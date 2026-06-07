//! POSIX-oriented shell word expansion phases.
//!
//! This module intentionally exposes phases separately so Bash-specific behavior
//! can be added later without baking it into parsing or execution IR.

const std = @import("std");
const compat = @import("compat.zig");

pub const EnvLookup = struct {
    context: ?*const anyopaque = null,
    lookupFn: ?*const fn (?*const anyopaque, []const u8) ?[]const u8 = null,

    pub fn get(self: EnvLookup, name: []const u8) ?[]const u8 {
        const lookup = self.lookupFn orelse return null;
        return lookup(self.context, name);
    }
};

pub const EnvSet = struct {
    context: ?*anyopaque = null,
    setFn: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror!void = null,

    pub fn set(self: EnvSet, name: []const u8, value: []const u8) !void {
        const set_fn = self.setFn orelse return;
        try set_fn(self.context, name, value);
    }
};

pub const CommandSubstitution = struct {
    context: ?*anyopaque = null,
    runFn: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8 = null,

    pub fn run(self: CommandSubstitution, allocator: std.mem.Allocator, script: []const u8) !?[]const u8 {
        const run_fn = self.runFn orelse return null;
        return try run_fn(self.context, allocator, script);
    }
};

pub const Options = struct {
    env: EnvLookup = .{},
    env_set: EnvSet = .{},
    io: ?std.Io = null,
    features: compat.Features = .{},
    command_substitution: CommandSubstitution = .{},
    positionals: []const []const u8 = &.{},
    pathname_expansion: bool = true,
};

pub const Phase = enum {
    tilde,
    parameter,
    field_splitting,
    pathname,
    quote_removal,
};

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn init(start: usize, end: usize) Span {
        std.debug.assert(end >= start);
        return .{ .start = start, .end = end };
    }

    pub fn slice(self: Span, source: []const u8) []const u8 {
        std.debug.assert(self.end <= source.len);
        return source[self.start..self.end];
    }
};

pub const WordPartKind = enum {
    unquoted,
    single_quoted,
    double_quoted,
    escaped,
    parameter,
    arithmetic,
    command_substitution,
};

pub const WordPart = struct {
    kind: WordPartKind,
    span: Span,
    value_span: Span,

    pub fn source(self: WordPart, raw: []const u8) []const u8 {
        return self.span.slice(raw);
    }

    pub fn value(self: WordPart, raw: []const u8) []const u8 {
        return self.value_span.slice(raw);
    }
};

pub const WordParts = struct {
    allocator: std.mem.Allocator,
    raw: []const u8,
    parts: []WordPart,

    pub fn deinit(self: *WordParts) void {
        self.allocator.free(self.parts);
        self.* = undefined;
    }
};

pub const ExpansionResult = struct {
    allocator: std.mem.Allocator,
    fields: []const []const u8,

    pub fn deinit(self: *ExpansionResult) void {
        for (self.fields) |field| self.allocator.free(field);
        self.allocator.free(self.fields);
        self.* = undefined;
    }
};

pub fn expandWord(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpansionResult {
    _ = options.features;
    const tilde_expanded = try expandTilde(allocator, raw, options.env);
    defer allocator.free(tilde_expanded);

    var parts = try parseWordParts(allocator, tilde_expanded);
    defer parts.deinit();

    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var force_current_field = false;

    const ifs = options.env.get("IFS") orelse " \t\n";
    for (parts.parts) |part| {
        if (part.kind == .double_quoted) {
            try appendDoubleQuotedText(allocator, &fields, &current, &force_current_field, part.value(parts.raw), options, ifs);
            continue;
        }
        const split = part.kind == .unquoted or part.kind == .parameter;
        const rendered = try renderPart(allocator, parts.raw, part, options);
        defer allocator.free(rendered);
        if (split) {
            try appendSplitText(allocator, &fields, &current, rendered, ifs);
        } else {
            try current.appendSlice(allocator, rendered);
        }
    }

    if (current.items.len != 0 or force_current_field) {
        try fields.append(allocator, try current.toOwnedSlice(allocator));
    }

    if (options.pathname_expansion) {
        if (options.io) |io| {
            try applyPathnameExpansion(allocator, io, &fields);
        }
    }

    return .{
        .allocator = allocator,
        .fields = try fields.toOwnedSlice(allocator),
    };
}

pub fn expandWordScalar(allocator: std.mem.Allocator, raw: []const u8, options: Options) anyerror![]const u8 {
    _ = options.features;
    const tilde_expanded = try expandTilde(allocator, raw, options.env);
    defer allocator.free(tilde_expanded);

    var parts = try parseWordParts(allocator, tilde_expanded);
    defer parts.deinit();

    // Field splitting and pathname expansion are explicit phases even though
    // this scalar helper leaves them as no-ops. `expandWord` is the place that
    // will grow multiple fields later.
    return renderWordParts(allocator, parts, options);
}

pub fn parseWordParts(allocator: std.mem.Allocator, raw: []const u8) !WordParts {
    var parts: std.ArrayList(WordPart) = .empty;
    errdefer parts.deinit(allocator);

    var index: usize = 0;
    var unquoted_start: ?usize = null;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                const start = index;
                index += 1;
                const value_start = index;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {}
                const value_end = index;
                if (index < raw.len) index += 1;
                try parts.append(allocator, .{
                    .kind = .single_quoted,
                    .span = .init(start, index),
                    .value_span = .init(value_start, value_end),
                });
            },
            '"' => {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                const start = index;
                index += 1;
                const value_start = index;
                while (index < raw.len and raw[index] != '"') {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        index += 2;
                    } else {
                        index += 1;
                    }
                }
                const value_end = index;
                if (index < raw.len) index += 1;
                try parts.append(allocator, .{
                    .kind = .double_quoted,
                    .span = .init(start, index),
                    .value_span = .init(value_start, value_end),
                });
            },
            '\\' => {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                const start = index;
                index += 1;
                const value_start = index;
                if (index < raw.len) index += 1;
                try parts.append(allocator, .{
                    .kind = .escaped,
                    .span = .init(start, index),
                    .value_span = .init(value_start, index),
                });
            },
            '$' => if (arithmeticPart(raw, index) orelse commandSubstitutionPart(raw, index) orelse parameterPart(raw, index)) |part| {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                try parts.append(allocator, part);
                index = part.span.end;
            } else {
                if (unquoted_start == null) unquoted_start = index;
                index += 1;
            },
            '`' => if (backquoteCommandSubstitutionPart(raw, index)) |part| {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                try parts.append(allocator, part);
                index = part.span.end;
            } else {
                if (unquoted_start == null) unquoted_start = index;
                index += 1;
            },
            else => {
                if (unquoted_start == null) unquoted_start = index;
                index += 1;
            },
        }
    }
    try flushUnquoted(allocator, raw, &parts, &unquoted_start, raw.len);

    return .{
        .allocator = allocator,
        .raw = raw,
        .parts = try parts.toOwnedSlice(allocator),
    };
}

