//! Semantic execution boundary model for shell evaluation.
//!
//! `ExecutionFrame` describes where a command reads, writes, captures output,
//! mutates shell state, observes traps, and reports fatal failures. It is a
//! shell-shaped semantic object, not a fd/process graph: runtime adapters still
//! own pipe creation, fork/exec, descriptor syscalls, buffering, and backpressure.
//!
//! Invariants intentionally live in this module so later evaluator migrations
//! have one vocabulary for boundary behavior:
//! - routing belongs to the active frame;
//! - redirections are ordered transforms of the active frame's fd table;
//! - pipeline data is distinct from parent-visible stdout;
//! - command-substitution stdout is a private capture;
//! - fatal failures are distinct from ordinary command statuses;
//! - user and runtime failures are diagnostics, statuses, or boundary outcomes,
//!   never assertions.

const std = @import("std");

const context = @import("context.zig");
const outcome = @import("outcome.zig");
const redirection_plan = @import("redirection_plan.zig");
const fd = @import("../runtime/fd.zig");

pub const BoundaryKind = enum {
    top_level,
    current_shell_command,
    function_body,
    sourced_script,
    subshell,
    pipeline_stage,
    command_substitution,
    external_command,

    pub fn isParentVisible(self: BoundaryKind) bool {
        return switch (self) {
            .top_level,
            .current_shell_command,
            .function_body,
            .sourced_script,
            => true,
            .subshell,
            .pipeline_stage,
            .command_substitution,
            .external_command,
            => false,
        };
    }
};

pub const MutationPolicy = enum {
    commit_to_parent_shell,
    commit_within_subshell,
    discard_at_boundary,

    pub fn allowsParentMutation(self: MutationPolicy) bool {
        return self == .commit_to_parent_shell;
    }
};

pub const TrapPolicy = enum {
    inherit,
    reset_caught,
    command_substitution,
    isolated_child,
};

pub const FailurePolicy = enum {
    ordinary_status,
    propagate_fatal_to_parent,
    contain_fatal_at_boundary,
};

pub const InputEndpoint = union(enum) {
    inherit_stdin,
    bytes: []const u8,
    fd: fd.Descriptor,
    pipe_read: fd.Descriptor,
    closed,

    pub fn validate(self: InputEndpoint) void {
        switch (self) {
            .fd, .pipe_read => |descriptor| fd.assertValidDescriptor(descriptor),
            .inherit_stdin, .bytes, .closed => {},
        }
    }
};

pub const CaptureChannel = enum {
    side_stdout,
    side_stderr,
    pipeline_data,
    command_substitution_stdout,

    pub fn isParentVisible(self: CaptureChannel) bool {
        return switch (self) {
            .side_stdout, .side_stderr => true,
            .pipeline_data, .command_substitution_stdout => false,
        };
    }
};

pub const OutputEndpoint = union(enum) {
    inherit_stdout,
    inherit_stderr,
    fd: fd.Descriptor,
    pipe_write: fd.Descriptor,
    capture: CaptureChannel,
    discard,

    pub fn validate(self: OutputEndpoint) void {
        switch (self) {
            .fd, .pipe_write => |descriptor| fd.assertValidDescriptor(descriptor),
            .inherit_stdout, .inherit_stderr, .capture, .discard => {},
        }
    }

    pub fn isCapture(self: OutputEndpoint) bool {
        return switch (self) {
            .capture => true,
            .inherit_stdout, .inherit_stderr, .fd, .pipe_write, .discard => false,
        };
    }

    pub fn captureChannel(self: OutputEndpoint) ?CaptureChannel {
        return switch (self) {
            .capture => |channel| channel,
            .inherit_stdout, .inherit_stderr, .fd, .pipe_write, .discard => null,
        };
    }

    pub fn isPipeWrite(self: OutputEndpoint) bool {
        return switch (self) {
            .pipe_write => true,
            .inherit_stdout, .inherit_stderr, .fd, .capture, .discard => false,
        };
    }

    pub fn isInheritStdout(self: OutputEndpoint) bool {
        return self == .inherit_stdout;
    }
};

pub const FdBinding = struct {
    descriptor: fd.Descriptor,
    endpoint: FdEndpoint,

    pub fn validate(self: FdBinding) void {
        fd.assertValidDescriptor(self.descriptor);
        self.endpoint.validate();
    }
};

pub const FdEndpoint = union(enum) {
    input: InputEndpoint,
    output: OutputEndpoint,
    closed,

    pub fn validate(self: FdEndpoint) void {
        switch (self) {
            .input => |endpoint| endpoint.validate(),
            .output => |endpoint| endpoint.validate(),
            .closed => {},
        }
    }
};

