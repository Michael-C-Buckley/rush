//! Authoritative mutable model for the redesigned semantic shell core.
//!
//! This module owns the shell state vocabulary mutated through explicit
//! `StateDelta` commit points.

const std = @import("std");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const runtime_process = @import("../runtime/process.zig");
const trap_semantics = @import("trap.zig");

pub const ExitStatus = u8;
pub const TrapSignal = trap_semantics.Signal;
pub const TrapDisposition = trap_semantics.Disposition;
pub const TrapDelivery = trap_semantics.Delivery;

pub const Scope = enum {
    current_shell,
    subshell,
};

pub const ShellOption = enum {
    allexport,
    emacs,
    errexit,
    ignoreeof,
    monitor,
    noclobber,
    noexec,
    noglob,
    notify,
    nounset,
    pipefail,
    verbose,
    vi,
    xtrace,
};

pub const ShellShopt = enum {
    expand_aliases,
};

pub const ShellShopts = struct {
    expand_aliases: bool = true,

    pub fn set(self: *ShellShopts, option: ShellShopt, value: bool) void {
        switch (option) {
            .expand_aliases => self.expand_aliases = value,
        }
    }

    pub fn enabled(self: ShellShopts, option: ShellShopt) bool {
        return switch (option) {
            .expand_aliases => self.expand_aliases,
        };
    }
};

pub const GetoptsCursor = struct {
    optind: usize = 1,
    char_index: usize = 1,

    pub fn validate(self: GetoptsCursor) void {
        std.debug.assert(self.optind >= 1);
        std.debug.assert(self.char_index >= 1);
    }
};

pub const ShellOptions = struct {
    allexport: bool = false,
    emacs: bool = true,
    errexit: bool = false,
    ignoreeof: bool = false,
    monitor: bool = false,
    noclobber: bool = false,
    noexec: bool = false,
    noglob: bool = false,
    notify: bool = false,
    nounset: bool = false,
    pipefail: bool = false,
    verbose: bool = false,
    vi: bool = false,
    xtrace: bool = false,

    pub fn set(self: *ShellOptions, option: ShellOption, value: bool) void {
        switch (option) {
            .allexport => self.allexport = value,
            .emacs => {
                self.emacs = value;
                if (value) self.vi = false;
            },
            .errexit => self.errexit = value,
            .ignoreeof => self.ignoreeof = value,
            .monitor => self.monitor = value,
            .noclobber => self.noclobber = value,
            .noexec => self.noexec = value,
            .noglob => self.noglob = value,
            .notify => self.notify = value,
            .nounset => self.nounset = value,
            .pipefail => self.pipefail = value,
            .verbose => self.verbose = value,
            .vi => {
                self.vi = value;
                self.emacs = !value;
            },
            .xtrace => self.xtrace = value,
        }
    }

    pub fn enabled(self: ShellOptions, option: ShellOption) bool {
        return switch (option) {
            .allexport => self.allexport,
            .emacs => self.emacs,
            .errexit => self.errexit,
            .ignoreeof => self.ignoreeof,
            .monitor => self.monitor,
            .noclobber => self.noclobber,
            .noexec => self.noexec,
            .noglob => self.noglob,
            .notify => self.notify,
            .nounset => self.nounset,
            .pipefail => self.pipefail,
            .verbose => self.verbose,
            .vi => self.vi,
            .xtrace => self.xtrace,
        };
    }
};

pub fn applyShellOptionShort(options: *ShellOptions, spelling: []const u8) bool {
    if (spelling.len < 2) return false;
    if (spelling[0] != '-' and spelling[0] != '+') return false;
    for (spelling[1..]) |option| switch (option) {
        'a', 'b', 'e', 'f', 'h', 'm', 'n', 'u', 'x', 'v', 'C' => {},
        else => return false,
    };

    const enabled = spelling[0] == '-';
    for (spelling[1..]) |option| switch (option) {
        'a' => options.set(.allexport, enabled),
        'b' => options.set(.notify, enabled),
        'e' => options.set(.errexit, enabled),
        'f' => options.set(.noglob, enabled),
        'h' => {},
        'm' => options.set(.monitor, enabled),
        'n' => options.set(.noexec, enabled),
        'u' => options.set(.nounset, enabled),
        'x' => options.set(.xtrace, enabled),
        'v' => options.set(.verbose, enabled),
        'C' => options.set(.noclobber, enabled),
        else => unreachable,
    };
    return true;
}

pub fn applyShellOptionName(options: *ShellOptions, name: []const u8, enabled: bool) bool {
    if (std.mem.eql(u8, name, "pipefail")) {
        options.set(.pipefail, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "emacs")) {
        options.set(.emacs, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "ignoreeof")) {
        options.set(.ignoreeof, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "vi")) {
        options.set(.vi, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "monitor")) {
        options.set(.monitor, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "allexport")) {
        options.set(.allexport, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "noglob")) {
        options.set(.noglob, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "noclobber")) {
        options.set(.noclobber, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "noexec")) {
        options.set(.noexec, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "notify")) {
        options.set(.notify, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "nolog")) {
        return true;
    }
    if (std.mem.eql(u8, name, "nounset")) {
        options.set(.nounset, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "errexit")) {
        options.set(.errexit, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "xtrace")) {
        options.set(.xtrace, enabled);
        return true;
    }
    if (std.mem.eql(u8, name, "verbose")) {
        options.set(.verbose, enabled);
        return true;
    }
    return false;
}

pub const VariableAttributes = struct {
    exported: ?bool = null,
    readonly: bool = false,
};

pub const VariableMutationError = error{
    ReadonlyVariable,
};

pub const Variable = struct {
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,
};

pub const Alias = struct {
    value: []const u8,
};

