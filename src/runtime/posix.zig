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
const runtime_signal = @import("signal.zig");

extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;
extern "c" fn tcsetpgrp(fd: std.c.fd_t, pgrp: std.c.pid_t) c_int;

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
            .is_tty_fn = isTty,
        };
    }

    pub fn fsPort(self: *Adapter) fs.Port {
        return .{
            .context = self,
            .get_cwd_fn = getCwd,
            .change_cwd_fn = changeCwd,
            .access_fn = access,
            .inspect_path_fn = inspectPath,
            .list_dir_fn = listDir,
            .set_file_creation_mask_fn = setFileCreationMask,
        };
    }

    pub fn processPort(self: *Adapter) process.Port {
        return .{
            .context = self,
            .spawn_fn = spawn,
            .start_subshell_fn = startSubshell,
            .wait_fn = wait,
            .poll_wait_fn = pollWait,
            .run_fn = run,
            .get_times_fn = getTimes,
            .get_resource_limit_fn = getResourceLimit,
            .set_resource_limit_fn = setResourceLimit,
            .continue_process_fn = continueProcess,
            .foreground_process_group_fn = foregroundProcessGroup,
        };
    }

    pub fn signalPort(self: *Adapter) runtime_signal.Port {
        return .{
            .context = self,
            .configure_fn = configureSignal,
            .poll_fn = pollSignal,
            .send_fn = sendSignal,
        };
    }
};

fn adapterFromContext(context: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(context));
}

