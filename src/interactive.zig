//! Interactive Rush session orchestration.

const std = @import("std");

const completion = @import("completion.zig");
const editor = @import("editor.zig");
const extensions = @import("extensions.zig");
const function_autoload = @import("function_autoload.zig");
const history = @import("history.zig");
const host = @import("host.zig");
const interactive_event = @import("interactive/event.zig");
const interactive_style = @import("interactive/style.zig");
const startup = @import("interactive/startup.zig");
const shell = @import("shell.zig");

const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

pub const Options = struct {
    state_options: shell.state.Options,
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
    login: bool = false,
    forced_interactive: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    real_host: host.RealHost,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    env: []const [*:0]const u8,
    options: Options,
) !u8 {
    var host_probe = real_host;
    const stdin_terminal = host_probe.isTerminalFd(.stdin);
    // POSIX: without -i, a shell whose standard input is not a terminal is
    // not interactive; it reads commands from standard input like a script.
    const interactive = options.forced_interactive or stdin_terminal;
    var state_options = options.state_options;
    if (!interactive) state_options.interactive = false;

    var sh = RushShell.init(allocator, real_host, .{
        .state = state_options,
        .env = env,
        .arg_zero = options.arg_zero,
        .positionals = options.positionals,
    });
    defer sh.deinit();
    sh.setFunctionAutoload(autoloadRushFunction);

    var source_id: shell.source.SourceId = 1;
    if (try startup.source(&sh, &source_id, options.login, stdin_terminal)) |status| return status;

    if (!interactive) return runStdinScript(allocator, &sh, &source_id);

    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    if (try startup.historyPath(allocator, env)) |path| {
        defer allocator.free(path);
        command_history.load(io, path) catch |err| {
            const message = try std.fmt.allocPrint(
                sh.scratchAllocator(),
                "rush: history disabled: {s}\n",
                .{@errorName(err)},
            );
            try sh.host.writeAll(.stderr, message);
        };
    }
    command_history.session_id = history.sessionId(allocator, io) catch "";
    var history_service = history.InteractiveHistoryService.init(&command_history);
    sh.setCommandHistory(history_service.commandHistory(io));

    if (!stdin_terminal) {
        return runPromptedStdin(allocator, &sh, &source_id);
    }

    var session: InteractiveSession = .{
        .allocator = allocator,
        .io = io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
        .events = .{ .sh = &sh },
    };
    return session.runTerminal();
}

fn enableJobControl(sh: *RushShell, tty_fd: host.Fd) ?host.Pid {
    const original_process_group = sh.host.currentProcessGroup();
    const original_terminal_group = sh.host.terminalProcessGroup(tty_fd) catch return null;

    const shell_pid = sh.host.currentProcessId();
    sh.state.shell_pid = shell_pid;
    ignoreInteractiveJobControlSignals(sh);
    sh.host.setProcessGroup(0, shell_pid) catch {
        sh.state.options.monitor = false;
        return null;
    };
    sh.host.setTerminalProcessGroup(tty_fd, shell_pid) catch {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        sh.host.setProcessGroup(0, original_process_group) catch {};
        sh.state.options.monitor = false;
        return null;
    };
    const foreground_group = sh.host.terminalProcessGroup(tty_fd) catch {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        sh.host.setTerminalProcessGroup(tty_fd, original_terminal_group) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        sh.host.setProcessGroup(0, original_process_group) catch {};
        sh.state.options.monitor = false;
        return null;
    };
    if (foreground_group != shell_pid) {
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        sh.host.setTerminalProcessGroup(tty_fd, original_terminal_group) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        sh.host.setProcessGroup(0, original_process_group) catch {};
        sh.state.options.monitor = false;
        return null;
    }
    sh.state.options.monitor = true;
    return original_terminal_group;
}

fn ignoreInteractiveJobControlSignals(sh: *RushShell) void {
    inline for (.{ "TSTP", "TTIN", "TTOU" }) |name| {
        if (shell.builtin.signalNumber(name)) |signal| {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            sh.host.setSignalIgnored(signal) catch {};
        }
    }
}

const InteractiveSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    command_history: *history.History,
    history_service: *history.InteractiveHistoryService,
    events: interactive_event.Dispatcher(RushShell),
    terminal: ?*editor.driver.TerminalSession = null,
    dispatching_directory_change: bool = false,
    restore_terminal_pgrp: ?host.Pid = null,
    last_command_duration_ms: ?i64 = null,
    pending_event_exit_status: ?u8 = null,

    fn runTerminal(self: *InteractiveSession) !u8 {
        var terminal = editor.driver.TerminalSession.init(self.allocator, self.io) catch {
            try self.sh.host.writeAll(.stderr, "rush: cannot initialize terminal\n");
            return 2;
        };
        defer self.restoreTerminalProcessGroup();
        defer terminal.deinit();
        self.terminal = &terminal;
        defer self.terminal = null;
        self.sh.setDirectoryChangeCallback(self, onDirectoryChange);
        self.restore_terminal_pgrp = enableJobControl(self.sh, @enumFromInt(terminal.ttyFd()));
        self.sh.extensions.configurePromptAsync(self.io, terminal.promptRedrawWakeFd(), .{
            .context = self,
            .register = registerPromptAsyncFd,
            .unregister = unregisterPromptAsyncFd,
        });

        while (true) {
            const line_result = self.readLine(&terminal) catch |err| switch (err) {
                error.EditorFailure => return 2,
                else => return err,
            };
            switch (line_result) {
                .submitted => |line| {
                    defer self.allocator.free(line);
                    if (try self.evaluateSubmittedLine(&terminal, line)) |status| return status;
                },
                .canceled => continue,
                .interrupted => if (self.pending_event_exit_status) |status| return self.exit(status) else continue,
                .eof => {
                    try terminal.leaveEditorMode();
                    return self.exitWithLastStatus();
                },
            }
        }
    }

    fn restoreTerminalProcessGroup(self: *InteractiveSession) void {
        if (self.restore_terminal_pgrp) |process_group| {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            self.sh.host.setTerminalProcessGroup(.stdin, process_group) catch {};
        }
    }

    const ReadLineError = error{EditorFailure} || error{OutOfMemory};

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    fn readLine(self: *InteractiveSession, terminal: *editor.driver.TerminalSession) ReadLineError!editor.driver.ReadLineResult {
        const job_output = self.reapBackgroundJobsAndDispatch(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try self.allocator.dupe(u8, ""),
        };
        defer self.allocator.free(job_output);
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        if (job_output.len != 0) self.sh.host.writeAll(.stderr, job_output) catch {};

        // Collect prompt async refreshes that completed while a foreground
        // command was running so the first render shows fresh output.
        self.sh.extensions.pumpPromptAsync();

        const prompt_text = self.renderPrompt() catch try prompt(self.allocator, self.sh);
        defer self.allocator.free(prompt_text);
        _ = self.dispatchPromptAsyncLifecycleEvents(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };

        const current_cwd = self.sh.host.currentDir(self.allocator) catch try self.allocator.dupe(u8, "");
        defer self.allocator.free(current_cwd);
        self.command_history.current_cwd = current_cwd;
        // ziglint-ignore: Z026 best-effort terminal metadata; the next directory change or prompt reports it again
        self.reportCurrentDirectory(terminal) catch {};

        return terminal.readLine(.{
            .prompt = prompt_text,
            .history = self.history_service.lineEditorView(self.io),
            .prompt_async_context = self,
            .pump_prompt_async = pumpPromptAsync,
            .completion_context = self.sh,
            .complete = completion.complete,
            .expand_abbreviation = expandRushAbbreviation,
            .theme = interactive_style.theme(self.sh.state),
            .style_context = self.sh,
            .refresh_style = interactive_style.refreshStyle,
            .refresh_color_report = interactive_style.refreshColorReport,
            .hook_context = self,
            .run_hooks = runInteractiveHooks,
            .next_hook_interval_ms = nextInteractiveHookIntervalMs,
            .run_activity_event = runInteractiveActivityEvent,
            .prompt_context = self,
            .refresh_prompt = refreshInteractivePrompt,
        }) catch |err| {
            var message_buffer: [128]u8 = undefined;
            const message = std.fmt.bufPrint(
                &message_buffer,
                "rush: editor error: {s}\n",
                .{@errorName(err)},
            ) catch "rush: editor error\n";
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            self.sh.host.writeAll(.stderr, message) catch {};
            return error.EditorFailure;
        };
    }

    fn reportCurrentDirectory(self: *InteractiveSession, terminal: *editor.driver.TerminalSession) !void {
        const cwd = try self.currentDirectoryForReporting();
        defer self.allocator.free(cwd);
        try terminal.reportCurrentDirectory(cwd, self.command_history.hostname);
    }

    fn currentDirectoryForReporting(self: *InteractiveSession) ![]const u8 {
        if (self.sh.state.getVariable("PWD")) |variable| {
            if (variable.value.len != 0 and variable.value[0] == '/') return self.allocator.dupe(u8, variable.value);
        }
        return self.sh.host.currentDir(self.allocator);
    }

    fn renderPrompt(self: *InteractiveSession) ![]const u8 {
        var prepared = try self.events.runEvent(self.allocator, self.io, "prompt.prepare", &.{});
        defer prepared.deinit(self.allocator);
        if (prepared.exit_status) |status| {
            self.pending_event_exit_status = status;
            return prompt(self.allocator, self.sh);
        }
        return extensions.rush.renderPrompt(
            self.allocator,
            self.sh,
            self.sh.state.last_status,
            self.last_command_duration_ms,
        );
    }

    fn dispatchPromptAsyncLifecycleEvents(self: *InteractiveSession, allocator: std.mem.Allocator) !bool {
        const events = self.sh.extensions.takePromptAsyncLifecycleEvents();
        for (0..events.start_count) |_| {
            var dispatched = try self.events.runEvent(allocator, self.io, "prompt.async.start", &.{ "prompt", "1" });
            defer dispatched.deinit(allocator);
            if (dispatched.exit_status) |status| pendingEventExit(self, status);
            if (dispatched.output.len != 0) try self.sh.host.writeAll(.stderr, dispatched.output);
        }
        for (0..events.end_count) |_| {
            var dispatched = try self.events.runEvent(allocator, self.io, "prompt.async.end", &.{ "prompt", "0" });
            defer dispatched.deinit(allocator);
            if (dispatched.exit_status) |status| pendingEventExit(self, status);
            if (dispatched.output.len != 0) try self.sh.host.writeAll(.stderr, dispatched.output);
        }
        return events.start_count != 0 or events.end_count != 0;
    }

    fn evaluateSubmittedLine(
        self: *InteractiveSession,
        terminal: *editor.driver.TerminalSession,
        line: []const u8,
    ) !?u8 {
        try terminal.leaveEditorMode();

        const src: shell.source.Source = .{
            .id = self.source_id.*,
            .kind = .interactive,
            .name = "interactive",
            .text = line,
        };
        self.source_id.* +%= 1;

        const background_jobs_before = self.sh.state.background_jobs.items.len;
        const started_at = unixTimestamp(self.io);
        const evaluated = self.sh.evalSource(src) catch {
            self.sh.state.last_status = 2;
            try self.sh.host.writeAll(.stderr, "rush: shell error\n");
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            terminal.finishSemanticCommand(2) catch {};
            try terminal.enterEditorMode();
            return null;
        };
        const duration_ms = @max(unixTimestamp(self.io) - started_at, 0) * 1000;
        self.last_command_duration_ms = duration_ms;
        if (!self.history_service.consumeSuppressNextAppend()) {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            self.history_service.addCommand(self.io, line, evaluated.status, started_at, duration_ms) catch {};
        }
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        terminal.finishSemanticCommand(evaluated.status) catch {};
        const job_event_output = try self.dispatchJobLifecycleEvents(
            self.allocator,
            background_jobs_before,
            self.sh.state.background_jobs.items.len,
        );
        defer self.allocator.free(job_event_output);
        if (job_event_output.len != 0) try self.sh.host.writeAll(.stderr, job_event_output);

        switch (evaluated.flow) {
            .exit => |status| return self.exit(status),
            else => {
                try terminal.enterEditorMode();
                return null;
            },
        }
    }

    fn reapBackgroundJobsAndDispatch(self: *InteractiveSession, allocator: std.mem.Allocator) ![]const u8 {
        const HostType = switch (@typeInfo(@TypeOf(self.sh.host))) {
            .pointer => |pointer| pointer.child,
            else => @TypeOf(self.sh.host),
        };
        if (!@hasDecl(HostType, "waitNonBlocking")) return allocator.dupe(u8, "");

        const background_jobs_before = self.sh.state.background_jobs.items.len;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var index: usize = 0;
        while (index < self.sh.state.background_jobs.items.len) {
            const job = &self.sh.state.background_jobs.items[index];
            var pid_index: usize = 0;
            while (pid_index < job.pids.items.len) {
                const pid = job.pids.items[pid_index];
                const waited = self.sh.host.waitNonBlocking(pid) catch {
                    pid_index += 1;
                    continue;
                };
                const status = waited orelse {
                    pid_index += 1;
                    continue;
                };
                const job_complete = job.pids.items.len == 1;
                if (job_complete and self.sh.state.options.notify) {
                    try appendBackgroundJobNotification(allocator, &output, job.*, status);
                }
                switch (status) {
                    .stopped => {
                        _ = self.sh.state.setBackgroundJobStatusByPid(pid, .stopped);
                        break;
                    },
                    else => {},
                }
                _ = self.sh.state.removeBackgroundPid(pid);
                if (job_complete) break;
            }
            if (index < self.sh.state.background_jobs.items.len and
                self.sh.state.background_jobs.items[index].pids.items.len != 0)
            {
                index += 1;
            }
        }

        const job_event_output = try self.dispatchJobLifecycleEvents(
            allocator,
            background_jobs_before,
            self.sh.state.background_jobs.items.len,
        );
        defer allocator.free(job_event_output);
        try output.appendSlice(allocator, job_event_output);
        return output.toOwnedSlice(allocator);
    }

    fn dispatchJobLifecycleEvents(
        self: *InteractiveSession,
        allocator: std.mem.Allocator,
        previous_count: usize,
        current_count: usize,
    ) ![]const u8 {
        if (previous_count == current_count) return allocator.dupe(u8, "");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        const event_name = if (current_count > previous_count) "job.start" else "job.end";
        var count_buffer: [32]u8 = undefined;
        const active_count = try std.fmt.bufPrint(&count_buffer, "{d}", .{current_count});
        var dispatched = try self.events.runEvent(allocator, self.io, event_name, &.{ "job", active_count });
        defer dispatched.deinit(allocator);
        if (dispatched.exit_status) |status| pendingEventExit(self, status);
        try output.appendSlice(allocator, dispatched.output);
        return output.toOwnedSlice(allocator);
    }

    fn exitWithLastStatus(self: *InteractiveSession) u8 {
        return self.exit(self.sh.state.last_status);
    }

    fn exit(self: *InteractiveSession, status: u8) u8 {
        return shell.eval.runExitTrap(self.sh, status) catch {
            // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
            self.sh.host.writeAll(.stderr, "rush: shell error\n") catch {};
            return 2;
        };
    }
};

