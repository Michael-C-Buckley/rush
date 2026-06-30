//! Direct evaluator for the rewritten shell core.

const std = @import("std");

const ast = @import("ast.zig");
const builtin = @import("builtin.zig");
const host_mod = @import("../host.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const result = @import("result.zig");
const source_mod = @import("source.zig");
const state_mod = @import("state.zig");

pub const EvalError = anyerror;
const CopyError = std.mem.Allocator.Error;

pub fn evalProgram(comptime Host: type, shell: anytype, program: ast.Program) EvalError!result.EvalResult {
    _ = Host;
    program.validate();
    return evalList(shell, program.body);
}

fn evalList(shell: anytype, list: ast.List) EvalError!result.EvalResult {
    var status: result.ExitStatus = 0;
    for (list.entries) |entry| {
        const evaluated = switch (entry.terminator orelse .sequence) {
            .sequence => try evalAndOr(shell, entry.and_or),
            .background => try evalBackgroundAndOr(shell, entry.and_or),
        };
        status = evaluated.status;
        shell.state.last_status = status;
        if (evaluated.flow != .normal) return evaluated;
    }
    return .{ .status = status };
}

fn evalBackgroundAndOr(shell: anytype, and_or: ast.AndOr) EvalError!result.EvalResult {
    and_or.validate();
    const pid = switch (try shell.host.forkProcess()) {
        .parent => |child_pid| child_pid,
        .child => {
            const evaluated = evalAndOr(shell, and_or) catch shell.host.exit(2);
            shell.host.exit(evaluated.status);
        },
    };
    shell.state.last_background_pid = pid;
    return .{ .status = 0 };
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
        .compound => |compound| evalCompound(shell, compound),
        .function_definition => |definition| evalFunctionDefinition(shell, definition),
    };
}

fn evalCompound(shell: anytype, command: ast.CompoundInvocation) EvalError!result.EvalResult {
    command.validate();
    return switch (command.body) {
        .brace_group => |body| evalList(shell, body),
        else => .{ .status = 2 },
    };
}

fn evalFunctionDefinition(shell: anytype, definition: ast.FunctionDefinition) EvalError!result.EvalResult {
    definition.validate();
    try shell.state.putPersistentFunction(try copyFunction(shell.state.definitionAllocator(), definition));
    return .{};
}

fn evalSimple(shell: anytype, command: ast.SimpleCommand) EvalError!result.EvalResult {
    command.validate();
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    return evalSimpleScoped(shell, command) catch |err| switch (err) {
        error.ExpansionError => .{ .status = 1, .flow = .{ .fatal = 1 } },
        else => return err,
    };
}

fn evalSimpleScoped(shell: anytype, command: ast.SimpleCommand) EvalError!result.EvalResult {
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
            .exit, .printf, .set => fields,
            else => &[_][]const u8{name},
        };
        return builtin.eval(shell, definition, args);
    }
    if (shell.state.getFunction(name)) |function| return evalFunction(shell, function, command.assignments);
    return evalExternal(shell, fields, command.assignments);
}

const SavedVariable = struct {
    name: []const u8,
    variable: ?state_mod.Variable,
};

fn evalFunction(shell: anytype, function: state_mod.Function, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    function.validate();
    const saved = try saveAssignmentVariables(shell, assignments);
    defer restoreVariables(shell, saved);

    try applyExportedAssignments(shell, assignments);
    return evalCommand(shell, .{ .compound = .{ .body = function.definition.body } });
}

fn saveAssignmentVariables(shell: anytype, assignments: []const ast.Assignment) ![]const SavedVariable {
    const saved = try shell.scratchAllocator().alloc(SavedVariable, assignments.len);
    for (assignments, 0..) |assignment, index| {
        saved[index] = .{
            .name = assignment.name,
            .variable = shell.state.getVariable(assignment.name),
        };
    }
    return saved;
}