fn flushUnquoted(allocator: std.mem.Allocator, raw: []const u8, parts: *std.ArrayList(WordPart), start: *?usize, end: usize) !void {
    _ = raw;
    const actual_start = start.* orelse return;
    if (actual_start < end) {
        try parts.append(allocator, .{
            .kind = .unquoted,
            .span = .init(actual_start, end),
            .value_span = .init(actual_start, end),
        });
    }
    start.* = null;
}

fn arithmeticPart(raw: []const u8, dollar: usize) ?WordPart {
    if (dollar + 2 >= raw.len or raw[dollar] != '$' or raw[dollar + 1] != '(' or raw[dollar + 2] != '(') return null;
    const value_start = dollar + 3;
    var index = value_start;
    while (index + 1 < raw.len) : (index += 1) {
        if (raw[index] == ')' and raw[index + 1] == ')') {
            return .{
                .kind = .arithmetic,
                .span = .init(dollar, index + 2),
                .value_span = .init(value_start, index),
            };
        }
    }
    return null;
}

fn backquoteCommandSubstitutionPart(raw: []const u8, start: usize) ?WordPart {
    if (raw[start] != '`') return null;
    var index = start + 1;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '\\' and index + 1 < raw.len) {
            index += 1;
            continue;
        }
        if (raw[index] == '`') {
            return .{
                .kind = .command_substitution,
                .span = .init(start, index + 1),
                .value_span = .init(start + 1, index),
            };
        }
    }
    return null;
}

fn commandSubstitutionPart(raw: []const u8, dollar: usize) ?WordPart {
    if (dollar + 1 >= raw.len or raw[dollar] != '$' or raw[dollar + 1] != '(') return null;
    // Arithmetic expansion is handled before this function.
    if (dollar + 2 < raw.len and raw[dollar + 2] == '(') return null;

    const value_start = dollar + 2;
    var index = value_start;
    var depth: usize = 1;
    while (index < raw.len) : (index += 1) {
        switch (raw[index]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return .{
                        .kind = .command_substitution,
                        .span = .init(dollar, index + 1),
                        .value_span = .init(value_start, index),
                    };
                }
            },
            '\'', '"' => {
                const quote = raw[index];
                index += 1;
                while (index < raw.len and raw[index] != quote) : (index += 1) {}
            },
            else => {},
        }
    }
    return null;
}

fn parameterPart(raw: []const u8, dollar: usize) ?WordPart {
    std.debug.assert(raw[dollar] == '$');
    const next = dollar + 1;
    if (next >= raw.len) return null;

    if (raw[next] == '{') {
        const name_start = next + 1;
        var name_end = name_start;
        while (name_end < raw.len and raw[name_end] != '}') : (name_end += 1) {}
        if (name_end >= raw.len) return null;
        return .{
            .kind = .parameter,
            .span = .init(dollar, name_end + 1),
            .value_span = .init(name_start, name_end),
        };
    }

    if (isSpecialParameterChar(raw[next])) {
        return .{
            .kind = .parameter,
            .span = .init(dollar, next + 1),
            .value_span = .init(next, next + 1),
        };
    }

    if (!isNameStart(raw[next])) return null;
    var name_end = next + 1;
    while (name_end < raw.len and isNameContinue(raw[name_end])) : (name_end += 1) {}
    return .{
        .kind = .parameter,
        .span = .init(dollar, name_end),
        .value_span = .init(next, name_end),
    };
}

