//! Benchmark current Rush glob expansion against macOS `getattrlistbulk` listing.

const std = @import("std");
const builtin = @import("builtin");

const expand = @import("rush_expand");
const runtime_posix = @import("rush_runtime_posix");

const c = if (builtin.os.tag == .macos) @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/attr.h");
    @cInclude("sys/unistd.h");
    @cInclude("unistd.h");
}) else struct {};

const default_entries = 20_000;
const default_iterations = 20;
const default_dir = ".zig-cache/rush-glob-bench";
const default_pattern = "file-*.tmp";
const bulk_buffer_len = 1024 * 1024;

const Options = struct {
    entries: usize = default_entries,
    iterations: usize = default_iterations,
    dir: []const u8 = default_dir,
    pattern: []const u8 = default_pattern,
    keep: bool = false,
};

const RunResult = struct {
    matches: usize,
    elapsed_ns: i128,
};

const BulkStats = struct {
    calls: usize = 0,
    eof_calls: usize = 0,
    entries_returned: usize = 0,
    records_parsed: usize = 0,
    max_entries_per_call: usize = 0,

    fn recordCall(self: *BulkStats, count: c_int) void {
        self.calls += 1;
        if (count == 0) {
            self.eof_calls += 1;
            return;
        }
        const entries: usize = @intCast(count);
        self.entries_returned += entries;
        self.max_entries_per_call = @max(self.max_entries_per_call, entries);
    }
};

const BulkRunResult = struct {
    run: RunResult,
    stats: BulkStats,
};

const SizeRunResult = struct {
    matches: usize,
    total_size: u64,
    elapsed_ns: i128,
};

const BulkSizeRunResult = struct {
    run: SizeRunResult,
    stats: BulkStats,
};

