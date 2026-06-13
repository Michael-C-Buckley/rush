//! POSIX-oriented shell word expansion phases.
//!
//! This module intentionally exposes phases separately so Bash-specific behavior
//! can be added later without baking it into parsing or execution IR.

const std = @import("std");
const zig_builtin = @import("builtin");
const compat = @import("compat.zig");
const parser = @import("parser.zig");

pub const EnvLookup = struct {
    context: ?*const anyopaque = null,
    lookupFn: ?*const fn (?*const anyopaque, []const u8) ?[]const u8 = null,

    pub fn get(self: EnvLookup, name: []const u8) ?[]const u8 {
        const lookup = self.lookupFn orelse return null;
        return lookup(self.context, name);
    }
};

pub const VariableNames = struct {
    context: ?*const anyopaque = null,
    countFn: ?*const fn (?*const anyopaque) usize = null,
    nameFn: ?*const fn (?*const anyopaque, usize) ?[]const u8 = null,

    pub fn count(self: VariableNames) usize {
        const count_fn = self.countFn orelse return 0;
        return count_fn(self.context);
    }

    pub fn name(self: VariableNames, ordinal: usize) ?[]const u8 {
        const name_fn = self.nameFn orelse return null;
        return name_fn(self.context, ordinal);
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

pub const ArrayLookup = struct {
    context: ?*const anyopaque = null,
    lookupFn: ?*const fn (?*const anyopaque, []const u8, usize) ?[]const u8 = null,
    lenFn: ?*const fn (?*const anyopaque, []const u8) usize = null,
    keyFn: ?*const fn (?*const anyopaque, []const u8, usize) ?usize = null,
    valueFn: ?*const fn (?*const anyopaque, []const u8, usize) ?[]const u8 = null,
    maxIndexFn: ?*const fn (?*const anyopaque, []const u8) ?usize = null,
    existsFn: ?*const fn (?*const anyopaque, []const u8) bool = null,

    pub fn get(self: ArrayLookup, name: []const u8, index: usize) ?[]const u8 {
        const lookup = self.lookupFn orelse return null;
        return lookup(self.context, name, index);
    }

    pub fn len(self: ArrayLookup, name: []const u8) usize {
        const len_fn = self.lenFn orelse return 0;
        return len_fn(self.context, name);
    }

    pub fn key(self: ArrayLookup, name: []const u8, ordinal: usize) ?usize {
        const key_fn = self.keyFn orelse return null;
        return key_fn(self.context, name, ordinal);
    }

    pub fn value(self: ArrayLookup, name: []const u8, ordinal: usize) ?[]const u8 {
        const value_fn = self.valueFn orelse return null;
        return value_fn(self.context, name, ordinal);
    }

    pub fn maxIndex(self: ArrayLookup, name: []const u8) ?usize {
        const max_index_fn = self.maxIndexFn orelse return null;
        return max_index_fn(self.context, name);
    }

    pub fn exists(self: ArrayLookup, name: []const u8) bool {
        const exists_fn = self.existsFn orelse return false;
        return exists_fn(self.context, name);
    }
};

pub const DiagnosticSink = struct {
    context: ?*anyopaque = null,
    appendFn: ?*const fn (?*anyopaque, []const u8, []const u8) anyerror!void = null,

    pub fn append(self: DiagnosticSink, name: []const u8, message: []const u8) !bool {
        const append_fn = self.appendFn orelse return false;
        try append_fn(self.context, name, message);
        return true;
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

pub const ArithmeticError = struct {
    expression: []const u8 = "",
    message: []const u8 = "",

    pub fn clear(self: *ArithmeticError, allocator: std.mem.Allocator) void {
        if (self.expression.len != 0) allocator.free(self.expression);
        if (self.message.len != 0) allocator.free(self.message);
        self.* = .{};
    }
};

pub const Options = struct {
    env: EnvLookup = .{},
    variable_names: VariableNames = .{},
    env_set: EnvSet = .{},
    arrays: ArrayLookup = .{},
    diagnostic_sink: DiagnosticSink = .{},
    io: ?std.Io = null,
    features: compat.Features = .{},
    command_substitution: CommandSubstitution = .{},
    positionals: []const []const u8 = &.{},
    option_flags: []const u8 = "",
    pathname_expansion: bool = true,
    pathname_nullglob: bool = false,
    pathname_dotglob: bool = false,
    extglob: bool = false,
    patsub_replacement: bool = true,
    nounset: bool = false,
    parameter_error: ?*ParameterError = null,
    arithmetic_error: ?*ArithmeticError = null,
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
    dollar_single_quoted,
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

const ExpandedWordFields = struct {
    fields: []const []const u8,
    quoted_glob: bool = false,

    fn deinit(self: *ExpandedWordFields, allocator: std.mem.Allocator) void {
        for (self.fields) |field| allocator.free(field);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

pub fn expandWord(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpansionResult {
    _ = options.features;
    const tilde_expanded = try expandTilde(allocator, raw, options.env);
    defer allocator.free(tilde_expanded);

    var parts = try parseWordParts(allocator, tilde_expanded);
    defer parts.deinit();
    const pathname_expansion_safe = !hasQuotedGlobSyntax(parts, .{ .extglob = options.extglob });

    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var force_current_field = false;
    var quoted_expansion_glob = false;

    const ifs = options.env.get("IFS") orelse " \t\n";
    try appendWordPartsUnquoted(allocator, &fields, &current, &force_current_field, &quoted_expansion_glob, parts, options, ifs, false);

    if (current.items.len != 0 or force_current_field) {
        try fields.append(allocator, try current.toOwnedSlice(allocator));
    }

    if (options.pathname_expansion and pathname_expansion_safe and !quoted_expansion_glob) {
        if (options.io) |io| {
            try applyPathnameExpansion(allocator, io, &fields, .{ .nullglob = options.pathname_nullglob, .dotglob = options.pathname_dotglob, .extglob = options.extglob });
        }
    }

    return .{
        .allocator = allocator,
        .fields = try fields.toOwnedSlice(allocator),
    };
}

fn expandWordFieldsNoPathname(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpandedWordFields {
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
    var quoted_expansion_glob = false;

    const ifs = options.env.get("IFS") orelse " \t\n";
    try appendWordPartsUnquoted(allocator, &fields, &current, &force_current_field, &quoted_expansion_glob, parts, options, ifs, true);

    if (current.items.len != 0 or force_current_field) {
        try fields.append(allocator, try current.toOwnedSlice(allocator));
    }

    return .{
        .fields = try fields.toOwnedSlice(allocator),
        .quoted_glob = quoted_expansion_glob,
    };
}

fn appendWordPartsUnquoted(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_expansion_glob: *bool, parts: WordParts, options: Options, ifs: []const u8, operator_word: bool) !void {
    for (parts.parts) |part| {
        if (part.kind == .double_quoted) {
            try appendDoubleQuotedText(allocator, fields, current, force_current_field, quoted_expansion_glob, part.value(parts.raw), options, ifs);
            continue;
        }
        if (part.kind == .single_quoted) force_current_field.* = true;
        if (part.kind == .dollar_single_quoted) force_current_field.* = true;
        const split = part.kind == .parameter or part.kind == .command_substitution or part.kind == .arithmetic or (operator_word and part.kind == .unquoted);
        if (part.kind == .parameter) {
            try appendParameterExpansionUnquoted(allocator, fields, current, force_current_field, quoted_expansion_glob, part.value(parts.raw), options, ifs);
            continue;
        }

        const rendered = try renderPart(allocator, parts.raw, part, options);
        defer allocator.free(rendered);
        if (split) {
            try appendSplitText(allocator, fields, current, rendered, ifs);
        } else {
            if (part.kind == .dollar_single_quoted and hasGlobSyntax(rendered)) quoted_expansion_glob.* = true;
            try current.appendSlice(allocator, rendered);
        }
    }
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

pub fn expandParametersScalar(allocator: std.mem.Allocator, raw: []const u8, options: Options) anyerror![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    var literal_start: usize = 0;
    while (index < raw.len) {
        if (raw[index] != '$' and raw[index] != '`') {
            index += 1;
            continue;
        }

        const part = (try substitutionPart(allocator, raw, index)) orelse {
            index += 1;
            continue;
        };
        if (part.kind != .parameter) {
            index = part.span.end;
            continue;
        }

        try output.appendSlice(allocator, raw[literal_start..index]);
        const rendered = try renderParameter(allocator, part.value(raw), options, false);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);

        index = part.span.end;
        literal_start = index;
    }
    try output.appendSlice(allocator, raw[literal_start..]);

    return output.toOwnedSlice(allocator);
}

const WordPartParseOptions = struct {
    single_quotes: bool = true,
};

pub fn parseWordParts(allocator: std.mem.Allocator, raw: []const u8) !WordParts {
    return parseWordPartsWithOptions(allocator, raw, .{});
}

fn parseParameterWordPartsInDoubleQuotes(allocator: std.mem.Allocator, raw: []const u8) !WordParts {
    return parseWordPartsWithOptions(allocator, raw, .{ .single_quotes = false });
}

fn parseWordPartsWithOptions(allocator: std.mem.Allocator, raw: []const u8, parse_options: WordPartParseOptions) !WordParts {
    var parts: std.ArrayList(WordPart) = .empty;
    errdefer parts.deinit(allocator);

    var index: usize = 0;
    var unquoted_start: ?usize = null;
    while (index < raw.len) {
        switch (raw[index]) {
            '$' => if (index + 1 < raw.len and raw[index + 1] == '\'') {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                const start = index;
                index += 2;
                const value_start = index;
                while (index < raw.len) {
                    switch (raw[index]) {
                        '\\' => {
                            index += 1;
                            if (index < raw.len) index += 1;
                        },
                        '\'' => break,
                        else => index += 1,
                    }
                }
                const value_end = index;
                if (index < raw.len) index += 1;
                try parts.append(allocator, .{
                    .kind = .dollar_single_quoted,
                    .span = .init(start, index),
                    .value_span = .init(value_start, value_end),
                });
            } else if (try substitutionPart(allocator, raw, index)) |part| {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                try parts.append(allocator, part);
                index = part.span.end;
            } else {
                if (unquoted_start == null) unquoted_start = index;
                index += 1;
            },
            '\'' => if (parse_options.single_quotes) {
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
            } else {
                if (unquoted_start == null) unquoted_start = index;
                index += 1;
            },
            '"' => {
                try flushUnquoted(allocator, raw, &parts, &unquoted_start, index);
                const start = index;
                const end = (try doubleQuotedSpanEnd(allocator, raw, index)) orelse raw.len;
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
            '`' => if (try substitutionPart(allocator, raw, index)) |part| {
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

fn substitutionPart(allocator: std.mem.Allocator, raw: []const u8, start: usize) !?WordPart {
    return switch (try parser.shellSubstitutionAt(allocator, raw, raw.len, start)) {
        .none, .incomplete => null,
        .complete => |substitution| .{
            .kind = switch (substitution.kind) {
                .parameter => .parameter,
                .arithmetic => .arithmetic,
                .command_substitution => .command_substitution,
            },
            .span = .init(substitution.span.start, substitution.span.end),
            .value_span = .init(substitution.value_span.start, substitution.value_span.end),
        },
    };
}

/// Returns the index just past the closing double quote of the
/// double-quoted string starting at `start`, or null when unterminated.
/// Embedded expansions keep their special meaning inside double quotes
/// (POSIX XCU 2.2.3), so quotes inside them do not close the string.
fn doubleQuotedSpanEnd(allocator: std.mem.Allocator, raw: []const u8, start: usize) !?usize {
    std.debug.assert(raw[start] == '"');
    var index = start + 1;
    while (index < raw.len) {
        switch (raw[index]) {
            '"' => return index + 1,
            '\\' => index += if (index + 1 < raw.len) 2 else 1,
            '$', '`' => {
                const part = try substitutionPart(allocator, raw, index);
                index = if (part) |p| p.span.end else index + 1;
            },
            else => index += 1,
        }
    }
    return null;
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
        .dollar_single_quoted => renderDollarSingleQuotedContent(allocator, part.value(raw)),
        .escaped => if (std.mem.eql(u8, part.value(raw), "\n")) allocator.dupe(u8, "") else allocator.dupe(u8, part.value(raw)),
        .double_quoted => renderDoubleQuotedContent(allocator, part.value(raw), options),
        .parameter => renderParameter(allocator, part.value(raw), options, false),
        .arithmetic => renderArithmetic(allocator, part.source(raw), part.value(raw), options),
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

fn renderArithmetic(allocator: std.mem.Allocator, source: []const u8, expression: []const u8, options: Options) anyerror![]const u8 {
    const expanded_expression = try expandArithmeticExpression(allocator, expression, options);
    defer allocator.free(expanded_expression);
    const value = evalArithmetic(expanded_expression, options.env, options.env_set) catch |err| return arithmeticExpansionFailed(allocator, source, err, options);
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn expandArithmeticExpression(allocator: std.mem.Allocator, expression: []const u8, options: Options) anyerror![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < expression.len) {
        if (expression[index] == '\\' and index + 1 < expression.len and isArithmeticBackslashEscaped(expression[index + 1])) {
            if (expression[index + 1] == '\n') {
                index += 2;
                continue;
            }
            try output.append(allocator, expression[index + 1]);
            index += 2;
            continue;
        }

        const part = (if (expression[index] == '$' or expression[index] == '`') try substitutionPart(allocator, expression, index) else null) orelse {
            try output.append(allocator, expression[index]);
            index += 1;
            continue;
        };

        const rendered = try renderArithmeticExpressionExpansion(allocator, expression, part, options);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
        index = part.span.end;
    }

    return output.toOwnedSlice(allocator);
}

fn renderArithmeticExpressionExpansion(allocator: std.mem.Allocator, raw: []const u8, part: WordPart, options: Options) anyerror![]const u8 {
    return switch (part.kind) {
        .parameter => renderParameter(allocator, part.value(raw), options, true),
        .arithmetic => renderArithmetic(allocator, part.source(raw), part.value(raw), options),
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

fn arithmeticExpansionFailed(allocator: std.mem.Allocator, source: []const u8, err: anyerror, options: Options) anyerror {
    const message = switch (err) {
        error.InvalidArithmetic => "invalid arithmetic expression",
        error.DivisionByZero => "division by zero",
        error.Overflow => "arithmetic overflow",
        else => return err,
    };

    if (options.arithmetic_error) |arithmetic_error| {
        const expression = try allocator.dupe(u8, source);
        errdefer allocator.free(expression);
        const owned_message = try allocator.dupe(u8, message);
        arithmetic_error.clear(allocator);
        arithmetic_error.expression = expression;
        arithmetic_error.message = owned_message;
    }
    return error.ArithmeticExpansionFailed;
}

const ParameterOperator = enum {
    none,
    invalid,
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

// Syntax-level representation for the inside of `${...}`. Rendering still
// adapts this to ParameterExpression so future extension forms can be added
// without changing the current POSIX behavior or diagnostics.
const ParameterTargetKind = enum {
    name,
    positional,
    special,
    unknown,
};

const ParameterTarget = struct {
    kind: ParameterTargetKind,
    text: []const u8,
};

const ParameterWordOperation = struct {
    kind: ParameterOperator,
    colon: bool,
    word: []const u8,
};

const ParameterPatternOperation = struct {
    kind: ParameterOperator,
    word: []const u8,
};

const ParameterSubstringOperation = struct {
    offset: []const u8,
    length: ?[]const u8 = null,
};

const ParameterReplacementKind = enum {
    first,
    global,
    prefix,
    suffix,
};

const ParameterReplacementOperation = struct {
    kind: ParameterReplacementKind,
    pattern: []const u8,
    replacement: []const u8,
};

const ParameterReplacementText = struct {
    text: []const u8,
    replace_match: []const bool,

    fn deinit(self: *ParameterReplacementText, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.replace_match);
        self.* = undefined;
    }
};

const ParameterCaseKind = enum {
    uppercase_first,
    uppercase_all,
    lowercase_first,
    lowercase_all,
};

const ParameterCaseOperation = struct {
    kind: ParameterCaseKind,
    pattern: ?[]const u8 = null,
};

const ParameterArrayWholeKind = enum {
    at,
    star,
};

const ParameterArrayIndexOperation = struct {
    index: []const u8,
};

const ParameterArrayWholeOperation = struct {
    kind: ParameterArrayWholeKind,
};

const ParameterNamePrefixOperation = struct {
    kind: ParameterArrayWholeKind,
};

const ParameterOperation = union(enum) {
    value,
    length,
    indirect,
    name_prefix: ParameterNamePrefixOperation,
    word: ParameterWordOperation,
    pattern: ParameterPatternOperation,
    substring: ParameterSubstringOperation,
    replacement: ParameterReplacementOperation,
    case_modification: ParameterCaseOperation,
    array_index: ParameterArrayIndexOperation,
    array_element_length: ParameterArrayIndexOperation,
    array_values: ParameterArrayWholeOperation,
    array_keys: ParameterArrayWholeOperation,
    array_length: ParameterArrayWholeOperation,
};

const ParameterExpansion = struct {
    target: ParameterTarget,
    operation: ParameterOperation,
    array_subscript: ?BashArraySubscript = null,
};

const ParameterExpansionSyntax = union(enum) {
    invalid,
    expansion: ParameterExpansion,
};

const ParameterExpression = struct {
    name: []const u8,
    operator: ParameterOperator = .none,
    word: []const u8 = "",
    colon: bool = false,
    indirect: bool = false,
    name_prefix: ?ParameterArrayWholeKind = null,
    substring: ?ParameterSubstringOperation = null,
    replacement: ?ParameterReplacementOperation = null,
    case_modification: ?ParameterCaseOperation = null,
    array_index: ?[]const u8 = null,
    array_whole: ?ParameterArrayWholeKind = null,
    array_keys: ?ParameterArrayWholeKind = null,
};

const SegmentedText = struct {
    text: []const u8,
    split: []const bool,
    force_field: bool = false,
    quoted_glob: bool = false,

    fn deinit(self: *SegmentedText, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.split);
        self.* = undefined;
    }
};

const SegmentedTextBuilder = struct {
    text: std.ArrayList(u8) = .empty,
    split: std.ArrayList(bool) = .empty,
    force_field: bool = false,
    quoted_glob: bool = false,

    fn deinit(self: *SegmentedTextBuilder, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.split.deinit(allocator);
        self.* = undefined;
    }

    fn append(self: *SegmentedTextBuilder, allocator: std.mem.Allocator, rendered: []const u8, split_enabled: bool, force_field: bool, quoted_glob: bool) !void {
        try self.text.appendSlice(allocator, rendered);
        for (rendered) |_| try self.split.append(allocator, split_enabled);
        self.force_field = self.force_field or force_field;
        self.quoted_glob = self.quoted_glob or quoted_glob;
    }

    fn appendSegmented(self: *SegmentedTextBuilder, allocator: std.mem.Allocator, rendered: SegmentedText) !void {
        try self.text.appendSlice(allocator, rendered.text);
        try self.split.appendSlice(allocator, rendered.split);
        self.force_field = self.force_field or rendered.force_field;
        self.quoted_glob = self.quoted_glob or rendered.quoted_glob;
    }

    fn toOwnedSegmented(self: *SegmentedTextBuilder, allocator: std.mem.Allocator) !SegmentedText {
        const owned_text = try self.text.toOwnedSlice(allocator);
        errdefer allocator.free(owned_text);
        return .{
            .text = owned_text,
            .split = try self.split.toOwnedSlice(allocator),
            .force_field = self.force_field,
            .quoted_glob = self.quoted_glob,
        };
    }
};

fn renderParameter(allocator: std.mem.Allocator, expression: []const u8, options: Options, in_double_quotes: bool) anyerror![]const u8 {
    const parsed = parseParameterExpression(expression, options.features);
    if (parsed.operator == .invalid) return invalidParameterExpansion(allocator, options);
    if (parsed.name_prefix) |kind| return renderNamePrefixJoined(allocator, parsed.name, kind, options);
    if (parsed.indirect) return renderIndirectParameter(allocator, parsed.name, options);
    if (parsed.array_keys) |kind| return renderArrayKeysJoined(allocator, parsed.name, kind, options, in_double_quotes);
    if (parsed.array_whole) |kind| {
        if (parsed.operator == .length) return std.fmt.allocPrint(allocator, "{d}", .{options.arrays.len(parsed.name)});
        if (hasParameterStringOperation(parsed)) {
            var values = try renderArrayStringOperationValues(allocator, parsed.name, kind, parsed, options, in_double_quotes);
            defer values.deinit(allocator);
            return joinValues(allocator, values.fields, arrayValueScalarJoinSeparator(kind, options));
        }
        return renderArrayValuesJoined(allocator, parsed.name, kind, options);
    }
    if (parsed.array_index) |index_text| {
        if (parsed.operator == .length) return renderArrayElementLength(allocator, parsed.name, index_text, options);
        const base = try renderArrayElement(allocator, parsed.name, index_text, options);
        defer allocator.free(base);
        if (hasParameterStringOperation(parsed)) return renderStringOperation(allocator, base, parsed, options, in_double_quotes);
        return allocator.dupe(u8, base);
    }

    if (parsed.substring) |operation| {
        if (isWholePositionalParameterName(parsed.name) and options.features.isBash()) {
            const values = try positionalSliceValues(allocator, operation, options);
            defer allocator.free(values);
            return joinPositionals(allocator, values, positionalSliceScalarJoinSeparator(parsed.name, in_double_quotes, options));
        }
    }

    if (parsed.operator == .none and isWholePositionalParameterName(parsed.name)) {
        return renderWholePositionalsJoined(allocator, parsed.name, options);
    }

    const digit_name = isDigitParameterName(parsed.name);
    const value = if (digit_name)
        digitParameterValue(parsed.name, options)
    else
        specialParameterValue(parsed.name, options) orelse options.env.get(parsed.name);
    const is_set = value != null;
    const is_null = if (value) |text| text.len == 0 else true;

    if (parsed.substring) |operation| {
        const base = value orelse {
            if (options.nounset and !isNounsetExemptParameter(parsed.name)) return error.NounsetParameter;
            return allocator.alloc(u8, 0);
        };
        return renderSubstring(allocator, base, operation, options);
    }
    if (parsed.replacement) |operation| {
        const base = value orelse {
            if (options.nounset and !isNounsetExemptParameter(parsed.name)) return error.NounsetParameter;
            return allocator.alloc(u8, 0);
        };
        return renderReplacement(allocator, base, operation, options, in_double_quotes);
    }
    if (parsed.case_modification) |operation| {
        const base = value orelse {
            if (options.nounset and !isNounsetExemptParameter(parsed.name)) return error.NounsetParameter;
            return allocator.alloc(u8, 0);
        };
        return renderCaseModification(allocator, base, operation, options);
    }

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
            return expandParameterWord(allocator, parsed.word, options, in_double_quotes);
        },
        .assign_default => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) return allocator.dupe(u8, value.?);
            if (!isAssignableParameterName(parsed.name)) return parameterAssignmentInvalid(allocator, options, parsed.name);
            const expanded = try expandParameterWord(allocator, parsed.word, options, in_double_quotes);
            errdefer allocator.free(expanded);
            try options.env_set.set(parsed.name, expanded);
            return expanded;
        },
        .alternate_value => {
            if (!parameterHasUsableValue(is_set, is_null, parsed.colon)) return allocator.alloc(u8, 0);
            return expandParameterWord(allocator, parsed.word, options, in_double_quotes);
        },
        .error_if_unset => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) return allocator.dupe(u8, value.?);
            const message = if (parsed.word.len != 0)
                try expandParameterWord(allocator, parsed.word, options, in_double_quotes)
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
            const base = value orelse blk: {
                if (options.nounset and !isNounsetExemptParameter(parsed.name)) return error.NounsetParameter;
                break :blk "";
            };
            var pattern = try expandPatternWord(allocator, parsed.word, options);
            defer pattern.deinit(allocator);
            return removePattern(allocator, base, pattern, parsed.operator, options.extglob);
        },
        .invalid => unreachable,
    }
}

fn hasParameterStringOperation(parsed: ParameterExpression) bool {
    return parsed.substring != null or parsed.replacement != null or parsed.case_modification != null;
}

fn renderParameterSegmented(allocator: std.mem.Allocator, expression: []const u8, options: Options) anyerror!SegmentedText {
    const parsed = parseParameterExpression(expression, options.features);
    if (parsed.operator == .invalid) return invalidParameterExpansion(allocator, options);
    if (parsed.name_prefix != null or parsed.indirect or parsed.array_keys != null or parsed.array_whole != null or parsed.array_index != null) {
        const rendered = try renderParameter(allocator, expression, options, false);
        defer allocator.free(rendered);
        return segmentedFromText(allocator, rendered, true, false, false);
    }

    const digit_name = isDigitParameterName(parsed.name);
    const value = if (digit_name)
        digitParameterValue(parsed.name, options)
    else
        specialParameterValue(parsed.name, options) orelse options.env.get(parsed.name);
    const is_set = value != null;
    const is_null = if (value) |text| text.len == 0 else true;

    switch (parsed.operator) {
        .none, .length, .error_if_unset, .remove_small_suffix, .remove_large_suffix, .remove_small_prefix, .remove_large_prefix => {
            const rendered = try renderParameter(allocator, expression, options, false);
            defer allocator.free(rendered);
            return segmentedFromText(allocator, rendered, true, false, false);
        },
        .default_value => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) return segmentedFromText(allocator, value.?, true, false, false);
            return expandParameterWordSegmented(allocator, parsed.word, options);
        },
        .assign_default => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) return segmentedFromText(allocator, value.?, true, false, false);
            if (!isAssignableParameterName(parsed.name)) return parameterAssignmentInvalid(allocator, options, parsed.name);
            const expanded = try expandParameterWord(allocator, parsed.word, options, false);
            defer allocator.free(expanded);
            try options.env_set.set(parsed.name, expanded);
            return segmentedFromText(allocator, expanded, true, false, false);
        },
        .alternate_value => {
            if (!parameterHasUsableValue(is_set, is_null, parsed.colon)) return segmentedFromText(allocator, "", true, false, false);
            return expandParameterWordSegmented(allocator, parsed.word, options);
        },
        .invalid => unreachable,
    }
}

fn renderSubstring(allocator: std.mem.Allocator, value: []const u8, operation: ParameterSubstringOperation, options: Options) anyerror![]const u8 {
    const value_len = std.math.cast(i64, value.len) orelse std.math.maxInt(i64);
    const offset = try evaluateArrayIndexValue(allocator, operation.offset, options);
    const start_value = if (offset < 0) value_len + offset else offset;
    if (start_value < 0 or start_value > value_len) return allocator.alloc(u8, 0);
    const start: usize = @intCast(start_value);

    const end = if (operation.length) |length_expression| blk: {
        const length = try evaluateArrayIndexValue(allocator, length_expression, options);
        if (length < 0) {
            const end_value = value_len + length;
            if (end_value < start_value) return badSubstringExpressionExpansion(allocator, options, length_expression);
            break :blk @as(usize, @intCast(end_value));
        }
        const available = value.len - start;
        const length_usize = std.math.cast(usize, length) orelse available;
        break :blk start + @min(length_usize, available);
    } else value.len;

    return allocator.dupe(u8, value[start..end]);
}

fn renderStringOperation(allocator: std.mem.Allocator, value: []const u8, parsed: ParameterExpression, options: Options, in_double_quotes: bool) anyerror![]const u8 {
    if (parsed.substring) |operation| return renderSubstring(allocator, value, operation, options);
    if (parsed.replacement) |operation| return renderReplacement(allocator, value, operation, options, in_double_quotes);
    if (parsed.case_modification) |operation| return renderCaseModification(allocator, value, operation, options);
    unreachable;
}

fn badSubstringExpressionExpansion(allocator: std.mem.Allocator, options: Options, expression: []const u8) anyerror {
    if (options.parameter_error) |parameter_error| {
        const name = try allocator.dupe(u8, expression);
        errdefer allocator.free(name);
        const message = try allocator.dupe(u8, "substring expression < 0");
        parameter_error.clear(allocator);
        parameter_error.name = name;
        parameter_error.message = message;
    }
    return error.ParameterExpansionFailed;
}

fn renderReplacement(allocator: std.mem.Allocator, value: []const u8, operation: ParameterReplacementOperation, options: Options, in_double_quotes: bool) anyerror![]const u8 {
    var pattern = try expandPatternWord(allocator, operation.pattern, options);
    defer pattern.deinit(allocator);

    var replacement = try expandParameterReplacementWord(allocator, operation.replacement, options, in_double_quotes);
    defer replacement.deinit(allocator);

    return replacePattern(allocator, value, pattern, replacement, operation.kind, options.extglob);
}

fn renderCaseModification(allocator: std.mem.Allocator, value: []const u8, operation: ParameterCaseOperation, options: Options) ![]const u8 {
    var pattern = if (operation.pattern) |pattern_text|
        try expandPatternWord(allocator, pattern_text, options)
    else
        try anySingleCharacterPattern(allocator);
    defer pattern.deinit(allocator);

    return renderCaseModificationWithPattern(allocator, value, operation.kind, pattern, options.extglob);
}

fn renderCaseModificationWithPattern(allocator: std.mem.Allocator, value: []const u8, kind: ParameterCaseKind, pattern: ExpansionPattern, extglob: bool) ![]const u8 {
    const output = try allocator.dupe(u8, value);
    errdefer allocator.free(output);

    switch (kind) {
        .uppercase_first => {
            if (output.len > 0 and casePatternMatchesByte(pattern, output[0], extglob)) output[0] = std.ascii.toUpper(output[0]);
        },
        .uppercase_all => {
            for (output) |*byte| {
                if (casePatternMatchesByte(pattern, byte.*, extglob)) byte.* = std.ascii.toUpper(byte.*);
            }
        },
        .lowercase_first => {
            if (output.len > 0 and casePatternMatchesByte(pattern, output[0], extglob)) output[0] = std.ascii.toLower(output[0]);
        },
        .lowercase_all => {
            for (output) |*byte| {
                if (casePatternMatchesByte(pattern, byte.*, extglob)) byte.* = std.ascii.toLower(byte.*);
            }
        },
    }
    return output;
}

fn anySingleCharacterPattern(allocator: std.mem.Allocator) !ExpansionPattern {
    const text = try allocator.dupe(u8, "?");
    errdefer allocator.free(text);
    const special = try allocator.alloc(bool, text.len);
    @memset(special, true);
    return .{ .text = text, .special = special };
}

fn casePatternMatchesByte(pattern: ExpansionPattern, byte: u8, extglob: bool) bool {
    const text = [_]u8{byte};
    return globPatternMatchesWithOptions(pattern, &text, .{ .extglob = extglob });
}

const PatternMatch = struct {
    start: usize,
    end: usize,
};

fn replacePattern(allocator: std.mem.Allocator, value: []const u8, pattern: ExpansionPattern, replacement: ParameterReplacementText, kind: ParameterReplacementKind, extglob: bool) ![]const u8 {
    return switch (kind) {
        .first => replaceFirstPattern(allocator, value, pattern, replacement, extglob),
        .global => replaceGlobalPattern(allocator, value, pattern, replacement, extglob),
        .prefix => replacePrefixPattern(allocator, value, pattern, replacement, extglob),
        .suffix => replaceSuffixPattern(allocator, value, pattern, replacement, extglob),
    };
}

fn replaceFirstPattern(allocator: std.mem.Allocator, value: []const u8, pattern: ExpansionPattern, replacement: ParameterReplacementText, extglob: bool) ![]const u8 {
    const match = findPatternMatch(value, pattern, 0, extglob) orelse return allocator.dupe(u8, value);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, value[0..match.start]);
    try appendExpandedReplacement(allocator, &output, replacement, value[match.start..match.end]);
    try output.appendSlice(allocator, value[match.end..]);
    return output.toOwnedSlice(allocator);
}

fn replaceGlobalPattern(allocator: std.mem.Allocator, value: []const u8, pattern: ExpansionPattern, replacement: ParameterReplacementText, extglob: bool) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < value.len) {
        const match = findPatternMatch(value, pattern, cursor, extglob) orelse break;
        try output.appendSlice(allocator, value[cursor..match.start]);
        try appendExpandedReplacement(allocator, &output, replacement, value[match.start..match.end]);
        if (match.end == match.start) {
            if (match.end < value.len) {
                try output.append(allocator, value[match.end]);
                cursor = match.end + 1;
                continue;
            }
            cursor = match.end;
            break;
        }
        cursor = match.end;
    }
    try output.appendSlice(allocator, value[cursor..]);
    return output.toOwnedSlice(allocator);
}

fn replacePrefixPattern(allocator: std.mem.Allocator, value: []const u8, pattern: ExpansionPattern, replacement: ParameterReplacementText, extglob: bool) ![]const u8 {
    const match_end = findPrefixPatternMatch(value, pattern, extglob) orelse return allocator.dupe(u8, value);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendExpandedReplacement(allocator, &output, replacement, value[0..match_end]);
    try output.appendSlice(allocator, value[match_end..]);
    return output.toOwnedSlice(allocator);
}

fn replaceSuffixPattern(allocator: std.mem.Allocator, value: []const u8, pattern: ExpansionPattern, replacement: ParameterReplacementText, extglob: bool) ![]const u8 {
    const match_start = findSuffixPatternMatch(value, pattern, extglob) orelse return allocator.dupe(u8, value);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, value[0..match_start]);
    try appendExpandedReplacement(allocator, &output, replacement, value[match_start..]);
    return output.toOwnedSlice(allocator);
}

fn appendExpandedReplacement(allocator: std.mem.Allocator, output: *std.ArrayList(u8), replacement: ParameterReplacementText, match: []const u8) !void {
    std.debug.assert(replacement.text.len == replacement.replace_match.len);

    var index: usize = 0;
    while (index < replacement.text.len) {
        const byte = replacement.text[index];
        if (byte == '&' and replacement.replace_match[index]) {
            try output.appendSlice(allocator, match);
            index += 1;
            continue;
        }
        if (byte == '\\' and replacement.replace_match[index] and index + 1 < replacement.text.len and replacement.replace_match[index + 1]) {
            const escaped = replacement.text[index + 1];
            if (escaped == '&' or escaped == '\\') {
                try output.append(allocator, escaped);
                index += 2;
                continue;
            }
        }

        try output.append(allocator, byte);
        index += 1;
    }
}

fn findPatternMatch(value: []const u8, pattern: ExpansionPattern, start_index: usize, extglob: bool) ?PatternMatch {
    var start = start_index;
    while (start <= value.len) : (start += 1) {
        var end = value.len;
        while (end >= start) {
            if (globPatternMatchesWithOptions(pattern, value[start..end], .{ .extglob = extglob })) return .{ .start = start, .end = end };
            if (end == start) break;
            end -= 1;
        }
    }
    return null;
}

fn findPrefixPatternMatch(value: []const u8, pattern: ExpansionPattern, extglob: bool) ?usize {
    var end = value.len;
    while (true) {
        if (globPatternMatchesWithOptions(pattern, value[0..end], .{ .extglob = extglob })) return end;
        if (end == 0) break;
        end -= 1;
    }
    return null;
}

fn findSuffixPatternMatch(value: []const u8, pattern: ExpansionPattern, extglob: bool) ?usize {
    var start: usize = 0;
    while (start <= value.len) : (start += 1) {
        if (globPatternMatchesWithOptions(pattern, value[start..], .{ .extglob = extglob })) return start;
    }
    return null;
}

fn renderArrayElement(allocator: std.mem.Allocator, name: []const u8, index_text: []const u8, options: Options) anyerror![]const u8 {
    const index = (try evaluateRecoverableArrayElementIndex(allocator, name, index_text, options, name)) orelse return allocator.alloc(u8, 0);
    if (options.arrays.get(name, index)) |value| return allocator.dupe(u8, value);
    if (options.nounset) return error.NounsetParameter;
    return allocator.alloc(u8, 0);
}

fn renderArrayElementLength(allocator: std.mem.Allocator, name: []const u8, index_text: []const u8, options: Options) anyerror![]const u8 {
    const diagnostic_name = try std.fmt.allocPrint(allocator, "{s}]", .{index_text});
    defer allocator.free(diagnostic_name);
    const value = try evaluateArrayIndexValue(allocator, index_text, options);
    const index = if (value < 0) blk: {
        if (normalizeNegativeArrayIndex(name, value, options)) |index| break :blk index;
        if (!options.arrays.exists(name)) return allocator.dupe(u8, "0");
        return badArraySubscriptExpansion(allocator, options, diagnostic_name);
    } else std.math.cast(usize, value) orelse return badArraySubscriptExpansion(allocator, options, diagnostic_name);
    if (options.arrays.get(name, index)) |array_value| return std.fmt.allocPrint(allocator, "{d}", .{array_value.len});
    if (options.nounset) return error.NounsetParameter;
    return allocator.dupe(u8, "0");
}

fn renderArrayValuesJoined(allocator: std.mem.Allocator, name: []const u8, kind: ParameterArrayWholeKind, options: Options) ![]const u8 {
    return joinArrayValues(allocator, name, options, arrayValueScalarJoinSeparator(kind, options));
}

fn renderArrayStringOperationValues(allocator: std.mem.Allocator, name: []const u8, kind: ParameterArrayWholeKind, parsed: ParameterExpression, options: Options, in_double_quotes: bool) anyerror!ExpandedWordFields {
    _ = kind;
    if (parsed.substring) |operation| return arraySliceValues(allocator, name, operation, options);

    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    if (parsed.replacement) |operation| {
        var pattern = try expandPatternWord(allocator, operation.pattern, options);
        defer pattern.deinit(allocator);

        var replacement = try expandParameterReplacementWord(allocator, operation.replacement, options, in_double_quotes);
        defer replacement.deinit(allocator);

        const len = options.arrays.len(name);
        for (0..len) |ordinal| {
            const value = options.arrays.value(name, ordinal) orelse continue;
            try values.append(allocator, try replacePattern(allocator, value, pattern, replacement, operation.kind, options.extglob));
        }
        return .{ .fields = try values.toOwnedSlice(allocator) };
    }

    if (parsed.case_modification) |operation| {
        var pattern = if (operation.pattern) |pattern_text|
            try expandPatternWord(allocator, pattern_text, options)
        else
            try anySingleCharacterPattern(allocator);
        defer pattern.deinit(allocator);

        const len = options.arrays.len(name);
        for (0..len) |ordinal| {
            const value = options.arrays.value(name, ordinal) orelse continue;
            try values.append(allocator, try renderCaseModificationWithPattern(allocator, value, operation.kind, pattern, options.extglob));
        }
        return .{ .fields = try values.toOwnedSlice(allocator) };
    }

    unreachable;
}

fn renderArrayKeysJoined(allocator: std.mem.Allocator, name: []const u8, kind: ParameterArrayWholeKind, options: Options, in_double_quotes: bool) ![]const u8 {
    return joinArrayKeys(allocator, name, options, arrayKeyScalarJoinSeparator(kind, in_double_quotes, options));
}

fn renderIndirectParameter(allocator: std.mem.Allocator, name: []const u8, options: Options) ![]const u8 {
    const target_name = parameterValue(name, options) orelse {
        if (options.nounset and !isNounsetExemptParameter(name)) return error.NounsetParameter;
        return allocator.alloc(u8, 0);
    };
    if (target_name.len == 0) return allocator.alloc(u8, 0);
    if (try parseIndirectArrayExpansionTarget(allocator, target_name, options)) |array_target| {
        return switch (array_target.subscript) {
            .index => |index| renderArrayElement(allocator, array_target.target.text, index, options),
            .whole => |kind| renderArrayValuesJoined(allocator, array_target.target.text, kind, options),
        };
    }
    if (classifyParameterTarget(target_name).kind == .unknown) return allocator.alloc(u8, 0);
    const value = parameterValue(target_name, options) orelse {
        if (options.nounset and !isNounsetExemptParameter(target_name)) return error.NounsetParameter;
        return allocator.alloc(u8, 0);
    };
    return allocator.dupe(u8, value);
}

fn parseIndirectArrayExpansionTarget(allocator: std.mem.Allocator, target_name: []const u8, options: Options) !?BashArrayExpansionTarget {
    if (parseBashArrayExpansionTarget(target_name)) |array_target| return array_target;
    if (looksLikeArrayTarget(target_name)) return invalidIndirectTargetExpansion(allocator, options, target_name);
    return null;
}

fn looksLikeArrayTarget(target_name: []const u8) bool {
    return std.mem.findScalar(u8, target_name, '[') != null or std.mem.findScalar(u8, target_name, ']') != null;
}

fn invalidIndirectTargetExpansion(allocator: std.mem.Allocator, options: Options, target_name: []const u8) anyerror {
    if (options.parameter_error) |parameter_error| {
        const name = try allocator.dupe(u8, target_name);
        errdefer allocator.free(name);
        const message = try allocator.dupe(u8, "invalid variable name");
        parameter_error.clear(allocator);
        parameter_error.name = name;
        parameter_error.message = message;
    }
    return error.ParameterExpansionFailed;
}

fn renderNamePrefixJoined(allocator: std.mem.Allocator, prefix: []const u8, kind: ParameterArrayWholeKind, options: Options) ![]const u8 {
    _ = kind;
    const names = try matchingVariableNames(allocator, prefix, options);
    defer freeVariableNameList(allocator, names);
    return joinNames(allocator, names, arrayJoinSeparator(options));
}

fn parameterValue(name: []const u8, options: Options) ?[]const u8 {
    if (isDigitParameterName(name)) return digitParameterValue(name, options);
    return specialParameterValue(name, options) orelse options.env.get(name);
}

fn renderWholePositionalsJoined(allocator: std.mem.Allocator, name: []const u8, options: Options) ![]const u8 {
    return joinPositionals(allocator, options.positionals, wholePositionalScalarJoinSeparator(name, options));
}

fn wholePositionalScalarJoinSeparator(name: []const u8, options: Options) []const u8 {
    return if (std.mem.eql(u8, name, "*")) arrayJoinSeparator(options) else " ";
}

fn positionalSliceScalarJoinSeparator(name: []const u8, in_double_quotes: bool, options: Options) []const u8 {
    if (std.mem.eql(u8, name, "*")) return arrayJoinSeparator(options);
    return if (in_double_quotes) arrayJoinSeparator(options) else " ";
}

fn arrayValueScalarJoinSeparator(kind: ParameterArrayWholeKind, options: Options) []const u8 {
    return switch (kind) {
        .at => " ",
        .star => arrayJoinSeparator(options),
    };
}

fn arrayKeyScalarJoinSeparator(kind: ParameterArrayWholeKind, in_double_quotes: bool, options: Options) []const u8 {
    return switch (kind) {
        .at => if (in_double_quotes) arrayJoinSeparator(options) else " ",
        .star => arrayJoinSeparator(options),
    };
}

fn evaluateArrayIndex(allocator: std.mem.Allocator, name: []const u8, index_text: []const u8, options: Options, diagnostic_name: []const u8) anyerror!usize {
    const value = try evaluateArrayIndexValue(allocator, index_text, options);
    if (value < 0) return normalizeNegativeArrayIndex(name, value, options) orelse return badArraySubscriptExpansion(allocator, options, diagnostic_name);
    return std.math.cast(usize, value) orelse return badArraySubscriptExpansion(allocator, options, diagnostic_name);
}

fn evaluateArrayIndexValue(allocator: std.mem.Allocator, index_text: []const u8, options: Options) anyerror!i64 {
    const expanded_expression = try expandArithmeticExpression(allocator, index_text, options);
    defer allocator.free(expanded_expression);
    return evalArithmetic(expanded_expression, options.env, options.env_set) catch |err| return arithmeticExpansionFailed(allocator, index_text, err, options);
}

fn evaluateRecoverableArrayElementIndex(allocator: std.mem.Allocator, name: []const u8, index_text: []const u8, options: Options, diagnostic_name: []const u8) anyerror!?usize {
    const value = try evaluateArrayIndexValue(allocator, index_text, options);
    if (value < 0) {
        if (normalizeNegativeArrayIndex(name, value, options)) |index| return index;
        if (try options.diagnostic_sink.append(diagnostic_name, "bad array subscript")) return null;
        return badArraySubscriptExpansion(allocator, options, diagnostic_name);
    }
    return std.math.cast(usize, value) orelse return badArraySubscriptExpansion(allocator, options, diagnostic_name);
}

fn normalizeNegativeArrayIndex(name: []const u8, value: i64, options: Options) ?usize {
    std.debug.assert(value < 0);
    const max_index = options.arrays.maxIndex(name) orelse return null;
    const base = std.math.cast(i64, max_index) orelse return null;
    const resolved = base + 1 + value;
    if (resolved < 0) return null;
    return std.math.cast(usize, resolved);
}

fn badArraySubscriptExpansion(allocator: std.mem.Allocator, options: Options, name: []const u8) anyerror {
    if (options.parameter_error) |parameter_error| {
        const owned_name = try allocator.dupe(u8, name);
        const message = allocator.dupe(u8, "bad array subscript") catch |err| {
            allocator.free(owned_name);
            return err;
        };
        parameter_error.clear(allocator);
        parameter_error.name = owned_name;
        parameter_error.message = message;
    }
    return error.ParameterExpansionFailed;
}

fn segmentedFromText(allocator: std.mem.Allocator, text: []const u8, split_enabled: bool, force_field: bool, quoted_glob: bool) !SegmentedText {
    const owned_text = try allocator.dupe(u8, text);
    errdefer allocator.free(owned_text);
    const split = try allocator.alloc(bool, owned_text.len);
    @memset(split, split_enabled);
    return .{
        .text = owned_text,
        .split = split,
        .force_field = force_field,
        .quoted_glob = quoted_glob,
    };
}

fn expandParameterWordSegmented(allocator: std.mem.Allocator, word: []const u8, options: Options) anyerror!SegmentedText {
    const tilde_expanded = try expandTilde(allocator, word, options.env);
    defer allocator.free(tilde_expanded);

    var parts = try parseWordParts(allocator, tilde_expanded);
    defer parts.deinit();

    var builder: SegmentedTextBuilder = .{};
    errdefer builder.deinit(allocator);

    for (parts.parts) |part| {
        switch (part.kind) {
            .unquoted => {
                const rendered = try renderPart(allocator, parts.raw, part, options);
                defer allocator.free(rendered);
                try builder.append(allocator, rendered, true, false, false);
            },
            .escaped => {
                const rendered = try renderPart(allocator, parts.raw, part, options);
                defer allocator.free(rendered);
                try builder.append(allocator, rendered, false, false, hasGlobSyntax(rendered));
            },
            .single_quoted, .dollar_single_quoted, .double_quoted => {
                const rendered = try renderPart(allocator, parts.raw, part, options);
                defer allocator.free(rendered);
                try builder.append(allocator, rendered, false, true, hasGlobSyntax(rendered));
            },
            .parameter => {
                var rendered = try renderParameterSegmented(allocator, part.value(parts.raw), options);
                defer rendered.deinit(allocator);
                try builder.appendSegmented(allocator, rendered);
            },
            .arithmetic, .command_substitution => {
                const rendered = try renderPart(allocator, parts.raw, part, options);
                defer allocator.free(rendered);
                try builder.append(allocator, rendered, true, false, false);
            },
        }
    }

    return builder.toOwnedSegmented(allocator);
}

fn invalidParameterExpansion(allocator: std.mem.Allocator, options: Options) anyerror {
    if (options.parameter_error) |parameter_error| {
        const name = try allocator.dupe(u8, "parameter");
        errdefer allocator.free(name);
        const message = try allocator.dupe(u8, "bad substitution");
        parameter_error.clear(allocator);
        parameter_error.name = name;
        parameter_error.message = message;
    }
    return error.ParameterExpansionFailed;
}

fn parameterAssignmentInvalid(allocator: std.mem.Allocator, options: Options, parameter: []const u8) anyerror {
    if (options.parameter_error) |parameter_error| {
        const name = try allocator.dupe(u8, parameter);
        errdefer allocator.free(name);
        const message = try allocator.dupe(u8, "cannot assign in this way");
        parameter_error.clear(allocator);
        parameter_error.name = name;
        parameter_error.message = message;
    }
    return error.ParameterExpansionFailed;
}

fn isAssignableParameterName(name: []const u8) bool {
    if (name.len == 0 or !isNameStart(name[0])) return false;
    for (name[1..]) |c| {
        if (!isNameContinue(c)) return false;
    }
    return true;
}

fn specialParameterValue(name: []const u8, options: Options) ?[]const u8 {
    if (std.mem.eql(u8, name, "-")) return options.option_flags;
    return null;
}

fn isWholePositionalParameterName(name: []const u8) bool {
    return std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*");
}

fn digitParameterValue(name: []const u8, options: Options) ?[]const u8 {
    std.debug.assert(isDigitParameterName(name));
    const number = std.fmt.parseInt(usize, name, 10) catch return null;
    if (number == 0) return options.env.get("0");
    const index = number - 1;
    if (index >= options.positionals.len) return null;
    return options.positionals[index];
}

fn isDigitParameterName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

pub const ExpansionPattern = struct {
    text: []const u8,
    special: []const bool,

    pub fn deinit(self: *ExpansionPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.special);
        self.* = undefined;
    }
};

pub const ExpansionPatterns = struct {
    items: []ExpansionPattern,

    pub fn deinit(self: *ExpansionPatterns, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn expandWordPattern(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpansionPattern {
    const tilde_expanded = try expandTilde(allocator, raw, options.env);
    defer allocator.free(tilde_expanded);
    return expandPatternWord(allocator, tilde_expanded, options);
}

pub fn expandWordPatterns(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpansionPatterns {
    const tilde_expanded = try expandTilde(allocator, raw, options.env);
    defer allocator.free(tilde_expanded);

    var parts = try parseWordParts(allocator, tilde_expanded);
    defer parts.deinit();

    var fields: std.ArrayList(ExpansionPattern) = .empty;
    errdefer {
        for (fields.items) |*field| field.deinit(allocator);
        fields.deinit(allocator);
    }
    var current_text: std.ArrayList(u8) = .empty;
    defer current_text.deinit(allocator);
    var current_special: std.ArrayList(bool) = .empty;
    defer current_special.deinit(allocator);
    var force_current_field = false;

    const ifs = options.env.get("IFS") orelse " \t\n";
    for (parts.parts) |part| {
        if (part.kind == .parameter) {
            const parameter = part.value(parts.raw);
            if (std.mem.eql(u8, parameter, "@")) {
                try appendUnquotedAtPattern(allocator, &fields, &current_text, &current_special, options.positionals, ifs);
                continue;
            }
            if (std.mem.eql(u8, parameter, "*")) {
                if (ifs.len == 0) {
                    try appendUnquotedAtPattern(allocator, &fields, &current_text, &current_special, options.positionals, ifs);
                    continue;
                }
                const joined = try joinPositionalsWithIfs(allocator, options.positionals, ifs);
                defer allocator.free(joined);
                try appendSplitPatternText(allocator, &fields, &current_text, &current_special, joined, ifs, true);
                continue;
            }

            var rendered = try renderParameterSegmented(allocator, parameter, options);
            defer rendered.deinit(allocator);
            if (rendered.force_field) force_current_field = true;
            try appendSplitPatternSegmentedText(allocator, &fields, &current_text, &current_special, rendered, ifs);
            continue;
        }

        const rendered = try renderPart(allocator, parts.raw, part, options);
        defer allocator.free(rendered);
        switch (part.kind) {
            .unquoted => try appendPatternBytes(allocator, &current_text, &current_special, rendered, true),
            .escaped => try appendPatternBytes(allocator, &current_text, &current_special, rendered, false),
            .single_quoted, .dollar_single_quoted, .double_quoted => {
                force_current_field = true;
                try appendPatternBytes(allocator, &current_text, &current_special, rendered, false);
            },
            .arithmetic, .command_substitution => try appendSplitPatternText(allocator, &fields, &current_text, &current_special, rendered, ifs, true),
            .parameter => unreachable,
        }
    }

    if (current_text.items.len != 0 or force_current_field) {
        try appendCurrentPatternField(allocator, &fields, &current_text, &current_special);
    }

    return .{ .items = try fields.toOwnedSlice(allocator) };
}

fn expandPatternWord(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpansionPattern {
    var parts = try parseWordParts(allocator, raw);
    defer parts.deinit();

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var special: std.ArrayList(bool) = .empty;
    errdefer special.deinit(allocator);

    for (parts.parts) |part| {
        if (part.kind == .parameter) {
            var rendered = try renderParameterSegmented(allocator, part.value(parts.raw), options);
            defer rendered.deinit(allocator);
            try appendSegmentedPatternPart(allocator, &text, &special, rendered);
            continue;
        }
        const rendered = try renderPart(allocator, parts.raw, part, options);
        defer allocator.free(rendered);
        const meta_active = switch (part.kind) {
            .unquoted, .parameter, .arithmetic, .command_substitution => true,
            .single_quoted, .dollar_single_quoted, .double_quoted, .escaped => false,
        };
        try appendPatternPart(allocator, &text, &special, rendered, meta_active);
    }

    return .{ .text = try text.toOwnedSlice(allocator), .special = try special.toOwnedSlice(allocator) };
}

fn appendSegmentedPatternPart(allocator: std.mem.Allocator, text: *std.ArrayList(u8), special: *std.ArrayList(bool), rendered: SegmentedText) !void {
    try text.appendSlice(allocator, rendered.text);
    try special.appendSlice(allocator, rendered.split);
}

fn appendPatternPart(allocator: std.mem.Allocator, text: *std.ArrayList(u8), special: *std.ArrayList(bool), rendered: []const u8, meta_active: bool) !void {
    try text.appendSlice(allocator, rendered);
    for (rendered) |_| {
        try special.append(allocator, meta_active);
    }
}

fn appendPatternBytes(allocator: std.mem.Allocator, text: *std.ArrayList(u8), special: *std.ArrayList(bool), rendered: []const u8, meta_active: bool) !void {
    try text.appendSlice(allocator, rendered);
    for (rendered) |_| try special.append(allocator, meta_active);
}

fn appendCurrentPatternField(allocator: std.mem.Allocator, fields: *std.ArrayList(ExpansionPattern), current_text: *std.ArrayList(u8), current_special: *std.ArrayList(bool)) !void {
    const text = try current_text.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    const special = try current_special.toOwnedSlice(allocator);
    errdefer allocator.free(special);
    std.debug.assert(text.len == special.len);
    try fields.append(allocator, .{ .text = text, .special = special });
}

fn appendSplitPatternText(allocator: std.mem.Allocator, fields: *std.ArrayList(ExpansionPattern), current_text: *std.ArrayList(u8), current_special: *std.ArrayList(bool), text: []const u8, ifs: []const u8, meta_active: bool) !void {
    if (ifs.len == 0) {
        try appendPatternBytes(allocator, current_text, current_special, text, meta_active);
        return;
    }

    var index: usize = 0;
    while (index < text.len) {
        const c = text[index];
        if (!isIfsChar(ifs, c)) {
            try current_text.append(allocator, c);
            try current_special.append(allocator, meta_active);
            index += 1;
            continue;
        }

        if (isIfsWhitespace(ifs, c)) {
            while (index < text.len and isIfsWhitespace(ifs, text[index])) index += 1;
            if (index < text.len and isIfsChar(ifs, text[index])) continue;
            if (current_text.items.len != 0) {
                try appendCurrentPatternField(allocator, fields, current_text, current_special);
            }
            continue;
        }

        try appendCurrentPatternField(allocator, fields, current_text, current_special);
        index += 1;
        while (index < text.len and isIfsWhitespace(ifs, text[index])) index += 1;
    }
}

fn appendSplitPatternSegmentedText(allocator: std.mem.Allocator, fields: *std.ArrayList(ExpansionPattern), current_text: *std.ArrayList(u8), current_special: *std.ArrayList(bool), text: SegmentedText, ifs: []const u8) !void {
    std.debug.assert(text.text.len == text.split.len);
    if (ifs.len == 0) {
        try current_text.appendSlice(allocator, text.text);
        try current_special.appendSlice(allocator, text.split);
        return;
    }

    var index: usize = 0;
    while (index < text.text.len) {
        const c = text.text[index];
        if (!text.split[index] or !isIfsChar(ifs, c)) {
            try current_text.append(allocator, c);
            try current_special.append(allocator, text.split[index]);
            index += 1;
            continue;
        }

        if (isIfsWhitespace(ifs, c)) {
            while (index < text.text.len and text.split[index] and isIfsWhitespace(ifs, text.text[index])) index += 1;
            if (index < text.text.len and text.split[index] and isIfsChar(ifs, text.text[index])) continue;
            if (current_text.items.len != 0) {
                try appendCurrentPatternField(allocator, fields, current_text, current_special);
            }
            continue;
        }

        try appendCurrentPatternField(allocator, fields, current_text, current_special);
        index += 1;
        while (index < text.text.len and text.split[index] and isIfsWhitespace(ifs, text.text[index])) index += 1;
    }
}

fn appendUnquotedAtPattern(allocator: std.mem.Allocator, fields: *std.ArrayList(ExpansionPattern), current_text: *std.ArrayList(u8), current_special: *std.ArrayList(bool), positionals: []const []const u8, ifs: []const u8) !void {
    for (positionals, 0..) |param, index| {
        try appendSplitPatternText(allocator, fields, current_text, current_special, param, ifs, true);
        if (index + 1 < positionals.len and current_text.items.len != 0) {
            try appendCurrentPatternField(allocator, fields, current_text, current_special);
        }
    }
}

fn removePattern(allocator: std.mem.Allocator, value: []const u8, pattern: ExpansionPattern, operator: ParameterOperator, extglob: bool) ![]const u8 {
    return switch (operator) {
        .remove_small_suffix => blk: {
            var start = value.len;
            while (true) {
                if (globPatternMatchesWithOptions(pattern, value[start..], .{ .extglob = extglob })) break :blk allocator.dupe(u8, value[0..start]);
                if (start == 0) break;
                start -= 1;
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_large_suffix => blk: {
            var start: usize = 0;
            while (start <= value.len) : (start += 1) {
                if (globPatternMatchesWithOptions(pattern, value[start..], .{ .extglob = extglob })) break :blk allocator.dupe(u8, value[0..start]);
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_small_prefix => blk: {
            var end: usize = 0;
            while (end <= value.len) : (end += 1) {
                if (globPatternMatchesWithOptions(pattern, value[0..end], .{ .extglob = extglob })) break :blk allocator.dupe(u8, value[end..]);
            }
            break :blk allocator.dupe(u8, value);
        },
        .remove_large_prefix => blk: {
            var end = value.len;
            while (true) {
                if (globPatternMatchesWithOptions(pattern, value[0..end], .{ .extglob = extglob })) break :blk allocator.dupe(u8, value[end..]);
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

/// Expands an operator word from ${parameter op word}. Tilde expansion only
/// applies when the surrounding expansion is unquoted (POSIX XCU 2.6.1).
fn expandParameterWord(allocator: std.mem.Allocator, word: []const u8, options: Options, in_double_quotes: bool) anyerror![]const u8 {
    if (!in_double_quotes) return expandWordScalar(allocator, word, options);
    var parts = try parseParameterWordPartsInDoubleQuotes(allocator, word);
    defer parts.deinit();
    return renderParameterWordParts(allocator, parts, options, true);
}

fn renderParameterWordParts(allocator: std.mem.Allocator, word: WordParts, options: Options, in_double_quotes: bool) anyerror![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (word.parts) |part| {
        const rendered = try renderParameterWordPart(allocator, word.raw, part, options, in_double_quotes);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
    }

    return output.toOwnedSlice(allocator);
}

fn renderParameterWordPart(allocator: std.mem.Allocator, raw: []const u8, part: WordPart, options: Options, in_double_quotes: bool) anyerror![]const u8 {
    if (!in_double_quotes) return renderPart(allocator, raw, part, options);
    return switch (part.kind) {
        .parameter, .arithmetic, .command_substitution => renderDoubleQuotedExpansion(allocator, raw, part, options),
        else => renderPart(allocator, raw, part, options),
    };
}

// Bash 5.2 enables patsub_replacement by default; the shopt option can disable
// it for subsequent replacement expansions.
fn expandParameterReplacementWord(allocator: std.mem.Allocator, word: []const u8, options: Options, in_double_quotes: bool) anyerror!ParameterReplacementText {
    const tilde_expanded: ?[]const u8 = if (!in_double_quotes) try expandTilde(allocator, word, options.env) else null;
    defer if (tilde_expanded) |expanded| allocator.free(expanded);
    const replacement_word = tilde_expanded orelse word;

    var parts = try parseWordParts(allocator, replacement_word);
    defer parts.deinit();

    const patsub_replacement = options.features.isBash() and options.patsub_replacement;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var replace_match: std.ArrayList(bool) = .empty;
    errdefer replace_match.deinit(allocator);

    for (parts.parts) |part| {
        if (part.kind == .parameter) {
            var rendered = try renderParameterSegmented(allocator, part.value(parts.raw), options);
            defer rendered.deinit(allocator);
            if (patsub_replacement) {
                try appendSegmentedParameterReplacementPart(allocator, &text, &replace_match, rendered);
            } else {
                try appendParameterReplacementPart(allocator, &text, &replace_match, rendered.text, false);
            }
            continue;
        }

        const rendered = try renderPart(allocator, parts.raw, part, options);
        defer allocator.free(rendered);
        const replace_active = patsub_replacement and switch (part.kind) {
            .unquoted, .parameter, .arithmetic, .command_substitution => true,
            .single_quoted, .dollar_single_quoted, .double_quoted, .escaped => false,
        };
        try appendParameterReplacementPart(allocator, &text, &replace_match, rendered, replace_active);
    }

    const owned_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    return .{
        .text = owned_text,
        .replace_match = try replace_match.toOwnedSlice(allocator),
    };
}

fn appendParameterReplacementPart(allocator: std.mem.Allocator, text: *std.ArrayList(u8), replace_match: *std.ArrayList(bool), rendered: []const u8, replace_active: bool) !void {
    try text.appendSlice(allocator, rendered);
    for (rendered) |_| try replace_match.append(allocator, replace_active);
}

fn appendSegmentedParameterReplacementPart(allocator: std.mem.Allocator, text: *std.ArrayList(u8), replace_match: *std.ArrayList(bool), rendered: SegmentedText) !void {
    std.debug.assert(rendered.text.len == rendered.split.len);
    try text.appendSlice(allocator, rendered.text);
    try replace_match.appendSlice(allocator, rendered.split);
}

fn parameterHasUsableValue(is_set: bool, is_null: bool, colon: bool) bool {
    return if (colon) is_set and !is_null else is_set;
}

fn parseParameterExpression(expression: []const u8, features: compat.Features) ParameterExpression {
    const syntax = parseParameterExpansionSyntax(expression, features);
    const expansion = switch (syntax) {
        .invalid => return .{ .name = "", .operator = .invalid },
        .expansion => |parsed| parsed,
    };

    return switch (expansion.operation) {
        .value => .{ .name = expansion.target.text },
        .length => .{ .name = expansion.target.text, .operator = .length },
        .indirect => .{ .name = expansion.target.text, .indirect = true },
        .name_prefix => |operation| .{ .name = expansion.target.text, .name_prefix = operation.kind },
        .word => |operation| .{
            .name = expansion.target.text,
            .operator = operation.kind,
            .word = operation.word,
            .colon = operation.colon,
        },
        .pattern => |operation| .{
            .name = expansion.target.text,
            .operator = operation.kind,
            .word = operation.word,
        },
        .substring => |operation| .{
            .name = expansion.target.text,
            .substring = operation,
            .array_index = arrayIndexSubscript(expansion.array_subscript),
            .array_whole = arrayWholeSubscript(expansion.array_subscript),
        },
        .replacement => |operation| .{
            .name = expansion.target.text,
            .replacement = operation,
            .array_index = arrayIndexSubscript(expansion.array_subscript),
            .array_whole = arrayWholeSubscript(expansion.array_subscript),
        },
        .case_modification => |operation| .{
            .name = expansion.target.text,
            .case_modification = operation,
            .array_index = arrayIndexSubscript(expansion.array_subscript),
            .array_whole = arrayWholeSubscript(expansion.array_subscript),
        },
        .array_index => |operation| .{
            .name = expansion.target.text,
            .array_index = operation.index,
        },
        .array_element_length => |operation| .{
            .name = expansion.target.text,
            .operator = .length,
            .array_index = operation.index,
        },
        .array_values => |operation| .{
            .name = expansion.target.text,
            .array_whole = operation.kind,
        },
        .array_keys => |operation| .{
            .name = expansion.target.text,
            .array_keys = operation.kind,
        },
        .array_length => |operation| .{
            .name = expansion.target.text,
            .operator = .length,
            .array_whole = operation.kind,
        },
    };
}

fn arrayIndexSubscript(subscript: ?BashArraySubscript) ?[]const u8 {
    return switch (subscript orelse return null) {
        .index => |index| index,
        .whole => null,
    };
}

fn arrayWholeSubscript(subscript: ?BashArraySubscript) ?ParameterArrayWholeKind {
    return switch (subscript orelse return null) {
        .index => null,
        .whole => |kind| kind,
    };
}

fn parseParameterExpansionSyntax(expression: []const u8, features: compat.Features) ParameterExpansionSyntax {
    if (expression.len == 0) return .invalid;

    if (expression.len > 1 and expression[0] == '#') {
        if (features.isBash()) {
            if (parseBashArrayExpansionTarget(expression[1..])) |array_target| {
                return .{ .expansion = .{
                    .target = array_target.target,
                    .operation = switch (array_target.subscript) {
                        .index => |index| .{ .array_element_length = .{ .index = index } },
                        .whole => |kind| .{ .array_length = .{ .kind = kind } },
                    },
                } };
            }
        }
        const target = classifyParameterTarget(expression[1..]);
        if (target.kind != .unknown) {
            return .{ .expansion = .{
                .target = target,
                .operation = .length,
            } };
        }
    }

    if (features.isBash() and expression.len > 1 and expression[0] == '!') {
        if (parseBashArrayExpansionTarget(expression[1..])) |array_target| {
            return switch (array_target.subscript) {
                .whole => |kind| .{ .expansion = .{
                    .target = array_target.target,
                    .operation = .{ .array_keys = .{ .kind = kind } },
                } },
                .index => .invalid,
            };
        }
        if (parseBashNamePrefixExpansionTarget(expression[1..])) |target| {
            return .{ .expansion = .{
                .target = .{ .kind = .name, .text = target.prefix },
                .operation = .{ .name_prefix = .{ .kind = target.kind } },
            } };
        }
        const target = classifyIndirectParameterTarget(expression[1..]) orelse return .invalid;
        return .{ .expansion = .{
            .target = target,
            .operation = .indirect,
        } };
    }

    const name_end = parseParameterNameEnd(expression) orelse return .invalid;
    const target = classifyParameterTarget(expression[0..name_end]);
    if (name_end >= expression.len) return .{ .expansion = .{
        .target = target,
        .operation = .value,
    } };

    if (features.isBash() and target.kind == .name and expression[name_end] == '[') {
        return parseBashArrayExpansion(expression, target, name_end);
    }

    if (features.isBash()) {
        if (parseBashStringOperation(expression, target, name_end)) |operation| {
            return .{ .expansion = .{
                .target = target,
                .operation = operation,
            } };
        }
    }

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
        else => return .invalid,
    };
    const word_start = operator_index + @as(usize, if (operator == .remove_large_suffix or operator == .remove_large_prefix) 2 else 1);
    if (isHashSpecialParameter(target)) {
        if (colon and isPatternParameterOperator(operator)) return .invalid;
        if (!colon and word_start == expression.len and isAmbiguousHashSpecialOmittedWordOperator(operator)) return .invalid;
    }
    if (operator == .remove_small_suffix or operator == .remove_large_suffix or operator == .remove_small_prefix or operator == .remove_large_prefix) {
        return .{ .expansion = .{
            .target = target,
            .operation = .{ .pattern = .{
                .kind = operator,
                .word = expression[word_start..],
            } },
        } };
    }
    return .{ .expansion = .{
        .target = target,
        .operation = .{ .word = .{
            .kind = operator,
            .colon = colon,
            .word = expression[word_start..],
        } },
    } };
}

fn isHashSpecialParameter(target: ParameterTarget) bool {
    return target.kind == .special and std.mem.eql(u8, target.text, "#");
}

fn isPatternParameterOperator(operator: ParameterOperator) bool {
    return switch (operator) {
        .remove_small_suffix, .remove_large_suffix, .remove_small_prefix, .remove_large_prefix => true,
        else => false,
    };
}

fn isAmbiguousHashSpecialOmittedWordOperator(operator: ParameterOperator) bool {
    return switch (operator) {
        .default_value,
        .assign_default,
        .alternate_value,
        .error_if_unset,
        .remove_small_suffix,
        .remove_small_prefix,
        => true,
        else => false,
    };
}

const BashArraySubscript = union(enum) {
    index: []const u8,
    whole: ParameterArrayWholeKind,
};

const BashArrayExpansionTarget = struct {
    target: ParameterTarget,
    subscript: BashArraySubscript,
};

const BashArraySubscriptSpan = struct {
    subscript: BashArraySubscript,
    end: usize,
};

const BashNamePrefixExpansionTarget = struct {
    prefix: []const u8,
    kind: ParameterArrayWholeKind,
};

fn parseBashStringOperation(expression: []const u8, target: ParameterTarget, name_end: usize) ?ParameterOperation {
    if (target.kind == .unknown or name_end >= expression.len) return null;
    return switch (expression[name_end]) {
        ':' => parseBashSubstringOperation(expression, name_end),
        '/' => parseBashReplacementOperation(expression, name_end),
        '^', ',' => parseBashCaseOperation(expression, name_end),
        else => null,
    };
}

fn parseBashSubstringOperation(expression: []const u8, name_end: usize) ?ParameterOperation {
    std.debug.assert(name_end < expression.len);
    std.debug.assert(expression[name_end] == ':');
    const offset_start = name_end + 1;
    if (offset_start >= expression.len) return null;

    switch (expression[offset_start]) {
        '-', '=', '+', '?' => return null,
        else => {},
    }

    const length_separator = findBashSubstringLengthSeparator(expression, offset_start);
    const offset = if (length_separator) |separator| expression[offset_start..separator] else expression[offset_start..];
    if (offset.len == 0) return null;
    if (length_separator) |separator| {
        const length = expression[separator + 1 ..];
        if (length.len == 0) return null;
        return .{ .substring = .{ .offset = offset, .length = length } };
    }
    return .{ .substring = .{ .offset = offset } };
}

fn parseBashReplacementOperation(expression: []const u8, name_end: usize) ?ParameterOperation {
    std.debug.assert(name_end < expression.len);
    std.debug.assert(expression[name_end] == '/');

    var pattern_start = name_end + 1;
    var kind: ParameterReplacementKind = .first;
    if (pattern_start < expression.len) {
        switch (expression[pattern_start]) {
            '/' => {
                kind = .global;
                pattern_start += 1;
            },
            '#' => {
                kind = .prefix;
                pattern_start += 1;
            },
            '%' => {
                kind = .suffix;
                pattern_start += 1;
            },
            else => {},
        }
    }
    if (pattern_start >= expression.len) return null;

    const replacement_separator = findBashReplacementSeparator(expression, pattern_start);
    const pattern = if (replacement_separator) |separator| expression[pattern_start..separator] else expression[pattern_start..];
    if (pattern.len == 0) return null;
    const replacement = if (replacement_separator) |separator| expression[separator + 1 ..] else "";
    return .{ .replacement = .{ .kind = kind, .pattern = pattern, .replacement = replacement } };
}

fn parseBashCaseOperation(expression: []const u8, name_end: usize) ?ParameterOperation {
    std.debug.assert(name_end < expression.len);
    const operator = expression[name_end];
    std.debug.assert(operator == '^' or operator == ',');
    const double_operator = name_end + 1 < expression.len and expression[name_end + 1] == operator;
    const pattern_start = name_end + @as(usize, if (double_operator) 2 else 1);
    return .{ .case_modification = .{
        .kind = switch (operator) {
            '^' => if (double_operator) .uppercase_all else .uppercase_first,
            ',' => if (double_operator) .lowercase_all else .lowercase_first,
            else => unreachable,
        },
        .pattern = if (pattern_start < expression.len) expression[pattern_start..] else null,
    } };
}

fn findBashReplacementSeparator(text: []const u8, start: usize) ?usize {
    return findBashOperationDelimiter(text, start, '/', .shell_word);
}

fn findBashSubstringLengthSeparator(text: []const u8, start: usize) ?usize {
    return findBashOperationDelimiter(text, start, ':', .arithmetic);
}

const BashOperationDelimiterMode = enum {
    shell_word,
    arithmetic,
};

fn findBashOperationDelimiter(text: []const u8, start: usize, needle: u8, mode: BashOperationDelimiterMode) ?usize {
    var index = start;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var ternary_depth: usize = 0;

    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '\'' => index = skipSingleQuotedText(text, index),
            '"' => index = skipDoubleQuotedText(text, index),
            '`' => index = skipBackquotedText(text, index),
            '$' => index = skipDollarExpansionText(text, index) orelse index + 1,
            '(' => {
                if (mode == .arithmetic) paren_depth += 1;
                index += 1;
            },
            ')' => {
                if (mode == .arithmetic and paren_depth != 0) paren_depth -= 1;
                index += 1;
            },
            '[' => {
                if (mode == .arithmetic) bracket_depth += 1;
                index += 1;
            },
            ']' => {
                if (mode == .arithmetic and bracket_depth != 0) bracket_depth -= 1;
                index += 1;
            },
            '?' => {
                if (mode == .arithmetic and paren_depth == 0 and bracket_depth == 0) ternary_depth += 1;
                index += 1;
            },
            else => |byte| {
                if (byte == needle and paren_depth == 0 and bracket_depth == 0) {
                    if (mode == .arithmetic and needle == ':' and ternary_depth != 0) {
                        ternary_depth -= 1;
                        index += 1;
                        continue;
                    }
                    return index;
                }
                index += 1;
            },
        }
    }
    return null;
}

fn skipSingleQuotedText(text: []const u8, start: usize) usize {
    std.debug.assert(text[start] == '\'');
    var index = start + 1;
    while (index < text.len and text[index] != '\'') : (index += 1) {}
    return if (index < text.len) index + 1 else index;
}

fn skipDoubleQuotedText(text: []const u8, start: usize) usize {
    std.debug.assert(text[start] == '"');
    var index = start + 1;
    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '$' => index = skipDollarExpansionText(text, index) orelse index + 1,
            '`' => index = skipBackquotedText(text, index),
            '"' => return index + 1,
            else => index += 1,
        }
    }
    return index;
}

fn skipBackquotedText(text: []const u8, start: usize) usize {
    std.debug.assert(text[start] == '`');
    var index = start + 1;
    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '`' => return index + 1,
            else => index += 1,
        }
    }
    return index;
}

fn skipDollarExpansionText(text: []const u8, start: usize) ?usize {
    std.debug.assert(text[start] == '$');
    if (start + 1 >= text.len) return null;
    return switch (text[start + 1]) {
        '{' => skipBracedParameterText(text, start),
        '(' => if (start + 2 < text.len and text[start + 2] == '(')
            skipArithmeticExpansionText(text, start)
        else
            skipCommandSubstitutionText(text, start),
        '\'' => skipDollarSingleQuotedText(text, start),
        else => null,
    };
}

fn skipDollarSingleQuotedText(text: []const u8, start: usize) ?usize {
    std.debug.assert(text[start] == '$');
    if (start + 1 >= text.len or text[start + 1] != '\'') return null;
    var index = start + 2;
    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '\'' => return index + 1,
            else => index += 1,
        }
    }
    return null;
}

fn skipBracedParameterText(text: []const u8, start: usize) ?usize {
    std.debug.assert(text[start] == '$');
    std.debug.assert(start + 1 < text.len and text[start + 1] == '{');
    var index = start + 2;
    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '\'' => index = skipSingleQuotedText(text, index),
            '"' => index = skipDoubleQuotedText(text, index),
            '`' => index = skipBackquotedText(text, index),
            '$' => index = skipDollarExpansionText(text, index) orelse index + 1,
            '}' => return index + 1,
            else => index += 1,
        }
    }
    return null;
}

fn skipCommandSubstitutionText(text: []const u8, start: usize) ?usize {
    std.debug.assert(text[start] == '$');
    std.debug.assert(start + 1 < text.len and text[start + 1] == '(');
    var index = start + 2;
    var paren_depth: usize = 1;
    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '\'' => index = skipSingleQuotedText(text, index),
            '"' => index = skipDoubleQuotedText(text, index),
            '`' => index = skipBackquotedText(text, index),
            '$' => index = skipDollarExpansionText(text, index) orelse index + 1,
            '(' => {
                paren_depth += 1;
                index += 1;
            },
            ')' => {
                paren_depth -= 1;
                index += 1;
                if (paren_depth == 0) return index;
            },
            else => index += 1,
        }
    }
    return null;
}

fn skipArithmeticExpansionText(text: []const u8, start: usize) ?usize {
    std.debug.assert(text[start] == '$');
    std.debug.assert(start + 2 < text.len and text[start + 1] == '(' and text[start + 2] == '(');
    var index = start + 3;
    var paren_depth: usize = 0;
    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '\'' => index = skipSingleQuotedText(text, index),
            '"' => index = skipDoubleQuotedText(text, index),
            '`' => index = skipBackquotedText(text, index),
            '$' => index = skipDollarExpansionText(text, index) orelse index + 1,
            '(' => {
                paren_depth += 1;
                index += 1;
            },
            ')' => {
                if (paren_depth == 0 and index + 1 < text.len and text[index + 1] == ')') return index + 2;
                if (paren_depth != 0) paren_depth -= 1;
                index += 1;
            },
            else => index += 1,
        }
    }
    return null;
}

