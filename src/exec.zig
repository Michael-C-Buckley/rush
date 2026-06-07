//! Minimal command execution for lowered shell IR.

const std = @import("std");
const zig_builtin = @import("builtin");
const compat = @import("compat.zig");
const expand = @import("expand.zig");
const ir = @import("ir.zig");
const parser = @import("parser.zig");

pub const ExitStatus = u8;

pub const ExternalStdio = enum {
    capture,
    inherit,
};

pub const ExecuteOptions = struct {
    io: ?std.Io = null,
    allow_external: bool = false,
    features: compat.Features = .{},
    external_stdio: ExternalStdio = .capture,
    arg_zero: []const u8 = "rush",
    suppress_functions: bool = false,
    suppress_errexit: bool = false,
};

pub const ShellOptions = struct {
    pipefail: bool = false,
    noglob: bool = false,
    noclobber: bool = false,
    nounset: bool = false,
    errexit: bool = false,
    xtrace: bool = false,
    verbose: bool = false,
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

pub const PositionalParams = struct {
    params: [][]const u8 = &.{},
    count: []const u8 = "0",
    joined: []const u8 = "",
    owned: bool = false,

    pub fn set(self: *PositionalParams, allocator: std.mem.Allocator, args: []const []const u8) !void {
        self.deinit(allocator);
        var params = try allocator.alloc([]const u8, args.len);
        errdefer allocator.free(params);
        var initialized: usize = 0;
        errdefer for (params[0..initialized]) |param| allocator.free(param);
        for (args, 0..) |arg, index| {
            params[index] = try allocator.dupe(u8, arg);
            initialized += 1;
        }
        const count = try std.fmt.allocPrint(allocator, "{d}", .{args.len});
        errdefer allocator.free(count);
        const joined = try joinParams(allocator, params);
        errdefer allocator.free(joined);
        self.* = .{ .params = params, .count = count, .joined = joined, .owned = true };
    }

    pub fn rebuildDerived(self: *PositionalParams, allocator: std.mem.Allocator) !void {
        if (self.owned) {
            allocator.free(self.count);
            allocator.free(self.joined);
        }
        self.count = try std.fmt.allocPrint(allocator, "{d}", .{self.params.len});
        self.joined = try joinParams(allocator, self.params);
        self.owned = true;
    }

    pub fn deinit(self: *PositionalParams, allocator: std.mem.Allocator) void {
        if (self.owned) {
            for (self.params) |param| allocator.free(param);
            allocator.free(self.params);
            allocator.free(self.count);
            allocator.free(self.joined);
        }
        self.* = .{};
    }
};

pub const CallFrame = struct {
    positionals: PositionalParams = .{},

    pub fn deinit(self: *CallFrame, allocator: std.mem.Allocator) void {
        self.positionals.deinit(allocator);
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
    readonly: std.StringHashMapUnmanaged(void) = .empty,
    arrays: std.StringHashMapUnmanaged(ArrayValue) = .empty,
    functions: std.StringHashMapUnmanaged([]const u8) = .empty,
    shell_options: ShellOptions = .{},
    global_positionals: PositionalParams = .{},
    call_frames: std.ArrayList(CallFrame) = .empty,
    function_depth: usize = 0,
    pending_return: ?ExitStatus = null,
    loop_depth: usize = 0,
    pending_loop_control: ?LoopControl = null,
    pending_exit: ?ExitStatus = null,
    arg_zero: []const u8 = "rush",
    last_status_text: [3]u8 = .{ '0', 0, 0 },
    last_status_text_len: usize = 1,
    pid_text: [32]u8 = undefined,
    pid_text_len: usize = 0,
    last_background_pid_text: [32]u8 = undefined,
    last_background_pid_text_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Executor {
        var executor: Executor = .{ .allocator = allocator };
        executor.setLastStatus(0);
        executor.setPidText();
        return executor;
    }

    pub fn importEnvironment(self: *Executor, environ_map: *const std.process.Environ.Map) !void {
        var iter = environ_map.iterator();
        while (iter.next()) |entry| {
            try self.setEnv(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    pub fn setLastStatus(self: *Executor, status: ExitStatus) void {
        const text = std.fmt.bufPrint(&self.last_status_text, "{d}", .{status}) catch unreachable;
        self.last_status_text_len = text.len;
    }

    fn setPidText(self: *Executor) void {
        const pid = shellPid();
        const text = std.fmt.bufPrint(&self.pid_text, "{d}", .{pid}) catch unreachable;
        self.pid_text_len = text.len;
    }

    pub fn deinit(self: *Executor) void {
        var iter = self.env.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.deinit(self.allocator);
        var readonly_iter = self.readonly.iterator();
        while (readonly_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.readonly.deinit(self.allocator);
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
        self.global_positionals.deinit(self.allocator);
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
        if (self.isReadonly(name)) return;
        if (self.env.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    pub fn isReadonly(self: Executor, name: []const u8) bool {
        return self.readonly.contains(name);
    }

    pub fn setReadonly(self: *Executor, name: []const u8) !void {
        if (self.readonly.contains(name)) return;
        try self.readonly.put(self.allocator, try self.allocator.dupe(u8, name), {});
    }

    pub fn setEnv(self: *Executor, name: []const u8, value: []const u8) !void {
        if (self.isReadonly(name)) return error.ReadonlyVariable;
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

    pub fn executeProgram(self: *Executor, program: ir.Program, options: ExecuteOptions) anyerror!CommandResult {
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
                try self.appendOrWriteResult(options, &stdout, &stderr, result);
                last_status = result.status;
                self.setLastStatus(last_status);
                self.applyErrexit(last_status, options, statement.op_before);
                if (self.pending_exit != null or self.pending_return != null or self.pending_loop_control != null) break;
            }
            return .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) };
        }

        if (program.pipelines.len > 0) {
            for (program.pipelines) |pipeline| {
                if (shouldSkipPipeline(pipeline.op_before, last_status)) continue;
                var result = try self.executePipeline(program, pipeline, options);
                defer result.deinit();
                try self.appendOrWriteResult(options, &stdout, &stderr, result);
                last_status = result.status;
                self.setLastStatus(last_status);
                self.applyErrexit(last_status, options, pipeline.op_before);
                if (self.pending_exit != null or self.pending_return != null or self.pending_loop_control != null) break;
            }
            return .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) };
        }

        for (program.commands) |command| {
            var result = try self.executeSimpleCommand(command, options);
            defer result.deinit();
            try self.appendOrWriteResult(options, &stdout, &stderr, result);
            last_status = result.status;
            self.setLastStatus(last_status);
            self.applyErrexit(last_status, options, .sequence);
            if (self.pending_exit != null or self.pending_return != null or self.pending_loop_control != null) break;
        }
        return .{ .allocator = self.allocator, .status = last_status, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try stderr.toOwnedSlice(self.allocator) };
    }

    fn applyErrexit(self: *Executor, status: ExitStatus, options: ExecuteOptions, op_before: ir.ListOp) void {
        if (!self.shell_options.errexit or options.suppress_errexit or status == 0) return;
        if (op_before == .or_if or op_before == .and_if) return;
        self.pending_exit = status;
    }

    fn appendOrWriteResult(self: *Executor, options: ExecuteOptions, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), result: CommandResult) !void {
        if (options.external_stdio == .inherit) {
            if (options.io) |io| {
                try writeInheritedResult(io, result);
                return;
            }
        }
        try stdout.appendSlice(self.allocator, result.stdout);
        try stderr.appendSlice(self.allocator, result.stderr);
    }

    fn executeSubshell(self: *Executor, subshell: ir.Subshell, options: ExecuteOptions) !CommandResult {
        var child = Executor.init(self.allocator);
        defer child.deinit();
        try child.copyStateFrom(self);
        const redirections = try self.expandRedirections(subshell.redirections, options);
        defer self.freeRedirections(redirections);
        const wrapper: ir.SimpleCommand = .{
            .span = subshell.span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = redirections,
        };
        if (self.applyRealFdRedirectionsIfNeeded(wrapper, options) catch |err| switch (err) {
            error.PathAlreadyExists => return errorResult(self.allocator, 1, noclobberTargetName(wrapper), "cannot overwrite existing file"),
            else => return err,
        }) |guard_value| {
            var guard = guard_value;
            defer guard.restore(options.io.?);
            var result = try child.executeScriptSlice(subshell.body, options);
            defer result.deinit();
            try writeInheritedResult(options.io.?, result);
            return emptyResult(self.allocator, result.status);
        }
        var result = try child.executeScriptSlice(subshell.body, options);
        errdefer result.deinit();
        return self.applyOutputRedirections(wrapper, result, options);
    }

    fn executeBraceGroup(self: *Executor, group: ir.BraceGroup, options: ExecuteOptions) !CommandResult {
        const redirections = try self.expandRedirections(group.redirections, options);
        defer self.freeRedirections(redirections);
        const wrapper: ir.SimpleCommand = .{
            .span = group.span,
            .assignments = &.{},
            .argv = &.{},
            .redirections = redirections,
        };
        if (self.applyRealFdRedirectionsIfNeeded(wrapper, options) catch |err| switch (err) {
            error.PathAlreadyExists => return errorResult(self.allocator, 1, noclobberTargetName(wrapper), "cannot overwrite existing file"),
            else => return err,
        }) |guard_value| {
            var guard = guard_value;
            defer guard.restore(options.io.?);
            var result = try self.executeScriptSlice(group.body, options);
            defer result.deinit();
            try writeInheritedResult(options.io.?, result);
            return emptyResult(self.allocator, result.status);
        }
        var result = try self.executeScriptSlice(group.body, options);
        errdefer result.deinit();
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
        var readonly_iter = other.readonly.iterator();
        while (readonly_iter.next()) |entry| try self.setReadonly(entry.key_ptr.*);
        var function_iter = other.functions.iterator();
        while (function_iter.next()) |entry| try self.setFunction(entry.key_ptr.*, entry.value_ptr.*);
        var array_iter = other.arrays.iterator();
        while (array_iter.next()) |entry| {
            for (entry.value_ptr.values.items, 0..) |value, index| {
                try self.setArrayElement(entry.key_ptr.*, index, value);
            }
        }
        try self.global_positionals.set(self.allocator, other.global_positionals.params);
        for (other.call_frames.items) |frame| {
            var copied: CallFrame = .{};
            errdefer copied.deinit(self.allocator);
            try copied.positionals.set(self.allocator, frame.positionals.params);
            try self.call_frames.append(self.allocator, copied);
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
            var condition_options = options;
            condition_options.suppress_errexit = true;
            var condition = try self.executeScriptSlice(command.condition, condition_options);
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

        var condition_options = options;
        condition_options.suppress_errexit = true;
        var condition = try self.executeScriptSlice(command.condition, condition_options);
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

    fn executeScriptSlice(self: *Executor, script: []const u8, options: ExecuteOptions) anyerror!CommandResult {
        const trimmed = std.mem.trim(u8, script, " \t\r\n;");
        if (trimmed.len == 0) return emptyResult(self.allocator, 0);
        var parsed = try parser.parse(self.allocator, trimmed, .{ .features = options.features });
        defer parsed.deinit();
        if (parsed.diagnostics.len != 0) return error.ParseError;
        var program = try ir.lowerSimpleCommands(self.allocator, parsed);
        defer program.deinit();
        var result = try self.executeProgram(program, options);
        errdefer result.deinit();
        if (self.shell_options.verbose and !options.suppress_errexit) {
            const stderr = try std.mem.concat(self.allocator, u8, &.{ trimmed, "\n", result.stderr });
            self.allocator.free(result.stderr);
            result.stderr = stderr;
        }
        return result;
    }

    fn executePipeline(self: *Executor, program: ir.Program, pipeline: ir.Pipeline, options: ExecuteOptions) anyerror!CommandResult {
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
                var child_env = try self.buildProcessEnv(command.assignments);
                defer child_env.deinit();
                children[spawned] = std.process.spawn(io, .{
                    .argv = argv,
                    .environ_map = &child_env,
                    .stdin = if (stdin_file) |file| .{ .file = file } else .ignore,
                    .stdout = if (stdout_file) |file| .{ .file = file } else .ignore,
                    .stderr = if (stderr_file) |file| .{ .file = file } else .inherit,
                }) catch |err| switch (err) {
                    error.FileNotFound => {
                        if (stdin_file) |file| file.close(io);
                        if (stdout_file) |file| file.close(io);
                        if (stderr_file) |file| file.close(io);
                        for (pipes) |*pipe| pipe.close(io);
                        capture_stdout.close(io);
                        capture_stderr.close(io);
                        return self.pipelineSpawnFailureResult(io, command.argv[0].text, children[0..spawned], &threads, contexts.items);
                    },
                    else => return err,
                };
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

    fn pipelineSpawnFailureResult(self: *Executor, io: std.Io, name: []const u8, children: []std.process.Child, threads: *std.ArrayList(std.Thread), contexts: []const *BuiltinPipelineContext) !CommandResult {
        for (children) |*child| child.kill(io);
        for (threads.items) |thread| thread.join();
        for (contexts) |context| self.allocator.destroy(context);
        threads.clearRetainingCapacity();
        return errorResult(self.allocator, 127, name, "command not found");
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
            if (isHereDocRedirection(redirection)) {
                if (stdin_file.*) |file| file.close(io);
                stdin_file.* = try fileFromBytes(io, redirection.here_doc orelse "");
                continue;
            }
            if (isStdinFileRedirection(redirection)) {
                const target = redirection.target orelse continue;
                if (stdin_file.*) |file| file.close(io);
                stdin_file.* = try std.Io.Dir.cwd().openFile(io, target.text, .{});
                continue;
            }
            if (isFileOutputRedirection(redirection)) {
                const target = redirection.target orelse continue;
                const fd = redirectionFd(redirection) orelse 1;
                const file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
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
            var child_env = try self.buildProcessEnv(command.assignments);
            defer child_env.deinit();

            const is_last = index + 1 == pipeline.command_indexes.len;
            children[index] = std.process.spawn(io, .{
                .argv = argv,
                .environ_map = &child_env,
                .stdin = if (previous_stdout) |file| .{ .file = file } else .ignore,
                .stdout = .pipe,
                .stderr = if (is_last) .pipe else .inherit,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    const open_stdin = previous_stdout;
                    previous_stdout = null;
                    return self.externalPipelineSpawnFailureResult(io, command.argv[0].text, children[0..spawned], open_stdin);
                },
                else => return err,
            };
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

    fn externalPipelineSpawnFailureResult(self: *Executor, io: std.Io, name: []const u8, children: []std.process.Child, previous_stdout: ?std.Io.File) !CommandResult {
        if (previous_stdout) |file| file.close(io);
        for (children) |*child| child.kill(io);
        return errorResult(self.allocator, 127, name, "command not found");
    }

    pub fn executeSimpleCommand(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !CommandResult {
        return self.executeSimpleCommandWithInput(command, "", options);
    }

    fn executeSimpleCommandWithInput(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) anyerror!CommandResult {
        const trace_enabled = self.shell_options.xtrace;
        var result = try self.executeSimpleCommandWithInputInner(command, stdin, options);
        errdefer result.deinit();
        if (trace_enabled and command.argv.len != 0) {
            const trace = try traceLineForCommand(self.allocator, command);
            defer self.allocator.free(trace);
            const stderr = try std.mem.concat(self.allocator, u8, &.{ trace, result.stderr });
            self.allocator.free(result.stderr);
            result.stderr = stderr;
        }
        return result;
    }

    fn executeSimpleCommandWithInputInner(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) anyerror!CommandResult {
        const expanded = self.expandSimpleCommand(command, options) catch |err| switch (err) {
            error.NounsetParameter => {
                self.pending_exit = 1;
                return errorResult(self.allocator, 1, "parameter", "unset parameter");
            },
            error.ParameterExpansionFailed => return errorResult(self.allocator, 1, "parameter", "expansion failed"),
            else => return err,
        };
        defer self.freeExpandedCommand(expanded);

        var owned_stdin: ?[]u8 = null;
        defer if (owned_stdin) |bytes| self.allocator.free(bytes);
        const effective_stdin = try self.applyInputRedirections(expanded, stdin, options, &owned_stdin);

        if (expanded.argv.len == 0) {
            try self.applyAssignments(expanded.assignments);
            return try self.applyOutputRedirections(expanded, try emptyResult(self.allocator, 0), options);
        }

        if (!options.suppress_functions and self.functions.get(expanded.argv[0].text) != null) {
            const body = self.functions.get(expanded.argv[0].text).?;
            if (self.applyRealFdRedirectionsIfNeeded(expanded, options) catch |err| switch (err) {
                error.PathAlreadyExists => return errorResult(self.allocator, 1, noclobberTargetName(expanded), "cannot overwrite existing file"),
                else => return err,
            }) |guard_value| {
                var guard = guard_value;
                defer guard.restore(options.io.?);
                var result = try self.executeFunctionBody(expanded, body, options);
                defer result.deinit();
                try writeInheritedResult(options.io.?, result);
                return emptyResult(self.allocator, result.status);
            }
            var result = try self.executeFunctionBody(expanded, body, options);
            errdefer result.deinit();
            return try self.applyOutputRedirections(expanded, result, options);
        }

        if (builtinFor(expanded.argv[0].text)) |builtin| {
            if (self.applyRealFdRedirectionsIfNeeded(expanded, options) catch |err| switch (err) {
                error.PathAlreadyExists => return errorResult(self.allocator, 1, noclobberTargetName(expanded), "cannot overwrite existing file"),
                else => return err,
            }) |guard_value| {
                var guard = guard_value;
                defer guard.restore(options.io.?);
                var result = try self.executeBuiltinWithAssignments(builtin, expanded, effective_stdin, options);
                defer result.deinit();
                try writeInheritedResult(options.io.?, result);
                return emptyResult(self.allocator, result.status);
            }
            return try self.applyOutputRedirections(expanded, try self.executeBuiltinWithAssignments(builtin, expanded, effective_stdin, options), options);
        }

        if (!options.allow_external) {
            return try self.applyOutputRedirections(expanded, try errorResult(self.allocator, 127, expanded.argv[0].text, "command not found"), options);
        }

        const io = options.io orelse return error.MissingIoForExternalCommand;
        return try self.applyExternalPostRedirections(expanded, try self.executeExternal(expanded, io, options), options);
    }

    fn executeBuiltinWithAssignments(self: *Executor, builtin: BuiltinFn, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
        if (isSpecialBuiltin(command.argv[0].text)) {
            try self.applyAssignments(command.assignments);
            return builtin(self, command, stdin, options);
        }
        var assignment_scope = try self.pushTemporaryAssignments(command.assignments);
        defer assignment_scope.restore();
        return builtin(self, command, stdin, options);
    }

    fn executeFunctionBody(self: *Executor, command: ir.SimpleCommand, body: []const u8, options: ExecuteOptions) anyerror!CommandResult {
        var assignment_scope = try self.pushTemporaryAssignments(command.assignments);
        defer assignment_scope.restore();
        try self.pushCallFrame(command.argv[1..]);
        defer self.popCallFrame();
        self.function_depth += 1;
        defer self.function_depth -= 1;
        var result = try self.executeScriptSlice(body, options);
        errdefer result.deinit();
        if (self.pending_return) |status| {
            self.pending_return = null;
            result.status = status;
        }
        return result;
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
        const positionals: []const []const u8 = self.currentPositionals().params;
        for (words) |word| {
            var fields = try expand.expandWord(self.allocator, word.raw, .{ .env = self.envLookup(), .env_set = self.envSet(), .io = options.io, .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .positionals = positionals, .pathname_expansion = !self.shell_options.noglob, .nounset = self.shell_options.nounset });
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
                .here_doc = if (redirection.here_doc) |text| try self.expandHereDoc(text, redirection.here_doc_quoted, options) else null,
                .here_doc_quoted = redirection.here_doc_quoted,
            };
            initialized += 1;
        }
        return expanded;
    }

    fn expandHereDoc(self: *Executor, text: []const u8, quoted: bool, options: ExecuteOptions) ![]const u8 {
        if (quoted) return self.allocator.dupe(u8, text);
        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        return expand.expandWordScalar(self.allocator, text, .{ .env = self.envLookup(), .env_set = self.envSet(), .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .nounset = self.shell_options.nounset });
    }

    fn expandWord(self: *Executor, word: ir.WordRef, options: ExecuteOptions) !ir.WordRef {
        const raw = try self.allocator.dupe(u8, word.raw);
        errdefer self.allocator.free(raw);
        var substitution_context: CommandSubstitutionContext = .{ .executor = self, .options = options };
        const text = try expand.expandWordScalar(self.allocator, word.raw, .{ .env = self.envLookup(), .env_set = self.envSet(), .features = options.features, .command_substitution = commandSubstitution(&substitution_context), .nounset = self.shell_options.nounset });
        return .{ .span = word.span, .raw = raw, .text = text };
    }

    fn findExecutableInPath(self: *Executor, io: std.Io, name: []const u8) !?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            std.Io.Dir.cwd().access(io, name, .{ .execute = true }) catch return null;
            return try self.allocator.dupe(u8, name);
        }
        const path_value = self.getEnv("PATH") orelse return null;
        var parts = std.mem.splitScalar(u8, path_value, ':');
        while (parts.next()) |part| {
            const dir = if (part.len == 0) "." else part;
            const candidate = try std.mem.concat(self.allocator, u8, &.{ dir, "/", name });
            errdefer self.allocator.free(candidate);
            std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => {
                    self.allocator.free(candidate);
                    continue;
                },
                else => return err,
            };
            return candidate;
        }
        return null;
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
        var values = try self.allocator.alloc([]const u8, args.len);
        defer self.allocator.free(values);
        for (args, 0..) |arg, index| values[index] = arg.text;
        var frame: CallFrame = .{};
        errdefer frame.deinit(self.allocator);
        try frame.positionals.set(self.allocator, values);
        try self.call_frames.append(self.allocator, frame);
    }

    fn popCallFrame(self: *Executor) void {
        var frame = self.call_frames.pop().?;
        frame.deinit(self.allocator);
    }

    fn currentCallFrame(self: Executor) ?CallFrame {
        if (self.call_frames.items.len == 0) return null;
        return self.call_frames.items[self.call_frames.items.len - 1];
    }

    fn currentCallFramePtr(self: *Executor) ?*CallFrame {
        if (self.call_frames.items.len == 0) return null;
        return &self.call_frames.items[self.call_frames.items.len - 1];
    }

    fn currentPositionals(self: Executor) PositionalParams {
        if (self.currentCallFrame()) |frame| return frame.positionals;
        return self.global_positionals;
    }

    fn currentPositionalsPtr(self: *Executor) *PositionalParams {
        if (self.currentCallFramePtr()) |frame| return &frame.positionals;
        return &self.global_positionals;
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
        var sub_options = substitution_context.options;
        sub_options.external_stdio = .capture;
        var result = try substitution_context.executor.executeProgram(program, sub_options);
        defer result.deinit();
        return allocator.dupe(u8, result.stdout);
    }

    fn envSet(self: *Executor) expand.EnvSet {
        return .{ .context = self, .setFn = setEnvCallback };
    }

    fn envLookup(self: *Executor) expand.EnvLookup {
        return .{ .context = self, .lookupFn = lookupEnv };
    }

    fn setEnvCallback(context: ?*anyopaque, name: []const u8, value: []const u8) !void {
        const self: *Executor = @ptrCast(@alignCast(context.?));
        try self.setEnv(name, value);
    }

    fn lookupEnv(context: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const Executor = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, name, "?")) return self.last_status_text[0..self.last_status_text_len];
        if (std.mem.eql(u8, name, "$")) return self.pid_text[0..self.pid_text_len];
        if (std.mem.eql(u8, name, "!")) return self.last_background_pid_text[0..self.last_background_pid_text_len];
        if (std.mem.eql(u8, name, "0")) return self.arg_zero;
        const positionals = self.currentPositionals();
        if (std.mem.eql(u8, name, "#")) return positionals.count;
        if (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) return positionals.joined;
        if (name.len == 1 and std.ascii.isDigit(name[0]) and name[0] != '0') {
            const index = name[0] - '1';
            if (index < positionals.params.len) return positionals.params[index];
            return null;
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
        if (redirection.here_doc) |text| self.allocator.free(text);
    }

    fn freeWord(self: *Executor, word: ir.WordRef) void {
        self.allocator.free(word.raw);
        self.allocator.free(word.text);
    }

    const SavedAssignment = struct {
        name: []const u8,
        old_value: ?[]const u8,
    };

    const AssignmentScope = struct {
        executor: *Executor,
        saved: []SavedAssignment,

        fn restore(self: *AssignmentScope) void {
            for (self.saved) |entry| {
                if (entry.old_value) |value| {
                    self.executor.setEnv(entry.name, value) catch {};
                    self.executor.allocator.free(value);
                } else {
                    self.executor.unsetEnv(entry.name);
                }
                self.executor.allocator.free(entry.name);
            }
            self.executor.allocator.free(self.saved);
            self.* = undefined;
        }
    };

    fn pushTemporaryAssignments(self: *Executor, assignments: []const ir.WordRef) !AssignmentScope {
        const saved = try self.allocator.alloc(SavedAssignment, assignments.len);
        var initialized: usize = 0;
        errdefer {
            for (saved[0..initialized]) |entry| {
                self.allocator.free(entry.name);
                if (entry.old_value) |value| self.allocator.free(value);
            }
            self.allocator.free(saved);
        }

        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            const name = assignment.text[0..equals];
            const old_value = if (self.getEnv(name)) |value| try self.allocator.dupe(u8, value) else null;
            saved[initialized] = .{ .name = try self.allocator.dupe(u8, name), .old_value = old_value };
            initialized += 1;
            try self.setEnv(name, assignment.text[equals + 1 ..]);
        }

        return .{ .executor = self, .saved = saved[0..initialized] };
    }

    fn applyAssignments(self: *Executor, assignments: []const ir.WordRef) !void {
        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            try self.setEnv(assignment.text[0..equals], assignment.text[equals + 1 ..]);
        }
    }

    fn buildProcessEnv(self: *Executor, assignments: []const ir.WordRef) !std.process.Environ.Map {
        var map = std.process.Environ.Map.init(self.allocator);
        errdefer map.deinit();
        var iter = self.env.iterator();
        while (iter.next()) |entry| try map.put(entry.key_ptr.*, entry.value_ptr.*);
        for (assignments) |assignment| {
            const equals = std.mem.indexOfScalar(u8, assignment.text, '=') orelse continue;
            try map.put(assignment.text[0..equals], assignment.text[equals + 1 ..]);
        }
        return map;
    }

    fn applyRealFdRedirectionsIfNeeded(self: *Executor, command: ir.SimpleCommand, options: ExecuteOptions) !?FdRedirectionGuard {
        if (options.external_stdio != .inherit or command.redirections.len == 0) return null;
        const io = options.io orelse return null;
        var guard = try FdRedirectionGuard.init(io);
        errdefer guard.restore(io);
        for (command.redirections) |redirection| {
            try guard.apply(self, io, redirection);
        }
        return guard;
    }

    fn applyInputRedirections(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions, owned_stdin: *?[]u8) ![]const u8 {
        var current = stdin;
        for (command.redirections) |redirection| {
            if (isHereDocRedirection(redirection)) {
                if (owned_stdin.*) |bytes| self.allocator.free(bytes);
                owned_stdin.* = try self.allocator.dupe(u8, redirection.here_doc orelse "");
                current = owned_stdin.*.?;
                continue;
            }
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
                self.writeRedirectedStream(stream, redirection, options) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        redirected.deinit();
                        return errorResult(self.allocator, 1, targetName(redirection), "cannot overwrite existing file");
                    },
                    else => return err,
                };
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
        var file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
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

    fn executeExternal(self: *Executor, command: ir.SimpleCommand, io: std.Io, options: ExecuteOptions) !CommandResult {
        const argv = try argvForCommand(self.allocator, command);
        defer self.allocator.free(argv);

        var stdin_file: ?std.Io.File = null;
        defer if (stdin_file) |file| file.close(io);
        var stdout_file: ?std.Io.File = null;
        defer if (stdout_file) |file| file.close(io);
        var stderr_file: ?std.Io.File = null;
        defer if (stderr_file) |file| file.close(io);

        for (command.redirections) |redirection| {
            if (isHereDocRedirection(redirection)) {
                if (stdin_file) |file| file.close(io);
                stdin_file = try fileFromBytes(io, redirection.here_doc orelse "");
                continue;
            }
            if (isStdinFileRedirection(redirection)) {
                const target = redirection.target orelse continue;
                if (stdin_file) |file| file.close(io);
                stdin_file = try std.Io.Dir.cwd().openFile(io, target.text, .{});
                continue;
            }
            if (isFileOutputRedirection(redirection)) {
                const target = redirection.target orelse continue;
                const fd = redirectionFd(redirection) orelse 1;
                var file = try openOutputRedirectionFile(io, target.text, redirection.operator, self.shell_options.noclobber);
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

        var child_env = try self.buildProcessEnv(command.assignments);
        defer child_env.deinit();
        const capture_stdout = options.external_stdio == .capture and stdout_file == null;
        const capture_stderr = options.external_stdio == .capture and stderr_file == null;
        const foreground_terminal = try prepareForegroundTerminal(options.external_stdio == .inherit and stdin_file == null);
        var child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = &child_env,
            .stdin = if (stdin_file) |file| .{ .file = file } else if (options.external_stdio == .inherit) .inherit else .ignore,
            .stdout = if (stdout_file) |file| .{ .file = file } else if (capture_stdout) .pipe else .inherit,
            .stderr = if (stderr_file) |file| .{ .file = file } else if (capture_stderr) .pipe else .inherit,
            .pgid = if (foreground_terminal != null) 0 else null,
        }) catch |err| switch (err) {
            error.FileNotFound => return errorResult(self.allocator, 127, command.argv[0].text, "command not found"),
            else => return err,
        };
        defer child.kill(io);
        try giveTerminalToForegroundChild(&child, foreground_terminal);
        defer restoreForegroundTerminal(foreground_terminal);

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

fn shellPid() i64 {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) return @intCast(std.os.linux.getpid());
    return @intCast(std.c.getpid());
}

fn shellUmask(mask: u16) u16 {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        return @intCast(std.os.linux.syscall1(.umask, mask));
    }
    return @intCast(std.c.umask(mask));
}

const FdRedirectionGuard = struct {
    saved: [3]std.posix.fd_t,
    active: bool = true,

    fn init(io: std.Io) !FdRedirectionGuard {
        _ = io;
        return .{ .saved = .{ try rawDup(0), try rawDup(1), try rawDup(2) } };
    }

    fn apply(self: *FdRedirectionGuard, executor: *Executor, io: std.Io, redirection: ir.Redirection) !void {
        _ = self;
        if (isHereDocRedirection(redirection)) {
            var file = try fileFromBytes(io, redirection.here_doc orelse "");
            defer file.close(io);
            try rawDup2(file.handle, 0);
            return;
        }
        if (isStdinFileRedirection(redirection)) {
            const target = redirection.target orelse return;
            var file = try std.Io.Dir.cwd().openFile(io, target.text, .{});
            defer file.close(io);
            try rawDup2(file.handle, 0);
            return;
        }
        if (isFileOutputRedirection(redirection)) {
            const target = redirection.target orelse return;
            const fd = redirectionFd(redirection) orelse 1;
            if (fd > 2) return;
            var file = try openOutputRedirectionFile(io, target.text, redirection.operator, executor.shell_options.noclobber);
            defer file.close(io);
            try rawDup2(file.handle, fd);
            return;
        }
        if (redirection.operator == .greater_and or redirection.operator == .less_and) {
            const default_fd: u8 = if (redirection.operator == .less_and) 0 else 1;
            const from_fd = redirectionFd(redirection) orelse default_fd;
            const target = redirection.target orelse return;
            const to_fd = parseFd(target.text) orelse return;
            if (from_fd > 2 or to_fd > 2) return;
            try rawDup2(to_fd, from_fd);
            return;
        }
    }

    fn restore(self: *FdRedirectionGuard, io: std.Io) void {
        if (!self.active) return;
        for (self.saved, 0..) |saved_fd, index| {
            rawDup2(saved_fd, @intCast(index)) catch {};
            closeRawFd(io, saved_fd);
        }
        self.active = false;
    }
};

fn writeInheritedResult(io: std.Io, result: CommandResult) !void {
    _ = io;
    try rawWriteAll(1, result.stdout);
    try rawWriteAll(2, result.stderr);
}

fn rawWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const written = try rawWrite(fd, remaining);
        remaining = remaining[written..];
    }
}