const PathRunResult = struct {
    executables: usize,
    elapsed_ns: i128,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) catch |err| {
        try printUsage(init.io, args[0], err);
        return 2;
    };
    if (options.iterations == 0 or options.entries == 0) {
        try printUsage(init.io, args[0], error.InvalidCount);
        return 2;
    }

    try prepareFixture(init.io, options);
    defer if (!options.keep) cleanupFixture(init.io, options.dir);

    const pattern_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ options.dir, options.pattern });
    defer allocator.free(pattern_path);

    const current_warmup = try currentRushGlob(allocator, init.io, pattern_path);
    defer freeMatches(allocator, current_warmup);
    const bulk_warmup = try macosBulkGlob(allocator, options.dir, options.pattern, null);
    defer freeMatches(allocator, bulk_warmup);
    try expectSameMatches(current_warmup, bulk_warmup);

    const current = try benchmarkCurrent(allocator, init.io, pattern_path, options.iterations);
    const bulk = try benchmarkBulk(allocator, init.io, options.dir, options.pattern, options.iterations);
    const current_size = try benchmarkCurrentSize(allocator, init.io, pattern_path, options.iterations);
    const bulk_size = try benchmarkBulkSize(allocator, init.io, options.dir, options.pattern, options.iterations);
    if (current_size.matches != bulk_size.run.matches or current_size.total_size != bulk_size.run.total_size) {
        return error.MetadataMismatch;
    }
    const path_old = try benchmarkPathOld(init.io, options.dir, options.iterations);
    const path_new = try benchmarkPathListDir(allocator, init.io, options.dir, options.iterations);
    if (path_old.executables != path_new.executables) return error.ExecutableCountMismatch;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};
    const writer = &stdout.interface;

    try writer.print("glob benchmark fixture: {s}\n", .{options.dir});
    try writer.print("entries: {} pattern: {s} iterations: {} matches: {}\n", .{
        options.entries,
        options.pattern,
        options.iterations,
        current.matches,
    });
    try writer.print("current Rush glob:       {d:.3} ms total  {d:.3} ms/iter\n", .{
        nsToMs(current.elapsed_ns),
        nsToMs(@divTrunc(current.elapsed_ns, @as(i128, @intCast(options.iterations)))),
    });
    try writer.print("macOS getattrlistbulk:   {d:.3} ms total  {d:.3} ms/iter\n", .{
        nsToMs(bulk.run.elapsed_ns),
        nsToMs(@divTrunc(bulk.run.elapsed_ns, @as(i128, @intCast(options.iterations)))),
    });
    try writer.print(
        "  bulk calls:           {} total  {d:.2} calls/iter  {} eof  {} max entries/call\n",
        .{
            bulk.stats.calls,
            @as(f64, @floatFromInt(bulk.stats.calls)) / @as(f64, @floatFromInt(options.iterations)),
            bulk.stats.eof_calls,
            bulk.stats.max_entries_per_call,
        },
    );
    try writer.print("  bulk entries:         {} returned  {} parsed  {d:.2} entries/call\n", .{
        bulk.stats.entries_returned,
        bulk.stats.records_parsed,
        entriesPerPositiveCall(bulk.stats),
    });
    try writer.print("speedup:                 {d:.2}x\n", .{
        @as(f64, @floatFromInt(current.elapsed_ns)) / @as(f64, @floatFromInt(bulk.run.elapsed_ns)),
    });
    try writer.print("\nsize metadata benchmark:\n", .{});
    try writer.print("current glob + stat:    {d:.3} ms total  {d:.3} ms/iter  size={}\n", .{
        nsToMs(current_size.elapsed_ns),
        nsToMs(@divTrunc(current_size.elapsed_ns, @as(i128, @intCast(options.iterations)))),
        current_size.total_size,
    });
    try writer.print("macOS bulk name+size:   {d:.3} ms total  {d:.3} ms/iter  size={}\n", .{
        nsToMs(bulk_size.run.elapsed_ns),
        nsToMs(@divTrunc(bulk_size.run.elapsed_ns, @as(i128, @intCast(options.iterations)))),
        bulk_size.run.total_size,
    });
    try writer.print("  bulk calls:           {} total  {d:.2} calls/iter  {} eof  {} max entries/call\n", .{
        bulk_size.stats.calls,
        @as(f64, @floatFromInt(bulk_size.stats.calls)) / @as(f64, @floatFromInt(options.iterations)),
        bulk_size.stats.eof_calls,
        bulk_size.stats.max_entries_per_call,
    });
    try writer.print("speedup:                 {d:.2}x\n", .{
        @as(f64, @floatFromInt(current_size.elapsed_ns)) /
            @as(f64, @floatFromInt(bulk_size.run.elapsed_ns)),
    });
    try writer.print("\nPATH executable scan benchmark:\n", .{});
    try writer.print("old iterator + access:  {d:.3} ms total  {d:.3} ms/iter  executables={}\n", .{
        nsToMs(path_old.elapsed_ns),
        nsToMs(@divTrunc(path_old.elapsed_ns, @as(i128, @intCast(options.iterations)))),
        path_old.executables,
    });
    try writer.print("listDir executable:     {d:.3} ms total  {d:.3} ms/iter  executables={}\n", .{
        nsToMs(path_new.elapsed_ns),
        nsToMs(@divTrunc(path_new.elapsed_ns, @as(i128, @intCast(options.iterations)))),
        path_new.executables,
    });
    try writer.print("speedup:                 {d:.2}x\n", .{
        @as(f64, @floatFromInt(path_old.elapsed_ns)) / @as(f64, @floatFromInt(path_new.elapsed_ns)),
    });

    return 0;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--entries")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.entries = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.iterations = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.dir = args[index];
        } else if (std.mem.eql(u8, arg, "--pattern")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.pattern = args[index];
        } else if (std.mem.eql(u8, arg, "--keep")) {
            options.keep = true;
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }
    if (std.mem.indexOfScalar(u8, options.pattern, '/') != null) return error.PatternMustBeBasename;
    return options;
}

fn printUsage(io: std.Io, arg_zero: []const u8, err: anyerror) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    defer stderr.interface.flush() catch {};
    try stderr.interface.print(
        \\error: {s}
        \\usage: {s} [--entries N] [--iterations N] [--dir PATH] [--pattern BASENAME] [--keep]
        \\
    , .{ @errorName(err), arg_zero });
}

fn prepareFixture(io: std.Io, options: Options) !void {
    cleanupFixture(io, options.dir);
    try std.Io.Dir.cwd().createDirPath(io, options.dir);
    var index: usize = 0;
    while (index < options.entries) : (index += 1) {
        var name_buffer: [128]u8 = undefined;
        const suffix = if (index % 4 == 0) "dat" else "tmp";
        const basename = try std.fmt.bufPrint(&name_buffer, "file-{d:0>6}.{s}", .{ index, suffix });
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ options.dir, basename });
        const permissions: std.Io.Dir.Permissions = if (index % 4 == 0)
            .default_file
        else
            .executable_file;
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = permissions });
        var file_buffer: [32]u8 = undefined;
        @memset(&file_buffer, 'x');
        var writer_buffer: [64]u8 = undefined;
        var writer = file.writer(io, &writer_buffer);
        try writer.interface.writeAll(file_buffer[0 .. index % file_buffer.len]);
        try writer.interface.flush();
        file.close(io);
    }
}

