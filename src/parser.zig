//! Parser surface, lexer, and test harness.
//!
//! The real parser will grow from POSIX shell syntax toward Bash-compatible
//! extensions. This file starts by defining the test-facing shape we want to
//! preserve: source spans, tokens, concrete syntax nodes, diagnostics, and an
//! incomplete-input flag for interactive parsing.

const std = @import("std");
const compat = @import("compat.zig");

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn init(start: usize, end: usize) Span {
        std.debug.assert(end >= start);
        return .{ .start = start, .end = end };
    }

    pub fn empty(offset: usize) Span {
        return .{ .start = offset, .end = offset };
    }

    pub fn len(self: Span) usize {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }

    pub fn isEmpty(self: Span) bool {
        return self.len() == 0;
    }

    pub fn contains(self: Span, offset: usize) bool {
        return offset >= self.start and offset < self.end;
    }

    pub fn touches(self: Span, offset: usize) bool {
        return offset >= self.start and offset <= self.end;
    }

    pub fn slice(self: Span, source: []const u8) []const u8 {
        std.debug.assert(self.end <= source.len);
        return source[self.start..self.end];
    }
};

pub const TokenKind = enum {
    invalid,
    eof,

    whitespace,
    newline,
    comment,
    word,

    pipe,
    and_if,
    or_if,
    semicolon,
    dsemicolon,
    ampersand,
    left_paren,
    right_paren,

    less,
    greater,
    dless,
    dless_dash,
    dgreat,
    less_and,
    greater_and,
    less_great,
    clobber,

    pub fn isTrivia(self: TokenKind) bool {
        return switch (self) {
            .whitespace, .newline, .comment => true,
            else => false,
        };
    }

    pub fn isOperator(self: TokenKind) bool {
        return switch (self) {
            .pipe,
            .and_if,
            .or_if,
            .semicolon,
            .dsemicolon,
            .ampersand,
            .left_paren,
            .right_paren,
            .less,
            .greater,
            .dless,
            .dless_dash,
            .dgreat,
            .less_and,
            .greater_and,
            .less_great,
            .clobber,
            => true,
            else => false,
        };
    }

    pub fn isRedirectOperator(self: TokenKind) bool {
        return switch (self) {
            .less,
            .greater,
            .dless,
            .dless_dash,
            .dgreat,
            .less_and,
            .greater_and,
            .less_great,
            .clobber,
            => true,
            else => false,
        };
    }
};

pub const Token = struct {
    kind: TokenKind,
    span: Span,

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return self.span.slice(source);
    }
};

pub const NodeId = struct {
    raw: u32,

    pub fn init(raw_index: usize) NodeId {
        std.debug.assert(raw_index < std.math.maxInt(u32));
        return .{ .raw = @intCast(raw_index) };
    }

    pub fn index(self: NodeId) usize {
        return self.raw;
    }
};

pub const TokenId = struct {
    raw: u32,

    pub fn init(raw_index: usize) TokenId {
        std.debug.assert(raw_index < std.math.maxInt(u32));
        return .{ .raw = @intCast(raw_index) };
    }

    pub fn index(self: TokenId) usize {
        return self.raw;
    }
};

pub const NodeKind = enum {
    root,
    list,
    pipeline,
    simple_command,
    redirection,
    io_number,
    assignment_word,
    command_word,
    word,
    command_substitution,
    here_doc_body,
    if_command,
    loop_command,
    for_command,
    bash_test_command,
    case_command,
    case_item,
    function_definition,
    brace_group,
    subshell,
    parse_error,
};

pub const SyntaxChild = union(enum) {
    node: NodeId,
    token: TokenId,
};

pub const Node = struct {
    kind: NodeKind,
    span: Span,
    token_start: usize,
    token_end: usize,
    child_start: usize,
    child_end: usize,
};

pub const DiagnosticKind = enum {
    lex_error,
    parse_error,
    incomplete_input,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    span: Span,
    message: []const u8,
};

pub const LexResult = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    diagnostics: []Diagnostic,
    incomplete: bool,

    pub fn deinit(self: *LexResult) void {
        self.allocator.free(self.tokens);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub fn lex(allocator: std.mem.Allocator, source: []const u8) !LexResult {
    var lexer: Lexer = .{
        .allocator = allocator,
        .source = source,
    };
    return lexer.run();
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,
    tokens: std.ArrayList(Token) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    incomplete: bool = false,

    fn run(self: *Lexer) !LexResult {
        errdefer self.tokens.deinit(self.allocator);
        errdefer self.diagnostics.deinit(self.allocator);

        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => try self.scanWhitespace(),
                '\n' => try self.addAndAdvance(.newline, 1),
                '#' => try self.scanComment(),
                '|', '&', ';', '(', ')', '<', '>' => try self.scanOperator(),
                else => try self.scanWord(),
            }
        }

        try self.add(.eof, Span.empty(self.source.len));

        const owned_tokens = try self.tokens.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_tokens);
        const owned_diagnostics = try self.diagnostics.toOwnedSlice(self.allocator);

        return .{
            .allocator = self.allocator,
            .tokens = owned_tokens,
            .diagnostics = owned_diagnostics,
            .incomplete = self.incomplete,
        };
    }

    fn scanWhitespace(self: *Lexer) !void {
        const start = self.index;
        while (!self.isAtEnd() and isBlank(self.peek())) {
            self.index += 1;
        }
        try self.add(.whitespace, .init(start, self.index));
    }

    fn scanComment(self: *Lexer) !void {
        const start = self.index;
        while (!self.isAtEnd() and self.peek() != '\n') {
            self.index += 1;
        }
        try self.add(.comment, .init(start, self.index));
    }

    fn scanOperator(self: *Lexer) !void {
        const start = self.index;
        const kind: TokenKind = switch (self.peek()) {
            '|' => if (self.matchNext('|')) .or_if else .pipe,
            '&' => if (self.matchNext('&')) .and_if else .ampersand,
            ';' => if (self.matchNext(';')) .dsemicolon else .semicolon,
            '(' => .left_paren,
            ')' => .right_paren,
            '<' => if (self.matchNext('<')) blk: {
                if (self.matchNext('-')) break :blk .dless_dash;
                break :blk .dless;
            } else if (self.matchNext('&')) .less_and else if (self.matchNext('>')) .less_great else .less,
            '>' => if (self.matchNext('>')) .dgreat else if (self.matchNext('&')) .greater_and else if (self.matchNext('|')) .clobber else .greater,
            else => unreachable,
        };

        try self.add(kind, .init(start, self.index + 1));
        self.index += 1;
    }

    fn scanWord(self: *Lexer) !void {
        const start = self.index;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isWordBoundary(c)) break;

            switch (c) {
                '\\' => self.consumeBackslash(),
                '\'' => try self.consumeQuoted('\'', "unterminated single quote"),
                '"' => try self.consumeDoubleQuoted(),
                '`' => try self.consumeBackquoted(),
                '$' => try self.consumeDollarExpansion(),
                else => self.index += 1,
            }
        }
        try self.add(.word, .init(start, self.index));
    }

    fn consumeBackslash(self: *Lexer) void {
        self.index += 1;
        if (!self.isAtEnd()) self.index += 1;
    }

    fn consumeBackquoted(self: *Lexer) !void {
        const start = self.index;
        self.index += 1;
        while (!self.isAtEnd()) {
            switch (self.peek()) {
                '\\' => self.consumeBackslash(),
                '`' => {
                    self.index += 1;
                    return;
                },
                else => self.index += 1,
            }
        }
        try self.addIncomplete(.init(start, self.source.len), "unterminated backquote command substitution");
    }

    fn consumeDollarExpansion(self: *Lexer) !void {
        if (self.index + 1 >= self.source.len) {
            self.index += 1;
            return;
        }

        if (self.source[self.index + 1] == '{') {
            try self.consumeParameterExpansion();
        } else if (self.source[self.index + 1] == '(' and self.index + 2 < self.source.len and self.source[self.index + 2] == '(') {
            try self.consumeArithmeticExpansion();
        } else if (self.source[self.index + 1] == '(') {
            try self.consumeCommandSubstitution();
        } else {
            self.index += 1;
        }
    }

    fn consumeParameterExpansion(self: *Lexer) !void {
        const start = self.index;
        if (try parameterExpansionEnd(self.allocator, self.source, self.source.len, start)) |end| {
            self.index = end;
            return;
        }

        self.index = self.source.len;
        try self.addIncomplete(.init(start, self.source.len), "unterminated parameter expansion");
    }

    fn consumeArithmeticExpansion(self: *Lexer) !void {
        const start = self.index;
        switch (try arithmeticExpansionScan(self.allocator, self.source, self.source.len, start)) {
            .complete => |end| {
                self.index = end;
                return;
            },
            .incomplete_backquote => |backquote_start| {
                self.index = self.source.len;
                try self.addIncomplete(.init(backquote_start, self.source.len), "unterminated backquote command substitution");
                return;
            },
            .incomplete_arithmetic => {},
        }

        self.index = self.source.len;
        try self.addIncomplete(.init(start, self.source.len), "unterminated arithmetic expansion");
    }

    fn consumeCommandSubstitution(self: *Lexer) !void {
        const start = self.index;
        if (try commandSubstitutionEnd(self.allocator, self.source, self.source.len, start)) |end| {
            self.index = end;
            return;
        }

        self.index = self.source.len;
        try self.addIncomplete(.init(start, self.source.len), "unterminated command substitution");
    }

    fn consumeQuoted(self: *Lexer, quote: u8, message: []const u8) !void {
        const start = self.index;
        self.index += 1;
        while (!self.isAtEnd() and self.peek() != quote) {
            self.index += 1;
        }
        if (self.isAtEnd()) {
            try self.addIncomplete(.init(start, self.source.len), message);
            return;
        }
        self.index += 1;
    }

    // The explicit error set breaks the inferred-error-set cycle through
    // consumeDollarExpansion; only allocation can fail in the lexer.
    fn consumeDoubleQuoted(self: *Lexer) std.mem.Allocator.Error!void {
        const start = self.index;
        self.index += 1;
        while (!self.isAtEnd() and self.peek() != '"') {
            switch (self.peek()) {
                '\\' => self.consumeBackslash(),
                // $ and ` keep their special meaning inside double quotes
                // (POSIX XCU 2.2.3); quotes inside the embedded expansion do
                // not close the surrounding double-quoted string.
                '$' => try self.consumeDollarExpansion(),
                '`' => try self.consumeBackquoted(),
                else => self.index += 1,
            }
        }
        if (self.isAtEnd()) {
            try self.addIncomplete(.init(start, self.source.len), "unterminated double quote");
            return;
        }
        self.index += 1;
    }

    fn addAndAdvance(self: *Lexer, kind: TokenKind, len: usize) !void {
        const start = self.index;
        self.index += len;
        try self.add(kind, .init(start, self.index));
    }

    fn addIncomplete(self: *Lexer, span: Span, message: []const u8) !void {
        self.incomplete = true;
        try self.diagnostics.append(self.allocator, .{
            .kind = .incomplete_input,
            .span = span,
            .message = message,
        });
    }

    fn add(self: *Lexer, kind: TokenKind, span: Span) !void {
        try self.tokens.append(self.allocator, .{ .kind = kind, .span = span });
    }

    fn matchNext(self: *Lexer, c: u8) bool {
        if (self.index + 1 >= self.source.len or self.source[self.index + 1] != c) return false;
        self.index += 1;
        return true;
    }

    fn isAtEnd(self: Lexer) bool {
        return self.index >= self.source.len;
    }

    fn peek(self: Lexer) u8 {
        std.debug.assert(!self.isAtEnd());
        return self.source[self.index];
    }
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

fn isWordBoundary(c: u8) bool {
    return isBlank(c) or c == '\n' or switch (c) {
        '|', '&', ';', '(', ')', '<', '>' => true,
        else => false,
    };
}

pub const ParseMode = enum {
    complete,
    interactive,
};

pub const ParseOptions = struct {
    mode: ParseMode = .complete,
    cursor: ?usize = null,
    features: compat.Features = .{},
};

pub const HighlightKind = enum {
    invalid,
    eof,
    whitespace,
    newline,
    comment,
    command,
    argument,
    assignment,
    io_number,
    operator,
    redirect,
    diagnostic_error,
};

pub const Highlight = struct {
    kind: HighlightKind,
    span: Span,
};

pub const CompletionKind = enum {
    command,
    argument,
    parameter,
    redirect_target,
    assignment_name,
    assignment_value,
    separator,
    quoted_string,
};

pub const CompletionContext = struct {
    kind: CompletionKind,
    cursor: usize,
    token_index: ?usize = null,
    span: Span,
};

