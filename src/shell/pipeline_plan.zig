//! Semantic pipeline plans.
//!
//! Pipelines keep command order, status rules, and segment target constraints in
//! the shell core. Pipe creation and process orchestration remain runtime-port
//! responsibilities.

const std = @import("std");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const state = @import("state.zig");

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
    simple: command_plan.CommandPlan,
    compound: command_plan.CompoundCommandPlan,

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
            .strategy = chooseStrategy(stages, options.background),
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
        std.debug.assert(self.strategy == chooseStrategy(self.stages, self.background));
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

fn chooseStrategy(stages: []const PipelineStagePlan, background: PipelineBackgroundMode) PipelineExecutionStrategy {
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

fn hasSimpleRedirections(plan: command_plan.CommandPlan) bool {
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

test "PipelinePlan selects strategy and stage targets before runtime effects" {
    const echo = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"echo"} } });
    const true_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } });
    const externals = [_]command_plan.ExternalResolution{
        .{ .name = "cat", .path = "/bin/cat" },
        .{ .name = "wc", .path = "/usr/bin/wc" },
    };
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const cat = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"cat"} }, .lookup = lookup });
    const wc = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"wc"} }, .lookup = lookup });

    const single = PipelinePlan.init(&[_]PipelineStagePlan{.{ .simple = echo }}, .{});
    try std.testing.expectEqual(PipelineExecutionStrategy.single_stage, single.strategy);
    try std.testing.expectEqual(context.ExecutionTarget.current_shell, single.stageTarget(0));

    const semantic = PipelinePlan.init(&[_]PipelineStagePlan{ .{ .simple = echo }, .{ .simple = true_plan } }, .{});
    try std.testing.expectEqual(PipelineExecutionStrategy.semantic_in_memory, semantic.strategy);
    try std.testing.expectEqual(context.ExecutionTarget.subshell, semantic.stageTarget(0));
    try std.testing.expectEqual(context.ExecutionTarget.subshell, semantic.stageTarget(1));
    try std.testing.expectEqual(@as(usize, 1), semantic.pipeCount());

    const external = PipelinePlan.init(&[_]PipelineStagePlan{ .{ .simple = cat }, .{ .simple = wc } }, .{});
    try std.testing.expectEqual(PipelineExecutionStrategy.external_only_real, external.strategy);
    try std.testing.expectEqual(context.ExecutionTarget.child_process, external.stageTarget(0));
    try std.testing.expectEqual(context.ExecutionTarget.child_process, external.stageTarget(1));

    const mixed = PipelinePlan.init(&[_]PipelineStagePlan{ .{ .simple = echo }, .{ .simple = wc } }, .{});
    try std.testing.expectEqual(PipelineExecutionStrategy.mixed_in_memory, mixed.strategy);
    try std.testing.expectEqual(context.ExecutionTarget.subshell, mixed.stageTarget(0));
    try std.testing.expectEqual(context.ExecutionTarget.child_process, mixed.stageTarget(1));

    const background = PipelinePlan.init(&[_]PipelineStagePlan{ .{ .simple = cat }, .{ .simple = wc } }, .{ .background = .background });
    try std.testing.expectEqual(PipelineExecutionStrategy.background_deferred, background.strategy);
}

test "pipeline status aggregation matches last-command pipefail and negation properties" {
    const rules = [_]PipelineStatusRule{ .last_command, .pipefail };
    const negated_values = [_]bool{ false, true };
    const generated = [_][4]state.ExitStatus{
        .{ 0, 0, 0, 0 },
        .{ 1, 0, 0, 0 },
        .{ 0, 2, 0, 0 },
        .{ 0, 0, 3, 0 },
        .{ 0, 0, 0, 4 },
        .{ 5, 0, 6, 0 },
        .{ 0, 7, 0, 8 },
        .{ 9, 10, 11, 12 },
    };

    for (1..5) |stage_count| {
        for (generated) |statuses_storage| {
            const statuses = statuses_storage[0..stage_count];
            for (rules) |rule| {
                for (negated_values) |negated| {
                    const aggregation = aggregateStatus(.{
                        .stage_count = stage_count,
                        .statuses = statuses,
                        .status_rule = rule,
                        .negated = negated,
                    });
                    const selected = switch (rule) {
                        .last_command => statuses[statuses.len - 1],
                        .pipefail => blk: {
                            var index = statuses.len;
                            while (index != 0) {
                                index -= 1;
                                if (statuses[index] != 0) break :blk statuses[index];
                            }
                            break :blk @as(state.ExitStatus, 0);
                        },
                    };
                    const final: state.ExitStatus = if (negated) (if (selected == 0) 1 else 0) else selected;
                    try std.testing.expectEqual(selected, aggregation.selected_status);
                    try std.testing.expectEqual(final, aggregation.final_status);
                }
            }
        }
    }
}
