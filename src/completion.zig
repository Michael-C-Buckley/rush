//! Rush interactive completion service.

const std = @import("std");
const build_config = @import("build_config");

const completion_path = @import("completion_path.zig");
const editor_completion = @import("editor/completion.zig");
const extensions = @import("extensions.zig");
const history = @import("history.zig");
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const src: shell.source.Source = .{ .id = 0, .kind = .interactive, .name = "completion", .text = source };
    const tokens = try shell.lexer.lex(arena.allocator(), src);

    var words: std.ArrayList(Word) = .empty;
    errdefer words.deinit(allocator);

    var tracker: shell.token.CommandPositionTracker = .{};
    var current_word_index: ?usize = null;
    var current_word_class: ?shell.token.CommandPositionTracker.Class = null;
    var command_word_index: ?usize = null;
    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        if (tok.span.start >= cursor) break;
        const class = tracker.classify(tok);
        if (tok.kind != .word) {
            // A token that reopens command position starts a new command
            // segment, so any previous command word no longer applies.
            if (tracker.command_position) command_word_index = null;
            continue;
        }
        const index = words.items.len;
        try words.append(allocator, .{
            .text = source[tok.span.start..tok.span.end],
            .start = tok.span.start,
            .end = tok.span.end,
        });
        if (class == .command) command_word_index = index;
        if (class == .reserved and tracker.command_position) command_word_index = null;
        if (cursor <= tok.span.end) {
            current_word_index = index;
            current_word_class = class;
        }
    }

    // Completing inside an unterminated command substitution is really
    // completing the inner command line, so analyze that line instead.
    if (current_word_index) |index| {
        const word = words.items[index];
        if (try substitutionInteriorStart(arena.allocator(), source[word.start..cursor])) |relative| {
            const inner_start = word.start + relative;
            words.deinit(allocator);
            words = .empty;
            var inner = try analyzeLine(allocator, source[inner_start..], cursor - inner_start);
            for (inner.words) |*inner_word| {
                inner_word.start += inner_start;
                inner_word.end += inner_start;
            }
            inner.replace_start += inner_start;
            inner.replace_end += inner_start;
            return inner;
        }
    }

    const replace_start = if (current_word_index) |index| words.items[index].start else cursor;
    const replace_end = if (current_word_index) |index| words.items[index].end else cursor;
    const raw_prefix = source[replace_start..cursor];
    const parameter = raw_prefix.len != 0 and raw_prefix[0] == '$';
    const prefix = if (parameter) raw_prefix[1..] else raw_prefix;

    const is_command = if (current_word_class) |class|
        class == .command or class == .reserved
    else
        tracker.command_position and !tracker.skip_redirection_target;
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

/// Returns the offset just past the opener of the innermost `$(` or backquote
/// substitution left unclosed in `text`, or null when every substitution is
/// closed. Single quotes suppress openers; double quotes do not.
fn substitutionInteriorStart(allocator: std.mem.Allocator, text: []const u8) !?usize {
    var open_interiors: std.ArrayList(usize) = .empty;
    defer open_interiors.deinit(allocator);
    var backquote: ?usize = null;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quote) |delimiter| {
            if (byte == delimiter) {
                quote = null;
                continue;
            }
            // Single quotes suppress substitutions; double quotes do not.
            if (delimiter == '\'') continue;
        }
        switch (byte) {
            '\\' => index += 1,
            '\'', '"' => if (quote == null) {
                quote = byte;
            },
            '`' => backquote = if (backquote == null) index + 1 else null,
            '$' => if (index + 1 < text.len and text[index + 1] == '(') {
                try open_interiors.append(allocator, index + 2);
                index += 1;
            },
            ')' => _ = open_interiors.pop(),
            else => {},
        }
    }
    const deepest = open_interiors.getLastOrNull();
    if (deepest != null and backquote != null) return @max(deepest.?, backquote.?);
    return deepest orelse backquote;
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
    const semantic = semanticContext(analyzed, command_word_index, command);

    if (semantic.complete_options) {
        try appendOptionCandidates(allocator, builder, current, analyzed.replace_start, analyzed.replace_end);
        try appendOptionProviderCandidates(
            allocator,
            io,
            sh,
            builder,
            analyzed,
            semantic,
            command,
            current,
            providers,
            companion_path,
        );
        return true;
    }

    if (semantic.option_value_provider) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendProviderCandidates(
            allocator,
            io,
            sh,
            builder,
            analyzed,
            semantic,
            command,
            current,
            providers,
            provider,
            companion_path,
        );
        return true;
    }

    if (semantic.complete_subcommands) {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendSubcommandCandidates(allocator, builder, current, providers, analyzed.replace_start, analyzed.replace_end);
        return true;
    }

    if (argumentProvider(current, semantic.operand_index)) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try appendProviderCandidates(
            allocator,
            io,
            sh,
            builder,
            analyzed,
            semantic,
            command,
            current,
            providers,
            provider,
            companion_path,
        );
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

