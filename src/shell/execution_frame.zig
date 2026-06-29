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
const zig_builtin = @import("builtin");

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
    trap_handler,
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
            .trap_handler,
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
    path: FileInputEndpoint,
    fd: fd.Descriptor,
    pipe_read: fd.Descriptor,
    closed,

    pub fn validate(self: InputEndpoint) void {
        switch (self) {
            .path => |path| path.validate(),
            .fd, .pipe_read => |descriptor| fd.assertValidDescriptor(descriptor),
            .inherit_stdin, .bytes, .closed => {},
        }
    }
};

pub const FileInputEndpoint = struct {
    path: []const u8,
    options: fd.OpenOptions,

    pub fn validate(self: FileInputEndpoint) void {
        self.options.validate();
        std.debug.assert(self.options.access != .write_only);
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
    path: FileOutputEndpoint,
    fd: fd.Descriptor,
    pipe_write: fd.Descriptor,
    capture: CaptureChannel,
    discard,

    pub fn validate(self: OutputEndpoint) void {
        switch (self) {
            .path => |path| path.validate(),
            .fd, .pipe_write => |descriptor| fd.assertValidDescriptor(descriptor),
            .inherit_stdout, .inherit_stderr, .capture, .discard => {},
        }
    }

    pub fn isCapture(self: OutputEndpoint) bool {
        return switch (self) {
            .capture => true,
            .inherit_stdout, .inherit_stderr, .path, .fd, .pipe_write, .discard => false,
        };
    }

    pub fn captureChannel(self: OutputEndpoint) ?CaptureChannel {
        return switch (self) {
            .capture => |channel| channel,
            .inherit_stdout, .inherit_stderr, .path, .fd, .pipe_write, .discard => null,
        };
    }

    pub fn isPipeWrite(self: OutputEndpoint) bool {
        return switch (self) {
            .pipe_write => true,
            .inherit_stdout, .inherit_stderr, .path, .fd, .capture, .discard => false,
        };
    }

    pub fn isInheritStdout(self: OutputEndpoint) bool {
        return self == .inherit_stdout;
    }
};

fn expectOutputPath(endpoint: FdEndpoint, path: []const u8) !void {
    switch (endpoint) {
        .output => |output| switch (output) {
            .path => |file| try std.testing.expectEqualStrings(path, file.path),
            else => return error.ExpectedOutputPath,
        },
        else => return error.ExpectedOutputEndpoint,
    }
}

fn expectOutputCapture(endpoint: FdEndpoint, channel: CaptureChannel) !void {
    switch (endpoint) {
        .output => |output| switch (output) {
            .capture => |capture| try std.testing.expectEqual(channel, capture),
            else => return error.ExpectedOutputCapture,
        },
        else => return error.ExpectedOutputEndpoint,
    }
}

fn expectInputBytes(endpoint: FdEndpoint, bytes: []const u8) !void {
    switch (endpoint) {
        .input => |input| switch (input) {
            .bytes => |actual| try std.testing.expectEqualStrings(bytes, actual),
            else => return error.ExpectedInputBytes,
        },
        else => return error.ExpectedInputEndpoint,
    }
}

fn expectClosed(endpoint: FdEndpoint) !void {
    switch (endpoint) {
        .closed => {},
        else => return error.ExpectedClosedEndpoint,
    }
}

pub const FileOutputEndpoint = struct {
    path: []const u8,
    options: fd.OpenOptions,
    noclobber: bool = false,

    pub fn validate(self: FileOutputEndpoint) void {
        self.options.validate();
        std.debug.assert(self.options.access != .read_only);
        std.debug.assert(!self.noclobber or self.options.exclusive);
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
    bidirectional_fd: fd.Descriptor,
    closed,

    pub fn validate(self: FdEndpoint) void {
        switch (self) {
            .input => |endpoint| endpoint.validate(),
            .output => |endpoint| endpoint.validate(),
            .bidirectional_fd => |descriptor| fd.assertValidDescriptor(descriptor),
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
    bindings: std.ArrayList(FdBinding) = .empty,
    redirections: redirection_plan.RedirectionPlan = .{},

    pub fn deinit(self: *FdTable, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
        self.redirections.deinit();
        self.* = undefined;
    }

    pub fn clone(self: FdTable, allocator: std.mem.Allocator) !FdTable {
        self.validate();
        const bindings = try allocator.dupe(FdBinding, self.bindings.items);
        errdefer allocator.free(bindings);
        var redirections = try self.redirections.clone(allocator);
        errdefer redirections.deinit();
        var table: FdTable = .{
            .bindings = std.ArrayList(FdBinding).fromOwnedSlice(bindings),
            .redirections = redirections,
        };
        table.validate();
        return table;
    }

    pub fn bind(
        self: *FdTable,
        allocator: std.mem.Allocator,
        descriptor: fd.Descriptor,
        fd_endpoint: FdEndpoint,
    ) !void {
        fd.assertValidDescriptor(descriptor);
        fd_endpoint.validate();
        if (self.bindingIndex(descriptor)) |index| {
            self.bindings.items[index] = .{ .descriptor = descriptor, .endpoint = fd_endpoint };
        } else {
            try self.bindings.append(allocator, .{ .descriptor = descriptor, .endpoint = fd_endpoint });
        }
        self.validate();
    }

    pub fn bindInput(
        self: *FdTable,
        allocator: std.mem.Allocator,
        descriptor: fd.Descriptor,
        input_endpoint: InputEndpoint,
    ) !void {
        try self.bind(allocator, descriptor, .{ .input = input_endpoint });
    }

    pub fn bindOutput(
        self: *FdTable,
        allocator: std.mem.Allocator,
        descriptor: fd.Descriptor,
        output_endpoint: OutputEndpoint,
    ) !void {
        try self.bind(allocator, descriptor, .{ .output = output_endpoint });
    }

    pub fn close(self: *FdTable, allocator: std.mem.Allocator, descriptor: fd.Descriptor) !void {
        try self.bind(allocator, descriptor, .closed);
    }

    pub fn endpoint(self: FdTable, descriptor: fd.Descriptor) FdEndpoint {
        fd.assertValidDescriptor(descriptor);
        if (self.bindingIndex(descriptor)) |index| return self.bindings.items[index].endpoint;
        return defaultEndpoint(descriptor);
    }

    pub fn boundEndpoint(self: FdTable, descriptor: fd.Descriptor) ?FdEndpoint {
        fd.assertValidDescriptor(descriptor);
        if (self.bindingIndex(descriptor)) |index| return self.bindings.items[index].endpoint;
        return null;
    }

    pub fn applyRedirectionPlan(
        self: *FdTable,
        allocator: std.mem.Allocator,
        plan: redirection_plan.RedirectionPlan,
    ) !void {
        plan.validate();
        for (plan.steps) |step| try self.applyRedirectionStep(allocator, step);
        var owned_plan = try plan.clone(allocator);
        errdefer owned_plan.deinit();
        self.redirections.deinit();
        self.redirections = owned_plan;
        self.validate();
    }

    pub fn applyRedirectionStep(
        self: *FdTable,
        allocator: std.mem.Allocator,
        step: redirection_plan.RedirectionStep,
    ) !void {
        step.validate();
        switch (step.effect) {
            .open_path => |open| switch (open.options.access) {
                .read_only => try self.bindInput(allocator, open.target, .{ .path = .{
                    .path = open.path.bytes,
                    .options = open.options,
                } }),
                .write_only, .read_write => try self.bindOutput(allocator, open.target, .{ .path = .{
                    .path = open.path.bytes,
                    .options = open.options,
                    .noclobber = open.noclobber,
                } }),
            },
            .here_doc => |here_doc| try self.bindInput(allocator, here_doc.target, .{ .bytes = here_doc.data.bytes }),
            .duplicate => |duplicate| try self.bind(allocator, duplicate.target, self.endpoint(duplicate.source)),
            .close => |close_step| try self.close(allocator, close_step.target),
        }
    }

    pub fn validate(self: FdTable) void {
        for (self.bindings.items, 0..) |binding, index| {
            binding.validate();
            for (self.bindings.items[0..index]) |previous| {
                std.debug.assert(previous.descriptor != binding.descriptor);
            }
        }
        self.redirections.validate();
    }

    fn bindingIndex(self: FdTable, descriptor: fd.Descriptor) ?usize {
        fd.assertValidDescriptor(descriptor);
        for (self.bindings.items, 0..) |binding, index| {
            if (binding.descriptor == descriptor) return index;
        }
        return null;
    }
};

fn defaultEndpoint(descriptor: fd.Descriptor) FdEndpoint {
    return switch (descriptor) {
        0 => .{ .input = .inherit_stdin },
        1 => .{ .output = .inherit_stdout },
        2 => .{ .output = .inherit_stderr },
        else => .closed,
    };
}

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
            if (!spec.stdout.isInheritStdout()) {
                std.debug.assert(self.contains(.command_substitution_stdout));
                std.debug.assert(spec.stdout.captureChannel() == .command_substitution_stdout);
            }
            std.debug.assert(!self.contains(.pipeline_data));
        }
        if (self.contains(.pipeline_data)) {
            if (spec.stdout.captureChannel() == .pipeline_data or spec.stdout.isPipeWrite()) {
                std.debug.assert(!spec.stdout.isInheritStdout());
            }
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

        if (self.kind != .trap_handler) {
            std.debug.assert(self.kind.isParentVisible() == self.mutation_policy.allowsParentMutation());
        }
        if (self.mutation_policy.allowsParentMutation()) {
            std.debug.assert(self.eval_target == .current_shell);
        } else {
            std.debug.assert(self.eval_target != .current_shell or self.kind == .external_command);
        }
        if (self.kind == .trap_handler) {
            std.debug.assert(self.eval_target.allowsShellStateCommit());
            std.debug.assert(self.trap_policy == .isolated_child);
        }
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
        if (!executionFrameValidationEnabled()) return;
        self.spec.validate();
        self.parent.validate();
    }

    pub fn writeFd(
        self: *ExecutionFrame,
        writer: OutputWriter,
        descriptor: fd.Descriptor,
        bytes: []const u8,
    ) OutputWriteError!void {
        self.validate();
        fd.assertValidDescriptor(descriptor);
        if (bytes.len == 0) return;
        try writer.write(descriptor, bytes);
    }

    pub fn emitDiagnostic(
        self: *ExecutionFrame,
        writer: OutputWriter,
        store: DiagnosticStore,
        diagnostic: []const u8,
        stderr_text: []const u8,
    ) OutputWriteError!void {
        self.validate();
        std.debug.assert(diagnostic.len != 0);
        std.debug.assert(stderr_text.len != 0);
        try self.writeFd(writer, 2, stderr_text);
        try store.append(diagnostic);
    }
};

pub const OutputWriteError = error{ OutOfMemory, Unimplemented };

pub const OutputWriter = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, fd.Descriptor, []const u8) OutputWriteError!void,

    pub fn write(self: OutputWriter, descriptor: fd.Descriptor, bytes: []const u8) OutputWriteError!void {
        fd.assertValidDescriptor(descriptor);
        if (bytes.len == 0) return;
        try self.write_fn(self.context, descriptor, bytes);
    }
};

