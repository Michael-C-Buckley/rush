//! Structured completion model and pure application logic.

const std = @import("std");

pub const CancellationToken = struct {
    canceled: std.atomic.Value(bool) = .init(false),
    mutex: std.atomic.Mutex = .unlocked,
    child_pids: [32]i32 = .{0} ** 32,

    pub fn cancel(self: *CancellationToken) void {
        self.canceled.store(true, .release);
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (self.child_pids) |pid| terminateProcess(pid);
    }

    pub fn isCanceled(self: *CancellationToken) bool {
        return self.canceled.load(.acquire);
    }

    pub fn registerChild(self: *CancellationToken, pid: i32) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (&self.child_pids) |*slot| {
            if (slot.* == 0) {
                slot.* = pid;
                break;
            }
        } else {
            terminateProcess(pid);
            return;
        }
        if (self.isCanceled()) terminateProcess(pid);
    }

    pub fn unregisterChild(self: *CancellationToken, pid: i32) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (&self.child_pids) |*slot| {
            if (slot.* == pid) slot.* = 0;
        }
    }
};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

fn terminateProcess(pid: i32) void {
    if (pid <= 0) return;
    switch (@import("builtin").os.tag) {
        .windows => {},
        else => std.posix.kill(@intCast(pid), .TERM) catch {},
    }
}

test "cancellation token tracks multiple children" {
    var token: CancellationToken = .{};
    token.registerChild(-1);
    token.registerChild(-2);
    try std.testing.expectEqual(@as(i32, -1), token.child_pids[0]);
    try std.testing.expectEqual(@as(i32, -2), token.child_pids[1]);

    token.unregisterChild(-1);
    try std.testing.expectEqual(@as(i32, 0), token.child_pids[0]);
    try std.testing.expectEqual(@as(i32, -2), token.child_pids[1]);

    token.cancel();
    try std.testing.expect(token.isCanceled());
}

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

pub const MatchRank = enum(u8) {
    exact = 0,
    prefix = 1,
    fuzzy = 2,
};

pub const Option = struct {
    long: ?[]const u8 = null,
    short: ?[]const u8 = null,
    argument: ?[]const u8 = null,
    no_space: bool = false,
};

pub const RuleKind = enum {
    dynamic_subcommands,
    dynamic_options,
    dynamic_argument,
    dynamic_option_value,
    subcommand,
    option,
};

pub const Rule = struct {
    root: []const u8,
    path: []const []const u8 = &.{},
    kind: RuleKind,
    value: ?[]const u8 = null,
    option: Option = .{},
    description: ?[]const u8 = null,
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

    return .{ .ambiguous = try cloneCandidates(allocator, candidates) };
}

pub fn sortCandidates(candidates: []Candidate) void {
    std.mem.sort(Candidate, candidates, {}, lessThanCandidate);
}

fn lessThanCandidate(_: void, a: Candidate, b: Candidate) bool {
    const a_class = candidateSortClass(a);
    const b_class = candidateSortClass(b);
    if (a_class != b_class) return a_class < b_class;
    return std.mem.lessThan(u8, candidateSortKey(a), candidateSortKey(b));
}

fn candidateSortClass(candidate: Candidate) u8 {
    if (candidate.kind != .option) return 0;
    if (candidate.option) |option| {
        if (option.long == null and option.short != null) return 1;
    }
    return 2;
}

fn candidateSortKey(candidate: Candidate) []const u8 {
    if (candidate.kind == .option) {
        if (candidate.option) |option| {
            if (option.long) |long| return long;
            if (option.short) |short| return short;
        }
    }
    return candidate.display orelse candidate.value;
}

