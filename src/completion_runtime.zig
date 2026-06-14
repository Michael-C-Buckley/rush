//! Completion runtime.
//!
//! This module is the app-facing owner for completion query state.  The old
//! executor-backed implementation was intentionally retired; this file now keeps
//! a small buildable surface on top of completion state and semantic shell
//! state.  Dynamic provider scripts and prompt functions are temporarily stubbed
//! while the interactive layer is rebuilt on top of `shell/` and `runtime/`.

const std = @import("std");
const compat = @import("compat.zig");
const completion = @import("completion.zig");
const expand = @import("expand.zig");
const ir = @import("ir.zig");
const parser = @import("parser.zig");
const runtime = @import("runtime.zig");
const shell = @import("shell.zig");

const Self = @This();

allocator: std.mem.Allocator,
state_data: completion.State,
shell_state: shell.ShellState,
arg_zero: []const u8 = "rush",
last_status_value: shell.ExitStatus = 0,
last_command_duration_ms: i64 = 0,

pub const Options = struct {
    io: ?std.Io = null,
    allow_external: bool = false,
    features: compat.Features = .{},
    external_stdio: runtime.ExternalStdio = .capture,
    interactive: bool = false,
    foreground_terminal: bool = true,
    cancel: ?*completion.CancellationToken = null,
    arg_zero: []const u8 = "rush",
    source_path: ?[]const u8 = null,
    suppress_functions: bool = false,
    suppress_special_builtin_properties: bool = false,
    suppress_errexit: bool = false,
    ignore_errexit: bool = false,
    force_noninteractive_error_consequences: bool = false,
    default_path_lookup: bool = false,
    verbose_input_echo: bool = true,
    alias_timing_chunks: bool = true,
    top_level_parse_diagnostics: bool = false,
    completion_provider_only: bool = false,
    completion_function_sink: ?*completion.State = null,
    stdin_script_file: ?std.Io.File = null,
    stdin_script_source_offset: usize = 0,
    completion_loader: ?*const fn (*anyopaque, *Self, []const u8, completion.ScriptLoaderOptions) anyerror!void = null,
    completion_loader_context: ?*anyopaque = null,
    abort_on_output_write_failure: bool = false,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    status: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .state_data = completion.State.init(allocator),
        .shell_state = shell.ShellState.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.state_data.deinit();
    self.shell_state.deinit();
    self.* = undefined;
}

pub fn state(self: *Self) *completion.State {
    return &self.state_data;
}

pub fn stateConst(self: *const Self) *const completion.State {
    return &self.state_data;
}

pub fn generation(self: *const Self) u64 {
    return self.stateConst().generationValue();
}

pub fn copyStateFrom(self: *Self, other: *const Self) !void {
    self.state_data.deinit();
    self.state_data = completion.State.init(self.allocator);
    try self.state_data.copyFrom(&other.state_data);

    self.shell_state.deinit();
    self.shell_state = try other.shell_state.clone(self.allocator);
    self.arg_zero = other.arg_zero;
    self.last_status_value = other.last_status_value;
    self.last_command_duration_ms = other.last_command_duration_ms;
}

pub fn assertIdle(_: *const Self) void {}

pub fn importEnvironment(self: *Self, environ_map: *const std.process.Environ.Map) !void {
    var iter = environ_map.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (!isValidShellVariableName(name)) continue;
        if (std.mem.indexOfScalar(u8, value, 0) != null) continue;
        self.shell_state.putVariable(name, value, .{ .exported = true }) catch |err| switch (err) {
            error.ReadonlyVariable => {},
            else => |e| return e,
        };
    }
}

pub fn initializeShellVariables(_: *Self, _: std.Io) !void {}

pub fn setArgZero(self: *Self, arg_zero: []const u8) void {
    std.debug.assert(arg_zero.len != 0);
    self.arg_zero = arg_zero;
}