pub const DiagnosticStore = struct {
    context: *anyopaque,
    append_fn: *const fn (*anyopaque, []const u8) OutputWriteError!void,

    pub fn append(self: DiagnosticStore, diagnostic: []const u8) OutputWriteError!void {
        std.debug.assert(diagnostic.len != 0);
        try self.append_fn(self.context, diagnostic);
    }
};

fn executionFrameValidationEnabled() bool {
    return switch (zig_builtin.mode) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };
}

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
    var table: FdTable = .{};
    defer table.deinit(std.testing.allocator);
    try table.bindInput(std.testing.allocator, 0, .inherit_stdin);
    try table.bindOutput(std.testing.allocator, 1, .inherit_stdout);
    try table.bindOutput(std.testing.allocator, 2, .inherit_stderr);
    table.validate();
}

test "fd table applies ordered output redirection before stderr duplication" {
    const steps = [_]redirection_plan.RedirectionStep{
        redirection_plan.RedirectionStep.openPath(0, 1, "out", .{
            .access = .write_only,
            .create = true,
            .truncate = true,
        }),
        redirection_plan.RedirectionStep.duplicate(1, 2, 1),
    };
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };

    var table: FdTable = .{};
    defer table.deinit(std.testing.allocator);
    try table.applyRedirectionPlan(std.testing.allocator, plan);

    try expectOutputPath(table.endpoint(1), "out");
    try expectOutputPath(table.endpoint(2), "out");
}

