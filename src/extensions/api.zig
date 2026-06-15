//! Shared API for bundled Rush extension builtin handlers.

const std = @import("std");

const builtin = @import("../shell/builtin.zig");
const command_plan = @import("../shell/command_plan.zig");
const context = @import("../shell/context.zig");
const delta = @import("../shell/delta.zig");
const outcome = @import("../shell/outcome.zig");
const state = @import("../shell/state.zig");

pub const Handler = *const fn (?*anyopaque, *Invocation) anyerror!outcome.ExitStatus;

pub const HandlerSpec = struct {
    context: ?*anyopaque = null,
    handler: Handler,
};

pub const FunctionScope = struct {
    depth: usize,
    context: *anyopaque,
    add_local: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn addLocal(self: FunctionScope, name: []const u8) !void {
        try self.add_local(self.context, name);
    }
};

pub const ExternalResolver = struct {
    context: *anyopaque,
    resolve_command: *const fn (
        std.mem.Allocator,
        *anyopaque,
        []const command_plan.Assignment,
        []const u8,
    ) anyerror!?command_plan.ExternalResolution,
    resolve_all_commands: *const fn (
        std.mem.Allocator,
        *anyopaque,
        []const command_plan.Assignment,
        []const u8,
    ) anyerror![]command_plan.ExternalResolution,

    /// Returns an external resolution whose `path` is owned by `allocator`.
    pub fn resolve(
        self: ExternalResolver,
        allocator: std.mem.Allocator,
        assignments: []const command_plan.Assignment,
        name: []const u8,
    ) !?command_plan.ExternalResolution {
        std.debug.assert(name.len != 0);
        for (assignments) |assignment| assignment.validate();
        return self.resolve_command(allocator, self.context, assignments, name);
    }

    /// Returns external resolutions whose slice and `path` fields are owned by `allocator`.
    pub fn resolveAll(
        self: ExternalResolver,
        allocator: std.mem.Allocator,
        assignments: []const command_plan.Assignment,
        name: []const u8,
    ) ![]command_plan.ExternalResolution {
        std.debug.assert(name.len != 0);
        for (assignments) |assignment| assignment.validate();
        return self.resolve_all_commands(allocator, self.context, assignments, name);
    }
};

pub fn freeExternalResolutions(
    allocator: std.mem.Allocator,
    resolutions: []const command_plan.ExternalResolution,
) void {
    for (resolutions) |resolution| allocator.free(resolution.path);
    allocator.free(resolutions);
}

pub const Invocation = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    assignments: []const command_plan.Assignment = &.{},
    builtins: []const builtin.Builtin,
    shell_state: state.ShellState,
    state_delta: *delta.StateDelta,
    eval_context: context.EvalContext,
    function_scope: ?FunctionScope = null,
    external_resolver: ?ExternalResolver = null,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    diagnostics: *std.ArrayList([]const u8),

    pub fn usageError(self: *Invocation, command: []const u8, message: []const u8) !outcome.ExitStatus {
        return self.statusError(2, command, message);
    }

    pub fn statusError(
        self: *Invocation,
        status: outcome.ExitStatus,
        command: []const u8,
        message: []const u8,
    ) !outcome.ExitStatus {
        std.debug.assert(status != 0);
        std.debug.assert(command.len != 0);
        std.debug.assert(message.len != 0);

        try self.stderr.print(self.allocator, "{s}: {s}\n", .{ command, message });
        const diagnostic = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ command, message });
        errdefer self.allocator.free(diagnostic);
        try self.diagnostics.append(self.allocator, diagnostic);
        return status;
    }
};

pub fn appendShellSingleQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
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
