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

pub const Origin = enum {
    core,
    extension,
};

pub const Id = enum {
    abbr,
    alias,
    bg,
    bracket,
    break_,
    cd,
    color,
    colon,
    dot,
    command,
    continue_,
    event,
    eval,
    exec,
    export_,
    exit,
    false_,
    fg,
    getopts,
    hash,
    jobs,
    kill,
    local,
    prompt,
    prompt_async,
    prompt_duration,
    prompt_pwd,
    rush_complete,
    rush_env,
    printf,
    pwd,
    read,
    readonly,
    return_,
    set,
    shift,
    shopt,
    source,
    test_,
    times,
    trap,
    true_,
    type,
    ulimit,
    umask,
    unalias,
    unset,
    wait,
};

pub const Definition = struct {
    name: []const u8,
    id: Id,
    kind: Kind,
    origin: Origin = .core,

    pub fn validate(self: Definition) void {
        std.debug.assert(self.name.len != 0);
    }
};

const DefinitionMap = std.StaticStringMap(Definition);

pub const core_definitions: DefinitionMap = .initComptime(.{
    .{ "[", Definition{ .name = "[", .id = .bracket, .kind = .regular } },
    .{ "alias", Definition{ .name = "alias", .id = .alias, .kind = .regular } },
    .{ "bg", Definition{ .name = "bg", .id = .bg, .kind = .regular } },
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
    .{ "fg", Definition{ .name = "fg", .id = .fg, .kind = .regular } },
    .{ "getopts", Definition{ .name = "getopts", .id = .getopts, .kind = .regular } },
    .{ "hash", Definition{ .name = "hash", .id = .hash, .kind = .regular } },
    .{ "jobs", Definition{ .name = "jobs", .id = .jobs, .kind = .regular } },
    .{ "kill", Definition{ .name = "kill", .id = .kill, .kind = .regular } },
    .{ "local", Definition{ .name = "local", .id = .local, .kind = .regular } },
    .{ "printf", Definition{ .name = "printf", .id = .printf, .kind = .regular } },
    .{ "pwd", Definition{ .name = "pwd", .id = .pwd, .kind = .regular } },
    .{ "read", Definition{ .name = "read", .id = .read, .kind = .regular } },
    .{ "readonly", Definition{ .name = "readonly", .id = .readonly, .kind = .special } },
    .{ "return", Definition{ .name = "return", .id = .return_, .kind = .special } },
    .{ "set", Definition{ .name = "set", .id = .set, .kind = .special } },
    .{ "shift", Definition{ .name = "shift", .id = .shift, .kind = .special } },
    .{ "shopt", Definition{ .name = "shopt", .id = .shopt, .kind = .regular } },
    .{ "source", Definition{ .name = "source", .id = .source, .kind = .regular } },
    .{ "test", Definition{ .name = "test", .id = .test_, .kind = .regular } },
    .{ "times", Definition{ .name = "times", .id = .times, .kind = .special } },
    .{ "trap", Definition{ .name = "trap", .id = .trap, .kind = .special } },
    .{ "true", Definition{ .name = "true", .id = .true_, .kind = .regular } },
    .{ "type", Definition{ .name = "type", .id = .type, .kind = .regular } },
    .{ "ulimit", Definition{ .name = "ulimit", .id = .ulimit, .kind = .regular } },
    .{ "umask", Definition{ .name = "umask", .id = .umask, .kind = .regular } },
    .{ "unalias", Definition{ .name = "unalias", .id = .unalias, .kind = .regular } },
    .{ "unset", Definition{ .name = "unset", .id = .unset, .kind = .special } },
    .{ "wait", Definition{ .name = "wait", .id = .wait, .kind = .regular } },
});

pub const Registry = struct {
    extensions: []const Definition = &.{},
    ExtensionState: type = EmptyExtensionState,

    pub fn lookup(comptime self: Registry, name: []const u8) ?Definition {
        if (core_definitions.get(name)) |definition| {
            definition.validate();
            return definition;
        }
        inline for (self.extensions) |definition| {
            if (std.mem.eql(u8, definition.name, name)) {
                definition.validate();
                return definition;
            }
        }
        return null;
    }
};

