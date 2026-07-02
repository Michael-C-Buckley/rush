//! Small AST close to the shell grammar.

const std = @import("std");

const source = @import("source.zig");

pub const Program = struct {
    source_id: source.SourceId,
    body: List,

    pub fn validate(self: Program) void {
        self.body.validate();
    }
};

pub const List = struct {
    entries: []const ListEntry = &.{},

    pub fn validate(self: List) void {
        for (self.entries) |entry| entry.validate();
    }
};

pub const ListTerminator = enum {
    sequence,
    background,
};

pub const ListEntry = struct {
    and_or: AndOr,
    terminator: ?ListTerminator = null,

    pub fn validate(self: ListEntry) void {
        self.and_or.validate();
    }
};

pub const AndOrOperator = enum {
    and_if,
    or_if,
};

pub const AndOr = struct {
    pipelines: []const AndOrPipeline,

    pub fn validate(self: AndOr) void {
        std.debug.assert(self.pipelines.len != 0);
        for (self.pipelines, 0..) |pipeline, index| pipeline.validate(index);
    }
};

pub const AndOrPipeline = struct {
    operator: ?AndOrOperator = null,
    pipeline: Pipeline,

    pub fn validate(self: AndOrPipeline, index: usize) void {
        if (index == 0) {
            std.debug.assert(self.operator == null);
        } else {
            std.debug.assert(self.operator != null);
        }
        self.pipeline.validate();
    }
};

pub const Pipeline = struct {
    stages: []const Command,
    negated: bool = false,

    pub fn validate(self: Pipeline) void {
        std.debug.assert(self.stages.len != 0);
        for (self.stages) |stage| stage.validate();
    }
};

pub const Command = union(enum) {
    simple: SimpleCommand,
    compound: CompoundInvocation,
    function_definition: FunctionDefinition,

    pub fn validate(self: Command) void {
        switch (self) {
            .simple => |command| command.validate(),
            .compound => |command| command.validate(),
            .function_definition => |definition| definition.validate(),
        }
    }
};

pub const SimpleCommand = struct {
    assignments: []const Assignment = &.{},
    words: []const Word = &.{},
    redirections: []const Redirection = &.{},
    span: source.Span = .{},

    pub fn validate(self: SimpleCommand) void {
        std.debug.assert(self.assignments.len != 0 or self.words.len != 0 or self.redirections.len != 0);
        self.span.validate();
        for (self.assignments) |assignment| assignment.validate();
        for (self.words) |word| word.validate();
        for (self.redirections) |redirection| redirection.validate();
    }
};

pub const Assignment = struct {
    name: []const u8,
    value: Word,
    append: bool = false,
    span: source.Span = .{},

    pub fn validate(self: Assignment) void {
        std.debug.assert(self.name.len != 0);
        self.value.validate();
        self.span.validate();
    }
};

pub const Word = struct {
    data: WordData,
    span: source.Span = .{},
    quoted: bool = false,

    pub fn validate(self: Word) void {
        self.span.validate();
        self.data.validate();
    }
};

pub const WordData = union(enum) {
    literal: []const u8,
    parts: []const WordPart,

    pub fn validate(self: WordData) void {
        switch (self) {
            .literal => {},
            .parts => |parts| for (parts) |part| part.validate(),
        }
    }
};

pub const WordPart = union(enum) {
    literal: []const u8,
    escaped: []const u8,
    single_quoted: []const u8,
    double_quoted: []const WordPart,
    parameter: ParameterExpansion,
    command_substitution: CommandSubstitution,
    arithmetic: []const u8,

    pub fn validate(self: WordPart) void {
        switch (self) {
            .literal, .escaped, .single_quoted, .arithmetic => {},
            .double_quoted => |parts| for (parts) |part| part.validate(),
            .parameter => |parameter| parameter.validate(),
            .command_substitution => |substitution| substitution.validate(),
        }
    }
};

pub const CommandSubstitution = struct {
    source_text: []const u8,
    parsed: ?*const Program = null,
    line_offset: usize = 0,

    pub fn validate(self: CommandSubstitution) void {
        if (self.parsed) |program| program.validate();
    }
};

pub const Parameter = union(enum) {
    variable: []const u8,
    positional: u32,
    special: SpecialParameter,

    pub fn validate(self: Parameter) void {
        switch (self) {
            .variable => |name| std.debug.assert(name.len != 0),
            .positional, .special => {},
        }
    }
};

pub const SpecialParameter = enum {
    at,
    star,
    hash,
    question,
    hyphen,
    dollar,
    bang,
};

pub const ParameterExpansion = struct {
    parameter: Parameter,
    length: bool = false,
    colon: bool = false,
    op: ?ParameterOperator = null,
    word: ?Word = null,
    span: source.Span = .{},

    pub fn validate(self: ParameterExpansion) void {
        self.parameter.validate();
        self.span.validate();
        if (self.op == null) {
            std.debug.assert(!self.colon);
            std.debug.assert(self.word == null);
        }
        if (self.length) std.debug.assert(self.op == null);
        if (self.word) |word| word.validate();
    }
};

pub const ParameterOperator = enum {
    default_value,
    assign_default,
    error_if_unset,
    alternate_value,
    remove_small_prefix,
    remove_large_prefix,
    remove_small_suffix,
    remove_large_suffix,
};

