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
    var evaluated = if (pipeline.stages.len == 1)
        try evalCommand(shell, pipeline.stages[0])
    else
        try evalExternalPipeline(shell, pipeline.stages);
    if (pipeline.negated and evaluated.flow == .normal) evaluated.status = if (evaluated.status == 0) 1 else 0;
    return evaluated;
}

fn evalExternalPipeline(shell: anytype, stages: []const ast.Command) EvalError!result.EvalResult {
    std.debug.assert(stages.len > 1);
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    const allocator = shell.scratchAllocator();
    const pipes = try allocator.alloc(host_mod.Pipe, stages.len - 1);
    var open_pipes: usize = 0;
    errdefer closePipes(shell, pipes[0..open_pipes]);
    for (pipes) |*pipe_desc| {
        pipe_desc.* = try shell.host.pipe();
        open_pipes += 1;
    }

    const pids = try allocator.alloc(host_mod.Pid, stages.len);
    var spawned: usize = 0;
    errdefer {
        closePipes(shell, pipes[0..open_pipes]);
        _ = waitPids(shell, pids[0..spawned]) catch {};
    }

    for (stages, 0..) |stage, index| {
        pids[index] = try forkPipelineStage(shell, stage, pipes, index);
        spawned += 1;
    }

    closePipes(shell, pipes);
    open_pipes = 0;
    const statuses = try waitPids(shell, pids);
    return .{ .status = statuses[statuses.len - 1].shellStatus() };
}

fn closePipes(shell: anytype, pipes: []const host_mod.Pipe) void {
    for (pipes) |pipe_desc| {
        shell.host.close(pipe_desc.read) catch {};
        shell.host.close(pipe_desc.write) catch {};
    }
}

fn waitPids(shell: anytype, pids: []const host_mod.Pid) ![]const host_mod.WaitStatus {
    const statuses = try shell.scratchAllocator().alloc(host_mod.WaitStatus, pids.len);
    for (pids, 0..) |pid, index| statuses[index] = try shell.host.wait(pid);
    return statuses;
}

fn forkPipelineStage(
    shell: anytype,
    command: ast.Command,
    pipes: []const host_mod.Pipe,
    stage_index: usize,
) !host_mod.Pid {
    const fd_actions = try pipelineFdActions(shell, pipes, stage_index);
    return switch (try shell.host.forkProcess()) {
        .parent => |pid| pid,
        .child => {
            applyPipelineChildFdActions(shell, fd_actions) catch shell.host.exit(127);
            const evaluated = evalCommand(shell, command) catch shell.host.exit(2);
            shell.host.exit(evaluated.status);
        },
    };
}

fn applyPipelineChildFdActions(shell: anytype, actions: []const host_mod.SpawnFdAction) !void {
    for (actions) |action| switch (action) {
        .close => |fd| try shell.host.close(fd),
        .duplicate => |dup| try shell.host.duplicateTo(dup.from, dup.to),
    };
}

fn pipelineFdActions(
    shell: anytype,
    pipes: []const host_mod.Pipe,
    stage_index: usize,
) ![]const host_mod.SpawnFdAction {
    const allocator = shell.scratchAllocator();
    var actions: std.ArrayList(host_mod.SpawnFdAction) = .empty;

    if (stage_index != 0) try actions.append(allocator, .{ .duplicate = .{
        .from = pipes[stage_index - 1].read,
        .to = .stdin,
    } });
    if (stage_index < pipes.len) try actions.append(allocator, .{ .duplicate = .{
        .from = pipes[stage_index].write,
        .to = .stdout,
    } });
    for (pipes) |pipe_desc| {
        try actions.append(allocator, .{ .close = pipe_desc.read });
        try actions.append(allocator, .{ .close = pipe_desc.write });
    }

    return actions.toOwnedSlice(allocator);
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
    const fields = try expandWordFields(shell, command.words, &expansion_status);
    if (fields.len == 0) {
        const status = try applyAssignmentsWithStatus(shell, command.assignments);
        return .{ .status = expansion_status orelse status };
    }
    const name = fields[0];
    if (builtin.lookup(name)) |definition| {
        if (definition.kind == .special) try applyAssignments(shell, command.assignments);
        const args = switch (definition.id) {
            .exit, .printf => fields,
            else => &[_][]const u8{name},
        };
        return builtin.eval(shell, definition, args);
    }
    return evalExternal(shell, fields, command.assignments);
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

fn expandWordFields(
    shell: anytype,
    words: []const ast.Word,
    substitution_status: ?*?result.ExitStatus,
) EvalError![]const []const u8 {
    std.debug.assert(words.len != 0);
    const allocator = shell.scratchAllocator();
    var fields: std.ArrayList([]const u8) = .empty;

    for (words) |word| {
        const expanded = try expandWordTracking(shell, word, substitution_status);
        if (wordContainsQuotes(word)) {
            try fields.append(allocator, expanded);
        } else {
            try appendSplitFields(allocator, &fields, expanded);
        }
    }

    return fields.toOwnedSlice(allocator);
}

fn appendSplitFields(
    allocator: std.mem.Allocator,
    fields: *std.ArrayList([]const u8),
    text: []const u8,
) !void {
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len and isDefaultIfsWhitespace(text[index])) index += 1;
        const start = index;
        while (index < text.len and !isDefaultIfsWhitespace(text[index])) index += 1;
        if (start != index) try fields.append(allocator, text[start..index]);
    }
}

