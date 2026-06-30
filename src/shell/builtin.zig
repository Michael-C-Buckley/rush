//! Builtin command dispatch for the direct evaluator.

const std = @import("std");

const host = @import("../host.zig");
const printf = @import("printf.zig");
const result = @import("result.zig");

pub const Kind = enum {
    special,
    regular,
};

pub const Id = enum {
    colon,
    false_,
    printf,
    true_,
};

pub const Definition = struct {
    name: []const u8,
    id: Id,
    kind: Kind,

    pub fn validate(self: Definition) void {
        std.debug.assert(self.name.len != 0);
    }
};

const DefinitionMap = std.StaticStringMap(Definition);

pub const definitions: DefinitionMap = .initComptime(.{
    .{ ":", Definition{ .name = ":", .id = .colon, .kind = .special } },
    .{ "false", Definition{ .name = "false", .id = .false_, .kind = .regular } },
    .{ "printf", Definition{ .name = "printf", .id = .printf, .kind = .regular } },
    .{ "true", Definition{ .name = "true", .id = .true_, .kind = .regular } },
});

pub fn lookup(name: []const u8) ?Definition {
    const definition = definitions.get(name) orelse return null;
    definition.validate();
    return definition;
}

pub fn eval(shell: anytype, definition: Definition, args: []const []const u8) !result.EvalResult {
    definition.validate();
    std.debug.assert(args.len != 0);
    return switch (definition.id) {
        .colon, .true_ => .{},
        .false_ => .{ .status = 1 },
        .printf => evalPrintf(shell, args),
    };
}

fn evalPrintf(shell: anytype, args: []const []const u8) !result.EvalResult {
    const allocator = shell.scratchAllocator();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    const status = try printf.evaluate(allocator, args, &stdout, &stderr);
    if (stdout.items.len != 0) try shell.host.writeAll(host.Fd.stdout, stdout.items);
    if (stderr.items.len != 0) try shell.host.writeAll(host.Fd.stderr, stderr.items);
    return .{ .status = status };
}

test "builtin lookup identifies null true and false utilities" {
    try std.testing.expectEqual(Id.colon, lookup(":").?.id);
    try std.testing.expectEqual(Id.true_, lookup("true").?.id);
    try std.testing.expectEqual(Id.false_, lookup("false").?.id);
    try std.testing.expectEqual(Id.printf, lookup("printf").?.id);
    try std.testing.expectEqual(@as(?Definition, null), lookup("missing"));
}

test "builtin eval returns utility status" {
    const TestHost = struct {
        fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},

        fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{};
    const true_definition = lookup("true").?;
    const false_definition = lookup("false").?;

    try std.testing.expectEqual(@as(result.ExitStatus, 0), (try eval(&shell, true_definition, &.{"true"})).status);
    try std.testing.expectEqual(@as(result.ExitStatus, 1), (try eval(&shell, false_definition, &.{"false"})).status);
}

test "printf writes formatted output once" {
    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(std.testing.allocator);
            self.stderr.deinit(std.testing.allocator);
        }

        fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                .stderr => try self.stderr.appendSlice(std.testing.allocator, bytes),
                else => unreachable,
            }
        }
    };
    const TestShell = struct {
        host: TestHost = .{},

        fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{};
    defer shell.host.deinit();

    const printf_definition = lookup("printf").?;
    const evaluated = try eval(&shell, printf_definition, &.{ "printf", "%s\\n", "hello" });

    try std.testing.expectEqual(@as(result.ExitStatus, 0), evaluated.status);
    try std.testing.expectEqualStrings("hello\n", shell.host.stdout.items);
    try std.testing.expectEqualStrings("", shell.host.stderr.items);
}
