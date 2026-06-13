//! Semantic evaluation entry point for the redesigned shell core.
//!
//! Evaluation will consume side-effect-free plans, call runtime ports for host
//! effects when needed, and return `CommandOutcome` data. The old executor stays
//! the behavioral reference while this path grows slice by slice.

const std = @import("std");
const builtin = @import("builtin.zig");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const delta = @import("delta.zig");
const outcome = @import("outcome.zig");
const state = @import("state.zig");

pub const EvalError = std.mem.Allocator.Error || error{
    Unimplemented,
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        return .{ .allocator = allocator };
    }
};

pub fn evaluatePlan(evaluator: *Evaluator, shell_state: *state.ShellState, eval_context: context.EvalContext, plan: command_plan.CommandPlan) EvalError!outcome.CommandOutcome {
    shell_state.validate();
    eval_context.validate();
    plan.validate();
    std.debug.assert(plan.target == eval_context.target);
    if (plan.target.allowsShellStateCommit()) std.debug.assert(shell_state.acceptsExecutionTarget(plan.target));
    if (plan.redirections.steps.len != 0 or plan.redirections.rollback_steps.len != 0) return error.Unimplemented;

    if (delta.firstReadonlyAssignment(shell_state.*, plan.assignments)) |name| {
        var failure = try outcome.readonlyVariableFailure(evaluator.allocator, plan.target, name);
        failure.state_delta.setLastStatus(failure.status);
        failure.validateForContext(eval_context);
        return failure;
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(evaluator.allocator);

    const status = try evaluateSimpleCommand(evaluator.allocator, plan, &stdout);

    var state_delta = delta.StateDelta.init(evaluator.allocator, plan.target);
    errdefer state_delta.deinit();
    if (plan.assignmentEffect() == .persistent) {
        state_delta.appendPersistentCommandAssignments(shell_state.*, plan.assignments) catch |err| switch (err) {
            error.ReadonlyVariable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    state_delta.setLastStatus(status);
    assertNonMutatingBuiltinDelta(plan, state_delta);

    var command_outcome = outcome.CommandOutcome.init(evaluator.allocator, status, state_delta);
    errdefer command_outcome.deinit();
    try command_outcome.appendStdout(stdout.items);
    try appendBuiltinDiagnostic(&command_outcome, plan, status);
    command_outcome.validateForContext(eval_context);
    return command_outcome;
}

fn evaluateSimpleCommand(allocator: std.mem.Allocator, plan: command_plan.CommandPlan, stdout: *std.ArrayList(u8)) EvalError!outcome.ExitStatus {
    return switch (plan.classification) {
        .empty => 0,
        .assignment_only => 0,
        .special_builtin => |definition| evaluateBuiltin(allocator, plan, definition, stdout),
        .regular_builtin => |definition| evaluateBuiltin(allocator, plan, definition, stdout),
        .function, .external, .not_found => error.Unimplemented,
    };
}

fn evaluateBuiltin(allocator: std.mem.Allocator, plan: command_plan.CommandPlan, definition: builtin.Builtin, stdout: *std.ArrayList(u8)) EvalError!outcome.ExitStatus {
    definition.validate();
    if (!definition.isSemanticallyNonMutating()) return error.Unimplemented;
    std.debug.assert(plan.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, plan.argv[0], definition.name));
    switch (plan.classification) {
        .special_builtin => |classified| std.debug.assert(std.mem.eql(u8, classified.name, definition.name) and classified.kind == definition.kind),
        .regular_builtin => |classified| std.debug.assert(std.mem.eql(u8, classified.name, definition.name) and classified.kind == definition.kind),
        else => unreachable,
    }

    if (std.mem.eql(u8, definition.name, ":")) return 0;
    if (std.mem.eql(u8, definition.name, "true")) return 0;
    if (std.mem.eql(u8, definition.name, "false")) return 1;
    if (std.mem.eql(u8, definition.name, "echo")) return evaluateEcho(allocator, plan.argv, stdout);
    if (std.mem.eql(u8, definition.name, "test") or std.mem.eql(u8, definition.name, "[")) return evaluateTestBuiltin(plan.argv);
    return error.Unimplemented;
}

fn appendBuiltinDiagnostic(command_outcome: *outcome.CommandOutcome, plan: command_plan.CommandPlan, status: outcome.ExitStatus) !void {
    if (status != 2 or plan.argv.len == 0) return;
    if (std.mem.eql(u8, plan.argv[0], "[")) {
        const args = plan.argv[1..];
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            try command_outcome.addDiagnostic("[: missing ]");
            return;
        }
        try command_outcome.addDiagnostic("[: invalid expression");
        return;
    }
    if (std.mem.eql(u8, plan.argv[0], "test")) try command_outcome.addDiagnostic("test: invalid expression");
}

fn evaluateEcho(allocator: std.mem.Allocator, argv: []const []const u8, stdout: *std.ArrayList(u8)) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "echo"));

    var first_operand: usize = 1;
    var append_newline = true;
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "-n")) {
        first_operand = 2;
        append_newline = false;
    }

    for (argv[first_operand..], 0..) |arg, index| {
        if (index > 0) try stdout.append(allocator, ' ');
        if (!try appendEchoOperand(allocator, stdout, arg)) {
            append_newline = false;
            break;
        }
    }
    if (append_newline) try stdout.append(allocator, '\n');
    return 0;
}

