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

    for (parts.parts) |part| {
        const split = part.kind == .unquoted or part.kind == .parameter;
        const rendered = try renderPart(allocator, parts.raw, part, options);
        defer allocator.free(rendered);
        if (split) {
            try appendSplitText(allocator, &fields, &current, rendered);
        } else {
            try current.appendSlice(allocator, rendered);
        }
    }

    if (current.items.len != 0) {
        try fields.append(allocator, try current.toOwnedSlice(allocator));
    }

    if (options.io) |io| {
        try applyPathnameExpansion(allocator, io, &fields);
    }

    return .{
        .allocator = allocator,
        .fields = try fields.toOwnedSlice(allocator),
    };
}

pub fn expandWordScalar(allocator: std.mem.Allocator, raw: []const u8, options: Options) ![]const u8 {
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

pub fn renderWordParts(allocator: std.mem.Allocator, word: WordParts, options: Options) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (word.parts) |part| {
        const rendered = try renderPart(allocator, word.raw, part, options);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
    }

    return output.toOwnedSlice(allocator);
}

fn renderPart(allocator: std.mem.Allocator, raw: []const u8, part: WordPart, options: Options) ![]const u8 {
    return switch (part.kind) {
        .unquoted, .escaped, .single_quoted => allocator.dupe(u8, part.value(raw)),
        .double_quoted => blk: {
            const expanded = try expandParameters(allocator, part.value(raw), options.env);
            defer allocator.free(expanded);
            break :blk quoteRemove(allocator, expanded);
        },
        .parameter => renderParameter(allocator, part.value(raw), options),
        .arithmetic => blk: {
            const value = try evalArithmetic(part.value(raw));
            break :blk std.fmt.allocPrint(allocator, "{d}", .{value});
        },
        .command_substitution => blk: {
            const output = (try options.command_substitution.run(allocator, part.value(raw))) orelse try allocator.alloc(u8, 0);
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
};

const ParameterExpression = struct {
    name: []const u8,
    operator: ParameterOperator = .none,
    word: []const u8 = "",
    colon: bool = false,
};

fn renderParameter(allocator: std.mem.Allocator, expression: []const u8, options: Options) ![]const u8 {
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
    }
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
        else => return .{ .name = expression },
    };
    return .{
        .name = expression[0..name_end],
        .operator = operator,
        .word = expression[operator_index + 1 ..],
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

fn trimTrailingNewlines(output: []const u8) []const u8 {
    var end = output.len;
    while (end > 0 and output[end - 1] == '\n') end -= 1;
    return output[0..end];
}

fn appendSplitText(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        if (isDefaultIfsWhitespace(c)) {
            if (current.items.len != 0) {
                try fields.append(allocator, try current.toOwnedSlice(allocator));
            }
        } else {
            try current.append(allocator, c);
        }
    }
}

fn isDefaultIfsWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
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

pub fn expandParameters(allocator: std.mem.Allocator, raw: []const u8, env: EnvLookup) ![]const u8 {
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
            '$' => if (try expandParameterAt(allocator, raw, &index, env, &output)) {},
            else => |c| {
                try output.append(allocator, c);
                index += 1;
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

fn expandParameterAt(allocator: std.mem.Allocator, raw: []const u8, index: *usize, env: EnvLookup, output: *std.ArrayList(u8)) !bool {
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
        if (env.get(raw[name_start..name_end])) |value| try output.appendSlice(allocator, value);
        index.* = name_end + 1;
        return true;
    }

    if (isSpecialParameterChar(raw[index.*])) {
        if (env.get(raw[index.* .. index.* + 1])) |value| try output.appendSlice(allocator, value);
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
    if (env.get(raw[name_start..index.*])) |value| try output.appendSlice(allocator, value);
    return true;
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
                    if (raw[index] == '\\' and index + 1 < raw.len) {
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
    return null;
}

const test_env: EnvLookup = .{ .lookupFn = testLookup };

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

test "field splitting preserves quoted expansion results" {
    var result = try expandWord(std.testing.allocator, "\"$USER two\" 'three four'", .{ .env = test_env });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.fields.len);
    try std.testing.expectEqualStrings("rush-user two", result.fields[0]);
    try std.testing.expectEqualStrings("three four", result.fields[1]);
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
