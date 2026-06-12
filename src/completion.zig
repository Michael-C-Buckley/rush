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
    insert: ?[]const u8 = null,
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
    exclusive_group: ?[]const u8 = null,
    repeatable: bool = false,
    terminates_options: bool = false,
    no_space: bool = false,
};

pub const Argument = struct {
    state: ?[]const u8 = null,
    index: ?usize = null,
    after_state: ?[]const u8 = null,
    after_value: ?[]const u8 = null,
    repeatable: bool = false,

    pub fn hasSelector(self: Argument) bool {
        return self.state != null or self.index != null or self.after_state != null or self.after_value != null or self.repeatable;
    }
};

pub const ValueGrammar = struct {
    list_separator: ?u8 = null,
    key_prefix: ?u8 = null,
    key_value_separator: ?u8 = null,

    pub fn isEmpty(self: ValueGrammar) bool {
        return self.list_separator == null and self.key_prefix == null and self.key_value_separator == null;
    }
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
    companion_path: ?[]const u8 = null,
};

pub const ProviderKind = enum {
    function,
    builtin_files,
    builtin_directories,
    builtin_executables,
    builtin_variables,
};

pub const Rule = struct {
    root: []const u8,
    path: []const []const u8 = &.{},
    kind: RuleKind,
    value: ?[]const u8 = null,
    provider_kind: ProviderKind = .function,
    option: Option = .{},
    argument: Argument = .{},
    value_grammar: ValueGrammar = .{},
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
    if (candidate.insert) |insert| allocator.free(insert);
    if (candidate.description) |description| allocator.free(description);
    if (candidate.option) |option| {
        if (option.long) |long| allocator.free(long);
        if (option.short) |short| allocator.free(short);
        if (option.argument) |argument| allocator.free(argument);
        if (option.exclusive_group) |group| allocator.free(group);
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
            .replacement = try allocator.dupe(u8, candidateInsertText(candidates[0])),
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
    defer freeTemporaryCandidates(allocator, exact_matches.items);
    var prefix_matches: std.ArrayList(Candidate) = .empty;
    defer prefix_matches.deinit(allocator);
    defer freeTemporaryCandidates(allocator, prefix_matches.items);
    var fuzzy_matches: std.ArrayList(Candidate) = .empty;
    defer fuzzy_matches.deinit(allocator);
    defer freeTemporaryCandidates(allocator, fuzzy_matches.items);
    for (candidates) |candidate| {
        std.debug.assert(candidate.replace_start <= candidate.replace_end);
        std.debug.assert(candidate.replace_end <= source.len);
        const prefix = try candidateQueryForInput(allocator, source, candidate);
        defer allocator.free(prefix);
        if (candidateMatchRank(candidate, prefix, policy)) |rank| {
            var insert_candidate = candidate;
            insert_candidate.insert = try candidateReplacementForInput(allocator, source, candidate);
            errdefer allocator.free(insert_candidate.insert.?);
            switch (rank) {
                .exact => try exact_matches.append(allocator, insert_candidate),
                .prefix => try prefix_matches.append(allocator, insert_candidate),
                .fuzzy => try fuzzy_matches.append(allocator, insert_candidate),
            }
        }
    }
    try matches.appendSlice(allocator, exact_matches.items);
    try matches.appendSlice(allocator, prefix_matches.items);
    try matches.appendSlice(allocator, fuzzy_matches.items);

    return applyCandidates(allocator, matches.items);
}

fn freeTemporaryCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| {
        if (candidate.insert) |insert| allocator.free(insert);
    }
}

pub fn candidateInsertText(candidate: Candidate) []const u8 {
    return candidate.insert orelse candidate.value;
}

pub fn candidateQueryForInput(allocator: std.mem.Allocator, source: []const u8, candidate: Candidate) ![]const u8 {
    std.debug.assert(candidate.replace_start <= candidate.replace_end);
    std.debug.assert(candidate.replace_end <= source.len);
    return decodeShellCompletionSlice(allocator, source, candidate.replace_start, candidate.replace_end);
}

pub fn candidateReplacementForInput(allocator: std.mem.Allocator, source: []const u8, candidate: Candidate) ![]const u8 {
    std.debug.assert(candidate.replace_start <= candidate.replace_end);
    std.debug.assert(candidate.replace_end <= source.len);
    return encodeShellCompletionReplacement(allocator, source, candidate.replace_start, candidate.replace_end, candidate.value, candidate.append_space);
}

