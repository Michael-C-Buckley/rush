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
const token_mod = @import("token.zig");

pub const EvalError = anyerror;
const CopyError = std.mem.Allocator.Error;
const CommandLookupMode = enum { none, terse, verbose };

pub fn evalProgram(comptime Host: type, shell: anytype, program: ast.Program) EvalError!result.EvalResult {
    _ = Host;
    program.validate();
    return evalList(shell, program.body);
}

pub fn runExitTrap(shell: anytype, status: result.ExitStatus) EvalError!result.ExitStatus {
    const action = shell.state.exit_trap orelse return status;
    if (shell.state.running_exit_trap) return status;

    shell.state.running_exit_trap = true;
    defer shell.state.running_exit_trap = false;

    shell.state.last_status = status;
    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "trap", .text = action };
    const evaluated = try shell.evalSourceNested(src);
    if (evaluated.flow == .exit) return evaluated.status;
    const pending = try runPendingTrapCheckpoint(shell);
    return if (pending.flow != .normal) pending.status else status;
}

fn runPendingTrapCheckpoint(shell: anytype) EvalError!result.EvalResult {
    if (shell.state.running_signal_trap) return .{};
    const name = shell.state.popPendingTrap() orelse return .{};
    const action = shell.state.getSignalTrap(name) orelse return .{};

    shell.state.running_signal_trap = true;
    defer shell.state.running_signal_trap = false;

    const saved_status = shell.state.last_status;
    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "trap", .text = action };
    const evaluated = try shell.evalSourceNested(src);
    shell.state.last_status = saved_status;
    if (evaluated.flow != .normal) return evaluated;
    return .{ .status = saved_status };
}

fn evalList(shell: anytype, list: ast.List) EvalError!result.EvalResult {
    var status: result.ExitStatus = 0;
    for (list.entries) |entry| {
        const trap_result = try runPendingTrapCheckpoint(shell);
        if (trap_result.flow != .normal) return trap_result;
        const evaluated = switch (entry.terminator orelse .sequence) {
            .sequence => try evalAndOr(shell, entry.and_or),
            .background => try evalBackgroundAndOr(shell, entry.and_or),
        };
        status = evaluated.status;
        shell.state.last_status = status;
        if (evaluated.flow != .normal) return evaluated;
        if (shouldApplyErrexit(shell, evaluated)) return .{ .status = status, .flow = .{ .exit = status } };
    }
    return .{ .status = status };
}

fn shouldApplyErrexit(shell: anytype, evaluated: result.EvalResult) bool {
    return shell.state.options.errexit and shell.state.errexit_ignore_depth == 0 and evaluated.flow == .normal and
        evaluated.status != 0;
}

fn evalBackgroundAndOr(shell: anytype, and_or: ast.AndOr) EvalError!result.EvalResult {
    and_or.validate();
    if (and_or.pipelines.len == 1 and and_or.pipelines[0].pipeline.stages.len > 1) {
        return evalBackgroundPipeline(shell, and_or.pipelines[0].pipeline);
    }
    const background_subshell = backgroundSubshellInvocation(and_or);
    const pid = switch (try shell.host.forkProcess()) {
        .parent => |child_pid| child_pid,
        .child => {
            const scratch = shell.beginScratchScope() catch shell.host.exit(2);
            defer scratch.end();
            if (background_subshell) |subshell| {
                const evaluated = evalSubshellInCurrentProcess(shell, subshell.body.subshell, subshell.redirections) catch shell.host.exit(2);
                const status = runExitTrap(shell, evaluated.status) catch shell.host.exit(2);
                shell.host.exit(status);
            } else {
                const evaluated = evalAndOr(shell, and_or) catch shell.host.exit(2);
                shell.host.exit(evaluated.status);
            }
        },
    };
    shell.state.last_background_pid = pid;
    try shell.state.addBackgroundPid(pid);
    return .{ .status = 0 };
}

fn backgroundSubshellInvocation(and_or: ast.AndOr) ?ast.CompoundInvocation {
    if (and_or.pipelines.len != 1) return null;
    const pipeline = and_or.pipelines[0].pipeline;
    if (pipeline.negated or pipeline.stages.len != 1) return null;
    const command = pipeline.stages[0];
    if (command != .compound) return null;
    const compound = command.compound;
    if (compound.body != .subshell) return null;
    return compound;
}

fn evalBackgroundPipeline(shell: anytype, pipeline: ast.Pipeline) EvalError!result.EvalResult {
    pipeline.validate();
    std.debug.assert(pipeline.stages.len > 1);
    const pids = try spawnPipelineStages(shell, pipeline.stages, true);
    defer shell.allocator.free(pids);
    for (pids) |pid| try shell.state.addBackgroundPid(pid);
    shell.state.last_background_pid = pids[pids.len - 1];
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
        const ignore_errexit = index + 1 < and_or.pipelines.len;
        if (ignore_errexit) shell.state.errexit_ignore_depth += 1;
        last = evalPipeline(shell, pipeline.pipeline) catch |err| {
            if (ignore_errexit) shell.state.errexit_ignore_depth -= 1;
            return err;
        };
        if (ignore_errexit) shell.state.errexit_ignore_depth -= 1;
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
    const pipefail = shell.state.options.pipefail;
    const pids = try spawnPipelineStages(shell, stages, false);
    defer shell.allocator.free(pids);
    const scratch = try shell.beginScratchScope();
    defer scratch.end();
    const statuses = try waitPids(shell, pids);
    return .{ .status = pipelineStatus(statuses, pipefail) };
}

fn pipelineStatus(statuses: []const host_mod.WaitStatus, pipefail: bool) result.ExitStatus {
    if (!pipefail) return statuses[statuses.len - 1].shellStatus();
    var index = statuses.len;
    while (index != 0) {
        index -= 1;
        const status = statuses[index].shellStatus();
        if (status != 0) return status;
    }
    return 0;
}

fn spawnPipelineStages(shell: anytype, stages: []const ast.Command, direct_static_externals: bool) EvalError![]const host_mod.Pid {
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

    const pids = try shell.allocator.alloc(host_mod.Pid, stages.len);
    errdefer shell.allocator.free(pids);
    var spawned: usize = 0;
    errdefer {
        closePipes(shell, pipes[0..open_pipes]);
        _ = waitPids(shell, pids[0..spawned]) catch {};
    }

    for (stages, 0..) |stage, index| {
        pids[index] = try forkPipelineStage(shell, stage, pipes, index, direct_static_externals);
        spawned += 1;
    }

    closePipes(shell, pipes);
    open_pipes = 0;
    return pids;
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
    direct_static_external: bool,
) !host_mod.Pid {
    const fd_actions = try pipelineFdActions(shell, pipes, stage_index);
    if (direct_static_external) {
        if (try staticExternalPipelineStageRequest(shell, command, fd_actions)) |request| {
            return (try shell.host.spawn(request)).pid;
        }
    }
    return switch (try shell.host.forkProcess()) {
        .parent => |pid| pid,
        .child => {
            applyPipelineChildFdActions(shell, fd_actions) catch shell.host.exit(127);
            const evaluated = evalCommand(shell, command) catch shell.host.exit(2);
            shell.host.exit(evaluated.status);
        },
    };
}

fn staticExternalPipelineStageRequest(
    shell: anytype,
    command: ast.Command,
    fd_actions: []const host_mod.SpawnFdAction,
) !?host_mod.SpawnRequest {
    if (command != .simple) return null;
    const simple = command.simple;
    if (simple.assignments.len != 0 or simple.redirections.len != 0 or simple.words.len == 0) return null;

    const fields = try shell.scratchAllocator().alloc([]const u8, simple.words.len);
    for (simple.words, 0..) |word, index| {
        fields[index] = staticLiteralWord(word) orelse return null;
    }
    if (builtin.lookup(fields[0]) != null or shell.state.getFunction(fields[0]) != null) return null;
    return makeExternalSpawnRequest(shell, fields, &.{}, fd_actions) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

fn staticLiteralWord(word: ast.Word) ?[]const u8 {
    return switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| staticLiteralParts(parts),
    };
}

fn staticLiteralParts(parts: []const ast.WordPart) ?[]const u8 {
    if (parts.len != 1) return null;
    return switch (parts[0]) {
        .literal, .escaped, .single_quoted => |literal| literal,
        .double_quoted => |nested| staticLiteralParts(nested),
        else => null,
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
    if (command.body == .subshell) return evalSubshell(shell, command.body.subshell, command.redirections);

    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    var redirections = applyRedirections(shell, command.redirections) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return redirectionFailure(shell, false),
    };
    defer redirections.restore(shell) catch {};

    return switch (command.body) {
        .brace_group => |body| evalList(shell, body),
        .if_command => |if_command| evalIf(shell, if_command),
        .loop => |loop| evalLoop(shell, loop),
        .for_command => |for_command| evalFor(shell, for_command),
        .case_command => |case_command| evalCase(shell, case_command),
        else => .{ .status = 2 },
    };
}

fn evalIf(shell: anytype, command: ast.IfCommand) EvalError!result.EvalResult {
    command.validate();
    for (command.branches) |branch| {
        shell.state.errexit_ignore_depth += 1;
        const condition = evalList(shell, branch.condition) catch |err| {
            shell.state.errexit_ignore_depth -= 1;
            return err;
        };
        shell.state.errexit_ignore_depth -= 1;
        if (condition.flow != .normal) return condition;
        if (condition.status == 0) return evalList(shell, branch.body);
    }
    if (command.else_body) |body| return evalList(shell, body);
    return .{};
}

fn evalLoop(shell: anytype, command: ast.LoopCommand) EvalError!result.EvalResult {
    command.validate();
    shell.state.loop_depth += 1;
    defer shell.state.loop_depth -= 1;

    var status: result.ExitStatus = 0;
    while (true) {
        shell.state.errexit_ignore_depth += 1;
        const condition = evalList(shell, command.condition) catch |err| {
            shell.state.errexit_ignore_depth -= 1;
            return err;
        };
        shell.state.errexit_ignore_depth -= 1;
        if (condition.flow != .normal) return condition;
        const run_body = switch (command.kind) {
            .while_loop => condition.status == 0,
            .until_loop => condition.status != 0,
        };
        if (!run_body) return .{ .status = status };

        const evaluated = try evalList(shell, command.body);
        status = evaluated.status;
        switch (evaluated.flow) {
            .normal => {},
            .continue_ => |count| if (count <= 1 or count > shell.state.loop_depth) continue else return .{
                .status = status,
                .flow = .{ .continue_ = count - 1 },
            },
            .break_ => |count| if (count <= 1 or count > shell.state.loop_depth)
                return .{ .status = status }
            else
                return .{
                    .status = status,
                    .flow = .{ .break_ = count - 1 },
                },
            else => return evaluated,
        }
    }
}

fn evalSubshell(shell: anytype, body: ast.List, redirections: []const ast.Redirection) EvalError!result.EvalResult {
    const pid = switch (try shell.host.forkProcess()) {
        .child => {
            const scratch = shell.beginScratchScope() catch shell.host.exit(2);
            defer scratch.end();
            const evaluated = evalSubshellInCurrentProcess(shell, body, redirections) catch shell.host.exit(2);
            const status = runExitTrap(shell, evaluated.status) catch shell.host.exit(2);
            shell.host.exit(status);
        },
        .parent => |child_pid| child_pid,
    };
    const wait_status = try shell.host.wait(pid);
    return .{ .status = wait_status.shellStatus() };
}

fn evalSubshellInCurrentProcess(
    shell: anytype,
    body: ast.List,
    redirections: []const ast.Redirection,
) EvalError!result.EvalResult {
    shell.state.loop_depth = 0;
    shell.state.running_exit_trap = false;
    shell.state.forgetActiveExitTrap();
    var applied = applyRedirections(shell, redirections) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return redirectionFailure(shell, false),
    };
    defer applied.restore(shell) catch {};
    return evalList(shell, body);
}

fn evalFor(shell: anytype, command: ast.ForCommand) EvalError!result.EvalResult {
    command.validate();
    shell.state.loop_depth += 1;
    defer shell.state.loop_depth -= 1;

    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    const words = try snapshotFields(shell, try forCommandWords(shell, command.words));
    var status: result.ExitStatus = 0;
    for (words) |word| {
        try shell.state.putVariable(.{ .name = command.name, .value = word });
        const evaluated = try evalList(shell, command.body);
        status = evaluated.status;
        switch (evaluated.flow) {
            .normal => {},
            .continue_ => |count| if (count <= 1 or count > shell.state.loop_depth) continue else return .{
                .status = status,
                .flow = .{ .continue_ = count - 1 },
            },
            .break_ => |count| if (count <= 1 or count > shell.state.loop_depth)
                return .{ .status = status }
            else
                return .{
                    .status = status,
                    .flow = .{ .break_ = count - 1 },
                },
            else => return evaluated,
        }
    }
    return .{ .status = status };
}

fn forCommandWords(shell: anytype, words: ast.ForWords) ![]const []const u8 {
    return switch (words) {
        .positional_parameters => shell.state.positionals,
        .words => |word_list| expandForWordFields(shell, word_list),
    };
}

fn snapshotFields(shell: anytype, fields: []const []const u8) ![]const []const u8 {
    const allocator = shell.scratchAllocator();
    const snapshot = try allocator.alloc([]const u8, fields.len);
    for (fields, 0..) |field, index| snapshot[index] = try allocator.dupe(u8, field);
    return snapshot;
}

