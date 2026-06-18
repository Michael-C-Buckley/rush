//! Shell-aware completion engine.

const std = @import("std");
const default_builtins = @import("builtins.zig");
const extension_api = @import("extensions/api.zig");
const extension_handlers = @import("extensions/handlers.zig");
const extension_rush_complete = @import("extensions/editor/rush_complete.zig");
const ir = @import("shell/ir.zig");
const parser = @import("shell/parser.zig");
const runner = @import("runner.zig");
const runtime = @import("runtime.zig");
const shell_state_mod = @import("shell/state.zig");
const editor_completion = @import("editor/completion.zig");
const expand = @import("shell/expand.zig");

pub const CancellationToken = editor_completion.CancellationToken;
pub const Kind = editor_completion.Kind;
pub const Candidate = editor_completion.Candidate;
pub const MatchRank = editor_completion.MatchRank;
pub const CaseSensitivity = editor_completion.CaseSensitivity;
pub const MatchMode = editor_completion.MatchMode;
pub const SeparatorPolicy = editor_completion.SeparatorPolicy;
pub const PathSegmentPolicy = editor_completion.PathSegmentPolicy;
pub const MatcherPolicy = editor_completion.MatcherPolicy;
pub const MatchSuppressionReason = editor_completion.MatchSuppressionReason;
pub const CandidateMatchTrace = editor_completion.CandidateMatchTrace;
pub const Option = editor_completion.Option;
pub const OptionExclusionKind = editor_completion.OptionExclusionKind;
pub const OptionExclusion = editor_completion.OptionExclusion;
pub const Edit = editor_completion.Edit;
pub const Application = editor_completion.Application;
pub const freeCandidates = editor_completion.freeCandidates;
pub const applyCandidates = editor_completion.applyCandidates;
pub const sortCandidates = editor_completion.sortCandidates;
pub const candidateInsertText = editor_completion.candidateInsertText;
pub const candidateEditReplacement = editor_completion.candidateEditReplacement;
pub const candidateEditSuffix = editor_completion.candidateEditSuffix;
pub const candidateFuzzyMatchRank = editor_completion.candidateFuzzyMatchRank;
pub const candidateMatchRank = editor_completion.candidateMatchRank;
pub const candidateMatchTrace = editor_completion.candidateMatchTrace;
pub const candidateSuppressionReason = editor_completion.candidateSuppressionReason;
pub const fuzzyMatchRank = editor_completion.fuzzyMatchRank;
pub const matchRank = editor_completion.matchRank;
pub const fuzzyMatchPositions = editor_completion.fuzzyMatchPositions;
pub const matchPositions = editor_completion.matchPositions;
pub const cloneCandidates = editor_completion.cloneCandidates;

pub const ScriptLoaderOptions = struct {
    io: ?std.Io = null,
    arg_zero: []const u8 = "rush",

    pub fn validate(self: ScriptLoaderOptions) void {
        std.debug.assert(self.arg_zero.len != 0);
        std.debug.assert(std.mem.indexOfScalar(u8, self.arg_zero, 0) == null);
    }
};

pub const Builder = struct {
    candidates: std.ArrayList(Candidate) = .empty,
    owned: std.ArrayList([]const u8) = .empty,
    owned_option_exclusions: std.ArrayList([]const OptionExclusion) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.owned_option_exclusions.items) |excludes| allocator.free(excludes);
        self.owned_option_exclusions.deinit(allocator);
        for (self.candidates.items) |candidate| {
            if (candidate.option) |option| if (option.spellings.len != 0) allocator.free(option.spellings);
        }
        for (self.owned.items) |value| allocator.free(value);
        self.owned.deinit(allocator);
        self.candidates.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendCandidate(self: *Builder, allocator: std.mem.Allocator, candidate: Candidate) !void {
        var owned_candidate = candidate;
        owned_candidate.value = try self.dupeField(allocator, candidate.value);
        if (candidate.display) |display| owned_candidate.display = try self.dupeField(allocator, display);
        if (candidate.insert) |insert| owned_candidate.insert = try self.dupeField(allocator, insert);
        if (candidate.description) |description| {
            owned_candidate.description = try self.dupeField(allocator, description);
        }
        if (candidate.tag) |tag| owned_candidate.tag = try self.dupeField(allocator, tag);
        if (candidate.suffix) |suffix| owned_candidate.suffix = try self.dupeField(allocator, suffix);
        if (candidate.option) |option| {
            const spellings = try allocator.alloc([]const u8, option.spellings.len);
            errdefer allocator.free(spellings);
            for (option.spellings, 0..) |spelling, spelling_index| {
                spellings[spelling_index] = try self.dupeField(allocator, spelling);
            }
            owned_candidate.option = .{
                .long = if (option.long) |long| try self.dupeField(allocator, long) else null,
                .short = if (option.short) |short| try self.dupeField(allocator, short) else null,
                .spellings = spellings,
                .argument = if (option.argument) |argument| try self.dupeField(allocator, argument) else null,
                .exclusive_group = if (option.exclusive_group) |group| try self.dupeField(allocator, group) else null,
                .excludes = try self.dupeOptionExclusions(allocator, option.excludes),
                .repeatable = option.repeatable,
                .terminates_options = option.terminates_options,
                .no_space = option.no_space,
                .inherit = option.inherit,
            };
        }
        try self.candidates.append(allocator, owned_candidate);
    }

    pub fn applyValueSegmentSuffix(
        self: *Builder,
        allocator: std.mem.Allocator,
        start: usize,
        segment: ?ValueSegment,
    ) !void {
        var suffix_buffer: [1]u8 = undefined;
        const suffix = valueSegmentRemovableSuffix(segment, &suffix_buffer) orelse return;
        for (self.candidates.items[start..]) |*candidate| {
            if (candidate.kind == .directory or candidate.suffix != null) continue;
            candidate.suffix = try self.dupeField(allocator, suffix);
            candidate.removable_suffix = true;
            candidate.append_space = false;
        }
    }

    pub fn applyOwnedRuleProviderMetadata(
        self: *Builder,
        allocator: std.mem.Allocator,
        candidate: *Candidate,
        rule: Rule,
    ) !void {
        if (candidate.tag == null) {
            if (rule.tag) |tag| candidate.tag = try self.dupeField(allocator, tag);
        }
        if (candidate.provider_order == null) candidate.provider_order = rule.provider_order;
    }

    pub fn appendCandidateIfMissing(self: *Builder, allocator: std.mem.Allocator, candidate: Candidate) !void {
        if (self.containsCandidate(candidate)) return;
        try self.appendCandidate(allocator, candidate);
    }

    fn containsCandidate(self: Builder, candidate: Candidate) bool {
        for (self.candidates.items) |existing| {
            if (candidateIdentityMatches(existing, candidate)) return true;
        }
        return false;
    }

    fn dupeField(self: *Builder, allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);
        try self.owned.append(allocator, owned);
        return owned;
    }

    fn dupeOptionExclusions(
        self: *Builder,
        allocator: std.mem.Allocator,
        excludes: []const OptionExclusion,
    ) ![]const OptionExclusion {
        if (excludes.len == 0) return &.{};
        const owned = try allocator.alloc(OptionExclusion, excludes.len);
        errdefer allocator.free(owned);
        for (excludes, 0..) |exclusion, index| {
            owned[index] = .{
                .kind = exclusion.kind,
                .selector = if (exclusion.selector) |selector| try self.dupeField(allocator, selector) else null,
            };
        }
        try self.owned_option_exclusions.append(allocator, owned);
        return owned;
    }

    pub fn finish(self: *Builder, allocator: std.mem.Allocator) ![]Candidate {
        const candidates = try self.candidates.toOwnedSlice(allocator);
        sortCandidates(candidates);
        self.owned_option_exclusions.deinit(allocator);
        self.owned.deinit(allocator);
        self.* = undefined;
        return candidates;
    }
};

fn valueSegmentRemovableSuffix(segment: ?ValueSegment, buffer: *[1]u8) ?[]const u8 {
    const active = segment orelse return null;
    if (active.position != .item) return null;
    const separator = active.list_separator orelse return null;
    buffer[0] = separator;
    return buffer[0..];
}

pub fn applyValueSegmentSuffix(candidate: *Candidate, segment: ?ValueSegment, buffer: *[1]u8) void {
    if (candidate.kind == .directory or candidate.suffix != null) return;
    const suffix = valueSegmentRemovableSuffix(segment, buffer) orelse return;
    candidate.suffix = suffix;
    candidate.removable_suffix = true;
    candidate.append_space = false;
}

// Completion candidates are deduplicated by the edit they would apply:
// replacement span plus inserted value. The first source wins so metadata stays
// deterministic across static and dynamic structured rules.
fn candidateIdentityMatches(a: Candidate, b: Candidate) bool {
    return a.replace_start == b.replace_start and
        a.replace_end == b.replace_end and
        std.mem.eql(u8, a.value, b.value);
}

pub const Argument = struct {
    state: ?[]const u8 = null,
    index: ?usize = null,
    after_state: ?[]const u8 = null,
    after_value: ?[]const u8 = null,
    repeatable: bool = false,
    rest_command_line: bool = false,
    when_condition: ?*const ArgumentCondition = null,
    after_condition: ?*const ArgumentCondition = null,
    until_condition: ?*const ArgumentCondition = null,
    require_option_values: []const OptionValueCondition = &.{},
    reject_option_values: []const OptionValueCondition = &.{},

    pub fn hasSelector(self: Argument) bool {
        return self.state != null or
            self.index != null or
            self.after_state != null or
            self.after_value != null or
            self.repeatable or
            self.rest_command_line or
            self.when_condition != null or
            self.after_condition != null or
            self.until_condition != null or
            self.require_option_values.len != 0 or
            self.reject_option_values.len != 0;
    }
};

pub const ArgumentCondition = union(enum) {
    unsupported: void,
    all: []const ArgumentCondition,
    any: []const ArgumentCondition,
    not: *const ArgumentCondition,
    terminator_seen: bool,
    previous_state: []const u8,
    option_present: []const []const u8,
    option_absent: []const []const u8,
    option_value: OptionValueCondition,
};

pub const OptionValueCondition = struct {
    key: []const u8,
    values: []const []const u8,
};

pub fn cloneArgumentCondition(
    allocator: std.mem.Allocator,
    condition: ?*const ArgumentCondition,
) !?*const ArgumentCondition {
    const source = condition orelse return null;
    const owned = try allocator.create(ArgumentCondition);
    errdefer allocator.destroy(owned);
    owned.* = try cloneArgumentConditionValue(allocator, source.*);
    return owned;
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |value| allocator.free(value);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return cloned;
}

fn cloneOptionExclusions(allocator: std.mem.Allocator, excludes: []const OptionExclusion) ![]const OptionExclusion {
    if (excludes.len == 0) return &.{};
    const cloned = try allocator.alloc(OptionExclusion, excludes.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |exclusion| if (exclusion.selector) |selector| allocator.free(selector);
        allocator.free(cloned);
    }
    for (excludes, 0..) |exclusion, index| {
        cloned[index] = .{
            .kind = exclusion.kind,
            .selector = if (exclusion.selector) |selector| try allocator.dupe(u8, selector) else null,
        };
        initialized += 1;
    }
    return cloned;
}

fn freeOptionExclusions(allocator: std.mem.Allocator, excludes: []const OptionExclusion) void {
    if (excludes.len == 0) return;
    for (excludes) |exclusion| if (exclusion.selector) |selector| allocator.free(selector);
    allocator.free(excludes);
}

pub fn cloneArgumentConditionValue(
    allocator: std.mem.Allocator,
    condition: ArgumentCondition,
) anyerror!ArgumentCondition {
    return switch (condition) {
        .unsupported => .{ .unsupported = {} },
        .all => |children| .{ .all = try cloneArgumentConditionSlice(allocator, children) },
        .any => |children| .{ .any = try cloneArgumentConditionSlice(allocator, children) },
        .not => |child| blk: {
            const owned_child = try allocator.create(ArgumentCondition);
            errdefer allocator.destroy(owned_child);
            owned_child.* = try cloneArgumentConditionValue(allocator, child.*);
            break :blk .{ .not = owned_child };
        },
        .terminator_seen => |expected| .{ .terminator_seen = expected },
        .previous_state => |state| .{ .previous_state = try allocator.dupe(u8, state) },
        .option_present => |keys| .{ .option_present = try cloneArgumentConditionStringSlice(allocator, keys) },
        .option_absent => |keys| .{ .option_absent = try cloneArgumentConditionStringSlice(allocator, keys) },
        .option_value => |condition_value| .{
            .option_value = try cloneOptionValueCondition(allocator, condition_value),
        },
    };
}

fn cloneArgumentConditionSlice(
    allocator: std.mem.Allocator,
    children: []const ArgumentCondition,
) anyerror![]const ArgumentCondition {
    if (children.len == 0) return &.{};
    const owned = try allocator.alloc(ArgumentCondition, children.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |child| freeArgumentConditionValue(allocator, child);
        allocator.free(owned);
    }
    for (children, 0..) |child, index| {
        owned[index] = try cloneArgumentConditionValue(allocator, child);
        initialized += 1;
    }
    return owned;
}

fn cloneArgumentConditionStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const owned = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| allocator.free(value);
        allocator.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return owned;
}

fn cloneOptionValueCondition(allocator: std.mem.Allocator, condition: OptionValueCondition) !OptionValueCondition {
    const key = try allocator.dupe(u8, condition.key);
    errdefer allocator.free(key);
    return .{
        .key = key,
        .values = try cloneArgumentConditionStringSlice(allocator, condition.values),
    };
}

pub fn freeArgumentCondition(allocator: std.mem.Allocator, condition: ?*const ArgumentCondition) void {
    const condition_ptr = condition orelse return;
    freeArgumentConditionValue(allocator, condition_ptr.*);
    allocator.destroy(@constCast(condition_ptr));
}

pub fn freeArgumentConditionValue(allocator: std.mem.Allocator, condition: ArgumentCondition) void {
    switch (condition) {
        .unsupported, .terminator_seen => {},
        .all, .any => |children| {
            for (children) |child| freeArgumentConditionValue(allocator, child);
            if (children.len != 0) allocator.free(children);
        },
        .not => |child| {
            freeArgumentCondition(allocator, child);
        },
        .previous_state => |state| allocator.free(state),
        .option_present, .option_absent => |keys| freeArgumentConditionStringSlice(allocator, keys),
        .option_value => |condition_value| {
            allocator.free(condition_value.key);
            freeArgumentConditionStringSlice(allocator, condition_value.values);
        },
    }
}

