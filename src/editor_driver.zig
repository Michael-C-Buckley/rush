//! Cooperative driver pieces for the future terminal line editor.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

const line_editor = @import("line_editor.zig");

const read_chunk_size = 4096;

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
                vaxis.ctlseqs.bp_set,
        );
        self.bracketed_paste = true;
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

    pub fn reset(self: TerminalCapabilities, tty: *vaxis.tty.PosixTty) void {
        if (self.kitty_keyboard) writeTtyAll(tty, vaxis.ctlseqs.csi_u_pop) catch {};
        if (self.unicode) writeTtyAll(tty, vaxis.ctlseqs.unicode_reset) catch {};
        if (self.bracketed_paste) writeTtyAll(tty, vaxis.ctlseqs.bp_reset) catch {};
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
            .mouse, .mouse_leave, .paste, .color_report, .color_scheme, .winsize => null,
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
};

pub fn readLineFromTty(allocator: std.mem.Allocator, io: std.Io, options: ReadLineOptions) !?[]const u8 {
    if (comptime (builtin.is_test or builtin.os.tag == .windows)) return error.Unsupported;

    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.tty.PosixTty.init(io, &tty_buffer);
    defer tty.deinit();

    var wake = try makePipe(io);
    defer wake.read.close(io);

    const read_fd = try rawDup(tty.fd.handle);
    const read_file: std.Io.File = .{ .handle = read_fd, .flags = .{ .nonblocking = false } };
    var reader = try OneShotReader.init(allocator, io, read_file, wake.write);
    defer reader.deinit();
    try reader.start();

    var terminal_parser = TerminalParser.init(allocator);
    defer terminal_parser.deinit();
    var capabilities: TerminalCapabilities = .{};
    defer capabilities.reset(&tty);
    var events: std.ArrayList(TerminalEvent) = .empty;
    defer events.deinit(allocator);
    var session = try line_editor.LineSession.init(allocator, options.prompt);
    defer session.deinit();

    try capabilities.sendQueries(&tty);
    try renderSession(allocator, &tty, session, capabilities);
    try reader.arm();
    while (session.state == .editing) {
        var wake_buffer: [32]u8 = undefined;
        _ = try rawRead(wake.read.handle, &wake_buffer);
        const bytes = try reader.takeReady();
        terminal_parser.resetEventText();
        events.clearRetainingCapacity();
        try terminal_parser.feed(bytes, &events);
        for (events.items) |event| {
            switch (event) {
                .key_press => |key| try session.handleKey(key),
                .capability => |capability| try capabilities.apply(allocator, &tty, capability),
                .key_release, .paste_start, .paste_end, .focus_in, .focus_out => {},
            }
        }
        if (session.state == .editing) {
            try renderSession(allocator, &tty, session, capabilities);
            try reader.arm();
        }
    }

    try writeTtyAll(&tty, "\r\n");
    if (session.state == .submitted) return session.takeSubmittedLine();
    return null;
}

fn renderSession(allocator: std.mem.Allocator, tty: *vaxis.tty.PosixTty, session: line_editor.LineSession, capabilities: TerminalCapabilities) !void {
    const rendered = try session.render(allocator, .{
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
