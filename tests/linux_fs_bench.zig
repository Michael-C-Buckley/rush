//! Linux-only prototype benchmark for directory metadata collection strategies.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux) @compileError("linux_fs_bench.zig is Linux-only");
}

const linux = std.os.linux;

const default_entries = 20_000;
const default_iterations = 20;
const default_dir = ".zig-cache/rush-linux-fs-bench";
const default_batch_size = 128;
const max_batch_size = 32_768;

const statx_mask: linux.STATX = .{ .SIZE = true };

const Strategy = enum {
    all,
    baseline,
    statx,
    uring,
};

const Metadata = enum {
    size,
    size_executable,

    fn executable(self: Metadata) bool {
        return self == .size_executable;
    }
};

const Options = struct {
    entries: usize = default_entries,
    iterations: usize = default_iterations,
    dir: []const u8 = default_dir,
    batch_size: usize = default_batch_size,
    strategy: Strategy = .all,
    metadata: Metadata = .size,
    create_fixture: bool = true,
    warmup: bool = true,
    prepare_only: bool = false,
    keep: bool = false,
};

const RunResult = struct {
    entries: usize,
    total_size: u64,
    executables: usize = 0,
    elapsed_ns: i128,
};

const IoUringScratch = struct {
    ring: linux.IoUring,
    names: []?[:0]u8,
    name_storage: []u8,
    statx_bufs: []linux.Statx,
    cqes: []linux.io_uring_cqe,
    batch_size: usize,

    fn init(allocator: std.mem.Allocator, batch_size: usize) !IoUringScratch {
        const names = try allocator.alloc(?[:0]u8, batch_size);
        errdefer allocator.free(names);
        @memset(names, null);

        const name_stride = std.Io.Dir.max_name_bytes + 1;
        const name_storage = try allocator.alloc(u8, batch_size * name_stride);
        errdefer allocator.free(name_storage);

        const statx_bufs = try allocator.alloc(linux.Statx, batch_size);
        errdefer allocator.free(statx_bufs);

        const cqes = try allocator.alloc(linux.io_uring_cqe, batch_size);
        errdefer allocator.free(cqes);

        var ring = try initRing(try ringEntries(batch_size));
        errdefer ring.deinit();

        return .{
            .ring = ring,
            .names = names,
            .name_storage = name_storage,
            .statx_bufs = statx_bufs,
            .cqes = cqes,
            .batch_size = batch_size,
        };
    }

    fn deinit(self: *IoUringScratch, allocator: std.mem.Allocator) void {
        self.ring.deinit();
        allocator.free(self.cqes);
        allocator.free(self.statx_bufs);
        allocator.free(self.name_storage);
        allocator.free(self.names);
        self.* = undefined;
    }

    fn nameSlot(self: *IoUringScratch, slot: usize, name: []const u8) ![:0]u8 {
        if (name.len > std.Io.Dir.max_name_bytes) return error.NameTooLong;
        const name_stride = std.Io.Dir.max_name_bytes + 1;
        const start = slot * name_stride;
        const storage = self.name_storage[start .. start + name_stride];
        @memcpy(storage[0..name.len], name);
        storage[name.len] = 0;
        return storage[0..name.len :0];
    }
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(args[1..]) catch |err| {
        try printUsage(init.io, args[0], err);
        return 2;
    };
    if ((!options.prepare_only and options.iterations == 0) or options.entries == 0 or
        options.batch_size == 0 or options.batch_size > max_batch_size)
    {
        try printUsage(init.io, args[0], error.InvalidCount);
        return 2;
    }

    if (options.create_fixture) try prepareFixture(init.io, options);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};
    const writer = &stdout.interface;

    if (options.prepare_only) {
        try writer.print("prepared Linux filesystem metadata benchmark fixture: {s}\n", .{options.dir});
        try writer.print("entries: {} expected total size: {} expected executables: {}\n", .{
            options.entries,
            expectedTotalSize(options.entries),
            expectedExecutableCount(options.entries),
        });
        return 0;
    }

    defer if (options.create_fixture and !options.keep) cleanupFixture(init.io, options.dir);

    if (options.strategy != .all) {
        if (options.warmup) {
            const warmup = try runStrategy(allocator, init.io, options, options.strategy, 1);
            try expectFixtureTotals(options, warmup);
        }

        const result = try runStrategy(allocator, init.io, options, options.strategy, options.iterations);
        try expectFixtureTotals(options, result);
        try printHeader(writer, options);
        try printStrategyResult(writer, options.strategy, result, options.iterations);
        return 0;
    }

    if (options.warmup) {
        const baseline_warmup = try portableBaseline(init.io, options.dir, options.metadata);
        const statx_warmup = try syncStatxLoop(init.io, options.dir, options.metadata);
        var uring_warmup_scratch = try IoUringScratch.init(allocator, options.batch_size);
        defer uring_warmup_scratch.deinit(allocator);
        const uring_warmup = try ioUringStatxBatch(&uring_warmup_scratch, init.io, options.dir, options.metadata);
        try expectSame(baseline_warmup, statx_warmup);
        try expectSame(baseline_warmup, uring_warmup);
    }

    const baseline = try benchmarkPortable(init.io, options.dir, options.iterations, options.metadata);
    const statx = try benchmarkSyncStatx(init.io, options.dir, options.iterations, options.metadata);
    const uring = try benchmarkIoUringStatx(
        allocator,
        init.io,
        options.dir,
        options.iterations,
        options.batch_size,
        options.metadata,
    );
    try expectSame(baseline, statx);
    try expectSame(baseline, uring);

    const baseline_per_iter = perIterMs(baseline.elapsed_ns, options.iterations);
    const statx_per_iter = perIterMs(statx.elapsed_ns, options.iterations);
    const uring_per_iter = perIterMs(uring.elapsed_ns, options.iterations);

    try printHeader(writer, options);
    try printStrategyResult(writer, .baseline, baseline, options.iterations);
    try printStrategyResult(writer, .statx, statx, options.iterations);
    try printStrategyResult(writer, .uring, uring, options.iterations);
    try writer.print("\nsync statx speedup:  {d:.2}x\n", .{baseline_per_iter / statx_per_iter});
    try writer.print("io_uring speedup:    {d:.2}x\n", .{baseline_per_iter / uring_per_iter});

    return 0;
}