pub const Trap = struct {
    action: []const u8,

    pub fn kind(self: Trap) trap_semantics.ActionKind {
        self.validate();
        return trap_semantics.actionKind(self.action);
    }

    pub fn disposition(self: Trap) TrapDisposition {
        return switch (self.kind()) {
            .command => .caught,
            .ignore => .ignore,
        };
    }

    pub fn validate(self: Trap) void {
        trap_semantics.assertValidAction(self.action);
    }
};

pub const JobState = enum {
    running,
    stopped,
    done,
};

pub const BackgroundJobProcess = struct {
    stage_index: usize,
    child: runtime_process.ChildProcess,
    status: ?ExitStatus = null,
    stop_signal: ?u8 = null,
    termination_signal: ?u8 = null,

    pub fn validate(self: BackgroundJobProcess) void {
        switch (self.child.state) {
            .running => std.debug.assert(self.status == null or self.stop_signal != null),
            .waited => std.debug.assert(self.status != null and self.stop_signal == null),
        }
        if (self.stop_signal) |signal| std.debug.assert(signal != 0);
        if (self.termination_signal) |signal| std.debug.assert(signal != 0);
        if (self.stop_signal != null) std.debug.assert(self.termination_signal == null);
    }
};

pub const BackgroundJob = struct {
    id: usize,
    pid: runtime_process.ProcessId,
    process_group: ?runtime_process.ProcessId = null,
    command: []const u8,
    processes: std.ArrayList(BackgroundJobProcess) = .empty,
    state: JobState = .running,
    status: ExitStatus = 0,
    stop_signal: ?u8 = null,
    termination_signal: ?u8 = null,
    notified_state: ?JobState = null,

    pub fn deinit(self: *BackgroundJob, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        self.processes.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: BackgroundJob, allocator: std.mem.Allocator) !BackgroundJob {
        self.validate();
        const owned_command = try allocator.dupe(u8, self.command);
        errdefer allocator.free(owned_command);

        var processes: std.ArrayList(BackgroundJobProcess) = .empty;
        errdefer processes.deinit(allocator);
        try processes.appendSlice(allocator, self.processes.items);

        const cloned: BackgroundJob = .{
            .id = self.id,
            .pid = self.pid,
            .process_group = self.process_group,
            .command = owned_command,
            .processes = processes,
            .state = self.state,
            .status = self.status,
            .stop_signal = self.stop_signal,
            .termination_signal = self.termination_signal,
            .notified_state = self.notified_state,
        };
        cloned.validate();
        return cloned;
    }

    pub fn appendProcess(self: *BackgroundJob, allocator: std.mem.Allocator, process: BackgroundJobProcess) !void {
        process.validate();
        try self.processes.append(allocator, process);
        self.validate();
    }

    pub fn validate(self: BackgroundJob) void {
        std.debug.assert(self.id != 0);
        std.debug.assert(self.pid > 0);
        if (self.process_group) |process_group| std.debug.assert(process_group > 0);
        std.debug.assert(self.command.len != 0);
        std.debug.assert(self.processes.items.len != 0);
        for (self.processes.items) |process| process.validate();
        if (self.stop_signal) |signal| std.debug.assert(signal != 0);
        if (self.termination_signal) |signal| std.debug.assert(signal != 0);
        switch (self.state) {
            .running => {
                std.debug.assert(self.stop_signal == null);
                std.debug.assert(self.termination_signal == null);
                std.debug.assert(self.hasRunningProcess());
            },
            .stopped => {
                std.debug.assert(self.status != 0);
                std.debug.assert(self.termination_signal == null);
                std.debug.assert(self.hasRunningProcess());
            },
            .done => {
                std.debug.assert(self.stop_signal == null);
                std.debug.assert(self.allProcessesWaited());
            },
        }
        if (self.notified_state) |notified| std.debug.assert(notified != .running);
    }

    pub fn hasRunningProcess(self: BackgroundJob) bool {
        for (self.processes.items) |process| {
            if (process.child.state == .running) return true;
        }
        return false;
    }

    pub fn allProcessesWaited(self: BackgroundJob) bool {
        for (self.processes.items) |process| {
            if (process.child.state != .waited) return false;
        }
        return true;
    }
};

pub const BackgroundJobNotification = struct {
    job_id: usize,
    state: JobState,
    command: []const u8,
    status: ExitStatus = 0,
    stop_signal: ?u8 = null,
    termination_signal: ?u8 = null,

    pub fn deinit(self: *BackgroundJobNotification, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        self.* = undefined;
    }

    pub fn clone(self: BackgroundJobNotification, allocator: std.mem.Allocator) !BackgroundJobNotification {
        self.validate();
        const owned_command = try allocator.dupe(u8, self.command);
        errdefer allocator.free(owned_command);
        const cloned: BackgroundJobNotification = .{
            .job_id = self.job_id,
            .state = self.state,
            .command = owned_command,
            .status = self.status,
            .stop_signal = self.stop_signal,
            .termination_signal = self.termination_signal,
        };
        cloned.validate();
        return cloned;
    }

    pub fn fromJob(job: BackgroundJob) BackgroundJobNotification {
        job.validate();
        std.debug.assert(job.state != .running);
        const notification: BackgroundJobNotification = .{
            .job_id = job.id,
            .state = job.state,
            .command = job.command,
            .status = job.status,
            .stop_signal = job.stop_signal,
            .termination_signal = job.termination_signal,
        };
        notification.validate();
        return notification;
    }

    pub fn validate(self: BackgroundJobNotification) void {
        std.debug.assert(self.job_id != 0);
        std.debug.assert(self.command.len != 0);
        switch (self.state) {
            .running => unreachable,
            .stopped => {
                std.debug.assert(self.status != 0);
                if (self.stop_signal) |signal| std.debug.assert(signal != 0);
                std.debug.assert(self.termination_signal == null);
            },
            .done => {
                std.debug.assert(self.stop_signal == null);
                if (self.termination_signal) |signal| std.debug.assert(signal != 0);
            },
        }
    }
};