fn open(context: *anyopaque, request: fd.OpenRequest) fd.OpenError!fd.OpenResult {
    _ = context;
    request.validate();
    const descriptor = try std.posix.openat(
        request.directory,
        request.path,
        request.options.toPosixFlags(),
        request.options.mode,
    );
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

fn isTty(context: *anyopaque, request: fd.IsTtyRequest) fd.IsTtyError!fd.IsTtyResult {
    _ = context;
    request.validate();
    return .{ .is_tty = try descriptorIsTty(request.descriptor) };
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

fn inspectPath(context: *anyopaque, request: fs.InspectPathRequest) fs.InspectPathError!fs.InspectPathResult {
    const adapter = adapterFromContext(context);
    request.validate();
    const stat = try std.Io.Dir.cwd().statFile(adapter.io, request.path, request.toStdOptions());
    return .{
        .stat = stat,
        .identity = pathIdentity(request.path, request.follow_symlinks),
    };
}

fn listDir(context: *anyopaque, request: fs.ListDirRequest) fs.ListDirError!fs.ListDirResult {
    const adapter = adapterFromContext(context);
    request.validate();

    var dir = try std.Io.Dir.cwd().openDir(adapter.io, request.path, .{ .iterate = true });
    defer dir.close(adapter.io);

    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |entry| request.allocator.free(entry);
        entries.deinit(request.allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(adapter.io)) |entry| {
        if (entry.name.len == 0) continue;
        const owned_name = try request.allocator.dupe(u8, entry.name);
        errdefer request.allocator.free(owned_name);
        try entries.append(request.allocator, owned_name);
    }

    return .{
        .allocator = request.allocator,
        .entries = try entries.toOwnedSlice(request.allocator),
    };
}

fn setFileCreationMask(
    context: *anyopaque,
    request: fs.SetFileCreationMaskRequest,
) fs.SetFileCreationMaskError!fs.SetFileCreationMaskResult {
    _ = context;
    request.validate();
    const previous = std.c.umask(@intCast(request.mask));
    return .{ .previous = @intCast(previous & 0o777) };
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

fn startSubshell(context: *anyopaque, request: process.StartSubshellRequest) process.SpawnError!process.SpawnResult {
    _ = adapterFromContext(context);
    request.validate();

    const pid = std.c.fork();
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    if (pid == 0) {
        configureForkedChild(request);
        const status = request.main_fn(request.context);
        std.c._exit(status);
    }

    const child: std.process.Child = .{
        .id = @intCast(pid),
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    return .{ .child = process.ChildProcess.init(child) };
}

fn wait(context: *anyopaque, request: process.WaitRequest) process.WaitError!process.WaitResult {
    const adapter = adapterFromContext(context);
    request.validate();
    const term = try request.child.child.wait(adapter.io);
    request.child.markWaited();
    return .{ .status = waitStatusFromTerm(term) };
}

fn pollWait(context: *anyopaque, request: process.PollWaitRequest) process.WaitError!process.PollWaitResult {
    const adapter = adapterFromContext(context);
    request.validate();

    var flags: c_int = 0;
    if (request.nohang) flags |= @intCast(std.posix.W.NOHANG);
    if (request.report_stopped) flags |= @intCast(std.posix.W.UNTRACED);

    const pid = request.child.id();
    var status: c_int = 0;
    while (true) {
        const result = waitPid(pid, &status, flags) catch |err| switch (err) {
            error.ChildNotFound => return error.Unexpected,
            error.Interrupted => return .{},
            error.Unexpected => return error.Unexpected,
        };
        if (result == 0) return .{};
        if (result != pid) return error.Unexpected;

        const wait_status = waitStatusFromRaw(@bitCast(status));
        switch (wait_status) {
            .stopped => {},
            .exited, .signaled, .unknown => cleanupWaitedChild(adapter.io, request.child),
        }
        return .{ .status = wait_status };
    }
}

fn getTimes(context: *anyopaque) process.TimesError!process.ProcessTimes {
    _ = adapterFromContext(context);
    const self = std.posix.getrusage(std.posix.rusage.SELF);
    const children = std.posix.getrusage(std.posix.rusage.CHILDREN);
    return .{
        .shell_user = cpuDurationFromTimeval(self.utime),
        .shell_system = cpuDurationFromTimeval(self.stime),
        .children_user = cpuDurationFromTimeval(children.utime),
        .children_system = cpuDurationFromTimeval(children.stime),
    };
}

fn cpuDurationFromTimeval(value: std.posix.timeval) process.CpuDuration {
    std.debug.assert(value.sec >= 0);
    std.debug.assert(value.usec >= 0);
    return .{ .microseconds = @as(u64, @intCast(value.sec)) * 1_000_000 + @as(u64, @intCast(value.usec)) };
}

fn getResourceLimit(
    context: *anyopaque,
    request: process.GetResourceLimitRequest,
) process.ResourceLimitError!process.GetResourceLimitResult {
    _ = adapterFromContext(context);
    request.validate();
    const limits = std.posix.getrlimit(resourceLimitResourceToPosix(request.resource)) catch |err| switch (err) {
        error.Unexpected => return error.Unexpected,
    };
    return .{ .limits = .{
        .soft = resourceLimitValueFromPosix(limits.cur),
        .hard = resourceLimitValueFromPosix(limits.max),
    } };
}

fn setResourceLimit(context: *anyopaque, request: process.SetResourceLimitRequest) process.ResourceLimitError!void {
    _ = adapterFromContext(context);
    request.validate();
    const limits: std.posix.rlimit = .{
        .cur = try resourceLimitValueToPosix(request.limits.soft),
        .max = try resourceLimitValueToPosix(request.limits.hard),
    };
    std.posix.setrlimit(resourceLimitResourceToPosix(request.resource), limits) catch |err| switch (err) {
        error.PermissionDenied => return error.PermissionDenied,
        error.LimitTooBig => return error.LimitTooBig,
        error.Unexpected => return error.Unexpected,
    };
}

fn resourceLimitResourceToPosix(resource: process.ResourceLimitResource) std.posix.rlimit_resource {
    return switch (resource) {
        .file_size => .FSIZE,
    };
}

fn resourceLimitValueFromPosix(value: std.posix.rlim_t) process.ResourceLimitValue {
    if (value == std.c.RLIM.INFINITY) return .unlimited;
    if (@typeInfo(std.posix.rlim_t).int.signedness == .signed) std.debug.assert(value >= 0);
    return .{ .bytes = @intCast(value) };
}

fn resourceLimitValueToPosix(value: process.ResourceLimitValue) process.ResourceLimitError!std.posix.rlim_t {
    return switch (value) {
        .unlimited => std.c.RLIM.INFINITY,
        .bytes => |bytes| blk: {
            if (bytes > std.math.maxInt(std.posix.rlim_t)) return error.LimitTooBig;
            break :blk @intCast(bytes);
        },
    };
}

const WaitPidError = error{
    Interrupted,
    ChildNotFound,
    Unexpected,
};

fn waitPid(pid: std.posix.pid_t, status: *c_int, flags: c_int) WaitPidError!std.posix.pid_t {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const linux_flags: u32 = @bitCast(flags);
        var linux_status: u32 = 0;
        const rc = std.os.linux.waitpid(pid, &linux_status, linux_flags);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                status.* = @bitCast(linux_status);
                return @intCast(rc);
            },
            .INTR => return error.Interrupted,
            .CHILD => return error.ChildNotFound,
            else => return error.Unexpected,
        }
    }

    const rc = std.c.waitpid(pid, status, flags);
    switch (std.c.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return error.Interrupted,
        .CHILD => return error.ChildNotFound,
        else => return error.Unexpected,
    }
}

fn continueProcess(context: *anyopaque, request: process.ContinueProcessRequest) process.JobControlError!void {
    _ = adapterFromContext(context);
    request.validate();
    const pid: std.posix.pid_t = switch (request.target) {
        .process => |process_id| process_id,
        .process_group => |process_group| -process_group,
    };
    std.posix.kill(pid, .CONT) catch |err| switch (err) {
        error.ProcessNotFound => return error.ProcessNotFound,
        error.PermissionDenied => return error.PermissionDenied,
        error.Unexpected => return error.Unexpected,
    };
}

fn foregroundProcessGroup(
    context: *anyopaque,
    request: process.ForegroundProcessGroupRequest,
) process.JobControlError!process.ForegroundProcessGroupResult {
    _ = adapterFromContext(context);
    request.validate();
    const previous = try terminalGetProcessGroup(request.terminal);
    try terminalSetProcessGroup(request.terminal, request.process_group);
    return .{ .previous_process_group = previous };
}

fn configureSignal(context: *anyopaque, request: runtime_signal.ConfigureRequest) runtime_signal.ConfigureError!void {
    _ = adapterFromContext(context);
    request.validate();
    const posix_signal = posixSignalFromRuntimeNumber(request.signal) orelse return error.Unsupported;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = switch (request.disposition) {
            .default => std.posix.SIG.DFL,
            .ignore => std.posix.SIG.IGN,
            .caught => runtimeSignalHandler,
        } },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(posix_signal, &action, null);
}

