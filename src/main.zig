//! Application entry point.

const std = @import("std");
const build_options = @import("builtin");
const build_config = @import("build_config");

extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;

pub const compat = @import("compat.zig");
pub const parser = @import("parser.zig");
pub const expand = @import("expand.zig");
pub const ir = @import("ir.zig");
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

const system_profile_path = build_config.sysconfdir ++ "/rush/profile.rush";
const system_config_path = build_config.sysconfdir ++ "/rush/config.rush";
const embedded_config = @embedFile("default_config");
const embedded_config_path = "embedded:config.rush";
const omitted_newline_marker = "\x1b[2m⏎\x1b[22m\r\n";
const ignoreeof_message = "Use \"exit\" to leave the shell.\r\n";
const stopped_jobs_exit_warning = "You have stopped jobs.\n";
const immediate_notify_poll_ms = 50;

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

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn monotonicTimestamp(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn durationMillis(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) i64 {
    return @max(start.durationTo(end).raw.toMilliseconds(), 0);
}

const InteractiveContext = struct {
    semantic_state: *shell.ShellState,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},
};

fn runInteractiveIntervalHooks(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !editor_driver.HookResult {
    const interactive_context: *InteractiveContext = @ptrCast(@alignCast(context));
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

fn nextInteractiveIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    _ = io;
    const interactive_context: *InteractiveContext = @ptrCast(@alignCast(context));
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

fn executeInteractivePendingTraps(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) !?CommandResult {
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

fn interactivePendingExit(interactive_shell: *const InteractiveShell) ?shell.ExitStatus {
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

const InteractiveOptions = struct {
    arg_zero: []const u8 = "rush",
    login: bool = false,
    features: compat.Features = .{},
    shell_options: shell.ShellOptions = .{},
    monitor_option_explicit: bool = false,
    positionals: []const []const u8 = &.{},
};

const InteractiveShell = struct {
    allocator: std.mem.Allocator,
    semantic_state: shell.ShellState,
    semantic_enabled: bool = false,

    fn init(allocator: std.mem.Allocator) InteractiveShell {
        return .{
            .allocator = allocator,
            .semantic_state = shell.ShellState.init(allocator),
        };
    }

    fn deinit(self: *InteractiveShell) void {
        self.semantic_state.deinit();
        self.* = undefined;
    }

    fn initializeSemanticStartup(self: *InteractiveShell, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !void {
        self.semantic_state.deinit();
        self.semantic_state = shell.ShellState.init(self.allocator);
        self.semantic_enabled = false;

        var startup_shell_options = options.shell_options;
        setInteractiveStartupShellOptions(&startup_shell_options, options.monitor_option_explicit, stdinIsTty(io));
        try shell.startup.initializeInteractiveState(self.allocator, io, &self.semantic_state, environ_map, options.positionals, startup_shell_options);
        self.semantic_enabled = true;
    }
};

fn setInteractiveStartupShellOptions(shell_options: *shell.ShellOptions, monitor_option_explicit: bool, stdin_is_tty: bool) void {
    if (stdin_is_tty and !monitor_option_explicit) shell_options.monitor = true;
    shell_options.noexec = false;
}

pub fn runInteractive(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !u8 {
    var signal_handlers = interactive.signals.install();
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
    var interactive_shell = InteractiveShell.init(allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(io, environ_map, options);
    try loadInteractiveConfig(allocator, io, &interactive_shell.semantic_state, options);
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
        const prompt = try interactive.prompt.renderStatic(allocator, &interactive_shell.semantic_state);
        defer allocator.free(prompt);
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        const physical_cwd = cwd_buffer[0..cwd_len];
        const cwd = if (interactive.prompt.getEnv(&interactive_shell.semantic_state, "PWD")) |pwd| if (pwd.len != 0) pwd else physical_cwd else physical_cwd;
        command_history.current_cwd = physical_cwd;
        try terminal.reportCurrentDirectory(cwd, terminal_hostname);
        const title = try interactive.input.titlePath(allocator, cwd, interactive.prompt.getEnv(&interactive_shell.semantic_state, "HOME"));
        defer if (title.owned) allocator.free(title.text);
        try terminal.reportWindowTitle(title.text);
        var interactive_context: InteractiveContext = .{ .semantic_state = &interactive_shell.semantic_state, .arg_zero = options.arg_zero, .features = options.features };
        const read_options: editor_driver.ReadLineOptions = .{
            .prompt = prompt,
            .editing_mode = interactive.input.editingMode(interactive_shell.semantic_state.options),
            .hook_context = &interactive_context,
            .run_hooks = runInteractiveIntervalHooks,
            .next_hook_interval_ms = nextInteractiveIntervalMs,
            .history = history_service.lineEditorView(io),
            .external_editor_command = interactive.prompt.externalEditorCommand(&interactive_shell.semantic_state),
            .external_editor_tmpdir = interactive.prompt.externalEditorTmpdir(&interactive_shell.semantic_state),
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
                    if (interactive.input.outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
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

        while (try interactive.input.needsContinuation(allocator, command.items, options.features)) {
            var continuation_options = read_options;
            continuation_options.prompt = interactive.prompt.text(&interactive_shell.semantic_state, "PS2", "> ");
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
                        if (interactive.input.outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
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
            if (interactive.input.outputNeedsNewlineMarker(result.stdout, result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
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

fn runInteractiveInterruptTrap(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) !?CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (shell_state.trapDisposition(.INT) != .caught) return null;
    try shell_state.appendPendingTrap(.INT);
    return executeInteractivePendingTraps(allocator, io, shell_state, arg_zero, features);
}

pub fn runReplInput(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !CommandResult {
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var last_status: shell.ExitStatus = 0;
    var interactive_shell = InteractiveShell.init(allocator);
    defer interactive_shell.deinit();
    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    try interactive_shell.initializeSemanticStartup(io, &empty_env, .{});
    {
        var result = try runner.runShellStateScript(allocator, io, &interactive_shell.semantic_state, embedded_config, embedded_config_path, "rush", .{}, .capture);
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
        const prompt = try interactive.prompt.renderStatic(allocator, &interactive_shell.semantic_state);
        try stdout.appendSlice(allocator, prompt);
        allocator.free(prompt);
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

pub fn runScript(allocator: std.mem.Allocator, io: std.Io, script: []const u8) !CommandResult {
    return runScriptWithOptions(allocator, io, script, .{ .io = io, .allow_external = true });
}

pub fn runScriptWithOptions(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions) !CommandResult {
    return runScriptWithEnvironment(allocator, io, script, options, null);
}

pub fn runScriptWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions, environ_map: ?*const std.process.Environ.Map) !CommandResult {
    return runCommandStringWithEnvironment(allocator, io, script, options, environ_map, &.{}, null, .{});
}

fn runShellInvocationWithEnvironment(allocator: std.mem.Allocator, io: std.Io, invocation: ShellInvocation, environ_map: ?*const std.process.Environ.Map, external_stdio: runtime.ExternalStdio, login_shell: bool) !CommandResult {
    var loaded_script = try runner.loadInvocationScript(allocator, io, invocation, external_stdio);
    defer loaded_script.deinit();
    const interactive_options: ?InteractiveOptions = if (invocation.interactive) .{ .arg_zero = invocation.arg_zero, .login = login_shell, .features = invocation.features, .shell_options = invocation.shell_options, .monitor_option_explicit = invocation.monitor_option_explicit, .positionals = invocation.positionals } else null;
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
    const semantic_invocation = runner.invocationContext(options);
    if (interactive_options) |startup_options| {
        var interactive_run_options = options;
        interactive_run_options.interactive = true;
        var interactive_shell = InteractiveShell.init(allocator);
        defer interactive_shell.deinit();
        var empty_env = std.process.Environ.Map.init(allocator);
        defer empty_env.deinit();
        const startup_env = environ_map orelse &empty_env;
        var startup_shell_options = shell_options;
        setInteractiveStartupShellOptions(&startup_shell_options, startup_options.monitor_option_explicit, stdinIsTty(io));
        try interactive_shell.initializeSemanticStartup(io, startup_env, .{
            .arg_zero = startup_options.arg_zero,
            .login = startup_options.login,
            .features = startup_options.features,
            .shell_options = startup_shell_options,
            .monitor_option_explicit = startup_options.monitor_option_explicit,
            .positionals = positionals,
        });
        try loadInteractiveConfig(allocator, io, &interactive_shell.semantic_state, startup_options);
        if (interactivePendingExit(&interactive_shell)) |status| return runner.empty(allocator, status);
        return runInteractiveScript(allocator, io, &interactive_shell, script, interactive_run_options);
    }
    if (semantic_invocation.interactive or !options.allow_external) {
        return runner.unsupported(allocator, "non-interactive command strings must run through the semantic executor");
    }
    var semantic_execution = try runSemanticCommandString(allocator, io, script, semantic_invocation, options.external_stdio, environ_map, positionals, shell_options);
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

const SemanticInvocationExecution = runner.SemanticInvocationExecution;

fn runSemanticCommandString(allocator: std.mem.Allocator, io: std.Io, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !SemanticInvocationExecution {
    return runner.runSemanticCommandString(allocator, io, script, invocation, external_stdio, environ_map, positionals, shell_options);
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

const InteractiveConfigService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},

    fn init(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) InteractiveConfigService {
        shell_state.validate();
        std.debug.assert(shell_state.scope == .current_shell);
        return .{ .allocator = allocator, .io = io, .shell_state = shell_state, .arg_zero = arg_zero, .features = features };
    }

    fn load(self: InteractiveConfigService, options: InteractiveOptions) !void {
        try self.sourceScript(embedded_config, embedded_config_path);
        if (self.pendingExit() != null) return;

        if (self.getEnv("ENV")) |env_path| {
            if (env_path.len != 0) {
                const expanded_env_path = try self.expandParametersScalar(env_path, options.features);
                defer self.allocator.free(expanded_env_path);
                if (expanded_env_path.len != 0) {
                    try self.sourceOptional(expanded_env_path);
                    if (self.pendingExit() != null) return;
                }
            }
        }

        if (options.login) {
            try self.sourceOptional(system_profile_path);
            if (self.pendingExit() != null) return;
            const user_profile_path = try self.userStartupPath("profile.rush");
            defer if (user_profile_path) |path| self.allocator.free(path);
            if (user_profile_path) |path| {
                try self.sourceOptional(path);
                if (self.pendingExit() != null) return;
            }
        }

        try self.sourceOptional(system_config_path);
        if (self.pendingExit() != null) return;
        const user_path = try self.userStartupPath("config.rush");
        defer if (user_path) |path| self.allocator.free(path);
        if (user_path) |path| {
            try self.sourceOptional(path);
            if (self.pendingExit() != null) return;
        }
    }

    fn sourceOptional(self: InteractiveConfigService, path: []const u8) !void {
        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                try writeOptionalConfigReadWarning(self.io, path, err);
                return;
            },
        };
        defer self.allocator.free(contents);

        try self.sourceScript(contents, path);
    }

    fn sourceScript(self: InteractiveConfigService, contents: []const u8, source_path: []const u8) !void {
        var result = try runner.runShellStateScript(self.allocator, self.io, self.shell_state, contents, source_path, self.arg_zero, self.features, .capture);
        defer result.deinit();
        if (result.stdout.len != 0) try writeAll(self.io, .stdout, result.stdout);
        if (result.stderr.len != 0) try writeAll(self.io, .stderr, result.stderr);
    }

    fn userConfigPath(self: InteractiveConfigService) !?[]const u8 {
        return self.userStartupPath("config.rush");
    }

    fn userProfilePath(self: InteractiveConfigService) !?[]const u8 {
        return self.userStartupPath("profile.rush");
    }

    fn userStartupPath(self: InteractiveConfigService, file_name: []const u8) !?[]const u8 {
        return userStartupPathForShellState(self.allocator, self.shell_state.*, file_name);
    }

    fn userStartupPathForShellState(allocator: std.mem.Allocator, shell_state: shell.ShellState, file_name: []const u8) !?[]const u8 {
        shell_state.validate();
        if (shell_state.getVariable("XDG_CONFIG_HOME")) |xdg_config_home| {
            if (xdg_config_home.value.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home.value, "rush", file_name });
        }
        if (shell_state.getVariable("HOME")) |home| {
            if (home.value.len != 0) return try std.fs.path.join(allocator, &.{ home.value, ".config", "rush", file_name });
        }
        return null;
    }

    fn getEnv(self: InteractiveConfigService, name: []const u8) ?[]const u8 {
        self.shell_state.validate();
        return if (self.shell_state.getVariable(name)) |variable| variable.value else null;
    }

    fn pendingExit(self: InteractiveConfigService) ?shell.ExitStatus {
        self.shell_state.validate();
        return self.shell_state.pending_exit;
    }

    fn expandParametersScalar(self: InteractiveConfigService, text: []const u8, features: compat.Features) ![]const u8 {
        self.shell_state.validate();
        var adapter = runtime.PosixAdapter.init(self.io);
        var expansion = shell.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true }),
            .fs_port = runtime.posixPorts(&adapter).fs,
            .features = features,
            .arg_zero = self.arg_zero,
        });
        defer expansion.deinit();
        return expansion.expandParametersScalar(text);
    }
};

fn loadInteractiveConfig(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, options: InteractiveOptions) !void {
    try InteractiveConfigService.init(allocator, io, shell_state, options.arg_zero, options.features).load(options);
}

fn sourceOptionalConfig(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, path: []const u8, arg_zero: []const u8) !void {
    try InteractiveConfigService.init(allocator, io, shell_state, arg_zero, .{}).sourceOptional(path);
}

fn writeOptionalConfigReadWarning(io: std.Io, path: []const u8, err: anyerror) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print("rush: warning: cannot read {s}: {s}; skipping\n", .{ path, configReadErrorMessage(err) });
}

fn configReadErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        else => @errorName(err),
    };
}

fn sourceConfigScript(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, contents: []const u8, source_path: []const u8, arg_zero: []const u8) !void {
    try InteractiveConfigService.init(allocator, io, shell_state, arg_zero, .{}).sourceScript(contents, source_path);
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

test "runReplInput reports unsupported exit builtin without legacy fallback" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "echo before\nexit 7\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("$ before\n$ $ ", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
}

test "runReplInput reports unsupported fc history bridge without legacy fallback" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\printf 'one\n'
        \\printf 'two\n'
        \\fc -l -n
        \\fc -s one=again 1
        \\fc -l -n
        \\exit
        \\
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "$ one\n$ two\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
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

test "interactive signal handlers catch interrupt quit and terminate" {
    var handlers = interactive.signals.install();
    defer handlers.restore();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &current);
    try std.testing.expect(current.handler.handler != null);
    std.posix.sigaction(.QUIT, null, &current);
    try std.testing.expect(current.handler.handler != null);
    std.posix.sigaction(.TERM, null, &current);
    try std.testing.expect(current.handler.handler != null);
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

test "command string semantic source operands report unsupported" {
    const path = "rush-command-string-source-positionals.rush";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\printf 'source:%s:%s:%s:%s\n' "$0" "$#" "$1" "$2"
        \\set -- changed
        \\
    });

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        ". ./rush-command-string-source-positionals.rush sourced 'two words'; printf 'after:%s:%s:%s:%s\n' \"$0\" \"$#\" \"$1\" \"$2\"",
        .{ .io = std.testing.io, .arg_zero = "myname", .features = compat.Features.bash() },
        null,
        &.{ "caller one", "caller two" },
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(result.stderr.len != 0);
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

test "script file invocation accepts sources larger than one mib" {
    const path = "rush-large-script-invocation-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.appendNTimes(std.testing.allocator, '#', 1024 * 1024 + 1);
    try contents.appendSlice(std.testing.allocator, "\necho ok\n");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = contents.items });

    const invocation = parseShellInvocation(&.{ "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ok\n", result.stdout);
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

test "standard input file script seeks stdin before external commands" {
    const path = "rush-stdin-script-seek-external.tmp";
    const output_path = "rush-stdin-script-seek-external.out";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, output_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "echo start > rush-stdin-script-seek-external.out\n/usr/bin/head -1 >> rush-stdin-script-seek-external.out\necho end >> rush-stdin-script-seek-external.out\n" });

    const invocation = parseShellInvocation(&.{"rush"}) orelse return error.ExpectedInvocation;
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var guard = try StdinGuard.replaceWith(file);
    defer guard.restore();
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .inherit, false);
    defer result.deinit();
    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqualStrings("start\necho end >> rush-stdin-script-seek-external.out\n", output);
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

test "semantic interactive command reports function-shadowed builtin unsupported" {
    const path = "rush-semantic-interactive-function-fallback.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });
    try sourceConfigScript(std.testing.allocator, std.testing.io, &interactive_shell.semantic_state, "echo() { printf 'function\\n' > " ++ path ++ "; }", "semantic-interactive-test.rush", "rush");

    var result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "echo semantic", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("semantic interactive executor does not yet preserve shell function calls\n", result.stderr);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
}

test "semantic interactive unset function reports unsupported without legacy bridge" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });
    try sourceConfigScript(std.testing.allocator, std.testing.io, &interactive_shell.semantic_state, "rush_semantic_unset_fn() { :; }", "semantic-interactive-test.rush", "rush");
    try std.testing.expect(interactive_shell.semantic_state.functions.contains("rush_semantic_unset_fn"));

    var result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "unset -f rush_semantic_unset_fn", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("semantic executor preflight found an unsupported builtin\n", result.stderr);
    try std.testing.expect(interactive_shell.semantic_state.functions.contains("rush_semantic_unset_fn"));
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

test "runScriptWithEnvironment preserves valid inherited logical PWD" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);

    const root = "rush-test-logical-pwd";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/real");
    std.Io.Dir.cwd().symLink(std.testing.io, "real", root ++ "/link", .{}) catch return error.SkipZigTest;

    const logical_pwd = try std.mem.concat(std.testing.allocator, u8, &.{ original_cwd, "/", root, "/link" });
    defer std.testing.allocator.free(logical_pwd);
    try std.process.setCurrentPath(std.testing.io, logical_pwd);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PWD", logical_pwd);

    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
        \\case $PWD in */rush-test-logical-pwd/link) echo logical-pwd ;; *) echo bad-pwd:$PWD ;; esac
        \\case "$(pwd -L)" in */rush-test-logical-pwd/link) echo pwd-L ;; *) echo bad-L ;; esac
        \\case "$(pwd -P)" in */rush-test-logical-pwd/real) echo pwd-P ;; *) echo bad-P ;; esac
    , .{ .io = std.testing.io, .allow_external = true }, &env);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("logical-pwd\npwd-L\npwd-P\n", result.stdout);
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

