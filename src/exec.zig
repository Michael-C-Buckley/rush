//! Minimal command execution for lowered shell IR.

const std = @import("std");
const compat = @import("compat.zig");
const expand = @import("expand.zig");
const ir = @import("ir.zig");

pub const ExitStatus = u8;

pub const ExecuteOptions = struct {
    io: ?std.Io = null,
    allow_external: bool = false,
    features: compat.Features = .{},
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

pub const ArrayValue = struct {
    values: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ArrayValue, allocator: std.mem.Allocator) void {
        for (self.values.items) |value| allocator.free(value);
        self.values.deinit(allocator);
        self.* = undefined;
    }
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    env: std.StringHashMapUnmanaged([]const u8) = .empty,
    arrays: std.StringHashMapUnmanaged(ArrayValue) = .empty,

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
        var array_iter = self.arrays.iterator();
        while (array_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.arrays.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn getEnv(self: Executor, name: []const u8) ?[]const u8 {
        return self.env.get(name);
    }

    pub fn setArrayElement(self: *Executor, name: []const u8, index: usize, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const result = try self.arrays.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
        } else {
            result.value_ptr.* = .{};
        }
        const array = result.value_ptr;
        while (array.values.items.len <= index) {
            try array.values.append(self.allocator, try self.allocator.alloc(u8, 0));
        }
        self.allocator.free(array.values.items[index]);
        array.values.items[index] = try self.allocator.dupe(u8, value);
    }

    pub fn getArrayElement(self: Executor, name: []const u8, index: usize) ?[]const u8 {
        const array = self.arrays.get(name) orelse return null;
        if (index >= array.values.items.len) return null;
        return array.values.items[index];
    }

    pub fn unsetArray(self: *Executor, name: []const u8) void {
        if (self.arrays.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            var value = entry.value;
            value.deinit(self.allocator);
        }
    }

    pub fn unsetEnv(self: *Executor, name: []const u8) void {
        if (self.env.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
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
        const expanded = try self.expandSimpleCommand(command, options);
        defer self.freeExpandedCommand(expanded);

        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const effective_stdin = try self.applyInputRedirections(expanded, stdin, options, &owned_stdin);

        if (expanded.argv.len == 0) {
            try self.applyAssignments(expanded.assignments);
            return try self.applyOutputRedirections(expanded, try emptyResult(self.allocator, 0), options);
        }

        if (builtinFor(expanded.argv[0].text)) |builtin| {
            return try self.applyOutputRedirections(expanded, try builtin(self, expanded, effective_stdin, options), options);
        }

        if (!options.allow_external) {
            return try self.applyOutputRedirections(expanded, try errorResult(self.allocator, 127, expanded.argv[0].text, "command not found"), options);
        }

        const io = options.io orelse return error.MissingIoForExternalCommand;
        return try self.applyOutputRedirections(expanded, try self.executeExternal(expanded, io), options);
    }

    fn expandSimpleCommand(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !ir.SimpleCommand {
        const assignments = try self.expandWords(command.assignments, options);
        errdefer self.freeWords(assignments);
        const argv = try self.expandArgv(command.argv, options);
        errdefer self.freeWords(argv);
        const redirections = try self.expandRedirections(command.redirections, options);
        errdefer self.freeRedirections(redirections);

        return .{
            .span = command.span,
            .assignments = assignments,
            .argv = argv,
            .redirections = redirections,
        };
    }

    fn expandArgv(self: *Executor, words: []const ir.WordRef, options: ExecuteOptions) ![]ir.WordRef {
        var expanded: std.ArrayList(ir.WordRef) = .empty;
        errdefer {
            for (expanded.items) |word| self.freeWord(word);
            expanded.deinit(self.allocator);
        }

        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        for (words) |word| {
            var fields = try expand.expandWord(self.allocator, word.raw, .{ .env = self.envLookup(), .io = options.io, .features = options.features, .command_substitution = commandSubstitution(&substitution_context) });
            defer fields.deinit();
            for (fields.fields) |field| {
                const raw = try self.allocator.dupe(u8, word.raw);
                errdefer self.allocator.free(raw);
                const text = try self.allocator.dupe(u8, field);
                errdefer self.allocator.free(text);
                try expanded.append(self.allocator, .{ .span = word.span, .raw = raw, .text = text });
            }
        }

        return expanded.toOwnedSlice(self.allocator);
    }

    fn expandWords(self: *Executor, words: []const ir.WordRef, options: ExecuteOptions) ![]ir.WordRef {
        const expanded = try self.allocator.alloc(ir.WordRef, words.len);
        errdefer self.allocator.free(expanded);
        var initialized: usize = 0;
        errdefer for (expanded[0..initialized]) |word| self.freeWord(word);

        for (words, 0..) |word, index| {
            expanded[index] = try self.expandWord(word, options);
            initialized += 1;
        }
        return expanded;
    }

    fn expandRedirections(self: *Executor, redirections: []const ir.Redirection, options: ExecuteOptions) ![]ir.Redirection {
        const expanded = try self.allocator.alloc(ir.Redirection, redirections.len);
        errdefer self.allocator.free(expanded);
        var initialized: usize = 0;
        errdefer for (expanded[0..initialized]) |redirection| self.freeRedirection(redirection);

        for (redirections, 0..) |redirection, index| {
            expanded[index] = .{
                .span = redirection.span,
                .io_number = if (redirection.io_number) |word| try self.expandWord(word, options) else null,
                .operator = redirection.operator,
                .target = if (redirection.target) |word| try self.expandWord(word, options) else null,
            };
            initialized += 1;
        }
        return expanded;
    }

    fn expandWord(self: *Executor, word: ir.WordRef, options: ExecuteOptions) !ir.WordRef {
        const raw = try self.allocator.dupe(u8, word.raw);
        errdefer self.allocator.free(raw);
        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        const text = try expand.expandWordScalar(self.allocator, word.raw, .{ .env = self.envLookup(), .features = options.features, .command_substitution = commandSubstitution(&substitution_context) });
        return .{ .span = word.span, .raw = raw, .text = text };
    }

    const CommandSubstitutionContext = struct {
        executor: *Executor,
        options: ExecuteOptions,
    };

    fn commandSubstitution(context: *CommandSubstitutionContext) expand.CommandSubstitution {
        return .{ .context = context, .runFn = runCommandSubstitution };
    }

    fn runCommandSubstitution(context: ?*anyopaque, allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
        const substitution_context: *CommandSubstitutionContext = @ptrCast(@alignCast(context.?));
        var parsed = try @import("parser.zig").parse(substitution_context.executor.allocator, script, .{ .features = substitution_context.options.features });
        defer parsed.deinit();
        var program = try ir.lowerSimpleCommands(substitution_context.executor.allocator, parsed);
        defer program.deinit();
        var result = try substitution_context.executor.executeProgram(program, substitution_context.options);
        defer result.deinit();
        return allocator.dupe(u8, result.stdout);
    }

    fn envLookup(self: *Executor) expand.EnvLookup {
        return .{ .context = self, .lookupFn = lookupEnv };
    }

    fn lookupEnv(context: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const Executor = @ptrCast(@alignCast(context.?));
        return self.getEnv(name);
    }

    fn freeExpandedCommand(self: *Executor, command: ir.SimpleCommand) void {
        self.freeWords(command.assignments);
        self.freeWords(command.argv);
        self.freeRedirections(command.redirections);
    }

    fn freeWords(self: *Executor, words: []const ir.WordRef) void {
        for (words) |word| self.freeWord(word);
        self.allocator.free(words);
    }

    fn freeRedirections(self: *Executor, redirections: []const ir.Redirection) void {
        for (redirections) |redirection| self.freeRedirection(redirection);
        self.allocator.free(redirections);
    }

    fn freeRedirection(self: *Executor, redirection: ir.Redirection) void {
        if (redirection.io_number) |word| self.freeWord(word);
        if (redirection.target) |word| self.freeWord(word);
    }

    fn freeWord(self: *Executor, word: ir.WordRef) void {
        self.allocator.free(word.raw);
        self.allocator.free(word.text);
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

        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| switch (err) {
            error.FileNotFound => return errorResult(self.allocator, 127, command.argv[0].text, "command not found"),
            else => return err,
        };
        defer child.kill(io);

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(self.allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();

        while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();

        const term = try child.wait(io);
        return .{
            .allocator = self.allocator,
            .status = exitStatusFromTerm(term),
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
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

const BuiltinFn = *const fn (*Executor, ir.SimpleCommand, []const u8, ExecuteOptions) anyerror!CommandResult;

fn builtinFor(name: []const u8) ?BuiltinFn {
    if (std.mem.eql(u8, name, ":")) return builtinTrue;
    if (std.mem.eql(u8, name, "true")) return builtinTrue;
    if (std.mem.eql(u8, name, "false")) return builtinFalse;
    if (std.mem.eql(u8, name, "echo")) return builtinEcho;
    if (std.mem.eql(u8, name, "cat")) return builtinCat;
    if (std.mem.eql(u8, name, "cd")) return builtinCd;
    if (std.mem.eql(u8, name, "pwd")) return builtinPwd;
    if (std.mem.eql(u8, name, "export")) return builtinExport;
    if (std.mem.eql(u8, name, "unset")) return builtinUnset;
    if (std.mem.eql(u8, name, "env")) return builtinEnv;
    if (std.mem.eql(u8, name, "test")) return builtinTest;
    if (std.mem.eql(u8, name, "[")) return builtinTest;
    return null;
}

fn builtinTrue(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    _ = options;
    return emptyResult(self.allocator, 0);
}

fn builtinFalse(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    _ = options;
    return emptyResult(self.allocator, 1);
}

fn builtinEcho(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
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

fn builtinCat(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = options;
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

fn builtinCd(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;
    if (command.argv.len > 2) return errorResult(self.allocator, 2, "cd", "too many arguments");
    const target = if (command.argv.len == 2) command.argv[1].text else self.getEnv("HOME") orelse return errorResult(self.allocator, 1, "cd", "HOME not set");
    std.process.setCurrentPath(io, target) catch |err| {
        const message = try std.fmt.allocPrint(self.allocator, "{s}: {t}", .{ target, err });
        defer self.allocator.free(message);
        return errorResult(self.allocator, 1, "cd", message);
    };
    return emptyResult(self.allocator, 0);
}

fn builtinPwd(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;
    const cwd = try std.process.currentPathAlloc(io, self.allocator);
    defer self.allocator.free(cwd);
    const stdout = try std.fmt.allocPrint(self.allocator, "{s}\n", .{cwd});
    errdefer self.allocator.free(stdout);
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = stdout,
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn builtinExport(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len == 1) {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var iter = self.env.iterator();
        while (iter.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, lessThanString);

        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        for (names.items) |name| {
            try stdout.appendSlice(self.allocator, "export ");
            try stdout.appendSlice(self.allocator, name);
            try stdout.append(self.allocator, '=');
            try stdout.appendSlice(self.allocator, self.env.get(name).?);
            try stdout.append(self.allocator, '\n');
        }
        return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
    }

    for (command.argv[1..]) |arg| {
        const equals = std.mem.indexOfScalar(u8, arg.text, '=') orelse continue;
        try self.setEnv(arg.text[0..equals], arg.text[equals + 1 ..]);
    }
    return emptyResult(self.allocator, 0);
}

fn builtinUnset(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    for (command.argv[1..]) |arg| {
        self.unsetEnv(arg.text);
    }
    return emptyResult(self.allocator, 0);
}

fn builtinEnv(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len != 1) return errorResult(self.allocator, 125, "env", "arguments are not implemented yet");

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var iter = self.env.iterator();
    while (iter.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    for (names.items) |name| {
        try stdout.appendSlice(self.allocator, name);
        try stdout.append(self.allocator, '=');
        try stdout.appendSlice(self.allocator, self.env.get(name).?);
        try stdout.append(self.allocator, '\n');
    }

    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = try stdout.toOwnedSlice(self.allocator),
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn builtinTest(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const is_bracket = std.mem.eql(u8, command.argv[0].text, "[");
    const args = command.argv[1..];
    if (is_bracket) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1].text, "]")) {
            return errorResult(self.allocator, 2, "[", "missing ]");
        }
        return emptyResult(self.allocator, if (try evalTest(self.allocator, options, args[0 .. args.len - 1])) 0 else 1);
    }
    return emptyResult(self.allocator, if (try evalTest(self.allocator, options, args)) 0 else 1);
}

fn evalTest(allocator: std.mem.Allocator, options: ExecuteOptions, args: []const ir.WordRef) !bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].text.len != 0,
        2 => try evalUnaryTest(allocator, options, args[0].text, args[1].text),
        3 => if (std.mem.eql(u8, args[0].text, "!"))
            !(try evalTest(allocator, options, args[1..]))
        else
            try evalBinaryTest(args[0].text, args[1].text, args[2].text),
        4 => if (std.mem.eql(u8, args[0].text, "!")) !(try evalTest(allocator, options, args[1..])) else error.InvalidTestExpression,
        else => error.InvalidTestExpression,
    };
}

fn evalUnaryTest(allocator: std.mem.Allocator, options: ExecuteOptions, op: []const u8, operand: []const u8) !bool {
    if (std.mem.eql(u8, op, "!")) return operand.len == 0;
    if (std.mem.eql(u8, op, "-n")) return operand.len != 0;
    if (std.mem.eql(u8, op, "-z")) return operand.len == 0;
    if (std.mem.eql(u8, op, "-e") or std.mem.eql(u8, op, "-f") or std.mem.eql(u8, op, "-d")) {
        const io = options.io orelse return false;
        const stat = statPath(allocator, io, operand) catch return false;
        if (std.mem.eql(u8, op, "-e")) return true;
        if (std.mem.eql(u8, op, "-f")) return stat.kind == .file;
        if (std.mem.eql(u8, op, "-d")) return stat.kind == .directory;
    }
    return error.InvalidTestExpression;
}

fn evalBinaryTest(left: []const u8, op: []const u8, right: []const u8) !bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, left, right);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, left, right);

    const lhs = std.fmt.parseInt(i64, left, 10) catch return error.InvalidTestExpression;
    const rhs = std.fmt.parseInt(i64, right, 10) catch return error.InvalidTestExpression;
    if (std.mem.eql(u8, op, "-eq")) return lhs == rhs;
    if (std.mem.eql(u8, op, "-ne")) return lhs != rhs;
    if (std.mem.eql(u8, op, "-gt")) return lhs > rhs;
    if (std.mem.eql(u8, op, "-ge")) return lhs >= rhs;
    if (std.mem.eql(u8, op, "-lt")) return lhs < rhs;
    if (std.mem.eql(u8, op, "-le")) return lhs <= rhs;
    return error.InvalidTestExpression;
}

