//! Minimal command execution for lowered shell IR.

const std = @import("std");
const compat = @import("compat.zig");
const expand = @import("expand.zig");
const ir = @import("ir.zig");
const parser = @import("parser.zig");

pub const ExitStatus = u8;

pub const ExecuteOptions = struct {
    io: ?std.Io = null,
    allow_external: bool = false,
    features: compat.Features = .{},
};

pub const ShellOptions = struct {
    pipefail: bool = false,
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

pub const LoopControlKind = enum {
    break_loop,
    continue_loop,
};

pub const LoopControl = struct {
    kind: LoopControlKind,
    levels: usize,
};

pub const CallFrame = struct {
    params: []const []const u8,
    count: []const u8,
    joined: []const u8,

    pub fn deinit(self: *CallFrame, allocator: std.mem.Allocator) void {
        for (self.params) |param| allocator.free(param);
        allocator.free(self.params);
        allocator.free(self.count);
        allocator.free(self.joined);
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
    functions: std.StringHashMapUnmanaged([]const u8) = .empty,
    shell_options: ShellOptions = .{},
    call_frames: std.ArrayList(CallFrame) = .empty,
    function_depth: usize = 0,
    pending_return: ?ExitStatus = null,
    loop_depth: usize = 0,
    pending_loop_control: ?LoopControl = null,

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
        var function_iter = self.functions.iterator();
        while (function_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.functions.deinit(self.allocator);
        for (self.call_frames.items) |*frame| frame.deinit(self.allocator);
        self.call_frames.deinit(self.allocator);
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
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);
        var last_status: ExitStatus = 0;

        if (program.statements.len > 0) {
            for (program.statements) |statement| {
                if (shouldSkipPipeline(statement.op_before, last_status)) continue;
                var result = switch (statement.kind) {
                    .pipeline => try self.executePipeline(program, program.pipelines[statement.index], options),
                    .if_command => try self.executeIfCommand(program.if_commands[statement.index], options),
                    .loop_command => try self.executeLoopCommand(program.loop_commands[statement.index], options),
                    .for_command => try self.executeForCommand(program.for_commands[statement.index], options),
                    .case_command => try self.executeCaseCommand(program.case_commands[statement.index], options),
                    .function_definition => try self.executeFunctionDefinition(program.function_definitions[statement.index]),
                    .bash_test_command => try self.executeBashTestCommand(program.bash_test_commands[statement.index], options),
                    .brace_group => try self.executeBraceGroup(program.brace_groups[statement.index], options),
                    .subshell => try self.executeSubshell(program.subshells[statement.index], options),
                };
                defer result.deinit();
                try stdout.appendSlice(self.allocator, result.stdout);
                try stderr.appendSlice(self.allocator, result.stderr);
                last_status = result.status;
                if (self.pending_return != null or self.pending_loop_control != null) break;
            }
            return .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) };
        }

        if (program.pipelines.len > 0) {
            for (program.pipelines) |pipeline| {
                if (shouldSkipPipeline(pipeline.op_before, last_status)) continue;
                var result = try self.executePipeline(program, pipeline, options);
                defer result.deinit();
                try stdout.appendSlice(self.allocator, result.stdout);
                try stderr.appendSlice(self.allocator, result.stderr);
                last_status = result.status;
                if (self.pending_return != null or self.pending_loop_control != null) break;
            }
            return .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) };
        }

        for (program.commands) |command| {
            var result = try self.executeSimpleCommand(command, options);
            defer result.deinit();
            try stdout.appendSlice(self.allocator, result.stdout);
            try stderr.appendSlice(self.allocator, result.stderr);
            last_status = result.status;
            if (self.pending_return != null or self.pending_loop_control != null) break;
        }
        return .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) };
    }

    fn executeSubshell(self: *Executor, subshell: ir.Subshell, options: ExecuteOptions) !CommandResult {
        var child = Executor.init(self.allocator);
        defer child.deinit();
        try child.copyStateFrom(self);
        const redirections = try self.expandRedirections(subshell.redirections, options);
        defer self.freeRedirections(redirections);
        var result = try child.executeScriptSlice(subshell.body, options);
        errdefer result.deinit();
        const wrapper: ir.SimpleCommand = .{
            .span = subshell.span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = redirections,
        };
        return self.applyOutputRedirections(wrapper, result, options);
    }

    fn executeBraceGroup(self: *Executor, group: ir.BraceGroup, options: ExecuteOptions) !CommandResult {
        const redirections = try self.expandRedirections(group.redirections, options);
        defer self.freeRedirections(redirections);
        var result = try self.executeScriptSlice(group.body, options);
        errdefer result.deinit();
        const wrapper: ir.SimpleCommand = .{
            .span = group.span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = redirections,
        };
        return self.applyOutputRedirections(wrapper, result, options);
    }

    fn executeBashTestCommand(self: *Executor, command: ir.BashTestCommand, options: ExecuteOptions) !CommandResult {
        const args = try self.expandWords(command.args, options);
        defer self.freeWords(args);
        const matched = evalBashTest(self.allocator, options, args) catch return errorResult(self.allocator, 2, "[[", "invalid expression");
        return emptyResult(self.allocator, if (matched) 0 else 1);
    }

    fn executeFunctionDefinition(self: *Executor, definition: ir.FunctionDefinition) !CommandResult {
        try self.setFunction(definition.name, definition.body);
        return emptyResult(self.allocator, 0);
    }

    fn copyStateFrom(self: *Executor, other: *const Executor) !void {
        self.shell_options = other.shell_options;
        var env_iter = other.env.iterator();
        while (env_iter.next()) |entry| try self.setEnv(entry.key_ptr.*, entry.value_ptr.*);
        var function_iter = other.functions.iterator();
        while (function_iter.next()) |entry| try self.setFunction(entry.key_ptr.*, entry.value_ptr.*);
        var array_iter = other.arrays.iterator();
        while (array_iter.next()) |entry| {
            for (entry.value_ptr.values.items, 0..) |value, index| {
                try self.setArrayElement(entry.key_ptr.*, index, value);
            }
        }
        for (other.call_frames.items) |frame| {
            var params = try self.allocator.alloc([]const u8, frame.params.len);
            errdefer self.allocator.free(params);
            var initialized: usize = 0;
            errdefer for (params[0..initialized]) |param| self.allocator.free(param);
            for (frame.params, 0..) |param, index| {
                params[index] = try self.allocator.dupe(u8, param);
                initialized += 1;
            }
            const count = try self.allocator.dupe(u8, frame.count);
            errdefer self.allocator.free(count);
            const joined = try self.allocator.dupe(u8, frame.joined);
            errdefer self.allocator.free(joined);
            try self.call_frames.append(self.allocator, .{ .params = params, .count = count, .joined = joined });
        }
    }

    fn setFunction(self: *Executor, name: []const u8, body: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(owned_body);
        const result = try self.functions.getOrPut(self.allocator, owned_name);
        if (result.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(result.value_ptr.*);
            result.value_ptr.* = owned_body;
        } else {
            result.value_ptr.* = owned_body;
        }
    }

    fn executeCaseCommand(self: *Executor, command: ir.CaseCommand, options: ExecuteOptions) !CommandResult {
        const subject_words = try self.expandWords(&.{command.word}, options);
        defer self.freeWords(subject_words);
        const subject = if (subject_words.len == 0) "" else subject_words[0].text;

        for (command.arms) |arm| {
            const patterns = try self.expandWords(arm.patterns, options);
            defer self.freeWords(patterns);
            for (patterns) |pattern| {
                if (shellPatternMatches(pattern.text, subject)) {
                    return self.executeScriptSlice(arm.body, options);
                }
            }
        }

        return emptyResult(self.allocator, 0);
    }

    fn executeForCommand(self: *Executor, command: ir.ForCommand, options: ExecuteOptions) !CommandResult {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        const expanded_words = try self.expandArgv(command.words, options);
        defer self.freeWords(expanded_words);

        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);
        var status: ExitStatus = 0;

        for (expanded_words) |word| {
            try self.setEnv(command.name, word.text);
            var body = try self.executeScriptSlice(command.body, options);
            defer body.deinit();
            try stdout.appendSlice(self.allocator, body.stdout);
            try stderr.appendSlice(self.allocator, body.stderr);
            status = body.status;
            if (self.pending_return != null) break;
            if (self.consumeLoopControl()) |control| switch (control) {
                .break_loop => break,
                .continue_loop => continue,
            };
        }

        return .{
            .allocator = self.allocator,
            .status = status,
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
        };
    }

    fn executeLoopCommand(self: *Executor, command: ir.LoopCommand, options: ExecuteOptions) !CommandResult {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);
        var status: ExitStatus = 0;

        while (true) {
            var condition = try self.executeScriptSlice(command.condition, options);
            defer condition.deinit();
            try stdout.appendSlice(self.allocator, condition.stdout);
            try stderr.appendSlice(self.allocator, condition.stderr);

            const run_body = switch (command.kind) {
                .while_loop => condition.status == 0,
                .until_loop => condition.status != 0,
            };
            if (!run_body) {
                status = 0;
                break;
            }

            var body = try self.executeScriptSlice(command.body, options);
            defer body.deinit();
            try stdout.appendSlice(self.allocator, body.stdout);
            try stderr.appendSlice(self.allocator, body.stderr);
            status = body.status;
            if (self.pending_return != null) break;
            if (self.consumeLoopControl()) |control| switch (control) {
                .break_loop => break,
                .continue_loop => continue,
            };
        }

        return .{
            .allocator = self.allocator,
            .status = status,
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
        };
    }

    fn consumeLoopControl(self: *Executor) ?LoopControlKind {
        const control = self.pending_loop_control orelse return null;
        if (control.levels <= 1) {
            self.pending_loop_control = null;
            return control.kind;
        }
        self.pending_loop_control = .{ .kind = control.kind, .levels = control.levels - 1 };
        return .break_loop;
    }

    fn executeIfCommand(self: *Executor, command: ir.IfCommand, options: ExecuteOptions) !CommandResult {
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        errdefer stderr.deinit(self.allocator);

        var condition = try self.executeScriptSlice(command.condition, options);
        defer condition.deinit();
        try stdout.appendSlice(self.allocator, condition.stdout);
        try stderr.appendSlice(self.allocator, condition.stderr);

        var status: ExitStatus = 0;
        if (condition.status == 0) {
            var body = try self.executeScriptSlice(command.then_body, options);
            defer body.deinit();
            try stdout.appendSlice(self.allocator, body.stdout);
            try stderr.appendSlice(self.allocator, body.stderr);
            status = body.status;
        } else if (command.else_body) |else_body| {
            var body = try self.executeElseBody(else_body, options);
            defer body.deinit();
            try stdout.appendSlice(self.allocator, body.stdout);
            try stderr.appendSlice(self.allocator, body.stderr);
            status = body.status;
        } else {
            status = 0;
        }

        return .{
            .allocator = self.allocator,
            .status = status,
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
        };
    }

    fn executeElseBody(self: *Executor, else_body: []const u8, options: ExecuteOptions) !CommandResult {
        const trimmed = trimLeftShellSeparators(else_body);
        if (std.mem.startsWith(u8, trimmed, "elif")) {
            const rest = trimLeftShellWhitespace(trimmed[4..]);
            const script = try std.fmt.allocPrint(self.allocator, "if {s} fi", .{rest});
            defer self.allocator.free(script);
            return self.executeScriptSlice(script, options);
        }
        return self.executeScriptSlice(else_body, options);
    }

    fn trimLeftShellSeparators(text: []const u8) []const u8 {
        var index: usize = 0;
        while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == '\r' or text[index] == '\n' or text[index] == ';')) : (index += 1) {}
        return text[index..];
    }

    fn trimLeftShellWhitespace(text: []const u8) []const u8 {
        var index: usize = 0;
        while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == '\r' or text[index] == '\n')) : (index += 1) {}
        return text[index..];
    }

    fn executeScriptSlice(self: *Executor, script: []const u8, options: ExecuteOptions) !CommandResult {
        const trimmed = std.mem.trim(u8, script, " \t\r\n;");
        if (trimmed.len == 0) return emptyResult(self.allocator, 0);
        var parsed = try parser.parse(self.allocator, trimmed, .{ .features = options.features });
        defer parsed.deinit();
        if (parsed.diagnostics.len != 0) return error.ParseError;
        var program = try ir.lowerSimpleCommands(self.allocator, parsed);
        defer program.deinit();
        return self.executeProgram(program, options);
    }

    fn executePipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) !CommandResult {
        if (self.canExecuteRealPipeline(program, pipeline, options)) {
            const io = options.io orelse return error.MissingIoForExternalCommand;
            return self.executeRealPipeline(program, pipeline, options, io);
        }

        var last = try emptyResult(self.allocator, 0);
        var stdin = try self.allocator.alloc(u8, 0);
        defer self.allocator.free(stdin);
        const statuses = try self.allocator.alloc(ExitStatus, pipeline.command_indexes.len);
        defer self.allocator.free(statuses);

        for (pipeline.command_indexes, 0..) |command_index, index| {
            last.deinit();
            last = try self.executeSimpleCommandWithInput(program.commands[command_index], stdin, options);
            statuses[index] = last.status;

            if (index + 1 < pipeline.command_indexes.len) {
                self.allocator.free(stdin);
                stdin = try self.allocator.dupe(u8, last.stdout);
            }
        }

        last.status = self.pipelineStatus(statuses);
        return last;
    }

    fn pipelineHasRedirections(program: ir.Program, pipeline: ir.Pipeline) bool {
        for (pipeline.command_indexes) |command_index| {
            if (program.commands[command_index].redirections.len != 0) return true;
        }
        return false;
    }

    fn pipelineStatus(self: Executor, statuses: []const ExitStatus) ExitStatus {
        if (statuses.len == 0) return 0;
        if (!self.shell_options.pipefail) return statuses[statuses.len - 1];
        var index = statuses.len;
        while (index > 0) {
            index -= 1;
            if (statuses[index] != 0) return statuses[index];
        }
        return 0;
    }

    fn canExecuteRealPipeline(self: Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) bool {
        _ = self;
        if (!options.allow_external or options.io == null or pipeline.command_indexes.len < 2) return false;
        for (pipeline.command_indexes) |command_index| {
            const command = program.commands[command_index];
            if (command.argv.len == 0) return false;
        }
        return true;
    }

    fn executeRealPipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions, io: std.Io) !CommandResult {
        var has_builtin = false;
        for (pipeline.command_indexes) |command_index| {
            const command = program.commands[command_index];
            if (builtinFor(command.argv[0].text) != null or self.functions.get(command.argv[0].text) != null) {
                has_builtin = true;
                break;
            }
        }
        if (!has_builtin and !pipelineHasRedirections(program, pipeline)) return self.executeExternalPipeline(program, pipeline, io);
        return self.executeMixedPipeline(program, pipeline, options, io);
    }

    const PipelinePipe = struct {
        read: ?std.Io.File,
        write: ?std.Io.File,

        fn close(self: *PipelinePipe, io: std.Io) void {
            if (self.read) |file| file.close(io);
            if (self.write) |file| file.close(io);
            self.* = .{ .read = null, .write = null };
        }
    };

    const BuiltinPipelineContext = struct {
        executor: *Executor,
        command: ir.SimpleCommand,
        options: ExecuteOptions,
        io: std.Io,
        stdin_file: ?std.Io.File,
        stdout_file: ?std.Io.File,
        stderr_file: ?std.Io.File,
        stage_index: usize,
        status: ExitStatus = 0,
        err: ?anyerror = null,
    };

    fn executeMixedPipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions, io: std.Io) !CommandResult {
        const pipe_count = pipeline.command_indexes.len - 1;
        const pipes = try self.allocator.alloc(PipelinePipe, pipe_count);
        defer self.allocator.free(pipes);
        for (pipes) |*pipe| pipe.* = try makePipelinePipe(io);
        defer for (pipes) |*pipe| pipe.close(io);

        var capture_stdout = try makePipelinePipe(io);
        defer capture_stdout.close(io);
        var capture_stderr = try makePipelinePipe(io);
        defer capture_stderr.close(io);

        const children = try self.allocator.alloc(std.process.Child, pipeline.command_indexes.len);
        defer self.allocator.free(children);
        const child_stage_indexes = try self.allocator.alloc(usize, pipeline.command_indexes.len);
        defer self.allocator.free(child_stage_indexes);
        var spawned: usize = 0;
        errdefer for (children[0..spawned]) |*child| child.kill(io);

        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(self.allocator);
        var contexts: std.ArrayList(*BuiltinPipelineContext) = .empty;
        defer contexts.deinit(self.allocator);
        errdefer {
            for (contexts.items) |context| self.allocator.destroy(context);
        }

        for (pipeline.command_indexes, 0..) |command_index, index| {
            const command = program.commands[command_index];
            const is_last = index + 1 == pipeline.command_indexes.len;
            var stdin_file = if (index == 0) null else takeRead(&pipes[index - 1]);
            var stdout_file = if (is_last) takeWrite(&capture_stdout) else takeWrite(&pipes[index]);
            var stderr_file = if (is_last) takeWrite(&capture_stderr) else null;
            try self.applyPipelineStageRedirections(io, command, options, &stdin_file, &stdout_file, &stderr_file);
            const command_without_redirs: ir.SimpleCommand = .{
                .span = command.span,
                .assignments = command.assignments,
                .argv = command.argv,
                .redirections = &.{},
            };

            if (builtinFor(command.argv[0].text) != null or self.functions.get(command.argv[0].text) != null) {
                const context = try self.allocator.create(BuiltinPipelineContext);
                errdefer self.allocator.destroy(context);
                context.* = .{
                    .executor = self,
                    .command = command_without_redirs,
                    .options = options,
                    .io = io,
                    .stdin_file = stdin_file,
                    .stdout_file = stdout_file,
                    .stderr_file = stderr_file,
                    .stage_index = index,
                };
                const thread = try std.Thread.spawn(.{}, runBuiltinPipelineStage, .{context});
                try threads.append(self.allocator, thread);
                try contexts.append(self.allocator, context);
            } else {
                const argv = try argvForCommand(self.allocator, command_without_redirs);
                defer self.allocator.free(argv);
                children[spawned] = try std.process.spawn(io, .{
                    .argv = argv,
                    .stdin = if (stdin_file) |file| .{ .file = file } else .ignore,
                    .stdout = if (stdout_file) |file| .{ .file = file } else .ignore,
                    .stderr = if (stderr_file) |file| .{ .file = file } else .inherit,
                });
                child_stage_indexes[spawned] = index;
                spawned += 1;
                if (stdin_file) |file| file.close(io);
                if (stdout_file) |file| file.close(io);
                if (stderr_file) |file| file.close(io);
            }
        }

        for (pipes) |*pipe| pipe.close(io);
        if (capture_stdout.write) |file| file.close(io);
        capture_stdout.write = null;
        if (capture_stderr.write) |file| file.close(io);
        capture_stderr.write = null;

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(self.allocator, io, multi_reader_buffer.toStreams(), &.{ capture_stdout.read.?, capture_stderr.read.? });
        defer multi_reader.deinit();

        while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }
        try multi_reader.checkAnyError();

        const statuses = try self.allocator.alloc(ExitStatus, pipeline.command_indexes.len);
        defer self.allocator.free(statuses);
        @memset(statuses, 0);
        for (children[0..spawned], child_stage_indexes[0..spawned]) |*child, stage_index| {
            const term = try child.wait(io);
            statuses[stage_index] = exitStatusFromTerm(term);
        }
        for (threads.items) |thread| thread.join();
        for (contexts.items) |context| {
            defer self.allocator.destroy(context);
            if (context.err) |err| return err;
            statuses[context.stage_index] = context.status;
        }

        return .{
            .allocator = self.allocator,
            .status = self.pipelineStatus(statuses),
            .stdout = try multi_reader.toOwnedSlice(0),
            .stderr = try multi_reader.toOwnedSlice(1),
        };
    }

    fn applyPipelineStageRedirections(
        self: *Executor,
        io: std.Io,
        command: ir.SimpleCommand,
        options: ExecuteOptions,
        stdin_file: *?std.Io.File,
        stdout_file: *?std.Io.File,
        stderr_file: *?std.Io.File,
    ) !void {
        const redirections = try self.expandRedirections(command.redirections, options);
        defer self.freeRedirections(redirections);
        for (redirections) |redirection| {
            if (isStdinFileRedirection(redirection)) {
                const target = redirection.target orelse continue;
                if (stdin_file.*) |file| file.close(io);
                stdin_file.* = try std.Io.Dir.cwd().openFile(io, target.text, .{});
                continue;
            }
            if (isFileOutputRedirection(redirection)) {
                const target = redirection.target orelse continue;
                const fd = redirectionFd(redirection) orelse 1;
                const file = try openOutputRedirectionFile(io, target.text, redirection.operator == .dgreat);
                switch (fd) {
                    1 => {
                        if (stdout_file.*) |old| old.close(io);
                        stdout_file.* = file;
                    },
                    2 => {
                        if (stderr_file.*) |old| old.close(io);
                        stderr_file.* = file;
                    },
                    else => file.close(io),
                }
            }
        }
    }

    fn runBuiltinPipelineStage(context: *BuiltinPipelineContext) void {
        runBuiltinPipelineStageFallible(context) catch |err| {
            context.err = err;
            context.status = 2;
        };
    }

    fn runBuiltinPipelineStageFallible(context: *BuiltinPipelineContext) !void {
        defer if (context.stdin_file) |file| file.close(context.io);
        defer if (context.stdout_file) |file| file.close(context.io);
        defer if (context.stderr_file) |file| file.close(context.io);

        var stdin_bytes: []u8 = try context.executor.allocator.alloc(u8, 0);
        defer context.executor.allocator.free(stdin_bytes);
        if (context.stdin_file) |file| {
            context.executor.allocator.free(stdin_bytes);
            var reader_buffer: [4096]u8 = undefined;
            var reader = file.reader(context.io, &reader_buffer);
            stdin_bytes = try reader.interface.allocRemaining(context.executor.allocator, .limited(1024 * 1024));
        }

        var result = try context.executor.executeSimpleCommandWithInput(context.command, stdin_bytes, context.options);
        defer result.deinit();
        context.status = result.status;
        if (context.stdout_file) |file| try writeBytesToFile(context.io, file, result.stdout);
        if (context.stderr_file) |file| try writeBytesToFile(context.io, file, result.stderr);
    }

    fn takeRead(pipe: *PipelinePipe) ?std.Io.File {
        const file = pipe.read;
        pipe.read = null;
        return file;
    }

    fn takeWrite(pipe: *PipelinePipe) ?std.Io.File {
        const file = pipe.write;
        pipe.write = null;
        return file;
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

        const statuses = try self.allocator.alloc(ExitStatus, spawned);
        defer self.allocator.free(statuses);
        for (children[0..spawned], 0..) |*child, index| {
            const term = try child.wait(io);
            statuses[index] = exitStatusFromTerm(term);
        }

        return .{
            .allocator = self.allocator,
            .status = self.pipelineStatus(statuses),
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

        if (self.functions.get(expanded.argv[0].text)) |body| {
            try self.pushCallFrame(expanded.argv[1..]);
            defer self.popCallFrame();
            self.function_depth += 1;
            defer self.function_depth -= 1;
            var result = try self.executeScriptSlice(body, options);
            errdefer result.deinit();
            if (self.pending_return) |status| {
                self.pending_return = null;
                result.status = status;
            }
            return try self.applyOutputRedirections(expanded, result, options);
        }

        if (builtinFor(expanded.argv[0].text)) |builtin| {
            return try self.applyOutputRedirections(expanded, try builtin(self, expanded, effective_stdin, options), options);
        }

        if (!options.allow_external) {
            return try self.applyOutputRedirections(expanded, try errorResult(self.allocator, 127, expanded.argv[0].text, "command not found"), options);
        }

        const io = options.io orelse return error.MissingIoForExternalCommand;
        return try self.applyExternalPostRedirections(expanded, try self.executeExternal(expanded, io), options);
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

    fn readSourceFile(self: *Executor, io: std.Io, name: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            return std.Io.Dir.cwd().readFileAlloc(io, name, self.allocator, .limited(1024 * 1024));
        }

        if (self.getEnv("PATH")) |path_value| {
            var parts = std.mem.splitScalar(u8, path_value, ':');
            while (parts.next()) |dir| {
                const prefix = if (dir.len == 0) "." else dir;
                const candidate = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, name });
                defer self.allocator.free(candidate);
                return std.Io.Dir.cwd().readFileAlloc(io, candidate, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => |e| return e,
                };
            }
        }

        return std.Io.Dir.cwd().readFileAlloc(io, name, self.allocator, .limited(1024 * 1024));
    }

    fn pushCallFrame(self: *Executor, args: []const ir.WordRef) !void {
        var params = try self.allocator.alloc([]const u8, args.len);
        errdefer self.allocator.free(params);
        var initialized: usize = 0;
        errdefer for (params[0..initialized]) |param| self.allocator.free(param);
        for (args, 0..) |arg, index| {
            params[index] = try self.allocator.dupe(u8, arg.text);
            initialized += 1;
        }

        const count = try std.fmt.allocPrint(self.allocator, "{d}", .{args.len});
        errdefer self.allocator.free(count);
        const joined = try joinParams(self.allocator, params);
        errdefer self.allocator.free(joined);

        try self.call_frames.append(self.allocator, .{
            .params = params,
            .count = count,
            .joined = joined,
        });
    }

    fn popCallFrame(self: *Executor) void {
        var frame = self.call_frames.pop().?;
        frame.deinit(self.allocator);
    }

    fn currentCallFrame(self: Executor) ?CallFrame {
        if (self.call_frames.items.len == 0) return null;
        return self.call_frames.items[self.call_frames.items.len - 1];
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
        if (self.currentCallFrame()) |frame| {
            if (std.mem.eql(u8, name, "#")) return frame.count;
            if (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) return frame.joined;
            if (name.len == 1 and std.ascii.isDigit(name[0]) and name[0] != '0') {
                const index = name[0] - '1';
                if (index < frame.params.len) return frame.params[index];
                return "";
            }
        }
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

    fn applyExternalPostRedirections(self: *Executor, command: ir.SimpleCommand, result: CommandResult, options: ExecuteOptions) !CommandResult {
        _ = options;
        var redirected = result;
        errdefer redirected.deinit();
        for (command.redirections) |redirection| {
            if (redirection.operator == .greater_and) {
                try self.applyDescriptorDuplication(&redirected, redirection);
            }
        }
        return redirected;
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

        var stdin_file: ?std.Io.File = null;
        defer if (stdin_file) |file| file.close(io);
        var stdout_file: ?std.Io.File = null;
        defer if (stdout_file) |file| file.close(io);
        var stderr_file: ?std.Io.File = null;
        defer if (stderr_file) |file| file.close(io);

        for (command.redirections) |redirection| {
            if (isStdinFileRedirection(redirection)) {
                const target = redirection.target orelse continue;
                if (stdin_file) |file| file.close(io);
                stdin_file = try std.Io.Dir.cwd().openFile(io, target.text, .{});
                continue;
            }
            if (isFileOutputRedirection(redirection)) {
                const target = redirection.target orelse continue;
                const fd = redirectionFd(redirection) orelse 1;
                var file = try openOutputRedirectionFile(io, target.text, redirection.operator == .dgreat);
                switch (fd) {
                    1 => {
                        if (stdout_file) |old| old.close(io);
                        stdout_file = file;
                    },
                    2 => {
                        if (stderr_file) |old| old.close(io);
                        stderr_file = file;
                    },
                    else => file.close(io),
                }
            }
        }

        const capture_stdout = stdout_file == null;
        const capture_stderr = stderr_file == null;
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = if (stdin_file) |file| .{ .file = file } else .ignore,
            .stdout = if (stdout_file) |file| .{ .file = file } else .pipe,
            .stderr = if (stderr_file) |file| .{ .file = file } else .pipe,
        }) catch |err| switch (err) {
            error.FileNotFound => return errorResult(self.allocator, 127, command.argv[0].text, "command not found"),
            else => return err,
        };
        defer child.kill(io);

        var stdout: []u8 = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(stdout);
        var stderr: []u8 = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(stderr);

        if (capture_stdout and capture_stderr) {
            var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
            var multi_reader: std.Io.File.MultiReader = undefined;
            multi_reader.init(self.allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
            defer multi_reader.deinit();
            while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
                error.EndOfStream => {},
                else => |e| return e,
            }
            try multi_reader.checkAnyError();
            self.allocator.free(stdout);
            self.allocator.free(stderr);
            stdout = try multi_reader.toOwnedSlice(0);
            stderr = try multi_reader.toOwnedSlice(1);
        } else if (capture_stdout) {
            var reader_buffer: [4096]u8 = undefined;
            var reader = child.stdout.?.reader(io, &reader_buffer);
            self.allocator.free(stdout);
            stdout = try reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024));
        } else if (capture_stderr) {
            var reader_buffer: [4096]u8 = undefined;
            var reader = child.stderr.?.reader(io, &reader_buffer);
            self.allocator.free(stderr);
            stderr = try reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024));
        }

        const term = try child.wait(io);
        return .{
            .allocator = self.allocator,
            .status = exitStatusFromTerm(term),
            .stdout = stdout,
            .stderr = stderr,
        };
    }
};

