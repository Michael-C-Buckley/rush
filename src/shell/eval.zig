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
const runtime = @import("../runtime.zig");
const state = @import("state.zig");

extern "c" fn snprintf(s: [*]u8, n: usize, format: [*:0]const u8, ...) c_int;

pub const EvalError = std.mem.Allocator.Error || error{
    Unimplemented,
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    fd_port: ?runtime.fd.Port = null,
    fs_port: ?runtime.fs.Port = null,

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        return .{ .allocator = allocator };
    }

    pub fn initWithFdPort(allocator: std.mem.Allocator, fd_port: runtime.fd.Port) Evaluator {
        return .{ .allocator = allocator, .fd_port = fd_port };
    }

    pub fn initWithFsPort(allocator: std.mem.Allocator, fs_port: runtime.fs.Port) Evaluator {
        return .{ .allocator = allocator, .fs_port = fs_port };
    }
};

const EvaluationBuffers = struct {
    allocator: std.mem.Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    diagnostics: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) EvaluationBuffers {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *EvaluationBuffers) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
        for (self.diagnostics.items) |message| self.allocator.free(message);
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    fn addBuiltinDiagnostic(self: *EvaluationBuffers, command: []const u8, message: []const u8) !void {
        std.debug.assert(command.len != 0);
        std.debug.assert(message.len != 0);

        try self.stderr.print(self.allocator, "{s}: {s}\n", .{ command, message });
        const diagnostic = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ command, message });
        errdefer self.allocator.free(diagnostic);
        try self.diagnostics.append(self.allocator, diagnostic);
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

    var state_delta = delta.StateDelta.init(evaluator.allocator, plan.target);
    errdefer state_delta.deinit();
    if (plan.assignmentEffect() == .persistent) {
        state_delta.appendPersistentCommandAssignments(shell_state.*, plan.assignments) catch |err| switch (err) {
            error.ReadonlyVariable => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    var buffers = EvaluationBuffers.init(evaluator.allocator);
    defer buffers.deinit();

    const status = try evaluateSimpleCommand(evaluator, shell_state.*, eval_context, plan, &state_delta, &buffers);
    state_delta.setLastStatus(status);
    assertBuiltinDeltaCompatible(plan, state_delta);

    var command_outcome = outcome.CommandOutcome.init(evaluator.allocator, status, state_delta);
    errdefer command_outcome.deinit();
    try command_outcome.appendStdout(buffers.stdout.items);
    try command_outcome.appendStderr(buffers.stderr.items);
    for (buffers.diagnostics.items) |message| try command_outcome.addDiagnostic(message);
    try appendBuiltinDiagnostic(&command_outcome, plan, status);
    command_outcome.validateForContext(eval_context);
    return command_outcome;
}

fn evaluateSimpleCommand(evaluator: *Evaluator, shell_state: state.ShellState, eval_context: context.EvalContext, plan: command_plan.CommandPlan, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) EvalError!outcome.ExitStatus {
    return switch (plan.classification) {
        .empty => 0,
        .assignment_only => 0,
        .special_builtin => |definition| evaluateBuiltin(evaluator, shell_state, eval_context, plan, definition, state_delta, buffers),
        .regular_builtin => |definition| evaluateBuiltin(evaluator, shell_state, eval_context, plan, definition, state_delta, buffers),
        .function, .external, .not_found => error.Unimplemented,
    };
}

fn evaluateBuiltin(evaluator: *Evaluator, shell_state: state.ShellState, eval_context: context.EvalContext, plan: command_plan.CommandPlan, definition: builtin.Builtin, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) EvalError!outcome.ExitStatus {
    definition.validate();
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
    if (std.mem.eql(u8, definition.name, "echo")) return evaluateEcho(evaluator.allocator, plan.argv, &buffers.stdout);
    if (std.mem.eql(u8, definition.name, "printf")) return evaluatePrintf(evaluator.allocator, plan.argv, &buffers.stdout, &buffers.stderr);
    if (std.mem.eql(u8, definition.name, "test") or std.mem.eql(u8, definition.name, "[")) return evaluateTestBuiltin(evaluator.fs_port, evaluator.fd_port, plan.argv);
    if (std.mem.eql(u8, definition.name, "export")) return evaluateExport(shell_state, plan.argv, state_delta, buffers);
    if (std.mem.eql(u8, definition.name, "readonly")) return evaluateReadonly(shell_state, plan.argv, state_delta, buffers);
    if (std.mem.eql(u8, definition.name, "unset")) return evaluateUnset(shell_state, plan.argv, state_delta, buffers);
    if (std.mem.eql(u8, definition.name, "set")) return evaluateSet(shell_state, eval_context, plan.argv, state_delta, buffers);
    if (std.mem.eql(u8, definition.name, "shift")) return evaluateShift(shell_state, plan.argv, state_delta, buffers);
    if (std.mem.eql(u8, definition.name, "alias")) return evaluateAlias(shell_state, plan.argv, state_delta, buffers);
    if (std.mem.eql(u8, definition.name, "unalias")) return evaluateUnalias(shell_state, plan.argv, state_delta, buffers);
    if (std.mem.eql(u8, definition.name, "trap")) return evaluateTrap(evaluator.allocator, shell_state, plan.argv, state_delta, buffers);
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

fn evaluateExport(shell_state: state.ShellState, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "export"));

    var index: usize = 1;
    const option_terminated = index < argv.len and std.mem.eql(u8, argv[index], "--");
    if (option_terminated) index += 1;
    if (index >= argv.len) return listVariableDeclarations(shell_state, state_delta.*, buffers, .exported, "export");
    if (!option_terminated and std.mem.eql(u8, argv[index], "-p")) {
        if (argv.len != index + 1) return builtinUsageError(buffers, "export", "too many arguments");
        return listVariableDeclarations(shell_state, state_delta.*, buffers, .exported, "export");
    }
    if (!option_terminated and std.mem.startsWith(u8, argv[index], "-") and !std.mem.eql(u8, argv[index], "-")) return builtinUsageError(buffers, "export", "unsupported option");

    for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        const name = assignment.name;
        if (!isShellName(name)) return builtinUsageError(buffers, "export", "invalid variable name");
        if (assignment.value) |_| {
            if (shell_state.isVariableReadonly(name)) return builtinUsageError(buffers, "export", "readonly variable");
        }
    }

    for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        if (assignment.value) |value| {
            try state_delta.assignVariable(assignment.name, value, .{ .exported = true });
        } else {
            try state_delta.setVariableExported(assignment.name, true);
        }
    }
    return 0;
}

fn evaluateReadonly(shell_state: state.ShellState, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "readonly"));

    var index: usize = 1;
    const option_terminated = index < argv.len and std.mem.eql(u8, argv[index], "--");
    if (option_terminated) index += 1;
    if (index >= argv.len) return listVariableDeclarations(shell_state, state_delta.*, buffers, .readonly, "readonly");
    if (!option_terminated and std.mem.eql(u8, argv[index], "-p")) {
        if (argv.len != index + 1) return builtinUsageError(buffers, "readonly", "too many arguments");
        return listVariableDeclarations(shell_state, state_delta.*, buffers, .readonly, "readonly");
    }
    if (!option_terminated and std.mem.startsWith(u8, argv[index], "-") and !std.mem.eql(u8, argv[index], "-")) return builtinUsageError(buffers, "readonly", "unsupported option");

    var declared_readonly: std.ArrayList([]const u8) = .empty;
    defer declared_readonly.deinit(buffers.allocator);
    for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        const name = assignment.name;
        if (!isShellName(name)) return builtinUsageError(buffers, "readonly", "invalid variable name");
        if (assignment.value != null and (shell_state.isVariableReadonly(name) or containsString(declared_readonly.items, name))) return builtinUsageError(buffers, "readonly", "readonly variable");
        try declared_readonly.append(buffers.allocator, name);
    }

    for (argv[index..]) |arg| {
        const assignment = splitAssignment(arg);
        if (assignment.value) |value| {
            try state_delta.assignVariable(assignment.name, value, .{ .readonly = true });
        } else {
            try state_delta.setVariableReadonly(assignment.name);
        }
    }
    return 0;
}

fn evaluateUnset(shell_state: state.ShellState, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "unset"));

    var mode: enum { variable, function } = .variable;
    var index: usize = 1;
    while (index < argv.len) {
        const option = argv[index];
        if (std.mem.eql(u8, option, "--")) {
            index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-v")) {
            mode = .variable;
            index += 1;
        } else if (std.mem.eql(u8, option, "-f")) {
            mode = .function;
            index += 1;
        } else if (std.mem.startsWith(u8, option, "-") and !std.mem.eql(u8, option, "-")) {
            return builtinUsageError(buffers, "unset", "unsupported option");
        } else {
            break;
        }
    }

    for (argv[index..]) |arg| {
        if (!isShellName(arg)) return builtinUsageError(buffers, "unset", "invalid variable name");
        if (mode == .variable and shell_state.isVariableReadonly(arg)) return builtinUsageError(buffers, "unset", "readonly variable");
    }

    for (argv[index..]) |arg| switch (mode) {
        .variable => try state_delta.unsetVariable(arg),
        .function => try state_delta.unsetFunction(arg),
    };
    return 0;
}

