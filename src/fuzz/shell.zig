//! Shell semantic fuzz targets.
//!
//! These targets stay above POSIX effects: generated inputs exercise semantic
//! shell state and deltas through the public shell core rather than real host
//! descriptors, processes, or current-directory mutation.

const std = @import("std");

pub const shell = @import("rush-shell");

const consequence = shell.consequence;
const redirection_plan = shell.redirection_plan;
const fd = redirection_plan.runtime_fd;

const variable_names = [_][]const u8{ "A", "B", "C", "PATH", "rush_var" };
const variable_values = [_][]const u8{ "", "0", "one", "two words", "*.zig", "$literal" };
const alias_names = [_][]const u8{ "ll", "g", "x-y", "run!" };
const alias_values = [_][]const u8{ "ls -l", "git", "echo ok", "printf %s" };
const shell_options = [_]shell.ShellOption{
    .allexport,
    .errexit,
    .ignoreeof,
    .monitor,
    .noclobber,
    .noexec,
    .noglob,
    .notify,
    .nounset,
    .pipefail,
    .verbose,
    .xtrace,
};
const shell_error_kinds = [_]consequence.ShellErrorKind{
    .redirection_error,
    .readonly_assignment,
    .expansion_error,
    .evaluation_error,
    .special_builtin_failure,
};

const redirection_max_prefix_steps = 4;
const redirection_target_count = 5;
const redirection_source_base = 5;
const redirection_table_len = 64;
const closed_duplicate_source: fd.Descriptor = 30;
const eval_max_redirection_steps = 5;
const eval_max_redirection_plans = 24;
const eval_max_commands = 20;
const eval_max_pipeline_stages = 4;
const eval_max_stage_commands = 3;

const eval_assignment_names = [_][]const u8{ "A", "B", "C", "rush_var" };
const eval_command_names = [_][]const u8{ ":", "true", "false" };

const VariableAction = enum {
    keep,
    assign,
    assign_exported,
    unset,
    export_enabled,
};

const AliasAction = enum {
    keep,
    set,
    unset,
};

const OptionAction = enum {
    keep,
    enable,
    disable,
};

const DeltaPlan = struct {
    variable_actions: [variable_names.len]VariableAction,
    variable_value_indexes: [variable_names.len]usize,
    alias_actions: [alias_names.len]AliasAction,
    alias_value_indexes: [alias_names.len]usize,
    option_actions: [shell_options.len]OptionAction,
    last_status: ?shell.ExitStatus,
};

test "fuzz shell delta commit and discard" {
    try std.testing.fuzz({}, fuzzShellDelta, .{});
}

test "fuzz shell consequence policy" {
    try std.testing.fuzz({}, fuzzShellConsequencePolicy, .{});
}

test "fuzz shell redirection rollback" {
    try std.testing.fuzz({}, fuzzShellRedirectionRollback, .{});
}

test "fuzz shell eval redirection invariants" {
    try std.testing.fuzz({}, fuzzShellEvalRedirectionInvariants, .{});
}

test "fuzz shell eval pipeline invariants" {
    try std.testing.fuzz({}, fuzzShellEvalPipelineInvariants, .{});
}

fn fuzzShellDelta(_: void, smith: *std.testing.Smith) anyerror!void {
    var initial = shell.ShellState.init(std.testing.allocator);
    defer initial.deinit();
    try populateInitialState(smith, &initial);

    var discarded = try initial.clone(std.testing.allocator);
    defer discarded.deinit();

    var expected = try initial.clone(std.testing.allocator);
    defer expected.deinit();

    const plan = generateDeltaPlan(smith);

    var discard_delta = try stateDeltaFromPlan(plan);
    defer discard_delta.deinit();
    discard_delta.discard(.current_shell);
    try expectShellStatesEqual(initial, discarded);

    var commit_delta = try stateDeltaFromPlan(plan);
    defer commit_delta.deinit();
    try commit_delta.commit(&initial, .current_shell);
    try applyPlanToExpected(&expected, plan);

    try expectShellStatesEqual(expected, initial);
}