pub const Redirection = struct {
    fd: ?u31 = null,
    op: RedirectionOperator,
    target: Word,
    here_doc: ?HereDoc = null,
    span: source.Span = .{},

    pub fn validate(self: Redirection) void {
        self.target.validate();
        self.span.validate();
        switch (self.op) {
            .here_doc, .here_doc_strip_tabs => std.debug.assert(self.here_doc != null),
            else => std.debug.assert(self.here_doc == null),
        }
        if (self.here_doc) |here_doc| here_doc.validate(self.op);
    }
};

pub const RedirectionOperator = enum {
    input,
    output,
    append,
    output_and_error,
    append_and_error,
    read_write,
    duplicate_input,
    duplicate_output,
    here_doc,
    here_doc_strip_tabs,
    here_string,
    clobber,
};

pub const HereDoc = struct {
    body: []const u8,
    delimiter_quoted: bool = false,
    /// Body parsed into word parts for evaluation-time expansion; empty
    /// when the delimiter was quoted and the body is taken literally.
    parts: []const WordPart = &.{},

    pub fn validate(self: HereDoc, op: RedirectionOperator) void {
        std.debug.assert(op == .here_doc or op == .here_doc_strip_tabs);
        if (self.delimiter_quoted) std.debug.assert(self.parts.len == 0);
    }
};

pub const CompoundInvocation = struct {
    body: CompoundCommand,
    redirections: []const Redirection = &.{},

    pub fn validate(self: CompoundInvocation) void {
        self.body.validate();
        for (self.redirections) |redirection| redirection.validate();
    }
};

pub const CompoundCommand = union(enum) {
    brace_group: List,
    subshell: List,
    if_command: IfCommand,
    loop: LoopCommand,
    for_command: ForCommand,
    c_for_command: CForCommand,
    arithmetic_command: ArithmeticCommand,
    case_command: CaseCommand,

    pub fn validate(self: CompoundCommand) void {
        switch (self) {
            .brace_group, .subshell => |list| list.validate(),
            .if_command => |command| command.validate(),
            .loop => |command| command.validate(),
            .for_command => |command| command.validate(),
            .c_for_command => |command| command.validate(),
            .arithmetic_command => |command| command.validate(),
            .case_command => |command| command.validate(),
        }
    }
};

pub const IfBranch = struct {
    condition: List,
    body: List,

    pub fn validate(self: IfBranch) void {
        self.condition.validate();
        self.body.validate();
    }
};

pub const IfCommand = struct {
    branches: []const IfBranch,
    else_body: ?List = null,

    pub fn validate(self: IfCommand) void {
        std.debug.assert(self.branches.len != 0);
        for (self.branches) |branch| branch.validate();
        if (self.else_body) |body| body.validate();
    }
};

pub const LoopKind = enum {
    while_loop,
    until_loop,
};

pub const LoopCommand = struct {
    kind: LoopKind,
    condition: List,
    body: List,

    pub fn validate(self: LoopCommand) void {
        self.condition.validate();
        self.body.validate();
    }
};

pub const ForWords = union(enum) {
    positional_parameters,
    words: []const Word,

    pub fn validate(self: ForWords) void {
        switch (self) {
            .positional_parameters => {},
            .words => |words| for (words) |word| word.validate(),
        }
    }
};

pub const ForCommand = struct {
    name: []const u8,
    words: ForWords = .positional_parameters,
    body: List,

    pub fn validate(self: ForCommand) void {
        std.debug.assert(self.name.len != 0);
        self.words.validate();
        self.body.validate();
    }
};

pub const CForCommand = struct {
    init: ?[]const u8 = null,
    condition: ?[]const u8 = null,
    update: ?[]const u8 = null,
    body: List,

    pub fn validate(self: CForCommand) void {
        self.body.validate();
    }
};

pub const ArithmeticCommand = struct {
    expression: []const u8,

    pub fn validate(self: ArithmeticCommand) void {
        _ = self;
    }
};

pub const CaseArm = struct {
    patterns: []const Word,
    body: List,
    fallthrough: Fallthrough = .none,

    pub fn validate(self: CaseArm) void {
        std.debug.assert(self.patterns.len != 0);
        for (self.patterns) |pattern| pattern.validate();
        self.body.validate();
    }
};

pub const Fallthrough = enum {
    none,
    execute_next,
    test_next,
};

pub const CaseCommand = struct {
    word: Word,
    arms: []const CaseArm,

    pub fn validate(self: CaseCommand) void {
        self.word.validate();
        for (self.arms) |arm| arm.validate();
    }
};

pub const FunctionDefinition = struct {
    name: []const u8,
    body: CompoundCommand,
    redirections: []const Redirection = &.{},

    pub fn validate(self: FunctionDefinition) void {
        std.debug.assert(self.name.len != 0);
        self.body.validate();
        for (self.redirections) |redirection| redirection.validate();
    }
};

test "AST models list, and-or, and pipeline as distinct grammar levels" {
    const words = [_]Word{.{ .data = .{ .literal = ":" } }};
    const stages = [_]Command{.{ .simple = .{ .words = &words } }};
    const pipeline: Pipeline = .{ .stages = &stages };
    const and_or_pipelines = [_]AndOrPipeline{.{ .pipeline = pipeline }};
    const list_entries = [_]ListEntry{.{ .and_or = .{ .pipelines = &and_or_pipelines } }};
    const program: Program = .{ .source_id = 1, .body = .{ .entries = &list_entries } };

    program.validate();
}
