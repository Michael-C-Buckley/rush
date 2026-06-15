//! Bundled Rush extension builtin sets.
//!
//! The POSIX shell core owns POSIX builtins and utilities. Rush-specific
//! conveniences live here so embedders can choose whether to include them.

const std = @import("std");
const shell_builtin = @import("shell/builtin.zig");

pub const color = @import("extensions/color.zig");
pub const compat = @import("extensions/compat.zig");
pub const editor = @import("extensions/editor.zig");

pub const default_builtins = editor.builtins ++ color.builtins ++ compat.builtins;
pub const default_registry: []const shell_builtin.Builtin = &default_builtins;

test "bundled Rush extensions classify their builtins as extensions" {
    for (default_registry) |definition| {
        try std.testing.expectEqual(shell_builtin.BuiltinOrigin.extension, definition.origin);
        try std.testing.expectEqual(shell_builtin.BuiltinKind.regular, definition.kind);
    }
}
