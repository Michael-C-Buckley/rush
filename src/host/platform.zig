//! Platform syscall shims used by `RealHost`.

const std = @import("std");
const builtin = @import("builtin");

const host = @import("../host.zig");

pub const WriteError = error{
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

pub const CloseError = host.CloseError;

pub const DuplicateError = host.DuplicateError;

pub const SpawnError = error{
    SystemResources,
    Unexpected,
};

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

pub fn duplicateTo(from: host.Fd, to: host.Fd) DuplicateError!void {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicateTo(from, to),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicateTo(from, to),
        else => @compileError("unsupported host OS"),
    };
}

pub fn isExecutableZ(path: [:0]const u8) bool {
    std.debug.assert(path.len != 0);
    return switch (builtin.os.tag) {
        .linux => linuxIsExecutableZ(path),
        .macos, .freebsd, .openbsd, .netbsd => libcIsExecutableZ(path),
        else => @compileError("unsupported host OS"),
    };
}

pub fn spawnAndWait(request: host.SpawnRequest) SpawnError!host.WaitStatus {
    request.validate();
    return switch (builtin.os.tag) {
        .linux => linuxSpawnAndWait(request),
        .macos, .freebsd, .openbsd, .netbsd => libcSpawnAndWait(request),
        else => @compileError("unsupported host OS"),
    };
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
            .BADF, .DESTADDRREQ, .DQUOT, .FBIG, .INVAL, .NOSPC, .PERM => return error.Unexpected,
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
            .BADF, .DESTADDRREQ, .DQUOT, .FBIG, .INVAL, .NOSPC, .PERM => return error.Unexpected,
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

fn linuxIsExecutableZ(path: [:0]const u8) bool {
    const rc = std.os.linux.access(path.ptr, std.os.linux.X_OK);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn libcIsExecutableZ(path: [:0]const u8) bool {
    const rc = std.c.access(path.ptr, std.c.X_OK);
    return std.c.errno(rc) == .SUCCESS;
}

fn linuxSpawnAndWait(request: host.SpawnRequest) SpawnError!host.WaitStatus {
    const linux = std.os.linux;
    const fork_rc = linux.fork();
    switch (linux.errno(fork_rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(fork_rc);
    if (pid == 0) {
        _ = linux.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        linux.exit(127);
    }

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

fn libcSpawnAndWait(request: host.SpawnRequest) SpawnError!host.WaitStatus {
    const fork_rc = std.c.fork();
    switch (std.c.errno(fork_rc)) {
        .SUCCESS => {},
        .AGAIN, .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    const pid: i32 = @intCast(fork_rc);
    if (pid == 0) {
        _ = std.c.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        std.c._exit(127);
    }

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
