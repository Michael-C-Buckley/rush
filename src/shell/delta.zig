//! Explicit semantic mutation set for shell execution.
//!
//! Planning must not mutate `ShellState` directly. Later tasks will add concrete
//! mutations here; this skeleton already models the commit/discard boundary so
//! child and subshell deltas cannot silently leak into the current shell.

const std = @import("std");
const context = @import("context.zig");
const state = @import("state.zig");

pub const DeltaState = enum {
    pending,
    consumed,
};

pub const StateDelta = struct {
    target: context.ExecutionTarget,
    state: DeltaState = .pending,

    pub fn init(target: context.ExecutionTarget) StateDelta {
        return .{ .target = target };
    }

    pub fn commit(self: *StateDelta, shell_state: *state.ShellState, target: context.ExecutionTarget) void {
        std.debug.assert(self.state == .pending);
        std.debug.assert(self.target == target);
        _ = shell_state;
        self.state = .consumed;
    }

    pub fn discard(self: *StateDelta) void {
        std.debug.assert(self.state == .pending);
        self.state = .consumed;
    }
};