pub fn decodeShellWordForCompletion(allocator: std.mem.Allocator, word: []const u8) ![]const u8 {
    return decodeShellCompletionSlice(allocator, word, 0, word.len);
}

const ShellQuote = enum {
    unquoted,
    single,
    double,
};

const ShellCompletionContext = struct {
    quote: ShellQuote,
    opening_quote: ?u8 = null,
};

fn shellCompletionContext(source: []const u8, replace_start: usize) ShellCompletionContext {
    var quote: ShellQuote = .unquoted;
    var index: usize = 0;
    while (index < replace_start) : (index += 1) {
        const byte = source[index];
        switch (quote) {
            .unquoted => {
                if (byte == '\\') {
                    if (index + 1 < replace_start) index += 1;
                } else if (byte == '\'') {
                    quote = .single;
                } else if (byte == '"') {
                    quote = .double;
                }
            },
            .single => {
                if (byte == '\'') quote = .unquoted;
            },
            .double => {
                if (byte == '\\') {
                    if (index + 1 < replace_start and isDoubleQuoteEscapable(source[index + 1])) index += 1;
                } else if (byte == '"') {
                    quote = .unquoted;
                }
            },
        }
    }
    if (quote == .unquoted and replace_start < source.len) {
        if (source[replace_start] == '\'') return .{ .quote = .single, .opening_quote = '\'' };
        if (source[replace_start] == '"') return .{ .quote = .double, .opening_quote = '"' };
    }
    return .{ .quote = quote };
}

fn decodeShellCompletionSlice(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize) ![]const u8 {
    const context = shellCompletionContext(source, start);
    var quote = context.quote;
    var index = start;
    if (context.opening_quote != null and index < end) index += 1;

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);
    while (index < end) : (index += 1) {
        const byte = source[index];
        switch (quote) {
            .unquoted => {
                if (byte == '\\' and index + 1 < end) {
                    index += 1;
                    try decoded.append(allocator, source[index]);
                } else if (byte == '\'') {
                    quote = .single;
                } else if (byte == '"') {
                    quote = .double;
                } else {
                    try decoded.append(allocator, byte);
                }
            },
            .single => {
                if (byte == '\'') {
                    quote = .unquoted;
                } else {
                    try decoded.append(allocator, byte);
                }
            },
            .double => {
                if (byte == '"') {
                    quote = .unquoted;
                } else if (byte == '\\' and index + 1 < end and isDoubleQuoteEscapable(source[index + 1])) {
                    index += 1;
                    try decoded.append(allocator, source[index]);
                } else {
                    try decoded.append(allocator, byte);
                }
            },
        }
    }
    return decoded.toOwnedSlice(allocator);
}

fn encodeShellCompletionReplacement(allocator: std.mem.Allocator, source: []const u8, replace_start: usize, replace_end: usize, value: []const u8, append_space: bool) ![]const u8 {
    const context = shellCompletionContext(source, replace_start);
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);
    if (context.opening_quote) |quote| try encoded.append(allocator, quote);
    try appendShellEscapedValue(allocator, &encoded, context.quote, value);
    if (append_space and shouldCloseQuoteForCompletion(source, replace_end, context.quote, context.opening_quote != null)) {
        try encoded.append(allocator, switch (context.quote) {
            .unquoted => unreachable,
            .single => '\'',
            .double => '"',
        });
    }
    return encoded.toOwnedSlice(allocator);
}

fn appendShellEscapedValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), quote: ShellQuote, value: []const u8) !void {
    switch (quote) {
        .unquoted => {
            for (value, 0..) |byte, index| {
                if (needsUnquotedEscape(byte, index)) try out.append(allocator, '\\');
                try out.append(allocator, byte);
            }
        },
        .single => {
            for (value) |byte| {
                if (byte == '\'') {
                    try out.appendSlice(allocator, "'\\''");
                } else {
                    try out.append(allocator, byte);
                }
            }
        },
        .double => {
            for (value) |byte| {
                if (isDoubleQuoteEscapable(byte) and byte != '\n') try out.append(allocator, '\\');
                try out.append(allocator, byte);
            }
        },
    }
}

fn needsUnquotedEscape(byte: u8, index: usize) bool {
    if (std.ascii.isWhitespace(byte)) return true;
    if (index == 0 and byte == '~') return true;
    return switch (byte) {
        '\\', '\'', '"', '`', '$', '&', '|', ';', '<', '>', '(', ')', '[', ']', '{', '}', '*', '?', '!', '#' => true,
        else => false,
    };
}

