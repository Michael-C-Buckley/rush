//! Semantic shell-core adapter for word expansion.
//!
//! The expansion engine lives in `expand.zig`; this module derives its
//! options from `ShellState`, `EvalContext`, and runtime ports so new semantic
//! code does not need old-executor state to expand words.

const std = @import("std");

const compat = @import("compat.zig");
const expansion = @import("expand.zig");
const command_plan = @import("command_plan.zig");
const context = @import("context.zig");
const outcome = @import("outcome.zig");
const runtime = @import("../runtime.zig");
const state = @import("state.zig");

pub const shell_option_flags_max = 10;

pub const ExpansionErrorKind = enum {
    nounset_parameter,
    parameter_expansion,
    parameter_assignment,
    arithmetic_expansion,
};

pub const ExpansionFailure = struct {
    kind: ExpansionErrorKind,
    name: []const u8,
    message: []const u8,
};

pub const OwnedExpandedSimpleCommand = struct {
    allocator: std.mem.Allocator,
    command: command_plan.ExpandedSimpleCommand,

    pub fn deinit(self: *OwnedExpandedSimpleCommand) void {
        for (self.command.assignments) |assignment| {
            self.allocator.free(assignment.name);
            self.allocator.free(assignment.value);
        }
        self.allocator.free(self.command.assignments);

        for (self.command.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.command.argv);
        self.* = undefined;
    }
};

