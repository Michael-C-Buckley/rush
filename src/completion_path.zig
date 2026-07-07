//! Filesystem lookup helpers for completion candidates.

const std = @import("std");

/// Expands the leading tilde forms supported by Rush while leaving candidate
/// spelling to the caller. The returned path is always allocator-owned.
pub fn expandLeadingTilde(
    allocator: std.mem.Allocator,
    path: []const u8,
    home: ?[]const u8,
) ![]u8 {
    const value = home orelse return allocator.dupe(u8, path);
    if (path.len == 0 or path[0] != '~') return allocator.dupe(u8, path);
    if (path.len != 1 and path[1] != '/') return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ value, path[1..] });
}

test "completion lookup expands only supported leading tilde forms" {
    const home_path = try expandLeadingTilde(std.testing.allocator, "~/.config", "/home/alice");
    defer std.testing.allocator.free(home_path);
    try std.testing.expectEqualStrings("/home/alice/.config", home_path);

    const named_user = try expandLeadingTilde(std.testing.allocator, "~bob/src", "/home/alice");
    defer std.testing.allocator.free(named_user);
    try std.testing.expectEqualStrings("~bob/src", named_user);

    const no_home = try expandLeadingTilde(std.testing.allocator, "~/src", null);
    defer std.testing.allocator.free(no_home);
    try std.testing.expectEqualStrings("~/src", no_home);
}