fn expandForWordFields(shell: anytype, words: []const ast.Word) ![]const []const u8 {
    if (words.len == 0) return &.{};
    const allocator = shell.scratchAllocator();
    var fields: std.ArrayList([]const u8) = .empty;
    for (words) |word| {
        if (try appendUnquotedAtFields(shell, &fields, word) or try appendSpecialQuotedFields(shell, &fields, word)) {
            continue;
        } else if (!wordHasDynamicExpansion(word)) {
            try appendStaticWordField(shell, &fields, word);
        } else {
            const expanded = try expandWordTracking(shell, word, null);
            if (wordContainsQuotes(word)) {
                try fields.append(allocator, expanded);
            } else {
                try appendSplitFields(shell, &fields, expanded, !wordExpandsLeadingTilde(shell, word));
            }
        }
    }
    return fields.toOwnedSlice(allocator);
}

fn appendSpecialQuotedFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    if (wordIsQuotedAt(word)) {
        try fields.appendSlice(shell.scratchAllocator(), shell.state.positionals);
        return true;
    }
    const parameter = singleDoubleQuotedParameter(word) orelse return false;
    if (parameter.parameter != .special or parameter.parameter.special != .at or parameter.op == null) return false;

    switch (parameter.op.?) {
        .default_value => {
            if (shell.state.positionals.len == 0) return false;
            try fields.appendSlice(shell.scratchAllocator(), shell.state.positionals);
            return true;
        },
        .alternate_value => {
            if (shell.state.positionals.len == 0 or parameter.word == null or !wordIsAtParameter(parameter.word.?)) {
                return false;
            }
            try fields.appendSlice(shell.scratchAllocator(), shell.state.positionals);
            return true;
        },
        else => return false,
    }
}

fn singleDoubleQuotedParameter(word: ast.Word) ?ast.ParameterExpansion {
    return switch (word.data) {
        .literal => null,
        .parts => |parts| if (parts.len == 1) switch (parts[0]) {
            .double_quoted => |quoted| if (quoted.len == 1) switch (quoted[0]) {
                .parameter => |parameter| parameter,
                else => null,
            } else null,
            else => null,
        } else null,
    };
}

fn appendUnquotedAtFields(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !bool {
    if (!wordIsUnquotedAt(word)) return false;
    const preserve_empty = ifsHasNonWhitespaceDelimiter(parameterValue(shell, "IFS") orelse " \t\n");
    for (shell.state.positionals) |positional| {
        if (positional.len == 0 and preserve_empty) {
            try fields.append(shell.scratchAllocator(), "");
        } else {
            try appendSplitFields(shell, fields, positional, true);
        }
    }
    return true;
}

fn wordIsUnquotedAt(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .parameter => |parameter| parameter.op == null and parameter.parameter == .special and
                parameter.parameter.special == .at,
            else => false,
        },
    };
}

fn wordIsQuotedAt(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .double_quoted => |quoted| quoted.len == 1 and switch (quoted[0]) {
                .parameter => |parameter| parameter.op == null and parameter.parameter == .special and
                    parameter.parameter.special == .at,
                else => false,
            },
            else => false,
        },
    };
}

fn wordIsAtParameter(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| parts.len == 1 and switch (parts[0]) {
            .parameter => |parameter| parameter.op == null and parameter.parameter == .special and
                parameter.parameter.special == .at,
            .double_quoted => |quoted| quoted.len == 1 and switch (quoted[0]) {
                .parameter => |parameter| parameter.op == null and parameter.parameter == .special and
                    parameter.parameter.special == .at,
                else => false,
            },
            else => false,
        },
    };
}

fn evalCase(shell: anytype, command: ast.CaseCommand) EvalError!result.EvalResult {
    command.validate();
    const scratch = try shell.beginScratchScope();
    defer scratch.end();

    const word = try expandWord(shell, command.word);
    var execute_next = false;
    for (command.arms) |arm| {
        const matches = execute_next or try caseArmMatches(shell, arm, word);
        if (!matches) continue;

        const evaluated = try evalList(shell, arm.body);
        if (evaluated.flow != .normal) return evaluated;
        switch (arm.fallthrough) {
            .none => return evaluated,
            .execute_next => execute_next = true,
            .test_next => execute_next = false,
        }
    }
    return .{ .status = 0 };
}

fn caseArmMatches(shell: anytype, arm: ast.CaseArm, word: []const u8) EvalError!bool {
    for (arm.patterns) |pattern_word| {
        const pattern = try expandPatternWord(shell, pattern_word);
        if (patternMatches(pattern, word)) return true;
    }
    return false;
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
        error.BadFd, error.BrokenPipe, error.InputOutput, error.WouldBlock => .{ .status = 1 },
        else => return err,
    };
}

fn redirectionFailure(shell: anytype, fatal: bool) result.EvalResult {
    shell.host.writeAll(.stderr, "redirection failed\n") catch {};
    return .{ .status = 1, .flow = if (fatal) .{ .fatal = 1 } else .normal };
}

fn evalSimpleScoped(shell: anytype, command: ast.SimpleCommand) EvalError!result.EvalResult {
    var redirections = applyRedirections(shell, command.redirections) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return redirectionFailure(shell, simpleRedirectionFailureIsFatal(command)),
    };
    var restore_redirections = true;
    defer if (restore_redirections) redirections.restore(shell) catch {};

    if (command.words.len == 0) {
        const status = try applyAssignmentsWithStatus(shell, command.assignments);
        return .{ .status = status };
    }

    if (try staticDeclarationBuiltinName(shell, command.words[0])) |id| {
        if (id == .export_ or id == .readonly) {
            try applyAssignments(shell, command.assignments);
            return evalDeclarationBuiltin(shell, id, command.words[1..]);
        }
    }

    var expansion_status: ?result.ExitStatus = null;
    const fields = try expandWordFields(shell, command.words, &expansion_status);
    if (fields.len == 0) {
        const status = try applyAssignmentsWithStatus(shell, command.assignments);
        return .{ .status = expansion_status orelse status };
    }
    const name = fields[0];
    if (builtin.lookup(name)) |definition| {
        if (definition.kind == .special) {
            try applyAssignments(shell, command.assignments);
            if (definition.id == .export_ or definition.id == .readonly) {
                return evalDeclarationBuiltin(shell, definition.id, command.words[1..]);
            }
            if (definition.id == .dot) return evalDotBuiltin(shell, fields);
            if (definition.id == .eval) return evalEvalBuiltin(shell, fields);
            if (definition.id == .exec) {
                restore_redirections = false;
                try redirections.commit(shell);
                if (fields.len == 1) return .{};
                return evalExecBuiltin(shell, fields);
            }
            const args = switch (definition.id) {
                .break_, .continue_, .exit, .return_, .set, .shift, .trap, .unset => fields,
                else => &[_][]const u8{name},
            };
            return fatalSpecialBuiltinError(definition, try builtin.eval(shell, definition, args));
        }
    }
    if (name.len == 0) return .{ .status = 127 };
    if (shell.state.getFunction(name)) |function| return evalFunction(shell, function, command.assignments, fields[1..]);
    if (builtin.lookup(name)) |definition| {
        if (definition.id == .cd) return evalCdBuiltin(shell, fields);
        if (definition.id == .command) {
            return evalCommandBuiltin(shell, fields, command.assignments, &redirections, &restore_redirections);
        }
        if (definition.id == .pwd) return evalPwdBuiltin(shell, fields);
        if (definition.id == .read) return evalReadBuiltin(shell, fields, command.assignments);
        if (definition.id == .test_ or definition.id == .bracket) {
            return evalTestBuiltin(shell, fields, command.assignments);
        }
        if (definition.id == .type) return evalTypeBuiltin(shell, fields);
        if (definition.id == .wait) return evalWaitBuiltin(shell, fields);
        const args = switch (definition.id) {
            .alias, .cd, .command, .getopts, .kill, .printf, .pwd, .read, .type, .umask, .unalias, .wait => fields,
            .false_, .true_ => &[_][]const u8{name},
            else => unreachable,
        };
        return builtin.eval(shell, definition, args);
    }
    return evalExternal(shell, fields, command.assignments);
}

fn simpleRedirectionFailureIsFatal(command: ast.SimpleCommand) bool {
    if (command.words.len == 0) return false;
    const name = staticLiteralWord(command.words[0]) orelse return false;
    const definition = builtin.lookup(name) orelse return false;
    return definition.kind == .special;
}

fn fatalSpecialBuiltinError(definition: builtin.Definition, evaluated: result.EvalResult) result.EvalResult {
    if (definition.kind == .special and evaluated.flow == .normal and evaluated.status == 2) {
        return .{ .status = evaluated.status, .flow = .{ .fatal = evaluated.status } };
    }
    return evaluated;
}

fn evalCdBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len > 2) return .{ .status = 2 };

    const allocator = shell.scratchAllocator();
    const old_pwd = try currentLogicalDir(shell);
    var print_new_dir = false;
    const target = if (args.len == 1) target: {
        break :target parameterValue(shell, "HOME") orelse return .{ .status = 1 };
    } else if (std.mem.eql(u8, args[1], "-")) target: {
        print_new_dir = true;
        break :target parameterValue(shell, "OLDPWD") orelse return .{ .status = 1 };
    } else target: {
        break :target try cdPathTarget(shell, args[1], &print_new_dir) orelse args[1];
    };

    shell.host.changeDir(target) catch return .{ .status = 1 };
    const new_pwd = try logicalPath(allocator, old_pwd, target);
    shell.state.putVariable(.{ .name = "OLDPWD", .value = old_pwd, .exported = exportedFlag(shell, "OLDPWD") }) catch {
        return .{ .status = 1 };
    };
    shell.state.putVariable(.{ .name = "PWD", .value = new_pwd, .exported = exportedFlag(shell, "PWD") }) catch {
        return .{ .status = 1 };
    };

    if (print_new_dir) try shell.host.writeAll(.stdout, try std.fmt.allocPrint(allocator, "{s}\n", .{new_pwd}));
    return .{};
}

fn evalPwdBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var physical = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-P")) {
            physical = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            physical = false;
        } else {
            return .{ .status = 2 };
        }
    }

    const cwd = if (physical) try shell.host.currentDir(shell.scratchAllocator()) else try currentLogicalDir(shell);
    try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}\n", .{cwd}));
    return .{};
}

fn evalDotBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len == 1) return .{ .status = 2 };

    const path = try resolveDotPath(shell, args[1]) orelse return .{ .status = 2 };
    const script = readDotScript(shell, path) catch return .{ .status = 1 };
    defer shell.allocator.free(script);

    const saved_positionals = try savePositionals(shell);
    defer freeSavedPositionals(shell, saved_positionals);
    var restored_positionals = false;
    errdefer if (!restored_positionals) restorePositionals(shell, saved_positionals) catch {};

    if (args.len > 2) try shell.state.setPositionals(args[2..]);

    const src: source_mod.Source = .{
        .id = 0,
        .kind = .sourced_file,
        .name = path,
        .text = script,
    };
    const evaluated = try shell.evalSourceNested(src);
    try restorePositionals(shell, saved_positionals);
    restored_positionals = true;
    if (evaluated.flow == .return_) return .{ .status = evaluated.status };
    return evaluated;
}

fn readDotScript(shell: anytype, path: []const u8) ![]const u8 {
    const allocator = shell.allocator;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = try shell.host.openZ(path_z, .{ .access = .read_only });
    defer shell.host.close(fd) catch {};

    var output: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try shell.host.read(fd, &buffer);
        if (read_len == 0) break;
        try output.appendSlice(allocator, buffer[0..read_len]);
    }
    return output.toOwnedSlice(allocator);
}

fn resolveDotPath(shell: anytype, operand: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, operand, '/') != null) return operand;

    const path = if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
    const allocator = shell.scratchAllocator();
    var candidate_buffer: std.ArrayList(u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, ':');
    while (iterator.next()) |directory| {
        candidate_buffer.clearRetainingCapacity();
        const prefix = if (directory.len == 0) "." else directory;
        try candidate_buffer.appendSlice(allocator, prefix);
        if (!std.mem.endsWith(u8, prefix, "/")) try candidate_buffer.append(allocator, '/');
        try candidate_buffer.appendSlice(allocator, operand);
        try candidate_buffer.append(allocator, 0);
        const candidate = candidate_buffer.items[0 .. candidate_buffer.items.len - 1 :0];
        if (shell.host.existsZ(candidate)) return candidate;
    }
    return null;
}

fn savePositionals(shell: anytype) ![]const []const u8 {
    const allocator = shell.allocator;
    const saved = try allocator.alloc([]const u8, shell.state.positionals.len);
    errdefer allocator.free(saved);
    var copied: usize = 0;
    errdefer for (saved[0..copied]) |positional| allocator.free(positional);
    for (shell.state.positionals, 0..) |positional, index| {
        saved[index] = try allocator.dupe(u8, positional);
        copied += 1;
    }
    return saved;
}

fn restorePositionals(shell: anytype, saved: []const []const u8) !void {
    try shell.state.setPositionals(saved);
}

fn freeSavedPositionals(shell: anytype, saved: []const []const u8) void {
    for (saved) |positional| shell.allocator.free(positional);
    shell.allocator.free(saved);
}

