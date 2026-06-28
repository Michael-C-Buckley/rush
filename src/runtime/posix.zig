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
extern "c" fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
extern "c" fn getattrlistbulk(
    dirfd: std.c.fd_t,
    attr_list: *MacosAttrList,
    attr_buf: *anyopaque,
    attr_buf_size: usize,
    options: u64,
) c_int;

const MacosAttrList = extern struct {
    bitmapcount: u16,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

const MacosAttributeSet = extern struct {
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
};

const macos_attr_bit_map_count = 5;
const macos_attr_cmn_name = 0x00000001;
const macos_attr_cmn_objtype = 0x00000008;
const macos_attr_cmn_useraccess = 0x00200000;
const macos_attr_cmn_returned_attrs = 0x80000000;
const macos_attr_file_datalength = 0x00000200;
const macos_vreg = 1;
const macos_vdir = 2;
const macos_vlnk = 5;
const macos_bulk_buffer_len = 1024 * 1024;
const posix_x_ok = 1;
const linux_statx_size_mask: std.os.linux.STATX = .{ .SIZE = true };

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
            .write_fn = writeAll,
            .is_tty_fn = isTty,
            .descriptor_status_fn = descriptorStatus,
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
    const adapter = adapterFromContext(context);
    request.validate();
    const descriptor = openDescriptor(request) catch |err| switch (err) {
        error.PathAlreadyExists => try openExistingNonRegularNoclobberTarget(adapter.io, request),
        else => |open_err| return open_err,
    };
    return .{ .descriptor = descriptor };
}

fn openDescriptor(request: fd.OpenRequest) fd.OpenError!fd.Descriptor {
    request.validate();
    const path_z = try std.posix.toPosixPath(request.path);
    while (true) {
        const rc = std.c.openat(
            request.directory,
            &path_z,
            request.options.toPosixFlags(),
            request.options.mode,
        );
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,

            .FAULT => unreachable,
            .INVAL => return error.BadPathName,
            .BADF => unreachable,
            .ACCES, .ROFS => return error.AccessDenied,
            .FBIG, .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV, .NXIO => return error.NoDevice,
            .NOENT, .SRCH => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .OPNOTSUPP => return error.FileLocksUnsupported,
            .AGAIN => return error.WouldBlock,
            .TXTBSY => return error.FileBusy,
            .ILSEQ => return error.BadPathName,
            else => return error.Unexpected,
        }
    }
}

fn openExistingNonRegularNoclobberTarget(io: std.Io, request: fd.OpenRequest) fd.OpenError!fd.Descriptor {
    request.validate();
    if (!request.options.exclusive or !request.options.create) return error.PathAlreadyExists;

    var options = request.options;
    options.exclusive = false;
    options.truncate = false;
    const descriptor = try std.posix.openat(
        request.directory,
        request.path,
        options.toPosixFlags(),
        options.mode,
    );
    errdefer closeDescriptor(descriptor) catch {};

    const file: std.Io.File = .{ .handle = descriptor, .flags = .{ .nonblocking = false } };
    const file_stat = file.stat(io) catch return error.Unexpected;
    if (file_stat.kind == .file) return error.PathAlreadyExists;
    return descriptor;
}

fn close(context: *anyopaque, request: fd.CloseRequest) fd.CloseError!void {
    _ = context;
    request.validate();
    return closeDescriptor(request.descriptor);
}

