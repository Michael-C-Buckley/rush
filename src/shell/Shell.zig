//! Owning shell instance parameterized by a concrete Host type.

const std = @import("std");

const memory = @import("memory.zig");
const state = @import("state.zig");

pub fn Shell(comptime Host: type) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        state: state.State,
        arenas: memory.Arenas,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, host: Host, options: state.Options) Self {
            return .{
                .allocator = allocator,
                .host = host,
                .state = state.State.init(allocator, options),
                .arenas = memory.Arenas.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.arenas.deinit();
            self.state.deinit();
            self.* = undefined;
        }

        pub fn astAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.ast.allocator();
        }

        pub fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.scratch.allocator();
        }

        pub fn resetForTopLevelCommand(self: *Self) void {
            self.arenas.resetForTopLevelCommand();
        }

        pub fn resetScratch(self: *Self) void {
            self.arenas.resetScratch();
        }
    };
}
