//! Process-control runtime port vocabulary.
//!
//! The semantic shell core will ask this port to spawn/exec/wait and manage job
//! control primitives. This file intentionally contains no POSIX syscall
//! implementation; `posix.zig` owns that adapter role.

const std = @import("std");

pub const ProcessId = std.posix.pid_t;

pub const WaitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    stopped: u8,
};

pub const Port = struct {};