pub const ShellExpansion = struct {
    allocator: std.mem.Allocator,
    shell_state: *state.ShellState,
    eval_context: context.EvalContext,
    fs_port: ?runtime.fs.Port = null,
    features: compat.Features = .{},
    command_substitution: expansion.CommandSubstitution = .{},
    arg_zero: []const u8 = "rush",
    process_id: []const u8 = "",
    last_background_pid: []const u8 = "",
    line_number: []const u8 = "1",
    pathname_nullglob: bool = false,
    pathname_dotglob: bool = false,
    extglob: bool = false,
    patsub_replacement: bool = true,

    parameter_error: expansion.ParameterError = .{},
    arithmetic_error: expansion.ArithmeticError = .{},
    diagnostics: std.ArrayList(outcome.Diagnostic) = .empty,
    assignment_overrides: std.StringHashMapUnmanaged([]const u8) = .empty,

    last_status_text: [3]u8 = undefined,
    last_status_text_len: usize = 0,
    positional_count_text: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined,
    positional_count_text_len: usize = 0,
    option_flags_buffer: [shell_option_flags_max]u8 = undefined,
    option_flags_len: usize = 0,

    pub const Init = struct {
        shell_state: *state.ShellState,
        eval_context: context.EvalContext,
        fs_port: ?runtime.fs.Port = null,
        features: compat.Features = .{},
        command_substitution: expansion.CommandSubstitution = .{},
        arg_zero: []const u8 = "rush",
        process_id: []const u8 = "",
        last_background_pid: []const u8 = "",
        line_number: []const u8 = "1",
        pathname_nullglob: bool = false,
        pathname_dotglob: bool = false,
        extglob: bool = false,
        patsub_replacement: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: Init) ShellExpansion {
        options.shell_state.validate();
        options.eval_context.validate();
        assertExpansionTargetState(options.shell_state.*, options.eval_context);
        const adapter: ShellExpansion = .{
            .allocator = allocator,
            .shell_state = options.shell_state,
            .eval_context = options.eval_context,
            .fs_port = options.fs_port,
            .features = options.features,
            .command_substitution = options.command_substitution,
            .arg_zero = options.arg_zero,
            .process_id = options.process_id,
            .last_background_pid = options.last_background_pid,
            .line_number = options.line_number,
            .pathname_nullglob = options.pathname_nullglob,
            .pathname_dotglob = options.pathname_dotglob,
            .extglob = options.extglob,
            .patsub_replacement = options.patsub_replacement,
        };
        adapter.validate();
        return adapter;
    }

    pub fn deinit(self: *ShellExpansion) void {
        self.parameter_error.clear(self.allocator);
        self.arithmetic_error.clear(self.allocator);
        for (self.diagnostics.items) |diagnostic| self.allocator.free(diagnostic.message);
        self.diagnostics.deinit(self.allocator);
        self.assignment_overrides.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn expandWordFields(self: *ShellExpansion, raw: []const u8) !expansion.ExpansionResult {
        self.validateExpansionInput(raw);
        var result = try expansion.expandWord(self.allocator, raw, self.expandOptions());
        errdefer result.deinit();
        assertExpandedFields(result.fields);
        return result;
    }

    pub fn expandWordScalar(self: *ShellExpansion, raw: []const u8) ![]const u8 {
        self.validateExpansionInput(raw);
        const text = try expansion.expandWordScalar(self.allocator, raw, self.expandOptions());
        errdefer self.allocator.free(text);
        assertExpandedField(text);
        return text;
    }

    pub fn expandCasePattern(self: *ShellExpansion, raw: []const u8) ![]const u8 {
        self.validateExpansionInput(raw);
        const text = try expansion.expandCasePattern(self.allocator, raw, self.expandOptions());
        errdefer self.allocator.free(text);
        assertExpandedField(text);
        return text;
    }

    pub fn expandAssignmentWordScalar(self: *ShellExpansion, raw: []const u8) ![]const u8 {
        self.validateExpansionInput(raw);
        const text = try expansion.expandAssignmentWordScalar(self.allocator, raw, self.expandOptions());
        errdefer self.allocator.free(text);
        assertExpandedField(text);
        return text;
    }

    pub fn expandHereDocBody(self: *ShellExpansion, text: []const u8) ![]const u8 {
        self.validateExpansionInput(text);
        const expanded = try expansion.expandHereDocBody(self.allocator, text, self.expandOptions());
        errdefer self.allocator.free(expanded);
        assertExpandedField(expanded);
        return expanded;
    }

    pub fn expandParametersScalar(self: *ShellExpansion, raw: []const u8) ![]const u8 {
        self.validateExpansionInput(raw);
        const text = try expansion.expandParametersScalar(self.allocator, raw, self.expandOptions());
        errdefer self.allocator.free(text);
        assertExpandedField(text);
        return text;
    }

    pub fn quoteRemove(self: *ShellExpansion, raw: []const u8) ![]const u8 {
        self.validateExpansionInput(raw);
        const text = try expansion.quoteRemove(self.allocator, raw);
        errdefer self.allocator.free(text);
        assertExpandedField(text);
        return text;
    }

    pub fn expandArgv(self: *ShellExpansion, words: []const []const u8) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (argv.items) |arg| self.allocator.free(arg);
            argv.deinit(self.allocator);
        }

        for (words) |word| {
            var fields = try self.expandWordFields(word);
            defer fields.deinit();
            for (fields.fields) |field| {
                const owned = try self.allocator.dupe(u8, field);
                errdefer self.allocator.free(owned);
                try argv.append(self.allocator, owned);
            }
        }

        const owned_argv = try argv.toOwnedSlice(self.allocator);
        assertExpandedFields(owned_argv);
        return owned_argv;
    }

    pub fn expandCommandArgv(self: *ShellExpansion, words: []const []const u8) ![]const []const u8 {
        if (words.len == 0) return self.expandArgv(words);

        var argv: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (argv.items) |arg| self.allocator.free(arg);
            argv.deinit(self.allocator);
        }

        var first_fields = try self.expandWordFields(words[0]);
        defer first_fields.deinit();
        for (first_fields.fields) |field| {
            const owned = try self.allocator.dupe(u8, field);
            errdefer self.allocator.free(owned);
            try argv.append(self.allocator, owned);
        }

        const declaration_utility = first_fields.fields.len != 0 and
            (isDeclarationUtility(first_fields.fields[0]) or
                commandInvocationWrapsDeclaration(first_fields.fields, words[1..]));
        for (words[1..]) |word| {
            if (declaration_utility and isAssignmentOperand(word)) {
                const expanded = try self.expandAssignmentWordScalar(word);
                errdefer self.allocator.free(expanded);
                try argv.append(self.allocator, expanded);
                continue;
            }

            var fields = try self.expandWordFields(word);
            defer fields.deinit();
            for (fields.fields) |field| {
                const owned = try self.allocator.dupe(u8, field);
                errdefer self.allocator.free(owned);
                try argv.append(self.allocator, owned);
            }
        }

        const owned_argv = try argv.toOwnedSlice(self.allocator);
        assertExpandedFields(owned_argv);
        return owned_argv;
    }

    pub fn expandAssignmentWord(self: *ShellExpansion, raw: []const u8) !command_plan.Assignment {
        const expanded = try self.expandAssignmentWordScalar(raw);
        defer self.allocator.free(expanded);

        const equals = std.mem.indexOfScalar(u8, expanded, '=') orelse return error.InvalidAssignmentWord;
        const name = expanded[0..equals];
        state.assertValidVariableName(name);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, expanded[equals + 1 ..]);
        return .{ .name = owned_name, .value = owned_value };
    }

    pub fn expandSimpleCommand(
        self: *ShellExpansion,
        assignment_words: []const []const u8,
        argv_words: []const []const u8,
    ) !OwnedExpandedSimpleCommand {
        var assignments: std.ArrayList(command_plan.Assignment) = .empty;
        errdefer {
            for (assignments.items) |assignment| {
                self.allocator.free(assignment.name);
                self.allocator.free(assignment.value);
            }
            assignments.deinit(self.allocator);
        }
        errdefer self.assignment_overrides.clearRetainingCapacity();
        for (assignment_words) |word| {
            const assignment = try self.expandAssignmentWord(word);
            self.assignment_overrides.put(self.allocator, assignment.name, assignment.value) catch |err| {
                self.allocator.free(assignment.name);
                self.allocator.free(assignment.value);
                return err;
            };
            assignments.append(self.allocator, assignment) catch |err| {
                _ = self.assignment_overrides.remove(assignment.name);
                self.allocator.free(assignment.name);
                self.allocator.free(assignment.value);
                return err;
            };
        }
        self.assignment_overrides.clearRetainingCapacity();

        const argv = try self.expandCommandArgv(argv_words);
        errdefer freeFields(self.allocator, argv);

        const command: command_plan.ExpandedSimpleCommand = .{
            .assignments = try assignments.toOwnedSlice(self.allocator),
            .argv = argv,
        };
        command.validate();
        assertValidExpandedCommand(command);
        return .{ .allocator = self.allocator, .command = command };
    }

    pub fn classifyError(self: ShellExpansion, err: anyerror) ?ExpansionFailure {
        return switch (err) {
            error.NounsetParameter => .{
                .kind = .nounset_parameter,
                .name = "parameter",
                .message = "parameter not set",
            },
            error.ParameterExpansionFailed => .{
                .kind = .parameter_expansion,
                .name = if (self.parameter_error.name.len != 0) self.parameter_error.name else "parameter",
                .message = if (self.parameter_error.message.len != 0)
                    self.parameter_error.message
                else
                    "expansion failed",
            },
            error.ParameterAssignmentFailed => .{
                .kind = .parameter_assignment,
                .name = if (self.parameter_error.name.len != 0) self.parameter_error.name else "parameter",
                .message = if (self.parameter_error.message.len != 0)
                    self.parameter_error.message
                else
                    "assignment failed",
            },
            error.ArithmeticExpansionFailed => .{
                .kind = .arithmetic_expansion,
                .name = "arithmetic",
                .message = if (self.arithmetic_error.message.len != 0)
                    self.arithmetic_error.message
                else
                    "invalid arithmetic expression",
            },
            else => null,
        };
    }

    pub fn validate(self: ShellExpansion) void {
        self.shell_state.validate();
        self.eval_context.validate();
        assertExpansionTargetState(self.shell_state.*, self.eval_context);
        if (self.command_substitution.runFn != null) std.debug.assert(self.command_substitution.context != null);
    }

    fn expandOptions(self: *ShellExpansion) expansion.Options {
        self.prepareSpecialParameterBuffers();
        self.parameter_error.clear(self.allocator);
        self.arithmetic_error.clear(self.allocator);

        return .{
            .env = .{ .context = self, .lookupFn = lookupEnv },
            .variable_names = .{ .context = self, .countFn = variableNameCount, .nameFn = variableNameAt },
            .env_set = .{ .context = self, .setFn = setEnv },
            .diagnostic_sink = .{ .context = self, .appendFn = appendDiagnostic },
            .features = self.features,
            .command_substitution = self.command_substitution,
            .pathname_lookup = pathnameLookup(self),
            .positionals = self.shell_state.positionals.items,
            .option_flags = self.option_flags_buffer[0..self.option_flags_len],
            .pathname_expansion = !self.shell_state.options.noglob,
            .pathname_nullglob = self.pathname_nullglob,
            .pathname_dotglob = self.pathname_dotglob,
            .extglob = self.extglob,
            .patsub_replacement = self.patsub_replacement,
            .nounset = self.shell_state.options.nounset,
            .parameter_error = &self.parameter_error,
            .arithmetic_error = &self.arithmetic_error,
        };
    }

    fn prepareSpecialParameterBuffers(self: *ShellExpansion) void {
        const status_text = std.fmt.bufPrint(
            &self.last_status_text,
            "{d}",
            .{self.shell_state.last_status},
        ) catch unreachable;
        self.last_status_text_len = status_text.len;
        const count_text = std.fmt.bufPrint(
            &self.positional_count_text,
            "{d}",
            .{self.shell_state.positionals.items.len},
        ) catch unreachable;
        self.positional_count_text_len = count_text.len;
        self.option_flags_len = shellOptionFlags(self.shell_state.options, &self.option_flags_buffer).len;
    }

    fn validateExpansionInput(self: ShellExpansion, raw: []const u8) void {
        self.validate();
        std.debug.assert(std.mem.indexOfScalar(u8, raw, 0) == null);
    }
};