fn freeArgumentConditionStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len != 0) allocator.free(values);
}

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
    static_enum,
};

pub const StaticProviderValue = struct {
    value: []const u8,
    display: ?[]const u8 = null,
    description: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    removable_suffix: bool = false,
    priority: i8 = 0,
    append_space: bool = true,
};

pub const Rule = struct {
    root: []const u8,
    path: []const []const u8 = &.{},
    kind: RuleKind,
    value: ?[]const u8 = null,
    priority: i8 = 0,
    provider_kind: ProviderKind = .function,
    static_values: []const StaticProviderValue = &.{},
    option: Option = .{},
    argument: Argument = .{},
    value_index: usize = 0,
    value_grammar: ValueGrammar = .{},
    description: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    provider_order: ?usize = null,
    source: RuleSource = .{},
    variant: ?[]const u8 = null,
    disabled: bool = false,
};

pub const EvalContext = struct {
    prefix: []const u8 = "",
    command: []const u8 = "",
    command_path: []const u8 = "",
    argument_index: usize = 0,
    argument_state: ?[]const u8 = null,
    parsed_options: []const ParsedOption = &.{},
    operands: []const ParsedOperand = &.{},
    options_terminated: bool = false,
    previous: []const u8 = "",
    position: parser.CompletionKind = .command,
    option_value: ?OptionValue = null,
    value_segment: ?ValueSegment = null,
    replace_start: usize = 0,
    replace_end: usize = 0,
};

pub const OptionValue = struct {
    name: []const u8,
    spelling: []const u8,
    value_index: usize = 0,
    from: ?[]const u8 = null,
    from_offset: ?usize = null,

    pub fn displaySpelling(self: OptionValue, buffer: *[2]u8) []const u8 {
        if (self.from_offset) |offset| {
            if (self.from) |from| {
                if (offset < from.len) {
                    buffer[0] = '-';
                    buffer[1] = from[offset];
                    return buffer[0..2];
                }
            }
        }
        return self.spelling;
    }
};

pub const ParsedOption = struct {
    spelling: []const u8,
    name: []const u8,
    key: []const u8,
    value: ?[]const u8 = null,
    from: ?[]const u8 = null,
    from_offset: ?usize = null,
    exclusive_group: ?[]const u8 = null,
    excludes: []const OptionExclusion = &.{},
    repeatable: bool = false,
    terminates_options: bool = false,

    pub fn displaySpelling(self: ParsedOption, buffer: *[2]u8) []const u8 {
        if (self.from_offset) |offset| {
            if (self.from) |from| {
                if (offset < from.len) {
                    buffer[0] = '-';
                    buffer[1] = from[offset];
                    return buffer[0..2];
                }
            }
        }
        return self.spelling;
    }
};

pub const ParsedOperand = struct {
    value: []const u8,
    index: usize,
    state: ?[]const u8 = null,
    after_terminator: bool = false,
    rest_command_line: bool = false,
};

pub const OptionSuppressionReason = enum {
    already_present,
    exclusive_group,
    excluded,
};

pub const OptionSuppression = struct {
    reason: OptionSuppressionReason,
    by: []const u8,
    group: ?[]const u8 = null,
    exclusion: ?[]const u8 = null,
};

pub const ValuePosition = enum {
    item,
    key,
    value,
};

pub const ValueSegment = struct {
    segment: []const u8,
    list_separator: ?u8 = null,
    key_value_separator: ?u8 = null,
    position: ValuePosition = .item,
    key: []const u8 = "",

    pub fn activeSeparator(self: ValueSegment) ?u8 {
        return switch (self.position) {
            .value => self.key_value_separator orelse self.list_separator,
            .item, .key => self.list_separator,
        };
    }
};

pub const SemanticPosition = enum {
    command,
    subcommand,
    option,
    option_value,
    redirect_target,
    argument,
};

pub const SemanticContext = struct {
    allocator: std.mem.Allocator,
    root: []const u8 = "",
    path: []const []const u8 = &.{},
    prefix: []const u8 = "",
    expand_tilde: bool = false,
    argument_index: usize = 0,
    argument_state: ?[]const u8 = null,
    parsed_options: []const ParsedOption = &.{},
    operands: []const ParsedOperand = &.{},
    options_terminated: bool = false,
    previous: []const u8 = "",
    position: SemanticPosition = .command,
    option_value: ?OptionValue = null,
    value_segment: ?ValueSegment = null,
    replace_start: usize = 0,
    replace_end: usize = 0,
    suspicious_start: ?usize = null,
    suspicious_end: ?usize = null,
    parser_position: parser.CompletionKind = .command,
    parser_source_offset: usize = 0,
    precommand_start: ?usize = null,

    pub fn deinit(self: *SemanticContext) void {
        self.allocator.free(self.path);
        self.allocator.free(self.parsed_options);
        self.allocator.free(self.operands);
        self.* = undefined;
    }
};

pub const DiagnosticSeverity = enum {
    warning,
    err,
};

pub const DiagnosticKind = enum {
    unknown_command,
    unknown_subcommand,
    unknown_option,
    missing_option_value,
    repeated_option,
    conflicting_option,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    severity: DiagnosticSeverity,
    start: usize,
    end: usize,
    message: []const u8,
};

pub const ProviderDiagnostic = struct {
    function: []const u8,
    command: []const u8,
    status: ?u8 = null,
    err: ?[]const u8 = null,
    stderr: []const u8 = "",
};

pub const ProviderFunction = struct {
    body: []const u8,
    redirections: []const ir.Redirection = &.{},
};

pub const VariantPattern = struct {
    name: []const u8,
    pattern: []const u8,
};

pub const ManifestCommandState = struct {
    command: []const u8,
    manifest_path: ?[]const u8 = null,
    manifest_version: ?i64 = null,
    platform: []const u8,
    platform_allowed: bool,
};

