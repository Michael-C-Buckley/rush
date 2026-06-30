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
    alias,
    bracket,
    break_,
    cd,
    colon,
    dot,
    command,
    continue_,
    eval,
    exec,
    export_,
    exit,
    false_,
    getopts,
    printf,
    pwd,
    read,
    readonly,
    return_,
    set,
    shift,
    test_,
    true_,
    type,
    umask,
    unalias,
    unset,
    wait,
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
    .{ "[", Definition{ .name = "[", .id = .bracket, .kind = .regular } },
    .{ "alias", Definition{ .name = "alias", .id = .alias, .kind = .regular } },
    .{ "break", Definition{ .name = "break", .id = .break_, .kind = .special } },
    .{ "cd", Definition{ .name = "cd", .id = .cd, .kind = .regular } },
    .{ ":", Definition{ .name = ":", .id = .colon, .kind = .special } },
    .{ ".", Definition{ .name = ".", .id = .dot, .kind = .special } },
    .{ "command", Definition{ .name = "command", .id = .command, .kind = .regular } },
    .{ "continue", Definition{ .name = "continue", .id = .continue_, .kind = .special } },
    .{ "eval", Definition{ .name = "eval", .id = .eval, .kind = .special } },
    .{ "exec", Definition{ .name = "exec", .id = .exec, .kind = .special } },
    .{ "export", Definition{ .name = "export", .id = .export_, .kind = .special } },
    .{ "exit", Definition{ .name = "exit", .id = .exit, .kind = .special } },
    .{ "false", Definition{ .name = "false", .id = .false_, .kind = .regular } },
    .{ "getopts", Definition{ .name = "getopts", .id = .getopts, .kind = .regular } },
    .{ "printf", Definition{ .name = "printf", .id = .printf, .kind = .regular } },
    .{ "pwd", Definition{ .name = "pwd", .id = .pwd, .kind = .regular } },
    .{ "read", Definition{ .name = "read", .id = .read, .kind = .regular } },
    .{ "readonly", Definition{ .name = "readonly", .id = .readonly, .kind = .special } },
    .{ "return", Definition{ .name = "return", .id = .return_, .kind = .special } },
    .{ "set", Definition{ .name = "set", .id = .set, .kind = .special } },
    .{ "shift", Definition{ .name = "shift", .id = .shift, .kind = .special } },
    .{ "test", Definition{ .name = "test", .id = .test_, .kind = .regular } },
    .{ "true", Definition{ .name = "true", .id = .true_, .kind = .regular } },
    .{ "type", Definition{ .name = "type", .id = .type, .kind = .regular } },
    .{ "umask", Definition{ .name = "umask", .id = .umask, .kind = .regular } },
    .{ "unalias", Definition{ .name = "unalias", .id = .unalias, .kind = .regular } },
    .{ "unset", Definition{ .name = "unset", .id = .unset, .kind = .special } },
    .{ "wait", Definition{ .name = "wait", .id = .wait, .kind = .regular } },
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
        .alias => evalAlias(shell, args),
        .break_ => evalBreak(args),
        .bracket, .cd, .command, .dot, .eval, .exec, .export_, .pwd, .read, .test_, .type, .wait => unreachable,
        .continue_ => evalContinue(args),
        .exit => evalExit(shell, args),
        .false_ => .{ .status = 1 },
        .getopts => evalGetopts(shell, args),
        .printf => evalPrintf(shell, args),
        .readonly => evalReadonly(shell, args),
        .return_ => evalReturn(shell, args),
        .set => evalSet(shell, args),
        .shift => evalShift(shell, args),
        .umask => evalUmask(shell, args),
        .unalias => evalUnalias(shell, args),
        .unset => evalUnset(shell, args),
    };
}

fn evalAlias(shell: anytype, args: []const []const u8) !result.EvalResult {
    var status: result.ExitStatus = 0;
    if (args.len == 1) {
        var iterator = shell.state.aliases.iterator();
        while (iterator.next()) |entry| try writeAlias(shell, entry.value_ptr.*);
        return .{};
    }

    for (args[1..]) |arg| {
        if (aliasAssignment(arg)) |assignment| {
            try shell.state.putAlias(.{ .name = assignment.name, .value = assignment.value });
        } else if (shell.state.getAlias(arg)) |alias| {
            try writeAlias(shell, alias);
        } else {
            try shell.host.writeAll(.stderr, "alias: use name=value to define an alias\n");
            status = 1;
        }
    }
    return .{ .status = status };
}