pub fn freeFields(allocator: std.mem.Allocator, fields: []const []const u8) void {
    for (fields) |field| allocator.free(field);
    allocator.free(fields);
}

fn pathnameLookup(self: *ShellExpansion) expansion.PathnameLookup {
    if (self.fs_port == null) return .{};
    return .{
        .context = self,
        .listDirFn = listPathnameDir,
        .pathExistsFn = pathnameExists,
        .pathIsDirectoryFn = pathnameIsDirectory,
    };
}

// ziglint-ignore: Z023 - signature is fixed by the listDirFn callback pointer
// type; the opaque context must come first.
fn listPathnameDir(
    opaque_context: ?*anyopaque,
    // ziglint-ignore: Z023 - opaque context must come first (callback ABI).
    allocator: std.mem.Allocator,
    path: []const u8,
) !expansion.PathnameEntries {
    std.debug.assert(opaque_context != null);
    const self: *ShellExpansion = @ptrCast(@alignCast(opaque_context.?));
    const fs_port = self.fs_port orelse unreachable;
    var entries = fs_port.listDir(.{ .allocator = allocator, .path = path }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .entries = &.{} },
        else => return err,
    };
    return pathnameEntriesFromRuntime(allocator, &entries);
}

fn pathnameEntriesFromRuntime(
    allocator: std.mem.Allocator,
    runtime_entries: *runtime.fs.ListDirResult,
) !expansion.PathnameEntries {
    const released = runtime_entries.release();
    errdefer {
        for (released) |entry| allocator.free(entry.name);
        allocator.free(released);
    }

    const entries = try allocator.alloc(expansion.PathnameEntry, released.len);
    errdefer allocator.free(entries);
    for (released, entries) |source, *dest| {
        dest.* = .{ .name = source.name };
    }
    allocator.free(released);
    return .{ .entries = entries };
}

