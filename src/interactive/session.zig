//! Interactive shell session orchestration.

const std = @import("std");

const compat = @import("../shell/compat.zig");
const completion = @import("../completion.zig");
const editor_completion = @import("../editor/completion.zig");
const editor_driver = @import("../editor.zig").driver;
const editor_render = @import("../editor/render.zig");
const extension_abbr = @import("../extensions/editor/abbr.zig");
const extension_api = @import("../extensions/api.zig");
const extension_handlers = @import("../extensions/handlers.zig");
const history = @import("../history.zig");
const runner = @import("../runner.zig");
const runtime = @import("../runtime.zig");
const shell = @import("../shell.zig");

const assets = @import("../assets.zig");
const interactive_input = @import("input.zig");
const prompt_mod = @import("prompt.zig");
const signals = @import("signals.zig");
const startup = @import("startup.zig");

const omitted_newline_marker = "\x1b[2m⏎\x1b[22m\r\n";
const ignoreeof_message = "Use \"exit\" to leave the shell.\r\n";
const stopped_jobs_exit_warning = "You have stopped jobs.\n";
pub const immediate_notify_poll_ms = 50;

const OutputStream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: OutputStream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn monotonicTimestamp(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn monotonicMillis(io: std.Io) u64 {
    return @intCast(monotonicTimestamp(io).raw.toMilliseconds());
}

fn durationMillis(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) i64 {
    return @max(start.durationTo(end).raw.toMilliseconds(), 0);
}

pub const Context = struct {
    semantic_state: *shell.ShellState,
    editor_state: *EditorState,
    arg_zero: []const u8 = "rush",
    cloned_arg_zero: ?[]const u8 = null,
    features: compat.Features = .{},
    previous_status: shell.ExitStatus = 0,
    previous_duration_ms: ?i64 = null,
    prompt_async_state: ?*prompt_mod.AsyncState = null,
    active_background_job_count: ?*usize = null,
};

pub const EditorState = struct {
    abbreviations: extension_abbr.State,
    completions: completion.State,

    pub fn init(allocator: std.mem.Allocator) EditorState {
        return .{
            .abbreviations = extension_abbr.State.init(allocator),
            .completions = completion.State.init(allocator),
        };
    }

    pub fn deinit(self: *EditorState) void {
        self.abbreviations.deinit();
        self.completions.deinit();
        self.* = undefined;
    }
};

fn interactiveExtensionHandlers(context: *Context) runner.ExtensionHandlers {
    return .{
        .context = context,
        .lookup = interactiveExtensionLookup,
    };
}

fn interactiveExtensionLookup(context: ?*anyopaque, name: []const u8) ?extension_api.HandlerSpec {
    const interactive_context: *Context = @ptrCast(@alignCast(context.?));
    if (extension_abbr.handlerForContext(
        name,
        &interactive_context.editor_state.abbreviations,
    )) |handler| return handler;
    return extension_handlers.lookup(name);
}

fn runInteractiveEventHooks(
    context: *Context,
    allocator: std.mem.Allocator,
    io: std.Io,
    event_name: shell.EventName,
    args: []const []const u8,
) !void {
    context.semantic_state.validate();
    const calls = try shell.event.orderedHookCalls(allocator, context.semantic_state.event_hooks.items, event_name);
    defer shell.event.freeHookCalls(allocator, calls);
    if (calls.len == 0) return;

    const visible_status = context.semantic_state.last_status;
    const visible_pipeline_statuses = try allocator.dupe(
        shell.ExitStatus,
        context.semantic_state.last_pipeline_statuses.items,
    );
    defer allocator.free(visible_pipeline_statuses);
    errdefer context.semantic_state.last_status = visible_status;
    for (calls) |call| {
        try restoreInteractiveEventVisibleStatus(context.semantic_state, visible_status, visible_pipeline_statuses);
        if (context.semantic_state.getFunction(call.function_name) == null) {
            try writeAll(io, .stderr, "event: ");
            try writeAll(io, .stderr, call.function_name);
            try writeAll(io, .stderr, ": function not found\n");
            continue;
        }

        var argv = try allocator.alloc([]const u8, args.len + 1);
        defer allocator.free(argv);
        argv[0] = call.function_name;
        for (args, 0..) |arg, index| argv[index + 1] = arg;

        const assignments = interactiveEventHookContextAssignments(event_name, call);
        var result = try runner.runHiddenShellStateCommandWithExtensionHandlersApplyOptionsAndAssignments(
            allocator,
            io,
            context.semantic_state,
            argv,
            &assignments,
            context.arg_zero,
            context.features,
            .capture,
            interactiveExtensionHandlers(context),
            .{ .record_exit_control_flow = true },
            1,
        );
        defer result.deinit();
        try writeAll(io, .stdout, result.stdout);
        try writeAll(io, .stderr, result.stderr);
        try restoreInteractiveEventVisibleStatus(context.semantic_state, visible_status, visible_pipeline_statuses);
        if (context.semantic_state.pending_exit != null) break;
    }
    try restoreInteractiveEventVisibleStatus(context.semantic_state, visible_status, visible_pipeline_statuses);
}

fn restoreInteractiveEventVisibleStatus(
    shell_state: *shell.ShellState,
    visible_status: shell.ExitStatus,
    visible_pipeline_statuses: []const shell.ExitStatus,
) !void {
    shell_state.last_status = visible_status;
    try shell_state.setLastPipelineStatuses(visible_pipeline_statuses);
}

fn interactiveEventHookContextAssignments(
    event_name: shell.EventName,
    call: shell.event.HookCall,
) [2]shell.command_plan.Assignment {
    return .{
        .{ .name = "RUSH_EVENT", .value = event_name.text() },
        .{ .name = "RUSH_EVENT_HOOK", .value = call.name },
    };
}

fn runInteractiveTimerHooks(
    context: *Context,
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
) !bool {
    context.semantic_state.validate();
    const calls = try shell.event.dueTimerHookCalls(
        allocator,
        context.semantic_state.event_hooks.items,
        monotonicMillis(io),
    );
    defer shell.event.freeHookCalls(allocator, calls);
    if (calls.len == 0) return false;

    const visible_status = context.semantic_state.last_status;
    const visible_pipeline_statuses = try allocator.dupe(
        shell.ExitStatus,
        context.semantic_state.last_pipeline_statuses.items,
    );
    defer allocator.free(visible_pipeline_statuses);
    errdefer context.semantic_state.last_status = visible_status;
    for (calls) |call| {
        try restoreInteractiveEventVisibleStatus(context.semantic_state, visible_status, visible_pipeline_statuses);
        if (context.semantic_state.getFunction(call.function_name) == null) {
            const message = try std.fmt.allocPrint(
                allocator,
                "event: {s}: function not found\n",
                .{call.function_name},
            );
            defer allocator.free(message);
            try output.appendSlice(allocator, message);
            continue;
        }

        const assignments = interactiveEventHookContextAssignments(.timer_tick, call);
        var result = try runner.runHiddenShellStateCommandWithExtensionHandlersApplyOptionsAndAssignments(
            allocator,
            io,
            context.semantic_state,
            &.{ call.function_name, call.name },
            &assignments,
            context.arg_zero,
            context.features,
            .capture,
            interactiveExtensionHandlers(context),
            .{ .record_exit_control_flow = true },
            1,
        );
        defer result.deinit();
        try output.appendSlice(allocator, result.stdout);
        try output.appendSlice(allocator, result.stderr);
        try restoreInteractiveEventVisibleStatus(context.semantic_state, visible_status, visible_pipeline_statuses);
        if (context.semantic_state.pending_exit != null) break;
    }
    try restoreInteractiveEventVisibleStatus(context.semantic_state, visible_status, visible_pipeline_statuses);
    return true;
}

pub fn runInteractiveIntervalHooks(
    context: *anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (run_hooks callback ABI).
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 - opaque context must come first (run_hooks callback ABI).
    io: std.Io,
) !editor_driver.HookResult {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var should_refresh_prompt = false;

    const semantic_state = interactive_context.semantic_state;
    if (try executeInteractivePendingTraps(
        allocator,
        io,
        semantic_state,
        interactive_context.arg_zero,
        interactive_context.features,
    )) |trap_result| {
        var result = trap_result;
        defer result.deinit();
        try output.appendSlice(allocator, result.stdout);
        try output.appendSlice(allocator, result.stderr);
        should_refresh_prompt = true;
    }

    try refreshInteractiveSemanticJobs(allocator, io, semantic_state);
    if (interactive_context.active_background_job_count) |active_count| {
        if (try dispatchBackgroundJobLifecycleActivityEvents(
            interactive_context,
            allocator,
            io,
            active_count,
            &output,
        )) {
            should_refresh_prompt = true;
        }
    }

    if (semantic_state.options.notify) {
        const notifications = try drainInteractiveSemanticJobNotifications(allocator, io, semantic_state);
        defer allocator.free(notifications);
        try output.appendSlice(allocator, notifications);
    }

    if (try runInteractiveTimerHooks(interactive_context, allocator, io, &output)) {
        should_refresh_prompt = true;
    }
    if (try dispatchPromptAsyncLifecycleEvents(interactive_context, allocator, io)) {
        should_refresh_prompt = true;
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = should_refresh_prompt,
        .stop = semantic_state.pending_exit != null,
    };
}

pub fn runInteractiveActivityEvent(
    context: *anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (run_activity_event callback ABI).
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 - opaque context must come first (run_activity_event callback ABI).
    io: std.Io,
    event_name_text: []const u8,
    args: []const []const u8,
) !editor_driver.HookResult {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    const event_name = shell.EventName.parse(event_name_text) orelse return .{
        .output = try allocator.dupe(u8, ""),
        .refresh_prompt = false,
    };
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const calls = try shell.event.orderedHookCalls(
        allocator,
        interactive_context.semantic_state.event_hooks.items,
        event_name,
    );
    defer shell.event.freeHookCalls(allocator, calls);
    if (calls.len == 0) return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = false,
    };

    const visible_status = interactive_context.semantic_state.last_status;
    const visible_pipeline_statuses = try allocator.dupe(
        shell.ExitStatus,
        interactive_context.semantic_state.last_pipeline_statuses.items,
    );
    defer allocator.free(visible_pipeline_statuses);
    errdefer interactive_context.semantic_state.last_status = visible_status;
    for (calls) |call| {
        try restoreInteractiveEventVisibleStatus(
            interactive_context.semantic_state,
            visible_status,
            visible_pipeline_statuses,
        );
        if (interactive_context.semantic_state.getFunction(call.function_name) == null) {
            const message = try std.fmt.allocPrint(
                allocator,
                "event: {s}: function not found\n",
                .{call.function_name},
            );
            defer allocator.free(message);
            try output.appendSlice(allocator, message);
            continue;
        }
        var argv = try allocator.alloc([]const u8, args.len + 1);
        defer allocator.free(argv);
        argv[0] = call.function_name;
        for (args, 0..) |arg, index| argv[index + 1] = arg;

        const assignments = interactiveEventHookContextAssignments(event_name, call);
        var result = try runner.runHiddenShellStateCommandWithExtensionHandlersApplyOptionsAndAssignments(
            allocator,
            io,
            interactive_context.semantic_state,
            argv,
            &assignments,
            interactive_context.arg_zero,
            interactive_context.features,
            .capture,
            interactiveExtensionHandlers(interactive_context),
            .{ .record_exit_control_flow = true },
            1,
        );
        defer result.deinit();
        try output.appendSlice(allocator, result.stdout);
        try output.appendSlice(allocator, result.stderr);
        try restoreInteractiveEventVisibleStatus(
            interactive_context.semantic_state,
            visible_status,
            visible_pipeline_statuses,
        );
        if (interactive_context.semantic_state.pending_exit != null) break;
    }
    try restoreInteractiveEventVisibleStatus(
        interactive_context.semantic_state,
        visible_status,
        visible_pipeline_statuses,
    );
    return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = true,
        .stop = interactive_context.semantic_state.pending_exit != null,
    };
}

