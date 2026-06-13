//! POSIX adapter surface for runtime ports.
//!
//! This is the layer that will translate runtime port requests into platform
//! syscalls and POSIX process behavior. It remains inert until behavior is
//! deliberately ported from the old executor.

const fd = @import("fd.zig");
const fs = @import("fs.zig");
const process = @import("process.zig");

pub const Adapter = struct {
    fd: fd.Port = .{},
    fs: fs.Port = .{},
    process: process.Port = .{},
};