fn duplicate(context: *anyopaque, request: fd.DuplicateRequest) fd.DuplicateError!fd.DuplicateResult {
    _ = context;
    request.validate();
    const descriptor = if (request.minimum_descriptor == 0)
        try duplicateDescriptor(request.descriptor)
    else
        try duplicateDescriptorAtLeast(request.descriptor, request.minimum_descriptor, request.close_on_exec);
    errdefer closeDescriptor(descriptor) catch {};
    if (request.close_on_exec and request.minimum_descriptor == 0) try setCloseOnExec(descriptor);
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

fn writeAll(context: *anyopaque, request: fd.WriteRequest) fd.WriteError!void {
    _ = context;
    request.validate();
    var index: usize = 0;
    while (index < request.bytes.len) {
        const written = std.c.write(request.descriptor, request.bytes[index..].ptr, request.bytes.len - index);
        if (written < 0) {
            return switch (std.posix.errno(written)) {
                .BADF => error.BadFileDescriptor,
                .PIPE => error.BrokenPipe,
                else => error.Unexpected,
            };
        }
        if (written == 0) return error.Unexpected;
        index += @intCast(written);
    }
}

fn isTty(context: *anyopaque, request: fd.IsTtyRequest) fd.IsTtyError!fd.IsTtyResult {
    _ = context;
    request.validate();
    return .{ .is_tty = try descriptorIsTty(request.descriptor) };
}

fn descriptorStatus(context: *anyopaque, request: fd.DescriptorStatusRequest) fd.DescriptorStatusError!fd.DescriptorStatusResult {
    _ = context;
    request.validate();
    return .{ .is_open = try descriptorIsOpen(request.descriptor) };
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

    if (request.attributes.needsStatLikeMetadata()) return listDirWithStatLikeMetadata(adapter, request);

    return listDirByIterator(adapter, request);
}

fn listDirWithStatLikeMetadata(adapter: *Adapter, request: fs.ListDirRequest) fs.ListDirError!fs.ListDirResult {
    request.validate();

    if (comptime builtin.os.tag == .macos) {
        return listDirMacosBulk(adapter, request) catch |err| switch (err) {
            error.BulkUnsupported => listDirByIterator(adapter, request),
            else => |list_err| list_err,
        };
    }

    return listDirByIterator(adapter, request);
}

fn listDirByIterator(adapter: *Adapter, request: fs.ListDirRequest) fs.ListDirError!fs.ListDirResult {
    request.validate();

    var dir = try std.Io.Dir.cwd().openDir(adapter.io, request.path, .{ .iterate = true });
    defer dir.close(adapter.io);

    var entries: std.ArrayList(fs.ListDirEntry) = .empty;
    errdefer {
        for (entries.items) |entry| request.allocator.free(entry.name);
        entries.deinit(request.allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(adapter.io)) |entry| {
        if (entry.name.len == 0) continue;
        const owned_name = try request.allocator.dupe(u8, entry.name);
        errdefer request.allocator.free(owned_name);
        var list_entry: fs.ListDirEntry = .{
            .name = owned_name,
            .kind = fs.EntryKind.fromStd(entry.kind),
        };
        try fillListDirMetadata(adapter.io, dir, &list_entry, request.attributes);
        try entries.append(request.allocator, list_entry);
    }

    return .{
        .allocator = request.allocator,
        .entries = try entries.toOwnedSlice(request.allocator),
    };
}

const ListDirMacosBulkError = fs.ListDirError || error{BulkUnsupported};

fn listDirMacosBulk(adapter: *Adapter, request: fs.ListDirRequest) ListDirMacosBulkError!fs.ListDirResult {
    request.validate();

    var dir = try std.Io.Dir.cwd().openDir(adapter.io, request.path, .{ .iterate = true });
    defer dir.close(adapter.io);

    const buffer = try request.allocator.alloc(u8, macos_bulk_buffer_len);
    defer request.allocator.free(buffer);

    var entries: std.ArrayList(fs.ListDirEntry) = .empty;
    errdefer {
        for (entries.items) |entry| request.allocator.free(entry.name);
        entries.deinit(request.allocator);
    }

    var attr_list: MacosAttrList = .{
        .bitmapcount = macos_attr_bit_map_count,
        .commonattr = macos_attr_cmn_returned_attrs | macos_attr_cmn_name,
    };
    if (request.attributes.kind or request.attributes.executable) attr_list.commonattr |= macos_attr_cmn_objtype;
    if (request.attributes.executable) attr_list.commonattr |= macos_attr_cmn_useraccess;
    if (request.attributes.size) attr_list.fileattr |= macos_attr_file_datalength;

    while (true) {
        const count = getattrlistbulk(dir.handle, &attr_list, buffer.ptr, buffer.len, 0);
        if (count < 0) return macosBulkErrnoToListDirError();
        if (count == 0) break;

        var offset: usize = 0;
        var entry_index: usize = 0;
        while (entry_index < @as(usize, @intCast(count))) : (entry_index += 1) {
            const parsed = try parseMacosBulkEntry(buffer, offset, request.attributes);
            offset += parsed.record_len;
            if (parsed.name.len == 0) continue;
            if (std.mem.eql(u8, parsed.name, ".") or std.mem.eql(u8, parsed.name, "..")) continue;

            const executable = if (request.attributes.executable and parsed.is_symlink)
                try executableAccess(adapter.io, dir, parsed.name)
            else
                parsed.executable;
            const owned_name = try request.allocator.dupe(u8, parsed.name);
            errdefer request.allocator.free(owned_name);
            try entries.append(request.allocator, .{
                .name = owned_name,
                .kind = parsed.kind,
                .size = parsed.size,
                .executable = executable,
            });
        }
    }

    return .{
        .allocator = request.allocator,
        .entries = try entries.toOwnedSlice(request.allocator),
    };
}

fn fillListDirMetadata(
    io: std.Io,
    dir: std.Io.Dir,
    entry: *fs.ListDirEntry,
    attributes: fs.ListDirAttributes,
) fs.ListDirError!void {
    if (attributes.size) {
        if (comptime builtin.os.tag == .linux) {
            entry.size = try linuxListDirEntrySize(dir, entry.name);
        } else {
            const stat = dir.statFile(io, entry.name, .{}) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => null,
                else => |stat_err| return stat_err,
            };
            if (stat) |metadata| entry.size = metadata.size;
        }
    }
    if (attributes.executable) {
        entry.executable = try executableAccess(io, dir, entry.name);
    }
}

fn linuxListDirEntrySize(dir: std.Io.Dir, name: []const u8) fs.ListDirError!?u64 {
    if (comptime builtin.os.tag != .linux) unreachable;
    if (name.len > std.Io.Dir.max_name_bytes) return error.NameTooLong;

    var name_buffer: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    @memcpy(name_buffer[0..name.len], name);
    name_buffer[name.len] = 0;
    const name_z = name_buffer[0..name.len :0];

    var statx_result: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(dir.handle, name_z.ptr, 0, linux_statx_size_mask, &statx_result);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .ACCES, .PERM => return null,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .IO => return error.InputOutput,
        .OVERFLOW, .FBIG => return error.FileTooBig,
        .BADF, .FAULT, .INVAL => return error.Unexpected,
        else => return error.Unexpected,
    }
    if (!statx_result.mask.SIZE) return null;
    return statx_result.size;
}

