//! Command-line shell invocation parsing.

const std = @import("std");

const compat = @import("compat.zig");
const shell = @import("shell.zig");

pub const Kind = enum { command_string, script_file, standard_input };

pub const ShellInvocation = struct {
    kind: Kind,
    source: []const u8,
    features: compat.Features = .{},
    shell_options: shell.ShellOptions = .{},
    monitor_option_explicit: bool = false,
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
    interactive: bool = false,
};

pub const CommandStringInvocation = ShellInvocation;

pub fn parseCommandString(args: []const []const u8) ?CommandStringInvocation {
    const invocation = parse(args) orelse return null;
    if (invocation.kind != .command_string) return null;
    return invocation;
}

pub fn parse(args: []const []const u8) ?ShellInvocation {
    std.debug.assert(args.len != 0);

    var features: compat.Features = .{};
    var shell_options: shell.ShellOptions = .{};
    var monitor_option_explicit = false;
    var interactive_mode = false;
    var command_string = false;
    var standard_input = false;
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--posix-strict")) {
            features = .strictPosix();
            index += 1;
            continue;
        }
        if (arg.len == 0 or (arg[0] != '-' and arg[0] != '+')) break;
        if (arg.len == 1 or (arg[0] == '-' and arg[1] == '-')) return null;

        const enabled = arg[0] == '-';
        var option_index: usize = 1;
        while (option_index < arg.len) : (option_index += 1) {
            const option = arg[option_index];
            if (enabled and option == 'c') {
                command_string = true;
            } else if (enabled and option == 's') {
                standard_input = true;
            } else if (enabled and option == 'i') {
                interactive_mode = true;
            } else if (option == 'o') {
                if (index + 1 >= args.len) return null;
                index += 1;
                const option_name = args[index];
                if (!shell.applyShellOptionName(&shell_options, option_name, enabled)) return null;
                if (std.mem.eql(u8, option_name, "monitor")) monitor_option_explicit = true;
            } else {
                var option_spelling = [_]u8{ arg[0], option };
                if (!shell.applyShellOptionShort(&shell_options, option_spelling[0..])) return null;
                if (option == 'm') monitor_option_explicit = true;
            }
        }

        index += 1;
    }

    const operands = args[index..];
    if (command_string) {
        if (operands.len == 0) return null;
        const arg_zero = if (operands.len >= 2) operands[1] else args[0];
        const positionals = if (operands.len >= 3) operands[2..] else &.{};
        return .{ .kind = .command_string, .source = operands[0], .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = arg_zero, .positionals = positionals, .interactive = interactive_mode };
    }
    if (standard_input) {
        return .{ .kind = .standard_input, .source = "-", .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = args[0], .positionals = operands, .interactive = interactive_mode };
    }
    if (operands.len != 0) {
        const path = operands[0];
        return .{ .kind = .script_file, .source = path, .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = path, .positionals = operands[1..], .interactive = interactive_mode };
    }
    return .{ .kind = .standard_input, .source = "-", .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = args[0], .interactive = interactive_mode };
}

pub fn shouldRunInteractiveStandardInput(invocation: ShellInvocation, stdin_is_tty: bool, stderr_is_tty: bool) bool {
    if (invocation.kind != .standard_input) return false;
    if (invocation.interactive) return stdin_is_tty;
    return stdin_is_tty and stderr_is_tty;
}

pub fn isLoginArgZero(arg_zero: []const u8) bool {
    const base = std.fs.path.basename(arg_zero);
    return base.len != 0 and base[0] == '-';
}