test "fd table duplicates stderr before later stdout file redirection" {
    const steps = [_]redirection_plan.RedirectionStep{
        redirection_plan.RedirectionStep.duplicate(0, 2, 1),
        redirection_plan.RedirectionStep.openPath(1, 1, "out", .{
            .access = .write_only,
            .create = true,
            .truncate = true,
        }),
    };
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };

    var table: FdTable = .{};
    defer table.deinit(std.testing.allocator);
    try table.applyRedirectionPlan(std.testing.allocator, plan);

    const inherited_stdout: FdEndpoint = .{ .output = .inherit_stdout };
    try std.testing.expectEqual(inherited_stdout, table.endpoint(2));
    try expectOutputPath(table.endpoint(1), "out");
}

test "fd table duplicates pipeline stdout capture into stderr" {
    var table: FdTable = .{};
    defer table.deinit(std.testing.allocator);
    try table.bindOutput(std.testing.allocator, 1, .{ .capture = .pipeline_data });

    const steps = [_]redirection_plan.RedirectionStep{
        redirection_plan.RedirectionStep.duplicate(0, 2, 1),
    };
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };
    try table.applyRedirectionPlan(std.testing.allocator, plan);

    try expectOutputCapture(table.endpoint(1), .pipeline_data);
    try expectOutputCapture(table.endpoint(2), .pipeline_data);
}