test "runScriptWithOptions accepts inherit mode for external commands" {
    var result = try runScriptWithOptions(std.testing.allocator, std.testing.io, "/usr/bin/true", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .inherit,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScriptWithOptions captures simple external command output semantically" {
    var captured = try runScriptWithOptions(std.testing.allocator, std.testing.io, "/bin/sh -c 'printf out; printf err >&2'", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .capture,
    });
    defer captured.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), captured.status);
    try std.testing.expectEqualStrings("out", captured.stdout);
    try std.testing.expectEqualStrings("err", captured.stderr);

    var stdout_only = try runScriptWithOptions(std.testing.allocator, std.testing.io, "/bin/sh -c 'printf out; printf err >&2'", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .capture_stdout,
    });
    defer stdout_only.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), stdout_only.status);
    try std.testing.expectEqualStrings("out", stdout_only.stdout);
    try std.testing.expectEqualStrings("", stdout_only.stderr);
}

test "runScript executes builtins" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo hello");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "compatibility feature plumbing accepts Bash mode without changing baseline behavior" {
    var result = try runScriptWithOptions(std.testing.allocator, std.testing.io, "echo ok", .{ .io = std.testing.io, .allow_external = true, .features = .bash() });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ok\n", result.stdout);
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

test "parser smoke corpus parses representative snippets" {
    const snippets = [_][]const u8{
        "",
        "   \t  ",
        "echo hello",
        "FOO=bar echo hi",
        "echo 'quoted text' \"double quoted\"",
        "echo hello | cat",
        "false || echo recovered",
        "true && echo ok",
        "echo > out",
        "echo | ",
        "echo 'unterminated",
        "2>err missing-command",
    };

    for (snippets) |snippet| {
        var parsed = try parser.parse(std.testing.allocator, snippet, .{ .mode = .interactive });
        defer parsed.deinit();
        try std.testing.expect(parsed.tokens.len >= 1);
        try std.testing.expect(parsed.nodes.len >= 1);
    }
}