fn appendEchoOperand(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8) !bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try stdout.append(allocator, text[index]);
            index += 1;
            continue;
        }

        index += 1;
        if (index >= text.len) {
            try stdout.append(allocator, '\\');
            continue;
        }

        switch (text[index]) {
            'a' => try stdout.append(allocator, 0x07),
            'b' => try stdout.append(allocator, 0x08),
            'c' => return false,
            'f' => try stdout.append(allocator, 0x0c),
            'n' => try stdout.append(allocator, '\n'),
            'r' => try stdout.append(allocator, '\r'),
            't' => try stdout.append(allocator, '\t'),
            'v' => try stdout.append(allocator, 0x0b),
            '\\' => try stdout.append(allocator, '\\'),
            '0' => {
                index += 1;
                var value: u16 = 0;
                var count: usize = 0;
                while (index < text.len and count < 3 and text[index] >= '0' and text[index] <= '7') : (count += 1) {
                    value = value * 8 + (text[index] - '0');
                    index += 1;
                }
                try stdout.append(allocator, @intCast(value & 0xff));
                continue;
            },
            else => {
                try stdout.append(allocator, '\\');
                try stdout.append(allocator, text[index]);
            },
        }
        index += 1;
    }
    return true;
}

fn evaluateTestBuiltin(argv: []const []const u8) outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    const is_bracket = std.mem.eql(u8, argv[0], "[");
    const args = argv[1..];
    if (is_bracket) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) return 2;
        const matched = evalTest(args[0 .. args.len - 1]) catch return 2;
        return if (matched) 0 else 1;
    }
    std.debug.assert(std.mem.eql(u8, argv[0], "test"));
    const matched = evalTest(args) catch return 2;
    return if (matched) 0 else 1;
}

const TestExpressionError = error{InvalidTestExpression};

fn evalTest(args: []const []const u8) TestExpressionError!bool {
    if (args.len == 3 and isBinaryTestOperator(args[1])) {
        return evalBinaryTest(args[0], args[1], args[2]);
    }
    if (hasTestExpressionOperator(args)) {
        var test_parser: TestExpressionParser = .{ .args = args };
        const result = try test_parser.parseOr();
        if (test_parser.index != args.len) return error.InvalidTestExpression;
        return result;
    }
    return evalSimpleTest(args);
}

fn evalSimpleTest(args: []const []const u8) TestExpressionError!bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].len != 0,
        2 => evalUnaryTest(args[0], args[1]),
        3 => if (isBinaryTestOperator(args[1]))
            evalBinaryTest(args[0], args[1], args[2])
        else if (std.mem.eql(u8, args[0], "!"))
            !(try evalSimpleTest(args[1..]))
        else
            error.InvalidTestExpression,
        4 => if (std.mem.eql(u8, args[0], "!")) !(try evalSimpleTest(args[1..])) else error.InvalidTestExpression,
        else => error.InvalidTestExpression,
    };
}