fn fuzzShellConsequencePolicy(_: void, smith: *std.testing.Smith) anyerror!void {
    var options: shell.ShellOptions = .{};
    options.set(.errexit, smith.boolWeighted(1, 1));

    const eval_context = shell.EvalContext.init(.{
        .target = .current_shell,
        .interactive = smith.boolWeighted(1, 1),
        .errexit_ignored = smith.boolWeighted(1, 2),
    });

    const raw_status = smith.value(shell.ExitStatus);
    const nonzero_status: shell.ExitStatus = if (raw_status == 0) 1 else raw_status;

    switch (smith.index(3)) {
        0 => {
            const decision = consequence.decideForStatus(options, eval_context, raw_status);
            decision.validate(eval_context);
            const expected_errexit = raw_status != 0 and options.enabled(.errexit) and eval_context.observesErrexit();
            if (expected_errexit) {
                try std.testing.expectEqual(consequence.ErrorConsequence.errexit_exit, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow{ .exit = raw_status }, decision.control_flow);
                try std.testing.expectEqual(consequence.ShellErrorKind.nonzero_status, decision.kind.?);
            } else {
                try std.testing.expectEqual(consequence.ErrorConsequence.normal_outcome, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow.normal, decision.control_flow);
                try std.testing.expectEqual(
                    if (raw_status == 0) @as(?consequence.ShellErrorKind, null) else .nonzero_status,
                    decision.kind,
                );
            }
        },
        1 => {
            const kind = shell_error_kinds[smith.index(shell_error_kinds.len)];
            const decision = consequence.decideForShellError(options, eval_context, kind, nonzero_status);
            decision.validate(eval_context);
            try std.testing.expectEqual(kind, decision.kind.?);
            try std.testing.expectEqual(nonzero_status, decision.status);

            if (shellErrorIsFatal(kind, eval_context)) {
                try std.testing.expectEqual(consequence.ErrorConsequence.fatal_shell_error, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow{ .fatal = nonzero_status }, decision.control_flow);
            } else if (options.enabled(.errexit) and eval_context.observesErrexit()) {
                try std.testing.expectEqual(consequence.ErrorConsequence.errexit_exit, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow{ .exit = nonzero_status }, decision.control_flow);
            } else {
                try std.testing.expectEqual(consequence.ErrorConsequence.normal_outcome, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow.normal, decision.control_flow);
            }
        },
        2 => {
            const failure_consequence: redirection_plan.FailureConsequence =
                if (smith.boolWeighted(1, 1)) .command_failure else .fatal_shell_error;
            const status = consequence.statusForRedirectionFailure(failure_consequence);
            const decision = consequence.decideForRedirectionFailure(
                options,
                eval_context,
                failure_consequence,
                status,
            );
            decision.validate(eval_context);
            try std.testing.expectEqual(status, decision.status);
            try std.testing.expectEqual(consequence.ShellErrorKind.redirection_error, decision.kind.?);

            if (failure_consequence == .fatal_shell_error) {
                try std.testing.expectEqual(consequence.ErrorConsequence.fatal_shell_error, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow{ .fatal = status }, decision.control_flow);
            } else if (options.enabled(.errexit) and eval_context.observesErrexit()) {
                try std.testing.expectEqual(consequence.ErrorConsequence.errexit_exit, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow{ .exit = status }, decision.control_flow);
            } else {
                try std.testing.expectEqual(consequence.ErrorConsequence.normal_outcome, decision.consequence);
                try std.testing.expectEqual(shell.ControlFlow.normal, decision.control_flow);
            }
        },
        else => unreachable,
    }
}