test "executor smoke corpus returns expected statuses and output fragments" {
    const Case = struct {
        script: []const u8,
        status: shell.ExitStatus,
        stdout_contains: []const u8 = "",
        stderr_contains: []const u8 = "",
    };
    const cases = [_]Case{
        .{ .script = "", .status = 0 },
        .{ .script = "true", .status = 0 },
        .{ .script = "false", .status = 1 },
        .{ .script = "echo smoke", .status = 0, .stdout_contains = "smoke\n" },
        .{ .script = "echo smoke | /bin/cat", .status = 0, .stdout_contains = "smoke\n" },
        .{ .script = "false || echo recovered", .status = 0, .stdout_contains = "recovered\n" },
        .{ .script = "true && echo ok", .status = 0, .stdout_contains = "ok\n" },
        .{ .script = "missing-command", .status = 127, .stderr_contains = "command not found" },
        .{ .script = "echo | ", .status = 2, .stderr_contains = "missing command after pipeline operator" },
    };

    for (cases) |case| {
        var result = try runScript(std.testing.allocator, std.testing.io, case.script);
        defer result.deinit();
        try std.testing.expectEqual(case.status, result.status);
        if (case.stdout_contains.len != 0) {
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, case.stdout_contains) != null);
        }
        if (case.stderr_contains.len != 0) {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.stderr_contains) != null);
        }
    }
}