fn pollSignal(context: *anyopaque) runtime_signal.PollError!?runtime_signal.Event {
    _ = adapterFromContext(context);
    return runtime_signal.pollCaughtSignal();
}

fn sendSignal(context: *anyopaque, request: runtime_signal.SendRequest) runtime_signal.SendError!void {
    _ = adapterFromContext(context);
    request.validate();
    std.posix.kill(@intCast(request.process), @enumFromInt(request.signal)) catch |err| switch (err) {
        error.ProcessNotFound => return error.ProcessNotFound,
        error.PermissionDenied => return error.PermissionDenied,
        error.Unexpected => return error.Unexpected,
    };
}

fn runtimeSignalHandler(posix_signal: std.posix.SIG) callconv(.c) void {
    runtime_signal.recordCaughtSignal(@intCast(@intFromEnum(posix_signal)));
}

fn posixSignalFromRuntimeNumber(number: runtime_signal.Number) ?std.posix.SIG {
    runtime_signal.assertValidNumber(number);
    inline for (supported_runtime_signals) |posix_signal| {
        if (number == @as(runtime_signal.Number, @intCast(@intFromEnum(posix_signal)))) return posix_signal;
    }
    return null;
}

const supported_runtime_signals = [_]std.posix.SIG{ .HUP, .INT, .QUIT, .TERM, .USR1, .USR2 };

fn terminalGetProcessGroup(terminal: fd.Descriptor) process.JobControlError!std.posix.pid_t {
    fd.assertValidDescriptor(terminal);
    const rc = tcgetpgrp(terminal);
    switch (std.c.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return terminalGetProcessGroup(terminal),
        .NOTTY => return error.OperationUnsupported,
        else => return error.Unexpected,
    }
}

fn terminalSetProcessGroup(terminal: fd.Descriptor, process_group: std.posix.pid_t) process.JobControlError!void {
    fd.assertValidDescriptor(terminal);
    std.debug.assert(process_group > 0);
    const rc = tcsetpgrp(terminal, process_group);
    switch (std.c.errno(rc)) {
        .SUCCESS => return,
        .INTR => return terminalSetProcessGroup(terminal, process_group),
        .NOTTY => return error.OperationUnsupported,
        .PERM => return error.PermissionDenied,
        else => return error.Unexpected,
    }
}