fn evalCommandBuiltin(
    shell: anytype,
    args: []const []const u8,
    assignments: []const ast.Assignment,
    redirections: *AppliedRedirections,
    restore_redirections: *bool,
) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var use_default_path = false;
    var lookup_mode: CommandLookupMode = .none;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'p' => use_default_path = true,
            'v' => lookup_mode = .terse,
            'V' => lookup_mode = .verbose,
            else => return .{ .status = 2 },
        };
    }
    if (index >= args.len) return .{};

    const saved = try saveAssignmentVariables(shell, assignments);
    var restored_assignments = false;
    errdefer if (!restored_assignments) restoreVariables(shell, saved);
    try applyAssignments(shell, assignments);

    const search_path: ?[]const u8 = if (use_default_path) defaultUtilityPath() else null;
    if (lookup_mode != .none) {
        const evaluated = try evalCommandLookup(shell, args[index..], lookup_mode, search_path);
        restoreVariables(shell, saved);
        restored_assignments = true;
        return evaluated;
    }

    const name = args[index];
    if (builtin.lookup(name)) |definition| {
        switch (definition.id) {
            .cd => {
                const evaluated = try evalCdBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .dot => {
                const evaluated = try evalDotBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .eval => {
                const evaluated = try evalEvalBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .exec => {
                restore_redirections.* = false;
                try redirections.commit(shell);
                if (index + 1 == args.len) return .{};
                return evalExecBuiltin(shell, args[index..]);
            },
            .export_, .readonly => {
                const evaluated = try evalDeclarationBuiltin(shell, definition.id, commandFieldsAsWords(shell, args[index + 1 ..]) catch return error.OutOfMemory);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .pwd => {
                const evaluated = try evalPwdBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .read => {
                const evaluated = try evalReadBuiltin(shell, args[index..], &.{});
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .test_, .bracket => {
                const evaluated = try evalTestBuiltin(shell, args[index..], assignments);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .type => {
                const evaluated = try evalTypeBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .wait => {
                const evaluated = try evalWaitBuiltin(shell, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .alias, .break_, .continue_, .exit, .getopts, .kill, .printf, .return_, .set, .shift, .trap, .umask, .unalias, .unset => {
                const evaluated = try builtin.eval(shell, definition, args[index..]);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .colon, .false_, .true_ => {
                const evaluated = try builtin.eval(shell, definition, &.{name});
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
            .command => {
                const evaluated = try evalCommandBuiltin(shell, args[index..], &.{}, redirections, restore_redirections);
                restoreVariables(shell, saved);
                restored_assignments = true;
                return evaluated;
            },
        }
    }
    const evaluated = try evalExternalWithSearchPath(shell, args[index..], assignments, search_path);
    restoreVariables(shell, saved);
    restored_assignments = true;
    return evaluated;
}

fn evalTestBuiltin(
    shell: anytype,
    args: []const []const u8,
    assignments: []const ast.Assignment,
) EvalError!result.EvalResult {
    _ = assignments;
    std.debug.assert(args.len != 0);
    const operands = testOperands(args) catch |err| {
        try writeTestDiagnostic(shell, args[0], err);
        return .{ .status = 2 };
    };
    const matches = evalTestOperands(shell, operands) catch |err| {
        switch (err) {
            error.Syntax => {
                try writeTestDiagnostic(shell, args[0], error.Syntax);
                return .{ .status = 2 };
            },
            error.Integer => {
                try writeTestDiagnostic(shell, args[0], error.Integer);
                return .{ .status = 2 };
            },
            else => return err,
        }
    };
    return .{ .status = if (matches) 0 else 1 };
}

const TestEvalError = error{
    Syntax,
    Integer,
};

fn testOperands(args: []const []const u8) TestEvalError![]const []const u8 {
    if (std.mem.eql(u8, args[0], "[")) {
        if (args.len < 2 or !std.mem.eql(u8, args[args.len - 1], "]")) return error.Syntax;
        return args[1 .. args.len - 1];
    }
    std.debug.assert(std.mem.eql(u8, args[0], "test"));
    return args[1..];
}

fn evalTestOperands(shell: anytype, args: []const []const u8) EvalError!bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].len != 0,
        2 => evalTwoArgumentTest(shell, args[0], args[1]),
        3 => evalThreeArgumentTest(shell, args[0], args[1], args[2]),
        4 => if (std.mem.eql(u8, args[0], "!"))
            !try evalThreeArgumentTest(shell, args[1], args[2], args[3])
        else
            error.Syntax,
        else => error.Syntax,
    };
}

fn evalTwoArgumentTest(shell: anytype, operator: []const u8, operand: []const u8) EvalError!bool {
    if (std.mem.eql(u8, operator, "!")) return operand.len == 0;
    if (std.mem.eql(u8, operator, "-n")) return operand.len != 0;
    if (std.mem.eql(u8, operator, "-z")) return operand.len == 0;
    return (try evalFileUnaryTest(shell, operator, operand)) orelse error.Syntax;
}

fn evalThreeArgumentTest(shell: anytype, left: []const u8, operator: []const u8, right: []const u8) EvalError!bool {
    if (std.mem.eql(u8, operator, "=")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, operator, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, operator, ">")) return std.mem.order(u8, left, right) == .gt;
    if (std.mem.eql(u8, operator, "<")) return std.mem.order(u8, left, right) == .lt;
    if (std.mem.eql(u8, left, "!")) {
        return !try evalTwoArgumentTest(shell, operator, right);
    }

    if (try evalFileBinaryTest(shell, left, operator, right)) |matches| return matches;
    if (try evalIntegerComparison(left, operator, right)) |matches| return matches;
    return error.Syntax;
}

fn evalIntegerComparison(left: []const u8, operator: []const u8, right: []const u8) TestEvalError!?bool {
    if (!isIntegerComparisonOperator(operator)) return null;
    const lhs = std.fmt.parseInt(i64, left, 10) catch return error.Integer;
    const rhs = std.fmt.parseInt(i64, right, 10) catch return error.Integer;
    if (std.mem.eql(u8, operator, "-eq")) return lhs == rhs;
    if (std.mem.eql(u8, operator, "-ne")) return lhs != rhs;
    if (std.mem.eql(u8, operator, "-gt")) return lhs > rhs;
    if (std.mem.eql(u8, operator, "-ge")) return lhs >= rhs;
    if (std.mem.eql(u8, operator, "-lt")) return lhs < rhs;
    if (std.mem.eql(u8, operator, "-le")) return lhs <= rhs;
    unreachable;
}

fn isIntegerComparisonOperator(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "-eq") or
        std.mem.eql(u8, operator, "-ne") or
        std.mem.eql(u8, operator, "-gt") or
        std.mem.eql(u8, operator, "-ge") or
        std.mem.eql(u8, operator, "-lt") or
        std.mem.eql(u8, operator, "-le");
}

fn evalFileUnaryTest(shell: anytype, operator: []const u8, operand: []const u8) EvalError!?bool {
    if (std.mem.eql(u8, operator, "-t")) return evalTerminalTest(shell, operand);

    const follow_symlinks = !std.mem.eql(u8, operator, "-h") and !std.mem.eql(u8, operator, "-L");
    const status = try fileStatus(shell, operand, follow_symlinks);
    if (std.mem.eql(u8, operator, "-b")) return if (status) |st| st.kind == .block_device else false;
    if (std.mem.eql(u8, operator, "-c")) return if (status) |st| st.kind == .character_device else false;
    if (std.mem.eql(u8, operator, "-d")) return if (status) |st| st.kind == .directory else false;
    if (std.mem.eql(u8, operator, "-e")) return status != null;
    if (std.mem.eql(u8, operator, "-f")) return if (status) |st| st.kind == .file else false;
    if (std.mem.eql(u8, operator, "-g")) return if (status) |st| st.mode & 0o2000 != 0 else false;
    if (std.mem.eql(u8, operator, "-h")) return if (status) |st| st.kind == .symlink else false;
    if (std.mem.eql(u8, operator, "-L")) return if (status) |st| st.kind == .symlink else false;
    if (std.mem.eql(u8, operator, "-p")) return if (status) |st| st.kind == .named_pipe else false;
    if (std.mem.eql(u8, operator, "-r")) return try fileAccess(shell, operand, .read);
    if (std.mem.eql(u8, operator, "-S")) return if (status) |st| st.kind == .socket else false;
    if (std.mem.eql(u8, operator, "-s")) return if (status) |st| st.size > 0 else false;
    if (std.mem.eql(u8, operator, "-u")) return if (status) |st| st.mode & 0o4000 != 0 else false;
    if (std.mem.eql(u8, operator, "-w")) return try fileAccess(shell, operand, .write);
    if (std.mem.eql(u8, operator, "-x")) return try fileAccess(shell, operand, .execute);
    return null;
}

fn evalFileBinaryTest(shell: anytype, left: []const u8, operator: []const u8, right: []const u8) EvalError!?bool {
    if (std.mem.eql(u8, operator, "-ef")) {
        const lhs = try fileStatus(shell, left, true) orelse return false;
        const rhs = try fileStatus(shell, right, true) orelse return false;
        return lhs.sameFile(rhs);
    }
    if (std.mem.eql(u8, operator, "-nt")) {
        const lhs = try fileStatus(shell, left, true) orelse return false;
        const rhs = try fileStatus(shell, right, true) orelse return true;
        return lhs.newerThan(rhs);
    }
    if (std.mem.eql(u8, operator, "-ot")) {
        const lhs = try fileStatus(shell, left, true);
        const rhs = try fileStatus(shell, right, true) orelse return false;
        return if (lhs) |status| status.olderThan(rhs) else true;
    }
    return null;
}

fn evalTerminalTest(shell: anytype, operand: []const u8) bool {
    const fd = std.fmt.parseInt(i32, operand, 10) catch return false;
    return shell.host.isTerminalFd(@enumFromInt(fd));
}

fn fileStatus(shell: anytype, path: []const u8, follow_symlinks: bool) !?host_mod.FileStatus {
    if (path.len == 0) return null;
    const path_z = try shell.scratchAllocator().dupeZ(u8, path);
    return shell.host.fileTestStatusZ(path_z, follow_symlinks);
}

fn fileAccess(shell: anytype, path: []const u8, access: host_mod.FileAccess) !bool {
    if (path.len == 0) return false;
    const path_z = try shell.scratchAllocator().dupeZ(u8, path);
    return shell.host.fileAccessZ(path_z, access);
}

fn writeTestDiagnostic(shell: anytype, name: []const u8, err: TestEvalError) !void {
    const message = switch (err) {
        error.Syntax => "invalid expression",
        error.Integer => "integer expression expected",
    };
    try shell.host.writeAll(.stderr, name);
    try shell.host.writeAll(.stderr, ": ");
    try shell.host.writeAll(.stderr, message);
    try shell.host.writeAll(.stderr, "\n");
}

fn evalCommandLookup(
    shell: anytype,
    names: []const []const u8,
    mode: CommandLookupMode,
    search_path: ?[]const u8,
) !result.EvalResult {
    var status: result.ExitStatus = 0;
    for (names) |name| {
        if (try commandLookupText(shell, name, mode, search_path)) |text| {
            try shell.host.writeAll(.stdout, text);
            try shell.host.writeAll(.stdout, "\n");
        } else {
            status = 1;
        }
    }
    return .{ .status = status };
}

fn commandLookupText(shell: anytype, name: []const u8, mode: CommandLookupMode, search_path: ?[]const u8) !?[]const u8 {
    const allocator = shell.scratchAllocator();
    if (shell.state.getAlias(name)) |alias| {
        return if (mode == .verbose)
            try std.fmt.allocPrint(allocator, "{s} is an alias for {s}", .{ name, alias.value })
        else
            try std.fmt.allocPrint(allocator, "alias {s}='{s}'", .{ name, alias.value });
    }
    if (shell.state.getFunction(name) != null) {
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is a shell function", .{name}) else name;
    }
    if (token_mod.lookupReservedWord(name) != null) {
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is a shell reserved word", .{name}) else name;
    }
    if (builtin.lookup(name) != null) {
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is a shell builtin", .{name}) else name;
    }
    if (try findCommandPath(shell, name, search_path)) |path| {
        return if (mode == .verbose) try std.fmt.allocPrint(allocator, "{s} is {s}", .{ name, path }) else path;
    }
    return null;
}

fn commandFieldsAsWords(shell: anytype, fields: []const []const u8) ![]const ast.Word {
    const words = try shell.scratchAllocator().alloc(ast.Word, fields.len);
    for (fields, 0..) |field, index| words[index] = .{ .data = .{ .literal = field } };
    return words;
}

fn evalTypeBuiltin(shell: anytype, args: []const []const u8) !result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len == 1) return .{ .status = 2 };
    return evalCommandLookup(shell, args[1..], .verbose, null);
}

fn evalWaitBuiltin(shell: anytype, args: []const []const u8) !result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len == 1) {
        for (shell.state.background_pids.items) |pid| _ = shell.host.wait(pid) catch {};
        shell.state.clearBackgroundPids();
        return .{};
    }

    var status: result.ExitStatus = 0;
    for (args[1..]) |arg| {
        const pid = waitOperandPid(shell, arg) orelse {
            try shell.host.writeAll(.stderr, "wait: invalid pid\n");
            status = 1;
            continue;
        };
        if (!shell.state.removeBackgroundPid(pid)) {
            try shell.host.writeAll(.stderr, "wait: unknown pid\n");
            status = 127;
            continue;
        }
        const waited = shell.host.wait(pid) catch {
            status = 127;
            continue;
        };
        status = waited.shellStatus();
    }
    return .{ .status = status };
}

fn waitOperandPid(shell: anytype, arg: []const u8) ?host_mod.Pid {
    if (arg.len >= 2 and arg[0] == '%') {
        const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch return null;
        if (job_id == 0 or job_id > shell.state.background_pids.items.len) return null;
        return shell.state.background_pids.items[job_id - 1];
    }
    return parseWaitPid(arg);
}

fn parseWaitPid(arg: []const u8) ?host_mod.Pid {
    if (arg.len == 0) return null;
    if (arg[0] == '%') return null;
    return std.fmt.parseInt(host_mod.Pid, arg, 10) catch null;
}

fn evalReadBuiltin(shell: anytype, args: []const []const u8, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    var raw = false;
    var delimiter: u8 = '\n';
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        var option_index: usize = 1;
        while (option_index < arg.len) : (option_index += 1) switch (arg[option_index]) {
            'r' => raw = true,
            'd' => {
                if (option_index + 1 < arg.len) {
                    delimiter = arg[option_index + 1];
                    option_index = arg.len;
                } else {
                    index += 1;
                    if (index >= args.len or args[index].len == 0) return .{ .status = 2 };
                    delimiter = args[index][0];
                }
                break;
            },
            else => return .{ .status = 2 },
        };
    }

    const names = if (index < args.len) args[index..] else &[_][]const u8{"REPLY"};
    for (names) |name| if (!isAssignmentName(name)) return .{ .status = 2 };

    const line_result = try readBuiltinLine(shell, raw, delimiter);
    const saved = try saveAssignmentVariables(shell, assignments);
    var restored_assignments = false;
    errdefer if (!restored_assignments) restoreVariables(shell, saved);
    try applyAssignments(shell, assignments);
    const ifs = parameterValue(shell, "IFS") orelse " \t\n";
    const values = try readFieldValues(shell, line_result.line, names.len, ifs);
    restoreVariables(shell, saved);
    restored_assignments = true;

    for (names, 0..) |name, name_index| {
        try shell.state.putVariable(.{ .name = name, .value = values[name_index] });
    }
    return .{ .status = if (line_result.found_delimiter) 0 else 1 };
}

const ReadLineResult = struct {
    line: []const u8,
    found_delimiter: bool,
};

const read_escape_marker: u8 = 0;

fn readBuiltinLine(shell: anytype, raw: bool, delimiter: u8) !ReadLineResult {
    var line: std.ArrayList(u8) = .empty;
    var byte: [1]u8 = undefined;
    while (true) {
        const read_len = try shell.host.read(.stdin, &byte);
        if (read_len == 0) return .{ .line = try line.toOwnedSlice(shell.scratchAllocator()), .found_delimiter = false };
        if (byte[0] == delimiter) return .{ .line = try line.toOwnedSlice(shell.scratchAllocator()), .found_delimiter = true };
        if (!raw and byte[0] == '\\') {
            const escaped_len = try shell.host.read(.stdin, &byte);
            if (escaped_len == 0) {
                try line.append(shell.scratchAllocator(), '\\');
                return .{ .line = try line.toOwnedSlice(shell.scratchAllocator()), .found_delimiter = false };
            }
            if (byte[0] == delimiter and delimiter == '\n') continue;
            try line.append(shell.scratchAllocator(), read_escape_marker);
        }
        try line.append(shell.scratchAllocator(), byte[0]);
    }
}

fn readFieldValues(shell: anytype, line: []const u8, count: usize, ifs: []const u8) ![]const []const u8 {
    std.debug.assert(count != 0);
    const values = try shell.scratchAllocator().alloc([]const u8, count);
    @memset(values, "");
    if (ifs.len == 0) {
        values[0] = try cleanReadField(shell, line);
        return values;
    }
    if (count == 1) {
        const start = skipIfsWhitespace(line, 0, ifs);
        values[0] = try cleanReadField(shell, line[start..trimTrailingIfsWhitespace(line, start, line.len, ifs)]);
        return values;
    }

    var pos: usize = 0;
    var value_index: usize = 0;
    while (value_index + 1 < count) : (value_index += 1) {
        pos = skipIfsWhitespace(line, pos, ifs);
        const start = pos;
        while (pos < line.len and ifsMatchAt(line, pos, ifs) == null) pos += utf8CharLen(line, pos);
        values[value_index] = try cleanReadField(shell, line[start..pos]);
        pos = consumeReadDelimiter(line, pos, ifs);
    }

    pos = skipIfsWhitespace(line, pos, ifs);
    const last_start = pos;
    var end = trimTrailingIfsWhitespace(line, last_start, line.len, ifs);
    const starts_with_nonwhitespace_delimiter = if (ifsMatchAt(line, last_start, ifs)) |match|
        !match.whitespace
    else
        false;
    if (!starts_with_nonwhitespace_delimiter) end = trimOneTrailingIfsNonWhitespace(line, last_start, end, ifs);
    values[value_index] = try cleanReadField(shell, line[last_start..end]);
    return values;
}

fn cleanReadField(shell: anytype, field: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, field, read_escape_marker) == null) return field;
    var output: std.ArrayList(u8) = .empty;
    for (field) |byte| {
        if (byte != read_escape_marker) try output.append(shell.scratchAllocator(), byte);
    }
    return output.toOwnedSlice(shell.scratchAllocator());
}