fn cleanupFixture(io: std.Io, dir: []const u8) void {
    // ziglint-ignore: Z026 best-effort benchmark fixture cleanup
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

fn benchmarkCurrent(allocator: std.mem.Allocator, io: std.Io, pattern_path: []const u8, iterations: usize) !RunResult {
    const start = std.Io.Clock.now(.awake, io);
    var matches: usize = 0;
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        const result = try currentRushGlob(allocator, io, pattern_path);
        matches = result.len;
        freeMatches(allocator, result);
    }
    const end = std.Io.Clock.now(.awake, io);
    return .{ .matches = matches, .elapsed_ns = start.durationTo(end).toNanoseconds() };
}

fn benchmarkCurrentSize(
    allocator: std.mem.Allocator,
    io: std.Io,
    pattern_path: []const u8,
    iterations: usize,
) !SizeRunResult {
    const start = std.Io.Clock.now(.awake, io);
    var matches: usize = 0;
    var total_size: u64 = 0;
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        const result = try currentRushGlob(allocator, io, pattern_path);
        matches = result.len;
        total_size = 0;
        for (result) |path| {
            const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
            total_size += stat.size;
        }
        freeMatches(allocator, result);
    }
    const end = std.Io.Clock.now(.awake, io);
    return .{ .matches = matches, .total_size = total_size, .elapsed_ns = start.durationTo(end).toNanoseconds() };
}

fn benchmarkBulk(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    pattern: []const u8,
    iterations: usize,
) !BulkRunResult {
    const start = std.Io.Clock.now(.awake, io);
    var matches: usize = 0;
    var stats: BulkStats = .{};
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        const result = try macosBulkGlob(allocator, dir, pattern, &stats);
        matches = result.len;
        freeMatches(allocator, result);
    }
    const end = std.Io.Clock.now(.awake, io);
    return .{
        .run = .{ .matches = matches, .elapsed_ns = start.durationTo(end).toNanoseconds() },
        .stats = stats,
    };
}

fn benchmarkBulkSize(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    pattern: []const u8,
    iterations: usize,
) !BulkSizeRunResult {
    const start = std.Io.Clock.now(.awake, io);
    var matches: usize = 0;
    var total_size: u64 = 0;
    var stats: BulkStats = .{};
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        const result = try macosBulkGlobSize(allocator, dir, pattern, &stats);
        matches = result.matches;
        total_size = result.total_size;
    }
    const end = std.Io.Clock.now(.awake, io);
    return .{
        .run = .{ .matches = matches, .total_size = total_size, .elapsed_ns = start.durationTo(end).toNanoseconds() },
        .stats = stats,
    };
}

fn benchmarkPathOld(io: std.Io, dir_path: []const u8, iterations: usize) !PathRunResult {
    const start = std.Io.Clock.now(.awake, io);
    var executables: usize = 0;
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        executables = try countPathExecutablesOld(io, dir_path);
    }
    const end = std.Io.Clock.now(.awake, io);
    return .{ .executables = executables, .elapsed_ns = start.durationTo(end).toNanoseconds() };
}

fn countPathExecutablesOld(io: std.Io, dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var executables: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;
        if (entry.kind == .directory) continue;
        dir.access(io, entry.name, .{ .execute = true }) catch continue;
        executables += 1;
    }
    return executables;
}

fn benchmarkPathListDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    iterations: usize,
) !PathRunResult {
    const start = std.Io.Clock.now(.awake, io);
    var executables: usize = 0;
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        executables = try countPathExecutablesListDir(allocator, io, dir_path);
    }
    const end = std.Io.Clock.now(.awake, io);
    return .{ .executables = executables, .elapsed_ns = start.durationTo(end).toNanoseconds() };
}

