//! Small AST close to the shell grammar.

const source = @import("source.zig");

pub const Program = struct {
    source_id: source.SourceId,
    body: List,
};

pub const List = struct {
    entries: []const ListEntry = &.{},
};

pub const ListOperator = enum {
    sequence,
    background,
};

pub const ListEntry = struct {
    pipeline: Pipeline,
    operator: ?ListOperator = null,
};

pub const AndOrOperator = enum {
    and_if,
    or_if,
};

pub const Pipeline = struct {
    commands: []const PipelineCommand = &.{},
    negated: bool = false,
};

pub const PipelineCommand = struct {
    operator: ?AndOrOperator = null,
    command: Command,
};

pub const Command = union(enum) {
    simple: SimpleCommand,
    compound: CompoundCommand,
    function_definition: FunctionDefinition,
};

pub const SimpleCommand = struct {
    assignments: []const Assignment = &.{},
    words: []const Word = &.{},
    redirections: []const Redirection = &.{},
    span: source.Span = .{},
};

pub const Assignment = struct {
    name: []const u8,
    value: Word,
    span: source.Span = .{},
};

pub const Word = struct {
    parts: []const WordPart = &.{},
    span: source.Span = .{},
};

pub const WordPart = union(enum) {
    literal: []const u8,
    single_quoted: []const u8,
    double_quoted: []const WordPart,
    parameter: ParameterExpansion,
    command_substitution: []const u8,
    arithmetic: []const u8,
};

pub const ParameterExpansion = struct {
    name: []const u8,
    op: ?ParameterOperator = null,
    word: ?Word = null,
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
    span: source.Span = .{},
};

pub const RedirectionOperator = enum {
    input,
    output,
    append,
    read_write,
    duplicate_input,
    duplicate_output,
    here_doc,
    here_doc_strip_tabs,
    clobber,
};

pub const CompoundCommand = union(enum) {
    brace_group: List,
    subshell: List,
    if_command: IfCommand,
    loop: LoopCommand,
    for_command: ForCommand,
    case_command: CaseCommand,
};

pub const IfBranch = struct {
    condition: List,
    body: List,
};

pub const IfCommand = struct {
    branches: []const IfBranch,
    else_body: ?List = null,
};

pub const LoopKind = enum {
    while_loop,
    until_loop,
};

pub const LoopCommand = struct {
    kind: LoopKind,
    condition: List,
    body: List,
};

pub const ForWords = union(enum) {
    positional_parameters,
    words: []const Word,
};

pub const ForCommand = struct {
    name: []const u8,
    words: ForWords = .positional_parameters,
    body: List,
};

pub const CaseArm = struct {
    patterns: []const Word,
    body: List,
    fallthrough: Fallthrough = .none,
};

pub const Fallthrough = enum {
    none,
    execute_next,
    test_next,
};

pub const CaseCommand = struct {
    word: Word,
    arms: []const CaseArm,
};

pub const FunctionDefinition = struct {
    name: []const u8,
    body: CompoundCommand,
    redirections: []const Redirection = &.{},
};