// ziglint-ignore: Z023 - signature is fixed by the next_hook_interval_ms
// callback pointer type; the opaque context must come first.
pub fn nextInteractiveIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    var next_ms = shell.event.nextTimerDelayMs(
        interactive_context.semantic_state.event_hooks.items,
        monotonicMillis(io),
    );
    if (shellStateWantsImmediateJobNotificationPoll(interactive_context.semantic_state)) {
        if (next_ms == null or immediate_notify_poll_ms < next_ms.?) next_ms = immediate_notify_poll_ms;
    }
    return next_ms;
}

fn dispatchPromptAsyncLifecycleEvents(
    context: *Context,
    allocator: std.mem.Allocator,
    io: std.Io,
) !bool {
    const async_state = context.prompt_async_state orelse return false;
    const events = async_state.takeLifecycleEvents();
    var dispatched = false;
    for (0..events.start_count) |_| {
        try runInteractiveEventHooks(context, allocator, io, .prompt_async_start, &.{ "prompt", "1" });
        dispatched = true;
    }
    for (0..events.end_count) |_| {
        try runInteractiveEventHooks(context, allocator, io, .prompt_async_end, &.{ "prompt", "0" });
        dispatched = true;
    }
    return dispatched;
}

// ziglint-ignore: Z023 - signature is fixed by the refresh_prompt callback pointer type.
fn refreshInteractivePrompt(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    _ = try dispatchPromptAsyncLifecycleEvents(interactive_context, allocator, io);
    const prompt = try prompt_mod.render(allocator, io, interactive_context.semantic_state, .{
        .arg_zero = interactive_context.arg_zero,
        .features = interactive_context.features,
        .previous_status = interactive_context.previous_status,
        .previous_duration_ms = interactive_context.previous_duration_ms,
        .async_state = interactive_context.prompt_async_state,
    });
    errdefer allocator.free(prompt);
    _ = try dispatchPromptAsyncLifecycleEvents(interactive_context, allocator, io);
    return prompt;
}

// ziglint-ignore: Z023 - signature is fixed by the expand_abbreviation callback pointer type.
fn expandInteractiveAbbreviation(
    context: *anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (expand_abbreviation callback ABI).
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    append_space: bool,
) !?editor_completion.Edit {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    return extension_abbr.expand(
        &interactive_context.editor_state.abbreviations,
        allocator,
        source,
        cursor,
        interactive_context.features,
        append_space,
    );
}

// ziglint-ignore: Z023 - signature is fixed by the complete callback pointer type.
fn completeInteractiveDefault(
    context: *anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (complete callback ABI).
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 - complete callback ABI orders allocator before io.
    io: std.Io,
    source: []const u8,
    cursor: usize,
) !editor_completion.Application {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    try loadInteractiveCompletionAssets(allocator, io, interactive_context, source, cursor);
    const manifest_application = try completion.manifestApplication(
        allocator,
        io,
        &interactive_context.editor_state.completions,
        interactive_context.semantic_state.*,
        source,
        cursor,
    );
    switch (manifest_application) {
        .none => {},
        .edit, .ambiguous => return manifest_application,
    }
    return completion.defaultApplication(allocator, io, interactive_context.semantic_state.*, source, cursor);
}

// ziglint-ignore: Z023 - signature is fixed by the clone_completion_context callback pointer type.
fn cloneInteractiveCompletionContext(
    context: *anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (clone_completion_context callback ABI).
    allocator: std.mem.Allocator,
    cancel: *editor_completion.CancellationToken,
) !*anyopaque {
    _ = cancel;
    const source: *Context = @ptrCast(@alignCast(context));
    const shell_state = try allocator.create(shell.ShellState);
    errdefer allocator.destroy(shell_state);
    shell_state.* = source.semantic_state.clone(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    errdefer shell_state.deinit();

    const editor_state = try allocator.create(EditorState);
    errdefer allocator.destroy(editor_state);
    editor_state.* = EditorState.init(allocator);
    errdefer editor_state.deinit();
    try copyEditorState(editor_state, source.editor_state);

    const arg_zero = try allocator.dupe(u8, source.arg_zero);
    errdefer allocator.free(arg_zero);
    const cloned = try allocator.create(Context);
    cloned.* = .{
        .semantic_state = shell_state,
        .editor_state = editor_state,
        .arg_zero = arg_zero,
        .cloned_arg_zero = arg_zero,
        .features = source.features,
        .previous_duration_ms = source.previous_duration_ms,
        .prompt_async_state = null,
    };
    return cloned;
}

// ziglint-ignore: Z023 - signature is fixed by the free_completion_context callback pointer type.
fn freeInteractiveCompletionContext(context: *anyopaque, allocator: std.mem.Allocator) void {
    const cloned: *Context = @ptrCast(@alignCast(context));
    if (cloned.cloned_arg_zero) |arg_zero| allocator.free(arg_zero);
    cloned.semantic_state.deinit();
    allocator.destroy(cloned.semantic_state);
    cloned.editor_state.deinit();
    allocator.destroy(cloned.editor_state);
    allocator.destroy(cloned);
}

fn copyEditorState(destination: *EditorState, source: *const EditorState) !void {
    var abbr_iter = source.abbreviations.abbreviations.iterator();
    while (abbr_iter.next()) |entry| try destination.abbreviations.set(entry.key_ptr.*, entry.value_ptr.*);
    try destination.completions.copyFrom(&source.completions);
}

fn loadInteractiveCompletionAssets(
    allocator: std.mem.Allocator,
    io: std.Io,
    interactive_context: *Context,
    source: []const u8,
    cursor: usize,
) !void {
    const root = try completion.rootForCompletion(allocator, source, cursor) orelse return;
    defer allocator.free(root);

    var dirs = try assets.searchDirs(
        allocator,
        interactive_context.semantic_state.*,
        .completions,
        .data_first,
    );
    defer dirs.deinit();
    for (dirs.paths) |path| try loadInteractiveCompletionAssetsFromDir(allocator, io, interactive_context, path, root);
}

fn loadInteractiveCompletionAssetsFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    interactive_context: *Context,
    dir: []const u8,
    root: []const u8,
) !void {
    const json_name = try std.fmt.allocPrint(allocator, "{s}.json", .{root});
    defer allocator.free(json_name);
    const json_path = try std.fs.path.join(allocator, &.{ dir, json_name });
    defer allocator.free(json_path);
    try completion.loadManifestFile(allocator, io, &interactive_context.editor_state.completions, json_path);

    const rush_name = try std.fmt.allocPrint(allocator, "{s}.rush", .{root});
    defer allocator.free(rush_name);
    const rush_path = try std.fs.path.join(allocator, &.{ dir, rush_name });
    defer allocator.free(rush_path);
    try sourceInteractiveCompletionCompanion(allocator, io, interactive_context, rush_path);
}

