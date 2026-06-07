//! Application entry point.

const std = @import("std");

pub const parser = @import("parser.zig");
pub const expand = @import("expand.zig");
pub const ir = @import("ir.zig");
pub const exec = @import("exec.zig");

const usage =
    \\usage: rush -c SCRIPT
    \\       rush --help
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try writeAll(init.io, .stdout, usage);
        return 0;
    }

    if (args.len != 3 or !std.mem.eql(u8, args[1], "-c")) {
        try writeAll(init.io, .stderr, usage);
        return 2;
    }

    var result = try runScript(allocator, init.io, args[2]);
    defer result.deinit();

    try writeAll(init.io, .stdout, result.stdout);
    try writeAll(init.io, .stderr, result.stderr);
    return result.status;
}

pub fn runScript(allocator: std.mem.Allocator, io: std.Io, script: []const u8) !exec.CommandResult {
    var parsed = try parser.parse(allocator, script, .{});
    defer parsed.deinit();

    if (parsed.diagnostics.len != 0) {
        return diagnosticsResult(allocator, script, parsed.diagnostics);
    }

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();

    var executor = exec.Executor.init(allocator);
    defer executor.deinit();

    return executor.executeProgram(program, .{ .io = io, .allow_external = true });
}

fn diagnosticsResult(allocator: std.mem.Allocator, script: []const u8, diagnostics: []const parser.Diagnostic) !exec.CommandResult {
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    for (diagnostics) |diagnostic| {
        const line = try std.fmt.allocPrint(allocator, "rush: {s} at {d}..{d}: {s}\n", .{
            @tagName(diagnostic.kind),
            diagnostic.span.start,
            diagnostic.span.end,
            diagnostic.message,
        });
        defer allocator.free(line);
        try stderr.appendSlice(allocator, line);

        const snippet = diagnostic.span.slice(script);
        if (snippet.len != 0) {
            const snippet_line = try std.fmt.allocPrint(allocator, "  {s}\n", .{snippet});
            defer allocator.free(snippet_line);
            try stderr.appendSlice(allocator, snippet_line);
        }
    }

    return .{
        .allocator = allocator,
        .status = 2,
        .stdout = try allocator.alloc(u8, 0),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

const OutputStream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: OutputStream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

test "runScript executes builtins" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo hello");
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScript returns parse diagnostics" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo | ");
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing command after pipeline operator") != null);
}

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(expand);
    std.testing.refAllDecls(ir);
    std.testing.refAllDecls(exec);
}
