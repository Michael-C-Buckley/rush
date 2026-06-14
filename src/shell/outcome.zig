//! Result values produced by the redesigned semantic shell core.
//!
//! Outcomes keep ordinary shell diagnostics and control flow in data. Internal
//! model bugs remain assertions in the code that builds, commits, or discards
//! plans and deltas.

const std = @import("std");
const context = @import("context.zig");
const delta = @import("delta.zig");
const state = @import("state.zig");

pub const ExitStatus = state.ExitStatus;

pub const Diagnostic = struct {
    message: []const u8,
};

pub const ReturnScope = enum {
    function,
    sourced_script,
};

pub const ReturnRequest = struct {
    scope: ReturnScope,
    status: ExitStatus,
};

pub const ControlFlow = union(enum) {
    normal,
    exit: ExitStatus,
    return_from_scope: ReturnRequest,
    break_loop: u32,
    continue_loop: u32,
    fatal: ExitStatus,

    pub fn validate(self: ControlFlow) void {
        switch (self) {
            .normal => {},
            .exit => {},
            .return_from_scope => {},
            .break_loop => |depth| std.debug.assert(depth != 0),
            .continue_loop => |depth| std.debug.assert(depth != 0),
            .fatal => |fatal_status| std.debug.assert(fatal_status != 0),
        }
    }

    pub fn validateForContext(self: ControlFlow, eval_context: context.EvalContext) void {
        self.validate();
        switch (self) {
            .normal, .exit, .fatal => {},
            .return_from_scope => |request| switch (request.scope) {
                .function => std.debug.assert(eval_context.canReturnFromFunction()),
                .sourced_script => std.debug.assert(eval_context.canReturnFromSource()),
            },
            .break_loop, .continue_loop => |depth| std.debug.assert(eval_context.canBreakOrContinue(depth)),
        }
    }

    pub fn status(self: ControlFlow, normal_status: ExitStatus) ExitStatus {
        return switch (self) {
            .normal, .break_loop, .continue_loop => normal_status,
            .exit => |exit_status| exit_status,
            .return_from_scope => |request| request.status,
            .fatal => |fatal_status| fatal_status,
        };
    }
};

pub const CommandOutcome = struct {
    allocator: std.mem.Allocator,
    status: ExitStatus,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    state_delta: delta.StateDelta,
    control_flow: ControlFlow = .normal,

    pub const ApplyOptions = struct {
        /// Top-level command runners record exit/fatal control flow as a pending
        /// shell exit after the command's semantic mutations are applied.
        record_exit_control_flow: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, status: ExitStatus, state_delta: delta.StateDelta) CommandOutcome {
        var outcome: CommandOutcome = .{
            .allocator = allocator,
            .status = status,
            .state_delta = state_delta,
        };
        outcome.validate();
        return outcome;
    }

    pub fn withControlFlow(
        allocator: std.mem.Allocator,
        status_value: ExitStatus,
        state_delta: delta.StateDelta,
        control_flow: ControlFlow,
    ) CommandOutcome {
        var outcome: CommandOutcome = .{
            .allocator = allocator,
            .status = status_value,
            .state_delta = state_delta,
            .control_flow = control_flow,
        };
        outcome.validate();
        return outcome;
    }

    pub fn deinit(self: *CommandOutcome) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
        for (self.diagnostics.items) |diagnostic| {
            self.allocator.free(diagnostic.message);
        }
        self.diagnostics.deinit(self.allocator);
        self.state_delta.deinit();
        self.* = undefined;
    }

    pub fn appendStdout(self: *CommandOutcome, bytes: []const u8) !void {
        try self.stdout.appendSlice(self.allocator, bytes);
    }

    pub fn appendStderr(self: *CommandOutcome, bytes: []const u8) !void {
        try self.stderr.appendSlice(self.allocator, bytes);
    }

    pub fn addDiagnostic(self: *CommandOutcome, message: []const u8) !void {
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        try self.diagnostics.append(self.allocator, .{ .message = owned_message });
    }

    pub fn validate(self: CommandOutcome) void {
        self.control_flow.validate();
        std.debug.assert(self.state_delta.state == .pending or self.state_delta.state == .consumed);

        switch (self.control_flow) {
            .normal => {},
            .exit => |exit_status| std.debug.assert(self.status == exit_status),
            .return_from_scope => |request| std.debug.assert(self.status == request.status),
            .break_loop, .continue_loop => std.debug.assert(self.status == 0),
            .fatal => |fatal_status| {
                std.debug.assert(fatal_status != 0);
                std.debug.assert(self.status == fatal_status);
            },
        }
    }

    pub fn validateForContext(self: CommandOutcome, eval_context: context.EvalContext) void {
        self.validate();
        self.control_flow.validateForContext(eval_context);
    }

    pub fn commitDelta(self: *CommandOutcome, shell_state: *state.ShellState, target: context.ExecutionTarget) !void {
        self.validate();
        try self.state_delta.commit(shell_state, target);
    }

    pub fn discardDelta(self: *CommandOutcome, target: context.ExecutionTarget) void {
        self.validate();
        self.state_delta.discard(target);
    }

    pub fn applyToShellState(
        self: *CommandOutcome,
        shell_state: *state.ShellState,
        options: ApplyOptions,
    ) !void {
        self.validate();
        shell_state.validate();

        const target = self.state_delta.target;
        if (target.allowsShellStateCommit() and shell_state.acceptsExecutionTarget(target)) {
            try self.commitDelta(shell_state, target);
        } else {
            std.debug.assert(target.isIsolatedFromParent());
            self.discardDelta(target);
            shell_state.last_status = self.control_flow.status(self.status);
        }

        if (options.record_exit_control_flow) {
            switch (self.control_flow) {
                .exit, .fatal => |exit_status| shell_state.setPendingExit(exit_status),
                .normal, .break_loop, .continue_loop, .return_from_scope => {},
            }
        }
        shell_state.validate();
    }
};

