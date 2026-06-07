//! Minimal command execution for lowered shell IR.

const std = @import("std");
const ir = @import("ir.zig");

pub const ExitStatus = u8;

pub const ExecuteOptions = struct {
    io: ?std.Io = null,
    allow_external: bool = false,
};

pub const CommandResult = struct {
    allocator: std.mem.Allocator,
    status: ExitStatus,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    env: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Executor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Executor) void {
        var iter = self.env.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn getEnv(self: Executor, name: []const u8) ?[]const u8 {
        return self.env.get(name);
    }

    pub fn setEnv(self: *Executor, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        const result = try self.env.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.key_ptr.*);
            self.allocator.free(result.value_ptr.*);
            result.key_ptr.* = try self.allocator.dupe(u8, name);
            result.value_ptr.* = owned_value;
        } else {
            result.value_ptr.* = owned_value;
        }
    }

    pub fn executeProgram(self: *Executor, program: ir.Program, options: ExecuteOptions) !CommandResult {
        var last = try emptyResult(self.allocator, 0);

        if (program.pipelines.len > 0) {
            for (program.pipelines) |pipeline| {
                if (shouldSkipPipeline(pipeline.op_before, last.status)) continue;
                last.deinit();
                last = try self.executePipeline(program, pipeline, options);
            }
            return last;
        }

        for (program.commands) |command| {
            last.deinit();
            last = try self.executeSimpleCommand(command, options);
        }
        return last;
    }

    fn executePipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) !CommandResult {
        if (self.canExecuteExternalPipeline(program, pipeline, options)) {
            const io = options.io orelse return error.MissingIoForExternalCommand;
            return self.executeExternalPipeline(program, pipeline, io);
        }

        var last = try emptyResult(self.allocator, 0);
        var stdin = try self.allocator.alloc(u8, 0);
        defer self.allocator.free(stdin);

        for (pipeline.command_indexes, 0..) |command_index, index| {
            last.deinit();
            last = try self.executeSimpleCommandWithInput(program.commands[command_index], stdin, options);

            if (index + 1 < pipeline.command_indexes.len) {
                self.allocator.free(stdin);
                stdin = try self.allocator.dupe(u8, last.stdout);
            }
        }

        return last;
    }

    fn canExecuteExternalPipeline(self: Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) bool {
        _ = self;
        if (!options.allow_external or options.io == null or pipeline.command_indexes.len < 2) return false;
        for (pipeline.command_indexes) |command_index| {
            const command = program.commands[command_index];
            if (command.argv.len == 0 or command.redirections.len != 0) return false;
            if (builtinFor(command.argv[0].text) != null) return false;
        }
        return true;
    }

    fn executeExternalPipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, io: std.Io) !CommandResult {
        const children = try self.allocator.alloc(std.process.Child, pipeline.command_indexes.len);
        defer self.allocator.free(children);
        var spawned: usize = 0;
        errdefer for (children[0..spawned]) |*child| child.kill(io);

        var previous_stdout: ?std.Io.File = null;
        defer if (previous_stdout) |file| file.close(io);

        for (pipeline.command_indexes, 0..) |command_index, index| {
            const command = program.commands[command_index];
            const argv = try argvForCommand(self.allocator, command);
            defer self.allocator.free(argv);

            const is_last = index + 1 == pipeline.command_indexes.len;
            children[index] = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = if (previous_stdout) |file| .{ .file = file } else .ignore,
                .stdout = .pipe,
                .stderr = if (is_last) .pipe else .inherit,
            });
            spawned += 1;

            if (previous_stdout) |file| file.close(io);
            previous_stdout = null;

            if (!is_last) {
                previous_stdout = children[index].stdout.?;
                children[index].stdout = null;
            }
        }

        const last_child = &children[pipeline.command_indexes.len - 1];
        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(self.allocator, io, multi_reader_buffer.toStreams(), &.{ last_child.stdout.?, last_child.stderr.? });
        defer multi_reader.deinit();

        while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();

        var status: ExitStatus = 0;
        for (children[0..spawned]) |*child| {
            const term = try child.wait(io);
            status = exitStatusFromTerm(term);
        }

        return .{
            .allocator = self.allocator,
            .status = status,
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
        };
    }

    pub fn executeSimpleCommand(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !CommandResult {
        return self.executeSimpleCommandWithInput(command, "", options);
    }

    fn executeSimpleCommandWithInput(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const effective_stdin = try self.applyInputRedirections(command, stdin, options, &owned_stdin);

        if (command.argv.len == 0) {
            try self.applyAssignments(command.assignments);
            return try self.applyOutputRedirections(command, try emptyResult(self.allocator, 0), options);
        }

        if (builtinFor(command.argv[0].text)) |builtin| {
            return try self.applyOutputRedirections(command, try builtin(self, command, effective_stdin), options);
        }

        if (!options.allow_external) {
            return try self.applyOutputRedirections(command, try errorResult(self.allocator, 127, command.argv[0].text, "command not found"), options);
        }

        const io = options.io orelse return error.MissingIoForExternalCommand;
        return try self.applyOutputRedirections(command, try self.executeExternal(command, io), options);
    }

    fn applyAssignments(self: *Executor, assignments: []const ir.WordRef) !void {
        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            try self.setEnv(assignment.text[0..equals], assignment.text[equals + 1 ..]);
        }
    }

    fn applyInputRedirections(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions, owned_stdin: *?[]u8) ![]const u8 {
        var current = stdin;
        for (command.redirections) |redirection| {
            if (!isStdinFileRedirection(redirection)) continue;
            const io = options.io orelse return error.MissingIoForRedirection;
            const target = redirection.target orelse continue;
            if (owned_stdin.*) |bytes| self.allocator.free(bytes);
            owned_stdin.* = try std.Io.Dir.cwd().readFileAlloc(io, target.text, self.allocator, .limited(1024 * 1024));
            current = owned_stdin.*.?;
        }
        return current;
    }

    fn applyOutputRedirections(self: *Executor, command: ir.SimpleCommand, result: CommandResult, options: ExecuteOptions) !CommandResult {
        var redirected = result;
        errdefer redirected.deinit();

        for (command.redirections) |redirection| {
            if (isFileOutputRedirection(redirection)) {
                const fd = redirectionFd(redirection) orelse 1;
                const stream = switch (fd) {
                    1 => &redirected.stdout,
                    2 => &redirected.stderr,
                    else => continue,
                };
                try self.writeRedirectedStream(stream, redirection, options);
                continue;
            }

            if (redirection.operator == .greater_and) {
                try self.applyDescriptorDuplication(&redirected, redirection);
            }
        }

        return redirected;
    }

    fn writeRedirectedStream(self: *Executor, stream: *[]u8, redirection: ir.Redirection, options: ExecuteOptions) !void {
        const io = options.io orelse return error.MissingIoForRedirection;
        const target = redirection.target orelse return;
        const flags: std.Io.Dir.CreateFileOptions = .{
            .truncate = redirection.operator != .dgreat,
        };
        var file = try std.Io.Dir.cwd().createFile(io, target.text, flags);
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        if (redirection.operator == .dgreat) {
            try writer.seekTo(try file.length(io));
        }
        try writer.interface.writeAll(stream.*);
        try writer.interface.flush();
        self.allocator.free(stream.*);
        stream.* = try self.allocator.alloc(u8, 0);
    }

    fn applyDescriptorDuplication(self: *Executor, result: *CommandResult, redirection: ir.Redirection) !void {
        const from_fd = redirectionFd(redirection) orelse 1;
        const target = redirection.target orelse return;
        const to_fd = parseFd(target.text) orelse return;

        if (from_fd == 2 and to_fd == 1) {
            const combined = try self.allocator.alloc(u8, result.stdout.len + result.stderr.len);
            @memcpy(combined[0..result.stdout.len], result.stdout);
            @memcpy(combined[result.stdout.len..], result.stderr);
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            result.stdout = combined;
            result.stderr = try self.allocator.alloc(u8, 0);
        } else if (from_fd == 1 and to_fd == 2) {
            const combined = try self.allocator.alloc(u8, result.stderr.len + result.stdout.len);
            @memcpy(combined[0..result.stderr.len], result.stderr);
            @memcpy(combined[result.stderr.len..], result.stdout);
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
            result.stdout = try self.allocator.alloc(u8, 0);
            result.stderr = combined;
        }
    }

    fn executeExternal(self: *Executor, command: ir.SimpleCommand, io: std.Io) !CommandResult {
        const argv = try argvForCommand(self.allocator, command);
        defer self.allocator.free(argv);

        const run_result = std.process.run(self.allocator, io, .{ .argv = argv }) catch |err| switch (err) {
            error.FileNotFound => return errorResult(self.allocator, 127, command.argv[0].text, "command not found"),
            else => return err,
        };

        return .{
            .allocator = self.allocator,
            .status = exitStatusFromTerm(run_result.term),
            .stdout = run_result.stdout,
            .stderr = run_result.stderr,
        };
    }
};

