//! Prompt rendering extension builtins.

const std = @import("std");
const builtin = @import("builtin");

const editor_signal = @import("../../editor/signal.zig");
const editor_render = @import("../../editor/render.zig");
const api = @import("../api.zig");
const compat = @import("../../shell/compat.zig");
const shell_context = @import("../../shell/context.zig");
const delta = @import("../../shell/delta.zig");
const shell_builtin = @import("../../shell/builtin.zig");
const state = @import("../../shell/state.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("prompt", .extension_state),
    shell_builtin.Builtin.initExtension("prompt_pwd", .output),
    shell_builtin.Builtin.initExtension("prompt_duration", .output),
    shell_builtin.Builtin.initExtension("prompt_async", .extension_state),
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    previous_duration_ms: ?i64 = null,
    async_state: ?*AsyncState = null,
    async_refresh_started: bool = false,
    io: ?std.Io = null,
    now_ms: u64 = 0,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn toOwnedSlice(self: *Builder) ![]u8 {
        const output = try self.bytes.toOwnedSlice(self.allocator);
        self.bytes = .empty;
        return output;
    }
};

const use_debug_allocator = builtin.mode == .Debug;
const AsyncDebugAllocator = if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void;

pub const AsyncState = struct {
    debug_allocator: AsyncDebugAllocator = if (use_debug_allocator) .init else {},
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    redraw_fd: ?std.posix.fd_t = null,
    task_scheduler: ?api.AsyncTaskScheduler = null,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(*AsyncEntry) = .empty,
    active_refresh_count: usize = 0,
    pending_start_events: usize = 0,
    pending_end_events: usize = 0,

    pub fn init(self: *AsyncState, io: std.Io, redraw_fd: ?std.posix.fd_t) void {
        self.* = .{};
        self.io = io;
        self.redraw_fd = redraw_fd;
        self.allocator = std.heap.smp_allocator;
    }

    pub fn deinit(self: *AsyncState) void {
        for (self.entries.items) |entry| {
            if (entry.task) |task| task.join();
            self.allocator.free(entry.key);
            self.allocator.free(entry.cwd);
            self.allocator.free(entry.stdout);
            entry.sink.release();
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        if (use_debug_allocator) std.debug.assert(self.debug_allocator.deinit() == .ok);
        self.* = undefined;
    }

    pub fn deinitAbandoningTasks(self: *AsyncState) void {
        for (self.entries.items) |entry| entry.sink.close();

        for (self.entries.items) |entry| {
            if (entry.task) |task| task.abandon();
            self.allocator.free(entry.key);
            self.allocator.free(entry.cwd);
            self.allocator.free(entry.stdout);
            entry.sink.release();
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        if (use_debug_allocator) std.debug.assert(self.debug_allocator.deinit() == .ok);
        self.* = undefined;
    }

    pub fn hasPending(self: *AsyncState) bool {
        self.lock();
        defer self.unlock();
        for (self.entries.items) |entry| if (entry.refreshing or entry.completed) return true;
        return false;
    }

    pub fn hasRefreshing(self: *AsyncState) bool {
        self.lock();
        defer self.unlock();
        for (self.entries.items) |entry| if (entry.refreshing) return true;
        return false;
    }

    pub fn takeCompleted(self: *AsyncState) bool {
        self.lock();
        defer self.unlock();
        var completed = false;
        for (self.entries.items) |entry| {
            if (entry.completed) {
                entry.completed = false;
                completed = true;
            }
        }
        return completed;
    }

    pub const LifecycleEvents = struct {
        start_count: usize = 0,
        end_count: usize = 0,
    };

    pub fn takeLifecycleEvents(self: *AsyncState) LifecycleEvents {
        self.lock();
        defer self.unlock();
        const events: LifecycleEvents = .{
            .start_count = self.pending_start_events,
            .end_count = self.pending_end_events,
        };
        self.pending_start_events = 0;
        self.pending_end_events = 0;
        return events;
    }

    fn noteRefreshStartedLocked(self: *AsyncState) void {
        if (self.active_refresh_count == 0) self.pending_start_events += 1;
        self.active_refresh_count += 1;
    }

    fn noteRefreshEndedLocked(self: *AsyncState) void {
        std.debug.assert(self.active_refresh_count != 0);
        self.active_refresh_count -= 1;
        if (self.active_refresh_count == 0) self.pending_end_events += 1;
    }

    fn lock(self: *AsyncState) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *AsyncState) void {
        self.mutex.unlock(self.io);
    }

    fn requestRedraw(self: AsyncState) void {
        const fd = self.redraw_fd orelse return;
        // ziglint-ignore: Z026 best-effort wakeup; the next input event can redraw
        editor_signal.rawWriteAll(fd, "p") catch {};
    }
};

const AsyncEntry = struct {
    state: *AsyncState,
    sink: *AsyncCompletionSink,
    key: []const u8,
    cwd: []const u8,
    stdout: []const u8,
    updated_ms: u64 = 0,
    refreshing: bool = false,
    completed: bool = false,
    task: ?api.AsyncTask = null,
};

const AsyncCompletionSink = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,
    state: *AsyncState,
    entry: *AsyncEntry,

    fn create(allocator: std.mem.Allocator, state_value: *AsyncState, entry: *AsyncEntry) !*AsyncCompletionSink {
        const sink = try allocator.create(AsyncCompletionSink);
        sink.* = .{
            .allocator = allocator,
            .io = state_value.io,
            .state = state_value,
            .entry = entry,
        };
        return sink;
    }

    fn retain(self: *AsyncCompletionSink) void {
        const previous = self.refs.fetchAdd(1, .acq_rel);
        std.debug.assert(previous != 0);
    }

    fn release(self: *AsyncCompletionSink) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous == 1) self.allocator.destroy(self);
    }

    fn close(self: *AsyncCompletionSink) void {
        self.lock();
        defer self.unlock();
        self.closed = true;
    }

    fn lock(self: *AsyncCompletionSink) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *AsyncCompletionSink) void {
        self.mutex.unlock(self.io);
    }
};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    return handlerForContext(name, null);
}

