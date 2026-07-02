//! Cooperative driver pieces for the future terminal line editor.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const event_loop = @import("../event_loop.zig");
const line_editor = @import("session.zig");
const completion = @import("completion.zig");
const signal = @import("signal.zig");
const terminal = @import("terminal.zig");
const worker = @import("worker.zig");

const log = std.log.scoped(.editor_driver);

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const anyopaque,
) c_int;
extern "c" fn close(fd: c_int) c_int;

const read_chunk_size = 4096;
const semantic_command_start = "\x1b]133;A;cl=w\x07";
const semantic_input_end = "\x1b]133;C\x07";
const semantic_input_cancel = "\x1b]133;D;err=CANCEL\x07";
const completion_progress_start = "\x1b]9;4;3\x07";
const completion_progress_stop = "\x1b]9;4;0\x07";
const completion_progress_delay_ms = 500;

pub const TerminalEvent = terminal.Event;
pub const ColorScheme = terminal.ColorScheme;
pub const ColorReport = terminal.ColorReport;
pub const Capability = terminal.Capability;
pub const TerminalCapabilities = terminal.Capabilities;
pub const TerminalParser = terminal.Parser;

const writeTtyAll = terminal.writeAll;
const writeTtyText = terminal.writeText;

pub const Pipe = signal.Pipe;
pub const makePipe = signal.makePipe;
const ResizeSignalSource = signal.ResizeSource;
const ChildSignalSource = signal.ChildSource;
const InterruptSignalSource = signal.InterruptSource;
const rawRead = signal.rawRead;
const rawWriteAll = signal.rawWriteAll;
const setNonBlocking = signal.setNonBlocking;

const CompletionController = worker.Controller;
const CompletionRequestReason = worker.RequestReason;
const CompletionWorker = worker.Worker;

pub const ReadLineOptions = struct {
    prompt: []const u8,
    editing_mode: line_editor.EditingMode = .emacs,
    prompt_refresh_interval_ms: ?u64 = null,
    hook_context: ?*anyopaque = null,
    run_hooks: ?*const fn (*anyopaque, std.mem.Allocator, std.Io) anyerror!HookResult = null,
    next_hook_interval_ms: ?*const fn (*anyopaque, std.Io) anyerror!?u64 = null,
    run_activity_event: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        []const u8,
        []const []const u8,
    ) anyerror!HookResult = null,
    prompt_context: ?*anyopaque = null,
    refresh_prompt: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
    ) anyerror![]const u8 = null,
    prompt_async_context: ?*anyopaque = null,
    pump_prompt_async: ?*const fn (*anyopaque) void = null,
    history: line_editor.HistoryView = .{},
    completion_context: ?*anyopaque = null,
    complete: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        []const u8,
        usize,
    ) anyerror!completion.Application = null,
    clone_completion_context: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        *completion.CancellationToken,
    ) anyerror!*anyopaque = null,
    free_completion_context: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    expand_abbreviation: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        []const u8,
        usize,
        bool,
    ) anyerror!?completion.Edit = null,
    path_expansion_context: ?*anyopaque = null,
    expand_pathname: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        []const u8,
    ) anyerror!line_editor.PathExpansionMatches = null,
    vi_alias_context: ?*anyopaque = null,
    lookup_vi_alias: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        u21,
    ) anyerror!?[]const u8 = null,
    external_editor_command: []const u8 = "vi",
    external_editor_tmpdir: []const u8 = "/tmp",
    diagnostic_context: ?*anyopaque = null,
    diagnose: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        []const u8,
    ) anyerror!?line_editor.DiagnosticRender = null,
    theme: line_editor.UiTheme = .{},
    style_context: ?*anyopaque = null,
    refresh_style: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        ColorScheme,
    ) anyerror!line_editor.UiTheme = null,
    refresh_color_report: ?*const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        ColorReport,
    ) anyerror!line_editor.UiTheme = null,
};

pub const HookResult = struct {
    output: []const u8,
    refresh_prompt: bool = true,
    stop: bool = false,
};

pub const ReadLineResult = union(enum) {
    submitted: []const u8,
    canceled,
    interrupted,
    eof,
};

const completion_flash_ms = 80;