fn sourceInteractiveCompletionCompanion(
    allocator: std.mem.Allocator,
    io: std.Io,
    interactive_context: *Context,
    path: []const u8,
) !void {
    if (interactive_context.editor_state.completions.loadedCompanion(path)) return;
    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(contents);

    var result = try runner.runShellStateScriptWithExtensionHandlers(
        allocator,
        io,
        interactive_context.semantic_state,
        contents,
        path,
        interactive_context.arg_zero,
        interactive_context.features,
        .capture,
        interactiveExtensionHandlers(interactive_context),
    );
    defer result.deinit();
    try interactive_context.editor_state.completions.markLoadedCompanion(path);
}

test "interactive completion lazily loads user manifest and companion script" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "rush/completions");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rush/completions/foo.json",
        .data =
        \\
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "foo",
        \\    "providers": {
        \\      "foo.values": { "function": "__rush_complete_foo_values" }
        \\    },
        \\    "subcommands": [
        \\      { "name": "bar", "description": "bar command" },
        \\      {
        \\        "name": "run",
        \\        "arguments": { "states": [{ "name": "value", "index": 0, "provider": "foo.values" }] }
        \\      }
        \\    ]
        \\  }
        \\}
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "rush/completions/foo.rush",
        .data =
        \\
        \\__rush_complete_foo_values() {
        \\  rush_complete candidate branch --kind plain --description dynamic
        \\  rush_complete candidate brown --kind plain --description dynamic --priority 10
        \\}
        \\
        ,
    });
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("XDG_CONFIG_HOME", tmp_root, .{ .exported = true });
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{
        .semantic_state = &shell_state,
        .editor_state = &editor_state,
    };

    const source = "foo b";
    try loadInteractiveCompletionAssets(std.testing.allocator, std.testing.io, &context, source, source.len);
    try std.testing.expect(shell_state.getFunction("__rush_complete_foo_values") != null);
    const application = try completion.manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &editor_state.completions,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bar", application.edit.replacement);

    const dynamic_source = "foo run br";
    const dynamic_application = try completion.manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &editor_state.completions,
        shell_state,
        dynamic_source,
        dynamic_source.len,
    );
    defer dynamic_application.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), dynamic_application.ambiguous.len);
    try std.testing.expectEqualStrings("brown", dynamic_application.ambiguous[0].value);
    try std.testing.expectEqualStrings("branch", dynamic_application.ambiguous[1].value);
}

fn drainInteractiveSemanticJobNotifications(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
) ![]const u8 {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    const eval_context = shell.EvalContext.init(.{
        .target = .current_shell,
        .source = .interactive,
        .interactive = true,
    });
    var outcome = try shell.eval.drainJobNotifications(&evaluator, shell_state, eval_context);
    defer outcome.deinit();
    try outcome.commitDelta(shell_state, .current_shell);
    const output = try outcome.stdout.toOwnedSlice(allocator);
    outcome.stdout = .empty;
    shell_state.validate();
    return output;
}

fn refreshInteractiveSemanticJobs(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
) !void {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (shell_state.background_jobs.items.len == 0) return;

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    const eval_context = shell.EvalContext.init(.{
        .target = .current_shell,
        .source = .interactive,
        .interactive = true,
    });
    var outcome = try shell.eval.refreshJobTable(&evaluator, shell_state, eval_context);
    defer outcome.deinit();
    try outcome.commitDelta(shell_state, .current_shell);
    shell_state.validate();
}

fn executeInteractivePendingTraps(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    arg_zero: []const u8,
    features: compat.Features,
) !?runner.CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(arg_zero.len != 0);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    evaluator.features = features;
    evaluator.arg_zero = arg_zero;
    evaluator.external_stdio = .inherit;
    const eval_context = shell.EvalContext.init(.{
        .target = .current_shell,
        .source = .interactive,
        .interactive = true,
    });

    if (try shell.eval.observeRuntimeSignal(&evaluator, shell_state, eval_context)) |observed| {
        var observation = observed;
        defer observation.deinit();
        try observation.command_outcome.commitDelta(shell_state, .current_shell);
    }

    var resolver = shell.eval.ParserBackedSourceResolver.init(&evaluator);
    resolver.features = features;
    resolver.arg_zero = arg_zero;
    var trap_outcome = (try shell.eval.executePendingTraps(
        &evaluator,
        shell_state,
        eval_context,
        resolver.resolver(),
    )) orelse return null;
    defer trap_outcome.deinit();

    const stdout = try trap_outcome.stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try trap_outcome.stderr.toOwnedSlice(allocator);
    errdefer allocator.free(stderr);
    try trap_outcome.commitDelta(shell_state, .current_shell);
    shell_state.validate();
    return .{ .allocator = allocator, .status = trap_outcome.status, .stdout = stdout, .stderr = stderr };
}

fn shellStateWantsImmediateJobNotificationPoll(shell_state: *const shell.ShellState) bool {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (!shell_state.options.notify) return false;
    if (shell_state.pending_job_notifications.items.len != 0) return true;
    for (shell_state.background_jobs.items) |job| {
        job.validate();
        if (job.state != .done or job.notified_state != job.state) return true;
    }
    return false;
}

fn countActiveBackgroundJobs(shell_state: shell.ShellState) usize {
    shell_state.validate();
    var count: usize = 0;
    for (shell_state.background_jobs.items) |job| {
        job.validate();
        if (job.state == .running) count += 1;
    }
    return count;
}

fn dispatchBackgroundJobLifecycleEvents(
    context: *Context,
    allocator: std.mem.Allocator,
    io: std.Io,
    previous_count: *usize,
) !void {
    const current_count = countActiveBackgroundJobs(context.semantic_state.*);
    if (current_count > previous_count.*) {
        var buffer: [32]u8 = undefined;
        const count_text = try std.fmt.bufPrint(&buffer, "{d}", .{current_count});
        for (previous_count.*..current_count) |_| {
            try runInteractiveEventHooks(context, allocator, io, .job_start, &.{ "job", count_text });
        }
    } else if (current_count < previous_count.*) {
        var buffer: [32]u8 = undefined;
        const count_text = try std.fmt.bufPrint(&buffer, "{d}", .{current_count});
        for (current_count..previous_count.*) |_| {
            try runInteractiveEventHooks(context, allocator, io, .job_end, &.{ "job", count_text });
        }
    }
    previous_count.* = current_count;
}

fn dispatchBackgroundJobLifecycleActivityEvents(
    context: *Context,
    allocator: std.mem.Allocator,
    io: std.Io,
    previous_count: *usize,
    output: *std.ArrayList(u8),
) !bool {
    const current_count = countActiveBackgroundJobs(context.semantic_state.*);
    var should_refresh_prompt = false;
    if (current_count > previous_count.*) {
        var buffer: [32]u8 = undefined;
        const count_text = try std.fmt.bufPrint(&buffer, "{d}", .{current_count});
        for (previous_count.*..current_count) |_| {
            const hook_result = try runInteractiveActivityEvent(
                context,
                allocator,
                io,
                "job.start",
                &.{ "job", count_text },
            );
            defer allocator.free(hook_result.output);
            try output.appendSlice(allocator, hook_result.output);
            should_refresh_prompt = should_refresh_prompt or hook_result.refresh_prompt or hook_result.output.len != 0;
        }
    } else if (current_count < previous_count.*) {
        var buffer: [32]u8 = undefined;
        const count_text = try std.fmt.bufPrint(&buffer, "{d}", .{current_count});
        for (current_count..previous_count.*) |_| {
            const hook_result = try runInteractiveActivityEvent(
                context,
                allocator,
                io,
                "job.end",
                &.{ "job", count_text },
            );
            defer allocator.free(hook_result.output);
            try output.appendSlice(allocator, hook_result.output);
            should_refresh_prompt = should_refresh_prompt or hook_result.refresh_prompt or hook_result.output.len != 0;
        }
    }
    previous_count.* = current_count;
    return should_refresh_prompt;
}

fn interactivePendingExit(interactive_shell: *const Shell) ?shell.ExitStatus {
    interactive_shell.semantic_state.validate();
    std.debug.assert(interactive_shell.semantic_state.scope == .current_shell);
    return interactive_shell.semantic_state.pending_exit;
}

