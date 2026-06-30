//! Temporary executable facade for the shell rewrite.

const std = @import("std");

pub const editor = @import("editor.zig");
pub const event_loop = @import("event_loop.zig");
pub const history = @import("history.zig");
pub const shell = @import("shell.zig");

pub fn main(_: std.process.Init.Minimal) !u8 {
    return 2;
}
