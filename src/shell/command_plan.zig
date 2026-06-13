//! Side-effect-free semantic command plans.
//!
//! `CommandPlan` is the core representation after parser/IR interpretation and
//! before runtime effects. It names the semantic target for mutations while
//! leaving command lowering and dispatch unimplemented.

const context = @import("context.zig");
const redirection_plan = @import("redirection_plan.zig");

pub const CommandKind = enum {
    simple,
    compound,
    function_definition,
};

pub const Dispatch = enum {
    unknown,
    builtin,
    function,
    external,
};

pub const CommandPlan = struct {
    kind: CommandKind,
    target: context.ExecutionTarget,
    dispatch: Dispatch = .unknown,
    redirections: []const redirection_plan.RedirectionPlan = &.{},

    pub fn init(kind: CommandKind, target: context.ExecutionTarget) CommandPlan {
        return .{ .kind = kind, .target = target };
    }
};
