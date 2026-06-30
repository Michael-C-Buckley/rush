//! Mutable shell state for direct evaluation.

const std = @import("std");

const result = @import("result.zig");

pub const Mode = enum {
    posix,
    bash,
};

pub const Options = struct {
    mode: Mode = .bash,
    errexit: bool = false,
    nounset: bool = false,
    noexec: bool = false,
    xtrace: bool = false,
    monitor: bool = false,
    interactive: bool = false,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    options: Options = .{},
    variables: std.StringHashMapUnmanaged(Variable) = .empty,
    last_status: result.ExitStatus = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) State {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *State) void {
        var iterator = self.variables.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.value);
        }
        self.variables.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn getVariable(self: State, name: []const u8) ?Variable {
        return self.variables.get(name);
    }

    pub fn putVariable(self: *State, variable: Variable) !void {
        std.debug.assert(variable.name.len != 0);
        const owned_name = try self.allocator.dupe(u8, variable.name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, variable.value);
        errdefer self.allocator.free(owned_value);

        if (self.variables.fetchRemove(variable.name)) |old| {
            self.allocator.free(old.value.name);
            self.allocator.free(old.value.value);
        }

        try self.variables.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = owned_value,
            .exported = variable.exported,
            .readonly = variable.readonly,
        });
    }
};
