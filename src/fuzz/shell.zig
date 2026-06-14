//! Shell semantic fuzz targets.
//!
//! These targets stay above POSIX effects: generated inputs exercise semantic
//! shell state and deltas through the public shell core rather than real host
//! descriptors, processes, or current-directory mutation.

const std = @import("std");

pub const shell = @import("rush-shell");

const variable_names = [_][]const u8{ "A", "B", "C", "PATH", "rush_var" };
const variable_values = [_][]const u8{ "", "0", "one", "two words", "*.zig", "$literal" };
const alias_names = [_][]const u8{ "ll", "g", "x-y", "run!" };
const alias_values = [_][]const u8{ "ls -l", "git", "echo ok", "printf %s" };
const shell_options = [_]shell.ShellOption{
    .allexport,
    .errexit,
    .ignoreeof,
    .monitor,
    .noclobber,
    .noexec,
    .noglob,
    .notify,
    .nounset,
    .pipefail,
    .verbose,
    .xtrace,
};

const VariableAction = enum {
    keep,
    assign,
    assign_exported,
    unset,
    export_enabled,
};

const AliasAction = enum {
    keep,
    set,
    unset,
};

const OptionAction = enum {
    keep,
    enable,
    disable,
};

const DeltaPlan = struct {
    variable_actions: [variable_names.len]VariableAction,
    variable_value_indexes: [variable_names.len]usize,
    alias_actions: [alias_names.len]AliasAction,
    alias_value_indexes: [alias_names.len]usize,
    option_actions: [shell_options.len]OptionAction,
    last_status: ?shell.ExitStatus,
};

test "fuzz shell delta commit and discard" {
    try std.testing.fuzz({}, fuzzShellDelta, .{});
}

fn fuzzShellDelta(_: void, smith: *std.testing.Smith) anyerror!void {
    var initial = shell.ShellState.init(std.testing.allocator);
    defer initial.deinit();
    try populateInitialState(smith, &initial);

    var discarded = try initial.clone(std.testing.allocator);
    defer discarded.deinit();

    var expected = try initial.clone(std.testing.allocator);
    defer expected.deinit();

    const plan = generateDeltaPlan(smith);

    var discard_delta = try stateDeltaFromPlan(plan);
    defer discard_delta.deinit();
    discard_delta.discard(.current_shell);
    try expectShellStatesEqual(initial, discarded);

    var commit_delta = try stateDeltaFromPlan(plan);
    defer commit_delta.deinit();
    try commit_delta.commit(&initial, .current_shell);
    try applyPlanToExpected(&expected, plan);

    try expectShellStatesEqual(expected, initial);
}

fn populateInitialState(smith: *std.testing.Smith, shell_state: *shell.ShellState) !void {
    for (variable_names) |name| {
        if (!smith.boolWeighted(1, 1)) continue;
        try shell_state.putVariable(name, pickValue(smith, &variable_values), .{
            .exported = smith.boolWeighted(1, 1),
        });
    }

    for (alias_names) |name| {
        if (!smith.boolWeighted(1, 2)) continue;
        try shell_state.setAlias(name, pickValue(smith, &alias_values));
    }

    for (shell_options) |option| shell_state.options.set(option, smith.boolWeighted(1, 1));
    shell_state.last_status = smith.value(shell.ExitStatus);
    shell_state.validate();
}

fn generateDeltaPlan(smith: *std.testing.Smith) DeltaPlan {
    var plan: DeltaPlan = undefined;
    for (&plan.variable_actions, &plan.variable_value_indexes) |*action, *value_index| {
        action.* = enumChoice(VariableAction, smith.index(@typeInfo(VariableAction).@"enum".fields.len));
        value_index.* = smith.index(variable_values.len);
    }
    for (&plan.alias_actions, &plan.alias_value_indexes) |*action, *value_index| {
        action.* = enumChoice(AliasAction, smith.index(@typeInfo(AliasAction).@"enum".fields.len));
        value_index.* = smith.index(alias_values.len);
    }
    for (&plan.option_actions) |*action| {
        action.* = enumChoice(OptionAction, smith.index(@typeInfo(OptionAction).@"enum".fields.len));
    }
    plan.last_status = if (smith.boolWeighted(1, 1)) smith.value(shell.ExitStatus) else null;
    return plan;
}

fn stateDeltaFromPlan(plan: DeltaPlan) !shell.delta.StateDelta {
    var state_delta = shell.delta.StateDelta.init(std.testing.allocator, .current_shell);
    errdefer state_delta.deinit();
    try appendPlanToDelta(&state_delta, plan);
    return state_delta;
}

