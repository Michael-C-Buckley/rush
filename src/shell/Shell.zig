//! Owning shell instance parameterized by a concrete Host type.

const std = @import("std");

const memory = @import("memory.zig");
const state = @import("state.zig");

pub fn Shell(comptime Host: type) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        state: state.State,
        command_arena: memory.Arena,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, host: Host, options: state.Options) Self {
            return .{
                .allocator = allocator,
                .host = host,
                .state = state.State.init(allocator, options),
                .command_arena = memory.Arena.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.command_arena.deinit();
            self.state.deinit();
            self.* = undefined;
        }

        pub fn commandAllocator(self: *Self) std.mem.Allocator {
            return self.command_arena.allocator();
        }

        pub fn resetCommandArena(self: *Self) void {
            self.command_arena.resetRetainingCapacity();
        }
    };
}
