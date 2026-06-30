//! Direct evaluator for the rewritten shell core.

const std = @import("std");

const ast = @import("ast.zig");
const builtin = @import("builtin.zig");
const result = @import("result.zig");

pub const EvalError = error{};

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
    _ = shell;
    command.validate();
    if (command.words.len == 0) return .{};
    const name = literalWord(command.words[0]) orelse return .{ .status = 2 };
    if (builtin.lookup(name)) |definition| return builtin.eval(definition);
    return .{ .status = 127 };
}

fn literalWord(word: ast.Word) ?[]const u8 {
    return switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| if (parts.len == 1) switch (parts[0]) {
            .literal => |literal| literal,
            else => null,
        } else null,
    };
}