fn hasTestExpressionOperator(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "(") or std.mem.eql(u8, arg, ")")) return true;
    }
    return false;
}

const TestExpressionParser = struct {
    args: []const []const u8,
    index: usize = 0,

    fn parseOr(self: *TestExpressionParser) TestExpressionError!bool {
        var result = try self.parseAnd();
        while (self.match("-o")) {
            const rhs = try self.parseAnd();
            result = result or rhs;
        }
        return result;
    }

    fn parseAnd(self: *TestExpressionParser) TestExpressionError!bool {
        var result = try self.parseNot();
        while (self.match("-a")) {
            const rhs = try self.parseNot();
            result = result and rhs;
        }
        return result;
    }

    fn parseNot(self: *TestExpressionParser) TestExpressionError!bool {
        if (self.match("!")) return !(try self.parseNot());
        return self.parsePrimary();
    }

    fn parsePrimary(self: *TestExpressionParser) TestExpressionError!bool {
        if (self.index >= self.args.len) return error.InvalidTestExpression;
        if (self.match("(")) {
            const result = try self.parseOr();
            if (!self.match(")")) return error.InvalidTestExpression;
            return result;
        }
        if (self.index + 2 < self.args.len and isBinaryTestOperator(self.args[self.index + 1])) {
            const left = self.args[self.index];
            const op = self.args[self.index + 1];
            const right = self.args[self.index + 2];
            self.index += 3;
            return evalBinaryTest(left, op, right);
        }
        if (self.index + 1 < self.args.len and isUnaryTestOperator(self.args[self.index])) {
            const op = self.args[self.index];
            const operand = self.args[self.index + 1];
            self.index += 2;
            return evalUnaryTest(op, operand);
        }
        const value = self.args[self.index].len != 0;
        self.index += 1;
        return value;
    }

    fn match(self: *TestExpressionParser, text: []const u8) bool {
        if (self.index >= self.args.len or !std.mem.eql(u8, self.args[self.index], text)) return false;
        self.index += 1;
        return true;
    }
};

fn isUnaryTestOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "!") or std.mem.eql(u8, op, "-n") or std.mem.eql(u8, op, "-z");
}

fn isBinaryTestOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "-eq") or std.mem.eql(u8, op, "-ne") or
        std.mem.eql(u8, op, "-gt") or std.mem.eql(u8, op, "-ge") or std.mem.eql(u8, op, "-lt") or std.mem.eql(u8, op, "-le");
}

fn evalUnaryTest(op: []const u8, operand: []const u8) TestExpressionError!bool {
    if (std.mem.eql(u8, op, "!")) return operand.len == 0;
    if (std.mem.eql(u8, op, "-n")) return operand.len != 0;
    if (std.mem.eql(u8, op, "-z")) return operand.len == 0;
    return error.InvalidTestExpression;
}

fn evalBinaryTest(left: []const u8, op: []const u8, right: []const u8) TestExpressionError!bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "<")) return std.mem.lessThan(u8, left, right);
    if (std.mem.eql(u8, op, ">")) return std.mem.lessThan(u8, right, left);

    const lhs = parseTestInteger(left) orelse return error.InvalidTestExpression;
    const rhs = parseTestInteger(right) orelse return error.InvalidTestExpression;
    if (std.mem.eql(u8, op, "-eq")) return lhs == rhs;
    if (std.mem.eql(u8, op, "-ne")) return lhs != rhs;
    if (std.mem.eql(u8, op, "-gt")) return lhs > rhs;
    if (std.mem.eql(u8, op, "-ge")) return lhs >= rhs;
    if (std.mem.eql(u8, op, "-lt")) return lhs < rhs;
    if (std.mem.eql(u8, op, "-le")) return lhs <= rhs;
    return error.InvalidTestExpression;
}