fn fuzzShellRedirectionRollback(_: void, smith: *std.testing.Smith) anyerror!void {
    const prefix_len = smith.index(redirection_max_prefix_steps + 1);
    const failure_mode = smith.index(3);

    var steps: [redirection_max_prefix_steps + 1]redirection_plan.RedirectionStep = undefined;
    var rollbacks: [redirection_max_prefix_steps + 1]redirection_plan.RestorationStep = undefined;
    for (0..prefix_len) |index| {
        steps[index] = generatedRedirectionStep(smith, index);
        rollbacks[index] = .{ .ordinal = index, .target = steps[index].target() };
    }

    const step_count = switch (failure_mode) {
        0 => prefix_len,
        1 => blk: {
            steps[prefix_len] = redirection_plan.RedirectionStep.openPath(
                prefix_len,
                generatedTarget(smith),
                "missing",
                .{ .access = .read_only },
            );
            rollbacks[prefix_len] = .{ .ordinal = prefix_len, .target = steps[prefix_len].target() };
            break :blk prefix_len + 1;
        },
        2 => blk: {
            steps[prefix_len] = redirection_plan.RedirectionStep.duplicate(
                prefix_len,
                generatedTarget(smith),
                closed_duplicate_source,
            );
            rollbacks[prefix_len] = .{ .ordinal = prefix_len, .target = steps[prefix_len].target() };
            break :blk prefix_len + 1;
        },
        else => unreachable,
    };

    const plan: redirection_plan.RedirectionPlan = .{
        .steps = steps[0..step_count],
        .rollback_steps = rollbacks[0..step_count],
    };
    plan.validate();

    var fake: FuzzFdRuntime = .{};
    const initial_table = fake.table;
    const result = try plan.apply(std.testing.allocator, fake.port());

    switch (result) {
        .applied => |applied_value| {
            var applied = applied_value;
            defer applied.deinit();
            if (failure_mode != 0) {
                applied.restore();
                return error.ExpectedRedirectionFailure;
            }
            applied.restore();
            try std.testing.expectEqualSlices(?u16, &initial_table, &fake.table);
        },
        .failure => |failure| {
            if (failure_mode == 0) return error.UnexpectedRedirectionFailure;
            try std.testing.expectEqual(prefix_len, failure.step_index);
            try std.testing.expectEqualSlices(?u16, &initial_table, &fake.table);
        },
    }
}

fn fuzzShellEvalRedirectionInvariants(_: void, smith: *std.testing.Smith) anyerror!void {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try populateInitialState(smith, &shell_state);

    var initial_state = try shell_state.clone(std.testing.allocator);
    defer initial_state.deinit();

    var fake: FuzzFdRuntime = .{};
    const initial_table = fake.table;
    var evaluator = shell.eval.Evaluator.initWithFdPort(std.testing.allocator, fake.port());

    var storage: EvalPlanStorage = .{};
    const subject = generateEvalSubject(smith, &storage);
    const eval_context = shell.EvalContext.forTarget(subject.target());

    var command_outcome = switch (subject) {
        .simple => |plan| try shell.eval.evaluatePlan(&evaluator, &shell_state, eval_context, plan),
        .compound => |plan| try shell.eval.evaluateCompoundPlan(&evaluator, &shell_state, eval_context, plan),
    };
    defer command_outcome.deinit();

    command_outcome.validateForContext(eval_context);
    try std.testing.expectEqualSlices(?u16, &initial_table, &fake.table);
    try expectShellStatesEqual(initial_state, shell_state);

    if (subject.target() == .current_shell) {
        var committed = try shell_state.clone(std.testing.allocator);
        defer committed.deinit();
        try command_outcome.commitDelta(&committed, .current_shell);
        committed.validate();
    } else {
        command_outcome.discardDelta(subject.target());
    }
    try std.testing.expectEqualSlices(?u16, &initial_table, &fake.table);
}