const AliasAssignment = struct {
    name: []const u8,
    value: []const u8,
};

fn aliasAssignment(arg: []const u8) ?AliasAssignment {
    const equal_index = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    const name = arg[0..equal_index];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    return .{ .name = name, .value = arg[equal_index + 1 ..] };
}

pub fn writeAlias(shell: anytype, alias: state_mod.Alias) !void {
    try shell.host.writeAll(.stdout, alias.name);
    try shell.host.writeAll(.stdout, "='");
    for (alias.value, 0..) |byte, index| {
        if (byte == '\'') {
            try shell.host.writeAll(.stdout, "'\\''");
        } else {
            try shell.host.writeAll(.stdout, alias.value[index..][0..1]);
        }
    }
    try shell.host.writeAll(.stdout, "'\n");
}

fn evalUnalias(shell: anytype, args: []const []const u8) result.EvalResult {
    var all = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'a' => all = true,
            else => return .{ .status = 2 },
        };
    }

    if (all) {
        shell.state.clearAliases();
        return .{};
    }
    if (index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    for (args[index..]) |name| {
        if (!shell.state.removeAlias(name)) status = 1;
    }
    return .{ .status = status };
}

fn evalGetopts(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len < 3) return .{ .status = 2 };
    const optstring = args[1];
    const name = args[2];
    if (!isAssignmentName(name)) return .{ .status = 2 };

    const operands = if (args.len > 3) args[3..] else shell.state.positionals;
    var optind = getoptsOptind(shell);
    if (optind == 0) optind = 1;
    const operand_index = optind - 1;
    if (operand_index >= operands.len) {
        try putGetoptsOptind(shell, optind);
        shell.state.getopts_char_index = 1;
        return .{ .status = 1 };
    }

    const operand = operands[operand_index];
    if (shell.state.getopts_char_index == 1) {
        if (!isGetoptsOptionOperand(operand)) return .{ .status = 1 };
        if (std.mem.eql(u8, operand, "--")) {
            try putGetoptsOptind(shell, optind + 1);
            return .{ .status = 1 };
        }
    }

    if (shell.state.getopts_char_index >= operand.len) {
        shell.state.getopts_char_index = 1;
        try putGetoptsOptind(shell, optind + 1);
        return .{ .status = 1 };
    }

    const option = operand[shell.state.getopts_char_index];
    const option_index = std.mem.indexOfScalar(u8, optstring, option);
    if (option_index == null or option == ':') {
        try shell.state.putVariable(.{ .name = name, .value = "?" });
        try advanceGetopts(shell, optind, operand);
        return .{};
    }

    try shell.state.putVariable(.{ .name = name, .value = operand[shell.state.getopts_char_index..][0..1] });
    if (option_index.? + 1 < optstring.len and optstring[option_index.? + 1] == ':') {
        if (shell.state.getopts_char_index + 1 < operand.len) {
            try shell.state.putVariable(.{ .name = "OPTARG", .value = operand[shell.state.getopts_char_index + 1 ..] });
            shell.state.getopts_char_index = 1;
            try putGetoptsOptind(shell, optind + 1);
        } else if (operand_index + 1 < operands.len) {
            try shell.state.putVariable(.{ .name = "OPTARG", .value = operands[operand_index + 1] });
            shell.state.getopts_char_index = 1;
            try putGetoptsOptind(shell, optind + 2);
        } else {
            try shell.state.putVariable(.{ .name = name, .value = "?" });
            try shell.state.putVariable(.{ .name = "OPTARG", .value = operand[shell.state.getopts_char_index..][0..1] });
            shell.state.getopts_char_index = 1;
            try putGetoptsOptind(shell, optind + 1);
        }
    } else {
        try advanceGetopts(shell, optind, operand);
    }
    return .{};
}

fn getoptsOptind(shell: anytype) usize {
    const value = if (shell.state.getVariable("OPTIND")) |variable| variable.value else "1";
    return std.fmt.parseInt(usize, value, 10) catch 1;
}

fn putGetoptsOptind(shell: anytype, optind: usize) !void {
    const value = try std.fmt.allocPrint(shell.scratchAllocator(), "{}", .{optind});
    try shell.state.putVariable(.{ .name = "OPTIND", .value = value });
}

