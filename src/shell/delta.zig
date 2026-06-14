//! Explicit semantic mutation set for shell execution.
//!
//! Planning must not mutate `ShellState` directly. Later tasks will add concrete
//! mutations here; this skeleton already models the commit/discard boundary so
//! child and subshell deltas cannot silently leak into the current shell.

const std = @import("std");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const state = @import("state.zig");

pub const DeltaState = enum {
    pending,
    consumed,
};

pub const VariableAssignment = struct {
    name: []const u8,
    value: []const u8,
    exported: ?bool = null,
    readonly: bool = false,
};

pub const VariableFlag = enum {
    exported,
    readonly,
};

pub const VariableFlagMutation = struct {
    name: []const u8,
    flag: VariableFlag,
    enabled: bool = true,
};

pub const NameValueMutation = struct {
    name: []const u8,
    value: []const u8,
};

pub const TrapMutation = struct {
    name: []const u8,
    action: ?[]const u8,
};

pub const OptionChange = struct {
    option: state.ShellOption,
    enabled: bool,
};

pub const JobMarkerMutation = struct {
    current_job_id: ?usize = null,
    previous_job_id: ?usize = null,

    pub fn validate(self: JobMarkerMutation) void {
        if (self.current_job_id) |id| std.debug.assert(id != 0);
        if (self.previous_job_id) |id| std.debug.assert(id != 0);
        std.debug.assert(self.current_job_id == null or
            self.previous_job_id == null or
            self.current_job_id.? != self.previous_job_id.?);
    }
};