pub const EmptyExtensionState = struct {
    pub fn init(_: std.mem.Allocator) EmptyExtensionState {
        return .{};
    }

    pub fn deinit(_: *EmptyExtensionState) void {}

    pub fn eval(
        _: *EmptyExtensionState,
        _: anytype,
        _: Definition,
        _: []const []const u8,
    ) !result.EvalResult {
        return .{ .status = 127 };
    }
};

pub const core_registry: Registry = .{};
pub const default_registry: Registry = core_registry;

pub fn extensionDefinition(comptime name: []const u8, comptime id: Id) Definition {
    return .{ .name = name, .id = id, .kind = .regular, .origin = .extension };
}

pub fn lookup(name: []const u8) ?Definition {
    return default_registry.lookup(name);
}

pub fn lookupInMode(name: []const u8, mode: state_mod.Mode) ?Definition {
    const definition = lookup(name) orelse return null;
    if (mode == .posix and (definition.id == .local or definition.id == .source or definition.id == .shopt)) return null;
    return definition;
}

pub fn eval(shell: anytype, definition: Definition, args: []const []const u8) !result.EvalResult {
    definition.validate();
    std.debug.assert(args.len != 0);
    if (definition.origin == .extension) return evalExtension(shell, definition, args);
    return switch (definition.id) {
        .colon, .true_ => .{},
        .alias => evalAlias(shell, args),
        .bg => evalBg(shell, args),
        .break_ => evalBreak(args),
        .bracket, .cd, .command, .dot, .eval, .exec, .export_, .pwd, .read, .test_, .type, .wait => unreachable,
        .continue_ => evalContinue(args),
        .exit => evalExit(shell, args),
        .false_ => .{ .status = 1 },
        .fg => evalFg(shell, args),
        .getopts => evalGetopts(shell, args),
        .hash => evalHash(shell, args),
        .jobs => evalJobs(shell, args),
        .kill => evalKill(shell, args),
        .local => evalLocal(shell, args),
        .printf => evalPrintf(shell, args),
        .readonly => evalReadonly(shell, args),
        .return_ => evalReturn(shell, args),
        .set => evalSet(shell, args),
        .shift => evalShift(shell, args),
        .shopt => evalShopt(shell, args),
        .source => unreachable,
        .times => evalTimes(shell, args),
        .trap => evalTrap(shell, args),
        .ulimit => .{},
        .umask => evalUmask(shell, args),
        .unalias => evalUnalias(shell, args),
        .unset => evalUnset(shell, args),
        .abbr, .color, .event, .prompt, .prompt_async, .prompt_duration, .prompt_pwd, .rush_complete, .rush_env => unreachable,
    };
}

fn evalExtension(shell: anytype, definition: Definition, args: []const []const u8) !result.EvalResult {
    const ShellType = switch (@typeInfo(@TypeOf(shell))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell),
    };
    if (!@hasDecl(ShellType, "evalExtensionBuiltin")) return .{ .status = 127 };
    return shell.evalExtensionBuiltin(definition, args);
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

fn evalShopt(shell: anytype, args: []const []const u8) result.EvalResult {
    var set_value: ?bool = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            's' => set_value = true,
            'u' => set_value = false,
            else => return .{ .status = 2 },
        };
    }

    if (set_value == null or index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    for (args[index..]) |name| {
        if (std.mem.eql(u8, name, "expand_aliases")) {
            shell.state.options.expand_aliases = set_value.?;
        } else {
            status = 1;
        }
    }
    return .{ .status = status };
}

