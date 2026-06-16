//! Side-effect-free semantic command plans.
//!
//! `CommandPlan` is the core representation after parser/IR interpretation and
//! expansion and before runtime effects. It classifies expanded simple commands
//! without executing builtins, applying redirections, resolving the filesystem,
//! or mutating shell state.

const std = @import("std");
const default_builtins = @import("../builtins.zig");
const builtin = @import("builtin.zig");
const context = @import("context.zig");
const ir = @import("ir.zig");
const redirection_plan = @import("redirection_plan.zig");
const state = @import("state.zig");

pub const Assignment = struct {
    name: []const u8,
    value: []const u8,

    pub fn validate(self: Assignment) void {
        state.assertValidVariableName(self.name);
    }
};

pub const FunctionDefinition = struct {
    name: []const u8,
    /// Eagerly lowered semantic body used by older unit tests and by manually
    /// constructed semantic plans.
    body: FunctionBody = .{},
    /// Parser-backed function body source. When present, the body is lowered
    /// at call time so parameter, variable, glob, and redirection expansion see
    /// the function invocation state rather than the definition state.
    source_body: ?[]const u8 = null,
    redirections: redirection_plan.RedirectionPlan = .{},

    pub fn validate(self: FunctionDefinition) void {
        state.assertValidVariableName(self.name);
        self.body.validate();
        if (self.source_body) |source_body| {
            std.debug.assert(std.mem.indexOfScalar(u8, source_body, 0) == null);
        }
        validateRedirections(self.redirections);
    }

    pub fn hasExecutableBody(self: FunctionDefinition) bool {
        self.validate();
        return self.source_body != null or self.body.statements.len != 0 or self.body.commands.len != 0;
    }
};

pub const FunctionBody = StatementList;

pub const CommandList = struct {
    commands: []const CommandPlan = &.{},

    pub fn validate(self: CommandList) void {
        for (self.commands) |command| command.validate();
    }
};

pub const IfBranch = struct {
    condition: StatementList,
    body: StatementList,

    pub fn validate(self: IfBranch) void {
        self.condition.validate();
        self.body.validate();
    }
};

pub const IfPlan = struct {
    branches: []const IfBranch,
    else_body: StatementList = .{},

    pub fn validate(self: IfPlan) void {
        std.debug.assert(self.branches.len != 0);
        for (self.branches) |branch| branch.validate();
        self.else_body.validate();
    }
};

pub const LoopPlan = struct {
    condition_source: ?[]const u8 = null,
    condition: StatementList,
    body_source: ?[]const u8 = null,
    body: StatementList,

    pub fn validate(self: LoopPlan) void {
        if (self.condition_source) |source| std.debug.assert(std.mem.indexOfScalar(u8, source, 0) == null);
        self.condition.validate();
        if (self.body_source) |source| std.debug.assert(std.mem.indexOfScalar(u8, source, 0) == null);
        self.body.validate();
    }
};

pub const AndOrOperator = enum {
    and_if,
    or_if,
};

pub const AndOrCommand = struct {
    operator: ?AndOrOperator = null,
    command: CommandPlan,

    pub fn validate(self: AndOrCommand, index: usize) void {
        if (index == 0) {
            std.debug.assert(self.operator == null);
        } else {
            std.debug.assert(self.operator != null);
        }
        self.command.validate();
    }
};

pub const AndOrPlan = struct {
    commands: []const AndOrCommand,

    pub fn validate(self: AndOrPlan) void {
        std.debug.assert(self.commands.len != 0);
        for (self.commands, 0..) |command, index| command.validate(index);
    }
};

pub const NegationPlan = struct {
    body: StatementList,

    pub fn validate(self: NegationPlan) void {
        self.body.validate();
    }
};

pub const ForWords = union(enum) {
    explicit: []const []const u8,
    positional_parameters,

    pub fn validate(self: ForWords) void {
        switch (self) {
            .explicit => |words| for (words) |word| std.debug.assert(std.mem.indexOfScalar(u8, word, 0) == null),
            .positional_parameters => {},
        }
    }
};

pub const ForPlan = struct {
    variable_name: []const u8,
    words: ForWords = .positional_parameters,
    /// Parser-backed loop body source. When present, the loop body is lowered
    /// for each iteration after the loop variable has been assigned.
    body_source: ?[]const u8 = null,
    body: StatementList,

    pub fn validate(self: ForPlan) void {
        state.assertValidVariableName(self.variable_name);
        self.words.validate();
        if (self.body_source) |source| std.debug.assert(std.mem.indexOfScalar(u8, source, 0) == null);
        self.body.validate();
    }
};

pub const CaseArm = struct {
    patterns: []const []const u8,
    body: StatementList,
    fallthrough: bool = false,
    test_next: bool = false,

    pub fn validate(self: CaseArm) void {
        std.debug.assert(self.patterns.len != 0);
        std.debug.assert(!(self.fallthrough and self.test_next));
        for (self.patterns) |pattern| std.debug.assert(std.mem.indexOfScalar(u8, pattern, 0) == null);
        self.body.validate();
    }
};

pub const CasePlan = struct {
    word: []const u8,
    arms: []const CaseArm,

    pub fn validate(self: CasePlan) void {
        std.debug.assert(std.mem.indexOfScalar(u8, self.word, 0) == null);
        for (self.arms) |arm| arm.validate();
    }
};

pub const CompoundBody = union(enum) {
    sequence: StatementList,
    and_or_list: AndOrPlan,
    negation: NegationPlan,
    brace_group: StatementList,
    subshell: StatementList,
    if_clause: IfPlan,
    while_loop: LoopPlan,
    until_loop: LoopPlan,
    for_loop: ForPlan,
    case_clause: CasePlan,

    pub fn validate(self: CompoundBody) void {
        switch (self) {
            .sequence => |list| list.validate(),
            .and_or_list => |and_or| and_or.validate(),
            .negation => |negation| negation.validate(),
            .brace_group => |list| list.validate(),
            .subshell => |list| list.validate(),
            .if_clause => |if_plan| if_plan.validate(),
            .while_loop => |loop| loop.validate(),
            .until_loop => |loop| loop.validate(),
            .for_loop => |for_plan| for_plan.validate(),
            .case_clause => |case_plan| case_plan.validate(),
        }
    }
};

pub const CompoundCommandPlan = struct {
    target: context.ExecutionTarget,
    redirections: redirection_plan.RedirectionPlan = .{},
    body: CompoundBody,

    pub fn validate(self: CompoundCommandPlan) void {
        validateRedirections(self.redirections);
        self.body.validate();
        if (self.body == .subshell) std.debug.assert(self.target == .subshell or self.target == .child_process);
    }

    pub fn kindName(self: CompoundCommandPlan) []const u8 {
        self.validate();
        return switch (self.body) {
            .sequence => "list",
            .and_or_list => "and-or list",
            .negation => "negation",
            .brace_group => "brace group",
            .subshell => "subshell",
            .if_clause => "if",
            .while_loop => "while",
            .until_loop => "until",
            .for_loop => "for",
            .case_clause => "case",
        };
    }
};

