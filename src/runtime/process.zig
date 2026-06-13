//! Process-control runtime port vocabulary.
//!
//! The semantic shell core will ask this port to spawn/exec/wait and manage job
//! control primitives. This file intentionally contains no POSIX syscall
//! implementation; `posix.zig` owns that adapter role.

const std = @import("std");
const fd = @import("fd.zig");

pub const ProcessId = std.posix.pid_t;

pub const WaitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    stopped: u8,
    unknown: u32,
};

pub const Operation = enum {
    spawn,
    wait,
};

pub const Cwd = union(enum) {
    inherit,
    path: []const u8,
    dir: std.Io.Dir,

    pub fn validate(self: Cwd) void {
        switch (self) {
            .inherit => {},
            .path => |path| std.debug.assert(path.len != 0),
            .dir => |dir| fd.assertValidDescriptor(dir.handle),
        }
    }

    pub fn toStdCwd(self: Cwd) std.process.Child.Cwd {
        self.validate();
        return switch (self) {
            .inherit => .inherit,
            .path => |path| .{ .path = path },
            .dir => |dir| .{ .dir = dir },
        };
    }
};

pub const StandardIo = union(enum) {
    inherit,
    fd: fd.Descriptor,
    ignore,
    pipe,
    close,

    pub fn validate(self: StandardIo) void {
        switch (self) {
            .inherit, .ignore, .pipe, .close => {},
            .fd => |descriptor| fd.assertValidDescriptor(descriptor),
        }
    }

    pub fn toStdIo(self: StandardIo) std.process.SpawnOptions.StdIo {
        self.validate();
        return switch (self) {
            .inherit => .inherit,
            .fd => |descriptor| .{ .file = .{ .handle = descriptor, .flags = .{ .nonblocking = false } } },
            .ignore => .ignore,
            .pipe => .pipe,
            .close => .close,
        };
    }
};

pub const SpawnRequest = struct {
    argv: []const []const u8,
    cwd: Cwd = .inherit,
    environment: ?*const std.process.Environ.Map = null,
    stdin: StandardIo = .inherit,
    stdout: StandardIo = .inherit,
    stderr: StandardIo = .inherit,
    process_group: ?ProcessId = null,

    /// `argv`, `environment`, and any path slices are borrowed only until the
    /// spawn call returns. The child owns its process image after the adapter
    /// successfully creates it.
    pub fn init(argv: []const []const u8) SpawnRequest {
        const request: SpawnRequest = .{ .argv = argv };
        request.validate();
        return request;
    }

    pub fn validate(self: SpawnRequest) void {
        std.debug.assert(self.argv.len != 0);
        std.debug.assert(self.argv[0].len != 0);
        self.cwd.validate();
        self.stdin.validate();
        self.stdout.validate();
        self.stderr.validate();
    }
};

pub const ChildProcess = struct {
    child: std.process.Child,
    state: State = .running,

    pub const State = enum {
        running,
        waited,
    };

    pub fn init(child: std.process.Child) ChildProcess {
        var process: ChildProcess = .{ .child = child };
        process.validateRunning();
        return process;
    }

    pub fn id(self: ChildProcess) ProcessId {
        self.validateRunning();
        return self.child.id.?;
    }

    pub fn validateRunning(self: ChildProcess) void {
        std.debug.assert(self.state == .running);
        std.debug.assert(self.child.id != null);
    }

    pub fn markWaited(self: *ChildProcess) void {
        std.debug.assert(self.state == .running);
        std.debug.assert(self.child.id == null);
        self.state = .waited;
    }

    pub fn validateWaited(self: ChildProcess) void {
        std.debug.assert(self.state == .waited);
        std.debug.assert(self.child.id == null);
    }
};

pub const SpawnResult = struct {
    child: ChildProcess,

    pub fn validate(self: SpawnResult) void {
        self.child.validateRunning();
    }
};

pub const WaitRequest = struct {
    child: *ChildProcess,

    pub fn init(child: *ChildProcess) WaitRequest {
        const request: WaitRequest = .{ .child = child };
        request.validate();
        return request;
    }

    pub fn validate(self: WaitRequest) void {
        self.child.validateRunning();
    }
};

pub const WaitResult = struct {
    status: WaitStatus,

    pub fn validate(self: WaitResult) void {
        switch (self.status) {
            .exited => {},
            .signaled => |signal| std.debug.assert(signal != 0),
            .stopped => |signal| std.debug.assert(signal != 0),
            .unknown => {},
        }
    }
};

pub const SpawnError = std.process.SpawnError;
pub const WaitError = std.process.Child.WaitError;

pub const SpawnFn = *const fn (*anyopaque, SpawnRequest) SpawnError!SpawnResult;
pub const WaitFn = *const fn (*anyopaque, WaitRequest) WaitError!WaitResult;

pub const Port = struct {
    context: *anyopaque,
    spawn_fn: SpawnFn,
    wait_fn: WaitFn,

    pub fn spawn(self: Port, request: SpawnRequest) SpawnError!SpawnResult {
        request.validate();
        const result = try self.spawn_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn wait(self: Port, request: WaitRequest) WaitError!WaitResult {
        request.validate();
        const result = try self.wait_fn(self.context, request);
        request.child.validateWaited();
        result.validate();
        return result;
    }
};

test "runtime process spawn request documents argv and stdio invariants" {
    const argv = [_][]const u8{ "/bin/sh", "-c", "exit 0" };
    const request: SpawnRequest = .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    };
    request.validate();

    try std.testing.expectEqual(std.process.SpawnOptions.StdIo.ignore, request.stdin.toStdIo());
    try std.testing.expectEqual(std.process.SpawnOptions.StdIo.ignore, request.stdout.toStdIo());
    try std.testing.expectEqual(std.process.SpawnOptions.StdIo.ignore, request.stderr.toStdIo());
}

test "runtime process cwd and descriptor-backed stdio are low-level values" {
    const cwd: Cwd = .{ .path = "." };
    cwd.validate();
    const std_cwd = cwd.toStdCwd();
    try std.testing.expectEqualStrings(".", std_cwd.path);

    const stdio: StandardIo = .{ .fd = 1 };
    stdio.validate();
    const std_stdio = stdio.toStdIo();
    try std.testing.expectEqual(@as(fd.Descriptor, 1), std_stdio.file.handle);
}
