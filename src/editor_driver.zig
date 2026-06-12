//! Cooperative driver pieces for the future terminal line editor.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const event_loop = @import("event_loop.zig");
const line_editor = @import("line_editor.zig");
const completion = @import("completion.zig");

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;
extern "c" fn close(fd: c_int) c_int;

const read_chunk_size = 4096;
const invalid_fd: std.posix.fd_t = -1;
const semanticCommandStart = "\x1b]133;A;cl=w\x07";
const semanticInputEnd = "\x1b]133;C\x07";
const semanticInputCancel = "\x1b]133;D;err=CANCEL\x07";
const completionProgressStart = "\x1b]9;4;3\x07";
const completionProgressStop = "\x1b]9;4;0\x07";
const completion_progress_delay_ms = 500;

const ResizeSignalFd = struct {
    var value: std.atomic.Value(std.posix.fd_t) = .init(invalid_fd);
};

const ChildSignalFd = struct {
    var value: std.atomic.Value(std.posix.fd_t) = .init(invalid_fd);
};

const InterruptSignalFd = struct {
    var value: std.atomic.Value(std.posix.fd_t) = .init(invalid_fd);
};

pub const DriverEvent = union(enum) {
    tty_read_ready,
};

pub const TerminalEvent = union(enum) {
    key_press: line_editor.KeyEvent,
    key_release: line_editor.KeyEvent,
    paste: []const u8,
    paste_start,
    paste_end,
    focus_in,
    focus_out,
    resize: vaxis.Winsize,
    capability: Capability,
    color_scheme: ColorScheme,
    color_report: ColorReport,
    prompt_redraw,
};

pub const ColorScheme = enum { dark, light, unknown };

pub const ColorReport = vaxis.Color.Report;

pub const Capability = enum {
    kitty_keyboard,
    kitty_graphics,
    rgb,
    sgr_pixels,
    unicode,
    da1,
    color_scheme_updates,
    multi_cursor,
};

pub const TerminalCapabilities = struct {
    kitty_keyboard: bool = false,
    kitty_graphics: bool = false,
    rgb: bool = false,
    sgr_pixels: bool = false,
    unicode: bool = false,
    da1: bool = false,
    color_scheme_updates: bool = false,
    multi_cursor: bool = false,
    synchronized_output: bool = true,
    bracketed_paste: bool = false,
    in_band_resize_enabled: bool = false,
    in_band_resize: bool = false,

    pub fn widthMethod(self: TerminalCapabilities) vaxis.gwidth.Method {
        return if (self.unicode) .unicode else .wcwidth;
    }

    pub fn sendQueries(self: *TerminalCapabilities, tty: *vaxis.tty.PosixTty) !void {
        try writeTtyAll(
            tty,
            vaxis.ctlseqs.decrqm_sgr_pixels ++
                vaxis.ctlseqs.decrqm_unicode ++
                vaxis.ctlseqs.decrqm_color_scheme ++
                vaxis.ctlseqs.csi_u_query ++
                vaxis.ctlseqs.kitty_graphics_query ++
                vaxis.ctlseqs.multi_cursor_query ++
                vaxis.ctlseqs.primary_device_attrs ++
                vaxis.ctlseqs.in_band_resize_set ++
                vaxis.ctlseqs.bp_set,
        );
        self.bracketed_paste = true;
        self.in_band_resize_enabled = true;
    }

    pub fn requestColorReports(_: TerminalCapabilities, tty: *vaxis.tty.PosixTty) !void {
        try writeTtyAll(tty, vaxis.ctlseqs.osc10_query ++ vaxis.ctlseqs.osc11_query);
        for (0..8) |index| {
            var sequence_buffer: [32]u8 = undefined;
            const sequence = try std.fmt.bufPrint(&sequence_buffer, vaxis.ctlseqs.osc4_query, .{index});
            try writeTtyAll(tty, sequence);
        }
    }

    pub fn sendInitialQueries(self: *TerminalCapabilities, tty: *vaxis.tty.PosixTty) !void {
        try self.requestColorReports(tty);
        try self.sendQueries(tty);
    }

    pub fn apply(self: *TerminalCapabilities, allocator: std.mem.Allocator, tty: *vaxis.tty.PosixTty, capability: Capability) !void {
        switch (capability) {
            .kitty_keyboard => {
                if (!self.kitty_keyboard) {
                    const flags: u5 = @bitCast(vaxis.Key.KittyFlags{});
                    const sequence = try std.fmt.allocPrint(allocator, vaxis.ctlseqs.csi_u_push, .{flags});
                    defer allocator.free(sequence);
                    try writeTtyAll(tty, sequence);
                }
                self.kitty_keyboard = true;
            },
            .kitty_graphics => self.kitty_graphics = true,
            .rgb => self.rgb = true,
            .sgr_pixels => self.sgr_pixels = true,
            .unicode => {
                if (!self.unicode) try writeTtyAll(tty, vaxis.ctlseqs.unicode_set);
                self.unicode = true;
            },
            .da1 => self.da1 = true,
            .color_scheme_updates => {
                if (!self.color_scheme_updates) try writeTtyAll(tty, vaxis.ctlseqs.color_scheme_request ++ vaxis.ctlseqs.color_scheme_set);
                self.color_scheme_updates = true;
            },
            .multi_cursor => self.multi_cursor = true,
        }
    }

    pub fn reset(self: *TerminalCapabilities, tty: *vaxis.tty.PosixTty) void {
        if (self.kitty_keyboard) writeTtyAll(tty, vaxis.ctlseqs.csi_u_pop) catch {};
        if (self.unicode) writeTtyAll(tty, vaxis.ctlseqs.unicode_reset) catch {};
        if (self.in_band_resize_enabled) writeTtyAll(tty, vaxis.ctlseqs.in_band_resize_reset) catch {};
        if (self.bracketed_paste) writeTtyAll(tty, vaxis.ctlseqs.bp_reset) catch {};
        self.kitty_keyboard = false;
        self.unicode = false;
        self.in_band_resize_enabled = false;
        self.in_band_resize = false;
        self.bracketed_paste = false;
    }
};