pub fn setEnv(self: *Self, name: []const u8, value: []const u8) !void {
    if (!isValidShellVariableName(name)) return;
    try self.shell_state.putVariable(name, value, .{});
}

pub fn getEnv(self: *const Self, name: []const u8) ?[]const u8 {
    if (!isValidShellVariableName(name)) return null;
    if (self.shell_state.getVariable(name)) |variable| return variable.value;
    return null;
}

pub fn setFunction(self: *Self, name: []const u8, body: []const u8, redirections: []const ir.Redirection) !void {
    try self.state_data.registerProviderFunction(name, body, redirections);
}

pub fn unsetFunction(_: *Self, _: []const u8) void {}

pub fn hasFunction(self: *const Self, name: []const u8) bool {
    return self.state_data.providerFunction(name) != null;
}

pub fn registerRule(self: *Self, rule: completion.Rule) !void {
    try self.state_data.registerRule(rule);
}

pub fn registerManifestCommandState(self: *Self, manifest_state: completion.ManifestCommandState) !void {
    try self.state_data.registerManifestCommandState(manifest_state);
}

pub fn registerVariantProbe(self: *Self, command: []const u8, args: []const []const u8, patterns: []const completion.VariantPattern) !void {
    try self.state_data.registerVariantProbe(command, args, patterns);
}

pub fn setVariantProbeMock(self: *Self, command: []const u8, stdout: []const u8) !void {
    try self.state_data.setVariantProbeMock(command, stdout);
}

pub fn clearProviderDiagnostics(self: *Self) void {
    self.state_data.clearProviderDiagnostics();
}

pub fn providerDiagnostics(self: *const Self) []const completion.ProviderDiagnostic {
    return self.stateConst().providerDiagnostics();
}

pub fn lastContext(self: *const Self) ?completion.EvalContext {
    return self.stateConst().lastContext();
}

pub fn lastSemantic(self: *const Self) ?completion.SemanticContext {
    return self.stateConst().lastSemantic();
}

pub fn lastTracePath(self: *const Self) ?[]const []const u8 {
    return self.stateConst().lastTracePath();
}

pub fn lastPrecommandDepthLimited(self: *const Self) bool {
    return self.stateConst().lastPrecommandDepthLimited();
}

pub fn analyze(self: *Self, source: []const u8, cursor: usize) !completion.SemanticContext {
    const semantic = try self.analyzeInternal(source, cursor);
    return semantic;
}

pub fn diagnostics(self: *Self, source: []const u8, cursor: usize, options: Options) ![]completion.Diagnostic {
    _ = source;
    _ = cursor;
    _ = options;
    return self.allocator.alloc(completion.Diagnostic, 0);
}

pub fn freeDiagnostics(self: *Self, diagnostics_value: []completion.Diagnostic) void {
    self.allocator.free(diagnostics_value);
}

pub fn collect(self: *Self, source: []const u8, cursor: usize, options: Options) ![]completion.Candidate {
    self.state_data.clearProviderDiagnostics();
    self.state_data.clearLastTrace();
    if (options.cancel) |cancel| if (cancel.isCanceled()) return error.Canceled;

    const context = try evalContextForInput(self.allocator, source, cursor);
    self.state_data.last_context = context;
    if (context.command.len != 0) try self.loadCompletionDataForRoot(context.command, options);

    var semantic = try self.analyzeInternal(source, cursor);
    defer semantic.deinit();
    try self.state_data.storeLastSemantic(semantic);
    try self.state_data.storeLastTracePath(semantic.root, semantic.path);

    var builder: completion.Builder = .{};
    errdefer builder.deinit(self.allocator);
    switch (semantic.position) {
        .command => try self.appendRootCommandCandidates(&builder, semantic),
        .subcommand => try self.appendSubcommandCandidates(&builder, semantic),
        .option => try self.appendOptionCandidates(&builder, semantic),
        .argument => try self.appendArgumentCandidates(&builder, semantic),
        .option_value => try self.appendOptionValueCandidates(&builder, semantic),
        .redirect_target => {},
    }
    return builder.finish(self.allocator);
}