const IfsMatch = struct {
    len: usize,
    whitespace: bool,
};

fn ifsMatchAt(line: []const u8, pos: usize, ifs: []const u8) ?IfsMatch {
    if (pos >= line.len) return null;
    if (line[pos] == read_escape_marker or (pos != 0 and line[pos - 1] == read_escape_marker)) return null;
    const line_len = utf8CharLen(line, pos);
    var ifs_pos: usize = 0;
    while (ifs_pos < ifs.len) {
        const ifs_len = utf8CharLen(ifs, ifs_pos);
        if (line_len == ifs_len and std.mem.eql(u8, line[pos..][0..line_len], ifs[ifs_pos..][0..ifs_len])) {
            return .{ .len = line_len, .whitespace = ifs_len == 1 and isIfsWhitespace(ifs[ifs_pos]) };
        }
        ifs_pos += ifs_len;
    }
    return null;
}

fn skipIfsWhitespace(line: []const u8, pos: usize, ifs: []const u8) usize {
    var cursor = pos;
    while (ifsMatchAt(line, cursor, ifs)) |match| {
        if (!match.whitespace) break;
        cursor += match.len;
    }
    return cursor;
}

fn consumeReadDelimiter(line: []const u8, pos: usize, ifs: []const u8) usize {
    const match = ifsMatchAt(line, pos, ifs) orelse return pos;
    var cursor = pos + match.len;
    cursor = skipIfsWhitespace(line, cursor, ifs);
    if (match.whitespace) {
        if (ifsMatchAt(line, cursor, ifs)) |next| {
            if (!next.whitespace) cursor = skipIfsWhitespace(line, cursor + next.len, ifs);
        }
    }
    return cursor;
}

fn trimTrailingIfsWhitespace(line: []const u8, start: usize, end: usize, ifs: []const u8) usize {
    var cursor = end;
    while (cursor > start) {
        const prev = previousUtf8Start(line, start, cursor);
        const match = ifsMatchAt(line, prev, ifs) orelse break;
        if (!match.whitespace or prev + match.len != cursor) break;
        cursor = prev;
    }
    return cursor;
}

fn trimOneTrailingIfsNonWhitespace(line: []const u8, start: usize, end: usize, ifs: []const u8) usize {
    if (end <= start) return end;
    const prev = previousUtf8Start(line, start, end);
    const match = ifsMatchAt(line, prev, ifs) orelse return end;
    return if (!match.whitespace and prev + match.len == end) prev else end;
}

fn previousUtf8Start(line: []const u8, start: usize, end: usize) usize {
    var cursor = end - 1;
    while (cursor > start and (line[cursor] & 0xc0) == 0x80) cursor -= 1;
    return cursor;
}

fn utf8CharLen(bytes: []const u8, index: usize) usize {
    const byte = bytes[index];
    if (byte < 0x80) return 1;
    if ((byte & 0xe0) == 0xc0 and index + 1 < bytes.len) return 2;
    if ((byte & 0xf0) == 0xe0 and index + 2 < bytes.len) return 3;
    if ((byte & 0xf8) == 0xf0 and index + 3 < bytes.len) return 4;
    return 1;
}

fn isIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn currentLogicalDir(shell: anytype) ![]const u8 {
    return parameterValue(shell, "PWD") orelse try shell.host.currentDir(shell.scratchAllocator());
}

fn exportedFlag(shell: anytype, name: []const u8) bool {
    return if (shell.state.getVariable(name)) |variable| variable.exported else envValue(shell.env, name) != null;
}

fn cdPathTarget(shell: anytype, operand: []const u8, print_new_dir: *bool) !?[]const u8 {
    if (operand.len == 0 or operand[0] == '/' or startsWithDotPathComponent(operand)) return null;
    const cdpath = parameterValue(shell, "CDPATH") orelse return null;
    var iterator = std.mem.splitScalar(u8, cdpath, ':');
    while (iterator.next()) |prefix| {
        const candidate = if (prefix.len == 0)
            operand
        else
            try std.fmt.allocPrint(shell.scratchAllocator(), "{s}/{s}", .{ prefix, operand });
        if (try pathIsDirectory(shell, candidate, .other)) {
            print_new_dir.* = prefix.len != 0;
            return candidate;
        }
    }
    return null;
}

fn startsWithDotPathComponent(path: []const u8) bool {
    return std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..") or
        std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../");
}

fn logicalPath(allocator: std.mem.Allocator, old_pwd: []const u8, target: []const u8) ![]const u8 {
    var combined: []const u8 = target;
    if (target.len == 0 or target[0] != '/') {
        combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ old_pwd, target });
    }
    return normalizeAbsolutePath(allocator, combined);
}

fn normalizeAbsolutePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    std.debug.assert(path.len != 0 and path[0] == '/');
    var components: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len != 0) components.items.len -= 1;
            continue;
        }
        try components.append(allocator, component);
    }
    if (components.items.len == 0) return allocator.dupe(u8, "/");

    var total_len: usize = 0;
    for (components.items) |component| total_len += component.len + 1;
    const normalized = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (components.items) |component| {
        normalized[cursor] = '/';
        cursor += 1;
        @memcpy(normalized[cursor..][0..component.len], component);
        cursor += component.len;
    }
    return normalized;
}

fn staticDeclarationBuiltinName(shell: anytype, word: ast.Word) !?builtin.Id {
    if (wordHasDynamicExpansion(word)) return null;
    const name = try expandWordTracking(shell, word, null);
    if (std.mem.eql(u8, name, "export")) return .export_;
    if (std.mem.eql(u8, name, "readonly")) return .readonly;
    return null;
}

const DeclarationAssignment = struct {
    name: []const u8,
    value: ast.Word,
};

fn evalDeclarationBuiltin(shell: anytype, id: builtin.Id, words: []const ast.Word) EvalError!result.EvalResult {
    std.debug.assert(id == .export_ or id == .readonly);
    if (words.len == 0) return evalDeclarationList(shell, id);

    var status: result.ExitStatus = 0;
    for (words) |word| {
        if (try declarationAssignment(shell, word)) |assignment| {
            const value = try expandAssignmentWordTracking(shell, assignment.value, null);
            const existing = shell.state.getVariable(assignment.name);
            shell.state.putVariable(.{
                .name = assignment.name,
                .value = value,
                .exported = id == .export_ or (existing != null and existing.?.exported),
                .readonly = id == .readonly or (existing != null and existing.?.readonly),
            }) catch |err| switch (err) {
                error.ReadonlyVariable => status = 2,
                else => return err,
            };
            continue;
        }

        const names = try expandWordFields(shell, &.{word}, null);
        for (names) |name| {
            if (!isAssignmentName(name)) {
                status = 2;
                continue;
            }
            const existing = shell.state.getVariable(name);
            shell.state.putVariable(.{
                .name = name,
                .value = if (existing) |variable| variable.value else "",
                .exported = id == .export_ or (existing != null and existing.?.exported),
                .readonly = id == .readonly or (existing != null and existing.?.readonly),
            }) catch |err| switch (err) {
                error.ReadonlyVariable => status = 2,
                else => return err,
            };
        }
    }
    return .{ .status = status };
}

fn evalDeclarationList(shell: anytype, id: builtin.Id) !result.EvalResult {
    var iterator = shell.state.variables.iterator();
    while (iterator.next()) |entry| {
        const variable = entry.value_ptr.*;
        const include = switch (id) {
            .export_ => variable.exported,
            .readonly => variable.readonly,
            else => unreachable,
        };
        if (!include) continue;
        try shell.host.writeAll(.stdout, variable.name);
        try shell.host.writeAll(.stdout, "\n");
    }
    return .{};
}

fn declarationAssignment(shell: anytype, word: ast.Word) !?DeclarationAssignment {
    return switch (word.data) {
        .literal => |literal| literalDeclarationAssignment(literal),
        .parts => |parts| partsDeclarationAssignment(shell, parts),
    };
}

fn literalDeclarationAssignment(literal: []const u8) ?DeclarationAssignment {
    const equal_index = std.mem.indexOfScalar(u8, literal, '=') orelse return null;
    const name = literal[0..equal_index];
    if (!isAssignmentName(name)) return null;
    return .{ .name = name, .value = .{ .data = .{ .literal = literal[equal_index + 1 ..] } } };
}