fn restoreVariables(shell: anytype, saved: []const SavedVariable) void {
    var index = saved.len;
    while (index != 0) {
        index -= 1;
        const entry = saved[index];
        if (entry.variable) |variable| {
            shell.state.putVariable(variable) catch {};
        } else {
            shell.state.removeVariable(entry.name);
        }
    }
}

fn applyExportedAssignments(shell: anytype, assignments: []const ast.Assignment) !void {
    var status: ?result.ExitStatus = null;
    for (assignments) |assignment| {
        const value = try expandWordTracking(shell, assignment.value, &status);
        try shell.state.putVariable(.{ .name = assignment.name, .value = value, .exported = true });
    }
}

fn copyFunction(allocator: std.mem.Allocator, definition: ast.FunctionDefinition) CopyError!state_mod.Function {
    const copied_name = try allocator.dupe(u8, definition.name);
    errdefer allocator.free(copied_name);
    const copied_definition: ast.FunctionDefinition = .{
        .name = copied_name,
        .body = try copyCompoundCommand(allocator, definition.body),
        .redirections = try copyRedirections(allocator, definition.redirections),
    };
    copied_definition.validate();
    return .{
        .name = copied_name,
        .source_text = copied_name,
        .definition = copied_definition,
    };
}

fn copyList(allocator: std.mem.Allocator, list: ast.List) CopyError!ast.List {
    const entries = try allocator.alloc(ast.ListEntry, list.entries.len);
    for (list.entries, 0..) |entry, index| {
        entries[index] = .{
            .and_or = try copyAndOr(allocator, entry.and_or),
            .terminator = entry.terminator,
        };
    }
    return .{ .entries = entries };
}

fn copyAndOr(allocator: std.mem.Allocator, and_or: ast.AndOr) CopyError!ast.AndOr {
    const pipelines = try allocator.alloc(ast.AndOrPipeline, and_or.pipelines.len);
    for (and_or.pipelines, 0..) |pipeline, index| {
        pipelines[index] = .{
            .operator = pipeline.operator,
            .pipeline = try copyPipeline(allocator, pipeline.pipeline),
        };
    }
    return .{ .pipelines = pipelines };
}

fn copyPipeline(allocator: std.mem.Allocator, pipeline: ast.Pipeline) CopyError!ast.Pipeline {
    const stages = try allocator.alloc(ast.Command, pipeline.stages.len);
    for (pipeline.stages, 0..) |stage, index| stages[index] = try copyCommand(allocator, stage);
    return .{ .stages = stages, .negated = pipeline.negated };
}

fn copyCommand(allocator: std.mem.Allocator, command: ast.Command) CopyError!ast.Command {
    return switch (command) {
        .simple => |simple| .{ .simple = try copySimpleCommand(allocator, simple) },
        .compound => |compound| .{ .compound = try copyCompoundInvocation(allocator, compound) },
        .function_definition => |definition| .{ .function_definition = (try copyFunction(allocator, definition)).definition },
    };
}

fn copyCompoundInvocation(allocator: std.mem.Allocator, invocation: ast.CompoundInvocation) CopyError!ast.CompoundInvocation {
    return .{
        .body = try copyCompoundCommand(allocator, invocation.body),
        .redirections = try copyRedirections(allocator, invocation.redirections),
    };
}

fn copyCompoundCommand(allocator: std.mem.Allocator, command: ast.CompoundCommand) CopyError!ast.CompoundCommand {
    return switch (command) {
        .brace_group => |list| .{ .brace_group = try copyList(allocator, list) },
        .subshell => |list| .{ .subshell = try copyList(allocator, list) },
        .if_command => |if_command| .{ .if_command = try copyIfCommand(allocator, if_command) },
        .loop => |loop| .{ .loop = try copyLoopCommand(allocator, loop) },
        .for_command => |for_command| .{ .for_command = try copyForCommand(allocator, for_command) },
        .case_command => |case_command| .{ .case_command = try copyCaseCommand(allocator, case_command) },
    };
}

