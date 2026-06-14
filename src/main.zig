//! Application entry point.

const std = @import("std");

pub const compat = @import("shell/compat.zig");
pub const parser = @import("shell/parser.zig");
pub const expand = @import("shell/expand.zig");
pub const ir = @import("shell/ir.zig");
pub const history = @import("history.zig");
pub const cli_invocation = @import("invocation.zig");
pub const interactive = @import("interactive.zig");
pub const shell = @import("shell.zig");
pub const runner = @import("runner.zig");
pub const runtime = @import("runtime.zig");
pub const line_editor = @import("line_editor.zig");
pub const editor_driver = @import("editor_driver.zig");
pub const event_loop = @import("event_loop.zig");

const usage =
    \\usage: rush [--login]
    \\       rush [-i] [--posix-strict] [set-options]
    \\       rush [-i] [--posix-strict] [set-options] -c SCRIPT [NAME [ARGS...]]
    \\       rush [-i] [--posix-strict] [set-options] -s [ARGS...]
    \\       rush [-i] [--posix-strict] [set-options] SCRIPT_FILE [ARGS...]
    \\       rush --help
    \\
;

pub const CommandResult = runner.CommandResult;
const RunOptions = runner.Options;

const ShellInvocation = cli_invocation.ShellInvocation;
const parseShellInvocation = cli_invocation.parse;
const shouldRunInteractiveStandardInput = cli_invocation.shouldRunInteractiveStandardInput;
const isLoginArgZero = cli_invocation.isLoginArgZero;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const login_shell = isLoginArgZero(args[0]);

    if (args.len == 1 and stdinIsTty(init.io)) {
        return runInteractive(allocator, init.io, init.environ_map, .{ .arg_zero = args[0], .login = login_shell });
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--login")) {
        return runInteractive(allocator, init.io, init.environ_map, .{ .arg_zero = args[0], .login = true });
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try writeAll(init.io, .stdout, usage);
        return 0;
    }

    const invocation: ShellInvocation = if (args.len == 1) .{
        .kind = .standard_input,
        .source = "-",
        .arg_zero = args[0],
    } else parseShellInvocation(args) orelse {
        try writeAll(init.io, .stderr, usage);
        return 2;
    };

    if (shouldRunInteractiveStandardInput(invocation, stdinIsTty(init.io), stderrIsTty(init.io))) {
        return runInteractive(allocator, init.io, init.environ_map, .{
            .arg_zero = invocation.arg_zero,
            .login = login_shell,
            .features = invocation.features,
            .shell_options = invocation.shell_options,
            .monitor_option_explicit = invocation.monitor_option_explicit,
            .positionals = invocation.positionals,
        });
    }

    var result = runShellInvocationWithEnvironment(allocator, init.io, invocation, init.environ_map, .inherit, login_shell) catch |err| switch (err) {
        error.FileNotFound => {
            try writeScriptReadError(init.io, invocation.source, "file not found");
            return 2;
        },
        error.AccessDenied, error.PermissionDenied => {
            try writeScriptReadError(init.io, invocation.source, "permission denied");
            return 2;
        },
        error.IsDir => {
            try writeScriptReadError(init.io, invocation.source, "is a directory");
            return 2;
        },
        else => |e| return e,
    };
    defer result.deinit();

    try writeAll(init.io, .stdout, result.stdout);
    try writeAll(init.io, .stderr, result.stderr);
    return result.status;
}

const InteractiveOptions = interactive.startup.Options;

pub fn runInteractive(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !u8 {
    return interactive.session.run(allocator, io, environ_map, options);
}

pub fn runReplInput(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !CommandResult {
    return interactive.session.runReplInput(allocator, io, input);
}

pub fn runScript(allocator: std.mem.Allocator, io: std.Io, script: []const u8) !CommandResult {
    return runner.runScript(allocator, io, script);
}

pub fn runScriptWithOptions(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions) !CommandResult {
    return runner.runScriptWithOptions(allocator, io, script, options);
}

pub fn runScriptWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions, environ_map: ?*const std.process.Environ.Map) !CommandResult {
    return runner.runScriptWithEnvironment(allocator, io, script, options, environ_map);
}

fn runShellInvocationWithEnvironment(allocator: std.mem.Allocator, io: std.Io, invocation: ShellInvocation, environ_map: ?*const std.process.Environ.Map, external_stdio: runtime.ExternalStdio, login_shell: bool) !CommandResult {
    var loaded_script = try runner.loadInvocationScript(allocator, io, invocation, external_stdio);
    defer loaded_script.deinit();
    const interactive_options: ?InteractiveOptions = if (invocation.interactive) .{
        .arg_zero = invocation.arg_zero,
        .login = login_shell,
        .features = invocation.features,
        .shell_options = invocation.shell_options,
        .monitor_option_explicit = invocation.monitor_option_explicit,
        .positionals = invocation.positionals,
    } else null;
    return runCommandStringWithEnvironment(allocator, io, loaded_script.script, loaded_script.options, environ_map, invocation.positionals, interactive_options, invocation.shell_options);
}

fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

fn stderrIsTty(io: std.Io) bool {
    return std.Io.File.stderr().isTty(io) catch false;
}

fn runCommandStringWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, interactive_options: ?InteractiveOptions, shell_options: shell.ShellOptions) !CommandResult {
    if (interactive_options) |startup_options| {
        return interactive.session.runCommandStringWithEnvironment(allocator, io, script, options, environ_map, positionals, startup_options, shell_options);
    }
    return runner.runCommandStringWithEnvironment(allocator, io, script, options, environ_map, positionals, shell_options);
}

const OutputStream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: OutputStream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeScriptReadError(io: std.Io, path: []const u8, message: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print("rush: cannot open {s}: {s}\n", .{ path, message });
}

test {
    std.testing.refAllDecls(compat);
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(expand);
    std.testing.refAllDecls(ir);
    std.testing.refAllDecls(history);
    std.testing.refAllDecls(cli_invocation);
    std.testing.refAllDecls(interactive);
    std.testing.refAllDecls(shell);
    std.testing.refAllDecls(runner);
    std.testing.refAllDecls(runtime);
    std.testing.refAllDecls(line_editor);
    std.testing.refAllDecls(editor_driver);
}
