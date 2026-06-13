//! POSIX adapter surface for runtime ports.
//!
//! This is the layer that will translate runtime port requests into platform
//! syscalls and POSIX process behavior. It exposes only low-level operations;
//! shell planning and policy stay in `src/shell/*`.

const std = @import("std");
const builtin = @import("builtin");

const fd = @import("fd.zig");
const fs = @import("fs.zig");
const process = @import("process.zig");

pub const Adapter = struct {
    io: std.Io,

    pub fn init(io: std.Io) Adapter {
        return .{ .io = io };
    }

    pub fn fdPort(self: *Adapter) fd.Port {
        return .{
            .context = self,
            .open_fn = open,
            .close_fn = close,
            .duplicate_fn = duplicate,
            .duplicate_to_fn = duplicateTo,
            .pipe_fn = pipe,
        };
    }

    pub fn fsPort(self: *Adapter) fs.Port {
        return .{
            .context = self,
            .get_cwd_fn = getCwd,
            .change_cwd_fn = changeCwd,
            .access_fn = access,
        };
    }

    pub fn processPort(self: *Adapter) process.Port {
        return .{
            .context = self,
            .spawn_fn = spawn,
            .wait_fn = wait,
        };
    }
};

fn adapterFromContext(context: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(context));
}

fn open(context: *anyopaque, request: fd.OpenRequest) fd.OpenError!fd.OpenResult {
    _ = context;
    request.validate();
    const descriptor = try std.posix.openat(request.directory, request.path, request.options.toPosixFlags(), request.options.mode);
    return .{ .descriptor = descriptor };
}

fn close(context: *anyopaque, request: fd.CloseRequest) fd.CloseError!void {
    _ = context;
    request.validate();
    return closeDescriptor(request.descriptor);
}

fn duplicate(context: *anyopaque, request: fd.DuplicateRequest) fd.DuplicateError!fd.DuplicateResult {
    _ = context;
    request.validate();
    const descriptor = try duplicateDescriptor(request.descriptor);
    errdefer closeDescriptor(descriptor) catch {};
    if (request.close_on_exec) try setCloseOnExec(descriptor);
    return .{ .descriptor = descriptor };
}

fn duplicateTo(context: *anyopaque, request: fd.DuplicateToRequest) fd.DuplicateError!void {
    _ = context;
    request.validate();
    try duplicateDescriptorTo(request.source, request.target);
    if (request.close_on_exec) try setCloseOnExec(request.target);
}

