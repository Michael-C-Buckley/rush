//! Shell startup state initialization.

const std = @import("std");
const build_options = @import("builtin");

const state = @import("state.zig");

pub fn initializeInvocationState(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *state.ShellState,
    environ_map: ?*const std.process.Environ.Map,
    positionals: []const []const u8,
    shell_options: state.ShellOptions,
) !void {
    shell_state.validate();
    shell_state.options = shell_options;

    if (environ_map) |map| {
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            if (!isValidVariableName(entry.key_ptr.*)) continue;
            if (std.mem.indexOfScalar(u8, entry.value_ptr.*, 0) != null) continue;
            try shell_state.putVariable(entry.key_ptr.*, entry.value_ptr.*, .{ .exported = true });
        }
    }

    try initializeShellLevel(shell_state);
    try shell_state.putVariable("IFS", " \t\n", .{});
    try shell_state.putVariable("OPTIND", "1", .{});
    if (shell_state.getVariable("PS4") == null) try shell_state.putVariable("PS4", "+ ", .{});

    var ppid_buffer: [32]u8 = undefined;
    const ppid = try std.fmt.bufPrint(&ppid_buffer, "{d}", .{std.posix.getppid()});
    try shell_state.putVariable("PPID", ppid, .{});

    if (shell_state.getVariable("PWD")) |pwd| {
        if (isValidLogicalPwd(allocator, pwd.value)) {
            try shell_state.setLogicalCwd(pwd.value);
        } else {
            try setSemanticPhysicalPwd(allocator, io, shell_state);
        }
    } else {
        try setSemanticPhysicalPwd(allocator, io, shell_state);
    }

    try shell_state.replacePositionals(positionals);
    shell_state.validate();
}

pub fn initializeInteractiveState(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *state.ShellState,
    environ_map: *const std.process.Environ.Map,
    positionals: []const []const u8,
    shell_options: state.ShellOptions,
) !void {
    try initializeInvocationState(allocator, io, shell_state, environ_map, positionals, shell_options);
    shell_state.validate();
}

fn initializeShellLevel(shell_state: *state.ShellState) !void {
    const inherited = if (shell_state.getVariable("SHLVL")) |variable| variable.value else null;
    const level = nextStartupShellLevel(inherited);
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{level});
    try shell_state.putVariable("SHLVL", text, .{ .exported = true });
}

fn setSemanticPhysicalPwd(allocator: std.mem.Allocator, io: std.Io, shell_state: *state.ShellState) !void {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    try shell_state.putVariable("PWD", cwd, .{ .exported = true });
    try shell_state.setLogicalCwd(cwd);
}

fn nextStartupShellLevel(inherited: ?[]const u8) i64 {
    const level = if (inherited) |text| parseShellLevel(text) orelse return 1 else return 1;
    return std.math.add(i64, level, 1) catch 1;
}

fn parseShellLevel(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var index: usize = 0;
    if (text[0] == '+' or text[0] == '-') {
        if (text.len == 1) return null;
        index = 1;
    }
    while (index < text.len) : (index += 1) {
        if (!std.ascii.isDigit(text[index])) return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn isValidLogicalPwd(allocator: std.mem.Allocator, pwd: []const u8) bool {
    if (pwd.len == 0 or pwd[0] != '/') return false;
    var parts = std.mem.splitScalar(u8, pwd, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return sameExistingFile(allocator, pwd, ".") orelse false;
}

const FileIdentity = struct {
    device: u64,
    inode: u64,
};

fn sameExistingFile(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ?bool {
    const lhs = fileIdentity(allocator, left) orelse return null;
    const rhs = fileIdentity(allocator, right) orelse return null;
    return lhs.device == rhs.device and lhs.inode == rhs.inode;
}

fn fileIdentity(allocator: std.mem.Allocator, path: []const u8) ?FileIdentity {
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(path_z);

    if (comptime build_options.os.tag == .linux) {
        var statx_result: std.os.linux.Statx = undefined;
        if (std.c.statx(std.c.AT.FDCWD, path_z.ptr, 0, std.os.linux.STATX.BASIC_STATS, &statx_result) != 0) return null;
        return .{
            .device = (@as(u64, statx_result.dev_major) << 32) | statx_result.dev_minor,
            .inode = statx_result.ino,
        };
    }

    var stat_result: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat_result, 0) != 0) return null;
    const device_int = @Int(.unsigned, @bitSizeOf(@TypeOf(stat_result.dev)));
    const inode_int = @Int(.unsigned, @bitSizeOf(@TypeOf(stat_result.ino)));
    return .{
        .device = @as(u64, @as(device_int, @bitCast(stat_result.dev))),
        .inode = @as(u64, @as(inode_int, @bitCast(stat_result.ino))),
    };
}

pub fn isValidVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}
