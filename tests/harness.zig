//! Minimal ZON-driven shell conformance harness.

const std = @import("std");

const Mode = enum {
    posix,
};

const Suite = struct {
    mode: Mode = .posix,
    cases: []const Case,
};

const Case = struct {
    name: []const u8,
    script: []const u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    status: u8 = 0,
};

const Config = struct {
    rush_path: ?[]const u8,
    shell: ?[]const u8,
    mode: Mode,
    files: []const []const u8,
};

const TempRoot = struct {
    path: []const u8,
    dir: std.Io.Dir,

    fn deinit(self: *TempRoot, allocator: std.mem.Allocator, io: std.Io) void {
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch |err| {
            std.debug.print("conformance: failed to remove temporary directory {s}: {s}\n", .{
                self.path,
                @errorName(err),
            });
        };
        allocator.free(self.path);
        self.* = undefined;
    }
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    status: u8,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed_config = parseArgs(args) orelse {
        try writeUsage(init.io);
        return 2;
    };
    const rush_path = if (parsed_config.rush_path) |path| try resolvePath(allocator, init.io, path) else null;
    defer if (rush_path) |path| allocator.free(path);
    const shell = if (parsed_config.shell) |path| try resolveCommandPath(allocator, init.io, path) else null;
    defer if (shell) |path| allocator.free(path);
    const config: Config = .{
        .rush_path = rush_path,
        .shell = shell,
        .mode = parsed_config.mode,
        .files = parsed_config.files,
    };

    var failures: usize = 0;
    for (config.files) |path| failures += try runSuiteFile(allocator, init.io, config, path);

    if (failures != 0) {
        std.debug.print("conformance: {d} failure(s)\n", .{failures});
        return 1;
    }
    std.debug.print("conformance: {d} file(s) passed\n", .{config.files.len});
    return 0;
}

fn parseArgs(args: []const []const u8) ?Config {
    if (args.len < 4) return null;
    var rush_path: ?[]const u8 = null;
    var shell: ?[]const u8 = null;
    var mode: ?Mode = null;
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--rush")) {
            index += 1;
            if (index >= args.len) return null;
            rush_path = args[index];
        } else if (std.mem.eql(u8, arg, "--shell")) {
            index += 1;
            if (index >= args.len) return null;
            shell = args[index];
        } else if (std.mem.eql(u8, arg, "--mode")) {
            index += 1;
            if (index >= args.len) return null;
            mode = parseMode(args[index]) orelse return null;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return null;
        } else {
            break;
        }
        index += 1;
    }
    if (index >= args.len) return null;
    if ((rush_path == null) == (shell == null)) return null;
    return .{
        .rush_path = rush_path,
        .shell = shell,
        .mode = mode orelse return null,
        .files = args[index..],
    };
}

fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "posix")) return .posix;
    return null;
}

fn resolvePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    if (std.Io.Dir.path.isAbsolute(path)) return allocator.dupeZ(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn resolveCommandPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null) return allocator.dupeZ(u8, path);
    return resolvePath(allocator, io, path);
}

fn runSuiteFile(allocator: std.mem.Allocator, io: std.Io, config: Config, path: []const u8) !usize {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(source);
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const suite = try std.zon.parse.fromSliceAlloc(Suite, arena.allocator(), source_z, null, .{});
    std.debug.assert(suite.mode == config.mode);

    var temp_root = try createTempRoot(allocator, io);
    defer temp_root.deinit(allocator, io);

    var failures: usize = 0;
    for (suite.cases, 0..) |case, case_index| {
        failures += try runCase(allocator, io, config, path, &temp_root, case, case_index);
    }
    return failures;
}

fn createTempRoot(allocator: std.mem.Allocator, io: std.Io) !TempRoot {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache");

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const random = std.mem.readInt(u64, &random_bytes, .little);
        const path = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/rush-conformance-{x}",
            .{random},
        );
        errdefer allocator.free(path);

        cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };

        return .{
            .path = path,
            .dir = try cwd.openDir(io, path, .{}),
        };
    }

    return error.TemporaryNameCollision;
}

