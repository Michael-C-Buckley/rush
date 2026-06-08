//! Semantic lowering from parser CST to execution-oriented IR.

const std = @import("std");
const expand = @import("expand.zig");
const parser = @import("parser.zig");

pub const WordRef = struct {
    span: parser.Span,
    raw: []const u8,
    text: []const u8,
};

pub const Redirection = struct {
    span: parser.Span,
    io_number: ?WordRef = null,
    operator: parser.TokenKind,
    target: ?WordRef = null,
    here_doc: ?[]const u8 = null,
    here_doc_quoted: bool = false,
};

pub const SimpleCommand = struct {
    span: parser.Span,
    assignments: []WordRef,
    argv: []WordRef,
    redirections: []Redirection,
};

pub const ListOp = enum {
    sequence,
    and_if,
    or_if,
};

pub const Pipeline = struct {
    span: parser.Span,
    command_indexes: []usize,
    op_before: ListOp = .sequence,
    negated: bool = false,
    async_after: bool = false,
};

pub const IfCommand = struct {
    span: parser.Span,
    condition: []const u8,
    then_body: []const u8,
    else_body: ?[]const u8 = null,
};

pub const LoopKind = enum {
    while_loop,
    until_loop,
};

pub const LoopCommand = struct {
    span: parser.Span,
    kind: LoopKind,
    condition: []const u8,
    body: []const u8,
};

pub const ForCommand = struct {
    span: parser.Span,
    name: []const u8,
    words: []WordRef,
    body: []const u8,
};

pub const CaseArm = struct {
    patterns: []WordRef,
    body: []const u8,
};

pub const CaseCommand = struct {
    span: parser.Span,
    word: WordRef,
    arms: []CaseArm,
};

pub const FunctionDefinition = struct {
    span: parser.Span,
    name: []const u8,
    body: []const u8,
};

pub const BashTestCommand = struct {
    span: parser.Span,
    args: []WordRef,
};

pub const BraceGroup = struct {
    span: parser.Span,
    body: []const u8,
    redirections: []Redirection,
};

pub const Subshell = struct {
    span: parser.Span,
    body: []const u8,
    redirections: []Redirection,
};

pub const StatementKind = enum {
    pipeline,
    if_command,
    loop_command,
    for_command,
    case_command,
    function_definition,
    bash_test_command,
    brace_group,
    subshell,
};

pub const Statement = struct {
    kind: StatementKind,
    index: usize,
    op_before: ListOp = .sequence,
    async_after: bool = false,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    commands: []SimpleCommand,
    pipelines: []Pipeline,
    if_commands: []IfCommand = &.{},
    loop_commands: []LoopCommand = &.{},
    for_commands: []ForCommand = &.{},
    case_commands: []CaseCommand = &.{},
    function_definitions: []FunctionDefinition = &.{},
    bash_test_commands: []BashTestCommand = &.{},
    brace_groups: []BraceGroup = &.{},
    subshells: []Subshell = &.{},
    statements: []Statement = &.{},

    pub fn deinit(self: *Program) void {
        for (self.commands) |command| {
            for (command.assignments) |word| freeWord(self.allocator, word);
            for (command.argv) |word| freeWord(self.allocator, word);
            for (command.redirections) |redirection| freeRedirection(self.allocator, redirection);
            self.allocator.free(command.assignments);
            self.allocator.free(command.argv);
            self.allocator.free(command.redirections);
        }
        for (self.pipelines) |pipeline| {
            self.allocator.free(pipeline.command_indexes);
        }
        self.allocator.free(self.commands);
        self.allocator.free(self.pipelines);
        self.allocator.free(self.if_commands);
        self.allocator.free(self.loop_commands);
        for (self.for_commands) |command| {
            self.allocator.free(command.name);
            for (command.words) |word| freeWord(self.allocator, word);
            self.allocator.free(command.words);
        }
        self.allocator.free(self.for_commands);
        for (self.case_commands) |command| freeCaseCommand(self.allocator, command);
        self.allocator.free(self.case_commands);
        for (self.function_definitions) |definition| self.allocator.free(definition.name);
        self.allocator.free(self.function_definitions);
        for (self.bash_test_commands) |command| {
            for (command.args) |arg| freeWord(self.allocator, arg);
            self.allocator.free(command.args);
        }
        self.allocator.free(self.bash_test_commands);
        for (self.brace_groups) |group| freeBraceGroup(self.allocator, group);
        self.allocator.free(self.brace_groups);
        for (self.subshells) |subshell| freeSubshell(self.allocator, subshell);
        self.allocator.free(self.subshells);
        self.allocator.free(self.statements);
        self.* = undefined;
    }
};