fn argvForCommand(allocator: std.mem.Allocator, command: ir.SimpleCommand) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, command.argv.len);
    for (command.argv, 0..) |word, index| {
        argv[index] = word.text;
    }
    return argv;
}

fn shouldSkipPipeline(op: ir.ListOp, previous_status: ExitStatus) bool {
    return switch (op) {
        .sequence => false,
        .and_if => previous_status != 0,
        .or_if => previous_status == 0,
    };
}

const BuiltinFn = *const fn (*Executor, ir.SimpleCommand, []const u8) anyerror!CommandResult;

fn builtinFor(name: []const u8) ?BuiltinFn {
    if (std.mem.eql(u8, name, ":")) return builtinTrue;
    if (std.mem.eql(u8, name, "true")) return builtinTrue;
    if (std.mem.eql(u8, name, "false")) return builtinFalse;
    if (std.mem.eql(u8, name, "echo")) return builtinEcho;
    if (std.mem.eql(u8, name, "cat")) return builtinCat;
    return null;
}

fn builtinTrue(self: *Executor, command: ir.SimpleCommand, stdin: []const u8) !CommandResult {
    _ = command;
    _ = stdin;
    return emptyResult(self.allocator, 0);
}

fn builtinFalse(self: *Executor, command: ir.SimpleCommand, stdin: []const u8) !CommandResult {
    _ = command;
    _ = stdin;
    return emptyResult(self.allocator, 1);
}

