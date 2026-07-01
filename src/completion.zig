//! Rush interactive completion service.

const std = @import("std");
const build_config = @import("build_config");

const editor_completion = @import("editor/completion.zig");
const extensions = @import("extensions.zig");
const host = @import("host.zig");
const shell = @import("shell.zig");

pub const Application = editor_completion.Application;

const max_manifest_bytes = 4 * 1024 * 1024;
const max_companion_bytes = 1024 * 1024;

pub fn complete(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    source: []const u8,
    cursor: usize,
) !Application {
    const sh = rushShellFromOpaque(context);
    const analyzed = try analyzeLine(allocator, source, cursor);
    defer analyzed.deinit(allocator);

    var builder: Builder = .{};
    defer builder.deinit(allocator);

    if (analyzed.kind == .parameter) {
        try appendVariableCandidates(allocator, &builder, sh, analyzed.replace_start, analyzed.replace_end);
        return applyBuiltCandidates(allocator, source, &builder);
    }

    if (analyzed.kind == .command) {
        if (std.mem.indexOfScalar(u8, analyzed.prefix, '/') == null) {
            try appendCommandCandidates(allocator, &builder, sh, analyzed.replace_start, analyzed.replace_end);
            return applyBuiltCandidates(allocator, source, &builder);
        }
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendPathCandidates(allocator, &builder, sh, analyzed.prefix, analyzed.replace_start, analyzed.replace_end, false);
        return applyBuiltCandidates(allocator, source, &builder);
    }

    if (analyzed.root) |root| {
        if (try completeFromManifest(allocator, io, sh, &builder, analyzed, root)) |handled| {
            if (handled) return applyBuiltCandidates(allocator, source, &builder);
        }
    }

    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    try appendPathCandidates(allocator, &builder, sh, analyzed.prefix, analyzed.replace_start, analyzed.replace_end, false);
    return applyBuiltCandidates(allocator, source, &builder);
}

fn rushShellFromOpaque(context: *anyopaque) *shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry) {
    return @ptrCast(@alignCast(context));
}

const CompletionKind = enum {
    command,
    argument,
    parameter,
};

const Word = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

const AnalyzedLine = struct {
    words: []Word,
    current_word_index: ?usize,
    replace_start: usize,
    replace_end: usize,
    prefix: []const u8,
    kind: CompletionKind,
    root: ?[]const u8,
    command_word_index: ?usize,

    fn deinit(self: AnalyzedLine, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
    }
};

fn analyzeLine(allocator: std.mem.Allocator, source: []const u8, raw_cursor: usize) !AnalyzedLine {
    const cursor = @min(raw_cursor, source.len);
    var words: std.ArrayList(Word) = .empty;
    errdefer words.deinit(allocator);
    try scanWords(allocator, source, cursor, &words);

    var current_word_index: ?usize = null;
    for (words.items, 0..) |word, index| {
        if (word.start <= cursor and cursor <= word.end) {
            current_word_index = index;
            break;
        }
    }

    const replace_start = if (current_word_index) |index| words.items[index].start else cursor;
    const replace_end = if (current_word_index) |index| words.items[index].end else cursor;
    const raw_prefix = source[replace_start..cursor];
    const parameter = raw_prefix.len != 0 and raw_prefix[0] == '$';
    const prefix = if (parameter) raw_prefix[1..] else raw_prefix;

    const command_word_index = findCommandWord(source, words.items, cursor);
    const is_command = if (command_word_index) |command_index|
        current_word_index != null and current_word_index.? == command_index
    else
        true;
    const kind: CompletionKind = if (parameter) .parameter else if (is_command) .command else .argument;
    const root = if (command_word_index) |index| words.items[index].text else null;

    return .{
        .words = try words.toOwnedSlice(allocator),
        .current_word_index = current_word_index,
        .replace_start = if (parameter) replace_start + 1 else replace_start,
        .replace_end = replace_end,
        .prefix = prefix,
        .kind = kind,
        .root = root,
        .command_word_index = command_word_index,
    };
}

fn scanWords(allocator: std.mem.Allocator, source: []const u8, cursor: usize, words: *std.ArrayList(Word)) !void {
    var index: usize = 0;
    while (index < cursor) {
        while (index < cursor and isWordSeparator(source[index])) index += 1;
        if (index >= cursor) break;
        const start = index;
        var quote: ?u8 = null;
        while (index < source.len) : (index += 1) {
            const byte = source[index];
            if (quote) |quoted| {
                if (byte == quoted) quote = null;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                continue;
            }
            if (isWordSeparator(byte)) break;
        }
        try words.append(allocator, .{ .text = source[start..index], .start = start, .end = index });
    }
}

