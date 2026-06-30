//! Direct evaluator for the rewritten shell core.

const std = @import("std");

const ast = @import("ast.zig");
const builtin = @import("builtin.zig");
const result = @import("result.zig");

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
    shell.resetScratch();

    if (command.words.len == 0) {
        try applyAssignments(shell, command.assignments);
        return .{};
    }

    const name = try expandWord(shell, command.words[0]);
    if (builtin.lookup(name)) |definition| {
        if (definition.kind == .special) try applyAssignments(shell, command.assignments);
        const args = if (definition.id == .printf)
            try expandWords(shell, command.words)
        else
            &[_][]const u8{name};
        return builtin.eval(shell, definition, args);
    }
    return .{ .status = 127 };
}

fn applyAssignments(shell: anytype, assignments: []const ast.Assignment) !void {
    for (assignments) |assignment| {
        const value = try expandWord(shell, assignment.value);
        try shell.state.putVariable(.{ .name = assignment.name, .value = value });
    }
}

fn expandWords(shell: anytype, words: []const ast.Word) ![]const []const u8 {
    std.debug.assert(words.len != 0);
    const allocator = shell.scratchAllocator();
    const expanded = try allocator.alloc([]const u8, words.len);
    for (words, 0..) |word, index| expanded[index] = try expandWord(shell, word);
    return expanded;
}

fn expandWord(shell: anytype, word: ast.Word) ![]const u8 {
    return switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| expandWordParts(shell, parts),
    };
}

fn expandWordParts(shell: anytype, parts: []const ast.WordPart) EvalError![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return expandWordPart(shell, parts[0]);

    const allocator = shell.scratchAllocator();
    var output: std.ArrayList(u8) = .empty;
    for (parts) |part| try output.appendSlice(allocator, try expandWordPart(shell, part));
    return output.toOwnedSlice(allocator);
}

fn expandWordPart(shell: anytype, part: ast.WordPart) EvalError![]const u8 {
    return switch (part) {
        .literal, .single_quoted, .arithmetic => |bytes| bytes,
        .double_quoted => |parts| expandWordParts(shell, parts),
        .parameter => |parameter| expandParameter(shell, parameter),
        .command_substitution => error.UnsupportedExpansion,
    };
}

fn expandParameter(shell: anytype, parameter: ast.ParameterExpansion) []const u8 {
    parameter.validate();
    return switch (parameter.parameter) {
        .variable => |name| if (shell.state.getVariable(name)) |variable| variable.value else "",
        .positional, .special => "",
    };
}