fn pathnameExists(opaque_context: ?*anyopaque, path: []const u8) !bool {
    std.debug.assert(opaque_context != null);
    const self: *ShellExpansion = @ptrCast(@alignCast(opaque_context.?));
    const fs_port = self.fs_port orelse unreachable;
    if (path.len == 0) return true;
    _ = fs_port.inspectPath(.{ .path = path }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return true;
}

fn pathnameIsDirectory(opaque_context: ?*anyopaque, path: []const u8) !bool {
    std.debug.assert(opaque_context != null);
    const self: *ShellExpansion = @ptrCast(@alignCast(opaque_context.?));
    const fs_port = self.fs_port orelse unreachable;
    if (path.len == 0) return true;
    const metadata = fs_port.inspectPath(.{ .path = path }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    return metadata.stat.kind == .directory;
}

fn lookupEnv(opaque_context: ?*const anyopaque, name: []const u8) ?[]const u8 {
    std.debug.assert(opaque_context != null);
    const self: *const ShellExpansion = @ptrCast(@alignCast(@constCast(opaque_context.?)));
    if (std.mem.eql(u8, name, "?")) return self.last_status_text[0..self.last_status_text_len];
    if (std.mem.eql(u8, name, "#")) return self.positional_count_text[0..self.positional_count_text_len];
    if (std.mem.eql(u8, name, "0")) return self.arg_zero;
    if (std.mem.eql(u8, name, "$")) return if (self.process_id.len != 0) self.process_id else null;
    if (std.mem.eql(u8, name, "!")) return if (self.last_background_pid.len != 0) self.last_background_pid else null;
    if (std.mem.eql(u8, name, "LINENO")) return self.line_number;
    if (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) return null;
    if (isDigitName(name)) {
        const number = std.fmt.parseInt(usize, name, 10) catch return null;
        if (number == 0) return self.arg_zero;
        const index = number - 1;
        if (index < self.shell_state.positionals.items.len) return self.shell_state.positionals.items[index];
        return null;
    }
    if (!isValidVariableName(name)) return null;
    if (self.assignment_overrides.get(name)) |value| return value;
    return if (self.shell_state.getVariable(name)) |variable| variable.value else null;
}

fn setEnv(opaque_context: ?*anyopaque, name: []const u8, value: []const u8) !void {
    std.debug.assert(opaque_context != null);
    const self: *ShellExpansion = @ptrCast(@alignCast(opaque_context.?));
    state.assertValidVariableName(name);
    try self.shell_state.putVariable(name, value, .{});
}

fn variableNameCount(opaque_context: ?*const anyopaque) usize {
    std.debug.assert(opaque_context != null);
    const self: *const ShellExpansion = @ptrCast(@alignCast(@constCast(opaque_context.?)));
    return self.shell_state.variables.count();
}

fn variableNameAt(opaque_context: ?*const anyopaque, ordinal: usize) ?[]const u8 {
    std.debug.assert(opaque_context != null);
    const self: *const ShellExpansion = @ptrCast(@alignCast(@constCast(opaque_context.?)));
    var remaining = ordinal;
    var iterator = self.shell_state.variables.iterator();
    while (iterator.next()) |entry| {
        if (remaining == 0) return entry.key_ptr.*;
        remaining -= 1;
    }
    return null;
}

fn appendDiagnostic(opaque_context: ?*anyopaque, name: []const u8, message: []const u8) !void {
    std.debug.assert(opaque_context != null);
    const self: *ShellExpansion = @ptrCast(@alignCast(opaque_context.?));
    const diagnostic = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ name, message });
    errdefer self.allocator.free(diagnostic);
    try self.diagnostics.append(self.allocator, .{ .message = diagnostic });
}