pub const TerminalSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tty_buffer: []u8,
    tty: vaxis.tty.PosixTty,
    prompt_redraw: Pipe,
    completion_wake: Pipe,
    trap_signal: Pipe,
    resize: ResizeSignalSource,
    child_signal: ChildSignalSource,
    interrupt_signal: InterruptSignalSource,
    loop: event_loop.EventLoop,
    terminal_parser: TerminalParser,
    renderer: line_editor.FrameRenderer = .{},
    completion: CompletionController,
    capabilities: TerminalCapabilities = .{},
    query_batch_sent: bool = false,
    color_scheme: ColorScheme = .unknown,
    winsize: vaxis.Winsize,
    events: std.ArrayList(TerminalEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !TerminalSession {
        const tty_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(tty_buffer);
        var tty = try initPosixTtyPreserveInput(io, tty_buffer);
        errdefer deinitPosixTtyPreserveInput(tty);

        var prompt_redraw = try makePipe(io);
        errdefer prompt_redraw.close(io);
        try setNonBlocking(prompt_redraw.read.handle);
        try setNonBlocking(prompt_redraw.write.handle);
        var completion_wake = try makePipe(io);
        errdefer completion_wake.close(io);
        try setNonBlocking(completion_wake.read.handle);
        try setNonBlocking(completion_wake.write.handle);
        var trap_signal = try makePipe(io);
        errdefer trap_signal.close(io);
        try setNonBlocking(trap_signal.read.handle);
        try setNonBlocking(trap_signal.write.handle);
        var resize = try ResizeSignalSource.init(io);
        errdefer resize.deinitUnregistered(io);
        var child_signal = try ChildSignalSource.init(io);
        errdefer child_signal.deinitUnregistered(io);
        var interrupt_signal = try InterruptSignalSource.init(io);
        errdefer interrupt_signal.deinitUnregistered(io);
        var loop = try event_loop.EventLoop.init();
        errdefer loop.deinit();
        try loop.addReadFd(tty.fd.handle, .tty_input);
        try loop.addReadFd(prompt_redraw.read.handle, .prompt_redraw);
        try loop.addReadFd(completion_wake.read.handle, .completion_result);
        try loop.addReadFd(trap_signal.read.handle, .trap_signal);
        try loop.addReadFd(resize.readFd(), .resize);
        try loop.addReadFd(child_signal.readFd(), .child_signal);
        try loop.addReadFd(interrupt_signal.readFd(), .interrupt_signal);

        const winsize = tty.getWinsize() catch vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };

        const self: TerminalSession = .{
            .allocator = allocator,
            .io = io,
            .tty_buffer = tty_buffer,
            .tty = tty,
            .prompt_redraw = prompt_redraw,
            .completion_wake = completion_wake,
            .trap_signal = trap_signal,
            .resize = resize,
            .child_signal = child_signal,
            .interrupt_signal = interrupt_signal,
            .loop = loop,
            .terminal_parser = .init(allocator),
            .completion = .init(allocator),
            .winsize = winsize,
        };
        return self;
    }

    pub fn deinit(self: *TerminalSession) void {
        // ziglint-ignore: Z026 best-effort terminal cleanup during deinit
        writeTtyAll(&self.tty, completion_progress_stop) catch {};
        self.resetTerminalCapabilities();
        self.events.deinit(self.allocator);
        self.completion.deinit();
        self.terminal_parser.deinit();
        self.renderer.deinit(self.allocator);
        self.interrupt_signal.deinit(self.io, &self.loop);
        self.child_signal.deinit(self.io, &self.loop);
        self.resize.deinit(self.io, &self.loop);
        self.loop.deinit();
        self.trap_signal.close(self.io);
        self.completion_wake.close(self.io);
        self.prompt_redraw.close(self.io);
        deinitPosixTtyPreserveInput(self.tty);
        self.allocator.free(self.tty_buffer);
        self.* = undefined;
    }

    pub fn suspendRawMode(self: *TerminalSession) !void {
        try std.posix.tcsetattr(self.tty.fd.handle, .DRAIN, self.tty.termios);
    }

    pub fn resumeRawMode(self: *TerminalSession) !void {
        _ = try makeRawPreserveInput(self.tty.fd.handle);
    }

    pub fn leaveEditorMode(self: *TerminalSession) !void {
        self.renderer.reset(self.allocator);
        self.suspendTerminalCapabilities();
        self.query_batch_sent = false;
        try self.suspendRawMode();
    }

    pub fn enterEditorMode(self: *TerminalSession) !void {
        try self.resumeRawMode();
        try self.resumeTerminalCapabilities();
        try self.writeInitialQuerySequences();
        self.query_batch_sent = true;
    }

    fn writeInitialQuerySequences(self: *TerminalSession) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try self.capabilities.appendInitialQuerySequences(self.allocator, &output);
        try self.writeTerminalSequence(output.items);
    }

    fn writeQuerySequences(self: *TerminalSession) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try self.capabilities.appendQuerySequences(self.allocator, &output);
        try self.writeTerminalSequence(output.items);
    }

    fn writeColorReportQueries(self: *TerminalSession) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try self.capabilities.appendColorReportQueries(self.allocator, &output);
        try self.writeTerminalSequence(output.items);
    }

    fn applyTerminalCapability(self: *TerminalSession, capability: Capability) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try self.capabilities.appendApplySequence(self.allocator, &output, capability);
        try self.writeTerminalSequence(output.items);
    }

    fn suspendTerminalCapabilities(self: *TerminalSession) void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        self.capabilities.appendSuspendSequences(self.allocator, &output) catch |err| {
            log.debug("failed to plan terminal capability suspension: {}", .{err});
            return;
        };
        self.writeTerminalSequence(output.items) catch |err| {
            log.debug("failed to suspend terminal capabilities: {}", .{err});
        };
    }

    fn resumeTerminalCapabilities(self: *TerminalSession) !void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try self.capabilities.appendResumeSequences(self.allocator, &output);
        try self.writeTerminalSequence(output.items);
    }

    fn resetTerminalCapabilities(self: *TerminalSession) void {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        self.capabilities.appendResetSequences(self.allocator, &output) catch |err| {
            log.debug("failed to plan terminal capability reset: {}", .{err});
            return;
        };
        self.writeTerminalSequence(output.items) catch |err| {
            log.debug("failed to reset terminal capabilities: {}", .{err});
        };
    }

    fn writeTerminalSequence(self: *TerminalSession, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try writeTtyAll(&self.tty, bytes);
    }

    pub fn currentWinsize(self: TerminalSession) vaxis.Winsize {
        return self.winsize;
    }

    pub fn refreshWinsize(self: *TerminalSession) void {
        self.winsize = self.tty.getWinsize() catch self.winsize;
    }

    pub fn reportCurrentDirectory(self: *TerminalSession, cwd: []const u8, hostname: []const u8) !void {
        const host = if (hostname.len != 0) hostname else "localhost";
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try writer.writer.writeAll("\x1b]7;file://");
        try writer.writer.print("{f}", .{std.fmt.alt(std.Uri.Component{ .raw = host }, .formatHost)});
        try writer.writer.print("{f}", .{std.fmt.alt(std.Uri.Component{ .raw = cwd }, .formatPath)});
        try writer.writer.writeByte(0x07);
        try writeTtyAll(&self.tty, writer.written());
    }

    pub fn reportWindowTitle(self: *TerminalSession, title: []const u8) !void {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        try writer.writer.writeAll("\x1b]0;");
        try appendOscText(&writer.writer, title);
        try writer.writer.writeAll("\x1b\\");
        try writeTtyAll(&self.tty, writer.written());
    }

    pub fn requestPromptRedraw(self: *TerminalSession) void {
        // ziglint-ignore: Z026 best-effort wakeup; the next input event can redraw
        rawWriteAll(self.prompt_redraw.write.handle, "p") catch {};
    }

    pub fn promptRedrawWakeFd(self: TerminalSession) std.posix.fd_t {
        return self.prompt_redraw.write.handle;
    }

    /// Registers an external pipe read end (e.g. prompt async command output)
    /// so `readLine` wakes and pumps it on the main thread. The fd is made
    /// nonblocking so pumping can never stall the editor.
    pub fn addPromptAsyncFd(self: *TerminalSession, fd: std.posix.fd_t) !void {
        try setNonBlocking(fd);
        try self.loop.addReadFd(fd, .prompt_async);
    }

    pub fn removePromptAsyncFd(self: *TerminalSession, fd: std.posix.fd_t) void {
        // ziglint-ignore: Z026 best-effort unregistration; a closed fd drops out of the loop anyway
        self.loop.removeFd(fd) catch {};
    }

    pub fn ttyFd(self: TerminalSession) std.posix.fd_t {
        return self.tty.fd.handle;
    }

    pub fn trapSignalWakeFd(self: TerminalSession) std.posix.fd_t {
        return self.trap_signal.write.handle;
    }

    pub fn finishSemanticCommand(self: *TerminalSession, status: u8) !void {
        const sequence = try std.fmt.allocPrint(self.allocator, "\x1b]133;D;{d}\x07", .{status});
        defer self.allocator.free(sequence);
        try writeTtyAll(&self.tty, sequence);
    }

    pub fn readLine(self: *TerminalSession, options: ReadLineOptions) !ReadLineResult {
        if (!self.query_batch_sent) {
            try self.writeInitialQuerySequences();
            self.query_batch_sent = true;
        }
        var read_options = options;

        var session = try line_editor.LineSession.initWithEditingMode(self.allocator, .{
            .bytes = read_options.prompt,
            .visible_width = line_editor.visibleWidth(read_options.prompt, self.capabilities.widthMethod()),
        }, read_options.history, read_options.editing_mode);
        defer session.deinit();

        try writeTtyAll(&self.tty, semantic_command_start);
        try renderSession(
            self.allocator,
            self.io,
            &self.tty,
            &self.renderer,
            &session,
            self.capabilities,
            self.winsize,
            read_options,
        );
        var next_prompt_refresh_ms: ?u64 = if (read_options.prompt_refresh_interval_ms) |interval_ms|
            nowMs(self.io) + interval_ms
        else
            null;
        var next_completion_flash_clear_ms: ?u64 = null;
        var next_hook_interval_ms = try nextHookIntervalDeadlineMs(read_options, self.io);
        var completion_async_event_active = self.completion.active != null;
        read_loop: while (true) {
            while (session.state == .editing or session.state == .history_search) {
                var render_needed = false;
                var loop_events: [8]event_loop.Event = undefined;
                const wait_now_ms = nowMs(self.io);
                const ready = try self.loop.waitTimeout(&loop_events, nextWaitMs(
                    self.io,
                    next_prompt_refresh_ms,
                    next_hook_interval_ms,
                    self.completion.debounceWaitMs(wait_now_ms),
                    next_completion_flash_clear_ms,
                    self.completion.progressWaitMs(wait_now_ms),
                ));
                if (ready.len == 0 and self.completion.progressWaitMs(nowMs(self.io)) == 0) {
                    try self.startCompletionProgress();
                }
                if (ready.len == 0 and
                    next_hook_interval_ms != null and
                    promptRefreshWaitMs(self.io, next_hook_interval_ms) == 0)
                {
                    if (try self.runHooks(read_options, &session, &render_needed)) {
                        return self.finishInterruptedReadLine();
                    }
                    next_hook_interval_ms = try nextHookIntervalDeadlineMs(read_options, self.io);
                }
                if (ready.len == 0 and
                    next_completion_flash_clear_ms != null and
                    promptRefreshWaitMs(self.io, next_completion_flash_clear_ms) == 0)
                {
                    render_needed = true;
                    next_completion_flash_clear_ms = null;
                }
                if (ready.len == 0 and
                    next_prompt_refresh_ms != null and
                    promptRefreshWaitMs(self.io, next_prompt_refresh_ms) == 0)
                {
                    render_needed = true;
                    session.invalidatePrompt();
                    next_prompt_refresh_ms = nowMs(self.io) + read_options.prompt_refresh_interval_ms.?;
                }
                try self.startReadyCompletion(read_options);
                if (try self.syncCompletionActivityEvent(
                    read_options,
                    &session,
                    &render_needed,
                    &completion_async_event_active,
                )) return self.finishInterruptedReadLine();
                self.events.clearRetainingCapacity();
                self.terminal_parser.resetEventText();
                var hook_ready = false;
                for (ready) |ready_event| {
                    switch (ready_event.source) {
                        .tty_input => try self.processTtyInput(),
                        .resize => try self.processResizeSignal(),
                        .prompt_redraw => try self.processPromptRedraw(),
                        .prompt_async => {
                            if (read_options.pump_prompt_async) |pump| pump(read_options.prompt_async_context.?);
                        },
                        .completion_result => {
                            if (try self.processCompletionResult(&session)) render_needed = true;
                        },
                        .child_signal => {
                            self.processChildSignal();
                            hook_ready = true;
                        },
                        .interrupt_signal => {
                            self.processInterruptSignal();
                            try session.cancel();
                        },
                        .trap_signal => {
                            self.processTrapSignal();
                            hook_ready = true;
                        },
                    }
                }
                if (hook_ready) {
                    if (try self.runHooks(read_options, &session, &render_needed)) {
                        return self.finishInterruptedReadLine();
                    }
                    next_hook_interval_ms = try nextHookIntervalDeadlineMs(read_options, self.io);
                }
                var reported_invalid_utf8 = false;
                for (self.events.items) |event| {
                    switch (event) {
                        .key_press => |key| {
                            render_needed = true;
                            try self.handleKeyPress(read_options, &session, key);
                            if (try self.processHistoryRequests(read_options, &session)) render_needed = true;
                            if (try self.processViAliasLookupRequests(read_options, &session)) render_needed = true;
                            if (try self.processPathExpansionRequest(read_options, &session)) render_needed = true;
                        },
                        .paste_start => {
                            render_needed = true;
                            session.beginPaste();
                        },
                        .paste => |text| {
                            render_needed = true;
                            try session.handlePaste(text);
                        },
                        .paste_end => {
                            render_needed = true;
                            session.endPaste();
                        },
                        .invalid_utf8 => {
                            if (!reported_invalid_utf8) {
                                reported_invalid_utf8 = true;
                                render_needed = true;
                                session.invalidatePrompt();
                                try self.writeInterruptOutput("rush: ignored invalid UTF-8 input\n");
                            }
                        },
                        .resize => |winsize| {
                            if (!sameWinsize(self.winsize, winsize)) {
                                render_needed = true;
                                self.winsize = winsize;
                                self.renderer.reset(self.allocator);
                            }
                        },
                        .capability => |capability| {
                            render_needed = true;
                            try self.applyTerminalCapability(capability);
                            if (capability == .da1 and
                                read_options.refresh_style != null and
                                read_options.style_context != null)
                            {
                                read_options.theme = try read_options.refresh_style.?(
                                    read_options.style_context.?,
                                    self.allocator,
                                    self.io,
                                    self.color_scheme,
                                );
                            }
                        },
                        .color_scheme => |scheme| {
                            self.color_scheme = scheme;
                            try self.writeColorReportQueries();
                            try self.writeQuerySequences();
                            if (read_options.refresh_style != null and read_options.style_context != null) {
                                read_options.theme = try read_options.refresh_style.?(
                                    read_options.style_context.?,
                                    self.allocator,
                                    self.io,
                                    scheme,
                                );
                                render_needed = true;
                            }
                        },
                        .color_report => |report| {
                            if (read_options.refresh_color_report != null and read_options.style_context != null) {
                                read_options.theme = try read_options.refresh_color_report.?(
                                    read_options.style_context.?,
                                    self.allocator,
                                    self.io,
                                    report,
                                );
                                render_needed = true;
                            }
                        },
                        .prompt_redraw => {
                            render_needed = true;
                            session.invalidatePrompt();
                        },
                        .key_release, .focus_in, .focus_out => {},
                    }
                }
                if (session.state == .editing or session.state == .history_search) {
                    try self.startReadyCompletion(read_options);
                    if (try self.syncCompletionActivityEvent(
                        read_options,
                        &session,
                        &render_needed,
                        &completion_async_event_active,
                    )) return self.finishInterruptedReadLine();
                    if (render_needed) {
                        if (session.takePromptInvalidation() and
                            read_options.refresh_prompt != null and
                            read_options.prompt_context != null)
                        {
                            const prompt = try read_options.refresh_prompt.?(
                                read_options.prompt_context.?,
                                self.allocator,
                                self.io,
                            );
                            defer self.allocator.free(prompt);
                            try session.replacePrompt(.{
                                .bytes = prompt,
                                .visible_width = line_editor.visibleWidth(prompt, self.capabilities.widthMethod()),
                            });
                        }
                        if (session.takeClearScreenRequest()) {
                            self.renderer.reset(self.allocator);
                            try writeTtyAll(&self.tty, "\x1b[H\x1b[2J");
                        }
                        const rendered_completion_flash = session.hasCompletionFlash();
                        try renderSession(
                            self.allocator,
                            self.io,
                            &self.tty,
                            &self.renderer,
                            &session,
                            self.capabilities,
                            self.winsize,
                            read_options,
                        );
                        if (rendered_completion_flash) {
                            next_completion_flash_clear_ms = nowMs(self.io) + completion_flash_ms;
                        }
                    }
                }
            }

            switch (session.state) {
                .history_search => unreachable,
                .external_editor => {
                    const edited = self.runExternalEditor(read_options, &session) catch null;
                    if (edited) |text| {
                        defer self.allocator.free(text);
                        try session.acceptExternalEditorResult(text);
                    } else {
                        session.resumeEditingAfterExternalEditor();
                        try renderSession(
                            self.allocator,
                            self.io,
                            &self.tty,
                            &self.renderer,
                            &session,
                            self.capabilities,
                            self.winsize,
                            read_options,
                        );
                        continue :read_loop;
                    }
                    continue :read_loop;
                },
                .submitted => {
                    self.quiesceCompletionWorker();
                    if (completion_async_event_active) {
                        var render_needed = false;
                        if (try self.runActivityEvent(
                            read_options,
                            &session,
                            &render_needed,
                            "completion.async.end",
                            &.{ "completion", "0" },
                        )) return self.finishInterruptedReadLine();
                        completion_async_event_active = false;
                    }
                    // Accepting the line may have rewritten the buffer (e.g.
                    // abbreviation expansion on Enter); paint the final text so
                    // the scrollback shows the command that actually runs.
                    try renderSession(
                        self.allocator,
                        self.io,
                        &self.tty,
                        &self.renderer,
                        &session,
                        self.capabilities,
                        self.winsize,
                        read_options,
                    );
                    try self.handoffSubmittedInput();
                    self.renderer.reset(self.allocator);
                    try writeTtyAll(&self.tty, semantic_input_end ++ "\r\n");
                    return .{ .submitted = session.takeSubmittedLine().? };
                },
                .canceled => {
                    self.quiesceCompletionWorker();
                    if (completion_async_event_active) {
                        var render_needed = false;
                        if (try self.runActivityEvent(
                            read_options,
                            &session,
                            &render_needed,
                            "completion.async.end",
                            &.{ "completion", "0" },
                        )) return self.finishInterruptedReadLine();
                        completion_async_event_active = false;
                    }
                    try self.clearRenderedRowsAfterFirst();
                    self.renderer.reset(self.allocator);
                    try writeTtyAll(&self.tty, semantic_input_cancel ++ "^C\r\n");
                    return .canceled;
                },
                .eof => {
                    self.quiesceCompletionWorker();
                    if (completion_async_event_active) {
                        var render_needed = false;
                        if (try self.runActivityEvent(
                            read_options,
                            &session,
                            &render_needed,
                            "completion.async.end",
                            &.{ "completion", "0" },
                        )) return self.finishInterruptedReadLine();
                        completion_async_event_active = false;
                    }
                    try self.clearRenderedRowsAfterFirst();
                    self.renderer.reset(self.allocator);
                    try writeTtyAll(&self.tty, "\r\n");
                    return .eof;
                },
                .editing => unreachable,
            }
        }
    }

    /// Cancels and joins any active completion worker thread.
    ///
    /// Must run before `readLine` hands control back to the shell: the shell
    /// forks children that keep allocating (subshells, command substitutions),
    /// and a forked child inherits any allocator lock a live worker thread
    /// happens to hold at that instant, deadlocking the child.
    fn quiesceCompletionWorker(self: *TerminalSession) void {
        const completion_thread = self.completion.active orelse return;
        self.completion.active = null;
        completion_thread.cancel.cancel();
        completion_thread.thread.join();
        // ziglint-ignore: Z026 best-effort terminal progress cleanup
        if (self.completion.progress_started) writeTtyAll(&self.tty, completion_progress_stop) catch {};
        self.completion.progress_started = false;
        self.completion.progress_deadline_ms = null;
        if (completion_thread.takeResult()) |result| result.deinit(self.allocator);
        completion_thread.deinit();
        self.allocator.destroy(completion_thread);
    }

    fn finishInterruptedReadLine(self: *TerminalSession) !ReadLineResult {
        self.quiesceCompletionWorker();
        try self.clearRenderedRowsAfterFirst();
        self.renderer.reset(self.allocator);
        try writeTtyAll(&self.tty, semantic_input_cancel ++ "\r\n");
        return .interrupted;
    }

    fn handleKeyPress(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
        key: line_editor.KeyEvent,
    ) !void {
        const has_provider = hasCompletionProvider(options);
        switch (planKeyPress(key, session.hasCompletionMenu(), has_provider)) {
            .menu_tab => try session.handleKey(.{ .key = .tab, .modifiers = key.modifiers }),
            .explicit_completion => {
                _ = try expandAbbreviationBeforeAccept(session, options, false);
                try self.applyCompletionProvider(options, session, .explicit);
            },
            .enter_accept => {
                _ = try expandAbbreviationBeforeAccept(session, options, false);
                try session.handleKey(key);
            },
            .space_accept => {
                if (try expandAbbreviationBeforeAccept(session, options, true)) return;
                try self.handleEditableCompletionKey(options, session, key, has_provider);
            },
            .refresh_completion => try self.handleEditableCompletionKey(options, session, key, has_provider),
            .edit => try session.handleKey(key),
        }
    }

    fn handleEditableCompletionKey(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
        key: line_editor.KeyEvent,
        has_provider: bool,
    ) !void {
        try session.handleKey(key);
        if (!session.hasCompletionMenu() or !has_provider) return;
        try self.applyCompletionProvider(options, session, .refresh);
    }

    fn applyCompletionProvider(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
        reason: CompletionRequestReason,
    ) !void {
        if (options.clone_completion_context != null and options.free_completion_context != null) {
            try self.requestCompletion(
                options,
                session.editor.buffer.text(),
                session.editor.buffer.cursor_byte,
                reason,
            );
            return;
        }
        const application = try options.complete.?(
            options.completion_context.?,
            self.allocator,
            self.io,
            session.editor.buffer.text(),
            session.editor.buffer.cursor_byte,
        );
        defer application.deinit(self.allocator);
        try session.applyCompletion(application);
    }

    fn runExternalEditor(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
    ) ![]const u8 {
        const request = session.takeExternalEditorRequest() orelse return error.MissingExternalEditorRequest;
        defer request.deinit(self.allocator);

        try self.clearRenderedRowsAfterFirst();
        self.renderer.reset(self.allocator);
        try writeTtyAll(&self.tty, "\r\n");

        try self.leaveEditorMode();
        var editor_mode_left = true;
        defer if (editor_mode_left) self.enterEditorMode() catch {};

        const edited = try editCommandWithExternalEditor(self.allocator, self.io, options, request.text);
        try self.enterEditorMode();
        editor_mode_left = false;
        return edited;
    }

    fn runHooks(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
        render_needed: *bool,
    ) !bool {
        if (options.run_hooks == null or options.hook_context == null) return false;
        const hook_result = try options.run_hooks.?(options.hook_context.?, self.allocator, self.io);
        defer self.allocator.free(hook_result.output);
        if (hook_result.output.len != 0) try self.writeInterruptOutput(hook_result.output);
        if (hook_result.refresh_prompt or hook_result.output.len != 0) {
            render_needed.* = true;
            session.invalidatePrompt();
        }
        return hook_result.stop;
    }

    fn syncCompletionActivityEvent(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
        render_needed: *bool,
        event_active: *bool,
    ) !bool {
        const active = self.completion.active != null;
        if (active == event_active.*) return false;
        event_active.* = active;
        return self.runActivityEvent(
            options,
            session,
            render_needed,
            if (active) "completion.async.start" else "completion.async.end",
            if (active) &.{ "completion", "1" } else &.{ "completion", "0" },
        );
    }

    fn runActivityEvent(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
        render_needed: *bool,
        event_name: []const u8,
        args: []const []const u8,
    ) !bool {
        if (options.run_activity_event == null or options.hook_context == null) return false;
        const hook_result = try options.run_activity_event.?(
            options.hook_context.?,
            self.allocator,
            self.io,
            event_name,
            args,
        );
        defer self.allocator.free(hook_result.output);
        if (hook_result.output.len != 0) try self.writeInterruptOutput(hook_result.output);
        if (hook_result.refresh_prompt or hook_result.output.len != 0) {
            render_needed.* = true;
            session.invalidatePrompt();
        }
        return hook_result.stop;
    }

    fn processViAliasLookupRequests(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
    ) !bool {
        var processed = false;
        while (session.takeViAliasLookupRequest()) |letter| {
            processed = true;
            const value = if (options.lookup_vi_alias != null and options.vi_alias_context != null)
                try options.lookup_vi_alias.?(options.vi_alias_context.?, self.allocator, letter)
            else
                null;
            defer if (value) |bytes| self.allocator.free(bytes);
            try session.applyViAliasResult(letter, value);
        }
        return processed;
    }

    fn processHistoryRequests(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
    ) !bool {
        return drainHistoryRequests(self.allocator, options.history, session);
    }

    fn processPathExpansionRequest(
        self: *TerminalSession,
        options: ReadLineOptions,
        session: *line_editor.LineSession,
    ) !bool {
        const request = session.takePathExpansionRequest() orelse return false;
        defer request.deinit(self.allocator);
        const expand_pathname = options.expand_pathname orelse return false;
        const context = options.path_expansion_context orelse return false;
        const matches = try expand_pathname(context, self.allocator, self.io, request.word);
        defer matches.deinit(self.allocator);

        if (request.command == .list) {
            const output = try line_editor.pathExpansionListOutput(self.allocator, matches);
            defer self.allocator.free(output);
            if (output.len != 0) {
                try self.writeInterruptOutput(output);
                session.invalidatePrompt();
                return true;
            }
            return false;
        }

        return session.applyPathExpansion(request, matches);
    }

    fn clearRenderedRowsAfterFirst(self: *TerminalSession) !void {
        const clear = try self.renderer.clearRowsAfterFirst(self.allocator);
        defer self.allocator.free(clear);
        try writeTtyAll(&self.tty, clear);
    }

    fn handoffSubmittedInput(self: *TerminalSession) !void {
        const handoff = try self.renderer.submittedHandoff(self.allocator);
        defer self.allocator.free(handoff);
        try writeTtyAll(&self.tty, handoff);
    }

    fn writeInterruptOutput(self: *TerminalSession, output: []const u8) !void {
        const prefix = try self.renderer.interruptOutputPrefix(self.allocator);
        defer self.allocator.free(prefix);
        try writeTtyAll(&self.tty, prefix);
        self.renderer.reset(self.allocator);
        try writeTtyText(&self.tty, output);
    }

    fn processTtyInput(self: *TerminalSession) !void {
        var buffer: [read_chunk_size]u8 = undefined;
        const n = rawRead(self.tty.fd.handle, &buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        const bytes = buffer[0..n];
        const old_len = self.events.items.len;
        try self.terminal_parser.feed(bytes, &self.events);
        for (self.events.items[old_len..]) |event| {
            if (event == .resize and !self.capabilities.in_band_resize) {
                self.capabilities.in_band_resize = true;
                try self.resize.disable(self.io, &self.loop);
            }
        }
    }

    fn processResizeSignal(self: *TerminalSession) !void {
        self.resize.drain();
        const winsize = self.tty.getWinsize() catch return;
        if (sameWinsize(self.winsize, winsize)) return;
        try self.events.append(self.allocator, .{ .resize = winsize });
    }

    fn processPromptRedraw(self: *TerminalSession) !void {
        var buffer: [32]u8 = undefined;
        _ = rawRead(self.prompt_redraw.read.handle, &buffer) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        try self.events.append(self.allocator, .prompt_redraw);
    }

    fn processChildSignal(self: *TerminalSession) void {
        self.child_signal.drain();
    }

    fn processTrapSignal(self: *TerminalSession) void {
        var buffer: [64]u8 = undefined;
        // ziglint-ignore: Z026 best-effort signal-pipe drain
        _ = rawRead(self.trap_signal.read.handle, &buffer) catch {};
    }

    fn processInterruptSignal(self: *TerminalSession) void {
        self.interrupt_signal.drain();
    }

    fn requestCompletion(
        self: *TerminalSession,
        options: ReadLineOptions,
        source: []const u8,
        cursor: usize,
        reason: CompletionRequestReason,
    ) !void {
        if (options.complete == null or options.completion_context == null) return;
        try self.completion.request(nowMs(self.io), source, cursor, reason);
        try self.startReadyCompletion(options);
    }

    fn startReadyCompletion(self: *TerminalSession, options: ReadLineOptions) !void {
        var request = self.completion.takeReadyRequest(nowMs(self.io)) orelse return;
        errdefer request.deinit(self.allocator);
        const clone = options.clone_completion_context orelse return;
        const free = options.free_completion_context orelse return;
        const completion_thread = try self.allocator.create(CompletionWorker);
        errdefer self.allocator.destroy(completion_thread);
        completion_thread.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .complete = options.complete,
            .free_context = free,
            .request = request,
            .context = null,
            .wake_fd = self.completion_wake.write.handle,
        };
        errdefer completion_thread.deinit();
        const context = try clone(options.completion_context.?, self.allocator, &completion_thread.cancel);
        completion_thread.context = context;
        request = undefined;
        try completion_thread.start();
        self.completion.active = completion_thread;
        self.completion.progress_deadline_ms = nowMs(self.io) + completion_progress_delay_ms;
        self.completion.progress_started = false;
    }

    fn startCompletionProgress(self: *TerminalSession) !void {
        if (self.completion.active == null or self.completion.progress_started) return;
        self.completion.progress_started = true;
        self.completion.progress_deadline_ms = null;
        try writeTtyAll(&self.tty, completion_progress_start);
    }

    fn processCompletionResult(self: *TerminalSession, session: *line_editor.LineSession) !bool {
        var buffer: [32]u8 = undefined;
        // ziglint-ignore: Z026 best-effort completion wake-pipe drain
        _ = rawRead(self.completion_wake.read.handle, &buffer) catch {};
        const completion_thread = self.completion.active orelse return false;
        if (!completion_thread.done.load(.acquire)) return false;
        self.completion.active = null;
        completion_thread.thread.join();
        // ziglint-ignore: Z026 best-effort terminal progress cleanup
        if (self.completion.progress_started) writeTtyAll(&self.tty, completion_progress_stop) catch {};
        self.completion.progress_started = false;
        self.completion.progress_deadline_ms = null;
        const result = completion_thread.takeResult();
        completion_thread.deinit();
        self.allocator.destroy(completion_thread);
        const completion_result = result orelse return false;
        defer completion_result.deinit(self.allocator);
        switch (completion_result) {
            .success => |payload| {
                if (self.completion.hasSupersedingRequest(payload.generation)) return false;
                if (!std.mem.eql(u8, session.editor.buffer.text(), payload.source)) return false;
                if (session.editor.buffer.cursor_byte != payload.cursor) return false;
                try session.applyCompletion(payload.application);
                return true;
            },
            .failed => return false,
        }
    }
};

