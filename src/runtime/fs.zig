//! Filesystem runtime port vocabulary.
//!
//! The semantic shell core will use this boundary for cwd and environment-facing
//! filesystem effects. POSIX path/syscall details stay in the adapter layer.

const std = @import("std");

pub const Path = []const u8;

pub const Operation = enum {
    get_cwd,
    set_cwd,
    inspect_path,
    list_dir,
    set_file_creation_mask,
};

pub const GetCwdRequest = struct {
    buffer: []u8,

    pub fn init(buffer: []u8) GetCwdRequest {
        const request: GetCwdRequest = .{ .buffer = buffer };
        request.validate();
        return request;
    }

    pub fn validate(self: GetCwdRequest) void {
        std.debug.assert(self.buffer.len != 0);
    }
};

pub const GetCwdResult = struct {
    path: Path,

    pub fn validate(self: GetCwdResult) void {
        std.debug.assert(self.path.len != 0);
    }
};

pub const ChangeCwdRequest = struct {
    path: Path,

    /// `path` is borrowed for the duration of the call; the runtime does not
    /// retain it after the current directory change request returns.
    pub fn init(path: Path) ChangeCwdRequest {
        const request: ChangeCwdRequest = .{ .path = path };
        request.validate();
        return request;
    }

    pub fn validate(self: ChangeCwdRequest) void {
        std.debug.assert(self.path.len != 0);
    }
};

pub const AccessRequest = struct {
    path: Path,
    follow_symlinks: bool = true,
    read: bool = false,
    write: bool = false,
    execute: bool = false,

    /// `path` is borrowed for the duration of the call. This is a low-level
    /// access probe only; callers must not use it to encode shell policy.
    pub fn init(path: Path) AccessRequest {
        const request: AccessRequest = .{ .path = path };
        request.validate();
        return request;
    }

    pub fn validate(self: AccessRequest) void {
        std.debug.assert(self.path.len != 0);
    }

    pub fn toStdOptions(self: AccessRequest) std.Io.Dir.AccessOptions {
        self.validate();
        return .{
            .follow_symlinks = self.follow_symlinks,
            .read = self.read,
            .write = self.write,
            .execute = self.execute,
        };
    }
};

pub const InspectPathRequest = struct {
    path: Path,
    follow_symlinks: bool = true,

    /// `path` is borrowed for the duration of the call. The result is a
    /// low-level metadata snapshot; callers own shell policy.
    pub fn init(path: Path) InspectPathRequest {
        const request: InspectPathRequest = .{ .path = path };
        request.validate();
        return request;
    }

    pub fn validate(self: InspectPathRequest) void {
        std.debug.assert(self.path.len != 0);
    }

    pub fn toStdOptions(self: InspectPathRequest) std.Io.Dir.StatFileOptions {
        self.validate();
        return .{ .follow_symlinks = self.follow_symlinks };
    }
};

pub const PathIdentity = struct {
    device: u64,
    inode: u64,

    pub fn validate(self: PathIdentity) void {
        std.debug.assert(self.inode != 0);
    }
};

pub const InspectPathResult = struct {
    stat: std.Io.File.Stat,
    identity: ?PathIdentity = null,

    pub fn validate(self: InspectPathResult) void {
        if (self.identity) |identity| identity.validate();
    }
};

pub const EntryKind = enum {
    unknown,
    file,
    directory,
    symlink,
    other,

    pub fn fromStd(kind: std.Io.File.Kind) EntryKind {
        return switch (kind) {
            .unknown => .unknown,
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            .block_device,
            .character_device,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            => .other,
        };
    }
};