fn parseBashArrayExpansion(expression: []const u8, target: ParameterTarget, name_end: usize) ParameterExpansionSyntax {
    std.debug.assert(name_end < expression.len);
    std.debug.assert(expression[name_end] == '[');

    const parsed_subscript = parseBashArraySubscriptSpan(expression, name_end) orelse return .invalid;
    if (parsed_subscript.end < expression.len) {
        const operation = parseBashStringOperation(expression, target, parsed_subscript.end) orelse return .invalid;
        return .{ .expansion = .{
            .target = target,
            .operation = operation,
            .array_subscript = parsed_subscript.subscript,
        } };
    }

    const subscript = parsed_subscript.subscript;
    return .{ .expansion = .{
        .target = target,
        .operation = switch (subscript) {
            .index => |index| .{ .array_index = .{ .index = index } },
            .whole => |kind| .{ .array_values = .{ .kind = kind } },
        },
    } };
}

fn parseBashArrayExpansionTarget(expression: []const u8) ?BashArrayExpansionTarget {
    const name_end = parseParameterNameEnd(expression) orelse return null;
    const target = classifyParameterTarget(expression[0..name_end]);
    if (target.kind != .name) return null;
    if (name_end >= expression.len or expression[name_end] != '[') return null;
    const subscript = parseBashArraySubscript(expression, name_end) orelse return null;
    return .{ .target = target, .subscript = subscript };
}

