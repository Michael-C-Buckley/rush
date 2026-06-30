//! Minimal parser for the rewrite bootstrap.

const std = @import("std");

const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const source_mod = @import("source.zig");
const token = @import("token.zig");

pub const ParseError = error{
    ExpectedCommand,
    ExpectedRedirectionTarget,
    UnclosedCommandSubstitution,
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
        var stages: std.ArrayList(ast.Command) = .empty;
        errdefer stages.deinit(self.allocator);

        try stages.append(self.allocator, try self.parseCommand());
        while (self.eat(.pipe) != null) {
            while (self.eat(.newline) != null) {}
            try stages.append(self.allocator, try self.parseCommand());
        }

        const pipeline: ast.Pipeline = .{ .stages = try stages.toOwnedSlice(self.allocator), .negated = negated };
        pipeline.validate();
        return pipeline;
    }

    fn parseCommand(self: *Parser) !ast.Command {
        return .{ .simple = try self.parseSimpleCommand() };
    }

    fn parseSimpleCommand(self: *Parser) !ast.SimpleCommand {
        var assignments: std.ArrayList(ast.Assignment) = .empty;
        errdefer assignments.deinit(self.allocator);
        var words: std.ArrayList(ast.Word) = .empty;
        errdefer words.deinit(self.allocator);
        var redirections: std.ArrayList(ast.Redirection) = .empty;
        errdefer redirections.deinit(self.allocator);
        var command_span: ?source_mod.Span = null;

        while (true) {
            if (try self.parseRedirection()) |redirection| {
                try redirections.append(self.allocator, redirection);
                command_span = extendCommandSpan(command_span, redirection.span);
                continue;
            }

            const word_token = self.eat(.word) orelse break;
            if (words.items.len == 0) {
                if (try self.parseAssignment(word_token)) |assignment| {
                    try assignments.append(self.allocator, assignment);
                    command_span = extendCommandSpan(command_span, word_token.span);
                    continue;
                }
            }

            const word = try self.parseWordToken(word_token);
            try words.append(self.allocator, word);
            command_span = extendCommandSpan(command_span, word_token.span);
        }

        if (assignments.items.len == 0 and words.items.len == 0 and redirections.items.len == 0) {
            return error.ExpectedCommand;
        }
        const command: ast.SimpleCommand = .{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .words = try words.toOwnedSlice(self.allocator),
            .redirections = try redirections.toOwnedSlice(self.allocator),
            .span = command_span.?,
        };
        command.validate();
        return command;
    }

    fn parseRedirection(self: *Parser) !?ast.Redirection {
        const fd_token = self.eat(.io_number);
        const operator_token = if (self.eatRedirectionOperator()) |tok| tok else {
            if (fd_token != null) return error.UnexpectedToken;
            return null;
        };
        const target_token = self.eat(.word) orelse return error.ExpectedRedirectionTarget;
        const redirection: ast.Redirection = .{
            .fd = if (fd_token) |tok| try parseIoNumber(tok.text) else null,
            .op = redirectionOperator(operator_token.kind),
            .target = try self.parseWordToken(target_token),
            .span = extendCommandSpan(
                if (fd_token) |tok| tok.span else null,
                spanTo(operator_token.span, target_token.span.end),
            ),
        };
        redirection.validate();
        return redirection;
    }

    fn parseAssignment(self: *Parser, word_token: token.Token) !?ast.Assignment {
        const equals_index = std.mem.indexOfScalar(u8, word_token.text, '=') orelse return null;
        if (!isAssignmentName(word_token.text[0..equals_index])) return null;

        const value = try self.parseWordText(word_token.text[equals_index + 1 ..], word_token.span);
        const assignment: ast.Assignment = .{
            .name = word_token.text[0..equals_index],
            .value = value,
            .span = word_token.span,
        };
        assignment.validate();
        return assignment;
    }

    fn parseWordToken(self: *Parser, word_token: token.Token) !ast.Word {
        std.debug.assert(word_token.kind == .word);
        return self.parseWordText(word_token.text, word_token.span);
    }

    fn parseWordText(self: *Parser, text: []const u8, span: source_mod.Span) !ast.Word {
        if (std.mem.indexOfAny(u8, text, "'\"$\\") == null) {
            const word: ast.Word = .{ .data = .{ .literal = text }, .span = span };
            word.validate();
            return word;
        }

        var parts: std.ArrayList(ast.WordPart) = .empty;
        errdefer parts.deinit(self.allocator);
        try self.appendWordParts(&parts, text, 0, text.len, null);

        const word: ast.Word = .{ .data = .{ .parts = try parts.toOwnedSlice(self.allocator) }, .span = span };
        word.validate();
        return word;
    }

    fn appendWordParts(
        self: *Parser,
        parts: *std.ArrayList(ast.WordPart),
        text: []const u8,
        start: usize,
        end: usize,
        quote: ?u8,
    ) !void {
        var index = start;
        var literal_start = start;
        while (index < end) {
            switch (text[index]) {
                '\'' => if (quote == null) {
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    const quote_start = index + 1;
                    index = quote_start;
                    while (index < end and text[index] != '\'') index += 1;
                    if (index >= end) return error.UnclosedQuote;
                    try parts.append(self.allocator, .{ .single_quoted = text[quote_start..index] });
                    index += 1;
                    literal_start = index;
                    continue;
                },
                '"' => if (quote == null) {
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    const quote_start = index + 1;
                    index = try scanDoubleQuoteEnd(text, quote_start, end);

                    var quoted_parts: std.ArrayList(ast.WordPart) = .empty;
                    errdefer quoted_parts.deinit(self.allocator);
                    try self.appendWordParts(&quoted_parts, text, quote_start, index, '"');
                    try parts.append(self.allocator, .{
                        .double_quoted = try quoted_parts.toOwnedSlice(self.allocator),
                    });

                    index += 1;
                    literal_start = index;
                    continue;
                },
                '\\' => {
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    index += 1;
                    if (index >= end) {
                        try parts.append(self.allocator, .{ .literal = "\\" });
                    } else {
                        try parts.append(self.allocator, .{ .literal = text[index .. index + 1] });
                        index += 1;
                    }
                    literal_start = index;
                    continue;
                },
                '$' => {
                    const name_start = index + 1;
                    if (name_start < end and text[name_start] == '(') {
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        const substitution_end = try scanCommandSubstitution(text, name_start, end);
                        const source_text = text[name_start + 1 .. substitution_end];
                        const parsed = try self.parseCommandSubstitution(source_text);
                        try parts.append(self.allocator, .{
                            .command_substitution = .{ .source_text = source_text, .parsed = parsed },
                        });
                        index = substitution_end + 1;
                        literal_start = index;
                        continue;
                    }
                    if (name_start < end and text[name_start] == '?') {
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        try parts.append(self.allocator, .{
                            .parameter = .{ .parameter = .{ .special = .question } },
                        });
                        index = name_start + 1;
                        literal_start = index;
                        continue;
                    }
                    const name_end = scanParameterName(text, name_start, end);
                    if (name_end == name_start) {
                        index += 1;
                        continue;
                    }
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    try parts.append(self.allocator, .{
                        .parameter = .{ .parameter = .{ .variable = text[name_start..name_end] } },
                    });
                    index = name_end;
                    literal_start = index;
                    continue;
                },
                else => {},
            }
            index += 1;
        }

        if (literal_start < end) try parts.append(self.allocator, .{ .literal = text[literal_start..end] });
    }

    fn parseCommandSubstitution(self: *Parser, source_text: []const u8) !*const ast.Program {
        const src: source_mod.Source = .{
            .id = self.source.id,
            .kind = .command_string,
            .name = "$()",
            .text = source_text,
        };
        const tokens = try lexer.lex(self.allocator, src);
        const program = try parse(self.allocator, src, tokens);
        const owned = try self.allocator.create(ast.Program);
        owned.* = program;
        return owned;
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

    fn eatRedirectionOperator(self: *Parser) ?token.Token {
        return switch (self.tokens[self.index].kind) {
            .less,
            .less_ampersand,
            .less_greater,
            .greater,
            .greater_greater,
            .greater_ampersand,
            .clobber,
            => self.eat(self.tokens[self.index].kind).?,
            else => null,
        };
    }

    fn at(self: Parser, kind: token.Kind) bool {
        std.debug.assert(self.index < self.tokens.len);
        return self.tokens[self.index].kind == kind;
    }
};