pub const TerminalParser = struct {
    allocator: std.mem.Allocator,
    parser: vaxis.Parser = undefined,
    pending: std.ArrayList(u8) = .empty,
    event_text: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) TerminalParser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TerminalParser) void {
        self.pending.deinit(self.allocator);
        self.event_text.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn resetEventText(self: *TerminalParser) void {
        self.event_text.clearRetainingCapacity();
    }

    pub fn feed(self: *TerminalParser, bytes: []const u8, events: *std.ArrayList(TerminalEvent)) !void {
        if (self.pending.items.len == 0 and std.mem.eql(u8, bytes, "\x1b")) {
            try events.append(self.allocator, .{ .key_press = .{ .key = .escape } });
            return;
        }

        try self.pending.appendSlice(self.allocator, bytes);
        while (self.pending.items.len != 0) {
            const result = try self.parser.parse(self.pending.items, null);
            if (result.n == 0) break;
            if (result.event) |event| {
                if (try self.eventFromVaxis(event)) |terminal_event| {
                    try events.append(self.allocator, terminal_event);
                }
            }
            self.pending.replaceRange(self.allocator, 0, result.n, "") catch unreachable;
        }
    }

    fn eventFromVaxis(self: *TerminalParser, event: vaxis.Event) !?TerminalEvent {
        return switch (event) {
            .key_press => |key| .{ .key_press = try self.keyEventFromVaxis(key) },
            .key_release => |key| .{ .key_release = try self.keyEventFromVaxis(key) },
            .paste => |text| .{ .paste = try self.eventText(text) },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .focus_in => .focus_in,
            .focus_out => .focus_out,
            .cap_kitty_keyboard => .{ .capability = .kitty_keyboard },
            .cap_kitty_graphics => .{ .capability = .kitty_graphics },
            .cap_rgb => .{ .capability = .rgb },
            .cap_sgr_pixels => .{ .capability = .sgr_pixels },
            .cap_unicode => .{ .capability = .unicode },
            .cap_da1 => .{ .capability = .da1 },
            .cap_color_scheme_updates => .{ .capability = .color_scheme_updates },
            .cap_multi_cursor => .{ .capability = .multi_cursor },
            .winsize => |winsize| .{ .resize = winsize },
            .color_scheme => |scheme| .{ .color_scheme = switch (scheme) {
                .dark => .dark,
                .light => .light,
            } },
            .color_report => |report| .{ .color_report = report },
            .mouse, .mouse_leave => null,
        };
    }

    fn keyEventFromVaxis(self: *TerminalParser, key: vaxis.Key) !line_editor.KeyEvent {
        var event = line_editor.keyEventFromVaxis(key);
        if (event.text.len != 0) {
            event.text = try self.eventText(event.text);
        }
        return event;
    }

    fn eventText(self: *TerminalParser, text: []const u8) ![]const u8 {
        const start = self.event_text.items.len;
        try self.event_text.appendSlice(self.allocator, text);
        return self.event_text.items[start..];
    }
};

pub const ReadLineOptions = struct {
    prompt: []const u8,
    editing_mode: line_editor.EditingMode = .emacs,
    prompt_refresh_interval_ms: ?u64 = null,
    hook_context: ?*anyopaque = null,
    run_hooks: ?*const fn (*anyopaque, std.mem.Allocator, std.Io) anyerror!HookResult = null,
    next_hook_interval_ms: ?*const fn (*anyopaque, std.Io) anyerror!?u64 = null,
    prompt_context: ?*anyopaque = null,
    refresh_prompt: ?*const fn (*anyopaque, std.mem.Allocator, std.Io) anyerror![]const u8 = null,
    history: line_editor.HistoryView = .{},
    completion_context: ?*anyopaque = null,
    complete: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8, usize) anyerror!completion.Application = null,
    clone_completion_context: ?*const fn (*anyopaque, std.mem.Allocator, *completion.CancellationToken) anyerror!*anyopaque = null,
    free_completion_context: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    expand_abbreviation: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, usize, bool) anyerror!?completion.Edit = null,
    path_expansion_context: ?*anyopaque = null,
    expand_pathname: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!line_editor.PathExpansionMatches = null,
    vi_alias_context: ?*anyopaque = null,
    lookup_vi_alias: ?*const fn (*anyopaque, std.mem.Allocator, u21) anyerror!?[]const u8 = null,
    external_editor_command: []const u8 = "vi",
    external_editor_tmpdir: []const u8 = "/tmp",
    diagnostic_context: ?*anyopaque = null,
    diagnose: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!?line_editor.DiagnosticRender = null,
    theme: line_editor.UiTheme = .{},
    style_context: ?*anyopaque = null,
    refresh_style: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, ColorScheme) anyerror!line_editor.UiTheme = null,
    refresh_color_report: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, ColorReport) anyerror!line_editor.UiTheme = null,
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

const completion_debounce_ms = 75;
const completion_flash_ms = 80;

const CompletionRequestReason = enum { explicit, refresh };

const CompletionRequest = struct {
    generation: u64,
    source: []u8,
    cursor: usize,
    reason: CompletionRequestReason,

    fn deinit(self: *CompletionRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }
};

const CompletionResult = union(enum) {
    success: struct {
        generation: u64,
        source: []u8,
        cursor: usize,
        application: completion.Application,
    },
    failed: u64,

    fn deinit(self: CompletionResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .success => |payload| {
                allocator.free(payload.source);
                payload.application.deinit(allocator);
            },
            .failed => {},
        }
    }
};

const CompletionWorker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ReadLineOptions,
    request: CompletionRequest,
    context: ?*anyopaque,
    cancel: completion.CancellationToken = .{},
    wake_fd: std.posix.fd_t,
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    mutex: std.atomic.Mutex = .unlocked,
    result: ?CompletionResult = null,

    fn start(self: *CompletionWorker) !void {
        self.thread = try std.Thread.spawn(.{}, CompletionWorker.run, .{self});
    }

    fn run(self: *CompletionWorker) void {
        defer {
            self.done.store(true, .release);
            rawWriteAll(self.wake_fd, "c") catch {};
        }
        const complete = self.options.complete orelse return self.storeResult(.{ .failed = self.request.generation });
        const context = self.context orelse return self.storeResult(.{ .failed = self.request.generation });
        const application = complete(context, self.allocator, self.io, self.request.source, self.request.cursor) catch return self.storeResult(.{ .failed = self.request.generation });
        const source = self.allocator.dupe(u8, self.request.source) catch {
            application.deinit(self.allocator);
            return self.storeResult(.{ .failed = self.request.generation });
        };
        self.storeResult(.{ .success = .{
            .generation = self.request.generation,
            .source = source,
            .cursor = self.request.cursor,
            .application = application,
        } });
    }

    fn storeResult(self: *CompletionWorker, result: CompletionResult) void {
        lockCompletionMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.result) |old| old.deinit(self.allocator);
        self.result = result;
    }

    fn takeResult(self: *CompletionWorker) ?CompletionResult {
        lockCompletionMutex(&self.mutex);
        defer self.mutex.unlock();
        const result = self.result;
        self.result = null;
        return result;
    }

    fn deinit(self: *CompletionWorker) void {
        if (self.result) |result| result.deinit(self.allocator);
        self.request.deinit(self.allocator);
        if (self.context) |context| if (self.options.free_completion_context) |free| free(context, self.allocator);
        self.* = undefined;
    }
};

fn lockCompletionMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