fn parseBashNamePrefixExpansionTarget(expression: []const u8) ?BashNamePrefixExpansionTarget {
    if (expression.len < 2) return null;
    const marker = expression[expression.len - 1];
    if (marker != '*' and marker != '@') return null;
    const prefix = expression[0 .. expression.len - 1];
    if (!isAssignableParameterName(prefix)) return null;
    return .{ .prefix = prefix, .kind = if (marker == '@') .at else .star };
}

fn classifyIndirectParameterTarget(expression: []const u8) ?ParameterTarget {
    const name_end = parseParameterNameEnd(expression) orelse return null;
    if (name_end != expression.len) return null;
    const target = classifyParameterTarget(expression);
    if (target.kind == .unknown) return null;
    return target;
}

fn parseBashArraySubscript(expression: []const u8, name_end: usize) ?BashArraySubscript {
    const parsed = parseBashArraySubscriptSpan(expression, name_end) orelse return null;
    if (parsed.end != expression.len) return null;
    return parsed.subscript;
}

fn parseBashArraySubscriptSpan(expression: []const u8, name_end: usize) ?BashArraySubscriptSpan {
    const index_start = name_end + 1;
    const close_index = findBashArraySubscriptEnd(expression, index_start) orelse return null;
    const index_text = expression[index_start..close_index];
    if (index_text.len == 0) return null;
    const subscript: BashArraySubscript = if (std.mem.eql(u8, index_text, "@"))
        .{ .whole = .at }
    else if (std.mem.eql(u8, index_text, "*"))
        .{ .whole = .star }
    else
        .{ .index = index_text };
    return .{ .subscript = subscript, .end = close_index + 1 };
}

fn findBashArraySubscriptEnd(text: []const u8, start: usize) ?usize {
    var index = start;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;

    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '\'' => index = skipSingleQuotedText(text, index),
            '"' => index = skipDoubleQuotedText(text, index),
            '`' => index = skipBackquotedText(text, index),
            '$' => index = skipDollarExpansionText(text, index) orelse index + 1,
            '(' => {
                paren_depth += 1;
                index += 1;
            },
            ')' => {
                if (paren_depth != 0) paren_depth -= 1;
                index += 1;
            },
            '[' => {
                bracket_depth += 1;
                index += 1;
            },
            ']' => {
                if (paren_depth == 0 and bracket_depth == 0) return index;
                if (bracket_depth != 0) bracket_depth -= 1;
                index += 1;
            },
            else => index += 1,
        }
    }
    return null;
}

fn classifyParameterTarget(text: []const u8) ParameterTarget {
    if (isDigitParameterName(text)) return .{ .kind = .positional, .text = text };
    if (text.len == 1 and isSpecialParameterChar(text[0])) return .{ .kind = .special, .text = text };
    if (isAssignableParameterName(text)) return .{ .kind = .name, .text = text };
    return .{ .kind = .unknown, .text = text };
}

fn parseParameterNameEnd(expression: []const u8) ?usize {
    if (expression.len == 0) return null;
    if (std.ascii.isDigit(expression[0])) {
        var name_end: usize = 1;
        while (name_end < expression.len and std.ascii.isDigit(expression[name_end])) : (name_end += 1) {}
        return name_end;
    }
    if (isSpecialParameterChar(expression[0])) return 1;
    if (!isNameStart(expression[0])) return null;

    var name_end: usize = 1;
    while (name_end < expression.len and isNameContinue(expression[name_end])) : (name_end += 1) {}
    return name_end;
}

const ArithmeticParser = struct {
    input: []const u8,
    env: EnvLookup = .{},
    env_set: EnvSet = .{},
    index: usize = 0,
    mode: EvaluationMode = .evaluate,

    const EvaluationMode = enum { evaluate, skip };

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

    fn parseCommaMode(self: *ArithmeticParser, mode: EvaluationMode) anyerror!i64 {
        const saved = self.mode;
        self.mode = mode;
        defer self.mode = saved;
        return self.parseComma();
    }

    fn parseTernaryMode(self: *ArithmeticParser, mode: EvaluationMode) anyerror!i64 {
        const saved = self.mode;
        self.mode = mode;
        defer self.mode = saved;
        return self.parseTernary();
    }

    fn parseLogicalAndMode(self: *ArithmeticParser, mode: EvaluationMode) anyerror!i64 {
        const saved = self.mode;
        self.mode = mode;
        defer self.mode = saved;
        return self.parseLogicalAnd();
    }

    fn parseBitwiseOrMode(self: *ArithmeticParser, mode: EvaluationMode) anyerror!i64 {
        const saved = self.mode;
        self.mode = mode;
        defer self.mode = saved;
        return self.parseBitwiseOr();
    }

    fn evaluating(self: ArithmeticParser) bool {
        return self.mode == .evaluate;
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
                if (!self.evaluating()) return 0;
                const value = switch (op) {
                    .assign => rhs,
                    .add_assign => try checkedAdd(try self.lookupNumber(name), rhs),
                    .sub_assign => try checkedSub(try self.lookupNumber(name), rhs),
                    .mul_assign => try checkedMul(try self.lookupNumber(name), rhs),
                    .div_assign => blk: {
                        break :blk try checkedDiv(try self.lookupNumber(name), rhs);
                    },
                    .mod_assign => blk: {
                        break :blk try checkedRem(try self.lookupNumber(name), rhs);
                    },
                    .shl_assign => (try self.lookupNumber(name)) << shiftAmount(rhs),
                    .shr_assign => (try self.lookupNumber(name)) >> shiftAmount(rhs),
                    .bit_and_assign => (try self.lookupNumber(name)) & rhs,
                    .bit_or_assign => (try self.lookupNumber(name)) | rhs,
                    .bit_xor_assign => (try self.lookupNumber(name)) ^ rhs,
                };
                try self.setNumber(name, value);
                return value;
            }
        }
        self.index = saved;
        return self.parseTernary();
    }

    const AssignmentOperator = enum { assign, add_assign, sub_assign, mul_assign, div_assign, mod_assign, shl_assign, shr_assign, bit_and_assign, bit_or_assign, bit_xor_assign };

    fn assignmentOperator(self: *ArithmeticParser) ?AssignmentOperator {
        if (self.index >= self.input.len) return null;
        if (self.input[self.index] == '=') {
            if (self.index + 1 < self.input.len and self.input[self.index + 1] == '=') return null;
            self.index += 1;
            return .assign;
        }
        if (self.eatString("<<=")) return .shl_assign;
        if (self.eatString(">>=")) return .shr_assign;
        if (self.index + 1 >= self.input.len or self.input[self.index + 1] != '=') return null;
        const op: AssignmentOperator = switch (self.input[self.index]) {
            '+' => .add_assign,
            '-' => .sub_assign,
            '*' => .mul_assign,
            '/' => .div_assign,
            '%' => .mod_assign,
            '&' => .bit_and_assign,
            '|' => .bit_or_assign,
            '^' => .bit_xor_assign,
            else => return null,
        };
        self.index += 2;
        return op;
    }

    fn parseTernary(self: *ArithmeticParser) anyerror!i64 {
        const condition = try self.parseLogicalOr();
        self.skipSpace();
        if (!self.eat('?')) return condition;

        if (!self.evaluating()) {
            _ = try self.parseComma();
            self.skipSpace();
            if (!self.eat(':')) return error.InvalidArithmetic;
            _ = try self.parseTernary();
            return 0;
        }

        const when_true = if (condition != 0) try self.parseComma() else try self.parseCommaMode(.skip);
        self.skipSpace();
        if (!self.eat(':')) return error.InvalidArithmetic;
        if (condition != 0) {
            _ = try self.parseTernaryMode(.skip);
            return when_true;
        }
        return self.parseTernary();
    }

    fn parseLogicalOr(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseLogicalAnd();
        while (true) {
            self.skipSpace();
            if (!self.eatString("||")) return value;
            if (!self.evaluating()) {
                _ = try self.parseLogicalAnd();
                value = 0;
                continue;
            }
            const rhs = if (value != 0) try self.parseLogicalAndMode(.skip) else try self.parseLogicalAnd();
            value = if (value != 0 or rhs != 0) 1 else 0;
        }
    }

    fn parseLogicalAnd(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseBitwiseOr();
        while (true) {
            self.skipSpace();
            if (!self.eatString("&&")) return value;
            if (!self.evaluating()) {
                _ = try self.parseBitwiseOr();
                value = 0;
                continue;
            }
            const rhs = if (value == 0) try self.parseBitwiseOrMode(.skip) else try self.parseBitwiseOr();
            value = if (value != 0 and rhs != 0) 1 else 0;
        }
    }

    fn parseBitwiseOr(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseBitwiseXor();
        while (true) {
            self.skipSpace();
            if (self.startsWith("||") or !self.eat('|')) return value;
            const rhs = try self.parseBitwiseXor();
            if (self.evaluating()) value |= rhs;
        }
    }

    fn parseBitwiseXor(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseBitwiseAnd();
        while (true) {
            self.skipSpace();
            if (!self.eat('^')) return value;
            const rhs = try self.parseBitwiseAnd();
            if (self.evaluating()) value ^= rhs;
        }
    }

    fn parseBitwiseAnd(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseEquality();
        while (true) {
            self.skipSpace();
            if (self.startsWith("&&") or !self.eat('&')) return value;
            const rhs = try self.parseEquality();
            if (self.evaluating()) value &= rhs;
        }
    }

    fn parseEquality(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseRelational();
        while (true) {
            self.skipSpace();
            if (self.eatString("==")) {
                const rhs = try self.parseRelational();
                if (self.evaluating()) value = if (value == rhs) 1 else 0;
            } else if (self.eatString("!=")) {
                const rhs = try self.parseRelational();
                if (self.evaluating()) value = if (value != rhs) 1 else 0;
            } else return value;
        }
    }

    fn parseRelational(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseShift();
        while (true) {
            self.skipSpace();
            if (self.eatString("<=")) {
                const rhs = try self.parseShift();
                if (self.evaluating()) value = if (value <= rhs) 1 else 0;
            } else if (self.eatString(">=")) {
                const rhs = try self.parseShift();
                if (self.evaluating()) value = if (value >= rhs) 1 else 0;
            } else if (!self.startsWith("<<") and self.eat('<')) {
                const rhs = try self.parseShift();
                if (self.evaluating()) value = if (value < rhs) 1 else 0;
            } else if (!self.startsWith(">>") and self.eat('>')) {
                const rhs = try self.parseShift();
                if (self.evaluating()) value = if (value > rhs) 1 else 0;
            } else return value;
        }
    }

    fn parseShift(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseAdditive();
        while (true) {
            self.skipSpace();
            if (self.eatString("<<")) {
                const rhs = try self.parseAdditive();
                if (self.evaluating()) value = value << shiftAmount(rhs);
            } else if (self.eatString(">>")) {
                const rhs = try self.parseAdditive();
                if (self.evaluating()) value = value >> shiftAmount(rhs);
            } else return value;
        }
    }

    fn parseAdditive(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseTerm();
        while (true) {
            self.skipSpace();
            if (self.eat('+')) {
                const rhs = try self.parseTerm();
                if (self.evaluating()) value = try checkedAdd(value, rhs);
            } else if (self.eat('-')) {
                const rhs = try self.parseTerm();
                if (self.evaluating()) value = try checkedSub(value, rhs);
            } else return value;
        }
    }

    fn parseTerm(self: *ArithmeticParser) anyerror!i64 {
        var value = try self.parseFactor();
        while (true) {
            self.skipSpace();
            if (self.eat('*')) {
                const rhs = try self.parseFactor();
                if (self.evaluating()) value = try checkedMul(value, rhs);
            } else if (self.eat('/')) {
                const rhs = try self.parseFactor();
                if (self.evaluating()) value = try checkedDiv(value, rhs);
            } else if (self.eat('%')) {
                const rhs = try self.parseFactor();
                if (self.evaluating()) value = try checkedRem(value, rhs);
            } else return value;
        }
    }

    fn parseFactor(self: *ArithmeticParser) anyerror!i64 {
        self.skipSpace();
        if (self.eat('+')) return self.parseFactor();
        if (self.eat('-')) {
            if (try self.parseNegativeNumber()) |value| return value;
            const value = try self.parseFactor();
            if (!self.evaluating()) return 0;
            return checkedNeg(value);
        }
        if (self.eat('!')) {
            const value = try self.parseFactor();
            return if (self.evaluating() and value == 0) 1 else 0;
        }
        if (self.eat('~')) {
            const value = try self.parseFactor();
            return if (self.evaluating()) ~value else 0;
        }
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
        if (!self.evaluating()) return 0;
        return self.lookupNumber(self.input[start..self.index]);
    }

    fn lookupNumber(self: ArithmeticParser, name: []const u8) !i64 {
        const value = self.env.get(name) orelse return 0;
        const trimmed = std.mem.trim(u8, value, " \t");
        if (trimmed.len == 0) return 0;
        return parseIntegerConstant(trimmed);
    }

    fn setNumber(self: ArithmeticParser, name: []const u8, value: i64) !void {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        try self.env_set.set(name, text);
    }

    fn parseNumber(self: *ArithmeticParser) anyerror!i64 {
        self.skipSpace();
        const start = self.index;
        self.index = numberEnd(self.input, self.index) orelse return error.InvalidArithmetic;
        if (!self.evaluating()) return 0;
        return parseIntegerConstant(self.input[start..self.index]);
    }

    fn parseNegativeNumber(self: *ArithmeticParser) anyerror!?i64 {
        self.skipSpace();
        const start = self.index;
        const end = numberEnd(self.input, start) orelse return null;
        self.index = end;
        if (!self.evaluating()) return 0;
        return try parseSignedIntegerConstant(self.input[start..end], true);
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

fn checkedAdd(lhs: i64, rhs: i64) error{Overflow}!i64 {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

fn checkedSub(lhs: i64, rhs: i64) error{Overflow}!i64 {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

fn checkedMul(lhs: i64, rhs: i64) error{Overflow}!i64 {
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.Overflow;
    return result[0];
}

fn checkedNeg(value: i64) error{Overflow}!i64 {
    return checkedSub(0, value);
}

fn checkedDiv(lhs: i64, rhs: i64) error{ DivisionByZero, Overflow }!i64 {
    if (rhs == 0) return error.DivisionByZero;
    if (lhs == std.math.minInt(i64) and rhs == -1) return error.Overflow;
    return @divTrunc(lhs, rhs);
}

fn checkedRem(lhs: i64, rhs: i64) error{ DivisionByZero, Overflow }!i64 {
    if (rhs == 0) return error.DivisionByZero;
    if (lhs == std.math.minInt(i64) and rhs == -1) return error.Overflow;
    return @rem(lhs, rhs);
}

fn shiftAmount(value: i64) u6 {
    const magnitude: u64 = if (value >= 0) @intCast(value) else magnitudeTwosComplement(value);
    return @intCast(magnitude & 63);
}

fn magnitudeTwosComplement(value: i64) u64 {
    const bits: u64 = @bitCast(value);
    return @subWithOverflow(@as(u64, 0), bits)[0];
}

fn numberEnd(input: []const u8, start: usize) ?usize {
    var end = start;
    if (end + 2 <= input.len and (std.mem.eql(u8, input[end .. end + 2], "0x") or std.mem.eql(u8, input[end .. end + 2], "0X"))) {
        end += 2;
        while (end < input.len and std.ascii.isHex(input[end])) : (end += 1) {}
        return end;
    }
    while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}
    if (end == start) return null;
    return end;
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
    return parseSignedIntegerConstant(rest, negative);
}

fn parseSignedIntegerConstant(rest: []const u8, negative: bool) error{ InvalidArithmetic, Overflow }!i64 {
    if (rest.len == 0) return error.InvalidArithmetic;
    const magnitude = blk: {
        if (rest.len > 2 and (std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X")) and std.ascii.isHex(rest[2])) {
            break :blk std.fmt.parseInt(u64, rest[2..], 16);
        }
        if (rest.len > 1 and rest[0] == '0') break :blk std.fmt.parseInt(u64, rest, 8);
        break :blk std.fmt.parseInt(u64, rest, 10);
    } catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => return error.InvalidArithmetic,
    };
    const max_positive: u64 = @intCast(std.math.maxInt(i64));
    if (negative) {
        if (magnitude == max_positive + 1) return std.math.minInt(i64);
        if (magnitude > max_positive) return error.Overflow;
        return -@as(i64, @intCast(magnitude));
    }
    if (magnitude > max_positive) return error.Overflow;
    return @intCast(magnitude);
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
            if (next == '\n') {
                index += 2;
                continue;
            }
            // Inside "`...`" the backslash also escapes the surrounding
            // double-quote (POSIX XCU 2.2.3), so it is removed here.
            if (next == '`' or next == '$' or next == '\\' or (in_double_quotes and next == '"')) {
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

fn renderDollarSingleQuotedContent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\' or index + 1 >= text.len) {
            try output.append(allocator, text[index]);
            index += 1;
            continue;
        }

        const escaped = text[index + 1];
        switch (escaped) {
            '"' => try output.append(allocator, '"'),
            '\'' => try output.append(allocator, '\''),
            '\\' => try output.append(allocator, '\\'),
            'a' => try output.append(allocator, 0x07),
            'b' => try output.append(allocator, 0x08),
            'e' => try output.append(allocator, 0x1b),
            'f' => try output.append(allocator, 0x0c),
            'n' => try output.append(allocator, '\n'),
            'r' => try output.append(allocator, '\r'),
            't' => try output.append(allocator, '\t'),
            'v' => try output.append(allocator, 0x0b),
            'c' => {
                if (index + 2 >= text.len) {
                    try output.appendSlice(allocator, text[index .. index + 2]);
                    index += 2;
                    continue;
                }
                var control_index = index + 2;
                var control = text[control_index];
                if (control == '\\' and control_index + 1 < text.len and text[control_index + 1] == '\\') {
                    control_index += 1;
                    control = '\\';
                }
                if (controlEscapeValue(control)) |value| {
                    try output.append(allocator, value);
                    index = control_index + 1;
                    continue;
                }
                try output.appendSlice(allocator, text[index .. index + 2]);
                index += 2;
                continue;
            },
            'x' => {
                var value: u8 = 0;
                var digits: usize = 0;
                var cursor = index + 2;
                while (cursor < text.len and digits < 2) : (cursor += 1) {
                    const digit = hexValue(text[cursor]) orelse break;
                    value = value * 16 + digit;
                    digits += 1;
                }
                if (digits == 0) {
                    try output.appendSlice(allocator, text[index .. index + 2]);
                    index += 2;
                    continue;
                }
                try output.append(allocator, value);
                index = cursor;
                continue;
            },
            '0'...'7' => {
                var value: u16 = 0;
                var digits: usize = 0;
                var cursor = index + 1;
                while (cursor < text.len and digits < 3 and text[cursor] >= '0' and text[cursor] <= '7') : (cursor += 1) {
                    value = value * 8 + (text[cursor] - '0');
                    digits += 1;
                }
                try output.append(allocator, @intCast(value & 0xff));
                index = cursor;
                continue;
            },
            else => {
                try output.append(allocator, '\\');
                try output.append(allocator, escaped);
            },
        }
        index += 2;
    }

    return output.toOwnedSlice(allocator);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn controlEscapeValue(byte: u8) ?u8 {
    return switch (byte) {
        '@' => 0x00,
        'A'...'Z' => byte - 'A' + 1,
        'a'...'z' => byte - 'a' + 1,
        '[' => 0x1b,
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        '_' => 0x1f,
        '?' => 0x7f,
        else => null,
    };
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

        const part = (if (text[index] == '$' or text[index] == '`') try substitutionPart(allocator, text, index) else null) orelse {
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
        .parameter => renderParameter(allocator, part.value(raw), options, true),
        .arithmetic => renderArithmetic(allocator, part.source(raw), part.value(raw), options),
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

fn appendParameterExpansionUnquoted(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_glob: *bool, parameter: []const u8, options: Options, ifs: []const u8) anyerror!void {
    if (std.mem.eql(u8, parameter, "@")) {
        try appendUnquotedAt(allocator, fields, current, options.positionals, ifs);
        return;
    }
    if (std.mem.eql(u8, parameter, "*")) {
        try appendUnquotedStar(allocator, fields, current, options.positionals, ifs);
        return;
    }
    if (bashPositionalSliceExpansion(parameter, options.features)) |slice| {
        const values = try positionalSliceValues(allocator, slice.operation, options);
        defer allocator.free(values);
        switch (slice.kind) {
            .at => try appendUnquotedAt(allocator, fields, current, values, ifs),
            .star => try appendUnquotedStar(allocator, fields, current, values, ifs),
        }
        return;
    }
    if (bashWholeArrayStringOperation(parameter, options.features)) |parsed| {
        const kind = parsed.array_whole.?;
        var values = try renderArrayStringOperationValues(allocator, parsed.name, kind, parsed, options, false);
        defer values.deinit(allocator);
        const separator: []const u8 = switch (kind) {
            .at => " ",
            .star => arrayJoinSeparatorFromIfs(ifs),
        };
        const joined = try joinValues(allocator, values.fields, separator);
        defer allocator.free(joined);
        try appendSplitText(allocator, fields, current, joined, ifs);
        return;
    }
    if (bashWholeArrayExpansion(parameter, options.features)) |array_expansion| {
        switch (array_expansion.kind) {
            .values => switch (array_expansion.whole) {
                .at => try appendUnquotedArrayValues(allocator, fields, current, array_expansion.name, options, ifs),
                .star => try appendUnquotedArrayValuesStar(allocator, fields, current, array_expansion.name, options, ifs),
            },
            .keys => switch (array_expansion.whole) {
                .at => try appendUnquotedArrayKeys(allocator, fields, current, array_expansion.name, options, ifs),
                .star => try appendUnquotedArrayKeysStar(allocator, fields, current, array_expansion.name, options, ifs),
            },
        }
        return;
    }
    if (try bashIndirectWholeArrayExpansion(allocator, parameter, options)) |array_expansion| {
        switch (array_expansion.whole) {
            .at => try appendUnquotedArrayValues(allocator, fields, current, array_expansion.name, options, ifs),
            .star => try appendUnquotedArrayValuesStar(allocator, fields, current, array_expansion.name, options, ifs),
        }
        return;
    }
    if (bashNamePrefixExpansion(parameter, options.features)) |prefix_expansion| {
        switch (prefix_expansion.kind) {
            .at => try appendUnquotedNamePrefixAt(allocator, fields, current, prefix_expansion.prefix, options, ifs),
            .star => try appendUnquotedNamePrefixStar(allocator, fields, current, prefix_expansion.prefix, options, ifs),
        }
        return;
    }

    const parsed = parseParameterExpression(parameter, options.features);
    if (parsed.operator == .invalid) return invalidParameterExpansion(allocator, options);
    if (isFieldAwareParameterWordOperator(parsed)) {
        try appendParameterWordOperatorUnquoted(allocator, fields, current, force_current_field, quoted_glob, parsed, options, ifs);
        return;
    }

    var rendered = try renderParameterSegmented(allocator, parameter, options);
    defer rendered.deinit(allocator);
    if (rendered.quoted_glob) quoted_glob.* = true;
    if (rendered.force_field) force_current_field.* = true;
    try appendSplitSegmentedText(allocator, fields, current, rendered, ifs);
}

fn appendParameterWordOperatorUnquoted(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_glob: *bool, parsed: ParameterExpression, options: Options, ifs: []const u8) anyerror!void {
    const value = parameterValue(parsed.name, options);
    const is_set = value != null;
    const is_null = if (value) |text| text.len == 0 else true;

    switch (parsed.operator) {
        .default_value => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) {
                try appendSplitText(allocator, fields, current, value.?, ifs);
                return;
            }
            var expanded = try expandWordFieldsNoPathname(allocator, parsed.word, options);
            defer expanded.deinit(allocator);
            if (expanded.quoted_glob) quoted_glob.* = true;
            try appendExpandedFields(allocator, fields, current, force_current_field, expanded.fields);
        },
        .assign_default => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) {
                try appendSplitText(allocator, fields, current, value.?, ifs);
                return;
            }
            if (!isAssignableParameterName(parsed.name)) return parameterAssignmentInvalid(allocator, options, parsed.name);
            const assigned = try expandParameterWord(allocator, parsed.word, options, false);
            defer allocator.free(assigned);
            try options.env_set.set(parsed.name, assigned);
            try appendSplitText(allocator, fields, current, assigned, ifs);
        },
        .alternate_value => {
            if (!parameterHasUsableValue(is_set, is_null, parsed.colon)) return;
            var expanded = try expandWordFieldsNoPathname(allocator, parsed.word, options);
            defer expanded.deinit(allocator);
            if (expanded.quoted_glob) quoted_glob.* = true;
            try appendExpandedFields(allocator, fields, current, force_current_field, expanded.fields);
        },
        else => unreachable,
    }
}