fn evaluateSet(shell_state: state.ShellState, eval_context: context.EvalContext, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "set"));

    if (argv.len == 1) return listShellVariables(shell_state, state_delta.*, buffers);

    var index: usize = 1;
    var set_positionals = false;
    while (index < argv.len) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            set_positionals = true;
            break;
        }
        if (std.mem.eql(u8, arg, "-")) {
            try state_delta.setOption(.xtrace, false);
            try state_delta.setOption(.verbose, false);
            index += 1;
            set_positionals = index < argv.len;
            break;
        }
        if (std.mem.eql(u8, arg, "+")) {
            index += 1;
            set_positionals = index < argv.len;
            break;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "+o")) {
            if (index + 1 == argv.len) return printShellOptions(shell_state, state_delta.*, buffers, arg[0] == '+');
            const enabled = arg[0] == '-';
            index += 1;
            if (!try appendShellOptionNameChange(state_delta, argv[index], enabled)) return builtinUsageError(buffers, "set", "unknown option name");
            if (eval_context.interactive) try state_delta.setOption(.noexec, false);
            index += 1;
            continue;
        }
        if (arg.len >= 2 and (arg[0] == '-' or arg[0] == '+')) {
            if (!try appendShellOptionShortChanges(state_delta, arg)) return builtinUsageError(buffers, "set", "unsupported arguments");
            if (eval_context.interactive) try state_delta.setOption(.noexec, false);
            index += 1;
            continue;
        }

        set_positionals = true;
        break;
    }

    if (set_positionals) try state_delta.replacePositionals(argv[index..]);
    return 0;
}

fn evaluateShift(shell_state: state.ShellState, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "shift"));

    const amount: usize = if (argv.len == 1) 1 else blk: {
        if (argv.len > 2) return builtinUsageError(buffers, "shift", "too many arguments");
        const operand = std.mem.trim(u8, argv[1], &std.ascii.whitespace);
        break :blk std.fmt.parseInt(usize, operand, 10) catch return builtinUsageError(buffers, "shift", "numeric argument required");
    };
    if (amount > shell_state.positionals.items.len) return builtinStatusError(buffers, 1, "shift", "shift count out of range");
    try state_delta.replacePositionals(shell_state.positionals.items[amount..]);
    return 0;
}

fn evaluateAlias(shell_state: state.ShellState, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "alias"));

    if (argv.len == 1) return listAliases(shell_state, state_delta.*, buffers);

    var preview_delta = try state_delta.clone(buffers.allocator);
    defer preview_delta.deinit();
    for (argv[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |equals| {
            const name = arg[0..equals];
            if (!isAliasName(name)) return builtinUsageError(buffers, "alias", "invalid alias name");
            try preview_delta.setAlias(name, arg[equals + 1 ..]);
        } else {
            if (!isAliasName(arg)) return builtinUsageError(buffers, "alias", "invalid alias name");
            if (lookupAliasValue(shell_state, preview_delta, arg) == null) return builtinStatusError(buffers, 1, "alias", "not found");
        }
    }

    for (argv[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |equals| {
            try state_delta.setAlias(arg[0..equals], arg[equals + 1 ..]);
        } else {
            const value = lookupAliasValue(shell_state, state_delta.*, arg).?;
            try buffers.stdout.print(buffers.allocator, "{s}=", .{arg});
            try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, value);
            try buffers.stdout.append(buffers.allocator, '\n');
        }
    }
    return 0;
}

fn evaluateUnalias(shell_state: state.ShellState, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "unalias"));

    if (argv.len == 1) return builtinUsageError(buffers, "unalias", "missing operand");
    var index: usize = 1;
    const option_terminated = std.mem.eql(u8, argv[index], "--");
    if (option_terminated) index += 1;
    if (index >= argv.len) return builtinUsageError(buffers, "unalias", "missing operand");
    if (!option_terminated and std.mem.startsWith(u8, argv[index], "-") and !std.mem.eql(u8, argv[index], "-a")) return builtinUsageError(buffers, "unalias", "unsupported option");
    var clear_requested = false;
    if (!option_terminated and std.mem.eql(u8, argv[index], "-a")) {
        clear_requested = true;
        index += 1;
        if (index == argv.len) {
            state_delta.clearAliases();
            return 0;
        }
    }

    var preview_delta = try state_delta.clone(buffers.allocator);
    defer preview_delta.deinit();
    if (clear_requested) preview_delta.clearAliases();
    for (argv[index..]) |arg| {
        if (!isAliasName(arg)) return builtinUsageError(buffers, "unalias", "invalid alias name");
        if (lookupAliasValue(shell_state, preview_delta, arg) == null) return builtinStatusError(buffers, 1, "unalias", "not found");
        try preview_delta.unsetAlias(arg);
    }
    if (clear_requested) state_delta.clearAliases();
    for (argv[index..]) |arg| try state_delta.unsetAlias(arg);
    return 0;
}

fn evaluateTrap(allocator: std.mem.Allocator, shell_state: state.ShellState, argv: []const []const u8, state_delta: *delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "trap"));

    if (argv.len == 1) return listTraps(shell_state, buffers);

    var index: usize = 1;
    var print = false;
    while (index < argv.len) {
        const option = argv[index];
        if (std.mem.eql(u8, option, "--")) {
            index += 1;
            break;
        } else if (std.mem.eql(u8, option, "-p")) {
            print = true;
            index += 1;
        } else {
            break;
        }
    }
    if (print) {
        if (index >= argv.len) return listTraps(shell_state, buffers);
        return listTrapOperands(allocator, shell_state, argv[index..], buffers);
    }
    if (index >= argv.len) return listTraps(shell_state, buffers);

    const action = argv[index];
    if (index + 1 >= argv.len) return builtinUsageError(buffers, "trap", "missing signal");
    for (argv[index + 1 ..]) |raw_signal| {
        const name = try normalizeTrapName(allocator, raw_signal);
        defer allocator.free(name);
        if (!state.isValidTrapName(name)) {
            const message = try std.fmt.allocPrint(allocator, "{s}: invalid signal specification", .{raw_signal});
            defer allocator.free(message);
            return builtinStatusError(buffers, 1, "trap", message);
        }
    }
    for (argv[index + 1 ..]) |raw_signal| {
        const name = try normalizeTrapName(allocator, raw_signal);
        defer allocator.free(name);
        try state_delta.setTrap(name, if (std.mem.eql(u8, action, "-")) null else action);
    }
    return 0;
}

fn builtinUsageError(buffers: *EvaluationBuffers, command: []const u8, message: []const u8) !outcome.ExitStatus {
    return builtinStatusError(buffers, 2, command, message);
}

fn builtinStatusError(buffers: *EvaluationBuffers, status: outcome.ExitStatus, command: []const u8, message: []const u8) !outcome.ExitStatus {
    std.debug.assert(status != 0);
    try buffers.addBuiltinDiagnostic(command, message);
    return status;
}

const AssignmentSlice = struct {
    name: []const u8,
    value: ?[]const u8,
};

fn splitAssignment(arg: []const u8) AssignmentSlice {
    if (std.mem.indexOfScalar(u8, arg, '=')) |equals| return .{ .name = arg[0..equals], .value = arg[equals + 1 ..] };
    return .{ .name = arg, .value = null };
}

fn isShellName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

fn isAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '!' or byte == '%' or byte == ',' or byte == '-' or byte == '@' or byte == '_')) return false;
    }
    return true;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

const VariableDeclarationMode = enum { exported, readonly };

fn listVariableDeclarations(shell_state: state.ShellState, state_delta: delta.StateDelta, buffers: *EvaluationBuffers, mode: VariableDeclarationMode, command: []const u8) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    try collectVariableNames(shell_state, state_delta, buffers.allocator, &names);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const variable = lookupVariable(shell_state, state_delta, name) orelse continue;
        const include = switch (mode) {
            .exported => variable.exported,
            .readonly => variable.readonly,
        };
        if (!include) continue;
        try buffers.stdout.print(buffers.allocator, "{s} {s}", .{ command, name });
        try buffers.stdout.append(buffers.allocator, '=');
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, variable.value);
        try buffers.stdout.append(buffers.allocator, '\n');
    }
    return 0;
}

fn listShellVariables(shell_state: state.ShellState, state_delta: delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    try collectVariableNames(shell_state, state_delta, buffers.allocator, &names);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const variable = lookupVariable(shell_state, state_delta, name) orelse continue;
        try buffers.stdout.print(buffers.allocator, "{s}=", .{name});
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, variable.value);
        try buffers.stdout.append(buffers.allocator, '\n');
    }
    return 0;
}

fn collectVariableNames(shell_state: state.ShellState, state_delta: delta.StateDelta, allocator: std.mem.Allocator, names: *std.ArrayList([]const u8)) !void {
    var variables = shell_state.variables.iterator();
    while (variables.next()) |entry| try appendUniqueString(names, allocator, entry.key_ptr.*);
    for (state_delta.variable_assignments.items) |assignment| try appendUniqueString(names, allocator, assignment.name);
}

fn lookupVariable(shell_state: state.ShellState, state_delta: delta.StateDelta, name: []const u8) ?state.Variable {
    for (state_delta.variable_unsets.items) |unset_name| if (std.mem.eql(u8, unset_name, name)) return null;
    var variable = shell_state.getVariable(name) orelse state.Variable{ .value = "" };
    for (state_delta.variable_assignments.items) |assignment| {
        if (!std.mem.eql(u8, assignment.name, name)) continue;
        variable.value = assignment.value;
        if (assignment.exported) |exported| variable.exported = exported;
        variable.readonly = variable.readonly or assignment.readonly;
    }
    for (state_delta.variable_flags.items) |mutation| {
        if (!std.mem.eql(u8, mutation.name, name)) continue;
        switch (mutation.flag) {
            .exported => variable.exported = mutation.enabled,
            .readonly => variable.readonly = true,
        }
    }
    return variable;
}

