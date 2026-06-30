//! Direct evaluator for the rewritten shell core.

const std = @import("std");

const ast = @import("ast.zig");
const builtin = @import("builtin.zig");
const host_mod = @import("../host.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const result = @import("result.zig");
const source_mod = @import("source.zig");

pub const EvalError = anyerror;

pub fn evalProgram(comptime Host: type, shell: anytype, program: ast.Program) EvalError!result.EvalResult {
    _ = Host;
    program.validate();
    return evalList(shell, program.body);
}

fn evalList(shell: anytype, list: ast.List) EvalError!result.EvalResult {
    var status: result.ExitStatus = 0;
    for (list.entries) |entry| {
        const evaluated = try evalAndOr(shell, entry.and_or);
        status = evaluated.status;
        shell.state.last_status = status;
        if (evaluated.flow != .normal) return evaluated;
    }
    return .{ .status = status };
}

fn evalAndOr(shell: anytype, and_or: ast.AndOr) EvalError!result.EvalResult {
    and_or.validate();
    var last: result.EvalResult = .{};
    for (and_or.pipelines, 0..) |pipeline, index| {
        if (index != 0) switch (pipeline.operator.?) {
            .and_if => if (last.status != 0) continue,
            .or_if => if (last.status == 0) continue,
        };
        last = try evalPipeline(shell, pipeline.pipeline);
        if (last.flow != .normal) return last;
    }
    return last;
}

fn evalPipeline(shell: anytype, pipeline: ast.Pipeline) EvalError!result.EvalResult {
    pipeline.validate();
    std.debug.assert(pipeline.stages.len == 1);
    var evaluated = try evalCommand(shell, pipeline.stages[0]);
    if (pipeline.negated and evaluated.flow == .normal) evaluated.status = if (evaluated.status == 0) 1 else 0;
    return evaluated;
}

fn evalCommand(shell: anytype, command: ast.Command) EvalError!result.EvalResult {
    return switch (command) {
        .simple => |simple| evalSimple(shell, simple),
        .compound, .function_definition => .{ .status = 2 },
    };
}

fn evalSimple(shell: anytype, command: ast.SimpleCommand) EvalError!result.EvalResult {
    command.validate();
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    var redirections = applyRedirections(shell, command.redirections) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .status = 1 },
    };
    defer redirections.restore(shell) catch {};

    if (command.words.len == 0) {
        const status = try applyAssignmentsWithStatus(shell, command.assignments);
        return .{ .status = status };
    }

    var expansion_status: ?result.ExitStatus = null;
    const name = try expandWordTracking(shell, command.words[0], &expansion_status);
    if (name.len == 0) {
        const status = try applyAssignmentsWithStatus(shell, command.assignments);
        return .{ .status = expansion_status orelse status };
    }
    if (builtin.lookup(name)) |definition| {
        if (definition.kind == .special) try applyAssignments(shell, command.assignments);
        const args = switch (definition.id) {
            .exit, .printf => try expandWords(shell, command.words),
            else => &[_][]const u8{name},
        };
        return builtin.eval(shell, definition, args);
    }
    return evalExternal(shell, command.words);
}

const AppliedRedirections = struct {
    frames: []const RedirectionFrame,

    fn restore(self: AppliedRedirections, shell: anytype) !void {
        var index = self.frames.len;
        while (index != 0) {
            index -= 1;
            const frame = self.frames[index];
            if (frame.saved) |saved| {
                try shell.host.duplicateTo(saved, frame.target);
                try shell.host.close(saved);
            } else {
                shell.host.close(frame.target) catch |err| switch (err) {
                    error.Unexpected => {},
                    else => return err,
                };
            }
        }
    }
};

const RedirectionFrame = struct {
    target: host_mod.Fd,
    saved: ?host_mod.Fd,
};

fn applyRedirections(shell: anytype, redirections: []const ast.Redirection) !AppliedRedirections {
    var frames: std.ArrayList(RedirectionFrame) = .empty;
    errdefer restoreFrames(shell, frames.items) catch {};

    for (redirections) |redirection| {
        try applyRedirection(shell, redirection, &frames);
    }

    return .{ .frames = try frames.toOwnedSlice(shell.scratchAllocator()) };
}