fn advanceGetopts(shell: anytype, optind: usize, operand: []const u8) !void {
    shell.state.getopts_char_index += 1;
    if (shell.state.getopts_char_index >= operand.len) {
        shell.state.getopts_char_index = 1;
        try putGetoptsOptind(shell, optind + 1);
    } else {
        try putGetoptsOptind(shell, optind);
    }
}

fn isGetoptsOptionOperand(operand: []const u8) bool {
    return operand.len >= 2 and operand[0] == '-' and !std.mem.eql(u8, operand, "-");
}

fn evalUmask(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    const current = currentUmask(shell);
    if (args.len == 1) {
        try shell.host.writeAll(.stdout, try std.fmt.allocPrint(shell.scratchAllocator(), "{o:0>4}\n", .{current}));
        return .{};
    }
    if (std.mem.eql(u8, args[1], "-S")) {
        try shell.host.writeAll(.stdout, try symbolicUmask(shell, current));
        return .{};
    }

    const new_mask = parseOctalUmask(args[1]) orelse parseSymbolicUmask(current, args[1]) orelse return .{ .status = 2 };
    _ = shell.host.setFileCreationMask(new_mask);
    return .{};
}

fn currentUmask(shell: anytype) u32 {
    const current = shell.host.setFileCreationMask(0);
    _ = shell.host.setFileCreationMask(current);
    return current & 0o777;
}

fn parseOctalUmask(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    var value: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '7') return null;
        value = value * 8 + byte - '0';
        if (value > 0o777) return null;
    }
    return value;
}

fn symbolicUmask(shell: anytype, mask: u32) ![]const u8 {
    const allowed = (~mask) & 0o777;
    return std.fmt.allocPrint(
        shell.scratchAllocator(),
        "u={s}{s}{s},g={s}{s}{s},o={s}{s}{s}\n",
        .{
            if ((allowed & 0o400) != 0) "r" else "",
            if ((allowed & 0o200) != 0) "w" else "",
            if ((allowed & 0o100) != 0) "x" else "",
            if ((allowed & 0o040) != 0) "r" else "",
            if ((allowed & 0o020) != 0) "w" else "",
            if ((allowed & 0o010) != 0) "x" else "",
            if ((allowed & 0o004) != 0) "r" else "",
            if ((allowed & 0o002) != 0) "w" else "",
            if ((allowed & 0o001) != 0) "x" else "",
        },
    );
}

fn parseSymbolicUmask(current: u32, text: []const u8) ?u32 {
    var mask = current & 0o777;
    var iterator = std.mem.splitScalar(u8, text, ',');
    while (iterator.next()) |clause| {
        if (clause.len == 0) return null;
        mask = applyUmaskClause(mask, clause) orelse return null;
    }
    return mask;
}

fn applyUmaskClause(current: u32, clause: []const u8) ?u32 {
    var index: usize = 0;
    var who_mask: u32 = 0;
    while (index < clause.len) : (index += 1) switch (clause[index]) {
        'u' => who_mask |= 0o700,
        'g' => who_mask |= 0o070,
        'o' => who_mask |= 0o007,
        'a' => who_mask |= 0o777,
        '+', '-', '=' => break,
        else => return null,
    };
    if (who_mask == 0) who_mask = 0o777;
    if (index >= clause.len) return null;
    const op = clause[index];
    index += 1;

    var permissions: u32 = 0;
    while (index < clause.len) : (index += 1) switch (clause[index]) {
        'r' => permissions |= permissionsForWho(who_mask, 0o444),
        'w' => permissions |= permissionsForWho(who_mask, 0o222),
        'x' => permissions |= permissionsForWho(who_mask, 0o111),
        else => return null,
    };

    const updated: u32 = switch (op) {
        '+' => current & ~permissions,
        '-' => current | permissions,
        '=' => (current & ~who_mask) | (who_mask & ~permissions),
        else => unreachable,
    };
    return updated & 0o777;
}

fn permissionsForWho(who_mask: u32, permissions: u32) u32 {
    return who_mask & permissions;
}

fn evalExit(shell: anytype, args: []const []const u8) result.EvalResult {
    const status = if (args.len > 1) parseExitStatus(args[1]) else shell.state.last_status;
    return .{ .status = status, .flow = .{ .exit = status } };
}

fn evalReturn(shell: anytype, args: []const []const u8) result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    const status = if (args.len > 1) parseExitStatus(args[1]) else shell.state.last_status;
    return .{ .status = status, .flow = .{ .return_ = status } };
}