fn registerPromptAsyncFd(context: *anyopaque, fd: std.posix.fd_t) anyerror!void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    const terminal = session.terminal orelse return error.Unexpected;
    try terminal.addPromptAsyncFd(fd);
}

fn unregisterPromptAsyncFd(context: *anyopaque, fd: std.posix.fd_t) void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    const terminal = session.terminal orelse return;
    terminal.removePromptAsyncFd(fd);
}

fn pumpPromptAsync(context: *anyopaque) void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    session.sh.extensions.pumpPromptAsync();
}

fn onDirectoryChange(context: *anyopaque, old_pwd: []const u8, new_pwd: []const u8) void {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    const terminal = session.terminal orelse return;

    // ziglint-ignore: Z026 best-effort terminal metadata; the next prompt reports it again
    terminal.reportCurrentDirectory(new_pwd, session.command_history.hostname) catch {};

    if (session.dispatching_directory_change) return;
    session.dispatching_directory_change = true;
    defer session.dispatching_directory_change = false;

    var dispatched = session.events.runEvent(
        session.allocator,
        session.io,
        "directory.change",
        &.{ old_pwd, new_pwd },
    ) catch |err| {
        var message_buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "rush: directory.change event failed: {s}\n",
            .{@errorName(err)},
        ) catch "rush: directory.change event failed\n";
        // ziglint-ignore: Z026 event diagnostics are best effort during callback dispatch
        session.sh.host.writeAll(.stderr, message) catch {};
        return;
    };
    defer dispatched.deinit(session.allocator);
    if (dispatched.exit_status) |status| pendingEventExit(session, status);
    if (dispatched.output.len != 0) {
        // ziglint-ignore: Z026 event output is best effort during callback dispatch
        session.sh.host.writeAll(.stderr, dispatched.output) catch {};
    }
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn runInteractiveHooks(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !editor.driver.HookResult {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const job_output = try session.reapBackgroundJobsAndDispatch(allocator);
    defer allocator.free(job_output);
    try output.appendSlice(allocator, job_output);

    const prompt_async_event_ran = try session.dispatchPromptAsyncLifecycleEvents(allocator);
    var dispatched = try session.events.runDueTimers(allocator, io);
    defer dispatched.deinit(allocator);
    if (dispatched.exit_status) |status| pendingEventExit(session, status);
    try output.appendSlice(allocator, dispatched.output);
    return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = prompt_async_event_ran or dispatched.ran_count != 0 or dispatched.output.len != 0,
        .stop = dispatched.exit_status != null,
    };
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn nextInteractiveHookIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    return session.events.nextTimerDelayMs(io);
}

