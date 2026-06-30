//! Platform syscall shims used by `RealHost`.

const std = @import("std");
const builtin = @import("builtin");

const host = @import("../host.zig");

extern "c" fn readdir(dir: *std.c.DIR) ?*std.c.dirent;

pub const ReadError = host.ReadError;

pub const WriteError = error{
    BadFd,
    WouldBlock,
    InputOutput,
    BrokenPipe,
    SystemResources,
    Unexpected,
};

pub const OpenError = error{
    AccessDenied,
    FileNotFound,
    PathAlreadyExists,
    NotDir,
    IsDir,
    NameTooLong,
    SystemResources,
    Unexpected,
};

pub const FileStatusError = host.FileStatusError;

pub const ListDirError = host.ListDirError || std.mem.Allocator.Error;

pub const ChangeDirError = host.ChangeDirError;

pub const CurrentDirError = host.CurrentDirError || std.mem.Allocator.Error;

pub const CloseError = host.CloseError;

pub const DuplicateError = host.DuplicateError;

pub const FdFlagError = host.FdFlagError;

pub const PipeError = host.PipeError;

pub const ForkError = host.ForkError;

pub const SpawnError = error{
    SystemResources,
    Unexpected,
};

pub const WaitError = error{
    Unexpected,
};

pub const KillError = host.KillError;

pub const SignalDispositionError = host.SignalDispositionError;

pub fn read(fd: host.Fd, buffer: []u8) ReadError!usize {
    if (buffer.len == 0) return 0;
    return switch (builtin.os.tag) {
        .linux => linuxRead(fd, buffer),
        .macos, .freebsd, .openbsd, .netbsd => libcRead(fd, buffer),
        else => @compileError("unsupported host OS"),
    };
}

pub fn writeAll(fd: host.Fd, bytes: []const u8) WriteError!void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try write(fd, bytes[written..]);
    }
}

pub fn write(fd: host.Fd, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    return switch (builtin.os.tag) {
        .linux => linuxWrite(fd, bytes),
        .macos, .freebsd, .openbsd, .netbsd => libcWrite(fd, bytes),
        else => @compileError("unsupported host OS"),
    };
}

pub fn openZ(path: [:0]const u8, options: host.OpenOptions) OpenError!host.Fd {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxOpenZ(path, options),
        .macos, .freebsd, .openbsd, .netbsd => libcOpenZ(path, options),
        else => @compileError("unsupported host OS"),
    };
}

pub fn close(fd: host.Fd) CloseError!void {
    return switch (builtin.os.tag) {
        .linux => linuxClose(fd),
        .macos, .freebsd, .openbsd, .netbsd => libcClose(fd),
        else => @compileError("unsupported host OS"),
    };
}

pub fn duplicate(fd: host.Fd) DuplicateError!host.Fd {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicate(fd),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicate(fd),
        else => @compileError("unsupported host OS"),
    };
}

pub fn duplicateAtLeast(fd: host.Fd, min_fd: u31) DuplicateError!host.Fd {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicateAtLeast(fd, min_fd),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicateAtLeast(fd, min_fd),
        else => @compileError("unsupported host OS"),
    };
}

pub fn duplicateTo(from: host.Fd, to: host.Fd) DuplicateError!void {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicateTo(from, to),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicateTo(from, to),
        else => @compileError("unsupported host OS"),
    };
}

pub fn setCloseOnExec(fd: host.Fd, enabled: bool) FdFlagError!void {
    return switch (builtin.os.tag) {
        .linux => linuxSetCloseOnExec(fd, enabled),
        .macos, .freebsd, .openbsd, .netbsd => libcSetCloseOnExec(fd, enabled),
        else => @compileError("unsupported host OS"),
    };
}

pub fn pipe() PipeError!host.Pipe {
    return switch (builtin.os.tag) {
        .linux => linuxPipe(),
        .macos, .freebsd, .openbsd, .netbsd => libcPipe(),
        else => @compileError("unsupported host OS"),
    };
}

pub fn forkProcess() ForkError!host.ForkResult {
    return switch (builtin.os.tag) {
        .linux => linuxForkProcess(),
        .macos, .freebsd, .openbsd, .netbsd => libcForkProcess(),
        else => @compileError("unsupported host OS"),
    };
}