pub fn renderWordParts(allocator: std.mem.Allocator, word: WordParts, options: Options) anyerror![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (word.parts) |part| {
        const rendered = try renderPart(allocator, word.raw, part, options);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
    }

    return output.toOwnedSlice(allocator);
}

fn renderPart(allocator: std.mem.Allocator, raw: []const u8, part: WordPart, options: Options) anyerror![]const u8 {
    return switch (part.kind) {
        .unquoted, .escaped, .single_quoted => allocator.dupe(u8, part.value(raw)),
        .double_quoted => blk: {
            const expanded = try expandParameters(allocator, part.value(raw), options);
            defer allocator.free(expanded);
            break :blk quoteRemoveDoubleQuotedContent(allocator, expanded);
        },
        .parameter => renderParameter(allocator, part.value(raw), options),
        .arithmetic => blk: {
            const value = try evalArithmetic(part.value(raw));
            break :blk std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .command_substitution => blk: {
            const script = try commandSubstitutionScript(allocator, raw, part);
            defer allocator.free(script);
            const output = (try options.command_substitution.run(allocator, script)) orelse try allocator.alloc(u8, 0);
            defer allocator.free(output);
            const trimmed = trimTrailingNewlines(output);
            break :blk allocator.dupe(u8, trimmed);
        },
    };
}

const ParameterOperator = enum {
    none,
    length,
    default_value,
    assign_default,
    alternate_value,
    error_if_unset,
    remove_small_suffix,
    remove_large_suffix,
    remove_small_prefix,
    remove_large_prefix,
};

const ParameterExpression = struct {
    name: []const u8,
    operator: ParameterOperator = .none,
    word: []const u8 = "",
    colon: bool = false,
};

fn renderParameter(allocator: std.mem.Allocator, expression: []const u8, options: Options) anyerror![]const u8 {
    const parsed = parseParameterExpression(expression);
    const value = options.env.get(parsed.name);
    const is_set = value != null;
    const is_null = if (value) |text| text.len == 0 else true;

    switch (parsed.operator) {
        .none => return if (value) |text| allocator.dupe(u8, text) else allocator.alloc(u8, 0),
        .length => {
            const len = if (value) |text| text.len else 0;
            return std.fmt.allocPrint(allocator, "{d}", .{len});
        },
        .default_value => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) return allocator.dupe(u8, value.?);
            return expandWordScalar(allocator, parsed.word, options);
        },
        .assign_default => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) return allocator.dupe(u8, value.?);
            const expanded = try expandWordScalar(allocator, parsed.word, options);
            errdefer allocator.free(expanded);
            try options.env_set.set(parsed.name, expanded);
            return expanded;
        },
        .alternate_value => {
            if (!parameterHasUsableValue(is_set, is_null, parsed.colon)) return allocator.alloc(u8, 0);
            return expandWordScalar(allocator, parsed.word, options);
        },
        .error_if_unset => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) return allocator.dupe(u8, value.?);
            return error.ParameterExpansionFailed;
        },
        .remove_small_suffix, .remove_large_suffix, .remove_small_prefix, .remove_large_prefix => {
            const base = value orelse "";
            const pattern = try expandWordScalar(allocator, parsed.word, options);
            defer allocator.free(pattern);
            return removePattern(allocator, base, pattern, parsed.operator);
        },
    }
}