pub const ParseResult = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []Token,
    nodes: []Node,
    children: []SyntaxChild,
    diagnostics: []Diagnostic,
    incomplete: bool,

    pub fn root(self: ParseResult) Node {
        std.debug.assert(self.nodes.len > 0);
        return self.nodes[0];
    }

    pub fn nodeTokens(self: ParseResult, node: Node) []const Token {
        std.debug.assert(node.token_start <= node.token_end);
        std.debug.assert(node.token_end <= self.tokens.len);
        return self.tokens[node.token_start..node.token_end];
    }

    pub fn nodeChildren(self: ParseResult, node: Node) []const SyntaxChild {
        std.debug.assert(node.child_start <= node.child_end);
        std.debug.assert(node.child_end <= self.children.len);
        return self.children[node.child_start..node.child_end];
    }

    pub fn deinit(self: *ParseResult) void {
        self.allocator.free(self.tokens);
        self.allocator.free(self.nodes);
        self.allocator.free(self.children);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub fn syntaxHighlights(allocator: std.mem.Allocator, result: ParseResult) ![]Highlight {
    var highlights: std.ArrayList(Highlight) = .empty;
    errdefer highlights.deinit(allocator);

    for (result.tokens) |token| {
        try highlights.append(allocator, .{
            .kind = defaultHighlightKind(token.kind),
            .span = token.span,
        });
    }

    for (result.nodes) |node| {
        const kind: ?HighlightKind = switch (node.kind) {
            .command_word => .command,
            .word => .argument,
            .assignment_word => .assignment,
            .io_number => .io_number,
            .command_substitution => .operator,
            else => null,
        };
        if (kind) |highlight_kind| {
            for (node.token_start..node.token_end) |token_index| {
                highlights.items[token_index].kind = highlight_kind;
            }
        }
    }

    for (result.diagnostics) |diagnostic| {
        try highlights.append(allocator, .{ .kind = .diagnostic_error, .span = diagnostic.span });
    }

    return highlights.toOwnedSlice(allocator);
}

pub fn completionContext(result: ParseResult, cursor: usize) CompletionContext {
    const clamped_cursor = @min(cursor, result.source.len);

    if (parameterCompletionContext(result.source, clamped_cursor)) |context| return context;

    for (result.diagnostics) |diagnostic| {
        if (diagnostic.kind == .incomplete_input and diagnostic.span.touches(clamped_cursor) and diagnosticBlocksTokenCompletion(diagnostic)) {
            return .{
                .kind = .quoted_string,
                .cursor = clamped_cursor,
                .span = diagnostic.span,
            };
        }
    }

    if (tokenAtCursor(result.tokens, clamped_cursor)) |token_index| {
        const token = result.tokens[token_index];
        if (token.kind == .word) {
            if (nodeKindForToken(result, token_index)) |node_kind| {
                if (node_kind == .assignment_word) {
                    return assignmentCompletionContext(result, token_index, clamped_cursor);
                }
                if (node_kind == .command_word) {
                    return .{ .kind = .command, .cursor = clamped_cursor, .token_index = token_index, .span = token.span };
                }
            }
        }
    }

    const previous = previousSignificantToken(result.tokens, clamped_cursor) orelse return .{
        .kind = .command,
        .cursor = clamped_cursor,
        .span = .empty(clamped_cursor),
    };
    const previous_token = result.tokens[previous];

    if (previous_token.kind == .word) {
        if (nodeKindForToken(result, previous)) |node_kind| {
            if (previous_token.span.end < clamped_cursor) {
                if (node_kind == .command_word or node_kind == .word or node_kind == .assignment_word) {
                    return .{ .kind = .argument, .cursor = clamped_cursor, .token_index = previous, .span = .empty(clamped_cursor) };
                }
            }
            if (node_kind == .command_word) {
                return .{ .kind = .command, .cursor = clamped_cursor, .token_index = previous, .span = previous_token.span };
            }
            if (node_kind == .word or node_kind == .assignment_word) {
                return .{ .kind = .argument, .cursor = clamped_cursor, .token_index = previous, .span = previous_token.span };
            }
        }
    }

    if (previous_token.kind.isRedirectOperator()) {
        return .{ .kind = .redirect_target, .cursor = clamped_cursor, .token_index = previous, .span = .empty(clamped_cursor) };
    }

    if (previous_token.kind == .pipe or isListSeparator(previous_token.kind)) {
        return .{ .kind = .command, .cursor = clamped_cursor, .token_index = previous, .span = .empty(clamped_cursor) };
    }

    if (previous_token.kind.isOperator()) {
        return .{ .kind = .separator, .cursor = clamped_cursor, .token_index = previous, .span = .empty(clamped_cursor) };
    }

    return .{ .kind = .argument, .cursor = clamped_cursor, .token_index = previous, .span = .empty(clamped_cursor) };
}

fn parameterCompletionContext(source: []const u8, cursor: usize) ?CompletionContext {
    var start = cursor;
    while (start > 0 and isParameterNameContinue(source[start - 1])) start -= 1;
    if (start == 0) return null;
    const dollar = start - 1;
    if (source[dollar] != '$') return null;
    if (isEscaped(source, dollar) or isInsideSingleQuotes(source, dollar)) return null;
    if (start < cursor and !isParameterNameStart(source[start])) return null;
    return .{
        .kind = .parameter,
        .cursor = cursor,
        .span = .init(start, cursor),
    };
}

fn isParameterNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isParameterNameContinue(byte: u8) bool {
    return isParameterNameStart(byte) or std.ascii.isDigit(byte);
}

fn isEscaped(source: []const u8, index: usize) bool {
    var count: usize = 0;
    var cursor = index;
    while (cursor > 0 and source[cursor - 1] == '\\') {
        count += 1;
        cursor -= 1;
    }
    return count % 2 == 1;
}

fn isInsideSingleQuotes(source: []const u8, index: usize) bool {
    var single = false;
    var double = false;
    var cursor: usize = 0;
    while (cursor < index) : (cursor += 1) {
        const byte = source[cursor];
        if (byte == '\\' and !single) {
            if (cursor + 1 < index) cursor += 1;
            continue;
        }
        if (byte == '\'' and !double) single = !single;
        if (byte == '"' and !single) double = !double;
    }
    return single;
}

fn diagnosticBlocksTokenCompletion(diagnostic: Diagnostic) bool {
    return std.mem.startsWith(u8, diagnostic.message, "unterminated");
}

fn assignmentCompletionContext(result: ParseResult, token_index: usize, cursor: usize) CompletionContext {
    const token = result.tokens[token_index];
    const lexeme = token.lexeme(result.source);
    const equals = std.mem.indexOfScalar(u8, lexeme, '=') orelse return .{
        .kind = .assignment_name,
        .cursor = cursor,
        .token_index = token_index,
        .span = token.span,
    };
    const equals_offset = token.span.start + equals;
    return .{
        .kind = if (cursor <= equals_offset) .assignment_name else .assignment_value,
        .cursor = cursor,
        .token_index = token_index,
        .span = token.span,
    };
}

fn tokenAtCursor(tokens: []const Token, cursor: usize) ?usize {
    for (tokens, 0..) |token, index| {
        if (token.kind == .eof) continue;
        if (token.span.contains(cursor)) return index;
    }
    return null;
}

fn previousSignificantToken(tokens: []const Token, cursor: usize) ?usize {
    var result: ?usize = null;
    for (tokens, 0..) |token, index| {
        if (token.kind == .eof or token.span.end > cursor) break;
        if (!token.kind.isTrivia()) result = index;
    }
    return result;
}

pub fn nodeKindForToken(result: ParseResult, token_index: usize) ?NodeKind {
    for (result.nodes) |node| {
        if (token_index >= node.token_start and token_index < node.token_end) {
            switch (node.kind) {
                .assignment_word, .command_word, .word, .io_number => return node.kind,
                else => {},
            }
        }
    }
    return null;
}

fn commandSubstitutionSpans(allocator: std.mem.Allocator, source: []const u8, span: Span) !std.ArrayList(Span) {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    var index = span.start;
    while (index < span.end) {
        switch (source[index]) {
            '\'' => skipQuoted(source, span.end, &index, '\''),
            '$' => {
                if (index + 1 < span.end and source[index + 1] == '(' and !(index + 2 < span.end and source[index + 2] == '(')) {
                    if (try commandSubstitutionEnd(allocator, source, span.end, index)) |end| {
                        try spans.append(allocator, .init(index, end));
                        index = end;
                    } else {
                        index += 1;
                    }
                } else {
                    index += 1;
                }
            },
            else => index += 1,
        }
    }

    return spans;
}

pub fn commandSubstitutionEnd(allocator: std.mem.Allocator, source: []const u8, limit: usize, start: usize) std.mem.Allocator.Error!?usize {
    std.debug.assert(start + 1 < limit);
    std.debug.assert(source[start] == '$');
    std.debug.assert(source[start + 1] == '(');

    var scanner: CommandSubstitutionScanner = .{
        .allocator = allocator,
        .source = source,
        .limit = limit,
        .index = start + 2,
    };
    defer scanner.deinit();
    return scanner.scan();
}

pub const ShellSubstitutionKind = enum {
    parameter,
    arithmetic,
    command_substitution,
};

pub const ShellSubstitution = struct {
    kind: ShellSubstitutionKind,
    span: Span,
    value_span: Span,
};

pub const ShellSubstitutionScanResult = union(enum) {
    none,
    complete: ShellSubstitution,
    incomplete: ShellSubstitutionKind,
};

pub fn shellSubstitutionAt(allocator: std.mem.Allocator, source: []const u8, limit: usize, start: usize) std.mem.Allocator.Error!ShellSubstitutionScanResult {
    std.debug.assert(limit <= source.len);
    if (start >= limit) return .none;

    if (source[start] == '`') {
        const end = backquoteCommandSubstitutionEnd(source, limit, start) orelse return .{ .incomplete = .command_substitution };
        return .{ .complete = .{
            .kind = .command_substitution,
            .span = .init(start, end),
            .value_span = .init(start + 1, end - 1),
        } };
    }

    if (source[start] != '$' or start + 1 >= limit) return .none;
    const next = start + 1;
    switch (source[next]) {
        '{' => {
            const end = (try parameterExpansionEnd(allocator, source, limit, start)) orelse return .{ .incomplete = .parameter };
            return .{ .complete = .{
                .kind = .parameter,
                .span = .init(start, end),
                .value_span = .init(start + 2, end - 1),
            } };
        },
        '(' => {
            if (next + 1 < limit and source[next + 1] == '(') {
                const end = (try arithmeticExpansionEnd(allocator, source, limit, start)) orelse return .{ .incomplete = .arithmetic };
                return .{ .complete = .{
                    .kind = .arithmetic,
                    .span = .init(start, end),
                    .value_span = .init(start + 3, end - 2),
                } };
            }
            const end = (try commandSubstitutionEnd(allocator, source, limit, start)) orelse return .{ .incomplete = .command_substitution };
            return .{ .complete = .{
                .kind = .command_substitution,
                .span = .init(start, end),
                .value_span = .init(start + 2, end - 1),
            } };
        },
        else => {
            if (isSpecialParameterChar(source[next])) {
                return .{ .complete = .{
                    .kind = .parameter,
                    .span = .init(start, next + 1),
                    .value_span = .init(next, next + 1),
                } };
            }
            if (!isNameStart(source[next])) return .none;
            var end = next + 1;
            while (end < limit and isNameContinue(source[end])) : (end += 1) {}
            return .{ .complete = .{
                .kind = .parameter,
                .span = .init(start, end),
                .value_span = .init(next, end),
            } };
        },
    }
}

fn backquoteCommandSubstitutionEnd(source: []const u8, limit: usize, start: usize) ?usize {
    std.debug.assert(start < limit);
    std.debug.assert(source[start] == '`');

    var index = start + 1;
    while (index < limit) : (index += 1) {
        if (source[index] == '\\' and index + 1 < limit) {
            index += 1;
            continue;
        }
        if (source[index] == '`') return index + 1;
    }
    return null;
}

pub fn parameterExpansionEnd(allocator: std.mem.Allocator, source: []const u8, limit: usize, start: usize) std.mem.Allocator.Error!?usize {
    std.debug.assert(start + 1 < limit);
    std.debug.assert(source[start] == '$');
    std.debug.assert(source[start + 1] == '{');

    var scanner: ParameterExpansionScanner = .{
        .allocator = allocator,
        .source = source,
        .limit = limit,
        .index = start + 2,
    };
    return scanner.scan();
}

pub fn arithmeticExpansionEnd(allocator: std.mem.Allocator, source: []const u8, limit: usize, start: usize) std.mem.Allocator.Error!?usize {
    switch (try arithmeticExpansionScan(allocator, source, limit, start)) {
        .complete => |end| return end,
        .incomplete_backquote, .incomplete_arithmetic => return null,
    }
}

const ArithmeticExpansionScanResult = union(enum) {
    complete: usize,
    incomplete_backquote: usize,
    incomplete_arithmetic,
};

fn arithmeticExpansionScan(allocator: std.mem.Allocator, source: []const u8, limit: usize, start: usize) std.mem.Allocator.Error!ArithmeticExpansionScanResult {
    std.debug.assert(start + 2 < limit);
    std.debug.assert(source[start] == '$');
    std.debug.assert(source[start + 1] == '(');
    std.debug.assert(source[start + 2] == '(');

    var scanner: ArithmeticExpansionScanner = .{
        .allocator = allocator,
        .source = source,
        .limit = limit,
        .index = start + 3,
    };
    return scanner.scan();
}

const ArithmeticExpansionScanner = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    limit: usize,
    index: usize,
    paren_depth: usize = 0,
    incomplete_backquote_start: ?usize = null,

    fn scan(self: *ArithmeticExpansionScanner) std.mem.Allocator.Error!ArithmeticExpansionScanResult {
        while (self.index < self.limit) {
            switch (self.source[self.index]) {
                '\\' => self.skipBackslash(),
                '$' => try self.skipDollarExpansion(),
                '`' => self.skipBackquoted(),
                '(' => {
                    self.paren_depth += 1;
                    self.index += 1;
                },
                ')' => {
                    if (self.paren_depth == 0 and self.index + 1 < self.limit and self.source[self.index + 1] == ')') return .{ .complete = self.index + 2 };
                    if (self.paren_depth != 0) self.paren_depth -= 1;
                    self.index += 1;
                },
                else => self.index += 1,
            }
        }
        if (self.incomplete_backquote_start) |start| return .{ .incomplete_backquote = start };
        return .incomplete_arithmetic;
    }

    fn skipBackslash(self: *ArithmeticExpansionScanner) void {
        self.index += 1;
        if (self.index < self.limit and isArithmeticBackslashEscaped(self.source[self.index])) {
            self.index += 1;
        }
    }

    fn skipDollarExpansion(self: *ArithmeticExpansionScanner) std.mem.Allocator.Error!void {
        if (self.index + 1 >= self.limit or self.source[self.index] != '$') {
            self.index += 1;
            return;
        }

        switch (try shellSubstitutionAt(self.allocator, self.source, self.limit, self.index)) {
            .complete => |substitution| self.index = substitution.span.end,
            .incomplete => self.index = self.limit,
            .none => self.index += 1,
        }
    }

    fn skipBackquoted(self: *ArithmeticExpansionScanner) void {
        const start = self.index;
        self.index += 1;
        while (self.index < self.limit) {
            switch (self.source[self.index]) {
                '\\' => {
                    self.index += 1;
                    if (self.index < self.limit) self.index += 1;
                },
                '`' => {
                    self.index += 1;
                    return;
                },
                else => self.index += 1,
            }
        }
        self.incomplete_backquote_start = start;
    }
};

fn isArithmeticBackslashEscaped(c: u8) bool {
    return c == '$' or c == '`' or c == '\\' or c == '\n';
}

const ParameterExpansionScanner = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    limit: usize,
    index: usize,

    fn scan(self: *ParameterExpansionScanner) std.mem.Allocator.Error!?usize {
        while (self.index < self.limit) {
            switch (self.source[self.index]) {
                '\\' => self.skipBackslash(),
                '\'' => skipQuoted(self.source, self.limit, &self.index, '\''),
                '"' => try self.skipDoubleQuoted(),
                '`' => self.skipBackquoted(),
                '$' => try self.skipDollarExpansion(),
                '}' => {
                    self.index += 1;
                    return self.index;
                },
                else => self.index += 1,
            }
        }
        return null;
    }

    fn skipDollarExpansion(self: *ParameterExpansionScanner) std.mem.Allocator.Error!void {
        if (self.index + 1 >= self.limit or self.source[self.index] != '$') {
            self.index += 1;
            return;
        }

        switch (try shellSubstitutionAt(self.allocator, self.source, self.limit, self.index)) {
            .complete => |substitution| self.index = substitution.span.end,
            .incomplete => self.index = self.limit,
            .none => self.index += 1,
        }
    }

    fn skipDoubleQuoted(self: *ParameterExpansionScanner) std.mem.Allocator.Error!void {
        std.debug.assert(self.source[self.index] == '"');
        self.index += 1;
        while (self.index < self.limit and self.source[self.index] != '"') {
            switch (self.source[self.index]) {
                '\\' => self.skipBackslash(),
                '$' => try self.skipDollarExpansion(),
                '`' => self.skipBackquoted(),
                else => self.index += 1,
            }
        }
        if (self.index < self.limit) self.index += 1;
    }

    fn skipBackquoted(self: *ParameterExpansionScanner) void {
        self.index += 1;
        while (self.index < self.limit) {
            switch (self.source[self.index]) {
                '\\' => self.skipBackslash(),
                '`' => {
                    self.index += 1;
                    return;
                },
                else => self.index += 1,
            }
        }
    }

    fn skipBackslash(self: *ParameterExpansionScanner) void {
        self.index += 1;
        if (self.index < self.limit) self.index += 1;
    }
};

const CasePhase = enum {
    subject,
    pattern,
    body,
};

const CaseContext = struct {
    phase: CasePhase = .subject,
    saw_subject: bool = false,
};