fn appendPlanToDelta(state_delta: *shell.delta.StateDelta, plan: DeltaPlan) !void {
    for (variable_names, plan.variable_actions, plan.variable_value_indexes) |name, action, value_index| {
        const value = variable_values[value_index];
        switch (action) {
            .keep => {},
            .assign => try state_delta.assignVariable(name, value, .{}),
            .assign_exported => try state_delta.assignVariable(name, value, .{ .exported = true }),
            .unset => try state_delta.unsetVariable(name),
            .export_enabled => try state_delta.setVariableExported(name, true),
        }
    }

    for (shell_options, plan.option_actions) |option, action| {
        switch (action) {
            .keep => {},
            .enable => try state_delta.setOption(option, true),
            .disable => try state_delta.setOption(option, false),
        }
    }

    for (alias_names, plan.alias_actions, plan.alias_value_indexes) |name, action, value_index| {
        const value = alias_values[value_index];
        switch (action) {
            .keep => {},
            .set => try state_delta.setAlias(name, value),
            .unset => try state_delta.unsetAlias(name),
        }
    }

    if (plan.last_status) |status| state_delta.setLastStatus(status);
}

fn applyPlanToExpected(shell_state: *shell.ShellState, plan: DeltaPlan) !void {
    for (variable_names, plan.variable_actions, plan.variable_value_indexes) |name, action, value_index| {
        const value = variable_values[value_index];
        switch (action) {
            .keep => {},
            .assign => try shell_state.putVariable(name, value, .{}),
            .assign_exported => try shell_state.putVariable(name, value, .{ .exported = true }),
            .unset => try shell_state.unsetVariable(name),
            .export_enabled => try shell_state.setVariableExported(name, true),
        }
    }

    for (shell_options, plan.option_actions) |option, action| {
        switch (action) {
            .keep => {},
            .enable => shell_state.options.set(option, true),
            .disable => shell_state.options.set(option, false),
        }
    }

    for (alias_names, plan.alias_actions, plan.alias_value_indexes) |name, action, value_index| {
        const value = alias_values[value_index];
        switch (action) {
            .keep => {},
            .set => try shell_state.setAlias(name, value),
            .unset => _ = shell_state.unsetAlias(name),
        }
    }

    if (plan.last_status) |status| shell_state.last_status = status;
    shell_state.validate();
}

fn expectShellStatesEqual(expected: shell.ShellState, actual: shell.ShellState) !void {
    try std.testing.expectEqual(expected.scope, actual.scope);
    try std.testing.expectEqual(expected.options, actual.options);
    try std.testing.expectEqual(expected.last_status, actual.last_status);
    try std.testing.expectEqual(expected.pending_exit, actual.pending_exit);
    try std.testing.expectEqual(expected.variables.count(), actual.variables.count());
    try std.testing.expectEqual(expected.aliases.count(), actual.aliases.count());
    try std.testing.expectEqual(expected.functions.count(), actual.functions.count());
    try std.testing.expectEqual(expected.abbreviations.count(), actual.abbreviations.count());
    try std.testing.expectEqual(expected.traps.count(), actual.traps.count());
    try std.testing.expectEqual(expected.positionals.items.len, actual.positionals.items.len);
    try std.testing.expectEqual(expected.last_pipeline_statuses.items.len, actual.last_pipeline_statuses.items.len);
    try std.testing.expectEqual(expected.pending_traps.items.len, actual.pending_traps.items.len);

    var variables = expected.variables.iterator();
    while (variables.next()) |entry| {
        const actual_variable = actual.variables.get(entry.key_ptr.*) orelse return error.MissingVariable;
        try std.testing.expectEqualStrings(entry.value_ptr.value, actual_variable.value);
        try std.testing.expectEqual(entry.value_ptr.exported, actual_variable.exported);
        try std.testing.expectEqual(entry.value_ptr.readonly, actual_variable.readonly);
    }

    var aliases = expected.aliases.iterator();
    while (aliases.next()) |entry| {
        const actual_alias = actual.aliases.get(entry.key_ptr.*) orelse return error.MissingAlias;
        try std.testing.expectEqualStrings(entry.value_ptr.value, actual_alias.value);
    }
}

fn pickValue(smith: *std.testing.Smith, comptime values: []const []const u8) []const u8 {
    return values[smith.index(values.len)];
}

fn enumChoice(comptime T: type, index: usize) T {
    return @enumFromInt(index);
}