fn removePattern(allocator: std.mem.Allocator, value: []const u8, pattern: []const u8, operator: ParameterOperator) ![]const u8 {
    return switch (operator) {
        .remove_small_suffix => blk: {
            var start = value.len;
            while (true) {
                if (globMatches(pattern, value[start..])) break :blk allocator.dupe(u8, value[0..start]);
                if (start == 0) break;
                start -= 1;
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_large_suffix => blk: {
            var start: usize = 0;
            while (start <= value.len) : (start += 1) {
                if (globMatches(pattern, value[start..])) break :blk allocator.dupe(u8, value[0..start]);
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_small_prefix => blk: {
            var end: usize = 0;
            while (end <= value.len) : (end += 1) {
                if (globMatches(pattern, value[0..end])) break :blk allocator.dupe(u8, value[end..]);
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_large_prefix => blk: {
            var end = value.len;
            while (true) {
                if (globMatches(pattern, value[0..end])) break :blk allocator.dupe(u8, value[end..]);
                if (end == 0) break;
                end -= 1;
            }
            break :blk allocator.dupe(u8, value);
        },
        else => unreachable,
    };
}

fn parameterHasUsableValue(is_set: bool, is_null: bool, colon: bool) bool {
    return if (colon) is_set and !is_null else is_set;
}

fn parseParameterExpression(expression: []const u8) ParameterExpression {
    if (expression.len > 1 and expression[0] == '#') {
        return .{ .name = expression[1..], .operator = .length };
    }

    var name_end: usize = 0;
    if (expression.len > 0 and isSpecialParameterChar(expression[0])) {
        name_end = 1;
    } else {
        while (name_end < expression.len and isNameContinue(expression[name_end])) : (name_end += 1) {}
    }
    if (name_end == 0) return .{ .name = expression };
    if (name_end >= expression.len) return .{ .name = expression[0..name_end] };

    var operator_index = name_end;
    var colon = false;
    if (expression[operator_index] == ':' and operator_index + 1 < expression.len) {
        colon = true;
        operator_index += 1;
    }
    const operator: ParameterOperator = switch (expression[operator_index]) {
        '-' => .default_value,
        '=' => .assign_default,
        '+' => .alternate_value,
        '?' => .error_if_unset,
        '%' => if (operator_index + 1 < expression.len and expression[operator_index + 1] == '%') .remove_large_suffix else .remove_small_suffix,
        '#' => if (operator_index + 1 < expression.len and expression[operator_index + 1] == '#') .remove_large_prefix else .remove_small_prefix,
        else => return .{ .name = expression },
    };
    const word_start = operator_index + @as(usize, if (operator == .remove_large_suffix or operator == .remove_large_prefix) 2 else 1);
    return .{
        .name = expression[0..name_end],
        .operator = operator,
        .word = expression[word_start..],
        .colon = colon,
    };
}

const ArithmeticParser = struct {
    input: []const u8,
    index: usize = 0,

    fn parse(self: *ArithmeticParser) anyerror!i64 {
        const value = try self.parseExpr();
        self.skipSpace();
        if (self.index != self.input.len) return error.InvalidArithmetic;
        return value;
    }

    fn parseExpr(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseTerm();
        while (true) {
            self.skipSpace();
            if (self.eat('+')) {
                value += try self.parseTerm();
            } else if (self.eat('-')) {
                value -= try self.parseTerm();
            } else return value;
        }
    }

    fn parseTerm(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseFactor();
        while (true) {
            self.skipSpace();
            if (self.eat('*')) {
                value *= try self.parseFactor();
            } else if (self.eat('/')) {
                const rhs = try self.parseFactor();
                if (rhs == 0) return error.DivisionByZero;
                value = @divTrunc(value, rhs);
            } else if (self.eat('%')) {
                const rhs = try self.parseFactor();
                if (rhs == 0) return error.DivisionByZero;
                value = @rem(value, rhs);
            } else return value;
        }
    }

    fn parseFactor(self: *ArithmeticParser) anyerror!i64 {
        self.skipSpace();
        if (self.eat('+')) return self.parseFactor();
        if (self.eat('-')) return -(try self.parseFactor());
        if (self.eat('(')) {
            const value = try self.parseExpr();
            self.skipSpace();
            if (!self.eat(')')) return error.InvalidArithmetic;
            return value;
        }
        return self.parseNumber();
    }

    fn parseNumber(self: *ArithmeticParser) anyerror!i64 {
        self.skipSpace();
        const start = self.index;
        while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) : (self.index += 1) {}
        if (start == self.index) return error.InvalidArithmetic;
        return std.fmt.parseInt(i64, self.input[start..self.index], 10);
    }

    fn skipSpace(self: *ArithmeticParser) void {
        while (self.index < self.input.len and isDefaultIfsWhitespace(self.input[self.index])) self.index += 1;
    }

    fn eat(self: *ArithmeticParser, c: u8) bool {
        if (self.index < self.input.len and self.input[self.index] == c) {
            self.index += 1;
            return true;
        }
        return false;
    }
};

pub fn evalArithmetic(input: []const u8) anyerror!i64 {
    var arithmetic_parser: ArithmeticParser = .{ .input = input };
    return arithmetic_parser.parse();
}

fn commandSubstitutionScript(allocator: std.mem.Allocator, raw: []const u8, part: WordPart) ![]const u8 {
    const source = part.source(raw);
    if (source.len == 0 or source[0] != '`') return allocator.dupe(u8, part.value(raw));

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const value = part.value(raw);
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '\\' and index + 1 < value.len) {
            const next = value[index + 1];
            if (next == '`' or next == '$' or next == '\\' or next == '\n') {
                try output.append(allocator, next);
                index += 2;
                continue;
            }
        }
        try output.append(allocator, value[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn trimTrailingNewlines(output: []const u8) []const u8 {
    var end = output.len;
    while (end > 0 and output[end - 1] == '\n') end -= 1;
    return output[0..end];
}

fn appendDoubleQuotedText(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, text: []const u8, options: Options, ifs: []const u8) !void {
    force_current_field.* = true;
    var index: usize = 0;
    var segment_start: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len) {
            index += 2;
            continue;
        }
        if (quotedPositionalAt(text, index)) |special| {
            try appendQuotedSegment(allocator, current, text[segment_start..index], options);
            switch (special.kind) {
                .at => try appendQuotedAt(allocator, fields, current, force_current_field, options.positionals),
                .star => try appendQuotedStar(allocator, current, options.positionals, ifs),
            }
            index = special.end;
            segment_start = index;
            continue;
        }
        index += 1;
    }
    try appendQuotedSegment(allocator, current, text[segment_start..], options);
}

const QuotedPositionalKind = enum { at, star };
const QuotedPositional = struct { kind: QuotedPositionalKind, end: usize };

fn quotedPositionalAt(text: []const u8, index: usize) ?QuotedPositional {
    if (index + 1 >= text.len or text[index] != '$') return null;
    return switch (text[index + 1]) {
        '@' => .{ .kind = .at, .end = index + 2 },
        '*' => .{ .kind = .star, .end = index + 2 },
        '{' => blk: {
            if (index + 3 < text.len and text[index + 3] == '}' and (text[index + 2] == '@' or text[index + 2] == '*')) {
                break :blk .{ .kind = if (text[index + 2] == '@') .at else .star, .end = index + 4 };
            }
            break :blk null;
        },
        else => null,
    };
}

fn appendQuotedSegment(allocator: std.mem.Allocator, current: *std.ArrayList(u8), text: []const u8, options: Options) !void {
    const expanded = try expandParameters(allocator, text, options);
    defer allocator.free(expanded);
    const removed = try quoteRemoveDoubleQuotedContent(allocator, expanded);
    defer allocator.free(removed);
    try current.appendSlice(allocator, removed);
}

fn appendQuotedAt(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, positionals: []const []const u8) !void {
    if (positionals.len == 0) {
        force_current_field.* = false;
        return;
    }
    for (positionals, 0..) |param, index| {
        try current.appendSlice(allocator, param);
        force_current_field.* = true;
        if (index + 1 < positionals.len) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
            force_current_field.* = false;
        }
    }
}

fn appendQuotedStar(allocator: std.mem.Allocator, current: *std.ArrayList(u8), positionals: []const []const u8, ifs: []const u8) !void {
    const separator = if (ifs.len == 0) "" else ifs[0..1];
    for (positionals, 0..) |param, index| {
        if (index > 0) try current.appendSlice(allocator, separator);
        try current.appendSlice(allocator, param);
    }
}

fn appendSplitText(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), text: []const u8, ifs: []const u8) !void {
    if (ifs.len == 0) {
        try current.appendSlice(allocator, text);
        return;
    }

    var index: usize = 0;
    while (index < text.len) {
        const c = text[index];
        if (!isIfsChar(ifs, c)) {
            try current.append(allocator, c);
            index += 1;
            continue;
        }

        if (isIfsWhitespace(ifs, c)) {
            if (current.items.len != 0) {
                try fields.append(allocator, try current.toOwnedSlice(allocator));
            }
            while (index < text.len and isIfsWhitespace(ifs, text[index])) index += 1;
            continue;
        }

        try fields.append(allocator, try current.toOwnedSlice(allocator));
        index += 1;
        while (index < text.len and isIfsWhitespace(ifs, text[index])) index += 1;
    }
}

fn isDefaultIfsWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn isIfsChar(ifs: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, ifs, c) != null;
}

fn isIfsWhitespace(ifs: []const u8, c: u8) bool {
    return (c == ' ' or c == '\t' or c == '\n') and isIfsChar(ifs, c);
}

fn applyPathnameExpansion(allocator: std.mem.Allocator, io: std.Io, fields: *std.ArrayList([]const u8)) !void {
    var expanded: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (expanded.items) |field| allocator.free(field);
        expanded.deinit(allocator);
    }

    for (fields.items) |field| {
        if (hasGlobSyntax(field)) {
            const matches = try globCwd(allocator, io, field);
            defer allocator.free(matches);
            if (matches.len != 0) {
                allocator.free(field);
                for (matches) |match| {
                    try expanded.append(allocator, match);
                }
                continue;
            }
        }
        try expanded.append(allocator, field);
    }

    fields.deinit(allocator);
    fields.* = expanded;
}

fn globCwd(allocator: std.mem.Allocator, io: std.Io, pattern: []const u8) ![][]const u8 {
    if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
        return allocator.alloc([]const u8, 0);
    }

    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |match| allocator.free(match);
        matches.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.' and (pattern.len == 0 or pattern[0] != '.')) continue;
        if (globMatches(pattern, entry.name)) {
            try matches.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    std.mem.sort([]const u8, matches.items, {}, lessThanString);
    return matches.toOwnedSlice(allocator);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hasGlobSyntax(text: []const u8) bool {
    for (text) |c| switch (c) {
        '*', '?', '[' => return true,
        else => {},
    };
    return false;
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    return globMatchesAt(pattern, 0, text, 0);
}

fn globMatchesAt(pattern: []const u8, pattern_index: usize, text: []const u8, text_index: usize) bool {
    if (pattern_index == pattern.len) return text_index == text.len;

    switch (pattern[pattern_index]) {
        '*' => {
            var next_text = text_index;
            while (true) : (next_text += 1) {
                if (globMatchesAt(pattern, pattern_index + 1, text, next_text)) return true;
                if (next_text == text.len) break;
            }
            return false;
        },
        '?' => return text_index < text.len and globMatchesAt(pattern, pattern_index + 1, text, text_index + 1),
        '[' => if (matchBracket(pattern, pattern_index, text, text_index)) |matched| {
            return matched.ok and globMatchesAt(pattern, matched.next_pattern, text, text_index + 1);
        } else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, pattern_index + 1, text, text_index + 1),
        else => |c| return text_index < text.len and c == text[text_index] and globMatchesAt(pattern, pattern_index + 1, text, text_index + 1),
    }
}

const BracketMatch = struct { ok: bool, next_pattern: usize };

fn matchBracket(pattern: []const u8, pattern_index: usize, text: []const u8, text_index: usize) ?BracketMatch {
    if (text_index >= text.len) return .{ .ok = false, .next_pattern = pattern_index + 1 };
    var index = pattern_index + 1;
    if (index >= pattern.len) return null;
    const negated = pattern[index] == '!' or pattern[index] == '^';
    if (negated) index += 1;

    var matched = false;
    var saw_end = false;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']') {
            saw_end = true;
            break;
        }
        if (index + 2 < pattern.len and pattern[index + 1] == '-' and pattern[index + 2] != ']') {
            const start = pattern[index];
            const end = pattern[index + 2];
            if (text[text_index] >= start and text[text_index] <= end) matched = true;
            index += 2;
            continue;
        }
        if (pattern[index] == text[text_index]) matched = true;
    }
    if (!saw_end) return null;
    return .{ .ok = if (negated) !matched else matched, .next_pattern = index + 1 };
}