fn partsDeclarationAssignment(shell: anytype, parts: []const ast.WordPart) !?DeclarationAssignment {
    if (parts.len == 0) return null;
    const first_literal = switch (parts[0]) {
        .literal => |literal| literal,
        else => return null,
    };
    const equal_index = std.mem.indexOfScalar(u8, first_literal, '=') orelse return null;
    const name = first_literal[0..equal_index];
    if (!isAssignmentName(name)) return null;

    const allocator = shell.scratchAllocator();
    var value_parts: std.ArrayList(ast.WordPart) = .empty;
    const suffix = first_literal[equal_index + 1 ..];
    if (suffix.len != 0) try value_parts.append(allocator, .{ .literal = suffix });
    try value_parts.appendSlice(allocator, parts[1..]);
    return .{ .name = name, .value = .{ .data = .{ .parts = try value_parts.toOwnedSlice(allocator) } } };
}

fn isAssignmentName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

fn evalEvalBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len != 0);
    if (args.len == 1) return .{};

    const allocator = shell.scratchAllocator();
    var total_len: usize = args.len - 2;
    for (args[1..]) |arg| total_len = std.math.add(usize, total_len, arg.len) catch return error.OutOfMemory;

    const script = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (args[1..], 0..) |arg, index| {
        if (index != 0) {
            script[cursor] = ' ';
            cursor += 1;
        }
        @memcpy(script[cursor..][0..arg.len], arg);
        cursor += arg.len;
    }

    const src: source_mod.Source = .{ .id = 0, .kind = .command_string, .name = "eval", .text = script };
    return shell.evalSourceNested(src);
}

fn evalExecBuiltin(shell: anytype, args: []const []const u8) EvalError!result.EvalResult {
    std.debug.assert(args.len > 1);
    const request = try makeExternalSpawnRequest(shell, args[1..], &.{}, &.{});
    try shell.host.exec(request);
    return .{ .status = 127 };
}

const SavedVariable = struct {
    name: []const u8,
    variable: ?state_mod.Variable,
};

fn evalFunction(
    shell: anytype,
    function: state_mod.Function,
    assignments: []const ast.Assignment,
    args: []const []const u8,
) EvalError!result.EvalResult {
    function.validate();
    const saved = try saveAssignmentVariables(shell, assignments);
    defer restoreVariables(shell, saved);

    const saved_positionals = try savePositionals(shell);
    defer freeSavedPositionals(shell, saved_positionals);
    var restored_positionals = false;
    errdefer if (!restored_positionals) restorePositionals(shell, saved_positionals) catch {};

    try applyExportedAssignments(shell, assignments);
    try shell.state.setPositionals(args);
    const evaluated = try evalCommand(shell, .{ .compound = .{
        .body = function.definition.body,
        .redirections = function.definition.redirections,
    } });
    try restorePositionals(shell, saved_positionals);
    restored_positionals = true;
    if (evaluated.flow == .return_) return .{ .status = evaluated.status };
    return evaluated;
}

fn saveAssignmentVariables(shell: anytype, assignments: []const ast.Assignment) ![]const SavedVariable {
    const saved = try shell.scratchAllocator().alloc(SavedVariable, assignments.len);
    for (assignments, 0..) |assignment, index| {
        const variable = if (shell.state.getVariable(assignment.name)) |existing| state_mod.Variable{
            .name = try shell.scratchAllocator().dupe(u8, existing.name),
            .value = try shell.scratchAllocator().dupe(u8, existing.value),
            .exported = existing.exported,
            .readonly = existing.readonly,
        } else null;
        saved[index] = .{
            .name = assignment.name,
            .variable = variable,
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
        const value = try expandAssignmentWordTracking(shell, assignment.value, &status);
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
        .quoted = word.quoted,
    };
}

fn copyWordParts(allocator: std.mem.Allocator, parts: []const ast.WordPart) CopyError![]const ast.WordPart {
    const copied = try allocator.alloc(ast.WordPart, parts.len);
    for (parts, 0..) |part, index| {
        copied[index] = switch (part) {
            .literal => |bytes| .{ .literal = bytes },
            .escaped => |bytes| .{ .escaped = bytes },
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

    fn commit(self: AppliedRedirections, shell: anytype) !void {
        for (self.frames) |frame| {
            if (frame.saved) |saved| try shell.host.close(saved);
        }
        for (self.here_doc_writers) |pid| _ = shell.host.wait(pid) catch {};
    }

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
    if (redirection.op == .duplicate_input or redirection.op == .duplicate_output) {
        try applyDuplicateRedirection(shell, redirection, target, frames);
        return;
    }

    const saved = saveFd(shell, target) catch |err| switch (err) {
        error.BadFd => null,
        else => return err,
    };
    try frames.append(shell.scratchAllocator(), .{ .target = target, .saved = saved });

    switch (redirection.op) {
        .input, .output, .append, .read_write, .clobber => {
            const path = try shell.scratchAllocator().dupeZ(u8, try expandWord(shell, redirection.target));
            const opened = try openRedirectionPath(shell, path, redirection.op);
            if (opened != target) {
                defer shell.host.close(opened) catch {};
                try shell.host.duplicateTo(opened, target);
            } else {
                try shell.host.setCloseOnExec(target, false);
            }
        },
        .duplicate_input, .duplicate_output => unreachable,
        .here_doc, .here_doc_strip_tabs => {
            const pid = try applyHereDocRedirection(shell, target, redirection.here_doc.?);
            try here_doc_writers.append(shell.scratchAllocator(), pid);
        },
    }
}

fn applyDuplicateRedirection(
    shell: anytype,
    redirection: ast.Redirection,
    target: host_mod.Fd,
    frames: *std.ArrayList(RedirectionFrame),
) !void {
    const source_text = try expandWord(shell, redirection.target);
    if (std.mem.eql(u8, source_text, "-")) {
        const saved = saveFd(shell, target) catch |err| switch (err) {
            error.BadFd => null,
            else => return err,
        };
        try frames.append(shell.scratchAllocator(), .{ .target = target, .saved = saved });
        shell.host.close(target) catch |err| switch (err) {
            error.Unexpected => {},
            else => return err,
        };
        return;
    }

    const source = try parseFd(source_text);
    if (source == target) return;
    const probe = try shell.host.duplicate(source);
    try shell.host.close(probe);

    const saved = saveFd(shell, target) catch |err| switch (err) {
        error.BadFd => null,
        else => return err,
    };
    try frames.append(shell.scratchAllocator(), .{ .target = target, .saved = saved });
    try shell.host.duplicateTo(source, target);
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
    } else {
        try shell.host.setCloseOnExec(target, false);
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
    return shell.host.duplicateAtLeast(fd, 10);
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

fn openRedirectionPath(shell: anytype, path: [:0]const u8, operator: ast.RedirectionOperator) !host_mod.Fd {
    if (operator != .output or !shell.state.options.noclobber) return shell.host.openZ(path, openOptions(operator));

    const opened = shell.host.openZ(path, .{
        .access = .write_only,
        .create = true,
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if ((try shell.host.fileStatusZ(path)).kind == .file) return error.PathAlreadyExists;
            return shell.host.openZ(path, .{ .access = .write_only });
        },
        else => return err,
    };
    return opened;
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
        const value = try expandAssignmentWordTracking(shell, assignment.value, &status);
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
        if (try appendUnquotedAtFields(shell, &fields, word) or try appendSpecialQuotedFields(shell, &fields, word)) {
            continue;
        } else if (!wordHasDynamicExpansion(word)) {
            try appendStaticWordField(shell, &fields, word);
        } else {
            const expanded = try expandWordTracking(shell, word, substitution_status);
            if (wordContainsQuotes(word)) {
                try fields.append(allocator, expanded);
            } else {
                try appendSplitFields(shell, &fields, expanded, !wordExpandsLeadingTilde(shell, word));
            }
        }
    }

    return fields.toOwnedSlice(allocator);
}

fn appendStaticWordField(shell: anytype, fields: *std.ArrayList([]const u8), word: ast.Word) !void {
    const expanded = try expandWordTracking(shell, word, null);
    if (wordExpandsLeadingTilde(shell, word)) {
        try fields.append(shell.scratchAllocator(), expanded);
    } else if (word.quoted) {
        try appendPathnameExpandedPattern(shell, fields, try staticWordPathnamePattern(shell, word));
    } else {
        try appendPathnameExpandedField(shell, fields, expanded);
    }
}

fn wordHasDynamicExpansion(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| partsHaveDynamicExpansion(parts),
    };
}

fn partsHaveDynamicExpansion(parts: []const ast.WordPart) bool {
    for (parts) |part| switch (part) {
        .parameter, .command_substitution, .arithmetic => return true,
        .double_quoted => |nested| if (partsHaveDynamicExpansion(nested)) return true,
        else => {},
    };
    return false;
}

fn staticWordPathnamePattern(shell: anytype, word: ast.Word) !PathnamePattern {
    const allocator = shell.scratchAllocator();
    var text: std.ArrayList(u8) = .empty;
    var special: std.ArrayList(bool) = .empty;
    switch (word.data) {
        .literal => |literal| try appendPathnamePatternBytes(allocator, &text, &special, literal, true),
        .parts => |parts| try appendStaticWordPathnameParts(allocator, &text, &special, parts, false),
    }
    return .{ .text = try text.toOwnedSlice(allocator), .special = try special.toOwnedSlice(allocator) };
}

fn appendStaticWordPathnameParts(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    special: *std.ArrayList(bool),
    parts: []const ast.WordPart,
    quoted: bool,
) !void {
    for (parts) |part| switch (part) {
        .literal => |bytes| try appendPathnamePatternBytes(allocator, text, special, bytes, !quoted),
        .escaped, .single_quoted => |bytes| try appendPathnamePatternBytes(allocator, text, special, bytes, false),
        .double_quoted => |nested| try appendStaticWordPathnameParts(allocator, text, special, nested, true),
        .parameter, .command_substitution, .arithmetic => unreachable,
    };
}

fn appendPathnamePatternBytes(
    allocator: std.mem.Allocator,
    text: *std.ArrayList(u8),
    special: *std.ArrayList(bool),
    bytes: []const u8,
    are_special: bool,
) !void {
    try text.appendSlice(allocator, bytes);
    try special.appendNTimes(allocator, are_special, bytes.len);
}

fn appendSplitFields(
    shell: anytype,
    fields: *std.ArrayList([]const u8),
    text: []const u8,
    pathname_expansion: bool,
) !void {
    const allocator = shell.scratchAllocator();
    const ifs = parameterValue(shell, "IFS") orelse " \t\n";
    if (ifs.len == 0) {
        if (text.len != 0) try fields.append(allocator, text);
        return;
    }

    var index: usize = 0;
    while (ifsDelimiter(ifs, text, index)) |delimiter| {
        if (!delimiter.whitespace) break;
        index += delimiter.len;
    }

    var field_start = index;
    while (index < text.len) {
        if (ifsDelimiter(ifs, text, index)) |delimiter| {
            if (delimiter.whitespace) {
                if (field_start < index) try appendMaybePathnameExpandedField(
                    shell,
                    fields,
                    text[field_start..index],
                    pathname_expansion,
                );
                index += delimiter.len;
                while (ifsDelimiter(ifs, text, index)) |next| {
                    if (!next.whitespace) break;
                    index += next.len;
                }
                if (ifsDelimiter(ifs, text, index)) |next| {
                    if (!next.whitespace) {
                        index += next.len;
                        while (ifsDelimiter(ifs, text, index)) |after| {
                            if (!after.whitespace) break;
                            index += after.len;
                        }
                    }
                }
                field_start = index;
                continue;
            }

            try appendMaybePathnameExpandedField(shell, fields, text[field_start..index], pathname_expansion);
            index += delimiter.len;
            while (ifsDelimiter(ifs, text, index)) |next| {
                if (!next.whitespace) break;
                index += next.len;
            }
            field_start = index;
            continue;
        }

        index += utf8SequenceLength(text[index..]);
    }
    if (field_start < text.len) try appendMaybePathnameExpandedField(shell, fields, text[field_start..], pathname_expansion);
}

fn appendMaybePathnameExpandedField(
    shell: anytype,
    fields: *std.ArrayList([]const u8),
    field: []const u8,
    pathname_expansion: bool,
) !void {
    if (!pathname_expansion) {
        try fields.append(shell.scratchAllocator(), field);
        return;
    }
    try appendPathnameExpandedField(shell, fields, field);
}

const PathnamePattern = struct {
    text: []const u8,
    special: ?[]const bool = null,

    fn slice(self: PathnamePattern, start: usize, end: usize) PathnamePattern {
        return .{
            .text = self.text[start..end],
            .special = if (self.special) |special| special[start..end] else null,
        };
    }

    fn byteIsSpecial(self: PathnamePattern, index: usize) bool {
        return self.special == null or self.special.?[index];
    }
};

fn appendPathnameExpandedField(shell: anytype, fields: *std.ArrayList([]const u8), field: []const u8) !void {
    try appendPathnameExpandedPattern(shell, fields, .{ .text = field });
}

fn appendPathnameExpandedPattern(shell: anytype, fields: *std.ArrayList([]const u8), pattern: PathnamePattern) !void {
    if (shell.state.options.noglob or !containsPatternMeta(pattern)) {
        try fields.append(shell.scratchAllocator(), pattern.text);
        return;
    }

    var matches: std.ArrayList([]const u8) = .empty;
    const allocator = shell.scratchAllocator();
    try expandPathnamePattern(shell, allocator, &matches, "", pattern);

    if (matches.items.len == 0) {
        try fields.append(allocator, pattern.text);
        return;
    }
    std.mem.sort([]const u8, matches.items, {}, stringLessThan);
    try fields.appendSlice(allocator, matches.items);
}

fn expandPathnamePattern(
    shell: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList([]const u8),
    prefix: []const u8,
    remaining: PathnamePattern,
) error{OutOfMemory}!void {
    const slash_index = std.mem.indexOfScalar(u8, remaining.text, '/');
    const component = if (slash_index) |index| remaining.slice(0, index) else remaining;
    const rest = if (slash_index) |index|
        remaining.slice(index + 1, remaining.text.len)
    else
        PathnamePattern{ .text = "" };
    const trailing_slash = slash_index != null and rest.text.len == 0;
    if (component.text.len == 0) return;

    if (!containsPatternMeta(component)) {
        const candidate = try joinPathComponent(allocator, prefix, component.text);
        if (trailing_slash) {
            if (try pathIsDirectory(shell, candidate, .other)) {
                try matches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/", .{candidate}));
            }
        } else if (rest.text.len == 0) {
            try matches.append(allocator, candidate);
        } else {
            try expandPathnamePattern(shell, allocator, matches, candidate, rest);
        }
        return;
    }

    const directory_path = if (prefix.len == 0) "." else prefix;
    const directory = shell.host.listDir(allocator, directory_path) catch return;
    var saw_dot = false;
    var saw_dotdot = false;
    for (directory.entries) |entry| {
        if (std.mem.eql(u8, entry.name, ".")) saw_dot = true;
        if (std.mem.eql(u8, entry.name, "..")) saw_dotdot = true;
        if (entry.name[0] == '.' and component.text[0] != '.') continue;
        if (!globMatches(component, entry.name)) continue;

        const candidate = try joinPathComponent(allocator, prefix, entry.name);
        if (trailing_slash) {
            if (try pathIsDirectory(shell, candidate, entry.kind)) {
                try matches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/", .{candidate}));
            }
        } else if (rest.text.len == 0) {
            try matches.append(allocator, candidate);
        } else {
            try expandPathnamePattern(shell, allocator, matches, candidate, rest);
        }
    }
    if (component.text[0] == '.') {
        if (!saw_dot) {
            try appendSyntheticDotPathnameMatch(
                shell,
                allocator,
                matches,
                prefix,
                component,
                rest,
                trailing_slash,
                ".",
            );
        }
        if (!saw_dotdot) {
            try appendSyntheticDotPathnameMatch(
                shell,
                allocator,
                matches,
                prefix,
                component,
                rest,
                trailing_slash,
                "..",
            );
        }
    }
}

fn appendSyntheticDotPathnameMatch(
    shell: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList([]const u8),
    prefix: []const u8,
    component: PathnamePattern,
    rest: PathnamePattern,
    trailing_slash: bool,
    entry_name: []const u8,
) error{OutOfMemory}!void {
    if (!globMatches(component, entry_name)) return;
    const candidate = try joinPathComponent(allocator, prefix, entry_name);
    if (trailing_slash) {
        try matches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/", .{candidate}));
    } else if (rest.text.len == 0) {
        try matches.append(allocator, candidate);
    } else {
        try expandPathnamePattern(shell, allocator, matches, candidate, rest);
    }
}

fn joinPathComponent(allocator: std.mem.Allocator, prefix: []const u8, component: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, component);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, component });
}