const CompletionController = struct {
    allocator: std.mem.Allocator,
    next_generation: u64 = 1,
    active: ?*CompletionWorker = null,
    queued: ?CompletionRequest = null,
    debounce: ?CompletionRequest = null,
    debounce_deadline_ms: ?u64 = null,
    progress_deadline_ms: ?u64 = null,
    progress_started: bool = false,

    fn init(allocator: std.mem.Allocator) CompletionController {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CompletionController) void {
        if (self.active) |worker| {
            worker.cancel.cancel();
            worker.thread.join();
            worker.deinit();
            self.allocator.destroy(worker);
        }
        if (self.queued) |*queued_request| queued_request.deinit(self.allocator);
        if (self.debounce) |*debounce_request| debounce_request.deinit(self.allocator);
        self.* = undefined;
    }

    fn request(self: *CompletionController, io: std.Io, source: []const u8, cursor: usize, reason: CompletionRequestReason) !void {
        var next = try self.makeRequest(source, cursor, reason);
        errdefer next.deinit(self.allocator);
        if (self.active) |worker| worker.cancel.cancel();
        switch (reason) {
            .explicit => {
                if (self.queued) |*old| old.deinit(self.allocator);
                self.queued = next;
            },
            .refresh => {
                if (self.debounce) |*old| old.deinit(self.allocator);
                self.debounce = next;
                self.debounce_deadline_ms = nowMs(io) + completion_debounce_ms;
            },
        }
    }

    fn takeReadyRequest(self: *CompletionController, io: std.Io) ?CompletionRequest {
        if (self.active != null) return null;
        if (self.queued) |queued_request| {
            self.queued = null;
            return queued_request;
        }
        const deadline = self.debounce_deadline_ms orelse return null;
        if (nowMs(io) < deadline) return null;
        self.debounce_deadline_ms = null;
        const debounce_request = self.debounce orelse return null;
        self.debounce = null;
        return debounce_request;
    }

    fn debounceWaitMs(self: CompletionController, io: std.Io) ?u64 {
        const deadline = self.debounce_deadline_ms orelse return null;
        const now = nowMs(io);
        return if (deadline <= now) 0 else deadline - now;
    }

    fn progressWaitMs(self: CompletionController, io: std.Io) ?u64 {
        if (self.progress_started) return null;
        const deadline = self.progress_deadline_ms orelse return null;
        const now = nowMs(io);
        return if (deadline <= now) 0 else deadline - now;
    }

    fn hasSupersedingRequest(self: CompletionController, generation: u64) bool {
        if (self.queued) |queued_request| if (queued_request.generation > generation) return true;
        if (self.debounce) |debounce_request| if (debounce_request.generation > generation) return true;
        return false;
    }

    fn makeRequest(self: *CompletionController, source: []const u8, cursor: usize, reason: CompletionRequestReason) !CompletionRequest {
        const generation = self.next_generation;
        self.next_generation += 1;
        return .{
            .generation = generation,
            .source = try self.allocator.dupe(u8, source),
            .cursor = cursor,
            .reason = reason,
        };
    }
};

pub fn readLineFromTty(allocator: std.mem.Allocator, io: std.Io, options: ReadLineOptions) !?[]const u8 {
    if (comptime (builtin.is_test or builtin.os.tag == .windows)) return error.Unsupported;

    var session = try TerminalSession.init(allocator, io);
    defer session.deinit();
    return switch (try session.readLine(options)) {
        .submitted => |line| line,
        .canceled => try allocator.dupe(u8, ""),
        .interrupted => error.Interrupted,
        .eof => null,
    };
}