pub fn expandTilde(allocator: std.mem.Allocator, raw: []const u8, env: EnvLookup) ![]const u8 {
    if (raw.len == 0 or raw[0] != '~') return allocator.dupe(u8, raw);
    if (raw.len > 1 and raw[1] != '/') return allocator.dupe(u8, raw);
    const home = env.get("HOME") orelse return allocator.dupe(u8, raw);
    return std.mem.concat(allocator, u8, &.{ home, raw[1..] });
}

pub fn expandParameters(allocator: std.mem.Allocator, raw: []const u8, options: Options) anyerror![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                const start = index;
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {}
                if (index < raw.len) index += 1;
                try output.appendSlice(allocator, raw[start..index]);
            },
            '$' => if (try expandParameterAt(allocator, raw, &index, options, &output)) {},
            else => |c| {
                try output.append(allocator, c);
                index += 1;
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

fn expandParameterAt(allocator: std.mem.Allocator, raw: []const u8, index: *usize, options: Options, output: *std.ArrayList(u8)) anyerror!bool {
    std.debug.assert(raw[index.*] == '$');
    const dollar = index.*;
    index.* += 1;

    if (index.* >= raw.len) {
        try output.append(allocator, '$');
        return true;
    }

    if (raw[index.*] == '{') {
        const name_start = index.* + 1;
        var name_end = name_start;
        while (name_end < raw.len and raw[name_end] != '}') : (name_end += 1) {}
        if (name_end >= raw.len) {
            try output.appendSlice(allocator, raw[dollar..]);
            index.* = raw.len;
            return true;
        }
        const rendered = try renderParameter(allocator, raw[name_start..name_end], options);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
        index.* = name_end + 1;
        return true;
    }

    if (isSpecialParameterChar(raw[index.*])) {
        const rendered = try renderParameter(allocator, raw[index.* .. index.* + 1], options);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
        index.* += 1;
        return true;
    }

    if (!isNameStart(raw[index.*])) {
        try output.append(allocator, '$');
        try output.append(allocator, raw[index.*]);
        index.* += 1;
        return true;
    }

    const name_start = index.*;
    index.* += 1;
    while (index.* < raw.len and isNameContinue(raw[index.*])) : (index.* += 1) {}
    const rendered = try renderParameter(allocator, raw[name_start..index.*], options);
    defer allocator.free(rendered);
    try output.appendSlice(allocator, rendered);
    return true;
}

fn quoteRemoveDoubleQuotedContent(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '\\' and index + 1 < raw.len and isDoubleQuoteBackslashEscaped(raw[index + 1])) {
            index += 1;
        }
        try output.append(allocator, raw[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

pub fn quoteRemove(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {
                    try output.append(allocator, raw[index]);
                }
                if (index < raw.len) index += 1;
            },
            '"' => {
                index += 1;
                while (index < raw.len and raw[index] != '"') {
                    if (raw[index] == '\\' and index + 1 < raw.len and isDoubleQuoteBackslashEscaped(raw[index + 1])) {
                        index += 1;
                    }
                    try output.append(allocator, raw[index]);
                    index += 1;
                }
                if (index < raw.len) index += 1;
            },
            '\\' => {
                index += 1;
                if (index < raw.len) {
                    try output.append(allocator, raw[index]);
                    index += 1;
                }
            },
            else => |c| {
                try output.append(allocator, c);
                index += 1;
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

fn isSpecialParameterChar(c: u8) bool {
    return std.ascii.isDigit(c) or c == '#' or c == '@' or c == '*' or c == '?' or c == '$' or c == '!';
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isDoubleQuoteBackslashEscaped(c: u8) bool {
    return c == '$' or c == '`' or c == '"' or c == '\\' or c == '\n';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c);
}

fn testCommandSubstitution(_: ?*anyopaque, allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    if (std.mem.eql(u8, script, "echo hi")) return allocator.dupe(u8, "hi\n\n");
    return allocator.dupe(u8, "");
}

const test_command_substitution: CommandSubstitution = .{ .runFn = testCommandSubstitution };

fn testLookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "HOME")) return "/home/rush";
    if (std.mem.eql(u8, name, "USER")) return "rush-user";
    if (std.mem.eql(u8, name, "EMPTY")) return "";
    if (std.mem.eql(u8, name, "PATHLIKE")) return "/usr/local/bin/rush";
    return null;
}

const test_env: EnvLookup = .{ .lookupFn = testLookup };

fn testIfsLookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "IFS")) return ":,";
    if (std.mem.eql(u8, name, "LIST")) return ":a::b:";
    return testLookup(null, name);
}