pub const Options = startup.Options;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    semantic_state: shell.ShellState,
    editor_state: EditorState,

    pub fn init(allocator: std.mem.Allocator) Shell {
        return .{
            .allocator = allocator,
            .semantic_state = shell.ShellState.init(allocator),
            .editor_state = EditorState.init(allocator),
        };
    }

    pub fn deinit(self: *Shell) void {
        self.semantic_state.deinit();
        self.editor_state.deinit();
        self.* = undefined;
    }

    pub fn initializeSemanticStartup(
        self: *Shell,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        options: Options,
    ) !void {
        self.semantic_state.deinit();
        self.semantic_state = shell.ShellState.init(self.allocator);
        self.editor_state.deinit();
        self.editor_state = EditorState.init(self.allocator);

        var startup_shell_options = options.shell_options;
        startup.setShellOptions(&startup_shell_options, options.monitor_option_explicit, stdinIsTty(io));
        try shell.startup.initializeInteractiveState(
            self.allocator,
            io,
            &self.semantic_state,
            environ_map,
            options.positionals,
            startup_shell_options,
        );
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    options: Options,
) !u8 {
    var signal_handlers = signals.install();
    defer signal_handlers.restore();

    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    const active_session_id = try history.sessionId(allocator, io);
    defer allocator.free(active_session_id);
    command_history.session_id = active_session_id;
    const history_path = try history.defaultPath(allocator, environ_map);
    defer if (history_path) |path| allocator.free(path);
    if (history_path) |path| command_history.load(io, path) catch {
        try writeAll(io, .stderr, "rush: history load failed\n");
    };
    defer if (history_path) |path| command_history.save(io, path) catch {};
    const terminal_hostname = try history.localHostname(allocator);
    defer allocator.free(terminal_hostname);

    var last_status: shell.ExitStatus = 0;
    var last_command_duration_ms: ?i64 = null;
    var interactive_shell = Shell.init(allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(io, environ_map, options);
    var startup_context: Context = .{
        .semantic_state = &interactive_shell.semantic_state,
        .editor_state = &interactive_shell.editor_state,
        .arg_zero = options.arg_zero,
        .features = options.features,
    };
    var startup_options = options;
    startup_options.extension_handlers = interactiveExtensionHandlers(&startup_context);
    try startup.loadConfig(allocator, io, &interactive_shell.semantic_state, startup_options);
    if (interactivePendingExit(&interactive_shell)) |status| return status;
    var terminal = try editor_driver.TerminalSession.init(allocator, io);
    defer terminal.deinit();
    runtime.signal.setWakeFd(terminal.trapSignalWakeFd());
    defer runtime.signal.clearWakeFd(terminal.trapSignalWakeFd());
    try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
    var prompt_async_state: prompt_mod.AsyncState = .{};
    prompt_async_state.init(io, terminal.promptRedrawWakeFd());
    prompt_async_state.task_scheduler = prompt_mod.asyncTaskScheduler();
    defer prompt_async_state.deinitAbandoningTasks();
    var active_background_job_count = countActiveBackgroundJobs(interactive_shell.semantic_state);

    repl_loop: while (true) {
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        terminal.refreshWinsize();
        try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const notifications = try drainInteractiveSemanticJobNotifications(
            allocator,
            io,
            &interactive_shell.semantic_state,
        );
        defer allocator.free(notifications);
        try writeAll(io, .stderr, notifications);
        var job_event_context: Context = .{
            .semantic_state = &interactive_shell.semantic_state,
            .editor_state = &interactive_shell.editor_state,
            .arg_zero = options.arg_zero,
            .features = options.features,
            .previous_status = last_status,
            .previous_duration_ms = last_command_duration_ms,
            .prompt_async_state = &prompt_async_state,
            .active_background_job_count = &active_background_job_count,
        };
        try dispatchBackgroundJobLifecycleEvents(
            &job_event_context,
            allocator,
            io,
            &active_background_job_count,
        );
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        var prompt_prepare_context: Context = .{
            .semantic_state = &interactive_shell.semantic_state,
            .editor_state = &interactive_shell.editor_state,
            .arg_zero = options.arg_zero,
            .features = options.features,
            .previous_status = last_status,
            .previous_duration_ms = last_command_duration_ms,
            .prompt_async_state = &prompt_async_state,
            .active_background_job_count = &active_background_job_count,
        };
        try runInteractiveEventHooks(
            &prompt_prepare_context,
            allocator,
            io,
            .prompt_prepare,
            &.{},
        );
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        const prompt_text = try prompt_mod.render(allocator, io, &interactive_shell.semantic_state, .{
            .arg_zero = options.arg_zero,
            .features = options.features,
            .previous_status = last_status,
            .previous_duration_ms = last_command_duration_ms,
            .async_state = &prompt_async_state,
        });
        defer allocator.free(prompt_text);
        _ = try dispatchPromptAsyncLifecycleEvents(&prompt_prepare_context, allocator, io);
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        const physical_cwd = cwd_buffer[0..cwd_len];
        const cwd = if (prompt_mod.getEnv(&interactive_shell.semantic_state, "PWD")) |pwd|
            if (pwd.len != 0) pwd else physical_cwd
        else
            physical_cwd;
        command_history.current_cwd = physical_cwd;
        try terminal.reportCurrentDirectory(cwd, terminal_hostname);
        const title = try interactive_input.titlePath(
            allocator,
            cwd,
            prompt_mod.getEnv(&interactive_shell.semantic_state, "HOME"),
        );
        defer if (title.owned) allocator.free(title.text);
        try terminal.reportWindowTitle(title.text);
        var interactive_context: Context = .{
            .semantic_state = &interactive_shell.semantic_state,
            .editor_state = &interactive_shell.editor_state,
            .arg_zero = options.arg_zero,
            .features = options.features,
            .previous_status = last_status,
            .previous_duration_ms = last_command_duration_ms,
            .prompt_async_state = &prompt_async_state,
            .active_background_job_count = &active_background_job_count,
        };
        const ui_theme = interactiveUiTheme(interactive_shell.semantic_state);
        const read_options: editor_driver.ReadLineOptions = .{
            .prompt = prompt_text,
            .editing_mode = interactive_input.editingMode(interactive_shell.semantic_state.options),
            .hook_context = &interactive_context,
            .run_hooks = runInteractiveIntervalHooks,
            .next_hook_interval_ms = nextInteractiveIntervalMs,
            .run_activity_event = runInteractiveActivityEvent,
            .prompt_context = &interactive_context,
            .refresh_prompt = refreshInteractivePrompt,
            .history = history_service.lineEditorView(io),
            .completion_context = &interactive_context,
            .complete = completeInteractiveDefault,
            .clone_completion_context = cloneInteractiveCompletionContext,
            .free_completion_context = freeInteractiveCompletionContext,
            .expand_abbreviation = expandInteractiveAbbreviation,
            .external_editor_command = prompt_mod.externalEditorCommand(&interactive_shell.semantic_state),
            .external_editor_tmpdir = prompt_mod.externalEditorTmpdir(&interactive_shell.semantic_state),
            .theme = ui_theme,
            .style_context = &interactive_context,
            .refresh_style = refreshInteractiveStyle,
            .refresh_color_report = refreshInteractiveColorReport,
        };
        const read_result = try terminal.readLine(read_options);
        try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const line = switch (read_result) {
            .submitted => |line| line,
            .canceled => {
                if (try runInteractiveInterruptTrap(
                    allocator,
                    io,
                    &interactive_shell.semantic_state,
                    options.arg_zero,
                    options.features,
                )) |result| {
                    var trap_result = result;
                    defer trap_result.deinit();
                    try terminal.leaveEditorMode();
                    var editor_mode_left = true;
                    defer if (editor_mode_left) terminal.enterEditorMode() catch {};

                    try writeAll(io, .stdout, trap_result.stdout);
                    try writeAll(io, .stderr, trap_result.stderr);
                    if (interactive_input.outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) {
                        try writeAll(io, .stderr, omitted_newline_marker);
                    }
                    last_status = trap_result.status;
                    try terminal.finishSemanticCommand(trap_result.status);
                    if (interactivePendingExit(&interactive_shell)) |status| {
                        last_status = status;
                        editor_mode_left = false;
                        break;
                    }

                    try terminal.enterEditorMode();
                    editor_mode_left = false;
                }
                continue;
            },
            .interrupted => {
                if (interactivePendingExit(&interactive_shell)) |status| {
                    last_status = status;
                    break;
                }
                continue;
            },
            .eof => {
                if (!interactive_shell.semantic_state.options.ignoreeof) break;
                try writeAll(io, .stderr, ignoreeof_message);
                continue;
            },
        };
        defer allocator.free(line);

        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(allocator);
        try command.appendSlice(allocator, line);

        while (try interactive_input.needsContinuation(allocator, command.items, options.features)) {
            var continuation_options = read_options;
            continuation_options.prompt = prompt_mod.text(&interactive_shell.semantic_state, "PS2", "> ");
            continuation_options.diagnostic_context = null;
            continuation_options.diagnose = null;
            const continuation_read_result = try terminal.readLine(continuation_options);
            try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
            const continuation_line = switch (continuation_read_result) {
                .submitted => |continuation_line| continuation_line,
                .canceled => {
                    if (try runInteractiveInterruptTrap(
                        allocator,
                        io,
                        &interactive_shell.semantic_state,
                        options.arg_zero,
                        options.features,
                    )) |result| {
                        var trap_result = result;
                        defer trap_result.deinit();
                        try terminal.leaveEditorMode();
                        var editor_mode_left = true;
                        defer if (editor_mode_left) terminal.enterEditorMode() catch {};

                        try writeAll(io, .stdout, trap_result.stdout);
                        try writeAll(io, .stderr, trap_result.stderr);
                        if (interactive_input.outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) {
                            try writeAll(io, .stderr, omitted_newline_marker);
                        }
                        last_status = trap_result.status;
                        try terminal.finishSemanticCommand(trap_result.status);
                        if (interactivePendingExit(&interactive_shell)) |status| {
                            last_status = status;
                            editor_mode_left = false;
                            break :repl_loop;
                        }

                        try terminal.enterEditorMode();
                        editor_mode_left = false;
                    }
                    continue :repl_loop;
                },
                .interrupted => {
                    if (interactivePendingExit(&interactive_shell)) |status| {
                        last_status = status;
                        break :repl_loop;
                    }
                    continue :repl_loop;
                },
                .eof => {
                    try terminal.finishSemanticCommand(2);
                    last_status = 2;
                    continue :repl_loop;
                },
            };
            defer allocator.free(continuation_line);
            try command.append(allocator, '\n');
            try command.appendSlice(allocator, continuation_line);
        }

        const input = command.items;
        if (std.mem.eql(u8, input, "exit")) {
            if (interactive_shell.semantic_state.shouldWarnBeforeExitWithStoppedJobs()) {
                try terminal.finishSemanticCommand(0);
                try writeAll(io, .stderr, stopped_jobs_exit_warning);
                continue;
            }
            try terminal.finishSemanticCommand(0);
            break;
        }
        if (input.len == 0) {
            try terminal.finishSemanticCommand(0);
            continue;
        }

        {
            try terminal.leaveEditorMode();
            var editor_mode_left = true;
            defer if (editor_mode_left) terminal.enterEditorMode() catch {};

            const command_started_at = unixTimestamp(io);
            const command_started = monotonicTimestamp(io);
            var result = try runInteractiveScript(
                allocator,
                io,
                &interactive_shell,
                input,
                .{
                    .io = io,
                    .allow_external = true,
                    .features = options.features,
                    .external_stdio = .inherit,
                    .interactive = true,
                    .arg_zero = options.arg_zero,
                },
            );
            const command_duration_ms = durationMillis(command_started, monotonicTimestamp(io));
            last_command_duration_ms = command_duration_ms;
            defer result.deinit();
            try writeAll(io, .stdout, result.stdout);
            try writeAll(io, .stderr, result.stderr);
            if (interactive_input.outputNeedsNewlineMarker(result.stdout, result.stderr)) {
                try writeAll(io, .stderr, omitted_newline_marker);
            }
            last_status = result.status;
            if (!history_service.consumeSuppressNextAppend()) {
                try history_service.addCommand(
                    io,
                    input,
                    result.status,
                    command_started_at,
                    command_duration_ms,
                );
            }
            try terminal.finishSemanticCommand(result.status);
            if (interactivePendingExit(&interactive_shell)) |status| {
                last_status = status;
                editor_mode_left = false;
                break;
            }

            try terminal.enterEditorMode();
            editor_mode_left = false;
        }
    }

    return last_status;
}

fn runInteractiveScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    interactive_shell: *Shell,
    script: []const u8,
    options: runner.Options,
) !runner.CommandResult {
    std.debug.assert(options.interactive);
    var execution = try runSemanticInteractiveCommandString(
        allocator,
        io,
        interactive_shell,
        script,
        runner.invocationContext(options),
        options.external_stdio,
        options.live_stdio,
    );
    switch (execution) {
        .output => |output| {
            execution = undefined;
            return output;
        },
        .unsupported => |message| {
            execution = undefined;
            defer allocator.free(message);
            return runner.unsupported(allocator, message);
        },
    }
}