fn isWordSeparator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', ';', '|', '&', '(', ')', '<', '>' => true,
        else => false,
    };
}

fn findCommandWord(source: []const u8, words: []const Word, cursor: usize) ?usize {
    if (words.len == 0) return null;
    var selected: ?usize = null;
    for (words, 0..) |word, index| {
        if (word.start > cursor) break;
        selected = index;
    }
    if (selected == null) return null;
    if (words[selected.?].end < cursor and commandBoundaryBetween(source, words[selected.?].end, cursor)) return null;
    var index = selected.?;
    while (index > 0) {
        const previous = words[index - 1];
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (previous.end < words[index].start and commandBoundaryBetween(source, previous.end, words[index].start)) return index;
        index -= 1;
    }
    return 0;
}

fn commandBoundaryBetween(source: []const u8, start: usize, end: usize) bool {
    for (source[start..end]) |byte| switch (byte) {
        ';', '|', '&', '\n' => return true,
        else => {},
    };
    return false;
}

const Builder = struct {
    candidates: std.ArrayList(editor_completion.Candidate) = .empty,
    next_source_order: usize = 0,

    fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        if (self.candidates.items.len != 0) {
            const candidates = self.candidates.toOwnedSlice(allocator) catch unreachable;
            editor_completion.freeCandidates(allocator, candidates);
        } else self.candidates.deinit(allocator);
        self.* = undefined;
    }

    fn append(self: *Builder, allocator: std.mem.Allocator, candidate: editor_completion.Candidate) !void {
        if (self.contains(candidate)) return;
        var owned = candidate;
        owned.value = try allocator.dupe(u8, candidate.value);
        errdefer allocator.free(owned.value);
        if (candidate.display) |display| owned.display = try allocator.dupe(u8, display);
        errdefer if (owned.display) |display| allocator.free(display);
        if (candidate.insert) |insert| owned.insert = try allocator.dupe(u8, insert);
        errdefer if (owned.insert) |insert| allocator.free(insert);
        if (candidate.description) |description| owned.description = try allocator.dupe(u8, description);
        errdefer if (owned.description) |description| allocator.free(description);
        if (candidate.tag) |tag| owned.tag = try allocator.dupe(u8, tag);
        errdefer if (owned.tag) |tag| allocator.free(tag);
        if (candidate.suffix) |suffix| owned.suffix = try allocator.dupe(u8, suffix);
        errdefer if (owned.suffix) |suffix| allocator.free(suffix);
        owned.source_order = self.next_source_order;
        self.next_source_order += 1;
        try self.candidates.append(allocator, owned);
    }

    fn contains(self: Builder, candidate: editor_completion.Candidate) bool {
        for (self.candidates.items) |existing| {
            if (existing.replace_start == candidate.replace_start and
                existing.replace_end == candidate.replace_end and
                std.mem.eql(u8, existing.value, candidate.value)) return true;
        }
        return false;
    }

    fn take(self: *Builder, allocator: std.mem.Allocator) ![]editor_completion.Candidate {
        editor_completion.sortCandidates(self.candidates.items);
        const candidates = try self.candidates.toOwnedSlice(allocator);
        self.candidates = .empty;
        return candidates;
    }
};

fn applyBuiltCandidates(allocator: std.mem.Allocator, source: []const u8, builder: *Builder) !Application {
    const candidates = try builder.take(allocator);
    defer editor_completion.freeCandidates(allocator, candidates);

    var matches: std.ArrayList(editor_completion.Candidate) = .empty;
    defer matches.deinit(allocator);
    for (candidates) |candidate| {
        const query = source[candidate.replace_start..candidate.replace_end];
        if (editor_completion.candidateMatchRank(candidate, query, .prefixOnly()) != null) {
            try matches.append(allocator, candidate);
        }
    }
    return editor_completion.applyCandidates(allocator, matches.items);
}