fn executableAccess(io: std.Io, dir: std.Io.Dir, name: []const u8) fs.ListDirError!bool {
    dir.access(io, name, .{ .execute = true }) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.SymLinkLoop,
        error.ReadOnlyFileSystem,
        => return false,
        else => |access_err| return access_err,
    };
    return true;
}

const MacosBulkEntry = struct {
    record_len: usize,
    name: []const u8,
    kind: fs.EntryKind,
    is_symlink: bool,
    size: ?u64,
    executable: ?bool,
};

fn parseMacosBulkEntry(
    buffer: []const u8,
    offset: usize,
    attributes: fs.ListDirAttributes,
) ListDirMacosBulkError!MacosBulkEntry {
    if (offset + @sizeOf(u32) + @sizeOf(MacosAttributeSet) > buffer.len) return error.Unexpected;
    const record_len = readNativeInt(u32, buffer[offset..][0..4]);
    if (record_len == 0 or offset + record_len > buffer.len) return error.Unexpected;

    var cursor = offset + @sizeOf(u32);
    const returned_attrs = readNativeStruct(MacosAttributeSet, buffer[cursor..][0..@sizeOf(MacosAttributeSet)]);
    cursor += @sizeOf(MacosAttributeSet);
    if (returned_attrs.commonattr & macos_attr_cmn_name == 0) return error.Unexpected;

    const name_ref = try readMacosAttrReference(buffer, offset, record_len, cursor);
    cursor += @sizeOf(MacosAttrReference);

    var parsed_kind: fs.EntryKind = .unknown;
    const reads_kind = attributes.kind or attributes.executable;
    if (reads_kind) {
        if (returned_attrs.commonattr & macos_attr_cmn_objtype == 0) return error.BulkUnsupported;
        if (cursor + @sizeOf(u32) > offset + record_len) return error.Unexpected;
        parsed_kind = macosEntryKind(readNativeInt(u32, buffer[cursor..][0..4]));
        cursor += @sizeOf(u32);
    }

    var executable: ?bool = null;
    if (attributes.executable) {
        if (returned_attrs.commonattr & macos_attr_cmn_useraccess == 0) return error.BulkUnsupported;
        if (cursor + @sizeOf(u32) > offset + record_len) return error.Unexpected;
        const user_access = readNativeInt(u32, buffer[cursor..][0..4]);
        executable = user_access & posix_x_ok != 0;
        cursor += @sizeOf(u32);
    }

    var size: ?u64 = null;
    if (attributes.size) {
        if (returned_attrs.fileattr & macos_attr_file_datalength == 0) return error.BulkUnsupported;
        if (cursor + @sizeOf(i64) > offset + record_len) return error.Unexpected;
        const data_length = readNativeInt(i64, buffer[cursor..][0..8]);
        if (data_length < 0) return error.Unexpected;
        size = @intCast(data_length);
    }

    return .{
        .record_len = record_len,
        .name = name_ref,
        .kind = if (attributes.kind) parsed_kind else .unknown,
        .is_symlink = parsed_kind == .symlink,
        .size = size,
        .executable = executable,
    };
}