pub const VariantProbeState = struct {
    command: []const u8,
    args: []const []const u8,
    patterns: []const VariantPattern,
    selected: ?[]const u8 = null,
    probed: bool = false,
    last_probed: bool = false,
    last_cached: bool = false,
    skipped_shadow: bool = false,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,
    generation: u64 = 0,
    provider_diagnostics: std.ArrayList(ProviderDiagnostic) = .empty,
    provider_functions: std.StringHashMapUnmanaged(ProviderFunction) = .empty,
    manifest_commands: std.ArrayList(ManifestCommandState) = .empty,
    variant_probes: std.ArrayList(VariantProbeState) = .empty,
    variant_probe_mocks: std.StringHashMapUnmanaged([]const u8) = .empty,
    variant_probe_counts: std.StringHashMapUnmanaged(usize) = .empty,
    loaded_scripts: std.StringHashMapUnmanaged(void) = .empty,
    loaded_companions: std.StringHashMapUnmanaged(void) = .empty,
    last_trace_path: ?[]const []const u8 = null,
    last_semantic: ?SemanticContext = null,
    last_precommand_depth_limited: bool = false,
    last_context: ?EvalContext = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        for (self.rules.items) |rule| freeRule(self.allocator, rule);
        self.rules.deinit(self.allocator);
        self.clearProviderDiagnostics();
        self.provider_diagnostics.deinit(self.allocator);
        var provider_function_iter = self.provider_functions.iterator();
        while (provider_function_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeProviderFunction(self.allocator, entry.value_ptr.*);
        }
        self.provider_functions.deinit(self.allocator);
        for (self.manifest_commands.items) |state| freeManifestCommandState(self.allocator, state);
        self.manifest_commands.deinit(self.allocator);
        for (self.variant_probes.items) |state| freeVariantProbeState(self.allocator, state);
        self.variant_probes.deinit(self.allocator);
        var probe_mock_iter = self.variant_probe_mocks.iterator();
        while (probe_mock_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.variant_probe_mocks.deinit(self.allocator);
        var probe_count_iter = self.variant_probe_counts.iterator();
        while (probe_count_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.variant_probe_counts.deinit(self.allocator);
        var loaded_script_iter = self.loaded_scripts.iterator();
        while (loaded_script_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.loaded_scripts.deinit(self.allocator);
        var loaded_companion_iter = self.loaded_companions.iterator();
        while (loaded_companion_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.loaded_companions.deinit(self.allocator);
        self.clearLastTrace();
        self.* = undefined;
    }

    pub fn copyFrom(self: *State, other: *const State) !void {
        for (other.rules.items) |rule| try self.registerRule(rule);
        var provider_function_iter = other.provider_functions.iterator();
        while (provider_function_iter.next()) |entry| try self.registerProviderFunction(
            entry.key_ptr.*,
            entry.value_ptr.*.body,
            entry.value_ptr.*.redirections,
        );
        for (other.manifest_commands.items) |state| try self.registerManifestCommandState(state);
        for (other.variant_probes.items) |probe| {
            try self.registerVariantProbe(probe.command, probe.args, probe.patterns);
            if (self.variant_probes.items.len != 0) {
                var copied = &self.variant_probes.items[self.variant_probes.items.len - 1];
                copied.probed = probe.probed;
                copied.last_probed = probe.last_probed;
                copied.last_cached = probe.last_cached;
                copied.skipped_shadow = probe.skipped_shadow;
                if (probe.selected) |selected| copied.selected = try self.allocator.dupe(u8, selected);
            }
        }
        var mock_iter = other.variant_probe_mocks.iterator();
        while (mock_iter.next()) |entry| try self.setVariantProbeMock(entry.key_ptr.*, entry.value_ptr.*);
        var count_iter = other.variant_probe_counts.iterator();
        while (count_iter.next()) |entry| {
            const owned_command = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(owned_command);
            try self.variant_probe_counts.put(self.allocator, owned_command, entry.value_ptr.*);
        }
        var loaded_script_iter = other.loaded_scripts.iterator();
        while (loaded_script_iter.next()) |entry| try self.markLoadedScript(entry.key_ptr.*);
        var loaded_companion_iter = other.loaded_companions.iterator();
        while (loaded_companion_iter.next()) |entry| try self.markLoadedCompanion(entry.key_ptr.*);
        self.last_context = other.last_context;
        self.generation = other.generation;
    }

    pub fn registerRule(self: *State, rule: Rule) !void {
        var owned_rule: Rule = .{
            .root = try self.allocator.dupe(u8, rule.root),
            .kind = rule.kind,
            .value = if (rule.value) |value| try self.allocator.dupe(u8, value) else null,
            .priority = rule.priority,
            .provider_kind = rule.provider_kind,
            .option = .{
                .long = if (rule.option.long) |long| try self.allocator.dupe(u8, long) else null,
                .short = if (rule.option.short) |short| try self.allocator.dupe(u8, short) else null,
                .spellings = try cloneStringSlice(self.allocator, rule.option.spellings),
                .argument = if (rule.option.argument) |argument| try self.allocator.dupe(u8, argument) else null,
                .value_count = rule.option.value_count,
                .exclusive_group = if (rule.option.exclusive_group) |group|
                    try self.allocator.dupe(u8, group)
                else
                    null,
                .excludes = try cloneOptionExclusions(self.allocator, rule.option.excludes),
                .repeatable = rule.option.repeatable,
                .terminates_options = rule.option.terminates_options,
                .no_space = rule.option.no_space,
                .inherit = rule.option.inherit,
            },
            .argument = .{
                .state = if (rule.argument.state) |state| try self.allocator.dupe(u8, state) else null,
                .index = rule.argument.index,
                .after_state = if (rule.argument.after_state) |state| try self.allocator.dupe(u8, state) else null,
                .after_value = if (rule.argument.after_value) |value| try self.allocator.dupe(u8, value) else null,
                .repeatable = rule.argument.repeatable,
                .rest_command_line = rule.argument.rest_command_line,
                .when_condition = try cloneArgumentCondition(self.allocator, rule.argument.when_condition),
                .after_condition = try cloneArgumentCondition(self.allocator, rule.argument.after_condition),
                .until_condition = try cloneArgumentCondition(self.allocator, rule.argument.until_condition),
                .require_option_values = try cloneOptionValueConditions(
                    self.allocator,
                    rule.argument.require_option_values,
                ),
                .reject_option_values = try cloneOptionValueConditions(
                    self.allocator,
                    rule.argument.reject_option_values,
                ),
            },
            .value_index = rule.value_index,
            .value_grammar = rule.value_grammar,
            .description = if (rule.description) |description| try self.allocator.dupe(u8, description) else null,
            .tag = if (rule.tag) |tag| try self.allocator.dupe(u8, tag) else null,
            .provider_order = rule.provider_order,
            .source = .{
                .kind = rule.source.kind,
                .manifest_path = if (rule.source.manifest_path) |path| try self.allocator.dupe(u8, path) else null,
                .manifest_version = rule.source.manifest_version,
                .companion_path = if (rule.source.companion_path) |path| try self.allocator.dupe(u8, path) else null,
            },
            .variant = if (rule.variant) |variant| try self.allocator.dupe(u8, variant) else null,
            .disabled = rule.disabled,
        };
        errdefer freeRule(self.allocator, owned_rule);
        owned_rule.static_values = try cloneStaticProviderValues(self.allocator, rule.static_values);
        var path: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (path.items) |segment| self.allocator.free(segment);
            path.deinit(self.allocator);
        }
        for (rule.path) |segment| try path.append(self.allocator, try self.allocator.dupe(u8, segment));
        owned_rule.path = try path.toOwnedSlice(self.allocator);
        try self.rules.append(self.allocator, owned_rule);
        self.generation +%= 1;
    }

    pub fn rulesSlice(self: State) []const Rule {
        return self.rules.items;
    }

    pub fn generationValue(self: State) u64 {
        return self.generation;
    }

    pub fn providerDiagnostics(self: State) []const ProviderDiagnostic {
        return self.provider_diagnostics.items;
    }

    pub fn registerProviderFunction(
        self: *State,
        name: []const u8,
        body: []const u8,
        redirections: []const ir.Redirection,
    ) !void {
        std.debug.assert(name.len != 0);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_function: ProviderFunction = .{
            .body = try self.allocator.dupe(u8, body),
            .redirections = try cloneProviderFunctionRedirections(self.allocator, redirections),
        };
        errdefer freeProviderFunction(self.allocator, owned_function);
        const result = try self.provider_functions.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            freeProviderFunction(self.allocator, result.value_ptr.*);
        }
        result.value_ptr.* = owned_function;
    }

    pub fn providerFunction(self: State, name: []const u8) ?ProviderFunction {
        return self.provider_functions.get(name);
    }

    pub fn lastContext(self: State) ?EvalContext {
        return self.last_context;
    }

    pub fn registerManifestCommandState(self: *State, state: ManifestCommandState) !void {
        const owned: ManifestCommandState = .{
            .command = try self.allocator.dupe(u8, state.command),
            .manifest_path = if (state.manifest_path) |path| try self.allocator.dupe(u8, path) else null,
            .manifest_version = state.manifest_version,
            .platform = try self.allocator.dupe(u8, state.platform),
            .platform_allowed = state.platform_allowed,
        };
        errdefer freeManifestCommandState(self.allocator, owned);
        for (self.manifest_commands.items) |*existing| {
            if (!std.mem.eql(u8, existing.command, state.command)) continue;
            freeManifestCommandState(self.allocator, existing.*);
            existing.* = owned;
            return;
        }
        try self.manifest_commands.append(self.allocator, owned);
    }

    pub fn manifestCommandState(self: State, command: []const u8) ?ManifestCommandState {
        for (self.manifest_commands.items) |state| {
            if (std.mem.eql(u8, state.command, command)) return state;
        }
        return null;
    }

    pub fn registerVariantProbe(
        self: *State,
        command: []const u8,
        args: []const []const u8,
        patterns: []const VariantPattern,
    ) !void {
        var owned_args = try self.allocator.alloc([]const u8, args.len);
        var owned_arg_count: usize = 0;
        var owned_args_transferred = false;
        errdefer {
            if (!owned_args_transferred) {
                for (owned_args[0..owned_arg_count]) |arg| self.allocator.free(arg);
                self.allocator.free(owned_args);
            }
        }
        for (args, 0..) |arg, index| {
            owned_args[index] = try self.allocator.dupe(u8, arg);
            owned_arg_count += 1;
        }
        var owned_patterns = try self.allocator.alloc(VariantPattern, patterns.len);
        var owned_pattern_count: usize = 0;
        var owned_patterns_transferred = false;
        errdefer {
            if (!owned_patterns_transferred) {
                for (owned_patterns[0..owned_pattern_count]) |pattern| {
                    self.allocator.free(pattern.name);
                    self.allocator.free(pattern.pattern);
                }
                self.allocator.free(owned_patterns);
            }
        }
        for (patterns, 0..) |pattern, index| {
            owned_patterns[index] = .{
                .name = try self.allocator.dupe(u8, pattern.name),
                .pattern = try self.allocator.dupe(u8, pattern.pattern),
            };
            owned_pattern_count += 1;
        }
        const state: VariantProbeState = .{
            .command = try self.allocator.dupe(u8, command),
            .args = owned_args,
            .patterns = owned_patterns,
        };
        owned_args_transferred = true;
        owned_patterns_transferred = true;
        errdefer freeVariantProbeState(self.allocator, state);
        for (self.variant_probes.items) |*existing| {
            if (!std.mem.eql(u8, existing.command, command)) continue;
            freeVariantProbeState(self.allocator, existing.*);
            existing.* = state;
            return;
        }
        try self.variant_probes.append(self.allocator, state);
    }

    pub fn variantProbeState(self: State, command: []const u8) ?VariantProbeState {
        for (self.variant_probes.items) |state| {
            if (std.mem.eql(u8, state.command, command)) return state;
        }
        return null;
    }

    pub fn setVariantProbeMock(self: *State, command: []const u8, output: []const u8) !void {
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        const owned_output = try self.allocator.dupe(u8, output);
        errdefer self.allocator.free(owned_output);
        const result = try self.variant_probe_mocks.getOrPut(self.allocator, owned_command);
        if (result.found_existing) {
            self.allocator.free(owned_command);
            self.allocator.free(result.value_ptr.*);
        }
        result.value_ptr.* = owned_output;
    }

    pub fn variantProbeCount(self: State, command: []const u8) usize {
        return self.variant_probe_counts.get(command) orelse 0;
    }

    pub fn incrementVariantProbeCount(self: *State, command: []const u8) !void {
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        const result = try self.variant_probe_counts.getOrPut(self.allocator, owned_command);
        if (result.found_existing) {
            self.allocator.free(owned_command);
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
    }

    pub fn applyVariantSelection(self: *State, root: []const u8, selected: ?[]const u8) void {
        for (self.rules.items) |*rule| {
            if (!std.mem.eql(u8, rule.root, root)) continue;
            const variant = rule.variant orelse continue;
            rule.disabled = if (selected) |name| !std.mem.eql(u8, variant, name) else true;
        }
        self.generation +%= 1;
    }

    pub fn loadedScript(self: State, root: []const u8) bool {
        return self.loaded_scripts.contains(root);
    }

    pub fn markLoadedScript(self: *State, root: []const u8) !void {
        const owned_root = try self.allocator.dupe(u8, root);
        errdefer self.allocator.free(owned_root);
        const result = try self.loaded_scripts.getOrPut(self.allocator, owned_root);
        if (result.found_existing) self.allocator.free(owned_root);
    }

    pub fn loadedCompanion(self: State, path: []const u8) bool {
        return self.loaded_companions.contains(path);
    }

    pub fn markLoadedCompanion(self: *State, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const result = try self.loaded_companions.getOrPut(self.allocator, owned_path);
        if (result.found_existing) self.allocator.free(owned_path);
    }

    pub fn clearProviderDiagnostics(self: *State) void {
        for (self.provider_diagnostics.items) |diagnostic| {
            self.allocator.free(diagnostic.function);
            self.allocator.free(diagnostic.command);
            if (diagnostic.err) |err| self.allocator.free(err);
            self.allocator.free(diagnostic.stderr);
        }
        self.provider_diagnostics.clearRetainingCapacity();
    }

    pub fn appendProviderDiagnostic(
        self: *State,
        function: []const u8,
        command: []const u8,
        status: ?u8,
        err: ?anyerror,
        stderr: []const u8,
    ) !void {
        const owned_function = try self.allocator.dupe(u8, function);
        errdefer self.allocator.free(owned_function);
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        const owned_err = if (err) |provider_err| try self.allocator.dupe(u8, @errorName(provider_err)) else null;
        errdefer if (owned_err) |err_name| self.allocator.free(err_name);
        const owned_stderr = try self.allocator.dupe(u8, stderr);
        errdefer self.allocator.free(owned_stderr);
        try self.provider_diagnostics.append(self.allocator, .{
            .function = owned_function,
            .command = owned_command,
            .status = status,
            .err = owned_err,
            .stderr = owned_stderr,
        });
    }

    pub fn lastTracePath(self: State) ?[]const []const u8 {
        return self.last_trace_path;
    }

    pub fn lastSemantic(self: State) ?SemanticContext {
        return self.last_semantic;
    }

    pub fn lastPrecommandDepthLimited(self: State) bool {
        return self.last_precommand_depth_limited;
    }

    pub fn clearLastTrace(self: *State) void {
        if (self.last_trace_path) |path| self.allocator.free(path);
        self.last_trace_path = null;
        if (self.last_semantic) |*semantic| semantic.deinit();
        self.last_semantic = null;
        self.last_precommand_depth_limited = false;
    }

    pub fn storeLastSemantic(self: *State, semantic: SemanticContext) !void {
        if (self.last_semantic) |*stored| stored.deinit();
        self.last_semantic = null;
        const owned_path = try self.allocator.dupe([]const u8, semantic.path);
        errdefer self.allocator.free(owned_path);
        const owned_parsed_options = try self.allocator.dupe(ParsedOption, semantic.parsed_options);
        errdefer self.allocator.free(owned_parsed_options);
        const owned_operands = try self.allocator.dupe(ParsedOperand, semantic.operands);
        errdefer self.allocator.free(owned_operands);
        self.last_semantic = .{
            .allocator = self.allocator,
            .root = semantic.root,
            .path = owned_path,
            .parsed_options = owned_parsed_options,
            .operands = owned_operands,
            .options_terminated = semantic.options_terminated,
            .prefix = semantic.prefix,
            .expand_tilde = semantic.expand_tilde,
            .argument_index = semantic.argument_index,
            .argument_state = semantic.argument_state,
            .previous = semantic.previous,
            .position = semantic.position,
            .option_value = semantic.option_value,
            .value_segment = semantic.value_segment,
            .replace_start = semantic.replace_start,
            .replace_end = semantic.replace_end,
            .suspicious_start = semantic.suspicious_start,
            .suspicious_end = semantic.suspicious_end,
            .parser_position = semantic.parser_position,
            .parser_source_offset = semantic.parser_source_offset,
            .precommand_start = semantic.precommand_start,
        };
    }

    pub fn offsetLastSemantic(self: *State, offset: usize) void {
        const semantic = if (self.last_semantic) |*stored| stored else return;
        semantic.replace_start += offset;
        semantic.replace_end += offset;
        if (semantic.suspicious_start) |start| semantic.suspicious_start = start + offset;
        if (semantic.suspicious_end) |end| semantic.suspicious_end = end + offset;
        semantic.parser_source_offset += offset;
        if (semantic.precommand_start) |start| semantic.precommand_start = start + offset;
    }

    pub fn storeLastTracePath(self: *State, root: []const u8, path: []const []const u8) !void {
        if (self.last_trace_path) |existing| self.allocator.free(existing);
        self.last_trace_path = null;
        const owned = try self.allocator.alloc([]const u8, 1 + path.len);
        owned[0] = root;
        @memcpy(owned[1..], path);
        self.last_trace_path = owned;
    }

    pub fn storeCombinedLastTracePath(self: *State, outer: SemanticContext, inner: []const []const u8) !void {
        const owned = try self.allocator.alloc([]const u8, 1 + outer.path.len + inner.len);
        errdefer self.allocator.free(owned);
        owned[0] = outer.root;
        @memcpy(owned[1 .. 1 + outer.path.len], outer.path);
        @memcpy(owned[1 + outer.path.len ..], inner);
        if (self.last_trace_path) |existing| self.allocator.free(existing);
        self.last_trace_path = owned;
    }
};

pub fn applyCandidatesForInput(
    allocator: std.mem.Allocator,
    source: []const u8,
    candidates: []const Candidate,
) !Application {
    return applyCandidatesForInputWithPolicy(allocator, source, candidates, .engineDefault());
}

pub fn applyCandidatesForInputWithPolicy(
    allocator: std.mem.Allocator,
    source: []const u8,
    candidates: []const Candidate,
    policy: MatcherPolicy,
) !Application {
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
            const replacement = try candidateReplacementAndSuffixForInput(allocator, source, candidate);
            insert_candidate.insert = replacement.text;
            insert_candidate.suffix = replacement.suffix;
            errdefer allocator.free(insert_candidate.insert.?);
            errdefer if (insert_candidate.suffix) |suffix| allocator.free(suffix);
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

pub fn rootForCompletion(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !?[]const u8 {
    var parse_result = try parser.parse(allocator, source, .{});
    defer parse_result.deinit();
    var program = try ir.lowerSimpleCommands(allocator, parse_result);
    defer program.deinit();

    var selected: ?ir.SimpleCommand = null;
    for (program.commands) |command| {
        if (command.argv.len == 0) continue;
        if (command.span.start > cursor) continue;
        selected = command;
        if (cursor <= command.span.end) break;
    }
    const command = selected orelse return null;
    return try allocator.dupe(u8, command.argv[0].text);
}

pub fn loadManifestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *State,
    path: []const u8,
) !void {
    if (state.loadedCompanion(path)) return;
    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();
    const root_object = jsonObject(parsed.value) orelse return error.InvalidCompletionManifest;
    const version = jsonInteger(root_object.get("manifestVersion") orelse return error.InvalidCompletionManifest) orelse
        return error.InvalidCompletionManifest;
    const command_value = root_object.get("command") orelse return error.InvalidCompletionManifest;
    const command_object = jsonObject(command_value) orelse return error.InvalidCompletionManifest;
    const providers = if (command_object.get("providers")) |providers_value| jsonObject(providers_value) else null;
    const root_name = commandPrimaryName(command_object) orelse return error.InvalidCompletionManifest;
    const platform = comptime @tagName(builtin_os);
    try state.registerManifestCommandState(.{
        .command = root_name,
        .manifest_path = path,
        .manifest_version = version,
        .platform = platform,
        .platform_allowed = true,
    });

    var path_stack: std.ArrayList([]const u8) = .empty;
    defer path_stack.deinit(allocator);
    try registerManifestCommand(allocator, state, root_name, command_object, providers, &path_stack, .{
        .kind = .manifest,
        .manifest_path = path,
        .manifest_version = version,
    });
    try state.markLoadedCompanion(path);
}

pub fn manifestApplication(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: *State,
    shell_state: shell_state_mod.ShellState,
    source: []const u8,
    cursor: usize,
) !Application {
    var parse_result = try parser.parse(allocator, source, .{});
    defer parse_result.deinit();
    const parser_context = parser.completionContext(parse_result, cursor);
    var program = try ir.lowerSimpleCommands(allocator, parse_result);
    defer program.deinit();

    const command = commandForCompletion(program, cursor) orelse return .none;
    if (command.argv.len == 0) return .none;
    const root = command.argv[0].text;
    if (state.manifestCommandState(root) == null) return .none;

    var semantic = try semanticContextForCommand(allocator, state.*, command, parser_context, source, cursor);
    defer semantic.deinit();
    defer allocator.free(semantic.prefix);

    var builder: Builder = .{};
    errdefer builder.deinit(allocator);
    var handled = false;
    switch (semantic.position) {
        .subcommand => {
            handled = true;
            try appendManifestSubcommands(allocator, io, state.*, shell_state, &builder, semantic);
        },
        .option => {
            handled = true;
            try appendManifestOptions(allocator, io, state.*, shell_state, &builder, semantic);
        },
        .option_value, .argument => handled = try appendManifestValueProviders(
            allocator,
            io,
            state.*,
            shell_state,
            &builder,
            semantic,
        ),
        .command, .redirect_target => {},
    }
    const candidates = try builder.finish(allocator);
    defer freeCandidates(allocator, candidates);
    const application = try applyCandidatesForInputWithPolicy(allocator, source, candidates, .engineDefault());
    return switch (application) {
        .none => if (handled) try emptyAmbiguousApplication(allocator) else .none,
        .edit, .ambiguous => application,
    };
}

fn emptyAmbiguousApplication(allocator: std.mem.Allocator) !Application {
    return .{ .ambiguous = try allocator.alloc(Candidate, 0) };
}

const builtin_os = @import("builtin").os.tag;

fn commandForCompletion(program: ir.Program, cursor: usize) ?ir.SimpleCommand {
    var selected: ?ir.SimpleCommand = null;
    for (program.commands) |command| {
        if (command.argv.len == 0) continue;
        if (command.span.start > cursor) continue;
        selected = command;
        if (cursor <= command.span.end) break;
    }
    return selected;
}

fn semanticContextForCommand(
    allocator: std.mem.Allocator,
    state: State,
    command: ir.SimpleCommand,
    parser_context: parser.CompletionContext,
    source: []const u8,
    cursor: usize,
) !SemanticContext {
    const replace_start = parser_context.span.start;
    const replace_end = parser_context.span.end;
    const prefix = try decodeShellCompletionSlice(allocator, source, replace_start, replace_end);
    errdefer allocator.free(prefix);

    var path: std.ArrayList([]const u8) = .empty;
    errdefer path.deinit(allocator);
    var parsed_options: std.ArrayList(ParsedOption) = .empty;
    errdefer parsed_options.deinit(allocator);
    var operands: std.ArrayList(ParsedOperand) = .empty;
    errdefer operands.deinit(allocator);
    var operand_index: usize = 0;
    var options_terminated = false;
    var current_is_option = false;
    var pending_option_value: ?OptionValue = null;
    var pending_option_index: ?usize = null;
    for (command.argv[1..]) |word| {
        if (word.span.start >= cursor) break;
        if (pending_option_value != null) {
            if (cursor <= word.span.end) break;
            if (pending_option_index) |index| parsed_options.items[index].value = word.text;
            pending_option_value = null;
            pending_option_index = null;
            continue;
        }
        if (cursor <= word.span.end) {
            current_is_option = std.mem.startsWith(u8, word.text, "-") and !options_terminated;
            break;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            if (manifestOptionRuleForWord(state, command.argv[0].text, path.items, word.text)) |rule| {
                const name = optionName(rule.option);
                try parsed_options.append(allocator, .{
                    .spelling = optionSpelling(rule.option, word.text),
                    .name = name,
                    .key = name,
                    .repeatable = rule.option.repeatable,
                    .terminates_options = rule.option.terminates_options,
                    .exclusive_group = rule.option.exclusive_group,
                    .excludes = rule.option.excludes,
                });
                if (rule.option.terminates_options) options_terminated = true;
                if (rule.option.value_count != 0) {
                    pending_option_value = optionValueForRule(rule, word.text);
                    pending_option_index = parsed_options.items.len - 1;
                }
            }
            continue;
        }
        if (path.items.len == 0) {
            try path.append(allocator, word.text);
        } else {
            try operands.append(allocator, .{ .value = word.text, .index = operand_index });
            operand_index += 1;
        }
    }

    const position: SemanticPosition = if (current_is_option)
        .option
    else if (pending_option_value != null)
        .option_value
    else if (parser_context.kind == .redirect_target)
        .redirect_target
    else if (path.items.len == 0 and manifestHasSubcommands(state, command.argv[0].text))
        .subcommand
    else
        .argument;

    const owned_path = try path.toOwnedSlice(allocator);
    errdefer allocator.free(owned_path);
    const owned_parsed_options = try parsed_options.toOwnedSlice(allocator);
    errdefer allocator.free(owned_parsed_options);
    const owned_operands = try operands.toOwnedSlice(allocator);
    errdefer allocator.free(owned_operands);

    return .{
        .allocator = allocator,
        .root = command.argv[0].text,
        .path = owned_path,
        .prefix = prefix,
        .expand_tilde = shellCompletionContext(source, replace_start).quote == .unquoted,
        .argument_index = operand_index,
        .parsed_options = owned_parsed_options,
        .operands = owned_operands,
        .options_terminated = options_terminated,
        .position = position,
        .option_value = pending_option_value,
        .replace_start = replace_start,
        .replace_end = replace_end,
        .parser_position = parser_context.kind,
    };
}

fn manifestHasSubcommands(state: State, root: []const u8) bool {
    for (state.rules.items) |rule| {
        if (rule.disabled or rule.kind != .subcommand) continue;
        if (std.mem.eql(u8, rule.root, root)) return true;
    }
    return false;
}

fn manifestOptionRuleForWord(
    state: State,
    root: []const u8,
    path: []const []const u8,
    word: []const u8,
) ?Rule {
    for (state.rules.items) |rule| {
        if (rule.disabled or rule.kind != .option) continue;
        if (!ruleMatchesPath(rule, root, path)) continue;
        if (optionMatchesWord(rule.option, word)) return rule;
    }
    return null;
}

fn optionMatchesWord(option: Option, word: []const u8) bool {
    if (option.long) |long| {
        if (word.len == long.len + 2 and std.mem.startsWith(u8, word, "--") and
            std.mem.eql(u8, word[2..], long)) return true;
    }
    if (option.short) |short| {
        if (word.len == short.len + 1 and word[0] == '-' and std.mem.eql(u8, word[1..], short)) return true;
    }
    for (option.spellings) |spelling| {
        if (std.mem.eql(u8, word, spelling)) return true;
    }
    return false;
}

fn optionValueForRule(rule: Rule, word: []const u8) OptionValue {
    return .{
        .name = optionName(rule.option),
        .spelling = optionSpelling(rule.option, word),
        .value_index = 0,
    };
}

fn optionName(option: Option) []const u8 {
    if (option.long) |long| return long;
    if (option.short) |short| return short;
    if (option.spellings.len != 0) return option.spellings[0];
    return "";
}

fn optionSpelling(option: Option, word: []const u8) []const u8 {
    if (option.long) |long| {
        if (word.len == long.len + 2 and std.mem.startsWith(u8, word, "--") and
            std.mem.eql(u8, word[2..], long)) return word;
    }
    if (option.short) |short| {
        if (word.len == short.len + 1 and word[0] == '-' and std.mem.eql(u8, word[1..], short)) return word;
    }
    for (option.spellings) |spelling| {
        if (std.mem.eql(u8, word, spelling)) return spelling;
    }
    return word;
}

fn appendManifestSubcommands(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: State,
    shell_state: shell_state_mod.ShellState,
    builder: *Builder,
    semantic: SemanticContext,
) !void {
    for (state.rules.items) |rule| {
        if (rule.disabled or rule.kind != .subcommand) continue;
        if (!ruleMatchesPath(rule, semantic.root, semantic.path)) continue;
        const value = rule.value orelse continue;
        try builder.appendCandidateIfMissing(allocator, .{
            .value = value,
            .description = rule.description,
            .priority = rule.priority,
            .kind = .subcommand,
            .replace_start = semantic.replace_start,
            .replace_end = semantic.replace_end,
            .provider_order = rule.provider_order,
        });
    }
    for (state.rules.items) |rule| {
        if (rule.disabled or rule.kind != .dynamic_subcommands) continue;
        if (!ruleMatchesPath(rule, semantic.root, semantic.path)) continue;
        try appendProviderCandidates(allocator, io, shell_state, builder, rule, semantic);
    }
}

fn appendManifestOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: State,
    shell_state: shell_state_mod.ShellState,
    builder: *Builder,
    semantic: SemanticContext,
) !void {
    for (state.rules.items) |rule| {
        if (rule.disabled) continue;
        if (!ruleMatchesPath(rule, semantic.root, semantic.path)) continue;
        switch (rule.kind) {
            .option => try appendOptionCandidate(allocator, builder, rule, semantic),
            .dynamic_options => try appendProviderCandidates(allocator, io, shell_state, builder, rule, semantic),
            else => {},
        }
    }
}

fn appendOptionCandidate(
    allocator: std.mem.Allocator,
    builder: *Builder,
    rule: Rule,
    semantic: SemanticContext,
) !void {
    if (rule.option.long) |long| {
        const spelling = try std.fmt.allocPrint(allocator, "--{s}", .{long});
        defer allocator.free(spelling);
        try builder.appendCandidateIfMissing(allocator, optionCandidate(rule, spelling, semantic));
    }
    if (rule.option.short) |short| {
        const spelling = try std.fmt.allocPrint(allocator, "-{s}", .{short});
        defer allocator.free(spelling);
        try builder.appendCandidateIfMissing(allocator, optionCandidate(rule, spelling, semantic));
    }
    for (rule.option.spellings) |spelling| try builder.appendCandidateIfMissing(
        allocator,
        optionCandidate(rule, spelling, semantic),
    );
}

fn optionCandidate(rule: Rule, spelling: []const u8, semantic: SemanticContext) Candidate {
    return .{
        .value = spelling,
        .description = rule.description,
        .priority = rule.priority,
        .kind = .option,
        .option = rule.option,
        .replace_start = semantic.replace_start,
        .replace_end = semantic.replace_end,
        .append_space = true,
        .provider_order = rule.provider_order,
    };
}

fn appendManifestValueProviders(
    allocator: std.mem.Allocator,
    io: std.Io,
    state: State,
    shell_state: shell_state_mod.ShellState,
    builder: *Builder,
    semantic: SemanticContext,
) !bool {
    var handled = false;
    switch (semantic.position) {
        .option_value => {
            const option_value = semantic.option_value orelse return false;
            for (state.rules.items) |rule| {
                if (rule.disabled or rule.kind != .dynamic_option_value) continue;
                if (!ruleMatchesPath(rule, semantic.root, semantic.path)) continue;
                if (!optionRuleMatchesValue(rule.option, option_value)) continue;
                if (rule.value_index != option_value.value_index) continue;
                handled = true;
                try appendProviderCandidates(allocator, io, shell_state, builder, rule, semantic);
            }
        },
        .argument => for (state.rules.items) |rule| {
            if (rule.disabled or rule.kind != .dynamic_argument) continue;
            if (!ruleMatchesPath(rule, semantic.root, semantic.path)) continue;
            if (!argumentRuleMatches(rule.argument, semantic.argument_index)) continue;
            handled = true;
            try appendProviderCandidates(allocator, io, shell_state, builder, rule, semantic);
        },
        else => {},
    }
    return handled;
}

fn optionRuleMatchesValue(option: Option, value: OptionValue) bool {
    if (option.long) |long| {
        if (std.mem.eql(u8, value.name, long)) return true;
        if (value.spelling.len == long.len + 2 and std.mem.startsWith(u8, value.spelling, "--") and
            std.mem.eql(u8, value.spelling[2..], long)) return true;
    }
    if (option.short) |short| {
        if (std.mem.eql(u8, value.name, short)) return true;
        if (value.spelling.len == short.len + 1 and value.spelling[0] == '-' and
            std.mem.eql(u8, value.spelling[1..], short)) return true;
    }
    for (option.spellings) |spelling| {
        if (std.mem.eql(u8, value.spelling, spelling)) return true;
    }
    return false;
}

fn appendProviderCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: shell_state_mod.ShellState,
    builder: *Builder,
    rule: Rule,
    semantic: SemanticContext,
) !void {
    switch (rule.provider_kind) {
        .static_enum => for (rule.static_values, 0..) |value, source_order| {
            try builder.appendCandidateIfMissing(allocator, .{
                .value = value.value,
                .display = value.display,
                .description = value.description orelse rule.description,
                .tag = value.tag orelse rule.tag,
                .suffix = value.suffix,
                .removable_suffix = value.removable_suffix,
                .priority = value.priority,
                .kind = .plain,
                .replace_start = semantic.replace_start,
                .replace_end = semantic.replace_end,
                .append_space = value.append_space,
                .provider_order = rule.provider_order,
                .source_order = source_order,
            });
        },
        .builtin_files => {
            const candidates = try pathCandidatesWithOptions(
                allocator,
                io,
                semantic.prefix,
                semantic.replace_start,
                semantic.replace_end,
                .{ .expand_tilde = semantic.expand_tilde },
                shell_state.envLookup(),
            );
            defer freeCandidates(allocator, candidates);
            for (candidates) |candidate| try builder.appendCandidateIfMissing(allocator, candidate);
        },
        .builtin_directories => {
            const candidates = try pathCandidatesWithOptions(
                allocator,
                io,
                semantic.prefix,
                semantic.replace_start,
                semantic.replace_end,
                .{ .directories_only = true, .expand_tilde = semantic.expand_tilde },
                shell_state.envLookup(),
            );
            defer freeCandidates(allocator, candidates);
            for (candidates) |candidate| try builder.appendCandidateIfMissing(allocator, candidate);
        },
        .builtin_executables => {
            const candidates = try commandCandidates(
                allocator,
                io,
                shell_state,
                semantic.replace_start,
                semantic.replace_end,
            );
            defer freeCandidates(allocator, candidates);
            for (candidates) |candidate| try builder.appendCandidateIfMissing(allocator, candidate);
        },
        .builtin_variables => {
            var variable_iter = shell_state.variables.iterator();
            while (variable_iter.next()) |entry| try builder.appendCandidateIfMissing(allocator, .{
                .value = entry.key_ptr.*,
                .kind = .variable,
                .replace_start = semantic.replace_start,
                .replace_end = semantic.replace_end,
            });
        },
        .function => try appendFunctionProviderCandidates(allocator, io, shell_state, builder, rule, semantic),
    }
}

fn appendFunctionProviderCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: shell_state_mod.ShellState,
    builder: *Builder,
    rule: Rule,
    semantic: SemanticContext,
) !void {
    const function_name = rule.value orelse return;
    var parsed_options = try allocator.alloc(extension_rush_complete.ParsedOption, semantic.parsed_options.len);
    defer allocator.free(parsed_options);
    for (semantic.parsed_options, 0..) |option, index| {
        parsed_options[index] = .{
            .spelling = option.spelling,
            .name = option.name,
            .key = option.key,
            .value = option.value,
        };
    }
    var operands = try allocator.alloc(extension_rush_complete.ParsedOperand, semantic.operands.len);
    defer allocator.free(operands);
    for (semantic.operands, 0..) |operand, index| {
        operands[index] = .{ .value = operand.value, .index = operand.index };
    }

    const value_position = if (semantic.position == .option_value) "value" else "item";
    var provider_state = extension_rush_complete.State.init(
        allocator,
        io,
        semantic.prefix,
        semantic.replace_start,
        semantic.replace_end,
        semantic.argument_index,
        semantic.options_terminated,
        value_position,
        parsed_options,
        operands,
        shell_state.envLookup(),
        semantic.expand_tilde,
    );
    defer provider_state.deinit();

    var provider_shell_state = shell_state.clone(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer provider_shell_state.deinit();
    const argument_index = try std.fmt.allocPrint(allocator, "{d}", .{semantic.argument_index});
    defer allocator.free(argument_index);
    try provider_shell_state.putVariable("rush_completion_argument_index", argument_index, .{});
    try provider_shell_state.putVariable(
        "rush_completion_options_terminated",
        if (semantic.options_terminated) "true" else "false",
        .{},
    );
    try provider_shell_state.putVariable("rush_completion_value_position", value_position, .{});
    try provider_shell_state.putVariable("rush_completion_prefix", semantic.prefix, .{});

    const argv = [_][]const u8{function_name};
    var result = try runner.runHiddenShellStateCommandWithExtensionHandlers(
        allocator,
        io,
        &provider_shell_state,
        &argv,
        "rush",
        .{},
        .capture,
        .{ .context = &provider_state, .lookup = providerExtensionLookup },
    );
    defer result.deinit();
    if (result.status != 0) return;

    const candidates = try provider_state.takeCandidates();
    defer editor_completion.freeCandidates(allocator, candidates);
    for (candidates) |candidate| {
        var provider_candidate = candidate;
        if (provider_candidate.tag == null) provider_candidate.tag = rule.tag;
        if (provider_candidate.provider_order == null) provider_candidate.provider_order = rule.provider_order;
        try builder.appendCandidateIfMissing(allocator, provider_candidate);
    }
}

fn providerExtensionLookup(context: ?*anyopaque, name: []const u8) ?extension_api.HandlerSpec {
    const provider_state: *extension_rush_complete.State = @ptrCast(@alignCast(context.?));
    if (extension_rush_complete.handlerForContext(name, provider_state)) |handler| return handler;
    return extension_handlers.lookup(name);
}

fn ruleMatchesPath(rule: Rule, root: []const u8, path: []const []const u8) bool {
    if (!std.mem.eql(u8, rule.root, root)) return false;
    if (rule.path.len != path.len) return false;
    for (rule.path, path) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn argumentRuleMatches(argument: Argument, index: usize) bool {
    if (argument.index) |argument_index| {
        return argument_index == index or (argument.repeatable and index >= argument_index);
    }
    return index == 0 or argument.repeatable;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonPriority(value: std.json.Value) i8 {
    const integer = jsonInteger(value) orelse return 0;
    if (integer < std.math.minInt(i8)) return std.math.minInt(i8);
    if (integer > std.math.maxInt(i8)) return std.math.maxInt(i8);
    return @intCast(integer);
}

fn jsonBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn commandPrimaryName(command_object: std.json.ObjectMap) ?[]const u8 {
    const name_value = command_object.get("name") orelse return null;
    if (jsonString(name_value)) |name| return name;
    return switch (name_value) {
        .array => |names| if (names.items.len != 0) jsonString(names.items[0]) else null,
        else => null,
    };
}

fn registerManifestCommand(
    allocator: std.mem.Allocator,
    state: *State,
    root: []const u8,
    command_object: std.json.ObjectMap,
    inherited_providers: ?std.json.ObjectMap,
    path: *std.ArrayList([]const u8),
    source: RuleSource,
) !void {
    const providers = if (command_object.get("providers")) |providers_value|
        jsonObject(providers_value) orelse inherited_providers
    else
        inherited_providers;
    try registerManifestOptions(allocator, state, root, command_object, providers, path.items, source);
    try registerManifestArguments(allocator, state, root, command_object, providers, path.items, source);

    var subcommand_count: usize = 0;
    if (command_object.get("subcommands")) |subcommands_value| {
        const subcommands = switch (subcommands_value) {
            .array => |array| array,
            else => return,
        };
        subcommand_count = subcommands.items.len;
        for (subcommands.items, 0..) |subcommand_value, index| {
            const subcommand_object = jsonObject(subcommand_value) orelse continue;
            if (subcommand_object.get("provider")) |provider_ref| {
                try registerProviderRefRules(allocator, state, .{
                    .root = root,
                    .path = path.items,
                    .kind = .dynamic_subcommands,
                    .provider_order = index,
                    .source = source,
                }, provider_ref, providers);
                continue;
            }
            const primary = commandPrimaryName(subcommand_object) orelse continue;
            try registerSubcommandNames(allocator, state, root, subcommand_object, path.items, source, index);
            try path.append(allocator, primary);
            try registerManifestCommand(allocator, state, root, subcommand_object, providers, path, source);
            _ = path.pop();
        }
    }
    if (command_object.get("dynamicSubcommands")) |dynamic_subcommands_value| {
        const dynamic_subcommands = switch (dynamic_subcommands_value) {
            .array => |array| array,
            else => return,
        };
        for (dynamic_subcommands.items, 0..) |provider_ref, index| try registerProviderRefRules(allocator, state, .{
            .root = root,
            .path = path.items,
            .kind = .dynamic_subcommands,
            .provider_order = subcommand_count + index,
            .source = source,
        }, provider_ref, providers);
    }
}

fn registerSubcommandNames(
    allocator: std.mem.Allocator,
    state: *State,
    root: []const u8,
    command_object: std.json.ObjectMap,
    path: []const []const u8,
    source: RuleSource,
    provider_order: usize,
) !void {
    const description = if (command_object.get("description")) |value| jsonString(value) else null;
    const priority = if (command_object.get("priority")) |value| jsonPriority(value) else 0;
    const name_value = command_object.get("name") orelse return;
    try registerCommandNameValue(
        allocator,
        state,
        root,
        path,
        name_value,
        description,
        priority,
        source,
        provider_order,
    );
    if (command_object.get("aliases")) |aliases_value| switch (aliases_value) {
        .array => |aliases| for (aliases.items) |alias| {
            try registerCommandNameValue(
                allocator,
                state,
                root,
                path,
                alias,
                description,
                priority,
                source,
                provider_order,
            );
        },
        else => {},
    };
}

fn registerCommandNameValue(
    allocator: std.mem.Allocator,
    state: *State,
    root: []const u8,
    path: []const []const u8,
    name_value: std.json.Value,
    description: ?[]const u8,
    priority: i8,
    source: RuleSource,
    provider_order: usize,
) !void {
    switch (name_value) {
        .string => |name| try state.registerRule(.{
            .root = root,
            .path = path,
            .kind = .subcommand,
            .value = name,
            .description = description,
            .priority = priority,
            .provider_order = provider_order,
            .source = source,
        }),
        .array => |names| for (names.items) |item| if (jsonString(item)) |name| try state.registerRule(.{
            .root = root,
            .path = path,
            .kind = .subcommand,
            .value = name,
            .description = description,
            .priority = priority,
            .provider_order = provider_order,
            .source = source,
        }),
        else => {},
    }
    _ = allocator;
}

fn registerManifestOptions(
    allocator: std.mem.Allocator,
    state: *State,
    root: []const u8,
    command_object: std.json.ObjectMap,
    providers: ?std.json.ObjectMap,
    path: []const []const u8,
    source: RuleSource,
) !void {
    const options_value = command_object.get("options") orelse return;
    const options = switch (options_value) {
        .array => |array| array,
        else => return,
    };
    for (options.items, 0..) |option_value, index| {
        const option_object = jsonObject(option_value) orelse continue;
        if (option_object.get("provider")) |provider_ref| {
            try registerProviderRefRules(allocator, state, .{
                .root = root,
                .path = path,
                .kind = .dynamic_options,
                .provider_order = index,
                .source = source,
            }, provider_ref, providers);
            continue;
        }
        var spellings: std.ArrayList([]const u8) = .empty;
        defer spellings.deinit(allocator);
        if (option_object.get("spellings")) |spellings_value| switch (spellings_value) {
            .array => |array| for (array.items) |item| {
                if (jsonString(item)) |spelling| try spellings.append(allocator, spelling);
            },
            else => {},
        };
        var option: Option = .{
            .long = if (option_object.get("long")) |value| jsonString(value) else null,
            .short = if (option_object.get("short")) |value| jsonString(value) else null,
            .spellings = spellings.items,
            .repeatable = if (option_object.get("repeatable")) |value| jsonBool(value) orelse false else false,
            .inherit = if (option_object.get("inherit")) |value| jsonBool(value) orelse true else true,
            .exclusive_group = if (option_object.get("exclusiveGroup")) |value| jsonString(value) else null,
            .terminates_options = if (option_object.get("terminatesOptions")) |value|
                jsonBool(value) orelse false
            else
                false,
        };
        const description = if (option_object.get("description")) |value| jsonString(value) else null;
        const priority = if (option_object.get("priority")) |value| jsonPriority(value) else 0;
        if (option_object.get("value")) |value_object| option.value_count = optionValueCount(value_object);
        try state.registerRule(.{
            .root = root,
            .path = path,
            .kind = .option,
            .option = option,
            .description = description,
            .priority = priority,
            .provider_order = index,
            .source = source,
        });
        if (option_object.get("value")) |value_object| {
            try registerOptionValueProviders(
                allocator,
                state,
                root,
                path,
                option,
                value_object,
                providers,
                description,
                index,
                source,
            );
        }
    }
}

fn registerOptionValueProviders(
    allocator: std.mem.Allocator,
    state: *State,
    root: []const u8,
    path: []const []const u8,
    option: Option,
    value_object: std.json.Value,
    providers: ?std.json.ObjectMap,
    description: ?[]const u8,
    provider_order: usize,
    source: RuleSource,
) !void {
    switch (value_object) {
        .object => |object| if (object.get("provider")) |provider_ref| {
            try registerProviderRefRules(allocator, state, .{
                .root = root,
                .path = path,
                .kind = .dynamic_option_value,
                .option = option,
                .description = description,
                .provider_order = provider_order,
                .source = source,
            }, provider_ref, providers);
        },
        .array => |values| for (values.items, 0..) |item, value_index| if (jsonObject(item)) |object| {
            if (object.get("provider")) |provider_ref| try registerProviderRefRules(allocator, state, .{
                .root = root,
                .path = path,
                .kind = .dynamic_option_value,
                .option = option,
                .value_index = value_index,
                .description = description,
                .provider_order = provider_order,
                .source = source,
            }, provider_ref, providers);
        },
        else => {},
    }
}

fn optionValueCount(value_object: std.json.Value) usize {
    return switch (value_object) {
        .array => |array| array.items.len,
        .object => 1,
        else => 0,
    };
}

fn registerManifestArguments(
    allocator: std.mem.Allocator,
    state: *State,
    root: []const u8,
    command_object: std.json.ObjectMap,
    providers: ?std.json.ObjectMap,
    path: []const []const u8,
    source: RuleSource,
) !void {
    const arguments_object = jsonObject(command_object.get("arguments") orelse return) orelse return;
    const states_value = arguments_object.get("states") orelse return;
    const states = switch (states_value) {
        .array => |array| array,
        else => return,
    };
    for (states.items, 0..) |state_value, index| {
        const argument_object = jsonObject(state_value) orelse continue;
        const provider_ref = argument_object.get("provider") orelse continue;
        const description = if (argument_object.get("description")) |value| jsonString(value) else null;
        const argument: Argument = .{
            .state = if (argument_object.get("name")) |value| jsonString(value) else null,
            .index = if (argument_object.get("index")) |value|
                if (jsonInteger(value)) |integer| @intCast(integer) else index
            else
                index,
            .repeatable = if (argument_object.get("repeatable")) |value| jsonBool(value) orelse false else false,
            .rest_command_line = if (argument_object.get("rest")) |value|
                if (jsonString(value)) |rest| std.mem.eql(u8, rest, "command-line") else false
            else
                false,
        };
        try registerProviderRefRules(allocator, state, .{
            .root = root,
            .path = path,
            .kind = .dynamic_argument,
            .argument = argument,
            .description = description,
            .provider_order = index,
            .source = source,
        }, provider_ref, providers);
    }
}

fn registerProviderRefRules(
    allocator: std.mem.Allocator,
    state: *State,
    base_rule: Rule,
    provider_ref: std.json.Value,
    providers: ?std.json.ObjectMap,
) !void {
    switch (provider_ref) {
        .string => |id| {
            if (providers) |provider_map| if (provider_map.get(id)) |provider| {
                return registerProviderRule(allocator, state, base_rule, provider);
            };
            try registerBuiltinProviderId(state, base_rule, id);
        },
        .object => try registerProviderRule(allocator, state, base_rule, provider_ref),
        .array => |array| for (array.items) |item| {
            try registerProviderRefRules(allocator, state, base_rule, item, providers);
        },
        else => {},
    }
}

fn registerProviderRule(
    allocator: std.mem.Allocator,
    state: *State,
    base_rule: Rule,
    provider: std.json.Value,
) !void {
    const provider_object = jsonObject(provider) orelse return;
    if (provider_object.get("builtin")) |builtin_value| {
        if (jsonString(builtin_value)) |id| return registerBuiltinProviderId(state, base_rule, id);
    }
    if (provider_object.get("function")) |function_value| {
        if (jsonString(function_value)) |function_name| {
            var rule = base_rule;
            rule.provider_kind = .function;
            rule.value = function_name;
            return state.registerRule(rule);
        }
    }
    if (provider_object.get("values")) |values| {
        const static_values = try parseStaticProviderValues(allocator, values);
        defer if (static_values.len != 0) allocator.free(static_values);
        var rule = base_rule;
        rule.provider_kind = .static_enum;
        rule.static_values = static_values;
        return state.registerRule(rule);
    }
}

fn registerBuiltinProviderId(state: *State, base_rule: Rule, id: []const u8) !void {
    var rule = base_rule;
    rule.provider_kind = if (std.mem.eql(u8, id, "files") or std.mem.eql(u8, id, "builtin.files"))
        .builtin_files
    else if (std.mem.eql(u8, id, "directories") or std.mem.eql(u8, id, "builtin.directories"))
        .builtin_directories
    else if (std.mem.eql(u8, id, "executables") or std.mem.eql(u8, id, "builtin.executables"))
        .builtin_executables
    else if (std.mem.eql(u8, id, "variables") or std.mem.eql(u8, id, "builtin.variables"))
        .builtin_variables
    else
        return;
    try state.registerRule(rule);
}

fn parseStaticProviderValues(allocator: std.mem.Allocator, values: std.json.Value) ![]const StaticProviderValue {
    const array = switch (values) {
        .array => |array| array,
        else => return &.{},
    };
    const parsed = try allocator.alloc(StaticProviderValue, array.items.len);
    errdefer allocator.free(parsed);
    for (array.items, 0..) |item, index| {
        parsed[index] = switch (item) {
            .string => |value| .{ .value = value },
            .object => |object| .{
                .value = if (object.get("value")) |value| jsonString(value) orelse "" else "",
                .display = if (object.get("display")) |value| jsonString(value) else null,
                .description = if (object.get("description")) |value| jsonString(value) else null,
                .tag = if (object.get("tag")) |value| jsonString(value) else null,
                .suffix = if (object.get("suffix")) |value| jsonString(value) else null,
                .removable_suffix = if (object.get("removableSuffix")) |value| jsonBool(value) orelse false else false,
                .priority = if (object.get("priority")) |value| jsonPriority(value) else 0,
                .append_space = if (object.get("noSpace")) |value| !(jsonBool(value) orelse false) else true,
            },
            else => .{ .value = "" },
        };
    }
    return parsed;
}

pub fn defaultPathApplication(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    cursor: usize,
) !Application {
    var parse_result = try parser.parse(allocator, source, .{});
    defer parse_result.deinit();

    const context = parser.completionContext(parse_result, cursor);
    if (!completionContextUsesPaths(context.kind)) return .none;

    const replace_start = context.span.start;
    const replace_end = context.span.end;
    std.debug.assert(replace_start <= replace_end);
    std.debug.assert(replace_end <= source.len);

    const word = try decodeShellCompletionSlice(allocator, source, replace_start, replace_end);
    defer allocator.free(word);

    const candidates = try pathCandidates(allocator, io, word, replace_start, replace_end, .{});
    defer freeCandidates(allocator, candidates);
    return applyCandidatesForInputWithPolicy(allocator, source, candidates, .prefixOnly());
}

pub fn defaultApplication(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: shell_state_mod.ShellState,
    source: []const u8,
    cursor: usize,
) !Application {
    var parse_result = try parser.parse(allocator, source, .{});
    defer parse_result.deinit();

    const context = parser.completionContext(parse_result, cursor);
    if (!completionContextUsesPaths(context.kind) and context.kind != .command) return .none;

    const replace_start = context.span.start;
    const replace_end = context.span.end;
    std.debug.assert(replace_start <= replace_end);
    std.debug.assert(replace_end <= source.len);

    const word = try decodeShellCompletionSlice(allocator, source, replace_start, replace_end);
    defer allocator.free(word);

    const path_options: PathCandidateOptions = .{
        .expand_tilde = shellCompletionContext(source, replace_start).quote == .unquoted,
    };
    const candidates = if (context.kind == .command and std.mem.indexOfScalar(u8, word, '/') == null)
        try commandCandidates(allocator, io, shell_state, replace_start, replace_end)
    else
        try pathCandidatesWithOptions(
            allocator,
            io,
            word,
            replace_start,
            replace_end,
            path_options,
            shell_state.envLookup(),
        );
    defer freeCandidates(allocator, candidates);
    return applyCandidatesForInputWithPolicy(allocator, source, candidates, .prefixOnly());
}

fn completionContextUsesPaths(kind: parser.CompletionKind) bool {
    return switch (kind) {
        .command,
        .argument,
        .redirect_target,
        .assignment_value,
        .quoted_string,
        => true,
        .parameter,
        .assignment_name,
        .separator,
        => false,
    };
}

fn pathCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    word: []const u8,
    replace_start: usize,
    replace_end: usize,
    env: expand.EnvLookup,
) ![]Candidate {
    return pathCandidatesWithOptions(allocator, io, word, replace_start, replace_end, .{}, env);
}

const PathCandidateOptions = struct {
    directories_only: bool = false,
    expand_tilde: bool = false,
};

fn pathCandidatesWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    word: []const u8,
    replace_start: usize,
    replace_end: usize,
    options: PathCandidateOptions,
    env: expand.EnvLookup,
) ![]Candidate {
    const split = std.mem.findScalarLast(u8, word, '/');
    const dir_prefix = if (split) |index| word[0 .. index + 1] else "";
    const entry_prefix = if (split) |index| word[index + 1 ..] else word;
    const dir_path_raw = pathDirectoryToOpen(dir_prefix);
    const dir_path = if (options.expand_tilde)
        try expand.expandTilde(allocator, dir_path_raw, env)
    else
        try allocator.dupe(u8, dir_path_raw);
    defer allocator.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var builder: Builder = .{};
    errdefer builder.deinit(allocator);

    const include_hidden = std.mem.startsWith(u8, entry_prefix, ".");
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!include_hidden and entry.name[0] == '.') continue;
        if (!std.mem.startsWith(u8, entry.name, entry_prefix)) continue;

        const is_directory = entry.kind == .directory;
        if (options.directories_only and !is_directory) continue;
        const value = try pathCandidateValue(allocator, dir_prefix, entry.name, is_directory);
        defer allocator.free(value);
        const display = try pathCandidateValue(allocator, "", entry.name, is_directory);
        defer allocator.free(display);
        try builder.appendCandidate(allocator, .{
            .value = value,
            .display = display,
            .kind = if (is_directory) .directory else .file,
            .replace_start = replace_start,
            .replace_end = replace_end,
            .append_space = !is_directory,
        });
    }

    return builder.finish(allocator);
}

