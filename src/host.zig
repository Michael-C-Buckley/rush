//! Host effects boundary for the rewritten shell.

const std = @import("std");

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

pub const DirectoryEntry = struct {
    name: []const u8,
    kind: FileKind = .other,

    pub fn validate(self: DirectoryEntry) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const ListDirResult = struct {
    allocator: std.mem.Allocator,
    entries: []const DirectoryEntry,

    pub fn deinit(self: *ListDirResult) void {
        for (self.entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn validate(self: ListDirResult) void {
        for (self.entries) |entry| entry.validate();
    }
};

pub const ListDirError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    SystemResources,
    Unexpected,
};

pub const ChangeDirError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    Unexpected,
};

pub const CurrentDirError = error{
    AccessDenied,
    NameTooLong,
    Unexpected,
};

pub const FileStatusError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    SystemResources,
    Unexpected,
};

pub const FdFlagError = error{
    BadFd,
    Unexpected,
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
    fallback_argv: ?[:null]const ?[*:0]const u8 = null,
    envp: [:null]const ?[*:0]const u8,
    cwd: ?[]const u8 = null,
    fd_actions: []const SpawnFdAction = &.{},
    process_group: ?Pid = null,

    pub fn validate(self: SpawnRequest) void {
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

    pub fn setCloseOnExec(_: *RealHost, fd: Fd, enabled: bool) platform.FdFlagError!void {
        try platform.setCloseOnExec(fd, enabled);
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

    pub fn existsZ(_: *RealHost, path: [:0]const u8) bool {
        return platform.existsZ(path);
    }

    pub fn fileStatusZ(_: *RealHost, path: [:0]const u8) platform.FileStatusError!FileStatus {
        return platform.fileStatusZ(path);
    }

    pub fn listDir(_: *RealHost, allocator: std.mem.Allocator, path: []const u8) platform.ListDirError!ListDirResult {
        return platform.listDir(allocator, path);
    }

    pub fn changeDir(_: *RealHost, path: []const u8) platform.ChangeDirError!void {
        return platform.changeDir(path);
    }

    pub fn currentDir(_: *RealHost, allocator: std.mem.Allocator) platform.CurrentDirError![]const u8 {
        return platform.currentDir(allocator);
    }

    pub fn setFileCreationMask(_: *RealHost, mask: u32) u32 {
        return platform.setFileCreationMask(mask);
    }

    pub fn spawn(_: *RealHost, request: SpawnRequest) platform.SpawnError!SpawnResult {
        return platform.spawn(request);
    }

    pub fn exec(_: *RealHost, request: SpawnRequest) platform.SpawnError!void {
        return platform.exec(request);
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
