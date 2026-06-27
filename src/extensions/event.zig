//! Shell event hook management builtin.

const std = @import("std");

const api = @import("api.zig");
const shell_builtin = @import("../shell/builtin.zig");
const shell_event = @import("../shell/event.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("event", .shell_state),
};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "event")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "event"));

    if (invocation.argv.len < 2) return api.EvaluationResult.normal(try usage(invocation));
    if (std.mem.eql(u8, invocation.argv[1], "add")) return evaluateAdd(invocation);
    if (std.mem.eql(u8, invocation.argv[1], "remove")) return evaluateRemove(invocation);
    if (std.mem.eql(u8, invocation.argv[1], "list")) return evaluateList(invocation);
    return api.EvaluationResult.normal(try invocation.usageError("event", "unsupported command"));
}

fn evaluateAdd(invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len < 5) return api.EvaluationResult.normal(try usage(invocation));
    const event_name = shell_event.Name.parse(invocation.argv[2]) orelse {
        return api.EvaluationResult.normal(try invocation.usageError("event", "unsupported event"));
    };
    if (!shell_event.isValidRegistrationName(invocation.argv[3])) {
        return api.EvaluationResult.normal(try invocation.usageError("event", "invalid registration name"));
    }
    if (!shell_event.isValidFunctionName(invocation.argv[4])) {
        return api.EvaluationResult.normal(try invocation.usageError("event", "invalid function name"));
    }
    var priority: i32 = 0;
    var every_ms: ?u64 = null;
    var index: usize = 5;
    while (index < invocation.argv.len) {
        const option = invocation.argv[index];
        if (index + 1 >= invocation.argv.len) return api.EvaluationResult.normal(try usage(invocation));
        if (std.mem.eql(u8, option, "--priority")) {
            priority = std.fmt.parseInt(i32, invocation.argv[index + 1], 10) catch {
                return api.EvaluationResult.normal(try invocation.usageError("event", "invalid priority"));
            };
        } else if (std.mem.eql(u8, option, "--every")) {
            every_ms = std.fmt.parseInt(u64, invocation.argv[index + 1], 10) catch {
                return api.EvaluationResult.normal(try invocation.usageError("event", "invalid interval"));
            };
            if (every_ms.? == 0) return api.EvaluationResult.normal(try invocation.usageError("event", "invalid interval"));
        } else {
            return api.EvaluationResult.normal(try invocation.usageError("event", "unsupported option"));
        }
        index += 2;
    }
    if (event_name == .timer_tick and every_ms == null) return api.EvaluationResult.normal(try usage(invocation));
    if (event_name != .timer_tick and every_ms != null) {
        return api.EvaluationResult.normal(try invocation.usageError("event", "unsupported option"));
    }
    try invocation.state_delta.setEventHook(.{
        .event = event_name,
        .name = invocation.argv[3],
        .function_name = invocation.argv[4],
        .priority = priority,
        .every_ms = every_ms,
    });
    return api.EvaluationResult.normal(0);
}

fn evaluateRemove(invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len != 4) return api.EvaluationResult.normal(try usage(invocation));
    const event_name = shell_event.Name.parse(invocation.argv[2]) orelse {
        return api.EvaluationResult.normal(try invocation.usageError("event", "unsupported event"));
    };
    if (!shell_event.isValidRegistrationName(invocation.argv[3])) {
        return api.EvaluationResult.normal(try invocation.usageError("event", "invalid registration name"));
    }
    try invocation.state_delta.removeEventHook(.{ .event = event_name, .name = invocation.argv[3] });
    return api.EvaluationResult.normal(0);
}

fn evaluateList(invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len > 3) return api.EvaluationResult.normal(try usage(invocation));
    const filter = if (invocation.argv.len == 3) shell_event.Name.parse(invocation.argv[2]) orelse {
        return api.EvaluationResult.normal(try invocation.usageError("event", "unsupported event"));
    } else null;

    var hooks: std.ArrayList(shell_event.Registration) = .empty;
    defer hooks.deinit(invocation.allocator);
    for (invocation.shell_state.event_hooks.items) |registration| {
        if (filter) |event_name| if (registration.event != event_name) continue;
        try hooks.append(invocation.allocator, registration);
    }
    std.mem.sort(shell_event.Registration, hooks.items, {}, lessThanRegistration);
    for (hooks.items) |registration| {
        try invocation.stdout.print(invocation.allocator, "event add {s} {s} {s}", .{
            registration.event.text(),
            registration.name,
            registration.function_name,
        });
        if (registration.every_ms) |every_ms| {
            try invocation.stdout.print(invocation.allocator, " --every {d}", .{every_ms});
        }
        try invocation.stdout.print(invocation.allocator, " --priority {d}\n", .{registration.priority});
    }
    return api.EvaluationResult.normal(0);
}

fn lessThanRegistration(_: void, left: shell_event.Registration, right: shell_event.Registration) bool {
    const left_event = left.event.text();
    const right_event = right.event.text();
    const event_order = std.mem.order(u8, left_event, right_event);
    if (event_order != .eq) return event_order == .lt;
    if (left.priority != right.priority) return left.priority < right.priority;
    return std.mem.lessThan(u8, left.name, right.name);
}

fn usage(invocation: *api.Invocation) !u8 {
    return invocation.usageError(
        "event",
        "usage: event add EVENT NAME FUNCTION [--priority N] [--every MS] | event remove EVENT NAME | event list [EVENT]",
    );
}

test "event add records registration in state delta" {
    var shell_state = @import("../shell/state.zig").ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var state_delta = @import("../shell/delta.zig").StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &.{ "event", "add", "directory.change", "direnv", "sync_direnv", "--priority", "40" },
        .builtins = &.{},
        .shell_state = shell_state,
        .state_delta = &state_delta,
        .eval_context = @import("../shell/context.zig").EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };

    const result = try evaluate(null, &invocation);
    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), state_delta.event_hook_sets.items.len);
    try std.testing.expectEqual(shell_event.Name.directory_change, state_delta.event_hook_sets.items[0].event);
    try std.testing.expectEqualStrings("direnv", state_delta.event_hook_sets.items[0].name);
    try std.testing.expectEqualStrings("sync_direnv", state_delta.event_hook_sets.items[0].function_name);
    try std.testing.expectEqual(@as(i32, 40), state_delta.event_hook_sets.items[0].priority);
}

test "event add defaults priority to zero" {
    var shell_state = @import("../shell/state.zig").ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var state_delta = @import("../shell/delta.zig").StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &.{ "event", "add", "prompt.prepare", "prompt-vars", "prepare_prompt" },
        .builtins = &.{},
        .shell_state = shell_state,
        .state_delta = &state_delta,
        .eval_context = @import("../shell/context.zig").EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };
    const result = try evaluate(null, &invocation);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), state_delta.event_hook_sets.items.len);
    try std.testing.expectEqual(@as(i32, 0), state_delta.event_hook_sets.items[0].priority);
}

test "event add records timer interval" {
    var shell_state = @import("../shell/state.zig").ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var state_delta = @import("../shell/delta.zig").StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &.{ "event", "add", "timer.tick", "clock", "on_clock", "--every", "1000" },
        .builtins = &.{},
        .shell_state = shell_state,
        .state_delta = &state_delta,
        .eval_context = @import("../shell/context.zig").EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };
    const result = try evaluate(null, &invocation);

    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), state_delta.event_hook_sets.items.len);
    try std.testing.expectEqual(shell_event.Name.timer_tick, state_delta.event_hook_sets.items[0].event);
    try std.testing.expectEqual(@as(?u64, 1000), state_delta.event_hook_sets.items[0].every_ms);
}
