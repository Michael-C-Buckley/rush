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

    pub fn executeSimpleCommand(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !CommandResult {
        return self.executeSimpleCommandWithInput(command, "", options);
    }

    fn executeSimpleCommandWithInput(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
        if (command.argv.len == 0) {
            try self.applyAssignments(command.assignments);
            return try self.applyRedirections(command, try emptyResult(self.allocator, 0), options);
        }

        if (builtinFor(command.argv[0].text)) |builtin| {
            return try self.applyRedirections(command, try builtin(self, command, stdin), options);
        }

        if (!options.allow_external) {
            return errorResult(self.allocator, 127, command.argv[0].text, "command not found");
        }

        const io = options.io orelse return error.MissingIoForExternalCommand;
        return try self.applyRedirections(command, try self.executeExternal(command, io), options);
    }

    fn applyAssignments(self: *Executor, assignments: []const ir.WordRef) !void {
        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            try self.setEnv(assignment.text[0..equals], assignment.text[equals + 1 ..]);
        }
    }

    fn applyRedirections(self: *Executor, command: ir.SimpleCommand, result: CommandResult, options: ExecuteOptions) !CommandResult {
        var redirected = result;
        errdefer redirected.deinit();

        for (command.redirections) |redirection| {
            if (!isStdoutRedirection(redirection)) continue;
            const io = options.io orelse return error.MissingIoForRedirection;
            const target = redirection.target orelse continue;
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
            try writer.interface.writeAll(redirected.stdout);
            try writer.interface.flush();
            self.allocator.free(redirected.stdout);
            redirected.stdout = try self.allocator.alloc(u8, 0);
        }

        return redirected;
    }

    fn executeExternal(self: *Executor, command: ir.SimpleCommand, io: std.Io) !CommandResult {
        const argv = try self.allocator.alloc([]const u8, command.argv.len);
        defer self.allocator.free(argv);
        for (command.argv, 0..) |word, index| {
            argv[index] = word.text;
        }

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

fn isStdoutRedirection(redirection: ir.Redirection) bool {
    if (redirection.io_number) |io_number| {
        if (!std.mem.eql(u8, io_number.text, "1")) return false;
    }
    return switch (redirection.operator) {
        .greater, .dgreat, .clobber => true,
        else => false,
    };
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