pub fn freeCandidates(self: *Self, candidates: []completion.Candidate) void {
    completion.freeCandidates(self.allocator, candidates);
}

pub fn executeScriptSlice(self: *Self, script: []const u8, options: Options) !Result {
    _ = script;
    _ = options;
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = try self.allocator.alloc(u8, 0),
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

pub fn renderPrompt(self: *Self, options: Options, fallback: []const u8) anyerror![]const u8 {
    _ = options;
    return self.allocator.dupe(u8, fallback);
}

pub fn promptRefreshIntervalMs(_: *const Self) ?u64 {
    return null;
}

pub fn exportVariablesToShellState(_: *const Self, _: *shell.ShellState) !void {}

pub fn setPromptRepaintHandler(_: *Self, _: *anyopaque, _: *const fn (*anyopaque) void) void {}

pub fn setLastCommandDuration(self: *Self, duration_ms: i64) void {
    self.last_command_duration_ms = duration_ms;
}

pub fn setLastStatus(self: *Self, status: shell.ExitStatus) void {
    self.last_status_value = status;
    self.shell_state.last_status = status;
}

pub fn lastStatus(self: *const Self) shell.ExitStatus {
    return self.last_status_value;
}

pub fn waitForPromptAsyncRefreshes(_: *Self) void {}

pub fn syncFromShellState(self: *Self, shell_state: shell.ShellState) !void {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    self.shell_state.deinit();
    self.shell_state = try shell_state.clone(self.allocator);
    self.last_status_value = shell_state.last_status;
}

pub fn expandViPathnamePattern(_: *Self, allocator: std.mem.Allocator, _: std.Io, word: []const u8) !expand.ExpansionPattern {
    return expand.expandWordPattern(allocator, word, .{});
}

pub fn expandViPathnamePatterns(_: *Self, allocator: std.mem.Allocator, _: std.Io, word: []const u8) !expand.ExpansionPatterns {
    return expand.expandWordPatterns(allocator, word, .{});
}

pub fn expandAbbreviationForInput(self: *Self, allocator: std.mem.Allocator, source: []const u8, cursor: usize, append_space: bool) !?completion.Edit {
    const span = try commandAbbreviationSpan(allocator, source, cursor) orelse return null;
    const name = source[span.start..span.end];
    const value = self.shell_state.getAbbreviation(name) orelse return null;
    return .{
        .replace_start = span.start,
        .replace_end = span.end,
        .replacement = try allocator.dupe(u8, value),
        .append_space = append_space,
    };
}

pub fn evalContextForInput(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !completion.EvalContext {
    const view = try completionInputView(allocator, source, cursor);
    var parsed = try parser.parse(allocator, view.source, .{ .mode = .interactive, .cursor = view.cursor });
    defer parsed.deinit();
    const parser_context = parser.completionContext(parsed, view.cursor);
    const prefix = completionContextPrefix(view.source, parser_context);
    const current_token_index = parser_context.token_index;

    var command: []const u8 = "";
    var previous: []const u8 = "";
    var argument_index: usize = 0;
    var words_seen: usize = 0;
    var words: std.ArrayList(CompletionWord) = .empty;
    defer words.deinit(allocator);
    try appendActiveCompletionWords(allocator, &words, parsed, parser_context);
    for (words.items) |word_token| {
        const token = word_token.token;
        const is_current_token = word_token.index == current_token_index and parser_context.cursor <= token.span.end;
        const word = token.lexeme(view.source);
        if (words_seen == 0) {
            command = word;
        } else {
            argument_index = words_seen;
        }
        if (!is_current_token and token.span.end <= parser_context.cursor) previous = word;
        words_seen += 1;
    }

    return .{
        .prefix = prefix,
        .command = command,
        .argument_index = argument_index,
        .previous = previous,
        .position = parser_context.kind,
        .replace_start = view.offset + parser_context.span.start,
        .replace_end = view.offset + @min(parser_context.cursor, parser_context.span.end),
    };
}

pub fn optionSuppressionForOption(context: completion.SemanticContext, option: completion.Option) ?completion.OptionSuppression {
    const key = completionOptionKey(option);
    if (key != null and !option.repeatable) {
        for (context.parsed_options) |parsed| {
            if (std.mem.eql(u8, parsed.key, key.?)) return .{ .reason = .already_present, .by = parsed.spelling };
        }
    }
    if (option.exclusive_group) |group| {
        for (context.parsed_options) |parsed| {
            const parsed_group = parsed.exclusive_group orelse continue;
            if (key != null and option.repeatable and std.mem.eql(u8, parsed.key, key.?)) continue;
            if (std.mem.eql(u8, parsed_group, group)) return .{ .reason = .exclusive_group, .by = parsed.spelling, .group = group };
        }
    }
    for (context.parsed_options) |parsed| {
        for (parsed.excludes) |exclusion| switch (exclusion.kind) {
            .everything => return .{ .reason = .excluded, .by = parsed.spelling, .exclusion = "everything" },
            .operands => {},
            .option => {
                const selector = exclusion.selector orelse continue;
                if (completionOptionMatchesSelector(option, selector)) return .{ .reason = .excluded, .by = parsed.spelling, .exclusion = selector };
            },
        };
    }
    return null;
}

fn loadCompletionDataForRoot(self: *Self, command: []const u8, options: Options) !void {
    const loader = options.completion_loader orelse return;
    const context = options.completion_loader_context orelse return;
    const loader_options: completion.ScriptLoaderOptions = .{ .io = options.io, .arg_zero = options.arg_zero };
    loader_options.validate();
    try loader(context, self, command, loader_options);
}

fn analyzeInternal(self: *Self, source: []const u8, cursor: usize) !completion.SemanticContext {
    const view = try completionInputView(self.allocator, source, cursor);
    var parsed = try parser.parse(self.allocator, view.source, .{ .mode = .interactive, .cursor = view.cursor });
    defer parsed.deinit();
    const parser_context = parser.completionContext(parsed, view.cursor);
    const prefix = completionContextPrefix(view.source, parser_context);
    const replace_start = view.offset + parser_context.span.start;
    const replace_end = view.offset + @min(parser_context.cursor, parser_context.span.end);

    var words: std.ArrayList(CompletionWord) = .empty;
    defer words.deinit(self.allocator);
    try appendActiveCompletionWords(self.allocator, &words, parsed, parser_context);

    var root: []const u8 = "";
    var path: std.ArrayList([]const u8) = .empty;
    errdefer path.deinit(self.allocator);
    var argument_index: usize = 0;
    var previous: []const u8 = "";
    var index: usize = 0;
    while (index < words.items.len) : (index += 1) {
        const word_token = words.items[index];
        const token = word_token.token;
        const is_current = word_token.index == parser_context.token_index and parser_context.cursor <= token.span.end;
        if (is_current or token.span.start > parser_context.cursor) break;
        const word = token.lexeme(view.source);
        if (root.len == 0) {
            root = word;
        } else if (findCompletionSubcommand(self.state_data.rulesSlice(), root, path.items, word)) {
            try path.append(self.allocator, word);
        } else {
            argument_index += 1;
        }
        previous = word;
    }

    const owned_path = try path.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_path);
    return .{
        .allocator = self.allocator,
        .root = root,
        .path = owned_path,
        .parsed_options = try self.allocator.alloc(completion.ParsedOption, 0),
        .operands = try self.allocator.alloc(completion.ParsedOperand, 0),
        .prefix = prefix,
        .argument_index = argument_index,
        .previous = previous,
        .position = completionPositionForParserContext(parser_context, prefix),
        .replace_start = replace_start,
        .replace_end = replace_end,
        .parser_position = parser_context.kind,
        .parser_source_offset = view.offset,
    };
}

fn appendRootCommandCandidates(self: *Self, builder: *completion.Builder, semantic: completion.SemanticContext) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);
    for (self.state_data.rulesSlice()) |rule| {
        if (rule.disabled) continue;
        try appendCandidateOnce(self.allocator, builder, &seen, rule.root, .command, null, semantic);
    }
    var functions = self.shell_state.functions.iterator();
    while (functions.next()) |entry| try appendCandidateOnce(self.allocator, builder, &seen, entry.key_ptr.*, .function, null, semantic);
    var aliases = self.shell_state.aliases.iterator();
    while (aliases.next()) |entry| try appendCandidateOnce(self.allocator, builder, &seen, entry.key_ptr.*, .command, null, semantic);
}