pub fn exit(status: u8) noreturn {
    switch (builtin.os.tag) {
        .linux => std.os.linux.exit(status),
        .macos, .freebsd, .openbsd, .netbsd => std.c._exit(status),
        else => @compileError("unsupported host OS"),
    }
}

pub fn currentProcessId() host.Pid {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos, .freebsd, .openbsd, .netbsd => @intCast(std.c.getpid()),
        else => @compileError("unsupported host OS"),
    };
}

pub fn sendSignal(pid: host.Pid, signal: u8) KillError!void {
    return switch (builtin.os.tag) {
        .linux => linuxSendSignal(pid, signal),
        .macos, .freebsd, .openbsd, .netbsd => libcSendSignal(pid, signal),
        else => @compileError("unsupported host OS"),
    };
}

pub fn setSignalIgnored(signal: u8) SignalDispositionError!void {
    setSignalAction(signal, std.posix.SIG.IGN) catch return error.InvalidSignal;
}

pub fn setSignalDefault(signal: u8) SignalDispositionError!void {
    setSignalAction(signal, std.posix.SIG.DFL) catch return error.InvalidSignal;
}

fn setSignalAction(signal: u8, handler: ?std.posix.Sigaction.handler_fn) !void {
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(@enumFromInt(signal), &action, null);
}