pub const TerminalSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tty_buffer: []u8,
    tty: vaxis.tty.PosixTty,
    wake: Pipe,
    prompt_redraw: Pipe,
    completion_wake: Pipe,
    trap_signal: Pipe,
    resize: ResizeSignalSource,
    child_signal: ChildSignalSource,
    interrupt_signal: InterruptSignalSource,
    loop: event_loop.EventLoop,
    reader: OneShotReader,
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

        var wake = try makePipe(io);
        errdefer wake.close(io);
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
        try loop.addReadFd(wake.read.handle, .tty_input);
        try loop.addReadFd(prompt_redraw.read.handle, .prompt_redraw);
        try loop.addReadFd(completion_wake.read.handle, .completion_result);
        try loop.addReadFd(trap_signal.read.handle, .trap_signal);
        try loop.addReadFd(resize.readFd(), .resize);
        try loop.addReadFd(child_signal.readFd(), .child_signal);
        try loop.addReadFd(interrupt_signal.readFd(), .interrupt_signal);

        const read_fd = try rawDup(tty.fd.handle);
        const read_file: std.Io.File = .{ .handle = read_fd, .flags = .{ .nonblocking = false } };
        var reader = try OneShotReader.init(allocator, io, read_file, wake.write);
        errdefer reader.deinit();
        const winsize = tty.getWinsize() catch vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };

        const self: TerminalSession = .{
            .allocator = allocator,
            .io = io,
            .tty_buffer = tty_buffer,
            .tty = tty,
            .wake = wake,
            .prompt_redraw = prompt_redraw,
            .completion_wake = completion_wake,
            .trap_signal = trap_signal,
            .resize = resize,
            .child_signal = child_signal,
            .interrupt_signal = interrupt_signal,
            .loop = loop,
            .reader = reader,
            .terminal_parser = .init(allocator),
            .completion = .init(allocator),
            .winsize = winsize,
        };
        return self;
    }

    pub fn deinit(self: *TerminalSession) void {
        writeTtyAll(&self.tty, completionProgressStop) catch {};
        self.capabilities.reset(&self.tty);
        self.events.deinit(self.allocator);
        self.completion.deinit();
        self.terminal_parser.deinit();
        self.renderer.deinit(self.allocator);
        self.reader.deinit();
        self.interrupt_signal.deinit(self.io, &self.loop);
        self.child_signal.deinit(self.io, &self.loop);
        self.resize.deinit(self.io, &self.loop);
        self.loop.deinit();
        self.trap_signal.close(self.io);
        self.completion_wake.close(self.io);
        self.prompt_redraw.close(self.io);
        self.wake.read.close(self.io);
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
        self.capabilities.reset(&self.tty);
        self.query_batch_sent = false;
        try self.suspendRawMode();
    }

    pub fn enterEditorMode(self: *TerminalSession) !void {
        try self.resumeRawMode();
        try self.capabilities.sendInitialQueries(&self.tty);
        self.query_batch_sent = true;
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
        rawWriteAll(self.prompt_redraw.write.handle, "p") catch {};
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
        if (self.reader.thread == null) try self.reader.start();
        if (!self.query_batch_sent) {
            try self.capabilities.sendInitialQueries(&self.tty);
            self.query_batch_sent = true;
        }
        var read_options = options;

        var session = try line_editor.LineSession.initWithEditingMode(self.allocator, .{
            .bytes = read_options.prompt,
            .visible_width = line_editor.visibleWidth(read_options.prompt, self.capabilities.widthMethod()),
        }, read_options.history, read_options.editing_mode);
        defer session.deinit();
        session.vi_aliases = .{ .context = read_options.vi_alias_context, .lookup = read_options.lookup_vi_alias };

        try writeTtyAll(&self.tty, semanticCommandStart);
        try renderSession(self.allocator, self.io, &self.tty, &self.renderer, &session, self.capabilities, self.winsize, read_options);
        self.reader.arm();
        var next_prompt_refresh_ms: ?u64 = if (read_options.prompt_refresh_interval_ms) |interval_ms| nowMs(self.io) + interval_ms else null;
        var next_completion_flash_clear_ms: ?u64 = null;
        var next_hook_interval_ms = try nextHookIntervalDeadlineMs(read_options, self.io);
        read_loop: while (true) {
            while (session.state == .editing or session.state == .history_search) {
                var render_needed = false;
                var loop_events: [8]event_loop.Event = undefined;
                const ready = try self.loop.waitTimeout(&loop_events, nextWaitMs(self.io, next_prompt_refresh_ms, next_hook_interval_ms, self.completion.debounceWaitMs(self.io), next_completion_flash_clear_ms, self.completion.progressWaitMs(self.io)));
                if (ready.len == 0 and self.completion.progressWaitMs(self.io) == 0) {
                    try self.startCompletionProgress();
                }
                if (ready.len == 0 and next_hook_interval_ms != null and promptRefreshWaitMs(self.io, next_hook_interval_ms) == 0) {
                    if (try self.runHooks(read_options, &session, &render_needed)) return try self.finishInterruptedReadLine();
                    next_hook_interval_ms = try nextHookIntervalDeadlineMs(read_options, self.io);
                }
                if (ready.len == 0 and next_completion_flash_clear_ms != null and promptRefreshWaitMs(self.io, next_completion_flash_clear_ms) == 0) {
                    render_needed = true;
                    next_completion_flash_clear_ms = null;
                }
                if (ready.len == 0 and next_prompt_refresh_ms != null and promptRefreshWaitMs(self.io, next_prompt_refresh_ms) == 0) {
                    render_needed = true;
                    session.invalidatePrompt();
                    next_prompt_refresh_ms = nowMs(self.io) + read_options.prompt_refresh_interval_ms.?;
                }
                try self.startReadyCompletion(read_options);
                self.events.clearRetainingCapacity();
                var hook_ready = false;
                for (ready) |ready_event| {
                    switch (ready_event.source) {
                        .tty_input => try self.processTtyInput(),
                        .resize => try self.processResizeSignal(),
                        .prompt_redraw => try self.processPromptRedraw(),
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
                    if (try self.runHooks(read_options, &session, &render_needed)) return try self.finishInterruptedReadLine();
                    next_hook_interval_ms = try nextHookIntervalDeadlineMs(read_options, self.io);
                }
                for (self.events.items) |event| {
                    switch (event) {
                        .key_press => |key| {
                            render_needed = true;
                            if (isCompletionTab(key) and session.hasCompletionMenu()) {
                                try session.handleKey(.{ .key = .tab, .modifiers = key.modifiers });
                            } else if (isCompletionTab(key) and read_options.complete != null and read_options.completion_context != null) {
                                _ = try expandAbbreviationBeforeAccept(&session, read_options, false);
                                if (read_options.clone_completion_context != null and read_options.free_completion_context != null) {
                                    try self.requestCompletion(read_options, session.editor.buffer.text(), session.editor.buffer.cursor_byte, .explicit);
                                } else {
                                    const application = try read_options.complete.?(read_options.completion_context.?, self.allocator, self.io, session.editor.buffer.text(), session.editor.buffer.cursor_byte);
                                    defer application.deinit(self.allocator);
                                    try session.applyCompletion(application);
                                }
                            } else if (key.key == .enter and !session.hasCompletionMenu()) {
                                _ = try expandAbbreviationBeforeAccept(&session, read_options, false);
                                try session.handleKey(key);
                            } else if (isSpaceAccept(key) and try expandAbbreviationBeforeAccept(&session, read_options, true)) {} else if (session.hasCompletionMenu() and shouldRefreshCompletionMenu(key) and read_options.complete != null and read_options.completion_context != null) {
                                try session.handleKey(key);
                                if (session.hasCompletionMenu()) {
                                    if (read_options.clone_completion_context != null and read_options.free_completion_context != null) {
                                        try self.requestCompletion(read_options, session.editor.buffer.text(), session.editor.buffer.cursor_byte, .refresh);
                                    } else {
                                        const application = try read_options.complete.?(read_options.completion_context.?, self.allocator, self.io, session.editor.buffer.text(), session.editor.buffer.cursor_byte);
                                        defer application.deinit(self.allocator);
                                        try session.applyCompletion(application);
                                    }
                                }
                            } else {
                                try session.handleKey(key);
                            }
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
                        .resize => |winsize| {
                            if (!sameWinsize(self.winsize, winsize)) {
                                render_needed = true;
                                self.winsize = winsize;
                                self.renderer.reset(self.allocator);
                            }
                        },
                        .capability => |capability| {
                            render_needed = true;
                            try self.capabilities.apply(self.allocator, &self.tty, capability);
                            if (capability == .da1 and read_options.refresh_style != null and read_options.style_context != null) {
                                read_options.theme = try read_options.refresh_style.?(read_options.style_context.?, self.allocator, self.io, self.color_scheme);
                            }
                        },
                        .color_scheme => |scheme| {
                            self.color_scheme = scheme;
                            try self.capabilities.requestColorReports(&self.tty);
                            try self.capabilities.sendQueries(&self.tty);
                            if (read_options.refresh_style != null and read_options.style_context != null) {
                                read_options.theme = try read_options.refresh_style.?(read_options.style_context.?, self.allocator, self.io, scheme);
                                render_needed = true;
                            }
                        },
                        .color_report => |report| {
                            if (read_options.refresh_color_report != null and read_options.style_context != null) {
                                read_options.theme = try read_options.refresh_color_report.?(read_options.style_context.?, self.allocator, self.io, report);
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
                    if (render_needed) {
                        if (session.takePromptInvalidation() and read_options.refresh_prompt != null and read_options.prompt_context != null) {
                            const prompt = try read_options.refresh_prompt.?(read_options.prompt_context.?, self.allocator, self.io);
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
                        try renderSession(self.allocator, self.io, &self.tty, &self.renderer, &session, self.capabilities, self.winsize, read_options);
                        if (rendered_completion_flash) next_completion_flash_clear_ms = nowMs(self.io) + completion_flash_ms;
                    }
                    self.reader.arm();
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
                        try renderSession(self.allocator, self.io, &self.tty, &self.renderer, &session, self.capabilities, self.winsize, read_options);
                        self.reader.arm();
                        continue :read_loop;
                    }
                    continue :read_loop;
                },
                .submitted => {
                    // Accepting the line may have rewritten the buffer (e.g.
                    // abbreviation expansion on Enter); paint the final text so
                    // the scrollback shows the command that actually runs.
                    try renderSession(self.allocator, self.io, &self.tty, &self.renderer, &session, self.capabilities, self.winsize, read_options);
                    try self.handoffSubmittedInput();
                    self.renderer.reset(self.allocator);
                    try writeTtyAll(&self.tty, semanticInputEnd ++ "\r\n");
                    return .{ .submitted = session.takeSubmittedLine().? };
                },
                .canceled => {
                    try self.clearRenderedRowsAfterFirst();
                    self.renderer.reset(self.allocator);
                    try writeTtyAll(&self.tty, semanticInputCancel ++ "^C\r\n");
                    return .canceled;
                },
                .eof => {
                    try self.clearRenderedRowsAfterFirst();
                    self.renderer.reset(self.allocator);
                    try writeTtyAll(&self.tty, "\r\n");
                    return .eof;
                },
                .editing => unreachable,
            }
        }
    }

    fn finishInterruptedReadLine(self: *TerminalSession) !ReadLineResult {
        try self.clearRenderedRowsAfterFirst();
        self.renderer.reset(self.allocator);
        try writeTtyAll(&self.tty, semanticInputCancel ++ "\r\n");
        return .interrupted;
    }

    fn runExternalEditor(self: *TerminalSession, options: ReadLineOptions, session: *line_editor.LineSession) ![]const u8 {
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

    fn runHooks(self: *TerminalSession, options: ReadLineOptions, session: *line_editor.LineSession, render_needed: *bool) !bool {
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

    fn processPathExpansionRequest(self: *TerminalSession, options: ReadLineOptions, session: *line_editor.LineSession) !bool {
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

        return try session.applyPathExpansion(request, matches);
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
        var wake_buffer: [32]u8 = undefined;
        _ = try rawRead(self.wake.read.handle, &wake_buffer);
        const bytes = try self.reader.takeReady();
        self.terminal_parser.resetEventText();
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
        _ = try rawRead(self.prompt_redraw.read.handle, &buffer);
        try self.events.append(self.allocator, .prompt_redraw);
    }

    fn processChildSignal(self: *TerminalSession) void {
        self.child_signal.drain();
    }

    fn processTrapSignal(self: *TerminalSession) void {
        var buffer: [64]u8 = undefined;
        _ = rawRead(self.trap_signal.read.handle, &buffer) catch {};
    }

    fn processInterruptSignal(self: *TerminalSession) void {
        self.interrupt_signal.drain();
    }

    fn requestCompletion(self: *TerminalSession, options: ReadLineOptions, source: []const u8, cursor: usize, reason: CompletionRequestReason) !void {
        if (options.complete == null or options.completion_context == null) return;
        try self.completion.request(self.io, source, cursor, reason);
        try self.startReadyCompletion(options);
    }

    fn startReadyCompletion(self: *TerminalSession, options: ReadLineOptions) !void {
        var request = self.completion.takeReadyRequest(self.io) orelse return;
        errdefer request.deinit(self.allocator);
        const clone = options.clone_completion_context orelse return;
        const free = options.free_completion_context orelse return;
        const worker = try self.allocator.create(CompletionWorker);
        errdefer self.allocator.destroy(worker);
        worker.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .options = options,
            .request = request,
            .context = null,
            .wake_fd = self.completion_wake.write.handle,
        };
        errdefer worker.deinit();
        const context = try clone(options.completion_context.?, self.allocator, &worker.cancel);
        errdefer free(context, self.allocator);
        worker.context = context;
        request = undefined;
        try worker.start();
        self.completion.active = worker;
        self.completion.progress_deadline_ms = nowMs(self.io) + completion_progress_delay_ms;
        self.completion.progress_started = false;
    }

    fn startCompletionProgress(self: *TerminalSession) !void {
        if (self.completion.active == null or self.completion.progress_started) return;
        self.completion.progress_started = true;
        self.completion.progress_deadline_ms = null;
        try writeTtyAll(&self.tty, completionProgressStart);
    }

    fn processCompletionResult(self: *TerminalSession, session: *line_editor.LineSession) !bool {
        var buffer: [32]u8 = undefined;
        _ = rawRead(self.completion_wake.read.handle, &buffer) catch {};
        const worker = self.completion.active orelse return false;
        if (!worker.done.load(.acquire)) return false;
        self.completion.active = null;
        worker.thread.join();
        if (self.completion.progress_started) writeTtyAll(&self.tty, completionProgressStop) catch {};
        self.completion.progress_started = false;
        self.completion.progress_deadline_ms = null;
        const result = worker.takeResult();
        worker.deinit();
        self.allocator.destroy(worker);
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

const ExternalEditorTempFile = struct {
    dir: std.Io.Dir,
    sub_path: []const u8,
    path: []const u8,

    fn deinit(self: ExternalEditorTempFile, allocator: std.mem.Allocator, io: std.Io) void {
        self.dir.deleteFile(io, self.sub_path) catch {};
        self.dir.close(io);
        allocator.free(self.path);
        allocator.free(self.sub_path);
    }
};

fn editCommandWithExternalEditor(allocator: std.mem.Allocator, io: std.Io, options: ReadLineOptions, initial_text: []const u8) ![]const u8 {
    const temp = try createExternalEditorTempFile(allocator, io, options.external_editor_tmpdir, initial_text);
    defer temp.deinit(allocator, io);

    try runExternalEditorCommand(allocator, io, options.external_editor_command, temp.path);
    return temp.dir.readFileAlloc(io, temp.sub_path, allocator, .limited(1024 * 1024));
}

fn createExternalEditorTempFile(allocator: std.mem.Allocator, io: std.Io, tmpdir: []const u8, initial_text: []const u8) !ExternalEditorTempFile {
    var dir = if (std.fs.path.isAbsolute(tmpdir))
        try std.Io.Dir.openDirAbsolute(io, tmpdir, .{})
    else
        try std.Io.Dir.cwd().openDir(io, tmpdir, .{});
    errdefer dir.close(io);

    var attempts: usize = 0;
    while (attempts < 64) : (attempts += 1) {
        const sub_path = try std.fmt.allocPrint(allocator, "rush-edit-{d}-{d}-{d}.sh", .{ std.c.getpid(), nowMs(io), attempts });
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

fn runExternalEditorCommand(allocator: std.mem.Allocator, io: std.Io, editor_command: []const u8, path: []const u8) !void {
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

fn shouldRefreshCompletionMenu(key: line_editor.KeyEvent) bool {
    return switch (key.key) {
        .text => key.text.len != 0,
        .transpose_chars,
        .yank,
        => true,
        else => false,
    };
}

fn expandAbbreviationBeforeAccept(session: *line_editor.LineSession, options: ReadLineOptions, append_space: bool) !bool {
    if (options.expand_abbreviation == null or options.completion_context == null) return false;
    const edit = try options.expand_abbreviation.?(options.completion_context.?, session.allocator, session.editor.buffer.text(), session.editor.buffer.cursor_byte, append_space) orelse return false;
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

fn renderSession(allocator: std.mem.Allocator, io: std.Io, tty: *vaxis.tty.PosixTty, renderer: *line_editor.FrameRenderer, session: *line_editor.LineSession, capabilities: TerminalCapabilities, winsize: vaxis.Winsize, options: ReadLineOptions) !void {
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
    const rendered = try renderer.render(allocator, frame, .{ .synchronized_output = capabilities.synchronized_output });
    defer allocator.free(rendered);
    try writeTtyAll(tty, rendered);
}

fn appendOscText(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        0x00...0x1f, 0x7f => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    };
}

fn writeTtyAll(tty: *vaxis.tty.PosixTty, bytes: []const u8) !void {
    try tty.writer().writeAll(bytes);
    try tty.writer().flush();
}

fn writeTtyText(tty: *vaxis.tty.PosixTty, bytes: []const u8) !void {
    var writer = tty.writer();
    for (bytes) |byte| {
        if (byte == '\n') try writer.writeByte('\r');
        try writer.writeByte(byte);
    }
    try writer.flush();
}

pub const Pipe = struct {
    read: std.Io.File,
    write: std.Io.File,

    pub fn close(self: *Pipe, io: std.Io) void {
        self.read.close(io);
        self.write.close(io);
        self.* = undefined;
    }
};

const ResizeSignalSource = struct {
    pipe: ?Pipe,
    previous: ?std.posix.Sigaction,

    fn init(io: std.Io) !ResizeSignalSource {
        var pipe = try makePipe(io);
        errdefer pipe.close(io);
        try setNonBlocking(pipe.read.handle);
        try setNonBlocking(pipe.write.handle);

        ResizeSignalFd.value.store(pipe.write.handle, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = resizeSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.WINCH, &action, &previous);
        return .{ .pipe = pipe, .previous = previous };
    }

    fn readFd(self: ResizeSignalSource) std.posix.fd_t {
        return self.pipe.?.read.handle;
    }

    fn drain(self: *ResizeSignalSource) void {
        const pipe = self.pipe orelse return;
        var buffer: [64]u8 = undefined;
        _ = rawRead(pipe.read.handle, &buffer) catch {};
    }

    fn disable(self: *ResizeSignalSource, io: std.Io, loop: *event_loop.EventLoop) !void {
        ResizeSignalFd.value.store(invalid_fd, .release);
        if (self.previous) |previous| {
            std.posix.sigaction(.WINCH, &previous, null);
            self.previous = null;
        }
        if (self.pipe) |*pipe| {
            try loop.removeFd(pipe.read.handle);
            pipe.close(io);
            self.pipe = null;
        }
    }

    fn deinit(self: *ResizeSignalSource, io: std.Io, loop: *event_loop.EventLoop) void {
        self.disable(io, loop) catch {};
        self.* = undefined;
    }

    fn deinitUnregistered(self: *ResizeSignalSource, io: std.Io) void {
        ResizeSignalFd.value.store(invalid_fd, .release);
        if (self.previous) |previous| std.posix.sigaction(.WINCH, &previous, null);
        if (self.pipe) |*pipe| pipe.close(io);
        self.* = undefined;
    }
};

fn resizeSignalHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = ResizeSignalFd.value.load(.acquire);
    if (fd == invalid_fd) return;
    _ = std.c.write(fd, "r", 1);
}

const ChildSignalSource = struct {
    pipe: ?Pipe,
    previous: ?std.posix.Sigaction,

    fn init(io: std.Io) !ChildSignalSource {
        var pipe = try makePipe(io);
        errdefer pipe.close(io);
        try setNonBlocking(pipe.read.handle);
        try setNonBlocking(pipe.write.handle);

        ChildSignalFd.value.store(pipe.write.handle, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = childSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.CHLD, &action, &previous);
        return .{ .pipe = pipe, .previous = previous };
    }

    fn readFd(self: ChildSignalSource) std.posix.fd_t {
        return self.pipe.?.read.handle;
    }

    fn drain(self: *ChildSignalSource) void {
        const pipe = self.pipe orelse return;
        var buffer: [64]u8 = undefined;
        _ = rawRead(pipe.read.handle, &buffer) catch {};
    }

    fn deinit(self: *ChildSignalSource, io: std.Io, loop: *event_loop.EventLoop) void {
        ChildSignalFd.value.store(invalid_fd, .release);
        if (self.previous) |previous| {
            std.posix.sigaction(.CHLD, &previous, null);
            self.previous = null;
        }
        if (self.pipe) |*pipe| {
            loop.removeFd(pipe.read.handle) catch {};
            pipe.close(io);
            self.pipe = null;
        }
        self.* = undefined;
    }

    fn deinitUnregistered(self: *ChildSignalSource, io: std.Io) void {
        ChildSignalFd.value.store(invalid_fd, .release);
        if (self.previous) |previous| std.posix.sigaction(.CHLD, &previous, null);
        if (self.pipe) |*pipe| pipe.close(io);
        self.* = undefined;
    }
};

fn childSignalHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = ChildSignalFd.value.load(.acquire);
    if (fd == invalid_fd) return;
    _ = std.c.write(fd, "c", 1);
}

const InterruptSignalSource = struct {
    pipe: ?Pipe,
    previous: ?std.posix.Sigaction,

    fn init(io: std.Io) !InterruptSignalSource {
        var pipe = try makePipe(io);
        errdefer pipe.close(io);
        try setNonBlocking(pipe.read.handle);
        try setNonBlocking(pipe.write.handle);

        InterruptSignalFd.value.store(pipe.write.handle, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = interruptSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, &action, &previous);
        return .{ .pipe = pipe, .previous = previous };
    }

    fn readFd(self: InterruptSignalSource) std.posix.fd_t {
        return self.pipe.?.read.handle;
    }

    fn drain(self: *InterruptSignalSource) void {
        const pipe = self.pipe orelse return;
        var buffer: [64]u8 = undefined;
        _ = rawRead(pipe.read.handle, &buffer) catch {};
    }

    fn deinit(self: *InterruptSignalSource, io: std.Io, loop: *event_loop.EventLoop) void {
        InterruptSignalFd.value.store(invalid_fd, .release);
        if (self.previous) |previous| {
            std.posix.sigaction(.INT, &previous, null);
            self.previous = null;
        }
        if (self.pipe) |*pipe| {
            loop.removeFd(pipe.read.handle) catch {};
            pipe.close(io);
            self.pipe = null;
        }
        self.* = undefined;
    }

    fn deinitUnregistered(self: *InterruptSignalSource, io: std.Io) void {
        InterruptSignalFd.value.store(invalid_fd, .release);
        if (self.previous) |previous| std.posix.sigaction(.INT, &previous, null);
        if (self.pipe) |*pipe| pipe.close(io);
        self.* = undefined;
    }
};

fn interruptSignalHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = InterruptSignalFd.value.load(.acquire);
    if (fd == invalid_fd) return;
    _ = std.c.write(fd, "i", 1);
}

pub fn makePipe(io: std.Io) !Pipe {
    const fds = switch (builtin.os.tag) {
        .linux => blk: {
            var fds: [2]i32 = undefined;
            const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            break :blk .{ fds[0], fds[1] };
        },
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => blk: {
            var fds: [2]std.c.fd_t = undefined;
            const rc = std.c.pipe(&fds);
            switch (std.c.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            errdefer {
                closeFd(io, fds[0]);
                closeFd(io, fds[1]);
            }
            try setCloseOnExec(fds[0]);
            try setCloseOnExec(fds[1]);
            break :blk .{ fds[0], fds[1] };
        },
        else => return error.Unsupported,
    };

    return .{
        .read = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .write = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

pub const OneShotReader = struct {
    const State = enum {
        idle,
        armed,
        reading,
        ready,
        stopping,
        stopped,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    state: State = .idle,
    read_file: ?std.Io.File,
    wake_write: ?std.Io.File,
    bytes: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, read_file: std.Io.File, wake_write: std.Io.File) !OneShotReader {
        var self: OneShotReader = .{
            .allocator = allocator,
            .io = io,
            .read_file = read_file,
            .wake_write = wake_write,
        };
        errdefer self.deinit();
        try self.bytes.ensureTotalCapacity(allocator, read_chunk_size);
        return self;
    }

    pub fn start(self: *OneShotReader) !void {
        if (self.thread != null) return error.ReaderAlreadyStarted;
        self.thread = try std.Thread.spawn(.{}, readThreadMain, .{self});
    }

    pub fn deinit(self: *OneShotReader) void {
        self.stop();
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Ensure a read is pending. A no-op when a read is already armed,
    /// in flight, or has produced data that has not been taken yet, so
    /// callers woken by unrelated events can arm unconditionally.
    pub fn arm(self: *OneShotReader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .idle) return;
        self.bytes.clearRetainingCapacity();
        self.err = null;
        self.state = .armed;
        self.cond.signal(self.io);
    }

    pub fn takeReady(self: *OneShotReader) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .ready) return error.ReadNotReady;
        self.state = .idle;
        if (self.err) |err| return err;
        return self.bytes.items;
    }

    pub fn stop(self: *OneShotReader) void {
        self.mutex.lockUncancelable(self.io);
        switch (self.state) {
            .stopped => {
                self.mutex.unlock(self.io);
                return;
            },
            else => self.state = .stopping,
        }
        if (self.read_file) |file| {
            file.close(self.io);
            self.read_file = null;
        }
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.wake_write) |file| {
            file.close(self.io);
            self.wake_write = null;
        }
    }

    fn readThreadMain(self: *OneShotReader) void {
        while (self.waitUntilArmed()) {
            const read_file = self.currentReadFile() orelse break;
            const result = self.readOnce(read_file);
            self.publishRead(result);
        }
        self.mutex.lockUncancelable(self.io);
        self.state = .stopped;
        self.mutex.unlock(self.io);
    }

    fn waitUntilArmed(self: *OneShotReader) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.state == .idle or self.state == .ready) self.cond.waitUncancelable(self.io, &self.mutex);
        if (self.state == .stopping or self.state == .stopped) return false;
        self.state = .reading;
        return true;
    }

    fn currentReadFile(self: *OneShotReader) ?std.Io.File {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.read_file;
    }

    fn readOnce(self: *OneShotReader, file: std.Io.File) anyerror!usize {
        self.bytes.clearRetainingCapacity();
        const buffer = self.bytes.addManyAsSliceAssumeCapacity(read_chunk_size);
        const n = rawRead(file.handle, buffer) catch |err| {
            self.bytes.shrinkRetainingCapacity(0);
            return err;
        };
        self.bytes.shrinkRetainingCapacity(n);
        return n;
    }

    fn publishRead(self: *OneShotReader, result: anyerror!usize) void {
        self.mutex.lockUncancelable(self.io);
        if (self.state != .stopping) {
            _ = result catch |err| {
                self.err = err;
            };
            self.state = .ready;
        }
        self.mutex.unlock(self.io);
        self.wake();
    }

    fn wake(self: *OneShotReader) void {
        const file = self.wake_write orelse return;
        rawWriteAll(file.handle, "x") catch {};
    }
};

fn rawRead(fd: std.posix.fd_t, buffer: []u8) !usize {
    while (true) {
        return std.posix.read(fd, buffer) catch |err| switch (err) {
            error.WouldBlock => return err,
            error.InputOutput => return err,
            error.IsDir => return err,
            error.SystemResources => return err,
            error.ConnectionResetByPeer => return err,
            error.Unexpected => return err,
            else => return err,
        };
    }
}

fn rawWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try rawWrite(fd, remaining);
        remaining = remaining[written..];
    }
}

fn rawWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .BADF => return error.BadFileDescriptor,
            .INTR => return rawWrite(fd, bytes),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
}

fn rawDup(fd: std.posix.fd_t) !std.posix.fd_t {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.dup(fd);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.dup(fd);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn closeFd(io: std.Io, fd: std.posix.fd_t) void {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(io);
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    if (builtin.os.tag == .linux and !builtin.link_libc) return;
    const rc = std.c.fcntl(fd, @as(c_int, std.c.F.SETFD), @as(c_int, std.c.FD_CLOEXEC));
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        .INVAL => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn setNonBlocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, @as(c_int, std.c.F.GETFL));
    switch (std.c.errno(flags)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        else => return error.Unexpected,
    }
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    const rc = std.c.fcntl(fd, @as(c_int, std.c.F.SETFL), flags | nonblock);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.BadFileDescriptor,
        else => return error.Unexpected,
    }
}

fn readAllFromFile(io: std.Io, file: std.Io.File, buffer: []u8) !usize {
    _ = io;
    return rawRead(file.handle, buffer);
}

test "child signal source reports SIGCHLD through event loop" {
    var source = try ChildSignalSource.init(std.testing.io);
    var loop = try event_loop.EventLoop.init();
    defer loop.deinit();
    defer source.deinit(std.testing.io, &loop);
    try loop.addReadFd(source.readFd(), .child_signal);

    try std.posix.raise(.CHLD);

    var events: [4]event_loop.Event = undefined;
    const ready = try loop.waitTimeout(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(event_loop.Source.child_signal, ready[0].source);
    source.drain();
}

test "interrupt signal source reports SIGINT through event loop" {
    var source = try InterruptSignalSource.init(std.testing.io);
    var loop = try event_loop.EventLoop.init();
    defer loop.deinit();
    defer source.deinit(std.testing.io, &loop);
    try loop.addReadFd(source.readFd(), .interrupt_signal);

    interruptSignalHandler(.INT);

    var events: [4]event_loop.Event = undefined;
    const ready = try loop.waitTimeout(&events, 1000);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(event_loop.Source.interrupt_signal, ready[0].source);
    source.drain();
}

test "terminal parser emits text keys" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("a", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.text, events.items[0].key_press.key);
    try std.testing.expectEqualStrings("a", events.items[0].key_press.text);
}

test "terminal parser emits color scheme changes" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[?997;1n", &events);
    try parser.feed("\x1b[?997;2n", &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(ColorScheme.dark, events.items[0].color_scheme);
    try std.testing.expectEqual(ColorScheme.light, events.items[1].color_scheme);
}

test "terminal parser emits terminal color reports" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b]10;rgb:0101/2323/4545\x1b\\", &events);
    try parser.feed("\x1b]4;4;rgb:6767/8989/abab\x1b\\", &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(vaxis.Color.Kind.fg, events.items[0].color_report.kind);
    try std.testing.expectEqual([3]u8{ 0x01, 0x23, 0x45 }, events.items[0].color_report.value);
    try std.testing.expectEqual(vaxis.Color.Kind{ .index = 4 }, events.items[1].color_report.kind);
    try std.testing.expectEqual([3]u8{ 0x67, 0x89, 0xab }, events.items[1].color_report.value);
}

test "terminal parser treats single escape chunk as escape key" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.escape, events.items[0].key_press.key);
}

