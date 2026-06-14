//! Application entry point.

const std = @import("std");

extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;

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

const InvocationKind = cli_invocation.Kind;
const ShellInvocation = cli_invocation.ShellInvocation;
const parseCommandStringInvocation = cli_invocation.parseCommandString;
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
const InteractiveShell = interactive.session.Shell;
const InteractiveContext = interactive.session.Context;
const SemanticInvocationExecution = runner.SemanticInvocationExecution;
const immediate_notify_poll_ms = interactive.session.immediate_notify_poll_ms;
const runInteractiveIntervalHooks = interactive.session.runInteractiveIntervalHooks;
const nextInteractiveIntervalMs = interactive.session.nextInteractiveIntervalMs;
const runInteractiveInterruptTrap = interactive.session.runInteractiveInterruptTrap;

pub fn runInteractive(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !u8 {
    return interactive.session.run(allocator, io, environ_map, options);
}

pub fn runReplInput(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !CommandResult {
    return interactive.session.runReplInput(allocator, io, input);
}

fn runInteractiveScript(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *InteractiveShell, script: []const u8, options: RunOptions) !CommandResult {
    std.debug.assert(options.interactive);
    if (interactive_shell.semantic_enabled) {
        var semantic_execution = try runSemanticInteractiveCommandString(allocator, io, interactive_shell, script, runner.invocationContext(options), options.external_stdio);
        switch (semantic_execution) {
            .output => |output| {
                semantic_execution = undefined;
                return output;
            },
            .unsupported => |message| {
                semantic_execution = undefined;
                defer allocator.free(message);
                return runner.unsupported(allocator, message);
            },
        }
    }

    return runner.unsupported(allocator, "semantic interactive executor is disabled while legacy interactive services are active");
}

fn runSemanticInteractiveCommandString(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *InteractiveShell, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    std.debug.assert(interactive_shell.semantic_enabled);
    return runner.runInteractiveCommandString(allocator, io, &interactive_shell.semantic_state, script, invocation, external_stdio);
}

fn loadInteractiveConfig(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, options: InteractiveOptions) !void {
    try interactive.startup.loadConfig(allocator, io, shell_state, options);
}

fn sourceConfigScript(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, contents: []const u8, source_path: []const u8, arg_zero: []const u8) !void {
    try interactive.startup.sourceConfigScript(allocator, io, shell_state, contents, source_path, arg_zero);
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

const StdinGuard = struct {
    saved_fd: c_int,

    fn replaceWith(file: std.Io.File) !StdinGuard {
        const saved_fd = dup(std.Io.File.stdin().handle);
        if (saved_fd < 0) return error.SkipZigTest;
        errdefer _ = close(saved_fd);
        if (dup2(file.handle, std.Io.File.stdin().handle) < 0) return error.SkipZigTest;
        return .{ .saved_fd = saved_fd };
    }

    fn restore(self: *StdinGuard) void {
        _ = dup2(self.saved_fd, std.Io.File.stdin().handle);
        _ = close(self.saved_fd);
        self.* = undefined;
    }
};

const StderrGuard = struct {
    saved_fd: c_int,

    fn replaceWith(file: std.Io.File) !StderrGuard {
        const saved_fd = dup(std.Io.File.stderr().handle);
        if (saved_fd < 0) return error.SkipZigTest;
        errdefer _ = close(saved_fd);
        if (dup2(file.handle, std.Io.File.stderr().handle) < 0) return error.SkipZigTest;
        return .{ .saved_fd = saved_fd };
    }

    fn restore(self: *StderrGuard) void {
        _ = dup2(self.saved_fd, std.Io.File.stderr().handle);
        _ = close(self.saved_fd);
        self.* = undefined;
    }
};

fn runInvocationWithPipeStdin(invocation: ShellInvocation, stdin: []const u8) !CommandResult {
    var pipe = try editor_driver.makePipe(std.testing.io);
    defer pipe.read.close(std.testing.io);
    var write_open = true;
    defer if (write_open) pipe.write.close(std.testing.io);

    try writeFileAll(pipe.write, stdin);
    pipe.write.close(std.testing.io);
    write_open = false;

    var guard = try StdinGuard.replaceWith(pipe.read);
    defer guard.restore();
    return runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
}

fn runInvocationWithFileStdin(invocation: ShellInvocation, path: []const u8) !CommandResult {
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var guard = try StdinGuard.replaceWith(file);
    defer guard.restore();
    return runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
}

fn writeFileAll(file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
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

fn runSemanticCommandString(allocator: std.mem.Allocator, io: std.Io, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !SemanticInvocationExecution {
    return runner.runSemanticCommandString(allocator, io, script, invocation, external_stdio, environ_map, positionals, shell_options);
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

test "interactive highlight renderer uses parser classifications" {
    const rendered = try interactive.input.renderHighlighted(std.testing.allocator, "echo hi > out # comment");
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[36mecho\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[35m>\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[32m# comment\x1b[0m") != null);
}

test "runReplInput executes lines and tracks status" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "echo hi\nfalse\nexit\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("$ hi\n$ $ ", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive notify schedules editor job notification polling" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var context: InteractiveContext = .{ .semantic_state = &shell_state };

    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
    try shell_state.appendJobNotification(.{ .job_id = 1, .state = .done, .command = "sleep 1" });
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));

    shell_state.options.notify = true;
    try std.testing.expectEqual(@as(?u64, immediate_notify_poll_ms), try nextInteractiveIntervalMs(&context, std.testing.io));

    shell_state.consumeJobNotifications(1);
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
}

test "interactive semantic job notifications drain from ShellState" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.notify = true;
    try shell_state.appendJobNotification(.{ .job_id = 1, .state = .done, .command = "sleep 1" });

    var context: InteractiveContext = .{ .semantic_state = &shell_state };

    try std.testing.expectEqual(@as(?u64, immediate_notify_poll_ms), try nextInteractiveIntervalMs(&context, std.testing.io));
    const hook_result = try runInteractiveIntervalHooks(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("[1] Done sleep 1\n", hook_result.output);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_job_notifications.items.len);
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
}

test "interactive hooks dispatch pending semantic signal trap" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.TERM, "echo term-trap");
    try shell_state.appendPendingTrap(.TERM);

    var context: InteractiveContext = .{ .semantic_state = &shell_state };

    const hook_result = try runInteractiveIntervalHooks(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("term-trap\n", hook_result.output);
    try std.testing.expect(hook_result.refresh_prompt);
    try std.testing.expect(!hook_result.stop);
}

test "interactive interrupt runs INT trap" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.INT, "echo trapped");

    var result = (try runInteractiveInterruptTrap(std.testing.allocator, std.testing.io, &shell_state, "rush", .{})) orelse return error.MissingTrapResult;
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("trapped\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string operands set the command name and positional parameters" {
    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo $0:$#:$1:$2; echo \"$@\"",
        .{ .io = std.testing.io, .arg_zero = "myname" },
        null,
        &.{ "a", "b c" },
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("myname:2:a:b c\na b c\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string invocation preserves trailing EOF backslash literal" {
    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo a\\",
        .{ .io = std.testing.io, .arg_zero = "rush" },
        null,
        &.{},
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\\\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "script file invocation sets command name and positional parameters" {
    const path = "rush-script-invocation-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\#!/usr/bin/env rush
        \\# first-line comments and shebangs are shell comments
        \\alias say='echo'
        \\read value <<EOF
        \\$2
        \\EOF
        \\say "$0:$#:$1:$value"
    });

    const invocation = parseShellInvocation(&.{ "rush", path, "arg one", "two words" }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush-script-invocation-test.rush:2:arg one:two words\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "script file invocation preserves trailing EOF backslash without final newline" {
    const path = "rush-script-trailing-backslash-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "echo a\\" });

    const invocation = parseShellInvocation(&.{ "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\\\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "script file invocation shell options affect execution" {
    const path = "rush-script-options-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\false
        \\echo unreached
    });

    const invocation = parseShellInvocation(&.{ "rush", "-e", path }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input invocation accepts -s operands and shell options" {
    const invocation = parseShellInvocation(&.{ "rush", "-e", "-s", "posarg", "two words" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(InvocationKind.standard_input, invocation.kind);
    try std.testing.expectEqualStrings("-", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("posarg", invocation.positionals[0]);
    try std.testing.expectEqualStrings("two words", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo $0:$#:$1:$2",
        .{ .io = std.testing.io, .arg_zero = invocation.arg_zero },
        null,
        invocation.positionals,
        null,
        invocation.shell_options,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush:2:posarg:two words\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input invocation is the default when only invocation options are present" {
    const invocation = parseShellInvocation(&.{ "rush", "--posix-strict", "-u" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(InvocationKind.standard_input, invocation.kind);
    try std.testing.expectEqualStrings("-", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 0), invocation.positionals.len);
    try std.testing.expect(invocation.features.strict_diagnostics);
    try std.testing.expect(invocation.shell_options.nounset);
}

test "interactive invocation tracks explicit monitor option" {
    const enabled = parseShellInvocation(&.{ "rush", "-im", "-c", "jobs" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(enabled.interactive);
    try std.testing.expect(enabled.shell_options.monitor);
    try std.testing.expect(enabled.monitor_option_explicit);

    const disabled = parseShellInvocation(&.{ "rush", "+m", "-i" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(disabled.interactive);
    try std.testing.expect(!disabled.shell_options.monitor);
    try std.testing.expect(disabled.monitor_option_explicit);
}

test "standard input invocation uses interactive editor when terminal rules require it" {
    const forced = parseShellInvocation(&.{ "rush", "-i" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(shouldRunInteractiveStandardInput(forced, true, false));
    try std.testing.expect(!shouldRunInteractiveStandardInput(forced, false, true));

    const implicit = parseShellInvocation(&.{ "rush", "--posix-strict", "-u" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(shouldRunInteractiveStandardInput(implicit, true, true));
    try std.testing.expect(!shouldRunInteractiveStandardInput(implicit, true, false));

    const command = parseShellInvocation(&.{ "rush", "-i", "-c", "exit" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(!shouldRunInteractiveStandardInput(command, true, true));
}

test "command string invocation shell options affect execution" {
    const errexit_invocation = parseCommandStringInvocation(&.{ "rush", "-e", "-c", "false; echo unreached" }) orelse return error.ExpectedInvocation;
    var errexit = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        errexit_invocation.source,
        .{ .io = std.testing.io, .arg_zero = errexit_invocation.arg_zero },
        null,
        errexit_invocation.positionals,
        null,
        errexit_invocation.shell_options,
    );
    defer errexit.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), errexit.status);
    try std.testing.expectEqualStrings("", errexit.stdout);
    try std.testing.expectEqualStrings("", errexit.stderr);

    const clustered_errexit_invocation = parseCommandStringInvocation(&.{ "rush", "-ec", "false; echo unreached" }) orelse return error.ExpectedInvocation;
    var clustered_errexit = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        clustered_errexit_invocation.source,
        .{ .io = std.testing.io, .arg_zero = clustered_errexit_invocation.arg_zero },
        null,
        clustered_errexit_invocation.positionals,
        null,
        clustered_errexit_invocation.shell_options,
    );
    defer clustered_errexit.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), clustered_errexit.status);
    try std.testing.expectEqualStrings("", clustered_errexit.stdout);
    try std.testing.expectEqualStrings("", clustered_errexit.stderr);

    const option_after_c_invocation = parseCommandStringInvocation(&.{ "rush", "-c", "-e", "false; echo unreached" }) orelse return error.ExpectedInvocation;
    var option_after_c = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        option_after_c_invocation.source,
        .{ .io = std.testing.io, .arg_zero = option_after_c_invocation.arg_zero },
        null,
        option_after_c_invocation.positionals,
        null,
        option_after_c_invocation.shell_options,
    );
    defer option_after_c.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), option_after_c.status);
    try std.testing.expectEqualStrings("", option_after_c.stdout);
    try std.testing.expectEqualStrings("", option_after_c.stderr);

    const nounset_invocation = parseCommandStringInvocation(&.{ "rush", "-o", "nounset", "-c", "echo $RUSH_INVOCATION_UNSET_FOR_TEST_416; echo unreached" }) orelse return error.ExpectedInvocation;
    var nounset = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        nounset_invocation.source,
        .{ .io = std.testing.io, .arg_zero = nounset_invocation.arg_zero },
        null,
        nounset_invocation.positionals,
        null,
        nounset_invocation.shell_options,
    );
    defer nounset.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), nounset.status);
    try std.testing.expectEqualStrings("", nounset.stdout);
    try std.testing.expect(std.mem.indexOf(u8, nounset.stderr, "parameter not set") != null);

    const flags_invocation = parseCommandStringInvocation(&.{ "rush", "-bem", "-o", "nounset", "-c", "printf '<%s>\\n' \"$-\"" }) orelse return error.ExpectedInvocation;
    var flags = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        flags_invocation.source,
        .{ .io = std.testing.io, .arg_zero = flags_invocation.arg_zero },
        null,
        flags_invocation.positionals,
        null,
        flags_invocation.shell_options,
    );
    defer flags.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), flags.status);
    try std.testing.expectEqualStrings("<bemu>\n", flags.stdout);
    try std.testing.expectEqualStrings("", flags.stderr);

    const noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "echo unreached" }) orelse return error.ExpectedInvocation;
    var no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = noexec_invocation.arg_zero },
        null,
        noexec_invocation.positionals,
        null,
        noexec_invocation.shell_options,
    );
    defer no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), no_execute.status);
    try std.testing.expectEqualStrings("", no_execute.stdout);
    try std.testing.expect(no_execute.stderr.len != 0);

    const invalid_noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "x=for; $x i in 1; do echo $i; done" }) orelse return error.ExpectedInvocation;
    var invalid_no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_noexec_invocation.arg_zero },
        null,
        invalid_noexec_invocation.positionals,
        null,
        invalid_noexec_invocation.shell_options,
    );
    defer invalid_no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_no_execute.status);
    try std.testing.expectEqualStrings("", invalid_no_execute.stdout);
    try std.testing.expect(invalid_no_execute.stderr.len != 0);

    const invalid_elif_noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "if false; then :; elif true; fi" }) orelse return error.ExpectedInvocation;
    var invalid_elif_no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_elif_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_elif_noexec_invocation.arg_zero },
        null,
        invalid_elif_noexec_invocation.positionals,
        null,
        invalid_elif_noexec_invocation.shell_options,
    );
    defer invalid_elif_no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_elif_no_execute.status);
    try std.testing.expectEqualStrings("", invalid_elif_no_execute.stdout);
    try std.testing.expect(invalid_elif_no_execute.stderr.len != 0);
}

