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
    if (command.words.len == 0) return .{};
    shell.resetScratch();
    const name = try expandWord(shell.scratchAllocator(), command.words[0]);
    if (builtin.lookup(name)) |definition| {
        const args = if (definition.id == .printf)
            try expandWords(shell.scratchAllocator(), command.words)
        else
            &[_][]const u8{name};
        return builtin.eval(shell, definition, args);
    }
    return .{ .status = 127 };
}

fn expandWords(allocator: std.mem.Allocator, words: []const ast.Word) ![]const []const u8 {
    std.debug.assert(words.len != 0);
    const expanded = try allocator.alloc([]const u8, words.len);
    for (words, 0..) |word, index| expanded[index] = try expandWord(allocator, word);
    return expanded;
}

fn expandWord(allocator: std.mem.Allocator, word: ast.Word) ![]const u8 {
    return switch (word.data) {
        .literal => |literal| literal,
        .parts => |parts| expandWordParts(allocator, parts),
    };
}

fn expandWordParts(allocator: std.mem.Allocator, parts: []const ast.WordPart) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    for (parts) |part| switch (part) {
        .literal, .single_quoted, .arithmetic => |bytes| try output.appendSlice(allocator, bytes),
        else => return error.UnsupportedExpansion,
    };
    return output.toOwnedSlice(allocator);
}