fn pipe(context: *anyopaque, request: fd.PipeRequest) fd.PipeError!fd.PipeResult {
    _ = context;
    request.validate();

    const descriptors = switch (builtin.os.tag) {
        .linux => blk: {
            var descriptors: [2]i32 = undefined;
            const flags: std.os.linux.O = if (request.close_on_exec) .{ .CLOEXEC = true } else .{};
            const rc = std.os.linux.pipe2(&descriptors, flags);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            break :blk .{ descriptors[0], descriptors[1] };
        },
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => blk: {
            var descriptors: [2]std.c.fd_t = undefined;
            const rc = std.c.pipe(&descriptors);
            switch (std.c.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            errdefer {
                closeDescriptor(descriptors[0]) catch {};
                closeDescriptor(descriptors[1]) catch {};
            }
            if (request.close_on_exec) {
                setCloseOnExec(descriptors[0]) catch |err| return pipeCloseOnExecError(err);
                setCloseOnExec(descriptors[1]) catch |err| return pipeCloseOnExecError(err);
            }
            break :blk .{ descriptors[0], descriptors[1] };
        },
        else => return error.Unsupported,
    };

    return .{ .read = descriptors[0], .write = descriptors[1] };
}

fn getCwd(context: *anyopaque, request: fs.GetCwdRequest) fs.GetCwdError!fs.GetCwdResult {
    const adapter = adapterFromContext(context);
    request.validate();
    const len = try std.process.currentPath(adapter.io, request.buffer);
    return .{ .path = request.buffer[0..len] };
}

fn changeCwd(context: *anyopaque, request: fs.ChangeCwdRequest) fs.ChangeCwdError!void {
    const adapter = adapterFromContext(context);
    request.validate();
    try std.process.setCurrentPath(adapter.io, request.path);
}

fn access(context: *anyopaque, request: fs.AccessRequest) fs.AccessError!void {
    const adapter = adapterFromContext(context);
    request.validate();
    try std.Io.Dir.cwd().access(adapter.io, request.path, request.toStdOptions());
}

fn spawn(context: *anyopaque, request: process.SpawnRequest) process.SpawnError!process.SpawnResult {
    const adapter = adapterFromContext(context);
    request.validate();
    const child = try std.process.spawn(adapter.io, .{
        .argv = request.argv,
        .cwd = request.cwd.toStdCwd(),
        .environ_map = request.environment,
        .stdin = request.stdin.toStdIo(),
        .stdout = request.stdout.toStdIo(),
        .stderr = request.stderr.toStdIo(),
        .pgid = request.process_group,
    });
    return .{ .child = process.ChildProcess.init(child) };
}

fn wait(context: *anyopaque, request: process.WaitRequest) process.WaitError!process.WaitResult {
    const adapter = adapterFromContext(context);
    request.validate();
    const term = try request.child.child.wait(adapter.io);
    request.child.markWaited();
    return .{ .status = waitStatusFromTerm(term) };
}

fn waitStatusFromTerm(term: std.process.Child.Term) process.WaitStatus {
    return switch (term) {
        .exited => |status| .{ .exited = status },
        .signal => |signal| .{ .signaled = @intCast(@intFromEnum(signal)) },
        .stopped => |signal| .{ .stopped = @intCast(@intFromEnum(signal)) },
        .unknown => |status| .{ .unknown = status },
    };
}

fn pipeCloseOnExecError(err: fd.DuplicateError) fd.PipeError {
    return switch (err) {
        error.BadFileDescriptor => error.Unexpected,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.Unexpected => error.Unexpected,
    };
}

fn closeDescriptor(descriptor: fd.Descriptor) fd.CloseError!void {
    fd.assertValidDescriptor(descriptor);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        while (true) {
            const rc = std.os.linux.close(descriptor);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return,
                .BADF => return error.BadFileDescriptor,
                .INTR => continue,
                else => return error.Unexpected,
            }
        }
    }
    while (true) {
        const rc = std.c.close(descriptor);
        switch (std.c.errno(rc)) {
            .SUCCESS => return,
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn duplicateDescriptor(descriptor: fd.Descriptor) fd.DuplicateError!fd.Descriptor {
    fd.assertValidDescriptor(descriptor);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        while (true) {
            const rc = std.os.linux.dup(descriptor);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .BADF => return error.BadFileDescriptor,
                .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => return error.Unexpected,
            }
        }
    }
    while (true) {
        const rc = std.c.dup(descriptor);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn duplicateDescriptorTo(source: fd.Descriptor, target: fd.Descriptor) fd.DuplicateError!void {
    fd.assertValidDescriptor(source);
    fd.assertValidDescriptor(target);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        while (true) {
            const rc = std.os.linux.dup2(source, target);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return,
                .BADF => return error.BadFileDescriptor,
                .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => return error.Unexpected,
            }
        }
    }
    while (true) {
        const rc = std.c.dup2(source, target);
        switch (std.c.errno(rc)) {
            .SUCCESS => return,
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn setCloseOnExec(descriptor: fd.Descriptor) fd.DuplicateError!void {
    fd.assertValidDescriptor(descriptor);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        while (true) {
            const rc = std.os.linux.fcntl(descriptor, std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return,
                .BADF => return error.BadFileDescriptor,
                .INTR => continue,
                else => return error.Unexpected,
            }
        }
    }
    while (true) {
        const rc = std.c.fcntl(descriptor, @as(c_int, std.c.F.SETFD), @as(c_int, std.c.FD_CLOEXEC));
        switch (std.c.errno(rc)) {
            .SUCCESS => return,
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

test "runtime posix adapter performs fd open duplicate close and pipe smoke operations" {
    var adapter = Adapter.init(std.testing.io);
    const fd_port = adapter.fdPort();

    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "rush-runtime-fd-{d}.tmp", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const opened = try fd_port.open(.{
        .path = path,
        .options = .{
            .access = .read_write,
            .create = true,
            .truncate = true,
            .close_on_exec = true,
        },
    });
    errdefer fd_port.close(.{ .descriptor = opened.descriptor }) catch {};

    const duplicate_fd = try fd_port.duplicate(.{ .descriptor = opened.descriptor, .close_on_exec = true });
    try fd_port.close(.{ .descriptor = duplicate_fd.descriptor });
    try fd_port.close(.{ .descriptor = opened.descriptor });

    const pipe_result = try fd_port.pipe(.{ .close_on_exec = true });
    try fd_port.close(.{ .descriptor = pipe_result.read });
    try fd_port.close(.{ .descriptor = pipe_result.write });
}

test "runtime posix adapter performs cwd and access smoke operations" {
    var adapter = Adapter.init(std.testing.io);
    const fs_port = adapter.fsPort();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try fs_port.getCwd(.{ .buffer = &buffer });
    try std.testing.expect(cwd.path.len != 0);

    try fs_port.access(.{ .path = "." });
    try fs_port.changeCwd(.{ .path = cwd.path });
}

test "runtime posix adapter spawns and waits for a simple process" {
    var adapter = Adapter.init(std.testing.io);
    const process_port = adapter.processPort();

    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 7" };
    var child = (try process_port.spawn(.{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    })).child;
    const result = try process_port.wait(.{ .child = &child });
    try std.testing.expectEqual(process.WaitStatus{ .exited = 7 }, result.status);
}
