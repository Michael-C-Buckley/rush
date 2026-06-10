//! POSIX-oriented shell word expansion phases.
//!
//! This module intentionally exposes phases separately so Bash-specific behavior
//! can be added later without baking it into parsing or execution IR.

const std = @import("std");
const zig_builtin = @import("builtin");
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

pub const ParameterError = struct {
    name: []const u8 = "",
    message: []const u8 = "",

    pub fn clear(self: *ParameterError, allocator: std.mem.Allocator) void {
        if (self.name.len != 0) allocator.free(self.name);
        if (self.message.len != 0) allocator.free(self.message);
        self.* = .{};
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
    nounset: bool = false,
    parameter_error: ?*ParameterError = null,
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
    const pathname_expansion_safe = !hasQuotedGlobSyntax(parts);

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
        const split = part.kind == .parameter or part.kind == .command_substitution or part.kind == .arithmetic;
        if (part.kind == .parameter) {
            const parameter = part.value(parts.raw);
            if (std.mem.eql(u8, parameter, "@")) {
                try appendUnquotedAt(allocator, &fields, &current, options.positionals, ifs);
                continue;
            }
            if (std.mem.eql(u8, parameter, "*")) {
                try appendUnquotedStar(allocator, &fields, &current, options.positionals, ifs);
                continue;
            }
        }
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

    if (options.pathname_expansion and pathname_expansion_safe) {
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

pub fn expandAssignmentWordScalar(allocator: std.mem.Allocator, raw: []const u8, options: Options) anyerror![]const u8 {
    _ = options.features;
    const tilde_expanded = try expandAssignmentTilde(allocator, raw, options.env);
    defer allocator.free(tilde_expanded);

    var parts = try parseWordParts(allocator, tilde_expanded);
    defer parts.deinit();

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
                const end = doubleQuotedSpanEnd(raw, index) orelse raw.len;
                const value_end = if (end > start + 1 and raw[end - 1] == '"') end - 1 else end;
                index = end;
                try parts.append(allocator, .{
                    .kind = .double_quoted,
                    .span = .init(start, end),
                    .value_span = .init(start + 1, value_end),
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
    while (index < raw.len) {
        switch (raw[index]) {
            '(' => {
                depth += 1;
                index += 1;
            },
            ')' => {
                depth -= 1;
                index += 1;
                if (depth == 0) {
                    return .{
                        .kind = .command_substitution,
                        .span = .init(dollar, index),
                        .value_span = .init(value_start, index - 1),
                    };
                }
            },
            '\\' => index += if (index + 1 < raw.len) 2 else 1,
            '\'' => {
                index += 1;
                while (index < raw.len and raw[index] != '\'') index += 1;
                if (index < raw.len) index += 1;
            },
            '"' => index = doubleQuotedSpanEnd(raw, index) orelse return null,
            else => index += 1,
        }
    }
    return null;
}

/// Returns the index just past the closing double quote of the
/// double-quoted string starting at `start`, or null when unterminated.
/// Embedded expansions keep their special meaning inside double quotes
/// (POSIX XCU 2.2.3), so quotes inside them do not close the string.
fn doubleQuotedSpanEnd(raw: []const u8, start: usize) ?usize {
    std.debug.assert(raw[start] == '"');
    var index = start + 1;
    while (index < raw.len) {
        switch (raw[index]) {
            '"' => return index + 1,
            '\\' => index += if (index + 1 < raw.len) 2 else 1,
            '$' => {
                const part = arithmeticPart(raw, index) orelse commandSubstitutionPart(raw, index) orelse parameterPart(raw, index);
                index = if (part) |p| p.span.end else index + 1;
            },
            '`' => {
                const part = backquoteCommandSubstitutionPart(raw, index);
                index = if (part) |p| p.span.end else index + 1;
            },
            else => index += 1,
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
        var index = name_start;
        var depth: usize = 1;
        while (index < raw.len) : (index += 1) {
            if (raw[index] == '$' and index + 1 < raw.len and raw[index + 1] == '{') {
                depth += 1;
                index += 1;
                continue;
            }
            if (raw[index] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (index >= raw.len or depth != 0) return null;
        return .{
            .kind = .parameter,
            .span = .init(dollar, index + 1),
            .value_span = .init(name_start, index),
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
        .unquoted, .single_quoted => allocator.dupe(u8, part.value(raw)),
        .escaped => if (std.mem.eql(u8, part.value(raw), "\n")) allocator.dupe(u8, "") else allocator.dupe(u8, part.value(raw)),
        .double_quoted => renderDoubleQuotedContent(allocator, part.value(raw), options),
        .parameter => renderParameter(allocator, part.value(raw), options),
        .arithmetic => blk: {
            const value = try evalArithmetic(part.value(raw), options.env, options.env_set);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .command_substitution => blk: {
            const script = try commandSubstitutionScript(allocator, raw, part, false);
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
        .none => {
            if (value) |text| return allocator.dupe(u8, text);
            if (options.nounset and !isNounsetExemptParameter(parsed.name)) return error.NounsetParameter;
            return allocator.alloc(u8, 0);
        },
        .length => {
            if (value) |text| return std.fmt.allocPrint(allocator, "{d}", .{text.len});
            if (options.nounset and !isNounsetExemptParameter(parsed.name)) return error.NounsetParameter;
            return allocator.dupe(u8, "0");
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
            const message = if (parsed.word.len != 0)
                try expandWordScalar(allocator, parsed.word, options)
            else
                try allocator.dupe(u8, "parameter null or not set");
            if (options.parameter_error) |parameter_error| {
                const name = allocator.dupe(u8, parsed.name) catch |err| {
                    allocator.free(message);
                    return err;
                };
                parameter_error.clear(allocator);
                parameter_error.name = name;
                parameter_error.message = message;
            } else {
                allocator.free(message);
            }
            return error.ParameterExpansionFailed;
        },
        .remove_small_suffix, .remove_large_suffix, .remove_small_prefix, .remove_large_prefix => {
            const base = value orelse "";
            var pattern = try expandPatternWord(allocator, parsed.word, options);
            defer pattern.deinit(allocator);
            return removePattern(allocator, base, pattern, parsed.operator);
        },
    }
}

const ExpansionPattern = struct {
    text: []const u8,
    special: []const bool,

    fn deinit(self: *ExpansionPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.special);
        self.* = undefined;
    }
};

fn expandPatternWord(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpansionPattern {
    var parts = try parseWordParts(allocator, raw);
    defer parts.deinit();

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var special: std.ArrayList(bool) = .empty;
    errdefer special.deinit(allocator);

    for (parts.parts) |part| {
        const rendered = try renderPart(allocator, parts.raw, part, options);
        defer allocator.free(rendered);
        const meta_active = switch (part.kind) {
            .unquoted, .parameter, .arithmetic, .command_substitution => true,
            .single_quoted, .double_quoted, .escaped => false,
        };
        try appendPatternPart(allocator, &text, &special, rendered, meta_active);
    }

    return .{ .text = try text.toOwnedSlice(allocator), .special = try special.toOwnedSlice(allocator) };
}

fn appendPatternPart(allocator: std.mem.Allocator, text: *std.ArrayList(u8), special: *std.ArrayList(bool), rendered: []const u8, meta_active: bool) !void {
    try text.appendSlice(allocator, rendered);
    for (rendered) |byte| {
        try special.append(allocator, meta_active and (byte == '*' or byte == '?' or byte == '['));
    }
}

fn removePattern(allocator: std.mem.Allocator, value: []const u8, pattern: ExpansionPattern, operator: ParameterOperator) ![]const u8 {
    return switch (operator) {
        .remove_small_suffix => blk: {
            var start = value.len;
            while (true) {
                if (globPatternMatches(pattern, value[start..])) break :blk allocator.dupe(u8, value[0..start]);
                if (start == 0) break;
                start -= 1;
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_large_suffix => blk: {
            var start: usize = 0;
            while (start <= value.len) : (start += 1) {
                if (globPatternMatches(pattern, value[start..])) break :blk allocator.dupe(u8, value[0..start]);
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_small_prefix => blk: {
            var end: usize = 0;
            while (end <= value.len) : (end += 1) {
                if (globPatternMatches(pattern, value[0..end])) break :blk allocator.dupe(u8, value[end..]);
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_large_prefix => blk: {
            var end = value.len;
            while (true) {
                if (globPatternMatches(pattern, value[0..end])) break :blk allocator.dupe(u8, value[end..]);
                if (end == 0) break;
                end -= 1;
            }
            break :blk allocator.dupe(u8, value);
        },
        else => unreachable,
    };
}

fn isNounsetExemptParameter(name: []const u8) bool {
    return std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*");
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
    env: EnvLookup = .{},
    env_set: EnvSet = .{},
    index: usize = 0,

    fn parse(self: *ArithmeticParser) anyerror!i64 {
        const value = try self.parseComma();
        self.skipSpace();
        if (self.index != self.input.len) return error.InvalidArithmetic;
        return value;
    }

    fn parseComma(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseAssignment();
        while (true) {
            self.skipSpace();
            if (!self.eat(',')) return value;
            value = try self.parseAssignment();
        }
    }

    fn parseAssignment(self: *ArithmeticParser) anyerror!i64 {
        self.skipSpace();
        const saved = self.index;
        if (self.index < self.input.len and isNameStart(self.input[self.index])) {
            const name_start = self.index;
            self.index += 1;
            while (self.index < self.input.len and isNameContinue(self.input[self.index])) : (self.index += 1) {}
            const name = self.input[name_start..self.index];
            self.skipSpace();
            if (self.assignmentOperator()) |op| {
                const rhs = try self.parseAssignment();
                const value = switch (op) {
                    .assign => rhs,
                    .add_assign => self.lookupNumber(name) + rhs,
                    .sub_assign => self.lookupNumber(name) - rhs,
                    .mul_assign => self.lookupNumber(name) * rhs,
                    .div_assign => blk: {
                        if (rhs == 0) return error.DivisionByZero;
                        break :blk @divTrunc(self.lookupNumber(name), rhs);
                    },
                    .mod_assign => blk: {
                        if (rhs == 0) return error.DivisionByZero;
                        break :blk @rem(self.lookupNumber(name), rhs);
                    },
                };
                try self.setNumber(name, value);
                return value;
            }
        }
        self.index = saved;
        return self.parseTernary();
    }

    const AssignmentOperator = enum { assign, add_assign, sub_assign, mul_assign, div_assign, mod_assign };

    fn assignmentOperator(self: *ArithmeticParser) ?AssignmentOperator {
        if (self.index >= self.input.len) return null;
        if (self.input[self.index] == '=') {
            if (self.index + 1 < self.input.len and self.input[self.index + 1] == '=') return null;
            self.index += 1;
            return .assign;
        }
        if (self.index + 1 >= self.input.len or self.input[self.index + 1] != '=') return null;
        const op: AssignmentOperator = switch (self.input[self.index]) {
            '+' => .add_assign,
            '-' => .sub_assign,
            '*' => .mul_assign,
            '/' => .div_assign,
            '%' => .mod_assign,
            else => return null,
        };
        self.index += 2;
        return op;
    }

    fn parseTernary(self: *ArithmeticParser) anyerror!i64 {
        const condition = try self.parseLogicalOr();
        self.skipSpace();
        if (!self.eat('?')) return condition;
        const when_true = try self.parseComma();
        self.skipSpace();
        if (!self.eat(':')) return error.InvalidArithmetic;
        const when_false = try self.parseTernary();
        return if (condition != 0) when_true else when_false;
    }

    fn parseLogicalOr(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseLogicalAnd();
        while (true) {
            self.skipSpace();
            if (!self.eatString("||")) return value;
            const rhs = try self.parseLogicalAnd();
            value = if (value != 0 or rhs != 0) 1 else 0;
        }
    }

    fn parseLogicalAnd(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseBitwiseOr();
        while (true) {
            self.skipSpace();
            if (!self.eatString("&&")) return value;
            const rhs = try self.parseBitwiseOr();
            value = if (value != 0 and rhs != 0) 1 else 0;
        }
    }

    fn parseBitwiseOr(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseBitwiseXor();
        while (true) {
            self.skipSpace();
            if (self.startsWith("||") or !self.eat('|')) return value;
            value |= try self.parseBitwiseXor();
        }
    }

    fn parseBitwiseXor(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseBitwiseAnd();
        while (true) {
            self.skipSpace();
            if (!self.eat('^')) return value;
            value ^= try self.parseBitwiseAnd();
        }
    }

    fn parseBitwiseAnd(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseEquality();
        while (true) {
            self.skipSpace();
            if (self.startsWith("&&") or !self.eat('&')) return value;
            value &= try self.parseEquality();
        }
    }

    fn parseEquality(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseRelational();
        while (true) {
            self.skipSpace();
            if (self.eatString("==")) {
                value = if (value == try self.parseRelational()) 1 else 0;
            } else if (self.eatString("!=")) {
                value = if (value != try self.parseRelational()) 1 else 0;
            } else return value;
        }
    }

    fn parseRelational(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseShift();
        while (true) {
            self.skipSpace();
            if (self.eatString("<=")) {
                value = if (value <= try self.parseShift()) 1 else 0;
            } else if (self.eatString(">=")) {
                value = if (value >= try self.parseShift()) 1 else 0;
            } else if (!self.startsWith("<<") and self.eat('<')) {
                value = if (value < try self.parseShift()) 1 else 0;
            } else if (!self.startsWith(">>") and self.eat('>')) {
                value = if (value > try self.parseShift()) 1 else 0;
            } else return value;
        }
    }

    fn parseShift(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseAdditive();
        while (true) {
            self.skipSpace();
            if (self.eatString("<<")) {
                value = value << shiftAmount(try self.parseAdditive());
            } else if (self.eatString(">>")) {
                value = value >> shiftAmount(try self.parseAdditive());
            } else return value;
        }
    }

    fn parseAdditive(self: *ArithmeticParser) anyerror!i64 {
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
        if (self.eat('!')) return if ((try self.parseFactor()) == 0) 1 else 0;
        if (self.eat('~')) return ~(try self.parseFactor());
        if (self.eat('(')) {
            const value = try self.parseComma();
            self.skipSpace();
            if (!self.eat(')')) return error.InvalidArithmetic;
            return value;
        }
        if (self.index < self.input.len and isNameStart(self.input[self.index])) return self.parseIdentifier();
        return self.parseNumber();
    }

    fn parseIdentifier(self: *ArithmeticParser) anyerror!i64 {
        const start = self.index;
        self.index += 1;
        while (self.index < self.input.len and isNameContinue(self.input[self.index])) : (self.index += 1) {}
        return self.lookupNumber(self.input[start..self.index]);
    }

    fn lookupNumber(self: ArithmeticParser, name: []const u8) i64 {
        const value = self.env.get(name) orelse return 0;
        if (value.len == 0) return 0;
        return parseIntegerConstant(value) catch 0;
    }

    fn setNumber(self: ArithmeticParser, name: []const u8, value: i64) !void {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        try self.env_set.set(name, text);
    }

    fn parseNumber(self: *ArithmeticParser) anyerror!i64 {
        self.skipSpace();
        const start = self.index;
        if (self.startsWith("0x") or self.startsWith("0X")) {
            self.index += 2;
            while (self.index < self.input.len and std.ascii.isHex(self.input[self.index])) : (self.index += 1) {}
        } else {
            while (self.index < self.input.len and std.ascii.isDigit(self.input[self.index])) : (self.index += 1) {}
        }
        if (start == self.index) return error.InvalidArithmetic;
        return parseIntegerConstant(self.input[start..self.index]);
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

    fn eatString(self: *ArithmeticParser, text: []const u8) bool {
        if (!self.startsWith(text)) return false;
        self.index += text.len;
        return true;
    }

    fn startsWith(self: ArithmeticParser, text: []const u8) bool {
        return self.index + text.len <= self.input.len and std.mem.eql(u8, self.input[self.index .. self.index + text.len], text);
    }
};

fn shiftAmount(value: i64) u6 {
    return @intCast(@as(u64, @intCast(if (value < 0) -value else value)) & 63);
}

/// Parse a POSIX arithmetic integer constant as in C: decimal, octal with a
/// leading 0, or hexadecimal with a leading 0x/0X, with an optional sign.
fn parseIntegerConstant(text: []const u8) error{ InvalidArithmetic, Overflow }!i64 {
    var rest = text;
    var negative = false;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    if (rest.len == 0) return error.InvalidArithmetic;
    const magnitude = blk: {
        if (rest.len > 2 and (std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X")) and std.ascii.isHex(rest[2])) {
            break :blk std.fmt.parseInt(i64, rest[2..], 16);
        }
        if (rest.len > 1 and rest[0] == '0') break :blk std.fmt.parseInt(i64, rest, 8);
        break :blk std.fmt.parseInt(i64, rest, 10);
    } catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => return error.InvalidArithmetic,
    };
    return if (negative) -magnitude else magnitude;
}

pub fn evalArithmetic(input: []const u8, env: EnvLookup, env_set: EnvSet) anyerror!i64 {
    var arithmetic_parser: ArithmeticParser = .{ .input = input, .env = env, .env_set = env_set };
    return arithmetic_parser.parse();
}

fn commandSubstitutionScript(allocator: std.mem.Allocator, raw: []const u8, part: WordPart, in_double_quotes: bool) ![]const u8 {
    const source = part.source(raw);
    if (source.len == 0 or source[0] != '`') return allocator.dupe(u8, part.value(raw));

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const value = part.value(raw);
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '\\' and index + 1 < value.len) {
            const next = value[index + 1];
            // Inside "`...`" the backslash also escapes the surrounding
            // double-quote (POSIX XCU 2.2.3), so it is removed here.
            if (next == '`' or next == '$' or next == '\\' or next == '\n' or
                (in_double_quotes and next == '"'))
            {
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

fn renderDoubleQuotedContent(allocator: std.mem.Allocator, text: []const u8, options: Options) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    var literal_start: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len) {
            index += 2;
            continue;
        }

        const part = switch (text[index]) {
            '$' => arithmeticPart(text, index) orelse commandSubstitutionPart(text, index) orelse parameterPart(text, index),
            '`' => backquoteCommandSubstitutionPart(text, index),
            else => null,
        } orelse {
            index += 1;
            continue;
        };

        try appendDoubleQuotedLiteral(allocator, &output, text[literal_start..index]);
        const rendered = try renderDoubleQuotedExpansion(allocator, text, part, options);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
        index = part.span.end;
        literal_start = index;
    }
    try appendDoubleQuotedLiteral(allocator, &output, text[literal_start..]);
    return output.toOwnedSlice(allocator);
}

fn appendDoubleQuotedLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    const removed = try quoteRemoveDoubleQuotedContent(allocator, text);
    defer allocator.free(removed);
    try output.appendSlice(allocator, removed);
}

fn renderDoubleQuotedExpansion(allocator: std.mem.Allocator, raw: []const u8, part: WordPart, options: Options) ![]const u8 {
    return switch (part.kind) {
        .parameter => renderParameter(allocator, part.value(raw), options),
        .arithmetic => blk: {
            const value = try evalArithmetic(part.value(raw), options.env, options.env_set);
            break :blk std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .command_substitution => blk: {
            const script = try commandSubstitutionScript(allocator, raw, part, true);
            defer allocator.free(script);
            const output = (try options.command_substitution.run(allocator, script)) orelse try allocator.alloc(u8, 0);
            defer allocator.free(output);
            const trimmed = trimTrailingNewlines(output);
            break :blk allocator.dupe(u8, trimmed);
        },
        else => unreachable,
    };
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
    const rendered = try renderDoubleQuotedContent(allocator, text, options);
    defer allocator.free(rendered);
    try current.appendSlice(allocator, rendered);
}

fn appendUnquotedAt(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), positionals: []const []const u8, ifs: []const u8) !void {
    for (positionals, 0..) |param, index| {
        try appendSplitText(allocator, fields, current, param, ifs);
        if (index + 1 < positionals.len and current.items.len != 0) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
        }
    }
}

fn appendUnquotedStar(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), positionals: []const []const u8, ifs: []const u8) !void {
    const joined = try joinPositionalsWithIfs(allocator, positionals, ifs);
    defer allocator.free(joined);
    try appendSplitText(allocator, fields, current, joined, ifs);
}

fn joinPositionalsWithIfs(allocator: std.mem.Allocator, positionals: []const []const u8, ifs: []const u8) ![]const u8 {
    const separator = if (ifs.len == 0) "" else ifs[0..1];
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (positionals, 0..) |param, index| {
        if (index > 0) try joined.appendSlice(allocator, separator);
        try joined.appendSlice(allocator, param);
    }
    return joined.toOwnedSlice(allocator);
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
            while (index < text.len and isIfsWhitespace(ifs, text[index])) index += 1;
            // IFS white space adjacent to a non-whitespace IFS character is
            // part of that single delimiter (POSIX XCU 2.6.5), handled by the
            // non-whitespace branch below.
            if (index < text.len and isIfsChar(ifs, text[index])) continue;
            if (current.items.len != 0) {
                try fields.append(allocator, try current.toOwnedSlice(allocator));
            }
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
    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |prefix| allocator.free(prefix);
        prefixes.deinit(allocator);
    }
    try prefixes.append(allocator, try allocator.dupe(u8, if (std.mem.startsWith(u8, pattern, "/")) "/" else ""));

    var component_iter = std.mem.splitScalar(u8, pattern, '/');
    while (component_iter.next()) |component| {
        if (component.len == 0 and prefixes.items.len == 1 and std.mem.eql(u8, prefixes.items[0], "/")) continue;
        var next_prefixes: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (next_prefixes.items) |prefix| allocator.free(prefix);
            next_prefixes.deinit(allocator);
        }

        for (prefixes.items) |prefix| {
            if (hasGlobSyntax(component)) {
                try appendGlobComponentMatches(allocator, io, &next_prefixes, prefix, component);
            } else {
                const candidate = try joinPathComponent(allocator, prefix, component);
                errdefer allocator.free(candidate);
                if (try pathComponentExists(io, candidate)) try next_prefixes.append(allocator, candidate) else allocator.free(candidate);
            }
        }

        for (prefixes.items) |prefix| allocator.free(prefix);
        prefixes.deinit(allocator);
        prefixes = next_prefixes;
    }

    std.mem.sort([]const u8, prefixes.items, {}, lessThanString);
    return prefixes.toOwnedSlice(allocator);
}

fn appendGlobComponentMatches(allocator: std.mem.Allocator, io: std.Io, matches: *std.ArrayList([]const u8), prefix: []const u8, component: []const u8) !void {
    const dir_path = if (prefix.len == 0) "." else prefix;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.' and (component.len == 0 or component[0] != '.')) continue;
        if (globMatches(component, entry.name)) {
            try matches.append(allocator, try joinPathComponent(allocator, prefix, entry.name));
        }
    }
}

fn joinPathComponent(allocator: std.mem.Allocator, prefix: []const u8, component: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, component);
    if (component.len == 0) return allocator.dupe(u8, prefix);
    if (std.mem.eql(u8, prefix, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{component});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, component });
}

fn pathComponentExists(io: std.Io, path: []const u8) !bool {
    if (path.len == 0) return true;
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    file.close(io);
    return true;
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

fn hasQuotedGlobSyntax(parts: WordParts) bool {
    for (parts.parts) |part| switch (part.kind) {
        .escaped, .single_quoted, .double_quoted => {
            if (hasGlobSyntax(part.value(parts.raw))) return true;
        },
        else => {},
    };
    return false;
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    return globMatchesAt(pattern, null, 0, text, 0);
}

fn globPatternMatches(pattern: ExpansionPattern, text: []const u8) bool {
    std.debug.assert(pattern.text.len == pattern.special.len);
    return globMatchesAt(pattern.text, pattern.special, 0, text, 0);
}

fn isGlobSpecial(special: ?[]const bool, index: usize) bool {
    return if (special) |mask| mask[index] else true;
}

fn globMatchesAt(pattern: []const u8, special: ?[]const bool, pattern_index: usize, text: []const u8, text_index: usize) bool {
    if (pattern_index == pattern.len) return text_index == text.len;

    switch (pattern[pattern_index]) {
        '*' => if (isGlobSpecial(special, pattern_index)) {
            var next_text = text_index;
            while (true) : (next_text += 1) {
                if (globMatchesAt(pattern, special, pattern_index + 1, text, next_text)) return true;
                if (next_text == text.len) break;
            }
            return false;
        } else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, pattern_index + 1, text, text_index + 1),
        '?' => if (isGlobSpecial(special, pattern_index)) return text_index < text.len and globMatchesAt(pattern, special, pattern_index + 1, text, text_index + 1) else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, pattern_index + 1, text, text_index + 1),
        '[' => if (isGlobSpecial(special, pattern_index)) {
            if (matchBracket(pattern, pattern_index, text, text_index)) |matched| {
                return matched.ok and globMatchesAt(pattern, special, matched.next_pattern, text, text_index + 1);
            }
            return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, pattern_index + 1, text, text_index + 1);
        } else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, pattern_index + 1, text, text_index + 1),
        else => |c| return text_index < text.len and c == text[text_index] and globMatchesAt(pattern, special, pattern_index + 1, text, text_index + 1),
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
    var first_expression = true;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']' and !first_expression) {
            saw_end = true;
            break;
        }
        first_expression = false;
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
    const end = tildePrefixEnd(raw, 0, false);
    const home = try lookupTildeHome(allocator, raw[1..end], env) orelse return allocator.dupe(u8, raw);
    defer allocator.free(home);
    return std.mem.concat(allocator, u8, &.{ home, raw[end..] });
}

pub fn expandAssignmentTilde(allocator: std.mem.Allocator, raw: []const u8, env: EnvLookup) ![]const u8 {
    const equals = std.mem.indexOfScalar(u8, raw, '=') orelse return allocator.dupe(u8, raw);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, raw[0 .. equals + 1]);

    var index = equals + 1;
    var at_tilde_prefix = true;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                const start = index;
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {}
                if (index < raw.len) index += 1;
                try output.appendSlice(allocator, raw[start..index]);
                at_tilde_prefix = false;
            },
            '"' => {
                const start = index;
                index += 1;
                while (index < raw.len and raw[index] != '"') {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        index += 2;
                    } else {
                        index += 1;
                    }
                }
                if (index < raw.len) index += 1;
                try output.appendSlice(allocator, raw[start..index]);
                at_tilde_prefix = false;
            },
            '\\' => {
                const start = index;
                index += 1;
                if (index < raw.len) index += 1;
                try output.appendSlice(allocator, raw[start..index]);
                at_tilde_prefix = false;
            },
            '~' => {
                if (at_tilde_prefix) {
                    const end = tildePrefixEnd(raw, index, true);
                    if (try lookupTildeHome(allocator, raw[index + 1 .. end], env)) |tilde_home| {
                        defer allocator.free(tilde_home);
                        try output.appendSlice(allocator, tilde_home);
                        index = end;
                    } else {
                        try output.append(allocator, raw[index]);
                        index += 1;
                    }
                } else {
                    try output.append(allocator, raw[index]);
                    index += 1;
                }
                at_tilde_prefix = false;
            },
            ':' => {
                try output.append(allocator, ':');
                index += 1;
                at_tilde_prefix = true;
            },
            else => |c| {
                try output.append(allocator, c);
                index += 1;
                at_tilde_prefix = false;
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

fn tildePrefixEnd(raw: []const u8, index: usize, colon_separator: bool) usize {
    std.debug.assert(raw[index] == '~');
    var end = index + 1;
    while (end < raw.len and raw[end] != '/' and !(colon_separator and raw[end] == ':')) : (end += 1) {}
    return end;
}

fn lookupTildeHome(allocator: std.mem.Allocator, user: []const u8, env: EnvLookup) !?[]const u8 {
    if (user.len == 0) return if (env.get("HOME")) |home| try allocator.dupe(u8, home) else null;
    if (!zig_builtin.link_libc) return null;
    if (std.mem.indexOfScalar(u8, user, 0) != null) return null;

    const user_z = try allocator.dupeZ(u8, user);
    defer allocator.free(user_z);
    const passwd = std.c.getpwnam(user_z.ptr) orelse return null;
    const dir = passwd.dir orelse return null;
    return @as(?[]const u8, try allocator.dupe(u8, std.mem.span(dir)));
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
            if (raw[index + 1] == '\n') {
                index += 2;
                continue;
            }
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
                    if (raw[index] == '\n') {
                        index += 1;
                        continue;
                    }
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
    if (std.mem.eql(u8, name, "USER_NUM")) return "3";
    if (std.mem.eql(u8, name, "OCTAL_NUM")) return "010";
    if (std.mem.eql(u8, name, "HEX_NUM")) return "0x2f";
    if (std.mem.eql(u8, name, "NEGATIVE_OCTAL_NUM")) return "-010";
    if (std.mem.eql(u8, name, "WORDS")) return "one two\tthree";
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

fn testCommaIfsLookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "IFS")) return ",";
    return testLookup(null, name);
}

const test_comma_ifs_env: EnvLookup = .{ .lookupFn = testCommaIfsLookup };

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
    var result = try expandWord(std.testing.allocator, "$WORDS", .{ .env = test_env });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.fields.len);
    try std.testing.expectEqualStrings("one", result.fields[0]);
    try std.testing.expectEqualStrings("two", result.fields[1]);
    try std.testing.expectEqualStrings("three", result.fields[2]);

    var literal = try expandWord(std.testing.allocator, "$USER two\tthree", .{ .env = test_env });
    defer literal.deinit();
    try std.testing.expectEqual(@as(usize, 1), literal.fields.len);
    try std.testing.expectEqualStrings("rush-user two\tthree", literal.fields[0]);
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

fn testMixedIfsLookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "IFS")) return " :";
    if (std.mem.eql(u8, name, "LIST")) return "a : b::c";
    return testLookup(null, name);
}