fn pathIsDirectory(shell: anytype, path: []const u8, kind: host_mod.FileKind) !bool {
    if (kind == .directory) return true;
    if (kind == .file) return false;
    const allocator = shell.scratchAllocator();
    const directory = shell.host.listDir(allocator, path) catch return false;
    _ = directory;
    return true;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn containsPatternMeta(pattern: PathnamePattern) bool {
    var index: usize = 0;
    while (index < pattern.text.len) : (index += utf8SequenceLength(pattern.text[index..])) {
        const byte = pattern.text[index];
        if (!pattern.byteIsSpecial(index)) continue;
        if (byte == '*' or byte == '?') return true;
        if (byte == '[' and bracketExpressionEnd(pattern, index) != null) return true;
    }
    return false;
}

fn globMatches(pattern: PathnamePattern, text: []const u8) bool {
    return globMatchesFrom(pattern, 0, text, 0);
}

fn globMatchesFrom(pattern: PathnamePattern, pattern_index: usize, text: []const u8, text_index: usize) bool {
    if (pattern_index == pattern.text.len) return text_index == text.len;
    if (pattern.byteIsSpecial(pattern_index) and pattern.text[pattern_index] == '*') {
        var next_pattern = pattern_index + 1;
        while (next_pattern < pattern.text.len and pattern.byteIsSpecial(next_pattern) and
            pattern.text[next_pattern] == '*')
        {
            next_pattern += 1;
        }
        var next_text = text_index;
        while (next_text <= text.len) : (next_text += if (next_text < text.len) utf8SequenceLength(text[next_text..]) else 1) {
            if (globMatchesFrom(pattern, next_pattern, text, next_text)) return true;
            if (next_text == text.len) break;
        }
        return false;
    }
    if (text_index == text.len) return false;
    const text_len = utf8SequenceLength(text[text_index..]);
    if (pattern.byteIsSpecial(pattern_index) and pattern.text[pattern_index] == '?') {
        return globMatchesFrom(pattern, pattern_index + 1, text, text_index + text_len);
    }
    if (pattern.byteIsSpecial(pattern_index) and pattern.text[pattern_index] == '[') {
        if (bracketExpressionMatches(pattern, pattern_index, text[text_index..][0..text_len])) |matched| {
            return matched.matched and globMatchesFrom(pattern, matched.end, text, text_index + text_len);
        }
    }
    const pattern_len = utf8SequenceLength(pattern.text[pattern_index..]);
    if (pattern_index + pattern_len > pattern.text.len or text_index + pattern_len > text.len) return false;
    if (!std.mem.eql(u8, pattern.text[pattern_index..][0..pattern_len], text[text_index..][0..pattern_len])) {
        return false;
    }
    return globMatchesFrom(pattern, pattern_index + pattern_len, text, text_index + pattern_len);
}

const BracketMatch = struct {
    matched: bool,
    end: usize,
};

fn bracketExpressionMatches(pattern: PathnamePattern, start: usize, character: []const u8) ?BracketMatch {
    std.debug.assert(pattern.text[start] == '[');
    var index = start + 1;
    var negated = false;
    if (index < pattern.text.len and (pattern.text[index] == '!' or pattern.text[index] == '^')) {
        negated = true;
        index += 1;
    }
    var matched = false;
    var saw_member = false;
    while (index < pattern.text.len and pattern.text[index] != ']') {
        const member_len = utf8SequenceLength(pattern.text[index..]);
        if (index + member_len > pattern.text.len) return null;
        const member = pattern.text[index..][0..member_len];
        index += member_len;
        saw_member = true;
        if (index < pattern.text.len and pattern.text[index] == '-' and index + 1 < pattern.text.len and
            pattern.text[index + 1] != ']')
        {
            index += 1;
            const end_len = utf8SequenceLength(pattern.text[index..]);
            if (index + end_len > pattern.text.len) return null;
            const end = pattern.text[index..][0..end_len];
            index += end_len;
            matched = matched or bracketRangeMatches(member, end, character);
        } else {
            matched = matched or std.mem.eql(u8, member, character);
        }
    }
    if (!saw_member or index >= pattern.text.len or pattern.text[index] != ']') return null;
    return .{ .matched = if (negated) !matched else matched, .end = index + 1 };
}

fn bracketExpressionEnd(pattern: PathnamePattern, start: usize) ?usize {
    std.debug.assert(pattern.text[start] == '[');
    var index = start + 1;
    if (index < pattern.text.len and (pattern.text[index] == '!' or pattern.text[index] == '^')) {
        index += 1;
    }
    var saw_member = false;
    while (index < pattern.text.len and pattern.text[index] != ']') {
        const member_len = utf8SequenceLength(pattern.text[index..]);
        if (index + member_len > pattern.text.len) return null;
        index += member_len;
        saw_member = true;
        if (index < pattern.text.len and pattern.text[index] == '-' and index + 1 < pattern.text.len and
            pattern.text[index + 1] != ']')
        {
            index += 1;
            const end_len = utf8SequenceLength(pattern.text[index..]);
            if (index + end_len > pattern.text.len) return null;
            index += end_len;
        }
    }
    if (!saw_member or index >= pattern.text.len or pattern.text[index] != ']') return null;
    return index + 1;
}

fn bracketRangeMatches(start: []const u8, end: []const u8, character: []const u8) bool {
    if (start.len != 1 or end.len != 1 or character.len != 1) return false;
    return start[0] <= character[0] and character[0] <= end[0];
}

fn isDefaultIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

const IfsDelimiter = struct {
    len: usize,
    whitespace: bool,
};

fn ifsDelimiter(ifs: []const u8, text: []const u8, index: usize) ?IfsDelimiter {
    if (index >= text.len) return null;
    var ifs_index: usize = 0;
    while (ifs_index < ifs.len) {
        const len = utf8SequenceLength(ifs[ifs_index..]);
        if (index + len <= text.len and std.mem.eql(u8, text[index..][0..len], ifs[ifs_index..][0..len])) {
            return .{ .len = len, .whitespace = len == 1 and isDefaultIfsWhitespace(ifs[ifs_index]) };
        }
        ifs_index += len;
    }
    return null;
}

fn ifsHasNonWhitespaceDelimiter(ifs: []const u8) bool {
    var index: usize = 0;
    while (index < ifs.len) {
        const len = utf8SequenceLength(ifs[index..]);
        if (len != 1 or !isDefaultIfsWhitespace(ifs[index])) return true;
        index += len;
    }
    return false;
}

fn utf8SequenceLength(text: []const u8) usize {
    if (text.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
    return @min(len, text.len);
}

fn wordContainsQuotes(word: ast.Word) bool {
    return switch (word.data) {
        .literal => false,
        .parts => |parts| partsContainQuotes(parts),
    };
}

fn partsContainQuotes(parts: []const ast.WordPart) bool {
    for (parts) |part| switch (part) {
        .escaped, .single_quoted, .double_quoted => return true,
        else => {},
    };
    return false;
}

fn expandWord(shell: anytype, word: ast.Word) ![]const u8 {
    return expandWordTracking(shell, word, null);
}

fn expandWordTracking(shell: anytype, word: ast.Word, substitution_status: ?*?result.ExitStatus) ![]const u8 {
    const expanded = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| try expandWordParts(shell, parts, substitution_status),
    };
    return expandLeadingTilde(shell, word, expanded);
}

fn expandAssignmentWordTracking(shell: anytype, word: ast.Word, substitution_status: ?*?result.ExitStatus) ![]const u8 {
    if (word.quoted) return expandWordTracking(shell, word, substitution_status);
    return switch (word.data) {
        .literal => |literal| expandAssignmentLiteralTildes(shell, literal),
        .parts => expandWordTracking(shell, word, substitution_status),
    };
}

fn expandAssignmentLiteralTildes(shell: anytype, literal: []const u8) ![]const u8 {
    const home = homeValue(shell) orelse return literal;
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    var index: usize = 0;
    while (index < literal.len) {
        if ((index == 0 or literal[index - 1] == ':') and assignmentTildePrefixLen(literal[index..]) != null) {
            try output.appendSlice(allocator, home);
            index += 1;
        } else {
            try output.append(allocator, literal[index]);
            index += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

fn expandLeadingTilde(shell: anytype, word: ast.Word, expanded: []const u8) ![]const u8 {
    if (word.quoted) return expanded;
    const literal = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| if (parts.len != 0) switch (parts[0]) {
            .literal => |literal| literal,
            else => return expanded,
        } else return expanded,
    };
    const prefix_len = tildePrefixLen(literal) orelse return expanded;
    const home = homeValue(shell) orelse return expanded;
    return std.fmt.allocPrint(shell.scratchAllocator(), "{s}{s}", .{ home, expanded[prefix_len..] });
}

fn wordExpandsLeadingTilde(shell: anytype, word: ast.Word) bool {
    if (word.quoted) return false;
    const literal = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| if (parts.len != 0) switch (parts[0]) {
            .literal => |literal| literal,
            else => return false,
        } else return false,
    };
    return tildePrefixLen(literal) != null and homeValue(shell) != null;
}

fn tildePrefixLen(literal: []const u8) ?usize {
    if (literal.len == 0 or literal[0] != '~') return null;
    if (literal.len == 1 or literal[1] == '/') return 1;
    return null;
}

fn assignmentTildePrefixLen(literal: []const u8) ?usize {
    if (literal.len == 0 or literal[0] != '~') return null;
    if (literal.len == 1 or literal[1] == '/' or literal[1] == ':') return 1;
    return null;
}

fn homeValue(shell: anytype) ?[]const u8 {
    if (parameterValue(shell, "HOME")) |home| return home;
    return envValue(shell.env, "HOME");
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
        .literal, .escaped, .single_quoted => |bytes| bytes,
        .arithmetic => |text| expandArithmetic(shell, text),
        .double_quoted => |parts| expandWordParts(shell, parts, substitution_status),
        .parameter => |parameter| expandParameter(shell, parameter),
        .command_substitution => |substitution| expandCommandSubstitution(shell, substitution, substitution_status),
    };
}

fn expandArithmetic(shell: anytype, text: []const u8) ![]const u8 {
    const expanded = try expandArithmeticText(shell, text);
    var parser_state: ArithmeticParser(@TypeOf(shell)) = .{ .shell = shell, .text = expanded };
    const value = try parser_state.parse();
    return std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{value});
}

