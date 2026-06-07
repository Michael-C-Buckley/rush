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

    pub fn len(self: Span) usize {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }
};

pub const TokenKind = enum {
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    span: Span,
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
        .span = .{ .start = source.len, .end = source.len },
    };

    const nodes = try allocator.alloc(Node, 1);
    errdefer allocator.free(nodes);
    nodes[0] = .{
        .kind = .root,
        .span = .{ .start = 0, .end = source.len },
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
