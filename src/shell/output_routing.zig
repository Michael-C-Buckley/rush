//! Semantic output routing derived from execution frames.

const std = @import("std");

const execution_frame = @import("execution_frame.zig");
const redirection_plan = @import("redirection_plan.zig");
const fd = @import("../runtime/fd.zig");

pub const OutputDestination = union(enum) {
    outcome_stdout_capture,
    outcome_stderr_capture,
    side_stdout_capture,
    command_substitution_side_stdout_capture,
    pipeline_data_capture,
    command_substitution_stdout_capture,
    command_substitution_stderr_capture,
    host_descriptor: fd.Descriptor,
    closed,

    pub fn validate(self: OutputDestination) void {
        switch (self) {
            .outcome_stdout_capture,
            .outcome_stderr_capture,
            .side_stdout_capture,
            .command_substitution_side_stdout_capture,
            .pipeline_data_capture,
            .command_substitution_stdout_capture,
            .command_substitution_stderr_capture,
            .closed,
            => {},
            .host_descriptor => |descriptor| fd.assertValidDescriptor(descriptor),
        }
    }
};

const OutputBinding = struct {
    descriptor: fd.Descriptor,
    destination: OutputDestination,

    fn validate(self: OutputBinding) void {
        fd.assertValidDescriptor(self.descriptor);
        self.destination.validate();
    }
};

