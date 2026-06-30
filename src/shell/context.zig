//! Scoped evaluation context for semantic shell operations.
//!
//! `EvalContext` is the immutable frame that tells planning/evaluation where
//! mutations are allowed to land. It deliberately contains semantic facts, not
//! POSIX adapter objects.

const std = @import("std");
const compat = @import("compat.zig");

pub const ExecutionTarget = enum {
    current_shell,
    subshell,
    child_process,

    pub fn allowsShellStateCommit(self: ExecutionTarget) bool {
        return switch (self) {
            .current_shell, .subshell => true,
            .child_process => false,
        };
    }

    pub fn isIsolatedFromParent(self: ExecutionTarget) bool {
        return switch (self) {
            .current_shell => false,
            .subshell, .child_process => true,
        };
    }
};

pub const InputSource = enum {
    command_string,
    script_file,
    standard_input,
    interactive,
};

pub const InvocationContext = struct {
    features: compat.Features = .{},
    arg_zero: []const u8 = "rush",
    source: InputSource = .command_string,
    interactive: bool = false,
    /// Borrowed handle for the original stdin script stream. The context does
    /// not own or close it; entry-point execution glue uses it only to keep the
    /// underlying stdin offset synchronized when script commands also read from
    /// stdin.
    stdin_script_file: ?std.Io.File = null,
    stdin_script_source_offset: usize = 0,

    pub const Init = struct {
        features: compat.Features = .{},
        arg_zero: []const u8 = "rush",
        source: InputSource = .command_string,
        interactive: bool = false,
        /// Borrowed handle for the original stdin script stream. The context
        /// does not own or close it.
        stdin_script_file: ?std.Io.File = null,
        stdin_script_source_offset: usize = 0,
    };

    pub fn init(options: Init) InvocationContext {
        const invocation: InvocationContext = .{
            .features = options.features,
            .arg_zero = options.arg_zero,
            .source = options.source,
            .interactive = options.interactive,
            .stdin_script_file = options.stdin_script_file,
            .stdin_script_source_offset = options.stdin_script_source_offset,
        };
        invocation.validate();
        return invocation;
    }

    pub fn evalContext(self: InvocationContext, target: ExecutionTarget) EvalContext {
        self.validate();
        return EvalContext.init(.{
            .target = target,
            .features = self.features,
            .source = self.source,
            .interactive = self.interactive,
        });
    }

    pub fn validate(self: InvocationContext) void {
        std.debug.assert(self.arg_zero.len != 0);
        std.debug.assert(std.mem.indexOfScalar(u8, self.arg_zero, 0) == null);
        if (self.source != .standard_input) std.debug.assert(self.stdin_script_file == null);
        if (self.stdin_script_file == null) std.debug.assert(self.stdin_script_source_offset == 0);
    }
};