fn appendSubcommandCandidates(self: *Self, builder: *completion.Builder, semantic: completion.SemanticContext) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);
    for (self.state_data.rulesSlice()) |rule| {
        if (rule.disabled or rule.kind != .subcommand) continue;
        if (!completionRuleContextMatches(rule, semantic.root, semantic.path)) continue;
        const value = rule.value orelse continue;
        try appendCandidateOnce(self.allocator, builder, &seen, value, .subcommand, rule.description, semantic);
    }
}

fn appendOptionCandidates(self: *Self, builder: *completion.Builder, semantic: completion.SemanticContext) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);
    for (self.state_data.rulesSlice()) |rule| {
        if (rule.disabled or rule.kind != .option) continue;
        if (!completionRuleContextMatches(rule, semantic.root, semantic.path)) continue;
        for (rule.option.spellings) |spelling| try appendOptionCandidate(self.allocator, builder, &seen, spelling, rule, semantic);
        if (rule.option.long) |long| {
            const spelling = try std.fmt.allocPrint(self.allocator, "--{s}", .{long});
            defer self.allocator.free(spelling);
            try appendOptionCandidate(self.allocator, builder, &seen, spelling, rule, semantic);
        }
        if (rule.option.short) |short| {
            const spelling = try std.fmt.allocPrint(self.allocator, "-{s}", .{short});
            defer self.allocator.free(spelling);
            try appendOptionCandidate(self.allocator, builder, &seen, spelling, rule, semantic);
        }
    }
}

