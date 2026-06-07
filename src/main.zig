//! Application entry point.

const std = @import("std");

pub const parser = @import("parser.zig");
pub const ir = @import("ir.zig");

pub fn main() void {}

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(ir);
}