pub fn readonlyVariableFailure(
    allocator: std.mem.Allocator,
    target: context.ExecutionTarget,
    name: []const u8,
) !CommandOutcome {
    state.assertValidVariableName(name);

    const state_delta = delta.StateDelta.init(allocator, target);
    var command_outcome = CommandOutcome.init(allocator, 1, state_delta);
    errdefer command_outcome.deinit();

    const message = try std.fmt.allocPrint(allocator, "{s}: readonly variable", .{name});
    errdefer allocator.free(message);
    try command_outcome.diagnostics.append(allocator, .{ .message = message });

    return command_outcome;
}

test "ControlFlow validates payloads against EvalContext scopes" {
    const loop_context = context.EvalContext.forTarget(.current_shell).enterLoop();
    const function_context = loop_context.enterFunction();
    const source_context = loop_context.enterSource();

    const normal_flow: ControlFlow = .normal;
    normal_flow.validateForContext(loop_context);
    (ControlFlow{ .break_loop = 1 }).validateForContext(loop_context);
    (ControlFlow{ .continue_loop = 1 }).validateForContext(loop_context);
    (ControlFlow{ .return_from_scope = .{ .scope = .function, .status = 3 } }).validateForContext(function_context);
    (ControlFlow{ .return_from_scope = .{ .scope = .sourced_script, .status = 4 } }).validateForContext(source_context);
    (ControlFlow{ .exit = 2 }).validateForContext(loop_context);
    (ControlFlow{ .fatal = 2 }).validateForContext(loop_context);

    try std.testing.expectEqual(@as(ExitStatus, 9), normal_flow.status(9));
    try std.testing.expectEqual(@as(ExitStatus, 2), (ControlFlow{ .exit = 2 }).status(9));
}

test "CommandOutcome owns diagnostics and commits or discards its delta" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var state_delta = delta.StateDelta.init(std.testing.allocator, .current_shell);
    try state_delta.assignVariable("name", "value", .{});
    state_delta.setLastStatus(5);

    var outcome = CommandOutcome.init(std.testing.allocator, 5, state_delta);
    defer outcome.deinit();

    try outcome.addDiagnostic("note");
    try outcome.appendStdout("out");
    try outcome.appendStderr("err");
    try std.testing.expectEqual(@as(usize, 1), outcome.diagnostics.items.len);
    try std.testing.expectEqualStrings("note", outcome.diagnostics.items[0].message);
    try std.testing.expectEqualStrings("out", outcome.stdout.items);
    try std.testing.expectEqualStrings("err", outcome.stderr.items);

    try outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(delta.DeltaState.consumed, outcome.state_delta.state);
    try std.testing.expectEqualStrings("value", shell_state.getVariable("name").?.value);
    try std.testing.expectEqual(@as(ExitStatus, 5), shell_state.last_status);
}

test "CommandOutcome applies isolated command status without committing child delta" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var state_delta = delta.StateDelta.init(std.testing.allocator, .child_process);
    try state_delta.assignVariable("child_only", "value", .{});
    state_delta.setLastStatus(7);

    var command_outcome = CommandOutcome.init(std.testing.allocator, 7, state_delta);
    defer command_outcome.deinit();

    try command_outcome.applyToShellState(&shell_state, .{});
    try std.testing.expectEqual(delta.DeltaState.consumed, command_outcome.state_delta.state);
    try std.testing.expectEqual(@as(ExitStatus, 7), shell_state.last_status);
    try std.testing.expect(shell_state.getVariable("child_only") == null);
}

test "CommandOutcome can record top-level exit control flow" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var state_delta = delta.StateDelta.init(std.testing.allocator, .current_shell);
    state_delta.setLastStatus(3);

    var command_outcome = CommandOutcome.withControlFlow(
        std.testing.allocator,
        3,
        state_delta,
        .{ .exit = 3 },
    );
    defer command_outcome.deinit();

    try command_outcome.applyToShellState(&shell_state, .{ .record_exit_control_flow = true });
    try std.testing.expectEqual(@as(ExitStatus, 3), shell_state.last_status);
    try std.testing.expectEqual(@as(?ExitStatus, 3), shell_state.pending_exit);
}

test "CommandOutcome control-flow statuses are internally consistent" {
    const flows = [_]ControlFlow{
        .normal,
        .{ .exit = 7 },
        .{ .return_from_scope = .{ .scope = .function, .status = 8 } },
        .{ .break_loop = 1 },
        .{ .continue_loop = 1 },
        .{ .fatal = 2 },
    };
    const statuses = [_]ExitStatus{ 0, 7, 8, 0, 0, 2 };

    for (flows, statuses) |flow, status_value| {
        const state_delta = delta.StateDelta.init(std.testing.allocator, .current_shell);
        var outcome = CommandOutcome.withControlFlow(std.testing.allocator, status_value, state_delta, flow);
        defer outcome.deinit();
        outcome.validate();
    }
}

test "CommandOutcome can carry readonly assignment diagnostics" {
    var command_outcome = try readonlyVariableFailure(std.testing.allocator, .current_shell, "LOCKED");
    defer command_outcome.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 1), command_outcome.status);
    try std.testing.expectEqual(@as(usize, 1), command_outcome.diagnostics.items.len);
    try std.testing.expectEqualStrings("LOCKED: readonly variable", command_outcome.diagnostics.items[0].message);
    try std.testing.expect(command_outcome.state_delta.isEmpty());
}