fn appendArgumentCandidates(self: *Self, builder: *completion.Builder, semantic: completion.SemanticContext) !void {
    for (self.state_data.rulesSlice()) |rule| {
        if (rule.disabled or rule.kind != .dynamic_argument or rule.provider_kind != .static_enum) continue;
        if (!completionRuleContextMatches(rule, semantic.root, semantic.path)) continue;
        try appendStaticValues(self.allocator, builder, rule, semantic);
    }
}

fn appendOptionValueCandidates(self: *Self, builder: *completion.Builder, semantic: completion.SemanticContext) !void {
    for (self.state_data.rulesSlice()) |rule| {
        if (rule.disabled or rule.kind != .dynamic_option_value or rule.provider_kind != .static_enum) continue;
        if (!completionRuleContextMatches(rule, semantic.root, semantic.path)) continue;
        try appendStaticValues(self.allocator, builder, rule, semantic);
    }
}

fn appendStaticValues(allocator: std.mem.Allocator, builder: *completion.Builder, rule: completion.Rule, semantic: completion.SemanticContext) !void {
    for (rule.static_values) |value| {
        if (completion.fuzzyMatchRank(value.value, semantic.prefix) == null) continue;
        try builder.appendCandidate(allocator, .{
            .value = value.value,
            .display = value.display,
            .description = value.description orelse rule.description,
            .tag = value.tag orelse rule.tag,
            .suffix = value.suffix,
            .removable_suffix = value.removable_suffix,
            .kind = .plain,
            .replace_start = semantic.replace_start,
            .replace_end = semantic.replace_end,
            .append_space = value.append_space,
            .provider_order = rule.provider_order,
        });
    }
}

