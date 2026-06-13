//! Side-effect-free semantic command plans.
//!
//! `CommandPlan` is the core representation after parser/IR interpretation and
//! expansion and before runtime effects. It classifies expanded simple commands
//! without executing builtins, applying redirections, resolving the filesystem,
//! or mutating shell state.

const std = @import("std");
const builtin = @import("builtin.zig");
const context = @import("context.zig");
const redirection_plan = @import("redirection_plan.zig");
const state = @import("state.zig");

pub const Assignment = struct {
    name: []const u8,
    value: []const u8,

    pub fn validate(self: Assignment) void {
        state.assertValidVariableName(self.name);
    }
};

pub const FunctionDefinition = struct {
    name: []const u8,
    /// Borrowed semantic body for this redesign slice. Parser/IR integration
    /// will replace this with an owned lowered representation later.
    body: FunctionBody = .{},
    redirections: redirection_plan.RedirectionPlan = .{},

    pub fn validate(self: FunctionDefinition) void {
        state.assertValidVariableName(self.name);
        self.body.validate();
        validateRedirections(self.redirections);
        std.debug.assert(self.redirections.allocator == null);
    }

    pub fn hasExecutableBody(self: FunctionDefinition) bool {
        self.validate();
        return self.body.commands.len != 0;
    }
};

pub const FunctionBody = struct {
    commands: []const CommandPlan = &.{},

    pub fn validate(self: FunctionBody) void {
        for (self.commands) |command| command.validate();
    }
};

pub const ExternalResolution = struct {
    name: []const u8,
    path: []const u8,

    pub fn validate(self: ExternalResolution) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.path.len != 0);
    }
};

pub const NotFound = struct {
    name: []const u8,
};

pub const CommandClass = enum {
    empty,
    assignment_only,
    special_builtin,
    regular_builtin,
    function_definition,
    function,
    external,
    not_found,
};

pub const AssignmentEffect = enum {
    none,
    persistent,
    temporary,
};

pub const Classification = union(CommandClass) {
    /// No command name and no assignments. Redirections, if present, are kept
    /// as data for later redirection planning/evaluation tasks.
    empty: void,
    assignment_only: void,
    special_builtin: builtin.Builtin,
    regular_builtin: builtin.Builtin,
    function_definition: FunctionDefinition,
    function: FunctionDefinition,
    external: ExternalResolution,
    not_found: NotFound,
};

pub const ExpandedSimpleCommand = struct {
    assignments: []const Assignment = &.{},
    argv: []const []const u8 = &.{},
    redirections: redirection_plan.RedirectionPlan = .{},

    pub fn validate(self: ExpandedSimpleCommand) void {
        for (self.assignments) |assignment| assignment.validate();
        validateRedirections(self.redirections);
    }
};