fn rawWrite(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .BADF => return error.BadFileDescriptor,
            .INTR => return rawWrite(fd, bytes),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            else => return error.Unexpected,
        }
    }
}

fn rawDup(fd: std.posix.fd_t) !std.posix.fd_t {
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        const rc = std.os.linux.dup(fd);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.dup(fd);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

fn rawDup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    if (old_fd == new_fd) return;
    if (zig_builtin.os.tag == .linux and !zig_builtin.link_libc) {
        const rc = std.os.linux.dup2(old_fd, new_fd);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .BADF => return error.BadFileDescriptor,
            .BUSY => return error.FileBusy,
            .INTR => return rawDup2(old_fd, new_fd),
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
    while (true) {
        const rc = std.c.dup2(old_fd, new_fd);
        switch (std.c.errno(rc)) {
            .SUCCESS => return,
            .BADF => return error.BadFileDescriptor,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

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

extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;
extern "c" fn tcsetpgrp(fd: std.c.fd_t, pgrp: std.c.pid_t) c_int;

const ForegroundTerminal = struct {
    tty_fd: std.posix.fd_t,
    previous_pgrp: std.posix.pid_t,
};

fn terminalGetPgrp(fd: std.posix.fd_t) !std.posix.pid_t {
    if (zig_builtin.link_libc) {
        while (true) {
            const rc = tcgetpgrp(fd);
            switch (std.c.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .BADF, .INVAL => unreachable,
                .INTR => continue,
                .NOTTY => return error.NotATerminal,
                else => return error.Unexpected,
            }
        }
    }
    return std.posix.tcgetpgrp(fd);
}

fn terminalSetPgrp(fd: std.posix.fd_t, pgrp: std.posix.pid_t) !void {
    if (zig_builtin.link_libc) {
        while (true) {
            const rc = tcsetpgrp(fd, pgrp);
            switch (std.c.errno(rc)) {
                .SUCCESS => return,
                .BADF, .INVAL => unreachable,
                .INTR => continue,
                .NOTTY => return error.NotATerminal,
                .PERM => return error.NotAPgrpMember,
                else => return error.Unexpected,
            }
        }
    }
    return std.posix.tcsetpgrp(fd, pgrp);
}

fn prepareForegroundTerminal(enabled: bool) !?ForegroundTerminal {
    if (!enabled) return null;
    const tty_fd = std.Io.File.stdin().handle;
    const previous_pgrp = terminalGetPgrp(tty_fd) catch |err| switch (err) {
        error.NotATerminal => return null,
        else => return err,
    };
    return .{ .tty_fd = tty_fd, .previous_pgrp = previous_pgrp };
}

fn giveTerminalToForegroundChild(child: *std.process.Child, terminal: ?ForegroundTerminal) !void {
    const active = terminal orelse return;
    const child_pgrp = child.id orelse return;
    var sigttou = ignoreSignal(.TTOU);
    defer sigttou.restore();
    terminalSetPgrp(active.tty_fd, child_pgrp) catch |err| switch (err) {
        error.NotATerminal, error.NotAPgrpMember => return,
        else => return err,
    };
}

fn restoreForegroundTerminal(terminal: ?ForegroundTerminal) void {
    const active = terminal orelse return;
    var sigttou = ignoreSignal(.TTOU);
    defer sigttou.restore();
    terminalSetPgrp(active.tty_fd, active.previous_pgrp) catch {};
}

const SignalActionGuard = struct {
    signal: std.posix.SIG,
    previous: std.posix.Sigaction,

    fn restore(self: *SignalActionGuard) void {
        std.posix.sigaction(self.signal, &self.previous, null);
    }
};

fn ignoreSignal(signal: std.posix.SIG) SignalActionGuard {
    const ignored: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(signal, &ignored, &previous);
    return .{ .signal = signal, .previous = previous };
}

fn fileFromBytes(io: std.Io, bytes: []const u8) !std.Io.File {
    var name_buffer: [128]u8 = undefined;
    var attempts: usize = 0;
    const Counter = struct {
        var value: std.atomic.Value(u64) = .init(0);
    };
    while (attempts < 32) : (attempts += 1) {
        const suffix = Counter.value.fetchAdd(1, .monotonic);
        const name = try std.fmt.bufPrint(&name_buffer, ".rush-heredoc-{d}-{d}.tmp", .{ shellPid(), suffix });
        var write_file = std.Io.Dir.cwd().createFile(io, name, .{ .truncate = false, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        defer write_file.close(io);
        errdefer std.Io.Dir.cwd().deleteFile(io, name) catch {};
        try writeBytesToFile(io, write_file, bytes);
        const read_file = try std.Io.Dir.cwd().openFile(io, name, .{});
        std.Io.Dir.cwd().deleteFile(io, name) catch {};
        return read_file;
    }
    return error.PathAlreadyExists;
}

fn writeBytesToFile(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn openOutputRedirectionFile(io: std.Io, target: []const u8, operator: parser.TokenKind, noclobber: bool) !std.Io.File {
    return switch (operator) {
        .dgreat => openAppendRedirectionFile(io, target),
        .clobber => std.Io.Dir.cwd().createFile(io, target, .{ .truncate = true }),
        .greater => if (noclobber)
            std.Io.Dir.cwd().createFile(io, target, .{ .truncate = false, .exclusive = true })
        else
            std.Io.Dir.cwd().createFile(io, target, .{ .truncate = true }),
        else => unreachable,
    };
}

fn openAppendRedirectionFile(io: std.Io, target: []const u8) !std.Io.File {
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

fn traceLineForCommand(allocator: std.mem.Allocator, command: ir.SimpleCommand) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    try line.appendSlice(allocator, "+");
    for (command.assignments) |assignment| {
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, assignment.raw);
    }
    for (command.argv) |arg| {
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, arg.raw);
    }
    try line.append(allocator, '\n');
    return line.toOwnedSlice(allocator);
}

fn simpleCommandFromArgs(command: ir.SimpleCommand, start: usize) ir.SimpleCommand {
    return .{
        .span = command.span,
        .assignments = &.{},
        .argv = command.argv[start..],
        .redirections = &.{},
    };
}

fn stdoutLine(allocator: std.mem.Allocator, text: []const u8, status: ExitStatus) !CommandResult {
    const stdout = try std.fmt.allocPrint(allocator, "{s}\n", .{text});
    errdefer allocator.free(stdout);
    return .{ .allocator = allocator, .status = status, .stdout = stdout, .stderr = try allocator.alloc(u8, 0) };
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

fn isSpecialBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, ":") or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "break") or
        std.mem.eql(u8, name, "continue") or
        std.mem.eql(u8, name, "eval") or
        std.mem.eql(u8, name, "exec") or
        std.mem.eql(u8, name, "exit") or
        std.mem.eql(u8, name, "export") or
        std.mem.eql(u8, name, "readonly") or
        std.mem.eql(u8, name, "return") or
        std.mem.eql(u8, name, "set") or
        std.mem.eql(u8, name, "shift") or
        std.mem.eql(u8, name, "times") or
        std.mem.eql(u8, name, "trap") or
        std.mem.eql(u8, name, "unset");
}

fn builtinFor(name: []const u8) ?BuiltinFn {
    if (std.mem.eql(u8, name, ".")) return builtinSource;
    if (std.mem.eql(u8, name, ":")) return builtinTrue;
    if (std.mem.eql(u8, name, "break")) return builtinBreak;
    if (std.mem.eql(u8, name, "true")) return builtinTrue;
    if (std.mem.eql(u8, name, "false")) return builtinFalse;
    if (std.mem.eql(u8, name, "echo")) return builtinEcho;
    if (std.mem.eql(u8, name, "cat")) return builtinCat;
    if (std.mem.eql(u8, name, "command")) return builtinCommand;
    if (std.mem.eql(u8, name, "continue")) return builtinContinue;
    if (std.mem.eql(u8, name, "cd")) return builtinCd;
    if (std.mem.eql(u8, name, "printf")) return builtinPrintf;
    if (std.mem.eql(u8, name, "pwd")) return builtinPwd;
    if (std.mem.eql(u8, name, "read")) return builtinRead;
    if (std.mem.eql(u8, name, "readonly")) return builtinReadonly;
    if (std.mem.eql(u8, name, "return")) return builtinReturn;
    if (std.mem.eql(u8, name, "shift")) return builtinShift;
    if (std.mem.eql(u8, name, "export")) return builtinExport;
    if (std.mem.eql(u8, name, "unset")) return builtinUnset;
    if (std.mem.eql(u8, name, "env")) return builtinEnv;
    if (std.mem.eql(u8, name, "eval")) return builtinEval;
    if (std.mem.eql(u8, name, "exec")) return builtinExec;
    if (std.mem.eql(u8, name, "exit")) return builtinExit;
    if (std.mem.eql(u8, name, "set")) return builtinSet;
    if (std.mem.eql(u8, name, "source")) return builtinSource;
    if (std.mem.eql(u8, name, "test")) return builtinTest;
    if (std.mem.eql(u8, name, "times")) return builtinTimes;
    if (std.mem.eql(u8, name, "umask")) return builtinUmask;
    if (std.mem.eql(u8, name, "wait")) return builtinWait;
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

fn builtinCommand(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    if (command.argv.len == 1) return emptyResult(self.allocator, 0);
    if (std.mem.eql(u8, command.argv[1].text, "-v")) {
        if (command.argv.len != 3) return errorResult(self.allocator, 2, "command", "unsupported arguments");
        const name = command.argv[2].text;
        if (builtinFor(name) != null) return stdoutLine(self.allocator, name, 0);
        if (self.functions.get(name) != null) return stdoutLine(self.allocator, name, 0);
        if (options.io) |io| {
            if (try self.findExecutableInPath(io, name)) |path| {
                defer self.allocator.free(path);
                return stdoutLine(self.allocator, path, 0);
            }
        }
        return emptyResult(self.allocator, 1);
    }
    if (command.argv[1].text.len > 0 and command.argv[1].text[0] == '-') return errorResult(self.allocator, 2, "command", "unsupported option");
    const nested = simpleCommandFromArgs(command, 1);
    var nested_options = options;
    nested_options.suppress_functions = true;
    return self.executeSimpleCommandWithInput(nested, stdin, nested_options);
}

fn builtinEval(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(self.allocator);
    for (command.argv[1..], 0..) |arg, index| {
        if (index > 0) try script.append(self.allocator, ' ');
        try script.appendSlice(self.allocator, arg.text);
    }
    return self.executeScriptSlice(script.items, options);
}

fn builtinExec(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    if (command.argv.len == 1) return emptyResult(self.allocator, 0);
    const nested = simpleCommandFromArgs(command, 1);
    var result = try self.executeSimpleCommandWithInput(nested, stdin, options);
    errdefer result.deinit();
    self.pending_exit = result.status;
    return result;
}

fn builtinExit(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len > 2) return errorResult(self.allocator, 2, "exit", "too many arguments");
    const status: ExitStatus = if (command.argv.len == 2) std.fmt.parseInt(u8, command.argv[1].text, 10) catch return errorResult(self.allocator, 2, "exit", "numeric argument required") else 0;
    self.pending_exit = status;
    return emptyResult(self.allocator, status);
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

fn builtinPrintf(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len == 1) return errorResult(self.allocator, 2, "printf", "missing format operand");

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(self.allocator);
    try appendPrintfOutput(self.allocator, &stdout, command.argv[1].text, command.argv[2..]);
    return .{
        .allocator = self.allocator,
        .status = 0,
        .stdout = try stdout.toOwnedSlice(self.allocator),
        .stderr = try self.allocator.alloc(u8, 0),
    };
}

fn builtinRead(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = options;
    var arg_start: usize = 1;
    if (arg_start < command.argv.len and std.mem.eql(u8, command.argv[arg_start].text, "-r")) {
        arg_start += 1;
    }

    const names = command.argv[arg_start..];
    const line_end = std.mem.indexOfScalar(u8, stdin, '\n') orelse stdin.len;
    const status: ExitStatus = if (line_end < stdin.len) 0 else 1;
    const line = if (line_end < stdin.len and line_end > 0 and stdin[line_end - 1] == '\r') stdin[0 .. line_end - 1] else stdin[0..line_end];
    if (names.len == 0) {
        try self.setEnv("REPLY", line);
        return emptyResult(self.allocator, status);
    }

    var field_start = skipIfsWhitespace(line, 0);
    for (names, 0..) |name_word, index| {
        if (!isShellName(name_word.text)) return errorResult(self.allocator, 2, "read", "invalid variable name");
        if (index == names.len - 1) {
            const value_end = trimTrailingIfsWhitespace(line, line.len);
            const value = if (field_start <= value_end) line[field_start..value_end] else "";
            try self.setEnv(name_word.text, value);
            break;
        }
        const field_end = nextIfsWhitespace(line, field_start);
        try self.setEnv(name_word.text, line[field_start..field_end]);
        field_start = skipIfsWhitespace(line, field_end);
    }
    return emptyResult(self.allocator, status);
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

fn appendPrintfOutput(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), format: []const u8, args: []const ir.WordRef) !void {
    var arg_index: usize = 0;
    var first_pass = true;
    while (first_pass or arg_index < args.len) {
        first_pass = false;
        const before = arg_index;
        var index: usize = 0;
        while (index < format.len) {
            switch (format[index]) {
                '\\' => {
                    index += 1;
                    if (index >= format.len) {
                        try stdout.append(allocator, '\\');
                    } else {
                        try appendEscapedSequence(allocator, stdout, format[index]);
                        index += 1;
                    }
                },
                '%' => {
                    index += 1;
                    if (index >= format.len) {
                        try stdout.append(allocator, '%');
                        break;
                    }
                    const spec = format[index];
                    index += 1;
                    if (spec == '%') {
                        try stdout.append(allocator, '%');
                        continue;
                    }
                    const arg = if (arg_index < args.len) blk: {
                        const value = args[arg_index].text;
                        arg_index += 1;
                        break :blk value;
                    } else "";
                    switch (spec) {
                        's' => try stdout.appendSlice(allocator, arg),
                        'b' => try appendEscapedString(allocator, stdout, arg),
                        'c' => try stdout.append(allocator, if (arg.len == 0) 0 else arg[0]),
                        'd', 'i' => {
                            const value = std.fmt.parseInt(i64, arg, 10) catch 0;
                            try stdout.print(allocator, "{d}", .{value});
                        },
                        'u' => {
                            const value = std.fmt.parseInt(u64, arg, 10) catch 0;
                            try stdout.print(allocator, "{d}", .{value});
                        },
                        else => {
                            try stdout.append(allocator, '%');
                            try stdout.append(allocator, spec);
                        },
                    }
                },
                else => {
                    try stdout.append(allocator, format[index]);
                    index += 1;
                },
            }
        }
        if (arg_index == before) break;
    }
}

fn appendEscapedString(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try stdout.append(allocator, text[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= text.len) {
            try stdout.append(allocator, '\\');
        } else {
            try appendEscapedSequence(allocator, stdout, text[index]);
            index += 1;
        }
    }
}

fn appendEscapedSequence(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), byte: u8) !void {
    switch (byte) {
        'a' => try stdout.append(allocator, 0x07),
        'b' => try stdout.append(allocator, 0x08),
        'f' => try stdout.append(allocator, 0x0c),
        'n' => try stdout.append(allocator, '\n'),
        'r' => try stdout.append(allocator, '\r'),
        't' => try stdout.append(allocator, '\t'),
        'v' => try stdout.append(allocator, 0x0b),
        '\\' => try stdout.append(allocator, '\\'),
        else => {
            try stdout.append(allocator, '\\');
            try stdout.append(allocator, byte);
        },
    }
}

fn isShellName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_')) return false;
    }
    return true;
}

