//! Owning shell instance parameterized by a concrete Host type.

const std = @import("std");

const state = @import("state.zig");

pub fn Shell(comptime Host: type) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        state: state.State,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, host: Host, options: state.Options) Self {
            return .{
                .allocator = allocator,
                .host = host,
                .state = state.State.init(allocator, options),
            };
        }

        pub fn deinit(self: *Self) void {
            self.state.deinit();
            self.* = undefined;
        }
    };
}