test "field splitting absorbs whitespace adjacent to non-whitespace delimiters" {
    const mixed_ifs_env: EnvLookup = .{ .lookupFn = testMixedIfsLookup };
    var result = try expandWord(std.testing.allocator, "$LIST", .{ .env = mixed_ifs_env });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.fields.len);
    try std.testing.expectEqualStrings("a", result.fields[0]);
    try std.testing.expectEqualStrings("b", result.fields[1]);
    try std.testing.expectEqualStrings("", result.fields[2]);
    try std.testing.expectEqualStrings("c", result.fields[3]);
}

test "unquoted positional parameters split field-aware values" {
    const params = [_][]const u8{ "a,b", "c" };
    var at = try expandWord(std.testing.allocator, "$@", .{ .positionals = &params, .env = test_comma_ifs_env });
    defer at.deinit();
    try std.testing.expectEqual(@as(usize, 3), at.fields.len);
    try std.testing.expectEqualStrings("a", at.fields[0]);
    try std.testing.expectEqualStrings("b", at.fields[1]);
    try std.testing.expectEqualStrings("c", at.fields[2]);

    const empty_params = [_][]const u8{ "", "x" };
    var empty_at = try expandWord(std.testing.allocator, "$@", .{ .positionals = &empty_params });
    defer empty_at.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty_at.fields.len);
    try std.testing.expectEqualStrings("x", empty_at.fields[0]);

    var star = try expandWord(std.testing.allocator, "$*", .{ .positionals = &params, .env = test_comma_ifs_env });
    defer star.deinit();
    try std.testing.expectEqual(@as(usize, 3), star.fields.len);
    try std.testing.expectEqualStrings("a", star.fields[0]);
    try std.testing.expectEqualStrings("b", star.fields[1]);
    try std.testing.expectEqualStrings("c", star.fields[2]);
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
    var result = try expandWord(std.testing.allocator, "\"$USER two\"'three four'", .{ .env = test_env });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("rush-user twothree four", result.fields[0]);
}