fn semanticContext(analyzed: AnalyzedLine, command_word_index: usize, root_command: std.json.Value) Semantic {
    var operand_index: usize = 0;
    var options_terminated = false;
    var pending_option_value: ?std.json.Value = null;
    var pending_option_word_index: ?usize = null;
    var command = root_command;
    var command_path: [16]std.json.Value = undefined;
    command_path[0] = command;
    var command_path_len: usize = 1;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    for (analyzed.words[command_word_index + 1 ..], command_word_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
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
            if (optionTokenForContext(command_path[0..command_path_len], word.text)) |parsed| {
                if (jsonObjectField(parsed.option, "value")) |value| {
                    if (parsed.value != null) continue;
                    pending_option_value = value;
                    pending_option_word_index = absolute_index;
                }
            }
            continue;
        }
        if (!options_terminated) {
            if (subcommandForName(command, null, word.text)) |subcommand| {
                command = subcommand;
                if (command_path_len == command_path.len) return .{
                    .operand_index = operand_index,
                    .options_terminated = options_terminated,
                };
                command_path[command_path_len] = command;
                command_path_len += 1;
                operand_index = 0;
                continue;
            }
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
    var command_path: [16]std.json.Value = undefined;
    command_path[0] = command;
    var command_path_len: usize = 1;
    var pending_option_value = false;
    var options_terminated = false;
    const limit = if (current_word_index) |index| @min(index, words.len) else words.len;
    for (words, 0..) |word, relative_index| {
        if (relative_index >= limit) break;
        if (pending_option_value) {
            pending_option_value = false;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            if (optionTokenForContext(command_path[0..command_path_len], word.text)) |parsed| {
                pending_option_value = parsed.value == null and jsonObjectField(parsed.option, "value") != null;
            }
            continue;
        }
        if (options_terminated) break;
        if (subcommandForName(command, providers, word.text)) |subcommand| {
            command = subcommand;
            if (command_path_len == command_path.len) return command;
            command_path[command_path_len] = command;
            command_path_len += 1;
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

fn appendOptionProviderCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: anytype,
    builder: *Builder,
    analyzed: AnalyzedLine,
    semantic: Semantic,
    root_command: std.json.Value,
    command: std.json.Value,
    providers: ?std.json.Value,
    companion_path: ?[]const u8,
) !void {
    const options = jsonArrayField(command, "options") orelse return;
    for (options.items) |option| {
        const provider = jsonField(option, "provider") orelse continue;
        try appendProviderCandidates(
            allocator,
            io,
            sh,
            builder,
            analyzed,
            semantic,
            root_command,
            command,
            providers,
            provider,
            companion_path,
        );
    }
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
    root_command: std.json.Value,
    command: std.json.Value,
    providers: ?std.json.Value,
    provider_ref: std.json.Value,
    companion_path: ?[]const u8,
) !void {
    if (jsonArray(provider_ref)) |provider_refs| {
        for (provider_refs.items) |item| {
            try appendProviderCandidates(
                allocator,
                io,
                sh,
                builder,
                analyzed,
                semantic,
                root_command,
                command,
                providers,
                item,
                companion_path,
            );
        }
        return;
    }
    if (providerValue(providers, provider_ref)) |provider| {
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (jsonStringField(provider, "builtin")) |name| return appendBuiltinProvider(allocator, builder, sh, analyzed, name);
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        if (jsonArrayField(provider, "values")) |values| return appendStaticValues(allocator, builder, analyzed, values);
        if (jsonStringField(provider, "function")) |function_name| {
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            return appendFunctionProvider(
                allocator,
                io,
                sh,
                builder,
                analyzed,
                semantic,
                root_command,
                function_name,
                companion_path,
            );
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
    root_command: std.json.Value,
    function_name: []const u8,
    companion_path: ?[]const u8,
) !void {
    if (companion_path) |path| try sourceCompanionIfNeeded(allocator, io, sh, path);

    const parsed_options = try parsedOptionsForProvider(allocator, analyzed, root_command);
    defer allocator.free(parsed_options);
    const operands = try operandsForProvider(allocator, analyzed, root_command);
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
    try sh.state.putVariable(.{ .name = "rush_completion_prefix", .value = analyzed.prefix });
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
    root_command: std.json.Value,
) ![]extensions.rush.CompletionParsedOption {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const command_index = analyzed.command_word_index orelse return allocator.alloc(extensions.rush.CompletionParsedOption, 0);
    var options: std.ArrayList(extensions.rush.CompletionParsedOption) = .empty;
    errdefer options.deinit(allocator);
    var pending_index: ?usize = null;
    var options_terminated = false;
    var command = root_command;
    var command_path: [16]std.json.Value = undefined;
    command_path[0] = command;
    var command_path_len: usize = 1;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    for (analyzed.words[command_index + 1 ..], command_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
        if (pending_index) |index| {
            options.items[index].value = word.text;
            pending_index = null;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            const parsed = optionTokenForContext(command_path[0..command_path_len], word.text) orelse continue;
            const name = optionName(parsed.option, word.text);
            try options.append(allocator, .{
                .spelling = word.text,
                .name = name,
                .key = name,
                .value = parsed.value,
            });
            if (parsed.value == null and jsonObjectField(parsed.option, "value") != null) {
                pending_index = options.items.len - 1;
            }
            continue;
        }
        if (!options_terminated) {
            if (subcommandForName(command, null, word.text)) |subcommand| {
                command = subcommand;
                if (command_path_len == command_path.len) break;
                command_path[command_path_len] = command;
                command_path_len += 1;
            }
        }
    }
    return options.toOwnedSlice(allocator);
}

fn operandsForProvider(
    allocator: std.mem.Allocator,
    analyzed: AnalyzedLine,
    root_command: std.json.Value,
) ![]extensions.rush.CompletionParsedOperand {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const command_index = analyzed.command_word_index orelse return allocator.alloc(extensions.rush.CompletionParsedOperand, 0);
    var operands: std.ArrayList(extensions.rush.CompletionParsedOperand) = .empty;
    errdefer operands.deinit(allocator);
    var operand_index: usize = 0;
    var pending_option_value = false;
    var options_terminated = false;
    var command = root_command;
    var command_path: [16]std.json.Value = undefined;
    command_path[0] = command;
    var command_path_len: usize = 1;
    const current_word_index = analyzed.current_word_index orelse analyzed.words.len;
    for (analyzed.words[command_index + 1 ..], command_index + 1..) |word, absolute_index| {
        if (absolute_index >= current_word_index) break;
        if (pending_option_value) {
            pending_option_value = false;
            continue;
        }
        if (std.mem.eql(u8, word.text, "--")) {
            options_terminated = true;
            continue;
        }
        if (!options_terminated and std.mem.startsWith(u8, word.text, "-")) {
            if (optionTokenForContext(command_path[0..command_path_len], word.text)) |parsed| {
                pending_option_value = parsed.value == null and jsonObjectField(parsed.option, "value") != null;
            }
            continue;
        }
        if (!options_terminated) {
            if (subcommandForName(command, null, word.text)) |subcommand| {
                command = subcommand;
                if (command_path_len == command_path.len) break;
                command_path[command_path_len] = command;
                command_path_len += 1;
                operands.clearRetainingCapacity();
                operand_index = 0;
                continue;
            }
        }
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

const ParsedOptionToken = struct {
    option: std.json.Value,
    value: ?[]const u8 = null,
};

fn optionTokenForContext(command_path: []const std.json.Value, token: []const u8) ?ParsedOptionToken {
    var index = command_path.len;
    while (index > 0) {
        index -= 1;
        const options = jsonArrayField(command_path[index], "options") orelse continue;
        for (options.items) |option| {
            if (index + 1 != command_path.len and !(jsonBoolField(option, "inherit") orelse true)) continue;
            if (optionToken(option, token)) |parsed| return parsed;
        }
    }
    return null;
}

fn optionToken(option: std.json.Value, token: []const u8) ?ParsedOptionToken {
    if (optionMatchesSpelling(option, token)) return .{ .option = option };
    if (jsonObjectField(option, "value") == null) return null;

    if (jsonStringField(option, "long")) |long| {
        if (token.len >= long.len + 3 and
            std.mem.eql(u8, token[0..2], "--") and
            std.mem.eql(u8, token[2 .. long.len + 2], long) and
            token[long.len + 2] == '=')
        {
            return .{ .option = option, .value = token[long.len + 3 ..] };
        }
    }
    if (jsonStringField(option, "short")) |short| {
        if (short.len == 1 and token.len > 2 and token[0] == '-' and token[1] == short[0]) {
            const value = if (token[2] == '=') token[3..] else token[2..];
            return .{ .option = option, .value = value };
        }
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
    const unexpanded_dir_path = if (dir_prefix.len == 0) "." else if (std.mem.eql(u8, dir_prefix, "/")) "/" else std.mem.trimEnd(u8, dir_prefix, "/");
    const dir_path = try completion_path.expandLeadingTilde(
        allocator,
        unexpanded_dir_path,
        shellValue(sh, "HOME"),
    );
    defer allocator.free(dir_path);
    var entries = sh.host.listDir(allocator, dir_path) catch return;
    defer entries.deinit();
    const include_hidden = std.mem.startsWith(u8, entry_prefix, ".");
    for (entries.entries) |entry| {
        if (entry.name.len == 0 or std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!include_hidden and entry.name[0] == '.') continue;
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

    const unexpanded_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_prefix, entry.name });
    defer allocator.free(unexpanded_path);
    const path = try completion_path.expandLeadingTilde(
        allocator,
        unexpanded_path,
        shellValue(sh, "HOME"),
    );
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

test "completion keeps command position after assignment prefixes" {
    const analyzed = try analyzeLine(std.testing.allocator, "FOO=bar ", "FOO=bar ".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("", analyzed.prefix);
}

test "completion treats redirection targets as arguments" {
    const analyzed = try analyzeLine(std.testing.allocator, "true; > ", "true; > ".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqual(@as(?[]const u8, null), analyzed.root);
}

test "completion keeps escaped spaces inside a single word" {
    const line = "cat foo\\ bar";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("foo\\ bar", analyzed.prefix);
    try std.testing.expectEqualStrings("cat", analyzed.root.?);
}

test "completion analyzes the inner line of an open command substitution" {
    const line = "echo $(git ch";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("git", analyzed.root.?);
    try std.testing.expectEqualStrings("ch", analyzed.prefix);
    try std.testing.expectEqual(@as(usize, "echo $(git ".len), analyzed.replace_start);
    try std.testing.expectEqual(@as(usize, line.len), analyzed.replace_end);
}

test "completion analyzes substitutions opened inside double quotes" {
    const line = "echo \"$(git ch";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("git", analyzed.root.?);
    try std.testing.expectEqualStrings("ch", analyzed.prefix);
    try std.testing.expectEqual(@as(usize, "echo \"$(git ".len), analyzed.replace_start);
}

test "completion ignores substitution openers inside single quotes" {
    const line = "echo '$(li";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("echo", analyzed.root.?);
    try std.testing.expectEqualStrings("'$(li", analyzed.prefix);
}

test "completion completes commands right after a substitution opener" {
    const line = "echo $(";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("", analyzed.prefix);
}

test "completion ignores closed command substitutions" {
    const line = "echo $(id) ar";
    const analyzed = try analyzeLine(std.testing.allocator, line, line.len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.argument, analyzed.kind);
    try std.testing.expectEqualStrings("echo", analyzed.root.?);
    try std.testing.expectEqualStrings("ar", analyzed.prefix);
}

test "completion recognizes reserved words as command prefixes" {
    const analyzed = try analyzeLine(std.testing.allocator, "if tr", "if tr".len);
    defer analyzed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CompletionKind.command, analyzed.kind);
    try std.testing.expectEqualStrings("tr", analyzed.prefix);
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

test "completion includes dynamic option provider candidates" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "zig build -Doptimize=";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedDynamicOptionCandidates,
    };
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "-Doptimize=ReleaseSafe")) return;
    }
    return error.ExpectedOptimizeReleaseSafeCandidate;
}

test "provider context preserves root options before a subcommand" {
    const manifest =
        \\{
        \\  "name": "tool",
        \\  "options": [
        \\    { "long": "user", "inherit": false },
        \\    { "long": "host", "inherit": false, "value": { "name": "host" } }
        \\  ],
        \\  "subcommands": [
        \\    { "name": "stop", "arguments": { "states": [
        \\      { "name": "unit", "index": 0, "repeatable": true }
        \\    ] } }
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest, .{});
    defer parsed.deinit();

    const source = "tool --user --host example stop alpha ";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);

    const semantic = semanticContext(analyzed, analyzed.command_word_index.?, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), semantic.operand_index);

    const options = try parsedOptionsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(options);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqualStrings("user", options[0].name);
    try std.testing.expectEqualStrings("host", options[1].name);
    try std.testing.expectEqualStrings("example", options[1].value.?);

    const operands = try operandsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(operands);
    try std.testing.expectEqual(@as(usize, 1), operands.len);
    try std.testing.expectEqualStrings("alpha", operands[0].value);
    try std.testing.expectEqual(@as(usize, 0), operands[0].index);
}

test "manifest selection accepts attached root option values before a subcommand" {
    const manifest =
        \\{
        \\  "name": "tool",
        \\  "options": [
        \\    { "long": "host", "value": { "name": "host" } }
        \\  ],
        \\  "subcommands": [ { "name": "stop" } ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, manifest, .{});
    defer parsed.deinit();

    const source = "tool --host=example stop ";
    const analyzed = try analyzeLine(std.testing.allocator, source, source.len);
    defer analyzed.deinit(std.testing.allocator);
    const words = analyzed.words[analyzed.command_word_index.? + 1 ..];
    const current = selectedCommand(parsed.value, words, null, null).?;
    try std.testing.expectEqualStrings("stop", commandName(current).?);

    const options = try parsedOptionsForProvider(std.testing.allocator, analyzed, parsed.value);
    defer std.testing.allocator.free(options);
    try std.testing.expectEqual(@as(usize, 1), options.len);
    try std.testing.expectEqualStrings("example", options[0].value.?);
}

test "z completion uses Rush frecent directory history" {
    var command_history = try history.History.init(std.testing.allocator);
    defer command_history.deinit();
    command_history.current_cwd = "/work/mywebsite";
    try command_history.addCommand(std.testing.io, "first", 0, 10, 1);
    try command_history.addCommand(std.testing.io, "second", 0, 20, 1);
    command_history.current_cwd = "/work/web-docs";
    try command_history.addCommand(std.testing.io, "third", 0, 30, 1);
    command_history.current_cwd = "work-web";
    try command_history.addCommand(std.testing.io, "corrupt", 0, 40, 1);

    var history_service = history.InteractiveHistoryService.init(&command_history);
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();
    sh.setCommandHistory(history_service.commandHistory(std.testing.io));
    try sh.state.putVariable(.{ .name = "PWD", .value = "/work/current" });
    try sh.state.putVariable(.{ .name = "HOME", .value = "/work" });

    const source = "z work web";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedDirectoryHistoryCandidates,
    };

    try std.testing.expect(candidates.len >= 2);
    try std.testing.expectEqualStrings("website", candidates[0].value);
    try std.testing.expectEqualStrings("mywebsite", candidates[0].display.?);
    try std.testing.expectEqualStrings("~/mywebsite", candidates[0].description.?);
    try std.testing.expect(candidates[0].append_space);
    for (candidates) |candidate| {
        if (candidate.display) |display| try std.testing.expect(!std.mem.eql(u8, display, "work-web"));
    }
}

test "completion uses provider arrays from nvim manifest" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "nvim ";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);
    const candidates = switch (application) {
        .ambiguous => |candidates| candidates,
        else => return error.ExpectedNvimPathCandidates,
    };

    var saw_file = false;
    var saw_directory = false;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, "AGENTS.md") and candidate.kind == .file) saw_file = true;
        if (std.mem.eql(u8, candidate.value, "src/") and candidate.kind == .directory) saw_directory = true;
    }
    try std.testing.expect(saw_file);
    try std.testing.expect(saw_directory);
}