pub const StatementListOperator = enum {
    sequence,
    and_if,
    or_if,
};

pub const StatementPlan = union(enum) {
    simple: CommandPlan,
    compound: CompoundCommandPlan,
    pipeline: PipelinePlan,
    source: SourceStatementPlan,
    ir_source: IrStatementPlan,

    pub fn validate(self: StatementPlan) void {
        switch (self) {
            .simple => |plan| plan.validate(),
            .compound => |plan| plan.validate(),
            .pipeline => |plan| plan.validate(),
            .source => |plan| plan.validate(),
            .ir_source => |plan| plan.validate(),
        }
    }
};

pub const SourceStatementPlan = struct {
    target: context.ExecutionTarget,
    source: []const u8,
    line: usize = 0,
    targets_stdout: bool = false,
    targets_stderr: bool = false,

    pub fn validate(self: SourceStatementPlan) void {
        std.debug.assert(self.target.allowsShellStateCommit());
        std.debug.assert(self.source.len != 0);
        std.debug.assert(std.mem.indexOfScalar(u8, self.source, 0) == null);
    }
};

pub const IrStatementPlan = struct {
    target: context.ExecutionTarget,
    program: *const ir.Program,
    statement_index: usize,
    fallback_source: []const u8,
    line: usize = 0,
    targets_stdout: bool = false,
    targets_stderr: bool = false,

    pub fn validate(self: IrStatementPlan) void {
        std.debug.assert(self.target.allowsShellStateCommit());
        std.debug.assert(self.statement_index < self.program.statements.len);
        std.debug.assert(self.fallback_source.len != 0);
        std.debug.assert(std.mem.indexOfScalar(u8, self.fallback_source, 0) == null);
    }
};

pub const StatementListEntry = struct {
    op_before: StatementListOperator = .sequence,
    plan: StatementPlan,

    pub fn validate(self: StatementListEntry, index: usize) void {
        if (index == 0) std.debug.assert(self.op_before == .sequence);
        self.plan.validate();
    }
};

pub const StatementList = struct {
    statements: []const StatementListEntry = &.{},
    /// Compatibility for simple-only semantic lists constructed by older unit
    /// tests and callers. Parser-backed lowering writes `statements` so
    /// heterogeneous lists can carry simple, compound, and pipeline plans.
    commands: []const CommandPlan = &.{},

    pub fn validate(self: StatementList) void {
        std.debug.assert(self.statements.len == 0 or self.commands.len == 0);
        for (self.statements, 0..) |statement, index| statement.validate(index);
        for (self.commands) |command| command.validate();
    }
};

pub const PipelineStatusRule = enum {
    last_command,
    pipefail,
};

pub const PipelineBackgroundMode = enum {
    foreground,
    background,
};

pub const PipelineExecutionStrategy = enum {
    /// A syntactic pipeline with one stage. The stage keeps its own target, so
    /// current-shell builtins/functions still mutate the current shell.
    single_stage,
    /// Every stage is an external command without shell-managed redirections,
    /// so the runtime can wire real host pipes before spawning children.
    external_only_real,
    /// Shell-implemented stages only. Stages are evaluated in isolated
    /// subshell snapshots and only statuses/output diagnostics cross back.
    semantic_in_memory,
    /// Mixed shell/external stages or stage redirections streamed through the
    /// semantic/runtime boundary with bounded in-memory byte buffers.
    mixed_in_memory,
    /// Async/background pipelines require job ownership in a later slice. This
    /// strategy reserves the semantic decision without implementing job control.
    background_deferred,
};

pub const PipelineOptions = struct {
    negated: bool = false,
    status_rule: PipelineStatusRule = .last_command,
    background: PipelineBackgroundMode = .foreground,
};

pub const PipelineStagePlan = union(enum) {
    simple: CommandPlan,
    compound: CompoundCommandPlan,

    pub fn validate(self: PipelineStagePlan) void {
        switch (self) {
            .simple => |plan| plan.validate(),
            .compound => |plan| plan.validate(),
        }
    }

    pub fn target(self: PipelineStagePlan) context.ExecutionTarget {
        self.validate();
        return switch (self) {
            .simple => |plan| plan.target,
            .compound => |plan| plan.target,
        };
    }

    pub fn isExternalOnlyRealEligible(self: PipelineStagePlan) bool {
        self.validate();
        return switch (self) {
            .simple => |plan| plan.class() == .external and !hasSimpleRedirections(plan),
            .compound => false,
        };
    }

    pub fn isExternal(self: PipelineStagePlan) bool {
        self.validate();
        return switch (self) {
            .simple => |plan| plan.class() == .external,
            .compound => false,
        };
    }
};

pub const PipelinePlan = struct {
    stages: []const PipelineStagePlan,
    negated: bool = false,
    status_rule: PipelineStatusRule = .last_command,
    background: PipelineBackgroundMode = .foreground,
    strategy: PipelineExecutionStrategy,

    pub fn init(stages: []const PipelineStagePlan, options: PipelineOptions) PipelinePlan {
        std.debug.assert(stages.len != 0);
        for (stages) |stage| stage.validate();
        const plan: PipelinePlan = .{
            .stages = stages,
            .negated = options.negated,
            .status_rule = options.status_rule,
            .background = options.background,
            .strategy = choosePipelineStrategy(stages, options.background),
        };
        plan.validate();
        return plan;
    }

    pub fn validate(self: PipelinePlan) void {
        std.debug.assert(self.stages.len != 0);
        for (self.stages, 0..) |stage, index| {
            stage.validate();
            const target = self.stageTarget(index);
            if (self.stages.len > 1) std.debug.assert(target != .current_shell);
            if (stage.isExternal()) std.debug.assert(target == .child_process);
        }
        std.debug.assert(self.pipeCount() == self.stages.len - 1);
        std.debug.assert(self.strategy == choosePipelineStrategy(self.stages, self.background));
        switch (self.strategy) {
            .single_stage => std.debug.assert(self.stages.len == 1 and self.background == .foreground),
            .external_only_real => {
                std.debug.assert(self.stages.len > 1);
                std.debug.assert(self.background == .foreground);
                for (self.stages) |stage| std.debug.assert(stage.isExternalOnlyRealEligible());
            },
            .semantic_in_memory => {
                std.debug.assert(self.stages.len > 1);
                std.debug.assert(self.background == .foreground);
                for (self.stages) |stage| std.debug.assert(!stage.isExternal());
            },
            .mixed_in_memory => {
                std.debug.assert(self.stages.len > 1);
                std.debug.assert(self.background == .foreground);
            },
            .background_deferred => std.debug.assert(self.background == .background),
        }
    }

    pub fn pipeCount(self: PipelinePlan) usize {
        self.validateStagesOnly();
        return self.stages.len - 1;
    }

    pub fn stageTarget(self: PipelinePlan, index: usize) context.ExecutionTarget {
        self.validateStagesOnly();
        std.debug.assert(index < self.stages.len);
        const stage = self.stages[index];
        if (self.stages.len == 1) return stage.target();
        if (stage.isExternal()) return .child_process;
        return .subshell;
    }

    pub fn validateStatusCount(self: PipelinePlan, statuses: []const state.ExitStatus) void {
        self.validate();
        std.debug.assert(statuses.len == self.stages.len);
    }

    fn validateStagesOnly(self: PipelinePlan) void {
        std.debug.assert(self.stages.len != 0);
        for (self.stages) |stage| stage.validate();
    }
};