pub fn handlerForContext(name: []const u8, handler_context: ?*anyopaque) ?api.HandlerSpec {
    if (std.mem.eql(u8, name, "prompt")) return .{ .context = handler_context, .handler = evaluatePrompt };
    if (std.mem.eql(u8, name, "prompt_pwd")) return .{ .handler = evaluatePromptPwd };
    if (std.mem.eql(u8, name, "prompt_duration")) return .{
        .context = handler_context,
        .handler = evaluatePromptDuration,
    };
    if (std.mem.eql(u8, name, "prompt_async")) return .{
        .context = handler_context,
        .handler = evaluatePromptAsync,
    };
    return null;
}

fn evaluatePrompt(handler_context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "prompt"));
    const builder: *Builder = if (handler_context) |ctx| @ptrCast(@alignCast(ctx)) else {
        return api.EvaluationResult.normal(try invocation.usageError(
            "prompt",
            "only available while rendering prompt",
        ));
    };

    if (invocation.argv.len < 2) return api.EvaluationResult.normal(try promptUsage(invocation));
    if (std.mem.eql(u8, invocation.argv[1], "text")) return evaluatePromptText(builder, invocation);
    if (std.mem.eql(u8, invocation.argv[1], "segment")) return evaluatePromptSegment(builder, invocation);
    if (std.mem.eql(u8, invocation.argv[1], "newline")) return evaluatePromptNewline(builder, invocation);
    if (std.mem.eql(u8, invocation.argv[1], "async-pending")) return evaluatePromptAsyncPending(builder, invocation);
    return api.EvaluationResult.normal(try invocation.usageError("prompt", "unsupported command"));
}

fn evaluatePromptText(builder: *Builder, invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len < 3) return api.EvaluationResult.normal(try promptUsage(invocation));
    try appendPromptText(builder, invocation.argv[2..]);
    return api.EvaluationResult.normal(0);
}

fn evaluatePromptSegment(builder: *Builder, invocation: *api.Invocation) !api.EvaluationResult {
    var style: editor_render.UiStyle = .{};
    var index: usize = 2;
    while (index < invocation.argv.len) {
        const option = invocation.argv[index];
        if (!std.mem.startsWith(u8, option, "--")) break;
        index += 1;
        if (std.mem.eql(u8, option, "--fg") or std.mem.eql(u8, option, "--bg")) {
            if (index >= invocation.argv.len) return api.EvaluationResult.normal(try promptUsage(invocation));
            const color = editor_render.parseUiColor(invocation.argv[index]) orelse {
                return api.EvaluationResult.normal(try invocation.usageError("prompt", "invalid color"));
            };
            if (std.mem.eql(u8, option, "--fg")) style.fg = color else style.bg = color;
            index += 1;
        } else if (std.mem.eql(u8, option, "--bold")) {
            style.bold = true;
        } else if (std.mem.eql(u8, option, "--dim")) {
            style.dim = true;
        } else if (std.mem.eql(u8, option, "--italic")) {
            style.italic = true;
        } else if (std.mem.eql(u8, option, "--underline")) {
            style.ul = .single;
        } else if (std.mem.eql(u8, option, "--reverse")) {
            style.reverse = true;
        } else if (std.mem.eql(u8, option, "--strikethrough")) {
            style.strike = true;
        } else return api.EvaluationResult.normal(try invocation.usageError("prompt", "unsupported option"));
    }
    if (index >= invocation.argv.len) return api.EvaluationResult.normal(try promptUsage(invocation));

    try editor_render.appendUiStyleStart(builder.allocator, &builder.bytes, style);
    try appendPromptText(builder, invocation.argv[index..]);
    try editor_render.appendUiStyleEnd(builder.allocator, &builder.bytes, style);
    return api.EvaluationResult.normal(0);
}