pub const EvalContext = struct {
    target: ExecutionTarget,
    features: compat.Features = .{},
    source: InputSource = .command_string,
    interactive: bool = false,
    errexit_ignored: bool = false,
    loop_depth: u32 = 0,
    function_depth: u32 = 0,
    source_depth: u32 = 0,
    subshell_depth: u32 = 0,
    pipeline_depth: u32 = 0,
    command_substitution_depth: u32 = 0,
    special_builtin: bool = false,

    pub fn forTarget(target: ExecutionTarget) EvalContext {
        return EvalContext.init(.{ .target = target });
    }

    pub const Init = struct {
        target: ExecutionTarget,
        features: compat.Features = .{},
        source: InputSource = .command_string,
        interactive: bool = false,
        errexit_ignored: bool = false,
        loop_depth: u32 = 0,
        function_depth: u32 = 0,
        source_depth: u32 = 0,
        subshell_depth: u32 = 0,
        pipeline_depth: u32 = 0,
        command_substitution_depth: u32 = 0,
        special_builtin: bool = false,
    };

    pub fn init(options: Init) EvalContext {
        const eval_context: EvalContext = .{
            .target = options.target,
            .features = options.features,
            .source = options.source,
            .interactive = options.interactive,
            .errexit_ignored = options.errexit_ignored,
            .loop_depth = options.loop_depth,
            .function_depth = options.function_depth,
            .source_depth = options.source_depth,
            .subshell_depth = options.subshell_depth,
            .pipeline_depth = options.pipeline_depth,
            .command_substitution_depth = options.command_substitution_depth,
            .special_builtin = options.special_builtin,
        };
        eval_context.validate();
        return eval_context;
    }

    pub fn withTarget(self: EvalContext, target: ExecutionTarget) EvalContext {
        var next = self;
        next.target = target;
        next.validate();
        return next;
    }

    pub fn enterLoop(self: EvalContext) EvalContext {
        var next = self;
        next.loop_depth = checkedIncrement(next.loop_depth);
        next.validate();
        return next;
    }

    pub fn enterFunction(self: EvalContext) EvalContext {
        var next = self;
        next.function_depth = checkedIncrement(next.function_depth);
        next.loop_depth = 0;
        next.source_depth = 0;
        next.validate();
        return next;
    }

    pub fn enterSource(self: EvalContext) EvalContext {
        var next = self;
        next.source_depth = checkedIncrement(next.source_depth);
        next.validate();
        return next;
    }

    pub fn enterSubshell(self: EvalContext) EvalContext {
        var next = self.withTarget(.subshell);
        next.subshell_depth = checkedIncrement(next.subshell_depth);
        next.loop_depth = 0;
        next.validate();
        return next;
    }

    pub fn enterPipeline(self: EvalContext) EvalContext {
        var next = self;
        next.pipeline_depth = checkedIncrement(next.pipeline_depth);
        next.validate();
        return next;
    }

    pub fn enterCommandSubstitution(self: EvalContext) EvalContext {
        var next = self.withTarget(.subshell);
        next.command_substitution_depth = checkedIncrement(next.command_substitution_depth);
        next.validate();
        return next;
    }

    pub fn ignoreErrexit(self: EvalContext) EvalContext {
        var next = self;
        next.errexit_ignored = true;
        next.validate();
        return next;
    }

    pub fn enterSpecialBuiltin(self: EvalContext) EvalContext {
        var next = self;
        next.special_builtin = true;
        next.validate();
        return next;
    }

    pub fn observesErrexit(self: EvalContext) bool {
        self.validate();
        return !self.errexit_ignored;
    }

    pub fn canReturnFromFunction(self: EvalContext) bool {
        return self.function_depth != 0;
    }

    pub fn canReturnFromSource(self: EvalContext) bool {
        return self.source_depth != 0;
    }

    pub fn canBreakOrContinue(self: EvalContext, depth: u32) bool {
        std.debug.assert(depth != 0);
        return depth <= self.loop_depth;
    }

    pub fn validate(self: EvalContext) void {
        if (self.command_substitution_depth != 0) {
            std.debug.assert(self.target != .current_shell);
        }
    }
};

fn checkedIncrement(value: u32) u32 {
    std.debug.assert(value != std.math.maxInt(u32));
    return value + 1;
}

test "EvalContext constructors preserve target and scoped nesting invariants" {
    const root = EvalContext.forTarget(.current_shell);
    try std.testing.expectEqual(ExecutionTarget.current_shell, root.target);
    try std.testing.expect(!root.target.isIsolatedFromParent());
    try std.testing.expect(root.target.allowsShellStateCommit());

    const loop_context = root.enterLoop().enterLoop();
    try std.testing.expect(loop_context.canBreakOrContinue(1));
    try std.testing.expect(loop_context.canBreakOrContinue(2));
    try std.testing.expect(!loop_context.canBreakOrContinue(3));
    try std.testing.expect(!loop_context.enterSubshell().canBreakOrContinue(1));

    const function_context = root.enterFunction();
    try std.testing.expect(function_context.canReturnFromFunction());
    try std.testing.expect(!function_context.canReturnFromSource());

    const source_context = root.enterSource();
    try std.testing.expect(source_context.canReturnFromSource());

    const source_function_context = source_context.enterFunction();
    try std.testing.expect(source_function_context.canReturnFromFunction());
    try std.testing.expect(!source_function_context.canReturnFromSource());

    const command_substitution = root.enterCommandSubstitution();
    try std.testing.expectEqual(ExecutionTarget.subshell, command_substitution.target);
    try std.testing.expect(command_substitution.target.isIsolatedFromParent());
    try std.testing.expectEqual(@as(u32, 1), command_substitution.command_substitution_depth);

    const subshell_child = root.enterSubshell().withTarget(.child_process);
    try std.testing.expectEqual(ExecutionTarget.child_process, subshell_child.target);
    try std.testing.expectEqual(@as(u32, 1), subshell_child.subshell_depth);

    const ignored = root.ignoreErrexit();
    try std.testing.expect(ignored.errexit_ignored);
    try std.testing.expect(!ignored.observesErrexit());
    try std.testing.expect(root.observesErrexit());
}

test "ExecutionTarget commit permissions are explicit" {
    const targets = [_]ExecutionTarget{ .current_shell, .subshell, .child_process };
    const expected_commit = [_]bool{ true, true, false };
    const expected_isolated = [_]bool{ false, true, true };

    for (targets, expected_commit, expected_isolated) |target, can_commit, isolated| {
        try std.testing.expectEqual(can_commit, target.allowsShellStateCommit());
        try std.testing.expectEqual(isolated, target.isIsolatedFromParent());
    }
}