fn completeFromManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    root: []const u8,
) !?bool {
    const manifest_path = try findCompletionFile(allocator, sh, root, ".json") orelse return null;
    defer allocator.free(manifest_path);
    const companion_path = try findCompletionFile(allocator, sh, root, ".rush");
    defer if (companion_path) |path| allocator.free(path);

    const contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(max_manifest_bytes),
    ) catch return null;
    defer allocator.free(contents);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();
    const command = jsonObjectField(parsed.value, "command") orelse return null;
    const providers = jsonObjectField(command, "providers");

    const command_word_index = analyzed.command_word_index orelse return null;
    const current_relative_word_index = if (analyzed.current_word_index) |index|
        if (index > command_word_index) index - command_word_index - 1 else 0
    else
        null;
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const current = selectedCommand(command, analyzed.words[command_word_index + 1 ..], current_relative_word_index, providers) orelse command;
    const semantic = semanticContext(analyzed, command_word_index, current);

    if (semantic.complete_options) {
        try appendOptionCandidates(allocator, builder, current, analyzed.replace_start, analyzed.replace_end);
        return true;
    }

    if (semantic.option_value_provider) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendProviderCandidates(allocator, io, sh, builder, analyzed, semantic, current, providers, provider, companion_path);
        return true;
    }

    if (semantic.complete_subcommands) {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendSubcommandCandidates(allocator, builder, current, providers, analyzed.replace_start, analyzed.replace_end);
        return true;
    }

    if (argumentProvider(current, semantic.operand_index)) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendProviderCandidates(allocator, io, sh, builder, analyzed, semantic, current, providers, provider, companion_path);
        return true;
    }
    return false;
}

const Semantic = struct {
    operand_index: usize,
    options_terminated: bool,
    complete_options: bool = false,
    complete_subcommands: bool = false,
    option_value_provider: ?std.json.Value = null,
};

fn semanticContext(analyzed: AnalyzedLine, command_word_index: usize, command: std.json.Value) Semantic {
    var operand_index: usize = 0;
    var options_terminated = false;
    var pending_option_value: ?std.json.Value = null;
    var pending_option_word_index: ?usize = null;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    var skipped_selected_subcommand = false;
    for (analyzed.words[command_word_index + 1 ..], command_word_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
        if (!skipped_selected_subcommand) {
            if (commandName(command)) |name| {
                if (std.mem.eql(u8, word.text, name)) {
                    skipped_selected_subcommand = true;
                    continue;
                }
            }
            skipped_selected_subcommand = true;
        }
        if (pending_option_value != null) {
            pending_option_value = null;
            pending_option_word_index = null;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            if (optionForSpelling(command, word.text)) |option| {
                if (jsonObjectField(option, "value")) |value| {
                    pending_option_value = value;
                    pending_option_word_index = absolute_index;
                }
            }
            continue;
        }
        operand_index += 1;
    }

    if (pending_option_value) |value| {
        if (pending_option_word_index != null) {
            return .{
                .operand_index = operand_index,
                .options_terminated = options_terminated,
                .option_value_provider = jsonField(value, "provider"),
            };
        }
    }

    const prefix_is_option = analyzed.prefix.len != 0 and analyzed.prefix[0] == '-' and !options_terminated;
    return .{
        .operand_index = operand_index,
        .options_terminated = options_terminated,
        .complete_options = prefix_is_option,
        .complete_subcommands = operand_index == 0 and commandHasSubcommands(command),
    };
}

fn selectedCommand(
    root: std.json.Value,
    words: []const Word,
    current_word_index: ?usize,
    providers: ?std.json.Value,
) ?std.json.Value {
    var command = root;
    const limit = if (current_word_index) |index| @min(index, words.len) else words.len;
    for (words, 0..) |word, relative_index| {
        if (relative_index >= limit) break;
        if (std.mem.startsWith(u8, word.text, "-")) continue;
        if (subcommandForName(command, providers, word.text)) |subcommand| {
            command = subcommand;
            continue;
        }
        break;
    }
    return command;
}

fn appendOptionCandidates(
    allocator: std.mem.Allocator,
    builder: *Builder,
    command: std.json.Value,
    replace_start: usize,
    replace_end: usize,
) !void {
    const options = jsonArrayField(command, "options") orelse return;
    for (options.items) |option| try appendOptionCandidate(allocator, builder, option, replace_start, replace_end);
}

fn appendOptionCandidate(
    allocator: std.mem.Allocator,
    builder: *Builder,
    option: std.json.Value,
    replace_start: usize,
    replace_end: usize,
) !void {
    const object = jsonObject(option) orelse return;
    if (object.get("provider")) |_| return;
    const description = jsonStringField(option, "description");
    const priority = jsonI8Field(option, "priority") orelse 0;
    if (jsonStringField(option, "long")) |long| {
        const value = try std.fmt.allocPrint(allocator, "--{s}", .{long});
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .description = description, .kind = .option, .priority = priority, .replace_start = replace_start, .replace_end = replace_end });
    }
    if (jsonStringField(option, "short")) |short| {
        const value = try std.fmt.allocPrint(allocator, "-{s}", .{short});
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .description = description, .kind = .option, .priority = priority, .replace_start = replace_start, .replace_end = replace_end });
    }
    if (jsonArrayField(option, "spellings")) |spellings| {
        for (spellings.items) |spelling_value| {
            const spelling = jsonString(spelling_value) orelse continue;
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = spelling, .description = description, .kind = .option, .priority = priority, .replace_start = replace_start, .replace_end = replace_end });
        }
    }
}