fn drainHistoryRequests(
    allocator: std.mem.Allocator,
    history: line_editor.HistoryView,
    session: *line_editor.LineSession,
) !bool {
    var processed = false;
    while (session.takeHistoryRequest()) |request| {
        defer request.deinit(allocator);
        processed = true;
        const result = try resolveHistoryRequest(allocator, history, request);
        try session.applyHistoryResult(request, result);
    }
    return processed;
}

fn resolveHistoryRequest(
    allocator: std.mem.Allocator,
    history: line_editor.HistoryView,
    request: line_editor.HistoryRequest,
) !line_editor.HistoryResult {
    const context = history.context orelse return emptyHistoryResult(request);
    return switch (request) {
        .previous => |previous| .{ .entry = if (history.previous) |callback|
            try callback(context, allocator, previous.prefix, previous.before)
        else
            null },
        .next => |next| .{ .entry = if (history.next) |callback|
            try callback(context, allocator, next.prefix, next.after)
        else
            null },
        .by_number => |number| .{ .entry = if (history.by_number) |callback|
            try callback(context, allocator, number)
        else
            null },
        .search => |search| .{ .entries = try resolveHistorySearch(
            allocator,
            history,
            context,
            search.query,
            search.before,
        ) },
        .search_next => |search| .{ .entries = try resolveHistorySearchNext(
            allocator,
            history,
            context,
            search.query,
            search.after,
        ) },
        .suggest => |prefix| .{ .entry = if (history.suggest) |callback|
            try callback(context, allocator, prefix)
        else
            null },
    };
}