fn isDeclarationUtility(name: []const u8) bool {
    return std.mem.eql(u8, name, "export") or std.mem.eql(u8, name, "readonly");
}

fn commandInvocationWrapsDeclaration(first_fields: []const []const u8, operands: []const []const u8) bool {
    if (first_fields.len != 1 or !std.mem.eql(u8, first_fields[0], "command")) return false;
    var index: usize = 0;
    while (index < operands.len) : (index += 1) {
        const operand = operands[index];
        if (std.mem.eql(u8, operand, "-p")) continue;
        if (std.mem.eql(u8, operand, "command")) {
            return commandInvocationWrapsDeclaration(&.{"command"}, operands[index + 1 ..]);
        }
        return isDeclarationUtility(operand);
    }
    return false;
}

fn isAssignmentOperand(word: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    return isValidVariableName(word[0..equals]);
}

pub fn shellOptionFlags(options: state.ShellOptions, buffer: *[shell_option_flags_max]u8) []const u8 {
    var len: usize = 0;
    if (options.allexport) appendFlag(buffer, &len, 'a');
    if (options.notify) appendFlag(buffer, &len, 'b');
    if (options.errexit) appendFlag(buffer, &len, 'e');
    if (options.monitor) appendFlag(buffer, &len, 'm');
    if (options.noclobber) appendFlag(buffer, &len, 'C');
    if (options.noglob) appendFlag(buffer, &len, 'f');
    if (options.noexec) appendFlag(buffer, &len, 'n');
    if (options.nounset) appendFlag(buffer, &len, 'u');
    if (options.verbose) appendFlag(buffer, &len, 'v');
    if (options.xtrace) appendFlag(buffer, &len, 'x');
    return buffer[0..len];
}