pub const LookupSnapshot = struct {
    builtins: []const builtin.Builtin = builtin.default_registry,
    functions: []const FunctionDefinition = &.{},
    externals: []const ExternalResolution = &.{},

    pub fn validate(self: LookupSnapshot) void {
        builtin.assertUniqueNames(self.builtins);
        assertUniqueFunctionNames(self.functions);
        assertUniqueExternalNames(self.externals);
    }

    pub fn findSpecialBuiltin(self: LookupSnapshot, name: []const u8) ?builtin.Builtin {
        return self.findBuiltinWithKind(name, .special);
    }

    pub fn findRegularBuiltin(self: LookupSnapshot, name: []const u8) ?builtin.Builtin {
        return self.findBuiltinWithKind(name, .regular);
    }

    pub fn findFunction(self: LookupSnapshot, name: []const u8) ?FunctionDefinition {
        for (self.functions) |definition| {
            definition.validate();
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    pub fn findExternal(self: LookupSnapshot, name: []const u8) ?ExternalResolution {
        for (self.externals) |resolution| {
            resolution.validate();
            if (std.mem.eql(u8, resolution.name, name)) return resolution;
        }
        return null;
    }

    fn findBuiltinWithKind(self: LookupSnapshot, name: []const u8, kind: builtin.BuiltinKind) ?builtin.Builtin {
        for (self.builtins) |definition| {
            definition.validate();
            if (definition.kind == kind and std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }
};

pub const PlanRequest = struct {
    command: ExpandedSimpleCommand = .{},
    lookup: LookupSnapshot = .{},
    /// Target selected by the enclosing semantic context for commands that do
    /// not inherently require child execution. External commands are always
    /// planned for a child process because their shell-state mutations cannot
    /// land in the parent shell.
    target: context.ExecutionTarget = .current_shell,

    pub fn validate(self: PlanRequest) void {
        self.command.validate();
        self.lookup.validate();
    }
};

pub const CommandPlan = struct {
    target: context.ExecutionTarget,
    assignments: []const Assignment = &.{},
    argv: []const []const u8 = &.{},
    redirections: redirection_plan.RedirectionPlan = .{},
    classification: Classification,

    pub fn classify(request: PlanRequest) CommandPlan {
        request.validate();

        const command = request.command;
        const classification: Classification = if (command.argv.len == 0) blk: {
            if (command.assignments.len == 0) break :blk .{ .empty = {} };
            break :blk .{ .assignment_only = {} };
        } else blk: {
            const name = command.argv[0];
            if (!containsSlash(name)) {
                if (request.lookup.findSpecialBuiltin(name)) |definition| break :blk .{ .special_builtin = definition };
                if (request.lookup.findFunction(name)) |definition| break :blk .{ .function = definition };
                if (request.lookup.findRegularBuiltin(name)) |definition| break :blk .{ .regular_builtin = definition };
            }
            if (request.lookup.findExternal(name)) |resolution| break :blk .{ .external = resolution };
            break :blk .{ .not_found = .{ .name = name } };
        };

        const plan: CommandPlan = .{
            .target = targetForClassification(request.target, classification),
            .assignments = command.assignments,
            .argv = command.argv,
            .redirections = command.redirections,
            .classification = classification,
        };
        plan.validate();
        return plan;
    }

    pub fn class(self: CommandPlan) CommandClass {
        return switch (self.classification) {
            .empty => .empty,
            .assignment_only => .assignment_only,
            .special_builtin => .special_builtin,
            .regular_builtin => .regular_builtin,
            .function_definition => .function_definition,
            .function => .function,
            .external => .external,
            .not_found => .not_found,
        };
    }

    pub fn assignmentEffect(self: CommandPlan) AssignmentEffect {
        self.validate();
        if (self.assignments.len == 0) return .none;

        return switch (self.classification) {
            .empty => .none,
            .assignment_only, .special_builtin => .persistent,
            .function_definition => .none,
            .regular_builtin, .function, .external, .not_found => .temporary,
        };
    }

    pub fn validate(self: CommandPlan) void {
        for (self.assignments) |assignment| assignment.validate();
        validateRedirections(self.redirections);

        switch (self.classification) {
            .empty => {
                std.debug.assert(self.argv.len == 0);
                std.debug.assert(self.assignments.len == 0);
            },
            .assignment_only => {
                std.debug.assert(self.argv.len == 0);
                std.debug.assert(self.assignments.len != 0);
            },
            .special_builtin => |definition| {
                definition.validate();
                assertResolvedCommand(self.argv, definition.name);
                std.debug.assert(definition.kind == .special);
            },
            .regular_builtin => |definition| {
                definition.validate();
                assertResolvedCommand(self.argv, definition.name);
                std.debug.assert(definition.kind == .regular);
            },
            .function_definition => |definition| {
                definition.validate();
                std.debug.assert(self.argv.len == 0);
                std.debug.assert(self.assignments.len == 0);
                std.debug.assert(self.redirections.steps.len == 0);
                std.debug.assert(self.redirections.rollback_steps.len == 0);
            },
            .function => |definition| {
                definition.validate();
                assertResolvedCommand(self.argv, definition.name);
            },
            .external => |resolution| {
                resolution.validate();
                assertResolvedCommand(self.argv, resolution.name);
                std.debug.assert(self.target == .child_process);
            },
            .not_found => |not_found| {
                std.debug.assert(self.argv.len != 0);
                std.debug.assert(std.mem.eql(u8, self.argv[0], not_found.name));
            },
        }
    }
};

pub fn classifyExpandedSimpleCommand(request: PlanRequest) CommandPlan {
    return CommandPlan.classify(request);
}

fn targetForClassification(default_target: context.ExecutionTarget, classification: Classification) context.ExecutionTarget {
    return switch (classification) {
        .external => .child_process,
        else => default_target,
    };
}

fn containsSlash(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '/') != null;
}

fn assertResolvedCommand(argv: []const []const u8, name: []const u8) void {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], name));
}

