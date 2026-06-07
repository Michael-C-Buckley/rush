//! Parser surface, lexer, and test harness.
//!
//! The real parser will grow from POSIX shell syntax toward Bash-compatible
//! extensions. This file starts by defining the test-facing shape we want to
//! preserve: source spans, tokens, concrete syntax nodes, diagnostics, and an
//! incomplete-input flag for interactive parsing.

const std = @import("std");

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
    assignment_word,
    command_word,
    word,
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
                else => self.index += 1,
            }
        }
        try self.add(.word, .init(start, self.index));
    }

    fn consumeBackslash(self: *Lexer) void {
        self.index += 1;
        if (!self.isAtEnd()) self.index += 1;
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

    fn consumeDoubleQuoted(self: *Lexer) !void {
        const start = self.index;
        self.index += 1;
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\\') {
                self.consumeBackslash();
            } else {
                self.index += 1;
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
    return isBlank(c) or c == '\n' or c == '#' or switch (c) {
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

pub fn parse(allocator: std.mem.Allocator, source: []const u8, options: ParseOptions) !ParseResult {
    _ = options;

    var lex_result = try lex(allocator, source);
    errdefer lex_result.deinit();

    const nodes = try allocator.alloc(Node, 1);
    errdefer allocator.free(nodes);

    const children = try allocator.alloc(SyntaxChild, lex_result.tokens.len);
    errdefer allocator.free(children);
    for (children, 0..) |*child, index| {
        child.* = .{ .token = .init(index) };
    }

    nodes[0] = .{
        .kind = .root,
        .span = .init(0, source.len),
        .token_start = 0,
        .token_end = lex_result.tokens.len,
        .child_start = 0,
        .child_end = children.len,
    };

    return .{
        .allocator = allocator,
        .source = source,
        .tokens = lex_result.tokens,
        .nodes = nodes,
        .children = children,
        .diagnostics = lex_result.diagnostics,
        .incomplete = lex_result.incomplete,
    };
}

pub const ExpectedToken = struct {
    kind: TokenKind,
    span: Span,
};

pub const ExpectedNode = struct {
    kind: NodeKind,
    span: Span,
    token_start: usize = 0,
    token_end: ?usize = null,
    child_start: usize = 0,
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
    try expectNodes(expectation.nodes, result.nodes, result.tokens.len, result.children.len);
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

fn expectNodes(expected: []const ExpectedNode, actual: []const Node, token_len: usize, child_len: usize) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try expectSpan(want.span, got.span);
        try std.testing.expectEqual(want.token_start, got.token_start);
        try std.testing.expectEqual(want.token_end orelse token_len, got.token_end);
        try std.testing.expectEqual(want.child_start, got.child_start);
        try std.testing.expectEqual(want.child_end orelse child_len, got.child_end);
    }
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

test "concrete syntax root covers token and child ranges" {
    try expectParse("echo", .{
        .tokens = &.{
            .{ .kind = .word, .span = .init(0, 4) },
            .{ .kind = .eof, .span = .empty(4) },
        },
        .nodes = &.{.{
            .kind = .root,
            .span = .init(0, 4),
            .token_start = 0,
            .token_end = 2,
            .child_start = 0,
            .child_end = 2,
        }},
        .children = &.{
            .{ .token = .init(0) },
            .{ .token = .init(1) },
        },
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
    });
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
