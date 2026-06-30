//! Builtin command dispatch for the direct evaluator.

const std = @import("std");

const host = @import("../host.zig");
const output = @import("output.zig");
const printf = @import("printf.zig");
const result = @import("result.zig");
const state_mod = @import("state.zig");

pub const Kind = enum {
    special,
    regular,
};

pub const Id = enum {
    break_,
    cd,
    colon,
    command,
    continue_,
    eval,
    exec,
    export_,
    exit,
    false_,
    printf,
    pwd,
    read,
    readonly,
    set,
    true_,
    type,
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
    .{ "break", Definition{ .name = "break", .id = .break_, .kind = .special } },
    .{ "cd", Definition{ .name = "cd", .id = .cd, .kind = .regular } },
    .{ ":", Definition{ .name = ":", .id = .colon, .kind = .special } },
    .{ "command", Definition{ .name = "command", .id = .command, .kind = .regular } },
    .{ "continue", Definition{ .name = "continue", .id = .continue_, .kind = .special } },
    .{ "eval", Definition{ .name = "eval", .id = .eval, .kind = .special } },
    .{ "exec", Definition{ .name = "exec", .id = .exec, .kind = .special } },
    .{ "export", Definition{ .name = "export", .id = .export_, .kind = .special } },
    .{ "exit", Definition{ .name = "exit", .id = .exit, .kind = .special } },
    .{ "false", Definition{ .name = "false", .id = .false_, .kind = .regular } },
    .{ "printf", Definition{ .name = "printf", .id = .printf, .kind = .regular } },
    .{ "pwd", Definition{ .name = "pwd", .id = .pwd, .kind = .regular } },
    .{ "read", Definition{ .name = "read", .id = .read, .kind = .regular } },
    .{ "readonly", Definition{ .name = "readonly", .id = .readonly, .kind = .special } },
    .{ "set", Definition{ .name = "set", .id = .set, .kind = .special } },
    .{ "true", Definition{ .name = "true", .id = .true_, .kind = .regular } },
    .{ "type", Definition{ .name = "type", .id = .type, .kind = .regular } },
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
        .break_ => evalBreak(args),
        .cd, .command, .eval, .exec, .export_, .pwd, .read, .type => unreachable,
        .continue_ => evalContinue(args),
        .exit => evalExit(shell, args),
        .false_ => .{ .status = 1 },
        .printf => evalPrintf(shell, args),
        .readonly => evalReadonly(shell, args),
        .set => evalSet(shell, args),
    };
}

fn evalExit(shell: anytype, args: []const []const u8) result.EvalResult {
    const status = if (args.len > 1) parseExitStatus(args[1]) else shell.state.last_status;
    return .{ .status = status, .flow = .{ .exit = status } };
}

fn parseExitStatus(text: []const u8) result.ExitStatus {
    return std.fmt.parseInt(u8, text, 10) catch 2;
}

fn evalBreak(args: []const []const u8) result.EvalResult {
    const count = parseLoopControlCount(args) orelse return .{ .status = 2 };
    return .{ .flow = .{ .break_ = count } };
}

fn evalContinue(args: []const []const u8) result.EvalResult {
    const count = parseLoopControlCount(args) orelse return .{ .status = 2 };
    return .{ .flow = .{ .continue_ = count } };
}

fn parseLoopControlCount(args: []const []const u8) ?usize {
    if (args.len > 2) return null;
    if (args.len == 1) return 1;
    const count = std.fmt.parseInt(usize, args[1], 10) catch return null;
    return if (count == 0) null else count;
}

fn evalPrintf(shell: anytype, args: []const []const u8) !result.EvalResult {
    const Writer = output.HostFdWriter(@TypeOf(shell.host));
    var stdout: Writer = .{ .host = &shell.host, .fd = .stdout };
    var stderr: Writer = .{ .host = &shell.host, .fd = .stderr };

    const status = try printf.evaluate(Writer, shell.scratchAllocator(), args, &stdout, &stderr);
    try stdout.flush();
    try stderr.flush();
    return .{ .status = status };
}