fn commandCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: shell_state_mod.ShellState,
    replace_start: usize,
    replace_end: usize,
) ![]Candidate {
    var builder: Builder = .{};
    errdefer builder.deinit(allocator);

    var alias_iter = shell_state.aliases.iterator();
    while (alias_iter.next()) |entry| try builder.appendCandidateIfMissing(allocator, .{
        .value = entry.key_ptr.*,
        .kind = .command,
        .replace_start = replace_start,
        .replace_end = replace_end,
    });

    var function_iter = shell_state.functions.iterator();
    while (function_iter.next()) |entry| try builder.appendCandidateIfMissing(allocator, .{
        .value = entry.key_ptr.*,
        .kind = .function,
        .replace_start = replace_start,
        .replace_end = replace_end,
    });

    for (default_builtins.default_registry) |builtin| try builder.appendCandidateIfMissing(allocator, .{
        .value = builtin.name,
        .kind = .builtin,
        .replace_start = replace_start,
        .replace_end = replace_end,
    });

    if (shell_state.getVariable("PATH")) |path_variable| {
        var path_iter = std.mem.splitScalar(u8, path_variable.value, ':');
        while (path_iter.next()) |directory| try appendPathExecutableCandidates(
            allocator,
            io,
            &builder,
            directory,
            replace_start,
            replace_end,
        );
    }

    return builder.finish(allocator);
}