fn emptyHistoryResult(request: line_editor.HistoryRequest) line_editor.HistoryResult {
    return switch (request) {
        .search, .search_next => .{ .entries = &.{} },
        .previous,
        .next,
        .by_number,
        .suggest,
        => .{ .entry = null },
    };
}

fn resolveHistorySearch(
    allocator: std.mem.Allocator,
    history: line_editor.HistoryView,
    context: *anyopaque,
    query: []const u8,
    before: ?i64,
) ![]line_editor.HistoryView.HistoryEntry {
    const search = history.search orelse return &.{};
    var matches: std.ArrayList(line_editor.HistoryView.HistoryEntry) = .empty;
    errdefer {
        for (matches.items) |entry| entry.deinit(allocator);
        matches.deinit(allocator);
    }
    try appendHistorySearchEntries(allocator, &matches, search, context, query, before);
    if (matches.items.len == 0 and before != null) {
        try appendHistorySearchEntries(allocator, &matches, search, context, query, null);
    }
    return matches.toOwnedSlice(allocator);
}

fn resolveHistorySearchNext(
    allocator: std.mem.Allocator,
    history: line_editor.HistoryView,
    context: *anyopaque,
    query: []const u8,
    after: ?i64,
) ![]line_editor.HistoryView.HistoryEntry {
    const search_next = history.search_next orelse
        return resolveHistorySearch(allocator, history, context, query, null);
    var matches: std.ArrayList(line_editor.HistoryView.HistoryEntry) = .empty;
    errdefer {
        for (matches.items) |entry| entry.deinit(allocator);
        matches.deinit(allocator);
    }
    try appendHistorySearchEntries(allocator, &matches, search_next, context, query, after);
    if (matches.items.len == 0 and after != null) {
        try appendHistorySearchEntries(allocator, &matches, search_next, context, query, null);
    }
    return matches.toOwnedSlice(allocator);
}

