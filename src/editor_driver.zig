//! Cooperative driver pieces for the future terminal line editor.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const event_loop = @import("event_loop.zig");
const line_editor = @import("line_editor.zig");
const completion = @import("completion.zig");

const read_chunk_size = 4096;
const invalid_fd: std.posix.fd_t = -1;

const ResizeSignalFd = struct {
    var value: std.atomic.Value(std.posix.fd_t) = .init(invalid_fd);
};

pub const DriverEvent = union(enum) {
    tty_read_ready,
};

pub const TerminalEvent = union(enum) {
    key_press: line_editor.KeyEvent,
    key_release: line_editor.KeyEvent,
    paste_start,
    paste_end,
    focus_in,
    focus_out,
    resize: vaxis.Winsize,
    capability: Capability,
};

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
            .color_scheme_updates => self.color_scheme_updates = true,
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
            .mouse, .mouse_leave, .paste, .color_report, .color_scheme => null,
        };
    }

    fn keyEventFromVaxis(self: *TerminalParser, key: vaxis.Key) !line_editor.KeyEvent {
        var event = line_editor.keyEventFromVaxis(key);
        if (event.text.len != 0) {
            const start = self.event_text.items.len;
            try self.event_text.appendSlice(self.allocator, event.text);
            event.text = self.event_text.items[start..];
        }
        return event;
    }
};

pub const ReadLineOptions = struct {
    prompt: []const u8,
    history: line_editor.HistoryView = .{},
    completion_context: ?*anyopaque = null,
    complete: ?*const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8, usize) anyerror!completion.Application = null,
};

pub const ReadLineResult = union(enum) {
    submitted: []const u8,
    canceled,
    eof,
};

pub fn readLineFromTty(allocator: std.mem.Allocator, io: std.Io, options: ReadLineOptions) !?[]const u8 {
    if (comptime (builtin.is_test or builtin.os.tag == .windows)) return error.Unsupported;

    var session = try TerminalSession.init(allocator, io);
    defer session.deinit();
    return switch (try session.readLine(options)) {
        .submitted => |line| line,
        .canceled => try allocator.dupe(u8, ""),
        .eof => null,
    };
}

pub const TerminalSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tty_buffer: []u8,
    tty: vaxis.tty.PosixTty,
    wake: Pipe,
    resize: ResizeSignalSource,
    loop: event_loop.EventLoop,
    reader: OneShotReader,
    terminal_parser: TerminalParser,
    capabilities: TerminalCapabilities = .{},
    winsize: vaxis.Winsize,
    events: std.ArrayList(TerminalEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !TerminalSession {
        const tty_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(tty_buffer);
        var tty = try vaxis.tty.PosixTty.init(io, tty_buffer);
        errdefer tty.deinit();

        var wake = try makePipe(io);
        errdefer wake.close(io);
        var resize = try ResizeSignalSource.init(io);
        errdefer resize.deinitUnregistered(io);
        var loop = try event_loop.EventLoop.init();
        errdefer loop.deinit();
        try loop.addReadFd(wake.read.handle, .tty_input);
        try loop.addReadFd(resize.readFd(), .resize);

        const read_fd = try rawDup(tty.fd.handle);
        const read_file: std.Io.File = .{ .handle = read_fd, .flags = .{ .nonblocking = false } };
        var reader = try OneShotReader.init(allocator, io, read_file, wake.write);
        errdefer reader.deinit();
        const winsize = tty.getWinsize() catch vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };

        var self: TerminalSession = .{
            .allocator = allocator,
            .io = io,
            .tty_buffer = tty_buffer,
            .tty = tty,
            .wake = wake,
            .resize = resize,
            .loop = loop,
            .reader = reader,
            .terminal_parser = .init(allocator),
            .winsize = winsize,
        };
        try self.capabilities.sendQueries(&self.tty);
        return self;
    }

    pub fn deinit(self: *TerminalSession) void {
        self.capabilities.reset(&self.tty);
        self.events.deinit(self.allocator);
        self.terminal_parser.deinit();
        self.reader.deinit();
        self.resize.deinit(self.io, &self.loop);
        self.loop.deinit();
        self.wake.read.close(self.io);
        self.tty.deinit();
        self.allocator.free(self.tty_buffer);
        self.* = undefined;
    }

    pub fn suspendRawMode(self: *TerminalSession) !void {
        try std.posix.tcsetattr(self.tty.fd.handle, .FLUSH, self.tty.termios);
    }

    pub fn resumeRawMode(self: *TerminalSession) !void {
        _ = try vaxis.tty.PosixTty.makeRaw(self.tty.fd.handle);
    }

    pub fn leaveEditorMode(self: *TerminalSession) !void {
        self.capabilities.reset(&self.tty);
        try self.suspendRawMode();
    }

    pub fn enterEditorMode(self: *TerminalSession) !void {
        try self.resumeRawMode();
        try self.capabilities.sendQueries(&self.tty);
    }

    pub fn readLine(self: *TerminalSession, options: ReadLineOptions) !ReadLineResult {
        if (self.reader.thread == null) try self.reader.start();

        var session = try line_editor.LineSession.initWithOptions(self.allocator, .{
            .bytes = options.prompt,
            .visible_width = line_editor.visibleWidth(options.prompt, self.capabilities.widthMethod()),
        }, options.history);
        defer session.deinit();

        try renderSession(self.allocator, &self.tty, session, self.capabilities, self.winsize);
        try self.reader.arm();
        while (session.state == .editing) {
            var render_needed = false;
            var loop_events: [8]event_loop.Event = undefined;
            const ready = try self.loop.wait(&loop_events);
            self.events.clearRetainingCapacity();
            for (ready) |ready_event| {
                switch (ready_event.source) {
                    .tty_input => try self.processTtyInput(),
                    .resize => try self.processResizeSignal(),
                }
            }
            for (self.events.items) |event| {
                switch (event) {
                    .key_press => |key| {
                        render_needed = true;
                        if (isCompletionTab(key) and options.complete != null and options.completion_context != null) {
                            const application = try options.complete.?(options.completion_context.?, self.allocator, self.io, session.editor.buffer.text(), session.editor.buffer.cursor_byte);
                            defer application.deinit(self.allocator);
                            try session.applyCompletion(application);
                        } else {
                            try session.handleKey(key);
                        }
                    },
                    .paste_start => {
                        render_needed = true;
                        session.beginPaste();
                    },
                    .paste_end => {
                        render_needed = true;
                        session.endPaste();
                    },
                    .resize => |winsize| {
                        if (!sameWinsize(self.winsize, winsize)) {
                            render_needed = true;
                            self.winsize = winsize;
                        }
                    },
                    .capability => |capability| {
                        render_needed = true;
                        try self.capabilities.apply(self.allocator, &self.tty, capability);
                    },
                    .key_release, .focus_in, .focus_out => {},
                }
            }
            if (session.state == .editing) {
                if (render_needed) try renderSession(self.allocator, &self.tty, session, self.capabilities, self.winsize);
                try self.reader.arm();
            }
        }

        switch (session.state) {
            .submitted => {
                try writeTtyAll(&self.tty, "\r\n");
                return .{ .submitted = session.takeSubmittedLine().? };
            },
            .canceled => {
                try writeTtyAll(&self.tty, "^C\r\n");
                return .canceled;
            },
            .eof => {
                try writeTtyAll(&self.tty, "\r\n");
                return .eof;
            },
            .editing => unreachable,
        }
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
};