pub const CapturedBytes = struct {
    channel: CaptureChannel,
    bytes: []const u8,

    pub fn validate(self: CapturedBytes) void {
        _ = self.bytes;
    }
};

/// Semantic descriptor table owned by one active frame. Redirection plans are
/// ordered transforms of this table; this task only records the pre/post shape
/// needed for later evaluator migration.
pub const FdTable = struct {
    bindings: []const FdBinding = &.{},
    redirections: redirection_plan.RedirectionPlan = .{},

    pub fn validate(self: FdTable) void {
        for (self.bindings, 0..) |binding, index| {
            binding.validate();
            for (self.bindings[0..index]) |previous| {
                std.debug.assert(previous.descriptor != binding.descriptor);
            }
        }
        self.redirections.validate();
    }
};

pub const Captures = struct {
    channels: []const CaptureChannel = &.{},

    pub fn none() Captures {
        return .{};
    }

    pub fn commandSubstitution() Captures {
        return .{ .channels = &.{.command_substitution_stdout} };
    }

    pub fn pipelineStage() Captures {
        return .{ .channels = &.{.pipeline_data} };
    }

    pub fn contains(self: Captures, channel: CaptureChannel) bool {
        for (self.channels) |entry| {
            if (entry == channel) return true;
        }
        return false;
    }

    pub fn validate(self: Captures) void {
        for (self.channels, 0..) |channel, index| {
            for (self.channels[0..index]) |previous| {
                std.debug.assert(previous != channel);
            }
        }
    }

    pub fn validateFor(self: Captures, spec: BoundarySpec) void {
        self.validate();
        if (spec.kind == .command_substitution) {
            std.debug.assert(self.contains(.command_substitution_stdout));
            std.debug.assert(spec.stdout.captureChannel() == .command_substitution_stdout);
            std.debug.assert(!self.contains(.pipeline_data));
        }
        if (self.contains(.pipeline_data)) {
            std.debug.assert(spec.kind == .pipeline_stage);
            std.debug.assert(spec.stdout.captureChannel() == .pipeline_data or spec.stdout.isPipeWrite());
            std.debug.assert(!spec.stdout.isInheritStdout());
        }
        if (spec.stdout.captureChannel()) |channel| std.debug.assert(self.contains(channel));
        if (spec.stderr.captureChannel()) |channel| std.debug.assert(self.contains(channel));
    }
};

pub const BoundarySpec = struct {
    kind: BoundaryKind,
    eval_target: context.ExecutionTarget,
    stdin: InputEndpoint = .inherit_stdin,
    stdout: OutputEndpoint = .inherit_stdout,
    stderr: OutputEndpoint = .inherit_stderr,
    fd_table: FdTable = .{},
    captures: Captures = .{},
    mutation_policy: MutationPolicy,
    trap_policy: TrapPolicy = .inherit,
    failure_policy: FailurePolicy = .ordinary_status,

    pub fn validate(self: BoundarySpec) void {
        self.stdin.validate();
        self.stdout.validate();
        self.stderr.validate();
        self.fd_table.validate();
        self.captures.validateFor(self);

        std.debug.assert(self.kind.isParentVisible() == self.mutation_policy.allowsParentMutation());
        if (self.mutation_policy.allowsParentMutation()) {
            std.debug.assert(self.eval_target == .current_shell);
        } else {
            std.debug.assert(self.eval_target != .current_shell or self.kind == .external_command);
        }
        if (self.kind == .pipeline_stage) std.debug.assert(!self.stdout.isInheritStdout());
        if (self.kind == .command_substitution) {
            std.debug.assert(self.eval_target == .subshell);
            std.debug.assert(self.trap_policy == .command_substitution);
            std.debug.assert(self.failure_policy != .ordinary_status);
        }
    }
};

pub const ExecutionFrame = struct {
    spec: BoundarySpec,
    parent: ParentBoundary = .none,

    pub fn init(spec: BoundarySpec) ExecutionFrame {
        const frame: ExecutionFrame = .{ .spec = spec };
        frame.validate();
        return frame;
    }

    pub fn child(self: ExecutionFrame, spec: BoundarySpec) ExecutionFrame {
        self.validate();
        const frame: ExecutionFrame = .{ .spec = spec, .parent = .{ .kind = self.spec.kind } };
        frame.validate();
        return frame;
    }

    pub fn validate(self: ExecutionFrame) void {
        self.spec.validate();
        self.parent.validate();
    }
};