test "quote removal preserves non-special backslashes in double quotes" {
    const removed = try quoteRemove(std.testing.allocator, "\"a\\ b\\$c\\\\d\"");
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("a\\ b$c\\d", removed);

    const content = try quoteRemoveDoubleQuotedContent(std.testing.allocator, "a\\ b\\$c\\\\d");
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("a\\ b$c\\d", content);
}

test "command substitution expands inside double quotes" {
    var result = try expandWord(std.testing.allocator, "\"before-$(echo hi)-after\"", .{ .command_substitution = test_command_substitution });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("before-hi-after", result.fields[0]);

    var spaced = try expandWord(std.testing.allocator, "\"$(echo hi)\"", .{ .command_substitution = test_command_substitution });
    defer spaced.deinit();
    try std.testing.expectEqual(@as(usize, 1), spaced.fields.len);
    try std.testing.expectEqualStrings("hi", spaced.fields[0]);

    var backquote = try expandWord(std.testing.allocator, "\"before-`echo hi`-after\"", .{ .command_substitution = test_command_substitution });
    defer backquote.deinit();
    try std.testing.expectEqual(@as(usize, 1), backquote.fields.len);
    try std.testing.expectEqualStrings("before-hi-after", backquote.fields[0]);
}

fn testScriptEchoSubstitution(_: ?*anyopaque, allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return allocator.dupe(u8, script);
}