fn copySimpleCommand(allocator: std.mem.Allocator, command: ast.SimpleCommand) CopyError!ast.SimpleCommand {
    const assignments = try allocator.alloc(ast.Assignment, command.assignments.len);
    for (command.assignments, 0..) |assignment, index| {
        assignments[index] = .{
            .name = assignment.name,
            .value = try copyWord(allocator, assignment.value),
            .span = assignment.span,
        };
    }

    const words = try copyWords(allocator, command.words);
    const redirections = try copyRedirections(allocator, command.redirections);
    return .{
        .assignments = assignments,
        .words = words,
        .redirections = redirections,
        .span = command.span,
    };
}

fn copyWords(allocator: std.mem.Allocator, words: []const ast.Word) CopyError![]const ast.Word {
    const copied = try allocator.alloc(ast.Word, words.len);
    for (words, 0..) |word, index| copied[index] = try copyWord(allocator, word);
    return copied;
}

fn copyWord(allocator: std.mem.Allocator, word: ast.Word) CopyError!ast.Word {
    return .{
        .data = switch (word.data) {
            .literal => |literal| .{ .literal = literal },
            .parts => |parts| .{ .parts = try copyWordParts(allocator, parts) },
        },
        .span = word.span,
    };
}

fn copyWordParts(allocator: std.mem.Allocator, parts: []const ast.WordPart) CopyError![]const ast.WordPart {
    const copied = try allocator.alloc(ast.WordPart, parts.len);
    for (parts, 0..) |part, index| {
        copied[index] = switch (part) {
            .literal => |bytes| .{ .literal = bytes },
            .single_quoted => |bytes| .{ .single_quoted = bytes },
            .double_quoted => |nested| .{ .double_quoted = try copyWordParts(allocator, nested) },
            .parameter => |parameter| .{ .parameter = try copyParameterExpansion(allocator, parameter) },
            .command_substitution => |substitution| .{
                .command_substitution = try copyCommandSubstitution(allocator, substitution),
            },
            .arithmetic => |bytes| .{ .arithmetic = bytes },
        };
    }
    return copied;
}

fn copyParameterExpansion(allocator: std.mem.Allocator, parameter: ast.ParameterExpansion) CopyError!ast.ParameterExpansion {
    return .{
        .parameter = parameter.parameter,
        .length = parameter.length,
        .colon = parameter.colon,
        .op = parameter.op,
        .word = if (parameter.word) |word| try copyWord(allocator, word) else null,
        .span = parameter.span,
    };
}

fn copyCommandSubstitution(
    allocator: std.mem.Allocator,
    substitution: ast.CommandSubstitution,
) CopyError!ast.CommandSubstitution {
    return .{
        .source_text = substitution.source_text,
        .parsed = if (substitution.parsed) |program| try copyProgramPtr(allocator, program.*) else null,
    };
}

fn copyProgramPtr(allocator: std.mem.Allocator, program: ast.Program) CopyError!*const ast.Program {
    const copied = try allocator.create(ast.Program);
    copied.* = .{ .source_id = program.source_id, .body = try copyList(allocator, program.body) };
    return copied;
}

fn copyRedirections(allocator: std.mem.Allocator, redirections: []const ast.Redirection) CopyError![]const ast.Redirection {
    const copied = try allocator.alloc(ast.Redirection, redirections.len);
    for (redirections, 0..) |redirection, index| {
        copied[index] = .{
            .fd = redirection.fd,
            .op = redirection.op,
            .target = try copyWord(allocator, redirection.target),
            .here_doc = redirection.here_doc,
            .span = redirection.span,
        };
    }
    return copied;
}

fn copyIfCommand(allocator: std.mem.Allocator, command: ast.IfCommand) CopyError!ast.IfCommand {
    const branches = try allocator.alloc(ast.IfBranch, command.branches.len);
    for (command.branches, 0..) |branch, index| {
        branches[index] = .{
            .condition = try copyList(allocator, branch.condition),
            .body = try copyList(allocator, branch.body),
        };
    }
    return .{
        .branches = branches,
        .else_body = if (command.else_body) |body| try copyList(allocator, body) else null,
    };
}