pub fn runSemanticInteractiveCommandString(
    allocator: std.mem.Allocator,
    io: std.Io,
    interactive_shell: *Shell,
    script: []const u8,
    invocation: shell.InvocationContext,
    external_stdio: runtime.ExternalStdio,
    live_stdio: bool,
) !runner.SemanticInvocationExecution {
    var interactive_context: Context = .{
        .semantic_state = &interactive_shell.semantic_state,
        .editor_state = &interactive_shell.editor_state,
        .arg_zero = invocation.arg_zero,
        .features = invocation.features,
    };
    return runner.runInteractiveCommandStringWithExtensionHandlers(
        allocator,
        io,
        &interactive_shell.semantic_state,
        script,
        invocation,
        external_stdio,
        live_stdio,
        interactiveExtensionHandlers(&interactive_context),
    );
}

fn refreshInteractiveStyle(
    context: *anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (refresh_style callback ABI).
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 - opaque context must come first (refresh_style callback ABI).
    io: std.Io,
    scheme: editor_driver.ColorScheme,
) !editor_render.UiTheme {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    try interactive_context.semantic_state.putRushStateVariable("rush_color_scheme", colorSchemeName(scheme));
    try runInteractiveStyleFunction(interactive_context, allocator, io);
    return interactiveUiTheme(interactive_context.semantic_state.*);
}

fn refreshInteractiveColorReport(
    context: *anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (refresh_color_report callback ABI).
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 - opaque context must come first (refresh_color_report callback ABI).
    io: std.Io,
    report: editor_driver.ColorReport,
) !editor_render.UiTheme {
    const interactive_context: *Context = @ptrCast(@alignCast(context));
    const variable = colorReportVariable(report) orelse return interactiveUiTheme(interactive_context.semantic_state.*);
    var value_buffer: [8]u8 = undefined;
    const value = try std.fmt.bufPrint(
        &value_buffer,
        "#{x:0>2}{x:0>2}{x:0>2}",
        .{ report.value[0], report.value[1], report.value[2] },
    );
    try interactive_context.semantic_state.putRushStateVariable(variable, value);
    try runInteractiveStyleFunction(interactive_context, allocator, io);
    return interactiveUiTheme(interactive_context.semantic_state.*);
}

fn runInteractiveStyleFunction(context: *Context, allocator: std.mem.Allocator, io: std.Io) !void {
    context.semantic_state.validate();
    if (context.semantic_state.getFunction("rush_style") == null) return;

    var result = try runner.runHiddenShellStateCommandWithExtensionHandlers(
        allocator,
        io,
        context.semantic_state,
        &.{"rush_style"},
        context.arg_zero,
        context.features,
        .capture,
        interactiveExtensionHandlers(context),
    );
    defer result.deinit();
}

fn colorReportVariable(report: editor_driver.ColorReport) ?[]const u8 {
    return switch (report.kind) {
        .fg => "rush_color_foreground",
        .bg => "rush_color_background",
        .cursor => null,
        .index => |index| switch (index) {
            0 => "rush_color_black",
            1 => "rush_color_red",
            2 => "rush_color_green",
            3 => "rush_color_yellow",
            4 => "rush_color_blue",
            5 => "rush_color_magenta",
            6 => "rush_color_cyan",
            7 => "rush_color_white",
            else => null,
        },
    };
}

fn colorSchemeName(scheme: editor_driver.ColorScheme) []const u8 {
    return switch (scheme) {
        .dark => "dark",
        .light => "light",
        .unknown => "unknown",
    };
}

fn interactiveUiTheme(shell_state: shell.ShellState) editor_render.UiTheme {
    var theme: editor_render.UiTheme = .{};
    applyUiStyleVariable(shell_state, &theme.completion_selected, "rush_style_completion_selected");
    applyUiStyleVariable(shell_state, &theme.completion_command, "rush_style_completion_command");
    applyUiStyleVariable(shell_state, &theme.completion_builtin, "rush_style_completion_builtin");
    applyUiStyleVariable(shell_state, &theme.completion_subcommand, "rush_style_completion_subcommand");
    applyUiStyleVariable(shell_state, &theme.completion_plain, "rush_style_completion_plain");
    applyUiStyleVariable(shell_state, &theme.completion_directory, "rush_style_completion_directory");
    applyUiStyleVariable(shell_state, &theme.completion_option, "rush_style_completion_option");
    applyUiStyleVariable(shell_state, &theme.completion_variable, "rush_style_completion_variable");
    applyUiStyleVariable(shell_state, &theme.completion_function, "rush_style_completion_function");
    applyUiStyleVariable(shell_state, &theme.completion_file, "rush_style_completion_file");
    applyUiStyleVariable(shell_state, &theme.completion_description, "rush_style_completion_description");
    applyUiStyleVariable(shell_state, &theme.completion_summary, "rush_style_completion_summary");
    applyUiStyleVariable(shell_state, &theme.completion_flash, "rush_style_completion_flash");
    applyUiStyleVariable(shell_state, &theme.history_match, "rush_style_history_match");
    applyUiStyleVariable(shell_state, &theme.autosuggestion, "rush_style_autosuggestion");
    applyUiStyleVariable(shell_state, &theme.diagnostic_error, "rush_style_diagnostic_error");
    return theme;
}

fn applyUiStyleVariable(
    shell_state: shell.ShellState,
    style: *editor_render.UiStyle,
    name: []const u8,
) void {
    const variable = shell_state.getVariable(name) orelse return;
    style.* = editor_render.parseUiStyle(variable.value) orelse style.*;
}