test "command string set -v does not echo already-read input" {
    const invocation = parseShellInvocation(&.{ "rush", "-c", "set -v\necho command-string-verbose" }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("command-string-verbose\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string read consumes piped real stdin" {
    const invocation = parseShellInvocation(&.{ "rush", "-c", "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"" }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "pipe value\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[pipe value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string read consumes file real stdin" {
    const path = "rush-command-string-read-stdin.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "file value\n" });

    const invocation = parseShellInvocation(&.{ "rush", "-c", "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"" }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithFileStdin(invocation, path);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[file value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string read keeps explicit stdin redirection precedence" {
    const path = "rush-command-string-read-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "redirected value\n" });

    const invocation = parseShellInvocation(&.{ "rush", "-c", "read x < \"$1\"; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"", "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "real stdin value\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[redirected value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input script source still leaves read at EOF" {
    const invocation = parseShellInvocation(&.{"rush"}) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[] status=1\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input file script skips lines consumed by read" {
    const path = "rush-stdin-script-seek-read.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "read x\nprintf 'x=[%s]\\n' \"$x\"\nprintf 'after\\n'\n" });

    const invocation = parseShellInvocation(&.{"rush"}) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithFileStdin(invocation, path);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("after\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "invalid arithmetic expansion returns a shell diagnostic" {
    const cases = [_][]const u8{
        "echo $((2 ** 3)); echo after",
        "echo $((\"1\" + 2)); echo after",
    };

    for (cases) |script| {
        var result = try runScript(std.testing.allocator, std.testing.io, script);
        defer result.deinit();

        try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "invalid arithmetic expression") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "after") == null);
    }
}

test "runScriptWithEnvironment imports initial shell variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "present");
    try env.put("IFS", ":");
    try env.put("OPTIND", "7");
    try env.put("PWD", "/definitely/not/rush/current/directory");

    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
        \\case $PPID in ''|*[!0123456789]*) echo bad-ppid ;; *) echo ppid-ok ;; esac
        \\printf '<%s>\n' "$RUSH_IMPORTED_ENV" "$IFS" "$OPTIND"
        \\case $PWD in /definitely/not/rush/*) echo bad-pwd ;; /*) echo pwd-ok ;; *) echo bad-pwd ;; esac
    , .{ .io = std.testing.io, .allow_external = true }, &env);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ppid-ok\n<present>\n< \t\n>\n<1>\npwd-ok\n", result.stdout);
}

test "semantic interactive command updates executor status for later commands" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var false_result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "false", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer false_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 1), false_result.status);
    try std.testing.expectEqualStrings("", false_result.stdout);
    try std.testing.expectEqualStrings("", false_result.stderr);
    try std.testing.expectEqual(@as(shell.ExitStatus, 1), interactive_shell.semantic_state.last_status);

    var status_result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "echo $?", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer status_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), status_result.status);
    try std.testing.expectEqualStrings("1\n", status_result.stdout);
    try std.testing.expectEqualStrings("", status_result.stderr);
}

test "semantic interactive shell state persists variable mutations without legacy execution" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var assign = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "RUSH_INTERACTIVE_SEMANTIC=state", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer assign.deinit(std.testing.allocator);
    switch (assign) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expectEqualStrings("state", interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_SEMANTIC").?.value);

    var readback = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "printf '%s\n' \"$RUSH_INTERACTIVE_SEMANTIC\"", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer readback.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), readback.status);
    try std.testing.expectEqualStrings("state\n", readback.stdout);
    try std.testing.expectEqualStrings("", readback.stderr);
}

test "semantic interactive assignment-bearing commands preserve assignment lifetime without legacy fallback" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var temporary = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "RUSH_INTERACTIVE_TEMPORARY=discarded true", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer temporary.deinit(std.testing.allocator);
    switch (temporary) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expect(interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_TEMPORARY") == null);

    var persistent = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "RUSH_INTERACTIVE_SPECIAL=persistent :", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer persistent.deinit(std.testing.allocator);
    switch (persistent) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expectEqualStrings("persistent", interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_SPECIAL").?.value);
}

test "semantic interactive external commands run through runtime ports without legacy fallback" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var external = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "/usr/bin/printf 'semantic-external\\n'", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .capture);
    defer external.deinit(std.testing.allocator);
    switch (external) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |output| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status);
            try std.testing.expectEqualStrings("semantic-external\n", output.stdout);
            try std.testing.expectEqualStrings("", output.stderr);
        },
    }
}

test "semantic interactive startup initializes ShellState without executor shell variables as source" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_INTERACTIVE_IMPORTED", "present");
    try env.put("SHLVL", "2");

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{
        .arg_zero = "rush",
        .positionals = &.{ "one", "two" },
        .shell_options = .{ .ignoreeof = true },
    });
    try std.testing.expect(interactive_shell.semantic_enabled);
    try std.testing.expectEqualStrings("present", interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_IMPORTED").?.value);
    try std.testing.expectEqualStrings("3", interactive_shell.semantic_state.getVariable("SHLVL").?.value);
    try std.testing.expectEqualStrings(" \t\n", interactive_shell.semantic_state.getVariable("IFS").?.value);
    try std.testing.expectEqualStrings("1", interactive_shell.semantic_state.getVariable("OPTIND").?.value);
    try std.testing.expect(interactive_shell.semantic_state.options.ignoreeof);
    try std.testing.expectEqual(@as(usize, 2), interactive_shell.semantic_state.positionals.items.len);
    try std.testing.expectEqualStrings("one", interactive_shell.semantic_state.positionals.items[0]);
    try std.testing.expectEqualStrings("two", interactive_shell.semantic_state.positionals.items[1]);
}

test "interactive config service sources simple config through semantic ShellState" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });
    try sourceConfigScript(std.testing.allocator, std.testing.io, &interactive_shell.semantic_state,
        \\RUSH_SEMANTIC_CONFIG=loaded
        \\RUSH_SEMANTIC_CONFIG_SECOND=ok
    , "semantic-config-test.rush", "rush");
    try std.testing.expectEqualStrings("loaded", interactive_shell.semantic_state.getVariable("RUSH_SEMANTIC_CONFIG").?.value);
    try std.testing.expectEqualStrings("ok", interactive_shell.semantic_state.getVariable("RUSH_SEMANTIC_CONFIG_SECOND").?.value);
}

test "semantic interactive invocation executes simple command redirections without legacy fallback" {
    const path = "rush-semantic-interactive-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var semantic = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "echo before > " ++ path ++ "; echo redirected >> " ++ path, shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer semantic.deinit(std.testing.allocator);
    switch (semantic) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("before\nredirected\n", output);
}

test "semantic non-interactive invocation initializes environment arg zero and positionals" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "semantic");
    try env.put("SHLVL", "5");

    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "printf '<%s>\n' \"$0\" \"$#\" \"$1\" \"$RUSH_IMPORTED_ENV\" \"$IFS\" \"$OPTIND\" \"$SHLVL\"",
        shell.InvocationContext.init(.{ .arg_zero = "semantic-rush" }),
        .inherit,
        &env,
        &.{"positional"},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("<semantic-rush>\n<1>\n<positional>\n<semantic>\n< \t\n>\n<1>\n<6>\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation executes foreground simple pipelines" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\printf 'pipe:%s\n' value | /bin/cat
        \\false | true
        \\printf 'status:%s\n' "$?"
        \\! false
        \\printf 'negated:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("pipe:value\nstatus:0\nnegated:0\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation lowers function bodies at call time" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\func() { printf 'call:%s:%s\n' "$1" "$#"; }
        \\func first second
        \\outer() { inner() { printf 'same-list:%s\n' "$1"; }; inner nested; }
        \\outer
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("call:first:2\nsame-list:nested\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation lowers function for bodies per iteration" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\h() for i in 1 2; do echo f$i; done
        \\h
        \\show() { for x in "$@"; do echo "<$x>"; done; }
        \\show "a b" c ""
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("f1\nf2\n<a b>\n<c>\n<>\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation executes function calls in pipelines with subshell isolation" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\pipe_fn() { printf 'pipe:%s\n' "$1"; }
        \\pipe_fn value | /bin/cat
        \\maker() { made() { printf 'bad\n'; }; }
        \\maker | /bin/cat
        \\made
        \\printf 'missing:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("pipe:value\nmissing:127\n", result.stdout);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "made: command not found") != null);
        },
    }
}

test "semantic parser lowering plans compound pipeline stages" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = shell.eval.Evaluator.init(std.testing.allocator);
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    const resolver = parser_resolver.resolver();

    var body = (try resolver.resolve(
        std.testing.allocator,
        "{ printf 'left\n'; } | printf 'right\n'",
        .TERM,
        shell.EvalContext.forTarget(.current_shell),
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const plan = switch (body) {
        .owned => |owned| switch (owned.body) {
            .pipeline => |plan| plan,
            else => return error.ExpectedPipelinePlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };

    try std.testing.expectEqual(@as(usize, 2), plan.stages.len);
    switch (plan.stages[0]) {
        .compound => |compound| try std.testing.expectEqualStrings("brace group", compound.kindName()),
        .simple => return error.ExpectedCompoundPipelineStage,
    }
    switch (plan.stages[1]) {
        .simple => {},
        .compound => return error.ExpectedSimplePipelineStage,
    }
}

test "semantic non-interactive invocation executes compound pipeline stages" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\{ printf 'brace\n'; } | /bin/cat
        \\( printf 'subshell\n' ) | /bin/cat
        \\if true; then printf 'if\n'; fi | /bin/cat
        \\while true; do printf 'while\n'; break; done | /bin/cat
        \\for item in loop; do printf 'for\n'; break; done | /bin/cat
        \\case x in x) printf 'case\n' ;; esac | /bin/cat
        \\! { false; }
        \\printf 'negated-compound:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("brace\nsubshell\nif\nwhile\nfor\ncase\nnegated-compound:0\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

fn expectBackgroundStatusAndPidLine(prefix: []const u8, line: []const u8) !void {
    var fields = std.mem.splitScalar(u8, line, ':');
    try std.testing.expectEqualStrings(prefix, fields.next() orelse return error.ExpectedBackgroundLinePrefix);
    try std.testing.expectEqualStrings("0", fields.next() orelse return error.ExpectedBackgroundStatus);
    const pid_text = fields.next() orelse return error.ExpectedBackgroundPid;
    try std.testing.expect(fields.next() == null);
    const pid = try std.fmt.parseUnsigned(usize, pid_text, 10);
    try std.testing.expect(pid != 0);
}

test "semantic non-interactive invocation executes simple command redirections" {
    const path = "rush-semantic-simple-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "echo redirected > " ++ path,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("redirected\n", output);
}

test "semantic non-interactive invocation executes formerly gated production pipeline shapes" {
    const path = "rush-semantic-compound-stage.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var redirected_compound_stage = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "{ printf 'compound\n'; } > " ++ path ++ " | /bin/cat",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer redirected_compound_stage.deinit(std.testing.allocator);
    switch (redirected_compound_stage) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const file_output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file_output);
    try std.testing.expectEqualStrings("compound\n", file_output);

    var dynamic_compound_stage = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "{ printf \"$(printf dynamic)\\n\"; } | /bin/cat",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer dynamic_compound_stage.deinit(std.testing.allocator);
    switch (dynamic_compound_stage) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("dynamic\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "runScriptWithEnvironment initializes and exports SHLVL" {
    const ShellLevelCase = struct {
        inherited: ?[]const u8,
        expected: []const u8,
    };
    const cases = [_]ShellLevelCase{
        .{ .inherited = null, .expected = "1" },
        .{ .inherited = "5", .expected = "6" },
        .{ .inherited = "not-a-number", .expected = "1" },
    };

    for (cases) |case| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        if (case.inherited) |level| try env.put("SHLVL", level);

        var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
            \\printf '<%s>\n' "$SHLVL"
            \\env
        , .{ .io = std.testing.io, .allow_external = true }, &env);
        defer result.deinit();

        const expected = try std.fmt.allocPrint(std.testing.allocator, "<{s}>\n", .{case.expected});
        defer std.testing.allocator.free(expected);
        const exported = try std.fmt.allocPrint(std.testing.allocator, "\nSHLVL={s}\n", .{case.expected});
        defer std.testing.allocator.free(exported);
        try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, expected));
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, exported) != null);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "runScriptWithEnvironment exports PWD and OLDPWD after cd" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "target" });
    defer std.testing.allocator.free(target_path);

    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\unset PWD OLDPWD
        \\cd "{s}"
        \\env
    , .{target_path});
    defer std.testing.allocator.free(script);
    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io, script, .{ .io = std.testing.io, .allow_external = true }, null);
    defer result.deinit();

    const pwd_line = try std.fmt.allocPrint(std.testing.allocator, "PWD={s}\n", .{target_path});
    defer std.testing.allocator.free(pwd_line);
    const oldpwd_line = try std.fmt.allocPrint(std.testing.allocator, "OLDPWD={s}\n", .{original_cwd});
    defer std.testing.allocator.free(oldpwd_line);

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, pwd_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, oldpwd_line) != null);
}

test "POSIX mode reports misplaced reserved words" {
    var bare = try runScript(std.testing.allocator, std.testing.io, "then echo bad");
    defer bare.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), bare.status);
    try std.testing.expectEqualStrings("", bare.stdout);
    try std.testing.expect(std.mem.indexOf(u8, bare.stderr, "misplaced reserved word") != null);

    var expanded = try runScript(std.testing.allocator, std.testing.io, "x=for; $x i in 1");
    defer expanded.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 127), expanded.status);
    try std.testing.expect(std.mem.indexOf(u8, expanded.stderr, "for: command not found") != null);

    const alias_script =
        \\alias then='echo bad'
        \\then
    ;
    var alias_result = try runScript(std.testing.allocator, std.testing.io, alias_script);
    defer alias_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), alias_result.status);
    try std.testing.expectEqualStrings("", alias_result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, alias_result.stderr, "misplaced reserved word") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_result.stderr, "bad\n") == null);
}

test "runScript returns parse diagnostics" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo | ");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing command after pipeline operator") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "echo | ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "     ^") != null);
}

test "runScript executes newline-continued pipeline" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\echo before
        \\echo |
        \\echo after
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("before\nafter\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution preserves semantic builtin state and sequencing" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\VALUE=new
        \\printf 'semantic %s\n' shell
        \\printf '%s\n' "$VALUE"
        \\false && printf 'bad-and\n'
        \\true || printf 'bad-or\n'
        \\printf 'after\n'
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("semantic shell\nnew\nafter\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution handles deterministic builtin pipeline" {
    var result = try runScript(std.testing.allocator, std.testing.io, "printf 'pipe-value\n' | /bin/cat");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("pipe-value\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution handles compound pipeline stage" {
    var result = try runScript(std.testing.allocator, std.testing.io, "{ printf 'compound-value\n'; } | /bin/cat");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("compound-value\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution handles pipeline function call" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\fn() { printf 'compare:%s\n' "$1"; }
        \\fn value | read VALUE
        \\printf 'status:%s value:%s\n' "$?" "$VALUE"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("status:0 value:\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScript reports misplaced reserved words before execution" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\echo before
        \\then
        \\echo after
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "misplaced reserved word") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "echo after") == null);
}

test "non-interactive aliases affect later complete commands" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo script-alias-ok'
        \\say
        \\if true; then echo compound-ok; fi
        \\alias prefix='say '
        \\alias word='trailing-ok'
        \\prefix word
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("script-alias-ok\ncompound-ok\nscript-alias-ok trailing-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "chunked alias scripts run EXIT trap once" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\trap 'echo bye' EXIT
        \\alias say='echo body'
        \\say
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("body\nbye\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "alias timing chunks keep multi-line here-doc bodies intact" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo alias-ok'
        \\read value <<EOF
        \\hello
        \\EOF
        \\say
        \\echo "$value"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-ok\nhello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases expand at parser-recognized command word positions" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-alias-redir.tmp") catch {};
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo parser-ok'
        \\FOO=bar say
        \\> rush-alias-redir.tmp say
        \\if say; then echo if-ok; fi
        \\read redirected < rush-alias-redir.tmp
        \\echo "$redirected"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("parser-ok\nparser-ok\nif-ok\nparser-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases expand inside command substitutions without touching here-doc bodies" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo subst-ok'
        \\alias body='echo bad'
        \\echo "$(say)"
        \\read value <<EOF
        \\body
        \\EOF
        \\echo "$value"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("subst-ok\nbody\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases can introduce reserved-word compound commands" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias start='if'
        \\start true
        \\then echo alias-if-ok
        \\fi
        \\alias loop='while '
        \\count=0
        \\loop [ "$count" -lt 1 ]
        \\do echo alias-while-ok; count=$((count + 1))
        \\done
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-if-ok\nalias-while-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases defined by eval and dot affect later complete commands" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-alias-dot-source") catch {};
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\eval "alias say='echo eval-ok'"
        \\say
        \\printf '%s\n' "alias dot='echo dot-ok'" > rush-alias-dot-source
        \\. ./rush-alias-dot-source
        \\dot
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("eval-ok\ndot-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases defined on a read line affect only later read lines" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-alias-read-line-source") catch {};
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias zzsamecmd='echo same-ok'; zzsamecmd; echo same-line:$?
        \\zzsamecmd
        \\eval "alias zzevalcmd='echo eval-ok'"; zzevalcmd; echo eval-line:$?
        \\zzevalcmd
        \\printf '%s\n' "alias zzdotcmd='echo dot-ok'" > rush-alias-read-line-source
        \\. ./rush-alias-read-line-source; zzdotcmd; echo dot-line:$?
        \\zzdotcmd
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("same-line:127\nsame-ok\neval-line:127\neval-ok\ndot-line:127\ndot-ok\n", result.stdout);
    try std.testing.expectEqualStrings("zzsamecmd: command not found\nzzevalcmd: command not found\nzzdotcmd: command not found\n", result.stderr);
}

test "repl uses literal PS1 fallback prompt" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\PS1='custom> '
        \\echo ok
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("$ custom> ok\ncustom> ", result.stdout);
}

test "interactive prompt helpers use ShellState prompts and editing mode" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("PS1", "semantic> ", .{});
    try shell_state.putVariable("PS2", "semantic2> ", .{});
    shell_state.options.vi = true;
    shell_state.validate();

    const prompt = try interactive.prompt.renderStatic(std.testing.allocator, &shell_state);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("semantic> ", prompt);
    try std.testing.expectEqualStrings("semantic2> ", interactive.prompt.text(&shell_state, "PS2", "> "));
    try std.testing.expectEqual(line_editor.EditingMode.vi, interactive.input.editingMode(shell_state.options));
}

test "interactive startup initializes prompt variables and sources ENV" {
    const env_path = "rush-test-env-startup.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "ENV_LOADED=ok\nPS1='env> '\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("ENV", env_path, .{ .exported = true });

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("ENV_LOADED").?.value);
    // Embedded default config provides PS2; $ENV overrides the embedded PS1 default.
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
    try std.testing.expectEqualStrings("env> ", shell_state.getVariable("PS1").?.value);
}

test "interactive startup parameter-expands ENV pathname from HOME" {
    const env_path = "rush-test-home-env-startup.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "HOME_ENV_LOADED=ok\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const env_value = try std.fmt.allocPrint(std.testing.allocator, "$HOME/{s}", .{env_path});
    defer std.testing.allocator.free(env_value);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("HOME", cwd, .{ .exported = true });
    try shell_state.putVariable("ENV", env_value, .{ .exported = true });

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("HOME_ENV_LOADED").?.value);
}

test "interactive startup enables monitor by default for tty stdin" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = close(master);
    defer _ = close(slave);

    var guard = try StdinGuard.replaceWith(.{ .handle = slave, .flags = .{ .nonblocking = false } });
    defer guard.restore();

    var default_monitor = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '<%s>\\n' \"$-\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        null,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer default_monitor.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), default_monitor.status);
    try std.testing.expect(std.mem.indexOf(u8, default_monitor.stdout, "m") != null);
    try std.testing.expectEqualStrings("", default_monitor.stderr);

    var explicit_disabled = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '<%s>\\n' \"$-\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        null,
        &.{},
        .{ .arg_zero = "rush", .monitor_option_explicit = true },
        .{},
    );
    defer explicit_disabled.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), explicit_disabled.status);
    try std.testing.expect(std.mem.indexOf(u8, explicit_disabled.stdout, "m") == null);
    try std.testing.expectEqualStrings("", explicit_disabled.stderr);
}

fn loadInteractiveConfigCapturingStderr(allocator: std.mem.Allocator, shell_state: *shell.ShellState, stderr_path: []const u8) ![]u8 {
    var stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{ .truncate = true });
    var stderr_file_open = true;
    defer if (stderr_file_open) stderr_file.close(std.testing.io);

    var stderr_guard = try StderrGuard.replaceWith(stderr_file);
    var stderr_guard_active = true;
    defer if (stderr_guard_active) stderr_guard.restore();

    try loadInteractiveConfig(allocator, std.testing.io, shell_state, .{ .arg_zero = "rush" });

    stderr_guard.restore();
    stderr_guard_active = false;
    stderr_file.close(std.testing.io);
    stderr_file_open = false;

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, allocator, .limited(4096));
}

test "interactive startup warns and skips user config path directory" {
    const root = "rush-test-config-directory-startup";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/config.rush");

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("XDG_CONFIG_HOME", root, .{ .exported = true });

    const stderr = try loadInteractiveConfigCapturingStderr(std.testing.allocator, &shell_state, root ++ "/stderr");
    defer std.testing.allocator.free(stderr);

    try std.testing.expectEqualStrings("rush: warning: cannot read " ++ root ++ "/rush/config.rush: is a directory; skipping\n", stderr);
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
}

test "interactive command string invocation sources ENV before script" {
    const env_path = "rush-test-command-string-env.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "COMMAND_STRING_ENV=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV", env_path);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"$COMMAND_STRING_ENV\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("loaded\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string invocation exits immediately when user config exits" {
    const root = "rush-test-config-exit-startup";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data = "exit 7\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo should-not-run",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string invocation exits immediately when user config exec fails" {
    const root = "rush-test-config-exec-failure-startup";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data = "exec /nonexistent/rush-task-702 2>/dev/null\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo should-not-run",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive command string invocation does not source ENV" {
    const env_path = "rush-test-noninteractive-env.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "NONINTERACTIVE_ENV=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV", env_path);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"${NONINTERACTIVE_ENV-unset}\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("unset\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string invocation parameter-expands ENV_DIR before script" {
    const env_path = "rush-test-env-dir-command-string.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "ENV_DIR_COMMAND_STRING=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const env_value = try std.fmt.allocPrint(std.testing.allocator, "${{ENV_DIR}}/{s}", .{env_path});
    defer std.testing.allocator.free(env_value);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV_DIR", cwd);
    try env.put("ENV", env_value);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"$ENV_DIR_COMMAND_STRING\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("loaded\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "embedded default config sets prompt defaults without clobbering inherited values" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("PS1", "inherited> ", .{});

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("inherited> ", shell_state.getVariable("PS1").?.value);
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
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
