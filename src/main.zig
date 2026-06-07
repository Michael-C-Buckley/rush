//! Application entry point.

const std = @import("std");

pub const compat = @import("compat.zig");
pub const parser = @import("parser.zig");
pub const expand = @import("expand.zig");
pub const ir = @import("ir.zig");
pub const exec = @import("exec.zig");

const usage =
    \\usage: rush -c SCRIPT
    \\       rush --help
    \\
;

const system_config_path = "/etc/rush/config.rush";

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1) {
        return runInteractive(allocator, init.io, init.environ_map);
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try writeAll(init.io, .stdout, usage);
        return 0;
    }

    if (args.len != 3 or !std.mem.eql(u8, args[1], "-c")) {
        try writeAll(init.io, .stderr, usage);
        return 2;
    }

    var result = try runScriptWithEnvironment(allocator, init.io, args[2], .{ .io = init.io, .allow_external = true, .external_stdio = .inherit, .arg_zero = args[0] }, init.environ_map);
    defer result.deinit();

    try writeAll(init.io, .stdout, result.stdout);
    try writeAll(init.io, .stderr, result.stderr);
    return result.status;
}

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| self.allocator.free(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *History, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.entries.items.len != 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], line)) return;
        try self.entries.append(self.allocator, try self.allocator.dupe(u8, line));
    }

    pub fn suggest(self: History, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0) return null;
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            if (std.mem.startsWith(u8, entry, prefix) and entry.len > prefix.len) return entry;
        }
        return null;
    }

    pub fn load(self: *History, io: std.Io, path: []const u8) !void {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| try self.add(line);
    }

    pub fn save(self: History, io: std.Io, path: []const u8) !void {
        var contents: std.ArrayList(u8) = .empty;
        defer contents.deinit(self.allocator);
        for (self.entries.items) |entry| {
            try contents.appendSlice(self.allocator, entry);
            try contents.append(self.allocator, '\n');
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents.items });
    }
};

pub const Completion = struct {
    text: []const u8,
};

pub fn completeInput(allocator: std.mem.Allocator, io: std.Io, executor: exec.Executor, source: []const u8, cursor: usize) ![]Completion {
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .cursor = cursor });
    defer parsed.deinit();
    const context = parser.completionContext(parsed, cursor);
    const prefix = completionPrefix(source, context);

    if (isVariableCompletion(source, context)) {
        return completeVariables(allocator, executor, prefix);
    }

    return switch (context.kind) {
        .command => completeCommands(allocator, prefix),
        .argument, .redirect_target => completePaths(allocator, io, prefix),
        .assignment_name => completeVariables(allocator, executor, prefix),
        .assignment_value, .separator, .quoted_string => allocator.alloc(Completion, 0),
    };
}

fn isVariableCompletion(source: []const u8, context: parser.CompletionContext) bool {
    if (context.token_index == null or context.span.start >= source.len) return false;
    return source[context.span.start] == '$';
}

fn completionPrefix(source: []const u8, context: parser.CompletionContext) []const u8 {
    if (context.token_index == null) return "";
    const start = context.span.start;
    const end = @min(context.cursor, context.span.end);
    if (start >= end or end > source.len) return "";
    const raw = source[start..end];
    if (raw.len > 0 and raw[0] == '$') return raw[1..];
    return raw;
}

fn completeCommands(allocator: std.mem.Allocator, prefix: []const u8) ![]Completion {
    const builtins = [_][]const u8{ ".", ":", "cat", "cd", "echo", "env", "export", "false", "pwd", "set", "source", "test", "true", "unset", "[" };
    var completions: std.ArrayList(Completion) = .empty;
    errdefer freeCompletions(allocator, completions.items);
    for (builtins) |builtin| {
        if (std.mem.startsWith(u8, builtin, prefix)) {
            try completions.append(allocator, .{ .text = try allocator.dupe(u8, builtin) });
        }
    }
    return completions.toOwnedSlice(allocator);
}

fn completeVariables(allocator: std.mem.Allocator, executor: exec.Executor, prefix: []const u8) ![]Completion {
    var completions: std.ArrayList(Completion) = .empty;
    errdefer freeCompletions(allocator, completions.items);
    var iter = executor.env.iterator();
    while (iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
            try completions.append(allocator, .{ .text = try allocator.dupe(u8, entry.key_ptr.*) });
        }
    }
    return completions.toOwnedSlice(allocator);
}