fn runInteractiveActivityEvent(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    event_name: []const u8,
    args: []const []const u8,
) !editor.driver.HookResult {
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    var dispatched = try session.events.runEvent(allocator, io, event_name, args);
    if (dispatched.exit_status) |status| pendingEventExit(session, status);
    return dispatched.hookResult();
}

// ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
fn refreshInteractivePrompt(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    _ = io;
    const session: *InteractiveSession = @ptrCast(@alignCast(context));
    _ = try session.dispatchPromptAsyncLifecycleEvents(allocator);
    return session.renderPrompt() catch try prompt(allocator, session.sh);
}

fn pendingEventExit(session: *InteractiveSession, status: u8) void {
    session.pending_event_exit_status = status;
}

fn appendBackgroundJobNotification(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    job: shell.state.BackgroundJob,
    status: host.WaitStatus,
) !void {
    const label = switch (status) {
        .exited => |code| if (code == 0) "Done" else "Exit",
        .signaled => "Terminated",
        .stopped => "Stopped",
        .continued => "Continued",
    };
    switch (status) {
        .exited => |code| if (code == 0) {
            try appendPrint(allocator, output, "[{d}] {s} {s}\n", .{ job.id, label, job.command });
        } else {
            try appendPrint(allocator, output, "[{d}] {s} {d} {s}\n", .{ job.id, label, code, job.command });
        },
        .signaled => |signal| try appendPrint(
            allocator,
            output,
            "[{d}] {s} {d} {s}\n",
            .{ job.id, label, signal, job.command },
        ),
        .stopped => |signal| try appendPrint(
            allocator,
            output,
            "[{d}] {s} {d} {s}\n",
            .{ job.id, label, signal, job.command },
        ),
        .continued => try appendPrint(allocator, output, "[{d}] {s} {s}\n", .{ job.id, label, job.command }),
    }
}

