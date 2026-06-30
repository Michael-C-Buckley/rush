//! Platform syscall shims used by `RealHost`.

const std = @import("std");
const builtin = @import("builtin");

const host = @import("../host.zig");

extern "c" fn readdir(dir: *std.c.DIR) ?*std.c.dirent;

pub const ReadError = host.ReadError;

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

pub const ListDirError = host.ListDirError || std.mem.Allocator.Error;

pub const ChangeDirError = host.ChangeDirError;

pub const CurrentDirError = host.CurrentDirError || std.mem.Allocator.Error;

pub const CloseError = host.CloseError;

pub const DuplicateError = host.DuplicateError;

pub const PipeError = host.PipeError;

pub const ForkError = host.ForkError;

pub const SpawnError = error{
    SystemResources,
    Unexpected,
};

pub const WaitError = error{
    Unexpected,
};

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

pub fn duplicateTo(from: host.Fd, to: host.Fd) DuplicateError!void {
    return switch (builtin.os.tag) {
        .linux => linuxDuplicateTo(from, to),
        .macos, .freebsd, .openbsd, .netbsd => libcDuplicateTo(from, to),
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
    try setCloseOnExec(@enumFromInt(fds[0]));
    try setCloseOnExec(@enumFromInt(fds[1]));
    return .{ .read = @enumFromInt(fds[0]), .write = @enumFromInt(fds[1]) };
}

fn setCloseOnExec(fd: host.Fd) PipeError!void {
    const rc = std.c.fcntl(@intCast(fd.raw()), std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
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

fn libcIsExecutableZ(path: [:0]const u8) bool {
    const rc = std.c.access(path.ptr, std.c.X_OK);
    return std.c.errno(rc) == .SUCCESS;
}

fn libcExistsZ(path: [:0]const u8) bool {
    const rc = std.c.access(path.ptr, std.c.F_OK);
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
        return allocator.dupe(u8, std.mem.span(cwd));
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
        _ = linux.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        linux.exit(127);
    }

    return .{ .pid = pid };
}

fn linuxExec(request: host.SpawnRequest) SpawnError!void {
    const linux = std.os.linux;
    applyLinuxFdActions(request.fd_actions);
    _ = linux.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
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
        _ = std.c.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
        std.c._exit(127);
    }

    return .{ .pid = pid };
}

fn libcExec(request: host.SpawnRequest) SpawnError!void {
    applyLibcFdActions(request.fd_actions);
    _ = std.c.execve(request.path.ptr, request.argv.ptr, request.envp.ptr);
    return error.Unexpected;
}

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
