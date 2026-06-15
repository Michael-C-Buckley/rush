//! Process-control runtime port vocabulary.
//!
//! The semantic shell core will ask this port to spawn/exec/wait and manage job
//! control primitives. This file intentionally contains no POSIX syscall
//! implementation; `posix.zig` owns that adapter role.

const std = @import("std");
const fd = @import("fd.zig");

// ziglint-ignore: Z006 type alias
pub const ProcessId = std.posix.pid_t;

pub const ExternalStdio = enum {
    capture,
    capture_stdout,
    /// Externals write to the shell's stdout and stderr but read script input,
    /// not the terminal. Used for the last stage of an interactive pipeline,
    /// where stdin is the pipe but output belongs to the tty.
    inherit_output,
    inherit,
};

pub const WaitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    stopped: u8,
    unknown: u32,
};

pub const ProcessTarget = union(enum) {
    process: ProcessId,
    process_group: ProcessId,

    pub fn validate(self: ProcessTarget) void {
        switch (self) {
            .process => |process_id| std.debug.assert(process_id > 0),
            .process_group => |process_group| std.debug.assert(process_group > 0),
        }
    }
};

pub const Operation = enum {
    spawn,
    start_subshell,
    wait,
    poll_wait,
    run,
    continue_process,
    foreground_process_group,
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

pub const SubshellMainFn = *const fn (*anyopaque) u8;

pub const StartSubshellRequest = struct {
    context: *anyopaque,
    main_fn: SubshellMainFn,
    stdin: StandardIo = .inherit,
    stdout: StandardIo = .inherit,
    stderr: StandardIo = .inherit,
    process_group: ?ProcessId = null,

    /// Forks a child process and invokes `main_fn` in that child. Runtime owns
    /// only the low-level fork/stdio/process-group mechanics; the callback is
    /// supplied by the shell layer and returns the child's exit status.
    pub fn init(context: *anyopaque, main_fn: SubshellMainFn) StartSubshellRequest {
        const request: StartSubshellRequest = .{ .context = context, .main_fn = main_fn };
        request.validate();
        return request;
    }

    pub fn validate(self: StartSubshellRequest) void {
        _ = self.context;
        _ = self.main_fn;
        self.stdin.validate();
        self.stdout.validate();
        self.stderr.validate();
        if (self.process_group) |process_group| std.debug.assert(process_group >= 0);
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

pub const CpuDuration = struct {
    microseconds: u64,

    pub fn validate(self: CpuDuration) void {
        _ = self;
    }
};

pub const ProcessTimes = struct {
    shell_user: CpuDuration = .{ .microseconds = 0 },
    shell_system: CpuDuration = .{ .microseconds = 0 },
    children_user: CpuDuration = .{ .microseconds = 0 },
    children_system: CpuDuration = .{ .microseconds = 0 },

    pub fn validate(self: ProcessTimes) void {
        self.shell_user.validate();
        self.shell_system.validate();
        self.children_user.validate();
        self.children_system.validate();
    }
};

pub const PollWaitRequest = struct {
    child: *ChildProcess,
    nohang: bool = true,
    report_stopped: bool = true,

    pub fn init(child: *ChildProcess) PollWaitRequest {
        const request: PollWaitRequest = .{ .child = child };
        request.validate();
        return request;
    }

    pub fn validate(self: PollWaitRequest) void {
        _ = self.nohang;
        _ = self.report_stopped;
        self.child.validateRunning();
    }
};

pub const PollWaitResult = struct {
    status: ?WaitStatus = null,

    pub fn validate(self: PollWaitResult) void {
        if (self.status) |status| (WaitResult{ .status = status }).validate();
    }
};

pub const RunRequest = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: Cwd = .inherit,
    environment: ?*const std.process.Environ.Map = null,
    stdin: []const u8 = &.{},

    /// `argv`, `environment`, `stdin`, and path slices are borrowed only until
    /// the run call returns. Captured output in the result is owned by
    /// `allocator`.
    pub fn init(allocator: std.mem.Allocator, argv: []const []const u8) RunRequest {
        const request: RunRequest = .{ .allocator = allocator, .argv = argv };
        request.validate();
        return request;
    }

    pub fn validate(self: RunRequest) void {
        _ = self.allocator;
        std.debug.assert(self.argv.len != 0);
        std.debug.assert(self.argv[0].len != 0);
        self.cwd.validate();
    }
};

pub const RunResult = struct {
    allocator: std.mem.Allocator,
    status: WaitStatus,
    stdout: []u8,
    stderr: []u8,

    pub fn validate(self: RunResult) void {
        _ = self.allocator;
        (WaitResult{ .status = self.status }).validate();
    }

    pub fn deinit(self: *RunResult) void {
        self.validate();
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const ContinueProcessRequest = struct {
    target: ProcessTarget,

    pub fn init(target: ProcessTarget) ContinueProcessRequest {
        const request: ContinueProcessRequest = .{ .target = target };
        request.validate();
        return request;
    }

    pub fn validate(self: ContinueProcessRequest) void {
        self.target.validate();
    }
};

pub const ForegroundProcessGroupRequest = struct {
    terminal: fd.Descriptor = 0,
    process_group: ProcessId,

    pub fn init(process_group: ProcessId) ForegroundProcessGroupRequest {
        const request: ForegroundProcessGroupRequest = .{ .process_group = process_group };
        request.validate();
        return request;
    }

    pub fn validate(self: ForegroundProcessGroupRequest) void {
        fd.assertValidDescriptor(self.terminal);
        std.debug.assert(self.process_group > 0);
    }
};

pub const ForegroundProcessGroupResult = struct {
    previous_process_group: ProcessId,

    pub fn validate(self: ForegroundProcessGroupResult) void {
        std.debug.assert(self.previous_process_group > 0);
    }
};

pub const SpawnError = std.process.SpawnError;
pub const WaitError = std.process.Child.WaitError;
pub const RunError = anyerror;
pub const TimesError = error{OperationUnsupported};
pub const JobControlError = error{
    OperationUnsupported,
    ProcessNotFound,
    PermissionDenied,
    Unexpected,
};

pub const SpawnFn = *const fn (*anyopaque, SpawnRequest) SpawnError!SpawnResult;
pub const StartSubshellFn = *const fn (*anyopaque, StartSubshellRequest) SpawnError!SpawnResult;
pub const WaitFn = *const fn (*anyopaque, WaitRequest) WaitError!WaitResult;
pub const PollWaitFn = *const fn (*anyopaque, PollWaitRequest) WaitError!PollWaitResult;
pub const RunFn = *const fn (*anyopaque, RunRequest) RunError!RunResult;
pub const GetTimesFn = *const fn (*anyopaque) TimesError!ProcessTimes;
pub const ContinueProcessFn = *const fn (*anyopaque, ContinueProcessRequest) JobControlError!void;
pub const ForegroundProcessGroupFn = *const fn (
    *anyopaque,
    ForegroundProcessGroupRequest,
) JobControlError!ForegroundProcessGroupResult;

pub const Port = struct {
    context: *anyopaque,
    spawn_fn: SpawnFn,
    start_subshell_fn: ?StartSubshellFn = null,
    wait_fn: WaitFn,
    poll_wait_fn: ?PollWaitFn = null,
    run_fn: RunFn,
    get_times_fn: ?GetTimesFn = null,
    continue_process_fn: ?ContinueProcessFn = null,
    foreground_process_group_fn: ?ForegroundProcessGroupFn = null,

    pub fn spawn(self: Port, request: SpawnRequest) SpawnError!SpawnResult {
        request.validate();
        const result = try self.spawn_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn startSubshell(self: Port, request: StartSubshellRequest) SpawnError!SpawnResult {
        request.validate();
        const start_subshell_fn = self.start_subshell_fn orelse return error.OperationUnsupported;
        const result = try start_subshell_fn(self.context, request);
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

    pub fn pollWait(self: Port, request: PollWaitRequest) WaitError!PollWaitResult {
        request.validate();
        const poll_wait_fn = self.poll_wait_fn orelse return error.Unexpected;
        const result = try poll_wait_fn(self.context, request);
        if (result.status) |status| switch (status) {
            .stopped => request.child.validateRunning(),
            .exited, .signaled, .unknown => request.child.validateWaited(),
        } else request.child.validateRunning();
        result.validate();
        return result;
    }

    pub fn run(self: Port, request: RunRequest) RunError!RunResult {
        request.validate();
        const result = try self.run_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn getTimes(self: Port) TimesError!ProcessTimes {
        const get_times_fn = self.get_times_fn orelse return error.OperationUnsupported;
        const result = try get_times_fn(self.context);
        result.validate();
        return result;
    }

    pub fn continueProcess(self: Port, request: ContinueProcessRequest) JobControlError!void {
        request.validate();
        const continue_process_fn = self.continue_process_fn orelse return error.OperationUnsupported;
        try continue_process_fn(self.context, request);
    }

    pub fn foregroundProcessGroup(
        self: Port,
        request: ForegroundProcessGroupRequest,
    ) JobControlError!ForegroundProcessGroupResult {
        request.validate();
        const foreground_process_group_fn = self.foreground_process_group_fn orelse return error.OperationUnsupported;
        const result = try foreground_process_group_fn(self.context, request);
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

fn testSubshellMain(context: *anyopaque) u8 {
    const value: *const u8 = @ptrCast(@alignCast(context));
    return value.*;
}

test "runtime process subshell request owns only low-level launch shape" {
    const status: u8 = 5;
    const request = StartSubshellRequest.init(@ptrCast(@constCast(&status)), testSubshellMain);
    request.validate();

    try std.testing.expectEqual(StandardIo.inherit, request.stdin);
    try std.testing.expectEqual(@as(?ProcessId, null), request.process_group);
}

test "runtime process job-control requests stay low-level" {
    const target: ProcessTarget = .{ .process_group = 1234 };
    target.validate();

    const continue_request = ContinueProcessRequest.init(target);
    continue_request.validate();

    const foreground_request = ForegroundProcessGroupRequest.init(1234);
    foreground_request.validate();

    try std.testing.expectEqual(@as(fd.Descriptor, 0), foreground_request.terminal);
    try std.testing.expectEqual(@as(ProcessId, 1234), foreground_request.process_group);
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

test "runtime process captured run request owns byte streams" {
    const argv = [_][]const u8{"/bin/cat"};
    const request = RunRequest.init(std.testing.allocator, &argv);
    request.validate();

    var result: RunResult = .{
        .allocator = std.testing.allocator,
        .status = .{ .exited = 0 },
        .stdout = try std.testing.allocator.dupe(u8, "out"),
        .stderr = try std.testing.allocator.dupe(u8, "err"),
    };
    result.validate();
    result.deinit();
}

test "runtime process times carry shell and child cpu durations" {
    const times: ProcessTimes = .{
        .shell_user = .{ .microseconds = 1 },
        .shell_system = .{ .microseconds = 2 },
        .children_user = .{ .microseconds = 3 },
        .children_system = .{ .microseconds = 4 },
    };
    times.validate();

    try std.testing.expectEqual(@as(u64, 1), times.shell_user.microseconds);
    try std.testing.expectEqual(@as(u64, 4), times.children_system.microseconds);
}