fn skipIfsWhitespace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and isIfsWhitespace(text[index])) : (index += 1) {}
    return index;
}

fn nextIfsWhitespace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and !isIfsWhitespace(text[index])) : (index += 1) {}
    return index;
}

fn trimTrailingIfsWhitespace(text: []const u8, end: usize) usize {
    var index = end;
    while (index > 0 and isIfsWhitespace(text[index - 1])) : (index -= 1) {}
    return index;
}

fn isIfsWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
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

fn builtinReadonly(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len == 1) {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var iter = self.readonly.iterator();
        while (iter.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, lessThanString);
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        for (names.items) |name| {
            try stdout.appendSlice(self.allocator, "readonly ");
            try stdout.appendSlice(self.allocator, name);
            try stdout.append(self.allocator, '\n');
        }
        return .{ .allocator = self.allocator, .status = 0, .stdout = try stdout.toOwnedSlice(self.allocator), .stderr = try self.allocator.alloc(u8, 0) };
    }
    for (command.argv[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg.text, '=')) |equals| {
            try self.setEnv(arg.text[0..equals], arg.text[equals + 1 ..]);
            try self.setReadonly(arg.text[0..equals]);
        } else {
            try self.setReadonly(arg.text);
        }
    }
    return emptyResult(self.allocator, 0);
}

