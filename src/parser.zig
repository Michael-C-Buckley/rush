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
    io_number,
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

    var parser: SyntaxParser = .{
        .allocator = allocator,
        .source = source,
        .tokens = lex_result.tokens,
    };
    errdefer parser.deinit();

    try parser.diagnostics.appendSlice(allocator, lex_result.diagnostics);
    allocator.free(lex_result.diagnostics);
    lex_result.diagnostics = &.{};

    try parser.run();

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

const SyntaxParser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    index: usize = 0,
    nodes: std.ArrayList(Node) = .empty,
    children: std.ArrayList(SyntaxChild) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    incomplete: bool = false,

    fn deinit(self: *SyntaxParser) void {
        self.nodes.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
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
            } else if (self.startsPipeline()) {
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

    fn parseList(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var list_children: std.ArrayList(SyntaxChild) = .empty;
        defer list_children.deinit(self.allocator);

        while (!self.at(.eof)) {
            if (self.startsPipeline()) {
                const pipeline = try self.parsePipeline();
                try list_children.append(self.allocator, .{ .node = pipeline });
                continue;
            }

            if (self.current().kind.isTrivia() or isListSeparator(self.current().kind)) {
                try self.appendCurrentTokenChildTo(&list_children);
                continue;
            }

            break;
        }

        const token_end = self.index;
        const child_start = self.children.items.len;
        try self.children.appendSlice(self.allocator, list_children.items);
        const span = spanForTokenRange(self.tokens, token_start, token_end);
        return self.addNode(.list, span, token_start, token_end, child_start, self.children.items.len);
    }

    fn parsePipeline(self: *SyntaxParser) !NodeId {
        const token_start = self.index;
        var pipeline_children: std.ArrayList(SyntaxChild) = .empty;
        defer pipeline_children.deinit(self.allocator);

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
                const kind: NodeKind = if (!saw_command_word and isAssignmentWord(self.current().lexeme(self.source)))
                    .assignment_word
                else if (!saw_command_word) blk: {
                    saw_command_word = true;
                    break :blk .command_word;
                } else .word;
                const word = try self.addLeafNode(kind, self.index);
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
        const operator_span = self.current().span;
        try self.appendCurrentTokenChildTo(&redirection_children);

        while (self.current().kind == .whitespace) {
            try self.appendCurrentTokenChildTo(&redirection_children);
        }

        if (self.at(.word)) {
            const target = try self.addLeafNode(.word, self.index);
            try redirection_children.append(self.allocator, .{ .node = target });
            self.index += 1;
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

    fn addLeafNode(self: *SyntaxParser, kind: NodeKind, token_index: usize) !NodeId {
        const child_start = self.children.items.len;
        try self.children.append(self.allocator, .{ .token = .init(token_index) });
        return self.addNode(kind, self.tokens[token_index].span, token_index, token_index + 1, child_start, self.children.items.len);
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

    fn startsPipeline(self: SyntaxParser) bool {
        return self.startsSimpleCommand();
    }

    fn startsSimpleCommand(self: SyntaxParser) bool {
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

fn isAssignmentWord(word: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (equals == 0) return false;
    if (!isNameStart(word[0])) return false;
    for (word[1..equals]) |c| {
        if (!isNameContinue(c)) return false;
    }
    return true;
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
