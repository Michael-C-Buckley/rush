//! Facade for the redesigned runtime boundary.
//!
//! Runtime ports are the only dependency-injected imperative boundary beneath
//! the semantic shell core. POSIX adapters translate those ports into host
//! behavior; the shell core should not import adapters directly.

pub const fd = @import("runtime/fd.zig");
pub const fs = @import("runtime/fs.zig");
pub const posix = @import("runtime/posix.zig");
pub const process = @import("runtime/process.zig");

pub const Ports = struct {
    fd: fd.Port = .{},
    fs: fs.Port = .{},
    process: process.Port = .{},
};
