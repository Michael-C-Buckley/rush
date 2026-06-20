//! Generated differential shell integration harness.

const std = @import("std");

const Config = struct {
    rush_path: [:0]u8,
    shell: [:0]u8,
    shell_args: []const []const u8,
    cases: usize = 100,
    seed: u64 = 1,
    case_filter: ?usize = null,
    keep_temp: bool = false,
    strict_stderr: bool = false,
    features: FeatureSet = .default,
    print_cases: bool = false,
    timeout_ms: i64 = 5000,

    fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.rush_path);
        allocator.free(self.shell);
        allocator.free(self.shell_args);
    }

    fn timeout(self: Config) std.Io.Timeout {
        if (self.timeout_ms == 0) return .none;
        return .{ .duration = .{ .raw = .fromMilliseconds(self.timeout_ms), .clock = .awake } };
    }

    fn caseLimit(self: Config) usize {
        if (self.case_filter) |selected| return @max(self.cases, selected + 1);
        return self.cases;
    }
};

const FeatureSet = packed struct {
    fd: bool = true,
    params: bool = true,
    lists: bool = true,

    const default: FeatureSet = .{ .fd = true, .params = true, .lists = true };

    fn parse(text: []const u8) ?FeatureSet {
        var features: FeatureSet = .{ .fd = false, .params = false, .lists = false };
        var saw_feature = false;
        var iterator = std.mem.splitScalar(u8, text, ',');
        while (iterator.next()) |feature| {
            if (feature.len == 0) return null;
            if (std.mem.eql(u8, feature, "base")) {
                saw_feature = true;
            } else if (std.mem.eql(u8, feature, "fd")) {
                features.fd = true;
                saw_feature = true;
            } else if (std.mem.eql(u8, feature, "params")) {
                features.params = true;
                saw_feature = true;
            } else if (std.mem.eql(u8, feature, "lists")) {
                features.lists = true;
                saw_feature = true;
            } else {
                return null;
            }
        }
        return if (saw_feature) features else null;
    }

    fn format(self: FeatureSet, writer: *std.Io.Writer) !void {
        try writer.writeAll("base");
        if (self.fd) try writer.writeAll(",fd");
        if (self.params) try writer.writeAll(",params");
        if (self.lists) try writer.writeAll(",lists");
    }
};

const TempRoot = struct {
    path: []const u8,
    dir: std.Io.Dir,

    fn deinit(self: *TempRoot, allocator: std.mem.Allocator, io: std.Io, keep: bool) void {
        self.dir.close(io);
        if (!keep) {
            std.Io.Dir.cwd().deleteTree(io, self.path) catch |err| {
                std.debug.print("differential: failed to remove temporary directory {s}: {s}\n", .{
                    self.path,
                    @errorName(err),
                });
            };
        } else {
            std.debug.print("differential: kept temporary directory {s}\n", .{self.path});
        }
        allocator.free(self.path);
        self.* = undefined;
    }
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    status: u8,
    files: []FileSnapshot,
    timed_out: bool = false,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        for (self.files) |file| file.deinit(allocator);
        allocator.free(self.files);
    }
};

const FileSnapshot = struct {
    path: []u8,
    kind: Kind,
    contents: ?[]u8 = null,

    const Kind = enum { file, directory };

    fn deinit(self: FileSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.contents) |contents| allocator.free(contents);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = (try parseArgs(allocator, init.io, args)) orelse {
        try writeUsage(init.io);
        return 2;
    };
    defer config.deinit(allocator);

    var temp_root = try createTempRoot(allocator, init.io);
    var keep_temp = config.keep_temp;
    defer temp_root.deinit(allocator, init.io, keep_temp);

    const case_limit = config.caseLimit();
    const run_count = if (config.case_filter == null) config.cases else 1;
    var progress = Progress.init(init.io, run_count, config.print_cases);
    defer progress.deinit();

    var failures: usize = 0;
    var completed: usize = 0;
    var case_index: usize = 0;
    while (case_index < case_limit) : (case_index += 1) {
        if (config.case_filter) |selected| if (selected != case_index) continue;
        progress.startCase(case_index);

        const script = try generateScript(allocator, config.seed, case_index, config.features);
        defer allocator.free(script);
        if (config.print_cases) printGeneratedCase(case_index, script);

        const rush = try runOne(
            allocator,
            init.io,
            &temp_root,
            "rush",
            case_index,
            config.rush_path,
            &.{"--posix"},
            script,
            config.timeout(),
        );
        defer rush.deinit(allocator);
        const reference = try runOne(
            allocator,
            init.io,
            &temp_root,
            "ref",
            case_index,
            config.shell,
            config.shell_args,
            script,
            config.timeout(),
        );
        defer reference.deinit(allocator);

        const mismatch = !resultsMatch(config, rush, reference);
        if (mismatch) {
            failures += 1;
            keep_temp = true;
            const shrunk = try shrinkScriptAlloc(allocator, init.io, &temp_root, config, case_index, script);
            defer shrunk.deinit(allocator);
            _ = try reportMismatch(allocator, config, case_index, shrunk.script, shrunk.rush, shrunk.reference);
            break;
        }

        completed += 1;
        progress.completeCase(completed);
    }

    if (failures != 0) return 1;
    std.debug.print("differential: passed {d} generated case(s) against {s}\n", .{ completed, config.shell });
    return 0;
}