fn makePipelinePipe(io: std.Io) !Executor.PipelinePipe {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .linux => blk: {
            var fds: [2]i32 = undefined;
            const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            break :blk filesFromPipeFds(fds);
        },
        .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => blk: {
            var fds: [2]std.c.fd_t = undefined;
            const rc = std.c.pipe(&fds);
            switch (std.c.errno(rc)) {
                .SUCCESS => {},
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                else => return error.Unexpected,
            }
            errdefer {
                closeRawFd(io, fds[0]);
                closeRawFd(io, fds[1]);
            }
            try setCloseOnExec(fds[0]);
            try setCloseOnExec(fds[1]);
            break :blk filesFromPipeFds(.{ fds[0], fds[1] });
        },
        else => error.Unsupported,
    };
}

fn closeRawFd(io: std.Io, fd: std.posix.fd_t) void {
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    file.close(io);
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    const rc = std.c.fcntl(fd, @as(c_int, std.c.F.SETFD), @as(c_int, std.c.FD_CLOEXEC));
    switch (std.c.errno(rc)) {
        .SUCCESS => {},
        .BADF => return error.FileDescriptorNotASocket,
        .INVAL => return error.Unexpected,
        else => return error.Unexpected,
    }
}

fn filesFromPipeFds(fds: [2]std.posix.fd_t) Executor.PipelinePipe {
    return .{
        .read = .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .write = .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

fn writeBytesToFile(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn openOutputRedirectionFile(io: std.Io, target: []const u8, append: bool) !std.Io.File {
    if (!append) return std.Io.Dir.cwd().createFile(io, target, .{ .truncate = true });
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows, .wasi => std.Io.Dir.cwd().createFile(io, target, .{ .truncate = false }),
        else => blk: {
            const fd = try std.posix.openat(std.Io.Dir.cwd().handle, target, .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .APPEND = true,
                .CLOEXEC = true,
            }, 0o666);
            break :blk .{ .handle = fd, .flags = .{ .nonblocking = false } };
        },
    };
}

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
    if (std.mem.eql(u8, name, ".")) return builtinSource;
    if (std.mem.eql(u8, name, ":")) return builtinTrue;
    if (std.mem.eql(u8, name, "break")) return builtinBreak;
    if (std.mem.eql(u8, name, "true")) return builtinTrue;
    if (std.mem.eql(u8, name, "false")) return builtinFalse;
    if (std.mem.eql(u8, name, "echo")) return builtinEcho;
    if (std.mem.eql(u8, name, "cat")) return builtinCat;
    if (std.mem.eql(u8, name, "continue")) return builtinContinue;
    if (std.mem.eql(u8, name, "cd")) return builtinCd;
    if (std.mem.eql(u8, name, "pwd")) return builtinPwd;
    if (std.mem.eql(u8, name, "return")) return builtinReturn;
    if (std.mem.eql(u8, name, "export")) return builtinExport;
    if (std.mem.eql(u8, name, "unset")) return builtinUnset;
    if (std.mem.eql(u8, name, "env")) return builtinEnv;
    if (std.mem.eql(u8, name, "set")) return builtinSet;
    if (std.mem.eql(u8, name, "source")) return builtinSource;
    if (std.mem.eql(u8, name, "test")) return builtinTest;
    if (std.mem.eql(u8, name, "[")) return builtinTest;
    return null;
}