fn appendOptionCandidate(allocator: std.mem.Allocator, builder: *completion.Builder, seen: *std.StringHashMapUnmanaged(void), spelling: []const u8, rule: completion.Rule, semantic: completion.SemanticContext) !void {
    if (completion.fuzzyMatchRank(spelling, semantic.prefix) == null) return;
    if (seen.contains(spelling)) return;
    const seen_spelling = try allocator.dupe(u8, spelling);
    errdefer allocator.free(seen_spelling);
    try seen.put(allocator, seen_spelling, {});
    try builder.appendCandidate(allocator, .{
        .value = spelling,
        .description = rule.description,
        .tag = rule.tag,
        .kind = .option,
        .option = rule.option,
        .replace_start = semantic.replace_start,
        .replace_end = semantic.replace_end,
        .append_space = !rule.option.no_space,
        .provider_order = rule.provider_order,
    });
}

fn appendCandidateOnce(allocator: std.mem.Allocator, builder: *completion.Builder, seen: *std.StringHashMapUnmanaged(void), value: []const u8, kind: completion.Kind, description: ?[]const u8, semantic: completion.SemanticContext) !void {
    if (completion.fuzzyMatchRank(value, semantic.prefix) == null) return;
    if (seen.contains(value)) return;
    const seen_value = try allocator.dupe(u8, value);
    errdefer allocator.free(seen_value);
    try seen.put(allocator, seen_value, {});
    try builder.appendCandidate(allocator, .{
        .value = value,
        .description = description,
        .kind = kind,
        .replace_start = semantic.replace_start,
        .replace_end = semantic.replace_end,
    });
}

fn completionRuleContextMatches(rule: completion.Rule, root: []const u8, path: []const []const u8) bool {
    if (!std.mem.eql(u8, rule.root, root)) return false;
    if (rule.path.len != path.len) return false;
    for (rule.path, path) |expected, actual| if (!std.mem.eql(u8, expected, actual)) return false;
    return true;
}

fn findCompletionSubcommand(rules: []const completion.Rule, root: []const u8, path: []const []const u8, word: []const u8) bool {
    for (rules) |rule| {
        if (rule.disabled or rule.kind != .subcommand) continue;
        if (!completionRuleContextMatches(rule, root, path)) continue;
        if (rule.value) |value| if (std.mem.eql(u8, value, word)) return true;
    }
    return false;
}

fn completionOptionKey(option: completion.Option) ?[]const u8 {
    if (option.long) |long| return long;
    if (option.short) |short| return short;
    if (option.spellings.len != 0) return option.spellings[0];
    return null;
}

fn completionOptionMatchesSelector(option: completion.Option, selector: []const u8) bool {
    if (std.mem.startsWith(u8, selector, "--")) {
        const long_selector = selector[2..];
        if (option.long) |long| return std.mem.eql(u8, long, long_selector);
        return false;
    }
    if (std.mem.startsWith(u8, selector, "-") and selector.len == 2) {
        const short_selector = selector[1..];
        if (option.short) |short| return std.mem.eql(u8, short, short_selector);
        return false;
    }
    return false;
}

const CompletionInputView = struct {
    source: []const u8,
    cursor: usize,
    offset: usize,
};

const CompletionWord = struct {
    index: usize,
    token: parser.Token,
};

const TokenRange = struct {
    start: usize,
    end: usize,
};