fn validateRedirections(redirections: redirection_plan.RedirectionPlan) void {
    redirections.validate();
}

fn assertUniqueFunctionNames(functions: []const FunctionDefinition) void {
    for (functions, 0..) |left, left_index| {
        left.validate();
        for (functions[left_index + 1 ..]) |right| {
            right.validate();
            std.debug.assert(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

fn assertUniqueExternalNames(externals: []const ExternalResolution) void {
    for (externals, 0..) |left, left_index| {
        left.validate();
        for (externals[left_index + 1 ..]) |right| {
            right.validate();
            std.debug.assert(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

test "CommandPlan classifies expanded simple command shapes" {
    const assignments = [_]Assignment{.{ .name = "FOO", .value = "bar" }};
    const redirection_steps = [_]redirection_plan.RedirectionStep{redirection_plan.RedirectionStep.close(0, 1)};
    const rollback_steps = [_]redirection_plan.RestorationStep{.{ .ordinal = 0, .target = 1 }};
    const redirections: redirection_plan.RedirectionPlan = .{ .steps = &redirection_steps, .rollback_steps = &rollback_steps };
    const echo_argv = [_][]const u8{ "echo", "hello" };
    const function_argv = [_][]const u8{"say_hi"};
    const external_argv = [_][]const u8{ "cat", "file" };
    const missing_argv = [_][]const u8{"missing"};
    const functions = [_]FunctionDefinition{.{ .name = "say_hi" }};
    const externals = [_]ExternalResolution{.{ .name = "cat", .path = "/bin/cat" }};
    const lookup: LookupSnapshot = .{ .functions = &functions, .externals = &externals };

    const empty = classifyExpandedSimpleCommand(.{});
    try std.testing.expectEqual(CommandClass.empty, empty.class());
    try std.testing.expectEqual(context.ExecutionTarget.current_shell, empty.target);

    const redirection_only = classifyExpandedSimpleCommand(.{ .command = .{ .redirections = redirections } });
    try std.testing.expectEqual(CommandClass.empty, redirection_only.class());
    try std.testing.expectEqual(@as(usize, 1), redirection_only.redirections.steps.len);

    const assignment_only = classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments } });
    try std.testing.expectEqual(CommandClass.assignment_only, assignment_only.class());
    try std.testing.expectEqual(AssignmentEffect.persistent, assignment_only.assignmentEffect());
    try std.testing.expectEqual(@as(usize, 0), assignment_only.argv.len);

    const special = classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments, .argv = &[_][]const u8{"export"} } });
    try std.testing.expectEqual(CommandClass.special_builtin, special.class());
    try std.testing.expectEqual(AssignmentEffect.persistent, special.assignmentEffect());

    const regular = classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments, .argv = &echo_argv } });
    try std.testing.expectEqual(CommandClass.regular_builtin, regular.class());
    try std.testing.expectEqual(AssignmentEffect.temporary, regular.assignmentEffect());

    const function_plan = classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments, .argv = &function_argv }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.function, function_plan.class());
    try std.testing.expectEqual(AssignmentEffect.temporary, function_plan.assignmentEffect());

    const external = classifyExpandedSimpleCommand(.{ .command = .{ .assignments = &assignments, .argv = &external_argv }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.external, external.class());
    try std.testing.expectEqual(AssignmentEffect.temporary, external.assignmentEffect());
    try std.testing.expectEqual(context.ExecutionTarget.child_process, external.target);

    const not_found = classifyExpandedSimpleCommand(.{ .command = .{ .argv = &missing_argv }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.not_found, not_found.class());
    switch (not_found.classification) {
        .not_found => |resolution| try std.testing.expectEqualStrings("missing", resolution.name),
        else => return error.TestUnexpectedResult,
    }
}

test "CommandPlan lookup precedence is special builtin function regular builtin external" {
    const colliding_builtins = [_]builtin.Builtin{
        .{ .name = "special", .kind = .special },
        .{ .name = "regular", .kind = .regular },
        .{ .name = "only_builtin", .kind = .regular },
    };
    const functions = [_]FunctionDefinition{
        .{ .name = "special" },
        .{ .name = "regular" },
        .{ .name = "only_function" },
    };
    const externals = [_]ExternalResolution{
        .{ .name = "special", .path = "/bin/special" },
        .{ .name = "regular", .path = "/bin/regular" },
        .{ .name = "only_function", .path = "/bin/only_function" },
        .{ .name = "only_builtin", .path = "/bin/only_builtin" },
        .{ .name = "only_external", .path = "/bin/only_external" },
        .{ .name = "/bin/regular", .path = "/bin/regular" },
    };
    const lookup: LookupSnapshot = .{ .builtins = &colliding_builtins, .functions = &functions, .externals = &externals };

    const special = classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"special"} }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.special_builtin, special.class());

    const regular_collision = classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"regular"} }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.function, regular_collision.class());

    const builtin_collision = classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"only_builtin"} }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.regular_builtin, builtin_collision.class());

    const external = classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"only_external"} }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.external, external.class());

    const path_command = classifyExpandedSimpleCommand(.{ .command = .{ .argv = &[_][]const u8{"/bin/regular"} }, .lookup = lookup });
    try std.testing.expectEqual(CommandClass.external, path_command.class());
}

