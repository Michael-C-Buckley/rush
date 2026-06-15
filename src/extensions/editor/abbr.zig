//! `abbr` extension builtin implementation.

const std = @import("std");

const api = @import("../api.zig");
const editor_completion = @import("../../editor/completion.zig");
const compat = @import("../../shell/compat.zig");
const parser = @import("../../shell/parser.zig");
const shell_startup = @import("../../shell/startup.zig");
const state = @import("../../shell/state.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    abbreviations: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        var iterator = self.abbreviations.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.abbreviations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: State, name: []const u8) ?[]const u8 {
        if (!isShellName(name)) return null;
        return self.abbreviations.get(name);
    }

    pub fn set(self: *State, name: []const u8, value: []const u8) !void {
        std.debug.assert(isShellName(name));
        std.debug.assert(std.mem.indexOfScalar(u8, value, 0) == null);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const result = try self.abbreviations.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.value_ptr.*);
        }
        result.value_ptr.* = owned_value;
    }

    pub fn unset(self: *State, name: []const u8) bool {
        std.debug.assert(isShellName(name));
        if (self.abbreviations.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            return true;
        }
        return false;
    }
};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    return handlerForContext(name, null);
}

pub fn handlerForContext(name: []const u8, abbr_state: ?*State) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "abbr")) return null;
    return .{ .context = abbr_state, .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "abbr"));
    const abbr_state: *State = if (context) |value| @ptrCast(@alignCast(value)) else {
        return api.EvaluationResult.normal(try invocation.statusError(2, "abbr", "extension state unavailable"));
    };

    const argv = invocation.argv;
    if (argv.len == 1 or (argv.len == 2 and std.mem.eql(u8, argv[1], "--list"))) {
        return api.EvaluationResult.normal(try listAbbreviations(abbr_state, invocation));
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
        if (abbr_state.get(argv[2]) == null) {
            return api.EvaluationResult.normal(try invocation.statusError(1, "abbr", "not found"));
        }
        _ = abbr_state.unset(argv[2]);
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
    try abbr_state.set(argv[1], argv[2]);
    return api.EvaluationResult.normal(0);
}

fn listAbbreviations(abbr_state: *State, invocation: *api.Invocation) !state.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(invocation.allocator);
    var iterator = abbr_state.abbreviations.iterator();
    while (iterator.next()) |entry| try appendUniqueString(invocation.allocator, &names, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    for (names.items) |name| {
        const value = abbr_state.get(name) orelse continue;
        try invocation.stdout.print(invocation.allocator, "abbr {s} ", .{name});
        try api.appendShellSingleQuoted(invocation.allocator, invocation.stdout, value);
        try invocation.stdout.append(invocation.allocator, '\n');
    }
    return 0;
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

pub fn expand(
    abbr_state: *State,
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    features: compat.Features,
    append_space: bool,
) !?editor_completion.Edit {
    const clamped_cursor = @min(cursor, source.len);

    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .features = features });
    defer parsed.deinit();

    const cursor_context = parser.completionContext(parsed, clamped_cursor);
    if (cursor_context.kind != .command) return null;
    if (cursor_context.span.isEmpty() or cursor_context.span.end != clamped_cursor) return null;

    const name = cursor_context.span.slice(source);
    const replacement = abbr_state.get(name) orelse return null;
    return .{
        .replace_start = cursor_context.span.start,
        .replace_end = cursor_context.span.end,
        .replacement = try allocator.dupe(u8, replacement),
        .append_space = append_space,
    };
}