const test_ifs_env: EnvLookup = .{ .lookupFn = testIfsLookup };

fn testEmptyIfsLookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "IFS")) return "";
    if (std.mem.eql(u8, name, "LIST")) return "a b c";
    return testLookup(null, name);
}

const test_empty_ifs_env: EnvLookup = .{ .lookupFn = testEmptyIfsLookup };

test "word part parser records quoted escaped and parameter regions" {
    var parts = try parseWordParts(std.testing.allocator, "a'$USER'\"$USER\"\\ b${EMPTY}");
    defer parts.deinit();

    try std.testing.expectEqual(@as(usize, 6), parts.parts.len);
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[0].kind);
    try std.testing.expectEqualStrings("a", parts.parts[0].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.single_quoted, parts.parts[1].kind);
    try std.testing.expectEqualStrings("$USER", parts.parts[1].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.double_quoted, parts.parts[2].kind);
    try std.testing.expectEqualStrings("$USER", parts.parts[2].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.escaped, parts.parts[3].kind);
    try std.testing.expectEqualStrings(" ", parts.parts[3].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[4].kind);
    try std.testing.expectEqualStrings("b", parts.parts[4].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.parameter, parts.parts[5].kind);
    try std.testing.expectEqualStrings("EMPTY", parts.parts[5].value(parts.raw));
}