fn parseIoNumber(text: []const u8) !u31 {
    return std.fmt.parseInt(u31, text, 10) catch error.UnexpectedToken;
}

fn redirectionOperator(kind: token.Kind) ast.RedirectionOperator {
    return switch (kind) {
        .less => .input,
        .less_ampersand => .duplicate_input,
        .less_greater => .read_write,
        .greater => .output,
        .greater_greater => .append,
        .greater_ampersand => .duplicate_output,
        .clobber => .clobber,
        else => unreachable,
    };
}

fn extendCommandSpan(existing: ?source_mod.Span, span: source_mod.Span) source_mod.Span {
    return if (existing) |current| .{
        .source_id = current.source_id,
        .start = current.start,
        .end = span.end,
        .start_line = current.start_line,
        .start_column = current.start_column,
    } else span;
}

fn spanTo(start: source_mod.Span, end: usize) source_mod.Span {
    std.debug.assert(end >= start.start);
    return .{
        .source_id = start.source_id,
        .start = start.start,
        .end = end,
        .start_line = start.start_line,
        .start_column = start.start_column,
    };
}

fn isAssignmentName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isNameStart(name[0])) return false;
    for (name[1..]) |byte| if (!isNameContinue(byte)) return false;
    return true;
}

fn scanParameterName(text: []const u8, start: usize, end: usize) usize {
    if (start >= end or !isNameStart(text[start])) return start;
    var index = start + 1;
    while (index < end and isNameContinue(text[index])) index += 1;
    return index;
}