fn applyRedirection(shell: anytype, redirection: ast.Redirection, frames: *std.ArrayList(RedirectionFrame)) !void {
    redirection.validate();
    const target = redirectionFd(redirection);
    const saved = saveFd(shell, target) catch |err| switch (err) {
        error.BadFd => null,
        else => return err,
    };
    try frames.append(shell.scratchAllocator(), .{ .target = target, .saved = saved });

    switch (redirection.op) {
        .input, .output, .append, .read_write, .clobber => {
            const path = try shell.scratchAllocator().dupeZ(u8, try expandWord(shell, redirection.target));
            const opened = try shell.host.openZ(path, openOptions(redirection.op));
            if (opened != target) {
                defer shell.host.close(opened) catch {};
                try shell.host.duplicateTo(opened, target);
            }
        },
        .duplicate_input, .duplicate_output => {
            const source_text = try expandWord(shell, redirection.target);
            if (std.mem.eql(u8, source_text, "-")) {
                shell.host.close(target) catch |err| switch (err) {
                    error.Unexpected => {},
                    else => return err,
                };
                return;
            }
            const source = try parseFd(source_text);
            if (source != target) try shell.host.duplicateTo(source, target);
        },
        .here_doc, .here_doc_strip_tabs => return error.UnsupportedRedirection,
    }
}

fn restoreFrames(shell: anytype, frames: []const RedirectionFrame) !void {
    try (AppliedRedirections{ .frames = frames }).restore(shell);
}

fn saveFd(shell: anytype, fd: host_mod.Fd) !host_mod.Fd {
    return shell.host.duplicate(fd);
}

fn redirectionFd(redirection: ast.Redirection) host_mod.Fd {
    return if (redirection.fd) |fd| parseKnownFd(fd) else switch (redirection.op) {
        .input, .duplicate_input, .read_write, .here_doc, .here_doc_strip_tabs => .stdin,
        .output, .append, .duplicate_output, .clobber => .stdout,
    };
}

fn openOptions(operator: ast.RedirectionOperator) host_mod.OpenOptions {
    return switch (operator) {
        .input => .{ .access = .read_only },
        .output, .clobber => .{ .access = .write_only, .create = true, .truncate = true },
        .append => .{ .access = .write_only, .create = true, .append = true },
        .read_write => .{ .access = .read_write, .create = true },
        else => unreachable,
    };
}

fn parseFd(text: []const u8) !host_mod.Fd {
    const raw = std.fmt.parseInt(u31, text, 10) catch return error.UnsupportedRedirection;
    return parseKnownFd(raw);
}

fn parseKnownFd(raw: u31) host_mod.Fd {
    return @enumFromInt(@as(i32, @intCast(raw)));
}

fn applyAssignments(shell: anytype, assignments: []const ast.Assignment) !void {
    _ = try applyAssignmentsWithStatus(shell, assignments);
}

fn applyAssignmentsWithStatus(shell: anytype, assignments: []const ast.Assignment) !result.ExitStatus {
    var status: ?result.ExitStatus = null;
    for (assignments) |assignment| {
        const value = try expandWordTracking(shell, assignment.value, &status);
        try shell.state.putVariable(.{ .name = assignment.name, .value = value });
    }
    return status orelse 0;
}

fn expandWords(shell: anytype, words: []const ast.Word) ![]const []const u8 {
    std.debug.assert(words.len != 0);
    const allocator = shell.scratchAllocator();
    const expanded = try allocator.alloc([]const u8, words.len);
    for (words, 0..) |word, index| expanded[index] = try expandWord(shell, word);
    return expanded;
}

fn expandWord(shell: anytype, word: ast.Word) ![]const u8 {
    return expandWordTracking(shell, word, null);
}

fn expandWordTracking(shell: anytype, word: ast.Word, substitution_status: ?*?result.ExitStatus) ![]const u8 {
    return switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| expandWordParts(shell, parts, substitution_status),
    };
}

fn expandWordParts(shell: anytype, parts: []const ast.WordPart, substitution_status: ?*?result.ExitStatus) EvalError![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return expandWordPart(shell, parts[0], substitution_status);

    const allocator = shell.scratchAllocator();
    var output: std.ArrayList(u8) = .empty;
    for (parts) |part| try output.appendSlice(allocator, try expandWordPart(shell, part, substitution_status));
    return output.toOwnedSlice(allocator);
}