fn builtinEcho(self: *Executor, command: ir.SimpleCommand, stdin: []const u8) !CommandResult {
    _ = stdin;
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);

    for (command.argv[1..], 0..) |arg, index| {
        if (index > 0) try stdout.append(self.allocator, ' ');
        try stdout.appendSlice(self.allocator, arg.text);
    }
    try stdout.append(self.allocator, '\n');

    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = try stdout.toOwnedSlice(self.allocator),
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn builtinCat(self: *Executor, command: ir.SimpleCommand, stdin: []const u8) !CommandResult {
    // Initial pipeline-friendly `cat`: with no operands, copy stdin to stdout.
    // File operands belong with the fuller POSIX builtin/external behavior later.
    if (command.argv.len > 1) {
        return errorResult(self.allocator, 1, "cat", "file operands are not implemented yet");
    }
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = try self.allocator.dupe(u8, stdin),
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn isStdinFileRedirection(redirection: ir.Redirection) bool {
    const fd = redirectionFd(redirection) orelse 0;
    return fd == 0 and redirection.operator == .less;
}

fn isFileOutputRedirection(redirection: ir.Redirection) bool {
    const fd = redirectionFd(redirection) orelse 1;
    if (fd != 1 and fd != 2) return false;
    return switch (redirection.operator) {
        .greater, .dgreat, .clobber => true,
        else => false,
    };
}

fn redirectionFd(redirection: ir.Redirection) ?u8 {
    if (redirection.io_number) |io_number| return parseFd(io_number.text);
    return null;
}

fn parseFd(text: []const u8) ?u8 {
    if (text.len != 1 or !std.ascii.isDigit(text[0])) return null;
    return text[0] - '0';
}

fn emptyResult(allocator: std.mem.Allocator, status: ExitStatus) !CommandResult {
    return .{
        .allocator = allocator,
        .status = status,
        .stdout = try allocator.alloc(u8, 0),
        .stderr = try allocator.alloc(u8, 0),
    };
}

fn errorResult(allocator: std.mem.Allocator, status: ExitStatus, command: []const u8, message: []const u8) !CommandResult {
    const stderr = try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{ command, message });
    errdefer allocator.free(stderr);
    return .{
        .allocator = allocator,
        .status = status,
        .stdout = try allocator.alloc(u8, 0),
        .stderr = stderr,
    };
}

fn exitStatusFromTerm(term: std.process.Child.Term) ExitStatus {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .stopped => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .unknown => 1,
    };
}

fn parseAndLower(allocator: std.mem.Allocator, source: []const u8) !struct { parsed: @import("parser.zig").ParseResult, program: ir.Program } {
    const parser = @import("parser.zig");
    var parsed = try parser.parse(allocator, source, .{});
    errdefer parsed.deinit();
    var program = try ir.lowerSimpleCommands(allocator, parsed);
    errdefer program.deinit();
    return .{ .parsed = parsed, .program = program };
}