fn statPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.File.Stat {
    _ = allocator;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return file.stat(io);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

test "executor expands command substitutions recursively" {
    var lowered = try parseAndLower(std.testing.allocator, "echo before-$(echo hi)-after");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("before-hi-after\n", result.stdout);
}

test "executor stores Bash array runtime data" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    try executor.setArrayElement("arr", 0, "zero");
    try executor.setArrayElement("arr", 2, "two");
    try executor.setArrayElement("arr", 0, "ZERO");

    try std.testing.expectEqualStrings("ZERO", executor.getArrayElement("arr", 0).?);
    try std.testing.expectEqualStrings("", executor.getArrayElement("arr", 1).?);
    try std.testing.expectEqualStrings("two", executor.getArrayElement("arr", 2).?);
    try std.testing.expect(executor.getArrayElement("arr", 3) == null);

    executor.unsetArray("arr");
    try std.testing.expect(executor.getArrayElement("arr", 0) == null);
}

test "executor implements test and bracket builtins" {
    const path = "rush-test-builtin-file.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const Case = struct { script: []const u8, status: ExitStatus };
    const cases = [_]Case{
        .{ .script = "test nonempty", .status = 0 },
        .{ .script = "test ''", .status = 1 },
        .{ .script = "test a = a", .status = 0 },
        .{ .script = "test a != a", .status = 1 },
        .{ .script = "test 3 -gt 2", .status = 0 },
        .{ .script = "test 3 -le 2", .status = 1 },
        .{ .script = "test -e rush-test-builtin-file.tmp", .status = 0 },
        .{ .script = "test -f rush-test-builtin-file.tmp", .status = 0 },
        .{ .script = "test ! -e rush-test-missing.tmp", .status = 0 },
        .{ .script = "[ a = a ]", .status = 0 },
        .{ .script = "[ a = b ]", .status = 1 },
    };

    for (cases) |case| {
        var lowered = try parseAndLower(std.testing.allocator, case.script);
        defer lowered.parsed.deinit();
        defer lowered.program.deinit();

        var executor = Executor.init(std.testing.allocator);
        defer executor.deinit();

        var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
        defer result.deinit();
        try std.testing.expectEqual(case.status, result.status);
    }
}