const MacosAttrReference = extern struct {
    offset: i32,
    length: u32,
};

fn readMacosAttrReference(
    buffer: []const u8,
    record_offset: usize,
    record_len: usize,
    reference_offset: usize,
) fs.ListDirError![]const u8 {
    if (reference_offset + @sizeOf(MacosAttrReference) > record_offset + record_len) return error.Unexpected;
    const reference = readNativeStruct(
        MacosAttrReference,
        buffer[reference_offset..][0..@sizeOf(MacosAttrReference)],
    );
    if (reference.offset < 0) return error.Unexpected;
    const name_start = reference_offset + @as(usize, @intCast(reference.offset));
    if (name_start > record_offset + record_len or
        name_start + reference.length > record_offset + record_len) return error.Unexpected;
    return std.mem.sliceTo(buffer[name_start .. name_start + reference.length], 0);
}

fn macosEntryKind(vtype: u32) fs.EntryKind {
    return switch (vtype) {
        macos_vreg => .file,
        macos_vdir => .directory,
        macos_vlnk => .symlink,
        else => .other,
    };
}

fn macosBulkErrnoToListDirError() ListDirMacosBulkError {
    return switch (std.c.errno(-1)) {
        .SUCCESS => error.Unexpected,
        .INTR, .INVAL, .OPNOTSUPP => error.BulkUnsupported,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .BADF => error.Unexpected,
        .FAULT => error.Unexpected,
        .IO => error.InputOutput,
        .LOOP => error.SymLinkLoop,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOTDIR => error.NotDir,
        else => error.Unexpected,
    };
}

fn readNativeInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, bytes, builtin.cpu.arch.endian());
}

