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

const ParserError = std.mem.Allocator.Error || ParseError;

pub fn parse(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
) ParserError!ast.Program {
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
    pending_here_docs: std.ArrayList(PendingHereDoc) = .empty,

    const PendingHereDoc = struct {
        redirection: *ast.Redirection,
        delimiter: []const u8,
        strip_tabs: bool,
        delimiter_quoted: bool,
    };

    fn parseProgram(self: *Parser) !ast.Program {
        const body = try self.parseList(.eof);
        try self.expect(.eof);
        const program: ast.Program = .{ .source_id = self.source.id, .body = body };
        program.validate();
        return program;
    }

    const ListEnd = enum {
        eof,
        right_brace,
    };

    fn parseList(self: *Parser, end_kind: ListEnd) ParserError!ast.List {
        var entries: std.ArrayList(ast.ListEntry) = .empty;
        errdefer entries.deinit(self.allocator);

        self.skipSeparators();
        while (!self.at(.eof) and !(end_kind == .right_brace and self.at(.right_brace))) {
            const and_or = try self.parseAndOr();
            var terminator: ?ast.ListTerminator = null;
            if (self.eat(.semicolon) != null) terminator = .sequence;
            if (self.eat(.ampersand) != null) terminator = .background;
            if (self.eat(.newline)) |newline| {
                if (terminator == null) terminator = .sequence;
                try self.parsePendingHereDocs(newline.span.end);
                while (self.eat(.newline) != null) {}
            }
            try entries.append(self.allocator, .{ .and_or = and_or, .terminator = terminator });
        }

        return .{ .entries = try entries.toOwnedSlice(self.allocator) };
    }

    fn parseAndOr(self: *Parser) ParserError!ast.AndOr {
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
        return and_or;
    }

    fn parsePipeline(self: *Parser) ParserError!ast.Pipeline {
        const negated = self.eat(.bang) != null;
        var stages: std.ArrayList(ast.Command) = .empty;
        errdefer stages.deinit(self.allocator);

        try stages.append(self.allocator, try self.parseCommand());
        while (self.eat(.pipe) != null) {
            while (self.eat(.newline) != null) {}
            try stages.append(self.allocator, try self.parseCommand());
        }

        const pipeline: ast.Pipeline = .{ .stages = try stages.toOwnedSlice(self.allocator), .negated = negated };
        return pipeline;
    }

    fn parseCommand(self: *Parser) ParserError!ast.Command {
        if (try self.parseFunctionDefinition()) |definition| return .{ .function_definition = definition };
        if (try self.parseCompoundCommand()) |compound| return .{ .compound = compound };
        return .{ .simple = try self.parseSimpleCommand() };
    }

    fn parseFunctionDefinition(self: *Parser) ParserError!?ast.FunctionDefinition {
        if (!self.at(.word)) return null;
        const name_token = self.tokens[self.index];
        if (name_token.quoted or !isAssignmentName(name_token.text)) return null;
        if (self.index + 2 >= self.tokens.len) return null;
        if (self.tokens[self.index + 1].kind != .left_paren or self.tokens[self.index + 2].kind != .right_paren) return null;

        self.index += 3;
        self.skipSeparators();
        const compound = (try self.parseCompoundCommand()) orelse return error.ExpectedCommand;

        const definition: ast.FunctionDefinition = .{
            .name = name_token.text,
            .body = compound.body,
            .redirections = compound.redirections,
        };
        definition.validate();
        return definition;
    }

    fn parseCompoundCommand(self: *Parser) ParserError!?ast.CompoundInvocation {
        if (self.eat(.left_brace) == null) return null;
        const body = try self.parseList(.right_brace);
        try self.expect(.right_brace);
        const invocation: ast.CompoundInvocation = .{ .body = .{ .brace_group = body } };
        invocation.validate();
        return invocation;
    }

    fn parseSimpleCommand(self: *Parser) ParserError!ast.SimpleCommand {
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
        const redirection_items = try redirections.toOwnedSlice(self.allocator);
        for (redirection_items) |*redirection| {
            if (redirection.op == .here_doc or redirection.op == .here_doc_strip_tabs) {
                const delimiter = try self.hereDocDelimiter(redirection.target);
                try self.pending_here_docs.append(self.allocator, .{
                    .redirection = redirection,
                    .delimiter = delimiter.text,
                    .strip_tabs = redirection.op == .here_doc_strip_tabs,
                    .delimiter_quoted = delimiter.quoted,
                });
            }
        }
        const command: ast.SimpleCommand = .{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .words = try words.toOwnedSlice(self.allocator),
            .redirections = redirection_items,
            .span = command_span.?,
        };
        if (!hasPendingHereDoc(command.redirections)) command.validate();
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
        if (redirection.op != .here_doc and redirection.op != .here_doc_strip_tabs) redirection.validate();
        return redirection;
    }

    fn parseAssignment(self: *Parser, word_token: token.Token) !?ast.Assignment {
        const equals_index = std.mem.indexOfScalar(u8, word_token.text, '=') orelse return null;
        if (!isAssignmentName(word_token.text[0..equals_index])) return null;

        const value = try self.parseWordText(
            word_token.text[equals_index + 1 ..],
            word_token.span,
            word_token.span.start + equals_index + 1,
        );
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
        return self.parseWordText(word_token.text, word_token.span, word_token.span.start);
    }

    fn parseWordText(
        self: *Parser,
        text: []const u8,
        span: source_mod.Span,
        source_start: usize,
    ) ParserError!ast.Word {
        if (std.mem.indexOfAny(u8, text, "'\"$\\") == null) {
            const word: ast.Word = .{ .data = .{ .literal = text }, .span = span };
            word.validate();
            return word;
        }

        var parts: std.ArrayList(ast.WordPart) = .empty;
        errdefer parts.deinit(self.allocator);
        try self.appendWordParts(&parts, text, 0, text.len, null, source_start);

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
        source_start: usize,
    ) ParserError!void {
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
                    try self.appendWordParts(&quoted_parts, text, quote_start, index, '"', source_start);
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
                    } else if (text[index] == '\n') {
                        index += 1;
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
                    if (name_start < end and text[name_start] == '{') {
                        const expansion_end = std.mem.indexOfScalarPos(u8, text, name_start + 1, '}') orelse {
                            index += 1;
                            continue;
                        };
                        const expansion_span = self.spanFromOffsets(source_start + index, source_start + expansion_end + 1);
                        if (try self.parseBracedParameter(text[name_start + 1 .. expansion_end], expansion_span)) |parameter| {
                            if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                            try parts.append(self.allocator, .{ .parameter = parameter });
                            index = expansion_end + 1;
                            literal_start = index;
                            continue;
                        }
                    }
                    if (name_start < end) {
                        if (parseSingleParameter(text[name_start])) |parameter| {
                            if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                            try parts.append(self.allocator, .{
                                .parameter = .{
                                    .parameter = parameter,
                                    .span = self.spanFromOffsets(source_start + index, source_start + name_start + 1),
                                },
                            });
                            index = name_start + 1;
                            literal_start = index;
                            continue;
                        }
                    }
                    if (name_start < end and text[name_start] == '?') {
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        try parts.append(self.allocator, .{
                            .parameter = .{
                                .parameter = .{ .special = .question },
                                .span = self.spanFromOffsets(source_start + index, source_start + name_start + 1),
                            },
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
                        .parameter = .{
                            .parameter = .{ .variable = text[name_start..name_end] },
                            .span = self.spanFromOffsets(source_start + index, source_start + name_end),
                        },
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

    fn parseBracedParameter(
        self: *Parser,
        raw_content: []const u8,
        span: source_mod.Span,
    ) ParserError!?ast.ParameterExpansion {
        const content = try self.removeBackslashNewlines(raw_content);
        if (parseBracedSimpleParameter(content)) |parameter| return .{ .parameter = parameter, .span = span };
        if (content.len >= 2 and content[0] == '#') {
            const name_end = scanParameterName(content, 1, content.len);
            if (name_end == 1 or name_end != content.len) return null;
            return .{
                .parameter = .{ .variable = content[1..name_end] },
                .length = true,
                .span = span,
            };
        }

        const name_end = scanParameterName(content, 0, content.len);
        if (name_end == 0) return null;
        const name = content[0..name_end];
        const rest = content[name_end..];
        if (rest.len == 0) return .{ .parameter = .{ .variable = name }, .span = span };

        if (try self.parsePatternRemoval(name, rest, span)) |parameter| return parameter;

        const colon = rest.len >= 2 and rest[0] == ':' and isParameterOperator(rest[1]);
        if (colon or isParameterOperator(rest[0])) {
            const operator_byte = if (colon) rest[1] else rest[0];
            const word_text = if (colon) rest[2..] else rest[1..];
            return .{
                .parameter = .{ .variable = name },
                .colon = colon,
                .op = parameterOperator(operator_byte),
                .word = try self.parseWordText(word_text, .{}, 0),
                .span = span,
            };
        }

        return null;
    }

    fn parsePatternRemoval(
        self: *Parser,
        name: []const u8,
        rest: []const u8,
        span: source_mod.Span,
    ) ParserError!?ast.ParameterExpansion {
        if (rest.len == 0) return null;
        const PatternRemoval = struct {
            operator: ast.ParameterOperator,
            word_text: []const u8,
        };
        const removal: PatternRemoval = switch (rest[0]) {
            '#' => if (rest.len >= 2 and rest[1] == '#') .{
                .operator = .remove_large_prefix,
                .word_text = rest[2..],
            } else .{
                .operator = .remove_small_prefix,
                .word_text = rest[1..],
            },
            '%' => if (rest.len >= 2 and rest[1] == '%') .{
                .operator = .remove_large_suffix,
                .word_text = rest[2..],
            } else .{
                .operator = .remove_small_suffix,
                .word_text = rest[1..],
            },
            else => return null,
        };
        return .{
            .parameter = .{ .variable = name },
            .op = removal.operator,
            .word = try self.parseWordText(removal.word_text, .{}, 0),
            .span = span,
        };
    }

    fn removeBackslashNewlines(self: *Parser, text: []const u8) ParserError![]const u8 {
        const first = std.mem.indexOf(u8, text, "\\\n") orelse return text;
        var output: std.ArrayList(u8) = .empty;
        try output.appendSlice(self.allocator, text[0..first]);

        var index = first;
        while (index < text.len) {
            if (index + 1 < text.len and text[index] == '\\' and text[index + 1] == '\n') {
                index += 2;
                continue;
            }
            try output.append(self.allocator, text[index]);
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
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

    fn spanFromOffsets(self: Parser, start: usize, end: usize) source_mod.Span {
        var position: source_mod.Position = .{ .source_id = self.source.id };
        position.advance(self.source.text[0..start]);
        return source_mod.Span.init(position, end);
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
            .less_less,
            .less_less_dash,
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

    const HereDocDelimiter = struct {
        text: []const u8,
        quoted: bool,
    };

    fn hereDocDelimiter(self: *Parser, word: ast.Word) ParserError!HereDocDelimiter {
        var quoted = false;
        const text = try self.hereDocDelimiterText(word, &quoted);
        return .{ .text = text, .quoted = quoted };
    }

    fn hereDocDelimiterText(self: *Parser, word: ast.Word, quoted: *bool) ParserError![]const u8 {
        return switch (word.data) {
            .literal => |literal| literal,
            .parts => |parts| self.hereDocDelimiterParts(parts, quoted),
        };
    }

    fn hereDocDelimiterParts(self: *Parser, parts: []const ast.WordPart, quoted: *bool) ParserError![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        for (parts) |part| switch (part) {
            .literal => |bytes| try output.appendSlice(self.allocator, bytes),
            .single_quoted => |bytes| {
                quoted.* = true;
                try output.appendSlice(self.allocator, bytes);
            },
            .double_quoted => |nested| {
                quoted.* = true;
                try output.appendSlice(self.allocator, try self.hereDocDelimiterParts(nested, quoted));
            },
            .parameter, .command_substitution, .arithmetic => quoted.* = true,
        };
        return output.toOwnedSlice(self.allocator);
    }

    fn parsePendingHereDocs(self: *Parser, start_offset: usize) ParserError!void {
        if (self.pending_here_docs.items.len == 0) return;

        var offset = start_offset;
        for (self.pending_here_docs.items) |pending| {
            const parsed = try self.parseHereDocBody(offset, pending);
            pending.redirection.here_doc = .{
                .body = parsed.body,
                .delimiter_quoted = pending.delimiter_quoted,
            };
            offset = parsed.next_offset;
        }
        self.pending_here_docs.clearRetainingCapacity();

        while (self.index < self.tokens.len and self.tokens[self.index].span.start < offset) self.index += 1;
        if (self.index >= self.tokens.len) self.index = self.tokens.len - 1;
    }

    const ParsedHereDoc = struct {
        body: []const u8,
        next_offset: usize,
    };

    fn parseHereDocBody(self: *Parser, start_offset: usize, pending: PendingHereDoc) ParserError!ParsedHereDoc {
        var body: std.ArrayList(u8) = .empty;
        var offset = start_offset;
        while (offset <= self.source.text.len) {
            const line_start = offset;
            const newline_index = std.mem.indexOfScalarPos(u8, self.source.text, offset, '\n');
            const line_end = newline_index orelse self.source.text.len;
            const next_offset = if (newline_index) |newline| newline + 1 else self.source.text.len;
            const raw_line = self.source.text[line_start..line_end];
            const delimiter_line = if (pending.strip_tabs) stripLeadingTabs(raw_line) else raw_line;
            if (std.mem.eql(u8, delimiter_line, pending.delimiter)) {
                return .{ .body = try body.toOwnedSlice(self.allocator), .next_offset = next_offset };
            }

            const body_line = if (pending.strip_tabs) delimiter_line else raw_line;
            try body.appendSlice(self.allocator, body_line);
            if (newline_index != null) try body.append(self.allocator, '\n');
            if (next_offset == offset) break;
            offset = next_offset;
        }
        return .{ .body = try body.toOwnedSlice(self.allocator), .next_offset = offset };
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
        .less_less => .here_doc,
        .less_less_dash => .here_doc_strip_tabs,
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

fn isParameterOperator(byte: u8) bool {
    return byte == '-' or byte == '=' or byte == '+' or byte == '?';
}

fn parameterOperator(byte: u8) ast.ParameterOperator {
    return switch (byte) {
        '-' => .default_value,
        '=' => .assign_default,
        '+' => .alternate_value,
        '?' => .error_if_unset,
        else => unreachable,
    };
}

fn stripLeadingTabs(line: []const u8) []const u8 {
    var index: usize = 0;
    while (index < line.len and line[index] == '\t') index += 1;
    return line[index..];
}

fn hasPendingHereDoc(redirections: []const ast.Redirection) bool {
    for (redirections) |redirection| {
        if ((redirection.op == .here_doc or redirection.op == .here_doc_strip_tabs) and redirection.here_doc == null) {
            return true;
        }
    }
    return false;
}

fn scanParameterName(text: []const u8, start: usize, end: usize) usize {
    if (start >= end or !isNameStart(text[start])) return start;
    var index = start + 1;
    while (index < end and isNameContinue(text[index])) index += 1;
    return index;
}

fn parseBracedSimpleParameter(content: []const u8) ?ast.Parameter {
    if (content.len == 0) return null;
    if (parseSpecialParameter(content[0])) |special| {
        if (content.len == 1) return .{ .special = special };
        return null;
    }
    if (!std.ascii.isDigit(content[0])) return null;
    for (content) |byte| if (!std.ascii.isDigit(byte)) return null;
    return .{ .positional = std.fmt.parseInt(u32, content, 10) catch return null };
}

fn parseSingleParameter(byte: u8) ?ast.Parameter {
    if (parseSpecialParameter(byte)) |special| return .{ .special = special };
    if (std.ascii.isDigit(byte)) return .{ .positional = byte - '0' };
    return null;
}

fn parseSpecialParameter(byte: u8) ?ast.SpecialParameter {
    return switch (byte) {
        '@' => .at,
        '*' => .star,
        '#' => .hash,
        '?' => .question,
        '-' => .hyphen,
        '$' => .dollar,
        '!' => .bang,
        else => null,
    };
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