pub const StatusAggregationInput = struct {
    stage_count: usize,
    statuses: []const state.ExitStatus,
    status_rule: PipelineStatusRule = .last_command,
    negated: bool = false,

    pub fn validate(self: StatusAggregationInput) void {
        std.debug.assert(self.stage_count != 0);
        std.debug.assert(self.statuses.len == self.stage_count);
    }
};

pub const StatusAggregation = struct {
    selected_status: state.ExitStatus,
    final_status: state.ExitStatus,

    pub fn validate(self: StatusAggregation) void {
        if (self.selected_status == 0) {
            std.debug.assert(self.final_status == 0 or self.final_status == 1);
        }
    }
};

pub fn aggregateStatus(input: StatusAggregationInput) StatusAggregation {
    input.validate();
    const selected = switch (input.status_rule) {
        .last_command => input.statuses[input.statuses.len - 1],
        .pipefail => pipefailStatus(input.statuses),
    };
    const final = if (input.negated) negateStatus(selected) else selected;
    const aggregation: StatusAggregation = .{ .selected_status = selected, .final_status = final };
    aggregation.validate();
    return aggregation;
}

pub const ExternalResolution = struct {
    name: []const u8,
    path: []const u8,

    pub fn validate(self: ExternalResolution) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.path.len != 0);
    }
};

pub const NotFound = struct {
    name: []const u8,
};

pub const CommandClass = enum {
    empty,
    assignment_only,
    special_builtin,
    regular_builtin,
    function_definition,
    function,
    external,
    not_found,
};

pub const AssignmentEffect = enum {
    none,
    persistent,
    temporary,
};

pub const Classification = union(CommandClass) {
    /// No command name and no assignments. Redirections, if present, are kept
    /// as data for later redirection planning/evaluation tasks.
    empty: void,
    assignment_only: void,
    special_builtin: builtin.Builtin,
    regular_builtin: builtin.Builtin,
    function_definition: FunctionDefinition,
    function: FunctionDefinition,
    external: ExternalResolution,
    not_found: NotFound,
};

pub const ExpandedSimpleCommand = struct {
    assignments: []const Assignment = &.{},
    argv: []const []const u8 = &.{},
    redirections: redirection_plan.RedirectionPlan = .{},
    last_command_substitution_status: ?state.ExitStatus = null,
    expansion_stderr: []const u8 = "",
    expansion_diagnostics: []const []const u8 = &.{},

    pub fn validate(self: ExpandedSimpleCommand) void {
        for (self.assignments) |assignment| assignment.validate();
        validateRedirections(self.redirections);
        std.debug.assert(std.mem.indexOfScalar(u8, self.expansion_stderr, 0) == null);
        for (self.expansion_diagnostics) |message| {
            std.debug.assert(message.len != 0);
            std.debug.assert(std.mem.indexOfScalar(u8, message, 0) == null);
        }
    }
};