fn readNativeStruct(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.bytesToValue(T, bytes);
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
    if (request.executable_path) |executable_path| return spawnResolvedPath(adapter, request, executable_path);

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

fn spawnResolvedPath(
    adapter: *Adapter,
    request: process.SpawnRequest,
    executable_path: []const u8,
) process.SpawnError!process.SpawnResult {
    request.validate();
    std.debug.assert(request.executable_path != null);
    std.debug.assert(executable_path.len != 0);
    const environment = request.environment orelse return error.Unexpected;

    var reserved_stdio = try ReservedStandardDescriptors.init();
    defer reserved_stdio.deinit();

    const stdin_pipe = if (request.stdin == .pipe) try spawnPipe(adapter) else null;
    errdefer if (stdin_pipe) |descriptors| closePipe(descriptors);
    const stdout_pipe = if (request.stdout == .pipe) try spawnPipe(adapter) else null;
    errdefer if (stdout_pipe) |descriptors| closePipe(descriptors);
    const stderr_pipe = if (request.stderr == .pipe) try spawnPipe(adapter) else null;
    errdefer if (stderr_pipe) |descriptors| closePipe(descriptors);
    const err_pipe = try spawnPipe(adapter);
    errdefer closePipe(err_pipe);

    const dev_null = if (request.stdin == .ignore or request.stdout == .ignore or request.stderr == .ignore)
        try openNullDescriptor()
    else
        null;
    defer if (dev_null) |descriptor| closeDescriptor(descriptor) catch {};

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const executable_path_z = try arena.dupeZ(u8, executable_path);
    const argv_z = try arena.allocSentinel(?[*:0]const u8, request.argv.len, null);
    for (request.argv, 0..) |arg, index| argv_z[index] = (try arena.dupeZ(u8, arg)).ptr;
    const env_block = try environment.createPosixBlock(arena, .{});

    const pid = std.c.fork();
    switch (std.c.errno(pid)) {
        .SUCCESS => {},
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }

    if (pid == 0) {
        configureSpawnedChild(request, stdin_pipe, stdout_pipe, stderr_pipe, dev_null, err_pipe.write);
        _ = execve(executable_path_z.ptr, argv_z.ptr, env_block.slice.ptr);
        forkBail(err_pipe.write, execveErrorFromErrno(std.c.errno(-1)));
    }

    closeDescriptor(err_pipe.write) catch {};
    defer closeDescriptor(err_pipe.read) catch {};
    if (stdin_pipe) |descriptors| closeDescriptor(descriptors.read) catch {};
    if (stdout_pipe) |descriptors| closeDescriptor(descriptors.write) catch {};
    if (stderr_pipe) |descriptors| closeDescriptor(descriptors.write) catch {};

    if (readForkError(err_pipe.read)) |child_err_int| {
        return @errorCast(@errorFromInt(child_err_int));
    } else |read_err| switch (read_err) {
        error.EndOfStream => {},
        error.Unexpected => {},
    }

    const child: std.process.Child = .{
        .id = @intCast(pid),
        .thread_handle = {},
        .stdin = if (stdin_pipe) |descriptors| .{ .handle = descriptors.write, .flags = .{ .nonblocking = false } } else null,
        .stdout = if (stdout_pipe) |descriptors| .{ .handle = descriptors.read, .flags = .{ .nonblocking = false } } else null,
        .stderr = if (stderr_pipe) |descriptors| .{ .handle = descriptors.read, .flags = .{ .nonblocking = false } } else null,
        .request_resource_usage_statistics = false,
    };
    return .{ .child = process.ChildProcess.init(child) };
}

fn spawnPipe(adapter: *Adapter) process.SpawnError!fd.PipeResult {
    return pipe(@ptrCast(adapter), .{ .close_on_exec = true }) catch |err| switch (err) {
        error.Unsupported => error.OperationUnsupported,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.Unexpected => error.Unexpected,
    };
}

fn closePipe(descriptors: fd.PipeResult) void {
    closeDescriptor(descriptors.read) catch {};
    closeDescriptor(descriptors.write) catch {};
}

fn configureSpawnedChild(
    request: process.SpawnRequest,
    stdin_pipe: ?fd.PipeResult,
    stdout_pipe: ?fd.PipeResult,
    stderr_pipe: ?fd.PipeResult,
    dev_null: ?fd.Descriptor,
    err_fd: fd.Descriptor,
) void {
    if (request.process_group) |requested_group| {
        const group = if (requested_group == 0) std.c.getpid() else requested_group;
        if (std.c.setpgid(0, group) != 0) forkBail(err_fd, error.InvalidProcessGroupId);
    }
    configureSpawnCwd(request.cwd, err_fd);
    configureSpawnStdio(request.stdin, stdin_pipe, dev_null, 0, err_fd);
    configureSpawnStdio(request.stdout, stdout_pipe, dev_null, 1, err_fd);
    configureSpawnStdio(request.stderr, stderr_pipe, dev_null, 2, err_fd);

    if (stdin_pipe) |descriptors| closeDescriptor(descriptors.write) catch {};
    if (stdout_pipe) |descriptors| closeDescriptor(descriptors.read) catch {};
    if (stderr_pipe) |descriptors| closeDescriptor(descriptors.read) catch {};
}

fn configureSpawnCwd(cwd: process.Cwd, err_fd: fd.Descriptor) void {
    switch (cwd) {
        .inherit => {},
        .dir => |dir| if (std.c.fchdir(dir.handle) != 0) forkBail(err_fd, error.Unexpected),
        .path => |path| {
            const path_z = std.posix.toPosixPath(path) catch forkBail(err_fd, error.NameTooLong);
            if (std.c.chdir(&path_z) != 0) forkBail(err_fd, error.Unexpected);
        },
    }
}

fn configureSpawnStdio(
    stdio: process.StandardIo,
    pipe_descriptors: ?fd.PipeResult,
    dev_null: ?fd.Descriptor,
    target: fd.Descriptor,
    err_fd: fd.Descriptor,
) void {
    const source: ?fd.Descriptor = switch (stdio) {
        .inherit => null,
        .fd => |descriptor| descriptor,
        .ignore => dev_null orelse forkBail(err_fd, error.Unexpected),
        .pipe => switch (target) {
            0 => (pipe_descriptors orelse forkBail(err_fd, error.Unexpected)).read,
            1, 2 => (pipe_descriptors orelse forkBail(err_fd, error.Unexpected)).write,
            else => unreachable,
        },
        .close => {
            closeDescriptor(target) catch forkBail(err_fd, error.Unexpected);
            return;
        },
    };
    if (source) |descriptor| {
        if (descriptor != target) duplicateDescriptorTo(descriptor, target) catch forkBail(err_fd, error.Unexpected);
    }
}

const ForkErrorInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

fn forkBail(descriptor: fd.Descriptor, err: process.SpawnError) noreturn {
    writeForkError(descriptor, @intFromError(err)) catch {};
    std.c._exit(1);
}

fn writeForkError(descriptor: fd.Descriptor, value: ForkErrorInt) !void {
    var buffer: [@sizeOf(ForkErrorInt)]u8 = undefined;
    std.mem.writeInt(ForkErrorInt, &buffer, value, .little);
    var index: usize = 0;
    while (index < buffer.len) {
        const written = std.c.write(descriptor, buffer[index..].ptr, buffer.len - index);
        switch (std.c.errno(written)) {
            .SUCCESS => index += @intCast(written),
            .INTR => {},
            else => return error.Unexpected,
        }
    }
}

fn readForkError(descriptor: fd.Descriptor) error{ EndOfStream, Unexpected }!ForkErrorInt {
    var buffer: [@sizeOf(ForkErrorInt)]u8 = undefined;
    var index: usize = 0;
    while (index < buffer.len) {
        const read_count = std.c.read(descriptor, buffer[index..].ptr, buffer.len - index);
        switch (std.c.errno(read_count)) {
            .SUCCESS => {
                const count: usize = @intCast(read_count);
                if (count == 0) break;
                index += count;
            },
            .INTR => {},
            else => return error.Unexpected,
        }
    }
    if (index != buffer.len) return error.EndOfStream;
    return std.mem.readInt(ForkErrorInt, &buffer, .little);
}

fn execveErrorFromErrno(errno: std.c.E) process.SpawnError {
    return switch (errno) {
        .@"2BIG" => error.SystemResources,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .INVAL, .NOEXEC => error.InvalidExe,
        .IO, .LOOP => error.FileSystem,
        .ISDIR => error.IsDir,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .TXTBSY => error.FileBusy,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
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
    const runtime_number = runtimeNumberFromPosixSignal(posix_signal) orelse return;
    runtime_signal.recordCaughtSignal(runtime_number);
}

fn posixSignalFromRuntimeNumber(number: runtime_signal.Number) ?std.posix.SIG {
    runtime_signal.assertValidNumber(number);
    return switch (number) {
        @intFromEnum(std.posix.SIG.HUP) => .HUP,
        @intFromEnum(std.posix.SIG.INT) => .INT,
        @intFromEnum(std.posix.SIG.QUIT) => .QUIT,
        @intFromEnum(std.posix.SIG.PIPE) => .PIPE,
        @intFromEnum(std.posix.SIG.ALRM) => .ALRM,
        @intFromEnum(std.posix.SIG.CONT) => .CONT,
        @intFromEnum(std.posix.SIG.USR1) => .USR1,
        @intFromEnum(std.posix.SIG.USR2) => .USR2,
        @intFromEnum(std.posix.SIG.TERM) => .TERM,
        else => null,
    };
}

fn runtimeNumberFromPosixSignal(posix_signal: std.posix.SIG) ?runtime_signal.Number {
    return switch (posix_signal) {
        .HUP => @intFromEnum(std.posix.SIG.HUP),
        .INT => @intFromEnum(std.posix.SIG.INT),
        .QUIT => @intFromEnum(std.posix.SIG.QUIT),
        .PIPE => @intFromEnum(std.posix.SIG.PIPE),
        .ALRM => @intFromEnum(std.posix.SIG.ALRM),
        .CONT => @intFromEnum(std.posix.SIG.CONT),
        .USR1 => @intFromEnum(std.posix.SIG.USR1),
        .USR2 => @intFromEnum(std.posix.SIG.USR2),
        .TERM => @intFromEnum(std.posix.SIG.TERM),
        else => null,
    };
}

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
    var blocked = std.posix.sigemptyset();
    std.posix.sigaddset(&blocked, .TTOU);
    var previous: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, &previous);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous, null);
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

    var child = if (request.executable_path) |executable_path|
        (try spawnResolvedPath(adapter, .{
            .executable_path = executable_path,
            .argv = request.argv,
            .cwd = request.cwd,
            .environment = request.environment,
            .stdin = request.stdin_stdio,
            .stdout = .pipe,
            .stderr = .pipe,
        }, executable_path)).child.child
    else
        try std.process.spawn(adapter.io, .{
            .argv = request.argv,
            .cwd = request.cwd.toStdCwd(),
            .environ_map = request.environment,
            .stdin = request.stdin_stdio.toStdIo(),
            .stdout = .pipe,
            .stderr = .pipe,
        });

    std.debug.assert(child.stdout != null);
    std.debug.assert(child.stderr != null);

    var stdin_writer: StdinWriter = .{
        .io = adapter.io,
        .file = undefined,
        .bytes = request.stdin,
    };
    var stdin_thread: ?std.Thread = null;
    var stdin_joined = true;
    if (switch (request.stdin_stdio) {
        .pipe => true,
        .inherit, .fd, .ignore, .close => false,
    }) {
        std.debug.assert(child.stdin != null);
        stdin_writer.file = child.stdin.?;
        child.stdin = null;
        stdin_thread = std.Thread.spawn(.{}, StdinWriter.run, .{&stdin_writer}) catch |err| {
            child.kill(adapter.io);
            return err;
        };
        stdin_joined = false;
    } else std.debug.assert(child.stdin == null);
    defer {
        child.kill(adapter.io);
        if (!stdin_joined) stdin_thread.?.join();
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
    if (stdin_thread) |thread| {
        thread.join();
        stdin_joined = true;
        if (stdin_writer.err) |err| return err;
    }

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
    const Device = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(stat_result.dev)));
    const Inode = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(stat_result.ino)));
    return .{
        .device = @as(u64, @as(Device, @bitCast(stat_result.dev))),
        .inode = @as(u64, @as(Inode, @bitCast(stat_result.ino))),
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

fn duplicateDescriptorAtLeast(
    descriptor: fd.Descriptor,
    minimum_descriptor: fd.Descriptor,
    close_on_exec: bool,
) fd.DuplicateError!fd.Descriptor {
    fd.assertValidDescriptor(descriptor);
    fd.assertValidDescriptor(minimum_descriptor);
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const command = if (close_on_exec) std.os.linux.F.DUPFD_CLOEXEC else std.os.linux.F.DUPFD;
        while (true) {
            const rc = std.os.linux.fcntl(descriptor, command, @intCast(minimum_descriptor));
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .BADF => return error.BadFileDescriptor,
                .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .INVAL => return error.Unexpected,
                else => return error.Unexpected,
            }
        }
    }
    const command: c_int = if (close_on_exec and @hasDecl(std.c.F, "DUPFD_CLOEXEC"))
        std.c.F.DUPFD_CLOEXEC
    else
        std.c.F.DUPFD;
    while (true) {
        const rc = std.c.fcntl(descriptor, command, minimum_descriptor);
        switch (std.c.errno(rc)) {
            .SUCCESS => {
                const duplicated: fd.Descriptor = @intCast(rc);
                if (close_on_exec and command == std.c.F.DUPFD) try setCloseOnExec(duplicated);
                return duplicated;
            },
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL => return error.Unexpected,
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
    var previous_usr1: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR1, &action, &previous_usr1);
    defer std.posix.sigaction(.USR1, &previous_usr1, null);

    var adapter = Adapter.init(std.testing.io);
    const signal_port = adapter.signalPort();
    const term_number: runtime_signal.Number = @intFromEnum(std.posix.SIG.TERM);
    try signal_port.configure(.{ .signal = term_number, .disposition = .caught });

    runtimeSignalHandler(.TERM);

    const event = (try signal_port.poll()).?;
    try std.testing.expectEqual(term_number, event.signal);
    try std.testing.expectEqual(@as(?runtime_signal.Event, null), try signal_port.poll());

    const usr1_number: runtime_signal.Number = @intFromEnum(std.posix.SIG.USR1);
    try signal_port.configure(.{ .signal = usr1_number, .disposition = .caught });
    runtimeSignalHandler(.USR1);

    const usr1_event = (try signal_port.poll()).?;
    try std.testing.expectEqual(usr1_number, usr1_event.signal);
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

test "runtime posix adapter listDir defaults to names and kinds only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "hello" });
    try tmp.dir.createDir(std.testing.io, "subdir", .default_dir);

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];

    var adapter = Adapter.init(std.testing.io);
    const fs_port = adapter.fsPort();
    var entries = try fs_port.listDir(.{ .allocator = std.testing.allocator, .path = tmp_root });
    defer entries.deinit();

    const note = try expectListDirEntry(entries.entries, "note.txt");
    try std.testing.expectEqual(fs.EntryKind.file, note.kind);
    try std.testing.expectEqual(@as(?u64, null), note.size);
    try std.testing.expectEqual(@as(?bool, null), note.executable);

    const subdir = try expectListDirEntry(entries.entries, "subdir");
    try std.testing.expectEqual(fs.EntryKind.directory, subdir.kind);
    try std.testing.expectEqual(@as(?u64, null), subdir.size);
    try std.testing.expectEqual(@as(?bool, null), subdir.executable);
}

