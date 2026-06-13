//! Filesystem runtime port vocabulary.
//!
//! The semantic shell core will use this boundary for cwd and environment-facing
//! filesystem effects. POSIX path/syscall details stay in the adapter layer.

pub const Path = []const u8;

pub const Operation = enum {
    get_cwd,
    set_cwd,
    inspect_path,
};

pub const Port = struct {};
