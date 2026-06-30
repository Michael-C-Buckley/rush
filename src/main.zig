//! Temporary executable facade for the shell rewrite.

const std = @import("std");
const builtin = @import("builtin");

pub const editor = @import("editor.zig");
pub const event_loop = @import("event_loop.zig");
pub const history = @import("history.zig");
pub const shell = @import("shell.zig");

const use_debug_allocator = builtin.mode == .Debug;
const AppDebugAllocator = if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void;

pub fn main(init: std.process.Init.Minimal) !u8 {
    _ = init;

    var debug_allocator: AppDebugAllocator = if (use_debug_allocator) .init else {};
    defer if (use_debug_allocator) {
        _ = debug_allocator.deinit();
    };

    const root_allocator = if (use_debug_allocator) debug_allocator.allocator() else std.heap.smp_allocator;
    var process_arena = std.heap.ArenaAllocator.init(root_allocator);
    defer process_arena.deinit();

    const process_allocator = process_arena.allocator();
    _ = process_allocator;

    return 2;
}