fn evaluatePromptNewline(builder: *Builder, invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len != 2) return api.EvaluationResult.normal(try promptUsage(invocation));
    try builder.bytes.append(builder.allocator, '\n');
    return api.EvaluationResult.normal(0);
}

fn evaluatePromptAsyncPending(builder: *Builder, invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len != 2) return api.EvaluationResult.normal(try promptUsage(invocation));
    if (builder.async_refresh_started) return api.EvaluationResult.normal(0);
    const async_state = builder.async_state orelse return api.EvaluationResult.normal(1);
    return api.EvaluationResult.normal(if (async_state.hasRefreshing()) 0 else 1);
}

fn appendPromptText(builder: *Builder, args: []const []const u8) !void {
    for (args, 0..) |arg, index| {
        if (index != 0) try builder.bytes.append(builder.allocator, ' ');
        try builder.bytes.appendSlice(builder.allocator, arg);
    }
}

fn evaluatePromptPwd(handler_context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = handler_context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "prompt_pwd"));

    const options = parsePromptPwdOptions(invocation.argv) orelse {
        return api.EvaluationResult.normal(try invocation.usageError("prompt_pwd", "unsupported option"));
    };
    const cwd = promptCwd(invocation);
    const home = if (invocation.shell_state.getVariable("HOME")) |variable| variable.value else null;
    const display = try formatPromptPwd(invocation.allocator, cwd, home, options);
    defer invocation.allocator.free(display);
    try invocation.stdout.print(invocation.allocator, "{s}\n", .{display});
    return api.EvaluationResult.normal(0);
}

const PromptPwdOptions = struct {
    dir_length: usize = 0,
    full_length_dirs: usize = 1,
};

fn parsePromptPwdOptions(argv: []const []const u8) ?PromptPwdOptions {
    var options: PromptPwdOptions = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const option = argv[index];
        if (std.mem.eql(u8, option, "-d") or std.mem.eql(u8, option, "--dir-length")) {
            index += 1;
            if (index >= argv.len) return null;
            options.dir_length = std.fmt.parseInt(usize, argv[index], 10) catch return null;
        } else if (std.mem.eql(u8, option, "-D") or std.mem.eql(u8, option, "--full-length-dirs")) {
            index += 1;
            if (index >= argv.len) return null;
            options.full_length_dirs = std.fmt.parseInt(usize, argv[index], 10) catch return null;
        } else return null;
    }
    return options;
}

fn promptCwd(invocation: *api.Invocation) []const u8 {
    if (invocation.shell_state.logical_cwd.len != 0) return invocation.shell_state.logical_cwd;
    if (invocation.shell_state.getVariable("PWD")) |variable| if (variable.value.len != 0) return variable.value;
    return ".";
}

fn formatPromptPwd(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home: ?[]const u8,
    options: PromptPwdOptions,
) ![]const u8 {
    const home_replaced = try replaceHome(allocator, cwd, home);
    defer if (home_replaced.owned) allocator.free(home_replaced.text);
    if (options.dir_length == 0) return allocator.dupe(u8, home_replaced.text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var parts = std.mem.splitScalar(u8, home_replaced.text, '/');
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);
    while (parts.next()) |part| try components.append(allocator, part);

    for (components.items, 0..) |component, index| {
        if (index != 0) try out.append(allocator, '/');
        if (component.len == 0 or component.len == 1 or components.items.len - index <= options.full_length_dirs) {
            try out.appendSlice(allocator, component);
        } else {
            try appendShortComponent(allocator, &out, component, options.dir_length);
        }
    }
    return out.toOwnedSlice(allocator);
}