const CommandSubstitutionScanner = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    limit: usize,
    index: usize,
    paren_depth: usize = 1,
    command_position: bool = true,
    cases: std.ArrayList(CaseContext) = .empty,

    fn deinit(self: *CommandSubstitutionScanner) void {
        self.cases.deinit(self.allocator);
    }

    fn scan(self: *CommandSubstitutionScanner) std.mem.Allocator.Error!?usize {
        while (self.index < self.limit) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t', '\r' => self.index += 1,
                '\n' => {
                    self.command_position = true;
                    self.index += 1;
                },
                '#' => if (self.command_position) {
                    self.skipComment();
                } else {
                    try self.scanWord();
                },
                '(' => {
                    if (self.topCasePhase() == .pattern) {
                        self.index += 1;
                    } else {
                        self.paren_depth += 1;
                        self.command_position = true;
                        self.index += 1;
                    }
                },
                ')' => {
                    if (self.topCasePhase() == .pattern) {
                        self.setTopCasePhase(.body);
                        self.command_position = true;
                        self.index += 1;
                    } else {
                        self.paren_depth -= 1;
                        self.index += 1;
                        if (self.paren_depth == 0) return self.index;
                        self.command_position = false;
                    }
                },
                ';' => {
                    if (self.index + 1 < self.limit and self.source[self.index + 1] == ';') {
                        if (self.topCasePhase() == .body) self.setTopCasePhase(.pattern);
                        self.command_position = true;
                        self.index += 2;
                    } else {
                        self.command_position = true;
                        self.index += 1;
                    }
                },
                '|' => {
                    if (self.topCasePhase() == .pattern) {
                        self.index += 1;
                    } else {
                        self.command_position = true;
                        self.index += if (self.index + 1 < self.limit and self.source[self.index + 1] == '|') 2 else 1;
                    }
                },
                '&' => {
                    self.command_position = true;
                    self.index += if (self.index + 1 < self.limit and self.source[self.index + 1] == '&') 2 else 1;
                },
                '<', '>' => {
                    self.command_position = false;
                    self.index += self.operatorLen();
                },
                else => try self.scanWord(),
            }
        }
        return null;
    }

    fn scanWord(self: *CommandSubstitutionScanner) std.mem.Allocator.Error!void {
        const start = self.index;
        var keyword_possible = true;
        while (self.index < self.limit and !isCommandSubstitutionWordBoundary(self.source[self.index])) {
            switch (self.source[self.index]) {
                '\\' => {
                    keyword_possible = false;
                    self.skipBackslash();
                },
                '\'' => {
                    keyword_possible = false;
                    skipQuoted(self.source, self.limit, &self.index, '\'');
                },
                '"' => {
                    keyword_possible = false;
                    try self.skipDoubleQuoted();
                },
                '`' => {
                    keyword_possible = false;
                    self.skipBackquoted();
                },
                '$' => {
                    keyword_possible = false;
                    if (!try self.skipDollarExpansion()) self.index += 1;
                },
                else => self.index += 1,
            }
        }

        const word: ?[]const u8 = if (keyword_possible) self.source[start..self.index] else null;
        try self.observeWord(word);
    }

    fn observeWord(self: *CommandSubstitutionScanner, maybe_word: ?[]const u8) std.mem.Allocator.Error!void {
        if (self.topCase()) |case_context| {
            switch (case_context.phase) {
                .subject => {
                    if (maybe_word) |word| {
                        if (case_context.saw_subject and std.mem.eql(u8, word, "in")) {
                            case_context.phase = .pattern;
                            self.command_position = true;
                            return;
                        }
                    }
                    case_context.saw_subject = true;
                    self.command_position = false;
                    return;
                },
                .pattern => {
                    if (maybe_word) |word| {
                        if (std.mem.eql(u8, word, "esac")) {
                            _ = self.cases.pop();
                            self.command_position = false;
                            return;
                        }
                    }
                    self.command_position = false;
                    return;
                },
                .body => {
                    if (maybe_word) |word| {
                        if (self.command_position and std.mem.eql(u8, word, "esac")) {
                            _ = self.cases.pop();
                            self.command_position = false;
                            return;
                        }
                        if (self.command_position and std.mem.eql(u8, word, "case")) {
                            try self.cases.append(self.allocator, .{});
                            self.command_position = false;
                            return;
                        }
                    }
                },
            }
        }

        if (maybe_word) |word| {
            if (self.command_position and std.mem.eql(u8, word, "case")) {
                try self.cases.append(self.allocator, .{});
                self.command_position = false;
                return;
            }
            if (std.mem.eql(u8, word, "then") or std.mem.eql(u8, word, "do") or
                std.mem.eql(u8, word, "else") or std.mem.eql(u8, word, "elif"))
            {
                self.command_position = true;
                return;
            }
        }

        self.command_position = false;
    }

    fn skipDollarExpansion(self: *CommandSubstitutionScanner) std.mem.Allocator.Error!bool {
        if (self.index + 1 >= self.limit or self.source[self.index] != '$') return false;

        switch (try shellSubstitutionAt(self.allocator, self.source, self.limit, self.index)) {
            .complete => |substitution| self.index = substitution.span.end,
            .incomplete => self.index = self.limit,
            .none => self.index += 1,
        }
        return true;
    }

    fn skipDoubleQuoted(self: *CommandSubstitutionScanner) std.mem.Allocator.Error!void {
        std.debug.assert(self.source[self.index] == '"');
        self.index += 1;
        while (self.index < self.limit and self.source[self.index] != '"') {
            switch (self.source[self.index]) {
                '\\' => self.skipBackslash(),
                '$' => {
                    if (!try self.skipDollarExpansion()) self.index += 1;
                },
                '`' => self.skipBackquoted(),
                else => self.index += 1,
            }
        }
        if (self.index < self.limit) self.index += 1;
    }

    fn skipBackquoted(self: *CommandSubstitutionScanner) void {
        self.index += 1;
        while (self.index < self.limit) {
            switch (self.source[self.index]) {
                '\\' => self.skipBackslash(),
                '`' => {
                    self.index += 1;
                    return;
                },
                else => self.index += 1,
            }
        }
    }

    fn skipBackslash(self: *CommandSubstitutionScanner) void {
        self.index += 1;
        if (self.index < self.limit) self.index += 1;
    }

    fn skipComment(self: *CommandSubstitutionScanner) void {
        while (self.index < self.limit and self.source[self.index] != '\n') self.index += 1;
    }

    fn operatorLen(self: CommandSubstitutionScanner) usize {
        if (self.index + 1 >= self.limit) return 1;
        return switch (self.source[self.index]) {
            '<' => if (self.source[self.index + 1] == '<' or self.source[self.index + 1] == '&' or self.source[self.index + 1] == '>') 2 else 1,
            '>' => if (self.source[self.index + 1] == '>' or self.source[self.index + 1] == '&' or self.source[self.index + 1] == '|') 2 else 1,
            else => 1,
        };
    }

    fn topCase(self: *CommandSubstitutionScanner) ?*CaseContext {
        if (self.cases.items.len == 0) return null;
        return &self.cases.items[self.cases.items.len - 1];
    }

    fn topCasePhase(self: *CommandSubstitutionScanner) ?CasePhase {
        if (self.topCase()) |case_context| return case_context.phase;
        return null;
    }

    fn setTopCasePhase(self: *CommandSubstitutionScanner, phase: CasePhase) void {
        const case_context = self.topCase() orelse return;
        case_context.phase = phase;
    }
};

fn isCommandSubstitutionWordBoundary(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '|', '&', ';', '(', ')', '<', '>' => true,
        else => false,
    };
}

fn skipQuoted(source: []const u8, limit: usize, index: *usize, quote: u8) void {
    index.* += 1;
    while (index.* < limit and source[index.*] != quote) {
        if (quote == '"' and source[index.*] == '\\') {
            index.* += 1;
            if (index.* < limit) index.* += 1;
        } else {
            index.* += 1;
        }
    }
    if (index.* < limit) index.* += 1;
}

fn defaultHighlightKind(kind: TokenKind) HighlightKind {
    return switch (kind) {
        .invalid => .invalid,
        .eof => .eof,
        .whitespace => .whitespace,
        .newline => .newline,
        .comment => .comment,
        .word => .argument,
        .less,
        .greater,
        .dless,
        .dless_dash,
        .dgreat,
        .less_and,
        .greater_and,
        .less_great,
        .clobber,
        => .redirect,
        else => .operator,
    };
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8, options: ParseOptions) !ParseResult {
    _ = options.mode;
    _ = options.cursor;

    var lex_result = try lex(allocator, source);
    errdefer lex_result.deinit();

    var parser: SyntaxParser = .{
        .allocator = allocator,
        .source = source,
        .tokens = lex_result.tokens,
        .features = options.features,
    };
    errdefer parser.deinit();

    try parser.diagnostics.appendSlice(allocator, lex_result.diagnostics);
    allocator.free(lex_result.diagnostics);
    lex_result.diagnostics = &.{};

    try parser.run();
    parser.freePendingHereDocs();
    parser.pending_here_docs.deinit(allocator);
    parser.pending_here_docs = .empty;

    return .{
        .allocator = allocator,
        .source = source,
        .tokens = lex_result.tokens,
        .nodes = try parser.nodes.toOwnedSlice(allocator),
        .children = try parser.children.toOwnedSlice(allocator),
        .diagnostics = try parser.diagnostics.toOwnedSlice(allocator),
        .incomplete = lex_result.incomplete or parser.incomplete,
    };
}

const PendingHereDoc = struct {
    delimiter: []const u8,
    strip_tabs: bool,
    quoted: bool,
};

fn hereDocDelimiterIsQuoted(raw: []const u8) bool {
    return std.mem.indexOfAny(u8, raw, "'\"\\") != null;
}

fn hereDocDelimiterFromRaw(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote) |active| {
            if (byte == active) {
                quote = null;
            } else if (active == '"' and byte == '\\' and index + 1 < raw.len) {
                index += 1;
                try out.append(allocator, raw[index]);
            } else {
                try out.append(allocator, byte);
            }
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '\\' and index + 1 < raw.len) {
            index += 1;
            try out.append(allocator, raw[index]);
        } else {
            try out.append(allocator, byte);
        }
    }
    return out.toOwnedSlice(allocator);
}

const HereDocBodyParse = struct {
    span: Span,
    found_delimiter: bool,
};

fn parseHereDocBodySpan(source: []const u8, start: usize, delimiter: []const u8, strip_tabs: bool, allow_continuation: bool) HereDocBodyParse {
    var index = @min(start, source.len);
    var continued = false;
    while (index <= source.len) {
        const raw_line_start = index;
        while (index < source.len and source[index] != '\n') : (index += 1) {}
        const raw_line_end = index;
        const line_start_no_tabs = if (strip_tabs) blk: {
            var line_start = raw_line_start;
            while (line_start < raw_line_end and source[line_start] == '\t') : (line_start += 1) {}
            break :blk line_start;
        } else raw_line_start;
        // A physical line joined to the previous one by backslash-newline
        // is body text and cannot be the delimiter (POSIX XCU 2.7.4 gives
        // unquoted bodies double-quote backslash semantics).
        if (!continued and std.mem.eql(u8, source[line_start_no_tabs..raw_line_end], delimiter)) {
            const end = if (index < source.len and source[index] == '\n') index + 1 else index;
            return .{ .span = .init(start, end), .found_delimiter = true };
        }
        continued = allow_continuation and hasTrailingLineContinuation(source[raw_line_start..raw_line_end]);
        if (index < source.len and source[index] == '\n') {
            index += 1;
        } else break;
    }
    return .{ .span = .init(start, source.len), .found_delimiter = false };
}

pub fn hasTrailingLineContinuation(line: []const u8) bool {
    var backslashes: usize = 0;
    var index = line.len;
    while (index > 0 and line[index - 1] == '\\') {
        backslashes += 1;
        index -= 1;
    }
    return backslashes % 2 == 1;
}

