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

pub const GetCwdError = std.process.CurrentPathError;
pub const ChangeCwdError = std.process.SetCurrentPathError;
pub const AccessError = std.Io.Dir.AccessError;

pub const GetCwdFn = *const fn (*anyopaque, GetCwdRequest) GetCwdError!GetCwdResult;
pub const ChangeCwdFn = *const fn (*anyopaque, ChangeCwdRequest) ChangeCwdError!void;
pub const AccessFn = *const fn (*anyopaque, AccessRequest) AccessError!void;

pub const Port = struct {
    context: *anyopaque,
    get_cwd_fn: GetCwdFn,
    change_cwd_fn: ChangeCwdFn,
    access_fn: AccessFn,

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
}