fn evalHash(shell: anytype, args: []const []const u8) !result.EvalResult {
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'r' => shell.state.clearCommandHashes(),
            else => return .{ .status = 2 },
        };
    }

    if (index < args.len) return .{ .status = 2 };

    var iterator = shell.state.command_hashes.iterator();
    while (iterator.next()) |entry| {
        try shell.host.writeAll(.stdout, entry.value_ptr.path);
        try shell.host.writeAll(.stdout, "\n");
    }
    return .{};
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
        shell.state.removeVariable("OPTARG");
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
            const option_text = operand[shell.state.getopts_char_index..][0..1];
            if (std.mem.startsWith(u8, optstring, ":")) {
                try shell.state.putVariable(.{ .name = name, .value = ":" });
                try shell.state.putVariable(.{ .name = "OPTARG", .value = option_text });
            } else {
                try shell.state.putVariable(.{ .name = name, .value = "?" });
                shell.state.removeVariable("OPTARG");
            }
            shell.state.getopts_char_index = 1;
            try putGetoptsOptind(shell, optind + 1);
        }
    } else {
        shell.state.removeVariable("OPTARG");
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

fn evalKill(shell: anytype, args: []const []const u8) !result.EvalResult {
    var kill_signal: KillSignal = .{ .name = "TERM", .number = signalNumber("TERM").? };
    var index: usize = 1;
    if (index < args.len and std.mem.eql(u8, args[index], "-l")) return evalKillList(shell, args[index + 1 ..]);
    if (index < args.len and std.mem.eql(u8, args[index], "-s")) {
        index += 1;
        if (index >= args.len) return .{ .status = 2 };
        kill_signal = parseKillSignal(args[index]) orelse return .{ .status = 2 };
        index += 1;
    } else if (index < args.len and args[index].len > 1 and args[index][0] == '-') {
        kill_signal = parseKillSignal(args[index][1..]) orelse return .{ .status = 2 };
        index += 1;
    }
    if (index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    while (index < args.len) : (index += 1) {
        if (killOperandJob(shell, args[index])) |job| {
            shell.host.sendSignal(-job.process_group, kill_signal.number) catch {
                status = 1;
                continue;
            };
            continue;
        }
        const pid = killOperandPid(shell, args[index]) orelse {
            status = 1;
            continue;
        };
        if (kill_signal.name) |signal_name| {
            if (pid == shell.host.currentProcessId() and shell.state.getSignalTrap(signal_name) != null) {
                try shell.state.queueTrap(signal_name);
                continue;
            }
        }
        shell.host.sendSignal(pid, kill_signal.number) catch {
            status = 1;
            continue;
        };
    }
    return .{ .status = status };
}

fn killOperandPid(shell: anytype, arg: []const u8) ?host.Pid {
    _ = shell;
    if (arg.len >= 1 and arg[0] == '%') return null;
    return std.fmt.parseInt(host.Pid, arg, 10) catch null;
}

fn killOperandJob(shell: anytype, arg: []const u8) ?state_mod.BackgroundJob {
    if (!shell.state.options.monitor) return null;
    return jobOperand(shell, arg);
}

fn evalJobs(shell: anytype, args: []const []const u8) !result.EvalResult {
    var format: JobFormat = .default;
    var first_operand: usize = 1;
    while (first_operand < args.len) : (first_operand += 1) {
        const arg = args[first_operand];
        if (std.mem.eql(u8, arg, "-l")) {
            if (format != .default) return .{ .status = 2 };
            format = .long;
        } else if (std.mem.eql(u8, arg, "-p")) {
            if (format != .default) return .{ .status = 2 };
            format = .pid;
        } else break;
    }

    if (first_operand == args.len) {
        for (shell.state.background_jobs.items) |job| try writeJob(shell, job, format);
        return .{};
    }

    var status: result.ExitStatus = 0;
    for (args[first_operand..]) |arg| {
        const job = jobOperand(shell, arg) orelse {
            try shell.host.writeAll(.stderr, "jobs: no such job\n");
            status = 1;
            continue;
        };
        try writeJob(shell, job, format);
    }
    return .{ .status = status };
}

const JobFormat = enum { default, long, pid };

fn writeJob(shell: anytype, job: state_mod.BackgroundJob, format: JobFormat) !void {
    const text = switch (format) {
        .default => try std.fmt.allocPrint(
            shell.scratchAllocator(),
            "[{}] Running {s}\n",
            .{ job.id, job.command },
        ),
        .long => try std.fmt.allocPrint(
            shell.scratchAllocator(),
            "[{}] {} Running {s}\n",
            .{ job.id, job.pid, job.command },
        ),
        .pid => try std.fmt.allocPrint(shell.scratchAllocator(), "{}\n", .{job.process_group}),
    };
    defer shell.scratchAllocator().free(text);
    try shell.host.writeAll(.stdout, text);
}

fn jobOperand(shell: anytype, arg: []const u8) ?state_mod.BackgroundJob {
    if (arg.len < 2 or arg[0] != '%') return null;
    const job_id = std.fmt.parseInt(usize, arg[1..], 10) catch return null;
    return shell.state.backgroundJob(job_id);
}

fn jobOperandOrCurrent(shell: anytype, arg: ?[]const u8) ?state_mod.BackgroundJob {
    if (arg) |job_spec| {
        return jobOperand(shell, job_spec);
    }
    return shell.state.currentBackgroundJob();
}

fn writeNoSuchJob(shell: anytype, builtin_name: []const u8) !void {
    try shell.host.writeAll(
        .stderr,
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: no such job\n", .{builtin_name}),
    );
}

fn writeNoCurrentJob(shell: anytype, builtin_name: []const u8) !void {
    try shell.host.writeAll(
        .stderr,
        try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: no current job\n", .{builtin_name}),
    );
}

fn resumeBackgroundJob(shell: anytype, job: state_mod.BackgroundJob) !result.EvalResult {
    sendContinueToJob(shell, job) catch return .{ .status = 1 };
    const text = try std.fmt.allocPrint(shell.scratchAllocator(), "[{}] {s}\n", .{ job.id, job.command });
    defer shell.scratchAllocator().free(text);
    try shell.host.writeAll(.stdout, text);
    return .{};
}

fn foregroundJob(shell: anytype, job: state_mod.BackgroundJob) !result.EvalResult {
    sendContinueToJob(shell, job) catch return .{ .status = 1 };
    const text = try std.fmt.allocPrint(shell.scratchAllocator(), "{s}\n", .{job.command});
    defer shell.scratchAllocator().free(text);
    try shell.host.writeAll(.stdout, text);
    const foreground_restore_group = giveTerminalToJob(shell, job.process_group) catch return .{ .status = 1 };
    defer if (foreground_restore_group) |process_group| restoreTerminalToShell(shell, process_group);
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "waitInterruptible")) return .{ .status = 1 };
    const pids = try shell.scratchAllocator().dupe(host.Pid, job.pids.items);
    defer shell.scratchAllocator().free(pids);
    var status: result.ExitStatus = 0;
    for (pids) |pid| {
        _ = shell.state.removeBackgroundPid(pid);
        const waited = shell.host.waitInterruptible(pid) catch return .{ .status = 127 };
        status = waited.shellStatus();
    }
    return .{ .status = status };
}