test "path completion matches file names case insensitively" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "nvim agents";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedCaseInsensitivePathCompletion,
    };
    try std.testing.expectEqualStrings("AGENTS.md", edit.replacement);
}

test "cd directory completion appends slash without trailing space" {
    var sh = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry).init(std.testing.allocator, .{}, .{});
    defer sh.deinit();

    const source = "cd sr";
    var application = try complete(&sh, std.testing.allocator, std.testing.io, source, source.len);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedCdDirectoryCompletion,
    };
    try std.testing.expectEqualStrings("src/", edit.replacement);
    try std.testing.expect(!edit.append_space);
}

test "path completion follows symlinked directories before appending space" {
    const TestState = struct {
        const Self = @This();

        fn getVariable(_: Self, _: []const u8) ?shell.state.Variable {
            return null;
        }
    };
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
    const TestShell = struct {
        host: TestHost,
        state: TestState,
        env: []const [*:0]const u8 = &.{},
    };

    var sh: TestShell = .{ .host = .{}, .state = .{} };
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

test "path completion expands tilde for lookup and preserves it in candidates" {
    const TestState = struct {
        const Self = @This();

        fn getVariable(_: Self, name: []const u8) ?shell.state.Variable {
            if (!std.mem.eql(u8, name, "HOME")) return null;
            return .{ .name = "HOME", .value = "/home/alice" };
        }
    };
    const TestHost = struct {
        const Self = @This();

        pub fn listDir(_: *Self, allocator: std.mem.Allocator, path: []const u8) !host.ListDirResult {
            try std.testing.expectEqualStrings("/home/alice/.config", path);
            const entries = try allocator.alloc(host.DirectoryEntry, 1);
            errdefer allocator.free(entries);
            entries[0] = .{ .name = try allocator.dupe(u8, "rush"), .kind = .directory };
            return .{ .allocator = allocator, .entries = entries };
        }

        pub fn fileTestStatusZ(_: *Self, _: [:0]const u8, _: bool) ?host.FileStatus {
            unreachable;
        }
    };
    const TestShell = struct {
        host: TestHost,
        state: TestState,
        env: []const [*:0]const u8 = &.{},
    };

    const source = "nvim ~/.config/ru";
    var sh: TestShell = .{ .host = .{}, .state = .{} };
    var builder: Builder = .{};
    defer builder.deinit(std.testing.allocator);

    try appendPathCandidates(
        std.testing.allocator,
        &builder,
        &sh,
        "~/.config/ru",
        "nvim ".len,
        source.len,
        false,
    );
    var application = try applyBuiltCandidates(std.testing.allocator, source, &builder);
    defer application.deinit(std.testing.allocator);

    const edit = switch (application) {
        .edit => |edit| edit,
        else => return error.ExpectedTildePathCompletion,
    };
    try std.testing.expectEqualStrings("~/.config/rush/", edit.replacement);
    try std.testing.expect(!edit.append_space);
}