const Progress = struct {
    root_node: std.Progress.Node,
    case_node: ?std.Progress.Node = null,

    fn init(io: std.Io, case_count: usize, disable_printing: bool) Progress {
        return .{ .root_node = std.Progress.start(io, .{
            .root_name = "Differential",
            .disable_printing = disable_printing,
            .initial_delay_ns = .fromMilliseconds(0),
            .estimated_total_items = case_count,
        }) };
    }

    fn deinit(self: *Progress) void {
        if (self.case_node) |case_node| case_node.end();
        self.root_node.end();
        self.* = undefined;
    }

    fn startCase(self: *Progress, case_index: usize) void {
        if (self.case_node) |case_node| case_node.end();
        self.case_node = self.root_node.startFmt(0, "case {d}", .{case_index});
    }

    fn completeCase(self: *Progress, completed: usize) void {
        if (self.case_node) |case_node| case_node.end();
        self.case_node = null;
        self.root_node.setCompletedItems(completed);
    }
};

fn printGeneratedCase(case_index: usize, script: []const u8) void {
    std.debug.print(
        \\differential: generated case {d}
        \\---
        \\{s}---
        \\
    , .{ case_index, script });
}

fn parseArgs(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !?Config {
    if (args.len < 2) return null;
    var rush_path: ?[]const u8 = null;
    var shell: []const u8 = "dash";
    var shell_args: std.ArrayList([]const u8) = .empty;
    defer shell_args.deinit(allocator);
    var cases: usize = 100;
    var seed: u64 = 1;
    var case_filter: ?usize = null;
    var keep_temp = false;
    var strict_stderr = false;
    var features: FeatureSet = .default;
    var print_cases = false;
    var timeout_ms: i64 = 5000;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--rush")) {
            index += 1;
            if (index >= args.len) return null;
            rush_path = args[index];
        } else if (std.mem.eql(u8, arg, "--shell")) {
            index += 1;
            if (index >= args.len) return null;
            shell = args[index];
        } else if (std.mem.eql(u8, arg, "--shell-arg")) {
            index += 1;
            if (index >= args.len) return null;
            try shell_args.append(allocator, args[index]);
        } else if (std.mem.eql(u8, arg, "--cases")) {
            index += 1;
            if (index >= args.len) return null;
            cases = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            index += 1;
            if (index >= args.len) return null;
            seed = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--case")) {
            index += 1;
            if (index >= args.len) return null;
            case_filter = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--keep-temp")) {
            keep_temp = true;
        } else if (std.mem.eql(u8, arg, "--strict-stderr")) {
            strict_stderr = true;
        } else if (std.mem.eql(u8, arg, "--print-cases")) {
            print_cases = true;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            index += 1;
            if (index >= args.len) return null;
            timeout_ms = try std.fmt.parseInt(i64, args[index], 10);
            if (timeout_ms < 0) return null;
        } else if (std.mem.eql(u8, arg, "--features")) {
            index += 1;
            if (index >= args.len) return null;
            features = FeatureSet.parse(args[index]) orelse return null;
        } else {
            return null;
        }
    }

    const resolved_rush = try resolvePath(allocator, io, rush_path orelse return null);
    errdefer allocator.free(resolved_rush);
    const resolved_shell = try resolveCommandPath(allocator, io, shell);
    errdefer allocator.free(resolved_shell);
    const owned_shell_args = try shell_args.toOwnedSlice(allocator);

    return .{
        .rush_path = resolved_rush,
        .shell = resolved_shell,
        .shell_args = owned_shell_args,
        .cases = cases,
        .seed = seed,
        .case_filter = case_filter,
        .keep_temp = keep_temp,
        .strict_stderr = strict_stderr,
        .features = features,
        .print_cases = print_cases,
        .timeout_ms = timeout_ms,
    };
}

fn resolvePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    if (std.Io.Dir.path.isAbsolute(path)) return allocator.dupeZ(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn resolveCommandPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, path, '/') == null) return allocator.dupeZ(u8, path);
    return resolvePath(allocator, io, path);
}