test "word part rendering expands parameters outside single quotes" {
    var parts = try parseWordParts(std.testing.allocator, "'$USER'\"$USER\"-$USER");
    defer parts.deinit();

    const rendered = try renderWordParts(std.testing.allocator, parts, .{ .env = test_env });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("$USERrush-user-rush-user", rendered);
}

test "expansion phases include tilde parameter and quote removal" {
    const expanded = try expandWordScalar(std.testing.allocator, "~/src/$USER/'literal $USER'/\"x\"", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("/home/rush/src/rush-user/literal $USER/x", expanded);
}

test "parameter expansion supports braced names and missing values" {
    const expanded = try expandWordScalar(std.testing.allocator, "${USER}-${MISSING}-${EMPTY}", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("rush-user--", expanded);
}

test "parameter expansion supports POSIX operators" {
    const defaults = try expandWordScalar(std.testing.allocator, "${USER:-fallback}:${MISSING:-fallback}:${EMPTY:-fallback}:${EMPTY-fallback}", .{ .env = test_env });
    defer std.testing.allocator.free(defaults);
    try std.testing.expectEqualStrings("rush-user:fallback:fallback:", defaults);

    const alternate = try expandWordScalar(std.testing.allocator, "${USER:+yes}:${MISSING:+yes}:${EMPTY:+yes}:${EMPTY+yes}", .{ .env = test_env });
    defer std.testing.allocator.free(alternate);
    try std.testing.expectEqualStrings("yes:::yes", alternate);

    const lengths = try expandWordScalar(std.testing.allocator, "${#USER}:${#MISSING}:${#EMPTY}", .{ .env = test_env });
    defer std.testing.allocator.free(lengths);
    try std.testing.expectEqualStrings("9:0:0", lengths);

    try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, "${MISSING:?required}", .{ .env = test_env }));
}