fn builtinSource(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    const io = options.io orelse return error.MissingIoForBuiltin;
    if (command.argv.len < 2) return errorResult(self.allocator, 2, command.argv[0].text, "missing file operand");
    if (command.argv.len > 2) return errorResult(self.allocator, 2, command.argv[0].text, "arguments are not implemented yet");
    const contents = self.readSourceFile(io, command.argv[1].text) catch |err| switch (err) {
        error.FileNotFound => return errorResult(self.allocator, 1, command.argv[0].text, "file not found"),
        else => |e| return e,
    };
    defer self.allocator.free(contents);
    return self.executeScriptSlice(contents, options);
}

fn builtinBreak(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    return setLoopControlBuiltin(self, command, .break_loop, "break");
}

fn builtinContinue(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    return setLoopControlBuiltin(self, command, .continue_loop, "continue");
}

fn setLoopControlBuiltin(self: *Executor, command: ir.SimpleCommand, kind: LoopControlKind, name: []const u8) !CommandResult {
    if (self.loop_depth == 0) return errorResult(self.allocator, 2, name, "not in a loop");
    if (command.argv.len > 2) return errorResult(self.allocator, 2, name, "too many arguments");
    const levels: usize = if (command.argv.len == 2) blk: {
        const parsed = std.fmt.parseInt(usize, command.argv[1].text, 10) catch return errorResult(self.allocator, 2, name, "numeric argument required");
        if (parsed == 0) return errorResult(self.allocator, 2, name, "loop count must be positive");
        break :blk parsed;
    } else 1;
    self.pending_loop_control = .{ .kind = kind, .levels = levels };
    return emptyResult(self.allocator, 0);
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

fn builtinReturn(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (self.function_depth == 0) return errorResult(self.allocator, 2, "return", "not in a function");
    if (command.argv.len > 2) return errorResult(self.allocator, 2, "return", "too many arguments");
    const status: ExitStatus = if (command.argv.len == 2) blk: {
        const parsed = std.fmt.parseInt(u8, command.argv[1].text, 10) catch return errorResult(self.allocator, 2, "return", "numeric argument required");
        break :blk parsed;
    } else 0;
    self.pending_return = status;
    return emptyResult(self.allocator, status);
}

fn builtinSet(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;

    if (command.argv.len == 1) return printShellOptions(self, false);
    if (command.argv.len == 2 and std.mem.eql(u8, command.argv[1].text, "-o")) return printShellOptions(self, false);
    if (command.argv.len == 2 and std.mem.eql(u8, command.argv[1].text, "+o")) return printShellOptions(self, true);
    if (command.argv.len == 3 and (std.mem.eql(u8, command.argv[1].text, "-o") or std.mem.eql(u8, command.argv[1].text, "+o"))) {
        const enabled = command.argv[1].text[0] == '-';
        if (std.mem.eql(u8, command.argv[2].text, "pipefail")) {
            self.shell_options.pipefail = enabled;
            return emptyResult(self.allocator, 0);
        }
        return errorResult(self.allocator, 2, "set", "unknown option name");
    }
    return errorResult(self.allocator, 2, "set", "unsupported arguments");
}

fn printShellOptions(self: *Executor, reusable: bool) !CommandResult {
    const stdout = if (reusable)
        try std.fmt.allocPrint(self.allocator, "set {s}o pipefail\n", .{if (self.shell_options.pipefail) "-" else "+"})
    else
        try std.fmt.allocPrint(self.allocator, "pipefail\t{s}\n", .{if (self.shell_options.pipefail) "on" else "off"});
    errdefer self.allocator.free(stdout);
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = stdout,
        .stderr = try self.allocator.alloc(u8, 0),
    };
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

fn evalBashTest(allocator: std.mem.Allocator, options: ExecuteOptions, args: []const ir.WordRef) !bool {
    return switch (args.len) {
        0 => false,
        1 => args[0].text.len != 0,
        2 => try evalUnaryTest(allocator, options, args[0].text, args[1].text),
        3 => if (std.mem.eql(u8, args[0].text, "!"))
            !(try evalBashTest(allocator, options, args[1..]))
        else if (std.mem.eql(u8, args[1].text, "==") or std.mem.eql(u8, args[1].text, "="))
            shellPatternMatches(args[2].text, args[0].text)
        else if (std.mem.eql(u8, args[1].text, "!="))
            !shellPatternMatches(args[2].text, args[0].text)
        else
            try evalBinaryTest(args[0].text, args[1].text, args[2].text),
        4 => if (std.mem.eql(u8, args[0].text, "!")) !(try evalBashTest(allocator, options, args[1..])) else error.InvalidTestExpression,
        else => error.InvalidTestExpression,
    };
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

fn joinParams(allocator: std.mem.Allocator, params: []const []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (params, 0..) |param, index| {
        if (index > 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, param);
    }
    return joined.toOwnedSlice(allocator);
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

fn shellPatternMatches(pattern: []const u8, text: []const u8) bool {
    return shellPatternMatchesFrom(pattern, text, 0, 0);
}

fn shellPatternMatchesFrom(pattern: []const u8, text: []const u8, pattern_index: usize, text_index: usize) bool {
    if (pattern_index == pattern.len) return text_index == text.len;
    if (pattern[pattern_index] == '*') {
        var next_text = text_index;
        while (next_text <= text.len) : (next_text += 1) {
            if (shellPatternMatchesFrom(pattern, text, pattern_index + 1, next_text)) return true;
        }
        return false;
    }
    if (text_index >= text.len) return false;
    if (pattern[pattern_index] == '?' or pattern[pattern_index] == text[text_index]) {
        return shellPatternMatchesFrom(pattern, text, pattern_index + 1, text_index + 1);
    }
    return false;
}

fn exitStatusFromTerm(term: std.process.Child.Term) ExitStatus {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .stopped => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .unknown => 1,
    };
}

const LoweredForTest = struct { parsed: parser.ParseResult, program: ir.Program };

fn parseAndLower(allocator: std.mem.Allocator, source: []const u8) !LoweredForTest {
    return parseAndLowerWithOptions(allocator, source, .{});
}

fn parseAndLowerWithOptions(allocator: std.mem.Allocator, source: []const u8, options: parser.ParseOptions) !LoweredForTest {
    var parsed = try parser.parse(allocator, source, options);
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

test "executor executes Bash conditional command baseline" {
    var pattern = try parseAndLowerWithOptions(std.testing.allocator, "[[ foobar == foo* ]]", .{ .features = compat.Features.bash() });
    defer pattern.parsed.deinit();
    defer pattern.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var pattern_result = try executor.executeProgram(pattern.program, .{});
    defer pattern_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), pattern_result.status);

    var string_false = try parseAndLowerWithOptions(std.testing.allocator, "[[ foo == bar ]]", .{ .features = compat.Features.bash() });
    defer string_false.parsed.deinit();
    defer string_false.program.deinit();
    var string_false_result = try executor.executeProgram(string_false.program, .{});
    defer string_false_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), string_false_result.status);

    var integer = try parseAndLowerWithOptions(std.testing.allocator, "[[ 5 -gt 3 ]]", .{ .features = compat.Features.bash() });
    defer integer.parsed.deinit();
    defer integer.program.deinit();
    var integer_result = try executor.executeProgram(integer.program, .{});
    defer integer_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), integer_result.status);

    var parameter = try parseAndLowerWithOptions(std.testing.allocator, "FOO=bar; [[ $FOO == b* ]]", .{ .features = compat.Features.bash() });
    defer parameter.parsed.deinit();
    defer parameter.program.deinit();
    var parameter_result = try executor.executeProgram(parameter.program, .{});
    defer parameter_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), parameter_result.status);
}