fn fuzzShellEvalPipelineInvariants(_: void, smith: *std.testing.Smith) anyerror!void {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try populateInitialState(smith, &shell_state);
    shell_state.options.set(.pipefail, smith.boolWeighted(1, 1));

    var initial_state = try shell_state.clone(std.testing.allocator);
    defer initial_state.deinit();

    var fake: FuzzFdRuntime = .{};
    const initial_table = fake.table;
    var evaluator = shell.eval.Evaluator.initWithFdPort(std.testing.allocator, fake.port());

    var storage: EvalPlanStorage = .{};
    const plan = generatePipelineSubject(smith, &storage, shell_state.options.enabled(.pipefail));
    const eval_context = shell.EvalContext.forTarget(.current_shell);

    var command_outcome = try shell.eval.evaluatePipelinePlan(&evaluator, &shell_state, eval_context, plan);
    defer command_outcome.deinit();

    command_outcome.validateForContext(eval_context);
    try std.testing.expectEqualSlices(?u16, &initial_table, &fake.table);
    try expectShellStatesEqual(initial_state, shell_state);

    const statuses = command_outcome.state_delta.last_pipeline_statuses orelse return error.MissingPipelineStatuses;
    try std.testing.expectEqual(plan.stages.len, statuses.len);
    const aggregation = shell.pipeline_plan.aggregateStatus(.{
        .stage_count = plan.stages.len,
        .statuses = statuses,
        .status_rule = plan.status_rule,
        .negated = plan.negated,
    });
    try std.testing.expectEqual(aggregation.final_status, command_outcome.status);
    try std.testing.expectEqual(aggregation.final_status, command_outcome.state_delta.last_status.?);

    var committed = try shell_state.clone(std.testing.allocator);
    defer committed.deinit();
    try command_outcome.commitDelta(&committed, .current_shell);
    committed.validate();
    try std.testing.expectEqualSlices(?u16, &initial_table, &fake.table);
}

fn populateInitialState(smith: *std.testing.Smith, shell_state: *shell.ShellState) !void {
    for (variable_names) |name| {
        if (!smith.boolWeighted(1, 1)) continue;
        try shell_state.putVariable(name, pickValue(&variable_values, smith), .{
            .exported = smith.boolWeighted(1, 1),
        });
    }

    for (alias_names) |name| {
        if (!smith.boolWeighted(1, 2)) continue;
        try shell_state.setAlias(name, pickValue(&alias_values, smith));
    }

    for (shell_options) |option| shell_state.options.set(option, smith.boolWeighted(1, 1));
    shell_state.last_status = smith.value(shell.ExitStatus);
    shell_state.validate();
}

fn generateDeltaPlan(smith: *std.testing.Smith) DeltaPlan {
    var plan: DeltaPlan = undefined;
    for (&plan.variable_actions, &plan.variable_value_indexes) |*action, *value_index| {
        action.* = enumChoice(VariableAction, smith.index(@typeInfo(VariableAction).@"enum".fields.len));
        value_index.* = smith.index(variable_values.len);
    }
    for (&plan.alias_actions, &plan.alias_value_indexes) |*action, *value_index| {
        action.* = enumChoice(AliasAction, smith.index(@typeInfo(AliasAction).@"enum".fields.len));
        value_index.* = smith.index(alias_values.len);
    }
    for (&plan.option_actions) |*action| {
        action.* = enumChoice(OptionAction, smith.index(@typeInfo(OptionAction).@"enum".fields.len));
    }
    plan.last_status = if (smith.boolWeighted(1, 1)) smith.value(shell.ExitStatus) else null;
    return plan;
}

fn stateDeltaFromPlan(plan: DeltaPlan) !shell.delta.StateDelta {
    var state_delta = shell.delta.StateDelta.init(std.testing.allocator, .current_shell);
    errdefer state_delta.deinit();
    try appendPlanToDelta(&state_delta, plan);
    return state_delta;
}

fn appendPlanToDelta(state_delta: *shell.delta.StateDelta, plan: DeltaPlan) !void {
    for (variable_names, plan.variable_actions, plan.variable_value_indexes) |name, action, value_index| {
        const value = variable_values[value_index];
        switch (action) {
            .keep => {},
            .assign => try state_delta.assignVariable(name, value, .{}),
            .assign_exported => try state_delta.assignVariable(name, value, .{ .exported = true }),
            .unset => try state_delta.unsetVariable(name),
            .export_enabled => try state_delta.setVariableExported(name, true),
        }
    }

    for (shell_options, plan.option_actions) |option, action| {
        switch (action) {
            .keep => {},
            .enable => try state_delta.setOption(option, true),
            .disable => try state_delta.setOption(option, false),
        }
    }

    for (alias_names, plan.alias_actions, plan.alias_value_indexes) |name, action, value_index| {
        const value = alias_values[value_index];
        switch (action) {
            .keep => {},
            .set => try state_delta.setAlias(name, value),
            .unset => try state_delta.unsetAlias(name),
        }
    }

    if (plan.last_status) |status| state_delta.setLastStatus(status);
}