test "double-quoted command substitution may contain double quotes" {
    var parts = try parseWordParts(std.testing.allocator, "\"$(printf \"a b\")\"");
    defer parts.deinit();
    try std.testing.expectEqual(@as(usize, 1), parts.parts.len);
    try std.testing.expectEqual(WordPartKind.double_quoted, parts.parts[0].kind);
    try std.testing.expectEqualStrings("$(printf \"a b\")", parts.parts[0].value(parts.raw));

    var nested = try parseWordParts(std.testing.allocator, "\"$(echo \"n $(echo \"d)p\")\")\"");
    defer nested.deinit();
    try std.testing.expectEqual(@as(usize, 1), nested.parts.len);
    try std.testing.expectEqual(WordPartKind.double_quoted, nested.parts[0].kind);
    try std.testing.expectEqualStrings("$(echo \"n $(echo \"d)p\")\")", nested.parts[0].value(nested.raw));

    const echo_script: CommandSubstitution = .{ .runFn = testScriptEchoSubstitution };
    var rendered = try expandWord(std.testing.allocator, "\"$(cmd \"x)y\")\"", .{ .command_substitution = echo_script });
    defer rendered.deinit();
    try std.testing.expectEqual(@as(usize, 1), rendered.fields.len);
    try std.testing.expectEqualStrings("cmd \"x)y\"", rendered.fields[0]);
}