fn completePaths(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]Completion {
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var completions: std.ArrayList(Completion) = .empty;
    errdefer freeCompletions(allocator, completions.items);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            try completions.append(allocator, .{ .text = try allocator.dupe(u8, entry.name) });
        }
    }
    std.mem.sort(Completion, completions.items, {}, lessThanCompletion);
    return completions.toOwnedSlice(allocator);
}

fn lessThanCompletion(_: void, a: Completion, b: Completion) bool {
    return std.mem.lessThan(u8, a.text, b.text);
}

pub fn freeCompletions(allocator: std.mem.Allocator, completions: []Completion) void {
    for (completions) |completion| allocator.free(completion.text);
    allocator.free(completions);
}

pub fn renderHighlightedInput(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive });
    defer parsed.deinit();
    const highlights = try parser.syntaxHighlights(allocator, parsed);
    defer allocator.free(highlights);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (highlights) |highlight| {
        if (highlight.kind == .eof or highlight.span.isEmpty()) continue;
        try output.appendSlice(allocator, ansiForHighlight(highlight.kind));
        try output.appendSlice(allocator, highlight.span.slice(source));
        try output.appendSlice(allocator, "\x1b[0m");
    }
    return output.toOwnedSlice(allocator);
}

fn ansiForHighlight(kind: parser.HighlightKind) []const u8 {
    return switch (kind) {
        .command => "\x1b[36m",
        .argument => "\x1b[0m",
        .assignment => "\x1b[33m",
        .io_number => "\x1b[35m",
        .operator => "\x1b[90m",
        .redirect => "\x1b[35m",
        .comment => "\x1b[32m",
        .diagnostic_error, .invalid => "\x1b[31m",
        .whitespace, .newline, .eof => "\x1b[0m",
    };
}