const OptionSpec = struct {
    name: []const u8,
    option: state.ShellOption,
};

const option_specs = [_]OptionSpec{
    .{ .name = "allexport", .option = .allexport },
    .{ .name = "emacs", .option = .emacs },
    .{ .name = "errexit", .option = .errexit },
    .{ .name = "ignoreeof", .option = .ignoreeof },
    .{ .name = "monitor", .option = .monitor },
    .{ .name = "noclobber", .option = .noclobber },
    .{ .name = "noexec", .option = .noexec },
    .{ .name = "noglob", .option = .noglob },
    .{ .name = "notify", .option = .notify },
    .{ .name = "nounset", .option = .nounset },
    .{ .name = "pipefail", .option = .pipefail },
    .{ .name = "vi", .option = .vi },
    .{ .name = "verbose", .option = .verbose },
    .{ .name = "xtrace", .option = .xtrace },
};

fn printShellOptions(shell_state: state.ShellState, state_delta: delta.StateDelta, buffers: *EvaluationBuffers, reusable: bool) !outcome.ExitStatus {
    for (option_specs) |spec| {
        const enabled = optionEnabled(shell_state, state_delta, spec.option);
        if (reusable) {
            try buffers.stdout.print(buffers.allocator, "set {s}o {s}\n", .{ if (enabled) "-" else "+", spec.name });
        } else {
            try buffers.stdout.print(buffers.allocator, "{s}\t{s}\n", .{ spec.name, if (enabled) "on" else "off" });
        }
    }
    return 0;
}

fn appendShellOptionNameChange(state_delta: *delta.StateDelta, name: []const u8, enabled: bool) !bool {
    if (std.mem.eql(u8, name, "nolog")) return true;
    for (option_specs) |spec| {
        if (!std.mem.eql(u8, spec.name, name)) continue;
        try state_delta.setOption(spec.option, enabled);
        return true;
    }
    return false;
}

fn appendShellOptionShortChanges(state_delta: *delta.StateDelta, spelling: []const u8) !bool {
    if (spelling.len < 2) return false;
    if (spelling[0] != '-' and spelling[0] != '+') return false;
    for (spelling[1..]) |option| switch (option) {
        'a', 'b', 'e', 'f', 'h', 'm', 'n', 'u', 'x', 'v', 'C' => {},
        else => return false,
    };

    const enabled = spelling[0] == '-';
    for (spelling[1..]) |option| switch (option) {
        'a' => try state_delta.setOption(.allexport, enabled),
        'b' => try state_delta.setOption(.notify, enabled),
        'e' => try state_delta.setOption(.errexit, enabled),
        'f' => try state_delta.setOption(.noglob, enabled),
        'h' => {},
        'm' => try state_delta.setOption(.monitor, enabled),
        'n' => try state_delta.setOption(.noexec, enabled),
        'u' => try state_delta.setOption(.nounset, enabled),
        'x' => try state_delta.setOption(.xtrace, enabled),
        'v' => try state_delta.setOption(.verbose, enabled),
        'C' => try state_delta.setOption(.noclobber, enabled),
        else => unreachable,
    };
    return true;
}

fn optionEnabled(shell_state: state.ShellState, state_delta: delta.StateDelta, option: state.ShellOption) bool {
    var enabled = shell_state.options.enabled(option);
    for (state_delta.option_changes.items) |change| {
        if (change.option == option) enabled = change.enabled;
    }
    if (option == .emacs) {
        for (state_delta.option_changes.items) |change| {
            if (change.option == .vi and change.enabled) enabled = false;
        }
    } else if (option == .vi) {
        for (state_delta.option_changes.items) |change| {
            if (change.option == .emacs and change.enabled) enabled = false;
        }
    }
    return enabled;
}

fn listAliases(shell_state: state.ShellState, state_delta: delta.StateDelta, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    var aliases = shell_state.aliases.iterator();
    while (aliases.next()) |entry| try appendUniqueString(&names, buffers.allocator, entry.key_ptr.*);
    for (state_delta.alias_sets.items) |mutation| try appendUniqueString(&names, buffers.allocator, mutation.name);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| {
        const value = lookupAliasValue(shell_state, state_delta, name) orelse continue;
        try buffers.stdout.print(buffers.allocator, "{s}=", .{name});
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, value);
        try buffers.stdout.append(buffers.allocator, '\n');
    }
    return 0;
}

fn lookupAliasValue(shell_state: state.ShellState, state_delta: delta.StateDelta, name: []const u8) ?[]const u8 {
    if (state_delta.clear_aliases) return lookupAliasSetValue(state_delta, name);
    for (state_delta.alias_unsets.items) |unset_name| if (std.mem.eql(u8, unset_name, name)) return null;
    return lookupAliasSetValue(state_delta, name) orelse if (shell_state.getAlias(name)) |alias| alias.value else null;
}

fn lookupAliasSetValue(state_delta: delta.StateDelta, name: []const u8) ?[]const u8 {
    for (state_delta.alias_sets.items) |mutation| if (std.mem.eql(u8, mutation.name, name)) return mutation.value;
    return null;
}

fn listTraps(shell_state: state.ShellState, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(buffers.allocator);
    var traps = shell_state.traps.iterator();
    while (traps.next()) |entry| try names.append(buffers.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    for (names.items) |name| try appendTrapLine(shell_state, buffers, name, false);
    return 0;
}

fn listTrapOperands(allocator: std.mem.Allocator, shell_state: state.ShellState, signal_words: []const []const u8, buffers: *EvaluationBuffers) !outcome.ExitStatus {
    for (signal_words) |raw_signal| {
        const name = try normalizeTrapName(allocator, raw_signal);
        defer allocator.free(name);
        if (!state.isValidTrapName(name)) {
            const message = try std.fmt.allocPrint(allocator, "{s}: invalid signal specification", .{raw_signal});
            defer allocator.free(message);
            return builtinStatusError(buffers, 1, "trap", message);
        }
        try appendTrapLine(shell_state, buffers, name, true);
    }
    return 0;
}

fn appendTrapLine(shell_state: state.ShellState, buffers: *EvaluationBuffers, name: []const u8, print_unset: bool) !void {
    if (shell_state.getTrap(name)) |trap| {
        try buffers.stdout.appendSlice(buffers.allocator, "trap -- ");
        try appendShellSingleQuoted(buffers.allocator, &buffers.stdout, trap.action);
        try buffers.stdout.print(buffers.allocator, " {s}\n", .{name});
    } else if (print_unset) {
        try buffers.stdout.print(buffers.allocator, "trap -- - {s}\n", .{name});
    }
}

fn normalizeTrapName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.eql(u8, raw, "0")) return allocator.dupe(u8, "EXIT");
    if (parseTrapSignalNumber(raw)) |name| return allocator.dupe(u8, name);
    const start: usize = if (std.ascii.startsWithIgnoreCase(raw, "SIG") and raw.len > 3) 3 else 0;
    if (start >= raw.len) return allocator.dupe(u8, raw);
    const name = try allocator.alloc(u8, raw.len - start);
    for (raw[start..], 0..) |byte, index| name[index] = std.ascii.toUpper(byte);
    return name;
}

fn parseTrapSignalNumber(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;
    for (raw) |byte| if (!std.ascii.isDigit(byte)) return null;
    const number = std.fmt.parseInt(u8, raw, 10) catch return null;
    return switch (number) {
        1 => "HUP",
        2 => "INT",
        3 => "QUIT",
        10 => "USR1",
        12 => "USR2",
        15 => "TERM",
        else => null,
    };
}

fn appendUniqueString(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try list.append(allocator, value);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn appendShellSingleQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
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

fn evaluatePrintf(allocator: std.mem.Allocator, argv: []const []const u8, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8)) !outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "printf"));

    var format_index: usize = 1;
    if (format_index < argv.len and std.mem.eql(u8, argv[format_index], "--")) format_index += 1;
    if (format_index >= argv.len) {
        var status: outcome.ExitStatus = 2;
        try printfDiagnostic(allocator, stderr, &status, "missing format operand");
        return status;
    }

    var status: outcome.ExitStatus = 0;
    var stderr_before_stdout = false;
    try appendPrintfOutput(allocator, stdout, stderr, &status, &stderr_before_stdout, argv[format_index], argv[format_index + 1 ..]);
    return status;
}

const PrintfSpec = struct {
    spec: u8,
    argument: ?usize = null,
    left_adjust: bool = false,
    zero_pad: bool = false,
    sign_plus: bool = false,
    sign_space: bool = false,
    alternate: bool = false,
    width_from_argument: bool = false,
    width: ?usize = null,
    precision_from_argument: bool = false,
    precision: ?usize = null,
};

const PrintfIntegerBase = enum { decimal, octal, lower_hex, upper_hex };

const PrintfArgumentMode = enum { none, numbered, unnumbered };