fn copyLoopCommand(allocator: std.mem.Allocator, command: ast.LoopCommand) CopyError!ast.LoopCommand {
    return .{
        .kind = command.kind,
        .condition = try copyList(allocator, command.condition),
        .body = try copyList(allocator, command.body),
    };
}

fn copyForCommand(allocator: std.mem.Allocator, command: ast.ForCommand) CopyError!ast.ForCommand {
    return .{
        .name = command.name,
        .words = switch (command.words) {
            .positional_parameters => .positional_parameters,
            .words => |words| .{ .words = try copyWords(allocator, words) },
        },
        .body = try copyList(allocator, command.body),
    };
}

fn copyCaseCommand(allocator: std.mem.Allocator, command: ast.CaseCommand) CopyError!ast.CaseCommand {
    const arms = try allocator.alloc(ast.CaseArm, command.arms.len);
    for (command.arms, 0..) |arm, index| {
        arms[index] = .{
            .patterns = try copyWords(allocator, arm.patterns),
            .body = try copyList(allocator, arm.body),
            .fallthrough = arm.fallthrough,
        };
    }
    return .{ .word = try copyWord(allocator, command.word), .arms = arms };
}

const AppliedRedirections = struct {
    frames: []const RedirectionFrame,
    here_doc_writers: []const host_mod.Pid,

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
        for (self.here_doc_writers) |pid| _ = shell.host.wait(pid) catch {};
    }
};

const RedirectionFrame = struct {
    target: host_mod.Fd,
    saved: ?host_mod.Fd,
};

fn applyRedirections(shell: anytype, redirections: []const ast.Redirection) !AppliedRedirections {
    var frames: std.ArrayList(RedirectionFrame) = .empty;
    var here_doc_writers: std.ArrayList(host_mod.Pid) = .empty;
    errdefer restoreFrames(shell, frames.items) catch {};

    for (redirections) |redirection| {
        try applyRedirection(shell, redirection, &frames, &here_doc_writers);
    }

    return .{
        .frames = try frames.toOwnedSlice(shell.scratchAllocator()),
        .here_doc_writers = try here_doc_writers.toOwnedSlice(shell.scratchAllocator()),
    };
}

fn applyRedirection(
    shell: anytype,
    redirection: ast.Redirection,
    frames: *std.ArrayList(RedirectionFrame),
    here_doc_writers: *std.ArrayList(host_mod.Pid),
) !void {
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
        .here_doc, .here_doc_strip_tabs => {
            const pid = try applyHereDocRedirection(shell, target, redirection.here_doc.?);
            try here_doc_writers.append(shell.scratchAllocator(), pid);
        },
    }
}

fn applyHereDocRedirection(shell: anytype, target: host_mod.Fd, here_doc: ast.HereDoc) !host_mod.Pid {
    const body = if (here_doc.delimiter_quoted) here_doc.body else try expandHereDocBody(shell, here_doc.body);
    const pipe_desc = try shell.host.pipe();
    errdefer {
        shell.host.close(pipe_desc.read) catch {};
        shell.host.close(pipe_desc.write) catch {};
    }

    const pid = switch (try shell.host.forkProcess()) {
        .child => {
            shell.host.close(pipe_desc.read) catch shell.host.exit(127);
            shell.host.writeAll(pipe_desc.write, body) catch shell.host.exit(1);
            shell.host.close(pipe_desc.write) catch shell.host.exit(1);
            shell.host.exit(0);
        },
        .parent => |child_pid| child_pid,
    };

    try shell.host.close(pipe_desc.write);
    if (pipe_desc.read != target) {
        defer shell.host.close(pipe_desc.read) catch {};
        try shell.host.duplicateTo(pipe_desc.read, target);
    }
    return pid;
}