fn expandArithmeticText(shell: anytype, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    var index: usize = 0;
    while (index < text.len) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < text.len and text[index] != quote) : (index += 1) {
                    try output.append(allocator, text[index]);
                }
                if (index >= text.len) return error.InvalidArithmetic;
                index += 1;
            },
            '$' => {
                if (index + 1 >= text.len) {
                    try output.append(allocator, '$');
                    index += 1;
                    continue;
                }
                if (text[index + 1] == '(' and (index + 2 >= text.len or text[index + 2] != '(')) {
                    const substitution_end = try scanArithmeticCommandSubstitution(text, index + 1);
                    const substitution: ast.CommandSubstitution = .{ .source_text = text[index + 2 .. substitution_end] };
                    try output.appendSlice(allocator, try expandCommandSubstitution(shell, substitution, null));
                    index = substitution_end + 1;
                    continue;
                }
                const expanded = try expandArithmeticParameter(shell, text, &index);
                try output.appendSlice(allocator, expanded);
            },
            else => {
                try output.append(allocator, text[index]);
                index += 1;
            },
        }
    }
    return output.toOwnedSlice(allocator);
}

fn expandArithmeticParameter(shell: anytype, text: []const u8, index: *usize) ![]const u8 {
    std.debug.assert(index.* < text.len and text[index.*] == '$');
    const parameter_start = index.* + 1;
    if (parameter_start >= text.len) {
        index.* += 1;
        return "$";
    }
    if (std.ascii.isDigit(text[parameter_start])) {
        index.* = parameter_start + 1;
        return positionalValue(shell, text[parameter_start] - '0') orelse "";
    }
    if (arithmeticSpecialParameter(text[parameter_start])) |special| {
        index.* = parameter_start + 1;
        return expandParameter(shell, .{ .parameter = .{ .special = special } });
    }
    if (!isArithmeticNameStart(text[parameter_start])) {
        index.* += 1;
        return "$";
    }
    var parameter_end = parameter_start + 1;
    while (parameter_end < text.len and isArithmeticNameContinue(text[parameter_end])) parameter_end += 1;
    index.* = parameter_end;
    return parameterValue(shell, text[parameter_start..parameter_end]) orelse {
        if (shell.state.options.nounset) return error.InvalidArithmetic;
        return "";
    };
}

fn arithmeticSpecialParameter(byte: u8) ?ast.SpecialParameter {
    return switch (byte) {
        '@' => .at,
        '*' => .star,
        '#' => .hash,
        '?' => .question,
        '-' => .hyphen,
        '$' => .dollar,
        '!' => .bang,
        else => null,
    };
}

fn scanArithmeticCommandSubstitution(text: []const u8, open_index: usize) !usize {
    std.debug.assert(open_index < text.len and text[open_index] == '(');
    var index = open_index + 1;
    var depth: usize = 1;
    while (index < text.len) {
        switch (text[index]) {
            '\'', '"' => |quote| {
                index += 1;
                while (index < text.len and text[index] != quote) index += 1;
                if (index >= text.len) return error.InvalidArithmetic;
                index += 1;
            },
            '\\' => index += if (index + 1 < text.len) 2 else 1,
            '(' => {
                depth += 1;
                index += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
                index += 1;
            },
            else => index += 1,
        }
    }
    return error.InvalidArithmetic;
}

const ArithmeticError = error{ InvalidArithmetic, OutOfMemory };

fn ArithmeticParser(comptime ShellType: type) type {
    return struct {
        shell: ShellType,
        text: []const u8,
        index: usize = 0,
        evaluating: bool = true,

        const Self = @This();

        fn parse(self: *Self) ArithmeticError!i64 {
            const value = try self.parseAssignment();
            self.skipWhitespace();
            if (self.index != self.text.len) return error.InvalidArithmetic;
            return value;
        }

        fn parseAssignment(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            const rewind = self.index;
            if (self.parseName()) |name| {
                self.skipWhitespace();
                if (self.eat('=')) {
                    const value = try self.parseAssignment();
                    try self.assignVariable(name, value);
                    return value;
                }
                if (self.eatString("+=")) {
                    const value = try self.variableValue(name) + try self.parseAssignment();
                    try self.assignVariable(name, value);
                    return value;
                }
            }
            self.index = rewind;
            return self.parseConditional();
        }

        fn parseConditional(self: *Self) ArithmeticError!i64 {
            const condition = try self.parseLogicalOr();
            self.skipWhitespace();
            if (!self.eat('?')) return condition;

            const outer_evaluating = self.evaluating;
            self.evaluating = outer_evaluating and condition != 0;
            const true_value = try self.parseAssignment();
            self.skipWhitespace();
            if (!self.eat(':')) return error.InvalidArithmetic;
            self.evaluating = outer_evaluating and condition == 0;
            const false_value = try self.parseAssignment();
            self.evaluating = outer_evaluating;
            return if (condition != 0) true_value else false_value;
        }

        fn parseLogicalOr(self: *Self) ArithmeticError!i64 {
            var value = try self.parseLogicalAnd();
            var saw_operator = false;
            while (true) {
                self.skipWhitespace();
                if (!self.eatString("||")) return if (saw_operator) if (value != 0) 1 else 0 else value;
                saw_operator = true;
                const outer_evaluating = self.evaluating;
                self.evaluating = outer_evaluating and value == 0;
                const rhs = try self.parseLogicalAnd();
                self.evaluating = outer_evaluating;
                value = if (value != 0 or rhs != 0) 1 else 0;
            }
        }

        fn parseLogicalAnd(self: *Self) ArithmeticError!i64 {
            var value = try self.parseBitOr();
            var saw_operator = false;
            while (true) {
                self.skipWhitespace();
                if (!self.eatString("&&")) return if (saw_operator) if (value != 0) 1 else 0 else value;
                saw_operator = true;
                const outer_evaluating = self.evaluating;
                self.evaluating = outer_evaluating and value != 0;
                const rhs = try self.parseBitOr();
                self.evaluating = outer_evaluating;
                value = if (value != 0 and rhs != 0) 1 else 0;
            }
        }

        fn parseBitOr(self: *Self) ArithmeticError!i64 {
            var value = try self.parseBitXor();
            while (true) {
                self.skipWhitespace();
                if (self.eatSingle('|')) {
                    value |= try self.parseBitXor();
                } else {
                    return value;
                }
            }
        }

        fn parseBitXor(self: *Self) ArithmeticError!i64 {
            var value = try self.parseBitAnd();
            while (true) {
                self.skipWhitespace();
                if (self.eat('^')) {
                    value ^= try self.parseBitAnd();
                } else {
                    return value;
                }
            }
        }

        fn parseBitAnd(self: *Self) ArithmeticError!i64 {
            var value = try self.parseRelational();
            while (true) {
                self.skipWhitespace();
                if (self.eatSingle('&')) {
                    value &= try self.parseRelational();
                } else {
                    return value;
                }
            }
        }

        fn parseRelational(self: *Self) ArithmeticError!i64 {
            var value = try self.parseShift();
            while (true) {
                self.skipWhitespace();
                if (self.eatString("==")) {
                    value = if (value == try self.parseShift()) 1 else 0;
                } else if (self.eatString("!=")) {
                    value = if (value != try self.parseShift()) 1 else 0;
                } else if (self.eatString(">=")) {
                    value = if (value >= try self.parseShift()) 1 else 0;
                } else if (self.eatString("<=")) {
                    value = if (value <= try self.parseShift()) 1 else 0;
                } else if (self.eat('>')) {
                    value = if (value > try self.parseShift()) 1 else 0;
                } else if (self.eat('<')) {
                    value = if (value < try self.parseShift()) 1 else 0;
                } else {
                    return value;
                }
            }
        }

        fn parseShift(self: *Self) ArithmeticError!i64 {
            var value = try self.parseAdd();
            while (true) {
                self.skipWhitespace();
                if (self.eatString("<<")) {
                    value = shiftLeft(value, try self.parseAdd());
                } else if (self.eatString(">>")) {
                    value = shiftRight(value, try self.parseAdd());
                } else {
                    return value;
                }
            }
        }

        fn parseAdd(self: *Self) ArithmeticError!i64 {
            var value = try self.parseMul();
            while (true) {
                self.skipWhitespace();
                if (self.eat('+')) {
                    value += try self.parseMul();
                } else if (self.eat('-')) {
                    value -= try self.parseMul();
                } else {
                    return value;
                }
            }
        }

        fn parseMul(self: *Self) ArithmeticError!i64 {
            var value = try self.parseUnary();
            while (true) {
                self.skipWhitespace();
                if (self.eat('*')) {
                    value *= try self.parseUnary();
                } else if (self.eat('/')) {
                    const rhs = try self.parseUnary();
                    if (!self.evaluating) return 0;
                    if (rhs == 0) return error.InvalidArithmetic;
                    value = @divTrunc(value, rhs);
                } else if (self.eat('%')) {
                    const rhs = try self.parseUnary();
                    if (!self.evaluating) return 0;
                    if (rhs == 0) return error.InvalidArithmetic;
                    value = @rem(value, rhs);
                } else {
                    return value;
                }
            }
        }

        fn parseUnary(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            if (self.eat('+')) return self.parseUnary();
            if (self.eat('-')) return -(try self.parseUnary());
            return self.parsePrimary();
        }

        fn parsePrimary(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            if (self.eat('(')) {
                const value = try self.parseAssignment();
                self.skipWhitespace();
                if (!self.eat(')')) return error.InvalidArithmetic;
                return value;
            }
            if (self.peek() == '$') {
                self.index += 1;
                const name = self.parseName() orelse return error.InvalidArithmetic;
                return self.variableValue(name);
            }
            if (isArithmeticNameStart(self.peek())) {
                const name = self.parseName().?;
                return self.variableValue(name);
            }
            return self.parseNumber();
        }

        fn parseNumber(self: *Self) ArithmeticError!i64 {
            self.skipWhitespace();
            const start = self.index;
            while (self.index < self.text.len and std.ascii.isAlphanumeric(self.text[self.index])) self.index += 1;
            if (start == self.index) return error.InvalidArithmetic;
            const token = self.text[start..self.index];
            if (std.mem.startsWith(u8, token, "0x") or std.mem.startsWith(u8, token, "0X")) {
                return std.fmt.parseInt(i64, token[2..], 16) catch error.InvalidArithmetic;
            }
            if (token.len > 1 and token[0] == '0') {
                return std.fmt.parseInt(i64, token[1..], 8) catch error.InvalidArithmetic;
            }
            return std.fmt.parseInt(i64, token, 10) catch error.InvalidArithmetic;
        }

        fn parseName(self: *Self) ?[]const u8 {
            if (!isArithmeticNameStart(self.peek())) return null;
            const start = self.index;
            self.index += 1;
            while (isArithmeticNameContinue(self.peek())) self.index += 1;
            return self.text[start..self.index];
        }

        fn variableValue(self: *Self, name: []const u8) ArithmeticError!i64 {
            if (!self.evaluating) return 0;
            const value = parameterValue(self.shell, name) orelse {
                if (self.shell.state.options.nounset) return error.InvalidArithmetic;
                return 0;
            };
            return std.fmt.parseInt(i64, value, 10) catch error.InvalidArithmetic;
        }

        fn assignVariable(self: *Self, name: []const u8, value: i64) ArithmeticError!void {
            if (!self.evaluating) return;
            const text = try std.fmt.allocPrint(self.shell.scratchAllocator(), "{}", .{value});
            self.shell.state.putVariable(.{ .name = name, .value = text }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ReadonlyVariable => return error.InvalidArithmetic,
            };
        }

        fn skipWhitespace(self: *Self) void {
            while (self.index < self.text.len and std.ascii.isWhitespace(self.text[self.index])) self.index += 1;
        }

        fn eat(self: *Self, byte: u8) bool {
            if (self.peek() != byte) return false;
            self.index += 1;
            return true;
        }

        fn eatSingle(self: *Self, byte: u8) bool {
            if (self.peek() != byte or self.peekOffset(1) == byte) return false;
            self.index += 1;
            return true;
        }

        fn eatString(self: *Self, bytes: []const u8) bool {
            if (!std.mem.startsWith(u8, self.text[self.index..], bytes)) return false;
            self.index += bytes.len;
            return true;
        }

        fn peek(self: Self) u8 {
            if (self.index >= self.text.len) return 0;
            return self.text[self.index];
        }

        fn peekOffset(self: Self, offset: usize) u8 {
            const target = self.index + offset;
            if (target >= self.text.len) return 0;
            return self.text[target];
        }
    };
}

fn isArithmeticNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isArithmeticNameContinue(byte: u8) bool {
    return isArithmeticNameStart(byte) or std.ascii.isDigit(byte);
}

fn shiftLeft(value: i64, amount: i64) i64 {
    if (amount < 0 or amount >= 63) return 0;
    return value << @as(u6, @intCast(amount));
}

