//! Interactive shell session orchestration.

const std = @import("std");

const compat = @import("../shell/compat.zig");
const editor_driver = @import("../editor_driver.zig");
const history = @import("../history.zig");
const runner = @import("../runner.zig");
const runtime = @import("../runtime.zig");
const shell = @import("../shell.zig");

const interactive_input = @import("input.zig");
const prompt_mod = @import("prompt.zig");
const signals = @import("signals.zig");
const startup = @import("startup.zig");

const omitted_newline_marker = "\x1b[2m⏎\x1b[22m\r\n";
const ignoreeof_message = "Use \"exit\" to leave the shell.\r\n";
const stopped_jobs_exit_warning = "You have stopped jobs.\n";
pub const immediate_notify_poll_ms = 50;

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

fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn monotonicTimestamp(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn durationMillis(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) i64 {
    return @max(start.durationTo(end).raw.toMilliseconds(), 0);
}

pub const Context = struct {
    semantic_state: *shell.ShellState,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},
};

pub fn runInteractiveIntervalHooks(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !editor_driver.HookResult {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var should_refresh_prompt = false;

    const semantic_state = interactive_context.semantic_state;
    if (try executeInteractivePendingTraps(allocator, io, semantic_state, interactive_context.arg_zero, interactive_context.features)) |trap_result| {
        var result = trap_result;
        defer result.deinit();
        try output.appendSlice(allocator, result.stdout);
        try output.appendSlice(allocator, result.stderr);
        should_refresh_prompt = true;
    }

    if (semantic_state.options.notify) {
        const notifications = try drainInteractiveSemanticJobNotifications(allocator, io, semantic_state);
        defer allocator.free(notifications);
        try output.appendSlice(allocator, notifications);
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = should_refresh_prompt,
        .stop = semantic_state.pending_exit != null,
    };
}

pub fn nextInteractiveIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    _ = io;
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    if (shellStateWantsImmediateJobNotificationPoll(interactive_context.semantic_state)) {
        return immediate_notify_poll_ms;
    }
    return null;
}

fn drainInteractiveSemanticJobNotifications(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState) ![]const u8 {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    const eval_context = shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true });
    var outcome = try shell.eval.drainJobNotifications(&evaluator, shell_state, eval_context);
    defer outcome.deinit();
    try outcome.commitDelta(shell_state, .current_shell);
    const output = try outcome.stdout.toOwnedSlice(allocator);
    outcome.stdout = .empty;
    shell_state.validate();
    return output;
}

fn executeInteractivePendingTraps(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) !?runner.CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(arg_zero.len != 0);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    evaluator.features = features;
    evaluator.arg_zero = arg_zero;
    evaluator.external_stdio = .inherit;
    const eval_context = shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true });

    if (try shell.eval.observeRuntimeSignal(&evaluator, shell_state, eval_context)) |observed| {
        var observation = observed;
        defer observation.deinit();
        try observation.command_outcome.commitDelta(shell_state, .current_shell);
    }

    var resolver = shell.eval.ParserTrapActionResolver.init(&evaluator);
    resolver.features = features;
    resolver.arg_zero = arg_zero;
    var trap_outcome = (try shell.eval.executePendingTraps(&evaluator, shell_state, eval_context, resolver.resolver())) orelse return null;
    defer trap_outcome.deinit();

    const stdout = try trap_outcome.stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try trap_outcome.stderr.toOwnedSlice(allocator);
    errdefer allocator.free(stderr);
    try trap_outcome.commitDelta(shell_state, .current_shell);
    shell_state.validate();
    return .{ .allocator = allocator, .status = trap_outcome.status, .stdout = stdout, .stderr = stderr };
}

fn shellStateWantsImmediateJobNotificationPoll(shell_state: *const shell.ShellState) bool {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (!shell_state.options.notify) return false;
    if (shell_state.pending_job_notifications.items.len != 0) return true;
    for (shell_state.background_jobs.items) |job| {
        job.validate();
        if (job.state != .done or job.notified_state != job.state) return true;
    }
    return false;
}

fn interactivePendingExit(interactive_shell: *const Shell) ?shell.ExitStatus {
    if (!interactive_shell.semantic_enabled) return null;
    interactive_shell.semantic_state.validate();
    std.debug.assert(interactive_shell.semantic_state.scope == .current_shell);
    return interactive_shell.semantic_state.pending_exit;
}

fn shellStateHasStoppedJobs(shell_state: shell.ShellState) bool {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    for (shell_state.background_jobs.items) |job| {
        job.validate();
        if (job.state == .stopped) return true;
    }
    return false;
}

fn shouldWarnBeforeExitWithStoppedJobs(shell_state: *shell.ShellState) bool {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (!shellStateHasStoppedJobs(shell_state.*)) {
        shell_state.warned_stopped_jobs_on_exit = false;
        shell_state.validate();
        return false;
    }
    if (shell_state.warned_stopped_jobs_on_exit) return false;
    shell_state.warned_stopped_jobs_on_exit = true;
    shell_state.validate();
    return true;
}

