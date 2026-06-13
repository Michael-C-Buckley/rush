//! Ordered descriptor mutation plans for the semantic shell core.
//!
//! Redirection planning preserves POSIX ordering and rollback obligations in
//! data. The actual descriptor syscalls belong to runtime ports and POSIX
//! adapters, not to this semantic module.

const std = @import("std");

const fd = @import("../runtime/fd.zig");

pub const Ownership = enum {
    borrowed,
    owned_by_plan,

    pub fn validate(self: Ownership, bytes: []const u8) void {
        _ = self;
        _ = bytes;
    }
};

pub const DataSlice = struct {
    bytes: []const u8,
    ownership: Ownership = .borrowed,

    pub fn borrowed(bytes: []const u8) DataSlice {
        const data: DataSlice = .{ .bytes = bytes, .ownership = .borrowed };
        data.validateAllowingEmpty();
        return data;
    }

    pub fn validate(self: DataSlice) void {
        self.ownership.validate(self.bytes);
    }

    pub fn validateAllowingEmpty(self: DataSlice) void {
        _ = self.ownership;
    }
};

pub const ExpandedFields = struct {
    fields: []const []const u8,
    ownership: Ownership = .borrowed,

    pub fn validate(self: ExpandedFields) void {
        for (self.fields) |field| self.ownership.validate(field);
    }
};

pub const ExpandedOperand = union(enum) {
    fields: ExpandedFields,
    here_doc: DataSlice,

    pub fn validate(self: ExpandedOperand) void {
        switch (self) {
            .fields => |fields| fields.validate(),
            .here_doc => |data| data.validateAllowingEmpty(),
        }
    }
};

pub const RedirectionOperator = enum {
    input,
    input_output,
    output,
    append,
    clobber,
    duplicate_input,
    duplicate_output,
    here_doc,

    pub fn defaultDescriptor(self: RedirectionOperator) fd.Descriptor {
        return switch (self) {
            .input,
            .input_output,
            .duplicate_input,
            .here_doc,
            => 0,
            .output,
            .append,
            .clobber,
            .duplicate_output,
            => 1,
        };
    }
};

pub const FailureConsequence = enum {
    command_failure,
    fatal_shell_error,
};

pub const FailurePolicy = enum {
    regular_command,
    special_builtin_interactive,
    special_builtin_non_interactive,

    pub fn consequence(self: FailurePolicy) FailureConsequence {
        return switch (self) {
            .regular_command,
            .special_builtin_interactive,
            => .command_failure,
            .special_builtin_non_interactive => .fatal_shell_error,
        };
    }
};

pub const PlanningFailureKind = enum {
    ambiguous_redirect,
    bad_fd_operand,
    wrong_operand_kind,
};

pub const PlanningFailure = struct {
    kind: PlanningFailureKind,
    operand: []const u8,
    consequence: FailureConsequence,

    pub fn diagnosticText(self: PlanningFailure) []const u8 {
        _ = self.operand;
        return switch (self.kind) {
            .ambiguous_redirect => "ambiguous redirect",
            .bad_fd_operand => "bad file descriptor",
            .wrong_operand_kind => "invalid redirection operand",
        };
    }
};

pub const RedirectionSpec = struct {
    descriptor: ?fd.Descriptor = null,
    operator: RedirectionOperator,
    operand: ExpandedOperand,

    pub fn validate(self: RedirectionSpec) void {
        if (self.descriptor) |descriptor| fd.assertValidDescriptor(descriptor);
        self.operand.validate();
    }
};

pub const PlanOptions = struct {
    noclobber: bool = false,
    failure_policy: FailurePolicy = .regular_command,
};

pub const OpenPathStep = struct {
    target: fd.Descriptor,
    path: DataSlice,
    options: fd.OpenOptions,
    noclobber: bool = false,

    pub fn validate(self: OpenPathStep) void {
        fd.assertValidDescriptor(self.target);
        self.path.validate();
        std.debug.assert(self.path.bytes.len != 0);
        self.options.validate();
        std.debug.assert(!self.noclobber or self.options.exclusive);
    }
};

pub const HereDocStep = struct {
    target: fd.Descriptor,
    data: DataSlice,

    pub fn validate(self: HereDocStep) void {
        fd.assertValidDescriptor(self.target);
        self.data.validateAllowingEmpty();
    }
};

pub const DuplicateStep = struct {
    target: fd.Descriptor,
    source: fd.Descriptor,

    pub fn validate(self: DuplicateStep) void {
        fd.assertValidDescriptor(self.target);
        fd.assertValidDescriptor(self.source);
    }
};