test "executor executes POSIX subshells with isolated state" {
    var lowered = try parseAndLower(std.testing.allocator, "FOO=outer; ( FOO=inner; echo $FOO; f; ); echo $FOO; f");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setFunction("f", "echo outer-f");

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("inner\nouter-f\nouter\nouter-f\n", result.stdout);

    const path = "rush-subshell-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var redirected = try parseAndLower(std.testing.allocator, "( echo one; echo two ) > rush-subshell-redirection.tmp");
    defer redirected.parsed.deinit();
    defer redirected.program.deinit();
    var redirected_result = try executor.executeProgram(redirected.program, .{ .io = std.testing.io });
    defer redirected_result.deinit();
    try std.testing.expectEqualStrings("", redirected_result.stdout);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}

test "executor executes POSIX brace groups in current shell" {
    var lowered = try parseAndLower(std.testing.allocator, "{ FOO=bar; echo $FOO; }; echo $FOO");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("bar\nbar\n", result.stdout);

    const path = "rush-brace-group-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var redirected = try parseAndLower(std.testing.allocator, "{ echo one; echo two; } > rush-brace-group-redirection.tmp");
    defer redirected.parsed.deinit();
    defer redirected.program.deinit();
    var redirected_result = try executor.executeProgram(redirected.program, .{ .io = std.testing.io });
    defer redirected_result.deinit();
    try std.testing.expectEqualStrings("", redirected_result.stdout);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}

