//! Assignment semantics for expanded simple command plans.
//!
//! This module does not execute commands. It classifies assignment words from a
//! `CommandPlan` into persistent `StateDelta` mutations or explicit temporary
//! command environments so commit/discard boundaries can be tested directly.

const std = @import("std");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const delta = @import("delta.zig");
const outcome = @import("outcome.zig");
const state = @import("state.zig");

pub const TemporaryVariable = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
};

pub const TemporaryEnvironment = struct {
    allocator: std.mem.Allocator,
    variables: std.ArrayList(TemporaryVariable) = .empty,

    pub fn init(allocator: std.mem.Allocator) TemporaryEnvironment {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TemporaryEnvironment) void {
        for (self.variables.items) |variable| {
            self.allocator.free(variable.name);
            self.allocator.free(variable.value);
        }
        self.variables.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn isEmpty(self: TemporaryEnvironment) bool {
        return self.variables.items.len == 0;
    }

    pub fn appendCommandAssignments(
        self: *TemporaryEnvironment,
        shell_state: state.ShellState,
        plan: command_plan.CommandPlan,
    ) !void {
        plan.validate();
        std.debug.assert(plan.assignmentEffect() == .temporary);
        if (delta.firstReadonlyAssignment(shell_state, plan.assignments) != null) return error.ReadonlyVariable;

        const force_export = temporaryAssignmentsAreExported(plan);
        for (plan.assignments) |assignment| {
            const existing = shell_state.getVariable(assignment.name);
            try self.put(
                assignment.name,
                assignment.value,
                force_export or
                    shell_state.options.enabled(.allexport) or
                    (existing != null and existing.?.exported),
            );
        }
    }

    fn put(self: *TemporaryEnvironment, name: []const u8, value: []const u8, exported: bool) !void {
        state.assertValidVariableName(name);

        if (findTemporaryVariable(self, name)) |variable| {
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(variable.value);
            variable.value = owned_value;
            variable.exported = variable.exported or exported;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        try self.variables.append(self.allocator, .{
            .name = owned_name,
            .value = owned_value,
            .exported = exported,
        });
    }
};

pub const ProcessEnvironmentEntry = struct {
    name: []const u8,
    value: []const u8,

    pub fn validate(self: ProcessEnvironmentEntry) void {
        assertValidProcessEnvironmentName(self.name);
        std.debug.assert(std.mem.findScalar(u8, self.value, 0) == null);
    }
};

pub const ProcessEnvironmentOverlay = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ProcessEnvironmentEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProcessEnvironmentOverlay {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProcessEnvironmentOverlay) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn put(self: *ProcessEnvironmentOverlay, name: []const u8, value: []const u8) !void {
        assertValidProcessEnvironmentName(name);
        std.debug.assert(std.mem.findScalar(u8, value, 0) == null);

        if (findProcessEnvironmentEntry(self, name)) |entry| {
            const owned_value = try self.allocator.dupe(u8, value);
            self.allocator.free(entry.value);
            entry.value = owned_value;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.entries.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }
};

pub fn isProcessEnvironmentName(name: []const u8) bool {
    return name.len != 0 and
        std.mem.findScalar(u8, name, '=') == null and
        std.mem.findScalar(u8, name, 0) == null;
}

pub fn assertValidProcessEnvironmentName(name: []const u8) void {
    std.debug.assert(isProcessEnvironmentName(name));
}

pub const AssignmentEffects = struct {
    allocator: std.mem.Allocator,
    target: context.ExecutionTarget,
    effect: command_plan.AssignmentEffect,
    state_delta: delta.StateDelta,
    temporary_environment: TemporaryEnvironment,

    pub fn init(
        allocator: std.mem.Allocator,
        target: context.ExecutionTarget,
        effect: command_plan.AssignmentEffect,
    ) AssignmentEffects {
        return .{
            .allocator = allocator,
            .target = target,
            .effect = effect,
            .state_delta = delta.StateDelta.init(allocator, target),
            .temporary_environment = TemporaryEnvironment.init(allocator),
        };
    }

    pub fn deinit(self: *AssignmentEffects) void {
        self.state_delta.deinit();
        self.temporary_environment.deinit();
        self.* = undefined;
    }

    pub fn validate(self: AssignmentEffects) void {
        std.debug.assert(self.state_delta.target == self.target);
        switch (self.effect) {
            .none => {
                std.debug.assert(self.state_delta.isEmpty());
                std.debug.assert(self.temporary_environment.isEmpty());
            },
            .persistent => {
                std.debug.assert(self.temporary_environment.isEmpty());
            },
            .temporary => {
                std.debug.assert(self.state_delta.isEmpty());
            },
        }
    }

    pub fn commitOrDiscard(self: *AssignmentEffects, shell_state: *state.ShellState) !void {
        self.validate();
        if (self.target.allowsShellStateCommit()) {
            try self.state_delta.commit(shell_state, self.target);
        } else {
            self.state_delta.discard(self.target);
        }
    }
};

pub const AssignmentResult = union(enum) {
    effects: AssignmentEffects,
    failure: outcome.CommandOutcome,

    pub fn deinit(self: *AssignmentResult) void {
        switch (self.*) {
            .effects => |*effects| effects.deinit(),
            .failure => |*failure| failure.deinit(),
        }
        self.* = undefined;
    }
};

pub fn prepareCommandAssignments(
    allocator: std.mem.Allocator,
    shell_state: state.ShellState,
    plan: command_plan.CommandPlan,
) !AssignmentResult {
    plan.validate();

    if (delta.firstReadonlyAssignment(shell_state, plan.assignments)) |name| {
        return .{ .failure = try outcome.readonlyVariableFailure(allocator, plan.target, name) };
    }

    var effects = AssignmentEffects.init(allocator, plan.target, plan.assignmentEffect());
    errdefer effects.deinit();

    switch (plan.assignmentEffect()) {
        .none => {},
        .persistent => try effects.state_delta.appendPersistentCommandAssignments(shell_state, plan.assignments),
        .temporary => try effects.temporary_environment.appendCommandAssignments(shell_state, plan),
    }

    effects.validate();
    return .{ .effects = effects };
}

fn temporaryAssignmentsAreExported(plan: command_plan.CommandPlan) bool {
    return switch (plan.class()) {
        .external, .not_found => true,
        else => plan.target == .child_process,
    };
}

fn findTemporaryVariable(environment: *TemporaryEnvironment, name: []const u8) ?*TemporaryVariable {
    for (environment.variables.items) |*variable| {
        if (std.mem.eql(u8, variable.name, name)) return variable;
    }
    return null;
}

fn findProcessEnvironmentEntry(
    environment: *ProcessEnvironmentOverlay,
    name: []const u8,
) ?*ProcessEnvironmentEntry {
    for (environment.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn effectsFromResult(result: *AssignmentResult) !*AssignmentEffects {
    return switch (result.*) {
        .effects => |*effects| effects,
        .failure => error.TestUnexpectedResult,
    };
}

fn failureFromResult(result: *AssignmentResult) !*outcome.CommandOutcome {
    return switch (result.*) {
        .effects => error.TestUnexpectedResult,
        .failure => |*failure| failure,
    };
}

test "assignment-only commands persist assignments through StateDelta" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const assignments = [_]command_plan.Assignment{.{ .name = "FOO", .value = "bar" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments } });

    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
    defer result.deinit();
    const effects = try effectsFromResult(&result);

    try std.testing.expectEqual(command_plan.AssignmentEffect.persistent, effects.effect);
    try std.testing.expect(effects.temporary_environment.isEmpty());
    try effects.commitOrDiscard(&shell_state);

    try std.testing.expectEqual(delta.DeltaState.consumed, effects.state_delta.state);
    try std.testing.expectEqualStrings("bar", shell_state.getVariable("FOO").?.value);
    try std.testing.expect(!shell_state.getVariable("FOO").?.exported);
}

test "assignments before special builtins persist in the command target" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const assignments = [_]command_plan.Assignment{.{ .name = "SPECIAL", .value = "yes" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{":"},
    } });

    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
    defer result.deinit();
    const effects = try effectsFromResult(&result);

    try std.testing.expectEqual(command_plan.CommandClass.special_builtin, plan.class());
    try std.testing.expectEqual(command_plan.AssignmentEffect.persistent, effects.effect);
    try effects.commitOrDiscard(&shell_state);
    try std.testing.expectEqualStrings("yes", shell_state.getVariable("SPECIAL").?.value);
}

