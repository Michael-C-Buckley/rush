//! Completion provider extension builtin.

const std = @import("std");

const api = @import("../api.zig");
const editor_completion = @import("../../editor/completion.zig");
const shell_builtin = @import("../../shell/builtin.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("rush_complete", .extension_state),
};

pub const ParsedOption = struct {
    spelling: []const u8,
    name: []const u8,
    key: []const u8,
    value: ?[]const u8 = null,
};

pub const ParsedOperand = struct {
    value: []const u8,
    index: usize,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const u8,
    replace_start: usize,
    replace_end: usize,
    argument_index: usize,
    options_terminated: bool,
    value_position: []const u8,
    parsed_options: []const ParsedOption,
    operands: []const ParsedOperand,
    candidates: std.ArrayList(editor_completion.Candidate) = .empty,
    next_source_order: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        prefix: []const u8,
        replace_start: usize,
        replace_end: usize,
        argument_index: usize,
        options_terminated: bool,
        value_position: []const u8,
        parsed_options: []const ParsedOption,
        operands: []const ParsedOperand,
    ) State {
        return .{
            .allocator = allocator,
            .io = io,
            .prefix = prefix,
            .replace_start = replace_start,
            .replace_end = replace_end,
            .argument_index = argument_index,
            .options_terminated = options_terminated,
            .value_position = value_position,
            .parsed_options = parsed_options,
            .operands = operands,
        };
    }

    pub fn deinit(self: *State) void {
        editor_completion.freeCandidates(self.allocator, self.candidates.items);
        self.* = undefined;
    }

    pub fn takeCandidates(self: *State) ![]editor_completion.Candidate {
        const candidates = try self.candidates.toOwnedSlice(self.allocator);
        self.candidates = .empty;
        return candidates;
    }
};

pub fn handlerForContext(name: []const u8, state: ?*State) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "rush_complete")) return null;
    return .{ .context = state, .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "rush_complete"));
    const state: *State = if (context) |value| @ptrCast(@alignCast(value)) else {
        return api.EvaluationResult.normal(try invocation.statusError(
            2,
            "rush_complete",
            "only available while running completion providers",
        ));
    };
    const argv = invocation.argv;
    if (argv.len < 2) return api.EvaluationResult.normal(try usage(invocation));
    if (std.mem.eql(u8, argv[1], "candidate")) return evaluateCandidate(state, invocation);
    if (std.mem.eql(u8, argv[1], "files")) return evaluatePathCandidates(state, invocation, false);
    if (std.mem.eql(u8, argv[1], "directories")) return evaluatePathCandidates(state, invocation, true);
    if (std.mem.eql(u8, argv[1], "option-present")) return evaluateOptionPresent(state, invocation);
    if (std.mem.eql(u8, argv[1], "option-values")) return evaluateOptionValues(state, invocation);
    if (std.mem.eql(u8, argv[1], "operand")) return evaluateOperand(state, invocation);
    return api.EvaluationResult.normal(try usage(invocation));
}

fn evaluateCandidate(state: *State, invocation: *api.Invocation) !api.EvaluationResult {
    const argv = invocation.argv;
    if (argv.len < 3) return api.EvaluationResult.normal(try usage(invocation));
    var candidate: editor_completion.Candidate = .{
        .value = try state.allocator.dupe(u8, argv[2]),
        .replace_start = state.replace_start,
        .replace_end = state.replace_end,
        .source_order = state.next_source_order,
    };
    errdefer freeCandidateFields(state.allocator, candidate);
    var index: usize = 3;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--kind")) {
            index += 1;
            if (index >= argv.len) return api.EvaluationResult.normal(try usage(invocation));
            candidate.kind = parseKind(argv[index]) orelse return api.EvaluationResult.normal(try usage(invocation));
        } else if (std.mem.eql(u8, arg, "--description")) {
            index += 1;
            if (index >= argv.len) return api.EvaluationResult.normal(try usage(invocation));
            candidate.description = try state.allocator.dupe(u8, argv[index]);
        } else if (std.mem.eql(u8, arg, "--display")) {
            index += 1;
            if (index >= argv.len) return api.EvaluationResult.normal(try usage(invocation));
            candidate.display = try state.allocator.dupe(u8, argv[index]);
        } else if (std.mem.eql(u8, arg, "--insert")) {
            index += 1;
            if (index >= argv.len) return api.EvaluationResult.normal(try usage(invocation));
            candidate.insert = try state.allocator.dupe(u8, argv[index]);
        } else if (std.mem.eql(u8, arg, "--tag")) {
            index += 1;
            if (index >= argv.len) return api.EvaluationResult.normal(try usage(invocation));
            candidate.tag = try state.allocator.dupe(u8, argv[index]);
        } else if (std.mem.eql(u8, arg, "--suffix")) {
            index += 1;
            if (index >= argv.len) return api.EvaluationResult.normal(try usage(invocation));
            candidate.suffix = try state.allocator.dupe(u8, argv[index]);
        } else if (std.mem.eql(u8, arg, "--priority")) {
            index += 1;
            if (index >= argv.len) return api.EvaluationResult.normal(try usage(invocation));
            candidate.priority = std.fmt.parseInt(i8, argv[index], 10) catch {
                return api.EvaluationResult.normal(try usage(invocation));
            };
        } else if (std.mem.eql(u8, arg, "--no-space")) {
            candidate.append_space = false;
        } else {
            return api.EvaluationResult.normal(try usage(invocation));
        }
        index += 1;
    }
    try state.candidates.append(state.allocator, candidate);
    state.next_source_order += 1;
    return api.EvaluationResult.normal(0);
}