fn runCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    path: []const u8,
    temp_root: *TempRoot,
    case: Case,
    case_index: usize,
) !usize {
    var failures: usize = 0;

    const target = try runTarget(allocator, io, temp_root, case_index, config, case.script);
    defer target.deinit(allocator);
    failures += reportMismatch(path, case, targetName(config), target);

    return failures;
}

fn targetName(config: Config) []const u8 {
    return config.shell orelse "rush";
}

fn runTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    case_index: usize,
    config: Config,
    script: []const u8,
) !RunResult {
    if (config.shell) |shell| {
        var sub_path_buffer: [64]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&sub_path_buffer, "case-{d}-shell", .{case_index});
        return runGenericShell(allocator, io, temp_root, sub_path, shell, script);
    }
    return runRush(allocator, io, temp_root, case_index, config, script);
}

fn runRush(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    case_index: usize,
    config: Config,
    script: []const u8,
) !RunResult {
    var sub_path_buffer: [64]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_path_buffer, "case-{d}-rush", .{case_index});
    var cwd = try temp_root.dir.createDirPathOpen(io, sub_path, .{});
    defer cwd.close(io);

    const argv = switch (config.mode) {
        .posix => &[_][]const u8{ config.rush_path.?, "--posix", "-c", script },
    };
    return runCommand(allocator, io, cwd, argv);
}

fn runGenericShell(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    sub_path: []const u8,
    shell: []const u8,
    script: []const u8,
) !RunResult {
    var cwd = try temp_root.dir.createDirPathOpen(io, sub_path, .{});
    defer cwd.close(io);

    const argv = [_][]const u8{ shell, "-c", script };
    return runCommand(allocator, io, cwd, &argv);
}

fn runCommand(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !RunResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .dir = cwd } });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .status = statusFromTerm(result.term),
    };
}

fn statusFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |status| status,
        .signal => |signal| signalStatus(@intFromEnum(signal)),
        .stopped => |signal| signalStatus(@intFromEnum(signal)),
        .unknown => 255,
    };
}

fn signalStatus(signal: u32) u8 {
    const value: u32 = 128 + signal;
    return if (value <= std.math.maxInt(u8)) @intCast(value) else std.math.maxInt(u8);
}

fn reportMismatch(path: []const u8, case: Case, shell_name: []const u8, actual: RunResult) usize {
    var failed = false;
    if (!std.mem.eql(u8, actual.stdout, case.stdout)) {
        failed = true;
        printBytesMismatch(path, case.name, shell_name, "stdout", case.stdout, actual.stdout);
    }
    if (!std.mem.eql(u8, actual.stderr, case.stderr)) {
        failed = true;
        printBytesMismatch(path, case.name, shell_name, "stderr", case.stderr, actual.stderr);
    }
    if (actual.status != case.status) {
        failed = true;
        std.debug.print(
            "{s}: {s}: {s}: status mismatch: expected {d}, got {d}\n",
            .{ path, case.name, shell_name, case.status, actual.status },
        );
    }
    return if (failed) 1 else 0;
}

fn printBytesMismatch(
    path: []const u8,
    case_name: []const u8,
    shell_name: []const u8,
    stream: []const u8,
    expected: []const u8,
    actual: []const u8,
) void {
    std.debug.print(
        "{s}: {s}: {s}: {s} mismatch\nexpected:\n{s}\nactual:\n{s}\n",
        .{ path, case_name, shell_name, stream, expected, actual },
    );
}

fn writeUsage(io: std.Io) !void {
    const usage =
        \\usage: conformance-harness (--rush PATH | --shell SHELL) --mode posix FILE...
        \\
    ;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.writeAll(usage);
    try writer.interface.flush();
}