fn isCompletionTab(key: line_editor.KeyEvent) bool {
    return key.key == .tab or (key.key == .text and std.mem.eql(u8, key.text, "\t"));
}

fn sameWinsize(a: vaxis.Winsize, b: vaxis.Winsize) bool {
    return a.rows == b.rows and
        a.cols == b.cols and
        a.x_pixel == b.x_pixel and
        a.y_pixel == b.y_pixel;
}

fn renderSession(allocator: std.mem.Allocator, tty: *vaxis.tty.PosixTty, session: line_editor.LineSession, capabilities: TerminalCapabilities, winsize: vaxis.Winsize) !void {
    const rendered = try session.render(allocator, .{
        .width = winsize.cols,
        .height = winsize.rows,
        .width_method = capabilities.widthMethod(),
        .synchronized_output = capabilities.synchronized_output,
    });
    defer allocator.free(rendered);
    try writeTtyAll(tty, rendered);
}

fn writeTtyAll(tty: *vaxis.tty.PosixTty, bytes: []const u8) !void {
    try tty.writer().writeAll(bytes);
    try tty.writer().flush();
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

    pub fn arm(self: *OneShotReader) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .idle) return error.ReadAlreadyPending;
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

test "terminal parser emits tab key" {
    var parser = TerminalParser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\t", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(isCompletionTab(events.items[0].key_press));
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

    try reader.arm();
    try rawWriteAll(input.write.handle, "abc");

    var wake_buffer: [8]u8 = undefined;
    const wake_n = try readAllFromFile(std.testing.io, wake.read, &wake_buffer);
    try std.testing.expectEqual(@as(usize, 1), wake_n);

    const bytes = try reader.takeReady();
    try std.testing.expectEqualStrings("abc", bytes);
}

test "one-shot reader rejects overlapping arms" {
    var input = try makePipe(std.testing.io);
    defer input.write.close(std.testing.io);
    var wake = try makePipe(std.testing.io);
    defer wake.read.close(std.testing.io);

    var reader = try OneShotReader.init(std.testing.allocator, std.testing.io, input.read, wake.write);
    defer reader.deinit();
    try reader.start();

    try reader.arm();
    try std.testing.expectError(error.ReadAlreadyPending, reader.arm());
    try rawWriteAll(input.write.handle, "x");
    var wake_buffer: [8]u8 = undefined;
    _ = try readAllFromFile(std.testing.io, wake.read, &wake_buffer);
    _ = try reader.takeReady();
}