fn builtinShift(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    const positionals = self.currentPositionalsPtr();
    const amount: usize = if (command.argv.len == 1) 1 else blk: {
        if (command.argv.len > 2) return errorResult(self.allocator, 2, "shift", "too many arguments");
        break :blk std.fmt.parseInt(usize, command.argv[1].text, 10) catch return errorResult(self.allocator, 2, "shift", "numeric argument required");
    };
    if (amount > positionals.params.len) return emptyResult(self.allocator, 1);
    if (positionals.owned) {
        for (positionals.params[0..amount]) |param| self.allocator.free(param);
        std.mem.copyForwards([]const u8, positionals.params[0 .. positionals.params.len - amount], positionals.params[amount..]);
        positionals.params = try self.allocator.realloc(positionals.params, positionals.params.len - amount);
    } else if (amount != 0) {
        positionals.params = &.{};
    }
    try positionals.rebuildDerived(self.allocator);
    return emptyResult(self.allocator, 0);
}

fn builtinUmask(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len > 2) return errorResult(self.allocator, 2, "umask", "too many arguments");
    const old = shellUmask(0);
    _ = shellUmask(old);
    if (command.argv.len == 1) {
        const stdout = try std.fmt.allocPrint(self.allocator, "{o:0>4}\n", .{@as(u16, @intCast(old & 0o777))});
        errdefer self.allocator.free(stdout);
        return .{ .allocator = self.allocator, .status = 0, .stdout = stdout, .stderr = try self.allocator.alloc(u8, 0) };
    }
    const new_mask = std.fmt.parseInt(u16, command.argv[1].text, 8) catch return errorResult(self.allocator, 2, "umask", "invalid mask");
    _ = shellUmask(new_mask);
    return emptyResult(self.allocator, 0);
}

