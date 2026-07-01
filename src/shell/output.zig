//! Shell output adapters backed by Host effects.

const std = @import("std");

const host_mod = @import("../host.zig");

pub fn HostFdWriter(comptime Host: type) type {
    return struct {
        host: *Host,
        fd: host_mod.Fd,
        buffer: [4096]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn append(self: *Self, allocator: std.mem.Allocator, byte: u8) !void {
            _ = allocator;
            try self.writeByte(byte);
        }

        pub fn appendSlice(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !void {
            _ = allocator;
            try self.writeAll(bytes);
        }

        pub fn appendNTimes(self: *Self, allocator: std.mem.Allocator, byte: u8, count: usize) !void {
            _ = allocator;
            var remaining = count;
            while (remaining != 0) {
                if (self.len == self.buffer.len) try self.flush();
                const write_len = @min(remaining, self.buffer.len - self.len);
                @memset(self.buffer[self.len..][0..write_len], byte);
                self.len += write_len;
                remaining -= write_len;
            }
        }

        pub fn writeByte(self: *Self, byte: u8) !void {
            if (self.len == self.buffer.len) try self.flush();
            self.buffer[self.len] = byte;
            self.len += 1;
        }

        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            if (bytes.len >= self.buffer.len) {
                try self.flush();
                try self.host.writeAll(self.fd, bytes);
                return;
            }

            if (bytes.len > self.buffer.len - self.len) try self.flush();
            @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        pub fn flush(self: *Self) !void {
            if (self.len == 0) return;
            try self.host.writeAll(self.fd, self.buffer[0..self.len]);
            self.len = 0;
        }
    };
}

test "HostFdWriter buffers writes until flush" {
    const TestHost = struct {
        bytes: std.ArrayList(u8) = .empty,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.bytes.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(self: *@This(), fd: host_mod.Fd, bytes: []const u8) !void {
            try std.testing.expectEqual(host_mod.Fd.stdout, fd);
            try self.bytes.appendSlice(std.testing.allocator, bytes);
        }
    };

    var host: TestHost = .{};
    defer host.deinit();

    var writer: HostFdWriter(TestHost) = .{ .host = &host, .fd = .stdout };
    try writer.writeAll("hello");
    try std.testing.expectEqualStrings("", host.bytes.items);
    try writer.flush();
    try std.testing.expectEqualStrings("hello", host.bytes.items);
}

test "HostFdWriter flushes repeated bytes in buffer-sized chunks" {
    const TestHost = struct {
        bytes: std.ArrayList(u8) = .empty,
        writes: usize = 0,

        // ziglint-ignore: Z020 Z030 test helper/reusable deinit; preserve behavior
        fn deinit(self: *@This()) void {
            self.bytes.deinit(std.testing.allocator);
        }

        // ziglint-ignore: Z020 test-local helper uses @This(); avoid non-semantic refactor
        pub fn writeAll(self: *@This(), fd: host_mod.Fd, bytes: []const u8) !void {
            try std.testing.expectEqual(host_mod.Fd.stdout, fd);
            try self.bytes.appendSlice(std.testing.allocator, bytes);
            self.writes += 1;
        }
    };

    var host: TestHost = .{};
    defer host.deinit();

    var writer: HostFdWriter(TestHost) = .{ .host = &host, .fd = .stdout };
    try writer.appendNTimes(std.testing.allocator, 'x', writer.buffer.len + 3);

    try std.testing.expectEqual(@as(usize, 1), host.writes);
    try std.testing.expectEqual(writer.buffer.len, host.bytes.items.len);
    try writer.flush();
    try std.testing.expectEqual(@as(usize, 2), host.writes);
    try std.testing.expectEqual(writer.buffer.len + 3, host.bytes.items.len);
    try std.testing.expect(std.mem.allEqual(u8, host.bytes.items, 'x'));
}