fn appendPrintfOutput(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, stderr_before_stdout: *bool, format: []const u8, args: []const []const u8) !void {
    const argument_mode = analyzePrintfFormat(format) catch |err| switch (err) {
        error.MixedArguments => {
            try printfDiagnostic(allocator, stderr, status, "invalid format");
            return;
        },
    };

    var arg_index: usize = 0;
    var numbered_base: usize = 0;
    var first_pass = true;
    while (first_pass or switch (argument_mode) {
        .numbered => numbered_base < args.len,
        .none, .unnumbered => arg_index < args.len,
    }) {
        first_pass = false;
        const before = if (argument_mode == .numbered) numbered_base else arg_index;
        var pass_max_numbered_argument: usize = 0;
        var index: usize = 0;
        while (index < format.len) {
            switch (format[index]) {
                '\\' => {
                    index += 1;
                    if (index >= format.len) {
                        try stdout.append(allocator, '\\');
                    } else {
                        _ = try appendEscapedSequence(allocator, stdout, format, &index, .format);
                    }
                },
                '%' => {
                    index += 1;
                    if (index >= format.len) {
                        try printfDiagnostic(allocator, stderr, status, "invalid format");
                        break;
                    }
                    const spec = parsePrintfSpec(format, &index) orelse {
                        try printfDiagnostic(allocator, stderr, status, "invalid format");
                        continue;
                    };
                    if (spec.spec == '%') {
                        if (spec.width_from_argument or spec.precision_from_argument) {
                            try printfDiagnostic(allocator, stderr, status, "invalid format");
                            continue;
                        }
                        try stdout.append(allocator, '%');
                        continue;
                    }
                    const resolved_spec = try resolvePrintfDynamicSpec(allocator, stderr, status, stderr_before_stdout, spec, args, &arg_index);
                    const arg = if (spec.argument) |argument_number| blk: {
                        pass_max_numbered_argument = @max(pass_max_numbered_argument, argument_number);
                        const offset = std.math.add(usize, numbered_base, argument_number - 1) catch {
                            try printfDiagnostic(allocator, stderr, status, "missing argument");
                            return;
                        };
                        if (offset >= args.len) {
                            try printfDiagnostic(allocator, stderr, status, "missing argument");
                            return;
                        }
                        break :blk args[offset];
                    } else if (arg_index < args.len) blk: {
                        const value = args[arg_index];
                        arg_index += 1;
                        break :blk value;
                    } else "";
                    if (!try appendPrintfConversion(allocator, stdout, stderr, status, stderr_before_stdout, resolved_spec, arg)) return;
                },
                else => {
                    try stdout.append(allocator, format[index]);
                    index += 1;
                },
            }
        }
        if (argument_mode == .numbered) {
            if (pass_max_numbered_argument == 0) break;
            numbered_base = std.math.add(usize, numbered_base, pass_max_numbered_argument) catch {
                try printfDiagnostic(allocator, stderr, status, "missing argument");
                return;
            };
            if (numbered_base == before) break;
        } else if (arg_index == before) break;
    }
}

fn analyzePrintfFormat(format: []const u8) error{MixedArguments}!PrintfArgumentMode {
    var result: PrintfArgumentMode = .none;
    var index: usize = 0;
    while (index < format.len) {
        switch (format[index]) {
            '\\' => {
                index += 1;
                if (index < format.len) skipPrintfFormatEscape(format, &index);
            },
            '%' => {
                index += 1;
                if (index >= format.len) return result;
                const spec = parsePrintfSpec(format, &index) orelse return result;
                if (spec.spec == '%') continue;
                if (spec.width_from_argument or spec.precision_from_argument) {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
                if (spec.argument != null) {
                    if (result == .unnumbered) return error.MixedArguments;
                    result = .numbered;
                } else {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
            },
            else => index += 1,
        }
    }
    return result;
}

fn skipPrintfFormatEscape(format: []const u8, index: *usize) void {
    switch (format[index.*]) {
        'a', 'b', 'f', 'n', 'r', 't', 'v', '\\' => index.* += 1,
        'x' => {
            index.* += 1;
            var count: usize = 0;
            while (index.* < format.len and count < 2) : (count += 1) {
                _ = std.fmt.charToDigit(format[index.*], 16) catch break;
                index.* += 1;
            }
        },
        '0'...'7' => {
            var count: usize = 0;
            while (index.* < format.len and count < 3 and format[index.*] >= '0' and format[index.*] <= '7') : (count += 1) {
                index.* += 1;
            }
        },
        else => {},
    }
}

fn printfDiagnostic(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, message: []const u8) !void {
    status.* = if (status.* == 2) 2 else 1;
    try stderr.appendSlice(allocator, "printf: ");
    try stderr.appendSlice(allocator, message);
    try stderr.append(allocator, '\n');
}

fn printfNumericDiagnostic(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, stderr_before_stdout: *bool) !void {
    stderr_before_stdout.* = true;
    try printfDiagnostic(allocator, stderr, status, "numeric argument required");
}

fn resolvePrintfDynamicSpec(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, stderr_before_stdout: *bool, spec: PrintfSpec, args: []const []const u8, arg_index: *usize) !PrintfSpec {
    var result = spec;
    if (result.width_from_argument) {
        const value = try parsePrintfSigned(allocator, stderr, status, stderr_before_stdout, nextPrintfArgument(args, arg_index));
        applyPrintfDynamicWidth(&result, value);
    }
    if (result.precision_from_argument) {
        const value = try parsePrintfSigned(allocator, stderr, status, stderr_before_stdout, nextPrintfArgument(args, arg_index));
        result.precision = if (value < 0) null else printfDynamicMagnitude(value);
    }
    result.width_from_argument = false;
    result.precision_from_argument = false;
    return result;
}

fn nextPrintfArgument(args: []const []const u8, arg_index: *usize) []const u8 {
    if (arg_index.* >= args.len) return "";
    const value = args[arg_index.*];
    arg_index.* += 1;
    return value;
}

fn applyPrintfDynamicWidth(spec: *PrintfSpec, value: i64) void {
    if (value < 0) {
        spec.left_adjust = true;
    }
    spec.width = printfDynamicMagnitude(value);
}

fn printfDynamicMagnitude(value: i64) usize {
    const magnitude: u64 = if (value < 0) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    return std.math.cast(usize, magnitude) orelse std.math.maxInt(usize);
}

fn parsePrintfSpec(format: []const u8, index: *usize) ?PrintfSpec {
    var result: PrintfSpec = .{ .spec = 0 };
    if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        if (index.* < format.len and format[index.*] == '$') {
            const argument_number = std.fmt.parseInt(usize, format[start..index.*], 10) catch return null;
            if (argument_number == 0) return null;
            result.argument = argument_number;
            index.* += 1;
        } else {
            index.* = start;
        }
    }
    while (index.* < format.len) {
        switch (format[index.*]) {
            '-' => result.left_adjust = true,
            '0' => result.zero_pad = true,
            '+' => result.sign_plus = true,
            ' ' => result.sign_space = true,
            '#' => result.alternate = true,
            else => break,
        }
        index.* += 1;
    }
    if (index.* < format.len and format[index.*] == '*') {
        result.width_from_argument = true;
        index.* += 1;
    } else if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        result.width = std.fmt.parseInt(usize, format[start..index.*], 10) catch null;
    }
    if (index.* < format.len and format[index.*] == '.') {
        index.* += 1;
        const start = index.*;
        if (index.* < format.len and format[index.*] == '*') {
            result.precision_from_argument = true;
            index.* += 1;
        } else {
            while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
            result.precision = if (start == index.*) 0 else std.fmt.parseInt(usize, format[start..index.*], 10) catch 0;
        }
    }
    if (index.* >= format.len) return null;
    result.spec = format[index.*];
    index.* += 1;
    return result;
}