pub const LookupSnapshot = struct {
    builtins: []const builtin.Builtin = default_builtins.default_registry,
    functions: []const FunctionDefinition = &.{},
    externals: []const ExternalResolution = &.{},

    pub fn validate(self: LookupSnapshot) void {
        builtin.assertUniqueNames(self.builtins);
        assertUniqueFunctionNames(self.functions);
        assertUniqueExternalNames(self.externals);
    }

    pub fn findSpecialBuiltin(self: LookupSnapshot, name: []const u8) ?builtin.Builtin {
        return self.findBuiltinWithKind(name, .special);
    }

    pub fn findRegularBuiltin(self: LookupSnapshot, name: []const u8) ?builtin.Builtin {
        return self.findBuiltinWithKind(name, .regular);
    }

    pub fn findFunction(self: LookupSnapshot, name: []const u8) ?FunctionDefinition {
        for (self.functions) |definition| {
            definition.validate();
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    pub fn findExternal(self: LookupSnapshot, name: []const u8) ?ExternalResolution {
        for (self.externals) |resolution| {
            resolution.validate();
            if (std.mem.eql(u8, resolution.name, name)) return resolution;
        }
        return null;
    }

    fn findBuiltinWithKind(self: LookupSnapshot, name: []const u8, kind: builtin.BuiltinKind) ?builtin.Builtin {
        for (self.builtins) |definition| {
            definition.validate();
            if (definition.kind == kind and std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }
};

pub const PlanRequest = struct {
    command: ExpandedSimpleCommand = .{},
    lookup: LookupSnapshot = .{},
    /// Target selected by the enclosing semantic context for commands that do
    /// not inherently require child execution. External commands are always
    /// planned for a child process because their shell-state mutations cannot
    /// land in the parent shell.
    target: context.ExecutionTarget = .current_shell,

    pub fn validate(self: PlanRequest) void {
        self.command.validate();
        self.lookup.validate();
    }
};

pub const CommandPlan = struct {
    target: context.ExecutionTarget,
    assignments: []const Assignment = &.{},
    argv: []const []const u8 = &.{},
    redirections: redirection_plan.RedirectionPlan = .{},
    last_command_substitution_status: ?state.ExitStatus = null,
    expansion_stderr: []const u8 = "",
    expansion_diagnostics: []const []const u8 = &.{},
    classification: Classification,

    pub fn classify(request: PlanRequest) CommandPlan {
        request.validate();

        const command = request.command;
        const classification: Classification = if (command.argv.len == 0) blk: {
            if (command.assignments.len == 0) break :blk .{ .empty = {} };
            break :blk .{ .assignment_only = {} };
        } else blk: {
            const name = command.argv[0];
            if (!containsSlash(name)) {
                if (request.lookup.findSpecialBuiltin(name)) |definition| break :blk .{ .special_builtin = definition };
                if (request.lookup.findFunction(name)) |definition| break :blk .{ .function = definition };
                if (request.lookup.findRegularBuiltin(name)) |definition| break :blk .{ .regular_builtin = definition };
            }
            if (request.lookup.findExternal(name)) |resolution| break :blk .{ .external = resolution };
            break :blk .{ .not_found = .{ .name = name } };
        };

        const plan: CommandPlan = .{
            .target = targetForClassification(request.target, classification),
            .assignments = command.assignments,
            .argv = command.argv,
            .redirections = command.redirections,
            .last_command_substitution_status = command.last_command_substitution_status,
            .expansion_stderr = command.expansion_stderr,
            .expansion_diagnostics = command.expansion_diagnostics,
            .classification = classification,
        };
        plan.validate();
        return plan;
    }

    pub fn class(self: CommandPlan) CommandClass {
        return switch (self.classification) {
            .empty => .empty,
            .assignment_only => .assignment_only,
            .special_builtin => .special_builtin,
            .regular_builtin => .regular_builtin,
            .function_definition => .function_definition,
            .function => .function,
            .external => .external,
            .not_found => .not_found,
        };
    }

    pub fn assignmentEffect(self: CommandPlan) AssignmentEffect {
        self.validate();
        if (self.assignments.len == 0) return .none;

        return switch (self.classification) {
            .empty => .none,
            .assignment_only, .special_builtin => .persistent,
            .function_definition => .none,
            .regular_builtin, .function, .external, .not_found => .temporary,
        };
    }

    pub fn validate(self: CommandPlan) void {
        for (self.assignments) |assignment| assignment.validate();
        validateRedirections(self.redirections);
        std.debug.assert(std.mem.indexOfScalar(u8, self.expansion_stderr, 0) == null);
        for (self.expansion_diagnostics) |message| {
            std.debug.assert(message.len != 0);
            std.debug.assert(std.mem.indexOfScalar(u8, message, 0) == null);
        }

        switch (self.classification) {
            .empty => {
                std.debug.assert(self.argv.len == 0);
                std.debug.assert(self.assignments.len == 0);
            },
            .assignment_only => {
                std.debug.assert(self.argv.len == 0);
                std.debug.assert(self.assignments.len != 0);
            },
            .special_builtin => |definition| {
                definition.validate();
                assertResolvedCommand(self.argv, definition.name);
                std.debug.assert(definition.kind == .special);
            },
            .regular_builtin => |definition| {
                definition.validate();
                assertResolvedCommand(self.argv, definition.name);
                std.debug.assert(definition.kind == .regular);
            },
            .function_definition => |definition| {
                definition.validate();
                std.debug.assert(self.argv.len == 0);
                std.debug.assert(self.assignments.len == 0);
                std.debug.assert(self.redirections.steps.len == 0);
                std.debug.assert(self.redirections.rollback_steps.len == 0);
            },
            .function => |definition| {
                definition.validate();
                assertResolvedCommand(self.argv, definition.name);
            },
            .external => |resolution| {
                resolution.validate();
                assertResolvedCommand(self.argv, resolution.name);
                std.debug.assert(self.target == .child_process);
            },
            .not_found => |not_found| {
                std.debug.assert(self.argv.len != 0);
                std.debug.assert(std.mem.eql(u8, self.argv[0], not_found.name));
            },
        }
    }
};

pub fn classifyExpandedSimpleCommand(request: PlanRequest) CommandPlan {
    return CommandPlan.classify(request);
}

pub fn cloneFunctionDefinition(
    allocator: std.mem.Allocator,
    definition: FunctionDefinition,
) std.mem.Allocator.Error!FunctionDefinition {
    definition.validate();
    const owned_name = try allocator.dupe(u8, definition.name);
    errdefer allocator.free(owned_name);
    const owned_body = try cloneStatementList(allocator, definition.body);
    errdefer freeStatementList(allocator, owned_body);
    const owned_source_body = if (definition.source_body) |source_body| try allocator.dupe(u8, source_body) else null;
    errdefer if (owned_source_body) |source_body| allocator.free(source_body);
    var owned_redirections = try definition.redirections.clone(allocator);
    errdefer owned_redirections.deinit();
    return .{
        .name = owned_name,
        .body = owned_body,
        .source_body = owned_source_body,
        .redirections = owned_redirections,
    };
}

pub fn freeFunctionDefinition(allocator: std.mem.Allocator, definition: FunctionDefinition) void {
    allocator.free(definition.name);
    freeStatementList(allocator, definition.body);
    if (definition.source_body) |source_body| allocator.free(source_body);
    var redirections = definition.redirections;
    redirections.deinit();
}

fn targetForClassification(
    default_target: context.ExecutionTarget,
    classification: Classification,
) context.ExecutionTarget {
    return switch (classification) {
        .external => .child_process,
        else => default_target,
    };
}

fn containsSlash(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '/') != null;
}

fn assertResolvedCommand(argv: []const []const u8, name: []const u8) void {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], name));
}

fn validateRedirections(redirections: redirection_plan.RedirectionPlan) void {
    redirections.validate();
}