fn appendExpandedFields(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, expanded_fields: []const []const u8) !void {
    for (expanded_fields, 0..) |field, index| {
        try current.appendSlice(allocator, field);
        if (index + 1 < expanded_fields.len) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
            force_current_field.* = false;
        }
    }
    if (expanded_fields.len != 0 and expanded_fields[expanded_fields.len - 1].len == 0) force_current_field.* = true;
}

fn isFieldAwareParameterWordOperator(parsed: ParameterExpression) bool {
    if (parsed.name_prefix != null or parsed.indirect or parsed.array_keys != null or parsed.array_whole != null or parsed.array_index != null) return false;
    if (parsed.substring != null or parsed.replacement != null or parsed.case_modification != null) return false;
    return parsed.operator == .default_value or parsed.operator == .assign_default or parsed.operator == .alternate_value;
}

fn appendDoubleQuotedText(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_glob: *bool, text: []const u8, options: Options, ifs: []const u8) !void {
    force_current_field.* = true;
    var index: usize = 0;
    var segment_start: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 1 < text.len) {
            index += 2;
            continue;
        }
        if (text[index] == '$' or text[index] == '`') {
            if (try substitutionPart(allocator, text, index)) |part| {
                switch (part.kind) {
                    .arithmetic, .command_substitution => {
                        index = part.span.end;
                        continue;
                    },
                    .parameter => {},
                    else => unreachable,
                }
            }
        }
        if (try quotedPositionalSliceAt(allocator, text, index, options)) |special| {
            try appendQuotedSegment(allocator, current, quoted_glob, text[segment_start..index], options);
            const values = try positionalSliceValues(allocator, special.expansion.operation, options);
            defer allocator.free(values);
            switch (special.expansion.kind) {
                .at => try appendQuotedAt(allocator, fields, current, force_current_field, quoted_glob, values, false),
                .star => try appendQuotedStar(allocator, current, quoted_glob, values, ifs),
            }
            index = special.end;
            segment_start = index;
            continue;
        }
        if (quotedPositionalAt(text, index)) |special| {
            try appendQuotedSegment(allocator, current, quoted_glob, text[segment_start..index], options);
            switch (special.kind) {
                .at => try appendQuotedAt(allocator, fields, current, force_current_field, quoted_glob, options.positionals, true),
                .star => try appendQuotedStar(allocator, current, quoted_glob, options.positionals, ifs),
            }
            index = special.end;
            segment_start = index;
            continue;
        }
        if (quotedWholeArrayExpansionAt(text, index, options.features)) |special| {
            try appendQuotedSegment(allocator, current, quoted_glob, text[segment_start..index], options);
            switch (special.expansion.kind) {
                .values => switch (special.expansion.whole) {
                    .at => try appendQuotedArrayValues(allocator, fields, current, force_current_field, quoted_glob, special.expansion.name, options),
                    .star => try appendQuotedArrayValuesStar(allocator, current, quoted_glob, special.expansion.name, options, ifs),
                },
                .keys => switch (special.expansion.whole) {
                    .at => try appendQuotedArrayKeys(allocator, fields, current, force_current_field, special.expansion.name, options),
                    .star => try appendQuotedArrayKeysStar(allocator, current, special.expansion.name, options, ifs),
                },
            }
            index = special.end;
            segment_start = index;
            continue;
        }
        if (try quotedIndirectWholeArrayExpansionAt(allocator, text, index, options)) |special| {
            try appendQuotedSegment(allocator, current, quoted_glob, text[segment_start..index], options);
            switch (special.expansion.whole) {
                .at => try appendQuotedArrayValues(allocator, fields, current, force_current_field, quoted_glob, special.expansion.name, options),
                .star => try appendQuotedArrayValuesStar(allocator, current, quoted_glob, special.expansion.name, options, ifs),
            }
            index = special.end;
            segment_start = index;
            continue;
        }
        if (quotedNamePrefixExpansionAt(text, index, options.features)) |special| {
            try appendQuotedSegment(allocator, current, quoted_glob, text[segment_start..index], options);
            switch (special.expansion.kind) {
                .at => try appendQuotedNamePrefixAt(allocator, fields, current, force_current_field, special.expansion.prefix, options),
                .star => try appendQuotedNamePrefixStar(allocator, current, special.expansion.prefix, options, ifs),
            }
            index = special.end;
            segment_start = index;
            continue;
        }
        if (try quotedParameterExpansionAt(allocator, text, index)) |special| {
            try appendQuotedSegment(allocator, current, quoted_glob, text[segment_start..index], options);
            try appendParameterExpansionQuoted(allocator, fields, current, force_current_field, quoted_glob, special.expression, options, ifs, false);
            index = special.end;
            segment_start = index;
            continue;
        }
        index += 1;
    }
    try appendQuotedSegment(allocator, current, quoted_glob, text[segment_start..], options);
}

const QuotedPositionalKind = enum { at, star };
const QuotedPositional = struct { kind: QuotedPositionalKind, end: usize };

const BashWholeArrayExpansionKind = enum { values, keys };
const BashWholeArrayExpansion = struct {
    kind: BashWholeArrayExpansionKind,
    name: []const u8,
    whole: ParameterArrayWholeKind,
};

const BashNamePrefixExpansion = struct {
    prefix: []const u8,
    kind: ParameterArrayWholeKind,
};

const BashIndirectWholeArrayExpansion = struct {
    name: []const u8,
    whole: ParameterArrayWholeKind,
};

const BashPositionalSliceExpansion = struct {
    kind: ParameterArrayWholeKind,
    operation: ParameterSubstringOperation,
};

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

fn quotedPositionalSliceAt(allocator: std.mem.Allocator, text: []const u8, index: usize, options: Options) !?struct { expansion: BashPositionalSliceExpansion, end: usize } {
    if (!options.features.isBash() or index + 3 >= text.len or text[index] != '$' or text[index + 1] != '{') return null;
    const part = (try substitutionPart(allocator, text, index)) orelse return null;
    if (part.kind != .parameter) return null;
    const expansion = bashPositionalSliceExpansion(part.value(text), options.features) orelse return null;
    return .{ .expansion = expansion, .end = part.span.end };
}

fn quotedParameterExpansionAt(allocator: std.mem.Allocator, text: []const u8, index: usize) !?struct { expression: []const u8, end: usize } {
    if (index >= text.len or text[index] != '$') return null;
    const part = (try substitutionPart(allocator, text, index)) orelse return null;
    if (part.kind != .parameter) return null;
    return .{ .expression = part.value(text), .end = part.span.end };
}

fn appendParameterExpansionQuoted(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_glob: *bool, parameter: []const u8, options: Options, ifs: []const u8, empty_at_removes_field: bool) anyerror!void {
    if (std.mem.eql(u8, parameter, "@")) {
        try appendQuotedAt(allocator, fields, current, force_current_field, quoted_glob, options.positionals, empty_at_removes_field);
        return;
    }
    if (std.mem.eql(u8, parameter, "*")) {
        try appendQuotedStar(allocator, current, quoted_glob, options.positionals, ifs);
        return;
    }
    if (bashPositionalSliceExpansion(parameter, options.features)) |slice| {
        const values = try positionalSliceValues(allocator, slice.operation, options);
        defer allocator.free(values);
        switch (slice.kind) {
            .at => try appendQuotedAt(allocator, fields, current, force_current_field, quoted_glob, values, false),
            .star => try appendQuotedStar(allocator, current, quoted_glob, values, ifs),
        }
        return;
    }
    if (bashWholeArrayStringOperation(parameter, options.features)) |parsed| {
        const kind = parsed.array_whole.?;
        var values = try renderArrayStringOperationValues(allocator, parsed.name, kind, parsed, options, true);
        defer values.deinit(allocator);
        switch (kind) {
            .at => try appendQuotedAt(allocator, fields, current, force_current_field, quoted_glob, values.fields, true),
            .star => try appendQuotedStar(allocator, current, quoted_glob, values.fields, ifs),
        }
        return;
    }
    if (bashWholeArrayExpansion(parameter, options.features)) |array_expansion| {
        switch (array_expansion.kind) {
            .values => switch (array_expansion.whole) {
                .at => try appendQuotedArrayValues(allocator, fields, current, force_current_field, quoted_glob, array_expansion.name, options),
                .star => try appendQuotedArrayValuesStar(allocator, current, quoted_glob, array_expansion.name, options, ifs),
            },
            .keys => switch (array_expansion.whole) {
                .at => try appendQuotedArrayKeys(allocator, fields, current, force_current_field, array_expansion.name, options),
                .star => try appendQuotedArrayKeysStar(allocator, current, array_expansion.name, options, ifs),
            },
        }
        return;
    }
    if (try bashIndirectWholeArrayExpansion(allocator, parameter, options)) |array_expansion| {
        switch (array_expansion.whole) {
            .at => try appendQuotedArrayValues(allocator, fields, current, force_current_field, quoted_glob, array_expansion.name, options),
            .star => try appendQuotedArrayValuesStar(allocator, current, quoted_glob, array_expansion.name, options, ifs),
        }
        return;
    }
    if (bashNamePrefixExpansion(parameter, options.features)) |prefix_expansion| {
        switch (prefix_expansion.kind) {
            .at => try appendQuotedNamePrefixAt(allocator, fields, current, force_current_field, prefix_expansion.prefix, options),
            .star => try appendQuotedNamePrefixStar(allocator, current, prefix_expansion.prefix, options, ifs),
        }
        return;
    }

    const parsed = parseParameterExpression(parameter, options.features);
    if (parsed.operator == .invalid) return invalidParameterExpansion(allocator, options);
    if (isFieldAwareParameterWordOperator(parsed)) {
        try appendParameterWordOperatorQuoted(allocator, fields, current, force_current_field, quoted_glob, parsed, options, ifs);
        return;
    }

    const rendered = try renderParameter(allocator, parameter, options, true);
    defer allocator.free(rendered);
    if (hasGlobSyntax(rendered)) quoted_glob.* = true;
    try current.appendSlice(allocator, rendered);
    force_current_field.* = true;
}

fn appendParameterWordOperatorQuoted(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_glob: *bool, parsed: ParameterExpression, options: Options, ifs: []const u8) anyerror!void {
    const value = parameterValue(parsed.name, options);
    const is_set = value != null;
    const is_null = if (value) |text| text.len == 0 else true;

    switch (parsed.operator) {
        .default_value => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) {
                if (hasGlobSyntax(value.?)) quoted_glob.* = true;
                try current.appendSlice(allocator, value.?);
                force_current_field.* = true;
                return;
            }
            var expanded = try expandParameterWordQuotedFields(allocator, parsed.word, options, ifs);
            defer expanded.deinit(allocator);
            if (expanded.quoted_glob) quoted_glob.* = true;
            try appendExpandedFields(allocator, fields, current, force_current_field, expanded.fields);
        },
        .assign_default => {
            if (parameterHasUsableValue(is_set, is_null, parsed.colon)) {
                if (hasGlobSyntax(value.?)) quoted_glob.* = true;
                try current.appendSlice(allocator, value.?);
                force_current_field.* = true;
                return;
            }
            if (!isAssignableParameterName(parsed.name)) return parameterAssignmentInvalid(allocator, options, parsed.name);
            const assigned = try expandParameterWord(allocator, parsed.word, options, true);
            defer allocator.free(assigned);
            try options.env_set.set(parsed.name, assigned);
            if (hasGlobSyntax(assigned)) quoted_glob.* = true;
            try current.appendSlice(allocator, assigned);
            force_current_field.* = true;
        },
        .alternate_value => {
            if (!parameterHasUsableValue(is_set, is_null, parsed.colon)) return;
            var expanded = try expandParameterWordQuotedFields(allocator, parsed.word, options, ifs);
            defer expanded.deinit(allocator);
            if (expanded.quoted_glob) quoted_glob.* = true;
            try appendExpandedFields(allocator, fields, current, force_current_field, expanded.fields);
        },
        else => unreachable,
    }
}

fn expandParameterWordQuotedFields(allocator: std.mem.Allocator, word: []const u8, options: Options, ifs: []const u8) anyerror!ExpandedWordFields {
    var parts = try parseParameterWordPartsInDoubleQuotes(allocator, word);
    defer parts.deinit();

    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var force_current_field = true;
    var quoted_expansion_glob = false;

    for (parts.parts) |part| {
        switch (part.kind) {
            .parameter => try appendParameterExpansionQuoted(allocator, &fields, &current, &force_current_field, &quoted_expansion_glob, part.value(parts.raw), options, ifs, false),
            .double_quoted => try appendDoubleQuotedText(allocator, &fields, &current, &force_current_field, &quoted_expansion_glob, part.value(parts.raw), options, ifs),
            .unquoted, .single_quoted, .dollar_single_quoted, .escaped => {
                const rendered = try renderPart(allocator, parts.raw, part, options);
                defer allocator.free(rendered);
                if (part.kind == .dollar_single_quoted and hasGlobSyntax(rendered)) quoted_expansion_glob = true;
                try current.appendSlice(allocator, rendered);
                force_current_field = true;
            },
            .arithmetic, .command_substitution => {
                const rendered = try renderDoubleQuotedExpansion(allocator, parts.raw, part, options);
                defer allocator.free(rendered);
                if (hasGlobSyntax(rendered)) quoted_expansion_glob = true;
                try current.appendSlice(allocator, rendered);
                force_current_field = true;
            },
        }
    }

    if (current.items.len != 0 or force_current_field) {
        try fields.append(allocator, try current.toOwnedSlice(allocator));
    }

    return .{
        .fields = try fields.toOwnedSlice(allocator),
        .quoted_glob = quoted_expansion_glob,
    };
}

fn quotedWholeArrayExpansionAt(text: []const u8, index: usize, features: compat.Features) ?struct { expansion: BashWholeArrayExpansion, end: usize } {
    if (!features.isBash() or index + 3 >= text.len or text[index] != '$' or text[index + 1] != '{') return null;
    const close = std.mem.indexOfScalarPos(u8, text, index + 2, '}') orelse return null;
    const expression = text[index + 2 .. close];
    const expansion = bashWholeArrayExpansion(expression, features) orelse return null;
    return .{ .expansion = expansion, .end = close + 1 };
}

fn quotedNamePrefixExpansionAt(text: []const u8, index: usize, features: compat.Features) ?struct { expansion: BashNamePrefixExpansion, end: usize } {
    if (!features.isBash() or index + 3 >= text.len or text[index] != '$' or text[index + 1] != '{') return null;
    const close = std.mem.indexOfScalarPos(u8, text, index + 2, '}') orelse return null;
    const expression = text[index + 2 .. close];
    const expansion = bashNamePrefixExpansion(expression, features) orelse return null;
    return .{ .expansion = expansion, .end = close + 1 };
}

fn quotedIndirectWholeArrayExpansionAt(allocator: std.mem.Allocator, text: []const u8, index: usize, options: Options) !?struct { expansion: BashIndirectWholeArrayExpansion, end: usize } {
    if (!options.features.isBash() or index + 3 >= text.len or text[index] != '$' or text[index + 1] != '{') return null;
    const close = std.mem.indexOfScalarPos(u8, text, index + 2, '}') orelse return null;
    const expression = text[index + 2 .. close];
    const expansion = (try bashIndirectWholeArrayExpansion(allocator, expression, options)) orelse return null;
    return .{ .expansion = expansion, .end = close + 1 };
}

fn bashWholeArrayExpansion(expression: []const u8, features: compat.Features) ?BashWholeArrayExpansion {
    if (!features.isBash()) return null;
    const syntax = parseParameterExpansionSyntax(expression, features);
    const expansion = switch (syntax) {
        .invalid => return null,
        .expansion => |parsed| parsed,
    };
    return switch (expansion.operation) {
        .array_values => |operation| .{ .kind = .values, .name = expansion.target.text, .whole = operation.kind },
        .array_keys => |operation| .{ .kind = .keys, .name = expansion.target.text, .whole = operation.kind },
        else => null,
    };
}

fn bashWholeArrayStringOperation(expression: []const u8, features: compat.Features) ?ParameterExpression {
    if (!features.isBash()) return null;
    const parsed = parseParameterExpression(expression, features);
    if (parsed.operator == .invalid or parsed.array_whole == null or !hasParameterStringOperation(parsed)) return null;
    return parsed;
}

fn bashNamePrefixExpansion(expression: []const u8, features: compat.Features) ?BashNamePrefixExpansion {
    if (!features.isBash()) return null;
    const syntax = parseParameterExpansionSyntax(expression, features);
    const expansion = switch (syntax) {
        .invalid => return null,
        .expansion => |parsed| parsed,
    };
    return switch (expansion.operation) {
        .name_prefix => |operation| .{ .prefix = expansion.target.text, .kind = operation.kind },
        else => null,
    };
}

fn bashPositionalSliceExpansion(expression: []const u8, features: compat.Features) ?BashPositionalSliceExpansion {
    if (!features.isBash()) return null;
    const syntax = parseParameterExpansionSyntax(expression, features);
    const expansion = switch (syntax) {
        .invalid => return null,
        .expansion => |parsed| parsed,
    };
    if (expansion.target.kind != .special) return null;
    const kind: ParameterArrayWholeKind = if (std.mem.eql(u8, expansion.target.text, "@"))
        .at
    else if (std.mem.eql(u8, expansion.target.text, "*"))
        .star
    else
        return null;
    return switch (expansion.operation) {
        .substring => |operation| .{ .kind = kind, .operation = operation },
        else => null,
    };
}

fn bashIndirectWholeArrayExpansion(allocator: std.mem.Allocator, expression: []const u8, options: Options) !?BashIndirectWholeArrayExpansion {
    if (!options.features.isBash()) return null;
    const syntax = parseParameterExpansionSyntax(expression, options.features);
    const expansion = switch (syntax) {
        .invalid => return null,
        .expansion => |parsed| parsed,
    };
    switch (expansion.operation) {
        .indirect => {},
        else => return null,
    }
    const target_name = parameterValue(expansion.target.text, options) orelse {
        if (options.nounset and !isNounsetExemptParameter(expansion.target.text)) return error.NounsetParameter;
        return null;
    };
    if (target_name.len == 0) return null;
    const array_target = (try parseIndirectArrayExpansionTarget(allocator, target_name, options)) orelse return null;
    return switch (array_target.subscript) {
        .index => null,
        .whole => |kind| .{ .name = array_target.target.text, .whole = kind },
    };
}

fn positionalSliceValues(allocator: std.mem.Allocator, operation: ParameterSubstringOperation, options: Options) anyerror![]const []const u8 {
    const positional_count = std.math.cast(i64, options.positionals.len) orelse std.math.maxInt(i64);
    const offset = try evaluateArrayIndexValue(allocator, operation.offset, options);
    const start_value = if (offset < 0) positional_count + 1 + offset else offset;
    const out_of_range = start_value < 0 or start_value > positional_count + 1;

    const requested_count = if (operation.length) |length_expression| blk: {
        const length = try evaluateArrayIndexValue(allocator, length_expression, options);
        if (length < 0) {
            if (out_of_range) break :blk @as(i64, 0);
            return badSubstringExpressionExpansion(allocator, options, length_expression);
        }
        break :blk length;
    } else std.math.maxInt(i64);

    if (out_of_range or requested_count == 0) return allocator.alloc([]const u8, 0);
    const available = positionalSliceAvailableCount(positional_count, start_value);
    const value_count: usize = @intCast(@min(requested_count, available));
    const values = try allocator.alloc([]const u8, value_count);
    errdefer allocator.free(values);
    for (values, 0..) |*value, index| {
        const position = start_value + @as(i64, @intCast(index));
        value.* = if (position == 0) options.env.get("0") orelse "" else options.positionals[@intCast(position - 1)];
    }
    return values;
}

fn arraySliceValues(allocator: std.mem.Allocator, name: []const u8, operation: ParameterSubstringOperation, options: Options) anyerror!ExpandedWordFields {
    const max_index = options.arrays.maxIndex(name) orelse return emptyExpandedWordFields(allocator);
    const max_value = std.math.cast(i64, max_index) orelse std.math.maxInt(i64) - 1;
    const offset = try evaluateArrayIndexValue(allocator, operation.offset, options);
    const start_value = if (offset < 0) max_value + 1 + offset else offset;
    const out_of_range = start_value < 0 or start_value > max_value;

    const requested_count = if (operation.length) |length_expression| blk: {
        const length = try evaluateArrayIndexValue(allocator, length_expression, options);
        if (length < 0) {
            if (out_of_range) break :blk @as(i64, 0);
            return badSubstringExpressionExpansion(allocator, options, length_expression);
        }
        break :blk length;
    } else std.math.maxInt(i64);

    if (out_of_range or requested_count == 0) return emptyExpandedWordFields(allocator);

    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    const value_limit = std.math.cast(usize, requested_count) orelse std.math.maxInt(usize);
    const len = options.arrays.len(name);
    for (0..len) |ordinal| {
        const key = options.arrays.key(name, ordinal) orelse continue;
        const key_value = std.math.cast(i64, key) orelse std.math.maxInt(i64);
        if (key_value < start_value) continue;
        if (values.items.len >= value_limit) break;
        const value = options.arrays.value(name, ordinal) orelse continue;
        try values.append(allocator, try allocator.dupe(u8, value));
    }

    return .{ .fields = try values.toOwnedSlice(allocator) };
}

fn emptyExpandedWordFields(allocator: std.mem.Allocator) !ExpandedWordFields {
    return .{ .fields = try allocator.alloc([]const u8, 0) };
}