fn appendPrintfConversion(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, stderr_before_stdout: *bool, spec: PrintfSpec, arg: []const u8) !bool {
    if (isPrintfFloatSpec(spec.spec)) {
        try appendPrintfFloatConversion(allocator, stdout, stderr, status, spec, arg);
        return true;
    }

    switch (spec.spec) {
        'd', 'i' => {
            const rendered = try formatPrintfSignedInteger(allocator, spec, try parsePrintfSigned(allocator, stderr, status, stderr_before_stdout, arg));
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'u' => {
            const rendered = try formatPrintfUnsignedInteger(allocator, spec, try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg), .decimal);
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'o' => {
            const rendered = try formatPrintfUnsignedInteger(allocator, spec, try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg), .octal);
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'x' => {
            const rendered = try formatPrintfUnsignedInteger(allocator, spec, try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg), .lower_hex);
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        'X' => {
            const rendered = try formatPrintfUnsignedInteger(allocator, spec, try parsePrintfUnsigned(allocator, stderr, status, stderr_before_stdout, arg), .upper_hex);
            defer allocator.free(rendered);
            try stdout.appendSlice(allocator, rendered);
            return true;
        },
        else => {},
    }

    if (spec.spec == 'b') {
        var escaped: std.ArrayList(u8) = .empty;
        errdefer escaped.deinit(allocator);
        const keep_going = try appendPrintfEscapedString(allocator, &escaped, arg);
        const bytes = try escaped.toOwnedSlice(allocator);
        defer allocator.free(bytes);
        try appendPadded(allocator, stdout, truncatePrintfBytes(bytes, spec.precision), spec);
        return keep_going;
    }

    const rendered: []u8 = switch (spec.spec) {
        's' => try formatPrintfString(allocator, arg, spec.precision),
        'c' => try allocator.dupe(u8, if (arg.len == 0) &[_]u8{0} else arg[0..1]),
        else => blk: {
            try printfDiagnostic(allocator, stderr, status, "invalid conversion");
            break :blk try allocator.alloc(u8, 0);
        },
    };
    defer allocator.free(rendered);
    try appendPadded(allocator, stdout, rendered, spec);
    return true;
}

fn formatPrintfString(allocator: std.mem.Allocator, arg: []const u8, precision: ?usize) ![]u8 {
    return allocator.dupe(u8, truncatePrintfBytes(arg, precision));
}

fn truncatePrintfBytes(text: []const u8, precision: ?usize) []const u8 {
    const limit = if (precision) |value| @min(value, text.len) else text.len;
    return text[0..limit];
}

fn formatPrintfSignedInteger(allocator: std.mem.Allocator, spec: PrintfSpec, value: i64) ![]u8 {
    const negative = value < 0;
    const magnitude: u64 = if (negative) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    return formatPrintfInteger(allocator, spec, magnitude, negative, .decimal);
}

fn formatPrintfUnsignedInteger(allocator: std.mem.Allocator, spec: PrintfSpec, value: u64, base: PrintfIntegerBase) ![]u8 {
    var unsigned_spec = spec;
    unsigned_spec.sign_plus = false;
    unsigned_spec.sign_space = false;
    return formatPrintfInteger(allocator, unsigned_spec, value, false, base);
}

fn formatPrintfInteger(allocator: std.mem.Allocator, spec: PrintfSpec, magnitude: u64, negative: bool, base: PrintfIntegerBase) ![]u8 {
    const raw_digits = try formatPrintfIntegerDigits(allocator, magnitude, base);
    defer allocator.free(raw_digits);

    var digits: []const u8 = raw_digits;
    if (spec.precision == 0 and magnitude == 0) digits = "";

    var precision_zeroes: usize = if (spec.precision) |precision| if (precision > digits.len) precision - digits.len else 0 else 0;
    if (base == .octal and spec.alternate) {
        if (digits.len + precision_zeroes == 0) {
            precision_zeroes = 1;
        } else if ((digits.len == 0 or digits[0] != '0') and precision_zeroes == 0) {
            precision_zeroes = 1;
        }
    }

    var prefix_buffer: [2]u8 = undefined;
    const prefix: []const u8 = switch (base) {
        .decimal => blk: {
            if (negative) {
                prefix_buffer[0] = '-';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_plus) {
                prefix_buffer[0] = '+';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_space) {
                prefix_buffer[0] = ' ';
                break :blk prefix_buffer[0..1];
            }
            break :blk "";
        },
        .octal => "",
        .lower_hex => if (spec.alternate and magnitude != 0) "0x" else "",
        .upper_hex => if (spec.alternate and magnitude != 0) "0X" else "",
    };

    const unpadded_len = prefix.len + precision_zeroes + digits.len;
    const width = spec.width orelse 0;
    const width_pad = if (width > unpadded_len) width - unpadded_len else 0;
    const use_zero_width_pad = spec.zero_pad and !spec.left_adjust and spec.precision == null;
    const leading_spaces: usize = if (!spec.left_adjust and !use_zero_width_pad) width_pad else 0;
    const width_zeroes: usize = if (use_zero_width_pad) width_pad else 0;
    const trailing_spaces: usize = if (spec.left_adjust) width_pad else 0;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, ' ', leading_spaces);
    try out.appendSlice(allocator, prefix);
    try out.appendNTimes(allocator, '0', width_zeroes + precision_zeroes);
    try out.appendSlice(allocator, digits);
    try out.appendNTimes(allocator, ' ', trailing_spaces);
    return out.toOwnedSlice(allocator);
}

fn formatPrintfIntegerDigits(allocator: std.mem.Allocator, value: u64, base: PrintfIntegerBase) ![]u8 {
    return switch (base) {
        .decimal => std.fmt.allocPrint(allocator, "{d}", .{value}),
        .octal => std.fmt.allocPrint(allocator, "{o}", .{value}),
        .lower_hex => std.fmt.allocPrint(allocator, "{x}", .{value}),
        .upper_hex => std.fmt.allocPrint(allocator, "{X}", .{value}),
    };
}

fn appendPadded(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, spec: PrintfSpec) !void {
    const width = spec.width orelse 0;
    const pad_len = if (width > text.len) width - text.len else 0;
    const pad_byte: u8 = if (spec.zero_pad and !spec.left_adjust) '0' else ' ';
    if (!spec.left_adjust) try stdout.appendNTimes(allocator, pad_byte, pad_len);
    try stdout.appendSlice(allocator, text);
    if (spec.left_adjust) try stdout.appendNTimes(allocator, ' ', pad_len);
}

fn isPrintfFloatSpec(spec: u8) bool {
    return switch (spec) {
        'a', 'A', 'e', 'E', 'f', 'F', 'g', 'G' => true,
        else => false,
    };
}

fn appendPrintfFloatConversion(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, spec: PrintfSpec, arg: []const u8) !void {
    const value = try parsePrintfFloat(allocator, stderr, status, arg);

    var format_buffer: [64]u8 = undefined;
    const c_format = printfCFormat(&format_buffer, spec) catch unreachable;

    var stack_buffer: [128]u8 = undefined;
    const stack_len = snprintf(stack_buffer[0..].ptr, stack_buffer.len, c_format.ptr, value);
    if (stack_len < 0) {
        try printfDiagnostic(allocator, stderr, status, "invalid conversion");
        return;
    }
    const needed: usize = @intCast(stack_len);
    if (needed < stack_buffer.len) {
        try stdout.appendSlice(allocator, stack_buffer[0..needed]);
        return;
    }

    const heap_buffer = try allocator.alloc(u8, needed + 1);
    defer allocator.free(heap_buffer);
    const heap_len = snprintf(heap_buffer.ptr, heap_buffer.len, c_format.ptr, value);
    if (heap_len < 0) {
        try printfDiagnostic(allocator, stderr, status, "invalid conversion");
        return;
    }
    try stdout.appendSlice(allocator, heap_buffer[0..@min(@as(usize, @intCast(heap_len)), needed)]);
}

fn printfCFormat(buffer: []u8, spec: PrintfSpec) ![:0]u8 {
    var flags_buffer: [5]u8 = undefined;
    var flags_len: usize = 0;
    if (spec.left_adjust) {
        flags_buffer[flags_len] = '-';
        flags_len += 1;
    }
    if (spec.sign_plus) {
        flags_buffer[flags_len] = '+';
        flags_len += 1;
    }
    if (spec.sign_space) {
        flags_buffer[flags_len] = ' ';
        flags_len += 1;
    }
    if (spec.alternate) {
        flags_buffer[flags_len] = '#';
        flags_len += 1;
    }
    if (spec.zero_pad) {
        flags_buffer[flags_len] = '0';
        flags_len += 1;
    }
    const flags = flags_buffer[0..flags_len];

    if (spec.width) |width| {
        if (spec.precision) |precision| {
            return std.fmt.bufPrintSentinel(buffer, "%{s}{d}.{d}{c}", .{ flags, width, precision, spec.spec }, 0);
        }
        return std.fmt.bufPrintSentinel(buffer, "%{s}{d}{c}", .{ flags, width, spec.spec }, 0);
    }
    if (spec.precision) |precision| {
        return std.fmt.bufPrintSentinel(buffer, "%{s}.{d}{c}", .{ flags, precision, spec.spec }, 0);
    }
    return std.fmt.bufPrintSentinel(buffer, "%{s}{c}", .{ flags, spec.spec }, 0);
}

const PrintfIntegerConstant = struct {
    magnitude: u64,
    negative: bool = false,
    complete: bool = true,
    overflow: bool = false,
};

const PrintfMagnitude = struct {
    value: u64,
    overflow: bool = false,
};

const PrintfSignedValue = struct {
    value: i64,
    overflow: bool = false,
};

const PrintfUnsignedValue = struct {
    value: u64,
    overflow: bool = false,
};

fn parsePrintfSigned(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, stderr_before_stdout: *bool, arg: []const u8) !i64 {
    const parsed = parsePrintfIntegerConstant(arg) catch |err| switch (err) {
        error.InvalidCharacter => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
        error.Overflow => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
    };
    const converted = printfSignedValue(parsed);
    if (!parsed.complete or converted.overflow) try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
    return converted.value;
}

fn parsePrintfUnsigned(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, stderr_before_stdout: *bool, arg: []const u8) !u64 {
    const parsed = parsePrintfIntegerConstant(arg) catch |err| switch (err) {
        error.InvalidCharacter => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
        error.Overflow => {
            try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
            return 0;
        },
    };
    const converted = printfUnsignedValue(parsed);
    if (!parsed.complete or converted.overflow) try printfNumericDiagnostic(allocator, stderr, status, stderr_before_stdout);
    return converted.value;
}

fn printfSignedValue(parsed: PrintfIntegerConstant) PrintfSignedValue {
    if (!parsed.negative) {
        if (parsed.magnitude > std.math.maxInt(i64)) return .{ .value = std.math.maxInt(i64), .overflow = true };
        return .{ .value = @intCast(parsed.magnitude), .overflow = parsed.overflow };
    }
    const max_plus_one = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    if (parsed.magnitude == max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = parsed.overflow };
    if (parsed.magnitude > max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = true };
    return .{ .value = -@as(i64, @intCast(parsed.magnitude)), .overflow = parsed.overflow };
}

fn printfUnsignedValue(parsed: PrintfIntegerConstant) PrintfUnsignedValue {
    if (!parsed.negative) return .{ .value = parsed.magnitude, .overflow = parsed.overflow };
    if (parsed.overflow) return .{ .value = std.math.maxInt(u64), .overflow = true };
    return .{ .value = (~parsed.magnitude) +% 1 };
}

fn parsePrintfMagnitude(text: []const u8, base: u8) !PrintfMagnitude {
    const value = std.fmt.parseInt(u64, text, base) catch |err| switch (err) {
        error.Overflow => return .{ .value = std.math.maxInt(u64), .overflow = true },
        else => return err,
    };
    return .{ .value = value };
}