fn evalReadonly(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) return .{};
    for (args[1..]) |arg| {
        const equal_index = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (equal_index) |index| arg[0..index] else arg;
        if (!isAssignmentName(name)) return .{ .status = 2 };
        const value = if (equal_index) |index| arg[index + 1 ..] else if (shell.state.getVariable(name)) |variable| variable.value else "";
        try shell.state.putVariable(.{ .name = name, .value = value, .readonly = true });
    }
    return .{};
}

fn evalSet(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) return .{};
    if (std.mem.eql(u8, args[1], "--")) {
        try shell.state.setPositionals(args[2..]);
        return .{};
    }
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) return .{ .status = 2 };
        const enabled = arg[0] == '-';
        for (arg[1..]) |option| switch (option) {
            'f' => shell.state.options.noglob = enabled,
            'u' => shell.state.options.nounset = enabled,
            else => return .{ .status = 2 },
        };
    }
    return .{};
}

fn isAssignmentName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

test "builtin lookup identifies null true and false utilities" {
    try std.testing.expectEqual(Id.break_, lookup("break").?.id);
    try std.testing.expectEqual(Id.cd, lookup("cd").?.id);
    try std.testing.expectEqual(Id.colon, lookup(":").?.id);
    try std.testing.expectEqual(Id.command, lookup("command").?.id);
    try std.testing.expectEqual(Id.continue_, lookup("continue").?.id);
    try std.testing.expectEqual(Id.eval, lookup("eval").?.id);
    try std.testing.expectEqual(Id.exec, lookup("exec").?.id);
    try std.testing.expectEqual(Id.export_, lookup("export").?.id);
    try std.testing.expectEqual(Id.exit, lookup("exit").?.id);
    try std.testing.expectEqual(Id.true_, lookup("true").?.id);
    try std.testing.expectEqual(Id.false_, lookup("false").?.id);
    try std.testing.expectEqual(Id.printf, lookup("printf").?.id);
    try std.testing.expectEqual(Id.pwd, lookup("pwd").?.id);
    try std.testing.expectEqual(Id.read, lookup("read").?.id);
    try std.testing.expectEqual(Id.readonly, lookup("readonly").?.id);
    try std.testing.expectEqual(Id.type, lookup("type").?.id);
    try std.testing.expectEqual(@as(?Definition, null), lookup("missing"));
}

test "builtin eval returns utility status" {
    const TestHost = struct {
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    const true_definition = lookup("true").?;
    const false_definition = lookup("false").?;

    try std.testing.expectEqual(@as(result.ExitStatus, 0), (try eval(&shell, true_definition, &.{"true"})).status);
    try std.testing.expectEqual(@as(result.ExitStatus, 1), (try eval(&shell, false_definition, &.{"false"})).status);
}

test "exit builtin returns requested exit flow" {
    const TestHost = struct {
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    const evaluated = try eval(&shell, lookup("exit").?, &.{ "exit", "7" });

    try std.testing.expectEqual(@as(result.ExitStatus, 7), evaluated.status);
    try std.testing.expectEqual(result.ControlFlow{ .exit = 7 }, evaluated.flow);
}

test "printf writes formatted output once" {
    const TestHost = struct {
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This()) void {
            self.stdout.deinit(std.testing.allocator);
            self.stderr.deinit(std.testing.allocator);
        }

        pub fn writeAll(self: *@This(), fd: host.Fd, bytes: []const u8) !void {
            switch (fd) {
                .stdout => try self.stdout.appendSlice(std.testing.allocator, bytes),
                .stderr => try self.stderr.appendSlice(std.testing.allocator, bytes),
                else => unreachable,
            }
        }
    };
    const TestShell = struct {
        host: TestHost = .{},
        state: state_mod.State,

        fn scratchAllocator(_: *@This()) std.mem.Allocator {
            return std.testing.allocator;
        }
    };

    var shell: TestShell = .{ .state = state_mod.State.init(std.testing.allocator, .{}) };
    defer shell.state.deinit();
    defer shell.host.deinit();

    const printf_definition = lookup("printf").?;
    const evaluated = try eval(&shell, printf_definition, &.{ "printf", "%s\\n", "hello" });

    try std.testing.expectEqual(@as(result.ExitStatus, 0), evaluated.status);
    try std.testing.expectEqualStrings("hello\n", shell.host.stdout.items);
    try std.testing.expectEqualStrings("", shell.host.stderr.items);
}