fn parseExitStatus(text: []const u8) result.ExitStatus {
    const value = std.fmt.parseInt(u64, text, 10) catch return 2;
    return @truncate(value);
}

fn evalShift(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    const count = if (args.len == 1) 1 else std.fmt.parseInt(usize, args[1], 10) catch return .{ .status = 2 };
    if (count > shell.state.positionals.len) return .{ .status = 1 };
    try shell.state.setPositionals(shell.state.positionals[count..]);
    return .{};
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
        if (std.mem.eql(u8, arg[1..], "o")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            if (std.mem.eql(u8, args[index], "pipefail")) {
                shell.state.options.pipefail = enabled;
                continue;
            }
            return .{ .status = 2 };
        }
        for (arg[1..]) |option| switch (option) {
            'C' => shell.state.options.noclobber = enabled,
            'e' => shell.state.options.errexit = enabled,
            'f' => shell.state.options.noglob = enabled,
            'u' => shell.state.options.nounset = enabled,
            else => return .{ .status = 2 },
        };
    }
    return .{};
}

fn evalUnset(shell: anytype, args: []const []const u8) result.EvalResult {
    var functions = false;
    var variables = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'f' => functions = true,
            'v' => variables = true,
            else => return .{ .status = 2 },
        };
    }
    if (functions and variables) return .{ .status = 2 };
    const unset_functions = functions and !variables;
    var status: result.ExitStatus = 0;
    for (args[index..]) |name| {
        if (!isAssignmentName(name) and !unset_functions) {
            status = 2;
            continue;
        }
        if (unset_functions) {
            if (std.mem.indexOfScalar(u8, name, '/') == null) shell.state.removeFunction(name);
        } else if (shell.state.getVariable(name)) |variable| {
            if (variable.readonly) {
                status = 1;
            } else {
                shell.state.removeVariable(name);
            }
        }
    }
    return .{ .status = status };
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
    try std.testing.expectEqual(Id.bracket, lookup("[").?.id);
    try std.testing.expectEqual(Id.alias, lookup("alias").?.id);
    try std.testing.expectEqual(Id.break_, lookup("break").?.id);
    try std.testing.expectEqual(Id.cd, lookup("cd").?.id);
    try std.testing.expectEqual(Id.colon, lookup(":").?.id);
    try std.testing.expectEqual(Id.dot, lookup(".").?.id);
    try std.testing.expectEqual(Id.command, lookup("command").?.id);
    try std.testing.expectEqual(Id.continue_, lookup("continue").?.id);
    try std.testing.expectEqual(Id.eval, lookup("eval").?.id);
    try std.testing.expectEqual(Id.exec, lookup("exec").?.id);
    try std.testing.expectEqual(Id.export_, lookup("export").?.id);
    try std.testing.expectEqual(Id.exit, lookup("exit").?.id);
    try std.testing.expectEqual(Id.getopts, lookup("getopts").?.id);
    try std.testing.expectEqual(Id.true_, lookup("true").?.id);
    try std.testing.expectEqual(Id.false_, lookup("false").?.id);
    try std.testing.expectEqual(Id.printf, lookup("printf").?.id);
    try std.testing.expectEqual(Id.pwd, lookup("pwd").?.id);
    try std.testing.expectEqual(Id.read, lookup("read").?.id);
    try std.testing.expectEqual(Id.readonly, lookup("readonly").?.id);
    try std.testing.expectEqual(Id.type, lookup("type").?.id);
    try std.testing.expectEqual(Id.test_, lookup("test").?.id);
    try std.testing.expectEqual(Id.umask, lookup("umask").?.id);
    try std.testing.expectEqual(Id.unalias, lookup("unalias").?.id);
    try std.testing.expectEqual(Id.unset, lookup("unset").?.id);
    try std.testing.expectEqual(Id.wait, lookup("wait").?.id);
    try std.testing.expectEqual(@as(?Definition, null), lookup("missing"));
}

test "builtin eval returns utility status" {
    const TestHost = struct {
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
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
    const true_definition = lookup("true").?;
    const false_definition = lookup("false").?;

    try std.testing.expectEqual(@as(result.ExitStatus, 0), (try eval(&shell, true_definition, &.{"true"})).status);
    try std.testing.expectEqual(@as(result.ExitStatus, 1), (try eval(&shell, false_definition, &.{"false"})).status);
}

test "exit builtin returns requested exit flow" {
    const TestHost = struct {
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
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

        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
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