test "terminal parser emits arrow keys" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[D", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.left, events.items[0].key_press.key);
}

test "terminal parser keeps split escape sequences pending" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[", &events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try parser.feed("D", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.left, events.items[0].key_press.key);
}

test "terminal parser emits enter and backspace" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\r\x7f", &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(line_editor.Key.enter, events.items[0].key_press.key);
    try std.testing.expectEqual(line_editor.Key.backspace, events.items[1].key_press.key);
}

test "terminal parser marks bracketed paste around text keys" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[200~echo one\necho two\x1b[201~", &events);

    try std.testing.expect(events.items.len > 3);
    try std.testing.expectEqual(TerminalEvent.paste_start, events.items[0]);
    try std.testing.expectEqual(TerminalEvent.paste_end, events.items[events.items.len - 1]);
    var saw_enter = false;
    for (events.items[1 .. events.items.len - 1]) |event| {
        if (event == .key_press and event.key_press.key == .enter) saw_enter = true;
    }
    try std.testing.expect(saw_enter);
}

fn testExpandAbbreviation(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, cursor: usize, append_space: bool) !?completion.Edit {
    _ = context;
    if (cursor < source.len or !std.mem.eql(u8, source, "gs")) return null;
    return .{ .replace_start = 0, .replace_end = 2, .replacement = try allocator.dupe(u8, "git status"), .append_space = append_space };
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
    std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};
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
    std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, tmpdir, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, tmpdir) catch {};

    try std.testing.expectError(error.ExternalEditorFailed, editCommandWithExternalEditor(std.testing.allocator, std.testing.io, .{
        .prompt = "",
        .external_editor_command = "false",
        .external_editor_tmpdir = tmpdir,
    }, "original"));
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

