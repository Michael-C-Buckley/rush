//! Compatibility facade for semantic pipeline plans.
//!
//! Pipelines are mutually recursive with semantic statement lists, so the
//! canonical plan types live in `command_plan.zig`. This module keeps the
//! previous import path stable for callers and tests.

const std = @import("std");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const state = @import("state.zig");

pub const PipelineStatusRule = command_plan.PipelineStatusRule;
pub const PipelineBackgroundMode = command_plan.PipelineBackgroundMode;
pub const PipelineExecutionStrategy = command_plan.PipelineExecutionStrategy;
pub const PipelineOptions = command_plan.PipelineOptions;
pub const PipelineStagePlan = command_plan.PipelineStagePlan;
pub const PipelinePlan = command_plan.PipelinePlan;
pub const StatusAggregationInput = command_plan.StatusAggregationInput;
pub const StatusAggregation = command_plan.StatusAggregation;
pub const aggregateStatus = command_plan.aggregateStatus;

test "PipelinePlan selects strategy and stage targets before runtime effects" {
    const echo = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"echo"} },
    });
    const true_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"true"} },
    });
    const externals = [_]command_plan.ExternalResolution{
        .{ .name = "cat", .path = "/bin/cat" },
        .{ .name = "wc", .path = "/usr/bin/wc" },
    };
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const cat = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"cat"} },
        .lookup = lookup,
    });
    const wc = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"wc"} },
        .lookup = lookup,
    });

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

    const background = PipelinePlan.init(
        &[_]PipelineStagePlan{ .{ .simple = cat }, .{ .simple = wc } },
        .{ .background = .background },
    );
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