fn skipPrintfIntegerWhitespace(arg: []const u8, cursor: *usize) void {
    while (cursor.* < arg.len and std.ascii.isWhitespace(arg[cursor.*])) : (cursor.* += 1) {}
}

fn printfIntegerParseComplete(arg: []const u8, cursor: usize) bool {
    var trailing = cursor;
    skipPrintfIntegerWhitespace(arg, &trailing);
    return trailing == arg.len;
}

fn parsePrintfIntegerConstant(arg: []const u8) !PrintfIntegerConstant {
    if (arg.len == 0) return .{ .magnitude = 0 };
    if (arg[0] == '\'' or arg[0] == '"') return .{ .magnitude = if (arg.len > 1) arg[1] else 0 };

    var cursor: usize = 0;
    skipPrintfIntegerWhitespace(arg, &cursor);
    if (cursor >= arg.len) return error.InvalidCharacter;

    var negative = false;
    if (arg[cursor] == '+' or arg[cursor] == '-') {
        negative = arg[cursor] == '-';
        cursor += 1;
    }
    if (cursor >= arg.len or !std.ascii.isDigit(arg[cursor])) return error.InvalidCharacter;

    const digits_start: usize = cursor;
    var base: u8 = 10;
    if (arg[cursor] == '0') {
        base = 8;
        cursor += 1;
        if (cursor < arg.len and (arg[cursor] == 'x' or arg[cursor] == 'X')) {
            base = 16;
            cursor += 1;
            const hex_start = cursor;
            while (cursor < arg.len and std.ascii.isHex(arg[cursor])) : (cursor += 1) {}
            if (cursor == hex_start) return .{ .magnitude = 0, .negative = negative, .complete = false };
            const magnitude = try parsePrintfMagnitude(arg[hex_start..cursor], base);
            return .{
                .magnitude = magnitude.value,
                .negative = negative,
                .complete = printfIntegerParseComplete(arg, cursor),
                .overflow = magnitude.overflow,
            };
        }
        while (cursor < arg.len and arg[cursor] >= '0' and arg[cursor] <= '7') : (cursor += 1) {}
    } else {
        while (cursor < arg.len and std.ascii.isDigit(arg[cursor])) : (cursor += 1) {}
    }
    const magnitude = try parsePrintfMagnitude(arg[digits_start..cursor], base);
    return .{
        .magnitude = magnitude.value,
        .negative = negative,
        .complete = printfIntegerParseComplete(arg, cursor),
        .overflow = magnitude.overflow,
    };
}

fn parsePrintfFloat(allocator: std.mem.Allocator, stderr: *std.ArrayList(u8), status: *outcome.ExitStatus, arg: []const u8) !f64 {
    if (arg.len == 0) return 0;
    return std.fmt.parseFloat(f64, arg) catch {
        try printfDiagnostic(allocator, stderr, status, "numeric argument required");
        return 0;
    };
}

fn appendPrintfEscapedString(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8) !bool {
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
        } else if (!try appendEscapedSequence(allocator, stdout, text, &index, .percent_b)) {
            return false;
        }
    }
    return true;
}

const PrintfEscapeMode = enum { format, percent_b };

fn appendEscapedSequence(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, index: *usize, mode: PrintfEscapeMode) !bool {
    const byte = text[index.*];
    switch (byte) {
        'a' => try stdout.append(allocator, 0x07),
        'b' => try stdout.append(allocator, 0x08),
        'c' => {
            if (mode == .format) {
                try stdout.append(allocator, '\\');
                return true;
            }
            index.* += 1;
            return false;
        },
        'f' => try stdout.append(allocator, 0x0c),
        'n' => try stdout.append(allocator, '\n'),
        'r' => try stdout.append(allocator, '\r'),
        't' => try stdout.append(allocator, '\t'),
        'v' => try stdout.append(allocator, 0x0b),
        '\\' => try stdout.append(allocator, '\\'),
        'x' => {
            try appendHexEscape(allocator, stdout, text, index);
            return true;
        },
        '0'...'7' => {
            try appendOctalEscape(allocator, stdout, text, index, mode);
            return true;
        },
        else => {
            try stdout.append(allocator, '\\');
            if (mode == .format) return true;
            try stdout.append(allocator, byte);
        },
    }
    index.* += 1;
    return true;
}

fn appendHexEscape(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, index: *usize) !void {
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = index.* + 1;
    while (cursor < text.len and count < 2) : (count += 1) {
        const digit = std.fmt.charToDigit(text[cursor], 16) catch break;
        value = value * 16 + digit;
        cursor += 1;
    }
    if (count == 0) {
        try stdout.append(allocator, '\\');
        try stdout.append(allocator, 'x');
        index.* += 1;
    } else {
        try stdout.append(allocator, value);
        index.* = cursor;
    }
}

fn appendOctalEscape(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8, index: *usize, mode: PrintfEscapeMode) !void {
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = index.*;
    if (mode == .percent_b and cursor < text.len and text[cursor] == '0') cursor += 1;
    while (cursor < text.len and count < 3 and text[cursor] >= '0' and text[cursor] <= '7') : (count += 1) {
        value = value * 8 + (text[cursor] - '0');
        cursor += 1;
    }
    if (count == 0) {
        try stdout.append(allocator, 0);
        index.* += 1;
    } else {
        try stdout.append(allocator, value);
        index.* = cursor;
    }
}

fn evaluateTestBuiltin(fs_port: ?runtime.fs.Port, fd_port: ?runtime.fd.Port, argv: []const []const u8) outcome.ExitStatus {
    std.debug.assert(argv.len != 0);
    const is_bracket = std.mem.eql(u8, argv[0], "[");
    const args = argv[1..];
    if (is_bracket) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) return 2;
        std.debug.assert(args.len != 0 and std.mem.eql(u8, args[args.len - 1], "]"));
        const matched = evalTest(fs_port, fd_port, args[0 .. args.len - 1]) catch return 2;
        return if (matched) 0 else 1;
    }
    std.debug.assert(std.mem.eql(u8, argv[0], "test"));
    const matched = evalTest(fs_port, fd_port, args) catch return 2;
    return if (matched) 0 else 1;
}

const TestExpressionError = error{InvalidTestExpression};

fn evalTest(fs_port: ?runtime.fs.Port, fd_port: ?runtime.fd.Port, args: []const []const u8) TestExpressionError!bool {
    if (args.len == 3 and isBinaryTestOperator(args[1])) {
        return evalBinaryTest(fs_port, args[0], args[1], args[2]);
    }
    if (hasTestExpressionOperator(args)) {
        var test_parser: TestExpressionParser = .{ .fs_port = fs_port, .fd_port = fd_port, .args = args };
        const result = try test_parser.parseOr();
        if (test_parser.index != args.len) return error.InvalidTestExpression;
        return result;
    }
    return evalSimpleTest(fs_port, fd_port, args);
}

fn evalSimpleTest(fs_port: ?runtime.fs.Port, fd_port: ?runtime.fd.Port, args: []const []const u8) TestExpressionError!bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].len != 0,
        2 => evalUnaryTest(fs_port, fd_port, args[0], args[1]),
        3 => if (isBinaryTestOperator(args[1]))
            evalBinaryTest(fs_port, args[0], args[1], args[2])
        else if (std.mem.eql(u8, args[0], "!"))
            !(try evalSimpleTest(fs_port, fd_port, args[1..]))
        else
            error.InvalidTestExpression,
        4 => if (std.mem.eql(u8, args[0], "!")) !(try evalSimpleTest(fs_port, fd_port, args[1..])) else error.InvalidTestExpression,
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
    fs_port: ?runtime.fs.Port,
    fd_port: ?runtime.fd.Port,
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
            return evalBinaryTest(self.fs_port, left, op, right);
        }
        if (self.index + 1 < self.args.len and isUnaryTestOperator(self.args[self.index])) {
            const op = self.args[self.index];
            const operand = self.args[self.index + 1];
            self.index += 2;
            return evalUnaryTest(self.fs_port, self.fd_port, op, operand);
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
    return std.mem.eql(u8, op, "!") or std.mem.eql(u8, op, "-n") or std.mem.eql(u8, op, "-z") or
        std.mem.eql(u8, op, "-e") or std.mem.eql(u8, op, "-f") or std.mem.eql(u8, op, "-d") or std.mem.eql(u8, op, "-s") or
        std.mem.eql(u8, op, "-b") or std.mem.eql(u8, op, "-c") or std.mem.eql(u8, op, "-p") or std.mem.eql(u8, op, "-S") or
        std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h") or std.mem.eql(u8, op, "-u") or std.mem.eql(u8, op, "-g") or
        std.mem.eql(u8, op, "-k") or std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(u8, op, "-x") or
        std.mem.eql(u8, op, "-t");
}

fn isBinaryTestOperator(op: []const u8) bool {
    return std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "-eq") or std.mem.eql(u8, op, "-ne") or
        std.mem.eql(u8, op, "-gt") or std.mem.eql(u8, op, "-ge") or std.mem.eql(u8, op, "-lt") or std.mem.eql(u8, op, "-le") or
        std.mem.eql(u8, op, "-ef") or std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot");
}

