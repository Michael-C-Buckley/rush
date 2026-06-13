//! Authoritative mutable model for the redesigned semantic shell core.
//!
//! The old executor still owns behavior today. This module establishes the
//! owned state vocabulary that later semantic tasks will mutate through
//! explicit `StateDelta` commit points.

const std = @import("std");
const context = @import("context.zig");

pub const ExitStatus = u8;

pub const Scope = enum {
    current_shell,
    subshell,
};

pub const ShellOption = enum {
    allexport,
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
    xtrace,
};

pub const ShellOptions = struct {
    allexport: bool = false,
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
    xtrace: bool = false,

    pub fn set(self: *ShellOptions, option: ShellOption, value: bool) void {
        switch (option) {
            .allexport => self.allexport = value,
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
            .xtrace => self.xtrace = value,
        }
    }

    pub fn enabled(self: ShellOptions, option: ShellOption) bool {
        return switch (option) {
            .allexport => self.allexport,
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
            .xtrace => self.xtrace,
        };
    }
};

pub const VariableAttributes = struct {
    exported: ?bool = null,
    readonly: bool = false,
};

pub const Variable = struct {
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,
};

pub const ShellState = struct {
    allocator: std.mem.Allocator,
    scope: Scope = .current_shell,
    variables: std.StringHashMapUnmanaged(Variable) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,
    options: ShellOptions = .{},
    logical_cwd: []const u8 = "",
    last_status: ExitStatus = 0,
    last_pipeline_statuses: std.ArrayList(ExitStatus) = .empty,

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

        freePositionals(self.allocator, self.positionals.items);
        self.positionals.deinit(self.allocator);
        if (self.logical_cwd.len != 0) self.allocator.free(self.logical_cwd);
        self.last_pipeline_statuses.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn clone(self: *const ShellState, allocator: std.mem.Allocator) !ShellState {
        var cloned = ShellState.init(allocator);
        errdefer cloned.deinit();

        cloned.scope = self.scope;
        cloned.options = self.options;
        cloned.last_status = self.last_status;

        var variables = self.variables.iterator();
        while (variables.next()) |entry| {
            try cloned.putVariable(entry.key_ptr.*, entry.value_ptr.value, .{
                .exported = entry.value_ptr.exported,
                .readonly = entry.value_ptr.readonly,
            });
        }

        try cloned.replacePositionals(self.positionals.items);
        if (self.logical_cwd.len != 0) try cloned.setLogicalCwd(self.logical_cwd);
        try cloned.last_pipeline_statuses.appendSlice(allocator, self.last_pipeline_statuses.items);

        cloned.validate();
        return cloned;
    }

    pub fn snapshotForSubshell(self: *const ShellState, allocator: std.mem.Allocator) !ShellState {
        var snapshot = try self.clone(allocator);
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

    pub fn putVariable(self: *ShellState, name: []const u8, value: []const u8, attributes: VariableAttributes) !void {
        assertValidVariableName(name);

        if (self.variables.getEntry(name)) |entry| {
            const previous = entry.value_ptr.*;
            std.debug.assert(!previous.readonly);

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

    pub fn validate(self: ShellState) void {
        var variables = self.variables.iterator();
        while (variables.next()) |entry| {
            assertValidVariableName(entry.key_ptr.*);
        }
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

fn freePositionals(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
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
        .xtrace,
    };

    var shell_options: ShellOptions = .{};
    for (options) |option| {
        try std.testing.expect(!shell_options.enabled(option));
        shell_options.set(option, true);
        try std.testing.expect(shell_options.enabled(option));
        shell_options.set(option, false);
        try std.testing.expect(!shell_options.enabled(option));
    }
}
