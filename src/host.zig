//! Host effects boundary for the rewritten shell.

pub const platform = @import("host/platform.zig");

pub const Fd = enum(i32) {
    stdin = 0,
    stdout = 1,
    stderr = 2,
    _,

    pub fn raw(self: Fd) i32 {
        return @intFromEnum(self);
    }
};

pub const Pid = i32;

pub const OpenAccess = enum {
    read_only,
    write_only,
    read_write,
};

pub const OpenOptions = struct {
    access: OpenAccess = .read_only,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,
    mode: u32 = 0o666,
};

pub const Pipe = struct {
    read: Fd,
    write: Fd,
};

pub const FileKind = enum {
    file,
    directory,
    symlink,
    other,
};

pub const FileStatus = struct {
    kind: FileKind,
    executable: bool = false,
};

pub const SpawnFdAction = union(enum) {
    close: Fd,
    duplicate: struct {
        from: Fd,
        to: Fd,
    },
};

pub const SpawnRequest = struct {
    path: [:0]const u8,
    argv: [:null]const ?[*:0]const u8,
    envp: [:null]const ?[*:0]const u8,
    cwd: ?[]const u8 = null,
    fd_actions: []const SpawnFdAction = &.{},
    process_group: ?Pid = null,

    pub fn validate(self: SpawnRequest) void {
        const std = @import("std");
        std.debug.assert(self.path.len != 0);
        std.debug.assert(self.argv.len != 0);
        std.debug.assert(self.argv[0] != null);
    }
};

pub const SpawnResult = struct {
    pid: Pid,
};

pub const ForkResult = union(enum) {
    child,
    parent: Pid,
};

pub const CloseError = error{
    Interrupted,
    InputOutput,
    Unexpected,
};

pub const ReadError = error{
    WouldBlock,
    InputOutput,
    SystemResources,
    Unexpected,
};

pub const DuplicateError = error{
    BadFd,
    Interrupted,
    SystemResources,
    Unexpected,
};

pub const PipeError = error{
    SystemResources,
    Unexpected,
};

pub const ForkError = error{
    SystemResources,
    Unexpected,
};

pub const WaitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    stopped: u8,
    continued,

    pub fn shellStatus(self: WaitStatus) u8 {
        return switch (self) {
            .exited => |status| status,
            .signaled => |signal| 128 + signal,
            .stopped, .continued => 0,
        };
    }
};

pub const DirectoryEntry = struct {
    name: []const u8,
    kind: FileKind,
};

pub const RealHost = struct {
    pub fn read(_: *RealHost, fd: Fd, buffer: []u8) platform.ReadError!usize {
        return platform.read(fd, buffer);
    }

    pub fn writeAll(_: *RealHost, fd: Fd, bytes: []const u8) platform.WriteError!void {
        try platform.writeAll(fd, bytes);
    }

    pub fn openZ(_: *RealHost, path: [:0]const u8, options: OpenOptions) platform.OpenError!Fd {
        return platform.openZ(path, options);
    }

    pub fn close(_: *RealHost, fd: Fd) platform.CloseError!void {
        try platform.close(fd);
    }

    pub fn duplicate(_: *RealHost, fd: Fd) platform.DuplicateError!Fd {
        return platform.duplicate(fd);
    }

    pub fn duplicateTo(_: *RealHost, from: Fd, to: Fd) platform.DuplicateError!void {
        try platform.duplicateTo(from, to);
    }

    pub fn pipe(_: *RealHost) platform.PipeError!Pipe {
        return platform.pipe();
    }

    pub fn forkProcess(_: *RealHost) platform.ForkError!ForkResult {
        return platform.forkProcess();
    }

    pub fn exit(_: *RealHost, status: u8) noreturn {
        platform.exit(status);
    }

    pub fn isExecutableZ(_: *RealHost, path: [:0]const u8) bool {
        return platform.isExecutableZ(path);
    }

    pub fn spawn(_: *RealHost, request: SpawnRequest) platform.SpawnError!SpawnResult {
        return platform.spawn(request);
    }

    pub fn wait(_: *RealHost, pid: Pid) platform.WaitError!WaitStatus {
        return platform.wait(pid);
    }

    pub fn spawnAndWait(
        _: *RealHost,
        request: SpawnRequest,
    ) platform.SpawnError!WaitStatus {
        return platform.spawnAndWait(request);
    }
};