pub const ListDirEntry = struct {
    name: []const u8,
    kind: EntryKind = .unknown,
    size: ?u64 = null,
    executable: ?bool = null,

    pub fn validate(self: ListDirEntry) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const ListDirAttributes = struct {
    kind: bool = true,
    size: bool = false,
    executable: bool = false,

    pub fn needsStatLikeMetadata(self: ListDirAttributes) bool {
        return self.size or self.executable;
    }
};

pub const ListDirRequest = struct {
    allocator: std.mem.Allocator,
    path: Path,
    attributes: ListDirAttributes = .{},

    /// `path` is borrowed for the duration of the call. Returned entry names are
    /// owned by `allocator`; callers must release them with `ListDirResult.deinit`.
    pub fn init(allocator: std.mem.Allocator, path: Path) ListDirRequest {
        const request: ListDirRequest = .{ .allocator = allocator, .path = path };
        request.validate();
        return request;
    }

    pub fn validate(self: ListDirRequest) void {
        std.debug.assert(self.path.len != 0);
    }
};

pub const ListDirResult = struct {
    allocator: std.mem.Allocator,
    entries: []const ListDirEntry,

    pub fn deinit(self: *ListDirResult) void {
        for (self.entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn release(self: *ListDirResult) []const ListDirEntry {
        const entries = self.entries;
        self.entries = &.{};
        return entries;
    }

    pub fn validate(self: ListDirResult) void {
        for (self.entries) |entry| entry.validate();
    }
};

pub const FileCreationMask = u16;

pub const SetFileCreationMaskRequest = struct {
    mask: FileCreationMask,

    pub fn init(mask: FileCreationMask) SetFileCreationMaskRequest {
        const request: SetFileCreationMaskRequest = .{ .mask = mask };
        request.validate();
        return request;
    }

    pub fn validate(self: SetFileCreationMaskRequest) void {
        std.debug.assert(self.mask <= 0o777);
    }
};

pub const SetFileCreationMaskResult = struct {
    previous: FileCreationMask,

    pub fn validate(self: SetFileCreationMaskResult) void {
        std.debug.assert(self.previous <= 0o777);
    }
};

pub const GetCwdError = std.process.CurrentPathError;
pub const ChangeCwdError = std.process.SetCurrentPathError;
pub const AccessError = std.Io.Dir.AccessError;
pub const InspectPathError = std.Io.Dir.StatFileError;
pub const ListDirError = std.mem.Allocator.Error ||
    std.Io.Dir.OpenError ||
    std.Io.Dir.Iterator.Error ||
    std.Io.Dir.StatFileError ||
    std.Io.Dir.AccessError ||
    error{Unexpected};
pub const SetFileCreationMaskError = error{Unexpected};

pub const GetCwdFn = *const fn (*anyopaque, GetCwdRequest) GetCwdError!GetCwdResult;
pub const ChangeCwdFn = *const fn (*anyopaque, ChangeCwdRequest) ChangeCwdError!void;
pub const AccessFn = *const fn (*anyopaque, AccessRequest) AccessError!void;
pub const InspectPathFn = *const fn (*anyopaque, InspectPathRequest) InspectPathError!InspectPathResult;
pub const ListDirFn = *const fn (*anyopaque, ListDirRequest) ListDirError!ListDirResult;
pub const SetFileCreationMaskFn = *const fn (
    *anyopaque,
    SetFileCreationMaskRequest,
) SetFileCreationMaskError!SetFileCreationMaskResult;

pub const Port = struct {
    context: *anyopaque,
    get_cwd_fn: GetCwdFn,
    change_cwd_fn: ChangeCwdFn,
    access_fn: AccessFn,
    inspect_path_fn: InspectPathFn,
    list_dir_fn: ListDirFn,
    set_file_creation_mask_fn: SetFileCreationMaskFn,

    pub fn getCwd(self: Port, request: GetCwdRequest) GetCwdError!GetCwdResult {
        request.validate();
        const result = try self.get_cwd_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn changeCwd(self: Port, request: ChangeCwdRequest) ChangeCwdError!void {
        request.validate();
        try self.change_cwd_fn(self.context, request);
    }

    pub fn access(self: Port, request: AccessRequest) AccessError!void {
        request.validate();
        try self.access_fn(self.context, request);
    }

    pub fn inspectPath(self: Port, request: InspectPathRequest) InspectPathError!InspectPathResult {
        request.validate();
        const result = try self.inspect_path_fn(self.context, request);
        result.validate();
        return result;
    }

    // ziglint-ignore: Z015 - ListDirError is `pub`, but ziglint does not treat
    // `||`-merged error sets as public type declarations (false positive).
    pub fn listDir(self: Port, request: ListDirRequest) ListDirError!ListDirResult {
        request.validate();
        const result = try self.list_dir_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn setFileCreationMask(
        self: Port,
        request: SetFileCreationMaskRequest,
    ) SetFileCreationMaskError!SetFileCreationMaskResult {
        request.validate();
        const result = try self.set_file_creation_mask_fn(self.context, request);
        result.validate();
        return result;
    }
};

test "runtime fs requests validate borrowed path and buffer lifetimes" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_request = GetCwdRequest.init(&buffer);
    cwd_request.validate();

    const change_request = ChangeCwdRequest.init(".");
    change_request.validate();

    const access_request = AccessRequest.init(".");
    access_request.validate();
    const options = access_request.toStdOptions();
    try std.testing.expect(options.follow_symlinks);
    try std.testing.expect(!options.read);
    try std.testing.expect(!options.write);
    try std.testing.expect(!options.execute);

    const inspect_request = InspectPathRequest.init(".");
    inspect_request.validate();
    const inspect_options = inspect_request.toStdOptions();
    try std.testing.expect(inspect_options.follow_symlinks);

    const identity: PathIdentity = .{ .device = 1, .inode = 2 };
    identity.validate();

    const list_request = ListDirRequest.init(std.testing.allocator, ".");
    list_request.validate();
}
