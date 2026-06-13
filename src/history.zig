//! Command history interface types shared by execution and interactive glue.

const std = @import("std");

const ExitStatus = u8;

pub const HistoryEntry = struct {
    number: i64,
    command: []const u8,
};

pub const CommandHistory = struct {
    context: *anyopaque,
    list: *const fn (*anyopaque, std.mem.Allocator) anyerror![]HistoryEntry,
    append: ?*const fn (*anyopaque, std.Io, []const u8, ExitStatus, i64, i64) anyerror!void = null,
};
