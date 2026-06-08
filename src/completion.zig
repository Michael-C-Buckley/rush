//! Structured completion model and pure application logic.

const std = @import("std");

pub const Kind = enum {
    command,
    builtin,
    function,
    file,
    directory,
    variable,
    option,
    subcommand,
    plain,
};

pub const Candidate = struct {
    value: []const u8,
    display: ?[]const u8 = null,
    description: ?[]const u8 = null,
    kind: Kind = .plain,
    replace_start: usize,
    replace_end: usize,
    append_space: bool = true,
};

pub const Edit = struct {
    replace_start: usize,
    replace_end: usize,
    replacement: []const u8,
    append_space: bool = false,
};

pub const Application = union(enum) {
    none,
    edit: Edit,
    ambiguous,

    pub fn deinit(self: Application, allocator: std.mem.Allocator) void {
        switch (self) {
            .edit => |edit| allocator.free(edit.replacement),
            .none, .ambiguous => {},
        }
    }
};

pub fn applyCandidates(allocator: std.mem.Allocator, candidates: []const Candidate) !Application {
    if (candidates.len == 0) return .none;
    const replace_start = candidates[0].replace_start;
    const replace_end = candidates[0].replace_end;

    for (candidates[1..]) |candidate| {
        std.debug.assert(candidate.replace_start == replace_start);
        std.debug.assert(candidate.replace_end == replace_end);
    }

    if (candidates.len == 1) {
        return .{ .edit = .{
            .replace_start = replace_start,
            .replace_end = replace_end,
            .replacement = try allocator.dupe(u8, candidates[0].value),
            .append_space = candidates[0].append_space,
        } };
    }

    const common = commonCandidatePrefix(candidates);
    const current_len = replace_end - replace_start;
    if (common.len > current_len) {
        return .{ .edit = .{
            .replace_start = replace_start,
            .replace_end = replace_end,
            .replacement = try allocator.dupe(u8, common),
            .append_space = false,
        } };
    }

    return .ambiguous;
}

fn commonCandidatePrefix(candidates: []const Candidate) []const u8 {
    std.debug.assert(candidates.len != 0);
    var prefix = candidates[0].value;
    for (candidates[1..]) |candidate| {
        var index: usize = 0;
        while (index < prefix.len and index < candidate.value.len and prefix[index] == candidate.value[index]) index += 1;
        prefix = prefix[0..index];
    }
    return prefix;
}

test "application handles no candidates" {
    const candidates = [_]Candidate{};
    const application = try applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(Application.none, application);
}

test "application inserts one candidate" {
    const candidates = [_]Candidate{.{
        .value = "status",
        .kind = .subcommand,
        .replace_start = 4,
        .replace_end = 6,
        .append_space = true,
    }};
    const application = try applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqual(@as(usize, 4), edit.replace_start);
    try std.testing.expectEqual(@as(usize, 6), edit.replace_end);
    try std.testing.expectEqualStrings("status", edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "application inserts common prefix" {
    const candidates = [_]Candidate{
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 },
    };
    const application = try applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("che", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

test "application reports ambiguous candidates" {
    const candidates = [_]Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 4 },
        .{ .value = "diff", .replace_start = 4, .replace_end = 4 },
    };
    const application = try applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(Application.ambiguous, application);
}
