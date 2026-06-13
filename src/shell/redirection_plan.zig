//! Ordered descriptor mutation plans for the semantic shell core.
//!
//! Redirection planning preserves POSIX ordering and rollback obligations in
//! data. The actual descriptor syscalls belong to runtime ports and POSIX
//! adapters, not to this semantic module.

const fd = @import("../runtime/fd.zig");

pub const StepKind = enum {
    open,
    duplicate,
    close,
};

pub const RedirectionStep = struct {
    descriptor: fd.Descriptor,
    kind: StepKind,
};

pub const RedirectionPlan = struct {
    steps: []const RedirectionStep = &.{},
    rollback_steps: []const RedirectionStep = &.{},
};
