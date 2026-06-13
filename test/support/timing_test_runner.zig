//! Test runner that reports per-test runtime.

const builtin = @import("builtin");
const std = @import("std");

const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const test_fns = builtin.test_functions;
    var pass_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leak_count: usize = 0;

    for (test_fns, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;

        const start = std.Io.Timestamp.now(testing.io, .awake);
        const result = test_fn.func();
        const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));

        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;
        leak_count += @intFromBool(leaked);

        const elapsed_us = elapsed.toMicroseconds();
        if (result) |_| {
            pass_count += 1;
            std.debug.print("{d}/{d} PASS time_us={d} {s}\n", .{ i + 1, test_fns.len, elapsed_us, test_fn.name });
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                std.debug.print("{d}/{d} SKIP time_us={d} {s}\n", .{ i + 1, test_fns.len, elapsed_us, test_fn.name });
            },
            else => {
                fail_count += 1;
                std.debug.print("{d}/{d} FAIL time_us={d} {s} ({t})\n", .{ i + 1, test_fns.len, elapsed_us, test_fn.name, err });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }

        if (leaked) {
            std.debug.print("{d}/{d} LEAK {s}\n", .{ i + 1, test_fns.len, test_fn.name });
        }
    }

    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ pass_count, skip_count, fail_count });
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leak_count != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leak_count});
    }
    if (fail_count != 0 or log_err_count != 0 or leak_count != 0) {
        std.process.exit(1);
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