fn evaluatePathCandidates(
    state: *State,
    invocation: *api.Invocation,
    directories_only: bool,
) !api.EvaluationResult {
    for (invocation.argv[2..]) |arg| {
        if (!std.mem.eql(u8, arg, "--append-slash")) return api.EvaluationResult.normal(try usage(invocation));
    }
    try appendPathCandidates(state, directories_only);
    return api.EvaluationResult.normal(0);
}

fn evaluateOptionPresent(state: *State, invocation: *api.Invocation) !api.EvaluationResult {
    const selector = parseOptionSelector(invocation.argv[2..]) orelse
        return api.EvaluationResult.normal(try usage(invocation));
    return api.EvaluationResult.normal(if (optionPresent(state.*, selector)) 0 else 1);
}

fn evaluateOptionValues(state: *State, invocation: *api.Invocation) !api.EvaluationResult {
    const selector = parseOptionSelector(invocation.argv[2..]) orelse
        return api.EvaluationResult.normal(try usage(invocation));
    for (state.parsed_options) |option| {
        if (!optionMatchesSelector(option, selector)) continue;
        const value = option.value orelse continue;
        try invocation.stdout.print(invocation.allocator, "{s}\n", .{value});
    }
    return api.EvaluationResult.normal(0);
}

fn evaluateOperand(state: *State, invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len != 3) return api.EvaluationResult.normal(try usage(invocation));
    const index = std.fmt.parseInt(usize, invocation.argv[2], 10) catch return api.EvaluationResult.normal(
        try usage(invocation),
    );
    for (state.operands) |operand| {
        if (operand.index != index) continue;
        try invocation.stdout.print(invocation.allocator, "{s}\n", .{operand.value});
        return api.EvaluationResult.normal(0);
    }
    return api.EvaluationResult.normal(1);
}

const OptionSelector = union(enum) {
    long: []const u8,
    short: []const u8,
};

fn parseOptionSelector(argv: []const []const u8) ?OptionSelector {
    if (argv.len != 2) return null;
    if (std.mem.eql(u8, argv[0], "--long")) return .{ .long = argv[1] };
    if (std.mem.eql(u8, argv[0], "--short")) return .{ .short = argv[1] };
    return null;
}

fn optionPresent(state: State, selector: OptionSelector) bool {
    for (state.parsed_options) |option| {
        if (optionMatchesSelector(option, selector)) return true;
    }
    return false;
}

fn optionMatchesSelector(option: ParsedOption, selector: OptionSelector) bool {
    return switch (selector) {
        .long => |name| std.mem.eql(u8, option.name, name) or std.mem.eql(u8, option.key, name),
        .short => |name| std.mem.eql(u8, option.name, name) or std.mem.eql(u8, option.key, name),
    };
}

fn appendPathCandidates(state: *State, directories_only: bool) !void {
    const separator_index = std.mem.lastIndexOfScalar(u8, state.prefix, '/') orelse 0;
    const split_after_separator = separator_index != 0 or std.mem.startsWith(u8, state.prefix, "/");
    const dir_prefix = if (split_after_separator) state.prefix[0 .. separator_index + 1] else "";
    const entry_prefix = if (split_after_separator) state.prefix[separator_index + 1 ..] else state.prefix;
    const dir_path = if (dir_prefix.len == 0) "." else dir_prefix;
    var dir = std.Io.Dir.cwd().openDir(state.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close(state.io);
    const include_hidden = std.mem.startsWith(u8, entry_prefix, ".");
    var iterator = dir.iterate();
    while (try iterator.next(state.io)) |entry| {
        if (entry.name.len == 0) continue;
        if (!include_hidden and entry.name[0] == '.') continue;
        if (!std.mem.startsWith(u8, entry.name, entry_prefix)) continue;
        const is_directory = entry.kind == .directory;
        if (directories_only and !is_directory) continue;
        const value = try pathCandidateValue(state.allocator, dir_prefix, entry.name, is_directory);
        errdefer state.allocator.free(value);
        const display = try pathCandidateValue(state.allocator, "", entry.name, is_directory);
        errdefer state.allocator.free(display);
        try state.candidates.append(state.allocator, .{
            .value = value,
            .display = display,
            .kind = if (is_directory) .directory else .file,
            .replace_start = state.replace_start,
            .replace_end = state.replace_end,
            .append_space = !is_directory,
        });
    }
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

fn parseKind(value: []const u8) ?editor_completion.Kind {
    if (std.mem.eql(u8, value, "plain")) return .plain;
    if (std.mem.eql(u8, value, "file")) return .file;
    if (std.mem.eql(u8, value, "directory")) return .directory;
    if (std.mem.eql(u8, value, "subcommand")) return .subcommand;
    if (std.mem.eql(u8, value, "option")) return .option;
    if (std.mem.eql(u8, value, "variable")) return .variable;
    if (std.mem.eql(u8, value, "function")) return .function;
    if (std.mem.eql(u8, value, "command")) return .command;
    if (std.mem.eql(u8, value, "builtin")) return .builtin;
    return null;
}

fn usage(invocation: *api.Invocation) !u8 {
    return invocation.usageError("rush_complete", "invalid completion provider command");
}

fn freeCandidateFields(allocator: std.mem.Allocator, candidate: editor_completion.Candidate) void {
    allocator.free(candidate.value);
    if (candidate.display) |display| allocator.free(display);
    if (candidate.insert) |insert| allocator.free(insert);
    if (candidate.description) |description| allocator.free(description);
    if (candidate.tag) |tag| allocator.free(tag);
    if (candidate.suffix) |suffix| allocator.free(suffix);
}