test "executor implements source and dot builtins" {
    const path = "rush-source-test.sh";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "FOO=sourced\nf() { echo from-source; }\n" });

    var lowered = try parseAndLower(std.testing.allocator, ". ./rush-source-test.sh; echo $FOO; f");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("sourced\nfrom-source\n", result.stdout);

    try executor.setEnv("PATH", ".");
    var source_lowered = try parseAndLower(std.testing.allocator, "source rush-source-test.sh; f");
    defer source_lowered.parsed.deinit();
    defer source_lowered.program.deinit();
    var source_result = try executor.executeProgram(source_lowered.program, .{ .io = std.testing.io });
    defer source_result.deinit();
    try std.testing.expectEqualStrings("from-source\n", source_result.stdout);
}

test "executor supports break and continue builtins in loops" {
    var break_lowered = try parseAndLower(std.testing.allocator, "for x in a b; do echo $x; break; done");
    defer break_lowered.parsed.deinit();
    defer break_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var break_result = try executor.executeProgram(break_lowered.program, .{});
    defer break_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), break_result.status);
    try std.testing.expectEqualStrings("a\n", break_result.stdout);

    var continue_lowered = try parseAndLower(std.testing.allocator, "for x in a b; do continue; echo nope; done");
    defer continue_lowered.parsed.deinit();
    defer continue_lowered.program.deinit();
    var continue_result = try executor.executeProgram(continue_lowered.program, .{});
    defer continue_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), continue_result.status);
    try std.testing.expectEqualStrings("", continue_result.stdout);

    var outside = try parseAndLower(std.testing.allocator, "break");
    defer outside.parsed.deinit();
    defer outside.program.deinit();
    var outside_result = try executor.executeProgram(outside.program, .{});
    defer outside_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 2), outside_result.status);
    try std.testing.expect(std.mem.indexOf(u8, outside_result.stderr, "not in a loop") != null);
}