fn shiftRight(value: i64, amount: i64) i64 {
    if (amount < 0 or amount >= 63) return 0;
    return value >> @as(u6, @intCast(amount));
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
        const tokens = try lexer.lexWithAliases(ast_allocator, src, shell.state);
        break :program try parser.parseWithAliases(ast_allocator, src, tokens, shell.state);
    };
    const capture = try evalCommandSubstitutionInChild(shell, substitution, program);
    const status = capture.status;
    if (substitution_status) |tracked| tracked.* = status;
    shell.state.last_status = status;
    return capture.output;
}

const CommandSubstitutionCapture = struct {
    output: []const u8,
    status: result.ExitStatus,
};

fn evalCommandSubstitutionInChild(
    shell: anytype,
    substitution: ast.CommandSubstitution,
    program: ast.Program,
) !CommandSubstitutionCapture {
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
            const static_request = staticExternalProgramRequest(shell, program) catch shell.host.exit(2);
            if (static_request) |request| {
                shell.host.exec(request) catch shell.host.exit(127);
            }
            shell.state.loop_depth = 0;
            shell.state.running_exit_trap = false;
            shell.state.diagnostic_line_offset += substitution.line_offset;
            shell.state.forgetActiveExitTrap();
            shell.state.exit_trap_listing = null;
            const evaluated = evalProgram(@TypeOf(shell.host), shell, program) catch shell.host.exit(2);
            const status = runExitTrap(shell, evaluated.status) catch shell.host.exit(2);
            shell.host.exit(status);
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

fn staticExternalProgramRequest(shell: anytype, program: ast.Program) !?host_mod.SpawnRequest {
    if (program.body.entries.len != 1) return null;
    const entry = program.body.entries[0];
    if (entry.terminator == .background) return null;
    if (entry.and_or.pipelines.len != 1) return null;
    const pipeline = entry.and_or.pipelines[0].pipeline;
    if (pipeline.negated or pipeline.stages.len != 1) return null;
    return staticExternalPipelineStageRequest(shell, pipeline.stages[0], &.{});
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
        .variable => |name| parameterValue(shell, name) orelse {
            if (shell.state.options.nounset) {
                try writeExpansionDiagnostic(shell, parameter, "parameter", "parameter not set");
                return error.ExpansionError;
            }
            return "";
        },
        .special => |special| switch (special) {
            .hash => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.state.positionals.len}),
            .question => try formatExitStatus(shell, shell.state.last_status),
            .hyphen => try optionFlags(shell),
            .dollar => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.host.currentProcessId()}),
            .bang => if (shell.state.last_background_pid) |pid|
                try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{pid})
            else
                "",
            .star => try joinPositionals(shell, ifsFirstCharacter(shell)),
            .at => try joinPositionals(shell, " "),
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
    if (shell.state.options.noclobber) try flags.append(allocator, 'C');
    if (shell.state.options.errexit) try flags.append(allocator, 'e');
    if (shell.state.options.noglob) try flags.append(allocator, 'f');
    if (shell.state.options.monitor) try flags.append(allocator, 'm');
    if (shell.state.options.nounset) try flags.append(allocator, 'u');
    if (shell.state.options.xtrace) try flags.append(allocator, 'x');
    return flags.toOwnedSlice(allocator);
}

fn ifsFirstCharacter(shell: anytype) []const u8 {
    const ifs = parameterValue(shell, "IFS") orelse " \t\n";
    if (ifs.len == 0) return "";
    const len = std.unicode.utf8ByteSequenceLength(ifs[0]) catch 1;
    return ifs[0..@min(len, ifs.len)];
}

fn joinPositionals(shell: anytype, separator: []const u8) ![]const u8 {
    const positionals = shell.state.positionals;
    if (positionals.len == 0) return "";
    var total_len = std.math.mul(usize, positionals.len - 1, separator.len) catch return error.OutOfMemory;
    for (positionals) |positional| total_len = std.math.add(usize, total_len, positional.len) catch return error.OutOfMemory;

    const output = try shell.scratchAllocator().alloc(u8, total_len);
    var cursor: usize = 0;
    for (positionals, 0..) |positional, index| {
        if (index != 0) {
            @memcpy(output[cursor..][0..separator.len], separator);
            cursor += separator.len;
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
    const value = try parameterCurrentValue(shell, parameter.parameter);
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
    const value = try parameterCurrentValue(shell, parameter.parameter);
    if (!isParameterSet(parameter, value)) return "";
    return expandWord(shell, parameter.word.?);
}

fn expandParameterErrorIfUnset(shell: anytype, parameter: ast.ParameterExpansion) EvalError![]const u8 {
    const value = try parameterCurrentValue(shell, parameter.parameter);
    if (isParameterSet(parameter, value)) return value.?;

    const message = try expandWord(shell, parameter.word.?);
    try writeExpansionDiagnostic(shell, parameter, parameterDiagnosticName(parameter.parameter), message);
    return error.ExpansionError;
}

fn parameterDiagnosticName(parameter: ast.Parameter) []const u8 {
    return switch (parameter) {
        .variable => |name| name,
        .positional => "positional parameter",
        .special => "special parameter",
    };
}

fn parameterCurrentValue(shell: anytype, parameter: ast.Parameter) !?[]const u8 {
    return switch (parameter) {
        .variable => |name| parameterValue(shell, name),
        .positional => |position| positionalValue(shell, position),
        .special => |special| switch (special) {
            .at => if (shell.state.positionals.len == 0) null else try joinPositionals(shell, " "),
            .star => if (shell.state.positionals.len == 0) null else try joinPositionals(shell, ifsFirstCharacter(shell)),
            .hash => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.state.positionals.len}),
            .question => try formatExitStatus(shell, shell.state.last_status),
            .hyphen => try optionFlags(shell),
            .dollar => try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{shell.host.currentProcessId()}),
            .bang => if (shell.state.last_background_pid) |pid|
                try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{pid})
            else
                null,
        },
    };
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
    const pattern = try expandPatternWord(shell, parameter.word.?);
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

fn expandPatternWord(shell: anytype, word: ast.Word) ![]const u8 {
    const pattern = switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| try expandPatternParts(shell, parts),
    };
    return expandLeadingTilde(shell, word, pattern);
}

fn expandPatternParts(shell: anytype, parts: []const ast.WordPart) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    const allocator = shell.scratchAllocator();
    for (parts) |part| switch (part) {
        .literal => |bytes| try output.appendSlice(allocator, bytes),
        .escaped => |bytes| try appendPatternLiteral(allocator, &output, bytes),
        .single_quoted => |bytes| try appendPatternLiteral(allocator, &output, bytes),
        .double_quoted => |nested| try appendPatternLiteral(allocator, &output, try expandWordParts(shell, nested, null)),
        .parameter, .command_substitution, .arithmetic => {
            try output.appendSlice(allocator, try expandWordPart(shell, part, null));
        },
    };
    return output.toOwnedSlice(allocator);
}

fn appendPatternLiteral(allocator: std.mem.Allocator, output: *std.ArrayList(u8), bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte == '*' or byte == '?' or byte == '[' or byte == '\\') try output.append(allocator, '\\');
        try output.append(allocator, byte);
    }
}

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
        '\\' => if (pattern.len >= 2)
            text.len != 0 and pattern[1] == text[0] and patternMatches(pattern[2..], text[1..])
        else
            text.len != 0 and pattern[0] == text[0] and patternMatches(pattern[1..], text[1..]),
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
    const negated = expression.len != 0 and (expression[0] == '!' or expression[0] == '^');
    const members = if (negated) expression[1..] else expression;
    var matched = false;
    var index: usize = 0;
    while (index < members.len) {
        if (index + 2 < members.len and members[index + 1] == '-') {
            if (byte >= members[index] and byte <= members[index + 2]) matched = true;
            index += 3;
        } else {
            if (byte == members[index]) matched = true;
            index += 1;
        }
    }
    return if (negated) !matched else matched;
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
        .{ parameter.span.start_line + shell.state.diagnostic_line_offset, name, message },
    );
    try shell.host.writeAll(.stderr, diagnostic);
}

fn parameterValue(shell: anytype, name: []const u8) ?[]const u8 {
    if (shell.state.getVariable(name)) |variable| return variable.value;
    if (std.mem.eql(u8, name, "PWD")) {
        if (comptime @hasDecl(@TypeOf(shell.host), "currentDir")) {
            return shell.host.currentDir(shell.scratchAllocator()) catch envValue(shell.env, name);
        }
    }
    return envValue(shell.env, name);
}

fn formatExitStatus(shell: anytype, status: result.ExitStatus) ![]const u8 {
    var buffer: [3]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{}", .{status});
    return shell.scratchAllocator().dupe(u8, text);
}

fn evalExternal(shell: anytype, fields: []const []const u8, assignments: []const ast.Assignment) EvalError!result.EvalResult {
    return evalExternalWithSearchPath(shell, fields, assignments, null);
}

fn evalExternalWithSearchPath(
    shell: anytype,
    fields: []const []const u8,
    assignments: []const ast.Assignment,
    search_path: ?[]const u8,
) EvalError!result.EvalResult {
    if (fields[0].len == 0) return .{ .status = 127 };
    const saved = try saveAssignmentVariables(shell, assignments);
    var restored_assignments = false;
    errdefer if (!restored_assignments) restoreVariables(shell, saved);
    try applyAssignments(shell, assignments);
    if (try commandFoundButNotExecutable(shell, fields[0], search_path)) {
        restoreVariables(shell, saved);
        restored_assignments = true;
        return .{ .status = 126 };
    }
    if (try findCommandPath(shell, fields[0], search_path) == null) {
        try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: not found\n", .{fields[0]}));
        restoreVariables(shell, saved);
        restored_assignments = true;
        return .{ .status = 127 };
    }
    const request = try makeExternalSpawnRequestWithSearchPath(shell, fields, assignments, &.{}, search_path);
    const status = try shell.host.spawnAndWait(request);
    restoreVariables(shell, saved);
    restored_assignments = true;
    return .{ .status = status.shellStatus() };
}

fn commandFoundButNotExecutable(shell: anytype, command: []const u8, search_path: ?[]const u8) !bool {
    const allocator = shell.scratchAllocator();
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        const command_z = try allocator.dupeZ(u8, command);
        if (try pathIsDirectory(shell, command, .other)) return true;
        return !shell.host.isExecutableZ(command_z) and shell.host.existsZ(command_z);
    }

    var found = false;
    const path = search_path orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
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
        if (try pathIsDirectory(shell, candidate, .other)) {
            found = true;
            continue;
        }
        if (shell.host.isExecutableZ(candidate)) return false;
        found = found or shell.host.existsZ(candidate);
    }
    return found;
}

fn makeExternalSpawnRequest(
    shell: anytype,
    fields: []const []const u8,
    assignments: []const ast.Assignment,
    fd_actions: []const host_mod.SpawnFdAction,
) !host_mod.SpawnRequest {
    return makeExternalSpawnRequestWithSearchPath(shell, fields, assignments, fd_actions, null);
}

fn makeExternalSpawnRequestWithSearchPath(
    shell: anytype,
    fields: []const []const u8,
    assignments: []const ast.Assignment,
    fd_actions: []const host_mod.SpawnFdAction,
    search_path: ?[]const u8,
) !host_mod.SpawnRequest {
    const argv = try makeExecArgv(shell, fields);
    const command_text = std.mem.span(argv[0].?);
    const command = argv[0].?[0..command_text.len :0];
    const path = try resolveCommandPathWithSearchPath(shell, command, search_path);
    const envp = try makeExecEnvp(shell, assignments);
    return .{
        .path = path,
        .argv = argv,
        .fallback_argv = try makeShellFallbackArgv(shell, path, fields[1..]),
        .envp = envp,
        .fd_actions = fd_actions,
    };
}

fn makeShellFallbackArgv(
    shell: anytype,
    path: [:0]const u8,
    args: []const []const u8,
) ![:null]const ?[*:0]const u8 {
    const allocator = shell.scratchAllocator();
    const argv = try allocator.allocSentinel(?[*:0]const u8, args.len + 2, null);
    argv[0] = default_shell_path.ptr;
    argv[1] = path.ptr;
    for (args, 0..) |arg, index| argv[index + 2] = (try allocator.dupeZ(u8, arg)).ptr;
    return argv;
}

const default_shell_path: [:0]const u8 = "/bin/sh";

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
            .value = try expandAssignmentWordTracking(shell, assignment.value, null),
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
    return resolveCommandPathWithSearchPath(shell, command, null);
}

fn resolveCommandPathWithSearchPath(shell: anytype, command: [:0]const u8, search_path: ?[]const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return command;

    const path = search_path orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
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

fn findCommandPath(shell: anytype, command: []const u8, search_path: ?[]const u8) !?[]const u8 {
    const allocator = shell.scratchAllocator();
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        const command_z = try allocator.dupeZ(u8, command);
        return if (shell.host.isExecutableZ(command_z)) command else null;
    }

    const path = search_path orelse if (shell.state.getVariable("PATH")) |variable| variable.value else envPath(shell.env) orelse defaultUtilityPath();
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
    return null;
}

fn defaultUtilityPath() []const u8 {
    return "/bin:/usr/bin";
}

fn envPath(env: []const [*:0]const u8) ?[]const u8 {
    return envValue(env, "PATH");
}

fn envValue(env: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    for (env) |entry| {
        const text = std.mem.span(entry);
        const equals = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        if (std.mem.eql(u8, text[0..equals], name)) return text[equals + 1 ..];
    }
    return null;
}