pub fn isExecutableZ(path: [:0]const u8) bool {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxIsExecutableZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcIsExecutableZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn existsZ(path: [:0]const u8) bool {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxExistsZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcExistsZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn fileStatusZ(path: [:0]const u8) FileStatusError!host.FileStatus {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxFileStatusZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcFileStatusZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn fileTestStatusZ(path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxFileTestStatusZ(path, follow_symlinks),
        .macos, .freebsd, .openbsd, .netbsd => libcFileTestStatusZ(path, follow_symlinks),
        else => @compileError("unsupported host OS"),
    };
}

pub fn fileAccessZ(path: [:0]const u8, access: host.FileAccess) bool {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxFileAccessZ(path, access),
        .macos, .freebsd, .openbsd, .netbsd => libcFileAccessZ(path, access),
        else => @compileError("unsupported host OS"),
    };
}

pub fn isTerminalFd(fd: host.Fd) bool {
    return std.c.isatty(@intCast(fd.raw())) == 1;
}

pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ListDirError!host.ListDirResult {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxListDir(allocator, path),
        .macos, .freebsd, .openbsd, .netbsd => libcListDir(allocator, path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn changeDir(path: []const u8) ChangeDirError!void {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxChangeDir(path),
        .macos, .freebsd, .openbsd, .netbsd => libcChangeDir(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn currentDir(allocator: std.mem.Allocator) CurrentDirError![]const u8 {
    return switch (builtin.os.tag) {
        .linux => linuxCurrentDir(allocator),
        .macos, .freebsd, .openbsd, .netbsd => libcCurrentDir(allocator),
        else => @compileError("unsupported host OS"),
    };
}

pub fn setFileCreationMask(mask: u32) u32 {
    return @intCast(std.c.umask(@intCast(mask)));
}

pub fn spawnAndWait(request: host.SpawnRequest) SpawnError!host.WaitStatus {
    request.validate();
    const spawned = try spawn(request);
    return wait(spawned.pid) catch error.Unexpected;
}

pub fn spawn(request: host.SpawnRequest) SpawnError!host.SpawnResult {
    request.validate();
    return switch (builtin.os.tag) {
        .linux => linuxSpawn(request),
        .macos, .freebsd, .openbsd, .netbsd => libcSpawn(request),
        else => @compileError("unsupported host OS"),
    };
}

pub fn exec(request: host.SpawnRequest) SpawnError!void {
    request.validate();
    return switch (builtin.os.tag) {
        .linux => linuxExec(request),
        .macos, .freebsd, .openbsd, .netbsd => libcExec(request),
        else => @compileError("unsupported host OS"),
    };
}

pub fn wait(pid: host.Pid) WaitError!host.WaitStatus {
    return switch (builtin.os.tag) {
        .linux => linuxWait(pid),
        .macos, .freebsd, .openbsd, .netbsd => libcWait(pid),
        else => @compileError("unsupported host OS"),
    };
}

fn linuxRead(fd: host.Fd, buffer: []u8) ReadError!usize {
    const linux = std.os.linux;
    while (true) {
        const rc = linux.read(fd.raw(), buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF, .FAULT, .INVAL, .ISDIR => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn libcRead(fd: host.Fd, buffer: []u8) ReadError!usize {
    while (true) {
        const rc = std.c.read(@intCast(fd.raw()), buffer.ptr, buffer.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF, .FAULT, .INVAL, .ISDIR => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn linuxWrite(fd: host.Fd, bytes: []const u8) WriteError!usize {
    const linux = std.os.linux;
    while (true) {
        const rc = linux.write(fd.raw(), bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF => return error.BadFd,
            .DESTADDRREQ, .DQUOT, .FBIG, .INVAL, .NOSPC, .PERM => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn libcWrite(fd: host.Fd, bytes: []const u8) WriteError!usize {
    while (true) {
        const rc = std.c.write(@intCast(fd.raw()), bytes.ptr, bytes.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .BADF => return error.BadFd,
            .DESTADDRREQ, .DQUOT, .FBIG, .INVAL, .NOSPC, .PERM => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

fn linuxOpenZ(path: [:0]const u8, options: host.OpenOptions) OpenError!host.Fd {
    const linux = std.os.linux;
    var flags = linuxOpenFlags(options);
    flags.CLOEXEC = true;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, flags, @intCast(options.mode));
    switch (linux.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .EXIST => return error.PathAlreadyExists,
        .NOTDIR => return error.NotDir,
        .ISDIR => return error.IsDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcOpenZ(path: [:0]const u8, options: host.OpenOptions) OpenError!host.Fd {
    var flags = libcOpenFlags(options);
    flags.CLOEXEC = true;
    const rc = std.c.open(path.ptr, flags, @as(std.c.mode_t, @intCast(options.mode)));
    switch (std.c.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .EXIST => return error.PathAlreadyExists,
        .NOTDIR => return error.NotDir,
        .ISDIR => return error.IsDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxClose(fd: host.Fd) CloseError!void {
    const linux = std.os.linux;
    const rc = linux.close(fd.raw());
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .INTR => return error.Interrupted,
        .IO => return error.InputOutput,
        .BADF => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn libcClose(fd: host.Fd) CloseError!void {
    const rc = std.c.close(@intCast(fd.raw()));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .INTR => return error.Interrupted,
        .IO => return error.InputOutput,
        .BADF => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn linuxDuplicate(fd: host.Fd) DuplicateError!host.Fd {
    const linux = std.os.linux;
    const rc = linux.dup(fd.raw());
    switch (linux.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcDuplicate(fd: host.Fd) DuplicateError!host.Fd {
    const rc = std.c.dup(@intCast(fd.raw()));
    switch (std.c.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxDuplicateAtLeast(fd: host.Fd, min_fd: u31) DuplicateError!host.Fd {
    const linux = std.os.linux;
    const rc = linux.fcntl(fd.raw(), linux.F.DUPFD_CLOEXEC, min_fd);
    switch (linux.errno(rc)) {
        .SUCCESS => return @enumFromInt(@as(i32, @intCast(rc))),
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcDuplicateAtLeast(fd: host.Fd, min_fd: u31) DuplicateError!host.Fd {
    const command = if (comptime @hasDecl(std.c.F, "DUPFD_CLOEXEC")) std.c.F.DUPFD_CLOEXEC else std.c.F.DUPFD;
    const rc = std.c.fcntl(@intCast(fd.raw()), command, @as(c_int, @intCast(min_fd)));
    switch (std.c.errno(rc)) {
        .SUCCESS => {
            const duplicated: host.Fd = @enumFromInt(@as(i32, @intCast(rc)));
            if (comptime !@hasDecl(std.c.F, "DUPFD_CLOEXEC")) {
                libcSetCloseOnExec(duplicated, true) catch |err| {
                    close(duplicated) catch {};
                    return switch (err) {
                        error.BadFd => error.BadFd,
                        error.Unexpected => error.Unexpected,
                    };
                };
            }
            return duplicated;
        },
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxDuplicateTo(from: host.Fd, to: host.Fd) DuplicateError!void {
    if (from == to) return;
    const linux = std.os.linux;
    const rc = linux.dup2(from.raw(), to.raw());
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcDuplicateTo(from: host.Fd, to: host.Fd) DuplicateError!void {
    if (from == to) return;
    const rc = std.c.dup2(@intCast(from.raw()), @intCast(to.raw()));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        .INTR => return error.Interrupted,
        .MFILE => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn linuxPipe() PipeError!host.Pipe {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return .{ .read = @enumFromInt(fds[0]), .write = @enumFromInt(fds[1]) },
        .MFILE, .NFILE, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcPipe() PipeError!host.Pipe {
    var fds: [2]std.c.fd_t = undefined;
    const rc = std.c.pipe(&fds);
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .MFILE, .NFILE, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    errdefer close(@enumFromInt(fds[0])) catch {};
    errdefer close(@enumFromInt(fds[1])) catch {};
    try setCloseOnExecForPipe(@enumFromInt(fds[0]));
    try setCloseOnExecForPipe(@enumFromInt(fds[1]));
    return .{ .read = @enumFromInt(fds[0]), .write = @enumFromInt(fds[1]) };
}

fn setCloseOnExecForPipe(fd: host.Fd) PipeError!void {
    const rc = std.c.fcntl(@intCast(fd.raw()), std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        else => return error.Unexpected,
    }
}

fn linuxSetCloseOnExec(fd: host.Fd, enabled: bool) FdFlagError!void {
    const linux = std.os.linux;
    const get_rc = linux.fcntl(fd.raw(), linux.F.GETFD, 0);
    const flags = switch (linux.errno(get_rc)) {
        .SUCCESS => get_rc,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    };
    const new_flags = if (enabled) flags | linux.FD_CLOEXEC else flags & ~@as(usize, linux.FD_CLOEXEC);
    const set_rc = linux.fcntl(fd.raw(), linux.F.SETFD, new_flags);
    switch (linux.errno(set_rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    }
}

fn libcSetCloseOnExec(fd: host.Fd, enabled: bool) FdFlagError!void {
    const get_rc = std.c.fcntl(@intCast(fd.raw()), std.c.F.GETFD, @as(c_int, 0));
    const flags: c_int = switch (std.c.errno(get_rc)) {
        .SUCCESS => get_rc,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    };
    const new_flags = if (enabled) flags | std.c.FD_CLOEXEC else flags & ~@as(c_int, std.c.FD_CLOEXEC);
    const set_rc = std.c.fcntl(@intCast(fd.raw()), std.c.F.SETFD, new_flags);
    switch (std.c.errno(set_rc)) {
        .SUCCESS => return,
        .BADF => return error.BadFd,
        else => return error.Unexpected,
    }
}

fn linuxForkProcess() ForkError!host.ForkResult {
    const rc = std.os.linux.fork();
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(rc);
    return if (pid == 0) .child else .{ .parent = pid };
}

fn libcForkProcess() ForkError!host.ForkResult {
    const rc = std.c.fork();
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(rc);
    return if (pid == 0) .child else .{ .parent = pid };
}

fn linuxIsExecutableZ(path: [:0]const u8) bool {
    const rc = std.os.linux.access(path.ptr, std.os.linux.X_OK);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn linuxExistsZ(path: [:0]const u8) bool {
    const rc = std.os.linux.access(path.ptr, std.os.linux.F_OK);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn linuxSendSignal(pid: host.Pid, signal: u8) KillError!void {
    const rc = std.os.linux.kill(pid, @enumFromInt(signal));
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.AccessDenied,
        .SRCH => return error.NoSuchProcess,
        .INVAL => return error.InvalidSignal,
        else => return error.Unexpected,
    }
}

fn libcIsExecutableZ(path: [:0]const u8) bool {
    const rc = std.c.access(path.ptr, std.c.X_OK);
    return std.c.errno(rc) == .SUCCESS;
}

fn libcExistsZ(path: [:0]const u8) bool {
    const rc = std.c.access(path.ptr, std.c.F_OK);
    return std.c.errno(rc) == .SUCCESS;
}

fn libcSendSignal(pid: host.Pid, signal: u8) KillError!void {
    const rc = std.c.kill(@intCast(pid), @enumFromInt(signal));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .PERM => return error.AccessDenied,
        .SRCH => return error.NoSuchProcess,
        .INVAL => return error.InvalidSignal,
        else => return error.Unexpected,
    }
}

fn linuxFileStatusZ(path: [:0]const u8) FileStatusError!host.FileStatus {
    const linux = std.os.linux;
    var status: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, 0, file_status_mask, &status);
    switch (linux.errno(rc)) {
        .SUCCESS => return linuxStatusFromStatx(status),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

fn libcFileStatusZ(path: [:0]const u8) FileStatusError!host.FileStatus {
    var status: std.c.Stat = undefined;
    const rc = std.c.fstatat(std.c.AT.FDCWD, path.ptr, &status, 0);
    switch (std.c.errno(rc)) {
        .SUCCESS => return libcStatusFromStat(status),
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE, .MFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
}

const file_status_mask: std.os.linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .MTIME = true,
    .INO = true,
    .SIZE = true,
};

fn linuxFileTestStatusZ(path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
    const linux = std.os.linux;
    var flags: u32 = linux.AT.NO_AUTOMOUNT;
    if (!follow_symlinks) flags |= linux.AT.SYMLINK_NOFOLLOW;
    var statx = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, flags, file_status_mask, &statx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return linuxStatusFromStatx(statx);
}

fn linuxStatusFromStatx(statx: std.os.linux.Statx) host.FileStatus {
    return .{
        .kind = linuxFileKindFromMode(statx.mode),
        .size = statx.size,
        .mode = statx.mode,
        .device = (@as(u64, statx.dev_major) << 32) | statx.dev_minor,
        .inode = statx.ino,
        .mtime_sec = statx.mtime.sec,
        .mtime_nsec = statx.mtime.nsec,
    };
}

fn libcFileTestStatusZ(path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
    const flags: u32 = if (follow_symlinks) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    const fstatat_sym = if (std.posix.lfs64_abi) std.c.fstatat64 else std.c.fstatat;
    var stat = std.mem.zeroes(std.posix.Stat);
    const rc = fstatat_sym(std.c.AT.FDCWD, path.ptr, &stat, flags);
    if (std.c.errno(rc) != .SUCCESS) return null;
    return libcStatusFromStat(stat);
}

fn libcStatusFromStat(stat: std.posix.Stat) host.FileStatus {
    const mtime = stat.mtime();
    return .{
        .kind = libcFileKindFromMode(stat.mode),
        .size = @intCast(@max(stat.size, 0)),
        .mode = @intCast(stat.mode),
        .device = @intCast(stat.dev),
        .inode = @intCast(stat.ino),
        .mtime_sec = @intCast(mtime.sec),
        .mtime_nsec = @intCast(mtime.nsec),
    };
}

fn linuxFileAccessZ(path: [:0]const u8, access: host.FileAccess) bool {
    const mode: u32 = switch (access) {
        .read => std.os.linux.R_OK,
        .write => std.os.linux.W_OK,
        .execute => std.os.linux.X_OK,
    };
    const rc = std.os.linux.access(path.ptr, mode);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn libcFileAccessZ(path: [:0]const u8, access: host.FileAccess) bool {
    const mode: c_uint = switch (access) {
        .read => std.c.R_OK,
        .write => std.c.W_OK,
        .execute => std.c.X_OK,
    };
    const rc = std.c.access(path.ptr, mode);
    return std.c.errno(rc) == .SUCCESS;
}

fn linuxListDir(allocator: std.mem.Allocator, path: []const u8) ListDirError!host.ListDirResult {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const flags: std.os.linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = std.os.linux.openat(std.os.linux.AT.FDCWD, &path_z, flags, 0);
    switch (std.os.linux.errno(fd)) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => return error.SystemResources,
        else => return error.Unexpected,
    }
    const directory_fd: host.Fd = @enumFromInt(@as(i32, @intCast(fd)));
    defer close(directory_fd) catch {};

    var entries: std.ArrayList(host.DirectoryEntry) = .empty;
    errdefer freeDirectoryEntryList(allocator, &entries);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try linuxGetDents(directory_fd.raw(), &buffer);
        if (read_len == 0) break;
        var index: usize = 0;
        while (index < read_len) {
            const entry: *align(1) std.os.linux.dirent64 = @ptrCast(&buffer[index]);
            const name_start = index + @offsetOf(std.os.linux.dirent64, "name");
            const name_limit = entry.reclen - @offsetOf(std.os.linux.dirent64, "name");
            const name_len = std.mem.indexOfScalar(u8, buffer[name_start..][0..name_limit], 0) orelse name_limit;
            const name = buffer[name_start..][0..name_len];
            if (!isSpecialDirectoryEntry(name)) {
                const owned_name = try allocator.dupe(u8, name);
                entries.append(allocator, .{
                    .name = owned_name,
                    .kind = fileKindFromDirentType(entry.type),
                }) catch |err| {
                    allocator.free(owned_name);
                    return err;
                };
            }
            index += entry.reclen;
        }
    }

    const result: host.ListDirResult = .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
    result.validate();
    return result;
}

fn linuxGetDents(fd: i32, buffer: []u8) ListDirError!usize {
    while (true) {
        const rc = std.os.linux.getdents64(fd, buffer.ptr, buffer.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NAMETOOLONG => return error.NameTooLong,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

fn libcListDir(allocator: std.mem.Allocator, path: []const u8) ListDirError!host.ListDirResult {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const dir = std.c.opendir(&path_z) orelse return switch (std.c.errno(-1)) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .MFILE, .NFILE, .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
    defer _ = std.c.closedir(dir);

    var entries: std.ArrayList(host.DirectoryEntry) = .empty;
    errdefer freeDirectoryEntryList(allocator, &entries);

    while (readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (isSpecialDirectoryEntry(name)) continue;
        const owned_name = try allocator.dupe(u8, name);
        entries.append(allocator, .{
            .name = owned_name,
            .kind = fileKindFromDirentType(entry.type),
        }) catch |err| {
            allocator.free(owned_name);
            return err;
        };
    }

    const result: host.ListDirResult = .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
    result.validate();
    return result;
}

fn linuxChangeDir(path: []const u8) ChangeDirError!void {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const rc = std.os.linux.chdir(&path_z);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        else => return error.Unexpected,
    }
}

fn libcChangeDir(path: []const u8) ChangeDirError!void {
    const path_z = std.posix.toPosixPath(path) catch return error.NameTooLong;
    const rc = std.c.chdir(&path_z);
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        else => return error.Unexpected,
    }
}

fn linuxCurrentDir(allocator: std.mem.Allocator) CurrentDirError![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&buffer, buffer.len);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {
            const len = if (rc != 0 and buffer[rc - 1] == 0) rc - 1 else rc;
            return allocator.dupe(u8, buffer[0..len]);
        },
        .ACCES, .PERM => return error.AccessDenied,
        .RANGE, .NAMETOOLONG => return error.NameTooLong,
        else => return error.Unexpected,
    }
}

fn libcCurrentDir(allocator: std.mem.Allocator) CurrentDirError![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buffer, buffer.len)) |cwd| {
        return allocator.dupe(u8, std.mem.sliceTo(cwd, 0));
    }
    return switch (std.c.errno(-1)) {
        .ACCES, .PERM => error.AccessDenied,
        .RANGE, .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn isSpecialDirectoryEntry(name: []const u8) bool {
    return name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

fn freeDirectoryEntryList(allocator: std.mem.Allocator, entries: *std.ArrayList(host.DirectoryEntry)) void {
    for (entries.items) |entry| allocator.free(entry.name);
    entries.deinit(allocator);
}

fn fileKindFromDirentType(kind: u8) host.FileKind {
    return switch (kind) {
        std.c.DT.REG => .file,
        std.c.DT.DIR => .directory,
        std.c.DT.LNK => .symlink,
        else => .other,
    };
}

fn linuxFileKindFromMode(mode: std.os.linux.mode_t) host.FileKind {
    const S = std.os.linux.S;
    if (S.ISBLK(mode)) return .block_device;
    if (S.ISCHR(mode)) return .character_device;
    if (S.ISREG(mode)) return .file;
    if (S.ISDIR(mode)) return .directory;
    if (S.ISFIFO(mode)) return .named_pipe;
    if (S.ISLNK(mode)) return .symlink;
    if (S.ISSOCK(mode)) return .socket;
    return .other;
}

fn libcFileKindFromMode(mode: std.c.mode_t) host.FileKind {
    const S = std.c.S;
    if (S.ISBLK(mode)) return .block_device;
    if (S.ISCHR(mode)) return .character_device;
    if (S.ISREG(mode)) return .file;
    if (S.ISDIR(mode)) return .directory;
    if (S.ISFIFO(mode)) return .named_pipe;
    if (S.ISLNK(mode)) return .symlink;
    if (S.ISSOCK(mode)) return .socket;
    return .other;
}

fn linuxSpawn(request: host.SpawnRequest) SpawnError!host.SpawnResult {
    const linux = std.os.linux;
    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(fork_rc);
    if (pid == 0) {
        applyLinuxFdActions(request.fd_actions);
        const exec_rc = linux.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        if (linux.errno(exec_rc) == .NOEXEC) {
            if (request.fallback_argv) |argv| _ = linux.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
        }
        linux.exit(127);
    }

    return .{ .pid = pid };
}

fn linuxExec(request: host.SpawnRequest) SpawnError!void {
    const linux = std.os.linux;
    applyLinuxFdActions(request.fd_actions);
    const exec_rc = linux.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
    if (linux.errno(exec_rc) == .NOEXEC) {
        if (request.fallback_argv) |argv| _ = linux.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
    }
    return error.Unexpected;
}

fn linuxWait(pid: host.Pid) WaitError!host.WaitStatus {
    const linux = std.os.linux;
    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(pid, &status, 0);
        switch (linux.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(status),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn libcSpawn(request: host.SpawnRequest) SpawnError!host.SpawnResult {
    const fork_rc = std.c.fork();
    switch (std.c.errno(fork_rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(fork_rc);
    if (pid == 0) {
        applyLibcFdActions(request.fd_actions);
        const exec_rc = std.c.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        if (std.c.errno(exec_rc) == .NOEXEC) {
            if (request.fallback_argv) |argv| _ = std.c.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
        }
        std.c._exit(127);
    }

    return .{ .pid = pid };
}

fn libcExec(request: host.SpawnRequest) SpawnError!void {
    applyLibcFdActions(request.fd_actions);
    const exec_rc = std.c.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
    if (std.c.errno(exec_rc) == .NOEXEC) {
        if (request.fallback_argv) |argv| _ = std.c.execve(default_shell_path.ptr, argv.ptr, request.envp.ptr);
    }
    return error.Unexpected;
}

const default_shell_path: [:0]const u8 = "/bin/sh";

fn libcWait(pid: host.Pid) WaitError!host.WaitStatus {
    var status: c_int = 0;
    while (true) {
        const wait_rc = std.c.waitpid(pid, &status, 0);
        switch (std.c.errno(wait_rc)) {
            .SUCCESS => return decodeWaitStatus(@bitCast(status)),
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn applyLinuxFdActions(actions: []const host.SpawnFdAction) void {
    const linux = std.os.linux;
    for (actions) |action| switch (action) {
        .close => |fd| {
            const rc = linux.close(fd.raw());
            if (linux.errno(rc) != .SUCCESS) linux.exit(127);
        },
        .duplicate => |dup| {
            const rc = linux.dup2(dup.from.raw(), dup.to.raw());
            if (linux.errno(rc) != .SUCCESS) linux.exit(127);
        },
    };
}

fn applyLibcFdActions(actions: []const host.SpawnFdAction) void {
    for (actions) |action| switch (action) {
        .close => |fd| {
            const rc = std.c.close(@intCast(fd.raw()));
            if (std.c.errno(rc) != .SUCCESS) std.c._exit(127);
        },
        .duplicate => |dup| {
            const rc = std.c.dup2(@intCast(dup.from.raw()), @intCast(dup.to.raw()));
            if (std.c.errno(rc) != .SUCCESS) std.c._exit(127);
        },
    };
}

fn decodeWaitStatus(status: u32) host.WaitStatus {
    if ((status & 0xff) == 0x7f) return .{ .stopped = @intCast((status >> 8) & 0xff) };
    if ((status & 0x7f) == 0) return .{ .exited = @intCast((status >> 8) & 0xff) };
    return .{ .signaled = @intCast(status & 0x7f) };
}

fn linuxOpenFlags(options: host.OpenOptions) std.os.linux.O {
    var flags: std.os.linux.O = .{ .ACCMODE = accessMode(std.posix.ACCMODE, options.access) };
    flags.CREAT = options.create;
    flags.TRUNC = options.truncate;
    flags.APPEND = options.append;
    flags.EXCL = options.exclusive;
    return flags;
}

fn libcOpenFlags(options: host.OpenOptions) std.c.O {
    var flags: std.c.O = .{ .ACCMODE = accessMode(std.posix.ACCMODE, options.access) };
    flags.CREAT = options.create;
    flags.TRUNC = options.truncate;
    flags.APPEND = options.append;
    flags.EXCL = options.exclusive;
    return flags;
}

fn accessMode(comptime AccessMode: type, access: host.OpenAccess) AccessMode {
    return switch (access) {
        .read_only => .RDONLY,
        .write_only => .WRONLY,
        .read_write => .RDWR,
    };
}