test "assignments before regular builtins are explicit temporary environments" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const assignments = [_]command_plan.Assignment{.{ .name = "TEMP", .value = "builtin" }};
    const argv = [_][]const u8{ "echo", "hello" };
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &argv,
    } });

    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
    defer result.deinit();
    const effects = try effectsFromResult(&result);

    try std.testing.expectEqual(command_plan.CommandClass.regular_builtin, plan.class());
    try std.testing.expectEqual(command_plan.AssignmentEffect.temporary, effects.effect);
    try std.testing.expect(effects.state_delta.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), effects.temporary_environment.variables.items.len);
    try std.testing.expectEqualStrings("builtin", effects.temporary_environment.variables.items[0].value);

    try effects.commitOrDiscard(&shell_state);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("TEMP"));
}

test "assignments before functions are temporary and do not mutate parent state" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const assignments = [_]command_plan.Assignment{.{ .name = "TEMP", .value = "function" }};
    const functions = [_]command_plan.FunctionDefinition{.{ .name = "fn" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &assignments, .argv = &[_][]const u8{"fn"} },
        .lookup = .{ .functions = &functions },
    });

    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
    defer result.deinit();
    const effects = try effectsFromResult(&result);

    try std.testing.expectEqual(command_plan.CommandClass.function, plan.class());
    try std.testing.expectEqual(command_plan.AssignmentEffect.temporary, effects.effect);
    try effects.commitOrDiscard(&shell_state);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("TEMP"));
}