fn builtinWait(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = stdin;
    _ = options;
    if (command.argv.len > 1) return errorResult(self.allocator, 127, "wait", "job ids are not implemented yet");
    return emptyResult(self.allocator, 0);
}

fn builtinTimes(self: *Executor, command: ir.SimpleCommand, stdin: []const u8, options: ExecuteOptions) !CommandResult {
    _ = command;
    _ = stdin;
    _ = options;
    return .{ .allocator = self.allocator, .status = 0, .stdout = try self.allocator.dupe(u8, "0m0.00s 0m0.00s\n0m0.00s 0m0.00s\n"), .stderr = try self.allocator.alloc(u8, 0) };
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
    if (command.argv.len >= 2 and std.mem.eql(u8, command.argv[1].text, "--")) {
        try setGlobalPositionals(self, command.argv[2..]);
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-f") or std.mem.eql(u8, command.argv[1].text, "+f"))) {
        self.shell_options.noglob = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-C") or std.mem.eql(u8, command.argv[1].text, "+C"))) {
        self.shell_options.noclobber = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-u") or std.mem.eql(u8, command.argv[1].text, "+u"))) {
        self.shell_options.nounset = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-e") or std.mem.eql(u8, command.argv[1].text, "+e"))) {
        self.shell_options.errexit = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-x") or std.mem.eql(u8, command.argv[1].text, "+x"))) {
        self.shell_options.xtrace = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and (std.mem.eql(u8, command.argv[1].text, "-v") or std.mem.eql(u8, command.argv[1].text, "+v"))) {
        self.shell_options.verbose = command.argv[1].text[0] == '-';
        return emptyResult(self.allocator, 0);
    }
    if (command.argv.len == 2 and std.mem.eql(u8, command.argv[1].text, "-o")) return printShellOptions(self, false);
    if (command.argv.len == 2 and std.mem.eql(u8, command.argv[1].text, "+o")) return printShellOptions(self, true);
    if (command.argv.len == 3 and (std.mem.eql(u8, command.argv[1].text, "-o") or std.mem.eql(u8, command.argv[1].text, "+o"))) {
        const enabled = command.argv[1].text[0] == '-';
        if (std.mem.eql(u8, command.argv[2].text, "pipefail")) {
            self.shell_options.pipefail = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "noglob")) {
            self.shell_options.noglob = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "noclobber")) {
            self.shell_options.noclobber = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "nounset")) {
            self.shell_options.nounset = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "errexit")) {
            self.shell_options.errexit = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "xtrace")) {
            self.shell_options.xtrace = enabled;
            return emptyResult(self.allocator, 0);
        }
        if (std.mem.eql(u8, command.argv[2].text, "verbose")) {
            self.shell_options.verbose = enabled;
            return emptyResult(self.allocator, 0);
        }
        return errorResult(self.allocator, 2, "set", "unknown option name");
    }
    return errorResult(self.allocator, 2, "set", "unsupported arguments");
}

