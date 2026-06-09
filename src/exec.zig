//! Minimal command execution for lowered shell IR.

const std = @import("std");
const zig_builtin = @import("builtin");
const compat = @import("compat.zig");
const completion = @import("completion.zig");
const expand = @import("expand.zig");
const ir = @import("ir.zig");
const parser = @import("parser.zig");
const vaxis = @import("vaxis");

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn fork() std.c.pid_t;
extern "c" fn pause() c_int;

var pending_trap_signal: std.atomic.Value(u8) = .init(0);

pub const ExitStatus = u8;

pub const ExternalStdio = enum {
    capture,
    capture_stdout,
    inherit,
};

pub const ExecuteOptions = struct {
    io: ?std.Io = null,
    allow_external: bool = false,
    features: compat.Features = .{},
    external_stdio: ExternalStdio = .capture,
    arg_zero: []const u8 = "rush",
    source_path: ?[]const u8 = null,
    suppress_functions: bool = false,
    suppress_errexit: bool = false,
    default_path_lookup: bool = false,
};

pub const ShellOptions = struct {
    pipefail: bool = false,
    noglob: bool = false,
    noclobber: bool = false,
    nounset: bool = false,
    errexit: bool = false,
    xtrace: bool = false,
    verbose: bool = false,
    allexport: bool = false,
};

pub const CommandResult = struct {
    allocator: std.mem.Allocator,
    status: ExitStatus,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const PromptBuilder = struct {
    text: std.ArrayList(u8) = .empty,
    used: bool = false,

    pub fn deinit(self: *PromptBuilder, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *PromptBuilder) void {
        self.text.clearRetainingCapacity();
        self.used = false;
    }

    pub fn appendText(self: *PromptBuilder, allocator: std.mem.Allocator, args: []const ir.WordRef) !void {
        for (args, 0..) |arg, index| {
            if (index > 0) try self.text.append(allocator, ' ');
            try self.text.appendSlice(allocator, arg.text);
        }
        self.used = true;
    }

    pub fn appendSegment(self: *PromptBuilder, allocator: std.mem.Allocator, style: PromptStyle, args: []const ir.WordRef) !void {
        try self.appendAnsiAttributes(allocator, style);
        try self.appendAnsiColor(allocator, .fg, style.fg);
        try self.appendAnsiColor(allocator, .bg, style.bg);
        try self.appendText(allocator, args);
        if (style.hasStyle()) try self.text.appendSlice(allocator, "\x1b[0m");
    }

    fn appendAnsiAttributes(self: *PromptBuilder, allocator: std.mem.Allocator, style: PromptStyle) !void {
        if (style.bold) try self.text.appendSlice(allocator, "\x1b[1m");
        if (style.dim) try self.text.appendSlice(allocator, "\x1b[2m");
        if (style.italic) try self.text.appendSlice(allocator, "\x1b[3m");
        if (style.underline) try self.text.appendSlice(allocator, "\x1b[4m");
        if (style.blink) try self.text.appendSlice(allocator, "\x1b[5m");
        if (style.reverse) try self.text.appendSlice(allocator, "\x1b[7m");
        if (style.strikethrough) try self.text.appendSlice(allocator, "\x1b[9m");
    }

    fn appendAnsiColor(self: *PromptBuilder, allocator: std.mem.Allocator, kind: enum { fg, bg }, color: vaxis.Color) !void {
        switch (color) {
            .default => {},
            .index => |index| {
                const sequence = switch (kind) {
                    .fg => try std.fmt.allocPrint(allocator, "\x1b[38;5;{d}m", .{index}),
                    .bg => try std.fmt.allocPrint(allocator, "\x1b[48;5;{d}m", .{index}),
                };
                defer allocator.free(sequence);
                try self.text.appendSlice(allocator, sequence);
            },
            .rgb => |rgb| {
                const sequence = switch (kind) {
                    .fg => try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] }),
                    .bg => try std.fmt.allocPrint(allocator, "\x1b[48;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] }),
                };
                defer allocator.free(sequence);
                try self.text.appendSlice(allocator, sequence);
            },
        }
    }
};

pub const CompletionBuilder = struct {
    candidates: std.ArrayList(completion.Candidate) = .empty,
    owned: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *CompletionBuilder, allocator: std.mem.Allocator) void {
        for (self.owned.items) |value| allocator.free(value);
        self.owned.deinit(allocator);
        self.candidates.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendCandidate(self: *CompletionBuilder, allocator: std.mem.Allocator, candidate: completion.Candidate) !void {
        var owned_candidate = candidate;
        owned_candidate.value = try self.dupeField(allocator, candidate.value);
        if (candidate.display) |display| owned_candidate.display = try self.dupeField(allocator, display);
        if (candidate.description) |description| owned_candidate.description = try self.dupeField(allocator, description);
        if (candidate.option) |option| {
            owned_candidate.option = .{
                .long = if (option.long) |long| try self.dupeField(allocator, long) else null,
                .short = if (option.short) |short| try self.dupeField(allocator, short) else null,
                .argument = if (option.argument) |argument| try self.dupeField(allocator, argument) else null,
                .no_space = option.no_space,
            };
        }
        try self.candidates.append(allocator, owned_candidate);
    }

    pub fn appendCandidateIfMissing(self: *CompletionBuilder, allocator: std.mem.Allocator, candidate: completion.Candidate) !void {
        if (self.containsCandidate(candidate)) return;
        try self.appendCandidate(allocator, candidate);
    }

    fn containsCandidate(self: CompletionBuilder, candidate: completion.Candidate) bool {
        for (self.candidates.items) |existing| {
            if (completionCandidateIdentityMatches(existing, candidate)) return true;
        }
        return false;
    }

    fn dupeField(self: *CompletionBuilder, allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);
        try self.owned.append(allocator, owned);
        return owned;
    }

    pub fn finish(self: *CompletionBuilder, allocator: std.mem.Allocator) ![]completion.Candidate {
        const candidates = try self.candidates.toOwnedSlice(allocator);
        completion.sortCandidates(candidates);
        self.owned.deinit(allocator);
        self.* = undefined;
        return candidates;
    }
};

pub const CompletionEvalContext = struct {
    prefix: []const u8 = "",
    command: []const u8 = "",
    command_path: []const u8 = "",
    argument_index: usize = 0,
    previous: []const u8 = "",
    position: parser.CompletionKind = .command,
    option_value: ?CompletionOptionValue = null,
    replace_start: usize = 0,
    replace_end: usize = 0,
};

pub const CompletionOptionValue = struct {
    name: []const u8,
    spelling: []const u8,
};

pub const CompletionSemanticPosition = enum {
    command,
    subcommand,
    option,
    option_value,
    argument,
};

pub const CompletionSemanticContext = struct {
    allocator: std.mem.Allocator,
    root: []const u8 = "",
    path: []const []const u8 = &.{},
    prefix: []const u8 = "",
    previous: []const u8 = "",
    position: CompletionSemanticPosition = .command,
    option_value: ?CompletionOptionValue = null,
    replace_start: usize = 0,
    replace_end: usize = 0,
    suspicious_start: ?usize = null,
    suspicious_end: ?usize = null,

    pub fn deinit(self: *CompletionSemanticContext) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const CompletionDiagnosticSeverity = enum {
    warning,
    err,
};

pub const CompletionDiagnosticKind = enum {
    unknown_command,
    unknown_subcommand,
    unknown_option,
    missing_option_value,
};

pub const CompletionDiagnostic = struct {
    kind: CompletionDiagnosticKind,
    severity: CompletionDiagnosticSeverity,
    start: usize,
    end: usize,
    message: []const u8,
};

const builtin_names = [_][]const u8{
    ".",
    ":",
    "alias",
    "bg",
    "break",
    "true",
    "false",
    "echo",
    "cat",
    "command",
    "complete",
    "continue",
    "cd",
    "printf",
    "pwd",
    "read",
    "readonly",
    "return",
    "shift",
    "export",
    "getopts",
    "fg",
    "jobs",
    "unset",
    "env",
    "eval",
    "exec",
    "exit",
    "set",
    "source",
    "test",
    "times",
    "trap",
    "umask",
    "unalias",
    "wait",
    "[",
};

fn appendRootCommandCandidate(
    allocator: std.mem.Allocator,
    builder: *CompletionBuilder,
    seen: *std.StringHashMapUnmanaged(void),
    name: []const u8,
    kind: completion.Kind,
    description: []const u8,
    context: CompletionEvalContext,
) !void {
    if (completion.fuzzyMatchRank(name, context.prefix) == null) return;
    if (seen.contains(name)) return;
    const seen_name = try allocator.dupe(u8, name);
    errdefer allocator.free(seen_name);
    try seen.put(allocator, seen_name, {});
    try builder.appendCandidate(allocator, .{
        .value = name,
        .description = description,
        .kind = kind,
        .replace_start = context.replace_start,
        .replace_end = context.replace_end,
    });
}

fn freeCompletionRule(allocator: std.mem.Allocator, rule: completion.Rule) void {
    allocator.free(rule.root);
    for (rule.path) |segment| allocator.free(segment);
    allocator.free(rule.path);
    if (rule.value) |value| allocator.free(value);
    if (rule.option.long) |long| allocator.free(long);
    if (rule.option.short) |short| allocator.free(short);
    if (rule.option.argument) |argument| allocator.free(argument);
    if (rule.description) |description| allocator.free(description);
}

const MatchedCompletionOption = struct {
    takes_value: bool,
    attached_value: bool,
    name: []const u8,
    spelling: []const u8,
};

const ShortOptionCluster = struct {
    valid: bool,
    takes_next_value: bool = false,
    unknown_offset: ?usize = null,
};

const AttachedCompletionOptionValue = struct {
    name: []const u8,
    spelling: []const u8,
    value_offset: usize,
};

fn attachedCompletionOptionValue(rules: []const completion.Rule, root: []const u8, path: []const []const u8, word: []const u8) ?AttachedCompletionOptionValue {
    const equals_index = std.mem.indexOfScalar(u8, word, '=') orelse return null;
    if (equals_index == 0) return null;
    const spelling = word[0..equals_index];
    const matched = findCompletionOption(rules, root, path, spelling) orelse return null;
    if (!matched.takes_value) return null;
    return .{
        .name = matched.name,
        .spelling = spelling,
        .value_offset = equals_index + 1,
    };
}

fn findCompletionOption(rules: []const completion.Rule, root: []const u8, path: []const []const u8, word: []const u8) ?MatchedCompletionOption {
    for (rules) |rule| {
        if ((rule.kind != .option and rule.kind != .dynamic_option_value) or !completionRuleContextMatches(rule, root, path)) continue;
        const takes_value = rule.option.argument != null or rule.kind == .dynamic_option_value;
        if (rule.option.long) |long| {
            var spelling_buffer: [256]u8 = undefined;
            const spelling = std.fmt.bufPrint(&spelling_buffer, "--{s}", .{long}) catch return null;
            if (std.mem.eql(u8, word, spelling)) return .{ .takes_value = takes_value, .attached_value = false, .name = long, .spelling = word };
            if (takes_value and std.mem.startsWith(u8, word, spelling) and word.len > spelling.len and word[spelling.len] == '=') {
                return .{ .takes_value = true, .attached_value = true, .name = long, .spelling = word[0..spelling.len] };
            }
        }
        if (rule.option.short) |short| {
            var spelling_buffer: [32]u8 = undefined;
            const spelling = std.fmt.bufPrint(&spelling_buffer, "-{s}", .{short}) catch return null;
            if (std.mem.eql(u8, word, spelling)) return .{ .takes_value = takes_value, .attached_value = false, .name = short, .spelling = word };
        }
    }
    return null;
}

fn findShortCompletionOption(rules: []const completion.Rule, root: []const u8, path: []const []const u8, short: u8) ?MatchedCompletionOption {
    for (rules) |rule| {
        if ((rule.kind != .option and rule.kind != .dynamic_option_value) or !completionRuleContextMatches(rule, root, path)) continue;
        const option_short = rule.option.short orelse continue;
        if (option_short.len != 1 or option_short[0] != short) continue;
        const takes_value = rule.option.argument != null or rule.kind == .dynamic_option_value;
        return .{ .takes_value = takes_value, .attached_value = false, .name = option_short, .spelling = option_short };
    }
    return null;
}

fn analyzeShortOptionCluster(rules: []const completion.Rule, root: []const u8, path: []const []const u8, word: []const u8) ?ShortOptionCluster {
    if (!isShortOptionCluster(word)) return null;
    var index: usize = 1;
    while (index < word.len) : (index += 1) {
        const matched = findShortCompletionOption(rules, root, path, word[index]) orelse return .{ .valid = false, .unknown_offset = index };
        if (matched.takes_value) {
            return .{ .valid = true, .takes_next_value = index + 1 == word.len };
        }
    }
    return .{ .valid = true };
}

fn findCompletionSubcommand(rules: []const completion.Rule, root: []const u8, path: []const []const u8, word: []const u8) bool {
    for (rules) |rule| {
        if (rule.kind == .subcommand and completionRuleContextMatches(rule, root, path)) {
            if (rule.value) |value| if (std.mem.eql(u8, value, word)) return true;
        }
    }
    return false;
}

fn completionContextHasSubcommands(rules: []const completion.Rule, root: []const u8, path: []const []const u8) bool {
    for (rules) |rule| {
        if (rule.kind == .subcommand and completionRuleContextMatches(rule, root, path)) return true;
    }
    return false;
}

fn completionSubcommandPrefixMatches(rules: []const completion.Rule, root: []const u8, path: []const []const u8, prefix: []const u8) bool {
    for (rules) |rule| {
        if (rule.kind != .subcommand or !completionRuleContextMatches(rule, root, path)) continue;
        if (rule.value) |value| if (std.mem.startsWith(u8, value, prefix)) return true;
    }
    return false;
}

fn completionOptionPrefixMatches(rules: []const completion.Rule, root: []const u8, path: []const []const u8, prefix: []const u8) bool {
    for (rules) |rule| {
        if (rule.kind != .option or !completionRuleContextAppliesToPath(rule, root, path)) continue;
        if (rule.option.long) |long| {
            var spelling_buffer: [256]u8 = undefined;
            const spelling = std.fmt.bufPrint(&spelling_buffer, "--{s}", .{long}) catch continue;
            if (std.mem.startsWith(u8, spelling, prefix)) return true;
        }
        if (rule.option.short) |short| {
            var spelling_buffer: [32]u8 = undefined;
            const spelling = std.fmt.bufPrint(&spelling_buffer, "-{s}", .{short}) catch continue;
            if (std.mem.startsWith(u8, spelling, prefix)) return true;
        }
    }
    return false;
}

fn completionRuleContextMatches(rule: completion.Rule, root: []const u8, path: []const []const u8) bool {
    if (!std.mem.eql(u8, rule.root, root) or rule.path.len != path.len) return false;
    for (rule.path, path) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return false;
    }
    return true;
}

fn completionRuleContextAppliesToPath(rule: completion.Rule, root: []const u8, path: []const []const u8) bool {
    if (!std.mem.eql(u8, rule.root, root) or rule.path.len > path.len) return false;
    for (rule.path, path[0..rule.path.len]) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return false;
    }
    return true;
}

fn completionDynamicRuleMatches(rule: completion.Rule, context: CompletionSemanticContext) bool {
    return switch (rule.kind) {
        .dynamic_subcommands => context.position == .subcommand and completionRuleContextMatches(rule, context.root, context.path),
        .dynamic_options => context.position == .option and completionRuleContextAppliesToPath(rule, context.root, context.path),
        .dynamic_argument => (context.position == .subcommand or context.position == .argument) and completionRuleContextMatches(rule, context.root, context.path),
        .dynamic_option_value => context.position == .option_value and completionRuleContextMatches(rule, context.root, context.path) and completionOptionValueMatches(rule, context.option_value),
        else => false,
    };
}

fn completionOptionValueMatches(rule: completion.Rule, option_value: ?CompletionOptionValue) bool {
    const active = option_value orelse return false;
    if (rule.option.long) |long| if (std.mem.eql(u8, active.name, long)) return true;
    if (rule.option.short) |short| if (std.mem.eql(u8, active.name, short)) return true;
    return rule.option.long == null and rule.option.short == null;
}

// Completion candidates are deduplicated by the edit they would apply:
// replacement span plus inserted value. The first source wins so metadata stays
// deterministic across static and dynamic structured rules.
fn completionCandidateIdentityMatches(a: completion.Candidate, b: completion.Candidate) bool {
    return a.replace_start == b.replace_start and
        a.replace_end == b.replace_end and
        std.mem.eql(u8, a.value, b.value);
}

fn completionCommandPath(allocator: std.mem.Allocator, context: CompletionSemanticContext) ![]const u8 {
    if (context.root.len == 0) return allocator.alloc(u8, 0);
    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(allocator);
    try path.appendSlice(allocator, context.root);
    for (context.path) |segment| {
        try path.append(allocator, ' ');
        try path.appendSlice(allocator, segment);
    }
    return path.toOwnedSlice(allocator);
}

fn isOptionLike(word: []const u8) bool {
    return word.len > 1 and word[0] == '-';
}

fn isShortOptionCluster(word: []const u8) bool {
    return word.len > 2 and word[0] == '-' and word[1] != '-';
}

fn deinitSeenCompletionNames(allocator: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void)) void {
    var iter = seen.iterator();
    while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
    seen.deinit(allocator);
}

const PromptStyle = struct {
    fg: vaxis.Color = .default,
    bg: vaxis.Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,

    fn hasStyle(self: PromptStyle) bool {
        return self.fg != .default or
            self.bg != .default or
            self.bold or
            self.dim or
            self.italic or
            self.underline or
            self.blink or
            self.reverse or
            self.strikethrough;
    }
};

pub const LoopControlKind = enum {
    break_loop,
    continue_loop,
};

pub const LoopControl = struct {
    kind: LoopControlKind,
    levels: usize,
};

pub const PositionalParams = struct {
    params: [][]const u8 = &.{},
    count: []const u8 = "0",
    joined: []const u8 = "",
    owned: bool = false,

    pub fn set(self: *PositionalParams, allocator: std.mem.Allocator, args: []const []const u8) !void {
        self.deinit(allocator);
        var params = try allocator.alloc([]const u8, args.len);
        errdefer allocator.free(params);
        var initialized: usize = 0;
        errdefer for (params[0..initialized]) |param| allocator.free(param);
        for (args, 0..) |arg, index| {
            params[index] = try allocator.dupe(u8, arg);
            initialized += 1;
        }
        const count = try std.fmt.allocPrint(allocator, "{d}", .{args.len});
        errdefer allocator.free(count);
        const joined = try joinParams(allocator, params);
        errdefer allocator.free(joined);
        self.* = .{ .params = params, .count = count, .joined = joined, .owned = true };
    }

    pub fn rebuildDerived(self: *PositionalParams, allocator: std.mem.Allocator) !void {
        if (self.owned) {
            allocator.free(self.count);
            allocator.free(self.joined);
        }
        self.count = try std.fmt.allocPrint(allocator, "{d}", .{self.params.len});
        self.joined = try joinParams(allocator, self.params);
        self.owned = true;
    }

    pub fn deinit(self: *PositionalParams, allocator: std.mem.Allocator) void {
        if (self.owned) {
            for (self.params) |param| allocator.free(param);
            allocator.free(self.params);
            allocator.free(self.count);
            allocator.free(self.joined);
        }
        self.* = .{};
    }
};

pub const CallFrame = struct {
    positionals: PositionalParams = .{},

    pub fn deinit(self: *CallFrame, allocator: std.mem.Allocator) void {
        self.positionals.deinit(allocator);
        self.* = undefined;
    }
};

pub const FunctionValue = struct {
    body: []const u8,
    program: ir.Program,
    redirections: []ir.Redirection,

    pub fn deinit(self: *FunctionValue, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.program.deinit();
        freeFunctionValueRedirections(allocator, self.redirections);
        self.* = undefined;
    }
};

fn freeFunctionValueRedirections(allocator: std.mem.Allocator, redirections: []const ir.Redirection) void {
    for (redirections) |redirection| {
        if (redirection.io_number) |word| freeFunctionValueWord(allocator, word);
        if (redirection.target) |word| freeFunctionValueWord(allocator, word);
        if (redirection.here_doc) |text| allocator.free(text);
    }
    allocator.free(redirections);
}

fn freeFunctionValueWord(allocator: std.mem.Allocator, word: ir.WordRef) void {
    allocator.free(word.raw);
    allocator.free(word.text);
}

pub const BackgroundJob = struct {
    id: usize,
    pid: i64,
    command: []const u8,
    child: std.process.Child,
    state: JobState = .running,
    status: ExitStatus = 0,
    saved_termios: ?std.posix.termios = null,
    notified_state: ?JobState = null,
};

pub const JobState = enum {
    running,
    stopped,
    done,
};

pub const ArrayValue = struct {
    values: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ArrayValue, allocator: std.mem.Allocator) void {
        for (self.values.items) |value| allocator.free(value);
        self.values.deinit(allocator);
        self.* = undefined;
    }
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    env: std.StringHashMapUnmanaged([]const u8) = .empty,
    exported: std.StringHashMapUnmanaged(void) = .empty,
    readonly: std.StringHashMapUnmanaged(void) = .empty,
    arrays: std.StringHashMapUnmanaged(ArrayValue) = .empty,
    functions: std.StringHashMapUnmanaged(FunctionValue) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    traps: std.StringHashMapUnmanaged([]const u8) = .empty,
    completion_rules: std.ArrayList(completion.Rule) = .empty,
    completion_generation: u64 = 0,
    loaded_completion_scripts: std.StringHashMapUnmanaged(void) = .empty,
    background_jobs: std.ArrayList(BackgroundJob) = .empty,
    pending_job_notifications: std.ArrayList([]const u8) = .empty,
    next_job_id: usize = 1,
    current_job_id: ?usize = null,
    previous_job_id: ?usize = null,
    open_fds: std.AutoHashMapUnmanaged(std.posix.fd_t, void) = .empty,
    shell_options: ShellOptions = .{},
    global_positionals: PositionalParams = .{},
    call_frames: std.ArrayList(CallFrame) = .empty,
    function_depth: usize = 0,
    pending_return: ?ExitStatus = null,
    loop_depth: usize = 0,
    pending_loop_control: ?LoopControl = null,
    pending_exit: ?ExitStatus = null,
    execution_depth: usize = 0,
    running_exit_trap: bool = false,
    arg_zero: []const u8 = "rush",
    last_status_text: [3]u8 = .{ '0', 0, 0 },
    last_status_text_len: usize = 1,
    lineno_text: [32]u8 = .{ '1', 0 } ++ .{0} ** 30,
    lineno_text_len: usize = 1,
    last_command_duration_text: [32]u8 = .{ '0', 0 } ++ .{0} ** 30,
    last_command_duration_text_len: usize = 1,
    pid_text: [32]u8 = undefined,
    pid_text_len: usize = 0,
    last_background_pid_text: [32]u8 = undefined,
    last_background_pid_text_len: usize = 0,
    prompt_builder: ?PromptBuilder = null,
    completion_builder: ?CompletionBuilder = null,
    completion_context: ?CompletionEvalContext = null,
    last_completion_context: ?CompletionEvalContext = null,
    getopts_offset: usize = 1,
    getopts_last_optind: usize = 1,
    parameter_error: expand.ParameterError = .{},
    command_substitution_status: ?ExitStatus = null,
    script_stdin: ?[]const u8 = null,
    script_stdin_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Executor {
        var executor: Executor = .{ .allocator = allocator };
        executor.setLastStatus(0);
        executor.setPidText();
        return executor;
    }

    pub fn importEnvironment(self: *Executor, environ_map: *const std.process.Environ.Map) !void {
        var iter = environ_map.iterator();
        while (iter.next()) |entry| {
            try self.setEnv(entry.key_ptr.*, entry.value_ptr.*);
            try self.setExported(entry.key_ptr.*);
        }
    }

    pub fn initializeShellVariables(self: *Executor, io: std.Io) !void {
        try self.setEnv("IFS", " \t\n");

        var ppid_buffer: [32]u8 = undefined;
        const ppid = try std.fmt.bufPrint(&ppid_buffer, "{d}", .{std.posix.getppid()});
        try self.setEnv("PPID", ppid);

        if (self.getEnv("PWD")) |pwd| {
            if (try self.validLogicalPwd(io, pwd)) return;
        }
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        try self.setEnv("PWD", cwd);
        try self.setExported("PWD");
    }

    pub fn initializeInteractiveVariables(self: *Executor) !void {
        if (self.getEnv("PS1") == null) try self.setEnv("PS1", "$ ");
        if (self.getEnv("PS2") == null) try self.setEnv("PS2", "> ");
    }

    fn validLogicalPwd(self: *Executor, io: std.Io, pwd: []const u8) !bool {
        if (pwd.len == 0 or pwd[0] != '/') return false;
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        return std.mem.eql(u8, pwd, cwd);
    }

    fn physicalCwd(self: *Executor, io: std.Io) ![]u8 {
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        return self.allocator.dupe(u8, cwd);
    }

    fn clearEnvironment(self: *Executor) void {
        var iter = self.env.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.clearRetainingCapacity();
        var exported_iter = self.exported.iterator();
        while (exported_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.exported.clearRetainingCapacity();
    }

    pub fn setLastStatus(self: *Executor, status: ExitStatus) void {
        const text = std.fmt.bufPrint(&self.last_status_text, "{d}", .{status}) catch unreachable;
        self.last_status_text_len = text.len;
    }

    fn lastStatus(self: Executor) ExitStatus {
        return std.fmt.parseInt(ExitStatus, self.last_status_text[0..self.last_status_text_len], 10) catch 0;
    }

    fn setCurrentLineNumber(self: *Executor, source: []const u8, offset: usize) void {
        var line: usize = 1;
        var index: usize = 0;
        const end = @min(offset, source.len);
        while (index < end) : (index += 1) {
            if (source[index] == '\n') line += 1;
        }
        const text = std.fmt.bufPrint(&self.lineno_text, "{d}", .{line}) catch unreachable;
        self.lineno_text_len = text.len;
    }

    pub fn setLastCommandDuration(self: *Executor, duration_ms: i64) void {
        const text = std.fmt.bufPrint(&self.last_command_duration_text, "{d}", .{@max(duration_ms, 0)}) catch unreachable;
        self.last_command_duration_text_len = text.len;
    }

    fn setPidText(self: *Executor) void {
        const pid = shellPid();
        const text = std.fmt.bufPrint(&self.pid_text, "{d}", .{pid}) catch unreachable;
        self.pid_text_len = text.len;
    }

    pub fn deinit(self: *Executor) void {
        var iter = self.env.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.deinit(self.allocator);
        var exported_iter = self.exported.iterator();
        while (exported_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.exported.deinit(self.allocator);
        var readonly_iter = self.readonly.iterator();
        while (readonly_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.readonly.deinit(self.allocator);
        var array_iter = self.arrays.iterator();
        while (array_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.arrays.deinit(self.allocator);
        var function_iter = self.functions.iterator();
        while (function_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.functions.deinit(self.allocator);
        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit(self.allocator);
        var trap_iter = self.traps.iterator();
        while (trap_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.traps.deinit(self.allocator);
        for (self.completion_rules.items) |rule| freeCompletionRule(self.allocator, rule);
        self.completion_rules.deinit(self.allocator);
        var loaded_completion_iter = self.loaded_completion_scripts.iterator();
        while (loaded_completion_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.loaded_completion_scripts.deinit(self.allocator);
        for (self.background_jobs.items) |job| self.allocator.free(job.command);
        self.background_jobs.deinit(self.allocator);
        for (self.pending_job_notifications.items) |notification| self.allocator.free(notification);
        self.pending_job_notifications.deinit(self.allocator);
        self.parameter_error.clear(self.allocator);
        self.open_fds.deinit(self.allocator);
        if (self.prompt_builder) |*builder| builder.deinit(self.allocator);
        if (self.completion_builder) |*builder| builder.deinit(self.allocator);
        self.global_positionals.deinit(self.allocator);
        for (self.call_frames.items) |*frame| frame.deinit(self.allocator);
        self.call_frames.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hasFunction(self: Executor, name: []const u8) bool {
        return self.functions.contains(name);
    }

    pub fn registerCompletionRule(self: *Executor, rule: completion.Rule) !void {
        var owned_rule: completion.Rule = .{
            .root = try self.allocator.dupe(u8, rule.root),
            .kind = rule.kind,
            .value = if (rule.value) |value| try self.allocator.dupe(u8, value) else null,
            .option = .{
                .long = if (rule.option.long) |long| try self.allocator.dupe(u8, long) else null,
                .short = if (rule.option.short) |short| try self.allocator.dupe(u8, short) else null,
                .argument = if (rule.option.argument) |argument| try self.allocator.dupe(u8, argument) else null,
                .no_space = rule.option.no_space,
            },
            .description = if (rule.description) |description| try self.allocator.dupe(u8, description) else null,
        };
        errdefer freeCompletionRule(self.allocator, owned_rule);
        var path: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (path.items) |segment| self.allocator.free(segment);
            path.deinit(self.allocator);
        }
        for (rule.path) |segment| try path.append(self.allocator, try self.allocator.dupe(u8, segment));
        owned_rule.path = try path.toOwnedSlice(self.allocator);
        try self.completion_rules.append(self.allocator, owned_rule);
        self.completion_generation +%= 1;
    }

    pub fn completionGeneration(self: Executor) u64 {
        return self.completion_generation;
    }

    pub fn completionRules(self: Executor) []const completion.Rule {
        return self.completion_rules.items;
    }

    fn completionCommandKnown(self: Executor, command: []const u8, io: ?std.Io) !bool {
        if (builtinFor(command) != null) return true;
        if (self.functions.get(command) != null) return true;
        if (self.aliases.get(command) != null) return true;
        for (self.completion_rules.items) |rule| {
            if (std.mem.eql(u8, rule.root, command)) return true;
        }
        if (try self.completionCommandInPath(command, io)) return true;
        return false;
    }

    fn completionCommandInPath(self: Executor, command: []const u8, maybe_io: ?std.Io) !bool {
        const io = maybe_io orelse return false;
        if (std.mem.indexOfScalar(u8, command, '/') != null) {
            std.Io.Dir.cwd().access(io, command, .{ .execute = true }) catch return false;
            return true;
        }
        const path_value = self.getEnv("PATH") orelse return false;
        var parts = std.mem.splitScalar(u8, path_value, ':');
        while (parts.next()) |part| {
            const dir = if (part.len == 0) "." else part;
            const candidate = try std.mem.concat(self.allocator, u8, &.{ dir, "/", command });
            defer self.allocator.free(candidate);
            std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
            return true;
        }
        return false;
    }

    fn loadCompletionScriptForRoot(self: *Executor, root: []const u8, options: ExecuteOptions) !void {
        const io = options.io orelse return;
        if (root.len == 0 or self.loaded_completion_scripts.contains(root)) return;
        const owned_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(owned_root);
        try self.loaded_completion_scripts.put(self.allocator, owned_root, {});
        const file_name = try rootCompletionFileName(self.allocator, root);
        defer self.allocator.free(file_name);
        if (file_name.len == 0) return;

        if (self.getEnv("XDG_DATA_HOME")) |data_home| {
            if (data_home.len != 0) {
                const path = try std.fs.path.join(self.allocator, &.{ data_home, "rush", "completions", file_name });
                defer self.allocator.free(path);
                if (try self.sourceCompletionScript(io, path, options)) return;
            }
        } else if (self.getEnv("HOME")) |home| {
            if (home.len != 0) {
                const path = try std.fs.path.join(self.allocator, &.{ home, ".local", "share", "rush", "completions", file_name });
                defer self.allocator.free(path);
                if (try self.sourceCompletionScript(io, path, options)) return;
            }
        }

        const data_dirs = self.getEnv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        var dirs = std.mem.splitScalar(u8, data_dirs, ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const path = try std.fs.path.join(self.allocator, &.{ dir, "rush", "completions", file_name });
            defer self.allocator.free(path);
            if (try self.sourceCompletionScript(io, path, options)) return;
        }
    }

    fn rootCompletionFileName(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, root, '/') != null or std.mem.indexOfScalar(u8, root, 0) != null) return allocator.alloc(u8, 0);
        return std.fmt.allocPrint(allocator, "{s}.rush", .{root});
    }

    fn sourceCompletionScript(self: *Executor, io: std.Io, path: []const u8, options: ExecuteOptions) !bool {
        if (path.len == 0) return false;
        const contents = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return false,
        };
        defer self.allocator.free(contents);
        var source_options = options;
        source_options.allow_external = true;
        var result = self.executeScriptSlice(contents, source_options) catch return true;
        defer result.deinit();
        return true;
    }

    pub fn lastCompletionContext(self: Executor) ?CompletionEvalContext {
        return self.last_completion_context;
    }

    pub fn collectCompletionsForInput(self: *Executor, source: []const u8, cursor: usize, options: ExecuteOptions) ![]completion.Candidate {
        var context = try completionEvalContextForInput(self.allocator, source, cursor);
        const completing_parameter = context.position == .parameter;
        const parameter_context = context;
        if (context.command.len != 0) try self.loadCompletionScriptForRoot(context.command, options);
        var semantic = try self.analyzeCompletionsForInput(source, cursor);
        defer semantic.deinit();
        const command_path = try completionCommandPath(self.allocator, semantic);
        defer self.allocator.free(command_path);

        if (semantic.root.len != 0) {
            context.command = semantic.root;
            context.command_path = command_path;
            context.prefix = semantic.prefix;
            context.previous = semantic.previous;
            context.option_value = semantic.option_value;
            context.replace_start = semantic.replace_start;
            context.replace_end = semantic.replace_end;
            context.position = switch (semantic.position) {
                .command => .command,
                .option, .option_value, .subcommand, .argument => .argument,
            };
        }

        if (completing_parameter) {
            return try self.collectParameterCompletions(parameter_context);
        }

        const candidates = try self.collectCompletionsWithContext(context.command, context, options);
        if (semantic.root.len == 0 or semantic.position == .command) return candidates;

        var builder: CompletionBuilder = .{};
        errdefer builder.deinit(self.allocator);
        for (candidates) |candidate| try builder.appendCandidateIfMissing(self.allocator, candidate);
        if (semantic.position != .option_value) try self.appendStructuredCompletionCandidates(&builder, semantic);
        try self.appendDynamicStructuredCompletionCandidates(&builder, context, semantic, options);
        self.freeCompletions(candidates);
        const merged = try builder.finish(self.allocator);
        return merged;
    }

    fn collectParameterCompletions(self: *Executor, context: CompletionEvalContext) ![]completion.Candidate {
        var builder: CompletionBuilder = .{};
        errdefer builder.deinit(self.allocator);
        var iter = self.env.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, context.prefix)) {
                try builder.appendCandidate(self.allocator, .{
                    .value = entry.key_ptr.*,
                    .kind = .variable,
                    .replace_start = context.replace_start,
                    .replace_end = context.replace_end,
                    .append_space = false,
                });
            }
        }
        return try builder.finish(self.allocator);
    }

    pub fn analyzeCompletionsForInput(self: *Executor, source: []const u8, cursor: usize) !CompletionSemanticContext {
        var parsed = try parser.parse(self.allocator, source, .{ .mode = .interactive, .cursor = cursor });
        defer parsed.deinit();
        const parser_context = parser.completionContext(parsed, cursor);
        const clamped_cursor = @min(cursor, source.len);

        var words: std.ArrayList(parser.Token) = .empty;
        defer words.deinit(self.allocator);
        for (parsed.tokens) |token| {
            if (token.span.start > clamped_cursor) break;
            if (token.kind == .word) try words.append(self.allocator, token);
        }

        if (words.items.len == 0) {
            return .{
                .allocator = self.allocator,
                .path = try self.allocator.alloc([]const u8, 0),
                .prefix = completionContextPrefix(source, parser_context),
                .replace_start = parser_context.span.start,
                .replace_end = @min(parser_context.cursor, parser_context.span.end),
            };
        }

        const current_token_index = parser_context.token_index;
        const root = words.items[0].lexeme(source);
        var path: std.ArrayList([]const u8) = .empty;
        errdefer path.deinit(self.allocator);
        var index: usize = 1;
        var previous: []const u8 = "";
        var suspicious: ?parser.Span = null;
        var option_value: ?CompletionOptionValue = null;
        while (index < words.items.len) {
            const token = words.items[index];
            const is_current = current_token_index != null and token.span.start == parsed.tokens[current_token_index.?].span.start and clamped_cursor <= token.span.end;
            if (is_current or token.span.end > clamped_cursor) break;
            const word = token.lexeme(source);
            previous = word;
            if (findCompletionOption(self.completion_rules.items, root, path.items, word)) |matched| {
                if (matched.takes_value and !matched.attached_value) {
                    if (index + 1 < words.items.len) {
                        const value_token = words.items[index + 1];
                        const value_is_current = current_token_index != null and value_token.span.start == parsed.tokens[current_token_index.?].span.start and clamped_cursor <= value_token.span.end;
                        if (!value_is_current and value_token.span.end <= clamped_cursor) {
                            index += 1;
                            previous = value_token.lexeme(source);
                        } else {
                            option_value = .{ .name = matched.name, .spelling = matched.spelling };
                        }
                    } else {
                        option_value = .{ .name = matched.name, .spelling = matched.spelling };
                    }
                }
            } else if (analyzeShortOptionCluster(self.completion_rules.items, root, path.items, word)) |cluster| {
                if (!cluster.valid) {
                    suspicious = token.span;
                } else if (cluster.takes_next_value) {
                    if (index + 1 < words.items.len) {
                        const value_token = words.items[index + 1];
                        const value_is_current = current_token_index != null and value_token.span.start == parsed.tokens[current_token_index.?].span.start and clamped_cursor <= value_token.span.end;
                        if (!value_is_current and value_token.span.end <= clamped_cursor) {
                            index += 1;
                            previous = value_token.lexeme(source);
                        }
                    }
                }
            } else if (isOptionLike(word)) {
                suspicious = token.span;
            } else if (findCompletionSubcommand(self.completion_rules.items, root, path.items, word)) {
                try path.append(self.allocator, word);
            } else {
                break;
            }
            index += 1;
        }

        var prefix = completionContextPrefix(source, parser_context);
        var replace_start = parser_context.span.start;
        if (option_value == null) {
            if (attachedCompletionOptionValue(self.completion_rules.items, root, path.items, prefix)) |attached| {
                option_value = .{ .name = attached.name, .spelling = attached.spelling };
                prefix = prefix[attached.value_offset..];
                replace_start += attached.value_offset;
            }
        }
        const position: CompletionSemanticPosition = if (option_value != null)
            .option_value
        else if (parser_context.kind == .command)
            .command
        else if (std.mem.startsWith(u8, prefix, "-"))
            .option
        else
            .subcommand;
        return .{
            .allocator = self.allocator,
            .root = root,
            .path = try path.toOwnedSlice(self.allocator),
            .prefix = prefix,
            .previous = previous,
            .position = position,
            .option_value = option_value,
            .replace_start = replace_start,
            .replace_end = @min(parser_context.cursor, parser_context.span.end),
            .suspicious_start = if (suspicious) |span| span.start else null,
            .suspicious_end = if (suspicious) |span| span.end else null,
        };
    }

    pub fn completionDiagnosticsForInput(self: *Executor, source: []const u8, cursor: usize) ![]CompletionDiagnostic {
        return self.completionDiagnosticsForInputOptions(source, cursor, .{});
    }

    pub fn completionDiagnosticsForInputOptions(self: *Executor, source: []const u8, cursor: usize, options: ExecuteOptions) ![]CompletionDiagnostic {
        var parsed = try parser.parse(self.allocator, source, .{ .mode = .interactive, .cursor = cursor });
        defer parsed.deinit();
        const clamped_cursor = @min(cursor, source.len);

        var words: std.ArrayList(parser.Token) = .empty;
        defer words.deinit(self.allocator);
        for (parsed.tokens, 0..) |token, token_index| {
            if (token.span.start > clamped_cursor) break;
            if (token.kind != .word) continue;
            switch (parser.nodeKindForToken(parsed, token_index) orelse .word) {
                .assignment_word => {},
                .command_word, .word => try words.append(self.allocator, token),
                else => {},
            }
        }
        if (words.items.len == 0) return self.allocator.alloc(CompletionDiagnostic, 0);

        var diagnostics: std.ArrayList(CompletionDiagnostic) = .empty;
        errdefer diagnostics.deinit(self.allocator);

        const root_token = words.items[0];
        const root = root_token.lexeme(source);
        try self.loadCompletionScriptForRoot(root, options);
        if (root_token.span.end < clamped_cursor and !try self.completionCommandKnown(root, options.io)) {
            try diagnostics.append(self.allocator, .{
                .kind = .unknown_command,
                .severity = .err,
                .start = root_token.span.start,
                .end = root_token.span.end,
                .message = "unknown command",
            });
            return diagnostics.toOwnedSlice(self.allocator);
        }

        var path: std.ArrayList([]const u8) = .empty;
        defer path.deinit(self.allocator);
        var index: usize = 1;
        while (index < words.items.len) : (index += 1) {
            const token = words.items[index];
            if (token.span.end > clamped_cursor) break;
            const word = token.lexeme(source);
            const word_complete = token.span.end < clamped_cursor;
            if (findCompletionOption(self.completion_rules.items, root, path.items, word)) |matched| {
                if (matched.takes_value and !matched.attached_value) {
                    if (index + 1 >= words.items.len or words.items[index + 1].span.start > clamped_cursor) {
                        try diagnostics.append(self.allocator, .{
                            .kind = .missing_option_value,
                            .severity = .warning,
                            .start = token.span.start,
                            .end = token.span.end,
                            .message = "option requires a value",
                        });
                    } else if (words.items[index + 1].span.end <= clamped_cursor) {
                        index += 1;
                    }
                }
            } else if (analyzeShortOptionCluster(self.completion_rules.items, root, path.items, word)) |cluster| {
                if (!cluster.valid) {
                    if (word_complete) {
                        try diagnostics.append(self.allocator, .{
                            .kind = .unknown_option,
                            .severity = .err,
                            .start = token.span.start + (cluster.unknown_offset orelse 0),
                            .end = token.span.end,
                            .message = "unknown option",
                        });
                    }
                } else if (cluster.takes_next_value) {
                    if (index + 1 >= words.items.len or words.items[index + 1].span.start > clamped_cursor) {
                        try diagnostics.append(self.allocator, .{
                            .kind = .missing_option_value,
                            .severity = .warning,
                            .start = token.span.start,
                            .end = token.span.end,
                            .message = "option requires a value",
                        });
                    } else if (words.items[index + 1].span.end <= clamped_cursor) {
                        index += 1;
                    }
                }
            } else if (isOptionLike(word)) {
                if (word_complete and !completionOptionPrefixMatches(self.completion_rules.items, root, path.items, word)) {
                    try diagnostics.append(self.allocator, .{
                        .kind = .unknown_option,
                        .severity = .err,
                        .start = token.span.start,
                        .end = token.span.end,
                        .message = "unknown option",
                    });
                }
            } else if (findCompletionSubcommand(self.completion_rules.items, root, path.items, word)) {
                try path.append(self.allocator, word);
            } else if (completionContextHasSubcommands(self.completion_rules.items, root, path.items)) {
                if (word_complete and !completionSubcommandPrefixMatches(self.completion_rules.items, root, path.items, word)) {
                    try diagnostics.append(self.allocator, .{
                        .kind = .unknown_subcommand,
                        .severity = .err,
                        .start = token.span.start,
                        .end = token.span.end,
                        .message = "unknown subcommand",
                    });
                }
                break;
            } else {
                break;
            }
        }

        return diagnostics.toOwnedSlice(self.allocator);
    }

    pub fn collectCompletionsWithContext(self: *Executor, command: []const u8, context: CompletionEvalContext, options: ExecuteOptions) ![]completion.Candidate {
        if (context.position == .command) return self.collectRootCommandCompletions(context, options);
        _ = command;
        return self.allocator.alloc(completion.Candidate, 0);
    }

    fn collectCompletionsFromFunction(self: *Executor, function: []const u8, command: []const u8, context: CompletionEvalContext, options: ExecuteOptions) ![]completion.Candidate {
        const function_value = self.functions.getPtr(function) orelse return self.allocator.alloc(completion.Candidate, 0);
        if (self.completion_builder != null) return error.RecursiveCompletion;
        self.completion_builder = .{};
        self.completion_context = context;
        errdefer {
            self.completion_builder.?.deinit(self.allocator);
            self.completion_builder = null;
            self.completion_context = null;
        }

        var argv = [_]ir.WordRef{
            .{ .raw = function, .text = function, .span = .{ .start = 0, .end = 0 } },
            .{ .raw = command, .text = command, .span = .{ .start = 0, .end = 0 } },
        };
        const call: ir.SimpleCommand = .{ .span = .{ .start = 0, .end = 0 }, .assignments = &.{}, .argv = &argv, .redirections = &.{} };
        var completion_options = options;
        completion_options.external_stdio = .capture;
        var result = try self.executeFunctionBody(call, function_value, completion_options);
        defer result.deinit();

        var builder = self.completion_builder.?;
        self.completion_builder = null;
        errdefer builder.deinit(self.allocator);
        const final_context = self.completion_context orelse context;
        self.last_completion_context = final_context;
        for (builder.candidates.items) |*candidate| {
            if (candidate.replace_start == 0 and candidate.replace_end == 0) {
                candidate.replace_start = final_context.replace_start;
                candidate.replace_end = final_context.replace_end;
            }
        }
        self.completion_context = null;

        var deduplicated: CompletionBuilder = .{};
        errdefer deduplicated.deinit(self.allocator);
        for (builder.candidates.items) |candidate| try deduplicated.appendCandidateIfMissing(self.allocator, candidate);
        builder.deinit(self.allocator);
        return deduplicated.finish(self.allocator);
    }

    fn collectRootCommandCompletions(self: *Executor, context: CompletionEvalContext, options: ExecuteOptions) ![]completion.Candidate {
        self.last_completion_context = context;
        var builder: CompletionBuilder = .{};
        errdefer builder.deinit(self.allocator);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer deinitSeenCompletionNames(self.allocator, &seen);

        var alias_iter = self.aliases.iterator();
        while (alias_iter.next()) |entry| {
            try appendRootCommandCandidate(self.allocator, &builder, &seen, entry.key_ptr.*, .command, "alias", context);
        }

        var function_iter = self.functions.iterator();
        while (function_iter.next()) |entry| {
            try appendRootCommandCandidate(self.allocator, &builder, &seen, entry.key_ptr.*, .function, "function", context);
        }

        for (builtin_names) |name| {
            try appendRootCommandCandidate(self.allocator, &builder, &seen, name, .builtin, "builtin", context);
        }

        if (options.io) |io| {
            const path = self.getEnv("PATH") orelse "";
            var path_iter = std.mem.splitScalar(u8, path, ':');
            while (path_iter.next()) |path_dir| {
                if (path_dir.len == 0) continue;
                var dir = std.Io.Dir.cwd().openDir(io, path_dir, .{ .iterate = true }) catch continue;
                errdefer dir.close(io);
                var iterator = dir.iterate();
                while (iterator.next(io) catch null) |entry| {
                    try appendRootCommandCandidate(self.allocator, &builder, &seen, entry.name, .command, "executable", context);
                }
                dir.close(io);
            }
        }

        return builder.finish(self.allocator);
    }

    fn appendStructuredCompletionCandidates(self: *Executor, builder: *CompletionBuilder, context: CompletionSemanticContext) !void {
        for (self.completion_rules.items) |rule| {
            switch (rule.kind) {
                .dynamic_subcommands, .dynamic_options, .dynamic_argument, .dynamic_option_value => {},
                .subcommand => {
                    if (context.position != .subcommand) continue;
                    if (!completionRuleContextMatches(rule, context.root, context.path)) continue;
                    const value = rule.value orelse continue;
                    try self.appendStructuredCompletionCandidate(builder, value, rule.description, .subcommand, null, context, true);
                },
                .option => {
                    if (context.position != .option and !(context.position == .subcommand and context.prefix.len == 0)) continue;
                    if (context.position == .subcommand and context.prefix.len == 0) {
                        if (!completionRuleContextMatches(rule, context.root, context.path)) continue;
                    } else if (!completionRuleContextAppliesToPath(rule, context.root, context.path)) continue;
                    if (rule.option.long) |long| {
                        var spelling_buffer: [256]u8 = undefined;
                        const value = std.fmt.bufPrint(&spelling_buffer, "--{s}", .{long}) catch continue;
                        try self.appendStructuredCompletionCandidate(builder, value, rule.description, .option, rule.option, context, rule.option.argument == null and !rule.option.no_space);
                    }
                    if (rule.option.short) |short| {
                        if (rule.option.long != null and context.prefix.len == 0) continue;
                        var spelling_buffer: [32]u8 = undefined;
                        const value = std.fmt.bufPrint(&spelling_buffer, "-{s}", .{short}) catch continue;
                        try self.appendStructuredCompletionCandidate(builder, value, rule.description, .option, rule.option, context, rule.option.argument == null and !rule.option.no_space);
                    }
                },
            }
        }
    }

    fn appendStructuredCompletionCandidate(
        self: *Executor,
        builder: *CompletionBuilder,
        value: []const u8,
        description: ?[]const u8,
        kind: completion.Kind,
        option: ?completion.Option,
        context: CompletionSemanticContext,
        append_space: bool,
    ) !void {
        if (completion.fuzzyMatchRank(value, context.prefix) == null) return;
        try builder.appendCandidateIfMissing(self.allocator, .{
            .value = value,
            .description = description,
            .kind = kind,
            .option = option,
            .replace_start = context.replace_start,
            .replace_end = context.replace_end,
            .append_space = append_space,
        });
    }

    fn appendDynamicStructuredCompletionCandidates(self: *Executor, builder: *CompletionBuilder, context: CompletionEvalContext, semantic: CompletionSemanticContext, options: ExecuteOptions) !void {
        for (self.completion_rules.items) |rule| {
            if (!completionDynamicRuleMatches(rule, semantic)) continue;
            const function = rule.value orelse continue;
            var provider_context = context;
            provider_context.position = switch (rule.kind) {
                .dynamic_argument => .argument,
                .dynamic_subcommands => .argument,
                .dynamic_options => .argument,
                .dynamic_option_value => .argument,
                else => provider_context.position,
            };
            const candidates = try self.collectCompletionsFromFunction(function, context.command, provider_context, options);
            defer self.freeCompletions(candidates);
            for (candidates) |candidate| {
                try builder.appendCandidateIfMissing(self.allocator, candidate);
            }
        }
    }

    pub fn freeCompletions(self: *Executor, candidates: []completion.Candidate) void {
        for (candidates) |candidate| {
            self.allocator.free(candidate.value);
            if (candidate.display) |display| self.allocator.free(display);
            if (candidate.description) |description| self.allocator.free(description);
            if (candidate.option) |option| {
                if (option.long) |long| self.allocator.free(long);
                if (option.short) |short| self.allocator.free(short);
                if (option.argument) |argument| self.allocator.free(argument);
            }
        }
        self.allocator.free(candidates);
    }

    pub fn freeCompletionDiagnostics(self: *Executor, diagnostics: []CompletionDiagnostic) void {
        self.allocator.free(diagnostics);
    }

    pub fn renderPrompt(self: *Executor, options: ExecuteOptions, fallback: []const u8) ![]const u8 {
        if (!self.hasFunction("rush_prompt")) return self.allocator.dupe(u8, fallback);

        if (self.prompt_builder != null) return error.RecursivePrompt;
        self.prompt_builder = .{};
        errdefer {
            self.prompt_builder.?.deinit(self.allocator);
            self.prompt_builder = null;
        }

        var prompt_options = options;
        prompt_options.external_stdio = .capture;
        var result = try self.executeScriptSlice("rush_prompt", prompt_options);
        defer result.deinit();

        var builder = self.prompt_builder.?;
        self.prompt_builder = null;
        defer builder.deinit(self.allocator);

        if (builder.used) return builder.text.toOwnedSlice(self.allocator);
        return self.allocator.dupe(u8, result.stdout);
    }

    pub fn getEnv(self: Executor, name: []const u8) ?[]const u8 {
        return self.env.get(name);
    }

    fn logicalCwd(self: *Executor, io: std.Io) ![:0]u8 {
        if (self.getEnv("PWD")) |pwd| {
            if (pwd.len > 0 and pwd[0] == '/') return self.allocator.dupeZ(u8, pwd);
        }
        return std.process.currentPathAlloc(io, self.allocator);
    }

    pub fn setArrayElement(self: *Executor, name: []const u8, index: usize, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const result = try self.arrays.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
        } else {
            result.value_ptr.* = .{};
        }
        const array = result.value_ptr;
        while (array.values.items.len <= index) {
            try array.values.append(self.allocator, try self.allocator.alloc(u8, 0));
        }
        self.allocator.free(array.values.items[index]);
        array.values.items[index] = try self.allocator.dupe(u8, value);
    }

    pub fn getArrayElement(self: Executor, name: []const u8, index: usize) ?[]const u8 {
        const array = self.arrays.get(name) orelse return null;
        if (index >= array.values.items.len) return null;
        return array.values.items[index];
    }

    pub fn unsetArray(self: *Executor, name: []const u8) void {
        if (self.arrays.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            var value = entry.value;
            value.deinit(self.allocator);
        }
    }

    pub fn unsetEnv(self: *Executor, name: []const u8) void {
        if (self.isReadonly(name)) return;
        self.unsetExported(name);
        if (self.env.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    fn isExported(self: Executor, name: []const u8) bool {
        return self.exported.contains(name);
    }

    pub fn setExported(self: *Executor, name: []const u8) !void {
        if (self.exported.contains(name)) return;
        try self.exported.put(self.allocator, try self.allocator.dupe(u8, name), {});
    }

    fn unsetExported(self: *Executor, name: []const u8) void {
        if (self.exported.fetchRemove(name)) |entry| self.allocator.free(entry.key);
    }

    fn restoreExported(self: *Executor, name: []const u8, exported: bool) !void {
        if (exported) try self.setExported(name) else self.unsetExported(name);
    }

    fn unsetFunction(self: *Executor, name: []const u8) void {
        if (self.functions.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            var value = entry.value;
            value.deinit(self.allocator);
        }
    }

    pub fn isReadonly(self: Executor, name: []const u8) bool {
        return self.readonly.contains(name);
    }

    pub fn setReadonly(self: *Executor, name: []const u8) !void {
        if (self.readonly.contains(name)) return;
        try self.readonly.put(self.allocator, try self.allocator.dupe(u8, name), {});
    }

    pub fn setEnv(self: *Executor, name: []const u8, value: []const u8) !void {
        if (self.isReadonly(name)) return error.ReadonlyVariable;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const result = try self.env.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.key_ptr.*);
            self.allocator.free(result.value_ptr.*);
            result.key_ptr.* = try self.allocator.dupe(u8, name);
            result.value_ptr.* = owned_value;
        } else {
            result.value_ptr.* = owned_value;
        }
    }

    pub fn executeProgram(self: *Executor, program: ir.Program, options: ExecuteOptions) anyerror!CommandResult {
        const root_execution = self.execution_depth == 0;
        self.execution_depth += 1;
        defer self.execution_depth -= 1;

        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);
        var last_status: ExitStatus = 0;

        if (program.statements.len > 0) {
            for (program.statements, 0..) |statement, statement_index| {
                if (shouldSkipPipeline(statement.op_before, last_status)) continue;
                self.setCurrentLineNumber(program.source, statement.span.start);
                var result = if (statement.async_after)
                    try self.executeAsyncStatement(program, statement, options)
                else switch (statement.kind) {
                    .pipeline => try self.executePipeline(program, program.pipelines[statement.index], options),
                    .if_command => try self.executeIfCommand(program.if_commands[statement.index], options),
                    .loop_command => try self.executeLoopCommand(program.loop_commands[statement.index], options),
                    .for_command => try self.executeForCommand(program.for_commands[statement.index], options),
                    .case_command => try self.executeCaseCommand(program.case_commands[statement.index], options),
                    .function_definition => try self.executeFunctionDefinition(program.function_definitions[statement.index]),
                    .bash_test_command => try self.executeBashTestCommand(program.bash_test_commands[statement.index], options),
                    .brace_group => try self.executeBraceGroup(program.brace_groups[statement.index], options),
                    .subshell => try self.executeSubshell(program.subshells[statement.index], options),
                };
                defer result.deinit();
                try self.annotateSourcedError(program.source, statement.span.start, options, &result);
                try self.appendOrWriteResult(options, &stdout, &stderr, result);
                try self.dispatchPendingSignalTrap(options, &stdout, &stderr);
                last_status = result.status;
                self.setLastStatus(last_status);
                self.applyErrexit(last_status, options, isFollowedByAndOrListOp(program.statements, statement_index));
                if (self.pending_exit != null or self.pending_return != null or self.pending_loop_control != null) break;
            }
            return self.finishExecuteProgram(root_execution, options, .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) });
        }

        if (program.pipelines.len > 0) {
            for (program.pipelines, 0..) |pipeline, pipeline_index| {
                if (shouldSkipPipeline(pipeline.op_before, last_status)) continue;
                self.setCurrentLineNumber(program.source, pipeline.span.start);
                var result = if (pipeline.async_after)
                    try self.executeAsyncPipeline(program, pipeline, options)
                else
                    try self.executePipeline(program, pipeline, options);
                defer result.deinit();
                try self.annotateSourcedError(program.source, pipeline.span.start, options, &result);
                try self.appendOrWriteResult(options, &stdout, &stderr, result);
                try self.dispatchPendingSignalTrap(options, &stdout, &stderr);
                last_status = result.status;
                self.setLastStatus(last_status);
                self.applyErrexit(last_status, options, isPipelineFollowedByAndOrListOp(program.pipelines, pipeline_index));
                if (self.pending_exit != null or self.pending_return != null or self.pending_loop_control != null) break;
            }
            return self.finishExecuteProgram(root_execution, options, .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) });
        }

        for (program.commands) |command| {
            self.setCurrentLineNumber(program.source, command.span.start);
            var result = try self.executeSimpleCommand(command, options);
            defer result.deinit();
            try self.annotateSourcedError(program.source, command.span.start, options, &result);
            try self.appendOrWriteResult(options, &stdout, &stderr, result);
            try self.dispatchPendingSignalTrap(options, &stdout, &stderr);
            last_status = result.status;
            self.setLastStatus(last_status);
            self.applyErrexit(last_status, options, false);
            if (self.pending_exit != null or self.pending_return != null or self.pending_loop_control != null) break;
        }
        return self.finishExecuteProgram(root_execution, options, .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) });
    }

    fn annotateSourcedError(self: *Executor, source: []const u8, offset: usize, options: ExecuteOptions, result: *CommandResult) !void {
        if (result.status == 0 or result.stderr.len == 0) return;
        const path = options.source_path orelse return;
        const line = sourceLineNumber(source, offset);
        const annotated = try std.fmt.allocPrint(self.allocator, "{s}:{d}: {s}", .{ path, line, result.stderr });
        self.allocator.free(result.stderr);
        result.stderr = annotated;
    }

    fn dispatchPendingSignalTrap(self: *Executor, options: ExecuteOptions, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8)) !void {
        const raw = pending_trap_signal.swap(0, .seq_cst);
        if (raw == 0) return;
        const name = signalNameFromNumber(raw) orelse return;
        const action = self.traps.get(name) orelse return;
        var trap_result = try self.executeScriptSlice(action, options);
        defer trap_result.deinit();
        try stdout.appendSlice(self.allocator, trap_result.stdout);
        try stderr.appendSlice(self.allocator, trap_result.stderr);
        self.setLastStatus(trap_result.status);
    }

    fn finishExecuteProgram(self: *Executor, root_execution: bool, options: ExecuteOptions, result: CommandResult) !CommandResult {
        if (!root_execution or self.running_exit_trap) return result;
        const action = self.traps.get("EXIT") orelse return result;
        var final = result;
        errdefer final.deinit();
        self.running_exit_trap = true;
        defer self.running_exit_trap = false;
        var trap_result = try self.executeScriptSlice(action, options);
        defer trap_result.deinit();
        const stdout = try std.mem.concat(self.allocator, u8, &.{ final.stdout, trap_result.stdout });
        errdefer self.allocator.free(stdout);
        const stderr = try std.mem.concat(self.allocator, u8, &.{ final.stderr, trap_result.stderr });
        errdefer self.allocator.free(stderr);
        self.allocator.free(final.stdout);
        self.allocator.free(final.stderr);
        final.stdout = stdout;
        final.stderr = stderr;
        if (self.pending_exit) |status| final.status = status;
        return final;
    }

    fn applyErrexit(self: *Executor, status: ExitStatus, options: ExecuteOptions, followed_by_and_or: bool) void {
        if (!self.shell_options.errexit or options.suppress_errexit or status == 0) return;
        if (followed_by_and_or) return;
        self.pending_exit = status;
    }

    fn appendOrWriteResult(self: *Executor, options: ExecuteOptions, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), result: CommandResult) !void {
        if (options.external_stdio == .inherit) {
            if (options.io) |io| {
                try writeInheritedResult(io, result);
                return;
            }
        }
        try stdout.appendSlice(self.allocator, result.stdout);
        try stderr.appendSlice(self.allocator, result.stderr);
    }

    fn executeSubshell(self: *Executor, subshell: ir.Subshell, options: ExecuteOptions) !CommandResult {
        var child = Executor.init(self.allocator);
        defer child.deinit();
        try child.copyStateFrom(self);
        const redirections = try self.expandRedirections(subshell.redirections, options);
        defer self.freeRedirections(redirections);
        const wrapper: ir.SimpleCommand = .{
            .span = subshell.span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = redirections,
        };
        if (self.applyRealFdRedirectionsIfNeeded(wrapper, options) catch |err| switch (err) {
            error.PathAlreadyExists => return errorResult(self.allocator, 1, noclobberTargetName(wrapper), "cannot overwrite existing file"),
            error.BadFileDescriptor => return errorResult(self.allocator, 1, badFdTargetName(wrapper), "bad file descriptor"),
            else => return err,
        }) |guard_value| {
            var guard = guard_value;
            defer guard.restore(self, options.io.?);
            var result = try child.executeScriptSlice(subshell.body, options);
            defer result.deinit();
            writeInheritedResult(options.io.?, result) catch |err| switch (err) {
                error.BadFileDescriptor => return errorResult(self.allocator, 1, "write", "bad file descriptor"),
                else => return err,
            };
            return emptyResult(self.allocator, result.status);
        }
        var result = try child.executeScriptSlice(subshell.body, options);
        errdefer result.deinit();
        return self.applyOutputRedirections(wrapper, result, options, false);
    }

    fn executeBraceGroup(self: *Executor, group: ir.BraceGroup, options: ExecuteOptions) !CommandResult {
        const redirections = try self.expandRedirections(group.redirections, options);
        defer self.freeRedirections(redirections);
        const wrapper: ir.SimpleCommand = .{
            .span = group.span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = redirections,
        };
        if (self.applyRealFdRedirectionsIfNeeded(wrapper, options) catch |err| switch (err) {
            error.PathAlreadyExists => return errorResult(self.allocator, 1, noclobberTargetName(wrapper), "cannot overwrite existing file"),
            error.BadFileDescriptor => return errorResult(self.allocator, 1, badFdTargetName(wrapper), "bad file descriptor"),
            else => return err,
        }) |guard_value| {
            var guard = guard_value;
            defer guard.restore(self, options.io.?);
            var result = try self.executeScriptSlice(group.body, options);
            defer result.deinit();
            writeInheritedResult(options.io.?, result) catch |err| switch (err) {
                error.BadFileDescriptor => return errorResult(self.allocator, 1, "write", "bad file descriptor"),
                else => return err,
            };
            return emptyResult(self.allocator, result.status);
        }
        var execution_options = options;
        if (options.external_stdio == .capture_stdout and commandDuplicatesStderrToStdout(redirections)) execution_options.external_stdio = .capture;
        var result = try self.executeScriptSlice(group.body, execution_options);
        errdefer result.deinit();
        return self.applyOutputRedirections(wrapper, result, options, false);
    }

    fn executeBashTestCommand(self: *Executor, command: ir.BashTestCommand, options: ExecuteOptions) !CommandResult {
        const args = try self.expandWords(command.args, options);
        defer self.freeWords(args);
        const matched = evalBashTest(self.allocator, options, args) catch return errorResult(self.allocator, 2, "[[", "invalid expression");
        return emptyResult(self.allocator, if (matched) 0 else 1);
    }

    fn executeFunctionDefinition(self: *Executor, definition: ir.FunctionDefinition) !CommandResult {
        try self.setFunction(definition.name, definition.body, definition.redirections);
        return emptyResult(self.allocator, 0);
    }

    pub fn copyStateFrom(self: *Executor, other: *const Executor) !void {
        self.shell_options = other.shell_options;
        self.getopts_offset = other.getopts_offset;
        self.getopts_last_optind = other.getopts_last_optind;
        self.arg_zero = other.arg_zero;
        self.last_status_text = other.last_status_text;
        self.last_status_text_len = other.last_status_text_len;
        self.lineno_text = other.lineno_text;
        self.lineno_text_len = other.lineno_text_len;
        self.last_command_duration_text = other.last_command_duration_text;
        self.last_command_duration_text_len = other.last_command_duration_text_len;
        self.pid_text = other.pid_text;
        self.pid_text_len = other.pid_text_len;
        self.last_background_pid_text = other.last_background_pid_text;
        self.last_background_pid_text_len = other.last_background_pid_text_len;
        self.completion_context = other.completion_context;
        self.last_completion_context = other.last_completion_context;
        self.script_stdin = other.script_stdin;
        self.script_stdin_offset = other.script_stdin_offset;
        var env_iter = other.env.iterator();
        while (env_iter.next()) |entry| try self.setEnv(entry.key_ptr.*, entry.value_ptr.*);
        var exported_iter = other.exported.iterator();
        while (exported_iter.next()) |entry| try self.setExported(entry.key_ptr.*);
        var readonly_iter = other.readonly.iterator();
        while (readonly_iter.next()) |entry| try self.setReadonly(entry.key_ptr.*);
        var open_fd_iter = other.open_fds.iterator();
        while (open_fd_iter.next()) |entry| try self.open_fds.put(self.allocator, entry.key_ptr.*, {});
        var function_iter = other.functions.iterator();
        while (function_iter.next()) |entry| try self.setFunction(entry.key_ptr.*, entry.value_ptr.body, entry.value_ptr.redirections);
        var alias_iter = other.aliases.iterator();
        while (alias_iter.next()) |entry| try self.setAlias(entry.key_ptr.*, entry.value_ptr.*);
        for (other.completion_rules.items) |rule| try self.registerCompletionRule(rule);
        var trap_iter = other.traps.iterator();
        while (trap_iter.next()) |entry| try self.setTrap(entry.key_ptr.*, entry.value_ptr.*);
        var array_iter = other.arrays.iterator();
        while (array_iter.next()) |entry| {
            for (entry.value_ptr.values.items, 0..) |value, index| {
                try self.setArrayElement(entry.key_ptr.*, index, value);
            }
        }
        try self.global_positionals.set(self.allocator, other.global_positionals.params);
        for (other.call_frames.items) |frame| {
            var copied: CallFrame = .{};
            errdefer copied.deinit(self.allocator);
            try copied.positionals.set(self.allocator, frame.positionals.params);
            try self.call_frames.append(self.allocator, copied);
        }
    }

    fn isShellFdOpen(self: Executor, fd: std.posix.fd_t) bool {
        return fd <= 2 or self.open_fds.contains(fd);
    }

    fn markShellFdOpen(self: *Executor, fd: std.posix.fd_t) !void {
        if (fd <= 2) return;
        try self.open_fds.put(self.allocator, fd, {});
    }

    fn markShellFdClosed(self: *Executor, fd: std.posix.fd_t) void {
        if (fd <= 2) return;
        _ = self.open_fds.remove(fd);
    }

    fn findBackgroundJob(self: *Executor, pid: i64) ?*BackgroundJob {
        for (self.background_jobs.items) |*job| {
            if (job.pid == pid) return job;
        }
        return null;
    }

    fn findBackgroundJobBySpec(self: *Executor, spec: []const u8) ?*BackgroundJob {
        const text = if (std.mem.startsWith(u8, spec, "%")) spec[1..] else spec;
        if (text.len == 0 or std.mem.eql(u8, text, "+") or std.mem.eql(u8, text, "%")) {
            const id = self.current_job_id orelse return null;
            return self.findBackgroundJobById(id);
        }
        if (std.mem.eql(u8, text, "-")) {
            const id = self.previous_job_id orelse return null;
            return self.findBackgroundJobById(id);
        }
        const id = std.fmt.parseUnsigned(usize, text, 10) catch return null;
        return self.findBackgroundJobById(id);
    }

    fn findBackgroundJobById(self: *Executor, id: usize) ?*BackgroundJob {
        for (self.background_jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    fn currentBackgroundJob(self: *Executor) ?*BackgroundJob {
        const id = self.current_job_id orelse return null;
        return self.findBackgroundJobById(id);
    }

    fn selectCurrentJob(self: *Executor, id: usize) void {
        if (self.current_job_id != null and self.current_job_id.? != id) self.previous_job_id = self.current_job_id;
        self.current_job_id = id;
    }

    fn jobMarker(self: Executor, job: BackgroundJob) u8 {
        if (self.current_job_id == job.id) return '+';
        if (self.previous_job_id == job.id) return '-';
        return ' ';
    }

    fn refreshBackgroundJobs(self: *Executor) void {
        const flags: c_int = @intCast(std.posix.W.NOHANG | std.posix.W.UNTRACED);
        for (self.background_jobs.items) |*job| {
            if (job.state == .done) continue;
            var status: c_int = 0;
            const pid: std.c.pid_t = @intCast(job.pid);
            const result = std.c.waitpid(pid, &status, flags);
            if (result <= 0 or result != pid) continue;
            const wait_status: u32 = @intCast(status);
            job.status = exitStatusFromWaitStatus(wait_status);
            job.state = if (std.posix.W.IFSTOPPED(wait_status)) .stopped else .done;
            if (job.state == .stopped) saveJobTerminalModes(job);
            self.queueJobNotification(job) catch {};
        }
    }

    fn queueJobNotification(self: *Executor, job: *BackgroundJob) !void {
        if (job.notified_state == job.state) return;
        const state = switch (job.state) {
            .running => return,
            .stopped => "Stopped",
            .done => "Done",
        };
        const notification = try std.fmt.allocPrint(self.allocator, "[{d}] {s} {s}\n", .{ job.id, state, job.command });
        errdefer self.allocator.free(notification);
        try self.pending_job_notifications.append(self.allocator, notification);
        job.notified_state = job.state;
    }

    pub fn drainJobNotifications(self: *Executor) ![]const u8 {
        self.refreshBackgroundJobs();
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (self.pending_job_notifications.items) |notification| {
            try output.appendSlice(self.allocator, notification);
            self.allocator.free(notification);
        }
        self.pending_job_notifications.clearRetainingCapacity();
        return output.toOwnedSlice(self.allocator);
    }

    pub fn expandAliasesForScript(self: *Executor, script: []const u8) ![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var active_aliases: std.ArrayList([]const u8) = .empty;
        defer active_aliases.deinit(self.allocator);
        _ = try self.expandAliasesInto(script, &output, &active_aliases, true);
        return output.toOwnedSlice(self.allocator);
    }

    fn expandAliasesInto(
        self: *Executor,
        script: []const u8,
        output: *std.ArrayList(u8),
        active_aliases: *std.ArrayList([]const u8),
        initial_command_position: bool,
    ) !bool {
        var index: usize = 0;
        var command_position = initial_command_position;
        while (index < script.len) {
            const byte = script[index];
            if (byte == '\'' or byte == '"') {
                const start = index;
                index += 1;
                while (index < script.len and script[index] != byte) {
                    if (script[index] == '\\' and index + 1 < script.len) index += 2 else index += 1;
                }
                if (index < script.len) index += 1;
                try output.appendSlice(self.allocator, script[start..index]);
                command_position = false;
                continue;
            }
            if (isShellSeparatorByte(byte)) {
                try output.append(self.allocator, byte);
                command_position = true;
                index += 1;
                continue;
            }
            if (byte == ' ' or byte == '\t' or byte == '\r') {
                try output.append(self.allocator, byte);
                index += 1;
                continue;
            }
            if (isAliasWordBoundary(byte)) {
                try output.append(self.allocator, byte);
                index += 1;
                command_position = false;
                continue;
            }
            const start = index;
            while (index < script.len and !isAliasWordBoundary(script[index])) : (index += 1) {}
            const word = script[start..index];
            if (command_position and !isReservedAliasWord(word) and !looksLikeFunctionDefinitionName(script, index)) {
                if (self.aliases.get(word)) |value| {
                    if (!isActiveAlias(active_aliases.items, word)) {
                        try active_aliases.append(self.allocator, word);
                        _ = try self.expandAliasesInto(value, output, active_aliases, true);
                        _ = active_aliases.pop();
                        command_position = value.len > 0 and isAliasTrailingBlank(value[value.len - 1]);
                        continue;
                    }
                    try output.appendSlice(self.allocator, word);
                    command_position = false;
                    continue;
                }
            }
            try output.appendSlice(self.allocator, word);
            command_position = false;
        }
        return command_position;
    }

    fn setAlias(self: *Executor, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const result = try self.aliases.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.value_ptr.*);
            result.value_ptr.* = owned_value;
        } else {
            result.value_ptr.* = owned_value;
        }
    }

    fn unsetAlias(self: *Executor, name: []const u8) bool {
        if (self.aliases.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            return true;
        }
        return false;
    }

    fn setFunction(self: *Executor, name: []const u8, body: []const u8, redirections: []const ir.Redirection) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(owned_body);
        const owned_redirections = try self.cloneRedirections(redirections);
        errdefer self.freeRedirections(owned_redirections);
        var parsed = try parser.parse(self.allocator, owned_body, .{});
        defer parsed.deinit();
        var program = try ir.lowerSimpleCommands(self.allocator, parsed);
        errdefer program.deinit();
        const result = try self.functions.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            result.value_ptr.deinit(self.allocator);
        }
        result.value_ptr.* = .{ .body = owned_body, .program = program, .redirections = owned_redirections };
    }

    fn cloneRedirections(self: *Executor, redirections: []const ir.Redirection) ![]ir.Redirection {
        const cloned = try self.allocator.alloc(ir.Redirection, redirections.len);
        errdefer self.allocator.free(cloned);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |redirection| self.freeRedirection(redirection);
            self.allocator.free(cloned);
        }
        for (redirections, 0..) |redirection, index| {
            cloned[index] = .{
                .span = redirection.span,
                .io_number = if (redirection.io_number) |word| try self.cloneWord(word) else null,
                .operator = redirection.operator,
                .target = if (redirection.target) |word| try self.cloneWord(word) else null,
                .here_doc = if (redirection.here_doc) |text| try self.allocator.dupe(u8, text) else null,
                .here_doc_quoted = redirection.here_doc_quoted,
            };
            initialized += 1;
        }
        return cloned;
    }

    fn cloneWord(self: *Executor, word: ir.WordRef) !ir.WordRef {
        const raw = try self.allocator.dupe(u8, word.raw);
        errdefer self.allocator.free(raw);
        const text = try self.allocator.dupe(u8, word.text);
        errdefer self.allocator.free(text);
        return .{ .span = word.span, .raw = raw, .text = text };
    }

    fn setTrap(self: *Executor, name: []const u8, action: []const u8) !void {
        if (signalFromTrapName(name)) |signal| installTrapSignal(signal);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);
        const result = try self.traps.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.value_ptr.*);
            result.value_ptr.* = owned_action;
        } else {
            result.value_ptr.* = owned_action;
        }
    }

    fn clearTrap(self: *Executor, name: []const u8) void {
        if (signalFromTrapName(name)) |signal| restoreDefaultSignal(signal);
        if (self.traps.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    fn executeCaseCommand(self: *Executor, command: ir.CaseCommand, options: ExecuteOptions) !CommandResult {
        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const prior_stdin = self.script_stdin;
        const prior_stdin_offset = self.script_stdin_offset;
        defer {
            self.script_stdin = prior_stdin;
            self.script_stdin_offset = prior_stdin_offset;
        }
        const redirected_stdin = try self.applyCompoundInputRedirections(command.span, command.redirections, options, &owned_stdin);
        if (redirected_stdin) |stdin| {
            self.script_stdin = stdin;
            self.script_stdin_offset = 0;
        }
        var execution_options = options;
        if (command.redirections.len != 0) execution_options.external_stdio = .capture;

        const subject_words = try self.expandWords(&.{command.word}, execution_options);
        defer self.freeWords(subject_words);
        const subject = if (subject_words.len == 0) "" else subject_words[0].text;

        for (command.arms) |arm| {
            for (arm.patterns) |word| {
                var pattern = try self.expandCasePattern(word, execution_options);
                defer pattern.deinit(self.allocator);
                if (shellCasePatternMatches(pattern, subject)) {
                    const result = try self.executeScriptSlice(arm.body, execution_options);
                    return self.applyCompoundOutputRedirections(command.span, command.redirections, result, options);
                }
            }
        }

        const result = try emptyResult(self.allocator, 0);
        return self.applyCompoundOutputRedirections(command.span, command.redirections, result, options);
    }

    fn executeForCommand(self: *Executor, command: ir.ForCommand, options: ExecuteOptions) !CommandResult {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const prior_stdin = self.script_stdin;
        const prior_stdin_offset = self.script_stdin_offset;
        defer {
            self.script_stdin = prior_stdin;
            self.script_stdin_offset = prior_stdin_offset;
        }
        const redirected_stdin = try self.applyCompoundInputRedirections(command.span, command.redirections, options, &owned_stdin);
        if (redirected_stdin) |stdin| {
            self.script_stdin = stdin;
            self.script_stdin_offset = 0;
        }
        var execution_options = options;
        if (command.redirections.len != 0) execution_options.external_stdio = .capture;
        const expanded_words = if (command.use_positionals) &[_]ir.WordRef{} else try self.expandArgv(command.words, options);
        defer if (!command.use_positionals) self.freeWords(expanded_words);

        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);
        var status: ExitStatus = 0;

        if (command.use_positionals) {
            for (self.currentPositionals().params) |param| {
                try self.setEnv(command.name, param);
                var body = try self.executeScriptSlice(command.body, execution_options);
                defer body.deinit();
                try stdout.appendSlice(self.allocator, body.stdout);
                try stderr.appendSlice(self.allocator, body.stderr);
                status = body.status;
                if (self.pending_exit != null) break;
                if (self.pending_return != null) break;
                if (self.consumeLoopControl()) |control| switch (control) {
                    .break_loop => break,
                    .continue_loop => continue,
                };
            }
        } else {
            for (expanded_words) |word| {
                try self.setEnv(command.name, word.text);
                var body = try self.executeScriptSlice(command.body, execution_options);
                defer body.deinit();
                try stdout.appendSlice(self.allocator, body.stdout);
                try stderr.appendSlice(self.allocator, body.stderr);
                status = body.status;
                if (self.pending_exit != null) break;
                if (self.pending_return != null) break;
                if (self.consumeLoopControl()) |control| switch (control) {
                    .break_loop => break,
                    .continue_loop => continue,
                };
            }
        }

        const result: CommandResult = .{
            .allocator = self.allocator,
            .status = status,
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
        };
        return self.applyCompoundOutputRedirections(command.span, command.redirections, result, options);
    }

    fn executeLoopCommand(self: *Executor, command: ir.LoopCommand, options: ExecuteOptions) !CommandResult {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const prior_stdin = self.script_stdin;
        const prior_stdin_offset = self.script_stdin_offset;
        defer {
            self.script_stdin = prior_stdin;
            self.script_stdin_offset = prior_stdin_offset;
        }
        const redirected_stdin = try self.applyCompoundInputRedirections(command.span, command.redirections, options, &owned_stdin);
        if (redirected_stdin) |stdin| {
            self.script_stdin = stdin;
            self.script_stdin_offset = 0;
        }
        var execution_options = options;
        if (command.redirections.len != 0) execution_options.external_stdio = .capture;
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);
        var status: ExitStatus = 0;

        while (true) {
            var condition_options = execution_options;
            condition_options.suppress_errexit = true;
            var condition = try self.executeScriptSlice(command.condition, condition_options);
            defer condition.deinit();
            try stdout.appendSlice(self.allocator, condition.stdout);
            try stderr.appendSlice(self.allocator, condition.stderr);

            const run_body = switch (command.kind) {
                .while_loop => condition.status == 0,
                .until_loop => condition.status != 0,
            };
            if (!run_body) break;

            var body = try self.executeScriptSlice(command.body, execution_options);
            defer body.deinit();
            try stdout.appendSlice(self.allocator, body.stdout);
            try stderr.appendSlice(self.allocator, body.stderr);
            status = body.status;
            if (self.pending_exit != null) break;
            if (self.pending_return != null) break;
            if (self.consumeLoopControl()) |control| switch (control) {
                .break_loop => break,
                .continue_loop => continue,
            };
        }

        const result: CommandResult = .{
            .allocator = self.allocator,
            .status = status,
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
        };
        return self.applyCompoundOutputRedirections(command.span, command.redirections, result, options);
    }

    fn applyCompoundInputRedirections(self: *Executor, span: parser.Span, redirections: []const ir.Redirection, options: ExecuteOptions, owned_stdin: *?[]u8) !?[]const u8 {
        if (redirections.len == 0) return null;
        if (!hasInputRedirection(redirections)) return null;
        const expanded_redirections = try self.expandRedirections(redirections, options);
        defer self.freeRedirections(expanded_redirections);
        const wrapper: ir.SimpleCommand = .{
            .span = span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = expanded_redirections,
        };
        return try self.applyInputRedirections(wrapper, "", options, owned_stdin);
    }

    fn applyCompoundOutputRedirections(self: *Executor, span: parser.Span, redirections: []const ir.Redirection, result: CommandResult, options: ExecuteOptions) !CommandResult {
        if (redirections.len == 0) return result;
        var owned_result = result;
        const expanded_redirections = self.expandRedirections(redirections, options) catch |err| {
            owned_result.deinit();
            return err;
        };
        defer self.freeRedirections(expanded_redirections);
        const wrapper: ir.SimpleCommand = .{
            .span = span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = expanded_redirections,
        };
        return self.applyOutputRedirections(wrapper, owned_result, options, false);
    }

    fn hasInputRedirection(redirections: []const ir.Redirection) bool {
        for (redirections) |redirection| {
            if (isHereDocRedirection(redirection) or isStdinFileRedirection(redirection)) return true;
        }
        return false;
    }

    fn consumeLoopControl(self: *Executor) ?LoopControlKind {
        const control = self.pending_loop_control orelse return null;
        if (control.levels <= 1) {
            self.pending_loop_control = null;
            return control.kind;
        }
        self.pending_loop_control = .{ .kind = control.kind, .levels = control.levels - 1 };
        return .break_loop;
    }

    fn executeIfCommand(self: *Executor, command: ir.IfCommand, options: ExecuteOptions) !CommandResult {
        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const prior_stdin = self.script_stdin;
        const prior_stdin_offset = self.script_stdin_offset;
        defer {
            self.script_stdin = prior_stdin;
            self.script_stdin_offset = prior_stdin_offset;
        }
        const redirected_stdin = try self.applyCompoundInputRedirections(command.span, command.redirections, options, &owned_stdin);
        if (redirected_stdin) |stdin| {
            self.script_stdin = stdin;
            self.script_stdin_offset = 0;
        }
        var execution_options = options;
        if (command.redirections.len != 0) execution_options.external_stdio = .capture;
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);

        var condition_options = execution_options;
        condition_options.suppress_errexit = true;
        var condition = try self.executeScriptSlice(command.condition, condition_options);
        defer condition.deinit();
        try stdout.appendSlice(self.allocator, condition.stdout);
        try stderr.appendSlice(self.allocator, condition.stderr);

        var status: ExitStatus = 0;
        if (condition.status == 0) {
            var body = try self.executeScriptSlice(command.then_body, execution_options);
            defer body.deinit();
            try stdout.appendSlice(self.allocator, body.stdout);
            try stderr.appendSlice(self.allocator, body.stderr);
            status = body.status;
        } else if (command.else_body) |else_body| {
            var body = try self.executeElseBody(else_body, execution_options);
            defer body.deinit();
            try stdout.appendSlice(self.allocator, body.stdout);
            try stderr.appendSlice(self.allocator, body.stderr);
            status = body.status;
        } else {
            status = 0;
        }

        const result: CommandResult = .{
            .allocator = self.allocator,
            .status = status,
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
        };
        return self.applyCompoundOutputRedirections(command.span, command.redirections, result, options);
    }

    fn executeElseBody(self: *Executor, else_body: []const u8, options: ExecuteOptions) !CommandResult {
        const trimmed = trimLeftShellSeparators(else_body);
        if (std.mem.startsWith(u8, trimmed, "elif")) {
            const rest = trimLeftShellWhitespace(trimmed[4..]);
            const script = try std.fmt.allocPrint(self.allocator, "if {s} fi", .{rest});
            defer self.allocator.free(script);
            return self.executeScriptSlice(script, options);
        }
        return self.executeScriptSlice(else_body, options);
    }

    fn trimLeftShellSeparators(text: []const u8) []const u8 {
        var index: usize = 0;
        while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == '\r' or text[index] == '\n' or text[index] == ';')) : (index += 1) {}
        return text[index..];
    }

    fn trimLeftShellWhitespace(text: []const u8) []const u8 {
        var index: usize = 0;
        while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == '\r' or text[index] == '\n')) : (index += 1) {}
        return text[index..];
    }

    pub fn executeScriptSlice(self: *Executor, script: []const u8, options: ExecuteOptions) anyerror!CommandResult {
        const trimmed = std.mem.trim(u8, script, " \t\r\n;");
        if (trimmed.len == 0) return emptyResult(self.allocator, 0);
        if (containsAliasCommandToken(trimmed)) {
            if (try self.aliasTimingChunkProgram(trimmed, options)) |chunk_program| {
                var program = chunk_program;
                defer program.deinit();
                return self.executeScriptChunks(trimmed, program, options);
            }
        }
        const aliased = try self.expandAliasesForScript(trimmed);
        defer self.allocator.free(aliased);
        var parsed = try parser.parse(self.allocator, aliased, .{ .features = options.features });
        defer parsed.deinit();
        if (parsed.diagnostics.len != 0) return error.ParseError;
        var program = try ir.lowerSimpleCommands(self.allocator, parsed);
        defer program.deinit();
        var result = try self.executeProgram(program, options);
        errdefer result.deinit();
        if (self.shell_options.verbose and !options.suppress_errexit) {
            const stderr = try std.mem.concat(self.allocator, u8, &.{ trimmed, "\n", result.stderr });
            self.allocator.free(result.stderr);
            result.stderr = stderr;
        }
        return result;
    }

    fn aliasTimingChunkProgram(self: *Executor, script: []const u8, options: ExecuteOptions) !?ir.Program {
        var parsed = try parser.parse(self.allocator, script, .{ .features = options.features });
        defer parsed.deinit();
        if (parsed.diagnostics.len != 0) return null;
        var program = try ir.lowerSimpleCommands(self.allocator, parsed);
        errdefer program.deinit();
        if (!canExecuteAsAliasTimingChunks(program)) {
            program.deinit();
            return null;
        }
        return program;
    }

    fn executeScriptChunks(self: *Executor, script: []const u8, program: ir.Program, options: ExecuteOptions) anyerror!CommandResult {
        const root_execution = self.execution_depth == 0;
        self.execution_depth += 1;
        defer self.execution_depth -= 1;

        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);
        var last_status: ExitStatus = 0;
        for (program.statements, 0..) |statement, index| {
            const start = statement.span.start;
            const end = if (index + 1 < program.statements.len) program.statements[index + 1].span.start else script.len;
            var result = try self.executeScriptSlice(script[start..end], options);
            defer result.deinit();
            try self.appendOrWriteResult(options, &stdout, &stderr, result);
            last_status = result.status;
            if (self.pending_exit != null or self.pending_return != null or self.pending_loop_control != null) break;
        }
        var result: CommandResult = .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) };
        errdefer result.deinit();
        return self.finishExecuteProgram(root_execution, options, result);
    }

    fn executeStatementSync(self: *Executor, program: ir.Program, statement: ir.Statement, options: ExecuteOptions) !CommandResult {
        return switch (statement.kind) {
            .pipeline => try self.executePipeline(program, program.pipelines[statement.index], options),
            .if_command => try self.executeIfCommand(program.if_commands[statement.index], options),
            .loop_command => try self.executeLoopCommand(program.loop_commands[statement.index], options),
            .for_command => try self.executeForCommand(program.for_commands[statement.index], options),
            .case_command => try self.executeCaseCommand(program.case_commands[statement.index], options),
            .function_definition => try self.executeFunctionDefinition(program.function_definitions[statement.index]),
            .bash_test_command => try self.executeBashTestCommand(program.bash_test_commands[statement.index], options),
            .brace_group => try self.executeBraceGroup(program.brace_groups[statement.index], options),
            .subshell => try self.executeSubshell(program.subshells[statement.index], options),
        };
    }

    fn executeAsyncStatement(self: *Executor, program: ir.Program, statement: ir.Statement, options: ExecuteOptions) !CommandResult {
        if (statement.kind == .pipeline) return self.executeAsyncPipeline(program, program.pipelines[statement.index], options);
        if (options.io == null) return self.executeAsyncStatementFallback(program, statement, options);
        const command_text = statementText(program, statement);
        const forked = self.forkAsyncJob(command_text, options, .{ .statement = statement }, program) catch |err| switch (err) {
            error.Unsupported => return self.executeAsyncStatementFallback(program, statement, options),
            else => return err,
        };
        return forked;
    }

    fn executeAsyncStatementFallback(self: *Executor, program: ir.Program, statement: ir.Statement, options: ExecuteOptions) !CommandResult {
        var result = try self.executeStatementSync(program, statement, options);
        result.status = 0;
        return result;
    }

    fn executeAsyncPipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) !CommandResult {
        if (pipeline.command_indexes.len != 1 or !options.allow_external or options.io == null) return self.executeAsyncPipelineFallback(program, pipeline, options);
        const command = program.commands[pipeline.command_indexes[0]];
        if (command.argv.len == 0 or builtinForName(self.*, command.argv[0].text) != null or self.functions.get(command.argv[0].text) != null) return self.executeAsyncPipelineFallback(program, pipeline, options);
        const expanded = try self.expandSimpleCommand(command, options);
        defer self.freeExpandedCommand(expanded);
        if (expanded.argv.len == 0) return emptyResult(self.allocator, 0);
        return self.executeExternalAsync(expanded, options.io.?, options);
    }

    fn executeAsyncPipelineFallback(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) !CommandResult {
        if (options.io == null) {
            var result = try self.executePipeline(program, pipeline, options);
            result.status = 0;
            return result;
        }
        return self.forkAsyncJob(pipelineText(program, pipeline), options, .{ .pipeline = pipeline }, program) catch |err| switch (err) {
            error.Unsupported => {
                var result = try self.executePipeline(program, pipeline, options);
                result.status = 0;
                return result;
            },
            else => return err,
        };
    }

    const AsyncJobKind = union(enum) {
        statement: ir.Statement,
        pipeline: ir.Pipeline,
    };

    fn forkAsyncJob(self: *Executor, command_text: []const u8, options: ExecuteOptions, kind: AsyncJobKind, program: ir.Program) !CommandResult {
        const io = options.io orelse return error.Unsupported;
        const pid = try forkProcess();
        if (pid == 0) {
            var status: ExitStatus = 2;
            var child_result = switch (kind) {
                .statement => |statement| self.executeStatementSync(program, statement, options),
                .pipeline => |pipeline| self.executePipeline(program, pipeline, options),
            } catch null;
            if (child_result) |*result| {
                status = result.status;
                if (options.external_stdio == .inherit) writeInheritedResult(io, result.*) catch {};
                result.deinit();
            }
            exitForkedChild(status);
        }

        const numeric_pid: i64 = @intCast(pid);
        self.setLastBackgroundPid(numeric_pid);
        const owned_command = try self.allocator.dupe(u8, std.mem.trim(u8, command_text, " \t\r\n;&"));
        errdefer self.allocator.free(owned_command);
        try self.background_jobs.append(self.allocator, .{
            .id = self.next_job_id,
            .pid = numeric_pid,
            .command = owned_command,
            .child = childFromPid(pid),
        });
        self.selectCurrentJob(self.next_job_id);
        self.next_job_id += 1;
        return emptyResult(self.allocator, 0);
    }

    fn executePipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) anyerror!CommandResult {
        if (self.canExecuteRealPipeline(program, pipeline, options)) {
            const io = options.io orelse return error.MissingIoForExternalCommand;
            return self.executeRealPipeline(program, pipeline, options, io);
        }

        var last = try emptyResult(self.allocator, 0);
        var stdin = try self.allocator.alloc(u8, 0);
        defer self.allocator.free(stdin);
        const statuses = try self.allocator.alloc(ExitStatus, pipeline.command_indexes.len);
        defer self.allocator.free(statuses);

        for (pipeline.command_indexes, 0..) |command_index, index| {
            last.deinit();
            last = try self.executeSimpleCommandWithInput(program.commands[command_index], stdin, options);
            statuses[index] = last.status;

            if (index + 1 < pipeline.command_indexes.len) {
                self.allocator.free(stdin);
                stdin = try self.allocator.dupe(u8, last.stdout);
            }
        }

        last.status = self.pipelineStatus(pipeline, statuses);
        return last;
    }

    fn pipelineHasRedirections(program: ir.Program, pipeline: ir.Pipeline) bool {
        for (pipeline.command_indexes) |command_index| {
            if (program.commands[command_index].redirections.len != 0) return true;
        }
        return false;
    }

    fn pipelineStatus(self: Executor, pipeline: ir.Pipeline, statuses: []const ExitStatus) ExitStatus {
        const status: ExitStatus = blk: {
            if (statuses.len == 0) break :blk 0;
            if (!self.shell_options.pipefail) break :blk statuses[statuses.len - 1];
            var index = statuses.len;
            while (index > 0) {
                index -= 1;
                if (statuses[index] != 0) break :blk statuses[index];
            }
            break :blk 0;
        };
        return if (pipeline.negated) (if (status == 0) 1 else 0) else status;
    }

    fn canExecuteRealPipeline(self: Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) bool {
        _ = self;
        if (!options.allow_external or options.io == null or pipeline.command_indexes.len < 2) return false;
        for (pipeline.command_indexes) |command_index| {
            const command = program.commands[command_index];
            if (command.argv.len == 0) return false;
        }
        return true;
    }

    fn executeRealPipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions, io: std.Io) !CommandResult {
        var has_builtin = false;
        for (pipeline.command_indexes) |command_index| {
            const command = program.commands[command_index];
            if (builtinForName(self.*, command.argv[0].text) != null or self.functions.get(command.argv[0].text) != null) {
                has_builtin = true;
                break;
            }
        }
        if (!has_builtin and !pipelineHasRedirections(program, pipeline)) return self.executeExternalPipeline(program, pipeline, options, io);
        return self.executeMixedPipeline(program, pipeline, options, io);
    }

    const PipelinePipe = struct {
        read: ?std.Io.File,
        write: ?std.Io.File,

        fn close(self: *PipelinePipe, io: std.Io) void {
            if (self.read) |file| file.close(io);
            if (self.write) |file| file.close(io);
            self.* = .{ .read = null, .write = null };
        }
    };

    const BuiltinPipelineContext = struct {
        executor: *Executor,
        command: ir.SimpleCommand,
        options: ExecuteOptions,
        io: std.Io,
        stdin_file: ?std.Io.File,
        stdout_file: ?std.Io.File,
        stderr_file: ?std.Io.File,
        stage_index: usize,
        status: ExitStatus = 0,
        err: ?anyerror = null,
    };

    fn executeMixedPipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions, io: std.Io) !CommandResult {
        const pipe_count = pipeline.command_indexes.len - 1;
        const pipes = try self.allocator.alloc(PipelinePipe, pipe_count);
        defer self.allocator.free(pipes);
        for (pipes) |*pipe| pipe.* = try makePipelinePipe(io);
        defer for (pipes) |*pipe| pipe.close(io);

        var capture_stdout = try makePipelinePipe(io);
        defer capture_stdout.close(io);
        var capture_stderr = try makePipelinePipe(io);
        defer capture_stderr.close(io);

        const children = try self.allocator.alloc(std.process.Child, pipeline.command_indexes.len);
        defer self.allocator.free(children);
        const child_stage_indexes = try self.allocator.alloc(usize, pipeline.command_indexes.len);
        defer self.allocator.free(child_stage_indexes);
        var spawned: usize = 0;
        errdefer for (children[0..spawned]) |*child| child.kill(io);

        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(self.allocator);
        var contexts: std.ArrayList(*BuiltinPipelineContext) = .empty;
        defer contexts.deinit(self.allocator);
        errdefer {
            for (contexts.items) |context| self.allocator.destroy(context);
        }

        for (pipeline.command_indexes, 0..) |command_index, index| {
            const command = program.commands[command_index];
            const is_last = index + 1 == pipeline.command_indexes.len;
            var stdin_file = if (index == 0) null else takeRead(&pipes[index - 1]);
            var stdout_file = if (is_last) takeWrite(&capture_stdout) else takeWrite(&pipes[index]);
            var stderr_file = if (is_last) takeWrite(&capture_stderr) else null;
            try self.applyPipelineStageRedirections(io, command, options, &stdin_file, &stdout_file, &stderr_file);
            const command_without_redirs: ir.SimpleCommand = .{
                .span = command.span,
                .assignments = command.assignments,
                .argv = command.argv,
                .redirections = &.{},
            };

            if (builtinForName(self.*, command.argv[0].text) != null or self.functions.get(command.argv[0].text) != null) {
                const context = try self.allocator.create(BuiltinPipelineContext);
                errdefer self.allocator.destroy(context);
                context.* = .{
                    .executor = self,
                    .command = command_without_redirs,
                    .options = options,
                    .io = io,
                    .stdin_file = stdin_file,
                    .stdout_file = stdout_file,
                    .stderr_file = stderr_file,
                    .stage_index = index,
                };
                const thread = try std.Thread.spawn(.{}, runBuiltinPipelineStage, .{context});
                try threads.append(self.allocator, thread);
                try contexts.append(self.allocator, context);
            } else {
                const argv = try argvForCommand(self.allocator, command_without_redirs);
                defer self.allocator.free(argv);
                var child_env = try self.buildProcessEnv(command.assignments);
                defer child_env.deinit();
                children[spawned] = std.process.spawn(io, .{
                    .argv = argv,
                    .environ_map = &child_env,
                    .stdin = if (stdin_file) |file| .{ .file = file } else .ignore,
                    .stdout = if (stdout_file) |file| .{ .file = file } else .ignore,
                    .stderr = if (stderr_file) |file| .{ .file = file } else .inherit,
                }) catch |err| switch (err) {
                    error.FileNotFound => {
                        if (stdin_file) |file| file.close(io);
                        if (stdout_file) |file| file.close(io);
                        if (stderr_file) |file| file.close(io);
                        for (pipes) |*pipe| pipe.close(io);
                        capture_stdout.close(io);
                        capture_stderr.close(io);
                        return self.pipelineSpawnFailureResult(io, command.argv[0].text, children[0..spawned], &threads, contexts.items);
                    },
                    else => return err,
                };
                child_stage_indexes[spawned] = index;
                spawned += 1;
                if (stdin_file) |file| file.close(io);
                if (stdout_file) |file| file.close(io);
                if (stderr_file) |file| file.close(io);
            }
        }

        for (pipes) |*pipe| pipe.close(io);
        if (capture_stdout.write) |file| file.close(io);
        capture_stdout.write = null;
        if (capture_stderr.write) |file| file.close(io);
        capture_stderr.write = null;

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(self.allocator, io, multi_reader_buffer.toStreams(), &.{ capture_stdout.read.?, capture_stderr.read.? });
        defer multi_reader.deinit();

        while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();

        const statuses = try self.allocator.alloc(ExitStatus, pipeline.command_indexes.len);
        defer self.allocator.free(statuses);
        @memset(statuses, 0);
        for (children[0..spawned], child_stage_indexes[0..spawned]) |*child, stage_index| {
            const term = try child.wait(io);
            statuses[stage_index] = exitStatusFromTerm(term);
        }
        for (threads.items) |thread| thread.join();
        for (contexts.items) |context| {
            defer self.allocator.destroy(context);
            if (context.err) |err| return err;
            statuses[context.stage_index] = context.status;
        }

        return .{
            .allocator = self.allocator,
            .status = self.pipelineStatus(pipeline, statuses),
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
        };
    }

    fn pipelineSpawnFailureResult(self: *Executor, io: std.Io, name: []const u8, children: []std.process.Child, threads: *std.ArrayList(std.Thread), contexts: []const *BuiltinPipelineContext) !CommandResult {
        for (children) |*child| child.kill(io);
        for (threads.items) |thread| thread.join();
        for (contexts) |context| self.allocator.destroy(context);
        threads.clearRetainingCapacity();
        return errorResult(self.allocator, 127, name, "command not found");
    }

    fn applyPipelineStageRedirections(
        self: *Executor,
        io: std.Io,
        command: ir.SimpleCommand,
        options: ExecuteOptions,
        stdin_file: *?std.Io.File,
        stdout_file: *?std.Io.File,
        stderr_file: *?std.Io.File,
    ) !void {
        const redirections = try self.expandRedirections(command.redirections, options);
        defer self.freeRedirections(redirections);
        for (redirections) |redirection| {
            if (isHereDocRedirection(redirection)) {
                if (stdin_file.*) |file| file.close(io);
                stdin_file.* = try fileFromBytes(io, redirection.here_doc orelse "");
                continue;
            }
            if (isStdinFileRedirection(redirection)) {
                const target = redirection.target orelse continue;
                if (stdin_file.*) |file| file.close(io);
                stdin_file.* = try std.Io.Dir.cwd().openFile(io, target.text, .{});
                continue;
            }
            if (isFileOutputRedirection(redirection)) {
                const target = redirection.target orelse continue;
                const fd = redirectionFd(redirection) orelse 1;
                const file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
                switch (fd) {
                    1 => {
                        if (stdout_file.*) |old| old.close(io);
                        stdout_file.* = file;
                    },
                    2 => {
                        if (stderr_file.*) |old| old.close(io);
                        stderr_file.* = file;
                    },
                    else => file.close(io),
                }
            }
        }
    }

    fn runBuiltinPipelineStage(context: *BuiltinPipelineContext) void {
        runBuiltinPipelineStageFallible(context) catch |err| {
            context.err = err;
            context.status = 2;
        };
    }

    fn runBuiltinPipelineStageFallible(context: *BuiltinPipelineContext) !void {
        defer if (context.stdin_file) |file| file.close(context.io);
        defer if (context.stdout_file) |file| file.close(context.io);
        defer if (context.stderr_file) |file| file.close(context.io);

        var stdin_bytes: []u8 = try context.executor.allocator.alloc(u8, 0);
        defer context.executor.allocator.free(stdin_bytes);
        if (context.stdin_file) |file| {
            context.executor.allocator.free(stdin_bytes);
            var reader_buffer: [4096]u8 = undefined;
            var reader = file.reader(context.io, &reader_buffer);
            stdin_bytes = try reader.interface.allocRemaining(context.executor.allocator, .limited(1024 * 1024));
        }

        var result = try context.executor.executeSimpleCommandWithInput(context.command, stdin_bytes, context.options);
        defer result.deinit();
        context.status = result.status;
        if (context.stdout_file) |file| try writeBytesToFile(context.io, file, result.stdout);
        if (context.stderr_file) |file| try writeBytesToFile(context.io, file, result.stderr);
    }

    fn takeRead(pipe: *PipelinePipe) ?std.Io.File {
        const file = pipe.read;
        pipe.read = null;
        return file;
    }

    fn takeWrite(pipe: *PipelinePipe) ?std.Io.File {
        const file = pipe.write;
        pipe.write = null;
        return file;
    }

    fn executeExternalPipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions, io: std.Io) !CommandResult {
        const children = try self.allocator.alloc(std.process.Child, pipeline.command_indexes.len);
        defer self.allocator.free(children);
        var spawned: usize = 0;
        errdefer for (children[0..spawned]) |*child| child.kill(io);

        var previous_stdout: ?std.Io.File = null;
        defer if (previous_stdout) |file| file.close(io);
        const foreground_terminal = try prepareForegroundTerminal(options.external_stdio == .inherit);
        defer restoreForegroundTerminal(foreground_terminal);
        var pipeline_pgrp: ?std.posix.pid_t = null;

        for (pipeline.command_indexes, 0..) |command_index, index| {
            const command = program.commands[command_index];
            const argv = try argvForCommand(self.allocator, command);
            defer self.allocator.free(argv);
            var child_env = try self.buildProcessEnv(command.assignments);
            defer child_env.deinit();

            const is_last = index + 1 == pipeline.command_indexes.len;
            children[index] = std.process.spawn(io, .{
                .argv = argv,
                .environ_map = &child_env,
                .stdin = if (previous_stdout) |file| .{ .file = file } else if (options.external_stdio == .inherit) .inherit else .ignore,
                .stdout = .pipe,
                .stderr = if (is_last) .pipe else .inherit,
                .pgid = if (foreground_terminal != null) (pipeline_pgrp orelse 0) else null,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    const open_stdin = previous_stdout;
                    previous_stdout = null;
                    return self.externalPipelineSpawnFailureResult(io, command.argv[0].text, children[0..spawned], open_stdin);
                },
                else => return err,
            };
            if (pipeline_pgrp == null and foreground_terminal != null) pipeline_pgrp = children[index].id;
            spawned += 1;

            if (previous_stdout) |file| file.close(io);
            previous_stdout = null;

            if (!is_last) {
                previous_stdout = children[index].stdout.?;
                children[index].stdout = null;
            }
        }

        if (pipeline_pgrp) |pgrp| try giveTerminalToForegroundPgrp(pgrp, foreground_terminal);

        const last_child = &children[pipeline.command_indexes.len - 1];
        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(self.allocator, io, multi_reader_buffer.toStreams(), &.{ last_child.stdout.?, last_child.stderr.? });
        defer multi_reader.deinit();

        while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();

        const statuses = try self.allocator.alloc(ExitStatus, spawned);
        defer self.allocator.free(statuses);
        for (children[0..spawned], 0..) |*child, index| {
            const term = try child.wait(io);
            statuses[index] = exitStatusFromTerm(term);
        }

        return .{
            .allocator = self.allocator,
            .status = self.pipelineStatus(pipeline, statuses),
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
        };
    }

    fn externalPipelineSpawnFailureResult(self: *Executor, io: std.Io, name: []const u8, children: []std.process.Child, previous_stdout: ?std.Io.File) !CommandResult {
        if (previous_stdout) |file| file.close(io);
        for (children) |*child| child.kill(io);
        return errorResult(self.allocator, 127, name, "command not found");
    }

    pub fn executeSimpleCommand(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !CommandResult {
        return self.executeSimpleCommandWithInput(command, "", options);
    }

    fn executeSimpleCommandWithInput(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) anyerror!CommandResult {
        const trace_enabled = self.shell_options.xtrace;
        var result = try self.executeSimpleCommandWithInputInner(command, stdin, options);
        errdefer result.deinit();
        if (trace_enabled and command.argv.len != 0) {
            const trace = try traceLineForCommand(self.allocator, command);
            defer self.allocator.free(trace);
            const stderr = try std.mem.concat(self.allocator, u8, &.{ trace, result.stderr });
            self.allocator.free(result.stderr);
            result.stderr = stderr;
        }
        return result;
    }

    fn executeSimpleCommandWithInputInner(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) anyerror!CommandResult {
        const expanded = self.expandSimpleCommand(command, options) catch |err| switch (err) {
            error.NounsetParameter => {
                self.pending_exit = 1;
                return errorResult(self.allocator, 1, "parameter", "unset parameter");
            },
            error.ParameterExpansionFailed => return self.parameterExpansionErrorResult(),
            error.ReadonlyVariable => return self.assignmentErrorResult(),
            else => return err,
        };
        defer self.freeExpandedCommand(expanded);

        if (isRedirectionOnlyExec(expanded)) {
            self.applyAssignments(expanded.assignments) catch |err| switch (err) {
                error.ReadonlyVariable => return self.assignmentErrorResult(),
                else => return err,
            };
            if (self.applyPermanentRealFdRedirections(expanded, options) catch |err| return self.redirectionErrorResult(expanded, err, true)) {
                return emptyResult(self.allocator, 0);
            }
        }

        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const input_special_builtin = expanded.argv.len > 0 and isSpecialBuiltin(expanded.argv[0].text);
        const effective_stdin = self.applyInputRedirections(expanded, stdin, options, &owned_stdin) catch |err| return self.redirectionErrorResult(expanded, err, input_special_builtin);

        if (expanded.argv.len == 0) {
            self.applyAssignments(expanded.assignments) catch |err| switch (err) {
                error.ReadonlyVariable => return self.assignmentErrorResult(),
                else => return err,
            };
            const assignment_status = self.command_substitution_status orelse 0;
            if (self.applyRealFdRedirectionsIfNeeded(expanded, options) catch |err| return self.redirectionErrorResult(expanded, err, false)) |guard_value| {
                var guard = guard_value;
                defer guard.restore(self, options.io.?);
                return emptyResult(self.allocator, assignment_status);
            }
            return try self.applyOutputRedirections(expanded, try emptyResult(self.allocator, assignment_status), options, false);
        }

        if (!options.suppress_functions and self.functions.getPtr(expanded.argv[0].text) != null) {
            const function_value = self.functions.getPtr(expanded.argv[0].text).?;
            if (self.applyRealFdRedirectionsIfNeeded(expanded, options) catch |err| return self.redirectionErrorResult(expanded, err, false)) |guard_value| {
                var guard = guard_value;
                defer guard.restore(self, options.io.?);
                var result = try self.executeFunctionBody(expanded, function_value, options);
                defer result.deinit();
                writeInheritedResult(options.io.?, result) catch |err| switch (err) {
                    error.BadFileDescriptor => return errorResult(self.allocator, 1, "write", "bad file descriptor"),
                    else => return err,
                };
                return emptyResult(self.allocator, result.status);
            }
            var result = try self.executeFunctionBody(expanded, function_value, options);
            errdefer result.deinit();
            return try self.applyOutputRedirections(expanded, result, options, false);
        }

        if (builtinForName(self.*, expanded.argv[0].text)) |builtin| {
            const special_builtin = isSpecialBuiltin(expanded.argv[0].text);
            if (self.applyRealFdRedirectionsIfNeeded(expanded, options) catch |err| return self.redirectionErrorResult(expanded, err, special_builtin)) |guard_value| {
                var guard = guard_value;
                defer guard.restore(self, options.io.?);
                var result = try self.executeBuiltinWithAssignments(builtin, expanded, effective_stdin, options);
                defer result.deinit();
                writeInheritedResult(options.io.?, result) catch |err| switch (err) {
                    error.BadFileDescriptor => return errorResult(self.allocator, 1, "write", "bad file descriptor"),
                    else => return err,
                };
                return emptyResult(self.allocator, result.status);
            }
            return try self.applyOutputRedirections(expanded, try self.executeBuiltinWithAssignments(builtin, expanded, effective_stdin, options), options, special_builtin);
        }

        if (!options.allow_external) {
            return try self.applyOutputRedirections(expanded, try errorResult(self.allocator, 127, expanded.argv[0].text, "command not found"), options, false);
        }

        const io = options.io orelse return error.MissingIoForExternalCommand;
        var synthetic_failure = false;
        var external_result = self.executeExternal(expanded, io, options) catch |err| switch (err) {
            error.CommandNotFound => blk: {
                synthetic_failure = true;
                break :blk try errorResult(self.allocator, 127, expanded.argv[0].text, "command not found");
            },
            else => return err,
        };
        errdefer external_result.deinit();
        if (synthetic_failure) return try self.applyOutputRedirections(expanded, external_result, options, false);
        return try self.applyExternalPostRedirections(expanded, external_result, options);
    }

    fn redirectionErrorResult(self: *Executor, command: ir.SimpleCommand, err: anyerror, special_builtin: bool) !CommandResult {
        const result = switch (err) {
            error.PathAlreadyExists => try errorResult(self.allocator, 1, noclobberTargetName(command), "cannot overwrite existing file"),
            error.BadFileDescriptor => try errorResult(self.allocator, 1, badFdTargetName(command), "bad file descriptor"),
            error.FileNotFound => try errorResult(self.allocator, 1, inputTargetName(command), "no such file or directory"),
            error.IsDir => try errorResult(self.allocator, 1, redirectionTargetName(command), "is a directory"),
            else => return err,
        };
        if (special_builtin) self.pending_exit = result.status;
        return result;
    }

    fn assignmentErrorResult(self: *Executor) !CommandResult {
        self.pending_exit = 2;
        return errorResult(self.allocator, 2, "assignment", "readonly variable");
    }

    fn parameterExpansionErrorResult(self: *Executor) !CommandResult {
        if (self.parameter_error.name.len == 0) return errorResult(self.allocator, 1, "parameter", "expansion failed");
        const name = self.parameter_error.name;
        const message = if (self.parameter_error.message.len != 0) self.parameter_error.message else "parameter null or not set";
        self.pending_exit = 1;
        errdefer self.parameter_error.clear(self.allocator);
        const result = try errorResult(self.allocator, 1, name, message);
        self.parameter_error.clear(self.allocator);
        return result;
    }

    fn executeBuiltinWithAssignments(self: *Executor, builtin: BuiltinFn, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
        if (isSpecialBuiltin(command.argv[0].text)) {
            self.applyAssignments(command.assignments) catch |err| switch (err) {
                error.ReadonlyVariable => return self.assignmentErrorResult(),
                else => return err,
            };
            return builtin(self, command, stdin, options);
        }
        var assignment_scope = self.pushTemporaryAssignments(command.assignments) catch |err| switch (err) {
            error.ReadonlyVariable => return self.assignmentErrorResult(),
            else => return err,
        };
        defer assignment_scope.restore();
        return builtin(self, command, stdin, options);
    }

    fn executeFunctionBody(self: *Executor, command: ir.SimpleCommand, function_value: *const FunctionValue, options: ExecuteOptions) anyerror!CommandResult {
        var assignment_scope = self.pushTemporaryAssignments(command.assignments) catch |err| switch (err) {
            error.ReadonlyVariable => return self.assignmentErrorResult(),
            else => return err,
        };
        defer assignment_scope.restore();
        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const prior_stdin = self.script_stdin;
        const prior_stdin_offset = self.script_stdin_offset;
        defer {
            self.script_stdin = prior_stdin;
            self.script_stdin_offset = prior_stdin_offset;
        }
        const redirected_stdin = try self.applyCompoundInputRedirections(command.span, function_value.redirections, options, &owned_stdin);
        if (redirected_stdin) |stdin| {
            self.script_stdin = stdin;
            self.script_stdin_offset = 0;
        }
        var execution_options = options;
        if (function_value.redirections.len != 0) execution_options.external_stdio = .capture;
        try self.pushCallFrame(command.argv[1..]);
        defer self.popCallFrame();
        self.function_depth += 1;
        defer self.function_depth -= 1;
        var result = try self.executeProgram(function_value.program, execution_options);
        errdefer result.deinit();
        if (self.pending_return) |status| {
            self.pending_return = null;
            result.status = status;
        }
        return self.applyCompoundOutputRedirections(command.span, function_value.redirections, result, options);
    }

    fn expandSimpleCommand(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !ir.SimpleCommand {
        self.command_substitution_status = null;
        const assignments = try self.expandAssignmentWords(command.assignments, options);
        errdefer self.freeWords(assignments);
        const argv = try self.expandArgv(command.argv, options);
        errdefer self.freeWords(argv);
        const redirections = try self.expandRedirections(command.redirections, options);
        errdefer self.freeRedirections(redirections);

        return .{
            .span = command.span,
            .assignments = assignments,
            .argv = argv,
            .redirections = redirections,
        };
    }

    fn expandArgv(self: *Executor, words: []const ir.WordRef, options: ExecuteOptions) ![]ir.WordRef {
        var expanded: std.ArrayList(ir.WordRef) = .empty;
        errdefer {
            for (expanded.items) |word| self.freeWord(word);
            expanded.deinit(self.allocator);
        }

        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        const positionals: []const []const u8 = self.currentPositionals().params;
        for (words) |word| {
            var fields = try expand.expandWord(self.allocator, word.raw, .{ .env = self.envLookup(), .env_set = self.envSet(), .io = options.io, .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .positionals = positionals, .pathname_expansion = !self.shell_options.noglob, .nounset = self.shell_options.nounset, .parameter_error = &self.parameter_error });
            defer fields.deinit();
            for (fields.fields) |field| {
                const raw = try self.allocator.dupe(u8, word.raw);
                errdefer self.allocator.free(raw);
                const text = try self.allocator.dupe(u8, field);
                errdefer self.allocator.free(text);
                try expanded.append(self.allocator, .{ .span = word.span, .raw = raw, .text = text });
            }
        }

        return expanded.toOwnedSlice(self.allocator);
    }

    fn expandWords(self: *Executor, words: []const ir.WordRef, options: ExecuteOptions) ![]ir.WordRef {
        const expanded = try self.allocator.alloc(ir.WordRef, words.len);
        errdefer self.allocator.free(expanded);
        var initialized: usize = 0;
        errdefer for (expanded[0..initialized]) |word| self.freeWord(word);

        for (words, 0..) |word, index| {
            expanded[index] = try self.expandWord(word, options);
            initialized += 1;
        }
        return expanded;
    }

    fn expandAssignmentWords(self: *Executor, words: []const ir.WordRef, options: ExecuteOptions) ![]ir.WordRef {
        const expanded = try self.allocator.alloc(ir.WordRef, words.len);
        errdefer self.allocator.free(expanded);
        var initialized: usize = 0;
        errdefer for (expanded[0..initialized]) |word| self.freeWord(word);

        var scope = AssignmentExpansionScope.init(self);
        defer scope.restore();

        for (words, 0..) |word, index| {
            expanded[index] = try self.expandAssignmentWord(word, options);
            initialized += 1;
            try scope.apply(expanded[index]);
        }
        return expanded;
    }

    fn expandRedirections(self: *Executor, redirections: []const ir.Redirection, options: ExecuteOptions) ![]ir.Redirection {
        const expanded = try self.allocator.alloc(ir.Redirection, redirections.len);
        errdefer self.allocator.free(expanded);
        var initialized: usize = 0;
        errdefer for (expanded[0..initialized]) |redirection| self.freeRedirection(redirection);

        for (redirections, 0..) |redirection, index| {
            expanded[index] = .{
                .span = redirection.span,
                .io_number = if (redirection.io_number) |word| try self.expandWord(word, options) else null,
                .operator = redirection.operator,
                .target = if (redirection.target) |word| try self.expandWord(word, options) else null,
                .here_doc = if (redirection.here_doc) |text| try self.expandHereDoc(text, redirection.here_doc_quoted, options) else null,
                .here_doc_quoted = redirection.here_doc_quoted,
            };
            initialized += 1;
        }
        return expanded;
    }

    fn expandHereDoc(self: *Executor, text: []const u8, quoted: bool, options: ExecuteOptions) ![]const u8 {
        if (quoted) return self.allocator.dupe(u8, text);
        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        return expand.expandWordScalar(self.allocator, text, .{ .env = self.envLookup(), .env_set = self.envSet(), .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .nounset = self.shell_options.nounset, .parameter_error = &self.parameter_error });
    }

    fn expandWord(self: *Executor, word: ir.WordRef, options: ExecuteOptions) !ir.WordRef {
        const raw = try self.allocator.dupe(u8, word.raw);
        errdefer self.allocator.free(raw);
        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        const text = try expand.expandWordScalar(self.allocator, word.raw, .{ .env = self.envLookup(), .env_set = self.envSet(), .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .nounset = self.shell_options.nounset, .parameter_error = &self.parameter_error });
        return .{ .span = word.span, .raw = raw, .text = text };
    }

    fn expandCasePattern(self: *Executor, word: ir.WordRef, options: ExecuteOptions) !CasePattern {
        var parts = try expand.parseWordParts(self.allocator, word.raw);
        defer parts.deinit();

        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);
        var special: std.ArrayList(bool) = .empty;
        errdefer special.deinit(self.allocator);

        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        const expansion_options: expand.Options = .{ .env = self.envLookup(), .env_set = self.envSet(), .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .nounset = self.shell_options.nounset, .parameter_error = &self.parameter_error };

        for (parts.parts) |part| {
            const rendered = try expand.expandWordScalar(self.allocator, part.source(parts.raw), expansion_options);
            defer self.allocator.free(rendered);
            const meta_active = switch (part.kind) {
                .unquoted, .parameter, .arithmetic, .command_substitution => true,
                .single_quoted, .double_quoted, .escaped => false,
            };
            try appendCasePatternPart(self.allocator, &text, &special, rendered, meta_active);
        }

        return .{ .text = try text.toOwnedSlice(self.allocator), .special = try special.toOwnedSlice(self.allocator) };
    }

    fn expandAssignmentWord(self: *Executor, word: ir.WordRef, options: ExecuteOptions) !ir.WordRef {
        const raw = try self.allocator.dupe(u8, word.raw);
        errdefer self.allocator.free(raw);
        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        const text = try expand.expandAssignmentWordScalar(self.allocator, word.raw, .{ .env = self.envLookup(), .env_set = self.envSet(), .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .nounset = self.shell_options.nounset, .parameter_error = &self.parameter_error });
        return .{ .span = word.span, .raw = raw, .text = text };
    }

    fn findExecutableInPath(self: *Executor, io: std.Io, name: []const u8) !?[]const u8 {
        return self.findExecutableInPathValue(io, name, self.getEnv("PATH") orelse return null);
    }

    fn findExecutableInDefaultPath(self: *Executor, io: std.Io, name: []const u8) !?[]const u8 {
        return self.findExecutableInPathValue(io, name, "/bin:/usr/bin");
    }

    fn findExecutableInPathValue(self: *Executor, io: std.Io, name: []const u8, path_value: []const u8) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            std.Io.Dir.cwd().access(io, name, .{ .execute = true }) catch return null;
            return try self.allocator.dupe(u8, name);
        }
        var parts = std.mem.splitScalar(u8, path_value, ':');
        while (parts.next()) |part| {
            const dir = if (part.len == 0) "." else part;
            const candidate = try std.mem.concat(self.allocator, u8, &.{ dir, "/", name });
            errdefer self.allocator.free(candidate);
            std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => {
                    self.allocator.free(candidate);
                    continue;
                },
                else => return err,
            };
            return candidate;
        }
        return null;
    }

    fn readSourceFile(self: *Executor, io: std.Io, name: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            return std.Io.Dir.cwd().readFileAlloc(io, name, self.allocator, .limited(1024 * 1024));
        }

        if (self.getEnv("PATH")) |path_value| {
            var parts = std.mem.splitScalar(u8, path_value, ':');
            while (parts.next()) |dir| {
                const prefix = if (dir.len == 0) "." else dir;
                const candidate = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, name });
                defer self.allocator.free(candidate);
                return std.Io.Dir.cwd().readFileAlloc(io, candidate, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => |e| return e,
                };
            }
        }

        return std.Io.Dir.cwd().readFileAlloc(io, name, self.allocator, .limited(1024 * 1024));
    }

    fn pushCallFrame(self: *Executor, args: []const ir.WordRef) !void {
        var values = try self.allocator.alloc([]const u8, args.len);
        defer self.allocator.free(values);
        for (args, 0..) |arg, index| values[index] = arg.text;
        var frame: CallFrame = .{};
        errdefer frame.deinit(self.allocator);
        try frame.positionals.set(self.allocator, values);
        try self.call_frames.append(self.allocator, frame);
    }

    fn popCallFrame(self: *Executor) void {
        var frame = self.call_frames.pop().?;
        frame.deinit(self.allocator);
    }

    fn currentCallFrame(self: Executor) ?CallFrame {
        if (self.call_frames.items.len == 0) return null;
        return self.call_frames.items[self.call_frames.items.len - 1];
    }

    fn currentCallFramePtr(self: *Executor) ?*CallFrame {
        if (self.call_frames.items.len == 0) return null;
        return &self.call_frames.items[self.call_frames.items.len - 1];
    }

    fn currentPositionals(self: Executor) PositionalParams {
        if (self.currentCallFrame()) |frame| return frame.positionals;
        return self.global_positionals;
    }

    fn currentPositionalsPtr(self: *Executor) *PositionalParams {
        if (self.currentCallFramePtr()) |frame| return &frame.positionals;
        return &self.global_positionals;
    }

    const CommandSubstitutionContext = struct {
        executor: *Executor,
        options: ExecuteOptions,
    };

    fn commandSubstitution(context: *CommandSubstitutionContext) expand.CommandSubstitution {
        return .{ .context = context, .runFn = runCommandSubstitution };
    }

    fn runCommandSubstitution(context: ?*anyopaque, allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
        const substitution_context: *CommandSubstitutionContext = @ptrCast(@alignCast(context.?));
        var parsed = try @import("parser.zig").parse(substitution_context.executor.allocator, script, .{ .features = substitution_context.options.features });
        defer parsed.deinit();
        var program = try ir.lowerSimpleCommands(substitution_context.executor.allocator, parsed);
        defer program.deinit();
        var sub_options = substitution_context.options;
        sub_options.external_stdio = .capture_stdout;
        var child = Executor.init(substitution_context.executor.allocator);
        defer child.deinit();
        try child.copyStateFrom(substitution_context.executor);
        if (substitution_context.executor.completion_builder != null) child.completion_builder = .{};
        if (substitution_context.executor.prompt_builder != null) child.prompt_builder = .{};
        child.pending_exit = null;
        var result = try child.executeProgram(program, sub_options);
        defer result.deinit();
        substitution_context.executor.command_substitution_status = result.status;
        return allocator.dupe(u8, result.stdout);
    }

    fn envSet(self: *Executor) expand.EnvSet {
        return .{ .context = self, .setFn = setEnvCallback };
    }

    fn envLookup(self: *Executor) expand.EnvLookup {
        return .{ .context = self, .lookupFn = lookupEnv };
    }

    fn setEnvCallback(context: ?*anyopaque, name: []const u8, value: []const u8) !void {
        const self: *Executor = @ptrCast(@alignCast(context.?));
        try self.setEnv(name, value);
    }

    fn lookupEnv(context: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const Executor = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, name, "?")) return self.last_status_text[0..self.last_status_text_len];
        if (std.mem.eql(u8, name, "$")) return self.pid_text[0..self.pid_text_len];
        if (std.mem.eql(u8, name, "!")) return self.last_background_pid_text[0..self.last_background_pid_text_len];
        if (std.mem.eql(u8, name, "LINENO")) return self.lineno_text[0..self.lineno_text_len];
        if (std.mem.eql(u8, name, "0")) return self.arg_zero;
        const positionals = self.currentPositionals();
        if (std.mem.eql(u8, name, "#")) return positionals.count;
        if (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) return positionals.joined;
        if (name.len == 1 and std.ascii.isDigit(name[0]) and name[0] != '0') {
            const index = name[0] - '1';
            if (index < positionals.params.len) return positionals.params[index];
            return null;
        }
        return self.getEnv(name);
    }

    fn freeExpandedCommand(self: *Executor, command: ir.SimpleCommand) void {
        self.freeWords(command.assignments);
        self.freeWords(command.argv);
        self.freeRedirections(command.redirections);
    }

    fn freeWords(self: *Executor, words: []const ir.WordRef) void {
        for (words) |word| self.freeWord(word);
        self.allocator.free(words);
    }

    fn freeRedirections(self: *Executor, redirections: []const ir.Redirection) void {
        for (redirections) |redirection| self.freeRedirection(redirection);
        self.allocator.free(redirections);
    }

    fn freeRedirection(self: *Executor, redirection: ir.Redirection) void {
        if (redirection.io_number) |word| self.freeWord(word);
        if (redirection.target) |word| self.freeWord(word);
        if (redirection.here_doc) |text| self.allocator.free(text);
    }

    fn freeWord(self: *Executor, word: ir.WordRef) void {
        self.allocator.free(word.raw);
        self.allocator.free(word.text);
    }

    const SavedAssignment = struct {
        name: []const u8,
        old_value: ?[]const u8,
        old_exported: bool = false,
    };

    const AssignmentExpansionScope = struct {
        executor: *Executor,
        saved: std.ArrayList(SavedAssignment) = .empty,

        fn init(executor: *Executor) AssignmentExpansionScope {
            return .{ .executor = executor };
        }

        fn apply(self: *AssignmentExpansionScope, assignment: ir.WordRef) !void {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse return;
            const name = assignment.text[0..equals];
            const old_value = if (self.executor.getEnv(name)) |value| try self.executor.allocator.dupe(u8, value) else null;
            errdefer if (old_value) |value| self.executor.allocator.free(value);
            const owned_name = try self.executor.allocator.dupe(u8, name);
            errdefer self.executor.allocator.free(owned_name);
            try self.saved.append(self.executor.allocator, .{ .name = owned_name, .old_value = old_value, .old_exported = self.executor.isExported(name) });
            errdefer _ = self.saved.pop();
            try self.executor.setEnv(name, assignment.text[equals + 1 ..]);
        }

        fn restore(self: *AssignmentExpansionScope) void {
            var index = self.saved.items.len;
            while (index > 0) {
                index -= 1;
                const entry = self.saved.items[index];
                if (entry.old_value) |value| {
                    self.executor.setEnv(entry.name, value) catch {};
                    self.executor.allocator.free(value);
                } else {
                    self.executor.unsetEnv(entry.name);
                }
                self.executor.restoreExported(entry.name, entry.old_exported) catch {};
                self.executor.allocator.free(entry.name);
            }
            self.saved.deinit(self.executor.allocator);
            self.* = undefined;
        }
    };

    const AssignmentScope = struct {
        executor: *Executor,
        saved: []SavedAssignment,

        fn restore(self: *AssignmentScope) void {
            var index = self.saved.len;
            while (index > 0) {
                index -= 1;
                const entry = self.saved[index];
                if (entry.old_value) |value| {
                    self.executor.setEnv(entry.name, value) catch {};
                    self.executor.allocator.free(value);
                } else {
                    self.executor.unsetEnv(entry.name);
                }
                self.executor.restoreExported(entry.name, entry.old_exported) catch {};
                self.executor.allocator.free(entry.name);
            }
            self.executor.allocator.free(self.saved);
            self.* = undefined;
        }
    };

    fn pushTemporaryAssignments(self: *Executor, assignments: []const ir.WordRef) !AssignmentScope {
        const saved = try self.allocator.alloc(SavedAssignment, assignments.len);
        var initialized: usize = 0;
        errdefer {
            for (saved[0..initialized]) |entry| {
                self.allocator.free(entry.name);
                if (entry.old_value) |value| self.allocator.free(value);
            }
            self.allocator.free(saved);
        }

        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            const name = assignment.text[0..equals];
            const old_value = if (self.getEnv(name)) |value| try self.allocator.dupe(u8, value) else null;
            saved[initialized] = .{ .name = try self.allocator.dupe(u8, name), .old_value = old_value, .old_exported = self.isExported(name) };
            initialized += 1;
            try self.setEnv(name, assignment.text[equals + 1 ..]);
            try self.setExported(name);
        }

        return .{ .executor = self, .saved = saved[0..initialized] };
    }

    fn applyAssignments(self: *Executor, assignments: []const ir.WordRef) !void {
        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            const name = assignment.text[0..equals];
            try self.setEnv(name, assignment.text[equals + 1 ..]);
            if (self.shell_options.allexport) try self.setExported(name);
        }
    }

    fn buildProcessEnv(self: *Executor, assignments: []const ir.WordRef) !std.process.Environ.Map {
        var map = std.process.Environ.Map.init(self.allocator);
        errdefer map.deinit();
        var iter = self.exported.iterator();
        while (iter.next()) |entry| {
            if (self.env.get(entry.key_ptr.*)) |value| try map.put(entry.key_ptr.*, value);
        }
        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            try map.put(assignment.text[0..equals], assignment.text[equals + 1 ..]);
        }
        return map;
    }

    fn applyRealFdRedirectionsIfNeeded(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !?FdRedirectionGuard {
        if (options.external_stdio != .inherit or command.redirections.len == 0) return null;
        const io = options.io orelse return null;
        var guard = try FdRedirectionGuard.init(self.allocator, io);
        errdefer guard.restore(self, io);
        for (command.redirections) |redirection| {
            try guard.apply(self, io, redirection);
        }
        return guard;
    }

    fn applyPermanentRealFdRedirections(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !bool {
        if (options.external_stdio != .inherit or command.redirections.len == 0) return false;
        const io = options.io orelse return false;
        var guard = try FdRedirectionGuard.init(self.allocator, io);
        errdefer guard.restore(self, io);
        for (command.redirections) |redirection| try guard.apply(self, io, redirection);
        guard.commit(io);
        return true;
    }

    fn applyInputRedirections(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions, owned_stdin: *?[]u8) ![]const u8 {
        var current = stdin;
        for (command.redirections) |redirection| {
            if (isHereDocRedirection(redirection)) {
                if (owned_stdin.*) |bytes| self.allocator.free(bytes);
                owned_stdin.* = try self.allocator.dupe(u8, redirection.here_doc orelse "");
                current = owned_stdin.*.?;
                continue;
            }
            if (!isStdinFileRedirection(redirection)) continue;
            const io = options.io orelse return error.MissingIoForRedirection;
            const target = redirection.target orelse continue;
            if (owned_stdin.*) |bytes| self.allocator.free(bytes);
            if (redirection.operator == .less_great) {
                var file = try openReadWriteRedirectionFile(io, target.text);
                file.close(io);
            }
            owned_stdin.* = try std.Io.Dir.cwd().readFileAlloc(io, target.text, self.allocator, .limited(1024 * 1024));
            current = owned_stdin.*.?;
        }
        return current;
    }

    const OutputSink = union(enum) {
        stdout,
        stderr,
        file: FileOutputSink,
    };

    const FileOutputSink = struct {
        redirection: ir.Redirection,
        id: usize,
    };

    fn applyOutputRedirections(self: *Executor, command: ir.SimpleCommand, result: CommandResult, options: ExecuteOptions, special_exit: bool) !CommandResult {
        var redirected = result;
        errdefer redirected.deinit();

        var stdout_sink: OutputSink = .stdout;
        var stderr_sink: OutputSink = .stderr;
        var next_file_id: usize = 1;

        for (command.redirections) |redirection| {
            if (isFileOutputRedirection(redirection)) {
                const fd = redirectionFd(redirection) orelse 1;
                if (fd != 1 and fd != 2) continue;
                self.validateOutputRedirection(redirection, options) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        redirected.deinit();
                        const failure = try errorResult(self.allocator, 1, targetName(redirection), "cannot overwrite existing file");
                        if (special_exit) self.pending_exit = failure.status;
                        return failure;
                    },
                    error.IsDir => {
                        redirected.deinit();
                        const failure = try errorResult(self.allocator, 1, targetName(redirection), "is a directory");
                        if (special_exit) self.pending_exit = failure.status;
                        return failure;
                    },
                    else => return err,
                };
                const sink: OutputSink = .{ .file = .{ .redirection = redirection, .id = next_file_id } };
                next_file_id += 1;
                if (fd == 1) stdout_sink = sink else stderr_sink = sink;
                continue;
            }

            if (redirection.operator == .greater_and) {
                const from_fd = redirectionFd(redirection) orelse 1;
                const target = redirection.target orelse continue;
                const to_fd = parseFd(target.text) orelse continue;
                if ((from_fd == 1 or from_fd == 2) and (to_fd == 1 or to_fd == 2)) {
                    const copied = if (to_fd == 1) stdout_sink else stderr_sink;
                    if (from_fd == 1) stdout_sink = copied else stderr_sink = copied;
                }
            }
        }

        const original_stdout = redirected.stdout;
        const original_stderr = redirected.stderr;
        redirected.stdout = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(redirected.stdout);
        redirected.stderr = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(redirected.stderr);

        if (sameFileSink(stdout_sink, stderr_sink)) {
            const file_sink = stdout_sink.file;
            const combined = try std.mem.concat(self.allocator, u8, &.{ original_stdout, original_stderr });
            defer self.allocator.free(combined);
            try self.writeRedirectedBytes(combined, file_sink.redirection, options);
        } else {
            try self.routeCapturedStream(&redirected.stdout, &redirected.stderr, original_stdout, stdout_sink, options);
            try self.routeCapturedStream(&redirected.stdout, &redirected.stderr, original_stderr, stderr_sink, options);
        }

        self.allocator.free(original_stdout);
        self.allocator.free(original_stderr);
        return redirected;
    }

    fn sameFileSink(left: OutputSink, right: OutputSink) bool {
        if (left != .file or right != .file) return false;
        return left.file.id == right.file.id;
    }

    fn routeCapturedStream(self: *Executor, stdout: *[]u8, stderr: *[]u8, bytes: []const u8, sink: OutputSink, options: ExecuteOptions) !void {
        switch (sink) {
            .stdout => try appendOwnedBytes(self.allocator, stdout, bytes),
            .stderr => try appendOwnedBytes(self.allocator, stderr, bytes),
            .file => |file_sink| try self.writeRedirectedBytes(bytes, file_sink.redirection, options),
        }
    }

    fn appendOwnedBytes(allocator: std.mem.Allocator, target: *[]u8, bytes: []const u8) !void {
        const old_len = target.len;
        target.* = try allocator.realloc(target.*, old_len + bytes.len);
        @memcpy(target.*[old_len..], bytes);
    }

    fn validateOutputRedirection(self: *Executor, redirection: ir.Redirection, options: ExecuteOptions) !void {
        const io = options.io orelse return error.MissingIoForRedirection;
        const target = redirection.target orelse return;
        var file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
        file.close(io);
    }

    fn writeRedirectedBytes(self: *Executor, bytes: []const u8, redirection: ir.Redirection, options: ExecuteOptions) !void {
        const io = options.io orelse return error.MissingIoForRedirection;
        const target = redirection.target orelse return;
        var file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        if (redirection.operator == .dgreat) {
            try writer.seekTo(try file.length(io));
        }
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    fn applyExternalPostRedirections(self: *Executor, command: ir.SimpleCommand, result: CommandResult, options: ExecuteOptions) !CommandResult {
        _ = options;
        var redirected = result;
        errdefer redirected.deinit();
        for (command.redirections) |redirection| {
            if (redirection.operator == .greater_and) {
                try self.applyDescriptorDuplication(&redirected, redirection);
            }
        }
        return redirected;
    }

    fn applyDescriptorDuplication(self: *Executor, result: *CommandResult, redirection: ir.Redirection) !void {
        const from_fd = redirectionFd(redirection) orelse 1;
        const target = redirection.target orelse return;
        const to_fd = parseFd(target.text) orelse return;

        if (from_fd == 2 and to_fd == 1) {
            const combined = try self.allocator.alloc(u8, result.stdout.len + result.stderr.len);
            @memcpy(combined[0..result.stdout.len], result.stdout);
            @memcpy(combined[result.stdout.len..], result.stderr);
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            result.stdout = combined;
            result.stderr = try self.allocator.alloc(u8, 0);
        } else if (from_fd == 1 and to_fd == 2) {
            const combined = try self.allocator.alloc(u8, result.stderr.len + result.stdout.len);
            @memcpy(combined[0..result.stderr.len], result.stderr);
            @memcpy(combined[result.stderr.len..], result.stdout);
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            result.stdout = try self.allocator.alloc(u8, 0);
            result.stderr = combined;
        }
    }

    fn replaceWithExternal(self: *Executor, command: ir.SimpleCommand, io: std.Io, options: ExecuteOptions) !CommandResult {
        const executable = if (options.default_path_lookup)
            try self.findExecutableInDefaultPath(io, command.argv[0].text) orelse return errorResult(self.allocator, 127, command.argv[0].text, "command not found")
        else
            try self.findExecutableInPath(io, command.argv[0].text) orelse return errorResult(self.allocator, 127, command.argv[0].text, "command not found");
        defer self.allocator.free(executable);

        var child_env = try self.buildProcessEnv(command.assignments);
        defer child_env.deinit();
        var argv_storage: std.ArrayList([:0]u8) = .empty;
        defer {
            for (argv_storage.items) |arg| self.allocator.free(arg);
            argv_storage.deinit(self.allocator);
        }
        const argv_ptrs = try self.allocator.alloc(?[*:0]const u8, command.argv.len + 1);
        defer self.allocator.free(argv_ptrs);
        for (command.argv, 0..) |word, index| {
            const arg = try self.allocator.dupeZ(u8, word.text);
            errdefer self.allocator.free(arg);
            try argv_storage.append(self.allocator, arg);
            argv_ptrs[index] = arg.ptr;
        }
        argv_ptrs[command.argv.len] = null;

        var env_storage: std.ArrayList([:0]u8) = .empty;
        defer {
            for (env_storage.items) |entry| self.allocator.free(entry);
            env_storage.deinit(self.allocator);
        }
        const keys = child_env.keys();
        const values = child_env.values();
        const env_ptrs = try self.allocator.alloc(?[*:0]const u8, keys.len + 1);
        defer self.allocator.free(env_ptrs);
        for (keys, values, 0..) |key, value, index| {
            const printed = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ key, value });
            defer self.allocator.free(printed);
            const entry = try self.allocator.dupeZ(u8, printed);
            errdefer self.allocator.free(entry);
            try env_storage.append(self.allocator, entry);
            env_ptrs[index] = entry.ptr;
        }
        env_ptrs[keys.len] = null;

        const path = try self.allocator.dupeZ(u8, executable);
        defer self.allocator.free(path);
        execve(path.ptr, @ptrCast(argv_ptrs.ptr), @ptrCast(env_ptrs.ptr)) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return errorResult(self.allocator, 126, command.argv[0].text, "permission denied"),
            error.FileNotFound => return errorResult(self.allocator, 127, command.argv[0].text, "command not found"),
            else => return err,
        };
        unreachable;
    }

    fn setLastBackgroundPid(self: *Executor, pid: i64) void {
        const text = std.fmt.bufPrint(&self.last_background_pid_text, "{d}", .{pid}) catch return;
        self.last_background_pid_text_len = text.len;
    }

    fn executeExternalAsync(self: *Executor, command: ir.SimpleCommand, io: std.Io, options: ExecuteOptions) !CommandResult {
        const argv = try argvForCommand(self.allocator, command);
        defer self.allocator.free(argv);
        const resolved_executable = self.resolveExternalArgv0(command, io, options) catch |err| switch (err) {
            error.CommandNotFound => return errorResult(self.allocator, 127, command.argv[0].text, "command not found"),
            else => return err,
        };
        defer if (resolved_executable) |executable| self.allocator.free(executable);
        if (resolved_executable) |executable| argv[0] = executable;

        var stdin_file: ?std.Io.File = null;
        defer if (stdin_file) |file| file.close(io);
        var stdout_file: ?std.Io.File = null;
        defer if (stdout_file) |file| file.close(io);
        var stderr_file: ?std.Io.File = null;
        defer if (stderr_file) |file| file.close(io);

        for (command.redirections) |redirection| {
            if (isHereDocRedirection(redirection)) {
                if (stdin_file) |file| file.close(io);
                stdin_file = try fileFromBytes(io, redirection.here_doc orelse "");
                continue;
            }
            if (isStdinFileRedirection(redirection)) {
                const target = redirection.target orelse continue;
                if (stdin_file) |file| file.close(io);
                stdin_file = try std.Io.Dir.cwd().openFile(io, target.text, .{});
                continue;
            }
            if (isFileOutputRedirection(redirection)) {
                const target = redirection.target orelse continue;
                const fd = redirectionFd(redirection) orelse 1;
                var file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
                switch (fd) {
                    1 => {
                        if (stdout_file) |old| old.close(io);
                        stdout_file = file;
                    },
                    2 => {
                        if (stderr_file) |old| old.close(io);
                        stderr_file = file;
                    },
                    else => file.close(io),
                }
                continue;
            }
            if (redirection.operator == .greater_and) {
                const from_fd = redirectionFd(redirection) orelse 1;
                const target = redirection.target orelse continue;
                if (std.mem.eql(u8, target.text, "-")) {
                    if (from_fd == 1) {
                        if (stdout_file) |old| old.close(io);
                        stdout_file = null;
                    } else if (from_fd == 2) {
                        if (stderr_file) |old| old.close(io);
                        stderr_file = null;
                    }
                    continue;
                }
                const to_fd = parseFd(target.text) orelse continue;
                if (from_fd == 2 and to_fd == 1 and stdout_file != null) {
                    if (stderr_file) |old| old.close(io);
                    const duped = try rawDup(stdout_file.?.handle);
                    stderr_file = .{ .handle = duped, .flags = stdout_file.?.flags };
                } else if (from_fd == 1 and to_fd == 2 and stderr_file != null) {
                    if (stdout_file) |old| old.close(io);
                    const duped = try rawDup(stderr_file.?.handle);
                    stdout_file = .{ .handle = duped, .flags = stderr_file.?.flags };
                }
            }
        }

        var child_env = try self.buildProcessEnv(command.assignments);
        defer child_env.deinit();
        var child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = &child_env,
            .stdin = if (stdin_file) |file| .{ .file = file } else if (options.external_stdio == .inherit) .inherit else .close,
            .stdout = if (stdout_file) |file| .{ .file = file } else if (options.external_stdio == .inherit) .inherit else .ignore,
            .stderr = if (stderr_file) |file| .{ .file = file } else if (options.external_stdio == .inherit) .inherit else .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => return errorResult(self.allocator, 127, command.argv[0].text, "command not found"),
            else => return err,
        };
        errdefer child.kill(io);
        if (child.id) |pid| {
            const numeric_pid: i64 = @intCast(pid);
            self.setLastBackgroundPid(numeric_pid);
            const argv_text = try argvForCommand(self.allocator, command);
            defer self.allocator.free(argv_text);
            const command_text = try joinParams(self.allocator, argv_text);
            errdefer self.allocator.free(command_text);
            try self.background_jobs.append(self.allocator, .{ .id = self.next_job_id, .pid = numeric_pid, .command = command_text, .child = child });
            self.selectCurrentJob(self.next_job_id);
            self.next_job_id += 1;
        }
        return emptyResult(self.allocator, 0);
    }

    fn remainingScriptStdin(self: Executor) ?[]const u8 {
        const script_stdin = self.script_stdin orelse return null;
        if (self.script_stdin_offset >= script_stdin.len) return null;
        return script_stdin[self.script_stdin_offset..];
    }

    fn executeExternal(self: *Executor, command: ir.SimpleCommand, io: std.Io, options: ExecuteOptions) !CommandResult {
        const argv = try argvForCommand(self.allocator, command);
        defer self.allocator.free(argv);
        const resolved_executable = self.resolveExternalArgv0(command, io, options) catch |err| switch (err) {
            error.CommandNotFound => return error.CommandNotFound,
            else => return err,
        };
        defer if (resolved_executable) |executable| self.allocator.free(executable);
        if (resolved_executable) |executable| argv[0] = executable;

        var stdin_file: ?std.Io.File = null;
        defer if (stdin_file) |file| file.close(io);
        var stdout_file: ?std.Io.File = null;
        defer if (stdout_file) |file| file.close(io);
        var stderr_file: ?std.Io.File = null;
        defer if (stderr_file) |file| file.close(io);

        for (command.redirections) |redirection| {
            if (isHereDocRedirection(redirection)) {
                if (stdin_file) |file| file.close(io);
                stdin_file = try fileFromBytes(io, redirection.here_doc orelse "");
                continue;
            }
            if (isStdinFileRedirection(redirection)) {
                const target = redirection.target orelse continue;
                if (stdin_file) |file| file.close(io);
                stdin_file = try std.Io.Dir.cwd().openFile(io, target.text, .{});
                continue;
            }
            if (isFileOutputRedirection(redirection)) {
                const target = redirection.target orelse continue;
                const fd = redirectionFd(redirection) orelse 1;
                var file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
                switch (fd) {
                    1 => {
                        if (stdout_file) |old| old.close(io);
                        stdout_file = file;
                    },
                    2 => {
                        if (stderr_file) |old| old.close(io);
                        stderr_file = file;
                    },
                    else => file.close(io),
                }
                continue;
            }
            if (redirection.operator == .greater_and) {
                const from_fd = redirectionFd(redirection) orelse 1;
                const target = redirection.target orelse continue;
                if (std.mem.eql(u8, target.text, "-")) {
                    if (from_fd == 1) {
                        if (stdout_file) |old| old.close(io);
                        stdout_file = null;
                    } else if (from_fd == 2) {
                        if (stderr_file) |old| old.close(io);
                        stderr_file = null;
                    }
                    continue;
                }
                const to_fd = parseFd(target.text) orelse continue;
                if (from_fd == 2 and to_fd == 1 and stdout_file != null) {
                    if (stderr_file) |old| old.close(io);
                    const duped = try rawDup(stdout_file.?.handle);
                    stderr_file = .{ .handle = duped, .flags = stdout_file.?.flags };
                } else if (from_fd == 1 and to_fd == 2 and stderr_file != null) {
                    if (stdout_file) |old| old.close(io);
                    const duped = try rawDup(stderr_file.?.handle);
                    stdout_file = .{ .handle = duped, .flags = stderr_file.?.flags };
                }
            }
        }

        if (stdin_file == null and externalStdinUsesScriptInput(options.external_stdio)) {
            if (self.remainingScriptStdin()) |stdin| {
                stdin_file = try fileFromBytes(io, stdin);
                self.script_stdin_offset = (self.script_stdin orelse unreachable).len;
            }
        }

        var child_env = try self.buildProcessEnv(command.assignments);
        defer child_env.deinit();
        const duplicate_stderr_to_stdout = externalStdioCapturesStdout(options.external_stdio) and stderr_file == null and commandDuplicatesStderrToStdout(command.redirections);
        const capture_stdout = externalStdioCapturesStdout(options.external_stdio) and stdout_file == null and !duplicate_stderr_to_stdout;
        const capture_stderr = stderr_file == null and externalStdioCapturesStderr(options.external_stdio);
        var merged_capture: ?PipelinePipe = if (duplicate_stderr_to_stdout) try makePipelinePipe(io) else null;
        defer if (merged_capture) |*pipe| pipe.close(io);
        const merged_stderr_write: ?std.Io.File = if (merged_capture) |pipe| .{ .handle = try rawDup(pipe.write.?.handle), .flags = pipe.write.?.flags } else null;
        const foreground_terminal = try prepareForegroundTerminal(options.external_stdio == .inherit and stdin_file == null);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = &child_env,
            .stdin = if (stdin_file) |file| .{ .file = file } else if (externalStdioInheritsStdin(options.external_stdio)) .inherit else .close,
            .stdout = if (stdout_file) |file| .{ .file = file } else if (merged_capture) |pipe| .{ .file = pipe.write.? } else if (capture_stdout) .pipe else .inherit,
            .stderr = if (stderr_file) |file| .{ .file = file } else if (merged_stderr_write) |file| .{ .file = file } else if (capture_stderr) .pipe else .inherit,
            .pgid = if (foreground_terminal != null) 0 else null,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.CommandNotFound,
            else => return err,
        };
        defer child.kill(io);
        if (merged_capture) |*pipe| {
            pipe.write.?.close(io);
            pipe.write = null;
        }
        if (merged_stderr_write) |file| file.close(io);
        defer if (capture_stdout) if (child.stdout) |file| file.close(io);
        defer if (capture_stderr) if (child.stderr) |file| file.close(io);
        try giveTerminalToForegroundChild(&child, foreground_terminal);
        defer restoreForegroundTerminal(foreground_terminal);

        var stdout: []u8 = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(stdout);
        var stderr: []u8 = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(stderr);

        if (capture_stdout and capture_stderr) {
            var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
            var multi_reader: std.Io.File.MultiReader = undefined;
            multi_reader.init(self.allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
            defer multi_reader.deinit();
            while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
                error.EndOfStream => {},
                else => |e| return e,
            }
            try multi_reader.checkAnyError();
            self.allocator.free(stdout);
            self.allocator.free(stderr);
            stdout = try multi_reader.toOwnedSlice(0);
            stderr = try multi_reader.toOwnedSlice(1);
            child.stdout.?.close(io);
            child.stdout = null;
            child.stderr.?.close(io);
            child.stderr = null;
        } else if (capture_stdout) {
            var reader_buffer: [4096]u8 = undefined;
            var reader = child.stdout.?.reader(io, &reader_buffer);
            self.allocator.free(stdout);
            stdout = try reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024));
            child.stdout.?.close(io);
            child.stdout = null;
        } else if (capture_stderr) {
            var reader_buffer: [4096]u8 = undefined;
            var reader = child.stderr.?.reader(io, &reader_buffer);
            self.allocator.free(stderr);
            stderr = try reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024));
            child.stderr.?.close(io);
            child.stderr = null;
        } else if (merged_capture) |pipe| {
            var reader_buffer: [4096]u8 = undefined;
            var reader = pipe.read.?.reader(io, &reader_buffer);
            const combined = try reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024));
            self.allocator.free(stdout);
            self.allocator.free(stderr);
            stdout = combined;
            stderr = try self.allocator.alloc(u8, 0);
        }

        const term = try child.wait(io);
        return .{
            .allocator = self.allocator,
            .status = exitStatusFromTerm(term),
            .stdout = stdout,
            .stderr = stderr,
        };
    }

    fn resolveExternalArgv0(self: *Executor, command: ir.SimpleCommand, io: std.Io, options: ExecuteOptions) !?[]const u8 {
        if (!options.default_path_lookup) return null;
        if (std.mem.indexOfScalar(u8, command.argv[0].text, '/') != null) return null;
        return try self.findExecutableInDefaultPath(io, command.argv[0].text) orelse return error.CommandNotFound;
    }
};

const ExecveError = error{ FileNotFound, AccessDenied, PermissionDenied, ExecFailed, Unsupported };

fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) ExecveError!void {
    if (zig_builtin.os.tag == .windows or zig_builtin.os.tag == .wasi) return error.Unsupported;
    if (zig_builtin.link_libc) {
        const rc = std.c.execve(path, argv, envp);
        return switch (std.c.errno(rc)) {
            .SUCCESS => unreachable,
            .NOENT, .NOTDIR => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            else => error.ExecFailed,
        };
    }
    if (zig_builtin.os.tag == .linux) {
        const rc = std.os.linux.execve(path, argv, envp);
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => unreachable,
            .NOENT, .NOTDIR => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            else => error.ExecFailed,
        };
    }
    return error.Unsupported;
}

fn shellPid() i64 {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) return @intCast(std.os.linux.getpid());
    return @intCast(std.c.getpid());
}

fn shellUmask(mask: u16) u16 {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        return @intCast(std.os.linux.syscall1(.umask, mask));
    }
    return @intCast(std.c.umask(mask));
}

const FdRedirectionGuard = struct {
    const SavedFd = struct {
        fd: std.posix.fd_t,
        saved: ?std.posix.fd_t,
    };

    allocator: std.mem.Allocator,
    saved: std.ArrayList(SavedFd) = .empty,
    active: bool = true,

    fn init(allocator: std.mem.Allocator, io: std.Io) !FdRedirectionGuard {
        _ = io;
        return .{ .allocator = allocator };
    }

    fn saveFd(self: *FdRedirectionGuard, executor: *Executor, fd: std.posix.fd_t) !void {
        for (self.saved.items) |entry| if (entry.fd == fd) return;
        const should_save = fd <= 2 or executor.isShellFdOpen(fd);
        const saved_fd = if (should_save) rawDup(fd) catch |err| switch (err) {
            error.BadFileDescriptor => null,
            else => return err,
        } else null;
        try self.saved.append(self.allocator, .{ .fd = fd, .saved = saved_fd });
    }

    fn apply(self: *FdRedirectionGuard, executor: *Executor, io: std.Io, redirection: ir.Redirection) !void {
        if (isHereDocRedirection(redirection)) {
            try self.saveFd(executor, 0);
            var file = try fileFromBytes(io, redirection.here_doc orelse "");
            defer if (file.handle != 0) file.close(io);
            try rawDup2(file.handle, 0);
            return;
        }
        if (isStdinFileRedirection(redirection)) {
            const target = redirection.target orelse return;
            try self.saveFd(executor, 0);
            var file = if (redirection.operator == .less_great)
                try openReadWriteRedirectionFile(io, target.text)
            else
                try std.Io.Dir.cwd().openFile(io, target.text, .{});
            defer if (file.handle != 0) file.close(io);
            try rawDup2(file.handle, 0);
            return;
        }
        if (redirection.operator == .less_great) {
            const target = redirection.target orelse return;
            const fd = redirectionFd(redirection) orelse 0;
            try self.saveFd(executor, fd);
            var file = try openReadWriteRedirectionFile(io, target.text);
            defer if (file.handle != fd) file.close(io);
            try rawDup2(file.handle, fd);
            try executor.markShellFdOpen(fd);
            return;
        }
        if (isFileOutputRedirection(redirection)) {
            const target = redirection.target orelse return;
            const fd = redirectionFd(redirection) orelse 1;
            try self.saveFd(executor, fd);
            var file = try openOutputRedirectionFile(io, target.text, redirection.operator, executor.shell_options.noclobber);
            defer if (file.handle != fd) file.close(io);
            try rawDup2(file.handle, fd);
            try executor.markShellFdOpen(fd);
            return;
        }
        if (redirection.operator == .greater_and or redirection.operator == .less_and) {
            const default_fd: std.posix.fd_t = if (redirection.operator == .less_and) 0 else 1;
            const from_fd = redirectionFd(redirection) orelse default_fd;
            const target = redirection.target orelse return;
            try self.saveFd(executor, from_fd);
            if (std.mem.eql(u8, target.text, "-")) {
                closeRawFd(io, from_fd);
                executor.markShellFdClosed(from_fd);
                return;
            }
            const to_fd = parseFd(target.text) orelse return;
            if (!executor.isShellFdOpen(to_fd)) return error.BadFileDescriptor;
            try rawDup2(to_fd, from_fd);
            try executor.markShellFdOpen(from_fd);
            return;
        }
    }

    fn commit(self: *FdRedirectionGuard, io: std.Io) void {
        if (!self.active) return;
        for (self.saved.items) |entry| {
            if (entry.saved) |saved_fd| closeRawFd(io, saved_fd);
        }
        self.saved.deinit(self.allocator);
        self.active = false;
    }

    fn restore(self: *FdRedirectionGuard, executor: *Executor, io: std.Io) void {
        if (!self.active) return;
        var index = self.saved.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.saved.items[index];
            if (entry.saved) |saved_fd| {
                rawDup2(saved_fd, entry.fd) catch {};
                closeRawFd(io, saved_fd);
            } else {
                closeRawFd(io, entry.fd);
                executor.markShellFdClosed(entry.fd);
            }
        }
        self.saved.deinit(self.allocator);
        self.active = false;
    }
};

fn writeInheritedResult(io: std.Io, result: CommandResult) !void {
    _ = io;
    try rawWriteAll(1, result.stdout);
    try rawWriteAll(2, result.stderr);
}

fn rawWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try rawWrite(fd, remaining);
        remaining = remaining[written..];
    }
}

fn rawWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .BADF => return error.BadFileDescriptor,
            .INTR => return rawWrite(fd, bytes),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
}

fn rawDup(fd: std.posix.fd_t) !std.posix.fd_t {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        const rc = std.os.linux.dup(fd);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.dup(fd);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn rawDup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    if (old_fd == new_fd) return;
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        const rc = std.os.linux.dup2(old_fd, new_fd);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .BADF => return error.BadFileDescriptor,
            .BUSY => return error.FileBusy,
            .INTR => return rawDup2(old_fd, new_fd),
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.dup2(old_fd, new_fd);
        switch (std.c.errno(rc)) {
            .SUCCESS => return,
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn makePipelinePipe(io: std.Io) !Executor.PipelinePipe {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .linux => blk: {
            var fds: [2]i32 = undefined;
            const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            break :blk filesFromPipeFds(fds);
        },
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => blk: {
            var fds: [2]std.c.fd_t = undefined;
            const rc = std.c.pipe(&fds);
            switch (std.c.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            errdefer {
                closeRawFd(io, fds[0]);
                closeRawFd(io, fds[1]);
            }
            try setCloseOnExec(fds[0]);
            try setCloseOnExec(fds[1]);
            break :blk filesFromPipeFds(.{ fds[0], fds[1] });
        },
        else => error.Unsupported,
    };
}

fn closeRawFd(io: std.Io, fd: std.posix.fd_t) void {
    _ = io;
    rawClose(fd) catch {};
}

fn rawClose(fd: std.posix.fd_t) !void {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        const rc = std.os.linux.close(fd);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS, .BADF => return,
            .INTR => return rawClose(fd),
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.close(fd);
        switch (std.c.errno(rc)) {
            .SUCCESS, .BADF => return,
            .INTR => continue,
            else => return error.Unexpected,
        }
    }
}

fn forkProcess() !std.posix.pid_t {
    if (comptime zig_builtin.link_libc) {
        while (true) {
            const rc = std.c.fork();
            switch (std.c.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN, .NOMEM => return error.SystemResources,
                else => return error.Unexpected,
            }
        }
    }
    if (comptime zig_builtin.os.tag == .linux) {
        const rc = std.os.linux.fork();
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    return error.Unsupported;
}

fn exitForkedChild(status: ExitStatus) noreturn {
    if (comptime zig_builtin.link_libc) std.c._exit(status);
    if (comptime zig_builtin.os.tag == .linux) std.os.linux.exit(status);
    unreachable;
}

fn childFromPid(pid: std.posix.pid_t) std.process.Child {
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
}

fn statementText(program: ir.Program, statement: ir.Statement) []const u8 {
    return switch (statement.kind) {
        .pipeline => pipelineText(program, program.pipelines[statement.index]),
        .if_command => spanText(program.source, program.if_commands[statement.index].span),
        .loop_command => spanText(program.source, program.loop_commands[statement.index].span),
        .for_command => spanText(program.source, program.for_commands[statement.index].span),
        .case_command => spanText(program.source, program.case_commands[statement.index].span),
        .function_definition => spanText(program.source, program.function_definitions[statement.index].span),
        .bash_test_command => spanText(program.source, program.bash_test_commands[statement.index].span),
        .brace_group => spanText(program.source, program.brace_groups[statement.index].span),
        .subshell => spanText(program.source, program.subshells[statement.index].span),
    };
}

fn pipelineText(program: ir.Program, pipeline: ir.Pipeline) []const u8 {
    return spanText(program.source, pipeline.span);
}

fn spanText(source: []const u8, span: parser.Span) []const u8 {
    return source[@min(span.start, source.len)..@min(span.end, source.len)];
}

fn sourceLineNumber(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (source[0..@min(offset, source.len)]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    const rc = std.c.fcntl(fd, @as(c_int, std.c.F.SETFD), @as(c_int, std.c.FD_CLOEXEC));
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.FileDescriptorNotASocket,
        .INVAL => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn filesFromPipeFds(fds: [2]std.posix.fd_t) Executor.PipelinePipe {
    return .{
        .read = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .write = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;
extern "c" fn tcsetpgrp(fd: std.c.fd_t, pgrp: std.c.pid_t) c_int;

const ForegroundTerminal = struct {
    tty_fd: std.posix.fd_t,
    previous_pgrp: std.posix.pid_t,
};

fn terminalGetPgrp(fd: std.posix.fd_t) !std.posix.pid_t {
    if (zig_builtin.link_libc) {
        while (true) {
            const rc = tcgetpgrp(fd);
            switch (std.c.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .BADF, .INVAL => unreachable,
                .INTR => continue,
                .NOTTY => return error.NotATerminal,
                else => return error.Unexpected,
            }
        }
    }
    return std.posix.tcgetpgrp(fd);
}

fn terminalSetPgrp(fd: std.posix.fd_t, pgrp: std.posix.pid_t) !void {
    if (zig_builtin.link_libc) {
        while (true) {
            const rc = tcsetpgrp(fd, pgrp);
            switch (std.c.errno(rc)) {
                .SUCCESS => return,
                .BADF, .INVAL => unreachable,
                .INTR => continue,
                .NOTTY => return error.NotATerminal,
                .PERM => return error.NotAPgrpMember,
                else => return error.Unexpected,
            }
        }
    }
    return std.posix.tcsetpgrp(fd, pgrp);
}

fn prepareForegroundTerminal(enabled: bool) !?ForegroundTerminal {
    if (!enabled) return null;
    const tty_fd = std.Io.File.stdin().handle;
    const previous_pgrp = terminalGetPgrp(tty_fd) catch |err| switch (err) {
        error.NotATerminal => return null,
        else => return err,
    };
    return .{ .tty_fd = tty_fd, .previous_pgrp = previous_pgrp };
}

fn giveTerminalToForegroundChild(child: *std.process.Child, terminal: ?ForegroundTerminal) !void {
    const child_pgrp = child.id orelse return;
    return giveTerminalToForegroundPgrp(child_pgrp, terminal);
}

fn giveTerminalToForegroundPgrp(pgrp: std.posix.pid_t, terminal: ?ForegroundTerminal) !void {
    const active = terminal orelse return;
    var sigttou = ignoreSignal(.TTOU);
    defer sigttou.restore();
    terminalSetPgrp(active.tty_fd, pgrp) catch |err| switch (err) {
        error.NotATerminal, error.NotAPgrpMember => return,
        else => return err,
    };
}

fn restoreForegroundTerminal(terminal: ?ForegroundTerminal) void {
    const active = terminal orelse return;
    var sigttou = ignoreSignal(.TTOU);
    defer sigttou.restore();
    terminalSetPgrp(active.tty_fd, active.previous_pgrp) catch {};
}

fn trapSignalHandler(signal: std.posix.SIG) callconv(.c) void {
    pending_trap_signal.store(@intCast(@intFromEnum(signal)), .seq_cst);
}

fn installTrapSignal(signal: std.posix.SIG) void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = trapSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &action, null);
}

fn restoreDefaultSignal(signal: std.posix.SIG) void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &action, null);
}

fn signalFromTrapName(name: []const u8) ?std.posix.SIG {
    if (std.mem.eql(u8, name, "HUP")) return .HUP;
    if (std.mem.eql(u8, name, "INT")) return .INT;
    if (std.mem.eql(u8, name, "QUIT")) return .QUIT;
    if (std.mem.eql(u8, name, "TERM")) return .TERM;
    if (std.mem.eql(u8, name, "USR1")) return .USR1;
    if (std.mem.eql(u8, name, "USR2")) return .USR2;
    return null;
}

fn signalNameFromNumber(raw: u8) ?[]const u8 {
    inline for (.{ "HUP", "INT", "QUIT", "TERM", "USR1", "USR2" }) |name| {
        const signal = signalFromTrapName(name).?;
        if (raw == @intFromEnum(signal)) return name;
    }
    return null;
}

const SignalActionGuard = struct {
    signal: std.posix.SIG,
    previous: std.posix.Sigaction,

    fn restore(self: *SignalActionGuard) void {
        std.posix.sigaction(self.signal, &self.previous, null);
    }
};

fn ignoreSignal(signal: std.posix.SIG) SignalActionGuard {
    const ignored: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(signal, &ignored, &previous);
    return .{ .signal = signal, .previous = previous };
}

fn fileFromBytes(io: std.Io, bytes: []const u8) !std.Io.File {
    var name_buffer: [128]u8 = undefined;
    var attempts: usize = 0;
    const Counter = struct {
        var value: std.atomic.Value(u64) = .init(0);
    };
    while (attempts < 32) : (attempts += 1) {
        const suffix = Counter.value.fetchAdd(1, .monotonic);
        const name = try std.fmt.bufPrint(&name_buffer, ".rush-heredoc-{d}-{d}.tmp", .{ shellPid(), suffix });
        var write_file = std.Io.Dir.cwd().createFile(io, name, .{ .truncate = false, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer write_file.close(io);
        errdefer std.Io.Dir.cwd().deleteFile(io, name) catch {};
        try writeBytesToFile(io, write_file, bytes);
        const read_file = try std.Io.Dir.cwd().openFile(io, name, .{});
        std.Io.Dir.cwd().deleteFile(io, name) catch {};
        return read_file;
    }
    return error.PathAlreadyExists;
}

fn writeBytesToFile(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn openReadWriteRedirectionFile(io: std.Io, target: []const u8) !std.Io.File {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows, .wasi => std.Io.Dir.cwd().createFile(io, target, .{ .truncate = false }),
        else => blk: {
            const fd = try std.posix.openat(std.Io.Dir.cwd().handle, target, .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            }, 0o666);
            break :blk .{ .handle = fd, .flags = .{ .nonblocking = false } };
        },
    };
}

fn openOutputRedirectionFile(io: std.Io, target: []const u8, operator: parser.TokenKind, noclobber: bool) !std.Io.File {
    return switch (operator) {
        .dgreat => openAppendRedirectionFile(io, target),
        .clobber => std.Io.Dir.cwd().createFile(io, target, .{ .truncate = true }),
        .greater => if (noclobber)
            std.Io.Dir.cwd().createFile(io, target, .{ .truncate = false, .exclusive = true })
        else
            std.Io.Dir.cwd().createFile(io, target, .{ .truncate = true }),
        else => unreachable,
    };
}

fn openAppendRedirectionFile(io: std.Io, target: []const u8) !std.Io.File {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows, .wasi => std.Io.Dir.cwd().createFile(io, target, .{ .truncate = false }),
        else => blk: {
            const fd = try std.posix.openat(std.Io.Dir.cwd().handle, target, .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .APPEND = true,
                .CLOEXEC = true,
            }, 0o666);
            break :blk .{ .handle = fd, .flags = .{ .nonblocking = false } };
        },
    };
}

fn traceLineForCommand(allocator: std.mem.Allocator, command: ir.SimpleCommand) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    try line.appendSlice(allocator, "+");
    for (command.assignments) |assignment| {
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, assignment.raw);
    }
    for (command.argv) |arg| {
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, arg.raw);
    }
    try line.append(allocator, '\n');
    return line.toOwnedSlice(allocator);
}

fn simpleCommandFromArgs(command: ir.SimpleCommand, start: usize) ir.SimpleCommand {
    return .{
        .span = command.span,
        .assignments = command.assignments,
        .argv = command.argv[start..],
        .redirections = &.{},
    };
}

fn stdoutLine(allocator: std.mem.Allocator, text: []const u8, status: ExitStatus) !CommandResult {
    const stdout = try std.fmt.allocPrint(allocator, "{s}\n", .{text});
    errdefer allocator.free(stdout);
    return .{ .allocator = allocator, .status = status, .stdout = stdout, .stderr = try allocator.alloc(u8, 0) };
}

fn stdoutLineFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype, status: ExitStatus) !CommandResult {
    const text = try std.fmt.allocPrint(allocator, fmt ++ "\n", args);
    errdefer allocator.free(text);
    return .{ .allocator = allocator, .status = status, .stdout = text, .stderr = try allocator.alloc(u8, 0) };
}

fn argvForCommand(allocator: std.mem.Allocator, command: ir.SimpleCommand) ![][]const u8 {
    const argv = try allocator.alloc([]const u8, command.argv.len);
    for (command.argv, 0..) |word, index| {
        argv[index] = word.text;
    }
    return argv;
}

fn isShellSeparatorByte(byte: u8) bool {
    return byte == '\n' or byte == ';' or byte == '&' or byte == '|';
}

fn containsAliasCommandToken(script: []const u8) bool {
    var index: usize = 0;
    while (index < script.len) {
        const start = index;
        while (index < script.len and !isAliasWordBoundary(script[index])) : (index += 1) {}
        const word = script[start..index];
        if (std.mem.eql(u8, word, "alias")) return true;
        if (index < script.len) index += 1;
    }
    return false;
}

fn canExecuteAsAliasTimingChunks(program: ir.Program) bool {
    if (program.statements.len < 2) return false;
    var previous_end: usize = 0;
    for (program.statements, 0..) |statement, index| {
        if (statement.op_before != .sequence or statement.async_after) return false;
        if (index != 0 and statement.span.start < previous_end) return false;
        previous_end = statement.span.end;
    }
    return true;
}

fn isAliasWordBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == ';' or byte == '&' or byte == '|' or byte == '(' or byte == ')' or byte == '<' or byte == '>';
}

fn isAliasTrailingBlank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isActiveAlias(active_aliases: []const []const u8, word: []const u8) bool {
    for (active_aliases) |active| {
        if (std.mem.eql(u8, active, word)) return true;
    }
    return false;
}

fn isReservedAliasWord(word: []const u8) bool {
    return std.mem.eql(u8, word, "if") or
        std.mem.eql(u8, word, "then") or
        std.mem.eql(u8, word, "else") or
        std.mem.eql(u8, word, "elif") or
        std.mem.eql(u8, word, "fi") or
        std.mem.eql(u8, word, "do") or
        std.mem.eql(u8, word, "done") or
        std.mem.eql(u8, word, "case") or
        std.mem.eql(u8, word, "esac") or
        std.mem.eql(u8, word, "for") or
        std.mem.eql(u8, word, "while") or
        std.mem.eql(u8, word, "until") or
        std.mem.eql(u8, word, "in") or
        std.mem.eql(u8, word, "{") or
        std.mem.eql(u8, word, "}") or
        std.mem.eql(u8, word, "!");
}

fn looksLikeFunctionDefinitionName(script: []const u8, after_word: usize) bool {
    var index = after_word;
    while (index < script.len and (script[index] == ' ' or script[index] == '\t' or script[index] == '\r')) : (index += 1) {}
    if (index >= script.len or script[index] != '(') return false;
    index += 1;
    while (index < script.len and (script[index] == ' ' or script[index] == '\t' or script[index] == '\r')) : (index += 1) {}
    return index < script.len and script[index] == ')';
}

fn shouldSkipPipeline(op: ir.ListOp, previous_status: ExitStatus) bool {
    return switch (op) {
        .sequence => false,
        .and_if => previous_status != 0,
        .or_if => previous_status == 0,
    };
}

fn isAndOrListOp(op: ir.ListOp) bool {
    return op == .and_if or op == .or_if;
}

fn isFollowedByAndOrListOp(statements: []const ir.Statement, index: usize) bool {
    return index + 1 < statements.len and isAndOrListOp(statements[index + 1].op_before);
}

fn isPipelineFollowedByAndOrListOp(pipelines: []const ir.Pipeline, index: usize) bool {
    return index + 1 < pipelines.len and isAndOrListOp(pipelines[index + 1].op_before);
}

const BuiltinFn = *const fn (*Executor, ir.SimpleCommand, []const u8, ExecuteOptions) anyerror!CommandResult;

fn isSpecialBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, ":") or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "break") or
        std.mem.eql(u8, name, "continue") or
        std.mem.eql(u8, name, "eval") or
        std.mem.eql(u8, name, "exec") or
        std.mem.eql(u8, name, "exit") or
        std.mem.eql(u8, name, "export") or
        std.mem.eql(u8, name, "readonly") or
        std.mem.eql(u8, name, "return") or
        std.mem.eql(u8, name, "set") or
        std.mem.eql(u8, name, "shift") or
        std.mem.eql(u8, name, "times") or
        std.mem.eql(u8, name, "trap") or
        std.mem.eql(u8, name, "unset");
}

fn builtinForName(self: Executor, name: []const u8) ?BuiltinFn {
    if (self.prompt_builder != null) {
        if (std.mem.eql(u8, name, "prompt")) return builtinPrompt;
        if (std.mem.eql(u8, name, "prompt_pwd")) return builtinPromptPwd;
        if (std.mem.eql(u8, name, "prompt_duration")) return builtinPromptDuration;
    }
    if (self.completion_builder != null) {
        if (std.mem.eql(u8, name, "completion")) return builtinCompletion;
    }
    return builtinFor(name);
}

fn builtinFor(name: []const u8) ?BuiltinFn {
    if (std.mem.eql(u8, name, ".")) return builtinSource;
    if (std.mem.eql(u8, name, ":")) return builtinTrue;
    if (std.mem.eql(u8, name, "alias")) return builtinAlias;
    if (std.mem.eql(u8, name, "bg")) return builtinBg;
    if (std.mem.eql(u8, name, "break")) return builtinBreak;
    if (std.mem.eql(u8, name, "true")) return builtinTrue;
    if (std.mem.eql(u8, name, "false")) return builtinFalse;
    if (std.mem.eql(u8, name, "echo")) return builtinEcho;
    if (std.mem.eql(u8, name, "cat")) return builtinCat;
    if (std.mem.eql(u8, name, "command")) return builtinCommand;
    if (std.mem.eql(u8, name, "complete")) return builtinComplete;
    if (std.mem.eql(u8, name, "continue")) return builtinContinue;
    if (std.mem.eql(u8, name, "cd")) return builtinCd;
    if (std.mem.eql(u8, name, "printf")) return builtinPrintf;
    if (std.mem.eql(u8, name, "pwd")) return builtinPwd;
    if (std.mem.eql(u8, name, "read")) return builtinRead;
    if (std.mem.eql(u8, name, "readonly")) return builtinReadonly;
    if (std.mem.eql(u8, name, "return")) return builtinReturn;
    if (std.mem.eql(u8, name, "shift")) return builtinShift;
    if (std.mem.eql(u8, name, "export")) return builtinExport;
    if (std.mem.eql(u8, name, "getopts")) return builtinGetopts;
    if (std.mem.eql(u8, name, "fg")) return builtinFg;
    if (std.mem.eql(u8, name, "jobs")) return builtinJobs;
    if (std.mem.eql(u8, name, "unset")) return builtinUnset;
    if (std.mem.eql(u8, name, "env")) return builtinEnv;
    if (std.mem.eql(u8, name, "eval")) return builtinEval;
    if (std.mem.eql(u8, name, "exec")) return builtinExec;
    if (std.mem.eql(u8, name, "exit")) return builtinExit;
    if (std.mem.eql(u8, name, "set")) return builtinSet;
    if (std.mem.eql(u8, name, "source")) return builtinSource;
    if (std.mem.eql(u8, name, "test")) return builtinTest;
    if (std.mem.eql(u8, name, "times")) return builtinTimes;
    if (std.mem.eql(u8, name, "trap")) return builtinTrap;
    if (std.mem.eql(u8, name, "umask")) return builtinUmask;
    if (std.mem.eql(u8, name, "unalias")) return builtinUnalias;
    if (std.mem.eql(u8, name, "wait")) return builtinWait;
    if (std.mem.eql(u8, name, "[")) return builtinTest;
    return null;
}

fn builtinSource(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;
    if (command.argv.len < 2) return sourceUsageError(self, command.argv[0].text, 2, "missing file operand");
    if (command.argv.len > 2) return sourceUsageError(self, command.argv[0].text, 2, "arguments are not implemented yet");
    const contents = self.readSourceFile(io, command.argv[1].text) catch |err| switch (err) {
        error.FileNotFound => return sourceUsageError(self, command.argv[0].text, 1, "file not found"),
        else => |e| return e,
    };
    defer self.allocator.free(contents);
    var source_options = options;
    source_options.source_path = command.argv[1].text;
    return self.executeScriptSlice(contents, source_options);
}

fn sourceUsageError(self: *Executor, name: []const u8, status: ExitStatus, message: []const u8) !CommandResult {
    if (std.mem.eql(u8, name, ".")) self.pending_exit = status;
    return errorResult(self.allocator, status, name, message);
}

fn builtinCommand(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    if (command.argv.len == 1) return emptyResult(self.allocator, 0);
    var use_default_path = false;
    var lookup_mode: CommandLookupMode = .none;
    var index: usize = 1;
    while (index < command.argv.len and command.argv[index].text.len > 1 and command.argv[index].text[0] == '-') {
        const option = command.argv[index].text;
        index += 1;
        if (std.mem.eql(u8, option, "--")) break;
        if (std.mem.eql(u8, option, "-p")) {
            use_default_path = true;
        } else if (std.mem.eql(u8, option, "-v")) {
            lookup_mode = .terse;
        } else if (std.mem.eql(u8, option, "-V")) {
            lookup_mode = .verbose;
        } else {
            return errorResult(self.allocator, 2, "command", "unsupported option");
        }
    }
    if (lookup_mode != .none) {
        if (index >= command.argv.len) return errorResult(self.allocator, 2, "command", "missing command name");
        if (index + 1 != command.argv.len) return errorResult(self.allocator, 2, "command", "unsupported arguments");
        return commandLookup(self, options, command.argv[index].text, use_default_path, lookup_mode);
    }
    if (index >= command.argv.len) return emptyResult(self.allocator, 0);
    const nested = simpleCommandFromArgs(command, index);
    var nested_options = options;
    nested_options.suppress_functions = true;
    if (use_default_path) nested_options.default_path_lookup = true;
    return self.executeSimpleCommandWithInput(nested, stdin, nested_options);
}

const CommandLookupMode = enum { none, terse, verbose };

fn commandLookup(self: *Executor, options: ExecuteOptions, name: []const u8, use_default_path: bool, mode: CommandLookupMode) !CommandResult {
    if (builtinForName(self.*, name) != null) {
        return if (mode == .terse)
            stdoutLine(self.allocator, name, 0)
        else
            stdoutLineFmt(self.allocator, "{s} is a shell builtin", .{name}, 0);
    }
    if (self.functions.get(name) != null) {
        return if (mode == .terse)
            stdoutLine(self.allocator, name, 0)
        else
            stdoutLineFmt(self.allocator, "{s} is a function", .{name}, 0);
    }
    if (options.io) |io| {
        const found = if (use_default_path) try self.findExecutableInDefaultPath(io, name) else try self.findExecutableInPath(io, name);
        if (found) |path| {
            defer self.allocator.free(path);
            return if (mode == .terse)
                stdoutLine(self.allocator, path, 0)
            else
                stdoutLineFmt(self.allocator, "{s} is {s}", .{ name, path }, 0);
        }
    }
    return emptyResult(self.allocator, 1);
}

fn builtinComplete(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len < 2) return errorResult(self.allocator, 2, "complete", "missing command name");
    var pattern = try parseCompletionPattern(self.allocator, command.argv[1].text);
    defer pattern.deinit(self.allocator);
    var index: usize = 2;
    var function_name: ?[]const u8 = null;
    var rule: completion.Rule = .{ .root = pattern.root, .path = pattern.path, .kind = .subcommand };
    var rule_set = false;
    while (index < command.argv.len) {
        const option = command.argv[index].text;
        index += 1;
        if (std.mem.eql(u8, option, "--function")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "complete", "missing function name");
            function_name = command.argv[index].text;
            if (rule_set) rule.value = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, option, "--subcommands")) {
            rule = .{ .root = pattern.root, .path = pattern.path, .kind = .dynamic_subcommands, .value = function_name };
            rule_set = true;
        } else if (std.mem.eql(u8, option, "--options")) {
            rule = .{ .root = pattern.root, .path = pattern.path, .kind = .dynamic_options, .value = function_name };
            rule_set = true;
        } else if (std.mem.eql(u8, option, "--argument")) {
            rule = .{ .root = pattern.root, .path = pattern.path, .kind = .dynamic_argument, .value = function_name };
            rule_set = true;
        } else if (std.mem.eql(u8, option, "--option-value")) {
            rule = .{ .root = pattern.root, .path = pattern.path, .kind = .dynamic_option_value, .value = function_name };
            rule_set = true;
        } else if (std.mem.eql(u8, option, "--subcommand")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "complete", "missing subcommand name");
            rule = .{ .root = pattern.root, .path = pattern.path, .kind = .subcommand, .value = command.argv[index].text };
            rule_set = true;
            index += 1;
        } else if (std.mem.eql(u8, option, "--option")) {
            rule = .{ .root = pattern.root, .path = pattern.path, .kind = .option };
            rule_set = true;
        } else if (std.mem.eql(u8, option, "--long")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "complete", "missing long option name");
            rule.option.long = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, option, "--short")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "complete", "missing short option name");
            rule.option.short = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, option, "--value-name")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "complete", "missing value name");
            rule.option.argument = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, option, "--description")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "complete", "missing description text");
            rule.description = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, option, "--no-space")) {
            rule.option.no_space = true;
        } else {
            return errorResult(self.allocator, 2, "complete", "unsupported option");
        }
    }
    if (rule_set) {
        if (rule.kind == .option and rule.option.long == null and rule.option.short == null) return errorResult(self.allocator, 2, "complete", "missing option spelling");
        if (rule.kind == .dynamic_option_value and rule.option.long == null and rule.option.short == null) return errorResult(self.allocator, 2, "complete", "missing option spelling");
        if (rule.kind == .dynamic_subcommands or rule.kind == .dynamic_options or rule.kind == .dynamic_argument or rule.kind == .dynamic_option_value) {
            if (rule.value == null) return errorResult(self.allocator, 2, "complete", "missing function name");
        }
        try self.registerCompletionRule(rule);
    } else {
        if (function_name != null) return errorResult(self.allocator, 2, "complete", "--function requires --subcommands, --options, --argument, or --option-value");
        return errorResult(self.allocator, 2, "complete", "missing completion rule");
    }
    return emptyResult(self.allocator, 0);
}

const CompletionPattern = struct {
    root: []const u8,
    path: []const []const u8,

    fn deinit(self: *CompletionPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        for (self.path) |segment| allocator.free(segment);
        allocator.free(self.path);
        self.* = undefined;
    }
};

fn parseCompletionPattern(allocator: std.mem.Allocator, pattern: []const u8) !CompletionPattern {
    var parsed = try parser.parse(allocator, pattern, .{});
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return error.InvalidCompletionPattern;

    var words: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }
    for (parsed.tokens) |token| {
        if (token.kind == .word) try words.append(allocator, try allocator.dupe(u8, token.lexeme(pattern)));
    }
    if (words.items.len == 0) return error.InvalidCompletionPattern;
    const root = words.items[0];
    const path = try allocator.alloc([]const u8, words.items.len - 1);
    @memcpy(path, words.items[1..]);
    words.deinit(allocator);
    return .{ .root = root, .path = path };
}

fn builtinCompletion(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const builder = if (self.completion_builder) |*builder| builder else return errorResult(self.allocator, 2, "completion", "not completing a command");
    if (command.argv.len < 2) return errorResult(self.allocator, 2, "completion", "missing subcommand");
    const subcommand = command.argv[1].text;
    if (std.mem.eql(u8, subcommand, "prefix")) return completionContextLine(self, subcommand, completionContextValue(self.*, .prefix));
    if (std.mem.eql(u8, subcommand, "command")) return completionContextLine(self, subcommand, completionContextValue(self.*, .command));
    if (std.mem.eql(u8, subcommand, "command-path")) return completionContextLine(self, subcommand, completionContextValue(self.*, .command_path));
    if (std.mem.eql(u8, subcommand, "argument-index")) {
        const context = self.completion_context orelse return errorResult(self.allocator, 2, "completion", "missing completion context");
        const text = try std.fmt.allocPrint(self.allocator, "{d}\n", .{context.argument_index});
        return .{ .allocator = self.allocator, .status = 0, .stdout = text, .stderr = try self.allocator.alloc(u8, 0) };
    }
    if (std.mem.eql(u8, subcommand, "previous")) return completionContextLine(self, subcommand, completionContextValue(self.*, .previous));
    if (std.mem.eql(u8, subcommand, "position")) {
        const context = self.completion_context orelse return errorResult(self.allocator, 2, "completion", "missing completion context");
        return stdoutLine(self.allocator, if (context.option_value != null) "option_value" else @tagName(context.position), 0);
    }
    if (std.mem.eql(u8, subcommand, "option-name")) return completionOptionContextLine(self, subcommand, .name);
    if (std.mem.eql(u8, subcommand, "option-spelling")) return completionOptionContextLine(self, subcommand, .spelling);
    if (std.mem.eql(u8, subcommand, "files")) return builtinCompletionFiles(self, builder, command, options, false);
    if (std.mem.eql(u8, subcommand, "directories")) return builtinCompletionFiles(self, builder, command, options, true);
    if (std.mem.eql(u8, subcommand, "executables")) return builtinCompletionExecutables(self, builder, command, options);
    if (std.mem.eql(u8, subcommand, "variables")) return builtinCompletionVariables(self, builder, command);
    if (std.mem.eql(u8, subcommand, "option")) return builtinCompletionOption(self, builder, command);
    if (!std.mem.eql(u8, subcommand, "candidate")) return errorResult(self.allocator, 2, "completion", "unsupported subcommand");

    var candidate: completion.Candidate = .{ .value = "", .replace_start = 0, .replace_end = 0 };
    var value_set = false;
    var index: usize = 2;
    while (index < command.argv.len) {
        const arg = command.argv[index].text;
        index += 1;
        if (std.mem.eql(u8, arg, "--display")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing display text");
            candidate.display = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--description")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing description text");
            candidate.description = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--kind")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing kind");
            candidate.kind = parseCompletionKind(command.argv[index].text) orelse return errorResult(self.allocator, 2, "completion", "unsupported kind");
            index += 1;
        } else if (std.mem.eql(u8, arg, "--no-space")) {
            candidate.append_space = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return errorResult(self.allocator, 2, "completion", "unsupported candidate option");
        } else if (!value_set) {
            candidate.value = arg;
            value_set = true;
        } else {
            return errorResult(self.allocator, 2, "completion", "too many arguments");
        }
    }
    if (!value_set) return errorResult(self.allocator, 2, "completion", "missing candidate value");
    try builder.appendCandidate(self.allocator, candidate);
    return emptyResult(self.allocator, 0);
}

fn builtinCompletionOption(self: *Executor, builder: *CompletionBuilder, command: ir.SimpleCommand) !CommandResult {
    var option: completion.Option = .{};
    var description: ?[]const u8 = null;
    var index: usize = 2;
    while (index < command.argv.len) {
        const arg = command.argv[index].text;
        index += 1;
        if (std.mem.eql(u8, arg, "--long")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing long option name");
            option.long = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--short")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing short option name");
            option.short = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--argument")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing argument name");
            option.argument = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--description")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing description text");
            description = command.argv[index].text;
            index += 1;
        } else {
            return errorResult(self.allocator, 2, "completion", "unsupported option declaration flag");
        }
    }

    if (option.long == null and option.short == null) return errorResult(self.allocator, 2, "completion", "missing option spelling");
    if (updateCompletionOptionValueContext(self, option)) return emptyResult(self.allocator, 0);
    if (option.long) |long| {
        const value = try std.mem.concat(self.allocator, u8, &.{ "--", long });
        defer self.allocator.free(value);
        try builder.appendCandidate(self.allocator, .{ .value = value, .description = description, .kind = .option, .option = option, .replace_start = 0, .replace_end = 0 });
    }
    if (option.short) |short| {
        const value = try std.mem.concat(self.allocator, u8, &.{ "-", short });
        defer self.allocator.free(value);
        try builder.appendCandidate(self.allocator, .{ .value = value, .description = description, .kind = .option, .option = option, .replace_start = 0, .replace_end = 0 });
    }
    return emptyResult(self.allocator, 0);
}

const CompletionContextField = enum { prefix, command, command_path, previous };

fn completionContextValue(self: Executor, field: CompletionContextField) ?[]const u8 {
    const context = self.completion_context orelse return null;
    return switch (field) {
        .prefix => context.prefix,
        .command => context.command,
        .command_path => if (context.command_path.len != 0) context.command_path else context.command,
        .previous => context.previous,
    };
}

fn completionContextLine(self: *Executor, name: []const u8, value: ?[]const u8) !CommandResult {
    _ = name;
    return stdoutLine(self.allocator, value orelse return errorResult(self.allocator, 2, "completion", "missing completion context"), 0);
}

fn completionOptionContextLine(self: *Executor, name: []const u8, field: enum { name, spelling }) !CommandResult {
    _ = name;
    const context = self.completion_context orelse return errorResult(self.allocator, 2, "completion", "missing completion context");
    const option_value = context.option_value orelse return errorResult(self.allocator, 2, "completion", "missing active option");
    return stdoutLine(self.allocator, switch (field) {
        .name => option_value.name,
        .spelling => option_value.spelling,
    }, 0);
}

fn updateCompletionOptionValueContext(self: *Executor, option: completion.Option) bool {
    if (option.argument == null) return false;
    var context = self.completion_context orelse return false;
    if (context.option_value != null) return true;

    if (option.long) |long| {
        var attached_prefix_buffer: [256]u8 = undefined;
        const attached_prefix = std.fmt.bufPrint(&attached_prefix_buffer, "--{s}=", .{long}) catch return false;
        if (std.mem.startsWith(u8, context.prefix, attached_prefix)) {
            const value_start = context.replace_start + attached_prefix.len;
            const spelling = context.prefix[0 .. attached_prefix.len - 1];
            context.option_value = .{ .name = spelling[2..], .spelling = spelling };
            context.prefix = context.prefix[attached_prefix.len..];
            context.replace_start = value_start;
            self.completion_context = context;
            return true;
        }

        var spelling_buffer: [256]u8 = undefined;
        const spelling = std.fmt.bufPrint(&spelling_buffer, "--{s}", .{long}) catch return false;
        if (std.mem.eql(u8, context.previous, spelling)) {
            context.option_value = .{ .name = context.previous[2..], .spelling = context.previous };
            self.completion_context = context;
            return true;
        }
    }
    if (option.short) |short| {
        var spelling_buffer: [16]u8 = undefined;
        const spelling = std.fmt.bufPrint(&spelling_buffer, "-{s}", .{short}) catch return false;
        if (std.mem.eql(u8, context.previous, spelling)) {
            context.option_value = .{ .name = context.previous[1..], .spelling = context.previous };
            self.completion_context = context;
            return true;
        }
    }
    return false;
}

fn completionPrefixOption(self: *Executor, command: ir.SimpleCommand, start: usize) ![]const u8 {
    var prefix: ?[]const u8 = null;
    var index = start;
    while (index < command.argv.len) {
        const option = command.argv[index].text;
        index += 1;
        if (std.mem.eql(u8, option, "--prefix")) {
            if (index >= command.argv.len) return error.MissingCompletionPrefix;
            prefix = command.argv[index].text;
            index += 1;
        } else {
            return error.UnsupportedCompletionOption;
        }
    }
    if (prefix) |value| return value;
    const context = self.completion_context orelse return "";
    return context.prefix;
}

fn builtinCompletionFiles(self: *Executor, builder: *CompletionBuilder, command: ir.SimpleCommand, options: ExecuteOptions, directories_only: bool) !CommandResult {
    const io = options.io orelse return error.MissingIoForBuiltin;
    var append_slash = false;
    var extension: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    var index: usize = 2;
    while (index < command.argv.len) {
        const option = command.argv[index].text;
        index += 1;
        if (std.mem.eql(u8, option, "--prefix")) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing prefix");
            prefix = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, option, "--extension") and !directories_only) {
            if (index >= command.argv.len) return errorResult(self.allocator, 2, "completion", "missing extension");
            extension = command.argv[index].text;
            index += 1;
        } else if (std.mem.eql(u8, option, "--append-slash") and directories_only) {
            append_slash = true;
        } else {
            return errorResult(self.allocator, 2, "completion", "unsupported helper option");
        }
    }
    const effective_prefix = prefix orelse if (self.completion_context) |context| context.prefix else "";
    const replace_start: usize = if (prefix == null) if (self.completion_context) |context| context.replace_start else 0 else 0;
    const replace_end: usize = if (prefix == null) if (self.completion_context) |context| context.replace_end else effective_prefix.len else effective_prefix.len;
    try appendPathCandidates(self, builder, io, effective_prefix, replace_start, replace_end, extension, directories_only, append_slash);
    return emptyResult(self.allocator, 0);
}

fn appendPathCandidates(self: *Executor, builder: *CompletionBuilder, io: std.Io, prefix: []const u8, replace_start: usize, replace_end: usize, extension: ?[]const u8, directories_only: bool, append_slash: bool) !void {
    if (std.mem.indexOfScalar(u8, prefix, '/') != null) return;
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
        if (completion.fuzzyMatchRank(entry.name, prefix) == null) continue;
        const is_directory = entry.kind == .directory;
        if (directories_only and !is_directory) continue;
        if (extension) |ext| {
            if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        }
        const value = if (append_slash and is_directory) try std.mem.concat(self.allocator, u8, &.{ entry.name, "/" }) else entry.name;
        defer if (append_slash and is_directory) self.allocator.free(value);
        try builder.appendCandidate(self.allocator, .{
            .value = value,
            .kind = if (is_directory) .directory else .file,
            .replace_start = replace_start,
            .replace_end = replace_end,
            .append_space = !is_directory,
        });
    }
}

fn builtinCompletionVariables(self: *Executor, builder: *CompletionBuilder, command: ir.SimpleCommand) !CommandResult {
    const prefix = completionPrefixOption(self, command, 2) catch |err| switch (err) {
        error.MissingCompletionPrefix => return errorResult(self.allocator, 2, "completion", "missing prefix"),
        error.UnsupportedCompletionOption => return errorResult(self.allocator, 2, "completion", "unsupported helper option"),
        else => |e| return e,
    };
    var iter = self.env.iterator();
    while (iter.next()) |entry| {
        if (completion.fuzzyMatchRank(entry.key_ptr.*, prefix) != null) {
            try builder.appendCandidate(self.allocator, .{ .value = entry.key_ptr.*, .kind = .variable, .replace_start = completionHelperReplaceStart(self.*, prefix), .replace_end = completionHelperReplaceEnd(self.*, prefix) });
        }
    }
    return emptyResult(self.allocator, 0);
}

fn builtinCompletionExecutables(self: *Executor, builder: *CompletionBuilder, command: ir.SimpleCommand, options: ExecuteOptions) !CommandResult {
    const io = options.io orelse return error.MissingIoForBuiltin;
    const prefix = completionPrefixOption(self, command, 2) catch |err| switch (err) {
        error.MissingCompletionPrefix => return errorResult(self.allocator, 2, "completion", "missing prefix"),
        error.UnsupportedCompletionOption => return errorResult(self.allocator, 2, "completion", "unsupported helper option"),
        else => |e| return e,
    };
    const path = self.getEnv("PATH") orelse return emptyResult(self.allocator, 0);
    var path_iter = std.mem.splitScalar(u8, path, ':');
    while (path_iter.next()) |path_dir| {
        if (path_dir.len == 0) continue;
        var dir = std.Io.Dir.cwd().openDir(io, path_dir, .{ .iterate = true }) catch continue;
        errdefer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (completion.fuzzyMatchRank(entry.name, prefix) != null) {
                try builder.appendCandidate(self.allocator, .{ .value = entry.name, .kind = .command, .replace_start = completionHelperReplaceStart(self.*, prefix), .replace_end = completionHelperReplaceEnd(self.*, prefix) });
            }
        }
        dir.close(io);
    }
    return emptyResult(self.allocator, 0);
}

fn completionHelperReplaceStart(self: Executor, prefix: []const u8) usize {
    const context = self.completion_context orelse return 0;
    if (!std.mem.eql(u8, context.prefix, prefix)) return 0;
    return context.replace_start;
}

fn completionHelperReplaceEnd(self: Executor, prefix: []const u8) usize {
    const context = self.completion_context orelse return prefix.len;
    if (!std.mem.eql(u8, context.prefix, prefix)) return prefix.len;
    return context.replace_end;
}

fn parseCompletionKind(name: []const u8) ?completion.Kind {
    inline for (@typeInfo(completion.Kind).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn completionEvalContextForInput(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !CompletionEvalContext {
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .cursor = cursor });
    defer parsed.deinit();
    const context = parser.completionContext(parsed, cursor);
    const prefix = completionContextPrefix(source, context);
    const current_token_index = context.token_index;

    var command: []const u8 = "";
    var previous: []const u8 = "";
    var argument_index: usize = 0;
    var words_seen: usize = 0;
    for (parsed.tokens, 0..) |token, index| {
        if (token.span.start > context.cursor) break;
        if (token.kind != .word) continue;
        const is_current_token = index == current_token_index and context.cursor <= token.span.end;
        const word = token.lexeme(source);
        if (words_seen == 0) {
            command = word;
        } else {
            argument_index = words_seen;
        }
        if (!is_current_token and token.span.end <= context.cursor) previous = word;
        words_seen += 1;
    }

    return .{
        .prefix = prefix,
        .command = command,
        .argument_index = argument_index,
        .previous = previous,
        .position = context.kind,
        .replace_start = context.span.start,
        .replace_end = @min(context.cursor, context.span.end),
    };
}

fn completionContextPrefix(source: []const u8, context: parser.CompletionContext) []const u8 {
    const start = context.span.start;
    const end = @min(context.cursor, context.span.end);
    if (start >= end or end > source.len) return "";
    return source[start..end];
}

fn builtinEval(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(self.allocator);
    for (command.argv[1..], 0..) |arg, index| {
        if (index > 0) try script.append(self.allocator, ' ');
        try script.appendSlice(self.allocator, arg.text);
    }
    return self.executeScriptSlice(script.items, options);
}

fn builtinExec(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    if (command.argv.len == 1) return emptyResult(self.allocator, 0);
    const nested = simpleCommandFromArgs(command, 1);
    if (options.allow_external and options.external_stdio == .inherit and options.io != null and builtinForName(self.*, nested.argv[0].text) == null and self.functions.get(nested.argv[0].text) == null) {
        return self.replaceWithExternal(nested, options.io.?, options);
    }
    var result = try self.executeSimpleCommandWithInput(nested, stdin, options);
    errdefer result.deinit();
    self.pending_exit = result.status;
    return result;
}

fn builtinExit(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len > 2) return exitUsageError(self, "too many arguments");
    const status: ExitStatus = if (command.argv.len == 2) blk: {
        const parsed = std.fmt.parseInt(u64, command.argv[1].text, 10) catch return exitUsageError(self, "numeric argument required");
        break :blk @truncate(parsed);
    } else self.lastStatus();
    self.pending_exit = status;
    return emptyResult(self.allocator, status);
}

fn exitUsageError(self: *Executor, message: []const u8) !CommandResult {
    self.pending_exit = 2;
    return errorResult(self.allocator, 2, "exit", message);
}

fn builtinBreak(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    return setLoopControlBuiltin(self, command, .break_loop, "break");
}

fn builtinContinue(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    return setLoopControlBuiltin(self, command, .continue_loop, "continue");
}

fn setLoopControlBuiltin(self: *Executor, command: ir.SimpleCommand, kind: LoopControlKind, name: []const u8) !CommandResult {
    if (self.loop_depth == 0) return loopControlUsageError(self, name, "not in a loop");
    if (command.argv.len > 2) return loopControlUsageError(self, name, "too many arguments");
    const levels: usize = if (command.argv.len == 2) blk: {
        const parsed = std.fmt.parseInt(usize, command.argv[1].text, 10) catch return loopControlUsageError(self, name, "numeric argument required");
        if (parsed == 0) return loopControlUsageError(self, name, "loop count must be positive");
        break :blk parsed;
    } else 1;
    self.pending_loop_control = .{ .kind = kind, .levels = levels };
    return emptyResult(self.allocator, 0);
}

fn loopControlUsageError(self: *Executor, name: []const u8, message: []const u8) !CommandResult {
    self.pending_exit = 2;
    return errorResult(self.allocator, 2, name, message);
}

fn builtinTrue(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    _ = options;
    return emptyResult(self.allocator, 0);
}

fn builtinFalse(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    _ = options;
    return emptyResult(self.allocator, 1);
}

fn builtinEcho(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);

    for (command.argv[1..], 0..) |arg, index| {
        if (index > 0) try stdout.append(self.allocator, ' ');
        try stdout.appendSlice(self.allocator, arg.text);
    }
    try stdout.append(self.allocator, '\n');

    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = try stdout.toOwnedSlice(self.allocator),
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn builtinPrompt(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    const builder = if (self.prompt_builder) |*builder| builder else return errorResult(self.allocator, 2, "prompt", "not rendering a prompt");
    if (command.argv.len < 2) return errorResult(self.allocator, 2, "prompt", "missing subcommand");

    const subcommand = command.argv[1].text;
    if (std.mem.eql(u8, subcommand, "text")) {
        try appendPromptArgs(self, builder, command.argv[2..]);
        return emptyResult(self.allocator, 0);
    }
    if (std.mem.eql(u8, subcommand, "segment")) {
        var index: usize = 2;
        var style: PromptStyle = .{};
        while (index < command.argv.len and std.mem.startsWith(u8, command.argv[index].text, "--")) {
            const option = command.argv[index].text;
            index += 1;
            if (std.mem.eql(u8, option, "--fg")) {
                if (index >= command.argv.len) return errorResult(self.allocator, 2, "prompt", "missing option value");
                style.fg = parsePromptColor(command.argv[index].text) orelse return errorResult(self.allocator, 2, "prompt", "unsupported foreground color");
                index += 1;
            } else if (std.mem.eql(u8, option, "--bg")) {
                if (index >= command.argv.len) return errorResult(self.allocator, 2, "prompt", "missing option value");
                style.bg = parsePromptColor(command.argv[index].text) orelse return errorResult(self.allocator, 2, "prompt", "unsupported background color");
                index += 1;
            } else if (std.mem.eql(u8, option, "--max-width") or std.mem.eql(u8, option, "--min-width") or std.mem.eql(u8, option, "--truncate")) {
                if (index >= command.argv.len) return errorResult(self.allocator, 2, "prompt", "missing option value");
                index += 1;
            } else if (std.mem.eql(u8, option, "--bold")) {
                style.bold = true;
            } else if (std.mem.eql(u8, option, "--dim")) {
                style.dim = true;
            } else if (std.mem.eql(u8, option, "--italic")) {
                style.italic = true;
            } else if (std.mem.eql(u8, option, "--underline")) {
                style.underline = true;
            } else if (std.mem.eql(u8, option, "--blink")) {
                style.blink = true;
            } else if (std.mem.eql(u8, option, "--reverse")) {
                style.reverse = true;
            } else if (std.mem.eql(u8, option, "--strikethrough")) {
                style.strikethrough = true;
            } else {
                return errorResult(self.allocator, 2, "prompt", "unsupported segment option");
            }
        }
        try builder.appendSegment(self.allocator, style, command.argv[index..]);
        return emptyResult(self.allocator, 0);
    }
    if (std.mem.eql(u8, subcommand, "newline")) {
        try builder.text.append(self.allocator, '\n');
        builder.used = true;
        return emptyResult(self.allocator, 0);
    }
    return errorResult(self.allocator, 2, "prompt", "unsupported subcommand");
}

fn appendPromptArgs(self: *Executor, builder: *PromptBuilder, args: []const ir.WordRef) !void {
    try builder.appendText(self.allocator, args);
}

fn parsePromptColor(name: []const u8) ?vaxis.Color {
    if (std.mem.eql(u8, name, "default")) return .default;
    if (std.mem.eql(u8, name, "black")) return .{ .index = 0 };
    if (std.mem.eql(u8, name, "red")) return .{ .index = 1 };
    if (std.mem.eql(u8, name, "green")) return .{ .index = 2 };
    if (std.mem.eql(u8, name, "yellow")) return .{ .index = 3 };
    if (std.mem.eql(u8, name, "blue")) return .{ .index = 4 };
    if (std.mem.eql(u8, name, "magenta")) return .{ .index = 5 };
    if (std.mem.eql(u8, name, "cyan")) return .{ .index = 6 };
    if (std.mem.eql(u8, name, "white")) return .{ .index = 7 };
    if (std.mem.eql(u8, name, "bright-black")) return .{ .index = 8 };
    if (std.mem.eql(u8, name, "bright-red")) return .{ .index = 9 };
    if (std.mem.eql(u8, name, "bright-green")) return .{ .index = 10 };
    if (std.mem.eql(u8, name, "bright-yellow")) return .{ .index = 11 };
    if (std.mem.eql(u8, name, "bright-blue")) return .{ .index = 12 };
    if (std.mem.eql(u8, name, "bright-magenta")) return .{ .index = 13 };
    if (std.mem.eql(u8, name, "bright-cyan")) return .{ .index = 14 };
    if (std.mem.eql(u8, name, "bright-white")) return .{ .index = 15 };
    if (std.mem.startsWith(u8, name, "index:")) {
        const index = std.fmt.parseUnsigned(u8, name["index:".len..], 10) catch return null;
        return .{ .index = index };
    }
    if (name.len == 7 and name[0] == '#') {
        const value = std.fmt.parseUnsigned(u24, name[1..], 16) catch return null;
        return vaxis.Color.rgbFromUint(value);
    }
    return null;
}

fn builtinPromptPwd(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;
    const cwd = try self.logicalCwd(io);
    defer self.allocator.free(cwd);
    const display = try homeRelativePath(self.allocator, cwd, self.getEnv("HOME"));
    defer if (display.owned) self.allocator.free(display.text);
    return stdoutLine(self.allocator, display.text, 0);
}

fn builtinPromptDuration(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    _ = options;
    return stdoutLine(self.allocator, self.last_command_duration_text[0..self.last_command_duration_text_len], 0);
}

const PromptPath = struct {
    text: []const u8,
    owned: bool = false,
};

fn homeRelativePath(allocator: std.mem.Allocator, path: []const u8, maybe_home: ?[]const u8) !PromptPath {
    const home = maybe_home orelse return .{ .text = path };
    if (home.len == 0) return .{ .text = path };
    if (std.mem.eql(u8, path, home)) return .{ .text = "~" };
    if (std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/') {
        return .{ .text = try std.mem.concat(allocator, u8, &.{ "~", path[home.len..] }), .owned = true };
    }
    return .{ .text = path };
}

fn normalizeLogicalPath(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]const u8 {
    const combined = if (target.len > 0 and target[0] == '/')
        try allocator.dupe(u8, target)
    else
        try std.mem.concat(allocator, u8, &.{ base, "/", target });
    defer allocator.free(combined);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var iter = std.mem.splitScalar(u8, combined, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }

    if (parts.items.len == 0) return allocator.dupe(u8, "/");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts.items) |part| {
        try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn builtinPrintf(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    var format_index: usize = 1;
    if (format_index < command.argv.len and std.mem.eql(u8, command.argv[format_index].text, "--")) format_index += 1;
    if (format_index >= command.argv.len) return errorResult(self.allocator, 2, "printf", "missing format operand");

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(self.allocator);
    var status: ExitStatus = 0;
    try appendPrintfOutput(self.allocator, &stdout, &stderr, &status, command.argv[format_index].text, command.argv[format_index + 1 ..]);
    return .{
        .allocator = self.allocator,
        .status = status,
        .stdout = try stdout.toOwnedSlice(self.allocator),
        .stderr = try stderr.toOwnedSlice(self.allocator),
    };
}

fn builtinRead(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = options;
    var arg_start: usize = 1;
    var raw_mode = false;
    while (arg_start < command.argv.len and std.mem.startsWith(u8, command.argv[arg_start].text, "-") and command.argv[arg_start].text.len > 1) {
        const option = command.argv[arg_start].text;
        if (std.mem.eql(u8, option, "--")) {
            arg_start += 1;
            break;
        }
        if (!std.mem.eql(u8, option, "-r")) return errorResult(self.allocator, 2, "read", "unsupported option");
        raw_mode = true;
        arg_start += 1;
    }

    const names = command.argv[arg_start..];
    const read_input = nextReadInput(self, stdin);
    const status = read_input.status;
    const raw_line = read_input.line;
    const line = if (raw_mode) try self.allocator.dupe(u8, raw_line) else try unescapeReadLine(self.allocator, raw_line);
    defer self.allocator.free(line);
    if (names.len == 0) {
        try self.setEnv("REPLY", line);
        return emptyResult(self.allocator, status);
    }

    const ifs = self.getEnv("IFS") orelse " \t\n";
    var cursor = skipReadIfsWhitespace(line, 0, ifs);
    for (names, 0..) |name_word, index| {
        if (!isShellName(name_word.text)) return errorResult(self.allocator, 2, "read", "invalid variable name");
        if (index == names.len - 1) {
            const value_end = trimTrailingReadIfsWhitespace(line, line.len, ifs);
            const value = if (cursor <= value_end) line[cursor..value_end] else "";
            try self.setEnv(name_word.text, value);
            break;
        }
        const field = nextReadField(line, &cursor, ifs);
        try self.setEnv(name_word.text, field);
    }
    return emptyResult(self.allocator, status);
}

const ReadInput = struct {
    line: []const u8,
    status: ExitStatus,
};

fn nextReadInput(self: *Executor, stdin: []const u8) ReadInput {
    if (stdin.len != 0) return readInputFromSlice(stdin);
    const script_stdin = self.script_stdin orelse return .{ .line = "", .status = 1 };
    if (self.script_stdin_offset >= script_stdin.len) return .{ .line = "", .status = 1 };
    const remaining = script_stdin[self.script_stdin_offset..];
    const line_end = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
    const status: ExitStatus = if (line_end < remaining.len) 0 else 1;
    self.script_stdin_offset += @min(line_end + 1, remaining.len);
    return .{ .line = trimReadCarriageReturn(remaining[0..line_end]), .status = status };
}

fn readInputFromSlice(stdin: []const u8) ReadInput {
    const line_end = std.mem.indexOfScalar(u8, stdin, '\n') orelse stdin.len;
    const status: ExitStatus = if (line_end < stdin.len) 0 else 1;
    return .{ .line = trimReadCarriageReturn(stdin[0..line_end]), .status = status };
}

fn trimReadCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn builtinCat(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    const input = catInput(self, stdin);
    if (command.argv.len == 1) {
        return .{
            .allocator = self.allocator,
            .status = 0,
            .stdout = try self.allocator.dupe(u8, input),
            .stderr = try self.allocator.alloc(u8, 0),
        };
    }

    const io = options.io orelse return error.MissingIoForBuiltin;
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    for (command.argv[1..]) |arg| {
        if (std.mem.eql(u8, arg.text, "-")) {
            try stdout.appendSlice(self.allocator, input);
            continue;
        }
        const contents = std.Io.Dir.cwd().readFileAlloc(io, arg.text, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return errorResult(self.allocator, 1, arg.text, "not found"),
            error.AccessDenied, error.PermissionDenied => return errorResult(self.allocator, 1, arg.text, "permission denied"),
            error.IsDir => return errorResult(self.allocator, 1, arg.text, "is a directory"),
            else => return err,
        };
        defer self.allocator.free(contents);
        try stdout.appendSlice(self.allocator, contents);
    }
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = try stdout.toOwnedSlice(self.allocator),
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn catInput(self: *Executor, stdin: []const u8) []const u8 {
    if (stdin.len != 0) return stdin;
    const script_stdin = self.script_stdin orelse return stdin;
    if (self.script_stdin_offset >= script_stdin.len) return stdin;
    const remaining = script_stdin[self.script_stdin_offset..];
    self.script_stdin_offset = script_stdin.len;
    return remaining;
}

const PrintfSpec = struct {
    spec: u8,
    left_adjust: bool = false,
    zero_pad: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
};

fn appendPrintfOutput(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), status: *ExitStatus, format: []const u8, args: []const ir.WordRef) !void {
    var arg_index: usize = 0;
    var first_pass = true;
    while (first_pass or arg_index < args.len) {
        first_pass = false;
        const before = arg_index;
        var index: usize = 0;
        while (index < format.len) {
            switch (format[index]) {
                '\\' => {
                    index += 1;
                    if (index >= format.len) {
                        try stdout.append(allocator, '\\');
                    } else {
                        _ = try appendEscapedSequence(allocator, stdout, format, &index, .format);
                    }
                },
                '%' => {
                    index += 1;
                    if (index >= format.len) {
                        try printfDiagnostic(allocator, stderr, status, "invalid format");
                        break;
                    }
                    const spec = parsePrintfSpec(format, &index) orelse {
                        try printfDiagnostic(allocator, stderr, status, "invalid format");
                        continue;
                    };
                    if (spec.spec == '%') {
                        try stdout.append(allocator, '%');
                        continue;
                    }
                    const arg = if (arg_index < args.len) blk: {
                        const value = args[arg_index].text;
                        arg_index += 1;
                        break :blk value;
                    } else "";
                    if (!try appendPrintfConversion(allocator, stdout, stderr, status, spec, arg)) return;
                },
                else => {
                    try stdout.append(allocator, format[index]);
                    index += 1;
                },
            }
        }
        if (arg_index == before) break;
    }
}

fn printfDiagnostic(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *ExitStatus, message: []const u8) !void {
    status.* = 1;
    try stderr.appendSlice(allocator, "printf: ");
    try stderr.appendSlice(allocator, message);
    try stderr.append(allocator, '\n');
}

fn parsePrintfSpec(format: []const u8, index: *usize) ?PrintfSpec {
    var result: PrintfSpec = .{ .spec = 0 };
    while (index.* < format.len) {
        switch (format[index.*]) {
            '-' => result.left_adjust = true,
            '0' => result.zero_pad = true,
            '+', ' ', '#' => {},
            else => break,
        }
        index.* += 1;
    }
    if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        result.width = std.fmt.parseInt(usize, format[start..index.*], 10) catch null;
    }
    if (index.* < format.len and format[index.*] == '.') {
        index.* += 1;
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        result.precision = if (start == index.*) 0 else std.fmt.parseInt(usize, format[start..index.*], 10) catch 0;
    }
    if (index.* >= format.len) return null;
    result.spec = format[index.*];
    index.* += 1;
    return result;
}

fn appendPrintfConversion(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), status: *ExitStatus, spec: PrintfSpec, arg: []const u8) !bool {
    const rendered: []u8 = switch (spec.spec) {
        's' => try formatPrintfString(allocator, arg, spec.precision),
        'b' => blk: {
            var escaped: std.ArrayList(u8) = .empty;
            errdefer escaped.deinit(allocator);
            const keep_going = try appendEscapedString(allocator, &escaped, arg);
            const bytes = try escaped.toOwnedSlice(allocator);
            if (!keep_going) {
                try appendPadded(allocator, stdout, bytes, spec);
                allocator.free(bytes);
                return false;
            }
            break :blk bytes;
        },
        'c' => try allocator.dupe(u8, if (arg.len == 0) &[_]u8{0} else arg[0..1]),
        'd', 'i' => try std.fmt.allocPrint(allocator, "{d}", .{try parsePrintfSigned(allocator, stderr, status, arg)}),
        'u' => try std.fmt.allocPrint(allocator, "{d}", .{try parsePrintfUnsigned(allocator, stderr, status, arg)}),
        'o' => try std.fmt.allocPrint(allocator, "{o}", .{try parsePrintfUnsigned(allocator, stderr, status, arg)}),
        'x' => try std.fmt.allocPrint(allocator, "{x}", .{try parsePrintfUnsigned(allocator, stderr, status, arg)}),
        'X' => try std.fmt.allocPrint(allocator, "{X}", .{try parsePrintfUnsigned(allocator, stderr, status, arg)}),
        else => blk: {
            try printfDiagnostic(allocator, stderr, status, "invalid conversion");
            break :blk try allocator.alloc(u8, 0);
        },
    };
    defer allocator.free(rendered);
    try appendPadded(allocator, stdout, rendered, spec);
    return true;
}

fn formatPrintfString(allocator: std.mem.Allocator, arg: []const u8, precision: ?usize) ![]u8 {
    const limit = if (precision) |value| @min(value, arg.len) else arg.len;
    return allocator.dupe(u8, arg[0..limit]);
}

fn appendPadded(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, spec: PrintfSpec) !void {
    const width = spec.width orelse 0;
    const pad_len = if (width > text.len) width - text.len else 0;
    const pad_byte: u8 = if (spec.zero_pad and !spec.left_adjust) '0' else ' ';
    if (!spec.left_adjust) try stdout.appendNTimes(allocator, pad_byte, pad_len);
    try stdout.appendSlice(allocator, text);
    if (spec.left_adjust) try stdout.appendNTimes(allocator, ' ', pad_len);
}

fn parsePrintfSigned(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *ExitStatus, arg: []const u8) !i64 {
    return std.fmt.parseInt(i64, arg, 0) catch {
        try printfDiagnostic(allocator, stderr, status, "numeric argument required");
        return 0;
    };
}

fn parsePrintfUnsigned(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *ExitStatus, arg: []const u8) !u64 {
    return std.fmt.parseInt(u64, arg, 0) catch blk: {
        const signed = std.fmt.parseInt(i64, arg, 0) catch {
            try printfDiagnostic(allocator, stderr, status, "numeric argument required");
            return 0;
        };
        break :blk @bitCast(signed);
    };
}

fn appendEscapedString(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8) !bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try stdout.append(allocator, text[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= text.len) {
            try stdout.append(allocator, '\\');
        } else if (!try appendEscapedSequence(allocator, stdout, text, &index, .percent_b)) {
            return false;
        }
    }
    return true;
}

const PrintfEscapeMode = enum { format, percent_b };

fn appendEscapedSequence(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, index: *usize, mode: PrintfEscapeMode) !bool {
    const byte = text[index.*];
    switch (byte) {
        'a' => try stdout.append(allocator, 0x07),
        'b' => try stdout.append(allocator, 0x08),
        'c' => {
            index.* += 1;
            return false;
        },
        'f' => try stdout.append(allocator, 0x0c),
        'n' => try stdout.append(allocator, '\n'),
        'r' => try stdout.append(allocator, '\r'),
        't' => try stdout.append(allocator, '\t'),
        'v' => try stdout.append(allocator, 0x0b),
        '\\' => try stdout.append(allocator, '\\'),
        '0'...'7' => {
            try appendOctalEscape(allocator, stdout, text, index, mode);
            return true;
        },
        else => {
            try stdout.append(allocator, '\\');
            try stdout.append(allocator, byte);
        },
    }
    index.* += 1;
    return true;
}

fn appendOctalEscape(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, index: *usize, mode: PrintfEscapeMode) !void {
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = index.*;
    if (mode == .percent_b and cursor < text.len and text[cursor] == '0') cursor += 1;
    while (cursor < text.len and count < 3 and text[cursor] >= '0' and text[cursor] <= '7') : (count += 1) {
        value = value * 8 + (text[cursor] - '0');
        cursor += 1;
    }
    if (count == 0) {
        try stdout.append(allocator, 0);
        index.* += 1;
    } else {
        try stdout.append(allocator, value);
        index.* = cursor;
    }
}

fn isShellName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_')) return false;
    }
    return true;
}

fn unescapeReadLine(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '\\' and index + 1 < raw.len) {
            index += 1;
        }
        try out.append(allocator, raw[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn nextReadField(text: []const u8, cursor: *usize, ifs: []const u8) []const u8 {
    cursor.* = skipReadIfsWhitespace(text, cursor.*, ifs);
    if (cursor.* >= text.len) return "";
    if (isReadIfsNonWhitespace(text[cursor.*], ifs)) {
        cursor.* += 1;
        cursor.* = skipReadIfsWhitespace(text, cursor.*, ifs);
        return "";
    }
    const start = cursor.*;
    while (cursor.* < text.len and !isReadIfs(text[cursor.*], ifs)) : (cursor.* += 1) {}
    const end = cursor.*;
    if (cursor.* < text.len and isReadIfsNonWhitespace(text[cursor.*], ifs)) cursor.* += 1;
    cursor.* = skipReadIfsWhitespace(text, cursor.*, ifs);
    return text[start..end];
}

fn skipReadIfsWhitespace(text: []const u8, start: usize, ifs: []const u8) usize {
    var index = start;
    while (index < text.len and isReadIfsWhitespace(text[index], ifs)) : (index += 1) {}
    return index;
}

fn trimTrailingReadIfsWhitespace(text: []const u8, end: usize, ifs: []const u8) usize {
    var index = end;
    while (index > 0 and isReadIfsWhitespace(text[index - 1], ifs)) : (index -= 1) {}
    return index;
}

fn isReadIfs(byte: u8, ifs: []const u8) bool {
    return std.mem.indexOfScalar(u8, ifs, byte) != null;
}

fn isDefaultReadIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn isReadIfsWhitespace(byte: u8, ifs: []const u8) bool {
    return isDefaultReadIfsWhitespace(byte) and isReadIfs(byte, ifs);
}

fn isReadIfsNonWhitespace(byte: u8, ifs: []const u8) bool {
    return !isDefaultReadIfsWhitespace(byte) and isReadIfs(byte, ifs);
}

fn builtinCd(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;

    var arg_index: usize = 1;
    var physical = false;
    while (arg_index < command.argv.len) {
        const option = command.argv[arg_index].text;
        if (std.mem.eql(u8, option, "--")) {
            arg_index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-L")) {
            physical = false;
            arg_index += 1;
        } else if (std.mem.eql(u8, option, "-P")) {
            physical = true;
            arg_index += 1;
        } else if (std.mem.startsWith(u8, option, "-") and !std.mem.eql(u8, option, "-")) {
            return errorResult(self.allocator, 2, "cd", "unsupported option");
        } else {
            break;
        }
    }
    if (command.argv.len > arg_index + 1) return errorResult(self.allocator, 2, "cd", "too many arguments");

    const operand = if (arg_index < command.argv.len) command.argv[arg_index].text else self.getEnv("HOME") orelse return errorResult(self.allocator, 1, "cd", "HOME not set");
    const oldpwd_target = std.mem.eql(u8, operand, "-");
    const target = if (oldpwd_target) self.getEnv("OLDPWD") orelse return errorResult(self.allocator, 1, "cd", "OLDPWD not set") else operand;
    const old_pwd = try self.logicalCwd(io);
    defer self.allocator.free(old_pwd);

    const cd_target = try resolveCdTarget(self, io, target);
    defer cd_target.deinit(self.allocator);

    std.process.setCurrentPath(io, cd_target.path) catch |err| {
        const message = try std.fmt.allocPrint(self.allocator, "{s}: {t}", .{ cd_target.path, err });
        defer self.allocator.free(message);
        return errorResult(self.allocator, 1, "cd", message);
    };
    const new_pwd = if (physical)
        try self.physicalCwd(io)
    else
        try normalizeLogicalPath(self.allocator, old_pwd, cd_target.path);
    errdefer self.allocator.free(new_pwd);
    try self.setEnv("OLDPWD", old_pwd);
    try self.setEnv("PWD", new_pwd);
    const stdout = if (oldpwd_target or cd_target.print_path) try std.fmt.allocPrint(self.allocator, "{s}\n", .{new_pwd}) else try self.allocator.alloc(u8, 0);
    errdefer self.allocator.free(stdout);
    self.allocator.free(new_pwd);
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = stdout,
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

const CdTarget = struct {
    path: []const u8,
    print_path: bool = false,
    owned: bool = false,

    fn deinit(self: CdTarget, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

fn resolveCdTarget(self: *Executor, io: std.Io, target: []const u8) !CdTarget {
    if (target.len == 0 or target[0] == '/' or std.mem.indexOfScalar(u8, target, '/') != null) return .{ .path = target };
    const cdpath = self.getEnv("CDPATH") orelse return .{ .path = target };
    var iter = std.mem.splitScalar(u8, cdpath, ':');
    while (iter.next()) |entry| {
        const candidate = if (entry.len == 0 or std.mem.eql(u8, entry, "."))
            try self.allocator.dupe(u8, target)
        else
            try std.mem.concat(self.allocator, u8, &.{ entry, "/", target });
        errdefer self.allocator.free(candidate);
        var dir = std.Io.Dir.cwd().openDir(io, candidate, .{}) catch {
            self.allocator.free(candidate);
            continue;
        };
        dir.close(io);
        return .{ .path = candidate, .print_path = entry.len != 0 and !std.mem.eql(u8, entry, "."), .owned = true };
    }
    return .{ .path = target };
}

fn builtinPwd(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;
    var arg_index: usize = 1;
    var physical = false;
    while (arg_index < command.argv.len) {
        const option = command.argv[arg_index].text;
        if (std.mem.eql(u8, option, "--")) {
            arg_index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-L")) {
            physical = false;
            arg_index += 1;
        } else if (std.mem.eql(u8, option, "-P")) {
            physical = true;
            arg_index += 1;
        } else if (std.mem.startsWith(u8, option, "-")) {
            return errorResult(self.allocator, 2, "pwd", "unsupported option");
        } else {
            break;
        }
    }
    if (arg_index < command.argv.len) return errorResult(self.allocator, 2, "pwd", "too many arguments");

    const cwd = if (physical) try self.physicalCwd(io) else blk: {
        const logical = try self.logicalCwd(io);
        defer self.allocator.free(logical);
        break :blk try self.allocator.dupe(u8, logical);
    };
    defer self.allocator.free(cwd);
    const stdout = try std.fmt.allocPrint(self.allocator, "{s}\n", .{cwd});
    errdefer self.allocator.free(stdout);
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = stdout,
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn builtinTrap(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len == 1) return listTraps(self);

    var action_index: usize = 1;
    if (std.mem.eql(u8, command.argv[action_index].text, "--")) {
        action_index += 1;
        if (action_index >= command.argv.len) return listTraps(self);
    }
    const action = command.argv[action_index].text;
    if (action_index + 1 >= command.argv.len) return errorResult(self.allocator, 2, "trap", "missing signal");

    for (command.argv[action_index + 1 ..]) |signal_word| {
        const name = try normalizeTrapName(self.allocator, signal_word.text);
        defer self.allocator.free(name);
        if (std.mem.eql(u8, action, "-")) {
            self.clearTrap(name);
        } else {
            try self.setTrap(name, action);
        }
    }
    return emptyResult(self.allocator, 0);
}

fn listTraps(self: *Executor) !CommandResult {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var iter = self.traps.iterator();
    while (iter.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    for (names.items) |name| {
        const quoted = try singleQuote(self.allocator, self.traps.get(name).?);
        defer self.allocator.free(quoted);
        try stdout.print(self.allocator, "trap -- {s} {s}\n", .{ quoted, name });
    }
    return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
}

fn normalizeTrapName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "0")) return allocator.dupe(u8, "EXIT");
    const start: usize = if (std.ascii.startsWithIgnoreCase(raw, "SIG") and raw.len > 3) 3 else 0;
    if (start >= raw.len) return allocator.dupe(u8, raw);
    const name = try allocator.alloc(u8, raw.len - start);
    for (raw[start..], 0..) |byte, index| name[index] = std.ascii.toUpper(byte);
    return name;
}

fn singleQuote(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (text) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn builtinAlias(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len == 1) return listAliases(self, null);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    for (command.argv[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg.text, '=')) |equals| {
            const name = arg.text[0..equals];
            if (!isShellName(name)) return errorResult(self.allocator, 2, "alias", "invalid alias name");
            try self.setAlias(name, arg.text[equals + 1 ..]);
        } else {
            const value = self.aliases.get(arg.text) orelse return errorResult(self.allocator, 1, "alias", "not found");
            const quoted = try singleQuote(self.allocator, value);
            defer self.allocator.free(quoted);
            try stdout.print(self.allocator, "alias {s}={s}\n", .{ arg.text, quoted });
        }
    }
    return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
}

fn listAliases(self: *Executor, prefix: ?[]const u8) !CommandResult {
    _ = prefix;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var iter = self.aliases.iterator();
    while (iter.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    for (names.items) |name| {
        const quoted = try singleQuote(self.allocator, self.aliases.get(name).?);
        defer self.allocator.free(quoted);
        try stdout.print(self.allocator, "alias {s}={s}\n", .{ name, quoted });
    }
    return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
}

fn builtinUnalias(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len == 1) return errorResult(self.allocator, 2, "unalias", "missing operand");
    var index: usize = 1;
    const option_terminated = std.mem.eql(u8, command.argv[index].text, "--");
    if (option_terminated) index += 1;
    if (index >= command.argv.len) return errorResult(self.allocator, 2, "unalias", "missing operand");
    if (!option_terminated and std.mem.startsWith(u8, command.argv[index].text, "-") and !std.mem.eql(u8, command.argv[index].text, "-a")) return errorResult(self.allocator, 2, "unalias", "unsupported option");
    if (!option_terminated and std.mem.eql(u8, command.argv[index].text, "-a")) {
        var iter = self.aliases.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.clearRetainingCapacity();
        index += 1;
        if (index == command.argv.len) return emptyResult(self.allocator, 0);
    }
    for (command.argv[index..]) |arg| {
        if (!isShellName(arg.text)) return errorResult(self.allocator, 2, "unalias", "invalid alias name");
        if (!self.unsetAlias(arg.text)) return errorResult(self.allocator, 1, "unalias", "not found");
    }
    return emptyResult(self.allocator, 0);
}

fn builtinGetopts(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len < 3) return errorResult(self.allocator, 2, "getopts", "usage: getopts optstring name [arg ...]");
    const optstring = command.argv[1].text;
    const name = command.argv[2].text;
    if (!isValidGetoptsOptstring(optstring)) return errorResult(self.allocator, 2, "getopts", "invalid optstring");
    if (!isShellName(name)) return errorResult(self.allocator, 2, "getopts", "invalid variable name");

    const arg_count = if (command.argv.len > 3) command.argv.len - 3 else self.currentPositionals().params.len;
    const args = try self.allocator.alloc([]const u8, arg_count);
    defer self.allocator.free(args);
    if (command.argv.len > 3) {
        for (command.argv[3..], 0..) |arg, index| args[index] = arg.text;
    } else {
        const positionals = self.currentPositionals().params;
        for (positionals, 0..) |param, index| args[index] = param;
    }

    var optind = getOptind(self.*);
    if (optind != self.getopts_last_optind) self.getopts_offset = 1;
    self.getopts_last_optind = optind;
    const silent = optstring.len > 0 and optstring[0] == ':';

    if (optind == 0) optind = 1;
    if (optind > args.len) return finishGetoptsEnd(self, name, optind);

    const arg = args[optind - 1];
    if (arg.len < 2 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) return finishGetoptsEnd(self, name, optind);
    if (std.mem.eql(u8, arg, "--")) return finishGetoptsEnd(self, name, optind + 1);

    if (self.getopts_offset >= arg.len) self.getopts_offset = 1;
    const option = arg[self.getopts_offset];
    const next_offset = self.getopts_offset + 1;
    const spec = getoptsSpec(optstring, option);
    if (spec == .invalid) {
        if (next_offset < arg.len) {
            self.getopts_offset = next_offset;
        } else {
            optind += 1;
            self.getopts_offset = 1;
        }
        self.getopts_last_optind = optind;
        try setOptind(self, optind);
        if (silent) {
            const optarg = [_]u8{option};
            try self.setEnv("OPTARG", optarg[0..]);
            try self.setEnv(name, "?");
            return emptyResult(self.allocator, 0);
        }
        self.unsetEnv("OPTARG");
        try self.setEnv(name, "?");
        const stderr = try std.fmt.allocPrint(self.allocator, "getopts: illegal option -- {c}\n", .{option});
        errdefer self.allocator.free(stderr);
        return .{ .allocator = self.allocator, .status = 0, .stdout = try self.allocator.alloc(u8, 0), .stderr = stderr };
    }

    const name_value = [_]u8{option};
    try self.setEnv(name, name_value[0..]);
    if (spec == .requires_arg) {
        if (next_offset < arg.len) {
            try self.setEnv("OPTARG", arg[next_offset..]);
            optind += 1;
            self.getopts_offset = 1;
        } else if (optind < args.len) {
            try self.setEnv("OPTARG", args[optind]);
            optind += 2;
            self.getopts_offset = 1;
        } else {
            optind += 1;
            self.getopts_offset = 1;
            self.getopts_last_optind = optind;
            try setOptind(self, optind);
            const optarg = [_]u8{option};
            try self.setEnv("OPTARG", optarg[0..]);
            if (silent) {
                try self.setEnv(name, ":");
                return emptyResult(self.allocator, 0);
            }
            try self.setEnv(name, "?");
            const stderr = try std.fmt.allocPrint(self.allocator, "getopts: option requires an argument -- {c}\n", .{option});
            errdefer self.allocator.free(stderr);
            return .{ .allocator = self.allocator, .status = 0, .stdout = try self.allocator.alloc(u8, 0), .stderr = stderr };
        }
    } else {
        self.unsetEnv("OPTARG");
        if (next_offset < arg.len) {
            self.getopts_offset = next_offset;
        } else {
            optind += 1;
            self.getopts_offset = 1;
        }
    }

    self.getopts_last_optind = optind;
    try setOptind(self, optind);
    return emptyResult(self.allocator, 0);
}

const GetoptsSpec = enum { invalid, no_arg, requires_arg };

fn isValidGetoptsOptstring(optstring: []const u8) bool {
    const start: usize = if (optstring.len > 0 and optstring[0] == ':') 1 else 0;
    var index = start;
    while (index < optstring.len) : (index += 1) {
        switch (optstring[index]) {
            '?' => return false,
            ':' => if (index == start or optstring[index - 1] == ':') return false,
            else => {},
        }
    }
    return true;
}

fn getoptsSpec(optstring: []const u8, option: u8) GetoptsSpec {
    if (option == ':' or option == '?') return .invalid;
    const start: usize = if (optstring.len > 0 and optstring[0] == ':') 1 else 0;
    var index = start;
    while (index < optstring.len) : (index += 1) {
        if (optstring[index] == ':') continue;
        if (optstring[index] != option) continue;
        return if (index + 1 < optstring.len and optstring[index + 1] == ':') .requires_arg else .no_arg;
    }
    return .invalid;
}

fn getOptind(self: Executor) usize {
    const text = self.getEnv("OPTIND") orelse return 1;
    const parsed = std.fmt.parseInt(usize, text, 10) catch return 1;
    return if (parsed == 0) 1 else parsed;
}

fn setOptind(self: *Executor, optind: usize) !void {
    const text = try std.fmt.allocPrint(self.allocator, "{d}", .{optind});
    defer self.allocator.free(text);
    try self.setEnv("OPTIND", text);
}

fn finishGetoptsEnd(self: *Executor, name: []const u8, optind: usize) !CommandResult {
    self.getopts_offset = 1;
    self.getopts_last_optind = optind;
    try setOptind(self, optind);
    try self.setEnv(name, "?");
    self.unsetEnv("OPTARG");
    return emptyResult(self.allocator, 1);
}

fn builtinExport(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    var index: usize = 1;
    const option_terminated = index < command.argv.len and std.mem.eql(u8, command.argv[index].text, "--");
    if (option_terminated) index += 1;
    if (index >= command.argv.len) return listExported(self);
    if (!option_terminated and std.mem.eql(u8, command.argv[index].text, "-p")) {
        if (command.argv.len != index + 1) return variableBuiltinUsageError(self, "export", "too many arguments");
        return listExported(self);
    }
    if (!option_terminated and std.mem.startsWith(u8, command.argv[index].text, "-") and !std.mem.eql(u8, command.argv[index].text, "-")) return variableBuiltinUsageError(self, "export", "unsupported option");

    for (command.argv[index..]) |arg| {
        const assignment = std.mem.indexOfScalar(u8, arg.text, '=');
        const name = if (assignment) |equals| arg.text[0..equals] else arg.text;
        if (!isShellName(name)) return variableBuiltinUsageError(self, "export", "invalid variable name");
        if (assignment) |equals| {
            if (self.isReadonly(name)) return variableBuiltinUsageError(self, "export", "readonly variable");
            try self.setEnv(name, arg.text[equals + 1 ..]);
        }
        try self.setExported(name);
    }
    return emptyResult(self.allocator, 0);
}

fn listExported(self: *Executor) !CommandResult {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var iter = self.exported.iterator();
    while (iter.next()) |entry| if (self.env.contains(entry.key_ptr.*)) try names.append(self.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    for (names.items) |name| {
        try stdout.appendSlice(self.allocator, "export ");
        try stdout.appendSlice(self.allocator, name);
        try stdout.append(self.allocator, '=');
        try appendShellSingleQuoted(self.allocator, &stdout, self.env.get(name).?);
        try stdout.append(self.allocator, '\n');
    }
    return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
}

fn builtinUnset(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    var mode: enum { variable, function } = .variable;
    var index: usize = 1;
    while (index < command.argv.len) {
        const option = command.argv[index].text;
        if (std.mem.eql(u8, option, "--")) {
            index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-v")) {
            mode = .variable;
            index += 1;
        } else if (std.mem.eql(u8, option, "-f")) {
            mode = .function;
            index += 1;
        } else if (std.mem.startsWith(u8, option, "-") and !std.mem.eql(u8, option, "-")) {
            return variableBuiltinUsageError(self, "unset", "unsupported option");
        } else {
            break;
        }
    }
    for (command.argv[index..]) |arg| {
        if (!isShellName(arg.text)) return variableBuiltinUsageError(self, "unset", "invalid variable name");
        switch (mode) {
            .variable => {
                if (self.isReadonly(arg.text)) return variableBuiltinUsageError(self, "unset", "readonly variable");
                self.unsetEnv(arg.text);
            },
            .function => self.unsetFunction(arg.text),
        }
    }
    return emptyResult(self.allocator, 0);
}

fn builtinReadonly(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    var index: usize = 1;
    const option_terminated = index < command.argv.len and std.mem.eql(u8, command.argv[index].text, "--");
    if (option_terminated) index += 1;
    if (index >= command.argv.len) return listReadonly(self);
    if (!option_terminated and std.mem.eql(u8, command.argv[index].text, "-p")) {
        if (command.argv.len != index + 1) return variableBuiltinUsageError(self, "readonly", "too many arguments");
        return listReadonly(self);
    }
    if (!option_terminated and std.mem.startsWith(u8, command.argv[index].text, "-") and !std.mem.eql(u8, command.argv[index].text, "-")) return variableBuiltinUsageError(self, "readonly", "unsupported option");
    for (command.argv[index..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg.text, '=')) |equals| {
            const name = arg.text[0..equals];
            if (!isShellName(name)) return variableBuiltinUsageError(self, "readonly", "invalid variable name");
            if (self.isReadonly(name)) return variableBuiltinUsageError(self, "readonly", "readonly variable");
            try self.setEnv(name, arg.text[equals + 1 ..]);
            try self.setReadonly(name);
        } else {
            if (!isShellName(arg.text)) return variableBuiltinUsageError(self, "readonly", "invalid variable name");
            try self.setReadonly(arg.text);
        }
    }
    return emptyResult(self.allocator, 0);
}

fn listReadonly(self: *Executor) !CommandResult {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var iter = self.readonly.iterator();
    while (iter.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    for (names.items) |name| {
        try stdout.appendSlice(self.allocator, "readonly ");
        try stdout.appendSlice(self.allocator, name);
        if (self.env.get(name)) |value| {
            try stdout.append(self.allocator, '=');
            try appendShellSingleQuoted(self.allocator, &stdout, value);
        }
        try stdout.append(self.allocator, '\n');
    }
    return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
}

fn appendShellSingleQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
}

fn variableBuiltinUsageError(self: *Executor, name: []const u8, message: []const u8) !CommandResult {
    self.pending_exit = 2;
    return errorResult(self.allocator, 2, name, message);
}

fn builtinShift(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    const positionals = self.currentPositionalsPtr();
    const amount: usize = if (command.argv.len == 1) 1 else blk: {
        if (command.argv.len > 2) return shiftUsageError(self, "too many arguments");
        break :blk std.fmt.parseInt(usize, command.argv[1].text, 10) catch return shiftUsageError(self, "numeric argument required");
    };
    if (amount > positionals.params.len) {
        self.pending_exit = 1;
        return errorResult(self.allocator, 1, "shift", "shift count out of range");
    }
    if (positionals.owned) {
        for (positionals.params[0..amount]) |param| self.allocator.free(param);
        std.mem.copyForwards([]const u8, positionals.params[0 .. positionals.params.len - amount], positionals.params[amount..]);
        positionals.params = try self.allocator.realloc(positionals.params, positionals.params.len - amount);
    } else if (amount != 0) {
        positionals.params = &.{};
    }
    try positionals.rebuildDerived(self.allocator);
    return emptyResult(self.allocator, 0);
}

fn shiftUsageError(self: *Executor, message: []const u8) !CommandResult {
    self.pending_exit = 2;
    return errorResult(self.allocator, 2, "shift", message);
}

fn builtinUmask(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    var arg_index: usize = 1;
    var option_terminated = false;
    var symbolic_output = false;
    while (arg_index < command.argv.len) {
        const option = command.argv[arg_index].text;
        if (std.mem.eql(u8, option, "--")) {
            option_terminated = true;
            arg_index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-S")) {
            symbolic_output = true;
            arg_index += 1;
        } else if (std.mem.startsWith(u8, option, "-")) {
            break;
        } else {
            break;
        }
    }
    if (command.argv.len > arg_index + 1) return errorResult(self.allocator, 2, "umask", "too many arguments");
    const old = shellUmask(0);
    _ = shellUmask(old);
    if (arg_index >= command.argv.len) {
        if (symbolic_output) return symbolicUmaskResult(self.allocator, old);
        const stdout = try std.fmt.allocPrint(self.allocator, "{o:0>4}\n", .{@as(u16, @intCast(old & 0o777))});
        errdefer self.allocator.free(stdout);
        return .{ .allocator = self.allocator, .status = 0, .stdout = stdout, .stderr = try self.allocator.alloc(u8, 0) };
    }
    const operand = command.argv[arg_index].text;
    if (!option_terminated and std.mem.startsWith(u8, operand, "-")) return errorResult(self.allocator, 2, "umask", "unsupported option");
    const new_mask = std.fmt.parseInt(u16, operand, 8) catch blk: {
        break :blk parseSymbolicUmask(operand, old) orelse return errorResult(self.allocator, 2, "umask", "invalid mask");
    };
    _ = shellUmask(new_mask);
    return emptyResult(self.allocator, 0);
}

fn parseSymbolicUmask(operand: []const u8, current_mask: u32) ?u16 {
    if (operand.len == 0 or std.ascii.isDigit(operand[0])) return null;
    var mask: u16 = @intCast(current_mask & 0o777);
    var index: usize = 0;
    while (index < operand.len) {
        var who_bits: u16 = 0;
        while (index < operand.len) : (index += 1) {
            switch (operand[index]) {
                'u' => who_bits |= 0o700,
                'g' => who_bits |= 0o070,
                'o' => who_bits |= 0o007,
                'a' => who_bits |= 0o777,
                else => break,
            }
        }
        if (who_bits == 0) who_bits = 0o777;
        if (index >= operand.len) return null;
        const op = operand[index];
        if (op != '+' and op != '-' and op != '=') return null;
        index += 1;

        var permissions: u16 = 0;
        while (index < operand.len and operand[index] != ',') : (index += 1) {
            switch (operand[index]) {
                'r' => permissions |= 0o444,
                'w' => permissions |= 0o222,
                'x' => permissions |= 0o111,
                else => return null,
            }
        }
        const affected_permissions = permissions & who_bits;
        switch (op) {
            '+' => mask &= ~affected_permissions,
            '-' => mask |= affected_permissions,
            '=' => {
                mask |= who_bits;
                mask &= ~affected_permissions;
            },
            else => unreachable,
        }
        if (index < operand.len) {
            if (operand[index] != ',') return null;
            index += 1;
            if (index == operand.len) return null;
        }
    }
    return mask;
}

fn symbolicUmaskResult(allocator: std.mem.Allocator, mask: u32) !CommandResult {
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    const permissions: u32 = (~mask) & 0o777;
    try stdout.appendSlice(allocator, "u=");
    try appendSymbolicPermissions(allocator, &stdout, @intCast((permissions >> 6) & 0o7));
    try stdout.appendSlice(allocator, ",g=");
    try appendSymbolicPermissions(allocator, &stdout, @intCast((permissions >> 3) & 0o7));
    try stdout.appendSlice(allocator, ",o=");
    try appendSymbolicPermissions(allocator, &stdout, @intCast(permissions & 0o7));
    try stdout.append(allocator, '\n');
    return .{ .allocator = allocator, .status = 0, .stdout = try stdout.toOwnedSlice(allocator), .stderr = try allocator.alloc(u8, 0) };
}

fn appendSymbolicPermissions(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), bits: u3) !void {
    if (bits & 0o4 != 0) try stdout.append(allocator, 'r');
    if (bits & 0o2 != 0) try stdout.append(allocator, 'w');
    if (bits & 0o1 != 0) try stdout.append(allocator, 'x');
}

const JobPrintMode = enum { normal, long, pids };

fn builtinJobs(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    self.refreshBackgroundJobs();
    var mode: JobPrintMode = .normal;
    var index: usize = 1;
    while (index < command.argv.len) : (index += 1) {
        const arg = command.argv[index].text;
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) break;
        if (std.mem.eql(u8, arg, "-l")) {
            mode = .long;
        } else if (std.mem.eql(u8, arg, "-p")) {
            mode = .pids;
        } else {
            return errorResult(self.allocator, 2, "jobs", "unsupported option");
        }
    }

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    if (index >= command.argv.len) {
        for (self.background_jobs.items) |job| try appendJobLine(self.allocator, &stdout, job, self.jobMarker(job), mode);
    } else {
        for (command.argv[index..]) |arg| {
            const job = self.findBackgroundJobBySpec(arg.text) orelse return errorResult(self.allocator, 127, "jobs", "unknown job");
            try appendJobLine(self.allocator, &stdout, job.*, self.jobMarker(job.*), mode);
        }
    }
    return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
}

fn appendJobLine(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), job: BackgroundJob, marker: u8, mode: JobPrintMode) !void {
    switch (mode) {
        .pids => try stdout.print(allocator, "{d}\n", .{job.pid}),
        .long => {
            switch (job.state) {
                .running => try stdout.print(allocator, "[{d}]{c} {d} Running {s}\n", .{ job.id, marker, job.pid, job.command }),
                .stopped => try stdout.print(allocator, "[{d}]{c} {d} Stopped {s}\n", .{ job.id, marker, job.pid, job.command }),
                .done => try stdout.print(allocator, "[{d}]{c} {d} Done({d}) {s}\n", .{ job.id, marker, job.pid, job.status, job.command }),
            }
        },
        .normal => {
            switch (job.state) {
                .running => try stdout.print(allocator, "[{d}]{c} Running {s}\n", .{ job.id, marker, job.command }),
                .stopped => try stdout.print(allocator, "[{d}]{c} Stopped {s}\n", .{ job.id, marker, job.command }),
                .done => try stdout.print(allocator, "[{d}]{c} Done({d}) {s}\n", .{ job.id, marker, job.status, job.command }),
            }
        },
    }
}

fn builtinBg(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len > 2) return errorResult(self.allocator, 2, "bg", "too many arguments");
    self.refreshBackgroundJobs();
    const job = if (command.argv.len == 1)
        self.currentBackgroundJob() orelse return errorResult(self.allocator, 1, "bg", "no current job")
    else
        self.findBackgroundJobBySpec(command.argv[1].text) orelse return errorResult(self.allocator, 127, "bg", "unknown job");
    try continueStoppedJob(job);
    self.selectCurrentJob(job.id);
    const stdout = try std.fmt.allocPrint(self.allocator, "[{d}] {s} &\n", .{ job.id, job.command });
    errdefer self.allocator.free(stdout);
    return .{ .allocator = self.allocator, .status = 0, .stdout = stdout, .stderr = try self.allocator.alloc(u8, 0) };
}

fn builtinFg(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;
    if (command.argv.len > 2) return errorResult(self.allocator, 2, "fg", "too many arguments");
    self.refreshBackgroundJobs();
    const job = if (command.argv.len == 1)
        self.currentBackgroundJob() orelse return errorResult(self.allocator, 1, "fg", "no current job")
    else
        self.findBackgroundJobBySpec(command.argv[1].text) orelse return errorResult(self.allocator, 127, "fg", "unknown job");
    const stdout = try std.fmt.allocPrint(self.allocator, "{s}\n", .{job.command});
    errdefer self.allocator.free(stdout);
    try continueStoppedJob(job);
    self.selectCurrentJob(job.id);
    const status = try waitBackgroundJob(io, job);
    return .{ .allocator = self.allocator, .status = status, .stdout = stdout, .stderr = try self.allocator.alloc(u8, 0) };
}

fn builtinWait(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    self.refreshBackgroundJobs();
    const operand_start: usize = if (command.argv.len > 1 and std.mem.eql(u8, command.argv[1].text, "--")) 2 else 1;
    if (operand_start >= command.argv.len and self.background_jobs.items.len == 0) return emptyResult(self.allocator, 0);
    const io = options.io orelse return error.MissingIoForBuiltin;
    if (operand_start >= command.argv.len) {
        var status: ExitStatus = 0;
        for (self.background_jobs.items) |*job| status = try waitBackgroundJob(io, job);
        return emptyResult(self.allocator, status);
    }

    var status: ExitStatus = 0;
    for (command.argv[operand_start..]) |arg| {
        const pid = std.fmt.parseInt(i64, arg.text, 10) catch return errorResult(self.allocator, 127, "wait", "invalid pid");
        const job = self.findBackgroundJob(pid) orelse return errorResult(self.allocator, 127, "wait", "unknown pid");
        status = try waitBackgroundJob(io, job);
    }
    return emptyResult(self.allocator, status);
}

fn waitBackgroundJob(io: std.Io, job: *BackgroundJob) !ExitStatus {
    if (job.state != .done) {
        const term = try job.child.wait(io);
        job.status = exitStatusFromTerm(term);
        job.state = switch (term) {
            .stopped => .stopped,
            else => .done,
        };
        if (job.state == .stopped) saveJobTerminalModes(job);
    }
    return job.status;
}

fn continueStoppedJob(job: *BackgroundJob) !void {
    if (job.state != .stopped) return;
    restoreJobTerminalModes(job);
    const pid: std.posix.pid_t = @intCast(job.pid);
    try std.posix.kill(pid, .CONT);
    job.state = .running;
}

fn saveJobTerminalModes(job: *BackgroundJob) void {
    job.saved_termios = std.posix.tcgetattr(std.Io.File.stdin().handle) catch |err| switch (err) {
        error.NotATerminal => null,
        else => null,
    };
}

fn restoreJobTerminalModes(job: *BackgroundJob) void {
    const termios = job.saved_termios orelse return;
    std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, termios) catch {};
}

fn builtinTimes(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len != 1) return errorResult(self.allocator, 2, "times", "too many arguments");
    const usage = readResourceUsage();
    const self_user = try formatCpuTime(self.allocator, usage.self_user);
    defer self.allocator.free(self_user);
    const self_system = try formatCpuTime(self.allocator, usage.self_system);
    defer self.allocator.free(self_system);
    const children_user = try formatCpuTime(self.allocator, usage.children_user);
    defer self.allocator.free(children_user);
    const children_system = try formatCpuTime(self.allocator, usage.children_system);
    defer self.allocator.free(children_system);
    const stdout = try std.fmt.allocPrint(self.allocator, "{s} {s}\n{s} {s}\n", .{ self_user, self_system, children_user, children_system });
    errdefer self.allocator.free(stdout);
    return .{ .allocator = self.allocator, .status = 0, .stdout = stdout, .stderr = try self.allocator.alloc(u8, 0) };
}

const CpuUsage = struct {
    self_user: u64 = 0,
    self_system: u64 = 0,
    children_user: u64 = 0,
    children_system: u64 = 0,
};

fn readResourceUsage() CpuUsage {
    if (!zig_builtin.link_libc) return .{};
    var self_usage: std.c.rusage = undefined;
    var child_usage: std.c.rusage = undefined;
    const self_ok = std.c.getrusage(0, &self_usage) == 0;
    const child_ok = std.c.getrusage(-1, &child_usage) == 0;
    return .{
        .self_user = if (self_ok) timevalCentiseconds(self_usage.utime) else 0,
        .self_system = if (self_ok) timevalCentiseconds(self_usage.stime) else 0,
        .children_user = if (child_ok) timevalCentiseconds(child_usage.utime) else 0,
        .children_system = if (child_ok) timevalCentiseconds(child_usage.stime) else 0,
    };
}

fn timevalCentiseconds(value: std.c.timeval) u64 {
    const seconds: u64 = @intCast(if (value.sec < 0) 0 else value.sec);
    const micros: u64 = @intCast(if (value.usec < 0) 0 else value.usec);
    return seconds * 100 + micros / 10_000;
}

fn formatCpuTime(allocator: std.mem.Allocator, centiseconds: u64) ![]u8 {
    const minutes = centiseconds / 6000;
    const seconds = (centiseconds / 100) % 60;
    const hundredths = centiseconds % 100;
    return std.fmt.allocPrint(allocator, "{d}m{d}.{d:0>2}s", .{ minutes, seconds, hundredths });
}

fn builtinReturn(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (self.function_depth == 0) return returnUsageError(self, "not in a function");
    if (command.argv.len > 2) return returnUsageError(self, "too many arguments");
    const status: ExitStatus = if (command.argv.len == 2) blk: {
        const parsed = std.fmt.parseInt(u8, command.argv[1].text, 10) catch return returnUsageError(self, "numeric argument required");
        break :blk parsed;
    } else self.lastStatus();
    self.pending_return = status;
    return emptyResult(self.allocator, status);
}

fn returnUsageError(self: *Executor, message: []const u8) !CommandResult {
    self.pending_exit = 2;
    return errorResult(self.allocator, 2, "return", message);
}

fn builtinSet(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;

    if (command.argv.len == 1) return printShellOptions(self, false);
    if (command.argv.len >= 2 and std.mem.eql(u8, command.argv[1].text, "--")) {
        try setCurrentPositionals(self, command.argv[2..]);
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and isSetShortOptionCluster(command.argv[1].text)) {
        try applySetShortOptionCluster(self, command.argv[1].text);
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-a") or std.mem.eql(u8, command.argv[1].text, "+a"))) {
        self.shell_options.allexport = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-f") or std.mem.eql(u8, command.argv[1].text, "+f"))) {
        self.shell_options.noglob = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-C") or std.mem.eql(u8, command.argv[1].text, "+C"))) {
        self.shell_options.noclobber = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-u") or std.mem.eql(u8, command.argv[1].text, "+u"))) {
        self.shell_options.nounset = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-e") or std.mem.eql(u8, command.argv[1].text, "+e"))) {
        self.shell_options.errexit = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-x") or std.mem.eql(u8, command.argv[1].text, "+x"))) {
        self.shell_options.xtrace = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-v") or std.mem.eql(u8, command.argv[1].text, "+v"))) {
        self.shell_options.verbose = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and std.mem.eql(u8, command.argv[1].text, "-o")) return printShellOptions(self, false);
    if (command.argv.len == 2 and std.mem.eql(u8, command.argv[1].text, "+o")) return printShellOptions(self, true);
    if (command.argv.len == 3 and (std.mem.eql(u8, command.argv[1].text, "-o") or std.mem.eql(u8, command.argv[1].text, "+o"))) {
        const enabled = command.argv[1].text[0] == '-';
        if (std.mem.eql(u8, command.argv[2].text, "pipefail")) {
            self.shell_options.pipefail = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "allexport")) {
            self.shell_options.allexport = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "noglob")) {
            self.shell_options.noglob = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "noclobber")) {
            self.shell_options.noclobber = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "nounset")) {
            self.shell_options.nounset = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "errexit")) {
            self.shell_options.errexit = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "xtrace")) {
            self.shell_options.xtrace = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "verbose")) {
            self.shell_options.verbose = enabled;
            return emptyResult(self.allocator, 0);
        }
        return setUsageError(self, "unknown option name");
    }
    return setUsageError(self, "unsupported arguments");
}

fn isSetShortOptionCluster(text: []const u8) bool {
    if (text.len <= 2) return false;
    if (text[0] != '-' and text[0] != '+') return false;
    for (text[1..]) |option| switch (option) {
        'a', 'e', 'f', 'u', 'x', 'v', 'C' => {},
        else => return false,
    };
    return true;
}

fn applySetShortOptionCluster(self: *Executor, text: []const u8) !void {
    const enabled = text[0] == '-';
    for (text[1..]) |option| switch (option) {
        'a' => self.shell_options.allexport = enabled,
        'e' => self.shell_options.errexit = enabled,
        'f' => self.shell_options.noglob = enabled,
        'u' => self.shell_options.nounset = enabled,
        'x' => self.shell_options.xtrace = enabled,
        'v' => self.shell_options.verbose = enabled,
        'C' => self.shell_options.noclobber = enabled,
        else => unreachable,
    };
}

fn setUsageError(self: *Executor, message: []const u8) !CommandResult {
    self.pending_exit = 2;
    return errorResult(self.allocator, 2, "set", message);
}

fn setCurrentPositionals(self: *Executor, args: []const ir.WordRef) !void {
    var values = try self.allocator.alloc([]const u8, args.len);
    defer self.allocator.free(values);
    for (args, 0..) |arg, index| values[index] = arg.text;
    try self.currentPositionalsPtr().set(self.allocator, values);
}

fn printShellOptions(self: *Executor, reusable: bool) !CommandResult {
    const stdout = if (reusable)
        try std.fmt.allocPrint(self.allocator, "set {s}o allexport\nset {s}o errexit\nset {s}o noclobber\nset {s}o noglob\nset {s}o nounset\nset {s}o pipefail\nset {s}o verbose\nset {s}o xtrace\n", .{ if (self.shell_options.allexport) "-" else "+", if (self.shell_options.errexit) "-" else "+", if (self.shell_options.noclobber) "-" else "+", if (self.shell_options.noglob) "-" else "+", if (self.shell_options.nounset) "-" else "+", if (self.shell_options.pipefail) "-" else "+", if (self.shell_options.verbose) "-" else "+", if (self.shell_options.xtrace) "-" else "+" })
    else
        try std.fmt.allocPrint(self.allocator, "allexport\t{s}\nerrexit\t{s}\nnoclobber\t{s}\nnoglob\t{s}\nnounset\t{s}\npipefail\t{s}\nverbose\t{s}\nxtrace\t{s}\n", .{ if (self.shell_options.allexport) "on" else "off", if (self.shell_options.errexit) "on" else "off", if (self.shell_options.noclobber) "on" else "off", if (self.shell_options.noglob) "on" else "off", if (self.shell_options.nounset) "on" else "off", if (self.shell_options.pipefail) "on" else "off", if (self.shell_options.verbose) "on" else "off", if (self.shell_options.xtrace) "on" else "off" });
    errdefer self.allocator.free(stdout);
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = stdout,
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn builtinEnv(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    var child = Executor.init(self.allocator);
    defer child.deinit();
    try child.copyStateFrom(self);

    var index: usize = 1;
    while (index < command.argv.len) {
        const option = command.argv[index].text;
        if (std.mem.eql(u8, option, "-i")) {
            child.clearEnvironment();
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, option, "--")) {
            index += 1;
            break;
        }
        if (std.mem.startsWith(u8, option, "-") and !std.mem.eql(u8, option, "-")) return errorResult(self.allocator, 2, "env", "unsupported option");
        break;
    }

    while (index < command.argv.len) {
        const assignment = envAssignment(command.argv[index].text) orelse break;
        try child.setEnv(assignment.name, assignment.value);
        try child.setExported(assignment.name);
        index += 1;
    }

    if (index >= command.argv.len) {
        var process_env = try child.buildProcessEnv(&.{});
        defer process_env.deinit();
        return printProcessEnvironment(self.allocator, &process_env);
    }

    const nested: ir.SimpleCommand = .{
        .span = command.span,
        .assignments = &.{},
        .argv = command.argv[index..],
        .redirections = &.{},
    };
    return child.executeSimpleCommandWithInput(nested, stdin, options);
}

fn printEnvironment(allocator: std.mem.Allocator, env: std.StringHashMapUnmanaged([]const u8)) !CommandResult {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var iter = env.iterator();
    while (iter.next()) |entry| try names.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    for (names.items) |name| {
        try stdout.appendSlice(allocator, name);
        try stdout.append(allocator, '=');
        try stdout.appendSlice(allocator, env.get(name).?);
        try stdout.append(allocator, '\n');
    }

    return .{
        .allocator = allocator,
        .status = 0,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try allocator.alloc(u8, 0),
    };
}

fn printProcessEnvironment(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !CommandResult {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    for (env.keys()) |name| try names.append(allocator, name);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    for (names.items) |name| {
        try stdout.appendSlice(allocator, name);
        try stdout.append(allocator, '=');
        try stdout.appendSlice(allocator, env.get(name).?);
        try stdout.append(allocator, '\n');
    }

    return .{
        .allocator = allocator,
        .status = 0,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try allocator.alloc(u8, 0),
    };
}

const EnvAssignment = struct {
    name: []const u8,
    value: []const u8,
};

fn envAssignment(text: []const u8) ?EnvAssignment {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    if (equals == 0) return null;
    return .{ .name = text[0..equals], .value = text[equals + 1 ..] };
}

fn builtinTest(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const is_bracket = std.mem.eql(u8, command.argv[0].text, "[");
    const args = command.argv[1..];
    if (is_bracket) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1].text, "]")) {
            return errorResult(self.allocator, 2, "[", "missing ]");
        }
        const matched = evalTest(self.allocator, options, args[0 .. args.len - 1]) catch return errorResult(self.allocator, 2, command.argv[0].text, "invalid expression");
        return emptyResult(self.allocator, if (matched) 0 else 1);
    }
    const matched = evalTest(self.allocator, options, args) catch return errorResult(self.allocator, 2, command.argv[0].text, "invalid expression");
    return emptyResult(self.allocator, if (matched) 0 else 1);
}

fn evalBashTest(allocator: std.mem.Allocator, options: ExecuteOptions, args: []const ir.WordRef) !bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].text.len != 0,
        2 => try evalUnaryTest(allocator, options, args[0].text, args[1].text),
        3 => if (std.mem.eql(u8, args[0].text, "!"))
            !(try evalBashTest(allocator, options, args[1..]))
        else if (std.mem.eql(u8, args[1].text, "==") or std.mem.eql(u8, args[1].text, "="))
            shellPatternMatches(args[2].text, args[0].text)
        else if (std.mem.eql(u8, args[1].text, "!="))
            !shellPatternMatches(args[2].text, args[0].text)
        else
            try evalBinaryTest(args[0].text, args[1].text, args[2].text),
        4 => if (std.mem.eql(u8, args[0].text, "!")) !(try evalBashTest(allocator, options, args[1..])) else error.InvalidTestExpression,
        else => error.InvalidTestExpression,
    };
}

fn evalTest(allocator: std.mem.Allocator, options: ExecuteOptions, args: []const ir.WordRef) !bool {
    if (hasTestExpressionOperator(args)) {
        var test_parser: TestExpressionParser = .{ .allocator = allocator, .options = options, .args = args };
        const result = try test_parser.parseOr();
        if (test_parser.index != args.len) return error.InvalidTestExpression;
        return result;
    }
    return evalSimpleTest(allocator, options, args);
}

fn evalSimpleTest(allocator: std.mem.Allocator, options: ExecuteOptions, args: []const ir.WordRef) !bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].text.len != 0,
        2 => try evalUnaryTest(allocator, options, args[0].text, args[1].text),
        3 => if (std.mem.eql(u8, args[0].text, "!"))
            !(try evalSimpleTest(allocator, options, args[1..]))
        else
            try evalBinaryTest(args[0].text, args[1].text, args[2].text),
        4 => if (std.mem.eql(u8, args[0].text, "!")) !(try evalSimpleTest(allocator, options, args[1..])) else error.InvalidTestExpression,
        else => error.InvalidTestExpression,
    };
}

fn hasTestExpressionOperator(args: []const ir.WordRef) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg.text, "-a") or std.mem.eql(u8, arg.text, "-o") or std.mem.eql(u8, arg.text, "(") or std.mem.eql(u8, arg.text, ")")) return true;
    }
    return false;
}

const TestExpressionError = error{InvalidTestExpression};

const TestExpressionParser = struct {
    allocator: std.mem.Allocator,
    options: ExecuteOptions,
    args: []const ir.WordRef,
    index: usize = 0,

    fn parseOr(self: *TestExpressionParser) TestExpressionError!bool {
        var result = try self.parseAnd();
        while (self.match("-o")) {
            const rhs = try self.parseAnd();
            result = result or rhs;
        }
        return result;
    }

    fn parseAnd(self: *TestExpressionParser) TestExpressionError!bool {
        var result = try self.parseNot();
        while (self.match("-a")) {
            const rhs = try self.parseNot();
            result = result and rhs;
        }
        return result;
    }

    fn parseNot(self: *TestExpressionParser) TestExpressionError!bool {
        if (self.match("!")) return !(try self.parseNot());
        return self.parsePrimary();
    }

    fn parsePrimary(self: *TestExpressionParser) TestExpressionError!bool {
        if (self.index >= self.args.len) return error.InvalidTestExpression;
        if (self.match("(")) {
            const result = try self.parseOr();
            if (!self.match(")")) return error.InvalidTestExpression;
            return result;
        }
        if (self.index + 2 < self.args.len and isBinaryTestOperator(self.args[self.index + 1].text)) {
            const left = self.args[self.index].text;
            const op = self.args[self.index + 1].text;
            const right = self.args[self.index + 2].text;
            self.index += 3;
            return evalBinaryTest(left, op, right);
        }
        if (self.index + 1 < self.args.len and isUnaryTestOperator(self.args[self.index].text)) {
            const op = self.args[self.index].text;
            const operand = self.args[self.index + 1].text;
            self.index += 2;
            return evalUnaryTest(self.allocator, self.options, op, operand);
        }
        const value = self.args[self.index].text.len != 0;
        self.index += 1;
        return value;
    }

    fn match(self: *TestExpressionParser, text: []const u8) bool {
        if (self.index >= self.args.len or !std.mem.eql(u8, self.args[self.index].text, text)) return false;
        self.index += 1;
        return true;
    }
};

fn isUnaryTestOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "!") or std.mem.eql(u8, op, "-n") or std.mem.eql(u8, op, "-z") or
        std.mem.eql(u8, op, "-e") or std.mem.eql(u8, op, "-f") or std.mem.eql(u8, op, "-d") or std.mem.eql(u8, op, "-s") or
        std.mem.eql(u8, op, "-b") or std.mem.eql(u8, op, "-c") or std.mem.eql(u8, op, "-p") or std.mem.eql(u8, op, "-S") or
        std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h") or std.mem.eql(u8, op, "-u") or std.mem.eql(u8, op, "-g") or
        std.mem.eql(u8, op, "-k") or std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(u8, op, "-x") or
        std.mem.eql(u8, op, "-t");
}

fn isBinaryTestOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "-eq") or std.mem.eql(u8, op, "-ne") or
        std.mem.eql(u8, op, "-gt") or std.mem.eql(u8, op, "-ge") or std.mem.eql(u8, op, "-lt") or std.mem.eql(u8, op, "-le");
}

fn evalUnaryTest(allocator: std.mem.Allocator, options: ExecuteOptions, op: []const u8, operand: []const u8) !bool {
    if (std.mem.eql(u8, op, "!")) return operand.len == 0;
    if (std.mem.eql(u8, op, "-n")) return operand.len != 0;
    if (std.mem.eql(u8, op, "-z")) return operand.len == 0;
    if (std.mem.eql(u8, op, "-e") or std.mem.eql(u8, op, "-f") or std.mem.eql(u8, op, "-d") or std.mem.eql(u8, op, "-s") or std.mem.eql(u8, op, "-b") or std.mem.eql(u8, op, "-c") or std.mem.eql(u8, op, "-p") or std.mem.eql(u8, op, "-S")) {
        const io = options.io orelse return false;
        const stat = statPath(allocator, io, operand) catch return false;
        if (std.mem.eql(u8, op, "-e")) return true;
        if (std.mem.eql(u8, op, "-f")) return stat.kind == .file;
        if (std.mem.eql(u8, op, "-d")) return stat.kind == .directory;
        if (std.mem.eql(u8, op, "-s")) return stat.size > 0;
        if (std.mem.eql(u8, op, "-b")) return stat.kind == .block_device;
        if (std.mem.eql(u8, op, "-c")) return stat.kind == .character_device;
        if (std.mem.eql(u8, op, "-p")) return stat.kind == .named_pipe;
        if (std.mem.eql(u8, op, "-S")) return stat.kind == .unix_domain_socket;
    }
    if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
        const io = options.io orelse return false;
        const stat = statPathNoFollow(allocator, io, operand) catch return false;
        return stat.kind == .sym_link;
    }
    if (std.mem.eql(u8, op, "-u") or std.mem.eql(u8, op, "-g") or std.mem.eql(u8, op, "-k")) {
        const io = options.io orelse return false;
        const stat = statPathNoFollow(allocator, io, operand) catch return false;
        const mode = stat.permissions.toMode();
        if (std.mem.eql(u8, op, "-u")) return mode & 0o4000 != 0;
        if (std.mem.eql(u8, op, "-g")) return mode & 0o2000 != 0;
        if (std.mem.eql(u8, op, "-k")) return mode & 0o1000 != 0;
    }
    if (std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(u8, op, "-x")) {
        const io = options.io orelse return false;
        std.Io.Dir.cwd().access(io, operand, .{
            .read = std.mem.eql(u8, op, "-r"),
            .write = std.mem.eql(u8, op, "-w"),
            .execute = std.mem.eql(u8, op, "-x"),
        }) catch return false;
        return true;
    }
    if (std.mem.eql(u8, op, "-t")) {
        const fd = std.fmt.parseInt(std.c.fd_t, operand, 10) catch return error.InvalidTestExpression;
        return std.c.isatty(fd) == 1;
    }
    return error.InvalidTestExpression;
}

fn evalBinaryTest(left: []const u8, op: []const u8, right: []const u8) !bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "<")) return std.mem.lessThan(u8, left, right);
    if (std.mem.eql(u8, op, ">")) return std.mem.lessThan(u8, right, left);

    const lhs = std.fmt.parseInt(i64, left, 10) catch return error.InvalidTestExpression;
    const rhs = std.fmt.parseInt(i64, right, 10) catch return error.InvalidTestExpression;
    if (std.mem.eql(u8, op, "-eq")) return lhs == rhs;
    if (std.mem.eql(u8, op, "-ne")) return lhs != rhs;
    if (std.mem.eql(u8, op, "-gt")) return lhs > rhs;
    if (std.mem.eql(u8, op, "-ge")) return lhs >= rhs;
    if (std.mem.eql(u8, op, "-lt")) return lhs < rhs;
    if (std.mem.eql(u8, op, "-le")) return lhs <= rhs;
    return error.InvalidTestExpression;
}

fn statPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.File.Stat {
    _ = allocator;
    return std.Io.Dir.cwd().statFile(io, path, .{});
}

fn statPathNoFollow(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.File.Stat {
    _ = allocator;
    return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
}

fn joinParams(allocator: std.mem.Allocator, params: []const []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (params, 0..) |param, index| {
        if (index > 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, param);
    }
    return joined.toOwnedSlice(allocator);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isRedirectionOnlyExec(command: ir.SimpleCommand) bool {
    return command.argv.len == 1 and std.mem.eql(u8, command.argv[0].text, "exec") and command.redirections.len != 0;
}

fn targetName(redirection: ir.Redirection) []const u8 {
    return if (redirection.target) |target| target.text else "redirection";
}

fn noclobberTargetName(command: ir.SimpleCommand) []const u8 {
    for (command.redirections) |redirection| {
        if (redirection.operator == .greater) return targetName(redirection);
    }
    return "redirection";
}

fn badFdTargetName(command: ir.SimpleCommand) []const u8 {
    for (command.redirections) |redirection| {
        if (redirection.operator == .greater_and or redirection.operator == .less_and) return targetName(redirection);
    }
    return "redirection";
}

fn redirectionTargetName(command: ir.SimpleCommand) []const u8 {
    for (command.redirections) |redirection| {
        if (redirection.target != null) return targetName(redirection);
    }
    return "redirection";
}

fn inputTargetName(command: ir.SimpleCommand) []const u8 {
    for (command.redirections) |redirection| {
        if (isStdinFileRedirection(redirection)) return targetName(redirection);
    }
    return "redirection";
}

fn isHereDocRedirection(redirection: ir.Redirection) bool {
    const fd = redirectionFd(redirection) orelse 0;
    return fd == 0 and (redirection.operator == .dless or redirection.operator == .dless_dash);
}

fn externalStdioCapturesStdout(stdio: ExternalStdio) bool {
    return stdio == .capture or stdio == .capture_stdout;
}

fn externalStdioCapturesStderr(stdio: ExternalStdio) bool {
    return stdio == .capture;
}

fn externalStdinUsesScriptInput(stdio: ExternalStdio) bool {
    return stdio == .capture or stdio == .capture_stdout;
}

fn externalStdioInheritsStdin(stdio: ExternalStdio) bool {
    return stdio == .inherit;
}

fn commandDuplicatesStderrToStdout(redirections: []const ir.Redirection) bool {
    var stderr_to_stdout = false;
    for (redirections) |redirection| {
        if (isFileOutputRedirection(redirection)) {
            const fd = redirectionFd(redirection) orelse 1;
            if (fd == 2) stderr_to_stdout = false;
            continue;
        }
        if (redirection.operator != .greater_and) continue;
        const from_fd = redirectionFd(redirection) orelse 1;
        if (from_fd != 2) continue;
        const target = redirection.target orelse continue;
        stderr_to_stdout = std.mem.eql(u8, target.text, "1");
    }
    return stderr_to_stdout;
}

fn isStdinFileRedirection(redirection: ir.Redirection) bool {
    const fd = redirectionFd(redirection) orelse 0;
    return fd == 0 and (redirection.operator == .less or redirection.operator == .less_great);
}

fn isFileOutputRedirection(redirection: ir.Redirection) bool {
    return switch (redirection.operator) {
        .greater, .dgreat, .clobber => true,
        else => false,
    };
}

fn redirectionFd(redirection: ir.Redirection) ?std.posix.fd_t {
    if (redirection.io_number) |io_number| return parseFd(io_number.text);
    return null;
}

fn parseFd(text: []const u8) ?std.posix.fd_t {
    if (text.len == 0) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const value = std.fmt.parseInt(std.posix.fd_t, text, 10) catch return null;
    if (value < 0) return null;
    return value;
}

fn emptyResult(allocator: std.mem.Allocator, status: ExitStatus) !CommandResult {
    return .{
        .allocator = allocator,
        .status = status,
        .stdout = try allocator.alloc(u8, 0),
        .stderr = try allocator.alloc(u8, 0),
    };
}

fn errorResult(allocator: std.mem.Allocator, status: ExitStatus, command: []const u8, message: []const u8) !CommandResult {
    const stderr = try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{ command, message });
    errdefer allocator.free(stderr);
    return .{
        .allocator = allocator,
        .status = status,
        .stdout = try allocator.alloc(u8, 0),
        .stderr = stderr,
    };
}

const CasePattern = struct {
    text: []const u8,
    special: []const bool,

    fn deinit(self: *CasePattern, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.special);
        self.* = undefined;
    }
};

fn appendCasePatternPart(allocator: std.mem.Allocator, text: *std.ArrayList(u8), special: *std.ArrayList(bool), rendered: []const u8, meta_active: bool) !void {
    try text.appendSlice(allocator, rendered);
    for (rendered) |byte| {
        try special.append(allocator, meta_active and (byte == '*' or byte == '?' or byte == '['));
    }
}

fn shellPatternMatches(pattern: []const u8, text: []const u8) bool {
    return shellPatternMatchesFrom(pattern, null, text, 0, 0);
}

fn shellCasePatternMatches(pattern: CasePattern, text: []const u8) bool {
    std.debug.assert(pattern.text.len == pattern.special.len);
    return shellPatternMatchesFrom(pattern.text, pattern.special, text, 0, 0);
}

fn isSpecialPatternByte(special: ?[]const bool, index: usize) bool {
    return if (special) |mask| mask[index] else true;
}

fn shellPatternMatchesFrom(pattern: []const u8, special: ?[]const bool, text: []const u8, pattern_index: usize, text_index: usize) bool {
    if (pattern_index == pattern.len) return text_index == text.len;
    if (pattern[pattern_index] == '*' and isSpecialPatternByte(special, pattern_index)) {
        var next_text = text_index;
        while (next_text <= text.len) : (next_text += 1) {
            if (shellPatternMatchesFrom(pattern, special, text, pattern_index + 1, next_text)) return true;
        }
        return false;
    }
    if (text_index >= text.len) return false;
    if (pattern[pattern_index] == '[' and isSpecialPatternByte(special, pattern_index)) {
        if (matchShellBracket(pattern, pattern_index, text[text_index])) |matched| {
            return matched.ok and shellPatternMatchesFrom(pattern, special, text, matched.next_pattern, text_index + 1);
        }
    }
    if ((pattern[pattern_index] == '?' and isSpecialPatternByte(special, pattern_index)) or pattern[pattern_index] == text[text_index]) {
        return shellPatternMatchesFrom(pattern, special, text, pattern_index + 1, text_index + 1);
    }
    return false;
}

const ShellBracketMatch = struct { ok: bool, next_pattern: usize };

fn matchShellBracket(pattern: []const u8, pattern_index: usize, text: u8) ?ShellBracketMatch {
    var index = pattern_index + 1;
    if (index >= pattern.len) return null;
    const negated = pattern[index] == '!' or pattern[index] == '^';
    if (negated) index += 1;

    var matched = false;
    var first_expression = true;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == ']' and !first_expression) {
            return .{ .ok = if (negated) !matched else matched, .next_pattern = index + 1 };
        }
        first_expression = false;

        if (index + 2 < pattern.len and pattern[index + 1] == '-' and pattern[index + 2] != ']') {
            const start = pattern[index];
            const end = pattern[index + 2];
            if (start <= text and text <= end) matched = true;
            index += 2;
            continue;
        }

        if (pattern[index] == text) matched = true;
    }

    return null;
}

fn exitStatusFromTerm(term: std.process.Child.Term) ExitStatus {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .stopped => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .unknown => 1,
    };
}

fn exitStatusFromWaitStatus(status: u32) ExitStatus {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) return 128 + signalStatusNumber(std.posix.W.TERMSIG(status));
    if (std.posix.W.IFSTOPPED(status)) return 128 + signalStatusNumber(std.posix.W.STOPSIG(status));
    return 1;
}

fn signalStatusNumber(signal: anytype) u8 {
    return switch (@typeInfo(@TypeOf(signal))) {
        .@"enum" => @intCast(@intFromEnum(signal)),
        else => @intCast(signal),
    };
}

const LoweredForTest = struct { parsed: parser.ParseResult, program: ir.Program };

fn expectTimesOutputShape(output: []const u8) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    const first = lines.next() orelse return error.MissingTimesLine;
    const second = lines.next() orelse return error.MissingTimesLine;
    const third = lines.next() orelse return error.MissingTimesLine;
    try std.testing.expect(first.len != 0);
    try std.testing.expect(second.len != 0);
    try std.testing.expectEqualStrings("", third);
    try std.testing.expect(std.mem.indexOf(u8, first, "m") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "s ") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "m") != null);
    try std.testing.expect(std.mem.endsWith(u8, second, "s"));
}

fn parseAndLower(allocator: std.mem.Allocator, source: []const u8) !LoweredForTest {
    return parseAndLowerWithOptions(allocator, source, .{});
}

fn parseAndLowerWithOptions(allocator: std.mem.Allocator, source: []const u8, options: parser.ParseOptions) !LoweredForTest {
    var parsed = try parser.parse(allocator, source, options);
    errdefer parsed.deinit();
    var program = try ir.lowerSimpleCommands(allocator, parsed);
    errdefer program.deinit();
    return .{ .parsed = parsed, .program = program };
}

test "executor uses quote-removed argv text" {
    var lowered = try parseAndLower(std.testing.allocator, "echo 'hello world'");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world\n", result.stdout);
}

test "executor runs true false and echo builtins" {
    var lowered = try parseAndLower(std.testing.allocator, "true");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    var lowered_false = try parseAndLower(std.testing.allocator, "false");
    defer lowered_false.parsed.deinit();
    defer lowered_false.program.deinit();
    var false_result = try executor.executeProgram(lowered_false.program, .{});
    defer false_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), false_result.status);

    var lowered_echo = try parseAndLower(std.testing.allocator, "echo hello world");
    defer lowered_echo.parsed.deinit();
    defer lowered_echo.program.deinit();
    var echo_result = try executor.executeProgram(lowered_echo.program, .{});
    defer echo_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), echo_result.status);
    try std.testing.expectEqualStrings("hello world\n", echo_result.stdout);
}

test "executor executes Bash conditional command baseline" {
    var pattern = try parseAndLowerWithOptions(std.testing.allocator, "[[ foobar == foo* ]]", .{ .features = compat.Features.bash() });
    defer pattern.parsed.deinit();
    defer pattern.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var pattern_result = try executor.executeProgram(pattern.program, .{});
    defer pattern_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), pattern_result.status);

    var string_false = try parseAndLowerWithOptions(std.testing.allocator, "[[ foo == bar ]]", .{ .features = compat.Features.bash() });
    defer string_false.parsed.deinit();
    defer string_false.program.deinit();
    var string_false_result = try executor.executeProgram(string_false.program, .{});
    defer string_false_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), string_false_result.status);

    var integer = try parseAndLowerWithOptions(std.testing.allocator, "[[ 5 -gt 3 ]]", .{ .features = compat.Features.bash() });
    defer integer.parsed.deinit();
    defer integer.program.deinit();
    var integer_result = try executor.executeProgram(integer.program, .{});
    defer integer_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), integer_result.status);

    var parameter = try parseAndLowerWithOptions(std.testing.allocator, "FOO=bar; [[ $FOO == b* ]]", .{ .features = compat.Features.bash() });
    defer parameter.parsed.deinit();
    defer parameter.program.deinit();
    var parameter_result = try executor.executeProgram(parameter.program, .{});
    defer parameter_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), parameter_result.status);
}

test "executor executes POSIX subshells with isolated state" {
    var lowered = try parseAndLower(std.testing.allocator, "FOO=outer; ( FOO=inner; echo $FOO; f; ); echo $FOO; f");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setFunction("f", "echo outer-f", &.{});

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("inner\nouter-f\nouter\nouter-f\n", result.stdout);

    const path = "rush-subshell-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var redirected = try parseAndLower(std.testing.allocator, "( echo one; echo two ) > rush-subshell-redirection.tmp");
    defer redirected.parsed.deinit();
    defer redirected.program.deinit();
    var redirected_result = try executor.executeProgram(redirected.program, .{ .io = std.testing.io });
    defer redirected_result.deinit();
    try std.testing.expectEqualStrings("", redirected_result.stdout);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}

test "executor executes POSIX brace groups in current shell" {
    var lowered = try parseAndLower(std.testing.allocator, "{ FOO=bar; echo $FOO; }; echo $FOO");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("bar\nbar\n", result.stdout);

    const path = "rush-brace-group-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var redirected = try parseAndLower(std.testing.allocator, "{ echo one; echo two; } > rush-brace-group-redirection.tmp");
    defer redirected.parsed.deinit();
    defer redirected.program.deinit();
    var redirected_result = try executor.executeProgram(redirected.program, .{ .io = std.testing.io });
    defer redirected_result.deinit();
    try std.testing.expectEqualStrings("", redirected_result.stdout);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}

test "executor implements source and dot builtins" {
    const path = "rush-source-test.sh";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "FOO=sourced\nf() { echo from-source; }\n" });

    var lowered = try parseAndLower(std.testing.allocator, ". ./rush-source-test.sh; echo $FOO; f");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("sourced\nfrom-source\n", result.stdout);

    try executor.setEnv("PATH", ".");
    var source_lowered = try parseAndLower(std.testing.allocator, "source rush-source-test.sh; f");
    defer source_lowered.parsed.deinit();
    defer source_lowered.program.deinit();
    var source_result = try executor.executeProgram(source_lowered.program, .{ .io = std.testing.io });
    defer source_result.deinit();
    try std.testing.expectEqualStrings("from-source\n", source_result.stdout);
}

test "source builtin reports file and line for runtime errors" {
    const path = "rush-source-error-test.sh";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\echo ok
        \\complete git --function __rush_complete_git
    });

    var lowered = try parseAndLower(std.testing.allocator, ". ./rush-source-error-test.sh");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("ok\n", result.stdout);
    try std.testing.expectEqualStrings("./rush-source-error-test.sh:2: complete: --function requires --subcommands, --options, --argument, or --option-value\n", result.stderr);
}

test "executor supports break and continue builtins in loops" {
    var break_lowered = try parseAndLower(std.testing.allocator, "for x in a b; do echo $x; break; done");
    defer break_lowered.parsed.deinit();
    defer break_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var break_result = try executor.executeProgram(break_lowered.program, .{});
    defer break_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), break_result.status);
    try std.testing.expectEqualStrings("a\n", break_result.stdout);

    var continue_lowered = try parseAndLower(std.testing.allocator, "for x in a b; do continue; echo nope; done");
    defer continue_lowered.parsed.deinit();
    defer continue_lowered.program.deinit();
    var continue_result = try executor.executeProgram(continue_lowered.program, .{});
    defer continue_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), continue_result.status);
    try std.testing.expectEqualStrings("", continue_result.stdout);

    var outside = try parseAndLower(std.testing.allocator, "break");
    defer outside.parsed.deinit();
    defer outside.program.deinit();
    var outside_result = try executor.executeProgram(outside.program, .{});
    defer outside_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 2), outside_result.status);
    try std.testing.expect(std.mem.indexOf(u8, outside_result.stderr, "not in a loop") != null);
}

test "executor supports return builtin in shell functions" {
    var returned = try parseAndLower(std.testing.allocator, "f() { echo before; return 7; echo after; }; f");
    defer returned.parsed.deinit();
    defer returned.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(returned.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("before\n", result.stdout);

    var continues = try parseAndLower(std.testing.allocator, "f() { return 3; }; f; echo after");
    defer continues.parsed.deinit();
    defer continues.program.deinit();
    var continues_result = try executor.executeProgram(continues.program, .{});
    defer continues_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), continues_result.status);
    try std.testing.expectEqualStrings("after\n", continues_result.stdout);

    var outside = try parseAndLower(std.testing.allocator, "return 4");
    defer outside.parsed.deinit();
    defer outside.program.deinit();
    var outside_result = try executor.executeProgram(outside.program, .{});
    defer outside_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 2), outside_result.status);
    try std.testing.expect(std.mem.indexOf(u8, outside_result.stderr, "not in a function") != null);
}

test "executor provides positional parameters to shell functions" {
    var lowered = try parseAndLower(std.testing.allocator, "show() { echo $1/$2/$#/$@/$*; }; show one two");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("one/two/2/one two/one two\n", result.stdout);

    var quoted = try parseAndLower(std.testing.allocator,
        \\show() { for x in "$@"; do echo "<$x>"; done; IFS=:; echo "<$*>"; }
        \\show "a b" c ""
    );
    defer quoted.parsed.deinit();
    defer quoted.program.deinit();
    var quoted_result = try executor.executeProgram(quoted.program, .{});
    defer quoted_result.deinit();
    try std.testing.expectEqualStrings("<a b>\n<c>\n<>\n<a b:c:>\n", quoted_result.stdout);

    var nested = try parseAndLower(std.testing.allocator, "inner() { echo $1/$#; }; outer() { inner nested; echo $1/$#; }; outer caller arg2");
    defer nested.parsed.deinit();
    defer nested.program.deinit();
    var nested_result = try executor.executeProgram(nested.program, .{});
    defer nested_result.deinit();
    try std.testing.expectEqualStrings("nested/1\ncaller/2\n", nested_result.stdout);
}

test "executor parses and executes POSIX shell functions" {
    var lowered = try parseAndLower(std.testing.allocator, "greet() { echo hi; }; greet");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hi\n", result.stdout);
    const stored = executor.functions.get("greet") orelse return error.MissingFunction;
    try std.testing.expect(stored.program.commands.len > 0 or stored.program.statements.len > 0);

    var redefine = try parseAndLower(std.testing.allocator, "greet() { echo one; }; greet() { echo two; }; greet");
    defer redefine.parsed.deinit();
    defer redefine.program.deinit();

    var redefine_result = try executor.executeProgram(redefine.program, .{});
    defer redefine_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), redefine_result.status);
    try std.testing.expectEqualStrings("two\n", redefine_result.stdout);
}

test "executor executes POSIX case statements" {
    var lowered = try parseAndLower(std.testing.allocator, "case foo in bar) echo no ;; f*) echo yes ;; *) echo fallback ;; esac");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("yes\n", result.stdout);

    var fallback_lowered = try parseAndLower(std.testing.allocator, "case z in a) echo a ;; ?) echo one ;; *) echo many ;; esac");
    defer fallback_lowered.parsed.deinit();
    defer fallback_lowered.program.deinit();

    var fallback = try executor.executeProgram(fallback_lowered.program, .{});
    defer fallback.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), fallback.status);
    try std.testing.expectEqualStrings("one\n", fallback.stdout);
}

test "executor executes POSIX for loops" {
    var lowered = try parseAndLower(std.testing.allocator, "for x in a b; do echo $x; done");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\nb\n", result.stdout);

    var split_lowered = try parseAndLower(std.testing.allocator, "WORDS='c d'; for x in $WORDS; do echo $x; done");
    defer split_lowered.parsed.deinit();
    defer split_lowered.program.deinit();

    var split_result = try executor.executeProgram(split_lowered.program, .{});
    defer split_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), split_result.status);
    try std.testing.expectEqualStrings("c\nd\n", split_result.stdout);
}

test "executor executes POSIX while and until loops" {
    var while_lowered = try parseAndLower(std.testing.allocator, "while false; do echo no; done");
    defer while_lowered.parsed.deinit();
    defer while_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var while_result = try executor.executeProgram(while_lowered.program, .{});
    defer while_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), while_result.status);
    try std.testing.expectEqualStrings("", while_result.stdout);

    var until_lowered = try parseAndLower(std.testing.allocator, "until true; do echo no; done");
    defer until_lowered.parsed.deinit();
    defer until_lowered.program.deinit();

    var until_result = try executor.executeProgram(until_lowered.program, .{});
    defer until_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), until_result.status);
    try std.testing.expectEqualStrings("", until_result.stdout);

    var break_lowered = try parseAndLower(std.testing.allocator, "while true; do echo once; break; done");
    defer break_lowered.parsed.deinit();
    defer break_lowered.program.deinit();

    var break_result = try executor.executeProgram(break_lowered.program, .{});
    defer break_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), break_result.status);
    try std.testing.expectEqualStrings("once\n", break_result.stdout);
}

test "executor feeds loop input redirection through read conditions" {
    const path = "rush-loop-read-input.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var lowered = try parseAndLower(std.testing.allocator, "printf 'a\\nb\\n' > rush-loop-read-input.tmp; n=0; while read line; do n=$((n + 1)); echo \"$n:$line\"; done < rush-loop-read-input.tmp; echo done=$n");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("1:a\n2:b\ndone=2\n", result.stdout);
}

test "executor executes POSIX if compound commands" {
    var true_lowered = try parseAndLower(std.testing.allocator, "if true; then echo yes; else echo no; fi");
    defer true_lowered.parsed.deinit();
    defer true_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var true_result = try executor.executeProgram(true_lowered.program, .{});
    defer true_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), true_result.status);
    try std.testing.expectEqualStrings("yes\n", true_result.stdout);

    var false_lowered = try parseAndLower(std.testing.allocator, "if false; then echo yes; else echo no; fi");
    defer false_lowered.parsed.deinit();
    defer false_lowered.program.deinit();

    var false_result = try executor.executeProgram(false_lowered.program, .{});
    defer false_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), false_result.status);
    try std.testing.expectEqualStrings("no\n", false_result.stdout);

    var elif_lowered = try parseAndLower(std.testing.allocator, "if false; then echo no; elif true; then echo elif; else echo else; fi");
    defer elif_lowered.parsed.deinit();
    defer elif_lowered.program.deinit();

    var elif_result = try executor.executeProgram(elif_lowered.program, .{});
    defer elif_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), elif_result.status);
    try std.testing.expectEqualStrings("elif\n", elif_result.stdout);
}

test "executor expands nested command substitutions and arithmetic inside them" {
    var nested = try parseAndLower(std.testing.allocator, "echo $(echo $(echo hi))");
    defer nested.parsed.deinit();
    defer nested.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var nested_result = try executor.executeProgram(nested.program, .{});
    defer nested_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), nested_result.status);
    try std.testing.expectEqualStrings("hi\n", nested_result.stdout);

    var arithmetic = try parseAndLower(std.testing.allocator, "echo $(echo $((1 + 2)))");
    defer arithmetic.parsed.deinit();
    defer arithmetic.program.deinit();

    var arithmetic_result = try executor.executeProgram(arithmetic.program, .{});
    defer arithmetic_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), arithmetic_result.status);
    try std.testing.expectEqualStrings("3\n", arithmetic_result.stdout);
}

test "executor expands command substitutions inside double quotes" {
    var lowered = try parseAndLower(std.testing.allocator, "set -- \"$(printf 'a b')\" c; echo $#:$1:$2");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("2:a b:c\n", result.stdout);
}

test "executor expands command substitutions recursively" {
    var lowered = try parseAndLower(std.testing.allocator, "echo before-$(echo hi)-after");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("before-hi-after\n", result.stdout);
}

test "executor stores Bash array runtime data" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    try executor.setArrayElement("arr", 0, "zero");
    try executor.setArrayElement("arr", 2, "two");
    try executor.setArrayElement("arr", 0, "ZERO");

    try std.testing.expectEqualStrings("ZERO", executor.getArrayElement("arr", 0).?);
    try std.testing.expectEqualStrings("", executor.getArrayElement("arr", 1).?);
    try std.testing.expectEqualStrings("two", executor.getArrayElement("arr", 2).?);
    try std.testing.expect(executor.getArrayElement("arr", 3) == null);

    executor.unsetArray("arr");
    try std.testing.expect(executor.getArrayElement("arr", 0) == null);
}

test "executor implements test and bracket builtins" {
    const path = "rush-test-builtin-file.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "x" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const Case = struct { script: []const u8, status: ExitStatus };
    const cases = [_]Case{
        .{ .script = "test nonempty", .status = 0 },
        .{ .script = "test ''", .status = 1 },
        .{ .script = "test a = a", .status = 0 },
        .{ .script = "test a != a", .status = 1 },
        .{ .script = "test 3 -gt 2", .status = 0 },
        .{ .script = "test 3 -le 2", .status = 1 },
        .{ .script = "test a '<' b", .status = 0 },
        .{ .script = "test b '>' a", .status = 0 },
        .{ .script = "test -e rush-test-builtin-file.tmp", .status = 0 },
        .{ .script = "test -f rush-test-builtin-file.tmp", .status = 0 },
        .{ .script = "test -s rush-test-builtin-file.tmp", .status = 0 },
        .{ .script = "test -r rush-test-builtin-file.tmp", .status = 0 },
        .{ .script = "test ! -e rush-test-missing.tmp", .status = 0 },
        .{ .script = "[ a = a ]", .status = 0 },
        .{ .script = "[ a = b ]", .status = 1 },
    };

    for (cases) |case| {
        var lowered = try parseAndLower(std.testing.allocator, case.script);
        defer lowered.parsed.deinit();
        defer lowered.program.deinit();

        var executor = Executor.init(std.testing.allocator);
        defer executor.deinit();

        var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
        defer result.deinit();
        try std.testing.expectEqual(case.status, result.status);
    }

    var invalid = try parseAndLower(std.testing.allocator, "test 1 -unknown 2");
    defer invalid.parsed.deinit();
    defer invalid.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var invalid_result = try executor.executeProgram(invalid.program, .{});
    defer invalid_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 2), invalid_result.status);
    try std.testing.expectEqualStrings("test: invalid expression\n", invalid_result.stderr);
}

test "executor implements trap builtin baseline" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var list = try parseAndLower(std.testing.allocator, "trap 'echo bye' EXIT; trap 'echo int' INT; trap");
    defer list.parsed.deinit();
    defer list.program.deinit();
    var list_result = try executor.executeProgram(list.program, .{});
    defer list_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), list_result.status);
    try std.testing.expectEqualStrings("trap -- 'echo bye' EXIT\ntrap -- 'echo int' INT\nbye\n", list_result.stdout);

    var cleared = try parseAndLower(std.testing.allocator, "trap - EXIT; trap");
    defer cleared.parsed.deinit();
    defer cleared.program.deinit();
    var cleared_result = try executor.executeProgram(cleared.program, .{});
    defer cleared_result.deinit();
    try std.testing.expectEqualStrings("trap -- 'echo int' INT\n", cleared_result.stdout);

    var signal = try parseAndLower(std.testing.allocator, "trap 'echo int' INT; /bin/kill -INT $$; echo after");
    defer signal.parsed.deinit();
    defer signal.program.deinit();
    var signal_executor = Executor.init(std.testing.allocator);
    defer signal_executor.deinit();
    var signal_result = try signal_executor.executeProgram(signal.program, .{ .io = std.testing.io, .allow_external = true });
    defer signal_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), signal_result.status);
    try std.testing.expectEqualStrings("int\nafter\n", signal_result.stdout);

    var zero = try parseAndLower(std.testing.allocator, "trap 'echo zero' 0; echo body");
    defer zero.parsed.deinit();
    defer zero.program.deinit();
    var zero_executor = Executor.init(std.testing.allocator);
    defer zero_executor.deinit();
    var zero_result = try zero_executor.executeProgram(zero.program, .{});
    defer zero_result.deinit();
    try std.testing.expectEqualStrings("body\nzero\n", zero_result.stdout);
}

test "executor implements getopts builtin" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var clustered = try parseAndLower(std.testing.allocator,
        \\while getopts ab opt -ab; do echo "$opt:$OPTIND:${OPTARG-unset}"; done
    );
    defer clustered.parsed.deinit();
    defer clustered.program.deinit();
    var clustered_result = try executor.executeProgram(clustered.program, .{});
    defer clustered_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), clustered_result.status);
    try std.testing.expectEqualStrings("a:1:unset\nb:2:unset\n", clustered_result.stdout);

    var with_arg = try parseAndLower(std.testing.allocator,
        \\OPTIND=1; while getopts a:b opt -a value; do echo "$opt/$OPTARG/$OPTIND"; done
    );
    defer with_arg.parsed.deinit();
    defer with_arg.program.deinit();
    var with_arg_result = try executor.executeProgram(with_arg.program, .{});
    defer with_arg_result.deinit();
    try std.testing.expectEqualStrings("a/value/3\n", with_arg_result.stdout);

    var silent = try parseAndLower(std.testing.allocator,
        \\OPTIND=1; getopts :a: opt -a; echo "$opt/$OPTARG/$OPTIND"
    );
    defer silent.parsed.deinit();
    defer silent.program.deinit();
    var silent_result = try executor.executeProgram(silent.program, .{});
    defer silent_result.deinit();
    try std.testing.expectEqualStrings(":/a/2\n", silent_result.stdout);
}

test "executor implements unset and env builtins" {
    var lowered = try parseAndLower(std.testing.allocator, "export A=one B=two; unset A; env");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "B=two\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "A=one\n") == null);
    try std.testing.expect(executor.getEnv("A") == null);
    try std.testing.expectEqualStrings("two", executor.getEnv("B").?);

    var clean = try parseAndLower(std.testing.allocator, "env -i ONLY=value env");
    defer clean.parsed.deinit();
    defer clean.program.deinit();
    var clean_result = try executor.executeProgram(clean.program, .{});
    defer clean_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), clean_result.status);
    try std.testing.expectEqualStrings("ONLY=value\n", clean_result.stdout);

    var command_env = try parseAndLower(std.testing.allocator, "OUTER=keep; env INNER=value env; echo ${INNER:-unset}/$OUTER");
    defer command_env.parsed.deinit();
    defer command_env.program.deinit();
    var command_env_result = try executor.executeProgram(command_env.program, .{});
    defer command_env_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), command_env_result.status);
    try std.testing.expect(std.mem.indexOf(u8, command_env_result.stdout, "INNER=value\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, command_env_result.stdout, "unset/keep\n"));

    var local_env = try parseAndLower(std.testing.allocator, "LOCAL=hidden; env");
    defer local_env.parsed.deinit();
    defer local_env.program.deinit();
    var local_env_result = try executor.executeProgram(local_env.program, .{});
    defer local_env_result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, local_env_result.stdout, "LOCAL=hidden\n") == null);

    var allexport = try parseAndLower(std.testing.allocator, "set -a; AUTO=ok; set +a; LOCAL=hidden; env");
    defer allexport.parsed.deinit();
    defer allexport.program.deinit();
    var allexport_result = try executor.executeProgram(allexport.program, .{});
    defer allexport_result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, allexport_result.stdout, "AUTO=ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, allexport_result.stdout, "LOCAL=hidden\n") == null);
}

test "executor implements global positional parameters via set --" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\set -- "a b" c ""
        \\echo "$1/$2/$#"
        \\for x in "$@"; do echo "<$x>"; done
        \\IFS=:; echo "<$*>"
        \\shift; echo "$1/$#"
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a b/c/3\n<a b>\n<c>\n<>\n<a b:c:>\nc/2\n", result.stdout);
}

test "executor persists assignment prefixes for POSIX special builtins" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\FOO=regular echo ok; echo ${FOO:-unset}; FOO=special export BAR=value; echo $FOO/$BAR
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("ok\nunset\nspecial/value\n", result.stdout);
    try std.testing.expectEqualStrings("special", executor.getEnv("FOO").?);
}

test "executor implements readonly shift umask wait and times builtins" {
    var readonly_lowered = try parseAndLower(std.testing.allocator, "readonly RO=value; unset RO; echo $RO; readonly");
    defer readonly_lowered.parsed.deinit();
    defer readonly_lowered.program.deinit();
    var readonly_executor = Executor.init(std.testing.allocator);
    defer readonly_executor.deinit();
    var readonly_result = try readonly_executor.executeProgram(readonly_lowered.program, .{});
    defer readonly_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 2), readonly_result.status);
    try std.testing.expectEqualStrings("", readonly_result.stdout);
    try std.testing.expectEqualStrings("unset: readonly variable\n", readonly_result.stderr);
    try std.testing.expectEqualStrings("value", readonly_executor.getEnv("RO").?);

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var shift_lowered = try parseAndLower(std.testing.allocator, "f() { shift; echo $1/$#; }; f a b c");
    defer shift_lowered.parsed.deinit();
    defer shift_lowered.program.deinit();
    var shift_result = try executor.executeProgram(shift_lowered.program, .{});
    defer shift_result.deinit();
    try std.testing.expectEqualStrings("b/2\n", shift_result.stdout);

    var wait_times_lowered = try parseAndLower(std.testing.allocator, "wait; times");
    defer wait_times_lowered.parsed.deinit();
    defer wait_times_lowered.program.deinit();
    var wait_times_result = try executor.executeProgram(wait_times_lowered.program, .{});
    defer wait_times_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), wait_times_result.status);
    try expectTimesOutputShape(wait_times_result.stdout);

    var umask_lowered = try parseAndLower(std.testing.allocator, "umask 022; umask");
    defer umask_lowered.parsed.deinit();
    defer umask_lowered.program.deinit();
    var umask_result = try executor.executeProgram(umask_lowered.program, .{});
    defer umask_result.deinit();
    try std.testing.expectEqualStrings("0022\n", umask_result.stdout);
}

test "executor implements command eval exec and exit builtins" {
    var eval_lowered = try parseAndLower(std.testing.allocator, "eval echo eval-ok");
    defer eval_lowered.parsed.deinit();
    defer eval_lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var eval_result = try executor.executeProgram(eval_lowered.program, .{});
    defer eval_result.deinit();
    try std.testing.expectEqualStrings("eval-ok\n", eval_result.stdout);

    var command_executor = Executor.init(std.testing.allocator);
    defer command_executor.deinit();
    var command_lowered = try parseAndLower(std.testing.allocator, "echo() { printf 'function\\n'; }; command echo builtin; command -v echo; command -V echo");
    defer command_lowered.parsed.deinit();
    defer command_lowered.program.deinit();
    var command_result = try command_executor.executeProgram(command_lowered.program, .{});
    defer command_result.deinit();
    try std.testing.expectEqualStrings("builtin\necho\necho is a shell builtin\n", command_result.stdout);

    var command_path = try parseAndLower(std.testing.allocator, "PATH=/nope; command -p sh -c 'echo path-ok'; printf '%s\n' \"$PATH\"");
    defer command_path.parsed.deinit();
    defer command_path.program.deinit();
    var command_path_result = try command_executor.executeProgram(command_path.program, .{ .io = std.testing.io, .allow_external = true });
    defer command_path_result.deinit();
    try std.testing.expectEqualStrings("path-ok\n/nope\n", command_path_result.stdout);

    var exit_lowered = try parseAndLower(std.testing.allocator, "echo before; exit 7; echo after");
    defer exit_lowered.parsed.deinit();
    defer exit_lowered.program.deinit();
    var exit_result = try executor.executeProgram(exit_lowered.program, .{});
    defer exit_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 7), exit_result.status);
    try std.testing.expectEqualStrings("before\n", exit_result.stdout);

    var exec_lowered = try parseAndLower(std.testing.allocator, "exec echo exec-ok; echo after");
    defer exec_lowered.parsed.deinit();
    defer exec_lowered.program.deinit();
    var exec_result = try executor.executeProgram(exec_lowered.program, .{});
    defer exec_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), exec_result.status);
    try std.testing.expectEqualStrings("exec-ok\n", exec_result.stdout);
}

test "executor implements read and printf builtins" {
    var printf_lowered = try parseAndLower(std.testing.allocator, "printf 'hello %s %d\\n' world 42");
    defer printf_lowered.parsed.deinit();
    defer printf_lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var printf_result = try executor.executeProgram(printf_lowered.program, .{});
    defer printf_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), printf_result.status);
    try std.testing.expectEqualStrings("hello world 42\n", printf_result.stdout);

    var repeat_lowered = try parseAndLower(std.testing.allocator, "printf '%s:%s\\n' a b c d");
    defer repeat_lowered.parsed.deinit();
    defer repeat_lowered.program.deinit();
    var repeat_result = try executor.executeProgram(repeat_lowered.program, .{});
    defer repeat_result.deinit();
    try std.testing.expectEqualStrings("a:b\nc:d\n", repeat_result.stdout);

    var width_lowered = try parseAndLower(std.testing.allocator, "printf '[%5s][%-5s][%.3s][%04d][%o][%x][%X]' a b abcdef 7 10 255 255");
    defer width_lowered.parsed.deinit();
    defer width_lowered.program.deinit();
    var width_result = try executor.executeProgram(width_lowered.program, .{});
    defer width_result.deinit();
    try std.testing.expectEqualStrings("[    a][b    ][abc][0007][12][ff][FF]", width_result.stdout);

    var escaped_lowered = try parseAndLower(std.testing.allocator, "printf '%b' 'x\\ny'");
    defer escaped_lowered.parsed.deinit();
    defer escaped_lowered.program.deinit();
    var escaped_result = try executor.executeProgram(escaped_lowered.program, .{});
    defer escaped_result.deinit();
    try std.testing.expectEqualStrings("x\ny", escaped_result.stdout);

    var octal_escape = try parseAndLower(std.testing.allocator, "printf 'A\\101'; printf '%b' 'B\\0101'; printf '%b' 'C\\cD'");
    defer octal_escape.parsed.deinit();
    defer octal_escape.program.deinit();
    var octal_escape_result = try executor.executeProgram(octal_escape.program, .{});
    defer octal_escape_result.deinit();
    try std.testing.expectEqualStrings("AABAC", octal_escape_result.stdout);

    var format_octal_escape = try parseAndLower(std.testing.allocator, "printf '\\0337\\0338'");
    defer format_octal_escape.parsed.deinit();
    defer format_octal_escape.program.deinit();
    var format_octal_escape_result = try executor.executeProgram(format_octal_escape.program, .{});
    defer format_octal_escape_result.deinit();
    try std.testing.expectEqualStrings("\x1b\x37\x1b\x38", format_octal_escape_result.stdout);

    var unknown_escape = try parseAndLower(std.testing.allocator, "printf 'a\\ b'");
    defer unknown_escape.parsed.deinit();
    defer unknown_escape.program.deinit();
    var unknown_escape_result = try executor.executeProgram(unknown_escape.program, .{});
    defer unknown_escape_result.deinit();
    try std.testing.expectEqualStrings("a\\ b", unknown_escape_result.stdout);

    var read_lowered = try parseAndLower(std.testing.allocator,
        \\read first rest <<EOF; printf '%s/%s\n' "$first" "$rest"
        \\one two three
        \\EOF
    );
    defer read_lowered.parsed.deinit();
    defer read_lowered.program.deinit();
    var read_result = try executor.executeProgram(read_lowered.program, .{});
    defer read_result.deinit();
    try std.testing.expectEqualStrings("one/two three\n", read_result.stdout);

    var backslash_lowered = try parseAndLower(std.testing.allocator,
        \\read cooked <<'EOF'; read -r raw <<'EOF2'; printf '%s/%s\n' "$cooked" "$raw"
        \\a\ b
        \\EOF
        \\a\ b
        \\EOF2
    );
    defer backslash_lowered.parsed.deinit();
    defer backslash_lowered.program.deinit();
    var backslash_result = try executor.executeProgram(backslash_lowered.program, .{});
    defer backslash_result.deinit();
    try std.testing.expectEqualStrings("a b/a\\ b\n", backslash_result.stdout);

    var ifs_lowered = try parseAndLower(std.testing.allocator,
        \\IFS=: read a b c <<EOF; printf '%s/%s/%s\n' "$a" "$b" "$c"
        \\one::three
        \\EOF
    );
    defer ifs_lowered.parsed.deinit();
    defer ifs_lowered.program.deinit();
    var ifs_result = try executor.executeProgram(ifs_lowered.program, .{});
    defer ifs_result.deinit();
    try std.testing.expectEqualStrings("one//three\n", ifs_result.stdout);

    var unsupported = try parseAndLower(std.testing.allocator, "read -z var");
    defer unsupported.parsed.deinit();
    defer unsupported.program.deinit();
    var unsupported_result = try executor.executeProgram(unsupported.program, .{});
    defer unsupported_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 2), unsupported_result.status);
    try std.testing.expectEqualStrings("read: unsupported option\n", unsupported_result.stderr);
}

test "executor implements pwd cd and export builtins" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var pwd_lowered = try parseAndLower(std.testing.allocator, "pwd");
    defer pwd_lowered.parsed.deinit();
    defer pwd_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var pwd_result = try executor.executeProgram(pwd_lowered.program, .{ .io = std.testing.io });
    defer pwd_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), pwd_result.status);
    try std.testing.expect(std.mem.indexOf(u8, pwd_result.stdout, original_cwd) != null);

    var cd_lowered = try parseAndLower(std.testing.allocator, "cd /tmp; pwd; echo $PWD");
    defer cd_lowered.parsed.deinit();
    defer cd_lowered.program.deinit();
    var cd_result = try executor.executeProgram(cd_lowered.program, .{ .io = std.testing.io });
    defer cd_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), cd_result.status);
    try std.testing.expectEqualStrings("/tmp\n/tmp\n", cd_result.stdout);

    var export_lowered = try parseAndLower(std.testing.allocator, "export RUSH_TEST_EXPORT=ok; echo $RUSH_TEST_EXPORT");
    defer export_lowered.parsed.deinit();
    defer export_lowered.program.deinit();
    var export_result = try executor.executeProgram(export_lowered.program, .{});
    defer export_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), export_result.status);
    try std.testing.expectEqualStrings("ok\n", export_result.stdout);
}

test "executor expands arithmetic expressions in argv" {
    var assign = try parseAndLower(std.testing.allocator, "echo $((x = 3)); echo $x; echo $((x += 4)); echo $x; echo $((x *= 2)); echo $x");
    defer assign.parsed.deinit();
    defer assign.program.deinit();

    var assign_executor = Executor.init(std.testing.allocator);
    defer assign_executor.deinit();
    var assign_result = try assign_executor.executeProgram(assign.program, .{});
    defer assign_result.deinit();
    try std.testing.expectEqualStrings("3\n3\n7\n7\n14\n14\n", assign_result.stdout);

    var vars = try parseAndLower(std.testing.allocator, "x=2; y=5; echo $((x + y * 2)); echo $((unset_name + x))");
    defer vars.parsed.deinit();
    defer vars.program.deinit();

    var vars_executor = Executor.init(std.testing.allocator);
    defer vars_executor.deinit();
    var vars_result = try vars_executor.executeProgram(vars.program, .{});
    defer vars_result.deinit();
    try std.testing.expectEqualStrings("12\n2\n", vars_result.stdout);

    var lowered = try parseAndLower(std.testing.allocator, "echo $((1 + 2 * 3))");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "executor expands pathname patterns in argv" {
    const a = "rush-exec-glob-a.tmp";
    const b = "rush-exec-glob-b.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, b) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo rush-exec-glob-?.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush-exec-glob-a.tmp rush-exec-glob-b.tmp\n", result.stdout);
}

test "executor field-splits unquoted parameter expansion in argv" {
    var lowered = try parseAndLower(std.testing.allocator, "WORDS='one two'; echo $WORDS");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("one two\n", result.stdout);
}

test "executor expands core POSIX special parameters" {
    var status_lowered = try parseAndLower(std.testing.allocator, "false; echo $?; true; echo $?");
    defer status_lowered.parsed.deinit();
    defer status_lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var status_result = try executor.executeProgram(status_lowered.program, .{});
    defer status_result.deinit();
    try std.testing.expectEqualStrings("1\n0\n", status_result.stdout);

    var names_lowered = try parseAndLower(std.testing.allocator, "echo $0; echo ${!}");
    defer names_lowered.parsed.deinit();
    defer names_lowered.program.deinit();
    executor.arg_zero = "rush-test";
    var names_result = try executor.executeProgram(names_lowered.program, .{});
    defer names_result.deinit();
    try std.testing.expectEqualStrings("rush-test\n\n", names_result.stdout);

    var pid_lowered = try parseAndLower(std.testing.allocator, "test -n $$");
    defer pid_lowered.parsed.deinit();
    defer pid_lowered.program.deinit();
    var pid_result = try executor.executeProgram(pid_lowered.program, .{});
    defer pid_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), pid_result.status);
}

test "executor supports POSIX parameter expansion assignment" {
    var lowered = try parseAndLower(std.testing.allocator, "echo ${ASSIGNED:=value}; echo $ASSIGNED; echo ${ASSIGNED:+set}");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("value\nvalue\nset\n", result.stdout);
}

test "executor expands parameters from shell environment" {
    var lowered = try parseAndLower(std.testing.allocator, "FOO=bar; echo $FOO");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("bar\n", result.stdout);
}

test "executor expands redirection targets from shell environment" {
    const path = "rush-test-expanded-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "OUT=rush-test-expanded-redirection.tmp; echo hi > $OUT");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("hi\n", contents);
}

test "executor applies command-prefix assignments temporarily" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\FOO=outer; FOO=inner echo "$FOO"; echo "$FOO"
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("outer\nouter\n", result.stdout);
    try std.testing.expectEqualStrings("outer", executor.getEnv("FOO").?);
}

test "executor expands assignment prefixes sequentially" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\HOME=/tmp/rush-home VALUE=~ LIST=~/bin:~ :
        \\echo "$VALUE"
        \\echo "$LIST"
        \\A=one B=$A :
        \\echo "$A/$B"
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("/tmp/rush-home\n/tmp/rush-home/bin:/tmp/rush-home\none/one\n", result.stdout);
}

test "executor passes shell environment and command assignments to external commands" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\export FOO=outer; FOO=inner /usr/bin/env | /usr/bin/grep '^FOO='
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("FOO=inner\n", result.stdout);
    try std.testing.expectEqualStrings("outer", executor.getEnv("FOO").?);
}

test "executor applies assignment-only commands to shell environment" {
    var lowered = try parseAndLower(std.testing.allocator, "FOO=bar");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("bar", executor.getEnv("FOO").?);
}

test "executor reports command not found without external execution" {
    var lowered = try parseAndLower(std.testing.allocator, "definitely-not-a-rush-builtin");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("definitely-not-a-rush-builtin: command not found\n", result.stderr);
}

test "executor short-circuits AND and OR lists" {
    var and_lowered = try parseAndLower(std.testing.allocator, "false && echo nope");
    defer and_lowered.parsed.deinit();
    defer and_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var and_result = try executor.executeProgram(and_lowered.program, .{});
    defer and_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), and_result.status);
    try std.testing.expectEqualStrings("", and_result.stdout);

    var or_lowered = try parseAndLower(std.testing.allocator, "false || echo yes");
    defer or_lowered.parsed.deinit();
    defer or_lowered.program.deinit();
    var or_result = try executor.executeProgram(or_lowered.program, .{});
    defer or_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), or_result.status);
    try std.testing.expectEqualStrings("yes\n", or_result.stdout);

    var skip_or_lowered = try parseAndLower(std.testing.allocator, "true || echo nope");
    defer skip_or_lowered.parsed.deinit();
    defer skip_or_lowered.program.deinit();
    var skip_or_result = try executor.executeProgram(skip_or_lowered.program, .{});
    defer skip_or_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), skip_or_result.status);
    try std.testing.expectEqualStrings("", skip_or_result.stdout);
}

test "executor pipes stdout into stdin-consuming builtins" {
    var lowered = try parseAndLower(std.testing.allocator, "echo hello | cat");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
}

test "executor reads cat file operands" {
    const first_path = "rush-cat-first.tmp";
    const second_path = "rush-cat-second.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = first_path, .data = "one\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = second_path, .data = "two\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, first_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, second_path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo stdin | cat rush-cat-first.tmp - rush-cat-second.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("one\nstdin\ntwo\n", result.stdout);
}

test "executor redirects stdin from files for builtins" {
    const path = "rush-test-stdin-redirection.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "from file" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "cat < rush-test-stdin-redirection.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("from file", result.stdout);
}

test "executor redirects stdout to files" {
    const path = "rush-test-redirection-output.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo file > rush-test-redirection-output.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("file\n", contents);
}

test "executor redirects stderr to files" {
    const path = "rush-test-stderr-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "definitely-not-a-rush-builtin 2> rush-test-stderr-redirection.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.stderr);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("definitely-not-a-rush-builtin: command not found\n", contents);
}

test "executor appends stdout redirections" {
    const path = "rush-test-redirection-append.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo one >> rush-test-redirection-append.tmp; echo two >> rush-test-redirection-append.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}

test "executor appends stderr redirections and duplicates descriptors" {
    const path = "rush-test-stderr-append.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var append_lowered = try parseAndLower(std.testing.allocator, "missing-one 2>> rush-test-stderr-append.tmp; missing-two 2>> rush-test-stderr-append.tmp");
    defer append_lowered.parsed.deinit();
    defer append_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var append_result = try executor.executeProgram(append_lowered.program, .{ .io = std.testing.io });
    defer append_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), append_result.status);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("missing-one: command not found\nmissing-two: command not found\n", contents);

    var dup_lowered = try parseAndLower(std.testing.allocator, "missing-three 2>&1");
    defer dup_lowered.parsed.deinit();
    defer dup_lowered.program.deinit();
    var dup_result = try executor.executeProgram(dup_lowered.program, .{});
    defer dup_result.deinit();
    try std.testing.expectEqualStrings("missing-three: command not found\n", dup_result.stdout);
    try std.testing.expectEqualStrings("", dup_result.stderr);
}

test "executor applies real redirections to spawned external commands" {
    const stdout_path = "rush-external-stdout-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, stdout_path) catch {};
    var stdout_lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf external > rush-external-stdout-redirection.tmp");
    defer stdout_lowered.parsed.deinit();
    defer stdout_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var stdout_result = try executor.executeProgram(stdout_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer stdout_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), stdout_result.status);
    try std.testing.expectEqualStrings("", stdout_result.stdout);
    const stdout_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stdout_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(stdout_contents);
    try std.testing.expectEqualStrings("external", stdout_contents);

    const append_path = "rush-external-append-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, append_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = append_path, .data = "one\n" });
    var append_lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf two >> rush-external-append-redirection.tmp");
    defer append_lowered.parsed.deinit();
    defer append_lowered.program.deinit();
    var append_result = try executor.executeProgram(append_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer append_result.deinit();
    const append_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, append_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(append_contents);
    try std.testing.expectEqualStrings("one\ntwo", append_contents);

    const stderr_path = "rush-external-stderr-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, stderr_path) catch {};
    var stderr_lowered = try parseAndLower(std.testing.allocator, "/bin/sh -c 'echo err >&2' 2> rush-external-stderr-redirection.tmp");
    defer stderr_lowered.parsed.deinit();
    defer stderr_lowered.program.deinit();
    var stderr_result = try executor.executeProgram(stderr_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer stderr_result.deinit();
    try std.testing.expectEqualStrings("", stderr_result.stderr);
    const stderr_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(stderr_contents);
    try std.testing.expectEqualStrings("err\n", stderr_contents);

    const stdin_path = "rush-external-stdin-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, stdin_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stdin_path, .data = "from-file" });
    var stdin_lowered = try parseAndLower(std.testing.allocator, "/bin/cat < rush-external-stdin-redirection.tmp");
    defer stdin_lowered.parsed.deinit();
    defer stdin_lowered.program.deinit();
    var stdin_result = try executor.executeProgram(stdin_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer stdin_result.deinit();
    try std.testing.expectEqualStrings("from-file", stdin_result.stdout);
}

test "executor implements set shell option baseline" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var show_lowered = try parseAndLower(std.testing.allocator, "set -o");
    defer show_lowered.parsed.deinit();
    defer show_lowered.program.deinit();
    var show = try executor.executeProgram(show_lowered.program, .{});
    defer show.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), show.status);
    try std.testing.expectEqualStrings("allexport\toff\nerrexit\toff\nnoclobber\toff\nnoglob\toff\nnounset\toff\npipefail\toff\nverbose\toff\nxtrace\toff\n", show.stdout);

    var enable_lowered = try parseAndLower(std.testing.allocator, "set -o pipefail; false | true");
    defer enable_lowered.parsed.deinit();
    defer enable_lowered.program.deinit();
    var enabled = try executor.executeProgram(enable_lowered.program, .{});
    defer enabled.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), enabled.status);
    try std.testing.expect(executor.shell_options.pipefail);

    var reusable_lowered = try parseAndLower(std.testing.allocator, "set +o");
    defer reusable_lowered.parsed.deinit();
    defer reusable_lowered.program.deinit();
    var reusable = try executor.executeProgram(reusable_lowered.program, .{});
    defer reusable.deinit();
    try std.testing.expectEqualStrings("set +o allexport\nset +o errexit\nset +o noclobber\nset +o noglob\nset +o nounset\nset -o pipefail\nset +o verbose\nset +o xtrace\n", reusable.stdout);

    var disable_lowered = try parseAndLower(std.testing.allocator, "set +o pipefail; false | true");
    defer disable_lowered.parsed.deinit();
    defer disable_lowered.program.deinit();
    var disabled = try executor.executeProgram(disable_lowered.program, .{});
    defer disabled.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), disabled.status);
    try std.testing.expect(!executor.shell_options.pipefail);

    const path = "rush-noglob-a.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    var noglob_lowered = try parseAndLower(std.testing.allocator, "set -f; echo rush-noglob-?.tmp; set +f; echo rush-noglob-?.tmp");
    defer noglob_lowered.parsed.deinit();
    defer noglob_lowered.program.deinit();
    var noglob = try executor.executeProgram(noglob_lowered.program, .{ .io = std.testing.io });
    defer noglob.deinit();
    try std.testing.expectEqualStrings("rush-noglob-?.tmp\nrush-noglob-a.tmp\n", noglob.stdout);
    try std.testing.expect(!executor.shell_options.noglob);

    const clobber_path = "rush-noclobber.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, clobber_path) catch {};
    var noclobber_lowered = try parseAndLower(std.testing.allocator, "echo old > rush-noclobber.tmp; set -C; echo new > rush-noclobber.tmp; echo status=$?; echo forced >| rush-noclobber.tmp; /bin/cat rush-noclobber.tmp");
    defer noclobber_lowered.parsed.deinit();
    defer noclobber_lowered.program.deinit();
    var noclobber = try executor.executeProgram(noclobber_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer noclobber.deinit();
    try std.testing.expectEqualStrings("status=1\nforced\n", noclobber.stdout);
    try std.testing.expect(executor.shell_options.noclobber);

    var nounset_lowered = try parseAndLower(std.testing.allocator, "set -u; echo $RUSH_UNSET_FOR_TEST; echo after");
    defer nounset_lowered.parsed.deinit();
    defer nounset_lowered.program.deinit();
    var nounset = try executor.executeProgram(nounset_lowered.program, .{});
    defer nounset.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), nounset.status);
    try std.testing.expectEqualStrings("", nounset.stdout);
    try std.testing.expect(std.mem.indexOf(u8, nounset.stderr, "unset parameter") != null);
    try std.testing.expect(executor.shell_options.nounset);

    var nounset_disabled_executor = Executor.init(std.testing.allocator);
    defer nounset_disabled_executor.deinit();
    nounset_disabled_executor.shell_options.nounset = true;
    var disable_nounset = try parseAndLower(std.testing.allocator, "set +u; echo $RUSH_UNSET_FOR_TEST; echo after");
    defer disable_nounset.parsed.deinit();
    defer disable_nounset.program.deinit();
    var nounset_disabled = try nounset_disabled_executor.executeProgram(disable_nounset.program, .{});
    defer nounset_disabled.deinit();
    try std.testing.expectEqualStrings("\nafter\n", nounset_disabled.stdout);
    try std.testing.expect(!nounset_disabled_executor.shell_options.nounset);

    var errexit_executor = Executor.init(std.testing.allocator);
    defer errexit_executor.deinit();
    var errexit_lowered = try parseAndLower(std.testing.allocator, "set -e; echo before; false; echo after");
    defer errexit_lowered.parsed.deinit();
    defer errexit_lowered.program.deinit();
    var errexit = try errexit_executor.executeProgram(errexit_lowered.program, .{});
    defer errexit.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), errexit.status);
    try std.testing.expectEqualStrings("before\n", errexit.stdout);

    var condition_executor = Executor.init(std.testing.allocator);
    defer condition_executor.deinit();
    var condition_lowered = try parseAndLower(std.testing.allocator, "set -e; if false; then echo bad; else echo ok; fi; echo after");
    defer condition_lowered.parsed.deinit();
    defer condition_lowered.program.deinit();
    var condition = try condition_executor.executeProgram(condition_lowered.program, .{});
    defer condition.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), condition.status);
    try std.testing.expectEqualStrings("ok\nafter\n", condition.stdout);

    var and_or_suppressed_executor = Executor.init(std.testing.allocator);
    defer and_or_suppressed_executor.deinit();
    var and_or_suppressed_lowered = try parseAndLower(std.testing.allocator, "set -e; false && echo bad; false || echo ok; ! false; echo after");
    defer and_or_suppressed_lowered.parsed.deinit();
    defer and_or_suppressed_lowered.program.deinit();
    var and_or_suppressed = try and_or_suppressed_executor.executeProgram(and_or_suppressed_lowered.program, .{});
    defer and_or_suppressed.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), and_or_suppressed.status);
    try std.testing.expectEqualStrings("ok\nafter\n", and_or_suppressed.stdout);

    var and_or_last_executor = Executor.init(std.testing.allocator);
    defer and_or_last_executor.deinit();
    var and_or_last_lowered = try parseAndLower(std.testing.allocator, "set -e; true && false; echo after");
    defer and_or_last_lowered.parsed.deinit();
    defer and_or_last_lowered.program.deinit();
    var and_or_last = try and_or_last_executor.executeProgram(and_or_last_lowered.program, .{});
    defer and_or_last.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), and_or_last.status);
    try std.testing.expectEqualStrings("", and_or_last.stdout);

    var trace_executor = Executor.init(std.testing.allocator);
    defer trace_executor.deinit();
    var trace_lowered = try parseAndLower(std.testing.allocator, "set -x; echo hi; set +x; echo quiet");
    defer trace_lowered.parsed.deinit();
    defer trace_lowered.program.deinit();
    var trace = try trace_executor.executeProgram(trace_lowered.program, .{});
    defer trace.deinit();
    try std.testing.expectEqualStrings("hi\nquiet\n", trace.stdout);
    try std.testing.expect(std.mem.indexOf(u8, trace.stderr, "+ echo hi\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace.stderr, "+ echo quiet\n") == null);

    var verbose_executor = Executor.init(std.testing.allocator);
    defer verbose_executor.deinit();
    var verbose = try verbose_executor.executeScriptSlice("set -v\necho verbose\n", .{});
    defer verbose.deinit();
    try std.testing.expectEqualStrings("verbose\n", verbose.stdout);
    try std.testing.expect(std.mem.indexOf(u8, verbose.stderr, "echo verbose") != null);
}

test "executor exits on special builtin redirection errors" {
    const path = "rush-special-redirection-error.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo old > rush-special-redirection-error.tmp; set -C; : > rush-special-redirection-error.tmp; echo after");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "cannot overwrite existing file") != null);
}

test "executor reports parameter error expansion diagnostics" {
    var lowered = try parseAndLower(std.testing.allocator, "MSG=why; echo ${RUSH_UNSET_FOR_TEST:?bad-${MSG}}; echo after");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("RUSH_UNSET_FOR_TEST: bad-why\n", result.stderr);
}

test "executor runs builtin async jobs as waitable children" {
    const path = "rush-builtin-async-job.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var lowered = try parseAndLower(std.testing.allocator, "echo bg > rush-builtin-async-job.tmp & wait $!; cat < rush-builtin-async-job.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("bg\n", result.stdout);
}

test "executor runs compound async jobs as waitable children" {
    const path = "rush-compound-async-job.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var lowered = try parseAndLower(std.testing.allocator, "{ echo compound > rush-compound-async-job.tmp; } & wait $!; cat < rush-compound-async-job.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("compound\n", result.stdout);
}

test "executor backgrounds current and selected tracked jobs" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sleep 0 & bg; /bin/sleep 0 & bg %2; wait");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("[1] /bin/sleep 0 &\n[2] /bin/sleep 0 &\n", result.stdout);
}

test "executor foregrounds current and selected background jobs" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sleep 0 & fg; /bin/sleep 0 & fg %2");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("/bin/sleep 0\n/bin/sleep 0\n", result.stdout);
}

test "executor filters and formats jobs builtin output" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sleep 1 & jobs -p %1; jobs -l 1; wait $!; jobs %1");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    const first_newline = std.mem.indexOfScalar(u8, result.stdout, '\n') orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_newline > 0);
    for (result.stdout[0..first_newline]) |byte| try std.testing.expect(std.ascii.isDigit(byte));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "[1]+ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, " Running /bin/sleep 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "[1]+ Done(0) /bin/sleep 1\n") != null);
}

test "executor reports tracked background jobs" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sleep 1 & jobs; wait $!; jobs");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "[1]+ Running /bin/sleep 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "[1]+ Done(0) /bin/sleep 1\n") != null);
}

test "executor drains interactive stopped and done job notifications once" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    try executor.background_jobs.append(std.testing.allocator, .{
        .id = 1,
        .pid = 999_999,
        .command = try std.testing.allocator.dupe(u8, "sleep 1"),
        .child = undefined,
        .state = .stopped,
    });

    try executor.queueJobNotification(&executor.background_jobs.items[0]);
    const stopped = try executor.drainJobNotifications();
    defer std.testing.allocator.free(stopped);
    try std.testing.expectEqualStrings("[1] Stopped sleep 1\n", stopped);

    const empty = try executor.drainJobNotifications();
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    executor.background_jobs.items[0].state = .done;
    try executor.queueJobNotification(&executor.background_jobs.items[0]);
    const done = try executor.drainJobNotifications();
    defer std.testing.allocator.free(done);
    try std.testing.expectEqualStrings("[1] Done sleep 1\n", done);
}

test "executor restores saved pty terminal modes before continuing stopped job" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = close(master);
    defer _ = close(slave);

    const original_stdin = dup(std.Io.File.stdin().handle);
    if (original_stdin < 0) return error.SkipZigTest;
    defer _ = close(original_stdin);
    if (dup2(slave, std.Io.File.stdin().handle) < 0) return error.SkipZigTest;
    defer _ = dup2(original_stdin, std.Io.File.stdin().handle);

    const saved = try std.posix.tcgetattr(std.Io.File.stdin().handle);
    var changed = saved;
    if (@hasField(@TypeOf(changed.lflag), "ECHO")) {
        changed.lflag.ECHO = !changed.lflag.ECHO;
    } else {
        changed.lflag = ~changed.lflag;
    }
    try std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, changed);
    defer std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, saved) catch {};

    const child_pid = fork();
    if (child_pid < 0) return error.SkipZigTest;
    if (child_pid == 0) {
        while (true) _ = pause();
    }
    defer {
        std.posix.kill(child_pid, .TERM) catch {};
        _ = std.c.waitpid(child_pid, null, 0);
    }
    try std.posix.kill(child_pid, .STOP);
    var status: c_int = 0;
    _ = std.c.waitpid(child_pid, &status, @intCast(std.posix.W.UNTRACED));

    var job: BackgroundJob = .{
        .id = 1,
        .pid = child_pid,
        .command = "sleep 1",
        .child = undefined,
        .state = .stopped,
        .saved_termios = saved,
    };
    try continueStoppedJob(&job);

    const restored = try std.posix.tcgetattr(std.Io.File.stdin().handle);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&saved), std.mem.asBytes(&restored));
    try std.testing.expectEqual(JobState.running, job.state);
}

test "executor waits for background pid operands" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sh -c 'exit 7' & wait $!; echo status=$?");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("status=7\n", result.stdout);
}

test "executor starts external commands asynchronously" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sleep 0 & echo pid=$!; echo done");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "pid="));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "\ndone\n"));
    try std.testing.expect(result.stdout.len > "pid=\ndone\n".len);
}

test "executor applies POSIX pipeline negation" {
    var false_negated = try parseAndLower(std.testing.allocator, "! false");
    defer false_negated.parsed.deinit();
    defer false_negated.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var false_result = try executor.executeProgram(false_negated.program, .{});
    defer false_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), false_result.status);

    var true_negated = try parseAndLower(std.testing.allocator, "! true");
    defer true_negated.parsed.deinit();
    defer true_negated.program.deinit();
    var true_result = try executor.executeProgram(true_negated.program, .{});
    defer true_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), true_result.status);

    var pipeline_negated = try parseAndLower(std.testing.allocator, "! false | true");
    defer pipeline_negated.parsed.deinit();
    defer pipeline_negated.program.deinit();
    var pipeline_result = try executor.executeProgram(pipeline_negated.program, .{});
    defer pipeline_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), pipeline_result.status);
}

test "executor applies pipefail option to pipeline status" {
    var internal = try parseAndLower(std.testing.allocator, "false | true");
    defer internal.parsed.deinit();
    defer internal.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var default_result = try executor.executeProgram(internal.program, .{});
    defer default_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), default_result.status);

    executor.shell_options.pipefail = true;
    var pipefail_result = try executor.executeProgram(internal.program, .{});
    defer pipefail_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), pipefail_result.status);

    var external = try parseAndLower(std.testing.allocator, "/bin/sh -c 'exit 3' | /usr/bin/true");
    defer external.parsed.deinit();
    defer external.program.deinit();
    var external_result = try executor.executeProgram(external.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 3), external_result.status);

    var mixed = try parseAndLower(std.testing.allocator, "false | /usr/bin/true");
    defer mixed.parsed.deinit();
    defer mixed.program.deinit();
    var mixed_result = try executor.executeProgram(mixed.program, .{ .io = std.testing.io, .allow_external = true });
    defer mixed_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), mixed_result.status);
}

test "executor materializes here-docs without fixed temp filename" {
    const old_path = "rush-heredoc.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, old_path) catch {};
    var sentinel = try std.Io.Dir.cwd().createFile(std.testing.io, old_path, .{ .truncate = true });
    defer sentinel.close(std.testing.io);
    try writeBytesToFile(std.testing.io, sentinel, "sentinel");

    var lowered = try parseAndLower(std.testing.allocator,
        \\cat <<EOF
        \\body
        \\EOF
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqualStrings("body\n", result.stdout);

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, old_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("sentinel", contents);
}

test "executor supports here-doc stdin redirections" {
    var simple = try parseAndLower(std.testing.allocator,
        \\cat <<EOF
        \\hello
        \\EOF
    );
    defer simple.parsed.deinit();
    defer simple.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var simple_result = try executor.executeProgram(simple.program, .{ .io = std.testing.io });
    defer simple_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), simple_result.status);
    try std.testing.expectEqualStrings("hello\n", simple_result.stdout);

    var stripped = try parseAndLower(std.testing.allocator, "cat <<-EOF\n\tstripped\n\tEOF\n");
    defer stripped.parsed.deinit();
    defer stripped.program.deinit();
    var stripped_result = try executor.executeProgram(stripped.program, .{ .io = std.testing.io });
    defer stripped_result.deinit();
    try std.testing.expectEqualStrings("stripped\n", stripped_result.stdout);

    var piped = try parseAndLower(std.testing.allocator,
        \\cat <<EOF | /bin/cat
        \\pipe
        \\EOF
    );
    defer piped.parsed.deinit();
    defer piped.program.deinit();
    var piped_result = try executor.executeProgram(piped.program, .{ .io = std.testing.io, .allow_external = true });
    defer piped_result.deinit();
    try std.testing.expectEqualStrings("pipe\n", piped_result.stdout);

    var multiple = try parseAndLower(std.testing.allocator,
        \\cat <<FIRST <<SECOND
        \\first body
        \\FIRST
        \\second body
        \\SECOND
    );
    defer multiple.parsed.deinit();
    defer multiple.program.deinit();
    var multiple_result = try executor.executeProgram(multiple.program, .{ .io = std.testing.io });
    defer multiple_result.deinit();
    try std.testing.expectEqualStrings("second body\n", multiple_result.stdout);

    var pipeline_multiple = try parseAndLower(std.testing.allocator,
        \\cat <<LEFT | cat <<RIGHT
        \\left body
        \\LEFT
        \\right body
        \\RIGHT
    );
    defer pipeline_multiple.parsed.deinit();
    defer pipeline_multiple.program.deinit();
    var pipeline_multiple_result = try executor.executeProgram(pipeline_multiple.program, .{ .io = std.testing.io });
    defer pipeline_multiple_result.deinit();
    try std.testing.expectEqualStrings("right body\n", pipeline_multiple_result.stdout);

    try executor.setEnv("HD_VALUE", "expanded");
    var expanded = try parseAndLower(std.testing.allocator,
        \\cat <<EOF
        \\$HD_VALUE $(echo command) $((1 + 2))
        \\EOF
    );
    defer expanded.parsed.deinit();
    defer expanded.program.deinit();
    var expanded_result = try executor.executeProgram(expanded.program, .{ .io = std.testing.io });
    defer expanded_result.deinit();
    try std.testing.expectEqualStrings("expanded command 3\n", expanded_result.stdout);

    var quoted = try parseAndLower(std.testing.allocator,
        \\cat <<'EOF'
        \\$HD_VALUE $(echo command) $((1 + 2))
        \\EOF
    );
    defer quoted.parsed.deinit();
    defer quoted.program.deinit();
    var quoted_result = try executor.executeProgram(quoted.program, .{ .io = std.testing.io });
    defer quoted_result.deinit();
    try std.testing.expectEqualStrings("$HD_VALUE $(echo command) $((1 + 2))\n", quoted_result.stdout);
}

test "executor cleans up pipelines when a stage command is missing" {
    var mixed_first = try parseAndLower(std.testing.allocator, "hi | cat");
    defer mixed_first.parsed.deinit();
    defer mixed_first.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var mixed_first_result = try executor.executeProgram(mixed_first.program, .{ .io = std.testing.io, .allow_external = true });
    defer mixed_first_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), mixed_first_result.status);
    try std.testing.expectEqualStrings("hi: command not found\n", mixed_first_result.stderr);

    var mixed_last = try parseAndLower(std.testing.allocator, "echo ok | hi");
    defer mixed_last.parsed.deinit();
    defer mixed_last.program.deinit();
    var mixed_last_result = try executor.executeProgram(mixed_last.program, .{ .io = std.testing.io, .allow_external = true });
    defer mixed_last_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), mixed_last_result.status);
    try std.testing.expectEqualStrings("hi: command not found\n", mixed_last_result.stderr);

    var external_first = try parseAndLower(std.testing.allocator, "hi | /bin/cat");
    defer external_first.parsed.deinit();
    defer external_first.program.deinit();
    var external_first_result = try executor.executeProgram(external_first.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_first_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), external_first_result.status);
    try std.testing.expectEqualStrings("hi: command not found\n", external_first_result.stderr);
}

test "executor supports real redirections on pipeline stages" {
    const first_path = "rush-pipeline-stage-first.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, first_path) catch {};
    var first = try parseAndLower(std.testing.allocator, "echo hidden > rush-pipeline-stage-first.tmp | cat");
    defer first.parsed.deinit();
    defer first.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var first_result = try executor.executeProgram(first.program, .{ .io = std.testing.io, .allow_external = true });
    defer first_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), first_result.status);
    try std.testing.expectEqualStrings("", first_result.stdout);
    const first_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, first_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(first_contents);
    try std.testing.expectEqualStrings("hidden\n", first_contents);

    const last_path = "rush-pipeline-stage-last.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, last_path) catch {};
    var last = try parseAndLower(std.testing.allocator, "/usr/bin/printf visible | cat > rush-pipeline-stage-last.tmp");
    defer last.parsed.deinit();
    defer last.program.deinit();
    var last_result = try executor.executeProgram(last.program, .{ .io = std.testing.io, .allow_external = true });
    defer last_result.deinit();
    try std.testing.expectEqualStrings("", last_result.stdout);
    const last_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, last_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(last_contents);
    try std.testing.expectEqualStrings("visible", last_contents);

    const input_path = "rush-pipeline-stage-input.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = input_path, .data = "from-input" });
    var input = try parseAndLower(std.testing.allocator, "cat < rush-pipeline-stage-input.tmp | /bin/cat");
    defer input.parsed.deinit();
    defer input.program.deinit();
    var input_result = try executor.executeProgram(input.program, .{ .io = std.testing.io, .allow_external = true });
    defer input_result.deinit();
    try std.testing.expectEqualStrings("from-input", input_result.stdout);
}

test "executor supports mixed builtin and external pipeline stages" {
    var builtin_to_external = try parseAndLower(std.testing.allocator, "echo hello | /bin/cat");
    defer builtin_to_external.parsed.deinit();
    defer builtin_to_external.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var builtin_to_external_result = try executor.executeProgram(builtin_to_external.program, .{ .io = std.testing.io, .allow_external = true });
    defer builtin_to_external_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), builtin_to_external_result.status);
    try std.testing.expectEqualStrings("hello\n", builtin_to_external_result.stdout);

    var external_to_builtin = try parseAndLower(std.testing.allocator, "/usr/bin/printf hello | cat");
    defer external_to_builtin.parsed.deinit();
    defer external_to_builtin.program.deinit();

    var external_to_builtin_result = try executor.executeProgram(external_to_builtin.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_to_builtin_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), external_to_builtin_result.status);
    try std.testing.expectEqualStrings("hello", external_to_builtin_result.stdout);

    var external_status = try parseAndLower(std.testing.allocator, "true | /bin/sh -c 'exit 7'");
    defer external_status.parsed.deinit();
    defer external_status.program.deinit();

    var external_status_result = try executor.executeProgram(external_status.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_status_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 7), external_status_result.status);

    var builtin_status = try parseAndLower(std.testing.allocator, "/usr/bin/printf hello | false");
    defer builtin_status.parsed.deinit();
    defer builtin_status.program.deinit();

    var builtin_status_result = try executor.executeProgram(builtin_status.program, .{ .io = std.testing.io, .allow_external = true });
    defer builtin_status_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), builtin_status_result.status);
}

test "executor wires external pipelines with real process pipes" {
    var lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf hello | /bin/cat");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello", result.stdout);
}

test "executor captures stderr and status from spawned external commands" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sh -c 'echo err >&2; exit 7'");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("err\n", result.stderr);
}

test "command substitution captures external stdout while stderr remains pty" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = close(master);
    defer _ = close(slave);

    const original_stderr = dup(std.Io.File.stderr().handle);
    if (original_stderr < 0) return error.SkipZigTest;
    defer _ = close(original_stderr);
    if (dup2(slave, std.Io.File.stderr().handle) < 0) return error.SkipZigTest;
    defer _ = dup2(original_stderr, std.Io.File.stderr().handle);

    var lowered = try parseAndLower(std.testing.allocator,
        \\value=$(/bin/sh -c 'if test -t 2; then printf tty; else printf notty; fi')
        \\echo stderr:$value
        \\value=$(/bin/sh -c 'if test -t 2; then printf tty; else printf notty; fi; printf err-simple >&2' 2>&1)
        \\echo dup:$value
        \\value=$(/bin/sh -c 'printf err >&2; printf out' 2>&1)
        \\echo order:$value
        \\value=$({ /bin/sh -c 'if test -t 2; then printf tty; else printf notty; fi; printf err-group >&2'; } 2>&1)
        \\echo group:$value
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("stderr:tty\ndup:nottyerr-simple\norder:errout\ngroup:nottyerr-group\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "executor can run an external command when allowed" {
    var lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf ok");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ok", result.stdout);
}

test "complete requires function providers to declare a structured context" {
    var lowered = try parseAndLower(std.testing.allocator, "complete git --function __rush_complete_git");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("complete: --function requires --subcommands, --options, --argument, or --option-value\n", result.stderr);
    try std.testing.expectEqual(@as(usize, 0), executor.completion_rules.items.len);
}

test "complete accepts structured function provider selectors" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\complete git --subcommands --function __rush_complete_git_subcommands
        \\complete git --options --function __rush_complete_git_options
        \\complete git --argument --function __rush_complete_git_arguments
        \\complete git --option-value --long config --function __rush_complete_git_config_values
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 4), executor.completion_rules.items.len);
    try std.testing.expectEqual(completion.RuleKind.dynamic_subcommands, executor.completion_rules.items[0].kind);
    try std.testing.expectEqual(completion.RuleKind.dynamic_options, executor.completion_rules.items[1].kind);
    try std.testing.expectEqual(completion.RuleKind.dynamic_argument, executor.completion_rules.items[2].kind);
    try std.testing.expectEqual(completion.RuleKind.dynamic_option_value, executor.completion_rules.items[3].kind);
}

test "complete registers static subcommand rules" {
    var lowered = try parseAndLower(std.testing.allocator, "complete git --subcommand commit --description 'record changes'");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqual(@as(usize, 1), executor.completion_rules.items.len);
    const rule = executor.completion_rules.items[0];
    try std.testing.expectEqual(completion.RuleKind.subcommand, rule.kind);
    try std.testing.expectEqualStrings("git", rule.root);
    try std.testing.expectEqual(@as(usize, 0), rule.path.len);
    try std.testing.expectEqualStrings("commit", rule.value.?);
    try std.testing.expectEqualStrings("record changes", rule.description.?);
}

test "complete registers static option rules" {
    var lowered = try parseAndLower(std.testing.allocator, "complete git --option --short C --value-name path --description 'change directory' --no-space");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    const rule = executor.completion_rules.items[0];
    try std.testing.expectEqual(completion.RuleKind.option, rule.kind);
    try std.testing.expectEqualStrings("git", rule.root);
    try std.testing.expectEqualStrings("C", rule.option.short.?);
    try std.testing.expectEqualStrings("path", rule.option.argument.?);
    try std.testing.expectEqualStrings("change directory", rule.description.?);
    try std.testing.expect(rule.option.no_space);
}

test "complete registers path scoped option rules" {
    var lowered = try parseAndLower(std.testing.allocator, "complete 'git commit' --option --long amend --description 'amend previous commit'");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    const rule = executor.completion_rules.items[0];
    try std.testing.expectEqual(completion.RuleKind.option, rule.kind);
    try std.testing.expectEqualStrings("git", rule.root);
    try std.testing.expectEqual(@as(usize, 1), rule.path.len);
    try std.testing.expectEqualStrings("commit", rule.path[0]);
    try std.testing.expectEqualStrings("amend", rule.option.long.?);
    try std.testing.expectEqualStrings("amend previous commit", rule.description.?);
}

test "completion analysis resolves subcommand context and option prefix" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete git --subcommand commit
        \\complete 'git commit' --option --long amend --description amend
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const source = "git commit --am";
    var analysis = try executor.analyzeCompletionsForInput(source, source.len);
    defer analysis.deinit();

    try std.testing.expectEqualStrings("git", analysis.root);
    try std.testing.expectEqual(@as(usize, 1), analysis.path.len);
    try std.testing.expectEqualStrings("commit", analysis.path[0]);
    try std.testing.expectEqual(CompletionSemanticPosition.option, analysis.position);
    try std.testing.expectEqualStrings("--am", analysis.prefix);
    try std.testing.expectEqual(@as(usize, "git commit ".len), analysis.replace_start);
    try std.testing.expectEqual(@as(usize, source.len), analysis.replace_end);
}

test "completion analysis consumes parent options before subcommands" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete git --option --short C --value-name path
        \\complete git --option --long git-dir --value-name path
        \\complete git --subcommand commit
        \\complete 'git commit' --option --long amend
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const detached = "git -C repo commit --am";
    var detached_analysis = try executor.analyzeCompletionsForInput(detached, detached.len);
    defer detached_analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), detached_analysis.path.len);
    try std.testing.expectEqualStrings("commit", detached_analysis.path[0]);
    try std.testing.expectEqualStrings("--am", detached_analysis.prefix);
    try std.testing.expectEqualStrings("commit", detached_analysis.previous);

    const value_slot = "git -C re";
    var value_analysis = try executor.analyzeCompletionsForInput(value_slot, value_slot.len);
    defer value_analysis.deinit();
    try std.testing.expectEqual(CompletionSemanticPosition.option_value, value_analysis.position);
    try std.testing.expectEqualStrings("C", value_analysis.option_value.?.name);
    try std.testing.expectEqualStrings("-C", value_analysis.option_value.?.spelling);
    try std.testing.expectEqualStrings("re", value_analysis.prefix);

    const attached = "git --git-dir=.git commit --am";
    var attached_analysis = try executor.analyzeCompletionsForInput(attached, attached.len);
    defer attached_analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), attached_analysis.path.len);
    try std.testing.expectEqualStrings("commit", attached_analysis.path[0]);
    try std.testing.expectEqualStrings("--am", attached_analysis.prefix);
}

test "completion analysis handles nested subcommands and unknown options conservatively" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete kubectl --option --long context --value-name name
        \\complete kubectl --subcommand get
        \\complete 'kubectl get' --subcommand pods
        \\complete 'kubectl get pods' --option --long watch
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const nested = "kubectl --context prod get pods --w";
    var nested_analysis = try executor.analyzeCompletionsForInput(nested, nested.len);
    defer nested_analysis.deinit();
    try std.testing.expectEqual(@as(usize, 2), nested_analysis.path.len);
    try std.testing.expectEqualStrings("get", nested_analysis.path[0]);
    try std.testing.expectEqualStrings("pods", nested_analysis.path[1]);
    try std.testing.expectEqualStrings("--w", nested_analysis.prefix);

    const unknown = "kubectl --unknown prod get pods --w";
    var unknown_analysis = try executor.analyzeCompletionsForInput(unknown, unknown.len);
    defer unknown_analysis.deinit();
    try std.testing.expectEqual(@as(usize, 0), unknown_analysis.path.len);
    try std.testing.expect(unknown_analysis.suspicious_start != null);
    try std.testing.expectEqualStrings("prod", unknown_analysis.previous);
}

test "completion diagnostics report unknown command" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    const diagnostics = try executor.completionDiagnosticsForInput("gti ", "gti ".len);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.unknown_command, diagnostics[0].kind);
    try std.testing.expectEqual(CompletionDiagnosticSeverity.err, diagnostics[0].severity);
    try std.testing.expectEqual(@as(usize, 0), diagnostics[0].start);
    try std.testing.expectEqual(@as(usize, 3), diagnostics[0].end);
}

test "completion diagnostics ignore assignment prefixes" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    const assignment_only = try executor.completionDiagnosticsForInput("rows=$(tput lines); echo $rows", "rows=$(tput lines); echo $rows".len);
    defer std.testing.allocator.free(assignment_only);
    try std.testing.expectEqual(@as(usize, 0), assignment_only.len);

    const source = "FOO=bar gti ";
    const diagnostics = try executor.completionDiagnosticsForInput(source, source.len);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.unknown_command, diagnostics[0].kind);
    try std.testing.expectEqual(@as(usize, 8), diagnostics[0].start);
    try std.testing.expectEqual(@as(usize, 11), diagnostics[0].end);
}

test "completion diagnostics accept executable commands from PATH" {
    const root = "rush-completion-path-command-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().symLink(std.testing.io, "/bin/sh", "rush-completion-path-command-test/rush-path-command", .{});

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PATH", root);

    const available = try executor.completionDiagnosticsForInputOptions("rush-path-command ", "rush-path-command ".len, .{ .io = std.testing.io });
    defer std.testing.allocator.free(available);
    try std.testing.expectEqual(@as(usize, 0), available.len);

    const missing = try executor.completionDiagnosticsForInputOptions("rush-missing-command ", "rush-missing-command ".len, .{ .io = std.testing.io });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.unknown_command, missing[0].kind);
}

test "completion diagnostics report unknown subcommand after valid prefixes" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete git --subcommand commit
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const prefix = try executor.completionDiagnosticsForInput("git com", "git com".len);
    defer std.testing.allocator.free(prefix);
    try std.testing.expectEqual(@as(usize, 0), prefix.len);

    const diagnostics = try executor.completionDiagnosticsForInput("git comit ", "git comit ".len);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.unknown_subcommand, diagnostics[0].kind);
    try std.testing.expectEqual(@as(usize, 4), diagnostics[0].start);
    try std.testing.expectEqual(@as(usize, 9), diagnostics[0].end);
}

test "completion diagnostics report unknown option after valid prefixes" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete git --subcommand commit
        \\complete 'git commit' --option --long amend
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const prefix = try executor.completionDiagnosticsForInput("git commit --am", "git commit --am".len);
    defer std.testing.allocator.free(prefix);
    try std.testing.expectEqual(@as(usize, 0), prefix.len);

    const diagnostics = try executor.completionDiagnosticsForInput("git commit --ammend ", "git commit --ammend ".len);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.unknown_option, diagnostics[0].kind);
    try std.testing.expectEqual(@as(usize, 11), diagnostics[0].start);
    try std.testing.expectEqual(@as(usize, 19), diagnostics[0].end);
}

test "completion diagnostics report missing option value" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete git --option --short C --value-name path
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const diagnostics = try executor.completionDiagnosticsForInput("git -C", "git -C".len);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.missing_option_value, diagnostics[0].kind);
    try std.testing.expectEqual(CompletionDiagnosticSeverity.warning, diagnostics[0].severity);
    try std.testing.expectEqual(@as(usize, 4), diagnostics[0].start);
    try std.testing.expectEqual(@as(usize, 6), diagnostics[0].end);
}

test "completion diagnostics accept combined short option clusters" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete ls --option --short a
        \\complete ls --option --short l
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const diagnostics = try executor.completionDiagnosticsForInput("ls -al ", "ls -al ".len);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "completion diagnostics report invalid combined short option members" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete ls --option --short a
        \\complete ls --option --short l
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const diagnostics = try executor.completionDiagnosticsForInput("ls -alz ", "ls -alz ".len);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.unknown_option, diagnostics[0].kind);
    try std.testing.expectEqual(@as(usize, 6), diagnostics[0].start);
    try std.testing.expectEqual(@as(usize, 7), diagnostics[0].end);
}

test "completion diagnostics handle value-taking short options in clusters" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete grep --option --short n
        \\complete grep --option --short e --value-name pattern
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const attached = try executor.completionDiagnosticsForInput("grep -nefoo ", "grep -nefoo ".len);
    defer std.testing.allocator.free(attached);
    try std.testing.expectEqual(@as(usize, 0), attached.len);

    const next_word = try executor.completionDiagnosticsForInput("grep -ne foo ", "grep -ne foo ".len);
    defer std.testing.allocator.free(next_word);
    try std.testing.expectEqual(@as(usize, 0), next_word.len);

    const missing = try executor.completionDiagnosticsForInput("grep -ne ", "grep -ne ".len);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqual(CompletionDiagnosticKind.missing_option_value, missing[0].kind);
}

test "structured completion rules emit subcommand and option candidates" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_commit_args() {
        \\  completion candidate HEAD --kind plain
        \\}
        \\complete git --subcommand commit --description commit
        \\complete git --option --long help --description help
        \\complete 'git commit' --option --long amend --description amend
        \\complete 'git commit' --argument --function __git_commit_args
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const subcommands = try executor.collectCompletionsForInput("git c", "git c".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(subcommands);
    try expectCandidate(subcommands, "commit", .subcommand);
    const commit = findCandidate(subcommands, "commit") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("commit", commit.description.?);
    try std.testing.expectEqual(@as(usize, "git ".len), commit.replace_start);

    var root_trailing = try executor.analyzeCompletionsForInput("git ", "git ".len);
    defer root_trailing.deinit();
    try std.testing.expectEqualStrings("git", root_trailing.root);
    try std.testing.expectEqual(CompletionSemanticPosition.subcommand, root_trailing.position);
    try std.testing.expectEqualStrings("", root_trailing.prefix);
    try std.testing.expectEqual(@as(usize, "git ".len), root_trailing.replace_start);
    try std.testing.expectEqual(@as(usize, "git ".len), root_trailing.replace_end);

    const trailing_subcommands = try executor.collectCompletionsForInput("git ", "git ".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(trailing_subcommands);
    try expectCandidate(trailing_subcommands, "commit", .subcommand);
    try expectCandidate(trailing_subcommands, "--help", .option);
    const trailing_commit = findCandidate(trailing_subcommands, "commit") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "git ".len), trailing_commit.replace_start);
    try std.testing.expectEqual(@as(usize, "git ".len), trailing_commit.replace_end);
    const trailing_help = findCandidate(trailing_subcommands, "--help") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "git ".len), trailing_help.replace_start);
    try std.testing.expectEqual(@as(usize, "git ".len), trailing_help.replace_end);

    const options = try executor.collectCompletionsForInput("git commit --a", "git commit --a".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(options);
    try expectCandidate(options, "--amend", .option);
    const amend = findCandidate(options, "--amend") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("amend", amend.option.?.long.?);
    try std.testing.expectEqualStrings("amend", amend.description.?);
    try std.testing.expectEqual(@as(usize, "git commit ".len), amend.replace_start);

    var nested_trailing = try executor.analyzeCompletionsForInput("git commit ", "git commit ".len);
    defer nested_trailing.deinit();
    try std.testing.expectEqualStrings("git", nested_trailing.root);
    try std.testing.expectEqual(@as(usize, 1), nested_trailing.path.len);
    try std.testing.expectEqualStrings("commit", nested_trailing.path[0]);
    try std.testing.expectEqual(CompletionSemanticPosition.subcommand, nested_trailing.position);
    try std.testing.expectEqualStrings("", nested_trailing.prefix);
    try std.testing.expectEqual(@as(usize, "git commit ".len), nested_trailing.replace_start);
    try std.testing.expectEqual(@as(usize, "git commit ".len), nested_trailing.replace_end);

    const nested_options = try executor.collectCompletionsForInput("git commit ", "git commit ".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(nested_options);
    try expectCandidate(nested_options, "HEAD", .plain);
}

test "completion candidates sort non-options before grouped options" {
    var builder: CompletionBuilder = .{};
    try builder.appendCandidate(std.testing.allocator, .{ .value = "--zeta", .kind = .option, .option = .{ .long = "zeta" }, .replace_start = 0, .replace_end = 0 });
    try builder.appendCandidate(std.testing.allocator, .{ .value = "-v", .kind = .option, .option = .{ .short = "v" }, .replace_start = 0, .replace_end = 0 });
    try builder.appendCandidate(std.testing.allocator, .{ .value = "status", .kind = .subcommand, .replace_start = 0, .replace_end = 0 });
    try builder.appendCandidate(std.testing.allocator, .{ .value = "--alpha", .kind = .option, .option = .{ .long = "alpha", .short = "a" }, .replace_start = 0, .replace_end = 0 });
    try builder.appendCandidate(std.testing.allocator, .{ .value = "add", .kind = .subcommand, .replace_start = 0, .replace_end = 0 });

    const candidates = try builder.finish(std.testing.allocator);
    defer completion.freeCandidates(std.testing.allocator, candidates);
    try std.testing.expectEqualStrings("add", candidates[0].value);
    try std.testing.expectEqualStrings("status", candidates[1].value);
    try std.testing.expectEqualStrings("-v", candidates[2].value);
    try std.testing.expectEqualStrings("--alpha", candidates[3].value);
    try std.testing.expectEqualStrings("--zeta", candidates[4].value);
}

fn openFdCount() !usize {
    if (zig_builtin.os.tag == .windows or zig_builtin.os.tag == .wasi) return error.SkipZigTest;
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, "/dev/fd", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(std.testing.io);
    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

test "root command completion closes PATH directory fds" {
    const root = "rush-fd-completion-path-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);

    var path_builder: std.ArrayList(u8) = .empty;
    defer path_builder.deinit(std.testing.allocator);
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        const dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin{d}", .{ root, index });
        defer std.testing.allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
        if (index != 0) try path_builder.append(std.testing.allocator, ':');
        try path_builder.appendSlice(std.testing.allocator, dir);
    }

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PATH", path_builder.items);

    const before = try openFdCount();
    index = 0;
    while (index < 8) : (index += 1) {
        const candidates = try executor.collectCompletionsForInput("x", "x".len, .{ .io = std.testing.io });
        executor.freeCompletions(candidates);
    }
    const after = try openFdCount();
    try std.testing.expectEqual(before, after);
}

test "dynamic completion providers close external command fds" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_external() {
        \\  value=$(/bin/echo candidate)
        \\  /bin/echo err >&2
        \\  completion candidate candidate
        \\}
        \\complete tool --argument --function __rush_complete_external
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PATH", "/bin:/usr/bin");
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const before = try openFdCount();
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        const candidates = try executor.collectCompletionsForInput("tool ", "tool ".len, .{ .io = std.testing.io, .allow_external = true });
        executor.freeCompletions(candidates);
    }
    const after = try openFdCount();
    try std.testing.expectEqual(before, after);
}

test "structured completion keeps parent options available in subcommand contexts" {
    var setup = try parseAndLower(std.testing.allocator,
        \\complete git --option --long verbose --description verbose
        \\complete git --subcommand commit
        \\complete 'git commit' --option --long amend
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const candidates = try executor.collectCompletionsForInput("git commit --", "git commit --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "--verbose", .option);
    try expectCandidate(candidates, "--amend", .option);
}

test "dynamic structured completion merges with static subcommands" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_dynamic_subcommands() {
        \\  completion candidate checkout --kind subcommand
        \\}
        \\complete git --subcommand commit
        \\complete git --subcommands --function __git_dynamic_subcommands
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const candidates = try executor.collectCompletionsForInput("git c", "git c".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "commit", .subcommand);
    try expectCandidate(candidates, "checkout", .subcommand);
}

test "dynamic structured argument provider is scoped to command path" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_refs() {
        \\  completion candidate main --kind plain
        \\}
        \\complete git --subcommand checkout
        \\complete git --subcommand commit
        \\complete 'git checkout' --argument --function __git_refs
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const checkout = try executor.collectCompletionsForInput("git checkout ma", "git checkout ma".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(checkout);
    try expectCandidate(checkout, "main", .plain);

    const commit = try executor.collectCompletionsForInput("git commit ma", "git commit ma".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(commit);
    try expectNoCandidate(commit, "main");
}

test "dynamic structured completion candidates support fuzzy display filtering" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_args() {
        \\  completion candidate checkout --display 'git checkout' --kind plain
        \\  completion candidate status --kind plain
        \\}
        \\complete git --subcommand commit
        \\complete 'git commit' --argument --function __git_args
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const candidates = try executor.collectCompletionsForInput("git commit gco", "git commit gco".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    const application = try completion.applyCandidatesForInput(std.testing.allocator, "git commit gco", candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("checkout", edit.replacement);
}

test "dynamic structured option value provider is scoped to option" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_log_formats() {
        \\  completion candidate full --kind plain
        \\}
        \\complete git --subcommand log
        \\complete 'git log' --option-value --long format --function __git_log_formats
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const candidates = try executor.collectCompletionsForInput("git log --format f", "git log --format f".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "full", .plain);
    const full = findCandidate(candidates, "full") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "git log --format ".len), full.replace_start);
}

test "completion candidate merge deduplicates by replacement span and value" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_dynamic_subcommands() {
        \\  completion candidate commit --kind subcommand --description dynamic
        \\}
        \\complete git --subcommand commit --description static
        \\complete git --subcommands --function __git_dynamic_subcommands
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const candidates = try executor.collectCompletionsForInput("git c", "git c".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try std.testing.expectEqual(@as(usize, 1), countCandidates(candidates, "commit"));
    const commit = findCandidate(candidates, "commit") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("static", commit.description.?);
}

test "completion candidate merge keeps static metadata before dynamic overlap" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_dynamic_options() {
        \\  completion option --long amend --description dynamic
        \\}
        \\complete git --options --function __git_dynamic_options
        \\complete git --option --long amend --description static
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const candidates = try executor.collectCompletionsForInput("git --a", "git --a".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try std.testing.expectEqual(@as(usize, 1), countCandidates(candidates, "--amend"));
    const amend = findCandidate(candidates, "--amend") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("static", amend.description.?);
}

test "completion candidate merge deduplicates provider helper fallback overlap" {
    const path = "rush-dedup-path-candidate";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });

    var setup = try parseAndLower(std.testing.allocator,
        \\__git_paths() {
        \\  completion candidate rush-dedup-path-candidate --description dynamic
        \\  completion files
        \\}
        \\complete git --subcommand checkout
        \\complete 'git checkout' --argument --function __git_paths
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const source = "git checkout rush-dedup";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try std.testing.expectEqual(@as(usize, 1), countCandidates(candidates, path));
    const candidate = findCandidate(candidates, path) orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("dynamic", candidate.description.?);
}

test "completion context helpers expose semantic command path in scoped providers" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_commit_args() {
        \\  completion candidate "$(completion command-path)" --display "$(completion command)" --description "$(completion previous)" --kind plain
        \\  completion candidate "$(completion position)" --display "$(completion prefix)"
        \\}
        \\complete git --subcommand commit
        \\complete 'git commit' --argument --function __git_commit_args
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const source = "git commit fi";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "git commit", .plain);
    const path = findCandidate(candidates, "git commit") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("git", path.display.?);
    try std.testing.expectEqualStrings("commit", path.description.?);
    try expectCandidate(candidates, "argument", .plain);
    const position = findCandidate(candidates, "argument") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("fi", position.display.?);
}

test "completion context helpers expose semantic option value context in scoped providers" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__git_authors() {
        \\  completion candidate "$(completion prefix)" --display "$(completion position)" --description "$(completion option-name):$(completion option-spelling)"
        \\}
        \\complete git --subcommand commit
        \\complete 'git commit' --option-value --long author --function __git_authors
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    const detached_source = "git commit --author ti";
    const detached = try executor.collectCompletionsForInput(detached_source, detached_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(detached);
    const detached_candidate = findCandidate(detached, "ti") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("option_value", detached_candidate.display.?);
    try std.testing.expectEqualStrings("author:--author", detached_candidate.description.?);
    try std.testing.expectEqual(@as(usize, "git commit --author ".len), detached_candidate.replace_start);

    const attached_source = "git commit --author=ti";
    const attached = try executor.collectCompletionsForInput(attached_source, attached_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(attached);
    const attached_candidate = findCandidate(attached, "ti") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("option_value", attached_candidate.display.?);
    try std.testing.expectEqualStrings("author:--author", attached_candidate.description.?);
    try std.testing.expectEqual(@as(usize, "git commit --author=".len), attached_candidate.replace_start);
}

test "completion candidate is scoped to completion evaluation" {
    var outside = try parseAndLower(std.testing.allocator, "completion candidate status");
    defer outside.parsed.deinit();
    defer outside.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var outside_result = try executor.executeProgram(outside.program, .{ .io = std.testing.io });
    defer outside_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), outside_result.status);

    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_git() {
        \\  completion candidate status --display st --description 'show status' --kind subcommand --no-space
        \\}
        \\complete git --argument --function __rush_complete_git
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const candidates = try executor.collectCompletionsForInput("git s", "git s".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("status", candidates[0].value);
    try std.testing.expectEqualStrings("st", candidates[0].display.?);
    try std.testing.expectEqualStrings("show status", candidates[0].description.?);
    try std.testing.expectEqual(completion.Kind.subcommand, candidates[0].kind);
    try std.testing.expect(!candidates[0].append_space);
}

test "completion functions can read semantic context" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_git() {
        \\  completion candidate $(completion prefix) --display $(completion command) --description $(completion previous) --kind option
        \\  completion candidate $(completion argument-index) --display $(completion position)
        \\}
        \\complete git --argument --function __rush_complete_git
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "git checkout ma";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    const prefix = findCandidate(candidates, "ma") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("git", prefix.display.?);
    try std.testing.expectEqualStrings("checkout", prefix.description.?);
    try std.testing.expectEqual(completion.Kind.option, prefix.kind);
    const argument_index = findCandidate(candidates, "2") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("argument", argument_index.display.?);
}

test "completion option emits structured option candidates" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_git() {
        \\  completion option --long amend --description 'amend previous commit'
        \\  completion option --short m --long message --argument message --description 'use message'
        \\}
        \\complete git --options --function __rush_complete_git
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const candidates = try executor.collectCompletionsForInput("git --am", "git --am".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "--amend", .option);
    try expectCandidate(candidates, "--message", .option);
    try expectCandidate(candidates, "-m", .option);

    const message = findCandidate(candidates, "--message") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("message", message.option.?.long.?);
    try std.testing.expectEqualStrings("m", message.option.?.short.?);
    try std.testing.expectEqualStrings("message", message.option.?.argument.?);
    try std.testing.expectEqualStrings("use message", message.description.?);
}

test "completion option works with engine-owned prefix filtering" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_git() {
        \\  completion option --long amend --description amend
        \\  completion option --long author --argument user --description author
        \\}
        \\complete git --options --function __rush_complete_git
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "git --au";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    const application = try completion.applyCandidatesForInput(std.testing.allocator, source, candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("--author", edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "completion detects detached long option value slots" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_git() {
        \\  completion candidate tim --display "$(completion option-name)" --description "$(completion option-spelling)"
        \\}
        \\complete git --option --long author --value-name user --description author
        \\complete git --option-value --long author --function __rush_complete_git
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "git --author t";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("tim", candidates[0].value);
    try std.testing.expectEqualStrings("author", candidates[0].display.?);
    try std.testing.expectEqualStrings("--author", candidates[0].description.?);
    try std.testing.expectEqual(@as(usize, "git --author ".len), candidates[0].replace_start);
    try std.testing.expectEqual(@as(usize, source.len), candidates[0].replace_end);
    const context = executor.lastCompletionContext() orelse return error.MissingCompletionContext;
    try std.testing.expectEqualStrings("t", context.prefix);
    try std.testing.expectEqualStrings("author", context.option_value.?.name);
    try std.testing.expectEqualStrings("--author", context.option_value.?.spelling);
}

test "completion detects attached long option value slots" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_git() {
        \\  completion candidate tim --description "$(completion prefix)"
        \\}
        \\complete git --option --long author --value-name user --description author
        \\complete git --option-value --long author --function __rush_complete_git
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "git --author=t";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("tim", candidates[0].value);
    try std.testing.expectEqualStrings("t", candidates[0].description.?);
    try std.testing.expectEqual(@as(usize, "git --author=".len), candidates[0].replace_start);
    try std.testing.expectEqual(@as(usize, source.len), candidates[0].replace_end);
    const context = executor.lastCompletionContext() orelse return error.MissingCompletionContext;
    try std.testing.expectEqualStrings("t", context.prefix);
    try std.testing.expectEqualStrings("--author", context.option_value.?.spelling);
}

test "completion detects short option value slots" {
    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_git() {
        \\  completion candidate fix --display "$(completion option-spelling)"
        \\}
        \\complete git --option --short m --long message --value-name text --description message
        \\complete git --option-value --short m --function __rush_complete_git
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "git -m f";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);

    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqualStrings("fix", candidates[0].value);
    try std.testing.expectEqualStrings("-m", candidates[0].display.?);
    try std.testing.expectEqual(@as(usize, "git -m ".len), candidates[0].replace_start);
    try std.testing.expectEqual(@as(usize, source.len), candidates[0].replace_end);
}

test "root command completion includes builtins functions aliases and executables" {
    const dir_path = "rush-root-completion-bin";
    const exe_path = "rush-root-completion-bin/rush-root-tool";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir_path, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = exe_path, .data = "" });

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PATH", dir_path);

    var setup = try parseAndLower(std.testing.allocator,
        \\rush_function() { :; }
        \\alias rush_alias='echo alias'
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();
    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "rush";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "rush_function", .function);
    try expectCandidate(candidates, "rush_alias", .command);
    try expectCandidate(candidates, "rush-root-tool", .command);
    const function = findCandidate(candidates, "rush_function") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("function", function.description.?);
}

test "root command completion includes builtin commands" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    const source = "ex";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "exec", .builtin);
    try expectCandidate(candidates, "exit", .builtin);
    try expectCandidate(candidates, "export", .builtin);
}

test "completion helper builtins append structured candidates" {
    const zig_path = "rush-complete-helper-test.zig";
    const txt_path = "rush-complete-helper-test.txt";
    const dir_path = "rush-complete-helper-dir";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, zig_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, txt_path) catch {};
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = zig_path, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = txt_path, .data = "" });
    try std.Io.Dir.cwd().createDir(std.testing.io, dir_path, .default_dir);

    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_files() {
        \\  completion files --prefix rush-complete-helper --extension .zig
        \\  completion directories --prefix rush-complete-helper --append-slash
        \\  completion variables --prefix RUSH_COMPLETION_HELPER_
        \\}
        \\complete helper --argument --function __rush_complete_files
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("RUSH_COMPLETION_HELPER_VARIABLE", "1");

    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const candidates = try executor.collectCompletionsForInput("helper rush-complete-helper", "helper rush-complete-helper".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, zig_path, .file);
    try expectNoCandidate(candidates, txt_path);
    try expectCandidate(candidates, "rush-complete-helper-dir/", .directory);
    try expectCandidate(candidates, "RUSH_COMPLETION_HELPER_VARIABLE", .variable);
}

test "context-scoped completion providers preserve file and directory helpers" {
    const zig_path = "rush-context-helper-test.zig";
    const txt_path = "rush-context-helper-test.txt";
    const dir_path = "rush-context-helper-dir";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, zig_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, txt_path) catch {};
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = zig_path, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = txt_path, .data = "" });
    try std.Io.Dir.cwd().createDir(std.testing.io, dir_path, .default_dir);

    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_paths() {
        \\  completion files --extension .zig
        \\  completion directories --append-slash
        \\}
        \\complete helper --subcommand open
        \\complete 'helper open' --argument --function __rush_complete_paths
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "helper open rush-context-helper";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, zig_path, .file);
    try expectNoCandidate(candidates, txt_path);
    try expectCandidate(candidates, "rush-context-helper-dir/", .directory);

    const directory = findCandidate(candidates, "rush-context-helper-dir/") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "helper open ".len), directory.replace_start);
    try std.testing.expectEqual(@as(usize, source.len), directory.replace_end);
    try std.testing.expect(!directory.append_space);
}

test "context-scoped completion providers preserve executable and variable helpers" {
    const dir_path = "rush-context-helper-bin";
    const exe_path = "rush-context-helper-bin/rush-context-helper-tool";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, dir_path, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = exe_path, .data = "" });

    var setup = try parseAndLower(std.testing.allocator,
        \\__rush_complete_external() {
        \\  completion executables
        \\  completion variables
        \\}
        \\complete helper --subcommand run
        \\complete 'helper run' --argument --function __rush_complete_external
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PATH", dir_path);
    try executor.setEnv("rush-context-helper-variable", "1");
    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const source = "helper run rush-context-helper";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCandidate(candidates, "rush-context-helper-tool", .command);
    try expectCandidate(candidates, "rush-context-helper-variable", .variable);

    const executable = findCandidate(candidates, "rush-context-helper-tool") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "helper run ".len), executable.replace_start);
    try std.testing.expectEqual(@as(usize, source.len), executable.replace_end);
}

test "completion lazy-loads structured scripts from XDG data home" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_HOME", "test/fixtures/completion-data");
    try executor.setEnv("XDG_DATA_DIRS", "");

    try std.testing.expectEqual(@as(usize, 0), executor.completion_rules.items.len);
    const static_candidates = try executor.collectCompletionsForInput("fixturetool st", "fixturetool st".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(static_candidates);
    try expectCandidate(static_candidates, "static", .subcommand);
    try std.testing.expect(executor.completion_rules.items.len != 0);
    const loaded_rule_count = executor.completion_rules.items.len;

    const option_candidates = try executor.collectCompletionsForInput("fixturetool --v", "fixturetool --v".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(option_candidates);
    try expectCandidate(option_candidates, "--verbose", .option);
    try std.testing.expectEqual(loaded_rule_count, executor.completion_rules.items.len);
}

test "completion lazy-loaded scripts can provide dynamic file arguments" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_HOME", "test/fixtures/completion-data");
    try executor.setEnv("XDG_DATA_DIRS", "");

    const path = "rush-lazy-fixture-file.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const source = "fixturetool files rush-lazy-fixture";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    const candidate = findCandidate(candidates, path) orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(completion.Kind.file, candidate.kind);
    try std.testing.expectEqual(@as(usize, "fixturetool files ".len), candidate.replace_start);
    try std.testing.expectEqual(@as(usize, source.len), candidate.replace_end);
}

test "completion config rules merge after lazy-loaded data scripts" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_HOME", "test/fixtures/completion-data");
    try executor.setEnv("XDG_DATA_DIRS", "");

    var setup = try parseAndLower(std.testing.allocator,
        \\complete fixturetool --subcommand user --description 'user config rule'
    );
    defer setup.parsed.deinit();
    defer setup.program.deinit();
    var setup_result = try executor.executeProgram(setup.program, .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), setup_result.status);

    const static_candidates = try executor.collectCompletionsForInput("fixturetool st", "fixturetool st".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(static_candidates);
    try expectCandidate(static_candidates, "static", .subcommand);

    const user_candidates = try executor.collectCompletionsForInput("fixturetool u", "fixturetool u".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(user_candidates);
    try expectCandidate(user_candidates, "user", .subcommand);
}

test "parameter prefix completion offers variables without replacing dollar" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PATH", "/bin");
    try executor.setEnv("HOME", "/tmp");

    const empty_source = "echo $";
    const empty_candidates = try executor.collectCompletionsForInput(empty_source, empty_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(empty_candidates);
    const path = findCandidate(empty_candidates, "PATH") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(completion.Kind.variable, path.kind);
    try std.testing.expectEqual(@as(usize, "echo $".len), path.replace_start);
    try std.testing.expectEqual(@as(usize, "echo $".len), path.replace_end);
    try std.testing.expect(!path.append_space);

    const prefixed_source = "echo $PA";
    const prefixed_candidates = try executor.collectCompletionsForInput(prefixed_source, prefixed_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(prefixed_candidates);
    const prefixed_path = findCandidate(prefixed_candidates, "PATH") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "echo $".len), prefixed_path.replace_start);
    try std.testing.expectEqual(@as(usize, prefixed_source.len), prefixed_path.replace_end);
    try std.testing.expect(findCandidate(prefixed_candidates, "HOME") == null);

    const quoted_source = "echo \"$PA";
    const quoted_candidates = try executor.collectCompletionsForInput(quoted_source, quoted_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(quoted_candidates);
    const quoted_path = findCandidate(quoted_candidates, "PATH") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "echo \"$".len), quoted_path.replace_start);
    try std.testing.expectEqual(@as(usize, quoted_source.len), quoted_path.replace_end);

    const single_quoted_source = "echo '$PA";
    const single_quoted_candidates = try executor.collectCompletionsForInput(single_quoted_source, single_quoted_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(single_quoted_candidates);
    try std.testing.expect(findCandidate(single_quoted_candidates, "PATH") == null);

    const escaped_source = "echo \\$PA";
    const escaped_candidates = try executor.collectCompletionsForInput(escaped_source, escaped_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(escaped_candidates);
    try std.testing.expect(findCandidate(escaped_candidates, "PATH") == null);
}

test "parameter prefix completion application preserves dollar" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PATH", "/bin");

    const source = "echo $PA";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    const application = try completion.applyCandidatesForInput(std.testing.allocator, source, candidates);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.MissingCompletionEdit,
    };
    try std.testing.expectEqual(@as(usize, "echo $".len), edit.replace_start);
    try std.testing.expectEqual(@as(usize, source.len), edit.replace_end);
    try std.testing.expectEqualStrings("PATH", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

fn expectCandidate(candidates: []const completion.Candidate, value: []const u8, kind: completion.Kind) !void {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) {
            try std.testing.expectEqual(kind, candidate.kind);
            return;
        }
    }
    return error.MissingCompletionCandidate;
}

fn findCandidate(candidates: []const completion.Candidate, value: []const u8) ?completion.Candidate {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return candidate;
    }
    return null;
}

fn countCandidates(candidates: []const completion.Candidate, value: []const u8) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) count += 1;
    }
    return count;
}

fn expectNoCandidate(candidates: []const completion.Candidate, value: []const u8) !void {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return error.UnexpectedCompletionCandidate;
    }
}