test "interactive aliases report unsupported without legacy fallback" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\alias if='echo bad'
        \\if true; then echo ok; fi
        \\alias greet='echo alias'
        \\greet() { echo function; }
        \\unalias greet
        \\greet
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "bad\n") == null);
}

test "repl reports alias builtins unsupported without legacy fallback" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\alias lsx='echo alias-ok'
        \\lsx
        \\alias lsx
        \\unalias lsx
        \\lsx
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "alias-ok\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "lsx: command not found\n") != null);
}

test "recursive interactive aliases report unsupported without legacy fallback" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\alias say='echo recursive-ok'
        \\alias run=say
        \\run
        \\alias prefix='run '
        \\alias word='recursive-trailing-ok'
        \\prefix word
        \\alias self=self
        \\self
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok recursive-trailing-ok\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "self: command not found\n") != null);
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

test "interactive startup warns and skips unreadable user config" {
    const root = "rush-test-unreadable-config-startup";
    const config_path = root ++ "/rush/config.rush";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = "CONFIG_LOADED=bad\n" });

    var config_file = try std.Io.Dir.cwd().openFile(std.testing.io, config_path, .{});
    defer config_file.close(std.testing.io);
    try config_file.setPermissions(std.testing.io, @enumFromInt(0o000));
    defer config_file.setPermissions(std.testing.io, @enumFromInt(0o644)) catch {};

    const denied = denied: {
        const contents = std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(1024)) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => break :denied true,
            else => return err,
        };
        std.testing.allocator.free(contents);
        break :denied false;
    };
    if (!denied) return error.SkipZigTest;

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("XDG_CONFIG_HOME", root, .{ .exported = true });

    const stderr = try loadInteractiveConfigCapturingStderr(std.testing.allocator, &shell_state, root ++ "/stderr");
    defer std.testing.allocator.free(stderr);

    try std.testing.expectEqualStrings("rush: warning: cannot read " ++ config_path ++ ": permission denied; skipping\n", stderr);
    try std.testing.expect(shell_state.getVariable("CONFIG_LOADED") == null);
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

