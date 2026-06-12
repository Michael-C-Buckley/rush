//! Structured completion model and pure application logic.

const std = @import("std");

pub const CancellationToken = struct {
    canceled: std.atomic.Value(bool) = .init(false),
    mutex: std.atomic.Mutex = .unlocked,
    children: [32]CancelableChild = .{CancelableChild{}} ** 32,

    const CancelableChild = struct {
        pid: i32 = 0,
        process_group: bool = false,
    };

    pub fn cancel(self: *CancellationToken) void {
        self.canceled.store(true, .release);
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (self.children) |child| terminateProcess(child);
    }

    pub fn isCanceled(self: *CancellationToken) bool {
        return self.canceled.load(.acquire);
    }

    pub fn activeChildCount(self: *CancellationToken) usize {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.children) |child| {
            if (child.pid != 0) count += 1;
        }
        return count;
    }

    pub fn registerChild(self: *CancellationToken, pid: i32) void {
        self.register(pid, false);
    }

    pub fn registerProcessGroup(self: *CancellationToken, pid: i32) void {
        self.register(pid, true);
    }

    fn register(self: *CancellationToken, pid: i32, process_group: bool) void {
        if (pid <= 0) return;
        const child: CancelableChild = .{ .pid = pid, .process_group = process_group };
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (&self.children) |*slot| {
            if (slot.pid == 0) {
                slot.* = child;
                break;
            }
        } else {
            terminateProcess(child);
            return;
        }
        if (self.isCanceled()) terminateProcess(child);
    }

    pub fn unregisterChild(self: *CancellationToken, pid: i32) void {
        if (pid <= 0) return;
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        for (&self.children) |*slot| {
            if (slot.pid == pid) slot.* = .{};
        }
    }
};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

fn terminateProcess(child: CancellationToken.CancelableChild) void {
    if (child.pid <= 0) return;
    switch (@import("builtin").os.tag) {
        .windows => {},
        else => {
            const pid: std.posix.pid_t = @intCast(child.pid);
            std.posix.kill(if (child.process_group) -pid else pid, .TERM) catch {};
        },
    }
}