test "executor supports return builtin in shell functions" {
    var returned = try parseAndLower(std.testing.allocator, "f() { echo before; return 7; echo after; }; f");
    defer returned.parsed.deinit();
    defer returned.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(returned.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("before\n", result.stdout);

    var continues = try parseAndLower(std.testing.allocator, "f() { return 3; }; f; echo after");
    defer continues.parsed.deinit();
    defer continues.program.deinit();
    var continues_result = try executor.executeProgram(continues.program, .{});
    defer continues_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), continues_result.status);
    try std.testing.expectEqualStrings("after\n", continues_result.stdout);

    var outside = try parseAndLower(std.testing.allocator, "return 4");
    defer outside.parsed.deinit();
    defer outside.program.deinit();
    var outside_result = try executor.executeProgram(outside.program, .{});
    defer outside_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 2), outside_result.status);
    try std.testing.expect(std.mem.indexOf(u8, outside_result.stderr, "not in a function") != null);
}

test "executor provides positional parameters to shell functions" {
    var lowered = try parseAndLower(std.testing.allocator, "show() { echo $1/$2/$#/$@/$*; }; show one two");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("one/two/2/one two/one two\n", result.stdout);

    var nested = try parseAndLower(std.testing.allocator, "inner() { echo $1/$#; }; outer() { inner nested; echo $1/$#; }; outer caller arg2");
    defer nested.parsed.deinit();
    defer nested.program.deinit();
    var nested_result = try executor.executeProgram(nested.program, .{});
    defer nested_result.deinit();
    try std.testing.expectEqualStrings("nested/1\ncaller/2\n", nested_result.stdout);
}