fn setGlobalPositionals(self: *Executor, args: []const ir.WordRef) !void {
    var values = try self.allocator.alloc([]const u8, args.len);
    defer self.allocator.free(values);
    for (args, 0..) |arg, index| values[index] = arg.text;
    try self.global_positionals.set(self.allocator, values);
}

fn printShellOptions(self: *Executor, reusable: bool) !CommandResult {
    const stdout = if (reusable)
        try std.fmt.allocPrint(self.allocator, "set {s}o errexit\nset {s}o noclobber\nset {s}o noglob\nset {s}o nounset\nset {s}o pipefail\nset {s}o verbose\nset {s}o xtrace\n", .{ if (self.shell_options.errexit) "-" else "+", if (self.shell_options.noclobber) "-" else "+", if (self.shell_options.noglob) "-" else "+", if (self.shell_options.nounset) "-" else "+", if (self.shell_options.pipefail) "-" else "+", if (self.shell_options.verbose) "-" else "+", if (self.shell_options.xtrace) "-" else "+" })
    else
        try std.fmt.allocPrint(self.allocator, "errexit\t{s}\nnoclobber\t{s}\nnoglob\t{s}\nnounset\t{s}\npipefail\t{s}\nverbose\t{s}\nxtrace\t{s}\n", .{ if (self.shell_options.errexit) "on" else "off", if (self.shell_options.noclobber) "on" else "off", if (self.shell_options.noglob) "on" else "off", if (self.shell_options.nounset) "on" else "off", if (self.shell_options.pipefail) "on" else "off", if (self.shell_options.verbose) "on" else "off", if (self.shell_options.xtrace) "on" else "off" });
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

fn targetName(redirection: ir.Redirection) []const u8 {
    return if (redirection.target) |target| target.text else "redirection";
}

fn noclobberTargetName(command: ir.SimpleCommand) []const u8 {
    for (command.redirections) |redirection| {
        if (redirection.operator == .greater) return targetName(redirection);
    }
    return "redirection";
}

fn isHereDocRedirection(redirection: ir.Redirection) bool {
    const fd = redirectionFd(redirection) orelse 0;
    return fd == 0 and (redirection.operator == .dless or redirection.operator == .dless_dash);
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

    var quoted = try parseAndLower(std.testing.allocator,
        \\show() { for x in "$@"; do echo "<$x>"; done; IFS=:; echo "<$*>"; }
        \\show "a b" c ""
    );
    defer quoted.parsed.deinit();
    defer quoted.program.deinit();
    var quoted_result = try executor.executeProgram(quoted.program, .{});
    defer quoted_result.deinit();
    try std.testing.expectEqualStrings("<a b>\n<c>\n<>\n<a b:c:>\n", quoted_result.stdout);

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

test "executor implements global positional parameters via set --" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\set -- "a b" c ""
        \\echo "$1/$2/$#"
        \\for x in "$@"; do echo "<$x>"; done
        \\IFS=:; echo "<$*>"
        \\shift; echo "$1/$#"
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a b/c/3\n<a b>\n<c>\n<>\n<a b:c:>\nc/2\n", result.stdout);
}

test "executor persists assignment prefixes for POSIX special builtins" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\FOO=regular echo ok; echo ${FOO:-unset}; FOO=special export BAR=value; echo $FOO/$BAR
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("ok\nunset\nspecial/value\n", result.stdout);
    try std.testing.expectEqualStrings("special", executor.getEnv("FOO").?);
}