fn writeUsage(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.writeAll(
        \\usage: differential --rush PATH [--shell SHELL] [options]
        \\
        \\options:
        \\  --shell SHELL       reference shell (default: dash)
        \\  --shell-arg ARG     pass ARG to the reference shell
        \\  --cases N           number of generated cases (default: 100)
        \\  --seed N            deterministic seed (default: 1)
        \\  --case N            run only one generated case index
        \\  --features LIST     comma-separated features: base,fd,params,lists (default: all)
        \\  --print-cases       print each generated shell script before running it
        \\  --timeout-ms N      per-command timeout in milliseconds, or 0 to disable (default: 5000)
        \\  --keep-temp         keep the temporary sandbox
        \\  --strict-stderr     compare stderr exactly
        \\
    );
}

fn createTempRoot(allocator: std.mem.Allocator, io: std.Io) !TempRoot {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache");

    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const random = std.mem.readInt(u64, &random_bytes, .little);
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/rush-differential-{x}", .{random});
        errdefer allocator.free(path);
        cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return .{ .path = path, .dir = try cwd.openDir(io, path, .{}) };
    }
    return error.TemporaryNameCollision;
}

fn generateScript(allocator: std.mem.Allocator, seed: u64, case_index: usize, features: FeatureSet) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed ^ (@as(u64, @intCast(case_index)) *% 0x9e3779b97f4a7c15));
    const random = prng.random();
    var script_ast = try Script.generate(allocator, random, features);
    defer script_ast.deinit(allocator);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try script_ast.render(&writer.writer);
    try renderProbe(&writer.writer, features);
    return writer.toOwnedSlice();
}

const Script = struct {
    commands: []Command,

    fn generate(allocator: std.mem.Allocator, random: std.Random, features: FeatureSet) !Script {
        const command_count = 1 + random.uintLessThan(usize, 8);
        const commands = try allocator.alloc(Command, command_count);
        errdefer allocator.free(commands);
        var initialized: usize = 0;
        errdefer for (commands[0..initialized]) |*command| command.deinit(allocator);

        for (commands) |*command| {
            command.* = try Command.generate(allocator, random, .top_level, 0, features);
            initialized += 1;
        }

        return .{ .commands = commands };
    }

    fn deinit(self: *Script, allocator: std.mem.Allocator) void {
        for (self.commands) |*command| command.deinit(allocator);
        allocator.free(self.commands);
        self.* = undefined;
    }

    fn render(self: Script, writer: *std.Io.Writer) !void {
        for (self.commands) |command| try command.render(writer, .top_level);
    }
};

const RenderMode = enum { top_level, inline_compound };

const Value = enum {
    empty,
    one,
    two,
    three,

    fn random(random_source: std.Random) Value {
        return @enumFromInt(random_source.uintLessThan(u3, 4));
    }

    fn shell(self: Value) []const u8 {
        return switch (self) {
            .empty => "''",
            .one => "one",
            .two => "two",
            .three => "three",
        };
    }
};

const Variable = enum {
    A,
    B,

    fn random(random_source: std.Random) Variable {
        return @enumFromInt(random_source.uintLessThan(u2, 2));
    }

    fn shell(self: Variable) []const u8 {
        return @tagName(self);
    }
};

const PositionalParameter = enum {
    one,
    two,

    fn random(random_source: std.Random) PositionalParameter {
        return @enumFromInt(random_source.uintLessThan(u2, 2));
    }

    fn number(self: PositionalParameter) u8 {
        return switch (self) {
            .one => 1,
            .two => 2,
        };
    }
};

const Assignment = struct {
    variable: Variable,
    value: Value,

    fn random(random_source: std.Random) Assignment {
        return .{ .variable = Variable.random(random_source), .value = Value.random(random_source) };
    }

    fn render(self: Assignment, writer: *std.Io.Writer) !void {
        try writer.print("{s}={s}", .{ self.variable.shell(), self.value.shell() });
    }
};

const Expansion = union(enum) {
    quoted: Variable,
    default_unset: Variable,
    default_null: Variable,
    positional_quoted: PositionalParameter,
    positional_default_unset: PositionalParameter,

    fn random(random_source: std.Random) Expansion {
        return switch (random_source.uintLessThan(u3, 5)) {
            0 => .{ .quoted = Variable.random(random_source) },
            1 => .{ .default_unset = Variable.random(random_source) },
            2 => .{ .default_null = Variable.random(random_source) },
            3 => .{ .positional_quoted = PositionalParameter.random(random_source) },
            4 => .{ .positional_default_unset = PositionalParameter.random(random_source) },
            else => unreachable,
        };
    }

    fn render(self: Expansion, writer: *std.Io.Writer) !void {
        switch (self) {
            .quoted => |variable| try writer.print("\"${s}\"", .{variable.shell()}),
            .default_unset => |variable| try writer.print("\"${{{s}-default}}\"", .{variable.shell()}),
            .default_null => |variable| try writer.print("\"${{{s}:-default}}\"", .{variable.shell()}),
            .positional_quoted => |parameter| try writer.print("\"${d}\"", .{parameter.number()}),
            .positional_default_unset => |parameter| try writer.print(
                "\"${{{d}-default}}\"",
                .{parameter.number()},
            ),
        }
    }
};