fn appendSubcommandCandidates(
    allocator: std.mem.Allocator,
    builder: *Builder,
    command: std.json.Value,
    providers: ?std.json.Value,
    replace_start: usize,
    replace_end: usize,
) !void {
    const subcommands = jsonArrayField(command, "subcommands") orelse return;
    for (subcommands.items) |subcommand| {
        if (jsonObjectField(subcommand, "provider")) |provider| {
            _ = provider;
            _ = providers;
            continue;
        }
        const name = commandName(subcommand) orelse continue;
        try builder.append(allocator, .{
            .value = name,
            .description = jsonStringField(subcommand, "description"),
            .kind = .subcommand,
            .priority = jsonI8Field(subcommand, "priority") orelse 0,
            .replace_start = replace_start,
            .replace_end = replace_end,
        });
    }
}

fn appendProviderCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    semantic: Semantic,
    command: std.json.Value,
    providers: ?std.json.Value,
    provider_ref: std.json.Value,
    companion_path: ?[]const u8,
) !void {
    if (providerValue(providers, provider_ref)) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (jsonStringField(provider, "builtin")) |name| return appendBuiltinProvider(allocator, builder, sh, analyzed, name);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (jsonArrayField(provider, "values")) |values| return appendStaticValues(allocator, builder, analyzed, values);
        if (jsonStringField(provider, "function")) |function_name| {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            return appendFunctionProvider(allocator, io, sh, builder, analyzed, semantic, command, function_name, companion_path);
        }
    } else if (jsonString(provider_ref)) |builtin_name| {
        if (std.mem.startsWith(u8, builtin_name, "builtin.")) {
            return appendBuiltinProvider(allocator, builder, sh, analyzed, builtin_name["builtin.".len..]);
        }
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendBuiltinProvider(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, analyzed: AnalyzedLine, name: []const u8) !void {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "files")) return appendPathCandidates(allocator, builder, sh, analyzed.prefix, analyzed.replace_start, analyzed.replace_end, false);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "directories")) return appendPathCandidates(allocator, builder, sh, analyzed.prefix, analyzed.replace_start, analyzed.replace_end, true);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "executables")) return appendPathExecutableCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "variables")) return appendVariableCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "aliases")) return appendAliasCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "functions")) return appendFunctionCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    if (std.mem.eql(u8, name, "jobs")) return appendJobCandidates(allocator, builder, sh, analyzed.replace_start, analyzed.replace_end);
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendStaticValues(allocator: std.mem.Allocator, builder: *Builder, analyzed: AnalyzedLine, values: std.json.Array) !void {
    for (values.items) |value| {
        if (jsonString(value)) |text| {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = text, .replace_start = analyzed.replace_start, .replace_end = analyzed.replace_end });
            continue;
        }
        const text = jsonStringField(value, "value") orelse continue;
        try builder.append(allocator, .{
            .value = text,
            .display = jsonStringField(value, "display"),
            .description = jsonStringField(value, "description"),
            .tag = jsonStringField(value, "tag"),
            .suffix = jsonStringField(value, "suffix"),
            .removable_suffix = jsonBoolField(value, "removableSuffix") orelse false,
            .priority = jsonI8Field(value, "priority") orelse 0,
            .append_space = !(jsonBoolField(value, "noSpace") orelse false),
            .replace_start = analyzed.replace_start,
            .replace_end = analyzed.replace_end,
        });
    }
}