test "executor implements readonly shift umask wait and times builtins" {
    var readonly_lowered = try parseAndLower(std.testing.allocator, "readonly RO=value; unset RO; echo $RO; readonly");
    defer readonly_lowered.parsed.deinit();
    defer readonly_lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var readonly_result = try executor.executeProgram(readonly_lowered.program, .{});
    defer readonly_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), readonly_result.status);
    try std.testing.expectEqualStrings("value\nreadonly RO\n", readonly_result.stdout);

    var shift_lowered = try parseAndLower(std.testing.allocator, "f() { shift; echo $1/$#; }; f a b c");
    defer shift_lowered.parsed.deinit();
    defer shift_lowered.program.deinit();
    var shift_result = try executor.executeProgram(shift_lowered.program, .{});
    defer shift_result.deinit();
    try std.testing.expectEqualStrings("b/2\n", shift_result.stdout);

    var wait_times_lowered = try parseAndLower(std.testing.allocator, "wait; times");
    defer wait_times_lowered.parsed.deinit();
    defer wait_times_lowered.program.deinit();
    var wait_times_result = try executor.executeProgram(wait_times_lowered.program, .{});
    defer wait_times_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), wait_times_result.status);
    try std.testing.expectEqualStrings("0m0.00s 0m0.00s\n0m0.00s 0m0.00s\n", wait_times_result.stdout);

    var umask_lowered = try parseAndLower(std.testing.allocator, "umask 022; umask");
    defer umask_lowered.parsed.deinit();
    defer umask_lowered.program.deinit();
    var umask_result = try executor.executeProgram(umask_lowered.program, .{});
    defer umask_result.deinit();
    try std.testing.expectEqualStrings("0022\n", umask_result.stdout);
}

test "executor implements command eval exec and exit builtins" {
    var eval_lowered = try parseAndLower(std.testing.allocator, "eval echo eval-ok");
    defer eval_lowered.parsed.deinit();
    defer eval_lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var eval_result = try executor.executeProgram(eval_lowered.program, .{});
    defer eval_result.deinit();
    try std.testing.expectEqualStrings("eval-ok\n", eval_result.stdout);

    var command_lowered = try parseAndLower(std.testing.allocator, "f() { echo function; }; command echo builtin; command -v echo");
    defer command_lowered.parsed.deinit();
    defer command_lowered.program.deinit();
    var command_result = try executor.executeProgram(command_lowered.program, .{});
    defer command_result.deinit();
    try std.testing.expectEqualStrings("builtin\necho\n", command_result.stdout);

    var exit_lowered = try parseAndLower(std.testing.allocator, "echo before; exit 7; echo after");
    defer exit_lowered.parsed.deinit();
    defer exit_lowered.program.deinit();
    var exit_result = try executor.executeProgram(exit_lowered.program, .{});
    defer exit_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 7), exit_result.status);
    try std.testing.expectEqualStrings("before\n", exit_result.stdout);

    var exec_lowered = try parseAndLower(std.testing.allocator, "exec echo exec-ok; echo after");
    defer exec_lowered.parsed.deinit();
    defer exec_lowered.program.deinit();
    var exec_result = try executor.executeProgram(exec_lowered.program, .{});
    defer exec_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), exec_result.status);
    try std.testing.expectEqualStrings("exec-ok\n", exec_result.stdout);
}

test "executor implements read and printf builtins" {
    var printf_lowered = try parseAndLower(std.testing.allocator, "printf 'hello %s %d\\n' world 42");
    defer printf_lowered.parsed.deinit();
    defer printf_lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var printf_result = try executor.executeProgram(printf_lowered.program, .{});
    defer printf_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), printf_result.status);
    try std.testing.expectEqualStrings("hello world 42\n", printf_result.stdout);

    var repeat_lowered = try parseAndLower(std.testing.allocator, "printf '%s:%s\\n' a b c d");
    defer repeat_lowered.parsed.deinit();
    defer repeat_lowered.program.deinit();
    var repeat_result = try executor.executeProgram(repeat_lowered.program, .{});
    defer repeat_result.deinit();
    try std.testing.expectEqualStrings("a:b\nc:d\n", repeat_result.stdout);

    var escaped_lowered = try parseAndLower(std.testing.allocator, "printf '%b' 'x\\ny'");
    defer escaped_lowered.parsed.deinit();
    defer escaped_lowered.program.deinit();
    var escaped_result = try executor.executeProgram(escaped_lowered.program, .{});
    defer escaped_result.deinit();
    try std.testing.expectEqualStrings("x\ny", escaped_result.stdout);

    var unknown_escape = try parseAndLower(std.testing.allocator, "printf 'a\\ b'");
    defer unknown_escape.parsed.deinit();
    defer unknown_escape.program.deinit();
    var unknown_escape_result = try executor.executeProgram(unknown_escape.program, .{});
    defer unknown_escape_result.deinit();
    try std.testing.expectEqualStrings("a\\ b", unknown_escape_result.stdout);

    var read_lowered = try parseAndLower(std.testing.allocator,
        \\read first rest <<EOF; printf '%s/%s\n' "$first" "$rest"
        \\one two three
        \\EOF
    );
    defer read_lowered.parsed.deinit();
    defer read_lowered.program.deinit();
    var read_result = try executor.executeProgram(read_lowered.program, .{});
    defer read_result.deinit();
    try std.testing.expectEqualStrings("one/two three\n", read_result.stdout);
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

test "executor expands core POSIX special parameters" {
    var status_lowered = try parseAndLower(std.testing.allocator, "false; echo $?; true; echo $?");
    defer status_lowered.parsed.deinit();
    defer status_lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var status_result = try executor.executeProgram(status_lowered.program, .{});
    defer status_result.deinit();
    try std.testing.expectEqualStrings("1\n0\n", status_result.stdout);

    var names_lowered = try parseAndLower(std.testing.allocator, "echo $0; echo ${!}");
    defer names_lowered.parsed.deinit();
    defer names_lowered.program.deinit();
    executor.arg_zero = "rush-test";
    var names_result = try executor.executeProgram(names_lowered.program, .{});
    defer names_result.deinit();
    try std.testing.expectEqualStrings("rush-test\n\n", names_result.stdout);

    var pid_lowered = try parseAndLower(std.testing.allocator, "test -n $$");
    defer pid_lowered.parsed.deinit();
    defer pid_lowered.program.deinit();
    var pid_result = try executor.executeProgram(pid_lowered.program, .{});
    defer pid_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), pid_result.status);
}

test "executor supports POSIX parameter expansion assignment" {
    var lowered = try parseAndLower(std.testing.allocator, "echo ${ASSIGNED:=value}; echo $ASSIGNED; echo ${ASSIGNED:+set}");
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("value\nvalue\nset\n", result.stdout);
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

test "executor applies command-prefix assignments temporarily" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\FOO=outer; FOO=inner echo "$FOO"; echo "$FOO"
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{});
    defer result.deinit();
    try std.testing.expectEqualStrings("outer\nouter\n", result.stdout);
    try std.testing.expectEqualStrings("outer", executor.getEnv("FOO").?);
}