fn parseTestInteger(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn assertNonMutatingBuiltinDelta(plan: command_plan.CommandPlan, state_delta: delta.StateDelta) void {
    const definition = switch (plan.classification) {
        .special_builtin, .regular_builtin => |definition| definition,
        .empty, .assignment_only => return,
        .function, .external, .not_found => unreachable,
    };
    if (!definition.isSemanticallyNonMutating()) return;

    std.debug.assert(state_delta.variable_flags.items.len == 0);
    std.debug.assert(state_delta.option_changes.items.len == 0);
    std.debug.assert(state_delta.positionals == null);
    std.debug.assert(state_delta.logical_cwd == null);
    std.debug.assert(state_delta.last_status != null);
    if (plan.assignmentEffect() != .persistent) std.debug.assert(state_delta.variable_assignments.items.len == 0);
}

test "semantic evaluator executes colon true and false builtins" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const colon_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{":"} } });
    var colon = try evaluatePlan(&evaluator, &shell_state, eval_context, colon_plan);
    defer colon.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), colon.status);
    try std.testing.expectEqualStrings("", colon.stdout.items);
    try colon.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);

    const true_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"true"} } });
    var true_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, true_plan);
    defer true_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), true_outcome.status);
    try true_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);

    const false_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"false"} } });
    var false_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, false_plan);
    defer false_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), false_outcome.status);
    try false_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 1), shell_state.last_status);
}

test "semantic evaluator captures echo output in CommandOutcome" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const echo_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "echo", "hello", "world" } } });
    var echo_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, echo_plan);
    defer echo_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), echo_outcome.status);
    try std.testing.expectEqualStrings("hello world\n", echo_outcome.stdout.items);
    try std.testing.expect(echo_outcome.state_delta.variable_assignments.items.len == 0);
    try echo_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(state.ExitStatus, 0), shell_state.last_status);

    const escaped_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "echo", "-n", "a\\nb\\c", "ignored" } } });
    var escaped = try evaluatePlan(&evaluator, &shell_state, eval_context, escaped_plan);
    defer escaped.deinit();
    try std.testing.expectEqualStrings("a\nb", escaped.stdout.items);
    escaped.discardDelta(.current_shell);
}

test "semantic evaluator executes string and integer test predicates" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const true_string = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "test", "-n", "value" } } });
    var true_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, true_string);
    defer true_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), true_outcome.status);
    try std.testing.expectEqual(@as(usize, 0), true_outcome.diagnostics.items.len);
    true_outcome.discardDelta(.current_shell);

    const false_integer = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "test", "2", "-gt", "3" } } });
    var false_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, false_integer);
    defer false_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), false_outcome.status);
    false_outcome.discardDelta(.current_shell);

    const bracket_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "[", "a", "=", "a", "]" } } });
    var bracket_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, bracket_plan);
    defer bracket_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), bracket_outcome.status);
    bracket_outcome.discardDelta(.current_shell);

    const invalid_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "[", "a", "=" } } });
    var invalid = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_plan);
    defer invalid.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), invalid.status);
    try std.testing.expectEqualStrings("[: missing ]", invalid.diagnostics.items[0].message);
    invalid.discardDelta(.current_shell);
}

test "semantic evaluator preserves assignment commit behavior around simple builtins" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const assignment_only = [_]command_plan.Assignment{.{ .name = "ONLY", .value = "persistent" }};
    const assignment_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignment_only } });
    var assignment_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, assignment_plan);
    defer assignment_outcome.deinit();
    try assignment_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("persistent", shell_state.getVariable("ONLY").?.value);

    const special_assignments = [_]command_plan.Assignment{.{ .name = "SPECIAL", .value = "persistent" }};
    const special_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &special_assignments, .argv = &[_][]const u8{":"} } });
    var special_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, special_plan);
    defer special_outcome.deinit();
    try special_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("persistent", shell_state.getVariable("SPECIAL").?.value);

    const temporary_assignments = [_]command_plan.Assignment{.{ .name = "TEMP", .value = "discarded" }};
    const regular_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &temporary_assignments, .argv = &[_][]const u8{"echo"} } });
    var regular_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, regular_plan);
    defer regular_outcome.deinit();
    try std.testing.expectEqualStrings("\n", regular_outcome.stdout.items);
    try regular_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("TEMP"));
}

test "semantic evaluator reports unsupported simple builtin execution explicitly" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const printf_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "printf", "%s", "value" } } });
    try std.testing.expectError(error.Unimplemented, evaluatePlan(&evaluator, &shell_state, eval_context, printf_plan));
}