fn isDefaultIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn wordContainsQuotes(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| partsContainQuotes(parts),
    };
}

fn partsContainQuotes(parts: []const ast.WordPart) bool {
    for (parts) |part| switch (part) {
        .single_quoted, .double_quoted => return true,
        else => {},
    };
    return false;
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
    var stack_expanded: [8][]const u8 = undefined;
    const expanded = if (parts.len <= stack_expanded.len)
        stack_expanded[0..parts.len]
    else
        try allocator.alloc([]const u8, parts.len);

    var total_len: usize = 0;
    for (parts, 0..) |part, index| {
        const bytes = try expandWordPart(shell, part, substitution_status);
        expanded[index] = bytes;
        total_len = std.math.add(usize, total_len, bytes.len) catch return error.OutOfMemory;
    }
    if (total_len == 0) return "";

    const output = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (expanded) |bytes| {
        @memcpy(output[cursor..][0..bytes.len], bytes);
        cursor += bytes.len;
    }
    return output;
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
    const capture = try evalCommandSubstitutionInChild(shell, program);
    const status = capture.status;
    if (substitution_status) |tracked| tracked.* = status;
    shell.state.last_status = status;
    return capture.output;
}

const CommandSubstitutionCapture = struct {
    output: []const u8,
    status: result.ExitStatus,
};

fn evalCommandSubstitutionInChild(shell: anytype, program: ast.Program) !CommandSubstitutionCapture {
    const pipe_desc = try shell.host.pipe();
    errdefer {
        shell.host.close(pipe_desc.read) catch {};
        shell.host.close(pipe_desc.write) catch {};
    }

    const pid = switch (try shell.host.forkProcess()) {
        .child => {
            shell.host.close(pipe_desc.read) catch shell.host.exit(127);
            shell.host.duplicateTo(pipe_desc.write, .stdout) catch shell.host.exit(127);
            shell.host.close(pipe_desc.write) catch shell.host.exit(127);
            const evaluated = evalProgram(@TypeOf(shell.host), shell, program) catch shell.host.exit(2);
            shell.host.exit(evaluated.status);
        },
        .parent => |child_pid| child_pid,
    };

    try shell.host.close(pipe_desc.write);
    const output = readCommandSubstitutionOutput(shell, pipe_desc.read) catch |err| {
        shell.host.close(pipe_desc.read) catch {};
        _ = shell.host.wait(pid) catch {};
        return err;
    };
    try shell.host.close(pipe_desc.read);
    const wait_status = try shell.host.wait(pid);
    return .{ .output = output, .status = wait_status.shellStatus() };
}

fn readCommandSubstitutionOutput(shell: anytype, fd: host_mod.Fd) ![]const u8 {
    const allocator = shell.scratchAllocator();
    var output: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try shell.host.read(fd, &buffer);
        if (read_len == 0) break;
        for (buffer[0..read_len]) |byte| {
            if (byte != 0) try output.append(allocator, byte);
        }
    }
    while (output.items.len != 0 and output.items[output.items.len - 1] == '\n') {
        output.items.len -= 1;
    }
    if (output.items.len == 0) return "";
    return output.toOwnedSlice(allocator);
}

fn expandParameter(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    parameter.validate();
    if (parameter.op) |operator| {
        return switch (operator) {
            .default_value => expandParameterDefault(shell, parameter),
            else => "",
        };
    }

    return switch (parameter.parameter) {
        .variable => |name| parameterValue(shell, name) orelse "",
        .special => |special| switch (special) {
            .question => try formatExitStatus(shell, shell.state.last_status),
            else => "",
        },
        .positional => "",
    };
}

fn expandParameterDefault(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const name = switch (parameter.parameter) {
        .variable => |variable_name| variable_name,
        else => return "",
    };
    const value = parameterValue(shell, name);
    const use_default = value == null or (parameter.colon and value.?.len == 0);
    if (!use_default) return value.?;
    return expandWord(shell, parameter.word.?);
}

fn parameterValue(shell: anytype, name: []const u8) ?[]const u8 {
    return if (shell.state.getVariable(name)) |variable| variable.value else null;
}

fn formatExitStatus(shell: anytype, status: result.ExitStatus) ![]const u8 {
    var buffer: [3]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{}", .{status});
    return shell.scratchAllocator().dupe(u8, text);
}

