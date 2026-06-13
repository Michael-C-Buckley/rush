//! Result values produced by the redesigned semantic shell core.
//!
//! Outcomes keep ordinary shell diagnostics and control flow in data. Internal
//! model bugs remain assertions in the code that builds, commits, or discards
//! plans and deltas.

const delta = @import("delta.zig");

pub const ExitStatus = u8;

pub const Diagnostic = struct {
    message: []const u8,
};

pub const ControlFlow = union(enum) {
    normal,
    exit: ExitStatus,
    return_from_scope: ExitStatus,
    break_loop: u32,
    continue_loop: u32,
    fatal,
};

pub const CommandOutcome = struct {
    status: ExitStatus,
    diagnostics: []const Diagnostic = &.{},
    state_delta: delta.StateDelta,
    control_flow: ControlFlow = .normal,

    pub fn init(status: ExitStatus, state_delta: delta.StateDelta) CommandOutcome {
        return .{ .status = status, .state_delta = state_delta };
    }
};