fn appendFunctionProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    semantic: Semantic,
    command: std.json.Value,
    function_name: []const u8,
    companion_path: ?[]const u8,
) !void {
    if (companion_path) |path| try sourceCompanionIfNeeded(allocator, io, sh, path);

    const parsed_options = try parsedOptionsForProvider(allocator, analyzed, command);
    defer allocator.free(parsed_options);
    const operands = try operandsForProvider(allocator, analyzed, command);
    defer allocator.free(operands);
    var provider_context = extensions.rush.CompletionContext.init(
        allocator,
        analyzed.prefix,
        analyzed.replace_start,
        analyzed.replace_end,
        semantic.operand_index,
        semantic.options_terminated,
        if (semantic.option_value_provider != null) "value" else "item",
        parsed_options,
        operands,
    );
    defer provider_context.deinit();

    const previous_context = sh.extensions.completion_context;
    sh.extensions.completion_context = &provider_context;
    defer sh.extensions.completion_context = previous_context;

    const argument_index = try std.fmt.allocPrint(allocator, "{d}", .{semantic.operand_index});
    defer allocator.free(argument_index);
    try sh.state.putVariable(.{ .name = "rush_completion_argument_index", .value = argument_index });
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    try sh.state.putVariable(.{ .name = "rush_completion_options_terminated", .value = if (semantic.options_terminated) "true" else "false" });
    try sh.state.putVariable(.{ .name = "rush_completion_value_position", .value = provider_context.value_position });

    var discard = OutputDiscard.init(&sh.host) catch null;
    defer if (discard) |*active| active.restore(&sh.host) catch {};
    const src: shell.source.Source = .{ .id = 0, .kind = .command_string, .name = "completion", .text = function_name };
    const evaluated = sh.evalSourceNested(src) catch return;
    if (evaluated.status != 0 or evaluated.flow != .normal) return;

    const candidates = try provider_context.takeCandidates();
    defer editor_completion.freeCandidates(allocator, candidates);
    for (candidates) |candidate| try builder.append(allocator, candidate);
}

fn parsedOptionsForProvider(
    allocator: std.mem.Allocator,
    analyzed: AnalyzedLine,
    command: std.json.Value,
) ![]extensions.rush.CompletionParsedOption {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const command_index = analyzed.command_word_index orelse return allocator.alloc(extensions.rush.CompletionParsedOption, 0);
    var options: std.ArrayList(extensions.rush.CompletionParsedOption) = .empty;
    errdefer options.deinit(allocator);
    var pending_index: ?usize = null;
    var skipped_selected_subcommand = false;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    for (analyzed.words[command_index + 1 ..], command_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
        if (!skipped_selected_subcommand and wordMatchesCommandName(command, word.text)) {
            skipped_selected_subcommand = true;
            continue;
        }
        skipped_selected_subcommand = true;
        if (pending_index) |index| {
            options.items[index].value = word.text;
            pending_index = null;
            continue;
        }
        if (!std.mem.startsWith(u8, word.text, "-")) continue;
        const option = optionForSpelling(command, word.text) orelse continue;
        const name = optionName(option, word.text);
        try options.append(allocator, .{ .spelling = word.text, .name = name, .key = name });
        if (jsonObjectField(option, "value") != null) pending_index = options.items.len - 1;
    }
    return options.toOwnedSlice(allocator);
}

fn operandsForProvider(
    allocator: std.mem.Allocator,
    analyzed: AnalyzedLine,
    command: std.json.Value,
) ![]extensions.rush.CompletionParsedOperand {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const command_index = analyzed.command_word_index orelse return allocator.alloc(extensions.rush.CompletionParsedOperand, 0);
    var operands: std.ArrayList(extensions.rush.CompletionParsedOperand) = .empty;
    errdefer operands.deinit(allocator);
    var operand_index: usize = 0;
    var skipped_selected_subcommand = false;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    for (analyzed.words[command_index + 1 ..], command_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
        if (!skipped_selected_subcommand and wordMatchesCommandName(command, word.text)) {
            skipped_selected_subcommand = true;
            continue;
        }
        skipped_selected_subcommand = true;
        if (std.mem.startsWith(u8, word.text, "-")) continue;
        try operands.append(allocator, .{ .value = word.text, .index = operand_index });
        operand_index += 1;
    }
    return operands.toOwnedSlice(allocator);
}

fn optionName(option: std.json.Value, spelling: []const u8) []const u8 {
    if (jsonStringField(option, "long")) |long| return long;
    if (jsonStringField(option, "short")) |short| return short;
    return spelling;
}

fn sourceCompanionIfNeeded(allocator: std.mem.Allocator, io: std.Io, sh: anytype, path: []const u8) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_companion_bytes)) catch return;
    defer allocator.free(text);
    const src: shell.source.Source = .{ .id = 0, .kind = .sourced_file, .name = path, .text = text };
    _ = sh.evalSourceNested(src) catch return;
}

fn argumentProvider(command: std.json.Value, operand_index: usize) ?std.json.Value {
    const arguments = jsonObjectField(command, "arguments") orelse return null;
    const states = jsonArrayField(arguments, "states") orelse return null;
    var repeatable_provider: ?std.json.Value = null;
    for (states.items) |state| {
        const provider = jsonObjectField(state, "provider") orelse jsonField(state, "provider") orelse continue;
        const index = jsonUsizeField(state, "index");
        if (index != null and index.? == operand_index) return provider;
        if (jsonBoolField(state, "repeatable") orelse false) repeatable_provider = provider;
    }
    return repeatable_provider;
}

