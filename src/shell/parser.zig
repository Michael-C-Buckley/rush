//! Minimal parser for the rewrite bootstrap.

const std = @import("std");

const ast = @import("ast.zig");
const builtin = @import("builtin.zig");
const lexer = @import("lexer.zig");
const source_mod = @import("source.zig");
const state_mod = @import("state.zig");
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
    return parseWithAliasState(allocator, src, tokens, null);
}

pub fn parseWithAliases(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    shell_state: state_mod.State,
) ParserError!ast.Program {
    return parseWithAliasState(allocator, src, tokens, shell_state);
}

fn parseWithAliasState(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    alias_state: ?state_mod.State,
) ParserError!ast.Program {
    src.validate();
    std.debug.assert(tokens.len != 0);
    var parser: Parser = .{ .allocator = allocator, .source = src, .tokens = tokens, .alias_state = alias_state };
    return parser.parseProgram();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    tokens: []const token.Token,
    alias_state: ?state_mod.State,
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
        right_paren,
        esac,
        do,
        done,
        then,
        if_branch,
        fi,
        case_item,
    };

    fn parseList(self: *Parser, end_kind: ListEnd) ParserError!ast.List {
        var entries: std.ArrayList(ast.ListEntry) = .empty;
        errdefer entries.deinit(self.allocator);

        self.skipSeparators();
        while (!self.atListEnd(end_kind)) {
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
            while (self.eat(.newline) != null) {}
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
        if (name_token.reserved != null) return error.UnexpectedToken;
        if (builtin.lookup(name_token.text)) |definition| {
            if (definition.kind == .special) return error.UnexpectedToken;
        }

        self.index += 3;
        self.skipSeparators();
        const compound = (try self.parseCompoundCommand()) orelse return error.ExpectedCommand;

        const definition: ast.FunctionDefinition = .{
            .name = name_token.text,
            .body = compound.body,
            .redirections = compound.redirections,
        };
        if (self.canValidateHereDocs()) definition.validate();
        return definition;
    }

    fn parseCompoundCommand(self: *Parser) ParserError!?ast.CompoundInvocation {
        var body: ast.CompoundCommand = undefined;
        if (try self.parseIfCommand()) |if_command| {
            body = .{ .if_command = if_command };
        } else if (try self.parseLoopCommand()) |loop| {
            body = .{ .loop = loop };
        } else if (try self.parseForCommand()) |for_command| {
            body = .{ .for_command = for_command };
        } else if (try self.parseCaseCommand()) |case_command| {
            body = .{ .case_command = case_command };
        } else if (self.eat(.left_paren) != null) {
            body = .{ .subshell = try self.parseList(.right_paren) };
            try self.expect(.right_paren);
        } else if (self.eat(.left_brace) != null) {
            const list = try self.parseList(.right_brace);
            if (list.entries.len == 0 or list.entries[list.entries.len - 1].terminator == null) {
                return error.UnexpectedToken;
            }
            body = .{ .brace_group = list };
            try self.expect(.right_brace);
        } else {
            return null;
        }

        const redirections = try self.parseRedirectionList();
        const invocation: ast.CompoundInvocation = .{ .body = body, .redirections = redirections };
        if (self.canValidateHereDocs()) invocation.validate();
        return invocation;
    }

    fn parseIfCommand(self: *Parser) ParserError!?ast.IfCommand {
        if (self.eatReserved(.if_kw) == null) return null;
        var branches: std.ArrayList(ast.IfBranch) = .empty;
        errdefer branches.deinit(self.allocator);

        while (true) {
            const condition = try self.parseList(.then);
            _ = self.eatReserved(.then_kw) orelse return error.UnexpectedToken;
            const body = try self.parseList(.if_branch);
            try branches.append(self.allocator, .{ .condition = condition, .body = body });

            if (self.eatReserved(.elif_kw) != null) continue;
            const else_body = if (self.eatReserved(.else_kw) != null) try self.parseList(.fi) else null;
            _ = self.eatReserved(.fi_kw) orelse return error.UnexpectedToken;
            const command: ast.IfCommand = .{
                .branches = try branches.toOwnedSlice(self.allocator),
                .else_body = else_body,
            };
            if (self.canValidateHereDocs()) command.validate();
            return command;
        }
    }

    fn parseLoopCommand(self: *Parser) ParserError!?ast.LoopCommand {
        const kind: ast.LoopKind = if (self.eatReserved(.while_kw) != null)
            .while_loop
        else if (self.eatReserved(.until_kw) != null)
            .until_loop
        else
            return null;

        const condition = try self.parseList(.do);
        _ = self.eatReserved(.do_kw) orelse return error.UnexpectedToken;
        const body = try self.parseList(.done);
        _ = self.eatReserved(.done_kw) orelse return error.UnexpectedToken;

        const command: ast.LoopCommand = .{ .kind = kind, .condition = condition, .body = body };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseForCommand(self: *Parser) ParserError!?ast.ForCommand {
        if (self.eatReserved(.for_kw) == null) return null;
        const name_token = self.eat(.word) orelse return error.UnexpectedToken;
        if (name_token.quoted or !isAssignmentName(name_token.text)) return error.UnexpectedToken;

        var words: ast.ForWords = .positional_parameters;
        self.skipSeparators();
        if (self.eatReserved(.in_kw) != null) {
            var word_list: std.ArrayList(ast.Word) = .empty;
            errdefer word_list.deinit(self.allocator);
            while (!self.at(.eof) and !self.at(.semicolon) and !self.at(.newline) and !self.atReserved(.do_kw)) {
                try word_list.append(self.allocator, try self.parseWordToken(self.eat(.word) orelse return error.UnexpectedToken));
            }
            words = .{ .words = try word_list.toOwnedSlice(self.allocator) };
        }

        self.skipSeparators();
        _ = self.eatReserved(.do_kw) orelse return error.UnexpectedToken;
        const body = try self.parseList(.done);
        _ = self.eatReserved(.done_kw) orelse return error.UnexpectedToken;

        const command: ast.ForCommand = .{ .name = name_token.text, .words = words, .body = body };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseCaseCommand(self: *Parser) ParserError!?ast.CaseCommand {
        if (self.eatReserved(.case_kw) == null) return null;
        const word = try self.parseWordToken(self.eat(.word) orelse return error.UnexpectedToken);
        self.skipSeparators();
        _ = self.eatReserved(.in_kw) orelse return error.UnexpectedToken;
        self.skipSeparators();

        var arms: std.ArrayList(ast.CaseArm) = .empty;
        errdefer arms.deinit(self.allocator);
        while (!self.atReserved(.esac_kw)) {
            try arms.append(self.allocator, try self.parseCaseArm());
            self.skipSeparators();
        }
        _ = self.eatReserved(.esac_kw).?;

        const command: ast.CaseCommand = .{ .word = word, .arms = try arms.toOwnedSlice(self.allocator) };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn parseCaseArm(self: *Parser) ParserError!ast.CaseArm {
        _ = self.eat(.left_paren);

        var patterns: std.ArrayList(ast.Word) = .empty;
        errdefer patterns.deinit(self.allocator);
        while (true) {
            try patterns.append(self.allocator, try self.parseWordToken(self.eatCasePatternWord() orelse return error.UnexpectedToken));
            if (self.eat(.pipe) == null) break;
        }
        try self.expect(.right_paren);

        const body = try self.parseList(.case_item);
        const fallthrough: ast.Fallthrough = if (self.eat(.double_semicolon) != null)
            .none
        else if (self.eat(.semicolon_ampersand) != null)
            .execute_next
        else if (self.eat(.double_semicolon_ampersand) != null)
            .test_next
        else
            .none;

        const arm: ast.CaseArm = .{
            .patterns = try patterns.toOwnedSlice(self.allocator),
            .body = body,
            .fallthrough = fallthrough,
        };
        if (self.canValidateHereDocs()) arm.validate();
        return arm;
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

            const word_token = self.eatSimpleCommandWord(words.items.len != 0) orelse break;
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
        try self.registerPendingHereDocs(redirection_items);
        const command: ast.SimpleCommand = .{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .words = try words.toOwnedSlice(self.allocator),
            .redirections = redirection_items,
            .span = command_span.?,
        };
        if (self.canValidateHereDocs()) command.validate();
        return command;
    }

    fn canValidateHereDocs(self: Parser) bool {
        return self.pending_here_docs.items.len == 0;
    }

    fn parseRedirectionList(self: *Parser) ParserError![]const ast.Redirection {
        var redirections: std.ArrayList(ast.Redirection) = .empty;
        errdefer redirections.deinit(self.allocator);
        while (try self.parseRedirection()) |redirection| {
            try redirections.append(self.allocator, redirection);
        }
        const redirection_items = try redirections.toOwnedSlice(self.allocator);
        try self.registerPendingHereDocs(redirection_items);
        return redirection_items;
    }

    fn registerPendingHereDocs(self: *Parser, redirections: []ast.Redirection) !void {
        for (redirections) |*redirection| {
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

        const value_span = spanFromRelativeOffsets(
            word_token.span,
            word_token.text,
            equals_index + 1,
            word_token.text.len,
        );
        var value = try self.parseWordText(
            word_token.text[equals_index + 1 ..],
            value_span,
        );
        value.quoted = word_token.quoted;
        value.validate();
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
        var word = try self.parseWordText(word_token.text, word_token.span);
        word.quoted = word_token.quoted;
        word.validate();
        return word;
    }

    fn parseWordText(
        self: *Parser,
        text: []const u8,
        span: source_mod.Span,
    ) ParserError!ast.Word {
        if (std.mem.indexOfAny(u8, text, "'\"$\\`") == null) {
            const word: ast.Word = .{ .data = .{ .literal = text }, .span = span };
            word.validate();
            return word;
        }

        var parts: std.ArrayList(ast.WordPart) = .empty;
        errdefer parts.deinit(self.allocator);
        try self.appendWordParts(&parts, text, 0, text.len, null, span);

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
        span: source_mod.Span,
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
                    try self.appendWordParts(&quoted_parts, text, quote_start, index, '"', span);
                    try parts.append(self.allocator, .{
                        .double_quoted = try quoted_parts.toOwnedSlice(self.allocator),
                    });

                    index += 1;
                    literal_start = index;
                    continue;
                },
                '\\' => {
                    if (quote == '"' and index + 1 < end and !doubleQuoteEscapes(text[index + 1])) {
                        index += 1;
                        continue;
                    }
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    index += 1;
                    if (index >= end) {
                        try parts.append(self.allocator, .{ .escaped = "\\" });
                    } else if (text[index] == '\n') {
                        index += 1;
                    } else {
                        try parts.append(self.allocator, .{ .escaped = text[index .. index + 1] });
                        index += 1;
                    }
                    literal_start = index;
                    continue;
                },
                '`' => {
                    if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                    const substitution_end = try scanBackquoteSubstitution(text, index, end);
                    const source_text = try self.backquoteSourceText(text[index + 1 .. substitution_end]);
                    const line_offset = self.commandSubstitutionLineOffset(span, text, index + 1);
                    const parsed = try self.parseCommandSubstitution(source_text, line_offset);
                    try parts.append(self.allocator, .{
                        .command_substitution = .{ .source_text = source_text, .parsed = parsed, .line_offset = line_offset },
                    });
                    index = substitution_end + 1;
                    literal_start = index;
                    continue;
                },
                '$' => {
                    const name_start = index + 1;
                    if (quote == null and name_start < end and text[name_start] == '\'') {
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        const quote_start = name_start + 1;
                        const quote_end = try scanDollarSingleQuoteEnd(text, quote_start, end);
                        try parts.append(self.allocator, .{
                            .single_quoted = try self.dollarSingleQuotedText(text[quote_start..quote_end]),
                        });
                        index = quote_end + 1;
                        literal_start = index;
                        continue;
                    }
                    if (name_start + 1 < end and text[name_start] == '(' and text[name_start + 1] == '(') {
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        const arithmetic_end = try scanArithmeticExpansion(text, index, end);
                        try parts.append(self.allocator, .{ .arithmetic = text[name_start + 2 .. arithmetic_end] });
                        index = arithmetic_end + 2;
                        literal_start = index;
                        continue;
                    }
                    if (name_start < end and text[name_start] == '(') {
                        if (literal_start < index) try parts.append(self.allocator, .{ .literal = text[literal_start..index] });
                        const substitution_end = try scanCommandSubstitution(text, name_start, end);
                        const source_text = text[name_start + 1 .. substitution_end];
                        const line_offset = self.commandSubstitutionLineOffset(span, text, name_start + 1);
                        const parsed = try self.parseCommandSubstitution(source_text, line_offset);
                        try parts.append(self.allocator, .{
                            .command_substitution = .{ .source_text = source_text, .parsed = parsed, .line_offset = line_offset },
                        });
                        index = substitution_end + 1;
                        literal_start = index;
                        continue;
                    }
                    if (name_start < end and text[name_start] == '{') {
                        const expansion_end = scanBracedParameterEnd(text, name_start, end) orelse {
                            index += 1;
                            continue;
                        };
                        const expansion_span = spanFromRelativeOffsets(span, text, index, expansion_end + 1);
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
                                    .span = spanFromRelativeOffsets(span, text, index, name_start + 1),
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
                                .span = spanFromRelativeOffsets(span, text, index, name_start + 1),
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
                            .span = spanFromRelativeOffsets(span, text, index, name_end),
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

    fn dollarSingleQuotedText(self: *Parser, text: []const u8) ![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] != '\\') {
                try output.append(self.allocator, text[index]);
                index += 1;
                continue;
            }
            index += 1;
            if (index >= text.len) {
                try output.append(self.allocator, '\\');
                break;
            }
            switch (text[index]) {
                'a' => try output.append(self.allocator, 0x07),
                'b' => try output.append(self.allocator, 0x08),
                'e', 'E' => try output.append(self.allocator, 0x1b),
                'f' => try output.append(self.allocator, 0x0c),
                'n' => try output.append(self.allocator, '\n'),
                'r' => try output.append(self.allocator, '\r'),
                't' => try output.append(self.allocator, '\t'),
                'v' => try output.append(self.allocator, 0x0b),
                '\\', '\'', '"', '?' => try output.append(self.allocator, text[index]),
                'x' => {
                    const consumed = try appendHexEscape(self.allocator, &output, text[index + 1 ..]);
                    index += consumed;
                },
                '0'...'7' => {
                    const consumed = try appendOctalEscape(self.allocator, &output, text[index..]);
                    index += consumed - 1;
                },
                '\n' => {},
                else => try output.append(self.allocator, text[index]),
            }
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
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

        const prefix = parseBracedParameterPrefix(content) orelse return null;
        const rest = content[prefix.end..];
        if (rest.len == 0) return .{ .parameter = prefix.parameter, .span = span };

        if (prefix.parameter == .variable) {
            if (try self.parsePatternRemoval(prefix.parameter.variable, rest, span)) |parameter| return parameter;
        }

        const colon = rest.len >= 2 and rest[0] == ':' and isParameterOperator(rest[1]);
        if (colon or isParameterOperator(rest[0])) {
            const operator_byte = if (colon) rest[1] else rest[0];
            const word_text = if (colon) rest[2..] else rest[1..];
            return .{
                .parameter = prefix.parameter,
                .colon = colon,
                .op = parameterOperator(operator_byte),
                .word = try self.parseWordText(word_text, .{}),
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
            .word = try self.parseWordText(removal.word_text, .{}),
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

    fn parseCommandSubstitution(self: *Parser, source_text: []const u8, line_offset: usize) !*const ast.Program {
        _ = line_offset;
        const src: source_mod.Source = .{
            .id = self.source.id,
            .kind = .command_string,
            .name = "$()",
            .text = source_text,
        };
        const tokens = if (self.alias_state) |alias_state|
            try lexer.lexWithAliases(self.allocator, src, alias_state)
        else
            try lexer.lex(self.allocator, src);
        const program = try parseWithAliasState(self.allocator, src, tokens, self.alias_state);
        const owned = try self.allocator.create(ast.Program);
        owned.* = program;
        return owned;
    }

    fn commandSubstitutionLineOffset(self: *Parser, span: source_mod.Span, text: []const u8, start: usize) usize {
        _ = self;
        const source_start = spanFromRelativeOffsets(span, text, start, start);
        return source_start.start_line - 1;
    }

    fn backquoteSourceText(self: *Parser, raw: []const u8) ParserError![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] == '\\' and index + 1 < raw.len) {
                switch (raw[index + 1]) {
                    '`' => {
                        try output.append(self.allocator, '`');
                        index += 2;
                    },
                    '\\' => {
                        try output.append(self.allocator, '\\');
                        index += 2;
                    },
                    '\n' => index += 2,
                    else => {
                        try output.append(self.allocator, raw[index]);
                        try output.append(self.allocator, raw[index + 1]);
                        index += 2;
                    },
                }
            } else {
                try output.append(self.allocator, raw[index]);
                index += 1;
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn spanFromRelativeOffsets(span: source_mod.Span, text: []const u8, start: usize, end: usize) source_mod.Span {
        std.debug.assert(start <= end);
        std.debug.assert(end <= text.len);

        var position: source_mod.Position = .{
            .source_id = span.source_id,
            .byte_offset = span.start,
            .line = span.start_line,
            .column = span.start_column,
        };
        position.advance(text[0..start]);
        return source_mod.Span.init(position, span.start + end);
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

    fn eatSimpleCommandWord(self: *Parser, after_command_name: bool) ?token.Token {
        if (self.eat(.word)) |word| return word;
        if (!after_command_name) return null;
        return switch (self.tokens[self.index].kind) {
            .bang, .left_brace, .right_brace => token_word: {
                break :token_word self.eatOperatorAsWord();
            },
            else => null,
        };
    }

    fn eatCasePatternWord(self: *Parser) ?token.Token {
        if (self.eat(.word)) |word| return word;
        if (!self.at(.bang)) return null;
        return self.eatOperatorAsWord();
    }

    fn eatOperatorAsWord(self: *Parser) token.Token {
        const tok = self.tokens[self.index];
        self.index += 1;
        return .{
            .kind = .word,
            .span = tok.span,
            .text = self.source.text[tok.span.start..tok.span.end],
        };
    }

    fn eatReserved(self: *Parser, reserved: token.ReservedWord) ?token.Token {
        if (!self.atReserved(reserved)) return null;
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
            .escaped => |bytes| {
                quoted.* = true;
                try output.appendSlice(self.allocator, bytes);
            },
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

    fn atReserved(self: Parser, reserved: token.ReservedWord) bool {
        return self.tokens[self.index].reserved == reserved;
    }

    fn atListEnd(self: Parser, end_kind: ListEnd) bool {
        if (self.at(.eof)) return true;
        return switch (end_kind) {
            .eof => false,
            .right_brace => self.at(.right_brace),
            .right_paren => self.at(.right_paren),
            .esac => self.atReserved(.esac_kw),
            .do => self.atReserved(.do_kw),
            .done => self.atReserved(.done_kw),
            .then => self.atReserved(.then_kw),
            .if_branch => self.atReserved(.elif_kw) or self.atReserved(.else_kw) or self.atReserved(.fi_kw),
            .fi => self.atReserved(.fi_kw),
            .case_item => self.at(.double_semicolon) or
                self.at(.semicolon_ampersand) or
                self.at(.double_semicolon_ampersand) or
                self.atReserved(.esac_kw),
        };
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

const BracedParameterPrefix = struct {
    parameter: ast.Parameter,
    end: usize,
};

fn parseBracedParameterPrefix(content: []const u8) ?BracedParameterPrefix {
    if (content.len == 0) return null;
    if (parseSpecialParameter(content[0])) |special| return .{ .parameter = .{ .special = special }, .end = 1 };
    if (std.ascii.isDigit(content[0])) {
        var end: usize = 1;
        while (end < content.len and std.ascii.isDigit(content[end])) end += 1;
        return .{
            .parameter = .{ .positional = std.fmt.parseInt(u32, content[0..end], 10) catch return null },
            .end = end,
        };
    }
    const end = scanParameterName(content, 0, content.len);
    if (end == 0) return null;
    return .{ .parameter = .{ .variable = content[0..end] }, .end = end };
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
        if (text[index] == '\\') {
            index += if (index + 1 < end) 2 else 1;
            continue;
        }
        if (text[index] == '$' and index + 1 < end and text[index + 1] == '(') {
            index = try scanCommandSubstitution(text, index + 1, end);
        } else if (text[index] == '$' and index + 1 < end and text[index + 1] == '{') {
            index = scanBracedParameterEnd(text, index + 1, end) orelse return error.UnclosedQuote;
        }
        index += 1;
    }
    return error.UnclosedQuote;
}

fn scanSingleQuoteEnd(text: []const u8, start: usize, end: usize) ParseError!usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (text[index] == '\'') return index;
    }
    return error.UnclosedQuote;
}

fn scanDollarSingleQuoteEnd(text: []const u8, start: usize, end: usize) ParseError!usize {
    var index = start;
    while (index < end) : (index += 1) {
        if (text[index] == '\'') return index;
        if (text[index] == '\\' and index + 1 < end) index += 1;
    }
    return error.UnclosedQuote;
}

fn appendHexEscape(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !usize {
    var value: u16 = 0;
    var consumed: usize = 0;
    while (consumed < text.len and consumed < 2) : (consumed += 1) {
        const digit = std.fmt.charToDigit(text[consumed], 16) catch break;
        value = value * 16 + digit;
    }
    if (consumed == 0) return 0;
    try output.append(allocator, @truncate(value));
    return consumed;
}

fn appendOctalEscape(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !usize {
    var value: u16 = 0;
    var consumed: usize = 0;
    while (consumed < text.len and consumed < 3) : (consumed += 1) {
        const digit = std.fmt.charToDigit(text[consumed], 8) catch break;
        value = value * 8 + digit;
    }
    std.debug.assert(consumed != 0);
    try output.append(allocator, @truncate(value));
    return consumed;
}

fn doubleQuoteEscapes(byte: u8) bool {
    return switch (byte) {
        '$', '`', '"', '\\', '\n' => true,
        else => false,
    };
}

fn scanBracedParameterEnd(text: []const u8, open_index: usize, end: usize) ?usize {
    std.debug.assert(open_index > 0);
    std.debug.assert(text[open_index] == '{');

    var index = open_index + 1;
    var depth: usize = 1;
    var quote: ?u8 = null;
    while (index < end) {
        const byte = text[index];
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
            index += 1;
            continue;
        }
        switch (byte) {
            '\'', '"' => {
                quote = byte;
                index += 1;
            },
            '\\' => index += if (index + 1 < end) 2 else 1,
            '$' => if (index + 1 < end and text[index + 1] == '{') {
                depth += 1;
                index += 2;
            } else if (index + 1 < end and text[index + 1] == '(') {
                index = (scanCommandSubstitution(text, index + 1, end) catch return null) + 1;
            } else {
                index += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) return index;
                index += 1;
            },
            else => index += 1,
        }
    }
    return null;
}

fn scanBackquoteSubstitution(text: []const u8, open_index: usize, end: usize) ParseError!usize {
    std.debug.assert(text[open_index] == '`');
    var index = open_index + 1;
    while (index < end) {
        if (text[index] == '\\' and index + 1 < end) {
            index += 2;
            continue;
        }
        if (text[index] == '`') return index;
        index += 1;
    }
    return error.UnclosedCommandSubstitution;
}

fn scanArithmeticExpansion(text: []const u8, dollar_index: usize, end: usize) ParseError!usize {
    std.debug.assert(dollar_index + 2 < end);
    std.debug.assert(text[dollar_index] == '$');
    std.debug.assert(text[dollar_index + 1] == '(');
    std.debug.assert(text[dollar_index + 2] == '(');

    var index = dollar_index + 3;
    var paren_depth: usize = 0;
    while (index < end) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < end and text[index] != quote) index += 1;
                if (index >= end) return error.UnclosedQuote;
                index += 1;
            },
            '\\' => index += if (index + 1 < end) 2 else 1,
            '(' => {
                paren_depth += 1;
                index += 1;
            },
            ')' => if (paren_depth != 0) {
                paren_depth -= 1;
                index += 1;
            } else if (index + 1 < end and text[index + 1] == ')') {
                return index;
            } else {
                index += 1;
            },
            else => index += 1,
        }
    }
    return error.UnclosedCommandSubstitution;
}

fn scanCommandSubstitution(text: []const u8, open_index: usize, end: usize) ParseError!usize {
    std.debug.assert(open_index > 0);
    std.debug.assert(text[open_index] == '(');

    var index = open_index + 1;
    var depth: usize = 1;
    while (index < end) {
        if (startsReservedWordAt(text, index, "case")) {
            index = try scanCaseCommandText(text, index, end);
            continue;
        }
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
            '(' => depth += 1,
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

fn scanCaseCommandText(text: []const u8, start: usize, end: usize) ParseError!usize {
    var index = start + "case".len;
    while (index < end) {
        if (text[index] == '\\') {
            index += if (index + 1 < end) 2 else 1;
            continue;
        }
        if (text[index] == '\'' or text[index] == '"') {
            const quote = text[index];
            index += 1;
            while (index < end and text[index] != quote) index += 1;
            if (index >= end) return error.UnclosedQuote;
            index += 1;
            continue;
        }
        if (text[index] == '$' and index + 1 < end and text[index + 1] == '(') {
            index = try scanCommandSubstitution(text, index + 1, end);
            index += 1;
            continue;
        }
        if (startsReservedWordAt(text, index, "esac")) {
            index += "esac".len;
            return index;
        }
        index += 1;
    }
    return error.UnclosedCommandSubstitution;
}

fn startsReservedWordAt(text: []const u8, index: usize, word: []const u8) bool {
    if (index + word.len > text.len) return false;
    if (!std.mem.eql(u8, text[index..][0..word.len], word)) return false;
    if (index != 0 and isNameContinue(text[index - 1])) return false;
    if (index + word.len < text.len and isNameContinue(text[index + word.len])) return false;
    return true;
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
    try std.testing.expectEqualStrings("'", words[1].data.parts[0].escaped);
    try std.testing.expectEqualStrings("3", words[1].data.parts[1].literal);
    try std.testing.expectEqualStrings("a", words[2].data.parts[0].literal);
    try std.testing.expectEqualStrings(" ", words[2].data.parts[1].escaped);
    try std.testing.expectEqualStrings("b", words[2].data.parts[2].literal);
}

test "parser preserves non-escaper backslashes inside double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "printf \"a\\ b\" \"ok\\n\"",
    };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqualStrings("a\\ b", words[1].data.parts[0].double_quoted[0].literal);
    try std.testing.expectEqualStrings("ok\\n", words[2].data.parts[0].double_quoted[0].literal);
}

test "parser decodes dollar single quoted words as quoted literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf $'a\\nb' $'\\101' $'$x'" };
    const tokens = try @import("lexer.zig").lex(allocator, src);
    const program = try parse(allocator, src, tokens);
    const words = program.body.entries[0].and_or.pipelines[0].pipeline.stages[0].simple.words;

    try std.testing.expectEqualStrings("a\nb", words[1].data.parts[0].single_quoted);
    try std.testing.expectEqualStrings("A", words[2].data.parts[0].single_quoted);
    try std.testing.expectEqualStrings("$x", words[3].data.parts[0].single_quoted);
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