fn applyPlanToExpected(shell_state: *shell.ShellState, plan: DeltaPlan) !void {
    for (variable_names, plan.variable_actions, plan.variable_value_indexes) |name, action, value_index| {
        const value = variable_values[value_index];
        switch (action) {
            .keep => {},
            .assign => try shell_state.putVariable(name, value, .{}),
            .assign_exported => try shell_state.putVariable(name, value, .{ .exported = true }),
            .unset => try shell_state.unsetVariable(name),
            .export_enabled => try shell_state.setVariableExported(name, true),
        }
    }

    for (shell_options, plan.option_actions) |option, action| {
        switch (action) {
            .keep => {},
            .enable => shell_state.options.set(option, true),
            .disable => shell_state.options.set(option, false),
        }
    }

    for (alias_names, plan.alias_actions, plan.alias_value_indexes) |name, action, value_index| {
        const value = alias_values[value_index];
        switch (action) {
            .keep => {},
            .set => try shell_state.setAlias(name, value),
            .unset => _ = shell_state.unsetAlias(name),
        }
    }

    if (plan.last_status) |status| shell_state.last_status = status;
    shell_state.validate();
}

fn shellErrorIsFatal(kind: consequence.ShellErrorKind, eval_context: shell.EvalContext) bool {
    if (eval_context.interactive) return false;
    return switch (kind) {
        .nonzero_status, .redirection_error => false,
        .readonly_assignment,
        .expansion_error,
        .evaluation_error,
        .special_builtin_failure,
        => true,
    };
}

fn generatedRedirectionStep(smith: *std.testing.Smith, ordinal: usize) redirection_plan.RedirectionStep {
    const target = generatedTarget(smith);
    return switch (smith.index(3)) {
        0 => redirection_plan.RedirectionStep.openPath(
            ordinal,
            target,
            generatedPath(smith),
            .{ .access = .write_only, .create = true, .truncate = true },
        ),
        1 => redirection_plan.RedirectionStep.duplicate(ordinal, target, generatedSource(smith)),
        2 => redirection_plan.RedirectionStep.close(ordinal, target),
        else => unreachable,
    };
}

fn generatedTarget(smith: *std.testing.Smith) fd.Descriptor {
    return @intCast(smith.index(redirection_target_count));
}

fn generatedSource(smith: *std.testing.Smith) fd.Descriptor {
    return @intCast(redirection_source_base + smith.index(redirection_target_count));
}

fn generatedPath(smith: *std.testing.Smith) []const u8 {
    return switch (smith.index(4)) {
        0 => "out-a",
        1 => "out-b",
        2 => "out-c",
        3 => "out-d",
        else => unreachable,
    };
}

const EvalSubject = union(enum) {
    simple: shell.CommandPlan,
    compound: shell.CompoundCommandPlan,

    fn target(self: EvalSubject) shell.ExecutionTarget {
        return switch (self) {
            .simple => |plan| plan.target,
            .compound => |plan| plan.target,
        };
    }
};

