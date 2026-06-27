//! Native environment import helper for shell integration hooks.

const std = @import("std");

const api = @import("api.zig");
const assignment = @import("../shell/assignment.zig");
const shell_builtin = @import("../shell/builtin.zig");
const shell_context = @import("../shell/context.zig");
const shell_delta = @import("../shell/delta.zig");
const shell_state = @import("../shell/state.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("rush_env", .shell_state),
};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "rush_env")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "rush_env"));

    if (invocation.argv.len != 2) return api.EvaluationResult.normal(try usage(invocation));
    const mode: ImportMode = if (std.mem.eql(u8, invocation.argv[1], "import-json"))
        .json
    else if (std.mem.eql(u8, invocation.argv[1], "import-sh"))
        .shell
    else {
        return api.EvaluationResult.normal(try invocation.usageError("rush_env", "unsupported command"));
    };
    if (invocation.stdin == null) {
        return api.EvaluationResult.normal(try invocation.statusError(1, "rush_env", "stdin unavailable"));
    }

    const input = invocation.stdin.?.takeRemaining();

    (switch (mode) {
        .json => applyJsonEnvironment(invocation, input),
        .shell => applyShellEnvironment(invocation, input),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return api.EvaluationResult.normal(try invocation.statusError(
            1,
            "rush_env",
            "invalid environment output",
        )),
    };
    return api.EvaluationResult.normal(0);
}

const ImportMode = enum { json, shell };

fn applyJsonEnvironment(invocation: *api.Invocation, contents: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, invocation.allocator, contents, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJsonEnvironment,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!assignment.isProcessEnvironmentName(name) or !isShellVariableName(name)) {
            return error.InvalidJsonEnvironment;
        }
        switch (entry.value_ptr.*) {
            .string => |value| {
                if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidJsonEnvironment;
                try invocation.state_delta.assignVariable(name, value, .{ .exported = true });
            },
            .null => try invocation.state_delta.unsetVariable(name),
            else => return error.InvalidJsonEnvironment,
        }
    }
}

fn isShellVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn applyShellEnvironment(invocation: *api.Invocation, contents: []const u8) !void {
    var rest = contents;
    while (rest.len != 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const raw_line = rest[0..line_end];
        rest = if (line_end == rest.len) &.{} else rest[line_end + 1 ..];
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            try applyShellExport(invocation, line[7..]);
        } else if (std.mem.startsWith(u8, line, "unset ")) {
            try applyShellUnset(invocation, line[6..]);
        } else {
            return error.InvalidShellEnvironment;
        }
    }
}

fn applyShellExport(invocation: *api.Invocation, text: []const u8) !void {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidShellEnvironment;
    const name = text[0..equals];
    if (!assignment.isProcessEnvironmentName(name) or !isShellVariableName(name)) {
        return error.InvalidShellEnvironment;
    }
    const value = try parseShellWord(invocation.allocator, text[equals + 1 ..]);
    defer invocation.allocator.free(value);
    try invocation.state_delta.assignVariable(name, value, .{ .exported = true });
}

fn applyShellUnset(invocation: *api.Invocation, text: []const u8) !void {
    var iterator = std.mem.tokenizeAny(u8, text, " \t");
    var count: usize = 0;
    while (iterator.next()) |name| {
        if (!assignment.isProcessEnvironmentName(name) or !isShellVariableName(name)) {
            return error.InvalidShellEnvironment;
        }
        try invocation.state_delta.unsetVariable(name);
        count += 1;
    }
    if (count == 0) return error.InvalidShellEnvironment;
}

