//! Concrete host effect contract used by the direct evaluator.
//!
//! The evaluator is generic over a comptime-known Host type. These types define
//! the values passed across that boundary; the real host implementation should
//! call `std.posix` or targeted platform APIs directly.

const std = @import("std");

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

pub const OpenRequest = struct {
    path: []const u8,
    access: OpenAccess,
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

pub const SpawnFdAction = union(enum) {
    close: Fd,
    duplicate: struct {
        from: Fd,
        to: Fd,
    },
};

pub const SpawnRequest = struct {
    path: []const u8,
    argv: []const []const u8,
    env: []const []const u8,
    cwd: ?[]const u8 = null,
    fd_actions: []const SpawnFdAction = &.{},
    process_group: ?Pid = null,

    pub fn validate(self: SpawnRequest) void {
        std.debug.assert(self.path.len != 0);
        std.debug.assert(self.argv.len != 0);
        std.debug.assert(self.argv[0].len != 0);
    }
};

pub const SpawnResult = struct {
    pid: Pid,
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

pub const DirectoryEntry = struct {
    name: []const u8,
    kind: FileKind,
};