const SyntaxParser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    features: compat.Features = .{},
    index: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    children: std.ArrayList(SyntaxChild) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    pending_here_docs: std.ArrayList(PendingHereDoc) = .empty,
    incomplete: bool = false,

    fn deinit(self: *SyntaxParser) void {
        self.nodes.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.freePendingHereDocs();
        self.pending_here_docs.deinit(self.allocator);
    }

    fn run(self: *SyntaxParser) !void {
        try self.nodes.append(self.allocator, .{
            .kind = .root,
            .span = .init(0, self.source.len),
            .token_start = 0,
            .token_end = self.tokens.len,
            .child_start = 0,
            .child_end = 0,
        });

        var root_children: std.ArrayList(SyntaxChild) = .empty;
        defer root_children.deinit(self.allocator);

        while (!self.at(.eof)) {
            if (self.current().kind.isTrivia() and self.current().kind != .newline) {
                try root_children.append(self.allocator, .{ .token = .init(self.index) });
                self.index += 1;
            } else if (self.startsListElement()) {
                const list = try self.parseList();
                try root_children.append(self.allocator, .{ .node = list });
            } else {
                try root_children.append(self.allocator, .{ .token = .init(self.index) });
                self.index += 1;
            }
        }

        try root_children.append(self.allocator, .{ .token = .init(self.index) });

        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, root_children.items);
        self.nodes.items[0].child_start = child_start;
        self.nodes.items[0].child_end = self.children.items.len;
    }

    fn parseList(self: *SyntaxParser) anyerror!NodeId {
        return self.parseListUntil(&.{}, &.{});
    }

    fn parseListUntil(self: *SyntaxParser, word_terminators: []const []const u8, token_terminators: []const TokenKind) anyerror!NodeId {
        const token_start = self.index;
        var list_children: std.ArrayList(SyntaxChild) = .empty;
        defer list_children.deinit(self.allocator);

        while (!self.at(.eof) and !self.atListTerminator(word_terminators, token_terminators)) {
            if (self.startsFunctionDefinition()) {
                const function_definition = try self.parseFunctionDefinition();
                try list_children.append(self.allocator, .{ .node = function_definition });
                continue;
            }

            if (self.startsBraceGroup()) {
                const brace_group = try self.parseBraceGroup();
                try list_children.append(self.allocator, .{ .node = brace_group });
                continue;
            }

            if (self.startsSubshell()) {
                const subshell = try self.parseSubshell();
                try list_children.append(self.allocator, .{ .node = subshell });
                continue;
            }

            if (self.startsBashTestCommand()) {
                const bash_test = try self.parseBashTestCommand();
                try list_children.append(self.allocator, .{ .node = bash_test });
                continue;
            }

            if (self.startsIfCommand()) {
                const if_command = try self.parseIfCommand();
                try list_children.append(self.allocator, .{ .node = if_command });
                continue;
            }

            if (self.startsLoopCommand()) {
                const loop_command = try self.parseLoopCommand();
                try list_children.append(self.allocator, .{ .node = loop_command });
                continue;
            }

            if (self.startsForCommand()) {
                const for_command = try self.parseForCommand();
                try list_children.append(self.allocator, .{ .node = for_command });
                continue;
            }

            if (self.startsCaseCommand()) {
                const case_command = try self.parseCaseCommand();
                try list_children.append(self.allocator, .{ .node = case_command });
                continue;
            }

            if (self.features.strict_diagnostics and self.atMisplacedReservedWord()) {
                try self.diagnostics.append(self.allocator, .{
                    .kind = .parse_error,
                    .span = self.current().span,
                    .message = "misplaced reserved word",
                });
                try self.appendCurrentTokenChildTo(&list_children);
                continue;
            }

            if (self.startsPipeline()) {
                const pipeline = try self.parsePipeline();
                try list_children.append(self.allocator, .{ .node = pipeline });
                continue;
            }

            if (self.current().kind.isTrivia() or isListSeparator(self.current().kind)) {
                const was_newline = self.at(.newline);
                try self.appendCurrentTokenChildTo(&list_children);
                if (was_newline) try self.drainHereDocBodies(&list_children);
                continue;
            }

            break;
        }

        if (self.at(.eof)) try self.drainHereDocBodies(&list_children);

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, list_children.items);
        const span = spanForPossiblyEmptyTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.list, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseRawListUntilWord(self: *SyntaxParser, terminator: []const u8) !NodeId {
        const token_start = self.index;
        var list_children: std.ArrayList(SyntaxChild) = .empty;
        defer list_children.deinit(self.allocator);
        while (!self.at(.eof) and !self.atWord(terminator)) {
            try self.appendCurrentTokenChildTo(&list_children);
        }
        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, list_children.items);
        const span = spanForPossiblyEmptyTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.list, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseIfCommand(self: *SyntaxParser) anyerror!NodeId {
        const token_start = self.index;
        var if_children: std.ArrayList(SyntaxChild) = .empty;
        defer if_children.deinit(self.allocator);
        var saw_then = false;
        var closed = false;

        try self.appendCurrentTokenChildTo(&if_children);
        const condition = try self.parseListUntil(&.{ "then", "fi" }, &.{});
        try if_children.append(self.allocator, .{ .node = condition });
        if (self.atWord("then")) {
            saw_then = true;
            try self.appendCurrentTokenChildTo(&if_children);
            const then_body = try self.parseListUntil(&.{ "elif", "else", "fi" }, &.{});
            try if_children.append(self.allocator, .{ .node = then_body });
        }
        while (self.atWord("elif")) {
            try self.appendCurrentTokenChildTo(&if_children);
            const elif_condition = try self.parseListUntil(&.{ "then", "fi" }, &.{});
            try if_children.append(self.allocator, .{ .node = elif_condition });
            if (self.atWord("then")) {
                saw_then = true;
                try self.appendCurrentTokenChildTo(&if_children);
                const elif_body = try self.parseListUntil(&.{ "elif", "else", "fi" }, &.{});
                try if_children.append(self.allocator, .{ .node = elif_body });
            }
        }
        if (self.atWord("else")) {
            try self.appendCurrentTokenChildTo(&if_children);
            const else_body = try self.parseListUntil(&.{"fi"}, &.{});
            try if_children.append(self.allocator, .{ .node = else_body });
        }
        if (self.atWord("fi")) {
            try self.appendCurrentTokenChildTo(&if_children);
            closed = true;
        }

        if (!saw_then) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing then in if command",
            });
        }
        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing fi to close if command",
            });
        }

        try self.parseTrailingRedirections(&if_children);

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, if_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.if_command, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseTrailingRedirections(self: *SyntaxParser, children: *std.ArrayList(SyntaxChild)) !void {
        while (self.current().kind == .whitespace) {
            try self.appendCurrentTokenChildTo(children);
        }
        while (self.startsRedirection()) {
            const redirection = try self.parseRedirection();
            try children.append(self.allocator, .{ .node = redirection });
            while (self.current().kind == .whitespace) {
                try self.appendCurrentTokenChildTo(children);
            }
        }
    }

    fn parseSubshell(self: *SyntaxParser) anyerror!NodeId {
        const token_start = self.index;
        var subshell_children: std.ArrayList(SyntaxChild) = .empty;
        defer subshell_children.deinit(self.allocator);
        var closed = false;

        try self.appendCurrentTokenChildTo(&subshell_children);
        if (!self.at(.right_paren) and !self.at(.eof)) {
            const body = try self.parseListUntil(&.{}, &.{.right_paren});
            try subshell_children.append(self.allocator, .{ .node = body });
        }
        if (self.at(.right_paren)) {
            try self.appendCurrentTokenChildTo(&subshell_children);
            closed = true;
        }

        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing ) to close subshell",
            });
        }

        while (self.current().kind == .whitespace) {
            try self.appendCurrentTokenChildTo(&subshell_children);
        }
        while (self.startsRedirection()) {
            const redirection = try self.parseRedirection();
            try subshell_children.append(self.allocator, .{ .node = redirection });
            while (self.current().kind == .whitespace) {
                try self.appendCurrentTokenChildTo(&subshell_children);
            }
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, subshell_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.subshell, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseBraceGroup(self: *SyntaxParser) anyerror!NodeId {
        const token_start = self.index;
        var group_children: std.ArrayList(SyntaxChild) = .empty;
        defer group_children.deinit(self.allocator);
        var closed = false;

        try self.appendCurrentTokenChildTo(&group_children);
        if (!self.at(.word) or !std.mem.eql(u8, self.current().lexeme(self.source), "}")) {
            const body = try self.parseListUntil(&.{"}"}, &.{});
            try group_children.append(self.allocator, .{ .node = body });
        }
        if (self.at(.word) and std.mem.eql(u8, self.current().lexeme(self.source), "}")) {
            try self.appendCurrentTokenChildTo(&group_children);
            closed = true;
        }

        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing } to close brace group",
            });
        }

        while (self.current().kind == .whitespace) {
            try self.appendCurrentTokenChildTo(&group_children);
        }
        while (self.startsRedirection()) {
            const redirection = try self.parseRedirection();
            try group_children.append(self.allocator, .{ .node = redirection });
            while (self.current().kind == .whitespace) {
                try self.appendCurrentTokenChildTo(&group_children);
            }
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, group_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.brace_group, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseFunctionDefinition(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var function_children: std.ArrayList(SyntaxChild) = .empty;
        defer function_children.deinit(self.allocator);

        try self.appendCurrentTokenChildTo(&function_children);
        try self.appendCurrentTokenChildTo(&function_children);
        try self.appendCurrentTokenChildTo(&function_children);

        while (self.current().kind.isTrivia()) {
            try self.appendCurrentTokenChildTo(&function_children);
        }

        if (!self.startsBraceGroup() and self.startsFunctionBodyCompoundCommand()) {
            const body = try self.parseFunctionBodyCompoundCommand();
            try function_children.append(self.allocator, .{ .node = body });
            try self.parseTrailingRedirections(&function_children);

            const token_end = self.index;
            const child_start = self.children.items.len;
            try self.children.appendSlice(self.allocator, function_children.items);
            const span = spanForTokenRange(self.tokens, token_start, token_end);
            return self.addNode(.function_definition, span, token_start, token_end, child_start, self.children.items.len);
        }

        var brace_depth: usize = 0;
        var saw_open_brace = false;
        var closed = false;
        var command_position = true;

        while (!self.at(.eof)) {
            const token = self.current();
            if (token.kind == .word) {
                const lexeme = token.lexeme(self.source);
                if (command_position and std.mem.eql(u8, lexeme, "{")) {
                    saw_open_brace = true;
                    brace_depth += 1;
                } else if (command_position and saw_open_brace and std.mem.eql(u8, lexeme, "}")) {
                    if (brace_depth > 0) brace_depth -= 1;
                    closed = brace_depth == 0;
                    command_position = false;
                } else {
                    command_position = command_position and functionBodyWordContinuesCommandPosition(lexeme);
                }
            } else if (token.kind != .whitespace and token.kind != .comment) {
                command_position = isSimpleCommandSeparator(token.kind) or token.kind == .left_paren or token.kind == .right_paren;
            }
            try self.appendCurrentTokenChildTo(&function_children);
            if (closed) break;
        }

        if (!saw_open_brace) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing function body",
            });
        }
        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing } to close function definition",
            });
        }

        try self.parseTrailingRedirections(&function_children);

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, function_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.function_definition, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn startsFunctionBodyCompoundCommand(self: SyntaxParser) bool {
        return self.startsSubshell() or self.startsBashTestCommand() or self.startsIfCommand() or self.startsLoopCommand() or self.startsForCommand() or self.startsCaseCommand();
    }

    fn parseFunctionBodyCompoundCommand(self: *SyntaxParser) !NodeId {
        if (self.startsSubshell()) return self.parseSubshell();
        if (self.startsBashTestCommand()) return self.parseBashTestCommand();
        if (self.startsIfCommand()) return self.parseIfCommand();
        if (self.startsLoopCommand()) return self.parseLoopCommand();
        if (self.startsForCommand()) return self.parseForCommand();
        std.debug.assert(self.startsCaseCommand());
        return self.parseCaseCommand();
    }

    fn parseCaseCommand(self: *SyntaxParser) anyerror!NodeId {
        const token_start = self.index;
        var case_children: std.ArrayList(SyntaxChild) = .empty;
        defer case_children.deinit(self.allocator);
        var saw_in = false;
        var closed = false;

        if (!self.at(.eof)) try self.appendCurrentTokenChildTo(&case_children);
        while (!self.at(.eof) and self.current().kind.isTrivia()) {
            try self.appendCurrentTokenChildTo(&case_children);
        }
        if (!self.at(.eof)) try self.appendCurrentTokenChildTo(&case_children);
        while (!self.at(.eof) and !self.atWord("in") and !self.atWord("esac")) {
            try self.appendCurrentTokenChildTo(&case_children);
        }
        if (self.atWord("in")) {
            saw_in = true;
            try self.appendCurrentTokenChildTo(&case_children);
            while (!self.at(.eof)) {
                if (self.current().kind.isTrivia()) {
                    try self.appendCurrentTokenChildTo(&case_children);
                    continue;
                }
                if (self.atWord("esac") and !self.esacStartsCaseItemPattern()) break;
                const item = try self.parseCaseItem();
                try case_children.append(self.allocator, .{ .node = item });
            }
        }
        if (self.atWord("esac")) {
            try self.appendCurrentTokenChildTo(&case_children);
            closed = true;
        }

        if (!saw_in) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing in in case command",
            });
        }
        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing esac to close case command",
            });
        }

        try self.parseTrailingRedirections(&case_children);

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, case_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.case_command, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseCaseItem(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var item_children: std.ArrayList(SyntaxChild) = .empty;
        defer item_children.deinit(self.allocator);
        var saw_pattern_end = false;
        var nested_case_depth: usize = 0;

        while (!self.at(.eof)) {
            if (self.atWord("esac") and nested_case_depth == 0 and (saw_pattern_end or !self.esacStartsCaseItemPattern())) break;
            try self.appendCurrentTokenChildTo(&item_children);
            const previous = self.previousToken();
            if (previous.kind == .right_paren) {
                saw_pattern_end = true;
                continue;
            }
            if (saw_pattern_end and previous.kind == .word) {
                const lexeme = previous.lexeme(self.source);
                if (std.mem.eql(u8, lexeme, "case")) {
                    nested_case_depth += 1;
                } else if (std.mem.eql(u8, lexeme, "esac") and nested_case_depth > 0) {
                    nested_case_depth -= 1;
                }
            }
            if (saw_pattern_end and nested_case_depth == 0 and previous.kind == .dsemicolon) break;
        }

        if (!saw_pattern_end) {
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing ) in case item",
            });
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, item_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.case_item, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn esacStartsCaseItemPattern(self: SyntaxParser) bool {
        if (!self.atWord("esac")) return false;
        var index = self.index + 1;
        while (index < self.tokens.len and self.tokens[index].kind.isTrivia()) : (index += 1) {}
        if (index >= self.tokens.len) return false;
        return self.tokens[index].kind == .right_paren or self.tokens[index].kind == .pipe;
    }

    fn parseBashTestCommand(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var test_children: std.ArrayList(SyntaxChild) = .empty;
        defer test_children.deinit(self.allocator);
        var closed = false;

        while (!self.at(.eof)) {
            const token = self.current();
            try self.appendCurrentTokenChildTo(&test_children);
            if (token.kind == .word and std.mem.eql(u8, token.lexeme(self.source), "]]")) {
                closed = true;
                break;
            }
        }

        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing ]] to close Bash conditional command",
            });
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, test_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.bash_test_command, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseForCommand(self: *SyntaxParser) anyerror!NodeId {
        const token_start = self.index;
        var for_children: std.ArrayList(SyntaxChild) = .empty;
        defer for_children.deinit(self.allocator);
        var saw_name = false;
        var saw_do = false;
        var closed = false;

        try self.appendCurrentTokenChildTo(&for_children);
        while (self.current().kind.isTrivia()) {
            try self.appendCurrentTokenChildTo(&for_children);
        }
        if (self.at(.word) and !self.atWord("in") and isName(self.current().lexeme(self.source))) {
            saw_name = true;
            try self.appendCurrentTokenChildTo(&for_children);
        }
        while (!self.at(.eof) and !self.atWord("do") and !self.atWord("done")) {
            try self.appendCurrentTokenChildTo(&for_children);
        }
        if (self.atWord("do")) {
            saw_do = true;
            try self.appendCurrentTokenChildTo(&for_children);
            const body = try self.parseListUntil(&.{"done"}, &.{});
            try for_children.append(self.allocator, .{ .node = body });
        }
        if (self.atWord("done")) {
            try self.appendCurrentTokenChildTo(&for_children);
            closed = true;
        }

        if (!saw_name) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing loop variable in for command",
            });
        }
        if (!saw_do) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing do in for command",
            });
        }
        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = "missing done to close for command",
            });
        }

        try self.parseTrailingRedirections(&for_children);

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, for_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.for_command, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseLoopCommand(self: *SyntaxParser) anyerror!NodeId {
        const token_start = self.index;
        const opener = self.current().lexeme(self.source);
        var loop_children: std.ArrayList(SyntaxChild) = .empty;
        defer loop_children.deinit(self.allocator);
        var saw_do = false;
        var closed = false;

        try self.appendCurrentTokenChildTo(&loop_children);
        const condition = try self.parseListUntil(&.{ "do", "done" }, &.{});
        try loop_children.append(self.allocator, .{ .node = condition });
        if (self.atWord("do")) {
            saw_do = true;
            try self.appendCurrentTokenChildTo(&loop_children);
            const body = try self.parseListUntil(&.{"done"}, &.{});
            try loop_children.append(self.allocator, .{ .node = body });
        }
        if (self.atWord("done")) {
            try self.appendCurrentTokenChildTo(&loop_children);
            closed = true;
        }
        try self.parseTrailingRedirections(&loop_children);

        if (!saw_do) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = if (std.mem.eql(u8, opener, "while")) "missing do in while command" else "missing do in until command",
            });
        }
        if (!closed) {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .incomplete_input,
                .span = spanForTokenRange(self.tokens, token_start, self.index),
                .message = if (std.mem.eql(u8, opener, "while")) "missing done to close while command" else "missing done to close until command",
            });
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, loop_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.loop_command, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parsePipeline(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var pipeline_children: std.ArrayList(SyntaxChild) = .empty;
        defer pipeline_children.deinit(self.allocator);

        if (self.atWord("!")) {
            try self.appendCurrentTokenChildTo(&pipeline_children);
            while (self.current().kind == .whitespace) {
                try self.appendCurrentTokenChildTo(&pipeline_children);
            }
        }

        const first_command = try self.parseSimpleCommand();
        try pipeline_children.append(self.allocator, .{ .node = first_command });

        while (!self.at(.eof)) {
            while (self.current().kind == .whitespace) {
                try self.appendCurrentTokenChildTo(&pipeline_children);
            }

            if (!self.at(.pipe)) break;
            const pipe_span = self.current().span;
            try self.appendCurrentTokenChildTo(&pipeline_children);

            while (self.current().kind == .whitespace) {
                try self.appendCurrentTokenChildTo(&pipeline_children);
            }

            if (!self.startsSimpleCommand()) {
                self.incomplete = true;
                try self.diagnostics.append(self.allocator, .{
                    .kind = .parse_error,
                    .span = pipe_span,
                    .message = "missing command after pipeline operator",
                });
                break;
            }

            const command = try self.parseSimpleCommand();
            try pipeline_children.append(self.allocator, .{ .node = command });
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, pipeline_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.pipeline, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseSimpleCommand(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var command_children: std.ArrayList(SyntaxChild) = .empty;
        defer command_children.deinit(self.allocator);
        var saw_command_word = false;

        while (!self.at(.eof) and !isSimpleCommandSeparator(self.current().kind)) {
            if (self.current().kind.isTrivia()) {
                try self.appendCurrentTokenChildTo(&command_children);
                continue;
            }

            if (self.startsRedirection()) {
                const redirection = try self.parseRedirection();
                try command_children.append(self.allocator, .{ .node = redirection });
                continue;
            }

            if (self.at(.word)) {
                if (!saw_command_word) {
                    if (try self.bashIndexedArrayAssignmentTokenEnd()) |token_end| {
                        const word = try self.addWordNodeForTokenRange(.assignment_word, self.index, token_end);
                        try command_children.append(self.allocator, .{ .node = word });
                        self.index = token_end;
                        continue;
                    }
                }

                const kind: NodeKind = if (!saw_command_word and isAssignmentWord(self.current().lexeme(self.source), self.features))
                    .assignment_word
                else if (!saw_command_word) blk: {
                    saw_command_word = true;
                    break :blk .command_word;
                } else .word;
                const word = try self.addWordNode(kind, self.index);
                try command_children.append(self.allocator, .{ .node = word });
                self.index += 1;
                continue;
            }

            break;
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, command_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.simple_command, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parseRedirection(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var redirection_children: std.ArrayList(SyntaxChild) = .empty;
        defer redirection_children.deinit(self.allocator);

        if (self.startsIoNumberRedirection()) {
            const io_number = try self.addLeafNode(.io_number, self.index);
            try redirection_children.append(self.allocator, .{ .node = io_number });
            self.index += 1;
        }

        std.debug.assert(self.current().kind.isRedirectOperator());
        const operator = self.current().kind;
        const operator_span = self.current().span;
        try self.appendCurrentTokenChildTo(&redirection_children);

        while (self.current().kind == .whitespace) {
            try self.appendCurrentTokenChildTo(&redirection_children);
        }

        if (self.at(.word)) {
            const raw_target = self.current().lexeme(self.source);
            const target = try self.addWordNode(.word, self.index);
            try redirection_children.append(self.allocator, .{ .node = target });
            self.index += 1;
            if (operator == .dless or operator == .dless_dash) {
                try self.pending_here_docs.append(self.allocator, .{
                    .delimiter = try hereDocDelimiterFromRaw(self.allocator, raw_target),
                    .strip_tabs = operator == .dless_dash,
                    .quoted = hereDocDelimiterIsQuoted(raw_target),
                });
            }
        } else {
            self.incomplete = true;
            try self.diagnostics.append(self.allocator, .{
                .kind = .parse_error,
                .span = operator_span,
                .message = "missing redirection target",
            });
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, redirection_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.redirection, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn drainHereDocBodies(self: *SyntaxParser, children_out: *std.ArrayList(SyntaxChild)) !void {
        while (self.pending_here_docs.items.len != 0) {
            const doc = self.pending_here_docs.orderedRemove(0);
            defer self.allocator.free(doc.delimiter);
            const body_start = if (self.index < self.tokens.len) self.tokens[self.index].span.start else self.source.len;
            const body = parseHereDocBodySpan(self.source, body_start, doc.delimiter, doc.strip_tabs, !doc.quoted);
            const token_start = self.index;
            while (!self.at(.eof) and self.current().span.start < body.span.end) : (self.index += 1) {}
            const token_end = self.index;
            const child_start = self.children.items.len;
            const body_node = try self.addNode(.here_doc_body, body.span, token_start, token_end, child_start, child_start);
            try children_out.append(self.allocator, .{ .node = body_node });
            if (!body.found_delimiter) {
                self.incomplete = true;
                try self.diagnostics.append(self.allocator, .{
                    .kind = .incomplete_input,
                    .span = body.span,
                    .message = "missing here-doc delimiter",
                });
            }
        }
    }

    fn freePendingHereDocs(self: *SyntaxParser) void {
        for (self.pending_here_docs.items) |doc| self.allocator.free(doc.delimiter);
        self.pending_here_docs.clearRetainingCapacity();
    }

    fn addLeafNode(self: *SyntaxParser, kind: NodeKind, token_index: usize) !NodeId {
        const child_start = self.children.items.len;
        try self.children.append(self.allocator, .{ .token = .init(token_index) });
        return self.addNode(kind, self.tokens[token_index].span, token_index, token_index + 1, child_start, self.children.items.len);
    }

    fn addWordNode(self: *SyntaxParser, kind: NodeKind, token_index: usize) !NodeId {
        return self.addWordNodeForTokenRange(kind, token_index, token_index + 1);
    }

    fn addWordNodeForTokenRange(self: *SyntaxParser, kind: NodeKind, token_start: usize, token_end: usize) !NodeId {
        std.debug.assert(token_start < token_end);
        std.debug.assert(token_end <= self.tokens.len);
        var word_children: std.ArrayList(SyntaxChild) = .empty;
        defer word_children.deinit(self.allocator);

        for (token_start..token_end) |token_index| {
            const token = self.tokens[token_index];
            try word_children.append(self.allocator, .{ .token = .init(token_index) });
            if (token.kind != .word) continue;

            var substitutions = try commandSubstitutionSpans(self.allocator, self.source, token.span);
            defer substitutions.deinit(self.allocator);
            for (substitutions.items) |span| {
                const substitution = try self.addCommandSubstitutionNode(token_index, span);
                try word_children.append(self.allocator, .{ .node = substitution });
            }
        }

        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, word_children.items);
        return self.addNode(kind, spanForTokenRange(self.tokens, token_start, token_end), token_start, token_end, child_start, self.children.items.len);
    }

    fn addCommandSubstitutionNode(self: *SyntaxParser, token_index: usize, span: Span) !NodeId {
        var substitution_children: std.ArrayList(SyntaxChild) = .empty;
        defer substitution_children.deinit(self.allocator);

        const inner = if (span.end >= span.start + 3) Span.init(span.start + 2, span.end - 1) else Span.empty(span.start + 2);
        var nested = try commandSubstitutionSpans(self.allocator, self.source, inner);
        defer nested.deinit(self.allocator);
        for (nested.items) |nested_span| {
            const child = try self.addCommandSubstitutionNode(token_index, nested_span);
            try substitution_children.append(self.allocator, .{ .node = child });
        }

        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, substitution_children.items);
        return self.addNode(.command_substitution, span, token_index, token_index + 1, child_start, self.children.items.len);
    }

    fn addNode(self: *SyntaxParser, kind: NodeKind, span: Span, token_start: usize, token_end: usize, child_start: usize, child_end: usize) !NodeId {
        const id = NodeId.init(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .kind = kind,
            .span = span,
            .token_start = token_start,
            .token_end = token_end,
            .child_start = child_start,
            .child_end = child_end,
        });
        return id;
    }

    fn appendCurrentTokenChildTo(self: *SyntaxParser, children: *std.ArrayList(SyntaxChild)) !void {
        try children.append(self.allocator, .{ .token = .init(self.index) });
        self.index += 1;
    }

    fn atWord(self: SyntaxParser, word: []const u8) bool {
        return self.at(.word) and std.mem.eql(u8, self.current().lexeme(self.source), word);
    }

    fn atListTerminator(self: SyntaxParser, word_terminators: []const []const u8, token_terminators: []const TokenKind) bool {
        for (token_terminators) |kind| {
            if (self.at(kind)) return true;
        }
        if (!self.at(.word)) return false;
        const lexeme = self.current().lexeme(self.source);
        for (word_terminators) |word| {
            if (std.mem.eql(u8, lexeme, word)) return true;
        }
        return false;
    }

    fn startsListElement(self: SyntaxParser) bool {
        return self.startsFunctionDefinition() or self.startsBraceGroup() or self.startsSubshell() or self.startsBashTestCommand() or self.startsIfCommand() or self.startsLoopCommand() or self.startsForCommand() or self.startsCaseCommand() or self.startsPipeline();
    }

    fn startsBraceGroup(self: SyntaxParser) bool {
        return self.at(.word) and std.mem.eql(u8, self.current().lexeme(self.source), "{");
    }

    fn startsSubshell(self: SyntaxParser) bool {
        return self.at(.left_paren);
    }

    fn startsFunctionDefinition(self: SyntaxParser) bool {
        if (!self.at(.word) or self.index + 2 >= self.tokens.len) return false;
        if (!isName(self.current().lexeme(self.source))) return false;
        return self.tokens[self.index + 1].kind == .left_paren and self.tokens[self.index + 2].kind == .right_paren;
    }

    fn startsBashTestCommand(self: SyntaxParser) bool {
        return self.features.isBash() and self.at(.word) and std.mem.eql(u8, self.current().lexeme(self.source), "[[");
    }

    fn startsIfCommand(self: SyntaxParser) bool {
        return self.at(.word) and std.mem.eql(u8, self.current().lexeme(self.source), "if");
    }

    fn startsLoopCommand(self: SyntaxParser) bool {
        if (!self.at(.word)) return false;
        const lexeme = self.current().lexeme(self.source);
        return std.mem.eql(u8, lexeme, "while") or std.mem.eql(u8, lexeme, "until");
    }

    fn startsForCommand(self: SyntaxParser) bool {
        return self.at(.word) and std.mem.eql(u8, self.current().lexeme(self.source), "for");
    }

    fn startsCaseCommand(self: SyntaxParser) bool {
        return self.at(.word) and std.mem.eql(u8, self.current().lexeme(self.source), "case");
    }

    fn startsPipeline(self: SyntaxParser) bool {
        return self.startsSimpleCommand();
    }

    fn atMisplacedReservedWord(self: SyntaxParser) bool {
        if (!self.at(.word)) return false;
        const lexeme = self.current().lexeme(self.source);
        return std.mem.eql(u8, lexeme, "then") or
            std.mem.eql(u8, lexeme, "else") or
            std.mem.eql(u8, lexeme, "elif") or
            std.mem.eql(u8, lexeme, "fi") or
            std.mem.eql(u8, lexeme, "do") or
            std.mem.eql(u8, lexeme, "done") or
            std.mem.eql(u8, lexeme, "esac") or
            std.mem.eql(u8, lexeme, "in");
    }

    fn startsSimpleCommand(self: SyntaxParser) bool {
        if (self.startsFunctionDefinition() or self.startsBraceGroup() or self.startsSubshell() or self.startsBashTestCommand() or self.startsIfCommand() or self.startsLoopCommand() or self.startsForCommand() or self.startsCaseCommand()) return false;
        return self.at(.word) or self.current().kind.isRedirectOperator() or self.startsIoNumberRedirection();
    }

    fn startsRedirection(self: SyntaxParser) bool {
        return self.current().kind.isRedirectOperator() or self.startsIoNumberRedirection();
    }

    fn startsIoNumberRedirection(self: SyntaxParser) bool {
        if (!self.at(.word) or self.index + 1 >= self.tokens.len) return false;
        if (!isAllDigits(self.current().lexeme(self.source))) return false;
        const next = self.tokens[self.index + 1];
        return self.current().span.end == next.span.start and next.kind.isRedirectOperator();
    }

    fn bashIndexedArrayAssignmentTokenEnd(self: *SyntaxParser) std.mem.Allocator.Error!?usize {
        if (!self.features.isBash() or !self.at(.word)) return null;
        const first = self.current();
        const word = first.lexeme(self.source);
        if (word.len == 0 or !isNameStart(word[0])) return null;

        var name_end: usize = 1;
        while (name_end < word.len and isNameContinue(word[name_end])) : (name_end += 1) {}
        if (name_end >= word.len or word[name_end] != '[') return null;

        var index = first.span.start + name_end + 1;
        var saw_subscript_byte = false;
        while (index < self.source.len) {
            switch (self.source[index]) {
                ' ', '\t', '\r', '\n' => index += 1,
                ']' => {
                    if (!saw_subscript_byte) return null;
                    if (index + 1 >= self.source.len or self.source[index + 1] != '=') return null;
                    return self.tokenEndContaining(index + 1);
                },
                '\\' => {
                    saw_subscript_byte = true;
                    index += 1;
                    if (index < self.source.len) index += 1;
                },
                '\'' => {
                    saw_subscript_byte = true;
                    skipQuoted(self.source, self.source.len, &index, '\'');
                },
                '"' => {
                    saw_subscript_byte = true;
                    skipQuoted(self.source, self.source.len, &index, '"');
                },
                '`' => {
                    saw_subscript_byte = true;
                    index = backquoteCommandSubstitutionEnd(self.source, self.source.len, index) orelse return null;
                },
                '$' => {
                    saw_subscript_byte = true;
                    switch (try shellSubstitutionAt(self.allocator, self.source, self.source.len, index)) {
                        .complete => |substitution| index = substitution.span.end,
                        .none => index += 1,
                        .incomplete => return null,
                    }
                },
                else => {
                    saw_subscript_byte = true;
                    index += 1;
                },
            }
        }
        return null;
    }

    fn tokenEndContaining(self: SyntaxParser, offset: usize) ?usize {
        for (self.index..self.tokens.len) |token_index| {
            const token = self.tokens[token_index];
            if (token.kind == .eof) return null;
            if (token.span.contains(offset)) return token_index + 1;
        }
        return null;
    }

    fn at(self: SyntaxParser, kind: TokenKind) bool {
        return self.current().kind == kind;
    }

    fn current(self: SyntaxParser) Token {
        std.debug.assert(self.index < self.tokens.len);
        return self.tokens[self.index];
    }

    fn previousToken(self: SyntaxParser) Token {
        std.debug.assert(self.index > 0);
        return self.tokens[self.index - 1];
    }
};

fn isSimpleCommandSeparator(kind: TokenKind) bool {
    return kind == .pipe or isListSeparator(kind);
}

fn isListSeparator(kind: TokenKind) bool {
    return switch (kind) {
        .newline,
        .comment,
        .and_if,
        .or_if,
        .semicolon,
        .dsemicolon,
        .ampersand,
        => true,
        else => false,
    };
}

fn functionBodyWordContinuesCommandPosition(word: []const u8) bool {
    return std.mem.eql(u8, word, "if") or
        std.mem.eql(u8, word, "then") or
        std.mem.eql(u8, word, "elif") or
        std.mem.eql(u8, word, "else") or
        std.mem.eql(u8, word, "while") or
        std.mem.eql(u8, word, "until") or
        std.mem.eql(u8, word, "do") or
        std.mem.eql(u8, word, "case") or
        std.mem.eql(u8, word, "in");
}

fn isAssignmentWord(word: []const u8, features: compat.Features) bool {
    if (word.len == 0) return false;
    if (!isNameStart(word[0])) return false;
    var name_end: usize = 1;
    while (name_end < word.len and isNameContinue(word[name_end])) : (name_end += 1) {}

    if (features.isBash() and name_end < word.len and word[name_end] == '[') {
        const index_start = name_end + 1;
        const close = std.mem.findScalar(u8, word[index_start..], ']') orelse return false;
        const close_index = index_start + close;
        if (index_start == close_index) return false;
        return close_index + 1 < word.len and word[close_index + 1] == '=';
    }

    const equals = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    return name_end == equals;
}

fn isName(word: []const u8) bool {
    if (word.len == 0 or !isNameStart(word[0])) return false;
    for (word[1..]) |c| {
        if (!isNameContinue(c)) return false;
    }
    return true;
}

fn isSpecialParameterChar(c: u8) bool {
    return std.ascii.isDigit(c) or c == '#' or c == '@' or c == '*' or c == '?' or c == '$' or c == '!' or c == '-';
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c);
}

fn isAllDigits(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn spanForTokenRange(tokens: []const Token, start: usize, end: usize) Span {
    std.debug.assert(start < end);
    return .init(tokens[start].span.start, tokens[end - 1].span.end);
}

fn spanForPossiblyEmptyTokenRange(tokens: []const Token, start: usize, end: usize) Span {
    if (start < end) return spanForTokenRange(tokens, start, end);
    return .empty(tokens[start].span.start);
}

pub const ExpectedToken = struct {
    kind: TokenKind,
    span: Span,
};

pub const ExpectedNode = struct {
    kind: NodeKind,
    span: Span,
    token_start: ?usize = null,
    token_end: ?usize = null,
    child_start: ?usize = null,
    child_end: ?usize = null,
};

pub const ExpectedChild = SyntaxChild;

pub const ExpectedDiagnostic = struct {
    kind: DiagnosticKind,
    span: Span,
    message: []const u8,
};

pub const ParseExpectation = struct {
    options: ParseOptions = .{},
    tokens: []const ExpectedToken = &.{},
    nodes: []const ExpectedNode = &.{},
    nodes_exact: bool = false,
    children: ?[]const ExpectedChild = null,
    diagnostics: []const ExpectedDiagnostic = &.{},
    incomplete: bool = false,
};

pub fn expectParse(source: []const u8, expectation: ParseExpectation) !void {
    var result = try parse(std.testing.allocator, source, expectation.options);
    defer result.deinit();

    try std.testing.expectEqual(source.ptr, result.source.ptr);
    try std.testing.expectEqual(expectation.incomplete, result.incomplete);
    try expectTokens(expectation.tokens, result.tokens);
    try expectNodes(expectation.nodes, result.nodes, result.tokens.len, result.children.len, expectation.nodes_exact);
    if (expectation.children) |children| {
        try expectChildren(children, result.children);
    }
    try expectDiagnostics(expectation.diagnostics, result.diagnostics);
}

fn expectTokens(expected: []const ExpectedToken, actual: []const Token) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try expectSpan(want.span, got.span);
    }
}