fn giveTerminalToJob(shell: anytype, process_group: host.Pid) !?host.Pid {
    if (!shell.state.options.monitor) return null;
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "terminalProcessGroup") or
        !@hasDecl(HostType, "setTerminalProcessGroup")) return null;
    const shell_process_group = shell.host.terminalProcessGroup(.stdin) catch |err| switch (err) {
        error.NotATerminal => return null,
        else => return err,
    };
    shell.host.setTerminalProcessGroup(.stdin, process_group) catch |err| switch (err) {
        error.NotATerminal => return null,
        else => return err,
    };
    return shell_process_group;
}

fn restoreTerminalToShell(shell: anytype, process_group: host.Pid) void {
    const HostType = switch (@typeInfo(@TypeOf(shell.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(shell.host),
    };
    if (!@hasDecl(HostType, "setTerminalProcessGroup")) return;
    shell.host.setTerminalProcessGroup(.stdin, process_group) catch {};
}

fn sendContinueToJob(shell: anytype, job: state_mod.BackgroundJob) !void {
    const cont = signalNumber("CONT") orelse return error.InvalidSignal;
    if (shell.state.options.monitor) {
        try shell.host.sendSignal(-job.process_group, cont);
        return;
    }
    var failed = false;
    for (job.pids.items) |pid| {
        shell.host.sendSignal(pid, cont) catch {
            failed = true;
        };
    }
    if (failed) return error.SignalFailed;
}

fn evalBg(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) {
        const job = shell.state.currentBackgroundJob() orelse {
            try writeNoCurrentJob(shell, "bg");
            return .{ .status = 1 };
        };
        return resumeBackgroundJob(shell, job);
    }

    var status: result.ExitStatus = 0;
    for (args[1..]) |arg| {
        const job = jobOperandOrCurrent(shell, arg) orelse {
            try writeNoSuchJob(shell, "bg");
            status = 1;
            continue;
        };
        const evaluated = try resumeBackgroundJob(shell, job);
        if (evaluated.status != 0) status = evaluated.status;
    }
    return .{ .status = status };
}

fn evalFg(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len > 2) return .{ .status = 2 };
    const job = jobOperandOrCurrent(shell, if (args.len == 2) args[1] else null) orelse {
        if (args.len == 2) {
            try writeNoSuchJob(shell, "fg");
        } else {
            try writeNoCurrentJob(shell, "fg");
        }
        return .{ .status = 1 };
    };
    return foregroundJob(shell, job);
}