fn assertUniqueFunctionNames(functions: []const FunctionDefinition) void {
    for (functions, 0..) |left, left_index| {
        left.validate();
        for (functions[left_index + 1 ..]) |right| {
            right.validate();
            std.debug.assert(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

fn assertUniqueExternalNames(externals: []const ExternalResolution) void {
    for (externals, 0..) |left, left_index| {
        left.validate();
        for (externals[left_index + 1 ..]) |right| {
            right.validate();
            std.debug.assert(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

fn cloneStatementList(allocator: std.mem.Allocator, list: StatementList) std.mem.Allocator.Error!StatementList {
    list.validate();
    if (list.commands.len != 0) {
        const commands = try allocator.alloc(CommandPlan, list.commands.len);
        errdefer allocator.free(commands);
        var initialized: usize = 0;
        errdefer for (commands[0..initialized]) |command| freeCommandPlan(allocator, command);
        for (list.commands, 0..) |command, index| {
            commands[index] = try cloneCommandPlan(allocator, command);
            initialized += 1;
        }
        return .{ .commands = commands };
    }

    const statements = try allocator.alloc(StatementListEntry, list.statements.len);
    errdefer allocator.free(statements);
    var initialized: usize = 0;
    errdefer for (statements[0..initialized]) |entry| freeStatementPlan(allocator, entry.plan);
    for (list.statements, 0..) |entry, index| {
        statements[index] = .{ .op_before = entry.op_before, .plan = try cloneStatementPlan(allocator, entry.plan) };
        initialized += 1;
    }
    return .{ .statements = statements };
}

fn freeStatementList(allocator: std.mem.Allocator, list: StatementList) void {
    for (list.commands) |command| freeCommandPlan(allocator, command);
    allocator.free(list.commands);
    for (list.statements) |entry| freeStatementPlan(allocator, entry.plan);
    allocator.free(list.statements);
}

fn cloneStatementPlan(allocator: std.mem.Allocator, plan: StatementPlan) std.mem.Allocator.Error!StatementPlan {
    plan.validate();
    return switch (plan) {
        .simple => |simple| .{ .simple = try cloneCommandPlan(allocator, simple) },
        .compound => |compound| .{ .compound = try cloneCompoundCommandPlan(allocator, compound) },
        .pipeline => |pipeline| .{ .pipeline = try clonePipelinePlan(allocator, pipeline) },
        .source => |source| .{ .source = try cloneSourceStatementPlan(allocator, source) },
        .ir_source => |source| .{ .source = try cloneIrStatementPlanAsSource(allocator, source) },
    };
}

fn freeStatementPlan(allocator: std.mem.Allocator, plan: StatementPlan) void {
    switch (plan) {
        .simple => |simple| freeCommandPlan(allocator, simple),
        .compound => |compound| freeCompoundCommandPlan(allocator, compound),
        .pipeline => |pipeline| freePipelinePlan(allocator, pipeline),
        .source => |source| freeSourceStatementPlan(allocator, source),
        .ir_source => {},
    }
}

fn cloneSourceStatementPlan(
    allocator: std.mem.Allocator,
    plan: SourceStatementPlan,
) std.mem.Allocator.Error!SourceStatementPlan {
    plan.validate();
    return .{
        .target = plan.target,
        .source = try allocator.dupe(u8, plan.source),
        .line = plan.line,
        .targets_stdout = plan.targets_stdout,
        .targets_stderr = plan.targets_stderr,
    };
}

fn freeSourceStatementPlan(allocator: std.mem.Allocator, plan: SourceStatementPlan) void {
    allocator.free(plan.source);
}

fn cloneIrStatementPlanAsSource(
    allocator: std.mem.Allocator,
    plan: IrStatementPlan,
) std.mem.Allocator.Error!SourceStatementPlan {
    plan.validate();
    return .{
        .target = plan.target,
        .source = try allocator.dupe(u8, plan.fallback_source),
        .line = plan.line,
        .targets_stdout = plan.targets_stdout,
        .targets_stderr = plan.targets_stderr,
    };
}

fn cloneCommandPlan(allocator: std.mem.Allocator, plan: CommandPlan) std.mem.Allocator.Error!CommandPlan {
    plan.validate();
    const assignments = try cloneAssignments(allocator, plan.assignments);
    errdefer freeAssignments(allocator, assignments);
    const argv = try cloneArgv(allocator, plan.argv);
    errdefer freeArgv(allocator, argv);
    var redirections = try plan.redirections.clone(allocator);
    errdefer redirections.deinit();
    const expansion_stderr = try allocator.dupe(u8, plan.expansion_stderr);
    errdefer allocator.free(expansion_stderr);
    const expansion_diagnostics = try cloneArgv(allocator, plan.expansion_diagnostics);
    errdefer freeArgv(allocator, expansion_diagnostics);
    const classification = try cloneClassification(allocator, plan.classification, argv);
    errdefer freeClassification(allocator, classification);
    const owned: CommandPlan = .{
        .target = plan.target,
        .assignments = assignments,
        .argv = argv,
        .redirections = redirections,
        .last_command_substitution_status = plan.last_command_substitution_status,
        .expansion_stderr = expansion_stderr,
        .expansion_diagnostics = expansion_diagnostics,
        .classification = classification,
    };
    owned.validate();
    return owned;
}

fn freeCommandPlan(allocator: std.mem.Allocator, plan: CommandPlan) void {
    freeAssignments(allocator, plan.assignments);
    freeArgv(allocator, plan.argv);
    var redirections = plan.redirections;
    redirections.deinit();
    allocator.free(plan.expansion_stderr);
    freeArgv(allocator, plan.expansion_diagnostics);
    freeClassification(allocator, plan.classification);
}

fn cloneAssignments(
    allocator: std.mem.Allocator,
    assignments: []const Assignment,
) std.mem.Allocator.Error![]const Assignment {
    const owned = try allocator.alloc(Assignment, assignments.len);
    errdefer allocator.free(owned);
    var initialized: usize = 0;
    errdefer for (owned[0..initialized]) |assignment| freeAssignment(allocator, assignment);
    for (assignments, 0..) |assignment, index| {
        owned[index] = try cloneAssignment(allocator, assignment);
        initialized += 1;
    }
    return owned;
}

fn cloneAssignment(allocator: std.mem.Allocator, assignment: Assignment) std.mem.Allocator.Error!Assignment {
    const name = try allocator.dupe(u8, assignment.name);
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, assignment.value);
    return .{ .name = name, .value = value };
}

fn freeAssignments(allocator: std.mem.Allocator, assignments: []const Assignment) void {
    for (assignments) |assignment| freeAssignment(allocator, assignment);
    allocator.free(assignments);
}

fn freeAssignment(allocator: std.mem.Allocator, assignment: Assignment) void {
    allocator.free(assignment.name);
    allocator.free(assignment.value);
}

fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const owned = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(owned);
    var initialized: usize = 0;
    errdefer for (owned[0..initialized]) |arg| allocator.free(arg);
    for (argv, 0..) |arg, index| {
        owned[index] = try allocator.dupe(u8, arg);
        initialized += 1;
    }
    return owned;
}

fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn cloneClassification(
    allocator: std.mem.Allocator,
    classification: Classification,
    cloned_argv: []const []const u8,
) std.mem.Allocator.Error!Classification {
    return switch (classification) {
        .empty => .{ .empty = {} },
        .assignment_only => .{ .assignment_only = {} },
        .special_builtin => |definition| .{ .special_builtin = definition },
        .regular_builtin => |definition| .{ .regular_builtin = definition },
        .function_definition => |definition| .{
            .function_definition = try cloneFunctionDefinition(allocator, definition),
        },
        .function => |definition| .{ .function = try cloneFunctionDefinition(allocator, definition) },
        .external => |resolution| .{ .external = try cloneExternalResolution(allocator, resolution) },
        .not_found => .{ .not_found = .{ .name = cloned_argv[0] } },
    };
}

fn cloneExternalResolution(
    allocator: std.mem.Allocator,
    resolution: ExternalResolution,
) std.mem.Allocator.Error!ExternalResolution {
    const name = try allocator.dupe(u8, resolution.name);
    errdefer allocator.free(name);
    const path = try allocator.dupe(u8, resolution.path);
    return .{ .name = name, .path = path };
}

fn freeClassification(allocator: std.mem.Allocator, classification: Classification) void {
    switch (classification) {
        .empty, .assignment_only, .special_builtin, .regular_builtin, .not_found => {},
        .function_definition => |definition| freeFunctionDefinition(allocator, definition),
        .function => |definition| freeFunctionDefinition(allocator, definition),
        .external => |resolution| {
            allocator.free(resolution.name);
            allocator.free(resolution.path);
        },
    }
}

fn cloneCompoundCommandPlan(
    allocator: std.mem.Allocator,
    plan: CompoundCommandPlan,
) std.mem.Allocator.Error!CompoundCommandPlan {
    plan.validate();
    var redirections = try plan.redirections.clone(allocator);
    errdefer redirections.deinit();
    const body = try cloneCompoundBody(allocator, plan.body);
    errdefer freeCompoundBody(allocator, body);
    return .{ .target = plan.target, .redirections = redirections, .body = body };
}

fn freeCompoundCommandPlan(allocator: std.mem.Allocator, plan: CompoundCommandPlan) void {
    var redirections = plan.redirections;
    redirections.deinit();
    freeCompoundBody(allocator, plan.body);
}

fn cloneCompoundBody(allocator: std.mem.Allocator, body: CompoundBody) std.mem.Allocator.Error!CompoundBody {
    body.validate();
    return switch (body) {
        .sequence => |list| .{ .sequence = try cloneStatementList(allocator, list) },
        .and_or_list => |and_or| .{ .and_or_list = try cloneAndOrPlan(allocator, and_or) },
        .negation => |negation| .{ .negation = .{ .body = try cloneStatementList(allocator, negation.body) } },
        .brace_group => |list| .{ .brace_group = try cloneStatementList(allocator, list) },
        .subshell => |list| .{ .subshell = try cloneStatementList(allocator, list) },
        .if_clause => |if_plan| .{ .if_clause = try cloneIfPlan(allocator, if_plan) },
        .while_loop => |loop| .{ .while_loop = try cloneLoopPlan(allocator, loop) },
        .until_loop => |loop| .{ .until_loop = try cloneLoopPlan(allocator, loop) },
        .for_loop => |for_plan| .{ .for_loop = try cloneForPlan(allocator, for_plan) },
        .case_clause => |case_plan| .{ .case_clause = try cloneCasePlan(allocator, case_plan) },
    };
}

fn freeCompoundBody(allocator: std.mem.Allocator, body: CompoundBody) void {
    switch (body) {
        .sequence => |list| freeStatementList(allocator, list),
        .and_or_list => |and_or| freeAndOrPlan(allocator, and_or),
        .negation => |negation| freeStatementList(allocator, negation.body),
        .brace_group => |list| freeStatementList(allocator, list),
        .subshell => |list| freeStatementList(allocator, list),
        .if_clause => |if_plan| freeIfPlan(allocator, if_plan),
        .while_loop => |loop| freeLoopPlan(allocator, loop),
        .until_loop => |loop| freeLoopPlan(allocator, loop),
        .for_loop => |for_plan| freeForPlan(allocator, for_plan),
        .case_clause => |case_plan| freeCasePlan(allocator, case_plan),
    }
}

fn cloneAndOrPlan(allocator: std.mem.Allocator, plan: AndOrPlan) std.mem.Allocator.Error!AndOrPlan {
    plan.validate();
    const commands = try allocator.alloc(AndOrCommand, plan.commands.len);
    errdefer allocator.free(commands);
    var initialized: usize = 0;
    errdefer for (commands[0..initialized]) |command| freeCommandPlan(allocator, command.command);
    for (plan.commands, 0..) |command, index| {
        commands[index] = .{
            .operator = command.operator,
            .command = try cloneCommandPlan(allocator, command.command),
        };
        initialized += 1;
    }
    return .{ .commands = commands };
}

fn freeAndOrPlan(allocator: std.mem.Allocator, plan: AndOrPlan) void {
    for (plan.commands) |command| freeCommandPlan(allocator, command.command);
    allocator.free(plan.commands);
}

fn cloneIfPlan(allocator: std.mem.Allocator, plan: IfPlan) std.mem.Allocator.Error!IfPlan {
    plan.validate();
    const branches = try allocator.alloc(IfBranch, plan.branches.len);
    errdefer allocator.free(branches);
    var initialized: usize = 0;
    errdefer for (branches[0..initialized]) |branch| freeIfBranch(allocator, branch);
    for (plan.branches, 0..) |branch, index| {
        branches[index] = try cloneIfBranch(allocator, branch);
        initialized += 1;
    }
    const else_body = try cloneStatementList(allocator, plan.else_body);
    errdefer freeStatementList(allocator, else_body);
    return .{ .branches = branches, .else_body = else_body };
}

fn cloneIfBranch(allocator: std.mem.Allocator, branch: IfBranch) std.mem.Allocator.Error!IfBranch {
    branch.validate();
    const condition = try cloneStatementList(allocator, branch.condition);
    errdefer freeStatementList(allocator, condition);
    const body = try cloneStatementList(allocator, branch.body);
    return .{ .condition = condition, .body = body };
}

fn freeIfPlan(allocator: std.mem.Allocator, plan: IfPlan) void {
    for (plan.branches) |branch| freeIfBranch(allocator, branch);
    allocator.free(plan.branches);
    freeStatementList(allocator, plan.else_body);
}

fn freeIfBranch(allocator: std.mem.Allocator, branch: IfBranch) void {
    freeStatementList(allocator, branch.condition);
    freeStatementList(allocator, branch.body);
}

fn cloneLoopPlan(allocator: std.mem.Allocator, plan: LoopPlan) std.mem.Allocator.Error!LoopPlan {
    plan.validate();
    const condition_source = if (plan.condition_source) |source| try allocator.dupe(u8, source) else null;
    errdefer if (condition_source) |source| allocator.free(source);
    const condition = try cloneStatementList(allocator, plan.condition);
    errdefer freeStatementList(allocator, condition);
    const body_source = if (plan.body_source) |source| try allocator.dupe(u8, source) else null;
    errdefer if (body_source) |source| allocator.free(source);
    const body = try cloneStatementList(allocator, plan.body);
    return .{ .condition_source = condition_source, .condition = condition, .body_source = body_source, .body = body };
}

fn freeLoopPlan(allocator: std.mem.Allocator, plan: LoopPlan) void {
    if (plan.condition_source) |source| allocator.free(source);
    freeStatementList(allocator, plan.condition);
    if (plan.body_source) |source| allocator.free(source);
    freeStatementList(allocator, plan.body);
}

fn cloneForPlan(allocator: std.mem.Allocator, plan: ForPlan) std.mem.Allocator.Error!ForPlan {
    plan.validate();
    const variable_name = try allocator.dupe(u8, plan.variable_name);
    errdefer allocator.free(variable_name);
    const words = try cloneForWords(allocator, plan.words);
    errdefer freeForWords(allocator, words);
    const body_source = if (plan.body_source) |source| try allocator.dupe(u8, source) else null;
    errdefer if (body_source) |source| allocator.free(source);
    const body = try cloneStatementList(allocator, plan.body);
    errdefer freeStatementList(allocator, body);
    return .{ .variable_name = variable_name, .words = words, .body_source = body_source, .body = body };
}

fn freeForPlan(allocator: std.mem.Allocator, plan: ForPlan) void {
    allocator.free(plan.variable_name);
    freeForWords(allocator, plan.words);
    if (plan.body_source) |source| allocator.free(source);
    freeStatementList(allocator, plan.body);
}

fn cloneForWords(allocator: std.mem.Allocator, words: ForWords) std.mem.Allocator.Error!ForWords {
    words.validate();
    return switch (words) {
        .positional_parameters => .positional_parameters,
        .explicit => |explicit| blk: {
            const owned = try allocator.alloc([]const u8, explicit.len);
            errdefer allocator.free(owned);
            var initialized: usize = 0;
            errdefer for (owned[0..initialized]) |word| allocator.free(word);
            for (explicit, 0..) |word, index| {
                owned[index] = try allocator.dupe(u8, word);
                initialized += 1;
            }
            break :blk .{ .explicit = owned };
        },
    };
}

fn freeForWords(allocator: std.mem.Allocator, words: ForWords) void {
    switch (words) {
        .positional_parameters => {},
        .explicit => |explicit| {
            for (explicit) |word| allocator.free(word);
            allocator.free(explicit);
        },
    }
}

fn cloneCasePlan(allocator: std.mem.Allocator, plan: CasePlan) std.mem.Allocator.Error!CasePlan {
    plan.validate();
    const word = try allocator.dupe(u8, plan.word);
    errdefer allocator.free(word);
    const arms = try allocator.alloc(CaseArm, plan.arms.len);
    errdefer allocator.free(arms);
    var initialized: usize = 0;
    errdefer for (arms[0..initialized]) |arm| freeCaseArm(allocator, arm);
    for (plan.arms, 0..) |arm, index| {
        arms[index] = try cloneCaseArm(allocator, arm);
        initialized += 1;
    }
    return .{ .word = word, .arms = arms };
}

fn freeCasePlan(allocator: std.mem.Allocator, plan: CasePlan) void {
    allocator.free(plan.word);
    for (plan.arms) |arm| freeCaseArm(allocator, arm);
    allocator.free(plan.arms);
}

fn cloneCaseArm(allocator: std.mem.Allocator, arm: CaseArm) std.mem.Allocator.Error!CaseArm {
    arm.validate();
    const patterns = try allocator.alloc([]const u8, arm.patterns.len);
    errdefer allocator.free(patterns);
    var initialized: usize = 0;
    errdefer for (patterns[0..initialized]) |pattern| allocator.free(pattern);
    for (arm.patterns, 0..) |pattern, index| {
        patterns[index] = try allocator.dupe(u8, pattern);
        initialized += 1;
    }
    const body = try cloneStatementList(allocator, arm.body);
    errdefer freeStatementList(allocator, body);
    return .{ .patterns = patterns, .body = body, .fallthrough = arm.fallthrough, .test_next = arm.test_next };
}

fn freeCaseArm(allocator: std.mem.Allocator, arm: CaseArm) void {
    for (arm.patterns) |pattern| allocator.free(pattern);
    allocator.free(arm.patterns);
    freeStatementList(allocator, arm.body);
}

fn clonePipelinePlan(allocator: std.mem.Allocator, plan: PipelinePlan) std.mem.Allocator.Error!PipelinePlan {
    plan.validate();
    const stages = try allocator.alloc(PipelineStagePlan, plan.stages.len);
    errdefer allocator.free(stages);
    var initialized: usize = 0;
    errdefer for (stages[0..initialized]) |stage| freePipelineStagePlan(allocator, stage);
    for (plan.stages, 0..) |stage, index| {
        stages[index] = try clonePipelineStagePlan(allocator, stage);
        initialized += 1;
    }
    return PipelinePlan.init(stages, .{
        .negated = plan.negated,
        .status_rule = plan.status_rule,
        .background = plan.background,
    });
}

fn freePipelinePlan(allocator: std.mem.Allocator, plan: PipelinePlan) void {
    for (plan.stages) |stage| freePipelineStagePlan(allocator, stage);
    allocator.free(plan.stages);
}

fn clonePipelineStagePlan(
    allocator: std.mem.Allocator,
    stage: PipelineStagePlan,
) std.mem.Allocator.Error!PipelineStagePlan {
    stage.validate();
    return switch (stage) {
        .simple => |simple| .{ .simple = try cloneCommandPlan(allocator, simple) },
        .compound => |compound| .{ .compound = try cloneCompoundCommandPlan(allocator, compound) },
    };
}

fn freePipelineStagePlan(allocator: std.mem.Allocator, stage: PipelineStagePlan) void {
    switch (stage) {
        .simple => |simple| freeCommandPlan(allocator, simple),
        .compound => |compound| freeCompoundCommandPlan(allocator, compound),
    }
}

fn choosePipelineStrategy(
    stages: []const PipelineStagePlan,
    background: PipelineBackgroundMode,
) PipelineExecutionStrategy {
    std.debug.assert(stages.len != 0);
    for (stages) |stage| stage.validate();
    if (background == .background) return .background_deferred;
    if (stages.len == 1) return .single_stage;
    if (allStagesExternalOnlyRealEligible(stages)) return .external_only_real;
    if (allStagesSemantic(stages)) return .semantic_in_memory;
    return .mixed_in_memory;
}

fn allStagesExternalOnlyRealEligible(stages: []const PipelineStagePlan) bool {
    std.debug.assert(stages.len != 0);
    for (stages) |stage| if (!stage.isExternalOnlyRealEligible()) return false;
    return true;
}

fn allStagesSemantic(stages: []const PipelineStagePlan) bool {
    std.debug.assert(stages.len != 0);
    for (stages) |stage| if (stage.isExternal()) return false;
    return true;
}

fn hasSimpleRedirections(plan: CommandPlan) bool {
    plan.redirections.validate();
    return plan.redirections.steps.len != 0 or plan.redirections.rollback_steps.len != 0;
}

fn pipefailStatus(statuses: []const state.ExitStatus) state.ExitStatus {
    std.debug.assert(statuses.len != 0);
    var index = statuses.len;
    while (index != 0) {
        index -= 1;
        if (statuses[index] != 0) return statuses[index];
    }
    return 0;
}

fn negateStatus(status: state.ExitStatus) state.ExitStatus {
    return if (status == 0) 1 else 0;
}

test "CommandPlan classifies expanded simple command shapes" {
    const assignments = [_]Assignment{.{ .name = "FOO", .value = "bar" }};
    const redirection_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.close(0, 1)};
    const rollback_steps = [_]redirection_plan.RestorationStep{.{ .ordinal = 0, .target = 1 }};
    const redirections: redirection_plan.RedirectionPlan = .{
        .steps = &redirection_steps,
        .rollback_steps = &rollback_steps,
    };
    const echo_argv = [_][]const u8{ "echo", "hello" };
    const function_argv = [_][]const u8{"say_hi"};
    const external_argv = [_][]const u8{ "cat", "file" };
    const missing_argv = [_][]const u8{"missing"};
    const functions = [_]FunctionDefinition{.{ .name = "say_hi" }};
    const externals = [_]ExternalResolution{.{ .name = "cat", .path = "/bin/cat" }};
    const lookup: LookupSnapshot = .{ .functions = &functions, .externals = &externals };

    const empty = classifyExpandedSimpleCommand(.{});
    try std.testing.expectEqual(CommandClass.empty, empty.class());
    try std.testing.expectEqual(context.ExecutionTarget.current_shell, empty.target);

    const redirection_only = classifyExpandedSimpleCommand(.{ .command = .{ .redirections = redirections } });
    try std.testing.expectEqual(CommandClass.empty, redirection_only.class());
    try std.testing.expectEqual(@as(usize, 1), redirection_only.redirections.steps.len);

    const assignment_only = classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments } });
    try std.testing.expectEqual(CommandClass.assignment_only, assignment_only.class());
    try std.testing.expectEqual(AssignmentEffect.persistent, assignment_only.assignmentEffect());
    try std.testing.expectEqual(@as(usize, 0), assignment_only.argv.len);

    const special = classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{"export"},
    } });
    try std.testing.expectEqual(CommandClass.special_builtin, special.class());
    try std.testing.expectEqual(AssignmentEffect.persistent, special.assignmentEffect());

    const regular = classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments, .argv = &echo_argv } });
    try std.testing.expectEqual(CommandClass.regular_builtin, regular.class());
    try std.testing.expectEqual(AssignmentEffect.temporary, regular.assignmentEffect());

    const function_plan = classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &assignments, .argv = &function_argv },
        .lookup = lookup,
    });
    try std.testing.expectEqual(CommandClass.function, function_plan.class());
    try std.testing.expectEqual(AssignmentEffect.temporary, function_plan.assignmentEffect());

    const external = classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &assignments, .argv = &external_argv },
        .lookup = lookup,
    });
    try std.testing.expectEqual(CommandClass.external, external.class());
    try std.testing.expectEqual(AssignmentEffect.temporary, external.assignmentEffect());
    try std.testing.expectEqual(context.ExecutionTarget.child_process, external.target);

    const not_found = classifyExpandedSimpleCommand(.{ .command = .{ .argv = &missing_argv }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.not_found, not_found.class());
    switch (not_found.classification) {
        .not_found => |resolution| try std.testing.expectEqualStrings("missing", resolution.name),
        else => return error.TestUnexpectedResult,
    }
}

