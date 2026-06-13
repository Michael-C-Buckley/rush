//! Scoped evaluation context for semantic shell operations.
//!
//! `EvalContext` is the immutable frame that tells planning/evaluation where
//! mutations are allowed to land. It deliberately contains semantic facts, not
//! POSIX adapter objects.

pub const ExecutionTarget = enum {
    current_shell,
    subshell,
    child_process,
};

pub const InputSource = enum {
    command_string,
    script_file,
    standard_input,
    interactive,
};

pub const EvalContext = struct {
    target: ExecutionTarget,
    source: InputSource = .command_string,

    pub fn forTarget(target: ExecutionTarget) EvalContext {
        return .{ .target = target };
    }
};
