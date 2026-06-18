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
    here_doc_range: ?parser.Span = null,
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
    stage_spans: []parser.Span = &.{},
    stage_sources: []const []const u8 = &.{},
    op_before: ListOp = .sequence,
    negated: bool = false,
    async_after: bool = false,
};

pub const IfBranch = struct {
    condition: []const u8,
    body: []const u8,
};

pub const IfCommand = struct {
    span: parser.Span,
    branches: []const IfBranch,
    else_body: ?[]const u8 = null,
    redirections: []Redirection,
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
    redirections: []Redirection,
};

pub const ForCommand = struct {
    span: parser.Span,
    name: []const u8,
    words: []WordRef,
    use_positionals: bool = false,
    body: []const u8,
    redirections: []Redirection,
};

pub const CaseArm = struct {
    patterns: []WordRef,
    body: []const u8,
    fallthrough: bool = false,
    test_next: bool = false,
};

pub const CaseCommand = struct {
    span: parser.Span,
    word: WordRef,
    arms: []CaseArm,
    redirections: []Redirection,
};

pub const FunctionDefinition = struct {
    span: parser.Span,
    name: []const u8,
    body: []const u8,
    redirections: []Redirection,
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
    span: parser.Span,
    op_before: ListOp = .sequence,
    async_after: bool = false,
};

pub const SourceFragmentRenderOptions = struct {
    trim_syntax: bool = false,
};