pub const CloseStep = struct {
    target: fd.Descriptor,

    pub fn validate(self: CloseStep) void {
        fd.assertValidDescriptor(self.target);
    }
};

pub const RedirectionEffect = union(enum) {
    open_path: OpenPathStep,
    here_doc: HereDocStep,
    duplicate: DuplicateStep,
    close: CloseStep,

    pub fn target(self: RedirectionEffect) fd.Descriptor {
        return switch (self) {
            .open_path => |step| step.target,
            .here_doc => |step| step.target,
            .duplicate => |step| step.target,
            .close => |step| step.target,
        };
    }

    pub fn validate(self: RedirectionEffect) void {
        switch (self) {
            .open_path => |step| step.validate(),
            .here_doc => |step| step.validate(),
            .duplicate => |step| step.validate(),
            .close => |step| step.validate(),
        }
    }
};

pub const RedirectionStep = struct {
    ordinal: usize,
    effect: RedirectionEffect,

    pub fn openPath(ordinal: usize, target_descriptor: fd.Descriptor, path: []const u8, options: fd.OpenOptions) RedirectionStep {
        const step: RedirectionStep = .{
            .ordinal = ordinal,
            .effect = .{ .open_path = .{ .target = target_descriptor, .path = DataSlice.borrowed(path), .options = options } },
        };
        step.validate();
        return step;
    }

    pub fn duplicate(ordinal: usize, target_descriptor: fd.Descriptor, source: fd.Descriptor) RedirectionStep {
        const step: RedirectionStep = .{ .ordinal = ordinal, .effect = .{ .duplicate = .{ .target = target_descriptor, .source = source } } };
        step.validate();
        return step;
    }

    pub fn close(ordinal: usize, target_descriptor: fd.Descriptor) RedirectionStep {
        const step: RedirectionStep = .{ .ordinal = ordinal, .effect = .{ .close = .{ .target = target_descriptor } } };
        step.validate();
        return step;
    }

    pub fn target(self: RedirectionStep) fd.Descriptor {
        return self.effect.target();
    }

    pub fn validate(self: RedirectionStep) void {
        self.effect.validate();
    }
};

pub const RestorationStep = struct {
    ordinal: usize,
    target: fd.Descriptor,

    pub fn validate(self: RestorationStep) void {
        fd.assertValidDescriptor(self.target);
    }
};

pub const RedirectionPlan = struct {
    steps: []const RedirectionStep = &.{},
    rollback_steps: []const RestorationStep = &.{},
    failure_consequence: FailureConsequence = .command_failure,
    allocator: ?std.mem.Allocator = null,

    pub fn clone(self: RedirectionPlan, allocator: std.mem.Allocator) std.mem.Allocator.Error!RedirectionPlan {
        self.validate();

        const owned_steps = try allocator.alloc(RedirectionStep, self.steps.len);
        errdefer allocator.free(owned_steps);
        var initialized: usize = 0;
        errdefer for (owned_steps[0..initialized]) |step| freeStepData(allocator, step);
        for (self.steps, 0..) |step, index| {
            owned_steps[index] = try cloneStep(allocator, step);
            initialized += 1;
        }

        const owned_rollback_steps = try allocator.dupe(RestorationStep, self.rollback_steps);
        errdefer allocator.free(owned_rollback_steps);

        const plan: RedirectionPlan = .{
            .steps = owned_steps,
            .rollback_steps = owned_rollback_steps,
            .failure_consequence = self.failure_consequence,
            .allocator = allocator,
        };
        plan.validate();
        return plan;
    }

    pub fn build(allocator: std.mem.Allocator, specs: []const RedirectionSpec, options: PlanOptions) std.mem.Allocator.Error!PlanResult {
        var steps: std.ArrayList(RedirectionStep) = .empty;
        errdefer steps.deinit(allocator);

        var rollback_steps: std.ArrayList(RestorationStep) = .empty;
        errdefer rollback_steps.deinit(allocator);

        const consequence = options.failure_policy.consequence();
        for (specs, 0..) |spec, ordinal| {
            spec.validate();
            const step_or_failure = stepFromSpec(spec, ordinal, options, consequence);
            switch (step_or_failure) {
                .step => |step| {
                    try steps.append(allocator, step);
                    try rollback_steps.append(allocator, .{ .ordinal = ordinal, .target = step.target() });
                },
                .failure => |failure| {
                    return .{ .failure = failure };
                },
            }
        }

        const owned_steps = try steps.toOwnedSlice(allocator);
        errdefer allocator.free(owned_steps);
        const owned_rollback_steps = try rollback_steps.toOwnedSlice(allocator);

        const plan: RedirectionPlan = .{
            .steps = owned_steps,
            .rollback_steps = owned_rollback_steps,
            .failure_consequence = consequence,
            .allocator = allocator,
        };
        plan.validate();
        return .{ .plan = plan };
    }

    pub fn deinit(self: *RedirectionPlan) void {
        const allocator = self.allocator orelse {
            self.* = undefined;
            return;
        };
        for (self.steps) |step| freeStepData(allocator, step);
        allocator.free(self.steps);
        allocator.free(self.rollback_steps);
        self.* = undefined;
    }

    pub fn validate(self: RedirectionPlan) void {
        std.debug.assert(self.rollback_steps.len == 0 or self.rollback_steps.len == self.steps.len);
        for (self.steps, 0..) |step, index| {
            step.validate();
            std.debug.assert(step.ordinal == index);
            if (self.rollback_steps.len != 0) {
                const rollback = self.rollback_steps[index];
                rollback.validate();
                std.debug.assert(rollback.ordinal == step.ordinal);
                std.debug.assert(rollback.target == step.target());
            }
        }
    }

    pub fn apply(self: RedirectionPlan, allocator: std.mem.Allocator, port: fd.Port) std.mem.Allocator.Error!ApplyResult {
        self.validate();

        var applied = AppliedRedirections.init(allocator, port);
        errdefer {
            applied.restore();
            applied.deinit();
        }

        for (self.steps, 0..) |step, index| {
            if (try applied.applyStep(step)) |detail| {
                applied.restore();
                applied.deinit();
                return .{ .failure = .{
                    .step_index = index,
                    .target = step.target(),
                    .detail = detail,
                    .consequence = self.failure_consequence,
                } };
            }
        }

        applied.validateActive();
        return .{ .applied = applied };
    }
};