fn expectNodes(expected: []const ExpectedNode, actual: []const Node, token_len: usize, child_len: usize, exact: bool) !void {
    if (exact) {
        try std.testing.expectEqual(expected.len, actual.len);
    } else {
        try std.testing.expect(actual.len >= expected.len);
    }
    for (expected, actual[0..expected.len]) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try expectSpan(want.span, got.span);
        if (want.token_start) |token_start| try std.testing.expectEqual(token_start, got.token_start);
        if (want.token_end) |token_end| try std.testing.expectEqual(token_end, got.token_end) else _ = token_len;
        if (want.child_start) |child_start| try std.testing.expectEqual(child_start, got.child_start);
        if (want.child_end) |child_end| try std.testing.expectEqual(child_end, got.child_end) else _ = child_len;
    }
}

fn countChildNodesOfKind(result: ParseResult, node: Node, kind: NodeKind) usize {
    var count: usize = 0;
    for (result.nodeChildren(node)) |child| switch (child) {
        .node => |node_id| {
            if (result.nodes[node_id.index()].kind == kind) count += 1;
        },
        .token => {},
    };
    return count;
}

fn expectChildren(expected: []const ExpectedChild, actual: []const SyntaxChild) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        switch (want) {
            .node => |want_node| switch (got) {
                .node => |got_node| try std.testing.expectEqual(want_node, got_node),
                .token => return error.UnexpectedTokenChild,
            },
            .token => |want_token| switch (got) {
                .node => return error.UnexpectedNodeChild,
                .token => |got_token| try std.testing.expectEqual(want_token, got_token),
            },
        }
    }
}

