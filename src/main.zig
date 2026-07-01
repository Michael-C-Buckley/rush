//! Temporary executable facade for the shell rewrite.

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

pub const editor = @import("editor.zig");
pub const event_loop = @import("event_loop.zig");
pub const host = @import("host.zig");
pub const history = @import("history.zig");
pub const shell = @import("shell.zig");

const use_debug_allocator = builtin.mode == .Debug;
const AppDebugAllocator = if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void;
const default_config = @embedFile("default_config");
const usage =
    \\usage: rush [--login] [-i] [--posix]
    \\       rush [--posix] -c SCRIPT [NAME [ARGS...]]
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
        .interactive => |interactive| {
            var threaded_io: std.Io.Threaded = .init(root_allocator, .{
                .argv0 = .init(init.args),
                .environ = init.environ,
            });
            defer threaded_io.deinit();
            return runInteractive(process_allocator, real_host, threaded_io.io(), init.environ.block.view().slice, .{
                .state_options = interactive.options,
                .arg_zero = interactive.arg_zero,
                .positionals = &.{},
                .login = interactive.login,
            });
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

fn runInteractive(
    allocator: std.mem.Allocator,
    real_host: host.RealHost,
    io: std.Io,
    env: []const [*:0]const u8,
    options: EvalSourceOptions,
) !u8 {
    var sh = shell.Shell(host.RealHost).init(allocator, real_host, .{
        .state = options.state_options,
        .env = env,
        .arg_zero = options.arg_zero,
        .positionals = options.positionals,
    });
    defer sh.deinit();

    var source_id: shell.source.SourceId = 1;
    if (try sourceInteractiveStartup(&sh, &source_id, options.login)) |status| return status;

    var terminal = editor.driver.TerminalSession.init(allocator, io) catch {
        try sh.host.writeAll(.stderr, "rush: cannot initialize terminal\n");
        return 2;
    };
    defer terminal.deinit();

    while (true) {
        const line_result = terminal.readLine(.{ .prompt = prompt(&sh) }) catch {
            try sh.host.writeAll(.stderr, "rush: editor error\n");
            return 2;
        };
        switch (line_result) {
            .submitted => |line| {
                defer allocator.free(line);

                try terminal.leaveEditorMode();

                const src: shell.source.Source = .{
                    .id = source_id,
                    .kind = .interactive,
                    .name = "interactive",
                    .text = line,
                };
                source_id +%= 1;

                const evaluated = sh.evalSource(src) catch {
                    try sh.host.writeAll(.stderr, "rush: shell error\n");
                    terminal.finishSemanticCommand(2) catch {};
                    try terminal.enterEditorMode();
                    continue;
                };
                terminal.finishSemanticCommand(evaluated.status) catch {};

                switch (evaluated.flow) {
                    .exit => |status| return shell.eval.runExitTrap(&sh, status) catch {
                        try sh.host.writeAll(.stderr, "rush: shell error\n");
                        return 2;
                    },
                    else => try terminal.enterEditorMode(),
                }
            },
            .canceled, .interrupted => continue,
            .eof => {
                try terminal.leaveEditorMode();
                return shell.eval.runExitTrap(&sh, sh.state.last_status) catch {
                    try sh.host.writeAll(.stderr, "rush: shell error\n");
                    return 2;
                };
            },
        }
    }
}

fn sourceInteractiveStartup(
    sh: *shell.Shell(host.RealHost),
    source_id: *shell.source.SourceId,
    login: bool,
) !?u8 {
    if (try sourceStartupText(sh, source_id, "default_config", default_config)) |status| return status;

    if (envValue(sh.env, "ENV")) |env_path| {
        if (try sourceStartupFileIfExists(sh, source_id, env_path)) |status| return status;
    }

    if (login) {
        const system_profile = try std.fs.path.join(
            sh.allocator,
            &.{ build_config.sysconfdir, "rush", "profile.rush" },
        );
        defer sh.allocator.free(system_profile);
        if (try sourceStartupFileIfExists(sh, source_id, system_profile)) |status| return status;

        const user_profile = try userConfigPath(sh.allocator, sh.env, "profile.rush");
        defer if (user_profile) |path| sh.allocator.free(path);
        if (user_profile) |path| {
            if (try sourceStartupFileIfExists(sh, source_id, path)) |status| return status;
        }
    }

    const system_config = try std.fs.path.join(sh.allocator, &.{ build_config.sysconfdir, "rush", "config.rush" });
    defer sh.allocator.free(system_config);
    if (try sourceStartupFileIfExists(sh, source_id, system_config)) |status| return status;

    const user_config = try userConfigPath(sh.allocator, sh.env, "config.rush");
    defer if (user_config) |path| sh.allocator.free(path);
    if (user_config) |path| {
        if (try sourceStartupFileIfExists(sh, source_id, path)) |status| return status;
    }

    return null;
}

fn sourceStartupFileIfExists(
    sh: *shell.Shell(host.RealHost),
    source_id: *shell.source.SourceId,
    path: []const u8,
) !?u8 {
    const path_z = try sh.allocator.dupeZ(u8, path);
    defer sh.allocator.free(path_z);
    if (!sh.host.fileAccessZ(path_z, .read)) return null;

    const text = readFileAlloc(sh.allocator, &sh.host, path) catch {
        const message = try std.fmt.allocPrint(sh.scratchAllocator(), "rush: cannot read {s}\n", .{path});
        try sh.host.writeAll(.stderr, message);
        return null;
    };
    defer sh.allocator.free(text);
    return sourceStartupText(sh, source_id, path, text);
}

fn sourceStartupText(
    sh: *shell.Shell(host.RealHost),
    source_id: *shell.source.SourceId,
    name: []const u8,
    text: []const u8,
) !?u8 {
    const src: shell.source.Source = .{
        .id = source_id.*,
        .kind = .sourced_file,
        .name = name,
        .text = text,
    };
    source_id.* +%= 1;

    const evaluated = sh.evalSource(src) catch {
        const message = try std.fmt.allocPrint(sh.scratchAllocator(), "rush: error while sourcing {s}\n", .{name});
        try sh.host.writeAll(.stderr, message);
        return null;
    };
    return switch (evaluated.flow) {
        .exit => |status| shell.eval.runExitTrap(sh, status) catch 2,
        else => null,
    };
}

fn userConfigPath(allocator: std.mem.Allocator, env: []const [*:0]const u8, file_name: []const u8) !?[]const u8 {
    if (envValue(env, "XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home, "rush", file_name });
    }

    const home = envValue(env, "HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home, ".config", "rush", file_name });
}

fn prompt(sh: *shell.Shell(host.RealHost)) []const u8 {
    if (sh.state.getVariable("PS1")) |variable| return variable.value;
    if (envValue(sh.env, "PS1")) |value| return value;
    return "rush> ";
}

fn envValue(env: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len != 0);
    for (env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

const EvalSourceOptions = struct {
    state_options: shell.state.Options,
    arg_zero: []const u8,
    positionals: []const []const u8,
    login: bool = false,
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