fn appendPrint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const bytes = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(bytes);
    try output.appendSlice(allocator, bytes);
}

fn autoloadRushFunction(sh: *RushShell, name: []const u8) !bool {
    return function_autoload.autoload(sh, name);
}

/// Runs a non-interactive shell reading commands from standard input.
///
/// Lines accumulate until they form complete commands, so multi-line
/// constructs and here-documents work across lines while commands still
/// execute as soon as they are complete, sharing standard input with the
/// commands they run (POSIX sh -s semantics). Per POSIX 2.8.1 the shell
/// exits on a syntax error or fatal shell error.
fn runStdinScript(
    allocator: std.mem.Allocator,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
) !u8 {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    while (true) {
        const line = try readStdinLineWithNewline(allocator, sh) orelse break;
        defer allocator.free(line);
        try pending.appendSlice(allocator, line);
        if (endsWithLineContinuation(pending.items)) continue;
        if (!stdinCommandsComplete(sh, pending.items)) continue;
        if (try evalStdinPending(sh, source_id, &pending)) |status| return status;
    }
    if (pending.items.len != 0) {
        if (try evalStdinPending(sh, source_id, &pending)) |status| return status;
    }
    return shell.eval.runExitTrap(sh, sh.state.last_status) catch {
        try sh.host.writeAll(.stderr, "rush: shell error\n");
        return 2;
    };
}

/// Evaluates the pending buffer; returns an exit status when the shell
/// must stop reading standard input.
fn evalStdinPending(
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    pending: *std.ArrayList(u8),
) !?u8 {
    const src: shell.source.Source = .{
        .id = source_id.*,
        .kind = .standard_input,
        .name = "stdin",
        .text = pending.items,
    };
    source_id.* +%= 1;

    const evaluated = sh.evalSource(src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try sh.host.writeAll(.stderr, "rush: shell error\n");
            return 2;
        },
    };
    pending.clearRetainingCapacity();
    switch (evaluated.flow) {
        .exit, .fatal => return shell.eval.runExitTrap(sh, evaluated.status) catch {
            try sh.host.writeAll(.stderr, "rush: shell error\n");
            return 2;
        },
        else => return null,
    }
}