test "executor implements unset and env builtins" {
    var lowered = try parseAndLower(std.testing.allocator, "export A=one B=two; unset A; env");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "B=two\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "A=one\n") == null);
    try std.testing.expect(executor.getEnv("A") == null);
    try std.testing.expectEqualStrings("two", executor.getEnv("B").?);
}

test "executor implements pwd cd and export builtins" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var pwd_lowered = try parseAndLower(std.testing.allocator, "pwd");
    defer pwd_lowered.parsed.deinit();
    defer pwd_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var pwd_result = try executor.executeProgram(pwd_lowered.program, .{ .io = std.testing.io });
    defer pwd_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), pwd_result.status);
    try std.testing.expect(std.mem.indexOf(u8, pwd_result.stdout, original_cwd) != null);

    var cd_lowered = try parseAndLower(std.testing.allocator, "cd /tmp; pwd");
    defer cd_lowered.parsed.deinit();
    defer cd_lowered.program.deinit();
    var cd_result = try executor.executeProgram(cd_lowered.program, .{ .io = std.testing.io });
    defer cd_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), cd_result.status);
    try std.testing.expectEqualStrings("/tmp\n", cd_result.stdout);

    var export_lowered = try parseAndLower(std.testing.allocator, "export RUSH_TEST_EXPORT=ok; echo $RUSH_TEST_EXPORT");
    defer export_lowered.parsed.deinit();
    defer export_lowered.program.deinit();
    var export_result = try executor.executeProgram(export_lowered.program, .{});
    defer export_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), export_result.status);
    try std.testing.expectEqualStrings("ok\n", export_result.stdout);
}

