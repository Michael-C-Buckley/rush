//! Minimal parser for the rewrite bootstrap.

const std = @import("std");

const ast = @import("ast.zig");
const source_mod = @import("source.zig");
const token = @import("token.zig");

pub const ParseError = error{
    ExpectedCommand,
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
        const pipeline = try self.parsePipeline();
        const pipelines = try self.allocator.alloc(ast.AndOrPipeline, 1);
        pipelines[0] = .{ .pipeline = pipeline };
        const and_or: ast.AndOr = .{ .pipelines = pipelines };
        and_or.validate();
        return and_or;
    }

    fn parsePipeline(self: *Parser) !ast.Pipeline {
        const command = try self.parseCommand();
        const stages = try self.allocator.alloc(ast.Command, 1);
        stages[0] = command;
        const pipeline: ast.Pipeline = .{ .stages = stages };
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
            const parts = try self.allocator.alloc(ast.WordPart, 1);
            parts[0] = .{ .literal = word_token.text };
            const word: ast.Word = .{ .parts = parts, .span = word_token.span };
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