const HistorySearchCallback = *const fn (
    *anyopaque,
    std.mem.Allocator,
    []const u8,
    ?i64,
) anyerror!?line_editor.HistoryView.HistoryEntry;

fn appendHistorySearchEntries(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(line_editor.HistoryView.HistoryEntry),
    callback: HistorySearchCallback,
    context: *anyopaque,
    query: []const u8,
    start_cursor: ?i64,
) !void {
    var cursor = start_cursor;
    while (matches.items.len < 20) {
        const entry = try callback(context, allocator, query, cursor) orelse break;
        cursor = entry.id;
        try matches.append(allocator, entry);
    }
}

const ExternalEditorTempFile = struct {
    dir: std.Io.Dir,
    sub_path: []const u8,
    path: []const u8,

    fn deinit(self: ExternalEditorTempFile, allocator: std.mem.Allocator, io: std.Io) void {
        // ziglint-ignore: Z026 best-effort temporary file cleanup
        self.dir.deleteFile(io, self.sub_path) catch {};
        self.dir.close(io);
        allocator.free(self.path);
        allocator.free(self.sub_path);
    }
};

fn editCommandWithExternalEditor(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ReadLineOptions,
    initial_text: []const u8,
) ![]const u8 {
    const temp = try createExternalEditorTempFile(allocator, io, options.external_editor_tmpdir, initial_text);
    defer temp.deinit(allocator, io);

    try runExternalEditorCommand(allocator, io, options.external_editor_command, temp.path);
    return temp.dir.readFileAlloc(io, temp.sub_path, allocator, .limited(1024 * 1024));
}

