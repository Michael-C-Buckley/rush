//! Search paths for Rush-owned runtime assets.

const std = @import("std");
const build_config = @import("build_config");

const shell = @import("shell.zig");

pub const AssetKind = enum {
    completions,
    functions,

    fn directoryName(self: AssetKind) []const u8 {
        return switch (self) {
            .completions => "completions",
            .functions => "functions",
        };
    }
};

pub const SearchOrder = enum {
    config_first,
    data_first,
};

pub const SearchDirs = struct {
    allocator: std.mem.Allocator,
    paths: []const []const u8,

    pub fn deinit(self: *SearchDirs) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.* = undefined;
    }
};

pub fn searchDirs(
    allocator: std.mem.Allocator,
    shell_state: shell.ShellState,
    kind: AssetKind,
    order: SearchOrder,
) !SearchDirs {
    shell_state.validate();
    var config_dirs: std.ArrayList([]const u8) = .empty;
    defer freePathList(allocator, &config_dirs);
    var data_dirs: std.ArrayList([]const u8) = .empty;
    defer freePathList(allocator, &data_dirs);

    try appendUserConfigDir(allocator, shell_state, kind, &config_dirs);
    try appendPath(allocator, &config_dirs, &.{ build_config.sysconfdir, "rush", kind.directoryName() });

    try appendUserDataDir(allocator, shell_state, kind, &data_dirs);
    try appendXdgDataDirs(allocator, shell_state, kind, &data_dirs);
    try appendPath(allocator, &data_dirs, &.{ build_config.datadir, "rush", kind.directoryName() });

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer freePathList(allocator, &paths);
    switch (order) {
        .config_first => {
            try appendUniquePaths(allocator, &paths, config_dirs.items);
            try appendUniquePaths(allocator, &paths, data_dirs.items);
        },
        .data_first => {
            try appendUniquePaths(allocator, &paths, data_dirs.items);
            try appendUniquePaths(allocator, &paths, config_dirs.items);
        },
    }

    return .{ .allocator = allocator, .paths = try paths.toOwnedSlice(allocator) };
}

pub fn functionAutoload() shell.eval.FunctionAutoload {
    return .{ .lookup = functionAutoloadLookup };
}

fn functionAutoloadLookup(
    opaque_context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: shell.ShellState,
    name: []const u8,
) !?shell.eval.FunctionAutoloadSource {
    _ = opaque_context;
    var dirs = try searchDirs(allocator, shell_state, .functions, .config_first);
    defer dirs.deinit();

    const file_name = try std.fmt.allocPrint(allocator, "{s}.rush", .{name});
    defer allocator.free(file_name);
    for (dirs.paths) |dir| {
        const path = try std.fs.path.join(allocator, &.{ dir, file_name });
        errdefer allocator.free(path);
        const source = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            else => |read_err| return read_err,
        };
        return .{ .path = path, .source = source };
    }
    return null;
}

fn appendUserConfigDir(
    allocator: std.mem.Allocator,
    shell_state: shell.ShellState,
    kind: AssetKind,
    paths: *std.ArrayList([]const u8),
) !void {
    if (shell_state.getVariable("XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.value.len != 0) {
            return appendPath(allocator, paths, &.{ xdg_config_home.value, "rush", kind.directoryName() });
        }
    }
    if (shell_state.getVariable("HOME")) |home| {
        if (home.value.len != 0) {
            return appendPath(allocator, paths, &.{ home.value, ".config", "rush", kind.directoryName() });
        }
    }
}

fn appendUserDataDir(
    allocator: std.mem.Allocator,
    shell_state: shell.ShellState,
    kind: AssetKind,
    paths: *std.ArrayList([]const u8),
) !void {
    if (shell_state.getVariable("XDG_DATA_HOME")) |xdg_data_home| {
        if (xdg_data_home.value.len != 0) {
            return appendPath(allocator, paths, &.{ xdg_data_home.value, "rush", kind.directoryName() });
        }
    }
    if (shell_state.getVariable("HOME")) |home| {
        if (home.value.len != 0) {
            return appendPath(allocator, paths, &.{ home.value, ".local", "share", "rush", kind.directoryName() });
        }
    }
}

fn appendXdgDataDirs(
    allocator: std.mem.Allocator,
    shell_state: shell.ShellState,
    kind: AssetKind,
    paths: *std.ArrayList([]const u8),
) !void {
    const value = if (shell_state.getVariable("XDG_DATA_DIRS")) |xdg_data_dirs|
        xdg_data_dirs.value
    else
        "/usr/local/share:/usr/share";
    var parts = std.mem.splitScalar(u8, value, ':');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try appendPath(allocator, paths, &.{ part, "rush", kind.directoryName() });
    }
}

fn appendPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), parts: []const []const u8) !void {
    try paths.append(allocator, try std.fs.path.join(allocator, parts));
}

fn appendUniquePaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), candidates: []const []const u8) !void {
    for (candidates) |candidate| {
        if (pathListContains(paths.items, candidate)) continue;
        try paths.append(allocator, try allocator.dupe(u8, candidate));
    }
}

fn pathListContains(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, candidate)) return true;
    return false;
}

fn freePathList(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

test "Rush asset search dirs include config, system, xdg data, and build data" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("HOME", "/home/alice", .{});
    try shell_state.putVariable("XDG_CONFIG_HOME", "/cfg", .{});
    try shell_state.putVariable("XDG_DATA_HOME", "/data-home", .{});
    try shell_state.putVariable("XDG_DATA_DIRS", "/data-one:/data-two", .{});

    var dirs = try searchDirs(std.testing.allocator, shell_state, .functions, .config_first);
    defer dirs.deinit();

    try std.testing.expectEqualStrings("/cfg/rush/functions", dirs.paths[0]);
    try std.testing.expectEqualStrings(build_config.sysconfdir ++ "/rush/functions", dirs.paths[1]);
    try std.testing.expectEqualStrings("/data-home/rush/functions", dirs.paths[2]);
    try std.testing.expectEqualStrings("/data-one/rush/functions", dirs.paths[3]);
    try std.testing.expectEqualStrings("/data-two/rush/functions", dirs.paths[4]);
    try std.testing.expectEqualStrings(build_config.datadir ++ "/rush/functions", dirs.paths[5]);
    try std.testing.expectEqual(@as(usize, 6), dirs.paths.len);
}