fn expandHereDocBody(shell: anytype, body: []const u8) EvalError![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < body.len) {
        switch (body[index]) {
            '\\' => {
                if (index + 1 >= body.len) {
                    try output.append(shell.scratchAllocator(), '\\');
                    index += 1;
                    continue;
                }
                const next = body[index + 1];
                if (next == '\n') {
                    index += 2;
                } else if (next == '\\' or next == '$' or next == '`') {
                    try output.append(shell.scratchAllocator(), next);
                    index += 2;
                } else {
                    try output.append(shell.scratchAllocator(), '\\');
                    try output.append(shell.scratchAllocator(), next);
                    index += 2;
                }
            },
            '$' => {
                if (index + 1 < body.len and body[index + 1] == '(') {
                    const close_index = scanHereDocCommandSubstitution(body, index + 1) orelse {
                        try output.append(shell.scratchAllocator(), body[index]);
                        index += 1;
                        continue;
                    };
                    const source_text = body[index + 2 .. close_index];
                    const expanded = try expandCommandSubstitution(shell, .{ .source_text = source_text }, null);
                    try output.appendSlice(shell.scratchAllocator(), expanded);
                    index = close_index + 1;
                    continue;
                }
                if (index + 1 < body.len and body[index + 1] == '?') {
                    try output.appendSlice(shell.scratchAllocator(), try formatExitStatus(shell, shell.state.last_status));
                    index += 2;
                    continue;
                }
                const name_start = index + 1;
                const name_end = scanHereDocParameterName(body, name_start);
                if (name_end == name_start) {
                    try output.append(shell.scratchAllocator(), '$');
                    index += 1;
                    continue;
                }
                if (parameterValue(shell, body[name_start..name_end])) |value| try output.appendSlice(shell.scratchAllocator(), value);
                index = name_end;
            },
            else => {
                try output.append(shell.scratchAllocator(), body[index]);
                index += 1;
            },
        }
    }
    return output.toOwnedSlice(shell.scratchAllocator());
}

fn scanHereDocCommandSubstitution(body: []const u8, open_index: usize) ?usize {
    std.debug.assert(body[open_index] == '(');
    var depth: usize = 1;
    var quote: ?u8 = null;
    var index = open_index + 1;
    while (index < body.len) : (index += 1) {
        const byte = body[index];
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
            if (byte == '\\' and delimiter == '"' and index + 1 < body.len) index += 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '$' and index + 1 < body.len and body[index + 1] == '(') {
            depth += 1;
            index += 1;
        } else if (byte == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn scanHereDocParameterName(body: []const u8, start: usize) usize {
    if (start >= body.len or !isNameStart(body[start])) return start;
    var index = start + 1;
    while (index < body.len and isNameContinue(body[index])) index += 1;
    return index;
}

fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

fn restoreFrames(shell: anytype, frames: []const RedirectionFrame) !void {
    try (AppliedRedirections{ .frames = frames, .here_doc_writers = &.{} }).restore(shell);
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
    if (parameter.length) return expandParameterLength(shell, parameter);

    if (parameter.op) |operator| {
        return switch (operator) {
            .default_value => expandParameterDefault(shell, parameter),
            .assign_default => expandParameterAssignDefault(shell, parameter),
            .alternate_value => expandParameterAlternate(shell, parameter),
            .error_if_unset => expandParameterErrorIfUnset(shell, parameter),
            .remove_small_prefix,
            .remove_large_prefix,
            .remove_small_suffix,
            .remove_large_suffix,
            => expandParameterPatternRemoval(shell, parameter, operator),
        };
    }

    return switch (parameter.parameter) {
        .variable => |name| parameterValue(shell, name) orelse "",
        .special => |special| switch (special) {
            .hash => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.state.positionals.len}),
            .question => try formatExitStatus(shell, shell.state.last_status),
            .hyphen => try optionFlags(shell),
            .dollar => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{std.c.getpid()}),
            .bang => if (shell.state.last_background_pid) |pid|
                try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{pid})
            else
                "",
            .star, .at => try joinPositionals(shell, ' '),
        },
        .positional => |position| positionalValue(shell, position) orelse "",
    };
}

fn positionalValue(shell: anytype, position: u32) ?[]const u8 {
    if (position == 0) return shell.state.arg_zero;
    const index: usize = position - 1;
    if (index >= shell.state.positionals.len) return null;
    return shell.state.positionals[index];
}