fn evalUnaryTest(fs_port: ?runtime.fs.Port, fd_port: ?runtime.fd.Port, op: []const u8, operand: []const u8) TestExpressionError!bool {
    if (std.mem.eql(u8, op, "!")) return operand.len == 0;
    if (std.mem.eql(u8, op, "-n")) return operand.len != 0;
    if (std.mem.eql(u8, op, "-z")) return operand.len == 0;

    if (std.mem.eql(u8, op, "-e") or std.mem.eql(u8, op, "-f") or std.mem.eql(u8, op, "-d") or std.mem.eql(u8, op, "-s") or std.mem.eql(u8, op, "-b") or std.mem.eql(u8, op, "-c") or std.mem.eql(u8, op, "-p") or std.mem.eql(u8, op, "-S")) {
        const metadata = inspectTestPath(fs_port, operand, true) orelse return false;
        if (std.mem.eql(u8, op, "-e")) return true;
        if (std.mem.eql(u8, op, "-f")) return metadata.stat.kind == .file;
        if (std.mem.eql(u8, op, "-d")) return metadata.stat.kind == .directory;
        if (std.mem.eql(u8, op, "-s")) return metadata.stat.size > 0;
        if (std.mem.eql(u8, op, "-b")) return metadata.stat.kind == .block_device;
        if (std.mem.eql(u8, op, "-c")) return metadata.stat.kind == .character_device;
        if (std.mem.eql(u8, op, "-p")) return metadata.stat.kind == .named_pipe;
        if (std.mem.eql(u8, op, "-S")) return metadata.stat.kind == .unix_domain_socket;
    }
    if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
        const metadata = inspectTestPath(fs_port, operand, false) orelse return false;
        return metadata.stat.kind == .sym_link;
    }
    if (std.mem.eql(u8, op, "-u") or std.mem.eql(u8, op, "-g") or std.mem.eql(u8, op, "-k")) {
        const metadata = inspectTestPath(fs_port, operand, false) orelse return false;
        const mode = metadata.stat.permissions.toMode();
        if (std.mem.eql(u8, op, "-u")) return mode & 0o4000 != 0;
        if (std.mem.eql(u8, op, "-g")) return mode & 0o2000 != 0;
        if (std.mem.eql(u8, op, "-k")) return mode & 0o1000 != 0;
    }
    if (std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(u8, op, "-x")) {
        const port = fs_port orelse return false;
        if (operand.len == 0) return false;
        const request: runtime.fs.AccessRequest = .{
            .path = operand,
            .read = std.mem.eql(u8, op, "-r"),
            .write = std.mem.eql(u8, op, "-w"),
            .execute = std.mem.eql(u8, op, "-x"),
        };
        request.validate();
        port.access(request) catch return false;
        return true;
    }
    if (std.mem.eql(u8, op, "-t")) {
        const descriptor = std.fmt.parseInt(runtime.fd.Descriptor, operand, 10) catch return error.InvalidTestExpression;
        if (!runtime.fd.isValidDescriptor(descriptor)) return false;
        const port = fd_port orelse {
            std.debug.assert(false);
            return false;
        };
        const request = runtime.fd.IsTtyRequest.init(descriptor);
        const result = port.isTty(request) catch return false;
        result.validate();
        return result.is_tty;
    }
    return error.InvalidTestExpression;
}

fn evalBinaryTest(fs_port: ?runtime.fs.Port, left: []const u8, op: []const u8, right: []const u8) TestExpressionError!bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "<")) return std.mem.lessThan(u8, left, right);
    if (std.mem.eql(u8, op, ">")) return std.mem.lessThan(u8, right, left);

    if (std.mem.eql(u8, op, "-ef") or std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot")) {
        return evalFileComparisonTest(fs_port, left, op, right);
    }

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

fn inspectTestPath(fs_port: ?runtime.fs.Port, path: []const u8, follow_symlinks: bool) ?runtime.fs.InspectPathResult {
    const port = fs_port orelse return null;
    if (path.len == 0) return null;
    const request: runtime.fs.InspectPathRequest = .{ .path = path, .follow_symlinks = follow_symlinks };
    request.validate();
    const result = port.inspectPath(request) catch return null;
    result.validate();
    return result;
}

fn evalFileComparisonTest(fs_port: ?runtime.fs.Port, left: []const u8, op: []const u8, right: []const u8) bool {
    const left_metadata = inspectTestPath(fs_port, left, true);
    const right_metadata = inspectTestPath(fs_port, right, true);

    if (std.mem.eql(u8, op, "-ef")) {
        const lhs = left_metadata orelse return false;
        const rhs = right_metadata orelse return false;
        if (lhs.identity) |left_identity| {
            if (rhs.identity) |right_identity| return left_identity.device == right_identity.device and left_identity.inode == right_identity.inode;
        }
        return lhs.stat.inode == rhs.stat.inode;
    }
    if (std.mem.eql(u8, op, "-nt")) {
        const lhs = left_metadata orelse return false;
        const rhs = right_metadata orelse return true;
        return lhs.stat.mtime.nanoseconds > rhs.stat.mtime.nanoseconds;
    }
    if (std.mem.eql(u8, op, "-ot")) {
        const rhs = right_metadata orelse return false;
        const lhs = left_metadata orelse return true;
        return lhs.stat.mtime.nanoseconds < rhs.stat.mtime.nanoseconds;
    }
    unreachable;
}

fn parseTestInteger(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn assertBuiltinDeltaCompatible(plan: command_plan.CommandPlan, state_delta: delta.StateDelta) void {
    const definition = switch (plan.classification) {
        .special_builtin, .regular_builtin => |definition| definition,
        .empty, .assignment_only => return,
        .function, .external, .not_found => unreachable,
    };
    definition.validate();
    if (!definition.isSemanticallyNonMutating()) {
        std.debug.assert(definition.semantic_class.isStateful());
        std.debug.assert(state_delta.target == plan.target);
        return;
    }

    std.debug.assert(state_delta.variable_flags.items.len == 0);
    std.debug.assert(state_delta.variable_unsets.items.len == 0);
    std.debug.assert(state_delta.function_unsets.items.len == 0);
    std.debug.assert(state_delta.option_changes.items.len == 0);
    std.debug.assert(state_delta.alias_sets.items.len == 0);
    std.debug.assert(state_delta.alias_unsets.items.len == 0);
    std.debug.assert(!state_delta.clear_aliases);
    std.debug.assert(state_delta.trap_mutations.items.len == 0);
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

test "semantic evaluator routes test -t through fd runtime port" {
    const FakeFdRuntime = struct {
        requested_descriptor: ?runtime.fd.Descriptor = null,
        tty_descriptor: runtime.fd.Descriptor = 7,

        fn port(self: *@This()) runtime.fd.Port {
            return .{
                .context = self,
                .open_fn = open,
                .close_fn = close,
                .duplicate_fn = duplicate,
                .duplicate_to_fn = duplicateTo,
                .pipe_fn = pipe,
                .is_tty_fn = isTty,
            };
        }

        fn fromContext(context_value: *anyopaque) *@This() {
            return @ptrCast(@alignCast(context_value));
        }

        fn open(_: *anyopaque, _: runtime.fd.OpenRequest) runtime.fd.OpenError!runtime.fd.OpenResult {
            unreachable;
        }

        fn close(_: *anyopaque, _: runtime.fd.CloseRequest) runtime.fd.CloseError!void {
            unreachable;
        }

        fn duplicate(_: *anyopaque, _: runtime.fd.DuplicateRequest) runtime.fd.DuplicateError!runtime.fd.DuplicateResult {
            unreachable;
        }

        fn duplicateTo(_: *anyopaque, _: runtime.fd.DuplicateToRequest) runtime.fd.DuplicateError!void {
            unreachable;
        }

        fn pipe(_: *anyopaque, _: runtime.fd.PipeRequest) runtime.fd.PipeError!runtime.fd.PipeResult {
            unreachable;
        }

        fn isTty(context_value: *anyopaque, request: runtime.fd.IsTtyRequest) runtime.fd.IsTtyError!runtime.fd.IsTtyResult {
            const self = fromContext(context_value);
            request.validate();
            self.requested_descriptor = request.descriptor;
            return .{ .is_tty = request.descriptor == self.tty_descriptor };
        }
    };

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var fake: FakeFdRuntime = .{};
    var evaluator = Evaluator.initWithFdPort(std.testing.allocator, fake.port());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const tty_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "test", "-t", "7" } } });
    var tty = try evaluatePlan(&evaluator, &shell_state, eval_context, tty_plan);
    defer tty.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), tty.status);
    try std.testing.expectEqual(@as(?runtime.fd.Descriptor, 7), fake.requested_descriptor);
    tty.discardDelta(.current_shell);

    const non_tty_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "[", "-t", "8", "]" } } });
    var non_tty = try evaluatePlan(&evaluator, &shell_state, eval_context, non_tty_plan);
    defer non_tty.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), non_tty.status);
    try std.testing.expectEqual(@as(?runtime.fd.Descriptor, 8), fake.requested_descriptor);
    non_tty.discardDelta(.current_shell);

    const invalid_fd_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "test", "-t", "-1" } } });
    var invalid_fd = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_fd_plan);
    defer invalid_fd.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), invalid_fd.status);
    try std.testing.expectEqual(@as(?runtime.fd.Descriptor, 8), fake.requested_descriptor);
    invalid_fd.discardDelta(.current_shell);
}