test "executor parses and executes POSIX shell functions" {
    var lowered = try parseAndLower(std.testing.allocator, "greet() { echo hi; }; greet");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hi\n", result.stdout);

    var redefine = try parseAndLower(std.testing.allocator, "greet() { echo one; }; greet() { echo two; }; greet");
    defer redefine.parsed.deinit();
    defer redefine.program.deinit();

    var redefine_result = try executor.executeProgram(redefine.program, .{});
    defer redefine_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), redefine_result.status);
    try std.testing.expectEqualStrings("two\n", redefine_result.stdout);
}

test "executor executes POSIX case statements" {
    var lowered = try parseAndLower(std.testing.allocator, "case foo in bar) echo no ;; f*) echo yes ;; *) echo fallback ;; esac");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("yes\n", result.stdout);

    var fallback_lowered = try parseAndLower(std.testing.allocator, "case z in a) echo a ;; ?) echo one ;; *) echo many ;; esac");
    defer fallback_lowered.parsed.deinit();
    defer fallback_lowered.program.deinit();

    var fallback = try executor.executeProgram(fallback_lowered.program, .{});
    defer fallback.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), fallback.status);
    try std.testing.expectEqualStrings("one\n", fallback.stdout);
}

test "executor executes POSIX for loops" {
    var lowered = try parseAndLower(std.testing.allocator, "for x in a b; do echo $x; done");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\nb\n", result.stdout);

    var split_lowered = try parseAndLower(std.testing.allocator, "WORDS='c d'; for x in $WORDS; do echo $x; done");
    defer split_lowered.parsed.deinit();
    defer split_lowered.program.deinit();

    var split_result = try executor.executeProgram(split_lowered.program, .{});
    defer split_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), split_result.status);
    try std.testing.expectEqualStrings("c\nd\n", split_result.stdout);
}

test "executor executes POSIX while and until loops" {
    var while_lowered = try parseAndLower(std.testing.allocator, "while false; do echo no; done");
    defer while_lowered.parsed.deinit();
    defer while_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var while_result = try executor.executeProgram(while_lowered.program, .{});
    defer while_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), while_result.status);
    try std.testing.expectEqualStrings("", while_result.stdout);

    var until_lowered = try parseAndLower(std.testing.allocator, "until true; do echo no; done");
    defer until_lowered.parsed.deinit();
    defer until_lowered.program.deinit();

    var until_result = try executor.executeProgram(until_lowered.program, .{});
    defer until_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), until_result.status);
    try std.testing.expectEqualStrings("", until_result.stdout);

    var break_lowered = try parseAndLower(std.testing.allocator, "while true; do echo once; break; done");
    defer break_lowered.parsed.deinit();
    defer break_lowered.program.deinit();

    var break_result = try executor.executeProgram(break_lowered.program, .{});
    defer break_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), break_result.status);
    try std.testing.expectEqualStrings("once\n", break_result.stdout);
}

test "executor executes POSIX if compound commands" {
    var true_lowered = try parseAndLower(std.testing.allocator, "if true; then echo yes; else echo no; fi");
    defer true_lowered.parsed.deinit();
    defer true_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var true_result = try executor.executeProgram(true_lowered.program, .{});
    defer true_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), true_result.status);
    try std.testing.expectEqualStrings("yes\n", true_result.stdout);

    var false_lowered = try parseAndLower(std.testing.allocator, "if false; then echo yes; else echo no; fi");
    defer false_lowered.parsed.deinit();
    defer false_lowered.program.deinit();

    var false_result = try executor.executeProgram(false_lowered.program, .{});
    defer false_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), false_result.status);
    try std.testing.expectEqualStrings("no\n", false_result.stdout);

    var elif_lowered = try parseAndLower(std.testing.allocator, "if false; then echo no; elif true; then echo elif; else echo else; fi");
    defer elif_lowered.parsed.deinit();
    defer elif_lowered.program.deinit();

    var elif_result = try executor.executeProgram(elif_lowered.program, .{});
    defer elif_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), elif_result.status);
    try std.testing.expectEqualStrings("elif\n", elif_result.stdout);
}

test "executor expands nested command substitutions and arithmetic inside them" {
    var nested = try parseAndLower(std.testing.allocator, "echo $(echo $(echo hi))");
    defer nested.parsed.deinit();
    defer nested.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var nested_result = try executor.executeProgram(nested.program, .{});
    defer nested_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), nested_result.status);
    try std.testing.expectEqualStrings("hi\n", nested_result.stdout);

    var arithmetic = try parseAndLower(std.testing.allocator, "echo $(echo $((1 + 2)))");
    defer arithmetic.parsed.deinit();
    defer arithmetic.program.deinit();

    var arithmetic_result = try executor.executeProgram(arithmetic.program, .{});
    defer arithmetic_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), arithmetic_result.status);
    try std.testing.expectEqualStrings("3\n", arithmetic_result.stdout);
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

