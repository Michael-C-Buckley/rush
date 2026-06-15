//! Central POSIX shell-error and errexit consequence policy.
//!
//! Evaluators report ordinary command statuses and modeled shell errors as data;
//! this module is the single place that decides whether those statuses remain
//! normal outcomes, request an errexit shell exit, or become fatal shell errors.

const std = @import("std");

const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const outcome = @import("outcome.zig");
const redirection_plan = @import("redirection_plan.zig");
const state = @import("state.zig");

pub const ShellErrorKind = enum {
    nonzero_status,
    redirection_error,
    readonly_assignment,
    expansion_error,
    evaluation_error,
    special_builtin_failure,
};

pub const ErrorConsequence = enum {
    normal_outcome,
    errexit_exit,
    fatal_shell_error,
};

pub const Decision = struct {
    status: outcome.ExitStatus,
    kind: ?ShellErrorKind = null,
    consequence: ErrorConsequence = .normal_outcome,
    control_flow: outcome.ControlFlow = .normal,

    pub fn validate(self: Decision, eval_context: context.EvalContext) void {
        eval_context.validate();
        self.control_flow.validateForContext(eval_context);
        switch (self.consequence) {
            .normal_outcome => std.debug.assert(self.control_flow != .fatal),
            .errexit_exit => switch (self.control_flow) {
                .exit => |exit_status| {
                    std.debug.assert(self.status == exit_status);
                },
                else => unreachable,
            },
            .fatal_shell_error => switch (self.control_flow) {
                .fatal => |fatal_status| {
                    std.debug.assert(self.status == fatal_status);
                    std.debug.assert(fatal_status != 0);
                },
                else => unreachable,
            },
        }
        if (self.kind) |kind| {
            if (kind != .nonzero_status) std.debug.assert(self.status != 0);
        }
    }
};

pub fn decideForSimpleCommand(
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    status: outcome.ExitStatus,
    control_flow: outcome.ControlFlow,
) Decision {
    eval_context.validate();
    plan.validate();
    control_flow.validateForContext(eval_context);
    std.debug.assert(plan.target == eval_context.target);

    if (control_flow != .normal) return decisionForExistingFlow(eval_context, status, control_flow);
    if (status == 0) return normalDecision(eval_context, status, null);
    if (plan.class() == .special_builtin) {
        return decideForShellError(shell_options, eval_context, .special_builtin_failure, status);
    }
    return decideForStatus(shell_options, eval_context, status);
}

pub fn decideForCompoundCommand(
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    status: outcome.ExitStatus,
    control_flow: outcome.ControlFlow,
) Decision {
    eval_context.validate();
    control_flow.validateForContext(eval_context);
    if (control_flow != .normal) return decisionForExistingFlow(eval_context, status, control_flow);
    return decideForStatus(shell_options, eval_context, status);
}

pub fn decideForStatus(
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    status: outcome.ExitStatus,
) Decision {
    eval_context.validate();
    if (!shouldApplyErrexit(shell_options, eval_context, status)) {
        return normalDecision(eval_context, status, if (status == 0) null else .nonzero_status);
    }
    const decision: Decision = .{
        .status = status,
        .kind = .nonzero_status,
        .consequence = .errexit_exit,
        .control_flow = .{ .exit = status },
    };
    decision.validate(eval_context);
    return decision;
}

pub fn decideForShellError(
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    kind: ShellErrorKind,
    status: outcome.ExitStatus,
) Decision {
    eval_context.validate();
    std.debug.assert(kind != .nonzero_status);
    std.debug.assert(status != 0);

    if (isFatalShellError(kind, eval_context)) {
        const decision: Decision = .{
            .status = status,
            .kind = kind,
            .consequence = .fatal_shell_error,
            .control_flow = .{ .fatal = status },
        };
        decision.validate(eval_context);
        return decision;
    }

    if (shouldApplyErrexit(shell_options, eval_context, status)) {
        const decision: Decision = .{
            .status = status,
            .kind = kind,
            .consequence = .errexit_exit,
            .control_flow = .{ .exit = status },
        };
        decision.validate(eval_context);
        return decision;
    }

    return normalDecision(eval_context, status, kind);
}

pub fn decideForRedirectionFailure(
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    failure_consequence: redirection_plan.FailureConsequence,
    status: outcome.ExitStatus,
) Decision {
    eval_context.validate();
    std.debug.assert(status != 0);
    switch (failure_consequence) {
        .command_failure => return decideForShellError(shell_options, eval_context, .redirection_error, status),
        .fatal_shell_error => {
            const decision: Decision = .{
                .status = status,
                .kind = .redirection_error,
                .consequence = .fatal_shell_error,
                .control_flow = .{ .fatal = status },
            };
            decision.validate(eval_context);
            return decision;
        },
    }
}

pub fn statusForRedirectionFailure(failure_consequence: redirection_plan.FailureConsequence) outcome.ExitStatus {
    return switch (failure_consequence) {
        .command_failure => 1,
        .fatal_shell_error => 2,
    };
}

pub fn applyToOutcome(
    command_outcome: *outcome.CommandOutcome,
    eval_context: context.EvalContext,
    decision: Decision,
) void {
    command_outcome.validateForContext(eval_context);
    decision.validate(eval_context);
    std.debug.assert(command_outcome.status == decision.status);
    command_outcome.control_flow = decision.control_flow;
    command_outcome.validateForContext(eval_context);
}

pub fn shouldApplyErrexit(
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    status: outcome.ExitStatus,
) bool {
    eval_context.validate();
    if (status == 0) return false;
    if (!shell_options.enabled(.errexit)) return false;
    return eval_context.observesErrexit();
}