fn evalKillList(shell: anytype, operands: []const []const u8) !result.EvalResult {
    if (operands.len == 0) {
        for (trap_signal_names, 0..) |name, index| {
            if (index != 0) try shell.host.writeAll(.stdout, " ");
            try shell.host.writeAll(.stdout, name);
        }
        try shell.host.writeAll(.stdout, "\n");
        return .{};
    }
    if (operands.len != 1) return .{ .status = 2 };
    const raw_number = std.fmt.parseInt(u8, operands[0], 10) catch return .{ .status = 2 };
    const number = if (raw_number > 128) raw_number - 128 else raw_number;
    const name = signalNameFromNumber(number) orelse return .{ .status = 2 };
    try shell.host.writeAll(.stdout, name);
    try shell.host.writeAll(.stdout, "\n");
    return .{};
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

fn evalTimes(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len != 1) return .{ .status = 2 };
    shell.host.writeAll(.stdout, "0m0.000s 0m0.000s\n0m0.000s 0m0.000s\n") catch {
        try shell.host.writeAll(.stderr, "times: write failed\n");
        return .{ .status = 1 };
    };
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

fn evalLocal(shell: anytype, args: []const []const u8) !result.EvalResult {
    var status: result.ExitStatus = 0;
    for (args[1..]) |arg| {
        const equal_index = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (equal_index) |index| arg[0..index] else arg;
        if (!isAssignmentName(name)) {
            try shell.host.writeAll(
                .stderr,
                try std.fmt.allocPrint(shell.scratchAllocator(), "local: `{s}': not a valid identifier\n", .{arg}),
            );
            status = 1;
            continue;
        }
        const value = if (equal_index) |index| arg[index + 1 ..] else if (shell.state.getVariable(name)) |variable| variable.value else "";
        shell.state.putVariable(.{ .name = name, .value = value }) catch |err| switch (err) {
            error.ReadonlyVariable => {
                try shell.host.writeAll(
                    .stderr,
                    try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: readonly variable\n", .{name}),
                );
                status = 1;
            },
            else => return err,
        };
    }
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
    if (args.len == 1) return listSetVariables(shell);
    if (std.mem.eql(u8, args[1], "--")) {
        try shell.state.setPositionals(args[2..]);
        return .{};
    }
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            try shell.state.setPositionals(args[index + 1 ..]);
            return .{};
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) {
            try shell.state.setPositionals(args[index..]);
            return .{};
        }
        const enabled = arg[0] == '-';
        if (std.mem.eql(u8, arg[1..], "o")) {
            index += 1;
            if (index >= args.len) return listSetOptions(shell, enabled);
            if (!setNamedOption(shell, args[index], enabled)) return setUsageError(shell);
            continue;
        }
        for (arg[1..]) |option| switch (option) {
            'a' => shell.state.options.allexport = enabled,
            'C' => shell.state.options.noclobber = enabled,
            'e' => shell.state.options.errexit = enabled,
            'f' => shell.state.options.noglob = enabled,
            'm' => shell.state.options.monitor = enabled,
            'u' => shell.state.options.nounset = enabled,
            'x' => shell.state.options.xtrace = enabled,
            else => return setUsageError(shell),
        };
    }
    return .{};
}