pub fn runInteractive(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !u8 {
    installInteractiveSignalHandlers();

    var history = History.init(allocator);
    defer history.deinit();
    history.load(io, ".rush_history") catch {};
    defer history.save(io, ".rush_history") catch {};

    var last_status: exec.ExitStatus = 0;
    var stdin_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    try executor.importEnvironment(environ_map);
    executor.arg_zero = "rush";
    try loadInteractiveConfig(allocator, io, &executor);

    while (true) {
        const prompt = executor.renderPrompt(.{ .io = io, .allow_external = true, .external_stdio = .inherit, .arg_zero = "rush" }, "rush$ ") catch |err| switch (err) {
            error.RecursivePrompt => try allocator.dupe(u8, "rush$ "),
            else => |e| return e,
        };
        try writeAll(io, .stdout, prompt);
        allocator.free(prompt);
        const line = (try reader.interface.takeDelimiter('\n')) orelse break;
        if (std.mem.eql(u8, line, "exit")) break;
        if (line.len == 0) continue;
        try history.add(line);

        var result = try runScriptWithExecutor(allocator, &executor, line, .{ .io = io, .allow_external = true, .external_stdio = .inherit, .arg_zero = "rush" });
        defer result.deinit();
        try writeAll(io, .stdout, result.stdout);
        try writeAll(io, .stderr, result.stderr);
        last_status = result.status;
    }

    return last_status;
}

pub fn runReplInput(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !exec.CommandResult {
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var history = History.init(allocator);
    defer history.deinit();
    var last_status: exec.ExitStatus = 0;
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const prompt = try executor.renderPrompt(.{ .io = io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
        try stdout.appendSlice(allocator, prompt);
        allocator.free(prompt);
        if (std.mem.eql(u8, line, "exit")) break;
        if (line.len == 0) continue;
        try history.add(line);

        var result = try runScriptWithExecutor(allocator, &executor, line, .{ .io = io, .allow_external = true, .arg_zero = "rush" });
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
        last_status = result.status;
    }

    return .{
        .allocator = allocator,
        .status = last_status,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

pub fn runScript(allocator: std.mem.Allocator, io: std.Io, script: []const u8) !exec.CommandResult {
    return runScriptWithOptions(allocator, io, script, .{ .io = io, .allow_external = true });
}

pub fn runScriptWithOptions(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: exec.ExecuteOptions) !exec.CommandResult {
    return runScriptWithEnvironment(allocator, io, script, options, null);
}

pub fn runScriptWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: exec.ExecuteOptions, environ_map: ?*const std.process.Environ.Map) !exec.CommandResult {
    _ = io;
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    if (environ_map) |map| try executor.importEnvironment(map);
    executor.arg_zero = options.arg_zero;

    return runScriptWithExecutor(allocator, &executor, script, options);
}

fn runScriptWithExecutor(allocator: std.mem.Allocator, executor: *exec.Executor, script: []const u8, options: exec.ExecuteOptions) !exec.CommandResult {
    _ = options.io;
    const aliased = try executor.expandAliasesForScript(script);
    defer allocator.free(aliased);
    var parsed = try parser.parse(allocator, aliased, .{});
    defer parsed.deinit();

    if (parsed.diagnostics.len != 0) {
        return diagnosticsResult(allocator, script, parsed.diagnostics);
    }

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();

    var result = try executor.executeProgram(program, options);
    errdefer result.deinit();
    if (executor.shell_options.verbose) {
        const trimmed = std.mem.trim(u8, script, " \t\r\n;");
        const stderr = try std.mem.concat(allocator, u8, &.{ trimmed, "\n", result.stderr });
        allocator.free(result.stderr);
        result.stderr = stderr;
    }
    return result;
}

fn loadInteractiveConfig(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor) !void {
    try sourceOptionalConfig(allocator, io, executor, system_config_path);
    const user_path = try userConfigPath(allocator, executor.*);
    defer if (user_path) |path| allocator.free(path);
    if (user_path) |path| try sourceOptionalConfig(allocator, io, executor, path);
}

fn sourceOptionalConfig(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, path: []const u8) !void {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(contents);

    var result = try runScriptWithExecutor(allocator, executor, contents, .{ .io = io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();
    if (result.stdout.len != 0) try writeAll(io, .stdout, result.stdout);
    if (result.stderr.len != 0) try writeAll(io, .stderr, result.stderr);
}

fn userConfigPath(allocator: std.mem.Allocator, executor: exec.Executor) !?[]const u8 {
    if (executor.getEnv("XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home, "rush", "config.rush" });
    }
    if (executor.getEnv("HOME")) |home| {
        if (home.len != 0) return try std.fs.path.join(allocator, &.{ home, ".config", "rush", "config.rush" });
    }
    return null;
}

fn installInteractiveSignalHandlers() void {
    const sigint_action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleInteractiveSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &sigint_action, null);
}

fn handleInteractiveSigint(_: std.posix.SIG) callconv(.c) void {}

fn diagnosticsResult(allocator: std.mem.Allocator, script: []const u8, diagnostics: []const parser.Diagnostic) !exec.CommandResult {
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);

    for (diagnostics) |diagnostic| {
        const line = try std.fmt.allocPrint(allocator, "rush: {s}: {s}\n", .{
            @tagName(diagnostic.kind),
            diagnostic.message,
        });
        defer allocator.free(line);
        try stderr.appendSlice(allocator, line);
        try appendDiagnosticSource(allocator, &stderr, script, diagnostic.span);
    }

    return .{
        .allocator = allocator,
        .status = 2,
        .stdout = try allocator.alloc(u8, 0),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

fn appendDiagnosticSource(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, span: parser.Span) !void {
    const line_start = findLineStart(source, span.start);
    const line_end = findLineEnd(source, span.start);
    const line = source[line_start..line_end];
    const caret_start = span.start - line_start;
    const caret_end = @max(caret_start + 1, @min(span.end, line_end) - line_start);

    try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "  ");
    try out.appendNTimes(allocator, ' ', caret_start);
    try out.appendNTimes(allocator, '^', caret_end - caret_start);
    try out.append(allocator, '\n');
}

fn findLineStart(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index > 0 and source[index - 1] != '\n') index -= 1;
    return index;
}

fn findLineEnd(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index < source.len and source[index] != '\n') index += 1;
    return index;
}

const OutputStream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: OutputStream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

test "history stores commands and suggests by prefix" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    try history.add("echo first");
    try history.add("git status");
    try history.add("echo second");
    try history.add("echo second");

    try std.testing.expectEqual(@as(usize, 3), history.entries.items.len);
    try std.testing.expectEqualStrings("echo second", history.suggest("ec").?);
    try std.testing.expectEqualStrings("git status", history.suggest("git").?);
    try std.testing.expect(history.suggest("missing") == null);
}

test "history can persist and reload" {
    const path = "rush-history-test.tmp";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.add("echo saved");
    try history.save(std.testing.io, path);

    var loaded = History.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.load(std.testing.io, path);
    try std.testing.expectEqualStrings("echo saved", loaded.suggest("echo").?);
}

test "interactive completion helper suggests commands variables and paths" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("RUSH_COMPLETION_VAR", "ok");

    const command_completions = try completeInput(std.testing.allocator, std.testing.io, executor, "ec", 2);
    defer freeCompletions(std.testing.allocator, command_completions);
    try std.testing.expect(hasCompletion(command_completions, "echo"));

    const variable_completions = try completeInput(std.testing.allocator, std.testing.io, executor, "echo $RUSH", 10);
    defer freeCompletions(std.testing.allocator, variable_completions);
    try std.testing.expect(hasCompletion(variable_completions, "RUSH_COMPLETION_VAR"));

    const path = "rush-complete-path.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const path_completions = try completeInput(std.testing.allocator, std.testing.io, executor, "echo rush-complete", 18);
    defer freeCompletions(std.testing.allocator, path_completions);
    try std.testing.expect(hasCompletion(path_completions, path));
}

fn hasCompletion(completions: []const Completion, text: []const u8) bool {
    for (completions) |completion| {
        if (std.mem.eql(u8, completion.text, text)) return true;
    }
    return false;
}

test "interactive highlight renderer uses parser classifications" {
    const rendered = try renderHighlightedInput(std.testing.allocator, "echo hi > out # comment");
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[36mecho\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[35m>\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[32m# comment\x1b[0m") != null);
}

test "runReplInput executes lines and tracks status" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "echo hi\nfalse\nexit\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("rush$ hi\nrush$ rush$ ", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScriptWithEnvironment imports initial shell variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "present");

    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io, "echo $RUSH_IMPORTED_ENV", .{ .io = std.testing.io, .allow_external = true }, &env);
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("present\n", result.stdout);
}

test "runScriptWithOptions accepts inherit mode for external commands" {
    var result = try runScriptWithOptions(std.testing.allocator, std.testing.io, "/usr/bin/true", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .inherit,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScript executes builtins" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo hello");
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "compatibility feature plumbing accepts Bash mode without changing baseline behavior" {
    var parsed = try parser.parse(std.testing.allocator, "echo ok", .{ .features = .bash() });
    defer parsed.deinit();
    var program = try ir.lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var result = try executor.executeProgram(program, .{ .features = .bash() });
    defer result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ok\n", result.stdout);
}

test "runScript returns parse diagnostics" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo | ");
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing command after pipeline operator") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "echo | ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "     ^") != null);
}

test "parser smoke corpus parses representative snippets" {
    const snippets = [_][]const u8{
        "",
        "   \t  ",
        "echo hello",
        "FOO=bar echo hi",
        "echo 'quoted text' \"double quoted\"",
        "echo hello | cat",
        "false || echo recovered",
        "true && echo ok",
        "echo > out",
        "echo | ",
        "echo 'unterminated",
        "2>err missing-command",
    };

    for (snippets) |snippet| {
        var parsed = try parser.parse(std.testing.allocator, snippet, .{ .mode = .interactive });
        defer parsed.deinit();
        try std.testing.expect(parsed.tokens.len >= 1);
        try std.testing.expect(parsed.nodes.len >= 1);
    }
}

test "executor smoke corpus returns expected statuses and output fragments" {
    const Case = struct {
        script: []const u8,
        status: exec.ExitStatus,
        stdout_contains: []const u8 = "",
        stderr_contains: []const u8 = "",
    };
    const cases = [_]Case{
        .{ .script = "", .status = 0 },
        .{ .script = "true", .status = 0 },
        .{ .script = "false", .status = 1 },
        .{ .script = "echo smoke", .status = 0, .stdout_contains = "smoke\n" },
        .{ .script = "echo smoke | cat", .status = 0, .stdout_contains = "smoke\n" },
        .{ .script = "false || echo recovered", .status = 0, .stdout_contains = "recovered\n" },
        .{ .script = "true && echo ok", .status = 0, .stdout_contains = "ok\n" },
        .{ .script = "missing-command", .status = 127, .stderr_contains = "command not found" },
        .{ .script = "echo | ", .status = 2, .stderr_contains = "missing command after pipeline operator" },
    };

    for (cases) |case| {
        var result = try runScript(std.testing.allocator, std.testing.io, case.script);
        defer result.deinit();
        try std.testing.expectEqual(case.status, result.status);
        if (case.stdout_contains.len != 0) {
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, case.stdout_contains) != null);
        }
        if (case.stderr_contains.len != 0) {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, case.stderr_contains) != null);
        }
    }
}