test "parameter expansion supports pattern removal operators" {
    const expanded = try expandWordScalar(std.testing.allocator, "${PATHLIKE%/*}:${PATHLIKE%%/*}:${PATHLIKE#*/}:${PATHLIKE##*/}", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualStrings("/usr/local/bin::usr/local/bin/rush:rush", expanded);
}

test "expand word returns fields through an explicit result" {
    var result = try expandWord(std.testing.allocator, "'hello world'", .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("hello world", result.fields[0]);
}

test "field splitting uses default IFS for unquoted expansion" {
    var result = try expandWord(std.testing.allocator, "$USER two\tthree", .{ .env = test_env });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.fields.len);
    try std.testing.expectEqualStrings("rush-user", result.fields[0]);
    try std.testing.expectEqualStrings("two", result.fields[1]);
    try std.testing.expectEqualStrings("three", result.fields[2]);
}

test "field splitting honors custom and empty IFS" {
    var custom = try expandWord(std.testing.allocator, "$LIST", .{ .env = test_ifs_env });
    defer custom.deinit();

    try std.testing.expectEqual(@as(usize, 4), custom.fields.len);
    try std.testing.expectEqualStrings("", custom.fields[0]);
    try std.testing.expectEqualStrings("a", custom.fields[1]);
    try std.testing.expectEqualStrings("", custom.fields[2]);
    try std.testing.expectEqualStrings("b", custom.fields[3]);

    var empty = try expandWord(std.testing.allocator, "$LIST", .{ .env = test_empty_ifs_env });
    defer empty.deinit();

    try std.testing.expectEqual(@as(usize, 1), empty.fields.len);
    try std.testing.expectEqualStrings("a b c", empty.fields[0]);
}

test "quoted positional parameters preserve fields" {
    const params = [_][]const u8{ "a b", "c", "" };

    var at = try expandWord(std.testing.allocator, "\"$@\"", .{ .positionals = &params });
    defer at.deinit();
    try std.testing.expectEqual(@as(usize, 3), at.fields.len);
    try std.testing.expectEqualStrings("a b", at.fields[0]);
    try std.testing.expectEqualStrings("c", at.fields[1]);
    try std.testing.expectEqualStrings("", at.fields[2]);

    var embedded = try expandWord(std.testing.allocator, "pre\"$@\"post", .{ .positionals = &params });
    defer embedded.deinit();
    try std.testing.expectEqual(@as(usize, 3), embedded.fields.len);
    try std.testing.expectEqualStrings("prea b", embedded.fields[0]);
    try std.testing.expectEqualStrings("c", embedded.fields[1]);
    try std.testing.expectEqualStrings("post", embedded.fields[2]);

    var star = try expandWord(std.testing.allocator, "\"$*\"", .{ .positionals = &params });
    defer star.deinit();
    try std.testing.expectEqual(@as(usize, 1), star.fields.len);
    try std.testing.expectEqualStrings("a b c ", star.fields[0]);
}

test "field splitting preserves quoted expansion results" {
    var result = try expandWord(std.testing.allocator, "\"$USER two\" 'three four'", .{ .env = test_env });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.fields.len);
    try std.testing.expectEqualStrings("rush-user two", result.fields[0]);
    try std.testing.expectEqualStrings("three four", result.fields[1]);
}

test "quote removal preserves non-special backslashes in double quotes" {
    const removed = try quoteRemove(std.testing.allocator, "\"a\\ b\\$c\\\\d\"");
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("a\\ b$c\\d", removed);

    const content = try quoteRemoveDoubleQuotedContent(std.testing.allocator, "a\\ b\\$c\\\\d");
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("a\\ b$c\\d", content);
}

test "command substitution parses and trims callback output" {
    var parts = try parseWordParts(std.testing.allocator, "before-$(echo hi)-after");
    defer parts.deinit();

    try std.testing.expectEqual(@as(usize, 3), parts.parts.len);
    try std.testing.expectEqual(WordPartKind.command_substitution, parts.parts[1].kind);
    try std.testing.expectEqualStrings("echo hi", parts.parts[1].value(parts.raw));

    var result = try expandWord(std.testing.allocator, "before-$(echo hi)-after", .{ .command_substitution = test_command_substitution });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("before-hi-after", result.fields[0]);

    var backquote_parts = try parseWordParts(std.testing.allocator, "before-`echo hi`-after");
    defer backquote_parts.deinit();
    try std.testing.expectEqual(@as(usize, 3), backquote_parts.parts.len);
    try std.testing.expectEqual(WordPartKind.command_substitution, backquote_parts.parts[1].kind);
    try std.testing.expectEqualStrings("echo hi", backquote_parts.parts[1].value(backquote_parts.raw));

    var backquote_result = try expandWord(std.testing.allocator, "before-`echo hi`-after", .{ .command_substitution = test_command_substitution });
    defer backquote_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), backquote_result.fields.len);
    try std.testing.expectEqualStrings("before-hi-after", backquote_result.fields[0]);
}

test "arithmetic expansion evaluates integer expressions" {
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("1 + 2 * 3"));
    try std.testing.expectEqual(@as(i64, 9), try evalArithmetic("(1 + 2) * 3"));
    try std.testing.expectEqual(@as(i64, -4), try evalArithmetic("-8 / 2"));

    var result = try expandWord(std.testing.allocator, "value=$((1 + 2 * 3))", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("value=7", result.fields[0]);
}

test "word part parser records arithmetic expansion regions" {
    var parts = try parseWordParts(std.testing.allocator, "a$((1 + 2))b");
    defer parts.deinit();

    try std.testing.expectEqual(@as(usize, 3), parts.parts.len);
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[0].kind);
    try std.testing.expectEqual(WordPartKind.arithmetic, parts.parts[1].kind);
    try std.testing.expectEqualStrings("1 + 2", parts.parts[1].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[2].kind);
}

test "pathname expansion matches sorted cwd entries" {
    const a = "rush-glob-a.tmp";
    const b = "rush-glob-b.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, b) catch {};

    var result = try expandWord(std.testing.allocator, "rush-glob-?.tmp", .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.fields.len);
    try std.testing.expectEqualStrings(a, result.fields[0]);
    try std.testing.expectEqualStrings(b, result.fields[1]);
}

test "pathname expansion preserves unmatched patterns" {
    var result = try expandWord(std.testing.allocator, "rush-no-match-*.tmp", .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("rush-no-match-*.tmp", result.fields[0]);
}
