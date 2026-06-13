//! Semantic evaluation entry point for the redesigned shell core.
//!
//! Evaluation will consume side-effect-free plans, call runtime ports for host
//! effects, and return `CommandOutcome` data. Behavior remains unported in this
//! skeleton so the old executor stays the reference.

const std = @import("std");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const outcome = @import("outcome.zig");

pub const EvalError = error{
    Unimplemented,
};

pub const Evaluator = struct {};

pub fn evaluatePlan(evaluator: *Evaluator, eval_context: context.EvalContext, plan: command_plan.CommandPlan) EvalError!outcome.CommandOutcome {
    _ = evaluator;
    std.debug.assert(plan.target == eval_context.target);
    return error.Unimplemented;
}
