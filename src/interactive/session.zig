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