fn appendPathExecutableCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    builder: *Builder,
    directory: []const u8,
    replace_start: usize,
    replace_end: usize,
) !void {
    const dir_path = if (directory.len == 0) "." else directory;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;
        if (entry.kind == .directory) continue;
        dir.access(io, entry.name, .{ .execute = true }) catch continue;
        try builder.appendCandidateIfMissing(allocator, .{
            .value = entry.name,
            .kind = .command,
            .replace_start = replace_start,
            .replace_end = replace_end,
        });
    }
}

fn pathDirectoryToOpen(dir_prefix: []const u8) []const u8 {
    if (dir_prefix.len == 0) return ".";
    if (std.mem.eql(u8, dir_prefix, "/")) return "/";
    if (std.mem.endsWith(u8, dir_prefix, "/")) return dir_prefix[0 .. dir_prefix.len - 1];
    return dir_prefix;
}

fn pathCandidateValue(
    allocator: std.mem.Allocator,
    dir_prefix: []const u8,
    name: []const u8,
    is_directory: bool,
) ![]const u8 {
    return if (is_directory)
        std.fmt.allocPrint(allocator, "{s}{s}/", .{ dir_prefix, name })
    else
        std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, name });
}

fn freeTemporaryCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| {
        if (candidate.insert) |insert| allocator.free(insert);
        if (candidate.suffix) |suffix| allocator.free(suffix);
    }
}