pub fn runCommandStringWithEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    script: []const u8,
    options: runner.Options,
    environ_map: ?*const std.process.Environ.Map,
    positionals: []const []const u8,
    startup_options: Options,
    shell_options: shell.ShellOptions,
) !runner.CommandResult {
    var interactive_run_options = options;
    interactive_run_options.interactive = true;
    var interactive_shell = Shell.init(allocator);
    defer interactive_shell.deinit();
    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    const startup_env = environ_map orelse &empty_env;
    var startup_shell_options = shell_options;
    startup.setShellOptions(&startup_shell_options, startup_options.monitor_option_explicit, stdinIsTty(io));
    try interactive_shell.initializeSemanticStartup(io, startup_env, .{
        .arg_zero = startup_options.arg_zero,
        .login = startup_options.login,
        .features = startup_options.features,
        .shell_options = startup_shell_options,
        .monitor_option_explicit = startup_options.monitor_option_explicit,
        .positionals = positionals,
    });
    var startup_context: Context = .{
        .semantic_state = &interactive_shell.semantic_state,
        .editor_state = &interactive_shell.editor_state,
        .arg_zero = startup_options.arg_zero,
        .features = startup_options.features,
    };
    var configured_startup_options = startup_options;
    configured_startup_options.extension_handlers = interactiveExtensionHandlers(&startup_context);
    try startup.loadConfig(allocator, io, &interactive_shell.semantic_state, configured_startup_options);
    if (interactivePendingExit(&interactive_shell)) |status| return runner.empty(allocator, status);
    return runInteractiveScript(allocator, io, &interactive_shell, script, interactive_run_options);
}

fn syncSemanticTerminalSize(shell_state: *shell.ShellState, terminal: editor_driver.TerminalSession) !void {
    const winsize = terminal.currentWinsize();
    if (winsize.rows == 0 or winsize.cols == 0) return;
    try shell_state.setInteractiveTerminalSize(winsize.rows, winsize.cols);
}

pub fn runInteractiveInterruptTrap(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    arg_zero: []const u8,
    features: compat.Features,
) !?runner.CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (!try shell_state.requestInteractiveInterruptTrap()) return null;
    return executeInteractivePendingTraps(allocator, io, shell_state, arg_zero, features);
}

pub fn runReplInput(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !runner.CommandResult {
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    var history_service = history.InteractiveHistoryService.init(&command_history);
    var last_status: shell.ExitStatus = 0;
    var interactive_shell = Shell.init(allocator);
    defer interactive_shell.deinit();
    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    try interactive_shell.initializeSemanticStartup(io, &empty_env, .{});
    {
        var context: Context = .{
            .semantic_state = &interactive_shell.semantic_state,
            .editor_state = &interactive_shell.editor_state,
        };
        var result = try startup.sourceDefaultConfig(
            allocator,
            io,
            &interactive_shell.semantic_state,
            "rush",
            .{},
            interactiveExtensionHandlers(&context),
        );
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
    }
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        const notifications = try drainInteractiveSemanticJobNotifications(
            allocator,
            io,
            &interactive_shell.semantic_state,
        );
        try stderr.appendSlice(allocator, notifications);
        allocator.free(notifications);
        const prompt_text = try prompt_mod.render(allocator, io, &interactive_shell.semantic_state, .{
            .previous_status = last_status,
            .previous_duration_ms = null,
        });
        try stdout.appendSlice(allocator, prompt_text);
        allocator.free(prompt_text);
        if (std.mem.eql(u8, line, "exit")) break;
        if (line.len == 0) continue;

        const command_started_at = unixTimestamp(io);
        var result = try runInteractiveScript(allocator, io, &interactive_shell, line, .{
            .io = io,
            .allow_external = true,
            .interactive = true,
            .arg_zero = "rush",
        });
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
        last_status = result.status;
        if (!history_service.consumeSuppressNextAppend()) {
            try history_service.addCommand(io, line, result.status, command_started_at, 0);
        }
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
    }

    return .{
        .allocator = allocator,
        .status = last_status,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const anyopaque,
) c_int;

const StdinGuard = struct {
    saved_fd: c_int,

    fn replaceWith(file: std.Io.File) !StdinGuard {
        const saved_fd = dup(std.Io.File.stdin().handle);
        if (saved_fd < 0) return error.SkipZigTest;
        errdefer _ = close(saved_fd);
        if (dup2(file.handle, std.Io.File.stdin().handle) < 0) return error.SkipZigTest;
        return .{ .saved_fd = saved_fd };
    }

    fn restore(self: *StdinGuard) void {
        _ = dup2(self.saved_fd, std.Io.File.stdin().handle);
        _ = close(self.saved_fd);
        self.* = undefined;
    }
};

test "runReplInput executes lines and tracks status" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "false\nexit\n");
    defer result.deinit();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "\x1b[38;5;4m{s}\x1b[39m ● " ++
            "\x1b[38;5;4m{s}\x1b[39m\x1b[38;5;1m ● \x1b[39m",
        .{ cwd, cwd },
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "interactive notify schedules editor job notification polling" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{ .semantic_state = &shell_state, .editor_state = &editor_state };

    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
    try shell_state.appendJobNotification(.{ .job_id = 1, .state = .done, .command = "sleep 1" });
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));

    shell_state.options.notify = true;
    try std.testing.expectEqual(
        @as(?u64, immediate_notify_poll_ms),
        try nextInteractiveIntervalMs(&context, std.testing.io),
    );

    shell_state.consumeJobNotifications(1);
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
}
test "interactive semantic job notifications drain from ShellState" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.notify = true;
    try shell_state.appendJobNotification(.{ .job_id = 1, .state = .done, .command = "sleep 1" });

    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{ .semantic_state = &shell_state, .editor_state = &editor_state };

    try std.testing.expectEqual(
        @as(?u64, immediate_notify_poll_ms),
        try nextInteractiveIntervalMs(&context, std.testing.io),
    );
    const hook_result = try runInteractiveIntervalHooks(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("[1] Done sleep 1\n", hook_result.output);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_job_notifications.items.len);
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
}
test "interactive timer events run due hooks" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setEventHook(.{
        .event = .timer_tick,
        .name = "clock",
        .function_name = "on_clock",
        .every_ms = 1000,
        .next_tick_ms = 0,
    });
    try shell_state.putFunction(.{
        .name = "on_clock",
        .source_body = "TICKED=$1; EVENT=$RUSH_EVENT; HOOK=$RUSH_EVENT_HOOK",
    });
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{ .semantic_state = &shell_state, .editor_state = &editor_state };

    const hook_result = try runInteractiveIntervalHooks(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("", hook_result.output);
    try std.testing.expect(hook_result.refresh_prompt);
    try std.testing.expect(!hook_result.stop);
    try std.testing.expectEqualStrings("clock", shell_state.getVariable("TICKED").?.value);
    try std.testing.expectEqualStrings("timer.tick", shell_state.getVariable("EVENT").?.value);
    try std.testing.expectEqualStrings("clock", shell_state.getVariable("HOOK").?.value);
    try std.testing.expectEqual(@as(?shell.Variable, null), shell_state.getVariable("RUSH_EVENT"));
    try std.testing.expectEqual(@as(?shell.Variable, null), shell_state.getVariable("RUSH_EVENT_HOOK"));
    try std.testing.expect(shell_state.event_hooks.items[0].next_tick_ms != null);
    try std.testing.expect(shell_state.event_hooks.items[0].next_tick_ms.? > monotonicMillis(std.testing.io));
}

test "interactive event hooks can register timer hooks from shell functions" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "on_job_start",
        .source_body = "event add timer.tick prompt-activity on_tick --every 180",
    });
    try shell_state.putFunction(.{ .name = "on_tick", .source_body = ":" });
    try shell_state.setEventHook(.{
        .event = .job_start,
        .name = "prompt-activity",
        .function_name = "on_job_start",
    });
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{ .semantic_state = &shell_state, .editor_state = &editor_state };

    const hook_result = try runInteractiveActivityEvent(
        &context,
        std.testing.allocator,
        std.testing.io,
        "job.start",
        &.{ "job", "1" },
    );
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("", hook_result.output);
    try std.testing.expect(hook_result.refresh_prompt);
    try std.testing.expect(!hook_result.stop);
    const registration = shell_state.event_hooks.items[1];
    try std.testing.expectEqual(shell.EventName.timer_tick, registration.event);
    try std.testing.expectEqualStrings("prompt-activity", registration.name);
    try std.testing.expectEqualStrings("on_tick", registration.function_name);
    try std.testing.expectEqual(@as(?u64, 180), registration.every_ms);
    try std.testing.expectEqual(@as(?u64, null), registration.next_tick_ms);
}

test "interactive interval hooks dispatch background job end lifecycle" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "on_job_end",
        .source_body = "JOB_EVENT=$RUSH_EVENT/$1/$2; event remove timer.tick prompt-activity",
    });
    try shell_state.setEventHook(.{
        .event = .job_end,
        .name = "prompt-activity",
        .function_name = "on_job_end",
    });
    try shell_state.setEventHook(.{
        .event = .timer_tick,
        .name = "prompt-activity",
        .function_name = "on_tick",
        .every_ms = 180,
    });
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var active_count: usize = 1;
    var context: Context = .{
        .semantic_state = &shell_state,
        .editor_state = &editor_state,
        .active_background_job_count = &active_count,
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(try dispatchBackgroundJobLifecycleActivityEvents(
        &context,
        std.testing.allocator,
        std.testing.io,
        &active_count,
        &output,
    ));

    try std.testing.expectEqualStrings("", output.items);
    try std.testing.expectEqual(@as(usize, 0), active_count);
    try std.testing.expectEqualStrings("job.end/job/0", shell_state.getVariable("JOB_EVENT").?.value);
    try std.testing.expectEqual(@as(usize, 1), shell_state.event_hooks.items.len);
    try std.testing.expectEqual(shell.EventName.job_end, shell_state.event_hooks.items[0].event);
}

