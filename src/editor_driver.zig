//! Cooperative driver pieces for the future terminal line editor.

const Self = @This();

const std = @import("std");
const builtin = @import("builtin");

const read_chunk_size = 4096;

pub const DriverEvent = union(enum) {
    tty_read_ready,
};

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