fn parseShellWord(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        switch (byte) {
            '\'', '"' => {
                const consumed = try parseQuotedShellText(allocator, &out, text[index..], byte);
                index += consumed;
            },
            '\\' => {
                if (index + 1 >= text.len) return error.InvalidShellEnvironment;
                try out.append(allocator, text[index + 1]);
                index += 2;
            },
            ' ', '\t', '\r', '\n' => return error.InvalidShellEnvironment,
            else => {
                try out.append(allocator, byte);
                index += 1;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn parseQuotedShellText(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    quote: u8,
) !usize {
    std.debug.assert(text.len != 0);
    std.debug.assert(text[0] == quote);
    var index: usize = 1;
    while (index < text.len) {
        const byte = text[index];
        if (byte == quote) return index + 1;
        if (quote == '"' and byte == '\\') {
            if (index + 1 >= text.len) return error.InvalidShellEnvironment;
            try out.append(allocator, text[index + 1]);
            index += 2;
            continue;
        }
        try out.append(allocator, byte);
        index += 1;
    }
    return error.InvalidShellEnvironment;
}

fn usage(invocation: *api.Invocation) !u8 {
    return invocation.usageError("rush_env", "usage: rush_env import-json|import-sh");
}

test "rush_env import-json applies string and null JSON entries" {
    var state = shell_state.ShellState.init(std.testing.allocator);
    defer state.deinit();
    var state_delta = shell_delta.StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &.{ "rush_env", "import-json", "tool" },
        .builtins = &.{},
        .shell_state = state,
        .state_delta = &state_delta,
        .eval_context = shell_context.EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };

    try applyJsonEnvironment(&invocation, "{\"FOO\":\"bar\",\"REMOVE_ME\":null}");
    try std.testing.expectEqual(@as(usize, 1), state_delta.variable_assignments.items.len);
    try std.testing.expectEqualStrings("FOO", state_delta.variable_assignments.items[0].name);
    try std.testing.expectEqualStrings("bar", state_delta.variable_assignments.items[0].value);
    try std.testing.expectEqual(@as(?bool, true), state_delta.variable_assignments.items[0].exported);
    try std.testing.expectEqual(@as(usize, 1), state_delta.variable_unsets.items.len);
    try std.testing.expectEqualStrings("REMOVE_ME", state_delta.variable_unsets.items[0]);
}

test "rush_env import-json rejects non-shell environment names" {
    var state = shell_state.ShellState.init(std.testing.allocator);
    defer state.deinit();
    var state_delta = shell_delta.StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &.{ "rush_env", "import-json", "tool" },
        .builtins = &.{},
        .shell_state = state,
        .state_delta = &state_delta,
        .eval_context = shell_context.EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };

    try std.testing.expectError(
        error.InvalidJsonEnvironment,
        applyJsonEnvironment(&invocation, "{\"BAD-NAME\":\"x\"}"),
    );
}

test "rush_env import-sh applies export and unset lines" {
    var state = shell_state.ShellState.init(std.testing.allocator);
    defer state.deinit();
    var state_delta = shell_delta.StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &.{ "rush_env", "import-sh", "tool" },
        .builtins = &.{},
        .shell_state = state,
        .state_delta = &state_delta,
        .eval_context = shell_context.EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };

    try applyShellEnvironment(&invocation, "export PATH='/tmp/bin:/usr/bin'\nexport FOO=one\nunset OLD BAR\n");
    try std.testing.expectEqual(@as(usize, 2), state_delta.variable_assignments.items.len);
    try std.testing.expectEqualStrings("PATH", state_delta.variable_assignments.items[0].name);
    try std.testing.expectEqualStrings("/tmp/bin:/usr/bin", state_delta.variable_assignments.items[0].value);
    try std.testing.expectEqualStrings("FOO", state_delta.variable_assignments.items[1].name);
    try std.testing.expectEqualStrings("one", state_delta.variable_assignments.items[1].value);
    try std.testing.expectEqual(@as(usize, 2), state_delta.variable_unsets.items.len);
    try std.testing.expectEqualStrings("OLD", state_delta.variable_unsets.items[0]);
    try std.testing.expectEqualStrings("BAR", state_delta.variable_unsets.items[1]);
}

test "rush_env import-sh parses adjacent single quoted shell text" {
    const parsed = try parseShellWord(std.testing.allocator, "'it'\\''s ok'");
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqualStrings("it's ok", parsed);
}
