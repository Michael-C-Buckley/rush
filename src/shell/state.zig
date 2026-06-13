//! Authoritative mutable model for the redesigned semantic shell core.
//!
//! The old executor still owns behavior today. This placeholder only names the
//! state object that later semantic tasks will mutate through explicit
//! `StateDelta` commit points.

pub const ShellState = struct {
    pub fn init() ShellState {
        return .{};
    }
};
