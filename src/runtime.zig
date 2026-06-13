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
    fd: fd.Port,
    fs: fs.Port,
    process: process.Port,

    pub fn init(fd_port: fd.Port, fs_port: fs.Port, process_port: process.Port) Ports {
        return .{ .fd = fd_port, .fs = fs_port, .process = process_port };
    }
};

pub const Descriptor = fd.Descriptor;
pub const PosixAdapter = posix.Adapter;

pub fn posixPorts(adapter: *posix.Adapter) Ports {
    return Ports.init(adapter.fdPort(), adapter.fsPort(), adapter.processPort());
}