test "interactive hooks dispatch pending semantic signal trap" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.TERM, "echo term-trap");
    try shell_state.appendPendingTrap(.TERM);

    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{ .semantic_state = &shell_state, .editor_state = &editor_state };

    const hook_result = try runInteractiveIntervalHooks(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("term-trap\n", hook_result.output);
    try std.testing.expect(hook_result.refresh_prompt);
    try std.testing.expect(!hook_result.stop);
}
test "interactive interrupt runs INT trap" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.INT, "echo trapped");

    var result = (try runInteractiveInterruptTrap(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        "rush",
        .{},
    )) orelse return error.MissingTrapResult;
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("trapped\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "semantic interactive command updates executor status for later commands" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var false_result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "false", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .inherit,
        .interactive = true,
        .arg_zero = "rush",
    });
    defer false_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 1), false_result.status);
    try std.testing.expectEqualStrings("", false_result.stdout);
    try std.testing.expectEqualStrings("", false_result.stderr);
    try std.testing.expectEqual(@as(shell.ExitStatus, 1), interactive_shell.semantic_state.last_status);

    var status_result = try runInteractiveScript(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "echo $?",
        .{
            .io = std.testing.io,
            .allow_external = true,
            .external_stdio = .inherit,
            .interactive = true,
            .arg_zero = "rush",
        },
    );
    defer status_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), status_result.status);
    try std.testing.expectEqualStrings("1\n", status_result.stdout);
    try std.testing.expectEqualStrings("", status_result.stderr);
}
test "semantic interactive shell state persists variable mutations" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var assign = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "RUSH_INTERACTIVE_SEMANTIC=state",
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .inherit,
        false,
    );
    defer assign.deinit(std.testing.allocator);
    switch (assign) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expectEqualStrings(
        "state",
        interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_SEMANTIC").?.value,
    );

    var readback = try runInteractiveScript(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "printf '%s\n' \"$RUSH_INTERACTIVE_SEMANTIC\"",
        .{
            .io = std.testing.io,
            .allow_external = true,
            .external_stdio = .inherit,
            .interactive = true,
            .arg_zero = "rush",
        },
    );
    defer readback.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), readback.status);
    try std.testing.expectEqualStrings("state\n", readback.stdout);
    try std.testing.expectEqualStrings("", readback.stderr);
}

test "semantic interactive eval accepts command substitution output" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var eval_result = try runInteractiveScript(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "eval \"$(printf '%s\\n' 'export RUSH_INTERACTIVE_EVAL=ok')\"",
        .{
            .io = std.testing.io,
            .allow_external = true,
            .external_stdio = .inherit,
            .interactive = true,
            .arg_zero = "rush",
        },
    );
    defer eval_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), eval_result.status);
    try std.testing.expectEqualStrings("", eval_result.stdout);
    try std.testing.expectEqualStrings("", eval_result.stderr);
    try std.testing.expectEqualStrings(
        "ok",
        interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_EVAL").?.value,
    );
}

test "semantic interactive assignment-bearing commands preserve assignment lifetime" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var temporary = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "RUSH_INTERACTIVE_TEMPORARY=discarded true",
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .inherit,
        false,
    );
    defer temporary.deinit(std.testing.allocator);
    switch (temporary) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expect(interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_TEMPORARY") == null);

    var persistent = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "RUSH_INTERACTIVE_SPECIAL=persistent :",
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .inherit,
        false,
    );
    defer persistent.deinit(std.testing.allocator);
    switch (persistent) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expectEqualStrings(
        "persistent",
        interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_SPECIAL").?.value,
    );
}
test "semantic interactive external commands run through runtime ports" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var external = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "/usr/bin/printf 'semantic-external\\n'",
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .capture,
        false,
    );
    defer external.deinit(std.testing.allocator);
    switch (external) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |output| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status);
            try std.testing.expectEqualStrings("semantic-external\n", output.stdout);
            try std.testing.expectEqualStrings("", output.stderr);
        },
    }
}
test "semantic interactive startup initializes ShellState without executor shell variables as source" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_INTERACTIVE_IMPORTED", "present");
    try env.put("SHLVL", "2");

    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{
        .arg_zero = "rush",
        .positionals = &.{ "one", "two" },
        .shell_options = .{ .ignoreeof = true },
    });
    try std.testing.expectEqualStrings(
        "present",
        interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_IMPORTED").?.value,
    );
    try std.testing.expectEqualStrings("3", interactive_shell.semantic_state.getVariable("SHLVL").?.value);
    try std.testing.expectEqualStrings(" \t\n", interactive_shell.semantic_state.getVariable("IFS").?.value);
    try std.testing.expectEqualStrings("1", interactive_shell.semantic_state.getVariable("OPTIND").?.value);
    try std.testing.expect(interactive_shell.semantic_state.options.ignoreeof);
    try std.testing.expectEqual(@as(usize, 2), interactive_shell.semantic_state.positionals.items.len);
    try std.testing.expectEqualStrings("one", interactive_shell.semantic_state.positionals.items[0]);
    try std.testing.expectEqualStrings("two", interactive_shell.semantic_state.positionals.items[1]);
}
test "semantic interactive invocation executes simple command redirections" {
    const path = "rush-semantic-interactive-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var semantic = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "echo before > " ++ path ++ "; echo redirected >> " ++ path,
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .inherit,
        false,
    );
    defer semantic.deinit(std.testing.allocator);
    switch (semantic) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("before\nredirected\n", output);
}

test "semantic interactive invocation preserves function definitions" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var semantic = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "f(){ echo FN=$1; }; f arg",
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .capture,
        false,
    );
    defer semantic.deinit(std.testing.allocator);
    switch (semantic) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("FN=arg\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive invocation executes compound commands" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var semantic = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "case abc in a*) echo CASE=no;; ab*) echo CASE=yes;; esac",
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .capture,
        false,
    );
    defer semantic.deinit(std.testing.allocator);
    switch (semantic) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("CASE=no\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic interactive command string aliases affect later lines" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var semantic = try runSemanticInteractiveCommandString(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell,
        "alias hi='echo HI'\nhi",
        shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }),
        .capture,
        false,
    );
    defer semantic.deinit(std.testing.allocator);
    switch (semantic) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("HI\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "interactive abbreviation expansion rewrites command words from editor state" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    try editor_state.abbreviations.set("ll", "ls -lh");

    var interactive_context: Context = .{ .semantic_state = &shell_state, .editor_state = &editor_state };
    const edit = (try expandInteractiveAbbreviation(
        &interactive_context,
        std.testing.allocator,
        "ll",
        "ll".len,
        true,
    )).?;
    defer std.testing.allocator.free(edit.replacement);

    try std.testing.expectEqual(@as(usize, 0), edit.replace_start);
    try std.testing.expectEqual(@as(usize, 2), edit.replace_end);
    try std.testing.expectEqualStrings("ls -lh", edit.replacement);
    try std.testing.expect(edit.append_space);

    try std.testing.expect(try expandInteractiveAbbreviation(
        &interactive_context,
        std.testing.allocator,
        "echo ll",
        "echo ll".len,
        false,
    ) == null);
    try std.testing.expect(try expandInteractiveAbbreviation(
        &interactive_context,
        std.testing.allocator,
        "'ll'",
        "'ll'".len,
        false,
    ) == null);
}

test "interactive abbreviation expansion handles later command positions" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    try editor_state.abbreviations.set("ll", "ls -lh");

    var interactive_context: Context = .{ .semantic_state = &shell_state, .editor_state = &editor_state };
    const edit = (try expandInteractiveAbbreviation(
        &interactive_context,
        std.testing.allocator,
        "true; ll",
        "true; ll".len,
        false,
    )).?;
    defer std.testing.allocator.free(edit.replacement);

    try std.testing.expectEqual(@as(usize, "true; ".len), edit.replace_start);
    try std.testing.expectEqual(@as(usize, "true; ll".len), edit.replace_end);
    try std.testing.expectEqualStrings("ls -lh", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

test "repl uses default rush_prompt" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\PS1='custom> '
        \\exit
    );
    defer result.deinit();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "\x1b[38;5;4m{s}\x1b[39m ● " ++
            "\x1b[38;5;4m{s}\x1b[39m ● ",
        .{ cwd, cwd },
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings(expected, result.stdout);
}

test "default rush_prompt fades activity dot when rgb colors are known" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var context: Context = .{
        .semantic_state = &interactive_shell.semantic_state,
        .editor_state = &interactive_shell.editor_state,
        .arg_zero = "rush",
    };
    var config_result = try startup.sourceDefaultConfig(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell.semantic_state,
        "rush",
        .{},
        interactiveExtensionHandlers(&context),
    );
    defer config_result.deinit();

    try interactive_shell.semantic_state.putRushStateVariable("rush_color_foreground", "#ffffff");
    try interactive_shell.semantic_state.putRushStateVariable("rush_color_background", "#000000");
    try interactive_shell.semantic_state.putRushStateVariable("rush_color_red", "#ff0000");
    try interactive_shell.semantic_state.putRushStateVariable("rush_prompt_activity_prompt", "1");

    const prompt = try prompt_mod.render(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell.semantic_state,
        .{},
    );
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\x1b[38;2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◐") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◓") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◑") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◒") == null);
}