test "assignments before externals are child temporary environments" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const assignments = [_]command_plan.Assignment{.{ .name = "TEMP", .value = "external" }};
    const externals = [_]command_plan.ExternalResolution{.{ .name = "exe", .path = "/bin/exe" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &assignments, .argv = &[_][]const u8{"exe"} },
        .lookup = .{ .externals = &externals },
    });

    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
    defer result.deinit();
    const effects = try effectsFromResult(&result);

    try std.testing.expectEqual(command_plan.CommandClass.external, plan.class());
    try std.testing.expectEqual(context.ExecutionTarget.child_process, effects.target);
    try std.testing.expectEqual(command_plan.AssignmentEffect.temporary, effects.effect);
    try std.testing.expect(effects.temporary_environment.variables.items[0].exported);

    try effects.commitOrDiscard(&shell_state);
    try std.testing.expectEqual(delta.DeltaState.consumed, effects.state_delta.state);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("TEMP"));
}

test "readonly assignment failures become diagnostics without partial mutation" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("RO", "old", .{});
    try shell_state.setVariableReadonly("RO");

    const assignments = [_]command_plan.Assignment{
        .{ .name = "A", .value = "new" },
        .{ .name = "RO", .value = "new" },
    };
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments } });

    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
    defer result.deinit();
    const failure = try failureFromResult(&result);

    try std.testing.expectEqual(@as(outcome.ExitStatus, 1), failure.status);
    try std.testing.expectEqualStrings("RO: readonly variable", failure.diagnostics.items[0].message);
    failure.discardDelta(.current_shell);

    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("A"));
    try std.testing.expectEqualStrings("old", shell_state.getVariable("RO").?.value);
}

test "readonly temporary assignments fail before command execution" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("RO", "old", .{});
    try shell_state.setVariableReadonly("RO");

    const assignments = [_]command_plan.Assignment{.{ .name = "RO", .value = "new" }};
    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = .{
        .assignments = &assignments,
        .argv = &[_][]const u8{"echo"},
    } });

    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
    defer result.deinit();
    const failure = try failureFromResult(&result);

    try std.testing.expectEqualStrings("RO: readonly variable", failure.diagnostics.items[0].message);
    failure.discardDelta(.current_shell);
    try std.testing.expectEqualStrings("old", shell_state.getVariable("RO").?.value);
}

test "assignment export behavior separates persistent state from temporary environments" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("EXISTING", "old", .{ .exported = true });
    shell_state.options.set(.allexport, true);

    const persistent_assignments = [_]command_plan.Assignment{
        .{ .name = "EXISTING", .value = "new" },
        .{ .name = "NEW", .value = "value" },
    };
    const persistent_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &persistent_assignments },
    });
    var persistent_result = try prepareCommandAssignments(std.testing.allocator, shell_state, persistent_plan);
    defer persistent_result.deinit();
    try (try effectsFromResult(&persistent_result)).commitOrDiscard(&shell_state);

    try std.testing.expect(shell_state.getVariable("EXISTING").?.exported);
    try std.testing.expect(shell_state.getVariable("NEW").?.exported);

    const temporary_assignments = [_]command_plan.Assignment{.{ .name = "ONLY_TEMP", .value = "value" }};
    const externals = [_]command_plan.ExternalResolution{.{ .name = "exe", .path = "/bin/exe" }};
    const temporary_plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .assignments = &temporary_assignments, .argv = &[_][]const u8{"exe"} },
        .lookup = .{ .externals = &externals },
    });
    var temporary_result = try prepareCommandAssignments(std.testing.allocator, shell_state, temporary_plan);
    defer temporary_result.deinit();
    const temporary_effects = try effectsFromResult(&temporary_result);

    try std.testing.expect(temporary_effects.temporary_environment.variables.items[0].exported);
    try temporary_effects.commitOrDiscard(&shell_state);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("ONLY_TEMP"));
}