const StdinWriter = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    err: ?anyerror = null,

    fn run(self: *StdinWriter) void {
        defer self.file.close(self.io);
        if (self.bytes.len == 0) return;

        var buffer: [4096]u8 = undefined;
        var writer = self.file.writerStreaming(self.io, &buffer);
        writer.interface.writeAll(self.bytes) catch |err| {
            self.err = writer.err orelse err;
            return;
        };
        writer.interface.flush() catch |err| {
            self.err = writer.err orelse err;
            return;
        };
    }
};

fn run(context: *anyopaque, request: process.RunRequest) process.RunError!process.RunResult {
    const adapter = adapterFromContext(context);
    request.validate();

    var reserved_stdio = try ReservedStandardDescriptors.init();
    defer reserved_stdio.deinit();

    var child = try std.process.spawn(adapter.io, .{
        .argv = request.argv,
        .cwd = request.cwd.toStdCwd(),
        .environ_map = request.environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    std.debug.assert(child.stdin != null);
    std.debug.assert(child.stdout != null);
    std.debug.assert(child.stderr != null);

    var stdin_writer: StdinWriter = .{
        .io = adapter.io,
        .file = child.stdin.?,
        .bytes = request.stdin,
    };
    child.stdin = null;
    var stdin_thread = std.Thread.spawn(.{}, StdinWriter.run, .{&stdin_writer}) catch |err| {
        child.kill(adapter.io);
        return err;
    };
    var stdin_joined = false;
    defer {
        child.kill(adapter.io);
        if (!stdin_joined) stdin_thread.join();
    }

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        request.allocator,
        adapter.io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    while (multi_reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |read_err| return read_err,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(adapter.io);
    stdin_thread.join();
    stdin_joined = true;
    if (stdin_writer.err) |err| return err;

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer request.allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer request.allocator.free(stderr_slice);

    return .{
        .allocator = request.allocator,
        .status = waitStatusFromTerm(term),
        .stdout = stdout_slice,
        .stderr = stderr_slice,
    };
}

const ReservedStandardDescriptors = struct {
    descriptors: [3]?fd.Descriptor = .{ null, null, null },

    fn init() !ReservedStandardDescriptors {
        var reserved: ReservedStandardDescriptors = .{};
        errdefer reserved.deinit();

        for (&reserved.descriptors, 0..) |*slot, index| {
            const descriptor: fd.Descriptor = @intCast(index);
            if (try descriptorIsOpen(descriptor)) continue;

            const opened = try openNullDescriptor();
            if (opened == descriptor) {
                slot.* = opened;
                continue;
            }

            // ziglint-ignore: Z026 best-effort close of a temporary /dev/null descriptor
            closeDescriptor(opened) catch {};
            if (!(try descriptorIsOpen(descriptor))) return error.Unexpected;
        }

        return reserved;
    }

    fn deinit(self: *ReservedStandardDescriptors) void {
        for (&self.descriptors) |*slot| {
            const descriptor = slot.* orelse continue;
            // ziglint-ignore: Z026 best-effort close during cleanup
            closeDescriptor(descriptor) catch {};
            slot.* = null;
        }
        self.* = undefined;
    }
};

fn descriptorIsOpen(descriptor: fd.Descriptor) !bool {
    fd.assertValidDescriptor(descriptor);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        while (true) {
            const rc = std.os.linux.fcntl(descriptor, std.os.linux.F.GETFD, 0);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return true,
                .BADF => return false,
                .INTR => continue,
                else => return error.Unexpected,
            }
        }
    }
    while (true) {
        const rc = std.c.fcntl(descriptor, @as(c_int, std.c.F.GETFD), @as(c_int, 0));
        switch (std.c.errno(rc)) {
            .SUCCESS => return true,
            .BADF => return false,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn openNullDescriptor() !fd.Descriptor {
    var flags: std.posix.O = .{ .ACCMODE = .RDWR };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    return std.posix.openat(fd.current_working_directory, "/dev/null", flags, 0) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        else => error.Unexpected,
    };
}

fn waitStatusFromTerm(term: std.process.Child.Term) process.WaitStatus {
    return switch (term) {
        .exited => |status| .{ .exited = status },
        .signal => |signal| .{ .signaled = @intCast(@intFromEnum(signal)) },
        .stopped => |signal| .{ .stopped = @intCast(@intFromEnum(signal)) },
        .unknown => |status| .{ .unknown = status },
    };
}

fn waitStatusFromRaw(status: u32) process.WaitStatus {
    if (std.posix.W.IFEXITED(status)) return .{ .exited = @intCast(std.posix.W.EXITSTATUS(status)) };
    if (std.posix.W.IFSIGNALED(status)) return .{ .signaled = @intCast(@intFromEnum(std.posix.W.TERMSIG(status))) };
    if (std.posix.W.IFSTOPPED(status)) return .{ .stopped = @intCast(@intFromEnum(std.posix.W.STOPSIG(status))) };
    return .{ .unknown = status };
}

fn cleanupWaitedChild(io: std.Io, child: *process.ChildProcess) void {
    if (child.child.stdin) |file| {
        var owned = file;
        owned.close(io);
        child.child.stdin = null;
    }
    if (child.child.stdout) |file| {
        var owned = file;
        owned.close(io);
        child.child.stdout = null;
    }
    if (child.child.stderr) |file| {
        var owned = file;
        owned.close(io);
        child.child.stderr = null;
    }
    child.child.id = null;
    child.markWaited();
}

fn configureForkedChild(request: process.StartSubshellRequest) void {
    request.validate();
    if (request.process_group) |requested_group| {
        const group = if (requested_group == 0) std.c.getpid() else requested_group;
        if (std.c.setpgid(0, group) != 0) std.c._exit(126);
    }
    configureForkedStdio(request.stdin, 0);
    configureForkedStdio(request.stdout, 1);
    configureForkedStdio(request.stderr, 2);
}

fn configureForkedStdio(stdio: process.StandardIo, target: fd.Descriptor) void {
    stdio.validate();
    fd.assertValidDescriptor(target);
    switch (stdio) {
        .inherit => {},
        .fd => |source| {
            if (source != target) duplicateDescriptorTo(source, target) catch std.c._exit(126);
        },
        .close => closeDescriptor(target) catch std.c._exit(126),
        .ignore, .pipe => std.c._exit(126),
    }
}

fn pathIdentity(path: []const u8, follow_symlinks: bool) ?fs.PathIdentity {
    std.debug.assert(path.len != 0);
    const path_z = std.posix.toPosixPath(path) catch return null;

    if (comptime builtin.os.tag == .linux) {
        var statx_result: std.os.linux.Statx = undefined;
        const flags: u32 = if (follow_symlinks) 0 else std.c.AT.SYMLINK_NOFOLLOW;
        if (std.c.statx(
            std.c.AT.FDCWD,
            &path_z,
            flags,
            std.os.linux.STATX.BASIC_STATS,
            &statx_result,
        ) != 0) return null;
        return .{
            .device = (@as(u64, statx_result.dev_major) << 32) | statx_result.dev_minor,
            .inode = statx_result.ino,
        };
    }

    var stat_result: std.c.Stat = undefined;
    const flags: u32 = if (follow_symlinks) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    if (std.c.fstatat(std.c.AT.FDCWD, &path_z, &stat_result, flags) != 0) return null;
    return .{
        .device = @intCast(stat_result.dev),
        .inode = @intCast(stat_result.ino),
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

fn descriptorIsTty(descriptor: fd.Descriptor) fd.IsTtyError!bool {
    fd.assertValidDescriptor(descriptor);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        while (true) {
            var window_size: std.posix.winsize = undefined;
            const descriptor_arg: usize = @bitCast(@as(isize, descriptor));
            const rc = std.os.linux.syscall3(
                .ioctl,
                descriptor_arg,
                std.os.linux.T.IOCGWINSZ,
                @intFromPtr(&window_size),
            );
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return true,
                .INTR => continue,
                .BADF, .NOTTY, .INVAL => return false,
                else => return error.Unexpected,
            }
        }
    }
    while (true) {
        const rc = std.c.isatty(descriptor);
        switch (std.c.errno(rc - 1)) {
            .SUCCESS => return true,
            .INTR => continue,
            .BADF, .NOTTY, .INVAL => return false,
            else => return error.Unexpected,
        }
    }
}

test "runtime posix adapter performs fd open duplicate close and pipe smoke operations" {
    var adapter = Adapter.init(std.testing.io);
    const fd_port = adapter.fdPort();

    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "rush-runtime-fd-{d}.tmp", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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

    const opened_tty = try fd_port.isTty(.{ .descriptor = opened.descriptor });
    try std.testing.expect(!opened_tty.is_tty);

    const duplicate_fd = try fd_port.duplicate(.{ .descriptor = opened.descriptor, .close_on_exec = true });
    try fd_port.close(.{ .descriptor = duplicate_fd.descriptor });
    try fd_port.close(.{ .descriptor = opened.descriptor });

    const pipe_result = try fd_port.pipe(.{ .close_on_exec = true });
    try fd_port.close(.{ .descriptor = pipe_result.read });
    try fd_port.close(.{ .descriptor = pipe_result.write });
}

test "runtime posix adapter exposes signal configure and poll port" {
    runtime_signal.resetProcessSignalStateForTesting();
    defer runtime_signal.resetProcessSignalStateForTesting();

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, &action, &previous);
    defer std.posix.sigaction(.TERM, &previous, null);

    var adapter = Adapter.init(std.testing.io);
    const signal_port = adapter.signalPort();
    const term_number: runtime_signal.Number = @intCast(@intFromEnum(std.posix.SIG.TERM));
    try signal_port.configure(.{ .signal = term_number, .disposition = .caught });

    runtimeSignalHandler(.TERM);

    const event = (try signal_port.poll()).?;
    try std.testing.expectEqual(term_number, event.signal);
    try std.testing.expectEqual(@as(?runtime_signal.Event, null), try signal_port.poll());
}

test "runtime posix adapter performs cwd and access smoke operations" {
    var adapter = Adapter.init(std.testing.io);
    const fs_port = adapter.fsPort();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try fs_port.getCwd(.{ .buffer = &buffer });
    try std.testing.expect(cwd.path.len != 0);

    try fs_port.access(.{ .path = "." });
    const metadata = try fs_port.inspectPath(.{ .path = "." });
    try std.testing.expectEqual(std.Io.File.Kind.directory, metadata.stat.kind);
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
    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(process.WaitStatus{ .exited = 7 }, result.status);
}

fn testSubshellMain(context: *anyopaque) u8 {
    const value: *const u8 = @ptrCast(@alignCast(context));
    return value.*;
}

test "runtime posix adapter starts and waits for a forked subshell callback" {
    var adapter = Adapter.init(std.testing.io);
    const process_port = adapter.processPort();
    const status: u8 = 6;

    var child = (try process_port.startSubshell(.{
        .context = @ptrCast(@constCast(&status)),
        .main_fn = testSubshellMain,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    })).child;
    const result = try process_port.wait(.{ .child = &child });
    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(process.WaitStatus{ .exited = 6 }, result.status);
}

test "runtime posix adapter runs a process with byte stdin and captured output" {
    var adapter = Adapter.init(std.testing.io);
    const process_port = adapter.processPort();

    const argv = [_][]const u8{"/bin/cat"};
    var result = try process_port.run(.{
        .allocator = std.testing.allocator,
        .argv = &argv,
        .stdin = "captured stdin",
    });
    defer result.deinit();

    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(process.WaitStatus{ .exited = 0 }, result.status);
    try std.testing.expectEqualStrings("captured stdin", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runtime posix adapter runs stdin writer concurrently with stdout and stderr capture" {
    var adapter = Adapter.init(std.testing.io);
    const process_port = adapter.processPort();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    try input.appendNTimes(std.testing.allocator, 'i', 256 * 1024);

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        \\dd if=/dev/zero bs=1024 count=128 2>/dev/null
        \\dd if=/dev/zero bs=1024 count=128 1>&2 2>/dev/null
        \\wc -c >/dev/null
        ,
    };
    var result = try process_port.run(.{
        .allocator = std.testing.allocator,
        .argv = &argv,
        .stdin = input.items,
    });
    defer result.deinit();

    // ziglint-ignore: Z010 - anon `.{}` does not peer-resolve to the union in expectEqual
    try std.testing.expectEqual(process.WaitStatus{ .exited = 0 }, result.status);
    try std.testing.expectEqual(@as(usize, 128 * 1024), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 128 * 1024), result.stderr.len);
    for (result.stdout) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (result.stderr) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