fn appendFlag(buffer: *[shell_option_flags_max]u8, len: *usize, flag: u8) void {
    std.debug.assert(len.* < buffer.len);
    buffer[len.*] = flag;
    len.* += 1;
}

fn assertExpansionTargetState(shell_state: state.ShellState, eval_context: context.EvalContext) void {
    eval_context.validate();
    if (eval_context.target == .current_shell) std.debug.assert(shell_state.acceptsExecutionTarget(.current_shell));
    if (eval_context.target == .subshell) std.debug.assert(shell_state.acceptsExecutionTarget(.subshell));
}

fn assertExpandedFields(fields: []const []const u8) void {
    for (fields) |field| assertExpandedField(field);
}

fn assertExpandedField(field: []const u8) void {
    std.debug.assert(std.mem.indexOfScalar(u8, field, 0) == null);
}

fn assertValidExpandedCommand(command: command_plan.ExpandedSimpleCommand) void {
    command.validate();
    assertExpandedFields(command.argv);
    for (command.assignments) |assignment| assertExpandedField(assignment.value);
}

fn isDigitName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isValidVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

test "ShellExpansion derives parameter positional special and option lookups from ShellState" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("USER", "rush", .{});
    try shell_state.replacePositionals(&.{ "one", "two words" });
    shell_state.last_status = 7;
    shell_state.options.set(.errexit, true);
    shell_state.options.set(.noglob, true);

    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
        .arg_zero = "rush-test",
    });
    defer adapter.deinit();

    const scalar = try adapter.expandWordScalar("$USER:$1:$2:$#:$?:$0:$-");
    defer std.testing.allocator.free(scalar);

    try std.testing.expectEqualStrings("rush:one:two words:2:7:rush-test:ef", scalar);
}