fn optionForSpelling(command: std.json.Value, spelling: []const u8) ?std.json.Value {
    const options = jsonArrayField(command, "options") orelse return null;
    for (options.items) |option| {
        if (optionMatchesSpelling(option, spelling)) return option;
    }
    return null;
}

fn optionMatchesSpelling(option: std.json.Value, spelling: []const u8) bool {
    if (jsonStringField(option, "long")) |long| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (spelling.len == long.len + 2 and std.mem.eql(u8, spelling[0..2], "--") and std.mem.eql(u8, spelling[2..], long)) return true;
    }
    if (jsonStringField(option, "short")) |short| {
        if (spelling.len == short.len + 1 and spelling[0] == '-' and std.mem.eql(u8, spelling[1..], short)) return true;
    }
    if (jsonArrayField(option, "spellings")) |spellings| {
        for (spellings.items) |item| if (jsonString(item)) |value| if (std.mem.eql(u8, spelling, value)) return true;
    }
    return false;
}

fn subcommandForName(command: std.json.Value, providers: ?std.json.Value, name: []const u8) ?std.json.Value {
    _ = providers;
    const subcommands = jsonArrayField(command, "subcommands") orelse return null;
    for (subcommands.items) |subcommand| {
        if (commandNameMatches(subcommand, name)) return subcommand;
    }
    return null;
}

fn commandHasSubcommands(command: std.json.Value) bool {
    const subcommands = jsonArrayField(command, "subcommands") orelse return false;
    return subcommands.items.len != 0;
}

fn commandName(command: std.json.Value) ?[]const u8 {
    if (jsonStringField(command, "name")) |name| return name;
    const names = jsonArrayField(command, "name") orelse return null;
    if (names.items.len == 0) return null;
    return jsonString(names.items[0]);
}

fn commandNameMatches(command: std.json.Value, name: []const u8) bool {
    return wordMatchesCommandName(command, name);
}

fn wordMatchesCommandName(command: std.json.Value, name: []const u8) bool {
    if (commandName(command)) |primary| if (std.mem.eql(u8, primary, name)) return true;
    if (jsonArrayField(command, "aliases")) |aliases| {
        for (aliases.items) |alias| if (jsonString(alias)) |value| if (std.mem.eql(u8, value, name)) return true;
    }
    return false;
}

fn providerValue(providers: ?std.json.Value, ref: std.json.Value) ?std.json.Value {
    if (jsonString(ref)) |name| {
        const provider_object = providers orelse return null;
        return jsonField(provider_object, name);
    }
    return ref;
}

fn findCompletionFile(allocator: std.mem.Allocator, sh: anytype, root: []const u8, extension: []const u8) !?[]const u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ root, extension });
    defer allocator.free(file_name);
    const local = try std.fs.path.join(allocator, &.{ "share", "rush", "completions", file_name });
    if (try fileExists(sh, local)) return local;
    allocator.free(local);
    if (shellValue(sh, "XDG_CONFIG_HOME")) |xdg_config_home| {
        const path = try std.fs.path.join(allocator, &.{ xdg_config_home, "rush", "completions", file_name });
        if (try fileExists(sh, path)) return path;
        allocator.free(path);
    }
    if (shellValue(sh, "HOME")) |home| {
        const path = try std.fs.path.join(allocator, &.{ home, ".config", "rush", "completions", file_name });
        if (try fileExists(sh, path)) return path;
        allocator.free(path);
    }
    const installed = try std.fs.path.join(allocator, &.{ build_config.datadir, "rush", "completions", file_name });
    if (try fileExists(sh, installed)) return installed;
    allocator.free(installed);
    return null;
}

fn fileExists(sh: anytype, path: []const u8) !bool {
    const path_z = try sh.allocator.dupeZ(u8, path);
    defer sh.allocator.free(path_z);
    return sh.host.existsZ(path_z);
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendCommandCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    try appendAliasCandidates(allocator, builder, sh, replace_start, replace_end);
    try appendFunctionCandidates(allocator, builder, sh, replace_start, replace_end);
    inline for (core_completion_builtin_names) |name| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = name, .kind = .builtin, .replace_start = replace_start, .replace_end = replace_end });
    }
    inline for (extensions.rush.definitions) |definition| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = definition.name, .kind = .builtin, .replace_start = replace_start, .replace_end = replace_end });
    }
    try appendPathExecutableCandidates(allocator, builder, sh, replace_start, replace_end);
}

