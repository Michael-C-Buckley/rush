//! Minimal command-line invocation parsing for the rewrite bootstrap.

const std = @import("std");

const state = @import("state.zig");

pub const ParseError = error{
    MissingCommandString,
    UnsupportedOption,
    UnexpectedOperand,
};

pub const Invocation = union(enum) {
    help,
    command_string: CommandString,
    script_file: ScriptFile,
};

pub const CommandString = struct {
    mode: state.Mode = .bash,
    options: state.Options = .{},
    script: []const u8,
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
};

pub const ScriptFile = struct {
    mode: state.Mode = .bash,
    options: state.Options = .{},
    path: []const u8,
    positionals: []const []const u8 = &.{},
};

pub fn parse(args: []const []const u8) ParseError!Invocation {
    std.debug.assert(args.len != 0);

    var mode: state.Mode = .bash;
    var options: state.Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "--posix")) {
            mode = .posix;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            if (index + 1 >= args.len) return error.MissingCommandString;
            options.mode = mode;
            return .{ .script_file = .{
                .mode = mode,
                .options = options,
                .path = args[index + 1],
                .positionals = args[index + 2 ..],
            } };
        }
        if (arg.len > 1 and arg[0] == '-' and !std.mem.eql(u8, arg, "-c")) {
            for (arg[1..]) |option| switch (option) {
                'i' => options.interactive = true,
                'x' => options.xtrace = true,
                else => return error.UnsupportedOption,
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "-c")) {
            if (index + 1 >= args.len) return error.MissingCommandString;
            const script = args[index + 1];
            const operands = args[index + 2 ..];
            const arg_zero = if (operands.len == 0) args[0] else operands[0];
            const positionals = if (operands.len <= 1) &.{} else operands[1..];
            options.mode = mode;
            return .{ .command_string = .{
                .mode = mode,
                .options = options,
                .script = script,
                .arg_zero = arg_zero,
                .positionals = positionals,
            } };
        }
        if (arg.len != 0 and arg[0] == '-') return error.UnsupportedOption;
        options.mode = mode;
        return .{ .script_file = .{
            .mode = mode,
            .options = options,
            .path = arg,
            .positionals = args[index + 1 ..],
        } };
    }

    return error.MissingCommandString;
}

test "invocation parses POSIX command string" {
    const args = [_][]const u8{ "rush", "--posix", "-c", ":", "name", "a" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.posix, command.mode);
    try std.testing.expectEqual(state.Mode.posix, command.options.mode);
    try std.testing.expectEqualStrings(":", command.script);
    try std.testing.expectEqualStrings("name", command.arg_zero);
    try std.testing.expectEqual(@as(usize, 1), command.positionals.len);
    try std.testing.expectEqualStrings("a", command.positionals[0]);
}

test "invocation parses xtrace option" {
    const args = [_][]const u8{ "rush", "--posix", "-x", "-c", ":" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(command.options.xtrace);
    try std.testing.expectEqual(state.Mode.posix, command.options.mode);
}

test "invocation parses POSIX script file" {
    const args = [_][]const u8{ "rush", "--posix", "script.sh", "a", "b" };
    const invocation = try parse(&args);
    const script = switch (invocation) {
        .script_file => |script| script,
        .command_string, .help => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.posix, script.mode);
    try std.testing.expectEqual(state.Mode.posix, script.options.mode);
    try std.testing.expectEqualStrings("script.sh", script.path);
    try std.testing.expectEqual(@as(usize, 2), script.positionals.len);
    try std.testing.expectEqualStrings("a", script.positionals[0]);
    try std.testing.expectEqualStrings("b", script.positionals[1]);
}

test "invocation parses script file after option terminator" {
    const args = [_][]const u8{ "rush", "--posix", "--", "-script", "a" };
    const invocation = try parse(&args);
    const script = switch (invocation) {
        .script_file => |script| script,
        .command_string, .help => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(state.Mode.posix, script.options.mode);
    try std.testing.expectEqualStrings("-script", script.path);
    try std.testing.expectEqual(@as(usize, 1), script.positionals.len);
    try std.testing.expectEqualStrings("a", script.positionals[0]);
}

test "invocation parses interactive option" {
    const args = [_][]const u8{ "rush", "--posix", "-i", "-c", ":" };
    const invocation = try parse(&args);
    const command = switch (invocation) {
        .command_string => |command| command,
        .help, .script_file => return error.TestExpectedEqual,
    };
    try std.testing.expect(command.options.interactive);
    try std.testing.expectEqual(state.Mode.posix, command.options.mode);
}