fn countPathExecutablesListDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !usize {
    var adapter = runtime_posix.Adapter.init(io);
    const fs_port = adapter.fsPort();
    var entries = try fs_port.listDir(.{
        .allocator = allocator,
        .path = dir_path,
        .attributes = .{ .kind = true, .executable = true },
    });
    defer entries.deinit();

    var executables: usize = 0;
    for (entries.entries) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;
        if (entry.kind == .directory) continue;
        if (entry.executable != true) continue;
        executables += 1;
    }
    return executables;
}

fn currentRushGlob(allocator: std.mem.Allocator, io: std.Io, pattern_path: []const u8) ![][]const u8 {
    return expand.expandPathnamePattern(allocator, io, pattern_path);
}

fn macosBulkGlob(
    allocator: std.mem.Allocator,
    dir: []const u8,
    pattern: []const u8,
    stats: ?*BulkStats,
) ![][]const u8 {
    if (builtin.os.tag != .macos) return error.Unsupported;
    return macosBulkGlobImpl(allocator, dir, pattern, stats);
}

fn macosBulkGlobImpl(
    allocator: std.mem.Allocator,
    dir: []const u8,
    pattern: []const u8,
    stats: ?*BulkStats,
) ![][]const u8 {
    const fd = try openDirFd(dir);
    defer closeFd(fd);

    const buffer = try allocator.alloc(u8, bulk_buffer_len);
    defer allocator.free(buffer);

    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |match| allocator.free(match);
        matches.deinit(allocator);
    }

    var attr_list: c.struct_attrlist = std.mem.zeroes(c.struct_attrlist);
    attr_list.bitmapcount = c.ATTR_BIT_MAP_COUNT;
    attr_list.commonattr = c.ATTR_CMN_RETURNED_ATTRS | c.ATTR_CMN_NAME;

    const include_hidden = std.mem.startsWith(u8, pattern, ".");
    while (true) {
        const count = c.getattrlistbulk(fd, &attr_list, buffer.ptr, buffer.len, 0);
        if (count < 0) return error.Unexpected;
        if (stats) |bulk_stats| bulk_stats.recordCall(count);
        if (count == 0) break;

        var offset: usize = 0;
        var entry_index: usize = 0;
        while (entry_index < @as(usize, @intCast(count))) : (entry_index += 1) {
            if (stats) |bulk_stats| bulk_stats.records_parsed += 1;
            if (offset + 32 > buffer.len) return error.Unexpected;
            const record_len = readInt(u32, buffer[offset..][0..4]);
            if (record_len == 0 or offset + record_len > buffer.len) return error.Unexpected;

            const name_ref_offset = offset + 4 + @sizeOf(c.attribute_set_t);
            const name_data_offset = readInt(i32, buffer[name_ref_offset..][0..4]);
            const name_len = readInt(u32, buffer[name_ref_offset + 4 ..][0..4]);
            if (name_data_offset < 0) return error.Unexpected;
            const name_start = name_ref_offset + @as(usize, @intCast(name_data_offset));
            if (name_start > offset + record_len or
                name_start + name_len > offset + record_len) return error.Unexpected;
            const raw_name = buffer[name_start .. name_start + name_len];
            const name = std.mem.sliceTo(raw_name, 0);

            if (name.len != 0 and
                !std.mem.eql(u8, name, ".") and
                !std.mem.eql(u8, name, "..") and
                (include_hidden or name[0] != '.') and
                simpleGlobMatches(pattern, name))
            {
                try matches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name }));
            }
            offset += record_len;
        }
    }

    std.mem.sort([]const u8, matches.items, {}, lessThanString);
    return matches.toOwnedSlice(allocator);
}