fn positionalSliceAvailableCount(positional_count: i64, start_value: i64) i64 {
    std.debug.assert(start_value >= 0);
    std.debug.assert(start_value <= positional_count + 1);
    if (start_value == 0) return positional_count + 1;
    if (start_value > positional_count) return 0;
    return positional_count - start_value + 1;
}

fn appendQuotedSegment(allocator: std.mem.Allocator, current: *std.ArrayList(u8), quoted_glob: *bool, text: []const u8, options: Options) !void {
    const rendered = try renderDoubleQuotedContent(allocator, text, options);
    defer allocator.free(rendered);
    // Glob characters produced inside double quotes must not trigger
    // pathname expansion (POSIX XCU 2.13.3).
    if (hasGlobSyntax(rendered)) quoted_glob.* = true;
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
    if (ifs.len == 0) {
        try appendUnquotedAt(allocator, fields, current, positionals, ifs);
        return;
    }
    const joined = try joinPositionalsWithIfs(allocator, positionals, ifs);
    defer allocator.free(joined);
    try appendSplitText(allocator, fields, current, joined, ifs);
}

fn appendUnquotedArrayValues(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), name: []const u8, options: Options, ifs: []const u8) !void {
    const len = options.arrays.len(name);
    for (0..len) |ordinal| {
        const value = options.arrays.value(name, ordinal) orelse continue;
        try appendSplitText(allocator, fields, current, value, ifs);
        if (ordinal + 1 < len and current.items.len != 0) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
        }
    }
}

fn appendUnquotedArrayValuesStar(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), name: []const u8, options: Options, ifs: []const u8) !void {
    const joined = try joinArrayValues(allocator, name, options, arrayJoinSeparatorFromIfs(ifs));
    defer allocator.free(joined);
    try appendSplitText(allocator, fields, current, joined, ifs);
}

fn appendUnquotedArrayKeys(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), name: []const u8, options: Options, ifs: []const u8) !void {
    const len = options.arrays.len(name);
    for (0..len) |ordinal| {
        var buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        const key_text = try std.fmt.bufPrint(&buffer, "{d}", .{options.arrays.key(name, ordinal) orelse continue});
        try appendSplitText(allocator, fields, current, key_text, ifs);
        if (ordinal + 1 < len and current.items.len != 0) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
        }
    }
}

fn appendUnquotedArrayKeysStar(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), name: []const u8, options: Options, ifs: []const u8) !void {
    const joined = try joinArrayKeys(allocator, name, options, arrayJoinSeparatorFromIfs(ifs));
    defer allocator.free(joined);
    try appendSplitText(allocator, fields, current, joined, ifs);
}

fn appendUnquotedNamePrefixAt(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), prefix: []const u8, options: Options, ifs: []const u8) !void {
    const names = try matchingVariableNames(allocator, prefix, options);
    defer freeVariableNameList(allocator, names);
    for (names, 0..) |name, index| {
        try appendSplitText(allocator, fields, current, name, ifs);
        if (index + 1 < names.len and current.items.len != 0) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
        }
    }
}

fn appendUnquotedNamePrefixStar(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), prefix: []const u8, options: Options, ifs: []const u8) !void {
    const names = try matchingVariableNames(allocator, prefix, options);
    defer freeVariableNameList(allocator, names);
    const joined = try joinNames(allocator, names, arrayJoinSeparatorFromIfs(ifs));
    defer allocator.free(joined);
    try appendSplitText(allocator, fields, current, joined, ifs);
}

fn joinPositionalsWithIfs(allocator: std.mem.Allocator, positionals: []const []const u8, ifs: []const u8) ![]const u8 {
    const separator = arrayJoinSeparatorFromIfs(ifs);
    return joinPositionals(allocator, positionals, separator);
}

fn joinPositionals(allocator: std.mem.Allocator, positionals: []const []const u8, separator: []const u8) ![]const u8 {
    return joinValues(allocator, positionals, separator);
}

fn joinValues(allocator: std.mem.Allocator, values: []const []const u8, separator: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (values, 0..) |param, index| {
        if (index > 0) try joined.appendSlice(allocator, separator);
        try joined.appendSlice(allocator, param);
    }
    return joined.toOwnedSlice(allocator);
}

fn appendQuotedAt(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_glob: *bool, positionals: []const []const u8, empty_removes_field: bool) !void {
    if (positionals.len == 0) {
        if (empty_removes_field) force_current_field.* = false;
        return;
    }
    for (positionals, 0..) |param, index| {
        if (hasGlobSyntax(param)) quoted_glob.* = true;
        try current.appendSlice(allocator, param);
        force_current_field.* = true;
        if (index + 1 < positionals.len) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
            force_current_field.* = false;
        }
    }
}

fn appendQuotedStar(allocator: std.mem.Allocator, current: *std.ArrayList(u8), quoted_glob: *bool, positionals: []const []const u8, ifs: []const u8) !void {
    const separator = arrayJoinSeparatorFromIfs(ifs);
    for (positionals, 0..) |param, index| {
        if (hasGlobSyntax(param)) quoted_glob.* = true;
        if (index > 0) try current.appendSlice(allocator, separator);
        try current.appendSlice(allocator, param);
    }
}

fn appendQuotedArrayValues(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, quoted_glob: *bool, name: []const u8, options: Options) !void {
    const len = options.arrays.len(name);
    if (len == 0) {
        force_current_field.* = false;
        return;
    }
    for (0..len) |ordinal| {
        const value = options.arrays.value(name, ordinal) orelse continue;
        if (hasGlobSyntax(value)) quoted_glob.* = true;
        try current.appendSlice(allocator, value);
        force_current_field.* = true;
        if (ordinal + 1 < len) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
            force_current_field.* = false;
        }
    }
}

fn appendQuotedArrayValuesStar(allocator: std.mem.Allocator, current: *std.ArrayList(u8), quoted_glob: *bool, name: []const u8, options: Options, ifs: []const u8) !void {
    const len = options.arrays.len(name);
    const separator = arrayJoinSeparatorFromIfs(ifs);
    for (0..len) |ordinal| {
        const value = options.arrays.value(name, ordinal) orelse continue;
        if (hasGlobSyntax(value)) quoted_glob.* = true;
        if (ordinal > 0) try current.appendSlice(allocator, separator);
        try current.appendSlice(allocator, value);
    }
}

fn appendQuotedArrayKeys(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, name: []const u8, options: Options) !void {
    const len = options.arrays.len(name);
    if (len == 0) {
        force_current_field.* = false;
        return;
    }
    for (0..len) |ordinal| {
        var buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        const key_text = try std.fmt.bufPrint(&buffer, "{d}", .{options.arrays.key(name, ordinal) orelse continue});
        try current.appendSlice(allocator, key_text);
        force_current_field.* = true;
        if (ordinal + 1 < len) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
            force_current_field.* = false;
        }
    }
}

fn appendQuotedArrayKeysStar(allocator: std.mem.Allocator, current: *std.ArrayList(u8), name: []const u8, options: Options, ifs: []const u8) !void {
    const len = options.arrays.len(name);
    const separator = arrayJoinSeparatorFromIfs(ifs);
    for (0..len) |ordinal| {
        var buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        const key_text = try std.fmt.bufPrint(&buffer, "{d}", .{options.arrays.key(name, ordinal) orelse continue});
        if (ordinal > 0) try current.appendSlice(allocator, separator);
        try current.appendSlice(allocator, key_text);
    }
}

fn appendQuotedNamePrefixAt(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), force_current_field: *bool, prefix: []const u8, options: Options) !void {
    const names = try matchingVariableNames(allocator, prefix, options);
    defer freeVariableNameList(allocator, names);
    if (names.len == 0) {
        force_current_field.* = false;
        return;
    }
    for (names, 0..) |name, index| {
        try current.appendSlice(allocator, name);
        force_current_field.* = true;
        if (index + 1 < names.len) {
            try fields.append(allocator, try current.toOwnedSlice(allocator));
            force_current_field.* = false;
        }
    }
}

fn appendQuotedNamePrefixStar(allocator: std.mem.Allocator, current: *std.ArrayList(u8), prefix: []const u8, options: Options, ifs: []const u8) !void {
    const names = try matchingVariableNames(allocator, prefix, options);
    defer freeVariableNameList(allocator, names);
    const joined = try joinNames(allocator, names, arrayJoinSeparatorFromIfs(ifs));
    defer allocator.free(joined);
    try current.appendSlice(allocator, joined);
}

fn joinArrayValues(allocator: std.mem.Allocator, name: []const u8, options: Options, separator: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    const len = options.arrays.len(name);
    for (0..len) |ordinal| {
        const value = options.arrays.value(name, ordinal) orelse continue;
        if (ordinal > 0) try joined.appendSlice(allocator, separator);
        try joined.appendSlice(allocator, value);
    }
    return joined.toOwnedSlice(allocator);
}

fn joinArrayKeys(allocator: std.mem.Allocator, name: []const u8, options: Options, separator: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    const len = options.arrays.len(name);
    for (0..len) |ordinal| {
        var buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        const key_text = try std.fmt.bufPrint(&buffer, "{d}", .{options.arrays.key(name, ordinal) orelse continue});
        if (ordinal > 0) try joined.appendSlice(allocator, separator);
        try joined.appendSlice(allocator, key_text);
    }
    return joined.toOwnedSlice(allocator);
}

fn matchingVariableNames(allocator: std.mem.Allocator, prefix: []const u8, options: Options) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    for (0..options.variable_names.count()) |ordinal| {
        const name = options.variable_names.name(ordinal) orelse continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (containsName(names.items, name)) continue;
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    return names.toOwnedSlice(allocator);
}

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn freeVariableNameList(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn joinNames(allocator: std.mem.Allocator, names: []const []const u8, separator: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (names, 0..) |name, index| {
        if (index > 0) try joined.appendSlice(allocator, separator);
        try joined.appendSlice(allocator, name);
    }
    return joined.toOwnedSlice(allocator);
}

fn arrayJoinSeparator(options: Options) []const u8 {
    return arrayJoinSeparatorFromIfs(options.env.get("IFS") orelse " \t\n");
}

fn arrayJoinSeparatorFromIfs(ifs: []const u8) []const u8 {
    return if (ifs.len == 0) "" else ifs[0..1];
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

fn appendSplitSegmentedText(allocator: std.mem.Allocator, fields: *std.ArrayList([]const u8), current: *std.ArrayList(u8), text: SegmentedText, ifs: []const u8) !void {
    std.debug.assert(text.text.len == text.split.len);
    if (ifs.len == 0) {
        try current.appendSlice(allocator, text.text);
        return;
    }

    var index: usize = 0;
    while (index < text.text.len) {
        const c = text.text[index];
        if (!text.split[index] or !isIfsChar(ifs, c)) {
            try current.append(allocator, c);
            index += 1;
            continue;
        }

        if (isIfsWhitespace(ifs, c)) {
            while (index < text.text.len and text.split[index] and isIfsWhitespace(ifs, text.text[index])) index += 1;
            // Quoted bytes terminate the delimiter run: they are data even when
            // they equal IFS characters.
            if (index < text.text.len and text.split[index] and isIfsChar(ifs, text.text[index])) continue;
            if (current.items.len != 0) {
                try fields.append(allocator, try current.toOwnedSlice(allocator));
            }
            continue;
        }

        try fields.append(allocator, try current.toOwnedSlice(allocator));
        index += 1;
        while (index < text.text.len and text.split[index] and isIfsWhitespace(ifs, text.text[index])) index += 1;
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

const PathnameExpansionOptions = struct {
    nullglob: bool = false,
    dotglob: bool = false,
    extglob: bool = false,
};

fn applyPathnameExpansion(allocator: std.mem.Allocator, io: std.Io, fields: *std.ArrayList([]const u8), options: PathnameExpansionOptions) !void {
    var expanded: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (expanded.items) |field| allocator.free(field);
        expanded.deinit(allocator);
    }

    for (fields.items) |field| {
        if (hasGlobSyntaxWithOptions(field, .{ .extglob = options.extglob })) {
            const matches = try expandPathnamePatternWithOptions(allocator, io, field, options);
            defer allocator.free(matches);
            if (matches.len != 0) {
                allocator.free(field);
                for (matches) |match| {
                    try expanded.append(allocator, match);
                }
                continue;
            }
            if (options.nullglob) {
                allocator.free(field);
                continue;
            }
        }
        try expanded.append(allocator, field);
    }

    fields.deinit(allocator);
    fields.* = expanded;
}

pub fn expandPathnamePattern(allocator: std.mem.Allocator, io: std.Io, pattern: []const u8) ![][]const u8 {
    return expandPathnamePatternWithOptions(allocator, io, pattern, .{});
}

fn expandPathnamePatternWithOptions(allocator: std.mem.Allocator, io: std.Io, pattern: []const u8, options: PathnameExpansionOptions) ![][]const u8 {
    const special = try allocator.alloc(bool, pattern.len);
    defer allocator.free(special);
    @memset(special, true);
    return expandPathnameExpansionPatternWithOptions(allocator, io, .{ .text = pattern, .special = special }, options);
}

pub fn expandPathnameExpansionPattern(allocator: std.mem.Allocator, io: std.Io, pattern: ExpansionPattern) ![][]const u8 {
    return expandPathnameExpansionPatternWithOptions(allocator, io, pattern, .{});
}

fn expandPathnameExpansionPatternWithOptions(allocator: std.mem.Allocator, io: std.Io, pattern: ExpansionPattern, options: PathnameExpansionOptions) ![][]const u8 {
    std.debug.assert(pattern.text.len == pattern.special.len);

    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |prefix| allocator.free(prefix);
        prefixes.deinit(allocator);
    }
    try prefixes.append(allocator, try allocator.dupe(u8, if (std.mem.startsWith(u8, pattern.text, "/")) "/" else ""));

    var component_start: usize = 0;
    while (component_start <= pattern.text.len) {
        const component_end = std.mem.indexOfScalarPos(u8, pattern.text, component_start, '/') orelse pattern.text.len;
        const component: ExpansionPattern = .{
            .text = pattern.text[component_start..component_end],
            .special = pattern.special[component_start..component_end],
        };
        if (component.text.len == 0 and prefixes.items.len == 1 and std.mem.eql(u8, prefixes.items[0], "/")) {
            if (component_end == pattern.text.len) break;
            component_start = component_end + 1;
            continue;
        }
        var next_prefixes: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (next_prefixes.items) |prefix| allocator.free(prefix);
            next_prefixes.deinit(allocator);
        }

        for (prefixes.items) |prefix| {
            if (patternHasGlobSyntaxWithOptions(component, .{ .extglob = options.extglob })) {
                try appendGlobComponentMatches(allocator, io, &next_prefixes, prefix, component, options);
            } else {
                const candidate = try joinPathComponent(allocator, prefix, component.text);
                errdefer allocator.free(candidate);
                if (try pathComponentExists(io, candidate)) try next_prefixes.append(allocator, candidate) else allocator.free(candidate);
            }
        }

        for (prefixes.items) |prefix| allocator.free(prefix);
        prefixes.deinit(allocator);
        prefixes = next_prefixes;

        if (component_end == pattern.text.len) break;
        component_start = component_end + 1;
    }

    std.mem.sort([]const u8, prefixes.items, {}, lessThanString);
    return prefixes.toOwnedSlice(allocator);
}

fn appendGlobComponentMatches(allocator: std.mem.Allocator, io: std.Io, matches: *std.ArrayList([]const u8), prefix: []const u8, component: ExpansionPattern, options: PathnameExpansionOptions) !void {
    const dir_path = if (prefix.len == 0) "." else prefix;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.' and !options.dotglob and (component.text.len == 0 or component.text[0] != '.')) continue;
        if (globPatternMatchesWithOptions(component, entry.name, .{ .extglob = options.extglob, .backslash_escape = false })) {
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

pub fn hasGlobSyntax(text: []const u8) bool {
    return hasGlobSyntaxWithOptions(text, .{});
}

const GlobSyntaxOptions = struct {
    extglob: bool = false,
};

fn hasGlobSyntaxWithOptions(text: []const u8, options: GlobSyntaxOptions) bool {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (options.extglob and startsExtglobOperator(text, null, index)) return true;
        switch (text[index]) {
            '*', '?' => return true,
            '[' => if (bracketExpressionEnd(text, null, index) != null) return true,
            else => {},
        }
    }
    return false;
}

pub fn patternHasGlobSyntax(pattern: ExpansionPattern) bool {
    return patternHasGlobSyntaxWithOptions(pattern, .{});
}

fn patternHasGlobSyntaxWithOptions(pattern: ExpansionPattern, options: GlobSyntaxOptions) bool {
    std.debug.assert(pattern.text.len == pattern.special.len);
    for (pattern.text, 0..) |c, index| {
        if (options.extglob and startsExtglobOperator(pattern.text, pattern.special, index)) return true;
        switch (c) {
            '*', '?' => if (pattern.special[index]) return true,
            '[' => if (pattern.special[index] and bracketExpressionEnd(pattern.text, pattern.special, index) != null) return true,
            else => {},
        }
    }
    return false;
}

fn hasQuotedGlobSyntax(parts: WordParts, options: GlobSyntaxOptions) bool {
    for (parts.parts) |part| switch (part.kind) {
        .escaped, .single_quoted, .dollar_single_quoted, .double_quoted => {
            if (hasGlobSyntaxWithOptions(part.value(parts.raw), options)) return true;
        },
        else => {},
    };
    return false;
}

fn startsExtglobOperator(pattern: []const u8, special: ?[]const bool, index: usize) bool {
    if (index + 1 >= pattern.len) return false;
    if (!isGlobSpecial(special, index) or !isGlobSpecial(special, index + 1)) return false;
    if (pattern[index + 1] != '(') return false;
    return switch (pattern[index]) {
        '@', '!', '+', '*', '?' => true,
        else => false,
    };
}

pub const PatternMatchOptions = struct {
    extglob: bool = false,
    backslash_escape: bool = true,
};

const GlobMatchOptions = PatternMatchOptions;

pub fn patternTextMatches(pattern: []const u8, text: []const u8, options: PatternMatchOptions) bool {
    return globMatchesAt(pattern, null, options, 0, text, 0);
}

pub fn patternMatches(pattern: ExpansionPattern, text: []const u8, options: PatternMatchOptions) bool {
    return globPatternMatchesWithOptions(pattern, text, options);
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    return globMatchesAt(pattern, null, .{}, 0, text, 0);
}

fn globPatternMatches(pattern: ExpansionPattern, text: []const u8) bool {
    return globPatternMatchesWithOptions(pattern, text, .{});
}

fn globPatternMatchesWithOptions(pattern: ExpansionPattern, text: []const u8, options: GlobMatchOptions) bool {
    std.debug.assert(pattern.text.len == pattern.special.len);
    return globMatchesAt(pattern.text, pattern.special, options, 0, text, 0);
}

fn isGlobSpecial(special: ?[]const bool, index: usize) bool {
    return if (special) |mask| mask[index] else true;
}

fn globMatchesAt(pattern: []const u8, special: ?[]const bool, options: GlobMatchOptions, pattern_index: usize, text: []const u8, text_index: usize) bool {
    if (pattern_index == pattern.len) return text_index == text.len;

    if (options.extglob) {
        if (parseExtglob(pattern, special, pattern_index)) |extglob| {
            return extglobMatches(pattern, special, options, extglob, text, text_index);
        }
    }

    switch (pattern[pattern_index]) {
        '*' => if (isGlobSpecial(special, pattern_index)) {
            var next_text = text_index;
            while (true) : (next_text += 1) {
                if (globMatchesAt(pattern, special, options, pattern_index + 1, text, next_text)) return true;
                if (next_text == text.len) break;
            }
            return false;
        } else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, options, pattern_index + 1, text, text_index + 1),
        '?' => if (isGlobSpecial(special, pattern_index)) return text_index < text.len and globMatchesAt(pattern, special, options, pattern_index + 1, text, text_index + 1) else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, options, pattern_index + 1, text, text_index + 1),
        '[' => if (isGlobSpecial(special, pattern_index)) {
            if (matchBracket(pattern, special, pattern_index, text, text_index)) |matched| {
                return matched.ok and globMatchesAt(pattern, special, options, matched.next_pattern, text, text_index + 1);
            }
            return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, options, pattern_index + 1, text, text_index + 1);
        } else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, options, pattern_index + 1, text, text_index + 1),
        '\\' => if (options.backslash_escape and isGlobSpecial(special, pattern_index)) {
            const escaped_index = pattern_index + 1;
            if (escaped_index >= pattern.len) return false;
            return text_index < text.len and pattern[escaped_index] == text[text_index] and globMatchesAt(pattern, special, options, escaped_index + 1, text, text_index + 1);
        } else return text_index < text.len and pattern[pattern_index] == text[text_index] and globMatchesAt(pattern, special, options, pattern_index + 1, text, text_index + 1),
        else => |c| return text_index < text.len and c == text[text_index] and globMatchesAt(pattern, special, options, pattern_index + 1, text, text_index + 1),
    }
}

const ExtglobPattern = struct {
    operator: u8,
    body_start: usize,
    body_end: usize,
    next_pattern: usize,
};

fn parseExtglob(pattern: []const u8, special: ?[]const bool, pattern_index: usize) ?ExtglobPattern {
    if (!startsExtglobOperator(pattern, special, pattern_index)) return null;
    var index = pattern_index + 2;
    var depth: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == '[' and isGlobSpecial(special, index)) {
            if (bracketExpressionEnd(pattern, special, index)) |end| {
                index = end;
                continue;
            }
        }
        if (startsExtglobOperator(pattern, special, index)) {
            depth += 1;
            index += 1;
            continue;
        }
        if (pattern[index] == ')' and isGlobSpecial(special, index)) {
            if (depth == 0) {
                return .{
                    .operator = pattern[pattern_index],
                    .body_start = pattern_index + 2,
                    .body_end = index,
                    .next_pattern = index + 1,
                };
            }
            depth -= 1;
        }
    }
    return null;
}

fn bracketExpressionEnd(pattern: []const u8, special: ?[]const bool, pattern_index: usize) ?usize {
    var index = pattern_index + 1;
    if (index < pattern.len and (pattern[index] == '!' or pattern[index] == '^') and isGlobSpecial(special, index)) index += 1;
    var first_expression = true;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']' and !first_expression and isGlobSpecial(special, index)) return index;
        first_expression = false;
    }
    return null;
}

fn extglobMatches(pattern: []const u8, special: ?[]const bool, options: GlobMatchOptions, extglob: ExtglobPattern, text: []const u8, text_index: usize) bool {
    return switch (extglob.operator) {
        '@' => extglobMatchOne(pattern, special, options, extglob, text, text_index),
        '?' => globMatchesAt(pattern, special, options, extglob.next_pattern, text, text_index) or extglobMatchOne(pattern, special, options, extglob, text, text_index),
        '*' => extglobMatchRepeat(pattern, special, options, extglob, text, text_index, false),
        '+' => extglobMatchRepeat(pattern, special, options, extglob, text, text_index, true),
        '!' => extglobMatchNegated(pattern, special, options, extglob, text, text_index),
        else => unreachable,
    };
}

fn extglobMatchOne(pattern: []const u8, special: ?[]const bool, options: GlobMatchOptions, extglob: ExtglobPattern, text: []const u8, text_index: usize) bool {
    var cursor = extglob.body_start;
    while (cursor <= extglob.body_end) {
        const alternative = nextExtglobAlternative(pattern, special, extglob.body_end, cursor);
        var end = text_index;
        while (end <= text.len) : (end += 1) {
            if (globMatchesAlternative(pattern, special, options, alternative, text[text_index..end]) and
                globMatchesAt(pattern, special, options, extglob.next_pattern, text, end)) return true;
        }
        if (alternative.next == null) break;
        cursor = alternative.next.?;
    }
    return false;
}

fn extglobMatchRepeat(pattern: []const u8, special: ?[]const bool, options: GlobMatchOptions, extglob: ExtglobPattern, text: []const u8, text_index: usize, require_one: bool) bool {
    if (!require_one and globMatchesAt(pattern, special, options, extglob.next_pattern, text, text_index)) return true;

    var cursor = extglob.body_start;
    while (cursor <= extglob.body_end) {
        const alternative = nextExtglobAlternative(pattern, special, extglob.body_end, cursor);
        var end = text_index;
        while (end <= text.len) : (end += 1) {
            if (!globMatchesAlternative(pattern, special, options, alternative, text[text_index..end])) continue;
            if (end == text_index) {
                if (require_one and globMatchesAt(pattern, special, options, extglob.next_pattern, text, end)) return true;
                continue;
            }
            if (extglobMatchRepeat(pattern, special, options, extglob, text, end, false)) return true;
        }
        if (alternative.next == null) break;
        cursor = alternative.next.?;
    }
    return false;
}

fn extglobMatchNegated(pattern: []const u8, special: ?[]const bool, options: GlobMatchOptions, extglob: ExtglobPattern, text: []const u8, text_index: usize) bool {
    var end = text_index;
    while (end <= text.len) : (end += 1) {
        if (!extglobBodyMatchesWhole(pattern, special, options, extglob, text[text_index..end]) and
            globMatchesAt(pattern, special, options, extglob.next_pattern, text, end)) return true;
    }
    return false;
}

fn extglobBodyMatchesWhole(pattern: []const u8, special: ?[]const bool, options: GlobMatchOptions, extglob: ExtglobPattern, text: []const u8) bool {
    var cursor = extglob.body_start;
    while (cursor <= extglob.body_end) {
        const alternative = nextExtglobAlternative(pattern, special, extglob.body_end, cursor);
        if (globMatchesAlternative(pattern, special, options, alternative, text)) return true;
        if (alternative.next == null) break;
        cursor = alternative.next.?;
    }
    return false;
}

fn globMatchesAlternative(pattern: []const u8, special: ?[]const bool, options: GlobMatchOptions, alternative: ExtglobAlternative, text: []const u8) bool {
    return globMatchesAt(
        pattern[alternative.start..alternative.end],
        if (special) |mask| mask[alternative.start..alternative.end] else null,
        options,
        0,
        text,
        0,
    );
}

const ExtglobAlternative = struct {
    start: usize,
    end: usize,
    next: ?usize,
};

fn nextExtglobAlternative(pattern: []const u8, special: ?[]const bool, body_end: usize, start: usize) ExtglobAlternative {
    var index = start;
    var depth: usize = 0;
    while (index < body_end) : (index += 1) {
        if (pattern[index] == '[' and isGlobSpecial(special, index)) {
            if (bracketExpressionEnd(pattern, special, index)) |end| {
                index = end;
                continue;
            }
        }
        if (startsExtglobOperator(pattern, special, index)) {
            depth += 1;
            index += 1;
            continue;
        }
        if (pattern[index] == ')' and isGlobSpecial(special, index) and depth != 0) {
            depth -= 1;
            continue;
        }
        if (pattern[index] == '|' and isGlobSpecial(special, index) and depth == 0) {
            return .{ .start = start, .end = index, .next = index + 1 };
        }
    }
    return .{ .start = start, .end = body_end, .next = null };
}

const BracketMatch = struct { ok: bool, next_pattern: usize };

