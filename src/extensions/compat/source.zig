//! `source` compatibility extension builtin implementation.

const std = @import("std");

const api = @import("../api.zig");

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "source")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "source"));

    if (invocation.argv.len < 2) return api.EvaluationResult.normal(try invocation.statusError(
        2,
        "source",
        "missing file operand",
    ));

    const source_evaluator = invocation.source_evaluator orelse return error.Unimplemented;
    return source_evaluator.sourceFileWithArgs("source", invocation.argv[1], invocation.argv[2..]);
}