fn macosBulkGlobSize(
    allocator: std.mem.Allocator,
    dir: []const u8,
    pattern: []const u8,
    stats: ?*BulkStats,
) !SizeRunResult {
    if (builtin.os.tag != .macos) return error.Unsupported;

    const fd = try openDirFd(dir);
    defer closeFd(fd);

    const buffer = try allocator.alloc(u8, bulk_buffer_len);
    defer allocator.free(buffer);

    var attr_list: c.struct_attrlist = std.mem.zeroes(c.struct_attrlist);
    attr_list.bitmapcount = c.ATTR_BIT_MAP_COUNT;
    attr_list.commonattr = c.ATTR_CMN_RETURNED_ATTRS | c.ATTR_CMN_NAME;
    attr_list.fileattr = c.ATTR_FILE_DATALENGTH;

    var matches: usize = 0;
    var total_size: u64 = 0;
    const include_hidden = std.mem.startsWith(u8, pattern, ".");
    while (true) {
        const count = c.getattrlistbulk(fd, &attr_list, buffer.ptr, buffer.len, 0);
        if (count < 0) return error.Unexpected;
        if (stats) |bulk_stats| bulk_stats.recordCall(count);
        if (count == 0) break;

        var offset: usize = 0;
        var entry_index: usize = 0;
        while (entry_index < @as(usize, @intCast(count))) : (entry_index += 1) {
            if (stats) |bulk_stats| bulk_stats.records_parsed += 1;
            if (offset + 40 > buffer.len) return error.Unexpected;
            const record_len = readInt(u32, buffer[offset..][0..4]);
            if (record_len == 0 or offset + record_len > buffer.len) return error.Unexpected;

            const name_ref_offset = offset + 4 + @sizeOf(c.attribute_set_t);
            const name_data_offset = readInt(i32, buffer[name_ref_offset..][0..4]);
            const name_len = readInt(u32, buffer[name_ref_offset + 4 ..][0..4]);
            if (name_data_offset < 0) return error.Unexpected;
            const name_start = name_ref_offset + @as(usize, @intCast(name_data_offset));
            if (name_start > offset + record_len or
                name_start + name_len > offset + record_len) return error.Unexpected;
            const raw_name = buffer[name_start .. name_start + name_len];
            const name = std.mem.sliceTo(raw_name, 0);

            const size_offset = name_ref_offset + @sizeOf(c.attrreference_t);
            if (size_offset + @sizeOf(i64) > offset + record_len) return error.Unexpected;
            const size = readInt(i64, buffer[size_offset..][0..8]);
            if (size < 0) return error.Unexpected;

            if (name.len != 0 and
                !std.mem.eql(u8, name, ".") and
                !std.mem.eql(u8, name, "..") and
                (include_hidden or name[0] != '.') and
                simpleGlobMatches(pattern, name))
            {
                matches += 1;
                total_size += @intCast(size);
            }
            offset += record_len;
        }
    }

    return .{ .matches = matches, .total_size = total_size, .elapsed_ns = 0 };
}

fn openDirFd(dir: []const u8) !c_int {
    const dir_z = try std.posix.toPosixPath(dir);
    const fd = c.open(&dir_z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return error.Unexpected;
    return fd;
}

fn closeFd(fd: c_int) void {
    while (true) {
        const rc = c.close(fd);
        switch (std.c.errno(rc)) {
            .SUCCESS, .BADF => return,
            .INTR => continue,
            else => return,
        }
    }
}

fn readInt(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8) T {
    return std.mem.readInt(T, bytes, builtin.cpu.arch.endian());
}

fn simpleGlobMatches(pattern: []const u8, name: []const u8) bool {
    return simpleGlobMatchesAt(pattern, 0, name, 0);
}

fn simpleGlobMatchesAt(pattern: []const u8, pattern_index: usize, name: []const u8, name_index: usize) bool {
    if (pattern_index == pattern.len) return name_index == name.len;
    return switch (pattern[pattern_index]) {
        '*' => blk: {
            var next_name = name_index;
            while (next_name <= name.len) : (next_name += 1) {
                if (simpleGlobMatchesAt(pattern, pattern_index + 1, name, next_name)) break :blk true;
            }
            break :blk false;
        },
        '?' => name_index < name.len and simpleGlobMatchesAt(pattern, pattern_index + 1, name, name_index + 1),
        else => name_index < name.len and pattern[pattern_index] == name[name_index] and
            simpleGlobMatchesAt(pattern, pattern_index + 1, name, name_index + 1),
    };
}

fn expectSameMatches(a: []const []const u8, b: []const []const u8) !void {
    if (a.len != b.len) return error.MatchCountMismatch;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return error.MatchMismatch;
    }
}

fn freeMatches(allocator: std.mem.Allocator, matches: []const []const u8) void {
    for (matches) |match| allocator.free(match);
    allocator.free(matches);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn entriesPerPositiveCall(stats: BulkStats) f64 {
    const positive_calls = stats.calls - stats.eof_calls;
    if (positive_calls == 0) return 0;
    return @as(f64, @floatFromInt(stats.entries_returned)) / @as(f64, @floatFromInt(positive_calls));
}
