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
    \\       rush [--posix] SCRIPT [ARGS...]
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
            const src: shell.source.Source = .{
                .id = 1,
                .kind = .command_string,
                .name = command.arg_zero,
                .text = command.script,
            };
            return evalSource(process_allocator, real_host, init.environ.block.view().slice, .{
                .state_options = command.options,
                .arg_zero = command.arg_zero,
                .positionals = command.positionals,
            }, src);
        },
        .script_file => |script| {
            const text = readFileAlloc(process_allocator, &real_host, script.path) catch {
                try real_host.writeAll(.stderr, "rush: cannot read script file\n");
                return 2;
            };
            const src: shell.source.Source = .{
                .id = 1,
                .kind = .script_file,
                .name = script.path,
                .text = text,
            };
            return evalSource(process_allocator, real_host, init.environ.block.view().slice, .{
                .state_options = script.options,
                .arg_zero = script.path,
                .positionals = script.positionals,
            }, src);
        },
    }
}

const EvalSourceOptions = struct {
    state_options: shell.state.Options,
    arg_zero: []const u8,
    positionals: []const []const u8,
};

fn evalSource(
    allocator: std.mem.Allocator,
    real_host: host.RealHost,
    env: []const [*:0]const u8,
    options: EvalSourceOptions,
    src: shell.source.Source,
) !u8 {
    var sh = shell.Shell(host.RealHost).init(allocator, real_host, .{
        .state = options.state_options,
        .env = env,
        .arg_zero = options.arg_zero,
        .positionals = options.positionals,
    });
    defer sh.deinit();

    const evaluated = sh.evalSource(src) catch {
        try sh.host.writeAll(.stderr, "rush: shell error\n");
        return 2;
    };
    return shell.eval.runExitTrap(&sh, evaluated.status) catch {
        try sh.host.writeAll(.stderr, "rush: shell error\n");
        return 2;
    };
}

fn readFileAlloc(allocator: std.mem.Allocator, real_host: *host.RealHost, path: []const u8) ![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = try real_host.openZ(path_z, .{ .access = .read_only });
    defer real_host.close(fd) catch {};

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_len = try real_host.read(fd, &buffer);
        if (read_len == 0) break;
        try bytes.appendSlice(allocator, buffer[0..read_len]);
    }
    return bytes.toOwnedSlice(allocator);
}

test {
    std.testing.refAllDecls(@This());
}