test "fd table clone owns bindings and preserves endpoint snapshots" {
    var original: FdTable = .{};
    defer original.deinit(std.testing.allocator);
    try original.bindInput(std.testing.allocator, 0, .{ .bytes = "original\n" });
    try original.bindOutput(std.testing.allocator, 1, .{ .capture = .pipeline_data });

    var clone = try original.clone(std.testing.allocator);
    defer clone.deinit(std.testing.allocator);

    try original.bindInput(std.testing.allocator, 0, .inherit_stdin);
    try original.bindOutput(std.testing.allocator, 1, .inherit_stdout);
    try original.bindOutput(std.testing.allocator, 2, .inherit_stderr);

    const steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.duplicate(0, 2, 1)};
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };
    try clone.applyRedirectionPlan(std.testing.allocator, plan);

    try expectInputBytes(clone.endpoint(0), "original\n");
    try expectOutputCapture(clone.endpoint(1), .pipeline_data);
    try expectOutputCapture(clone.endpoint(2), .pipeline_data);
    const original_stderr: FdEndpoint = .{ .output = .inherit_stderr };
    try std.testing.expectEqual(original_stderr, original.endpoint(2));
}

test "fd table applies here-doc bytes and closes descriptors" {
    const steps = [_]redirection_plan.RedirectionStep{
        .{ .ordinal = 0, .effect = .{ .here_doc = .{ .target = 0, .data = .{ .bytes = "body\n" } } } },
        redirection_plan.RedirectionStep.close(1, 1),
    };
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };

    var table: FdTable = .{};
    defer table.deinit(std.testing.allocator);
    try table.applyRedirectionPlan(std.testing.allocator, plan);

    try expectInputBytes(table.endpoint(0), "body\n");
    try expectClosed(table.endpoint(1));
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