test "CommandPlan classification matrix is deterministic over command and lookup snapshots" {
    const assignment_sets = [_][]const Assignment{
        &.{},
        &[_]Assignment{.{ .name = "A", .value = "1" }},
    };
    const argv_sets = [_][]const []const u8{
        &.{},
        &[_][]const u8{"export"},
        &[_][]const u8{"fn"},
        &[_][]const u8{"echo"},
        &[_][]const u8{"exe"},
        &[_][]const u8{"missing"},
    };
    const function_sets = [_][]const FunctionDefinition{
        &.{},
        &[_]FunctionDefinition{ .{ .name = "fn" }, .{ .name = "echo" } },
    };
    const external_sets = [_][]const ExternalResolution{
        &.{},
        &[_]ExternalResolution{ .{ .name = "exe", .path = "/bin/exe" }, .{ .name = "echo", .path = "/bin/echo" } },
    };
    const targets = [_]context.ExecutionTarget{ .current_shell, .subshell, .child_process };

    for (assignment_sets) |assignments| {
        for (argv_sets) |argv| {
            for (function_sets) |functions| {
                for (external_sets) |externals| {
                    for (targets) |target| {
                        const request: PlanRequest = .{
                            .command = .{ .assignments = assignments, .argv = argv },
                            .lookup = .{ .functions = functions, .externals = externals },
                            .target = target,
                        };
                        const first = classifyExpandedSimpleCommand(request);
                        const second = classifyExpandedSimpleCommand(request);
                        first.validate();
                        second.validate();
                        try std.testing.expectEqual(first.class(), second.class());
                        try std.testing.expectEqual(first.target, second.target);
                        if (first.class() == .external) {
                            try std.testing.expectEqual(context.ExecutionTarget.child_process, first.target);
                        } else {
                            try std.testing.expectEqual(target, first.target);
                        }
                    }
                }
            }
        }
    }
}