pub fn applyCandidatesForInput(allocator: std.mem.Allocator, source: []const u8, candidates: []const Candidate) !Application {
    if (candidates.len == 0) return .none;

    var matches: std.ArrayList(Candidate) = .empty;
    defer matches.deinit(allocator);
    var exact_matches: std.ArrayList(Candidate) = .empty;
    defer exact_matches.deinit(allocator);
    var prefix_matches: std.ArrayList(Candidate) = .empty;
    defer prefix_matches.deinit(allocator);
    var fuzzy_matches: std.ArrayList(Candidate) = .empty;
    defer fuzzy_matches.deinit(allocator);
    for (candidates) |candidate| {
        std.debug.assert(candidate.replace_start <= candidate.replace_end);
        std.debug.assert(candidate.replace_end <= source.len);
        const prefix = source[candidate.replace_start..candidate.replace_end];
        if (candidateFuzzyMatchRank(candidate, prefix)) |rank| {
            switch (rank) {
                .exact => try exact_matches.append(allocator, candidate),
                .prefix => try prefix_matches.append(allocator, candidate),
                .fuzzy => try fuzzy_matches.append(allocator, candidate),
            }
        }
    }
    try matches.appendSlice(allocator, exact_matches.items);
    try matches.appendSlice(allocator, prefix_matches.items);
    try matches.appendSlice(allocator, fuzzy_matches.items);

    return applyCandidates(allocator, matches.items);
}

pub fn candidateFuzzyMatchRank(candidate: Candidate, query: []const u8) ?MatchRank {
    const value_rank = fuzzyMatchRank(candidate.value, query);
    const display_rank = if (candidate.display) |display| fuzzyMatchRank(display, query) else null;
    if (value_rank) |value| {
        if (display_rank) |display| return if (@intFromEnum(display) < @intFromEnum(value)) display else value;
        return value;
    }
    return display_rank;
}

pub fn fuzzyMatchRank(text: []const u8, query: []const u8) ?MatchRank {
    if (query.len == 0) return .prefix;
    if (std.ascii.eqlIgnoreCase(text, query)) return .exact;
    if (std.ascii.startsWithIgnoreCase(text, query)) return .prefix;

    var text_index: usize = 0;
    for (query) |query_byte| {
        var matched = false;
        while (text_index < text.len) : (text_index += 1) {
            if (std.ascii.toLower(text[text_index]) == std.ascii.toLower(query_byte)) {
                text_index += 1;
                matched = true;
                break;
            }
        }
        if (!matched) return null;
    }
    return .fuzzy;
}

pub fn fuzzyMatchPositions(allocator: std.mem.Allocator, text: []const u8, query: []const u8) !?[]usize {
    if (fuzzyMatchRank(text, query) == null) return null;
    var positions: std.ArrayList(usize) = .empty;
    errdefer positions.deinit(allocator);
    if (query.len == 0) return try positions.toOwnedSlice(allocator);

    var text_index: usize = 0;
    for (query) |query_byte| {
        while (text_index < text.len) : (text_index += 1) {
            if (std.ascii.toLower(text[text_index]) == std.ascii.toLower(query_byte)) {
                try positions.append(allocator, text_index);
                text_index += 1;
                break;
            }
        }
    }
    return try positions.toOwnedSlice(allocator);
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
            .no_space = option.no_space,
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

test "application reports shared-prefix candidates as ambiguous" {
    const candidates = [_]Candidate{
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 },
    };
    const application = try applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("checkout", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("cherry-pick", application.ambiguous[1].value);
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

test "fuzzy matcher ranks exact prefix and ordered non-contiguous matches" {
    try std.testing.expectEqual(MatchRank.exact, fuzzyMatchRank("git checkout", "git checkout").?);
    try std.testing.expectEqual(MatchRank.prefix, fuzzyMatchRank("git checkout", "git").?);
    try std.testing.expectEqual(MatchRank.fuzzy, fuzzyMatchRank("git checkout", "gco").?);
    try std.testing.expect(fuzzyMatchRank("git checkout", "zq") == null);
}

test "application filtering uses fuzzy display and value matches" {
    const source = "git gco";
    const candidates = [_]Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 7 },
        .{ .value = "checkout", .display = "git checkout", .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 7 },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("checkout", edit.replacement);
}

test "application filtering ranks prefix matches before fuzzy matches" {
    const source = "git ch";
    const candidates = [_]Candidate{
        .{ .value = "git-checkout", .replace_start = 4, .replace_end = 6 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("checkout", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("git-checkout", application.ambiguous[1].value);
}

test "application filtering reports multiple prefix matches as ambiguous" {
    const source = "git c";
    const candidates = [_]Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 5 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 5 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 5 },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("checkout", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("cherry-pick", application.ambiguous[1].value);
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