fn listSetVariables(shell: anytype) !result.EvalResult {
    const allocator = shell.scratchAllocator();
    var variables: std.ArrayList(state_mod.Variable) = .empty;
    var iterator = shell.state.variables.iterator();
    while (iterator.next()) |entry| try variables.append(allocator, entry.value_ptr.*);

    std.mem.sort(state_mod.Variable, variables.items, {}, variableLessThan);
    for (variables.items) |variable| {
        try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
            allocator,
            "{s}={s}\n",
            .{ variable.name, variable.value },
        ));
    }
    return .{};
}

fn variableLessThan(_: void, lhs: state_mod.Variable, rhs: state_mod.Variable) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

const SetOption = enum {
    allexport,
    errexit,
    noclobber,
    noexec,
    noglob,
    notify,
    nounset,
    pipefail,
    xtrace,
};

const set_option_names = std.StaticStringMap(SetOption).initComptime(.{
    .{ "allexport", .allexport },
    .{ "errexit", .errexit },
    .{ "noclobber", .noclobber },
    .{ "noexec", .noexec },
    .{ "noglob", .noglob },
    .{ "notify", .notify },
    .{ "nounset", .nounset },
    .{ "pipefail", .pipefail },
    .{ "xtrace", .xtrace },
});

const set_option_order = [_]SetOption{
    .allexport,
    .errexit,
    .noclobber,
    .noexec,
    .noglob,
    .notify,
    .nounset,
    .pipefail,
    .xtrace,
};

fn setOptionName(option: SetOption) []const u8 {
    return switch (option) {
        .allexport => "allexport",
        .errexit => "errexit",
        .noclobber => "noclobber",
        .noexec => "noexec",
        .noglob => "noglob",
        .notify => "notify",
        .nounset => "nounset",
        .pipefail => "pipefail",
        .xtrace => "xtrace",
    };
}

fn setOptionEnabled(shell: anytype, option: SetOption) bool {
    return switch (option) {
        .allexport => shell.state.options.allexport,
        .errexit => shell.state.options.errexit,
        .noclobber => shell.state.options.noclobber,
        .noexec => shell.state.options.noexec,
        .noglob => shell.state.options.noglob,
        .notify => shell.state.options.notify,
        .nounset => shell.state.options.nounset,
        .pipefail => shell.state.options.pipefail,
        .xtrace => shell.state.options.xtrace,
    };
}

fn listSetOptions(shell: anytype, table: bool) !result.EvalResult {
    for (set_option_order) |option| {
        const name = setOptionName(option);
        const enabled = setOptionEnabled(shell, option);
        if (table) {
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "{s}\t{s}\n",
                .{ name, if (enabled) "on" else "off" },
            ));
        } else {
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "set {s}o {s}\n",
                .{ if (enabled) "-" else "+", name },
            ));
        }
    }
    return .{};
}

fn setNamedOption(shell: anytype, name: []const u8, enabled: bool) bool {
    const option = set_option_names.get(name) orelse return false;
    switch (option) {
        .allexport => shell.state.options.allexport = enabled,
        .errexit => shell.state.options.errexit = enabled,
        .noclobber => shell.state.options.noclobber = enabled,
        .noexec => shell.state.options.noexec = enabled,
        .noglob => shell.state.options.noglob = enabled,
        .notify => shell.state.options.notify = enabled,
        .nounset => shell.state.options.nounset = enabled,
        .pipefail => shell.state.options.pipefail = enabled,
        .xtrace => shell.state.options.xtrace = enabled,
    }
    return true;
}

fn setUsageError(shell: anytype) !result.EvalResult {
    try shell.host.writeAll(.stderr, "set: invalid option\n");
    return .{ .status = 2 };
}