fn runStrategy(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    strategy: Strategy,
    iterations: usize,
) !RunResult {
    return switch (strategy) {
        .all => error.InvalidStrategy,
        .baseline => benchmarkPortable(io, options.dir, iterations, options.metadata),
        .statx => benchmarkSyncStatx(io, options.dir, iterations, options.metadata),
        .uring => benchmarkIoUringStatx(allocator, io, options.dir, iterations, options.batch_size, options.metadata),
    };
}

fn printHeader(writer: *std.Io.Writer, options: Options) !void {
    try writer.print("Linux filesystem metadata benchmark fixture: {s}\n", .{options.dir});
    try writer.print("entries: {} iterations: {} io_uring batch size: {} strategy: {s} metadata: {s}\n", .{
        options.entries,
        options.iterations,
        options.batch_size,
        @tagName(options.strategy),
        @tagName(options.metadata),
    });
    try writer.print("\nstrategy                    entries  total size  executables  total ms   ms/iter\n", .{});
}

fn printStrategyResult(writer: *std.Io.Writer, strategy: Strategy, result: RunResult, iterations: usize) !void {
    try writer.print("{s:<28}  {d:>7}  {d:>10}  {d:>11}  {d:>8.3}  {d:>8.3}\n", .{
        strategyLabel(strategy),
        result.entries,
        result.total_size,
        result.executables,
        nsToMs(result.elapsed_ns),
        perIterMs(result.elapsed_ns, iterations),
    });
}

fn strategyLabel(strategy: Strategy) []const u8 {
    return switch (strategy) {
        .all => "all",
        .baseline => "portable iterator+statFile",
        .statx => "sync statx loop",
        .uring => "io_uring statx window",
    };
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
        } else if (std.mem.eql(u8, arg, "--batch-size")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.batch_size = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--strategy")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.strategy = parseStrategy(args[index]) orelse return error.InvalidStrategy;
        } else if (std.mem.eql(u8, arg, "--metadata")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.metadata = parseMetadata(args[index]) orelse return error.InvalidMetadata;
        } else if (std.mem.eql(u8, arg, "--no-create")) {
            options.create_fixture = false;
        } else if (std.mem.eql(u8, arg, "--no-warmup")) {
            options.warmup = false;
        } else if (std.mem.eql(u8, arg, "--prepare-only")) {
            options.prepare_only = true;
        } else if (std.mem.eql(u8, arg, "--keep")) {
            options.keep = true;
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }
    return options;
}

fn parseStrategy(value: []const u8) ?Strategy {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "baseline")) return .baseline;
    if (std.mem.eql(u8, value, "statx")) return .statx;
    if (std.mem.eql(u8, value, "uring")) return .uring;
    return null;
}

fn parseMetadata(value: []const u8) ?Metadata {
    if (std.mem.eql(u8, value, "size")) return .size;
    if (std.mem.eql(u8, value, "size-executable")) return .size_executable;
    return null;
}

fn printUsage(io: std.Io, arg_zero: []const u8, err: anyerror) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    defer stderr.interface.flush() catch {};
    try stderr.interface.print(
        \\error: {s}
        \\usage: {s} [--entries N] [--iterations N] [--dir PATH] [--batch-size N]
        \\       [--strategy all|baseline|statx|uring] [--no-create] [--no-warmup]
        \\       [--metadata size|size-executable] [--prepare-only] [--keep]
        \\
    , .{ @errorName(err), arg_zero });
}