test "executor passes shell environment and command assignments to external commands" {
    var lowered = try parseAndLower(std.testing.allocator,
        \\export FOO=outer; FOO=inner /usr/bin/env | /usr/bin/grep '^FOO='
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("FOO=inner\n", result.stdout);
    try std.testing.expectEqualStrings("outer", executor.getEnv("FOO").?);
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
    try std.testing.expectEqualStrings("errexit\toff\nnoclobber\toff\nnoglob\toff\nnounset\toff\npipefail\toff\nverbose\toff\nxtrace\toff\n", show.stdout);

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
    try std.testing.expectEqualStrings("set +o errexit\nset +o noclobber\nset +o noglob\nset +o nounset\nset -o pipefail\nset +o verbose\nset +o xtrace\n", reusable.stdout);

    var disable_lowered = try parseAndLower(std.testing.allocator, "set +o pipefail; false | true");
    defer disable_lowered.parsed.deinit();
    defer disable_lowered.program.deinit();
    var disabled = try executor.executeProgram(disable_lowered.program, .{});
    defer disabled.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), disabled.status);
    try std.testing.expect(!executor.shell_options.pipefail);

    const path = "rush-noglob-a.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    var noglob_lowered = try parseAndLower(std.testing.allocator, "set -f; echo rush-noglob-?.tmp; set +f; echo rush-noglob-?.tmp");
    defer noglob_lowered.parsed.deinit();
    defer noglob_lowered.program.deinit();
    var noglob = try executor.executeProgram(noglob_lowered.program, .{ .io = std.testing.io });
    defer noglob.deinit();
    try std.testing.expectEqualStrings("rush-noglob-?.tmp\nrush-noglob-a.tmp\n", noglob.stdout);
    try std.testing.expect(!executor.shell_options.noglob);

    const clobber_path = "rush-noclobber.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, clobber_path) catch {};
    var noclobber_lowered = try parseAndLower(std.testing.allocator, "echo old > rush-noclobber.tmp; set -C; echo new > rush-noclobber.tmp; echo status=$?; echo forced >| rush-noclobber.tmp; /usr/bin/cat rush-noclobber.tmp");
    defer noclobber_lowered.parsed.deinit();
    defer noclobber_lowered.program.deinit();
    var noclobber = try executor.executeProgram(noclobber_lowered.program, .{ .io = std.testing.io, .allow_external = true });
    defer noclobber.deinit();
    try std.testing.expectEqualStrings("status=1\nforced\n", noclobber.stdout);
    try std.testing.expect(executor.shell_options.noclobber);

    var nounset_lowered = try parseAndLower(std.testing.allocator, "set -u; echo $RUSH_UNSET_FOR_TEST; echo after");
    defer nounset_lowered.parsed.deinit();
    defer nounset_lowered.program.deinit();
    var nounset = try executor.executeProgram(nounset_lowered.program, .{});
    defer nounset.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), nounset.status);
    try std.testing.expectEqualStrings("", nounset.stdout);
    try std.testing.expect(std.mem.indexOf(u8, nounset.stderr, "unset parameter") != null);
    try std.testing.expect(executor.shell_options.nounset);

    var nounset_disabled_executor = Executor.init(std.testing.allocator);
    defer nounset_disabled_executor.deinit();
    nounset_disabled_executor.shell_options.nounset = true;
    var disable_nounset = try parseAndLower(std.testing.allocator, "set +u; echo $RUSH_UNSET_FOR_TEST; echo after");
    defer disable_nounset.parsed.deinit();
    defer disable_nounset.program.deinit();
    var nounset_disabled = try nounset_disabled_executor.executeProgram(disable_nounset.program, .{});
    defer nounset_disabled.deinit();
    try std.testing.expectEqualStrings("\nafter\n", nounset_disabled.stdout);
    try std.testing.expect(!nounset_disabled_executor.shell_options.nounset);

    var errexit_executor = Executor.init(std.testing.allocator);
    defer errexit_executor.deinit();
    var errexit_lowered = try parseAndLower(std.testing.allocator, "set -e; echo before; false; echo after");
    defer errexit_lowered.parsed.deinit();
    defer errexit_lowered.program.deinit();
    var errexit = try errexit_executor.executeProgram(errexit_lowered.program, .{});
    defer errexit.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 1), errexit.status);
    try std.testing.expectEqualStrings("before\n", errexit.stdout);

    var condition_executor = Executor.init(std.testing.allocator);
    defer condition_executor.deinit();
    var condition_lowered = try parseAndLower(std.testing.allocator, "set -e; if false; then echo bad; else echo ok; fi; echo after");
    defer condition_lowered.parsed.deinit();
    defer condition_lowered.program.deinit();
    var condition = try condition_executor.executeProgram(condition_lowered.program, .{});
    defer condition.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), condition.status);
    try std.testing.expectEqualStrings("ok\nafter\n", condition.stdout);

    var trace_executor = Executor.init(std.testing.allocator);
    defer trace_executor.deinit();
    var trace_lowered = try parseAndLower(std.testing.allocator, "set -x; echo hi; set +x; echo quiet");
    defer trace_lowered.parsed.deinit();
    defer trace_lowered.program.deinit();
    var trace = try trace_executor.executeProgram(trace_lowered.program, .{});
    defer trace.deinit();
    try std.testing.expectEqualStrings("hi\nquiet\n", trace.stdout);
    try std.testing.expect(std.mem.indexOf(u8, trace.stderr, "+ echo hi\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace.stderr, "+ echo quiet\n") == null);

    var verbose_executor = Executor.init(std.testing.allocator);
    defer verbose_executor.deinit();
    var verbose = try verbose_executor.executeScriptSlice("set -v\necho verbose\n", .{});
    defer verbose.deinit();
    try std.testing.expectEqualStrings("verbose\n", verbose.stdout);
    try std.testing.expect(std.mem.indexOf(u8, verbose.stderr, "echo verbose") != null);
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

test "executor materializes here-docs without fixed temp filename" {
    const old_path = "rush-heredoc.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, old_path) catch {};
    var sentinel = try std.Io.Dir.cwd().createFile(std.testing.io, old_path, .{ .truncate = true });
    defer sentinel.close(std.testing.io);
    try writeBytesToFile(std.testing.io, sentinel, "sentinel");

    var lowered = try parseAndLower(std.testing.allocator,
        \\cat <<EOF
        \\body
        \\EOF
    );
    defer lowered.parsed.deinit();
    defer lowered.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(lowered.program, .{ .io = std.testing.io });
    defer result.deinit();
    try std.testing.expectEqualStrings("body\n", result.stdout);

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, old_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("sentinel", contents);
}

test "executor supports here-doc stdin redirections" {
    var simple = try parseAndLower(std.testing.allocator,
        \\cat <<EOF
        \\hello
        \\EOF
    );
    defer simple.parsed.deinit();
    defer simple.program.deinit();

    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();

    var simple_result = try executor.executeProgram(simple.program, .{ .io = std.testing.io });
    defer simple_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 0), simple_result.status);
    try std.testing.expectEqualStrings("hello\n", simple_result.stdout);

    var stripped = try parseAndLower(std.testing.allocator, "cat <<-EOF\n\tstripped\n\tEOF\n");
    defer stripped.parsed.deinit();
    defer stripped.program.deinit();
    var stripped_result = try executor.executeProgram(stripped.program, .{ .io = std.testing.io });
    defer stripped_result.deinit();
    try std.testing.expectEqualStrings("stripped\n", stripped_result.stdout);

    var piped = try parseAndLower(std.testing.allocator,
        \\cat <<EOF | /usr/bin/cat
        \\pipe
        \\EOF
    );
    defer piped.parsed.deinit();
    defer piped.program.deinit();
    var piped_result = try executor.executeProgram(piped.program, .{ .io = std.testing.io, .allow_external = true });
    defer piped_result.deinit();
    try std.testing.expectEqualStrings("pipe\n", piped_result.stdout);

    var multiple = try parseAndLower(std.testing.allocator,
        \\cat <<FIRST <<SECOND
        \\first body
        \\FIRST
        \\second body
        \\SECOND
    );
    defer multiple.parsed.deinit();
    defer multiple.program.deinit();
    var multiple_result = try executor.executeProgram(multiple.program, .{ .io = std.testing.io });
    defer multiple_result.deinit();
    try std.testing.expectEqualStrings("second body\n", multiple_result.stdout);

    var pipeline_multiple = try parseAndLower(std.testing.allocator,
        \\cat <<LEFT | cat <<RIGHT
        \\left body
        \\LEFT
        \\right body
        \\RIGHT
    );
    defer pipeline_multiple.parsed.deinit();
    defer pipeline_multiple.program.deinit();
    var pipeline_multiple_result = try executor.executeProgram(pipeline_multiple.program, .{ .io = std.testing.io });
    defer pipeline_multiple_result.deinit();
    try std.testing.expectEqualStrings("right body\n", pipeline_multiple_result.stdout);

    try executor.setEnv("HD_VALUE", "expanded");
    var expanded = try parseAndLower(std.testing.allocator,
        \\cat <<EOF
        \\$HD_VALUE $(echo command) $((1 + 2))
        \\EOF
    );
    defer expanded.parsed.deinit();
    defer expanded.program.deinit();
    var expanded_result = try executor.executeProgram(expanded.program, .{ .io = std.testing.io });
    defer expanded_result.deinit();
    try std.testing.expectEqualStrings("expanded command 3\n", expanded_result.stdout);

    var quoted = try parseAndLower(std.testing.allocator,
        \\cat <<'EOF'
        \\$HD_VALUE $(echo command) $((1 + 2))
        \\EOF
    );
    defer quoted.parsed.deinit();
    defer quoted.program.deinit();
    var quoted_result = try executor.executeProgram(quoted.program, .{ .io = std.testing.io });
    defer quoted_result.deinit();
    try std.testing.expectEqualStrings("$HD_VALUE $(echo command) $((1 + 2))\n", quoted_result.stdout);
}

test "executor cleans up pipelines when a stage command is missing" {
    var mixed_first = try parseAndLower(std.testing.allocator, "hi | cat");
    defer mixed_first.parsed.deinit();
    defer mixed_first.program.deinit();
    var executor = Executor.init(std.testing.allocator);
    defer executor.deinit();
    var mixed_first_result = try executor.executeProgram(mixed_first.program, .{ .io = std.testing.io, .allow_external = true });
    defer mixed_first_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), mixed_first_result.status);
    try std.testing.expectEqualStrings("hi: command not found\n", mixed_first_result.stderr);

    var mixed_last = try parseAndLower(std.testing.allocator, "echo ok | hi");
    defer mixed_last.parsed.deinit();
    defer mixed_last.program.deinit();
    var mixed_last_result = try executor.executeProgram(mixed_last.program, .{ .io = std.testing.io, .allow_external = true });
    defer mixed_last_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), mixed_last_result.status);
    try std.testing.expectEqualStrings("hi: command not found\n", mixed_last_result.stderr);

    var external_first = try parseAndLower(std.testing.allocator, "hi | /usr/bin/cat");
    defer external_first.parsed.deinit();
    defer external_first.program.deinit();
    var external_first_result = try executor.executeProgram(external_first.program, .{ .io = std.testing.io, .allow_external = true });
    defer external_first_result.deinit();
    try std.testing.expectEqual(@as(ExitStatus, 127), external_first_result.status);
    try std.testing.expectEqualStrings("hi: command not found\n", external_first_result.stderr);
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