fn evalUnset(shell: anytype, args: []const []const u8) !result.EvalResult {
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
            if (std.mem.indexOfScalar(u8, name, '/') == null) {
                shell.state.removeFunction(name);
                try shell.state.suppressFunctionAutoload(name);
            }
        } else if (shell.state.getVariable(name)) |variable| {
            if (variable.readonly) {
                try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: readonly variable\n", .{name}));
                status = 1;
            } else {
                shell.state.removeVariable(name);
            }
        } else if (shell.state.getVariableAttributes(name)) |attributes| {
            if (attributes.readonly) {
                try shell.host.writeAll(.stderr, try std.fmt.allocPrint(shell.scratchAllocator(), "{s}: readonly variable\n", .{name}));
                status = 1;
            } else {
                shell.state.removeVariableAttributes(name);
            }
        }
    }
    return .{ .status = status, .flow = if (status == 1) .{ .fatal = status } else .normal };
}

fn evalTrap(shell: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) {
        try listAllTraps(shell);
        return .{};
    }

    var index: usize = 1;
    if (std.mem.eql(u8, args[index], "--")) {
        index += 1;
        if (index >= args.len) return .{ .status = 2 };
    }
    if (std.mem.eql(u8, args[index], "-p")) {
        index += 1;
        if (index >= args.len) {
            try listAllTraps(shell);
            return .{};
        }
        var status: result.ExitStatus = 0;
        while (index < args.len) : (index += 1) {
            const signal = parseTrapSignal(args[index]) orelse {
                status = 1;
                continue;
            };
            try listTrap(shell, signal);
        }
        return .{ .status = status };
    }

    const reset = std.mem.eql(u8, args[index], "-");
    const action = args[index];
    index += 1;
    if (index >= args.len) return .{ .status = 2 };

    var status: result.ExitStatus = 0;
    while (index < args.len) : (index += 1) {
        const signal = parseTrapSignal(args[index]) orelse {
            status = 1;
            continue;
        };
        switch (signal) {
            .exit => if (reset) shell.state.clearExitTrap() else try shell.state.setExitTrap(action),
            .other => |name| if (reset) {
                shell.state.clearSignalTrap(name);
                if (signalNumber(name)) |number| shell.host.setSignalDefault(number) catch {};
            } else {
                try shell.state.setSignalTrap(name, action);
                if (signalNumber(name)) |number| {
                    if (action.len == 0) {
                        shell.host.setSignalIgnored(number) catch {};
                    } else {
                        shell.host.installSignalTrap(number) catch {};
                    }
                }
            },
        }
    }
    return .{ .status = status };
}

fn listAllTraps(shell: anytype) !void {
    try listTrap(shell, .exit);
    for (trap_signal_names) |signal| try listTrap(shell, .{ .other = signal });
}

fn listTrap(shell: anytype, signal: TrapSignal) !void {
    switch (signal) {
        .exit => if (shell.state.exit_trap_listing) |action| {
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "trap -- '{s}' EXIT\n",
                .{action},
            ));
        },
        .other => |name| if (shell.state.getSignalTrap(name)) |action| {
            try shell.host.writeAll(.stdout, try std.fmt.allocPrint(
                shell.scratchAllocator(),
                "trap -- '{s}' {s}\n",
                .{ action, name },
            ));
        },
    }
}

const TrapSignal = union(enum) { exit, other: []const u8 };

const KillSignal = struct {
    name: ?[]const u8,
    number: u8,
};

const trap_signal_names = [_][]const u8{
    "HUP",  "INT",  "QUIT", "ILL",  "TRAP",   "ABRT", "FPE",   "KILL", "BUS",  "SEGV",
    "PIPE", "ALRM", "TERM", "USR1", "USR2",   "CHLD", "CONT",  "STOP", "TSTP", "TTIN",
    "TTOU", "URG",  "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "POLL", "SYS",
};

fn parseTrapSignal(signal: []const u8) ?TrapSignal {
    if (std.mem.eql(u8, signal, "0") or std.ascii.eqlIgnoreCase(signal, "EXIT")) return .exit;
    if (signalName(signal)) |name| return .{ .other = name };
    const number = std.fmt.parseInt(u8, signal, 10) catch return null;
    return if (signalNameFromNumber(number)) |name| .{ .other = name } else null;
}