test "repl expands aliases defined on previous input lines" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\alias ll='echo alias-ok'
        \\ll
        \\alias ll
        \\unalias ll
        \\ll
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("rush$ rush$ alias-ok\nrush$ alias ll='echo alias-ok'\nrush$ rush$ rush$ ", result.stdout);
    try std.testing.expectEqualStrings("ll: command not found\n", result.stderr);
}

test "prompt DSL commands are scoped to prompt rendering" {
    var prompt_result = try runScript(std.testing.allocator, std.testing.io, "prompt text hi");
    defer prompt_result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 127), prompt_result.status);
    try std.testing.expectEqualStrings("prompt: command not found\n", prompt_result.stderr);

    var command_result = try runScript(std.testing.allocator, std.testing.io, "command -v prompt");
    defer command_result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 1), command_result.status);
    try std.testing.expectEqualStrings("", command_result.stdout);
}

test "repl uses rush_prompt function to build prompt text" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\rush_prompt() { prompt segment --fg blue custom; prompt text ' > '; }
        \\echo ok
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush$ custom > ok\ncustom > ", result.stdout);
}

test "user config path prefers XDG_CONFIG_HOME" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("HOME", "/home/example");
    try executor.setEnv("XDG_CONFIG_HOME", "/tmp/xdg");

    const path = (try userConfigPath(std.testing.allocator, executor)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/xdg/rush/config.rush", path);
}