test "command string invocation accepts interactive flag before -c" {
    const invocation = parseCommandString(&.{ "rush", "-i", "-c", "exit" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqualStrings("exit", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 0), invocation.positionals.len);
    try std.testing.expect(invocation.interactive);
    try std.testing.expect(!invocation.features.strict_diagnostics);
}

test "command string invocation accepts posix strict with interactive flag before -c" {
    const cases = [_][]const []const u8{
        &.{ "rush", "--posix-strict", "-i", "-c", "echo positional", "name", "one" },
        &.{ "rush", "-i", "--posix-strict", "-c", "echo positional", "name", "one" },
    };

    for (cases) |args| {
        const invocation = parseCommandString(args) orelse return error.ExpectedInvocation;
        try std.testing.expectEqualStrings("echo positional", invocation.source);
        try std.testing.expectEqualStrings("name", invocation.arg_zero);
        try std.testing.expectEqual(@as(usize, 1), invocation.positionals.len);
        try std.testing.expectEqualStrings("one", invocation.positionals[0]);
        try std.testing.expect(invocation.interactive);
        try std.testing.expect(invocation.features.strict_diagnostics);
    }
}

test "command string invocation accepts set option flags before -c" {
    const invocation = parseCommandString(
        &.{ "rush", "-eu", "-o", "pipefail", "-c", "echo positional", "name", "-o", "nounset" },
    ) orelse return error.ExpectedInvocation;

    try std.testing.expectEqualStrings("echo positional", invocation.source);
    try std.testing.expectEqualStrings("name", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("-o", invocation.positionals[0]);
    try std.testing.expectEqualStrings("nounset", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);
    try std.testing.expect(invocation.shell_options.nounset);
    try std.testing.expect(invocation.shell_options.pipefail);
}

test "command string invocation continues option parsing after -c" {
    const invocation = parseCommandString(
        &.{ "rush", "-c", "-e", "printf '%s:%s:%s\n' \"$0\" \"$1\" \"$2\"", "name", "one", "two" },
    ) orelse return error.ExpectedInvocation;

    try std.testing.expectEqualStrings("printf '%s:%s:%s\n' \"$0\" \"$1\" \"$2\"", invocation.source);
    try std.testing.expectEqualStrings("name", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("one", invocation.positionals[0]);
    try std.testing.expectEqualStrings("two", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);
}

test "command string invocation accepts -c in clustered short options" {
    const invocation = parseCommandString(
        &.{ "rush", "-ec", "printf '%s:%s:%s\n' \"$0\" \"$1\" \"$2\"", "name", "one", "two" },
    ) orelse return error.ExpectedInvocation;

    try std.testing.expectEqualStrings("printf '%s:%s:%s\n' \"$0\" \"$1\" \"$2\"", invocation.source);
    try std.testing.expectEqualStrings("name", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("one", invocation.positionals[0]);
    try std.testing.expectEqualStrings("two", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);
}

test "command string invocation lets -c win when clustered with -s" {
    const sc_invocation = parseCommandString(&.{ "rush", "-sc", "echo ok" }) orelse return error.ExpectedInvocation;
    try std.testing.expectEqualStrings("echo ok", sc_invocation.source);
    try std.testing.expectEqualStrings("rush", sc_invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 0), sc_invocation.positionals.len);

    const cs_invocation = parseCommandString(&.{ "rush", "-cs", "echo ok" }) orelse return error.ExpectedInvocation;
    try std.testing.expectEqualStrings("echo ok", cs_invocation.source);
    try std.testing.expectEqualStrings("rush", cs_invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 0), cs_invocation.positionals.len);
}

test "standard input invocation continues option parsing after -s" {
    const invocation = parse(&.{ "rush", "-s", "-e", "posarg", "two words" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(Kind.standard_input, invocation.kind);
    try std.testing.expectEqualStrings("-", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("posarg", invocation.positionals[0]);
    try std.testing.expectEqualStrings("two words", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);
}

test "script file invocation accepts options before script operand" {
    const invocation = parse(
        &.{ "rush", "--posix-strict", "-eu", "-o", "pipefail", "script.rush", "-o", "nounset" },
    ) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(Kind.script_file, invocation.kind);
    try std.testing.expectEqualStrings("script.rush", invocation.source);
    try std.testing.expectEqualStrings("script.rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("-o", invocation.positionals[0]);
    try std.testing.expectEqualStrings("nounset", invocation.positionals[1]);
    try std.testing.expect(invocation.features.strict_diagnostics);
    try std.testing.expect(invocation.shell_options.errexit);
    try std.testing.expect(invocation.shell_options.nounset);
    try std.testing.expect(invocation.shell_options.pipefail);
}

test "script file invocation accepts option terminator" {
    const invocation = parse(&.{ "rush", "-e", "--", "-script.rush", "arg" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(Kind.script_file, invocation.kind);
    try std.testing.expectEqualStrings("-script.rush", invocation.source);
    try std.testing.expectEqualStrings("-script.rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 1), invocation.positionals.len);
    try std.testing.expectEqualStrings("arg", invocation.positionals[0]);
    try std.testing.expect(invocation.shell_options.errexit);
}

test "command string invocation rejects invalid set option flags" {
    try std.testing.expect(parseCommandString(&.{ "rush", "-z", "-c", "echo bad" }) == null);
    try std.testing.expect(parseCommandString(&.{ "rush", "+z", "-c", "echo bad" }) == null);
    try std.testing.expect(parseCommandString(&.{ "rush", "-o", "-c", "echo bad" }) == null);
    try std.testing.expect(parseCommandString(&.{ "rush", "-o", "unknown", "-c", "echo bad" }) == null);
    try std.testing.expect(parse(&.{ "rush", "-z", "script.rush" }) == null);
    try std.testing.expect(parse(&.{ "rush", "+z", "script.rush" }) == null);
}

test "command string invocation still requires -c" {
    try std.testing.expect(parseCommandString(&.{ "rush", "-i" }) == null);
}

test "login shell detection follows argv0 dash convention" {
    try std.testing.expect(isLoginArgZero("-rush"));
    try std.testing.expect(isLoginArgZero("/bin/-rush"));
    try std.testing.expect(!isLoginArgZero("rush"));
    try std.testing.expect(!isLoginArgZero("/bin/rush"));
}