const EvalPlanStorage = struct {
    redirection_steps: [eval_max_redirection_plans][eval_max_redirection_steps]redirection_plan.RedirectionStep =
        undefined,
    rollback_steps: [eval_max_redirection_plans][eval_max_redirection_steps]redirection_plan.RestorationStep =
        undefined,
    redirection_plan_count: usize = 0,
    assignments: [eval_max_commands][1]shell.Assignment = undefined,
    argv: [eval_max_commands][1][]const u8 = undefined,
    commands: [eval_max_commands]shell.CommandPlan = undefined,
    stages: [eval_max_pipeline_stages]shell.PipelineStagePlan = undefined,
    command_count: usize = 0,

    fn redirectionPlan(self: *EvalPlanStorage, smith: *std.testing.Smith) shell.RedirectionPlan {
        std.debug.assert(self.redirection_plan_count < eval_max_redirection_plans);
        const index = self.redirection_plan_count;
        self.redirection_plan_count += 1;

        const step_count = smith.index(eval_max_redirection_steps + 1);
        for (0..step_count) |ordinal| {
            self.redirection_steps[index][ordinal] = generatedEvalRedirectionStep(smith, ordinal);
            self.rollback_steps[index][ordinal] = .{
                .ordinal = ordinal,
                .target = self.redirection_steps[index][ordinal].target(),
            };
        }

        const plan: shell.RedirectionPlan = .{
            .steps = self.redirection_steps[index][0..step_count],
            .rollback_steps = self.rollback_steps[index][0..step_count],
            .failure_consequence = if (smith.boolWeighted(1, 3)) .fatal_shell_error else .command_failure,
        };
        plan.validate();
        return plan;
    }

    fn simpleCommand(
        self: *EvalPlanStorage,
        smith: *std.testing.Smith,
        target: shell.ExecutionTarget,
    ) shell.CommandPlan {
        std.debug.assert(self.command_count < eval_max_commands);
        const index = self.command_count;
        self.command_count += 1;

        const redirections = self.redirectionPlan(smith);
        const expanded = switch (smith.index(5)) {
            0 => shell.ExpandedSimpleCommand{ .redirections = redirections },
            1, 2 => blk: {
                self.assignments[index][0] = .{
                    .name = eval_assignment_names[smith.index(eval_assignment_names.len)],
                    .value = pickValue(&variable_values, smith),
                };
                break :blk shell.ExpandedSimpleCommand{
                    .assignments = self.assignments[index][0..1],
                    .redirections = redirections,
                };
            },
            3, 4 => blk: {
                self.argv[index][0] = eval_command_names[smith.index(eval_command_names.len)];
                break :blk shell.ExpandedSimpleCommand{
                    .argv = self.argv[index][0..1],
                    .redirections = redirections,
                };
            },
            else => unreachable,
        };

        return shell.command_plan.classifyExpandedSimpleCommand(.{
            .command = expanded,
            .target = target,
        });
    }

    fn stage(self: *EvalPlanStorage, smith: *std.testing.Smith, single_stage: bool) shell.PipelineStagePlan {
        return switch (smith.index(4)) {
            0, 1 => .{ .simple = self.simpleCommand(smith, if (single_stage) .current_shell else .subshell) },
            2 => .{ .compound = self.braceGroup(smith, if (single_stage) .current_shell else .subshell) },
            3 => .{ .compound = self.subshell(smith) },
            else => unreachable,
        };
    }

    fn braceGroup(
        self: *EvalPlanStorage,
        smith: *std.testing.Smith,
        target: shell.ExecutionTarget,
    ) shell.CompoundCommandPlan {
        const command_count = 1 + smith.index(eval_max_stage_commands);
        const commands = self.commandSlice(smith, target, command_count);
        const plan: shell.CompoundCommandPlan = .{
            .target = target,
            .redirections = self.redirectionPlan(smith),
            .body = .{ .brace_group = .{ .commands = commands } },
        };
        plan.validate();
        return plan;
    }

    fn subshell(self: *EvalPlanStorage, smith: *std.testing.Smith) shell.CompoundCommandPlan {
        const command_count = 1 + smith.index(eval_max_stage_commands);
        const commands = self.commandSlice(smith, .subshell, command_count);
        const plan: shell.CompoundCommandPlan = .{
            .target = .subshell,
            .redirections = self.redirectionPlan(smith),
            .body = .{ .subshell = .{ .commands = commands } },
        };
        plan.validate();
        return plan;
    }

    fn commandSlice(
        self: *EvalPlanStorage,
        smith: *std.testing.Smith,
        target: shell.ExecutionTarget,
        count: usize,
    ) []const shell.CommandPlan {
        std.debug.assert(self.command_count + count <= eval_max_commands);
        const start = self.command_count;
        for (0..count) |index| {
            self.commands[start + index] = self.simpleCommand(smith, target);
        }
        return self.commands[start..self.command_count];
    }
};

