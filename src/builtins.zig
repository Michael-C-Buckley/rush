//! Default Rush builtin registry.
//!
//! This is the shell core's POSIX builtin set plus bundled Rush extensions. The
//! POSIX-only set remains available from `shell.builtin.posix_registry`.

const std = @import("std");
const shell_builtin = @import("shell/builtin.zig");
const extensions = @import("extensions.zig");

pub const default_builtins = shell_builtin.posix_builtins ++ extensions.default_builtins;
pub const default_registry: []const shell_builtin.Builtin = &default_builtins;

pub fn lookup(name: []const u8) ?shell_builtin.Builtin {
    return shell_builtin.lookupIn(default_registry, name);
}

pub fn isSpecialBuiltin(name: []const u8) bool {
    const definition = lookup(name) orelse return false;
    return definition.kind == .special;
}

pub fn defaultRegistry(allocator: std.mem.Allocator) !shell_builtin.BuiltinRegistry {
    var registry = shell_builtin.BuiltinRegistry.init(allocator);
    errdefer registry.deinit();
    try registry.registerSlice(shell_builtin.posix_registry);
    try registry.registerSlice(extensions.default_registry);
    return registry;
}

test "default Rush registry combines POSIX core and bundled extensions" {
    shell_builtin.assertUniqueNames(default_registry);

    const core = lookup("printf") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(shell_builtin.BuiltinOrigin.posix, core.origin);

    const extension = lookup("abbr") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(shell_builtin.BuiltinOrigin.extension, extension.origin);
}

test "default Rush registry can be materialized for embedders" {
    var registry = try defaultRegistry(std.testing.allocator);
    defer registry.deinit();

    const core = registry.lookup("printf") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(shell_builtin.BuiltinOrigin.posix, core.origin);

    const extension = registry.lookup("abbr") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(shell_builtin.BuiltinOrigin.extension, extension.origin);
}