test "ShellExpansion classifies nounset parameter and arithmetic errors as data" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.set(.nounset, true);

    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
    });
    defer adapter.deinit();

    try std.testing.expectError(error.NounsetParameter, adapter.expandWordScalar("$MISSING"));
    const nounset = adapter.classifyError(error.NounsetParameter).?;
    try std.testing.expectEqual(ExpansionErrorKind.nounset_parameter, nounset.kind);

    try std.testing.expectError(error.ParameterExpansionFailed, adapter.expandWordScalar("${MISSING:?custom message}"));
    const parameter = adapter.classifyError(error.ParameterExpansionFailed).?;
    try std.testing.expectEqual(ExpansionErrorKind.parameter_expansion, parameter.kind);
    try std.testing.expectEqualStrings("MISSING", parameter.name);
    try std.testing.expectEqualStrings("custom message", parameter.message);

    try std.testing.expectError(error.ArithmeticExpansionFailed, adapter.expandWordScalar("$((1 / 0))"));
    const arithmetic = adapter.classifyError(error.ArithmeticExpansionFailed).?;
    try std.testing.expectEqual(ExpansionErrorKind.arithmetic_expansion, arithmetic.kind);
    try std.testing.expectEqualStrings("division by zero", arithmetic.message);
}

test "ShellExpansion applies field splitting quote removal arithmetic tilde and assignment defaults" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("HOME", "/tmp/rush-home", .{});
    try shell_state.putVariable("WORDS", "one two", .{});

    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
    });
    defer adapter.deinit();

    const argv = try adapter.expandArgv(&.{ "$WORDS", "\"three four\"", "$((1 + 2))", "~" });
    defer freeFields(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("one", argv[0]);
    try std.testing.expectEqualStrings("two", argv[1]);
    try std.testing.expectEqualStrings("three four", argv[2]);
    try std.testing.expectEqualStrings("3", argv[3]);
    try std.testing.expectEqualStrings("/tmp/rush-home", argv[4]);

    const removed = try adapter.quoteRemove("'a b'\\ c");
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("a b c", removed);

    const assigned = try adapter.expandWordScalar("${ASSIGNED:=value}");
    defer std.testing.allocator.free(assigned);
    try std.testing.expectEqualStrings("value", assigned);
    try std.testing.expectEqualStrings("value", shell_state.getVariable("ASSIGNED").?.value);
}

test "ShellExpansion routes pathname expansion through runtime fs port" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const dir = "rush-shell-expansion-glob-dir";
    const a = "rush-shell-expansion-glob-dir/a.tmp";
    const b = "rush-shell-expansion-glob-dir/b.tmp";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = a, .data = "" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = b, .data = "" });

    var posix_adapter = runtime.posix.Adapter.init(std.testing.io);
    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
        .fs_port = posix_adapter.fsPort(),
    });
    defer adapter.deinit();

    var fields = try adapter.expandWordFields("rush-shell-expansion-glob-dir/*.tmp");
    defer fields.deinit();
    try std.testing.expectEqual(@as(usize, 2), fields.fields.len);
    try std.testing.expectEqualStrings(a, fields.fields[0]);
    try std.testing.expectEqualStrings(b, fields.fields[1]);

    shell_state.options.set(.noglob, true);
    var disabled = try adapter.expandWordFields("rush-shell-expansion-glob-dir/*.tmp");
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 1), disabled.fields.len);
    try std.testing.expectEqualStrings("rush-shell-expansion-glob-dir/*.tmp", disabled.fields[0]);
}

test "ShellExpansion uses semantic command-substitution callback without parent leakage" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const Resolver = struct {
        // ziglint-ignore: Z023 - signature is fixed by the resolveFn callback
        // pointer type; the opaque context must come first.
        fn run(_: ?*anyopaque, allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
            if (std.mem.eql(u8, script, "emit")) return allocator.dupe(u8, "one two\n\n");
            return allocator.alloc(u8, 0);
        }
    };

    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
        .command_substitution = .{ .context = &shell_state, .runFn = Resolver.run },
    });
    defer adapter.deinit();

    var unquoted = try adapter.expandWordFields("pre-$(emit)-post");
    defer unquoted.deinit();
    try std.testing.expectEqual(@as(usize, 2), unquoted.fields.len);
    try std.testing.expectEqualStrings("pre-one", unquoted.fields[0]);
    try std.testing.expectEqualStrings("two-post", unquoted.fields[1]);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("SUB"));
}