fn prepareFixture(io: std.Io, options: Options) !void {
    cleanupFixture(io, options.dir);
    try std.Io.Dir.cwd().createDirPath(io, options.dir);
    var index: usize = 0;
    while (index < options.entries) : (index += 1) {
        var name_buffer: [128]u8 = undefined;
        const basename = try std.fmt.bufPrint(&name_buffer, "file-{d:0>6}.tmp", .{index});
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ options.dir, basename });

        const permissions: std.Io.Dir.Permissions = if (isExecutableFixtureEntry(index))
            .executable_file
        else
            .default_file;
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = permissions });
        var file_buffer: [251]u8 = undefined;
        @memset(&file_buffer, 'x');
        const file_size = (index % file_buffer.len) + 1;
        var writer_buffer: [512]u8 = undefined;
        var writer = file.writer(io, &writer_buffer);
        try writer.interface.writeAll(file_buffer[0..file_size]);
        try writer.interface.flush();
        file.close(io);
    }
}

fn cleanupFixture(io: std.Io, dir: []const u8) void {
    // ziglint-ignore: Z026 best-effort benchmark fixture cleanup
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

fn benchmarkPortable(io: std.Io, dir_path: []const u8, iterations: usize, metadata: Metadata) !RunResult {
    const start = std.Io.Clock.now(.awake, io);
    var result: RunResult = .{ .entries = 0, .total_size = 0, .elapsed_ns = 0 };
    var index: usize = 0;
    while (index < iterations) : (index += 1) result = try portableBaseline(io, dir_path, metadata);
    const end = std.Io.Clock.now(.awake, io);
    result.elapsed_ns = start.durationTo(end).toNanoseconds();
    return result;
}

fn portableBaseline(io: std.Io, dir_path: []const u8, metadata: Metadata) !RunResult {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var result: RunResult = .{ .entries = 0, .total_size = 0, .elapsed_ns = 0 };
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        const stat = try dir.statFile(io, entry.name, .{});
        result.entries += 1;
        result.total_size += stat.size;
        if (metadata.executable() and try executableAccess(io, dir, entry.name)) result.executables += 1;
    }
    return result;
}

fn benchmarkSyncStatx(io: std.Io, dir_path: []const u8, iterations: usize, metadata: Metadata) !RunResult {
    const start = std.Io.Clock.now(.awake, io);
    var result: RunResult = .{ .entries = 0, .total_size = 0, .elapsed_ns = 0 };
    var index: usize = 0;
    while (index < iterations) : (index += 1) result = try syncStatxLoop(io, dir_path, metadata);
    const end = std.Io.Clock.now(.awake, io);
    result.elapsed_ns = start.durationTo(end).toNanoseconds();
    return result;
}

fn syncStatxLoop(io: std.Io, dir_path: []const u8, metadata: Metadata) !RunResult {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var result: RunResult = .{ .entries = 0, .total_size = 0, .elapsed_ns = 0 };
    var iterator = dir.iterate();
    var name_buffer: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name.len > std.Io.Dir.max_name_bytes) return error.NameTooLong;
        @memcpy(name_buffer[0..entry.name.len], entry.name);
        name_buffer[entry.name.len] = 0;
        const name = name_buffer[0..entry.name.len :0];
        const size = try statxSize(dir.handle, name);
        result.entries += 1;
        result.total_size += size;
        if (metadata.executable() and try executableAccess(io, dir, name)) result.executables += 1;
    }
    return result;
}

fn benchmarkIoUringStatx(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    iterations: usize,
    batch_size: usize,
    metadata: Metadata,
) !RunResult {
    var scratch = try IoUringScratch.init(allocator, batch_size);
    defer scratch.deinit(allocator);

    const start = std.Io.Clock.now(.awake, io);
    var result: RunResult = .{ .entries = 0, .total_size = 0, .elapsed_ns = 0 };
    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        result = try ioUringStatxBatch(&scratch, io, dir_path, metadata);
    }
    const end = std.Io.Clock.now(.awake, io);
    result.elapsed_ns = start.durationTo(end).toNanoseconds();
    return result;
}