pub const SourceFragment = struct {
    syntax_span: parser.Span,
    consumed_end: usize,
    payload_slices: []const []const u8 = &.{},

    pub fn deinit(self: *SourceFragment, allocator: std.mem.Allocator) void {
        allocator.free(self.payload_slices);
        self.* = undefined;
    }

    pub fn render(
        self: SourceFragment,
        allocator: std.mem.Allocator,
        source: []const u8,
        options: SourceFragmentRenderOptions,
    ) ![]const u8 {
        std.debug.assert(self.syntax_span.end <= source.len);
        std.debug.assert(self.syntax_span.end <= self.consumed_end);
        std.debug.assert(self.consumed_end <= source.len);
        var syntax = self.syntax_span.slice(source);
        if (options.trim_syntax) syntax = std.mem.trim(u8, syntax, " \t\r\n;");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, syntax);
        for (self.payload_slices) |payload| {
            if (output.items.len != 0 and output.items[output.items.len - 1] != '\n') {
                try output.append(allocator, '\n');
            }
            try output.appendSlice(allocator, payload);
        }
        return output.toOwnedSlice(allocator);
    }
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
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
            self.allocator.free(pipeline.stage_spans);
            freePipelineStageSources(self.allocator, pipeline.stage_sources);
        }
        self.allocator.free(self.commands);
        self.allocator.free(self.pipelines);
        for (self.if_commands) |command| freeIfCommand(self.allocator, command);
        self.allocator.free(self.if_commands);
        for (self.loop_commands) |command| freeLoopCommand(self.allocator, command);
        self.allocator.free(self.loop_commands);
        for (self.for_commands) |command| freeForCommand(self.allocator, command);
        self.allocator.free(self.for_commands);
        for (self.case_commands) |command| freeCaseCommand(self.allocator, command);
        self.allocator.free(self.case_commands);
        for (self.function_definitions) |definition| freeFunctionDefinition(self.allocator, definition);
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
    var compound_pipeline_stage_ranges = try collectCompoundPipelineStageRanges(allocator, parsed);
    defer compound_pipeline_stage_ranges.deinit(allocator);
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
            allocator.free(pipeline.stage_spans);
            freePipelineStageSources(allocator, pipeline.stage_sources);
        }
        commands.deinit(allocator);
        pipelines.deinit(allocator);
        for (if_commands.items) |command| freeIfCommand(allocator, command);
        if_commands.deinit(allocator);
        for (loop_commands.items) |command| freeLoopCommand(allocator, command);
        loop_commands.deinit(allocator);
        for (for_commands.items) |command| freeForCommand(allocator, command);
        for_commands.deinit(allocator);
        for (case_commands.items) |command| freeCaseCommand(allocator, command);
        case_commands.deinit(allocator);
        for (function_definitions.items) |definition| freeFunctionDefinition(allocator, definition);
        function_definitions.deinit(allocator);
        for (bash_test_commands.items) |command| freeBashTestCommand(allocator, command);
        bash_test_commands.deinit(allocator);
        for (brace_groups.items) |group| freeBraceGroup(allocator, group);
        brace_groups.deinit(allocator);
        for (subshells.items) |subshell| freeSubshell(allocator, subshell);
        subshells.deinit(allocator);
    }

    for (parsed.nodes, 0..) |node, node_index| {
        if (node.kind != .simple_command or
            spanStartsInRanges(node.span, here_doc_ranges.items) or
            spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        command_indexes_by_node[node_index] = commands.items.len;
        const lowered = try lowerSimpleCommand(allocator, parsed, parser.NodeId.init(node_index));
        try commands.append(allocator, lowered);
    }

    var previous_pipeline_token_end: ?usize = null;
    for (parsed.nodes) |node| {
        if (node.kind != .pipeline or
            spanStartsInRanges(node.span, here_doc_ranges.items) or
            spanStartsInRanges(node.span, nested_body_ranges.items)) continue;
        var lowered = try lowerPipeline(allocator, parsed, node, command_indexes_by_node, missing_command);
        if (previous_pipeline_token_end) |previous_end| {
            lowered.op_before = listOpBetween(parsed.tokens, previous_end, node.token_start);
        }
        lowered.async_after = statementHasAsyncTerminator(
            parsed.tokens,
            node.token_end,
            nextStatementStart(parsed, node.token_end),
        );
        previous_pipeline_token_end = node.token_end;
        try statement_refs.append(allocator, .{
            .kind = .pipeline,
            .index = pipelines.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try pipelines.append(allocator, lowered);
    }

    for (parsed.nodes) |node| {
        if (node.kind != .if_command or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .if_command,
            .index = if_commands.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try if_commands.append(allocator, try lowerIfCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .loop_command or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .loop_command,
            .index = loop_commands.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try loop_commands.append(allocator, try lowerLoopCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .for_command or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .for_command,
            .index = for_commands.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try for_commands.append(allocator, try lowerForCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .case_command or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .case_command,
            .index = case_commands.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try case_commands.append(allocator, try lowerCaseCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .function_definition or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .function_definition,
            .index = function_definitions.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try function_definitions.append(allocator, try lowerFunctionDefinition(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .bash_test_command or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .bash_test_command,
            .index = bash_test_commands.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try bash_test_commands.append(allocator, try lowerBashTestCommand(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .brace_group or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .brace_group,
            .index = brace_groups.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try brace_groups.append(allocator, try lowerBraceGroup(allocator, parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .subshell or spanStartsInSkippedRange(
            node.span,
            here_doc_ranges.items,
            nested_body_ranges.items,
            compound_pipeline_stage_ranges.items,
        )) continue;
        try statement_refs.append(allocator, .{
            .kind = .subshell,
            .index = subshells.items.len,
            .token_start = node.token_start,
            .token_end = node.token_end,
        });
        try subshells.append(allocator, try lowerSubshell(allocator, parsed, node));
    }

    std.mem.sort(LoweredStatementRef, statement_refs.items, {}, lessThanStatementRef);
    var statements: std.ArrayList(Statement) = .empty;
    errdefer statements.deinit(allocator);
    var previous_statement_end: ?usize = null;
    for (statement_refs.items) |statement_ref| {
        var statement: Statement = .{
            .kind = statement_ref.kind,
            .index = statement_ref.index,
            .span = statementSpan(parsed, statement_ref),
        };
        if (previous_statement_end) |previous_end| {
            if (previous_end <= statement_ref.token_start) {
                statement.op_before = listOpBetween(parsed.tokens, previous_end, statement_ref.token_start);
            }
        }
        statement.async_after = statementHasAsyncTerminator(
            parsed.tokens,
            statement_ref.token_end,
            nextStatementStart(parsed, statement_ref.token_end),
        );
        if (statement.kind == .pipeline) pipelines.items[statement.index].async_after = statement.async_after;
        previous_statement_end = if (previous_statement_end) |previous_end|
            @max(previous_end, statement_ref.token_end)
        else
            statement_ref.token_end;
        try statements.append(allocator, statement);
    }

    return .{
        .allocator = allocator,
        .source = parsed.source,
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

pub fn statementSourceFragment(
    allocator: std.mem.Allocator,
    program: Program,
    statement_index: usize,
) !SourceFragment {
    std.debug.assert(statement_index < program.statements.len);
    const statement = program.statements[statement_index];
    const syntax_end = statementSyntacticEnd(program, statement);
    std.debug.assert(statement.span.start <= syntax_end);
    std.debug.assert(syntax_end <= program.source.len);
    const broad_end = if (statement_index + 1 < program.statements.len)
        program.statements[statement_index + 1].span.start
    else
        program.source.len;

    var payloads: std.ArrayList([]const u8) = .empty;
    errdefer payloads.deinit(allocator);
    var consumed_end = syntax_end;
    try appendStatementPayloadSlices(allocator, &payloads, &consumed_end, program, statement, syntax_end, broad_end);
    return .{
        .syntax_span = .init(statement.span.start, syntax_end),
        .consumed_end = consumed_end,
        .payload_slices = try payloads.toOwnedSlice(allocator),
    };
}

fn statementSyntacticEnd(program: Program, statement: Statement) usize {
    return switch (statement.kind) {
        .pipeline => pipelineSyntacticEnd(program, program.pipelines[statement.index]),
        .if_command => program.if_commands[statement.index].span.end,
        .loop_command => program.loop_commands[statement.index].span.end,
        .for_command => program.for_commands[statement.index].span.end,
        .case_command => program.case_commands[statement.index].span.end,
        .function_definition => program.function_definitions[statement.index].span.end,
        .bash_test_command => program.bash_test_commands[statement.index].span.end,
        .brace_group => program.brace_groups[statement.index].span.end,
        .subshell => program.subshells[statement.index].span.end,
    };
}

fn pipelineSyntacticEnd(program: Program, pipeline: Pipeline) usize {
    var end = pipeline.span.end;
    for (pipeline.command_indexes) |command_index| end = @max(end, program.commands[command_index].span.end);
    return end;
}

fn appendStatementPayloadSlices(
    allocator: std.mem.Allocator,
    payloads: *std.ArrayList([]const u8),
    consumed_end: *usize,
    program: Program,
    statement: Statement,
    syntax_end: usize,
    broad_end: usize,
) anyerror!void {
    switch (statement.kind) {
        .pipeline => {
            const pipeline = program.pipelines[statement.index];
            if (pipeline.command_indexes.len == pipeline.stage_spans.len) {
                for (pipeline.command_indexes) |command_index| {
                    try appendRedirectionPayloadSlices(
                        allocator,
                        payloads,
                        consumed_end,
                        program.source,
                        program.commands[command_index].redirections,
                        syntax_end,
                    );
                }
            } else {
                for (pipeline.stage_sources, pipeline.stage_spans) |source, span| {
                    const syntax_len = span.end - span.start;
                    const payload_start = payloadTailStart(source, syntax_len);
                    if (source.len > payload_start) {
                        consumed_end.* = @max(consumed_end.*, broad_end);
                        try payloads.append(allocator, source[payload_start..]);
                    }
                }
            }
        },
        .if_command => {
            const command = program.if_commands[statement.index];
            try appendRedirectionPayloadSlices(
                allocator,
                payloads,
                consumed_end,
                program.source,
                command.redirections,
                syntax_end,
            );
            for (command.branches) |branch| {
                try appendEmbeddedPayloadSlices(allocator, payloads, branch.condition);
                try appendEmbeddedPayloadSlices(allocator, payloads, branch.body);
            }
            if (command.else_body) |body| try appendEmbeddedPayloadSlices(allocator, payloads, body);
        },
        .loop_command => {
            const command = program.loop_commands[statement.index];
            try appendRedirectionPayloadSlices(
                allocator,
                payloads,
                consumed_end,
                program.source,
                command.redirections,
                syntax_end,
            );
            try appendEmbeddedPayloadSlices(allocator, payloads, command.condition);
            try appendEmbeddedPayloadSlices(allocator, payloads, command.body);
        },
        .for_command => {
            const command = program.for_commands[statement.index];
            try appendRedirectionPayloadSlices(
                allocator,
                payloads,
                consumed_end,
                program.source,
                command.redirections,
                syntax_end,
            );
            try appendEmbeddedPayloadSlices(allocator, payloads, command.body);
        },
        .case_command => {
            const command = program.case_commands[statement.index];
            try appendRedirectionPayloadSlices(
                allocator,
                payloads,
                consumed_end,
                program.source,
                command.redirections,
                syntax_end,
            );
            for (command.arms) |arm| try appendEmbeddedPayloadSlices(allocator, payloads, arm.body);
        },
        .function_definition => {
            const definition = program.function_definitions[statement.index];
            try appendRedirectionPayloadSlices(
                allocator,
                payloads,
                consumed_end,
                program.source,
                definition.redirections,
                syntax_end,
            );
            try appendEmbeddedPayloadSlices(allocator, payloads, definition.body);
        },
        .brace_group => {
            const group = program.brace_groups[statement.index];
            try appendRedirectionPayloadSlices(
                allocator,
                payloads,
                consumed_end,
                program.source,
                group.redirections,
                syntax_end,
            );
            try appendEmbeddedPayloadSlices(allocator, payloads, group.body);
        },
        .subshell => {
            const subshell = program.subshells[statement.index];
            try appendRedirectionPayloadSlices(
                allocator,
                payloads,
                consumed_end,
                program.source,
                subshell.redirections,
                syntax_end,
            );
            try appendEmbeddedPayloadSlices(allocator, payloads, subshell.body);
        },
        .bash_test_command => {},
    }
}

fn payloadTailStart(source: []const u8, syntax_len: usize) usize {
    std.debug.assert(syntax_len <= source.len);
    var start = syntax_len;
    if (start < source.len and source[start] == '\r') start += 1;
    if (start < source.len and source[start] == '\n') start += 1;
    return start;
}

fn appendRedirectionPayloadSlices(
    allocator: std.mem.Allocator,
    payloads: *std.ArrayList([]const u8),
    consumed_end: ?*usize,
    source: []const u8,
    redirections: []const Redirection,
    syntax_end: usize,
) !void {
    for (redirections) |redirection| {
        const range = redirection.here_doc_range orelse continue;
        if (range.start < syntax_end) continue;
        if (consumed_end) |end| end.* = @max(end.*, range.end);
        try payloads.append(allocator, source[range.start..range.end]);
    }
}

fn appendEmbeddedPayloadSlices(
    allocator: std.mem.Allocator,
    payloads: *std.ArrayList([]const u8),
    body: []const u8,
) anyerror!void {
    if (std.mem.indexOf(u8, body, "<<") == null) return;
    var parsed = try parser.parse(allocator, body, .{});
    defer parsed.deinit();
    var body_program = try lowerSimpleCommands(allocator, parsed);
    defer body_program.deinit();
    for (body_program.statements) |statement| {
        const syntax_end = statementSyntacticEnd(body_program, statement);
        var ignored_consumed_end = syntax_end;
        try appendStatementPayloadSlices(
            allocator,
            payloads,
            &ignored_consumed_end,
            body_program,
            statement,
            syntax_end,
            body_program.source.len,
        );
    }
}

fn lowerListNode(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    list_node: parser.Node,
    source_span: parser.Span,
) !Program {
    std.debug.assert(list_node.kind == .list);
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
    var statements: std.ArrayList(Statement) = .empty;

    errdefer {
        for (commands.items) |command| freeCommand(allocator, command);
        commands.deinit(allocator);
        for (pipelines.items) |pipeline| {
            allocator.free(pipeline.command_indexes);
            allocator.free(pipeline.stage_spans);
            freePipelineStageSources(allocator, pipeline.stage_sources);
        }
        pipelines.deinit(allocator);
        for (if_commands.items) |command| freeIfCommand(allocator, command);
        if_commands.deinit(allocator);
        for (loop_commands.items) |command| freeLoopCommand(allocator, command);
        loop_commands.deinit(allocator);
        for (for_commands.items) |command| freeForCommand(allocator, command);
        for_commands.deinit(allocator);
        for (case_commands.items) |command| freeCaseCommand(allocator, command);
        case_commands.deinit(allocator);
        for (function_definitions.items) |definition| freeFunctionDefinition(allocator, definition);
        function_definitions.deinit(allocator);
        for (bash_test_commands.items) |command| freeBashTestCommand(allocator, command);
        bash_test_commands.deinit(allocator);
        for (brace_groups.items) |group| freeBraceGroup(allocator, group);
        brace_groups.deinit(allocator);
        for (subshells.items) |subshell| freeSubshell(allocator, subshell);
        subshells.deinit(allocator);
        statements.deinit(allocator);
    }

    var previous_statement_end: ?usize = null;
    for (parsed.nodeChildren(list_node)) |child| {
        const child_node_id = switch (child) {
            .node => |node_id| node_id,
            .token => continue,
        };
        const child_node = parsed.nodes[child_node_id.index()];
        var statement: Statement = switch (child_node.kind) {
            .pipeline => blk: {
                var lowered = try lowerPipelineDirect(allocator, parsed, child_node, &commands);
                lowered.async_after = statementHasAsyncTerminator(
                    parsed.tokens,
                    child_node.token_end,
                    nextListStatementStart(parsed, list_node, child_node.token_end),
                );
                const pipeline_index = pipelines.items.len;
                try pipelines.append(allocator, lowered);
                break :blk .{
                    .kind = .pipeline,
                    .index = pipeline_index,
                    .span = child_node.span,
                    .async_after = lowered.async_after,
                };
            },
            .if_command => blk: {
                const index = if_commands.items.len;
                try if_commands.append(allocator, try lowerIfCommand(allocator, parsed, child_node));
                break :blk .{ .kind = .if_command, .index = index, .span = child_node.span };
            },
            .loop_command => blk: {
                const index = loop_commands.items.len;
                try loop_commands.append(allocator, try lowerLoopCommand(allocator, parsed, child_node));
                break :blk .{ .kind = .loop_command, .index = index, .span = child_node.span };
            },
            .for_command => blk: {
                const index = for_commands.items.len;
                try for_commands.append(allocator, try lowerForCommand(allocator, parsed, child_node));
                break :blk .{ .kind = .for_command, .index = index, .span = child_node.span };
            },
            .case_command => blk: {
                const index = case_commands.items.len;
                try case_commands.append(allocator, try lowerCaseCommand(allocator, parsed, child_node));
                break :blk .{ .kind = .case_command, .index = index, .span = child_node.span };
            },
            .function_definition => blk: {
                const index = function_definitions.items.len;
                try function_definitions.append(allocator, try lowerFunctionDefinition(allocator, parsed, child_node));
                break :blk .{ .kind = .function_definition, .index = index, .span = child_node.span };
            },
            .bash_test_command => blk: {
                const index = bash_test_commands.items.len;
                try bash_test_commands.append(allocator, try lowerBashTestCommand(allocator, parsed, child_node));
                break :blk .{ .kind = .bash_test_command, .index = index, .span = child_node.span };
            },
            .brace_group => blk: {
                const index = brace_groups.items.len;
                try brace_groups.append(allocator, try lowerBraceGroup(allocator, parsed, child_node));
                break :blk .{ .kind = .brace_group, .index = index, .span = child_node.span };
            },
            .subshell => blk: {
                const index = subshells.items.len;
                try subshells.append(allocator, try lowerSubshell(allocator, parsed, child_node));
                break :blk .{ .kind = .subshell, .index = index, .span = child_node.span };
            },
            else => continue,
        };
        if (previous_statement_end) |previous_end| {
            statement.op_before = listOpBetween(parsed.tokens, previous_end, child_node.token_start);
        }
        statement.async_after = statementHasAsyncTerminator(
            parsed.tokens,
            child_node.token_end,
            nextListStatementStart(parsed, list_node, child_node.token_end),
        );
        if (statement.kind == .pipeline) pipelines.items[statement.index].async_after = statement.async_after;
        previous_statement_end = if (previous_statement_end) |previous_end|
            @max(previous_end, child_node.token_end)
        else
            child_node.token_end;
        try statements.append(allocator, statement);
    }

    var program: Program = .{
        .allocator = allocator,
        .source = parsed.source[source_span.start..source_span.end],
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
    relocateProgramSpans(&program, source_span.start);
    return program;
}

fn nextListStatementStart(parsed: parser.ParseResult, list_node: parser.Node, after_token: usize) usize {
    for (parsed.nodeChildren(list_node)) |child| {
        const child_node_id = switch (child) {
            .node => |node_id| node_id,
            .token => continue,
        };
        const child_node = parsed.nodes[child_node_id.index()];
        if (!isStatementNode(child_node.kind) or child_node.token_start <= after_token) continue;
        return child_node.token_start;
    }
    return list_node.token_end;
}

fn isStatementNode(kind: parser.NodeKind) bool {
    return switch (kind) {
        .pipeline,
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

fn lowerPipelineDirect(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    node: parser.Node,
    commands: *std.ArrayList(SimpleCommand),
) !Pipeline {
    std.debug.assert(node.kind == .pipeline);
    var command_indexes: std.ArrayList(usize) = .empty;
    errdefer command_indexes.deinit(allocator);
    var stage_spans: std.ArrayList(parser.Span) = .empty;
    errdefer stage_spans.deinit(allocator);
    var stage_sources: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (stage_sources.items) |source| allocator.free(source);
        stage_sources.deinit(allocator);
    }
    var negated = false;

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_index| {
            const token = parsed.tokens[token_index.index()];
            if (token.kind == .word and std.mem.eql(u8, token.lexeme(parsed.source), "!")) negated = true;
        },
        .node => |child_node_id| {
            const child_node = parsed.nodes[child_node_id.index()];
            try stage_spans.append(allocator, child_node.span);
            try stage_sources.append(
                allocator,
                try ownedSourceWithHereDocs(allocator, parsed, child_node.span.start, child_node.span.end),
            );
            if (child_node.kind == .simple_command) {
                const command_index = commands.items.len;
                try commands.append(allocator, try lowerSimpleCommand(allocator, parsed, child_node_id));
                try command_indexes.append(allocator, command_index);
            }
        },
    };

    return .{
        .span = node.span,
        .command_indexes = try command_indexes.toOwnedSlice(allocator),
        .stage_spans = try stage_spans.toOwnedSlice(allocator),
        .stage_sources = try stage_sources.toOwnedSlice(allocator),
        .negated = negated,
    };
}

fn relocateProgramSpans(program: *Program, source_offset: usize) void {
    for (program.commands) |*command| relocateSimpleCommandSpans(command, source_offset);
    for (program.pipelines) |*pipeline| {
        pipeline.span = relocateSpan(pipeline.span, source_offset);
        for (pipeline.stage_spans) |*span| span.* = relocateSpan(span.*, source_offset);
    }
    for (program.if_commands) |*command| {
        command.span = relocateSpan(command.span, source_offset);
        for (command.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
    }
    for (program.loop_commands) |*command| {
        command.span = relocateSpan(command.span, source_offset);
        for (command.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
    }
    for (program.for_commands) |*command| {
        command.span = relocateSpan(command.span, source_offset);
        for (command.words) |*word| relocateWordSpans(word, source_offset);
        for (command.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
    }
    for (program.case_commands) |*command| {
        command.span = relocateSpan(command.span, source_offset);
        relocateWordSpans(&command.word, source_offset);
        for (command.arms) |*arm| {
            for (arm.patterns) |*pattern| relocateWordSpans(pattern, source_offset);
        }
        for (command.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
    }
    for (program.function_definitions) |*definition| {
        definition.span = relocateSpan(definition.span, source_offset);
        for (definition.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
    }
    for (program.bash_test_commands) |*command| {
        command.span = relocateSpan(command.span, source_offset);
        for (command.args) |*arg| relocateWordSpans(arg, source_offset);
    }
    for (program.brace_groups) |*group| {
        group.span = relocateSpan(group.span, source_offset);
        for (group.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
    }
    for (program.subshells) |*subshell| {
        subshell.span = relocateSpan(subshell.span, source_offset);
        for (subshell.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
    }
    for (program.statements) |*statement| statement.span = relocateSpan(statement.span, source_offset);
}

fn relocateSimpleCommandSpans(command: *SimpleCommand, source_offset: usize) void {
    command.span = relocateSpan(command.span, source_offset);
    for (command.assignments) |*word| relocateWordSpans(word, source_offset);
    for (command.argv) |*word| relocateWordSpans(word, source_offset);
    for (command.redirections) |*redirection| relocateRedirectionSpans(redirection, source_offset);
}

fn relocateRedirectionSpans(redirection: *Redirection, source_offset: usize) void {
    redirection.span = relocateSpan(redirection.span, source_offset);
    if (redirection.here_doc_range) |*range| range.* = relocateSpan(range.*, source_offset);
    if (redirection.io_number) |*word| relocateWordSpans(word, source_offset);
    if (redirection.target) |*word| relocateWordSpans(word, source_offset);
}

fn relocateWordSpans(word: *WordRef, source_offset: usize) void {
    word.span = relocateSpan(word.span, source_offset);
}

fn relocateSpan(span: parser.Span, source_offset: usize) parser.Span {
    std.debug.assert(span.start >= source_offset);
    std.debug.assert(span.end >= source_offset);
    return .init(span.start - source_offset, span.end - source_offset);
}

fn collectNestedBodyRanges(allocator: std.mem.Allocator, parsed: parser.ParseResult) !std.ArrayList(parser.Span) {
    var ranges: std.ArrayList(parser.Span) = .empty;
    errdefer ranges.deinit(allocator);
    for (parsed.nodes) |node| {
        if (!isCompoundNode(node.kind)) continue;
        for (parsed.nodeChildren(node)) |child| switch (child) {
            .node => |node_id| {
                const child_node = parsed.nodes[node_id.index()];
                if (node.kind == .function_definition and isFunctionBodyNode(child_node.kind)) {
                    try ranges.append(allocator, child_node.span);
                }
                if (child_node.kind == .list) try ranges.append(allocator, child_node.span);
            },
            .token => {},
        };
    }
    return ranges;
}

fn collectCompoundPipelineStageRanges(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
) !std.ArrayList(parser.Span) {
    var ranges: std.ArrayList(parser.Span) = .empty;
    errdefer ranges.deinit(allocator);
    for (parsed.nodes) |node| {
        if (node.kind != .pipeline) continue;
        for (parsed.nodeChildren(node)) |child| switch (child) {
            .node => |node_id| {
                const child_node = parsed.nodes[node_id.index()];
                if (isCompoundNode(child_node.kind)) try ranges.append(allocator, child_node.span);
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
        .case_item,
        .function_definition,
        .bash_test_command,
        .brace_group,
        .subshell,
        => true,
        else => false,
    };
}

fn isFunctionBodyNode(kind: parser.NodeKind) bool {
    return switch (kind) {
        .if_command,
        .loop_command,
        .for_command,
        .case_command,
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
    try collectDirectHereDocRanges(allocator, parsed, &ranges);
    try collectFunctionBodyHereDocRanges(allocator, parsed, &ranges);
    return ranges;
}

fn collectDirectHereDocRanges(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    ranges: *std.ArrayList(parser.Span),
) !void {
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
            const extraction = try extractHereDocFromBodyStart(
                allocator,
                parsed.source,
                body_start,
                doc.delimiter,
                doc.strip_tabs,
                !doc.quoted,
            );
            defer allocator.free(extraction.body);
            try ranges.append(allocator, extraction.range);
            body_start = extraction.range.end;
        }
    }
}

fn collectFunctionBodyHereDocRanges(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    ranges: *std.ArrayList(parser.Span),
) !void {
    for (parsed.nodes) |node| {
        if (node.kind != .function_definition) continue;
        const function_body = functionBodyTokenRange(parsed, node) orelse continue;
        const body_start = sourceStart(parsed, function_body.start);
        const body_end = sourceEnd(parsed, function_body.end);
        const body = parsed.source[body_start..body_end];
        if (std.mem.indexOf(u8, body, "<<") == null) continue;

        const function_line = sourceLineBounds(parsed.source, node.span.start);
        if (function_line.end >= parsed.source.len) continue;
        const tail_start = function_line.end + 1;
        var synthetic: std.ArrayList(u8) = .empty;
        defer synthetic.deinit(allocator);
        try synthetic.appendSlice(allocator, body);
        if (synthetic.items.len == 0 or synthetic.items[synthetic.items.len - 1] != '\n') {
            try synthetic.append(allocator, '\n');
        }
        const tail_offset = synthetic.items.len;
        try synthetic.appendSlice(allocator, parsed.source[tail_start..]);

        var reparsed = try parser.parse(allocator, synthetic.items, .{});
        defer reparsed.deinit();
        var synthetic_ranges: std.ArrayList(parser.Span) = .empty;
        defer synthetic_ranges.deinit(allocator);
        try collectDirectHereDocRanges(allocator, reparsed, &synthetic_ranges);
        for (synthetic_ranges.items) |range| {
            if (range.start < tail_offset) continue;
            try ranges.append(allocator, .init(
                tail_start + (range.start - tail_offset),
                tail_start + (range.end - tail_offset),
            ));
        }
    }
}

const FunctionBodyTokenRange = struct {
    start: usize,
    end: usize,
};

fn functionBodyTokenRange(parsed: parser.ParseResult, node: parser.Node) ?FunctionBodyTokenRange {
    std.debug.assert(node.kind == .function_definition);
    var body_node: ?parser.Node = null;
    var open_brace: ?usize = null;
    var close_brace: ?usize = null;
    for (parsed.nodeChildren(node)) |child| switch (child) {
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (body_node == null and isFunctionBodyNode(child_node.kind)) body_node = child_node;
        },
        .token => {},
    };
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
    const start = if (open_brace) |index|
        index + 1
    else if (body_node) |body|
        body.token_start
    else
        node.token_end;
    const end = if (open_brace != null)
        close_brace orelse node.token_end
    else if (body_node) |body|
        body.token_end
    else
        node.token_end;
    return .{ .start = start, .end = end };
}

fn spanStartsInRanges(span: parser.Span, ranges: []const parser.Span) bool {
    for (ranges) |range| {
        if (range.touches(span.start) and span.start != range.end) return true;
    }
    return false;
}

fn spanStartsInSkippedRange(
    span: parser.Span,
    here_doc_ranges: []const parser.Span,
    nested_body_ranges: []const parser.Span,
    compound_pipeline_stage_ranges: []const parser.Span,
) bool {
    return spanStartsInRanges(span, here_doc_ranges) or
        spanStartsInRanges(span, nested_body_ranges) or
        spanStartsInRanges(span, compound_pipeline_stage_ranges);
}

const LoweredStatementRef = struct {
    kind: StatementKind,
    index: usize,
    token_start: usize,
    token_end: usize,
};

fn statementSpan(parsed: parser.ParseResult, statement_ref: LoweredStatementRef) parser.Span {
    if (statement_ref.token_start >= statement_ref.token_end) return .empty(parsed.source.len);
    return .init(
        parsed.tokens[statement_ref.token_start].span.start,
        parsed.tokens[statement_ref.token_end - 1].span.end,
    );
}

fn lessThanStatementRef(_: void, a: LoweredStatementRef, b: LoweredStatementRef) bool {
    return a.token_start < b.token_start;
}

fn lowerSubshell(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !Subshell {
    std.debug.assert(node.kind == .subshell);
    const close_paren = directTokenChildMatching(parsed, node, .right_paren, null);

    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }

    const body_end = close_paren orelse node.token_end;
    const body = try ownedBodySource(allocator, parsed, @min(node.token_start + 1, node.token_end), body_end);
    errdefer allocator.free(body);
    return .{
        .span = node.span,
        .body = body,
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn lowerBraceGroup(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !BraceGroup {
    std.debug.assert(node.kind == .brace_group);
    const close_brace = directTokenChildMatching(parsed, node, .word, "}");

    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }

    const body_end = close_brace orelse node.token_end;
    const body = try ownedBodySource(allocator, parsed, @min(node.token_start + 1, node.token_end), body_end);
    errdefer allocator.free(body);
    return .{
        .span = node.span,
        .body = body,
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn directTokenChildMatching(
    parsed: parser.ParseResult,
    node: parser.Node,
    kind: parser.TokenKind,
    lexeme: ?[]const u8,
) ?usize {
    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_id| {
            const token_index = token_id.index();
            const token = parsed.tokens[token_index];
            if (token.kind != kind) continue;
            if (lexeme) |expected| {
                if (!std.mem.eql(u8, token.lexeme(parsed.source), expected)) continue;
            }
            return token_index;
        },
        .node => {},
    };
    return null;
}

fn lowerCompoundRedirections(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    node: parser.Node,
) !std.ArrayList(Redirection) {
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
    std.mem.sort(Redirection, redirections.items, {}, redirectionBefore);
    return redirections;
}

fn redirectionBefore(_: void, left: Redirection, right: Redirection) bool {
    return left.span.start < right.span.start;
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

fn lowerFunctionDefinition(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    node: parser.Node,
) !FunctionDefinition {
    std.debug.assert(node.kind == .function_definition);
    var body_node: ?parser.Node = null;
    var open_brace: ?usize = null;
    var close_brace: ?usize = null;
    for (parsed.nodeChildren(node)) |child| switch (child) {
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (body_node == null and isFunctionBodyNode(child_node.kind)) body_node = child_node;
        },
        .token => {},
    };
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
    const name = try parser.removeLineContinuations(allocator, parsed.tokens[node.token_start].lexeme(parsed.source));
    errdefer allocator.free(name);
    const body_start = if (open_brace) |index|
        index + 1
    else if (body_node) |body|
        body.token_start
    else
        node.token_end;
    const body_end = if (open_brace != null)
        close_brace orelse node.token_end
    else if (body_node) |body|
        body.token_end
    else
        node.token_end;
    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }
    const body = try ownedFunctionBodySource(allocator, parsed, node, body_start, body_end);
    errdefer allocator.free(body);

    return .{
        .span = node.span,
        .name = name,
        .body = body,
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn ownedFunctionBodySource(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    function_node: parser.Node,
    token_start: usize,
    token_end: usize,
) ![]const u8 {
    const body_start = sourceStart(parsed, token_start);
    const body_end = sourceEnd(parsed, token_end);
    const body = parsed.source[body_start..body_end];
    if (std.mem.indexOf(u8, body, "<<") == null) return ownedSourceWithHereDocs(
        allocator,
        parsed,
        body_start,
        body_end,
    );

    const function_line = sourceLineBounds(parsed.source, function_node.span.start);
    var synthetic: std.ArrayList(u8) = .empty;
    defer synthetic.deinit(allocator);
    try synthetic.appendSlice(allocator, body);
    if (synthetic.items.len == 0 or synthetic.items[synthetic.items.len - 1] != '\n') {
        try synthetic.append(allocator, '\n');
    }
    if (function_line.end < parsed.source.len) {
        try synthetic.appendSlice(allocator, parsed.source[function_line.end + 1 ..]);
    }

    var reparsed = try parser.parse(allocator, synthetic.items, .{});
    defer reparsed.deinit();
    return ownedSourceWithHereDocs(allocator, reparsed, 0, body.len);
}

fn lowerCaseCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !CaseCommand {
    std.debug.assert(node.kind == .case_command);
    var word_token: ?usize = null;
    var in_token: ?usize = null;

    for (node.token_start + 1..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        const lexeme = token.lexeme(parsed.source);
        if (word_token == null) {
            word_token = token_index;
        } else if (in_token == null and std.mem.eql(u8, lexeme, "in")) {
            in_token = token_index;
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

    for (parsed.nodeChildren(node)) |child| {
        const child_node = switch (child) {
            .node => |node_id| parsed.nodes[node_id.index()],
            .token => continue,
        };
        if (child_node.kind != .case_item) continue;

        var patterns: std.ArrayList(WordRef) = .empty;
        errdefer {
            for (patterns.items) |pattern| freeWord(allocator, pattern);
            patterns.deinit(allocator);
        }

        var pattern_end: ?usize = null;
        for (child_node.token_start..child_node.token_end) |token_index| {
            const token = parsed.tokens[token_index];
            if (token.kind == .right_paren) {
                pattern_end = token_index;
                break;
            }
            if (token.kind == .word) {
                try patterns.append(allocator, try wordRefFromToken(allocator, parsed, token_index));
            }
        }

        const body_start = if (pattern_end) |token_index| token_index + 1 else child_node.token_end;
        const body_end = if (body_start < child_node.token_end and
            caseArmHasTerminator(parsed.tokens[child_node.token_end - 1].kind))
            child_node.token_end - 1
        else
            child_node.token_end;
        const body = try ownedBodySource(allocator, parsed, body_start, body_end);

        try arms.append(allocator, .{
            .patterns = try patterns.toOwnedSlice(allocator),
            .body = body,
            .fallthrough = child_node.token_end > child_node.token_start and
                parsed.tokens[child_node.token_end - 1].kind == .semicolon_amp,
            .test_next = child_node.token_end > child_node.token_start and
                parsed.tokens[child_node.token_end - 1].kind == .semicolon_amp_amp,
        });
    }

    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }

    return .{
        .span = node.span,
        .word = subject,
        .arms = try arms.toOwnedSlice(allocator),
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn caseArmHasTerminator(kind: parser.TokenKind) bool {
    return kind == .dsemicolon or kind == .semicolon_amp or kind == .semicolon_amp_amp;
}

fn lowerForCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !ForCommand {
    std.debug.assert(node.kind == .for_command);
    var name_token: ?usize = null;
    var in_token: ?usize = null;
    var do_token: ?usize = null;
    var done_token: ?usize = null;
    var previous_word_token: ?usize = null;
    var body_node: ?parser.Node = null;

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_id| {
            const token_index = token_id.index();
            const token = parsed.tokens[token_index];
            if (token.kind != .word) continue;
            const lexeme = token.lexeme(parsed.source);
            if (body_node == null) {
                if (std.mem.eql(u8, lexeme, "for")) continue;
                if (name_token == null) {
                    if (!std.mem.eql(u8, lexeme, "in")) name_token = token_index;
                } else if (in_token == null and std.mem.eql(u8, lexeme, "in")) {
                    in_token = token_index;
                }
                previous_word_token = token_index;
            } else if (done_token == null and std.mem.eql(u8, lexeme, "done")) {
                done_token = token_index;
            }
        },
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (child_node.kind == .list and body_node == null) {
                body_node = child_node;
                do_token = previous_word_token;
            }
        },
    };

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

    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }
    const body = if (body_node) |body_node_value|
        try ownedBodySource(allocator, parsed, body_node_value.token_start, body_node_value.token_end)
    else
        try ownedBodySource(allocator, parsed, @min(do_index + 1, node.token_end), done_index);
    errdefer allocator.free(body);

    return .{
        .span = node.span,
        .name = name,
        .words = try words.toOwnedSlice(allocator),
        .use_positionals = in_token == null,
        .body = body,
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn lowerLoopCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !LoopCommand {
    std.debug.assert(node.kind == .loop_command);
    const opener = parsed.tokens[node.token_start].lexeme(parsed.source);
    var condition_node: ?parser.Node = null;
    var body_node: ?parser.Node = null;
    var do_token: ?usize = null;
    var done_token: ?usize = null;

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (child_node.kind == .list) {
                if (condition_node == null) {
                    condition_node = child_node;
                } else if (body_node == null) {
                    body_node = child_node;
                }
            }
        },
        .token => |token_id| {
            const token_index = token_id.index();
            const token = parsed.tokens[token_index];
            if (token.kind != .word) continue;
            const lexeme = token.lexeme(parsed.source);
            if (do_token == null and std.mem.eql(u8, lexeme, "do")) {
                do_token = token_index;
            } else if (done_token == null and std.mem.eql(u8, lexeme, "done")) {
                done_token = token_index;
            }
        },
    };

    const do_index = do_token orelse node.token_end;
    const done_index = done_token orelse node.token_end;
    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
    }
    const condition = if (condition_node) |condition_node_value|
        try ownedBodySource(allocator, parsed, condition_node_value.token_start, condition_node_value.token_end)
    else
        try ownedBodySource(allocator, parsed, node.token_start + 1, do_index);
    errdefer allocator.free(condition);
    const body = if (body_node) |body_node_value|
        try ownedBodySource(allocator, parsed, body_node_value.token_start, body_node_value.token_end)
    else
        try ownedBodySource(allocator, parsed, @min(do_index + 1, node.token_end), done_index);
    errdefer allocator.free(body);
    return .{
        .span = node.span,
        .kind = if (std.mem.eql(u8, opener, "while")) .while_loop else .until_loop,
        .condition = condition,
        .body = body,
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn lowerIfCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !IfCommand {
    std.debug.assert(node.kind == .if_command);
    var list_sources: std.ArrayList([]const u8) = .empty;
    defer {
        for (list_sources.items) |source| allocator.free(source);
        list_sources.deinit(allocator);
    }
    var has_else_clause = false;

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (child_node.kind != .list) continue;
            try list_sources.append(
                allocator,
                try ownedBodySource(allocator, parsed, child_node.token_start, child_node.token_end),
            );
        },
        .token => |token_id| {
            const token_index = token_id.index();
            const token = parsed.tokens[token_index];
            if (token.kind != .word) continue;
            const lexeme = token.lexeme(parsed.source);
            if (std.mem.eql(u8, lexeme, "else")) has_else_clause = true;
        },
    };

    const branch_source_count = if (has_else_clause and list_sources.items.len != 0)
        list_sources.items.len - 1
    else
        list_sources.items.len;
    const branch_count = branch_source_count / 2;
    const branches = try allocator.alloc(IfBranch, branch_count);
    errdefer {
        for (branches[0..branch_count]) |branch| {
            allocator.free(branch.condition);
            allocator.free(branch.body);
        }
        allocator.free(branches);
    }
    for (branches, 0..) |*branch, index| {
        branch.* = .{
            .condition = list_sources.items[index * 2],
            .body = list_sources.items[index * 2 + 1],
        };
    }
    const else_body = if (has_else_clause and list_sources.items.len != 0) blk: {
        const source = list_sources.items[list_sources.items.len - 1];
        break :blk source;
    } else null;
    list_sources.items.len = 0;
    errdefer if (else_body) |body| allocator.free(body);

    var redirections = try lowerCompoundRedirections(allocator, parsed, node);
    errdefer {
        for (redirections.items) |redirection| freeRedirection(allocator, redirection);
        redirections.deinit(allocator);
        allocator.free(branches);
    }

    return .{
        .span = node.span,
        .branches = branches,
        .else_body = else_body,
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn isListSeparatorToken(kind: parser.TokenKind) bool {
    return switch (kind) {
        .newline, .semicolon, .and_if, .or_if, .ampersand => true,
        else => false,
    };
}

fn ownedBodySource(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    token_start: usize,
    token_end: usize,
) ![]const u8 {
    return ownedSourceWithHereDocs(
        allocator,
        parsed,
        sourceStart(parsed, token_start),
        sourceEnd(parsed, token_end),
    );
}

fn ownedSourceWithHereDocs(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    source_start: usize,
    source_end: usize,
) ![]const u8 {
    std.debug.assert(source_start <= source_end);
    std.debug.assert(source_end <= parsed.source.len);
    const body = parsed.source[source_start..source_end];
    var ranges: std.ArrayList(parser.Span) = .empty;
    defer ranges.deinit(allocator);

    for (parsed.nodes) |node| {
        if (node.kind != .redirection or !isHereDocRedirectionNode(parsed, node)) continue;
        if (node.span.start < source_start or node.span.start >= source_end) continue;
        const here_doc = try extractOrderedHereDocForRedirection(allocator, parsed, node) orelse continue;
        allocator.free(here_doc.body);
        try ranges.append(allocator, here_doc.range);
    }
    std.mem.sort(parser.Span, ranges.items, {}, lessThanSpanStart);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, body);
    for (ranges.items) |range| {
        if (range.end <= source_end) continue;
        if (output.items.len != 0 and output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
        try output.appendSlice(allocator, parsed.source[range.start..range.end]);
    }
    return output.toOwnedSlice(allocator);
}

fn lessThanSpanStart(_: void, left: parser.Span, right: parser.Span) bool {
    return left.start < right.start;
}

fn sourceStart(parsed: parser.ParseResult, token_start: usize) usize {
    if (token_start >= parsed.tokens.len) return parsed.source.len;
    return parsed.tokens[token_start].span.start;
}

fn sourceEnd(parsed: parser.ParseResult, token_end: usize) usize {
    if (token_end == 0 or token_end > parsed.tokens.len) return parsed.source.len;
    return parsed.tokens[token_end - 1].span.end;
}

fn spanSlice(parsed: parser.ParseResult, token_start: usize, token_end: usize) []const u8 {
    if (token_start >= token_end or token_start >= parsed.tokens.len) return "";
    const end_index = @min(token_end, parsed.tokens.len);
    const start = parsed.tokens[token_start].span.start;
    const end = parsed.tokens[end_index - 1].span.end;
    if (end < start) return "";
    return parsed.source[start..end];
}

fn lowerPipeline(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    node: parser.Node,
    command_indexes_by_node: []const usize,
    missing_command: usize,
) !Pipeline {
    var command_indexes: std.ArrayList(usize) = .empty;
    errdefer command_indexes.deinit(allocator);
    var stage_spans: std.ArrayList(parser.Span) = .empty;
    errdefer stage_spans.deinit(allocator);
    var stage_sources: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (stage_sources.items) |source| allocator.free(source);
        stage_sources.deinit(allocator);
    }
    var negated = false;

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_index| {
            const token = parsed.tokens[token_index.index()];
            if (token.kind == .word and std.mem.eql(u8, token.lexeme(parsed.source), "!")) negated = true;
        },
        .node => |child_node_id| {
            const child_node = parsed.nodes[child_node_id.index()];
            try stage_spans.append(allocator, child_node.span);
            try stage_sources.append(
                allocator,
                try ownedSourceWithHereDocs(allocator, parsed, child_node.span.start, child_node.span.end),
            );
            if (child_node.kind == .simple_command) {
                const command_index = command_indexes_by_node[child_node_id.index()];
                std.debug.assert(command_index != missing_command);
                try command_indexes.append(allocator, command_index);
            }
        },
    };

    return .{
        .span = node.span,
        .command_indexes = try command_indexes.toOwnedSlice(allocator),
        .stage_spans = try stage_spans.toOwnedSlice(allocator),
        .stage_sources = try stage_sources.toOwnedSlice(allocator),
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
            result.here_doc_range = here_doc.range;
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
    range: parser.Span,
    quoted: bool,
};

fn extractOrderedHereDocForRedirection(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    node: parser.Node,
) !?OrderedHereDoc {
    const line = sourceLineBounds(parsed.source, node.span.start);
    var pending = try collectPendingHereDocsOnLine(allocator, parsed, line);
    defer pending.deinit(allocator);
    defer freePendingHereDocs(allocator, pending.items);

    var body_start = hereDocBodyStartFromLine(parsed.source, line) orelse return null;
    for (pending.items) |doc| {
        const extraction = try extractHereDocFromBodyStart(
            allocator,
            parsed.source,
            body_start,
            doc.delimiter,
            doc.strip_tabs,
            !doc.quoted,
        );
        body_start = extraction.range.end;
        if (doc.redirection_start == node.span.start) return .{
            .body = extraction.body,
            .range = extraction.range,
            .quoted = doc.quoted,
        };
        allocator.free(extraction.body);
    }
    return null;
}

fn collectPendingHereDocsOnLine(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    line: SourceLine,
) !std.ArrayList(PendingHereDoc) {
    var pending: std.ArrayList(PendingHereDoc) = .empty;
    errdefer {
        freePendingHereDocs(allocator, pending.items);
        pending.deinit(allocator);
    }
    for (parsed.nodes) |node| {
        if (node.kind != .redirection or node.span.start < line.start or node.span.start >= line.end) continue;
        const info = try hereDocInfoForNode(allocator, parsed, node) orelse continue;
        try pending.append(allocator, .{
            .redirection_start = node.span.start,
            .delimiter = info.delimiter,
            .strip_tabs = info.strip_tabs,
            .quoted = info.quoted,
        });
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
    const normalized = try removeLineContinuations(allocator, raw);
    defer allocator.free(normalized);
    return .{
        .delimiter = try expand.quoteRemove(allocator, normalized),
        .strip_tabs = operator == .dless_dash,
        .quoted = wordContainsQuotes(normalized),
    };
}

fn removeLineContinuations(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, raw, "\\\n") == null) return allocator.dupe(u8, raw);

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '\\' and index + 1 < raw.len and raw[index + 1] == '\n') {
            index += 2;
            continue;
        }
        try normalized.append(allocator, raw[index]);
        index += 1;
    }
    return normalized.toOwnedSlice(allocator);
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

fn extractHereDocFromBodyStart(
    allocator: std.mem.Allocator,
    source: []const u8,
    range_start: usize,
    delimiter: []const u8,
    strip_tabs: bool,
    allow_continuation: bool,
) !HereDocExtraction {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var index = range_start;
    var continued = false;
    while (index <= source.len) {
        const raw_line_start = index;
        while (index < source.len and source[index] != '\n') : (index += 1) {}
        const raw_line_end = index;
        // Leading tabs are stripped only at the start of an input line; a
        // physical line joined by backslash-newline continues the previous
        // line, so its tabs are body text.
        const line_start_no_tabs = if (strip_tabs and !continued) blk: {
            var start = raw_line_start;
            while (start < raw_line_end and source[start] == '\t') : (start += 1) {}
            break :blk start;
        } else raw_line_start;
        const line = source[line_start_no_tabs..raw_line_end];
        // A physical line joined to the previous one by backslash-newline
        // is body text and cannot be the delimiter (POSIX XCU 2.7.4).
        if (!continued and std.mem.eql(u8, line, delimiter)) {
            const range_end = if (index < source.len and source[index] == '\n') index + 1 else index;
            return .{ .body = try body.toOwnedSlice(allocator), .range = .init(range_start, range_end) };
        }
        continued = allow_continuation and parser.hasTrailingLineContinuation(line);
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
    var current = line;
    while (true) {
        if (current.end >= source.len) return null;
        if (!parser.hasTrailingLineContinuation(source[current.start..current.end])) return current.end + 1;
        current = sourceLineBounds(source, current.end + 1);
    }
}

fn containsUsize(items: []const usize, needle: usize) bool {
    for (items) |item| if (item == needle) return true;
    return false;
}

fn wordRef(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !WordRef {
    if (node.token_end == node.token_start + 1) return wordRefFromToken(allocator, parsed, node.token_start);
    return wordRefFromSpan(allocator, parsed, node.span);
}

fn wordRefFromToken(allocator: std.mem.Allocator, parsed: parser.ParseResult, token_index: usize) !WordRef {
    const token = parsed.tokens[token_index];
    return wordRefFromSpan(allocator, parsed, token.span);
}

fn wordRefFromSpan(allocator: std.mem.Allocator, parsed: parser.ParseResult, span: parser.Span) !WordRef {
    const raw = try wordRawForExpansion(allocator, parsed.source, span);
    errdefer allocator.free(raw);
    const text = expand.expandWordScalar(allocator, raw, .{}) catch |err| switch (err) {
        error.NounsetParameter,
        error.ParameterExpansionFailed,
        error.ArithmeticExpansionFailed,
        => try allocator.dupe(u8, raw),
        else => return err,
    };
    errdefer allocator.free(text);
    return .{
        .span = span,
        .raw = raw,
        .text = text,
    };
}

fn wordRawForExpansion(allocator: std.mem.Allocator, source: []const u8, span: parser.Span) ![]const u8 {
    const raw = span.slice(source);
    if (!endsWithUnpairedBackslashAtEof(source, span)) return allocator.dupe(u8, raw);

    const normalized = try allocator.alloc(u8, raw.len + 1);
    @memcpy(normalized[0..raw.len], raw);
    normalized[raw.len] = '\\';
    return normalized;
}

fn endsWithUnpairedBackslashAtEof(source: []const u8, span: parser.Span) bool {
    if (span.end != source.len or span.isEmpty() or source[span.end - 1] != '\\') return false;

    var slash_count: usize = 0;
    var index = span.end;
    while (index > span.start and source[index - 1] == '\\') {
        slash_count += 1;
        index -= 1;
    }
    return slash_count % 2 == 1;
}

fn freeSubshell(allocator: std.mem.Allocator, subshell: Subshell) void {
    allocator.free(subshell.body);
    for (subshell.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(subshell.redirections);
}

fn freePipelineStageSources(allocator: std.mem.Allocator, sources: []const []const u8) void {
    for (sources) |source| allocator.free(source);
    allocator.free(sources);
}

fn freeBraceGroup(allocator: std.mem.Allocator, group: BraceGroup) void {
    allocator.free(group.body);
    for (group.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(group.redirections);
}

fn freeFunctionDefinition(allocator: std.mem.Allocator, definition: FunctionDefinition) void {
    allocator.free(definition.name);
    allocator.free(definition.body);
    for (definition.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(definition.redirections);
}

fn freeBashTestCommand(allocator: std.mem.Allocator, command: BashTestCommand) void {
    for (command.args) |arg| freeWord(allocator, arg);
    allocator.free(command.args);
}

fn freeCaseArm(allocator: std.mem.Allocator, arm: CaseArm) void {
    for (arm.patterns) |pattern| freeWord(allocator, pattern);
    allocator.free(arm.patterns);
    allocator.free(arm.body);
}

fn freeCaseCommand(allocator: std.mem.Allocator, command: CaseCommand) void {
    freeWord(allocator, command.word);
    for (command.arms) |arm| freeCaseArm(allocator, arm);
    allocator.free(command.arms);
    for (command.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(command.redirections);
}

fn freeIfCommand(allocator: std.mem.Allocator, command: IfCommand) void {
    for (command.branches) |branch| {
        allocator.free(branch.condition);
        allocator.free(branch.body);
    }
    allocator.free(command.branches);
    if (command.else_body) |body| allocator.free(body);
    for (command.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(command.redirections);
}

fn freeForCommand(allocator: std.mem.Allocator, command: ForCommand) void {
    allocator.free(command.name);
    for (command.words) |word| freeWord(allocator, word);
    allocator.free(command.words);
    allocator.free(command.body);
    for (command.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(command.redirections);
}

fn freeLoopCommand(allocator: std.mem.Allocator, command: LoopCommand) void {
    allocator.free(command.condition);
    allocator.free(command.body);
    for (command.redirections) |redirection| freeRedirection(allocator, redirection);
    allocator.free(command.redirections);
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

test "lower preserves unpaired EOF backslash literals" {
    var parsed = try parser.parse(std.testing.allocator, "echo a\\", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    const command = program.commands[0];
    try std.testing.expectEqualStrings("echo", command.argv[0].text);
    try std.testing.expectEqualStrings("a\\", command.argv[1].text);
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

test "lower compound command redirection preserves io number" {
    var parsed = try parser.parse(std.testing.allocator, "{ echo out; } >both 2>&1", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.brace_groups.len);
    const group = program.brace_groups[0];
    try std.testing.expectEqual(@as(usize, 2), group.redirections.len);
    try std.testing.expectEqual(parser.TokenKind.greater, group.redirections[0].operator);
    try std.testing.expect(group.redirections[0].io_number == null);
    try std.testing.expectEqual(parser.TokenKind.greater_and, group.redirections[1].operator);
    try std.testing.expectEqualStrings("2", group.redirections[1].io_number.?.text);
    try std.testing.expectEqualStrings("1", group.redirections[1].target.?.text);
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
