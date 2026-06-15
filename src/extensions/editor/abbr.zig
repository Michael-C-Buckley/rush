//! `abbr` extension builtin implementation.

const std = @import("std");

const api = @import("../api.zig");
const delta = @import("../../shell/delta.zig");
const shell_startup = @import("../../shell/startup.zig");
const state = @import("../../shell/state.zig");

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "abbr")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "abbr"));

    const argv = invocation.argv;
    if (argv.len == 1 or (argv.len == 2 and std.mem.eql(u8, argv[1], "--list"))) {
        return api.EvaluationResult.normal(try listAbbreviations(invocation));
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "--erase")) {
        if (argv.len != 3) return api.EvaluationResult.normal(try invocation.usageError(
            "abbr",
            "usage: abbr --erase NAME",
        ));
        if (!isShellName(argv[2])) return api.EvaluationResult.normal(try invocation.usageError(
            "abbr",
            "invalid abbreviation name",
        ));
        if (lookupAbbreviationValue(invocation.shell_state, invocation.state_delta.*, argv[2]) == null) {
            return api.EvaluationResult.normal(try invocation.statusError(1, "abbr", "not found"));
        }
        try invocation.state_delta.unsetAbbreviation(argv[2]);
        return api.EvaluationResult.normal(0);
    }
    if (argv.len >= 2 and std.mem.startsWith(u8, argv[1], "--")) {
        return api.EvaluationResult.normal(try invocation.usageError("abbr", "unsupported option"));
    }
    if (argv.len != 3) return api.EvaluationResult.normal(try invocation.usageError(
        "abbr",
        "usage: abbr NAME EXPANSION",
    ));
    if (!isShellName(argv[1])) return api.EvaluationResult.normal(try invocation.usageError(
        "abbr",
        "invalid abbreviation name",
    ));
    try invocation.state_delta.setAbbreviation(argv[1], argv[2]);
    return api.EvaluationResult.normal(0);
}

fn listAbbreviations(invocation: *api.Invocation) !state.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(invocation.allocator);
    var iterator = invocation.shell_state.abbreviations.iterator();
    while (iterator.next()) |entry| try appendUniqueString(invocation.allocator, &names, entry.key_ptr.*);
    for (invocation.state_delta.abbreviation_sets.items) |mutation| try appendUniqueString(
        invocation.allocator,
        &names,
        mutation.name,
    );
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    for (names.items) |name| {
        const value = lookupAbbreviationValue(invocation.shell_state, invocation.state_delta.*, name) orelse continue;
        try invocation.stdout.print(invocation.allocator, "abbr {s} ", .{name});
        try api.appendShellSingleQuoted(invocation.allocator, invocation.stdout, value);
        try invocation.stdout.append(invocation.allocator, '\n');
    }
    return 0;
}

fn lookupAbbreviationValue(shell_state: state.ShellState, state_delta: delta.StateDelta, name: []const u8) ?[]const u8 {
    for (state_delta.abbreviation_unsets.items) |unset| if (std.mem.eql(u8, unset, name)) return null;
    for (state_delta.abbreviation_sets.items) |mutation| {
        if (std.mem.eql(u8, mutation.name, name)) return mutation.value;
    }
    return shell_state.getAbbreviation(name);
}

fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(allocator, value);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn isShellName(name: []const u8) bool {
    return shell_startup.isValidVariableName(name);
}