fn generateEvalSubject(smith: *std.testing.Smith, storage: *EvalPlanStorage) EvalSubject {
    const kind = smith.index(4);
    if (kind == 0) return .{ .simple = storage.simpleCommand(smith, .current_shell) };

    const target: shell.ExecutionTarget = if (kind == 3) .subshell else .current_shell;
    const command_count = 1 + smith.index(eval_max_commands);
    for (0..command_count) |index| {
        storage.commands[index] = storage.simpleCommand(smith, target);
    }
    const body: shell.CompoundBody = if (target == .subshell)
        .{ .subshell = .{ .commands = storage.commands[0..command_count] } }
    else
        .{ .brace_group = .{ .commands = storage.commands[0..command_count] } };
    const plan: shell.CompoundCommandPlan = .{
        .target = target,
        .redirections = storage.redirectionPlan(smith),
        .body = body,
    };
    plan.validate();
    return .{ .compound = plan };
}

fn generatePipelineSubject(smith: *std.testing.Smith, storage: *EvalPlanStorage, pipefail: bool) shell.PipelinePlan {
    const stage_count = 1 + smith.index(eval_max_pipeline_stages);
    for (0..stage_count) |index| {
        storage.stages[index] = storage.stage(smith, stage_count == 1);
    }
    const plan = shell.PipelinePlan.init(storage.stages[0..stage_count], .{
        .negated = smith.boolWeighted(1, 1),
        .status_rule = if (pipefail) .pipefail else .last_command,
    });
    plan.validate();
    return plan;
}

fn generatedEvalRedirectionStep(smith: *std.testing.Smith, ordinal: usize) redirection_plan.RedirectionStep {
    const target = @as(fd.Descriptor, @intCast(smith.index(6)));
    return switch (smith.index(6)) {
        0 => redirection_plan.RedirectionStep.openPath(
            ordinal,
            target,
            generatedPath(smith),
            .{ .access = .write_only, .create = true, .truncate = true },
        ),
        1 => redirection_plan.RedirectionStep.openPath(
            ordinal,
            target,
            generatedPath(smith),
            .{ .access = .read_write, .create = true },
        ),
        2 => redirection_plan.RedirectionStep.openPath(ordinal, target, "missing", .{ .access = .read_only }),
        3, 4 => redirection_plan.RedirectionStep.duplicate(ordinal, target, generatedEvalSource(smith)),
        5 => redirection_plan.RedirectionStep.close(ordinal, target),
        else => unreachable,
    };
}

fn generatedEvalSource(smith: *std.testing.Smith) fd.Descriptor {
    return switch (smith.index(8)) {
        0...6 => |descriptor| @intCast(descriptor),
        7 => closed_duplicate_source,
        else => unreachable,
    };
}