fn ioUringStatxBatch(scratch: *IoUringScratch, io: std.Io, dir_path: []const u8, metadata: Metadata) !RunResult {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var result: RunResult = .{ .entries = 0, .total_size = 0, .elapsed_ns = 0 };
    var iterator = dir.iterate();

    var in_flight: usize = 0;
    var next_slot: usize = 0;
    while (next_slot < scratch.batch_size) : (next_slot += 1) {
        if (!try queueNextStatx(scratch, io, dir, &iterator, next_slot)) break;
        in_flight += 1;
    }

    var submitted = in_flight;
    while (in_flight > 0) {
        if (submitted > 0) {
            _ = try scratch.ring.submit_and_wait(1);
            submitted = 0;
        }

        const copied = try scratch.ring.copy_cqes(scratch.cqes, 0);
        if (copied == 0) {
            _ = try scratch.ring.submit_and_wait(1);
            continue;
        }

        for (scratch.cqes[0..copied]) |cqe| {
            if (cqe.err() != .SUCCESS) return error.StatxFailed;
            const slot: usize = @intCast(cqe.user_data);
            if (slot >= scratch.batch_size) return error.UnexpectedCompletion;
            if (!scratch.statx_bufs[slot].mask.SIZE) return error.StatxSizeUnsupported;
            result.entries += 1;
            result.total_size += scratch.statx_bufs[slot].size;
            in_flight -= 1;

            const name = scratch.names[slot] orelse return error.DuplicateCompletion;
            if (metadata.executable() and try executableAccess(io, dir, name)) result.executables += 1;
            scratch.names[slot] = null;

            if (try queueNextStatx(scratch, io, dir, &iterator, slot)) {
                in_flight += 1;
                submitted += 1;
            }
        }
    }

    return result;
}

fn queueNextStatx(
    scratch: *IoUringScratch,
    io: std.Io,
    dir: std.Io.Dir,
    iterator: *std.Io.Dir.Iterator,
    slot: usize,
) !bool {
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0) continue;
        const name = try scratch.nameSlot(slot, entry.name);
        scratch.names[slot] = name;
        _ = try scratch.ring.statx(
            @intCast(slot),
            dir.handle,
            name,
            0,
            statx_mask,
            &scratch.statx_bufs[slot],
        );
        return true;
    }
    return false;
}

fn statxSize(dirfd: i32, name: [:0]const u8) !u64 {
    var statx_result: linux.Statx = undefined;
    const rc = linux.statx(dirfd, name.ptr, 0, statx_mask, &statx_result);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.StatxFailed,
    }
    if (!statx_result.mask.SIZE) return error.StatxSizeUnsupported;
    return statx_result.size;
}

fn executableAccess(io: std.Io, dir: std.Io.Dir, name: []const u8) !bool {
    dir.access(io, name, .{ .execute = true }) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        error.PermissionDenied,
        error.SymLinkLoop,
        error.ReadOnlyFileSystem,
        => return false,
        else => |access_err| return access_err,
    };
    return true;
}

fn expectSame(expected: RunResult, actual: RunResult) !void {
    if (expected.entries != actual.entries) return error.EntryCountMismatch;
    if (expected.total_size != actual.total_size) return error.TotalSizeMismatch;
    if (expected.executables != actual.executables) return error.ExecutableCountMismatch;
}

fn expectFixtureTotals(options: Options, actual: RunResult) !void {
    if (actual.entries != options.entries) return error.EntryCountMismatch;
    if (actual.total_size != expectedTotalSize(options.entries)) return error.TotalSizeMismatch;
    if (options.metadata.executable() and actual.executables != expectedExecutableCount(options.entries)) {
        return error.ExecutableCountMismatch;
    }
}

fn expectedTotalSize(entries: usize) u64 {
    var total_size: u64 = 0;
    var index: usize = 0;
    while (index < entries) : (index += 1) {
        total_size += @intCast((index % 251) + 1);
    }
    return total_size;
}

fn expectedExecutableCount(entries: usize) usize {
    var executables: usize = 0;
    var index: usize = 0;
    while (index < entries) : (index += 1) {
        if (isExecutableFixtureEntry(index)) executables += 1;
    }
    return executables;
}

fn isExecutableFixtureEntry(index: usize) bool {
    return index % 3 == 0;
}

fn ringEntries(batch_size: usize) !u16 {
    if (batch_size == 0 or batch_size > max_batch_size) return error.InvalidCount;
    var entries: usize = 1;
    while (entries < batch_size) entries *= 2;
    return @intCast(entries);
}

fn initRing(entries: u16) !linux.IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = ourioSetupFlags(),
        .sq_thread_idle = 1000,
    });
    return linux.IoUring.init_params(entries, &params) catch linux.IoUring.init(entries, 0);
}

fn ourioSetupFlags() u32 {
    return linux.IORING_SETUP_CLAMP |
        linux.IORING_SETUP_SUBMIT_ALL |
        linux.IORING_SETUP_COOP_TASKRUN |
        linux.IORING_SETUP_SINGLE_ISSUER |
        linux.IORING_SETUP_DEFER_TASKRUN;
}

fn perIterMs(ns: i128, iterations: usize) f64 {
    return nsToMs(@divTrunc(ns, @as(i128, @intCast(iterations))));
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}