test "backquote escaped double-quote is unescaped only inside double quotes" {
    const echo_script: CommandSubstitution = .{ .runFn = testScriptEchoSubstitution };

    var quoted = try expandWord(std.testing.allocator, "\"`cmd \\\"x y\\\"`\"", .{ .command_substitution = echo_script });
    defer quoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted.fields.len);
    try std.testing.expectEqualStrings("cmd \"x y\"", quoted.fields[0]);

    var unquoted = try expandWord(std.testing.allocator, "`cmd \\\"xy\\\"`", .{ .command_substitution = echo_script });
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 2), unquoted.fields.len);
    try std.testing.expectEqualStrings("cmd", unquoted.fields[0]);
    try std.testing.expectEqualStrings("\\\"xy\\\"", unquoted.fields[1]);
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
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("1 + 2 * 3", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 9), try evalArithmetic("(1 + 2) * 3", .{}, .{}));
    try std.testing.expectEqual(@as(i64, -4), try evalArithmetic("-8 / 2", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 5), try evalArithmetic("USER_NUM + 2", test_env, .{}));
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("UNKNOWN + USER", test_env, .{}));
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("3 > 2", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("3 == 2", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("1 || 0", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("1 && 0", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 5), try evalArithmetic("(5 & 3) | 4", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 16), try evalArithmetic("1 << 4", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("0 ? 1 : 7", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 9), try evalArithmetic("1, 2, 9", .{}, .{}));
    try std.testing.expectEqual(@as(i64, -6), try evalArithmetic("~5", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 8), try evalArithmetic("010", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 16), try evalArithmetic("0x10", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 255), try evalArithmetic("0XFF", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 24), try evalArithmetic("010 + 0x10", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 55), try evalArithmetic("OCTAL_NUM + HEX_NUM", test_env, .{}));
    try std.testing.expectEqual(@as(i64, -8), try evalArithmetic("NEGATIVE_OCTAL_NUM", test_env, .{}));
    try std.testing.expectError(error.InvalidArithmetic, evalArithmetic("08", .{}, .{}));
    try std.testing.expectError(error.InvalidArithmetic, evalArithmetic("0x", .{}, .{}));

    var variable = try expandWord(std.testing.allocator, "value=$((USER_NUM + 4))", .{ .env = test_env });
    defer variable.deinit();
    try std.testing.expectEqual(@as(usize, 1), variable.fields.len);
    try std.testing.expectEqualStrings("value=7", variable.fields[0]);

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

test "pathname expansion handles slash components and dotfiles" {
    const dir = "rush-glob-dir";
    const visible = "rush-glob-dir/visible.tmp";
    const hidden = "rush-glob-dir/.hidden.tmp";
    const missing_suffix = "rush-glob-dir/*.missing";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = visible, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, visible) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hidden, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hidden) catch {};

    var slash = try expandWord(std.testing.allocator, "rush-glob-dir/*.tmp", .{ .io = std.testing.io });
    defer slash.deinit();
    try std.testing.expectEqual(@as(usize, 1), slash.fields.len);
    try std.testing.expectEqualStrings(visible, slash.fields[0]);

    var dot = try expandWord(std.testing.allocator, "rush-glob-dir/.*.tmp", .{ .io = std.testing.io });
    defer dot.deinit();
    try std.testing.expectEqual(@as(usize, 1), dot.fields.len);
    try std.testing.expectEqualStrings(hidden, dot.fields[0]);

    var unmatched = try expandWord(std.testing.allocator, missing_suffix, .{ .io = std.testing.io });
    defer unmatched.deinit();
    try std.testing.expectEqual(@as(usize, 1), unmatched.fields.len);
    try std.testing.expectEqualStrings(missing_suffix, unmatched.fields[0]);
}

test "pathname expansion handles absolute path components" {
    const dir = "/tmp/rush-absolute-glob-dir";
    const file = "/tmp/rush-absolute-glob-dir/match.tmp";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file, .data = "" });

    var result = try expandWord(std.testing.allocator, "/tmp/rush-absolute-glob-dir/*.tmp", .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings(file, result.fields[0]);
}

test "pathname expansion bracket expressions treat leading right bracket as literal" {
    const close = "rush-bracket-].tmp";
    const open = "rush-bracket-[.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = close, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = open, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, close) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, open) catch {};

    var literal = try expandWord(std.testing.allocator, "rush-bracket-[]].tmp", .{ .io = std.testing.io });
    defer literal.deinit();
    try std.testing.expectEqual(@as(usize, 1), literal.fields.len);
    try std.testing.expectEqualStrings(close, literal.fields[0]);

    var negated = try expandWord(std.testing.allocator, "rush-bracket-[!]].tmp", .{ .io = std.testing.io });
    defer negated.deinit();
    try std.testing.expectEqual(@as(usize, 1), negated.fields.len);
    try std.testing.expectEqualStrings(open, negated.fields[0]);
}

test "pathname expansion preserves unmatched patterns" {
    var result = try expandWord(std.testing.allocator, "rush-no-match-*.tmp", .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("rush-no-match-*.tmp", result.fields[0]);
}