const PositionalSet = struct {
    values: [3]Value,
    count: usize,

    fn random(random_source: std.Random) PositionalSet {
        var values: [3]Value = undefined;
        for (&values) |*value| value.* = Value.random(random_source);
        return .{ .values = values, .count = random_source.uintLessThan(usize, values.len + 1) };
    }

    fn render(self: PositionalSet, writer: *std.Io.Writer) !void {
        try writer.writeAll("set --");
        for (self.values[0..self.count]) |value| try writer.print(" {s}", .{value.shell()});
    }
};

const FileName = enum {
    a,
    b,
    c,
    out,

    fn random(random_source: std.Random) FileName {
        return @enumFromInt(random_source.uintLessThan(u3, 4));
    }

    fn shell(self: FileName) []const u8 {
        return @tagName(self);
    }
};

const OutputRedirection = struct {
    file: FileName,
    append: bool,

    fn random(random_source: std.Random) OutputRedirection {
        return .{ .file = FileName.random(random_source), .append = random_source.boolean() };
    }

    fn render(self: OutputRedirection, writer: *std.Io.Writer) !void {
        try writer.print(" {s} {s}", .{ if (self.append) ">>" else ">", self.file.shell() });
    }
};

const RedirectedCompound = struct {
    body: []Command,
    redirection: OutputRedirection,
};

const DirName = enum {
    d,
    e,

    fn random(random_source: std.Random) DirName {
        return @enumFromInt(random_source.uintLessThan(u2, 2));
    }

    fn shell(self: DirName) []const u8 {
        return @tagName(self);
    }
};

const Fd = enum {
    fd3,
    fd4,

    fn random(random_source: std.Random) Fd {
        return @enumFromInt(random_source.uintLessThan(u2, 2));
    }

    fn number(self: Fd) u8 {
        return switch (self) {
            .fd3 => 3,
            .fd4 => 4,
        };
    }
};

const FdSource = enum {
    stdout,
    stderr,

    fn random(random_source: std.Random) FdSource {
        return @enumFromInt(random_source.uintLessThan(u2, 2));
    }

    fn number(self: FdSource) u8 {
        return switch (self) {
            .stdout => 1,
            .stderr => 2,
        };
    }
};

const ListOperator = enum {
    and_if,
    or_if,

    fn random(random_source: std.Random) ListOperator {
        return @enumFromInt(random_source.uintLessThan(u2, 2));
    }

    fn shell(self: ListOperator) []const u8 {
        return switch (self) {
            .and_if => "&&",
            .or_if => "||",
        };
    }
};

const ListOperand = union(enum) {
    noop,
    true_cmd,
    false_cmd,
    print_stdout: Value,
    print_expansion: Expansion,

    fn random(random_source: std.Random, features: FeatureSet) ListOperand {
        const count: u8 = if (features.params) 5 else 4;
        return switch (random_source.uintLessThan(u8, count)) {
            0 => .noop,
            1 => .true_cmd,
            2 => .false_cmd,
            3 => .{ .print_stdout = Value.random(random_source) },
            4 => .{ .print_expansion = Expansion.random(random_source) },
            else => unreachable,
        };
    }

    fn render(self: ListOperand, writer: *std.Io.Writer) !void {
        switch (self) {
            .noop => try writer.writeAll(":"),
            .true_cmd => try writer.writeAll("true"),
            .false_cmd => try writer.writeAll("false"),
            .print_stdout => |value| try writer.print("printf '%s\\n' {s}", .{value.shell()}),
            .print_expansion => |expansion| {
                try writer.writeAll("printf '%s\\n' ");
                try expansion.render(writer);
            },
        }
    }
};