test "user config path falls back to HOME config.rush" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("HOME", "/home/example");

    const path = (try userConfigPath(std.testing.allocator, executor)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/example/.config/rush/config.rush", path);
}

test "integration harness compares selected scripts with /bin/sh" {
    try expectMatchesSh("echo hello");
    try expectMatchesSh("false");
    try expectMatchesSh("echo hello | cat");
    try expectMatchesSh("false || echo yes");
    try expectMatchesSh("true && echo ok");
    try expectMatchesSh("/usr/bin/printf external");
}

test "integration harness checks redirection side effects" {
    const rush_path = "rush-itest-rush-redir.tmp";
    const sh_path = "rush-itest-sh-redir.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, rush_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, sh_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rush_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, sh_path) catch {};

    var rush_result = try runScript(std.testing.allocator, std.testing.io, "echo file > rush-itest-rush-redir.tmp");
    defer rush_result.deinit();
    var sh_result = try runSh(std.testing.allocator, "echo file > rush-itest-sh-redir.tmp");
    defer sh_result.deinit();

    try std.testing.expectEqual(sh_result.status, rush_result.status);
    try std.testing.expectEqualStrings(sh_result.stdout, rush_result.stdout);
    try std.testing.expectEqualStrings(sh_result.stderr, rush_result.stderr);

    const rush_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rush_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(rush_contents);
    const sh_contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, sh_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(sh_contents);
    try std.testing.expectEqualStrings(sh_contents, rush_contents);
}

fn expectMatchesSh(script: []const u8) !void {
    var rush_result = try runScript(std.testing.allocator, std.testing.io, script);
    defer rush_result.deinit();
    var sh_result = try runSh(std.testing.allocator, script);
    defer sh_result.deinit();

    try std.testing.expectEqual(sh_result.status, rush_result.status);
    try std.testing.expectEqualStrings(sh_result.stdout, rush_result.stdout);
    try std.testing.expectEqualStrings(sh_result.stderr, rush_result.stderr);
}

fn runSh(allocator: std.mem.Allocator, script: []const u8) !exec.CommandResult {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", script },
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    return .{
        .allocator = allocator,
        .status = processStatus(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn processStatus(term: std.process.Child.Term) exec.ExitStatus {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .stopped => |sig| 128 + @as(u8, @intCast(@intFromEnum(sig))),
        .unknown => 1,
    };
}

test {
    std.testing.refAllDecls(compat);
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(expand);
    std.testing.refAllDecls(ir);
    std.testing.refAllDecls(exec);
}