const ReplacedHome = struct {
    text: []const u8,
    owned: bool = false,
};

fn replaceHome(allocator: std.mem.Allocator, cwd: []const u8, home: ?[]const u8) !ReplacedHome {
    const home_value = home orelse return .{ .text = cwd };
    if (home_value.len == 0) return .{ .text = cwd };
    if (std.mem.eql(u8, cwd, home_value)) return .{ .text = "~" };
    if (std.mem.startsWith(u8, cwd, home_value) and cwd.len > home_value.len and cwd[home_value.len] == '/') {
        return .{ .text = try std.mem.concat(allocator, u8, &.{ "~", cwd[home_value.len..] }), .owned = true };
    }
    return .{ .text = cwd };
}

fn appendShortComponent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    component: []const u8,
    length: usize,
) !void {
    if (length == 0 or component.len <= length) return out.appendSlice(allocator, component);
    if (component[0] == '.' and component.len > 1) {
        try out.append(allocator, '.');
        try out.appendSlice(allocator, component[1..@min(component.len, 1 + length)]);
        return;
    }
    try out.appendSlice(allocator, component[0..length]);
}

fn evaluatePromptDuration(handler_context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "prompt_duration"));
    if (invocation.argv.len != 1) return api.EvaluationResult.normal(try invocation.usageError(
        "prompt_duration",
        "too many arguments",
    ));
    const builder: *Builder = if (handler_context) |ctx| @ptrCast(@alignCast(ctx)) else {
        return api.EvaluationResult.normal(try invocation.usageError(
            "prompt_duration",
            "only available while rendering prompt",
        ));
    };
    const duration_ms = builder.previous_duration_ms orelse return api.EvaluationResult.normal(1);
    try invocation.stdout.print(invocation.allocator, "{d}ms\n", .{duration_ms});
    return api.EvaluationResult.normal(0);
}

fn evaluatePromptAsync(handler_context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "prompt_async"));
    const builder: *Builder = if (handler_context) |ctx| @ptrCast(@alignCast(ctx)) else {
        return api.EvaluationResult.normal(try invocation.usageError(
            "prompt_async",
            "only available while rendering prompt",
        ));
    };
    const async_state = builder.async_state orelse return api.EvaluationResult.normal(0);
    const io = builder.io orelse return api.EvaluationResult.normal(0);

    const parsed = parsePromptAsync(invocation.argv) orelse {
        return api.EvaluationResult.normal(try promptAsyncUsage(invocation));
    };
    const cwd = promptCwd(invocation);
    const entry = try asyncEntry(async_state, parsed.key, cwd);

    async_state.lock();
    const cached_stdout = try invocation.allocator.dupe(u8, entry.stdout);
    const should_refresh = !entry.refreshing and
        (entry.updated_ms == 0 or builder.now_ms >= entry.updated_ms + parsed.ttl_ms);
    if (should_refresh) {
        entry.refreshing = true;
        async_state.noteRefreshStartedLocked();
        builder.async_refresh_started = true;
    }
    async_state.unlock();
    defer invocation.allocator.free(cached_stdout);

    try invocation.stdout.appendSlice(invocation.allocator, cached_stdout);
    if (should_refresh) startPromptAsyncRefresh(
        async_state,
        io,
        entry,
        parsed.command,
        builder,
        invocation,
    ) catch |err| {
        async_state.lock();
        entry.refreshing = false;
        async_state.noteRefreshEndedLocked();
        async_state.unlock();
        if (err == error.OutOfMemory) return error.OutOfMemory;
    };
    return api.EvaluationResult.normal(0);
}

const PromptAsyncOptions = struct {
    key: []const u8,
    ttl_ms: u64,
    command: []const []const u8,
};

fn parsePromptAsync(argv: []const []const u8) ?PromptAsyncOptions {
    if (argv.len < 6) return null;
    var options: PromptAsyncOptions = .{ .key = argv[1], .ttl_ms = 0, .command = &.{} };
    var index: usize = 2;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            if (index >= argv.len) return null;
            options.command = argv[index..];
            return options;
        }
        if (std.mem.eql(u8, arg, "--ttl")) {
            index += 1;
            if (index >= argv.len) return null;
            options.ttl_ms = std.fmt.parseInt(u64, argv[index], 10) catch return null;
            index += 1;
            continue;
        }
        return null;
    }
    return null;
}