test "default rush_prompt does not animate for background jobs" {
    var interactive_shell = Shell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var context: Context = .{
        .semantic_state = &interactive_shell.semantic_state,
        .editor_state = &interactive_shell.editor_state,
        .arg_zero = "rush",
    };
    var config_result = try startup.sourceDefaultConfig(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell.semantic_state,
        "rush",
        .{},
        interactiveExtensionHandlers(&context),
    );
    defer config_result.deinit();

    try interactive_shell.semantic_state.putRushStateVariable("rush_color_foreground", "#ffffff");
    try interactive_shell.semantic_state.putRushStateVariable("rush_color_background", "#000000");
    try interactive_shell.semantic_state.putRushStateVariable("rush_color_red", "#ff0000");
    try interactive_shell.semantic_state.putRushStateVariable("rush_prompt_activity_jobs", "1");

    const prompt = try prompt_mod.render(
        std.testing.allocator,
        std.testing.io,
        &interactive_shell.semantic_state,
        .{},
    );
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\x1b[38;2;") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◐") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◓") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◑") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "◒") == null);
}

const PendingPromptAsyncScheduler = struct {
    scheduled: bool = false,
    complete_context: ?*anyopaque = null,
    complete_fn: ?extension_api.AsyncTaskComplete = null,

    fn scheduler(self: *PendingPromptAsyncScheduler) extension_api.AsyncTaskScheduler {
        return .{ .context = self, .schedule_fn = schedule };
    }

    fn complete(self: *PendingPromptAsyncScheduler, stdout: []const u8) void {
        const complete_fn = self.complete_fn.?;
        complete_fn(self.complete_context, .{ .status = 0, .stdout = stdout });
    }

    fn schedule(
        allocator: std.mem.Allocator,
        io: std.Io,
        context: ?*anyopaque,
        request: extension_api.AsyncTaskRequest,
    ) !extension_api.AsyncTask {
        _ = allocator;
        _ = io;
        const self: *PendingPromptAsyncScheduler = @ptrCast(@alignCast(context.?));
        std.debug.assert(!self.scheduled);
        self.scheduled = true;
        self.complete_context = request.complete_context;
        self.complete_fn = request.complete;
        return .{ .context = self, .join_fn = join, .abandon_fn = abandon };
    }

    fn join(context: *anyopaque) void {
        _ = context;
    }

    fn abandon(context: *anyopaque) void {
        _ = context;
    }
};

test "prompt async refresh dispatches lifecycle events" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "rush_prompt",
        .source_body =
        \\value="$(prompt_async sample --ttl 10000 -- unused)"
        \\prompt text "[$value]"
        ,
    });
    try shell_state.putFunction(.{
        .name = "on_prompt_async",
        .source_body = "PROMPT_ASYNC_EVENT=$RUSH_EVENT/$1/$2",
    });
    try shell_state.setEventHook(.{
        .event = .prompt_async_start,
        .name = "prompt-activity",
        .function_name = "on_prompt_async",
    });
    try shell_state.setEventHook(.{
        .event = .prompt_async_end,
        .name = "prompt-activity",
        .function_name = "on_prompt_async",
    });
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var scheduler: PendingPromptAsyncScheduler = .{};
    var async_state: prompt_mod.AsyncState = .{};
    async_state.init(std.testing.io, null);
    async_state.task_scheduler = scheduler.scheduler();
    defer async_state.deinit();

    var context: Context = .{
        .semantic_state = &shell_state,
        .editor_state = &editor_state,
        .prompt_async_state = &async_state,
    };

    const prompt = try refreshInteractivePrompt(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("[]", prompt);
    try std.testing.expect(scheduler.scheduled);
    try std.testing.expectEqualStrings(
        "prompt.async.start/prompt/1",
        shell_state.getVariable("PROMPT_ASYNC_EVENT").?.value,
    );

    scheduler.complete("async");
    const refreshed = try refreshInteractivePrompt(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(refreshed);
    try std.testing.expectEqualStrings("[async]", refreshed);
    try std.testing.expectEqualStrings(
        "prompt.async.end/prompt/0",
        shell_state.getVariable("PROMPT_ASYNC_EVENT").?.value,
    );
}

test "interactive command string autoloads shipped shell function wrappers" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "share");
    try env.put("PATH", "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin");

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "ls >/dev/null; printf x | grep x >/dev/null; diff /dev/null /dev/null; type ls grep diff",
        .{ .io = std.testing.io, .allow_external = true, .features = .bash(), .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings(
        \\ls is a shell function
        \\grep is a shell function
        \\diff is a shell function
        \\
    , result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string autoloads shipped project environment hooks" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "share");
    try env.put("PATH", "");

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "rush_direnv_hook; rush_mise_hook; type rush_direnv_hook rush_mise_hook",
        .{ .io = std.testing.io, .allow_external = true, .features = .bash(), .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings(
        \\rush_direnv_hook is a shell function
        \\rush_mise_hook is a shell function
        \\
    , result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive startup enables monitor by default for tty stdin" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = close(master);
    defer _ = close(slave);

    var guard = try StdinGuard.replaceWith(.{ .handle = slave, .flags = .{ .nonblocking = false } });
    defer guard.restore();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var default_monitor = Shell.init(std.testing.allocator);
    defer default_monitor.deinit();
    try default_monitor.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });
    try std.testing.expect(default_monitor.semantic_state.options.monitor);

    var explicit_disabled = Shell.init(std.testing.allocator);
    defer explicit_disabled.deinit();
    try explicit_disabled.initializeSemanticStartup(std.testing.io, &env, .{
        .arg_zero = "rush",
        .monitor_option_explicit = true,
    });
    try std.testing.expect(!explicit_disabled.semantic_state.options.monitor);
}

test "interactive command string invocation sources expanded ENV before script" {
    const env_path = "rush-test-command-string-env.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "COMMAND_STRING_ENV=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const env_value = try std.fmt.allocPrint(std.testing.allocator, "${{ENV_DIR}}/{s}", .{env_path});
    defer std.testing.allocator.free(env_value);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV_DIR", cwd);
    try env.put("ENV", env_value);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"$COMMAND_STRING_ENV\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("loaded\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string invocation sources user alias config" {
    const root = "rush-test-alias-config-startup";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/rush/config.rush",
        .data = "alias ll='echo listed'\n",
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "alias ll; ll",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ll='echo listed'\nlisted\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string autoloads user functions" {
    const root = "rush-test-function-autoload";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/functions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/rush/functions/hello.rush",
        .data =
        \\printf 'autoload noise\n'
        \\hello() {
        \\  printf 'hello %s\n' "$1"
        \\}
        \\
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "hello rush",
        .{ .io = std.testing.io, .allow_external = true, .features = .bash(), .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello rush\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive style refresh runs rush_style with rush-owned color scheme" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "rush_style",
        .source_body =
        \\if test "$rush_color_scheme" = light; then
        \\  rush_style_history_match='fg=red,bold'
        \\else
        \\  rush_style_history_match='fg=blue'
        \\fi
        ,
    });
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{
        .semantic_state = &shell_state,
        .editor_state = &editor_state,
        .arg_zero = "rush",
    };

    const theme = try refreshInteractiveStyle(&context, std.testing.allocator, std.testing.io, .light);

    try std.testing.expectEqualStrings("light", shell_state.getVariable("rush_color_scheme").?.value);
    try std.testing.expectEqual(editor_render.parseUiColor("red").?, theme.history_match.fg.?);
    try std.testing.expect(theme.history_match.bold);
}

test "interactive color reports define rgb theme variables" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "rush_style",
        .source_body = "rush_style_completion_directory=\"fg=$rush_color_blue\"",
    });
    var editor_state = EditorState.init(std.testing.allocator);
    defer editor_state.deinit();
    var context: Context = .{
        .semantic_state = &shell_state,
        .editor_state = &editor_state,
        .arg_zero = "rush",
    };

    const theme = try refreshInteractiveColorReport(
        &context,
        std.testing.allocator,
        std.testing.io,
        .{ .kind = .{ .index = 4 }, .value = .{ 0x01, 0x23, 0x45 } },
    );

    try std.testing.expectEqualStrings("#012345", shell_state.getVariable("rush_color_blue").?.value);
    try std.testing.expectEqual(editor_render.parseUiColor("#012345").?, theme.completion_directory.fg.?);
}

test "interactive command string invocation exits immediately when user config exits" {
    const root = "rush-test-config-exit-startup";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data = "exit 7\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo should-not-run",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
test "interactive command string invocation exits immediately when user config exec fails" {
    const root = "rush-test-config-exec-failure-startup";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root ++ "/rush/config.rush",
        .data = "exec /nonexistent/rush-task-702 2>/dev/null\n",
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo should-not-run",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}
