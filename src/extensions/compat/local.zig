//! `local` compatibility extension builtin implementation.

const std = @import("std");

const api = @import("../api.zig");
const command_plan = @import("../../shell/command_plan.zig");
const shell_startup = @import("../../shell/startup.zig");

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "local")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "local"));

    const scope = invocation.function_scope orelse {
        return api.EvaluationResult.normal(try invocation.statusError(
            1,
            "local",
            "can only be used in a function",
        ));
    };
    std.debug.assert(invocation.eval_context.canReturnFromFunction());
    std.debug.assert(scope.depth == invocation.eval_context.function_depth);
    if (invocation.argv.len == 1) return api.EvaluationResult.normal(0);

    for (invocation.argv[1..]) |arg| {
        const assignment = splitAssignment(arg);
        if (!isShellName(assignment.name)) return api.EvaluationResult.normal(try invocation.usageError(
            "local",
            "invalid variable name",
        ));
        if (invocation.shell_state.isVariableReadonly(assignment.name)) {
            return api.EvaluationResult.normal(try invocation.statusError(1, "local", "readonly variable"));
        }
    }

    for (invocation.argv[1..]) |arg| {
        const assignment = splitAssignment(arg);
        try scope.addLocal(assignment.name);
        if (assignment.value) |value| {
            try invocation.state_delta.assignVariable(assignment.name, value, .{});
        } else if (findAssignmentPrefixValue(invocation.assignments, assignment.name)) |value| {
            try invocation.state_delta.assignVariable(assignment.name, value, .{});
        } else {
            try invocation.state_delta.unsetVariable(assignment.name);
        }
    }
    return api.EvaluationResult.normal(0);
}

const AssignmentSlice = struct {
    name: []const u8,
    value: ?[]const u8,
};

fn splitAssignment(arg: []const u8) AssignmentSlice {
    const equals = std.mem.findScalar(u8, arg, '=') orelse return .{ .name = arg, .value = null };
    return .{ .name = arg[0..equals], .value = arg[equals + 1 ..] };
}

fn findAssignmentPrefixValue(assignments: []const command_plan.Assignment, name: []const u8) ?[]const u8 {
    for (assignments) |assignment| {
        if (std.mem.eql(u8, assignment.name, name)) return assignment.value;
    }
    return null;
}

fn isShellName(name: []const u8) bool {
    return shell_startup.isValidVariableName(name);
}