const core_completion_builtin_names = [_][]const u8{
    "[",
    "alias",
    "bg",
    "break",
    "cd",
    ":",
    ".",
    "command",
    "continue",
    "eval",
    "exec",
    "export",
    "exit",
    "false",
    "fg",
    "getopts",
    "hash",
    "jobs",
    "kill",
    "local",
    "printf",
    "pwd",
    "read",
    "readonly",
    "return",
    "set",
    "shift",
    "shopt",
    "source",
    "test",
    "times",
    "trap",
    "true",
    "type",
    "ulimit",
    "umask",
    "unalias",
    "unset",
    "wait",
};

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendAliasCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    var iterator = sh.state.aliases.iterator();
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    while (iterator.next()) |entry| try builder.append(allocator, .{ .value = entry.key_ptr.*, .kind = .command, .description = "alias", .replace_start = replace_start, .replace_end = replace_end });
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendVariableCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    var iterator = sh.state.variables.iterator();
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    while (iterator.next()) |entry| try builder.append(allocator, .{ .value = entry.key_ptr.*, .kind = .variable, .replace_start = replace_start, .replace_end = replace_end, .append_space = false });
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendFunctionCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    var iterator = sh.state.functions.iterator();
    while (iterator.next()) |entry| {
        if (!sh.state.isFunctionAutoloadSuppressed(entry.key_ptr.*)) {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = entry.key_ptr.*, .kind = .function, .description = "function", .replace_start = replace_start, .replace_end = replace_end });
        }
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendJobCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    for (sh.state.background_jobs.items) |job| {
        const value = try std.fmt.allocPrint(allocator, "%{d}", .{job.id});
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .kind = .plain, .description = "job", .replace_start = replace_start, .replace_end = replace_end });
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendPathExecutableCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, replace_start: usize, replace_end: usize) !void {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const path_value = if (sh.state.getVariable("PATH")) |variable| variable.value else shellValue(sh, "PATH") orelse return;
    var dirs = std.mem.splitScalar(u8, path_value, ':');
    while (dirs.next()) |raw_dir| {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        var entries = sh.host.listDir(allocator, dir) catch continue;
        defer entries.deinit();
        for (entries.entries) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.kind == .directory) continue;
            const full_path = try std.fs.path.join(allocator, &.{ dir, entry.name });
            defer allocator.free(full_path);
            const full_path_z = try allocator.dupeZ(u8, full_path);
            defer allocator.free(full_path_z);
            if (!sh.host.fileAccessZ(full_path_z, .execute)) continue;
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            try builder.append(allocator, .{ .value = entry.name, .kind = .command, .replace_start = replace_start, .replace_end = replace_end });
        }
    }
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn appendPathCandidates(allocator: std.mem.Allocator, builder: *Builder, sh: anytype, prefix: []const u8, replace_start: usize, replace_end: usize, directories_only: bool) !void {
    // ziglint-ignore: Z011 deprecated API left unchanged to avoid semantic drift in lint-only pass
    const slash = std.mem.lastIndexOfScalar(u8, prefix, '/');
    const dir_prefix = if (slash) |index| prefix[0 .. index + 1] else "";
    const entry_prefix = if (slash) |index| prefix[index + 1 ..] else prefix;
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const dir_path = if (dir_prefix.len == 0) "." else if (std.mem.eql(u8, dir_prefix, "/")) "/" else std.mem.trimEnd(u8, dir_prefix, "/");
    var entries = sh.host.listDir(allocator, dir_path) catch return;
    defer entries.deinit();
    const include_hidden = std.mem.startsWith(u8, entry_prefix, ".");
    for (entries.entries) |entry| {
        if (entry.name.len == 0 or std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!include_hidden and entry.name[0] == '.') continue;
        if (!std.mem.startsWith(u8, entry.name, entry_prefix)) continue;
        const is_directory = try pathCandidateIsDirectory(allocator, sh, dir_prefix, entry);
        if (directories_only and !is_directory) continue;
        const value = if (is_directory)
            try std.fmt.allocPrint(allocator, "{s}{s}/", .{ dir_prefix, entry.name })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, entry.name });
        defer allocator.free(value);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try builder.append(allocator, .{ .value = value, .display = entry.name, .kind = if (is_directory) .directory else .file, .replace_start = replace_start, .replace_end = replace_end, .append_space = !is_directory });
    }
}

fn pathCandidateIsDirectory(
    allocator: std.mem.Allocator,
    sh: anytype,
    dir_prefix: []const u8,
    entry: host.DirectoryEntry,
) !bool {
    if (entry.kind == .directory) return true;
    if (entry.kind != .symlink and entry.kind != .other) return false;

    const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, entry.name });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const status = sh.host.fileTestStatusZ(path_z, true) orelse return false;
    return status.kind == .directory;
}

