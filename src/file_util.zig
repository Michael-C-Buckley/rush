//! Small file helpers shared by invocation paths.

const std = @import("std");

const host = @import("host.zig");

/// Returns the complete file contents owned by `allocator`.
pub fn readFileAlloc(allocator: std.mem.Allocator, real_host: *host.RealHost, path: []const u8) ![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = try real_host.openZ(path_z, .{ .access = .read_only });
    defer real_host.close(fd) catch {};

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_len = try real_host.read(fd, &buffer);
        if (read_len == 0) break;
        try bytes.appendSlice(allocator, buffer[0..read_len]);
    }
    return bytes.toOwnedSlice(allocator);
}
