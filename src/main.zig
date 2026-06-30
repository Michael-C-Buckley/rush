//! Temporary executable facade for the shell rewrite.

const std = @import("std");
const builtin = @import("builtin");

pub const editor = @import("editor.zig");
pub const event_loop = @import("event_loop.zig");
pub const host = @import("host.zig");
pub const history = @import("history.zig");
pub const shell = @import("shell.zig");

const use_debug_allocator = builtin.mode == .Debug;
const AppDebugAllocator = if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void;
const usage =
    \\usage: rush [--posix] -c SCRIPT [NAME [ARGS...]]
    \\       rush --help
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: AppDebugAllocator = if (use_debug_allocator) .init else {};
    defer if (use_debug_allocator) {
        _ = debug_allocator.deinit();
    };

    const root_allocator = if (use_debug_allocator) debug_allocator.allocator() else std.heap.smp_allocator;

    var process_arena = std.heap.ArenaAllocator.init(root_allocator);
    defer process_arena.deinit();

    const process_allocator = process_arena.allocator();
    var real_host: host.RealHost = .{};

    const args = try init.args.toSlice(process_allocator);
    const invocation = shell.invocation.parse(args) catch {
        try real_host.writeAll(.stderr, usage);
        return 2;
    };

    switch (invocation) {
        .help => {
            try real_host.writeAll(.stdout, usage);
            return 0;
        },
        .command_string => |command| {
            var sh = shell.Shell(host.RealHost).init(process_allocator, real_host, .{
                .state = .{ .mode = command.mode },
                .env = init.environ.block.view().slice,
                .arg_zero = command.arg_zero,
                .positionals = command.positionals,
            });
            defer sh.deinit();

            const src: shell.source.Source = .{
                .id = 1,
                .kind = .command_string,
                .name = command.arg_zero,
                .text = command.script,
            };
            const evaluated = sh.evalSource(src) catch {
                try real_host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            };
            return shell.eval.runExitTrap(&sh, evaluated.status) catch {
                try real_host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            };
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