test "assignment matrix preserves commit discard and readonly invariants" {
    const CommandCase = struct {
        argv: []const []const u8,
        functions: []const command_plan.FunctionDefinition = &.{},
        externals: []const command_plan.ExternalResolution = &.{},
        expected_class: command_plan.CommandClass,
        expected_effect: command_plan.AssignmentEffect,
    };

    const function_defs = [_]command_plan.FunctionDefinition{.{ .name = "fn" }};
    const external_defs = [_]command_plan.ExternalResolution{.{ .name = "exe", .path = "/bin/exe" }};
    const command_cases = [_]CommandCase{
        .{ .argv = &.{}, .expected_class = .assignment_only, .expected_effect = .persistent },
        .{ .argv = &[_][]const u8{":"}, .expected_class = .special_builtin, .expected_effect = .persistent },
        .{ .argv = &[_][]const u8{"echo"}, .expected_class = .regular_builtin, .expected_effect = .temporary },
        .{
            .argv = &[_][]const u8{"fn"},
            .functions = &function_defs,
            .expected_class = .function,
            .expected_effect = .temporary,
        },
        .{
            .argv = &[_][]const u8{"exe"},
            .externals = &external_defs,
            .expected_class = .external,
            .expected_effect = .temporary,
        },
    };
    const requested_targets = [_]context.ExecutionTarget{ .current_shell, .subshell, .child_process };
    const readonly_flags = [_]bool{ false, true };
    const allexport_flags = [_]bool{ false, true };

    for (command_cases) |case| {
        for (requested_targets) |requested_target| {
            for (readonly_flags) |readonly| {
                for (allexport_flags) |allexport| {
                    var shell_state = state.ShellState.init(std.testing.allocator);
                    defer shell_state.deinit();
                    shell_state.options.set(.allexport, allexport);
                    if (readonly) {
                        try shell_state.putVariable("A", "old", .{});
                        try shell_state.setVariableReadonly("A");
                    }

                    const assignments = [_]command_plan.Assignment{.{ .name = "A", .value = "new" }};
                    const plan = command_plan.classifyExpandedSimpleCommand(.{
                        .command = .{ .assignments = &assignments, .argv = case.argv },
                        .lookup = .{ .functions = case.functions, .externals = case.externals },
                        .target = requested_target,
                    });
                    try std.testing.expectEqual(case.expected_class, plan.class());
                    try std.testing.expectEqual(case.expected_effect, plan.assignmentEffect());

                    var result = try prepareCommandAssignments(std.testing.allocator, shell_state, plan);
                    defer result.deinit();

                    if (readonly) {
                        const failure = try failureFromResult(&result);
                        try std.testing.expectEqual(@as(outcome.ExitStatus, 1), failure.status);
                        failure.discardDelta(plan.target);
                        try std.testing.expectEqualStrings("old", shell_state.getVariable("A").?.value);
                        continue;
                    }

                    const effects = try effectsFromResult(&result);
                    try std.testing.expectEqual(case.expected_effect, effects.effect);

                    if (plan.target == .subshell) {
                        var subshell = try shell_state.snapshotForSubshell(std.testing.allocator);
                        defer subshell.deinit();
                        try effects.commitOrDiscard(&subshell);
                        if (case.expected_effect == .persistent) {
                            try std.testing.expectEqualStrings("new", subshell.getVariable("A").?.value);
                            try std.testing.expectEqual(allexport, subshell.getVariable("A").?.exported);
                        } else {
                            try std.testing.expectEqual(@as(?state.Variable, null), subshell.getVariable("A"));
                        }
                        try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("A"));
                    } else {
                        try effects.commitOrDiscard(&shell_state);
                        if (case.expected_effect == .persistent and plan.target == .current_shell) {
                            try std.testing.expectEqualStrings("new", shell_state.getVariable("A").?.value);
                            try std.testing.expectEqual(allexport, shell_state.getVariable("A").?.exported);
                        } else {
                            try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("A"));
                        }
                    }
                }
            }
        }
    }
}