fn evalExternal(shell: anytype, fields: []const []const u8, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    const request = try makeExternalSpawnRequest(shell, fields, assignments, &.{});
    const status = try shell.host.spawnAndWait(request);
    return .{ .status = status.shellStatus() };
}

fn makeExternalSpawnRequest(
    shell: anytype,
    fields: []const []const u8,
    assignments: []const ast.Assignment,
    fd_actions: []const host_mod.SpawnFdAction,
) !host_mod.SpawnRequest {
    const argv = try makeExecArgv(shell, fields);
    const command_text = std.mem.span(argv[0].?);
    const command = argv[0].?[0..command_text.len :0];
    const path = try resolveCommandPath(shell, command);
    const envp = try makeExecEnvp(shell, assignments);
    return .{
        .path = path,
        .argv = argv,
        .envp = envp,
        .fd_actions = fd_actions,
    };
}

fn makeExecArgv(shell: anytype, fields: []const []const u8) ![:null]const ?[*:0]const u8 {
    std.debug.assert(fields.len != 0);
    const allocator = shell.scratchAllocator();
    const argv = try allocator.allocSentinel(?[*:0]const u8, fields.len, null);

    var total_len: usize = 0;
    for (fields) |bytes| {
        total_len = std.math.add(usize, total_len, bytes.len + 1) catch return error.OutOfMemory;
    }

    const arg_bytes = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (fields, 0..) |bytes, index| {
        @memcpy(arg_bytes[cursor..][0..bytes.len], bytes);
        arg_bytes[cursor + bytes.len] = 0;
        argv[index] = arg_bytes[cursor .. cursor + bytes.len :0].ptr;
        cursor += bytes.len + 1;
    }

    return argv;
}

const AssignmentEnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

fn makeExecEnvp(shell: anytype, assignments: []const ast.Assignment) ![:null]const ?[*:0]const u8 {
    if (assignments.len == 0) {
        if (comptime @hasDecl(@TypeOf(shell.*), "execEnvp")) return shell.execEnvp();

        const envp = try shell.scratchAllocator().allocSentinel(?[*:0]const u8, shell.env.len, null);
        for (shell.env, 0..) |entry, index| envp[index] = entry;
        return envp;
    }

    const allocator = shell.scratchAllocator();
    const assignment_entries = try allocator.alloc(AssignmentEnvEntry, assignments.len);
    for (assignments, 0..) |assignment, index| {
        assignment_entries[index] = .{
            .name = assignment.name,
            .value = try expandWord(shell, assignment.value),
        };
    }

    var env_len: usize = countBaseEnv(shell.env, assignment_entries);
    for (assignment_entries, 0..) |entry, index| {
        if (lastAssignmentIndex(assignment_entries, entry.name) == index) env_len += 1;
    }

    const envp = try allocator.allocSentinel(?[*:0]const u8, env_len, null);
    var env_index: usize = 0;
    for (shell.env) |entry| {
        const text = std.mem.span(entry);
        const name = envEntryName(text);
        if (containsAssignmentName(assignment_entries, name)) continue;
        envp[env_index] = entry;
        env_index += 1;
    }
    for (assignment_entries, 0..) |entry, index| {
        if (lastAssignmentIndex(assignment_entries, entry.name) != index) continue;
        envp[env_index] = (try makeEnvEntryZ(allocator, entry.name, entry.value)).ptr;
        env_index += 1;
    }
    std.debug.assert(env_index == env_len);
    return envp;
}

fn makeEnvEntryZ(allocator: std.mem.Allocator, name: []const u8, value: []const u8) ![:0]const u8 {
    const entry = try allocator.allocSentinel(u8, name.len + 1 + value.len, 0);
    @memcpy(entry[0..name.len], name);
    entry[name.len] = '=';
    @memcpy(entry[name.len + 1 ..][0..value.len], value);
    return entry;
}

fn countBaseEnv(env: []const [*:0]const u8, assignments: []const AssignmentEnvEntry) usize {
    var count: usize = 0;
    for (env) |entry| {
        const name = envEntryName(std.mem.span(entry));
        if (!containsAssignmentName(assignments, name)) count += 1;
    }
    return count;
}

fn envEntryName(entry: []const u8) []const u8 {
    return entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
}

fn containsAssignmentName(assignments: []const AssignmentEnvEntry, name: []const u8) bool {
    for (assignments) |assignment| {
        if (std.mem.eql(u8, assignment.name, name)) return true;
    }
    return false;
}

fn lastAssignmentIndex(assignments: []const AssignmentEnvEntry, name: []const u8) usize {
    var index = assignments.len;
    while (index != 0) {
        index -= 1;
        if (std.mem.eql(u8, assignments[index].name, name)) return index;
    }
    unreachable;
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