pub fn lowerSimpleCommands(allocator: std.mem.Allocator, parsed: parser.ParseResult) !Program {
    var commands: std.ArrayList(SimpleCommand) = .empty;
    var pipelines: std.ArrayList(Pipeline) = .empty;
    var if_commands: std.ArrayList(IfCommand) = .empty;
    var loop_commands: std.ArrayList(LoopCommand) = .empty;
    var for_commands: std.ArrayList(ForCommand) = .empty;
    var case_commands: std.ArrayList(CaseCommand) = .empty;
    var function_definitions: std.ArrayList(FunctionDefinition) = .empty;
    var bash_test_commands: std.ArrayList(BashTestCommand) = .empty;
    var brace_groups: std.ArrayList(BraceGroup) = .empty;
    var subshells: std.ArrayList(Subshell) = .empty;
    var statement_refs: std.ArrayList(LoweredStatementRef) = .empty;
    defer statement_refs.deinit(allocator);
    var here_doc_ranges = try collectHereDocRanges(allocator, parsed);
    defer here_doc_ranges.deinit(allocator);
    var nested_body_ranges = try collectNestedBodyRanges(allocator, parsed);
    defer nested_body_ranges.deinit(allocator);
    const missing_command = std.math.maxInt(usize);
    const command_indexes_by_node = try allocator.alloc(usize, parsed.nodes.len);
    defer allocator.free(command_indexes_by_node);
    @memset(command_indexes_by_node, missing_command);

    errdefer {
        for (commands.items) |command| {
            freeCommand(allocator, command);
        }
        for (pipelines.items) |pipeline| {
            allocator.free(pipeline.command_indexes);
        }
        commands.deinit(allocator);
        pipelines.deinit(allocator);
        if_commands.deinit(allocator);
        loop_commands.deinit(allocator);
        for (for_commands.items) |command| freeForCommand(allocator, command);
        for_commands.deinit(allocator);
        for (case_commands.items) |command| freeCaseCommand(allocator, command);
        case_commands.deinit(allocator);
        for (function_definitions.items) |definition| allocator.free(definition.name);
        function_definitions.deinit(allocator);
        for (bash_test_commands.items) |command| freeBashTestCommand(allocator, command);
        bash_test_commands.deinit(allocator);
        for (brace_groups.items) |group| freeBraceGroup(allocator, group);
        brace_groups.deinit(allocator);
        for (subshells.items) |subshell| freeSubshell(allocator, subshell);
        subshells.deinit(allocator);
    }

    for (parsed.nodes, 0..) |node, node_index| {
        if (node.kind != .simple_command or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        command_indexes_by_node[node_index] = commands.items.len;
        const lowered = try lowerSimpleCommand(allocator, parsed, parser.NodeId.init(node_index));
        try commands.append(allocator, lowered);
    }

    var previous_pipeline_token_end: ?usize = null;
    for (parsed.nodes) |node| {
        if (node.kind != .pipeline or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        var lowered = try lowerPipeline(allocator, parsed, node, command_indexes_by_node, missing_command);
        if (previous_pipeline_token_end) |previous_end| {
            lowered.op_before = listOpBetween(parsed.tokens, previous_end, node.token_start);
        }
        lowered.async_after = statementHasAsyncTerminator(parsed.tokens, node.token_end, nextStatementStart(parsed, node.token_end));
        previous_pipeline_token_end = node.token_end;
        try statement_refs.append(allocator, .{ .kind = .pipeline, .index = pipelines.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try pipelines.append(allocator, lowered);
    }

    for (parsed.nodes) |node| {
        if (node.kind != .if_command or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .if_command, .index = if_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try if_commands.append(allocator, lowerIfCommand(parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .loop_command or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .loop_command, .index = loop_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try loop_commands.append(allocator, lowerLoopCommand(parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .for_command or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .for_command, .index = for_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try for_commands.append(allocator, try lowerForCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .case_command or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .case_command, .index = case_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try case_commands.append(allocator, try lowerCaseCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .function_definition or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .function_definition, .index = function_definitions.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try function_definitions.append(allocator, try lowerFunctionDefinition(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .bash_test_command or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .bash_test_command, .index = bash_test_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try bash_test_commands.append(allocator, try lowerBashTestCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .brace_group or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .brace_group, .index = brace_groups.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try brace_groups.append(allocator, try lowerBraceGroup(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .subshell or spanStartsInRanges(node.span, here_doc_ranges.items) or spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        try statement_refs.append(allocator, .{ .kind = .subshell, .index = subshells.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try subshells.append(allocator, try lowerSubshell(allocator, parsed, node));
    }

    std.mem.sort(LoweredStatementRef, statement_refs.items, {}, lessThanStatementRef);
    var statements: std.ArrayList(Statement) = .empty;
    errdefer statements.deinit(allocator);
    var previous_statement_end: ?usize = null;
    for (statement_refs.items) |statement_ref| {
        var statement: Statement = .{ .kind = statement_ref.kind, .index = statement_ref.index };
        if (previous_statement_end) |previous_end| {
            statement.op_before = listOpBetween(parsed.tokens, previous_end, statement_ref.token_start);
        }
        statement.async_after = statementHasAsyncTerminator(parsed.tokens, statement_ref.token_end, nextStatementStart(parsed, statement_ref.token_end));
        if (statement.kind == .pipeline) pipelines.items[statement.index].async_after = statement.async_after;
        previous_statement_end = statement_ref.token_end;
        try statements.append(allocator, statement);
    }

    return .{
        .allocator = allocator,
        .commands = try commands.toOwnedSlice(allocator),
        .pipelines = try pipelines.toOwnedSlice(allocator),
        .if_commands = try if_commands.toOwnedSlice(allocator),
        .loop_commands = try loop_commands.toOwnedSlice(allocator),
        .for_commands = try for_commands.toOwnedSlice(allocator),
        .case_commands = try case_commands.toOwnedSlice(allocator),
        .function_definitions = try function_definitions.toOwnedSlice(allocator),
        .bash_test_commands = try bash_test_commands.toOwnedSlice(allocator),
        .brace_groups = try brace_groups.toOwnedSlice(allocator),
        .subshells = try subshells.toOwnedSlice(allocator),
        .statements = try statements.toOwnedSlice(allocator),
    };
}

fn collectNestedBodyRanges(allocator: std.mem.Allocator, parsed: parser.ParseResult) !std.ArrayList(parser.Span) {
    var ranges: std.ArrayList(parser.Span) = .empty;
    errdefer ranges.deinit(allocator);
    for (parsed.nodes) |node| {
        if (!isCompoundNode(node.kind)) continue;
        for (parsed.nodeChildren(node)) |child| switch (child) {
            .node => |node_id| {
                const child_node = parsed.nodes[node_id.index()];
                if (child_node.kind == .list) try ranges.append(allocator, child_node.span);
            },
            .token => {},
        };
    }
    return ranges;
}

fn isCompoundNode(kind: parser.NodeKind) bool {
    return switch (kind) {
        .if_command,
        .loop_command,
        .for_command,
        .case_command,
        .function_definition,
        .bash_test_command,
        .brace_group,
        .subshell,
        => true,
        else => false,
    };
}

fn collectHereDocRanges(allocator: std.mem.Allocator, parsed: parser.ParseResult) !std.ArrayList(parser.Span) {
    var ranges: std.ArrayList(parser.Span) = .empty;
    errdefer ranges.deinit(allocator);
    var processed_lines: std.ArrayList(usize) = .empty;
    defer processed_lines.deinit(allocator);

    for (parsed.nodes) |node| {
        if (node.kind != .redirection or !isHereDocRedirectionNode(parsed, node)) continue;
        const line = sourceLineBounds(parsed.source, node.span.start);
        if (containsUsize(processed_lines.items, line.start)) continue;
        try processed_lines.append(allocator, line.start);

        var pending = try collectPendingHereDocsOnLine(allocator, parsed, line);
        defer pending.deinit(allocator);
        defer freePendingHereDocs(allocator, pending.items);
        var body_start = hereDocBodyStartFromLine(parsed.source, line) orelse continue;
        for (pending.items) |doc| {
            const extraction = try extractHereDocFromBodyStart(allocator, parsed.source, body_start, doc.delimiter, doc.strip_tabs);
            defer allocator.free(extraction.body);
            try ranges.append(allocator, extraction.range);
            body_start = extraction.range.end;
        }
    }
    return ranges;
}

fn spanStartsInRanges(span: parser.Span, ranges: []const parser.Span) bool {
    for (ranges) |range| {
        if (range.touches(span.start) and span.start != range.end) return true;
    }
    return false;
}

const LoweredStatementRef = struct {
    kind: StatementKind,
    index: usize,
    token_start: usize,
    token_end: usize,
};

fn lessThanStatementRef(_: void, a: LoweredStatementRef, b: LoweredStatementRef) bool {
    return a.token_start < b.token_start;
}

fn lowerSubshell(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !Subshell {
    std.debug.assert(node.kind == .subshell);
    var close_paren: ?usize = null;
    for (node.token_start..node.token_end) |token_index| {
        if (parsed.tokens[token_index].kind == .right_paren) {
            close_paren = token_index;
            break;
        }
    }

    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }

    const body_end = close_paren orelse node.token_end;
    return .{
        .span = node.span,
        .body = spanSlice(parsed, @min(node.token_start + 1, node.token_end), body_end),
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn lowerBraceGroup(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !BraceGroup {
    std.debug.assert(node.kind == .brace_group);
    var close_brace: ?usize = null;
    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind == .word and std.mem.eql(u8, token.lexeme(parsed.source), "}")) {
            close_brace = token_index;
            break;
        }
    }

    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }

    const body_end = close_brace orelse node.token_end;
    return .{
        .span = node.span,
        .body = spanSlice(parsed, @min(node.token_start + 1, node.token_end), body_end),
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn lowerCompoundRedirections(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !std.ArrayList(Redirection) {
    var redirections: std.ArrayList(Redirection) = .empty;
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }
    for (parsed.nodeChildren(node)) |child| switch (child) {
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (child_node.kind == .redirection) {
                try redirections.append(allocator, try lowerRedirection(allocator, parsed, child_node));
            }
        },
        .token => {},
    };
    return redirections;
}

fn lowerBashTestCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !BashTestCommand {
    std.debug.assert(node.kind == .bash_test_command);
    var args: std.ArrayList(WordRef) = .empty;
    errdefer {
        for (args.items) |arg| freeWord(allocator, arg);
        args.deinit(allocator);
    }

    if (node.token_end > node.token_start + 1) {
        for (node.token_start + 1..node.token_end - 1) |token_index| {
            if (parsed.tokens[token_index].kind == .word) {
                try args.append(allocator, try wordRefFromToken(allocator, parsed, token_index));
            }
        }
    }

    return .{
        .span = node.span,
        .args = try args.toOwnedSlice(allocator),
    };
}

fn lowerFunctionDefinition(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !FunctionDefinition {
    std.debug.assert(node.kind == .function_definition);
    var open_brace: ?usize = null;
    var close_brace: ?usize = null;
    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        const lexeme = token.lexeme(parsed.source);
        if (open_brace == null and std.mem.eql(u8, lexeme, "{")) {
            open_brace = token_index;
        } else if (std.mem.eql(u8, lexeme, "}")) {
            close_brace = token_index;
        }
    }
    const name = try allocator.dupe(u8, parsed.tokens[node.token_start].lexeme(parsed.source));
    errdefer allocator.free(name);
    const body_start = if (open_brace) |index| index + 1 else node.token_end;
    const body_end = close_brace orelse node.token_end;
    return .{
        .span = node.span,
        .name = name,
        .body = spanSlice(parsed, body_start, body_end),
    };
}

fn lowerCaseCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !CaseCommand {
    std.debug.assert(node.kind == .case_command);
    var word_token: ?usize = null;
    var in_token: ?usize = null;
    var esac_token: ?usize = null;

    for (node.token_start + 1..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        const lexeme = token.lexeme(parsed.source);
        if (word_token == null and !std.mem.eql(u8, lexeme, "in")) {
            word_token = token_index;
        } else if (std.mem.eql(u8, lexeme, "in")) {
            in_token = token_index;
        } else if (std.mem.eql(u8, lexeme, "esac")) {
            esac_token = token_index;
            break;
        }
    }

    const subject = try wordRefFromToken(allocator, parsed, word_token orelse node.token_start);
    errdefer freeWord(allocator, subject);

    var arms: std.ArrayList(CaseArm) = .empty;
    errdefer {
        for (arms.items) |arm| freeCaseArm(allocator, arm);
        arms.deinit(allocator);
    }

    var index = if (in_token) |token_index| token_index + 1 else node.token_end;
    const limit = esac_token orelse node.token_end;
    while (index < limit) {
        while (index < limit and parsed.tokens[index].kind.isTrivia()) : (index += 1) {}
        if (index >= limit) break;

        var patterns: std.ArrayList(WordRef) = .empty;
        errdefer {
            for (patterns.items) |pattern| freeWord(allocator, pattern);
            patterns.deinit(allocator);
        }
        while (index < limit and parsed.tokens[index].kind != .right_paren) : (index += 1) {
            if (parsed.tokens[index].kind == .word) {
                try patterns.append(allocator, try wordRefFromToken(allocator, parsed, index));
            }
        }
        if (index < limit and parsed.tokens[index].kind == .right_paren) index += 1;
        const body_start = index;
        while (index < limit and parsed.tokens[index].kind != .dsemicolon) : (index += 1) {}
        const body_end = index;
        if (index < limit and parsed.tokens[index].kind == .dsemicolon) index += 1;

        try arms.append(allocator, .{
            .patterns = try patterns.toOwnedSlice(allocator),
            .body = spanSlice(parsed, body_start, body_end),
        });
    }

    return .{
        .span = node.span,
        .word = subject,
        .arms = try arms.toOwnedSlice(allocator),
    };
}

fn lowerForCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !ForCommand {
    std.debug.assert(node.kind == .for_command);
    var name_token: ?usize = null;
    var in_token: ?usize = null;
    var do_token: ?usize = null;
    var done_token: ?usize = null;
    var depth: usize = 0;

    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        const lexeme = token.lexeme(parsed.source);
        const reserved_position = isReservedPosition(parsed, node.token_start, token_index);
        if (reserved_position and std.mem.eql(u8, lexeme, "for")) {
            depth += 1;
        } else if (depth == 1 and name_token == null) {
            if (!std.mem.eql(u8, lexeme, "in") and !std.mem.eql(u8, lexeme, "do")) name_token = token_index;
        } else if (depth == 1 and std.mem.eql(u8, lexeme, "in") and do_token == null) {
            in_token = token_index;
        } else if (depth == 1 and do_token == null and reserved_position and std.mem.eql(u8, lexeme, "do")) {
            do_token = token_index;
        } else if (reserved_position and std.mem.eql(u8, lexeme, "done")) {
            if (depth == 1 and done_token == null) done_token = token_index;
            if (depth > 0) depth -= 1;
        }
    }

    const name_index = name_token orelse node.token_start;
    const do_index = do_token orelse node.token_end;
    const done_index = done_token orelse node.token_end;
    const word_start = if (in_token) |index| index + 1 else do_index;

    var words: std.ArrayList(WordRef) = .empty;
    errdefer {
        for (words.items) |word| freeWord(allocator, word);
        words.deinit(allocator);
    }
    for (word_start..do_index) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        try words.append(allocator, try wordRefFromToken(allocator, parsed, token_index));
    }

    const name = try allocator.dupe(u8, parsed.tokens[name_index].lexeme(parsed.source));
    errdefer allocator.free(name);

    return .{
        .span = node.span,
        .name = name,
        .words = try words.toOwnedSlice(allocator),
        .body = spanSlice(parsed, @min(do_index + 1, node.token_end), done_index),
    };
}

fn lowerLoopCommand(parsed: parser.ParseResult, node: parser.Node) LoopCommand {
    std.debug.assert(node.kind == .loop_command);
    const opener = parsed.tokens[node.token_start].lexeme(parsed.source);
    var do_token: ?usize = null;
    var done_token: ?usize = null;
    var depth: usize = 0;

    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word or !isReservedPosition(parsed, node.token_start, token_index)) continue;
        const lexeme = token.lexeme(parsed.source);
        if (std.mem.eql(u8, lexeme, "while") or std.mem.eql(u8, lexeme, "until")) {
            depth += 1;
        } else if (depth == 1 and do_token == null and std.mem.eql(u8, lexeme, "do")) {
            do_token = token_index;
        } else if (std.mem.eql(u8, lexeme, "done")) {
            if (depth == 1 and done_token == null) done_token = token_index;
            if (depth > 0) depth -= 1;
        }
    }

    const do_index = do_token orelse node.token_end;
    const done_index = done_token orelse node.token_end;
    return .{
        .span = node.span,
        .kind = if (std.mem.eql(u8, opener, "while")) .while_loop else .until_loop,
        .condition = spanSlice(parsed, node.token_start + 1, do_index),
        .body = spanSlice(parsed, @min(do_index + 1, node.token_end), done_index),
    };
}

fn lowerIfCommand(parsed: parser.ParseResult, node: parser.Node) IfCommand {
    std.debug.assert(node.kind == .if_command);
    var then_token: ?usize = null;
    var else_token: ?usize = null;
    var fi_token: ?usize = null;
    var depth: usize = 0;

    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word or !isReservedPosition(parsed, node.token_start, token_index)) continue;
        const lexeme = token.lexeme(parsed.source);
        if (std.mem.eql(u8, lexeme, "if")) {
            depth += 1;
        } else if (std.mem.eql(u8, lexeme, "fi")) {
            if (depth == 1 and fi_token == null) fi_token = token_index;
            if (depth > 0) depth -= 1;
        } else if (depth == 1 and then_token == null and std.mem.eql(u8, lexeme, "then")) {
            then_token = token_index;
        } else if (depth == 1 and else_token == null and (std.mem.eql(u8, lexeme, "else") or std.mem.eql(u8, lexeme, "elif"))) {
            else_token = token_index;
        }
    }

    const then_index = then_token orelse node.token_end;
    const fi_index = fi_token orelse node.token_end;
    const condition_start = node.token_start + 1;
    const condition_end = then_index;
    const body_start = @min(then_index + 1, node.token_end);
    const body_end = else_token orelse fi_index;
    const else_body = if (else_token) |else_index| blk: {
        if (std.mem.eql(u8, parsed.tokens[else_index].lexeme(parsed.source), "elif")) {
            break :blk spanSlice(parsed, else_index, fi_index);
        }
        break :blk spanSlice(parsed, @min(else_index + 1, node.token_end), fi_index);
    } else null;

    return .{
        .span = node.span,
        .condition = spanSlice(parsed, condition_start, condition_end),
        .then_body = spanSlice(parsed, body_start, body_end),
        .else_body = else_body,
    };
}

fn isReservedPosition(parsed: parser.ParseResult, start: usize, token_index: usize) bool {
    if (token_index == start) return true;
    var index = token_index;
    while (index > start) {
        index -= 1;
        const token = parsed.tokens[index];
        if (token.kind.isTrivia()) continue;
        if (isListSeparatorToken(token.kind)) return true;
        const lexeme = if (token.kind == .word) token.lexeme(parsed.source) else "";
        return std.mem.eql(u8, lexeme, "then") or std.mem.eql(u8, lexeme, "else") or std.mem.eql(u8, lexeme, "elif") or std.mem.eql(u8, lexeme, "do") or std.mem.eql(u8, lexeme, "in");
    }
    return true;
}

fn isListSeparatorToken(kind: parser.TokenKind) bool {
    return switch (kind) {
        .newline, .semicolon, .and_if, .or_if, .ampersand => true,
        else => false,
    };
}

fn spanSlice(parsed: parser.ParseResult, token_start: usize, token_end: usize) []const u8 {
    if (token_start >= token_end or token_start >= parsed.tokens.len) return "";
    const end_index = @min(token_end, parsed.tokens.len);
    const start = parsed.tokens[token_start].span.start;
    const end = parsed.tokens[end_index - 1].span.end;
    if (end < start) return "";
    return parsed.source[start..end];
}

fn lowerPipeline(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node, command_indexes_by_node: []const usize, missing_command: usize) !Pipeline {
    var command_indexes: std.ArrayList(usize) = .empty;
    errdefer command_indexes.deinit(allocator);
    var negated = false;

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_index| {
            const token = parsed.tokens[token_index.index()];
            if (token.kind == .word and std.mem.eql(u8, token.lexeme(parsed.source), "!")) negated = true;
        },
        .node => |child_node_id| {
            const child_node = parsed.nodes[child_node_id.index()];
            if (child_node.kind != .simple_command) continue;
            const command_index = command_indexes_by_node[child_node_id.index()];
            std.debug.assert(command_index != missing_command);
            try command_indexes.append(allocator, command_index);
        },
    };

    return .{
        .span = node.span,
        .command_indexes = try command_indexes.toOwnedSlice(allocator),
        .negated = negated,
    };
}

fn nextStatementStart(parsed: parser.ParseResult, start: usize) usize {
    var index = start;
    while (index < parsed.tokens.len) : (index += 1) {
        const kind = parsed.tokens[index].kind;
        if (kind.isTrivia() or kind == .semicolon or kind == .ampersand or kind == .and_if or kind == .or_if) continue;
        break;
    }
    return index;
}

fn statementHasAsyncTerminator(tokens: []const parser.Token, start: usize, end: usize) bool {
    for (tokens[start..end]) |token| {
        if (token.kind == .ampersand) return true;
    }
    return false;
}

fn listOpBetween(tokens: []const parser.Token, start: usize, end: usize) ListOp {
    for (tokens[start..end]) |token| {
        switch (token.kind) {
            .and_if => return .and_if,
            .or_if => return .or_if,
            else => {},
        }
    }
    return .sequence;
}

fn lowerSimpleCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, id: parser.NodeId) !SimpleCommand {
    const node = parsed.nodes[id.index()];
    std.debug.assert(node.kind == .simple_command);

    var assignments: std.ArrayList(WordRef) = .empty;
    errdefer assignments.deinit(allocator);
    var argv: std.ArrayList(WordRef) = .empty;
    errdefer argv.deinit(allocator);
    var redirections: std.ArrayList(Redirection) = .empty;
    errdefer redirections.deinit(allocator);

    for (parsed.nodeChildren(node)) |child| {
        const child_node_id = switch (child) {
            .node => |child_node| child_node,
            .token => continue,
        };
        const child_node = parsed.nodes[child_node_id.index()];
        switch (child_node.kind) {
            .assignment_word => try assignments.append(allocator, try wordRef(allocator, parsed, child_node)),
            .command_word, .word => try argv.append(allocator, try wordRef(allocator, parsed, child_node)),
            .redirection => try redirections.append(allocator, try lowerRedirection(allocator, parsed, child_node)),
            else => {},
        }
    }

    return .{
        .span = node.span,
        .assignments = try assignments.toOwnedSlice(allocator),
        .argv = try argv.toOwnedSlice(allocator),
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn lowerRedirection(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !Redirection {
    std.debug.assert(node.kind == .redirection);

    var result: Redirection = .{
        .span = node.span,
        .operator = .invalid,
    };

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_id| {
            const token = parsed.tokens[token_id.index()];
            if (token.kind.isRedirectOperator()) result.operator = token.kind;
        },
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            switch (child_node.kind) {
                .io_number => result.io_number = try wordRef(allocator, parsed, child_node),
                .word => result.target = try wordRef(allocator, parsed, child_node),
                else => {},
            }
        },
    };

    if ((result.operator == .dless or result.operator == .dless_dash) and result.target != null) {
        if (try extractOrderedHereDocForRedirection(allocator, parsed, node)) |here_doc| {
            result.here_doc = here_doc.body;
            result.here_doc_quoted = here_doc.quoted;
        }
    }

    return result;
}

const HereDocExtraction = struct {
    body: []const u8,
    range: parser.Span,
};

const SourceLine = struct {
    start: usize,
    end: usize,
};

const PendingHereDoc = struct {
    redirection_start: usize,
    delimiter: []const u8,
    strip_tabs: bool,
    quoted: bool,
};

const OrderedHereDoc = struct {
    body: []const u8,
    quoted: bool,
};

fn extractOrderedHereDocForRedirection(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !?OrderedHereDoc {
    const line = sourceLineBounds(parsed.source, node.span.start);
    var pending = try collectPendingHereDocsOnLine(allocator, parsed, line);
    defer pending.deinit(allocator);
    defer freePendingHereDocs(allocator, pending.items);

    var body_start = hereDocBodyStartFromLine(parsed.source, line) orelse return null;
    for (pending.items) |doc| {
        const extraction = try extractHereDocFromBodyStart(allocator, parsed.source, body_start, doc.delimiter, doc.strip_tabs);
        body_start = extraction.range.end;
        if (doc.redirection_start == node.span.start) return .{ .body = extraction.body, .quoted = doc.quoted };
        allocator.free(extraction.body);
    }
    return null;
}

fn collectPendingHereDocsOnLine(allocator: std.mem.Allocator, parsed: parser.ParseResult, line: SourceLine) !std.ArrayList(PendingHereDoc) {
    var pending: std.ArrayList(PendingHereDoc) = .empty;
    errdefer {
        freePendingHereDocs(allocator, pending.items);
        pending.deinit(allocator);
    }
    for (parsed.nodes) |node| {
        if (node.kind != .redirection or node.span.start < line.start or node.span.start >= line.end) continue;
        const info = try hereDocInfoForNode(allocator, parsed, node) orelse continue;
        try pending.append(allocator, .{ .redirection_start = node.span.start, .delimiter = info.delimiter, .strip_tabs = info.strip_tabs, .quoted = info.quoted });
    }
    std.mem.sort(PendingHereDoc, pending.items, {}, lessThanPendingHereDoc);
    return pending;
}

fn lessThanPendingHereDoc(_: void, a: PendingHereDoc, b: PendingHereDoc) bool {
    return a.redirection_start < b.redirection_start;
}

fn freePendingHereDocs(allocator: std.mem.Allocator, pending: []const PendingHereDoc) void {
    for (pending) |doc| allocator.free(doc.delimiter);
}

const HereDocInfo = struct {
    delimiter: []const u8,
    strip_tabs: bool,
    quoted: bool,
};

fn hereDocInfoForNode(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !?HereDocInfo {
    var operator: parser.TokenKind = .invalid;
    var target_token: ?usize = null;
    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_id| {
            const token = parsed.tokens[token_id.index()];
            if (token.kind.isRedirectOperator()) operator = token.kind;
        },
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (child_node.kind == .word) target_token = child_node.token_start;
        },
    };
    if (operator != .dless and operator != .dless_dash) return null;
    const token_index = target_token orelse return null;
    const raw = parsed.tokens[token_index].lexeme(parsed.source);
    return .{
        .delimiter = try expand.quoteRemove(allocator, raw),
        .strip_tabs = operator == .dless_dash,
        .quoted = wordContainsQuotes(raw),
    };
}

fn wordContainsQuotes(raw: []const u8) bool {
    for (raw) |byte| {
        if (byte == '\'' or byte == '"' or byte == '\\') return true;
    }
    return false;
}

fn isHereDocRedirectionNode(parsed: parser.ParseResult, node: parser.Node) bool {
    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_id| {
            const kind = parsed.tokens[token_id.index()].kind;
            if (kind == .dless or kind == .dless_dash) return true;
        },
        .node => {},
    };
    return false;
}

fn extractHereDocFromBodyStart(allocator: std.mem.Allocator, source: []const u8, range_start: usize, delimiter: []const u8, strip_tabs: bool) !HereDocExtraction {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var index = range_start;
    while (index <= source.len) {
        const raw_line_start = index;
        while (index < source.len and source[index] != '\n') : (index += 1) {}
        const raw_line_end = index;
        const line_start_no_tabs = if (strip_tabs) blk: {
            var start = raw_line_start;
            while (start < raw_line_end and source[start] == '\t') : (start += 1) {}
            break :blk start;
        } else raw_line_start;
        const line = source[line_start_no_tabs..raw_line_end];
        if (std.mem.eql(u8, line, delimiter)) {
            const range_end = if (index < source.len and source[index] == '\n') index + 1 else index;
            return .{ .body = try body.toOwnedSlice(allocator), .range = .init(range_start, range_end) };
        }
        try body.appendSlice(allocator, line);
        if (index < source.len and source[index] == '\n') {
            try body.append(allocator, '\n');
            index += 1;
        } else break;
    }
    return .{ .body = try body.toOwnedSlice(allocator), .range = .init(range_start, source.len) };
}

fn sourceLineBounds(source: []const u8, offset: usize) SourceLine {
    var start = @min(offset, source.len);
    while (start > 0 and source[start - 1] != '\n') : (start -= 1) {}
    var end = @min(offset, source.len);
    while (end < source.len and source[end] != '\n') : (end += 1) {}
    return .{ .start = start, .end = end };
}

fn hereDocBodyStartFromLine(source: []const u8, line: SourceLine) ?usize {
    if (line.end >= source.len) return null;
    return line.end + 1;
}

fn containsUsize(items: []const usize, needle: usize) bool {
    for (items) |item| if (item == needle) return true;
    return false;
}

fn wordRef(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !WordRef {
    std.debug.assert(node.token_end == node.token_start + 1);
    return wordRefFromToken(allocator, parsed, node.token_start);
}

fn wordRefFromToken(allocator: std.mem.Allocator, parsed: parser.ParseResult, token_index: usize) !WordRef {
    const token = parsed.tokens[token_index];
    const raw = try allocator.dupe(u8, token.lexeme(parsed.source));
    errdefer allocator.free(raw);
    const text = try expand.expandWordScalar(allocator, raw, .{});
    return .{
        .span = token.span,
        .raw = raw,
        .text = text,
    };
}

fn freeSubshell(allocator: std.mem.Allocator, subshell: Subshell) void {
    for (subshell.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(subshell.redirections);
}

fn freeBraceGroup(allocator: std.mem.Allocator, group: BraceGroup) void {
    for (group.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(group.redirections);
}

fn freeBashTestCommand(allocator: std.mem.Allocator, command: BashTestCommand) void {
    for (command.args) |arg| freeWord(allocator, arg);
    allocator.free(command.args);
}

fn freeCaseArm(allocator: std.mem.Allocator, arm: CaseArm) void {
    for (arm.patterns) |pattern| freeWord(allocator, pattern);
    allocator.free(arm.patterns);
}

fn freeCaseCommand(allocator: std.mem.Allocator, command: CaseCommand) void {
    freeWord(allocator, command.word);
    for (command.arms) |arm| freeCaseArm(allocator, arm);
    allocator.free(command.arms);
}

fn freeForCommand(allocator: std.mem.Allocator, command: ForCommand) void {
    allocator.free(command.name);
    for (command.words) |word| freeWord(allocator, word);
    allocator.free(command.words);
}

fn freeCommand(allocator: std.mem.Allocator, command: SimpleCommand) void {
    for (command.assignments) |word| freeWord(allocator, word);
    for (command.argv) |word| freeWord(allocator, word);
    for (command.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(command.assignments);
    allocator.free(command.argv);
    allocator.free(command.redirections);
}

fn freeRedirection(allocator: std.mem.Allocator, redirection: Redirection) void {
    if (redirection.io_number) |word| freeWord(allocator, word);
    if (redirection.target) |word| freeWord(allocator, word);
    if (redirection.here_doc) |text| allocator.free(text);
}

fn freeWord(allocator: std.mem.Allocator, word: WordRef) void {
    allocator.free(word.raw);
    allocator.free(word.text);
}

test "quote removal handles single double and backslash quoting" {
    const single = try expand.quoteRemove(std.testing.allocator, "'hello world'");
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("hello world", single);

    const double = try expand.quoteRemove(std.testing.allocator, "\"hello world\"");
    defer std.testing.allocator.free(double);
    try std.testing.expectEqualStrings("hello world", double);

    const backslash = try expand.quoteRemove(std.testing.allocator, "hello\\ world");
    defer std.testing.allocator.free(backslash);
    try std.testing.expectEqualStrings("hello world", backslash);
}

test "lower removes quotes from execution words" {
    var parsed = try parser.parse(std.testing.allocator, "echo 'hello world' \"again\" a\\ b", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    const command = program.commands[0];
    try std.testing.expectEqualStrings("echo", command.argv[0].text);
    try std.testing.expectEqualStrings("hello world", command.argv[1].text);
    try std.testing.expectEqualStrings("again", command.argv[2].text);
    try std.testing.expectEqualStrings("a b", command.argv[3].text);
}

test "lower simple command assignments argv and redirections" {
    var parsed = try parser.parse(std.testing.allocator, "FOO=bar echo hi 2>out", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.commands.len);
    const command = program.commands[0];
    try std.testing.expectEqualStrings("FOO=bar", command.assignments[0].text);
    try std.testing.expectEqualStrings("echo", command.argv[0].text);
    try std.testing.expectEqualStrings("hi", command.argv[1].text);
    try std.testing.expectEqual(@as(usize, 1), command.redirections.len);
    try std.testing.expectEqual(parser.TokenKind.greater, command.redirections[0].operator);
    try std.testing.expectEqualStrings("2", command.redirections[0].io_number.?.text);
    try std.testing.expectEqualStrings("out", command.redirections[0].target.?.text);
}

test "lower preserves POSIX pipeline negation" {
    var parsed = try parser.parse(std.testing.allocator, "! false", .{});
    defer parsed.deinit();
    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.pipelines.len);
    try std.testing.expect(program.pipelines[0].negated);
    try std.testing.expectEqual(@as(usize, 1), program.pipelines[0].command_indexes.len);
}

test "lower preserves multiple simple commands from lists and pipelines" {
    var parsed = try parser.parse(std.testing.allocator, "echo hi | grep h && pwd", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 3), program.commands.len);
    try std.testing.expectEqualStrings("echo", program.commands[0].argv[0].text);
    try std.testing.expectEqualStrings("grep", program.commands[1].argv[0].text);
    try std.testing.expectEqualStrings("pwd", program.commands[2].argv[0].text);
    try std.testing.expectEqual(@as(usize, 2), program.pipelines.len);
    try std.testing.expectEqual(@as(usize, 2), program.pipelines[0].command_indexes.len);
    try std.testing.expectEqual(@as(usize, 0), program.pipelines[0].command_indexes[0]);
    try std.testing.expectEqual(@as(usize, 1), program.pipelines[0].command_indexes[1]);
    try std.testing.expectEqual(@as(usize, 1), program.pipelines[1].command_indexes.len);
    try std.testing.expectEqual(@as(usize, 2), program.pipelines[1].command_indexes[0]);
}
