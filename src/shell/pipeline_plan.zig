//! Semantic pipeline plans.
//!
//! Pipelines keep command order, status rules, and segment target constraints in
//! the shell core. Pipe creation and process orchestration remain runtime-port
//! responsibilities.

const std = @import("std");
const command_plan = @import("command_plan.zig");

pub const PipelineStatusRule = enum {
    last_command,
    pipefail,
};

pub const PipelinePlan = struct {
    commands: []const command_plan.CommandPlan,
    negated: bool = false,
    status_rule: PipelineStatusRule = .last_command,

    pub fn init(commands: []const command_plan.CommandPlan) PipelinePlan {
        std.debug.assert(commands.len != 0);
        return .{ .commands = commands };
    }
};