test "executor expands arithmetic expressions in argv" {
    var lowered = try parseAndLower(std.testing.allocator, "echo $((1 + 2 * 3))");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("7\n", result.stdout);
}

test "executor expands pathname patterns in argv" {
    const a = "rush-exec-glob-a.tmp";
    const b = "rush-exec-glob-b.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, a) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, b) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "echo rush-exec-glob-?.tmp");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush-exec-glob-a.tmp rush-exec-glob-b.tmp\n", result.stdout);
}

test "executor field-splits unquoted parameter expansion in argv" {
    var lowered = try parseAndLower(std.testing.allocator, "WORDS='one two'; echo $WORDS");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("one two\n", result.stdout);
}

test "executor expands parameters from shell environment" {
    var lowered = try parseAndLower(std.testing.allocator, "FOO=bar; echo $FOO");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("bar\n", result.stdout);
}

test "executor expands redirection targets from shell environment" {
    const path = "rush-test-expanded-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var lowered = try parseAndLower(std.testing.allocator, "OUT=rush-test-expanded-redirection.tmp; echo hi > $OUT");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("hi\n", contents);
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

test "executor captures stderr and status from spawned external commands" {
    var lowered = try parseAndLower(std.testing.allocator, "/bin/sh -c 'echo err >&2; exit 7'");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("err\n", result.stderr);
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
