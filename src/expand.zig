//! POSIX-oriented shell word expansion phases.
//!
//! This module intentionally exposes phases separately so Bash-specific behavior
//! can be added later without baking it into parsing or execution IR.

const std = @import("std");

pub const EnvLookup = struct {
    context: ?*const anyopaque = null,
    lookupFn: ?*const fn (?*const anyopaque, []const u8) ?[]const u8 = null,

    pub fn get(self: EnvLookup, name: []const u8) ?[]const u8 {
        const lookup = self.lookupFn orelse return null;
        return lookup(self.context, name);
    }
};

pub const Options = struct {
    env: EnvLookup = .{},
};

pub const Phase = enum {
    tilde,
    parameter,
    field_splitting,
    pathname,
    quote_removal,
};

pub const ExpansionResult = struct {
    allocator: std.mem.Allocator,
    fields: []const []const u8,

    pub fn deinit(self: *ExpansionResult) void {
        for (self.fields) |field| self.allocator.free(field);
        self.allocator.free(self.fields);
        self.* = undefined;
    }
};

pub fn expandWord(allocator: std.mem.Allocator, raw: []const u8, options: Options) !ExpansionResult {
    const scalar = try expandWordScalar(allocator, raw, options);
    errdefer allocator.free(scalar);

    const fields = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(fields);
    fields[0] = scalar;

    return .{
        .allocator = allocator,
        .fields = fields,
    };
}

pub fn expandWordScalar(allocator: std.mem.Allocator, raw: []const u8, options: Options) ![]const u8 {
    const tilde_expanded = try expandTilde(allocator, raw, options.env);
    defer allocator.free(tilde_expanded);

    const parameter_expanded = try expandParameters(allocator, tilde_expanded, options.env);
    defer allocator.free(parameter_expanded);

    // Field splitting and pathname expansion are explicit phases even though
    // this scalar helper leaves them as no-ops. `expandWord` is the place that
    // will grow multiple fields later.
    const field_split = parameter_expanded;
    const pathname_expanded = field_split;

    return quoteRemove(allocator, pathname_expanded);
}

pub fn expandTilde(allocator: std.mem.Allocator, raw: []const u8, env: EnvLookup) ![]const u8 {
    if (raw.len == 0 or raw[0] != '~') return allocator.dupe(u8, raw);
    if (raw.len > 1 and raw[1] != '/') return allocator.dupe(u8, raw);
    const home = env.get("HOME") orelse return allocator.dupe(u8, raw);
    return std.mem.concat(allocator, u8, &.{ home, raw[1..] });
}

pub fn expandParameters(allocator: std.mem.Allocator, raw: []const u8, env: EnvLookup) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                const start = index;
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {}
                if (index < raw.len) index += 1;
                try output.appendSlice(allocator, raw[start..index]);
            },
            '$' => if (try expandParameterAt(allocator, raw, &index, env, &output)) {},
            else => |c| {
                try output.append(allocator, c);
                index += 1;
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

fn expandParameterAt(allocator: std.mem.Allocator, raw: []const u8, index: *usize, env: EnvLookup, output: *std.ArrayList(u8)) !bool {
    std.debug.assert(raw[index.*] == '$');
    const dollar = index.*;
    index.* += 1;

    if (index.* >= raw.len) {
        try output.append(allocator, '$');
        return true;
    }

    if (raw[index.*] == '{') {
        const name_start = index.* + 1;
        var name_end = name_start;
        while (name_end < raw.len and raw[name_end] != '}') : (name_end += 1) {}
        if (name_end >= raw.len) {
            try output.appendSlice(allocator, raw[dollar..]);
            index.* = raw.len;
            return true;
        }
        if (env.get(raw[name_start..name_end])) |value| try output.appendSlice(allocator, value);
        index.* = name_end + 1;
        return true;
    }

    if (!isNameStart(raw[index.*])) {
        try output.append(allocator, '$');
        try output.append(allocator, raw[index.*]);
        index.* += 1;
        return true;
    }

    const name_start = index.*;
    index.* += 1;
    while (index.* < raw.len and isNameContinue(raw[index.*])) : (index.* += 1) {}
    if (env.get(raw[name_start..index.*])) |value| try output.appendSlice(allocator, value);
    return true;
}

pub fn quoteRemove(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {
                    try output.append(allocator, raw[index]);
                }
                if (index < raw.len) index += 1;
            },
            '"' => {
                index += 1;
                while (index < raw.len and raw[index] != '"') {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        index += 1;
                    }
                    try output.append(allocator, raw[index]);
                    index += 1;
                }
                if (index < raw.len) index += 1;
            },
            '\\' => {
                index += 1;
                if (index < raw.len) {
                    try output.append(allocator, raw[index]);
                    index += 1;
                }
            },
            else => |c| {
                try output.append(allocator, c);
                index += 1;
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c);
}

fn testLookup(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "HOME")) return "/home/rush";
    if (std.mem.eql(u8, name, "USER")) return "rush-user";
    if (std.mem.eql(u8, name, "EMPTY")) return "";
    return null;
}

const test_env: EnvLookup = .{ .lookupFn = testLookup };

test "expansion phases include tilde parameter and quote removal" {
    const expanded = try expandWordScalar(std.testing.allocator, "~/src/$USER/'literal $USER'/\"x\"", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("/home/rush/src/rush-user/literal $USER/x", expanded);
}

test "parameter expansion supports braced names and missing values" {
    const expanded = try expandWordScalar(std.testing.allocator, "${USER}-${MISSING}-${EMPTY}", .{ .env = test_env });
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("rush-user--", expanded);
}

test "expand word returns fields through an explicit result" {
    var result = try expandWord(std.testing.allocator, "'hello world'", .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.fields.len);
    try std.testing.expectEqualStrings("hello world", result.fields[0]);
}
