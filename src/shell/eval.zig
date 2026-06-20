//! Semantic evaluation entry point for the redesigned shell core.
//!
//! Evaluation will consume side-effect-free plans, call runtime ports for host
//! effects when needed, and return `CommandOutcome` data.
//!
//! The active `ExecutionFrame` owns semantic stdin/stdout/stderr endpoints,
//! redirection transforms, capture channels, mutation policy, trap policy, and
//! fatal-failure propagation. `EvaluationBuffers`, `OutputFrame`, and
//! `OutputRouting` are private adapter state only: they materialize frame writes
//! into `CommandOutcome` buffers or host descriptors while runtime adapters still
//! own irreversible fd/process effects.
//!
//! New evaluation code should take an `ExecutionFrame` at semantic boundaries and
//! route reads, writes, diagnostics, traps, and propagated failures through that
//! frame rather than inspecting ambient pipeline or command-substitution depth.

const std = @import("std");
const assignment_runtime = @import("assignment.zig");
const default_builtins = @import("../builtins.zig");
const extension_api = @import("../extensions/api.zig");
const extension_handlers = @import("../extensions/handlers.zig");
const builtin = @import("builtin.zig");
const command_plan = @import("command_plan.zig");
const compat = @import("compat.zig");
const consequence = @import("consequence.zig");
const context = @import("context.zig");
const delta = @import("delta.zig");
const expand = @import("expand.zig");
const execution_frame = @import("execution_frame.zig");
const ir = @import("ir.zig");
const outcome = @import("outcome.zig");
const output_routing = @import("output_routing.zig");
const parser = @import("parser.zig");
const pipeline_plan = @import("pipeline_plan.zig");
const redirection_plan = @import("redirection_plan.zig");
const runtime = @import("../runtime.zig");
const shell_expand = @import("expansion_context.zig");
const state = @import("state.zig");
const trap_semantics = @import("trap.zig");

const OutputDestination = output_routing.OutputDestination;
const OutputRouting = output_routing.OutputRouting;
const frameWithinCommandSubstitution = output_routing.frameWithinCommandSubstitution;
const outputDestinationForFrameEndpointInContext = output_routing.outputDestinationForFrameEndpointInContext;

extern "c" fn snprintf(s: [*]u8, n: usize, format: [*:0]const u8, ...) c_int;

// Equivalent to `std.mem.Allocator.Error || error{Unimplemented}`; spelled as an
// explicit error set so ziglint recognizes it as a public type (Z015).
pub const EvalError = error{
    OutOfMemory,
    Unimplemented,
};

pub const ExternalStdio = runtime.ExternalStdio;

pub const CommandHistoryEntry = struct {
    number: i64,
    text: []const u8,

    pub fn validate(self: CommandHistoryEntry) void {
        std.debug.assert(self.number > 0);
        std.debug.assert(self.text.len != 0);
        std.debug.assert(std.mem.findScalar(u8, self.text, 0) == null);
    }
};

const ScopedExecRedirection = struct {
    applied: ?redirection_plan.FdTransaction = null,
    redirections: redirection_plan.RedirectionPlan,

    fn restoreAndDeinit(self: *ScopedExecRedirection) void {
        if (self.applied) |*applied| {
            applied.restore();
            applied.deinit();
        }
        self.redirections.deinit();
        self.* = undefined;
    }
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    fd_port: ?runtime.fd.Port = null,
    fs_port: ?runtime.fs.Port = null,
    process_port: ?runtime.process.Port = null,
    signal_port: ?runtime.signal.Port = null,
    features: compat.Features = .{},
    arg_zero: []const u8 = "rush",
    command_string_line_diagnostics: bool = false,
    shell_pid: runtime.process.ProcessId,
    function_frame: ?*FunctionFrame = null,
    io: ?std.Io = null,
    read_stdin_from_fd: bool = false,
    external_stdio: ExternalStdio = .inherit,
    commit_exec_redirections: bool = false,
    scoped_exec_redirections: ?*std.ArrayList(ScopedExecRedirection) = null,
    builtin_definitions: []const builtin.Builtin = default_builtins.default_registry,
    extension_handler_context: ?*anyopaque = null,
    extension_handler_lookup: ?*const fn (?*anyopaque, []const u8) ?extension_api.HandlerSpec = null,
    alias_state: ?*state.ShellState = null,
    history_entries: []const CommandHistoryEntry = &.{},

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        return .{ .allocator = allocator, .shell_pid = currentProcessId() };
    }

    pub fn initWithFdPort(allocator: std.mem.Allocator, fd_port: runtime.fd.Port) Evaluator {
        return .{ .allocator = allocator, .fd_port = fd_port, .shell_pid = currentProcessId() };
    }

    pub fn initWithExternalPorts(
        allocator: std.mem.Allocator,
        fd_port: runtime.fd.Port,
        process_port: runtime.process.Port,
    ) Evaluator {
        return .{
            .allocator = allocator,
            .fd_port = fd_port,
            .process_port = process_port,
            .shell_pid = currentProcessId(),
        };
    }

    pub fn initWithFsPort(allocator: std.mem.Allocator, fs_port: runtime.fs.Port) Evaluator {
        return .{ .allocator = allocator, .fs_port = fs_port, .shell_pid = currentProcessId() };
    }

    pub fn initWithRuntimePorts(allocator: std.mem.Allocator, ports: runtime.Ports) Evaluator {
        return .{
            .allocator = allocator,
            .fd_port = ports.fd,
            .fs_port = ports.fs,
            .process_port = ports.process,
            .signal_port = ports.signal,
            .shell_pid = currentProcessId(),
        };
    }

    pub fn initWithSignalPort(allocator: std.mem.Allocator, signal_port: runtime.signal.Port) Evaluator {
        return .{ .allocator = allocator, .signal_port = signal_port, .shell_pid = currentProcessId() };
    }

    pub fn setExtensionHandlerLookup(
        self: *Evaluator,
        context_value: ?*anyopaque,
        lookup: *const fn (?*anyopaque, []const u8) ?extension_api.HandlerSpec,
    ) void {
        self.extension_handler_context = context_value;
        self.extension_handler_lookup = lookup;
    }

    pub fn setBuiltinDefinitions(self: *Evaluator, definitions: []const builtin.Builtin) void {
        builtin.assertUniqueNames(definitions);
        self.builtin_definitions = definitions;
    }

    pub fn setHistoryEntries(self: *Evaluator, entries: []const CommandHistoryEntry) void {
        for (entries) |entry| entry.validate();
        self.history_entries = entries;
    }

    fn builtinDefinition(self: Evaluator, name: []const u8) ?builtin.Builtin {
        return builtin.lookupIn(self.builtin_definitions, name);
    }

    fn extensionHandler(self: Evaluator, name: []const u8) ?extension_api.HandlerSpec {
        if (self.extension_handler_lookup) |lookup| {
            if (lookup(self.extension_handler_context, name)) |handler| return handler;
        }
        return extension_handlers.lookup(name);
    }
};

fn currentProcessId() runtime.process.ProcessId {
    return @intCast(std.c.getpid());
}

fn rootExecutionFrame(eval_context: context.EvalContext) execution_frame.ExecutionFrame {
    eval_context.validate();
    return execution_frame.ExecutionFrame.init(rootBoundarySpec(eval_context));
}

fn rootBoundarySpec(eval_context: context.EvalContext) execution_frame.BoundarySpec {
    eval_context.validate();
    return switch (eval_context.target) {
        .current_shell => .{
            .kind = .top_level,
            .eval_target = .current_shell,
            .stdout = .{ .capture = .side_stdout },
            .stderr = .{ .capture = .side_stderr },
            .captures = captureSet(.side_stdout, .side_stderr),
            .mutation_policy = .commit_to_parent_shell,
        },
        .subshell => .{
            .kind = .subshell,
            .eval_target = .subshell,
            .mutation_policy = .commit_within_subshell,
            .failure_policy = .contain_fatal_at_boundary,
        },
        .child_process => .{
            .kind = .external_command,
            .eval_target = .child_process,
            .mutation_policy = .discard_at_boundary,
            .trap_policy = .isolated_child,
            .failure_policy = .contain_fatal_at_boundary,
        },
    };
}

fn commandSubstitutionExecutionFrame(
    allocator: std.mem.Allocator,
    scoped_exec_redirections: ?*std.ArrayList(ScopedExecRedirection),
    parent_frame: *execution_frame.ExecutionFrame,
) EvalError!execution_frame.ExecutionFrame {
    parent_frame.validate();
    var fd_table = try parent_frame.spec.fd_table.clone(allocator);
    errdefer fd_table.deinit(allocator);
    if (frameStandardDescriptorsAreDefault(parent_frame.*)) if (scoped_exec_redirections) |scoped_list| {
        for (scoped_list.items) |scoped| try fd_table.applyRedirectionPlan(allocator, scoped.redirections);
    };

    const stdin = commandSubstitutionInputEndpoint(parent_frame.*, fd_table);
    const stdout: execution_frame.OutputEndpoint = .{ .capture = .command_substitution_stdout };
    const stderr = commandSubstitutionStderrEndpoint(parent_frame.*, fd_table);

    try fd_table.bindInput(allocator, 0, stdin);
    try fd_table.bindOutput(allocator, 1, stdout);
    switch (fd_table.endpoint(2)) {
        .output => |output| try fd_table.bindOutput(allocator, 2, commandSubstitutionInheritedErrorEndpoint(output)),
        .closed => try fd_table.close(allocator, 2),
        .input => try fd_table.bindOutput(allocator, 2, parent_frame.spec.stderr),
    }

    return parent_frame.child(.{
        .kind = .command_substitution,
        .eval_target = .subshell,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
        .fd_table = fd_table,
        .captures = commandSubstitutionCaptures(stderr),
        .mutation_policy = .discard_at_boundary,
        .trap_policy = .command_substitution,
        .failure_policy = .propagate_fatal_to_parent,
    });
}

fn commandSubstitutionCaptures(stderr: execution_frame.OutputEndpoint) execution_frame.Captures {
    stderr.validate();
    if (stderr.captureChannel()) |channel| {
        if (channel == .command_substitution_stdout) return execution_frame.Captures.commandSubstitution();
        return captureSet(.command_substitution_stdout, channel);
    }
    return execution_frame.Captures.commandSubstitution();
}

fn commandSubstitutionInputEndpoint(
    parent_frame: execution_frame.ExecutionFrame,
    fd_table: execution_frame.FdTable,
) execution_frame.InputEndpoint {
    parent_frame.validate();
    fd_table.validate();
    return switch (fd_table.endpoint(0)) {
        .input => |input| input,
        .closed => .closed,
        .output => parent_frame.spec.stdin,
    };
}

fn commandSubstitutionStderrEndpoint(
    parent_frame: execution_frame.ExecutionFrame,
    fd_table: execution_frame.FdTable,
) execution_frame.OutputEndpoint {
    parent_frame.validate();
    fd_table.validate();
    return switch (fd_table.endpoint(2)) {
        .output => |output| commandSubstitutionInheritedErrorEndpoint(output),
        .closed => .discard,
        .input => parent_frame.spec.stderr,
    };
}

fn commandSubstitutionInheritedErrorEndpoint(output: execution_frame.OutputEndpoint) execution_frame.OutputEndpoint {
    output.validate();
    return switch (output) {
        .capture => |channel| switch (channel) {
            .command_substitution_stdout => .{ .capture = .side_stdout },
            .pipeline_data => .{ .capture = .side_stdout },
            else => output,
        },
        else => output,
    };
}

fn pipelineStageExecutionFrame(
    allocator: std.mem.Allocator,
    scoped_exec_redirections: ?*std.ArrayList(ScopedExecRedirection),
    parent_frame: *execution_frame.ExecutionFrame,
    stage_target: context.ExecutionTarget,
    is_last_stage: bool,
    previous_stdin: []const u8,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!execution_frame.ExecutionFrame {
    parent_frame.validate();
    redirections.validate();
    std.debug.assert(stage_target != .current_shell);
    var fd_table = try parent_frame.spec.fd_table.clone(allocator);
    errdefer fd_table.deinit(allocator);
    if (frameStandardDescriptorsAreDefault(parent_frame.*)) if (scoped_exec_redirections) |scoped_list| {
        for (scoped_list.items) |scoped| try fd_table.applyRedirectionPlan(allocator, scoped.redirections);
    };
    normalizeInheritedPipelineCapturesForPipelineStage(&fd_table);

    const stdin: execution_frame.InputEndpoint = if (previous_stdin.len != 0)
        .{ .bytes = previous_stdin }
    else
        pipelineStageInheritedInput(parent_frame.*, fd_table);
    const stdout = pipelineStageOutputEndpoint(parent_frame.*, fd_table, is_last_stage);
    const stderr = pipelineStageErrorEndpoint(parent_frame.*, fd_table);
    try fd_table.bindInput(allocator, 0, stdin);
    try fd_table.bindOutput(allocator, 1, stdout);
    try fd_table.bindOutput(allocator, 2, stderr);
    try fd_table.applyRedirectionPlan(allocator, redirections);

    var frame = parent_frame.child(.{
        .kind = .pipeline_stage,
        .eval_target = stage_target,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
        .fd_table = fd_table,
        .captures = pipelineStageCaptures(stdout, stderr),
        .mutation_policy = if (stage_target == .subshell) .commit_within_subshell else .discard_at_boundary,
        .trap_policy = .isolated_child,
        .failure_policy = .contain_fatal_at_boundary,
    });
    frame.validate();
    return frame;
}

fn normalizeInheritedPipelineCapturesForPipelineStage(fd_table: *execution_frame.FdTable) void {
    fd_table.validate();
    for (fd_table.bindings.items) |*binding| {
        binding.validate();
        if (binding.descriptor <= 2) continue;
        switch (binding.endpoint) {
            .output => |output| switch (output) {
                .capture => |channel| if (channel == .pipeline_data) {
                    binding.endpoint = .{ .output = .{ .capture = .side_stdout } };
                },
                else => {},
            },
            .input, .closed => {},
        }
    }
    fd_table.validate();
}

fn pipelineStageInheritedInput(
    parent_frame: execution_frame.ExecutionFrame,
    fd_table: execution_frame.FdTable,
) execution_frame.InputEndpoint {
    parent_frame.validate();
    fd_table.validate();
    return switch (fd_table.endpoint(0)) {
        .input => |input| input,
        .closed => .closed,
        .output => parent_frame.spec.stdin,
    };
}

fn semanticCommandExecutionFrame(
    allocator: std.mem.Allocator,
    scoped_exec_redirections: ?*std.ArrayList(ScopedExecRedirection),
    parent_frame: *execution_frame.ExecutionFrame,
    target: context.ExecutionTarget,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!execution_frame.ExecutionFrame {
    parent_frame.validate();
    redirections.validate();
    var fd_table = try parent_frame.spec.fd_table.clone(allocator);
    errdefer fd_table.deinit(allocator);
    const inherit_scoped = frameStandardDescriptorsAreDefault(parent_frame.*) or
        parent_frame.spec.kind == .trap_handler;
    if (inherit_scoped) if (scoped_exec_redirections) |scoped_list| {
        for (scoped_list.items) |scoped| try fd_table.applyRedirectionPlan(allocator, scoped.redirections);
    };
    if (parent_frame.spec.kind == .pipeline_stage) normalizeInheritedPipelineCapturesForPipelineStage(&fd_table);
    try fd_table.applyRedirectionPlan(allocator, redirections);
    const stdin: execution_frame.InputEndpoint = switch (fd_table.boundEndpoint(0) orelse
        @as(execution_frame.FdEndpoint, .{ .input = parent_frame.spec.stdin })) {
        .input => |input| input,
        .closed => .closed,
        .output => parent_frame.spec.stdin,
    };
    const stdout: execution_frame.OutputEndpoint = switch (fd_table.boundEndpoint(1) orelse
        @as(execution_frame.FdEndpoint, .{ .output = parent_frame.spec.stdout })) {
        .output => |output| output,
        .closed => .discard,
        .input => parent_frame.spec.stdout,
    };
    const stderr: execution_frame.OutputEndpoint = switch (fd_table.boundEndpoint(2) orelse
        @as(execution_frame.FdEndpoint, .{ .output = parent_frame.spec.stderr })) {
        .output => |output| output,
        .closed => .discard,
        .input => parent_frame.spec.stderr,
    };
    try fd_table.bindInput(allocator, 0, stdin);
    try fd_table.bindOutput(allocator, 1, stdout);
    try fd_table.bindOutput(allocator, 2, stderr);
    const spec: execution_frame.BoundarySpec = .{
        .kind = if (parent_frame.spec.kind == .pipeline_stage)
            .pipeline_stage
        else if (target == .current_shell)
            .top_level
        else
            .subshell,
        .eval_target = target,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
        .fd_table = fd_table,
        .captures = semanticCommandCaptures(parent_frame.*, stdout, stderr),
        .mutation_policy = if (target == .current_shell) .commit_to_parent_shell else .commit_within_subshell,
        .trap_policy = parent_frame.spec.trap_policy,
        .failure_policy = parent_frame.spec.failure_policy,
    };
    return parent_frame.child(spec);
}

fn semanticCommandCaptures(
    parent_frame: execution_frame.ExecutionFrame,
    stdout: execution_frame.OutputEndpoint,
    stderr: execution_frame.OutputEndpoint,
) execution_frame.Captures {
    parent_frame.validate();
    stdout.validate();
    stderr.validate();
    if (parent_frame.spec.kind == .pipeline_stage) return pipelineStageCaptures(stdout, stderr);
    const stdout_channel = stdout.captureChannel();
    const stderr_channel = stderr.captureChannel();
    if (stdout_channel) |out_channel| return captureSet(out_channel, stderr_channel);
    if (stderr_channel) |err_channel| return captureSet(err_channel, null);
    return .{};
}

fn frameRoutesPipelineData(frame: execution_frame.ExecutionFrame) bool {
    frame.validate();
    return frame.spec.captures.contains(.pipeline_data) or
        frameOutputEndpointCaptures(frame.spec.fd_table.endpoint(1), .pipeline_data) or
        frameOutputEndpointCaptures(frame.spec.fd_table.endpoint(2), .pipeline_data);
}

fn frameRoutesCapturedOutput(frame: execution_frame.ExecutionFrame) bool {
    frame.validate();
    if (frame.spec.captures.channels.len != 0) return true;
    for (frame.spec.fd_table.bindings.items) |binding| {
        binding.validate();
        if (frameOutputEndpointHasCapture(binding.endpoint)) return true;
    }
    return false;
}

fn frameOutputEndpointHasCapture(endpoint: execution_frame.FdEndpoint) bool {
    endpoint.validate();
    return switch (endpoint) {
        .output => |output| output.captureChannel() != null,
        .input, .closed => false,
    };
}

fn frameOutputEndpointCaptures(
    endpoint: execution_frame.FdEndpoint,
    channel: execution_frame.CaptureChannel,
) bool {
    endpoint.validate();
    return switch (endpoint) {
        .output => |output| output.captureChannel() == channel,
        .input, .closed => false,
    };
}

fn defaultFrameEndpoint(descriptor: runtime.fd.Descriptor) execution_frame.FdEndpoint {
    runtime.fd.assertValidDescriptor(descriptor);
    return switch (descriptor) {
        0 => .{ .input = .inherit_stdin },
        1 => .{ .output = .inherit_stdout },
        2 => .{ .output = .inherit_stderr },
        else => .{ .output = .{ .fd = descriptor } },
    };
}

fn pipelineStageOutputEndpoint(
    parent_frame: execution_frame.ExecutionFrame,
    fd_table: execution_frame.FdTable,
    is_last_stage: bool,
) execution_frame.OutputEndpoint {
    parent_frame.validate();
    fd_table.validate();
    if (!is_last_stage) return .{ .capture = .pipeline_data };
    return switch (fd_table.endpoint(1)) {
        .output => |output| switch (output) {
            .inherit_stdout => .{ .capture = .side_stdout },
            else => output,
        },
        .closed => .discard,
        .input => parent_frame.spec.stdout,
    };
}

fn pipelineStageErrorEndpoint(
    parent_frame: execution_frame.ExecutionFrame,
    fd_table: execution_frame.FdTable,
) execution_frame.OutputEndpoint {
    parent_frame.validate();
    fd_table.validate();
    return switch (fd_table.endpoint(2)) {
        .output => |output| switch (output) {
            .inherit_stderr => .{ .capture = .side_stderr },
            else => output,
        },
        .closed => .discard,
        .input => parent_frame.spec.stderr,
    };
}

fn pipelineStageCaptures(
    stdout: execution_frame.OutputEndpoint,
    stderr: execution_frame.OutputEndpoint,
) execution_frame.Captures {
    stdout.validate();
    stderr.validate();
    const stdout_channel = stdout.captureChannel();
    const stderr_channel = stderr.captureChannel();
    if (stdout_channel) |out_channel| {
        if (stderr_channel) |err_channel| {
            return if (out_channel == err_channel)
                captureSet(out_channel, null)
            else
                captureSet(out_channel, err_channel);
        }
        return captureSet(out_channel, null);
    }
    if (stderr_channel) |err_channel| return captureSet(err_channel, null);
    return .{};
}

fn captureSet(
    first: execution_frame.CaptureChannel,
    second: ?execution_frame.CaptureChannel,
) execution_frame.Captures {
    return switch (first) {
        .side_stdout => switch (second orelse return .{ .channels = &.{.side_stdout} }) {
            .side_stdout => .{ .channels = &.{.side_stdout} },
            .side_stderr => .{ .channels = &.{ .side_stdout, .side_stderr } },
            .pipeline_data => .{ .channels = &.{ .side_stdout, .pipeline_data } },
            .command_substitution_stdout => .{ .channels = &.{ .side_stdout, .command_substitution_stdout } },
        },
        .side_stderr => switch (second orelse return .{ .channels = &.{.side_stderr} }) {
            .side_stdout => .{ .channels = &.{ .side_stderr, .side_stdout } },
            .side_stderr => .{ .channels = &.{.side_stderr} },
            .pipeline_data => .{ .channels = &.{ .side_stderr, .pipeline_data } },
            .command_substitution_stdout => .{ .channels = &.{ .side_stderr, .command_substitution_stdout } },
        },
        .pipeline_data => switch (second orelse return .{ .channels = &.{.pipeline_data} }) {
            .side_stdout => .{ .channels = &.{ .pipeline_data, .side_stdout } },
            .side_stderr => .{ .channels = &.{ .pipeline_data, .side_stderr } },
            .pipeline_data => .{ .channels = &.{.pipeline_data} },
            .command_substitution_stdout => .{ .channels = &.{ .pipeline_data, .command_substitution_stdout } },
        },
        .command_substitution_stdout => switch (second orelse
            return .{ .channels = &.{.command_substitution_stdout} }) {
            .side_stdout => .{ .channels = &.{ .command_substitution_stdout, .side_stdout } },
            .side_stderr => .{ .channels = &.{ .command_substitution_stdout, .side_stderr } },
            .pipeline_data => .{ .channels = &.{ .command_substitution_stdout, .pipeline_data } },
            .command_substitution_stdout => .{ .channels = &.{.command_substitution_stdout} },
        },
    };
}

fn pipelineStageRedirections(stage: pipeline_plan.PipelineStagePlan) redirection_plan.RedirectionPlan {
    stage.validate();
    return switch (stage) {
        .simple => |plan| plan.redirections,
        .compound => |plan| plan.redirections,
    };
}

pub const TrapActionBodyPayload = union(enum) {
    simple: command_plan.CommandPlan,
    compound: command_plan.CompoundCommandPlan,
    pipeline: pipeline_plan.PipelinePlan,
    failure: TrapActionFailure,

    fn validate(self: TrapActionBodyPayload) void {
        switch (self) {
            .simple => |plan| plan.validate(),
            .compound => |plan| plan.validate(),
            .pipeline => |plan| plan.validate(),
            .failure => |failure| failure.validate(),
        }
    }
};

pub const TrapActionFailureKind = enum {
    parse_error,
    lowering_error,
    expansion_error,
    unsupported_shape,
};

pub const TrapActionFailure = struct {
    kind: TrapActionFailureKind,
    status: outcome.ExitStatus = 2,
    message: []const u8,
    fatal_noninteractive: bool = false,
    bash_arithmetic_expansion: bool = false,
    bash_arithmetic_readonly_assignment: bool = false,
    bash_arithmetic_assignment_only_expansion: bool = false,
    bash_parameter_assignment_expansion: bool = false,

    pub fn validate(self: TrapActionFailure) void {
        std.debug.assert(self.status != 0);
        std.debug.assert(self.message.len != 0);
        std.debug.assert(std.mem.findScalar(u8, self.message, 0) == null);
    }

    fn fatalInNonInteractiveShell(self: TrapActionFailure) TrapActionFailure {
        var failure = self;
        failure.fatal_noninteractive = true;
        failure.validate();
        return failure;
    }
};

fn cloneTrapActionFailure(allocator: std.mem.Allocator, failure: TrapActionFailure) !TrapActionFailure {
    failure.validate();
    var cloned = failure;
    cloned.message = try allocator.dupe(u8, failure.message);
    cloned.validate();
    return cloned;
}

pub const OwnedTrapActionBody = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    body: TrapActionBodyPayload,

    fn init(
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        body: TrapActionBodyPayload,
    ) OwnedTrapActionBody {
        body.validate();
        const owned: OwnedTrapActionBody = .{ .allocator = allocator, .arena = arena, .body = body };
        owned.validate();
        return owned;
    }

    fn deinit(self: *OwnedTrapActionBody) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    fn validate(self: OwnedTrapActionBody) void {
        self.body.validate();
    }
};

pub const TrapActionBody = union(enum) {
    simple: command_plan.CommandPlan,
    compound: command_plan.CompoundCommandPlan,
    pipeline: pipeline_plan.PipelinePlan,
    failure: TrapActionFailure,
    owned: OwnedTrapActionBody,

    pub fn deinit(self: *TrapActionBody) void {
        switch (self.*) {
            .owned => |*owned| owned.deinit(),
            .simple, .compound, .pipeline, .failure => {},
        }
        self.* = undefined;
    }

    pub fn validate(self: TrapActionBody) void {
        switch (self) {
            .simple => |plan| plan.validate(),
            .compound => |plan| plan.validate(),
            .pipeline => |plan| plan.validate(),
            .failure => |failure| failure.validate(),
            .owned => |owned| owned.validate(),
        }
    }
};

pub const TrapActionResolver = struct {
    context: ?*anyopaque = null,
    resolveFn: ?*const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const u8,
        state.TrapSignal,
        context.EvalContext,
        *state.ShellState,
    ) anyerror!?TrapActionBody = null,

    pub fn resolve(
        self: TrapActionResolver,
        allocator: std.mem.Allocator,
        action: []const u8,
        signal: state.TrapSignal,
        eval_context: context.EvalContext,
        shell_state: *state.ShellState,
    ) !?TrapActionBody {
        trapSemanticActionAssert(action, signal, eval_context);
        shell_state.validate();
        std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));
        const resolve_fn = self.resolveFn orelse return null;
        const body = try resolve_fn(self.context, allocator, action, signal, eval_context, shell_state);
        if (body) |resolved| resolved.validate();
        return body;
    }

    pub fn validate(self: TrapActionResolver) void {
        std.debug.assert(self.resolveFn != null);
    }
};

pub const ParserBackedSourceResolver = struct {
    evaluator: *Evaluator,
    features: compat.Features = .{},
    externals: []const command_plan.ExternalResolution = &.{},
    arg_zero: []const u8 = "rush",
    expand_aliases: bool = true,
    alias_state: ?*state.ShellState = null,
    active_frame: ?*execution_frame.ExecutionFrame = null,
    active_input: ?*EvaluationInput = null,
    source_line_offset: usize = 0,
    command_string_line_diagnostics: bool = false,

    pub fn init(evaluator: *Evaluator) ParserBackedSourceResolver {
        return .{
            .evaluator = evaluator,
            .command_string_line_diagnostics = evaluator.command_string_line_diagnostics,
        };
    }

    pub fn resolver(self: *ParserBackedSourceResolver) TrapActionResolver {
        self.validate();
        return .{ .context = self, .resolveFn = resolveTrapAction };
    }

    pub fn lowerSource(
        self: *ParserBackedSourceResolver,
        allocator: std.mem.Allocator,
        source: []const u8,
        eval_context: context.EvalContext,
        shell_state: *state.ShellState,
    ) !?TrapActionBody {
        self.validate();
        shell_state.validate();
        std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));
        return self.lowerSourceWithSignal(allocator, source, null, eval_context, shell_state);
    }

    pub fn lowerProgramStatement(
        self: *ParserBackedSourceResolver,
        allocator: std.mem.Allocator,
        program: ir.Program,
        statement_index: usize,
        eval_context: context.EvalContext,
        shell_state: *state.ShellState,
    ) !TrapActionBody {
        self.validate();
        shell_state.validate();
        std.debug.assert(statement_index < program.statements.len);
        std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));

        var lowering_eval_context = eval_context;
        lowering_eval_context.features = self.features;
        lowering_eval_context.validate();

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();
        var lowerer: SourceLowerer = .{
            .allocator = arena_allocator,
            .owner = self,
            .shell_state = shell_state,
            .eval_context = lowering_eval_context,
            .signal = null,
            .local_functions = .empty,
            .source_line_offset = self.source_line_offset,
        };

        const payload = try lowerer.lowerSingleStatement(
            program,
            program.statements[statement_index],
            lowering_eval_context.target,
        );
        payload.validate();
        return .{ .owned = OwnedTrapActionBody.init(allocator, arena, payload) };
    }

    pub fn validate(self: ParserBackedSourceResolver) void {
        _ = self.evaluator.allocator;
        std.debug.assert(self.arg_zero.len != 0);
        if (self.active_frame) |frame| frame.validate();
        if (self.active_input) |input| input.validate();
        for (self.externals) |external| external.validate();
    }

    fn bashMode(self: ParserBackedSourceResolver) bool {
        return self.features.isBash() or self.evaluator.features.isBash();
    }

    fn resolveTrapAction(
        opaque_context: ?*anyopaque,
        allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
        action: []const u8,
        signal: state.TrapSignal,
        eval_context: context.EvalContext,
        shell_state: *state.ShellState,
    ) anyerror!?TrapActionBody {
        std.debug.assert(opaque_context != null);
        const self: *ParserBackedSourceResolver = @ptrCast(@alignCast(opaque_context.?));
        self.validate();
        trapSemanticActionAssert(action, signal, eval_context);
        shell_state.validate();
        std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));
        return self.lowerSourceWithSignal(allocator, action, signal, eval_context, shell_state);
    }

    fn lowerSourceWithSignal(
        self: *ParserBackedSourceResolver,
        allocator: std.mem.Allocator,
        source: []const u8,
        signal: ?state.TrapSignal,
        eval_context: context.EvalContext,
        shell_state: *state.ShellState,
    ) !?TrapActionBody {
        var lowering_eval_context = eval_context;
        lowering_eval_context.features = self.features;
        lowering_eval_context.validate();

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();
        var lowerer: SourceLowerer = .{
            .allocator = arena_allocator,
            .owner = self,
            .shell_state = shell_state,
            .eval_context = lowering_eval_context,
            .signal = signal,
            .local_functions = .empty,
            .source_line_offset = self.source_line_offset,
        };

        const payload = try lowerer.lower(source);
        payload.validate();
        return .{ .owned = OwnedTrapActionBody.init(allocator, arena, payload) };
    }
};

const ParserCommandSubstitutionResolver = struct {
    owner: *ParserBackedSourceResolver,
    signal: ?state.TrapSignal,
    expansion_context: *CommandSubstitutionExpansionContext,
    local_functions: []const command_plan.FunctionDefinition = &.{},
    source_line_offset: usize = 0,

    fn commandSubstitutionResolver(self: *ParserCommandSubstitutionResolver) CommandSubstitutionResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn validate(self: ParserCommandSubstitutionResolver) void {
        self.owner.validate();
        if (self.signal) |signal| signal.validate();
        self.expansion_context.shell_state.validate();
        self.expansion_context.eval_context.validate();
        std.debug.assert(
            self.expansion_context.shell_state.acceptsExecutionTarget(self.expansion_context.eval_context.target),
        );
        for (self.local_functions) |definition| definition.validate();
    }

    fn resolve(
        opaque_context: ?*anyopaque,
        allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
        script: []const u8,
    ) anyerror!?CommandSubstitutionBody {
        std.debug.assert(opaque_context != null);
        const self: *ParserCommandSubstitutionResolver = @ptrCast(@alignCast(opaque_context.?));
        self.validate();

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const arena_allocator = arena.allocator();
        var lowerer: SourceLowerer = .{
            .allocator = arena_allocator,
            .owner = self.owner,
            .shell_state = self.expansion_context.shell_state,
            .eval_context = self.expansion_context.eval_context,
            .signal = self.signal,
            .local_functions = .empty,
            .source_line_offset = self.source_line_offset,
        };
        try lowerer.local_functions.appendSlice(arena_allocator, self.local_functions);

        const payload = try lowerer.lowerCommandSubstitution(script);
        payload.validate();
        return .{ .owned = OwnedCommandSubstitutionBody.init(allocator, arena, payload) };
    }
};

fn lookupSemanticAliasForParser(opaque_context: *anyopaque, name: []const u8) ?[]const u8 {
    if (!isSemanticAliasName(name)) return null;
    const shell_state: *state.ShellState = @ptrCast(@alignCast(opaque_context));
    const alias = shell_state.getAlias(name) orelse return null;
    return alias.value;
}

fn isSemanticAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or
            std.ascii.isDigit(byte) or
            byte == '!' or
            byte == '%' or
            byte == ',' or
            byte == '-' or
            byte == '@' or
            byte == '_')) return false;
    }
    return true;
}

const SourceExpansionCommandSubstitutions = struct {
    resolver: ParserCommandSubstitutionResolver = undefined,
    context: CommandSubstitutionExpansionContext = undefined,

    fn init(
        self: *SourceExpansionCommandSubstitutions,
        lowerer: *SourceLowerer,
        expansion_eval_context: context.EvalContext,
    ) void {
        lowerer.shell_state.validate();
        expansion_eval_context.validate();
        self.resolver = .{
            .owner = lowerer.owner,
            .signal = lowerer.signal,
            .expansion_context = undefined,
            .local_functions = lowerer.local_functions.items,
            .source_line_offset = lowerer.current_line_number -| 1,
        };
        self.context = CommandSubstitutionExpansionContext.init(
            lowerer.owner.evaluator,
            lowerer.shell_state,
            expansion_eval_context,
            self.resolver.commandSubstitutionResolver(),
            lowerer.owner.resolver(),
            lowerer.owner.active_frame,
            lowerer.owner.active_input,
        );
        self.resolver.expansion_context = &self.context;
    }

    fn deinit(self: *SourceExpansionCommandSubstitutions) void {
        self.context.deinit();
        self.* = undefined;
    }

    fn commandSubstitution(self: *SourceExpansionCommandSubstitutions) expand.CommandSubstitution {
        return self.context.commandSubstitution();
    }
};

const SourceLowerer = struct {
    allocator: std.mem.Allocator,
    owner: *ParserBackedSourceResolver,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    signal: ?state.TrapSignal,
    local_functions: std.ArrayList(command_plan.FunctionDefinition),
    source_line_offset: usize = 0,
    current_line_number: usize = 1,

    fn lower(self: *SourceLowerer, action: []const u8) !TrapActionBodyPayload {
        if (self.signal) |signal| trapSemanticActionAssert(action, signal, self.eval_context);
        const parsed = try self.parseWithAliases(action);

        if (parsed.diagnostics.len != 0) return self.parserDiagnosticFailure(parsed.diagnostics[0]);
        if (parsed.incomplete) return self.incompleteSourceFailure();

        const program = try ir.lowerSimpleCommands(self.allocator, parsed);
        return self.lowerProgram(program, self.eval_context.target, true);
    }

    fn lowerCommandSubstitution(self: *SourceLowerer, script: []const u8) !CommandSubstitutionBodyPayload {
        const parsed = try self.parseWithAliases(script);
        if (parsed.diagnostics.len != 0) return self.commandSubstitutionDiagnosticFailure(parsed.diagnostics[0]);
        if (parsed.incomplete) return error.Unimplemented;

        const program = try ir.lowerSimpleCommands(self.allocator, parsed);
        const payload = try self.lowerProgram(program, .subshell, false);
        return switch (payload) {
            .simple => |plan| .{ .simple = plan },
            .compound => |plan| .{ .compound = plan },
            .pipeline => |plan| .{ .pipeline = plan },
            .failure => |trap_failure| .{ .failure = trap_failure.fatalInNonInteractiveShell() },
        };
    }

    fn parseWithAliases(self: *SourceLowerer, source: []const u8) !parser.ParseResult {
        if (!self.owner.expand_aliases) return parser.parse(
            self.allocator,
            source,
            .{
                .features = self.owner.features.withStrictDiagnostics(),
                .collect_command_substitution_nodes = false,
            },
        );
        const aliased = try parser.expandAliases(self.allocator, source, .{
            .features = self.owner.features.withStrictDiagnostics(),
            .context = self.owner.alias_state orelse self.shell_state,
            .lookup = lookupSemanticAliasForParser,
            .collect_command_substitution_nodes = false,
        });
        return parser.parse(self.allocator, aliased, .{
            .features = self.owner.features.withStrictDiagnostics(),
            .collect_command_substitution_nodes = false,
        });
    }

    fn parseWithoutAliases(self: *SourceLowerer, source: []const u8) !parser.ParseResult {
        return parser.parse(self.allocator, source, .{
            .features = self.owner.features.withStrictDiagnostics(),
            .collect_command_substitution_nodes = false,
        });
    }

    fn lowerProgram(
        self: *SourceLowerer,
        program: ir.Program,
        target: context.ExecutionTarget,
        trap_body: bool,
    ) !TrapActionBodyPayload {
        std.debug.assert(target.allowsShellStateCommit());
        self.shell_state.validate();
        if (program.statements.len == 0) {
            const plan = command_plan.classifyExpandedSimpleCommand(.{ .target = target });
            return .{ .simple = plan };
        }

        if (program.statements.len == 1 and trap_body) return self.lowerSingleStatement(
            program,
            program.statements[0],
            target,
        );
        const lowered = try self.lowerStatementList(program, target);
        return switch (lowered) {
            .failure => |trap_failure| .{ .failure = trap_failure },
            .list => |list| blk: {
                const plan: command_plan.CompoundCommandPlan = .{ .target = target, .body = .{ .sequence = list } };
                plan.validate();
                break :blk .{ .compound = plan };
            },
        };
    }

    fn lowerSingleStatement(
        self: *SourceLowerer,
        program: ir.Program,
        statement: ir.Statement,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        const previous_line_number = self.current_line_number;
        self.current_line_number = self.sourceLineNumber(program.source, statement.span.start);
        defer self.current_line_number = previous_line_number;

        if (statement.async_after) return self.unsupportedShapeFailure(
            "background commands are not supported by the semantic trap resolver",
            "background commands are not supported by semantic source lowering",
        );
        return switch (statement.kind) {
            .pipeline => self.lowerPipeline(program, program.pipelines[statement.index], target),
            .brace_group => self.lowerBraceGroup(program.brace_groups[statement.index], target),
            .subshell => self.lowerSubshell(program.subshells[statement.index]),
            .if_command => self.lowerIfCommand(program.if_commands[statement.index], target),
            .loop_command => self.lowerLoopCommand(program.loop_commands[statement.index], target),
            .for_command => self.lowerForCommand(program.source, program.for_commands[statement.index], target),
            .case_command => self.lowerCaseCommand(program.source, program.case_commands[statement.index], target),
            .function_definition => self.lowerFunctionDefinition(program.function_definitions[statement.index], target),
            .bash_test_command => self.unsupportedShapeFailure(
                "bash [[ ]] lowering is not implemented in the semantic trap resolver",
                "bash [[ ]] lowering is not implemented in semantic source lowering",
            ),
        };
    }

    const StatementListLowering = union(enum) {
        list: command_plan.StatementList,
        failure: TrapActionFailure,
    };

    fn lowerStatementList(
        self: *SourceLowerer,
        program: ir.Program,
        target: context.ExecutionTarget,
    ) !StatementListLowering {
        for (program.statements, 0..) |statement, index| {
            if (statement.async_after) return .{ .failure = (try self.unsupportedShapeFailure(
                "background commands are not supported by the semantic trap resolver",
                "background commands are not supported by semantic source lowering",
            )).failure };
            if (index == 0) {
                std.debug.assert(statement.op_before == .sequence);
                continue;
            }
        }

        const program_ref = try self.allocator.create(ir.Program);
        program_ref.* = program;
        const statements = try self.allocator.alloc(command_plan.StatementListEntry, program.statements.len);
        for (program.statements, 0..) |statement, index| {
            const op_before: command_plan.StatementListOperator = switch (statement.op_before) {
                .sequence => .sequence,
                .and_if => .and_if,
                .or_if => .or_if,
            };
            const eager_plan = switch (try self.lowerStatementListEntryPlan(program, statement, target)) {
                .plan => |plan| plan,
                .failure => |trap_failure| return .{ .failure = trap_failure },
            };
            statements[index] = .{
                .op_before = op_before,
                .plan = eager_plan orelse .{ .ir_source = .{
                    .target = target,
                    .program = program_ref,
                    .statement_index = index,
                    .fallback_source = try self.statementSource(program, index),
                    .expand_aliases = self.owner.expand_aliases,
                    .line = self.source_line_offset + statementLine(program.source, statement.span.start),
                    .targets_stdout = statementTargetsDescriptor(program, statement, 1),
                    .targets_stderr = statementTargetsDescriptor(program, statement, 2),
                } },
            };
        }
        const list: command_plan.StatementList = .{ .statements = statements };
        list.validate();
        return .{ .list = list };
    }

    fn lowerStatementListAtLine(
        self: *SourceLowerer,
        program: ir.Program,
        source_line_offset: usize,
        target: context.ExecutionTarget,
    ) !StatementListLowering {
        const previous_source_line_offset = self.source_line_offset;
        self.source_line_offset += source_line_offset;
        defer self.source_line_offset = previous_source_line_offset;
        return self.lowerStatementList(program, target);
    }

    const StatementListEntryLowering = union(enum) {
        plan: ?command_plan.StatementPlan,
        failure: TrapActionFailure,
    };

    fn lowerStatementListEntryPlan(
        self: *SourceLowerer,
        program: ir.Program,
        statement: ir.Statement,
        target: context.ExecutionTarget,
    ) !StatementListEntryLowering {
        if (statementHasCompoundRedirections(program, statement)) return .{ .plan = null };
        return switch (statement.kind) {
            .brace_group,
            .subshell,
            .if_command,
            .loop_command,
            .for_command,
            .case_command,
            .function_definition,
            => switch (try self.lowerSingleStatement(program, statement, target)) {
                .compound => |plan| .{ .plan = .{ .compound = plan } },
                .simple => |plan| .{ .plan = .{ .simple = plan } },
                .pipeline => |plan| .{ .plan = .{ .pipeline = plan } },
                .failure => |trap_failure| .{ .failure = trap_failure },
            },
            .pipeline, .bash_test_command => .{ .plan = null },
        };
    }

    fn statementHasCompoundRedirections(program: ir.Program, statement: ir.Statement) bool {
        return switch (statement.kind) {
            .brace_group => program.brace_groups[statement.index].redirections.len != 0,
            .subshell => program.subshells[statement.index].redirections.len != 0,
            .if_command => program.if_commands[statement.index].redirections.len != 0,
            .loop_command => program.loop_commands[statement.index].redirections.len != 0,
            .for_command => program.for_commands[statement.index].redirections.len != 0,
            .case_command => program.case_commands[statement.index].redirections.len != 0,
            .function_definition => program.function_definitions[statement.index].redirections.len != 0,
            .pipeline, .bash_test_command => false,
        };
    }

    fn statementSource(self: *SourceLowerer, program: ir.Program, statement_index: usize) ![]const u8 {
        var fragment = try ir.statementSourceFragment(self.allocator, program, statement_index);
        defer fragment.deinit(self.allocator);
        return fragment.render(self.allocator, program.source, .{});
    }

    fn statementLine(source: []const u8, offset: usize) usize {
        std.debug.assert(offset <= source.len);
        var line: usize = 0;
        for (source[0..offset]) |byte| {
            if (byte == '\n') line += 1;
        }
        return line;
    }

    fn sourceLineNumber(self: SourceLowerer, source: []const u8, offset: usize) usize {
        return self.source_line_offset + statementLine(source, offset) + 1;
    }

    fn currentLineNumberText(self: SourceLowerer, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{d}", .{self.current_line_number}) catch "1";
    }

    fn statementTargetsDescriptor(
        program: ir.Program,
        statement: ir.Statement,
        descriptor: runtime.fd.Descriptor,
    ) bool {
        runtime.fd.assertValidDescriptor(descriptor);
        return switch (statement.kind) {
            .pipeline => pipelineTargetsDescriptor(program, program.pipelines[statement.index], descriptor),
            .if_command => rawRedirectionsTargetDescriptor(
                program.if_commands[statement.index].redirections,
                descriptor,
            ),
            .loop_command => rawRedirectionsTargetDescriptor(
                program.loop_commands[statement.index].redirections,
                descriptor,
            ),
            .for_command => rawRedirectionsTargetDescriptor(
                program.for_commands[statement.index].redirections,
                descriptor,
            ),
            .case_command => rawRedirectionsTargetDescriptor(
                program.case_commands[statement.index].redirections,
                descriptor,
            ),
            .function_definition => rawRedirectionsTargetDescriptor(
                program.function_definitions[statement.index].redirections,
                descriptor,
            ),
            .brace_group => rawRedirectionsTargetDescriptor(
                program.brace_groups[statement.index].redirections,
                descriptor,
            ),
            .subshell => rawRedirectionsTargetDescriptor(program.subshells[statement.index].redirections, descriptor),
            .bash_test_command => false,
        };
    }

    fn pipelineTargetsDescriptor(
        program: ir.Program,
        pipeline: ir.Pipeline,
        descriptor: runtime.fd.Descriptor,
    ) bool {
        for (pipeline.command_indexes) |command_index| {
            if (rawRedirectionsTargetDescriptor(program.commands[command_index].redirections, descriptor)) return true;
        }
        return false;
    }

    fn lowerPipeline(
        self: *SourceLowerer,
        program: ir.Program,
        pipeline: ir.Pipeline,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        if (pipeline.async_after) return self.unsupportedShapeFailure(
            "background pipelines are not supported by the semantic trap resolver",
            "background pipelines are not supported by semantic source lowering",
        );
        if (pipeline.command_indexes.len == 1 and pipeline.stage_spans.len == 1 and !pipeline.negated) {
            const lowered = try self.lowerIrSimpleCommand(program.commands[pipeline.command_indexes[0]], target);
            return switch (lowered) {
                .plan => |plan| .{ .simple = plan },
                .failure => |trap_failure| .{ .failure = trap_failure },
            };
        }
        if (pipeline.stage_spans.len == 0) {
            return self.unsupportedShapeFailure(
                "empty pipelines are not supported by the semantic trap resolver",
                "empty pipelines are not supported by semantic source lowering",
            );
        }

        const stages = try self.allocator.alloc(pipeline_plan.PipelineStagePlan, pipeline.stage_spans.len);
        for (pipeline.stage_spans, 0..) |stage_span, index| {
            const stage_target: context.ExecutionTarget = if (pipeline.stage_spans.len == 1) target else .subshell;
            const stage_line_offset = statementLine(program.source, stage_span.start);
            const lowered = if (pipeline.command_indexes.len == pipeline.stage_spans.len) blk: {
                const previous_line_number = self.current_line_number;
                self.current_line_number = self.source_line_offset + stage_line_offset + 1;
                defer self.current_line_number = previous_line_number;
                const command = program.commands[pipeline.command_indexes[index]];
                break :blk try self.lowerPipelineSimpleStage(command, stage_target);
            } else blk: {
                std.debug.assert(pipeline.stage_sources.len == pipeline.stage_spans.len);
                const source = pipeline.stage_sources[index];
                break :blk try self.lowerPipelineStageSource(source, stage_line_offset, stage_target);
            };
            stages[index] = switch (lowered) {
                .failure => |trap_failure| return .{ .failure = trap_failure },
                .stage => |stage| stage,
            };
        }
        const status_rule: pipeline_plan.PipelineStatusRule =
            if (self.shell_state.options.pipefail) .pipefail else .last_command;
        const plan = pipeline_plan.PipelinePlan.init(
            stages,
            .{ .negated = pipeline.negated, .status_rule = status_rule },
        );
        return .{ .pipeline = plan };
    }

    const PipelineStageLowering = union(enum) {
        stage: pipeline_plan.PipelineStagePlan,
        failure: TrapActionFailure,
    };

    fn lowerPipelineSimpleStage(
        self: *SourceLowerer,
        command: ir.SimpleCommand,
        target: context.ExecutionTarget,
    ) !PipelineStageLowering {
        const lowered = try self.lowerIrSimpleCommand(command, target);
        return switch (lowered) {
            .plan => |plan| .{ .stage = .{ .simple = plan } },
            .failure => |trap_failure| .{ .failure = trap_failure },
        };
    }

    fn lowerPipelineStageSource(
        self: *SourceLowerer,
        source: []const u8,
        source_line_offset: usize,
        target: context.ExecutionTarget,
    ) anyerror!PipelineStageLowering {
        const local_function_count = self.local_functions.items.len;
        defer self.local_functions.shrinkRetainingCapacity(local_function_count);

        const previous_source_line_offset = self.source_line_offset;
        self.source_line_offset += source_line_offset;
        defer self.source_line_offset = previous_source_line_offset;

        const parsed = try self.parseWithAliases(source);
        if (parsed.diagnostics.len != 0)
            return .{ .failure = (try self.parserDiagnosticFailure(parsed.diagnostics[0])).failure };
        if (parsed.incomplete) return .{ .failure = (try self.incompletePipelineStageFailure()).failure };

        const stage_program = try ir.lowerSimpleCommands(self.allocator, parsed);
        if (stage_program.statements.len != 1) return .{ .failure = (try self.unsupportedShapeFailure(
            "pipeline stages must contain a single command",
            "pipeline stages must contain a single command",
        )).failure };

        const payload = try self.lowerSingleStatement(stage_program, stage_program.statements[0], target);
        return switch (payload) {
            .simple => |simple| .{ .stage = .{ .simple = simple } },
            .compound => |compound| .{ .stage = .{ .compound = compound } },
            .pipeline => .{ .failure = (try self.unsupportedShapeFailure(
                "nested pipelines are not valid pipeline stages",
                "nested pipelines are not valid pipeline stages",
            )).failure },
            .failure => |trap_failure| .{ .failure = trap_failure },
        };
    }

    fn lowerBraceGroup(
        self: *SourceLowerer,
        group: ir.BraceGroup,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        const redirections = try self.lowerRedirections(group.redirections, .regular_command);
        if (redirections == .failure) return .{ .failure = redirections.failure };
        const list = if (group.body_program) |program|
            try self.lowerStatementListAtLine(program.*, group.body_line_offset, target)
        else
            try self.lowerStatementListSourceAtLine(group.body, group.body_line_offset, target);
        switch (list) {
            .failure => |trap_failure| return .{ .failure = trap_failure },
            .list => |command_list| {
                const plan: command_plan.CompoundCommandPlan = .{
                    .target = target,
                    .redirections = redirections.plan,
                    .body = .{ .brace_group = command_list },
                };
                plan.validate();
                return .{ .compound = plan };
            },
        }
    }

    fn lowerSubshell(self: *SourceLowerer, subshell: ir.Subshell) !TrapActionBodyPayload {
        const redirections = try self.lowerRedirections(subshell.redirections, .regular_command);
        if (redirections == .failure) return .{ .failure = redirections.failure };
        const list = if (subshell.body_program) |program|
            try self.lowerStatementListAtLine(program.*, subshell.body_line_offset, .subshell)
        else
            try self.lowerStatementListSourceAtLine(subshell.body, subshell.body_line_offset, .subshell);
        switch (list) {
            .failure => |trap_failure| return .{ .failure = trap_failure },
            .list => |command_list| {
                const plan: command_plan.CompoundCommandPlan = .{
                    .target = .subshell,
                    .redirections = redirections.plan,
                    .body = .{ .subshell = flattenNestedSubshellOnlyList(command_list) },
                };
                plan.validate();
                return .{ .compound = plan };
            },
        }
    }

    fn flattenNestedSubshellOnlyList(list: command_plan.StatementList) command_plan.StatementList {
        var current = list;
        while (singleUnredirectedSubshellBody(current)) |nested| current = nested;
        return current;
    }

    fn singleUnredirectedSubshellBody(list: command_plan.StatementList) ?command_plan.StatementList {
        list.validate();
        if (list.commands.len != 0 or list.statements.len != 1) return null;
        const entry = list.statements[0];
        if (entry.op_before != .sequence) return null;
        return switch (entry.plan) {
            .compound => |compound| blk: {
                if (compound.target != .subshell) break :blk null;
                if (compound.redirections.steps.len != 0) break :blk null;
                break :blk switch (compound.body) {
                    .subshell => |nested| nested,
                    else => null,
                };
            },
            .simple, .pipeline, .source, .ir_source => null,
        };
    }

    fn lowerIfCommand(
        self: *SourceLowerer,
        command: ir.IfCommand,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        const redirections = try self.lowerRedirections(command.redirections, .regular_command);
        if (redirections == .failure) return .{ .failure = redirections.failure };
        const branches = try self.allocator.alloc(command_plan.IfBranch, command.branches.len);
        for (command.branches, 0..) |source_branch, branch_index| {
            const condition_result = try self.lowerStatementListSourceAtLine(
                source_branch.condition,
                source_branch.condition_line_offset,
                target,
            );
            const condition = switch (condition_result) {
                .failure => |trap_failure| return .{ .failure = trap_failure },
                .list => |list| list,
            };
            const body_result = try self.lowerStatementListSourceAtLine(
                source_branch.body,
                source_branch.body_line_offset,
                target,
            );
            const body = switch (body_result) {
                .failure => |trap_failure| return .{ .failure = trap_failure },
                .list => |list| list,
            };
            branches[branch_index] = .{ .condition = condition, .body = body };
        }
        var else_body: command_plan.StatementList = .{};
        if (command.else_body) |source| {
            const lowered_else = try self.lowerStatementListSourceAtLine(
                source,
                command.else_body_line_offset,
                target,
            );
            else_body = switch (lowered_else) {
                .failure => |trap_failure| return .{ .failure = trap_failure },
                .list => |list| list,
            };
        }
        const plan: command_plan.CompoundCommandPlan = .{
            .target = target,
            .redirections = redirections.plan,
            .body = .{ .if_clause = .{ .branches = branches, .else_body = else_body } },
        };
        plan.validate();
        return .{ .compound = plan };
    }

    fn lowerLoopCommand(
        self: *SourceLowerer,
        command: ir.LoopCommand,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        const redirections = try self.lowerRedirections(command.redirections, .regular_command);
        if (redirections == .failure) return .{ .failure = redirections.failure };
        const condition_result = try self.lowerStatementListSourceAtLine(
            command.condition,
            command.condition_line_offset,
            target,
        );
        const condition = switch (condition_result) {
            .failure => |trap_failure| return .{ .failure = trap_failure },
            .list => |list| list,
        };
        const body_result = try self.lowerStatementListSourceAtLine(command.body, command.body_line_offset, target);
        const body = switch (body_result) {
            .failure => |trap_failure| return .{ .failure = trap_failure },
            .list => |list| list,
        };
        const source_backed = self.owner.expand_aliases or command.redirections.len != 0;
        const condition_source: ?[]const u8 = if (source_backed)
            try self.allocator.dupe(u8, command.condition)
        else
            null;
        const body_source: ?[]const u8 = if (source_backed)
            try self.allocator.dupe(u8, command.body)
        else
            null;
        const loop: command_plan.LoopPlan = .{
            .condition_source = condition_source,
            .condition = condition,
            .body_source = body_source,
            .body = body,
        };
        const compound_body: command_plan.CompoundBody = switch (command.kind) {
            .while_loop => .{ .while_loop = loop },
            .until_loop => .{ .until_loop = loop },
        };
        const plan: command_plan.CompoundCommandPlan = .{
            .target = target,
            .redirections = redirections.plan,
            .body = compound_body,
        };
        plan.validate();
        return .{ .compound = plan };
    }

    fn lowerForCommand(
        self: *SourceLowerer,
        source: []const u8,
        command: ir.ForCommand,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        if (!isShellName(command.name) and self.owner.features.isBash()) {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "{s}: not a valid identifier",
                .{command.name},
            );
            const trap_failure: TrapActionFailure = .{
                .kind = .parse_error,
                .status = 1,
                .message = message,
            };
            trap_failure.validate();
            return .{ .failure = trap_failure };
        }
        const redirections = try self.lowerRedirections(command.redirections, .regular_command);
        if (redirections == .failure) return .{ .failure = redirections.failure };
        const words = if (command.use_positionals) command_plan.ForWords.positional_parameters else blk: {
            const source_words = try self.allocator.alloc(command_plan.ForWord, command.words.len);
            errdefer self.allocator.free(source_words);
            var initialized: usize = 0;
            errdefer for (source_words[0..initialized]) |word| self.allocator.free(word.raw);
            for (command.words, 0..) |word, index| {
                source_words[index] = .{
                    .raw = try self.allocator.dupe(u8, word.raw),
                    .line = self.sourceLineNumber(source, word.span.start),
                };
                initialized += 1;
            }
            break :blk command_plan.ForWords{ .source = source_words };
        };
        const name = try self.allocator.dupe(u8, command.name);
        const source_backed = self.owner.expand_aliases;
        const body_source: ?[]const u8 = if (source_backed)
            try self.allocator.dupe(u8, command.body)
        else
            null;
        const body: command_plan.StatementList = if (source_backed) .{} else blk: {
            const lowered = try self.lowerStatementListSourceAtLine(command.body, command.body_line_offset, target);
            break :blk switch (lowered) {
                .failure => |trap_failure| return .{ .failure = trap_failure },
                .list => |list| list,
            };
        };
        const plan: command_plan.CompoundCommandPlan = .{
            .target = target,
            .redirections = redirections.plan,
            .body = .{ .for_loop = .{
                .variable_name = name,
                .words = words,
                .body_source = body_source,
                .body = body,
            } },
        };
        plan.validate();
        return .{ .compound = plan };
    }

    fn lowerCaseCommand(
        self: *SourceLowerer,
        source: []const u8,
        command: ir.CaseCommand,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        const redirections = try self.lowerRedirections(command.redirections, .regular_command);
        if (redirections == .failure) return .{ .failure = redirections.failure };
        const arms = try self.allocator.alloc(command_plan.CaseArm, command.arms.len);
        for (command.arms, 0..) |arm, arm_index| {
            const patterns = try self.allocator.alloc([]const u8, arm.patterns.len);
            const pattern_lines = try self.allocator.alloc(usize, arm.patterns.len);
            for (arm.patterns, 0..) |pattern, pattern_index| {
                patterns[pattern_index] = try self.allocator.dupe(u8, pattern.raw);
                pattern_lines[pattern_index] = self.sourceLineNumber(source, pattern.span.start);
            }
            const body_result = try self.lowerStatementListSourceAtLine(arm.body, arm.body_line_offset, target);
            const body = switch (body_result) {
                .failure => |trap_failure| return .{ .failure = trap_failure },
                .list => |list| list,
            };
            arms[arm_index] = .{
                .patterns = patterns,
                .pattern_lines = pattern_lines,
                .patterns_expanded = false,
                .body = body,
                .fallthrough = arm.fallthrough,
                .test_next = arm.test_next,
            };
        }
        const raw_word = try self.allocator.dupe(u8, command.word.raw);
        const plan: command_plan.CompoundCommandPlan = .{
            .target = target,
            .redirections = redirections.plan,
            .body = .{ .case_clause = .{
                .word = raw_word,
                .word_line = self.sourceLineNumber(source, command.word.span.start),
                .word_expanded = false,
                .arms = arms,
            } },
        };
        plan.validate();
        return .{ .compound = plan };
    }

    fn lowerFunctionDefinition(
        self: *SourceLowerer,
        definition: ir.FunctionDefinition,
        target: context.ExecutionTarget,
    ) !TrapActionBodyPayload {
        const redirections = try self.lowerRedirections(definition.redirections, .regular_command);
        if (redirections == .failure) return .{ .failure = redirections.failure };
        const name = try self.allocator.dupe(u8, definition.name);
        errdefer self.allocator.free(name);
        const source_body = if (self.owner.expand_aliases)
            try parser.expandAliases(self.allocator, definition.body, .{
                .features = self.owner.features.withStrictDiagnostics(),
                .context = self.owner.alias_state orelse self.shell_state,
                .lookup = lookupSemanticAliasForParser,
            })
        else
            try self.allocator.dupe(u8, definition.body);
        errdefer self.allocator.free(source_body);
        const source_body_program = try self.cacheFunctionBodyProgram(source_body);
        const function_definition: command_plan.FunctionDefinition = .{
            .name = name,
            .source_body = source_body,
            .source_body_line_offset = self.source_line_offset + definition.body_line_offset,
            .source_body_program = source_body_program,
            .redirections = redirections.plan,
        };
        const plan: command_plan.CommandPlan = .{
            .target = target,
            .classification = .{ .function_definition = function_definition },
        };
        plan.validate();
        return .{ .simple = plan };
    }

    fn cacheFunctionBodyProgram(
        self: *SourceLowerer,
        source_body: []const u8,
    ) !?*ir.Program {
        std.debug.assert(std.mem.indexOfScalar(u8, source_body, 0) == null);
        const parsed = try self.parseWithoutAliases(source_body);
        if (parsed.diagnostics.len != 0 or parsed.incomplete) return null;

        const program = try ir.lowerSimpleCommands(self.allocator, parsed);
        if (!try self.functionBodyProgramCacheable(program)) return null;

        const owned_program = try self.allocator.create(ir.Program);
        owned_program.* = program;
        return owned_program;
    }

    fn functionBodySourceCacheable(self: *SourceLowerer, source: []const u8) !bool {
        std.debug.assert(std.mem.indexOfScalar(u8, source, 0) == null);
        const parsed = try self.parseWithoutAliases(source);
        if (parsed.diagnostics.len != 0 or parsed.incomplete) return false;

        const program = try ir.lowerSimpleCommands(self.allocator, parsed);
        return self.functionBodyProgramCacheable(program);
    }

    fn functionBodyProgramCacheable(self: *SourceLowerer, program: ir.Program) !bool {
        for (program.statements) |statement| {
            if (statement.async_after) return false;
            if (!try self.functionBodyStatementCacheable(program, statement)) return false;
        }
        return true;
    }

    fn functionBodyStatementCacheable(
        self: *SourceLowerer,
        program: ir.Program,
        statement: ir.Statement,
    ) !bool {
        return switch (statement.kind) {
            .pipeline,
            .bash_test_command,
            => true,
            .if_command => self.functionBodyIfCommandCacheable(program.if_commands[statement.index]),
            .loop_command => self.functionBodyLoopCommandCacheable(program.loop_commands[statement.index]),
            .case_command => self.functionBodyCaseCommandCacheable(program.case_commands[statement.index]),
            .brace_group => self.functionBodyGroupCacheable(
                program.brace_groups[statement.index].body,
                program.brace_groups[statement.index].redirections,
            ),
            .subshell => self.functionBodyGroupCacheable(
                program.subshells[statement.index].body,
                program.subshells[statement.index].redirections,
            ),
            .for_command,
            .function_definition,
            => false,
        };
    }

    fn functionBodyIfCommandCacheable(self: *SourceLowerer, command: ir.IfCommand) !bool {
        if (command.redirections.len != 0) return false;
        for (command.branches) |branch| {
            if (!try self.functionBodySourceCacheable(branch.condition)) return false;
            if (!try self.functionBodySourceCacheable(branch.body)) return false;
        }
        if (command.else_body) |body| {
            if (!try self.functionBodySourceCacheable(body)) return false;
        }
        return true;
    }

    fn functionBodyLoopCommandCacheable(self: *SourceLowerer, command: ir.LoopCommand) !bool {
        if (command.redirections.len != 0) return false;
        if (!try self.functionBodySourceCacheable(command.condition)) return false;
        return self.functionBodySourceCacheable(command.body);
    }

    fn functionBodyCaseCommandCacheable(self: *SourceLowerer, command: ir.CaseCommand) !bool {
        if (command.redirections.len != 0) return false;
        for (command.arms) |arm| {
            if (!try self.functionBodySourceCacheable(arm.body)) return false;
        }
        return true;
    }

    fn functionBodyGroupCacheable(
        self: *SourceLowerer,
        body: []const u8,
        redirections: []const ir.Redirection,
    ) !bool {
        if (redirections.len != 0) return false;
        return self.functionBodySourceCacheable(body);
    }

    fn lowerStatementListSource(
        self: *SourceLowerer,
        source: []const u8,
        target: context.ExecutionTarget,
    ) !StatementListLowering {
        return self.lowerStatementListSourceAtLine(source, 0, target);
    }

    fn lowerStatementListSourceAtLine(
        self: *SourceLowerer,
        source: []const u8,
        source_line_offset: usize,
        target: context.ExecutionTarget,
    ) !StatementListLowering {
        const local_function_count = self.local_functions.items.len;
        defer self.local_functions.shrinkRetainingCapacity(local_function_count);

        const previous_source_line_offset = self.source_line_offset;
        self.source_line_offset += source_line_offset;
        defer self.source_line_offset = previous_source_line_offset;

        const parsed = try self.parseWithAliases(source);
        if (parsed.diagnostics.len != 0)
            return .{ .failure = (try self.parserDiagnosticFailure(parsed.diagnostics[0])).failure };

        const program = try ir.lowerSimpleCommands(self.allocator, parsed);
        return self.lowerStatementList(program, target);
    }

    const SimpleCommandLowering = union(enum) {
        plan: command_plan.CommandPlan,
        failure: TrapActionFailure,
    };

    fn lowerIrSimpleCommand(
        self: *SourceLowerer,
        command: ir.SimpleCommand,
        target: context.ExecutionTarget,
    ) !SimpleCommandLowering {
        const assignment_words = try self.allocator.alloc([]const u8, command.assignments.len);
        for (command.assignments, 0..) |word, index| assignment_words[index] = word.raw;
        const argv_words = try self.allocator.alloc([]const u8, command.argv.len);
        for (command.argv, 0..) |word, index| argv_words[index] = word.raw;

        const expansion_target = self.expansionTarget(target);
        const expansion_eval_context = self.eval_context.withTarget(expansion_target);
        var process_id_buffer: [32]u8 = undefined;
        var last_background_pid_buffer: [32]u8 = undefined;
        var line_number_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        var command_substitutions: SourceExpansionCommandSubstitutions = .{};
        command_substitutions.init(self, expansion_eval_context);
        defer command_substitutions.deinit();
        var expansion = shell_expand.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = expansion_eval_context,
            .fs_port = self.owner.evaluator.fs_port,
            .features = self.owner.features,
            .command_substitution = command_substitutions.commandSubstitution(),
            .arg_zero = self.owner.arg_zero,
            .process_id = self.processIdText(&process_id_buffer),
            .last_background_pid = self.lastBackgroundPidText(&last_background_pid_buffer),
            .line_number = self.currentLineNumberText(&line_number_buffer),
        });
        defer expansion.deinit();

        var expanded = expansion.expandSimpleCommand(assignment_words, argv_words) catch |err| {
            if (expansion.classifyError(err)) |expansion_failure| {
                const message = try self.formatExpansionFailureMessage(expansion_failure);
                const trap_failure: TrapActionFailure = .{
                    .kind = .expansion_error,
                    .status = statusForExpansionFailure(self.owner.features, expansion_failure),
                    .message = message,
                    .bash_arithmetic_expansion = self.owner.bashMode() and
                        expansion_failure.kind == .arithmetic_expansion,
                    .bash_arithmetic_readonly_assignment = self.owner.bashMode() and
                        expansion_failure.kind == .arithmetic_expansion and
                        std.mem.eql(u8, expansion_failure.message, "readonly variable"),
                    .bash_arithmetic_assignment_only_expansion = self.owner.bashMode() and
                        command.argv.len == 0 and
                        expansion_failure.kind == .arithmetic_expansion,
                    .bash_parameter_assignment_expansion = self.owner.bashMode() and
                        expansion_failure.kind == .parameter_assignment,
                };
                trap_failure.validate();
                return .{ .failure = trap_failure };
            }
            return err;
        };
        expanded.command.validate();
        if (command_substitutions.context.fatal_failure) |trap_failure| {
            return .{ .failure = try cloneTrapActionFailure(self.allocator, trap_failure) };
        }
        expanded.command.last_command_substitution_status = command_substitutions.context.last_status;
        expanded.command.source_line = self.current_line_number;
        try appendCommandSubstitutionExpansionOutput(self.allocator, &expanded.command, command_substitutions.context);
        const lookup = try self.lookupSnapshot(expanded.command);
        const plan_without_redirections = command_plan.classifyExpandedSimpleCommand(.{
            .command = expanded.command,
            .lookup = lookup,
            .target = target,
        });
        const redirections = try self.lowerRedirections(
            command.redirections,
            redirectionFailurePolicy(plan_without_redirections.class(), self.eval_context),
        );
        if (redirections == .failure) {
            return .{ .failure = redirections.failure };
        }
        expanded.command.redirections = redirections.plan;
        const plan = command_plan.classifyExpandedSimpleCommand(.{
            .command = expanded.command,
            .lookup = lookup,
            .target = target,
        });
        plan.validate();
        return .{ .plan = plan };
    }

    fn appendCommandSubstitutionExpansionOutput(
        allocator: std.mem.Allocator,
        command: *command_plan.ExpandedSimpleCommand,
        expansion_context: CommandSubstitutionExpansionContext,
    ) !void {
        command.validate();
        expansion_context.validate();

        var output: command_plan.ExpansionOutput = .{};
        if (expansion_context.stderr.items.len != 0) {
            output.stderr = try allocator.dupe(u8, expansion_context.stderr.items);
        }
        if (expansion_context.side_stdout.items.len != 0) {
            output.side_stdout = try allocator.dupe(u8, expansion_context.side_stdout.items);
        }
        if (expansion_context.diagnostics.items.len != 0) {
            const diagnostics = try allocator.alloc([]const u8, expansion_context.diagnostics.items.len);
            var diagnostics_owned: usize = 0;
            errdefer {
                for (diagnostics[0..diagnostics_owned]) |message| allocator.free(message);
                allocator.free(diagnostics);
            }
            for (expansion_context.diagnostics.items, 0..) |diagnostic, index| {
                diagnostics[index] = try allocator.dupe(u8, diagnostic.message);
                diagnostics_owned += 1;
            }
            output.diagnostics = diagnostics;
        }
        command.expansion_output = output;
        command.validate();
    }

    fn lookupSnapshot(
        self: *SourceLowerer,
        command: command_plan.ExpandedSimpleCommand,
    ) !command_plan.LookupSnapshot {
        var functions: std.ArrayList(command_plan.FunctionDefinition) = .empty;
        errdefer functions.deinit(self.allocator);
        try functions.appendSlice(self.allocator, self.local_functions.items);
        var iterator = self.shell_state.functions.iterator();
        while (iterator.next()) |entry| {
            if (self.localFunction(entry.key_ptr.*) != null) continue;
            try functions.append(
                self.allocator,
                try command_plan.cloneFunctionDefinition(self.allocator, entry.value_ptr.*),
            );
        }

        var externals: std.ArrayList(command_plan.ExternalResolution) = .empty;
        errdefer externals.deinit(self.allocator);
        try externals.appendSlice(self.allocator, self.owner.externals);
        if (try self.resolveExternal(command)) |external| try externals.append(self.allocator, external);

        return .{
            .functions = try functions.toOwnedSlice(self.allocator),
            .externals = try externals.toOwnedSlice(self.allocator),
        };
    }

    fn rememberLocalFunction(self: *SourceLowerer, definition: command_plan.FunctionDefinition) !void {
        definition.validate();
        for (self.local_functions.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, definition.name)) continue;
            existing.* = definition;
            return;
        }
        try self.local_functions.append(self.allocator, definition);
    }

    fn localFunction(self: SourceLowerer, name: []const u8) ?command_plan.FunctionDefinition {
        for (self.local_functions.items) |definition| {
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    const LoweredRedirections = union(enum) {
        plan: redirection_plan.RedirectionPlan,
        failure: TrapActionFailure,
    };

    const LoweredRedirection = union(enum) {
        spec: redirection_plan.RedirectionSpec,
        failure: TrapActionFailure,
    };

    const HereDocLowering = union(enum) {
        data: HereDocValue,
        failure: TrapActionFailure,
    };

    const HereDocValue = struct {
        data: []const u8,
        output: redirection_plan.ExpansionOutput = .{},
    };

    const RedirectionFieldsValue = struct {
        fields: redirection_plan.ExpandedFields,
        output: redirection_plan.ExpansionOutput = .{},
    };

    const ExpandedFieldsLowering = union(enum) {
        fields: RedirectionFieldsValue,
        failure: TrapActionFailure,
    };

    const ScalarExpansionValue = struct {
        value: []const u8,
        output: command_plan.ExpansionOutput = .{},
    };

    const ScalarExpansionLowering = union(enum) {
        value: ScalarExpansionValue,
        failure: TrapActionFailure,
    };

    const WordExpansionValue = struct {
        result: expand.ExpansionResult,
        output: command_plan.ExpansionOutput = .{},
    };

    const WordExpansionLowering = union(enum) {
        result: WordExpansionValue,
        failure: TrapActionFailure,
    };

    const ExpansionOutputAccumulator = struct {
        stderr: std.ArrayList(u8) = .empty,
        side_stdout: std.ArrayList(u8) = .empty,
        diagnostics: std.ArrayList([]const u8) = .empty,

        fn appendOwned(
            allocator: std.mem.Allocator,
            self: *ExpansionOutputAccumulator,
            output: command_plan.ExpansionOutput,
        ) !void {
            output.validate();
            errdefer freeExpansionOutput(allocator, output);
            try self.stderr.appendSlice(allocator, output.stderr);
            try self.side_stdout.appendSlice(allocator, output.side_stdout);
            try self.diagnostics.appendSlice(allocator, output.diagnostics);
            allocator.free(output.stderr);
            allocator.free(output.side_stdout);
            allocator.free(output.diagnostics);
        }

        fn toOwned(
            allocator: std.mem.Allocator,
            self: *ExpansionOutputAccumulator,
        ) !command_plan.ExpansionOutput {
            const stderr = try self.stderr.toOwnedSlice(allocator);
            errdefer allocator.free(stderr);
            const side_stdout = try self.side_stdout.toOwnedSlice(allocator);
            errdefer allocator.free(side_stdout);
            const diagnostics = try self.diagnostics.toOwnedSlice(allocator);
            return .{ .stderr = stderr, .side_stdout = side_stdout, .diagnostics = diagnostics };
        }

        fn deinit(allocator: std.mem.Allocator, self: *ExpansionOutputAccumulator) void {
            self.stderr.deinit(allocator);
            self.side_stdout.deinit(allocator);
            for (self.diagnostics.items) |message| allocator.free(message);
            self.diagnostics.deinit(allocator);
            self.* = undefined;
        }
    };

    fn freeExpansionOutput(allocator: std.mem.Allocator, output: command_plan.ExpansionOutput) void {
        allocator.free(output.stderr);
        allocator.free(output.side_stdout);
        for (output.diagnostics) |message| allocator.free(message);
        allocator.free(output.diagnostics);
    }

    fn captureExpansionOutput(
        self: *SourceLowerer,
        expansion_context: CommandSubstitutionExpansionContext,
    ) !command_plan.ExpansionOutput {
        expansion_context.validate();
        const stderr = try self.allocator.dupe(u8, expansion_context.stderr.items);
        errdefer self.allocator.free(stderr);
        const side_stdout = try self.allocator.dupe(u8, expansion_context.side_stdout.items);
        errdefer self.allocator.free(side_stdout);
        const diagnostics = try self.allocator.alloc([]const u8, expansion_context.diagnostics.items.len);
        errdefer self.allocator.free(diagnostics);
        var initialized: usize = 0;
        errdefer for (diagnostics[0..initialized]) |message| self.allocator.free(message);
        for (expansion_context.diagnostics.items, 0..) |diagnostic, index| {
            diagnostics[index] = try self.allocator.dupe(u8, diagnostic.message);
            initialized += 1;
        }
        const output: command_plan.ExpansionOutput = .{
            .stderr = stderr,
            .side_stdout = side_stdout,
            .diagnostics = diagnostics,
        };
        output.validate();
        return output;
    }

    fn captureRedirectionExpansionOutput(
        self: *SourceLowerer,
        expansion_context: CommandSubstitutionExpansionContext,
    ) !redirection_plan.ExpansionOutput {
        expansion_context.validate();
        const stderr: redirection_plan.DataSlice = .{
            .bytes = try self.allocator.dupe(u8, expansion_context.stderr.items),
            .ownership = .owned_by_plan,
        };
        errdefer self.allocator.free(stderr.bytes);
        const diagnostics = try self.allocator.alloc(
            redirection_plan.DataSlice,
            expansion_context.diagnostics.items.len,
        );
        errdefer self.allocator.free(diagnostics);
        var initialized: usize = 0;
        errdefer for (diagnostics[0..initialized]) |diagnostic| self.allocator.free(diagnostic.bytes);
        for (expansion_context.diagnostics.items, 0..) |diagnostic, index| {
            diagnostics[index] = .{
                .bytes = try self.allocator.dupe(u8, diagnostic.message),
                .ownership = .owned_by_plan,
            };
            initialized += 1;
        }
        const output: redirection_plan.ExpansionOutput = .{ .stderr = stderr, .diagnostics = diagnostics };
        output.validate();
        return output;
    }

    fn lowerRedirections(
        self: *SourceLowerer,
        redirections: []const ir.Redirection,
        failure_policy: redirection_plan.FailurePolicy,
    ) !LoweredRedirections {
        if (redirections.len == 0) return .{ .plan = .{} };

        var specs: std.ArrayList(redirection_plan.RedirectionSpec) = .empty;
        defer specs.deinit(self.allocator);

        for (redirections) |redirection| {
            const spec = switch (try self.lowerRedirection(redirection)) {
                .spec => |spec| spec,
                .failure => |trap_failure| return .{ .failure = trap_failure },
            };
            try specs.append(self.allocator, spec);
        }

        const plan_result = try redirection_plan.RedirectionPlan.build(self.allocator, specs.items, .{
            .noclobber = self.shell_state.options.noclobber,
            .failure_policy = failure_policy,
            .self_duplicate_noop = true,
        });
        return switch (plan_result) {
            .plan => |plan| .{ .plan = plan },
            .failure => |planning_failure| .{ .failure = .{
                .kind = .lowering_error,
                .status = consequence.statusForRedirectionFailure(planning_failure.consequence),
                .message = try self.formatRedirectionPlanningFailure(planning_failure.diagnosticText()),
            } },
        };
    }

    fn lowerRedirection(self: *SourceLowerer, redirection: ir.Redirection) !LoweredRedirection {
        const operator = redirectionOperator(redirection.operator) orelse
            return .{ .failure = try self.malformedRedirectionFailure() };
        const descriptor = if (redirection.io_number) |io_number| std.fmt.parseInt(
            runtime.fd.Descriptor,
            io_number.text,
            10,
        ) catch return .{ .failure = try self.malformedRedirectionFailure() } else null;
        if (descriptor) |fd| if (!runtime.fd.isValidDescriptor(fd))
            return .{ .failure = try self.malformedRedirectionFailure() };

        if (redirection.operator == .tless) {
            const target_word = redirection.target orelse return .{ .failure = try self.malformedRedirectionFailure() };
            const here_string = switch (try self.expandHereStringForRedirection(
                target_word.raw,
                self.eval_context.target,
            )) {
                .data => |data| data,
                .failure => |trap_failure| return .{ .failure = trap_failure },
            };
            return .{ .spec = .{
                .descriptor = descriptor,
                .operator = operator,
                .operand = .{ .here_doc = .{ .bytes = here_string.data, .ownership = .owned_by_plan } },
                .expansion_output = here_string.output,
            } };
        }

        if (operator == .here_doc) {
            const body = redirection.here_doc orelse "";
            const here_doc = if (redirection.here_doc_quoted) HereDocValue{ .data = try self.allocator.dupe(
                u8,
                body,
            ) } else switch (try self.expandHereDocForRedirection(
                body,
                self.eval_context.target,
            )) {
                .data => |data| data,
                .failure => |trap_failure| return .{ .failure = trap_failure },
            };
            return .{ .spec = .{
                .descriptor = descriptor,
                .operator = operator,
                .operand = .{ .here_doc = .{ .bytes = here_doc.data, .ownership = .owned_by_plan } },
                .expansion_output = here_doc.output,
            } };
        }

        const target_word = redirection.target orelse return .{ .failure = try self.malformedRedirectionFailure() };
        const expanded_fields = switch (try self.expandFieldsForRedirection(
            target_word.raw,
            self.eval_context.target,
        )) {
            .fields => |fields| fields,
            .failure => |trap_failure| return .{ .failure = trap_failure },
        };
        return .{ .spec = .{
            .descriptor = descriptor,
            .operator = operator,
            .operand = .{ .fields = expanded_fields.fields },
            .expansion_output = expanded_fields.output,
        } };
    }

    fn expandHereStringForRedirection(
        self: *SourceLowerer,
        raw: []const u8,
        target: context.ExecutionTarget,
    ) !HereDocLowering {
        return switch (try self.expandFieldsForRedirection(raw, target)) {
            .fields => |expanded| blk: {
                std.debug.assert(expanded.fields.fields.len == 1);
                const field = expanded.fields.fields[0];
                const data = try std.fmt.allocPrint(self.allocator, "{s}\n", .{field});
                switch (expanded.fields.ownership) {
                    .owned_by_plan => {
                        self.allocator.free(field);
                        self.allocator.free(expanded.fields.fields);
                    },
                    .borrowed => {},
                }
                break :blk .{ .data = .{ .data = data, .output = expanded.output } };
            },
            .failure => |trap_failure| .{ .failure = trap_failure },
        };
    }

    fn malformedRedirectionFailure(self: *SourceLowerer) !TrapActionFailure {
        const trap_failure: TrapActionFailure = .{
            .kind = .lowering_error,
            .message = try self.formatMalformedRedirectionFailure(),
        };
        trap_failure.validate();
        return trap_failure;
    }

    fn expandFieldsForRedirection(
        self: *SourceLowerer,
        raw: []const u8,
        target: context.ExecutionTarget,
    ) !ExpandedFieldsLowering {
        const expansion_target = self.expansionTarget(target);
        const expansion_eval_context = self.eval_context.withTarget(expansion_target);
        var process_id_buffer: [32]u8 = undefined;
        var last_background_pid_buffer: [32]u8 = undefined;
        var line_number_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        var command_substitutions: SourceExpansionCommandSubstitutions = .{};
        command_substitutions.init(self, expansion_eval_context);
        defer command_substitutions.deinit();
        var expansion = shell_expand.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = expansion_eval_context,
            .fs_port = self.owner.evaluator.fs_port,
            .features = self.owner.features,
            .command_substitution = command_substitutions.commandSubstitution(),
            .arg_zero = self.owner.arg_zero,
            .process_id = self.processIdText(&process_id_buffer),
            .last_background_pid = self.lastBackgroundPidText(&last_background_pid_buffer),
            .line_number = self.currentLineNumberText(&line_number_buffer),
        });
        defer expansion.deinit();
        const field = expansion.expandWordScalar(raw) catch |err| {
            if (expansion.classifyError(err)) |expansion_failure|
                return .{ .failure = try self.expansionFailure(expansion_failure) };
            return err;
        };
        if (command_substitutions.context.fatal_failure) |trap_failure| {
            return .{ .failure = try cloneTrapActionFailure(self.allocator, trap_failure) };
        }
        const fields = try self.allocator.alloc([]const u8, 1);
        errdefer {
            self.allocator.free(field);
            self.allocator.free(fields);
        }
        fields[0] = field;
        return .{ .fields = .{
            .fields = .{ .fields = fields, .ownership = .owned_by_plan },
            .output = try self.captureRedirectionExpansionOutput(command_substitutions.context),
        } };
    }

    fn expandHereDocForRedirection(
        self: *SourceLowerer,
        text: []const u8,
        target: context.ExecutionTarget,
    ) !HereDocLowering {
        const expansion_target = self.expansionTarget(target);
        const expansion_eval_context = self.eval_context.withTarget(expansion_target);
        var process_id_buffer: [32]u8 = undefined;
        var last_background_pid_buffer: [32]u8 = undefined;
        var line_number_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        var command_substitutions: SourceExpansionCommandSubstitutions = .{};
        command_substitutions.init(self, expansion_eval_context);
        defer command_substitutions.deinit();
        var expansion = shell_expand.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = expansion_eval_context,
            .fs_port = self.owner.evaluator.fs_port,
            .features = self.owner.features,
            .command_substitution = command_substitutions.commandSubstitution(),
            .arg_zero = self.owner.arg_zero,
            .process_id = self.processIdText(&process_id_buffer),
            .last_background_pid = self.lastBackgroundPidText(&last_background_pid_buffer),
            .line_number = self.currentLineNumberText(&line_number_buffer),
        });
        defer expansion.deinit();
        const data = expansion.expandHereDocBody(text) catch |err| {
            if (expansion.classifyError(err)) |expansion_failure|
                return .{ .failure = try self.expansionFailure(expansion_failure) };
            return err;
        };
        if (command_substitutions.context.fatal_failure) |trap_failure| {
            return .{ .failure = try cloneTrapActionFailure(self.allocator, trap_failure) };
        }
        return .{ .data = .{
            .data = data,
            .output = try self.captureRedirectionExpansionOutput(command_substitutions.context),
        } };
    }

    fn expansionFailure(self: *SourceLowerer, expansion_failure: shell_expand.ExpansionFailure) !TrapActionFailure {
        const trap_failure: TrapActionFailure = .{
            .kind = .expansion_error,
            .message = try self.formatExpansionFailureMessage(expansion_failure),
            .bash_arithmetic_expansion = self.owner.bashMode() and
                expansion_failure.kind == .arithmetic_expansion,
            .bash_arithmetic_readonly_assignment = self.owner.bashMode() and
                expansion_failure.kind == .arithmetic_expansion and
                std.mem.eql(u8, expansion_failure.message, "readonly variable"),
        };
        trap_failure.validate();
        return trap_failure;
    }

    fn formatExpansionFailureMessage(
        self: *SourceLowerer,
        expansion_failure: shell_expand.ExpansionFailure,
    ) ![]const u8 {
        if (self.signal) |signal| {
            if (self.scriptPathForDiagnostics()) |path| return std.fmt.allocPrint(
                self.allocator,
                "{s}:{d}: trap {s}: expansion error: {s}: {s}",
                .{ path, self.current_line_number, signal.name(), expansion_failure.name, expansion_failure.message },
            );
            if (self.lineNumberForDiagnostics()) |line_number| return std.fmt.allocPrint(
                self.allocator,
                "{d}: trap {s}: expansion error: {s}: {s}",
                .{ line_number, signal.name(), expansion_failure.name, expansion_failure.message },
            );
            return std.fmt.allocPrint(
                self.allocator,
                "trap {s}: expansion error: {s}: {s}",
                .{ signal.name(), expansion_failure.name, expansion_failure.message },
            );
        }
        if (self.scriptPathForDiagnostics()) |path| return std.fmt.allocPrint(
            self.allocator,
            "{s}:{d}: expansion error: {s}: {s}",
            .{ path, self.current_line_number, expansion_failure.name, expansion_failure.message },
        );
        if (self.lineNumberForDiagnostics()) |line_number| return std.fmt.allocPrint(
            self.allocator,
            "{d}: expansion error: {s}: {s}",
            .{ line_number, expansion_failure.name, expansion_failure.message },
        );
        return std.fmt.allocPrint(
            self.allocator,
            "expansion error: {s}: {s}",
            .{ expansion_failure.name, expansion_failure.message },
        );
    }

    fn scriptPathForDiagnostics(self: SourceLowerer) ?[]const u8 {
        return if (self.eval_context.source == .script_file) self.owner.arg_zero else null;
    }

    fn lineNumberForDiagnostics(self: SourceLowerer) ?usize {
        return if (self.eval_context.source == .command_string and self.owner.command_string_line_diagnostics)
            self.current_line_number
        else
            null;
    }

    fn resolveExternal(
        self: *SourceLowerer,
        command: command_plan.ExpandedSimpleCommand,
    ) !?command_plan.ExternalResolution {
        command.validate();
        if (command.argv.len == 0) return null;
        const name = command.argv[0];
        if (name.len == 0) return null;
        if (std.mem.findScalar(u8, name, '/') != null) {
            const owned_path = try self.allocator.dupe(u8, name);
            return .{ .name = name, .path = owned_path };
        }

        const fs_port = self.owner.evaluator.fs_port orelse return null;
        const path_value = commandLookupPath(self.shell_state.*, command) orelse return null;
        var first_found: ?[]const u8 = null;
        errdefer if (first_found) |path| self.allocator.free(path);
        var parts = std.mem.splitScalar(u8, path_value, ':');
        while (parts.next()) |part| {
            const dir = if (part.len == 0) "." else part;
            const candidate = try std.mem.concat(self.allocator, u8, &.{ dir, "/", name });
            errdefer self.allocator.free(candidate);
            switch (externalCandidate(fs_port, candidate)) {
                .missing => self.allocator.free(candidate),
                .found_not_executable => {
                    if (first_found == null) {
                        first_found = candidate;
                    } else {
                        self.allocator.free(candidate);
                    }
                },
                .executable => {
                    if (first_found) |path| self.allocator.free(path);
                    return .{ .name = name, .path = candidate };
                },
            }
        }
        if (first_found) |path| {
            first_found = null;
            return .{ .name = name, .path = path };
        }
        return null;
    }

    fn expandScalar(
        self: *SourceLowerer,
        raw: []const u8,
        target: context.ExecutionTarget,
    ) !ScalarExpansionLowering {
        const expansion_target = self.expansionTarget(target);
        const expansion_eval_context = self.eval_context.withTarget(expansion_target);
        var process_id_buffer: [32]u8 = undefined;
        var last_background_pid_buffer: [32]u8 = undefined;
        var line_number_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        var command_substitutions: SourceExpansionCommandSubstitutions = .{};
        command_substitutions.init(self, expansion_eval_context);
        defer command_substitutions.deinit();
        var expansion = shell_expand.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = expansion_eval_context,
            .fs_port = self.owner.evaluator.fs_port,
            .features = self.owner.features,
            .command_substitution = command_substitutions.commandSubstitution(),
            .arg_zero = self.owner.arg_zero,
            .process_id = self.processIdText(&process_id_buffer),
            .last_background_pid = self.lastBackgroundPidText(&last_background_pid_buffer),
            .line_number = self.currentLineNumberText(&line_number_buffer),
        });
        defer expansion.deinit();
        const value = expansion.expandWordScalar(raw) catch |err| {
            if (expansion.classifyError(err)) |expansion_failure|
                return .{ .failure = try self.expansionFailure(expansion_failure) };
            return err;
        };
        if (command_substitutions.context.fatal_failure) |trap_failure| {
            return .{ .failure = try cloneTrapActionFailure(self.allocator, trap_failure) };
        }
        return .{ .value = .{
            .value = value,
            .output = try self.captureExpansionOutput(command_substitutions.context),
        } };
    }

    fn expandCasePattern(
        self: *SourceLowerer,
        raw: []const u8,
        target: context.ExecutionTarget,
    ) !ScalarExpansionLowering {
        const expansion_target = self.expansionTarget(target);
        const expansion_eval_context = self.eval_context.withTarget(expansion_target);
        var process_id_buffer: [32]u8 = undefined;
        var last_background_pid_buffer: [32]u8 = undefined;
        var line_number_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        var command_substitutions: SourceExpansionCommandSubstitutions = .{};
        command_substitutions.init(self, expansion_eval_context);
        defer command_substitutions.deinit();
        var expansion = shell_expand.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = expansion_eval_context,
            .fs_port = self.owner.evaluator.fs_port,
            .features = self.owner.features,
            .command_substitution = command_substitutions.commandSubstitution(),
            .arg_zero = self.owner.arg_zero,
            .process_id = self.processIdText(&process_id_buffer),
            .last_background_pid = self.lastBackgroundPidText(&last_background_pid_buffer),
            .line_number = self.currentLineNumberText(&line_number_buffer),
        });
        defer expansion.deinit();
        const value = expansion.expandCasePattern(raw) catch |err| {
            if (expansion.classifyError(err)) |expansion_failure|
                return .{ .failure = try self.expansionFailure(expansion_failure) };
            return err;
        };
        if (command_substitutions.context.fatal_failure) |trap_failure| {
            return .{ .failure = try cloneTrapActionFailure(self.allocator, trap_failure) };
        }
        return .{ .value = .{
            .value = value,
            .output = try self.captureExpansionOutput(command_substitutions.context),
        } };
    }

    fn expandFields(
        self: *SourceLowerer,
        raw: []const u8,
        target: context.ExecutionTarget,
    ) !WordExpansionLowering {
        const expansion_target = self.expansionTarget(target);
        const expansion_eval_context = self.eval_context.withTarget(expansion_target);
        var process_id_buffer: [32]u8 = undefined;
        var last_background_pid_buffer: [32]u8 = undefined;
        var line_number_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        var command_substitutions: SourceExpansionCommandSubstitutions = .{};
        command_substitutions.init(self, expansion_eval_context);
        defer command_substitutions.deinit();
        var expansion = shell_expand.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = expansion_eval_context,
            .fs_port = self.owner.evaluator.fs_port,
            .features = self.owner.features,
            .command_substitution = command_substitutions.commandSubstitution(),
            .arg_zero = self.owner.arg_zero,
            .process_id = self.processIdText(&process_id_buffer),
            .last_background_pid = self.lastBackgroundPidText(&last_background_pid_buffer),
            .line_number = self.currentLineNumberText(&line_number_buffer),
        });
        defer expansion.deinit();
        const result = expansion.expandWordFields(raw) catch |err| {
            if (expansion.classifyError(err)) |expansion_failure|
                return .{ .failure = try self.expansionFailure(expansion_failure) };
            return err;
        };
        if (command_substitutions.context.fatal_failure) |trap_failure| {
            return .{ .failure = try cloneTrapActionFailure(self.allocator, trap_failure) };
        }
        return .{ .result = .{
            .result = result,
            .output = try self.captureExpansionOutput(command_substitutions.context),
        } };
    }

    fn expandHereDoc(self: *SourceLowerer, text: []const u8, target: context.ExecutionTarget) ![]const u8 {
        const expansion_target = self.expansionTarget(target);
        const expansion_eval_context = self.eval_context.withTarget(expansion_target);
        var process_id_buffer: [32]u8 = undefined;
        var last_background_pid_buffer: [32]u8 = undefined;
        var line_number_buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
        var command_substitutions: SourceExpansionCommandSubstitutions = .{};
        command_substitutions.init(self, expansion_eval_context);
        defer command_substitutions.deinit();
        var expansion = shell_expand.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = expansion_eval_context,
            .fs_port = self.owner.evaluator.fs_port,
            .features = self.owner.features,
            .command_substitution = command_substitutions.commandSubstitution(),
            .arg_zero = self.owner.arg_zero,
            .process_id = self.processIdText(&process_id_buffer),
            .last_background_pid = self.lastBackgroundPidText(&last_background_pid_buffer),
            .line_number = self.currentLineNumberText(&line_number_buffer),
        });
        defer expansion.deinit();
        return expansion.expandHereDocBody(text);
    }

    fn processIdText(self: SourceLowerer, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{d}", .{self.owner.evaluator.shell_pid}) catch "";
    }

    fn lastBackgroundPidText(self: SourceLowerer, buffer: []u8) []const u8 {
        if (self.shell_state.last_background_pid) |pid| return std.fmt.bufPrint(buffer, "{d}", .{pid}) catch "";
        return "";
    }

    fn expansionTarget(self: SourceLowerer, target: context.ExecutionTarget) context.ExecutionTarget {
        std.debug.assert(target.allowsShellStateCommit());
        if (self.shell_state.acceptsExecutionTarget(target)) return target;
        std.debug.assert(target == .subshell);
        std.debug.assert(self.shell_state.acceptsExecutionTarget(self.eval_context.target));
        return self.eval_context.target;
    }

    fn parserDiagnosticFailure(self: *SourceLowerer, diagnostic: parser.Diagnostic) !TrapActionBodyPayload {
        const message = if (self.signal) |signal|
            try std.fmt.allocPrint(
                self.allocator,
                "trap {s}: parse error: {s}",
                .{ signal.name(), diagnostic.message },
            )
        else
            try std.fmt.allocPrint(self.allocator, "parse error: {s}", .{diagnostic.message});
        const trap_failure: TrapActionFailure = .{
            .kind = .parse_error,
            .status = if (self.shell_state.last_status == 0) 2 else self.shell_state.last_status,
            .message = message,
        };
        trap_failure.validate();
        return .{ .failure = trap_failure };
    }

    fn commandSubstitutionDiagnosticFailure(
        self: *SourceLowerer,
        diagnostic: parser.Diagnostic,
    ) !CommandSubstitutionBodyPayload {
        const message = if (self.signal) |signal|
            try std.fmt.allocPrint(
                self.allocator,
                "trap {s}: command substitution parse error: {s}",
                .{ signal.name(), diagnostic.message },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "command substitution parse error: {s}",
                .{diagnostic.message},
            );
        const trap_failure: TrapActionFailure = .{
            .kind = .parse_error,
            .message = message,
            .fatal_noninteractive = true,
        };
        trap_failure.validate();
        return .{ .failure = trap_failure };
    }

    fn incompleteSourceFailure(self: *SourceLowerer) !TrapActionBodyPayload {
        if (self.signal) |signal| return self.failure(
            "trap {s}: parse error: incomplete trap action",
            .parse_error,
            .{signal.name()},
        );
        return self.failure("parse error: incomplete source", .parse_error, .{});
    }

    fn incompletePipelineStageFailure(self: *SourceLowerer) !TrapActionBodyPayload {
        if (self.signal) |signal| return self.failure(
            "trap {s}: parse error: incomplete pipeline stage",
            .parse_error,
            .{signal.name()},
        );
        return self.failure("parse error: incomplete pipeline stage", .parse_error, .{});
    }

    fn unsupportedShapeFailure(
        self: *SourceLowerer,
        comptime trap_detail: []const u8,
        comptime source_detail: []const u8,
    ) !TrapActionBodyPayload {
        if (self.signal) |signal| return self.failure(
            "trap {s}: unsupported trap action: " ++ trap_detail,
            .unsupported_shape,
            .{signal.name()},
        );
        return self.failure("unsupported source shape: " ++ source_detail, .unsupported_shape, .{});
    }

    fn formatRedirectionPlanningFailure(self: *SourceLowerer, diagnostic: []const u8) ![]const u8 {
        if (self.signal) |signal| return std.fmt.allocPrint(
            self.allocator,
            "trap {s}: redirection planning error: {s}",
            .{ signal.name(), diagnostic },
        );
        return std.fmt.allocPrint(self.allocator, "redirection planning error: {s}", .{diagnostic});
    }

    fn formatMalformedRedirectionFailure(self: *SourceLowerer) ![]const u8 {
        if (self.signal) |signal| return std.fmt.allocPrint(
            self.allocator,
            "trap {s}: malformed redirection",
            .{signal.name()},
        );
        return self.allocator.dupe(u8, "malformed redirection");
    }

    fn failure(
        self: *SourceLowerer,
        comptime fmt: []const u8,
        kind: TrapActionFailureKind,
        args: anytype,
    ) !TrapActionBodyPayload {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const trap_failure: TrapActionFailure = .{ .kind = kind, .message = message };
        trap_failure.validate();
        return .{ .failure = trap_failure };
    }
};

fn redirectionOperator(token: parser.TokenKind) ?redirection_plan.RedirectionOperator {
    return switch (token) {
        .less => .input,
        .greater => .output,
        .dless, .dless_dash, .tless => .here_doc,
        .dgreat => .append,
        .less_and => .duplicate_input,
        .greater_and => .duplicate_output,
        .less_great => .input_output,
        .clobber => .clobber,
        else => null,
    };
}

fn statusForExpansionFailure(
    features: compat.Features,
    failure: shell_expand.ExpansionFailure,
) outcome.ExitStatus {
    if (features.isBash()) switch (failure.kind) {
        .nounset_parameter, .parameter_expansion => return 127,
        .parameter_assignment, .arithmetic_expansion => {},
    };
    return 1;
}

fn redirectionFailurePolicy(
    command_class: command_plan.CommandClass,
    eval_context: context.EvalContext,
) redirection_plan.FailurePolicy {
    eval_context.validate();
    return switch (command_class) {
        .special_builtin => if (eval_context.interactive)
            .special_builtin_interactive
        else if (eval_context.features.isBash())
            .regular_command
        else
            .special_builtin_non_interactive,
        else => .regular_command,
    };
}

fn commandLookupPath(shell_state: state.ShellState, command: command_plan.ExpandedSimpleCommand) ?[]const u8 {
    shell_state.validate();
    command.validate();
    var path_value: ?[]const u8 = null;
    for (command.assignments) |assignment| {
        assignment.validate();
        if (std.mem.eql(u8, assignment.name, "PATH")) path_value = assignment.value;
    }
    if (path_value) |value| return value;
    const path = shell_state.getVariable("PATH") orelse return null;
    return path.value;
}

const ExternalCandidate = enum {
    missing,
    found_not_executable,
    executable,
};

fn externalCandidate(fs_port: runtime.fs.Port, path: []const u8) ExternalCandidate {
    _ = fs_port.inspectPath(.{ .path = path }) catch return .missing;
    fs_port.access(.{ .path = path, .execute = true }) catch return .found_not_executable;
    return .executable;
}

pub const RuntimeSignalObservation = struct {
    signal: state.TrapSignal,
    delivery: state.TrapDelivery,
    command_outcome: outcome.CommandOutcome,

    pub fn deinit(self: *RuntimeSignalObservation) void {
        self.command_outcome.deinit();
        self.* = undefined;
    }

    pub fn validate(self: RuntimeSignalObservation, eval_context: context.EvalContext) void {
        self.signal.validate();
        self.command_outcome.validateForContext(eval_context);
        switch (self.delivery) {
            .queued => std.debug.assert(self.command_outcome.state_delta.pending_trap_enqueues.items.len == 1),
            .ignored => std.debug.assert(self.command_outcome.state_delta.pending_trap_enqueues.items.len == 0),
            .default_action => std.debug.assert(self.command_outcome.control_flow != .normal),
        }
    }
};

pub const CommandSubstitutionBodyPayload = union(enum) {
    simple: command_plan.CommandPlan,
    compound: command_plan.CompoundCommandPlan,
    pipeline: pipeline_plan.PipelinePlan,
    failure: TrapActionFailure,

    fn validate(self: CommandSubstitutionBodyPayload) void {
        switch (self) {
            .simple => |plan| {
                plan.validate();
                std.debug.assert(plan.target != .current_shell);
            },
            .compound => |plan| {
                plan.validate();
                std.debug.assert(plan.target != .current_shell);
            },
            .pipeline => |plan| {
                plan.validate();
                for (plan.stages, 0..) |_, index| std.debug.assert(plan.stageTarget(index) != .current_shell);
            },
            .failure => |failure| failure.validate(),
        }
    }
};

pub const OwnedCommandSubstitutionBody = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    body: CommandSubstitutionBodyPayload,

    fn init(
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        body: CommandSubstitutionBodyPayload,
    ) OwnedCommandSubstitutionBody {
        body.validate();
        const owned: OwnedCommandSubstitutionBody = .{ .allocator = allocator, .arena = arena, .body = body };
        owned.validate();
        return owned;
    }

    fn deinit(self: *OwnedCommandSubstitutionBody) void {
        self.validate();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    fn validate(self: OwnedCommandSubstitutionBody) void {
        self.body.validate();
    }
};

pub const CommandSubstitutionBody = union(enum) {
    simple: command_plan.CommandPlan,
    compound: command_plan.CompoundCommandPlan,
    pipeline: pipeline_plan.PipelinePlan,
    failure: TrapActionFailure,
    owned: OwnedCommandSubstitutionBody,

    pub fn deinit(self: *CommandSubstitutionBody) void {
        switch (self.*) {
            .owned => |*owned| owned.deinit(),
            .simple, .compound, .pipeline, .failure => {},
        }
        self.* = undefined;
    }

    pub fn validate(self: CommandSubstitutionBody) void {
        switch (self) {
            .simple => |plan| (CommandSubstitutionBodyPayload{ .simple = plan }).validate(),
            .compound => |plan| (CommandSubstitutionBodyPayload{ .compound = plan }).validate(),
            .pipeline => |plan| (CommandSubstitutionBodyPayload{ .pipeline = plan }).validate(),
            .failure => |failure| (CommandSubstitutionBodyPayload{ .failure = failure }).validate(),
            .owned => |owned| owned.validate(),
        }
    }
};

pub const CommandSubstitutionResult = struct {
    allocator: std.mem.Allocator,
    status: outcome.ExitStatus,
    control_flow: outcome.ControlFlow = .normal,
    fatal_failure: ?TrapActionFailure = null,
    output: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    side_stdout: std.ArrayList(u8) = .empty,
    diagnostics: std.ArrayList(outcome.Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator, status: outcome.ExitStatus) CommandSubstitutionResult {
        const result: CommandSubstitutionResult = .{ .allocator = allocator, .status = status };
        result.validate();
        return result;
    }

    pub fn deinit(self: *CommandSubstitutionResult) void {
        if (self.fatal_failure) |failure| self.allocator.free(failure.message);
        self.output.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
        self.side_stdout.deinit(self.allocator);
        for (self.diagnostics.items) |diagnostic| self.allocator.free(diagnostic.message);
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn validate(self: CommandSubstitutionResult) void {
        self.control_flow.validate();
        std.debug.assert(self.control_flow == .normal);
        if (self.fatal_failure) |failure| {
            failure.validate();
            std.debug.assert(failure.fatal_noninteractive);
            std.debug.assert(self.status == failure.status);
        }
        if (self.output.items.len != 0) std.debug.assert(self.output.items[self.output.items.len - 1] != '\n');
    }
};

pub const CommandSubstitutionResolver = struct {
    context: ?*anyopaque = null,
    resolveFn: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?CommandSubstitutionBody = null,

    pub fn resolve(
        self: CommandSubstitutionResolver,
        allocator: std.mem.Allocator,
        script: []const u8,
    ) !?CommandSubstitutionBody {
        const resolve_fn = self.resolveFn orelse return null;
        const body = try resolve_fn(self.context, allocator, script);
        if (body) |resolved| resolved.validate();
        return body;
    }

    pub fn validate(self: CommandSubstitutionResolver) void {
        std.debug.assert(self.resolveFn != null);
    }
};

pub const CommandSubstitutionExpansionContext = struct {
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    resolver: CommandSubstitutionResolver,
    trap_resolver: ?TrapActionResolver = null,
    parent_frame: ?*execution_frame.ExecutionFrame = null,
    parent_input: ?*EvaluationInput = null,
    suppress_inherited_xtrace: bool = false,
    fatal_failure: ?TrapActionFailure = null,
    last_status: ?outcome.ExitStatus = null,
    last_control_flow: outcome.ControlFlow = .normal,
    max_depth_observed: u32 = 0,
    stderr: std.ArrayList(u8) = .empty,
    side_stdout: std.ArrayList(u8) = .empty,
    diagnostics: std.ArrayList(outcome.Diagnostic) = .empty,

    pub fn init(
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        eval_context: context.EvalContext,
        resolver: CommandSubstitutionResolver,
        trap_resolver: ?TrapActionResolver,
        parent_frame: ?*execution_frame.ExecutionFrame,
        parent_input: ?*EvaluationInput,
    ) CommandSubstitutionExpansionContext {
        shell_state.validate();
        eval_context.validate();
        resolver.validate();
        if (trap_resolver) |resolver_for_traps| resolver_for_traps.validate();
        if (parent_frame) |frame| frame.validate();
        if (parent_input) |input| input.validate();
        return .{
            .evaluator = evaluator,
            .shell_state = shell_state,
            .eval_context = eval_context,
            .resolver = resolver,
            .trap_resolver = trap_resolver,
            .parent_frame = parent_frame,
            .parent_input = parent_input,
        };
    }

    pub fn deinit(self: *CommandSubstitutionExpansionContext) void {
        if (self.fatal_failure) |failure| self.evaluator.allocator.free(failure.message);
        self.stderr.deinit(self.evaluator.allocator);
        self.side_stdout.deinit(self.evaluator.allocator);
        for (self.diagnostics.items) |diagnostic| self.evaluator.allocator.free(diagnostic.message);
        self.diagnostics.deinit(self.evaluator.allocator);
        self.* = undefined;
    }

    pub fn commandSubstitution(self: *CommandSubstitutionExpansionContext) expand.CommandSubstitution {
        self.validate();
        return .{ .context = self, .runFn = runSemanticCommandSubstitution };
    }

    fn recordFailure(self: *CommandSubstitutionExpansionContext, failure: TrapActionFailure) !void {
        failure.validate();
        if (self.fatal_failure != null) return;

        var owned = failure.fatalInNonInteractiveShell();
        owned.message = try self.evaluator.allocator.dupe(u8, failure.message);
        self.fatal_failure = owned;
        self.last_status = owned.status;
        self.last_control_flow = .{ .fatal = owned.status };
        self.validate();
    }

    pub fn validate(self: CommandSubstitutionExpansionContext) void {
        self.shell_state.validate();
        self.eval_context.validate();
        self.resolver.validate();
        if (self.trap_resolver) |resolver_for_traps| resolver_for_traps.validate();
        if (self.parent_frame) |frame| frame.validate();
        if (self.fatal_failure) |failure| {
            failure.validate();
            std.debug.assert(failure.fatal_noninteractive);
            std.debug.assert(self.last_status != null);
            std.debug.assert(self.last_status.? == failure.status);
            std.debug.assert(self.last_control_flow.status(0) == failure.status);
        }
        self.last_control_flow.validate();
        if (self.last_status == null) std.debug.assert(self.last_control_flow == .normal);
    }
};

const SimpleEvalResult = struct {
    status: outcome.ExitStatus,
    control_flow: outcome.ControlFlow = .normal,
};

const FunctionBodyEvalResult = union(enum) {
    result: SimpleEvalResult,
    tail_call: command_plan.CommandPlan,
    call_function: FunctionCursorCall,
};

const FunctionTailCallContext = struct {
    call_has_redirections: bool,
    definition_has_redirections: bool,
};

const FunctionCursorCall = struct {
    plan: command_plan.CommandPlan,
    eval_context: context.EvalContext,
    owns_plan: bool = false,

    fn validate(self: FunctionCursorCall) void {
        self.plan.validate();
        self.eval_context.validate();
        std.debug.assert(self.plan.class() == .function);
        std.debug.assert(self.plan.target == self.eval_context.target);
    }
};

const FunctionCursorFrame = union(enum) {
    list: FunctionStatementListCursor,
    if_clause: FunctionIfCursor,
    loop: FunctionLoopCursor,
};

const FunctionCursorStep = union(enum) {
    completed: SimpleEvalResult,
    tail_call: command_plan.CommandPlan,
    call_function: FunctionCursorCall,
};

const FunctionPendingCall = struct {
    state_disposition: StatementChildStateDisposition,
    statement_plan: ?command_plan.StatementPlan = null,

    fn validate(self: FunctionPendingCall) void {
        switch (self.state_disposition) {
            .commit_to_working => |target| std.debug.assert(target.allowsShellStateCommit()),
            .discard_except_status => {},
        }
        if (self.statement_plan) |plan| plan.validate();
    }
};

const FunctionPendingCompound = struct {
    body: command_plan.CompoundBody,
    tail_statement: bool,

    fn validate(self: FunctionPendingCompound) void {
        self.body.validate();
    }
};

const FunctionStatementListCursor = struct {
    list: command_plan.StatementList,
    eval_context: context.EvalContext,
    tail_position: bool,
    index: usize = 0,
    result: SimpleEvalResult = .{ .status = 0 },
    abort_bash_line: ?usize = null,
    pending_call: ?FunctionPendingCall = null,
    pending_compound: ?FunctionPendingCompound = null,

    fn init(
        list: command_plan.StatementList,
        eval_context: context.EvalContext,
        tail_position: bool,
    ) FunctionStatementListCursor {
        list.validate();
        eval_context.validate();
        return .{ .list = list, .eval_context = eval_context, .tail_position = tail_position };
    }

    fn validate(self: FunctionStatementListCursor) void {
        self.list.validate();
        self.eval_context.validate();
        self.result.control_flow.validate();
        std.debug.assert(self.index <= self.entryCount());
        if (self.abort_bash_line != null) std.debug.assert(self.list.statements.len != 0);
        if (self.pending_call) |pending| pending.validate();
        if (self.pending_compound) |pending| pending.validate();
        std.debug.assert(self.pending_call == null or self.pending_compound == null);
    }

    fn entryCount(self: FunctionStatementListCursor) usize {
        return if (self.list.commands.len != 0) self.list.commands.len else self.list.statements.len;
    }
};

const FunctionIfPhase = enum {
    condition,
    waiting_condition,
    body,
    waiting_body,
    done,
};

const FunctionIfCursor = struct {
    if_plan: command_plan.IfPlan,
    eval_context: context.EvalContext,
    tail_position: bool,
    branch_index: usize = 0,
    phase: FunctionIfPhase = .condition,
    stderr_before: usize = 0,
    diagnostics_before: usize = 0,
    completed_result: ?SimpleEvalResult = null,

    fn init(
        if_plan: command_plan.IfPlan,
        eval_context: context.EvalContext,
        tail_position: bool,
    ) FunctionIfCursor {
        if_plan.validate();
        eval_context.validate();
        return .{ .if_plan = if_plan, .eval_context = eval_context, .tail_position = tail_position };
    }

    fn validate(self: FunctionIfCursor) void {
        self.if_plan.validate();
        self.eval_context.validate();
        std.debug.assert(self.branch_index <= self.if_plan.branches.len);
        if (self.completed_result) |result| result.control_flow.validate();
    }
};

const FunctionLoopPhase = enum {
    condition,
    waiting_condition,
    body,
    waiting_body,
    done,
};

const FunctionLoopCursor = struct {
    loop: command_plan.LoopPlan,
    kind: LoopKind,
    eval_context: context.EvalContext,
    phase: FunctionLoopPhase = .condition,
    result: SimpleEvalResult = .{ .status = 0 },
    stderr_before: usize = 0,
    diagnostics_before: usize = 0,
    completed_result: ?SimpleEvalResult = null,

    fn init(
        loop: command_plan.LoopPlan,
        kind: LoopKind,
        eval_context: context.EvalContext,
    ) FunctionLoopCursor {
        loop.validate();
        std.debug.assert(loop.condition_source == null);
        std.debug.assert(loop.body_source == null);
        eval_context.validate();
        return .{ .loop = loop, .kind = kind, .eval_context = eval_context };
    }

    fn validate(self: FunctionLoopCursor) void {
        self.loop.validate();
        std.debug.assert(self.loop.condition_source == null);
        std.debug.assert(self.loop.body_source == null);
        self.eval_context.validate();
        self.result.control_flow.validate();
        if (self.completed_result) |result| result.control_flow.validate();
    }

    fn loopContext(self: FunctionLoopCursor) context.EvalContext {
        self.eval_context.validate();
        return self.eval_context.enterLoop();
    }

    fn complete(self: *FunctionLoopCursor, result: SimpleEvalResult) void {
        result.control_flow.validate();
        self.phase = .done;
        self.completed_result = result;
    }
};

const FunctionBodyCursor = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(FunctionCursorFrame) = .empty,
    tail_context: FunctionTailCallContext,

    fn init(
        allocator: std.mem.Allocator,
        list: command_plan.StatementList,
        eval_context: context.EvalContext,
        tail_context: FunctionTailCallContext,
    ) EvalError!FunctionBodyCursor {
        list.validate();
        eval_context.validate();
        var cursor: FunctionBodyCursor = .{ .allocator = allocator, .tail_context = tail_context };
        errdefer cursor.deinit();
        try cursor.frames.append(allocator, .{ .list = FunctionStatementListCursor.init(list, eval_context, true) });
        return cursor;
    }

    fn deinit(self: *FunctionBodyCursor) void {
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }

    fn step(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        buffers: *EvaluationBuffers,
    ) EvalError!FunctionCursorStep {
        shell_state.validate();
        while (true) {
            std.debug.assert(self.frames.items.len != 0);
            const frame_index = self.frames.items.len - 1;
            switch (self.frames.items[frame_index]) {
                .list => |*list_cursor| {
                    const step_result = try self.stepList(evaluator, shell_state, list_cursor, buffers);
                    switch (step_result) {
                        .completed => |simple_result| {
                            _ = self.frames.pop();
                            if (self.frames.items.len == 0) return .{ .completed = simple_result };
                            try self.deliverNestedResult(evaluator, shell_state, buffers, simple_result);
                            continue;
                        },
                        .tail_call, .call_function => return step_result,
                    }
                },
                .if_clause => |*if_cursor| {
                    const step_result = try self.stepIf(evaluator, shell_state, if_cursor, buffers);
                    switch (step_result) {
                        .completed => |simple_result| {
                            _ = self.frames.pop();
                            if (self.frames.items.len == 0) return .{ .completed = simple_result };
                            try self.deliverNestedResult(evaluator, shell_state, buffers, simple_result);
                            continue;
                        },
                        .tail_call, .call_function => return step_result,
                    }
                },
                .loop => |*loop_cursor| {
                    const step_result = try self.stepLoop(evaluator, shell_state, loop_cursor, buffers);
                    switch (step_result) {
                        .completed => |simple_result| {
                            _ = self.frames.pop();
                            if (self.frames.items.len == 0) return .{ .completed = simple_result };
                            try self.deliverNestedResult(evaluator, shell_state, buffers, simple_result);
                            continue;
                        },
                        .tail_call, .call_function => return step_result,
                    }
                },
            }
        }
    }

    fn completeCallOutcome(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        child_outcome: *outcome.CommandOutcome,
        buffers: *EvaluationBuffers,
    ) EvalError!void {
        std.debug.assert(self.frames.items.len != 0);
        switch (self.frames.items[self.frames.items.len - 1]) {
            .list => |*list_cursor| {
                const pending = list_cursor.pending_call orelse unreachable;
                pending.validate();
                var abort_bash_line_ptr: ?*?usize = null;
                if (pending.statement_plan != null) abort_bash_line_ptr = &list_cursor.abort_bash_line;
                const completion = try completeStatementChildOutcome(
                    evaluator,
                    shell_state,
                    list_cursor.eval_context,
                    child_outcome,
                    pending.state_disposition,
                    pending.statement_plan,
                    abort_bash_line_ptr,
                    &list_cursor.result,
                    buffers,
                );
                list_cursor.pending_call = null;
                if (completion.stop_list) {
                    list_cursor.index = list_cursor.entryCount();
                } else {
                    list_cursor.index += 1;
                }
                list_cursor.validate();
            },
            .if_clause, .loop => unreachable,
        }
    }

    fn stepList(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        list_cursor: *FunctionStatementListCursor,
        buffers: *EvaluationBuffers,
    ) EvalError!FunctionCursorStep {
        list_cursor.validate();
        std.debug.assert(list_cursor.pending_call == null);
        std.debug.assert(list_cursor.pending_compound == null);

        if (list_cursor.list.commands.len != 0) {
            while (list_cursor.index < list_cursor.list.commands.len) {
                const child_plan = list_cursor.list.commands[list_cursor.index];
                child_plan.validate();
                try flushBuffersForRedirectionTargetsBetweenCommands(
                    buffers,
                    list_cursor.eval_context,
                    child_plan.redirections,
                    evaluator.external_stdio,
                );
                const is_tail_child = list_cursor.tail_position and
                    list_cursor.index + 1 == list_cursor.list.commands.len;
                if (is_tail_child) {
                    if (try ownedTailFunctionCallPlan(
                        evaluator,
                        shell_state.*,
                        list_cursor.eval_context,
                        child_plan,
                        self.tail_context,
                        buffers,
                    )) |tail_plan| return .{ .tail_call = tail_plan };
                }
                if (functionCursorCanSuspendSimpleCall(child_plan)) {
                    list_cursor.pending_call = .{ .state_disposition = .{ .commit_to_working = child_plan.target } };
                    return .{ .call_function = .{
                        .plan = child_plan,
                        .eval_context = list_cursor.eval_context.withTarget(child_plan.target),
                    } };
                }

                var child_outcome = try evaluatePlanWithInput(
                    evaluator,
                    shell_state,
                    list_cursor.eval_context.withTarget(child_plan.target),
                    child_plan,
                    buffers.stdin,
                    buffers.frame,
                );
                defer child_outcome.deinit();
                const completion = try completeStatementChildOutcome(
                    evaluator,
                    shell_state,
                    list_cursor.eval_context,
                    &child_outcome,
                    .{ .commit_to_working = child_plan.target },
                    null,
                    null,
                    &list_cursor.result,
                    buffers,
                );
                list_cursor.index += 1;
                if (completion.stop_list) break;
            }
            list_cursor.index = list_cursor.entryCount();
            return .{ .completed = list_cursor.result };
        }

        while (list_cursor.index < list_cursor.list.statements.len) {
            const entry = list_cursor.list.statements[list_cursor.index];
            entry.validate(list_cursor.index);
            if (list_cursor.abort_bash_line) |line| {
                if (statementSourceLine(entry.plan) == line) {
                    list_cursor.index += 1;
                    continue;
                }
                list_cursor.abort_bash_line = null;
            }
            const should_run = switch (entry.op_before) {
                .sequence => true,
                .and_if => list_cursor.result.status == 0,
                .or_if => list_cursor.result.status != 0,
            };
            if (!should_run) {
                list_cursor.index += 1;
                continue;
            }

            var child_context = list_cursor.eval_context;
            if (list_cursor.index + 1 < list_cursor.list.statements.len) {
                switch (list_cursor.list.statements[list_cursor.index + 1].op_before) {
                    .sequence => {},
                    .and_if, .or_if => child_context = child_context.ignoreErrexit(),
                }
            }

            try flushBuffersForStatementRedirections(
                buffers,
                child_context,
                entry.plan,
                evaluator.external_stdio,
                evaluator.io != null,
            );
            const is_tail_child = list_cursor.tail_position and
                list_cursor.index + 1 == list_cursor.list.statements.len;
            if (is_tail_child) {
                switch (entry.plan) {
                    .simple => |simple| if (try ownedTailFunctionCallPlan(
                        evaluator,
                        shell_state.*,
                        child_context,
                        simple,
                        self.tail_context,
                        buffers,
                    )) |tail_plan| return .{ .tail_call = tail_plan },
                    .compound => |compound| if (functionCursorCanEnterCompound(shell_state.*, compound, true)) {
                        list_cursor.pending_compound = .{ .body = compound.body, .tail_statement = true };
                        try self.pushCompound(compound.body, child_context, true);
                        return self.step(evaluator, shell_state, buffers);
                    },
                    .source, .ir_source, .pipeline => {},
                }
            }

            switch (entry.plan) {
                .simple => |simple| if (functionCursorCanSuspendSimpleCall(simple)) {
                    const state_disposition: StatementChildStateDisposition = .{ .commit_to_working = simple.target };
                    list_cursor.pending_call = .{
                        .state_disposition = state_disposition,
                        .statement_plan = entry.plan,
                    };
                    return .{ .call_function = .{
                        .plan = simple,
                        .eval_context = child_context.withTarget(simple.target),
                    } };
                },
                .compound => |compound| if (functionCursorCanEnterCompound(shell_state.*, compound, false)) {
                    list_cursor.pending_compound = .{ .body = compound.body, .tail_statement = false };
                    try self.pushCompound(compound.body, child_context, false);
                    return self.step(evaluator, shell_state, buffers);
                },
                .source => |source| if (try ownedFunctionCallFromSourceForCursor(
                    evaluator,
                    shell_state,
                    child_context,
                    source,
                )) |owned_plan| {
                    list_cursor.pending_call = .{
                        .state_disposition = .{ .commit_to_working = owned_plan.target },
                        .statement_plan = entry.plan,
                    };
                    return .{ .call_function = .{
                        .plan = owned_plan,
                        .eval_context = child_context.withTarget(owned_plan.target),
                        .owns_plan = true,
                    } };
                },
                .ir_source => |source| if (try ownedFunctionCallFromIrSourceForCursor(
                    evaluator,
                    shell_state,
                    child_context,
                    source,
                )) |owned_plan| {
                    list_cursor.pending_call = .{
                        .state_disposition = .{ .commit_to_working = owned_plan.target },
                        .statement_plan = entry.plan,
                    };
                    return .{ .call_function = .{
                        .plan = owned_plan,
                        .eval_context = child_context.withTarget(owned_plan.target),
                        .owns_plan = true,
                    } };
                },
                .pipeline => {},
            }

            var child_outcome = try evaluateStatementPlan(
                evaluator,
                shell_state,
                child_context,
                entry.plan,
                buffers.stdin,
                buffers.frame,
            );
            defer child_outcome.deinit();

            const state_disposition: StatementChildStateDisposition = if (statementPlanCommitsStateToParent(entry.plan))
                .{ .commit_to_working = child_outcome.state_delta.target }
            else
                .discard_except_status;
            const completion = try completeStatementChildOutcome(
                evaluator,
                shell_state,
                list_cursor.eval_context,
                &child_outcome,
                state_disposition,
                entry.plan,
                &list_cursor.abort_bash_line,
                &list_cursor.result,
                buffers,
            );
            list_cursor.index += 1;
            if (completion.stop_list) break;
        }
        list_cursor.index = list_cursor.entryCount();
        return .{ .completed = list_cursor.result };
    }

    fn stepIf(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        if_cursor: *FunctionIfCursor,
        buffers: *EvaluationBuffers,
    ) EvalError!FunctionCursorStep {
        if_cursor.validate();
        switch (if_cursor.phase) {
            .condition => {
                if (if_cursor.branch_index < if_cursor.if_plan.branches.len) {
                    const branch = if_cursor.if_plan.branches[if_cursor.branch_index];
                    if_cursor.stderr_before = buffers.stderr.items.len;
                    if_cursor.diagnostics_before = buffers.diagnostics.items.len;
                    if_cursor.phase = .waiting_condition;
                    try self.frames.append(
                        self.allocator,
                        .{ .list = FunctionStatementListCursor.init(
                            branch.condition,
                            if_cursor.eval_context.ignoreErrexit(),
                            false,
                        ) },
                    );
                    return self.step(evaluator, shell_state, buffers);
                }
                if_cursor.phase = .waiting_body;
                try self.frames.append(
                    self.allocator,
                    .{ .list = FunctionStatementListCursor.init(
                        if_cursor.if_plan.else_body,
                        if_cursor.eval_context,
                        if_cursor.tail_position,
                    ) },
                );
                return self.step(evaluator, shell_state, buffers);
            },
            .body => {
                const branch = if_cursor.if_plan.branches[if_cursor.branch_index];
                if_cursor.phase = .waiting_body;
                try self.frames.append(
                    self.allocator,
                    .{ .list = FunctionStatementListCursor.init(
                        branch.body,
                        if_cursor.eval_context,
                        if_cursor.tail_position,
                    ) },
                );
                return self.step(evaluator, shell_state, buffers);
            },
            .waiting_condition, .waiting_body => unreachable,
            .done => return .{ .completed = if_cursor.completed_result.? },
        }
    }

    fn stepLoop(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        loop_cursor: *FunctionLoopCursor,
        buffers: *EvaluationBuffers,
    ) EvalError!FunctionCursorStep {
        loop_cursor.validate();
        const loop_context = loop_cursor.loopContext();
        switch (loop_cursor.phase) {
            .condition => {
                loop_cursor.stderr_before = buffers.stderr.items.len;
                loop_cursor.diagnostics_before = buffers.diagnostics.items.len;
                loop_cursor.phase = .waiting_condition;
                try self.frames.append(
                    self.allocator,
                    .{ .list = FunctionStatementListCursor.init(
                        loop_cursor.loop.condition,
                        loop_context.ignoreErrexit(),
                        false,
                    ) },
                );
                return self.step(evaluator, shell_state, buffers);
            },
            .body => {
                loop_cursor.phase = .waiting_body;
                try self.frames.append(
                    self.allocator,
                    .{ .list = FunctionStatementListCursor.init(loop_cursor.loop.body, loop_context, false) },
                );
                return self.step(evaluator, shell_state, buffers);
            },
            .waiting_condition, .waiting_body => unreachable,
            .done => return .{ .completed = loop_cursor.completed_result.? },
        }
    }

    fn pushCompound(
        self: *FunctionBodyCursor,
        body: command_plan.CompoundBody,
        eval_context: context.EvalContext,
        tail_position: bool,
    ) EvalError!void {
        body.validate();
        switch (body) {
            .sequence, .brace_group => |list| try self.frames.append(
                self.allocator,
                .{ .list = FunctionStatementListCursor.init(list, eval_context, tail_position) },
            ),
            .if_clause => |if_plan| try self.frames.append(
                self.allocator,
                .{ .if_clause = FunctionIfCursor.init(if_plan, eval_context, tail_position) },
            ),
            .while_loop => |loop| try self.frames.append(
                self.allocator,
                .{ .loop = FunctionLoopCursor.init(loop, .while_loop, eval_context) },
            ),
            .until_loop => |loop| try self.frames.append(
                self.allocator,
                .{ .loop = FunctionLoopCursor.init(loop, .until_loop, eval_context) },
            ),
            .and_or_list,
            .negation,
            .subshell,
            .for_loop,
            .case_clause,
            => unreachable,
        }
    }

    fn deliverNestedResult(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        buffers: *EvaluationBuffers,
        nested_result: SimpleEvalResult,
    ) EvalError!void {
        std.debug.assert(self.frames.items.len != 0);
        switch (self.frames.items[self.frames.items.len - 1]) {
            .list => |*list_cursor| try self.deliverCompoundResult(
                evaluator,
                shell_state,
                buffers,
                list_cursor,
                nested_result,
            ),
            .if_clause => |*if_cursor| try self.deliverIfResult(buffers, if_cursor, nested_result),
            .loop => |*loop_cursor| try self.deliverLoopResult(
                evaluator,
                buffers,
                loop_cursor,
                nested_result,
            ),
        }
    }

    fn deliverCompoundResult(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        shell_state: *state.ShellState,
        buffers: *EvaluationBuffers,
        list_cursor: *FunctionStatementListCursor,
        nested_result: SimpleEvalResult,
    ) EvalError!void {
        _ = self;
        const pending = list_cursor.pending_compound orelse unreachable;
        pending.validate();
        var child_result = nested_result;
        if (pending.tail_statement) {
            const tail_control_flow = child_result.control_flow;
            list_cursor.result = child_result;
            if (try runCurrentShellRuntimeTrapBoundary(
                evaluator,
                shell_state,
                list_cursor.eval_context,
                buffers,
            )) |trap_result| {
                if (trap_result.control_flow != .normal) {
                    list_cursor.result = trap_result;
                } else if (tail_control_flow == .normal) {
                    list_cursor.result = trap_result;
                }
            }
            try flushCurrentShellBufferedCommandOutput(
                buffers,
                list_cursor.eval_context,
                evaluator.external_stdio,
                evaluator.io != null,
            );
            list_cursor.index = list_cursor.entryCount();
            list_cursor.pending_compound = null;
            return;
        }

        if (!compoundBodySuppressesFinalErrexit(pending.body)) {
            const decision = consequence.decideForCompoundCommand(
                shell_state.options,
                list_cursor.eval_context,
                child_result.status,
                child_result.control_flow,
            );
            child_result.control_flow = decision.control_flow;
        }
        const completion = try completeStatementChildResult(
            evaluator,
            shell_state,
            list_cursor.eval_context,
            child_result,
            &list_cursor.result,
            buffers,
        );
        list_cursor.pending_compound = null;
        if (completion.stop_list) {
            list_cursor.index = list_cursor.entryCount();
        } else {
            list_cursor.index += 1;
        }
        list_cursor.validate();
    }

    fn deliverIfResult(
        self: *FunctionBodyCursor,
        buffers: *EvaluationBuffers,
        if_cursor: *FunctionIfCursor,
        nested_result: SimpleEvalResult,
    ) EvalError!void {
        _ = self;
        nested_result.control_flow.validate();
        switch (if_cursor.phase) {
            .waiting_condition => {
                if (nested_result.control_flow != .normal or bashAssignmentErrorBuffersAbortSourceLine(
                    if_cursor.eval_context,
                    buffers.*,
                    if_cursor.stderr_before,
                    if_cursor.diagnostics_before,
                    nested_result,
                )) {
                    if_cursor.phase = .done;
                    if_cursor.branch_index = if_cursor.if_plan.branches.len;
                    if_cursor.completed_result = nested_result;
                    return;
                }
                if (nested_result.status == 0) {
                    if_cursor.phase = .body;
                } else {
                    if_cursor.branch_index += 1;
                    if_cursor.phase = .condition;
                }
            },
            .waiting_body => {
                if_cursor.phase = .done;
                if_cursor.branch_index = if_cursor.if_plan.branches.len;
                if_cursor.completed_result = nested_result;
            },
            .condition, .body, .done => unreachable,
        }
    }

    fn deliverLoopResult(
        self: *FunctionBodyCursor,
        evaluator: *Evaluator,
        buffers: *EvaluationBuffers,
        loop_cursor: *FunctionLoopCursor,
        nested_result: SimpleEvalResult,
    ) EvalError!void {
        _ = self;
        nested_result.control_flow.validate();
        switch (loop_cursor.phase) {
            .waiting_condition => {
                if (nested_result.control_flow != .normal) {
                    switch (consumeLoopControl(nested_result.control_flow)) {
                        .stop => loop_cursor.complete(normalEvaluation(0)),
                        .repeat => loop_cursor.phase = .condition,
                        .propagate => |flow| loop_cursor.complete(.{
                            .status = flow.status(nested_result.status),
                            .control_flow = flow,
                        }),
                        .other => loop_cursor.complete(nested_result),
                    }
                    return;
                }
                if (bashAssignmentErrorBuffersAbortSourceLine(
                    loop_cursor.eval_context,
                    buffers.*,
                    loop_cursor.stderr_before,
                    loop_cursor.diagnostics_before,
                    nested_result,
                )) {
                    loop_cursor.complete(nested_result);
                    return;
                }

                const should_run = switch (loop_cursor.kind) {
                    .while_loop => nested_result.status == 0,
                    .until_loop => nested_result.status != 0,
                };
                loop_cursor.phase = if (should_run) .body else .done;
                if (!should_run) loop_cursor.completed_result = loop_cursor.result;
            },
            .waiting_body => {
                try flushCurrentShellBufferedCommandOutput(
                    buffers,
                    loop_cursor.eval_context,
                    evaluator.external_stdio,
                    evaluator.io != null,
                );
                switch (consumeLoopControl(nested_result.control_flow)) {
                    .stop => loop_cursor.complete(normalEvaluation(0)),
                    .repeat => {
                        loop_cursor.result = normalEvaluation(nested_result.status);
                        loop_cursor.phase = .condition;
                    },
                    .propagate => |flow| loop_cursor.complete(.{
                        .status = flow.status(nested_result.status),
                        .control_flow = flow,
                    }),
                    .other => {
                        if (nested_result.control_flow != .normal) {
                            loop_cursor.complete(nested_result);
                        } else {
                            loop_cursor.result = normalEvaluation(nested_result.status);
                            loop_cursor.phase = .condition;
                        }
                    },
                }
            },
            .condition, .body, .done => unreachable,
        }
        loop_cursor.validate();
    }
};

fn functionCursorCanSuspendSimpleCall(plan: command_plan.CommandPlan) bool {
    plan.validate();
    return plan.class() == .function and plan.target.allowsShellStateCommit();
}

fn ownedFunctionCallFromSourceForCursor(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source_plan: command_plan.SourceStatementPlan,
) EvalError!?command_plan.CommandPlan {
    source_plan.validate();
    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = source_plan.expand_aliases and shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.source_line_offset = source_plan.line;
    var body = (parser_resolver.lowerSource(
        evaluator.allocator,
        source_plan.source,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    }) orelse return null;
    defer body.deinit();
    return ownedFunctionCallFromTrapActionBodyForCursor(evaluator.allocator, body);
}

fn ownedFunctionCallFromIrSourceForCursor(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source_plan: command_plan.IrStatementPlan,
) EvalError!?command_plan.CommandPlan {
    source_plan.validate();
    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = source_plan.expand_aliases and shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.source_line_offset = source_plan.line -| sourceLineIndex(
        source_plan.program.source,
        source_plan.program.statements[source_plan.statement_index].span.start,
    );
    var body = (parser_resolver.lowerProgramStatement(
        evaluator.allocator,
        source_plan.program.*,
        source_plan.statement_index,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    });
    defer body.deinit();
    return ownedFunctionCallFromTrapActionBodyForCursor(evaluator.allocator, body);
}

fn ownedFunctionCallFromTrapActionBodyForCursor(
    allocator: std.mem.Allocator,
    body: TrapActionBody,
) EvalError!?command_plan.CommandPlan {
    body.validate();
    const plan: command_plan.CommandPlan = switch (body) {
        .simple => |simple| simple,
        .owned => |owned| switch (owned.body) {
            .simple => |simple| simple,
            .compound, .pipeline, .failure => return null,
        },
        .compound, .pipeline, .failure => return null,
    };
    if (!functionCursorCanSuspendSimpleCall(plan)) return null;
    return command_plan.cloneCommandPlan(allocator, plan) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn functionCursorCanEnterCompound(
    shell_state: state.ShellState,
    plan: command_plan.CompoundCommandPlan,
    _: bool,
) bool {
    shell_state.validate();
    plan.validate();
    if (plan.target != .current_shell) return false;
    if (plan.redirections.steps.len != 0) return false;
    if (shell_state.options.enabled(.errexit)) return false;
    return switch (plan.body) {
        .sequence, .brace_group, .if_clause => true,
        .while_loop, .until_loop => |loop| loop.condition_source == null and loop.body_source == null,
        .and_or_list,
        .negation,
        .subshell,
        .for_loop,
        .case_clause,
        => false,
    };
}

const FunctionCallFrame = struct {
    allocator: std.mem.Allocator,
    caller_context: context.EvalContext,
    function_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    definition: command_plan.FunctionDefinition,
    owns_plan: bool,
    function_frame: *FunctionFrame,
    call_redirections: RedirectionGuard = RedirectionGuard.empty(.current_scoped),
    definition_redirections: RedirectionGuard = RedirectionGuard.empty(.current_scoped),
    body_lowering: ?TrapActionBody = null,
    body_lowering_arena: ?*std.heap.ArenaAllocator = null,
    body_cursor: ?FunctionBodyCursor = null,

    fn init(
        allocator: std.mem.Allocator,
        caller_context: context.EvalContext,
        plan: command_plan.CommandPlan,
        owns_plan: bool,
    ) EvalError!FunctionCallFrame {
        caller_context.validate();
        plan.validate();
        const function_context = caller_context.enterFunction();
        const definition = functionDefinitionFromCallPlan(plan);
        validateFunctionCall(plan, definition);

        const function_frame = try allocator.create(FunctionFrame);
        errdefer allocator.destroy(function_frame);
        function_frame.* = FunctionFrame.init(
            allocator,
            function_context.function_depth,
            plan.assignments,
        );

        return .{
            .allocator = allocator,
            .caller_context = caller_context,
            .function_context = function_context,
            .plan = plan,
            .definition = definition,
            .owns_plan = owns_plan,
            .function_frame = function_frame,
        };
    }

    fn deinit(self: *FunctionCallFrame) void {
        if (self.body_cursor) |*cursor| {
            cursor.deinit();
            self.body_cursor = null;
        }
        if (self.body_lowering) |*body| {
            body.deinit();
            self.body_lowering = null;
        }
        if (self.body_lowering_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
            self.body_lowering_arena = null;
        }
        self.function_frame.deinit();
        self.allocator.destroy(self.function_frame);
        self.definition_redirections.restore();
        self.call_redirections.restore();
        if (self.owns_plan) command_plan.freeCommandPlan(self.allocator, self.plan);
        self.* = undefined;
    }

    fn bodyArenaAllocator(self: *FunctionCallFrame) EvalError!std.mem.Allocator {
        std.debug.assert(self.body_lowering_arena == null);
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        self.body_lowering_arena = arena;
        return arena.allocator();
    }

    fn storeBodyLowering(self: *FunctionCallFrame, body: TrapActionBody) void {
        body.validate();
        std.debug.assert(self.body_lowering == null);
        self.body_lowering = body;
    }

    fn bodyLowering(self: FunctionCallFrame) TrapActionBody {
        const body = self.body_lowering.?;
        body.validate();
        return body;
    }

    fn tailContext(self: FunctionCallFrame) FunctionTailCallContext {
        return functionTailCallContext(self.plan, self.definition);
    }

    fn hasRedirections(self: FunctionCallFrame) bool {
        return self.call_redirections.hasTransaction() or self.definition_redirections.hasTransaction();
    }

    fn validate(self: FunctionCallFrame) void {
        self.caller_context.validate();
        self.function_context.validate();
        std.debug.assert(self.function_context.canReturnFromFunction());
        validateFunctionCall(self.plan, self.definition);
        self.function_frame.validate();
        std.debug.assert(self.function_frame.depth == self.function_context.function_depth);
        if (self.function_frame.assignment_prefixes.len != 0) {
            std.debug.assert(self.function_frame.assignment_prefixes.ptr == self.plan.assignments.ptr);
        }
    }
};

const FunctionFrame = struct {
    allocator: std.mem.Allocator,
    depth: u32,
    assignment_prefixes: []const command_plan.Assignment,
    local_names: std.ArrayList([]const u8) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        depth: u32,
        assignment_prefixes: []const command_plan.Assignment,
    ) FunctionFrame {
        std.debug.assert(depth != 0);
        for (assignment_prefixes) |assignment| assignment.validate();
        return .{ .allocator = allocator, .depth = depth, .assignment_prefixes = assignment_prefixes };
    }

    fn deinit(self: *FunctionFrame) void {
        for (self.local_names.items) |name| self.allocator.free(name);
        self.local_names.deinit(self.allocator);
        self.* = undefined;
    }

    fn addLocal(self: *FunctionFrame, name: []const u8) !void {
        state.assertValidVariableName(name);
        if (self.excludesVariable(name)) return;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.local_names.append(self.allocator, owned_name);
    }

    fn excludesVariable(self: FunctionFrame, name: []const u8) bool {
        state.assertValidVariableName(name);
        for (self.assignment_prefixes) |assignment| {
            if (std.mem.eql(u8, assignment.name, name)) return true;
        }
        for (self.local_names.items) |local_name| {
            if (std.mem.eql(u8, local_name, name)) return true;
        }
        return false;
    }

    fn validate(self: FunctionFrame) void {
        std.debug.assert(self.depth != 0);
        for (self.assignment_prefixes) |assignment| assignment.validate();
        for (self.local_names.items) |name| state.assertValidVariableName(name);
    }
};

pub const EvaluationInput = struct {
    bytes: []const u8 = &.{},
    cursor: usize = 0,
    redirected: bool = false,
    /// Allows `read` to honor an explicit fd-0 redirection without letting hidden
    /// helpers fall back to the terminal when no redirection exists.
    fd_redirected: bool = false,

    pub fn empty() EvaluationInput {
        return .{};
    }

    pub fn init(bytes: []const u8) EvaluationInput {
        return initWithRedirected(bytes, false);
    }

    fn initWithRedirected(bytes: []const u8, redirected: bool) EvaluationInput {
        const input: EvaluationInput = .{ .bytes = bytes, .redirected = redirected };
        input.validate();
        return input;
    }

    fn fdRedirected() EvaluationInput {
        const input: EvaluationInput = .{ .fd_redirected = true };
        input.validate();
        return input;
    }

    pub fn validate(self: EvaluationInput) void {
        std.debug.assert(self.cursor <= self.bytes.len);
        std.debug.assert(!self.redirected or !self.fd_redirected);
    }

    fn remaining(self: EvaluationInput) []const u8 {
        self.validate();
        return self.bytes[self.cursor..];
    }

    fn takeRemaining(self: *EvaluationInput) []const u8 {
        self.validate();
        const bytes = self.remaining();
        self.cursor = self.bytes.len;
        self.validate();
        return bytes;
    }

    fn readUntil(self: *EvaluationInput, delimiter: u8) ?[]const u8 {
        return if (self.readUntilStatus(delimiter)) |result| result.bytes else null;
    }

    const ReadUntilResult = struct {
        bytes: []const u8,
        delimiter_found: bool,
    };

    fn readUntilStatus(self: *EvaluationInput, delimiter: u8) ?ReadUntilResult {
        self.validate();
        if (self.cursor == self.bytes.len) return null;
        const start = self.cursor;
        while (self.cursor < self.bytes.len and self.bytes[self.cursor] != delimiter) self.cursor += 1;
        const end = self.cursor;
        const delimiter_found = self.cursor < self.bytes.len and self.bytes[self.cursor] == delimiter;
        if (delimiter_found) self.cursor += 1;
        self.validate();
        return .{ .bytes = self.bytes[start..end], .delimiter_found = delimiter_found };
    }
};

const EvaluationBuffers = struct {
    allocator: std.mem.Allocator,
    stdin: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
    propagated_failure: ?outcome.PropagatedFailure = null,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    side_stdout: std.ArrayList(u8) = .empty,
    command_substitution_side_stdout: std.ArrayList(u8) = .empty,
    pipeline_stdout: std.ArrayList(u8) = .empty,
    diagnostics: std.ArrayList([]const u8) = .empty,
    preserve_parent_visible_stdout_capture: bool = false,
    fold_side_stdout_to_stdout: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        stdin: *EvaluationInput,
        frame: *execution_frame.ExecutionFrame,
    ) EvaluationBuffers {
        stdin.validate();
        frame.validate();
        return .{
            .allocator = allocator,
            .stdin = stdin,
            .frame = frame,
        };
    }

    fn deinit(self: *EvaluationBuffers) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
        self.side_stdout.deinit(self.allocator);
        self.command_substitution_side_stdout.deinit(self.allocator);
        self.pipeline_stdout.deinit(self.allocator);
        for (self.diagnostics.items) |message| self.allocator.free(message);
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    fn outputFrame(self: *EvaluationBuffers) !OutputFrame {
        self.frame.validate();
        var routing = try OutputRouting.initForFrame(
            self.allocator,
            self.frame.*,
            self.preserve_parent_visible_stdout_capture,
        );
        errdefer routing.deinit();
        return OutputFrame.initOwnedRouting(self, routing);
    }

    fn useFrameFdTableInput(
        self: *EvaluationBuffers,
        frame_input: *EvaluationInput,
        inherited_input: *EvaluationInput,
    ) void {
        self.frame.validate();
        frame_input.validate();
        inherited_input.validate();
        switch (self.frame.spec.fd_table.endpoint(0)) {
            .input => |endpoint| switch (endpoint) {
                .bytes => |bytes| {
                    if (std.mem.eql(u8, bytes, inherited_input.bytes)) {
                        self.stdin = inherited_input;
                    } else {
                        frame_input.* = EvaluationInput.initWithRedirected(bytes, true);
                        self.stdin = frame_input;
                    }
                },
                .inherit_stdin => self.stdin = inherited_input,
                .path, .fd, .pipe_read => {
                    frame_input.* = EvaluationInput.fdRedirected();
                    self.stdin = frame_input;
                },
                .closed => self.stdin = frame_input,
            },
            .closed => self.stdin = frame_input,
            .output => self.stdin = inherited_input,
        }
        self.stdin.validate();
    }

    fn addBuiltinDiagnostic(self: *EvaluationBuffers, command: []const u8, message: []const u8) !void {
        std.debug.assert(command.len != 0);
        std.debug.assert(message.len != 0);

        var frame = try self.outputFrame();
        defer frame.deinit();
        try frame.addBuiltinDiagnostic(command, message);
    }

    fn addDiagnosticMessage(self: *EvaluationBuffers, message: []const u8) !void {
        std.debug.assert(message.len != 0);
        var frame = try self.outputFrame();
        defer frame.deinit();
        try frame.diagnosticStore().append(message);
    }

    fn appendToDestination(
        self: *EvaluationBuffers,
        destination: OutputDestination,
        bytes: []const u8,
    ) EvalError!void {
        destination.validate();
        if (bytes.len == 0) return;
        switch (destination) {
            .outcome_stdout_capture,
            .command_substitution_stdout_capture,
            => try self.stdout.appendSlice(self.allocator, bytes),
            .side_stdout_capture => try self.side_stdout.appendSlice(self.allocator, bytes),
            .command_substitution_side_stdout_capture => try self.command_substitution_side_stdout.appendSlice(
                self.allocator,
                bytes,
            ),
            .pipeline_data_capture => try self.pipeline_stdout.appendSlice(self.allocator, bytes),
            .outcome_stderr_capture,
            .command_substitution_stderr_capture,
            => try self.stderr.appendSlice(self.allocator, bytes),
            .host_descriptor => |descriptor| {
                if (!writeAllDescriptor(descriptor, bytes)) return error.Unimplemented;
            },
            .closed => {},
        }
    }

    fn flushStreamToDestination(
        self: *EvaluationBuffers,
        stream: OutputStream,
        destination: OutputDestination,
    ) EvalError!void {
        destination.validate();
        const bytes = switch (stream) {
            .stdout => self.stdout.items,
            .stderr => self.stderr.items,
        };
        if (bytes.len == 0) return;

        switch (destination) {
            .command_substitution_stdout_capture => if (stream == .stderr) {
                try self.stdout.appendSlice(self.allocator, bytes);
                self.clearStream(stream);
            },
            .command_substitution_stderr_capture => if (stream == .stdout) {
                try self.stderr.insertSlice(self.allocator, 0, bytes);
                self.clearStream(stream);
            },
            .side_stdout_capture,
            .command_substitution_side_stdout_capture,
            .pipeline_data_capture,
            .host_descriptor,
            .closed,
            => {
                try self.appendToDestination(destination, bytes);
                self.clearStream(stream);
            },
            .outcome_stdout_capture, .outcome_stderr_capture => {},
        }
    }

    fn flushStandardToDestinations(
        self: *EvaluationBuffers,
        stdout_destination: OutputDestination,
        stderr_destination: OutputDestination,
    ) EvalError!void {
        stdout_destination.validate();
        stderr_destination.validate();
        if (self.stdout.items.len == 0 and self.stderr.items.len == 0) return;

        var stdout = self.stdout;
        var stderr = self.stderr;
        self.stdout = .empty;
        self.stderr = .empty;
        defer stdout.deinit(self.allocator);
        defer stderr.deinit(self.allocator);

        try self.appendToDestination(stdout_destination, stdout.items);
        try self.appendToDestination(stderr_destination, stderr.items);
    }

    fn clearStream(self: *EvaluationBuffers, stream: OutputStream) void {
        switch (stream) {
            .stdout => self.stdout.items.len = 0,
            .stderr => self.stderr.items.len = 0,
        }
    }

    fn appendPropagatedFailure(self: *EvaluationBuffers, command_outcome: outcome.CommandOutcome) void {
        command_outcome.validate();
        if (command_outcome.propagated_failure) |failure| {
            if (self.propagated_failure == null) self.propagated_failure = failure;
        }
    }

    fn appendDiagnosticsFromOutcome(self: *EvaluationBuffers, command_outcome: outcome.CommandOutcome) !void {
        command_outcome.validate();
        for (command_outcome.diagnostics.items) |diagnostic| {
            try self.addDiagnosticMessage(diagnostic.message);
        }
    }

    fn appendCommandSubstitutionSideOutput(self: *EvaluationBuffers, command_outcome: outcome.CommandOutcome) !void {
        command_outcome.validate();
        try self.command_substitution_side_stdout.appendSlice(
            self.allocator,
            command_outcome.command_substitution_side_stdout.items,
        );
    }

    fn appendSideOutput(self: *EvaluationBuffers, command_outcome: outcome.CommandOutcome) !void {
        command_outcome.validate();
        try self.side_stdout.appendSlice(self.allocator, command_outcome.side_stdout.items);
    }

    fn appendPipelineOutput(self: *EvaluationBuffers, command_outcome: outcome.CommandOutcome) !void {
        command_outcome.validate();
        try self.pipeline_stdout.appendSlice(self.allocator, command_outcome.pipeline_stdout.items);
    }
};

fn frameStandardDescriptorsAreDefault(frame: execution_frame.ExecutionFrame) bool {
    frame.validate();
    return std.meta.eql(frame.spec.fd_table.endpoint(1), @as(
        execution_frame.FdEndpoint,
        .{ .output = frame.spec.stdout },
    )) and std.meta.eql(frame.spec.fd_table.endpoint(2), @as(
        execution_frame.FdEndpoint,
        .{ .output = frame.spec.stderr },
    ));
}

const CwdGuard = struct {
    fs_port: ?runtime.fs.Port = null,
    buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path: []const u8 = &.{},

    fn capture(self: *CwdGuard, evaluator: *Evaluator) void {
        std.debug.assert(self.fs_port == null);
        const fs_port = evaluator.fs_port orelse return;
        const cwd = fs_port.getCwd(runtime.fs.GetCwdRequest.init(&self.buffer)) catch return;
        self.fs_port = fs_port;
        self.path = cwd.path;
    }

    fn restore(self: *CwdGuard) void {
        const fs_port = self.fs_port orelse return;
        // ziglint-ignore: Z026 best-effort cwd restoration while unwinding isolated shell evaluation
        fs_port.changeCwd(runtime.fs.ChangeCwdRequest.init(self.path)) catch {};
        self.* = .{};
    }
};

pub fn evaluatePlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
) EvalError!outcome.CommandOutcome {
    var input = EvaluationInput.empty();
    var frame = rootExecutionFrame(eval_context);
    return evaluatePlanWithInput(evaluator, shell_state, eval_context, plan, &input, &frame);
}

pub fn evaluatePlanInFrame(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    return evaluatePlanWithInput(evaluator, shell_state, eval_context, plan, input, frame);
}

fn evaluatePlanWithInput(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    input.validate();
    frame.validate();
    std.debug.assert(plan.target == eval_context.target);
    if (plan.target.allowsShellStateCommit()) std.debug.assert(shell_state.acceptsExecutionTarget(plan.target));

    var effective_plan = plan;
    var filtered_assignments: ?[]command_plan.Assignment = null;
    defer if (filtered_assignments) |assignments| evaluator.allocator.free(assignments);
    const readonly_assignment = delta.firstReadonlyAssignment(shell_state.*, plan.assignments);
    if (readonly_assignment) |name| {
        if (bashCommandIgnoresReadonlyAssignment(eval_context, plan)) {
            filtered_assignments = try filterReadonlyAssignments(evaluator.allocator, shell_state.*, plan.assignments);
            effective_plan.assignments = filtered_assignments.?;
            effective_plan.validate();
        } else {
            var state_delta = delta.StateDelta.init(evaluator.allocator, plan.target);
            errdefer state_delta.deinit();
            const status: outcome.ExitStatus = 1;
            state_delta.setLastStatus(status);

            var failure_input = EvaluationInput.empty();
            var buffers = EvaluationBuffers.init(evaluator.allocator, &failure_input, frame);
            defer buffers.deinit();
            try appendPlanExpansionOutput(evaluator.*, eval_context, plan, &buffers);
            try traceCommandPlanForEvaluation(
                evaluator,
                shell_state,
                eval_context,
                plan,
                &failure_input,
                frame,
                &buffers,
            );
            try buffers.addBuiltinDiagnostic(name, "readonly variable");

            const kind: consequence.ShellErrorKind = if (plan.class() == .special_builtin)
                .special_builtin_failure
            else
                .readonly_assignment;
            var control_flow = consequence.decideForShellError(
                shell_state.options,
                eval_context,
                kind,
                status,
            ).control_flow;
            if (readonlyAssignmentOnlyReturnsFromFunction(eval_context, plan, control_flow)) {
                control_flow = .{ .return_from_scope = .{ .scope = .function, .status = status } };
            }
            return commandOutcomeFromBuffers(
                evaluator.allocator,
                eval_context,
                status,
                state_delta,
                control_flow,
                &buffers,
            );
        }
    }

    var state_delta = delta.StateDelta.init(evaluator.allocator, effective_plan.target);
    errdefer state_delta.deinit();
    if (evaluatedAssignmentEffect(eval_context, effective_plan) == .persistent) {
        state_delta.appendPersistentCommandAssignments(
            shell_state.*,
            effective_plan.assignments,
        ) catch |err| switch (err) {
            error.ReadonlyVariable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    var command_frame = try semanticCommandExecutionFrame(
        evaluator.allocator,
        evaluator.scoped_exec_redirections,
        frame,
        effective_plan.target,
        effective_plan.redirections,
    );
    defer command_frame.spec.fd_table.deinit(evaluator.allocator);
    var frame_input = EvaluationInput.empty();
    var buffers = EvaluationBuffers.init(
        evaluator.allocator,
        input,
        &command_frame,
    );
    defer buffers.deinit();
    buffers.useFrameFdTableInput(&frame_input, input);
    if (readonly_assignment) |name| try buffers.addBuiltinDiagnostic(name, "readonly variable");
    try appendPlanExpansionOutput(evaluator.*, eval_context, effective_plan, &buffers);
    try traceCommandPlanForEvaluation(evaluator, shell_state, eval_context, effective_plan, input, frame, &buffers);
    try flushCurrentShellBufferedCommandOutput(&buffers, eval_context, evaluator.external_stdio, evaluator.io != null);
    const routed_prefix: RoutedOutputPrefix = .{
        .stdout = buffers.stdout.items.len,
        .stderr = buffers.stderr.items.len,
    };

    var redirection_guard = RedirectionGuard.empty(.current_scoped);
    defer redirection_guard.restore();
    if (effective_plan.redirections.steps.len != 0 and
        effective_plan.class() != .external and
        effective_plan.class() != .function)
    {
        if (!scopedExecRedirectionsMutateRuntime(evaluator.*, effective_plan) and
            (((eval_context.command_substitution_depth == 0 and eval_context.pipeline_depth != 0 and
                frameRoutesCapturedOutput(command_frame)) or frameRoutesPipelineData(command_frame)) or
                (hasScopedExecRedirections(evaluator.*) and !frame.spec.kind.isParentVisible() and
                    redirectionPlanDuplicatesFromOpenSources(command_frame, effective_plan.redirections) and
                    !scopedExecClosesDuplicateSource(
                        evaluator.scoped_exec_redirections,
                        effective_plan.redirections,
                    ))) and
            !redirectionPlanDuplicatesFromPathSources(command_frame, effective_plan.redirections) and
            !scopedExecPathBacksDuplicateSource(evaluator.scoped_exec_redirections, effective_plan.redirections) and
            !redirectionPlanNeedsRuntimeFdEffects(effective_plan.redirections))
        {
            if (hasScopedExecRedirections(evaluator.*) and !frame.spec.kind.isParentVisible()) {
                buffers.preserve_parent_visible_stdout_capture = true;
            }
            try emitSemanticRedirectionTransforms(evaluator.*, &buffers, effective_plan.redirections);
        } else {
            const apply_result = try applyRedirectionsForScope(
                evaluator.*,
                &buffers,
                .current_scoped,
                .{},
                effective_plan.redirections,
                redirectionExpansionModeForContext(eval_context),
                if (effective_plan.argv.len == 0) "redirection" else effective_plan.argv[0],
            );
            switch (apply_result) {
                .applied => |applied| redirection_guard = applied,
                .failure => |failure| {
                    const command_name = if (effective_plan.argv.len == 0) "redirection" else effective_plan.argv[0];
                    try addRedirectionFailureDiagnostic(&buffers, command_name, failure);
                    const redirection_result = evaluationFromRedirectionFailure(
                        shell_state.options,
                        eval_context,
                        failure,
                    );
                    state_delta.setLastStatus(redirection_result.status);
                    return try commandOutcomeFromBuffers(
                        evaluator.allocator,
                        eval_context,
                        redirection_result.status,
                        state_delta,
                        redirection_result.control_flow,
                        &buffers,
                    );
                },
            }
        }
    }

    const command_context = switch (effective_plan.class()) {
        .special_builtin => eval_context.enterSpecialBuiltin(),
        else => eval_context,
    };
    var result = try evaluateSimpleCommand(
        evaluator,
        shell_state,
        command_context,
        effective_plan,
        &state_delta,
        &buffers,
    );
    switch (execRedirectionCommitMode(evaluator.*, eval_context, effective_plan, result)) {
        .none => if (execRedirectionsMutateCurrentFrame(eval_context, effective_plan, result)) {
            try commitExecRedirectionsToFrame(evaluator.allocator, frame, effective_plan.redirections);
        },
        .permanent => {
            redirection_guard.commitPermanent();
            try commitRuntimeExecRedirectionsToFrame(evaluator.allocator, frame, effective_plan.redirections);
        },
        .scoped => {
            if (redirection_guard.hasTransaction()) {
                try appendScopedExecRedirection(
                    evaluator,
                    redirection_guard.disarmForScopedExec(),
                    effective_plan.redirections,
                );
            } else {
                try appendScopedExecRedirectionPlan(evaluator, effective_plan.redirections);
            }
            try commitRuntimeExecRedirectionsToFrame(evaluator.allocator, frame, effective_plan.redirections);
        },
    }
    if (!simpleCommandOutputAlreadyRouted(effective_plan) and
        (effective_plan.redirections.steps.len != 0 or
            redirection_guard.hasTransaction() or
            (hasScopedExecRedirections(evaluator.*) and eval_context.command_substitution_depth == 0)) and
        effective_plan.class() != .external and
        effective_plan.class() != .function)
    {
        if (try discardBufferedOutputForClosedDestinations(
            evaluator.*,
            &buffers,
            effective_plan.redirections,
            eval_context,
        )) {
            result.status = 1;
        }
        flushBufferedRedirectionOutput(
            evaluator.*,
            &buffers,
            effective_plan.redirections,
            eval_context,
            routed_prefix,
        ) catch |err| switch (err) {
            error.Unimplemented => result.status = 1,
            else => |e| return e,
        };
    }
    if (frameRoutesCapturedOutput(command_frame) and eval_context.command_substitution_depth == 0 and
        eval_context.pipeline_depth != 0)
    {
        try routeDirectPipelineStageBuffers(&buffers);
    }
    state_delta.setLastStatus(result.status);
    assertCommandDeltaCompatible(effective_plan, state_delta);
    const decision = if (specialBuiltinStatusOnly(effective_plan, result, buffers))
        consequence.decideForStatus(shell_state.options, eval_context, result.status)
    else
        consequence.decideForSimpleCommand(
            shell_state.options,
            eval_context,
            effective_plan,
            result.status,
            result.control_flow,
        );

    var command_outcome = outcome.CommandOutcome.withControlFlow(
        evaluator.allocator,
        result.status,
        state_delta,
        decision.control_flow,
    );
    errdefer command_outcome.deinit();
    try command_outcome.appendStdout(buffers.stdout.items);
    try command_outcome.appendStderr(buffers.stderr.items);
    try command_outcome.side_stdout.appendSlice(evaluator.allocator, buffers.side_stdout.items);
    try command_outcome.pipeline_stdout.appendSlice(evaluator.allocator, buffers.pipeline_stdout.items);
    for (buffers.diagnostics.items) |message| try command_outcome.addDiagnostic(message);
    try appendBuiltinDiagnostic(&command_outcome, effective_plan, result.status);
    command_outcome.validateForContext(eval_context);
    return command_outcome;
}

fn simpleCommandOutputAlreadyRouted(plan: command_plan.CommandPlan) bool {
    plan.validate();
    if (plan.argv.len == 0) return false;
    return std.mem.eql(u8, plan.argv[0], "echo") or std.mem.eql(u8, plan.argv[0], "printf");
}

fn bashCommandIgnoresReadonlyAssignment(eval_context: context.EvalContext, plan: command_plan.CommandPlan) bool {
    eval_context.validate();
    plan.validate();
    if (!eval_context.features.isBash()) return false;
    return switch (plan.class()) {
        .assignment_only, .empty, .function_definition => false,
        .special_builtin, .regular_builtin, .function, .external, .not_found => true,
    };
}

fn readonlyAssignmentOnlyReturnsFromFunction(
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    control_flow: outcome.ControlFlow,
) bool {
    eval_context.validate();
    plan.validate();
    control_flow.validateForContext(eval_context);
    return eval_context.canReturnFromFunction() and
        plan.class() == .assignment_only and
        control_flow == .normal;
}

fn evaluatedAssignmentEffect(
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
) command_plan.AssignmentEffect {
    eval_context.validate();
    plan.validate();
    if (bashEvalUsesTemporaryAssignments(eval_context, plan)) return .temporary;
    return plan.assignmentEffect();
}

fn bashEvalUsesTemporaryAssignments(eval_context: context.EvalContext, plan: command_plan.CommandPlan) bool {
    eval_context.validate();
    plan.validate();
    if (!eval_context.features.isBash()) return false;
    if (plan.assignments.len == 0 or plan.argv.len == 0) return false;
    return std.mem.eql(u8, plan.argv[0], "eval") and plan.class() == .special_builtin;
}

fn execRedirectionsMutateCurrentFrame(
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    result: SimpleEvalResult,
) bool {
    eval_context.validate();
    plan.validate();
    result.control_flow.validate();
    if (result.status != 0 or result.control_flow != .normal) return false;
    if (plan.argv.len != 1) return false;
    if (!std.mem.eql(u8, plan.argv[0], "exec")) return false;
    return eval_context.target.allowsShellStateCommit();
}

fn filterReadonlyAssignments(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    assignments: []const command_plan.Assignment,
) ![]command_plan.Assignment {
    shell_state.validate();
    for (assignments) |assignment| assignment.validate();
    var filtered: std.ArrayList(command_plan.Assignment) = .empty;
    errdefer filtered.deinit(allocator);
    for (assignments) |assignment| {
        const variable = shell_state.getVariable(assignment.name) orelse {
            try filtered.append(allocator, assignment);
            continue;
        };
        if (!variable.readonly) try filtered.append(allocator, assignment);
    }
    return filtered.toOwnedSlice(allocator);
}

const ExecRedirectionCommitMode = enum {
    none,
    permanent,
    scoped,
};

fn scopedExecRedirectionsMutateRuntime(evaluator: Evaluator, plan: command_plan.CommandPlan) bool {
    plan.validate();
    if (evaluator.scoped_exec_redirections == null) return false;
    if (plan.argv.len != 1) return false;
    return std.mem.eql(u8, plan.argv[0], "exec");
}

fn execRedirectionCommitMode(
    evaluator: Evaluator,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    result: SimpleEvalResult,
) ExecRedirectionCommitMode {
    eval_context.validate();
    plan.validate();
    result.control_flow.validate();
    if (result.status != 0 or result.control_flow != .normal) return .none;
    if (plan.argv.len != 1) return .none;
    if (!std.mem.eql(u8, plan.argv[0], "exec")) return .none;
    if (evaluator.scoped_exec_redirections != null) {
        return .scoped;
    }
    if (!evaluator.commit_exec_redirections) return .none;
    if (evaluator.external_stdio != .inherit) return .none;
    return .permanent;
}

fn compoundPlanOwnsScopedExecRedirections(
    eval_context: context.EvalContext,
    plan: command_plan.CompoundCommandPlan,
) bool {
    eval_context.validate();
    plan.validate();
    if (!plan.target.isIsolatedFromParent()) return false;
    if (eval_context.command_substitution_depth == 0) return true;
    if (eval_context.subshell_depth != 0) return true;
    return plan.body == .subshell;
}

fn appendScopedExecRedirection(
    evaluator: *Evaluator,
    applied: redirection_plan.FdTransaction,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    redirections.validate();
    const scoped_redirections = evaluator.scoped_exec_redirections.?;
    var owned_redirections = try redirections.clone(evaluator.allocator);
    errdefer owned_redirections.deinit();
    try scoped_redirections.append(evaluator.allocator, .{
        .applied = applied,
        .redirections = owned_redirections,
    });
}

fn appendScopedExecRedirectionPlan(
    evaluator: *Evaluator,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    redirections.validate();
    const scoped_redirections = evaluator.scoped_exec_redirections.?;
    var owned_redirections = try redirections.clone(evaluator.allocator);
    errdefer owned_redirections.deinit();
    try scoped_redirections.append(evaluator.allocator, .{ .redirections = owned_redirections });
}

fn commitExecRedirectionsToFrame(
    allocator: std.mem.Allocator,
    frame: *execution_frame.ExecutionFrame,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    frame.validate();
    redirections.validate();
    try frame.spec.fd_table.applyRedirectionPlan(allocator, redirections);
    frame.validate();
}

fn commitRuntimeExecRedirectionsToFrame(
    allocator: std.mem.Allocator,
    frame: *execution_frame.ExecutionFrame,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    frame.validate();
    redirections.validate();
    for (redirections.steps) |step| {
        step.validate();
        try bindRuntimeRedirectionTargetToFrame(allocator, frame, step);
    }
    frame.validate();
}

fn inheritScopedExecRedirections(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(ScopedExecRedirection),
    inherited: ?*std.ArrayList(ScopedExecRedirection),
) EvalError!void {
    const inherited_redirections = inherited orelse return;
    for (inherited_redirections.items) |scoped| {
        var owned_redirections = try scoped.redirections.clone(allocator);
        errdefer owned_redirections.deinit();
        try target.append(allocator, .{ .redirections = owned_redirections });
    }
}

fn specialBuiltinStatusOnly(
    plan: command_plan.CommandPlan,
    result: SimpleEvalResult,
    buffers: EvaluationBuffers,
) bool {
    plan.validate();
    result.control_flow.validate();
    if (plan.class() != .special_builtin) return false;
    if (result.control_flow != .normal) return false;
    if (result.status == 0) return false;
    return buffers.diagnostics.items.len == 0;
}

fn flushBuffersForRedirectionTargets(
    buffers: *EvaluationBuffers,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    redirections.validate();
    var frame = OutputFrame.initInherited(buffers);
    defer frame.deinit();
    try frame.applyRedirectionsFlushingRouteChanges(redirections);
}

fn flushBuffersToInheritedDescriptors(buffers: *EvaluationBuffers) EvalError!void {
    var frame = OutputFrame.initInherited(buffers);
    defer frame.deinit();
    try frame.flushPendingStandardDescriptors();
}

fn flushCurrentShellBufferedCommandOutput(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
    external_stdio: ExternalStdio,
    live_stdio: bool,
) EvalError!void {
    eval_context.validate();
    if (eval_context.target != .current_shell) return;
    if (!buffers.frame.spec.kind.isParentVisible()) return;
    if (eval_context.command_substitution_depth != 0) return;
    switch (external_stdio) {
        .capture => {},
        .capture_stdout => {
            if (!frameTargetsInheritedStandardDescriptors(buffers.frame.*, live_stdio)) return;
            var frame = OutputFrame.initInherited(buffers);
            defer frame.deinit();
            try frame.flushPendingDescriptor(2);
        },
        .inherit_output, .inherit => {
            if (!frameTargetsInheritedStandardDescriptors(buffers.frame.*, live_stdio)) return;
            var frame = OutputFrame.initInherited(buffers);
            defer frame.deinit();
            try frame.flushPendingStandardDescriptors();
        },
    }
}

fn flushLiveInheritedBufferedOutput(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
    live_stdio: bool,
) EvalError!void {
    eval_context.validate();
    if (!eval_context.interactive) return;
    if (eval_context.command_substitution_depth != 0) return;
    if (!frameTargetsInheritedStandardDescriptors(buffers.frame.*, live_stdio)) return;
    try flushBuffersToInheritedDescriptors(buffers);
}

fn frameTargetsInheritedStandardDescriptors(frame: execution_frame.ExecutionFrame, live_stdio: bool) bool {
    frame.validate();
    if (frame.spec.kind == .trap_handler and !live_stdio) return false;
    const stdout_endpoint = frame.spec.fd_table.boundEndpoint(1) orelse
        @as(execution_frame.FdEndpoint, .{ .output = frame.spec.stdout });
    const stderr_endpoint = frame.spec.fd_table.boundEndpoint(2) orelse
        @as(execution_frame.FdEndpoint, .{ .output = frame.spec.stderr });
    const stdout_inherited = switch (stdout_endpoint) {
        .output => |output| switch (output) {
            .inherit_stdout => true,
            .fd, .pipe_write => |descriptor| descriptor == 1,
            .capture => |channel| live_stdio and channel == .side_stdout,
            .inherit_stderr, .path, .discard => false,
        },
        .closed, .input => false,
    };
    const stderr_inherited = switch (stderr_endpoint) {
        .output => |output| switch (output) {
            .inherit_stderr => true,
            .fd, .pipe_write => |descriptor| descriptor == 2,
            .capture => |channel| live_stdio and channel == .side_stderr,
            .inherit_stdout, .path, .discard => false,
        },
        .closed, .input => false,
    };
    return stdout_inherited or stderr_inherited;
}

fn routeDirectPipelineStageBuffers(buffers: *EvaluationBuffers) EvalError!void {
    buffers.frame.validate();
    std.debug.assert(frameRoutesCapturedOutput(buffers.frame.*));

    try routeDirectPipelineStageBuffer(buffers, 1, &buffers.stdout);
    try routeDirectPipelineStageBuffer(buffers, 2, &buffers.stderr);
}

fn routeDirectPipelineStageBuffer(
    buffers: *EvaluationBuffers,
    descriptor: runtime.fd.Descriptor,
    source: *std.ArrayList(u8),
) EvalError!void {
    runtime.fd.assertValidDescriptor(descriptor);
    if (source.items.len == 0) return;

    switch (buffers.frame.spec.fd_table.endpoint(descriptor)) {
        .output => |output| switch (output) {
            .capture => |channel| switch (channel) {
                .pipeline_data => try moveBufferedOutput(buffers.allocator, source, &buffers.pipeline_stdout),
                .side_stdout => try moveBufferedOutput(buffers.allocator, source, &buffers.side_stdout),
                .side_stderr => try moveBufferedOutput(buffers.allocator, source, &buffers.stderr),
                .command_substitution_stdout => {},
            },
            .discard => source.items.len = 0,
            .inherit_stdout, .inherit_stderr, .fd, .pipe_write, .path => {},
        },
        .closed => source.items.len = 0,
        .input => source.items.len = 0,
    }
}

fn moveBufferedOutput(
    allocator: std.mem.Allocator,
    source: *std.ArrayList(u8),
    dest: *std.ArrayList(u8),
) !void {
    if (source == dest) return;
    try dest.appendSlice(allocator, source.items);
    source.items.len = 0;
}

pub const RunnerOutputWriteResult = struct {
    stdout_failed: bool = false,
    stderr_failed: bool = false,
};

pub const RunnerOutput = struct {
    stdout: []u8,
    stderr: []u8,
};

pub const RunnerOutputMode = enum {
    capture,
    live,
};

pub const RunnerOutputFrame = struct {
    allocator: std.mem.Allocator,
    input: *EvaluationInput,
    execution_frame_value: *execution_frame.ExecutionFrame,
    buffers: *EvaluationBuffers,
    routing: OutputRouting,

    pub fn init(allocator: std.mem.Allocator, mode: RunnerOutputMode) !RunnerOutputFrame {
        const input = try allocator.create(EvaluationInput);
        errdefer allocator.destroy(input);
        input.* = EvaluationInput.empty();

        const execution_frame_value = try allocator.create(execution_frame.ExecutionFrame);
        errdefer allocator.destroy(execution_frame_value);
        execution_frame_value.* = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
        errdefer execution_frame_value.spec.fd_table.deinit(allocator);
        try configureRunnerExecutionFrameForMode(allocator, execution_frame_value, mode);

        const buffers = try allocator.create(EvaluationBuffers);
        errdefer allocator.destroy(buffers);
        buffers.* = EvaluationBuffers.init(allocator, input, execution_frame_value);
        errdefer buffers.deinit();

        const initial_mode: OutputRouting.InitialMode = switch (mode) {
            .capture => .outcome_capture,
            .live => .inherited,
        };
        return .{
            .allocator = allocator,
            .input = input,
            .execution_frame_value = execution_frame_value,
            .buffers = buffers,
            .routing = OutputRouting.init(allocator, initial_mode),
        };
    }

    pub fn deinit(self: *RunnerOutputFrame) void {
        self.routing.deinit();
        self.buffers.deinit();
        self.execution_frame_value.spec.fd_table.deinit(self.allocator);
        self.allocator.destroy(self.buffers);
        self.allocator.destroy(self.execution_frame_value);
        self.allocator.destroy(self.input);
        self.* = undefined;
    }

    pub fn writeOutcome(
        self: *RunnerOutputFrame,
        stdout_bytes: []const u8,
        stderr_bytes: []const u8,
    ) !RunnerOutputWriteResult {
        var frame = self.outputFrame();
        defer frame.deinit();

        var result: RunnerOutputWriteResult = .{};
        frame.write(1, stdout_bytes) catch |err| switch (err) {
            error.Unimplemented => result.stdout_failed = true,
            else => |e| return e,
        };
        frame.write(2, stderr_bytes) catch |err| switch (err) {
            error.Unimplemented => result.stderr_failed = true,
            else => |e| return e,
        };
        return result;
    }

    pub fn flushPendingToInheritedDescriptors(self: *RunnerOutputFrame) !RunnerOutputWriteResult {
        var frame = OutputFrame.initInherited(self.buffers);
        defer frame.deinit();

        var result: RunnerOutputWriteResult = .{};
        frame.flushPendingDescriptor(1) catch |err| switch (err) {
            error.Unimplemented => result.stdout_failed = true,
            else => |e| return e,
        };
        frame.flushPendingDescriptor(2) catch |err| switch (err) {
            error.Unimplemented => result.stderr_failed = true,
            else => |e| return e,
        };
        return result;
    }

    pub fn finish(self: *RunnerOutputFrame) !RunnerOutput {
        const stdout = try self.buffers.stdout.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(stdout);
        const stderr = try self.buffers.stderr.toOwnedSlice(self.allocator);
        return .{ .stdout = stdout, .stderr = stderr };
    }

    fn outputFrame(self: *RunnerOutputFrame) OutputFrame {
        return OutputFrame.initBorrowed(self.buffers, &self.routing);
    }
};

const OutputFrame = struct {
    buffers: *EvaluationBuffers,
    routing: OutputRouting,
    borrowed_routing: ?*OutputRouting = null,

    fn initOutcomeCapture(buffers: *EvaluationBuffers) OutputFrame {
        return .{ .buffers = buffers, .routing = OutputRouting.init(buffers.allocator, .outcome_capture) };
    }

    fn initBorrowed(buffers: *EvaluationBuffers, routing: *OutputRouting) OutputFrame {
        return .{
            .buffers = buffers,
            .routing = OutputRouting.init(buffers.allocator, .outcome_capture),
            .borrowed_routing = routing,
        };
    }

    fn initOwnedRouting(buffers: *EvaluationBuffers, routing: OutputRouting) OutputFrame {
        return .{ .buffers = buffers, .routing = routing };
    }

    fn initInherited(buffers: *EvaluationBuffers) OutputFrame {
        return .{ .buffers = buffers, .routing = OutputRouting.init(buffers.allocator, .inherited) };
    }

    fn initCommandSubstitution(buffers: *EvaluationBuffers) OutputFrame {
        return .{ .buffers = buffers, .routing = OutputRouting.initCommandSubstitution(buffers.allocator) };
    }

    fn deinit(self: *OutputFrame) void {
        if (self.borrowed_routing == null) self.routing.deinit();
        self.* = undefined;
    }

    fn routingRef(self: *OutputFrame) *OutputRouting {
        return self.borrowed_routing orelse &self.routing;
    }

    fn write(self: *OutputFrame, descriptor: runtime.fd.Descriptor, bytes: []const u8) !void {
        try self.buffers.frame.writeFd(self.writer(), descriptor, bytes);
    }

    fn writer(self: *OutputFrame) execution_frame.OutputWriter {
        return .{ .context = self, .write_fn = writeRouted };
    }

    fn diagnosticStore(self: *OutputFrame) execution_frame.DiagnosticStore {
        return .{ .context = self, .append_fn = appendDiagnosticOnly };
    }

    fn writeRouted(
        context_ptr: *anyopaque,
        descriptor: runtime.fd.Descriptor,
        bytes: []const u8,
    ) execution_frame.OutputWriteError!void {
        const self: *OutputFrame = @ptrCast(@alignCast(context_ptr));
        runtime.fd.assertValidDescriptor(descriptor);
        if (bytes.len == 0) return;

        try self.buffers.appendToDestination(self.routingRef().destination(descriptor), bytes);
    }

    fn appendDiagnosticOnly(context_ptr: *anyopaque, diagnostic: []const u8) execution_frame.OutputWriteError!void {
        const self: *OutputFrame = @ptrCast(@alignCast(context_ptr));
        const diagnostic_copy = try self.buffers.allocator.dupe(u8, diagnostic);
        errdefer self.buffers.allocator.free(diagnostic_copy);
        try self.buffers.diagnostics.append(self.buffers.allocator, diagnostic_copy);
    }

    fn flushPendingDescriptor(self: *OutputFrame, descriptor: runtime.fd.Descriptor) EvalError!void {
        runtime.fd.assertValidDescriptor(descriptor);
        switch (descriptor) {
            1 => try self.buffers.flushStreamToDestination(.stdout, self.routingRef().destination(descriptor)),
            2 => try self.buffers.flushStreamToDestination(.stderr, self.routingRef().destination(descriptor)),
            else => {},
        }
    }

    fn flushPendingStandardDescriptors(self: *OutputFrame) EvalError!void {
        try self.buffers.flushStandardToDestinations(
            self.routingRef().destination(1),
            self.routingRef().destination(2),
        );
    }

    fn applyRedirectionsFlushingRouteChanges(
        self: *OutputFrame,
        redirections: redirection_plan.RedirectionPlan,
    ) EvalError!void {
        redirections.validate();
        // Flush buffered bytes before each descriptor's logical route changes. This is a transition helper, not
        // a final-route flush; callers must ensure the process fd state already matches the bytes being flushed.
        for (redirections.steps) |step| {
            step.validate();
            switch (step.target()) {
                1 => try self.flushPendingDescriptor(1),
                2 => try self.flushPendingDescriptor(2),
                else => {},
            }
            try self.routingRef().applyRedirectionStep(step);
        }
    }

    fn addDiagnostic(self: *OutputFrame, diagnostic: []const u8, stderr_text: []const u8) !void {
        std.debug.assert(diagnostic.len != 0);
        std.debug.assert(stderr_text.len != 0);

        try self.buffers.frame.emitDiagnostic(self.writer(), self.diagnosticStore(), diagnostic, stderr_text);
    }

    fn addBuiltinDiagnostic(self: *OutputFrame, command: []const u8, message: []const u8) !void {
        std.debug.assert(command.len != 0);
        std.debug.assert(message.len != 0);

        const stderr_text = try std.fmt.allocPrint(self.buffers.allocator, "{s}: {s}\n", .{ command, message });
        defer self.buffers.allocator.free(stderr_text);
        const diagnostic = try std.fmt.allocPrint(self.buffers.allocator, "{s}: {s}", .{ command, message });
        defer self.buffers.allocator.free(diagnostic);

        try self.addDiagnostic(diagnostic, stderr_text);
    }
};

fn configureRunnerExecutionFrameForMode(
    allocator: std.mem.Allocator,
    frame: *execution_frame.ExecutionFrame,
    mode: RunnerOutputMode,
) !void {
    frame.validate();
    switch (mode) {
        .live => {},
        .capture => {
            const stdout: execution_frame.OutputEndpoint = .{ .capture = .side_stdout };
            const stderr: execution_frame.OutputEndpoint = .{ .capture = .side_stderr };
            try frame.spec.fd_table.bindOutput(allocator, 1, stdout);
            try frame.spec.fd_table.bindOutput(allocator, 2, stderr);
            frame.spec.stdout = stdout;
            frame.spec.stderr = stderr;
            frame.spec.captures = captureSet(.side_stdout, .side_stderr);
        },
    }
    frame.validate();
}

fn writeExternalRunOutput(
    frame: *OutputFrame,
    descriptor: runtime.fd.Descriptor,
    bytes: []const u8,
) EvalError!void {
    runtime.fd.assertValidDescriptor(descriptor);
    if (bytes.len == 0) return;
    switch (frame.routingRef().destination(descriptor)) {
        .closed => return error.Unimplemented,
        else => {},
    }
    try frame.write(descriptor, bytes);
}

fn writeOutcomeToInheritedDescriptors(
    allocator: std.mem.Allocator,
    stdout_bytes: []const u8,
    stderr_bytes: []const u8,
) EvalError!void {
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    var frame = OutputFrame.initInherited(&buffers);
    defer frame.deinit();
    try frame.write(1, stdout_bytes);
    try frame.write(2, stderr_bytes);
}

test "output frame outcome capture writes stdout and stderr buffers" {
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    var frame = OutputFrame.initOutcomeCapture(&buffers);
    defer frame.deinit();
    try frame.write(1, "out");
    try frame.write(2, "err");

    try std.testing.expectEqualStrings("out", buffers.stdout.items);
    try std.testing.expectEqualStrings("err", buffers.stderr.items);
}

test "evaluation buffers output frame derives routing from fd table" {
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    try execution_frame_value.spec.fd_table.bindOutput(std.testing.allocator, 1, .{ .capture = .side_stderr });
    defer execution_frame_value.spec.fd_table.deinit(std.testing.allocator);
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    var frame = try buffers.outputFrame();
    defer frame.deinit();
    try frame.write(1, "routed");

    try std.testing.expectEqualStrings("", buffers.stdout.items);
    try std.testing.expectEqualStrings("routed", buffers.stderr.items);
}

test "output frame diagnostic helper writes stderr and structured diagnostic" {
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    var frame = OutputFrame.initOutcomeCapture(&buffers);
    defer frame.deinit();
    try frame.addBuiltinDiagnostic("cmd", "failed");

    try std.testing.expectEqualStrings("cmd: failed\n", buffers.stderr.items);
    try std.testing.expectEqual(@as(usize, 1), buffers.diagnostics.items.len);
    try std.testing.expectEqualStrings("cmd: failed", buffers.diagnostics.items[0]);
}

test "output frame closed destination discards output" {
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    var frame = OutputFrame.initOutcomeCapture(&buffers);
    defer frame.deinit();
    try frame.routing.setDestination(1, .closed);
    try frame.write(1, "discarded");

    try std.testing.expectEqualStrings("", buffers.stdout.items);
    try std.testing.expectEqualStrings("", buffers.stderr.items);
}

test "output frame flushes pending descriptor before route change" {
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    var frame = OutputFrame.initCommandSubstitution(&buffers);
    defer frame.deinit();
    try frame.routing.setDestination(1, .command_substitution_stderr_capture);
    try buffers.stdout.appendSlice(std.testing.allocator, "pending");

    const steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.close(0, 1)};
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };
    try frame.applyRedirectionsFlushingRouteChanges(plan);

    try std.testing.expectEqualStrings("", buffers.stdout.items);
    try std.testing.expectEqualStrings("pending", buffers.stderr.items);
    try std.testing.expectEqual(OutputDestination.closed, frame.routing.destination(1));
}

fn flushBufferedRedirectionOutput(
    evaluator: Evaluator,
    buffers: *EvaluationBuffers,
    redirections: redirection_plan.RedirectionPlan,
    eval_context: context.EvalContext,
    routed_prefix: RoutedOutputPrefix,
) EvalError!void {
    redirections.validate();
    eval_context.validate();
    routed_prefix.validate(buffers.*);
    if (eval_context.command_substitution_depth == 0 and
        !hasScopedExecRedirections(evaluator))
    {
        std.debug.assert(routed_prefix.stdout == 0);
        std.debug.assert(routed_prefix.stderr == 0);
        return flushBuffersForRedirectionTargets(buffers, redirections);
    }

    const command_substitution_capture = eval_context.command_substitution_depth != 0;
    var frame = if (command_substitution_capture)
        OutputFrame.initCommandSubstitution(buffers)
    else
        OutputFrame.initInherited(buffers);
    defer frame.deinit();

    if (!command_substitution_capture) {
        if (!buffers.frame.spec.kind.isParentVisible() and hasScopedExecRedirections(evaluator)) {
            if (!scopedExecTargetsDescriptor(evaluator, 1) and !scopedExecTargetsDescriptor(evaluator, 2)) return;
            var routed_frame = try buffers.outputFrame();
            defer routed_frame.deinit();
            try routed_frame.flushPendingStandardDescriptors();
            return;
        }
        if (evaluator.scoped_exec_redirections) |scoped_redirections| {
            for (scoped_redirections.items) |scoped| {
                try frame.applyRedirectionsFlushingRouteChanges(scoped.redirections);
            }
        }
        try frame.applyRedirectionsFlushingRouteChanges(redirections);
        try frame.flushPendingStandardDescriptors();
        return;
    }

    if (routed_prefix.stdout == 0 and routed_prefix.stderr == 0) {
        try applyOutputRoutingRedirections(evaluator, &frame.routing, redirections);
        try frame.flushPendingStandardDescriptors();
    } else {
        try flushBufferedRedirectionOutputAfterPrefix(
            evaluator,
            buffers,
            redirections,
            eval_context,
            routed_prefix,
        );
    }
}

fn discardBufferedOutputForClosedDestinations(
    evaluator: Evaluator,
    buffers: *EvaluationBuffers,
    redirections: redirection_plan.RedirectionPlan,
    eval_context: context.EvalContext,
) EvalError!bool {
    redirections.validate();
    eval_context.validate();
    if (buffers.stdout.items.len == 0 and buffers.stderr.items.len == 0) return false;

    var routing = if (eval_context.command_substitution_depth != 0)
        OutputRouting.initCommandSubstitution(buffers.allocator)
    else
        OutputRouting.init(buffers.allocator, .inherited);
    defer routing.deinit();

    try applyOutputRoutingRedirections(evaluator, &routing, redirections);
    var failed = false;
    if (buffers.stdout.items.len != 0 and routing.destination(1) == .closed) {
        buffers.stdout.items.len = 0;
        failed = true;
    }
    if (buffers.stderr.items.len != 0 and routing.destination(2) == .closed) {
        buffers.stderr.items.len = 0;
        failed = true;
    }
    return failed;
}

fn flushBufferedRedirectionOutputAfterPrefix(
    evaluator: Evaluator,
    buffers: *EvaluationBuffers,
    redirections: redirection_plan.RedirectionPlan,
    eval_context: context.EvalContext,
    routed_prefix: RoutedOutputPrefix,
) EvalError!void {
    redirections.validate();
    eval_context.validate();
    routed_prefix.validate(buffers.*);

    const stdout_tail = try buffers.allocator.dupe(u8, buffers.stdout.items[routed_prefix.stdout..]);
    defer buffers.allocator.free(stdout_tail);
    const stderr_tail = try buffers.allocator.dupe(u8, buffers.stderr.items[routed_prefix.stderr..]);
    defer buffers.allocator.free(stderr_tail);
    buffers.stdout.items.len = routed_prefix.stdout;
    buffers.stderr.items.len = routed_prefix.stderr;

    var frame = if (eval_context.command_substitution_depth != 0)
        OutputFrame.initCommandSubstitution(buffers)
    else
        OutputFrame.initOutcomeCapture(buffers);
    defer frame.deinit();
    try applyOutputRoutingRedirections(evaluator, &frame.routing, redirections);
    try frame.write(1, stdout_tail);
    try frame.write(2, stderr_tail);
}

const RedirectionExpansionOutputMode = enum {
    inherited,
    command_substitution,
};

fn redirectionExpansionModeForContext(eval_context: context.EvalContext) RedirectionExpansionOutputMode {
    eval_context.validate();
    return if (eval_context.command_substitution_depth != 0) .command_substitution else .inherited;
}

fn redirectionExpansionModeForExternal(external_stdio: ExternalStdio) RedirectionExpansionOutputMode {
    return switch (external_stdio) {
        .capture => .command_substitution,
        .capture_stdout, .inherit_output, .inherit => .inherited,
    };
}

fn redirectionExpansionOutputFrame(
    buffers: *EvaluationBuffers,
    mode: RedirectionExpansionOutputMode,
) OutputFrame {
    return switch (mode) {
        .inherited => OutputFrame.initInherited(buffers),
        .command_substitution => OutputFrame.initCommandSubstitution(buffers),
    };
}

fn redirectionPlanNeedsRuntimeFdEffects(redirections: redirection_plan.RedirectionPlan) bool {
    redirections.validate();
    for (redirections.steps) |step| {
        step.validate();
        switch (step.effect) {
            .open_path => return true,
            .here_doc, .duplicate, .close => {},
        }
    }
    return false;
}

fn redirectionPlanOnlyDuplicates(redirections: redirection_plan.RedirectionPlan) bool {
    redirections.validate();
    if (redirections.steps.len == 0) return false;
    for (redirections.steps) |step| {
        step.validate();
        switch (step.effect) {
            .duplicate => {},
            .open_path, .here_doc, .close => return false,
        }
    }
    return true;
}

fn redirectionPlanDuplicatesFromOpenSources(
    frame: execution_frame.ExecutionFrame,
    redirections: redirection_plan.RedirectionPlan,
) bool {
    frame.validate();
    redirections.validate();
    if (redirections.steps.len == 0) return false;
    for (redirections.steps) |step| {
        step.validate();
        switch (step.effect) {
            .duplicate => |duplicate| if (frame.spec.fd_table.endpoint(duplicate.source) == .closed) return false,
            .open_path, .here_doc, .close => return false,
        }
    }
    return true;
}

fn redirectionPlanDuplicatesFromPathSources(
    frame: execution_frame.ExecutionFrame,
    redirections: redirection_plan.RedirectionPlan,
) bool {
    frame.validate();
    redirections.validate();
    for (redirections.steps) |step| {
        step.validate();
        switch (step.effect) {
            .duplicate => |duplicate| switch (frame.spec.fd_table.endpoint(duplicate.source)) {
                .output => |output| switch (output) {
                    .path => return true,
                    .inherit_stdout,
                    .inherit_stderr,
                    .fd,
                    .pipe_write,
                    .capture,
                    .discard,
                    => {},
                },
                .input, .closed => {},
            },
            .open_path, .here_doc, .close => {},
        }
    }
    return false;
}

fn scopedExecClosesDuplicateSource(
    scoped_redirections: ?*std.ArrayList(ScopedExecRedirection),
    redirections: redirection_plan.RedirectionPlan,
) bool {
    redirections.validate();
    const scoped_list = scoped_redirections orelse return false;
    for (redirections.steps) |step| {
        step.validate();
        const source = switch (step.effect) {
            .duplicate => |duplicate| duplicate.source,
            .open_path, .here_doc, .close => continue,
        };
        for (scoped_list.items) |scoped| {
            scoped.redirections.validate();
            for (scoped.redirections.steps) |scoped_step| {
                scoped_step.validate();
                switch (scoped_step.effect) {
                    .close => |close_step| if (close_step.target == source) return true,
                    .open_path, .here_doc, .duplicate => {},
                }
            }
        }
    }
    return false;
}

fn scopedExecPathBacksDuplicateSource(
    scoped_redirections: ?*std.ArrayList(ScopedExecRedirection),
    redirections: redirection_plan.RedirectionPlan,
) bool {
    redirections.validate();
    const scoped_list = scoped_redirections orelse return false;
    if (scoped_list.items.len == 0) return false;
    for (redirections.steps) |step| {
        step.validate();
        switch (step.effect) {
            .duplicate => |duplicate| if (scopedDescriptorIsPathBacked(
                scoped_list.*,
                duplicate.source,
                scoped_list.items.len - 1,
                scoped_list.items[scoped_list.items.len - 1].redirections.steps.len,
                0,
            )) return true,
            .open_path, .here_doc, .close => {},
        }
    }
    return false;
}

fn scopedDescriptorIsPathBacked(
    scoped_list: std.ArrayList(ScopedExecRedirection),
    descriptor: runtime.fd.Descriptor,
    stop_scoped_index: usize,
    stop_step_index: usize,
    depth: usize,
) bool {
    runtime.fd.assertValidDescriptor(descriptor);
    std.debug.assert(scoped_list.items.len != 0);
    std.debug.assert(stop_scoped_index < scoped_list.items.len);
    std.debug.assert(stop_step_index <= scoped_list.items[stop_scoped_index].redirections.steps.len);
    if (depth > 16) return false;

    var scoped_index = stop_scoped_index + 1;
    while (scoped_index != 0) {
        scoped_index -= 1;
        const steps = scoped_list.items[scoped_index].redirections.steps;
        var step_index = if (scoped_index == stop_scoped_index) stop_step_index else steps.len;
        while (step_index != 0) {
            step_index -= 1;
            const step = steps[step_index];
            step.validate();
            if (step.target() != descriptor) continue;
            return switch (step.effect) {
                .open_path => true,
                .duplicate => |duplicate| scopedDescriptorIsPathBacked(
                    scoped_list,
                    duplicate.source,
                    scoped_index,
                    step_index,
                    depth + 1,
                ),
                .here_doc, .close => false,
            };
        }
    }
    return false;
}

fn emitSemanticRedirectionTransforms(
    evaluator: Evaluator,
    buffers: *EvaluationBuffers,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    redirections.validate();
    var frame = try buffers.outputFrame();
    defer frame.deinit();
    if (evaluator.scoped_exec_redirections) |scoped_redirections| {
        for (scoped_redirections.items) |scoped| {
            try frame.applyRedirectionsFlushingRouteChanges(scoped.redirections);
        }
    }
    for (redirections.steps) |step| {
        step.validate();
        try appendRedirectionExpansionOutputToFrame(step.expansion_output, &frame);
        switch (step.target()) {
            1 => try frame.flushPendingDescriptor(1),
            2 => try frame.flushPendingDescriptor(2),
            else => {},
        }
        try frame.routingRef().applyRedirectionStep(step);
    }
}

fn applyRedirectionsEmittingExpansionOutput(
    evaluator: Evaluator,
    buffers: *EvaluationBuffers,
    scope: RedirectionScope,
    already_applied: redirection_plan.RedirectionPlan,
    redirections: redirection_plan.RedirectionPlan,
    mode: RedirectionExpansionOutputMode,
    diagnostic_command_name: ?[]const u8,
) EvalError!redirection_plan.ApplyResult {
    scope.validate();
    already_applied.validate();
    redirections.validate();
    const fd_port = evaluator.fd_port orelse return error.Unimplemented;

    var frame = redirectionExpansionOutputFrame(buffers, mode);
    defer frame.deinit();
    if (evaluator.scoped_exec_redirections) |scoped_redirections| {
        for (scoped_redirections.items) |scoped| {
            try frame.applyRedirectionsFlushingRouteChanges(scoped.redirections);
        }
    }
    try frame.applyRedirectionsFlushingRouteChanges(already_applied);

    var applied = redirection_plan.FdTransaction.init(
        buffers.allocator,
        fd_port,
        redirections.self_duplicate_noop,
    );
    errdefer {
        applied.restore();
        applied.deinit();
    }

    for (redirections.steps, 0..) |step, index| {
        step.validate();
        try appendRedirectionExpansionOutputToFrame(step.expansion_output, &frame);
        switch (step.target()) {
            1 => try frame.flushPendingDescriptor(1),
            2 => try frame.flushPendingDescriptor(2),
            else => {},
        }
        if (try applied.applyStep(step)) |detail| {
            var failure: redirection_plan.ApplyFailure = .{
                .step_index = index,
                .target = step.target(),
                .detail = detail,
                .consequence = redirections.failure_consequence,
            };
            if (diagnostic_command_name) |command_name| {
                if (diagnosticDestinationIsWritable(frame.routingRef().destination(2))) {
                    try frame.addBuiltinDiagnostic(command_name, redirectionFailureMessage(failure));
                    failure.diagnostic_emitted = true;
                }
            }
            applied.restore();
            applied.deinit();
            return .{ .failure = failure };
        }
        try frame.routingRef().applyRedirectionStep(step);
    }

    applied.validateActive();
    return .{ .applied = applied };
}

const RedirectionScope = enum {
    /// Redirections apply to the current shell only for the duration of one
    /// builtin, function, or compound command evaluation.
    current_scoped,
    /// Redirections are expected to become current-shell state, such as a
    /// successful `exec` redirection. Callers still own the commit decision.
    current_permanent,
    /// Redirections are applied only to prepare a child/subshell boundary and
    /// must be restored in the parent after launch/evaluation.
    child_only,

    fn validate(_: RedirectionScope) void {}
};

const RedirectionGuard = struct {
    scope: RedirectionScope,
    transaction: ?redirection_plan.FdTransaction,

    fn init(scope: RedirectionScope, transaction: redirection_plan.FdTransaction) RedirectionGuard {
        scope.validate();
        transaction.validateActive();
        return .{ .scope = scope, .transaction = transaction };
    }

    fn empty(scope: RedirectionScope) RedirectionGuard {
        scope.validate();
        return .{ .scope = scope, .transaction = null };
    }

    fn hasTransaction(self: RedirectionGuard) bool {
        self.scope.validate();
        return self.transaction != null;
    }

    fn restore(self: *RedirectionGuard) void {
        self.scope.validate();
        if (self.transaction) |*transaction| {
            transaction.restore();
            transaction.deinit();
            self.transaction = null;
        }
    }

    fn commitPermanent(self: *RedirectionGuard) void {
        self.scope.validate();
        std.debug.assert(self.scope == .current_permanent or self.scope == .current_scoped);
        if (self.transaction) |*transaction| {
            transaction.commit();
            transaction.deinit();
            self.transaction = null;
        }
    }

    fn disarmForScopedExec(self: *RedirectionGuard) redirection_plan.FdTransaction {
        self.scope.validate();
        std.debug.assert(self.scope == .current_scoped or self.scope == .current_permanent);
        var transaction = self.transaction orelse unreachable;
        self.transaction = null;
        transaction.validateActive();
        return transaction;
    }
};

const ScopedFrameFdRedirections = struct {
    snapshots: std.ArrayList(Snapshot) = .empty,

    const Snapshot = struct {
        descriptor: runtime.fd.Descriptor,
        endpoint: ?execution_frame.FdEndpoint,
    };

    fn apply(
        self: *ScopedFrameFdRedirections,
        allocator: std.mem.Allocator,
        frame: *execution_frame.ExecutionFrame,
        redirections: redirection_plan.RedirectionPlan,
    ) EvalError!void {
        frame.validate();
        redirections.validate();
        std.debug.assert(self.snapshots.items.len == 0);

        errdefer self.restore(allocator, frame);
        try self.bindUnboundStandardDescriptors(allocator, frame);
        for (redirections.steps) |step| {
            step.validate();
            try self.recordTarget(allocator, frame.*, step.target());
            try bindRuntimeScopedTarget(allocator, frame, step);
        }
        frame.validate();
    }

    fn bindUnboundStandardDescriptors(
        self: *ScopedFrameFdRedirections,
        allocator: std.mem.Allocator,
        frame: *execution_frame.ExecutionFrame,
    ) EvalError!void {
        frame.validate();
        if (frame.spec.fd_table.boundEndpoint(0) == null) {
            try self.recordTarget(allocator, frame.*, 0);
            try frame.spec.fd_table.bindInput(allocator, 0, frame.spec.stdin);
        }
        if (frame.spec.fd_table.boundEndpoint(1) == null) {
            try self.recordTarget(allocator, frame.*, 1);
            try frame.spec.fd_table.bindOutput(allocator, 1, frame.spec.stdout);
        }
        if (frame.spec.fd_table.boundEndpoint(2) == null) {
            try self.recordTarget(allocator, frame.*, 2);
            try frame.spec.fd_table.bindOutput(allocator, 2, frame.spec.stderr);
        }
    }

    fn bindRuntimeScopedTarget(
        allocator: std.mem.Allocator,
        frame: *execution_frame.ExecutionFrame,
        step: redirection_plan.RedirectionStep,
    ) EvalError!void {
        return bindRuntimeRedirectionTargetToFrame(allocator, frame, step);
    }

    fn restore(
        self: *ScopedFrameFdRedirections,
        allocator: std.mem.Allocator,
        frame: *execution_frame.ExecutionFrame,
    ) void {
        if (self.snapshots.items.len == 0) return;
        var index = self.snapshots.items.len;
        while (index != 0) {
            index -= 1;
            restoreFrameFdBinding(frame, self.snapshots.items[index]);
        }
        frame.spec.fd_table.bindings.shrinkAndFree(allocator, frame.spec.fd_table.bindings.items.len);
        self.snapshots.deinit(allocator);
        self.* = .{};
        frame.validate();
    }

    fn recordTarget(
        self: *ScopedFrameFdRedirections,
        allocator: std.mem.Allocator,
        frame: execution_frame.ExecutionFrame,
        descriptor: runtime.fd.Descriptor,
    ) std.mem.Allocator.Error!void {
        runtime.fd.assertValidDescriptor(descriptor);
        for (self.snapshots.items) |snapshot| {
            if (snapshot.descriptor == descriptor) return;
        }
        try self.snapshots.append(allocator, .{
            .descriptor = descriptor,
            .endpoint = frame.spec.fd_table.boundEndpoint(descriptor),
        });
    }
};

fn bindRuntimeRedirectionTargetToFrame(
    allocator: std.mem.Allocator,
    frame: *execution_frame.ExecutionFrame,
    step: redirection_plan.RedirectionStep,
) EvalError!void {
    frame.validate();
    step.validate();
    switch (step.effect) {
        .open_path => |open| switch (open.options.access) {
            .read_only => try frame.spec.fd_table.bindInput(allocator, open.target, .{ .fd = open.target }),
            .write_only, .read_write => try frame.spec.fd_table.bindOutput(
                allocator,
                open.target,
                .{ .fd = open.target },
            ),
        },
        .here_doc => |here_doc| try frame.spec.fd_table.bindInput(
            allocator,
            here_doc.target,
            .{ .fd = here_doc.target },
        ),
        .duplicate => |duplicate| switch (frame.spec.fd_table.endpoint(duplicate.source)) {
            .input => try frame.spec.fd_table.bindInput(allocator, duplicate.target, .{ .fd = duplicate.target }),
            .output => |output| if (duplicatedOutputStaysInSemanticCapture(output))
                try frame.spec.fd_table.bindOutput(allocator, duplicate.target, output)
            else
                try frame.spec.fd_table.bindOutput(allocator, duplicate.target, .{ .fd = duplicate.target }),
            .closed => try frame.spec.fd_table.close(allocator, duplicate.target),
        },
        .close => |close_step| try frame.spec.fd_table.close(allocator, close_step.target),
    }
}

fn duplicatedOutputStaysInSemanticCapture(output: execution_frame.OutputEndpoint) bool {
    output.validate();
    return switch (output) {
        .capture => |channel| !channel.isParentVisible(),
        .inherit_stdout,
        .inherit_stderr,
        .path,
        .fd,
        .pipe_write,
        .discard,
        => false,
    };
}

fn restoreFrameFdBinding(frame: *execution_frame.ExecutionFrame, snapshot: ScopedFrameFdRedirections.Snapshot) void {
    runtime.fd.assertValidDescriptor(snapshot.descriptor);
    const binding_index = frameFdBindingIndex(frame.spec.fd_table, snapshot.descriptor);
    if (snapshot.endpoint) |endpoint| {
        endpoint.validate();
        const index = binding_index orelse unreachable;
        frame.spec.fd_table.bindings.items[index] = .{ .descriptor = snapshot.descriptor, .endpoint = endpoint };
    } else if (binding_index) |index| {
        _ = frame.spec.fd_table.bindings.orderedRemove(index);
    }
}

fn frameFdBindingIndex(table: execution_frame.FdTable, descriptor: runtime.fd.Descriptor) ?usize {
    runtime.fd.assertValidDescriptor(descriptor);
    for (table.bindings.items, 0..) |binding, index| {
        if (binding.descriptor == descriptor) return index;
    }
    return null;
}

const RedirectionGuardResult = union(enum) {
    applied: RedirectionGuard,
    failure: redirection_plan.ApplyFailure,
};

fn applyRedirectionsForScope(
    evaluator: Evaluator,
    buffers: *EvaluationBuffers,
    scope: RedirectionScope,
    already_applied: redirection_plan.RedirectionPlan,
    redirections: redirection_plan.RedirectionPlan,
    mode: RedirectionExpansionOutputMode,
    diagnostic_command_name: ?[]const u8,
) EvalError!RedirectionGuardResult {
    scope.validate();
    const apply_result = try applyRedirectionsEmittingExpansionOutput(
        evaluator,
        buffers,
        scope,
        already_applied,
        redirections,
        mode,
        diagnostic_command_name,
    );
    return switch (apply_result) {
        .applied => |applied| .{ .applied = RedirectionGuard.init(scope, applied) },
        .failure => |failure| .{ .failure = failure },
    };
}

fn diagnosticDestinationIsWritable(destination: OutputDestination) bool {
    destination.validate();
    return switch (destination) {
        .closed => false,
        .host_descriptor => |descriptor| descriptorIsOpen(descriptor),
        .outcome_stdout_capture,
        .outcome_stderr_capture,
        .side_stdout_capture,
        .command_substitution_side_stdout_capture,
        .pipeline_data_capture,
        .command_substitution_stdout_capture,
        .command_substitution_stderr_capture,
        => true,
    };
}

fn applyOutputRoutingRedirections(
    evaluator: Evaluator,
    routing: *OutputRouting,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    return applyOutputRoutingScopedRedirections(evaluator.scoped_exec_redirections, routing, redirections);
}

fn applyOutputRoutingScopedRedirections(
    scoped_redirections: ?*std.ArrayList(ScopedExecRedirection),
    routing: *OutputRouting,
    redirections: redirection_plan.RedirectionPlan,
) EvalError!void {
    redirections.validate();
    if (scoped_redirections) |scoped_redirection_list| {
        for (scoped_redirection_list.items) |scoped| {
            try routing.applyRedirections(scoped.redirections);
        }
    }
    try routing.applyRedirections(redirections);
}

const OutputStream = enum { stdout, stderr };

const RoutedOutputPrefix = struct {
    stdout: usize = 0,
    stderr: usize = 0,

    fn validate(self: RoutedOutputPrefix, buffers: EvaluationBuffers) void {
        std.debug.assert(self.stdout <= buffers.stdout.items.len);
        std.debug.assert(self.stderr <= buffers.stderr.items.len);
    }
};

fn commandExpansionOutputFrame(
    evaluator: Evaluator,
    eval_context: context.EvalContext,
    buffers: *EvaluationBuffers,
) EvalError!OutputFrame {
    eval_context.validate();
    const use_active_frame_routing = frameHasNonDefaultStandardOutputRouting(buffers.frame.*);
    var frame = if (use_active_frame_routing)
        try activeFrameOutputFrameForExpansion(evaluator.allocator, eval_context, buffers)
    else if (eval_context.command_substitution_depth != 0)
        OutputFrame.initCommandSubstitution(buffers)
    else if (eval_context.pipeline_depth != 0)
        OutputFrame.initInherited(buffers)
    else
        OutputFrame.initOutcomeCapture(buffers);
    errdefer frame.deinit();
    if (!use_active_frame_routing) try applyOutputRoutingRedirections(evaluator, &frame.routing, .{});
    return frame;
}

fn activeFrameOutputFrameForExpansion(
    allocator: std.mem.Allocator,
    eval_context: context.EvalContext,
    buffers: *EvaluationBuffers,
) EvalError!OutputFrame {
    eval_context.validate();
    buffers.frame.validate();
    var routing = OutputRouting.init(allocator, .outcome_capture);
    errdefer routing.deinit();
    const command_substitution_context = eval_context.command_substitution_depth != 0 or
        frameWithinCommandSubstitution(buffers.frame.*);
    try routing.setDestination(
        1,
        outputDestinationForFrameEndpointInContext(
            1,
            buffers.frame.spec.fd_table.endpoint(1),
            command_substitution_context,
            buffers.preserve_parent_visible_stdout_capture,
        ),
    );
    try routing.setDestination(
        2,
        outputDestinationForFrameEndpointInContext(
            2,
            buffers.frame.spec.fd_table.endpoint(2),
            command_substitution_context,
            buffers.preserve_parent_visible_stdout_capture,
        ),
    );
    return OutputFrame.initOwnedRouting(buffers, routing);
}

fn frameHasNonDefaultStandardOutputRouting(frame: execution_frame.ExecutionFrame) bool {
    frame.validate();
    return !std.meta.eql(frame.spec.fd_table.endpoint(1), defaultFrameEndpoint(1)) or
        !std.meta.eql(frame.spec.fd_table.endpoint(2), defaultFrameEndpoint(2));
}

fn appendPlanExpansionOutput(
    evaluator: Evaluator,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    buffers: *EvaluationBuffers,
) !void {
    plan.validate();
    try appendExpansionOutput(evaluator, eval_context, plan.expansion_output, buffers);
}

fn appendExpansionOutput(
    evaluator: Evaluator,
    eval_context: context.EvalContext,
    output: command_plan.ExpansionOutput,
    buffers: *EvaluationBuffers,
) !void {
    output.validate();
    var frame = try commandExpansionOutputFrame(evaluator, eval_context, buffers);
    defer frame.deinit();
    if (output.side_stdout.len != 0) {
        if (eval_context.command_substitution_depth != 0 or frameWithinCommandSubstitution(buffers.frame.*)) {
            if (frameHasNonstandardPipelineCapture(buffers.frame.*)) {
                try buffers.side_stdout.appendSlice(buffers.allocator, output.side_stdout);
            } else {
                try buffers.stdout.appendSlice(buffers.allocator, output.side_stdout);
            }
        } else {
            try frame.write(1, output.side_stdout);
        }
    }
    if (output.stderr.len != 0) try frame.write(2, output.stderr);
    for (output.diagnostics) |message| {
        try buffers.addDiagnosticMessage(message);
    }
}

fn frameHasNonstandardPipelineCapture(frame: execution_frame.ExecutionFrame) bool {
    frame.validate();
    for (frame.spec.fd_table.bindings.items) |binding| {
        binding.validate();
        if (binding.descriptor == 1 or binding.descriptor == 2) continue;
        if (frameOutputEndpointCaptures(binding.endpoint, .pipeline_data)) return true;
    }
    return false;
}

fn appendRedirectionExpansionOutputToFrame(
    output: redirection_plan.ExpansionOutput,
    frame: *OutputFrame,
) !void {
    output.validate();
    if (output.stderr.bytes.len != 0) try frame.write(2, output.stderr.bytes);
    for (output.diagnostics) |diagnostic| {
        try frame.buffers.addDiagnosticMessage(diagnostic.bytes);
    }
}

pub fn evaluateCompoundPlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CompoundCommandPlan,
) EvalError!outcome.CommandOutcome {
    var input = EvaluationInput.empty();
    var frame = rootExecutionFrame(eval_context);
    return evaluateCompoundPlanWithInput(evaluator, shell_state, eval_context, plan, &input, &frame);
}

fn evaluateCompoundPlanWithInput(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CompoundCommandPlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    input.validate();
    frame.validate();
    std.debug.assert(plan.target == eval_context.target);
    if (plan.target == .current_shell) std.debug.assert(shell_state.acceptsExecutionTarget(.current_shell));

    var state_delta = delta.StateDelta.init(evaluator.allocator, plan.target);
    errdefer state_delta.deinit();

    var command_frame = try semanticCommandExecutionFrame(
        evaluator.allocator,
        evaluator.scoped_exec_redirections,
        frame,
        plan.target,
        plan.redirections,
    );
    defer command_frame.spec.fd_table.deinit(evaluator.allocator);
    const active_frame = if (compoundBodyUsesParentFrame(plan)) frame else &command_frame;
    var frame_input = EvaluationInput.empty();
    var buffers = EvaluationBuffers.init(
        evaluator.allocator,
        input,
        active_frame,
    );
    defer buffers.deinit();
    buffers.useFrameFdTableInput(&frame_input, input);
    var cwd_guard: CwdGuard = .{};
    if (plan.target.isIsolatedFromParent()) cwd_guard.capture(evaluator);
    defer cwd_guard.restore();

    var scoped_exec_redirections: std.ArrayList(ScopedExecRedirection) = .empty;
    defer scoped_exec_redirections.deinit(evaluator.allocator);
    const previous_scoped_exec_redirections = evaluator.scoped_exec_redirections;
    const owns_scoped_exec_redirections = compoundPlanOwnsScopedExecRedirections(eval_context, plan);
    if (owns_scoped_exec_redirections) {
        errdefer restoreScopedExecRedirections(&scoped_exec_redirections);
        try inheritScopedExecRedirections(
            evaluator.allocator,
            &scoped_exec_redirections,
            previous_scoped_exec_redirections,
        );
        evaluator.scoped_exec_redirections = &scoped_exec_redirections;
    }
    defer if (owns_scoped_exec_redirections) {
        restoreScopedExecRedirections(&scoped_exec_redirections);
        evaluator.scoped_exec_redirections = previous_scoped_exec_redirections;
    };

    var redirection_guard = RedirectionGuard.empty(.current_scoped);
    defer redirection_guard.restore();
    var frame_redirection_guard: ScopedFrameFdRedirections = .{};
    defer frame_redirection_guard.restore(evaluator.allocator, active_frame);
    var redirection_output_flushed = false;
    if (hasCompoundRedirections(plan)) {
        if (frameRoutesPipelineData(command_frame) and !redirectionPlanNeedsRuntimeFdEffects(plan.redirections)) {
            try emitSemanticRedirectionTransforms(evaluator.*, &buffers, plan.redirections);
        } else {
            const apply_result = try applyRedirectionsForScope(
                evaluator.*,
                &buffers,
                .current_scoped,
                .{},
                plan.redirections,
                redirectionExpansionModeForContext(eval_context),
                plan.kindName(),
            );
            switch (apply_result) {
                .applied => |applied| {
                    redirection_guard = applied;
                    if (compoundBodyUsesParentFrame(plan)) {
                        try frame_redirection_guard.apply(evaluator.allocator, active_frame, plan.redirections);
                    }
                },
                .failure => |failure| {
                    const status = consequence.statusForRedirectionFailure(failure.consequence);
                    const decision = consequence.decideForRedirectionFailure(
                        shell_state.options,
                        eval_context,
                        failure.consequence,
                        status,
                    );
                    try addRedirectionFailureDiagnostic(&buffers, plan.kindName(), failure);
                    state_delta.setLastStatus(status);
                    return try commandOutcomeFromBuffers(
                        evaluator.allocator,
                        eval_context,
                        status,
                        state_delta,
                        decision.control_flow,
                        &buffers,
                    );
                },
            }
        }
    }
    if (eval_context.command_substitution_depth != 0 and redirection_guard.hasTransaction()) {
        try flushBufferedRedirectionOutput(evaluator.*, &buffers, plan.redirections, eval_context, .{});
        redirection_output_flushed = true;
    }

    var working_state = try workingStateForCompound(evaluator.allocator, shell_state.*, plan.target);
    defer working_state.deinit();

    var result = try evaluateCompoundBody(evaluator, &working_state, eval_context, plan.body, &buffers);
    if (plan.body == .subshell) {
        try appendSubshellExitTrap(
            evaluator,
            &working_state,
            eval_context,
            &result,
            &buffers,
        );
    }
    if (plan.target.isIsolatedFromParent()) {
        result.status = result.control_flow.status(result.status);
        if (buffers.propagated_failure) |propagated_failure| {
            result.status = propagated_failure.status();
            result.control_flow = propagated_failure.controlFlow();
        } else {
            result.control_flow = .normal;
        }
    }

    if (plan.target.allowsShellStateCommit()) try appendShellStateDiff(shell_state.*, working_state, &state_delta);
    state_delta.setLastStatus(result.status);

    if (!compoundBodySuppressesFinalErrexit(plan.body)) {
        const decision = consequence.decideForCompoundCommand(
            working_state.options,
            eval_context,
            result.status,
            result.control_flow,
        );
        result.control_flow = decision.control_flow;
    }

    if (redirection_guard.hasTransaction() and !redirection_output_flushed) {
        try flushBufferedRedirectionOutput(evaluator.*, &buffers, plan.redirections, eval_context, .{});
    }
    if (plan.target.isIsolatedFromParent()) try flushChildShellBufferedCommandOutput(&buffers, eval_context);
    if (frameRoutesCapturedOutput(active_frame.*) and eval_context.command_substitution_depth == 0 and
        eval_context.pipeline_depth != 0)
    {
        try routeDirectPipelineStageBuffers(&buffers);
    }

    return commandOutcomeFromBuffers(
        evaluator.allocator,
        eval_context,
        result.status,
        state_delta,
        result.control_flow,
        &buffers,
    );
}

fn compoundBodyUsesParentFrame(plan: command_plan.CompoundCommandPlan) bool {
    plan.validate();
    if (!plan.target.allowsShellStateCommit()) return false;
    return switch (plan.body) {
        .sequence, .brace_group => true,
        .and_or_list,
        .negation,
        .if_clause,
        .while_loop,
        .until_loop,
        .for_loop,
        .case_clause,
        .subshell,
        => false,
    };
}

pub fn evaluatePipelinePlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
) EvalError!outcome.CommandOutcome {
    var frame = rootExecutionFrame(eval_context);
    return evaluatePipelinePlanWithFrame(evaluator, shell_state, eval_context, plan, &frame);
}

fn evaluatePipelinePlanWithFrame(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    frame.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));

    if (plan.strategy == .background_deferred) return evaluateBackgroundPipelinePlan(
        evaluator,
        shell_state,
        eval_context,
        plan,
    );

    var input = EvaluationInput.empty();
    var buffers = EvaluationBuffers.init(evaluator.allocator, &input, frame);
    defer buffers.deinit();

    const statuses = try evaluator.allocator.alloc(outcome.ExitStatus, plan.stages.len);
    defer evaluator.allocator.free(statuses);

    var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);

    if (plan.strategy == .single_stage) {
        state_delta = try evaluateSingleStagePipeline(evaluator, shell_state, eval_context, plan, statuses, &buffers);
    } else switch (plan.strategy) {
        .external_only_real => if (capturedExternalMode(evaluator.external_stdio) != null or
            pipelineHasExpansionOutput(plan))
            try evaluateFallbackPipeline(evaluator, shell_state.*, eval_context, plan, statuses, &buffers)
        else
            try evaluateExternalOnlyRealPipeline(evaluator, shell_state.*, eval_context, plan, statuses, &buffers),
        .semantic_in_memory, .mixed_in_memory => try evaluateFallbackPipeline(
            evaluator,
            shell_state.*,
            eval_context,
            plan,
            statuses,
            &buffers,
        ),
        .single_stage, .background_deferred => unreachable,
    }

    return finishPipelineOutcome(
        evaluator.allocator,
        shell_state.options,
        eval_context,
        plan,
        statuses,
        state_delta,
        &buffers,
    );
}

pub fn configureRuntimeTrapSignal(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    signal: state.TrapSignal,
) EvalError!void {
    shell_state.validate();
    signal.validate();
    const signal_number = signal.runtimeNumber() orelse return;
    const signal_port = evaluator.signal_port orelse return error.Unimplemented;
    const disposition = runtimeDispositionForTrapDisposition(shell_state.trapDisposition(signal));
    signal_port.configure(.{ .signal = signal_number, .disposition = disposition }) catch |err| switch (err) {
        error.Unsupported, error.Unexpected => return error.Unimplemented,
    };
}

pub fn observeRuntimeSignal(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
) EvalError!?RuntimeSignalObservation {
    shell_state.validate();
    eval_context.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));

    const signal_port = evaluator.signal_port orelse return error.Unimplemented;
    const event = signal_port.poll() catch |err| switch (err) {
        error.Unsupported, error.Unexpected => return error.Unimplemented,
    } orelse return null;
    event.validate();
    const signal = state.TrapSignal.fromRuntimeNumber(event.signal) orelse return error.Unimplemented;

    var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);
    errdefer state_delta.deinit();
    const delivery = try state_delta.appendSignalDelivery(shell_state.*, signal);
    const status = switch (delivery) {
        .default_action => signal.defaultExitStatus().?,
        .ignored, .queued => shell_state.last_status,
    };
    const control_flow: outcome.ControlFlow = switch (delivery) {
        .default_action => .{ .exit = status },
        .ignored, .queued => .normal,
    };
    if (delivery == .default_action) state_delta.setLastStatus(status);

    var command_outcome = outcome.CommandOutcome.withControlFlow(
        evaluator.allocator,
        status,
        state_delta,
        control_flow,
    );
    command_outcome.validateForContext(eval_context);
    const observation: RuntimeSignalObservation = .{
        .signal = signal,
        .delivery = delivery,
        .command_outcome = command_outcome,
    };
    observation.validate(eval_context);
    return observation;
}

pub fn drainJobNotifications(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));

    var refreshed_state = try refreshedBackgroundJobState(evaluator, shell_state.*, null);
    defer refreshed_state.deinit();

    var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);
    errdefer state_delta.deinit();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(evaluator.allocator);
    var notified_done_ids: std.ArrayList(usize) = .empty;
    defer notified_done_ids.deinit(evaluator.allocator);

    for (refreshed_state.pending_job_notifications.items) |notification| {
        try appendJobNotificationLine(evaluator.allocator, &output, notification);
        if (notification.state == .done) try notified_done_ids.append(evaluator.allocator, notification.job_id);
    }
    const consumed_count = refreshed_state.pending_job_notifications.items.len;
    if (consumed_count != 0) refreshed_state.consumeJobNotifications(consumed_count);
    for (notified_done_ids.items) |id| {
        if (refreshed_state.findBackgroundJobById(id) != null) refreshed_state.removeBackgroundJobById(id);
    }
    try appendJobTableDiff(shell_state.*, refreshed_state, &state_delta);

    var command_outcome = outcome.CommandOutcome.init(evaluator.allocator, shell_state.last_status, state_delta);
    errdefer command_outcome.deinit();
    command_outcome.stdout = output;
    command_outcome.validateForContext(eval_context);
    return command_outcome;
}

pub fn executePendingTraps(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    resolver: TrapActionResolver,
) EvalError!?outcome.CommandOutcome {
    var frame = rootExecutionFrame(eval_context);
    defer frame.spec.fd_table.deinit(evaluator.allocator);
    try frame.spec.fd_table.bindOutput(evaluator.allocator, 1, .{ .capture = .side_stdout });
    try frame.spec.fd_table.bindOutput(evaluator.allocator, 2, .{ .capture = .side_stderr });
    frame.spec.stdout = .{ .capture = .side_stdout };
    frame.spec.stderr = .{ .capture = .side_stderr };
    frame.spec.captures = captureSet(.side_stdout, .side_stderr);
    frame.validate();
    return executePendingTrapsWithFrame(evaluator, shell_state, eval_context, resolver, &frame);
}

fn executePendingTrapsWithFrame(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    resolver: TrapActionResolver,
    parent_frame: *execution_frame.ExecutionFrame,
) EvalError!?outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    resolver.validate();
    parent_frame.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));
    std.debug.assert(shell_state.trap_execution == .idle);

    if (shell_state.pending_traps.items.len == 0) {
        const pending_exit = shell_state.pending_exit orelse return null;
        var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);
        errdefer state_delta.deinit();
        state_delta.clearPendingExit();
        state_delta.setLastStatus(pending_exit);
        var command_outcome = outcome.CommandOutcome.withControlFlow(
            evaluator.allocator,
            pending_exit,
            state_delta,
            .{ .exit = pending_exit },
        );
        command_outcome.validateForContext(eval_context);
        return command_outcome;
    }

    shell_state.beginTrapExecution();
    defer shell_state.endTrapExecution();

    var working_state = shell_state.clone(evaluator.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer working_state.deinit();

    var trap_frame = try trapHandlerExecutionFrame(evaluator.allocator, parent_frame, eval_context.target);
    defer trap_frame.spec.fd_table.deinit(evaluator.allocator);
    try inheritScopedExecRedirectionsIntoTrapFrame(evaluator.*, &trap_frame);
    var input = EvaluationInput.empty();
    var buffers = EvaluationBuffers.init(evaluator.allocator, &input, &trap_frame);
    buffers.fold_side_stdout_to_stdout = true;
    defer buffers.deinit();
    const pending_count = shell_state.pending_traps.items.len;
    const preserved_status = shell_state.last_status;
    var result: SimpleEvalResult = .{ .status = preserved_status };

    for (shell_state.pending_traps.items[0..pending_count]) |signal| {
        signal.validate();
        const registered = shell_state.getTrapForSignal(signal) orelse continue;
        registered.validate();
        if (registered.kind() == .ignore) continue;

        var alias_snapshot = working_state.clone(evaluator.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadonlyVariable => unreachable,
        };
        defer alias_snapshot.deinit();

        const previous_alias_state = evaluator.alias_state;
        evaluator.alias_state = &alias_snapshot;
        defer evaluator.alias_state = previous_alias_state;

        var body = (resolver.resolve(
            evaluator.allocator,
            registered.action,
            signal,
            eval_context,
            &working_state,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unimplemented,
        }) orelse return error.Unimplemented;
        defer body.deinit();
        var action_outcome = try evaluateTrapActionBody(evaluator, &working_state, eval_context, body, &trap_frame);
        defer action_outcome.deinit();

        try appendOutcomeBuffers(&buffers, action_outcome);
        try applyOutcomeToWorkingState(&working_state, &action_outcome, action_outcome.state_delta.target);
        const action_control_flow = if (interactiveSubshellExitTrapActionEndsWithExit(
            signal,
            eval_context,
            registered.action,
            body,
        ))
            outcome.ControlFlow{ .exit = action_outcome.status }
        else
            action_outcome.effectiveControlFlow();
        result = .{ .status = action_outcome.status, .control_flow = action_control_flow };
        if (action_control_flow != .normal) break;
    }

    var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);
    errdefer state_delta.deinit();
    try appendShellStateDiff(shell_state.*, working_state, &state_delta);
    state_delta.consumePendingTraps(pending_count);

    var control_flow = result.control_flow;
    var status = if (control_flow == .normal) preserved_status else control_flow.status(result.status);
    if (control_flow == .normal) {
        if (shell_state.pending_exit) |pending_exit| {
            status = pending_exit;
            control_flow = .{ .exit = pending_exit };
            state_delta.clearPendingExit();
        }
    } else if (shell_state.pending_exit != null) {
        state_delta.clearPendingExit();
    }
    state_delta.setLastStatus(status);

    return try commandOutcomeFromBuffers(
        evaluator.allocator,
        eval_context,
        status,
        state_delta,
        control_flow,
        &buffers,
    );
}

fn interactiveSubshellExitTrapActionEndsWithExit(
    signal: state.TrapSignal,
    eval_context: context.EvalContext,
    action: []const u8,
    body: TrapActionBody,
) bool {
    signal.validate();
    eval_context.validate();
    std.debug.assert(std.mem.indexOfScalar(u8, action, 0) == null);
    body.validate();
    if (signal != .EXIT) return false;
    if (!eval_context.interactive) return false;
    if (eval_context.target != .subshell) return false;
    if (sourceTextStartsWithExit(action)) return true;
    return trapActionBodyPayloadEndsWithTopLevelExit(switch (body) {
        .simple => |plan| .{ .simple = plan },
        .compound => |plan| .{ .compound = plan },
        .pipeline => |plan| .{ .pipeline = plan },
        .failure => |failure| .{ .failure = failure },
        .owned => |owned| owned.body,
    });
}

fn trapActionBodyPayloadEndsWithTopLevelExit(body: TrapActionBodyPayload) bool {
    body.validate();
    return switch (body) {
        .simple => |plan| simplePlanIsExit(plan),
        .compound => |plan| compoundPlanEndsWithTopLevelExit(plan),
        .pipeline, .failure => false,
    };
}

fn compoundPlanEndsWithTopLevelExit(plan: command_plan.CompoundCommandPlan) bool {
    plan.validate();
    return switch (plan.body) {
        .sequence, .brace_group => |list| statementListEndsWithTopLevelExit(list),
        .and_or_list => |and_or| andOrPlanEndsWithTopLevelExit(and_or),
        .negation => |negation| statementListEndsWithTopLevelExit(negation.body),
        .if_clause => |if_plan| ifPlanMayEndWithTopLevelExit(if_plan),
        .while_loop, .until_loop => |loop| statementListEndsWithTopLevelExit(loop.body),
        .for_loop => |for_plan| statementListEndsWithTopLevelExit(for_plan.body),
        .case_clause => |case_plan| casePlanMayEndWithTopLevelExit(case_plan),
        .subshell => false,
    };
}

fn andOrPlanEndsWithTopLevelExit(plan: command_plan.AndOrPlan) bool {
    plan.validate();
    if (plan.commands.len == 0) return false;
    return simplePlanIsExit(plan.commands[plan.commands.len - 1].command);
}

fn ifPlanMayEndWithTopLevelExit(plan: command_plan.IfPlan) bool {
    plan.validate();
    for (plan.branches) |branch| {
        if (statementListEndsWithTopLevelExit(branch.body)) return true;
    }
    return statementListEndsWithTopLevelExit(plan.else_body);
}

fn casePlanMayEndWithTopLevelExit(plan: command_plan.CasePlan) bool {
    plan.validate();
    for (plan.arms) |arm| {
        if (statementListEndsWithTopLevelExit(arm.body)) return true;
    }
    return false;
}

fn statementListEndsWithTopLevelExit(list: command_plan.StatementList) bool {
    list.validate();
    if (list.commands.len != 0) return simplePlanIsExit(list.commands[list.commands.len - 1]);
    if (list.statements.len == 0) return false;
    return statementPlanIsExit(list.statements[list.statements.len - 1].plan);
}

fn statementPlanIsExit(plan: command_plan.StatementPlan) bool {
    plan.validate();
    return switch (plan) {
        .simple => |simple| simplePlanIsExit(simple),
        .compound => |compound| compoundPlanEndsWithTopLevelExit(compound),
        .source => |source| sourceTextStartsWithExit(source.source),
        .ir_source => |source| sourceTextStartsWithExit(source.fallback_source),
        else => false,
    };
}

fn simplePlanIsExit(plan: command_plan.CommandPlan) bool {
    plan.validate();
    return plan.argv.len != 0 and std.mem.eql(u8, plan.argv[0], "exit");
}

fn sourceTextStartsWithExit(source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, &std.ascii.whitespace);
    if (sourceWordAtOffsetIsExit(trimmed, 0)) return true;
    var index: usize = 0;
    while (findUnquotedSeparator(trimmed, index, ';')) |separator| {
        var command_start = separator + 1;
        while (command_start < trimmed.len and std.ascii.isWhitespace(trimmed[command_start])) command_start += 1;
        if (sourceWordAtOffsetIsExit(trimmed, command_start)) return true;
        index = separator + 1;
    }
    return false;
}

fn sourceWordAtOffsetIsExit(source: []const u8, offset: usize) bool {
    if (offset > source.len) return false;
    const rest = source[offset..];
    if (!std.mem.startsWith(u8, rest, "exit")) return false;
    if (rest.len == "exit".len) return true;
    return std.ascii.isWhitespace(rest["exit".len]);
}

fn findUnquotedSeparator(source: []const u8, start: usize, separator: u8) ?usize {
    var index = start;
    var quote: ?u8 = null;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (quote) |active| {
            if (active == '"' and byte == '\\') {
                index += 1;
                continue;
            }
            if (byte == active) quote = null;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '\\' => index += 1,
            else => if (byte == separator) return index,
        }
    }
    return null;
}

fn trapHandlerExecutionFrame(
    allocator: std.mem.Allocator,
    parent_frame: *execution_frame.ExecutionFrame,
    target: context.ExecutionTarget,
) EvalError!execution_frame.ExecutionFrame {
    parent_frame.validate();
    std.debug.assert(target.allowsShellStateCommit());
    var fd_table = try parent_frame.spec.fd_table.clone(allocator);
    errdefer fd_table.deinit(allocator);
    const spec: execution_frame.BoundarySpec = .{
        .kind = .trap_handler,
        .eval_target = target,
        .stdin = parent_frame.spec.stdin,
        .stdout = parent_frame.spec.stdout,
        .stderr = parent_frame.spec.stderr,
        .fd_table = fd_table,
        .captures = parent_frame.spec.captures,
        .mutation_policy = if (target == .current_shell) .commit_to_parent_shell else .commit_within_subshell,
        .trap_policy = .isolated_child,
        .failure_policy = .propagate_fatal_to_parent,
    };
    return parent_frame.child(spec);
}

fn inheritScopedExecRedirectionsIntoTrapFrame(
    evaluator: Evaluator,
    trap_frame: *execution_frame.ExecutionFrame,
) EvalError!void {
    trap_frame.validate();
    const scoped_redirections = evaluator.scoped_exec_redirections orelse return;
    for (scoped_redirections.items) |scoped| {
        try trap_frame.spec.fd_table.applyRedirectionPlan(evaluator.allocator, scoped.redirections);
    }
    trap_frame.validate();
}

fn configureRuntimeTrapMutations(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    state_delta: delta.StateDelta,
) EvalError!void {
    shell_state.validate();
    if (!state_delta.target.allowsShellStateCommit()) return;
    if (!shell_state.acceptsExecutionTarget(state_delta.target)) return;
    if (evaluator.signal_port == null) return;

    for (state_delta.trap_mutations.items) |mutation| {
        const signal = state.TrapSignal.fromName(mutation.name) orelse continue;
        if (!signal.isRuntimeSignal()) continue;
        try configureRuntimeTrapSignal(evaluator, shell_state, signal);
    }
}

fn runCurrentShellRuntimeTrapBoundary(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    buffers: *EvaluationBuffers,
) EvalError!?SimpleEvalResult {
    shell_state.validate();
    eval_context.validate();
    if (eval_context.target != .current_shell) return null;
    if (!shell_state.acceptsExecutionTarget(.current_shell)) return null;
    if (shell_state.trap_execution != .idle) return null;

    if (evaluator.signal_port != null) {
        if (try observeRuntimeSignal(evaluator, shell_state, eval_context)) |observed| {
            var observation = observed;
            defer observation.deinit();
            try appendOutcomeBuffers(buffers, observation.command_outcome);
            try applyOutcomeToWorkingState(
                shell_state,
                &observation.command_outcome,
                observation.command_outcome.state_delta.target,
            );
            const signal_control_flow = observation.command_outcome.effectiveControlFlow();
            if (signal_control_flow != .normal) {
                return .{ .status = observation.command_outcome.status, .control_flow = signal_control_flow };
            }
        }
    }

    if (shell_state.pending_traps.items.len == 0 and shell_state.pending_exit == null) return null;

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = buffers.frame;
    parser_resolver.active_input = buffers.stdin;
    var trap_outcome = (try executePendingTrapsWithFrame(
        evaluator,
        shell_state,
        eval_context,
        parser_resolver.resolver(),
        buffers.frame,
    )) orelse return null;
    defer trap_outcome.deinit();

    try appendOutcomeBuffers(buffers, trap_outcome);
    try applyOutcomeToWorkingState(shell_state, &trap_outcome, trap_outcome.state_delta.target);
    return .{ .status = trap_outcome.status, .control_flow = trap_outcome.effectiveControlFlow() };
}

pub fn evaluateCommandSubstitution(
    evaluator: *Evaluator,
    parent_state: *state.ShellState,
    parent_context: context.EvalContext,
    body: CommandSubstitutionBody,
) EvalError!CommandSubstitutionResult {
    parent_state.validate();
    parent_context.validate();
    body.validate();
    const substitution_context = parent_context.enterCommandSubstitution();
    return evaluateCommandSubstitutionSnapshot(evaluator, parent_state, substitution_context, body);
}

fn evaluateCommandSubstitutionSnapshot(
    evaluator: *Evaluator,
    parent_state: *state.ShellState,
    substitution_context: context.EvalContext,
    body: CommandSubstitutionBody,
) EvalError!CommandSubstitutionResult {
    parent_state.validate();
    substitution_context.validate();
    assertCommandSubstitutionContext(substitution_context);
    body.validate();
    const parent_fingerprint = shellStateMutationFingerprint(parent_state.*);
    defer std.debug.assert(shellStateMutationFingerprint(parent_state.*) == parent_fingerprint);

    var substitution_state = parent_state.snapshotForSubshell(evaluator.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer substitution_state.deinit();
    if (evaluator.features.isBash()) substitution_state.options.set(.errexit, false);

    var parent_frame = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    return evaluateCommandSubstitutionInState(
        evaluator,
        &substitution_state,
        substitution_context,
        body,
        null,
        &parent_frame,
        null,
    );
}

fn evaluateCommandSubstitutionInState(
    evaluator: *Evaluator,
    substitution_state: *state.ShellState,
    substitution_context: context.EvalContext,
    body: CommandSubstitutionBody,
    exit_trap_resolver: ?TrapActionResolver,
    parent_frame: *execution_frame.ExecutionFrame,
    parent_input: ?*EvaluationInput,
) EvalError!CommandSubstitutionResult {
    substitution_state.validate();
    substitution_context.validate();
    assertCommandSubstitutionContext(substitution_context);
    std.debug.assert(substitution_state.acceptsExecutionTarget(.subshell));
    body.validate();
    if (exit_trap_resolver) |resolver| resolver.validate();
    parent_frame.validate();
    if (parent_input) |input| input.validate();

    const previous_external_stdio = evaluator.external_stdio;
    evaluator.external_stdio = .capture;
    defer evaluator.external_stdio = previous_external_stdio;

    var scoped_exec_redirections: std.ArrayList(ScopedExecRedirection) = .empty;
    defer scoped_exec_redirections.deinit(evaluator.allocator);
    const previous_scoped_exec_redirections = evaluator.scoped_exec_redirections;
    evaluator.scoped_exec_redirections = &scoped_exec_redirections;
    defer {
        restoreScopedExecRedirections(&scoped_exec_redirections);
        evaluator.scoped_exec_redirections = previous_scoped_exec_redirections;
    }

    var cwd_guard: CwdGuard = .{};
    cwd_guard.capture(evaluator);
    defer cwd_guard.restore();

    var substitution_frame = try commandSubstitutionExecutionFrame(
        evaluator.allocator,
        evaluator.scoped_exec_redirections,
        parent_frame,
    );
    defer substitution_frame.spec.fd_table.deinit(evaluator.allocator);
    var body_outcome = try evaluateCommandSubstitutionBody(
        evaluator,
        substitution_state,
        substitution_context,
        body,
        parent_input,
        &substitution_frame,
    );
    defer body_outcome.deinit();

    var visible_status = body_outcome.control_flow.status(body_outcome.status);
    if (!commandSubstitutionBodyIsExplicitSubshell(body)) {
        try applyCommandSubstitutionOutcome(substitution_state, &body_outcome);
    }
    if (exit_trap_resolver) |resolver| try appendCommandSubstitutionExitTrap(
        evaluator,
        substitution_state,
        substitution_context,
        &body_outcome,
        &visible_status,
        resolver,
        &substitution_frame,
    );
    const result = try commandSubstitutionResultFromOutcome(
        evaluator.allocator,
        substitution_context.command_substitution_depth,
        substitution_context.command_substitution_depth == 1 and !frameRoutesPipelineData(parent_frame.*),
        visible_status,
        body_outcome,
    );
    result.validate();
    return result;
}

fn commandSubstitutionBodyIsExplicitSubshell(body: CommandSubstitutionBody) bool {
    body.validate();
    return switch (body) {
        .compound => |plan| plan.body == .subshell,
        .owned => |owned| commandSubstitutionBodyPayloadIsExplicitSubshell(owned.body),
        .simple, .pipeline, .failure => false,
    };
}

fn commandSubstitutionBodyPayloadIsExplicitSubshell(body: CommandSubstitutionBodyPayload) bool {
    body.validate();
    return switch (body) {
        .compound => |plan| plan.body == .subshell,
        .simple, .pipeline, .failure => false,
    };
}

fn restoreScopedExecRedirections(scoped_redirections: *std.ArrayList(ScopedExecRedirection)) void {
    var index = scoped_redirections.items.len;
    while (index != 0) {
        index -= 1;
        scoped_redirections.items[index].restoreAndDeinit();
    }
    scoped_redirections.clearRetainingCapacity();
}

fn appendCommandSubstitutionExitTrap(
    evaluator: *Evaluator,
    substitution_state: *state.ShellState,
    substitution_context: context.EvalContext,
    command_outcome: *outcome.CommandOutcome,
    visible_status: *outcome.ExitStatus,
    resolver: TrapActionResolver,
    frame: *execution_frame.ExecutionFrame,
) EvalError!void {
    substitution_state.validate();
    substitution_context.validate();
    assertCommandSubstitutionContext(substitution_context);
    command_outcome.validate();
    resolver.validate();
    frame.validate();

    if (substitution_state.getTrapForSignal(.EXIT) == null) return;
    substitution_state.last_status = visible_status.*;
    try substitution_state.appendPendingTrap(.EXIT);

    var trap_outcome = (try executePendingTrapsWithFrame(
        evaluator,
        substitution_state,
        substitution_context,
        resolver,
        frame,
    )) orelse return;
    defer trap_outcome.deinit();

    try appendCommandSubstitutionExitTrapOutput(command_outcome, trap_outcome);
    visible_status.* = trap_outcome.status;
    trap_outcome.applyToShellState(substitution_state, .{}) catch |err| switch (err) {
        error.ReadonlyVariable => return error.Unimplemented,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn appendCommandSubstitutionExitTrapOutput(
    command_outcome: *outcome.CommandOutcome,
    trap_outcome: outcome.CommandOutcome,
) EvalError!void {
    command_outcome.validate();
    trap_outcome.validate();

    try appendCommandSubstitutionCapturedOutput(command_outcome, trap_outcome.stdout.items, trap_outcome.stderr.items);
    for (trap_outcome.diagnostics.items) |diagnostic| try command_outcome.addDiagnostic(diagnostic.message);
}

fn appendCommandSubstitutionCapturedOutput(
    command_outcome: *outcome.CommandOutcome,
    substitution_stdout: []const u8,
    side_stderr: []const u8,
) EvalError!void {
    command_outcome.validate();

    try command_outcome.appendStdout(substitution_stdout);
    try command_outcome.appendStderr(side_stderr);
}

fn evaluateCommandSubstitutionBody(
    evaluator: *Evaluator,
    substitution_state: *state.ShellState,
    substitution_context: context.EvalContext,
    body: CommandSubstitutionBody,
    parent_input: ?*EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    substitution_state.validate();
    substitution_context.validate();
    assertCommandSubstitutionContext(substitution_context);
    body.validate();
    if (parent_input) |input| input.validate();
    frame.validate();
    return switch (body) {
        .simple => |plan| blk: {
            var input = EvaluationInput.empty();
            if (parent_input) |active_input| input = active_input.*;
            break :blk evaluatePlanWithInput(
                evaluator,
                substitution_state,
                substitution_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .compound => |plan| blk: {
            var input = EvaluationInput.empty();
            if (parent_input) |active_input| input = active_input.*;
            break :blk evaluateCompoundPlanWithInput(
                evaluator,
                substitution_state,
                substitution_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .pipeline => |plan| evaluatePipelinePlanWithFrame(
            evaluator,
            substitution_state,
            substitution_context,
            plan,
            frame,
        ),
        .failure => |failure| trapActionFailureOutcome(
            evaluator.allocator,
            substitution_context,
            failure,
            substitution_state.*,
        ),
        .owned => |owned| evaluateCommandSubstitutionBodyPayload(
            evaluator,
            substitution_state,
            substitution_context,
            owned.body,
            parent_input,
            frame,
        ),
    };
}

fn evaluateCommandSubstitutionBodyPayload(
    evaluator: *Evaluator,
    substitution_state: *state.ShellState,
    substitution_context: context.EvalContext,
    body: CommandSubstitutionBodyPayload,
    parent_input: ?*EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    substitution_state.validate();
    substitution_context.validate();
    assertCommandSubstitutionContext(substitution_context);
    body.validate();
    if (parent_input) |input| input.validate();
    frame.validate();
    return switch (body) {
        .simple => |plan| blk: {
            var input = EvaluationInput.empty();
            if (parent_input) |active_input| input = active_input.*;
            break :blk evaluatePlanWithInput(
                evaluator,
                substitution_state,
                substitution_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .compound => |plan| blk: {
            var input = EvaluationInput.empty();
            if (parent_input) |active_input| input = active_input.*;
            break :blk evaluateCompoundPlanWithInput(
                evaluator,
                substitution_state,
                substitution_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .pipeline => |plan| evaluatePipelinePlanWithFrame(
            evaluator,
            substitution_state,
            substitution_context,
            plan,
            frame,
        ),
        .failure => |failure| trapActionFailureOutcome(
            evaluator.allocator,
            substitution_context,
            failure,
            substitution_state.*,
        ),
    };
}

fn applyCommandSubstitutionOutcome(
    substitution_state: *state.ShellState,
    command_outcome: *outcome.CommandOutcome,
) EvalError!void {
    substitution_state.validate();
    command_outcome.validate();
    std.debug.assert(substitution_state.acceptsExecutionTarget(.subshell));
    const target = command_outcome.state_delta.target;
    std.debug.assert(target != .current_shell);
    command_outcome.applyToShellState(substitution_state, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
}

fn commandSubstitutionResultFromOutcome(
    allocator: std.mem.Allocator,
    command_substitution_depth: u32,
    fold_side_stdout: bool,
    visible_status: outcome.ExitStatus,
    command_outcome: outcome.CommandOutcome,
) EvalError!CommandSubstitutionResult {
    command_outcome.validate();
    std.debug.assert(command_substitution_depth != 0);
    var result = CommandSubstitutionResult.init(allocator, visible_status);
    errdefer result.deinit();

    if (fold_side_stdout) {
        try appendCommandSubstitutionOutput(
            allocator,
            &result.output,
            command_outcome.command_substitution_side_stdout.items,
        );
    } else {
        try result.side_stdout.appendSlice(allocator, command_outcome.command_substitution_side_stdout.items);
    }
    const trimmed = trimCommandSubstitutionOutput(command_outcome.stdout.items);
    try appendCommandSubstitutionOutput(allocator, &result.output, trimmed);
    const trimmed_pipeline_stdout = trimCommandSubstitutionOutput(command_outcome.pipeline_stdout.items);
    if (command_substitution_depth == 1) {
        try appendCommandSubstitutionOutput(allocator, &result.output, trimmed_pipeline_stdout);
    } else {
        try result.side_stdout.appendSlice(allocator, command_outcome.pipeline_stdout.items);
    }
    std.debug.assert(result.output.items.len <=
        trimmed.len + trimmed_pipeline_stdout.len + command_outcome.command_substitution_side_stdout.items.len);
    if (result.output.items.len != 0) std.debug.assert(result.output.items.ptr != command_outcome.stdout.items.ptr);

    try result.side_stdout.appendSlice(allocator, command_outcome.side_stdout.items);
    try result.stderr.appendSlice(allocator, command_outcome.stderr.items);
    for (command_outcome.diagnostics.items) |diagnostic| {
        const owned_message = try allocator.dupe(u8, diagnostic.message);
        errdefer allocator.free(owned_message);
        try result.diagnostics.append(allocator, .{ .message = owned_message });
    }
    if (command_outcome.propagated_failure) |propagated_failure| {
        result.fatal_failure = try commandSubstitutionFatalFailureFromOutcome(
            allocator,
            propagated_failure,
            command_outcome,
        );
    }
    result.control_flow = .normal;
    result.validate();
    return result;
}

fn commandSubstitutionFatalFailureFromOutcome(
    allocator: std.mem.Allocator,
    propagated_failure: outcome.PropagatedFailure,
    command_outcome: outcome.CommandOutcome,
) !TrapActionFailure {
    command_outcome.validate();
    std.debug.assert(command_outcome.propagated_failure != null);
    std.debug.assert(command_outcome.propagated_failure.?.status() == propagated_failure.status());
    switch (command_outcome.propagated_failure.?) {
        .command_substitution => {},
    }
    switch (propagated_failure) {
        .command_substitution => {},
    }
    const status = propagated_failure.status();
    std.debug.assert(status != 0);

    const fallback = "command substitution failed";
    const raw_message = if (command_outcome.diagnostics.items.len != 0)
        command_outcome.diagnostics.items[0].message
    else
        trimCommandSubstitutionOutput(command_outcome.stderr.items);
    const message = if (raw_message.len == 0) fallback else raw_message;
    const failure: TrapActionFailure = .{
        .kind = .expansion_error,
        .status = status,
        .message = try allocator.dupe(u8, message),
        .fatal_noninteractive = true,
    };
    failure.validate();
    return failure;
}

fn trimCommandSubstitutionOutput(output_bytes: []const u8) []const u8 {
    var end = output_bytes.len;
    while (end != 0 and output_bytes[end - 1] == '\n') end -= 1;
    std.debug.assert(end <= output_bytes.len);
    if (end != 0) std.debug.assert(output_bytes[end - 1] != '\n');
    return output_bytes[0..end];
}

fn appendCommandSubstitutionOutput(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    for (bytes) |byte| {
        if (byte == 0) continue;
        try output.append(allocator, byte);
    }
}

fn assertCommandSubstitutionContext(substitution_context: context.EvalContext) void {
    substitution_context.validate();
    std.debug.assert(substitution_context.command_substitution_depth != 0);
    std.debug.assert(substitution_context.target == .subshell);
    std.debug.assert(substitution_context.target.isIsolatedFromParent());
}

fn commandSubstitutionBodyFailure(body: CommandSubstitutionBody) ?TrapActionFailure {
    return switch (body) {
        .failure => |failure| failure,
        .owned => |owned| commandSubstitutionBodyPayloadFailure(owned.body),
        .simple, .compound, .pipeline => null,
    };
}

fn commandSubstitutionBodyPayloadFailure(body: CommandSubstitutionBodyPayload) ?TrapActionFailure {
    return switch (body) {
        .failure => |failure| failure,
        .simple, .compound, .pipeline => null,
    };
}

fn runSemanticCommandSubstitution(
    opaque_context: ?*anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    script: []const u8,
) anyerror![]const u8 {
    std.debug.assert(opaque_context != null);
    const expansion_context: *CommandSubstitutionExpansionContext = @ptrCast(@alignCast(opaque_context.?));
    expansion_context.validate();

    const parent_state = expansion_context.shell_state;
    const parent_fingerprint = shellStateMutationFingerprint(parent_state.*);
    const previous_eval_context = expansion_context.eval_context;
    const substitution_context = previous_eval_context.enterCommandSubstitution();
    assertCommandSubstitutionContext(substitution_context);

    var substitution_state = parent_state.snapshotForSubshell(
        expansion_context.evaluator.allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer substitution_state.deinit();
    if (expansion_context.suppress_inherited_xtrace) substitution_state.options.set(.xtrace, false);
    if (expansion_context.evaluator.features.isBash()) substitution_state.options.set(.errexit, false);

    expansion_context.eval_context = substitution_context;
    expansion_context.shell_state = &substitution_state;
    expansion_context.max_depth_observed = @max(
        expansion_context.max_depth_observed,
        substitution_context.command_substitution_depth,
    );
    defer {
        expansion_context.shell_state = parent_state;
        expansion_context.eval_context = previous_eval_context;
        expansion_context.validate();
        std.debug.assert(shellStateMutationFingerprint(parent_state.*) == parent_fingerprint);
    }

    var body = (try expansion_context.resolver.resolve(allocator, script)) orelse return error.Unimplemented;
    defer body.deinit();
    if (commandSubstitutionBodyFailure(body)) |failure| {
        try expansion_context.recordFailure(failure);
        return allocator.dupe(u8, "");
    }
    var root_parent_frame = rootExecutionFrame(previous_eval_context);
    defer root_parent_frame.spec.fd_table.deinit(expansion_context.evaluator.allocator);
    const parent_frame = expansion_context.parent_frame orelse &root_parent_frame;
    var result = try evaluateCommandSubstitutionInState(
        expansion_context.evaluator,
        &substitution_state,
        substitution_context,
        body,
        expansion_context.trap_resolver,
        parent_frame,
        expansion_context.parent_input,
    );
    defer result.deinit();

    if (result.fatal_failure) |failure| {
        try expansion_context.recordFailure(failure);
        return allocator.dupe(u8, "");
    }

    expansion_context.last_status = result.status;
    expansion_context.last_control_flow = result.control_flow;
    if (commandSubstitutionHasSideOutput(result)) {
        try expansion_context.stderr.appendSlice(expansion_context.evaluator.allocator, result.stderr.items);
        try expansion_context.side_stdout.appendSlice(expansion_context.evaluator.allocator, result.side_stdout.items);
        for (result.diagnostics.items) |diagnostic| {
            const owned_message = try expansion_context.evaluator.allocator.dupe(u8, diagnostic.message);
            errdefer expansion_context.evaluator.allocator.free(owned_message);
            try expansion_context.diagnostics.append(
                expansion_context.evaluator.allocator,
                .{ .message = owned_message },
            );
        }
    }

    const owned_output = try allocator.dupe(u8, result.output.items);
    std.debug.assert(owned_output.len == result.output.items.len);
    if (owned_output.len != 0) std.debug.assert(owned_output.ptr != result.output.items.ptr);
    return owned_output;
}

fn commandSubstitutionHasSideOutput(result: CommandSubstitutionResult) bool {
    result.validate();
    return result.stderr.items.len != 0 or result.side_stdout.items.len != 0 or result.diagnostics.items.len != 0;
}

fn evaluateSingleStagePipeline(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    statuses: []outcome.ExitStatus,
    buffers: *EvaluationBuffers,
) EvalError!delta.StateDelta {
    plan.validate();
    std.debug.assert(plan.strategy == .single_stage);
    std.debug.assert(statuses.len == 1);
    const stage_target = plan.stageTarget(0);
    const stage = stageWithTarget(plan.stages[0], stage_target);
    const stage_context = pipelineStageContext(eval_context, stage_target, plan.negated);

    var stage_outcome = try evaluatePipelineStageWithInput(
        evaluator,
        shell_state,
        stage_context,
        stage,
        buffers.stdin,
        buffers.frame,
    );
    defer stage_outcome.deinit();
    if (plan.negated)
        try appendPipelineStageBuffers(buffers, stage_outcome, .parent_output)
    else
        try appendOutcomeBuffers(buffers, stage_outcome);

    const stage_control_flow = stage_outcome.effectiveControlFlow();
    statuses[0] = stage_control_flow.status(stage_outcome.status);
    if (stage_control_flow != .normal) {
        var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);
        errdefer state_delta.deinit();
        stage_outcome.discardDelta(stage_target);
        state_delta.setLastStatus(statuses[0]);
        return state_delta;
    }

    if (stage_target == eval_context.target and stage_target.allowsShellStateCommit()) {
        var state_delta = try stage_outcome.state_delta.clone(evaluator.allocator);
        errdefer state_delta.deinit();
        stage_outcome.discardDelta(stage_target);
        std.debug.assert(state_delta.target == eval_context.target);
        return state_delta;
    }

    stage_outcome.discardDelta(stage_target);
    var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);
    errdefer state_delta.deinit();
    return state_delta;
}

const BackgroundStartResult = union(enum) {
    started: state.BackgroundJob,
    failure: outcome.ExitStatus,
};

const BackgroundSemanticContext = struct {
    evaluator: *Evaluator,
    parent_state: *const state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    redirections_already_applied: bool = false,

    fn validate(self: BackgroundSemanticContext) void {
        _ = self.evaluator.allocator;
        self.parent_state.validate();
        self.eval_context.validate();
        self.plan.validate();
        std.debug.assert(self.plan.strategy == .background_deferred);
        std.debug.assert(self.eval_context.target.allowsShellStateCommit());
        std.debug.assert(self.parent_state.acceptsExecutionTarget(self.eval_context.target));
        if (self.redirections_already_applied) std.debug.assert(self.plan.stages.len == 1);
    }
};

fn evaluateBackgroundPipelinePlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    std.debug.assert(plan.strategy == .background_deferred);
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));

    var input = EvaluationInput.empty();
    var frame = rootExecutionFrame(eval_context);
    var buffers = EvaluationBuffers.init(evaluator.allocator, &input, &frame);
    defer buffers.deinit();

    var state_delta = delta.StateDelta.init(evaluator.allocator, eval_context.target);
    errdefer state_delta.deinit();

    var start_result = try startBackgroundPipeline(evaluator, shell_state.*, eval_context, plan, &buffers);
    switch (start_result) {
        .started => |*job| {
            defer job.deinit(evaluator.allocator);
            try state_delta.appendBackgroundJob(job.*);
            state_delta.setLastStatus(0);
            const statuses = try evaluator.allocator.alloc(outcome.ExitStatus, plan.stages.len);
            defer evaluator.allocator.free(statuses);
            @memset(statuses, 0);
            try state_delta.setLastPipelineStatuses(statuses);
            return try commandOutcomeFromBuffers(evaluator.allocator, eval_context, 0, state_delta, .normal, &buffers);
        },
        .failure => |status| {
            state_delta.setLastStatus(status);
            const decision = consequence.decideForStatus(shell_state.options, eval_context, status);
            return try commandOutcomeFromBuffers(
                evaluator.allocator,
                eval_context,
                status,
                state_delta,
                decision.control_flow,
                &buffers,
            );
        },
    }
}

fn startBackgroundPipeline(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    buffers: *EvaluationBuffers,
) EvalError!BackgroundStartResult {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    std.debug.assert(plan.strategy == .background_deferred);
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));

    const background_signals_ignored = try configureBackgroundSignalInheritance(evaluator, shell_state);
    defer if (background_signals_ignored) restoreBackgroundSignalInheritance(evaluator, shell_state);

    if (plan.stages.len == 1) {
        return switch (plan.stages[0]) {
            .simple => |simple| if (simple.class() == .external)
                startBackgroundSingleExternal(evaluator, shell_state, simple, buffers)
            else
                startBackgroundSemanticPipeline(evaluator, shell_state, eval_context, plan, buffers),
            .compound => startBackgroundSemanticPipeline(evaluator, shell_state, eval_context, plan, buffers),
        };
    }

    for (plan.stages) |stage| {
        if (!stage.isExternalOnlyRealEligible()) return startBackgroundSemanticPipeline(
            evaluator,
            shell_state,
            eval_context,
            plan,
            buffers,
        );
    }
    return startBackgroundExternalOnlyPipeline(evaluator, shell_state, plan, buffers);
}

fn configureBackgroundSignalInheritance(evaluator: *Evaluator, shell_state: state.ShellState) EvalError!bool {
    shell_state.validate();
    if (shell_state.options.enabled(.monitor)) return false;
    if (evaluator.signal_port == null) return false;
    try configureRuntimeSignalDisposition(evaluator, .INT, .ignore);
    try configureRuntimeSignalDisposition(evaluator, .QUIT, .ignore);
    return true;
}

fn restoreBackgroundSignalInheritance(evaluator: *Evaluator, shell_state: state.ShellState) void {
    shell_state.validate();
    // ziglint-ignore: Z026 best-effort signal restoration from background-spawn defer
    configureRuntimeTrapSignal(evaluator, shell_state, .INT) catch {};
    // ziglint-ignore: Z026 best-effort signal restoration from background-spawn defer
    configureRuntimeTrapSignal(evaluator, shell_state, .QUIT) catch {};
}

fn configureRuntimeSignalDisposition(
    evaluator: *Evaluator,
    signal: state.TrapSignal,
    disposition: runtime.signal.Disposition,
) EvalError!void {
    signal.validate();
    const signal_number = signal.runtimeNumber() orelse return;
    const signal_port = evaluator.signal_port orelse return error.Unimplemented;
    signal_port.configure(.{ .signal = signal_number, .disposition = disposition }) catch |err| switch (err) {
        error.Unsupported, error.Unexpected => return error.Unimplemented,
    };
}

fn startBackgroundSemanticPipeline(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    buffers: *EvaluationBuffers,
) EvalError!BackgroundStartResult {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    std.debug.assert(plan.strategy == .background_deferred);
    std.debug.assert(!backgroundPlanIsExternalOnlyRealEligible(plan));

    const process_port = evaluator.process_port orelse return error.Unimplemented;
    const use_process_group = shell_state.options.enabled(.monitor);

    var redirection_guard = RedirectionGuard.empty(.child_only);
    defer redirection_guard.restore();
    const redirections_already_applied = try applySingleStageBackgroundRedirections(
        evaluator,
        plan,
        buffers,
        &redirection_guard,
    ) orelse return .{ .failure = 1 };

    var semantic_context: BackgroundSemanticContext = .{
        .evaluator = evaluator,
        .parent_state = &shell_state,
        .eval_context = eval_context,
        .plan = plan,
        .redirections_already_applied = redirections_already_applied,
    };
    semantic_context.validate();

    const child = (process_port.startSubshell(.{
        .context = &semantic_context,
        .main_fn = runBackgroundSemanticSubshell,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .process_group = if (use_process_group) 0 else null,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |spawn_err| {
            const failure = spawnFailure(spawn_err);
            try buffers.addBuiltinDiagnostic("pipeline", failure.message);
            return .{ .failure = failure.status };
        },
    }).child;

    redirection_guard.restore();

    const command_text = try pipelineCommandText(evaluator.allocator, plan);
    errdefer evaluator.allocator.free(command_text);
    const pid = child.id();
    var job: state.BackgroundJob = .{
        .id = shell_state.next_job_id,
        .pid = pid,
        .process_group = if (use_process_group) pid else null,
        .command = command_text,
    };
    errdefer job.deinit(evaluator.allocator);
    try job.appendProcess(evaluator.allocator, .{ .stage_index = 0, .child = child });
    return .{ .started = job };
}

fn runBackgroundSemanticSubshell(opaque_context: *anyopaque) u8 {
    const semantic_context: *BackgroundSemanticContext = @ptrCast(@alignCast(opaque_context));
    semantic_context.validate();

    var child_state = semantic_context.parent_state.snapshotForSubshell(
        semantic_context.evaluator.allocator,
    ) catch return 126;
    defer child_state.deinit();

    const child_context = semantic_context.eval_context.enterSubshell();
    const foreground_plan = foregroundPlanForBackgroundSubshell(
        semantic_context.evaluator.allocator,
        semantic_context.plan,
        semantic_context.redirections_already_applied,
    ) catch return 126;
    defer semantic_context.evaluator.allocator.free(foreground_plan.stages);

    var result = evaluatePipelinePlan(
        semantic_context.evaluator,
        &child_state,
        child_context,
        foreground_plan,
    ) catch return 126;
    defer result.deinit();

    const status = result.control_flow.status(result.status);
    writeOutcomeToInheritedDescriptors(
        semantic_context.evaluator.allocator,
        result.stdout.items,
        result.stderr.items,
    ) catch return 126;
    result.applyToShellState(&child_state, .{}) catch return 126;
    return status;
}

fn backgroundPlanIsExternalOnlyRealEligible(plan: pipeline_plan.PipelinePlan) bool {
    plan.validate();
    std.debug.assert(plan.strategy == .background_deferred);
    if (plan.stages.len == 1) return switch (plan.stages[0]) {
        .simple => |simple| simple.class() == .external,
        .compound => false,
    };
    for (plan.stages) |stage| if (!stage.isExternalOnlyRealEligible()) return false;
    return true;
}

fn applySingleStageBackgroundRedirections(
    evaluator: *Evaluator,
    plan: pipeline_plan.PipelinePlan,
    buffers: *EvaluationBuffers,
    redirection_guard: *RedirectionGuard,
) EvalError!?bool {
    plan.validate();
    std.debug.assert(plan.strategy == .background_deferred);
    std.debug.assert(!redirection_guard.hasTransaction());
    if (plan.stages.len != 1) return false;

    const redirections = switch (plan.stages[0]) {
        .simple => |simple| blk: {
            if (simple.class() == .external or !hasRedirections(simple)) return false;
            break :blk simple.redirections;
        },
        .compound => |compound| blk: {
            if (!hasCompoundRedirections(compound)) return false;
            break :blk compound.redirections;
        },
    };

    const apply_result = try applyRedirectionsForScope(
        evaluator.*,
        buffers,
        .child_only,
        .{},
        redirections,
        .inherited,
        backgroundSingleStageName(plan.stages[0]),
    );
    switch (apply_result) {
        .applied => |applied| {
            redirection_guard.* = applied;
            return true;
        },
        .failure => |failure| {
            try addRedirectionFailureDiagnostic(buffers, backgroundSingleStageName(plan.stages[0]), failure);
            return null;
        },
    }
}

fn foregroundPlanForBackgroundSubshell(
    allocator: std.mem.Allocator,
    plan: pipeline_plan.PipelinePlan,
    redirections_already_applied: bool,
) !pipeline_plan.PipelinePlan {
    plan.validate();
    std.debug.assert(plan.strategy == .background_deferred);
    if (redirections_already_applied) std.debug.assert(plan.stages.len == 1);

    const stages = try allocator.alloc(pipeline_plan.PipelineStagePlan, plan.stages.len);
    errdefer allocator.free(stages);
    for (plan.stages, 0..) |stage, index| {
        const target: context.ExecutionTarget = if (stage.isExternal()) .child_process else .subshell;
        stages[index] = stageWithTarget(stage, target);
        if (redirections_already_applied and index == 0) clearStageRedirections(&stages[index]);
    }

    return pipeline_plan.PipelinePlan.init(stages, .{
        .negated = plan.negated,
        .status_rule = plan.status_rule,
        .background = .foreground,
    });
}

fn clearStageRedirections(stage: *pipeline_plan.PipelineStagePlan) void {
    stage.validate();
    switch (stage.*) {
        .simple => |*simple| simple.redirections = .{},
        .compound => |*compound| compound.redirections = .{},
    }
    stage.validate();
}

fn backgroundSingleStageName(stage: pipeline_plan.PipelineStagePlan) []const u8 {
    stage.validate();
    return switch (stage) {
        .simple => |simple| if (simple.argv.len == 0) "command" else simple.argv[0],
        .compound => |compound| compound.kindName(),
    };
}

fn startBackgroundSingleExternal(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
    buffers: *EvaluationBuffers,
) EvalError!BackgroundStartResult {
    shell_state.validate();
    plan.validate();
    std.debug.assert(plan.class() == .external);
    const process_port = evaluator.process_port orelse return error.Unimplemented;
    const resolution = switch (plan.classification) {
        .external => |external| external,
        else => unreachable,
    };

    var invocation = try ExternalInvocation.init(evaluator.allocator, shell_state, plan, resolution, &.{});
    defer invocation.deinit(evaluator.allocator);

    var redirection_guard = RedirectionGuard.empty(.child_only);
    defer redirection_guard.restore();
    if (hasRedirections(plan)) {
        const apply_result = try applyRedirectionsForScope(
            evaluator.*,
            buffers,
            .child_only,
            .{},
            plan.redirections,
            .inherited,
            plan.argv[0],
        );
        switch (apply_result) {
            .applied => |applied| redirection_guard = applied,
            .failure => |failure| {
                try addRedirectionFailureDiagnostic(buffers, plan.argv[0], failure);
                return .{ .failure = 1 };
            },
        }
    }

    const use_process_group = shell_state.options.enabled(.monitor);
    const child = (invocation.spawn(evaluator, process_port, .{
        .process_group = if (use_process_group) 0 else null,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |spawn_err| {
            const failure = spawnFailure(spawn_err);
            try buffers.addBuiltinDiagnostic(plan.argv[0], failure.message);
            return .{ .failure = failure.status };
        },
    }).child;

    redirection_guard.restore();

    const command_text = try commandTextFromArgv(evaluator.allocator, plan.argv);
    errdefer evaluator.allocator.free(command_text);
    const pid = child.id();
    var job: state.BackgroundJob = .{
        .id = shell_state.next_job_id,
        .pid = pid,
        .process_group = if (use_process_group) pid else null,
        .command = command_text,
    };
    errdefer job.deinit(evaluator.allocator);
    try job.appendProcess(evaluator.allocator, .{ .stage_index = 0, .child = child });
    return .{ .started = job };
}

fn startBackgroundExternalOnlyPipeline(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    plan: pipeline_plan.PipelinePlan,
    buffers: *EvaluationBuffers,
) EvalError!BackgroundStartResult {
    shell_state.validate();
    plan.validate();
    std.debug.assert(plan.strategy == .background_deferred);
    std.debug.assert(plan.stages.len > 1);

    const fd_port = evaluator.fd_port orelse return error.Unimplemented;
    const process_port = evaluator.process_port orelse return error.Unimplemented;

    const pipe_count = plan.pipeCount();
    std.debug.assert(pipe_count != 0);
    const pipes = try evaluator.allocator.alloc(PipelinePipe, pipe_count);
    defer evaluator.allocator.free(pipes);
    var initialized_pipes: usize = 0;
    errdefer closeOpenPipelinePipes(fd_port, pipes[0..initialized_pipes], buffers);

    for (pipes) |*pipe_slot| {
        const pipe_result = fd_port.pipe(.{}) catch |err| {
            try buffers.addBuiltinDiagnostic("pipeline", pipeFailureMessage(err));
            closeOpenPipelinePipes(fd_port, pipes[0..initialized_pipes], buffers);
            return .{ .failure = 1 };
        };
        pipe_slot.* = PipelinePipe.init(pipe_result);
        initialized_pipes += 1;
    }

    var children: std.ArrayList(runtime.process.ChildProcess) = .empty;
    defer children.deinit(evaluator.allocator);
    var child_stage_indexes: std.ArrayList(usize) = .empty;
    defer child_stage_indexes.deinit(evaluator.allocator);

    const use_process_group = shell_state.options.enabled(.monitor);
    var process_group: ?runtime.process.ProcessId = null;

    for (plan.stages, 0..) |stage, index| {
        const stdin: runtime.process.StandardIo = if (index == 0) .inherit else .{ .fd = pipes[index - 1].read };
        const stdout: runtime.process.StandardIo =
            if (index + 1 == plan.stages.len) .inherit else .{ .fd = pipes[index].write };
        const requested_group: ?runtime.process.ProcessId = if (use_process_group) process_group orelse 0 else null;

        const spawn_result = try spawnExternalPipelineStage(
            evaluator,
            shell_state,
            stage,
            stdin,
            stdout,
            requested_group,
            buffers,
        );
        switch (spawn_result) {
            .spawned => |child| {
                if (use_process_group and process_group == null) process_group = child.id();
                try children.append(evaluator.allocator, child);
                try child_stage_indexes.append(evaluator.allocator, index);
                if (index != 0) closePipelinePipeRead(fd_port, &pipes[index - 1], buffers);
                if (index + 1 != plan.stages.len) closePipelinePipeWrite(fd_port, &pipes[index], buffers);
            },
            .failure => |failure| {
                closeOpenPipelinePipes(fd_port, pipes, buffers);
                const statuses = try evaluator.allocator.alloc(outcome.ExitStatus, plan.stages.len);
                defer evaluator.allocator.free(statuses);
                @memset(statuses, failure.status);
                try waitSpawnedPipelineChildren(
                    process_port,
                    children.items,
                    child_stage_indexes.items,
                    statuses,
                    buffers,
                );
                return .{ .failure = failure.status };
            },
        }
    }

    closeOpenPipelinePipes(fd_port, pipes, buffers);
    const command_text = try pipelineCommandText(evaluator.allocator, plan);
    errdefer evaluator.allocator.free(command_text);
    const pid = children.items[children.items.len - 1].id();
    var job: state.BackgroundJob = .{
        .id = shell_state.next_job_id,
        .pid = pid,
        .process_group = process_group,
        .command = command_text,
    };
    errdefer job.deinit(evaluator.allocator);
    for (children.items, child_stage_indexes.items) |child, stage_index| try job.appendProcess(
        evaluator.allocator,
        .{ .stage_index = stage_index, .child = child },
    );
    return .{ .started = job };
}

fn evaluateFallbackPipeline(
    evaluator: *Evaluator,
    parent_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    statuses: []outcome.ExitStatus,
    buffers: *EvaluationBuffers,
) EvalError!void {
    parent_state.validate();
    eval_context.validate();
    plan.validate();
    plan.validateStatusCount(statuses);
    std.debug.assert(
        plan.strategy == .semantic_in_memory or
            plan.strategy == .mixed_in_memory or
            (plan.strategy == .external_only_real and
                (capturedExternalMode(evaluator.external_stdio) != null or pipelineHasExpansionOutput(plan))),
    );
    std.debug.assert(plan.stages.len > 1);

    var next_stdin: std.ArrayList(u8) = .empty;
    defer next_stdin.deinit(evaluator.allocator);

    for (plan.stages, 0..) |stage, index| {
        const is_last_stage = index + 1 == plan.stages.len;
        const stage_target = plan.stageTarget(index);
        std.debug.assert(stage_target != .current_shell);
        var stage_state = try workingStateForPipelineStage(evaluator.allocator, parent_state, stage_target);
        defer stage_state.deinit();
        var cwd_guard: CwdGuard = .{};
        cwd_guard.capture(evaluator);
        defer cwd_guard.restore();

        const stage_context = pipelineStageContext(eval_context, stage_target, true);
        var stage_input = EvaluationInput.init(next_stdin.items);
        var stage_frame = try pipelineStageExecutionFrame(
            evaluator.allocator,
            evaluator.scoped_exec_redirections,
            buffers.frame,
            stage_target,
            is_last_stage,
            next_stdin.items,
            pipelineStageRedirections(stage),
        );
        defer stage_frame.spec.fd_table.deinit(evaluator.allocator);
        var redirected_stage = stageWithTarget(stage, stage_target);
        if (!redirectionPlanNeedsRuntimeFdEffects(pipelineStageRedirections(stage)) and
            semanticHereDocStdinSource(pipelineStageRedirections(stage)) == null)
        {
            clearStageRedirections(&redirected_stage);
        }
        var stage_outcome = if (stage.isExternal())
            try evaluateExternalPipelineStage(
                evaluator,
                &stage_state,
                stage_context,
                redirected_stage,
                &stage_input,
                &stage_frame,
            )
        else
            try evaluatePipelineStageWithInput(
                evaluator,
                &stage_state,
                stage_context,
                redirected_stage,
                &stage_input,
                &stage_frame,
            );
        defer stage_outcome.deinit();

        if (!is_last_stage) try routePipelineStageOutcome(evaluator.allocator, &stage_outcome, stage_frame);

        if (is_last_stage) flushInheritedPipelineStdout(evaluator.*, &stage_outcome);
        const stage_control_flow = stage_outcome.effectiveControlFlow();
        statuses[index] = stage_control_flow.status(stage_outcome.status);
        try appendPipelineStageBuffers(buffers, stage_outcome, PipelineStageOutputRoute.forStage(is_last_stage));
        try flushCurrentShellBufferedCommandOutput(
            buffers,
            eval_context,
            evaluator.external_stdio,
            evaluator.io != null,
        );
        stage_outcome.applyToShellState(&stage_state, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadonlyVariable => unreachable,
        };

        if (stage_control_flow != .normal) {
            @memset(statuses[index + 1 ..], statuses[index]);
            break;
        }

        if (!is_last_stage) {
            try transferPipelineStdoutToNextStdin(evaluator.allocator, &next_stdin, stage_outcome);
        }
    }
}

fn transferPipelineStdoutToNextStdin(
    allocator: std.mem.Allocator,
    next_stdin: *std.ArrayList(u8),
    stage_outcome: outcome.CommandOutcome,
) !void {
    stage_outcome.validate();
    next_stdin.clearRetainingCapacity();
    try next_stdin.appendSlice(allocator, stage_outcome.pipeline_stdout.items);
}

fn routePipelineStageOutcome(
    allocator: std.mem.Allocator,
    stage_outcome: *outcome.CommandOutcome,
    frame: execution_frame.ExecutionFrame,
) EvalError!void {
    stage_outcome.validate();
    frame.validate();
    std.debug.assert(frame.spec.kind == .pipeline_stage);
    try routePipelineStageOutcomeBuffer(
        allocator,
        frame.spec.fd_table.endpoint(1),
        &stage_outcome.stdout,
        &stage_outcome.pipeline_stdout,
    );
    try routePipelineStageOutcomeBuffer(
        allocator,
        frame.spec.fd_table.endpoint(2),
        &stage_outcome.stderr,
        &stage_outcome.pipeline_stdout,
    );
}

fn routePipelineStageOutcomeBuffer(
    allocator: std.mem.Allocator,
    endpoint: execution_frame.FdEndpoint,
    source: *std.ArrayList(u8),
    pipeline_stdout: *std.ArrayList(u8),
) EvalError!void {
    endpoint.validate();
    if (source.items.len == 0) return;

    switch (endpoint) {
        .output => |output| switch (output) {
            .capture => |channel| if (channel == .pipeline_data) {
                try pipeline_stdout.appendSlice(allocator, source.items);
                source.items.len = 0;
            },
            .discard => source.items.len = 0,
            .inherit_stdout, .inherit_stderr, .fd, .pipe_write, .path => {},
        },
        .closed => source.items.len = 0,
        .input => source.items.len = 0,
    }
}

fn flushInheritedPipelineStdout(evaluator: Evaluator, stage_outcome: *outcome.CommandOutcome) void {
    stage_outcome.validate();
    if (!pipelineStdoutInherits(evaluator.external_stdio)) return;
    if (stage_outcome.stdout.items.len == 0) return;
    if (descriptorIsOpen(1)) return;

    if (stage_outcome.control_flow == .normal) {
        stage_outcome.status = 1;
    }
    stage_outcome.stdout.items.len = 0;
    stage_outcome.validate();
}

fn pipelineStdoutInherits(external_stdio: ExternalStdio) bool {
    return switch (external_stdio) {
        .inherit, .inherit_output => true,
        .capture, .capture_stdout => false,
    };
}

fn pipelineHasExpansionOutput(plan: pipeline_plan.PipelinePlan) bool {
    plan.validate();
    for (plan.stages) |stage| {
        switch (stage) {
            .simple => |simple| if (simple.expansion_output.stderr.len != 0 or
                simple.expansion_output.diagnostics.len != 0)
            {
                return true;
            },
            .compound => {},
        }
    }
    return false;
}

fn descriptorIsOpen(descriptor: runtime.fd.Descriptor) bool {
    runtime.fd.assertValidDescriptor(descriptor);
    while (true) {
        const rc = std.c.fcntl(descriptor, @as(c_int, std.c.F.GETFD), @as(c_int, 0));
        switch (std.c.errno(rc)) {
            .SUCCESS => return true,
            .BADF => return false,
            .INTR => continue,
            else => return true,
        }
    }
}

const PipelinePipe = struct {
    read: runtime.fd.Descriptor,
    write: runtime.fd.Descriptor,
    read_open: bool = true,
    write_open: bool = true,

    fn init(pipe_result: runtime.fd.PipeResult) PipelinePipe {
        pipe_result.validate();
        return .{ .read = pipe_result.read, .write = pipe_result.write };
    }

    fn validate(self: PipelinePipe) void {
        runtime.fd.assertValidDescriptor(self.read);
        runtime.fd.assertValidDescriptor(self.write);
        std.debug.assert(self.read != self.write);
    }
};

fn evaluateExternalOnlyRealPipeline(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    statuses: []outcome.ExitStatus,
    buffers: *EvaluationBuffers,
) EvalError!void {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    plan.validateStatusCount(statuses);
    std.debug.assert(plan.strategy == .external_only_real);
    @memset(statuses, 0);

    const fd_port = evaluator.fd_port orelse return error.Unimplemented;
    const process_port = evaluator.process_port orelse return error.Unimplemented;

    const pipe_count = plan.pipeCount();
    std.debug.assert(pipe_count != 0);
    const pipes = try evaluator.allocator.alloc(PipelinePipe, pipe_count);
    defer evaluator.allocator.free(pipes);
    var initialized_pipes: usize = 0;
    errdefer closeOpenPipelinePipes(fd_port, pipes[0..initialized_pipes], buffers);

    for (pipes) |*pipe_slot| {
        const pipe_result = fd_port.pipe(.{}) catch |err| {
            try buffers.addBuiltinDiagnostic("pipeline", pipeFailureMessage(err));
            @memset(statuses, 1);
            closeOpenPipelinePipes(fd_port, pipes[0..initialized_pipes], buffers);
            return;
        };
        pipe_slot.* = PipelinePipe.init(pipe_result);
        initialized_pipes += 1;
    }

    var children: std.ArrayList(runtime.process.ChildProcess) = .empty;
    defer children.deinit(evaluator.allocator);
    var child_stage_indexes: std.ArrayList(usize) = .empty;
    defer child_stage_indexes.deinit(evaluator.allocator);

    for (plan.stages, 0..) |stage, index| {
        const stdin: runtime.process.StandardIo = if (index == 0) .inherit else .{ .fd = pipes[index - 1].read };
        const stdout: runtime.process.StandardIo =
            if (index + 1 == plan.stages.len) .inherit else .{ .fd = pipes[index].write };
        const stage_target = plan.stageTarget(index);
        const stage_context = pipelineStageContext(eval_context, stage_target, true);
        var trace_state = shell_state;
        var trace_input = EvaluationInput.empty();
        switch (stageWithTarget(stage, stage_target)) {
            .simple => |simple| try traceCommandPlanForEvaluation(
                evaluator,
                &trace_state,
                stage_context,
                simple,
                &trace_input,
                buffers.frame,
                buffers,
            ),
            .compound => unreachable,
        }

        const spawn_result = try spawnExternalPipelineStage(
            evaluator,
            shell_state,
            stage,
            stdin,
            stdout,
            null,
            buffers,
        );
        switch (spawn_result) {
            .spawned => |child| {
                try children.append(evaluator.allocator, child);
                try child_stage_indexes.append(evaluator.allocator, index);
                if (index != 0) closePipelinePipeRead(fd_port, &pipes[index - 1], buffers);
                if (index + 1 != plan.stages.len) closePipelinePipeWrite(fd_port, &pipes[index], buffers);
            },
            .failure => |failure| {
                statuses[index] = failure.status;
                for (statuses[index + 1 ..]) |*status_slot| status_slot.* = failure.status;
                closeOpenPipelinePipes(fd_port, pipes, buffers);
                try waitSpawnedPipelineChildren(
                    process_port,
                    children.items,
                    child_stage_indexes.items,
                    statuses,
                    buffers,
                );
                return;
            },
        }
    }

    closeOpenPipelinePipes(fd_port, pipes, buffers);
    try waitSpawnedPipelineChildren(process_port, children.items, child_stage_indexes.items, statuses, buffers);
}

const PipelineSpawnResult = union(enum) {
    spawned: runtime.process.ChildProcess,
    failure: CommandFailure,
};

fn spawnExternalPipelineStage(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    stage: pipeline_plan.PipelineStagePlan,
    stdin: runtime.process.StandardIo,
    stdout: runtime.process.StandardIo,
    process_group: ?runtime.process.ProcessId,
    buffers: *EvaluationBuffers,
) EvalError!PipelineSpawnResult {
    shell_state.validate();
    stage.validate();
    stdin.validate();
    stdout.validate();
    const process_port = evaluator.process_port orelse return error.Unimplemented;
    const plan = switch (stage) {
        .simple => |simple| simple,
        .compound => unreachable,
    };
    std.debug.assert(plan.target == .child_process);
    std.debug.assert(plan.class() == .external);
    std.debug.assert(!hasRedirections(plan));
    const resolution = switch (plan.classification) {
        .external => |external| external,
        else => unreachable,
    };

    var invocation = try ExternalInvocation.init(evaluator.allocator, shell_state, plan, resolution, &.{});
    defer invocation.deinit(evaluator.allocator);

    const result = invocation.spawn(evaluator, process_port, .{
        .stdin = stdin,
        .stdout = stdout,
        .stderr = .inherit,
        .process_group = process_group,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |spawn_err| {
            const failure = spawnFailure(spawn_err);
            try buffers.addBuiltinDiagnostic(plan.argv[0], failure.message);
            return .{ .failure = failure };
        },
    };
    return .{ .spawned = result.child };
}

fn waitSpawnedPipelineChildren(
    process_port: runtime.process.Port,
    children: []runtime.process.ChildProcess,
    child_stage_indexes: []const usize,
    statuses: []outcome.ExitStatus,
    buffers: *EvaluationBuffers,
) EvalError!void {
    std.debug.assert(children.len == child_stage_indexes.len);
    for (children, child_stage_indexes) |*child, stage_index| {
        std.debug.assert(stage_index < statuses.len);
        const wait_result = process_port.wait(.{ .child = child }) catch |err| {
            const failure = waitFailure(err);
            try buffers.addBuiltinDiagnostic("pipeline", failure.message);
            statuses[stage_index] = failure.status;
            continue;
        };
        statuses[stage_index] = normalizeWaitStatus(wait_result.status);
    }
}

fn closeOpenPipelinePipes(fd_port: runtime.fd.Port, pipes: []PipelinePipe, buffers: *EvaluationBuffers) void {
    for (pipes) |*pipe| {
        pipe.validate();
        if (pipe.read_open) closePipelinePipeRead(fd_port, pipe, buffers);
        if (pipe.write_open) closePipelinePipeWrite(fd_port, pipe, buffers);
    }
}

fn closePipelinePipeRead(fd_port: runtime.fd.Port, pipe: *PipelinePipe, buffers: *EvaluationBuffers) void {
    pipe.validate();
    std.debug.assert(pipe.read_open);
    fd_port.close(.{ .descriptor = pipe.read }) catch {
        // ziglint-ignore: Z026 best-effort secondary diagnostic during cleanup
        buffers.addBuiltinDiagnostic("pipeline", "pipe close failed") catch {};
    };
    pipe.read_open = false;
}

fn closePipelinePipeWrite(fd_port: runtime.fd.Port, pipe: *PipelinePipe, buffers: *EvaluationBuffers) void {
    pipe.validate();
    std.debug.assert(pipe.write_open);
    fd_port.close(.{ .descriptor = pipe.write }) catch {
        // ziglint-ignore: Z026 best-effort secondary diagnostic during cleanup
        buffers.addBuiltinDiagnostic("pipeline", "pipe close failed") catch {};
    };
    pipe.write_open = false;
}

fn finishPipelineOutcome(
    allocator: std.mem.Allocator,
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    plan: pipeline_plan.PipelinePlan,
    statuses: []const outcome.ExitStatus,
    state_delta: delta.StateDelta,
    buffers: *EvaluationBuffers,
) EvalError!outcome.CommandOutcome {
    plan.validateStatusCount(statuses);
    std.debug.assert(state_delta.state == .pending);
    std.debug.assert(state_delta.target == eval_context.target);
    var mutable_delta = state_delta;
    errdefer mutable_delta.deinit();

    const aggregation = pipeline_plan.aggregateStatus(.{
        .stage_count = plan.stages.len,
        .statuses = statuses,
        .status_rule = plan.status_rule,
        .negated = plan.negated,
    });
    const final_status = if (buffers.propagated_failure) |failure|
        failure.status()
    else
        aggregation.final_status;
    if (mutable_delta.last_status != null) mutable_delta.last_status = null;
    mutable_delta.setLastStatus(final_status);
    try mutable_delta.setLastPipelineStatuses(statuses);

    const decision_context = if (plan.negated) eval_context.ignoreErrexit() else eval_context;
    const control_flow: outcome.ControlFlow = if (buffers.propagated_failure) |failure|
        failure.controlFlow()
    else
        consequence.decideForStatus(shell_options, decision_context, aggregation.final_status).control_flow;
    return commandOutcomeFromBuffers(
        allocator,
        eval_context,
        final_status,
        mutable_delta,
        control_flow,
        buffers,
    );
}

fn workingStateForPipelineStage(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    target: context.ExecutionTarget,
) EvalError!state.ShellState {
    shell_state.validate();
    return switch (target) {
        .current_shell => unreachable,
        .subshell => shell_state.snapshotForSubshell(allocator),
        .child_process => shell_state.clone(allocator),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
}

fn evaluatePipelineStage(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    stage: pipeline_plan.PipelineStagePlan,
) EvalError!outcome.CommandOutcome {
    var input = EvaluationInput.empty();
    var frame = rootExecutionFrame(eval_context);
    return evaluatePipelineStageWithInput(evaluator, shell_state, eval_context, stage, &input, &frame);
}

fn evaluatePipelineStageWithInput(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    stage: pipeline_plan.PipelineStagePlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    stage.validate();
    input.validate();
    frame.validate();

    var scoped_exec_redirections: std.ArrayList(ScopedExecRedirection) = .empty;
    defer scoped_exec_redirections.deinit(evaluator.allocator);
    const previous_scoped_exec_redirections = evaluator.scoped_exec_redirections;
    if (eval_context.target.isIsolatedFromParent()) {
        errdefer restoreScopedExecRedirections(&scoped_exec_redirections);
        try inheritScopedExecRedirections(
            evaluator.allocator,
            &scoped_exec_redirections,
            previous_scoped_exec_redirections,
        );
        evaluator.scoped_exec_redirections = &scoped_exec_redirections;
    }
    defer if (eval_context.target.isIsolatedFromParent()) {
        restoreScopedExecRedirections(&scoped_exec_redirections);
        evaluator.scoped_exec_redirections = previous_scoped_exec_redirections;
    };

    return switch (stage) {
        .simple => |simple| evaluatePlanWithInput(evaluator, shell_state, eval_context, simple, input, frame),
        .compound => |compound| evaluateCompoundPlanWithInput(
            evaluator,
            shell_state,
            eval_context,
            compound,
            input,
            frame,
        ),
    };
}

fn evaluateExternalPipelineStage(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    stage: pipeline_plan.PipelineStagePlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    stage.validate();
    input.validate();
    frame.validate();
    std.debug.assert(eval_context.target == .child_process);
    const plan = switch (stage) {
        .simple => |simple| simple,
        .compound => unreachable,
    };
    std.debug.assert(plan.target == .child_process);
    const resolution = switch (plan.classification) {
        .external => |external| external,
        else => unreachable,
    };
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, plan.argv[0], resolution.name));
    std.debug.assert(plan.assignmentEffect() == .temporary or plan.assignmentEffect() == .none);

    if (delta.firstReadonlyAssignment(shell_state.*, plan.assignments)) |name| {
        var failure = try outcome.readonlyVariableFailure(evaluator.allocator, plan.target, name);
        failure.state_delta.setLastStatus(failure.status);
        consequence.applyToOutcome(
            &failure,
            eval_context,
            consequence.decideForShellError(shell_state.options, eval_context, .readonly_assignment, failure.status),
        );
        failure.validateForContext(eval_context);
        return failure;
    }

    var state_delta = delta.StateDelta.init(evaluator.allocator, plan.target);
    errdefer state_delta.deinit();
    if (plan.assignmentEffect() == .persistent) {
        state_delta.appendPersistentCommandAssignments(shell_state.*, plan.assignments) catch |err| switch (err) {
            error.ReadonlyVariable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    var stage_buffers = EvaluationBuffers.init(evaluator.allocator, input, frame);
    defer stage_buffers.deinit();
    try appendPlanExpansionOutput(evaluator.*, eval_context, plan, &stage_buffers);
    try traceCommandPlanForEvaluation(evaluator, shell_state, eval_context, plan, input, frame, &stage_buffers);

    const status = try runExternalWithPipelineInput(
        evaluator,
        shell_state.*,
        eval_context,
        plan,
        resolution,
        &stage_buffers,
    );
    state_delta.setLastStatus(status);
    assertCommandDeltaCompatible(plan, state_delta);
    return commandOutcomeFromBuffers(evaluator.allocator, eval_context, status, state_delta, .normal, &stage_buffers);
}

fn evaluateTrapActionBody(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: TrapActionBody,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    body.validate();
    frame.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    return switch (body) {
        .simple => |plan| blk: {
            var input = EvaluationInput.empty();
            break :blk evaluatePlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .compound => |plan| blk: {
            var input = EvaluationInput.empty();
            break :blk evaluateCompoundPlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .pipeline => |plan| evaluatePipelinePlanWithFrame(evaluator, shell_state, eval_context, plan, frame),
        .failure => |failure| trapActionFailureOutcome(evaluator.allocator, eval_context, failure, shell_state.*),
        .owned => |owned| evaluateTrapActionBodyPayload(evaluator, shell_state, eval_context, owned.body, frame),
    };
}

fn evaluateTrapActionBodyPayload(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: TrapActionBodyPayload,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    body.validate();
    frame.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    return switch (body) {
        .simple => |plan| blk: {
            var input = EvaluationInput.empty();
            break :blk evaluatePlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .compound => |plan| blk: {
            var input = EvaluationInput.empty();
            break :blk evaluateCompoundPlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(plan.target),
                plan,
                &input,
                frame,
            );
        },
        .pipeline => |plan| evaluatePipelinePlanWithFrame(evaluator, shell_state, eval_context, plan, frame),
        .failure => |failure| trapActionFailureOutcome(evaluator.allocator, eval_context, failure, shell_state.*),
    };
}

pub fn trapActionFailureOutcome(
    allocator: std.mem.Allocator,
    eval_context: context.EvalContext,
    failure: TrapActionFailure,
    shell_state: state.ShellState,
) EvalError!outcome.CommandOutcome {
    eval_context.validate();
    failure.validate();
    shell_state.validate();
    var state_delta = delta.StateDelta.init(allocator, eval_context.target);
    errdefer state_delta.deinit();
    state_delta.setLastStatus(failure.status);
    const control_flow: outcome.ControlFlow = if (failure.fatal_noninteractive and !eval_context.interactive)
        .{ .fatal = failure.status }
    else if (bashExpansionFailureIsCommandFailure(
        eval_context,
        failure,
        shell_state,
    )) blk: {
        const decision = consequence.decideForStatus(shell_state.options, eval_context, failure.status);
        if (decision.control_flow == .normal and eval_context.canReturnFromFunction()) {
            break :blk .{ .return_from_scope = .{ .scope = .function, .status = failure.status } };
        }
        break :blk decision.control_flow;
    } else if (bashArithmeticExpansionFailureIsCommandFailure(eval_context, failure, shell_state)) blk: {
        break :blk if (eval_context.observesErrexit()) .{ .exit = failure.status } else .normal;
    } else switch (failure.kind) {
        .expansion_error => if (eval_context.interactive)
            .normal
        else
            .{ .exit = failure.status },
        .parse_error => if (eval_context.interactive or
            shell_state.trap_execution != .idle or
            eval_context.features.isBash() or
            !eval_context.special_builtin)
            .normal
        else
            .{ .fatal = failure.status },
        .lowering_error, .unsupported_shape => .normal,
    };
    var command_outcome = outcome.CommandOutcome.withControlFlow(allocator, failure.status, state_delta, control_flow);
    errdefer command_outcome.deinit();
    if (failure.fatal_noninteractive and !eval_context.interactive) {
        command_outcome.propagated_failure = .{ .command_substitution = failure.status };
    }
    try command_outcome.addDiagnostic(failure.message);
    try command_outcome.appendStderr(failure.message);
    try command_outcome.appendStderr("\n");
    command_outcome.validateForContext(eval_context);
    return command_outcome;
}

fn bashExpansionFailureIsCommandFailure(
    eval_context: context.EvalContext,
    failure: TrapActionFailure,
    shell_state: state.ShellState,
) bool {
    eval_context.validate();
    failure.validate();
    shell_state.validate();
    return shell_state.trap_execution == .idle and
        failure.kind == .expansion_error and
        (failure.bash_arithmetic_readonly_assignment or
            (eval_context.features.isBash() and
                std.mem.indexOf(u8, failure.message, "expansion error: arithmetic: readonly variable") != null) or
            failure.bash_arithmetic_assignment_only_expansion or
            failure.bash_parameter_assignment_expansion);
}

fn bashArithmeticExpansionFailureIsCommandFailure(
    eval_context: context.EvalContext,
    failure: TrapActionFailure,
    shell_state: state.ShellState,
) bool {
    eval_context.validate();
    failure.validate();
    shell_state.validate();
    return shell_state.trap_execution == .idle and
        failure.kind == .expansion_error and
        failure.bash_arithmetic_expansion;
}

fn runtimeDispositionForTrapDisposition(disposition: state.TrapDisposition) runtime.signal.Disposition {
    return switch (disposition) {
        .default => .default,
        .ignore => .ignore,
        .caught => .caught,
    };
}

fn trapSemanticActionAssert(action: []const u8, signal: state.TrapSignal, eval_context: context.EvalContext) void {
    trap_semantics.assertValidAction(action);
    std.debug.assert(action.len != 0);
    signal.validate();
    eval_context.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
}

fn stageWithTarget(
    stage: pipeline_plan.PipelineStagePlan,
    target: context.ExecutionTarget,
) pipeline_plan.PipelineStagePlan {
    stage.validate();
    return switch (stage) {
        .simple => |simple| blk: {
            var copy = simple;
            copy.target = target;
            copy.validate();
            break :blk .{ .simple = copy };
        },
        .compound => |compound| blk: {
            var copy = compound;
            copy.target = target;
            copy.validate();
            break :blk .{ .compound = copy };
        },
    };
}

fn pipelineStageContext(
    eval_context: context.EvalContext,
    target: context.ExecutionTarget,
    ignore_errexit: bool,
) context.EvalContext {
    const pipeline_context = eval_context.enterPipeline();
    const targeted = pipeline_context.withTarget(target);
    return if (ignore_errexit) targeted.ignoreErrexit() else targeted;
}

fn pipelineCommandText(allocator: std.mem.Allocator, plan: pipeline_plan.PipelinePlan) ![]const u8 {
    plan.validate();
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);

    for (plan.stages, 0..) |stage, index| {
        if (index != 0) try text.appendSlice(allocator, " | ");
        switch (stage) {
            .simple => |simple| try appendSimpleCommandText(allocator, &text, simple),
            .compound => |compound| try text.appendSlice(allocator, compound.kindName()),
        }
    }
    return text.toOwnedSlice(allocator);
}

fn appendSimpleCommandText(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    plan: command_plan.CommandPlan,
) !void {
    plan.validate();
    if (plan.argv.len != 0) return appendCommandTextFromArgv(allocator, text, plan.argv);
    if (plan.assignments.len == 0) return text.append(allocator, ':');
    for (plan.assignments, 0..) |assignment, index| {
        assignment.validate();
        if (index != 0) try text.append(allocator, ' ');
        try text.appendSlice(allocator, assignment.name);
        try text.append(allocator, '=');
        try appendShellSingleQuoted(allocator, text, assignment.value);
    }
}

fn commandTextFromArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    try appendCommandTextFromArgv(allocator, &text, argv);
    return text.toOwnedSlice(allocator);
}

fn appendCommandTextFromArgv(allocator: std.mem.Allocator, text: *std.ArrayList(u8), argv: []const []const u8) !void {
    std.debug.assert(argv.len != 0);
    for (argv, 0..) |arg, index| {
        if (index != 0) try text.append(allocator, ' ');
        try appendShellSingleQuoted(allocator, text, arg);
    }
}

fn pipeFailureMessage(err: runtime.fd.PipeError) []const u8 {
    return switch (err) {
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "too many open files",
        error.Unsupported => "pipes unsupported",
        error.Unexpected => "pipe failed",
    };
}

fn evaluateSimpleCommand(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    return switch (plan.classification) {
        .empty => normalEvaluation(statusForCommandWithoutName(plan)),
        .assignment_only => normalEvaluation(statusForCommandWithoutName(plan)),
        .function_definition => |definition| evaluateFunctionDefinition(definition, state_delta),
        .special_builtin => |definition| evaluateBuiltin(
            evaluator,
            shell_state.*,
            eval_context,
            plan,
            definition,
            state_delta,
            buffers,
        ),
        .regular_builtin => |definition| evaluateBuiltin(
            evaluator,
            shell_state.*,
            eval_context,
            plan,
            definition,
            state_delta,
            buffers,
        ),
        .external => |resolution| normalEvaluation(try evaluateExternal(
            evaluator,
            shell_state.*,
            eval_context,
            plan,
            resolution,
            buffers,
        )),
        .not_found => |not_found| normalEvaluation(try evaluateNotFound(
            evaluator,
            not_found,
            plan.source_line,
            buffers,
        )),
        .function => |definition| evaluateFunction(
            evaluator,
            shell_state,
            eval_context,
            plan,
            definition,
            state_delta,
            buffers,
        ),
    };
}

fn statusForCommandWithoutName(plan: command_plan.CommandPlan) outcome.ExitStatus {
    plan.validate();
    std.debug.assert(plan.argv.len == 0);
    return plan.last_command_substitution_status orelse 0;
}

fn normalEvaluation(status: outcome.ExitStatus) SimpleEvalResult {
    return .{ .status = status };
}

fn evaluationFromRedirectionFailure(
    shell_options: state.ShellOptions,
    eval_context: context.EvalContext,
    failure: redirection_plan.ApplyFailure,
) SimpleEvalResult {
    eval_context.validate();
    runtime.fd.assertValidDescriptor(failure.target);
    const status = consequence.statusForRedirectionFailure(failure.consequence);
    const decision = consequence.decideForRedirectionFailure(
        shell_options,
        eval_context,
        failure.consequence,
        status,
    );
    return .{ .status = status, .control_flow = decision.control_flow };
}

fn commandOutcomeFromBuffers(
    allocator: std.mem.Allocator,
    eval_context: context.EvalContext,
    status: outcome.ExitStatus,
    state_delta: delta.StateDelta,
    control_flow: outcome.ControlFlow,
    buffers: *EvaluationBuffers,
) EvalError!outcome.CommandOutcome {
    std.debug.assert(state_delta.state == .pending);
    control_flow.validate();
    var mutable_delta = state_delta;
    const effective_status = if (buffers.propagated_failure) |failure|
        failure.status()
    else
        status;
    const effective_control_flow = if (buffers.propagated_failure) |failure|
        failure.controlFlow()
    else
        control_flow;
    if (buffers.propagated_failure != null) {
        if (mutable_delta.last_status != null) mutable_delta.last_status = null;
        mutable_delta.setLastStatus(effective_status);
    }

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    try stdout.appendSlice(allocator, buffers.stdout.items);

    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    try stderr.appendSlice(allocator, buffers.stderr.items);

    var side_stdout: std.ArrayList(u8) = .empty;
    errdefer side_stdout.deinit(allocator);
    if (buffers.fold_side_stdout_to_stdout) {
        try stdout.appendSlice(allocator, buffers.side_stdout.items);
    } else {
        try side_stdout.appendSlice(allocator, buffers.side_stdout.items);
    }

    var command_substitution_side_stdout: std.ArrayList(u8) = .empty;
    errdefer command_substitution_side_stdout.deinit(allocator);
    try command_substitution_side_stdout.appendSlice(allocator, buffers.command_substitution_side_stdout.items);

    var pipeline_stdout: std.ArrayList(u8) = .empty;
    errdefer pipeline_stdout.deinit(allocator);
    try pipeline_stdout.appendSlice(allocator, buffers.pipeline_stdout.items);

    var diagnostics: std.ArrayList(outcome.Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| allocator.free(diagnostic.message);
        diagnostics.deinit(allocator);
    }
    for (buffers.diagnostics.items) |message| {
        const owned_message = try allocator.dupe(u8, message);
        errdefer allocator.free(owned_message);
        try diagnostics.append(allocator, .{ .message = owned_message });
    }

    var command_outcome = outcome.CommandOutcome.withControlFlow(
        allocator,
        effective_status,
        mutable_delta,
        effective_control_flow,
    );
    command_outcome.stdout = stdout;
    command_outcome.stderr = stderr;
    command_outcome.side_stdout = side_stdout;
    command_outcome.command_substitution_side_stdout = command_substitution_side_stdout;
    command_outcome.pipeline_stdout = pipeline_stdout;
    command_outcome.diagnostics = diagnostics;
    command_outcome.propagated_failure = buffers.propagated_failure;
    command_outcome.validateForContext(eval_context);
    return command_outcome;
}

fn workingStateForCompound(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    target: context.ExecutionTarget,
) EvalError!state.ShellState {
    shell_state.validate();
    return switch (target) {
        .current_shell => shell_state.clone(allocator),
        .subshell => shell_state.snapshotForSubshell(allocator),
        .child_process => shell_state.clone(allocator),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
}

fn appendSubshellExitTrap(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    result: *SimpleEvalResult,
    buffers: *EvaluationBuffers,
) EvalError!void {
    shell_state.validate();
    eval_context.validate();
    std.debug.assert(eval_context.target == .subshell);
    result.control_flow.validate();
    if (shell_state.getTrapForSignal(.EXIT) == null) return;

    const visible_status = result.control_flow.status(result.status);
    shell_state.last_status = visible_status;
    try shell_state.appendPendingTrap(.EXIT);
    try flushLiveInheritedBufferedOutput(buffers, eval_context, evaluator.io != null);

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = shell_state.shopts.enabled(.expand_aliases);
    var trap_outcome = (try executePendingTrapsWithFrame(
        evaluator,
        shell_state,
        eval_context,
        parser_resolver.resolver(),
        buffers.frame,
    )) orelse return;
    defer trap_outcome.deinit();

    try appendOutcomeBuffers(buffers, trap_outcome);
    try applyOutcomeToWorkingState(shell_state, &trap_outcome, trap_outcome.state_delta.target);
    result.* = .{ .status = trap_outcome.status, .control_flow = trap_outcome.control_flow };
}

fn evaluateCompoundBody(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: command_plan.CompoundBody,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    shell_state.validate();
    eval_context.validate();
    body.validate();

    return switch (body) {
        .sequence => |list| evaluateStatementList(evaluator, shell_state, eval_context, list, buffers),
        .and_or_list => |and_or| evaluateAndOrList(evaluator, shell_state, eval_context, and_or, buffers),
        .negation => |negation| evaluateNegation(evaluator, shell_state, eval_context, negation, buffers),
        .brace_group => |list| evaluateStatementList(evaluator, shell_state, eval_context, list, buffers),
        .subshell => |list| evaluateStatementList(evaluator, shell_state, eval_context, list, buffers),
        .if_clause => |if_plan| evaluateIfClause(evaluator, shell_state, eval_context, if_plan, buffers),
        .while_loop => |loop| evaluateLoop(evaluator, shell_state, eval_context, loop, .while_loop, buffers),
        .until_loop => |loop| evaluateLoop(evaluator, shell_state, eval_context, loop, .until_loop, buffers),
        .for_loop => |for_plan| evaluateForLoop(evaluator, shell_state, eval_context, for_plan, buffers),
        .case_clause => |case_plan| evaluateCaseClause(evaluator, shell_state, eval_context, case_plan, buffers),
    };
}

const StatementChildStateDisposition = union(enum) {
    commit_to_working: context.ExecutionTarget,
    discard_except_status,
};

const StatementChildCompletion = struct {
    stop_list: bool,
    flushed_child_output: bool,
};

fn completeStatementChildResult(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    child_result: SimpleEvalResult,
    result: *SimpleEvalResult,
    buffers: *EvaluationBuffers,
) EvalError!StatementChildCompletion {
    shell_state.validate();
    eval_context.validate();
    child_result.control_flow.validate();

    result.* = child_result;
    if (try runCurrentShellRuntimeTrapBoundary(evaluator, shell_state, eval_context, buffers)) |trap_result| {
        if (trap_result.control_flow != .normal) {
            result.* = trap_result;
            return .{
                .stop_list = true,
                .flushed_child_output = false,
            };
        }
        if (child_result.control_flow == .normal) result.* = trap_result;
    }
    if (eval_context.target == .current_shell and buffers.frame.spec.kind.isParentVisible()) {
        try flushCurrentShellBufferedCommandOutput(
            buffers,
            eval_context,
            evaluator.external_stdio,
            evaluator.io != null,
        );
    } else if (buffers.frame.spec.kind == .trap_handler) {
        try flushLiveInheritedBufferedOutput(buffers, eval_context, evaluator.io != null);
    } else if (!(buffers.frame.spec.eval_target != .current_shell and buffers.frame.spec.kind != .pipeline_stage)) {
        try flushChildShellBufferedCommandOutput(buffers, eval_context);
        try flushLiveInheritedBufferedOutput(buffers, eval_context, evaluator.io != null);
    }
    return .{
        .stop_list = child_result.control_flow != .normal,
        .flushed_child_output = true,
    };
}

fn completeStatementChildOutcome(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    child_outcome: *outcome.CommandOutcome,
    state_disposition: StatementChildStateDisposition,
    statement_plan: ?command_plan.StatementPlan,
    abort_bash_line: ?*?usize,
    result: *SimpleEvalResult,
    buffers: *EvaluationBuffers,
) EvalError!StatementChildCompletion {
    shell_state.validate();
    eval_context.validate();
    child_outcome.validate();
    if (statement_plan) |plan| {
        plan.validate();
        std.debug.assert(abort_bash_line != null);
    } else {
        std.debug.assert(abort_bash_line == null);
    }

    try appendStatementChildOutcomeBuffers(buffers, child_outcome.*);
    switch (state_disposition) {
        .commit_to_working => |target| {
            try applyOutcomeToWorkingState(shell_state, child_outcome, target);
            try configureRuntimeTrapMutations(evaluator, shell_state.*, child_outcome.state_delta);
        },
        .discard_except_status => try applyOutcomeStatusToWorkingState(shell_state, child_outcome.*),
    }

    const completion = try completeStatementChildResult(
        evaluator,
        shell_state,
        eval_context,
        .{ .status = child_outcome.status, .control_flow = child_outcome.effectiveControlFlow() },
        result,
        buffers,
    );
    if (completion.flushed_child_output) {
        if (statement_plan) |plan| {
            if (bashAssignmentErrorAbortsSourceLine(eval_context, plan, child_outcome.*)) {
                abort_bash_line.?.* = statementSourceLine(plan);
            }
        }
    }
    return completion;
}

fn evaluateStatementList(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    list: command_plan.StatementList,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    shell_state.validate();
    eval_context.validate();
    list.validate();

    var result = normalEvaluation(0);
    if (list.commands.len != 0) {
        for (list.commands) |child_plan| {
            child_plan.validate();
            if (noexecSuppressesCommand(shell_state.*, eval_context)) break;
            if (child_plan.target.isIsolatedFromParent()) {
                try flushSubshellBufferedOutputBeforeNestedChild(buffers, eval_context);
                try flushChildShellBufferedCommandOutput(buffers, eval_context);
            }
            try flushBuffersForRedirectionTargetsBetweenCommands(
                buffers,
                eval_context,
                child_plan.redirections,
                evaluator.external_stdio,
            );
            var child_outcome = try evaluatePlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(child_plan.target),
                child_plan,
                buffers.stdin,
                buffers.frame,
            );
            defer child_outcome.deinit();

            const completion = try completeStatementChildOutcome(
                evaluator,
                shell_state,
                eval_context,
                &child_outcome,
                .{ .commit_to_working = child_plan.target },
                null,
                null,
                &result,
                buffers,
            );
            if (completion.stop_list) break;
        }
        return result;
    }

    var abort_bash_line: ?usize = null;
    for (list.statements, 0..) |entry, index| {
        entry.validate(index);
        if (abort_bash_line) |line| {
            if (statementSourceLine(entry.plan) == line) continue;
            abort_bash_line = null;
        }
        const should_run = switch (entry.op_before) {
            .sequence => true,
            .and_if => result.status == 0,
            .or_if => result.status != 0,
        };
        if (!should_run) continue;
        if (noexecSuppressesCommand(shell_state.*, eval_context)) break;
        if (statementPlanRunsIsolated(entry.plan)) {
            try flushSubshellBufferedOutputBeforeNestedChild(buffers, eval_context);
        }
        try flushChildShellBufferedCommandOutput(buffers, eval_context);

        var child_context = eval_context;
        if (index + 1 < list.statements.len) {
            switch (list.statements[index + 1].op_before) {
                .sequence => {},
                .and_if, .or_if => child_context = child_context.ignoreErrexit(),
            }
        }

        try flushBuffersForStatementRedirections(
            buffers,
            child_context,
            entry.plan,
            evaluator.external_stdio,
            evaluator.io != null,
        );
        var child_outcome = try evaluateStatementPlan(
            evaluator,
            shell_state,
            child_context,
            entry.plan,
            buffers.stdin,
            buffers.frame,
        );
        defer child_outcome.deinit();

        const state_disposition: StatementChildStateDisposition = if (statementPlanCommitsStateToParent(entry.plan))
            .{ .commit_to_working = child_outcome.state_delta.target }
        else
            .discard_except_status;
        const completion = try completeStatementChildOutcome(
            evaluator,
            shell_state,
            eval_context,
            &child_outcome,
            state_disposition,
            entry.plan,
            &abort_bash_line,
            &result,
            buffers,
        );
        if (completion.stop_list) break;
    }
    return result;
}

fn noexecSuppressesCommand(shell_state: state.ShellState, eval_context: context.EvalContext) bool {
    shell_state.validate();
    eval_context.validate();
    return shell_state.options.enabled(.noexec) and !eval_context.interactive;
}

fn evaluateFunctionStatementList(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    list: command_plan.StatementList,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    shell_state.validate();
    eval_context.validate();
    list.validate();

    var result = normalEvaluation(0);
    if (list.commands.len != 0) {
        for (list.commands, 0..) |child_plan, index| {
            child_plan.validate();
            if (noexecSuppressesCommand(shell_state.*, eval_context)) break;
            try flushBuffersForRedirectionTargetsBetweenCommands(
                buffers,
                eval_context,
                child_plan.redirections,
                evaluator.external_stdio,
            );
            if (index + 1 == list.commands.len) {
                if (try ownedTailFunctionCallPlan(
                    evaluator,
                    shell_state.*,
                    eval_context,
                    child_plan,
                    tail_context,
                    buffers,
                )) |tail_plan| {
                    return .{ .tail_call = tail_plan };
                }
            }

            var child_outcome = try evaluatePlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(child_plan.target),
                child_plan,
                buffers.stdin,
                buffers.frame,
            );
            defer child_outcome.deinit();

            const completion = try completeStatementChildOutcome(
                evaluator,
                shell_state,
                eval_context,
                &child_outcome,
                .{ .commit_to_working = child_plan.target },
                null,
                null,
                &result,
                buffers,
            );
            if (completion.stop_list) break;
        }
        return .{ .result = result };
    }

    var abort_bash_line: ?usize = null;
    for (list.statements, 0..) |entry, index| {
        entry.validate(index);
        if (abort_bash_line) |line| {
            if (statementSourceLine(entry.plan) == line) continue;
            abort_bash_line = null;
        }
        const should_run = switch (entry.op_before) {
            .sequence => true,
            .and_if => result.status == 0,
            .or_if => result.status != 0,
        };
        if (!should_run) continue;
        if (noexecSuppressesCommand(shell_state.*, eval_context)) break;

        var child_context = eval_context;
        if (index + 1 < list.statements.len) {
            switch (list.statements[index + 1].op_before) {
                .sequence => {},
                .and_if, .or_if => child_context = child_context.ignoreErrexit(),
            }
        }

        try flushBuffersForStatementRedirections(
            buffers,
            child_context,
            entry.plan,
            evaluator.external_stdio,
            evaluator.io != null,
        );
        if (index + 1 == list.statements.len) {
            if (try evaluateFunctionTailStatementPlan(
                evaluator,
                shell_state,
                child_context,
                entry.plan,
                tail_context,
                buffers,
            )) |tail_result| {
                switch (tail_result) {
                    .tail_call => return tail_result,
                    .call_function => unreachable,
                    .result => |tail_simple_result| {
                        const tail_control_flow = tail_simple_result.control_flow;
                        result = tail_simple_result;
                        if (try runCurrentShellRuntimeTrapBoundary(
                            evaluator,
                            shell_state,
                            eval_context,
                            buffers,
                        )) |trap_result| {
                            if (trap_result.control_flow != .normal) {
                                result = trap_result;
                            } else if (tail_control_flow == .normal) {
                                result = trap_result;
                            }
                        }
                        try flushCurrentShellBufferedCommandOutput(
                            buffers,
                            eval_context,
                            evaluator.external_stdio,
                            evaluator.io != null,
                        );
                    },
                }
                return .{ .result = result };
            }
        }

        var child_outcome = try evaluateStatementPlan(
            evaluator,
            shell_state,
            child_context,
            entry.plan,
            buffers.stdin,
            buffers.frame,
        );
        defer child_outcome.deinit();

        const state_disposition: StatementChildStateDisposition = if (statementPlanCommitsStateToParent(entry.plan))
            .{ .commit_to_working = child_outcome.state_delta.target }
        else
            .discard_except_status;
        const completion = try completeStatementChildOutcome(
            evaluator,
            shell_state,
            eval_context,
            &child_outcome,
            state_disposition,
            entry.plan,
            &abort_bash_line,
            &result,
            buffers,
        );
        if (completion.stop_list) break;
    }
    return .{ .result = result };
}

fn evaluateFunctionTailStatementPlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.StatementPlan,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!?FunctionBodyEvalResult {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    return switch (plan) {
        .simple => |simple| if (try ownedTailFunctionCallPlan(
            evaluator,
            shell_state.*,
            eval_context,
            simple,
            tail_context,
            buffers,
        )) |tail_plan| .{ .tail_call = tail_plan } else null,
        .compound => |compound| evaluateFunctionTailCompoundPlan(
            evaluator,
            shell_state,
            eval_context,
            compound,
            tail_context,
            buffers,
        ),
        .source => |source| evaluateFunctionTailSourceStatementPlan(
            evaluator,
            shell_state,
            eval_context,
            source,
            tail_context,
            buffers,
        ),
        .ir_source => |source| evaluateFunctionTailIrSourceStatementPlan(
            evaluator,
            shell_state,
            eval_context,
            source,
            tail_context,
            buffers,
        ),
        .pipeline => null,
    };
}

fn evaluateFunctionTailSourceStatementPlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source_plan: command_plan.SourceStatementPlan,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!?FunctionBodyEvalResult {
    source_plan.validate();
    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = source_plan.expand_aliases and shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = buffers.frame;
    parser_resolver.active_input = buffers.stdin;
    parser_resolver.source_line_offset = source_plan.line;
    var body = (parser_resolver.lowerSource(
        evaluator.allocator,
        source_plan.source,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    }) orelse return error.Unimplemented;
    defer body.deinit();
    if (try evaluateFunctionTailTrapActionBody(
        evaluator,
        shell_state,
        eval_context,
        body,
        tail_context,
        buffers,
    )) |tail_result| return tail_result;
    return @as(
        ?FunctionBodyEvalResult,
        try evaluateFunctionTrapActionBodyResult(evaluator, shell_state, eval_context, body, buffers),
    );
}

fn evaluateFunctionTailIrSourceStatementPlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source_plan: command_plan.IrStatementPlan,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!?FunctionBodyEvalResult {
    source_plan.validate();
    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = source_plan.expand_aliases and shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = buffers.frame;
    parser_resolver.active_input = buffers.stdin;
    parser_resolver.source_line_offset = source_plan.line -| sourceLineIndex(
        source_plan.program.source,
        source_plan.program.statements[source_plan.statement_index].span.start,
    );
    var body = (parser_resolver.lowerProgramStatement(
        evaluator.allocator,
        source_plan.program.*,
        source_plan.statement_index,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    });
    defer body.deinit();
    if (try evaluateFunctionTailTrapActionBody(
        evaluator,
        shell_state,
        eval_context,
        body,
        tail_context,
        buffers,
    )) |tail_result| return tail_result;
    return @as(
        ?FunctionBodyEvalResult,
        try evaluateFunctionTrapActionBodyResult(evaluator, shell_state, eval_context, body, buffers),
    );
}

fn evaluateFunctionTailTrapActionBody(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: TrapActionBody,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!?FunctionBodyEvalResult {
    body.validate();
    return switch (body) {
        .simple => |simple| if (try ownedTailFunctionCallPlan(
            evaluator,
            shell_state.*,
            eval_context.withTarget(simple.target),
            simple,
            tail_context,
            buffers,
        )) |tail_plan| .{ .tail_call = tail_plan } else null,
        .compound => |compound| evaluateFunctionTailCompoundPlan(
            evaluator,
            shell_state,
            eval_context.withTarget(compound.target),
            compound,
            tail_context,
            buffers,
        ),
        .owned => |owned| switch (owned.body) {
            .simple => |simple| if (try ownedTailFunctionCallPlan(
                evaluator,
                shell_state.*,
                eval_context.withTarget(simple.target),
                simple,
                tail_context,
                buffers,
            )) |tail_plan| .{ .tail_call = tail_plan } else null,
            .compound => |compound| evaluateFunctionTailCompoundPlan(
                evaluator,
                shell_state,
                eval_context.withTarget(compound.target),
                compound,
                tail_context,
                buffers,
            ),
            .pipeline, .failure => null,
        },
        .pipeline, .failure => null,
    };
}

fn evaluateFunctionTrapActionBodyResult(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: TrapActionBody,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    var body_outcome = try evaluateTrapActionBodyWithInputInFrame(
        evaluator,
        shell_state,
        eval_context,
        body,
        buffers.stdin,
        buffers.frame,
    );
    defer body_outcome.deinit();

    try appendOutcomeBuffers(buffers, body_outcome);
    if (trapActionBodyCommitsStateToParent(body)) {
        try applyOutcomeToWorkingState(shell_state, &body_outcome, body_outcome.state_delta.target);
    } else {
        try applyOutcomeStatusToWorkingState(shell_state, body_outcome);
    }
    return .{ .result = .{ .status = body_outcome.status, .control_flow = body_outcome.effectiveControlFlow() } };
}

fn evaluateFunctionTailCompoundPlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CompoundCommandPlan,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!?FunctionBodyEvalResult {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    if (plan.target != .current_shell) return null;
    if (plan.redirections.steps.len != 0) return null;
    if (shell_state.options.enabled(.errexit)) return null;

    return switch (plan.body) {
        .sequence, .brace_group => |nested_list| @as(?FunctionBodyEvalResult, try evaluateFunctionStatementList(
            evaluator,
            shell_state,
            eval_context,
            nested_list,
            tail_context,
            buffers,
        )),
        .if_clause => |if_plan| @as(?FunctionBodyEvalResult, try evaluateFunctionIfClause(
            evaluator,
            shell_state,
            eval_context,
            if_plan,
            tail_context,
            buffers,
        )),
        .and_or_list,
        .negation,
        .subshell,
        .while_loop,
        .until_loop,
        .for_loop,
        .case_clause,
        => null,
    };
}

fn evaluateFunctionIfClause(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    if_plan: command_plan.IfPlan,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    if_plan.validate();
    for (if_plan.branches) |branch| {
        const stderr_before = buffers.stderr.items.len;
        const diagnostics_before = buffers.diagnostics.items.len;
        const condition = try evaluateStatementList(
            evaluator,
            shell_state,
            eval_context.ignoreErrexit(),
            branch.condition,
            buffers,
        );
        if (condition.control_flow != .normal) return .{ .result = condition };
        if (bashAssignmentErrorBuffersAbortSourceLine(
            eval_context,
            buffers.*,
            stderr_before,
            diagnostics_before,
            condition,
        )) return .{ .result = condition };
        if (condition.status == 0) return evaluateFunctionStatementList(
            evaluator,
            shell_state,
            eval_context,
            branch.body,
            tail_context,
            buffers,
        );
    }
    return evaluateFunctionStatementList(
        evaluator,
        shell_state,
        eval_context,
        if_plan.else_body,
        tail_context,
        buffers,
    );
}

fn ownedTailFunctionCallPlan(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!?command_plan.CommandPlan {
    if (!tailFunctionCallEligible(evaluator.*, shell_state, eval_context, plan, tail_context)) return null;
    try appendPlanExpansionOutput(evaluator.*, eval_context, plan, buffers);
    var trace_state = shell_state;
    try traceCommandPlanForEvaluation(
        evaluator,
        &trace_state,
        eval_context,
        plan,
        buffers.stdin,
        buffers.frame,
        buffers,
    );
    try flushCurrentShellBufferedCommandOutput(buffers, eval_context, evaluator.external_stdio, evaluator.io != null);
    return command_plan.cloneCommandPlan(evaluator.allocator, plan) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn tailFunctionCallEligible(
    evaluator: Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    tail_context: FunctionTailCallContext,
) bool {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    if (tail_context.call_has_redirections or tail_context.definition_has_redirections) return false;
    if (eval_context.target != .current_shell) return false;
    if (eval_context.subshell_depth != 0 or
        eval_context.pipeline_depth != 0 or
        eval_context.command_substitution_depth != 0) return false;
    if (shell_state.scope != .current_shell or !shell_state.acceptsExecutionTarget(.current_shell)) return false;
    if (shell_state.options.enabled(.errexit)) return false;
    if (shell_state.traps.count() != 0 or
        shell_state.pending_traps.items.len != 0 or
        shell_state.pending_exit != null or
        shell_state.trap_execution != .idle) return false;
    if (plan.target != .current_shell) return false;
    if (plan.assignments.len != 0 or plan.redirections.steps.len != 0) return false;
    const frame = evaluator.function_frame orelse return false;
    if (frame.assignment_prefixes.len != 0 or frame.local_names.items.len != 0) return false;
    return switch (plan.classification) {
        .function => true,
        .empty,
        .assignment_only,
        .function_definition,
        .special_builtin,
        .regular_builtin,
        .external,
        .not_found,
        => false,
    };
}

fn statementSourceLine(plan: command_plan.StatementPlan) ?usize {
    plan.validate();
    return switch (plan) {
        .source => |source| source.line,
        .ir_source => |source| source.line,
        .simple, .compound, .pipeline => null,
    };
}

fn traceCommandPlanForEvaluation(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    trace_input: *EvaluationInput,
    trace_frame: *execution_frame.ExecutionFrame,
    buffers: *EvaluationBuffers,
) EvalError!void {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    trace_input.validate();
    trace_frame.validate();
    buffers.frame.validate();
    buffers.stdin.validate();

    if (!shell_state.options.enabled(.xtrace)) return;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(buffers.allocator);
    try appendXtraceCommandText(buffers.allocator, &text, plan);

    var frame = OutputFrame.initOutcomeCapture(buffers);
    defer frame.deinit();
    try appendXtracePrefix(evaluator, shell_state, eval_context, trace_frame, trace_input, &frame);
    try frame.write(2, text.items);
    try frame.write(2, "\n");
}

fn appendXtracePrefix(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    parent_frame: *execution_frame.ExecutionFrame,
    parent_input: *EvaluationInput,
    frame: *OutputFrame,
) EvalError!void {
    shell_state.validate();
    eval_context.validate();
    parent_frame.validate();
    parent_input.validate();
    const raw_prefix = if (shell_state.getVariable("PS4")) |variable| variable.value else "";
    if (raw_prefix.len == 0) return;

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = eval_context.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.active_frame = parent_frame;
    parser_resolver.active_input = parent_input;

    var command_resolver: ParserCommandSubstitutionResolver = .{
        .owner = &parser_resolver,
        .signal = null,
        .expansion_context = undefined,
    };
    var command_substitutions = CommandSubstitutionExpansionContext.init(
        evaluator,
        shell_state,
        eval_context,
        command_resolver.commandSubstitutionResolver(),
        parser_resolver.resolver(),
        parent_frame,
        parent_input,
    );
    command_substitutions.suppress_inherited_xtrace = true;
    defer command_substitutions.deinit();
    command_resolver.expansion_context = &command_substitutions;

    var process_id_buffer: [32]u8 = undefined;
    var last_background_pid_buffer: [32]u8 = undefined;
    var expansion = shell_expand.ShellExpansion.init(evaluator.allocator, .{
        .shell_state = shell_state,
        .eval_context = eval_context,
        .fs_port = evaluator.fs_port,
        .features = evaluator.features,
        .command_substitution = command_substitutions.commandSubstitution(),
        .arg_zero = evaluator.arg_zero,
        .process_id = std.fmt.bufPrint(&process_id_buffer, "{d}", .{evaluator.shell_pid}) catch "",
        .last_background_pid = if (shell_state.last_background_pid) |pid|
            std.fmt.bufPrint(&last_background_pid_buffer, "{d}", .{pid}) catch ""
        else
            "",
    });
    defer expansion.deinit();

    const expanded_prefix = expansion.expandHereDocBody(raw_prefix) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unimplemented => return error.Unimplemented,
        else => raw_prefix,
    };
    const expanded_prefix_owned = expanded_prefix.ptr != raw_prefix.ptr;
    defer if (expanded_prefix_owned) evaluator.allocator.free(expanded_prefix);

    if (command_substitutions.stderr.items.len != 0) try frame.write(2, command_substitutions.stderr.items);
    for (command_substitutions.diagnostics.items) |diagnostic| {
        try frame.buffers.addDiagnosticMessage(diagnostic.message);
    }
    try frame.write(2, expanded_prefix);
}

fn appendXtraceCommandText(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    plan: command_plan.CommandPlan,
) !void {
    plan.validate();
    for (plan.assignments, 0..) |assignment, index| {
        if (index != 0) try text.append(allocator, ' ');
        try text.appendSlice(allocator, assignment.name);
        try text.append(allocator, '=');
        try text.appendSlice(allocator, assignment.value);
    }
    for (plan.argv, 0..) |arg, index| {
        if (index != 0 or plan.assignments.len != 0) try text.append(allocator, ' ');
        try text.appendSlice(allocator, arg);
    }
}

fn sourceLineIndex(source: []const u8, offset: usize) usize {
    std.debug.assert(offset <= source.len);
    var line: usize = 0;
    for (source[0..offset]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn bashAssignmentErrorAbortsSourceLine(
    eval_context: context.EvalContext,
    plan: command_plan.StatementPlan,
    child_outcome: outcome.CommandOutcome,
) bool {
    eval_context.validate();
    plan.validate();
    child_outcome.validateForContext(eval_context);
    if (statementSourceLine(plan) == null) return false;
    return bashAssignmentErrorOutcomeAbortsSourceLine(eval_context, child_outcome);
}

fn bashAssignmentErrorOutcomeAbortsSourceLine(
    eval_context: context.EvalContext,
    child_outcome: outcome.CommandOutcome,
) bool {
    eval_context.validate();
    child_outcome.validateForContext(eval_context);
    if (!eval_context.features.isBash()) return false;
    if (eval_context.canReturnFromFunction()) return false;
    if (child_outcome.status != 1 or child_outcome.control_flow != .normal) return false;
    for (child_outcome.diagnostics.items) |diagnostic| {
        if (bashAssignmentErrorDiagnosticAbortsSourceLine(diagnostic.message)) return true;
    }
    return bashAssignmentErrorTextAbortsSourceLine(child_outcome.stderr.items);
}

fn bashAssignmentErrorBuffersAbortSourceLine(
    eval_context: context.EvalContext,
    buffers: EvaluationBuffers,
    stderr_before: usize,
    diagnostics_before: usize,
    result: SimpleEvalResult,
) bool {
    eval_context.validate();
    buffers.stdin.validate();
    result.control_flow.validateForContext(eval_context);
    std.debug.assert(stderr_before <= buffers.stderr.items.len);
    std.debug.assert(diagnostics_before <= buffers.diagnostics.items.len);
    if (!eval_context.features.isBash()) return false;
    if (eval_context.canReturnFromFunction()) return false;
    if (result.status != 1 or result.control_flow != .normal) return false;
    for (buffers.diagnostics.items[diagnostics_before..]) |message| {
        if (bashAssignmentErrorDiagnosticAbortsSourceLine(message)) return true;
    }
    return bashAssignmentErrorTextAbortsSourceLine(buffers.stderr.items[stderr_before..]);
}

fn bashAssignmentErrorDiagnosticAbortsSourceLine(message: []const u8) bool {
    return std.mem.endsWith(u8, message, ": readonly variable") or
        std.mem.indexOf(u8, message, "expansion error: arithmetic:") != null;
}

fn bashAssignmentErrorTextAbortsSourceLine(text: []const u8) bool {
    return std.mem.endsWith(u8, text, ": readonly variable\n") or
        std.mem.indexOf(u8, text, "expansion error: arithmetic:") != null;
}

fn flushBuffersForStatementRedirections(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
    plan: command_plan.StatementPlan,
    external_stdio: ExternalStdio,
    live_stdio: bool,
) EvalError!void {
    eval_context.validate();
    plan.validate();
    switch (plan) {
        .simple => |simple| try flushBuffersForRedirectionTargetsBetweenCommands(
            buffers,
            eval_context,
            simple.redirections,
            external_stdio,
        ),
        .compound => |compound| try flushBuffersForRedirectionTargetsBetweenCommands(
            buffers,
            eval_context,
            compound.redirections,
            external_stdio,
        ),
        .pipeline => try flushCurrentShellBufferedCommandOutput(buffers, eval_context, external_stdio, live_stdio),
        .source => |source| try flushBuffersForSourceRedirectionTargets(buffers, eval_context, source, external_stdio),
        .ir_source => |source| try flushBuffersForIrSourceRedirectionTargets(
            buffers,
            eval_context,
            source,
            external_stdio,
        ),
    }
}

fn flushBuffersForRedirectionTargetsBetweenCommands(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
    redirections: redirection_plan.RedirectionPlan,
    external_stdio: ExternalStdio,
) EvalError!void {
    eval_context.validate();
    redirections.validate();
    if (eval_context.command_substitution_depth != 0) return;
    const flush_stdout = buffers.stdout.items.len != 0 and redirectionTargetsDescriptor(redirections, 1);
    const flush_stderr = buffers.stderr.items.len != 0 and redirectionTargetsDescriptor(redirections, 2);
    if (!flush_stdout and !flush_stderr) return;
    if (!evalContextCanFlushBufferedOutputBetweenCommands(eval_context)) return;
    switch (external_stdio) {
        .capture => {
            if (!evalContextCapturesSubshellOutput(eval_context)) return;
            if (flush_stdout) try moveBufferedOutput(buffers.allocator, &buffers.stdout, &buffers.side_stdout);
        },
        .capture_stdout => {
            if (!flush_stderr) return;
            var frame = OutputFrame.initInherited(buffers);
            defer frame.deinit();
            try frame.flushPendingDescriptor(2);
        },
        .inherit_output, .inherit => try flushBuffersForRedirectionTargets(buffers, redirections),
    }
}

fn evalContextCanFlushBufferedOutputBetweenCommands(eval_context: context.EvalContext) bool {
    eval_context.validate();
    return switch (eval_context.target) {
        .current_shell, .subshell => true,
        .child_process => false,
    };
}

fn evalContextCapturesSubshellOutput(eval_context: context.EvalContext) bool {
    eval_context.validate();
    return eval_context.target == .subshell or eval_context.subshell_depth != 0;
}

fn flushBuffersForSourceRedirectionTargets(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
    source: command_plan.SourceStatementPlan,
    external_stdio: ExternalStdio,
) EvalError!void {
    eval_context.validate();
    source.validate();
    if (eval_context.command_substitution_depth != 0) return;
    if (!evalContextCanFlushBufferedOutputBetweenCommands(eval_context)) return;
    if (external_stdio == .capture) {
        if (!evalContextCapturesSubshellOutput(eval_context)) return;
        if (source.targets_stdout) try moveBufferedOutput(buffers.allocator, &buffers.stdout, &buffers.side_stdout);
        return;
    }
    if (!buffers.frame.spec.kind.isParentVisible() and !evalContextCapturesSubshellOutput(eval_context)) return;
    var frame = OutputFrame.initInherited(buffers);
    defer frame.deinit();
    if (source.targets_stdout and external_stdio != .capture_stdout) try frame.flushPendingDescriptor(1);
    if (source.targets_stderr) try frame.flushPendingDescriptor(2);
}

fn flushBuffersForIrSourceRedirectionTargets(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
    source: command_plan.IrStatementPlan,
    external_stdio: ExternalStdio,
) EvalError!void {
    eval_context.validate();
    source.validate();
    if (eval_context.command_substitution_depth != 0) return;
    if (!evalContextCanFlushBufferedOutputBetweenCommands(eval_context)) return;
    if (external_stdio == .capture) {
        if (!evalContextCapturesSubshellOutput(eval_context)) return;
        if (source.targets_stdout) try moveBufferedOutput(buffers.allocator, &buffers.stdout, &buffers.side_stdout);
        return;
    }
    if (!buffers.frame.spec.kind.isParentVisible() and !evalContextCapturesSubshellOutput(eval_context)) return;
    var frame = OutputFrame.initInherited(buffers);
    defer frame.deinit();
    if (source.targets_stdout and external_stdio != .capture_stdout) try frame.flushPendingDescriptor(1);
    if (source.targets_stderr) try frame.flushPendingDescriptor(2);
}

fn rawRedirectionsTargetDescriptor(redirections: []const ir.Redirection, descriptor: runtime.fd.Descriptor) bool {
    for (redirections) |redirection| {
        const operator = redirectionOperator(redirection.operator) orelse continue;
        const target = if (redirection.io_number) |io_number| std.fmt.parseInt(
            runtime.fd.Descriptor,
            io_number.text,
            10,
        ) catch continue else operator.defaultDescriptor();
        if (target == descriptor) return true;
    }
    return false;
}

fn evaluateStatementPlan(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.StatementPlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    input.validate();
    frame.validate();
    return switch (plan) {
        .simple => |simple| evaluatePlanWithInput(
            evaluator,
            shell_state,
            eval_context.withTarget(simple.target),
            simple,
            input,
            frame,
        ),
        .compound => |compound| evaluateCompoundPlanWithInput(
            evaluator,
            shell_state,
            eval_context.withTarget(compound.target),
            compound,
            input,
            frame,
        ),
        .pipeline => |pipeline| evaluatePipelinePlanWithFrame(evaluator, shell_state, eval_context, pipeline, frame),
        .source => |source| evaluateSourceStatement(evaluator, shell_state, eval_context, source, input, frame),
        .ir_source => |source| evaluateIrSourceStatement(evaluator, shell_state, eval_context, source, input, frame),
    };
}

fn evaluateSourceStatement(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source_plan: command_plan.SourceStatementPlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    source_plan.validate();
    input.validate();
    frame.validate();
    std.debug.assert(source_plan.target == eval_context.target or
        (source_plan.target == .current_shell and eval_context.target == .subshell));

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = source_plan.expand_aliases and shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = frame;
    parser_resolver.active_input = input;
    parser_resolver.source_line_offset = source_plan.line;
    var body = (parser_resolver.lowerSource(
        evaluator.allocator,
        source_plan.source,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    }) orelse return error.Unimplemented;
    defer body.deinit();

    return evaluateTrapActionBodyWithInputInFrame(evaluator, shell_state, eval_context, body, input, frame);
}

fn evaluateIrSourceStatement(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source_plan: command_plan.IrStatementPlan,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    source_plan.validate();
    input.validate();
    frame.validate();
    std.debug.assert(source_plan.target == eval_context.target or
        (source_plan.target == .current_shell and eval_context.target == .subshell));

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = source_plan.expand_aliases and shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = frame;
    parser_resolver.active_input = input;
    parser_resolver.source_line_offset = source_plan.line -| sourceLineIndex(
        source_plan.program.source,
        source_plan.program.statements[source_plan.statement_index].span.start,
    );
    var body = (parser_resolver.lowerProgramStatement(
        evaluator.allocator,
        source_plan.program.*,
        source_plan.statement_index,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    });
    defer body.deinit();

    return evaluateTrapActionBodyWithInputInFrame(evaluator, shell_state, eval_context, body, input, frame);
}

fn evaluateAndOrList(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    and_or: command_plan.AndOrPlan,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    and_or.validate();
    var result = normalEvaluation(0);
    for (and_or.commands, 0..) |entry, index| {
        entry.validate(index);
        const should_run = if (index == 0) true else switch (entry.operator.?) {
            .and_if => result.status == 0,
            .or_if => result.status != 0,
        };
        if (!should_run) continue;

        const child_context = if (index + 1 < and_or.commands.len)
            eval_context.ignoreErrexit().withTarget(entry.command.target)
        else
            eval_context.withTarget(entry.command.target);
        var child_outcome = try evaluatePlanWithInput(
            evaluator,
            shell_state,
            child_context,
            entry.command,
            buffers.stdin,
            buffers.frame,
        );
        defer child_outcome.deinit();

        try appendOutcomeBuffers(buffers, child_outcome);
        try applyOutcomeToWorkingState(shell_state, &child_outcome, entry.command.target);
        try configureRuntimeTrapMutations(evaluator, shell_state.*, child_outcome.state_delta);

        const child_control_flow = child_outcome.effectiveControlFlow();
        result = .{ .status = child_outcome.status, .control_flow = child_control_flow };
        if (try runCurrentShellRuntimeTrapBoundary(evaluator, shell_state, eval_context, buffers)) |trap_result| {
            if (trap_result.control_flow != .normal) {
                result = trap_result;
                break;
            }
            if (child_control_flow == .normal) result = trap_result;
        }
        if (eval_context.target == .current_shell) {
            try flushCurrentShellBufferedCommandOutput(
                buffers,
                eval_context,
                evaluator.external_stdio,
                evaluator.io != null,
            );
        } else {
            try flushChildShellBufferedCommandOutput(buffers, eval_context);
            try flushLiveInheritedBufferedOutput(buffers, eval_context, evaluator.io != null);
        }
        if (bashAssignmentErrorOutcomeAbortsSourceLine(eval_context, child_outcome)) break;
        if (child_control_flow != .normal) break;
    }
    return result;
}

fn statementPlanCommitsStateToParent(plan: command_plan.StatementPlan) bool {
    plan.validate();
    return switch (plan) {
        .compound => |compound| compound.body != .subshell,
        .ir_source => |source| source.program.statements[source.statement_index].kind != .subshell,
        .simple, .pipeline, .source => true,
    };
}

fn statementPlanRunsIsolated(plan: command_plan.StatementPlan) bool {
    plan.validate();
    return switch (plan) {
        .simple => |simple| simple.target.isIsolatedFromParent(),
        .compound => |compound| compound.target.isIsolatedFromParent(),
        .ir_source => |source| source.program.statements[source.statement_index].kind == .subshell,
        .pipeline, .source => false,
    };
}

fn flushSubshellBufferedOutputBeforeNestedChild(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
) EvalError!void {
    eval_context.validate();
    if (!evalContextCapturesSubshellOutput(eval_context)) return;
    var frame = OutputFrame.initInherited(buffers);
    defer frame.deinit();
    try frame.flushPendingStandardDescriptors();
}

fn applyOutcomeStatusToWorkingState(
    shell_state: *state.ShellState,
    command_outcome: outcome.CommandOutcome,
) EvalError!void {
    shell_state.validate();
    command_outcome.validate();
    shell_state.last_status = command_outcome.effectiveControlFlow().status(command_outcome.status);
    if (command_outcome.state_delta.last_pipeline_statuses) |statuses| {
        shell_state.setLastPipelineStatuses(statuses) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
}

fn evaluateNegation(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    negation: command_plan.NegationPlan,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    negation.validate();
    var result = try evaluateStatementList(
        evaluator,
        shell_state,
        eval_context.ignoreErrexit(),
        negation.body,
        buffers,
    );
    if (result.control_flow == .normal) result.status = if (result.status == 0) 1 else 0;
    return result;
}

fn evaluateIfClause(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    if_plan: command_plan.IfPlan,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    if_plan.validate();
    for (if_plan.branches) |branch| {
        const stderr_before = buffers.stderr.items.len;
        const diagnostics_before = buffers.diagnostics.items.len;
        const condition = try evaluateStatementList(
            evaluator,
            shell_state,
            eval_context.ignoreErrexit(),
            branch.condition,
            buffers,
        );
        if (condition.control_flow != .normal) return condition;
        if (bashAssignmentErrorBuffersAbortSourceLine(
            eval_context,
            buffers.*,
            stderr_before,
            diagnostics_before,
            condition,
        )) return condition;
        if (condition.status == 0) return evaluateStatementList(
            evaluator,
            shell_state,
            eval_context,
            branch.body,
            buffers,
        );
    }
    return evaluateStatementList(evaluator, shell_state, eval_context, if_plan.else_body, buffers);
}

const LoopKind = enum { while_loop, until_loop };

fn evaluateLoop(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    loop: command_plan.LoopPlan,
    kind: LoopKind,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    loop.validate();
    const loop_context = eval_context.enterLoop();
    var result = normalEvaluation(0);

    while (true) {
        const stderr_before = buffers.stderr.items.len;
        const diagnostics_before = buffers.diagnostics.items.len;
        const condition = if (loop.condition_source) |source|
            try evaluateStatementListSource(evaluator, shell_state, loop_context.ignoreErrexit(), source, buffers)
        else
            try evaluateStatementList(evaluator, shell_state, loop_context.ignoreErrexit(), loop.condition, buffers);
        if (condition.control_flow != .normal) {
            switch (consumeLoopControl(condition.control_flow)) {
                .stop => return normalEvaluation(0),
                .repeat => continue,
                .propagate => |flow| return .{ .status = flow.status(condition.status), .control_flow = flow },
                .other => return condition,
            }
        }
        if (bashAssignmentErrorBuffersAbortSourceLine(
            eval_context,
            buffers.*,
            stderr_before,
            diagnostics_before,
            condition,
        )) return condition;

        const should_run = switch (kind) {
            .while_loop => condition.status == 0,
            .until_loop => condition.status != 0,
        };
        if (!should_run) return result;

        const body = if (loop.body_source) |source|
            try evaluateStatementListSource(evaluator, shell_state, loop_context, source, buffers)
        else
            try evaluateStatementList(evaluator, shell_state, loop_context, loop.body, buffers);
        try flushCurrentShellBufferedCommandOutput(
            buffers,
            eval_context,
            evaluator.external_stdio,
            evaluator.io != null,
        );
        switch (consumeLoopControl(body.control_flow)) {
            .stop => return normalEvaluation(0),
            .repeat => {
                result = normalEvaluation(body.status);
                continue;
            },
            .propagate => |flow| return .{ .status = flow.status(body.status), .control_flow = flow },
            .other => {
                if (body.control_flow != .normal) return body;
                result = normalEvaluation(body.status);
            },
        }
    }
}

fn evaluateForLoop(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    for_plan: command_plan.ForPlan,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    for_plan.validate();
    try appendExpansionOutput(evaluator.*, eval_context, for_plan.expansion_output, buffers);
    try flushCurrentShellBufferedCommandOutput(
        buffers,
        eval_context,
        evaluator.external_stdio,
        evaluator.io != null,
    );
    const loop_context = eval_context.enterLoop();
    var positional_words: ?[][]const u8 = null;
    defer if (positional_words) |words| freeForLoopWords(evaluator.allocator, words);
    var source_words: ?[][]const u8 = null;
    defer if (source_words) |words| freeForLoopWords(evaluator.allocator, words);

    const words = switch (for_plan.words) {
        .explicit => |explicit| explicit,
        .source => |source| blk: {
            switch (try expandForLoopSourceWords(evaluator, shell_state, eval_context, source, buffers)) {
                .words => |expanded| {
                    source_words = expanded;
                    break :blk expanded;
                },
                .failure => |result| return result,
            }
        },
        .positional_parameters => blk: {
            const snapshot = try cloneForLoopWords(evaluator.allocator, shell_state.positionals.items);
            positional_words = snapshot;
            break :blk snapshot;
        },
    };

    var result = normalEvaluation(0);
    for (words) |word| {
        const readonly_failure = try forLoopReadonlyAssignmentFailure(
            shell_state.*,
            eval_context,
            for_plan.variable_name,
            buffers,
        );
        if (readonly_failure) |failure| {
            return failure;
        }
        try assignForLoopVariable(evaluator.allocator, shell_state, eval_context.target, for_plan.variable_name, word);
        const body = if (for_plan.body_source) |source|
            try evaluateStatementListSource(evaluator, shell_state, loop_context, source, buffers)
        else
            try evaluateStatementList(evaluator, shell_state, loop_context, for_plan.body, buffers);
        try flushCurrentShellBufferedCommandOutput(
            buffers,
            eval_context,
            evaluator.external_stdio,
            evaluator.io != null,
        );
        switch (consumeLoopControl(body.control_flow)) {
            .stop => return normalEvaluation(0),
            .repeat => {
                result = normalEvaluation(body.status);
                continue;
            },
            .propagate => |flow| return .{ .status = flow.status(body.status), .control_flow = flow },
            .other => {
                if (body.control_flow != .normal) return body;
                result = normalEvaluation(body.status);
            },
        }
    }
    return result;
}

const ForLoopWordExpansion = union(enum) {
    words: [][]const u8,
    failure: SimpleEvalResult,
};

fn expandForLoopSourceWords(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source_words: []const command_plan.ForWord,
    buffers: *EvaluationBuffers,
) EvalError!ForLoopWordExpansion {
    shell_state.validate();
    eval_context.validate();
    for (source_words) |word| word.validate();

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = false;
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = buffers.frame;
    parser_resolver.active_input = buffers.stdin;

    var lowerer: SourceLowerer = .{
        .allocator = evaluator.allocator,
        .owner = &parser_resolver,
        .shell_state = shell_state,
        .eval_context = eval_context,
        .signal = null,
        .local_functions = .empty,
    };

    var expanded_words: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeForLoopWords(evaluator.allocator, expanded_words.items);
        expanded_words.deinit(evaluator.allocator);
    }
    var expansion_outputs: SourceLowerer.ExpansionOutputAccumulator = .{};
    defer SourceLowerer.ExpansionOutputAccumulator.deinit(evaluator.allocator, &expansion_outputs);

    for (source_words) |word| {
        lowerer.current_line_number = word.line;
        const expanded_word = lowerer.expandFields(word.raw, eval_context.target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unimplemented,
        };
        switch (expanded_word) {
            .failure => |failure| {
                const result = try simpleResultFromTrapActionFailure(
                    evaluator,
                    shell_state.*,
                    eval_context,
                    failure,
                    buffers,
                );
                evaluator.allocator.free(failure.message);
                try appendExpansionOutput(
                    evaluator.*,
                    eval_context,
                    try SourceLowerer.ExpansionOutputAccumulator.toOwned(evaluator.allocator, &expansion_outputs),
                    buffers,
                );
                return .{ .failure = result };
            },
            .result => |expanded| {
                var expanded_result = expanded.result;
                defer expanded_result.deinit();
                try SourceLowerer.ExpansionOutputAccumulator.appendOwned(
                    evaluator.allocator,
                    &expansion_outputs,
                    expanded.output,
                );
                for (expanded_result.fields) |field| {
                    try expanded_words.append(evaluator.allocator, try evaluator.allocator.dupe(u8, field));
                }
            },
        }
    }
    try appendExpansionOutput(evaluator.*, eval_context, try SourceLowerer.ExpansionOutputAccumulator.toOwned(
        evaluator.allocator,
        &expansion_outputs,
    ), buffers);
    return .{ .words = try expanded_words.toOwnedSlice(evaluator.allocator) };
}

fn cloneForLoopWords(allocator: std.mem.Allocator, words: []const []const u8) ![][]const u8 {
    const owned = try allocator.alloc([]const u8, words.len);
    errdefer allocator.free(owned);

    var initialized: usize = 0;
    errdefer for (owned[0..initialized]) |word| allocator.free(word);

    for (words, 0..) |word, index| {
        owned[index] = try allocator.dupe(u8, word);
        initialized += 1;
    }
    return owned;
}

fn freeForLoopWords(allocator: std.mem.Allocator, words: []const []const u8) void {
    for (words) |word| allocator.free(word);
    allocator.free(words);
}

fn forLoopReadonlyAssignmentFailure(
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    name: []const u8,
    buffers: *EvaluationBuffers,
) !?SimpleEvalResult {
    shell_state.validate();
    eval_context.validate();
    state.assertValidVariableName(name);
    if (!shell_state.isVariableReadonly(name)) return null;

    try buffers.addBuiltinDiagnostic(name, "readonly variable");
    const status: outcome.ExitStatus = 1;
    const decision = consequence.decideForShellError(
        shell_state.options,
        eval_context,
        .readonly_assignment,
        status,
    );
    return .{ .status = status, .control_flow = decision.control_flow };
}

fn evaluateStatementListSource(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source: []const u8,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    return evaluateStatementListSourceAtLine(evaluator, shell_state, eval_context, source, 0, buffers);
}

fn evaluateStatementListSourceAtLine(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source: []const u8,
    source_line_offset: usize,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    shell_state.validate();
    eval_context.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(std.mem.findScalar(u8, source, 0) == null);

    if (source.len == 0) return normalEvaluation(0);

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = buffers.frame;
    parser_resolver.active_input = buffers.stdin;
    parser_resolver.source_line_offset = source_line_offset;
    var body = (parser_resolver.lowerSource(
        evaluator.allocator,
        source,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    }) orelse return error.Unimplemented;
    defer body.deinit();

    if (trapActionStatementSequence(body)) |list| {
        return evaluateStatementList(evaluator, shell_state, eval_context, list, buffers);
    }

    var body_outcome = try evaluateTrapActionBodyWithInputInFrame(
        evaluator,
        shell_state,
        eval_context,
        body,
        buffers.stdin,
        buffers.frame,
    );
    defer body_outcome.deinit();

    try appendOutcomeBuffers(buffers, body_outcome);
    if (trapActionBodyCommitsStateToParent(body)) {
        try applyOutcomeToWorkingState(shell_state, &body_outcome, body_outcome.state_delta.target);
    } else {
        try applyOutcomeStatusToWorkingState(shell_state, body_outcome);
    }
    return .{ .status = body_outcome.status, .control_flow = body_outcome.effectiveControlFlow() };
}

fn evaluateFunctionStatementListSource(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    call_frame: *FunctionCallFrame,
    eval_context: context.EvalContext,
    source: []const u8,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    shell_state.validate();
    eval_context.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());
    std.debug.assert(std.mem.findScalar(u8, source, 0) == null);

    if (source.len == 0) return .{ .result = normalEvaluation(0) };

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = false;
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = buffers.frame;
    parser_resolver.active_input = buffers.stdin;
    parser_resolver.source_line_offset = call_frame.definition.source_body_line_offset;
    const body = (parser_resolver.lowerSource(
        evaluator.allocator,
        source,
        eval_context,
        shell_state,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    }) orelse return error.Unimplemented;
    call_frame.storeBodyLowering(body);
    const body_lowering = call_frame.bodyLowering();

    if (trapActionStatementSequence(body_lowering)) |list| {
        return evaluateFunctionStatementList(evaluator, shell_state, eval_context, list, tail_context, buffers);
    }

    var body_outcome = try evaluateTrapActionBodyWithInputInFrame(
        evaluator,
        shell_state,
        eval_context,
        body_lowering,
        buffers.stdin,
        buffers.frame,
    );
    defer body_outcome.deinit();

    try appendOutcomeBuffers(buffers, body_outcome);
    if (trapActionBodyCommitsStateToParent(body_lowering)) {
        try applyOutcomeToWorkingState(shell_state, &body_outcome, body_outcome.state_delta.target);
    } else {
        try applyOutcomeStatusToWorkingState(shell_state, body_outcome);
    }
    return .{ .result = .{ .status = body_outcome.status, .control_flow = body_outcome.effectiveControlFlow() } };
}

fn trapActionStatementSequence(body: TrapActionBody) ?command_plan.StatementList {
    body.validate();
    return switch (body) {
        .compound => |plan| compoundStatementSequence(plan),
        .owned => |owned| switch (owned.body) {
            .compound => |plan| compoundStatementSequence(plan),
            .simple, .pipeline, .failure => null,
        },
        .simple, .pipeline, .failure => null,
    };
}

fn compoundStatementSequence(plan: command_plan.CompoundCommandPlan) ?command_plan.StatementList {
    plan.validate();
    return switch (plan.body) {
        .sequence => |list| list,
        else => null,
    };
}

fn trapActionBodyCommitsStateToParent(body: TrapActionBody) bool {
    body.validate();
    return switch (body) {
        .compound => |plan| plan.body != .subshell,
        .owned => |owned| trapActionBodyPayloadCommitsStateToParent(owned.body),
        .simple, .pipeline, .failure => true,
    };
}

fn trapActionBodyPayloadCommitsStateToParent(body: TrapActionBodyPayload) bool {
    body.validate();
    return switch (body) {
        .compound => |plan| plan.body != .subshell,
        .simple, .pipeline, .failure => true,
    };
}

fn evaluateTrapActionBodyWithInput(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: TrapActionBody,
    input: *EvaluationInput,
) EvalError!outcome.CommandOutcome {
    body.validate();
    input.validate();
    var frame = rootExecutionFrame(eval_context);
    return evaluateTrapActionBodyWithInputInFrame(evaluator, shell_state, eval_context, body, input, &frame);
}

fn evaluateTrapActionBodyWithInputInFrame(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: TrapActionBody,
    input: *EvaluationInput,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    body.validate();
    input.validate();
    frame.validate();
    return switch (body) {
        .simple => |plan| evaluatePlanWithInput(
            evaluator,
            shell_state,
            eval_context.withTarget(plan.target),
            plan,
            input,
            frame,
        ),
        .compound => |plan| evaluateCompoundPlanWithInput(
            evaluator,
            shell_state,
            eval_context.withTarget(plan.target),
            plan,
            input,
            frame,
        ),
        .pipeline => |plan| evaluatePipelinePlanWithFrame(evaluator, shell_state, eval_context, plan, frame),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| evaluatePlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(plan.target),
                plan,
                input,
                frame,
            ),
            .compound => |plan| evaluateCompoundPlanWithInput(
                evaluator,
                shell_state,
                eval_context.withTarget(plan.target),
                plan,
                input,
                frame,
            ),
            .pipeline => |plan| evaluatePipelinePlanWithFrame(evaluator, shell_state, eval_context, plan, frame),
            .failure => |failure| trapActionFailureOutcome(evaluator.allocator, eval_context, failure, shell_state.*),
        },
        .failure => |failure| trapActionFailureOutcome(evaluator.allocator, eval_context, failure, shell_state.*),
    };
}

pub fn evaluateTrapActionBodyInFrame(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    body: TrapActionBody,
    frame: *execution_frame.ExecutionFrame,
) EvalError!outcome.CommandOutcome {
    body.validate();
    frame.validate();
    var input = EvaluationInput.empty();
    return evaluateTrapActionBodyWithInputInFrame(evaluator, shell_state, eval_context, body, &input, frame);
}

const CasePatternEvaluation = union(enum) {
    matched: bool,
    failure: TrapActionFailure,
};

const CaseWordEvaluation = union(enum) {
    value: struct {
        bytes: []const u8,
        owned: bool,
    },
    failure: TrapActionFailure,
};

fn evaluateCasePattern(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    raw_pattern: []const u8,
    line_number: usize,
    case_word: []const u8,
    buffers: *EvaluationBuffers,
) EvalError!CasePatternEvaluation {
    shell_state.validate();
    eval_context.validate();
    std.debug.assert(std.mem.findScalar(u8, raw_pattern, 0) == null);
    std.debug.assert(line_number != 0);
    std.debug.assert(std.mem.findScalar(u8, case_word, 0) == null);

    const arena = try evaluator.allocator.create(std.heap.ArenaAllocator);
    defer evaluator.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(evaluator.allocator);
    defer arena.deinit();

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;

    var lowerer: SourceLowerer = .{
        .allocator = arena.allocator(),
        .owner = &parser_resolver,
        .shell_state = shell_state,
        .eval_context = eval_context,
        .signal = null,
        .local_functions = .empty,
        .current_line_number = line_number,
    };

    const expanded_pattern = lowerer.expandCasePattern(raw_pattern, eval_context.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    };
    const value = switch (expanded_pattern) {
        .failure => |failure| return .{ .failure = try cloneTrapActionFailure(evaluator.allocator, failure) },
        .value => |expanded| expanded,
    };
    try appendExpansionOutput(evaluator.*, eval_context, value.output, buffers);
    try flushCurrentShellBufferedCommandOutput(buffers, eval_context, evaluator.external_stdio, evaluator.io != null);
    return .{ .matched = casePatternMatches(value.value, case_word) };
}

fn evaluateCaseWord(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    case_plan: command_plan.CasePlan,
    buffers: *EvaluationBuffers,
) EvalError!CaseWordEvaluation {
    shell_state.validate();
    eval_context.validate();
    case_plan.validate();
    if (case_plan.word_expanded) {
        try appendExpansionOutput(evaluator.*, eval_context, case_plan.word_expansion_output, buffers);
        return .{ .value = .{ .bytes = case_plan.word, .owned = false } };
    }

    const arena = try evaluator.allocator.create(std.heap.ArenaAllocator);
    defer evaluator.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(evaluator.allocator);
    defer arena.deinit();

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = shell_state.shopts.enabled(.expand_aliases);
    parser_resolver.alias_state = evaluator.alias_state;

    var lowerer: SourceLowerer = .{
        .allocator = arena.allocator(),
        .owner = &parser_resolver,
        .shell_state = shell_state,
        .eval_context = eval_context,
        .signal = null,
        .local_functions = .empty,
        .current_line_number = case_plan.word_line orelse 1,
    };
    const expanded_word = lowerer.expandScalar(case_plan.word, eval_context.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    };
    const value = switch (expanded_word) {
        .failure => |failure| return .{ .failure = try cloneTrapActionFailure(evaluator.allocator, failure) },
        .value => |expanded| expanded,
    };
    try appendExpansionOutput(evaluator.*, eval_context, value.output, buffers);
    return .{ .value = .{ .bytes = try evaluator.allocator.dupe(u8, value.value), .owned = true } };
}

fn simpleResultFromTrapActionFailure(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    failure: TrapActionFailure,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    var failure_outcome = try trapActionFailureOutcome(evaluator.allocator, eval_context, failure, shell_state);
    defer failure_outcome.deinit();
    try appendOutcomeBuffers(buffers, failure_outcome);
    return .{ .status = failure_outcome.status, .control_flow = failure_outcome.effectiveControlFlow() };
}

fn evaluateCaseClause(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    case_plan: command_plan.CasePlan,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    case_plan.validate();
    const case_word_result = try evaluateCaseWord(evaluator, shell_state, eval_context, case_plan, buffers);
    const case_word = switch (case_word_result) {
        .value => |value| value.bytes,
        .failure => |failure| {
            defer evaluator.allocator.free(failure.message);
            return simpleResultFromTrapActionFailure(evaluator, shell_state.*, eval_context, failure, buffers);
        },
    };
    defer switch (case_word_result) {
        .value => |value| if (value.owned) evaluator.allocator.free(value.bytes),
        .failure => {},
    };
    try flushCurrentShellBufferedCommandOutput(buffers, eval_context, evaluator.external_stdio, evaluator.io != null);
    var matched = false;
    var status: outcome.ExitStatus = 0;
    var control_flow: outcome.ControlFlow = .normal;
    for (case_plan.arms) |arm| {
        if (!matched) {
            for (arm.patterns, 0..) |pattern, pattern_index| {
                if (arm.patterns_expanded) {
                    if (arm.pattern_expansion_outputs.len != 0) {
                        try appendExpansionOutput(
                            evaluator.*,
                            eval_context,
                            arm.pattern_expansion_outputs[pattern_index],
                            buffers,
                        );
                        try flushCurrentShellBufferedCommandOutput(
                            buffers,
                            eval_context,
                            evaluator.external_stdio,
                            evaluator.io != null,
                        );
                    }
                    if (casePatternMatches(pattern, case_word)) {
                        matched = true;
                        break;
                    }
                } else {
                    const pattern_result = try evaluateCasePattern(
                        evaluator,
                        shell_state,
                        eval_context,
                        pattern,
                        if (arm.pattern_lines.len != 0) arm.pattern_lines[pattern_index] else 1,
                        case_word,
                        buffers,
                    );
                    switch (pattern_result) {
                        .matched => |pattern_matched| if (pattern_matched) {
                            matched = true;
                            break;
                        },
                        .failure => |failure| {
                            defer evaluator.allocator.free(failure.message);
                            return simpleResultFromTrapActionFailure(
                                evaluator,
                                shell_state.*,
                                eval_context,
                                failure,
                                buffers,
                            );
                        },
                    }
                }
            }
        }
        if (matched) {
            const result = try evaluateStatementList(
                evaluator,
                shell_state,
                eval_context,
                arm.body,
                buffers,
            );
            status = result.status;
            control_flow = result.control_flow;
            if (control_flow != .normal) return .{ .status = status, .control_flow = control_flow };
            if (arm.fallthrough) continue;
            if (arm.test_next) {
                matched = false;
                continue;
            }
            return .{ .status = status, .control_flow = control_flow };
        }
    }
    return if (matched) .{ .status = status, .control_flow = control_flow } else normalEvaluation(0);
}

const LoopControlAction = union(enum) {
    stop,
    repeat,
    propagate: outcome.ControlFlow,
    other,
};

fn consumeLoopControl(control_flow: outcome.ControlFlow) LoopControlAction {
    control_flow.validate();
    return switch (control_flow) {
        .break_loop => |depth| if (depth == 1) .stop else .{ .propagate = .{ .break_loop = depth - 1 } },
        .continue_loop => |depth| if (depth == 1) .repeat else .{ .propagate = .{ .continue_loop = depth - 1 } },
        else => .other,
    };
}

fn assignForLoopVariable(
    allocator: std.mem.Allocator,
    shell_state: *state.ShellState,
    target: context.ExecutionTarget,
    name: []const u8,
    value: []const u8,
) EvalError!void {
    state.assertValidVariableName(name);
    if (target.allowsShellStateCommit() and shell_state.acceptsExecutionTarget(target)) {
        var iteration_delta = delta.StateDelta.init(allocator, target);
        defer iteration_delta.deinit();
        try iteration_delta.assignVariable(name, value, .{});
        iteration_delta.commit(shell_state, target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadonlyVariable => unreachable,
        };
        return;
    }

    std.debug.assert(target == .child_process);
    shell_state.putVariable(name, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
}

fn applyOutcomeToWorkingState(
    shell_state: *state.ShellState,
    command_outcome: *outcome.CommandOutcome,
    target: context.ExecutionTarget,
) EvalError!void {
    command_outcome.validate();
    std.debug.assert(command_outcome.state_delta.target == target);
    command_outcome.applyToShellState(shell_state, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
}

const BoundaryOutputFinalizer = struct {
    buffers: *EvaluationBuffers,

    fn init(buffers: *EvaluationBuffers) BoundaryOutputFinalizer {
        buffers.frame.validate();
        return .{ .buffers = buffers };
    }

    fn appendOutcome(self: BoundaryOutputFinalizer, command_outcome: outcome.CommandOutcome) !void {
        command_outcome.validate();
        self.buffers.appendPropagatedFailure(command_outcome);
        try self.buffers.appendSideOutput(command_outcome);
        try self.buffers.appendCommandSubstitutionSideOutput(command_outcome);
        if (frameWithinCommandSubstitution(self.buffers.frame.*)) {
            try self.buffers.stdout.appendSlice(self.buffers.allocator, command_outcome.stdout.items);
            try self.buffers.stderr.appendSlice(self.buffers.allocator, command_outcome.stderr.items);
            try self.buffers.appendPipelineOutput(command_outcome);
            try self.buffers.appendDiagnosticsFromOutcome(command_outcome);
            return;
        }
        try self.buffers.appendPipelineOutput(command_outcome);
        var frame = try self.buffers.outputFrame();
        defer frame.deinit();
        try frame.write(1, command_outcome.stdout.items);
        try frame.write(2, command_outcome.stderr.items);
        try self.buffers.appendDiagnosticsFromOutcome(command_outcome);
    }

    fn appendStatementChild(self: BoundaryOutputFinalizer, command_outcome: outcome.CommandOutcome) !void {
        command_outcome.validate();
        if (frameWithinCommandSubstitution(self.buffers.frame.*) or self.buffers.frame.spec.kind == .pipeline_stage) {
            return self.appendOutcome(command_outcome);
        }
        self.buffers.appendPropagatedFailure(command_outcome);
        try self.buffers.appendCommandSubstitutionSideOutput(command_outcome);
        switch (self.buffers.frame.spec.kind) {
            .subshell, .trap_handler => try self.buffers.stdout.appendSlice(
                self.buffers.allocator,
                command_outcome.side_stdout.items,
            ),
            else => {
                var side_frame = try self.buffers.outputFrame();
                defer side_frame.deinit();
                try side_frame.write(1, command_outcome.side_stdout.items);
            },
        }

        try self.buffers.appendPipelineOutput(command_outcome);
        var frame = OutputFrame.initOutcomeCapture(self.buffers);
        defer frame.deinit();
        try frame.write(1, command_outcome.stdout.items);
        try frame.write(2, command_outcome.stderr.items);
        try self.buffers.appendDiagnosticsFromOutcome(command_outcome);
    }

    fn appendPipelineStage(
        self: BoundaryOutputFinalizer,
        command_outcome: outcome.CommandOutcome,
        route: PipelineStageOutputRoute,
    ) !void {
        command_outcome.validate();
        self.buffers.appendPropagatedFailure(command_outcome);
        try self.buffers.appendCommandSubstitutionSideOutput(command_outcome);
        var side_frame = try self.buffers.outputFrame();
        defer side_frame.deinit();
        try side_frame.write(1, command_outcome.side_stdout.items);

        var frame = OutputFrame.initOutcomeCapture(self.buffers);
        defer frame.deinit();
        switch (route) {
            .pipeline_data_only => {},
            .parent_output => try frame.write(1, command_outcome.pipeline_stdout.items),
        }
        try frame.write(1, command_outcome.stdout.items);
        try frame.write(2, command_outcome.stderr.items);
        try self.buffers.appendDiagnosticsFromOutcome(command_outcome);
    }
};

fn appendOutcomeBuffers(buffers: *EvaluationBuffers, command_outcome: outcome.CommandOutcome) !void {
    try BoundaryOutputFinalizer.init(buffers).appendOutcome(command_outcome);
}

fn appendStatementChildOutcomeBuffers(buffers: *EvaluationBuffers, command_outcome: outcome.CommandOutcome) !void {
    try BoundaryOutputFinalizer.init(buffers).appendStatementChild(command_outcome);
}

const PipelineStageOutputRoute = enum {
    pipeline_data_only,
    parent_output,

    fn forStage(is_last_stage: bool) PipelineStageOutputRoute {
        return if (is_last_stage) .parent_output else .pipeline_data_only;
    }
};

fn appendPipelineStageBuffers(
    buffers: *EvaluationBuffers,
    command_outcome: outcome.CommandOutcome,
    route: PipelineStageOutputRoute,
) !void {
    try BoundaryOutputFinalizer.init(buffers).appendPipelineStage(command_outcome, route);
}

fn hasCompoundRedirections(plan: command_plan.CompoundCommandPlan) bool {
    plan.redirections.validate();
    return plan.redirections.steps.len != 0;
}

fn compoundBodySuppressesFinalErrexit(body: command_plan.CompoundBody) bool {
    body.validate();
    return switch (body) {
        .and_or_list,
        .negation,
        => true,
        .sequence,
        .brace_group,
        .subshell,
        .if_clause,
        .while_loop,
        .until_loop,
        .for_loop,
        .case_clause,
        => false,
    };
}

fn evaluateFunctionDefinition(
    definition: command_plan.FunctionDefinition,
    state_delta: *delta.StateDelta,
) EvalError!SimpleEvalResult {
    definition.validate();
    try state_delta.setFunction(definition);
    return normalEvaluation(0);
}

fn validateFunctionCall(plan: command_plan.CommandPlan, definition: command_plan.FunctionDefinition) void {
    plan.validate();
    definition.validate();
    std.debug.assert(definition.hasExecutableBody());
    std.debug.assert(plan.target.allowsShellStateCommit());
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, plan.argv[0], definition.name));
    std.debug.assert(plan.assignmentEffect() == .temporary or plan.assignmentEffect() == .none);
}

fn functionDefinitionFromCallPlan(plan: command_plan.CommandPlan) command_plan.FunctionDefinition {
    plan.validate();
    return switch (plan.classification) {
        .function => |definition| definition,
        else => unreachable,
    };
}

fn cloneFunctionFrameState(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
) EvalError!state.ShellState {
    shell_state.validate();
    return shell_state.cloneBorrowingFunctions(evaluator.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
}

fn beginFunctionCallRedirections(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    caller_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    definition: command_plan.FunctionDefinition,
    guard: *RedirectionGuard,
    buffers: *EvaluationBuffers,
) EvalError!?SimpleEvalResult {
    shell_state.validate();
    caller_context.validate();
    validateFunctionCall(plan, definition);
    std.debug.assert(!guard.hasTransaction());
    if (!hasRedirections(plan)) return null;

    if (caller_context.command_substitution_depth == 0 and caller_context.pipeline_depth != 0 and
        frameRoutesCapturedOutput(buffers.frame.*) and !redirectionPlanNeedsRuntimeFdEffects(plan.redirections))
    {
        try emitSemanticRedirectionTransforms(evaluator.*, buffers, plan.redirections);
        return null;
    }

    const apply_result = try applyRedirectionsForScope(
        evaluator.*,
        buffers,
        .current_scoped,
        .{},
        plan.redirections,
        redirectionExpansionModeForContext(caller_context),
        definition.name,
    );
    switch (apply_result) {
        .applied => |applied| guard.* = applied,
        .failure => |failure| {
            try addRedirectionFailureDiagnostic(buffers, definition.name, failure);
            return evaluationFromRedirectionFailure(shell_state.options, caller_context, failure);
        },
    }
    return null;
}

fn beginFunctionDefinitionRedirections(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    caller_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    definition: command_plan.FunctionDefinition,
    guard: *RedirectionGuard,
    buffers: *EvaluationBuffers,
) EvalError!?SimpleEvalResult {
    shell_state.validate();
    caller_context.validate();
    validateFunctionCall(plan, definition);
    std.debug.assert(!guard.hasTransaction());
    if (definition.redirections.steps.len == 0) return null;

    const apply_result = try applyRedirectionsForScope(
        evaluator.*,
        buffers,
        .current_scoped,
        plan.redirections,
        definition.redirections,
        redirectionExpansionModeForContext(caller_context),
        definition.name,
    );
    switch (apply_result) {
        .applied => |applied| guard.* = applied,
        .failure => |failure| {
            try addRedirectionFailureDiagnostic(buffers, definition.name, failure);
            return evaluationFromRedirectionFailure(shell_state.options, caller_context, failure);
        },
    }
    return null;
}

fn beginFunctionFrameState(
    frame_state: *state.ShellState,
    plan: command_plan.CommandPlan,
) EvalError!void {
    frame_state.validate();
    plan.validate();
    try applyFunctionAssignmentPrefixes(frame_state, frame_state.*, plan);
    try frame_state.replacePositionals(plan.argv[1..]);
}

const FunctionActivation = struct {
    allocator: std.mem.Allocator,
    evaluator: *Evaluator,
    frame_state: state.ShellState,
    previous_frame: ?*FunctionFrame,
    call_frame: ?*FunctionCallFrame = null,
    installed_function_frame: bool = false,

    fn init(evaluator: *Evaluator, shell_state: *state.ShellState) EvalError!FunctionActivation {
        const frame_state = try cloneFunctionFrameState(evaluator, shell_state);
        return .{
            .allocator = evaluator.allocator,
            .evaluator = evaluator,
            .frame_state = frame_state,
            .previous_frame = evaluator.function_frame,
        };
    }

    fn deinit(self: *FunctionActivation) void {
        self.endCallFrame();
        self.frame_state.deinit();
        self.* = undefined;
    }

    fn beginCallFrame(
        self: *FunctionActivation,
        caller_context: context.EvalContext,
        plan: command_plan.CommandPlan,
        owns_plan: bool,
    ) EvalError!*FunctionCallFrame {
        std.debug.assert(self.call_frame == null);
        errdefer if (owns_plan) command_plan.freeCommandPlan(self.allocator, plan);

        const call_frame = try self.allocator.create(FunctionCallFrame);
        errdefer self.allocator.destroy(call_frame);
        call_frame.* = try FunctionCallFrame.init(self.allocator, caller_context, plan, owns_plan);
        self.call_frame = call_frame;
        return call_frame;
    }

    fn installCallFrame(self: *FunctionActivation) void {
        std.debug.assert(self.call_frame != null);
        std.debug.assert(!self.installed_function_frame);
        installFunctionFrame(self.evaluator, self.call_frame.?.function_frame);
        self.installed_function_frame = true;
    }

    fn endCallFrame(self: *FunctionActivation) void {
        if (self.call_frame) |call_frame| {
            if (self.installed_function_frame) {
                restoreFunctionFrame(self.evaluator, call_frame.function_frame, self.previous_frame);
                self.installed_function_frame = false;
            }
            call_frame.deinit();
            self.allocator.destroy(call_frame);
            self.call_frame = null;
        } else {
            std.debug.assert(!self.installed_function_frame);
        }
    }

    fn validate(self: FunctionActivation) void {
        self.frame_state.validate();
        if (self.call_frame) |call_frame| call_frame.validate();
    }
};

const FunctionStartResult = union(enum) {
    started: *FunctionCallFrame,
    completed: SimpleEvalResult,
};

fn startFunctionCallFrame(
    evaluator: *Evaluator,
    caller_shell_state: state.ShellState,
    activation: *FunctionActivation,
    caller_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    owns_plan: bool,
    buffers: *EvaluationBuffers,
) EvalError!FunctionStartResult {
    const call_frame = try activation.beginCallFrame(caller_context, plan, owns_plan);
    activation.validate();

    try flushBuffersForFunctionRedirectionTargets(buffers, call_frame.plan, call_frame.definition);

    if (try beginFunctionCallRedirections(
        evaluator,
        caller_shell_state,
        call_frame.caller_context,
        call_frame.plan,
        call_frame.definition,
        &call_frame.call_redirections,
        buffers,
    )) |redirection_failure| return .{ .completed = redirection_failure };

    if (try beginFunctionDefinitionRedirections(
        evaluator,
        caller_shell_state,
        call_frame.caller_context,
        call_frame.plan,
        call_frame.definition,
        &call_frame.definition_redirections,
        buffers,
    )) |redirection_failure| return .{ .completed = redirection_failure };

    try beginFunctionFrameState(&activation.frame_state, call_frame.plan);
    activation.installCallFrame();
    return .{ .started = call_frame };
}

const FunctionCommandInvocationStart = union(enum) {
    invocation: *FunctionCommandInvocation,
    outcome: outcome.CommandOutcome,
};

const ActiveFunctionStart = union(enum) {
    active: *ActiveFunctionCall,
    outcome: outcome.CommandOutcome,
};

const FunctionCommandInvocation = struct {
    allocator: std.mem.Allocator,
    parent_shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    effective_plan: command_plan.CommandPlan,
    owns_plan: bool = false,
    filtered_assignments: ?[]command_plan.Assignment = null,
    state_delta: delta.StateDelta,
    state_delta_consumed: bool = false,
    command_frame: execution_frame.ExecutionFrame,
    frame_input: EvaluationInput = EvaluationInput.empty(),
    buffers: EvaluationBuffers,

    fn begin(
        allocator: std.mem.Allocator,
        evaluator: *Evaluator,
        parent_shell_state: *state.ShellState,
        eval_context: context.EvalContext,
        plan: command_plan.CommandPlan,
        owns_plan: bool,
        input: *EvaluationInput,
        frame: *execution_frame.ExecutionFrame,
    ) EvalError!FunctionCommandInvocationStart {
        var plan_transferred = false;
        errdefer if (owns_plan and !plan_transferred) command_plan.freeCommandPlan(allocator, plan);
        parent_shell_state.validate();
        eval_context.validate();
        plan.validate();
        input.validate();
        frame.validate();
        std.debug.assert(plan.class() == .function);
        std.debug.assert(plan.target == eval_context.target);

        var effective_plan = plan;
        var filtered_assignments: ?[]command_plan.Assignment = null;
        errdefer if (filtered_assignments) |assignments| allocator.free(assignments);
        const readonly_assignment = delta.firstReadonlyAssignment(parent_shell_state.*, plan.assignments);
        if (readonly_assignment) |_| {
            if (bashCommandIgnoresReadonlyAssignment(eval_context, plan)) {
                filtered_assignments = try filterReadonlyAssignments(allocator, parent_shell_state.*, plan.assignments);
                effective_plan.assignments = filtered_assignments.?;
                effective_plan.validate();
            } else {
                var outcome_result = try evaluatePlanWithInput(
                    evaluator,
                    parent_shell_state,
                    eval_context,
                    plan,
                    input,
                    frame,
                );
                errdefer outcome_result.deinit();
                if (owns_plan) command_plan.freeCommandPlan(allocator, plan);
                return .{ .outcome = outcome_result };
            }
        }

        const invocation = try allocator.create(FunctionCommandInvocation);
        errdefer allocator.destroy(invocation);
        var command_frame = try semanticCommandExecutionFrame(
            allocator,
            evaluator.scoped_exec_redirections,
            frame,
            effective_plan.target,
            effective_plan.redirections,
        );
        errdefer command_frame.spec.fd_table.deinit(allocator);

        invocation.* = .{
            .allocator = allocator,
            .parent_shell_state = parent_shell_state,
            .eval_context = eval_context,
            .effective_plan = effective_plan,
            .owns_plan = owns_plan,
            .filtered_assignments = filtered_assignments,
            .state_delta = delta.StateDelta.init(allocator, effective_plan.target),
            .command_frame = command_frame,
            .buffers = EvaluationBuffers.init(allocator, input, &invocation.command_frame),
        };
        plan_transferred = true;
        filtered_assignments = null;
        errdefer invocation.deinit();

        invocation.buffers.useFrameFdTableInput(&invocation.frame_input, input);
        if (readonly_assignment) |name| try invocation.buffers.addBuiltinDiagnostic(name, "readonly variable");
        try appendPlanExpansionOutput(evaluator.*, eval_context, effective_plan, &invocation.buffers);
        try flushCurrentShellBufferedCommandOutput(
            &invocation.buffers,
            eval_context,
            evaluator.external_stdio,
            evaluator.io != null,
        );
        return .{ .invocation = invocation };
    }

    fn finishCommandOutcome(
        self: *FunctionCommandInvocation,
        evaluator: *Evaluator,
        result: SimpleEvalResult,
    ) EvalError!outcome.CommandOutcome {
        result.control_flow.validate();
        if (frameRoutesCapturedOutput(self.command_frame) and self.eval_context.command_substitution_depth == 0 and
            self.eval_context.pipeline_depth != 0)
        {
            try routeDirectPipelineStageBuffers(&self.buffers);
        }
        self.state_delta.setLastStatus(result.status);
        assertCommandDeltaCompatible(self.effective_plan, self.state_delta);
        const decision = consequence.decideForSimpleCommand(
            self.parent_shell_state.options,
            self.eval_context,
            self.effective_plan,
            result.status,
            result.control_flow,
        );
        var command_outcome = try commandOutcomeFromBuffers(
            self.allocator,
            self.eval_context,
            result.status,
            self.state_delta,
            decision.control_flow,
            &self.buffers,
        );
        self.state_delta_consumed = true;
        errdefer command_outcome.deinit();
        try appendBuiltinDiagnostic(&command_outcome, self.effective_plan, result.status);
        command_outcome.validateForContext(self.eval_context);
        _ = evaluator;
        return command_outcome;
    }

    fn deinit(self: *FunctionCommandInvocation) void {
        self.buffers.deinit();
        self.command_frame.spec.fd_table.deinit(self.allocator);
        if (!self.state_delta_consumed) self.state_delta.deinit();
        if (self.filtered_assignments) |assignments| self.allocator.free(assignments);
        if (self.owns_plan) command_plan.freeCommandPlan(self.allocator, self.effective_plan);
        self.* = undefined;
    }
};

const ActiveFunctionCall = struct {
    allocator: std.mem.Allocator,
    caller_shell_state: *state.ShellState,
    activation: FunctionActivation,
    invocation: ?*FunctionCommandInvocation = null,
    root_state_delta: ?*delta.StateDelta = null,
    root_buffers: ?*EvaluationBuffers = null,
    pending_result: ?SimpleEvalResult = null,

    fn initRoot(
        allocator: std.mem.Allocator,
        evaluator: *Evaluator,
        caller_shell_state: *state.ShellState,
        caller_context: context.EvalContext,
        plan: command_plan.CommandPlan,
        state_delta: *delta.StateDelta,
        buffers: *EvaluationBuffers,
    ) EvalError!*ActiveFunctionCall {
        const active = try allocator.create(ActiveFunctionCall);
        errdefer allocator.destroy(active);
        active.* = .{
            .allocator = allocator,
            .caller_shell_state = caller_shell_state,
            .activation = try FunctionActivation.init(evaluator, caller_shell_state),
            .root_state_delta = state_delta,
            .root_buffers = buffers,
        };
        errdefer active.deinit();
        switch (try startFunctionCallFrame(
            evaluator,
            caller_shell_state.*,
            &active.activation,
            caller_context,
            plan,
            false,
            buffers,
        )) {
            .started => {},
            .completed => |result| active.pending_result = result,
        }
        return active;
    }

    fn initNested(
        allocator: std.mem.Allocator,
        evaluator: *Evaluator,
        parent_shell_state: *state.ShellState,
        request: FunctionCursorCall,
        input: *EvaluationInput,
        frame: *execution_frame.ExecutionFrame,
    ) EvalError!ActiveFunctionStart {
        request.validate();
        const invocation_start = try FunctionCommandInvocation.begin(
            allocator,
            evaluator,
            parent_shell_state,
            request.eval_context,
            request.plan,
            request.owns_plan,
            input,
            frame,
        );
        switch (invocation_start) {
            .outcome => |command_outcome| return .{ .outcome = command_outcome },
            .invocation => |invocation| {
                errdefer {
                    invocation.deinit();
                    allocator.destroy(invocation);
                }
                const active = try allocator.create(ActiveFunctionCall);
                errdefer allocator.destroy(active);
                active.* = .{
                    .allocator = allocator,
                    .caller_shell_state = parent_shell_state,
                    .activation = try FunctionActivation.init(evaluator, parent_shell_state),
                    .invocation = invocation,
                };
                errdefer active.deinit();
                switch (try startFunctionCallFrame(
                    evaluator,
                    parent_shell_state.*,
                    &active.activation,
                    request.eval_context,
                    invocation.effective_plan,
                    false,
                    &invocation.buffers,
                )) {
                    .started => {},
                    .completed => |result| active.pending_result = result,
                }
                return .{ .active = active };
            },
        }
    }

    fn activeBuffers(self: *ActiveFunctionCall) *EvaluationBuffers {
        if (self.invocation) |invocation| return &invocation.buffers;
        return self.root_buffers.?;
    }

    fn callFrame(self: *ActiveFunctionCall) *FunctionCallFrame {
        return self.activation.call_frame.?;
    }

    fn deinit(self: *ActiveFunctionCall) void {
        self.activation.deinit();
        if (self.invocation) |invocation| {
            invocation.deinit();
            self.allocator.destroy(invocation);
        }
        self.* = undefined;
    }
};

fn installFunctionFrame(evaluator: *Evaluator, function_frame: *FunctionFrame) void {
    std.debug.assert(function_frame.depth != 0);
    evaluator.function_frame = function_frame;
}

fn restoreFunctionFrame(
    evaluator: *Evaluator,
    function_frame: *FunctionFrame,
    previous_frame: ?*FunctionFrame,
) void {
    std.debug.assert(evaluator.function_frame == function_frame);
    evaluator.function_frame = previous_frame;
}

fn functionTailCallContext(
    plan: command_plan.CommandPlan,
    definition: command_plan.FunctionDefinition,
) FunctionTailCallContext {
    validateFunctionCall(plan, definition);
    return .{
        .call_has_redirections = hasRedirections(plan),
        .definition_has_redirections = definition.redirections.steps.len != 0,
    };
}

fn assertFunctionTailCallElisionSafe(function_frame: FunctionFrame) void {
    std.debug.assert(function_frame.assignment_prefixes.len == 0);
    std.debug.assert(function_frame.local_names.items.len == 0);
}

fn consumeFunctionBoundaryReturn(
    function_context: context.EvalContext,
    body_result: SimpleEvalResult,
) SimpleEvalResult {
    function_context.validate();
    body_result.control_flow.validate();

    var result = body_result;
    if (result.control_flow == .return_from_scope) {
        const request = result.control_flow.return_from_scope;
        switch (request.scope) {
            .function => {
                std.debug.assert(function_context.canReturnFromFunction());
                result = normalEvaluation(request.status);
            },
            .sourced_script => {},
        }
    }
    return result;
}

fn finishFunctionLifecycle(
    shell_state: state.ShellState,
    frame_state: state.ShellState,
    function_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    definition: command_plan.FunctionDefinition,
    function_frame: FunctionFrame,
    has_function_redirections: bool,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
    body_result: SimpleEvalResult,
) EvalError!SimpleEvalResult {
    shell_state.validate();
    frame_state.validate();
    function_context.validate();
    validateFunctionCall(plan, definition);

    const result = consumeFunctionBoundaryReturn(function_context, body_result);
    if (has_function_redirections) {
        try flushBuffersForFunctionRedirectionTargets(buffers, plan, definition);
    }
    try appendFunctionFrameDelta(shell_state, frame_state, function_frame, state_delta);
    return result;
}

fn evaluateFunction(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    definition: command_plan.FunctionDefinition,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    validateFunctionCall(plan, definition);
    const shell_state_before = shellStateMutationFingerprint(shell_state.*);
    defer std.debug.assert(shellStateMutationFingerprint(shell_state.*) == shell_state_before);

    var stack: std.ArrayList(*ActiveFunctionCall) = .empty;
    defer {
        while (stack.items.len != 0) {
            const active = stack.pop().?;
            active.deinit();
            evaluator.allocator.destroy(active);
        }
        stack.deinit(evaluator.allocator);
    }

    try stack.append(
        evaluator.allocator,
        try ActiveFunctionCall.initRoot(
            evaluator.allocator,
            evaluator,
            shell_state,
            eval_context,
            plan,
            state_delta,
            buffers,
        ),
    );

    while (stack.items.len != 0) {
        const active = stack.items[stack.items.len - 1];
        const body_result = if (active.pending_result) |pending| blk: {
            active.pending_result = null;
            break :blk FunctionBodyEvalResult{ .result = pending };
        } else try evaluateFunctionBody(
            evaluator,
            &active.activation.frame_state,
            active.callFrame(),
            active.activeBuffers(),
        );

        switch (body_result) {
            .tail_call => |tail_plan| {
                const call_frame = active.callFrame();
                assertFunctionTailCallElisionSafe(call_frame.function_frame.*);
                const caller_context = call_frame.function_context;
                if (call_frame.body_cursor) |*cursor| {
                    cursor.deinit();
                    call_frame.body_cursor = null;
                }
                active.activation.endCallFrame();
                switch (try startFunctionCallFrame(
                    evaluator,
                    active.caller_shell_state.*,
                    &active.activation,
                    caller_context,
                    tail_plan,
                    true,
                    active.activeBuffers(),
                )) {
                    .started => {},
                    .completed => |result| active.pending_result = result,
                }
            },
            .call_function => |request| {
                request.validate();
                switch (try ActiveFunctionCall.initNested(
                    evaluator.allocator,
                    evaluator,
                    &active.activation.frame_state,
                    request,
                    active.activeBuffers().stdin,
                    active.activeBuffers().frame,
                )) {
                    .outcome => |*child_outcome| {
                        var mutable_outcome = child_outcome.*;
                        defer mutable_outcome.deinit();
                        try active.callFrame().body_cursor.?.completeCallOutcome(
                            evaluator,
                            &active.activation.frame_state,
                            &mutable_outcome,
                            active.activeBuffers(),
                        );
                    },
                    .active => |child_active| try stack.append(evaluator.allocator, child_active),
                }
            },
            .result => |body_simple_result| {
                const call_frame = active.callFrame();
                if (active.invocation) |invocation| {
                    const command_result = try finishFunctionLifecycle(
                        active.caller_shell_state.*,
                        active.activation.frame_state,
                        call_frame.function_context,
                        call_frame.plan,
                        call_frame.definition,
                        call_frame.function_frame.*,
                        call_frame.hasRedirections(),
                        &invocation.state_delta,
                        &invocation.buffers,
                        body_simple_result,
                    );
                    var child_outcome = try invocation.finishCommandOutcome(evaluator, command_result);
                    errdefer child_outcome.deinit();

                    _ = stack.pop();
                    active.deinit();
                    evaluator.allocator.destroy(active);

                    const parent = stack.items[stack.items.len - 1];
                    defer child_outcome.deinit();
                    try parent.callFrame().body_cursor.?.completeCallOutcome(
                        evaluator,
                        &parent.activation.frame_state,
                        &child_outcome,
                        parent.activeBuffers(),
                    );
                } else {
                    const result = try finishFunctionLifecycle(
                        shell_state.*,
                        active.activation.frame_state,
                        call_frame.function_context,
                        call_frame.plan,
                        call_frame.definition,
                        call_frame.function_frame.*,
                        call_frame.hasRedirections(),
                        state_delta,
                        buffers,
                        body_simple_result,
                    );
                    _ = stack.pop();
                    active.deinit();
                    evaluator.allocator.destroy(active);
                    return result;
                }
            },
        }
    }
    unreachable;
}

fn flushBuffersForFunctionRedirectionTargets(
    buffers: *EvaluationBuffers,
    call_plan: command_plan.CommandPlan,
    definition: command_plan.FunctionDefinition,
) EvalError!void {
    call_plan.validate();
    definition.validate();

    var frame = OutputFrame.initInherited(buffers);
    defer frame.deinit();
    try frame.applyRedirectionsFlushingRouteChanges(call_plan.redirections);
    try frame.applyRedirectionsFlushingRouteChanges(definition.redirections);
}

fn evaluateFunctionBody(
    evaluator: *Evaluator,
    frame_state: *state.ShellState,
    call_frame: *FunctionCallFrame,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    if (call_frame.body_cursor == null) {
        if (try initializeFunctionBodyCursor(evaluator, frame_state, call_frame, buffers)) {
            // The cursor is stepped below.
        } else {
            return evaluateFunctionBodyFallback(evaluator, frame_state, call_frame, buffers);
        }
    }
    const step = try call_frame.body_cursor.?.step(evaluator, frame_state, buffers);
    return switch (step) {
        .completed => |result| .{ .result = result },
        .tail_call => |tail_plan| .{ .tail_call = tail_plan },
        .call_function => |request| .{ .call_function = request },
    };
}

fn evaluateFunctionBodyFallback(
    evaluator: *Evaluator,
    frame_state: *state.ShellState,
    call_frame: *FunctionCallFrame,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    const function_context = call_frame.function_context;
    const definition = call_frame.definition;
    const tail_context = call_frame.tailContext();
    definition.validate();
    return if (definition.source_body_program) |program| blk: {
        break :blk try evaluateFunctionProgramBody(
            evaluator,
            frame_state,
            call_frame,
            function_context,
            program.*,
            tail_context,
            buffers,
        );
    } else if (definition.source_body) |source_body| blk: {
        break :blk try evaluateFunctionSourceBody(
            evaluator,
            frame_state,
            call_frame,
            function_context,
            source_body,
            tail_context,
            buffers,
        );
    } else blk: {
        break :blk try evaluateFunctionStatementList(
            evaluator,
            frame_state,
            function_context,
            definition.body,
            tail_context,
            buffers,
        );
    };
}

fn initializeFunctionBodyCursor(
    evaluator: *Evaluator,
    frame_state: *state.ShellState,
    call_frame: *FunctionCallFrame,
    buffers: *EvaluationBuffers,
) EvalError!bool {
    const function_context = call_frame.function_context;
    const definition = call_frame.definition;
    const tail_context = call_frame.tailContext();
    definition.validate();
    std.debug.assert(call_frame.body_cursor == null);

    const list: command_plan.StatementList = if (definition.source_body_program) |program| blk: {
        frame_state.validate();
        function_context.validate();
        std.debug.assert(function_context.canReturnFromFunction());
        std.debug.assert(std.mem.findScalar(u8, program.source, 0) == null);

        var parser_resolver = ParserBackedSourceResolver.init(evaluator);
        parser_resolver.features = evaluator.features;
        parser_resolver.arg_zero = evaluator.arg_zero;
        parser_resolver.expand_aliases = false;
        parser_resolver.alias_state = evaluator.alias_state;
        parser_resolver.active_frame = buffers.frame;
        parser_resolver.active_input = buffers.stdin;
        const arena_allocator = try call_frame.bodyArenaAllocator();
        var lowerer: SourceLowerer = .{
            .allocator = arena_allocator,
            .owner = &parser_resolver,
            .shell_state = frame_state,
            .eval_context = function_context,
            .signal = null,
            .local_functions = .empty,
            .source_line_offset = definition.source_body_line_offset,
        };

        const lowered = lowerer.lowerStatementList(program.*, function_context.target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        break :blk switch (lowered) {
            .list => |lowered_list| lowered_list,
            .failure => return false,
        };
    } else if (definition.source_body) |source_body| blk: {
        frame_state.validate();
        function_context.validate();
        std.debug.assert(function_context.canReturnFromFunction());
        std.debug.assert(std.mem.findScalar(u8, source_body, 0) == null);
        if (source_body.len == 0) break :blk command_plan.StatementList{};

        var parser_resolver = ParserBackedSourceResolver.init(evaluator);
        parser_resolver.features = evaluator.features;
        parser_resolver.arg_zero = evaluator.arg_zero;
        parser_resolver.expand_aliases = false;
        parser_resolver.alias_state = evaluator.alias_state;
        parser_resolver.active_frame = buffers.frame;
        parser_resolver.active_input = buffers.stdin;
        parser_resolver.source_line_offset = definition.source_body_line_offset;
        var cache_check_arena = std.heap.ArenaAllocator.init(evaluator.allocator);
        defer cache_check_arena.deinit();
        var cache_check_lowerer: SourceLowerer = .{
            .allocator = cache_check_arena.allocator(),
            .owner = &parser_resolver,
            .shell_state = frame_state,
            .eval_context = function_context,
            .signal = null,
            .local_functions = .empty,
            .source_line_offset = definition.source_body_line_offset,
        };
        if (!(cache_check_lowerer.functionBodySourceCacheable(source_body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        })) return false;

        const body = (parser_resolver.lowerSource(
            evaluator.allocator,
            source_body,
            function_context,
            frame_state,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        }) orelse return false;
        call_frame.storeBodyLowering(body);
        const body_lowering = call_frame.bodyLowering();
        break :blk trapActionStatementSequence(body_lowering) orelse {
            call_frame.body_lowering.?.deinit();
            call_frame.body_lowering = null;
            return false;
        };
    } else definition.body;

    call_frame.body_cursor = try FunctionBodyCursor.init(evaluator.allocator, list, function_context, tail_context);
    return true;
}

fn evaluateFunctionSourceBody(
    evaluator: *Evaluator,
    frame_state: *state.ShellState,
    call_frame: *FunctionCallFrame,
    function_context: context.EvalContext,
    source_body: []const u8,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    frame_state.validate();
    function_context.validate();
    std.debug.assert(function_context.canReturnFromFunction());
    std.debug.assert(std.mem.findScalar(u8, source_body, 0) == null);
    return evaluateFunctionStatementListSource(
        evaluator,
        frame_state,
        call_frame,
        function_context,
        source_body,
        tail_context,
        buffers,
    );
}

fn evaluateFunctionProgramBody(
    evaluator: *Evaluator,
    frame_state: *state.ShellState,
    call_frame: *FunctionCallFrame,
    function_context: context.EvalContext,
    program: ir.Program,
    tail_context: FunctionTailCallContext,
    buffers: *EvaluationBuffers,
) EvalError!FunctionBodyEvalResult {
    frame_state.validate();
    function_context.validate();
    std.debug.assert(function_context.canReturnFromFunction());
    std.debug.assert(std.mem.findScalar(u8, program.source, 0) == null);

    var parser_resolver = ParserBackedSourceResolver.init(evaluator);
    parser_resolver.features = evaluator.features;
    parser_resolver.arg_zero = evaluator.arg_zero;
    parser_resolver.expand_aliases = false;
    parser_resolver.alias_state = evaluator.alias_state;
    parser_resolver.active_frame = buffers.frame;
    parser_resolver.active_input = buffers.stdin;
    const arena_allocator = try call_frame.bodyArenaAllocator();
    var lowerer: SourceLowerer = .{
        .allocator = arena_allocator,
        .owner = &parser_resolver,
        .shell_state = frame_state,
        .eval_context = function_context,
        .signal = null,
        .local_functions = .empty,
        .source_line_offset = call_frame.definition.source_body_line_offset,
    };

    const lowered = lowerer.lowerStatementList(program, function_context.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    };
    const list = switch (lowered) {
        .list => |list| list,
        .failure => |failure| {
            return .{ .result = try simpleResultFromTrapActionFailure(
                evaluator,
                frame_state.*,
                function_context,
                failure,
                buffers,
            ) };
        },
    };
    return evaluateFunctionStatementList(evaluator, frame_state, function_context, list, tail_context, buffers);
}

fn applyFunctionAssignmentPrefixes(
    frame_state: *state.ShellState,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
) EvalError!void {
    plan.validate();
    std.debug.assert(plan.assignmentEffect() == .temporary or plan.assignmentEffect() == .none);
    if (plan.assignments.len == 0) return;

    var temporary_environment = assignment_runtime.TemporaryEnvironment.init(frame_state.allocator);
    defer temporary_environment.deinit();
    temporary_environment.appendCommandAssignments(shell_state, plan) catch |err| switch (err) {
        error.ReadonlyVariable => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    for (temporary_environment.variables.items) |variable| {
        frame_state.putVariable(
            variable.name,
            variable.value,
            .{ .exported = true },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadonlyVariable => unreachable,
        };
    }
}

fn appendFunctionFrameDelta(
    before: state.ShellState,
    after: state.ShellState,
    frame: FunctionFrame,
    state_delta: *delta.StateDelta,
) EvalError!void {
    std.debug.assert(before.scope == after.scope);
    std.debug.assert(state_delta.target.allowsShellStateCommit());
    std.debug.assert(state_delta.positionals == null);

    var after_variables = after.variables.iterator();
    while (after_variables.next()) |entry| {
        const name = entry.key_ptr.*;
        if (frame.excludesVariable(name)) continue;
        const next = entry.value_ptr.*;
        if (before.getVariable(name)) |previous| {
            std.debug.assert(!previous.readonly or next.readonly);
            if (!std.mem.eql(u8, previous.value, next.value)) {
                try state_delta.assignVariable(
                    name,
                    next.value,
                    .{ .exported = next.exported, .readonly = next.readonly },
                );
                continue;
            }
            if (previous.exported != next.exported) try state_delta.setVariableExported(name, next.exported);
            if (!previous.readonly and next.readonly) try state_delta.setVariableReadonly(name);
        } else {
            try state_delta.assignVariable(name, next.value, .{ .exported = next.exported, .readonly = next.readonly });
        }
    }

    var before_variables = before.variables.iterator();
    while (before_variables.next()) |entry| {
        const name = entry.key_ptr.*;
        if (frame.excludesVariable(name)) continue;
        if (!after.variables.contains(name)) try state_delta.unsetVariable(name);
    }

    var after_functions = after.functions.iterator();
    while (after_functions.next()) |entry| {
        if (before.getFunction(entry.key_ptr.*)) |previous| {
            if (functionDefinitionDefinitelyEqual(previous, entry.value_ptr.*)) continue;
        }
        try state_delta.setFunction(entry.value_ptr.*);
    }

    var before_functions = before.functions.iterator();
    while (before_functions.next()) |entry| {
        if (!after.functions.contains(entry.key_ptr.*)) try state_delta.unsetFunction(entry.key_ptr.*);
    }

    try appendOptionDiff(before.options, after.options, state_delta);
    try appendShoptDiff(before.shopts, after.shopts, state_delta);
    try appendAliasDiff(before, after, state_delta);
    try appendTrapDiff(before, after, state_delta);
    if (!std.mem.eql(
        u8,
        before.logical_cwd,
        after.logical_cwd,
    ) and after.logical_cwd.len != 0) try state_delta.setLogicalCwd(after.logical_cwd);
    for (after.background_jobs.items) |job| {
        if (before.findBackgroundJobById(job.id) == null) try state_delta.appendBackgroundJob(job);
    }
}

fn functionDefinitionDefinitelyEqual(
    left: command_plan.FunctionDefinition,
    right: command_plan.FunctionDefinition,
) bool {
    left.validate();
    right.validate();
    if (!std.mem.eql(u8, left.name, right.name)) return false;
    if (!redirectionPlansDefinitelyEqual(left.redirections, right.redirections)) return false;
    if (left.source_body) |left_source| {
        const right_source = right.source_body orelse return false;
        return std.mem.eql(u8, left_source, right_source);
    }
    return false;
}

fn redirectionPlansDefinitelyEqual(
    left: redirection_plan.RedirectionPlan,
    right: redirection_plan.RedirectionPlan,
) bool {
    left.validate();
    right.validate();
    return left.steps.len == 0 and right.steps.len == 0;
}

fn appendShellStateDiff(
    before: state.ShellState,
    after: state.ShellState,
    state_delta: *delta.StateDelta,
) EvalError!void {
    return appendShellStateDiffExcludingVariables(before, after, state_delta, &.{});
}

fn appendShellStateDiffExcludingVariables(
    before: state.ShellState,
    after: state.ShellState,
    state_delta: *delta.StateDelta,
    excluded_assignments: []const command_plan.Assignment,
) EvalError!void {
    std.debug.assert(state_delta.target.allowsShellStateCommit());
    std.debug.assert(state_delta.positionals == null);
    std.debug.assert(state_delta.last_status == null);
    if (state_delta.target == .current_shell) std.debug.assert(before.scope == after.scope);
    if (state_delta.target == .subshell) std.debug.assert(after.scope == .subshell);
    for (excluded_assignments) |assignment| assignment.validate();

    var after_variables = after.variables.iterator();
    while (after_variables.next()) |entry| {
        const name = entry.key_ptr.*;
        if (assignmentListContainsName(excluded_assignments, name)) continue;
        const next = entry.value_ptr.*;
        if (before.getVariable(name)) |previous| {
            std.debug.assert(!previous.readonly or next.readonly);
            if (!std.mem.eql(u8, previous.value, next.value)) {
                try state_delta.assignVariable(
                    name,
                    next.value,
                    .{ .exported = next.exported, .readonly = next.readonly },
                );
                continue;
            }
            if (previous.exported != next.exported) try state_delta.setVariableExported(name, next.exported);
            if (!previous.readonly and next.readonly) try state_delta.setVariableReadonly(name);
        } else {
            try state_delta.assignVariable(name, next.value, .{ .exported = next.exported, .readonly = next.readonly });
        }
    }

    var before_variables = before.variables.iterator();
    while (before_variables.next()) |entry| {
        const name = entry.key_ptr.*;
        if (assignmentListContainsName(excluded_assignments, name)) continue;
        if (!after.variables.contains(name)) try state_delta.unsetVariable(name);
    }

    var after_functions = after.functions.iterator();
    while (after_functions.next()) |entry| try state_delta.setFunction(entry.value_ptr.*);

    var before_functions = before.functions.iterator();
    while (before_functions.next()) |entry| {
        if (!after.functions.contains(entry.key_ptr.*)) try state_delta.unsetFunction(entry.key_ptr.*);
    }

    try appendOptionDiff(before.options, after.options, state_delta);
    try appendShoptDiff(before.shopts, after.shopts, state_delta);
    try appendAliasDiff(before, after, state_delta);
    try appendTrapDiff(before, after, state_delta);
    if (!positionalsEqual(
        before.positionals.items,
        after.positionals.items,
    )) try state_delta.replacePositionals(after.positionals.items);
    if (!std.mem.eql(
        u8,
        before.logical_cwd,
        after.logical_cwd,
    ) and after.logical_cwd.len != 0) try state_delta.setLogicalCwd(after.logical_cwd);
    for (after.background_jobs.items) |job| {
        if (before.findBackgroundJobById(job.id) == null) try state_delta.appendBackgroundJob(job);
    }
}

fn assignmentListContainsName(assignments: []const command_plan.Assignment, name: []const u8) bool {
    state.assertValidVariableName(name);
    for (assignments) |assignment| {
        assignment.validate();
        if (std.mem.eql(u8, assignment.name, name)) return true;
    }
    return false;
}

fn positionalsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_arg, right_arg| {
        if (!std.mem.eql(u8, left_arg, right_arg)) return false;
    }
    return true;
}

fn appendOptionDiff(before: state.ShellOptions, after: state.ShellOptions, state_delta: *delta.StateDelta) !void {
    const options = [_]state.ShellOption{
        .allexport,
        .emacs,
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
        .vi,
        .xtrace,
    };
    for (options) |option| {
        const enabled = after.enabled(option);
        if (before.enabled(option) != enabled) try state_delta.setOption(option, enabled);
    }
}

fn appendShoptDiff(before: state.ShellShopts, after: state.ShellShopts, state_delta: *delta.StateDelta) !void {
    const shopts = [_]state.ShellShopt{.expand_aliases};
    for (shopts) |shopt| {
        const enabled = after.enabled(shopt);
        if (before.enabled(shopt) != enabled) try state_delta.setShopt(shopt, enabled);
    }
}

fn appendAliasDiff(before: state.ShellState, after: state.ShellState, state_delta: *delta.StateDelta) !void {
    var after_aliases = after.aliases.iterator();
    while (after_aliases.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.value;
        if (before.getAlias(name)) |previous| {
            if (std.mem.eql(u8, previous.value, value)) continue;
        }
        try state_delta.setAlias(name, value);
    }

    var before_aliases = before.aliases.iterator();
    while (before_aliases.next()) |entry| {
        if (!after.aliases.contains(entry.key_ptr.*)) try state_delta.unsetAlias(entry.key_ptr.*);
    }
}

fn appendTrapDiff(before: state.ShellState, after: state.ShellState, state_delta: *delta.StateDelta) !void {
    var after_traps = after.traps.iterator();
    while (after_traps.next()) |entry| {
        const name = entry.key_ptr.*;
        const action = entry.value_ptr.action;
        if (before.getTrap(name)) |previous| {
            if (std.mem.eql(u8, previous.action, action)) continue;
        }
        try state_delta.setTrap(name, action);
    }

    var before_traps = before.traps.iterator();
    while (before_traps.next()) |entry| {
        if (!after.traps.contains(entry.key_ptr.*)) try state_delta.setTrap(entry.key_ptr.*, null);
    }
}

fn evaluateExternal(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    resolution: command_plan.ExternalResolution,
    buffers: *EvaluationBuffers,
) EvalError!outcome.ExitStatus {
    return evaluateExternalWithProcessEnvironment(
        evaluator,
        shell_state,
        eval_context,
        plan,
        resolution,
        &.{},
        buffers,
    );
}

const ExternalInvocation = struct {
    temporary_environment: assignment_runtime.TemporaryEnvironment,
    environment: std.process.Environ.Map,
    argv: [][]const u8,

    fn init(
        allocator: std.mem.Allocator,
        shell_state: state.ShellState,
        plan: command_plan.CommandPlan,
        resolution: command_plan.ExternalResolution,
        process_overlay: []const assignment_runtime.ProcessEnvironmentEntry,
    ) !ExternalInvocation {
        resolution.validate();
        std.debug.assert(plan.target == .child_process);
        std.debug.assert(plan.argv.len != 0);
        std.debug.assert(std.mem.eql(u8, plan.argv[0], resolution.name));
        std.debug.assert(plan.assignmentEffect() == .temporary or plan.assignmentEffect() == .none);

        var temporary_environment = assignment_runtime.TemporaryEnvironment.init(allocator);
        errdefer temporary_environment.deinit();
        if (plan.assignmentEffect() == .temporary) {
            temporary_environment.appendCommandAssignments(shell_state, plan) catch |err| switch (err) {
                error.ReadonlyVariable => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        var environment = try buildExternalEnvironmentWithProcessOverlay(
            allocator,
            shell_state,
            temporary_environment,
            process_overlay,
        );
        errdefer environment.deinit();

        const argv = try externalArgv(allocator, plan, resolution);
        errdefer allocator.free(argv);

        return .{
            .temporary_environment = temporary_environment,
            .environment = environment,
            .argv = argv,
        };
    }

    fn deinit(self: *ExternalInvocation, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        self.environment.deinit();
        self.temporary_environment.deinit();
        self.* = undefined;
    }

    fn run(
        self: ExternalInvocation,
        evaluator: *Evaluator,
        process_port: runtime.process.Port,
        stdin: []const u8,
    ) runtime.process.RunError!runtime.process.RunResult {
        return self.runWithStdin(evaluator, process_port, stdin, .pipe);
    }

    fn runWithStdin(
        self: ExternalInvocation,
        evaluator: *Evaluator,
        process_port: runtime.process.Port,
        stdin: []const u8,
        stdin_stdio: runtime.process.StandardIo,
    ) runtime.process.RunError!runtime.process.RunResult {
        return runExternalProcessWithStdin(evaluator, process_port, self.argv, &self.environment, stdin, stdin_stdio);
    }

    fn spawn(
        self: ExternalInvocation,
        evaluator: *Evaluator,
        process_port: runtime.process.Port,
        options: ExternalSpawnOptions,
    ) runtime.process.SpawnError!runtime.process.SpawnResult {
        return spawnExternalProcess(evaluator, process_port, self.argv, &self.environment, options);
    }
};

const ExternalSpawnOptions = struct {
    stdin: runtime.process.StandardIo = .inherit,
    stdout: runtime.process.StandardIo = .inherit,
    stderr: runtime.process.StandardIo = .inherit,
    process_group: ?runtime.process.ProcessId = null,
};

fn evaluateExternalWithProcessEnvironment(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    resolution: command_plan.ExternalResolution,
    process_overlay: []const assignment_runtime.ProcessEnvironmentEntry,
    buffers: *EvaluationBuffers,
) EvalError!outcome.ExitStatus {
    const shell_state_before = shellStateMutationFingerprint(shell_state);
    defer std.debug.assert(shellStateMutationFingerprint(shell_state) == shell_state_before);

    const fd_port = evaluator.fd_port orelse return error.Unimplemented;
    const process_port = evaluator.process_port orelse return error.Unimplemented;

    var invocation = try ExternalInvocation.init(evaluator.allocator, shell_state, plan, resolution, process_overlay);
    defer invocation.deinit(evaluator.allocator);

    if (externalNeedsBufferedStdin(plan, buffers)) {
        return runExternalWithPipelineInputWithProcessEnvironment(
            evaluator,
            shell_state,
            eval_context,
            plan,
            resolution,
            process_overlay,
            buffers,
        );
    }

    if (semanticHereDocStdinSource(plan.redirections)) |stdin_source| {
        var redirection_guard = RedirectionGuard.empty(.child_only);
        defer redirection_guard.restore();
        if (capturedExternalMode(evaluator.external_stdio) == null) try flushBuffersToInheritedDescriptors(buffers);
        if (plan.redirections.steps.len != 0) {
            const apply_result = try applyRedirectionsForScope(
                evaluator.*,
                buffers,
                .child_only,
                .{},
                plan.redirections,
                redirectionExpansionModeForExternal(evaluator.external_stdio),
                plan.argv[0],
            );
            switch (apply_result) {
                .applied => |applied| redirection_guard = applied,
                .failure => |failure| {
                    try addRedirectionFailureDiagnostic(buffers, plan.argv[0], failure);
                    return 1;
                },
            }
        }

        var run_result = invocation.run(
            evaluator,
            process_port,
            stdin_source.bytes(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |run_err| {
                const failure = runFailure(run_err);
                try buffers.addBuiltinDiagnostic(plan.argv[0], failure.message);
                return failure.status;
            },
        };
        defer run_result.deinit();

        var frame = if (buffers.frame.spec.kind == .pipeline_stage)
            try buffers.outputFrame()
        else
            OutputFrame.initOutcomeCapture(buffers);
        defer frame.deinit();
        if (buffers.frame.spec.kind != .pipeline_stage and
            evaluator.external_stdio != .capture and evaluator.external_stdio != .inherit)
        {
            try frame.routing.setDestination(2, .closed);
            try applyOutputRoutingRedirections(evaluator.*, &frame.routing, plan.redirections);
        } else if (buffers.frame.spec.kind != .pipeline_stage) {
            try applyOutputRoutingRedirections(evaluator.*, &frame.routing, plan.redirections);
        }
        writeExternalRunOutput(&frame, 1, run_result.stdout) catch |err| switch (err) {
            error.Unimplemented => {
                try buffers.addBuiltinDiagnostic(plan.argv[0], "bad file descriptor");
                return 1;
            },
            else => |e| return e,
        };
        writeExternalRunOutput(&frame, 2, run_result.stderr) catch |err| switch (err) {
            error.Unimplemented => {
                try buffers.addBuiltinDiagnostic(plan.argv[0], "bad file descriptor");
                return 1;
            },
            else => |e| return e,
        };
        return normalizeWaitStatus(run_result.status);
    }

    const external_capture_mode = try externalCaptureMode(evaluator.*, eval_context, plan, buffers);
    if (external_capture_mode) |capture_mode| {
        try flushCapturedExternalPrecedingOutput(buffers, capture_mode);
        return evaluateCapturedExternal(
            evaluator,
            process_port,
            fd_port,
            plan,
            invocation,
            buffers,
            capture_mode,
            &.{},
        );
    }

    try flushBuffersToInheritedDescriptors(buffers);

    var redirection_guard = RedirectionGuard.empty(.child_only);
    defer redirection_guard.restore();
    if (hasRedirections(plan)) {
        const apply_result = try applyRedirectionsForScope(
            evaluator.*,
            buffers,
            .child_only,
            .{},
            plan.redirections,
            redirectionExpansionModeForExternal(evaluator.external_stdio),
            plan.argv[0],
        );
        switch (apply_result) {
            .applied => |applied| redirection_guard = applied,
            .failure => |failure| {
                try addRedirectionFailureDiagnostic(buffers, plan.argv[0], failure);
                return 1;
            },
        }
    }

    var child = (invocation.spawn(evaluator, process_port, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |spawn_err| {
            const failure = spawnFailure(spawn_err);
            try buffers.addBuiltinDiagnostic(plan.argv[0], failure.message);
            try flushBuffersForRedirectionTargets(buffers, plan.redirections);
            return failure.status;
        },
    }).child;

    redirection_guard.restore();

    const wait_result = process_port.wait(.{ .child = &child }) catch |err| {
        const failure = waitFailure(err);
        try buffers.addBuiltinDiagnostic(plan.argv[0], failure.message);
        return failure.status;
    };
    return normalizeWaitStatus(wait_result.status);
}

const CapturedExternalMode = enum {
    stdout,
    stdout_and_stderr,
};

fn capturedExternalMode(external_stdio: ExternalStdio) ?CapturedExternalMode {
    return switch (external_stdio) {
        .capture => .stdout_and_stderr,
        .capture_stdout => .stdout,
        .inherit_output, .inherit => null,
    };
}

fn externalCaptureMode(
    evaluator: Evaluator,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    buffers: *EvaluationBuffers,
) EvalError!?CapturedExternalMode {
    plan.validate();
    if (evaluator.external_stdio == .inherit and
        eval_context.command_substitution_depth == 0 and
        eval_context.pipeline_depth == 0)
    {
        return null;
    }
    if (capturedExternalMode(evaluator.external_stdio) == null and
        !eval_context.target.isIsolatedFromParent()) return null;

    var frame = try buffers.outputFrame();
    defer frame.deinit();
    try applyOutputRoutingRedirections(evaluator, &frame.routing, plan.redirections);
    const stdout_captured = outputDestinationCaptures(frame.routing.destination(1));
    const stderr_captured = outputDestinationCaptures(frame.routing.destination(2));
    if (!stdout_captured and !stderr_captured) return null;
    return switch (evaluator.external_stdio) {
        .capture_stdout => if (stdout_captured) .stdout else null,
        .capture => if (stdout_captured) .stdout_and_stderr else null,
        .inherit_output, .inherit => if (stdout_captured) .stdout_and_stderr else null,
    };
}

fn outputDestinationCaptures(destination: OutputDestination) bool {
    return switch (destination) {
        .outcome_stdout_capture,
        .outcome_stderr_capture,
        .side_stdout_capture,
        .command_substitution_side_stdout_capture,
        .pipeline_data_capture,
        .command_substitution_stdout_capture,
        .command_substitution_stderr_capture,
        => true,
        .host_descriptor,
        .closed,
        => false,
    };
}

test "inherited foreground external stdio streams outside capture contexts" {
    const external_resolution: command_plan.ExternalResolution = .{ .name = "external", .path = "/bin/external" };
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"external"} },
        .lookup = .{
            .builtins = &.{},
            .externals = &[_]command_plan.ExternalResolution{external_resolution},
        },
    });

    var input = EvaluationInput.empty();
    var frame = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &frame);
    defer buffers.deinit();

    var evaluator = Evaluator.init(std.testing.allocator);
    evaluator.external_stdio = .inherit;

    const foreground_context = context.EvalContext.forTarget(.child_process);
    try std.testing.expectEqual(
        @as(?CapturedExternalMode, null),
        try externalCaptureMode(evaluator, foreground_context, plan, &buffers),
    );

    const substitution_context = context.EvalContext.forTarget(.current_shell)
        .enterCommandSubstitution()
        .withTarget(.child_process);
    var substitution_frame = try commandSubstitutionExecutionFrame(std.testing.allocator, null, &frame);
    defer substitution_frame.spec.fd_table.deinit(std.testing.allocator);
    var substitution_buffers = EvaluationBuffers.init(std.testing.allocator, &input, &substitution_frame);
    defer substitution_buffers.deinit();
    try std.testing.expectEqual(
        @as(?CapturedExternalMode, .stdout_and_stderr),
        try externalCaptureMode(evaluator, substitution_context, plan, &substitution_buffers),
    );
}

fn evaluateCapturedExternal(
    evaluator: *Evaluator,
    process_port: runtime.process.Port,
    fd_port: runtime.fd.Port,
    plan: command_plan.CommandPlan,
    invocation: ExternalInvocation,
    buffers: *EvaluationBuffers,
    capture_mode: CapturedExternalMode,
    stdin: []const u8,
) EvalError!outcome.ExitStatus {
    plan.validate();
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(invocation.argv.len != 0);
    _ = fd_port;

    var redirection_guard = RedirectionGuard.empty(.child_only);
    defer redirection_guard.restore();
    if (hasRedirections(plan)) {
        const apply_result = try applyRedirectionsForScope(
            evaluator.*,
            buffers,
            .child_only,
            .{},
            plan.redirections,
            switch (capture_mode) {
                .stdout => .inherited,
                .stdout_and_stderr => .command_substitution,
            },
            plan.argv[0],
        );
        switch (apply_result) {
            .applied => |applied| redirection_guard = applied,
            .failure => |failure| {
                try addRedirectionFailureDiagnostic(buffers, plan.argv[0], failure);
                return 1;
            },
        }
    }

    const use_redirected_stdin = stdin.len == 0 and redirectionOrScopedExecTargetsDescriptor(evaluator.*, plan, 0);
    const stdin_stdio: runtime.process.StandardIo = if (use_redirected_stdin)
        .inherit
    else
        .pipe;
    var run_result = invocation.runWithStdin(
        evaluator,
        process_port,
        stdin,
        stdin_stdio,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |run_err| {
            const failure = runFailure(run_err);
            try buffers.addBuiltinDiagnostic(plan.argv[0], failure.message);
            return failure.status;
        },
    };
    defer run_result.deinit();

    try appendCapturedExternalOutput(evaluator.*, buffers, plan, capture_mode, run_result.stdout, run_result.stderr);
    return normalizeWaitStatus(run_result.status);
}

fn flushCapturedExternalPrecedingOutput(
    buffers: *EvaluationBuffers,
    capture_mode: CapturedExternalMode,
) EvalError!void {
    var frame = try buffers.outputFrame();
    defer frame.deinit();
    if (capture_mode == .stdout) try frame.routing.setDestination(2, .closed);
    try frame.flushPendingStandardDescriptors();
}

fn flushChildShellBufferedCommandOutput(
    buffers: *EvaluationBuffers,
    eval_context: context.EvalContext,
) EvalError!void {
    eval_context.validate();
    if (eval_context.command_substitution_depth != 0) return;
    if (buffers.frame.spec.kind == .trap_handler and !eval_context.interactive) return;
    if (!buffers.frame.spec.kind.isParentVisible()) return;
    if (eval_context.target == .current_shell and buffers.frame.spec.kind.isParentVisible()) return;
    var frame = OutputFrame.initInherited(buffers);
    defer frame.deinit();
    try frame.flushPendingStandardDescriptors();
}

fn appendCapturedExternalOutput(
    evaluator: Evaluator,
    buffers: *EvaluationBuffers,
    plan: command_plan.CommandPlan,
    capture_mode: CapturedExternalMode,
    stdout: []const u8,
    stderr: []const u8,
) EvalError!void {
    plan.validate();
    switch (capture_mode) {
        .stdout => {
            var frame = try buffers.outputFrame();
            defer frame.deinit();
            if (buffers.frame.spec.kind != .pipeline_stage) {
                try frame.routing.setDestination(2, .closed);
                try applyOutputRoutingRedirections(evaluator, &frame.routing, plan.redirections);
            }
            try frame.write(1, stdout);
            try frame.write(2, stderr);
        },
        .stdout_and_stderr => {
            var frame = try buffers.outputFrame();
            defer frame.deinit();
            if (buffers.frame.spec.kind != .pipeline_stage) {
                try applyOutputRoutingRedirections(evaluator, &frame.routing, plan.redirections);
            }
            try frame.write(1, stdout);
            try frame.write(2, stderr);
        },
    }
}

fn runExternalWithPipelineInput(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    resolution: command_plan.ExternalResolution,
    buffers: *EvaluationBuffers,
) EvalError!outcome.ExitStatus {
    return runExternalWithPipelineInputWithProcessEnvironment(
        evaluator,
        shell_state,
        eval_context,
        plan,
        resolution,
        &.{},
        buffers,
    );
}

fn runExternalWithPipelineInputWithProcessEnvironment(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    resolution: command_plan.ExternalResolution,
    process_overlay: []const assignment_runtime.ProcessEnvironmentEntry,
    buffers: *EvaluationBuffers,
) EvalError!outcome.ExitStatus {
    const shell_state_before = shellStateMutationFingerprint(shell_state);
    defer std.debug.assert(shellStateMutationFingerprint(shell_state) == shell_state_before);

    const process_port = evaluator.process_port orelse return error.Unimplemented;

    var invocation = try ExternalInvocation.init(evaluator.allocator, shell_state, plan, resolution, process_overlay);
    defer invocation.deinit(evaluator.allocator);

    var redirection_guard = RedirectionGuard.empty(.child_only);
    defer redirection_guard.restore();
    const external_capture_mode = try externalCaptureMode(evaluator.*, eval_context, plan, buffers);
    if (external_capture_mode) |capture_mode| {
        if (buffers.frame.spec.kind != .pipeline_stage) try flushCapturedExternalPrecedingOutput(buffers, capture_mode);
    } else if (buffers.frame.spec.kind != .pipeline_stage) {
        try flushBuffersToInheritedDescriptors(buffers);
    }
    if (plan.redirections.steps.len != 0) {
        const apply_result = try applyRedirectionsForScope(
            evaluator.*,
            buffers,
            .child_only,
            .{},
            plan.redirections,
            redirectionExpansionModeForExternal(evaluator.external_stdio),
            plan.argv[0],
        );
        switch (apply_result) {
            .applied => |applied| redirection_guard = applied,
            .failure => |failure| {
                try addRedirectionFailureDiagnostic(buffers, plan.argv[0], failure);
                return 1;
            },
        }
    }

    const here_doc_stdin_source = semanticHereDocStdinSource(plan.redirections);
    const stdin_source = if (here_doc_stdin_source) |source|
        source.bytes()
    else if (redirectionTargetsDescriptor(plan.redirections, 0))
        ""
    else
        buffers.stdin.takeRemaining();
    const stdin_stdio: runtime.process.StandardIo = if (here_doc_stdin_source != null)
        .pipe
    else if (redirectionTargetsDescriptor(plan.redirections, 0))
        .inherit
    else
        .pipe;

    var run_result = invocation.runWithStdin(
        evaluator,
        process_port,
        stdin_source,
        stdin_stdio,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |run_err| {
            const failure = runFailure(run_err);
            try buffers.addBuiltinDiagnostic(plan.argv[0], failure.message);
            try flushBuffersForRedirectionTargets(buffers, plan.redirections);
            return failure.status;
        },
    };
    defer run_result.deinit();

    var frame = try buffers.outputFrame();
    defer frame.deinit();
    if (buffers.frame.spec.kind != .pipeline_stage) {
        try applyOutputRoutingRedirections(evaluator.*, &frame.routing, plan.redirections);
    }
    writeExternalRunOutput(&frame, 1, run_result.stdout) catch |err| switch (err) {
        error.Unimplemented => {
            try buffers.addBuiltinDiagnostic(plan.argv[0], "bad file descriptor");
            return 1;
        },
        else => |e| return e,
    };
    writeExternalRunOutput(&frame, 2, run_result.stderr) catch |err| switch (err) {
        error.Unimplemented => {
            try buffers.addBuiltinDiagnostic(plan.argv[0], "bad file descriptor");
            return 1;
        },
        else => |e| return e,
    };
    return normalizeWaitStatus(run_result.status);
}

fn evaluateNotFound(
    evaluator: *Evaluator,
    not_found: command_plan.NotFound,
    source_line: ?usize,
    buffers: *EvaluationBuffers,
) EvalError!outcome.ExitStatus {
    var frame = OutputFrame.initOutcomeCapture(buffers);
    defer frame.deinit();
    const diagnostic = try commandNotFoundDiagnostic(evaluator.allocator, evaluator.*, not_found.name, source_line);
    defer evaluator.allocator.free(diagnostic);
    const stderr_text = try std.fmt.allocPrint(evaluator.allocator, "{s}\n", .{diagnostic});
    defer evaluator.allocator.free(stderr_text);
    try frame.addDiagnostic(diagnostic, stderr_text);
    return 127;
}

fn commandNotFoundDiagnostic(
    allocator: std.mem.Allocator,
    evaluator: Evaluator,
    name: []const u8,
    source_line: ?usize,
) ![]const u8 {
    if (evaluator.command_string_line_diagnostics) {
        if (source_line) |line| return std.fmt.allocPrint(allocator, "{d}: {s}: command not found", .{ line, name });
    }
    return std.fmt.allocPrint(allocator, "{s}: command not found", .{name});
}

fn hasRedirections(plan: command_plan.CommandPlan) bool {
    plan.redirections.validate();
    return plan.redirections.steps.len != 0;
}

const StdinSource = union(enum) {
    here_doc: []const u8,

    fn bytes(self: StdinSource) []const u8 {
        return switch (self) {
            .here_doc => |data| data,
        };
    }
};

fn semanticHereDocStdinSource(plan: redirection_plan.RedirectionPlan) ?StdinSource {
    plan.validate();
    var source: ?StdinSource = null;
    for (plan.steps) |step| {
        switch (step.effect) {
            .here_doc => |here_doc| {
                if (here_doc.target != 0) return null;
                source = .{ .here_doc = here_doc.data.bytes };
            },
            .open_path, .duplicate, .close => {
                if (step.target() == 0) source = null;
            },
        }
    }
    return source;
}

fn redirectionTargetsDescriptor(plan: redirection_plan.RedirectionPlan, descriptor: runtime.fd.Descriptor) bool {
    plan.validate();
    runtime.fd.assertValidDescriptor(descriptor);
    for (plan.steps) |step| if (step.target() == descriptor) return true;
    return false;
}

fn redirectionOrScopedExecTargetsDescriptor(
    evaluator: Evaluator,
    plan: command_plan.CommandPlan,
    descriptor: runtime.fd.Descriptor,
) bool {
    plan.validate();
    runtime.fd.assertValidDescriptor(descriptor);
    if (redirectionTargetsDescriptor(plan.redirections, descriptor)) return true;
    const scoped_redirections = evaluator.scoped_exec_redirections orelse return false;
    for (scoped_redirections.items) |scoped| {
        if (redirectionTargetsDescriptor(scoped.redirections, descriptor)) return true;
    }
    return false;
}

fn hasScopedExecRedirections(evaluator: Evaluator) bool {
    const scoped_redirections = evaluator.scoped_exec_redirections orelse return false;
    return scoped_redirections.items.len != 0;
}

fn scopedExecTargetsDescriptor(evaluator: Evaluator, descriptor: runtime.fd.Descriptor) bool {
    runtime.fd.assertValidDescriptor(descriptor);
    const scoped_redirections = evaluator.scoped_exec_redirections orelse return false;
    for (scoped_redirections.items) |scoped| {
        if (redirectionTargetsDescriptor(scoped.redirections, descriptor)) return true;
    }
    return false;
}

fn externalNeedsBufferedStdin(plan: command_plan.CommandPlan, buffers: *EvaluationBuffers) bool {
    plan.validate();
    buffers.stdin.validate();
    return buffers.stdin.remaining().len != 0 and !redirectionTargetsDescriptor(plan.redirections, 0);
}

fn writeAllDescriptor(descriptor: runtime.fd.Descriptor, bytes: []const u8) bool {
    runtime.fd.assertValidDescriptor(descriptor);
    var index: usize = 0;
    while (index < bytes.len) {
        const written = std.c.write(descriptor, bytes[index..].ptr, bytes.len - index);
        if (written <= 0) return false;
        index += @intCast(written);
    }
    return true;
}

fn casePatternMatches(pattern: []const u8, text: []const u8) bool {
    std.debug.assert(std.mem.findScalar(u8, pattern, 0) == null);
    std.debug.assert(std.mem.findScalar(u8, text, 0) == null);
    return expand.patternTextMatches(pattern, text, .{});
}

fn externalArgv(
    allocator: std.mem.Allocator,
    plan: command_plan.CommandPlan,
    resolution: command_plan.ExternalResolution,
) ![][]const u8 {
    std.debug.assert(plan.argv.len != 0);
    resolution.validate();

    const argv = try allocator.alloc([]const u8, plan.argv.len);
    errdefer allocator.free(argv);
    argv[0] = resolution.path;
    @memcpy(argv[1..], plan.argv[1..]);
    assertExternalArgv(argv);
    return argv;
}

fn shellFallbackArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![][]const u8 {
    std.debug.assert(argv.len != 0);
    const fallback_argv = try allocator.alloc([]const u8, argv.len + 1);
    errdefer allocator.free(fallback_argv);
    fallback_argv[0] = "/bin/sh";
    fallback_argv[1] = argv[0];
    @memcpy(fallback_argv[2..], argv[1..]);
    assertExternalArgv(fallback_argv);
    return fallback_argv;
}

fn runExternalProcess(
    evaluator: *Evaluator,
    process_port: runtime.process.Port,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
    stdin: []const u8,
) runtime.process.RunError!runtime.process.RunResult {
    return runExternalProcessWithStdin(evaluator, process_port, argv, environment, stdin, .pipe);
}

fn runExternalProcessWithStdin(
    evaluator: *Evaluator,
    process_port: runtime.process.Port,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
    stdin: []const u8,
    stdin_stdio: runtime.process.StandardIo,
) runtime.process.RunError!runtime.process.RunResult {
    return process_port.run(.{
        .allocator = evaluator.allocator,
        .argv = argv,
        .environment = environment,
        .stdin_stdio = stdin_stdio,
        .stdin = stdin,
    }) catch |err| switch (err) {
        error.InvalidExe => {
            const fallback_argv = try shellFallbackArgv(evaluator.allocator, argv);
            defer evaluator.allocator.free(fallback_argv);
            return process_port.run(.{
                .allocator = evaluator.allocator,
                .argv = fallback_argv,
                .environment = environment,
                .stdin_stdio = stdin_stdio,
                .stdin = stdin,
            });
        },
        else => |run_err| return run_err,
    };
}

fn spawnExternalProcess(
    evaluator: *Evaluator,
    process_port: runtime.process.Port,
    argv: []const []const u8,
    environment: *const std.process.Environ.Map,
    options: ExternalSpawnOptions,
) runtime.process.SpawnError!runtime.process.SpawnResult {
    return process_port.spawn(.{
        .argv = argv,
        .environment = environment,
        .stdin = options.stdin,
        .stdout = options.stdout,
        .stderr = options.stderr,
        .process_group = options.process_group,
    }) catch |err| switch (err) {
        error.InvalidExe => {
            const fallback_argv = try shellFallbackArgv(evaluator.allocator, argv);
            defer evaluator.allocator.free(fallback_argv);
            return process_port.spawn(.{
                .argv = fallback_argv,
                .environment = environment,
                .stdin = options.stdin,
                .stdout = options.stdout,
                .stderr = options.stderr,
                .process_group = options.process_group,
            });
        },
        else => |spawn_err| return spawn_err,
    };
}

fn buildExternalEnvironmentWithProcessOverlay(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    temporary_environment: assignment_runtime.TemporaryEnvironment,
    process_overlay: []const assignment_runtime.ProcessEnvironmentEntry,
) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(allocator);
    errdefer environment.deinit();

    var variables = shell_state.variables.iterator();
    while (variables.next()) |entry| {
        const name = entry.key_ptr.*;
        const variable = entry.value_ptr.*;
        if (!variable.exported) continue;
        state.assertValidVariableName(name);
        assertValidEnvironmentEntry(name, variable.value);
        try environment.put(name, variable.value);
    }

    for (temporary_environment.variables.items) |variable| {
        state.assertValidVariableName(variable.name);
        assertValidEnvironmentEntry(variable.name, variable.value);
        try environment.put(variable.name, variable.value);
    }

    for (process_overlay) |entry| {
        entry.validate();
        assertValidEnvironmentEntry(entry.name, entry.value);
        try environment.put(entry.name, entry.value);
    }

    assertValidEnvironmentMap(environment);
    return environment;
}

fn assertExternalArgv(argv: []const []const u8) void {
    std.debug.assert(argv.len != 0);
    for (argv) |arg| std.debug.assert(arg.len != 0);
}

fn assertValidEnvironmentEntry(name: []const u8, value: []const u8) void {
    assignment_runtime.assertValidProcessEnvironmentName(name);
    std.debug.assert(std.mem.findScalar(u8, name, '=') == null);
    std.debug.assert(std.mem.findScalar(u8, name, 0) == null);
    std.debug.assert(std.mem.findScalar(u8, value, 0) == null);
}

fn assertValidEnvironmentMap(environment: std.process.Environ.Map) void {
    const keys = environment.keys();
    const values = environment.values();
    std.debug.assert(keys.len == values.len);
    for (keys, values) |key, value| assertValidEnvironmentEntry(key, value);
}

const CommandFailure = struct {
    status: outcome.ExitStatus,
    message: []const u8,
};

fn spawnFailure(err: runtime.process.SpawnError) CommandFailure {
    return switch (err) {
        error.FileNotFound, error.NotDir => .{ .status = 127, .message = "command not found" },
        error.AccessDenied, error.PermissionDenied => .{ .status = 126, .message = "permission denied" },
        error.IsDir => .{ .status = 126, .message = "is a directory" },
        else => .{ .status = 126, .message = "cannot spawn" },
    };
}

fn waitFailure(err: runtime.process.WaitError) CommandFailure {
    return switch (err) {
        error.AccessDenied => .{ .status = 126, .message = "wait permission denied" },
        else => .{ .status = 126, .message = "wait failed" },
    };
}

fn runFailure(err: anyerror) CommandFailure {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.FileNotFound, error.NotDir => .{ .status = 127, .message = "command not found" },
        error.AccessDenied, error.PermissionDenied => .{ .status = 126, .message = "permission denied" },
        error.IsDir => .{ .status = 126, .message = "is a directory" },
        else => .{ .status = 126, .message = "cannot run" },
    };
}

fn redirectionFailureMessage(failure: redirection_plan.ApplyFailure) []const u8 {
    runtime.fd.assertValidDescriptor(failure.target);
    return switch (failure.detail) {
        .open => |err| switch (err) {
            error.FileNotFound => "no such file or directory",
            error.AccessDenied, error.PermissionDenied => "permission denied",
            error.IsDir => "is a directory",
            else => "redirection open failed",
        },
        .close => "redirection close failed",
        .duplicate => |err| switch (err) {
            error.BadFileDescriptor => "bad file descriptor",
            else => "redirection duplicate failed",
        },
        .pipe => "here-document pipe failed",
        .write => |err| switch (err) {
            error.BadFileDescriptor => "bad file descriptor",
            error.BrokenPipe => "here-document pipe closed",
            else => "here-document write failed",
        },
    };
}

fn addRedirectionFailureDiagnostic(
    buffers: *EvaluationBuffers,
    command_name: []const u8,
    failure: redirection_plan.ApplyFailure,
) !void {
    runtime.fd.assertValidDescriptor(failure.target);
    if (failure.diagnostic_emitted) return;
    if (!descriptorIsOpen(2)) return;
    try buffers.addBuiltinDiagnostic(command_name, redirectionFailureMessage(failure));
}

fn normalizeWaitStatus(status: runtime.process.WaitStatus) outcome.ExitStatus {
    const normalized: outcome.ExitStatus = switch (status) {
        .exited => |code| code,
        .signaled => |signal| signalStatus(signal),
        .stopped => |signal| signalStatus(signal),
        .unknown => |raw| @intCast(raw & 0xff),
    };
    return normalized;
}

fn signalStatus(signal: u8) outcome.ExitStatus {
    std.debug.assert(signal != 0);
    const value: u16 = 128 + @as(u16, signal);
    return if (value <= std.math.maxInt(outcome.ExitStatus)) @intCast(value) else std.math.maxInt(outcome.ExitStatus);
}

fn shellStateMutationFingerprint(shell_state: state.ShellState) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var variables = shell_state.variables.iterator();
    while (variables.next()) |entry| {
        hasher.update(entry.key_ptr.*);
        hasher.update(entry.value_ptr.value);
        const flags = [_]u8{ @intFromBool(entry.value_ptr.exported), @intFromBool(entry.value_ptr.readonly) };
        hasher.update(&flags);
    }
    var functions = shell_state.functions.iterator();
    while (functions.next()) |entry| {
        hasher.update(entry.key_ptr.*);
        hasher.update(entry.value_ptr.name);
    }
    var aliases = shell_state.aliases.iterator();
    while (aliases.next()) |entry| {
        hasher.update(entry.key_ptr.*);
        hasher.update(entry.value_ptr.value);
    }
    var traps = shell_state.traps.iterator();
    while (traps.next()) |entry| {
        hasher.update(entry.key_ptr.*);
        hasher.update(entry.value_ptr.action);
    }
    hasher.update(std.mem.asBytes(&shell_state.options));
    hasher.update(shell_state.logical_cwd);
    hasher.update(std.mem.asBytes(&shell_state.last_status));
    if (shell_state.pending_exit) |pending_exit| hasher.update(std.mem.asBytes(&pending_exit));
    for (shell_state.pending_traps.items) |signal| {
        const signal_byte: u8 = @intFromEnum(signal);
        hasher.update(&.{signal_byte});
    }
    for (shell_state.background_jobs.items) |job| {
        hasher.update(std.mem.asBytes(&job.id));
        hasher.update(std.mem.asBytes(&job.pid));
        if (job.process_group) |process_group| hasher.update(std.mem.asBytes(&process_group));
        hasher.update(job.command);
        for (job.processes.items) |process| hasher.update(std.mem.asBytes(&process.stage_index));
    }
    for (shell_state.positionals.items) |arg| hasher.update(arg);
    return hasher.final();
}

fn evaluateBuiltin(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    definition: builtin.Builtin,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    definition.validate();
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, plan.argv[0], definition.name));
    switch (plan.classification) {
        .special_builtin => |classified| std.debug.assert(
            std.mem.eql(u8, classified.name, definition.name) and
                classified.kind == definition.kind,
        ),
        .regular_builtin => |classified| std.debug.assert(
            std.mem.eql(u8, classified.name, definition.name) and
                classified.kind == definition.kind,
        ),
        else => unreachable,
    }

    if (std.mem.eql(u8, definition.name, ":")) return normalEvaluation(0);
    if (std.mem.eql(u8, definition.name, "true")) return normalEvaluation(0);
    if (std.mem.eql(u8, definition.name, "false")) return normalEvaluation(1);
    if (std.mem.eql(u8, definition.name, "break")) {
        return evaluateLoopControl(eval_context, plan.argv, .break_loop, buffers);
    }
    if (std.mem.eql(u8, definition.name, "continue")) {
        return evaluateLoopControl(eval_context, plan.argv, .continue_loop, buffers);
    }
    if (std.mem.eql(u8, definition.name, "exec")) {
        return evaluateExec(evaluator, shell_state, plan, state_delta, buffers);
    }
    if (std.mem.eql(u8, definition.name, "exit")) return evaluateExit(shell_state, plan.argv, buffers);
    if (std.mem.eql(u8, definition.name, "return")) {
        return evaluateReturn(shell_state, eval_context, plan.argv, buffers);
    }
    if (std.mem.eql(u8, definition.name, "echo")) {
        return normalEvaluation(try evaluateEchoRouted(evaluator.allocator, plan.argv, buffers));
    }
    if (std.mem.eql(u8, definition.name, "printf")) {
        return normalEvaluation(try evaluatePrintfRouted(evaluator.allocator, eval_context, plan.argv, buffers));
    }
    if (std.mem.eql(u8, definition.name, "env")) {
        return normalEvaluation(
            try evaluateEnv(evaluator, shell_state, eval_context, plan, &buffers.stdout, buffers),
        );
    }
    if (std.mem.eql(u8, definition.name, "pwd")) {
        return normalEvaluation(
            try evaluatePwd(evaluator, shell_state, plan.argv, &buffers.stdout, buffers),
        );
    }
    if (std.mem.eql(u8, definition.name, "command")) {
        return evaluateCommandBuiltin(
            evaluator,
            shell_state,
            eval_context,
            plan,
            state_delta,
            buffers,
        );
    }
    if (std.mem.eql(u8, definition.name, "fc")) return evaluateFc(
        evaluator,
        shell_state,
        eval_context,
        plan.argv,
        state_delta,
        buffers,
    );
    if (std.mem.eql(u8, definition.name, "test") or
        std.mem.eql(u8, definition.name, "["))
    {
        return normalEvaluation(evaluateTestBuiltin(evaluator.fs_port, evaluator.fd_port, plan.argv));
    }
    if (std.mem.eql(u8, definition.name, "eval")) return evaluateEval(
        evaluator,
        shell_state,
        eval_context,
        plan,
        state_delta,
        buffers,
    );
    if (std.mem.eql(u8, definition.name, ".")) return evaluateDot(
        evaluator,
        shell_state,
        eval_context,
        plan,
        state_delta,
        buffers,
    );
    if (std.mem.eql(u8, definition.name, "export")) return normalEvaluation(try evaluateExport(
        shell_state,
        eval_context.features,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "readonly")) return normalEvaluation(try evaluateReadonly(
        shell_state,
        eval_context.features,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "unset")) return normalEvaluation(try evaluateUnset(
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "set")) return normalEvaluation(try evaluateSet(
        shell_state,
        eval_context,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "shift")) return normalEvaluation(try evaluateShift(
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "alias")) return normalEvaluation(try evaluateAlias(
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "unalias")) return normalEvaluation(try evaluateUnalias(
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "trap")) return normalEvaluation(try evaluateTrap(
        evaluator.allocator,
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "read")) return normalEvaluation(try evaluateRead(
        evaluator,
        shell_state,
        plan,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "cd")) return normalEvaluation(try evaluateCd(
        evaluator,
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "jobs")) return normalEvaluation(try evaluateJobs(
        evaluator,
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "wait")) return normalEvaluation(try evaluateWait(
        evaluator,
        shell_state,
        eval_context,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "bg")) return normalEvaluation(try evaluateBg(
        evaluator,
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "fg")) return normalEvaluation(try evaluateFg(
        evaluator,
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "times")) return normalEvaluation(try evaluateTimes(
        evaluator,
        plan.argv,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "ulimit")) return normalEvaluation(try evaluateUlimit(
        evaluator,
        plan.argv,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "umask")) return normalEvaluation(try evaluateUmask(
        evaluator,
        plan.argv,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "hash")) return normalEvaluation(try evaluateHash(
        evaluator,
        shell_state,
        plan,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "getopts")) return normalEvaluation(try evaluateGetopts(
        shell_state,
        plan.argv,
        state_delta,
        buffers,
    ));
    if (std.mem.eql(u8, definition.name, "kill")) return normalEvaluation(try evaluateKill(
        evaluator,
        plan.argv,
        buffers,
    ));
    if (definition.origin == .extension) {
        if (evaluator.extensionHandler(definition.name)) |handler| return evaluateExtensionBuiltin(
            evaluator,
            handler,
            shell_state,
            eval_context,
            plan,
            state_delta,
            buffers,
        );
    }
    return error.Unimplemented;
}

fn evaluateExtensionBuiltin(
    evaluator: *Evaluator,
    handler: extension_api.HandlerSpec,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    var external_resolver_context: ExtensionExternalResolverContext = .{
        .evaluator = evaluator,
        .shell_state = shell_state,
    };
    var source_evaluator_context: ExtensionSourceEvaluatorContext = .{
        .evaluator = evaluator,
        .shell_state = shell_state,
        .eval_context = eval_context,
        .state_delta = state_delta,
        .buffers = buffers,
    };
    var invocation: extension_api.Invocation = .{
        .allocator = buffers.allocator,
        .argv = plan.argv,
        .assignments = plan.assignments,
        .builtins = evaluator.builtin_definitions,
        .shell_state = shell_state,
        .state_delta = state_delta,
        .eval_context = eval_context,
        .function_scope = extensionFunctionScope(evaluator),
        .external_resolver = extensionExternalResolver(&external_resolver_context),
        .source_evaluator = extensionSourceEvaluator(&source_evaluator_context),
        .stdout = &buffers.stdout,
        .stderr = &buffers.stderr,
        .diagnostics = &buffers.diagnostics,
    };
    const result = handler.handler(handler.context, &invocation) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unimplemented,
    };
    result.validate();
    return .{ .status = result.status, .control_flow = result.control_flow };
}

const ExtensionExternalResolverContext = struct {
    evaluator: *Evaluator,
    shell_state: state.ShellState,
};

fn extensionExternalResolver(context_value: *ExtensionExternalResolverContext) extension_api.ExternalResolver {
    return .{
        .context = context_value,
        .resolve_command = resolveExtensionExternal,
        .resolve_all_commands = resolveAllExtensionExternals,
    };
}

fn resolveExtensionExternal(
    allocator: std.mem.Allocator,
    opaque_context: *anyopaque,
    assignments: []const command_plan.Assignment,
    name: []const u8,
) !?command_plan.ExternalResolution {
    const resolver_context: *ExtensionExternalResolverContext = @ptrCast(@alignCast(opaque_context));
    const command: command_plan.ExpandedSimpleCommand = .{
        .assignments = assignments,
        .argv = &.{name},
    };
    return resolveExternalForEvaluation(
        allocator,
        resolver_context.evaluator.fs_port,
        resolver_context.shell_state,
        command,
    );
}

fn resolveAllExtensionExternals(
    allocator: std.mem.Allocator,
    opaque_context: *anyopaque,
    assignments: []const command_plan.Assignment,
    name: []const u8,
) ![]command_plan.ExternalResolution {
    const resolver_context: *ExtensionExternalResolverContext = @ptrCast(@alignCast(opaque_context));
    const command: command_plan.ExpandedSimpleCommand = .{
        .assignments = assignments,
        .argv = &.{name},
    };
    return resolveAllExternalsForEvaluation(
        allocator,
        resolver_context.evaluator.fs_port,
        resolver_context.shell_state,
        command,
    );
}

const ExtensionSourceEvaluatorContext = struct {
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
};

fn extensionSourceEvaluator(context_value: *ExtensionSourceEvaluatorContext) extension_api.SourceEvaluator {
    return .{
        .context = context_value,
        .source_file = evaluateExtensionSourceFile,
    };
}

fn evaluateExtensionSourceFile(
    opaque_context: *anyopaque,
    command: []const u8,
    path: []const u8,
    args: []const []const u8,
) !extension_api.EvaluationResult {
    const source_context: *ExtensionSourceEvaluatorContext = @ptrCast(@alignCast(opaque_context));
    const result = try evaluateSourcePath(
        source_context.evaluator,
        source_context.shell_state,
        source_context.eval_context,
        command,
        path,
        &.{},
        false,
        args,
        source_context.state_delta,
        source_context.buffers,
    );
    return .{ .status = result.status, .control_flow = result.control_flow };
}

fn extensionFunctionScope(evaluator: *Evaluator) ?extension_api.FunctionScope {
    const frame = evaluator.function_frame orelse return null;
    return .{
        .depth = frame.depth,
        .context = frame,
        .add_local = addExtensionFunctionLocal,
    };
}

fn addExtensionFunctionLocal(opaque_frame: *anyopaque, name: []const u8) !void {
    const frame: *FunctionFrame = @ptrCast(@alignCast(opaque_frame));
    try frame.addLocal(name);
}

fn evaluateReturn(
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "return"));

    if (!eval_context.canReturnFromFunction() and !eval_context.canReturnFromSource())
        return normalEvaluation(try builtinUsageError(
            buffers,
            "return",
            "not in a function or dot script",
        ));
    if (argv.len > 2) return normalEvaluation(try builtinUsageError(buffers, "return", "too many arguments"));
    const status: outcome.ExitStatus = if (argv.len == 2) blk: {
        const operand = std.mem.trim(u8, argv[1], &std.ascii.whitespace);
        const parsed = std.fmt.parseInt(u64, operand, 10) catch return normalEvaluation(try builtinUsageError(
            buffers,
            "return",
            "numeric argument required",
        ));
        break :blk @truncate(parsed);
    } else shell_state.last_status;
    const scope: outcome.ReturnScope = if (eval_context.canReturnFromSource()) .sourced_script else .function;
    return .{ .status = status, .control_flow = .{ .return_from_scope = .{ .scope = scope, .status = status } } };
}

fn evaluateEval(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    const argv = plan.argv;
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "eval"));

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(evaluator.allocator);
    for (argv[1..], 0..) |arg, index| {
        if (index != 0) try source.append(evaluator.allocator, ' ');
        try source.appendSlice(evaluator.allocator, arg);
    }
    if (source.items.len == 0) return normalEvaluation(0);

    var working_state = shell_state.clone(evaluator.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer working_state.deinit();
    try applyEvalAssignmentOverlay(&working_state, shell_state, plan);

    const result = try evaluateSourcedTextChunks(evaluator, &working_state, eval_context, source.items, buffers);
    if (bashEvalUsesTemporaryAssignments(eval_context, plan)) {
        try appendShellStateDiffExcludingVariables(shell_state, working_state, state_delta, plan.assignments);
    } else {
        try appendShellStateDiff(shell_state, working_state, state_delta);
    }
    return result;
}

fn applyEvalAssignmentOverlay(
    working_state: *state.ShellState,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
) !void {
    working_state.validate();
    shell_state.validate();
    plan.validate();
    if (plan.assignments.len == 0) return;

    const exported: ?bool = if (shell_state.options.enabled(.allexport)) true else null;
    for (plan.assignments) |assignment| {
        working_state.putVariable(
            assignment.name,
            assignment.value,
            .{ .exported = exported },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadonlyVariable => unreachable,
        };
    }
}

fn evaluateDot(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    plan.validate();
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, plan.argv[0], "."));
    if (plan.argv.len < 2) return normalEvaluation(try builtinStatusError(buffers, 2, ".", "missing file operand"));

    return evaluateSourceFile(evaluator, shell_state, eval_context, plan, state_delta, buffers);
}

fn evaluateSourceFile(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    plan.validate();
    std.debug.assert(plan.argv.len >= 2);
    const command = plan.argv[0];
    const path = plan.argv[1];
    std.debug.assert(std.mem.eql(u8, command, "."));
    return evaluateSourcePath(
        evaluator,
        shell_state,
        eval_context,
        command,
        path,
        plan.assignments,
        true,
        if (eval_context.features.isBash()) plan.argv[2..] else &.{},
        state_delta,
        buffers,
    );
}

fn evaluateSourcePath(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    command: []const u8,
    path: []const u8,
    assignments: []const command_plan.Assignment,
    search_path: bool,
    args: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    std.debug.assert(command.len != 0);
    std.debug.assert(path.len != 0);
    for (assignments) |assignment| assignment.validate();
    const io = evaluator.io orelse return error.Unimplemented;
    const source = readSourceFile(evaluator.allocator, io, shell_state, assignments, path, search_path) catch
        return normalEvaluation(try builtinStatusError(buffers, 1, command, "file not found"));
    defer evaluator.allocator.free(source);

    const result = try evaluateSourcedText(
        evaluator,
        shell_state,
        eval_context.enterSource(),
        source,
        args,
        state_delta,
        buffers,
    );
    return consumeSourcedScriptReturn(result);
}

fn readSourceFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: state.ShellState,
    assignments: []const command_plan.Assignment,
    path: []const u8,
    search_path: bool,
) ![]const u8 {
    shell_state.validate();
    for (assignments) |assignment| assignment.validate();
    std.debug.assert(path.len != 0);
    if (!search_path or std.mem.findScalar(u8, path, '/') != null) return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .unlimited,
    );

    const path_value = commandLookupPath(shell_state, .{
        .assignments = assignments,
    }) orelse return error.FileNotFound;
    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |part| {
        const candidate = if (part.len == 0)
            try allocator.dupe(u8, path)
        else
            try std.mem.concat(allocator, u8, &.{ part, "/", path });
        defer allocator.free(candidate);
        return std.Io.Dir.cwd().readFileAlloc(io, candidate, allocator, .unlimited) catch continue;
    }
    return error.FileNotFound;
}

fn consumeSourcedScriptReturn(result: SimpleEvalResult) SimpleEvalResult {
    if (result.control_flow == .return_from_scope) {
        const request = result.control_flow.return_from_scope;
        if (request.scope == .sourced_script) return normalEvaluation(request.status);
    }
    return result;
}

fn evaluateSourcedText(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    source: []const u8,
    args: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    var working_state = shell_state.clone(evaluator.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer working_state.deinit();
    if (args.len != 0) try working_state.replacePositionals(args);

    const result = try evaluateSourcedTextChunks(evaluator, &working_state, eval_context, source, buffers);
    if (args.len != 0 and positionalsEqual(working_state.positionals.items, args)) {
        try working_state.replacePositionals(shell_state.positionals.items);
    }
    try appendShellStateDiff(shell_state, working_state, state_delta);
    return result;
}

fn evaluateSourcedTextChunks(
    evaluator: *Evaluator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    source: []const u8,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    shell_state.validate();
    eval_context.validate();
    var result = normalEvaluation(0);
    var start = skipSourcedTextChunkSeparators(source, 0);
    while (start < source.len) {
        var end = sourcedTextLineEnd(source, start);
        while (true) {
            const chunk = std.mem.trim(u8, source[start..end], " \t\r\n;");
            if (chunk.len == 0) break;

            var alias_snapshot = shell_state.clone(evaluator.allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadonlyVariable => unreachable,
            };
            defer alias_snapshot.deinit();

            const aliased = parser.expandAliases(evaluator.allocator, chunk, .{
                .features = evaluator.features.withStrictDiagnostics(),
                .context = &alias_snapshot,
                .lookup = lookupSemanticAliasForParser,
                .collect_command_substitution_nodes = false,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unimplemented,
            };
            defer evaluator.allocator.free(aliased);
            const parse_source = if (shell_state.shopts.enabled(.expand_aliases)) aliased else chunk;
            var parsed = parser.parse(evaluator.allocator, parse_source, .{
                .features = evaluator.features.withStrictDiagnostics(),
                .collect_command_substitution_nodes = false,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unimplemented,
            };
            defer parsed.deinit();
            if (parsed.diagnostics.len == 0) {
                const needs_more_here_doc = try sourcedTextChunkNeedsMoreHereDoc(
                    evaluator.allocator,
                    parsed,
                    parse_source,
                );
                if (needs_more_here_doc and end < source.len) {
                    end = sourcedTextLineEnd(source, end);
                    continue;
                }
                const previous_alias_state = evaluator.alias_state;
                evaluator.alias_state = &alias_snapshot;
                defer evaluator.alias_state = previous_alias_state;
                result = try evaluateStatementListSourceAtLine(
                    evaluator,
                    shell_state,
                    eval_context,
                    parse_source,
                    sourceLineIndex(source, start),
                    buffers,
                );
                if (result.control_flow != .normal) return result;
                break;
            }
            if (!parsed.incomplete or end >= source.len) {
                return evaluateStatementListSourceAtLine(
                    evaluator,
                    shell_state,
                    eval_context,
                    chunk,
                    sourceLineIndex(source, start),
                    buffers,
                );
            }
            end = sourcedTextLineEnd(source, end);
        }
        start = skipSourcedTextChunkSeparators(source, end);
    }
    return result;
}

fn sourcedTextChunkNeedsMoreHereDoc(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    source: []const u8,
) !bool {
    var body_index: usize = 0;
    for (parsed.nodes) |node| {
        if (node.kind != .redirection) continue;
        const info = try sourcedTextHereDocInfo(allocator, parsed, node) orelse continue;
        defer allocator.free(info.delimiter);
        const body = sourcedTextHereDocBodyAt(parsed, body_index) orelse continue;
        body_index += 1;
        if (body.span.end != source.len) continue;
        if (!sourceEndsWithHereDocDelimiterLine(source, info.delimiter, info.strip_tabs)) return true;
    }
    return false;
}

const SourcedTextHereDocInfo = struct {
    delimiter: []const u8,
    strip_tabs: bool,
};

fn sourcedTextHereDocInfo(
    allocator: std.mem.Allocator,
    parsed: parser.ParseResult,
    node: parser.Node,
) !?SourcedTextHereDocInfo {
    var operator: parser.TokenKind = .invalid;
    var target_token: ?usize = null;
    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_id| {
            const token = parsed.tokens[token_id.index()];
            if (token.kind.isRedirectOperator()) operator = token.kind;
        },
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            if (child_node.kind == .word) target_token = child_node.token_start;
        },
    };
    if (operator != .dless and operator != .dless_dash) return null;

    const token_index = target_token orelse return null;
    const raw = parsed.tokens[token_index].lexeme(parsed.source);
    const normalized = try removeSourcedTextLineContinuations(allocator, raw);
    defer allocator.free(normalized);
    return .{
        .delimiter = try expand.quoteRemove(allocator, normalized),
        .strip_tabs = operator == .dless_dash,
    };
}

fn removeSourcedTextLineContinuations(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.find(u8, raw, "\\\n") == null) return allocator.dupe(u8, raw);

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '\\' and index + 1 < raw.len and raw[index + 1] == '\n') {
            index += 2;
            continue;
        }
        try normalized.append(allocator, raw[index]);
        index += 1;
    }
    return normalized.toOwnedSlice(allocator);
}

fn sourcedTextHereDocBodyAt(parsed: parser.ParseResult, target_index: usize) ?parser.Node {
    var current_index: usize = 0;
    for (parsed.nodes) |node| {
        if (node.kind != .here_doc_body) continue;
        if (current_index == target_index) return node;
        current_index += 1;
    }
    return null;
}

fn sourceEndsWithHereDocDelimiterLine(source: []const u8, delimiter: []const u8, strip_tabs: bool) bool {
    if (source.len == 0) return false;
    const line_end = if (source[source.len - 1] == '\n') source.len - 1 else source.len;
    const raw_line_start = if (std.mem.findScalarLast(u8, source[0..line_end], '\n')) |newline|
        newline + 1
    else
        0;
    const line_start = if (strip_tabs) blk: {
        var index = raw_line_start;
        while (index < line_end and source[index] == '\t') : (index += 1) {}
        break :blk index;
    } else raw_line_start;
    return std.mem.eql(u8, source[line_start..line_end], delimiter);
}

fn skipSourcedTextChunkSeparators(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and (source[index] == ' ' or
        source[index] == '\t' or
        source[index] == '\r' or
        source[index] == '\n' or
        source[index] == ';')) index += 1;
    return index;
}

fn sourcedTextLineEnd(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len) {
        if (source[index] == '\\' and index + 1 < source.len and source[index + 1] == '\n') {
            index += 2;
            continue;
        }
        if (source[index] == '\n') {
            index += 1;
            break;
        }
        index += 1;
    }
    return index;
}

fn evaluateEnv(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    stdout: *std.ArrayList(u8),
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, plan.argv[0], "env"));

    var index: usize = 1;
    if (index < plan.argv.len and std.mem.eql(u8, plan.argv[index], "--")) index += 1;

    var temporary_environment = assignment_runtime.TemporaryEnvironment.init(evaluator.allocator);
    defer temporary_environment.deinit();
    if (plan.assignmentEffect() == .temporary) {
        temporary_environment.appendCommandAssignments(shell_state, plan) catch |err| switch (err) {
            error.ReadonlyVariable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    var process_overlay = assignment_runtime.ProcessEnvironmentOverlay.init(evaluator.allocator);
    defer process_overlay.deinit();
    while (index < plan.argv.len) : (index += 1) {
        const equals = std.mem.indexOfScalar(u8, plan.argv[index], '=') orelse break;
        const name = plan.argv[index][0..equals];
        if (!assignment_runtime.isProcessEnvironmentName(name)) {
            return builtinStatusError(buffers, 1, "env", "invalid variable name");
        }
        process_overlay.put(name, plan.argv[index][equals + 1 ..]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    if (index < plan.argv.len) {
        const command: command_plan.ExpandedSimpleCommand = .{
            .assignments = plan.assignments,
            .argv = plan.argv[index..],
            .last_command_substitution_status = plan.last_command_substitution_status,
            .source_line = plan.source_line,
        };
        const external = try resolveExternalForEnvEvaluation(
            evaluator.allocator,
            evaluator.fs_port,
            shell_state,
            command,
            process_overlay.entries.items,
        );
        defer if (external) |resolution| evaluator.allocator.free(resolution.path);
        const resolution = external orelse return evaluateNotFound(
            evaluator,
            .{ .name = command.argv[0] },
            command.source_line,
            buffers,
        );
        const target_plan = command_plan.classifyExpandedSimpleCommand(.{
            .command = command,
            .lookup = .{ .externals = &.{resolution} },
            .target = .child_process,
        });
        return evaluateExternalWithProcessEnvironment(
            evaluator,
            shell_state,
            eval_context,
            target_plan,
            resolution,
            process_overlay.entries.items,
            buffers,
        );
    }

    var environment = try buildExternalEnvironmentWithProcessOverlay(
        evaluator.allocator,
        shell_state,
        temporary_environment,
        process_overlay.entries.items,
    );
    defer environment.deinit();
    var iterator = environment.iterator();
    while (iterator.next()) |entry| {
        try stdout.print(evaluator.allocator, "{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return 0;
}

fn evaluatePwd(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    argv: []const []const u8,
    stdout: *std.ArrayList(u8),
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "pwd"));

    var physical = false;
    if (argv.len > 2) return builtinUsageError(buffers, "pwd", "too many arguments");
    if (argv.len == 2) {
        if (std.mem.eql(u8, argv[1], "-L")) {
            physical = false;
        } else if (std.mem.eql(u8, argv[1], "-P")) {
            physical = true;
        } else {
            return builtinUsageError(buffers, "pwd", "unsupported option");
        }
    }

    if (!physical and shell_state.logical_cwd.len != 0) {
        try stdout.print(evaluator.allocator, "{s}\n", .{shell_state.logical_cwd});
        return 0;
    }

    const fs_port = evaluator.fs_port orelse return error.Unimplemented;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = fs_port.getCwd(runtime.fs.GetCwdRequest.init(&buffer)) catch |err| switch (err) {
        else => return builtinStatusError(buffers, 1, "pwd", "could not get current directory"),
    };
    try stdout.print(evaluator.allocator, "{s}\n", .{cwd.path});
    return 0;
}

fn evaluateCd(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "cd"));
    var index: usize = 1;
    var physical = false;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-L")) {
            physical = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-P")) {
            physical = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            return builtinUsageError(buffers, "cd", "unsupported option");
        }
        break;
    }
    if (argv.len > index + 1) return builtinUsageError(buffers, "cd", "too many arguments");
    const fs_port = evaluator.fs_port orelse return error.Unimplemented;
    const old_pwd = if (shell_state.logical_cwd.len != 0)
        shell_state.logical_cwd
    else if (shell_state.getVariable("PWD")) |pwd| pwd.value else "";
    var before_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_pwd = if (old_pwd.len != 0) old_pwd else blk: {
        const cwd = fs_port.getCwd(runtime.fs.GetCwdRequest.init(&before_buffer)) catch return builtinStatusError(
            buffers,
            1,
            "cd",
            "could not get current directory",
        );
        break :blk cwd.path;
    };

    const requested_directory = if (index < argv.len)
        argv[index]
    else if (shell_state.getVariable("HOME")) |home|
        home.value
    else
        return builtinStatusError(buffers, 1, "cd", "HOME not set");
    if (requested_directory.len == 0) return builtinStatusError(buffers, 1, "cd", "empty directory");

    const directory = if (std.mem.eql(u8, requested_directory, "-")) blk: {
        const oldpwd = shell_state.getVariable("OLDPWD") orelse return builtinStatusError(
            buffers,
            1,
            "cd",
            "OLDPWD not set",
        );
        break :blk oldpwd.value;
    } else requested_directory;

    var path_to_change: ?[]const u8 = null;
    var owned_path: ?[]const u8 = null;
    defer if (owned_path) |path| buffers.allocator.free(path);
    var print_new_directory = std.mem.eql(u8, requested_directory, "-");
    if (shouldSearchCdpath(directory)) {
        const cdpath = if (shell_state.getVariable("CDPATH")) |value| value.value else "";
        var parts = std.mem.splitScalar(u8, cdpath, ':');
        while (parts.next()) |part| {
            const candidate = if (part.len == 0)
                try buffers.allocator.dupe(u8, directory)
            else
                try std.mem.concat(buffers.allocator, u8, &.{ part, "/", directory });
            errdefer buffers.allocator.free(candidate);
            if (canChangeDirectory(fs_port, candidate)) {
                owned_path = candidate;
                path_to_change = candidate;
                print_new_directory = print_new_directory or part.len != 0;
                break;
            }
            buffers.allocator.free(candidate);
        }
    }

    const target = path_to_change orelse directory;
    const logical_target = if (physical)
        null
    else
        try resolveLogicalCdPath(buffers.allocator, base_pwd, target);
    defer if (logical_target) |path| buffers.allocator.free(path);
    const change_target = logical_target orelse target;
    if (old_pwd.len != 0 and shell_state.isVariableReadonly("OLDPWD")) {
        return builtinStatusError(buffers, 1, "cd", "OLDPWD: readonly variable");
    }
    if (shell_state.isVariableReadonly("PWD")) {
        return builtinStatusError(buffers, 1, "cd", "PWD: readonly variable");
    }
    fs_port.changeCwd(runtime.fs.ChangeCwdRequest.init(change_target)) catch return builtinStatusError(
        buffers,
        1,
        "cd",
        "could not change directory",
    );
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = fs_port.getCwd(runtime.fs.GetCwdRequest.init(&buffer)) catch return builtinStatusError(
        buffers,
        1,
        "cd",
        "could not get current directory",
    );
    const new_pwd = if (physical) cwd.path else logical_target.?;
    if (old_pwd.len != 0) try state_delta.assignVariable("OLDPWD", old_pwd, .{ .exported = true });
    try state_delta.assignVariable("PWD", new_pwd, .{ .exported = true });
    try state_delta.setLogicalCwd(new_pwd);
    if (print_new_directory) try buffers.stdout.print(buffers.allocator, "{s}\n", .{new_pwd});
    return 0;
}

fn resolveLogicalCdPath(allocator: std.mem.Allocator, base_pwd: []const u8, target: []const u8) ![]u8 {
    std.debug.assert(base_pwd.len != 0);
    std.debug.assert(target.len != 0);
    if (std.fs.path.isAbsolute(target)) return std.fs.path.resolvePosix(allocator, &.{target});
    return std.fs.path.resolvePosix(allocator, &.{ base_pwd, target });
}

fn shouldSearchCdpath(directory: []const u8) bool {
    if (directory.len == 0) return false;
    if (std.fs.path.isAbsolute(directory)) return false;
    if (std.mem.eql(u8, directory, ".") or std.mem.eql(u8, directory, "..")) return false;
    if (std.mem.startsWith(u8, directory, "./") or std.mem.startsWith(u8, directory, "../")) return false;
    return true;
}

fn canChangeDirectory(fs_port: runtime.fs.Port, path: []const u8) bool {
    _ = fs_port.inspectPath(runtime.fs.InspectPathRequest.init(path)) catch return false;
    return true;
}

fn evaluateTimes(
    evaluator: *Evaluator,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "times"));
    if (argv.len > 1) return builtinUsageError(buffers, "times", "too many arguments");

    const process_port = evaluator.process_port orelse return error.Unimplemented;
    const times = process_port.getTimes() catch return error.Unimplemented;
    try printProcessTime(buffers.allocator, &buffers.stdout, times.shell_user);
    try buffers.stdout.append(buffers.allocator, ' ');
    try printProcessTime(buffers.allocator, &buffers.stdout, times.shell_system);
    try buffers.stdout.append(buffers.allocator, '\n');
    try printProcessTime(buffers.allocator, &buffers.stdout, times.children_user);
    try buffers.stdout.append(buffers.allocator, ' ');
    try printProcessTime(buffers.allocator, &buffers.stdout, times.children_system);
    try buffers.stdout.append(buffers.allocator, '\n');
    return 0;
}

fn printProcessTime(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    duration: runtime.process.CpuDuration,
) !void {
    const total_centiseconds = duration.microseconds / 10_000;
    const total_seconds = total_centiseconds / 100;
    try stdout.print(allocator, "{d}m{d}.{d:0>2}s", .{
        total_seconds / 60,
        total_seconds % 60,
        total_centiseconds % 100,
    });
}

const UlimitTarget = enum {
    soft,
    hard,
};

const UlimitOptions = struct {
    target: UlimitTarget = .soft,
    resource: runtime.process.ResourceLimitResource = .file_size,
    operand: ?[]const u8 = null,
};

fn evaluateUlimit(
    evaluator: *Evaluator,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "ulimit"));
    const options = parseUlimitOptions(argv) orelse return builtinUsageError(buffers, "ulimit", "unsupported option");

    const process_port = evaluator.process_port orelse return error.Unimplemented;
    var current = process_port.getResourceLimit(.{ .resource = options.resource }) catch |err| switch (err) {
        error.OperationUnsupported => return error.Unimplemented,
        else => return builtinStatusError(buffers, 1, "ulimit", "could not read resource limit"),
    };
    if (options.operand == null) {
        try printUlimitValue(buffers.allocator, &buffers.stdout, ulimitTargetValue(current.limits, options.target));
        return 0;
    }

    const value = parseUlimitValue(options.operand.?) orelse {
        return builtinUsageError(buffers, "ulimit", "invalid limit");
    };
    switch (options.target) {
        .soft => current.limits.soft = value,
        .hard => current.limits.hard = value,
    }
    process_port.setResourceLimit(.{
        .resource = options.resource,
        .limits = current.limits,
    }) catch |err| switch (err) {
        error.OperationUnsupported => return error.Unimplemented,
        error.PermissionDenied => return builtinStatusError(buffers, 1, "ulimit", "permission denied"),
        error.LimitTooBig => return builtinUsageError(buffers, "ulimit", "limit too big"),
        error.Unexpected => return builtinStatusError(buffers, 1, "ulimit", "could not set resource limit"),
    };
    return 0;
}

fn parseUlimitOptions(argv: []const []const u8) ?UlimitOptions {
    var options: UlimitOptions = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) break;
        for (arg[1..]) |option| switch (option) {
            'f' => options.resource = .file_size,
            'S' => options.target = .soft,
            'H' => options.target = .hard,
            else => return null,
        };
    }
    if (index < argv.len) {
        options.operand = argv[index];
        index += 1;
    }
    if (index != argv.len) return null;
    return options;
}

fn ulimitTargetValue(limits: runtime.process.ResourceLimits, target: UlimitTarget) runtime.process.ResourceLimitValue {
    limits.validate();
    return switch (target) {
        .soft => limits.soft,
        .hard => limits.hard,
    };
}

fn parseUlimitValue(raw: []const u8) ?runtime.process.ResourceLimitValue {
    if (std.mem.eql(u8, raw, "unlimited")) return .unlimited;
    const blocks = std.fmt.parseInt(u64, raw, 10) catch return null;
    const bytes = std.math.mul(u64, blocks, 512) catch return null;
    return .{ .bytes = bytes };
}

fn printUlimitValue(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    value: runtime.process.ResourceLimitValue,
) !void {
    switch (value) {
        .unlimited => try stdout.appendSlice(allocator, "unlimited\n"),
        .bytes => |bytes| try stdout.print(allocator, "{d}\n", .{bytes / 512}),
    }
}

fn evaluateUmask(
    evaluator: *Evaluator,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "umask"));
    var index: usize = 1;
    var symbolic = false;
    if (index < argv.len and std.mem.eql(u8, argv[index], "-S")) {
        symbolic = true;
        index += 1;
    }
    if (index < argv.len and std.mem.eql(u8, argv[index], "--")) index += 1;
    if (argv.len > index + 1) return builtinUsageError(buffers, "umask", "too many arguments");
    if (index < argv.len and std.mem.startsWith(u8, argv[index], "-") and !std.mem.eql(u8, argv[index], "-")) {
        return builtinUsageError(buffers, "umask", "unsupported option");
    }

    const fs_port = evaluator.fs_port orelse return error.Unimplemented;
    if (index >= argv.len) {
        const previous = fs_port.setFileCreationMask(.{ .mask = 0 }) catch {
            return builtinStatusError(buffers, 1, "umask", "could not read file creation mask");
        };
        _ = fs_port.setFileCreationMask(.{ .mask = previous.previous }) catch {
            return builtinStatusError(buffers, 1, "umask", "could not restore file creation mask");
        };
        if (symbolic) {
            try printSymbolicUmask(buffers.allocator, &buffers.stdout, previous.previous);
        } else {
            try printUmask(buffers.allocator, &buffers.stdout, previous.previous);
        }
        return 0;
    }

    const current_mask = currentFileCreationMask(fs_port) orelse {
        return builtinStatusError(buffers, 1, "umask", "could not read file creation mask");
    };
    const mask = parseUmaskOperand(argv[index], current_mask) orelse {
        return builtinUsageError(buffers, "umask", "invalid mask");
    };
    _ = fs_port.setFileCreationMask(.{ .mask = mask }) catch {
        return builtinStatusError(buffers, 1, "umask", "could not set file creation mask");
    };
    return 0;
}

fn currentFileCreationMask(fs_port: runtime.fs.Port) ?runtime.fs.FileCreationMask {
    const previous = fs_port.setFileCreationMask(.{ .mask = 0 }) catch return null;
    _ = fs_port.setFileCreationMask(.{ .mask = previous.previous }) catch return null;
    return previous.previous;
}

fn parseUmaskOperand(operand: []const u8, current_mask: runtime.fs.FileCreationMask) ?runtime.fs.FileCreationMask {
    if (operand.len == 0) return null;
    if (std.mem.indexOfAny(u8, operand, "+-=") == null) return parseOctalUmaskOperand(operand);
    return parseSymbolicUmaskOperand(operand, current_mask);
}

fn parseOctalUmaskOperand(operand: []const u8) ?runtime.fs.FileCreationMask {
    for (operand) |byte| if (byte < '0' or byte > '7') return null;
    const mask = std.fmt.parseInt(runtime.fs.FileCreationMask, operand, 8) catch return null;
    if (mask > 0o777) return null;
    return mask;
}

fn parseSymbolicUmaskOperand(
    operand: []const u8,
    current_mask: runtime.fs.FileCreationMask,
) ?runtime.fs.FileCreationMask {
    var mode: runtime.fs.FileCreationMask = (~current_mask) & 0o777;
    var clauses = std.mem.splitScalar(u8, operand, ',');
    while (clauses.next()) |clause| {
        if (clause.len == 0) return null;
        const parsed = parseSymbolicUmaskClause(clause) orelse return null;
        switch (parsed.operator) {
            '+' => mode |= parsed.permissions,
            '-' => mode &= ~parsed.permissions,
            '=' => mode = (mode & ~parsed.who_mask) | parsed.permissions,
            else => unreachable,
        }
        mode &= 0o777;
    }
    return (~mode) & 0o777;
}

const SymbolicUmaskClause = struct {
    operator: u8,
    who_mask: runtime.fs.FileCreationMask,
    permissions: runtime.fs.FileCreationMask,
};

fn parseSymbolicUmaskClause(clause: []const u8) ?SymbolicUmaskClause {
    var index: usize = 0;
    var who_mask: runtime.fs.FileCreationMask = 0;
    while (index < clause.len) : (index += 1) {
        switch (clause[index]) {
            'u' => who_mask |= 0o700,
            'g' => who_mask |= 0o070,
            'o' => who_mask |= 0o007,
            'a' => who_mask |= 0o777,
            '+', '-', '=' => break,
            else => return null,
        }
    }
    if (index >= clause.len) return null;
    if (who_mask == 0) who_mask = 0o777;
    const operator = clause[index];
    index += 1;

    var permissions: runtime.fs.FileCreationMask = 0;
    while (index < clause.len) : (index += 1) {
        switch (clause[index]) {
            'r' => permissions |= symbolicUmaskPermission(who_mask, 0o400, 0o040, 0o004),
            'w' => permissions |= symbolicUmaskPermission(who_mask, 0o200, 0o020, 0o002),
            'x' => permissions |= symbolicUmaskPermission(who_mask, 0o100, 0o010, 0o001),
            else => return null,
        }
    }
    return .{ .operator = operator, .who_mask = who_mask, .permissions = permissions };
}

fn symbolicUmaskPermission(
    who_mask: runtime.fs.FileCreationMask,
    user: runtime.fs.FileCreationMask,
    group: runtime.fs.FileCreationMask,
    other: runtime.fs.FileCreationMask,
) runtime.fs.FileCreationMask {
    var permissions: runtime.fs.FileCreationMask = 0;
    if (who_mask & 0o700 != 0) permissions |= user;
    if (who_mask & 0o070 != 0) permissions |= group;
    if (who_mask & 0o007 != 0) permissions |= other;
    return permissions;
}

fn printUmask(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    mask: runtime.fs.FileCreationMask,
) !void {
    std.debug.assert(mask <= 0o777);
    const digits = [_]u8{
        '0' + @as(u8, @intCast((mask >> 9) & 0o7)),
        '0' + @as(u8, @intCast((mask >> 6) & 0o7)),
        '0' + @as(u8, @intCast((mask >> 3) & 0o7)),
        '0' + @as(u8, @intCast(mask & 0o7)),
        '\n',
    };
    try stdout.appendSlice(allocator, &digits);
}

fn printSymbolicUmask(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    mask: runtime.fs.FileCreationMask,
) !void {
    std.debug.assert(mask <= 0o777);
    try stdout.print(allocator, "u={s}{s}{s},g={s}{s}{s},o={s}{s}{s}\n", .{
        if (mask & 0o400 == 0) "r" else "",
        if (mask & 0o200 == 0) "w" else "",
        if (mask & 0o100 == 0) "x" else "",
        if (mask & 0o040 == 0) "r" else "",
        if (mask & 0o020 == 0) "w" else "",
        if (mask & 0o010 == 0) "x" else "",
        if (mask & 0o004 == 0) "r" else "",
        if (mask & 0o002 == 0) "w" else "",
        if (mask & 0o001 == 0) "x" else "",
    });
}

fn evaluateHash(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, plan.argv[0], "hash"));
    var index: usize = 1;
    const option_terminated = index < plan.argv.len and std.mem.eql(u8, plan.argv[index], "--");
    if (option_terminated) index += 1;
    if (index >= plan.argv.len) return 0;
    if (!option_terminated and std.mem.eql(u8, plan.argv[index], "-r")) {
        index += 1;
        if (index >= plan.argv.len) return 0;
    } else if (!option_terminated and std.mem.startsWith(u8, plan.argv[index], "-") and !std.mem.eql(
        u8,
        plan.argv[index],
        "-",
    )) {
        return builtinUsageError(buffers, "hash", "unsupported option");
    }

    var status: outcome.ExitStatus = 0;
    for (plan.argv[index..]) |name| {
        const command: command_plan.ExpandedSimpleCommand = .{
            .assignments = plan.assignments,
            .argv = &.{name},
            .last_command_substitution_status = plan.last_command_substitution_status,
        };
        const external = try resolveExternalForEvaluation(evaluator.allocator, evaluator.fs_port, shell_state, command);
        defer if (external) |resolution| evaluator.allocator.free(resolution.path);
        if (external == null) {
            const message = try std.fmt.allocPrint(buffers.allocator, "{s}: not found", .{name});
            defer buffers.allocator.free(message);
            try buffers.addBuiltinDiagnostic("hash", message);
            status = 1;
        }
    }
    return status;
}

fn evaluateGetopts(
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "getopts"));
    if (argv.len < 3) return builtinUsageError(buffers, "getopts", "missing operand");
    if (!isShellName(argv[2])) return builtinUsageError(buffers, "getopts", "invalid variable name");
    if (shell_state.isVariableReadonly(argv[2]) or
        shell_state.isVariableReadonly("OPTIND") or
        shell_state.isVariableReadonly("OPTARG")) return builtinUsageError(buffers, "getopts", "readonly variable");

    const optstring = argv[1];
    const silent = optstring.len != 0 and optstring[0] == ':';
    const specs = if (silent) optstring[1..] else optstring;
    const args = if (argv.len > 3) argv[3..] else shell_state.positionals.items;
    const optind = getoptsOptind(shell_state);
    var cursor: state.GetoptsCursor = if (shell_state.getopts_cursor.optind == optind)
        shell_state.getopts_cursor
    else
        .{ .optind = optind, .char_index = 1 };

    while (cursor.optind <= args.len) {
        const arg = args[cursor.optind - 1];
        if (arg.len < 2 or arg[0] != '-') return getoptsEnd(argv[2], cursor.optind, state_delta);
        if (std.mem.eql(u8, arg, "--")) return getoptsEnd(argv[2], cursor.optind + 1, state_delta);
        if (cursor.char_index >= arg.len) {
            cursor.optind += 1;
            cursor.char_index = 1;
            continue;
        }

        const option = arg[cursor.char_index];
        const spec_index = optionSpecIndex(specs, option) orelse {
            return getoptsInvalidOption(argv[2], option, silent, cursor, arg.len, state_delta, buffers);
        };
        if (option == ':' or (spec_index + 1 < specs.len and specs[spec_index + 1] == ':')) {
            return getoptsOptionWithArgument(argv[2], option, silent, cursor, arg, args, state_delta, buffers);
        }
        return getoptsOption(argv[2], option, advanceGetoptsCursor(cursor, arg.len), state_delta);
    }
    return getoptsEnd(argv[2], cursor.optind, state_delta);
}

fn getoptsOptind(shell_state: state.ShellState) usize {
    const value = shell_state.getVariable("OPTIND") orelse return 1;
    const parsed = std.fmt.parseInt(usize, value.value, 10) catch return 1;
    return if (parsed == 0) 1 else parsed;
}

fn optionSpecIndex(specs: []const u8, option: u8) ?usize {
    var index: usize = 0;
    while (index < specs.len) : (index += 1) {
        if (specs[index] == ':') continue;
        if (specs[index] == option) return index;
    }
    return null;
}

fn advanceGetoptsCursor(cursor: state.GetoptsCursor, arg_len: usize) state.GetoptsCursor {
    std.debug.assert(cursor.char_index < arg_len);
    if (cursor.char_index + 1 < arg_len) return .{
        .optind = cursor.optind,
        .char_index = cursor.char_index + 1,
    };
    return .{ .optind = cursor.optind + 1, .char_index = 1 };
}

fn getoptsOption(
    name: []const u8,
    option: u8,
    cursor: state.GetoptsCursor,
    state_delta: *delta.StateDelta,
) !outcome.ExitStatus {
    const value = [_]u8{option};
    try state_delta.assignVariable(name, &value, .{});
    try state_delta.unsetVariable("OPTARG");
    try assignOptind(state_delta, cursor.optind);
    state_delta.setGetoptsCursor(cursor);
    return 0;
}

fn getoptsOptionWithArgument(
    name: []const u8,
    option: u8,
    silent: bool,
    cursor: state.GetoptsCursor,
    arg: []const u8,
    args: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    if (cursor.char_index + 1 < arg.len) {
        const next_cursor: state.GetoptsCursor = .{ .optind = cursor.optind + 1, .char_index = 1 };
        try assignGetoptsResult(name, option, arg[cursor.char_index + 1 ..], next_cursor, state_delta);
        return 0;
    }
    if (cursor.optind < args.len) {
        const next_cursor: state.GetoptsCursor = .{ .optind = cursor.optind + 2, .char_index = 1 };
        try assignGetoptsResult(name, option, args[cursor.optind], next_cursor, state_delta);
        return 0;
    }
    if (silent) {
        const option_value = [_]u8{option};
        try assignGetoptsResult(
            name,
            ':',
            &option_value,
            .{ .optind = cursor.optind + 1, .char_index = 1 },
            state_delta,
        );
        return 0;
    }
    try buffers.addBuiltinDiagnostic("getopts", "option requires an argument");
    return getoptsQuestion(name, .{ .optind = cursor.optind + 1, .char_index = 1 }, state_delta);
}

fn assignGetoptsResult(
    name: []const u8,
    option: u8,
    optarg: []const u8,
    cursor: state.GetoptsCursor,
    state_delta: *delta.StateDelta,
) !void {
    const value = [_]u8{option};
    try state_delta.assignVariable(name, &value, .{});
    try state_delta.assignVariable("OPTARG", optarg, .{});
    try assignOptind(state_delta, cursor.optind);
    state_delta.setGetoptsCursor(cursor);
}

fn getoptsInvalidOption(
    name: []const u8,
    option: u8,
    silent: bool,
    cursor: state.GetoptsCursor,
    arg_len: usize,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    const next_cursor = advanceGetoptsCursor(cursor, arg_len);
    if (silent) {
        const option_value = [_]u8{option};
        try assignGetoptsResult(name, '?', &option_value, next_cursor, state_delta);
        return 0;
    }
    try buffers.addBuiltinDiagnostic("getopts", "invalid option");
    return getoptsQuestion(name, next_cursor, state_delta);
}

fn getoptsQuestion(
    name: []const u8,
    cursor: state.GetoptsCursor,
    state_delta: *delta.StateDelta,
) !outcome.ExitStatus {
    const question = [_]u8{'?'};
    try state_delta.assignVariable(name, &question, .{});
    try state_delta.unsetVariable("OPTARG");
    try assignOptind(state_delta, cursor.optind);
    state_delta.setGetoptsCursor(cursor);
    return 0;
}

fn getoptsEnd(name: []const u8, optind: usize, state_delta: *delta.StateDelta) !outcome.ExitStatus {
    const question = [_]u8{'?'};
    try state_delta.assignVariable(name, &question, .{});
    try state_delta.unsetVariable("OPTARG");
    try assignOptind(state_delta, optind);
    state_delta.setGetoptsCursor(.{ .optind = optind, .char_index = 1 });
    return 1;
}

fn assignOptind(state_delta: *delta.StateDelta, optind: usize) !void {
    const value = try std.fmt.allocPrint(state_delta.allocator, "{d}", .{optind});
    defer state_delta.allocator.free(value);
    try state_delta.assignVariable("OPTIND", value, .{});
}

fn evaluateKill(
    evaluator: *Evaluator,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "kill"));
    if (argv.len == 1) return builtinUsageError(buffers, "kill", "missing operand");

    var signal = signalNumber(.TERM);
    var index: usize = 1;
    if (std.mem.eql(u8, argv[index], "--")) {
        index += 1;
    } else if (std.mem.eql(u8, argv[index], "-l")) {
        return evaluateKillList(argv[index + 1 ..], buffers);
    } else if (std.mem.eql(u8, argv[index], "-s")) {
        if (index + 1 >= argv.len) return builtinUsageError(buffers, "kill", "missing signal");
        signal = parseKillSignal(argv[index + 1]) orelse return builtinUsageError(buffers, "kill", "invalid signal");
        index += 2;
    } else if (std.mem.startsWith(u8, argv[index], "-") and argv[index].len > 1) {
        signal = parseKillSignal(argv[index][1..]) orelse return builtinUsageError(buffers, "kill", "invalid signal");
        index += 1;
    }
    if (index < argv.len and std.mem.eql(u8, argv[index], "--")) index += 1;
    if (index >= argv.len) return builtinUsageError(buffers, "kill", "missing process id");

    const signal_port = evaluator.signal_port orelse return error.Unimplemented;
    var status: outcome.ExitStatus = 0;
    for (argv[index..]) |operand| {
        const process = parseKillProcess(operand) orelse {
            const message = try std.fmt.allocPrint(buffers.allocator, "{s}: invalid process id", .{operand});
            defer buffers.allocator.free(message);
            try buffers.addBuiltinDiagnostic("kill", message);
            status = 1;
            continue;
        };
        signal_port.send(.{ .process = process, .signal = signal }) catch |err| {
            const reason: []const u8 = switch (err) {
                error.ProcessNotFound => "no such process",
                error.PermissionDenied => "permission denied",
                error.Unexpected => "unexpected signal error",
            };
            const message = try std.fmt.allocPrint(buffers.allocator, "{s}: {s}", .{ operand, reason });
            defer buffers.allocator.free(message);
            try buffers.addBuiltinDiagnostic("kill", message);
            status = 1;
        };
    }
    return status;
}

fn evaluateKillList(args: []const []const u8, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    if (args.len > 1) return builtinUsageError(buffers, "kill", "too many arguments");
    if (args.len == 1) {
        const signal = parseKillListStatus(args[0]) orelse return builtinUsageError(buffers, "kill", "invalid signal");
        if (signalName(signal)) |name| {
            const start: usize = if (std.mem.startsWith(u8, name, "SIG")) 3 else 0;
            try buffers.stdout.print(buffers.allocator, "{s}\n", .{name[start..]});
            return 0;
        }
        return builtinUsageError(buffers, "kill", "invalid signal");
    }
    try buffers.stdout.appendSlice(buffers.allocator, "HUP INT QUIT KILL TERM USR1 USR2\n");
    return 0;
}

fn parseKillListStatus(raw: []const u8) ?u8 {
    const parsed = std.fmt.parseInt(u8, raw, 10) catch return parseKillSignal(raw);
    return if (parsed >= 128) parsed - 128 else parsed;
}

fn parseKillSignal(raw: []const u8) ?u8 {
    if (raw.len == 0) return null;
    if (std.fmt.parseInt(u8, raw, 10)) |number| {
        return number;
    } else |_| {}
    const start: usize = if (std.ascii.startsWithIgnoreCase(raw, "SIG") and raw.len > 3) 3 else 0;
    const name = raw[start..];
    if (std.ascii.eqlIgnoreCase(name, "HUP")) return signalNumber(.HUP);
    if (std.ascii.eqlIgnoreCase(name, "INT")) return signalNumber(.INT);
    if (std.ascii.eqlIgnoreCase(name, "QUIT")) return signalNumber(.QUIT);
    if (std.ascii.eqlIgnoreCase(name, "KILL")) return signalNumber(.KILL);
    if (std.ascii.eqlIgnoreCase(name, "TERM")) return signalNumber(.TERM);
    if (std.ascii.eqlIgnoreCase(name, "USR1")) return signalNumber(.USR1);
    if (std.ascii.eqlIgnoreCase(name, "USR2")) return signalNumber(.USR2);
    return null;
}

fn parseKillProcess(raw: []const u8) ?i32 {
    if (raw.len == 0) return null;
    return std.fmt.parseInt(i32, raw, 10) catch null;
}

const FcMode = enum { edit, list, substitute };

const FcOptions = struct {
    mode: FcMode = .edit,
    suppress_numbers: bool = false,
    reverse: bool = false,
    first: ?[]const u8 = null,
    last: ?[]const u8 = null,
    substitution: ?FcSubstitution = null,
};

const FcSubstitution = struct {
    old: []const u8,
    new: []const u8,
};

fn evaluateFc(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "fc"));
    const options = parseFcOptions(argv) orelse return normalEvaluation(try builtinUsageError(
        buffers,
        "fc",
        "unsupported option",
    ));
    if (evaluator.history_entries.len == 0) return normalEvaluation(try builtinStatusError(
        buffers,
        1,
        "fc",
        "history is empty",
    ));

    return switch (options.mode) {
        .list => normalEvaluation(try evaluateFcList(evaluator, options, buffers)),
        .substitute => evaluateFcSubstitute(evaluator, shell_state, eval_context, options, state_delta, buffers),
        .edit => normalEvaluation(try builtinUsageError(buffers, "fc", "editor mode is not implemented")),
    };
}

fn parseFcOptions(argv: []const []const u8) ?FcOptions {
    var options: FcOptions = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) break;
        if (arg.len > 1 and std.ascii.isDigit(arg[1])) break;
        for (arg[1..]) |option| switch (option) {
            'l' => options.mode = .list,
            'n' => options.suppress_numbers = true,
            'r' => options.reverse = true,
            's' => options.mode = .substitute,
            else => return null,
        };
    }

    if (options.mode == .substitute and index < argv.len) {
        if (parseFcSubstitution(argv[index])) |substitution| {
            options.substitution = substitution;
            index += 1;
        }
    }
    if (index < argv.len) {
        options.first = argv[index];
        index += 1;
    }
    if (index < argv.len) {
        options.last = argv[index];
        index += 1;
    }
    if (index != argv.len) return null;
    if (options.mode == .substitute and options.last != null) return null;
    return options;
}

fn parseFcSubstitution(raw: []const u8) ?FcSubstitution {
    const offset = std.mem.indexOfScalar(u8, raw, '=') orelse return null;
    if (offset == 0) return null;
    return .{ .old = raw[0..offset], .new = raw[offset + 1 ..] };
}

fn evaluateFcList(evaluator: *Evaluator, options: FcOptions, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    const range = fcRange(evaluator.history_entries, options.first, options.last, .list) orelse {
        return builtinStatusError(buffers, 1, "fc", "history entry not found");
    };
    if (options.reverse) {
        var index = range.last + 1;
        while (index > range.first) {
            index -= 1;
            try printFcEntry(
                buffers.allocator,
                &buffers.stdout,
                evaluator.history_entries[index],
                options.suppress_numbers,
            );
        }
        return 0;
    }
    for (evaluator.history_entries[range.first .. range.last + 1]) |entry| {
        try printFcEntry(buffers.allocator, &buffers.stdout, entry, options.suppress_numbers);
    }
    return 0;
}

fn evaluateFcSubstitute(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    options: FcOptions,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    const range = fcRange(evaluator.history_entries, options.first, null, .substitute) orelse {
        return normalEvaluation(try builtinStatusError(buffers, 1, "fc", "history entry not found"));
    };
    const entry = evaluator.history_entries[range.first];
    const source = if (options.substitution) |substitution|
        try fcSubstituteCommand(evaluator.allocator, entry.text, substitution)
    else
        try evaluator.allocator.dupe(u8, entry.text);
    defer evaluator.allocator.free(source);

    try buffers.stdout.print(buffers.allocator, "{s}\n", .{source});
    return evaluateSourcedText(evaluator, shell_state, eval_context, source, &.{}, state_delta, buffers);
}

const FcRangeDefault = enum { list, substitute };

const FcRange = struct {
    first: usize,
    last: usize,
};

fn fcRange(
    entries: []const CommandHistoryEntry,
    first_spec: ?[]const u8,
    last_spec: ?[]const u8,
    default_mode: FcRangeDefault,
) ?FcRange {
    if (entries.len == 0) return null;
    const default_first = switch (default_mode) {
        .list => if (entries.len > 16) entries.len - 16 else 0,
        .substitute => entries.len - 1,
    };
    const first = if (first_spec) |spec| fcHistoryIndex(entries, spec) orelse return null else default_first;
    const last = if (last_spec) |spec| fcHistoryIndex(entries, spec) orelse return null else switch (default_mode) {
        .list => entries.len - 1,
        .substitute => first,
    };
    return if (first <= last) .{ .first = first, .last = last } else .{ .first = last, .last = first };
}

fn fcHistoryIndex(entries: []const CommandHistoryEntry, spec: []const u8) ?usize {
    if (spec.len == 0) return null;
    if (std.fmt.parseInt(i64, spec, 10)) |number| {
        if (number > 0) {
            for (entries, 0..) |entry, index| if (entry.number == number) return index;
            return null;
        }
        if (number < 0) {
            const offset: usize = @intCast(-number);
            if (offset == 0 or offset > entries.len) return null;
            return entries.len - offset;
        }
        return null;
    } else |_| {}

    var index = entries.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.startsWith(u8, entries[index].text, spec)) return index;
    }
    return null;
}

fn printFcEntry(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    entry: CommandHistoryEntry,
    suppress_numbers: bool,
) !void {
    entry.validate();
    if (suppress_numbers) {
        try stdout.print(allocator, "{s}\n", .{entry.text});
    } else {
        try stdout.print(allocator, "{d}\t{s}\n", .{ entry.number, entry.text });
    }
}

fn fcSubstituteCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    substitution: FcSubstitution,
) ![]const u8 {
    const offset = std.mem.indexOf(u8, command, substitution.old) orelse return allocator.dupe(u8, command);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, command[0..offset]);
    try result.appendSlice(allocator, substitution.new);
    try result.appendSlice(allocator, command[offset + substitution.old.len ..]);
    return result.toOwnedSlice(allocator);
}

fn evaluateCommandBuiltin(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    const argv = plan.argv;
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "command"));
    var index: usize = 1;
    var use_default_path = false;
    var lookup_format: ?CommandLookupFormat = null;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-p")) {
            use_default_path = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            lookup_format = .terse;
        } else if (std.mem.eql(u8, arg, "-V")) {
            lookup_format = .verbose;
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            return normalEvaluation(try builtinUsageError(buffers, "command", "unsupported arguments"));
        } else {
            break;
        }
    }
    if (index >= argv.len) return normalEvaluation(0);
    if (lookup_format) |format| {
        if (argv.len != index + 1) {
            return normalEvaluation(try builtinUsageError(buffers, "command", "too many arguments"));
        }
        return evaluateCommandLookup(evaluator, shell_state, plan, argv[index], format, use_default_path, buffers);
    }

    var lookup_state = if (use_default_path) shell_state.clone(evaluator.allocator) catch |err| switch (err) {
        error.ReadonlyVariable => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    } else shell_state;
    defer if (use_default_path) lookup_state.deinit();
    if (use_default_path) {
        lookup_state.putVariable("PATH", default_command_path, .{ .exported = true }) catch |err| switch (err) {
            error.ReadonlyVariable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    const command: command_plan.ExpandedSimpleCommand = .{
        .assignments = plan.assignments,
        .argv = argv[index..],
        .last_command_substitution_status = plan.last_command_substitution_status,
    };
    const lookup_command = if (use_default_path) command_plan.ExpandedSimpleCommand{
        .argv = command.argv,
        .last_command_substitution_status = command.last_command_substitution_status,
    } else command;
    const external = try resolveExternalForEvaluation(
        evaluator.allocator,
        evaluator.fs_port,
        lookup_state,
        lookup_command,
    );
    defer if (external) |resolution| evaluator.allocator.free(resolution.path);
    const externals: []const command_plan.ExternalResolution = if (external) |*resolution| &.{resolution.*} else &.{};
    const target_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = command,
        .lookup = .{ .functions = &.{}, .externals = externals },
        .target = eval_context.target,
    });
    var dispatch_state = shell_state;
    return evaluateSimpleCommand(evaluator, &dispatch_state, eval_context, target_plan, state_delta, buffers);
}

const default_command_path = "/bin:/usr/bin";

const CommandLookupFormat = enum { terse, verbose };

fn evaluateCommandLookup(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
    name: []const u8,
    format: CommandLookupFormat,
    use_default_path: bool,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    if (isAliasName(name)) {
        if (shell_state.getAlias(name)) |alias| {
            switch (format) {
                .terse => {
                    try buffers.stdout.print(buffers.allocator, "alias {s}=", .{name});
                    try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, alias.value);
                    try buffers.stdout.append(buffers.allocator, '\n');
                },
                .verbose => try buffers.stdout.print(
                    buffers.allocator,
                    "{s} is an alias for {s}\n",
                    .{ name, alias.value },
                ),
            }
            return normalEvaluation(0);
        }
    }

    if (parser.isAliasReservedWord(name)) {
        switch (format) {
            .terse => try buffers.stdout.print(buffers.allocator, "{s}\n", .{name}),
            .verbose => try buffers.stdout.print(buffers.allocator, "{s} is a shell keyword\n", .{name}),
        }
        return normalEvaluation(0);
    }

    if (isShellName(name) and shell_state.getFunction(name) != null) {
        switch (format) {
            .terse => try buffers.stdout.print(buffers.allocator, "{s}\n", .{name}),
            .verbose => try buffers.stdout.print(buffers.allocator, "{s} is a shell function\n", .{name}),
        }
        return normalEvaluation(0);
    }

    if (evaluator.builtinDefinition(name)) |definition| {
        switch (format) {
            .terse => try buffers.stdout.print(buffers.allocator, "{s}\n", .{name}),
            .verbose => try buffers.stdout.print(buffers.allocator, "{s} is a shell builtin\n", .{definition.name}),
        }
        return normalEvaluation(0);
    }

    if (std.mem.findScalar(u8, name, '/') != null) {
        const port = evaluator.fs_port orelse return normalEvaluation(1);
        if (externalCandidate(port, name) != .executable) return normalEvaluation(1);
        switch (format) {
            .terse => try buffers.stdout.print(buffers.allocator, "{s}\n", .{name}),
            .verbose => try buffers.stdout.print(buffers.allocator, "{s} is {s}\n", .{ name, name }),
        }
        return normalEvaluation(0);
    }

    var lookup_state = if (use_default_path) shell_state.clone(evaluator.allocator) catch |err| switch (err) {
        error.ReadonlyVariable => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    } else shell_state;
    defer if (use_default_path) lookup_state.deinit();
    if (use_default_path) {
        lookup_state.putVariable("PATH", default_command_path, .{ .exported = true }) catch |err| switch (err) {
            error.ReadonlyVariable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    const command: command_plan.ExpandedSimpleCommand = .{
        .assignments = plan.assignments,
        .argv = &.{name},
        .last_command_substitution_status = plan.last_command_substitution_status,
    };
    const lookup_command = if (use_default_path) command_plan.ExpandedSimpleCommand{
        .argv = command.argv,
        .last_command_substitution_status = command.last_command_substitution_status,
    } else command;
    const external = try resolveExternalForEvaluation(
        evaluator.allocator,
        evaluator.fs_port,
        lookup_state,
        lookup_command,
    );
    defer if (external) |resolution| evaluator.allocator.free(resolution.path);
    if (external) |resolution| {
        switch (format) {
            .terse => try buffers.stdout.print(buffers.allocator, "{s}\n", .{resolution.path}),
            .verbose => try buffers.stdout.print(buffers.allocator, "{s} is {s}\n", .{ name, resolution.path }),
        }
        return normalEvaluation(0);
    }

    return normalEvaluation(1);
}

pub fn resolveExternalForEvaluation(
    allocator: std.mem.Allocator,
    fs_port: ?runtime.fs.Port,
    shell_state: state.ShellState,
    command: command_plan.ExpandedSimpleCommand,
) !?command_plan.ExternalResolution {
    command.validate();
    if (command.argv.len == 0) return null;
    const name = command.argv[0];
    if (name.len == 0) return null;
    if (std.mem.findScalar(u8, name, '/') != null) {
        return .{ .name = name, .path = try allocator.dupe(u8, name) };
    }

    const port = fs_port orelse return null;
    const path_value = commandLookupPath(shell_state, command) orelse return null;
    var first_found: ?[]const u8 = null;
    errdefer if (first_found) |path| allocator.free(path);
    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |part| {
        const dir = if (part.len == 0) "." else part;
        const candidate = try std.mem.concat(allocator, u8, &.{ dir, "/", name });
        errdefer allocator.free(candidate);
        switch (externalCandidate(port, candidate)) {
            .missing => allocator.free(candidate),
            .found_not_executable => {
                if (first_found == null) {
                    first_found = candidate;
                } else {
                    allocator.free(candidate);
                }
            },
            .executable => {
                if (first_found) |path| allocator.free(path);
                return .{ .name = name, .path = candidate };
            },
        }
    }
    if (first_found) |path| {
        first_found = null;
        return .{ .name = name, .path = path };
    }
    return null;
}

fn resolveExternalForEnvEvaluation(
    allocator: std.mem.Allocator,
    fs_port: ?runtime.fs.Port,
    shell_state: state.ShellState,
    command: command_plan.ExpandedSimpleCommand,
    process_overlay: []const assignment_runtime.ProcessEnvironmentEntry,
) !?command_plan.ExternalResolution {
    command.validate();
    if (command.argv.len == 0) return null;
    const name = command.argv[0];
    if (name.len == 0) return null;
    if (std.mem.findScalar(u8, name, '/') != null) {
        return .{ .name = name, .path = try allocator.dupe(u8, name) };
    }

    const port = fs_port orelse return null;
    const path_value = processOverlayValue(process_overlay, "PATH") orelse
        commandLookupPath(shell_state, command) orelse return null;
    var first_found: ?[]const u8 = null;
    errdefer if (first_found) |path| allocator.free(path);
    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |part| {
        const dir = if (part.len == 0) "." else part;
        const candidate = try std.mem.concat(allocator, u8, &.{ dir, "/", name });
        errdefer allocator.free(candidate);
        switch (externalCandidate(port, candidate)) {
            .missing => allocator.free(candidate),
            .found_not_executable => {
                if (first_found == null) {
                    first_found = candidate;
                } else {
                    allocator.free(candidate);
                }
            },
            .executable => {
                if (first_found) |path| allocator.free(path);
                return .{ .name = name, .path = candidate };
            },
        }
    }
    if (first_found) |path| {
        first_found = null;
        return .{ .name = name, .path = path };
    }
    return null;
}

fn processOverlayValue(
    process_overlay: []const assignment_runtime.ProcessEnvironmentEntry,
    name: []const u8,
) ?[]const u8 {
    var value: ?[]const u8 = null;
    for (process_overlay) |entry| {
        entry.validate();
        if (std.mem.eql(u8, entry.name, name)) value = entry.value;
    }
    return value;
}

fn resolveAllExternalsForEvaluation(
    allocator: std.mem.Allocator,
    fs_port: ?runtime.fs.Port,
    shell_state: state.ShellState,
    command: command_plan.ExpandedSimpleCommand,
) ![]command_plan.ExternalResolution {
    command.validate();
    if (command.argv.len == 0) return allocator.dupe(command_plan.ExternalResolution, &.{});
    const name = command.argv[0];
    if (name.len == 0) return allocator.dupe(command_plan.ExternalResolution, &.{});
    if (std.mem.findScalar(u8, name, '/') != null) {
        const owned_path = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_path);
        return allocator.dupe(command_plan.ExternalResolution, &.{.{ .name = name, .path = owned_path }});
    }

    const port = fs_port orelse return allocator.dupe(command_plan.ExternalResolution, &.{});
    const path_value = commandLookupPath(shell_state, command) orelse return allocator.dupe(
        command_plan.ExternalResolution,
        &.{},
    );
    var resolutions: std.ArrayList(command_plan.ExternalResolution) = .empty;
    errdefer {
        for (resolutions.items) |resolution| allocator.free(resolution.path);
        resolutions.deinit(allocator);
    }
    var first_found_not_executable: ?[]const u8 = null;
    errdefer if (first_found_not_executable) |path| allocator.free(path);
    var parts = std.mem.splitScalar(u8, path_value, ':');
    while (parts.next()) |part| {
        const dir = if (part.len == 0) "." else part;
        const candidate = try std.mem.concat(allocator, u8, &.{ dir, "/", name });
        errdefer allocator.free(candidate);
        switch (externalCandidate(port, candidate)) {
            .missing => allocator.free(candidate),
            .found_not_executable => {
                if (first_found_not_executable == null) {
                    first_found_not_executable = candidate;
                } else {
                    allocator.free(candidate);
                }
            },
            .executable => try resolutions.append(allocator, .{ .name = name, .path = candidate }),
        }
    }
    if (resolutions.items.len == 0) {
        if (first_found_not_executable) |path| {
            first_found_not_executable = null;
            try resolutions.append(allocator, .{ .name = name, .path = path });
        }
    }
    return resolutions.toOwnedSlice(allocator);
}

const LoopControlKind = enum { break_loop, continue_loop };

fn evaluateLoopControl(
    eval_context: context.EvalContext,
    argv: []const []const u8,
    kind: LoopControlKind,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    std.debug.assert(argv.len != 0);
    const command = switch (kind) {
        .break_loop => "break",
        .continue_loop => "continue",
    };
    std.debug.assert(std.mem.eql(u8, argv[0], command));

    if (!eval_context.canBreakOrContinue(1)) return normalEvaluation(0);
    if (argv.len > 2) return normalEvaluation(try builtinUsageError(buffers, command, "too many arguments"));
    const requested_depth: u32 = if (argv.len == 2) blk: {
        const operand = std.mem.trim(u8, argv[1], &std.ascii.whitespace);
        const parsed = std.fmt.parseInt(u32, operand, 10) catch return normalEvaluation(try builtinUsageError(
            buffers,
            command,
            "numeric argument required",
        ));
        if (parsed == 0) return normalEvaluation(try builtinUsageError(buffers, command, "loop count out of range"));
        break :blk parsed;
    } else 1;
    const effective_depth = if (requested_depth > eval_context.loop_depth) eval_context.loop_depth else requested_depth;
    std.debug.assert(effective_depth != 0);
    return switch (kind) {
        .break_loop => .{ .status = 0, .control_flow = .{ .break_loop = effective_depth } },
        .continue_loop => .{ .status = 0, .control_flow = .{ .continue_loop = effective_depth } },
    };
}

fn evaluateExit(
    shell_state: state.ShellState,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !SimpleEvalResult {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "exit"));
    if (argv.len > 2) return normalEvaluation(try builtinUsageError(buffers, "exit", "too many arguments"));
    const status: outcome.ExitStatus = if (argv.len == 2) blk: {
        const operand = std.mem.trim(u8, argv[1], &std.ascii.whitespace);
        const parsed = std.fmt.parseInt(u64, operand, 10) catch {
            _ = try builtinUsageError(buffers, "exit", "numeric argument required");
            return .{ .status = 2, .control_flow = .{ .exit = 2 } };
        };
        break :blk @truncate(parsed);
    } else shell_state.last_status;
    return .{ .status = status, .control_flow = .{ .exit = status } };
}

fn evaluateExec(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) EvalError!SimpleEvalResult {
    const argv = plan.argv;
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "exec"));
    var index: usize = 1;
    if (index < argv.len and std.mem.eql(u8, argv[index], "--")) index += 1;
    if (index >= argv.len) return normalEvaluation(0);
    if (std.mem.startsWith(u8, argv[index], "-")) {
        return normalEvaluation(try builtinUsageError(buffers, "exec", "unsupported option"));
    }

    const command: command_plan.ExpandedSimpleCommand = .{
        .assignments = plan.assignments,
        .argv = argv[index..],
        .last_command_substitution_status = plan.last_command_substitution_status,
        .source_line = plan.source_line,
    };
    const external = try resolveExternalForEvaluation(evaluator.allocator, evaluator.fs_port, shell_state, command);
    defer if (external) |resolution| evaluator.allocator.free(resolution.path);
    const resolution = external orelse {
        const status = try evaluateNotFound(evaluator, .{ .name = command.argv[0] }, command.source_line, buffers);
        return .{ .status = status, .control_flow = .{ .exit = status } };
    };
    const target_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = command,
        .lookup = .{ .externals = &.{resolution} },
        .target = .child_process,
    });
    const status = if (externalNeedsBufferedStdin(target_plan, buffers))
        try runExternalWithPipelineInput(
            evaluator,
            shell_state,
            context.EvalContext.forTarget(.current_shell),
            target_plan,
            resolution,
            buffers,
        )
    else
        try evaluateExternal(
            evaluator,
            shell_state,
            context.EvalContext.forTarget(.current_shell),
            target_plan,
            resolution,
            buffers,
        );
    try state_delta.setTrap(state.TrapSignal.EXIT.name(), null);
    return .{ .status = status, .control_flow = .{ .exit = status } };
}

fn appendBuiltinDiagnostic(
    command_outcome: *outcome.CommandOutcome,
    plan: command_plan.CommandPlan,
    status: outcome.ExitStatus,
) !void {
    if (status != 2 or plan.argv.len == 0) return;
    if (std.mem.eql(u8, plan.argv[0], "[")) {
        const args = plan.argv[1..];
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            try command_outcome.addDiagnostic("[: missing ]");
            return;
        }
        try command_outcome.addDiagnostic("[: invalid expression");
        return;
    }
    if (std.mem.eql(u8, plan.argv[0], "test")) try command_outcome.addDiagnostic("test: invalid expression");
}

fn evaluateExport(
    shell_state: state.ShellState,
    features: compat.Features,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "export"));

    var index: usize = 1;
    const option_terminated = index < argv.len and std.mem.eql(u8, argv[index], "--");
    if (option_terminated) index += 1;
    if (index >= argv.len) return listVariableDeclarations(shell_state, state_delta.*, buffers, .exported, "export");
    if (!option_terminated and std.mem.eql(u8, argv[index], "-p")) {
        if (argv.len != index + 1) return builtinUsageError(buffers, "export", "too many arguments");
        return listVariableDeclarations(shell_state, state_delta.*, buffers, .exported, "export");
    }
    if (!option_terminated and std.mem.startsWith(u8, argv[index], "-") and !std.mem.eql(
        u8,
        argv[index],
        "-",
    )) return builtinUsageError(
        buffers,
        "export",
        "unsupported option",
    );

    if (!features.isBash()) for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        const name = assignment.name;
        if (!isShellName(name)) return builtinUsageError(buffers, "export", "invalid variable name");
        if (assignment.value) |_| {
            if (shell_state.isVariableReadonly(name)) return builtinUsageError(buffers, "export", "readonly variable");
        }
    };

    var status: outcome.ExitStatus = 0;
    for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        if (!isShellName(assignment.name)) {
            status = try builtinStatusError(buffers, 1, "export", "invalid variable name");
            continue;
        }
        if (assignment.value) |value| {
            if (shell_state.isVariableReadonly(assignment.name)) {
                status = try builtinStatusError(buffers, 1, "export", "readonly variable");
                continue;
            }
            try state_delta.assignVariable(assignment.name, value, .{ .exported = true });
        } else {
            try state_delta.setVariableExported(assignment.name, true);
        }
    }
    return status;
}

fn evaluateReadonly(
    shell_state: state.ShellState,
    features: compat.Features,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "readonly"));

    var index: usize = 1;
    const option_terminated = index < argv.len and std.mem.eql(u8, argv[index], "--");
    if (option_terminated) index += 1;
    if (index >= argv.len) return listVariableDeclarations(shell_state, state_delta.*, buffers, .readonly, "readonly");
    if (!option_terminated and std.mem.eql(u8, argv[index], "-p")) {
        if (argv.len != index + 1) return builtinUsageError(buffers, "readonly", "too many arguments");
        return listVariableDeclarations(shell_state, state_delta.*, buffers, .readonly, "readonly");
    }
    if (!option_terminated and std.mem.startsWith(u8, argv[index], "-") and !std.mem.eql(
        u8,
        argv[index],
        "-",
    )) return builtinUsageError(
        buffers,
        "readonly",
        "unsupported option",
    );

    if (!features.isBash()) for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        const name = assignment.name;
        if (!isShellName(name)) return builtinUsageError(buffers, "readonly", "invalid variable name");
        if (assignment.value != null and (shell_state.isVariableReadonly(name) or
            stateDeltaMarksVariableReadonly(state_delta.*, name)))
        {
            return builtinStatusError(buffers, 1, "readonly", "readonly variable");
        }
    };

    var status: outcome.ExitStatus = 0;
    for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        const name = assignment.name;
        if (!isShellName(name)) {
            status = try builtinStatusError(buffers, 1, "readonly", "invalid variable name");
            continue;
        }
        if (assignment.value != null and (shell_state.isVariableReadonly(name) or
            stateDeltaMarksVariableReadonly(state_delta.*, name)))
        {
            status = try builtinStatusError(buffers, 1, "readonly", "readonly variable");
            continue;
        }
        if (assignment.value) |value| {
            try state_delta.assignVariable(assignment.name, value, .{ .readonly = true });
        } else {
            try state_delta.setVariableReadonly(assignment.name);
        }
    }
    return status;
}

fn stateDeltaMarksVariableReadonly(state_delta: delta.StateDelta, name: []const u8) bool {
    std.debug.assert(state_delta.state == .pending);
    state.assertValidVariableName(name);
    for (state_delta.variable_assignments.items) |assignment| {
        if (std.mem.eql(u8, assignment.name, name) and assignment.readonly) return true;
    }
    for (state_delta.variable_flags.items) |mutation| {
        if (std.mem.eql(u8, mutation.name, name) and mutation.flag == .readonly and mutation.enabled) return true;
    }
    return false;
}

fn evaluateUnset(
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "unset"));

    var mode: enum { variable, function } = .variable;
    var index: usize = 1;
    while (index < argv.len) {
        const option = argv[index];
        if (std.mem.eql(u8, option, "--")) {
            index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-v")) {
            mode = .variable;
            index += 1;
        } else if (std.mem.eql(u8, option, "-f")) {
            mode = .function;
            index += 1;
        } else if (std.mem.startsWith(u8, option, "-") and !std.mem.eql(u8, option, "-")) {
            return builtinUsageError(buffers, "unset", "unsupported option");
        } else {
            break;
        }
    }

    for (argv[index..]) |arg| {
        if (mode == .variable and !isShellName(arg)) return builtinUsageError(
            buffers,
            "unset",
            "invalid variable name",
        );
        if (mode == .variable and shell_state.isVariableReadonly(arg)) return builtinUsageError(
            buffers,
            "unset",
            "readonly variable",
        );
    }

    for (argv[index..]) |arg| switch (mode) {
        .variable => try state_delta.unsetVariable(arg),
        .function => if (isShellName(arg)) try state_delta.unsetFunction(arg),
    };
    return 0;
}

fn evaluateSet(
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "set"));

    if (argv.len == 1) return listShellVariables(shell_state, state_delta.*, buffers);

    var index: usize = 1;
    var set_positionals = false;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            set_positionals = true;
            break;
        }
        if (std.mem.eql(u8, arg, "-")) {
            try state_delta.setOption(.xtrace, false);
            try state_delta.setOption(.verbose, false);
            index += 1;
            set_positionals = index < argv.len;
            break;
        }
        if (std.mem.eql(u8, arg, "+")) {
            index += 1;
            set_positionals = index < argv.len;
            break;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "+o")) {
            if (index + 1 == argv.len) return printShellOptions(shell_state, state_delta.*, buffers, arg[0] == '+');
            const enabled = arg[0] == '-';
            index += 1;
            if (!try appendShellOptionNameChange(state_delta, argv[index], enabled)) return builtinUsageError(
                buffers,
                "set",
                "unknown option name",
            );
            if (eval_context.interactive) try state_delta.setOption(.noexec, false);
            index += 1;
            continue;
        }
        if (arg.len >= 2 and (arg[0] == '-' or arg[0] == '+')) {
            if (!try appendShellOptionShortChanges(state_delta, arg)) return builtinUsageError(
                buffers,
                "set",
                "unsupported arguments",
            );
            if (eval_context.interactive) try state_delta.setOption(.noexec, false);
            index += 1;
            continue;
        }

        set_positionals = true;
        break;
    }

    if (set_positionals) try state_delta.replacePositionals(argv[index..]);
    return 0;
}

fn evaluateShift(
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "shift"));

    const amount: usize = if (argv.len == 1) 1 else blk: {
        if (argv.len > 2) return builtinUsageError(buffers, "shift", "too many arguments");
        const operand = std.mem.trim(u8, argv[1], &std.ascii.whitespace);
        break :blk std.fmt.parseInt(usize, operand, 10) catch return builtinUsageError(
            buffers,
            "shift",
            "numeric argument required",
        );
    };
    if (amount > shell_state.positionals.items.len) return builtinStatusError(
        buffers,
        1,
        "shift",
        "shift count out of range",
    );
    try state_delta.replacePositionals(shell_state.positionals.items[amount..]);
    return 0;
}

fn evaluateRead(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    const argv = plan.argv;
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "read"));

    var name_index: usize = 1;
    var preserve_backslashes = false;
    var delimiter: u8 = '\n';
    while (name_index < argv.len) {
        if (std.mem.eql(u8, argv[name_index], "-r")) {
            preserve_backslashes = true;
            name_index += 1;
        } else if (std.mem.eql(u8, argv[name_index], "-d")) {
            if (name_index + 1 >= argv.len) return builtinUsageError(buffers, "read", "missing delimiter");
            delimiter = if (argv[name_index + 1].len == 0) 0 else argv[name_index + 1][0];
            name_index += 2;
        } else {
            break;
        }
    }
    if (name_index < argv.len and std.mem.startsWith(u8, argv[name_index], "-") and !std.mem.eql(
        u8,
        argv[name_index],
        "-",
    )) return builtinUsageError(
        buffers,
        "read",
        "unsupported option",
    );
    if (name_index >= argv.len) return builtinUsageError(buffers, "read", "missing variable name");

    for (argv[name_index..]) |name| {
        if (!isShellName(name)) return builtinUsageError(buffers, "read", "invalid variable name");
        if (shell_state.isVariableReadonly(name)) return builtinUsageError(buffers, "read", "readonly variable");
    }

    const ifs = lookupCommandVariableValue(shell_state, plan, "IFS") orelse " \t\n";
    const raw_line = if (preserve_backslashes)
        try readSingleRawReadLine(evaluator, buffers, delimiter)
    else
        null;
    defer if (raw_line) |line| if (line.owned) evaluator.allocator.free(line.bytes);
    const escaped_line = if (preserve_backslashes)
        null
    else
        try readLineWithEscapesProcessed(evaluator, buffers, delimiter);
    defer if (escaped_line) |line| line.deinit(evaluator.allocator);
    const read_line = if (preserve_backslashes)
        if (raw_line) |line| line.bytes else {
            try assignReadFields("", null, argv[name_index..], ifs, state_delta);
            return 1;
        }
    else if (escaped_line) |line| line.bytes else {
        try assignReadFields("", null, argv[name_index..], ifs, state_delta);
        return 1;
    };
    const escaped_separators = if (escaped_line) |line| line.escaped else null;
    try assignReadFields(read_line, escaped_separators, argv[name_index..], ifs, state_delta);
    const complete = if (preserve_backslashes) raw_line.?.delimiter_found else escaped_line.?.delimiter_found;
    return if (complete) 0 else 1;
}

fn lookupCommandVariableValue(
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
    name: []const u8,
) ?[]const u8 {
    plan.validate();
    state.assertValidVariableName(name);
    var value: ?[]const u8 = if (shell_state.getVariable(name)) |variable| variable.value else null;
    for (plan.assignments) |assignment| {
        if (std.mem.eql(u8, assignment.name, name)) value = assignment.value;
    }
    return value;
}

const ReadRawLine = struct {
    bytes: []const u8,
    owned: bool,
    delimiter_found: bool,
};

const ReadLogicalLine = struct {
    bytes: []const u8,
    escaped: []const bool,
    delimiter_found: bool,

    fn deinit(self: ReadLogicalLine, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.escaped);
    }
};

fn readSingleRawReadLine(
    evaluator: *Evaluator,
    buffers: *EvaluationBuffers,
    delimiter: u8,
) !?ReadRawLine {
    if (buffers.stdin.readUntilStatus(delimiter)) |line| {
        return .{ .bytes = line.bytes, .owned = false, .delimiter_found = line.delimiter_found };
    }
    if (buffers.stdin.redirected) return null;
    if (!evaluator.read_stdin_from_fd and !buffers.stdin.fd_redirected) return null;
    const line = try readUntilFromStdinFd(evaluator.allocator, delimiter) orelse return null;
    return .{ .bytes = line.bytes, .owned = true, .delimiter_found = line.delimiter_found };
}

fn readLineWithEscapesProcessed(
    evaluator: *Evaluator,
    buffers: *EvaluationBuffers,
    delimiter: u8,
) !?ReadLogicalLine {
    var logical_line: std.ArrayList(u8) = .empty;
    var escaped: std.ArrayList(bool) = .empty;
    errdefer logical_line.deinit(evaluator.allocator);
    errdefer escaped.deinit(evaluator.allocator);
    var delimiter_found = false;

    while (true) {
        const raw_line = try readSingleRawReadLine(evaluator, buffers, delimiter) orelse {
            if (logical_line.items.len == 0) {
                logical_line.deinit(evaluator.allocator);
                escaped.deinit(evaluator.allocator);
                return null;
            }
            delimiter_found = false;
            break;
        };
        defer if (raw_line.owned) evaluator.allocator.free(raw_line.bytes);
        delimiter_found = raw_line.delimiter_found;

        if (delimiter == '\n' and readLineHasContinuation(raw_line.bytes)) {
            try appendReadEscapedSegment(
                evaluator.allocator,
                &logical_line,
                &escaped,
                raw_line.bytes[0 .. raw_line.bytes.len - 1],
            );
            continue;
        }

        try appendReadEscapedSegment(evaluator.allocator, &logical_line, &escaped, raw_line.bytes);
        break;
    }

    const bytes = try logical_line.toOwnedSlice(evaluator.allocator);
    errdefer evaluator.allocator.free(bytes);
    const escaped_flags = try escaped.toOwnedSlice(evaluator.allocator);
    return .{
        .bytes = bytes,
        .escaped = escaped_flags,
        .delimiter_found = delimiter_found,
    };
}

fn readLineHasContinuation(line: []const u8) bool {
    var backslash_count: usize = 0;
    while (backslash_count < line.len and line[line.len - 1 - backslash_count] == '\\') backslash_count += 1;
    return backslash_count % 2 == 1;
}

fn appendReadEscapedSegment(
    allocator: std.mem.Allocator,
    logical_line: *std.ArrayList(u8),
    escaped: *std.ArrayList(bool),
    line: []const u8,
) !void {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const escaped_byte = line[index] == '\\' and index + 1 < line.len;
        if (escaped_byte) index += 1;
        try logical_line.append(allocator, line[index]);
        try escaped.append(allocator, escaped_byte);
    }
}

const OwnedReadRawLine = struct {
    bytes: []const u8,
    delimiter_found: bool,
};

fn readUntilFromStdinFd(allocator: std.mem.Allocator, delimiter: u8) !?OwnedReadRawLine {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);

    var byte: [1]u8 = undefined;
    while (true) {
        const read_count = std.posix.read(std.Io.File.stdin().handle, &byte) catch |err| switch (err) {
            error.WouldBlock => break,
            else => break,
        };
        if (read_count == 0) break;
        if (byte[0] == delimiter) return .{ .bytes = try line.toOwnedSlice(allocator), .delimiter_found = true };
        try line.append(allocator, byte[0]);
    }

    if (line.items.len == 0) {
        line.deinit(allocator);
        return null;
    }
    return .{ .bytes = try line.toOwnedSlice(allocator), .delimiter_found = false };
}

fn assignReadFields(
    line: []const u8,
    escaped: ?[]const bool,
    names: []const []const u8,
    ifs: []const u8,
    state_delta: *delta.StateDelta,
) !void {
    std.debug.assert(names.len != 0);
    if (escaped) |flags| std.debug.assert(flags.len == line.len);
    if (names.len == 1) {
        const start = skipReadIfsWhitespace(line, escaped, 0, ifs);
        const end = trimReadIfsWhitespaceEnd(line, escaped, start, ifs);
        try state_delta.assignVariable(names[0], line[start..end], .{});
        return;
    }

    var cursor: usize = 0;
    for (names, 0..) |name, index| {
        cursor = skipReadIfsWhitespace(line, escaped, cursor, ifs);
        const start = cursor;
        if (index + 1 == names.len) {
            const end = trimReadLastFieldEnd(line, escaped, start, ifs);
            try state_delta.assignVariable(name, line[start..end], .{});
            return;
        }
        while (cursor < line.len and readIfsSeparatorAt(line, escaped, cursor, ifs) == null) {
            cursor = nextReadCharacterIndex(line, cursor);
        }
        try state_delta.assignVariable(name, line[start..cursor], .{});
        cursor = advanceReadFieldDelimiter(line, escaped, cursor, ifs);
    }
}

const ReadIfsSeparator = struct { width: usize, whitespace: bool };

fn isReadIfsWhitespaceAt(line: []const u8, escaped: ?[]const bool, index: usize, ifs: []const u8) bool {
    return if (readIfsSeparatorAt(line, escaped, index, ifs)) |separator| separator.whitespace else false;
}

fn isIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn readIfsSeparatorAt(line: []const u8, escaped: ?[]const bool, index: usize, ifs: []const u8) ?ReadIfsSeparator {
    std.debug.assert(index < line.len);

    if (isIfsWhitespace(line[index]) and std.mem.indexOfScalar(u8, ifs, line[index]) != null) {
        if (readBytesEscaped(escaped, index, index + 1)) return null;
        return .{ .width = 1, .whitespace = true };
    }

    var ifs_index: usize = 0;
    while (ifs_index < ifs.len) : (ifs_index = nextReadCharacterIndex(ifs, ifs_index)) {
        const ifs_end = nextReadCharacterIndex(ifs, ifs_index);
        const ifs_char = ifs[ifs_index..ifs_end];
        if (ifs_char.len == 1 and isIfsWhitespace(ifs_char[0])) continue;
        const line_end = index + ifs_char.len;
        if (line_end <= line.len and
            !readBytesEscaped(escaped, index, line_end) and
            std.mem.eql(u8, line[index..line_end], ifs_char))
        {
            return .{ .width = ifs_char.len, .whitespace = false };
        }
    }
    return null;
}

fn readBytesEscaped(escaped: ?[]const bool, start: usize, end: usize) bool {
    if (escaped) |flags| {
        std.debug.assert(end <= flags.len);
        for (flags[start..end]) |flag| if (flag) return true;
    }
    return false;
}

fn nextReadCharacterIndex(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    const end = @min(text.len, index + width);
    if (end > index and std.unicode.utf8ValidateSlice(text[index..end])) return end;
    return index + 1;
}

fn previousReadCharacterIndex(text: []const u8, end: usize) usize {
    std.debug.assert(end <= text.len);
    var index: usize = 0;
    var previous: usize = 0;
    while (index < end) {
        previous = index;
        index = nextReadCharacterIndex(text, index);
    }
    return previous;
}

fn skipReadIfsWhitespace(
    line: []const u8,
    escaped: ?[]const bool,
    start: usize,
    ifs: []const u8,
) usize {
    var cursor = start;
    while (cursor < line.len and isReadIfsWhitespaceAt(line, escaped, cursor, ifs)) cursor += 1;
    return cursor;
}

fn advanceReadFieldDelimiter(
    line: []const u8,
    escaped: ?[]const bool,
    start: usize,
    ifs: []const u8,
) usize {
    if (start >= line.len) return start;
    std.debug.assert(readIfsSeparatorAt(line, escaped, start, ifs) != null);

    var cursor = start;
    if (isReadIfsWhitespaceAt(line, escaped, cursor, ifs)) {
        cursor = skipReadIfsWhitespace(line, escaped, cursor, ifs);
        if (cursor < line.len) {
            if (readIfsSeparatorAt(line, escaped, cursor, ifs)) |separator| {
                if (!separator.whitespace) cursor += separator.width;
            }
        }
    } else {
        cursor += readIfsSeparatorAt(line, escaped, cursor, ifs).?.width;
    }
    return skipReadIfsWhitespace(line, escaped, cursor, ifs);
}

fn trimReadIfsWhitespaceEnd(
    line: []const u8,
    escaped: ?[]const bool,
    start: usize,
    ifs: []const u8,
) usize {
    var end = line.len;
    while (end > start) {
        const previous = previousReadCharacterIndex(line, end);
        if (!isReadIfsWhitespaceAt(line, escaped, previous, ifs)) break;
        end = previous;
    }
    return end;
}

fn trimReadLastFieldEnd(line: []const u8, escaped: ?[]const bool, start: usize, ifs: []const u8) usize {
    const end = trimReadIfsWhitespaceEnd(line, escaped, start, ifs);
    if (end <= start) return end;

    const previous = previousReadCharacterIndex(line, end);
    const trailing_separator = readIfsSeparatorAt(line, escaped, previous, ifs) orelse return end;
    if (trailing_separator.whitespace or previous + trailing_separator.width != end) return end;

    var cursor = start;
    while (cursor < previous) {
        if (readIfsSeparatorAt(line, escaped, cursor, ifs)) |separator| {
            if (!separator.whitespace) return end;
            cursor += separator.width;
        } else {
            cursor = nextReadCharacterIndex(line, cursor);
        }
    }
    return previous;
}

const JobPrintMode = enum {
    normal,
    long,
    pids,
};

fn evaluateJobs(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "jobs"));

    var refreshed_state = try refreshedBackgroundJobState(evaluator, shell_state, buffers);
    defer refreshed_state.deinit();

    var mode: JobPrintMode = .normal;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) break;
        if (std.mem.eql(u8, arg, "-l")) {
            mode = .long;
        } else if (std.mem.eql(u8, arg, "-p")) {
            mode = .pids;
        } else {
            try appendJobTableDiff(shell_state, refreshed_state, state_delta);
            return builtinUsageError(buffers, "jobs", "unsupported option");
        }
    }

    var reported_done_ids: std.ArrayList(usize) = .empty;
    defer reported_done_ids.deinit(evaluator.allocator);
    if (index >= argv.len) {
        for (refreshed_state.background_jobs.items) |job| {
            try appendJobLine(evaluator.allocator, &buffers.stdout, refreshed_state, job, mode);
            if (mode != .pids and job.state == .done) try reported_done_ids.append(evaluator.allocator, job.id);
        }
    } else {
        for (argv[index..]) |arg| {
            const job = findBackgroundJobBySpec(refreshed_state, arg) orelse {
                try appendJobTableDiff(shell_state, refreshed_state, state_delta);
                return builtinStatusError(buffers, 127, "jobs", "unknown job");
            };
            try appendJobLine(evaluator.allocator, &buffers.stdout, refreshed_state, job, mode);
            if (mode != .pids and job.state == .done) try reported_done_ids.append(evaluator.allocator, job.id);
        }
    }

    for (reported_done_ids.items) |id| refreshed_state.removeBackgroundJobById(id);
    try appendJobTableDiff(shell_state, refreshed_state, state_delta);
    return 0;
}

fn evaluateWait(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "wait"));
    eval_context.validate();

    var wait_state = shell_state.clone(evaluator.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer wait_state.deinit();

    var status: outcome.ExitStatus = 0;
    if (argv.len == 1) {
        var index: usize = 0;
        while (index < wait_state.background_jobs.items.len) {
            const job = &wait_state.background_jobs.items[index];
            status = try waitBackgroundJobUntilTerminated(evaluator, shell_state, eval_context, state_delta, job);
            if (status > 128) break;
            if (job.state == .done) {
                wait_state.removeBackgroundJobById(job.id);
            } else {
                index += 1;
            }
        }
        try appendJobTableDiff(shell_state, wait_state, state_delta);
        return if (status > 128) status else 0;
    }

    wait_operands: for (argv[1..]) |operand| {
        switch (resolveWaitOperand(wait_state, operand)) {
            .job_id => |job_id| {
                const job = wait_state.findBackgroundJobPtrById(job_id) orelse unreachable;
                status = try waitBackgroundJobUntilTerminated(evaluator, shell_state, eval_context, state_delta, job);
                if (status > 128) break :wait_operands;
                if (job.state == .done) wait_state.removeBackgroundJobById(job_id);
            },
            .unknown => status = 127,
            .invalid => status = try builtinStatusError(buffers, 1, "wait", "not a pid or valid job spec"),
        }
    }

    try appendJobTableDiff(shell_state, wait_state, state_delta);
    return status;
}

fn evaluateBg(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "bg"));
    if (!shell_state.options.enabled(.monitor)) return builtinStatusError(buffers, 1, "bg", "job control disabled");

    var refreshed_state = try refreshedBackgroundJobState(evaluator, shell_state, buffers);
    defer refreshed_state.deinit();

    if (argv.len == 1) {
        const job_id = resolveBackgroundJobOperand(
            refreshed_state,
            null,
        ) catch |err| return backgroundJobResolveStatus(buffers, "bg", err);
        try continueBackgroundJob(evaluator, &refreshed_state, job_id);
        const job = refreshed_state.findBackgroundJobById(job_id) orelse unreachable;
        try buffers.stdout.print(buffers.allocator, "[{d}] {s}\n", .{ job.id, job.command });
    } else {
        for (argv[1..]) |operand| {
            const job_id = resolveBackgroundJobOperand(
                refreshed_state,
                operand,
            ) catch |err| return backgroundJobResolveStatus(buffers, "bg", err);
            try continueBackgroundJob(evaluator, &refreshed_state, job_id);
            const job = refreshed_state.findBackgroundJobById(job_id) orelse unreachable;
            try buffers.stdout.print(buffers.allocator, "[{d}] {s}\n", .{ job.id, job.command });
        }
    }

    try appendJobTableDiff(shell_state, refreshed_state, state_delta);
    return 0;
}

fn evaluateFg(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "fg"));
    if (argv.len > 2) return builtinUsageError(buffers, "fg", "too many arguments");
    if (!shell_state.options.enabled(.monitor)) return builtinStatusError(buffers, 1, "fg", "job control disabled");

    var refreshed_state = try refreshedBackgroundJobState(evaluator, shell_state, buffers);
    defer refreshed_state.deinit();

    const operand = if (argv.len == 2) argv[1] else null;
    const job_id = resolveBackgroundJobOperand(
        refreshed_state,
        operand,
    ) catch |err| return backgroundJobResolveStatus(buffers, "fg", err);
    const job = refreshed_state.findBackgroundJobPtrById(job_id) orelse unreachable;

    try buffers.stdout.print(buffers.allocator, "{s}\n", .{job.command});

    var restore_process_group: ?runtime.process.ProcessId = null;
    var handed_foreground = false;
    if (job.process_group) |process_group| {
        const process_port = evaluator.process_port orelse return error.Unimplemented;
        const handoff = process_port.foregroundProcessGroup(
            .{ .process_group = process_group },
        ) catch |err| switch (err) {
            error.OperationUnsupported, error.ProcessNotFound => null,
            error.PermissionDenied, error.Unexpected => return builtinStatusError(
                buffers,
                1,
                "fg",
                "foreground handoff failed",
            ),
        };
        if (handoff) |foreground_result| {
            restore_process_group = foreground_result.previous_process_group;
            handed_foreground = true;
        }
    }
    defer if (handed_foreground) {
        const process_port = evaluator.process_port.?;
        _ = process_port.foregroundProcessGroup(.{ .process_group = restore_process_group.? }) catch {};
    };

    try continueJobProcesses(evaluator, job);
    selectBackgroundJob(&refreshed_state, job.id);
    const job_status = try waitForegroundJob(evaluator, job);
    if (job.state == .done) refreshed_state.removeBackgroundJobById(job_id);

    try appendJobTableDiff(shell_state, refreshed_state, state_delta);
    return job_status;
}

const BackgroundJobResolveError = error{
    NoCurrentJob,
    UnknownJob,
};

fn backgroundJobResolveStatus(
    buffers: *EvaluationBuffers,
    command: []const u8,
    err: BackgroundJobResolveError,
) !outcome.ExitStatus {
    return switch (err) {
        error.NoCurrentJob => builtinStatusError(buffers, 1, command, "no current job"),
        error.UnknownJob => builtinStatusError(buffers, 127, command, "unknown job"),
    };
}

fn resolveBackgroundJobOperand(shell_state: state.ShellState, operand: ?[]const u8) BackgroundJobResolveError!usize {
    shell_state.validate();
    const spec = operand orelse "";
    if (spec.len == 0 or std.mem.eql(u8, spec, "%") or std.mem.eql(u8, spec, "%%") or std.mem.eql(u8, spec, "%+")) {
        const id = shell_state.current_job_id orelse return error.NoCurrentJob;
        if (shell_state.findBackgroundJobById(id) != null) return id;
        return error.UnknownJob;
    }
    return (findBackgroundJobBySpec(shell_state, spec) orelse return error.UnknownJob).id;
}

const WaitOperandResolution = union(enum) {
    job_id: usize,
    unknown,
    invalid,
};

fn resolveWaitOperand(shell_state: state.ShellState, operand: []const u8) WaitOperandResolution {
    shell_state.validate();
    if (operand.len == 0) return .invalid;
    if (std.mem.startsWith(u8, operand, "%")) {
        return if (findBackgroundJobBySpec(shell_state, operand)) |job| .{ .job_id = job.id } else .unknown;
    }
    const pid = std.fmt.parseInt(runtime.process.ProcessId, operand, 10) catch return .invalid;
    if (pid <= 0) return .invalid;
    for (shell_state.background_jobs.items) |job| {
        if (job.pid == pid) return .{ .job_id = job.id };
        for (job.processes.items) |process| {
            if (process.child.child.id == pid) return .{ .job_id = job.id };
        }
    }
    return .unknown;
}

fn selectBackgroundJob(shell_state: *state.ShellState, id: usize) void {
    std.debug.assert(shell_state.findBackgroundJobById(id) != null);
    const previous = if (shell_state.current_job_id != null and shell_state.current_job_id.? != id)
        shell_state.current_job_id
    else
        shell_state.previous_job_id;
    shell_state.setJobMarkers(id, previous);
}

fn continueBackgroundJob(evaluator: *Evaluator, shell_state: *state.ShellState, job_id: usize) !void {
    const job = shell_state.findBackgroundJobPtrById(job_id) orelse unreachable;
    try continueJobProcesses(evaluator, job);
    selectBackgroundJob(shell_state, job_id);
}

fn continueJobProcesses(evaluator: *Evaluator, job: *state.BackgroundJob) !void {
    job.validate();
    if (job.state != .stopped) return;
    const process_port = evaluator.process_port orelse return error.Unimplemented;
    const target: runtime.process.ProcessTarget =
        if (job.process_group) |process_group| .{ .process_group = process_group } else .{ .process = job.pid };
    process_port.continueProcess(.{ .target = target }) catch |err| switch (err) {
        error.OperationUnsupported,
        error.ProcessNotFound,
        error.PermissionDenied,
        error.Unexpected,
        => return error.Unimplemented,
    };
    job.state = .running;
    job.status = 0;
    job.stop_signal = null;
    job.termination_signal = null;
    job.notified_state = null;
    for (job.processes.items) |*process| {
        if (process.stop_signal == null) continue;
        process.status = null;
        process.stop_signal = null;
        process.termination_signal = null;
    }
    job.validate();
}

fn waitBackgroundJobUntilTerminated(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    state_delta: *delta.StateDelta,
    job: *state.BackgroundJob,
) !outcome.ExitStatus {
    job.validate();
    shell_state.validate();
    eval_context.validate();
    if (job.state != .done) {
        const process_port = evaluator.process_port orelse return error.Unimplemented;
        for (job.processes.items, 0..) |*process, process_index| {
            if (process.child.state != .running) continue;
            while (process.child.state == .running) {
                const result = process_port.pollWait(.{
                    .child = &process.child,
                    .nohang = false,
                    .report_stopped = false,
                }) catch return error.Unimplemented;
                const wait_status = result.status orelse {
                    if (try appendInterruptedWaitSignal(evaluator, shell_state, eval_context, state_delta)) |status| {
                        return status;
                    }
                    continue;
                };
                applyBackgroundProcessStatus(job, process_index, wait_status);
            }
        }
    }
    job.validate();
    return job.status;
}

fn appendInterruptedWaitSignal(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    eval_context: context.EvalContext,
    state_delta: *delta.StateDelta,
) !?outcome.ExitStatus {
    shell_state.validate();
    eval_context.validate();
    std.debug.assert(eval_context.target.allowsShellStateCommit());

    const signal_port = evaluator.signal_port orelse return null;
    const event = signal_port.poll() catch |err| switch (err) {
        error.Unsupported, error.Unexpected => return error.Unimplemented,
    } orelse return null;
    event.validate();
    const signal = state.TrapSignal.fromRuntimeNumber(event.signal) orelse return error.Unimplemented;
    const delivery = try state_delta.appendSignalDelivery(shell_state, signal);
    return switch (delivery) {
        .default_action => signal.defaultExitStatus().?,
        .ignored => null,
        .queued => signal.defaultExitStatus().?,
    };
}

fn waitForegroundJob(evaluator: *Evaluator, job: *state.BackgroundJob) !outcome.ExitStatus {
    const process_port = evaluator.process_port orelse return error.Unimplemented;
    if (job.state != .done) {
        for (job.processes.items, 0..) |*process, process_index| {
            while (process.child.state == .running) {
                const result = process_port.pollWait(.{
                    .child = &process.child,
                    .nohang = false,
                    .report_stopped = true,
                }) catch return error.Unimplemented;
                const wait_status = result.status orelse continue;
                applyBackgroundProcessStatus(job, process_index, wait_status);
                if (job.state == .stopped) return job.status;
            }
        }
    }
    job.validate();
    return job.status;
}

fn refreshedBackgroundJobState(
    evaluator: *Evaluator,
    shell_state: state.ShellState,
    buffers: ?*EvaluationBuffers,
) EvalError!state.ShellState {
    shell_state.validate();
    var refreshed_state = shell_state.clone(evaluator.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    errdefer refreshed_state.deinit();
    try refreshBackgroundJobs(evaluator, &refreshed_state, buffers);
    refreshed_state.refreshJobMarkers();
    return refreshed_state;
}

fn refreshBackgroundJobs(evaluator: *Evaluator, shell_state: *state.ShellState, buffers: ?*EvaluationBuffers) !void {
    shell_state.validate();
    const process_port = evaluator.process_port orelse return;
    for (shell_state.background_jobs.items) |*job| {
        job.validate();
        if (job.state == .done) continue;
        const before_state = job.state;
        for (job.processes.items, 0..) |*process, process_index| {
            process.validate();
            if (process.child.state != .running) continue;
            const poll_result = process_port.pollWait(.{ .child = &process.child }) catch |err| {
                if (buffers) |active_buffers| {
                    const failure = waitFailure(err);
                    try active_buffers.addBuiltinDiagnostic("jobs", failure.message);
                }
                continue;
            };
            const wait_status = poll_result.status orelse continue;
            applyBackgroundProcessStatus(job, process_index, wait_status);
        }
        job.validate();
        if (job.state != before_state and job.state != .running) try shell_state.queueJobNotification(job.id);
    }
    shell_state.validate();
}

fn applyBackgroundProcessStatus(
    job: *state.BackgroundJob,
    process_index: usize,
    wait_status: runtime.process.WaitStatus,
) void {
    std.debug.assert(job.id != 0);
    std.debug.assert(job.processes.items.len != 0);
    std.debug.assert(process_index < job.processes.items.len);
    (runtime.process.WaitResult{ .status = wait_status }).validate();

    var process = &job.processes.items[process_index];
    const process_pid = process.child.child.id;
    const process_status = normalizeWaitStatus(wait_status);
    process.status = process_status;
    process.stop_signal = null;
    process.termination_signal = null;

    switch (wait_status) {
        .stopped => |signal| {
            process.stop_signal = signal;
            job.state = .stopped;
            job.status = process_status;
            job.stop_signal = signal;
            job.termination_signal = null;
        },
        .exited, .unknown => {
            process.stop_signal = null;
            if (process_pid == null or process_pid.? == job.pid) {
                job.status = process_status;
                job.termination_signal = null;
            }
        },
        .signaled => |signal| {
            process.termination_signal = signal;
            if (process_pid == null or process_pid.? == job.pid) {
                job.status = process_status;
                job.termination_signal = signal;
            }
        },
    }

    if (job.allProcessesWaited()) {
        job.state = .done;
        job.stop_signal = null;
        if (job.processes.items.len != 0) {
            if (job.processes.items[job.processes.items.len - 1].status) |last_status| {
                if (job.status == 0 or process_pid == null or process_pid.? != job.pid) job.status = last_status;
            }
        }
        return;
    }
    if (job.state != .stopped) job.state = .running;
}

fn appendJobTableDiff(before: state.ShellState, after: state.ShellState, state_delta: *delta.StateDelta) !void {
    before.validate();
    after.validate();
    for (after.background_jobs.items) |job| {
        if (before.findBackgroundJobById(job.id) == null) {
            try state_delta.appendBackgroundJob(job);
        } else {
            try state_delta.updateBackgroundJob(job);
        }
    }
    for (before.background_jobs.items) |job| {
        if (after.findBackgroundJobById(job.id) == null) try state_delta.removeBackgroundJob(job.id);
    }
    if (after.pending_job_notifications.items.len < before.pending_job_notifications.items.len) {
        state_delta.consumeJobNotifications(
            before.pending_job_notifications.items.len - after.pending_job_notifications.items.len,
        );
    }
    std.debug.assert(after.pending_job_notifications.items.len >= before.pending_job_notifications.items.len or
        state_delta.job_notification_consume_count != 0);
    const common_notifications = @min(
        before.pending_job_notifications.items.len,
        after.pending_job_notifications.items.len,
    );
    for (after.pending_job_notifications.items[common_notifications..]) |notification| {
        if (after.findBackgroundJobById(notification.job_id) == null) continue;
        try state_delta.appendJobNotification(notification);
    }
    if (before.current_job_id != after.current_job_id or before.previous_job_id != after.previous_job_id) {
        state_delta.setJobMarkers(.{
            .current_job_id = after.current_job_id,
            .previous_job_id = after.previous_job_id,
        });
    }
}

fn findBackgroundJobBySpec(shell_state: state.ShellState, spec: []const u8) ?state.BackgroundJob {
    shell_state.validate();
    std.debug.assert(spec.len != 0);
    const text = if (std.mem.startsWith(u8, spec, "%")) spec[1..] else spec;
    if (text.len == 0 or std.mem.eql(u8, text, "+") or std.mem.eql(u8, text, "%")) {
        const id = shell_state.current_job_id orelse return null;
        return shell_state.findBackgroundJobById(id);
    }
    if (std.mem.eql(u8, text, "-")) {
        const id = shell_state.previous_job_id orelse return null;
        return shell_state.findBackgroundJobById(id);
    }
    if (std.fmt.parseInt(usize, text, 10)) |id| {
        return shell_state.findBackgroundJobById(id);
    } else |_| {}
    if (std.mem.startsWith(u8, text, "?")) return findBackgroundJobBySubstring(shell_state, text[1..]);
    return findBackgroundJobByPrefix(shell_state, text);
}

fn findBackgroundJobByPrefix(shell_state: state.ShellState, prefix: []const u8) ?state.BackgroundJob {
    var match: ?state.BackgroundJob = null;
    for (shell_state.background_jobs.items) |job| {
        if (!std.mem.startsWith(u8, job.command, prefix)) continue;
        if (match != null) return null;
        match = job;
    }
    return match;
}

fn findBackgroundJobBySubstring(shell_state: state.ShellState, needle: []const u8) ?state.BackgroundJob {
    var match: ?state.BackgroundJob = null;
    for (shell_state.background_jobs.items) |job| {
        if (std.mem.indexOf(u8, job.command, needle) == null) continue;
        if (match != null) return null;
        match = job;
    }
    return match;
}

fn appendJobLine(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    shell_state: state.ShellState,
    job: state.BackgroundJob,
    mode: JobPrintMode,
) !void {
    job.validate();
    switch (mode) {
        .pids => try stdout.print(allocator, "{d}\n", .{job.pid}),
        .long => {
            try stdout.print(allocator, "[{d}] {c} {d} ", .{ job.id, shell_state.jobMarker(job), job.pid });
            try appendJobState(allocator, stdout, job.state, job.status, job.stop_signal, job.termination_signal);
            try stdout.print(allocator, " {s}\n", .{job.command});
        },
        .normal => {
            try stdout.print(allocator, "[{d}] {c} ", .{ job.id, shell_state.jobMarker(job) });
            try appendJobState(allocator, stdout, job.state, job.status, job.stop_signal, job.termination_signal);
            try stdout.print(allocator, " {s}\n", .{job.command});
        },
    }
}

fn appendJobNotificationLine(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    notification: state.BackgroundJobNotification,
) !void {
    notification.validate();
    try stdout.print(allocator, "[{d}] ", .{notification.job_id});
    try appendJobState(
        allocator,
        stdout,
        notification.state,
        notification.status,
        notification.stop_signal,
        notification.termination_signal,
    );
    try stdout.print(allocator, " {s}\n", .{notification.command});
}

fn appendJobState(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    job_state: state.JobState,
    status: outcome.ExitStatus,
    stop_signal: ?u8,
    termination_signal: ?u8,
) !void {
    switch (job_state) {
        .running => try stdout.appendSlice(allocator, "Running"),
        .stopped => try appendStoppedJobState(allocator, stdout, stop_signal),
        .done => {
            if (termination_signal) |signal| {
                try stdout.appendSlice(allocator, "Terminated(");
                try appendSignalName(allocator, stdout, signal);
                try stdout.append(allocator, ')');
            } else if (status == 0) {
                try stdout.appendSlice(allocator, "Done");
            } else {
                try stdout.print(allocator, "Done({d})", .{status});
            }
        },
    }
}

fn appendStoppedJobState(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), signal: ?u8) !void {
    const stopped_signal = signal orelse {
        try stdout.appendSlice(allocator, "Stopped");
        return;
    };
    if (stopped_signal == signalNumber(.STOP) or
        stopped_signal == signalNumber(.TSTP) or
        stopped_signal == signalNumber(.TTIN) or
        stopped_signal == signalNumber(.TTOU))
    {
        try stdout.appendSlice(allocator, "Stopped (");
        try appendSignalName(allocator, stdout, stopped_signal);
        try stdout.append(allocator, ')');
        return;
    }
    try stdout.appendSlice(allocator, "Stopped");
}

fn appendSignalName(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), signal: u8) !void {
    if (signalName(signal)) |name| {
        try stdout.appendSlice(allocator, name);
    } else {
        try stdout.print(allocator, "signal {d}", .{signal});
    }
}

fn signalName(signal: u8) ?[]const u8 {
    if (signal == signalNumber(.HUP)) return "SIGHUP";
    if (signal == signalNumber(.INT)) return "SIGINT";
    if (signal == signalNumber(.QUIT)) return "SIGQUIT";
    if (signal == signalNumber(.ILL)) return "SIGILL";
    if (signal == signalNumber(.ABRT)) return "SIGABRT";
    if (signal == signalNumber(.FPE)) return "SIGFPE";
    if (signal == signalNumber(.KILL)) return "SIGKILL";
    if (signal == signalNumber(.SEGV)) return "SIGSEGV";
    if (signal == signalNumber(.PIPE)) return "SIGPIPE";
    if (signal == signalNumber(.ALRM)) return "SIGALRM";
    if (signal == signalNumber(.TERM)) return "SIGTERM";
    if (signal == signalNumber(.STOP)) return "SIGSTOP";
    if (signal == signalNumber(.TSTP)) return "SIGTSTP";
    if (signal == signalNumber(.TTIN)) return "SIGTTIN";
    if (signal == signalNumber(.TTOU)) return "SIGTTOU";
    return null;
}

fn signalNumber(signal: std.posix.SIG) u8 {
    return @intCast(@intFromEnum(signal));
}

fn evaluateAlias(
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "alias"));

    if (argv.len == 1) return listAliases(shell_state, state_delta.*, buffers);

    var preview_delta = try state_delta.clone(buffers.allocator);
    defer preview_delta.deinit();
    for (argv[1..]) |arg| {
        if (std.mem.findScalar(u8, arg, '=')) |equals| {
            const name = arg[0..equals];
            if (!isAliasName(name)) return builtinUsageError(buffers, "alias", "invalid alias name");
            try preview_delta.setAlias(name, arg[equals + 1 ..]);
        } else {
            if (!isAliasName(arg)) return builtinUsageError(buffers, "alias", "invalid alias name");
            if (lookupAliasValue(shell_state, preview_delta, arg) == null)
                return aliasNotFoundError(buffers, arg);
        }
    }

    for (argv[1..]) |arg| {
        if (std.mem.findScalar(u8, arg, '=')) |equals| {
            try state_delta.setAlias(arg[0..equals], arg[equals + 1 ..]);
        } else {
            const value = lookupAliasValue(shell_state, state_delta.*, arg).?;
            try buffers.stdout.print(buffers.allocator, "{s}=", .{arg});
            try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, value);
            try buffers.stdout.append(buffers.allocator, '\n');
        }
    }
    return 0;
}

fn aliasNotFoundError(buffers: *EvaluationBuffers, name: []const u8) !outcome.ExitStatus {
    std.debug.assert(name.len != 0);
    const message = try std.fmt.allocPrint(
        buffers.allocator,
        "{s}: not found; define aliases with name=value",
        .{name},
    );
    defer buffers.allocator.free(message);
    return builtinStatusError(buffers, 1, "alias", message);
}

fn evaluateUnalias(
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "unalias"));

    if (argv.len == 1) return builtinUsageError(buffers, "unalias", "missing operand");
    var index: usize = 1;
    const option_terminated = std.mem.eql(u8, argv[index], "--");
    if (option_terminated) index += 1;
    if (index >= argv.len) return builtinUsageError(buffers, "unalias", "missing operand");
    if (!option_terminated and std.mem.startsWith(u8, argv[index], "-") and !std.mem.eql(
        u8,
        argv[index],
        "-a",
    )) return builtinUsageError(
        buffers,
        "unalias",
        "unsupported option",
    );
    var clear_requested = false;
    if (!option_terminated and std.mem.eql(u8, argv[index], "-a")) {
        clear_requested = true;
        index += 1;
        if (index == argv.len) {
            state_delta.clearAliases();
            return 0;
        }
    }

    var preview_delta = try state_delta.clone(buffers.allocator);
    defer preview_delta.deinit();
    if (clear_requested) preview_delta.clearAliases();
    for (argv[index..]) |arg| {
        if (!isAliasName(arg)) return builtinUsageError(buffers, "unalias", "invalid alias name");
        if (lookupAliasValue(shell_state, preview_delta, arg) == null) return builtinStatusError(
            buffers,
            1,
            "unalias",
            "not found",
        );
        try preview_delta.unsetAlias(arg);
    }
    if (clear_requested) state_delta.clearAliases();
    for (argv[index..]) |arg| try state_delta.unsetAlias(arg);
    return 0;
}

fn evaluateTrap(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    argv: []const []const u8,
    state_delta: *delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "trap"));

    if (argv.len == 1) return listTraps(shell_state, buffers);

    var index: usize = 1;
    var print = false;
    while (index < argv.len) {
        const option = argv[index];
        if (std.mem.eql(u8, option, "--")) {
            index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-p")) {
            print = true;
            index += 1;
        } else {
            break;
        }
    }
    if (print) {
        if (index >= argv.len) return listTraps(shell_state, buffers);
        return listTrapOperands(allocator, shell_state, argv[index..], buffers);
    }
    if (index >= argv.len) return listTraps(shell_state, buffers);

    const action = argv[index];
    if (index + 1 >= argv.len) return builtinUsageError(buffers, "trap", "missing signal");
    for (argv[index + 1 ..]) |raw_signal| {
        const name = try normalizeTrapName(allocator, raw_signal);
        defer allocator.free(name);
        if (!state.isValidTrapName(name)) {
            try appendTrapInvalidSignalMessage(buffers, raw_signal);
            return 1;
        }
    }
    for (argv[index + 1 ..]) |raw_signal| {
        const name = try normalizeTrapName(allocator, raw_signal);
        defer allocator.free(name);
        try state_delta.setTrap(name, if (std.mem.eql(u8, action, "-")) null else action);
    }
    return 0;
}

fn builtinUsageError(buffers: *EvaluationBuffers, command: []const u8, message: []const u8) !outcome.ExitStatus {
    return builtinStatusError(buffers, 2, command, message);
}

fn builtinStatusError(
    buffers: *EvaluationBuffers,
    status: outcome.ExitStatus,
    command: []const u8,
    message: []const u8,
) !outcome.ExitStatus {
    std.debug.assert(status != 0);
    try buffers.addBuiltinDiagnostic(command, message);
    return status;
}

const AssignmentSlice = struct {
    name: []const u8,
    value: ?[]const u8,
};

fn splitAssignment(arg: []const u8) AssignmentSlice {
    if (std.mem.findScalar(u8, arg, '=')) |equals| return .{ .name = arg[0..equals], .value = arg[equals + 1 ..] };
    return .{ .name = arg, .value = null };
}

fn findAssignmentPrefixValue(assignments: []const command_plan.Assignment, name: []const u8) ?[]const u8 {
    state.assertValidVariableName(name);
    var value: ?[]const u8 = null;
    for (assignments) |assignment| {
        assignment.validate();
        if (std.mem.eql(u8, assignment.name, name)) value = assignment.value;
    }
    return value;
}

fn isShellName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

fn isAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or
            std.ascii.isDigit(byte) or
            byte == '!' or
            byte == '%' or
            byte == ',' or
            byte == '-' or
            byte == '@' or
            byte == '_')) return false;
    }
    return true;
}

const VariableDeclarationMode = enum { exported, readonly };

fn listVariableDeclarations(
    shell_state: state.ShellState,
    state_delta: delta.StateDelta,
    buffers: *EvaluationBuffers,
    mode: VariableDeclarationMode,
    command: []const u8,
) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    try collectVariableNames(buffers.allocator, shell_state, state_delta, &names);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const variable = lookupVariable(shell_state, state_delta, name) orelse continue;
        const include = switch (mode) {
            .exported => variable.exported,
            .readonly => variable.readonly,
        };
        if (!include) continue;
        try buffers.stdout.print(buffers.allocator, "{s} {s}", .{ command, name });
        try buffers.stdout.append(buffers.allocator, '=');
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, variable.value);
        try buffers.stdout.append(buffers.allocator, '\n');
    }
    return 0;
}

fn listShellVariables(
    shell_state: state.ShellState,
    state_delta: delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    try collectVariableNames(buffers.allocator, shell_state, state_delta, &names);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const variable = lookupVariable(shell_state, state_delta, name) orelse continue;
        try buffers.stdout.print(buffers.allocator, "{s}=", .{name});
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, variable.value);
        try buffers.stdout.append(buffers.allocator, '\n');
    }
    return 0;
}

fn collectVariableNames(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    state_delta: delta.StateDelta,
    names: *std.ArrayList([]const u8),
) !void {
    var variables = shell_state.variables.iterator();
    while (variables.next()) |entry| try appendUniqueString(allocator, names, entry.key_ptr.*);
    for (state_delta.variable_assignments.items) |assignment| try appendUniqueString(allocator, names, assignment.name);
}

fn lookupVariable(shell_state: state.ShellState, state_delta: delta.StateDelta, name: []const u8) ?state.Variable {
    for (state_delta.variable_unsets.items) |unset_name| if (std.mem.eql(u8, unset_name, name)) return null;
    var variable = shell_state.getVariable(name) orelse state.Variable{ .value = "" };
    for (state_delta.variable_assignments.items) |assignment| {
        if (!std.mem.eql(u8, assignment.name, name)) continue;
        variable.value = assignment.value;
        if (assignment.exported) |exported| variable.exported = exported;
        variable.readonly = variable.readonly or assignment.readonly;
    }
    for (state_delta.variable_flags.items) |mutation| {
        if (!std.mem.eql(u8, mutation.name, name)) continue;
        switch (mutation.flag) {
            .exported => variable.exported = mutation.enabled,
            .readonly => variable.readonly = true,
        }
    }
    return variable;
}

const OptionSpec = struct {
    name: []const u8,
    option: state.ShellOption,
};

const option_specs = [_]OptionSpec{
    .{ .name = "allexport", .option = .allexport },
    .{ .name = "emacs", .option = .emacs },
    .{ .name = "errexit", .option = .errexit },
    .{ .name = "ignoreeof", .option = .ignoreeof },
    .{ .name = "monitor", .option = .monitor },
    .{ .name = "noclobber", .option = .noclobber },
    .{ .name = "noexec", .option = .noexec },
    .{ .name = "noglob", .option = .noglob },
    .{ .name = "notify", .option = .notify },
    .{ .name = "nounset", .option = .nounset },
    .{ .name = "pipefail", .option = .pipefail },
    .{ .name = "vi", .option = .vi },
    .{ .name = "verbose", .option = .verbose },
    .{ .name = "xtrace", .option = .xtrace },
};

fn printShellOptions(
    shell_state: state.ShellState,
    state_delta: delta.StateDelta,
    buffers: *EvaluationBuffers,
    reusable: bool,
) !outcome.ExitStatus {
    for (option_specs) |spec| {
        const enabled = optionEnabled(shell_state, state_delta, spec.option);
        if (reusable) {
            try buffers.stdout.print(buffers.allocator, "set {s}o {s}\n", .{ if (enabled) "-" else "+", spec.name });
        } else {
            try buffers.stdout.print(buffers.allocator, "{s}\t{s}\n", .{ spec.name, if (enabled) "on" else "off" });
        }
    }
    return 0;
}

fn appendShellOptionNameChange(state_delta: *delta.StateDelta, name: []const u8, enabled: bool) !bool {
    if (std.mem.eql(u8, name, "nolog")) return true;
    for (option_specs) |spec| {
        if (!std.mem.eql(u8, spec.name, name)) continue;
        try state_delta.setOption(spec.option, enabled);
        return true;
    }
    return false;
}

fn appendShellOptionShortChanges(state_delta: *delta.StateDelta, spelling: []const u8) !bool {
    if (spelling.len < 2) return false;
    if (spelling[0] != '-' and spelling[0] != '+') return false;
    for (spelling[1..]) |option| switch (option) {
        'a', 'b', 'e', 'f', 'h', 'm', 'n', 'u', 'x', 'v', 'C' => {},
        else => return false,
    };

    const enabled = spelling[0] == '-';
    for (spelling[1..]) |option| switch (option) {
        'a' => try state_delta.setOption(.allexport, enabled),
        'b' => try state_delta.setOption(.notify, enabled),
        'e' => try state_delta.setOption(.errexit, enabled),
        'f' => try state_delta.setOption(.noglob, enabled),
        'h' => {},
        'm' => try state_delta.setOption(.monitor, enabled),
        'n' => try state_delta.setOption(.noexec, enabled),
        'u' => try state_delta.setOption(.nounset, enabled),
        'x' => try state_delta.setOption(.xtrace, enabled),
        'v' => try state_delta.setOption(.verbose, enabled),
        'C' => try state_delta.setOption(.noclobber, enabled),
        else => unreachable,
    };
    return true;
}

fn optionEnabled(shell_state: state.ShellState, state_delta: delta.StateDelta, option: state.ShellOption) bool {
    var enabled = shell_state.options.enabled(option);
    for (state_delta.option_changes.items) |change| {
        if (change.option == option) enabled = change.enabled;
    }
    if (option == .emacs) {
        for (state_delta.option_changes.items) |change| {
            if (change.option == .vi and change.enabled) enabled = false;
        }
    } else if (option == .vi) {
        for (state_delta.option_changes.items) |change| {
            if (change.option == .emacs and change.enabled) enabled = false;
        }
    }
    return enabled;
}

fn listAliases(
    shell_state: state.ShellState,
    state_delta: delta.StateDelta,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    var aliases = shell_state.aliases.iterator();
    while (aliases.next()) |entry| try appendUniqueString(buffers.allocator, &names, entry.key_ptr.*);
    for (state_delta.alias_sets.items) |mutation| try appendUniqueString(buffers.allocator, &names, mutation.name);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const value = lookupAliasValue(shell_state, state_delta, name) orelse continue;
        try buffers.stdout.print(buffers.allocator, "{s}=", .{name});
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, value);
        try buffers.stdout.append(buffers.allocator, '\n');
    }
    return 0;
}

fn lookupAliasValue(shell_state: state.ShellState, state_delta: delta.StateDelta, name: []const u8) ?[]const u8 {
    if (state_delta.clear_aliases) return lookupAliasSetValue(state_delta, name);
    for (state_delta.alias_unsets.items) |unset_name| if (std.mem.eql(u8, unset_name, name)) return null;
    return lookupAliasSetValue(state_delta, name) orelse if (shell_state.getAlias(name)) |alias| alias.value else null;
}

fn lookupAliasSetValue(state_delta: delta.StateDelta, name: []const u8) ?[]const u8 {
    for (state_delta.alias_sets.items) |mutation| if (std.mem.eql(u8, mutation.name, name)) return mutation.value;
    return null;
}

fn listTraps(shell_state: state.ShellState, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    var traps = shell_state.traps.iterator();
    while (traps.next()) |entry| try names.append(buffers.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    for (names.items) |name| try appendTrapLine(shell_state, buffers, name, false);
    return 0;
}

fn listTrapOperands(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    signal_words: []const []const u8,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    for (signal_words) |raw_signal| {
        const name = try normalizeTrapName(allocator, raw_signal);
        defer allocator.free(name);
        if (!state.isValidTrapName(name)) {
            try appendTrapInvalidSignalMessage(buffers, raw_signal);
            return 1;
        }
        try appendTrapLine(shell_state, buffers, name, true);
    }
    return 0;
}

fn appendTrapInvalidSignalMessage(buffers: *EvaluationBuffers, raw_signal: []const u8) !void {
    try buffers.stderr.print(buffers.allocator, "trap: {s}: invalid signal specification\n", .{raw_signal});
}

fn appendTrapLine(
    shell_state: state.ShellState,
    buffers: *EvaluationBuffers,
    name: []const u8,
    print_unset: bool,
) !void {
    if (shell_state.getTrap(name)) |trap| {
        try buffers.stdout.appendSlice(buffers.allocator, "trap -- ");
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, trap.action);
        try buffers.stdout.print(buffers.allocator, " {s}\n", .{name});
    } else if (print_unset) {
        try buffers.stdout.print(buffers.allocator, "trap -- - {s}\n", .{name});
    }
}

fn normalizeTrapName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "0")) return allocator.dupe(u8, "EXIT");
    if (parseTrapSignalNumber(raw)) |name| return allocator.dupe(u8, name);
    const start: usize = if (std.ascii.startsWithIgnoreCase(raw, "SIG") and raw.len > 3) 3 else 0;
    if (start >= raw.len) return allocator.dupe(u8, raw);
    const name = try allocator.alloc(u8, raw.len - start);
    for (raw[start..], 0..) |byte, index| name[index] = std.ascii.toUpper(byte);
    return name;
}

fn parseTrapSignalNumber(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;
    for (raw) |byte| if (!std.ascii.isDigit(byte)) return null;
    const number = std.fmt.parseInt(u8, raw, 10) catch return null;
    return switch (number) {
        1 => "HUP",
        2 => "INT",
        3 => "QUIT",
        14 => "ALRM",
        10 => "USR1",
        12 => "USR2",
        15 => "TERM",
        else => null,
    };
}

fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(allocator, value);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn appendShellSingleQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
}

fn evaluateEcho(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: *std.ArrayList(u8),
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "echo"));

    var first_operand: usize = 1;
    var append_newline = true;
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "-n")) {
        first_operand = 2;
        append_newline = false;
    }

    for (argv[first_operand..], 0..) |arg, index| {
        if (index > 0) try stdout.append(allocator, ' ');
        if (!try appendEchoOperand(allocator, stdout, arg)) {
            append_newline = false;
            break;
        }
    }
    if (append_newline) try stdout.append(allocator, '\n');
    return 0;
}

fn evaluateEchoRouted(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var status = try evaluateEcho(allocator, argv, &stdout);
    var frame = try buffers.outputFrame();
    defer frame.deinit();
    if (stdout.items.len != 0 and frame.routingRef().destination(1) == .closed) status = 1;
    try frame.write(1, stdout.items);
    return status;
}

fn appendEchoOperand(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8) !bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try stdout.append(allocator, text[index]);
            index += 1;
            continue;
        }

        index += 1;
        if (index >= text.len) {
            try stdout.append(allocator, '\\');
            continue;
        }

        switch (text[index]) {
            'a' => try stdout.append(allocator, 0x07),
            'b' => try stdout.append(allocator, 0x08),
            'c' => return false,
            'f' => try stdout.append(allocator, 0x0c),
            'n' => try stdout.append(allocator, '\n'),
            'r' => try stdout.append(allocator, '\r'),
            't' => try stdout.append(allocator, '\t'),
            'v' => try stdout.append(allocator, 0x0b),
            '\\' => try stdout.append(allocator, '\\'),
            '0' => {
                index += 1;
                var value: u16 = 0;
                var count: usize = 0;
                while (index < text.len and count < 3 and text[index] >= '0' and text[index] <= '7') : (count += 1) {
                    value = value * 8 + (text[index] - '0');
                    index += 1;
                }
                try stdout.append(allocator, @intCast(value & 0xff));
                continue;
            },
            else => {
                try stdout.append(allocator, '\\');
                try stdout.append(allocator, text[index]);
            },
        }
        index += 1;
    }
    return true;
}

fn evaluatePrintf(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "printf"));

    var format_index: usize = 1;
    if (format_index < argv.len and std.mem.eql(u8, argv[format_index], "--")) format_index += 1;
    if (format_index >= argv.len) {
        var status: outcome.ExitStatus = 2;
        try printfDiagnostic(allocator, stderr, &status, "missing format operand");
        return status;
    }

    var status: outcome.ExitStatus = 0;
    var stderr_before_stdout = false;
    try appendPrintfOutput(
        allocator,
        stdout,
        stderr,
        &status,
        &stderr_before_stdout,
        argv[format_index],
        argv[format_index + 1 ..],
    );
    return status;
}

fn evaluatePrintfRouted(
    allocator: std.mem.Allocator,
    eval_context: context.EvalContext,
    argv: []const []const u8,
    buffers: *EvaluationBuffers,
) !outcome.ExitStatus {
    eval_context.validate();
    buffers.frame.validate();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    var status = try evaluatePrintf(allocator, argv, &stdout, &stderr);

    var frame = try buffers.outputFrame();
    defer frame.deinit();
    if ((stdout.items.len != 0 and frame.routingRef().destination(1) == .closed) or
        (stderr.items.len != 0 and frame.routingRef().destination(2) == .closed))
    {
        status = 1;
    }
    try frame.write(1, stdout.items);
    try frame.write(2, stderr.items);
    return status;
}

const PrintfSpec = struct {
    spec: u8,
    argument: ?usize = null,
    left_adjust: bool = false,
    zero_pad: bool = false,
    sign_plus: bool = false,
    sign_space: bool = false,
    alternate: bool = false,
    width_from_argument: bool = false,
    width: ?usize = null,
    precision_from_argument: bool = false,
    precision: ?usize = null,
};

const PrintfIntegerBase = enum { decimal, octal, lower_hex, upper_hex };

const PrintfArgumentMode = enum { none, numbered, unnumbered };

fn appendPrintfOutput(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    stderr_before_stdout: *bool,
    format: []const u8,
    args: []const []const u8,
) !void {
    const argument_mode = analyzePrintfFormat(format) catch |err| switch (err) {
        error.MixedArguments => {
            try printfDiagnostic(allocator, stderr, status, "invalid format");
            return;
        },
    };

    var arg_index: usize = 0;
    var numbered_base: usize = 0;
    var first_pass = true;
    while (first_pass or switch (argument_mode) {
        .numbered => numbered_base < args.len,
        .none, .unnumbered => arg_index < args.len,
    }) {
        first_pass = false;
        const before = if (argument_mode == .numbered) numbered_base else arg_index;
        var pass_max_numbered_argument: usize = 0;
        var index: usize = 0;
        while (index < format.len) {
            switch (format[index]) {
                '\\' => {
                    index += 1;
                    if (index >= format.len) {
                        try stdout.append(allocator, '\\');
                    } else {
                        _ = try appendEscapedSequence(allocator, stdout, format, &index, .format);
                    }
                },
                '%' => {
                    index += 1;
                    if (index >= format.len) {
                        try printfDiagnostic(allocator, stderr, status, "invalid format");
                        break;
                    }
                    const spec = parsePrintfSpec(format, &index) orelse {
                        try printfDiagnostic(allocator, stderr, status, "invalid format");
                        continue;
                    };
                    if (spec.spec == '%') {
                        if (spec.width_from_argument or spec.precision_from_argument) {
                            try printfDiagnostic(allocator, stderr, status, "invalid format");
                            continue;
                        }
                        try stdout.append(allocator, '%');
                        continue;
                    }
                    const resolved_spec = try resolvePrintfDynamicSpec(
                        allocator,
                        stderr,
                        status,
                        stderr_before_stdout,
                        spec,
                        args,
                        &arg_index,
                    );
                    const arg = if (spec.argument) |argument_number| blk: {
                        pass_max_numbered_argument = @max(pass_max_numbered_argument, argument_number);
                        const offset = std.math.add(usize, numbered_base, argument_number - 1) catch {
                            try printfDiagnostic(allocator, stderr, status, "missing argument");
                            return;
                        };
                        if (offset >= args.len) {
                            try printfDiagnostic(allocator, stderr, status, "missing argument");
                            return;
                        }
                        break :blk args[offset];
                    } else if (arg_index < args.len) blk: {
                        const value = args[arg_index];
                        arg_index += 1;
                        break :blk value;
                    } else "";
                    if (!try appendPrintfConversion(
                        allocator,
                        stdout,
                        stderr,
                        status,
                        stderr_before_stdout,
                        resolved_spec,
                        arg,
                    )) return;
                },
                else => {
                    try stdout.append(allocator, format[index]);
                    index += 1;
                },
            }
        }
        if (argument_mode == .numbered) {
            if (pass_max_numbered_argument == 0) break;
            numbered_base = std.math.add(usize, numbered_base, pass_max_numbered_argument) catch {
                try printfDiagnostic(allocator, stderr, status, "missing argument");
                return;
            };
            if (numbered_base == before) break;
        } else if (arg_index == before) break;
    }
}

fn analyzePrintfFormat(format: []const u8) error{MixedArguments}!PrintfArgumentMode {
    var result: PrintfArgumentMode = .none;
    var index: usize = 0;
    while (index < format.len) {
        switch (format[index]) {
            '\\' => {
                index += 1;
                if (index < format.len) skipPrintfFormatEscape(format, &index);
            },
            '%' => {
                index += 1;
                if (index >= format.len) return result;
                const spec = parsePrintfSpec(format, &index) orelse return result;
                if (spec.spec == '%') continue;
                if (spec.width_from_argument or spec.precision_from_argument) {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
                if (spec.argument != null) {
                    if (result == .unnumbered) return error.MixedArguments;
                    result = .numbered;
                } else {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
            },
            else => index += 1,
        }
    }
    return result;
}

fn skipPrintfFormatEscape(format: []const u8, index: *usize) void {
    switch (format[index.*]) {
        'a', 'b', 'f', 'n', 'r', 't', 'v', '\\' => index.* += 1,
        'x' => {
            index.* += 1;
            var count: usize = 0;
            while (index.* < format.len and count < 2) : (count += 1) {
                _ = std.fmt.charToDigit(format[index.*], 16) catch break;
                index.* += 1;
            }
        },
        '0'...'7' => {
            var count: usize = 0;
            while (index.* < format.len and
                count < 3 and
                format[index.*] >= '0' and
                format[index.*] <= '7') : (count += 1)
            {
                index.* += 1;
            }
        },
        else => {},
    }
}

fn printfDiagnostic(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    message: []const u8,
) !void {
    status.* = if (status.* == 2) 2 else 1;
    try stderr.appendSlice(allocator, "printf: ");
    try stderr.appendSlice(allocator, message);
    try stderr.append(allocator, '\n');
}

fn printfNumericDiagnostic(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    stderr_before_stdout: *bool,
) !void {
    stderr_before_stdout.* = true;
    try printfDiagnostic(allocator, stderr, status, "numeric argument required");
}

fn resolvePrintfDynamicSpec(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    stderr_before_stdout: *bool,
    spec: PrintfSpec,
    args: []const []const u8,
    arg_index: *usize,
) !PrintfSpec {
    var result = spec;
    if (result.width_from_argument) {
        const value = try parsePrintfSigned(
            allocator,
            stderr,
            status,
            stderr_before_stdout,
            nextPrintfArgument(args, arg_index),
        );
        applyPrintfDynamicWidth(&result, value);
    }
    if (result.precision_from_argument) {
        const value = try parsePrintfSigned(
            allocator,
            stderr,
            status,
            stderr_before_stdout,
            nextPrintfArgument(args, arg_index),
        );
        result.precision = if (value < 0) null else printfDynamicMagnitude(value);
    }
    result.width_from_argument = false;
    result.precision_from_argument = false;
    return result;
}

fn nextPrintfArgument(args: []const []const u8, arg_index: *usize) []const u8 {
    if (arg_index.* >= args.len) return "";
    const value = args[arg_index.*];
    arg_index.* += 1;
    return value;
}

fn applyPrintfDynamicWidth(spec: *PrintfSpec, value: i64) void {
    if (value < 0) {
        spec.left_adjust = true;
    }
    spec.width = printfDynamicMagnitude(value);
}

fn printfDynamicMagnitude(value: i64) usize {
    const magnitude: u64 = if (value < 0) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    return std.math.cast(usize, magnitude) orelse std.math.maxInt(usize);
}

fn parsePrintfSpec(format: []const u8, index: *usize) ?PrintfSpec {
    var result: PrintfSpec = .{ .spec = 0 };
    if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        if (index.* < format.len and format[index.*] == '$') {
            const argument_number = std.fmt.parseInt(usize, format[start..index.*], 10) catch return null;
            if (argument_number == 0) return null;
            result.argument = argument_number;
            index.* += 1;
        } else {
            index.* = start;
        }
    }
    while (index.* < format.len) {
        switch (format[index.*]) {
            '-' => result.left_adjust = true,
            '0' => result.zero_pad = true,
            '+' => result.sign_plus = true,
            ' ' => result.sign_space = true,
            '#' => result.alternate = true,
            else => break,
        }
        index.* += 1;
    }
    if (index.* < format.len and format[index.*] == '*') {
        result.width_from_argument = true;
        index.* += 1;
    } else if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        result.width = std.fmt.parseInt(usize, format[start..index.*], 10) catch null;
    }
    if (index.* < format.len and format[index.*] == '.') {
        index.* += 1;
        const start = index.*;
        if (index.* < format.len and format[index.*] == '*') {
            result.precision_from_argument = true;
            index.* += 1;
        } else {
            while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
            result.precision = if (start == index.*) 0 else std.fmt.parseInt(usize, format[start..index.*], 10) catch 0;
        }
    }
    if (index.* >= format.len) return null;
    result.spec = format[index.*];
    index.* += 1;
    return result;
}

fn appendPrintfConversion(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    stderr_before_stdout: *bool,
    spec: PrintfSpec,
    arg: []const u8,
) !bool {
    if (isPrintfFloatSpec(spec.spec)) {
        try appendPrintfFloatConversion(allocator, stdout, stderr, status, spec, arg);
        return true;
    }

    switch (spec.spec) {
        'd', 'i' => {
            const rendered = try formatPrintfSignedInteger(
                allocator,
                spec,
                try parsePrintfSigned(allocator, stderr, status, stderr_before_stdout, arg),
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'u' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg),
                .decimal,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'o' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg),
                .octal,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'x' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg),
                .lower_hex,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'X' => {
            const rendered = try formatPrintfUnsignedInteger(
                allocator,
                spec,
                try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg),
                .upper_hex,
            );
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        else => {},
    }

    if (spec.spec == 'b') {
        var escaped: std.ArrayList(u8) = .empty;
        errdefer escaped.deinit(allocator);
        const keep_going = try appendPrintfEscapedString(allocator, &escaped, arg);
        const bytes = try escaped.toOwnedSlice(allocator);
        defer allocator.free(bytes);
        try appendPadded(allocator, stdout, truncatePrintfBytes(bytes, spec.precision), spec);
        return keep_going;
    }

    const rendered: []u8 = switch (spec.spec) {
        's' => try formatPrintfString(allocator, arg, spec.precision),
        'c' => try allocator.dupe(u8, if (arg.len == 0) &[_]u8{0} else arg[0..1]),
        else => blk: {
            try printfDiagnostic(allocator, stderr, status, "invalid conversion");
            break :blk try allocator.alloc(u8, 0);
        },
    };
    defer allocator.free(rendered);
    try appendPadded(allocator, stdout, rendered, spec);
    return true;
}

fn formatPrintfString(allocator: std.mem.Allocator, arg: []const u8, precision: ?usize) ![]u8 {
    return allocator.dupe(u8, truncatePrintfBytes(arg, precision));
}

fn truncatePrintfBytes(text: []const u8, precision: ?usize) []const u8 {
    const limit = if (precision) |value| @min(value, text.len) else text.len;
    return text[0..limit];
}

fn formatPrintfSignedInteger(allocator: std.mem.Allocator, spec: PrintfSpec, value: i64) ![]u8 {
    const negative = value < 0;
    const magnitude: u64 = if (negative) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    return formatPrintfInteger(allocator, spec, magnitude, negative, .decimal);
}

fn formatPrintfUnsignedInteger(
    allocator: std.mem.Allocator,
    spec: PrintfSpec,
    value: u64,
    base: PrintfIntegerBase,
) ![]u8 {
    var unsigned_spec = spec;
    unsigned_spec.sign_plus = false;
    unsigned_spec.sign_space = false;
    return formatPrintfInteger(allocator, unsigned_spec, value, false, base);
}

fn formatPrintfInteger(
    allocator: std.mem.Allocator,
    spec: PrintfSpec,
    magnitude: u64,
    negative: bool,
    base: PrintfIntegerBase,
) ![]u8 {
    const raw_digits = try formatPrintfIntegerDigits(allocator, magnitude, base);
    defer allocator.free(raw_digits);

    var digits: []const u8 = raw_digits;
    if (spec.precision == 0 and magnitude == 0) digits = "";

    var precision_zeroes: usize = if (spec.precision) |precision|
        if (precision > digits.len) precision - digits.len else 0
    else
        0;
    if (base == .octal and spec.alternate) {
        if (digits.len + precision_zeroes == 0) {
            precision_zeroes = 1;
        } else if ((digits.len == 0 or digits[0] != '0') and precision_zeroes == 0) {
            precision_zeroes = 1;
        }
    }

    var prefix_buffer: [2]u8 = undefined;
    const prefix: []const u8 = switch (base) {
        .decimal => blk: {
            if (negative) {
                prefix_buffer[0] = '-';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_plus) {
                prefix_buffer[0] = '+';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_space) {
                prefix_buffer[0] = ' ';
                break :blk prefix_buffer[0..1];
            }
            break :blk "";
        },
        .octal => "",
        .lower_hex => if (spec.alternate and magnitude != 0) "0x" else "",
        .upper_hex => if (spec.alternate and magnitude != 0) "0X" else "",
    };

    const unpadded_len = prefix.len + precision_zeroes + digits.len;
    const width = spec.width orelse 0;
    const width_pad = if (width > unpadded_len) width - unpadded_len else 0;
    const use_zero_width_pad = spec.zero_pad and !spec.left_adjust and spec.precision == null;
    const leading_spaces: usize = if (!spec.left_adjust and !use_zero_width_pad) width_pad else 0;
    const width_zeroes: usize = if (use_zero_width_pad) width_pad else 0;
    const trailing_spaces: usize = if (spec.left_adjust) width_pad else 0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, ' ', leading_spaces);
    try out.appendSlice(allocator, prefix);
    try out.appendNTimes(allocator, '0', width_zeroes + precision_zeroes);
    try out.appendSlice(allocator, digits);
    try out.appendNTimes(allocator, ' ', trailing_spaces);
    return out.toOwnedSlice(allocator);
}

fn formatPrintfIntegerDigits(allocator: std.mem.Allocator, value: u64, base: PrintfIntegerBase) ![]u8 {
    return switch (base) {
        .decimal => std.fmt.allocPrint(allocator, "{d}", .{value}),
        .octal => std.fmt.allocPrint(allocator, "{o}", .{value}),
        .lower_hex => std.fmt.allocPrint(allocator, "{x}", .{value}),
        .upper_hex => std.fmt.allocPrint(allocator, "{X}", .{value}),
    };
}

fn appendPadded(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, spec: PrintfSpec) !void {
    const width = spec.width orelse 0;
    const pad_len = if (width > text.len) width - text.len else 0;
    const pad_byte: u8 = if (spec.zero_pad and !spec.left_adjust) '0' else ' ';
    if (!spec.left_adjust) try stdout.appendNTimes(allocator, pad_byte, pad_len);
    try stdout.appendSlice(allocator, text);
    if (spec.left_adjust) try stdout.appendNTimes(allocator, ' ', pad_len);
}

fn isPrintfFloatSpec(spec: u8) bool {
    return switch (spec) {
        'a', 'A', 'e', 'E', 'f', 'F', 'g', 'G' => true,
        else => false,
    };
}

fn appendPrintfFloatConversion(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    spec: PrintfSpec,
    arg: []const u8,
) !void {
    const value = try parsePrintfFloat(allocator, stderr, status, arg);

    var format_buffer: [64]u8 = undefined;
    const c_format = printfCFormat(&format_buffer, spec) catch unreachable;

    var stack_buffer: [128]u8 = undefined;
    const stack_len = snprintf(stack_buffer[0..].ptr, stack_buffer.len, c_format.ptr, value);
    if (stack_len < 0) {
        try printfDiagnostic(allocator, stderr, status, "invalid conversion");
        return;
    }
    const needed: usize = @intCast(stack_len);
    if (needed < stack_buffer.len) {
        try stdout.appendSlice(allocator, stack_buffer[0..needed]);
        return;
    }

    const heap_buffer = try allocator.alloc(u8, needed + 1);
    defer allocator.free(heap_buffer);
    const heap_len = snprintf(heap_buffer.ptr, heap_buffer.len, c_format.ptr, value);
    if (heap_len < 0) {
        try printfDiagnostic(allocator, stderr, status, "invalid conversion");
        return;
    }
    try stdout.appendSlice(allocator, heap_buffer[0..@min(@as(usize, @intCast(heap_len)), needed)]);
}

fn printfCFormat(buffer: []u8, spec: PrintfSpec) ![:0]u8 {
    var flags_buffer: [5]u8 = undefined;
    var flags_len: usize = 0;
    if (spec.left_adjust) {
        flags_buffer[flags_len] = '-';
        flags_len += 1;
    }
    if (spec.sign_plus) {
        flags_buffer[flags_len] = '+';
        flags_len += 1;
    }
    if (spec.sign_space) {
        flags_buffer[flags_len] = ' ';
        flags_len += 1;
    }
    if (spec.alternate) {
        flags_buffer[flags_len] = '#';
        flags_len += 1;
    }
    if (spec.zero_pad) {
        flags_buffer[flags_len] = '0';
        flags_len += 1;
    }
    const flags = flags_buffer[0..flags_len];

    if (spec.width) |width| {
        if (spec.precision) |precision| {
            return std.fmt.bufPrintSentinel(buffer, "%{s}{d}.{d}{c}", .{ flags, width, precision, spec.spec }, 0);
        }
        return std.fmt.bufPrintSentinel(buffer, "%{s}{d}{c}", .{ flags, width, spec.spec }, 0);
    }
    if (spec.precision) |precision| {
        return std.fmt.bufPrintSentinel(buffer, "%{s}.{d}{c}", .{ flags, precision, spec.spec }, 0);
    }
    return std.fmt.bufPrintSentinel(buffer, "%{s}{c}", .{ flags, spec.spec }, 0);
}

const PrintfIntegerConstant = struct {
    magnitude: u64,
    negative: bool = false,
    complete: bool = true,
    overflow: bool = false,
};

const PrintfMagnitude = struct {
    value: u64,
    overflow: bool = false,
};

const PrintfSignedValue = struct {
    value: i64,
    overflow: bool = false,
};

const PrintfUnsignedValue = struct {
    value: u64,
    overflow: bool = false,
};

fn parsePrintfSigned(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    stderr_before_stdout: *bool,
    arg: []const u8,
) !i64 {
    const parsed = parsePrintfIntegerConstant(arg) catch |err| switch (err) {
        error.InvalidCharacter => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
        error.Overflow => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
    };
    const converted = printfSignedValue(parsed);
    if (!parsed.complete or converted.overflow) try printfNumericDiagnostic(
        allocator,
        stderr,
        status,
        stderr_before_stdout,
    );
    return converted.value;
}

fn parsePrintfUnsigned(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    stderr_before_stdout: *bool,
    arg: []const u8,
) !u64 {
    const parsed = parsePrintfIntegerConstant(arg) catch |err| switch (err) {
        error.InvalidCharacter => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
        error.Overflow => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
    };
    const converted = printfUnsignedValue(parsed);
    if (!parsed.complete or converted.overflow) try printfNumericDiagnostic(
        allocator,
        stderr,
        status,
        stderr_before_stdout,
    );
    return converted.value;
}

fn printfSignedValue(parsed: PrintfIntegerConstant) PrintfSignedValue {
    if (!parsed.negative) {
        if (parsed.magnitude > std.math.maxInt(i64)) return .{ .value = std.math.maxInt(i64), .overflow = true };
        return .{ .value = @intCast(parsed.magnitude), .overflow = parsed.overflow };
    }
    const max_plus_one = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    if (parsed.magnitude == max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = parsed.overflow };
    if (parsed.magnitude > max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = true };
    return .{ .value = -@as(i64, @intCast(parsed.magnitude)), .overflow = parsed.overflow };
}

fn printfUnsignedValue(parsed: PrintfIntegerConstant) PrintfUnsignedValue {
    if (!parsed.negative) return .{ .value = parsed.magnitude, .overflow = parsed.overflow };
    if (parsed.overflow) return .{ .value = std.math.maxInt(u64), .overflow = true };
    return .{ .value = (~parsed.magnitude) +% 1 };
}

fn parsePrintfMagnitude(text: []const u8, base: u8) !PrintfMagnitude {
    const value = std.fmt.parseInt(u64, text, base) catch |err| switch (err) {
        error.Overflow => return .{ .value = std.math.maxInt(u64), .overflow = true },
        else => return err,
    };
    return .{ .value = value };
}

fn skipPrintfIntegerWhitespace(arg: []const u8, cursor: *usize) void {
    while (cursor.* < arg.len and std.ascii.isWhitespace(arg[cursor.*])) : (cursor.* += 1) {}
}

fn printfIntegerParseComplete(arg: []const u8, cursor: usize) bool {
    var trailing = cursor;
    skipPrintfIntegerWhitespace(arg, &trailing);
    return trailing == arg.len;
}

fn parsePrintfIntegerConstant(arg: []const u8) !PrintfIntegerConstant {
    if (arg.len == 0) return .{ .magnitude = 0 };
    if (arg[0] == '\'' or arg[0] == '"') return .{ .magnitude = if (arg.len > 1) arg[1] else 0 };

    var cursor: usize = 0;
    skipPrintfIntegerWhitespace(arg, &cursor);
    if (cursor >= arg.len) return error.InvalidCharacter;

    var negative = false;
    if (arg[cursor] == '+' or arg[cursor] == '-') {
        negative = arg[cursor] == '-';
        cursor += 1;
    }
    if (cursor >= arg.len or !std.ascii.isDigit(arg[cursor])) return error.InvalidCharacter;

    const digits_start: usize = cursor;
    var base: u8 = 10;
    if (arg[cursor] == '0') {
        base = 8;
        cursor += 1;
        if (cursor < arg.len and (arg[cursor] == 'x' or arg[cursor] == 'X')) {
            base = 16;
            cursor += 1;
            const hex_start = cursor;
            while (cursor < arg.len and std.ascii.isHex(arg[cursor])) : (cursor += 1) {}
            if (cursor == hex_start) return .{ .magnitude = 0, .negative = negative, .complete = false };
            const magnitude = try parsePrintfMagnitude(arg[hex_start..cursor], base);
            return .{
                .magnitude = magnitude.value,
                .negative = negative,
                .complete = printfIntegerParseComplete(arg, cursor),
                .overflow = magnitude.overflow,
            };
        }
        while (cursor < arg.len and arg[cursor] >= '0' and arg[cursor] <= '7') : (cursor += 1) {}
    } else {
        while (cursor < arg.len and std.ascii.isDigit(arg[cursor])) : (cursor += 1) {}
    }
    const magnitude = try parsePrintfMagnitude(arg[digits_start..cursor], base);
    return .{
        .magnitude = magnitude.value,
        .negative = negative,
        .complete = printfIntegerParseComplete(arg, cursor),
        .overflow = magnitude.overflow,
    };
}

fn parsePrintfFloat(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    status: *outcome.ExitStatus,
    arg: []const u8,
) !f64 {
    if (arg.len == 0) return 0;
    return std.fmt.parseFloat(f64, arg) catch {
        try printfDiagnostic(allocator, stderr, status, "numeric argument required");
        return 0;
    };
}

fn appendPrintfEscapedString(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8) !bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try stdout.append(allocator, text[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= text.len) {
            try stdout.append(allocator, '\\');
        } else if (!try appendEscapedSequence(allocator, stdout, text, &index, .percent_b)) {
            return false;
        }
    }
    return true;
}

const PrintfEscapeMode = enum { format, percent_b };

fn appendEscapedSequence(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    text: []const u8,
    index: *usize,
    mode: PrintfEscapeMode,
) !bool {
    const byte = text[index.*];
    switch (byte) {
        'a' => try stdout.append(allocator, 0x07),
        'b' => try stdout.append(allocator, 0x08),
        'c' => {
            if (mode == .format) {
                try stdout.append(allocator, '\\');
                return true;
            }
            index.* += 1;
            return false;
        },
        'f' => try stdout.append(allocator, 0x0c),
        'n' => try stdout.append(allocator, '\n'),
        'r' => try stdout.append(allocator, '\r'),
        't' => try stdout.append(allocator, '\t'),
        'v' => try stdout.append(allocator, 0x0b),
        '\\' => try stdout.append(allocator, '\\'),
        'x' => {
            try appendHexEscape(allocator, stdout, text, index);
            return true;
        },
        '0'...'7' => {
            try appendOctalEscape(allocator, stdout, text, index, mode);
            return true;
        },
        else => {
            try stdout.append(allocator, '\\');
            if (mode == .format) return true;
            try stdout.append(allocator, byte);
        },
    }
    index.* += 1;
    return true;
}

fn appendHexEscape(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, index: *usize) !void {
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = index.* + 1;
    while (cursor < text.len and count < 2) : (count += 1) {
        const digit = std.fmt.charToDigit(text[cursor], 16) catch break;
        value = value * 16 + digit;
        cursor += 1;
    }
    if (count == 0) {
        try stdout.append(allocator, '\\');
        try stdout.append(allocator, 'x');
        index.* += 1;
    } else {
        try stdout.append(allocator, value);
        index.* = cursor;
    }
}

fn appendOctalEscape(
    allocator: std.mem.Allocator,
    stdout: *std.ArrayList(u8),
    text: []const u8,
    index: *usize,
    mode: PrintfEscapeMode,
) !void {
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = index.*;
    if (mode == .percent_b and cursor < text.len and text[cursor] == '0') cursor += 1;
    while (cursor < text.len and count < 3 and text[cursor] >= '0' and text[cursor] <= '7') : (count += 1) {
        value = value * 8 + (text[cursor] - '0');
        cursor += 1;
    }
    if (count == 0) {
        try stdout.append(allocator, 0);
        index.* += 1;
    } else {
        try stdout.append(allocator, value);
        index.* = cursor;
    }
}

fn evaluateTestBuiltin(
    fs_port: ?runtime.fs.Port,
    fd_port: ?runtime.fd.Port,
    argv: []const []const u8,
) outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    const is_bracket = std.mem.eql(u8, argv[0], "[");
    const args = argv[1..];
    if (is_bracket) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) return 2;
        std.debug.assert(args.len != 0);
        std.debug.assert(std.mem.eql(u8, args[args.len - 1], "]"));
        const matched = evalTest(fs_port, fd_port, args[0 .. args.len - 1]) catch return 2;
        return if (matched) 0 else 1;
    }
    std.debug.assert(std.mem.eql(u8, argv[0], "test"));
    const matched = evalTest(fs_port, fd_port, args) catch return 2;
    return if (matched) 0 else 1;
}

const TestExpressionError = error{InvalidTestExpression};

fn evalTest(fs_port: ?runtime.fs.Port, fd_port: ?runtime.fd.Port, args: []const []const u8) TestExpressionError!bool {
    if (args.len == 3 and isBinaryTestOperator(args[1])) {
        return evalBinaryTest(fs_port, args[0], args[1], args[2]);
    }
    if (hasTestExpressionOperator(args)) {
        var test_parser: TestExpressionParser = .{ .fs_port = fs_port, .fd_port = fd_port, .args = args };
        const result = try test_parser.parseOr();
        if (test_parser.index != args.len) return error.InvalidTestExpression;
        return result;
    }
    return evalSimpleTest(fs_port, fd_port, args);
}

fn evalSimpleTest(
    fs_port: ?runtime.fs.Port,
    fd_port: ?runtime.fd.Port,
    args: []const []const u8,
) TestExpressionError!bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].len != 0,
        2 => evalUnaryTest(fs_port, fd_port, args[0], args[1]),
        3 => if (isBinaryTestOperator(args[1]))
            evalBinaryTest(fs_port, args[0], args[1], args[2])
        else if (std.mem.eql(u8, args[0], "!"))
            !(try evalSimpleTest(fs_port, fd_port, args[1..]))
        else
            error.InvalidTestExpression,
        4 => if (std.mem.eql(u8, args[0], "!")) !(try evalSimpleTest(
            fs_port,
            fd_port,
            args[1..],
        )) else error.InvalidTestExpression,
        else => error.InvalidTestExpression,
    };
}

fn hasTestExpressionOperator(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(
            u8,
            arg,
            "-o",
        ) or std.mem.eql(u8, arg, "(") or std.mem.eql(u8, arg, ")")) return true;
    }
    return false;
}

const TestExpressionParser = struct {
    fs_port: ?runtime.fs.Port,
    fd_port: ?runtime.fd.Port,
    args: []const []const u8,
    index: usize = 0,

    fn parseOr(self: *TestExpressionParser) TestExpressionError!bool {
        var result = try self.parseAnd();
        while (self.match("-o")) {
            const rhs = try self.parseAnd();
            result = result or rhs;
        }
        return result;
    }

    fn parseAnd(self: *TestExpressionParser) TestExpressionError!bool {
        var result = try self.parseNot();
        while (self.match("-a")) {
            const rhs = try self.parseNot();
            result = result and rhs;
        }
        return result;
    }

    fn parseNot(self: *TestExpressionParser) TestExpressionError!bool {
        if (self.match("!")) return !(try self.parseNot());
        return self.parsePrimary();
    }

    fn parsePrimary(self: *TestExpressionParser) TestExpressionError!bool {
        if (self.index >= self.args.len) return error.InvalidTestExpression;
        if (self.match("(")) {
            const result = try self.parseOr();
            if (!self.match(")")) return error.InvalidTestExpression;
            return result;
        }
        if (self.index + 2 < self.args.len and isBinaryTestOperator(self.args[self.index + 1])) {
            const left = self.args[self.index];
            const op = self.args[self.index + 1];
            const right = self.args[self.index + 2];
            self.index += 3;
            return evalBinaryTest(self.fs_port, left, op, right);
        }
        if (self.index + 1 < self.args.len and isUnaryTestOperator(self.args[self.index])) {
            const op = self.args[self.index];
            const operand = self.args[self.index + 1];
            self.index += 2;
            return evalUnaryTest(self.fs_port, self.fd_port, op, operand);
        }
        const value = self.args[self.index].len != 0;
        self.index += 1;
        return value;
    }

    fn match(self: *TestExpressionParser, text: []const u8) bool {
        if (self.index >= self.args.len or !std.mem.eql(u8, self.args[self.index], text)) return false;
        self.index += 1;
        return true;
    }
};

fn isUnaryTestOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "!") or std.mem.eql(u8, op, "-n") or std.mem.eql(u8, op, "-z") or
        std.mem.eql(u8, op, "-e") or std.mem.eql(u8, op, "-f") or std.mem.eql(u8, op, "-d") or std.mem.eql(
        u8,
        op,
        "-s",
    ) or
        std.mem.eql(u8, op, "-b") or std.mem.eql(u8, op, "-c") or std.mem.eql(u8, op, "-p") or std.mem.eql(
        u8,
        op,
        "-S",
    ) or
        std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h") or std.mem.eql(u8, op, "-u") or std.mem.eql(
        u8,
        op,
        "-g",
    ) or
        std.mem.eql(u8, op, "-k") or std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(
        u8,
        op,
        "-x",
    ) or
        std.mem.eql(u8, op, "-t");
}

fn isBinaryTestOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "-eq") or std.mem.eql(
        u8,
        op,
        "-ne",
    ) or
        std.mem.eql(u8, op, "-gt") or std.mem.eql(u8, op, "-ge") or std.mem.eql(u8, op, "-lt") or std.mem.eql(
        u8,
        op,
        "-le",
    ) or
        std.mem.eql(u8, op, "-ef") or std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot");
}

fn evalUnaryTest(
    fs_port: ?runtime.fs.Port,
    fd_port: ?runtime.fd.Port,
    op: []const u8,
    operand: []const u8,
) TestExpressionError!bool {
    if (std.mem.eql(u8, op, "!")) return operand.len == 0;
    if (std.mem.eql(u8, op, "-n")) return operand.len != 0;
    if (std.mem.eql(u8, op, "-z")) return operand.len == 0;

    if (std.mem.eql(u8, op, "-e") or
        std.mem.eql(u8, op, "-f") or
        std.mem.eql(u8, op, "-d") or
        std.mem.eql(u8, op, "-s") or
        std.mem.eql(u8, op, "-b") or
        std.mem.eql(u8, op, "-c") or
        std.mem.eql(u8, op, "-p") or
        std.mem.eql(u8, op, "-S"))
    {
        const metadata = inspectTestPath(fs_port, operand, true) orelse return false;
        if (std.mem.eql(u8, op, "-e")) return true;
        if (std.mem.eql(u8, op, "-f")) return metadata.stat.kind == .file;
        if (std.mem.eql(u8, op, "-d")) return metadata.stat.kind == .directory;
        if (std.mem.eql(u8, op, "-s")) return metadata.stat.size > 0;
        if (std.mem.eql(u8, op, "-b")) return metadata.stat.kind == .block_device;
        if (std.mem.eql(u8, op, "-c")) return metadata.stat.kind == .character_device;
        if (std.mem.eql(u8, op, "-p")) return metadata.stat.kind == .named_pipe;
        if (std.mem.eql(u8, op, "-S")) return metadata.stat.kind == .unix_domain_socket;
    }
    if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
        const metadata = inspectTestPath(fs_port, operand, false) orelse return false;
        return metadata.stat.kind == .sym_link;
    }
    if (std.mem.eql(u8, op, "-u") or std.mem.eql(u8, op, "-g") or std.mem.eql(u8, op, "-k")) {
        const metadata = inspectTestPath(fs_port, operand, false) orelse return false;
        const mode = metadata.stat.permissions.toMode();
        if (std.mem.eql(u8, op, "-u")) return mode & 0o4000 != 0;
        if (std.mem.eql(u8, op, "-g")) return mode & 0o2000 != 0;
        if (std.mem.eql(u8, op, "-k")) return mode & 0o1000 != 0;
    }
    if (std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(u8, op, "-x")) {
        const port = fs_port orelse return false;
        if (operand.len == 0) return false;
        const request: runtime.fs.AccessRequest = .{
            .path = operand,
            .read = std.mem.eql(u8, op, "-r"),
            .write = std.mem.eql(u8, op, "-w"),
            .execute = std.mem.eql(u8, op, "-x"),
        };
        request.validate();
        port.access(request) catch return false;
        return true;
    }
    if (std.mem.eql(u8, op, "-t")) {
        const descriptor = std.fmt.parseInt(
            runtime.fd.Descriptor,
            operand,
            10,
        ) catch return error.InvalidTestExpression;
        if (!runtime.fd.isValidDescriptor(descriptor)) return false;
        const port = fd_port orelse {
            std.debug.assert(false);
            return false;
        };
        const request = runtime.fd.IsTtyRequest.init(descriptor);
        const result = port.isTty(request) catch return false;
        result.validate();
        return result.is_tty;
    }
    return error.InvalidTestExpression;
}

fn evalBinaryTest(
    fs_port: ?runtime.fs.Port,
    left: []const u8,
    op: []const u8,
    right: []const u8,
) TestExpressionError!bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "<")) return std.mem.lessThan(u8, left, right);
    if (std.mem.eql(u8, op, ">")) return std.mem.lessThan(u8, right, left);

    if (std.mem.eql(u8, op, "-ef") or std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot")) {
        return evalFileComparisonTest(fs_port, left, op, right);
    }

    const lhs = parseTestInteger(left) orelse return error.InvalidTestExpression;
    const rhs = parseTestInteger(right) orelse return error.InvalidTestExpression;
    if (std.mem.eql(u8, op, "-eq")) return lhs == rhs;
    if (std.mem.eql(u8, op, "-ne")) return lhs != rhs;
    if (std.mem.eql(u8, op, "-gt")) return lhs > rhs;
    if (std.mem.eql(u8, op, "-ge")) return lhs >= rhs;
    if (std.mem.eql(u8, op, "-lt")) return lhs < rhs;
    if (std.mem.eql(u8, op, "-le")) return lhs <= rhs;
    return error.InvalidTestExpression;
}

fn inspectTestPath(fs_port: ?runtime.fs.Port, path: []const u8, follow_symlinks: bool) ?runtime.fs.InspectPathResult {
    const port = fs_port orelse return null;
    if (path.len == 0) return null;
    const request: runtime.fs.InspectPathRequest = .{ .path = path, .follow_symlinks = follow_symlinks };
    request.validate();
    const result = port.inspectPath(request) catch return null;
    result.validate();
    return result;
}

fn evalFileComparisonTest(fs_port: ?runtime.fs.Port, left: []const u8, op: []const u8, right: []const u8) bool {
    const left_metadata = inspectTestPath(fs_port, left, true);
    const right_metadata = inspectTestPath(fs_port, right, true);

    if (std.mem.eql(u8, op, "-ef")) {
        const lhs = left_metadata orelse return false;
        const rhs = right_metadata orelse return false;
        if (lhs.identity) |left_identity| {
            if (rhs.identity) |right_identity|
                return left_identity.device == right_identity.device and
                    left_identity.inode == right_identity.inode;
        }
        return lhs.stat.inode == rhs.stat.inode;
    }
    if (std.mem.eql(u8, op, "-nt")) {
        const lhs = left_metadata orelse return false;
        const rhs = right_metadata orelse return true;
        return lhs.stat.mtime.nanoseconds > rhs.stat.mtime.nanoseconds;
    }
    if (std.mem.eql(u8, op, "-ot")) {
        const rhs = right_metadata orelse return false;
        const lhs = left_metadata orelse return true;
        return lhs.stat.mtime.nanoseconds < rhs.stat.mtime.nanoseconds;
    }
    unreachable;
}

fn parseTestInteger(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn assertCommandDeltaCompatible(plan: command_plan.CommandPlan, state_delta: delta.StateDelta) void {
    switch (plan.classification) {
        .empty, .assignment_only => return,
        .function_definition => |definition| {
            definition.validate();
            std.debug.assert(state_delta.target == plan.target);
            std.debug.assert(state_delta.function_sets.items.len == 1);
            std.debug.assert(std.mem.eql(u8, state_delta.function_sets.items[0].name, definition.name));
            std.debug.assert(state_delta.last_status != null);
            return;
        },
        .external, .not_found => {
            std.debug.assert(state_delta.target == plan.target);
            std.debug.assert(state_delta.variable_assignments.items.len == 0);
            std.debug.assert(state_delta.variable_flags.items.len == 0);
            std.debug.assert(state_delta.variable_unsets.items.len == 0);
            std.debug.assert(state_delta.function_sets.items.len == 0);
            std.debug.assert(state_delta.function_unsets.items.len == 0);
            std.debug.assert(state_delta.option_changes.items.len == 0);
            std.debug.assert(state_delta.shopt_changes.items.len == 0);
            std.debug.assert(state_delta.alias_sets.items.len == 0);
            std.debug.assert(state_delta.alias_unsets.items.len == 0);
            std.debug.assert(!state_delta.clear_aliases);
            std.debug.assert(state_delta.trap_mutations.items.len == 0);
            std.debug.assert(state_delta.pending_trap_enqueues.items.len == 0);
            std.debug.assert(state_delta.pending_trap_consume_count == 0);
            std.debug.assert(state_delta.pending_exit == null);
            std.debug.assert(!state_delta.clear_pending_exit);
            std.debug.assert(state_delta.positionals == null);
            std.debug.assert(state_delta.logical_cwd == null);
            std.debug.assert(state_delta.last_status != null);
            return;
        },
        .function => {
            std.debug.assert(state_delta.target == plan.target);
            std.debug.assert(state_delta.positionals == null);
            std.debug.assert(state_delta.last_status != null);
            return;
        },
        .special_builtin, .regular_builtin => {},
    }

    const definition = switch (plan.classification) {
        .special_builtin, .regular_builtin => |definition| definition,
        else => unreachable,
    };
    definition.validate();
    if (!definition.isSemanticallyNonMutating()) {
        std.debug.assert(definition.semantic_class.isStateful());
        std.debug.assert(state_delta.target == plan.target);
        return;
    }

    std.debug.assert(state_delta.variable_flags.items.len == 0);
    std.debug.assert(state_delta.variable_unsets.items.len == 0);
    std.debug.assert(state_delta.function_sets.items.len == 0);
    std.debug.assert(state_delta.function_unsets.items.len == 0);
    std.debug.assert(state_delta.option_changes.items.len == 0);
    std.debug.assert(state_delta.shopt_changes.items.len == 0);
    std.debug.assert(state_delta.alias_sets.items.len == 0);
    std.debug.assert(state_delta.alias_unsets.items.len == 0);
    std.debug.assert(!state_delta.clear_aliases);
    std.debug.assert(state_delta.trap_mutations.items.len == 0);
    std.debug.assert(state_delta.pending_trap_enqueues.items.len == 0);
    std.debug.assert(state_delta.pending_trap_consume_count == 0);
    std.debug.assert(state_delta.pending_exit == null);
    std.debug.assert(!state_delta.clear_pending_exit);
    std.debug.assert(state_delta.positionals == null);
    std.debug.assert(state_delta.logical_cwd == null);
    std.debug.assert(state_delta.last_status != null);
    if (plan.assignmentEffect() != .persistent) std.debug.assert(state_delta.variable_assignments.items.len == 0);
}

test "semantic evaluator executes colon true and false builtins" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const colon_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{":"} } });
    var colon = try evaluatePlan(&evaluator, &shell_state, eval_context, colon_plan);
    defer colon.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), colon.status);
    try std.testing.expectEqualStrings("", colon.stdout.items);
    try colon.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);

    const true_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } });
    var true_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, true_plan);
    defer true_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), true_outcome.status);
    try true_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);

    const false_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"false"} } });
    var false_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, false_plan);
    defer false_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), false_outcome.status);
    try false_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 1), shell_state.last_status);
}

test "semantic evaluator captures echo output in CommandOutcome" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const echo_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "echo",
        "hello",
        "world",
    } } });
    var echo_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, echo_plan);
    defer echo_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), echo_outcome.status);
    try std.testing.expectEqualStrings("hello world\n", echo_outcome.stdout.items);
    try std.testing.expect(echo_outcome.state_delta.variable_assignments.items.len == 0);
    try echo_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);

    const escaped_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "echo",
        "-n",
        "a\\nb\\c",
        "ignored",
    } } });
    var escaped = try evaluatePlan(&evaluator, &shell_state, eval_context, escaped_plan);
    defer escaped.deinit();
    try std.testing.expectEqualStrings("a\nb", escaped.stdout.items);
    escaped.discardDelta(.current_shell);
}

test "cd logical path resolution preserves path spelling" {
    const relative = try resolveLogicalCdPath(std.testing.allocator, "/tmp/logical", "link/../next");
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("/tmp/logical/next", relative);

    const absolute = try resolveLogicalCdPath(std.testing.allocator, "/tmp/logical", "/other/link");
    defer std.testing.allocator.free(absolute);
    try std.testing.expectEqualStrings("/other/link", absolute);
}

test "semantic evaluator dispatches custom extension builtin handlers" {
    const CustomExtension = struct {
        fn lookup(_: ?*anyopaque, name: []const u8) ?extension_api.HandlerSpec {
            if (!std.mem.eql(u8, name, "custom_builtin")) return null;
            return .{ .handler = evaluate };
        }

        fn evaluate(_: ?*anyopaque, invocation: *extension_api.Invocation) !extension_api.EvaluationResult {
            std.debug.assert(invocation.argv.len != 0);
            std.debug.assert(std.mem.eql(u8, invocation.argv[0], "custom_builtin"));
            try invocation.stdout.appendSlice(invocation.allocator, "custom output\n");
            return extension_api.EvaluationResult.normal(0);
        }
    };

    var registry = builtin.BuiltinRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(builtin.Builtin.initExtension("custom_builtin", .output));

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    evaluator.setExtensionHandlerLookup(null, CustomExtension.lookup);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"custom_builtin"} },
        .lookup = .{ .builtins = registry.slice() },
    });
    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("custom output\n", result.stdout.items);
}

test "semantic evaluator dispatches source as a compat extension builtin" {
    const path = "rush-source-extension-test.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\echo sourced
        \\SOURCED_VALUE=ok
        \\return 7
        \\echo after-return
    });

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    evaluator.io = std.testing.io;
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "source",
        path,
    } } });

    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, result.control_flow);
    try std.testing.expectEqualStrings("sourced\n", result.stdout.items);
    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("SOURCED_VALUE").?.value);
}

test "semantic evaluator dispatches color as a Rush extension builtin" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const dim = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "color",
        "dim",
        "#204080",
        "25",
    } } });
    var dim_result = try evaluatePlan(&evaluator, &shell_state, eval_context, dim);
    defer dim_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), dim_result.status);
    try std.testing.expectEqualStrings("#183060\n", dim_result.stdout.items);

    const blend = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "color",
        "blend",
        "#000000",
        "#ffffff",
        "50",
    } } });
    var blend_result = try evaluatePlan(&evaluator, &shell_state, eval_context, blend);
    defer blend_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), blend_result.status);
    try std.testing.expectEqualStrings("#808080\n", blend_result.stdout.items);

    const invalid = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "color",
        "dim",
        "blue",
        "25",
    } } });
    var invalid_result = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid);
    defer invalid_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), invalid_result.status);
    try std.testing.expectEqualStrings("", invalid_result.stdout.items);
    try std.testing.expectEqualStrings("color: invalid color\n", invalid_result.stderr.items);
}

test "semantic evaluator evaluates times through process runtime" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setProcessTimes(.{
        .shell_user = .{ .microseconds = 61_230_000 },
        .shell_system = .{ .microseconds = 500_000 },
        .children_user = .{ .microseconds = 3_004_000 },
        .children_system = .{ .microseconds = 0 },
    });
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"times"} } });
    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("1m1.23s 0m0.50s\n0m3.00s 0m0.00s\n", result.stdout.items);

    const invalid_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "times",
        "now",
    } } });
    var invalid_result = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_plan);
    defer invalid_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), invalid_result.status);
    try std.testing.expectEqualStrings("times: too many arguments\n", invalid_result.stderr.items);
}

test "semantic evaluator evaluates ulimit file-size resource" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setResourceLimits(.{
        .soft = .{ .bytes = 1024 },
        .hard = .unlimited,
    });
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const print_soft_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"ulimit"} },
    });
    var print_soft = try evaluatePlan(&evaluator, &shell_state, eval_context, print_soft_plan);
    defer print_soft.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), print_soft.status);
    try std.testing.expectEqualStrings("2\n", print_soft.stdout.items);

    const print_hard_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "ulimit",
        "-Hf",
    } } });
    var print_hard = try evaluatePlan(&evaluator, &shell_state, eval_context, print_hard_plan);
    defer print_hard.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), print_hard.status);
    try std.testing.expectEqualStrings("unlimited\n", print_hard.stdout.items);

    const set_soft_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "ulimit",
        "4",
    } } });
    var set_soft = try evaluatePlan(&evaluator, &shell_state, eval_context, set_soft_plan);
    defer set_soft.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), set_soft.status);
    try std.testing.expectEqual(@as(usize, 1), fake.set_resource_limit_count);
    try std.testing.expectEqual(@as(u64, 2048), fake.resource_limits.soft.bytes);

    const invalid_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "ulimit",
        "-x",
    } } });
    var invalid_result = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_plan);
    defer invalid_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), invalid_result.status);
    try std.testing.expectEqualStrings("ulimit: unsupported option\n", invalid_result.stderr.items);
}

test "semantic evaluator evaluates fc history listing and substitution" {
    const history = [_]CommandHistoryEntry{
        .{ .number = 1, .text = "echo one" },
        .{ .number = 2, .text = "echo two" },
        .{ .number = 3, .text = "VALUE=old" },
    };
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    evaluator.setHistoryEntries(&history);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const list_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "fc",
        "-ln",
        "2",
        "3",
    } } });
    var list_result = try evaluatePlan(&evaluator, &shell_state, eval_context, list_plan);
    defer list_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), list_result.status);
    try std.testing.expectEqualStrings("echo two\nVALUE=old\n", list_result.stdout.items);

    const substitute_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "fc",
        "-s",
        "old=new",
        "VALUE=old",
    } } });
    var substitute_result = try evaluatePlan(&evaluator, &shell_state, eval_context, substitute_plan);
    defer substitute_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), substitute_result.status);
    try std.testing.expectEqualStrings("VALUE=new\n", substitute_result.stdout.items);
    try substitute_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("new", shell_state.getVariable("VALUE").?.value);
}

test "semantic evaluator evaluates umask through filesystem runtime" {
    var fake_fs = FakeFsRuntime.init();
    fake_fs.file_creation_mask = 0o022;
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.initWithFsPort(std.testing.allocator, fake_fs.port());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const print_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"umask"} } });
    var print_result = try evaluatePlan(&evaluator, &shell_state, eval_context, print_plan);
    defer print_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), print_result.status);
    try std.testing.expectEqualStrings("0022\n", print_result.stdout.items);
    try std.testing.expectEqual(@as(runtime.fs.FileCreationMask, 0o022), fake_fs.file_creation_mask);
    try std.testing.expectEqual(@as(usize, 2), fake_fs.file_creation_mask_change_count);

    const symbolic_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "umask",
        "-S",
    } } });
    var symbolic_result = try evaluatePlan(&evaluator, &shell_state, eval_context, symbolic_plan);
    defer symbolic_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), symbolic_result.status);
    try std.testing.expectEqualStrings("u=rwx,g=rx,o=rx\n", symbolic_result.stdout.items);
    try std.testing.expectEqual(@as(runtime.fs.FileCreationMask, 0o022), fake_fs.file_creation_mask);

    const set_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "umask",
        "077",
    } } });
    var set_result = try evaluatePlan(&evaluator, &shell_state, eval_context, set_plan);
    defer set_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), set_result.status);
    try std.testing.expectEqualStrings("", set_result.stdout.items);
    try std.testing.expectEqual(@as(runtime.fs.FileCreationMask, 0o077), fake_fs.file_creation_mask);

    const invalid_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "umask",
        "888",
    } } });
    var invalid_result = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_plan);
    defer invalid_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), invalid_result.status);
    try std.testing.expectEqualStrings("umask: invalid mask\n", invalid_result.stderr.items);
}

test "semantic evaluator evaluates hash through command search" {
    var fake_fs = FakeFsRuntime.init();
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.initWithFsPort(std.testing.allocator, fake_fs.port());
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const assignments = [_]command_plan.Assignment{.{ .name = "PATH", .value = "/fake/bin" }};

    const found_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{ "hash", "tool" },
    } });
    var found_result = try evaluatePlan(&evaluator, &shell_state, eval_context, found_plan);
    defer found_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), found_result.status);
    try std.testing.expectEqualStrings("", found_result.stdout.items);
    try std.testing.expectEqualStrings("", found_result.stderr.items);

    const reset_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "hash",
        "-r",
    } } });
    var reset_result = try evaluatePlan(&evaluator, &shell_state, eval_context, reset_plan);
    defer reset_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), reset_result.status);

    const missing_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{ "hash", "missing-tool" },
    } });
    var missing_result = try evaluatePlan(&evaluator, &shell_state, eval_context, missing_plan);
    defer missing_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), missing_result.status);
    try std.testing.expectEqualStrings("hash: missing-tool: not found\n", missing_result.stderr.items);

    const option_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "hash",
        "-x",
    } } });
    var option_result = try evaluatePlan(&evaluator, &shell_state, eval_context, option_plan);
    defer option_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), option_result.status);
    try std.testing.expectEqualStrings("hash: unsupported option\n", option_result.stderr.items);
}

test "semantic evaluator evaluates getopts over positional parameters" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.replacePositionals(&.{ "-ab", "-c", "value", "rest" });
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const first_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "getopts",
        "abc:",
        "opt",
    } } });
    var first = try evaluatePlan(&evaluator, &shell_state, eval_context, first_plan);
    defer first.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), first.status);
    try first.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("a", shell_state.getVariable("opt").?.value);
    try std.testing.expectEqualStrings("1", shell_state.getVariable("OPTIND").?.value);

    var second = try evaluatePlan(&evaluator, &shell_state, eval_context, first_plan);
    defer second.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), second.status);
    try second.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("b", shell_state.getVariable("opt").?.value);
    try std.testing.expectEqualStrings("2", shell_state.getVariable("OPTIND").?.value);

    var third = try evaluatePlan(&evaluator, &shell_state, eval_context, first_plan);
    defer third.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), third.status);
    try third.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("c", shell_state.getVariable("opt").?.value);
    try std.testing.expectEqualStrings("value", shell_state.getVariable("OPTARG").?.value);
    try std.testing.expectEqualStrings("4", shell_state.getVariable("OPTIND").?.value);

    var end = try evaluatePlan(&evaluator, &shell_state, eval_context, first_plan);
    defer end.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), end.status);
    try end.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("?", shell_state.getVariable("opt").?.value);
    try std.testing.expectEqualStrings("4", shell_state.getVariable("OPTIND").?.value);
}

test "semantic evaluator evaluates getopts diagnostics and silent mode" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const invalid_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "getopts",
        "a",
        "opt",
        "-x",
    } } });
    var invalid = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_plan);
    defer invalid.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), invalid.status);
    try std.testing.expectEqualStrings("getopts: invalid option\n", invalid.stderr.items);
    try invalid.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("?", shell_state.getVariable("opt").?.value);

    try shell_state.putVariable("OPTIND", "1", .{});
    const silent_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "getopts",
        ":a:",
        "opt",
        "-a",
    } } });
    var silent = try evaluatePlan(&evaluator, &shell_state, eval_context, silent_plan);
    defer silent.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), silent.status);
    try std.testing.expectEqualStrings("", silent.stderr.items);
    try silent.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings(":", shell_state.getVariable("opt").?.value);
    try std.testing.expectEqualStrings("a", shell_state.getVariable("OPTARG").?.value);
}

test "semantic evaluator evaluates kill through signal runtime" {
    var fake_signal = FakeSignalRuntime.init();
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.initWithSignalPort(std.testing.allocator, fake_signal.port());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const default_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "kill",
        "123",
    } } });
    var default_result = try evaluatePlan(&evaluator, &shell_state, eval_context, default_plan);
    defer default_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), default_result.status);
    try std.testing.expectEqual(@as(usize, 1), fake_signal.send_count);
    try std.testing.expectEqual(@as(i32, 123), fake_signal.sent_processes[0]);
    try std.testing.expectEqual(signalNumber(.TERM), fake_signal.sent_signals[0]);

    const explicit_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "kill",
        "-s",
        "HUP",
        "456",
    } } });
    var explicit_result = try evaluatePlan(&evaluator, &shell_state, eval_context, explicit_plan);
    defer explicit_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), explicit_result.status);
    try std.testing.expectEqual(@as(usize, 2), fake_signal.send_count);
    try std.testing.expectEqual(@as(i32, 456), fake_signal.sent_processes[1]);
    try std.testing.expectEqual(signalNumber(.HUP), fake_signal.sent_signals[1]);

    const zero_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "kill",
        "-s",
        "0",
        "456",
    } } });
    var zero_result = try evaluatePlan(&evaluator, &shell_state, eval_context, zero_plan);
    defer zero_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), zero_result.status);
    try std.testing.expectEqual(@as(usize, 3), fake_signal.send_count);
    try std.testing.expectEqual(@as(i32, 456), fake_signal.sent_processes[2]);
    try std.testing.expectEqual(@as(u8, 0), fake_signal.sent_signals[2]);

    const group_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "kill",
        "-TERM",
        "--",
        "-789",
    } } });
    var group_result = try evaluatePlan(&evaluator, &shell_state, eval_context, group_plan);
    defer group_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), group_result.status);
    try std.testing.expectEqual(@as(i32, -789), fake_signal.sent_processes[3]);
    try std.testing.expectEqual(signalNumber(.TERM), fake_signal.sent_signals[3]);

    const list_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "kill",
        "-l",
        "143",
    } } });
    var list_result = try evaluatePlan(&evaluator, &shell_state, eval_context, list_plan);
    defer list_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), list_result.status);
    try std.testing.expectEqualStrings("TERM\n", list_result.stdout.items);

    const invalid_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "kill",
        "not-a-pid",
    } } });
    var invalid_result = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_plan);
    defer invalid_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), invalid_result.status);
    try std.testing.expectEqualStrings("kill: not-a-pid: invalid process id\n", invalid_result.stderr.items);
}

test "semantic evaluator dispatches shopt as a compat extension builtin" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const query_default = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shopt",
        "-q",
        "expand_aliases",
    } } });
    var query_default_result = try evaluatePlan(&evaluator, &shell_state, eval_context, query_default);
    defer query_default_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), query_default_result.status);

    const unset = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shopt",
        "-u",
        "expand_aliases",
    } } });
    var unset_result = try evaluatePlan(&evaluator, &shell_state, eval_context, unset);
    defer unset_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), unset_result.status);
    try unset_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expect(!shell_state.shopts.enabled(.expand_aliases));

    const query_unset = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shopt",
        "-q",
        "expand_aliases",
    } } });
    var query_unset_result = try evaluatePlan(&evaluator, &shell_state, eval_context, query_unset);
    defer query_unset_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), query_unset_result.status);

    const reusable = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shopt",
        "-p",
        "expand_aliases",
    } } });
    var reusable_result = try evaluatePlan(&evaluator, &shell_state, eval_context, reusable);
    defer reusable_result.deinit();
    try std.testing.expectEqualStrings("shopt -u expand_aliases\n", reusable_result.stdout.items);
}

test "shopt expand_aliases affects subsequently sourced text" {
    const path = "rush-shopt-expand-aliases-test.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "say\n" });

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setAlias("say", "echo alias-hit");
    var evaluator = Evaluator.init(std.testing.allocator);
    evaluator.io = std.testing.io;
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const disable = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shopt",
        "-u",
        "expand_aliases",
    } } });
    var disable_result = try evaluatePlan(&evaluator, &shell_state, eval_context, disable);
    defer disable_result.deinit();
    try disable_result.commitDelta(&shell_state, .current_shell);

    const source = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "source",
        path,
    } } });
    var disabled_source = try evaluatePlan(&evaluator, &shell_state, eval_context, source);
    defer disabled_source.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 127), disabled_source.status);
    try std.testing.expectEqualStrings("", disabled_source.stdout.items);

    const enable = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shopt",
        "-s",
        "expand_aliases",
    } } });
    var enable_result = try evaluatePlan(&evaluator, &shell_state, eval_context, enable);
    defer enable_result.deinit();
    try enable_result.commitDelta(&shell_state, .current_shell);

    var enabled_source = try evaluatePlan(&evaluator, &shell_state, eval_context, source);
    defer enabled_source.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), enabled_source.status);
    try std.testing.expectEqualStrings("alias-hit\n", enabled_source.stdout.items);
}

test "semantic evaluator dispatches type as a compat extension builtin" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setAlias("ll", "ls -l");
    try shell_state.putFunctionName("helper");

    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "type",
        ":",
        "helper",
        "ll",
        "printf",
        "missing",
    } } });

    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings(
        \\: is a special shell builtin
        \\helper is a shell function
        \\ll is an alias for 'ls -l'
        \\printf is a shell builtin
        \\
    , result.stdout.items);
    try std.testing.expectEqualStrings("type: missing: not found\n", result.stderr.items);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
}

test "command builtin lookup reports shell functions" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunctionName("helper");

    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "command",
        "-v",
        "helper",
    } } });

    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("helper\n", result.stdout.items);
}

test "command builtin preserves state effects from the selected utility" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "command",
        "export",
        "VALUE=ok",
    } } });

    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("VALUE").?.value);
    try std.testing.expect(shell_state.getVariable("VALUE").?.exported);
}

test "semantic evaluator treats empty command names as not found" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{""} } });

    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings(": command not found\n", result.stderr.items);
    try std.testing.expectEqualStrings(": command not found", result.diagnostics.items[0].message);
}

test "type compat extension resolves external commands through evaluator runtime" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    var evaluator = Evaluator.initWithFsPort(std.testing.allocator, adapter.fsPort());
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const assignments = [_]command_plan.Assignment{.{ .name = "PATH", .value = "/bin" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{ "type", "sh" },
    } });

    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("sh is /bin/sh\n", result.stdout.items);
}

test "type compat extension supports bash-style lookup options" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunctionName("helper");
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    var evaluator = Evaluator.initWithFsPort(std.testing.allocator, adapter.fsPort());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const type_words = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "type",
        "-t",
        "printf",
        "helper",
    } } });
    var type_words_result = try evaluatePlan(&evaluator, &shell_state, eval_context, type_words);
    defer type_words_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), type_words_result.status);
    try std.testing.expectEqualStrings("builtin\nfunction\n", type_words_result.stdout.items);

    const path_only_builtin = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "type",
        "-p",
        "printf",
        "helper",
    } } });
    var path_only_builtin_result = try evaluatePlan(&evaluator, &shell_state, eval_context, path_only_builtin);
    defer path_only_builtin_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), path_only_builtin_result.status);
    try std.testing.expectEqualStrings("", path_only_builtin_result.stdout.items);

    const assignments = [_]command_plan.Assignment{.{ .name = "PATH", .value = "/bin" }};
    const forced_path = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{ "type", "-P", "sh" },
    } });
    var forced_path_result = try evaluatePlan(&evaluator, &shell_state, eval_context, forced_path);
    defer forced_path_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), forced_path_result.status);
    try std.testing.expectEqualStrings("sh is /bin/sh\n", forced_path_result.stdout.items);

    const all_path_words = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{ "type", "-at", "sh" },
    } });
    var all_path_words_result = try evaluatePlan(&evaluator, &shell_state, eval_context, all_path_words);
    defer all_path_words_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), all_path_words_result.status);
    try std.testing.expectEqualStrings("file\n", all_path_words_result.stdout.items);

    const suppressed_function = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "type",
        "-f",
        "helper",
    } } });
    var suppressed_function_result = try evaluatePlan(&evaluator, &shell_state, eval_context, suppressed_function);
    defer suppressed_function_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), suppressed_function_result.status);
    try std.testing.expectEqualStrings("type: helper: not found\n", suppressed_function_result.stderr.items);
}

test "semantic evaluator executes string and integer test predicates" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const true_string = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "test",
        "-n",
        "value",
    } } });
    var true_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, true_string);
    defer true_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), true_outcome.status);
    try std.testing.expectEqual(@as(usize, 0), true_outcome.diagnostics.items.len);
    true_outcome.discardDelta(.current_shell);

    const false_integer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "test",
        "2",
        "-gt",
        "3",
    } } });
    var false_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, false_integer);
    defer false_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), false_outcome.status);
    false_outcome.discardDelta(.current_shell);

    const bracket_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "[",
        "a",
        "=",
        "a",
        "]",
    } } });
    var bracket_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, bracket_plan);
    defer bracket_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), bracket_outcome.status);
    bracket_outcome.discardDelta(.current_shell);

    const invalid_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "[",
        "a",
        "=",
    } } });
    var invalid = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_plan);
    defer invalid.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), invalid.status);
    try std.testing.expectEqualStrings("[: missing ]", invalid.diagnostics.items[0].message);
    invalid.discardDelta(.current_shell);
}

test "semantic evaluator routes test -t through fd runtime port" {
    const FakeFdRuntime = struct {
        const Self = @This();

        requested_descriptor: ?runtime.fd.Descriptor = null,
        tty_descriptor: runtime.fd.Descriptor = 7,

        fn port(self: *Self) runtime.fd.Port {
            return .{
                .context = self,
                .open_fn = open,
                .close_fn = close,
                .duplicate_fn = duplicate,
                .duplicate_to_fn = duplicateTo,
                .pipe_fn = pipe,
                .write_fn = writeAll,
                .is_tty_fn = isTty,
            };
        }

        fn fromContext(context_value: *anyopaque) *Self {
            return @ptrCast(@alignCast(context_value));
        }

        fn open(_: *anyopaque, _: runtime.fd.OpenRequest) runtime.fd.OpenError!runtime.fd.OpenResult {
            unreachable;
        }

        fn close(_: *anyopaque, _: runtime.fd.CloseRequest) runtime.fd.CloseError!void {
            unreachable;
        }

        fn duplicate(
            _: *anyopaque,
            _: runtime.fd.DuplicateRequest,
        ) runtime.fd.DuplicateError!runtime.fd.DuplicateResult {
            unreachable;
        }

        fn duplicateTo(_: *anyopaque, _: runtime.fd.DuplicateToRequest) runtime.fd.DuplicateError!void {
            unreachable;
        }

        fn pipe(_: *anyopaque, _: runtime.fd.PipeRequest) runtime.fd.PipeError!runtime.fd.PipeResult {
            unreachable;
        }

        fn writeAll(_: *anyopaque, _: runtime.fd.WriteRequest) runtime.fd.WriteError!void {
            unreachable;
        }

        fn isTty(
            context_value: *anyopaque,
            request: runtime.fd.IsTtyRequest,
        ) runtime.fd.IsTtyError!runtime.fd.IsTtyResult {
            const self = fromContext(context_value);
            request.validate();
            self.requested_descriptor = request.descriptor;
            return .{ .is_tty = request.descriptor == self.tty_descriptor };
        }
    };

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var fake: FakeFdRuntime = .{};
    var evaluator = Evaluator.initWithFdPort(std.testing.allocator, fake.port());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const tty_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "test",
        "-t",
        "7",
    } } });
    var tty = try evaluatePlan(&evaluator, &shell_state, eval_context, tty_plan);
    defer tty.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), tty.status);
    try std.testing.expectEqual(@as(?runtime.fd.Descriptor, 7), fake.requested_descriptor);
    tty.discardDelta(.current_shell);

    const non_tty_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "[",
        "-t",
        "8",
        "]",
    } } });
    var non_tty = try evaluatePlan(&evaluator, &shell_state, eval_context, non_tty_plan);
    defer non_tty.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), non_tty.status);
    try std.testing.expectEqual(@as(?runtime.fd.Descriptor, 8), fake.requested_descriptor);
    non_tty.discardDelta(.current_shell);

    const invalid_fd_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "test",
        "-t",
        "-1",
    } } });
    var invalid_fd = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_fd_plan);
    defer invalid_fd.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), invalid_fd.status);
    try std.testing.expectEqual(@as(?runtime.fd.Descriptor, 8), fake.requested_descriptor);
    invalid_fd.discardDelta(.current_shell);
}

test "semantic evaluator captures printf output and operand errors in CommandOutcome" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const basic_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        "hello %s %d\n",
        "world",
        "42",
    } } });
    var basic = try evaluatePlan(&evaluator, &shell_state, eval_context, basic_plan);
    defer basic.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), basic.status);
    try std.testing.expectEqualStrings("hello world 42\n", basic.stdout.items);
    try std.testing.expectEqualStrings("", basic.stderr.items);
    try std.testing.expectEqual(@as(usize, 0), basic.state_delta.variable_assignments.items.len);
    basic.discardDelta(.current_shell);

    const repeat_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        "[%5s][%-5s][%.3s][%04d]\n",
        "a",
        "b",
        "abcdef",
        "7",
        "c",
        "d",
        "xyz",
        "8",
    } } });
    var repeat = try evaluatePlan(&evaluator, &shell_state, eval_context, repeat_plan);
    defer repeat.deinit();
    try std.testing.expectEqualStrings("[    a][b    ][abc][0007]\n[    c][d    ][xyz][0008]\n", repeat.stdout.items);
    repeat.discardDelta(.current_shell);

    const escape_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        "A\\101:%b",
        "B\\0101 C\\cD",
    } } });
    var escaped = try evaluatePlan(&evaluator, &shell_state, eval_context, escape_plan);
    defer escaped.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), escaped.status);
    try std.testing.expectEqualStrings("AA:BA C", escaped.stdout.items);
    escaped.discardDelta(.current_shell);

    const invalid_integer_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        "%d:%x\n",
        "5x ",
        " 0x1fg ",
    } } });
    var invalid_integer = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_integer_plan);
    defer invalid_integer.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), invalid_integer.status);
    try std.testing.expectEqualStrings("5:1f\n", invalid_integer.stdout.items);
    try std.testing.expectEqualStrings(
        "printf: numeric argument required\nprintf: numeric argument required\n",
        invalid_integer.stderr.items,
    );
    invalid_integer.discardDelta(.current_shell);

    const missing_format_plan = command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .argv = &[_][]const u8{"printf"} } },
    );
    var missing_format = try evaluatePlan(&evaluator, &shell_state, eval_context, missing_format_plan);
    defer missing_format.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), missing_format.status);
    try std.testing.expectEqualStrings("", missing_format.stdout.items);
    try std.testing.expectEqualStrings("printf: missing format operand\n", missing_format.stderr.items);
    missing_format.discardDelta(.current_shell);
}

test "semantic evaluator evaluates runtime-backed file test predicates" {
    const path = "rush-semantic-test-file.tmp";
    const hard_link_path = "rush-semantic-test-file-hard-link.tmp";
    const older_path = "rush-semantic-test-older.tmp";
    const newer_path = "rush-semantic-test-newer.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, hard_link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "x" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = older_path, .data = "old" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = newer_path, .data = "new" });
    try std.Io.Dir.cwd().hardLink(path, std.Io.Dir.cwd(), hard_link_path, std.testing.io, .{});
    const older_time: std.Io.Timestamp = .{ .nanoseconds = 1_000_000_000 };
    const newer_time: std.Io.Timestamp = .{ .nanoseconds = 2_000_000_000 };
    try std.Io.Dir.cwd().setTimestamps(std.testing.io, older_path, .{ .modify_timestamp = .{ .new = older_time } });
    try std.Io.Dir.cwd().setTimestamps(std.testing.io, newer_path, .{ .modify_timestamp = .{ .new = newer_time } });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hard_link_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, older_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, newer_path) catch {};

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    var evaluator = Evaluator.initWithFsPort(std.testing.allocator, adapter.fsPort());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const Case = struct { argv: []const []const u8, status: outcome.ExitStatus };
    const cases = [_]Case{
        .{ .argv = &.{ "test", "-d", "." }, .status = 0 },
        .{ .argv = &.{ "test", "-e", path }, .status = 0 },
        .{ .argv = &.{ "test", "-f", path }, .status = 0 },
        .{ .argv = &.{ "test", "-s", path }, .status = 0 },
        .{ .argv = &.{ "test", "-r", path }, .status = 0 },
        .{ .argv = &.{ "test", "-w", path }, .status = 0 },
        .{ .argv = &.{ "test", "!", "-e", "rush-semantic-test-missing.tmp" }, .status = 0 },
        .{ .argv = &.{ "test", path, "-ef", hard_link_path }, .status = 0 },
        .{ .argv = &.{ "test", path, "-ef", older_path }, .status = 1 },
        .{ .argv = &.{ "test", newer_path, "-nt", older_path }, .status = 0 },
        .{ .argv = &.{ "test", older_path, "-ot", newer_path }, .status = 0 },
        .{ .argv = &.{ "test", newer_path, "-nt", "rush-semantic-test-missing.tmp" }, .status = 0 },
        .{ .argv = &.{ "[", older_path, "-ot", newer_path, "]" }, .status = 0 },
    };

    for (cases) |case| {
        const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = case.argv } });
        var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
        defer result.deinit();
        try std.testing.expectEqual(case.status, result.status);
        try std.testing.expectEqualStrings("", result.stdout.items);
        try std.testing.expectEqualStrings("", result.stderr.items);
        try std.testing.expectEqual(@as(usize, 0), result.state_delta.variable_assignments.items.len);
        result.discardDelta(.current_shell);
    }
}

test "semantic evaluator preserves assignment commit behavior around simple builtins" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const assignment_only = [_]command_plan.Assignment{.{ .name = "ONLY", .value = "persistent" }};
    const assignment_plan = command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &assignment_only } },
    );
    var assignment_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, assignment_plan);
    defer assignment_outcome.deinit();
    try assignment_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("persistent", shell_state.getVariable("ONLY").?.value);

    const special_assignments = [_]command_plan.Assignment{.{ .name = "SPECIAL", .value = "persistent" }};
    const special_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &special_assignments,
        .argv = &[_][]const u8{":"},
    } });
    var special_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, special_plan);
    defer special_outcome.deinit();
    try special_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("persistent", shell_state.getVariable("SPECIAL").?.value);

    const temporary_assignments = [_]command_plan.Assignment{.{ .name = "TEMP", .value = "discarded" }};
    const regular_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &temporary_assignments,
        .argv = &[_][]const u8{"echo"},
    } });
    var regular_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, regular_plan);
    defer regular_outcome.deinit();
    try std.testing.expectEqualStrings("\n", regular_outcome.stdout.items);
    try regular_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("TEMP"));
}

test "semantic evaluator uses command substitution status for assignment-only commands" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    const result = try evaluateStatementListSource(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        "x=$(exit 7)",
        &buffers,
    );

    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), result.status);
    try std.testing.expectEqual(@as(state.ExitStatus, 7), shell_state.last_status);
    try std.testing.expectEqualStrings("", buffers.stdout.items);
    try std.testing.expectEqualStrings("", buffers.stderr.items);
    try std.testing.expectEqualStrings("", shell_state.getVariable("x").?.value);
}

test "semantic evaluator models declaration stateful builtins as StateDelta mutations" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const export_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "export",
        "EXPORTED=value",
        "MARKED",
    } } });
    var export_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, export_plan);
    defer export_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), export_outcome.status);
    try std.testing.expectEqual(
        @as(usize, 2),
        export_outcome.state_delta.variable_assignments.items.len + export_outcome.state_delta.variable_flags.items.len,
    );
    try export_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("value", shell_state.getVariable("EXPORTED").?.value);
    try std.testing.expect(shell_state.getVariable("EXPORTED").?.exported);
    try std.testing.expect(shell_state.getVariable("MARKED").?.exported);

    const readonly_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "readonly",
        "LOCKED=old",
    } } });
    var readonly_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, readonly_plan);
    defer readonly_outcome.deinit();
    try readonly_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expect(shell_state.getVariable("LOCKED").?.readonly);

    const unset_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "unset",
        "EXPORTED",
    } } });
    var unset_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, unset_plan);
    defer unset_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), unset_outcome.state_delta.variable_unsets.items.len);
    try unset_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("EXPORTED"));

    const readonly_unset_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "unset",
        "LOCKED",
    } } });
    var readonly_unset = try evaluatePlan(&evaluator, &shell_state, eval_context, readonly_unset_plan);
    defer readonly_unset.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), readonly_unset.status);
    try std.testing.expectEqualStrings("unset: readonly variable", readonly_unset.diagnostics.items[0].message);
    try readonly_unset.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("old", shell_state.getVariable("LOCKED").?.value);
}

test "semantic evaluator models set and shift stateful builtin deltas" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.replacePositionals(&.{ "a", "b", "c" });
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const set_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "set",
        "-eu",
        "--",
        "x",
        "y",
    } } });
    var set_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, set_plan);
    defer set_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 2), set_outcome.state_delta.option_changes.items.len);
    try std.testing.expectEqual(@as(usize, 2), set_outcome.state_delta.positionals.?.len);
    try set_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expect(shell_state.options.errexit);
    try std.testing.expect(shell_state.options.nounset);
    try std.testing.expectEqualStrings("x", shell_state.positionals.items[0]);

    const shift_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shift",
        "1",
    } } });
    var shift_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, shift_plan);
    defer shift_outcome.deinit();
    try shift_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.positionals.items.len);
    try std.testing.expectEqualStrings("y", shell_state.positionals.items[0]);

    const too_far_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "shift",
        "2",
    } } });
    var too_far = try evaluatePlan(&evaluator, &shell_state, eval_context, too_far_plan);
    defer too_far.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), too_far.status);
    try std.testing.expectEqualStrings("shift: shift count out of range", too_far.diagnostics.items[0].message);
    try too_far.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.positionals.items.len);
}

test "semantic evaluator models alias unalias and trap registration deltas" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const alias_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "alias",
        "say=echo hi",
        "say",
    } } });
    var alias_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, alias_plan);
    defer alias_outcome.deinit();
    try std.testing.expectEqualStrings("say='echo hi'\n", alias_outcome.stdout.items);
    try std.testing.expectEqual(@as(usize, 1), alias_outcome.state_delta.alias_sets.items.len);
    try alias_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("echo hi", shell_state.getAlias("say").?.value);

    const unalias_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "unalias",
        "say",
    } } });
    var unalias_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, unalias_plan);
    defer unalias_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), unalias_outcome.state_delta.alias_unsets.items.len);
    try unalias_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Alias, null), shell_state.getAlias("say"));

    const trap_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "trap",
        "echo bye",
        "EXIT",
        "INT",
    } } });
    var trap_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, trap_plan);
    defer trap_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 2), trap_outcome.state_delta.trap_mutations.items.len);
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("echo bye", shell_state.getTrap("EXIT").?.action);
    try std.testing.expectEqualStrings("echo bye", shell_state.getTrap("INT").?.action);

    const list_trap_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "trap",
        "-p",
        "INT",
    } } });
    var list_trap = try evaluatePlan(&evaluator, &shell_state, eval_context, list_trap_plan);
    defer list_trap.deinit();
    try std.testing.expectEqualStrings("trap -- 'echo bye' INT\n", list_trap.stdout.items);
    list_trap.discardDelta(.current_shell);

    const invalid_trap_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "trap",
        "",
        "NOTASIG",
    } } });
    var invalid_trap = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_trap_plan);
    defer invalid_trap.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), invalid_trap.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, invalid_trap.control_flow);
    try std.testing.expectEqual(@as(usize, 0), invalid_trap.diagnostics.items.len);
    try std.testing.expectEqualStrings("trap: NOTASIG: invalid signal specification\n", invalid_trap.stderr.items);
    invalid_trap.discardDelta(.current_shell);
}

test "semantic evaluator sources empty files as successful no-op scripts" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var input = EvaluationInput.empty();
    var execution_frame_value = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();

    const result = try evaluateStatementListSource(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell).enterSource(),
        "",
        &buffers,
    );
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, result.control_flow);
    try std.testing.expectEqualStrings("", buffers.stdout.items);
    try std.testing.expectEqualStrings("", buffers.stderr.items);
}

test "semantic evaluator sources backslash-newline continued reserved words" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var input = EvaluationInput.empty();
    const eval_context = context.EvalContext.forTarget(.current_shell).enterSource();
    var execution_frame_value = rootExecutionFrame(eval_context);
    var buffers = EvaluationBuffers.init(std.testing.allocator, &input, &execution_frame_value);
    defer buffers.deinit();
    var state_delta = delta.StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();

    const result = try evaluateSourcedText(
        &evaluator,
        shell_state,
        eval_context,
        "i\\\nf true; then DOT_OK=yes; fi\n",
        &.{},
        &state_delta,
        &buffers,
    );
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, result.control_flow);
    try std.testing.expectEqualStrings("", buffers.stderr.items);
    try state_delta.commit(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("yes", shell_state.getVariable("DOT_OK").?.value);
}

test "semantic evaluator polls fake runtime signals into pending trap state" {
    var fake_signal = FakeSignalRuntime.init();
    var evaluator = Evaluator.initWithSignalPort(std.testing.allocator, fake_signal.port());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const eval_context = context.EvalContext.forTarget(.current_shell);

    try shell_state.setTrapForSignal(.TERM, "echo term");
    try configureRuntimeTrapSignal(&evaluator, shell_state, .TERM);
    try std.testing.expectEqual(@as(runtime.signal.Number, 15), fake_signal.configured_signals[0]);
    try std.testing.expectEqual(runtime.signal.Disposition.caught, fake_signal.configured_dispositions[0]);

    fake_signal.push(.{ .signal = 15 });
    var observed = (try observeRuntimeSignal(&evaluator, &shell_state, eval_context)).?;
    defer observed.deinit();
    try std.testing.expectEqual(state.TrapSignal.TERM, observed.signal);
    try std.testing.expectEqual(state.TrapDelivery.queued, observed.delivery);
    try observed.command_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(state.TrapSignal.TERM, shell_state.pending_traps.items[0]);

    try shell_state.setTrapForSignal(.INT, "");
    try configureRuntimeTrapSignal(&evaluator, shell_state, .INT);
    try std.testing.expectEqual(runtime.signal.Disposition.ignore, fake_signal.configured_dispositions[1]);
    fake_signal.push(.{ .signal = 2 });
    var ignored = (try observeRuntimeSignal(&evaluator, &shell_state, eval_context)).?;
    defer ignored.deinit();
    try std.testing.expectEqual(state.TrapDelivery.ignored, ignored.delivery);
    try ignored.command_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.pending_traps.items.len);

    shell_state.clearTrapForSignal(.TERM);
    try configureRuntimeTrapSignal(&evaluator, shell_state, .TERM);
    try std.testing.expectEqual(runtime.signal.Disposition.default, fake_signal.configured_dispositions[2]);
    fake_signal.push(.{ .signal = 15 });
    var defaulted = (try observeRuntimeSignal(&evaluator, &shell_state, eval_context)).?;
    defer defaulted.deinit();
    try std.testing.expectEqual(state.TrapDelivery.default_action, defaulted.delivery);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 143 }, // ziglint-ignore: Z010 (expectEqual peer)
        defaulted.command_outcome.control_flow,
    );
    try defaulted.command_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.ExitStatus, 143), shell_state.pending_exit);
}

test "semantic evaluator executes pending traps and preserves pre-trap status" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    shell_state.last_status = 7;
    try shell_state.setTrapForSignal(.TERM, "echo term");
    try shell_state.appendPendingTrap(.TERM);

    var trap_outcome = (try executePendingTraps(&evaluator, &shell_state, eval_context, simpleTrapResolver())).?;
    defer trap_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), trap_outcome.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, trap_outcome.control_flow);
    try std.testing.expectEqualStrings("term\n", trap_outcome.stdout.items);
    try std.testing.expectEqual(@as(usize, 1), trap_outcome.state_delta.pending_trap_consume_count);

    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(@as(state.ExitStatus, 7), shell_state.last_status);
    try std.testing.expectEqual(state.ShellState.TrapExecution.idle, shell_state.trap_execution);
}

test "semantic parser trap resolver lowers arbitrary simple actions at delivery time" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("TRAP_MESSAGE", "semantic", .{});
    shell_state.last_status = 23;
    try shell_state.setTrapForSignal(.TERM, "TRAP_MUTATED=ok; echo \"$TRAP_MESSAGE:$$\"");
    try shell_state.appendPendingTrap(.TERM);

    var evaluator = Evaluator.init(std.testing.allocator);
    evaluator.shell_pid = 1234;
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 23), trap_outcome.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, trap_outcome.control_flow);
    try std.testing.expectEqualStrings("semantic:1234\n", trap_outcome.stdout.items);
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("TRAP_MUTATED").?.value);
    try std.testing.expectEqual(@as(state.ExitStatus, 23), shell_state.last_status);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_traps.items.len);
}

test "semantic parser trap resolver expands nested command substitutions in action words" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);

    shell_state.last_status = 24;
    try shell_state.setTrapForSignal(.TERM, "echo outer-$(printf \"%s\" \"$(printf inner)\")");
    try shell_state.appendPendingTrap(.TERM);

    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 24), trap_outcome.status);
    try std.testing.expectEqualStrings("outer-inner\n", trap_outcome.stdout.items);

    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 24), shell_state.last_status);
}

test "semantic parser trap command substitutions isolate body mutations from parent trap state" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);

    shell_state.last_status = 25;
    try shell_state.setTrapForSignal(.TERM, "echo \"$(echo ${MUTATED_IN_SUB:=inner})\"; TRAP_MUTATED=ok");
    try shell_state.appendPendingTrap(.TERM);

    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 25), trap_outcome.status);
    try std.testing.expectEqualStrings("inner\n", trap_outcome.stdout.items);

    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("MUTATED_IN_SUB"));
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("TRAP_MUTATED").?.value);
    try std.testing.expectEqual(@as(state.ExitStatus, 25), shell_state.last_status);
}

test "semantic parser trap resolver lowers compound pipeline and and-or actions" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    shell_state.last_status = 5;
    try shell_state.setTrapForSignal(.TERM, "if false; then echo bad; else echo compound; fi");
    try shell_state.appendPendingTrap(.TERM);
    var compound_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        eval_context,
        parser_resolver.resolver(),
    )).?;
    defer compound_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 5), compound_outcome.status);
    try std.testing.expectEqualStrings("compound\n", compound_outcome.stdout.items);
    try compound_outcome.commitDelta(&shell_state, .current_shell);

    shell_state.last_status = 6;
    try shell_state.setTrapForSignal(.TERM, "false && echo bad || echo and-or");
    try shell_state.appendPendingTrap(.TERM);
    var and_or_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        eval_context,
        parser_resolver.resolver(),
    )).?;
    defer and_or_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 6), and_or_outcome.status);
    try std.testing.expectEqualStrings("and-or\n", and_or_outcome.stdout.items);
    try and_or_outcome.commitDelta(&shell_state, .current_shell);

    shell_state.last_status = 7;
    try shell_state.setTrapForSignal(.TERM, "false | true");
    try shell_state.appendPendingTrap(.TERM);
    var pipeline_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        eval_context,
        parser_resolver.resolver(),
    )).?;
    defer pipeline_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), pipeline_outcome.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, pipeline_outcome.control_flow);
    try pipeline_outcome.commitDelta(&shell_state, .current_shell);
}

test "semantic parser trap resolver lowers heterogeneous statement lists and function bodies" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    shell_state.last_status = 31;
    try shell_state.setTrapForSignal(
        .TERM,
        "echo first; if true; then false | true; echo nested; fi; false && echo bad; echo after || echo bad",
    );
    try shell_state.appendPendingTrap(.TERM);
    var list_outcome = (try executePendingTraps(&evaluator, &shell_state, eval_context, parser_resolver.resolver())).?;
    defer list_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 31), list_outcome.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, list_outcome.control_flow);
    try std.testing.expectEqualStrings("first\nnested\nafter\n", list_outcome.stdout.items);
    try list_outcome.commitDelta(&shell_state, .current_shell);

    shell_state.last_status = 32;
    try shell_state.setTrapForSignal(.TERM, "fn() { false | true; if true; then echo function; fi; }");
    try shell_state.appendPendingTrap(.TERM);
    var definition_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        eval_context,
        parser_resolver.resolver(),
    )).?;
    defer definition_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 32), definition_outcome.status);
    try definition_outcome.commitDelta(&shell_state, .current_shell);

    const stored = shell_state.getFunction("fn").?;
    try std.testing.expect(stored.source_body != null);
    try std.testing.expect(stored.source_body_program != null);
    try std.testing.expectEqual(@as(usize, 0), stored.body.statements.len);
    const lookup_functions = [_]command_plan.FunctionDefinition{stored};
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"fn"} },
        .lookup = .{ .functions = &lookup_functions },
    });
    var call_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, call_plan);
    defer call_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), call_outcome.status);
    try std.testing.expectEqualStrings("function\n", call_outcome.stdout.items);
}

test "semantic parser trap resolver classifies same-list function calls" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    var body = (try parser_resolver.resolver().resolve(
        std.testing.allocator,
        "fn() { echo hi; }; fn",
        .TERM,
        eval_context,
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const list = switch (body) {
        .owned => |owned| switch (owned.body) {
            .compound => |compound| switch (compound.body) {
                .sequence => |list| list,
                else => return error.ExpectedStatementList,
            },
            else => return error.ExpectedCompoundPlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };
    try std.testing.expectEqual(@as(usize, 2), list.statements.len);
    switch (list.statements[1].plan) {
        .source => |plan| try std.testing.expectEqualStrings("fn", plan.source),
        .ir_source => |plan| try std.testing.expectEqualStrings("fn", plan.fallback_source),
        else => return error.ExpectedSourceStatement,
    }

    var frame = rootExecutionFrame(eval_context);
    var call_outcome = try evaluateTrapActionBody(&evaluator, &shell_state, eval_context, body, &frame);
    defer call_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), call_outcome.status);
    try std.testing.expectEqualStrings("hi\n", call_outcome.stdout.items);
}

test "semantic parser trap resolver uses lazy IR for alias-disabled while loops" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.expand_aliases = false;
    const eval_context = context.EvalContext.forTarget(.current_shell);

    var body = (try parser_resolver.resolver().resolve(
        std.testing.allocator,
        "i=0; while test \"$i\" != 2; do printf '%s\n' \"$i\"; i=$((i + 1)); done",
        .TERM,
        eval_context,
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const list = switch (body) {
        .owned => |owned| switch (owned.body) {
            .compound => |compound| switch (compound.body) {
                .sequence => |list| list,
                else => return error.ExpectedStatementList,
            },
            else => return error.ExpectedCompoundPlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };
    try std.testing.expectEqual(@as(usize, 2), list.statements.len);
    const loop = switch (list.statements[1].plan) {
        .compound => |compound| switch (compound.body) {
            .while_loop => |loop| loop,
            else => return error.ExpectedWhileLoop,
        },
        else => return error.ExpectedCompoundPlan,
    };
    try std.testing.expect(loop.condition_source == null);
    try std.testing.expect(loop.body_source == null);
    try std.testing.expect(loop.condition.statements.len != 0);
    try std.testing.expect(loop.body.statements.len != 0);

    var frame = rootExecutionFrame(eval_context);
    var outcome_body = try evaluateTrapActionBody(&evaluator, &shell_state, eval_context, body, &frame);
    defer outcome_body.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), outcome_body.status);
    try std.testing.expectEqualStrings("0\n1\n", outcome_body.stdout.items);
}

test "semantic parser trap resolver uses lazy IR for alias-disabled for loops" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.expand_aliases = false;
    const eval_context = context.EvalContext.forTarget(.current_shell);

    var body = (try parser_resolver.resolver().resolve(
        std.testing.allocator,
        "for word in a b; do printf '%s\n' \"$word\"; done",
        .TERM,
        eval_context,
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const for_plan = switch (body) {
        .owned => |owned| switch (owned.body) {
            .compound => |compound| switch (compound.body) {
                .for_loop => |for_plan| for_plan,
                else => return error.ExpectedForLoop,
            },
            else => return error.ExpectedCompoundPlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };
    try std.testing.expect(for_plan.body_source == null);
    try std.testing.expect(for_plan.body.statements.len != 0);

    var frame = rootExecutionFrame(eval_context);
    var outcome_body = try evaluateTrapActionBody(&evaluator, &shell_state, eval_context, body, &frame);
    defer outcome_body.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), outcome_body.status);
    try std.testing.expectEqualStrings("a\nb\n", outcome_body.stdout.items);
}

test "semantic parser trap resolver keeps loops source-backed when aliases are enabled" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    var body = (try parser_resolver.resolver().resolve(
        std.testing.allocator,
        "while :; do break; done; for word in a; do :; done",
        .TERM,
        eval_context,
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const list = switch (body) {
        .owned => |owned| switch (owned.body) {
            .compound => |compound| switch (compound.body) {
                .sequence => |list| list,
                else => return error.ExpectedStatementList,
            },
            else => return error.ExpectedCompoundPlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };
    try std.testing.expectEqual(@as(usize, 2), list.statements.len);
    const loop = switch (list.statements[0].plan) {
        .compound => |compound| switch (compound.body) {
            .while_loop => |loop| loop,
            else => return error.ExpectedWhileLoop,
        },
        else => return error.ExpectedCompoundPlan,
    };
    try std.testing.expect(loop.condition_source != null);
    try std.testing.expect(loop.body_source != null);

    const for_plan = switch (list.statements[1].plan) {
        .compound => |compound| switch (compound.body) {
            .for_loop => |for_plan| for_plan,
            else => return error.ExpectedForLoop,
        },
        else => return error.ExpectedCompoundPlan,
    };
    try std.testing.expect(for_plan.body_source != null);
    try std.testing.expectEqual(@as(usize, 0), for_plan.body.statements.len);
}

test "semantic parser trap resolver lowers redirection operators for trap actions" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("TRAP_MESSAGE", "semantic", .{});

    var evaluator = Evaluator.init(std.testing.allocator);
    const externals = [_]command_plan.ExternalResolution{.{ .name = "tool", .path = "/bin/tool" }};
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    parser_resolver.externals = &externals;
    const eval_context = context.EvalContext.forTarget(.current_shell);

    var body = (try parser_resolver.resolver().resolve(
        std.testing.allocator,
        \\tool 3>out 4>>append 5>|clobber 6<input 7<>rw 8>&1 9<&0 <<EOF
        \\$TRAP_MESSAGE
        \\EOF
    ,
        .TERM,
        eval_context,
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const plan = switch (body) {
        .owned => |owned| switch (owned.body) {
            .simple => |simple| simple,
            else => return error.ExpectedSimplePlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };
    try std.testing.expectEqual(command_plan.CommandClass.external, plan.class());
    try std.testing.expectEqual(@as(usize, 8), plan.redirections.steps.len);

    switch (plan.redirections.steps[0].effect) {
        .open_path => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 3), step.target);
            try std.testing.expectEqualStrings("out", step.path.bytes);
            try std.testing.expectEqual(runtime.fd.OpenAccess.write_only, step.options.access);
            try std.testing.expect(step.options.create);
            try std.testing.expect(step.options.truncate);
        },
        else => return error.ExpectedOpenRedirection,
    }
    switch (plan.redirections.steps[1].effect) {
        .open_path => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 4), step.target);
            try std.testing.expectEqualStrings("append", step.path.bytes);
            try std.testing.expect(step.options.append);
        },
        else => return error.ExpectedAppendRedirection,
    }
    switch (plan.redirections.steps[2].effect) {
        .open_path => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 5), step.target);
            try std.testing.expectEqualStrings("clobber", step.path.bytes);
            try std.testing.expect(step.options.truncate);
            try std.testing.expect(!step.options.exclusive);
        },
        else => return error.ExpectedClobberRedirection,
    }
    switch (plan.redirections.steps[3].effect) {
        .open_path => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 6), step.target);
            try std.testing.expectEqualStrings("input", step.path.bytes);
            try std.testing.expectEqual(runtime.fd.OpenAccess.read_only, step.options.access);
        },
        else => return error.ExpectedInputRedirection,
    }
    switch (plan.redirections.steps[4].effect) {
        .open_path => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 7), step.target);
            try std.testing.expectEqualStrings("rw", step.path.bytes);
            try std.testing.expectEqual(runtime.fd.OpenAccess.read_write, step.options.access);
            try std.testing.expect(step.options.create);
        },
        else => return error.ExpectedReadWriteRedirection,
    }
    switch (plan.redirections.steps[5].effect) {
        .duplicate => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 8), step.target);
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 1), step.source);
        },
        else => return error.ExpectedDuplicateOutput,
    }
    switch (plan.redirections.steps[6].effect) {
        .duplicate => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 9), step.target);
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 0), step.source);
        },
        else => return error.ExpectedDuplicateInput,
    }
    switch (plan.redirections.steps[7].effect) {
        .here_doc => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 0), step.target);
            try std.testing.expectEqualStrings("semantic\n", step.data.bytes);
        },
        else => return error.ExpectedHereDocRedirection,
    }
}

test "semantic parser trap resolver preserves compound redirection io number" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    var body = (try parser_resolver.resolver().resolve(
        std.testing.allocator,
        "{ echo out; } >both 2>&1",
        .TERM,
        eval_context,
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const plan = switch (body) {
        .owned => |owned| switch (owned.body) {
            .compound => |compound| compound,
            else => return error.ExpectedCompoundPlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };
    try std.testing.expectEqual(@as(usize, 2), plan.redirections.steps.len);
    switch (plan.redirections.steps[1].effect) {
        .duplicate => |step| {
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 2), step.target);
            try std.testing.expectEqual(@as(runtime.fd.Descriptor, 1), step.source);
        },
        else => return error.ExpectedDuplicateOutput,
    }
}

test "semantic parser trap resolver reports redirection expansion failures as trap diagnostics" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.nounset, true);
    shell_state.last_status = 41;
    try shell_state.setTrapForSignal(.TERM, ": > \"$MISSING\"");
    try shell_state.appendPendingTrap(.TERM);

    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), trap_outcome.status);
    try std.testing.expectEqual(@as(outcome.ControlFlow, .{ .exit = 2 }), trap_outcome.control_flow);
    try std.testing.expect(trap_outcome.diagnostics.items.len != 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        trap_outcome.diagnostics.items[0].message,
        "trap TERM: expansion error",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, trap_outcome.stderr.items, "parameter not set") != null);
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 2), shell_state.last_status);
}

test "semantic parser trap resolver reports bad descriptor redirects as trap diagnostics" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.last_status = 42;
    try shell_state.setTrapForSignal(.TERM, ": 1>&bad");
    try shell_state.appendPendingTrap(.TERM);

    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 42), trap_outcome.status);
    try std.testing.expect(trap_outcome.diagnostics.items.len != 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        trap_outcome.diagnostics.items[0].message,
        "bad file descriptor",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, trap_outcome.stderr.items, "bad file descriptor") != null);
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 42), shell_state.last_status);
}

test "semantic parser trap resolver preserves current-shell fds around compound redirections" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.last_status = 43;
    try shell_state.setTrapForSignal(.TERM, "{ :; } > trap-out");
    try shell_state.appendPendingTrap(.TERM);

    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 43), trap_outcome.status);
    try std.testing.expectEqual(@as(usize, 6), fake.fd_operation_count);
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[0],
    );
    switch (fake.fd_operations[1]) {
        .open => {},
        else => return error.ExpectedOpenRedirection,
    }
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 11, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[2],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[3],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 10, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[4],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[5],
    );

    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 43), shell_state.last_status);
}

test "semantic parser trap resolver stores parser-backed function definition redirections" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.initWithFdPort(std.testing.allocator, fake.fdPort());
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    shell_state.last_status = 33;
    try shell_state.setTrapForSignal(.TERM, "fn() { echo redirected; } > trap-function-out");
    try shell_state.appendPendingTrap(.TERM);
    {
        var definition_outcome = (try executePendingTraps(
            &evaluator,
            &shell_state,
            eval_context,
            parser_resolver.resolver(),
        )).?;
        defer definition_outcome.deinit();
        try std.testing.expectEqual(@as(outcome.ExitStatus, 33), definition_outcome.status);
        try definition_outcome.commitDelta(&shell_state, .current_shell);
    }

    const stored = shell_state.getFunction("fn").?;
    try std.testing.expect(stored.source_body != null);
    try std.testing.expectEqual(@as(usize, 1), stored.redirections.steps.len);
    switch (stored.redirections.steps[0].effect) {
        .open_path => |step| try std.testing.expectEqualStrings("trap-function-out", step.path.bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "semantic parser trap resolver models parse failures as trap diagnostics" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);

    shell_state.last_status = 11;
    try shell_state.setTrapForSignal(.TERM, "if true; then");
    try shell_state.appendPendingTrap(.TERM);
    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 11), trap_outcome.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, trap_outcome.control_flow);
    try std.testing.expect(trap_outcome.diagnostics.items.len != 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        trap_outcome.diagnostics.items[0].message,
        "trap TERM: parse error",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, trap_outcome.stderr.items, "trap TERM: parse error") != null);
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(@as(state.ExitStatus, 11), shell_state.last_status);
}

test "semantic parser trap resolver gives zero-status parse failures a nonzero diagnostic status" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);

    try shell_state.setTrapForSignal(.TERM, "if true; then");
    try shell_state.appendPendingTrap(.TERM);
    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        parser_resolver.resolver(),
    )).?;
    defer trap_outcome.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), trap_outcome.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, trap_outcome.control_flow);
    try std.testing.expect(trap_outcome.diagnostics.items.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, trap_outcome.stderr.items, "trap TERM: parse error") != null);
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

test "semantic parser trap resolver preserves subshell isolation and exit overrides" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    shell_state.last_status = 12;
    try shell_state.setTrapForSignal(.TERM, "( TRAP_SUBSHELL_ONLY=leak )");
    try shell_state.appendPendingTrap(.TERM);
    var subshell_outcome = (try executePendingTraps(
        &evaluator,
        &shell_state,
        eval_context,
        parser_resolver.resolver(),
    )).?;
    defer subshell_outcome.deinit();
    try subshell_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("TRAP_SUBSHELL_ONLY"));
    try std.testing.expectEqual(@as(state.ExitStatus, 12), shell_state.last_status);

    shell_state.setPendingExit(143);
    try shell_state.setTrapForSignal(.TERM, "exit 9");
    try shell_state.appendPendingTrap(.TERM);
    var exit_outcome = (try executePendingTraps(&evaluator, &shell_state, eval_context, parser_resolver.resolver())).?;
    defer exit_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 9), exit_outcome.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 9 }, // ziglint-ignore: Z010 (expectEqual peer)
        exit_outcome.control_flow,
    );
    try exit_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.ExitStatus, null), shell_state.pending_exit);
    try std.testing.expectEqual(@as(state.ExitStatus, 9), shell_state.last_status);
}

test "semantic evaluator lets trap exit override pending signal exit" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    shell_state.setPendingExit(143);
    try shell_state.setTrapForSignal(.TERM, "exit 9");
    try shell_state.appendPendingTrap(.TERM);

    var trap_outcome = (try executePendingTraps(&evaluator, &shell_state, eval_context, simpleTrapResolver())).?;
    defer trap_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 9), trap_outcome.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 9 }, // ziglint-ignore: Z010 (expectEqual peer)
        trap_outcome.control_flow,
    );
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.ExitStatus, null), shell_state.pending_exit);
    try std.testing.expectEqual(@as(state.ExitStatus, 9), shell_state.last_status);
}

test "semantic evaluator consumes pending default exit when no trap action is queued" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    shell_state.setPendingExit(143);
    var pending_exit = (try executePendingTraps(&evaluator, &shell_state, eval_context, simpleTrapResolver())).?;
    defer pending_exit.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 143), pending_exit.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 143 }, // ziglint-ignore: Z010 (expectEqual peer)
        pending_exit.control_flow,
    );
    try pending_exit.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.ExitStatus, null), shell_state.pending_exit);
}

test "semantic trap execution in subshell and command substitution does not mutate parent trap state" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.TERM, "echo parent");
    var evaluator = Evaluator.init(std.testing.allocator);

    const trap_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{ "trap", "echo sub", "TERM" } },
        .target = .subshell,
    });
    var substitution = try evaluateCommandSubstitution(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        .{ .simple = trap_plan },
    );
    defer substitution.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), substitution.status);
    try std.testing.expectEqualStrings("echo parent", shell_state.getTrapForSignal(.TERM).?.action);

    var subshell = try shell_state.snapshotForSubshell(std.testing.allocator);
    defer subshell.deinit();
    try subshell.setTrapForSignal(.TERM, "echo term");
    try subshell.appendPendingTrap(.TERM);
    var trap_outcome = (try executePendingTraps(
        &evaluator,
        &subshell,
        context.EvalContext.forTarget(.subshell),
        simpleTrapResolver(),
    )).?;
    defer trap_outcome.deinit();
    try trap_outcome.commitDelta(&subshell, .subshell);
    try std.testing.expectEqualStrings("echo parent", shell_state.getTrapForSignal(.TERM).?.action);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_traps.items.len);
}

test "semantic command substitution captures owned output and trims only trailing newlines" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);

    const printf_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{ "printf", "%s\n\n", "line1\nline2" } },
        .target = .subshell,
    });
    var result = try evaluateCommandSubstitution(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        .{ .simple = printf_plan },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, result.control_flow);
    try std.testing.expectEqualStrings("line1\nline2", result.output.items);
    try std.testing.expectEqualStrings("", result.stderr.items);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

test "semantic command substitution frame inherits parent stdin and stderr endpoints" {
    var parent_frame = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    try parent_frame.spec.fd_table.bindInput(std.testing.allocator, 0, .{ .bytes = "stdin" });
    try parent_frame.spec.fd_table.bindOutput(std.testing.allocator, 2, .{ .capture = .side_stderr });
    defer parent_frame.spec.fd_table.deinit(std.testing.allocator);

    var substitution_frame = try commandSubstitutionExecutionFrame(std.testing.allocator, null, &parent_frame);
    defer substitution_frame.spec.fd_table.deinit(std.testing.allocator);
    switch (substitution_frame.spec.stdin) {
        .bytes => |bytes| try std.testing.expectEqualStrings("stdin", bytes),
        else => return error.ExpectedByteStdinEndpoint,
    }
    const expected_stdout: execution_frame.OutputEndpoint = .{ .capture = .command_substitution_stdout };
    try std.testing.expectEqual(expected_stdout, substitution_frame.spec.stdout);
    const expected_stderr: execution_frame.OutputEndpoint = .{ .capture = .side_stderr };
    try std.testing.expectEqual(expected_stderr, substitution_frame.spec.stderr);
    try std.testing.expect(substitution_frame.spec.captures.contains(.command_substitution_stdout));
    try std.testing.expect(substitution_frame.spec.captures.contains(.side_stderr));
    try std.testing.expectEqual(
        execution_frame.MutationPolicy.discard_at_boundary,
        substitution_frame.spec.mutation_policy,
    );
}

test "fallback pipeline stage frames model stdin stdout stderr and redirection order" {
    var parent_frame = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    try parent_frame.spec.fd_table.bindOutput(std.testing.allocator, 2, .{ .capture = .side_stderr });
    defer parent_frame.spec.fd_table.deinit(std.testing.allocator);

    const stderr_to_stdout = [_]redirection_plan.RedirectionStep{
        redirection_plan.RedirectionStep.duplicate(0, 2, 1),
    };
    const first_redirections: redirection_plan.RedirectionPlan = .{ .steps = &stderr_to_stdout };
    var first = try pipelineStageExecutionFrame(
        std.testing.allocator,
        null,
        &parent_frame,
        .subshell,
        false,
        "",
        first_redirections,
    );
    defer first.spec.fd_table.deinit(std.testing.allocator);

    try std.testing.expect(first.spec.captures.contains(.pipeline_data));
    try expectFrameOutputCapture(first.spec.fd_table.endpoint(1), .pipeline_data);
    try expectFrameOutputCapture(first.spec.fd_table.endpoint(2), .pipeline_data);

    var last = try pipelineStageExecutionFrame(
        std.testing.allocator,
        null,
        &parent_frame,
        .subshell,
        true,
        "from-first",
        .{},
    );
    defer last.spec.fd_table.deinit(std.testing.allocator);

    switch (last.spec.fd_table.endpoint(0)) {
        .input => |input| switch (input) {
            .bytes => |bytes| try std.testing.expectEqualStrings("from-first", bytes),
            else => return error.ExpectedByteStdinEndpoint,
        },
        else => return error.ExpectedInputEndpoint,
    }
    try expectFrameOutputCapture(last.spec.fd_table.endpoint(2), .side_stderr);
}

fn expectFrameOutputCapture(
    endpoint: execution_frame.FdEndpoint,
    channel: execution_frame.CaptureChannel,
) !void {
    switch (endpoint) {
        .output => |output| try std.testing.expectEqual(execution_frame.OutputEndpoint{ .capture = channel }, output),
        else => return error.ExpectedOutputEndpoint,
    }
}

test "semantic command substitution captures external command stdout" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setRunResult("external\n", "external-err\n", .{ .exited = 0 });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const externals = [_]command_plan.ExternalResolution{.{ .name = "tool", .path = "/bin/tool" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"tool"} },
        .lookup = .{ .externals = &externals },
    });

    var result = try evaluateCommandSubstitution(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        .{ .simple = plan },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.run_count);
    try std.testing.expectEqualStrings("external", result.output.items);
    try std.testing.expectEqualStrings("external-err\n", result.stderr.items);
}

test "semantic command substitution runs subshell EXIT trap before trimming captured output" {
    var parent_state = state.ShellState.init(std.testing.allocator);
    defer parent_state.deinit();
    var substitution_state = try parent_state.snapshotForSubshell(std.testing.allocator);
    defer substitution_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);

    const commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{ "trap", "echo term", "0" } },
            .target = .subshell,
        }),
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{ "printf", "body-" } },
            .target = .subshell,
        }),
    };
    const compound: command_plan.CompoundCommandPlan = .{
        .target = .subshell,
        .body = .{ .sequence = .{ .commands = &commands } },
    };
    var parent_frame = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var result = try evaluateCommandSubstitutionInState(
        &evaluator,
        &substitution_state,
        context.EvalContext.forTarget(.current_shell).enterCommandSubstitution(),
        .{ .compound = compound },
        simpleTrapResolver(),
        &parent_frame,
        null,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("body-term", result.output.items);
    try std.testing.expectEqual(@as(?state.Trap, null), parent_state.getTrapForSignal(.EXIT));
}

test "semantic command substitution sees parent variables but isolates body mutations" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("PARENT", "outer", .{ .exported = true });
    var evaluator = Evaluator.init(std.testing.allocator);

    const assignments = [_]command_plan.Assignment{.{ .name = "SUB", .value = "inner" }};
    const commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .assignments = &assignments },
            .target = .subshell,
        }),
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{ "export", "SUB" } },
            .target = .subshell,
        }),
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{ "export", "-p" } },
            .target = .subshell,
        }),
    };
    const compound: command_plan.CompoundCommandPlan = .{
        .target = .subshell,
        .body = .{ .sequence = .{ .commands = &commands } },
    };

    var result = try evaluateCommandSubstitution(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        .{ .compound = compound },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("export PARENT='outer'\nexport SUB='inner'", result.output.items);
    try std.testing.expectEqualStrings("outer", shell_state.getVariable("PARENT").?.value);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("SUB"));
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

test "semantic command substitution propagates status and diagnostics without parent leakage" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.last_status = 42;
    var evaluator = Evaluator.init(std.testing.allocator);

    const missing_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"missing"} },
        .target = .subshell,
    });
    var result = try evaluateCommandSubstitution(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        .{ .simple = missing_plan },
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.output.items);
    try std.testing.expectEqualStrings("missing: command not found\n", result.stderr.items);
    try std.testing.expectEqualStrings("missing: command not found", result.diagnostics.items[0].message);
    try std.testing.expectEqual(@as(state.ExitStatus, 42), shell_state.last_status);
}

test "semantic expansion callback evaluates nested command substitutions through evaluator" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);

    const NestedResolver = struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        expansion_context: ?*CommandSubstitutionExpansionContext = null,
        allocated: std.ArrayList([]const u8) = .empty,
        inner_argv: [3][]const u8 = .{ "printf", "%s\n", "inner" },
        outer_argv: [3][]const u8 = .{ "printf", "%s\n", "" },

        fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        fn deinit(self: *Self) void {
            for (self.allocated.items) |bytes| self.allocator.free(bytes);
            self.allocated.deinit(self.allocator);
            self.* = undefined;
        }

        fn resolve(
            opaque_context: ?*anyopaque,
            _: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
            script: []const u8,
        ) anyerror!?CommandSubstitutionBody {
            std.debug.assert(opaque_context != null);
            const self: *Self = @ptrCast(@alignCast(opaque_context.?));
            if (std.mem.eql(u8, script, "inner")) {
                const plan = command_plan.classifyExpandedSimpleCommand(.{
                    .command = .{ .argv = &self.inner_argv },
                    .target = .subshell,
                });
                return .{ .simple = plan };
            }
            if (std.mem.eql(u8, script, "outer $(inner)")) {
                const expanded = try expand.expandWordScalar(self.allocator, script, .{
                    .command_substitution = self.expansion_context.?.commandSubstitution(),
                });
                errdefer self.allocator.free(expanded);
                try self.allocated.append(self.allocator, expanded);
                self.outer_argv[2] = expanded;
                const plan = command_plan.classifyExpandedSimpleCommand(.{
                    .command = .{ .argv = &self.outer_argv },
                    .target = .subshell,
                });
                return .{ .simple = plan };
            }
            return null;
        }
    };

    var resolver = NestedResolver.init(std.testing.allocator);
    defer resolver.deinit();
    var expansion_context = CommandSubstitutionExpansionContext.init(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        .{
            .context = &resolver,
            .resolveFn = NestedResolver.resolve,
        },
        null,
        null,
        null,
    );
    defer expansion_context.deinit();
    resolver.expansion_context = &expansion_context;

    const rendered = try expand.expandWordScalar(std.testing.allocator, "prefix-$(outer $(inner))-suffix", .{
        .command_substitution = expansion_context.commandSubstitution(),
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("prefix-outer inner-suffix", rendered);
    try std.testing.expectEqual(@as(?outcome.ExitStatus, 0), expansion_context.last_status);
    try std.testing.expect(expansion_context.max_depth_observed >= 2);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

const FakeFdOperation = union(enum) {
    open: []const u8,
    close: runtime.fd.Descriptor,
    duplicate: runtime.fd.Descriptor,
    duplicate_to: struct {
        source: runtime.fd.Descriptor,
        target: runtime.fd.Descriptor,
    },
    pipe: struct {
        read: runtime.fd.Descriptor,
        write: runtime.fd.Descriptor,
    },
};

const FakeSignalRuntime = struct {
    events: [8]runtime.signal.Event = undefined,
    event_count: usize = 0,
    configured_signals: [8]runtime.signal.Number = undefined,
    configured_dispositions: [8]runtime.signal.Disposition = undefined,
    configure_count: usize = 0,
    sent_processes: [8]i32 = undefined,
    sent_signals: [8]runtime.signal.Number = undefined,
    send_count: usize = 0,

    fn init() FakeSignalRuntime {
        return .{};
    }

    fn port(self: *FakeSignalRuntime) runtime.signal.Port {
        return .{
            .context = self,
            .configure_fn = configure,
            .poll_fn = poll,
            .send_fn = send,
        };
    }

    fn push(self: *FakeSignalRuntime, event: runtime.signal.Event) void {
        event.validate();
        std.debug.assert(self.event_count < self.events.len);
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    fn fromContext(opaque_context: *anyopaque) *FakeSignalRuntime {
        return @ptrCast(@alignCast(opaque_context));
    }

    fn configure(
        opaque_context: *anyopaque,
        request: runtime.signal.ConfigureRequest,
    ) runtime.signal.ConfigureError!void {
        const self = fromContext(opaque_context);
        request.validate();
        std.debug.assert(self.configure_count < self.configured_signals.len);
        self.configured_signals[self.configure_count] = request.signal;
        self.configured_dispositions[self.configure_count] = request.disposition;
        self.configure_count += 1;
    }

    fn poll(opaque_context: *anyopaque) runtime.signal.PollError!?runtime.signal.Event {
        const self = fromContext(opaque_context);
        if (self.event_count == 0) return null;
        const event = self.events[0];
        var index: usize = 1;
        while (index < self.event_count) : (index += 1) self.events[index - 1] = self.events[index];
        self.event_count -= 1;
        return event;
    }

    fn send(opaque_context: *anyopaque, request: runtime.signal.SendRequest) runtime.signal.SendError!void {
        const self = fromContext(opaque_context);
        request.validate();
        std.debug.assert(self.send_count < self.sent_processes.len);
        self.sent_processes[self.send_count] = request.process;
        self.sent_signals[self.send_count] = request.signal;
        self.send_count += 1;
    }
};

const FakeFsRuntime = struct {
    file_creation_mask: runtime.fs.FileCreationMask = 0o022,
    file_creation_mask_change_count: usize = 0,

    fn init() FakeFsRuntime {
        return .{};
    }

    fn port(self: *FakeFsRuntime) runtime.fs.Port {
        return .{
            .context = self,
            .get_cwd_fn = getCwd,
            .change_cwd_fn = changeCwd,
            .access_fn = access,
            .inspect_path_fn = inspectPath,
            .list_dir_fn = listDir,
            .set_file_creation_mask_fn = setFileCreationMask,
        };
    }

    fn fromContext(opaque_context: *anyopaque) *FakeFsRuntime {
        return @ptrCast(@alignCast(opaque_context));
    }

    fn getCwd(
        opaque_context: *anyopaque,
        request: runtime.fs.GetCwdRequest,
    ) runtime.fs.GetCwdError!runtime.fs.GetCwdResult {
        _ = opaque_context;
        request.validate();
        const cwd = "/fake";
        @memcpy(request.buffer[0..cwd.len], cwd);
        return .{ .path = request.buffer[0..cwd.len] };
    }

    fn changeCwd(opaque_context: *anyopaque, request: runtime.fs.ChangeCwdRequest) runtime.fs.ChangeCwdError!void {
        _ = opaque_context;
        request.validate();
    }

    fn access(opaque_context: *anyopaque, request: runtime.fs.AccessRequest) runtime.fs.AccessError!void {
        _ = opaque_context;
        request.validate();
        if (std.mem.indexOf(u8, request.path, "missing") != null) return error.FileNotFound;
    }

    fn inspectPath(
        opaque_context: *anyopaque,
        request: runtime.fs.InspectPathRequest,
    ) runtime.fs.InspectPathError!runtime.fs.InspectPathResult {
        _ = opaque_context;
        request.validate();
        if (std.mem.indexOf(u8, request.path, "missing") != null) return error.FileNotFound;
        return .{ .stat = undefined };
    }

    fn listDir(
        opaque_context: *anyopaque,
        request: runtime.fs.ListDirRequest,
    ) runtime.fs.ListDirError!runtime.fs.ListDirResult {
        _ = opaque_context;
        request.validate();
        return .{ .allocator = request.allocator, .entries = &.{} };
    }

    fn setFileCreationMask(
        opaque_context: *anyopaque,
        request: runtime.fs.SetFileCreationMaskRequest,
    ) runtime.fs.SetFileCreationMaskError!runtime.fs.SetFileCreationMaskResult {
        const self = fromContext(opaque_context);
        request.validate();
        const previous = self.file_creation_mask;
        self.file_creation_mask = request.mask;
        self.file_creation_mask_change_count += 1;
        return .{ .previous = previous };
    }
};

fn simpleTrapResolver() TrapActionResolver {
    return .{ .resolveFn = resolveSimpleTrapAction };
}

fn resolveSimpleTrapAction(
    _: ?*anyopaque,
    _: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    action: []const u8,
    signal: state.TrapSignal,
    eval_context: context.EvalContext,
    shell_state: *state.ShellState,
) anyerror!?TrapActionBody {
    trapSemanticActionAssert(action, signal, eval_context);
    shell_state.validate();
    std.debug.assert(shell_state.acceptsExecutionTarget(eval_context.target));
    if (std.mem.eql(u8, action, "echo term")) {
        return .{ .simple = command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{ "echo", "term" } },
            .target = eval_context.target,
        }) };
    }
    if (std.mem.eql(u8, action, "exit 9")) {
        return .{ .simple = command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{ "exit", "9" } },
            .target = eval_context.target,
        }) };
    }
    return null;
}

const FakeExternalRuntime = struct {
    allocator: std.mem.Allocator,
    open_descriptors: [64]bool = initFakeOpenDescriptors(),
    next_descriptor: runtime.fd.Descriptor = 10,
    fd_operations: [64]FakeFdOperation = undefined,
    fd_operation_count: usize = 0,
    observed_argv: std.ArrayList([]const u8) = .empty,
    observed_environment: std.process.Environ.Map,
    observed_stdin: runtime.process.StandardIo = .inherit,
    observed_stdout: runtime.process.StandardIo = .inherit,
    observed_stderr: runtime.process.StandardIo = .inherit,
    observed_spawn_stdin: [8]runtime.process.StandardIo = undefined,
    observed_spawn_stdout: [8]runtime.process.StandardIo = undefined,
    observed_spawn_stderr: [8]runtime.process.StandardIo = undefined,
    observed_spawn_process_group: [8]?runtime.process.ProcessId = undefined,
    observed_run_stdin: std.ArrayList(u8) = .empty,
    observed_process_group: ?runtime.process.ProcessId = null,
    observed_subshell_process_group: ?runtime.process.ProcessId = null,
    observed_continue_target: ?runtime.process.ProcessTarget = null,
    observed_foreground_process_groups: [4]runtime.process.ProcessId = undefined,
    spawn_count: usize = 0,
    start_subshell_count: usize = 0,
    run_count: usize = 0,
    wait_count: usize = 0,
    poll_wait_count: usize = 0,
    continue_count: usize = 0,
    foreground_count: usize = 0,
    wait_status: runtime.process.WaitStatus = .{ .exited = 7 },
    wait_statuses: [8]runtime.process.WaitStatus = undefined,
    wait_status_count: usize = 0,
    poll_wait_statuses: [8]?runtime.process.WaitStatus = undefined,
    poll_wait_status_count: usize = 0,
    run_status: runtime.process.WaitStatus = .{ .exited = 0 },
    run_stdout: []const u8 = &.{},
    run_stderr: []const u8 = &.{},
    process_times: runtime.process.ProcessTimes = .{},
    resource_limits: runtime.process.ResourceLimits = .{
        .soft = .unlimited,
        .hard = .unlimited,
    },
    set_resource_limit_count: usize = 0,

    fn init(allocator: std.mem.Allocator) FakeExternalRuntime {
        return .{
            .allocator = allocator,
            .observed_environment = std.process.Environ.Map.init(allocator),
        };
    }

    fn deinit(self: *FakeExternalRuntime) void {
        self.clearObservedArgv();
        self.observed_run_stdin.deinit(self.allocator);
        self.observed_argv.deinit(self.allocator);
        self.observed_environment.deinit();
        self.* = undefined;
    }

    fn fdPort(self: *FakeExternalRuntime) runtime.fd.Port {
        return .{
            .context = self,
            .open_fn = open,
            .close_fn = close,
            .duplicate_fn = duplicate,
            .duplicate_to_fn = duplicateTo,
            .pipe_fn = pipe,
            .write_fn = writeAll,
            .is_tty_fn = isTty,
        };
    }

    fn processPort(self: *FakeExternalRuntime) runtime.process.Port {
        return .{
            .context = self,
            .spawn_fn = spawn,
            .start_subshell_fn = startSubshell,
            .wait_fn = wait,
            .poll_wait_fn = pollWait,
            .run_fn = run,
            .get_times_fn = getTimes,
            .get_resource_limit_fn = getResourceLimit,
            .set_resource_limit_fn = setResourceLimit,
            .continue_process_fn = continueProcess,
            .foreground_process_group_fn = foregroundProcessGroup,
        };
    }

    fn setWaitStatuses(self: *FakeExternalRuntime, statuses: []const runtime.process.WaitStatus) void {
        std.debug.assert(statuses.len <= self.wait_statuses.len);
        for (statuses, 0..) |status_value, index| self.wait_statuses[index] = status_value;
        self.wait_status_count = statuses.len;
        std.debug.assert(statuses.len <= self.poll_wait_statuses.len);
        for (statuses, 0..) |status_value, index| self.poll_wait_statuses[index] = status_value;
        self.poll_wait_status_count = statuses.len;
        self.poll_wait_count = 0;
    }

    fn setPollWaitStatuses(self: *FakeExternalRuntime, statuses: []const ?runtime.process.WaitStatus) void {
        std.debug.assert(statuses.len <= self.poll_wait_statuses.len);
        for (statuses, 0..) |status_value, index| self.poll_wait_statuses[index] = status_value;
        self.poll_wait_status_count = statuses.len;
        self.poll_wait_count = 0;
    }

    fn setRunResult(
        self: *FakeExternalRuntime,
        stdout_bytes: []const u8,
        stderr_bytes: []const u8,
        status_value: runtime.process.WaitStatus,
    ) void {
        self.run_stdout = stdout_bytes;
        self.run_stderr = stderr_bytes;
        self.run_status = status_value;
    }

    fn setProcessTimes(self: *FakeExternalRuntime, times: runtime.process.ProcessTimes) void {
        times.validate();
        self.process_times = times;
    }

    fn setResourceLimits(self: *FakeExternalRuntime, limits: runtime.process.ResourceLimits) void {
        limits.validate();
        self.resource_limits = limits;
    }

    fn clearObservedArgv(self: *FakeExternalRuntime) void {
        for (self.observed_argv.items) |arg| self.allocator.free(arg);
        self.observed_argv.clearRetainingCapacity();
    }

    fn copyObservedArgv(self: *FakeExternalRuntime, argv: []const []const u8) !void {
        self.clearObservedArgv();
        for (argv) |arg| {
            const owned_arg = try self.allocator.dupe(u8, arg);
            errdefer self.allocator.free(owned_arg);
            try self.observed_argv.append(self.allocator, owned_arg);
        }
    }

    fn copyObservedEnvironment(self: *FakeExternalRuntime, environment: *const std.process.Environ.Map) !void {
        self.observed_environment.deinit();
        self.observed_environment = std.process.Environ.Map.init(self.allocator);
        const keys = environment.keys();
        const values = environment.values();
        for (keys, values) |key, value| try self.observed_environment.put(key, value);
    }

    fn recordFdOperation(self: *FakeExternalRuntime, operation: FakeFdOperation) void {
        std.debug.assert(self.fd_operation_count < self.fd_operations.len);
        self.fd_operations[self.fd_operation_count] = operation;
        self.fd_operation_count += 1;
    }

    fn isOpen(self: FakeExternalRuntime, descriptor: runtime.fd.Descriptor) bool {
        if (descriptor < 0 or descriptor >= self.open_descriptors.len) return false;
        return self.open_descriptors[@intCast(descriptor)];
    }

    fn setOpen(self: *FakeExternalRuntime, descriptor: runtime.fd.Descriptor, open_value: bool) void {
        std.debug.assert(descriptor >= 0);
        std.debug.assert(descriptor < self.open_descriptors.len);
        self.open_descriptors[@intCast(descriptor)] = open_value;
    }

    fn allocateDescriptor(
        self: *FakeExternalRuntime,
        minimum_descriptor: runtime.fd.Descriptor,
    ) runtime.fd.Descriptor {
        runtime.fd.assertValidDescriptor(minimum_descriptor);
        const descriptor = @max(self.next_descriptor, minimum_descriptor);
        self.next_descriptor = descriptor + 1;
        self.setOpen(descriptor, true);
        return descriptor;
    }

    fn fromContext(opaque_context: *anyopaque) *FakeExternalRuntime {
        return @ptrCast(@alignCast(opaque_context));
    }

    fn open(opaque_context: *anyopaque, request: runtime.fd.OpenRequest) runtime.fd.OpenError!runtime.fd.OpenResult {
        const self = fromContext(opaque_context);
        request.validate();
        self.recordFdOperation(.{ .open = request.path });
        if (std.mem.eql(u8, request.path, "missing")) return error.FileNotFound;
        return .{ .descriptor = self.allocateDescriptor(0) };
    }

    fn close(opaque_context: *anyopaque, request: runtime.fd.CloseRequest) runtime.fd.CloseError!void {
        const self = fromContext(opaque_context);
        request.validate();
        self.recordFdOperation(.{ .close = request.descriptor });
        if (!self.isOpen(request.descriptor)) return error.BadFileDescriptor;
        self.setOpen(request.descriptor, false);
    }

    fn duplicate(
        opaque_context: *anyopaque,
        request: runtime.fd.DuplicateRequest,
    ) runtime.fd.DuplicateError!runtime.fd.DuplicateResult {
        const self = fromContext(opaque_context);
        request.validate();
        self.recordFdOperation(.{ .duplicate = request.descriptor });
        if (!self.isOpen(request.descriptor)) return error.BadFileDescriptor;
        return .{ .descriptor = self.allocateDescriptor(request.minimum_descriptor) };
    }

    fn duplicateTo(opaque_context: *anyopaque, request: runtime.fd.DuplicateToRequest) runtime.fd.DuplicateError!void {
        const self = fromContext(opaque_context);
        request.validate();
        self.recordFdOperation(.{ .duplicate_to = .{ .source = request.source, .target = request.target } });
        if (!self.isOpen(request.source)) return error.BadFileDescriptor;
        self.setOpen(request.target, true);
    }

    fn pipe(opaque_context: *anyopaque, request: runtime.fd.PipeRequest) runtime.fd.PipeError!runtime.fd.PipeResult {
        const self = fromContext(opaque_context);
        request.validate();
        const read = self.allocateDescriptor(0);
        errdefer self.setOpen(read, false);
        const write = self.allocateDescriptor(0);
        self.recordFdOperation(.{ .pipe = .{ .read = read, .write = write } });
        return .{ .read = read, .write = write };
    }

    fn writeAll(opaque_context: *anyopaque, request: runtime.fd.WriteRequest) runtime.fd.WriteError!void {
        const self = fromContext(opaque_context);
        request.validate();
        if (!self.isOpen(request.descriptor)) return error.BadFileDescriptor;
    }

    fn isTty(
        opaque_context: *anyopaque,
        request: runtime.fd.IsTtyRequest,
    ) runtime.fd.IsTtyError!runtime.fd.IsTtyResult {
        _ = opaque_context;
        request.validate();
        return .{ .is_tty = false };
    }

    fn spawn(
        opaque_context: *anyopaque,
        request: runtime.process.SpawnRequest,
    ) runtime.process.SpawnError!runtime.process.SpawnResult {
        const self = fromContext(opaque_context);
        request.validate();
        std.debug.assert(request.environment != null);
        std.debug.assert(self.spawn_count < self.observed_spawn_stdin.len);
        const spawn_index = self.spawn_count;
        try self.copyObservedArgv(request.argv);
        try self.copyObservedEnvironment(request.environment.?);
        self.observed_stdin = request.stdin;
        self.observed_stdout = request.stdout;
        self.observed_stderr = request.stderr;
        self.observed_process_group = request.process_group;
        self.observed_spawn_stdin[spawn_index] = request.stdin;
        self.observed_spawn_stdout[spawn_index] = request.stdout;
        self.observed_spawn_stderr[spawn_index] = request.stderr;
        self.observed_spawn_process_group[spawn_index] = request.process_group;
        self.spawn_count += 1;
        return .{ .child = fakeChild(9001 + @as(runtime.process.ProcessId, @intCast(spawn_index))) };
    }

    fn startSubshell(
        opaque_context: *anyopaque,
        request: runtime.process.StartSubshellRequest,
    ) runtime.process.SpawnError!runtime.process.SpawnResult {
        const self = fromContext(opaque_context);
        request.validate();
        std.debug.assert(self.start_subshell_count < self.observed_spawn_process_group.len);
        self.observed_subshell_process_group = request.process_group;
        self.start_subshell_count += 1;
        return .{ .child = fakeChild(9100 + @as(runtime.process.ProcessId, @intCast(self.start_subshell_count))) };
    }

    fn wait(
        opaque_context: *anyopaque,
        request: runtime.process.WaitRequest,
    ) runtime.process.WaitError!runtime.process.WaitResult {
        const self = fromContext(opaque_context);
        request.validate();
        const wait_index = self.wait_count;
        self.wait_count += 1;
        request.child.child.id = null;
        request.child.markWaited();
        const status_value =
            if (wait_index < self.wait_status_count) self.wait_statuses[wait_index] else self.wait_status;
        return .{ .status = status_value };
    }

    fn pollWait(
        opaque_context: *anyopaque,
        request: runtime.process.PollWaitRequest,
    ) runtime.process.WaitError!runtime.process.PollWaitResult {
        const self = fromContext(opaque_context);
        request.validate();
        const poll_index = self.poll_wait_count;
        self.poll_wait_count += 1;
        if (poll_index >= self.poll_wait_status_count) return .{ .status = null };
        const status_value = self.poll_wait_statuses[poll_index] orelse return .{ .status = null };
        switch (status_value) {
            .stopped => {},
            .exited, .signaled, .unknown => {
                request.child.child.id = null;
                request.child.markWaited();
            },
        }
        return .{ .status = status_value };
    }

    fn continueProcess(
        opaque_context: *anyopaque,
        request: runtime.process.ContinueProcessRequest,
    ) runtime.process.JobControlError!void {
        const self = fromContext(opaque_context);
        request.validate();
        self.observed_continue_target = request.target;
        self.continue_count += 1;
    }

    fn foregroundProcessGroup(
        opaque_context: *anyopaque,
        request: runtime.process.ForegroundProcessGroupRequest,
    ) runtime.process.JobControlError!runtime.process.ForegroundProcessGroupResult {
        const self = fromContext(opaque_context);
        request.validate();
        std.debug.assert(self.foreground_count < self.observed_foreground_process_groups.len);
        self.observed_foreground_process_groups[self.foreground_count] = request.process_group;
        self.foreground_count += 1;
        return .{ .previous_process_group = 42 };
    }

    fn run(
        opaque_context: *anyopaque,
        request: runtime.process.RunRequest,
    ) runtime.process.RunError!runtime.process.RunResult {
        const self = fromContext(opaque_context);
        request.validate();
        std.debug.assert(request.environment != null);
        try self.copyObservedArgv(request.argv);
        try self.copyObservedEnvironment(request.environment.?);
        self.observed_run_stdin.clearRetainingCapacity();
        try self.observed_run_stdin.appendSlice(self.allocator, request.stdin);
        self.run_count += 1;
        return .{
            .allocator = request.allocator,
            .status = self.run_status,
            .stdout = try request.allocator.dupe(u8, self.run_stdout),
            .stderr = try request.allocator.dupe(u8, self.run_stderr),
        };
    }

    fn getTimes(opaque_context: *anyopaque) runtime.process.TimesError!runtime.process.ProcessTimes {
        const self = fromContext(opaque_context);
        return self.process_times;
    }

    fn getResourceLimit(
        opaque_context: *anyopaque,
        request: runtime.process.GetResourceLimitRequest,
    ) runtime.process.ResourceLimitError!runtime.process.GetResourceLimitResult {
        const self = fromContext(opaque_context);
        request.validate();
        return .{ .limits = self.resource_limits };
    }

    fn setResourceLimit(
        opaque_context: *anyopaque,
        request: runtime.process.SetResourceLimitRequest,
    ) runtime.process.ResourceLimitError!void {
        const self = fromContext(opaque_context);
        request.validate();
        self.resource_limits = request.limits;
        self.set_resource_limit_count += 1;
    }
};

fn initFakeOpenDescriptors() [64]bool {
    var descriptors = [_]bool{false} ** 64;
    descriptors[0] = true;
    descriptors[1] = true;
    descriptors[2] = true;
    return descriptors;
}

fn fakeChild(id: runtime.process.ProcessId) runtime.process.ChildProcess {
    const child: std.process.Child = .{
        .id = id,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    return runtime.process.ChildProcess.init(child);
}

fn appendSemanticTestJob(
    shell_state: *state.ShellState,
    id: usize,
    pid: runtime.process.ProcessId,
    process_group: ?runtime.process.ProcessId,
    command: []const u8,
    job_state: state.JobState,
) !void {
    const owned_command = try shell_state.allocator.dupe(u8, command);
    errdefer shell_state.allocator.free(owned_command);

    const stopped_signal = signalNumber(.STOP);
    const stopped_status = normalizeWaitStatus(.{ .stopped = stopped_signal });
    var child = fakeChild(pid);
    if (job_state == .done) {
        child.child.id = null;
        child.markWaited();
    }

    var job: state.BackgroundJob = .{
        .id = id,
        .pid = pid,
        .process_group = process_group,
        .command = owned_command,
        .state = job_state,
        .status = if (job_state == .stopped) stopped_status else 0,
        .stop_signal = if (job_state == .stopped) stopped_signal else null,
    };
    errdefer job.deinit(shell_state.allocator);
    try job.appendProcess(shell_state.allocator, .{
        .stage_index = 0,
        .child = child,
        .status = if (job_state == .running) null else job.status,
        .stop_signal = if (job_state == .stopped) stopped_signal else null,
    });
    try shell_state.appendBackgroundJob(job);
    job.deinit(shell_state.allocator);
}

test "semantic job operands resolve current previous numeric prefix and substring forms" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try appendSemanticTestJob(&shell_state, 1, 7001, 7001, "alpha one", .running);
    try appendSemanticTestJob(&shell_state, 2, 7002, 7002, "beta two", .running);

    try std.testing.expectEqual(@as(usize, 2), try resolveBackgroundJobOperand(shell_state, null));
    try std.testing.expectEqual(@as(usize, 2), try resolveBackgroundJobOperand(shell_state, "%%"));
    try std.testing.expectEqual(@as(usize, 2), try resolveBackgroundJobOperand(shell_state, "%+"));
    try std.testing.expectEqual(@as(usize, 1), try resolveBackgroundJobOperand(shell_state, "%-"));
    try std.testing.expectEqual(@as(usize, 1), try resolveBackgroundJobOperand(shell_state, "%1"));
    try std.testing.expectEqual(@as(usize, 1), try resolveBackgroundJobOperand(shell_state, "1"));
    try std.testing.expectEqual(@as(usize, 1), try resolveBackgroundJobOperand(shell_state, "%alpha"));
    try std.testing.expectEqual(@as(usize, 2), try resolveBackgroundJobOperand(shell_state, "%?two"));
    try std.testing.expectError(error.UnknownJob, resolveBackgroundJobOperand(shell_state, "%?a"));
    try std.testing.expectError(error.UnknownJob, resolveBackgroundJobOperand(shell_state, "%99"));
}

test "semantic wait returns known background pid status and removes waited job" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setWaitStatuses(&.{.{ .exited = 7 }});
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try appendSemanticTestJob(&shell_state, 1, 7001, 7001, "alpha one", .running);

    const wait_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "wait",
        "7001",
    } } });
    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), wait_plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), result.status);
    try result.commitDelta(&shell_state, .current_shell);

    try std.testing.expectEqual(@as(usize, 0), shell_state.background_jobs.items.len);
    try std.testing.expectEqual(@as(state.ExitStatus, 7), shell_state.last_status);
}

test "semantic wait with multiple operands returns last operand status" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setWaitStatuses(&.{ .{ .exited = 3 }, .{ .exited = 5 } });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try appendSemanticTestJob(&shell_state, 1, 7001, 7001, "alpha one", .running);
    try appendSemanticTestJob(&shell_state, 2, 7002, 7002, "beta two", .running);

    const wait_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "wait",
        "7001",
        "7002",
    } } });
    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), wait_plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 5), result.status);
    try result.commitDelta(&shell_state, .current_shell);

    try std.testing.expectEqual(@as(usize, 0), shell_state.background_jobs.items.len);
    try std.testing.expectEqual(@as(state.ExitStatus, 5), shell_state.last_status);
}

test "semantic wait treats unknown pid as status 127 and keeps evaluating operands" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setWaitStatuses(&.{.{ .exited = 4 }});
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try appendSemanticTestJob(&shell_state, 1, 7001, 7001, "alpha one", .running);

    const known_last = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "wait",
        "999999",
        "7001",
    } } });
    var known_last_result = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        known_last,
    );
    defer known_last_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 4), known_last_result.status);
    try known_last_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.background_jobs.items.len);

    const unknown_last = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "wait",
        "999999",
    } } });
    var unknown_last_result = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        unknown_last,
    );
    defer unknown_last_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 127), unknown_last_result.status);
}

test "semantic wait without operands waits all known jobs and returns zero" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setWaitStatuses(&.{ .{ .exited = 3 }, .{ .exited = 5 } });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try appendSemanticTestJob(&shell_state, 1, 7001, 7001, "alpha one", .running);
    try appendSemanticTestJob(&shell_state, 2, 7002, 7002, "beta two", .running);

    const wait_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"wait"} } });
    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), wait_plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try result.commitDelta(&shell_state, .current_shell);

    try std.testing.expectEqual(@as(usize, 0), shell_state.background_jobs.items.len);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

test "semantic wait interrupted by trapped signal enqueues pending trap" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setPollWaitStatuses(&.{null});
    var fake_signal = FakeSignalRuntime.init();
    fake_signal.push(.{ .signal = 15 });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    evaluator.signal_port = fake_signal.port();
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.TERM, "echo term");
    try appendSemanticTestJob(&shell_state, 1, 7001, 7001, "alpha one", .running);

    const wait_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"wait"} } });
    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), wait_plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 143), result.status);
    try std.testing.expectEqual(@as(usize, 1), result.state_delta.pending_trap_enqueues.items.len);
    try std.testing.expectEqual(state.TrapSignal.TERM, result.state_delta.pending_trap_enqueues.items[0]);
    try result.commitDelta(&shell_state, .current_shell);

    try std.testing.expectEqual(@as(usize, 1), shell_state.background_jobs.items.len);
    try std.testing.expectEqual(@as(usize, 1), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(state.TrapSignal.TERM, shell_state.pending_traps.items[0]);
    try std.testing.expectEqual(@as(state.ExitStatus, 143), shell_state.last_status);
}

test "semantic bg continues selected stopped jobs and reports POSIX lines" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);
    try appendSemanticTestJob(&shell_state, 1, 7001, 8001, "alpha one", .stopped);
    try appendSemanticTestJob(&shell_state, 2, 7002, 8002, "beta two", .stopped);

    const bg_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "bg",
        "%-",
        "%?two",
    } } });
    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), bg_plan);
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("[1] alpha one\n[2] beta two\n", result.stdout.items);
    try std.testing.expectEqual(@as(usize, 2), fake.continue_count);
    try std.testing.expectEqual(
        runtime.process.ProcessTarget{ .process_group = 8002 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.observed_continue_target.?,
    );

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(state.JobState.running, shell_state.background_jobs.items[0].state);
    try std.testing.expectEqual(state.JobState.running, shell_state.background_jobs.items[1].state);
    try std.testing.expectEqual(@as(?usize, 2), shell_state.current_job_id);
    try std.testing.expectEqual(@as(?usize, 1), shell_state.previous_job_id);
}

test "semantic fg foregrounds continues waits and removes completed job" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setPollWaitStatuses(&.{ null, .{ .exited = 5 } });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);
    try appendSemanticTestJob(&shell_state, 1, 7001, 8001, "alpha one", .stopped);

    const fg_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"fg"} } });
    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), fg_plan);
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 5), result.status);
    try std.testing.expectEqualStrings("alpha one\n", result.stdout.items);
    try std.testing.expectEqual(@as(usize, 1), fake.continue_count);
    try std.testing.expectEqual(@as(usize, 2), fake.foreground_count);
    try std.testing.expectEqual(@as(runtime.process.ProcessId, 8001), fake.observed_foreground_process_groups[0]);
    try std.testing.expectEqual(@as(runtime.process.ProcessId, 42), fake.observed_foreground_process_groups[1]);

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.background_jobs.items.len);
    try std.testing.expectEqual(@as(?usize, null), shell_state.current_job_id);
}

test "semantic fg and bg report missing and invalid jobs" {
    var evaluator = Evaluator.init(std.testing.allocator);
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);

    const fg_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"fg"} } });
    var fg_result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), fg_plan);
    defer fg_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), fg_result.status);
    try std.testing.expectEqualStrings("fg: no current job\n", fg_result.stderr.items);

    const bg_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "bg",
        "%99",
    } } });
    var bg_result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), bg_plan);
    defer bg_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 127), bg_result.status);
    try std.testing.expectEqualStrings("bg: unknown job\n", bg_result.stderr.items);
}

test "semantic jobs builtin refreshes stopped and done jobs and drains notifications" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);

    const externals = [_]command_plan.ExternalResolution{.{ .name = "sleep", .path = "/bin/sleep" }};
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const sleep_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{ "sleep", "1" } },
        .lookup = lookup,
    });
    const background = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{.{ .simple = sleep_plan }},
        .{ .background = .background },
    );

    var background_result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        background,
    );
    defer background_result.deinit();
    try background_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.background_jobs.items.len);

    fake.setPollWaitStatuses(&.{.{ .stopped = signalNumber(.STOP) }});
    const jobs_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"jobs"} } });
    var stopped_jobs = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        jobs_plan,
    );
    defer stopped_jobs.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), stopped_jobs.status);
    try std.testing.expectEqualStrings("[1] + Stopped (SIGSTOP) 'sleep' '1'\n", stopped_jobs.stdout.items);
    try stopped_jobs.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(state.JobState.stopped, shell_state.background_jobs.items[0].state);
    try std.testing.expectEqual(@as(usize, 1), shell_state.pending_job_notifications.items.len);

    var stopped_notifications = try drainJobNotifications(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
    );
    defer stopped_notifications.deinit();
    try std.testing.expectEqualStrings("[1] Stopped (SIGSTOP) 'sleep' '1'\n", stopped_notifications.stdout.items);
    try stopped_notifications.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_job_notifications.items.len);

    fake.setPollWaitStatuses(&.{.{ .exited = 5 }});
    var done_jobs = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        jobs_plan,
    );
    defer done_jobs.deinit();
    try std.testing.expectEqualStrings("[1] + Done(5) 'sleep' '1'\n", done_jobs.stdout.items);
    try done_jobs.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.background_jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_job_notifications.items.len);

    var done_notifications = try drainJobNotifications(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
    );
    defer done_notifications.deinit();
    try std.testing.expectEqualStrings("", done_notifications.stdout.items);
    try done_notifications.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_job_notifications.items.len);
}

test "semantic drained done job notification removes completed job" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);

    try appendSemanticTestJob(&shell_state, 1, 7001, 7001, "sleep 1", .running);
    fake.setPollWaitStatuses(&.{.{ .exited = 5 }});

    var done_notifications = try drainJobNotifications(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
    );
    defer done_notifications.deinit();
    try std.testing.expectEqualStrings("[1] Done(5) sleep 1\n", done_notifications.stdout.items);
    try done_notifications.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.background_jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_job_notifications.items.len);

    const jobs_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"jobs"} } });
    var jobs_result = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        jobs_plan,
    );
    defer jobs_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), jobs_result.status);
    try std.testing.expectEqualStrings("", jobs_result.stdout.items);
}

test "semantic jobs builtin supports pid and long operands with diagnostics" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const externals = [_]command_plan.ExternalResolution{.{ .name = "tool", .path = "/bin/tool" }};
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const first_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{ "tool", "alpha" } },
        .lookup = lookup,
    });
    const second_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{ "tool", "beta" } },
        .lookup = lookup,
    });

    var first = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        pipeline_plan.PipelinePlan.init(
            &[_]pipeline_plan.PipelineStagePlan{.{ .simple = first_plan }},
            .{ .background = .background },
        ),
    );
    defer first.deinit();
    try first.commitDelta(&shell_state, .current_shell);
    var second = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        pipeline_plan.PipelinePlan.init(
            &[_]pipeline_plan.PipelineStagePlan{.{ .simple = second_plan }},
            .{ .background = .background },
        ),
    );
    defer second.deinit();
    try second.commitDelta(&shell_state, .current_shell);

    const jobs_pid = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{ "jobs", "-p", "%1" } },
    });
    var pid_result = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        jobs_pid,
    );
    defer pid_result.deinit();
    try std.testing.expectEqualStrings("9001\n", pid_result.stdout.items);
    try pid_result.commitDelta(&shell_state, .current_shell);

    const jobs_long_previous = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "jobs",
        "-l",
        "%-",
    } } });
    var long_result = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        jobs_long_previous,
    );
    defer long_result.deinit();
    try std.testing.expectEqualStrings("[1] - 9001 Running 'tool' 'alpha'\n", long_result.stdout.items);
    try long_result.commitDelta(&shell_state, .current_shell);

    const jobs_unknown = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "jobs",
        "%99",
    } } });
    var unknown_result = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        jobs_unknown,
    );
    defer unknown_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 127), unknown_result.status);
    try std.testing.expectEqualStrings("jobs: unknown job\n", unknown_result.stderr.items);
    try unknown_result.commitDelta(&shell_state, .current_shell);
}

test "semantic pipeline evaluation isolates builtin mutations from parent stages" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const true_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } });
    const first_export = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "export",
        "FIRST=leaked",
    } } });
    const first_pipeline = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = first_export }, .{ .simple = true_plan } },
        .{},
    );
    var first_result = try evaluatePipelinePlan(&evaluator, &shell_state, eval_context, first_pipeline);
    defer first_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), first_result.status);
    try first_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("FIRST"));
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 0, 0 }, shell_state.last_pipeline_statuses.items);

    const last_export = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "export",
        "LAST=leaked",
    } } });
    const last_pipeline = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = true_plan }, .{ .simple = last_export } },
        .{},
    );
    var last_result = try evaluatePipelinePlan(&evaluator, &shell_state, eval_context, last_pipeline);
    defer last_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), last_result.status);
    try last_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("LAST"));
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

test "semantic pipeline evaluation aggregates pipefail negation and errexit centrally" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.errexit, true);
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const false_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"false"} } });
    const true_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } });

    const pipefail = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = false_plan }, .{ .simple = true_plan } },
        .{ .status_rule = .pipefail },
    );
    var pipefail_result = try evaluatePipelinePlan(&evaluator, &shell_state, eval_context, pipefail);
    defer pipefail_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), pipefail_result.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        pipefail_result.control_flow,
    );
    try std.testing.expectEqualSlices(
        outcome.ExitStatus,
        &.{ 1, 0 },
        pipefail_result.state_delta.last_pipeline_statuses.?,
    );
    pipefail_result.discardDelta(.current_shell);

    const negated = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = false_plan }, .{ .simple = true_plan } },
        .{ .status_rule = .pipefail, .negated = true },
    );
    var negated_result = try evaluatePipelinePlan(&evaluator, &shell_state, eval_context, negated);
    defer negated_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), negated_result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, negated_result.control_flow);
    try negated_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 1, 0 }, shell_state.last_pipeline_statuses.items);
}

test "semantic pipeline evaluation wires external-only real pipelines through runtime pipes" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setWaitStatuses(&.{ .{ .exited = 3 }, .{ .exited = 0 }, .{ .exited = 4 } });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const externals = [_]command_plan.ExternalResolution{
        .{ .name = "a", .path = "/bin/a" },
        .{ .name = "b", .path = "/bin/b" },
        .{ .name = "c", .path = "/bin/c" },
    };
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const a = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"a"} },
        .lookup = lookup,
    });
    const b = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"b"} },
        .lookup = lookup,
    });
    const c = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"c"} },
        .lookup = lookup,
    });
    const plan = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = a }, .{ .simple = b }, .{ .simple = c } },
        .{ .status_rule = .pipefail },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 4), result.status);
    try std.testing.expectEqual(@as(usize, 3), fake.spawn_count);
    try std.testing.expectEqual(@as(usize, 3), fake.wait_count);
    try std.testing.expectEqual(runtime.process.StandardIo.inherit, fake.observed_spawn_stdin[0]);
    try std.testing.expectEqual(
        runtime.process.StandardIo{ .fd = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.observed_spawn_stdout[0],
    );
    try std.testing.expectEqual(
        runtime.process.StandardIo{ .fd = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.observed_spawn_stdin[1],
    );
    try std.testing.expectEqual(
        runtime.process.StandardIo{ .fd = 13 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.observed_spawn_stdout[1],
    );
    try std.testing.expectEqual(
        runtime.process.StandardIo{ .fd = 12 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.observed_spawn_stdin[2],
    );
    try std.testing.expectEqual(runtime.process.StandardIo.inherit, fake.observed_spawn_stdout[2]);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 3, 0, 4 }, result.state_delta.last_pipeline_statuses.?);

    try std.testing.expectEqual(@as(usize, 6), fake.fd_operation_count);
    try std.testing.expectEqual(
        FakeFdOperation{ .pipe = .{ .read = 10, .write = 11 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[0],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .pipe = .{ .read = 12, .write = 13 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[1],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[2],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[3],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 13 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[4],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 12 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[5],
    );

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 4), shell_state.last_status);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 3, 0, 4 }, shell_state.last_pipeline_statuses.items);
}

test "semantic mixed pipeline streams large input while external captures large stdout and stderr" {
    var adapter = runtime.PosixAdapter.init(std.testing.io);
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, adapter.fdPort(), adapter.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var large_input: std.ArrayList(u8) = .empty;
    defer large_input.deinit(std.testing.allocator);
    try large_input.appendNTimes(std.testing.allocator, 'i', 256 * 1024);

    const externals = [_]command_plan.ExternalResolution{.{ .name = "sh", .path = "/bin/sh" }};
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const producer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        large_input.items,
    } } });
    const sink = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "sh",
        "-c",
        "dd if=/dev/zero bs=1024 count=128 2>/dev/null; " ++
            "dd if=/dev/zero bs=1024 count=128 1>&2 2>/dev/null; wc -c >/dev/null",
    } }, .lookup = lookup });
    const plan = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = producer }, .{ .simple = sink } },
        .{},
    );
    try std.testing.expectEqual(pipeline_plan.PipelineExecutionStrategy.mixed_in_memory, plan.strategy);

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 128 * 1024), result.stdout.items.len);
    try std.testing.expectEqual(@as(usize, 128 * 1024), result.stderr.items.len);
    for (result.stdout.items) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (result.stderr.items) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 0, 0 }, result.state_delta.last_pipeline_statuses.?);
}

test "semantic background external pipeline starts a tracked job without waiting" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);

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
        .command = .{ .argv = &[_][]const u8{ "wc", "-l" } },
        .lookup = lookup,
    });
    const plan = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = cat }, .{ .simple = wc } },
        .{ .background = .background },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 2), fake.spawn_count);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_count);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 0), fake.observed_spawn_process_group[0]);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 9001), fake.observed_spawn_process_group[1]);
    try std.testing.expectEqual(
        runtime.process.StandardIo{ .fd = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.observed_spawn_stdout[0],
    );
    try std.testing.expectEqual(
        runtime.process.StandardIo{ .fd = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.observed_spawn_stdin[1],
    );
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 0, 0 }, result.state_delta.last_pipeline_statuses.?);
    try std.testing.expectEqual(@as(usize, 1), result.state_delta.background_jobs.items.len);

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
    try std.testing.expectEqual(@as(usize, 1), shell_state.background_jobs.items.len);
    const job = shell_state.background_jobs.items[0];
    try std.testing.expectEqual(@as(usize, 1), job.id);
    try std.testing.expectEqual(@as(runtime.process.ProcessId, 9002), job.pid);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 9001), job.process_group);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 9002), shell_state.last_background_pid);
    try std.testing.expectEqual(@as(?usize, 1), shell_state.current_job_id);
    try std.testing.expectEqual(@as(usize, 2), job.processes.items.len);
    try std.testing.expectEqual(@as(usize, 0), job.processes.items[0].stage_index);
    try std.testing.expectEqual(@as(usize, 1), job.processes.items[1].stage_index);
    try std.testing.expectEqualStrings("'cat' | 'wc' '-l'", job.command);
}

test "semantic background single external applies redirections and records process group" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);

    const externals = [_]command_plan.ExternalResolution{.{ .name = "tool", .path = "/bin/tool" }};
    const redirection_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        1,
        "out",
        .{ .access = .write_only, .create = true, .truncate = true },
    )};
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{
            .argv = &[_][]const u8{ "tool", "arg" },
            .redirections = .{ .steps = &redirection_steps },
        },
        .lookup = .{ .externals = &externals },
    });
    const pipeline = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{.{ .simple = plan }},
        .{ .background = .background },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        pipeline,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_count);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_count);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 0), fake.observed_process_group);
    try std.testing.expectEqual(@as(usize, 6), fake.fd_operation_count);
    try result.commitDelta(&shell_state, .current_shell);

    const job = shell_state.background_jobs.items[0];
    try std.testing.expectEqual(@as(runtime.process.ProcessId, 9001), job.pid);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 9001), job.process_group);
    try std.testing.expectEqualStrings("'tool' 'arg'", job.command);
}

test "semantic background builtin starts tracked subshell without parent mutation leakage" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.monitor, true);

    const export_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "export",
        "BG_LEAK=child",
    } } });
    const pipeline = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{.{ .simple = export_plan }},
        .{ .background = .background },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        pipeline,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), fake.start_subshell_count);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_count);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 0), fake.observed_subshell_process_group);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{0}, result.state_delta.last_pipeline_statuses.?);
    try std.testing.expectEqual(@as(usize, 1), result.state_delta.background_jobs.items.len);

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("BG_LEAK"));
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{0}, shell_state.last_pipeline_statuses.items);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 9101), shell_state.last_background_pid);
    try std.testing.expectEqual(@as(?usize, 1), shell_state.current_job_id);
    const job = shell_state.background_jobs.items[0];
    try std.testing.expectEqual(@as(runtime.process.ProcessId, 9101), job.pid);
    try std.testing.expectEqual(@as(?runtime.process.ProcessId, 9101), job.process_group);
    try std.testing.expectEqual(@as(usize, 1), job.processes.items.len);
    try std.testing.expectEqualStrings("'export' 'BG_LEAK=child'", job.command);
}

test "semantic background compound command is tracked as one subshell job" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const export_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "export",
        "COMPOUND_LEAK=child",
    } } });
    const compound: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .brace_group = .{ .commands = &[_]command_plan.CommandPlan{export_plan} } },
    };
    const pipeline = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{.{ .compound = compound }},
        .{ .background = .background },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        pipeline,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.start_subshell_count);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_count);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_count);

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("COMPOUND_LEAK"));
    try std.testing.expectEqualStrings("brace group", shell_state.background_jobs.items[0].command);
}

test "semantic background mixed pipeline starts one subshell without foreground streaming" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const externals = [_]command_plan.ExternalResolution{.{ .name = "sink", .path = "/bin/sink" }};
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const producer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        "payload",
    } } });
    const sink = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"sink"} },
        .lookup = lookup,
    });
    const pipeline = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = producer }, .{ .simple = sink } },
        .{ .background = .background },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        pipeline,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.start_subshell_count);
    try std.testing.expectEqual(@as(usize, 0), fake.spawn_count);
    try std.testing.expectEqual(@as(usize, 0), fake.run_count);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_count);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 0, 0 }, result.state_delta.last_pipeline_statuses.?);

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("'printf' 'payload' | 'sink'", shell_state.background_jobs.items[0].command);
}

test "semantic background builtin redirections are guarded and restored around launch" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const redirection_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        1,
        "semantic-out",
        .{ .access = .write_only, .create = true, .truncate = true },
    )};
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .argv = &[_][]const u8{ "printf", "payload" },
        .redirections = .{ .steps = &redirection_steps },
    } });
    const pipeline = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{.{ .simple = plan }},
        .{ .background = .background },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        pipeline,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.start_subshell_count);
    try std.testing.expectEqual(@as(usize, 0), fake.wait_count);
    try std.testing.expectEqual(@as(usize, 6), fake.fd_operation_count);
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[0],
    );
    switch (fake.fd_operations[1]) {
        .open => |path| try std.testing.expectEqualStrings("semantic-out", path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 11, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[2],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[3],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 10, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[4],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[5],
    );

    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("'printf' 'payload'", shell_state.background_jobs.items[0].command);
}

test "semantic pipeline evaluation streams builtin output into read builtin stdin" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);

    const producer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        "payload\n",
    } } });
    const consumer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "read",
        "PIPE_VALUE",
    } } });
    const plan = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = producer }, .{ .simple = consumer } },
        .{},
    );
    try std.testing.expectEqual(pipeline_plan.PipelineExecutionStrategy.semantic_in_memory, plan.strategy);

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout.items);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 0, 0 }, result.state_delta.last_pipeline_statuses.?);
    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("PIPE_VALUE"));
}

test "semantic evaluator reads through custom delimiters" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var input = EvaluationInput.init("ab:cd");
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "read",
        "-r",
        "-d",
        ":",
        "value",
    } } });

    var frame = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var result = try evaluatePlanWithInput(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
        &input,
        &frame,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("ab", shell_state.getVariable("value").?.value);
    try std.testing.expectEqualStrings("cd", input.remaining());
}

test "semantic evaluator read reports EOF after escaped newline continuation" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var input = EvaluationInput.init("a\\ b c\\\n");
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "read",
        "x",
        "y",
    } } });

    var frame = rootExecutionFrame(context.EvalContext.forTarget(.current_shell));
    var result = try evaluatePlanWithInput(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
        &input,
        &frame,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), result.status);
    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("a b", shell_state.getVariable("x").?.value);
    try std.testing.expectEqualStrings("c", shell_state.getVariable("y").?.value);
}

test "semantic pipeline evaluation streams semantic output into external stdin" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setRunResult("external-out\n", "", .{ .exited = 0 });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const externals = [_]command_plan.ExternalResolution{.{ .name = "sink", .path = "/bin/sink" }};
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const producer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "printf",
        "to-external",
    } } });
    const sink = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"sink"} },
        .lookup = lookup,
    });
    const plan = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = producer }, .{ .simple = sink } },
        .{},
    );
    try std.testing.expectEqual(pipeline_plan.PipelineExecutionStrategy.mixed_in_memory, plan.strategy);

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.run_count);
    try std.testing.expectEqualStrings("to-external", fake.observed_run_stdin.items);
    try std.testing.expectEqualStrings("external-out\n", result.stdout.items);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 0, 0 }, result.state_delta.last_pipeline_statuses.?);
}

test "semantic pipeline evaluation streams external output into semantic stdin" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setRunResult("from-external\n", "", .{ .exited = 0 });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const externals = [_]command_plan.ExternalResolution{.{ .name = "extsource", .path = "/bin/extsource" }};
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const source = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"extsource"} },
        .lookup = lookup,
    });
    const consumer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "read",
        "PIPE_VALUE",
    } } });
    const plan = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = source }, .{ .simple = consumer } },
        .{},
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), fake.run_count);
    try std.testing.expectEqualStrings("", fake.observed_run_stdin.items);
    try std.testing.expectEqualStrings("", result.stdout.items);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 0, 0 }, result.state_delta.last_pipeline_statuses.?);
    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("PIPE_VALUE"));
}

test "semantic pipeline evaluation keeps mixed status policy and redirection guards" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.setRunResult("", "", .{ .exited = 3 });
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const redirection_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        1,
        "mixed-out",
        .{ .access = .write_only, .create = true, .truncate = true },
    )};
    const redirections: redirection_plan.RedirectionPlan = .{
        .steps = &redirection_steps,
    };
    const externals = [_]command_plan.ExternalResolution{.{ .name = "failer", .path = "/bin/failer" }};
    const lookup: command_plan.LookupSnapshot = .{ .externals = &externals };
    const failer = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"failer"}, .redirections = redirections },
        .lookup = lookup,
    });
    const ok = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } });
    const plan = pipeline_plan.PipelinePlan.init(
        &[_]pipeline_plan.PipelineStagePlan{ .{ .simple = failer }, .{ .simple = ok } },
        .{ .status_rule = .pipefail, .negated = true },
    );

    var result = try evaluatePipelinePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        plan,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try std.testing.expectEqualSlices(outcome.ExitStatus, &.{ 3, 0 }, result.state_delta.last_pipeline_statuses.?);
    try std.testing.expectEqual(@as(usize, 1), fake.run_count);
    try std.testing.expectEqual(@as(usize, 6), fake.fd_operation_count);
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[0],
    );
    switch (fake.fd_operations[1]) {
        .open => |path| try std.testing.expectEqualStrings("mixed-out", path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 11, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[2],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[3],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 10, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[4],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[5],
    );
}

test "semantic evaluator centralizes simple-command errexit and readonly consequences" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.errexit, true);
    try shell_state.putVariable("LOCKED", "old", .{ .readonly = true });

    var evaluator = Evaluator.init(std.testing.allocator);

    const false_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"false"} } });
    var failed = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), false_plan);
    defer failed.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), failed.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        failed.control_flow,
    );
    try std.testing.expectEqual(@as(state.ExitStatus, 1), failed.state_delta.last_status.?);
    failed.discardDelta(.current_shell);

    var suppressed = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell).ignoreErrexit(),
        false_plan,
    );
    defer suppressed.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), suppressed.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, suppressed.control_flow);
    suppressed.discardDelta(.current_shell);

    const readonly_assignments = [_]command_plan.Assignment{.{ .name = "LOCKED", .value = "new" }};
    const readonly_plan = command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &readonly_assignments } },
    );
    var readonly = try evaluatePlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell).ignoreErrexit(),
        readonly_plan,
    );
    defer readonly.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), readonly.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .fatal = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        readonly.control_flow,
    );
    try std.testing.expectEqualStrings("LOCKED: readonly variable", readonly.diagnostics.items[0].message);
    try readonly.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("old", shell_state.getVariable("LOCKED").?.value);
    try std.testing.expectEqual(@as(state.ExitStatus, 1), shell_state.last_status);
}

test "semantic evaluator suppresses errexit in POSIX condition and list contexts" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.errexit, true);
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const if_assignment = [_]command_plan.Assignment{.{ .name = "IF_ERREXIT", .value = "else" }};
    const if_branches = [_]command_plan.IfBranch{.{
        .condition = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
            .{ .command = .{ .argv = &[_][]const u8{"false"} } },
        )} },
        .body = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{
                "echo",
                "unreached",
            } },
        })} },
    }};
    const if_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .if_clause = .{
            .branches = &if_branches,
            .else_body = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
                .{ .command = .{ .assignments = &if_assignment } },
            )} },
        } },
    };
    var if_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, if_plan);
    defer if_result.deinit();
    try std.testing.expectEqual(outcome.ControlFlow.normal, if_result.control_flow);
    try if_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("else", shell_state.getVariable("IF_ERREXIT").?.value);

    const skipped_assignment = [_]command_plan.Assignment{.{ .name = "AND_ERREXIT_SKIPPED", .value = "bad" }};
    const and_or_commands = [_]command_plan.AndOrCommand{
        .{ .command = command_plan.classifyExpandedSimpleCommand(
            .{ .command = .{ .argv = &[_][]const u8{"false"} } },
        ) },
        .{
            .operator = .and_if,
            .command = command_plan.classifyExpandedSimpleCommand(
                .{ .command = .{ .assignments = &skipped_assignment } },
            ),
        },
    };
    const and_or_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .and_or_list = .{ .commands = &and_or_commands } },
    };
    var and_or_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, and_or_plan);
    defer and_or_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), and_or_result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, and_or_result.control_flow);
    try and_or_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("AND_ERREXIT_SKIPPED"));

    const negation_commands = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .argv = &[_][]const u8{"true"} } },
    )};
    const negation_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .negation = .{ .body = .{ .commands = &negation_commands } } },
    };
    var negation_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, negation_plan);
    defer negation_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), negation_result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, negation_result.control_flow);
    negation_result.discardDelta(.current_shell);

    const terminal_and_or = [_]command_plan.AndOrCommand{
        .{ .command = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } }) },
        .{
            .operator = .and_if,
            .command = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"false"} } }),
        },
    };
    const terminal_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .and_or_list = .{ .commands = &terminal_and_or } },
    };
    var terminal_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, terminal_plan);
    defer terminal_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), terminal_result.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        terminal_result.control_flow,
    );
    terminal_result.discardDelta(.current_shell);
}

test "semantic evaluator keeps shell-error fatality outside errexit suppression" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.errexit, true);
    var evaluator = Evaluator.init(std.testing.allocator);

    const if_branches = [_]command_plan.IfBranch{.{
        .condition = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
            .{ .command = .{ .argv = &[_][]const u8{"return"} } },
        )} },
        .body = .{},
    }};
    const if_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .if_clause = .{ .branches = &if_branches } },
    };
    var result = try evaluateCompoundPlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        if_plan,
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), result.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .fatal = 2 }, // ziglint-ignore: Z010 (expectEqual peer)
        result.control_flow,
    );
    try std.testing.expectEqualStrings("return: not in a function or dot script", result.diagnostics.items[0].message);
    result.discardDelta(.current_shell);
}

test "semantic evaluator treats eval parse errors as special builtin shell errors" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);
    const script = "if then echo bad; fi";

    const direct_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "eval",
        script,
    } } });
    var direct = try evaluatePlan(&evaluator, &shell_state, eval_context, direct_plan);
    defer direct.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), direct.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .fatal = 2 }, // ziglint-ignore: Z010 (expectEqual peer)
        direct.control_flow,
    );
    direct.discardDelta(.current_shell);

    const command_plan_value = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "command",
        "eval",
        script,
    } } });
    var command_result = try evaluatePlan(&evaluator, &shell_state, eval_context, command_plan_value);
    defer command_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), command_result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, command_result.control_flow);
    command_result.discardDelta(.current_shell);
}

test "semantic evaluator treats nonzero eval command status as a status not a utility error" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
        "eval",
        "false",
    } } });
    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, result.control_flow);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    result.discardDelta(.current_shell);
}

test "semantic evaluator routes redirection failure consequences through central policy" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithFdPort(std.testing.allocator, fake.fdPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.errexit, true);

    const command_failure_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        0,
        "missing",
        .{ .access = .read_only },
    )};
    const command_failure_redirections: redirection_plan.RedirectionPlan = .{
        .steps = &command_failure_steps,
    };
    const command_failure_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .redirections = command_failure_redirections,
        .body = .{ .brace_group = .{} },
    };
    var command_failure = try evaluateCompoundPlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        command_failure_plan,
    );
    defer command_failure.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), command_failure.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        command_failure.control_flow,
    );
    command_failure.discardDelta(.current_shell);

    const fatal_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        0,
        "missing",
        .{ .access = .read_only },
    )};
    const fatal_redirections: redirection_plan.RedirectionPlan = .{
        .steps = &fatal_steps,
        .failure_consequence = .fatal_shell_error,
    };
    const fatal_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .redirections = fatal_redirections,
        .body = .{ .brace_group = .{} },
    };
    var fatal = try evaluateCompoundPlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell).ignoreErrexit(),
        fatal_plan,
    );
    defer fatal.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), fatal.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .fatal = 2 }, // ziglint-ignore: Z010 (expectEqual peer)
        fatal.control_flow,
    );
    fatal.discardDelta(.current_shell);
}

test "semantic evaluator evaluates compound if loop for and case forms" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const if_assignment = [_]command_plan.Assignment{.{ .name = "IF_RESULT", .value = "elif" }};
    const if_commands = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &if_assignment } },
    )};
    const if_branches = [_]command_plan.IfBranch{
        .{
            .condition = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
                .{ .command = .{ .argv = &[_][]const u8{"false"} } },
            )} },
            .body = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(.{
                .command = .{ .argv = &[_][]const u8{
                    "echo",
                    "unreached",
                } },
            })} },
        },
        .{
            .condition = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
                .{ .command = .{ .argv = &[_][]const u8{"true"} } },
            )} },
            .body = .{ .commands = &if_commands },
        },
    };
    const if_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .if_clause = .{ .branches = &if_branches } },
    };
    var if_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, if_plan);
    defer if_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), if_result.status);
    try if_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("elif", shell_state.getVariable("IF_RESULT").?.value);

    const skipped_assignment = [_]command_plan.Assignment{.{ .name = "AND_SKIPPED", .value = "bad" }};
    const or_assignment = [_]command_plan.Assignment{.{ .name = "OR_RESULT", .value = "ran" }};
    const and_or_commands = [_]command_plan.AndOrCommand{
        .{ .command = command_plan.classifyExpandedSimpleCommand(
            .{ .command = .{ .argv = &[_][]const u8{"false"} } },
        ) },
        .{
            .operator = .and_if,
            .command = command_plan.classifyExpandedSimpleCommand(
                .{ .command = .{ .assignments = &skipped_assignment } },
            ),
        },
        .{
            .operator = .or_if,
            .command = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &or_assignment } }),
        },
    };
    const and_or_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .and_or_list = .{ .commands = &and_or_commands } },
    };
    var and_or_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, and_or_plan);
    defer and_or_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), and_or_result.status);
    try and_or_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("AND_SKIPPED"));
    try std.testing.expectEqualStrings("ran", shell_state.getVariable("OR_RESULT").?.value);

    const negation_commands = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .argv = &[_][]const u8{"false"} } },
    )};
    const negation_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .negation = .{ .body = .{ .commands = &negation_commands } } },
    };
    var negation_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, negation_plan);
    defer negation_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), negation_result.status);
    try negation_result.commitDelta(&shell_state, .current_shell);

    const loop_assignment = [_]command_plan.Assignment{.{ .name = "LOOP_RESULT", .value = "entered" }};
    const loop_body = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &loop_assignment } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"break"} } }),
    };
    const loop_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .while_loop = .{
            .condition = .{ .commands = &[_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
                .{ .command = .{ .argv = &[_][]const u8{"true"} } },
            )} },
            .body = .{ .commands = &loop_body },
        } },
    };
    var loop_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, loop_plan);
    defer loop_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), loop_result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, loop_result.control_flow);
    try loop_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("entered", shell_state.getVariable("LOOP_RESULT").?.value);

    const for_words = [_][]const u8{ "one", "two" };
    const for_body = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .argv = &[_][]const u8{"continue"} } },
    )};
    const for_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .for_loop = .{
            .variable_name = "ITEM",
            .words = .{ .explicit = &for_words },
            .body = .{ .commands = &for_body },
        } },
    };
    var for_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, for_plan);
    defer for_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), for_result.status);
    try for_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("two", shell_state.getVariable("ITEM").?.value);

    const case_assignment = [_]command_plan.Assignment{.{ .name = "CASE_RESULT", .value = "matched" }};
    const case_body = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &case_assignment } },
    )};
    const case_arms = [_]command_plan.CaseArm{
        .{ .patterns = &[_][]const u8{"one"}, .body = .{} },
        .{ .patterns = &[_][]const u8{ "t?o", "[ab]" }, .body = .{ .commands = &case_body } },
    };
    const case_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .case_clause = .{ .word = "two", .arms = &case_arms } },
    };
    var case_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, case_plan);
    defer case_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), case_result.status);
    try case_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("matched", shell_state.getVariable("CASE_RESULT").?.value);

    const fallthrough_first_assignment = [_]command_plan.Assignment{.{
        .name = "CASE_FALLTHROUGH_FIRST",
        .value = "yes",
    }};
    const fallthrough_second_assignment = [_]command_plan.Assignment{.{
        .name = "CASE_FALLTHROUGH_SECOND",
        .value = "yes",
    }};
    const fallthrough_first_body = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &fallthrough_first_assignment } },
    )};
    const fallthrough_second_body = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &fallthrough_second_assignment } },
    )};
    const fallthrough_arms = [_]command_plan.CaseArm{
        .{ .patterns = &[_][]const u8{"fall"}, .body = .{ .commands = &fallthrough_first_body }, .fallthrough = true },
        .{ .patterns = &[_][]const u8{"no-match"}, .body = .{ .commands = &fallthrough_second_body } },
    };
    const fallthrough_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .case_clause = .{ .word = "fall", .arms = &fallthrough_arms } },
    };
    var fallthrough_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, fallthrough_plan);
    defer fallthrough_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), fallthrough_result.status);
    try fallthrough_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("yes", shell_state.getVariable("CASE_FALLTHROUGH_FIRST").?.value);
    try std.testing.expectEqualStrings("yes", shell_state.getVariable("CASE_FALLTHROUGH_SECOND").?.value);

    const test_next_first_assignment = [_]command_plan.Assignment{.{ .name = "CASE_TEST_NEXT_FIRST", .value = "yes" }};
    const test_next_second_assignment = [_]command_plan.Assignment{.{
        .name = "CASE_TEST_NEXT_SECOND",
        .value = "yes",
    }};
    const test_next_first_body = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &test_next_first_assignment } },
    )};
    const test_next_second_body = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &test_next_second_assignment } },
    )};
    const test_next_arms = [_]command_plan.CaseArm{
        .{ .patterns = &[_][]const u8{"test"}, .body = .{ .commands = &test_next_first_body }, .test_next = true },
        .{ .patterns = &[_][]const u8{"test"}, .body = .{ .commands = &test_next_second_body } },
    };
    const test_next_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .case_clause = .{ .word = "test", .arms = &test_next_arms } },
    };
    var test_next_result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, test_next_plan);
    defer test_next_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), test_next_result.status);
    try test_next_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("yes", shell_state.getVariable("CASE_TEST_NEXT_FIRST").?.value);
    try std.testing.expectEqualStrings("yes", shell_state.getVariable("CASE_TEST_NEXT_SECOND").?.value);
}

test "semantic evaluator matches case patterns with POSIX character classes" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const matched_assignment = [_]command_plan.Assignment{.{ .name = "CASE_CLASS", .value = "digit" }};
    const matched_body = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .assignments = &matched_assignment } },
    )};
    const case_arms = [_]command_plan.CaseArm{
        .{ .patterns = &[_][]const u8{"[![:digit:]]"}, .body = .{} },
        .{ .patterns = &[_][]const u8{"[[:digit:]]"}, .body = .{ .commands = &matched_body } },
    };
    const case_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .case_clause = .{ .word = "7", .arms = &case_arms } },
    };

    var result = try evaluateCompoundPlan(&evaluator, &shell_state, eval_context, case_plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), result.status);
    try result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("digit", shell_state.getVariable("CASE_CLASS").?.value);
}

test "semantic evaluator applies compound command commit and discard boundaries" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);

    const parent_assignment = [_]command_plan.Assignment{.{ .name = "PARENT", .value = "changed" }};
    const parent_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &parent_assignment } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"false"} } }),
    };
    const brace_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .brace_group = .{ .commands = &parent_commands } },
    };
    var brace_result = try evaluateCompoundPlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        brace_plan,
    );
    defer brace_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), brace_result.status);
    try brace_result.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("changed", shell_state.getVariable("PARENT").?.value);
    try std.testing.expectEqual(@as(state.ExitStatus, 1), shell_state.last_status);

    const subshell_assignment = [_]command_plan.Assignment{.{ .name = "SUBSHELL", .value = "hidden" }};
    const subshell_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .assignments = &subshell_assignment },
            .target = .subshell,
        }),
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{ "exit", "7" } },
            .target = .subshell,
        }),
    };
    const subshell_plan: command_plan.CompoundCommandPlan = .{
        .target = .subshell,
        .body = .{ .subshell = .{ .commands = &subshell_commands } },
    };
    var subshell_result = try evaluateCompoundPlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell).enterSubshell(),
        subshell_plan,
    );
    defer subshell_result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), subshell_result.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, subshell_result.control_flow);
    try std.testing.expectEqual(context.ExecutionTarget.subshell, subshell_result.state_delta.target);
    subshell_result.discardDelta(.subshell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("SUBSHELL"));
    try std.testing.expectEqual(@as(state.ExitStatus, 1), shell_state.last_status);
}

test "semantic evaluator propagates current-shell compound control flow" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);

    const exit_commands = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{
            "exit",
            "5",
        } },
    })};
    const brace_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .body = .{ .brace_group = .{ .commands = &exit_commands } },
    };
    var result = try evaluateCompoundPlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        brace_plan,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 5), result.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 5 }, // ziglint-ignore: Z010 (expectEqual peer)
        result.control_flow,
    );
    result.discardDelta(.current_shell);
}

test "semantic evaluator applies and restores compound command redirections" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithFdPort(std.testing.allocator, fake.fdPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const redirection_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        1,
        "compound-out",
        .{ .access = .write_only, .create = true, .truncate = true },
    )};
    const redirections: redirection_plan.RedirectionPlan = .{
        .steps = &redirection_steps,
    };
    const body_commands = [_]command_plan.CommandPlan{command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{
            "exit",
            "4",
        } },
    })};
    const compound_plan: command_plan.CompoundCommandPlan = .{
        .target = .current_shell,
        .redirections = redirections,
        .body = .{ .brace_group = .{ .commands = &body_commands } },
    };

    var result = try evaluateCompoundPlan(
        &evaluator,
        &shell_state,
        context.EvalContext.forTarget(.current_shell),
        compound_plan,
    );
    defer result.deinit();
    try std.testing.expectEqual(
        outcome.ControlFlow{ .exit = 4 }, // ziglint-ignore: Z010 (expectEqual peer)
        result.control_flow,
    );
    try std.testing.expectEqual(@as(usize, 6), fake.fd_operation_count);
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[0],
    );
    switch (fake.fd_operations[1]) {
        .open => |path| try std.testing.expectEqualStrings("compound-out", path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 11, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[2],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[3],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 10, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[4],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[5],
    );
    result.discardDelta(.current_shell);
}

test "semantic evaluator stores and invokes function definitions through explicit frames" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const body_assignments = [_]command_plan.Assignment{.{ .name = "BODY", .value = "changed" }};
    const body_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &body_assignments } }),
    };
    const definition: command_plan.FunctionDefinition = .{ .name = "fn", .body = .{ .commands = &body_commands } };
    const definition_plan: command_plan.CommandPlan = .{
        .target = .current_shell,
        .classification = .{ .function_definition = definition },
    };

    var defined = try evaluatePlan(&evaluator, &shell_state, eval_context, definition_plan);
    defer defined.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), defined.status);
    try std.testing.expectEqual(@as(usize, 1), defined.state_delta.function_sets.items.len);
    try defined.commitDelta(&shell_state, .current_shell);
    try std.testing.expect(shell_state.getFunction("fn") != null);
    try std.testing.expectEqual(@as(usize, 1), shell_state.getFunction("fn").?.body.commands.len);

    const stored = shell_state.getFunction("fn").?;
    const lookup_functions = [_]command_plan.FunctionDefinition{stored};
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"fn"} },
        .lookup = .{ .functions = &lookup_functions },
    });

    var call = try evaluatePlan(&evaluator, &shell_state, eval_context, call_plan);
    defer call.deinit();
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("BODY"));
    try call.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("changed", shell_state.getVariable("BODY").?.value);
}

test "semantic evaluator keeps function assignment prefixes locals and positionals scoped" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("A", "outer", .{});
    try shell_state.replacePositionals(&.{});

    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const assign_a = [_]command_plan.Assignment{.{ .name = "A", .value = "inner" }};
    const assign_b = [_]command_plan.Assignment{.{ .name = "B", .value = "body" }};
    const body_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
            "local",
            "LOCAL=hidden",
        } } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assign_a } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assign_b } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "shift", "1" } } }),
    };
    const definition: command_plan.FunctionDefinition = .{ .name = "fn", .body = .{ .commands = &body_commands } };
    const lookup_functions = [_]command_plan.FunctionDefinition{definition};
    const prefixes = [_]command_plan.Assignment{.{ .name = "A", .value = "temporary" }};
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &prefixes, .argv = &[_][]const u8{ "fn", "arg" } },
        .lookup = .{ .functions = &lookup_functions },
    });

    var call = try evaluatePlan(&evaluator, &shell_state, eval_context, call_plan);
    defer call.deinit();
    try call.commitDelta(&shell_state, .current_shell);

    try std.testing.expectEqualStrings("outer", shell_state.getVariable("A").?.value);
    try std.testing.expectEqualStrings("body", shell_state.getVariable("B").?.value);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("LOCAL"));
    try std.testing.expectEqual(@as(usize, 0), shell_state.positionals.items.len);
}

test "semantic evaluator consumes return control flow at function boundary" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const body_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "echo", "before" } } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "return", "7" } } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "echo", "after" } } }),
    };
    const definition: command_plan.FunctionDefinition = .{ .name = "fn", .body = .{ .commands = &body_commands } };
    const lookup_functions = [_]command_plan.FunctionDefinition{definition};
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"fn"} },
        .lookup = .{ .functions = &lookup_functions },
    });

    var call = try evaluatePlan(&evaluator, &shell_state, eval_context, call_plan);
    defer call.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), call.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, call.control_flow);
    try std.testing.expectEqualStrings("before\n", call.stdout.items);
    try call.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 7), shell_state.last_status);

    const outside_return = command_plan.classifyExpandedSimpleCommand(
        .{ .command = .{ .argv = &[_][]const u8{"return"} } },
    );
    var outside = try evaluatePlan(&evaluator, &shell_state, eval_context, outside_return);
    defer outside.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), outside.status);
    try std.testing.expectEqual(
        outcome.ControlFlow{ .fatal = 2 }, // ziglint-ignore: Z010 (expectEqual peer)
        outside.control_flow,
    );
    try std.testing.expectEqualStrings("return: not in a function or dot script", outside.diagnostics.items[0].message);
    outside.discardDelta(.current_shell);
}

test "semantic evaluator stops function body after readonly assignment failure" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("LOCKED", "outer", .{ .readonly = true });
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.init(.{ .target = .current_shell, .interactive = true });

    const assignment = [_]command_plan.Assignment{.{ .name = "LOCKED", .value = "inner" }};
    const after_assignment = [_]command_plan.Assignment{.{ .name = "AFTER", .value = "bad" }};
    const body_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignment } }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &after_assignment } }),
    };
    const definition: command_plan.FunctionDefinition = .{ .name = "fn", .body = .{ .commands = &body_commands } };
    const lookup_functions = [_]command_plan.FunctionDefinition{definition};
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"fn"} },
        .lookup = .{ .functions = &lookup_functions },
    });

    var call = try evaluatePlan(&evaluator, &shell_state, eval_context, call_plan);
    defer call.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), call.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, call.control_flow);
    try std.testing.expectEqualStrings("LOCKED: readonly variable", call.diagnostics.items[0].message);
    try call.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("outer", shell_state.getVariable("LOCKED").?.value);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("AFTER"));
    try std.testing.expectEqual(@as(state.ExitStatus, 1), shell_state.last_status);
}

test "semantic evaluator uses child command status for bare function return" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.wait_status = .{ .exited = 9 };
    fake.run_status = .{ .exited = 9 };
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const externals = [_]command_plan.ExternalResolution{.{ .name = "tool", .path = "/bin/tool" }};
    const body_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{
            .command = .{ .argv = &[_][]const u8{"tool"} },
            .lookup = .{ .externals = &externals },
        }),
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"return"} } }),
    };
    const definition: command_plan.FunctionDefinition = .{ .name = "fn", .body = .{ .commands = &body_commands } };
    const lookup_functions = [_]command_plan.FunctionDefinition{definition};
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"fn"} },
        .lookup = .{ .functions = &lookup_functions },
    });

    var call = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), call_plan);
    defer call.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 9), call.status);
    try std.testing.expectEqual(outcome.ControlFlow.normal, call.control_flow);
    try call.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 9), shell_state.last_status);
}

test "semantic evaluator reports readonly local declarations as shell errors" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("LOCKED", "outer", .{ .readonly = true });
    var evaluator = Evaluator.init(std.testing.allocator);

    const body_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{
            "local",
            "LOCKED=inner",
        } } }),
    };
    const definition: command_plan.FunctionDefinition = .{ .name = "fn", .body = .{ .commands = &body_commands } };
    const lookup_functions = [_]command_plan.FunctionDefinition{definition};
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"fn"} },
        .lookup = .{ .functions = &lookup_functions },
    });

    var call = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), call_plan);
    defer call.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), call.status);
    try std.testing.expectEqualStrings("local: readonly variable", call.diagnostics.items[0].message);
    try call.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("outer", shell_state.getVariable("LOCKED").?.value);
    try std.testing.expect(shell_state.getVariable("LOCKED").?.readonly);
}

test "semantic evaluator applies and restores function call and definition redirections" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithFdPort(std.testing.allocator, fake.fdPort());
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const body_commands = [_]command_plan.CommandPlan{
        command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } }),
    };
    const definition_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        1,
        "definition-out",
        .{ .access = .write_only, .create = true, .truncate = true },
    )};
    const definition_redirections: redirection_plan.RedirectionPlan = .{
        .steps = &definition_steps,
    };
    const definition: command_plan.FunctionDefinition = .{
        .name = "fn",
        .body = .{ .commands = &body_commands },
        .redirections = definition_redirections,
    };
    const lookup_functions = [_]command_plan.FunctionDefinition{definition};
    const call_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        1,
        "call-out",
        .{ .access = .write_only, .create = true, .truncate = true },
    )};
    const call_redirections: redirection_plan.RedirectionPlan = .{
        .steps = &call_steps,
    };
    const call_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"fn"}, .redirections = call_redirections },
        .lookup = .{ .functions = &lookup_functions },
    });

    var call = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.current_shell), call_plan);
    defer call.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), call.status);
    try std.testing.expectEqualStrings("", call.stdout.items);
    try std.testing.expectEqual(@as(usize, 12), fake.fd_operation_count);
    switch (fake.fd_operations[1]) {
        .open => |path| try std.testing.expectEqualStrings("call-out", path),
        else => return error.TestUnexpectedResult,
    }
    switch (fake.fd_operations[5]) {
        .open => |path| try std.testing.expectEqualStrings("definition-out", path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 12, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[8],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 10, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[10],
    );
    call.discardDelta(.current_shell);
}

test "semantic evaluator executes external commands through runtime process and fd ports" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("FOO", "parent", .{ .exported = true });
    try shell_state.putVariable("PATH", "/mock/bin", .{ .exported = true });
    try shell_state.putVariable("HIDDEN", "secret", .{});

    const assignments = [_]command_plan.Assignment{
        .{ .name = "FOO", .value = "child" },
        .{ .name = "TEMP", .value = "value" },
    };
    const argv = [_][]const u8{ "tool", "arg" };
    const externals = [_]command_plan.ExternalResolution{.{ .name = "tool", .path = "/mock/bin/tool" }};
    const redirection_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.openPath(
        0,
        1,
        "out",
        .{ .access = .write_only, .create = true, .truncate = true },
    )};
    const redirections: redirection_plan.RedirectionPlan = .{
        .steps = &redirection_steps,
    };
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &assignments, .argv = &argv, .redirections = redirections },
        .lookup = .{ .externals = &externals },
    });
    const eval_context = context.EvalContext.forTarget(.child_process);

    var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
    defer result.deinit();

    try std.testing.expectEqual(@as(outcome.ExitStatus, 7), result.status);
    try std.testing.expectEqual(@as(state.ExitStatus, 7), result.state_delta.last_status.?);
    try std.testing.expectEqual(context.ExecutionTarget.child_process, result.state_delta.target);
    try std.testing.expectEqual(@as(usize, 1), fake.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), fake.wait_count);
    try std.testing.expectEqualStrings("/mock/bin/tool", fake.observed_argv.items[0]);
    try std.testing.expectEqualStrings("arg", fake.observed_argv.items[1]);
    try std.testing.expectEqualStrings("child", fake.observed_environment.get("FOO").?);
    try std.testing.expectEqualStrings("value", fake.observed_environment.get("TEMP").?);
    try std.testing.expectEqualStrings("/mock/bin", fake.observed_environment.get("PATH").?);
    try std.testing.expect(!fake.observed_environment.contains("HIDDEN"));
    try std.testing.expectEqual(runtime.process.StandardIo.inherit, fake.observed_stdin);
    try std.testing.expectEqual(runtime.process.StandardIo.inherit, fake.observed_stdout);
    try std.testing.expectEqual(runtime.process.StandardIo.inherit, fake.observed_stderr);

    try std.testing.expectEqual(@as(usize, 6), fake.fd_operation_count);
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate = 1 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[0],
    );
    switch (fake.fd_operations[1]) {
        .open => |path| try std.testing.expectEqualStrings("out", path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 11, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[2],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 11 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[3],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .duplicate_to = .{ .source = 10, .target = 1 } }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[4],
    );
    try std.testing.expectEqual(
        FakeFdOperation{ .close = 10 }, // ziglint-ignore: Z010 (expectEqual peer)
        fake.fd_operations[5],
    );

    result.discardDelta(.child_process);
    try std.testing.expectEqualStrings("parent", shell_state.getVariable("FOO").?.value);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("TEMP"));
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

test "semantic evaluator executes external commands through POSIX runtime ports" {
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    var evaluator = Evaluator.initWithRuntimePorts(std.testing.allocator, runtime.posixPorts(&adapter));
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 5" };
    const externals = [_]command_plan.ExternalResolution{.{ .name = "/bin/sh", .path = "/bin/sh" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &argv },
        .lookup = .{ .externals = &externals },
    });

    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.child_process), plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 5), result.status);
    result.discardDelta(.child_process);
}

test "semantic evaluator normalizes external signal wait status" {
    var fake = FakeExternalRuntime.init(std.testing.allocator);
    defer fake.deinit();
    fake.wait_status = .{ .signaled = 15 };
    var evaluator = Evaluator.initWithExternalPorts(std.testing.allocator, fake.fdPort(), fake.processPort());

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const argv = [_][]const u8{"sigtool"};
    const externals = [_]command_plan.ExternalResolution{.{ .name = "sigtool", .path = "/mock/bin/sigtool" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &argv },
        .lookup = .{ .externals = &externals },
    });

    var result = try evaluatePlan(&evaluator, &shell_state, context.EvalContext.forTarget(.child_process), plan);
    defer result.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 143), result.status);
    result.discardDelta(.child_process);
}

test "semantic evaluator reports unsupported simple builtin execution explicitly" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const pwd_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"pwd"} } });
    try std.testing.expectError(error.Unimplemented, evaluatePlan(&evaluator, &shell_state, eval_context, pwd_plan));
}

test "semantic parser lowering plans compound pipeline stages" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);
    const resolver = parser_resolver.resolver();

    var body = (try resolver.resolve(
        std.testing.allocator,
        "{ printf 'left\n'; } | printf 'right\n'",
        .TERM,
        context.EvalContext.forTarget(.current_shell),
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const plan = switch (body) {
        .owned => |owned| switch (owned.body) {
            .pipeline => |plan| plan,
            else => return error.ExpectedPipelinePlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };

    try std.testing.expectEqual(@as(usize, 2), plan.stages.len);
    switch (plan.stages[0]) {
        .compound => |compound| try std.testing.expectEqualStrings("brace group", compound.kindName()),
        .simple => return error.ExpectedCompoundPipelineStage,
    }
    switch (plan.stages[1]) {
        .simple => {},
        .compound => return error.ExpectedSimplePipelineStage,
    }
}

test "semantic parser lowering flattens redundant nested subshells" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    var parser_resolver = ParserBackedSourceResolver.init(&evaluator);

    var body = (try parser_resolver.lowerSource(
        std.testing.allocator,
        "( ( ( : ) ) )",
        context.EvalContext.forTarget(.current_shell),
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const plan = switch (body) {
        .owned => |owned| switch (owned.body) {
            .compound => |compound| compound,
            else => return error.ExpectedCompoundPlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };

    const list = switch (plan.body) {
        .subshell => |subshell| subshell,
        else => return error.ExpectedSubshellPlan,
    };
    try std.testing.expectEqual(@as(usize, 1), list.statements.len);
    try std.testing.expect(list.statements[0].plan != .compound);
}