test "terminal parser emits tab key" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\t", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(isCompletionTab(events.items[0].key_press));
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

test "completion controller debounces refresh requests to the latest input" {
    var controller = CompletionController.init(std.testing.allocator);
    defer controller.deinit();

    try controller.request(std.testing.io, "git c", 5, .refresh);
    try controller.request(std.testing.io, "git ch", 6, .refresh);

    try std.testing.expect(controller.debounce != null);
    try std.testing.expectEqualStrings("git ch", controller.debounce.?.source);
    try std.testing.expectEqual(@as(usize, 6), controller.debounce.?.cursor);
    try std.testing.expect(controller.debounceWaitMs(std.testing.io) != null);
}

test "completion controller cancels active worker when superseded" {
    var controller = CompletionController.init(std.testing.allocator);

    const worker = try std.testing.allocator.create(CompletionWorker);
    worker.* = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .options = .{ .prompt = "" },
        .request = .{
            .generation = 1,
            .source = try std.testing.allocator.dupe(u8, "git c"),
            .cursor = 5,
            .reason = .explicit,
        },
        .context = null,
        .wake_fd = -1,
    };
    controller.active = worker;

    try controller.request(std.testing.io, "git ch", 6, .explicit);
    try std.testing.expect(worker.cancel.isCanceled());
    try std.testing.expect(controller.queued != null);
    try std.testing.expectEqualStrings("git ch", controller.queued.?.source);

    controller.active = null;
    worker.deinit();
    std.testing.allocator.destroy(worker);
    controller.deinit();
}