fn expectDiagnostics(expected: []const ExpectedDiagnostic, actual: []const Diagnostic) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try expectSpan(want.span, got.span);
        try std.testing.expectEqualStrings(want.message, got.message);
    }
}

fn expectSpan(expected: Span, actual: Span) !void {
    try std.testing.expectEqual(expected.start, actual.start);
    try std.testing.expectEqual(expected.end, actual.end);
}

test "source spans measure, slice, and answer cursor containment" {
    const source = "echo hello";
    const command = Span.init(0, 4);
    const gap = Span.empty(4);

    try std.testing.expectEqual(@as(usize, 4), command.len());
    try std.testing.expect(!command.isEmpty());
    try std.testing.expect(gap.isEmpty());
    try std.testing.expect(command.contains(0));
    try std.testing.expect(command.contains(3));
    try std.testing.expect(!command.contains(4));
    try std.testing.expect(command.touches(4));
    try std.testing.expectEqualStrings("echo", command.slice(source));
}

test "token model classifies trivia, operators, and redirection operators" {
    try std.testing.expect(TokenKind.whitespace.isTrivia());
    try std.testing.expect(TokenKind.comment.isTrivia());
    try std.testing.expect(!TokenKind.word.isTrivia());

    try std.testing.expect(TokenKind.pipe.isOperator());
    try std.testing.expect(TokenKind.greater.isOperator());
    try std.testing.expect(!TokenKind.word.isOperator());

    try std.testing.expect(TokenKind.dless.isRedirectOperator());
    try std.testing.expect(TokenKind.clobber.isRedirectOperator());
    try std.testing.expect(!TokenKind.pipe.isRedirectOperator());
}

test "tokens expose source lexemes through spans" {
    const source = "echo hello";
    const token: Token = .{ .kind = .word, .span = .init(5, 10) };
    try std.testing.expectEqualStrings("hello", token.lexeme(source));
}

test "syntax highlights classify command arguments redirects and comments" {
    var result = try parse(std.testing.allocator, "echo hi > out # c", .{});
    defer result.deinit();

    const highlights = try syntaxHighlights(std.testing.allocator, result);
    defer std.testing.allocator.free(highlights);

    try std.testing.expectEqual(HighlightKind.command, highlights[0].kind);
    try std.testing.expectEqual(HighlightKind.whitespace, highlights[1].kind);
    try std.testing.expectEqual(HighlightKind.argument, highlights[2].kind);
    try std.testing.expectEqual(HighlightKind.whitespace, highlights[3].kind);
    try std.testing.expectEqual(HighlightKind.redirect, highlights[4].kind);
    try std.testing.expectEqual(HighlightKind.whitespace, highlights[5].kind);
    try std.testing.expectEqual(HighlightKind.argument, highlights[6].kind);
    try std.testing.expectEqual(HighlightKind.whitespace, highlights[7].kind);
    try std.testing.expectEqual(HighlightKind.comment, highlights[8].kind);
}

test "syntax highlights include diagnostic error spans" {
    var result = try parse(std.testing.allocator, "echo | ", .{});
    defer result.deinit();

    const highlights = try syntaxHighlights(std.testing.allocator, result);
    defer std.testing.allocator.free(highlights);

    try std.testing.expectEqual(HighlightKind.diagnostic_error, highlights[highlights.len - 1].kind);
    try expectSpan(.init(5, 6), highlights[highlights.len - 1].span);
}

test "completion context finds command and argument positions" {
    var empty = try parse(std.testing.allocator, "", .{});
    defer empty.deinit();
    try std.testing.expectEqual(CompletionKind.command, completionContext(empty, 0).kind);

    var command = try parse(std.testing.allocator, "echo", .{});
    defer command.deinit();
    try std.testing.expectEqual(CompletionKind.command, completionContext(command, 2).kind);
    try std.testing.expectEqual(CompletionKind.command, completionContext(command, 4).kind);

    var argument = try parse(std.testing.allocator, "echo hi", .{});
    defer argument.deinit();
    try std.testing.expectEqual(CompletionKind.argument, completionContext(argument, 7).kind);
}

test "completion context after trailing whitespace starts an empty argument" {
    var command = try parse(std.testing.allocator, "git ", .{});
    defer command.deinit();
    const command_context = completionContext(command, 4);
    try std.testing.expectEqual(CompletionKind.argument, command_context.kind);
    try expectSpan(.init(4, 4), command_context.span);

    var subcommand = try parse(std.testing.allocator, "git commit ", .{});
    defer subcommand.deinit();
    const subcommand_context = completionContext(subcommand, 11);
    try std.testing.expectEqual(CompletionKind.argument, subcommand_context.kind);
    try expectSpan(.init(11, 11), subcommand_context.span);
}

test "completion context finds redirect targets and pipeline commands" {
    var redirect = try parse(std.testing.allocator, "echo > ", .{});
    defer redirect.deinit();
    try std.testing.expectEqual(CompletionKind.redirect_target, completionContext(redirect, 7).kind);

    var pipeline = try parse(std.testing.allocator, "echo | ", .{});
    defer pipeline.deinit();
    try std.testing.expectEqual(CompletionKind.command, completionContext(pipeline, 7).kind);
}

test "completion context works inside incomplete compound commands" {
    var brace_command = try parse(std.testing.allocator, "{ ec", .{});
    defer brace_command.deinit();
    try std.testing.expect(brace_command.incomplete);
    try std.testing.expectEqual(CompletionKind.command, completionContext(brace_command, 4).kind);

    var subshell_pipeline = try parse(std.testing.allocator, "( echo | ", .{});
    defer subshell_pipeline.deinit();
    try std.testing.expect(subshell_pipeline.incomplete);
    try std.testing.expectEqual(CompletionKind.command, completionContext(subshell_pipeline, 9).kind);

    var brace_argument = try parse(std.testing.allocator, "{ echo ar", .{});
    defer brace_argument.deinit();
    try std.testing.expect(brace_argument.incomplete);
    try std.testing.expectEqual(CompletionKind.argument, completionContext(brace_argument, 9).kind);
}

test "completion context finds assignments and quoted strings" {
    var assignment = try parse(std.testing.allocator, "FOO=bar echo", .{});
    defer assignment.deinit();
    try std.testing.expectEqual(CompletionKind.assignment_name, completionContext(assignment, 2).kind);
    try std.testing.expectEqual(CompletionKind.assignment_value, completionContext(assignment, 5).kind);

    var quoted = try parse(std.testing.allocator, "echo 'unterminated", .{});
    defer quoted.deinit();
    try std.testing.expectEqual(CompletionKind.quoted_string, completionContext(quoted, 10).kind);
}

test "completion context finds parameter expansion prefixes" {
    var empty = try parse(std.testing.allocator, "echo $", .{ .mode = .interactive, .cursor = "echo $".len });
    defer empty.deinit();
    const empty_context = completionContext(empty, "echo $".len);
    try std.testing.expectEqual(CompletionKind.parameter, empty_context.kind);
    try std.testing.expectEqual(@as(usize, "echo $".len), empty_context.span.start);
    try std.testing.expectEqual(@as(usize, "echo $".len), empty_context.span.end);

    var prefixed = try parse(std.testing.allocator, "echo $PA", .{ .mode = .interactive, .cursor = "echo $PA".len });
    defer prefixed.deinit();
    const prefixed_context = completionContext(prefixed, "echo $PA".len);
    try std.testing.expectEqual(CompletionKind.parameter, prefixed_context.kind);
    try std.testing.expectEqual(@as(usize, "echo $".len), prefixed_context.span.start);
    try std.testing.expectEqual(@as(usize, "echo $PA".len), prefixed_context.span.end);

    var quoted = try parse(std.testing.allocator, "echo \"$PA", .{ .mode = .interactive, .cursor = "echo \"$PA".len });
    defer quoted.deinit();
    const quoted_context = completionContext(quoted, "echo \"$PA".len);
    try std.testing.expectEqual(CompletionKind.parameter, quoted_context.kind);
    try std.testing.expectEqual(@as(usize, "echo \"$".len), quoted_context.span.start);
    try std.testing.expectEqual(@as(usize, "echo \"$PA".len), quoted_context.span.end);

    var single_quoted = try parse(std.testing.allocator, "echo '$PA", .{ .mode = .interactive, .cursor = "echo '$PA".len });
    defer single_quoted.deinit();
    try std.testing.expect(completionContext(single_quoted, "echo '$PA".len).kind != .parameter);

    var escaped = try parse(std.testing.allocator, "echo \\$PA", .{ .mode = .interactive, .cursor = "echo \\$PA".len });
    defer escaped.deinit();
    try std.testing.expect(completionContext(escaped, "echo \\$PA".len).kind != .parameter);
}

test "parser builds a simple command node for a command word" {
    try expectParse("echo", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .eof, .span = .empty(4) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 4), .token_start = 0, .token_end = 2 },
            .{ .kind = .command_word, .span = .init(0, 4), .token_start = 0, .token_end = 1, .child_start = 0, .child_end = 1 },
            .{ .kind = .simple_command, .span = .init(0, 4), .token_start = 0, .token_end = 1 },
        },
    });
}

test "parser classifies assignment words, command word, and arguments" {
    try expectParse("FOO=bar echo hi", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 7) },
            .{ .kind = .whitespace, .span = .init(7, 8) },
            .{ .kind = .word, .span = .init(8, 12) },
            .{ .kind = .whitespace, .span = .init(12, 13) },
            .{ .kind = .word, .span = .init(13, 15) },
            .{ .kind = .eof, .span = .empty(15) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 15), .token_start = 0, .token_end = 6 },
            .{ .kind = .assignment_word, .span = .init(0, 7), .token_start = 0, .token_end = 1, .child_start = 0, .child_end = 1 },
            .{ .kind = .command_word, .span = .init(8, 12), .token_start = 2, .token_end = 3, .child_start = 1, .child_end = 2 },
            .{ .kind = .word, .span = .init(13, 15), .token_start = 4, .token_end = 5, .child_start = 2, .child_end = 3 },
            .{ .kind = .simple_command, .span = .init(0, 15), .token_start = 0, .token_end = 5 },
        },
    });
}

test "parser gates indexed array assignment words behind Bash mode" {
    try expectParse("arr[0]=zero echo", .{
        .options = .{ .features = compat.Features.bash() },
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 11) },
            .{ .kind = .whitespace, .span = .init(11, 12) },
            .{ .kind = .word, .span = .init(12, 16) },
            .{ .kind = .eof, .span = .empty(16) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 16) },
            .{ .kind = .assignment_word, .span = .init(0, 11) },
            .{ .kind = .command_word, .span = .init(12, 16) },
            .{ .kind = .simple_command, .span = .init(0, 16) },
        },
    });

    try expectParse("arr[i+1]=zero echo", .{
        .options = .{ .features = compat.Features.bash() },
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 13) },
            .{ .kind = .whitespace, .span = .init(13, 14) },
            .{ .kind = .word, .span = .init(14, 18) },
            .{ .kind = .eof, .span = .empty(18) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 18) },
            .{ .kind = .assignment_word, .span = .init(0, 13) },
            .{ .kind = .command_word, .span = .init(14, 18) },
            .{ .kind = .simple_command, .span = .init(0, 18) },
        },
    });

    try expectParse("arr[ i + 1 ]=zero echo", .{
        .options = .{ .features = compat.Features.bash() },
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 6) },
            .{ .kind = .whitespace, .span = .init(6, 7) },
            .{ .kind = .word, .span = .init(7, 8) },
            .{ .kind = .whitespace, .span = .init(8, 9) },
            .{ .kind = .word, .span = .init(9, 10) },
            .{ .kind = .whitespace, .span = .init(10, 11) },
            .{ .kind = .word, .span = .init(11, 17) },
            .{ .kind = .whitespace, .span = .init(17, 18) },
            .{ .kind = .word, .span = .init(18, 22) },
            .{ .kind = .eof, .span = .empty(22) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 22) },
            .{ .kind = .assignment_word, .span = .init(0, 17), .token_start = 0, .token_end = 9 },
            .{ .kind = .command_word, .span = .init(18, 22), .token_start = 10, .token_end = 11 },
            .{ .kind = .simple_command, .span = .init(0, 22) },
        },
    });

    try expectParse("arr[0]=zero echo", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 11) },
            .{ .kind = .whitespace, .span = .init(11, 12) },
            .{ .kind = .word, .span = .init(12, 16) },
            .{ .kind = .eof, .span = .empty(16) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 16) },
            .{ .kind = .command_word, .span = .init(0, 11) },
            .{ .kind = .word, .span = .init(12, 16) },
            .{ .kind = .simple_command, .span = .init(0, 16) },
        },
    });

    try expectParse("arr[ i + 1 ]=zero echo", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 6) },
            .{ .kind = .whitespace, .span = .init(6, 7) },
            .{ .kind = .word, .span = .init(7, 8) },
            .{ .kind = .whitespace, .span = .init(8, 9) },
            .{ .kind = .word, .span = .init(9, 10) },
            .{ .kind = .whitespace, .span = .init(10, 11) },
            .{ .kind = .word, .span = .init(11, 17) },
            .{ .kind = .whitespace, .span = .init(17, 18) },
            .{ .kind = .word, .span = .init(18, 22) },
            .{ .kind = .eof, .span = .empty(22) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 22) },
            .{ .kind = .command_word, .span = .init(0, 4), .token_start = 0, .token_end = 1 },
            .{ .kind = .word, .span = .init(5, 6), .token_start = 2, .token_end = 3 },
            .{ .kind = .word, .span = .init(7, 8), .token_start = 4, .token_end = 5 },
            .{ .kind = .word, .span = .init(9, 10), .token_start = 6, .token_end = 7 },
            .{ .kind = .word, .span = .init(11, 17), .token_start = 8, .token_end = 9 },
            .{ .kind = .word, .span = .init(18, 22), .token_start = 10, .token_end = 11 },
            .{ .kind = .simple_command, .span = .init(0, 22) },
        },
    });
}