test "semantic evaluator captures printf output and operand errors in CommandOutcome" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const basic_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "printf", "hello %s %d\n", "world", "42" } } });
    var basic = try evaluatePlan(&evaluator, &shell_state, eval_context, basic_plan);
    defer basic.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), basic.status);
    try std.testing.expectEqualStrings("hello world 42\n", basic.stdout.items);
    try std.testing.expectEqualStrings("", basic.stderr.items);
    try std.testing.expectEqual(@as(usize, 0), basic.state_delta.variable_assignments.items.len);
    basic.discardDelta(.current_shell);

    const repeat_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "printf", "[%5s][%-5s][%.3s][%04d]\n", "a", "b", "abcdef", "7", "c", "d", "xyz", "8" } } });
    var repeat = try evaluatePlan(&evaluator, &shell_state, eval_context, repeat_plan);
    defer repeat.deinit();
    try std.testing.expectEqualStrings("[    a][b    ][abc][0007]\n[    c][d    ][xyz][0008]\n", repeat.stdout.items);
    repeat.discardDelta(.current_shell);

    const escape_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "printf", "A\\101:%b", "B\\0101 C\\cD" } } });
    var escaped = try evaluatePlan(&evaluator, &shell_state, eval_context, escape_plan);
    defer escaped.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), escaped.status);
    try std.testing.expectEqualStrings("AA:BA C", escaped.stdout.items);
    escaped.discardDelta(.current_shell);

    const invalid_integer_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "printf", "%d:%x\n", "5x ", " 0x1fg " } } });
    var invalid_integer = try evaluatePlan(&evaluator, &shell_state, eval_context, invalid_integer_plan);
    defer invalid_integer.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), invalid_integer.status);
    try std.testing.expectEqualStrings("5:1f\n", invalid_integer.stdout.items);
    try std.testing.expectEqualStrings("printf: numeric argument required\nprintf: numeric argument required\n", invalid_integer.stderr.items);
    invalid_integer.discardDelta(.current_shell);

    const missing_format_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"printf"} } });
    var missing_format = try evaluatePlan(&evaluator, &shell_state, eval_context, missing_format_plan);
    defer missing_format.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), missing_format.status);
    try std.testing.expectEqualStrings("", missing_format.stdout.items);
    try std.testing.expectEqualStrings("printf: missing format operand\n", missing_format.stderr.items);
    missing_format.discardDelta(.current_shell);
}

test "semantic evaluator evaluates runtime-backed file test predicates" {
    const path = "rush-semantic-test-file.tmp";
    const hard_link_path = "rush-semantic-test-file-hard-link.tmp";
    const older_path = "rush-semantic-test-older.tmp";
    const newer_path = "rush-semantic-test-newer.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, hard_link_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "x" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = older_path, .data = "old" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = newer_path, .data = "new" });
    try std.Io.Dir.cwd().hardLink(path, std.Io.Dir.cwd(), hard_link_path, std.testing.io, .{});
    const older_time: std.Io.Timestamp = .{ .nanoseconds = 1_000_000_000 };
    const newer_time: std.Io.Timestamp = .{ .nanoseconds = 2_000_000_000 };
    try std.Io.Dir.cwd().setTimestamps(std.testing.io, older_path, .{ .modify_timestamp = .{ .new = older_time } });
    try std.Io.Dir.cwd().setTimestamps(std.testing.io, newer_path, .{ .modify_timestamp = .{ .new = newer_time } });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hard_link_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, older_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, newer_path) catch {};

    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var adapter = runtime.posix.Adapter.init(std.testing.io);
    var evaluator = Evaluator.initWithFsPort(std.testing.allocator, adapter.fsPort());
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const Case = struct { argv: []const []const u8, status: outcome.ExitStatus };
    const cases = [_]Case{
        .{ .argv = &.{ "test", "-d", "." }, .status = 0 },
        .{ .argv = &.{ "test", "-e", path }, .status = 0 },
        .{ .argv = &.{ "test", "-f", path }, .status = 0 },
        .{ .argv = &.{ "test", "-s", path }, .status = 0 },
        .{ .argv = &.{ "test", "-r", path }, .status = 0 },
        .{ .argv = &.{ "test", "-w", path }, .status = 0 },
        .{ .argv = &.{ "test", "!", "-e", "rush-semantic-test-missing.tmp" }, .status = 0 },
        .{ .argv = &.{ "test", path, "-ef", hard_link_path }, .status = 0 },
        .{ .argv = &.{ "test", path, "-ef", older_path }, .status = 1 },
        .{ .argv = &.{ "test", newer_path, "-nt", older_path }, .status = 0 },
        .{ .argv = &.{ "test", older_path, "-ot", newer_path }, .status = 0 },
        .{ .argv = &.{ "test", newer_path, "-nt", "rush-semantic-test-missing.tmp" }, .status = 0 },
        .{ .argv = &.{ "[", older_path, "-ot", newer_path, "]" }, .status = 0 },
    };

    for (cases) |case| {
        const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = case.argv } });
        var result = try evaluatePlan(&evaluator, &shell_state, eval_context, plan);
        defer result.deinit();
        try std.testing.expectEqual(case.status, result.status);
        try std.testing.expectEqualStrings("", result.stdout.items);
        try std.testing.expectEqualStrings("", result.stderr.items);
        try std.testing.expectEqual(@as(usize, 0), result.state_delta.variable_assignments.items.len);
        result.discardDelta(.current_shell);
    }
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

test "semantic evaluator models declaration stateful builtins as StateDelta mutations" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const export_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "export", "EXPORTED=value", "MARKED" } } });
    var export_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, export_plan);
    defer export_outcome.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 0), export_outcome.status);
    try std.testing.expectEqual(@as(usize, 2), export_outcome.state_delta.variable_assignments.items.len + export_outcome.state_delta.variable_flags.items.len);
    try export_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("value", shell_state.getVariable("EXPORTED").?.value);
    try std.testing.expect(shell_state.getVariable("EXPORTED").?.exported);
    try std.testing.expect(shell_state.getVariable("MARKED").?.exported);

    const readonly_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "readonly", "LOCKED=old" } } });
    var readonly_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, readonly_plan);
    defer readonly_outcome.deinit();
    try readonly_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expect(shell_state.getVariable("LOCKED").?.readonly);

    const unset_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "unset", "EXPORTED" } } });
    var unset_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, unset_plan);
    defer unset_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), unset_outcome.state_delta.variable_unsets.items.len);
    try unset_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("EXPORTED"));

    const readonly_unset_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "unset", "LOCKED" } } });
    var readonly_unset = try evaluatePlan(&evaluator, &shell_state, eval_context, readonly_unset_plan);
    defer readonly_unset.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 2), readonly_unset.status);
    try std.testing.expectEqualStrings("unset: readonly variable", readonly_unset.diagnostics.items[0].message);
    try readonly_unset.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("old", shell_state.getVariable("LOCKED").?.value);
}

test "semantic evaluator models set and shift stateful builtin deltas" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.replacePositionals(&.{ "a", "b", "c" });
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const set_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "set", "-eu", "--", "x", "y" } } });
    var set_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, set_plan);
    defer set_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 2), set_outcome.state_delta.option_changes.items.len);
    try std.testing.expectEqual(@as(usize, 2), set_outcome.state_delta.positionals.?.len);
    try set_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expect(shell_state.options.errexit);
    try std.testing.expect(shell_state.options.nounset);
    try std.testing.expectEqualStrings("x", shell_state.positionals.items[0]);

    const shift_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "shift", "1" } } });
    var shift_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, shift_plan);
    defer shift_outcome.deinit();
    try shift_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.positionals.items.len);
    try std.testing.expectEqualStrings("y", shell_state.positionals.items[0]);

    const too_far_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "shift", "2" } } });
    var too_far = try evaluatePlan(&evaluator, &shell_state, eval_context, too_far_plan);
    defer too_far.deinit();
    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), too_far.status);
    try std.testing.expectEqualStrings("shift: shift count out of range", too_far.diagnostics.items[0].message);
    try too_far.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(usize, 1), shell_state.positionals.items.len);
}

test "semantic evaluator models alias unalias and trap registration deltas" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const alias_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "alias", "say=echo hi", "say" } } });
    var alias_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, alias_plan);
    defer alias_outcome.deinit();
    try std.testing.expectEqualStrings("say='echo hi'\n", alias_outcome.stdout.items);
    try std.testing.expectEqual(@as(usize, 1), alias_outcome.state_delta.alias_sets.items.len);
    try alias_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("echo hi", shell_state.getAlias("say").?.value);

    const unalias_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "unalias", "say" } } });
    var unalias_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, unalias_plan);
    defer unalias_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), unalias_outcome.state_delta.alias_unsets.items.len);
    try unalias_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqual(@as(?state.Alias, null), shell_state.getAlias("say"));

    const trap_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "trap", "echo bye", "EXIT", "INT" } } });
    var trap_outcome = try evaluatePlan(&evaluator, &shell_state, eval_context, trap_plan);
    defer trap_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 2), trap_outcome.state_delta.trap_mutations.items.len);
    try trap_outcome.commitDelta(&shell_state, .current_shell);
    try std.testing.expectEqualStrings("echo bye", shell_state.getTrap("EXIT").?.action);
    try std.testing.expectEqualStrings("echo bye", shell_state.getTrap("INT").?.action);

    const list_trap_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{ "trap", "-p", "INT" } } });
    var list_trap = try evaluatePlan(&evaluator, &shell_state, eval_context, list_trap_plan);
    defer list_trap.deinit();
    try std.testing.expectEqualStrings("trap -- 'echo bye' INT\n", list_trap.stdout.items);
    list_trap.discardDelta(.current_shell);
}

test "semantic evaluator reports unsupported simple builtin execution explicitly" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = Evaluator.init(std.testing.allocator);
    const eval_context = context.EvalContext.forTarget(.current_shell);

    const pwd_plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"pwd"} } });
    try std.testing.expectError(error.Unimplemented, evaluatePlan(&evaluator, &shell_state, eval_context, pwd_plan));
}
