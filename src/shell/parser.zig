//! Minimal parser for the rewrite bootstrap.

const std = @import("std");

const ast = @import("ast.zig");
const source_mod = @import("source.zig");
const token = @import("token.zig");

pub const ParseError = error{
    ExpectedCommand,
    UnclosedQuote,
    UnexpectedToken,
};

pub fn parse(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
) (std.mem.Allocator.Error || ParseError)!ast.Program {
    src.validate();
    std.debug.assert(tokens.len != 0);
    var parser: Parser = .{ .allocator = allocator, .source = src, .tokens = tokens };
    return parser.parseProgram();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    tokens: []const token.Token,
    index: usize = 0,

    fn parseProgram(self: *Parser) !ast.Program {
        const body = try self.parseList();
        try self.expect(.eof);
        const program: ast.Program = .{ .source_id = self.source.id, .body = body };
        program.validate();
        return program;
    }

    fn parseList(self: *Parser) !ast.List {
        var entries: std.ArrayList(ast.ListEntry) = .empty;
        errdefer entries.deinit(self.allocator);

        self.skipSeparators();
        while (!self.at(.eof)) {
            const and_or = try self.parseAndOr();
            var terminator: ?ast.ListTerminator = null;
            if (self.eat(.semicolon) != null) terminator = .sequence;
            while (self.eat(.newline) != null) terminator = .sequence;
            try entries.append(self.allocator, .{ .and_or = and_or, .terminator = terminator });
        }

        return .{ .entries = try entries.toOwnedSlice(self.allocator) };
    }

    fn parseAndOr(self: *Parser) !ast.AndOr {
        var pipelines: std.ArrayList(ast.AndOrPipeline) = .empty;
        errdefer pipelines.deinit(self.allocator);

        try pipelines.append(self.allocator, .{ .pipeline = try self.parsePipeline() });
        while (self.eatAndOrOperator()) |operator| {
            try pipelines.append(self.allocator, .{
                .operator = operator,
                .pipeline = try self.parsePipeline(),
            });
        }

        const and_or: ast.AndOr = .{ .pipelines = try pipelines.toOwnedSlice(self.allocator) };
        and_or.validate();
        return and_or;
    }

    fn parsePipeline(self: *Parser) !ast.Pipeline {
        const negated = self.eat(.bang) != null;
        const command = try self.parseCommand();
        const stages = try self.allocator.alloc(ast.Command, 1);
        stages[0] = command;
        const pipeline: ast.Pipeline = .{ .stages = stages, .negated = negated };
        pipeline.validate();
        return pipeline;
    }

    fn parseCommand(self: *Parser) !ast.Command {
        return .{ .simple = try self.parseSimpleCommand() };
    }

    fn parseSimpleCommand(self: *Parser) !ast.SimpleCommand {
        var words: std.ArrayList(ast.Word) = .empty;
        errdefer words.deinit(self.allocator);
        var command_span: ?source_mod.Span = null;

        while (self.eat(.word)) |word_token| {
            const word = try self.parseWord(word_token);
            word.validate();
            try words.append(self.allocator, word);
            command_span = if (command_span) |span| .{
                .source_id = span.source_id,
                .start = span.start,
                .end = word_token.span.end,
                .start_line = span.start_line,
                .start_column = span.start_column,
            } else word_token.span;
        }

        if (words.items.len == 0) return error.ExpectedCommand;
        const command: ast.SimpleCommand = .{
            .words = try words.toOwnedSlice(self.allocator),
            .span = command_span.?,
        };
        command.validate();
        return command;
    }

    fn parseWord(self: *Parser, word_token: token.Token) !ast.Word {
        std.debug.assert(word_token.kind == .word);
        if (!word_token.quoted) return .{ .data = .{ .literal = word_token.text }, .span = word_token.span };

        var parts: std.ArrayList(ast.WordPart) = .empty;
        errdefer parts.deinit(self.allocator);

        var index: usize = 0;
        var literal_start: usize = 0;
        while (index < word_token.text.len) {
            if (word_token.text[index] != '\'') {
                index += 1;
                continue;
            }

            if (literal_start < index) {
                try parts.append(self.allocator, .{ .literal = word_token.text[literal_start..index] });
            }

            const quote_start = index + 1;
            index = quote_start;
            while (index < word_token.text.len and word_token.text[index] != '\'') index += 1;
            if (index >= word_token.text.len) return error.UnclosedQuote;
            try parts.append(self.allocator, .{ .single_quoted = word_token.text[quote_start..index] });

            index += 1;
            literal_start = index;
        }

        if (literal_start < word_token.text.len) {
            try parts.append(self.allocator, .{ .literal = word_token.text[literal_start..] });
        }

        const word: ast.Word = .{ .data = .{ .parts = try parts.toOwnedSlice(self.allocator) }, .span = word_token.span };
        word.validate();
        return word;
    }

    fn skipSeparators(self: *Parser) void {
        while (self.eat(.newline) != null or self.eat(.semicolon) != null) {}
    }

    fn expect(self: *Parser, kind: token.Kind) ParseError!void {
        _ = self.eat(kind) orelse return error.UnexpectedToken;
    }

    fn eat(self: *Parser, kind: token.Kind) ?token.Token {
        if (!self.at(kind)) return null;
        defer self.index += 1;
        return self.tokens[self.index];
    }

    fn eatAndOrOperator(self: *Parser) ?ast.AndOrOperator {
        if (self.eat(.ampersand_ampersand) != null) return .and_if;
        if (self.eat(.pipe_pipe) != null) return .or_if;
        return null;
    }

    fn at(self: Parser, kind: token.Kind) bool {
        std.debug.assert(self.index < self.tokens.len);
        return self.tokens[self.index].kind == kind;
    }
};

test "parser builds simple colon command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = ":" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);

    try std.testing.expectEqual(@as(usize, 1), program.body.entries.len);
}

test "parser builds AND-OR lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "true && ! false || false" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);

    const and_or = program.body.entries[0].and_or;
    try std.testing.expectEqual(@as(usize, 3), and_or.pipelines.len);
    try std.testing.expectEqual(@as(?ast.AndOrOperator, null), and_or.pipelines[0].operator);
    try std.testing.expectEqual(ast.AndOrOperator.and_if, and_or.pipelines[1].operator.?);
    try std.testing.expect(and_or.pipelines[1].pipeline.negated);
    try std.testing.expectEqual(ast.AndOrOperator.or_if, and_or.pipelines[2].operator.?);
}

test "parser splits single quoted word parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf '%s\\n' hello" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("printf", words[0].data.literal);
    try std.testing.expectEqualStrings("%s\\n", words[1].data.parts[0].single_quoted);
    try std.testing.expectEqualStrings("hello", words[2].data.literal);
}