test "parser builds redirection nodes with optional io number" {
    try expectParse("2>out echo", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 1) },
            .{ .kind = .greater, .span = .init(1, 2) },
            .{ .kind = .word, .span = .init(2, 5) },
            .{ .kind = .whitespace, .span = .init(5, 6) },
            .{ .kind = .word, .span = .init(6, 10) },
            .{ .kind = .eof, .span = .empty(10) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 10), .token_start = 0, .token_end = 6 },
            .{ .kind = .io_number, .span = .init(0, 1), .token_start = 0, .token_end = 1, .child_start = 0, .child_end = 1 },
            .{ .kind = .word, .span = .init(2, 5), .token_start = 2, .token_end = 3, .child_start = 1, .child_end = 2 },
            .{ .kind = .redirection, .span = .init(0, 5), .token_start = 0, .token_end = 3 },
            .{ .kind = .command_word, .span = .init(6, 10), .token_start = 4, .token_end = 5 },
            .{ .kind = .simple_command, .span = .init(0, 10), .token_start = 0, .token_end = 5 },
        },
    });
}

test "parser builds POSIX subshell nodes" {
    var result = try parse(std.testing.allocator, "( FOO=bar; echo $FOO ) > out", .{});
    defer result.deinit();

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .subshell) {
            found = true;
            try expectSpan(.init(0, 28), node.span);
        }
    }
    try std.testing.expect(found);
}

test "parser reports incomplete POSIX subshells" {
    var result = try parse(std.testing.allocator, "( echo hi", .{});
    defer result.deinit();

    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.incomplete_input, result.diagnostics[0].kind);
    try expectSpan(.init(0, 9), result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing ) to close subshell", result.diagnostics[0].message);
}

test "parser builds POSIX brace group nodes" {
    var result = try parse(std.testing.allocator, "{ FOO=bar; echo $FOO; } > out", .{});
    defer result.deinit();

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .brace_group) {
            found = true;
            try expectSpan(.init(0, 29), node.span);
        }
    }
    try std.testing.expect(found);
}

test "parser nests list bodies inside subshell and brace group CST nodes" {
    var result = try parse(std.testing.allocator, "( echo sub; ( echo nested ) ); { echo group; }", .{});
    defer result.deinit();

    var subshell_with_list = false;
    var brace_with_list = false;
    var nested_subshells: usize = 0;
    for (result.nodes) |node| {
        if (node.kind == .subshell) {
            nested_subshells += 1;
            for (result.nodeChildren(node)) |child| switch (child) {
                .node => |node_id| {
                    if (result.nodes[node_id.index()].kind == .list) subshell_with_list = true;
                },
                .token => {},
            };
        }
        if (node.kind == .brace_group) {
            for (result.nodeChildren(node)) |child| switch (child) {
                .node => |node_id| {
                    if (result.nodes[node_id.index()].kind == .list) brace_with_list = true;
                },
                .token => {},
            };
        }
    }

    try std.testing.expect(nested_subshells >= 2);
    try std.testing.expect(subshell_with_list);
    try std.testing.expect(brace_with_list);
}

test "parser reports incomplete POSIX brace groups" {
    var result = try parse(std.testing.allocator, "{ echo hi", .{});
    defer result.deinit();

    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.incomplete_input, result.diagnostics[0].kind);
    try expectSpan(.init(0, 9), result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing } to close brace group", result.diagnostics[0].message);
}

test "parser builds POSIX function definition nodes" {
    var result = try parse(std.testing.allocator, "greet() { echo hi; }", .{});
    defer result.deinit();

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .function_definition) {
            found = true;
            try expectSpan(.init(0, 20), node.span);
        }
    }
    try std.testing.expect(found);
}

test "parser keeps nested brace groups inside POSIX function definitions" {
    var result = try parse(std.testing.allocator, "f() { { echo inner; }; echo outer; }; f", .{});
    defer result.deinit();

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .function_definition) {
            found = true;
            try expectSpan(.init(0, 36), node.span);
        }
    }
    try std.testing.expect(found);
}

test "parser accepts compound commands as POSIX function bodies" {
    var result = try parse(std.testing.allocator, "f() ( echo hi ); g() if true; then echo yes; fi; h() for i in 1 2; do echo $i; done", .{});
    defer result.deinit();

    var definitions: usize = 0;
    var saw_subshell_body = false;
    var saw_if_body = false;
    var saw_for_body = false;
    for (result.nodes) |node| {
        if (node.kind != .function_definition) continue;
        definitions += 1;
        for (result.nodeChildren(node)) |child| switch (child) {
            .node => |node_id| switch (result.nodes[node_id.index()].kind) {
                .subshell => saw_subshell_body = true,
                .if_command => saw_if_body = true,
                .for_command => saw_for_body = true,
                else => {},
            },
            .token => {},
        };
    }

    try std.testing.expectEqual(@as(usize, 3), definitions);
    try std.testing.expect(saw_subshell_body);
    try std.testing.expect(saw_if_body);
    try std.testing.expect(saw_for_body);
}

test "parser reports incomplete POSIX function definitions" {
    var result = try parse(std.testing.allocator, "greet() { echo hi", .{});
    defer result.deinit();

    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.incomplete_input, result.diagnostics[0].kind);
    try expectSpan(.init(0, 17), result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing } to close function definition", result.diagnostics[0].message);
}

test "parser builds POSIX case command nodes" {
    var result = try parse(std.testing.allocator, "case foo in f*) echo yes ;; *) echo no ;; esac", .{});
    defer result.deinit();

    var found = false;
    var item_count: usize = 0;
    for (result.nodes) |node| {
        if (node.kind == .case_command) {
            found = true;
            try expectSpan(.init(0, 46), node.span);
            try std.testing.expectEqual(@as(usize, 2), countChildNodesOfKind(result, node, .case_item));
        }
        if (node.kind == .case_item) {
            if (item_count == 0) try expectSpan(.init(12, 27), node.span);
            if (item_count == 1) try expectSpan(.init(28, 41), node.span);
            item_count += 1;
        }
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 2), item_count);
}

test "parser accepts POSIX case edge items" {
    var result = try parse(std.testing.allocator, "case b in (a|b) ;; c) echo c esac", .{});
    defer result.deinit();

    var saw_case = false;
    var item_count: usize = 0;
    for (result.nodes) |node| {
        if (node.kind == .case_command) saw_case = true;
        if (node.kind == .case_item) item_count += 1;
    }
    try std.testing.expect(saw_case);
    try std.testing.expectEqual(@as(usize, 2), item_count);
}

test "parser keeps nested POSIX case statements inside case item bodies" {
    var result = try parse(std.testing.allocator, "case x in x) case y in y) echo nested ;; esac ;; esac", .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(!result.incomplete);
    var item_count: usize = 0;
    for (result.nodes) |node| {
        if (node.kind == .case_item) {
            item_count += 1;
            try expectSpan(.init(10, 48), node.span);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), item_count);
}

test "parser accepts in as POSIX case subject word" {
    var result = try parse(std.testing.allocator, "case in in in) echo ok ;; *) echo bad ;; esac", .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(!result.incomplete);
    var item_count: usize = 0;
    for (result.nodes) |node| {
        if (node.kind == .case_item) item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), item_count);
}

test "parser accepts esac as POSIX case subject word" {
    var result = try parse(std.testing.allocator, "case esac in esac) echo ok ;; *) echo bad ;; esac", .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(!result.incomplete);
    var item_count: usize = 0;
    for (result.nodes) |node| {
        if (node.kind == .case_item) item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), item_count);
}

test "parser reports missing POSIX case item terminator" {
    var result = try parse(std.testing.allocator, "case foo in f* echo yes ;; esac", .{});
    defer result.deinit();

    try std.testing.expect(result.diagnostics.len >= 1);
    try std.testing.expectEqualStrings("missing ) in case item", result.diagnostics[0].message);
}

test "parser reports incomplete POSIX case commands" {
    var result = try parse(std.testing.allocator, "case foo in f*) echo yes", .{});
    defer result.deinit();

    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.incomplete_input, result.diagnostics[0].kind);
    try expectSpan(.init(0, 24), result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing esac to close case command", result.diagnostics[0].message);
}

test "parser builds Bash conditional command nodes in Bash mode" {
    var bash_result = try parse(std.testing.allocator, "[[ -n foo ]]", .{ .features = compat.Features.bash() });
    defer bash_result.deinit();

    var found = false;
    for (bash_result.nodes) |node| {
        if (node.kind == .bash_test_command) {
            found = true;
            try expectSpan(.init(0, 12), node.span);
        }
    }
    try std.testing.expect(found);

    var posix_result = try parse(std.testing.allocator, "[[ -n foo ]]", .{});
    defer posix_result.deinit();
    for (posix_result.nodes) |node| {
        try std.testing.expect(node.kind != .bash_test_command);
    }
}

test "parser reports incomplete Bash conditional commands" {
    var result = try parse(std.testing.allocator, "[[ -n foo", .{ .features = compat.Features.bash() });
    defer result.deinit();

    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.incomplete_input, result.diagnostics[0].kind);
    try expectSpan(.init(0, 9), result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing ]] to close Bash conditional command", result.diagnostics[0].message);
}

test "parser builds POSIX for command nodes" {
    var result = try parse(std.testing.allocator, "for x in a b; do echo $x; done", .{});
    defer result.deinit();

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .for_command) {
            found = true;
            try expectSpan(.init(0, 30), node.span);
            try std.testing.expectEqual(@as(usize, 0), node.token_start);
            try std.testing.expectEqual(@as(usize, 1), countChildNodesOfKind(result, node, .list));
        }
    }
    try std.testing.expect(found);
}

test "parser reports incomplete POSIX for commands" {
    var result = try parse(std.testing.allocator, "for x in a b; do echo $x", .{});
    defer result.deinit();

    try std.testing.expect(result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.incomplete_input, result.diagnostics[0].kind);
    try expectSpan(.init(0, 24), result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing done to close for command", result.diagnostics[0].message);
}

test "parser reports missing POSIX for loop variables" {
    var missing_result = try parse(std.testing.allocator, "for in a; do echo $a; done", .{});
    defer missing_result.deinit();

    try std.testing.expect(missing_result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), missing_result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.parse_error, missing_result.diagnostics[0].kind);
    try expectSpan(.init(0, 26), missing_result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing loop variable in for command", missing_result.diagnostics[0].message);

    var invalid_result = try parse(std.testing.allocator, "for 1 in a; do echo bad; done", .{});
    defer invalid_result.deinit();

    try std.testing.expect(invalid_result.incomplete);
    try std.testing.expectEqual(@as(usize, 1), invalid_result.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.parse_error, invalid_result.diagnostics[0].kind);
    try expectSpan(.init(0, 29), invalid_result.diagnostics[0].span);
    try std.testing.expectEqualStrings("missing loop variable in for command", invalid_result.diagnostics[0].message);
}

test "parser builds POSIX while and until command nodes" {
    var while_result = try parse(std.testing.allocator, "while false; do echo no; done", .{});
    defer while_result.deinit();
    var while_found = false;
    for (while_result.nodes) |node| {
        if (node.kind == .loop_command) {
            while_found = true;
            try expectSpan(.init(0, 29), node.span);
            try std.testing.expectEqual(@as(usize, 2), countChildNodesOfKind(while_result, node, .list));
        }
    }
    try std.testing.expect(while_found);

    var until_result = try parse(std.testing.allocator, "until true; do echo no; done", .{});
    defer until_result.deinit();
    var until_found = false;
    for (until_result.nodes) |node| {
        if (node.kind == .loop_command) {
            until_found = true;
            try expectSpan(.init(0, 28), node.span);
            try std.testing.expectEqual(@as(usize, 2), countChildNodesOfKind(until_result, node, .list));
        }
    }
    try std.testing.expect(until_found);
}

test "parser reports incomplete POSIX loops" {
    try expectParse("while false; do echo no", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 5) },
            .{ .kind = .whitespace, .span = .init(5, 6) },
            .{ .kind = .word, .span = .init(6, 11) },
            .{ .kind = .semicolon, .span = .init(11, 12) },
            .{ .kind = .whitespace, .span = .init(12, 13) },
            .{ .kind = .word, .span = .init(13, 15) },
            .{ .kind = .whitespace, .span = .init(15, 16) },
            .{ .kind = .word, .span = .init(16, 20) },
            .{ .kind = .whitespace, .span = .init(20, 21) },
            .{ .kind = .word, .span = .init(21, 23) },
            .{ .kind = .eof, .span = .empty(23) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 23) }},
        .diagnostics = &.{.{
            .kind = .incomplete_input,
            .span = .init(0, 23),
            .message = "missing done to close while command",
        }},
        .incomplete = true,
    });
}

test "parser builds POSIX if command nodes" {
    var result = try parse(std.testing.allocator, "if true; then echo ok; else echo no; fi", .{});
    defer result.deinit();

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .if_command) {
            found = true;
            try expectSpan(.init(0, 39), node.span);
            try std.testing.expectEqual(@as(usize, 3), countChildNodesOfKind(result, node, .list));
        }
    }
    try std.testing.expect(found);
}

test "parser reports incomplete POSIX if commands" {
    try expectParse("if true; then echo ok", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 2) },
            .{ .kind = .whitespace, .span = .init(2, 3) },
            .{ .kind = .word, .span = .init(3, 7) },
            .{ .kind = .semicolon, .span = .init(7, 8) },
            .{ .kind = .whitespace, .span = .init(8, 9) },
            .{ .kind = .word, .span = .init(9, 13) },
            .{ .kind = .whitespace, .span = .init(13, 14) },
            .{ .kind = .word, .span = .init(14, 18) },
            .{ .kind = .whitespace, .span = .init(18, 19) },
            .{ .kind = .word, .span = .init(19, 21) },
            .{ .kind = .eof, .span = .empty(21) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 21) }},
        .diagnostics = &.{.{
            .kind = .incomplete_input,
            .span = .init(0, 21),
            .message = "missing fi to close if command",
        }},
        .incomplete = true,
    });
}