fn optionFlags(shell: anytype) ![]const u8 {
    var flags: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    if (shell.state.options.errexit) try flags.append(allocator, 'e');
    if (shell.state.options.noglob) try flags.append(allocator, 'f');
    if (shell.state.options.monitor) try flags.append(allocator, 'm');
    if (shell.state.options.nounset) try flags.append(allocator, 'u');
    if (shell.state.options.xtrace) try flags.append(allocator, 'x');
    return flags.toOwnedSlice(allocator);
}

fn joinPositionals(shell: anytype, separator: u8) ![]const u8 {
    const positionals = shell.state.positionals;
    if (positionals.len == 0) return "";
    var total_len: usize = positionals.len - 1;
    for (positionals) |positional| total_len = std.math.add(usize, total_len, positional.len) catch return error.OutOfMemory;

    const output = try shell.scratchAllocator().alloc(u8, total_len);
    var cursor: usize = 0;
    for (positionals, 0..) |positional, index| {
        if (index != 0) {
            output[cursor] = separator;
            cursor += 1;
        }
        @memcpy(output[cursor..][0..positional.len], positional);
        cursor += positional.len;
    }
    return output;
}

fn expandParameterLength(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const value = switch (parameter.parameter) {
        .variable => |name| parameterValue(shell, name) orelse "",
        else => "",
    };
    const length = std.unicode.utf8CountCodepoints(value) catch value.len;
    return std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{length});
}

fn expandParameterDefault(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const name = switch (parameter.parameter) {
        .variable => |variable_name| variable_name,
        else => return "",
    };
    const value = parameterValue(shell, name);
    if (isParameterSet(parameter, value)) return value.?;
    return expandWord(shell, parameter.word.?);
}

fn expandParameterAssignDefault(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const name = switch (parameter.parameter) {
        .variable => |variable_name| variable_name,
        else => return "",
    };
    const value = parameterValue(shell, name);
    if (isParameterSet(parameter, value)) return value.?;

    const default = try expandWord(shell, parameter.word.?);
    try shell.state.putVariable(.{ .name = name, .value = default });
    return default;
}

fn expandParameterAlternate(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const name = switch (parameter.parameter) {
        .variable => |variable_name| variable_name,
        else => return "",
    };
    const value = parameterValue(shell, name);
    if (!isParameterSet(parameter, value)) return "";
    return expandWord(shell, parameter.word.?);
}

fn expandParameterErrorIfUnset(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const name = switch (parameter.parameter) {
        .variable => |variable_name| variable_name,
        else => return "",
    };
    const value = parameterValue(shell, name);
    if (isParameterSet(parameter, value)) return value.?;

    const message = try expandWord(shell, parameter.word.?);
    try writeExpansionDiagnostic(shell, parameter, name, message);
    return error.ExpansionError;
}

fn expandParameterPatternRemoval(
    shell: anytype,
    parameter: ast.ParameterExpansion,
    operator: ast.ParameterOperator,
) EvalError![]const u8 {
    const name = switch (parameter.parameter) {
        .variable => |variable_name| variable_name,
        else => return "",
    };
    const value = parameterValue(shell, name) orelse "";
    const pattern = try expandWord(shell, parameter.word.?);
    return switch (operator) {
        .remove_small_prefix => removePrefix(value, pattern, .small),
        .remove_large_prefix => removePrefix(value, pattern, .large),
        .remove_small_suffix => removeSuffix(value, pattern, .small),
        .remove_large_suffix => removeSuffix(value, pattern, .large),
        else => unreachable,
    };
}

const RemovalSize = enum {
    small,
    large,
};

fn removePrefix(value: []const u8, pattern: []const u8, size: RemovalSize) []const u8 {
    switch (size) {
        .small => {
            var cut: usize = 0;
            while (cut <= value.len) : (cut += 1) {
                if (patternMatches(pattern, value[0..cut])) return value[cut..];
            }
        },
        .large => {
            var cut = value.len + 1;
            while (cut != 0) {
                cut -= 1;
                if (patternMatches(pattern, value[0..cut])) return value[cut..];
            }
        },
    }
    return value;
}