fn decisionForExistingFlow(
    eval_context: context.EvalContext,
    status: outcome.ExitStatus,
    control_flow: outcome.ControlFlow,
) Decision {
    const decision: Decision = switch (control_flow) {
        .normal => unreachable,
        .exit => .{ .status = status, .consequence = .errexit_exit, .control_flow = control_flow },
        .fatal => .{ .status = status, .consequence = .fatal_shell_error, .control_flow = control_flow },
        .return_from_scope, .break_loop, .continue_loop => .{ .status = status, .control_flow = control_flow },
    };
    decision.validate(eval_context);
    return decision;
}

fn normalDecision(eval_context: context.EvalContext, status: outcome.ExitStatus, kind: ?ShellErrorKind) Decision {
    const decision: Decision = .{ .status = status, .kind = kind };
    decision.validate(eval_context);
    return decision;
}

fn isFatalShellError(kind: ShellErrorKind, eval_context: context.EvalContext) bool {
    eval_context.validate();
    if (eval_context.interactive) return false;
    if (eval_context.features.isBash() and kind == .special_builtin_failure) return false;
    if (eval_context.features.isBash() and kind == .readonly_assignment) return false;
    return switch (kind) {
        .nonzero_status, .redirection_error => false,
        .readonly_assignment,
        .expansion_error,
        .evaluation_error,
        .special_builtin_failure,
        => true,
    };
}

test "consequence policy applies errexit only in observing contexts" {
    var options: state.ShellOptions = .{};
    const root = context.EvalContext.forTarget(.current_shell);

    try std.testing.expectEqual(ErrorConsequence.normal_outcome, decideForStatus(options, root, 1).consequence);
    options.set(.errexit, true);

    const unsuppressed = decideForStatus(options, root, 1);
    try std.testing.expectEqual(ErrorConsequence.errexit_exit, unsuppressed.consequence);
    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(outcome.ControlFlow{ .exit = 1 }, unsuppressed.control_flow);

    const suppressed = decideForStatus(options, root.ignoreErrexit(), 1);
    try std.testing.expectEqual(ErrorConsequence.normal_outcome, suppressed.consequence);
    try std.testing.expectEqual(outcome.ControlFlow.normal, suppressed.control_flow);
    try std.testing.expect(!shouldApplyErrexit(options, root.ignoreErrexit(), 1));
}

test "consequence policy treats modeled shell errors as fatal in non-interactive shells" {
    const root = context.EvalContext.forTarget(.current_shell);
    const ignored = root.ignoreErrexit();
    var options: state.ShellOptions = .{};
    options.set(.errexit, true);

    const readonly = decideForShellError(options, ignored, .readonly_assignment, 1);
    try std.testing.expectEqual(ErrorConsequence.fatal_shell_error, readonly.consequence);
    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(outcome.ControlFlow{ .fatal = 1 }, readonly.control_flow);

    const expansion = decideForShellError(.{}, root, .expansion_error, 2);
    try std.testing.expectEqual(ErrorConsequence.fatal_shell_error, expansion.consequence);

    const special = decideForShellError(.{}, root, .special_builtin_failure, 2);
    try std.testing.expectEqual(ErrorConsequence.fatal_shell_error, special.consequence);

    const bash = context.EvalContext.init(.{ .target = .current_shell, .features = .bash() });
    const bash_special = decideForShellError(.{}, bash, .special_builtin_failure, 2);
    try std.testing.expectEqual(ErrorConsequence.normal_outcome, bash_special.consequence);
    try std.testing.expectEqual(outcome.ControlFlow.normal, bash_special.control_flow);

    const interactive = context.EvalContext.init(.{ .target = .current_shell, .interactive = true });
    const interactive_readonly = decideForShellError(.{}, interactive, .readonly_assignment, 1);
    try std.testing.expectEqual(ErrorConsequence.normal_outcome, interactive_readonly.consequence);
    try std.testing.expectEqual(outcome.ControlFlow.normal, interactive_readonly.control_flow);
}

test "consequence policy normalizes redirection failures through one decision path" {
    var options: state.ShellOptions = .{};
    options.set(.errexit, true);
    const root = context.EvalContext.forTarget(.current_shell);

    const command_failure = decideForRedirectionFailure(
        options,
        root,
        .command_failure,
        statusForRedirectionFailure(.command_failure),
    );
    try std.testing.expectEqual(ErrorConsequence.errexit_exit, command_failure.consequence);
    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(outcome.ControlFlow{ .exit = 1 }, command_failure.control_flow);

    const suppressed = decideForRedirectionFailure(options, root.ignoreErrexit(), .command_failure, 1);
    try std.testing.expectEqual(ErrorConsequence.normal_outcome, suppressed.consequence);

    const fatal = decideForRedirectionFailure(
        .{},
        root.ignoreErrexit(),
        .fatal_shell_error,
        statusForRedirectionFailure(.fatal_shell_error),
    );
    try std.testing.expectEqual(ErrorConsequence.fatal_shell_error, fatal.consequence);
    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(outcome.ControlFlow{ .fatal = 2 }, fatal.control_flow);
}

test "consequence policy applies special builtin failures before errexit" {
    var options: state.ShellOptions = .{};
    options.set(.errexit, true);
    const argv = [_][]const u8{ "return", "extra" };
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &argv } });

    const decision = decideForSimpleCommand(
        options,
        context.EvalContext.forTarget(.current_shell).ignoreErrexit(),
        plan,
        2,
        .normal,
    );
    try std.testing.expectEqual(ShellErrorKind.special_builtin_failure, decision.kind.?);
    try std.testing.expectEqual(ErrorConsequence.fatal_shell_error, decision.consequence);
    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(outcome.ControlFlow{ .fatal = 2 }, decision.control_flow);
}