test "ShellExpansion prevents invalid expanded simple command shapes" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("EMPTY", "", .{});

    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
    });
    defer adapter.deinit();

    var command = try adapter.expandSimpleCommand(&.{"A=1"}, &.{ "$EMPTY", "echo", "'hello world'" });
    defer command.deinit();
    command.command.validate();

    try std.testing.expectEqual(@as(usize, 1), command.command.assignments.len);
    try std.testing.expectEqualStrings("A", command.command.assignments[0].name);
    try std.testing.expectEqualStrings("1", command.command.assignments[0].value);
    try std.testing.expectEqual(@as(usize, 2), command.command.argv.len);
    try std.testing.expectEqualStrings("echo", command.command.argv[0]);
    try std.testing.expectEqualStrings("hello world", command.command.argv[1]);

    const plan = command_plan.classifyExpandedSimpleCommand(.{ .command = command.command });
    plan.validate();
}

test "ShellExpansion applies assignment tilde expansion to declaration utility operands" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("HOME", "/tmp", .{});

    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
    });
    defer adapter.deinit();

    var command = try adapter.expandSimpleCommand(&.{}, &.{ "export", "PATH=~:/bin" });
    defer command.deinit();

    try std.testing.expectEqual(@as(usize, 2), command.command.argv.len);
    try std.testing.expectEqualStrings("export", command.command.argv[0]);
    try std.testing.expectEqualStrings("PATH=/tmp:/bin", command.command.argv[1]);

    var wrapped = try adapter.expandSimpleCommand(&.{}, &.{ "command", "export", "PATH=~:/bin" });
    defer wrapped.deinit();

    try std.testing.expectEqual(@as(usize, 3), wrapped.command.argv.len);
    try std.testing.expectEqualStrings("command", wrapped.command.argv[0]);
    try std.testing.expectEqualStrings("export", wrapped.command.argv[1]);
    try std.testing.expectEqualStrings("PATH=/tmp:/bin", wrapped.command.argv[2]);

    var nested = try adapter.expandSimpleCommand(&.{}, &.{ "command", "command", "readonly", "PATH=~:/bin" });
    defer nested.deinit();

    try std.testing.expectEqual(@as(usize, 4), nested.command.argv.len);
    try std.testing.expectEqualStrings("command", nested.command.argv[0]);
    try std.testing.expectEqualStrings("command", nested.command.argv[1]);
    try std.testing.expectEqualStrings("readonly", nested.command.argv[2]);
    try std.testing.expectEqualStrings("PATH=/tmp:/bin", nested.command.argv[3]);
}

test "ShellExpansion expands assignment words left-to-right without changing argv expansion" {
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("A", "outer", .{});

    var adapter = ShellExpansion.init(std.testing.allocator, .{
        .shell_state = &shell_state,
        .eval_context = context.EvalContext.forTarget(.current_shell),
    });
    defer adapter.deinit();

    var command = try adapter.expandSimpleCommand(&.{ "A=one", "B=$A" }, &.{ "printf", "$A" });
    defer command.deinit();
    command.command.validate();

    try std.testing.expectEqual(@as(usize, 2), command.command.assignments.len);
    try std.testing.expectEqualStrings("A", command.command.assignments[0].name);
    try std.testing.expectEqualStrings("one", command.command.assignments[0].value);
    try std.testing.expectEqualStrings("B", command.command.assignments[1].name);
    try std.testing.expectEqualStrings("one", command.command.assignments[1].value);
    try std.testing.expectEqual(@as(usize, 2), command.command.argv.len);
    try std.testing.expectEqualStrings("printf", command.command.argv[0]);
    try std.testing.expectEqualStrings("outer", command.command.argv[1]);
    try std.testing.expectEqualStrings("outer", shell_state.getVariable("A").?.value);
    try std.testing.expectEqual(@as(?state.Variable, null), shell_state.getVariable("B"));
}