fn createExternalEditorTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmpdir: []const u8,
    initial_text: []const u8,
) !ExternalEditorTempFile {
    var dir = if (std.fs.path.isAbsolute(tmpdir))
        try std.Io.Dir.openDirAbsolute(io, tmpdir, .{})
    else
        try std.Io.Dir.cwd().openDir(io, tmpdir, .{});
    errdefer dir.close(io);

    var attempts: usize = 0;
    while (attempts < 64) : (attempts += 1) {
        const sub_path = try std.fmt.allocPrint(
            allocator,
            "rush-edit-{d}-{d}-{d}.sh",
            .{ std.c.getpid(), nowMs(io), attempts },
        );
        errdefer allocator.free(sub_path);
        var file = dir.createFile(io, sub_path, .{
            .read = true,
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(sub_path);
                continue;
            },
            else => |e| return e,
        };
        defer file.close(io);
        try file.writeStreamingAll(io, initial_text);
        if (initial_text.len != 0 and initial_text[initial_text.len - 1] != '\n') try file.writeStreamingAll(io, "\n");
        const path = try std.fs.path.join(allocator, &.{ tmpdir, sub_path });
        return .{ .dir = dir, .sub_path = sub_path, .path = path };
    }
    return error.TemporaryNameExhausted;
}

