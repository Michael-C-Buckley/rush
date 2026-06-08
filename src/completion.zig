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
    option: ?Option = null,
    replace_start: usize,
    replace_end: usize,
    append_space: bool = true,
};

pub const Option = struct {
    long: ?[]const u8 = null,
    short: ?[]const u8 = null,
    argument: ?[]const u8 = null,
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
    ambiguous: []Candidate,

    pub fn deinit(self: Application, allocator: std.mem.Allocator) void {
        switch (self) {
            .edit => |edit| allocator.free(edit.replacement),
            .ambiguous => |candidates| freeCandidates(allocator, candidates),
            .none => {},
        }
    }
};

pub fn freeCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| {
        freeCandidateFields(allocator, candidate);
    }
    allocator.free(candidates);
}

fn freeCandidateFields(allocator: std.mem.Allocator, candidate: Candidate) void {
    allocator.free(candidate.value);
    if (candidate.display) |display| allocator.free(display);
    if (candidate.description) |description| allocator.free(description);
    if (candidate.option) |option| {
        if (option.long) |long| allocator.free(long);
        if (option.short) |short| allocator.free(short);
        if (option.argument) |argument| allocator.free(argument);
    }
}

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

    return .{ .ambiguous = try cloneCandidates(allocator, candidates) };
}

pub fn applyCandidatesForInput(allocator: std.mem.Allocator, source: []const u8, candidates: []const Candidate) !Application {
    if (candidates.len == 0) return .none;

    var matches: std.ArrayList(Candidate) = .empty;
    defer matches.deinit(allocator);
    for (candidates) |candidate| {
        std.debug.assert(candidate.replace_start <= candidate.replace_end);
        std.debug.assert(candidate.replace_end <= source.len);
        const prefix = source[candidate.replace_start..candidate.replace_end];
        if (std.mem.startsWith(u8, candidate.value, prefix)) {
            try matches.append(allocator, candidate);
        }
    }

    return applyCandidates(allocator, matches.items);
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

pub fn cloneCandidates(allocator: std.mem.Allocator, candidates: []const Candidate) ![]Candidate {
    const cloned = try allocator.alloc(Candidate, candidates.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |candidate| freeCandidateFields(allocator, candidate);
    for (candidates, 0..) |candidate, index| {
        cloned[index] = try cloneCandidate(allocator, candidate);
        initialized += 1;
    }
    return cloned;
}

fn cloneCandidate(allocator: std.mem.Allocator, candidate: Candidate) !Candidate {
    var cloned = candidate;
    cloned.value = try allocator.dupe(u8, candidate.value);
    errdefer allocator.free(cloned.value);
    if (candidate.display) |display| cloned.display = try allocator.dupe(u8, display);
    errdefer if (cloned.display) |display| allocator.free(display);
    if (candidate.description) |description| cloned.description = try allocator.dupe(u8, description);
    errdefer if (cloned.description) |description| allocator.free(description);
    if (candidate.option) |option| {
        cloned.option = .{
            .long = if (option.long) |long| try allocator.dupe(u8, long) else null,
            .short = if (option.short) |short| try allocator.dupe(u8, short) else null,
            .argument = if (option.argument) |argument| try allocator.dupe(u8, argument) else null,
        };
    }
    errdefer if (cloned.option) |option| {
        if (option.long) |long| allocator.free(long);
        if (option.short) |short| allocator.free(short);
        if (option.argument) |argument| allocator.free(argument);
    };
    return cloned;
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

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
}

test "application filters candidates by replacement prefix" {
    const source = "git st";
    const candidates = [_]Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 6 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("status", edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "application filtering preserves common prefix insertion" {
    const source = "git c";
    const candidates = [_]Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 5 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 5 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 5 },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("che", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

test "application filtering reports no matching candidates" {
    const source = "git zz";
    const candidates = [_]Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 6 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(Application.none, application);
}