fn matchBracket(pattern: []const u8, special: ?[]const bool, pattern_index: usize, text: []const u8, text_index: usize) ?BracketMatch {
    if (text_index >= text.len) return .{ .ok = false, .next_pattern = pattern_index + 1 };
    var index = pattern_index + 1;
    if (index >= pattern.len) return null;
    const negated = pattern[index] == '!' or pattern[index] == '^';
    if (negated) index += 1;

    var matched = false;
    var saw_end = false;
    var first_expression = true;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']' and !first_expression and isGlobSpecial(special, index)) {
            saw_end = true;
            break;
        }
        first_expression = false;
        if (matchBracketCharacterClass(pattern, special, index, text[text_index])) |class| {
            if (class.ok) matched = true;
            index = class.end_index;
            continue;
        }
        if (index + 2 < pattern.len and pattern[index + 1] == '-' and isGlobSpecial(special, index + 1) and pattern[index + 2] != ']') {
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

const BracketCharacterClassMatch = struct { ok: bool, end_index: usize };

fn matchBracketCharacterClass(pattern: []const u8, special: ?[]const bool, index: usize, text: u8) ?BracketCharacterClassMatch {
    if (index + 3 >= pattern.len or pattern[index] != '[' or pattern[index + 1] != ':') return null;

    const name_start = index + 2;
    var name_end = name_start;
    while (name_end + 1 < pattern.len) : (name_end += 1) {
        if (pattern[name_end] == ':' and pattern[name_end + 1] == ']') {
            if (!globPatternBytesAreSpecial(special, index, name_end + 2)) return null;
            const class_name = pattern[name_start..name_end];
            const ok = bracketCharacterClassMatches(class_name, text) orelse return null;
            return .{ .ok = ok, .end_index = name_end + 1 };
        }
    }
    return null;
}

fn globPatternBytesAreSpecial(special: ?[]const bool, start: usize, end: usize) bool {
    var index = start;
    while (index < end) : (index += 1) {
        if (!isGlobSpecial(special, index)) return false;
    }
    return true;
}

fn bracketCharacterClassMatches(class_name: []const u8, text: u8) ?bool {
    if (std.mem.eql(u8, class_name, "alnum")) return std.ascii.isAlphanumeric(text);
    if (std.mem.eql(u8, class_name, "alpha")) return std.ascii.isAlphabetic(text);
    if (std.mem.eql(u8, class_name, "blank")) return text == ' ' or text == '\t';
    if (std.mem.eql(u8, class_name, "cntrl")) return std.ascii.isControl(text);
    if (std.mem.eql(u8, class_name, "digit")) return std.ascii.isDigit(text);
    if (std.mem.eql(u8, class_name, "graph")) return std.ascii.isGraphical(text);
    if (std.mem.eql(u8, class_name, "lower")) return std.ascii.isLower(text);
    if (std.mem.eql(u8, class_name, "print")) return std.ascii.isPrint(text);
    if (std.mem.eql(u8, class_name, "punct")) return std.ascii.isPunctuation(text);
    if (std.mem.eql(u8, class_name, "space")) return std.ascii.isWhitespace(text);
    if (std.mem.eql(u8, class_name, "upper")) return std.ascii.isUpper(text);
    if (std.mem.eql(u8, class_name, "xdigit")) return std.ascii.isHex(text);
    return null;
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

/// Expands a here-document body (POSIX XCU 2.7.4): parameter expansion,
/// command substitution, and arithmetic expansion apply; quote characters are
/// not special except inside embedded expansions; backslash escapes only $,
/// backquote, backslash, and newline.
pub fn expandHereDocBody(allocator: std.mem.Allocator, text: []const u8, options: Options) anyerror![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const c = text[index];
        if (c == '\\' and index + 1 < text.len) {
            const next = text[index + 1];
            switch (next) {
                '$', '`', '\\' => {
                    try output.append(allocator, next);
                    index += 2;
                },
                '\n' => index += 2,
                else => {
                    try output.append(allocator, c);
                    index += 1;
                },
            }
            continue;
        }
        const part = (if (c == '$' or c == '`') try substitutionPart(allocator, text, index) else null) orelse {
            try output.append(allocator, c);
            index += 1;
            continue;
        };
        // No field splitting happens in a here-doc body, so $* joins with
        // the first IFS character like "$*" and $@ joins with spaces.
        if (part.kind == .parameter and std.mem.eql(u8, part.value(text), "*")) {
            const ifs = options.env.get("IFS") orelse " \t\n";
            // Here-doc bodies never undergo pathname expansion.
            var quoted_glob = false;
            try appendQuotedStar(allocator, &output, &quoted_glob, options.positionals, ifs);
            index = part.span.end;
            continue;
        }
        const rendered = try renderDoubleQuotedExpansion(allocator, text, part, options);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
        index = part.span.end;
    }
    return output.toOwnedSlice(allocator);
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
        const end = (try parser.parameterExpansionEnd(allocator, raw, raw.len, dollar)) orelse {
            try output.appendSlice(allocator, raw[dollar..]);
            index.* = raw.len;
            return true;
        };
        const rendered = try renderParameter(allocator, raw[name_start .. end - 1], options, false);
        defer allocator.free(rendered);
        try output.appendSlice(allocator, rendered);
        index.* = end;
        return true;
    }

    if (isSpecialParameterChar(raw[index.*])) {
        const rendered = try renderParameter(allocator, raw[index.* .. index.* + 1], options, false);
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
    const rendered = try renderParameter(allocator, raw[name_start..index.*], options, false);
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
            '$' => if (index + 1 < raw.len and raw[index + 1] == '\'') {
                const value_start = index + 2;
                index = value_start;
                while (index < raw.len) {
                    switch (raw[index]) {
                        '\\' => {
                            index += 1;
                            if (index < raw.len) index += 1;
                        },
                        '\'' => break,
                        else => index += 1,
                    }
                }
                const rendered = try renderDollarSingleQuotedContent(allocator, raw[value_start..index]);
                defer allocator.free(rendered);
                try output.appendSlice(allocator, rendered);
                if (index < raw.len) index += 1;
            } else {
                try output.append(allocator, '$');
                index += 1;
            },
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
    return std.ascii.isDigit(c) or c == '#' or c == '@' or c == '*' or c == '?' or c == '$' or c == '!' or c == '-';
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isDoubleQuoteBackslashEscaped(c: u8) bool {
    return c == '$' or c == '`' or c == '"' or c == '\\' or c == '\n';
}

fn isArithmeticBackslashEscaped(c: u8) bool {
    return c == '$' or c == '`' or c == '\\' or c == '\n';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c);
}

fn testCommandSubstitution(_: ?*anyopaque, allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    if (std.mem.eql(u8, script, "echo hi")) return allocator.dupe(u8, "hi\n\n");
    if (std.mem.eql(u8, script, "printf 2")) return allocator.dupe(u8, "2\n");
    if (std.mem.eql(u8, script, "printf /")) return allocator.dupe(u8, "/");
    if (std.mem.eql(u8, script, "printf '&X'")) return allocator.dupe(u8, "&X");
    if (std.mem.eql(u8, script, "printf 'a}b'")) return allocator.dupe(u8, "a}b");
    if (std.mem.eql(u8, script, "printf '}cd'")) return allocator.dupe(u8, "}cd");
    return allocator.dupe(u8, "");
}

const test_command_substitution: CommandSubstitution = .{ .runFn = testCommandSubstitution };

fn testLookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "#")) return "2";
    if (std.mem.eql(u8, name, "?")) return "0";
    if (std.mem.eql(u8, name, "0")) return "rush-test";
    if (std.mem.eql(u8, name, "HOME")) return "/home/rush";
    if (std.mem.eql(u8, name, "USER")) return "rush-user";
    if (std.mem.eql(u8, name, "USER_REF")) return "USER";
    if (std.mem.eql(u8, name, "STATUS_REF")) return "?";
    if (std.mem.eql(u8, name, "BAD_REF")) return "not-a-name";
    if (std.mem.eql(u8, name, "ARRAY_REF")) return "arr[2]";
    if (std.mem.eql(u8, name, "ARRAY_EXPR_REF")) return "arr[USER_NUM - 1]";
    if (std.mem.eql(u8, name, "ARRAY_NEG_REF")) return "arr[-1]";
    if (std.mem.eql(u8, name, "ARRAY_MISSING_REF")) return "arr[99]";
    if (std.mem.eql(u8, name, "ARRAY_VALUES_AT_REF")) return "arr[@]";
    if (std.mem.eql(u8, name, "ARRAY_VALUES_STAR_REF")) return "arr[*]";
    if (std.mem.eql(u8, name, "ARRAY_EMPTY_SUBSCRIPT_REF")) return "arr[]";
    if (std.mem.eql(u8, name, "ARRAY_UNCLOSED_SUBSCRIPT_REF")) return "arr[1";
    if (std.mem.eql(u8, name, "ARRAY_BAD_NAME_REF")) return "bad-name[0]";
    if (std.mem.eql(u8, name, "USER_NUM")) return "3";
    if (std.mem.eql(u8, name, "PADDED_NUM")) return " 42 ";
    if (std.mem.eql(u8, name, "TAB_PADDED_NUM")) return "\t42\t";
    if (std.mem.eql(u8, name, "PADDED_NEGATIVE_NUM")) return " -7 ";
    if (std.mem.eql(u8, name, "PADDED_BLANK_NUM")) return " \t ";
    if (std.mem.eql(u8, name, "WC_COUNT")) return "      12";
    if (std.mem.eql(u8, name, "MIN_INT")) return "-9223372036854775808";
    if (std.mem.eql(u8, name, "OCTAL_NUM")) return "010";
    if (std.mem.eql(u8, name, "HEX_NUM")) return "0x2f";
    if (std.mem.eql(u8, name, "NEGATIVE_OCTAL_NUM")) return "-010";
    if (std.mem.eql(u8, name, "EXPRESSION_VALUE")) return "1 + 2";
    if (std.mem.eql(u8, name, "PADDED_JUNK_VALUE")) return "42 junk";
    if (std.mem.eql(u8, name, "NESTED_PARAMETER_TEXT")) return "${MISSING:-2} + 1";
    if (std.mem.eql(u8, name, "WORDS")) return "one two\tthree";
    if (std.mem.eql(u8, name, "EMPTY")) return "";
    if (std.mem.eql(u8, name, "PATHLIKE")) return "/usr/local/bin/rush";
    if (std.mem.eql(u8, name, "AMP_REPL")) return "&X";
    if (std.mem.eql(u8, name, "ESC_AMP_REPL")) return "\\&X";
    if (std.mem.eql(u8, name, "BRACED")) return "ab}cd";
    if (std.mem.eql(u8, name, "GLOBBY")) return "rush-quoted-glob-?.tmp";
    return null;
}

const test_env: EnvLookup = .{ .lookupFn = testLookup };

const test_variable_names_items = [_][]const u8{
    "HOME",
    "USER",
    "USER_REF",
    "RUSH_PREFIX_ALPHA",
    "RUSH_PREFIX_BETA",
    "OTHER",
};

fn testVariableNameCount(_: ?*const anyopaque) usize {
    return test_variable_names_items.len;
}

fn testVariableNameAt(_: ?*const anyopaque, ordinal: usize) ?[]const u8 {
    if (ordinal >= test_variable_names_items.len) return null;
    return test_variable_names_items[ordinal];
}

const test_variable_names: VariableNames = .{ .countFn = testVariableNameCount, .nameFn = testVariableNameAt };

fn testArrayLookup(_: ?*const anyopaque, name: []const u8, index: usize) ?[]const u8 {
    if (!std.mem.eql(u8, name, "arr")) return null;
    return switch (index) {
        0 => "zero",
        2 => "two words",
        3 => "three",
        5 => "five",
        else => null,
    };
}

const test_array_keys = [_]usize{ 0, 2, 3, 5 };
const test_array_values = [_][]const u8{ "zero", "two words", "three", "five" };

fn testArrayLen(_: ?*const anyopaque, name: []const u8) usize {
    if (!std.mem.eql(u8, name, "arr")) return 0;
    return test_array_keys.len;
}

fn testArrayKey(_: ?*const anyopaque, name: []const u8, ordinal: usize) ?usize {
    if (!std.mem.eql(u8, name, "arr") or ordinal >= test_array_keys.len) return null;
    return test_array_keys[ordinal];
}

fn testArrayValue(_: ?*const anyopaque, name: []const u8, ordinal: usize) ?[]const u8 {
    if (!std.mem.eql(u8, name, "arr") or ordinal >= test_array_values.len) return null;
    return test_array_values[ordinal];
}

fn testArrayMaxIndex(_: ?*const anyopaque, name: []const u8) ?usize {
    if (!std.mem.eql(u8, name, "arr")) return null;
    return test_array_keys[test_array_keys.len - 1];
}

const test_arrays: ArrayLookup = .{
    .lookupFn = testArrayLookup,
    .lenFn = testArrayLen,
    .keyFn = testArrayKey,
    .valueFn = testArrayValue,
    .maxIndexFn = testArrayMaxIndex,
};

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

fn expectParameterSyntax(expression: []const u8) !ParameterExpansion {
    return expectParameterSyntaxWithFeatures(expression, .{});
}

fn expectParameterSyntaxWithFeatures(expression: []const u8, features: compat.Features) !ParameterExpansion {
    return switch (parseParameterExpansionSyntax(expression, features)) {
        .expansion => |parsed| parsed,
        .invalid => {
            try std.testing.expect(false);
            unreachable;
        },
    };
}

fn expectParameterTarget(target: ParameterTarget, kind: ParameterTargetKind, text: []const u8) !void {
    try std.testing.expectEqual(kind, target.kind);
    try std.testing.expectEqualStrings(text, target.text);
}

fn expectInvalidParameterSyntax(expression: []const u8) !void {
    switch (parseParameterExpansionSyntax(expression, .{})) {
        .invalid => {},
        .expansion => try std.testing.expect(false),
    }
}

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

test "word part parser records dollar single quotes as quoted word segments" {
    var parts = try parseWordParts(std.testing.allocator, "pre$'a\\n\\'b'post\"$'literal'\"");
    defer parts.deinit();

    try std.testing.expectEqual(@as(usize, 4), parts.parts.len);
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[0].kind);
    try std.testing.expectEqualStrings("pre", parts.parts[0].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.dollar_single_quoted, parts.parts[1].kind);
    try std.testing.expectEqualStrings("a\\n\\'b", parts.parts[1].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[2].kind);
    try std.testing.expectEqualStrings("post", parts.parts[2].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.double_quoted, parts.parts[3].kind);
    try std.testing.expectEqualStrings("$'literal'", parts.parts[3].value(parts.raw));
}

test "word part rendering expands parameters outside single quotes" {
    var parts = try parseWordParts(std.testing.allocator, "'$USER'\"$USER\"-$USER");
    defer parts.deinit();

    const rendered = try renderWordParts(std.testing.allocator, parts, .{ .env = test_env });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("$USERrush-user-rush-user", rendered);
}

test "dollar single quotes process POSIX escapes before expansion phases" {
    const scalar = try expandWordScalar(std.testing.allocator, "pre$'a\\n\\t\\\\\\'b'post:$'\\a\\b\\e\\f\\r\\v\\x41\\101'", .{});
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("prea\n\t\\'bpost:\x07\x08\x1b\x0c\r\x0bAA", scalar);

    var split = try expandWord(std.testing.allocator, "$'one two'", .{});
    defer split.deinit();
    try std.testing.expectEqual(@as(usize, 1), split.fields.len);
    try std.testing.expectEqualStrings("one two", split.fields[0]);

    var double_quoted = try expandWord(std.testing.allocator, "\"$'literal'\"", .{});
    defer double_quoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), double_quoted.fields.len);
    try std.testing.expectEqualStrings("$'literal'", double_quoted.fields[0]);
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

test "parameter-only expansion preserves non-parameter syntax" {
    const expanded = try expandParametersScalar(std.testing.allocator, "'$USER':${MISSING:-$USER}:$(printf '$USER'):`printf '$USER'`", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("'rush-user':rush-user:$(printf '$USER'):`printf '$USER'`", expanded);
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

    const hash_special = try expandWordScalar(std.testing.allocator, "${#}:${##}:${#:-fallback}:${#-fallback}:${#+alternate}:${#?required}:${#=fallback}", .{ .env = test_env });
    defer std.testing.allocator.free(hash_special);
    try std.testing.expectEqualStrings("2:1:2:2:alternate:2:2", hash_special);

    const hash_patterns = try expandWordScalar(std.testing.allocator, "${###}:${#%%}:${#%2}", .{ .env = test_env });
    defer std.testing.allocator.free(hash_patterns);
    try std.testing.expectEqualStrings("2:2:", hash_patterns);

    try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, "${MISSING:?required}", .{ .env = test_env }));
}