test "runtime posix adapter lists requested directory entry metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var executable = try tmp.dir.createFile(std.testing.io, "rush-tool", .{ .permissions = .executable_file });
    executable.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "hello" });
    try tmp.dir.symLink(std.testing.io, "note.txt", "note-link", .{});
    try tmp.dir.symLink(std.testing.io, "rush-tool", "tool-link", .{});

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];

    var adapter = Adapter.init(std.testing.io);
    const fs_port = adapter.fsPort();
    var entries = try fs_port.listDir(.{
        .allocator = std.testing.allocator,
        .path = tmp_root,
        .attributes = .{ .kind = true, .size = true, .executable = true },
    });
    defer entries.deinit();

    var saw_executable = false;
    var saw_note = false;
    var saw_note_link = false;
    var saw_tool_link = false;
    for (entries.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "rush-tool")) {
            saw_executable = true;
            try std.testing.expectEqual(fs.EntryKind.file, entry.kind);
            try std.testing.expectEqual(@as(?bool, true), entry.executable);
        } else if (std.mem.eql(u8, entry.name, "note.txt")) {
            saw_note = true;
            try std.testing.expectEqual(fs.EntryKind.file, entry.kind);
            try std.testing.expectEqual(@as(?u64, 5), entry.size);
            try std.testing.expectEqual(@as(?bool, false), entry.executable);
        } else if (std.mem.eql(u8, entry.name, "note-link")) {
            saw_note_link = true;
            try std.testing.expectEqual(fs.EntryKind.symlink, entry.kind);
            try std.testing.expectEqual(@as(?bool, false), entry.executable);
        } else if (std.mem.eql(u8, entry.name, "tool-link")) {
            saw_tool_link = true;
            try std.testing.expectEqual(fs.EntryKind.symlink, entry.kind);
            try std.testing.expectEqual(@as(?bool, true), entry.executable);
        }
    }
    try std.testing.expect(saw_executable);
    try std.testing.expect(saw_note);
    try std.testing.expect(saw_note_link);
    try std.testing.expect(saw_tool_link);
}

test "runtime posix adapter listDir reports missing and non-directory paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain", .data = "hello" });

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];

    const allocator = std.testing.allocator;
    const file_path = try std.fmt.allocPrint(allocator, "{s}/plain", .{tmp_root});
    defer allocator.free(file_path);
    const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing", .{tmp_root});
    defer allocator.free(missing_path);

    var adapter = Adapter.init(std.testing.io);
    const fs_port = adapter.fsPort();
    try std.testing.expectError(error.NotDir, fs_port.listDir(.{ .allocator = allocator, .path = file_path }));
    try std.testing.expectError(error.FileNotFound, fs_port.listDir(.{ .allocator = allocator, .path = missing_path }));
}

fn expectListDirEntry(entries: []const fs.ListDirEntry, name: []const u8) !fs.ListDirEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return error.TestUnexpectedResult;
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