const Command = union(enum) {
    noop,
    true_cmd,
    false_cmd,
    assign: Assignment,
    export_assign: Assignment,
    unset: Variable,
    set_positionals: PositionalSet,
    shift_guarded,
    print_stdout: Value,
    print_expansion: Expansion,
    print_to_file: struct { value: Value, file: FileName },
    cat_file: FileName,
    subshell: []Command,
    group: []Command,
    redirected_subshell: RedirectedCompound,
    redirected_group: RedirectedCompound,
    mkdir_cd: DirName,
    exec_open_fd: struct { fd: Fd, file: FileName, append: bool },
    exec_close_fd: Fd,
    exec_dup_fd: struct { target: Fd, source: FdSource },
    print_to_fd: struct { fd: Fd, value: Value },
    list: struct { left: ListOperand, operator: ListOperator, right: ListOperand },

    fn generate(
        allocator: std.mem.Allocator,
        random: std.Random,
        mode: RenderMode,
        depth: usize,
        features: FeatureSet,
    ) anyerror!Command {
        const base_count: u8 = switch (mode) {
            .top_level => if (depth < 2) 15 else 10,
            .inline_compound => if (depth < 2) 8 else 7,
        };
        const fd_count: u8 = if (features.fd) switch (mode) {
            .top_level => 4,
            .inline_compound => if (depth < 2) 4 else 0,
        } else 0;
        const params_count: u8 = if (features.params) 1 else 0;
        const positional_count: u8 = if (features.params) switch (mode) {
            .top_level => 2,
            .inline_compound => 1,
        } else 0;
        const lists_count: u8 = if (features.lists and mode == .top_level) 1 else 0;
        const choice = random.uintLessThan(u8, base_count + fd_count + params_count + positional_count + lists_count);
        if (choice < base_count) return switch (choice) {
            0 => .noop,
            1 => .true_cmd,
            2 => .false_cmd,
            3 => .{ .assign = Assignment.random(random) },
            4 => .{ .print_stdout = Value.random(random) },
            5 => .{ .print_to_file = .{ .value = Value.random(random), .file = FileName.random(random) } },
            6 => .{ .cat_file = FileName.random(random) },
            7 => .{ .subshell = try generateCompoundCommands(allocator, random, depth + 1, features) },
            8 => .{ .group = try generateCompoundCommands(allocator, random, depth + 1, features) },
            9 => .{ .mkdir_cd = DirName.random(random) },
            10 => .{ .export_assign = Assignment.random(random) },
            11 => .{ .unset = Variable.random(random) },
            12 => .{ .redirected_subshell = .{
                .body = try generateCompoundCommands(allocator, random, depth + 1, features),
                .redirection = OutputRedirection.random(random),
            } },
            13 => .{ .redirected_group = .{
                .body = try generateCompoundCommands(allocator, random, depth + 1, features),
                .redirection = OutputRedirection.random(random),
            } },
            14 => .{ .print_expansion = Expansion.random(random) },
            else => unreachable,
        };

        const fd_choice = choice - base_count;
        if (fd_choice < fd_count) return switch (fd_choice) {
            0 => .{ .exec_open_fd = .{
                .fd = Fd.random(random),
                .file = FileName.random(random),
                .append = random.boolean(),
            } },
            1 => .{ .exec_close_fd = Fd.random(random) },
            2 => target: {
                const target = Fd.random(random);
                break :target .{ .exec_dup_fd = .{ .target = target, .source = FdSource.random(random) } };
            },
            3 => .{ .print_to_fd = .{ .fd = Fd.random(random), .value = Value.random(random) } },
            else => unreachable,
        };

        var feature_choice = choice - base_count - fd_count;
        if (feature_choice < params_count) return .{ .print_expansion = Expansion.random(random) };
        feature_choice -= params_count;
        if (feature_choice < positional_count) return switch (feature_choice) {
            0 => .{ .set_positionals = PositionalSet.random(random) },
            1 => .shift_guarded,
            else => unreachable,
        };
        return .{ .list = .{
            .left = ListOperand.random(random, features),
            .operator = ListOperator.random(random),
            .right = ListOperand.random(random, features),
        } };
    }

    fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .subshell, .group => |commands| {
                for (commands) |*command| command.deinit(allocator);
                allocator.free(commands);
            },
            .redirected_subshell, .redirected_group => |redirected| {
                for (redirected.body) |*command| command.deinit(allocator);
                allocator.free(redirected.body);
            },
            else => {},
        }
        self.* = undefined;
    }

    fn render(self: Command, writer: *std.Io.Writer, mode: RenderMode) anyerror!void {
        switch (self) {
            .noop => try writer.writeAll(":"),
            .true_cmd => try writer.writeAll("true"),
            .false_cmd => try writer.writeAll("false"),
            .assign => |assignment| try assignment.render(writer),
            .export_assign => |assignment| {
                try writer.writeAll("export ");
                try assignment.render(writer);
            },
            .unset => |variable| try writer.print("unset {s}", .{variable.shell()}),
            .set_positionals => |positionals| try positionals.render(writer),
            .shift_guarded => try writer.writeAll("if [ \"$#\" -gt 0 ]; then shift; fi"),
            .print_stdout => |value| try writer.print("printf '%s\\n' {s}", .{value.shell()}),
            .print_expansion => |expansion| {
                try writer.writeAll("printf '%s\\n' ");
                try expansion.render(writer);
            },
            .print_to_file => |print| try writer.print(
                "printf '%s\\n' {s} > {s}",
                .{ print.value.shell(), print.file.shell() },
            ),
            .cat_file => |file| try writer.print("cat < {s}", .{file.shell()}),
            .subshell => |commands| try renderCompound(writer, commands, "( ", ")"),
            .group => |commands| try renderCompound(writer, commands, "{ ", "}"),
            .redirected_subshell => |redirected| {
                try renderCompound(writer, redirected.body, "( ", ")");
                try redirected.redirection.render(writer);
            },
            .redirected_group => |redirected| {
                try renderCompound(writer, redirected.body, "{ ", "}");
                try redirected.redirection.render(writer);
            },
            .mkdir_cd => |dir| try writer.print("mkdir -p {s}; cd {s}", .{ dir.shell(), dir.shell() }),
            .exec_open_fd => |open| try writer.print(
                "exec {d}{s}{s}",
                .{ open.fd.number(), if (open.append) ">>" else ">", open.file.shell() },
            ),
            .exec_close_fd => |fd| try writer.print("exec {d}>&-", .{fd.number()}),
            .exec_dup_fd => |dup| try writer.print("exec {d}>&{d}", .{ dup.target.number(), dup.source.number() }),
            .print_to_fd => |print| try writer.print(
                "printf '%s\\n' {s} >&{d}",
                .{ print.value.shell(), print.fd.number() },
            ),
            .list => |list| {
                try list.left.render(writer);
                try writer.print(" {s} ", .{list.operator.shell()});
                try list.right.render(writer);
            },
        }
        if (mode == .top_level) try writer.writeByte('\n');
    }
};

