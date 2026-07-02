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
    block_device,
    character_device,
    file,
    directory,
    named_pipe,
    symlink,
    socket,
    other,
};

pub const FileStatus = struct {
    kind: FileKind,
    size: u64 = 0,
    mode: u32 = 0,
    device: u64 = 0,
    inode: u64 = 0,
    mtime_sec: i64 = 0,
    mtime_nsec: i64 = 0,

    pub fn sameFile(self: FileStatus, other: FileStatus) bool {
        return self.device == other.device and self.inode == other.inode;
    }

    pub fn newerThan(self: FileStatus, other: FileStatus) bool {
        return self.mtime_sec > other.mtime_sec or
            (self.mtime_sec == other.mtime_sec and self.mtime_nsec > other.mtime_nsec);
    }

    pub fn olderThan(self: FileStatus, other: FileStatus) bool {
        return self.mtime_sec < other.mtime_sec or
            (self.mtime_sec == other.mtime_sec and self.mtime_nsec < other.mtime_nsec);
    }
};

pub const FileAccess = enum {
    read,
    write,
    execute,
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

pub const DeleteFileError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
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

pub const KillError = error{
    AccessDenied,
    NoSuchProcess,
    InvalidSignal,
    Unexpected,
};

pub const ProcessGroupError = error{
    AccessDenied,
    NoSuchProcess,
    Unexpected,
};

pub const TerminalProcessGroupError = error{
    NotATerminal,
    NotAPgrpMember,
    Unexpected,
};

pub const SignalDispositionError = error{
    InvalidSignal,
    Unexpected,
};

pub const ResourceLimitKind = enum {
    core,
    data,
    file_size,
    open_files,
    stack,
    cpu_time,
    address_space,
};

pub const ResourceLimit = struct {
    soft: ?u64,
    hard: ?u64,
};

pub const ResourceLimitError = error{
    PermissionDenied,
    LimitTooBig,
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
    default_signals: []const u8 = &.{},
    process_group: ?Pid = null,

    pub fn validate(self: SpawnRequest) void {
        std.debug.assert(self.path.len != 0);
        std.debug.assert(self.argv.len != 0);
        std.debug.assert(self.argv[0] != null);
        for (self.default_signals) |signal| std.debug.assert(signal != 0);
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

pub const TimedReadResult = union(enum) {
    read: usize,
    timeout,
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
            .stopped => |signal| 128 + signal,
            .continued => 0,
        };
    }
};

pub const RealHost = struct {
    pub fn read(_: *RealHost, fd: Fd, buffer: []u8) platform.ReadError!usize {
        return platform.read(fd, buffer);
    }

    pub fn readWithTimeout(_: *RealHost, fd: Fd, buffer: []u8, timeout_ms: u64) platform.ReadError!TimedReadResult {
        return platform.readWithTimeout(fd, buffer, timeout_ms);
    }

    pub fn readReady(_: *RealHost, fd: Fd, timeout_ms: u64) bool {
        return platform.readReady(fd, timeout_ms);
    }

    pub fn readInteractiveKey(_: *RealHost, timeout_ms: u64) ?u8 {
        return platform.readInteractiveKey(.stdin, timeout_ms);
    }

    pub fn disableTerminalEcho(_: *RealHost, fd: Fd) ?platform.TerminalMode {
        return platform.disableTerminalEcho(fd);
    }

    pub fn restoreTerminalMode(_: *RealHost, fd: Fd, mode: platform.TerminalMode) void {
        platform.restoreTerminalMode(fd, mode);
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

    pub fn deleteFileZ(_: *RealHost, path: [:0]const u8) platform.DeleteFileError!void {
        try platform.deleteFileZ(path);
    }

    pub fn duplicate(_: *RealHost, fd: Fd) platform.DuplicateError!Fd {
        return platform.duplicate(fd);
    }

    pub fn duplicateAtLeast(_: *RealHost, fd: Fd, min_fd: u31) platform.DuplicateError!Fd {
        return platform.duplicateAtLeast(fd, min_fd);
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

    pub fn fileTestStatusZ(_: *RealHost, path: [:0]const u8, follow_symlinks: bool) ?FileStatus {
        return platform.fileTestStatusZ(path, follow_symlinks);
    }

    pub fn fileAccessZ(_: *RealHost, path: [:0]const u8, access: FileAccess) bool {
        return platform.fileAccessZ(path, access);
    }

    pub fn isTerminalFd(_: *RealHost, fd: Fd) bool {
        return platform.isTerminalFd(fd);
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

    pub fn currentProcessId(_: *RealHost) Pid {
        return platform.currentProcessId();
    }

    pub fn currentProcessGroup(_: *RealHost) Pid {
        return platform.currentProcessGroup();
    }

    pub fn currentParentProcessId(_: *RealHost) Pid {
        return platform.currentParentProcessId();
    }

    pub fn sendSignal(_: *RealHost, pid: Pid, signal: u8) platform.KillError!void {
        try platform.sendSignal(pid, signal);
    }

    pub fn setProcessGroup(_: *RealHost, pid: Pid, process_group: Pid) platform.ProcessGroupError!void {
        try platform.setProcessGroup(pid, process_group);
    }

    pub fn terminalProcessGroup(_: *RealHost, fd: Fd) platform.TerminalProcessGroupError!Pid {
        return platform.terminalProcessGroup(fd);
    }

    pub fn setTerminalProcessGroup(_: *RealHost, fd: Fd, process_group: Pid) platform.TerminalProcessGroupError!void {
        try platform.setTerminalProcessGroup(fd, process_group);
    }

    pub fn setSignalIgnored(_: *RealHost, signal: u8) platform.SignalDispositionError!void {
        try platform.setSignalIgnored(signal);
    }

    pub fn setSignalDefault(_: *RealHost, signal: u8) platform.SignalDispositionError!void {
        try platform.setSignalDefault(signal);
    }

    pub fn installSignalTrap(_: *RealHost, signal: u8) platform.SignalDispositionError!void {
        try platform.installSignalTrap(signal);
    }

    pub fn consumePendingSignal(_: *RealHost, signal: u8) bool {
        return platform.consumePendingSignal(signal);
    }

    pub fn getResourceLimit(_: *RealHost, kind: ResourceLimitKind) platform.ResourceLimitError!ResourceLimit {
        return platform.getResourceLimit(kind);
    }

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    pub fn setResourceLimit(_: *RealHost, kind: ResourceLimitKind, limit: ResourceLimit) platform.ResourceLimitError!void {
        try platform.setResourceLimit(kind, limit);
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

    pub fn waitNonBlocking(_: *RealHost, pid: Pid) platform.WaitError!?WaitStatus {
        return platform.waitNonBlocking(pid);
    }

    pub fn waitJobEvent(_: *RealHost, pid: Pid) platform.WaitError!WaitStatus {
        return platform.waitJobEvent(pid);
    }

    pub fn waitJobEventInterruptible(_: *RealHost, pid: Pid) platform.WaitError!WaitStatus {
        return platform.waitJobEventInterruptible(pid);
    }

    pub fn waitInterruptible(_: *RealHost, pid: Pid) platform.WaitError!WaitStatus {
        return platform.waitInterruptible(pid);
    }

    pub fn spawnAndWait(
        _: *RealHost,
        request: SpawnRequest,
    ) platform.SpawnError!WaitStatus {
        return platform.spawnAndWait(request);
    }
};
