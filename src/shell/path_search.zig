//! PATH search helpers shared by command-facing shell features.

const std = @import("std");

const runtime_fs = @import("../runtime/fs.zig");

pub const Executable = struct {
    directory: []const u8,
    name: []const u8,

    pub fn validate(self: Executable) void {
        std.debug.assert(self.directory.len != 0);
        std.debug.assert(self.name.len != 0);
    }
};

pub const Visitor = struct {
    context: *anyopaque,
    visit_fn: *const fn (*anyopaque, Executable) anyerror!void,

    pub fn visit(self: Visitor, executable: Executable) !void {
        executable.validate();
        try self.visit_fn(self.context, executable);
    }
};

pub fn scanPathExecutables(
    allocator: std.mem.Allocator,
    fs_port: runtime_fs.Port,
    path_value: []const u8,
    visitor: Visitor,
) !void {
    var path_iter = std.mem.splitScalar(u8, path_value, ':');
    while (path_iter.next()) |directory| {
        const dir_path = if (directory.len == 0) "." else directory;
        var entries = fs_port.listDir(.{
            .allocator = allocator,
            .path = dir_path,
            .attributes = .{ .kind = true, .executable = true },
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied => continue,
            else => return err,
        };
        defer entries.deinit();

        for (entries.entries) |entry| {
            if (entry.name.len == 0) continue;
            if (entry.kind == .directory) continue;
            if (entry.executable != true) continue;
            const executable: Executable = .{ .directory = dir_path, .name = entry.name };
            try visitor.visit(executable);
        }
    }
}

const TestCollector = struct {
    names: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *TestCollector, allocator: std.mem.Allocator) void {
        for (self.names.items) |name| allocator.free(name);
        self.names.deinit(allocator);
        self.* = undefined;
    }

    fn append(self: *TestCollector, allocator: std.mem.Allocator, name: []const u8) !void {
        try self.names.append(allocator, try allocator.dupe(u8, name));
    }
};

fn collectExecutable(context: *anyopaque, executable: Executable) !void {
    const collector: *TestCollector = @ptrCast(@alignCast(context));
    try collector.append(std.testing.allocator, executable.name);
}

test "PATH executable scanner visits executable non-directories" {
    const runtime_posix = @import("../runtime/posix.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var executable = try tmp.dir.createFile(std.testing.io, "rush-tool", .{ .permissions = .executable_file });
    executable.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "hello" });
    try tmp.dir.createDir(std.testing.io, "bin-dir", .default_dir);

    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];

    var adapter = runtime_posix.Adapter.init(std.testing.io);
    const fs_port = adapter.fsPort();
    var collector: TestCollector = .{};
    defer collector.deinit(std.testing.allocator);

    try scanPathExecutables(std.testing.allocator, fs_port, tmp_root, .{
        .context = &collector,
        .visit_fn = collectExecutable,
    });

    try std.testing.expectEqual(@as(usize, 1), collector.names.items.len);
    try std.testing.expectEqualStrings("rush-tool", collector.names.items[0]);
}