/// Checks whether the accumulated text parses as complete commands, so
/// evaluation never runs a prefix of a construct that later lines finish.
/// Alias values that open compound commands cannot be detected here; such
/// constructs must not span physical lines when piped into the shell.
fn stdinCommandsComplete(sh: *RushShell, text: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(sh.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: shell.source.Source = .{ .id = 0, .kind = .standard_input, .name = "stdin", .text = text };
    const tokens = shell.lexer.lex(allocator, src) catch return true;
    var incremental = shell.parser.Incremental.initWithOptions(allocator, src, tokens, sh.state, .{
        .require_complete_here_docs = true,
    });
    while (true) {
        const maybe_program = incremental.next() catch |err| return switch (err) {
            error.IncompleteHereDoc,
            error.UnclosedQuote,
            error.UnclosedCommandSubstitution,
            => false,
            error.ExpectedCommand,
            error.ExpectedRedirectionTarget,
            error.UnexpectedToken,
            => !incremental.atEndOfInput(),
            error.InvalidParameterExpansion, error.OutOfMemory => true,
        };
        if (maybe_program == null) return true;
    }
}

/// True when the text ends with an unquoted <backslash><newline>, which the
/// lexer removes as line continuation; the next line must be read first.
fn endsWithLineContinuation(text: []const u8) bool {
    if (text.len < 2 or text[text.len - 1] != '\n') return false;
    var backslashes: usize = 0;
    var index = text.len - 1;
    while (index > 0 and text[index - 1] == '\\') : (index -= 1) backslashes += 1;
    return backslashes % 2 == 1;
}

test "line continuation detection counts trailing backslashes" {
    try std.testing.expect(endsWithLineContinuation("echo a\\\n"));
    try std.testing.expect(!endsWithLineContinuation("echo a\\\\\n"));
    try std.testing.expect(endsWithLineContinuation("echo a\\\\\\\n"));
    try std.testing.expect(!endsWithLineContinuation("echo a\n"));
    try std.testing.expect(!endsWithLineContinuation("echo a"));
    try std.testing.expect(!endsWithLineContinuation("\n"));
}

fn readStdinLineWithNewline(allocator: std.mem.Allocator, sh: *RushShell) !?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try sh.host.read(.stdin, &byte);
        if (read_len == 0) {
            if (line.items.len == 0) return null;
            return try line.toOwnedSlice(allocator);
        }
        try line.append(allocator, byte[0]);
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
    }
}

fn runPromptedStdin(
    allocator: std.mem.Allocator,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
) !u8 {
    while (true) {
        const prompt_text = try promptedStdinPrompt(allocator, sh);
        defer allocator.free(prompt_text);
        try sh.host.writeAll(.stderr, prompt_text);

        const line = try readInteractiveStdinLine(allocator, sh) orelse {
            return shell.eval.runExitTrap(sh, sh.state.last_status) catch {
                try sh.host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            };
        };
        defer allocator.free(line);

        const src: shell.source.Source = .{
            .id = source_id.*,
            .kind = .interactive,
            .name = "interactive",
            .text = line,
        };
        source_id.* +%= 1;

        const evaluated = sh.evalSource(src) catch {
            sh.state.last_status = 2;
            try sh.host.writeAll(.stderr, "rush: shell error\n");
            continue;
        };
        switch (evaluated.flow) {
            .exit => |status| return shell.eval.runExitTrap(sh, status) catch {
                try sh.host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            },
            else => {},
        }
    }
}

fn readInteractiveStdinLine(allocator: std.mem.Allocator, sh: *RushShell) !?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try sh.host.read(.stdin, &byte);
        if (read_len == 0) {
            if (line.items.len == 0) return null;
            return try line.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
        try line.append(allocator, byte[0]);
    }
}

fn prompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (startup.envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "rush> ");
}

fn promptedStdinPrompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (startup.envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "$ ");
}

fn expandRushAbbreviation(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    append_space: bool,
) !?editor.completion.Edit {
    const sh: *RushShell = @ptrCast(@alignCast(context));
    return extensions.rush.expandAbbreviation(&sh.extensions, allocator, source, cursor, append_space);
}

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

test {
    std.testing.refAllDecls(@This());
}