test "parser builds lists and pipelines around simple commands" {
    try expectParse("echo hi | grep h && echo ok", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 7) },
            .{ .kind = .whitespace, .span = .init(7, 8) },
            .{ .kind = .pipe, .span = .init(8, 9) },
            .{ .kind = .whitespace, .span = .init(9, 10) },
            .{ .kind = .word, .span = .init(10, 14) },
            .{ .kind = .whitespace, .span = .init(14, 15) },
            .{ .kind = .word, .span = .init(15, 16) },
            .{ .kind = .whitespace, .span = .init(16, 17) },
            .{ .kind = .and_if, .span = .init(17, 19) },
            .{ .kind = .whitespace, .span = .init(19, 20) },
            .{ .kind = .word, .span = .init(20, 24) },
            .{ .kind = .whitespace, .span = .init(24, 25) },
            .{ .kind = .word, .span = .init(25, 27) },
            .{ .kind = .eof, .span = .empty(27) },
        },
        .nodes = &.{
            .{ .kind = .root, .span = .init(0, 27), .token_start = 0, .token_end = 16, .child_start = 26, .child_end = 28 },
            .{ .kind = .command_word, .span = .init(0, 4), .token_start = 0, .token_end = 1, .child_start = 0, .child_end = 1 },
            .{ .kind = .word, .span = .init(5, 7), .token_start = 2, .token_end = 3, .child_start = 1, .child_end = 2 },
            .{ .kind = .simple_command, .span = .init(0, 8), .token_start = 0, .token_end = 4, .child_start = 2, .child_end = 6 },
            .{ .kind = .command_word, .span = .init(10, 14), .token_start = 6, .token_end = 7, .child_start = 6, .child_end = 7 },
            .{ .kind = .word, .span = .init(15, 16), .token_start = 8, .token_end = 9, .child_start = 7, .child_end = 8 },
            .{ .kind = .simple_command, .span = .init(10, 17), .token_start = 6, .token_end = 10, .child_start = 8, .child_end = 12 },
            .{ .kind = .pipeline, .span = .init(0, 17), .token_start = 0, .token_end = 10, .child_start = 12, .child_end = 16 },
            .{ .kind = .command_word, .span = .init(20, 24), .token_start = 12, .token_end = 13, .child_start = 16, .child_end = 17 },
            .{ .kind = .word, .span = .init(25, 27), .token_start = 14, .token_end = 15, .child_start = 17, .child_end = 18 },
            .{ .kind = .simple_command, .span = .init(20, 27), .token_start = 12, .token_end = 15, .child_start = 18, .child_end = 21 },
            .{ .kind = .pipeline, .span = .init(20, 27), .token_start = 12, .token_end = 15, .child_start = 21, .child_end = 22 },
            .{ .kind = .list, .span = .init(0, 27), .token_start = 0, .token_end = 15, .child_start = 22, .child_end = 26 },
        },
        .nodes_exact = true,
    });
}

test "parser reports a missing redirection target" {
    try expectParse("echo >", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .greater, .span = .init(5, 6) },
            .{ .kind = .eof, .span = .empty(6) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 6) }},
        .diagnostics = &.{.{
            .kind = .parse_error,
            .span = .init(5, 6),
            .message = "missing redirection target",
        }},
        .incomplete = true,
    });
}

test "parser recovers from missing pipeline rhs" {
    try expectParse("echo | ", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .pipe, .span = .init(5, 6) },
            .{ .kind = .whitespace, .span = .init(6, 7) },
            .{ .kind = .eof, .span = .empty(7) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 7) }},
        .diagnostics = &.{.{
            .kind = .parse_error,
            .span = .init(5, 6),
            .message = "missing command after pipeline operator",
        }},
        .incomplete = true,
    });
}

test "parser recovers from missing redirection target with trailing whitespace" {
    try expectParse("echo > ", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .greater, .span = .init(5, 6) },
            .{ .kind = .whitespace, .span = .init(6, 7) },
            .{ .kind = .eof, .span = .empty(7) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 7) }},
        .diagnostics = &.{.{
            .kind = .parse_error,
            .span = .init(5, 6),
            .message = "missing redirection target",
        }},
        .incomplete = true,
    });
}

test "lexer tokenizes words, trivia, newlines, and eof" {
    try expectParse("echo hello\n", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 10) },
            .{ .kind = .newline, .span = .init(10, 11) },
            .{ .kind = .eof, .span = .empty(11) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 11) }},
    });
}

test "lexer tokenizes operators and redirections with max munch" {
    try expectParse("2>>log | grep x && echo ok; cat <<-EOF", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 1) },
            .{ .kind = .dgreat, .span = .init(1, 3) },
            .{ .kind = .word, .span = .init(3, 6) },
            .{ .kind = .whitespace, .span = .init(6, 7) },
            .{ .kind = .pipe, .span = .init(7, 8) },
            .{ .kind = .whitespace, .span = .init(8, 9) },
            .{ .kind = .word, .span = .init(9, 13) },
            .{ .kind = .whitespace, .span = .init(13, 14) },
            .{ .kind = .word, .span = .init(14, 15) },
            .{ .kind = .whitespace, .span = .init(15, 16) },
            .{ .kind = .and_if, .span = .init(16, 18) },
            .{ .kind = .whitespace, .span = .init(18, 19) },
            .{ .kind = .word, .span = .init(19, 23) },
            .{ .kind = .whitespace, .span = .init(23, 24) },
            .{ .kind = .word, .span = .init(24, 26) },
            .{ .kind = .semicolon, .span = .init(26, 27) },
            .{ .kind = .whitespace, .span = .init(27, 28) },
            .{ .kind = .word, .span = .init(28, 31) },
            .{ .kind = .whitespace, .span = .init(31, 32) },
            .{ .kind = .dless_dash, .span = .init(32, 35) },
            .{ .kind = .word, .span = .init(35, 38) },
            .{ .kind = .eof, .span = .empty(38) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 38) }},
        .diagnostics = &.{.{ .kind = .incomplete_input, .span = .empty(38), .message = "missing here-doc delimiter" }},
        .incomplete = true,
    });
}

test "parser represents here-doc bodies as CST nodes" {
    const source = "cat <<EOF\nhello\nEOF\necho after";
    var result = try parse(std.testing.allocator, source, .{});
    defer result.deinit();

    var found_body = false;
    for (result.nodes) |node| {
        if (node.kind != .here_doc_body) continue;
        found_body = true;
        try expectSpan(.init(10, 20), node.span);
    }
    try std.testing.expect(found_body);
    var command_count: usize = 0;
    for (result.nodes) |node| {
        if (node.kind == .simple_command) command_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), command_count);
}

test "parser orders multiple here-doc bodies on a command line" {
    const source = "cat <<A <<B\na\nA\nb\nB\n";
    var result = try parse(std.testing.allocator, source, .{});
    defer result.deinit();

    var spans: [2]Span = undefined;
    var count: usize = 0;
    for (result.nodes) |node| {
        if (node.kind != .here_doc_body) continue;
        spans[count] = node.span;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try expectSpan(.init(12, 16), spans[0]);
    try expectSpan(.init(16, 20), spans[1]);
}

test "parser represents command substitutions as nested word syntax" {
    var result = try parse(std.testing.allocator, "echo before-$(echo hi)-after", .{});
    defer result.deinit();

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .command_substitution) {
            found = true;
            try expectSpan(.init(12, 22), node.span);
            try std.testing.expectEqual(@as(usize, 2), node.token_start);
            try std.testing.expectEqual(@as(usize, 3), node.token_end);
        }
    }
    try std.testing.expect(found);
}

test "parser nests command substitution CST nodes" {
    var result = try parse(std.testing.allocator, "echo $(echo $(echo hi))", .{});
    defer result.deinit();

    var outer_id: ?NodeId = null;
    var inner_id: ?NodeId = null;
    for (result.nodes, 0..) |node, index| {
        if (node.kind != .command_substitution) continue;
        if (node.span.start == 5) {
            outer_id = .init(index);
            try expectSpan(.init(5, 23), node.span);
        } else if (node.span.start == 12) {
            inner_id = .init(index);
            try expectSpan(.init(12, 22), node.span);
        }
    }
    const outer = result.nodes[outer_id.?.index()];
    const outer_children = result.nodeChildren(outer);
    try std.testing.expectEqual(@as(usize, 1), outer_children.len);
    try std.testing.expectEqual(inner_id.?, outer_children[0].node);
}

test "parser scans case pattern parens inside command substitution" {
    const script = "echo \"$(case x in x) echo case-in-subst ;; esac)\"";
    var result = try parse(std.testing.allocator, script, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(TokenKind.word, result.tokens[2].kind);
    try expectSpan(.init(5, 49), result.tokens[2].span);

    var found = false;
    for (result.nodes) |node| {
        if (node.kind == .command_substitution) {
            found = true;
            try expectSpan(.init(6, 48), node.span);
        }
    }
    try std.testing.expect(found);

    var optional = try parse(std.testing.allocator, "echo \"$(case x in (x) echo optional ;; esac)\"", .{});
    defer optional.deinit();
    try std.testing.expectEqual(@as(usize, 0), optional.diagnostics.len);
}

test "shared shell substitution scanner recognizes recursive spans" {
    const parameter = "${v:-$(printf '}'):$((1 + ${n:-2}))}";
    const parameter_scan = try shellSubstitutionAt(std.testing.allocator, parameter, parameter.len, 0);
    const parameter_substitution = switch (parameter_scan) {
        .complete => |substitution| substitution,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(ShellSubstitutionKind.parameter, parameter_substitution.kind);
    try expectSpan(.init(0, parameter.len), parameter_substitution.span);
    try std.testing.expectEqualStrings("v:-$(printf '}'):$((1 + ${n:-2}))", parameter_substitution.value_span.slice(parameter));

    const arithmetic = "$((1 + $(printf 2)))";
    const arithmetic_scan = try shellSubstitutionAt(std.testing.allocator, arithmetic, arithmetic.len, 0);
    const arithmetic_substitution = switch (arithmetic_scan) {
        .complete => |substitution| substitution,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(ShellSubstitutionKind.arithmetic, arithmetic_substitution.kind);
    try expectSpan(.init(0, arithmetic.len), arithmetic_substitution.span);
    try std.testing.expectEqualStrings("1 + $(printf 2)", arithmetic_substitution.value_span.slice(arithmetic));

    const backquote = "`printf \\`literal`";
    const backquote_scan = try shellSubstitutionAt(std.testing.allocator, backquote, backquote.len, 0);
    const backquote_substitution = switch (backquote_scan) {
        .complete => |substitution| substitution,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(ShellSubstitutionKind.command_substitution, backquote_substitution.kind);
    try expectSpan(.init(0, backquote.len), backquote_substitution.span);
    try std.testing.expectEqualStrings("printf \\`literal", backquote_substitution.value_span.slice(backquote));
}

test "lexer command substitution handles quoted parens arithmetic and incomplete input" {
    try expectParse("echo $(printf \"(\")", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 18) },
            .{ .kind = .eof, .span = .empty(18) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 18) }},
    });

    try expectParse("echo $(echo $((1 + 2)))", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 23) },
            .{ .kind = .eof, .span = .empty(23) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 23) }},
    });

    try expectParse("echo $(echo hi", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 14) },
            .{ .kind = .eof, .span = .empty(14) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 14) }},
        .diagnostics = &.{.{
            .kind = .incomplete_input,
            .span = .init(5, 14),
            .message = "unterminated command substitution",
        }},
        .incomplete = true,
    });
}

test "lexer preserves command substitution as part of a word" {
    try expectParse("echo $(echo hi)", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 15) },
            .{ .kind = .eof, .span = .empty(15) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 15) }},
    });
}

test "lexer preserves arithmetic expansion as part of a word" {
    try expectParse("echo $((1 + 2))", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 15) },
            .{ .kind = .eof, .span = .empty(15) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 15) }},
    });
}

test "arithmetic expansion scanner honors arithmetic backslash escapes" {
    const escaped_parameter = "echo $((1 + \\${x:-2)); echo after";
    const escaped_parameter_start = std.mem.indexOf(u8, escaped_parameter, "$((").?;
    const escaped_parameter_end = std.mem.indexOf(u8, escaped_parameter, ")); ").? + 2;
    try std.testing.expectEqual(
        @as(?usize, escaped_parameter_end),
        try arithmeticExpansionEnd(std.testing.allocator, escaped_parameter, escaped_parameter.len, escaped_parameter_start),
    );

    const escaped_backquote = "echo $((1 + \\`printf 2` + 3)); echo after";
    const escaped_backquote_start = std.mem.indexOf(u8, escaped_backquote, "$((").?;
    try std.testing.expectEqual(
        @as(?usize, null),
        try arithmeticExpansionEnd(std.testing.allocator, escaped_backquote, escaped_backquote.len, escaped_backquote_start),
    );

    var escaped_backquote_parse = try parse(std.testing.allocator, escaped_backquote, .{});
    defer escaped_backquote_parse.deinit();
    try std.testing.expect(escaped_backquote_parse.incomplete);
    try std.testing.expectEqual(@as(usize, 1), escaped_backquote_parse.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.incomplete_input, escaped_backquote_parse.diagnostics[0].kind);
    try expectSpan(
        .init(std.mem.findScalarLast(u8, escaped_backquote, '`').?, escaped_backquote.len),
        escaped_backquote_parse.diagnostics[0].span,
    );
    try std.testing.expectEqualStrings("unterminated backquote command substitution", escaped_backquote_parse.diagnostics[0].message);

    const literal_backquote = "echo $((1 + \\`printf 2)); echo after";
    const literal_backquote_start = std.mem.indexOf(u8, literal_backquote, "$((").?;
    const literal_backquote_end = std.mem.indexOf(u8, literal_backquote, ")); ").? + 2;
    try std.testing.expectEqual(
        @as(?usize, literal_backquote_end),
        try arithmeticExpansionEnd(std.testing.allocator, literal_backquote, literal_backquote.len, literal_backquote_start),
    );
}

test "lexer preserves quoted words as one word token" {
    try expectParse("echo 'hello world' \"again\"", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 18) },
            .{ .kind = .whitespace, .span = .init(18, 19) },
            .{ .kind = .word, .span = .init(19, 26) },
            .{ .kind = .eof, .span = .empty(26) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 26) }},
    });
}

test "lexer tokenizes comments" {
    try expectParse("echo # hello\nnext", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .comment, .span = .init(5, 12) },
            .{ .kind = .newline, .span = .init(12, 13) },
            .{ .kind = .word, .span = .init(13, 17) },
            .{ .kind = .eof, .span = .empty(17) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 17) }},
    });
}

test "lexer reports incomplete quoted input" {
    try expectParse("echo 'unterminated", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 18) },
            .{ .kind = .eof, .span = .empty(18) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 18) }},
        .diagnostics = &.{.{
            .kind = .incomplete_input,
            .span = .init(5, 18),
            .message = "unterminated single quote",
        }},
        .incomplete = true,
    });
}

test "parser harness checks tokens, nodes, spans, diagnostics, and incomplete flag" {
    try expectParse("", .{
        .tokens = &.{.{ .kind = .eof, .span = .empty(0) }},
        .nodes = &.{.{ .kind = .root, .span = .empty(0) }},
        .diagnostics = &.{},
        .incomplete = false,
    });
}

test "parser harness preserves source-length spans" {
    try expectParse("echo hello", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .whitespace, .span = .init(4, 5) },
            .{ .kind = .word, .span = .init(5, 10) },
            .{ .kind = .eof, .span = .empty(10) },
        },
        .nodes = &.{.{ .kind = .root, .span = .init(0, 10) }},
    });
}