test "completion controller marks same-input active results stale when superseded" {
    var controller = CompletionController.init(std.testing.allocator);
    defer controller.deinit();

    var first = try controller.makeRequest("git s", 5, .explicit);
    defer first.deinit(std.testing.allocator);
    try controller.request(std.testing.io, "git s", 5, .explicit);

    try std.testing.expect(controller.hasSupersedingRequest(first.generation));
    try std.testing.expect(!controller.hasSupersedingRequest(controller.queued.?.generation));
}

test "terminal parser emits in-band resize events" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[48;30;120;600;1200t", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(@as(u16, 30), events.items[0].resize.rows);
    try std.testing.expectEqual(@as(u16, 120), events.items[0].resize.cols);
}

test "one-shot reader reads only after it is armed" {
    var input = try makePipe(std.testing.io);
    defer input.write.close(std.testing.io);
    var wake = try makePipe(std.testing.io);
    defer wake.read.close(std.testing.io);

    var reader = try OneShotReader.init(std.testing.allocator, std.testing.io, input.read, wake.write);
    defer reader.deinit();
    try reader.start();

    reader.arm();
    try rawWriteAll(input.write.handle, "abc");

    var wake_buffer: [8]u8 = undefined;
    const wake_n = try readAllFromFile(std.testing.io, wake.read, &wake_buffer);
    try std.testing.expectEqual(@as(usize, 1), wake_n);

    const bytes = try reader.takeReady();
    try std.testing.expectEqualStrings("abc", bytes);
}

test "one-shot reader treats overlapping arms as no-ops" {
    var input = try makePipe(std.testing.io);
    defer input.write.close(std.testing.io);
    var wake = try makePipe(std.testing.io);
    defer wake.read.close(std.testing.io);

    var reader = try OneShotReader.init(std.testing.allocator, std.testing.io, input.read, wake.write);
    defer reader.deinit();
    try reader.start();

    reader.arm();
    reader.arm();
    try rawWriteAll(input.write.handle, "x");
    var wake_buffer: [8]u8 = undefined;
    _ = try readAllFromFile(std.testing.io, wake.read, &wake_buffer);
    const bytes = try reader.takeReady();
    try std.testing.expectEqualStrings("x", bytes);
}