test "executor applies real redirections to spawned external commands" {
    const stdout_path = "rush-external-stdout-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, stdout_path) catch {};
    var stdout_lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf external > rush-external-stdout-redirection.tmp");
    defer stdout_lowered.parsed.deinit();
    defer stdout_lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var stdout_result = try executor.executeProgram(stdout_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer stdout_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), stdout_result.status);
    try std.testing.expectEqualStrings("", stdout_result.stdout);
    const stdout_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stdout_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(stdout_contents);
    try std.testing.expectEqualStrings("external", stdout_contents);

    const append_path = "rush-external-append-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, append_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = append_path, .data = "one\n" });
    var append_lowered = try parseAndLower(std.testing.allocator, "/usr/bin/printf two >> rush-external-append-redirection.tmp");
    defer append_lowered.parsed.deinit();
    defer append_lowered.program.deinit();
    var append_result = try executor.executeProgram(append_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer append_result.deinit();
    const append_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, append_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(append_contents);
    try std.testing.expectEqualStrings("one\ntwo", append_contents);

    const stderr_path = "rush-external-stderr-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, stderr_path) catch {};
    var stderr_lowered = try parseAndLower(std.testing.allocator, "/bin/sh -c 'echo err >&2' 2> rush-external-stderr-redirection.tmp");
    defer stderr_lowered.parsed.deinit();
    defer stderr_lowered.program.deinit();
    var stderr_result = try executor.executeProgram(stderr_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer stderr_result.deinit();
    try std.testing.expectEqualStrings("", stderr_result.stderr);
    const stderr_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(stderr_contents);
    try std.testing.expectEqualStrings("err\n", stderr_contents);

    const stdin_path = "rush-external-stdin-redirection.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, stdin_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = stdin_path, .data = "from-file" });
    var stdin_lowered = try parseAndLower(std.testing.allocator, "/usr/bin/cat < rush-external-stdin-redirection.tmp");
    defer stdin_lowered.parsed.deinit();
    defer stdin_lowered.program.deinit();
    var stdin_result = try executor.executeProgram(stdin_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer stdin_result.deinit();
    try std.testing.expectEqualStrings("from-file", stdin_result.stdout);
}

test "executor implements set shell option baseline" {
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var show_lowered = try parseAndLower(std.testing.allocator, "set -o");
    defer show_lowered.parsed.deinit();
    defer show_lowered.program.deinit();
    var show = try executor.executeProgram(show_lowered.program, .{});
    defer show.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), show.status);
    try std.testing.expectEqualStrings("pipefail\toff\n", show.stdout);

    var enable_lowered = try parseAndLower(std.testing.allocator, "set -o pipefail; false | true");
    defer enable_lowered.parsed.deinit();
    defer enable_lowered.program.deinit();
    var enabled = try executor.executeProgram(enable_lowered.program, .{});
    defer enabled.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), enabled.status);
    try std.testing.expect(executor.shell_options.pipefail);

    var reusable_lowered = try parseAndLower(std.testing.allocator, "set +o");
    defer reusable_lowered.parsed.deinit();
    defer reusable_lowered.program.deinit();
    var reusable = try executor.executeProgram(reusable_lowered.program, .{});
    defer reusable.deinit();
    try std.testing.expectEqualStrings("set -o pipefail\n", reusable.stdout);

    var disable_lowered = try parseAndLower(std.testing.allocator, "set +o pipefail; false | true");
    defer disable_lowered.parsed.deinit();
    defer disable_lowered.program.deinit();
    var disabled = try executor.executeProgram(disable_lowered.program, .{});
    defer disabled.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), disabled.status);
    try std.testing.expect(!executor.shell_options.pipefail);
}

test "executor applies pipefail option to pipeline status" {
    var internal = try parseAndLower(std.testing.allocator, "false | true");
    defer internal.parsed.deinit();
    defer internal.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var default_result = try executor.executeProgram(internal.program, .{});
    defer default_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), default_result.status);

    executor.shell_options.pipefail = true;
    var pipefail_result = try executor.executeProgram(internal.program, .{});
    defer pipefail_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), pipefail_result.status);

    var external = try parseAndLower(std.testing.allocator, "/bin/sh -c 'exit 3' | /usr/bin/true");
    defer external.parsed.deinit();
    defer external.program.deinit();
    var external_result = try executor.executeProgram(external.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 3), external_result.status);

    var mixed = try parseAndLower(std.testing.allocator, "false | /usr/bin/true");
    defer mixed.parsed.deinit();
    defer mixed.program.deinit();
    var mixed_result = try executor.executeProgram(mixed.program, .{ .io = std.testing.io, .allow_external = true });
    defer mixed_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), mixed_result.status);
}

test "executor supports real redirections on pipeline stages" {
    const first_path = "rush-pipeline-stage-first.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, first_path) catch {};
    var first = try parseAndLower(std.testing.allocator, "echo hidden > rush-pipeline-stage-first.tmp | cat");
    defer first.parsed.deinit();
    defer first.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var first_result = try executor.executeProgram(first.program, .{ .io = std.testing.io, .allow_external = true });
    defer first_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), first_result.status);
    try std.testing.expectEqualStrings("", first_result.stdout);
    const first_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, first_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(first_contents);
    try std.testing.expectEqualStrings("hidden\n", first_contents);

    const last_path = "rush-pipeline-stage-last.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, last_path) catch {};
    var last = try parseAndLower(std.testing.allocator, "/usr/bin/printf visible | cat > rush-pipeline-stage-last.tmp");
    defer last.parsed.deinit();
    defer last.program.deinit();
    var last_result = try executor.executeProgram(last.program, .{ .io = std.testing.io, .allow_external = true });
    defer last_result.deinit();
    try std.testing.expectEqualStrings("", last_result.stdout);
    const last_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, last_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(last_contents);
    try std.testing.expectEqualStrings("visible", last_contents);

    const input_path = "rush-pipeline-stage-input.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = input_path, .data = "from-input" });
    var input = try parseAndLower(std.testing.allocator, "cat < rush-pipeline-stage-input.tmp | /usr/bin/cat");
    defer input.parsed.deinit();
    defer input.program.deinit();
    var input_result = try executor.executeProgram(input.program, .{ .io = std.testing.io, .allow_external = true });
    defer input_result.deinit();
    try std.testing.expectEqualStrings("from-input", input_result.stdout);
}

test "executor supports mixed builtin and external pipeline stages" {
    var builtin_to_external = try parseAndLower(std.testing.allocator, "echo hello | /usr/bin/cat");
    defer builtin_to_external.parsed.deinit();
    defer builtin_to_external.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var builtin_to_external_result = try executor.executeProgram(builtin_to_external.program, .{ .io = std.testing.io, .allow_external = true });
    defer builtin_to_external_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), builtin_to_external_result.status);
    try std.testing.expectEqualStrings("hello\n", builtin_to_external_result.stdout);

    var external_to_builtin = try parseAndLower(std.testing.allocator, "/usr/bin/printf hello | cat");
    defer external_to_builtin.parsed.deinit();
    defer external_to_builtin.program.deinit();

    var external_to_builtin_result = try executor.executeProgram(external_to_builtin.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_to_builtin_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), external_to_builtin_result.status);
    try std.testing.expectEqualStrings("hello", external_to_builtin_result.stdout);

    var external_status = try parseAndLower(std.testing.allocator, "true | /bin/sh -c 'exit 7'");
    defer external_status.parsed.deinit();
    defer external_status.program.deinit();

    var external_status_result = try executor.executeProgram(external_status.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_status_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 7), external_status_result.status);

    var builtin_status = try parseAndLower(std.testing.allocator, "/usr/bin/printf hello | false");
    defer builtin_status.parsed.deinit();
    defer builtin_status.program.deinit();

    var builtin_status_result = try executor.executeProgram(builtin_status.program, .{ .io = std.testing.io, .allow_external = true });
    defer builtin_status_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), builtin_status_result.status);
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