test "CommandPlan accepts builtin registry slices from embedders" {
    var registry = builtin.BuiltinRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerSlice(default_builtins.default_registry);
    try registry.register(builtin.Builtin.initExtension("custom_builtin", .output));

    const custom = classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"custom_builtin"} },
        .lookup = .{ .builtins = registry.slice() },
    });
    try std.testing.expectEqual(CommandClass.regular_builtin, custom.class());
    switch (custom.classification) {
        .regular_builtin => |definition| {
            try std.testing.expectEqual(builtin.BuiltinOrigin.extension, definition.origin);
            try std.testing.expectEqualStrings("custom_builtin", definition.name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "CommandPlan lookup precedence is special builtin function regular builtin external" {
    const colliding_builtins = [_]builtin.Builtin{
        .{ .name = "special", .kind = .special },
        .{ .name = "regular", .kind = .regular },
        .{ .name = "only_builtin", .kind = .regular },
    };
    const functions = [_]FunctionDefinition{
        .{ .name = "special" },
        .{ .name = "regular" },
        .{ .name = "only_function" },
    };
    const externals = [_]ExternalResolution{
        .{ .name = "special", .path = "/bin/special" },
        .{ .name = "regular", .path = "/bin/regular" },
        .{ .name = "only_function", .path = "/bin/only_function" },
        .{ .name = "only_builtin", .path = "/bin/only_builtin" },
        .{ .name = "only_external", .path = "/bin/only_external" },
        .{ .name = "/bin/regular", .path = "/bin/regular" },
    };
    const lookup: LookupSnapshot = .{
        .builtins = &colliding_builtins,
        .functions = &functions,
        .externals = &externals,
    };

    const special = classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"special"} },
        .lookup = lookup,
    });
    try std.testing.expectEqual(CommandClass.special_builtin, special.class());

    const regular_collision = classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"regular"} },
        .lookup = lookup,
    });
    try std.testing.expectEqual(CommandClass.function, regular_collision.class());

    const builtin_collision = classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"only_builtin"} },
        .lookup = lookup,
    });
    try std.testing.expectEqual(CommandClass.regular_builtin, builtin_collision.class());

    const external = classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"only_external"} },
        .lookup = lookup,
    });
    try std.testing.expectEqual(CommandClass.external, external.class());

    const path_command = classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"/bin/regular"} },
        .lookup = lookup,
    });
    try std.testing.expectEqual(CommandClass.external, path_command.class());
}