test "integration harness compares selected scripts with /bin/sh" {
    try expectMatchesSh("echo hello");
    try expectMatchesSh("false");
    try expectMatchesSh("echo hello | /bin/cat");
    try expectMatchesSh("false || echo yes");
    try expectMatchesSh("true && echo ok");
    try expectMatchesSh("/usr/bin/printf external");
}

test "integration harness checks redirection side effects" {
    const rush_path = "rush-itest-rush-redir.tmp";
    const sh_path = "rush-itest-sh-redir.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, rush_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, sh_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rush_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, sh_path) catch {};

    var rush_result = try runScript(std.testing.allocator, std.testing.io, "echo file > rush-itest-rush-redir.tmp");
    defer rush_result.deinit();
    var sh_result = try runSh(std.testing.allocator, "echo file > rush-itest-sh-redir.tmp");
    defer sh_result.deinit();

    try std.testing.expectEqual(sh_result.status, rush_result.status);
    try std.testing.expectEqualStrings(sh_result.stdout, rush_result.stdout);
    try std.testing.expectEqualStrings(sh_result.stderr, rush_result.stderr);

    const rush_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rush_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(rush_contents);
    const sh_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, sh_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(sh_contents);
    try std.testing.expectEqualStrings(sh_contents, rush_contents);
}

fn expectMatchesSh(script: []const u8) !void {
    var rush_result = try runScript(std.testing.allocator, std.testing.io, script);
    defer rush_result.deinit();
    var sh_result = try runSh(std.testing.allocator, script);
    defer sh_result.deinit();

    try std.testing.expectEqual(sh_result.status, rush_result.status);
    try std.testing.expectEqualStrings(sh_result.stdout, rush_result.stdout);
    try std.testing.expectEqualStrings(sh_result.stderr, rush_result.stderr);
}

fn runSh(allocator: std.mem.Allocator, script: []const u8) !CommandResult {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", script },
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .allocator = allocator,
        .status = processStatus(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn processStatus(term: std.process.Child.Term) shell.ExitStatus {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .stopped => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .unknown => 1,
    };
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