fn removeSuffix(value: []const u8, pattern: []const u8, size: RemovalSize) []const u8 {
    switch (size) {
        .small => {
            var cut = value.len + 1;
            while (cut != 0) {
                cut -= 1;
                if (patternMatches(pattern, value[cut..])) return value[0..cut];
            }
        },
        .large => {
            var cut: usize = 0;
            while (cut <= value.len) : (cut += 1) {
                if (patternMatches(pattern, value[cut..])) return value[0..cut];
            }
        },
    }
    return value;
}

fn patternMatches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    return switch (pattern[0]) {
        '*' => patternMatchesStar(pattern[1..], text),
        '?' => text.len != 0 and patternMatches(pattern[1..], text[1..]),
        '[' => matchBracketPattern(pattern, text),
        else => text.len != 0 and pattern[0] == text[0] and patternMatches(pattern[1..], text[1..]),
    };
}

fn patternMatchesStar(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    var offset: usize = 0;
    while (offset <= text.len) : (offset += 1) {
        if (patternMatches(pattern, text[offset..])) return true;
    }
    return false;
}

fn matchBracketPattern(pattern: []const u8, text: []const u8) bool {
    if (text.len == 0) return false;
    const close = std.mem.indexOfScalarPos(u8, pattern, 1, ']') orelse {
        return pattern[0] == text[0] and patternMatches(pattern[1..], text[1..]);
    };
    if (bracketContains(pattern[1..close], text[0])) return patternMatches(pattern[close + 1 ..], text[1..]);
    return false;
}

fn bracketContains(expression: []const u8, byte: u8) bool {
    var index: usize = 0;
    while (index < expression.len) {
        if (index + 2 < expression.len and expression[index + 1] == '-') {
            if (byte >= expression[index] and byte <= expression[index + 2]) return true;
            index += 3;
        } else {
            if (byte == expression[index]) return true;
            index += 1;
        }
    }
    return false;
}

fn isParameterSet(parameter: ast.ParameterExpansion, value: ?[]const u8) bool {
    return value != null and (!parameter.colon or value.?.len != 0);
}

fn writeExpansionDiagnostic(
    shell: anytype,
    parameter: ast.ParameterExpansion,
    name: []const u8,
    message: []const u8,
) !void {
    const diagnostic = try std.fmt.allocPrint(
        shell.scratchAllocator(),
        "{}: expansion error: {s}: {s}\n",
        .{ parameter.span.start_line, name, message },
    );
    try shell.host.writeAll(.stderr, diagnostic);
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
    const exported_count = countExportedVariables(shell);
    if (assignments.len == 0 and exported_count == 0) {
        if (comptime @hasDecl(@TypeOf(shell.*), "execEnvp")) return shell.execEnvp();

        const envp = try shell.scratchAllocator().allocSentinel(?[*:0]const u8, shell.env.len, null);
        for (shell.env, 0..) |entry, index| envp[index] = entry;
        return envp;
    }

    const allocator = shell.scratchAllocator();
    const assignment_entries = try allocator.alloc(AssignmentEnvEntry, exported_count + assignments.len);
    var entry_count: usize = 0;
    var variable_iterator = shell.state.variables.iterator();
    while (variable_iterator.next()) |entry| {
        const variable = entry.value_ptr.*;
        if (!variable.exported) continue;
        assignment_entries[entry_count] = .{ .name = variable.name, .value = variable.value };
        entry_count += 1;
    }
    for (assignments) |assignment| {
        assignment_entries[entry_count] = .{
            .name = assignment.name,
            .value = try expandWord(shell, assignment.value),
        };
        entry_count += 1;
    }
    std.debug.assert(entry_count == assignment_entries.len);

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

fn countExportedVariables(shell: anytype) usize {
    var count: usize = 0;
    var iterator = shell.state.variables.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.exported) count += 1;
    }
    return count;
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