pub fn candidateQueryForInput(allocator: std.mem.Allocator, source: []const u8, candidate: Candidate) ![]const u8 {
    std.debug.assert(candidate.replace_start <= candidate.replace_end);
    std.debug.assert(candidate.replace_end <= source.len);
    return decodeShellCompletionSlice(allocator, source, candidate.replace_start, candidate.replace_end);
}

const CandidateReplacement = struct {
    text: []const u8,
    suffix: ?[]const u8 = null,
};

fn candidateReplacementAndSuffixForInput(
    allocator: std.mem.Allocator,
    source: []const u8,
    candidate: Candidate,
) !CandidateReplacement {
    const preserve_initial_tilde = try shouldPreserveInitialTilde(allocator, source, candidate);
    return encodeShellCompletionReplacement(
        allocator,
        source,
        candidate.replace_start,
        candidate.replace_end,
        candidate.value,
        candidate.suffix,
        candidate.append_space,
        preserve_initial_tilde,
    );
}

fn shouldPreserveInitialTilde(
    allocator: std.mem.Allocator,
    source: []const u8,
    candidate: Candidate,
) !bool {
    if (candidate.value.len == 0 or candidate.value[0] != '~') return false;
    const context = shellCompletionContext(source, candidate.replace_start);
    if (context.quote != .unquoted or context.opening_quote != null) return false;
    const prefix = try decodeShellCompletionSlice(allocator, source, candidate.replace_start, candidate.replace_end);
    defer allocator.free(prefix);
    return prefix.len != 0 and prefix[0] == '~' and std.mem.indexOfScalar(u8, prefix, '/') != null;
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

fn encodeShellCompletionReplacement(
    allocator: std.mem.Allocator,
    source: []const u8,
    replace_start: usize,
    replace_end: usize,
    value: []const u8,
    suffix: ?[]const u8,
    append_space: bool,
    preserve_initial_tilde: bool,
) !CandidateReplacement {
    const context = shellCompletionContext(source, replace_start);
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);
    if (context.opening_quote) |quote| try encoded.append(allocator, quote);
    try appendShellEscapedValue(allocator, &encoded, context.quote, value, preserve_initial_tilde);
    const suffix_start = encoded.items.len;
    if (suffix) |text| try appendShellEscapedValue(allocator, &encoded, context.quote, text, false);
    const suffix_end = encoded.items.len;
    if (append_space and shouldCloseQuoteForCompletion(
        source,
        replace_end,
        context.quote,
        context.opening_quote != null,
    )) {
        try encoded.append(allocator, switch (context.quote) {
            .unquoted => unreachable,
            .single => '\'',
            .double => '"',
        });
    }
    const text = try encoded.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    const encoded_suffix = if (suffix_start != suffix_end)
        try allocator.dupe(u8, text[suffix_start..suffix_end])
    else
        null;
    return .{ .text = text, .suffix = encoded_suffix };
}

