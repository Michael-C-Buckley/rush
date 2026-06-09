//! Platform fd readiness loop for editor event sources.

const std = @import("std");
const builtin = @import("builtin");

pub const Source = enum(u32) {
    tty_input,
    resize,
    prompt_redraw,
};

pub const Event = struct {
    source: Source,
};

pub const EventLoop = switch (builtin.os.tag) {
    .linux => EpollEventLoop,
    .macos, .freebsd, .openbsd, .netbsd, .dragonfly => KqueueEventLoop,
    else => @compileError("unsupported event loop platform"),
};

const KqueueEventLoop = struct {
    fd: std.posix.fd_t,

    pub fn init() !KqueueEventLoop {
        const fd = std.c.kqueue();
        if (fd < 0) return error.Unexpected;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *KqueueEventLoop) void {
        closeFd(self.fd);
        self.* = undefined;
    }

    pub fn addReadFd(self: *KqueueEventLoop, fd: std.posix.fd_t, source: Source) !void {
        const change: std.posix.Kevent = .{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = @intFromEnum(source),
        };
        _ = try std.Io.Kqueue.kevent(self.fd, &.{change}, &.{}, null);
    }

    pub fn removeFd(self: *KqueueEventLoop, fd: std.posix.fd_t) !void {
        const change: std.posix.Kevent = .{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        _ = try std.Io.Kqueue.kevent(self.fd, &.{change}, &.{}, null);
    }

    pub fn wait(self: *KqueueEventLoop, out: []Event) ![]Event {
        return self.waitTimeout(out, null);
    }

    pub fn waitTimeout(self: *KqueueEventLoop, out: []Event, timeout_ms: ?u64) ![]Event {
        var events: [16]std.posix.Kevent = undefined;
        const timeout: ?std.posix.timespec = if (timeout_ms) |ms| .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        } else null;
        const count = try std.Io.Kqueue.kevent(self.fd, &.{}, events[0..@min(events.len, out.len)], if (timeout) |*value| value else null);
        for (events[0..count], 0..) |event, index| {
            out[index] = .{ .source = @enumFromInt(event.udata) };
        }
        return out[0..count];
    }
};

const EpollEventLoop = struct {
    fd: std.posix.fd_t,

    pub fn init() !EpollEventLoop {
        const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc) },
            else => return error.Unexpected,
        }
    }

    pub fn deinit(self: *EpollEventLoop) void {
        closeFd(self.fd);
        self.* = undefined;
    }

    pub fn addReadFd(self: *EpollEventLoop, fd: std.posix.fd_t, source: Source) !void {
        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP,
            .data = .{ .u32 = @intFromEnum(source) },
        };
        const rc = std.os.linux.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            else => return error.Unexpected,
        }
    }

    pub fn removeFd(self: *EpollEventLoop, fd: std.posix.fd_t) !void {
        const rc = std.os.linux.epoll_ctl(self.fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            else => return error.Unexpected,
        }
    }

    pub fn wait(self: *EpollEventLoop, out: []Event) ![]Event {
        return self.waitTimeout(out, null);
    }

    pub fn waitTimeout(self: *EpollEventLoop, out: []Event, timeout_ms: ?u64) ![]Event {
        var events: [16]std.os.linux.epoll_event = undefined;
        const timeout: i32 = if (timeout_ms) |ms| @intCast(@min(ms, @as(u64, @intCast(std.math.maxInt(i32))))) else -1;
        const count = std.os.linux.epoll_wait(self.fd, &events, @intCast(@min(events.len, out.len)), timeout);
        switch (std.os.linux.errno(count)) {
            .SUCCESS => {},
            .INTR => return self.waitTimeout(out, timeout_ms),
            else => return error.Unexpected,
        }
        const n: usize = @intCast(count);
        for (events[0..n], 0..) |event, index| {
            out[index] = .{ .source = @enumFromInt(event.data.u32) };
        }
        return out[0..n];
    }
};

test "event loop reports readable pipe fd" {
    var pipe = try makeTestPipe();
    defer pipe.close();

    var loop = try EventLoop.init();
    defer loop.deinit();
    try loop.addReadFd(pipe.read, .tty_input);

    _ = try std.posix.write(pipe.write, "x");
    var events: [4]Event = undefined;
    const ready = try loop.wait(&events);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(Source.tty_input, ready[0].source);

    var buffer: [1]u8 = undefined;
    _ = try std.posix.read(pipe.read, &buffer);
}

test "event loop timeout returns no events" {
    var loop = try EventLoop.init();
    defer loop.deinit();

    var events: [4]Event = undefined;
    const ready = try loop.waitTimeout(&events, 0);
    try std.testing.expectEqual(@as(usize, 0), ready.len);
}

const TestPipe = struct {
    read: std.posix.fd_t,
    write: std.posix.fd_t,

    fn close(self: *TestPipe) void {
        closeFd(self.read);
        closeFd(self.write);
        self.* = undefined;
    }
};

fn makeTestPipe() !TestPipe {
    var fds: [2]std.posix.fd_t = undefined;
    try std.posix.pipe2(&fds, .{ .CLOEXEC = true });
    return .{ .read = fds[0], .write = fds[1] };
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) {
        const rc = std.c.close(fd);
        switch (std.c.errno(rc)) {
            .SUCCESS, .BADF => return,
            .INTR => continue,
            else => return,
        }
    }
}