test "CommandPlan classification matrix is deterministic over command and lookup snapshots" {
    const assignment_sets = [_][]const Assignment{
        &.{},
        &[_]Assignment{.{ .name = "A", .value = "1" }},
    };
    const argv_sets = [_][]const []const u8{
        &.{},
        &[_][]const u8{"export"},
        &[_][]const u8{"fn"},
        &[_][]const u8{"echo"},
        &[_][]const u8{"exe"},
        &[_][]const u8{"missing"},
    };
    const function_sets = [_][]const FunctionDefinition{
        &.{},
        &[_]FunctionDefinition{ .{ .name = "fn" }, .{ .name = "echo" } },
    };
    const external_sets = [_][]const ExternalResolution{
        &.{},
        &[_]ExternalResolution{ .{ .name = "exe", .path = "/bin/exe" }, .{ .name = "echo", .path = "/bin/echo" } },
    };
    const targets = [_]context.ExecutionTarget{ .current_shell, .subshell, .child_process };

    for (assignment_sets) |assignments| {
        for (argv_sets) |argv| {
            for (function_sets) |functions| {
                for (external_sets) |externals| {
                    for (targets) |target| {
                        const request: PlanRequest = .{
                            .command = .{ .assignments = assignments, .argv = argv },
                            .lookup = .{ .functions = functions, .externals = externals },
                            .target = target,
                        };
                        const first = classifyExpandedSimpleCommand(request);
                        const second = classifyExpandedSimpleCommand(request);
                        first.validate();
                        second.validate();
                        try std.testing.expectEqual(first.class(), second.class());
                        try std.testing.expectEqual(first.target, second.target);
                        if (first.class() == .external) {
                            try std.testing.expectEqual(context.ExecutionTarget.child_process, first.target);
                        } else {
                            try std.testing.expectEqual(target, first.target);
                        }
                    }
                }
            }
        }
    }
}