fn runExternalEditorCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor_command: []const u8,
    path: []const u8,
) !void {
    const command = try std.fmt.allocPrint(allocator, "exec {s} \"$1\"", .{editor_command});
    defer allocator.free(command);
    const argv = [_][]const u8{ "/bin/sh", "-c", command, "rush-editor", path };
    var child = try std.process.spawn(io, .{ .argv = &argv });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ExternalEditorFailed,
        .signal, .stopped, .unknown => return error.ExternalEditorFailed,
    }
}

fn isCompletionTab(key: line_editor.KeyEvent) bool {
    return key.key == .tab or (key.key == .text and std.mem.eql(u8, key.text, "\t"));
}

fn isSpaceAccept(key: line_editor.KeyEvent) bool {
    return key.key == .text and std.mem.eql(u8, key.text, " ");
}

const KeyPressPlan = enum {
    menu_tab,
    explicit_completion,
    enter_accept,
    space_accept,
    refresh_completion,
    edit,
};

fn planKeyPress(
    key: line_editor.KeyEvent,
    has_completion_menu: bool,
    has_completion_provider: bool,
) KeyPressPlan {
    if (isCompletionTab(key) and has_completion_menu) return .menu_tab;
    if (isCompletionTab(key) and has_completion_provider) return .explicit_completion;
    if (key.key == .enter and !has_completion_menu) return .enter_accept;
    if (isSpaceAccept(key)) return .space_accept;
    if (has_completion_menu and
        shouldRefreshCompletionMenu(key) and
        has_completion_provider)
    {
        return .refresh_completion;
    }
    return .edit;
}

fn hasCompletionProvider(options: ReadLineOptions) bool {
    return options.complete != null and options.completion_context != null;
}

fn shouldRefreshCompletionMenu(key: line_editor.KeyEvent) bool {
    return switch (key.key) {
        .text => key.text.len != 0,
        .transpose_chars,
        .yank,
        => true,
        else => false,
    };
}

fn expandAbbreviationBeforeAccept(
    session: *line_editor.LineSession,
    options: ReadLineOptions,
    append_space: bool,
) !bool {
    if (options.expand_abbreviation == null or options.completion_context == null) return false;
    const edit = try options.expand_abbreviation.?(
        options.completion_context.?,
        session.allocator,
        session.editor.buffer.text(),
        session.editor.buffer.cursor_byte,
        append_space,
    ) orelse return false;
    defer session.allocator.free(edit.replacement);
    try session.applyCompletion(.{ .edit = edit });
    return true;
}

fn sameWinsize(a: vaxis.Winsize, b: vaxis.Winsize) bool {
    return a.rows == b.rows and
        a.cols == b.cols and
        a.x_pixel == b.x_pixel and
        a.y_pixel == b.y_pixel;
}

fn promptRefreshWaitMs(io: std.Io, next_prompt_refresh_ms: ?u64) ?u64 {
    const next = next_prompt_refresh_ms orelse return null;
    const now = nowMs(io);
    if (next <= now) return 0;
    return next - now;
}

fn nextWaitMs(io: std.Io, a: ?u64, b: ?u64, c: ?u64, d: ?u64, e: ?u64) ?u64 {
    var wait_ms: ?u64 = null;
    if (promptRefreshWaitMs(io, a)) |wait| wait_ms = if (wait_ms) |current| @min(current, wait) else wait;
    if (promptRefreshWaitMs(io, b)) |wait| wait_ms = if (wait_ms) |current| @min(current, wait) else wait;
    if (c) |wait| wait_ms = if (wait_ms) |current| @min(current, wait) else wait;
    if (promptRefreshWaitMs(io, d)) |wait| wait_ms = if (wait_ms) |current| @min(current, wait) else wait;
    if (e) |wait| wait_ms = if (wait_ms) |current| @min(current, wait) else wait;
    return wait_ms;
}

fn nextHookIntervalDeadlineMs(options: ReadLineOptions, io: std.Io) !?u64 {
    if (options.next_hook_interval_ms == null or options.hook_context == null) return null;
    const interval_ms = try options.next_hook_interval_ms.?(options.hook_context.?, io) orelse return null;
    return nowMs(io) + interval_ms;
}