pub const ParentBoundary = union(enum) {
    none,
    kind: BoundaryKind,

    pub fn validate(_: ParentBoundary) void {}
};

pub const BoundaryOutcome = union(enum) {
    completed: CompletedBoundary,
    fatal: PropagatedFailure,
    runtime_failure: RuntimeFailure,

    pub fn validate(self: BoundaryOutcome) void {
        switch (self) {
            .completed => |completed| completed.validate(),
            .fatal => |failure| failure.validate(),
            .runtime_failure => |failure| failure.validate(),
        }
    }
};

pub const CompletedBoundary = struct {
    status: outcome.ExitStatus,
    control_flow: outcome.ControlFlow = .normal,
    captures: []const CapturedBytes = &.{},

    pub fn validate(self: CompletedBoundary) void {
        self.control_flow.validate();
        std.debug.assert(self.control_flow.status(self.status) == self.status);
        for (self.captures, 0..) |capture, index| {
            capture.validate();
            for (self.captures[0..index]) |previous| {
                std.debug.assert(previous.channel != capture.channel);
            }
        }
    }
};

pub const PropagatedFailure = union(enum) {
    command_substitution: outcome.ExitStatus,
    parse_error: outcome.ExitStatus,
    expansion_error: outcome.ExitStatus,
    redirection_error: outcome.ExitStatus,

    pub fn validate(self: PropagatedFailure) void {
        std.debug.assert(self.status() != 0);
    }

    pub fn status(self: PropagatedFailure) outcome.ExitStatus {
        return switch (self) {
            .command_substitution,
            .parse_error,
            .expansion_error,
            .redirection_error,
            => |exit_status| exit_status,
        };
    }
};

pub const RuntimeFailure = struct {
    status: outcome.ExitStatus,
    diagnostic: []const u8,

    pub fn validate(self: RuntimeFailure) void {
        std.debug.assert(self.status != 0);
        std.debug.assert(self.diagnostic.len != 0);
    }
};

test "ExecutionFrame validates parent-visible and isolated boundary policies" {
    const root = ExecutionFrame.init(.{
        .kind = .top_level,
        .eval_target = .current_shell,
        .mutation_policy = .commit_to_parent_shell,
    });
    try std.testing.expect(root.spec.kind.isParentVisible());
    try std.testing.expect(root.spec.mutation_policy.allowsParentMutation());

    const pipeline_stage = root.child(.{
        .kind = .pipeline_stage,
        .eval_target = .child_process,
        .stdout = .{ .capture = .pipeline_data },
        .captures = Captures.pipelineStage(),
        .mutation_policy = .discard_at_boundary,
        .trap_policy = .isolated_child,
    });
    try std.testing.expect(!pipeline_stage.spec.kind.isParentVisible());
    switch (pipeline_stage.parent) {
        .kind => |kind| try std.testing.expectEqual(BoundaryKind.top_level, kind),
        .none => try std.testing.expect(false),
    }
}

test "command substitution stdout is private capture" {
    const frame = ExecutionFrame.init(.{
        .kind = .command_substitution,
        .eval_target = .subshell,
        .stdout = .{ .capture = .command_substitution_stdout },
        .captures = Captures.commandSubstitution(),
        .mutation_policy = .commit_within_subshell,
        .trap_policy = .command_substitution,
        .failure_policy = .propagate_fatal_to_parent,
    });
    try std.testing.expect(frame.spec.stdout.isCapture());
    try std.testing.expect(frame.spec.captures.contains(.command_substitution_stdout));
}

test "fd table endpoints validate distinct descriptor bindings" {
    const bindings = [_]FdBinding{
        .{ .descriptor = 0, .endpoint = .{ .input = .inherit_stdin } },
        .{ .descriptor = 1, .endpoint = .{ .output = .inherit_stdout } },
        .{ .descriptor = 2, .endpoint = .{ .output = .inherit_stderr } },
    };
    const table: FdTable = .{ .bindings = &bindings };
    table.validate();
}

test "boundary outcomes keep fatal failures separate from ordinary statuses" {
    const ordinary: BoundaryOutcome = .{ .completed = .{ .status = 1 } };
    ordinary.validate();

    const fatal: BoundaryOutcome = .{ .fatal = .{ .command_substitution = 2 } };
    fatal.validate();

    const runtime_failure: BoundaryOutcome = .{
        .runtime_failure = .{ .status = 126, .diagnostic = "permission denied" },
    };
    runtime_failure.validate();
}