fn isDoubleQuoteEscapable(byte: u8) bool {
    return switch (byte) {
        '$', '`', '"', '\\', '\n' => true,
        else => false,
    };
}

fn shouldCloseQuoteForCompletion(source: []const u8, replace_end: usize, quote: ShellQuote, opened_at_replacement: bool) bool {
    _ = source;
    _ = replace_end;
    _ = opened_at_replacement;
    return quote != .unquoted;
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
    if (candidate.insert) |insert| cloned.insert = try allocator.dupe(u8, insert);
    errdefer if (cloned.insert) |insert| allocator.free(insert);
    if (candidate.description) |description| cloned.description = try allocator.dupe(u8, description);
    errdefer if (cloned.description) |description| allocator.free(description);
    if (candidate.option) |option| {
        cloned.option = .{
            .long = if (option.long) |long| try allocator.dupe(u8, long) else null,
            .short = if (option.short) |short| try allocator.dupe(u8, short) else null,
            .argument = if (option.argument) |argument| try allocator.dupe(u8, argument) else null,
            .exclusive_group = if (option.exclusive_group) |group| try allocator.dupe(u8, group) else null,
            .repeatable = option.repeatable,
            .terminates_options = option.terminates_options,
            .no_space = option.no_space,
        };
    }
    errdefer if (cloned.option) |option| {
        if (option.long) |long| allocator.free(long);
        if (option.short) |short| allocator.free(short);
        if (option.argument) |argument| allocator.free(argument);
        if (option.exclusive_group) |group| allocator.free(group);
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

test "application escapes unquoted completion replacements" {
    const source = "cat two";
    const candidates = [_]Candidate{.{ .value = "two words&[x]*", .replace_start = 4, .replace_end = source.len }};
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("two\\ words\\&\\[x\\]\\*", edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "application preserves quote context when inserting completions" {
    const double_source = "cat \"two";
    const double_candidates = [_]Candidate{.{ .value = "two words$HOME", .replace_start = 4, .replace_end = double_source.len }};
    const double_application = try applyCandidatesForInput(std.testing.allocator, double_source, &double_candidates);
    defer double_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"two words\\$HOME\"", double_application.edit.replacement);
    try std.testing.expect(double_application.edit.append_space);

    const single_source = "cat 'two";
    const single_candidates = [_]Candidate{.{ .value = "two words", .replace_start = 4, .replace_end = single_source.len }};
    const single_application = try applyCandidatesForInput(std.testing.allocator, single_source, &single_candidates);
    defer single_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("'two words'", single_application.edit.replacement);
    try std.testing.expect(single_application.edit.append_space);
}

test "application decodes escaped prefixes before matching and reinserts escaped text" {
    const source = "cat two\\ w";
    const candidates = [_]Candidate{.{ .value = "two words", .replace_start = 4, .replace_end = source.len }};
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("two\\ words", edit.replacement);
}

test "application escapes tilde and keeps directory completions open" {
    const tilde_source = "cat ~li";
    const tilde_candidates = [_]Candidate{.{ .value = "~literal?", .replace_start = 4, .replace_end = tilde_source.len }};
    const tilde_application = try applyCandidatesForInput(std.testing.allocator, tilde_source, &tilde_candidates);
    defer tilde_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\\~literal\\?", tilde_application.edit.replacement);

    const dir_source = "cat dir";
    const dir_candidates = [_]Candidate{.{ .value = "dir name/", .kind = .directory, .replace_start = 4, .replace_end = dir_source.len, .append_space = false }};
    const dir_application = try applyCandidatesForInput(std.testing.allocator, dir_source, &dir_candidates);
    defer dir_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dir\\ name/", dir_application.edit.replacement);
    try std.testing.expect(!dir_application.edit.append_space);
}

test "ambiguous application keeps display values separate from insertion text" {
    const source = "cat two\\ w";
    const candidates = [_]Candidate{
        .{ .value = "two ways", .display = "first", .replace_start = 4, .replace_end = source.len },
        .{ .value = "two words", .display = "second", .replace_start = 4, .replace_end = source.len },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("first", application.ambiguous[0].display.?);
    try std.testing.expectEqualStrings("two\\ ways", application.ambiguous[0].insert.?);
    try std.testing.expectEqualStrings("second", application.ambiguous[1].display.?);
    try std.testing.expectEqualStrings("two\\ words", application.ambiguous[1].insert.?);
}