fn generateCompoundCommands(
    allocator: std.mem.Allocator,
    random: std.Random,
    depth: usize,
    features: FeatureSet,
) anyerror![]Command {
    const command_count = 1 + random.uintLessThan(usize, 3);
    const commands = try allocator.alloc(Command, command_count);
    errdefer allocator.free(commands);
    var initialized: usize = 0;
    errdefer for (commands[0..initialized]) |*command| command.deinit(allocator);

    for (commands) |*command| {
        command.* = try Command.generate(allocator, random, .inline_compound, depth, features);
        initialized += 1;
    }

    return commands;
}

fn renderCompound(
    writer: *std.Io.Writer,
    commands: []const Command,
    open: []const u8,
    close: []const u8,
) anyerror!void {
    try writer.writeAll(open);
    for (commands) |command| {
        try command.render(writer, .inline_compound);
        try writer.writeAll("; ");
    }
    try writer.writeAll(close);
}

fn renderProbe(writer: *std.Io.Writer, features: FeatureSet) !void {
    try writer.writeAll("printf '__RUSH_PROBE_PWD=%s\\n' \"$PWD\"\n");
    try writer.writeAll("printf '__RUSH_PROBE_A=%s\\n' \"${A-unset}\"\n");
    if (features.fd) {
        try renderFdProbe(writer, .fd3);
        try renderFdProbe(writer, .fd4);
    }
}

fn renderFdProbe(writer: *std.Io.Writer, fd: Fd) !void {
    try writer.print(
        \\if (: >&{d}) 2>/dev/null; then
        \\printf '__RUSH_PROBE_FD{d}_WRITABLE=yes\n'
        \\else
        \\printf '__RUSH_PROBE_FD{d}_WRITABLE=no\n'
        \\fi
        \\
    , .{ fd.number(), fd.number(), fd.number() });
}

fn runOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    prefix: []const u8,
    case_index: usize,
    shell: []const u8,
    shell_args: []const []const u8,
    script: []const u8,
    timeout_value: std.Io.Timeout,
) !RunResult {
    const sub_path = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ prefix, case_index });
    defer allocator.free(sub_path);
    var cwd = try temp_root.dir.createDirPathOpen(io, sub_path, .{ .open_options = .{ .iterate = true } });
    defer cwd.close(io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, shell);
    try argv.appendSlice(allocator, shell_args);
    try argv.append(allocator, "-c");
    try argv.append(allocator, script);

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .timeout = timeout_value,
    }) catch |err| switch (err) {
        error.Timeout => return timeoutRunResult(allocator, io, cwd),
        else => |run_err| return run_err,
    };
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);
    var cwd_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path = cwd_path_buffer[0..try cwd.realPath(io, &cwd_path_buffer)];
    const stdout = try normalizeBytes(allocator, result.stdout, cwd_path);
    errdefer allocator.free(stdout);
    const stderr = try normalizeBytes(allocator, result.stderr, cwd_path);
    errdefer allocator.free(stderr);
    const files = try snapshotFiles(allocator, io, cwd);
    errdefer {
        for (files) |file| file.deinit(allocator);
        allocator.free(files);
    }
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .status = statusFromTerm(result.term),
        .files = files,
    };
}

fn timeoutRunResult(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !RunResult {
    const stdout = try allocator.dupe(u8, "");
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, "");
    errdefer allocator.free(stderr);
    const files = try snapshotFiles(allocator, io, cwd);
    errdefer {
        for (files) |file| file.deinit(allocator);
        allocator.free(files);
    }
    return .{ .stdout = stdout, .stderr = stderr, .status = 124, .files = files, .timed_out = true };
}

fn normalizeBytes(allocator: std.mem.Allocator, bytes: []const u8, cwd_path: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    var start: usize = 0;
    while (std.mem.findPos(u8, bytes, start, cwd_path)) |index| {
        try writer.writer.writeAll(bytes[start..index]);
        try writer.writer.writeAll("$SANDBOX");
        start = index + cwd_path.len;
    }
    try writer.writer.writeAll(bytes[start..]);
    return writer.toOwnedSlice();
}

