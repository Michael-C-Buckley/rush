//! File-descriptor runtime port vocabulary.
//!
//! Redirection and pipeline plans depend on this narrow descriptor abstraction;
//! concrete open/close/dup/pipe calls belong to the POSIX adapter.

const std = @import("std");

pub const Descriptor = std.posix.fd_t;

pub const Operation = enum {
    open,
    close,
    duplicate,
    pipe,
};

pub const Port = struct {};
