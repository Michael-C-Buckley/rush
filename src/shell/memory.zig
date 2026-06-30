//! Allocator helpers for shell-owned arenas.

const std = @import("std");

pub const Arena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(parent_allocator: std.mem.Allocator) Arena {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_allocator) };
    }

    pub fn deinit(self: *Arena) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn resetRetainingCapacity(self: *Arena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn resetFreeingAll(self: *Arena) void {
        _ = self.arena.reset(.free_all);
    }
};

pub const Arenas = struct {
    ast: Arena,
    scratch: Arena,

    pub fn init(parent_allocator: std.mem.Allocator) Arenas {
        return .{
            .ast = Arena.init(parent_allocator),
            .scratch = Arena.init(parent_allocator),
        };
    }

    pub fn deinit(self: *Arenas) void {
        self.scratch.deinit();
        self.ast.deinit();
        self.* = undefined;
    }

    pub fn resetForTopLevelCommand(self: *Arenas) void {
        self.scratch.resetRetainingCapacity();
        self.ast.resetRetainingCapacity();
    }

    pub fn resetScratch(self: *Arenas) void {
        self.scratch.resetRetainingCapacity();
    }
};
