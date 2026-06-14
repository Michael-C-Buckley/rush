//! Background completion worker and request controller for the editor driver.

const std = @import("std");
const builtin = @import("builtin");

const completion = @import("completion.zig");

const log = std.log.scoped(.editor_worker);
const debounce_ms = 75;

pub const CompleteFn = *const fn (
    *anyopaque,
    std.mem.Allocator,
    std.Io,
    []const u8,
    usize,
) anyerror!completion.Application;
pub const FreeContextFn = *const fn (*anyopaque, std.mem.Allocator) void;

pub const RequestReason = enum { explicit, refresh };

pub const Request = struct {
    generation: u64,
    source: []u8,
    cursor: usize,
    reason: RequestReason,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    success: struct {
        generation: u64,
        source: []u8,
        cursor: usize,
        application: completion.Application,
    },
    failed: u64,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .success => |payload| {
                allocator.free(payload.source);
                payload.application.deinit(allocator);
            },
            .failed => {},
        }
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    complete: ?CompleteFn,
    free_context: ?FreeContextFn,
    request: Request,
    context: ?*anyopaque,
    cancel: completion.CancellationToken = .{},
    wake_fd: std.posix.fd_t,
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    mutex: std.atomic.Mutex = .unlocked,
    result: ?Result = null,

    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, Worker.run, .{self});
    }

    fn run(self: *Worker) void {
        defer {
            self.done.store(true, .release);
            writeFdAll(self.wake_fd, "c") catch |err| log.debug("failed to wake completion consumer: {}", .{err});
        }
        const complete = self.complete orelse return self.storeResult(.{ .failed = self.request.generation });
        const context = self.context orelse return self.storeResult(.{ .failed = self.request.generation });
        const application = complete(context, self.allocator, self.io, self.request.source, self.request.cursor) catch {
            return self.storeResult(.{ .failed = self.request.generation });
        };
        const source = self.allocator.dupe(u8, self.request.source) catch {
            application.deinit(self.allocator);
            return self.storeResult(.{ .failed = self.request.generation });
        };
        self.storeResult(.{ .success = .{
            .generation = self.request.generation,
            .source = source,
            .cursor = self.request.cursor,
            .application = application,
        } });
    }

    fn storeResult(self: *Worker, result: Result) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.result) |old| old.deinit(self.allocator);
        self.result = result;
    }

    pub fn takeResult(self: *Worker) ?Result {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const result = self.result;
        self.result = null;
        return result;
    }

    pub fn deinit(self: *Worker) void {
        if (self.result) |result| result.deinit(self.allocator);
        self.request.deinit(self.allocator);
        if (self.context) |context| if (self.free_context) |free| free(context, self.allocator);
        self.* = undefined;
    }
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    next_generation: u64 = 1,
    active: ?*Worker = null,
    queued: ?Request = null,
    debounce: ?Request = null,
    debounce_deadline_ms: ?u64 = null,
    progress_deadline_ms: ?u64 = null,
    progress_started: bool = false,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Controller) void {
        if (self.active) |worker| {
            worker.cancel.cancel();
            worker.thread.join();
            worker.deinit();
            self.allocator.destroy(worker);
        }
        if (self.queued) |*queued_request| queued_request.deinit(self.allocator);
        if (self.debounce) |*debounce_request| debounce_request.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn request(self: *Controller, io: std.Io, source: []const u8, cursor: usize, reason: RequestReason) !void {
        var next = try self.makeRequest(source, cursor, reason);
        errdefer next.deinit(self.allocator);
        if (self.active) |active_worker| active_worker.cancel.cancel();
        switch (reason) {
            .explicit => {
                if (self.queued) |*old| old.deinit(self.allocator);
                self.queued = next;
            },
            .refresh => {
                if (self.debounce) |*old| old.deinit(self.allocator);
                self.debounce = next;
                self.debounce_deadline_ms = nowMs(io) + debounce_ms;
            },
        }
    }

    pub fn takeReadyRequest(self: *Controller, io: std.Io) ?Request {
        if (self.active != null) return null;
        if (self.queued) |queued_request| {
            self.queued = null;
            return queued_request;
        }
        const deadline = self.debounce_deadline_ms orelse return null;
        if (nowMs(io) < deadline) return null;
        self.debounce_deadline_ms = null;
        const debounce_request = self.debounce orelse return null;
        self.debounce = null;
        return debounce_request;
    }

    pub fn debounceWaitMs(self: Controller, io: std.Io) ?u64 {
        const deadline = self.debounce_deadline_ms orelse return null;
        const now = nowMs(io);
        return if (deadline <= now) 0 else deadline - now;
    }

    pub fn progressWaitMs(self: Controller, io: std.Io) ?u64 {
        if (self.progress_started) return null;
        const deadline = self.progress_deadline_ms orelse return null;
        const now = nowMs(io);
        return if (deadline <= now) 0 else deadline - now;
    }

    pub fn hasSupersedingRequest(self: Controller, generation: u64) bool {
        if (self.queued) |queued_request| if (queued_request.generation > generation) return true;
        if (self.debounce) |debounce_request| if (debounce_request.generation > generation) return true;
        return false;
    }

    fn makeRequest(self: *Controller, source: []const u8, cursor: usize, reason: RequestReason) !Request {
        const generation = self.next_generation;
        self.next_generation += 1;
        return .{
            .generation = generation,
            .source = try self.allocator.dupe(u8, source),
            .cursor = cursor,
            .reason = reason,
        };
    }
};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch |err| log.debug("completion mutex yield failed: {}", .{err});
}

fn nowMs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

fn writeFdAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try writeFd(fd, remaining);
        remaining = remaining[written..];
    }
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .BADF => return error.BadFileDescriptor,
            .INTR => return writeFd(fd, bytes),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
}

test "completion controller debounces refresh requests to the latest input" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try controller.request(std.testing.io, "git c", 5, .refresh);
    try controller.request(std.testing.io, "git ch", 6, .refresh);

    try std.testing.expect(controller.debounce != null);
    try std.testing.expectEqualStrings("git ch", controller.debounce.?.source);
    try std.testing.expectEqual(@as(usize, 6), controller.debounce.?.cursor);
    try std.testing.expect(controller.debounceWaitMs(std.testing.io) != null);
}

test "completion controller cancels active worker when superseded" {
    var controller = Controller.init(std.testing.allocator);

    const active_worker = try std.testing.allocator.create(Worker);
    active_worker.* = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .complete = null,
        .free_context = null,
        .request = .{
            .generation = 1,
            .source = try std.testing.allocator.dupe(u8, "git c"),
            .cursor = 5,
            .reason = .explicit,
        },
        .context = null,
        .wake_fd = -1,
    };
    controller.active = active_worker;

    try controller.request(std.testing.io, "git ch", 6, .explicit);
    try std.testing.expect(active_worker.cancel.isCanceled());
    try std.testing.expect(controller.queued != null);
    try std.testing.expectEqualStrings("git ch", controller.queued.?.source);

    controller.active = null;
    active_worker.deinit();
    std.testing.allocator.destroy(active_worker);
    controller.deinit();
}

test "completion controller marks same-input active results stale when superseded" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    var first = try controller.makeRequest("git s", 5, .explicit);
    defer first.deinit(std.testing.allocator);
    try controller.request(std.testing.io, "git s", 5, .explicit);

    try std.testing.expect(controller.hasSupersedingRequest(first.generation));
    try std.testing.expect(!controller.hasSupersedingRequest(controller.queued.?.generation));
}