fn expandWordPart(shell: anytype, part: ast.WordPart, substitution_status: ?*?result.ExitStatus) EvalError![]const u8 {
    return switch (part) {
        .literal, .single_quoted, .arithmetic => |bytes| bytes,
        .double_quoted => |parts| expandWordParts(shell, parts, substitution_status),
        .parameter => |parameter| expandParameter(shell, parameter),
        .command_substitution => |substitution| expandCommandSubstitution(shell, substitution, substitution_status),
    };
}

fn expandCommandSubstitution(
    shell: anytype,
    substitution: ast.CommandSubstitution,
    substitution_status: ?*?result.ExitStatus,
) EvalError![]const u8 {
    substitution.validate();
    const program = if (substitution.parsed) |program| program.* else program: {
        const src: source_mod.Source = .{
            .id = 0,
            .kind = .command_string,
            .name = "$()",
            .text = substitution.source_text,
        };
        const ast_allocator = shell.astAllocator();
        const tokens = try lexer.lex(ast_allocator, src);
        break :program try parser.parse(ast_allocator, src, tokens);
    };
    const evaluated = try evalProgram(@TypeOf(shell.host), shell, program);
    const status = evaluated.status;
    if (substitution_status) |tracked| tracked.* = status;
    shell.state.last_status = status;
    return "";
}

fn expandParameter(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    parameter.validate();
    return switch (parameter.parameter) {
        .variable => |name| if (shell.state.getVariable(name)) |variable| variable.value else "",
        .special => |special| switch (special) {
            .question => try formatExitStatus(shell, shell.state.last_status),
            else => "",
        },
        .positional => "",
    };
}

fn formatExitStatus(shell: anytype, status: result.ExitStatus) ![]const u8 {
    var buffer: [3]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{}", .{status});
    return shell.scratchAllocator().dupe(u8, text);
}

fn evalExternal(shell: anytype, words: []const ast.Word) EvalError!result.EvalResult {
    const argv = try expandExecArgv(shell, words);
    const command_text = std.mem.span(argv[0].?);
    const command = argv[0].?[0..command_text.len :0];
    const path = try resolveCommandPath(shell, command);
    const envp = try makeExecEnvp(shell);
    const status = try shell.host.spawnAndWait(.{
        .path = path,
        .argv = argv,
        .envp = envp,
    });
    return .{ .status = status.shellStatus() };
}

fn expandExecArgv(shell: anytype, words: []const ast.Word) ![:null]const ?[*:0]const u8 {
    std.debug.assert(words.len != 0);
    const allocator = shell.scratchAllocator();
    const expanded = try allocator.allocSentinel(?[*:0]const u8, words.len, null);
    for (words, 0..) |word, index| {
        const bytes = try expandWord(shell, word);
        expanded[index] = (try allocator.dupeZ(u8, bytes)).ptr;
    }
    return expanded;
}

fn makeExecEnvp(shell: anytype) ![:null]const ?[*:0]const u8 {
    const envp = try shell.scratchAllocator().allocSentinel(?[*:0]const u8, shell.env.len, null);
    for (shell.env, 0..) |entry, index| envp[index] = entry;
    return envp;
}

fn resolveCommandPath(shell: anytype, command: [:0]const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return command;

    const path = if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse "/usr/bin:/bin";
    const allocator = shell.scratchAllocator();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        candidate_buffer.clearRetainingCapacity();
        const prefix = if (directory.len == 0) "." else directory;
        try candidate_buffer.appendSlice(allocator, prefix);
        if (!std.mem.endsWith(u8, prefix, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, command);
        try candidate_buffer.append(allocator, 0);
        const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
        if (shell.host.isExecutableZ(candidate)) return candidate;
    }

    return allocator.dupeZ(u8, command);
}

fn envPath(env: []const [*:0]const u8) ?[]const u8 {
    for (env) |entry| {
        const text = std.mem.span(entry);
        if (std.mem.startsWith(u8, text, "PATH=")) return text["PATH=".len..];
    }
    return null;
}