test "structured parameter parser classifies POSIX forms" {
    const simple = try expectParameterSyntax("USER");
    try expectParameterTarget(simple.target, .name, "USER");
    switch (simple.operation) {
        .value => {},
        else => try std.testing.expect(false),
    }

    const positional = try expectParameterSyntax("10");
    try expectParameterTarget(positional.target, .positional, "10");
    switch (positional.operation) {
        .value => {},
        else => try std.testing.expect(false),
    }

    const special = try expectParameterSyntax("@");
    try expectParameterTarget(special.target, .special, "@");
    switch (special.operation) {
        .value => {},
        else => try std.testing.expect(false),
    }

    const hash_special = try expectParameterSyntax("#");
    try expectParameterTarget(hash_special.target, .special, "#");
    switch (hash_special.operation) {
        .value => {},
        else => try std.testing.expect(false),
    }

    const length = try expectParameterSyntax("#USER");
    try expectParameterTarget(length.target, .name, "USER");
    switch (length.operation) {
        .length => {},
        else => try std.testing.expect(false),
    }

    const hash_length = try expectParameterSyntax("##");
    try expectParameterTarget(hash_length.target, .special, "#");
    switch (hash_length.operation) {
        .length => {},
        else => try std.testing.expect(false),
    }

    const default = try expectParameterSyntax("USER:-${OTHER}");
    try expectParameterTarget(default.target, .name, "USER");
    switch (default.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.default_value, operation.kind);
            try std.testing.expect(operation.colon);
            try std.testing.expectEqualStrings("${OTHER}", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_default = try expectParameterSyntax("#-fallback");
    try expectParameterTarget(hash_default.target, .special, "#");
    switch (hash_default.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.default_value, operation.kind);
            try std.testing.expect(!operation.colon);
            try std.testing.expectEqualStrings("fallback", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_colon_default = try expectParameterSyntax("#:-fallback");
    try expectParameterTarget(hash_colon_default.target, .special, "#");
    switch (hash_colon_default.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.default_value, operation.kind);
            try std.testing.expect(operation.colon);
            try std.testing.expectEqualStrings("fallback", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const assign = try expectParameterSyntax("USER=value");
    switch (assign.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.assign_default, operation.kind);
            try std.testing.expect(!operation.colon);
            try std.testing.expectEqualStrings("value", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_assign = try expectParameterSyntax("#=value");
    try expectParameterTarget(hash_assign.target, .special, "#");
    switch (hash_assign.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.assign_default, operation.kind);
            try std.testing.expect(!operation.colon);
            try std.testing.expectEqualStrings("value", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const alternate = try expectParameterSyntax("USER:+yes");
    switch (alternate.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.alternate_value, operation.kind);
            try std.testing.expect(operation.colon);
            try std.testing.expectEqualStrings("yes", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_alternate = try expectParameterSyntax("#+yes");
    try expectParameterTarget(hash_alternate.target, .special, "#");
    switch (hash_alternate.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.alternate_value, operation.kind);
            try std.testing.expect(!operation.colon);
            try std.testing.expectEqualStrings("yes", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const error_if_unset = try expectParameterSyntax("USER?message");
    switch (error_if_unset.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.error_if_unset, operation.kind);
            try std.testing.expect(!operation.colon);
            try std.testing.expectEqualStrings("message", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_error_if_unset = try expectParameterSyntax("#?message");
    try expectParameterTarget(hash_error_if_unset.target, .special, "#");
    switch (hash_error_if_unset.operation) {
        .word => |operation| {
            try std.testing.expectEqual(ParameterOperator.error_if_unset, operation.kind);
            try std.testing.expect(!operation.colon);
            try std.testing.expectEqualStrings("message", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const suffix = try expectParameterSyntax("PATHLIKE%%/*");
    switch (suffix.operation) {
        .pattern => |operation| {
            try std.testing.expectEqual(ParameterOperator.remove_large_suffix, operation.kind);
            try std.testing.expectEqualStrings("/*", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_suffix = try expectParameterSyntax("#%2");
    try expectParameterTarget(hash_suffix.target, .special, "#");
    switch (hash_suffix.operation) {
        .pattern => |operation| {
            try std.testing.expectEqual(ParameterOperator.remove_small_suffix, operation.kind);
            try std.testing.expectEqualStrings("2", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_large_suffix = try expectParameterSyntax("#%%");
    try expectParameterTarget(hash_large_suffix.target, .special, "#");
    switch (hash_large_suffix.operation) {
        .pattern => |operation| {
            try std.testing.expectEqual(ParameterOperator.remove_large_suffix, operation.kind);
            try std.testing.expectEqualStrings("", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const prefix = try expectParameterSyntax("PATHLIKE##*/");
    switch (prefix.operation) {
        .pattern => |operation| {
            try std.testing.expectEqual(ParameterOperator.remove_large_prefix, operation.kind);
            try std.testing.expectEqualStrings("*/", operation.word);
        },
        else => try std.testing.expect(false),
    }

    const hash_large_prefix = try expectParameterSyntax("###");
    try expectParameterTarget(hash_large_prefix.target, .special, "#");
    switch (hash_large_prefix.operation) {
        .pattern => |operation| {
            try std.testing.expectEqual(ParameterOperator.remove_large_prefix, operation.kind);
            try std.testing.expectEqualStrings("", operation.word);
        },
        else => try std.testing.expect(false),
    }
}

test "structured parameter parser rejects malformed POSIX forms" {
    const cases = [_][]const u8{
        "",
        ":",
        "USER/",
        "USER:1",
        "USER^",
        "1abc",
        "USER[0]",
        "arr[2]/two/TWO",
        "arr[@]^^",
        "#=",
        "#+",
        "#%",
        "#:#",
        "#abc:-x",
    };

    for (cases) |case| try expectInvalidParameterSyntax(case);
}

test "structured parameter parser accepts Bash indexed array expansion" {
    const indexed = try expectParameterSyntaxWithFeatures("arr[12]", compat.Features.bash());
    try expectParameterTarget(indexed.target, .name, "arr");
    switch (indexed.operation) {
        .array_index => |operation| try std.testing.expectEqualStrings("12", operation.index),
        else => try std.testing.expect(false),
    }

    const arithmetic = try expectParameterSyntaxWithFeatures("arr[USER_NUM - 1]", compat.Features.bash());
    try expectParameterTarget(arithmetic.target, .name, "arr");
    switch (arithmetic.operation) {
        .array_index => |operation| try std.testing.expectEqualStrings("USER_NUM - 1", operation.index),
        else => try std.testing.expect(false),
    }

    const nested_subscript = try expectParameterSyntaxWithFeatures("arr[$(printf ']')]", compat.Features.bash());
    try expectParameterTarget(nested_subscript.target, .name, "arr");
    switch (nested_subscript.operation) {
        .array_index => |operation| try std.testing.expectEqualStrings("$(printf ']')", operation.index),
        else => try std.testing.expect(false),
    }

    const invalid_cases = [_][]const u8{ "arr[]", "arr[1]x", "1[0]" };
    for (invalid_cases) |case| {
        switch (parseParameterExpansionSyntax(case, compat.Features.bash())) {
            .invalid => {},
            .expansion => try std.testing.expect(false),
        }
    }
}

test "structured parameter parser accepts Bash whole array operations" {
    const values = try expectParameterSyntaxWithFeatures("arr[@]", compat.Features.bash());
    try expectParameterTarget(values.target, .name, "arr");
    switch (values.operation) {
        .array_values => |operation| try std.testing.expectEqual(ParameterArrayWholeKind.at, operation.kind),
        else => try std.testing.expect(false),
    }

    const keys = try expectParameterSyntaxWithFeatures("!arr[*]", compat.Features.bash());
    try expectParameterTarget(keys.target, .name, "arr");
    switch (keys.operation) {
        .array_keys => |operation| try std.testing.expectEqual(ParameterArrayWholeKind.star, operation.kind),
        else => try std.testing.expect(false),
    }

    const length = try expectParameterSyntaxWithFeatures("#arr[@]", compat.Features.bash());
    try expectParameterTarget(length.target, .name, "arr");
    switch (length.operation) {
        .array_length => |operation| try std.testing.expectEqual(ParameterArrayWholeKind.at, operation.kind),
        else => try std.testing.expect(false),
    }

    try expectInvalidParameterSyntax("#arr[@]");
    try expectInvalidParameterSyntax("!arr[@]");
}

test "structured parameter parser accepts Bash indirect and name-prefix operations" {
    const indirect = try expectParameterSyntaxWithFeatures("!USER_REF", compat.Features.bash());
    try expectParameterTarget(indirect.target, .name, "USER_REF");
    switch (indirect.operation) {
        .indirect => {},
        else => try std.testing.expect(false),
    }

    const prefix_star = try expectParameterSyntaxWithFeatures("!RUSH_PREFIX_*", compat.Features.bash());
    try expectParameterTarget(prefix_star.target, .name, "RUSH_PREFIX_");
    switch (prefix_star.operation) {
        .name_prefix => |operation| try std.testing.expectEqual(ParameterArrayWholeKind.star, operation.kind),
        else => try std.testing.expect(false),
    }

    const prefix_at = try expectParameterSyntaxWithFeatures("!RUSH_PREFIX_@", compat.Features.bash());
    try expectParameterTarget(prefix_at.target, .name, "RUSH_PREFIX_");
    switch (prefix_at.operation) {
        .name_prefix => |operation| try std.testing.expectEqual(ParameterArrayWholeKind.at, operation.kind),
        else => try std.testing.expect(false),
    }

    try expectInvalidParameterSyntax("!USER_REF");
    try expectInvalidParameterSyntax("!RUSH_PREFIX_*");
}

test "structured parameter parser accepts Bash string operations" {
    const substring = try expectParameterSyntaxWithFeatures("USER:1:3", compat.Features.bash());
    try expectParameterTarget(substring.target, .name, "USER");
    switch (substring.operation) {
        .substring => |operation| {
            try std.testing.expectEqualStrings("1", operation.offset);
            try std.testing.expectEqualStrings("3", operation.length.?);
        },
        else => try std.testing.expect(false),
    }

    const positional_slice = try expectParameterSyntaxWithFeatures("@:2:3", compat.Features.bash());
    try expectParameterTarget(positional_slice.target, .special, "@");
    switch (positional_slice.operation) {
        .substring => |operation| {
            try std.testing.expectEqualStrings("2", operation.offset);
            try std.testing.expectEqualStrings("3", operation.length.?);
        },
        else => try std.testing.expect(false),
    }

    const nested_substring = try expectParameterSyntaxWithFeatures("USER:${MISSING:-1}:1", compat.Features.bash());
    switch (nested_substring.operation) {
        .substring => |operation| {
            try std.testing.expectEqualStrings("${MISSING:-1}", operation.offset);
            try std.testing.expectEqualStrings("1", operation.length.?);
        },
        else => try std.testing.expect(false),
    }

    const ternary_substring = try expectParameterSyntaxWithFeatures("USER:1 ? 2 : 3:1", compat.Features.bash());
    switch (ternary_substring.operation) {
        .substring => |operation| {
            try std.testing.expectEqualStrings("1 ? 2 : 3", operation.offset);
            try std.testing.expectEqualStrings("1", operation.length.?);
        },
        else => try std.testing.expect(false),
    }

    const replacement = try expectParameterSyntaxWithFeatures("PATHLIKE//\\//_", compat.Features.bash());
    try expectParameterTarget(replacement.target, .name, "PATHLIKE");
    switch (replacement.operation) {
        .replacement => |operation| {
            try std.testing.expectEqual(ParameterReplacementKind.global, operation.kind);
            try std.testing.expectEqualStrings("\\/", operation.pattern);
            try std.testing.expectEqualStrings("_", operation.replacement);
        },
        else => try std.testing.expect(false),
    }

    const nested_replacement = try expectParameterSyntaxWithFeatures("PATHLIKE/$(printf /)/_", compat.Features.bash());
    switch (nested_replacement.operation) {
        .replacement => |operation| {
            try std.testing.expectEqual(ParameterReplacementKind.first, operation.kind);
            try std.testing.expectEqualStrings("$(printf /)", operation.pattern);
            try std.testing.expectEqualStrings("_", operation.replacement);
        },
        else => try std.testing.expect(false),
    }

    const quoted_replacement = try expectParameterSyntaxWithFeatures("PATHLIKE/'/'/_", compat.Features.bash());
    switch (quoted_replacement.operation) {
        .replacement => |operation| {
            try std.testing.expectEqual(ParameterReplacementKind.first, operation.kind);
            try std.testing.expectEqualStrings("'/'", operation.pattern);
            try std.testing.expectEqualStrings("_", operation.replacement);
        },
        else => try std.testing.expect(false),
    }

    const prefix = try expectParameterSyntaxWithFeatures("PATHLIKE/#\\/*/root", compat.Features.bash());
    switch (prefix.operation) {
        .replacement => |operation| {
            try std.testing.expectEqual(ParameterReplacementKind.prefix, operation.kind);
            try std.testing.expectEqualStrings("\\/*", operation.pattern);
            try std.testing.expectEqualStrings("root", operation.replacement);
        },
        else => try std.testing.expect(false),
    }

    const nested_array_replacement = try expectParameterSyntaxWithFeatures("arr[$(printf ']')]/two/TWO", compat.Features.bash());
    try expectParameterTarget(nested_array_replacement.target, .name, "arr");
    switch (nested_array_replacement.array_subscript.?) {
        .index => |index| try std.testing.expectEqualStrings("$(printf ']')", index),
        .whole => try std.testing.expect(false),
    }
    switch (nested_array_replacement.operation) {
        .replacement => |operation| {
            try std.testing.expectEqual(ParameterReplacementKind.first, operation.kind);
            try std.testing.expectEqualStrings("two", operation.pattern);
            try std.testing.expectEqualStrings("TWO", operation.replacement);
        },
        else => try std.testing.expect(false),
    }

    const at_array_case_modification = try expectParameterSyntaxWithFeatures("arr[@]^^", compat.Features.bash());
    switch (at_array_case_modification.array_subscript.?) {
        .whole => |kind| try std.testing.expectEqual(ParameterArrayWholeKind.at, kind),
        .index => try std.testing.expect(false),
    }
    switch (at_array_case_modification.operation) {
        .case_modification => |operation| try std.testing.expectEqual(ParameterCaseKind.uppercase_all, operation.kind),
        else => try std.testing.expect(false),
    }

    const case_modification = try expectParameterSyntaxWithFeatures("USER^^", compat.Features.bash());
    switch (case_modification.operation) {
        .case_modification => |operation| {
            try std.testing.expectEqual(ParameterCaseKind.uppercase_all, operation.kind);
            try std.testing.expect(operation.pattern == null);
        },
        else => try std.testing.expect(false),
    }

    const patterned_case_modification = try expectParameterSyntaxWithFeatures("USER^^[[:lower:]]", compat.Features.bash());
    switch (patterned_case_modification.operation) {
        .case_modification => |operation| {
            try std.testing.expectEqual(ParameterCaseKind.uppercase_all, operation.kind);
            try std.testing.expectEqualStrings("[[:lower:]]", operation.pattern.?);
        },
        else => try std.testing.expect(false),
    }

    const array_substring = try expectParameterSyntaxWithFeatures("arr[2]:1:3", compat.Features.bash());
    try expectParameterTarget(array_substring.target, .name, "arr");
    switch (array_substring.array_subscript.?) {
        .index => |index| try std.testing.expectEqualStrings("2", index),
        .whole => try std.testing.expect(false),
    }
    switch (array_substring.operation) {
        .substring => |operation| {
            try std.testing.expectEqualStrings("1", operation.offset);
            try std.testing.expectEqualStrings("3", operation.length.?);
        },
        else => try std.testing.expect(false),
    }

    const array_replacement = try expectParameterSyntaxWithFeatures("arr[@]//o/O", compat.Features.bash());
    switch (array_replacement.array_subscript.?) {
        .whole => |kind| try std.testing.expectEqual(ParameterArrayWholeKind.at, kind),
        .index => try std.testing.expect(false),
    }
    switch (array_replacement.operation) {
        .replacement => |operation| {
            try std.testing.expectEqual(ParameterReplacementKind.global, operation.kind);
            try std.testing.expectEqualStrings("o", operation.pattern);
            try std.testing.expectEqualStrings("O", operation.replacement);
        },
        else => try std.testing.expect(false),
    }

    const array_case_modification = try expectParameterSyntaxWithFeatures("arr[*]^^[of]", compat.Features.bash());
    switch (array_case_modification.array_subscript.?) {
        .whole => |kind| try std.testing.expectEqual(ParameterArrayWholeKind.star, kind),
        .index => try std.testing.expect(false),
    }
    switch (array_case_modification.operation) {
        .case_modification => |operation| {
            try std.testing.expectEqual(ParameterCaseKind.uppercase_all, operation.kind);
            try std.testing.expectEqualStrings("[of]", operation.pattern.?);
        },
        else => try std.testing.expect(false),
    }

    try expectInvalidParameterSyntax("USER:1");
    try expectInvalidParameterSyntax("USER/a/b");
    try expectInvalidParameterSyntax("USER^^");
}

test "parameter assignment expansion rejects non-variable targets when assignment is needed" {
    const params = [_][]const u8{ "one", "" };

    const set_positional = try expandWordScalar(std.testing.allocator, "${1:=fallback}", .{ .positionals = &params });
    defer std.testing.allocator.free(set_positional);
    try std.testing.expectEqualStrings("one", set_positional);

    const null_positional_without_colon = try expandWordScalar(std.testing.allocator, "<${2=fallback}>", .{ .positionals = &params });
    defer std.testing.allocator.free(null_positional_without_colon);
    try std.testing.expectEqualStrings("<>", null_positional_without_colon);

    const cases = [_]struct {
        raw: []const u8,
        name: []const u8,
    }{
        .{ .raw = "${2:=fallback}", .name = "2" },
        .{ .raw = "${3=fallback}", .name = "3" },
        .{ .raw = "${10:=fallback}", .name = "10" },
        .{ .raw = "${@:=fallback}", .name = "@" },
        .{ .raw = "${-:=fallback}", .name = "-" },
    };

    for (cases) |case| {
        var parameter_error: ParameterError = .{};
        defer parameter_error.clear(std.testing.allocator);

        try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, case.raw, .{ .positionals = &params, .parameter_error = &parameter_error }));
        try std.testing.expectEqualStrings(case.name, parameter_error.name);
        try std.testing.expectEqualStrings("cannot assign in this way", parameter_error.message);
    }
}

test "parameter expansion rejects malformed braced forms" {
    const cases = [_][]const u8{
        "${}",
        "${:}",
        "${USER/}",
        "${USER:1}",
        "${USER:1:-1}",
        "${@:1:2}",
        "${*:1:2}",
        "${MISSING:-${@:1:2}}",
        "${USER^}",
        "${1abc}",
        "${!USER_REF}",
        "${!RUSH_PREFIX_*}",
        "${arr[2]/two/TWO}",
        "${arr[@]^^}",
        "${#=}",
        "${#+}",
        "${#%}",
        "${#:#}",
        "${#abc:-x}",
    };

    for (cases) |case| {
        var parameter_error: ParameterError = .{};
        defer parameter_error.clear(std.testing.allocator);

        try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, case, .{ .env = test_env, .parameter_error = &parameter_error }));
        try std.testing.expectEqualStrings("parameter", parameter_error.name);
        try std.testing.expectEqualStrings("bad substitution", parameter_error.message);
    }
}

test "parameter expansion supports Bash arithmetic indexed array subscripts" {
    const expanded = try expandWordScalar(std.testing.allocator, "${arr[USER_NUM - 1]}:${arr[$USER_NUM]}", .{ .env = test_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualStrings("two words:three", expanded);
}

test "parameter expansion supports Bash whole indexed array operations" {
    var unquoted_values = try expandWord(std.testing.allocator, "${arr[@]}", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer unquoted_values.deinit();
    try std.testing.expectEqual(@as(usize, 5), unquoted_values.fields.len);
    try std.testing.expectEqualStrings("zero", unquoted_values.fields[0]);
    try std.testing.expectEqualStrings("two", unquoted_values.fields[1]);
    try std.testing.expectEqualStrings("words", unquoted_values.fields[2]);
    try std.testing.expectEqualStrings("three", unquoted_values.fields[3]);
    try std.testing.expectEqualStrings("five", unquoted_values.fields[4]);

    var quoted_values = try expandWord(std.testing.allocator, "pre\"${arr[@]}\"post", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_values.deinit();
    try std.testing.expectEqual(@as(usize, 4), quoted_values.fields.len);
    try std.testing.expectEqualStrings("prezero", quoted_values.fields[0]);
    try std.testing.expectEqualStrings("two words", quoted_values.fields[1]);
    try std.testing.expectEqualStrings("three", quoted_values.fields[2]);
    try std.testing.expectEqualStrings("fivepost", quoted_values.fields[3]);

    var quoted_star = try expandWord(std.testing.allocator, "\"${arr[*]}\"", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_star.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_star.fields.len);
    try std.testing.expectEqualStrings("zero two words three five", quoted_star.fields[0]);

    var quoted_keys = try expandWord(std.testing.allocator, "\"${!arr[@]}\"", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_keys.deinit();
    try std.testing.expectEqual(@as(usize, 4), quoted_keys.fields.len);
    try std.testing.expectEqualStrings("0", quoted_keys.fields[0]);
    try std.testing.expectEqualStrings("2", quoted_keys.fields[1]);
    try std.testing.expectEqualStrings("3", quoted_keys.fields[2]);
    try std.testing.expectEqualStrings("5", quoted_keys.fields[3]);

    const scalar = try expandWordScalar(std.testing.allocator, "${#arr[@]}:${#arr[2]}:${arr[-1]}:${arr[-4]}:${!arr[*]}", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("4:9:five:two words:0 2 3 5", scalar);
}

test "parameter expansion supports Bash indirect and name-prefix operations" {
    const indirect = try expandWordScalar(std.testing.allocator, "${!USER_REF}:${!STATUS_REF}:${!BAD_REF}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(indirect);
    try std.testing.expectEqualStrings("rush-user:0:", indirect);

    const indirect_array = try expandWordScalar(std.testing.allocator, "${!ARRAY_REF}:${!ARRAY_EXPR_REF}:${!ARRAY_NEG_REF}:${!ARRAY_MISSING_REF}", .{ .env = test_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer std.testing.allocator.free(indirect_array);
    try std.testing.expectEqualStrings("two words:two words:five:", indirect_array);

    var unquoted_array = try expandWord(std.testing.allocator, "${!ARRAY_REF}", .{ .env = test_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer unquoted_array.deinit();
    try std.testing.expectEqual(@as(usize, 2), unquoted_array.fields.len);
    try std.testing.expectEqualStrings("two", unquoted_array.fields[0]);
    try std.testing.expectEqualStrings("words", unquoted_array.fields[1]);

    var quoted_array = try expandWord(std.testing.allocator, "\"${!ARRAY_REF}\"", .{ .env = test_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_array.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_array.fields.len);
    try std.testing.expectEqualStrings("two words", quoted_array.fields[0]);

    var unquoted_values = try expandWord(std.testing.allocator, "${!ARRAY_VALUES_AT_REF}", .{ .env = test_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer unquoted_values.deinit();
    try std.testing.expectEqual(@as(usize, 5), unquoted_values.fields.len);
    try std.testing.expectEqualStrings("zero", unquoted_values.fields[0]);
    try std.testing.expectEqualStrings("two", unquoted_values.fields[1]);
    try std.testing.expectEqualStrings("words", unquoted_values.fields[2]);
    try std.testing.expectEqualStrings("three", unquoted_values.fields[3]);
    try std.testing.expectEqualStrings("five", unquoted_values.fields[4]);

    var quoted_values = try expandWord(std.testing.allocator, "\"${!ARRAY_VALUES_AT_REF}\"", .{ .env = test_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_values.deinit();
    try std.testing.expectEqual(@as(usize, 4), quoted_values.fields.len);
    try std.testing.expectEqualStrings("zero", quoted_values.fields[0]);
    try std.testing.expectEqualStrings("two words", quoted_values.fields[1]);
    try std.testing.expectEqualStrings("three", quoted_values.fields[2]);
    try std.testing.expectEqualStrings("five", quoted_values.fields[3]);

    var quoted_star_values = try expandWord(std.testing.allocator, "\"${!ARRAY_VALUES_STAR_REF}\"", .{ .env = test_comma_ifs_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_star_values.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_star_values.fields.len);
    try std.testing.expectEqualStrings("zero,two words,three,five", quoted_star_values.fields[0]);

    const scalar = try expandWordScalar(std.testing.allocator, "${!RUSH_PREFIX_*}", .{ .env = test_env, .variable_names = test_variable_names, .features = compat.Features.bash() });
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("RUSH_PREFIX_ALPHA RUSH_PREFIX_BETA", scalar);

    var unquoted = try expandWord(std.testing.allocator, "${!RUSH_PREFIX_@}", .{ .env = test_env, .variable_names = test_variable_names, .features = compat.Features.bash() });
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 2), unquoted.fields.len);
    try std.testing.expectEqualStrings("RUSH_PREFIX_ALPHA", unquoted.fields[0]);
    try std.testing.expectEqualStrings("RUSH_PREFIX_BETA", unquoted.fields[1]);

    var quoted_star = try expandWord(std.testing.allocator, "\"${!RUSH_PREFIX_*}\"", .{ .env = test_comma_ifs_env, .variable_names = test_variable_names, .features = compat.Features.bash() });
    defer quoted_star.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_star.fields.len);
    try std.testing.expectEqualStrings("RUSH_PREFIX_ALPHA,RUSH_PREFIX_BETA", quoted_star.fields[0]);

    var quoted_at = try expandWord(std.testing.allocator, "\"${!RUSH_PREFIX_@}\"", .{ .env = test_comma_ifs_env, .variable_names = test_variable_names, .features = compat.Features.bash() });
    defer quoted_at.deinit();
    try std.testing.expectEqual(@as(usize, 2), quoted_at.fields.len);
    try std.testing.expectEqualStrings("RUSH_PREFIX_ALPHA", quoted_at.fields[0]);
    try std.testing.expectEqualStrings("RUSH_PREFIX_BETA", quoted_at.fields[1]);
}

test "parameter expansion supports Bash string operations" {
    const substring = try expandWordScalar(std.testing.allocator, "${PATHLIKE:1}:${PATHLIKE:5:5}:${PATHLIKE: -4:2}:${MISSING:1}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(substring);
    try std.testing.expectEqualStrings("usr/local/bin/rush:local:ru:", substring);

    const nested_substring = try expandWordScalar(std.testing.allocator, "${PATHLIKE:${MISSING:-1}:3}:${PATHLIKE:1 + (0 ? 9 : 2):3}:${PATHLIKE:0 ? 9 : 2:3}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(nested_substring);
    try std.testing.expectEqualStrings("usr:r/l:sr/", nested_substring);

    const negative_length_substring = try expandWordScalar(std.testing.allocator, "${PATHLIKE:1:-5}:${PATHLIKE: -4:-1}:${PATHLIKE: -99:-1}:${PATHLIKE:99:-1}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(negative_length_substring);
    try std.testing.expectEqualStrings("usr/local/bin:rus::", negative_length_substring);

    const params = [_][]const u8{ "01234567890abcdefgh", "abcdefg" };
    const positional_and_special_substring = try expandWordScalar(std.testing.allocator, "${1:7:-2}:${2: -4:-1}:${-:0:-1}", .{ .positionals = &params, .option_flags = "Cf", .features = compat.Features.bash() });
    defer std.testing.allocator.free(positional_and_special_substring);
    try std.testing.expectEqualStrings("7890abcdef:def:C", positional_and_special_substring);

    const replacement = try expandWordScalar(std.testing.allocator, "${PATHLIKE/local/LOCAL}:${PATHLIKE//\\//_}:${PATHLIKE/#\\/*/root}:${PATHLIKE/%rush/shell}:${PATHLIKE/bin}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(replacement);
    try std.testing.expectEqualStrings("/usr/LOCAL/bin/rush:_usr_local_bin_rush:root:/usr/local/bin/shell:/usr/local//rush", replacement);

    const nested_replacement = try expandWordScalar(std.testing.allocator, "${PATHLIKE/$(printf /)/_}:${PATHLIKE/'/'/_}", .{ .env = test_env, .features = compat.Features.bash(), .command_substitution = test_command_substitution });
    defer std.testing.allocator.free(nested_replacement);
    try std.testing.expectEqualStrings("_usr/local/bin/rush:_usr/local/bin/rush", nested_replacement);

    const pattern_replacement = try expandWordScalar(std.testing.allocator, "${PATHLIKE/b*/X}:${PATHLIKE/#\\/*/ROOT}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(pattern_replacement);
    try std.testing.expectEqualStrings("/usr/local/X:ROOT", pattern_replacement);

    const array_string_operations = try expandWordScalar(std.testing.allocator, "${arr[2]/two/TWO}:${arr[@]/e/E}:${arr[*]^^}", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer std.testing.allocator.free(array_string_operations);
    try std.testing.expectEqualStrings("TWO words:zEro two words thrEe fivE:ZERO TWO WORDS THREE FIVE", array_string_operations);

    const case_modification = try expandWordScalar(std.testing.allocator, "${USER^}:${USER^^}:${USER,}:${USER,,}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(case_modification);
    try std.testing.expectEqualStrings("Rush-user:RUSH-USER:rush-user:rush-user", case_modification);

    const patterned_case_modification = try expandWordScalar(std.testing.allocator, "${USER^^[rs]}:${USER^^[[:lower:]]}:${USER^[!r]}:${USER,,[RU]}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(patterned_case_modification);
    try std.testing.expectEqualStrings("RuSh-uSeR:RUSH-USER:rush-user:rush-user", patterned_case_modification);
}

test "parameter expansion supports Bash array string operations" {
    const element = try expandWordScalar(std.testing.allocator, "${arr[2]:1:3}:${arr[2]/words/WORDS}:${arr[2]^^[tw]}", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer std.testing.allocator.free(element);
    try std.testing.expectEqualStrings("wo :two WORDS:TWo Words", element);

    var quoted_slice = try expandWord(std.testing.allocator, "\"${arr[@]:2:2}\"", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_slice.deinit();
    try std.testing.expectEqual(@as(usize, 2), quoted_slice.fields.len);
    try std.testing.expectEqualStrings("two words", quoted_slice.fields[0]);
    try std.testing.expectEqualStrings("three", quoted_slice.fields[1]);

    var quoted_star_slice = try expandWord(std.testing.allocator, "\"${arr[*]:2:2}\"", .{ .env = test_comma_ifs_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_star_slice.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_star_slice.fields.len);
    try std.testing.expectEqualStrings("two words,three", quoted_star_slice.fields[0]);

    var quoted_replacement = try expandWord(std.testing.allocator, "\"${arr[@]//o/O}\"", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_replacement.deinit();
    try std.testing.expectEqual(@as(usize, 4), quoted_replacement.fields.len);
    try std.testing.expectEqualStrings("zerO", quoted_replacement.fields[0]);
    try std.testing.expectEqualStrings("twO wOrds", quoted_replacement.fields[1]);
    try std.testing.expectEqualStrings("three", quoted_replacement.fields[2]);
    try std.testing.expectEqualStrings("five", quoted_replacement.fields[3]);

    var quoted_star_replacement = try expandWord(std.testing.allocator, "\"${arr[*]//o/O}\"", .{ .env = test_comma_ifs_env, .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_star_replacement.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_star_replacement.fields.len);
    try std.testing.expectEqualStrings("zerO,twO wOrds,three,five", quoted_star_replacement.fields[0]);

    var unquoted_case_modification = try expandWord(std.testing.allocator, "${arr[@]^^[of]}", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer unquoted_case_modification.deinit();
    try std.testing.expectEqual(@as(usize, 5), unquoted_case_modification.fields.len);
    try std.testing.expectEqualStrings("zerO", unquoted_case_modification.fields[0]);
    try std.testing.expectEqualStrings("twO", unquoted_case_modification.fields[1]);
    try std.testing.expectEqualStrings("wOrds", unquoted_case_modification.fields[2]);
    try std.testing.expectEqualStrings("three", unquoted_case_modification.fields[3]);
    try std.testing.expectEqualStrings("Five", unquoted_case_modification.fields[4]);
}

test "parameter expansion supports Bash positional slice fields" {
    const params = [_][]const u8{ "a b", "", "c", "d" };

    var quoted_at = try expandWord(std.testing.allocator, "pre\"${@:2:2}\"post", .{ .env = test_env, .positionals = &params, .features = compat.Features.bash() });
    defer quoted_at.deinit();
    try std.testing.expectEqual(@as(usize, 2), quoted_at.fields.len);
    try std.testing.expectEqualStrings("pre", quoted_at.fields[0]);
    try std.testing.expectEqualStrings("cpost", quoted_at.fields[1]);

    var quoted_zero = try expandWord(std.testing.allocator, "\"${@:0:2}\"", .{ .env = test_env, .positionals = &params, .features = compat.Features.bash() });
    defer quoted_zero.deinit();
    try std.testing.expectEqual(@as(usize, 2), quoted_zero.fields.len);
    try std.testing.expectEqualStrings("rush-test", quoted_zero.fields[0]);
    try std.testing.expectEqualStrings("a b", quoted_zero.fields[1]);

    var quoted_star = try expandWord(std.testing.allocator, "\"${*:1:3}\"", .{ .env = test_comma_ifs_env, .positionals = &params, .features = compat.Features.bash() });
    defer quoted_star.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_star.fields.len);
    try std.testing.expectEqualStrings("a b,,c", quoted_star.fields[0]);

    var quoted_tail = try expandWord(std.testing.allocator, "\"${@:3}\"", .{ .positionals = &params, .features = compat.Features.bash() });
    defer quoted_tail.deinit();
    try std.testing.expectEqual(@as(usize, 2), quoted_tail.fields.len);
    try std.testing.expectEqualStrings("c", quoted_tail.fields[0]);
    try std.testing.expectEqualStrings("d", quoted_tail.fields[1]);

    var unquoted_at = try expandWord(std.testing.allocator, "${@:1:3}", .{ .positionals = &params, .features = compat.Features.bash() });
    defer unquoted_at.deinit();
    try std.testing.expectEqual(@as(usize, 3), unquoted_at.fields.len);
    try std.testing.expectEqualStrings("a", unquoted_at.fields[0]);
    try std.testing.expectEqualStrings("b", unquoted_at.fields[1]);
    try std.testing.expectEqualStrings("c", unquoted_at.fields[2]);

    var empty_quoted = try expandWord(std.testing.allocator, "\"${@:99:2}\"", .{ .positionals = &params, .features = compat.Features.bash() });
    defer empty_quoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty_quoted.fields.len);
    try std.testing.expectEqualStrings("", empty_quoted.fields[0]);

    var empty_unquoted = try expandWord(std.testing.allocator, "${@:99:2}", .{ .positionals = &params, .features = compat.Features.bash() });
    defer empty_unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_unquoted.fields.len);

    const scalar = try expandWordScalar(std.testing.allocator, "${@:1:3}:${*:2:2}", .{ .positionals = &params, .features = compat.Features.bash() });
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("a b  c: c", scalar);
}

test "parameter expansion supports Bash field producers in operator words" {
    const params = [_][]const u8{ "a b", "", "c", "d" };

    var unquoted_default = try expandWord(std.testing.allocator, "${missing:-${@:1:3}}", .{ .positionals = &params, .features = compat.Features.bash() });
    defer unquoted_default.deinit();
    try std.testing.expectEqual(@as(usize, 3), unquoted_default.fields.len);
    try std.testing.expectEqualStrings("a", unquoted_default.fields[0]);
    try std.testing.expectEqualStrings("b", unquoted_default.fields[1]);
    try std.testing.expectEqualStrings("c", unquoted_default.fields[2]);

    var quoted_default = try expandWord(std.testing.allocator, "\"${missing:-${@:1:3}}\"", .{ .positionals = &params, .features = compat.Features.bash() });
    defer quoted_default.deinit();
    try std.testing.expectEqual(@as(usize, 3), quoted_default.fields.len);
    try std.testing.expectEqualStrings("a b", quoted_default.fields[0]);
    try std.testing.expectEqualStrings("", quoted_default.fields[1]);
    try std.testing.expectEqualStrings("c", quoted_default.fields[2]);

    var embedded_quoted_default = try expandWord(std.testing.allocator, "pre\"${missing:-${@:2:2}}\"post", .{ .positionals = &params, .features = compat.Features.bash() });
    defer embedded_quoted_default.deinit();
    try std.testing.expectEqual(@as(usize, 2), embedded_quoted_default.fields.len);
    try std.testing.expectEqualStrings("pre", embedded_quoted_default.fields[0]);
    try std.testing.expectEqualStrings("cpost", embedded_quoted_default.fields[1]);

    var quoted_alternate = try expandWord(std.testing.allocator, "\"${USER:+${@:1:3}}\"", .{ .env = test_env, .positionals = &params, .features = compat.Features.bash() });
    defer quoted_alternate.deinit();
    try std.testing.expectEqual(@as(usize, 3), quoted_alternate.fields.len);
    try std.testing.expectEqualStrings("a b", quoted_alternate.fields[0]);
    try std.testing.expectEqualStrings("", quoted_alternate.fields[1]);
    try std.testing.expectEqualStrings("c", quoted_alternate.fields[2]);

    var quoted_at_word = try expandWord(std.testing.allocator, "\"${missing:-$@}\"", .{ .positionals = &params, .features = compat.Features.bash() });
    defer quoted_at_word.deinit();
    try std.testing.expectEqual(@as(usize, 4), quoted_at_word.fields.len);
    try std.testing.expectEqualStrings("a b", quoted_at_word.fields[0]);
    try std.testing.expectEqualStrings("", quoted_at_word.fields[1]);
    try std.testing.expectEqualStrings("c", quoted_at_word.fields[2]);
    try std.testing.expectEqualStrings("d", quoted_at_word.fields[3]);

    var quoted_array_default = try expandWord(std.testing.allocator, "\"${missing:-${arr[@]}}\"", .{ .arrays = test_arrays, .features = compat.Features.bash() });
    defer quoted_array_default.deinit();
    try std.testing.expectEqual(@as(usize, 4), quoted_array_default.fields.len);
    try std.testing.expectEqualStrings("zero", quoted_array_default.fields[0]);
    try std.testing.expectEqualStrings("two words", quoted_array_default.fields[1]);
    try std.testing.expectEqualStrings("three", quoted_array_default.fields[2]);
    try std.testing.expectEqualStrings("five", quoted_array_default.fields[3]);
}

test "parameter assignment operator words store Bash scalar field producer values" {
    const params = [_][]const u8{ "a b", "", "c", "d" };

    var quoted_word_recorder: ArithmeticSetRecorder = .{};
    var quoted_word = try expandWord(std.testing.allocator, "${assigned:=\"one two\"}", .{ .env_set = quoted_word_recorder.envSet(), .features = compat.Features.bash() });
    defer quoted_word.deinit();
    try std.testing.expectEqual(@as(usize, 2), quoted_word.fields.len);
    try std.testing.expectEqualStrings("one", quoted_word.fields[0]);
    try std.testing.expectEqualStrings("two", quoted_word.fields[1]);
    try std.testing.expectEqual(@as(usize, 1), quoted_word_recorder.count);
    try std.testing.expectEqualStrings("one two", quoted_word_recorder.lastValue());

    var quoted_at_recorder: ArithmeticSetRecorder = .{};
    var quoted_at = try expandWord(std.testing.allocator, "\"${assigned:=$@}\"", .{ .positionals = &params, .env_set = quoted_at_recorder.envSet(), .features = compat.Features.bash() });
    defer quoted_at.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_at.fields.len);
    try std.testing.expectEqualStrings("a b  c d", quoted_at.fields[0]);
    try std.testing.expectEqual(@as(usize, 1), quoted_at_recorder.count);
    try std.testing.expectEqualStrings("a b  c d", quoted_at_recorder.lastValue());

    var unquoted_slice_recorder: ArithmeticSetRecorder = .{};
    var unquoted_slice = try expandWord(std.testing.allocator, "${assigned:=${@:1:3}}", .{ .positionals = &params, .env = test_comma_ifs_env, .env_set = unquoted_slice_recorder.envSet(), .features = compat.Features.bash() });
    defer unquoted_slice.deinit();
    try std.testing.expectEqual(@as(usize, 1), unquoted_slice.fields.len);
    try std.testing.expectEqualStrings("a b  c", unquoted_slice.fields[0]);
    try std.testing.expectEqual(@as(usize, 1), unquoted_slice_recorder.count);
    try std.testing.expectEqualStrings("a b  c", unquoted_slice_recorder.lastValue());

    var quoted_slice_recorder: ArithmeticSetRecorder = .{};
    var quoted_slice = try expandWord(std.testing.allocator, "\"${assigned:=${@:1:3}}\"", .{ .positionals = &params, .env = test_comma_ifs_env, .env_set = quoted_slice_recorder.envSet(), .features = compat.Features.bash() });
    defer quoted_slice.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_slice.fields.len);
    try std.testing.expectEqualStrings("a b,,c", quoted_slice.fields[0]);
    try std.testing.expectEqual(@as(usize, 1), quoted_slice_recorder.count);
    try std.testing.expectEqualStrings("a b,,c", quoted_slice_recorder.lastValue());

    var array_at_recorder: ArithmeticSetRecorder = .{};
    var array_at = try expandWord(std.testing.allocator, "\"${assigned:=${arr[@]}}\"", .{ .env = test_comma_ifs_env, .arrays = test_arrays, .env_set = array_at_recorder.envSet(), .features = compat.Features.bash() });
    defer array_at.deinit();
    try std.testing.expectEqual(@as(usize, 1), array_at.fields.len);
    try std.testing.expectEqualStrings("zero two words three five", array_at.fields[0]);
    try std.testing.expectEqual(@as(usize, 1), array_at_recorder.count);
    try std.testing.expectEqualStrings("zero two words three five", array_at_recorder.lastValue());

    var array_keys_recorder: ArithmeticSetRecorder = .{};
    var array_keys = try expandWord(std.testing.allocator, "${assigned:=${!arr[@]}}", .{ .env = test_comma_ifs_env, .arrays = test_arrays, .env_set = array_keys_recorder.envSet(), .features = compat.Features.bash() });
    defer array_keys.deinit();
    try std.testing.expectEqual(@as(usize, 1), array_keys.fields.len);
    try std.testing.expectEqualStrings("0 2 3 5", array_keys.fields[0]);
    try std.testing.expectEqual(@as(usize, 1), array_keys_recorder.count);
    try std.testing.expectEqualStrings("0 2 3 5", array_keys_recorder.lastValue());
}

test "parameter expansion diagnoses Bash negative substring lengths before the start" {
    const params = [_][]const u8{"abcdefg"};
    const cases = [_]struct {
        raw: []const u8,
        name: []const u8,
    }{
        .{ .raw = "${PATHLIKE:15:-5}", .name = "-5" },
        .{ .raw = "${1:5:-3}", .name = "-3" },
        .{ .raw = "${-:1:-2}", .name = "-2" },
        .{ .raw = "${@:2:-1}", .name = "-1" },
        .{ .raw = "${*:1:-2}", .name = "-2" },
    };

    for (cases) |case| {
        var parameter_error: ParameterError = .{};
        defer parameter_error.clear(std.testing.allocator);

        try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, case.raw, .{ .env = test_env, .positionals = &params, .option_flags = "Cf", .features = compat.Features.bash(), .parameter_error = &parameter_error }));
        try std.testing.expectEqualStrings(case.name, parameter_error.name);
        try std.testing.expectEqualStrings("substring expression < 0", parameter_error.message);
    }

    var out_of_range = try expandWord(std.testing.allocator, "\"${@:99:-1}\"", .{ .positionals = &params, .features = compat.Features.bash() });
    defer out_of_range.deinit();
    try std.testing.expectEqual(@as(usize, 1), out_of_range.fields.len);
    try std.testing.expectEqualStrings("", out_of_range.fields[0]);
}

test "parameter expansion supports Bash replacement ampersand expansion" {
    const direct = try expandWordScalar(std.testing.allocator, "${USER/rush/[&]}:${USER/rush/[\\&]}:${USER/rush/['&']}:${USER/rush/[\"&\"]}:${USER/rush/[\\\\&]}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(direct);
    try std.testing.expectEqualStrings("[rush]-user:[&]-user:[&]-user:[&]-user:[\\rush]-user", direct);

    const nested = try expandWordScalar(std.testing.allocator, "${USER/rush/$AMP_REPL}:${USER/rush/\"$AMP_REPL\"}:${USER/rush/$ESC_AMP_REPL}:${USER/rush/$(printf '&X')}:${USER/rush/\"$(printf '&X')\"}", .{ .env = test_env, .features = compat.Features.bash(), .command_substitution = test_command_substitution });
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("rushX-user:&X-user:&X-user:rushX-user:&X-user", nested);

    const disabled = try expandWordScalar(std.testing.allocator, "${USER/rush/[&]}:${USER/rush/$AMP_REPL}:${USER/rush/$(printf '&X')}", .{ .env = test_env, .features = compat.Features.bash(), .command_substitution = test_command_substitution, .patsub_replacement = false });
    defer std.testing.allocator.free(disabled);
    try std.testing.expectEqualStrings("[&]-user:&X-user:&X-user", disabled);
}

test "parameter expansion diagnoses malformed Bash indirect array targets" {
    const cases = [_]struct {
        raw: []const u8,
        name: []const u8,
    }{
        .{ .raw = "${!ARRAY_EMPTY_SUBSCRIPT_REF}", .name = "arr[]" },
        .{ .raw = "${!ARRAY_UNCLOSED_SUBSCRIPT_REF}", .name = "arr[1" },
        .{ .raw = "${!ARRAY_BAD_NAME_REF}", .name = "bad-name[0]" },
    };

    for (cases) |case| {
        var parameter_error: ParameterError = .{};
        defer parameter_error.clear(std.testing.allocator);

        try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, case.raw, .{ .env = test_env, .features = compat.Features.bash(), .parameter_error = &parameter_error }));
        try std.testing.expectEqualStrings(case.name, parameter_error.name);
        try std.testing.expectEqualStrings("invalid variable name", parameter_error.message);
    }
}

test "parameter expansion handles Bash negative array subscripts on missing arrays" {
    var parameter_error: ParameterError = .{};
    defer parameter_error.clear(std.testing.allocator);

    try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, "${missing[-1]}", .{ .features = compat.Features.bash(), .parameter_error = &parameter_error }));
    try std.testing.expectEqualStrings("missing", parameter_error.name);
    try std.testing.expectEqualStrings("bad array subscript", parameter_error.message);

    const missing_length = try expandWordScalar(std.testing.allocator, "${#missing[-1]}", .{ .features = compat.Features.bash() });
    defer std.testing.allocator.free(missing_length);
    try std.testing.expectEqualStrings("0", missing_length);
}

test "parameter expansion reports arithmetic errors in Bash array subscripts" {
    var arithmetic_error: ArithmeticError = .{};
    defer arithmetic_error.clear(std.testing.allocator);

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "${arr[1 / 0]}", .{ .arrays = test_arrays, .features = compat.Features.bash(), .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("1 / 0", arithmetic_error.expression);
    try std.testing.expectEqualStrings("division by zero", arithmetic_error.message);
}

test "parameter expansion supports pattern removal operators" {
    const expanded = try expandWordScalar(std.testing.allocator, "${PATHLIKE%/*}:${PATHLIKE%%/*}:${PATHLIKE#*/}:${PATHLIKE##*/}", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualStrings("/usr/local/bin::usr/local/bin/rush:rush", expanded);

    const class = try expandWordScalar(std.testing.allocator, "${PATHLIKE%%[[:digit:]]*}:${PATHLIKE##*[![:lower:]]}", .{ .env = test_env });
    defer std.testing.allocator.free(class);
    try std.testing.expectEqualStrings("/usr/local/bin/rush:rush", class);

    const quoted_class = try expandWordScalar(std.testing.allocator, "${USER_NUM#\"[[:digit:]]\"}", .{ .env = test_env });
    defer std.testing.allocator.free(quoted_class);
    try std.testing.expectEqualStrings("3", quoted_class);

    const extglob_off = try expandWordScalar(std.testing.allocator, "${USER#@(rush|bash)-}", .{ .env = test_env, .features = compat.Features.bash() });
    defer std.testing.allocator.free(extglob_off);
    try std.testing.expectEqualStrings("rush-user", extglob_off);

    const extglob_on = try expandWordScalar(std.testing.allocator, "${USER#@(rush|bash)-}", .{ .env = test_env, .features = compat.Features.bash(), .extglob = true });
    defer std.testing.allocator.free(extglob_on);
    try std.testing.expectEqualStrings("user", extglob_on);
}

test "parameter pattern removal treats unquoted expansion backslashes as pattern escapes" {
    const env: EnvLookup = .{ .lookupFn = struct {
        fn lookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "ABC")) return "abc";
            if (std.mem.eql(u8, name, "AB_BACKSLASH")) return "ab\\";
            if (std.mem.eql(u8, name, "ESC_A")) return "\\a";
            if (std.mem.eql(u8, name, "ESC_C")) return "\\c";
            if (std.mem.eql(u8, name, "ONE_BACKSLASH")) return "\\";
            if (std.mem.eql(u8, name, "TWO_BACKSLASHES")) return "\\\\";
            return null;
        }
    }.lookup };

    const prefix = try expandWordScalar(std.testing.allocator, "${ABC#$ESC_A}", .{ .env = env });
    defer std.testing.allocator.free(prefix);
    try std.testing.expectEqualStrings("bc", prefix);

    const suffix = try expandWordScalar(std.testing.allocator, "${ABC%$ESC_C}", .{ .env = env });
    defer std.testing.allocator.free(suffix);
    try std.testing.expectEqualStrings("ab", suffix);

    const escaped_backslash = try expandWordScalar(std.testing.allocator, "${AB_BACKSLASH%$TWO_BACKSLASHES}", .{ .env = env });
    defer std.testing.allocator.free(escaped_backslash);
    try std.testing.expectEqualStrings("ab", escaped_backslash);

    const trailing_escape = try expandWordScalar(std.testing.allocator, "${AB_BACKSLASH%$ONE_BACKSLASH}", .{ .env = env });
    defer std.testing.allocator.free(trailing_escape);
    try std.testing.expectEqualStrings("ab\\", trailing_escape);

    const quoted = try expandWordScalar(std.testing.allocator, "${AB_BACKSLASH%\"$ONE_BACKSLASH\"}", .{ .env = env });
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("ab", quoted);
}

test "parameter pattern removal operators honor nounset" {
    const cases = [_][]const u8{
        "${MISSING%foo}",
        "${MISSING%%foo}",
        "${MISSING#foo}",
        "${MISSING##foo}",
        "\"${MISSING%foo}\"",
    };
    for (cases) |case| {
        try std.testing.expectError(error.NounsetParameter, expandWord(std.testing.allocator, case, .{ .nounset = true }));
    }

    const unset_without_nounset = try expandWordScalar(std.testing.allocator, "${MISSING%foo}:${MISSING#foo}", .{});
    defer std.testing.allocator.free(unset_without_nounset);
    try std.testing.expectEqualStrings(":", unset_without_nounset);
}

test "glob matcher supports extglob operators when enabled" {
    var exactly_one = try expandWordPattern(std.testing.allocator, "@(foo|bar)", .{});
    defer exactly_one.deinit(std.testing.allocator);
    try std.testing.expect(!globPatternMatches(exactly_one, "foo"));
    try std.testing.expect(globPatternMatchesWithOptions(exactly_one, "foo", .{ .extglob = true }));
    try std.testing.expect(globPatternMatchesWithOptions(exactly_one, "bar", .{ .extglob = true }));
    try std.testing.expect(!globPatternMatchesWithOptions(exactly_one, "baz", .{ .extglob = true }));

    var zero_or_one = try expandWordPattern(std.testing.allocator, "?(foo|bar)baz", .{});
    defer zero_or_one.deinit(std.testing.allocator);
    try std.testing.expect(globPatternMatchesWithOptions(zero_or_one, "baz", .{ .extglob = true }));
    try std.testing.expect(globPatternMatchesWithOptions(zero_or_one, "foobaz", .{ .extglob = true }));
    try std.testing.expect(!globPatternMatchesWithOptions(zero_or_one, "foofoobaz", .{ .extglob = true }));

    var zero_or_more = try expandWordPattern(std.testing.allocator, "*(ab|c)", .{});
    defer zero_or_more.deinit(std.testing.allocator);
    try std.testing.expect(globPatternMatchesWithOptions(zero_or_more, "", .{ .extglob = true }));
    try std.testing.expect(globPatternMatchesWithOptions(zero_or_more, "ababc", .{ .extglob = true }));

    var one_or_more = try expandWordPattern(std.testing.allocator, "+(ab|c)", .{});
    defer one_or_more.deinit(std.testing.allocator);
    try std.testing.expect(!globPatternMatchesWithOptions(one_or_more, "", .{ .extglob = true }));
    try std.testing.expect(globPatternMatchesWithOptions(one_or_more, "ababc", .{ .extglob = true }));

    var negated = try expandWordPattern(std.testing.allocator, "!(foo|bar)", .{});
    defer negated.deinit(std.testing.allocator);
    try std.testing.expect(globPatternMatchesWithOptions(negated, "baz", .{ .extglob = true }));
    try std.testing.expect(!globPatternMatchesWithOptions(negated, "foo", .{ .extglob = true }));

    var nested = try expandWordPattern(std.testing.allocator, "@(x|+(ab|c))", .{});
    defer nested.deinit(std.testing.allocator);
    try std.testing.expect(globPatternMatchesWithOptions(nested, "x", .{ .extglob = true }));
    try std.testing.expect(globPatternMatchesWithOptions(nested, "abc", .{ .extglob = true }));
}

test "glob syntax detection requires complete bracket expressions" {
    try std.testing.expect(!hasGlobSyntax("["));
    try std.testing.expect(!hasGlobSyntax("rush-["));
    try std.testing.expect(!hasGlobSyntax("rush-]"));
    try std.testing.expect(!hasGlobSyntax("[!]"));
    try std.testing.expect(hasGlobSyntax("[a]"));
    try std.testing.expect(hasGlobSyntax("[]]"));
    try std.testing.expect(hasGlobSyntax("[!]]"));
    try std.testing.expect(hasGlobSyntax("*"));
    try std.testing.expect(hasGlobSyntax("?"));

    const all_special = [_]bool{ true, true, true };
    try std.testing.expect(patternHasGlobSyntax(.{ .text = "[a]", .special = &all_special }));

    const quoted_close = [_]bool{ true, true, false };
    try std.testing.expect(!patternHasGlobSyntax(.{ .text = "[a]", .special = &quoted_close }));
}

test "parameter operator word spans skip nested substitutions and quoted braces" {
    const nested = try expandWordScalar(std.testing.allocator, "${MISSING:-$(printf 'a}b')}:${MISSING:-${USER}}:${MISSING:-$((1 + 2))}", .{ .env = test_env, .command_substitution = test_command_substitution });
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("a}b:rush-user:3", nested);

    const pattern = try expandWordScalar(std.testing.allocator, "${BRACED%$(printf '}cd')}:${BRACED%\"}cd\"}", .{ .env = test_env, .command_substitution = test_command_substitution });
    defer std.testing.allocator.free(pattern);
    try std.testing.expectEqualStrings("ab:ab", pattern);
}

test "parameter operator word quotes suppress field splitting" {
    var quoted = try expandWord(std.testing.allocator, "${MISSING:-\"one two\"}", .{ .env = test_env });
    defer quoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted.fields.len);
    try std.testing.expectEqualStrings("one two", quoted.fields[0]);

    var unquoted = try expandWord(std.testing.allocator, "${MISSING:-one two}", .{ .env = test_env });
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 2), unquoted.fields.len);
    try std.testing.expectEqualStrings("one", unquoted.fields[0]);
    try std.testing.expectEqualStrings("two", unquoted.fields[1]);

    var empty = try expandWord(std.testing.allocator, "${MISSING:-\"\"}", .{ .env = test_env });
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty.fields.len);
    try std.testing.expectEqualStrings("", empty.fields[0]);
}

test "quoted parameter operator words keep single quotes literal" {
    var default = try expandWord(std.testing.allocator, "\"${MISSING-'a'}\"", .{ .env = test_env });
    defer default.deinit();
    try std.testing.expectEqual(@as(usize, 1), default.fields.len);
    try std.testing.expectEqualStrings("'a'", default.fields[0]);

    var colon_default = try expandWord(std.testing.allocator, "\"${EMPTY:-'a b'}\"", .{ .env = test_env });
    defer colon_default.deinit();
    try std.testing.expectEqual(@as(usize, 1), colon_default.fields.len);
    try std.testing.expectEqualStrings("'a b'", colon_default.fields[0]);

    var alternate = try expandWord(std.testing.allocator, "\"${USER:+'$USER'}\"", .{ .env = test_env });
    defer alternate.deinit();
    try std.testing.expectEqual(@as(usize, 1), alternate.fields.len);
    try std.testing.expectEqualStrings("'rush-user'", alternate.fields[0]);

    var assign_recorder: ArithmeticSetRecorder = .{};
    var assign = try expandWord(std.testing.allocator, "\"${ASSIGNED:='a'}\"", .{ .env = test_env, .env_set = assign_recorder.envSet() });
    defer assign.deinit();
    try std.testing.expectEqual(@as(usize, 1), assign.fields.len);
    try std.testing.expectEqualStrings("'a'", assign.fields[0]);
    try std.testing.expectEqualStrings("'a'", assign_recorder.lastValue());

    var parameter_error: ParameterError = .{};
    defer parameter_error.clear(std.testing.allocator);
    try std.testing.expectError(error.ParameterExpansionFailed, expandWordScalar(std.testing.allocator, "\"${MISSING?'$USER'}\"", .{ .env = test_env, .parameter_error = &parameter_error }));
    try std.testing.expectEqualStrings("'rush-user'", parameter_error.message);

    var unquoted = try expandWord(std.testing.allocator, "${MISSING-'a'}", .{ .env = test_env });
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), unquoted.fields.len);
    try std.testing.expectEqualStrings("a", unquoted.fields[0]);
}

test "expand word returns fields through an explicit result" {
    var result = try expandWord(std.testing.allocator, "'hello world'", .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("hello world", result.fields[0]);
}

test "empty quoted word parts preserve fields" {
    var single = try expandWord(std.testing.allocator, "''", .{});
    defer single.deinit();
    try std.testing.expectEqual(@as(usize, 1), single.fields.len);
    try std.testing.expectEqualStrings("", single.fields[0]);

    var embedded = try expandWord(std.testing.allocator, "pre''post", .{});
    defer embedded.deinit();
    try std.testing.expectEqual(@as(usize, 1), embedded.fields.len);
    try std.testing.expectEqualStrings("prepost", embedded.fields[0]);

    var unquoted_empty = try expandWord(std.testing.allocator, "$EMPTY", .{ .env = test_env });
    defer unquoted_empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), unquoted_empty.fields.len);

    var quoted_generated_empty = try expandWord(std.testing.allocator, "''$EMPTY", .{ .env = test_env });
    defer quoted_generated_empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted_generated_empty.fields.len);
    try std.testing.expectEqualStrings("", quoted_generated_empty.fields[0]);
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

    const spaced_params = [_][]const u8{ "a b", "c d" };
    var empty_ifs_star = try expandWord(std.testing.allocator, "$*", .{ .positionals = &spaced_params, .env = test_empty_ifs_env });
    defer empty_ifs_star.deinit();
    try std.testing.expectEqual(@as(usize, 2), empty_ifs_star.fields.len);
    try std.testing.expectEqualStrings("a b", empty_ifs_star.fields[0]);
    try std.testing.expectEqualStrings("c d", empty_ifs_star.fields[1]);

    var empty_ifs_at = try expandWord(std.testing.allocator, "$@", .{ .positionals = &spaced_params, .env = test_empty_ifs_env });
    defer empty_ifs_at.deinit();
    try std.testing.expectEqual(@as(usize, 2), empty_ifs_at.fields.len);
    try std.testing.expectEqualStrings("a b", empty_ifs_at.fields[0]);
    try std.testing.expectEqualStrings("c d", empty_ifs_at.fields[1]);

    var embedded_empty_ifs_star = try expandWord(std.testing.allocator, "pre$*post", .{ .positionals = &spaced_params, .env = test_empty_ifs_env });
    defer embedded_empty_ifs_star.deinit();
    try std.testing.expectEqual(@as(usize, 2), embedded_empty_ifs_star.fields.len);
    try std.testing.expectEqualStrings("prea b", embedded_empty_ifs_star.fields[0]);
    try std.testing.expectEqualStrings("c dpost", embedded_empty_ifs_star.fields[1]);

    var embedded_empty_ifs_at = try expandWord(std.testing.allocator, "pre$@post", .{ .positionals = &spaced_params, .env = test_empty_ifs_env });
    defer embedded_empty_ifs_at.deinit();
    try std.testing.expectEqual(@as(usize, 2), embedded_empty_ifs_at.fields.len);
    try std.testing.expectEqualStrings("prea b", embedded_empty_ifs_at.fields[0]);
    try std.testing.expectEqualStrings("c dpost", embedded_empty_ifs_at.fields[1]);
}

test "braced multi-digit positional parameters use the full decimal index" {
    const params = [_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten words", "eleven" };

    const scalar = try expandWordScalar(std.testing.allocator, "${10}:${11}:${12}:${01}:$10", .{ .positionals = &params });
    defer std.testing.allocator.free(scalar);
    try std.testing.expectEqualStrings("ten words:eleven::one:one0", scalar);

    var unquoted = try expandWord(std.testing.allocator, "${10}", .{ .positionals = &params });
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 2), unquoted.fields.len);
    try std.testing.expectEqualStrings("ten", unquoted.fields[0]);
    try std.testing.expectEqualStrings("words", unquoted.fields[1]);
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

test "here-doc body keeps quotes and non-special backslashes literal" {
    const literal = try expandHereDocBody(std.testing.allocator, "\"q\" 'one' \\\"x\\\" a\\tb \\$lit \\\\ ${UNSET_NAME:-~}", .{ .env = test_env });
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings("\"q\" 'one' \\\"x\\\" a\\tb $lit \\ ~", literal);

    const expanded = try expandHereDocBody(std.testing.allocator, "$USER $((1 + 2)) line\\\njoined", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualStrings("rush-user 3 linejoined", expanded);
}

test "quoted parameter default word keeps tilde literal" {
    var quoted = try expandWord(std.testing.allocator, "\"${UNSET_NAME:-~}\"", .{ .env = test_env });
    defer quoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted.fields.len);
    try std.testing.expectEqualStrings("~", quoted.fields[0]);

    var unquoted = try expandWord(std.testing.allocator, "${UNSET_NAME:-~}", .{ .env = test_env });
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), unquoted.fields.len);
    try std.testing.expectEqualStrings("/home/rush", unquoted.fields[0]);
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

test "command substitution parses case pattern parens" {
    const echo_script: CommandSubstitution = .{ .runFn = testScriptEchoSubstitution };

    var rendered = try expandWord(std.testing.allocator, "\"$(case x in x) echo case-in-subst ;; esac)\"", .{ .command_substitution = echo_script });
    defer rendered.deinit();
    try std.testing.expectEqual(@as(usize, 1), rendered.fields.len);
    try std.testing.expectEqualStrings("case x in x) echo case-in-subst ;; esac", rendered.fields[0]);

    var optional = try expandWord(std.testing.allocator, "\"$(case x in (x) echo optional ;; esac)\"", .{ .command_substitution = echo_script });
    defer optional.deinit();
    try std.testing.expectEqual(@as(usize, 1), optional.fields.len);
    try std.testing.expectEqualStrings("case x in (x) echo optional ;; esac", optional.fields[0]);
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

test "backquote command substitution removes escaped newline from script" {
    var parts = try parseWordParts(std.testing.allocator, "`printf a\\\nb`");
    defer parts.deinit();
    try std.testing.expectEqual(@as(usize, 1), parts.parts.len);
    try std.testing.expectEqual(WordPartKind.command_substitution, parts.parts[0].kind);

    const script = try commandSubstitutionScript(std.testing.allocator, parts.raw, parts.parts[0], false);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("printf ab", script);
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
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("UNKNOWN + EMPTY", test_env, .{}));
    try std.testing.expectEqual(std.math.maxInt(i64), try evalArithmetic("9223372036854775807", .{}, .{}));
    try std.testing.expectEqual(std.math.minInt(i64), try evalArithmetic("-9223372036854775808", .{}, .{}));
    try std.testing.expectEqual(std.math.minInt(i64), try evalArithmetic("-9223372036854775807 - 1", .{}, .{}));
    try std.testing.expectEqual(std.math.maxInt(i64), try evalArithmetic("0x7fffffffffffffff", .{}, .{}));
    try std.testing.expectEqual(std.math.minInt(i64), try evalArithmetic("MIN_INT", test_env, .{}));
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("3 > 2", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("3 == 2", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("1 || 0", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("1 && 0", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 5), try evalArithmetic("(5 & 3) | 4", .{}, .{}));
    try std.testing.expectEqual(@as(i64, 16), try evalArithmetic("1 << 4", .{}, .{}));
    try std.testing.expectEqual(std.math.minInt(i64), try evalArithmetic("1 << 63", .{}, .{}));
    try std.testing.expectEqual(@as(i64, -1), try evalArithmetic("-1 >> 1", .{}, .{}));
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

test "arithmetic expansion trims shell blanks around variable integer values" {
    try std.testing.expectEqual(@as(i64, 42), try evalArithmetic("PADDED_NUM", test_env, .{}));
    try std.testing.expectEqual(@as(i64, 42), try evalArithmetic("TAB_PADDED_NUM", test_env, .{}));
    try std.testing.expectEqual(@as(i64, -5), try evalArithmetic("PADDED_NEGATIVE_NUM + 2", test_env, .{}));
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("PADDED_BLANK_NUM", test_env, .{}));
    try std.testing.expectEqual(@as(i64, 13), try evalArithmetic("WC_COUNT + 1", test_env, .{}));

    var unbraced = try expandWord(std.testing.allocator, "$(($PADDED_NUM))", .{ .env = test_env });
    defer unbraced.deinit();
    try std.testing.expectEqual(@as(usize, 1), unbraced.fields.len);
    try std.testing.expectEqualStrings("42", unbraced.fields[0]);
}

const ArithmeticSetRecorder = struct {
    count: usize = 0,
    last_name: [64]u8 = undefined,
    last_name_len: usize = 0,
    last_value: [64]u8 = undefined,
    last_value_len: usize = 0,

    fn envSet(self: *ArithmeticSetRecorder) EnvSet {
        return .{ .context = self, .setFn = arithmeticSetRecorderSet };
    }

    fn lastValue(self: *const ArithmeticSetRecorder) []const u8 {
        return self.last_value[0..self.last_value_len];
    }
};

fn arithmeticSetRecorderSet(context: ?*anyopaque, name: []const u8, value: []const u8) anyerror!void {
    const recorder: *ArithmeticSetRecorder = @ptrCast(@alignCast(context.?));
    try std.testing.expect(name.len <= recorder.last_name.len);
    try std.testing.expect(value.len <= recorder.last_value.len);
    @memcpy(recorder.last_name[0..name.len], name);
    @memcpy(recorder.last_value[0..value.len], value);
    recorder.last_name_len = name.len;
    recorder.last_value_len = value.len;
    recorder.count += 1;
}

test "arithmetic expansion evaluates shift and bitwise compound assignments" {
    var recorder: ArithmeticSetRecorder = .{};

    try std.testing.expectEqual(@as(i64, 6), try evalArithmetic("USER_NUM<<=1", test_env, recorder.envSet()));
    try std.testing.expectEqualStrings("6", recorder.lastValue());
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("USER_NUM>>=1", test_env, recorder.envSet()));
    try std.testing.expectEqualStrings("1", recorder.lastValue());
    try std.testing.expectEqual(@as(i64, 3), try evalArithmetic("USER_NUM&=3", test_env, recorder.envSet()));
    try std.testing.expectEqualStrings("3", recorder.lastValue());
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("USER_NUM|=4", test_env, recorder.envSet()));
    try std.testing.expectEqualStrings("7", recorder.lastValue());
    try std.testing.expectEqual(@as(i64, 2), try evalArithmetic("USER_NUM^=1", test_env, recorder.envSet()));
    try std.testing.expectEqualStrings("2", recorder.lastValue());
}

test "arithmetic expansion short-circuits logical operands" {
    var recorder: ArithmeticSetRecorder = .{};

    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("0 && (x = 2)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(usize, 0), recorder.count);
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("1 || (x = 2)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(usize, 0), recorder.count);

    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("0 && (1 / 0)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("1 || (1 / 0)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(i64, 0), try evalArithmetic("0 && (9223372036854775807 + 1)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("1 || (9223372036854775807 + 1)", .{}, recorder.envSet()));

    try std.testing.expectError(error.DivisionByZero, evalArithmetic("1 && (1 / 0)", .{}, recorder.envSet()));
    try std.testing.expectError(error.DivisionByZero, evalArithmetic("0 || (1 / 0)", .{}, recorder.envSet()));

    try std.testing.expectEqual(@as(i64, 1), try evalArithmetic("1 && (x = 3)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualStrings("3", recorder.lastValue());
}

test "arithmetic expansion evaluates only the selected conditional operand" {
    var recorder: ArithmeticSetRecorder = .{};

    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("1 ? 7 : (x = 2)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(usize, 0), recorder.count);
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("0 ? (x = 2) : 7", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(usize, 0), recorder.count);

    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("1 ? 7 : (1 / 0)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("0 ? (1 / 0) : 7", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("1 ? 7 : (9223372036854775807 + 1)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(i64, 7), try evalArithmetic("0 ? (9223372036854775807 + 1) : 7", .{}, recorder.envSet()));

    try std.testing.expectError(error.DivisionByZero, evalArithmetic("0 ? 7 : (1 / 0)", .{}, recorder.envSet()));
    try std.testing.expectError(error.DivisionByZero, evalArithmetic("1 ? (1 / 0) : 7", .{}, recorder.envSet()));

    try std.testing.expectEqual(@as(i64, 4), try evalArithmetic("0 ? 7 : (x = 4)", .{}, recorder.envSet()));
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualStrings("4", recorder.lastValue());
}

test "arithmetic expansion rejects invalid variable values" {
    try std.testing.expectError(error.InvalidArithmetic, evalArithmetic("USER", test_env, .{}));
    try std.testing.expectError(error.InvalidArithmetic, evalArithmetic("EXPRESSION_VALUE", test_env, .{}));
    try std.testing.expectError(error.InvalidArithmetic, evalArithmetic("PADDED_JUNK_VALUE", test_env, .{}));
    try std.testing.expectError(error.InvalidArithmetic, evalArithmetic("NESTED_PARAMETER_TEXT", test_env, .{}));
    try std.testing.expectError(error.InvalidArithmetic, evalArithmetic("USER += 1", test_env, .{}));

    var arithmetic_error: ArithmeticError = .{};
    defer arithmetic_error.clear(std.testing.allocator);

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "$((EXPRESSION_VALUE))", .{ .env = test_env, .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("$((EXPRESSION_VALUE))", arithmetic_error.expression);
    try std.testing.expectEqualStrings("invalid arithmetic expression", arithmetic_error.message);
}

test "arithmetic expansion preprocesses nested expansion tokens" {
    var braced = try expandWord(std.testing.allocator, "$((1 + ${MISSING:-2}))", .{});
    defer braced.deinit();
    try std.testing.expectEqual(@as(usize, 1), braced.fields.len);
    try std.testing.expectEqualStrings("3", braced.fields[0]);

    var unbraced = try expandWord(std.testing.allocator, "$(($USER_NUM + 4))", .{ .env = test_env });
    defer unbraced.deinit();
    try std.testing.expectEqual(@as(usize, 1), unbraced.fields.len);
    try std.testing.expectEqualStrings("7", unbraced.fields[0]);

    var command = try expandWord(std.testing.allocator, "$((1 + $(printf 2)))", .{ .command_substitution = test_command_substitution });
    defer command.deinit();
    try std.testing.expectEqual(@as(usize, 1), command.fields.len);
    try std.testing.expectEqualStrings("3", command.fields[0]);

    var nested = try expandWord(std.testing.allocator, "$((1 + $((2))))", .{});
    defer nested.deinit();
    try std.testing.expectEqual(@as(usize, 1), nested.fields.len);
    try std.testing.expectEqualStrings("3", nested.fields[0]);
}

test "arithmetic expansion applies POSIX quote and backslash preprocessing" {
    var continuation = try expandWord(std.testing.allocator, "$((1 + \\\n2))", .{});
    defer continuation.deinit();
    try std.testing.expectEqual(@as(usize, 1), continuation.fields.len);
    try std.testing.expectEqualStrings("3", continuation.fields[0]);

    var backquote = try expandWord(std.testing.allocator, "$((1 + `printf 2`))", .{ .command_substitution = test_command_substitution });
    defer backquote.deinit();
    try std.testing.expectEqual(@as(usize, 1), backquote.fields.len);
    try std.testing.expectEqualStrings("3", backquote.fields[0]);

    var arithmetic_error: ArithmeticError = .{};
    defer arithmetic_error.clear(std.testing.allocator);

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "$((1 + \\${MISSING:-2))", .{ .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("$((1 + \\${MISSING:-2))", arithmetic_error.expression);
    try std.testing.expectEqualStrings("invalid arithmetic expression", arithmetic_error.message);

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "$((\"1\" + 2))", .{ .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("$((\"1\" + 2))", arithmetic_error.expression);
    try std.testing.expectEqualStrings("invalid arithmetic expression", arithmetic_error.message);
}

test "arithmetic expansion records diagnostics instead of leaking parser errors" {
    var arithmetic_error: ArithmeticError = .{};
    defer arithmetic_error.clear(std.testing.allocator);

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "$((2 ** 3))", .{ .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("$((2 ** 3))", arithmetic_error.expression);
    try std.testing.expectEqualStrings("invalid arithmetic expression", arithmetic_error.message);

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "$((1 / 0))", .{ .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("$((1 / 0))", arithmetic_error.expression);
    try std.testing.expectEqualStrings("division by zero", arithmetic_error.message);

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "$((1 % 0))", .{ .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("$((1 % 0))", arithmetic_error.expression);
    try std.testing.expectEqualStrings("division by zero", arithmetic_error.message);

    try std.testing.expectError(error.Overflow, evalArithmetic("9223372036854775807 + 1", .{}, .{}));
    try std.testing.expectError(error.Overflow, evalArithmetic("-9223372036854775808 - 1", .{}, .{}));
    try std.testing.expectError(error.Overflow, evalArithmetic("3037000500 * 3037000500", .{}, .{}));
    try std.testing.expectError(error.Overflow, evalArithmetic("-(-9223372036854775808)", .{}, .{}));
    try std.testing.expectError(error.Overflow, evalArithmetic("(-9223372036854775808) / -1", .{}, .{}));
    try std.testing.expectError(error.Overflow, evalArithmetic("0x8000000000000000", .{}, .{}));

    try std.testing.expectError(error.ArithmeticExpansionFailed, expandWordScalar(std.testing.allocator, "$((9223372036854775807 + 1))", .{ .arithmetic_error = &arithmetic_error }));
    try std.testing.expectEqualStrings("$((9223372036854775807 + 1))", arithmetic_error.expression);
    try std.testing.expectEqualStrings("arithmetic overflow", arithmetic_error.message);
}

test "word part parser records arithmetic expansion regions" {
    var parts = try parseWordParts(std.testing.allocator, "a$((1 + 2))b");
    defer parts.deinit();

    try std.testing.expectEqual(@as(usize, 3), parts.parts.len);
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[0].kind);
    try std.testing.expectEqual(WordPartKind.arithmetic, parts.parts[1].kind);
    try std.testing.expectEqualStrings("1 + 2", parts.parts[1].value(parts.raw));
    try std.testing.expectEqual(WordPartKind.unquoted, parts.parts[2].kind);

    var nested = try parseWordParts(std.testing.allocator, "$((1 + $(printf 2)))");
    defer nested.deinit();
    try std.testing.expectEqual(@as(usize, 1), nested.parts.len);
    try std.testing.expectEqual(WordPartKind.arithmetic, nested.parts[0].kind);
    try std.testing.expectEqualStrings("1 + $(printf 2)", nested.parts[0].value(nested.raw));
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

test "pathname expansion honors nullglob and dotglob options" {
    const dir = "rush-glob-shopt-dir";
    const visible = "rush-glob-shopt-dir/visible.tmp";
    const hidden = "rush-glob-shopt-dir/.hidden.tmp";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = visible, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hidden, .data = "" });

    var default_glob = try expandWord(std.testing.allocator, "rush-glob-shopt-dir/*.tmp", .{ .io = std.testing.io });
    defer default_glob.deinit();
    try std.testing.expectEqual(@as(usize, 1), default_glob.fields.len);
    try std.testing.expectEqualStrings(visible, default_glob.fields[0]);

    var dotglob = try expandWord(std.testing.allocator, "rush-glob-shopt-dir/*.tmp", .{ .io = std.testing.io, .pathname_dotglob = true });
    defer dotglob.deinit();
    try std.testing.expectEqual(@as(usize, 2), dotglob.fields.len);
    try std.testing.expectEqualStrings(hidden, dotglob.fields[0]);
    try std.testing.expectEqualStrings(visible, dotglob.fields[1]);

    var unmatched = try expandWord(std.testing.allocator, "rush-glob-shopt-dir/*.missing", .{ .io = std.testing.io, .pathname_nullglob = true });
    defer unmatched.deinit();
    try std.testing.expectEqual(@as(usize, 0), unmatched.fields.len);
}

test "pathname expansion honors extglob option" {
    const a = "rush-extglob-a.tmp";
    const b = "rush-extglob-b.tmp";
    const c = "rush-extglob-c.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = c, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, b) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c) catch {};

    var disabled = try expandWord(std.testing.allocator, "rush-extglob-@(a|b).tmp", .{ .io = std.testing.io });
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 1), disabled.fields.len);
    try std.testing.expectEqualStrings("rush-extglob-@(a|b).tmp", disabled.fields[0]);

    var enabled = try expandWord(std.testing.allocator, "rush-extglob-@(a|b).tmp", .{ .io = std.testing.io, .extglob = true });
    defer enabled.deinit();
    try std.testing.expectEqual(@as(usize, 2), enabled.fields.len);
    try std.testing.expectEqualStrings(a, enabled.fields[0]);
    try std.testing.expectEqualStrings(b, enabled.fields[1]);
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

test "pathname expansion treats incomplete bracket expressions as literals" {
    var command_word = try expandWord(std.testing.allocator, "[", .{ .io = std.testing.io, .pathname_nullglob = true });
    defer command_word.deinit();
    try std.testing.expectEqual(@as(usize, 1), command_word.fields.len);
    try std.testing.expectEqualStrings("[", command_word.fields[0]);

    var argument_word = try expandWord(std.testing.allocator, "]", .{ .io = std.testing.io, .pathname_nullglob = true });
    defer argument_word.deinit();
    try std.testing.expectEqual(@as(usize, 1), argument_word.fields.len);
    try std.testing.expectEqualStrings("]", argument_word.fields[0]);

    var embedded = try expandWord(std.testing.allocator, "rush-unclosed-[.tmp", .{ .io = std.testing.io, .pathname_nullglob = true });
    defer embedded.deinit();
    try std.testing.expectEqual(@as(usize, 1), embedded.fields.len);
    try std.testing.expectEqualStrings("rush-unclosed-[.tmp", embedded.fields[0]);
}

test "pathname expansion bracket expressions support POSIX character classes" {
    const upper = "rush-class-A.tmp";
    const digit = "rush-class-7.tmp";
    const lower = "rush-class-x.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = upper, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = digit, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = lower, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, upper) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, digit) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lower) catch {};

    var upper_result = try expandWord(std.testing.allocator, "rush-class-[[:upper:]].tmp", .{ .io = std.testing.io });
    defer upper_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), upper_result.fields.len);
    try std.testing.expectEqualStrings(upper, upper_result.fields[0]);

    var negated_result = try expandWord(std.testing.allocator, "rush-class-[![:digit:]].tmp", .{ .io = std.testing.io });
    defer negated_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), negated_result.fields.len);
    try std.testing.expectEqualStrings(upper, negated_result.fields[0]);
    try std.testing.expectEqualStrings(lower, negated_result.fields[1]);
}

test "quoted parameter expansion is not subject to pathname expansion" {
    const a = "rush-quoted-glob-a.tmp";
    const b = "rush-quoted-glob-b.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, b) catch {};

    var quoted = try expandWord(std.testing.allocator, "\"$GLOBBY\"", .{ .env = test_env, .io = std.testing.io });
    defer quoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), quoted.fields.len);
    try std.testing.expectEqualStrings("rush-quoted-glob-?.tmp", quoted.fields[0]);

    var unquoted = try expandWord(std.testing.allocator, "$GLOBBY", .{ .env = test_env, .io = std.testing.io });
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 2), unquoted.fields.len);
    try std.testing.expectEqualStrings(a, unquoted.fields[0]);
    try std.testing.expectEqualStrings(b, unquoted.fields[1]);
}

test "pathname expansion preserves unmatched patterns" {
    var result = try expandWord(std.testing.allocator, "rush-no-match-*.tmp", .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("rush-no-match-*.tmp", result.fields[0]);
}