pub const OutputRouting = struct {
    pub const InitialMode = enum {
        outcome_capture,
        inherited,
        command_substitution,
    };

    allocator: std.mem.Allocator,
    initial_mode: InitialMode,
    bindings: std.ArrayList(OutputBinding) = .empty,

    pub fn init(allocator: std.mem.Allocator, initial_mode: InitialMode) OutputRouting {
        return .{ .allocator = allocator, .initial_mode = initial_mode };
    }

    pub fn initCommandSubstitution(allocator: std.mem.Allocator) OutputRouting {
        return init(allocator, .command_substitution);
    }

    pub fn initForFrame(
        allocator: std.mem.Allocator,
        frame: execution_frame.ExecutionFrame,
        preserve_parent_visible_stdout_capture: bool,
    ) !OutputRouting {
        frame.validate();
        var routing = OutputRouting.init(allocator, .outcome_capture);
        errdefer routing.deinit();
        const command_substitution_context = frameWithinCommandSubstitution(frame);
        try routing.setDestination(1, outputDestinationForFrameEndpointInContext(
            1,
            frame.spec.fd_table.endpoint(1),
            command_substitution_context,
            preserve_parent_visible_stdout_capture,
        ));
        try routing.setDestination(2, outputDestinationForFrameEndpointInContext(
            2,
            frame.spec.fd_table.endpoint(2),
            command_substitution_context,
            preserve_parent_visible_stdout_capture,
        ));
        for (frame.spec.fd_table.bindings.items) |binding| {
            if (binding.descriptor <= 2) continue;
            switch (binding.endpoint) {
                .output => try routing.setDestination(
                    binding.descriptor,
                    outputDestinationForFrameEndpointInContext(
                        binding.descriptor,
                        binding.endpoint,
                        command_substitution_context,
                        preserve_parent_visible_stdout_capture,
                    ),
                ),
                .closed => try routing.setDestination(binding.descriptor, .closed),
                .input => {},
            }
        }
        return routing;
    }

    pub fn deinit(self: *OutputRouting) void {
        self.bindings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn destination(self: OutputRouting, descriptor: fd.Descriptor) OutputDestination {
        fd.assertValidDescriptor(descriptor);
        if (self.boundDestination(descriptor)) |bound| return bound;
        return self.defaultDestination(descriptor);
    }

    fn boundDestination(self: OutputRouting, descriptor: fd.Descriptor) ?OutputDestination {
        fd.assertValidDescriptor(descriptor);
        for (self.bindings.items) |binding| {
            binding.validate();
            if (binding.descriptor == descriptor) return binding.destination;
        }
        return null;
    }

    fn defaultDestination(self: OutputRouting, descriptor: fd.Descriptor) OutputDestination {
        fd.assertValidDescriptor(descriptor);
        return switch (self.initial_mode) {
            .outcome_capture => switch (descriptor) {
                1 => .outcome_stdout_capture,
                2 => .outcome_stderr_capture,
                else => .{ .host_descriptor = descriptor },
            },
            .inherited => .{ .host_descriptor = descriptor },
            .command_substitution => switch (descriptor) {
                1 => .command_substitution_stdout_capture,
                2 => .command_substitution_stderr_capture,
                else => .{ .host_descriptor = descriptor },
            },
        };
    }

    pub fn setDestination(
        self: *OutputRouting,
        descriptor: fd.Descriptor,
        dest: OutputDestination,
    ) !void {
        fd.assertValidDescriptor(descriptor);
        dest.validate();
        for (self.bindings.items) |*binding| {
            binding.validate();
            if (binding.descriptor == descriptor) {
                binding.destination = dest;
                return;
            }
        }
        try self.bindings.append(self.allocator, .{ .descriptor = descriptor, .destination = dest });
    }

    pub fn applyRedirectionStep(self: *OutputRouting, step: redirection_plan.RedirectionStep) !void {
        step.validate();
        switch (step.effect) {
            .duplicate => |duplicate| {
                const source_bound = self.boundDestination(duplicate.source) != null;
                const source_destination = self.destination(duplicate.source);
                const copied_destination = if (!source_bound and self.initial_mode == .inherited)
                    switch (source_destination) {
                        .host_descriptor => @as(OutputDestination, .{ .host_descriptor = duplicate.target }),
                        else => source_destination,
                    }
                else
                    source_destination;
                try self.setDestination(duplicate.target, copied_destination);
            },
            .close => |close| try self.setDestination(close.target, .closed),
            .open_path, .here_doc => try self.setDestination(step.target(), .{ .host_descriptor = step.target() }),
        }
    }

    pub fn applyRedirections(self: *OutputRouting, redirections: redirection_plan.RedirectionPlan) !void {
        redirections.validate();
        for (redirections.steps) |step| try self.applyRedirectionStep(step);
    }
};

pub fn outputDestinationForFrameEndpointInContext(
    descriptor: fd.Descriptor,
    endpoint: execution_frame.FdEndpoint,
    command_substitution_context: bool,
    preserve_parent_visible_stdout: bool,
) OutputDestination {
    fd.assertValidDescriptor(descriptor);
    endpoint.validate();
    return switch (endpoint) {
        .output => |output| switch (output) {
            .inherit_stdout => if (command_substitution_context)
                .{ .host_descriptor = descriptor }
            else
                .{ .host_descriptor = descriptor },
            .inherit_stderr => if (command_substitution_context)
                .outcome_stderr_capture
            else
                .{ .host_descriptor = descriptor },
            .fd => |host_descriptor| if (command_substitution_context) switch (host_descriptor) {
                1 => .{ .host_descriptor = 1 },
                2 => .outcome_stderr_capture,
                else => .{ .host_descriptor = host_descriptor },
            } else .{ .host_descriptor = host_descriptor },
            .pipe_write => |host_descriptor| .{ .host_descriptor = host_descriptor },
            .path => .{ .host_descriptor = descriptor },
            .capture => |channel| blk: {
                if (preserve_parent_visible_stdout and channel == .side_stdout) break :blk .side_stdout_capture;
                break :blk if (command_substitution_context) switch (channel) {
                    .command_substitution_stdout => if (descriptor == 1)
                        .command_substitution_stdout_capture
                    else
                        .command_substitution_side_stdout_capture,
                    .side_stdout => .side_stdout_capture,
                    .side_stderr => .outcome_stderr_capture,
                    .pipeline_data => .pipeline_data_capture,
                } else outputDestinationForCaptureChannel(channel);
            },
            .discard => .closed,
        },
        .closed => .closed,
        .input => .closed,
    };
}

pub fn frameWithinCommandSubstitution(frame: execution_frame.ExecutionFrame) bool {
    frame.validate();
    if (frame.spec.kind == .command_substitution) return true;
    if (frame.spec.captures.contains(.command_substitution_stdout)) return true;
    return switch (frame.parent) {
        .kind => |kind| kind == .command_substitution,
        .none => false,
    };
}

fn outputDestinationForCaptureChannel(channel: execution_frame.CaptureChannel) OutputDestination {
    return switch (channel) {
        .side_stdout => .outcome_stdout_capture,
        .side_stderr => .outcome_stderr_capture,
        .pipeline_data => .pipeline_data_capture,
        .command_substitution_stdout => .command_substitution_stdout_capture,
    };
}

test "output routing defaults inherited descriptors to host descriptors" {
    var routing = OutputRouting.init(std.testing.allocator, .inherited);
    defer routing.deinit();

    const stdout_destination: OutputDestination = .{ .host_descriptor = 1 };
    const stderr_destination: OutputDestination = .{ .host_descriptor = 2 };
    try std.testing.expectEqual(stdout_destination, routing.destination(1));
    try std.testing.expectEqual(stderr_destination, routing.destination(2));
}

test "output routing defaults command substitution descriptors to captures" {
    var routing = OutputRouting.initCommandSubstitution(std.testing.allocator);
    defer routing.deinit();

    try std.testing.expectEqual(OutputDestination.command_substitution_stdout_capture, routing.destination(1));
    try std.testing.expectEqual(OutputDestination.command_substitution_stderr_capture, routing.destination(2));
}

test "output routing applies redirections in order" {
    const stderr_to_stdout_then_stdout_file_steps = [_]redirection_plan.RedirectionStep{
        redirection_plan.RedirectionStep.duplicate(0, 2, 1),
        redirection_plan.RedirectionStep.openPath(1, 1, "out", .{ .access = .write_only, .create = true }),
    };
    const stderr_to_stdout_then_stdout_file_plan: redirection_plan.RedirectionPlan = .{
        .steps = &stderr_to_stdout_then_stdout_file_steps,
    };
    var stderr_to_stdout_then_stdout_file = OutputRouting.initCommandSubstitution(std.testing.allocator);
    defer stderr_to_stdout_then_stdout_file.deinit();
    try stderr_to_stdout_then_stdout_file.applyRedirections(stderr_to_stdout_then_stdout_file_plan);

    const stdout_file_then_stderr_to_stdout_steps = [_]redirection_plan.RedirectionStep{
        redirection_plan.RedirectionStep.openPath(0, 1, "out", .{ .access = .write_only, .create = true }),
        redirection_plan.RedirectionStep.duplicate(1, 2, 1),
    };
    const stdout_file_then_stderr_to_stdout_plan: redirection_plan.RedirectionPlan = .{
        .steps = &stdout_file_then_stderr_to_stdout_steps,
    };
    var stdout_file_then_stderr_to_stdout = OutputRouting.initCommandSubstitution(std.testing.allocator);
    defer stdout_file_then_stderr_to_stdout.deinit();
    try stdout_file_then_stderr_to_stdout.applyRedirections(stdout_file_then_stderr_to_stdout_plan);

    const file_destination: OutputDestination = .{ .host_descriptor = 1 };
    try std.testing.expectEqual(file_destination, stderr_to_stdout_then_stdout_file.destination(1));
    try std.testing.expectEqual(
        OutputDestination.command_substitution_stdout_capture,
        stderr_to_stdout_then_stdout_file.destination(2),
    );
    try std.testing.expectEqual(file_destination, stdout_file_then_stderr_to_stdout.destination(1));
    try std.testing.expectEqual(file_destination, stdout_file_then_stderr_to_stdout.destination(2));
}

test "output routing duplicate copies current source destination" {
    const steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.duplicate(0, 1, 2)};
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };
    var routing = OutputRouting.initCommandSubstitution(std.testing.allocator);
    defer routing.deinit();

    try routing.applyRedirections(plan);

    try std.testing.expectEqual(OutputDestination.command_substitution_stderr_capture, routing.destination(1));
}

test "output routing inherited duplicate survives source close" {
    const steps = [_]redirection_plan.RedirectionStep{
        redirection_plan.RedirectionStep.duplicate(0, 1, 2),
        redirection_plan.RedirectionStep.close(1, 2),
    };
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };
    var routing = OutputRouting.init(std.testing.allocator, .inherited);
    defer routing.deinit();

    try routing.applyRedirections(plan);

    try std.testing.expectEqual(@as(OutputDestination, .{ .host_descriptor = 1 }), routing.destination(1));
    try std.testing.expectEqual(OutputDestination.closed, routing.destination(2));
}

test "output routing close marks destination closed" {
    const steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.close(0, 1)};
    const plan: redirection_plan.RedirectionPlan = .{ .steps = &steps };
    var routing = OutputRouting.init(std.testing.allocator, .inherited);
    defer routing.deinit();

    try routing.applyRedirections(plan);

    try std.testing.expectEqual(OutputDestination.closed, routing.destination(1));
}