fn scanDoubleQuoteEnd(text: []const u8, start: usize, end: usize) ParseError!usize {
    var index = start;
    while (index < end) {
        if (text[index] == '"') return index;
        if (text[index] == '$' and index + 1 < end and text[index + 1] == '(') {
            index = try scanCommandSubstitution(text, index + 1, end);
        }
        index += 1;
    }
    return error.UnclosedQuote;
}

fn scanCommandSubstitution(text: []const u8, open_index: usize, end: usize) ParseError!usize {
    std.debug.assert(open_index > 0);
    std.debug.assert(text[open_index] == '(');

    var index = open_index + 1;
    var depth: usize = 1;
    while (index < end) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < end and text[index] != quote) index += 1;
                if (index >= end) return error.UnclosedQuote;
            },
            '$' => if (index + 1 < end and text[index + 1] == '(') {
                depth += 1;
                index += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
        index += 1;
    }
    return error.UnclosedCommandSubstitution;
}

fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

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

test "parser builds pipeline stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf x | cat" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const pipeline = program.body.entries[0].and_or.pipelines[0].pipeline;

    try std.testing.expectEqual(@as(usize, 2), pipeline.stages.len);
    try std.testing.expectEqualStrings("printf", pipeline.stages[0].simple.words[0].data.literal);
    try std.testing.expectEqualStrings("cat", pipeline.stages[1].simple.words[0].data.literal);
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

test "parser removes unquoted backslash escapes from word text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \\'3 a\\ b" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("'", words[1].data.parts[0].literal);
    try std.testing.expectEqualStrings("3", words[1].data.parts[1].literal);
    try std.testing.expectEqualStrings("a", words[2].data.parts[0].literal);
    try std.testing.expectEqualStrings(" ", words[2].data.parts[1].literal);
    try std.testing.expectEqualStrings("b", words[2].data.parts[2].literal);
}

test "parser recognizes leading assignment words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=hello printf x=arg" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const command = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple;

    try std.testing.expectEqual(@as(usize, 1), command.assignments.len);
    try std.testing.expectEqualStrings("x", command.assignments[0].name);
    try std.testing.expectEqualStrings("hello", command.assignments[0].value.data.literal);
    try std.testing.expectEqual(@as(usize, 2), command.words.len);
    try std.testing.expectEqualStrings("x=arg", command.words[1].data.literal);
}

test "parser builds parameter parts inside double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \"$x\"" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const word = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words[1];

    const quoted_parts = word.data.parts[0].double_quoted;
    try std.testing.expectEqualStrings("x", quoted_parts[0].parameter.parameter.variable);
}

test "parser builds command substitution word parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=$(exit 7)" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const assignment = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.assignments[0];

    try std.testing.expectEqualStrings("x", assignment.name);
    const substitution = assignment.value.data.parts[0].command_substitution;
    try std.testing.expectEqualStrings("exit 7", substitution.source_text);
    try std.testing.expect(substitution.parsed != null);
}