pub const StateDelta = struct {
    allocator: std.mem.Allocator,
    target: context.ExecutionTarget,
    state: DeltaState = .pending,
    variable_assignments: std.ArrayList(VariableAssignment) = .empty,
    variable_flags: std.ArrayList(VariableFlagMutation) = .empty,
    variable_unsets: std.ArrayList([]const u8) = .empty,
    function_sets: std.ArrayList(command_plan.FunctionDefinition) = .empty,
    function_unsets: std.ArrayList([]const u8) = .empty,
    option_changes: std.ArrayList(OptionChange) = .empty,
    alias_sets: std.ArrayList(NameValueMutation) = .empty,
    alias_unsets: std.ArrayList([]const u8) = .empty,
    clear_aliases: bool = false,
    abbreviation_sets: std.ArrayList(NameValueMutation) = .empty,
    abbreviation_unsets: std.ArrayList([]const u8) = .empty,
    trap_mutations: std.ArrayList(TrapMutation) = .empty,
    pending_trap_enqueues: std.ArrayList(state.TrapSignal) = .empty,
    pending_trap_consume_count: usize = 0,
    pending_exit: ?state.ExitStatus = null,
    clear_pending_exit: bool = false,
    positionals: ?[][]const u8 = null,
    logical_cwd: ?[]const u8 = null,
    last_status: ?state.ExitStatus = null,
    last_pipeline_statuses: ?[]state.ExitStatus = null,
    background_jobs: std.ArrayList(state.BackgroundJob) = .empty,
    background_job_updates: std.ArrayList(state.BackgroundJob) = .empty,
    background_job_removals: std.ArrayList(usize) = .empty,
    job_notifications: std.ArrayList(state.BackgroundJobNotification) = .empty,
    job_notification_consume_count: usize = 0,
    job_markers: ?JobMarkerMutation = null,

    pub fn init(allocator: std.mem.Allocator, target: context.ExecutionTarget) StateDelta {
        return .{ .allocator = allocator, .target = target };
    }

    pub fn deinit(self: *StateDelta) void {
        for (self.variable_assignments.items) |assignment| {
            self.allocator.free(assignment.name);
            self.allocator.free(assignment.value);
        }
        self.variable_assignments.deinit(self.allocator);

        for (self.variable_flags.items) |mutation| {
            self.allocator.free(mutation.name);
        }
        self.variable_flags.deinit(self.allocator);

        for (self.variable_unsets.items) |name| self.allocator.free(name);
        self.variable_unsets.deinit(self.allocator);
        for (self.function_sets.items) |definition| freeFunctionDefinition(self.allocator, definition);
        self.function_sets.deinit(self.allocator);
        for (self.function_unsets.items) |name| self.allocator.free(name);
        self.function_unsets.deinit(self.allocator);
        self.option_changes.deinit(self.allocator);

        for (self.alias_sets.items) |mutation| {
            self.allocator.free(mutation.name);
            self.allocator.free(mutation.value);
        }
        self.alias_sets.deinit(self.allocator);
        for (self.alias_unsets.items) |name| self.allocator.free(name);
        self.alias_unsets.deinit(self.allocator);
        for (self.abbreviation_sets.items) |mutation| {
            self.allocator.free(mutation.name);
            self.allocator.free(mutation.value);
        }
        self.abbreviation_sets.deinit(self.allocator);
        for (self.abbreviation_unsets.items) |name| self.allocator.free(name);
        self.abbreviation_unsets.deinit(self.allocator);
        for (self.trap_mutations.items) |mutation| {
            self.allocator.free(mutation.name);
            if (mutation.action) |action| self.allocator.free(action);
        }
        self.trap_mutations.deinit(self.allocator);
        self.pending_trap_enqueues.deinit(self.allocator);

        if (self.positionals) |args| {
            for (args) |arg| self.allocator.free(arg);
            self.allocator.free(args);
        }
        if (self.logical_cwd) |cwd| self.allocator.free(cwd);
        if (self.last_pipeline_statuses) |statuses| self.allocator.free(statuses);
        for (self.background_jobs.items) |*job| job.deinit(self.allocator);
        self.background_jobs.deinit(self.allocator);
        for (self.background_job_updates.items) |*job| job.deinit(self.allocator);
        self.background_job_updates.deinit(self.allocator);
        self.background_job_removals.deinit(self.allocator);
        for (self.job_notifications.items) |*notification| notification.deinit(self.allocator);
        self.job_notifications.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn clone(self: *const StateDelta, allocator: std.mem.Allocator) !StateDelta {
        std.debug.assert(self.state == .pending);

        var cloned = StateDelta.init(allocator, self.target);
        errdefer cloned.deinit();

        for (self.variable_assignments.items) |assignment| {
            try cloned.assignVariable(assignment.name, assignment.value, .{
                .exported = assignment.exported,
                .readonly = assignment.readonly,
            });
        }
        for (self.variable_flags.items) |mutation| {
            try cloned.appendVariableFlag(mutation.name, mutation.flag, mutation.enabled);
        }
        for (self.variable_unsets.items) |name| try cloned.unsetVariable(name);
        for (self.function_sets.items) |definition| try cloned.setFunction(definition);
        for (self.function_unsets.items) |name| try cloned.unsetFunction(name);
        for (self.option_changes.items) |change| {
            try cloned.setOption(change.option, change.enabled);
        }
        for (self.alias_sets.items) |mutation| try cloned.setAlias(mutation.name, mutation.value);
        for (self.alias_unsets.items) |name| try cloned.unsetAlias(name);
        if (self.clear_aliases) cloned.clearAliases();
        for (self.abbreviation_sets.items) |mutation| try cloned.setAbbreviation(mutation.name, mutation.value);
        for (self.abbreviation_unsets.items) |name| try cloned.unsetAbbreviation(name);
        for (self.trap_mutations.items) |mutation| try cloned.setTrap(mutation.name, mutation.action);
        for (self.pending_trap_enqueues.items) |signal| try cloned.enqueuePendingTrap(signal);
        if (self.pending_trap_consume_count != 0) cloned.consumePendingTraps(self.pending_trap_consume_count);
        if (self.pending_exit) |status| cloned.setPendingExit(status);
        if (self.clear_pending_exit) cloned.clearPendingExit();
        if (self.positionals) |args| try cloned.replacePositionals(args);
        if (self.logical_cwd) |cwd| try cloned.setLogicalCwd(cwd);
        if (self.last_status) |status| cloned.setLastStatus(status);
        if (self.last_pipeline_statuses) |statuses| try cloned.setLastPipelineStatuses(statuses);
        for (self.background_jobs.items) |job| try cloned.appendBackgroundJob(job);
        for (self.background_job_updates.items) |job| try cloned.updateBackgroundJob(job);
        for (self.background_job_removals.items) |id| try cloned.removeBackgroundJob(id);
        for (self.job_notifications.items) |notification| try cloned.appendJobNotification(notification);
        if (self.job_notification_consume_count != 0) {
            cloned.consumeJobNotifications(self.job_notification_consume_count);
        }
        if (self.job_markers) |markers| cloned.setJobMarkers(markers);

        return cloned;
    }

    pub fn isEmpty(self: StateDelta) bool {
        return self.variable_assignments.items.len == 0 and
            self.variable_flags.items.len == 0 and
            self.variable_unsets.items.len == 0 and
            self.function_sets.items.len == 0 and
            self.function_unsets.items.len == 0 and
            self.option_changes.items.len == 0 and
            self.alias_sets.items.len == 0 and
            self.alias_unsets.items.len == 0 and
            !self.clear_aliases and
            self.abbreviation_sets.items.len == 0 and
            self.abbreviation_unsets.items.len == 0 and
            self.trap_mutations.items.len == 0 and
            self.pending_trap_enqueues.items.len == 0 and
            self.pending_trap_consume_count == 0 and
            self.pending_exit == null and
            !self.clear_pending_exit and
            self.positionals == null and
            self.logical_cwd == null and
            self.last_status == null and
            self.last_pipeline_statuses == null and
            self.background_jobs.items.len == 0 and
            self.background_job_updates.items.len == 0 and
            self.background_job_removals.items.len == 0 and
            self.job_notifications.items.len == 0 and
            self.job_notification_consume_count == 0 and
            self.job_markers == null;
    }

    pub fn assignVariable(
        self: *StateDelta,
        name: []const u8,
        value: []const u8,
        attributes: state.VariableAttributes,
    ) !void {
        self.assertPending();
        state.assertValidVariableName(name);

        if (findVariableAssignment(self, name)) |assignment| {
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(assignment.value);
            assignment.value = owned_value;
            if (attributes.exported) |exported| {
                if (assignment.exported) |existing| std.debug.assert(existing == exported);
                assignment.exported = exported;
            }
            assignment.readonly = assignment.readonly or attributes.readonly;
            return;
        }

        for (self.variable_flags.items) |mutation| {
            if (!std.mem.eql(u8, mutation.name, name)) continue;
            if (mutation.flag == .exported) {
                if (attributes.exported) |exported| {
                    std.debug.assert(mutation.enabled == exported);
                }
            }
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        try self.variable_assignments.append(self.allocator, .{
            .name = owned_name,
            .value = owned_value,
            .exported = attributes.exported,
            .readonly = attributes.readonly,
        });
    }

    pub fn setVariableExported(self: *StateDelta, name: []const u8, enabled: bool) !void {
        self.assertPending();
        state.assertValidVariableName(name);

        if (findVariableAssignment(self, name)) |assignment| {
            if (assignment.exported) |existing| std.debug.assert(existing == enabled);
            assignment.exported = enabled;
            return;
        }
        try self.appendVariableFlag(name, .exported, enabled);
    }

    pub fn setVariableReadonly(self: *StateDelta, name: []const u8) !void {
        self.assertPending();
        state.assertValidVariableName(name);

        if (findVariableAssignment(self, name)) |assignment| {
            assignment.readonly = true;
            return;
        }
        try self.appendVariableFlag(name, .readonly, true);
    }

    pub fn unsetVariable(self: *StateDelta, name: []const u8) !void {
        self.assertPending();
        state.assertValidVariableName(name);

        for (self.variable_unsets.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.variable_unsets.append(self.allocator, owned_name);
    }

    pub fn unsetFunction(self: *StateDelta, name: []const u8) !void {
        self.assertPending();
        state.assertValidVariableName(name);

        for (self.function_unsets.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.function_unsets.append(self.allocator, owned_name);
    }

    pub fn setFunction(self: *StateDelta, definition: command_plan.FunctionDefinition) !void {
        self.assertPending();
        definition.validate();

        for (self.function_sets.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, definition.name)) continue;
            const replacement = try cloneFunctionDefinition(self.allocator, definition);
            freeFunctionDefinition(self.allocator, existing.*);
            existing.* = replacement;
            return;
        }

        const owned_definition = try cloneFunctionDefinition(self.allocator, definition);
        errdefer freeFunctionDefinition(self.allocator, owned_definition);
        try self.function_sets.append(self.allocator, owned_definition);
    }

    pub fn setOption(self: *StateDelta, option: state.ShellOption, enabled: bool) !void {
        self.assertPending();
        for (self.option_changes.items) |*change| {
            if (change.option == option) {
                change.enabled = enabled;
                return;
            }
        }
        try self.option_changes.append(self.allocator, .{ .option = option, .enabled = enabled });
    }

    pub fn setAlias(self: *StateDelta, name: []const u8, value: []const u8) !void {
        self.assertPending();
        state.assertValidAliasName(name);

        if (findNameValueMutation(&self.alias_sets, name)) |mutation| {
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(mutation.value);
            mutation.value = owned_value;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.alias_sets.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }

    pub fn unsetAlias(self: *StateDelta, name: []const u8) !void {
        self.assertPending();
        state.assertValidAliasName(name);

        for (self.alias_unsets.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.alias_unsets.append(self.allocator, owned_name);
    }

    pub fn setAbbreviation(self: *StateDelta, name: []const u8, value: []const u8) !void {
        self.assertPending();
        state.assertValidVariableName(name);

        if (findNameValueMutation(&self.abbreviation_sets, name)) |mutation| {
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(mutation.value);
            mutation.value = owned_value;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.abbreviation_sets.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }

    pub fn unsetAbbreviation(self: *StateDelta, name: []const u8) !void {
        self.assertPending();
        state.assertValidVariableName(name);

        for (self.abbreviation_unsets.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.abbreviation_unsets.append(self.allocator, owned_name);
    }

    pub fn clearAliases(self: *StateDelta) void {
        self.assertPending();
        self.clear_aliases = true;
    }

    pub fn setTrap(self: *StateDelta, name: []const u8, action: ?[]const u8) !void {
        self.assertPending();
        state.assertValidTrapName(name);

        if (findTrapMutation(self, name)) |mutation| {
            const owned_action = if (action) |action_value| try self.allocator.dupe(u8, action_value) else null;
            if (mutation.action) |old_action| self.allocator.free(old_action);
            mutation.action = owned_action;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_action = if (action) |action_value| try self.allocator.dupe(u8, action_value) else null;
        errdefer if (owned_action) |action_value| self.allocator.free(action_value);
        try self.trap_mutations.append(self.allocator, .{ .name = owned_name, .action = owned_action });
    }

    pub fn enqueuePendingTrap(self: *StateDelta, signal: state.TrapSignal) !void {
        self.assertPending();
        signal.validate();
        try self.pending_trap_enqueues.append(self.allocator, signal);
    }

    pub fn consumePendingTraps(self: *StateDelta, count: usize) void {
        self.assertPending();
        std.debug.assert(count != 0);
        self.pending_trap_consume_count = std.math.add(usize, self.pending_trap_consume_count, count) catch unreachable;
    }

    pub fn setPendingExit(self: *StateDelta, status: state.ExitStatus) void {
        self.assertPending();
        std.debug.assert(!self.clear_pending_exit);
        self.pending_exit = status;
    }

    pub fn clearPendingExit(self: *StateDelta) void {
        self.assertPending();
        std.debug.assert(self.pending_exit == null);
        self.clear_pending_exit = true;
    }

    pub fn appendSignalDelivery(
        self: *StateDelta,
        shell_state: state.ShellState,
        signal: state.TrapSignal,
    ) !state.TrapDelivery {
        self.assertPending();
        shell_state.validate();
        signal.validate();
        std.debug.assert(signal.isRuntimeSignal());
        return switch (shell_state.trapDisposition(signal)) {
            .caught => blk: {
                try self.enqueuePendingTrap(signal);
                break :blk .queued;
            },
            .ignore => .ignored,
            .default => blk: {
                self.setPendingExit(signal.defaultExitStatus().?);
                break :blk .default_action;
            },
        };
    }

    pub fn replacePositionals(self: *StateDelta, args: []const []const u8) !void {
        self.assertPending();
        std.debug.assert(self.positionals == null);

        const owned_args = try self.allocator.alloc([]const u8, args.len);
        errdefer self.allocator.free(owned_args);

        var initialized: usize = 0;
        errdefer for (owned_args[0..initialized]) |arg| self.allocator.free(arg);

        for (args, 0..) |arg, index| {
            owned_args[index] = try self.allocator.dupe(u8, arg);
            initialized += 1;
        }

        self.positionals = owned_args;
    }

    pub fn setLogicalCwd(self: *StateDelta, cwd: []const u8) !void {
        self.assertPending();
        std.debug.assert(self.logical_cwd == null);
        state.assertValidLogicalCwd(cwd);
        self.logical_cwd = try self.allocator.dupe(u8, cwd);
    }

    pub fn setLastStatus(self: *StateDelta, status: state.ExitStatus) void {
        self.assertPending();
        std.debug.assert(self.last_status == null);
        self.last_status = status;
    }

    pub fn setLastPipelineStatuses(self: *StateDelta, statuses: []const state.ExitStatus) !void {
        self.assertPending();
        std.debug.assert(statuses.len != 0);
        std.debug.assert(self.last_pipeline_statuses == null);
        const owned_statuses = try self.allocator.alloc(state.ExitStatus, statuses.len);
        @memcpy(owned_statuses, statuses);
        self.last_pipeline_statuses = owned_statuses;
    }

    pub fn appendBackgroundJob(self: *StateDelta, job: state.BackgroundJob) !void {
        self.assertPending();
        job.validate();
        for (self.background_jobs.items) |existing| {
            std.debug.assert(existing.id != job.id);
        }
        var owned_job = try job.clone(self.allocator);
        errdefer owned_job.deinit(self.allocator);
        try self.background_jobs.append(self.allocator, owned_job);
    }

    pub fn updateBackgroundJob(self: *StateDelta, job: state.BackgroundJob) !void {
        self.assertPending();
        job.validate();
        for (self.background_jobs.items) |existing| std.debug.assert(existing.id != job.id);
        for (self.background_job_removals.items) |id| std.debug.assert(id != job.id);
        for (self.background_job_updates.items) |*existing| {
            if (existing.id != job.id) continue;
            var owned_job = try job.clone(self.allocator);
            errdefer owned_job.deinit(self.allocator);
            existing.deinit(self.allocator);
            existing.* = owned_job;
            return;
        }
        var owned_job = try job.clone(self.allocator);
        errdefer owned_job.deinit(self.allocator);
        try self.background_job_updates.append(self.allocator, owned_job);
    }

    pub fn removeBackgroundJob(self: *StateDelta, id: usize) !void {
        self.assertPending();
        std.debug.assert(id != 0);
        for (self.background_jobs.items) |job| std.debug.assert(job.id != id);
        for (self.background_job_updates.items) |job| std.debug.assert(job.id != id);
        for (self.background_job_removals.items) |existing| std.debug.assert(existing != id);
        try self.background_job_removals.append(self.allocator, id);
    }

    pub fn appendJobNotification(self: *StateDelta, notification: state.BackgroundJobNotification) !void {
        self.assertPending();
        notification.validate();
        var owned_notification = try notification.clone(self.allocator);
        errdefer owned_notification.deinit(self.allocator);
        try self.job_notifications.append(self.allocator, owned_notification);
    }

    pub fn consumeJobNotifications(self: *StateDelta, count: usize) void {
        self.assertPending();
        std.debug.assert(self.job_notification_consume_count == 0);
        self.job_notification_consume_count = count;
    }

    pub fn setJobMarkers(self: *StateDelta, markers: JobMarkerMutation) void {
        self.assertPending();
        markers.validate();
        self.job_markers = markers;
    }

    pub fn firstReadonlyVariableAssignment(self: StateDelta, shell_state: state.ShellState) ?[]const u8 {
        self.assertPending();
        for (self.variable_assignments.items) |assignment| {
            if (shell_state.isVariableReadonly(assignment.name)) return assignment.name;
        }
        for (self.variable_unsets.items) |name| {
            if (shell_state.isVariableReadonly(name)) return name;
        }
        return null;
    }

    pub fn appendPersistentCommandAssignments(
        self: *StateDelta,
        shell_state: state.ShellState,
        assignments: []const command_plan.Assignment,
    ) !void {
        self.assertPending();
        if (firstReadonlyAssignment(shell_state, assignments) != null) return error.ReadonlyVariable;

        const exported: ?bool = if (shell_state.options.enabled(.allexport)) true else null;
        for (assignments) |assignment| {
            try self.assignVariable(assignment.name, assignment.value, .{ .exported = exported });
        }
    }

    pub fn commit(self: *StateDelta, shell_state: *state.ShellState, target: context.ExecutionTarget) !void {
        std.debug.assert(self.state == .pending);
        std.debug.assert(self.target == target);
        std.debug.assert(target.allowsShellStateCommit());
        std.debug.assert(shell_state.acceptsExecutionTarget(target));

        if (self.firstReadonlyVariableAssignment(shell_state.*) != null) return error.ReadonlyVariable;

        for (self.variable_assignments.items) |assignment| {
            try shell_state.putVariable(assignment.name, assignment.value, .{
                .exported = assignment.exported,
                .readonly = assignment.readonly,
            });
        }
        for (self.variable_flags.items) |mutation| {
            switch (mutation.flag) {
                .exported => try shell_state.setVariableExported(mutation.name, mutation.enabled),
                .readonly => {
                    std.debug.assert(mutation.enabled);
                    try shell_state.setVariableReadonly(mutation.name);
                },
            }
        }
        for (self.variable_unsets.items) |name| try shell_state.unsetVariable(name);
        for (self.function_sets.items) |definition| try shell_state.putFunction(definition);
        for (self.function_unsets.items) |name| shell_state.unsetFunction(name);
        for (self.option_changes.items) |change| {
            shell_state.options.set(change.option, change.enabled);
        }
        if (self.clear_aliases) shell_state.clearAliases();
        for (self.alias_sets.items) |mutation| try shell_state.setAlias(mutation.name, mutation.value);
        for (self.alias_unsets.items) |name| _ = shell_state.unsetAlias(name);
        for (self.abbreviation_sets.items) |mutation| try shell_state.setAbbreviation(mutation.name, mutation.value);
        for (self.abbreviation_unsets.items) |name| _ = shell_state.unsetAbbreviation(name);
        for (self.trap_mutations.items) |mutation| {
            if (mutation.action) |action| {
                try shell_state.setTrap(mutation.name, action);
            } else {
                shell_state.clearTrap(mutation.name);
            }
        }
        if (self.pending_trap_consume_count != 0) shell_state.consumePendingTraps(self.pending_trap_consume_count);
        for (self.pending_trap_enqueues.items) |signal| try shell_state.appendPendingTrap(signal);
        if (self.clear_pending_exit) shell_state.clearPendingExit();
        if (self.pending_exit) |status| shell_state.setPendingExit(status);
        if (self.positionals) |args| try shell_state.replacePositionals(args);
        if (self.logical_cwd) |cwd| try shell_state.setLogicalCwd(cwd);
        if (self.last_status) |status| shell_state.last_status = status;
        if (self.last_pipeline_statuses) |statuses| try shell_state.setLastPipelineStatuses(statuses);
        for (self.background_jobs.items) |job| try shell_state.appendBackgroundJob(job);
        for (self.background_job_updates.items) |job| try shell_state.replaceBackgroundJob(job);
        for (self.background_job_removals.items) |id| shell_state.removeBackgroundJobById(id);
        if (self.job_notification_consume_count != 0) {
            shell_state.consumeJobNotifications(self.job_notification_consume_count);
        }
        for (self.job_notifications.items) |notification| try shell_state.appendJobNotification(notification);
        if (self.job_markers) |markers| shell_state.setJobMarkers(markers.current_job_id, markers.previous_job_id);

        shell_state.validate();
        self.state = .consumed;
    }

    pub fn discard(self: *StateDelta, target: context.ExecutionTarget) void {
        std.debug.assert(self.state == .pending);
        std.debug.assert(self.target == target);
        self.state = .consumed;
    }

    fn assertPending(self: StateDelta) void {
        std.debug.assert(self.state == .pending);
    }

    fn appendVariableFlag(self: *StateDelta, name: []const u8, flag: VariableFlag, enabled: bool) !void {
        self.assertPending();
        state.assertValidVariableName(name);
        if (flag == .readonly) std.debug.assert(enabled);

        for (self.variable_flags.items) |mutation| {
            if (std.mem.eql(u8, mutation.name, name) and mutation.flag == flag) {
                std.debug.assert(mutation.enabled == enabled);
                return;
            }
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.variable_flags.append(self.allocator, .{ .name = owned_name, .flag = flag, .enabled = enabled });
    }
};

fn findVariableAssignment(delta: *StateDelta, name: []const u8) ?*VariableAssignment {
    for (delta.variable_assignments.items) |*assignment| {
        if (std.mem.eql(u8, assignment.name, name)) return assignment;
    }
    return null;
}

fn findNameValueMutation(list: *std.ArrayList(NameValueMutation), name: []const u8) ?*NameValueMutation {
    for (list.items) |*mutation| {
        if (std.mem.eql(u8, mutation.name, name)) return mutation;
    }
    return null;
}

fn findTrapMutation(delta: *StateDelta, name: []const u8) ?*TrapMutation {
    for (delta.trap_mutations.items) |*mutation| {
        if (std.mem.eql(u8, mutation.name, name)) return mutation;
    }
    return null;
}

fn cloneFunctionDefinition(
    allocator: std.mem.Allocator,
    definition: command_plan.FunctionDefinition,
) !command_plan.FunctionDefinition {
    return command_plan.cloneFunctionDefinition(allocator, definition);
}

fn freeFunctionDefinition(allocator: std.mem.Allocator, definition: command_plan.FunctionDefinition) void {
    command_plan.freeFunctionDefinition(allocator, definition);
}

pub fn firstReadonlyAssignment(
    shell_state: state.ShellState,
    assignments: []const command_plan.Assignment,
) ?[]const u8 {
    for (assignments) |assignment| {
        assignment.validate();
        if (shell_state.isVariableReadonly(assignment.name)) return assignment.name;
    }
    return null;
}

test "StateDelta commits current-shell mutations explicitly" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var state_delta = StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();

    try state_delta.assignVariable("USER", "rush", .{ .exported = true });
    try state_delta.assignVariable("answer", "42", .{});
    try state_delta.setVariableReadonly("answer");
    try state_delta.setOption(.errexit, true);
    try state_delta.replacePositionals(&.{ "a", "b" });
    try state_delta.setLogicalCwd("/tmp");
    state_delta.setLastStatus(3);

    try state_delta.commit(&shell_state, .current_shell);

    try std.testing.expectEqual(DeltaState.consumed, state_delta.state);
    try std.testing.expectEqualStrings("rush", shell_state.getVariable("USER").?.value);
    try std.testing.expect(shell_state.getVariable("USER").?.exported);
    try std.testing.expect(shell_state.getVariable("answer").?.readonly);
    try std.testing.expect(shell_state.options.enabled(.errexit));
    try std.testing.expectEqualStrings("a", shell_state.positionals.items[0]);
    try std.testing.expectEqualStrings("/tmp", shell_state.logical_cwd);
    try std.testing.expectEqual(@as(state.ExitStatus, 3), shell_state.last_status);
}

test "StateDelta discard consumes child mutations without touching parent state" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("KEEP", "parent", .{});

    var child_delta = StateDelta.init(std.testing.allocator, .child_process);
    defer child_delta.deinit();

    try child_delta.assignVariable("KEEP", "child", .{});
    try child_delta.setOption(.nounset, true);
    child_delta.setLastStatus(9);

    child_delta.discard(.child_process);

    try std.testing.expectEqual(DeltaState.consumed, child_delta.state);
    try std.testing.expectEqualStrings("parent", shell_state.getVariable("KEEP").?.value);
    try std.testing.expect(!shell_state.options.enabled(.nounset));
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
}

test "StateDelta clone is deep and preserves pending mutations" {
    var original = StateDelta.init(std.testing.allocator, .subshell);
    defer original.deinit();

    try original.assignVariable("name", "value", .{});
    try original.setVariableExported("name", true);
    try original.setOption(.pipefail, true);
    try original.replacePositionals(&.{"one"});
    original.setLastStatus(4);

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expectEqual(DeltaState.pending, cloned.state);
    try std.testing.expectEqual(context.ExecutionTarget.subshell, cloned.target);
    try std.testing.expectEqual(@as(usize, 1), cloned.variable_assignments.items.len);
    try std.testing.expectEqualStrings("name", cloned.variable_assignments.items[0].name);
    try std.testing.expectEqualStrings("value", cloned.variable_assignments.items[0].value);
    try std.testing.expect(cloned.variable_assignments.items[0].exported.?);
    try std.testing.expectEqual(@as(state.ExitStatus, 4), cloned.last_status.?);

    try original.assignVariable("other", "original-only", .{});
    try std.testing.expectEqual(@as(usize, 1), cloned.variable_assignments.items.len);
}

test "StateDelta deterministic target matrix documents commit versus discard" {
    const targets = [_]context.ExecutionTarget{ .current_shell, .subshell, .child_process };

    for (targets) |target| {
        var shell_state = state.ShellState.init(std.testing.allocator);
        defer shell_state.deinit();
        if (target == .subshell) shell_state.scope = .subshell;

        var state_delta = StateDelta.init(std.testing.allocator, target);
        defer state_delta.deinit();
        state_delta.setLastStatus(11);

        if (target.allowsShellStateCommit()) {
            try state_delta.commit(&shell_state, target);
            try std.testing.expectEqual(@as(state.ExitStatus, 11), shell_state.last_status);
        } else {
            state_delta.discard(target);
            try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);
        }
        try std.testing.expectEqual(DeltaState.consumed, state_delta.state);
    }
}

test "StateDelta rejects readonly commits without partial mutation" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("LOCKED", "old", .{});
    try shell_state.setVariableReadonly("LOCKED");

    var state_delta = StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    try state_delta.assignVariable("A", "new", .{});
    try state_delta.assignVariable("LOCKED", "new", .{});

    try std.testing.expectEqualStrings("LOCKED", state_delta.firstReadonlyVariableAssignment(shell_state).?);
    try std.testing.expectError(error.ReadonlyVariable, state_delta.commit(&shell_state, .current_shell));
    try std.testing.expectEqual(DeltaState.pending, state_delta.state);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("A"));
    try std.testing.expectEqualStrings("old", shell_state.getVariable("LOCKED").?.value);

    state_delta.discard(.current_shell);
}

test "StateDelta command assignments use allexport and last assignment wins" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.allexport, true);

    const assignments = [_]command_plan.Assignment{
        .{ .name = "A", .value = "one" },
        .{ .name = "A", .value = "two" },
    };

    var state_delta = StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    try state_delta.appendPersistentCommandAssignments(shell_state, &assignments);
    try state_delta.commit(&shell_state, .current_shell);

    try std.testing.expectEqualStrings("two", shell_state.getVariable("A").?.value);
    try std.testing.expect(shell_state.getVariable("A").?.exported);
}

test "StateDelta commits signal delivery to pending traps default exit or ignore" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.TERM, "echo term");
    try shell_state.setTrapForSignal(.INT, "");

    var caught_delta = StateDelta.init(std.testing.allocator, .current_shell);
    defer caught_delta.deinit();
    try std.testing.expectEqual(state.TrapDelivery.queued, try caught_delta.appendSignalDelivery(shell_state, .TERM));
    try caught_delta.commit(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(state.TrapSignal.TERM, shell_state.pending_traps.items[0]);

    var ignored_delta = StateDelta.init(std.testing.allocator, .current_shell);
    defer ignored_delta.deinit();
    try std.testing.expectEqual(state.TrapDelivery.ignored, try ignored_delta.appendSignalDelivery(shell_state, .INT));
    try ignored_delta.commit(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.pending_traps.items.len);

    shell_state.clearTrapForSignal(.TERM);
    var default_delta = StateDelta.init(std.testing.allocator, .current_shell);
    defer default_delta.deinit();
    try std.testing.expectEqual(
        state.TrapDelivery.default_action,
        try default_delta.appendSignalDelivery(shell_state, .TERM),
    );
    try default_delta.commit(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.ExitStatus, 143), shell_state.pending_exit);

    var consume_delta = StateDelta.init(std.testing.allocator, .current_shell);
    defer consume_delta.deinit();
    consume_delta.consumePendingTraps(1);
    consume_delta.clearPendingExit();
    try consume_delta.commit(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(@as(?state.ExitStatus, null), shell_state.pending_exit);
}