fn cloneStep(allocator: std.mem.Allocator, step: RedirectionStep) std.mem.Allocator.Error!RedirectionStep {
    step.validate();
    return .{
        .ordinal = step.ordinal,
        .effect = try cloneEffect(allocator, step.effect),
    };
}

fn cloneEffect(allocator: std.mem.Allocator, effect: RedirectionEffect) std.mem.Allocator.Error!RedirectionEffect {
    effect.validate();
    return switch (effect) {
        .open_path => |step| blk: {
            const path = try cloneDataSlice(allocator, step.path);
            break :blk .{ .open_path = .{
                .target = step.target,
                .path = path,
                .options = step.options,
                .noclobber = step.noclobber,
            } };
        },
        .here_doc => |step| blk: {
            const data = try cloneDataSlice(allocator, step.data);
            break :blk .{ .here_doc = .{ .target = step.target, .data = data } };
        },
        .duplicate => |step| .{ .duplicate = step },
        .close => |step| .{ .close = step },
    };
}

fn cloneDataSlice(allocator: std.mem.Allocator, data: DataSlice) std.mem.Allocator.Error!DataSlice {
    data.validateAllowingEmpty();
    const bytes = try allocator.dupe(u8, data.bytes);
    return .{ .bytes = bytes, .ownership = .owned_by_plan };
}

fn freeStepData(allocator: std.mem.Allocator, step: RedirectionStep) void {
    switch (step.effect) {
        .open_path => |open_step| freeDataSlice(allocator, open_step.path),
        .here_doc => |here_doc_step| freeDataSlice(allocator, here_doc_step.data),
        .duplicate, .close => {},
    }
}

fn freeDataSlice(allocator: std.mem.Allocator, data: DataSlice) void {
    if (data.ownership == .owned_by_plan) allocator.free(data.bytes);
}

pub const PlanResult = union(enum) {
    plan: RedirectionPlan,
    failure: PlanningFailure,
};

pub const ApplyFailureDetail = union(enum) {
    open: fd.OpenError,
    close: fd.CloseError,
    duplicate: fd.DuplicateError,
    unsupported_here_doc,
};

pub const ApplyFailure = struct {
    step_index: usize,
    target: fd.Descriptor,
    detail: ApplyFailureDetail,
    consequence: FailureConsequence,
};

pub const ApplyResult = union(enum) {
    applied: AppliedRedirections,
    failure: ApplyFailure,
};

const SavedDescriptor = struct {
    target: fd.Descriptor,
    saved: ?fd.Descriptor,

    fn validate(self: SavedDescriptor) void {
        fd.assertValidDescriptor(self.target);
        if (self.saved) |saved| fd.assertValidDescriptor(saved);
    }
};