const FuzzFdRuntime = struct {
    table: [redirection_table_len]?u16 = initFdTable(),
    next_descriptor: fd.Descriptor = 10,
    next_identity: u16 = 100,

    fn port(self: *FuzzFdRuntime) fd.Port {
        return .{
            .context = self,
            .open_fn = open,
            .close_fn = close,
            .duplicate_fn = duplicate,
            .duplicate_to_fn = duplicateTo,
            .pipe_fn = pipe,
            .is_tty_fn = isTty,
        };
    }

    fn identity(self: FuzzFdRuntime, descriptor: fd.Descriptor) ?u16 {
        if (descriptor < 0 or descriptor >= self.table.len) return null;
        return self.table[@intCast(descriptor)];
    }

    fn setIdentity(self: *FuzzFdRuntime, descriptor: fd.Descriptor, identity_value: ?u16) void {
        std.debug.assert(descriptor >= 0);
        std.debug.assert(descriptor < self.table.len);
        self.table[@intCast(descriptor)] = identity_value;
    }

    fn allocateDescriptor(self: *FuzzFdRuntime, identity_value: u16) fd.Descriptor {
        const descriptor = self.next_descriptor;
        self.next_descriptor += 1;
        self.setIdentity(descriptor, identity_value);
        return descriptor;
    }

    fn allocateIdentity(self: *FuzzFdRuntime) u16 {
        const identity_value = self.next_identity;
        self.next_identity += 1;
        return identity_value;
    }

    fn fromContext(context: *anyopaque) *FuzzFdRuntime {
        return @ptrCast(@alignCast(context));
    }

    fn open(context: *anyopaque, request: fd.OpenRequest) fd.OpenError!fd.OpenResult {
        const self = fromContext(context);
        request.validate();
        if (std.mem.eql(u8, request.path, "missing")) return error.FileNotFound;
        return .{ .descriptor = self.allocateDescriptor(self.allocateIdentity()) };
    }

    fn close(context: *anyopaque, request: fd.CloseRequest) fd.CloseError!void {
        const self = fromContext(context);
        request.validate();
        if (self.identity(request.descriptor) == null) return error.BadFileDescriptor;
        self.setIdentity(request.descriptor, null);
    }

    fn duplicate(context: *anyopaque, request: fd.DuplicateRequest) fd.DuplicateError!fd.DuplicateResult {
        const self = fromContext(context);
        request.validate();
        const identity_value = self.identity(request.descriptor) orelse return error.BadFileDescriptor;
        return .{ .descriptor = self.allocateDescriptor(identity_value) };
    }

    fn duplicateTo(context: *anyopaque, request: fd.DuplicateToRequest) fd.DuplicateError!void {
        const self = fromContext(context);
        request.validate();
        const identity_value = self.identity(request.source) orelse return error.BadFileDescriptor;
        self.setIdentity(request.target, identity_value);
    }

    fn pipe(context: *anyopaque, request: fd.PipeRequest) fd.PipeError!fd.PipeResult {
        const self = fromContext(context);
        request.validate();
        return .{
            .read = self.allocateDescriptor(self.allocateIdentity()),
            .write = self.allocateDescriptor(self.allocateIdentity()),
        };
    }

    fn isTty(context: *anyopaque, request: fd.IsTtyRequest) fd.IsTtyError!fd.IsTtyResult {
        const self = fromContext(context);
        request.validate();
        _ = self;
        return .{ .is_tty = false };
    }
};

fn initFdTable() [redirection_table_len]?u16 {
    var table = [_]?u16{null} ** redirection_table_len;
    for (0..10) |descriptor| table[descriptor] = @intCast(descriptor + 1);
    return table;
}

fn expectShellStatesEqual(expected: shell.ShellState, actual: shell.ShellState) !void {
    try std.testing.expectEqual(expected.scope, actual.scope);
    try std.testing.expectEqual(expected.options, actual.options);
    try std.testing.expectEqual(expected.last_status, actual.last_status);
    try std.testing.expectEqual(expected.pending_exit, actual.pending_exit);
    try std.testing.expectEqual(expected.variables.count(), actual.variables.count());
    try std.testing.expectEqual(expected.aliases.count(), actual.aliases.count());
    try std.testing.expectEqual(expected.functions.count(), actual.functions.count());
    try std.testing.expectEqual(expected.traps.count(), actual.traps.count());
    try std.testing.expectEqual(expected.positionals.items.len, actual.positionals.items.len);
    try std.testing.expectEqual(expected.last_pipeline_statuses.items.len, actual.last_pipeline_statuses.items.len);
    try std.testing.expectEqual(expected.pending_traps.items.len, actual.pending_traps.items.len);

    var variables = expected.variables.iterator();
    while (variables.next()) |entry| {
        const actual_variable = actual.variables.get(entry.key_ptr.*) orelse return error.MissingVariable;
        try std.testing.expectEqualStrings(entry.value_ptr.value, actual_variable.value);
        try std.testing.expectEqual(entry.value_ptr.exported, actual_variable.exported);
        try std.testing.expectEqual(entry.value_ptr.readonly, actual_variable.readonly);
    }

    var aliases = expected.aliases.iterator();
    while (aliases.next()) |entry| {
        const actual_alias = actual.aliases.get(entry.key_ptr.*) orelse return error.MissingAlias;
        try std.testing.expectEqualStrings(entry.value_ptr.value, actual_alias.value);
    }
}

fn pickValue(comptime values: []const []const u8, smith: *std.testing.Smith) []const u8 {
    return values[smith.index(values.len)];
}

fn enumChoice(comptime T: type, index: usize) T {
    return @enumFromInt(index);
}