test "executor uses quote-removed argv text" {
    var lowered = try parseAndLower(std.testing.allocator, "echo 'hello world'");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world\n", result.stdout);
}

test "executor runs true false and echo builtins" {
    var lowered = try parseAndLower(std.testing.allocator, "true");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);

    var lowered_false = try parseAndLower(std.testing.allocator, "false");
    defer lowered_false.parsed.deinit();
    defer lowered_false.program.deinit();
    var false_result = try executor.executeProgram(lowered_false.program, .{});
    defer false_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), false_result.status);

    var lowered_echo = try parseAndLower(std.testing.allocator, "echo hello world");
    defer lowered_echo.parsed.deinit();
    defer lowered_echo.program.deinit();
    var echo_result = try executor.executeProgram(lowered_echo.program, .{});
    defer echo_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), echo_result.status);
    try std.testing.expectEqualStrings("hello world\n", echo_result.stdout);
}

test "executor applies assignment-only commands to shell environment" {
    var lowered = try parseAndLower(std.testing.allocator, "FOO=bar");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("bar", executor.getEnv("FOO").?);
}

test "executor reports command not found without external execution" {
    var lowered = try parseAndLower(std.testing.allocator, "definitely-not-a-rush-builtin");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("definitely-not-a-rush-builtin: command not found\n", result.stderr);
}

test "executor short-circuits AND and OR lists" {
    var and_lowered = try parseAndLower(std.testing.allocator, "false && echo nope");
    defer and_lowered.parsed.deinit();
    defer and_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var and_result = try executor.executeProgram(and_lowered.program, .{});
    defer and_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), and_result.status);
    try std.testing.expectEqualStrings("", and_result.stdout);

    var or_lowered = try parseAndLower(std.testing.allocator, "false || echo yes");
    defer or_lowered.parsed.deinit();
    defer or_lowered.program.deinit();
    var or_result = try executor.executeProgram(or_lowered.program, .{});
    defer or_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), or_result.status);
    try std.testing.expectEqualStrings("yes\n", or_result.stdout);

    var skip_or_lowered = try parseAndLower(std.testing.allocator, "true || echo nope");
    defer skip_or_lowered.parsed.deinit();
    defer skip_or_lowered.program.deinit();
    var skip_or_result = try executor.executeProgram(skip_or_lowered.program, .{});
    defer skip_or_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), skip_or_result.status);
    try std.testing.expectEqualStrings("", skip_or_result.stdout);
}

test "executor pipes stdout into stdin-consuming builtins" {
    var lowered = try parseAndLower(std.testing.allocator, "echo hello | cat");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
}

test "executor redirects stdin from files for builtins" {
    const path = "rush-test-stdin-redirection.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "from file" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "cat < rush-test-stdin-redirection.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("from file", result.stdout);
}

test "executor redirects stdout to files" {
    const path = "rush-test-redirection-output.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo file > rush-test-redirection-output.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("file\n", contents);
}

test "executor redirects stderr to files" {
    const path = "rush-test-stderr-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "definitely-not-a-rush-builtin 2> rush-test-stderr-redirection.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.stderr);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("definitely-not-a-rush-builtin: command not found\n", contents);
}

test "executor appends stdout redirections" {
    const path = "rush-test-redirection-append.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo one >> rush-test-redirection-append.tmp; echo two >> rush-test-redirection-append.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}

test "executor appends stderr redirections and duplicates descriptors" {
    const path = "rush-test-stderr-append.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var append_lowered = try parseAndLower(std.testing.allocator, "missing-one 2>> rush-test-stderr-append.tmp; missing-two 2>> rush-test-stderr-append.tmp");
    defer append_lowered.parsed.deinit();
    defer append_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var append_result = try executor.executeProgram(append_lowered.program, .{ .io = std.testing.io });
    defer append_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), append_result.status);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("missing-one: command not found\nmissing-two: command not found\n", contents);

    var dup_lowered = try parseAndLower(std.testing.allocator, "missing-three 2>&1");
    defer dup_lowered.parsed.deinit();
    defer dup_lowered.program.deinit();
    var dup_result = try executor.executeProgram(dup_lowered.program, .{});
    defer dup_result.deinit();
    try std.testing.expectEqualStrings("missing-three: command not found\n", dup_result.stdout);
    try std.testing.expectEqualStrings("", dup_result.stderr);
}

test "executor wires external pipelines with real process pipes" {
    var lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf hello | /usr/bin/cat");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello", result.stdout);
}

test "executor can run an external command when allowed" {
    var lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf ok");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ok", result.stdout);
}