pub const AppliedRedirections = struct {
    allocator: std.mem.Allocator,
    port: fd.Port,
    saved: std.ArrayList(SavedDescriptor) = .empty,
    active: bool = true,

    fn init(allocator: std.mem.Allocator, port: fd.Port) AppliedRedirections {
        return .{ .allocator = allocator, .port = port };
    }

    pub fn deinit(self: *AppliedRedirections) void {
        std.debug.assert(!self.active);
        std.debug.assert(self.saved.items.len == 0);
        self.saved.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn restore(self: *AppliedRedirections) void {
        if (!self.active) return;

        var index = self.saved.items.len;
        while (index > 0) {
            index -= 1;
            const saved = self.saved.items[index];
            saved.validate();
            if (saved.saved) |saved_descriptor| {
                self.port.duplicateTo(.{ .source = saved_descriptor, .target = saved.target }) catch {};
                self.port.close(.{ .descriptor = saved_descriptor }) catch {};
            } else {
                self.port.close(.{ .descriptor = saved.target }) catch {};
            }
        }
        self.saved.clearRetainingCapacity();
        self.active = false;
    }

    pub fn commit(self: *AppliedRedirections) void {
        if (!self.active) return;
        for (self.saved.items) |saved| {
            saved.validate();
            if (saved.saved) |saved_descriptor| self.port.close(.{ .descriptor = saved_descriptor }) catch {};
        }
        self.saved.clearRetainingCapacity();
        self.active = false;
    }

    fn validateActive(self: AppliedRedirections) void {
        std.debug.assert(self.active);
        for (self.saved.items) |saved| saved.validate();
    }

    fn applyStep(self: *AppliedRedirections, step: RedirectionStep) std.mem.Allocator.Error!?ApplyFailureDetail {
        std.debug.assert(self.active);
        step.validate();
        return switch (step.effect) {
            .open_path => |open_step| try self.applyOpenPath(open_step),
            .here_doc => .unsupported_here_doc,
            .duplicate => |duplicate_step| try self.applyDuplicate(duplicate_step),
            .close => |close_step| try self.applyClose(close_step),
        };
    }

    fn applyOpenPath(self: *AppliedRedirections, step: OpenPathStep) std.mem.Allocator.Error!?ApplyFailureDetail {
        step.validate();
        if (try self.saveTarget(step.target)) |failure| return failure;

        const opened = self.port.open(.{ .path = step.path.bytes, .options = step.options }) catch |err| return .{ .open = err };
        errdefer self.port.close(.{ .descriptor = opened.descriptor }) catch {};
        if (opened.descriptor == step.target) return null;
        self.port.duplicateTo(.{ .source = opened.descriptor, .target = step.target }) catch |err| {
            closeOpened(self.port, opened.descriptor) catch {};
            return .{ .duplicate = err };
        };
        closeOpened(self.port, opened.descriptor) catch |err| return .{ .close = err };
        return null;
    }

    fn applyDuplicate(self: *AppliedRedirections, step: DuplicateStep) std.mem.Allocator.Error!?ApplyFailureDetail {
        step.validate();
        if (step.source != step.target) {
            if (try self.saveTarget(step.target)) |failure| return failure;
        }
        self.port.duplicateTo(.{ .source = step.source, .target = step.target }) catch |err| return .{ .duplicate = err };
        return null;
    }

    fn applyClose(self: *AppliedRedirections, step: CloseStep) std.mem.Allocator.Error!?ApplyFailureDetail {
        step.validate();
        if (try self.saveTarget(step.target)) |failure| return failure;
        closeTarget(self.port, step.target) catch |err| return .{ .close = err };
        return null;
    }

    fn saveTarget(self: *AppliedRedirections, target: fd.Descriptor) std.mem.Allocator.Error!?ApplyFailureDetail {
        fd.assertValidDescriptor(target);
        for (self.saved.items) |saved| if (saved.target == target) return null;
        const saved = self.port.duplicate(.{ .descriptor = target, .close_on_exec = true }) catch |err| switch (err) {
            error.BadFileDescriptor => null,
            else => |duplicate_err| return .{ .duplicate = duplicate_err },
        };
        const saved_descriptor = if (saved) |duplicate| duplicate.descriptor else null;
        try self.saved.append(self.allocator, .{ .target = target, .saved = saved_descriptor });
        return null;
    }
};

fn closeOpened(port: fd.Port, descriptor: fd.Descriptor) fd.CloseError!void {
    fd.assertValidDescriptor(descriptor);
    port.close(.{ .descriptor = descriptor }) catch |err| switch (err) {
        error.BadFileDescriptor => return,
        else => |close_err| return close_err,
    };
}

fn closeTarget(port: fd.Port, descriptor: fd.Descriptor) fd.CloseError!void {
    fd.assertValidDescriptor(descriptor);
    port.close(.{ .descriptor = descriptor }) catch |err| switch (err) {
        error.BadFileDescriptor => return,
        else => |close_err| return close_err,
    };
}

const StepOrFailure = union(enum) {
    step: RedirectionStep,
    failure: PlanningFailure,
};

fn stepFromSpec(spec: RedirectionSpec, ordinal: usize, options: PlanOptions, consequence: FailureConsequence) StepOrFailure {
    const target = spec.descriptor orelse spec.operator.defaultDescriptor();
    fd.assertValidDescriptor(target);

    return switch (spec.operator) {
        .input => pathOpenStep(spec.operand, ordinal, target, .{
            .access = .read_only,
            .close_on_exec = true,
        }, false, consequence),
        .input_output => pathOpenStep(spec.operand, ordinal, target, .{
            .access = .read_write,
            .create = true,
            .close_on_exec = true,
        }, false, consequence),
        .output => pathOpenStep(spec.operand, ordinal, target, .{
            .access = .write_only,
            .create = true,
            .exclusive = options.noclobber,
            .truncate = !options.noclobber,
            .close_on_exec = true,
        }, options.noclobber, consequence),
        .append => pathOpenStep(spec.operand, ordinal, target, .{
            .access = .write_only,
            .create = true,
            .append = true,
            .close_on_exec = true,
        }, false, consequence),
        .clobber => pathOpenStep(spec.operand, ordinal, target, .{
            .access = .write_only,
            .create = true,
            .truncate = true,
            .close_on_exec = true,
        }, false, consequence),
        .duplicate_input,
        .duplicate_output,
        => duplicateOrCloseStep(spec.operand, ordinal, target, consequence),
        .here_doc => hereDocStep(spec.operand, ordinal, target, consequence),
    };
}

fn pathOpenStep(operand: ExpandedOperand, ordinal: usize, target: fd.Descriptor, open_options: fd.OpenOptions, noclobber: bool, consequence: FailureConsequence) StepOrFailure {
    const fields = switch (operand) {
        .fields => |fields| fields,
        .here_doc => return .{ .failure = .{ .kind = .wrong_operand_kind, .operand = "here-doc", .consequence = consequence } },
    };
    if (singleField(fields)) |path| {
        const step: RedirectionStep = .{
            .ordinal = ordinal,
            .effect = .{ .open_path = .{
                .target = target,
                .path = .{ .bytes = path, .ownership = fields.ownership },
                .options = open_options,
                .noclobber = noclobber,
            } },
        };
        step.validate();
        return .{ .step = step };
    }
    return .{ .failure = .{ .kind = .ambiguous_redirect, .operand = ambiguousOperand(fields), .consequence = consequence } };
}

fn duplicateOrCloseStep(operand: ExpandedOperand, ordinal: usize, target: fd.Descriptor, consequence: FailureConsequence) StepOrFailure {
    const fields = switch (operand) {
        .fields => |fields| fields,
        .here_doc => return .{ .failure = .{ .kind = .wrong_operand_kind, .operand = "here-doc", .consequence = consequence } },
    };
    const value = singleField(fields) orelse return .{ .failure = .{ .kind = .ambiguous_redirect, .operand = ambiguousOperand(fields), .consequence = consequence } };
    if (std.mem.eql(u8, value, "-")) return .{ .step = RedirectionStep.close(ordinal, target) };
    const source = parseDescriptor(value) orelse return .{ .failure = .{ .kind = .bad_fd_operand, .operand = value, .consequence = consequence } };
    return .{ .step = RedirectionStep.duplicate(ordinal, target, source) };
}

fn hereDocStep(operand: ExpandedOperand, ordinal: usize, target: fd.Descriptor, consequence: FailureConsequence) StepOrFailure {
    const data = switch (operand) {
        .here_doc => |data| data,
        .fields => |fields| return .{ .failure = .{ .kind = .wrong_operand_kind, .operand = ambiguousOperand(fields), .consequence = consequence } },
    };
    const step: RedirectionStep = .{ .ordinal = ordinal, .effect = .{ .here_doc = .{ .target = target, .data = data } } };
    step.validate();
    return .{ .step = step };
}

fn singleField(fields: ExpandedFields) ?[]const u8 {
    fields.validate();
    if (fields.fields.len != 1) return null;
    if (fields.fields[0].len == 0) return null;
    return fields.fields[0];
}

fn ambiguousOperand(fields: ExpandedFields) []const u8 {
    return if (fields.fields.len == 0) "redirection" else fields.fields[0];
}

fn parseDescriptor(text: []const u8) ?fd.Descriptor {
    if (text.len == 0) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const value = std.fmt.parseInt(fd.Descriptor, text, 10) catch return null;
    if (!fd.isValidDescriptor(value)) return null;
    return value;
}

test "RedirectionPlan builds ordered semantic operations and failure policy" {
    const output_fields = [_][]const u8{"out"};
    const stdout_fields = [_][]const u8{"1"};
    const close_fields = [_][]const u8{"-"};
    const specs = [_]RedirectionSpec{
        .{ .operator = .output, .operand = .{ .fields = .{ .fields = &output_fields } } },
        .{ .descriptor = 2, .operator = .duplicate_output, .operand = .{ .fields = .{ .fields = &stdout_fields } } },
        .{ .descriptor = 0, .operator = .duplicate_input, .operand = .{ .fields = .{ .fields = &close_fields } } },
        .{ .operator = .here_doc, .operand = .{ .here_doc = .{ .bytes = "body\n" } } },
    };

    const result = try RedirectionPlan.build(std.testing.allocator, &specs, .{
        .noclobber = true,
        .failure_policy = .special_builtin_non_interactive,
    });
    var plan = switch (result) {
        .plan => |plan| plan,
        .failure => return error.TestUnexpectedResult,
    };
    defer plan.deinit();

    try std.testing.expectEqual(FailureConsequence.fatal_shell_error, plan.failure_consequence);
    try std.testing.expectEqual(@as(usize, 4), plan.steps.len);
    try std.testing.expectEqual(@as(usize, 4), plan.rollback_steps.len);

    switch (plan.steps[0].effect) {
        .open_path => |step| {
            try std.testing.expectEqual(@as(fd.Descriptor, 1), step.target);
            try std.testing.expectEqualStrings("out", step.path.bytes);
            try std.testing.expect(step.options.exclusive);
            try std.testing.expect(!step.options.truncate);
            try std.testing.expect(step.noclobber);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (plan.steps[1].effect) {
        .duplicate => |step| {
            try std.testing.expectEqual(@as(fd.Descriptor, 2), step.target);
            try std.testing.expectEqual(@as(fd.Descriptor, 1), step.source);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (plan.steps[2].effect) {
        .close => |step| try std.testing.expectEqual(@as(fd.Descriptor, 0), step.target),
        else => return error.TestUnexpectedResult,
    }
    switch (plan.steps[3].effect) {
        .here_doc => |step| try std.testing.expectEqualStrings("body\n", step.data.bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "RedirectionPlan clone owns path and here-doc data" {
    const steps = [_]RedirectionStep{
        RedirectionStep.openPath(0, 1, "out", .{ .access = .write_only, .create = true, .truncate = true }),
        .{ .ordinal = 1, .effect = .{ .here_doc = .{ .target = 0, .data = .{ .bytes = "body\n" } } } },
    };
    const rollback_steps = [_]RestorationStep{
        .{ .ordinal = 0, .target = 1 },
        .{ .ordinal = 1, .target = 0 },
    };
    const plan: RedirectionPlan = .{ .steps = &steps, .rollback_steps = &rollback_steps };

    var cloned = try plan.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(@as(usize, 2), cloned.steps.len);
    try std.testing.expect(cloned.steps.ptr != plan.steps.ptr);
    try std.testing.expect(cloned.rollback_steps.ptr != plan.rollback_steps.ptr);
    switch (cloned.steps[0].effect) {
        .open_path => |step| {
            try std.testing.expectEqualStrings("out", step.path.bytes);
            try std.testing.expectEqual(Ownership.owned_by_plan, step.path.ownership);
            try std.testing.expect(step.path.bytes.ptr != steps[0].effect.open_path.path.bytes.ptr);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (cloned.steps[1].effect) {
        .here_doc => |step| {
            try std.testing.expectEqualStrings("body\n", step.data.bytes);
            try std.testing.expectEqual(Ownership.owned_by_plan, step.data.ownership);
            try std.testing.expect(step.data.bytes.ptr != steps[1].effect.here_doc.data.bytes.ptr);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "RedirectionPlan reports ambiguous redirects and bad fd operands as planning failures" {
    const empty_fields = [_][]const u8{};
    const ambiguous_specs = [_]RedirectionSpec{.{ .operator = .input, .operand = .{ .fields = .{ .fields = &empty_fields } } }};
    const ambiguous = try RedirectionPlan.build(std.testing.allocator, &ambiguous_specs, .{ .failure_policy = .special_builtin_non_interactive });
    switch (ambiguous) {
        .failure => |failure| {
            try std.testing.expectEqual(PlanningFailureKind.ambiguous_redirect, failure.kind);
            try std.testing.expectEqual(FailureConsequence.fatal_shell_error, failure.consequence);
            try std.testing.expectEqualStrings("ambiguous redirect", failure.diagnosticText());
        },
        .plan => |plan_value| {
            var plan = plan_value;
            plan.deinit();
            return error.TestUnexpectedResult;
        },
    }

    const bad_fd_fields = [_][]const u8{"not-a-fd"};
    const bad_fd_specs = [_]RedirectionSpec{.{ .operator = .duplicate_output, .operand = .{ .fields = .{ .fields = &bad_fd_fields } } }};
    const bad_fd = try RedirectionPlan.build(std.testing.allocator, &bad_fd_specs, .{});
    switch (bad_fd) {
        .failure => |failure| {
            try std.testing.expectEqual(PlanningFailureKind.bad_fd_operand, failure.kind);
            try std.testing.expectEqual(FailureConsequence.command_failure, failure.consequence);
            try std.testing.expectEqualStrings("not-a-fd", failure.operand);
        },
        .plan => |plan_value| {
            var plan = plan_value;
            plan.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

const FakeFdRuntime = struct {
    open_descriptors: [64]bool = initOpenDescriptors(),
    next_descriptor: fd.Descriptor = 10,
    fail_duplicate_to_target: ?fd.Descriptor = null,

    fn port(self: *FakeFdRuntime) fd.Port {
        return .{
            .context = self,
            .open_fn = open,
            .close_fn = close,
            .duplicate_fn = duplicate,
            .duplicate_to_fn = duplicateTo,
            .pipe_fn = pipe,
            .is_tty_fn = isTty,
        };
    }

    fn isOpen(self: FakeFdRuntime, descriptor: fd.Descriptor) bool {
        if (descriptor < 0 or descriptor >= self.open_descriptors.len) return false;
        return self.open_descriptors[@intCast(descriptor)];
    }

    fn setOpen(self: *FakeFdRuntime, descriptor: fd.Descriptor, open_value: bool) void {
        std.debug.assert(descriptor >= 0 and descriptor < self.open_descriptors.len);
        self.open_descriptors[@intCast(descriptor)] = open_value;
    }

    fn next(self: *FakeFdRuntime) fd.Descriptor {
        const descriptor = self.next_descriptor;
        self.next_descriptor += 1;
        self.setOpen(descriptor, true);
        return descriptor;
    }

    fn fromContext(context: *anyopaque) *FakeFdRuntime {
        return @ptrCast(@alignCast(context));
    }

    fn open(context: *anyopaque, request: fd.OpenRequest) fd.OpenError!fd.OpenResult {
        const self = fromContext(context);
        request.validate();
        if (std.mem.eql(u8, request.path, "missing")) return error.FileNotFound;
        return .{ .descriptor = self.next() };
    }

    fn close(context: *anyopaque, request: fd.CloseRequest) fd.CloseError!void {
        const self = fromContext(context);
        request.validate();
        if (!self.isOpen(request.descriptor)) return error.BadFileDescriptor;
        self.setOpen(request.descriptor, false);
    }

    fn duplicate(context: *anyopaque, request: fd.DuplicateRequest) fd.DuplicateError!fd.DuplicateResult {
        const self = fromContext(context);
        request.validate();
        if (!self.isOpen(request.descriptor)) return error.BadFileDescriptor;
        return .{ .descriptor = self.next() };
    }

    fn duplicateTo(context: *anyopaque, request: fd.DuplicateToRequest) fd.DuplicateError!void {
        const self = fromContext(context);
        request.validate();
        if (self.fail_duplicate_to_target == request.target) return error.Unexpected;
        if (!self.isOpen(request.source)) return error.BadFileDescriptor;
        self.setOpen(request.target, true);
    }

    fn pipe(context: *anyopaque, request: fd.PipeRequest) fd.PipeError!fd.PipeResult {
        const self = fromContext(context);
        request.validate();
        const read = self.next();
        const write = self.next();
        return .{ .read = read, .write = write };
    }

    fn isTty(context: *anyopaque, request: fd.IsTtyRequest) fd.IsTtyError!fd.IsTtyResult {
        const self = fromContext(context);
        request.validate();
        _ = self;
        return .{ .is_tty = false };
    }
};

fn initOpenDescriptors() [64]bool {
    var open_descriptors = [_]bool{false} ** 64;
    open_descriptors[0] = true;
    open_descriptors[1] = true;
    open_descriptors[2] = true;
    return open_descriptors;
}

test "RedirectionPlan application uses fd ports and restores saved descriptors" {
    const fields = [_][]const u8{"out"};
    const specs = [_]RedirectionSpec{
        .{ .operator = .output, .operand = .{ .fields = .{ .fields = &fields } } },
        .{ .descriptor = 2, .operator = .duplicate_output, .operand = .{ .fields = .{ .fields = &[_][]const u8{"1"} } } },
        .{ .descriptor = 0, .operator = .duplicate_input, .operand = .{ .fields = .{ .fields = &[_][]const u8{"-"} } } },
    };
    const result = try RedirectionPlan.build(std.testing.allocator, &specs, .{});
    var plan = switch (result) {
        .plan => |plan| plan,
        .failure => return error.TestUnexpectedResult,
    };
    defer plan.deinit();

    var fake: FakeFdRuntime = .{};
    const applied_result = try plan.apply(std.testing.allocator, fake.port());
    var applied = switch (applied_result) {
        .applied => |applied| applied,
        .failure => return error.TestUnexpectedResult,
    };
    defer applied.deinit();

    try std.testing.expect(!fake.isOpen(0));
    try std.testing.expect(fake.isOpen(1));
    try std.testing.expect(fake.isOpen(2));

    applied.restore();
    try std.testing.expect(fake.isOpen(0));
    try std.testing.expect(fake.isOpen(1));
    try std.testing.expect(fake.isOpen(2));
}

test "RedirectionPlan application restores earlier steps after runtime failure" {
    const steps = [_]RedirectionStep{
        RedirectionStep.close(0, 0),
        RedirectionStep.duplicate(1, 1, 9),
    };
    const rollback_steps = [_]RestorationStep{
        .{ .ordinal = 0, .target = 0 },
        .{ .ordinal = 1, .target = 1 },
    };
    const plan: RedirectionPlan = .{ .steps = &steps, .rollback_steps = &rollback_steps };

    var fake: FakeFdRuntime = .{};
    const result = try plan.apply(std.testing.allocator, fake.port());
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(@as(usize, 1), failure.step_index);
            try std.testing.expectEqual(@as(fd.Descriptor, 1), failure.target);
            try std.testing.expectEqual(FailureConsequence.command_failure, failure.consequence);
        },
        .applied => |applied_value| {
            var applied = applied_value;
            applied.restore();
            applied.deinit();
            return error.TestUnexpectedResult;
        },
    }

    try std.testing.expect(fake.isOpen(0));
    try std.testing.expect(fake.isOpen(1));
    try std.testing.expect(fake.isOpen(2));
}

test "RedirectionPlan application closes opened file after duplicate failure" {
    const fields = [_][]const u8{"out"};
    const specs = [_]RedirectionSpec{.{ .operator = .output, .operand = .{ .fields = .{ .fields = &fields } } }};
    const result = try RedirectionPlan.build(std.testing.allocator, &specs, .{});
    var plan = switch (result) {
        .plan => |plan| plan,
        .failure => return error.TestUnexpectedResult,
    };
    defer plan.deinit();

    var fake: FakeFdRuntime = .{ .fail_duplicate_to_target = 1 };
    const opened_descriptor = fake.next_descriptor;
    const apply_result = try plan.apply(std.testing.allocator, fake.port());
    switch (apply_result) {
        .failure => |failure| {
            try std.testing.expectEqual(@as(usize, 0), failure.step_index);
            try std.testing.expectEqual(@as(fd.Descriptor, 1), failure.target);
            try std.testing.expectEqual(ApplyFailureDetail{ .duplicate = error.Unexpected }, failure.detail);
        },
        .applied => |applied_value| {
            var applied = applied_value;
            applied.restore();
            applied.deinit();
            return error.TestUnexpectedResult;
        },
    }

    try std.testing.expect(!fake.isOpen(opened_descriptor));
    try std.testing.expect(fake.isOpen(0));
    try std.testing.expect(fake.isOpen(1));
    try std.testing.expect(fake.isOpen(2));
}