pub const ShellState = struct {
    allocator: std.mem.Allocator,
    scope: Scope = .current_shell,
    variables: std.StringHashMapUnmanaged(Variable) = .empty,
    functions: std.StringHashMapUnmanaged(command_plan.FunctionDefinition) = .empty,
    aliases: std.StringHashMapUnmanaged(Alias) = .empty,
    abbreviations: std.StringHashMapUnmanaged([]const u8) = .empty,
    traps: std.StringHashMapUnmanaged(Trap) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,
    options: ShellOptions = .{},
    shopts: ShellShopts = .{},
    getopts_cursor: GetoptsCursor = .{},
    logical_cwd: []const u8 = "",
    last_status: ExitStatus = 0,
    last_pipeline_statuses: std.ArrayList(ExitStatus) = .empty,
    pending_traps: std.ArrayList(TrapSignal) = .empty,
    trap_execution: TrapExecution = .idle,
    pending_exit: ?ExitStatus = null,
    background_jobs: std.ArrayList(BackgroundJob) = .empty,
    pending_job_notifications: std.ArrayList(BackgroundJobNotification) = .empty,
    warned_stopped_jobs_on_exit: bool = false,
    next_job_id: usize = 1,
    current_job_id: ?usize = null,
    previous_job_id: ?usize = null,
    last_background_pid: ?runtime_process.ProcessId = null,

    pub const TrapExecution = enum {
        idle,
        running,
    };

    pub fn init(allocator: std.mem.Allocator) ShellState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShellState) void {
        var variables = self.variables.iterator();
        while (variables.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.variables.deinit(self.allocator);

        var functions = self.functions.iterator();
        while (functions.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeFunctionDefinition(self.allocator, entry.value_ptr.*);
        }
        self.functions.deinit(self.allocator);

        var aliases = self.aliases.iterator();
        while (aliases.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.aliases.deinit(self.allocator);

        var abbreviations = self.abbreviations.iterator();
        while (abbreviations.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.abbreviations.deinit(self.allocator);

        var traps = self.traps.iterator();
        while (traps.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.action);
        }
        self.traps.deinit(self.allocator);

        freePositionals(self.allocator, self.positionals.items);
        self.positionals.deinit(self.allocator);
        if (self.logical_cwd.len != 0) self.allocator.free(self.logical_cwd);
        self.last_pipeline_statuses.deinit(self.allocator);
        self.pending_traps.deinit(self.allocator);
        self.clearBackgroundJobs();
        self.background_jobs.deinit(self.allocator);
        self.clearPendingJobNotifications();
        self.pending_job_notifications.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn clone(self: *const ShellState, allocator: std.mem.Allocator) !ShellState {
        var cloned = ShellState.init(allocator);
        errdefer cloned.deinit();

        cloned.scope = self.scope;
        cloned.options = self.options;
        cloned.shopts = self.shopts;
        cloned.getopts_cursor = self.getopts_cursor;
        cloned.last_status = self.last_status;
        cloned.pending_exit = self.pending_exit;
        cloned.trap_execution = self.trap_execution;
        cloned.warned_stopped_jobs_on_exit = self.warned_stopped_jobs_on_exit;

        var variables = self.variables.iterator();
        while (variables.next()) |entry| {
            try cloned.putVariable(entry.key_ptr.*, entry.value_ptr.value, .{
                .exported = entry.value_ptr.exported,
                .readonly = entry.value_ptr.readonly,
            });
        }

        var functions = self.functions.iterator();
        while (functions.next()) |entry| try cloned.putFunction(entry.value_ptr.*);

        var aliases = self.aliases.iterator();
        while (aliases.next()) |entry| try cloned.setAlias(entry.key_ptr.*, entry.value_ptr.value);

        var abbreviations = self.abbreviations.iterator();
        while (abbreviations.next()) |entry| try cloned.setAbbreviation(entry.key_ptr.*, entry.value_ptr.*);

        var traps = self.traps.iterator();
        while (traps.next()) |entry| try cloned.setTrap(entry.key_ptr.*, entry.value_ptr.action);

        try cloned.replacePositionals(self.positionals.items);
        if (self.logical_cwd.len != 0) try cloned.setLogicalCwd(self.logical_cwd);
        try cloned.last_pipeline_statuses.appendSlice(allocator, self.last_pipeline_statuses.items);
        try cloned.pending_traps.appendSlice(allocator, self.pending_traps.items);
        for (self.background_jobs.items) |job| try cloned.appendBackgroundJobCopy(job);
        cloned.next_job_id = self.next_job_id;
        cloned.current_job_id = self.current_job_id;
        cloned.previous_job_id = self.previous_job_id;
        cloned.last_background_pid = self.last_background_pid;
        for (self.pending_job_notifications.items) |notification| try cloned.appendJobNotification(notification);

        cloned.validate();
        return cloned;
    }

    pub fn snapshotForSubshell(self: *const ShellState, allocator: std.mem.Allocator) !ShellState {
        var snapshot = try self.clone(allocator);
        snapshot.clearBackgroundJobs();
        snapshot.next_job_id = 1;
        snapshot.current_job_id = null;
        snapshot.previous_job_id = null;
        snapshot.last_background_pid = null;
        snapshot.clearPendingJobNotifications();
        snapshot.scope = .subshell;
        snapshot.validate();
        return snapshot;
    }

    pub fn acceptsExecutionTarget(self: ShellState, target: context.ExecutionTarget) bool {
        return switch (target) {
            .current_shell => self.scope == .current_shell,
            .subshell => self.scope == .subshell,
            .child_process => false,
        };
    }

    pub fn getVariable(self: ShellState, name: []const u8) ?Variable {
        assertValidVariableName(name);
        return self.variables.get(name);
    }

    pub fn isVariableReadonly(self: ShellState, name: []const u8) bool {
        assertValidVariableName(name);
        const variable = self.variables.get(name) orelse return false;
        return variable.readonly;
    }

    pub fn putVariable(self: *ShellState, name: []const u8, value: []const u8, attributes: VariableAttributes) !void {
        assertValidVariableName(name);

        if (self.variables.getEntry(name)) |entry| {
            const previous = entry.value_ptr.*;
            if (previous.readonly) return error.ReadonlyVariable;

            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(previous.value);
            entry.value_ptr.* = .{
                .value = owned_value,
                .exported = attributes.exported orelse previous.exported,
                .readonly = previous.readonly or attributes.readonly,
            };
        } else {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_value = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(owned_value);

            try self.variables.put(self.allocator, owned_name, .{
                .value = owned_value,
                .exported = attributes.exported orelse false,
                .readonly = attributes.readonly,
            });
        }

        self.validate();
    }

    pub fn putRushStateVariable(self: *ShellState, name: []const u8, value: []const u8) !void {
        assertValidVariableName(name);
        std.debug.assert(std.mem.startsWith(u8, name, "rush_"));

        if (self.variables.getEntry(name)) |entry| {
            const previous = entry.value_ptr.*;
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(previous.value);
            entry.value_ptr.* = .{
                .value = owned_value,
                .exported = previous.exported,
                .readonly = previous.readonly,
            };
        } else {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_value = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(owned_value);

            try self.variables.put(self.allocator, owned_name, .{ .value = owned_value });
        }

        self.validate();
    }

    pub fn setVariableExported(self: *ShellState, name: []const u8, enabled: bool) !void {
        assertValidVariableName(name);

        if (self.variables.getEntry(name)) |entry| {
            entry.value_ptr.exported = enabled;
        } else {
            std.debug.assert(enabled);
            try self.putVariable(name, "", .{ .exported = true });
        }

        self.validate();
    }

    pub fn setVariableReadonly(self: *ShellState, name: []const u8) !void {
        assertValidVariableName(name);

        if (self.variables.getEntry(name)) |entry| {
            entry.value_ptr.readonly = true;
        } else {
            try self.putVariable(name, "", .{ .readonly = true });
        }

        self.validate();
    }

    pub fn unsetVariable(self: *ShellState, name: []const u8) !void {
        assertValidVariableName(name);
        if (self.isVariableReadonly(name)) return error.ReadonlyVariable;

        if (self.variables.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.value);
        }

        self.validate();
    }

    pub fn getFunction(self: ShellState, name: []const u8) ?command_plan.FunctionDefinition {
        assertValidVariableName(name);
        return self.functions.get(name);
    }

    pub fn putFunctionName(self: *ShellState, name: []const u8) !void {
        try self.putFunction(.{ .name = name });
    }

    pub fn putFunction(self: *ShellState, definition: command_plan.FunctionDefinition) !void {
        definition.validate();

        const owned_key = try self.allocator.dupe(u8, definition.name);
        errdefer self.allocator.free(owned_key);
        const owned_definition = try cloneFunctionDefinition(self.allocator, definition);
        errdefer freeFunctionDefinition(self.allocator, owned_definition);

        const result = try self.functions.getOrPut(self.allocator, owned_key);
        if (result.found_existing) {
            self.allocator.free(owned_key);
            freeFunctionDefinition(self.allocator, result.value_ptr.*);
        }

        result.value_ptr.* = owned_definition;
        self.validate();
    }

    pub fn unsetFunction(self: *ShellState, name: []const u8) void {
        assertValidVariableName(name);
        if (self.functions.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            freeFunctionDefinition(self.allocator, entry.value);
        }
        self.validate();
    }

    pub fn getAlias(self: ShellState, name: []const u8) ?Alias {
        assertValidAliasName(name);
        return self.aliases.get(name);
    }

    pub fn setAlias(self: *ShellState, name: []const u8, value: []const u8) !void {
        assertValidAliasName(name);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const result = try self.aliases.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.value_ptr.value);
            result.value_ptr.* = .{ .value = owned_value };
        } else {
            result.value_ptr.* = .{ .value = owned_value };
        }

        self.validate();
    }

    pub fn unsetAlias(self: *ShellState, name: []const u8) bool {
        assertValidAliasName(name);
        if (self.aliases.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.value);
            self.validate();
            return true;
        }
        self.validate();
        return false;
    }

    pub fn clearAliases(self: *ShellState) void {
        var aliases = self.aliases.iterator();
        while (aliases.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.aliases.clearRetainingCapacity();
        self.validate();
    }

    pub fn getAbbreviation(self: ShellState, name: []const u8) ?[]const u8 {
        assertValidVariableName(name);
        return self.abbreviations.get(name);
    }

    pub fn setAbbreviation(self: *ShellState, name: []const u8, value: []const u8) !void {
        assertValidVariableName(name);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const result = try self.abbreviations.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.value_ptr.*);
        }

        result.value_ptr.* = owned_value;
        self.validate();
    }

    pub fn unsetAbbreviation(self: *ShellState, name: []const u8) bool {
        assertValidVariableName(name);
        if (self.abbreviations.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            self.validate();
            return true;
        }
        self.validate();
        return false;
    }

    pub fn getTrap(self: ShellState, name: []const u8) ?Trap {
        assertValidTrapName(name);
        return self.traps.get(name);
    }

    pub fn getTrapForSignal(self: ShellState, signal: TrapSignal) ?Trap {
        signal.validate();
        return self.getTrap(signal.name());
    }

    pub fn trapDisposition(self: ShellState, signal: TrapSignal) TrapDisposition {
        signal.validate();
        const registered = self.getTrapForSignal(signal) orelse return .default;
        return registered.disposition();
    }

    pub fn setTrap(self: *ShellState, name: []const u8, action: []const u8) !void {
        assertValidTrapName(name);
        trap_semantics.assertValidAction(action);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);

        const result = try self.traps.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.value_ptr.action);
            result.value_ptr.* = .{ .action = owned_action };
        } else {
            result.value_ptr.* = .{ .action = owned_action };
        }

        self.validate();
    }

    pub fn setTrapForSignal(self: *ShellState, signal: TrapSignal, action: []const u8) !void {
        signal.validate();
        try self.setTrap(signal.name(), action);
    }

    pub fn clearTrap(self: *ShellState, name: []const u8) void {
        assertValidTrapName(name);
        if (self.traps.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.action);
        }
        self.validate();
    }

    pub fn clearTrapForSignal(self: *ShellState, signal: TrapSignal) void {
        signal.validate();
        self.clearTrap(signal.name());
    }

    pub fn appendPendingTrap(self: *ShellState, signal: TrapSignal) !void {
        signal.validate();
        try self.pending_traps.append(self.allocator, signal);
        self.validate();
    }

    pub fn requestInteractiveInterruptTrap(self: *ShellState) !bool {
        self.validate();
        std.debug.assert(self.scope == .current_shell);
        if (self.trapDisposition(.INT) != .caught) return false;
        try self.appendPendingTrap(.INT);
        return true;
    }

    pub fn consumePendingTraps(self: *ShellState, count: usize) void {
        std.debug.assert(count <= self.pending_traps.items.len);
        var consumed: usize = 0;
        while (consumed < count) : (consumed += 1) _ = self.pending_traps.orderedRemove(0);
        self.validate();
    }

    pub fn nextPendingTrap(self: ShellState) ?TrapSignal {
        self.validate();
        return if (self.pending_traps.items.len == 0) null else self.pending_traps.items[0];
    }

    pub fn beginTrapExecution(self: *ShellState) void {
        self.validate();
        std.debug.assert(self.trap_execution == .idle);
        self.trap_execution = .running;
        self.validate();
    }

    pub fn endTrapExecution(self: *ShellState) void {
        self.validate();
        std.debug.assert(self.trap_execution == .running);
        self.trap_execution = .idle;
        self.validate();
    }

    pub fn setPendingExit(self: *ShellState, status: ExitStatus) void {
        self.validate();
        self.pending_exit = status;
        self.validate();
    }

    pub fn clearPendingExit(self: *ShellState) void {
        self.validate();
        self.pending_exit = null;
        self.validate();
    }

    pub fn setInteractiveTerminalSize(self: *ShellState, rows_value: u16, cols_value: u16) !void {
        self.validate();
        std.debug.assert(self.scope == .current_shell);
        std.debug.assert(rows_value != 0);
        std.debug.assert(cols_value != 0);

        var rows_buffer: [32]u8 = undefined;
        var cols_buffer: [32]u8 = undefined;
        const rows = try std.fmt.bufPrint(&rows_buffer, "{d}", .{rows_value});
        const cols = try std.fmt.bufPrint(&cols_buffer, "{d}", .{cols_value});
        try self.putVariable("LINES", rows, .{ .exported = true });
        try self.putVariable("COLUMNS", cols, .{ .exported = true });
    }

    pub fn shouldWarnBeforeExitWithStoppedJobs(self: *ShellState) bool {
        self.validate();
        std.debug.assert(self.scope == .current_shell);
        if (!self.hasStoppedJobs()) {
            self.warned_stopped_jobs_on_exit = false;
            self.validate();
            return false;
        }
        if (self.warned_stopped_jobs_on_exit) return false;
        self.warned_stopped_jobs_on_exit = true;
        self.validate();
        return true;
    }

    pub fn replacePositionals(self: *ShellState, args: []const []const u8) !void {
        var replacement: std.ArrayList([]const u8) = .empty;
        errdefer {
            freePositionals(self.allocator, replacement.items);
            replacement.deinit(self.allocator);
        }

        for (args) |arg| {
            const owned_arg = try self.allocator.dupe(u8, arg);
            errdefer self.allocator.free(owned_arg);
            try replacement.append(self.allocator, owned_arg);
        }

        freePositionals(self.allocator, self.positionals.items);
        self.positionals.deinit(self.allocator);
        self.positionals = replacement;
        self.validate();
    }

    pub fn setLogicalCwd(self: *ShellState, cwd: []const u8) !void {
        assertValidLogicalCwd(cwd);

        const owned_cwd = try self.allocator.dupe(u8, cwd);
        if (self.logical_cwd.len != 0) self.allocator.free(self.logical_cwd);
        self.logical_cwd = owned_cwd;
        self.validate();
    }

    pub fn setLastPipelineStatuses(self: *ShellState, statuses: []const ExitStatus) !void {
        self.last_pipeline_statuses.clearRetainingCapacity();
        try self.last_pipeline_statuses.appendSlice(self.allocator, statuses);
        self.validate();
    }

    pub fn appendBackgroundJob(self: *ShellState, job: BackgroundJob) !void {
        job.validate();
        try self.appendBackgroundJobCopy(job);
        self.selectCurrentJob(job.id);
        self.next_job_id = @max(self.next_job_id, job.id + 1);
        self.last_background_pid = job.pid;
        self.validate();
    }

    pub fn findBackgroundJobById(self: ShellState, id: usize) ?BackgroundJob {
        std.debug.assert(id != 0);
        for (self.background_jobs.items) |job| {
            if (job.id == id) return job;
        }
        return null;
    }

    pub fn findBackgroundJobPtrById(self: *ShellState, id: usize) ?*BackgroundJob {
        std.debug.assert(id != 0);
        for (self.background_jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    pub fn findBackgroundJobIndexById(self: ShellState, id: usize) ?usize {
        std.debug.assert(id != 0);
        for (self.background_jobs.items, 0..) |job, index| {
            if (job.id == id) return index;
        }
        return null;
    }

    pub fn replaceBackgroundJob(self: *ShellState, job: BackgroundJob) !void {
        job.validate();
        const index = self.findBackgroundJobIndexById(job.id) orelse unreachable;
        var owned_job = try job.clone(self.allocator);
        errdefer owned_job.deinit(self.allocator);
        self.background_jobs.items[index].deinit(self.allocator);
        self.background_jobs.items[index] = owned_job;
        self.validate();
    }

    pub fn removeBackgroundJobById(self: *ShellState, id: usize) void {
        const index = self.findBackgroundJobIndexById(id) orelse unreachable;
        self.background_jobs.items[index].deinit(self.allocator);
        _ = self.background_jobs.orderedRemove(index);
        self.repairCurrentJobsAfterRemoval(id);
        self.validate();
    }

    pub fn appendJobNotification(self: *ShellState, notification: BackgroundJobNotification) !void {
        notification.validate();
        var owned_notification = try notification.clone(self.allocator);
        errdefer owned_notification.deinit(self.allocator);
        try self.pending_job_notifications.append(self.allocator, owned_notification);
        self.validate();
    }

    pub fn consumeJobNotifications(self: *ShellState, count: usize) void {
        std.debug.assert(count <= self.pending_job_notifications.items.len);
        var consumed: usize = 0;
        while (consumed < count) : (consumed += 1) {
            var notification = self.pending_job_notifications.orderedRemove(0);
            notification.deinit(self.allocator);
        }
        self.validate();
    }

    pub fn queueJobNotification(self: *ShellState, job_id: usize) !void {
        const index = self.findBackgroundJobIndexById(job_id) orelse unreachable;
        var job = &self.background_jobs.items[index];
        job.validate();
        if (job.state == .running or job.notified_state == job.state) return;
        const notification = BackgroundJobNotification.fromJob(job.*);
        try self.appendJobNotification(notification);
        job.notified_state = job.state;
        self.validate();
    }

    pub fn refreshJobMarkers(self: *ShellState) void {
        const old_current = self.current_job_id;
        const old_previous = self.previous_job_id;
        var current_stopped: ?usize = null;
        var previous_stopped: ?usize = null;
        var index = self.background_jobs.items.len;
        while (index > 0) {
            index -= 1;
            const job = self.background_jobs.items[index];
            if (job.state != .stopped) continue;
            if (current_stopped == null) {
                current_stopped = job.id;
            } else {
                previous_stopped = job.id;
                break;
            }
        }

        const current = current_stopped orelse {
            self.dropMissingCurrentJobIds();
            self.validate();
            return;
        };
        self.current_job_id = current;
        if (previous_stopped) |previous| {
            self.previous_job_id = previous;
            self.validate();
            return;
        }
        if (old_current != null and old_current.? != current and self.findBackgroundJobById(old_current.?) != null) {
            self.previous_job_id = old_current;
            self.validate();
            return;
        }
        if (old_previous != null and old_previous.? != current and self.findBackgroundJobById(old_previous.?) != null) {
            self.previous_job_id = old_previous;
            self.validate();
            return;
        }
        var fallback_index = self.background_jobs.items.len;
        while (fallback_index > 0) {
            fallback_index -= 1;
            const job = self.background_jobs.items[fallback_index];
            if (job.id == current) continue;
            self.previous_job_id = job.id;
            self.validate();
            return;
        }
        self.previous_job_id = null;
        self.validate();
    }

    pub fn jobMarker(self: ShellState, job: BackgroundJob) u8 {
        job.validate();
        if (self.current_job_id == job.id) return '+';
        if (self.previous_job_id == job.id) return '-';
        return ' ';
    }

    pub fn setJobMarkers(self: *ShellState, current_job_id: ?usize, previous_job_id: ?usize) void {
        if (current_job_id) |id| std.debug.assert(self.findBackgroundJobById(id) != null);
        if (previous_job_id) |id| std.debug.assert(self.findBackgroundJobById(id) != null);
        std.debug.assert(current_job_id == null or previous_job_id == null or current_job_id.? != previous_job_id.?);
        self.current_job_id = current_job_id;
        self.previous_job_id = previous_job_id;
        self.validate();
    }

    fn appendBackgroundJobCopy(self: *ShellState, job: BackgroundJob) !void {
        std.debug.assert(self.findBackgroundJobById(job.id) == null);
        var owned_job = try job.clone(self.allocator);
        errdefer owned_job.deinit(self.allocator);
        try self.background_jobs.append(self.allocator, owned_job);
    }

    fn clearBackgroundJobs(self: *ShellState) void {
        for (self.background_jobs.items) |*job| job.deinit(self.allocator);
        self.background_jobs.clearRetainingCapacity();
        self.current_job_id = null;
        self.previous_job_id = null;
        self.last_background_pid = null;
    }

    fn clearPendingJobNotifications(self: *ShellState) void {
        for (self.pending_job_notifications.items) |*notification| notification.deinit(self.allocator);
        self.pending_job_notifications.clearRetainingCapacity();
    }

    fn hasStoppedJobs(self: ShellState) bool {
        self.validate();
        std.debug.assert(self.scope == .current_shell);
        for (self.background_jobs.items) |job| {
            job.validate();
            if (job.state == .stopped) return true;
        }
        return false;
    }

    fn selectCurrentJob(self: *ShellState, id: usize) void {
        std.debug.assert(id != 0);
        if (self.current_job_id != null and self.current_job_id.? != id) self.previous_job_id = self.current_job_id;
        self.current_job_id = id;
    }

    fn repairCurrentJobsAfterRemoval(self: *ShellState, id: usize) void {
        if (self.previous_job_id == id) self.previous_job_id = null;
        if (self.current_job_id == id) {
            self.current_job_id = self.previous_job_id;
            self.previous_job_id = null;
        }
        self.dropMissingCurrentJobIds();
    }

    fn dropMissingCurrentJobIds(self: *ShellState) void {
        if (self.current_job_id) |current| {
            if (self.findBackgroundJobById(current) == null) self.current_job_id = null;
        }
        if (self.previous_job_id) |previous| {
            if (self.findBackgroundJobById(previous) == null) self.previous_job_id = null;
        }
    }

    pub fn validate(self: ShellState) void {
        var variables = self.variables.iterator();
        while (variables.next()) |entry| {
            assertValidVariableName(entry.key_ptr.*);
        }
        var functions = self.functions.iterator();
        while (functions.next()) |entry| {
            assertValidVariableName(entry.key_ptr.*);
            entry.value_ptr.validate();
            std.debug.assert(std.mem.eql(u8, entry.key_ptr.*, entry.value_ptr.name));
        }
        var aliases = self.aliases.iterator();
        while (aliases.next()) |entry| assertValidAliasName(entry.key_ptr.*);
        var abbreviations = self.abbreviations.iterator();
        while (abbreviations.next()) |entry| {
            assertValidVariableName(entry.key_ptr.*);
            std.debug.assert(std.mem.indexOfScalar(u8, entry.value_ptr.*, 0) == null);
        }
        var traps = self.traps.iterator();
        while (traps.next()) |entry| {
            assertValidTrapName(entry.key_ptr.*);
            entry.value_ptr.validate();
        }
        for (self.pending_traps.items) |signal| signal.validate();
        self.getopts_cursor.validate();
        for (self.background_jobs.items) |job| {
            job.validate();
            std.debug.assert(job.id < self.next_job_id);
        }
        for (self.pending_job_notifications.items) |notification| notification.validate();
        if (self.current_job_id) |id| std.debug.assert(self.findBackgroundJobById(id) != null);
        if (self.previous_job_id) |id| std.debug.assert(self.findBackgroundJobById(id) != null);
        if (self.current_job_id != null and self.previous_job_id != null) {
            std.debug.assert(self.current_job_id.? != self.previous_job_id.?);
        }
        if (self.last_background_pid) |pid| std.debug.assert(pid > 0);
        if (self.logical_cwd.len != 0) assertValidLogicalCwd(self.logical_cwd);
    }
};

pub fn assertValidVariableName(name: []const u8) void {
    std.debug.assert(name.len != 0);
    std.debug.assert(std.ascii.isAlphabetic(name[0]) or name[0] == '_');
    for (name[1..]) |byte| {
        std.debug.assert(std.ascii.isAlphanumeric(byte) or byte == '_');
    }
}

pub fn assertValidLogicalCwd(cwd: []const u8) void {
    std.debug.assert(cwd.len != 0);
    std.debug.assert(cwd[0] == '/');
}

pub fn assertValidAliasName(name: []const u8) void {
    std.debug.assert(name.len != 0);
    for (name) |byte| {
        std.debug.assert(std.ascii.isAlphabetic(byte) or
            std.ascii.isDigit(byte) or
            byte == '!' or
            byte == '%' or
            byte == ',' or
            byte == '-' or
            byte == '@' or
            byte == '_');
    }
}

pub fn assertValidTrapName(name: []const u8) void {
    trap_semantics.assertValidName(name);
}

pub fn isValidTrapName(name: []const u8) bool {
    return trap_semantics.isValidName(name);
}

fn freePositionals(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
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

test "ShellState owns variables positionals cwd and clones for subshell isolation" {
    var shell_state = ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    try shell_state.putVariable("PATH", "/bin", .{ .exported = true });
    try shell_state.putVariable("answer", "42", .{});
    try shell_state.setVariableReadonly("answer");
    try shell_state.replacePositionals(&.{ "one", "two" });
    try shell_state.setLogicalCwd("/tmp");
    shell_state.options.set(.pipefail, true);
    shell_state.last_status = 7;

    var subshell = try shell_state.snapshotForSubshell(std.testing.allocator);
    defer subshell.deinit();

    try std.testing.expect(shell_state.acceptsExecutionTarget(.current_shell));
    try std.testing.expect(!shell_state.acceptsExecutionTarget(.subshell));
    try std.testing.expect(subshell.acceptsExecutionTarget(.subshell));
    try std.testing.expect(!subshell.acceptsExecutionTarget(.current_shell));

    try std.testing.expectEqual(Scope.subshell, subshell.scope);
    try std.testing.expectEqual(@as(ExitStatus, 7), subshell.last_status);
    try std.testing.expect(subshell.options.enabled(.pipefail));
    try std.testing.expectEqualStrings("/bin", subshell.getVariable("PATH").?.value);
    try std.testing.expect(subshell.getVariable("PATH").?.exported);
    try std.testing.expect(subshell.getVariable("answer").?.readonly);
    try std.testing.expectEqualStrings("one", subshell.positionals.items[0]);

    try subshell.putVariable("PATH", "/usr/bin", .{ .exported = true });
    try subshell.replacePositionals(&.{"sub"});
    try std.testing.expectEqualStrings("/bin", shell_state.getVariable("PATH").?.value);
    try std.testing.expectEqualStrings("one", shell_state.positionals.items[0]);
}

test "ShellOptions toggles every modeled option deterministically" {
    const options = [_]ShellOption{
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

    var shell_options: ShellOptions = .{};
    for (options) |option| {
        shell_options.set(option, true);
        try std.testing.expect(shell_options.enabled(option));
        shell_options.set(option, false);
        try std.testing.expect(!shell_options.enabled(option));
    }
}

test "ShellShopts toggles every modeled shopt deterministically" {
    const shopts = [_]ShellShopt{.expand_aliases};

    var shell_shopts: ShellShopts = .{};
    for (shopts) |shopt| {
        shell_shopts.set(shopt, false);
        try std.testing.expect(!shell_shopts.enabled(shopt));
        shell_shopts.set(shopt, true);
        try std.testing.expect(shell_shopts.enabled(shopt));
    }
}

test "ShellOptions parses short and named invocation options" {
    var options: ShellOptions = .{};

    try std.testing.expect(applyShellOptionShort(&options, "-euC"));
    try std.testing.expect(options.errexit);
    try std.testing.expect(options.nounset);
    try std.testing.expect(options.noclobber);

    try std.testing.expect(applyShellOptionShort(&options, "+e"));
    try std.testing.expect(!options.errexit);
    try std.testing.expect(applyShellOptionName(&options, "pipefail", true));
    try std.testing.expect(options.pipefail);
    try std.testing.expect(applyShellOptionName(&options, "vi", true));
    try std.testing.expect(options.vi);
    try std.testing.expect(!options.emacs);
    try std.testing.expect(applyShellOptionName(&options, "emacs", true));
    try std.testing.expect(options.emacs);
    try std.testing.expect(!options.vi);

    try std.testing.expect(!applyShellOptionShort(&options, "-z"));
    try std.testing.expect(!applyShellOptionName(&options, "unknown", true));
}

test "ShellState reports readonly assignment as semantic error" {
    var shell_state = ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    try shell_state.putVariable("LOCKED", "first", .{});
    try shell_state.setVariableReadonly("LOCKED");

    try std.testing.expect(shell_state.isVariableReadonly("LOCKED"));
    try std.testing.expectError(error.ReadonlyVariable, shell_state.putVariable("LOCKED", "second", .{}));
    try std.testing.expectEqualStrings("first", shell_state.getVariable("LOCKED").?.value);
}

test "ShellState models trap dispositions pending queue and execution guard" {
    var shell_state = ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    try std.testing.expectEqual(TrapDisposition.default, shell_state.trapDisposition(.TERM));

    try shell_state.setTrapForSignal(.TERM, "echo term");
    try std.testing.expectEqual(TrapDisposition.caught, shell_state.trapDisposition(.TERM));
    try std.testing.expectEqualStrings("echo term", shell_state.getTrapForSignal(.TERM).?.action);

    try shell_state.setTrapForSignal(.INT, "");
    try std.testing.expectEqual(TrapDisposition.ignore, shell_state.trapDisposition(.INT));

    try shell_state.appendPendingTrap(.TERM);
    try shell_state.appendPendingTrap(.INT);
    try std.testing.expectEqual(@as(usize, 2), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(TrapSignal.TERM, shell_state.nextPendingTrap().?);

    shell_state.beginTrapExecution();
    try std.testing.expectEqual(ShellState.TrapExecution.running, shell_state.trap_execution);
    shell_state.endTrapExecution();
    try std.testing.expectEqual(ShellState.TrapExecution.idle, shell_state.trap_execution);

    shell_state.consumePendingTraps(1);
    try std.testing.expectEqual(@as(usize, 1), shell_state.pending_traps.items.len);
    try std.testing.expectEqual(TrapSignal.INT, shell_state.nextPendingTrap().?);
    shell_state.setPendingExit(143);
    try std.testing.expectEqual(@as(?ExitStatus, 143), shell_state.pending_exit);
    shell_state.clearPendingExit();
    try std.testing.expectEqual(@as(?ExitStatus, null), shell_state.pending_exit);
}

test "ShellState owns interactive terminal interrupt and stopped-job policies" {
    var shell_state = ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    try shell_state.setInteractiveTerminalSize(40, 120);
    try std.testing.expectEqualStrings("40", shell_state.getVariable("LINES").?.value);
    try std.testing.expectEqualStrings("120", shell_state.getVariable("COLUMNS").?.value);

    try std.testing.expect(!try shell_state.requestInteractiveInterruptTrap());
    try shell_state.setTrapForSignal(.INT, "echo int");
    try std.testing.expect(try shell_state.requestInteractiveInterruptTrap());
    try std.testing.expectEqual(TrapSignal.INT, shell_state.nextPendingTrap().?);

    try std.testing.expect(!shell_state.shouldWarnBeforeExitWithStoppedJobs());

    const owned_command = try std.testing.allocator.dupe(u8, "stopped job");
    const child: std.process.Child = .{
        .id = 123,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    var job: BackgroundJob = .{
        .id = 1,
        .pid = 123,
        .command = owned_command,
        .state = .stopped,
        .status = 146,
        .stop_signal = 18,
    };
    var job_owned = true;
    errdefer if (job_owned) job.deinit(std.testing.allocator);
    try job.appendProcess(std.testing.allocator, .{
        .stage_index = 0,
        .child = runtime_process.ChildProcess.init(child),
        .status = 146,
        .stop_signal = 18,
    });
    try shell_state.appendBackgroundJob(job);
    job.deinit(std.testing.allocator);
    job_owned = false;

    try std.testing.expect(shell_state.shouldWarnBeforeExitWithStoppedJobs());
    try std.testing.expect(!shell_state.shouldWarnBeforeExitWithStoppedJobs());
    shell_state.removeBackgroundJobById(1);
    try std.testing.expect(!shell_state.shouldWarnBeforeExitWithStoppedJobs());
    try std.testing.expect(!shell_state.warned_stopped_jobs_on_exit);
}