fn asyncEntry(async_state: *AsyncState, key: []const u8, cwd: []const u8) !*AsyncEntry {
    async_state.lock();
    defer async_state.unlock();
    for (async_state.entries.items) |entry| {
        if (std.mem.eql(u8, entry.key, key) and std.mem.eql(u8, entry.cwd, cwd)) return entry;
    }
    const entry = try async_state.allocator.create(AsyncEntry);
    errdefer async_state.allocator.destroy(entry);
    const sink = try AsyncCompletionSink.create(async_state.allocator, async_state, entry);
    errdefer sink.release();
    entry.* = .{
        .state = async_state,
        .sink = sink,
        .key = try async_state.allocator.dupe(u8, key),
        .cwd = try async_state.allocator.dupe(u8, cwd),
        .stdout = try async_state.allocator.dupe(u8, ""),
    };
    errdefer async_state.allocator.free(entry.key);
    errdefer async_state.allocator.free(entry.cwd);
    errdefer async_state.allocator.free(entry.stdout);
    try async_state.entries.append(async_state.allocator, entry);
    return entry;
}

fn startPromptAsyncRefresh(
    async_state: *AsyncState,
    io: std.Io,
    entry: *AsyncEntry,
    command: []const []const u8,
    builder: *Builder,
    invocation: *api.Invocation,
) !void {
    const task_scheduler = async_state.task_scheduler orelse return;
    if (entry.task) |task| task.join();
    entry.task = null;

    entry.sink.retain();
    errdefer entry.sink.release();
    entry.task = try task_scheduler.schedule(async_state.allocator, io, .{
        .shell_state = invocation.shell_state,
        .argv = command,
        .arg_zero = builder.arg_zero,
        .features = builder.features,
        .complete_context = entry.sink,
        .complete = finishPromptAsyncRefresh,
    });
}

fn finishPromptAsyncRefresh(context: ?*anyopaque, result: api.AsyncTaskResult) void {
    const sink: *AsyncCompletionSink = @ptrCast(@alignCast(context.?));
    defer sink.release();
    sink.lock();
    defer sink.unlock();
    if (sink.closed) return;

    const async_state = sink.state;
    const stdout = async_state.allocator.dupe(u8, result.stdout) catch {
        async_state.lock();
        const entry = sink.entry;
        entry.refreshing = false;
        async_state.noteRefreshEndedLocked();
        entry.completed = true;
        async_state.requestRedraw();
        async_state.unlock();
        return;
    };
    errdefer async_state.allocator.free(stdout);
    async_state.lock();
    const entry = sink.entry;
    async_state.allocator.free(entry.stdout);
    entry.stdout = stdout;
    entry.updated_ms = nowMillis(async_state.io);
    entry.refreshing = false;
    async_state.noteRefreshEndedLocked();
    entry.completed = true;
    async_state.requestRedraw();
    async_state.unlock();
}

fn nowMillis(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

fn promptAsyncUsage(invocation: *api.Invocation) !u8 {
    return invocation.usageError(
        "prompt_async",
        "usage: prompt_async KEY --ttl MS -- COMMAND...",
    );
}

fn promptUsage(invocation: *api.Invocation) !u8 {
    return invocation.usageError(
        "prompt",
        "usage: prompt text TEXT... | prompt segment [OPTIONS] TEXT... | prompt newline | prompt async-pending",
    );
}

test "prompt builder appends styled segments through userdata" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var state_delta = delta.StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "prompt", "segment", "--fg", "blue", "rush" },
        .builtins = &.{},
        .shell_state = shell_state,
        .state_delta = &state_delta,
        .eval_context = shell_context.EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };

    const result = try evaluatePrompt(&builder, &invocation);
    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("\x1b[38;5;4mrush\x1b[39m", builder.bytes.items);
}

test "prompt async-pending reports refresh started during render" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var state_delta = delta.StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "prompt", "async-pending" },
        .builtins = &.{},
        .shell_state = shell_state,
        .state_delta = &state_delta,
        .eval_context = shell_context.EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };

    try std.testing.expectEqual(@as(u8, 1), (try evaluatePrompt(&builder, &invocation)).status);
    builder.async_refresh_started = true;
    try std.testing.expectEqual(@as(u8, 0), (try evaluatePrompt(&builder, &invocation)).status);
}

test "prompt_pwd shortens home-relative paths" {
    const display = try formatPromptPwd(
        std.testing.allocator,
        "/home/me/repos/rush",
        "/home/me",
        .{ .dir_length = 1, .full_length_dirs = 1 },
    );
    defer std.testing.allocator.free(display);
    try std.testing.expectEqualStrings("~/r/rush", display);
}