fn snapshotFiles(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]FileSnapshot {
    var files: std.ArrayList(FileSnapshot) = .empty;
    errdefer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (std.mem.eql(u8, entry.path, ".")) continue;
        const path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(path);
        const kind: FileSnapshot.Kind = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            else => continue,
        };
        const contents = if (kind == .file)
            entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(4096)) catch |err| switch (err) {
                error.StreamTooLong => null,
                else => |read_err| return read_err,
            }
        else
            null;
        try files.append(allocator, .{ .path = path, .kind = kind, .contents = contents });
    }
    std.mem.sort(FileSnapshot, files.items, {}, lessFileSnapshot);
    return files.toOwnedSlice(allocator);
}

fn lessFileSnapshot(_: void, lhs: FileSnapshot, rhs: FileSnapshot) bool {
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

fn statusFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |status| status,
        .signal => |signal| signalStatus(@intFromEnum(signal)),
        .stopped => |signal| signalStatus(@intFromEnum(signal)),
        .unknown => 255,
    };
}

fn signalStatus(signal: u32) u8 {
    const value: u32 = 128 + signal;
    return if (value <= std.math.maxInt(u8)) @intCast(value) else std.math.maxInt(u8);
}

const ShrinkResult = struct {
    script: []u8,
    rush: RunResult,
    reference: RunResult,

    fn deinit(self: ShrinkResult, allocator: std.mem.Allocator) void {
        allocator.free(self.script);
        self.rush.deinit(allocator);
        self.reference.deinit(allocator);
    }
};

fn shrinkScriptAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    config: Config,
    case_index: usize,
    script: []const u8,
) !ShrinkResult {
    var current = try allocator.dupe(u8, script);
    errdefer allocator.free(current);
    var attempt: usize = 0;
    var changed = true;
    while (changed) {
        changed = false;
        const probe_start = probeStart(current);
        var line_start: usize = 0;
        while (line_start < probe_start) {
            const line_end = lineEnd(current, line_start);
            const candidate = try removeRangeAlloc(allocator, current, line_start, line_end);
            const candidate_attempt = attempt;
            attempt += 1;
            if (try scriptStillMismatches(allocator, io, temp_root, config, case_index, candidate_attempt, candidate)) {
                allocator.free(current);
                current = candidate;
                changed = true;
                break;
            }
            allocator.free(candidate);
            line_start = line_end;
        }
    }

    const rush_prefix = try std.fmt.allocPrint(allocator, "shrunk-rush-{d}", .{attempt});
    defer allocator.free(rush_prefix);
    const ref_prefix = try std.fmt.allocPrint(allocator, "shrunk-ref-{d}", .{attempt});
    defer allocator.free(ref_prefix);
    const rush = try runOne(
        allocator,
        io,
        temp_root,
        rush_prefix,
        case_index,
        config.rush_path,
        &.{"--posix"},
        current,
        config.timeout(),
    );
    errdefer rush.deinit(allocator);
    const reference = try runOne(
        allocator,
        io,
        temp_root,
        ref_prefix,
        case_index,
        config.shell,
        config.shell_args,
        current,
        config.timeout(),
    );
    errdefer reference.deinit(allocator);
    return .{ .script = current, .rush = rush, .reference = reference };
}

fn scriptStillMismatches(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: *TempRoot,
    config: Config,
    case_index: usize,
    attempt: usize,
    script: []const u8,
) !bool {
    const rush_prefix = try std.fmt.allocPrint(allocator, "shrink-rush-{d}", .{attempt});
    defer allocator.free(rush_prefix);
    const ref_prefix = try std.fmt.allocPrint(allocator, "shrink-ref-{d}", .{attempt});
    defer allocator.free(ref_prefix);
    const rush = try runOne(
        allocator,
        io,
        temp_root,
        rush_prefix,
        case_index,
        config.rush_path,
        &.{"--posix"},
        script,
        config.timeout(),
    );
    defer rush.deinit(allocator);
    const reference = try runOne(
        allocator,
        io,
        temp_root,
        ref_prefix,
        case_index,
        config.shell,
        config.shell_args,
        script,
        config.timeout(),
    );
    defer reference.deinit(allocator);
    return !resultsMatch(config, rush, reference);
}

fn probeStart(script: []const u8) usize {
    if (std.mem.find(u8, script, "printf '__RUSH_PROBE_PWD=")) |index| return index;
    return script.len;
}

fn lineEnd(script: []const u8, start: usize) usize {
    if (std.mem.findScalarPos(u8, script, start, '\n')) |newline| return newline + 1;
    return script.len;
}

fn removeRangeAlloc(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(source[0..start]);
    try writer.writer.writeAll(source[end..]);
    return writer.toOwnedSlice();
}