fn appendShellEscapedValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    quote: ShellQuote,
    value: []const u8,
    preserve_initial_tilde: bool,
) !void {
    switch (quote) {
        .unquoted => {
            for (value, 0..) |byte, index| {
                if (needsUnquotedEscape(byte, index, preserve_initial_tilde)) try out.append(allocator, '\\');
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

fn needsUnquotedEscape(byte: u8, index: usize, preserve_initial_tilde: bool) bool {
    if (std.ascii.isWhitespace(byte)) return true;
    if (index == 0 and byte == '~' and !preserve_initial_tilde) return true;
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

fn shouldCloseQuoteForCompletion(
    source: []const u8,
    replace_end: usize,
    quote: ShellQuote,
    opened_at_replacement: bool,
) bool {
    _ = source;
    _ = replace_end;
    _ = opened_at_replacement;
    return quote != .unquoted;
}

fn cloneStaticProviderValues(
    allocator: std.mem.Allocator,
    values: []const StaticProviderValue,
) ![]const StaticProviderValue {
    if (values.len == 0) return &.{};
    const owned = try allocator.alloc(StaticProviderValue, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| freeStaticProviderValue(allocator, value);
        allocator.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = .{
            .value = try allocator.dupe(u8, value.value),
            .display = if (value.display) |display| try allocator.dupe(u8, display) else null,
            .description = if (value.description) |description| try allocator.dupe(u8, description) else null,
            .tag = if (value.tag) |tag| try allocator.dupe(u8, tag) else null,
            .suffix = if (value.suffix) |suffix| try allocator.dupe(u8, suffix) else null,
            .removable_suffix = value.removable_suffix,
            .priority = value.priority,
            .append_space = value.append_space,
        };
        initialized += 1;
    }
    return owned;
}

fn cloneOptionValueConditions(
    allocator: std.mem.Allocator,
    conditions: []const OptionValueCondition,
) ![]const OptionValueCondition {
    if (conditions.len == 0) return &.{};
    const owned = try allocator.alloc(OptionValueCondition, conditions.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |condition| freeOptionValueCondition(allocator, condition);
        allocator.free(owned);
    }
    for (conditions, 0..) |condition, index| {
        owned[index] = try cloneOptionValueCondition(allocator, condition);
        initialized += 1;
    }
    return owned;
}

pub fn freeRule(allocator: std.mem.Allocator, rule: Rule) void {
    allocator.free(rule.root);
    for (rule.path) |segment| allocator.free(segment);
    allocator.free(rule.path);
    if (rule.value) |value| allocator.free(value);
    if (rule.static_values.len != 0) {
        for (rule.static_values) |value| freeStaticProviderValue(allocator, value);
        allocator.free(rule.static_values);
    }
    if (rule.option.long) |long| allocator.free(long);
    if (rule.option.short) |short| allocator.free(short);
    if (rule.option.spellings.len != 0) {
        for (rule.option.spellings) |spelling| allocator.free(spelling);
        allocator.free(rule.option.spellings);
    }
    if (rule.option.argument) |argument| allocator.free(argument);
    if (rule.option.exclusive_group) |group| allocator.free(group);
    freeOptionExclusions(allocator, rule.option.excludes);
    if (rule.argument.state) |state| allocator.free(state);
    if (rule.argument.after_state) |state| allocator.free(state);
    if (rule.argument.after_value) |value| allocator.free(value);
    freeArgumentCondition(allocator, rule.argument.when_condition);
    freeArgumentCondition(allocator, rule.argument.after_condition);
    freeArgumentCondition(allocator, rule.argument.until_condition);
    freeOptionValueConditions(allocator, rule.argument.require_option_values);
    freeOptionValueConditions(allocator, rule.argument.reject_option_values);
    if (rule.description) |description| allocator.free(description);
    if (rule.tag) |tag| allocator.free(tag);
    if (rule.source.manifest_path) |path| allocator.free(path);
    if (rule.source.companion_path) |path| allocator.free(path);
    if (rule.variant) |variant| allocator.free(variant);
}

fn freeStaticProviderValue(allocator: std.mem.Allocator, value: StaticProviderValue) void {
    allocator.free(value.value);
    if (value.display) |display| allocator.free(display);
    if (value.description) |description| allocator.free(description);
    if (value.tag) |tag| allocator.free(tag);
    if (value.suffix) |suffix| allocator.free(suffix);
}

fn freeProviderFunction(allocator: std.mem.Allocator, function: ProviderFunction) void {
    allocator.free(function.body);
    for (function.redirections) |redirection| {
        if (redirection.io_number) |word| freeProviderFunctionWord(allocator, word);
        if (redirection.target) |word| freeProviderFunctionWord(allocator, word);
        if (redirection.here_doc) |text| allocator.free(text);
    }
    allocator.free(function.redirections);
}

fn freeProviderFunctionWord(allocator: std.mem.Allocator, word: ir.WordRef) void {
    allocator.free(word.raw);
    allocator.free(word.text);
}

fn cloneProviderFunctionRedirections(
    allocator: std.mem.Allocator,
    redirections: []const ir.Redirection,
) ![]ir.Redirection {
    const cloned = try allocator.alloc(ir.Redirection, redirections.len);
    errdefer allocator.free(cloned);
    for (redirections, 0..) |redirection, index| {
        cloned[index] = .{
            .span = redirection.span,
            .operator = redirection.operator,
            .io_number = if (redirection.io_number) |word| try cloneProviderFunctionWord(allocator, word) else null,
            .target = if (redirection.target) |word| try cloneProviderFunctionWord(allocator, word) else null,
            .here_doc = if (redirection.here_doc) |text| try allocator.dupe(u8, text) else null,
            .here_doc_quoted = redirection.here_doc_quoted,
        };
    }
    return cloned;
}

fn cloneProviderFunctionWord(allocator: std.mem.Allocator, word: ir.WordRef) !ir.WordRef {
    return .{
        .span = word.span,
        .raw = try allocator.dupe(u8, word.raw),
        .text = try allocator.dupe(u8, word.text),
    };
}

fn freeOptionValueConditions(allocator: std.mem.Allocator, conditions: []const OptionValueCondition) void {
    if (conditions.len == 0) return;
    for (conditions) |condition| freeOptionValueCondition(allocator, condition);
    allocator.free(conditions);
}

fn freeOptionValueCondition(allocator: std.mem.Allocator, condition: OptionValueCondition) void {
    allocator.free(condition.key);
    for (condition.values) |value| allocator.free(value);
    allocator.free(condition.values);
}

fn freeManifestCommandState(allocator: std.mem.Allocator, state: ManifestCommandState) void {
    allocator.free(state.command);
    if (state.manifest_path) |path| allocator.free(path);
    allocator.free(state.platform);
}

fn freeVariantProbeState(allocator: std.mem.Allocator, state: VariantProbeState) void {
    allocator.free(state.command);
    for (state.args) |arg| allocator.free(arg);
    allocator.free(state.args);
    for (state.patterns) |pattern| {
        allocator.free(pattern.name);
        allocator.free(pattern.pattern);
    }
    allocator.free(state.patterns);
    if (state.selected) |selected| allocator.free(selected);
}

test "default path completion returns filesystem candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "apple.txt", .data = "" });
    try tmp.dir.createDir(std.testing.io, "apps", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".hidden", .data = "" });

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];

    const source = try std.fmt.allocPrint(std.testing.allocator, "cat {s}/app", .{tmp_root});
    defer std.testing.allocator.free(source);
    const application = try defaultPathApplication(std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);

    const expected_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/apps/", .{tmp_root});
    defer std.testing.allocator.free(expected_dir);
    const expected_file = try std.fmt.allocPrint(std.testing.allocator, "{s}/apple.txt", .{tmp_root});
    defer std.testing.allocator.free(expected_file);

    const candidates = application.ambiguous;
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings(expected_dir, candidates[0].value);
    try std.testing.expectEqualStrings("apps/", candidates[0].display.?);
    try std.testing.expectEqual(Kind.directory, candidates[0].kind);
    try std.testing.expect(!candidates[0].append_space);
    try std.testing.expectEqualStrings(expected_file, candidates[1].value);
    try std.testing.expectEqualStrings("apple.txt", candidates[1].display.?);
    try std.testing.expectEqual(Kind.file, candidates[1].kind);
    try std.testing.expect(candidates[1].append_space);
}

test "default path completion inserts escaped single file matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "two words", .data = "" });

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];

    const source = try std.fmt.allocPrint(std.testing.allocator, "cat {s}/two\\ w", .{tmp_root});
    defer std.testing.allocator.free(source);
    const application = try defaultPathApplication(std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);

    const expected_replacement = try std.fmt.allocPrint(std.testing.allocator, "{s}/two\\ words", .{tmp_root});
    defer std.testing.allocator.free(expected_replacement);

    const edit = application.edit;
    try std.testing.expectEqual(@as(usize, "cat ".len), edit.replace_start);
    try std.testing.expectEqual(@as(usize, source.len), edit.replace_end);
    try std.testing.expectEqualStrings(expected_replacement, edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "default completion returns commands in command position" {
    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setAlias("rush_alias", "echo alias");
    try shell_state.putFunctionName("rush_fn");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var executable = try tmp.dir.createFile(std.testing.io, "rush-tool", .{ .permissions = .executable_file });
    executable.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rush-note", .data = "" });

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    try shell_state.putVariable("PATH", tmp_root, .{ .exported = true });

    const source = "r";
    const application = try defaultApplication(std.testing.allocator, std.testing.io, shell_state, source, source.len);
    defer application.deinit(std.testing.allocator);

    const candidates = application.ambiguous;
    try expectCandidate(candidates, "read", .builtin);
    try expectCandidate(candidates, "rush_alias", .command);
    try expectCandidate(candidates, "rush_fn", .function);
    try expectCandidate(candidates, "rush-tool", .command);
    try expectNoCandidate(candidates, "rush-note");
}

test "default completion keeps command words with slash path-like" {
    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setAlias("rush_alias", "echo alias");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rush-script", .data = "" });

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/rush", .{tmp_root});
    defer std.testing.allocator.free(source);

    const application = try defaultApplication(std.testing.allocator, std.testing.io, shell_state, source, source.len);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    const expected_replacement = try std.fmt.allocPrint(std.testing.allocator, "{s}/rush-script", .{tmp_root});
    defer std.testing.allocator.free(expected_replacement);
    try std.testing.expectEqualStrings(expected_replacement, edit.replacement);
}

test "default completion keeps argument position path-only" {
    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setAlias("rush_alias", "echo alias");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rush-file", .data = "" });

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const source = try std.fmt.allocPrint(std.testing.allocator, "cat {s}/rush", .{tmp_root});
    defer std.testing.allocator.free(source);

    const application = try defaultApplication(std.testing.allocator, std.testing.io, shell_state, source, source.len);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    const expected_replacement = try std.fmt.allocPrint(std.testing.allocator, "{s}/rush-file", .{tmp_root});
    defer std.testing.allocator.free(expected_replacement);
    try std.testing.expectEqualStrings(expected_replacement, edit.replacement);
}

test "default completion expands tilde only where the shell would" {
    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "Downloads", .default_dir);

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    try shell_state.putVariable("HOME", tmp_root, .{ .exported = true });

    const unquoted_source = "cat ~/Down";
    const unquoted_application = try defaultApplication(
        std.testing.allocator,
        std.testing.io,
        shell_state,
        unquoted_source,
        unquoted_source.len,
    );
    defer unquoted_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("~/Downloads/", unquoted_application.edit.replacement);

    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    try std.process.setCurrentPath(std.testing.io, tmp_root);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch unreachable;

    const quoted_source = "cat \"~/Down";
    const quoted_application = try defaultApplication(
        std.testing.allocator,
        std.testing.io,
        shell_state,
        quoted_source,
        quoted_source.len,
    );
    defer quoted_application.deinit(std.testing.allocator);
    try std.testing.expectEqual(Application.none, quoted_application);
}

test "default completion escapes literal leading tilde path names" {
    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "~bob", .data = "" });

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    try std.process.setCurrentPath(std.testing.io, tmp_root);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch unreachable;

    const source = "cat ~b";
    const application = try defaultApplication(std.testing.allocator, std.testing.io, shell_state, source, source.len);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\\~bob", application.edit.replacement);
}

test "manifest completion loads git subcommands lazily" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/git.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const source = "git ch";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    const candidates = application.ambiguous;
    try expectCandidate(candidates, "checkout", .subcommand);
    try expectCandidate(candidates, "cherry-pick", .subcommand);
}

test "manifest completion uses dynamic subcommand providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tool.json",
        .data =
        \\
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.scripts": { "function": "__rush_complete_tool_scripts" }
        \\    },
        \\    "dynamicSubcommands": ["tool.scripts"],
        \\    "subcommands": [
        \\      { "name": "start", "description": "static command" }
        \\    ]
        \\  }
        \\}
        \\
        ,
    });
    var manifest_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &manifest_path_buffer);
    const tmp_root = manifest_path_buffer[0..tmp_root_len];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "tool.json" });
    defer std.testing.allocator.free(manifest_path);

    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, manifest_path);

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "__rush_complete_tool_scripts",
        .source_body =
        \\
        \\rush_complete candidate storybook --kind subcommand --description 'package script' --priority 20
        \\
        ,
    });
    const source = "tool st";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    const candidates = application.ambiguous;
    try expectCandidate(candidates, "storybook", .subcommand);
    try expectCandidate(candidates, "start", .subcommand);
    try std.testing.expectEqualStrings("storybook", candidates[0].value);
}

test "manifest completion providers support redirected while read loops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tool.json",
        .data =
        \\
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.generated": { "function": "__rush_complete_tool_generated" }
        \\    },
        \\    "dynamicSubcommands": ["tool.generated"],
        \\    "subcommands": [
        \\      { "name": "beta", "description": "static command" }
        \\    ]
        \\  }
        \\}
        \\
        ,
    });
    var manifest_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &manifest_path_buffer);
    const tmp_root = manifest_path_buffer[0..tmp_root_len];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "tool.json" });
    defer std.testing.allocator.free(manifest_path);

    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, manifest_path);

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const provider_tmp_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "provider-values.txt" });
    defer std.testing.allocator.free(provider_tmp_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "provider-values.txt", .data = "alpha\n" });
    const provider_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\
        \\tmp={s}
        \\while IFS= read -r value; do
        \\  rush_complete candidate "$value" --kind subcommand --description generated
        \\done < "$tmp"
        \\
    ,
        .{provider_tmp_path},
    );
    defer std.testing.allocator.free(provider_source);
    try shell_state.putFunction(.{
        .name = "__rush_complete_tool_generated",
        .source_body = provider_source,
    });
    const source = "tool alp";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    switch (application) {
        .edit => |edit| try std.testing.expectEqualStrings("alpha", edit.replacement),
        .ambiguous => |candidates| try expectCandidateDescription(candidates, "alpha", "generated"),
        .none => return error.ExpectedCompletionCandidate,
    }
}

test "git manifest completion includes configured aliases with expansion descriptions" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/git.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try sourceCompletionScript(&shell_state, "share/rush/completions/git.rush");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var git = try tmp.dir.createFile(std.testing.io, "git", .{ .permissions = .executable_file });
    {
        var buffer: [4096]u8 = undefined;
        var writer = git.writer(std.testing.io, &buffer);
        try writer.interface.writeAll(
            \\
            \\#!/bin/sh
            \\case "$1" in
            \\  config)
            \\    if test "$2" = --get-regexp; then
            \\      printf '%s\n' alias.co alias.cob
            \\    elif test "$2" = --get; then
            \\      case "$3" in
            \\        alias.co) printf '%s\n' checkout ;;
            \\        alias.cob) printf '%s\n' 'checkout -b' ;;
            \\      esac
            \\    fi
            \\    ;;
            \\  --list-cmds=list-mainporcelain,others)
            \\    printf '%s\n' checkout commit custom-tool
            \\    ;;
            \\esac
            \\
        );
        try writer.interface.flush();
    }
    git.close(std.testing.io);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}:/bin:/usr/bin", .{tmp_root});
    defer std.testing.allocator.free(path);
    try shell_state.putVariable("PATH", path, .{ .exported = true });

    const source = "git c";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    const candidates = application.ambiguous;
    try expectCandidateDescription(candidates, "co", "alias: checkout");
    try expectCandidateDescription(candidates, "cob", "alias: checkout -b");
    try expectCandidateDescription(candidates, "custom-tool", "git command");
    try expectCandidateDescription(candidates, "checkout", "switch branches or restore paths");
}

test "git manifest completion orders common subcommands by priority" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/git.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const source = "git st";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("status", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("stash", application.ambiguous[1].value);
}

test "manifest completion returns root options" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/git.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const source = "git --h";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqualStrings("--help", edit.replacement);
}