pub const Options = startup.Options;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    semantic_state: shell.ShellState,
    semantic_enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) Shell {
        return .{
            .allocator = allocator,
            .semantic_state = shell.ShellState.init(allocator),
        };
    }

    pub fn deinit(self: *Shell) void {
        self.semantic_state.deinit();
        self.* = undefined;
    }

    pub fn initializeSemanticStartup(self: *Shell, io: std.Io, environ_map: *const std.process.Environ.Map, options: Options) !void {
        self.semantic_state.deinit();
        self.semantic_state = shell.ShellState.init(self.allocator);
        self.semantic_enabled = false;

        var startup_shell_options = options.shell_options;
        startup.setShellOptions(&startup_shell_options, options.monitor_option_explicit, stdinIsTty(io));
        try shell.startup.initializeInteractiveState(self.allocator, io, &self.semantic_state, environ_map, options.positionals, startup_shell_options);
        self.semantic_enabled = true;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, options: Options) !u8 {
    var signal_handlers = signals.install();
    defer signal_handlers.restore();

    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    const active_session_id = try history.sessionId(allocator, io);
    defer allocator.free(active_session_id);
    command_history.session_id = active_session_id;
    const history_path = try history.defaultPath(allocator, environ_map);
    defer if (history_path) |path| allocator.free(path);
    if (history_path) |path| command_history.load(io, path) catch {};
    defer if (history_path) |path| command_history.save(io, path) catch {};
    const terminal_hostname = try history.localHostname(allocator);
    defer allocator.free(terminal_hostname);

    var last_status: shell.ExitStatus = 0;
    var interactive_shell = Shell.init(allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(io, environ_map, options);
    try startup.loadConfig(allocator, io, &interactive_shell.semantic_state, options);
    if (interactivePendingExit(&interactive_shell)) |status| return status;
    var terminal = try editor_driver.TerminalSession.init(allocator, io);
    defer terminal.deinit();
    runtime.signal.setWakeFd(terminal.trapSignalWakeFd());
    defer runtime.signal.clearWakeFd(terminal.trapSignalWakeFd());
    if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);

    repl_loop: while (true) {
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        terminal.refreshWinsize();
        if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const notifications = if (interactive_shell.semantic_enabled)
            try drainInteractiveSemanticJobNotifications(allocator, io, &interactive_shell.semantic_state)
        else
            try allocator.dupe(u8, "");
        defer allocator.free(notifications);
        try writeAll(io, .stderr, notifications);
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        const prompt_text = try prompt_mod.renderStatic(allocator, &interactive_shell.semantic_state);
        defer allocator.free(prompt_text);
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        const physical_cwd = cwd_buffer[0..cwd_len];
        const cwd = if (prompt_mod.getEnv(&interactive_shell.semantic_state, "PWD")) |pwd| if (pwd.len != 0) pwd else physical_cwd else physical_cwd;
        command_history.current_cwd = physical_cwd;
        try terminal.reportCurrentDirectory(cwd, terminal_hostname);
        const title = try interactive_input.titlePath(allocator, cwd, prompt_mod.getEnv(&interactive_shell.semantic_state, "HOME"));
        defer if (title.owned) allocator.free(title.text);
        try terminal.reportWindowTitle(title.text);
        var interactive_context: Context = .{ .semantic_state = &interactive_shell.semantic_state, .arg_zero = options.arg_zero, .features = options.features };
        const read_options: editor_driver.ReadLineOptions = .{
            .prompt = prompt_text,
            .editing_mode = interactive_input.editingMode(interactive_shell.semantic_state.options),
            .hook_context = &interactive_context,
            .run_hooks = runInteractiveIntervalHooks,
            .next_hook_interval_ms = nextInteractiveIntervalMs,
            .history = history_service.lineEditorView(io),
            .external_editor_command = prompt_mod.externalEditorCommand(&interactive_shell.semantic_state),
            .external_editor_tmpdir = prompt_mod.externalEditorTmpdir(&interactive_shell.semantic_state),
        };
        const read_result = try terminal.readLine(read_options);
        if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const line = switch (read_result) {
            .submitted => |line| line,
            .canceled => {
                if (try runInteractiveInterruptTrap(allocator, io, &interactive_shell.semantic_state, options.arg_zero, options.features)) |result| {
                    var trap_result = result;
                    defer trap_result.deinit();
                    try terminal.leaveEditorMode();
                    var editor_mode_left = true;
                    defer if (editor_mode_left) terminal.enterEditorMode() catch {};

                    try writeAll(io, .stdout, trap_result.stdout);
                    try writeAll(io, .stderr, trap_result.stderr);
                    if (interactive_input.outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
                    last_status = trap_result.status;
                    try terminal.finishSemanticCommand(trap_result.status);
                    if (interactivePendingExit(&interactive_shell)) |status| {
                        last_status = status;
                        editor_mode_left = false;
                        break;
                    }

                    try terminal.enterEditorMode();
                    editor_mode_left = false;
                }
                continue;
            },
            .interrupted => {
                if (interactivePendingExit(&interactive_shell)) |status| {
                    last_status = status;
                    break;
                }
                continue;
            },
            .eof => {
                if (!interactive_shell.semantic_state.options.ignoreeof) break;
                try writeAll(io, .stderr, ignoreeof_message);
                continue;
            },
        };
        defer allocator.free(line);

        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(allocator);
        try command.appendSlice(allocator, line);

        while (try interactive_input.needsContinuation(allocator, command.items, options.features)) {
            var continuation_options = read_options;
            continuation_options.prompt = prompt_mod.text(&interactive_shell.semantic_state, "PS2", "> ");
            continuation_options.diagnostic_context = null;
            continuation_options.diagnose = null;
            const continuation_read_result = try terminal.readLine(continuation_options);
            if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
            const continuation_line = switch (continuation_read_result) {
                .submitted => |continuation_line| continuation_line,
                .canceled => {
                    if (try runInteractiveInterruptTrap(allocator, io, &interactive_shell.semantic_state, options.arg_zero, options.features)) |result| {
                        var trap_result = result;
                        defer trap_result.deinit();
                        try terminal.leaveEditorMode();
                        var editor_mode_left = true;
                        defer if (editor_mode_left) terminal.enterEditorMode() catch {};

                        try writeAll(io, .stdout, trap_result.stdout);
                        try writeAll(io, .stderr, trap_result.stderr);
                        if (interactive_input.outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
                        last_status = trap_result.status;
                        try terminal.finishSemanticCommand(trap_result.status);
                        if (interactivePendingExit(&interactive_shell)) |status| {
                            last_status = status;
                            editor_mode_left = false;
                            break :repl_loop;
                        }

                        try terminal.enterEditorMode();
                        editor_mode_left = false;
                    }
                    continue :repl_loop;
                },
                .interrupted => {
                    if (interactivePendingExit(&interactive_shell)) |status| {
                        last_status = status;
                        break :repl_loop;
                    }
                    continue :repl_loop;
                },
                .eof => {
                    try terminal.finishSemanticCommand(2);
                    last_status = 2;
                    continue :repl_loop;
                },
            };
            defer allocator.free(continuation_line);
            try command.append(allocator, '\n');
            try command.appendSlice(allocator, continuation_line);
        }

        const input = command.items;
        if (std.mem.eql(u8, input, "exit")) {
            if (shouldWarnBeforeExitWithStoppedJobs(&interactive_shell.semantic_state)) {
                try terminal.finishSemanticCommand(0);
                try writeAll(io, .stderr, stopped_jobs_exit_warning);
                continue;
            }
            try terminal.finishSemanticCommand(0);
            break;
        }
        if (input.len == 0) {
            try terminal.finishSemanticCommand(0);
            continue;
        }

        {
            try terminal.leaveEditorMode();
            var editor_mode_left = true;
            defer if (editor_mode_left) terminal.enterEditorMode() catch {};

            const command_started_at = unixTimestamp(io);
            const command_started = monotonicTimestamp(io);
            var result = try runInteractiveScript(allocator, io, &interactive_shell, input, .{ .io = io, .allow_external = true, .features = options.features, .external_stdio = .inherit, .interactive = true, .arg_zero = options.arg_zero });
            const command_duration_ms = durationMillis(command_started, monotonicTimestamp(io));
            defer result.deinit();
            try writeAll(io, .stdout, result.stdout);
            try writeAll(io, .stderr, result.stderr);
            if (interactive_input.outputNeedsNewlineMarker(result.stdout, result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
            last_status = result.status;
            if (!history_service.consumeSuppressNextAppend()) try history_service.addCommand(io, input, result.status, command_started_at, command_duration_ms);
            try terminal.finishSemanticCommand(result.status);
            if (interactivePendingExit(&interactive_shell)) |status| {
                last_status = status;
                editor_mode_left = false;
                break;
            }

            try terminal.enterEditorMode();
            editor_mode_left = false;
        }
    }

    return last_status;
}

fn runInteractiveScript(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *Shell, script: []const u8, options: runner.Options) !runner.CommandResult {
    std.debug.assert(options.interactive);
    if (interactive_shell.semantic_enabled) {
        var execution = try runSemanticInteractiveCommandString(allocator, io, interactive_shell, script, runner.invocationContext(options), options.external_stdio);
        switch (execution) {
            .output => |output| {
                execution = undefined;
                return output;
            },
            .unsupported => |message| {
                execution = undefined;
                defer allocator.free(message);
                return runner.unsupported(allocator, message);
            },
        }
    }

    return runner.unsupported(allocator, "semantic interactive executor is disabled while legacy interactive services are active");
}

pub fn runSemanticInteractiveCommandString(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *Shell, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !runner.SemanticInvocationExecution {
    std.debug.assert(interactive_shell.semantic_enabled);
    return runner.runInteractiveCommandString(allocator, io, &interactive_shell.semantic_state, script, invocation, external_stdio);
}

pub fn runCommandStringWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: runner.Options, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, startup_options: Options, shell_options: shell.ShellOptions) !runner.CommandResult {
    var interactive_run_options = options;
    interactive_run_options.interactive = true;
    var interactive_shell = Shell.init(allocator);
    defer interactive_shell.deinit();
    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    const startup_env = environ_map orelse &empty_env;
    var startup_shell_options = shell_options;
    startup.setShellOptions(&startup_shell_options, startup_options.monitor_option_explicit, stdinIsTty(io));
    try interactive_shell.initializeSemanticStartup(io, startup_env, .{
        .arg_zero = startup_options.arg_zero,
        .login = startup_options.login,
        .features = startup_options.features,
        .shell_options = startup_shell_options,
        .monitor_option_explicit = startup_options.monitor_option_explicit,
        .positionals = positionals,
    });
    try startup.loadConfig(allocator, io, &interactive_shell.semantic_state, startup_options);
    if (interactivePendingExit(&interactive_shell)) |status| return runner.empty(allocator, status);
    return runInteractiveScript(allocator, io, &interactive_shell, script, interactive_run_options);
}

fn syncSemanticTerminalSize(shell_state: *shell.ShellState, terminal: editor_driver.TerminalSession) !void {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    const winsize = terminal.currentWinsize();
    var rows_buffer: [32]u8 = undefined;
    var cols_buffer: [32]u8 = undefined;
    const rows = try std.fmt.bufPrint(&rows_buffer, "{d}", .{winsize.rows});
    const cols = try std.fmt.bufPrint(&cols_buffer, "{d}", .{winsize.cols});
    try shell_state.putVariable("LINES", rows, .{ .exported = true });
    try shell_state.putVariable("COLUMNS", cols, .{ .exported = true });
}

pub fn runInteractiveInterruptTrap(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) !?runner.CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (shell_state.trapDisposition(.INT) != .caught) return null;
    try shell_state.appendPendingTrap(.INT);
    return executeInteractivePendingTraps(allocator, io, shell_state, arg_zero, features);
}

pub fn runReplInput(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !runner.CommandResult {
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var last_status: shell.ExitStatus = 0;
    var interactive_shell = Shell.init(allocator);
    defer interactive_shell.deinit();
    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    try interactive_shell.initializeSemanticStartup(io, &empty_env, .{});
    {
        var result = try startup.sourceDefaultConfig(allocator, io, &interactive_shell.semantic_state, "rush", .{});
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
    }

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        const notifications = if (interactive_shell.semantic_enabled)
            try drainInteractiveSemanticJobNotifications(allocator, io, &interactive_shell.semantic_state)
        else
            try allocator.dupe(u8, "");
        try stderr.appendSlice(allocator, notifications);
        allocator.free(notifications);
        const prompt_text = try prompt_mod.renderStatic(allocator, &interactive_shell.semantic_state);
        try stdout.appendSlice(allocator, prompt_text);
        allocator.free(prompt_text);
        if (std.mem.eql(u8, line, "exit")) break;
        if (line.len == 0) continue;

        const command_started_at = unixTimestamp(io);
        var result = try runInteractiveScript(allocator, io, &interactive_shell, line, .{ .io = io, .allow_external = true, .interactive = true, .arg_zero = "rush" });
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
        last_status = result.status;
        if (!history_service.consumeSuppressNextAppend()) try history_service.addCommand(io, line, result.status, command_started_at, 0);
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
    }

    return .{
        .allocator = allocator,
        .status = last_status,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;

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
    var context: Context = .{ .semantic_state = &shell_state };

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

    var context: Context = .{ .semantic_state = &shell_state };

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

    var context: Context = .{ .semantic_state = &shell_state };

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
test "semantic interactive command updates executor status for later commands" {
    var interactive_shell = Shell.init(std.testing.allocator);
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
    var interactive_shell = Shell.init(std.testing.allocator);
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
    var interactive_shell = Shell.init(std.testing.allocator);
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
    var interactive_shell = Shell.init(std.testing.allocator);
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

    var interactive_shell = Shell.init(std.testing.allocator);
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
test "semantic interactive invocation executes simple command redirections without legacy fallback" {
    const path = "rush-semantic-interactive-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = Shell.init(std.testing.allocator);
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