test "cancellation token tracks multiple children" {
    var token: CancellationToken = .{};
    token.registerChild(1);
    token.registerProcessGroup(2);
    try std.testing.expectEqual(@as(i32, 1), token.children[0].pid);
    try std.testing.expect(!token.children[0].process_group);
    try std.testing.expectEqual(@as(i32, 2), token.children[1].pid);
    try std.testing.expect(token.children[1].process_group);

    token.unregisterChild(1);
    try std.testing.expectEqual(@as(i32, 0), token.children[0].pid);
    try std.testing.expectEqual(@as(i32, 2), token.children[1].pid);

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

pub const CaseSensitivity = enum {
    sensitive,
    insensitive,
};

pub const MatchMode = enum {
    prefix,
    fuzzy,
};

pub const SeparatorPolicy = enum {
    literal,
    hyphen_underscore_equivalent,
};

pub const PathSegmentPolicy = enum {
    full,
    last,
};

pub const MatcherPolicy = struct {
    case_sensitivity: CaseSensitivity = .insensitive,
    mode: MatchMode = .fuzzy,
    separators: SeparatorPolicy = .hyphen_underscore_equivalent,
    path_segments: PathSegmentPolicy = .full,

    pub fn engineDefault() MatcherPolicy {
        return .{};
    }

    pub fn prefixOnly() MatcherPolicy {
        return .{ .mode = .prefix };
    }
};

pub const MatchSuppressionReason = enum {
    invalid_replace_span,
    no_match,
    prefix_only,
};

pub const CandidateMatchTrace = struct {
    query: []const u8,
    rank: ?MatchRank,
    suppression_reason: ?MatchSuppressionReason,
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

pub const RuleSourceKind = enum {
    rush,
    manifest,
};

pub const RuleSource = struct {
    kind: RuleSourceKind = .rush,
    manifest_path: ?[]const u8 = null,
    manifest_version: ?i64 = null,
};

pub const Rule = struct {
    root: []const u8,
    path: []const []const u8 = &.{},
    kind: RuleKind,
    value: ?[]const u8 = null,
    option: Option = .{},
    description: ?[]const u8 = null,
    source: RuleSource = .{},
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
    if (candidate.kind == .directory) return 0;
    if (candidate.kind == .file) return 1;
    if (candidate.kind != .option) return 2;
    if (candidate.option) |option| {
        if (option.long == null and option.short != null) return 3;
    }
    return 4;
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
    return applyCandidatesForInputWithPolicy(allocator, source, candidates, .engineDefault());
}

pub fn applyCandidatesForInputWithPolicy(allocator: std.mem.Allocator, source: []const u8, candidates: []const Candidate, policy: MatcherPolicy) !Application {
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
        if (candidateMatchRank(candidate, prefix, policy)) |rank| {
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
    return candidateMatchRank(candidate, query, .engineDefault());
}

pub fn candidateMatchRank(candidate: Candidate, query: []const u8, policy: MatcherPolicy) ?MatchRank {
    const value_rank = matchRank(candidate.value, query, policy);
    const display_rank = if (candidate.display) |display| matchRank(display, query, policy) else null;
    if (value_rank) |value| {
        if (display_rank) |display| return if (@intFromEnum(display) < @intFromEnum(value)) display else value;
        return value;
    }
    return display_rank;
}

pub fn candidateMatchTrace(source: []const u8, candidate: Candidate, policy: MatcherPolicy) CandidateMatchTrace {
    if (candidate.replace_start > candidate.replace_end or candidate.replace_end > source.len) {
        return .{ .query = "", .rank = null, .suppression_reason = .invalid_replace_span };
    }
    const query = source[candidate.replace_start..candidate.replace_end];
    const rank = candidateMatchRank(candidate, query, policy);
    return .{
        .query = query,
        .rank = rank,
        .suppression_reason = if (rank == null) candidateSuppressionReason(candidate, query, policy) else null,
    };
}

pub fn candidateSuppressionReason(candidate: Candidate, query: []const u8, policy: MatcherPolicy) MatchSuppressionReason {
    if (policy.mode == .prefix) {
        var fuzzy_policy = policy;
        fuzzy_policy.mode = .fuzzy;
        if (candidateMatchRank(candidate, query, fuzzy_policy)) |rank| {
            if (rank == .fuzzy) return .prefix_only;
        }
    }
    return .no_match;
}

pub fn fuzzyMatchRank(text: []const u8, query: []const u8) ?MatchRank {
    return matchRank(text, query, .engineDefault());
}

pub fn matchRank(text: []const u8, query: []const u8, policy: MatcherPolicy) ?MatchRank {
    const input = pathMatchInput(text, query, policy);
    const match_text = input.text;
    const match_query = input.query;
    if (match_query.len == 0) return .prefix;
    if (eqlWithPolicy(match_text, match_query, policy)) return .exact;
    if (startsWithPolicy(match_text, match_query, policy)) return .prefix;
    if (policy.mode == .prefix) return null;

    var text_index: usize = 0;
    for (match_query) |query_byte| {
        var matched = false;
        while (text_index < match_text.len) : (text_index += 1) {
            if (bytesEqual(match_text[text_index], query_byte, policy)) {
                text_index += 1;
                matched = true;
                break;
            }
        }
        if (!matched) return null;
    }
    return .fuzzy;
}

const PathMatchInput = struct {
    text: []const u8,
    query: []const u8,
};

fn pathMatchInput(text: []const u8, query: []const u8, policy: MatcherPolicy) PathMatchInput {
    if (policy.path_segments == .full) return .{ .text = text, .query = query };
    const query_slash = std.mem.lastIndexOfScalar(u8, query, '/') orelse return .{ .text = lastPathSegment(text), .query = query };
    const query_dir = query[0 .. query_slash + 1];
    if (!startsWithPolicy(text, query_dir, policy)) return .{ .text = "", .query = query };
    return .{ .text = text[query_dir.len..], .query = query[query_slash + 1 ..] };
}

fn lastPathSegment(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return path[0..end];
    return path[slash + 1 .. end];
}

fn eqlWithPolicy(a: []const u8, b: []const u8, policy: MatcherPolicy) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (!bytesEqual(a_byte, b_byte, policy)) return false;
    }
    return true;
}

fn startsWithPolicy(text: []const u8, query: []const u8, policy: MatcherPolicy) bool {
    if (query.len > text.len) return false;
    for (text[0..query.len], query) |text_byte, query_byte| {
        if (!bytesEqual(text_byte, query_byte, policy)) return false;
    }
    return true;
}

fn bytesEqual(a: u8, b: u8, policy: MatcherPolicy) bool {
    return normalizeMatchByte(a, policy) == normalizeMatchByte(b, policy);
}

fn normalizeMatchByte(byte: u8, policy: MatcherPolicy) u8 {
    const c = switch (policy.case_sensitivity) {
        .sensitive => byte,
        .insensitive => std.ascii.toLower(byte),
    };
    return switch (policy.separators) {
        .literal => c,
        .hyphen_underscore_equivalent => if (c == '_') '-' else c,
    };
}

pub fn fuzzyMatchPositions(allocator: std.mem.Allocator, text: []const u8, query: []const u8) !?[]usize {
    return matchPositions(allocator, text, query, .engineDefault());
}

pub fn matchPositions(allocator: std.mem.Allocator, text: []const u8, query: []const u8, policy: MatcherPolicy) !?[]usize {
    if (matchRank(text, query, policy) == null) return null;
    var positions: std.ArrayList(usize) = .empty;
    errdefer positions.deinit(allocator);
    if (query.len == 0) return try positions.toOwnedSlice(allocator);

    const input = pathMatchInput(text, query, policy);
    const match_text = input.text;
    const match_query = input.query;
    const offset = @intFromPtr(match_text.ptr) - @intFromPtr(text.ptr);
    var text_index: usize = 0;
    for (match_query) |query_byte| {
        while (text_index < match_text.len) : (text_index += 1) {
            if (bytesEqual(match_text[text_index], query_byte, policy)) {
                try positions.append(allocator, offset + text_index);
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

test "matcher policy controls case sensitivity" {
    const insensitive: MatcherPolicy = .{ .case_sensitivity = .insensitive };
    const sensitive: MatcherPolicy = .{ .case_sensitivity = .sensitive };

    try std.testing.expectEqual(MatchRank.exact, matchRank("Status", "status", insensitive).?);
    try std.testing.expect(matchRank("Status", "status", sensitive) == null);
    try std.testing.expectEqual(MatchRank.prefix, matchRank("Status", "Sta", sensitive).?);
}

test "matcher policy can suppress fuzzy matches for prefix-only mode" {
    const prefix_only = MatcherPolicy.prefixOnly();
    const candidate: Candidate = .{ .value = "git checkout", .replace_start = 0, .replace_end = 3 };

    try std.testing.expectEqual(MatchRank.fuzzy, candidateMatchRank(candidate, "gco", .engineDefault()).?);
    try std.testing.expect(candidateMatchRank(candidate, "gco", prefix_only) == null);
    try std.testing.expectEqual(MatchSuppressionReason.prefix_only, candidateSuppressionReason(candidate, "gco", prefix_only));
}

test "matcher policy treats hyphen and underscore as equivalent by default" {
    try std.testing.expectEqual(MatchRank.prefix, fuzzyMatchRank("feature-branch", "feature_").?);
    try std.testing.expectEqual(MatchRank.exact, fuzzyMatchRank("feature-branch", "feature_branch").?);

    const literal: MatcherPolicy = .{ .separators = .literal };
    try std.testing.expect(matchRank("feature-branch", "feature_", literal) == null);
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

test "application filtering uses display-label matches" {
    const source = "git gco";
    const candidates = [_]Candidate{
        .{ .value = "checkout", .display = "git checkout", .replace_start = 4, .replace_end = 7 },
        .{ .value = "status", .replace_start = 4, .replace_end = 7 },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("checkout", edit.replacement);
}

test "matcher policy supports path-segment matches" {
    const full: MatcherPolicy = .{ .mode = .prefix };
    const last_segment: MatcherPolicy = .{ .mode = .prefix, .path_segments = .last };

    try std.testing.expect(matchRank("src/completion.zig", "completion", full) == null);
    try std.testing.expectEqual(MatchRank.prefix, matchRank("src/completion.zig", "completion", last_segment).?);
    try std.testing.expectEqual(MatchRank.prefix, matchRank("src/completion.zig", "src/com", last_segment).?);
    try std.testing.expect(matchRank("src/completion.zig", "lib/com", last_segment) == null);
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