fn completionInputView(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !CompletionInputView {
    const clamped_cursor = @min(cursor, source.len);
    if (try commandSubstitutionCompletionValueSpan(allocator, source, clamped_cursor)) |span| {
        return .{
            .source = source[span.start..span.end],
            .cursor = clamped_cursor - span.start,
            .offset = span.start,
        };
    }
    return .{ .source = source, .cursor = clamped_cursor, .offset = 0 };
}

fn commandSubstitutionCompletionValueSpan(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !?parser.Span {
    var best: ?parser.Span = null;
    var index: usize = 0;
    var single = false;
    var double = false;
    while (index < cursor) : (index += 1) {
        const byte = source[index];
        if (byte == '\\' and !single) {
            if (index + 1 < cursor) index += 1;
            continue;
        }
        if (byte == '\'' and !double) {
            single = !single;
            continue;
        }
        if (byte == '"' and !single) {
            double = !double;
            continue;
        }
        if (single or byte != '$' or index + 1 >= source.len or source[index + 1] != '(') continue;
        if (index + 2 < source.len and source[index + 2] == '(') continue;

        const value_start = index + 2;
        if (cursor < value_start) continue;
        if (try parser.commandSubstitutionEnd(allocator, source, source.len, index)) |end| {
            const value_end = end - 1;
            if (cursor <= value_end) best = .init(value_start, value_end);
        } else {
            best = .init(value_start, source.len);
        }
    }
    return best;
}

fn appendActiveCompletionWords(allocator: std.mem.Allocator, words: *std.ArrayList(CompletionWord), parsed: parser.ParseResult, context: parser.CompletionContext) !void {
    const range = activeSimpleCommandTokenRange(parsed, context) orelse return;
    for (range.start..range.end) |index| {
        const token = parsed.tokens[index];
        if (token.span.start > context.cursor) break;
        if (token.kind != .word) continue;
        const node_kind = parser.nodeKindForToken(parsed, index) orelse continue;
        switch (node_kind) {
            .command_word, .word => {},
            .assignment_word, .io_number => continue,
            else => continue,
        }
        if (parser.tokenHasNodeKind(parsed, index, .redirection)) continue;
        try words.append(allocator, .{ .index = index, .token = token });
    }
}

fn activeSimpleCommandTokenRange(parsed: parser.ParseResult, context: parser.CompletionContext) ?TokenRange {
    if (context.token_index) |token_index| {
        if (simpleCommandNodeForToken(parsed, token_index)) |node| return .{ .start = node.token_start, .end = node.token_end };
    }

    var best: ?parser.Node = null;
    for (parsed.nodes) |node| {
        if (node.kind != .simple_command) continue;
        if (!node.span.touches(context.cursor)) continue;
        if (best == null or node.span.len() < best.?.span.len()) best = node;
    }
    if (best) |node| return .{ .start = node.token_start, .end = node.token_end };
    return null;
}

fn simpleCommandNodeForToken(parsed: parser.ParseResult, token_index: usize) ?parser.Node {
    var best: ?parser.Node = null;
    for (parsed.nodes) |node| {
        if (node.kind != .simple_command) continue;
        if (token_index < node.token_start or token_index >= node.token_end) continue;
        if (best == null or node.span.len() < best.?.span.len()) best = node;
    }
    return best;
}

fn completionPositionForParserContext(context: parser.CompletionContext, prefix: []const u8) completion.SemanticPosition {
    return switch (context.kind) {
        .command, .assignment_name => .command,
        .redirect_target => .redirect_target,
        .argument, .assignment_value, .quoted_string => if (std.mem.startsWith(u8, prefix, "-")) .option else .argument,
        .parameter, .separator => .argument,
    };
}

fn completionContextPrefix(source: []const u8, context: parser.CompletionContext) []const u8 {
    const start = context.span.start;
    const end = @min(context.cursor, context.span.end);
    if (start >= end or end > source.len) return "";
    return source[start..end];
}

fn commandAbbreviationSpan(allocator: std.mem.Allocator, source: []const u8, cursor: usize) !?parser.Span {
    const clamped_cursor = @min(cursor, source.len);
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .cursor = clamped_cursor });
    defer parsed.deinit();
    const highlights = try parser.syntaxHighlights(allocator, parsed);
    defer allocator.free(highlights);
    var selected: ?parser.Span = null;
    for (highlights) |highlight| {
        if (highlight.kind != .command) continue;
        if (clamped_cursor < highlight.span.end) return null;
        selected = highlight.span;
    }
    return selected;
}

fn isValidShellVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_')) return false;
    }
    return true;
}
