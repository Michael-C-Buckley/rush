//! Parser surface and test harness.
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

pub const NodeKind = enum {
    root,
};

pub const Node = struct {
    kind: NodeKind,
    span: Span,
};

pub const DiagnosticKind = enum {
    parse_error,
    incomplete_input,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    span: Span,
    message: []const u8,
};

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
    diagnostics: []Diagnostic,
    incomplete: bool,

    pub fn deinit(self: *ParseResult) void {
        self.allocator.free(self.tokens);
        self.allocator.free(self.nodes);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, options: ParseOptions) !ParseResult {
    _ = options;

    const tokens = try allocator.alloc(Token, 1);
    errdefer allocator.free(tokens);
    tokens[0] = .{
        .kind = .eof,
        .span = .empty(source.len),
    };

    const nodes = try allocator.alloc(Node, 1);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .kind = .root,
        .span = .init(0, source.len),
    };

    return .{
        .allocator = allocator,
        .source = source,
        .tokens = tokens,
        .nodes = nodes,
        .diagnostics = &.{},
        .incomplete = false,
    };
}

pub const ExpectedToken = struct {
    kind: TokenKind,
    span: Span,
};

pub const ExpectedNode = struct {
    kind: NodeKind,
    span: Span,
};

pub const ExpectedDiagnostic = struct {
    kind: DiagnosticKind,
    span: Span,
    message: []const u8,
};

pub const ParseExpectation = struct {
    options: ParseOptions = .{},
    tokens: []const ExpectedToken = &.{},
    nodes: []const ExpectedNode = &.{},
    diagnostics: []const ExpectedDiagnostic = &.{},
    incomplete: bool = false,
};

pub fn expectParse(source: []const u8, expectation: ParseExpectation) !void {
    var result = try parse(std.testing.allocator, source, expectation.options);
    defer result.deinit();

    try std.testing.expectEqual(source.ptr, result.source.ptr);
    try std.testing.expectEqual(expectation.incomplete, result.incomplete);
    try expectTokens(expectation.tokens, result.tokens);
    try expectNodes(expectation.nodes, result.nodes);
    try expectDiagnostics(expectation.diagnostics, result.diagnostics);
}

fn expectTokens(expected: []const ExpectedToken, actual: []const Token) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try expectSpan(want.span, got.span);
    }
}

fn expectNodes(expected: []const ExpectedNode, actual: []const Node) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try expectSpan(want.span, got.span);
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

test "parser harness checks tokens, nodes, spans, diagnostics, and incomplete flag" {
    try expectParse("", .{
        .tokens = &.{.{ .kind = .eof, .span = .{ .start = 0, .end = 0 } }},
        .nodes = &.{.{ .kind = .root, .span = .{ .start = 0, .end = 0 } }},
        .diagnostics = &.{},
        .incomplete = false,
    });
}

test "parser harness preserves source-length spans" {
    try expectParse("echo hello", .{
        .tokens = &.{.{ .kind = .eof, .span = .{ .start = 10, .end = 10 } }},
        .nodes = &.{.{ .kind = .root, .span = .{ .start = 0, .end = 10 } }},
    });
}