test "manifest completion orders subcommands and options by priority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tool.json",
        .data =
        \\
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "subcommands": [
        \\      { "name": "alpha", "description": "alpha command" },
        \\      { "name": "apricot", "description": "apricot command", "priority": 10 },
        \\      {
        \\        "name": "run",
        \\        "options": [
        \\          { "long": "alpha", "description": "alpha option" },
        \\          { "long": "apricot", "description": "apricot option", "priority": 10 }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        \\
        ,
    });
    var manifest_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &manifest_path_buffer);
    const tmp_root = manifest_path_buffer[0..tmp_root_len];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "tool.json" });
    defer std.testing.allocator.free(manifest_path);

    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, manifest_path);

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const subcommand_source = "tool a";
    const subcommand_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        subcommand_source,
        subcommand_source.len,
    );
    defer subcommand_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("apricot", subcommand_application.ambiguous[0].value);
    try std.testing.expectEqualStrings("alpha", subcommand_application.ambiguous[1].value);

    const option_source = "tool run --a";
    const option_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        option_source,
        option_source.len,
    );
    defer option_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("--apricot", option_application.ambiguous[0].value);
    try std.testing.expectEqualStrings("--alpha", option_application.ambiguous[1].value);
}

test "manifest completion uses dynamic option providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tool.json",
        .data =
        \\
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.options": { "function": "__rush_complete_tool_options" }
        \\    },
        \\    "subcommands": [
        \\      {
        \\        "name": "run",
        \\        "options": [
        \\          { "provider": "tool.options" },
        \\          { "long": "alpha", "description": "static option" }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
        \\
        ,
    });
    var manifest_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &manifest_path_buffer);
    const tmp_root = manifest_path_buffer[0..tmp_root_len];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "tool.json" });
    defer std.testing.allocator.free(manifest_path);

    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, manifest_path);

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "__rush_complete_tool_options",
        .source_body =
        \\
        \\case "$rush_completion_prefix" in
        \\  -D*) ;;
        \\  *) return ;;
        \\esac
        \\rush_complete candidate -Doptimize=ReleaseSafe --kind option --description 'dynamic option' --priority 20
        \\rush_complete candidate -Dtarget= --kind option --description 'dynamic target option'
        \\
        ,
    });

    const source = "tool run -D";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("dynamic option", application.ambiguous[0].description.?);
    try std.testing.expectEqualStrings("-Dtarget=", application.ambiguous[1].value);
}

test "manifest completion orders static provider values by priority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tool.json",
        .data =
        \\
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.values": {
        \\        "values": ["alpha", { "value": "apricot", "priority": 10 }]
        \\      }
        \\    },
        \\    "arguments": {
        \\      "states": [{ "name": "value", "index": 0, "provider": "tool.values" }]
        \\    }
        \\  }
        \\}
        \\
        ,
    });
    var manifest_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &manifest_path_buffer);
    const tmp_root = manifest_path_buffer[0..tmp_root_len];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "tool.json" });
    defer std.testing.allocator.free(manifest_path);

    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, manifest_path);

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const source = "tool a";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("apricot", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("alpha", application.ambiguous[1].value);
}

test "manifest completion treats empty dynamic provider as handled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "tool.json",
        .data =
        \\
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.values": { "function": "__rush_complete_tool_values" }
        \\    },
        \\    "arguments": {
        \\      "states": [{ "name": "value", "index": 0, "provider": "tool.values" }]
        \\    }
        \\  }
        \\}
        \\
        ,
    });
    var manifest_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &manifest_path_buffer);
    const tmp_root = manifest_path_buffer[0..tmp_root_len];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "tool.json" });
    defer std.testing.allocator.free(manifest_path);

    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, manifest_path);

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putFunction(.{
        .name = "__rush_complete_tool_values",
        .source_body = ":",
    });

    const source = "tool a";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), application.ambiguous.len);
}

test "manifest completion uses option value provider after root option" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/git.json");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "alpha", .default_dir);

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    try std.process.setCurrentPath(std.testing.io, tmp_root);

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const source = "git --git-dir a";
    const application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        source,
        source.len,
    );
    defer application.deinit(std.testing.allocator);

    try std.process.setCurrentPath(std.testing.io, original_cwd);
    const edit = application.edit;
    try std.testing.expectEqualStrings("alpha/", edit.replacement);
}

test "manifest completion loads mkdir options and directory operands" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/mkdir.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const option_source = "mkdir -";
    const option_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        option_source,
        option_source.len,
    );
    defer option_application.deinit(std.testing.allocator);

    const option_candidates = option_application.ambiguous;
    try expectCandidate(option_candidates, "-m", .option);
    try expectCandidate(option_candidates, "-p", .option);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "parent", .default_dir);

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    try std.process.setCurrentPath(std.testing.io, tmp_root);

    const operand_source = "mkdir par";
    const operand_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        operand_source,
        operand_source.len,
    );
    defer operand_application.deinit(std.testing.allocator);

    try std.process.setCurrentPath(std.testing.io, original_cwd);
    const edit = operand_application.edit;
    try std.testing.expectEqualStrings("parent/", edit.replacement);
}

test "manifest completion loads cd options previous directory and directory operands" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/cd.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const companion = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "share/rush/completions/cd.rush",
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(companion);
    var source_result = try runner.runShellStateScriptWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        &shell_state,
        companion,
        "share/rush/completions/cd.rush",
        "rush",
        .{},
        .capture,
        .{},
    );
    defer source_result.deinit();
    try std.testing.expectEqual(@as(shell_state_mod.ExitStatus, 0), source_result.status);
    try shell_state.putVariable("OLDPWD", "/tmp", .{ .exported = true });

    const option_source = "cd -";
    const option_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        option_source,
        option_source.len,
    );
    defer option_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("-", option_application.ambiguous[0].value);
    try std.testing.expectEqualStrings("change to previous directory", option_application.ambiguous[0].description.?);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "alpha", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    try std.process.setCurrentPath(std.testing.io, tmp_root);

    const operand_source = "cd ";
    const operand_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        operand_source,
        operand_source.len,
    );
    defer operand_application.deinit(std.testing.allocator);

    try std.process.setCurrentPath(std.testing.io, original_cwd);
    try std.testing.expectEqual(@as(usize, 2), operand_application.ambiguous.len);
    try std.testing.expectEqualStrings("-", operand_application.ambiguous[0].value);
    try std.testing.expectEqualStrings("previous directory", operand_application.ambiguous[0].description.?);
    try std.testing.expectEqualStrings("alpha/", operand_application.ambiguous[1].value);
}

test "manifest completion loads rmdir options and directory operands" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/rmdir.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    const option_source = "rmdir -";
    const option_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        option_source,
        option_source.len,
    );
    defer option_application.deinit(std.testing.allocator);

    const option_edit = option_application.edit;
    try std.testing.expectEqualStrings("-p", option_edit.replacement);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "empty", .default_dir);

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    try std.process.setCurrentPath(std.testing.io, tmp_root);

    const operand_source = "rmdir emp";
    const operand_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        operand_source,
        operand_source.len,
    );
    defer operand_application.deinit(std.testing.allocator);

    try std.process.setCurrentPath(std.testing.io, original_cwd);
    const edit = operand_application.edit;
    try std.testing.expectEqualStrings("empty/", edit.replacement);
}

test "builtin manifests complete alias and unalias aliases dynamically" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/alias.json");
    try loadManifestFile(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        "share/rush/completions/unalias.json",
    );

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try sourceCompletionScript(&shell_state, "share/rush/completions/alias.rush");
    try sourceCompletionScript(&shell_state, "share/rush/completions/unalias.rush");
    try shell_state.setAlias("ll", "ls -l");

    const alias_source = "alias l";
    const alias_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        alias_source,
        alias_source.len,
    );
    defer alias_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ll", alias_application.edit.replacement);

    const unalias_source = "unalias l";
    const unalias_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        unalias_source,
        unalias_source.len,
    );
    defer unalias_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ll", unalias_application.edit.replacement);
}

test "builtin manifests complete export and unset names dynamically" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        "share/rush/completions/export.json",
    );
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/unset.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try sourceCompletionScript(&shell_state, "share/rush/completions/unset.rush");
    try shell_state.putVariable("ALPHA", "1", .{});
    try shell_state.putVariable("ZED", "2", .{});
    try shell_state.putFunctionName("zap");

    const export_source = "export AL";
    const export_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        export_source,
        export_source.len,
    );
    defer export_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ALPHA", export_application.edit.replacement);

    const unset_variable_source = "unset ZE";
    const unset_variable_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        unset_variable_source,
        unset_variable_source.len,
    );
    defer unset_variable_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ZED", unset_variable_application.edit.replacement);

    const unset_function_source = "unset -f za";
    const unset_function_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        unset_function_source,
        unset_function_source.len,
    );
    defer unset_function_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zap", unset_function_application.edit.replacement);
}

test "builtin manifests complete jobs fg and bg job specs dynamically" {
    var completion_state = State.init(std.testing.allocator);
    defer completion_state.deinit();
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/jobs.json");
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/fg.json");
    try loadManifestFile(std.testing.allocator, std.testing.io, &completion_state, "share/rush/completions/bg.json");

    var shell_state = shell_state_mod.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try sourceCompletionScript(&shell_state, "share/rush/completions/jobs.rush");
    try sourceCompletionScript(&shell_state, "share/rush/completions/fg.rush");
    try sourceCompletionScript(&shell_state, "share/rush/completions/bg.rush");
    try appendCompletionTestJob(&shell_state, 1, 7001, "first job");
    try appendCompletionTestJob(&shell_state, 2, 7002, "second job");

    const fg_source = "fg ";
    const fg_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        fg_source,
        fg_source.len,
    );
    defer fg_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("%+", fg_application.ambiguous[0].value);
    try expectCandidateDescription(fg_application.ambiguous, "%%", "current job");
    try expectCandidateDescription(fg_application.ambiguous, "%1", "job");
    try expectCandidateDescription(fg_application.ambiguous, "%-", "previous job");

    const jobs_source = "jobs %";
    const jobs_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        jobs_source,
        jobs_source.len,
    );
    defer jobs_application.deinit(std.testing.allocator);
    try expectCandidateDescription(jobs_application.ambiguous, "%2", "job");

    const bg_source = "bg %";
    const bg_application = try manifestApplication(
        std.testing.allocator,
        std.testing.io,
        &completion_state,
        shell_state,
        bg_source,
        bg_source.len,
    );
    defer bg_application.deinit(std.testing.allocator);
    try expectCandidateDescription(bg_application.ambiguous, "%+", "current job");
}

fn sourceCompletionScript(shell_state: *shell_state_mod.ShellState, path: []const u8) !void {
    const companion = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(companion);
    var result = try runner.runShellStateScriptWithExtensionHandlers(
        std.testing.allocator,
        std.testing.io,
        shell_state,
        companion,
        path,
        "rush",
        .{},
        .capture,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(shell_state_mod.ExitStatus, 0), result.status);
}

fn appendCompletionTestJob(
    shell_state: *shell_state_mod.ShellState,
    id: usize,
    pid: runtime.process.ProcessId,
    command: []const u8,
) !void {
    const owned_command = try shell_state.allocator.dupe(u8, command);
    errdefer shell_state.allocator.free(owned_command);

    const child = fakeCompletionChild(pid);
    var job: shell_state_mod.BackgroundJob = .{
        .id = id,
        .pid = pid,
        .process_group = pid,
        .command = owned_command,
    };
    errdefer job.deinit(shell_state.allocator);
    try job.appendProcess(shell_state.allocator, .{
        .stage_index = 0,
        .child = child,
    });
    try shell_state.appendBackgroundJob(job);
    job.deinit(shell_state.allocator);
}

fn fakeCompletionChild(id: runtime.process.ProcessId) runtime.process.ChildProcess {
    const child: std.process.Child = .{
        .id = id,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    return runtime.process.ChildProcess.init(child);
}

fn expectCandidate(candidates: []const Candidate, value: []const u8, kind: Kind) !void {
    for (candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.value, value)) continue;
        try std.testing.expectEqual(kind, candidate.kind);
        return;
    }
    return error.MissingCandidate;
}

fn expectCandidateDescription(candidates: []const Candidate, value: []const u8, description: []const u8) !void {
    for (candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.value, value)) continue;
        try std.testing.expectEqualStrings(description, candidate.description.?);
        return;
    }
    return error.MissingCandidate;
}

fn expectNoCandidate(candidates: []const Candidate, value: []const u8) !void {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return error.UnexpectedCandidate;
    }
}

test "application handles no candidates" {
    const candidates: [0]Candidate = .{};
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

test "application reports mixed replacement spans as ambiguous" {
    const source = "git add src/mai";
    const candidates = [_]Candidate{
        .{ .value = "src/main.zig", .kind = .file, .replace_start = "git add ".len, .replace_end = source.len },
        .{ .value = "main.zig", .kind = .file, .replace_start = "git add src/".len, .replace_end = source.len },
    };
    const application = try applyCandidatesForInput(std.testing.allocator, source, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqual(@as(usize, "git add ".len), application.ambiguous[0].replace_start);
    try std.testing.expectEqualStrings("src/main.zig", application.ambiguous[0].insert.?);
    try std.testing.expectEqual(@as(usize, "git add src/".len), application.ambiguous[1].replace_start);
    try std.testing.expectEqualStrings("main.zig", application.ambiguous[1].insert.?);
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
    try std.testing.expectEqual(
        MatchSuppressionReason.prefix_only,
        candidateSuppressionReason(candidate, "gco", prefix_only),
    );
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
    const double_candidates = [_]Candidate{.{
        .value = "two words$HOME",
        .replace_start = 4,
        .replace_end = double_source.len,
    }};
    const double_application = try applyCandidatesForInput(std.testing.allocator, double_source, &double_candidates);
    defer double_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"two words\\$HOME\"", double_application.edit.replacement);
    try std.testing.expect(double_application.edit.append_space);

    const single_source = "cat 'two";
    const single_candidates = [_]Candidate{.{
        .value = "two words",
        .replace_start = 4,
        .replace_end = single_source.len,
    }};
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

test "application escapes literal tilde and keeps directory completions open" {
    const tilde_source = "cat ~li";
    const tilde_candidates = [_]Candidate{.{
        .value = "~literal?",
        .replace_start = 4,
        .replace_end = tilde_source.len,
    }};
    const tilde_application = try applyCandidatesForInput(std.testing.allocator, tilde_source, &tilde_candidates);
    defer tilde_application.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\\~literal\\?", tilde_application.edit.replacement);

    const dir_source = "cat dir";
    const dir_candidates = [_]Candidate{.{
        .value = "dir name/",
        .kind = .directory,
        .replace_start = 4,
        .replace_end = dir_source.len,
        .append_space = false,
    }};
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