fn parseKillSignal(signal: []const u8) ?KillSignal {
    if (std.mem.eql(u8, signal, "0")) return .{ .name = null, .number = 0 };
    if (signalName(signal)) |name| return .{ .name = name, .number = signalNumber(name) orelse return null };
    const number = std.fmt.parseInt(u8, signal, 10) catch return null;
    if (number == 0) return .{ .name = null, .number = 0 };
    return .{ .name = signalNameFromNumber(number), .number = number };
}

fn signalName(signal: []const u8) ?[]const u8 {
    const name_without_prefix = if (signal.len >= 3 and std.ascii.eqlIgnoreCase(signal[0..3], "SIG"))
        signal[3..]
    else
        signal;
    for (trap_signal_names) |name| if (std.ascii.eqlIgnoreCase(name_without_prefix, name)) return name;
    return null;
}

pub fn signalNumber(signal: []const u8) ?u8 {
    inline for (trap_signal_names) |name| {
        if (std.mem.eql(u8, signal, name) and @hasField(std.c.SIG, name)) {
            return @intCast(@intFromEnum(@field(std.c.SIG, name)));
        }
    }
    return null;
}

fn signalNameFromNumber(number: u8) ?[]const u8 {
    for (trap_signal_names) |name| if (signalNumber(name) == number) return name;
    return null;
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
    try std.testing.expectEqual(@as(?Definition, null), lookup("abbr"));
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
    try std.testing.expectEqual(Id.kill, lookup("kill").?.id);
    try std.testing.expectEqual(Id.true_, lookup("true").?.id);
    try std.testing.expectEqual(Id.false_, lookup("false").?.id);
    try std.testing.expectEqual(Id.printf, lookup("printf").?.id);
    try std.testing.expectEqual(Id.pwd, lookup("pwd").?.id);
    try std.testing.expectEqual(Id.read, lookup("read").?.id);
    try std.testing.expectEqual(Id.readonly, lookup("readonly").?.id);
    try std.testing.expectEqual(Id.trap, lookup("trap").?.id);
    try std.testing.expectEqual(Id.type, lookup("type").?.id);
    try std.testing.expectEqual(Id.test_, lookup("test").?.id);
    try std.testing.expectEqual(Id.times, lookup("times").?.id);
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

        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
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

test "set -o notify toggles notify option" {
    const TestHost = struct {
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
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
    const set_definition = lookup("set").?;

    try std.testing.expect(!shell.state.options.notify);
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "-o", "notify" })).status,
    );
    try std.testing.expect(shell.state.options.notify);
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, set_definition, &.{ "set", "+o", "notify" })).status,
    );
    try std.testing.expect(!shell.state.options.notify);
}

test "jobs builtin filters jobs and prints pids" {
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

        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
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
    try shell.state.addBackgroundPid(111);
    try shell.state.addBackgroundJob(111, "sleep 1");
    try shell.state.addBackgroundPid(222);
    try shell.state.addBackgroundJob(222, "sleep 2");

    const jobs_definition = lookup("jobs").?;
    try std.testing.expectEqual(
        @as(result.ExitStatus, 0),
        (try eval(&shell, jobs_definition, &.{ "jobs", "-p", "%2" })).status,
    );
    try std.testing.expectEqualStrings("222\n", shell.host.stdout.items);

    shell.host.stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(result.ExitStatus, 1),
        (try eval(&shell, jobs_definition, &.{ "jobs", "%3" })).status,
    );
    try std.testing.expectEqualStrings("", shell.host.stdout.items);
    try std.testing.expectEqualStrings("jobs: no such job\n", shell.host.stderr.items);
}

test "exit builtin returns requested exit flow" {
    const TestHost = struct {
        pub fn writeAll(_: *@This(), _: host.Fd, _: []const u8) !void {}

        pub fn setFileCreationMask(_: *@This(), mask: u32) u32 {
            return mask;
        }

        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
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

        pub fn currentProcessId(_: *@This()) host.Pid {
            return 1;
        }

        pub fn sendSignal(_: *@This(), _: host.Pid, _: u8) !void {}

        pub fn setSignalDefault(_: *@This(), _: u8) !void {}

        pub fn setSignalIgnored(_: *@This(), _: u8) !void {}

        pub fn installSignalTrap(_: *@This(), _: u8) !void {}
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