fn resultsMatch(config: Config, rush: RunResult, reference: RunResult) bool {
    if (rush.timed_out or reference.timed_out) return rush.timed_out == reference.timed_out;
    const stderr_matches = !config.strict_stderr or std.mem.eql(u8, rush.stderr, reference.stderr);
    return rush.status == reference.status and
        std.mem.eql(u8, rush.stdout, reference.stdout) and
        stderr_matches and
        filesEqual(rush.files, reference.files);
}

fn reportMismatch(
    allocator: std.mem.Allocator,
    config: Config,
    case_index: usize,
    script: []const u8,
    rush: RunResult,
    reference: RunResult,
) !bool {
    if (resultsMatch(config, rush, reference)) return false;
    const stderr_matches = !config.strict_stderr or std.mem.eql(u8, rush.stderr, reference.stderr);

    const replay_command = try replayCommandAlloc(allocator, config, case_index);
    defer allocator.free(replay_command);

    std.debug.print(
        \\differential: mismatch against {s}
        \\seed: {d}
        \\case: {d}
        \\
        \\replay:
        \\  {s}
        \\
        \\script:
        \\---
        \\{s}---
        \\
    , .{ config.shell, config.seed, case_index, replay_command, script });

    if (rush.status != reference.status) {
        std.debug.print("status: rush={d} reference={d}\n", .{ rush.status, reference.status });
    }
    if (rush.timed_out or reference.timed_out) {
        std.debug.print("timeout: rush={} reference={} timeout_ms={d}\n", .{
            rush.timed_out,
            reference.timed_out,
            config.timeout_ms,
        });
    }
    if (!std.mem.eql(u8, rush.stdout, reference.stdout)) {
        try printBytesMismatch(allocator, "stdout", rush.stdout, reference.stdout);
    }
    if (!stderr_matches) {
        try printBytesMismatch(allocator, "stderr", rush.stderr, reference.stderr);
    }
    if (!filesEqual(rush.files, reference.files)) {
        printFileMismatch(rush.files, reference.files);
    }
    return true;
}

fn replayCommandAlloc(allocator: std.mem.Allocator, config: Config, case_index: usize) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeAll("zig build differential -- --shell ");
    try writeShellArg(&writer.writer, config.shell);
    for (config.shell_args) |arg| {
        try writer.writer.writeAll(" --shell-arg ");
        try writeShellArg(&writer.writer, arg);
    }
    try writer.writer.writeAll(" --features ");
    try config.features.format(&writer.writer);
    if (config.strict_stderr) try writer.writer.writeAll(" --strict-stderr");
    try writer.writer.print(" --timeout-ms {d}", .{config.timeout_ms});
    try writer.writer.print(" --seed {d} --case {d}", .{ config.seed, case_index });
    return writer.toOwnedSlice();
}

fn writeShellArg(writer: *std.Io.Writer, arg: []const u8) !void {
    try writer.writeByte(0x27);
    for (arg) |byte| {
        if (byte == 0x27) {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte(0x27);
}

fn filesEqual(lhs: []const FileSnapshot, rhs: []const FileSnapshot) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path)) return false;
        if (left.kind != right.kind) return false;
        if ((left.contents == null) != (right.contents == null)) return false;
        if (left.contents) |contents| if (!std.mem.eql(u8, contents, right.contents.?)) return false;
    }
    return true;
}

fn printBytesMismatch(allocator: std.mem.Allocator, name: []const u8, rush: []const u8, reference: []const u8) !void {
    _ = allocator;
    std.debug.print("{s}:\n  rush:      ", .{name});
    printEscaped(rush);
    std.debug.print("\n  reference: ", .{});
    printEscaped(reference);
    std.debug.print("\n", .{});
}

fn printEscaped(bytes: []const u8) void {
    std.debug.print("\"", .{});
    for (bytes) |byte| switch (byte) {
        '\n' => std.debug.print("\\n", .{}),
        '\r' => std.debug.print("\\r", .{}),
        '\t' => std.debug.print("\\t", .{}),
        '"' => std.debug.print("\\\"", .{}),
        '\\' => std.debug.print("\\\\", .{}),
        else => if (std.ascii.isPrint(byte))
            std.debug.print("{c}", .{byte})
        else
            std.debug.print("\\x{x:0>2}", .{byte}),
    };
    std.debug.print("\"", .{});
}

fn printFileMismatch(rush: []const FileSnapshot, reference: []const FileSnapshot) void {
    std.debug.print("filesystem mismatch:\n", .{});
    std.debug.print("  rush files:\n", .{});
    for (rush) |file| std.debug.print("    {s} {s}\n", .{ @tagName(file.kind), file.path });
    std.debug.print("  reference files:\n", .{});
    for (reference) |file| std.debug.print("    {s} {s}\n", .{ @tagName(file.kind), file.path });
}