fn shellValue(sh: anytype, name: []const u8) ?[]const u8 {
    if (sh.state.getVariable(name)) |variable| return variable.value;
    for (sh.env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

fn jsonField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const object = jsonObject(value) orelse return null;
    return object.get(name);
}

fn jsonObjectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    const field = jsonField(value, name) orelse return null;
    _ = jsonObject(field) orelse return null;
    return field;
}

fn jsonArrayField(value: std.json.Value, name: []const u8) ?std.json.Array {
    return jsonArray(jsonField(value, name) orelse return null);
}

fn jsonStringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    return jsonString(jsonField(value, name) orelse return null);
}

fn jsonBoolField(value: std.json.Value, name: []const u8) ?bool {
    return switch (jsonField(value, name) orelse return null) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonI8Field(value: std.json.Value, name: []const u8) ?i8 {
    return switch (jsonField(value, name) orelse return null) {
        .integer => |integer| std.math.cast(i8, integer),
        else => null,
    };
}

fn jsonUsizeField(value: std.json.Value, name: []const u8) ?usize {
    return switch (jsonField(value, name) orelse return null) {
        .integer => |integer| std.math.cast(usize, integer),
        else => null,
    };
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

const OutputDiscard = struct {
    saved_stdout: host.Fd,
    saved_stderr: host.Fd,
    null_fd: host.Fd,
    active: bool = true,

    fn init(real_host: *host.RealHost) !OutputDiscard {
        const null_fd = try real_host.openZ("/dev/null", .{ .access = .write_only });
        errdefer real_host.close(null_fd) catch {};
        const saved_stdout = try real_host.duplicate(.stdout);
        errdefer real_host.close(saved_stdout) catch {};
        const saved_stderr = try real_host.duplicate(.stderr);
        errdefer real_host.close(saved_stderr) catch {};
        try real_host.duplicateTo(null_fd, .stdout);
        errdefer real_host.duplicateTo(saved_stdout, .stdout) catch {};
        try real_host.duplicateTo(null_fd, .stderr);
        return .{ .saved_stdout = saved_stdout, .saved_stderr = saved_stderr, .null_fd = null_fd };
    }

    fn restore(self: *OutputDiscard, real_host: *host.RealHost) !void {
        if (!self.active) return;
        self.active = false;
        try real_host.duplicateTo(self.saved_stdout, .stdout);
        try real_host.duplicateTo(self.saved_stderr, .stderr);
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        real_host.close(self.saved_stdout) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        real_host.close(self.saved_stderr) catch {};
        // ziglint-ignore: Z026 intentional best-effort cleanup; preserve behavior
        real_host.close(self.null_fd) catch {};
    }
};

test "completion analyzes command and argument words" {
    const analyzed = try analyzeLine(std.testing.allocator, "zig bu", "zig bu".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("zig", analyzed.root.?);
    try std.testing.expectEqualStrings("bu", analyzed.prefix);
}

test "completion analyzes command positions after separators" {
    const analyzed = try analyzeLine(std.testing.allocator, "true; zi", "true; zi".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("zi", analyzed.prefix);
}

test "completion loads manifest subcommands" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const application = try complete(&sh, std.testing.allocator, std.testing.io, "zig ", "zig ".len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedSubcommandCandidates,
    };
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "build")) return;
    }
    return error.ExpectedZigBuildCandidate;
}

test "path completion follows symlinked directories before appending space" {
    const TestHost = struct {
        const Self = @This();

        pub fn listDir(_: *Self, allocator: std.mem.Allocator, path: []const u8) !host.ListDirResult {
            try std.testing.expectEqualStrings(".config", path);
            const entries = try allocator.alloc(host.DirectoryEntry, 1);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "rush"), .kind = .symlink };
            return .{ .allocator = allocator, .entries = entries };
        }

        pub fn fileTestStatusZ(_: *Self, path: [:0]const u8, follow_symlinks: bool) ?host.FileStatus {
            std.testing.expect(follow_symlinks) catch unreachable;
            std.testing.expectEqualStrings(".config/rush", path) catch unreachable;
            return .{ .kind = .directory };
        }
    };
    const TestShell = struct { host: TestHost };

    var sh: TestShell = .{ .host = .{} };
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);

    try appendPathCandidates(
        std.testing.allocator,
        &builder,
        &sh,
        ".config/ru",
        "nvim ".len,
        "nvim .config/ru".len,
        false,
    );
    var application = try applyBuiltCandidates(std.testing.allocator, "nvim .config/ru", &builder);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedSingleSymlinkDirectoryCompletion,
    };
    try std.testing.expectEqualStrings(".config/rush/", edit.replacement);
    try std.testing.expect(!edit.append_space);
}