fn nowMs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

fn initPosixTtyPreserveInput(io: std.Io, buffer: []u8) !vaxis.tty.PosixTty {
    var file = try std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
    errdefer if (builtin.os.tag != .macos) file.close(io);

    const termios = try makeRawPreserveInput(file.handle);
    const tty: vaxis.tty.PosixTty = .{
        .io = io,
        .termios = termios,
        .fd = file,
        .tty_writer = file.writerStreaming(io, buffer),
    };
    if (!builtin.is_test) vaxis.tty.global_tty = tty;
    return tty;
}

fn deinitPosixTtyPreserveInput(tty: vaxis.tty.PosixTty) void {
    std.posix.tcsetattr(tty.fd.handle, .DRAIN, tty.termios) catch |err| {
        std.log.err("couldn't restore terminal: {}", .{err});
    };
    if (builtin.os.tag != .macos) tty.fd.close(tty.io);
}

fn makeRawPreserveInput(fd: std.posix.fd_t) !std.posix.termios {
    const state = try std.posix.tcgetattr(fd);
    var raw = state;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .DRAIN, raw);
    return state;
}

fn renderSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    tty: *vaxis.tty.PosixTty,
    renderer: *line_editor.FrameRenderer,
    session: *line_editor.LineSession,
    capabilities: TerminalCapabilities,
    winsize: vaxis.Winsize,
    options: ReadLineOptions,
) !void {
    try session.requestAutosuggestion();
    _ = try drainHistoryRequests(allocator, options.history, session);
    const diagnostic = if (options.diagnose != null and options.diagnostic_context != null)
        try options.diagnose.?(options.diagnostic_context.?, allocator, io, session.editor.buffer.text())
    else
        null;
    defer if (diagnostic) |render| render.deinit(allocator);
    var frame = try session.renderFrame(allocator, .{
        .width = winsize.cols,
        .height = winsize.rows,
        .width_method = capabilities.widthMethod(),
        .diagnostic_line = if (diagnostic) |render| render.line else "",
        .diagnostic_spans = if (diagnostic) |render| render.spans else &.{},
        .theme = options.theme,
        .semantic_prompt_marks = true,
    });
    defer frame.deinit(allocator);
    const rendered = try renderer.render(allocator, frame, .{
        .synchronized_output = capabilities.synchronized_output,
    });
    defer allocator.free(rendered);
    try writeTtyAll(tty, rendered);
}

fn appendOscText(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        0x00...0x1f, 0x7f => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    };
}

fn testExpandAbbreviation(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order is fixed by the expand_abbreviation callback signature
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    append_space: bool,
) !?completion.Edit {
    _ = context;
    if (cursor < source.len or !std.mem.eql(u8, source, "gs")) return null;
    return .{
        .replace_start = 0,
        .replace_end = 2,
        .replacement = try allocator.dupe(u8, "git status"),
        .append_space = append_space,
    };
}

test "abbreviation expansion seam rewrites the edit buffer" {
    var session = try line_editor.LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.handleKey(.{ .key = .text, .text = "gs" });
    var context: u8 = 0;

    try std.testing.expect(try expandAbbreviationBeforeAccept(&session, .{
        .prompt = "",
        .completion_context = &context,
        .expand_abbreviation = testExpandAbbreviation,
    }, true));

    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "git status ".len), session.editor.buffer.cursor_byte);
}

test "external editor helper writes reads and removes temporary command file" {
    const tmpdir = "rush-editor-test-tmp";
    try std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir);
    try std.Io.Dir.cwd().createDir(std.testing.io, tmpdir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};

    const edited = try editCommandWithExternalEditor(std.testing.allocator, std.testing.io, .{
        .prompt = "",
        .external_editor_command = "/bin/sh -c 'grep -q original \"$1\" && printf edited > \"$1\"' edit",
        .external_editor_tmpdir = tmpdir,
    }, "original");
    defer std.testing.allocator.free(edited);

    try std.testing.expectEqualStrings("edited", edited);
}

test "external editor helper rejects failed editor commands" {
    const tmpdir = "rush-editor-fail-test-tmp";
    try std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir);
    try std.Io.Dir.cwd().createDir(std.testing.io, tmpdir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};

    try std.testing.expectError(
        error.ExternalEditorFailed,
        editCommandWithExternalEditor(std.testing.allocator, std.testing.io, .{
            .prompt = "",
            .external_editor_command = "false",
            .external_editor_tmpdir = tmpdir,
        }, "original"),
    );
}

test "raw terminal transitions preserve queued pty input" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = close(master);
    defer _ = close(slave);

    const saved = try std.posix.tcgetattr(slave);
    defer std.posix.tcsetattr(slave, .DRAIN, saved) catch {};
    var no_echo = saved;
    no_echo.lflag.ECHO = false;
    try std.posix.tcsetattr(slave, .DRAIN, no_echo);
    try setNonBlocking(slave);

    const queued = "echo queued\n";
    try rawWriteAll(master, queued);
    _ = try makeRawPreserveInput(slave);

    var buffer: [64]u8 = undefined;
    const read_len = try rawRead(slave, &buffer);
    try std.testing.expectEqualStrings(queued, buffer[0..read_len]);
}

test "completion refresh key classification tracks editing keys" {
    try std.testing.expect(shouldRefreshCompletionMenu(.{ .key = .text, .text = "s" }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .text, .text = "" }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .backspace }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .delete }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .delete_previous_word }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .delete_to_start }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .left }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .home }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .word_left }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .tab }));
    try std.testing.expect(!shouldRefreshCompletionMenu(.{ .key = .escape }));
}

test "key press policy separates completion actions from plain editing" {
    try std.testing.expectEqual(
        KeyPressPlan.menu_tab,
        planKeyPress(.{ .key = .tab }, true, true),
    );
    try std.testing.expectEqual(
        KeyPressPlan.explicit_completion,
        planKeyPress(.{ .key = .tab }, false, true),
    );
    try std.testing.expectEqual(
        KeyPressPlan.enter_accept,
        planKeyPress(.{ .key = .enter }, false, true),
    );
    try std.testing.expectEqual(
        KeyPressPlan.edit,
        planKeyPress(.{ .key = .enter }, true, true),
    );
    try std.testing.expectEqual(
        KeyPressPlan.space_accept,
        planKeyPress(.{ .key = .text, .text = " " }, true, true),
    );
    try std.testing.expectEqual(
        KeyPressPlan.refresh_completion,
        planKeyPress(.{ .key = .text, .text = "s" }, true, true),
    );
    try std.testing.expectEqual(
        KeyPressPlan.edit,
        planKeyPress(.{ .key = .text, .text = "s" }, true, false),
    );
}
