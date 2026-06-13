//! Application entry point.

const std = @import("std");
const build_options = @import("builtin");
const build_config = @import("build_config");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*:0]u8, termp: ?*const std.posix.termios, winp: ?*const anyopaque) c_int;

pub const compat = @import("compat.zig");
pub const parser = @import("parser.zig");
pub const expand = @import("expand.zig");
pub const ir = @import("ir.zig");
pub const exec = @import("exec.zig");
pub const history_module = @import("history.zig");
pub const shell = @import("shell.zig");
pub const runtime = @import("runtime.zig");
pub const line_editor = @import("line_editor.zig");
pub const editor_driver = @import("editor_driver.zig");
pub const completion_model = @import("completion.zig");
pub const event_loop = @import("event_loop.zig");

const usage =
    \\usage: rush [--login]
    \\       rush [-i] [--posix-strict] [set-options]
    \\       rush [-i] [--posix-strict] [set-options] -c SCRIPT [NAME [ARGS...]]
    \\       rush [-i] [--posix-strict] [set-options] -s [ARGS...]
    \\       rush [-i] [--posix-strict] [set-options] SCRIPT_FILE [ARGS...]
    \\       rush complete --debug INPUT
    \\       rush complete --debug-json INPUT
    \\       rush complete trace INPUT
    \\       rush complete trace --json INPUT
    \\       rush complete validate [PATH]
    \\       rush --help
    \\
;

const system_profile_path = build_config.sysconfdir ++ "/rush/profile.rush";
const system_config_path = build_config.sysconfdir ++ "/rush/config.rush";
const embedded_config = @embedFile("default_config");
const embedded_config_path = "embedded:config.rush";
const omitted_newline_marker = "\x1b[2m⏎\x1b[22m\r\n";
const ignoreeof_message = "Use \"exit\" to leave the shell.\r\n";
const immediate_notify_poll_ms = 50;

pub const CommandResult = struct {
    allocator: std.mem.Allocator,
    status: shell.ExitStatus,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

const InvocationKind = enum { command_string, script_file, standard_input };

const ShellInvocation = struct {
    kind: InvocationKind,
    source: []const u8,
    features: compat.Features = .{},
    shell_options: shell.ShellOptions = .{},
    monitor_option_explicit: bool = false,
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
    interactive: bool = false,
};

const CommandStringInvocation = ShellInvocation;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const login_shell = isLoginArgZero(args[0]);

    if (args.len == 1 and stdinIsTty(init.io)) {
        var completion_debug_allocator: if (build_options.mode == .Debug) std.heap.DebugAllocator(.{}) else void = if (build_options.mode == .Debug) .init else {};
        defer if (build_options.mode == .Debug) {
            _ = completion_debug_allocator.deinit();
        };
        const completion_allocator = if (build_options.mode == .Debug) completion_debug_allocator.allocator() else std.heap.smp_allocator;
        return runInteractive(allocator, completion_allocator, init.io, init.environ_map, .{ .arg_zero = args[0], .login = login_shell });
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--login")) {
        var completion_debug_allocator: if (build_options.mode == .Debug) std.heap.DebugAllocator(.{}) else void = if (build_options.mode == .Debug) .init else {};
        defer if (build_options.mode == .Debug) {
            _ = completion_debug_allocator.deinit();
        };
        const completion_allocator = if (build_options.mode == .Debug) completion_debug_allocator.allocator() else std.heap.smp_allocator;
        return runInteractive(allocator, completion_allocator, init.io, init.environ_map, .{ .arg_zero = args[0], .login = true });
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try writeAll(init.io, .stdout, usage);
        return 0;
    }

    if (args.len == 4 and std.mem.eql(u8, args[1], "complete") and std.mem.eql(u8, args[2], "--debug")) {
        try debugCompletion(allocator, init.io, init.environ_map, args[3], .text);
        return 0;
    }

    if (args.len == 4 and std.mem.eql(u8, args[1], "complete") and std.mem.eql(u8, args[2], "trace")) {
        try debugCompletion(allocator, init.io, init.environ_map, args[3], .text);
        return 0;
    }

    if (args.len == 5 and std.mem.eql(u8, args[1], "complete") and std.mem.eql(u8, args[2], "trace") and std.mem.eql(u8, args[3], "--json")) {
        try debugCompletion(allocator, init.io, init.environ_map, args[4], .json);
        return 0;
    }

    if (args.len == 4 and std.mem.eql(u8, args[1], "complete") and std.mem.eql(u8, args[2], "--debug-json")) {
        try debugCompletion(allocator, init.io, init.environ_map, args[3], .json);
        return 0;
    }

    if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "complete") and std.mem.eql(u8, args[2], "validate")) {
        const dir = if (args.len == 4) args[3] else "share/rush/completions";
        return validateCompletionScripts(allocator, init.io, dir);
    }

    const invocation: ShellInvocation = if (args.len == 1) .{
        .kind = .standard_input,
        .source = "-",
        .arg_zero = args[0],
    } else parseShellInvocation(args) orelse {
        try writeAll(init.io, .stderr, usage);
        return 2;
    };

    if (shouldRunInteractiveStandardInput(invocation, stdinIsTty(init.io), stderrIsTty(init.io))) {
        var completion_debug_allocator: if (build_options.mode == .Debug) std.heap.DebugAllocator(.{}) else void = if (build_options.mode == .Debug) .init else {};
        defer if (build_options.mode == .Debug) {
            _ = completion_debug_allocator.deinit();
        };
        const completion_allocator = if (build_options.mode == .Debug) completion_debug_allocator.allocator() else std.heap.smp_allocator;
        return runInteractive(allocator, completion_allocator, init.io, init.environ_map, .{
            .arg_zero = invocation.arg_zero,
            .login = login_shell,
            .features = invocation.features,
            .shell_options = invocation.shell_options,
            .monitor_option_explicit = invocation.monitor_option_explicit,
            .positionals = invocation.positionals,
        });
    }

    var result = runShellInvocationWithEnvironment(allocator, init.io, invocation, init.environ_map, .inherit, login_shell) catch |err| switch (err) {
        error.FileNotFound => {
            try writeScriptReadError(init.io, invocation.source, "file not found");
            return 2;
        },
        error.AccessDenied, error.PermissionDenied => {
            try writeScriptReadError(init.io, invocation.source, "permission denied");
            return 2;
        },
        error.IsDir => {
            try writeScriptReadError(init.io, invocation.source, "is a directory");
            return 2;
        },
        else => |e| return e,
    };
    defer result.deinit();

    try writeAll(init.io, .stdout, result.stdout);
    try writeAll(init.io, .stderr, result.stderr);
    return result.status;
}

fn parseCommandStringInvocation(args: []const []const u8) ?CommandStringInvocation {
    const invocation = parseShellInvocation(args) orelse return null;
    if (invocation.kind != .command_string) return null;
    return invocation;
}

fn parseShellInvocation(args: []const []const u8) ?ShellInvocation {
    std.debug.assert(args.len != 0);

    var features: compat.Features = .{};
    var shell_options: shell.ShellOptions = .{};
    var monitor_option_explicit = false;
    var interactive = false;
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
                interactive = true;
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
        return .{ .kind = .command_string, .source = operands[0], .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = arg_zero, .positionals = positionals, .interactive = interactive };
    }
    if (standard_input) {
        return .{ .kind = .standard_input, .source = "-", .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = args[0], .positionals = operands, .interactive = interactive };
    }
    if (operands.len != 0) {
        const path = operands[0];
        return .{ .kind = .script_file, .source = path, .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = path, .positionals = operands[1..], .interactive = interactive };
    }
    return .{ .kind = .standard_input, .source = "-", .features = features, .shell_options = shell_options, .monitor_option_explicit = monitor_option_explicit, .arg_zero = args[0], .interactive = interactive };
}

pub const History = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(HistoryRecord) = .empty,
    entries: std.ArrayList([]const u8) = .empty,
    hostname: []const u8 = "",
    session_id: []const u8 = "",
    current_cwd: []const u8 = "",
    db: ?*sqlite.sqlite3 = null,

    pub const HistoryRecord = struct {
        cmd: []const u8,
        when: i64 = 0,
        status: shell.ExitStatus = 0,
        exit_signal: ?u8 = null,
        cwd: []const u8 = "",
        duration_ms: ?i64 = null,
        hostname: []const u8 = "",
        session_id: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        if (self.db) |db| _ = sqlite.sqlite3_close(db);
        for (self.records.items) |record| {
            self.allocator.free(record.cmd);
            self.allocator.free(record.cwd);
            self.allocator.free(record.hostname);
            self.allocator.free(record.session_id);
        }
        self.records.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        if (self.hostname.len != 0) self.allocator.free(self.hostname);
        self.* = undefined;
    }

    pub fn copyFrom(self: *History, other: *const History) !void {
        self.* = .init(self.allocator);
        self.session_id = other.session_id;
        if (other.db) |db| {
            try self.loadRecentRows(db, 500);
            return;
        }
        for (other.records.items) |record| {
            try self.addRecord(.{
                .cmd = record.cmd,
                .when = record.when,
                .status = record.status,
                .exit_signal = record.exit_signal,
                .cwd = record.cwd,
                .duration_ms = record.duration_ms,
                .hostname = record.hostname,
                .session_id = record.session_id,
            });
        }
    }

    pub fn add(self: *History, line: []const u8) !void {
        try self.addRecord(.{ .cmd = line });
    }

    pub fn addCommand(self: *History, io: std.Io, line: []const u8, status: shell.ExitStatus, started_at: i64, duration_ms: i64) !void {
        try self.addCommandRecord(io, line, status, started_at, duration_ms, true);
    }

    pub fn appendCommand(self: *History, io: std.Io, line: []const u8, status: shell.ExitStatus, started_at: i64, duration_ms: i64) !void {
        try self.addCommandRecord(io, line, status, started_at, duration_ms, false);
    }

    fn addCommandRecord(self: *History, io: std.Io, line: []const u8, status: shell.ExitStatus, started_at: i64, duration_ms: i64, dedupe: bool) !void {
        if (line.len == 0) return;
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        const cwd = cwd_buffer[0..cwd_len];
        const record: HistoryRecord = .{
            .cmd = line,
            .when = started_at,
            .status = status,
            .exit_signal = exitSignalFromStatus(status),
            .cwd = cwd,
            .duration_ms = duration_ms,
            .hostname = self.hostname,
            .session_id = self.session_id,
        };
        if (self.db) |db| {
            try insertHistoryRecord(db, record);
            return;
        }
        if (dedupe) try self.addRecord(record) else try self.appendRecord(record);
    }

    fn addRecord(self: *History, record: HistoryRecord) !void {
        if (record.cmd.len == 0) return;
        if (self.entries.items.len != 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], record.cmd)) return;
        try self.appendRecord(record);
    }

    fn appendRecord(self: *History, record: HistoryRecord) !void {
        if (record.cmd.len == 0) return;
        const cmd = try self.allocator.dupe(u8, record.cmd);
        errdefer self.allocator.free(cmd);
        const cwd = try self.allocator.dupe(u8, record.cwd);
        errdefer self.allocator.free(cwd);
        const hostname = try self.allocator.dupe(u8, record.hostname);
        errdefer self.allocator.free(hostname);
        const session_id = try self.allocator.dupe(u8, record.session_id);
        errdefer self.allocator.free(session_id);
        try self.records.append(self.allocator, .{
            .cmd = cmd,
            .when = record.when,
            .status = record.status,
            .exit_signal = record.exit_signal,
            .cwd = cwd,
            .duration_ms = record.duration_ms,
            .hostname = hostname,
            .session_id = session_id,
        });
        try self.entries.append(self.allocator, cmd);
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
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        var db: ?*sqlite.sqlite3 = null;
        try sqliteCheck(sqlite.sqlite3_open_v2(path_z.ptr, &db, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX, null), db);
        errdefer if (db) |handle| {
            _ = sqlite.sqlite3_close(handle);
        };
        const handle = db.?;
        try configureHistoryDb(handle);
        try initHistorySchema(handle);
        self.hostname = try localHostname(self.allocator);
        if (build_options.is_test) try self.loadRecentRows(handle, 10_000);
        self.db = handle;
    }

    pub fn save(self: History, io: std.Io, path: []const u8) !void {
        if (self.db != null) return;
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        var db: ?*sqlite.sqlite3 = null;
        try sqliteCheck(sqlite.sqlite3_open_v2(path_z.ptr, &db, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX, null), db);
        defer if (db) |handle| {
            _ = sqlite.sqlite3_close(handle);
        };
        const handle = db.?;
        try configureHistoryDb(handle);
        try initHistorySchema(handle);
        try sqliteExec(handle, "delete from history;");
        for (self.records.items) |record| try insertHistoryRecord(handle, record);
    }

    fn loadRecentRows(self: *History, db: *sqlite.sqlite3, limit: usize) !void {
        var stmt: ?*sqlite.sqlite3_stmt = null;
        try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "select command, started_at, status, cwd, exit_signal, duration_ms, hostname, session_id from history order by id desc limit ?1", -1, &stmt, null), db);
        defer _ = sqlite.sqlite3_finalize(stmt);
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, @intCast(limit)), db);
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const command_text = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const cwd_text = sqlite.sqlite3_column_text(stmt, 3) orelse @as([*c]const u8, @ptrCast(""));
            const hostname_text = sqlite.sqlite3_column_text(stmt, 6) orelse @as([*c]const u8, @ptrCast(""));
            const session_id_text = sqlite.sqlite3_column_text(stmt, 7) orelse @as([*c]const u8, @ptrCast(""));
            try self.addRecord(.{
                .cmd = std.mem.span(command_text),
                .when = sqlite.sqlite3_column_int64(stmt, 1),
                .status = @intCast(sqlite.sqlite3_column_int(stmt, 2)),
                .exit_signal = if (sqlite.sqlite3_column_type(stmt, 4) == sqlite.SQLITE_NULL) null else @intCast(sqlite.sqlite3_column_int(stmt, 4)),
                .cwd = std.mem.span(cwd_text),
                .duration_ms = if (sqlite.sqlite3_column_type(stmt, 5) == sqlite.SQLITE_NULL) null else sqlite.sqlite3_column_int64(stmt, 5),
                .hostname = std.mem.span(hostname_text),
                .session_id = std.mem.span(session_id_text),
            });
        }
    }

    pub fn previousEntry(self: *History, allocator: std.mem.Allocator, prefix: []const u8, cwd: []const u8, session_id: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(db, allocator, prefix, cwd, session_id, before, .previous);
    }

    pub fn nextEntry(self: *History, allocator: std.mem.Allocator, prefix: []const u8, cwd: []const u8, session_id: []const u8, after: i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(db, allocator, prefix, cwd, session_id, after, .next);
    }

    pub fn numberedEntry(self: *History, allocator: std.mem.Allocator, number: usize) !?line_editor.HistoryView.HistoryEntry {
        if (number == 0) return null;
        if (self.db) |db| return queryHistoryEntryByNumber(db, allocator, number);
        const index = number - 1;
        if (index >= self.entries.items.len) return null;
        return .{ .id = @intCast(index), .text = try allocator.dupe(u8, self.entries.items[index]) };
    }

    pub fn fcEntries(self: *History, allocator: std.mem.Allocator) ![]exec.HistoryEntry {
        if (self.db) |db| return queryFcHistoryEntries(db, allocator);
        var entries: std.ArrayList(exec.HistoryEntry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.command);
            entries.deinit(allocator);
        }
        for (self.entries.items, 0..) |entry, index| {
            try entries.append(allocator, .{
                .number = @intCast(index + 1),
                .command = try allocator.dupe(u8, entry),
            });
        }
        return entries.toOwnedSlice(allocator);
    }

    pub fn searchEntry(self: *History, allocator: std.mem.Allocator, query: []const u8, cwd: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistorySearchEntry(db, allocator, query, cwd, before, .previous);
    }

    pub fn searchNextEntry(self: *History, allocator: std.mem.Allocator, query: []const u8, cwd: []const u8, after: ?i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistorySearchEntry(db, allocator, query, cwd, after, .next);
    }

    pub fn suggestEntry(self: *History, allocator: std.mem.Allocator, prefix: []const u8, cwd: []const u8) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(db, allocator, prefix, cwd, "", null, .previous);
    }
};

const InteractiveHistoryService = struct {
    history: *History,

    fn init(history: *History) InteractiveHistoryService {
        return .{ .history = history };
    }

    fn attachFc(self: *InteractiveHistoryService, executor: *exec.Executor) void {
        executor.setCommandHistory(.{
            .context = self,
            .list = fcHistoryEntries,
            .append = appendFcHistoryCommand,
        });
    }

    fn lineEditorView(self: *InteractiveHistoryService, io: std.Io) line_editor.HistoryView {
        return .{
            .now = unixTimestamp(io),
            .context = self,
            .previous = previousHistoryEntry,
            .next = nextHistoryEntry,
            .by_number = numberedHistoryEntry,
            .search = searchHistoryEntry,
            .search_next = searchNextHistoryEntry,
            .suggest = suggestHistoryEntry,
        };
    }

    fn addCommand(self: *InteractiveHistoryService, io: std.Io, line: []const u8, status: shell.ExitStatus, started_at: i64, duration_ms: i64) !void {
        try self.history.addCommand(io, line, status, started_at, duration_ms);
    }

    fn consumeSuppressNextAppend(_: *InteractiveHistoryService, executor: *exec.Executor) bool {
        return executor.consumeSuppressNextInteractiveHistoryAppend();
    }

    fn previousEntry(self: *InteractiveHistoryService, allocator: std.mem.Allocator, prefix: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
        return self.history.previousEntry(allocator, prefix, self.history.current_cwd, self.history.session_id, before);
    }

    fn nextEntry(self: *InteractiveHistoryService, allocator: std.mem.Allocator, prefix: []const u8, after: i64) !?line_editor.HistoryView.HistoryEntry {
        return self.history.nextEntry(allocator, prefix, self.history.current_cwd, self.history.session_id, after);
    }

    fn numberedEntry(self: *InteractiveHistoryService, allocator: std.mem.Allocator, number: usize) !?line_editor.HistoryView.HistoryEntry {
        return self.history.numberedEntry(allocator, number);
    }

    fn fcEntries(self: *InteractiveHistoryService, allocator: std.mem.Allocator) ![]exec.HistoryEntry {
        return self.history.fcEntries(allocator);
    }

    fn appendFcCommand(self: *InteractiveHistoryService, io: std.Io, line: []const u8, status: shell.ExitStatus, started_at: i64, duration_ms: i64) !void {
        try self.history.appendCommand(io, line, status, started_at, duration_ms);
    }

    fn searchEntry(self: *InteractiveHistoryService, allocator: std.mem.Allocator, query: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
        return self.history.searchEntry(allocator, query, self.history.current_cwd, before);
    }

    fn searchNextEntry(self: *InteractiveHistoryService, allocator: std.mem.Allocator, query: []const u8, after: ?i64) !?line_editor.HistoryView.HistoryEntry {
        return self.history.searchNextEntry(allocator, query, self.history.current_cwd, after);
    }

    fn suggestEntry(self: *InteractiveHistoryService, allocator: std.mem.Allocator, prefix: []const u8) !?line_editor.HistoryView.HistoryEntry {
        return self.history.suggestEntry(allocator, prefix, self.history.current_cwd);
    }
};

fn previousHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.previousEntry(allocator, prefix, before);
}

fn nextHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8, after: i64) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.nextEntry(allocator, prefix, after);
}

fn numberedHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, number: usize) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.numberedEntry(allocator, number);
}

fn fcHistoryEntries(context: *anyopaque, allocator: std.mem.Allocator) ![]exec.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.fcEntries(allocator);
}

fn appendFcHistoryCommand(context: *anyopaque, io: std.Io, line: []const u8, status: shell.ExitStatus, started_at: i64, duration_ms: i64) !void {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    try history_service.appendFcCommand(io, line, status, started_at, duration_ms);
}

fn searchHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, query: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.searchEntry(allocator, query, before);
}

fn searchNextHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, query: []const u8, after: ?i64) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.searchNextEntry(allocator, query, after);
}

fn suggestHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.suggestEntry(allocator, prefix);
}

const HistoryDirection = enum { previous, next };

fn queryHistoryEntry(db: *sqlite.sqlite3, allocator: std.mem.Allocator, prefix: []const u8, cwd: []const u8, session_id: []const u8, cursor: ?i64, direction: HistoryDirection) !?line_editor.HistoryView.HistoryEntry {
    var like_pattern: std.ArrayList(u8) = .empty;
    defer like_pattern.deinit(allocator);
    try appendSqlLikePrefix(allocator, &like_pattern, prefix);

    const sql = switch (direction) {
        .previous =>
        \\select id, command, started_at from history h
        \\where (?1 is null or id < ?1)
        \\  and (?2 = '' or command like ?2 escape '\')
        \\  and (?3 = '' or h.cwd = ?3)
        \\  and (?4 = '' or h.session_id = ?4)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command = h.command
        \\      and (?2 = '' or newer.command like ?2 escape '\')
        \\      and (?3 = '' or newer.cwd = ?3)
        \\      and (?4 = '' or newer.session_id = ?4)
        \\  )
        \\order by id desc limit 1
        ,
        .next =>
        \\select id, command, started_at from history h
        \\where id > ?1
        \\  and (?2 = '' or command like ?2 escape '\')
        \\  and (?3 = '' or h.cwd = ?3)
        \\  and (?4 = '' or h.session_id = ?4)
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command = h.command
        \\      and (?2 = '' or newer.command like ?2 escape '\')
        \\      and (?3 = '' or newer.cwd = ?3)
        \\      and (?4 = '' or newer.session_id = ?4)
        \\  )
        \\order by id asc limit 1
        ,
    };
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    if (cursor) |id| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, id), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 1), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, like_pattern.items.ptr, @intCast(like_pattern.items.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 3, cwd.ptr, @intCast(cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 4, session_id.ptr, @intCast(session_id.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{ .id = sqlite.sqlite3_column_int64(stmt, 0), .text = try allocator.dupe(u8, std.mem.span(command_text)), .when = sqlite.sqlite3_column_int64(stmt, 2) };
}

fn queryHistoryEntryByNumber(db: *sqlite.sqlite3, allocator: std.mem.Allocator, number: usize) !?line_editor.HistoryView.HistoryEntry {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "select id, command, started_at from history where id = ?1", -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, @intCast(number)), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{ .id = sqlite.sqlite3_column_int64(stmt, 0), .text = try allocator.dupe(u8, std.mem.span(command_text)), .when = sqlite.sqlite3_column_int64(stmt, 2) };
}

fn queryFcHistoryEntries(db: *sqlite.sqlite3, allocator: std.mem.Allocator) ![]exec.HistoryEntry {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "select id, command from history order by id asc", -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var entries: std.ArrayList(exec.HistoryEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.command);
        entries.deinit(allocator);
    }
    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
        const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse continue;
        try entries.append(allocator, .{
            .number = sqlite.sqlite3_column_int64(stmt, 0),
            .command = try allocator.dupe(u8, std.mem.span(command_text)),
        });
    }
    return entries.toOwnedSlice(allocator);
}

fn appendSqlLikePrefix(allocator: std.mem.Allocator, pattern: *std.ArrayList(u8), prefix: []const u8) !void {
    for (prefix) |byte| switch (byte) {
        '%', '_', '\\' => {
            try pattern.append(allocator, '\\');
            try pattern.append(allocator, byte);
        },
        else => try pattern.append(allocator, byte),
    };
    try pattern.append(allocator, '%');
}

fn queryHistorySearchEntry(db: *sqlite.sqlite3, allocator: std.mem.Allocator, query: []const u8, cwd: []const u8, cursor: ?i64, direction: HistoryDirection) !?line_editor.HistoryView.HistoryEntry {
    var fts_query: std.ArrayList(u8) = .empty;
    defer fts_query.deinit(allocator);
    try appendHistoryFtsQuery(allocator, &fts_query, query);
    if (fts_query.items.len == 0) return queryHistoryEntry(db, allocator, "", cwd, "", cursor, direction);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    const offset = if (cursor) |value| @max(value, 0) else 0;
    const sql = switch (direction) {
        .previous =>
        \\select h.id, h.command, h.started_at
        \\from history_fts f
        \\join history h on h.id = f.rowid
        \\where history_fts match ?1
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command = h.command
        \\      and ((newer.cwd = ?2 and h.cwd <> ?2) or ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id))
        \\  )
        \\order by (h.cwd = ?2) desc, bm25(history_fts), h.id desc
        \\limit 1 offset ?3
        ,
        .next =>
        \\select h.id, h.command, h.started_at
        \\from history_fts f
        \\join history h on h.id = f.rowid
        \\where history_fts match ?1
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.command = h.command
        \\      and ((newer.cwd = ?2 and h.cwd <> ?2) or ((newer.cwd = ?2) = (h.cwd = ?2) and newer.id > h.id))
        \\  )
        \\order by (h.cwd = ?2) asc, bm25(history_fts) desc, h.id asc
        \\limit 1 offset ?3
        ,
    };
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, fts_query.items.ptr, @intCast(fts_query.items.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, cwd.ptr, @intCast(cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 3, offset), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{ .id = offset + 1, .text = try allocator.dupe(u8, std.mem.span(command_text)), .when = sqlite.sqlite3_column_int64(stmt, 2) };
}

fn appendHistoryFtsQuery(allocator: std.mem.Allocator, output: *std.ArrayList(u8), query: []const u8) !void {
    var token_start: ?usize = null;
    for (query, 0..) |byte, index| {
        if (historyFtsTokenByte(byte)) {
            if (token_start == null) token_start = index;
        } else if (token_start) |start| {
            try appendHistoryFtsQueryToken(allocator, output, query[start..index]);
            token_start = null;
        }
    }
    if (token_start) |start| try appendHistoryFtsQueryToken(allocator, output, query[start..]);
}

fn historyFtsTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn appendHistoryFtsQueryToken(allocator: std.mem.Allocator, output: *std.ArrayList(u8), token: []const u8) !void {
    if (token.len == 0) return;
    if (output.items.len != 0) try output.append(allocator, ' ');
    try output.append(allocator, '"');
    try output.appendSlice(allocator, token);
    try output.appendSlice(allocator, "\"*");
}

fn configureHistoryDb(db: *sqlite.sqlite3) !void {
    try sqliteExec(db,
        \\pragma busy_timeout = 5000;
        \\pragma journal_mode = wal;
        \\pragma synchronous = normal;
        \\pragma foreign_keys = on;
        \\pragma temp_store = memory;
    );
}

fn initHistorySchema(db: *sqlite.sqlite3) !void {
    if (sqlite.sqlite3_compileoption_used("ENABLE_FTS5") == 0) return error.SqliteFts5Unavailable;
    try sqliteExec(db,
        \\create table if not exists history (
        \\  id integer primary key,
        \\  command text not null,
        \\  cwd text not null,
        \\  status integer not null,
        \\  exit_signal integer,
        \\  started_at integer not null,
        \\  duration_ms integer,
        \\  hostname text not null default '',
        \\  session_id text not null default ''
        \\);
        \\create virtual table if not exists history_fts using fts5(
        \\  command,
        \\  content='history',
        \\  content_rowid='id'
        \\);
        \\create trigger if not exists history_ai after insert on history begin
        \\  insert into history_fts(rowid, command) values (new.id, new.command);
        \\end;
        \\create trigger if not exists history_ad after delete on history begin
        \\  insert into history_fts(history_fts, rowid, command) values('delete', old.id, old.command);
        \\end;
        \\create trigger if not exists history_au after update on history begin
        \\  insert into history_fts(history_fts, rowid, command) values('delete', old.id, old.command);
        \\  insert into history_fts(rowid, command) values (new.id, new.command);
        \\end;
        \\create index if not exists history_started_idx on history(started_at);
        \\create index if not exists history_command_started_idx on history(command, started_at);
        \\create table if not exists history_meta (
        \\  key text primary key,
        \\  value text not null
        \\);
    );
    addHistoryColumn(db, "exit_signal", "integer") catch {};
    addHistoryColumn(db, "duration_ms", "integer") catch {};
    addHistoryColumn(db, "hostname", "text not null default ''") catch {};
    addHistoryColumn(db, "session_id", "text not null default ''") catch {};
    if (try historyFtsNeedsRebuild(db)) {
        try sqliteExec(db, "insert into history_fts(history_fts) values('rebuild');");
    }
}

fn historyFtsNeedsRebuild(db: *sqlite.sqlite3) !bool {
    const migration_done = try sqliteScalarInt(db, "select count(*) from history_meta where key = 'history_fts_rebuilt'");
    if (migration_done != 0) return false;
    try sqliteExec(db, "insert or replace into history_meta(key, value) values ('history_fts_rebuilt', '1');");
    return (try sqliteScalarInt(db, "select count(*) from history")) != 0;
}

fn addHistoryColumn(db: *sqlite.sqlite3, comptime name: []const u8, comptime column_type: []const u8) !void {
    try sqliteExec(db, "alter table history add column " ++ name ++ " " ++ column_type ++ ";");
}

fn insertHistoryRecord(db: *sqlite.sqlite3, record: History.HistoryRecord) !void {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "insert into history(command, cwd, status, exit_signal, started_at, duration_ms, hostname, session_id) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)", -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, record.cmd.ptr, @intCast(record.cmd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, record.cwd.ptr, @intCast(record.cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 3, record.status), db);
    if (record.exit_signal) |signal| {
        try sqliteCheck(sqlite.sqlite3_bind_int(stmt, 4, signal), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 4), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 5, record.when), db);
    if (record.duration_ms) |duration_ms| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 6, duration_ms), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 6), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 7, record.hostname.ptr, @intCast(record.hostname.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 8, record.session_id.ptr, @intCast(record.session_id.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_DONE) try sqliteCheck(rc, db);
}

fn sqliteExec(db: *sqlite.sqlite3, sql: [:0]const u8) !void {
    var message: [*c]u8 = null;
    const rc = sqlite.sqlite3_exec(db, sql.ptr, null, null, &message);
    if (message) |text| sqlite.sqlite3_free(text);
    try sqliteCheck(rc, db);
}

fn sqliteCheck(rc: c_int, db: ?*sqlite.sqlite3) !void {
    switch (rc) {
        sqlite.SQLITE_OK, sqlite.SQLITE_ROW, sqlite.SQLITE_DONE => {},
        else => {
            _ = db;
            return error.SqliteError;
        },
    }
}

fn sqliteScalarInt(db: *sqlite.sqlite3, sql: [:0]const u8) !i64 {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    return sqlite.sqlite3_column_int64(stmt, 0);
}

fn historyFtsMatchCount(db: *sqlite.sqlite3, query: []const u8) !c_int {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "select count(*) from history_fts where history_fts match ?1", -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, query.ptr, @intCast(query.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    return sqlite.sqlite3_column_int(stmt, 0);
}

fn localHostname(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&buffer) catch return allocator.dupe(u8, "");
    return allocator.dupe(u8, hostname);
}

fn historySessionId(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const pid = std.c.getpid();
    const started_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return std.fmt.allocPrint(allocator, "{d}:{d}", .{ pid, started_ns });
}

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn monotonicTimestamp(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn durationMillis(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) i64 {
    return @max(start.durationTo(end).raw.toMilliseconds(), 0);
}

fn exitSignalFromStatus(status: shell.ExitStatus) ?u8 {
    if (status < 128) return null;
    return status - 128;
}

const InteractiveCompletionContext = struct {
    executor: *exec.Executor,
    history: *const History,
    cache: *CompletionCache,
    loader: *CompletionScriptLoader,
    io: std.Io,
    cwd: []const u8 = "",
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},
    owned_executor: ?*exec.Executor = null,
    owned_history: ?*History = null,
    owned_cache: ?*CompletionCache = null,
    owned_loader: ?*CompletionScriptLoader = null,
    owned_cwd: ?[]u8 = null,
    cancel: ?*completion_model.CancellationToken = null,

    fn promptService(self: InteractiveCompletionContext) InteractivePromptService {
        return .{ .executor = self.executor, .arg_zero = self.arg_zero, .features = self.features };
    }
};

const InteractivePromptService = struct {
    executor: *exec.Executor,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},

    fn render(self: InteractivePromptService, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        const fallback_prompt = self.executor.getEnv("PS1") orelse "$ ";
        return self.renderWithFallback(allocator, io, fallback_prompt);
    }

    fn renderWithFallback(self: InteractivePromptService, allocator: std.mem.Allocator, io: std.Io, fallback_prompt: []const u8) ![]const u8 {
        return self.executor.renderPrompt(.{
            .io = io,
            .allow_external = true,
            .features = self.features,
            .external_stdio = .inherit,
            .arg_zero = self.arg_zero,
        }, fallback_prompt) catch |err| switch (err) {
            error.RecursivePrompt => try allocator.dupe(u8, fallback_prompt),
            else => |e| return e,
        };
    }

    fn refreshIntervalMs(self: InteractivePromptService) ?u64 {
        return self.executor.promptRefreshIntervalMs();
    }

    fn runEventHooks(self: InteractivePromptService, io: std.Io, event: []const u8, args: []const []const u8) !void {
        try self.executor.runPromptEventHooks(io, event, args);
    }

    fn runPendingVariableHooks(self: InteractivePromptService, io: std.Io) !void {
        try self.executor.runPendingVariableHooks(io);
    }

    fn intervalWaitMs(self: InteractivePromptService, io: std.Io) ?u64 {
        return self.executor.promptIntervalWaitMs(io);
    }

    fn runDueIntervals(self: InteractivePromptService, io: std.Io) !void {
        try self.executor.runDuePromptIntervals(io);
    }

    fn applyColorScheme(self: InteractivePromptService, io: std.Io, scheme: editor_driver.ColorScheme) !void {
        try self.executor.setRushStateVariable("rush_color_scheme", colorSchemeName(scheme));
        try self.runStyleHook(io);
    }

    fn applyColorReport(self: InteractivePromptService, io: std.Io, report: editor_driver.ColorReport) !void {
        const variable = colorReportVariable(report) orelse return;
        var value_buffer: [8]u8 = undefined;
        const value = try std.fmt.bufPrint(&value_buffer, "#{x:0>2}{x:0>2}{x:0>2}", .{ report.value[0], report.value[1], report.value[2] });
        try self.executor.setRushStateVariable(variable, value);
        try self.runStyleHook(io);
    }

    fn theme(self: InteractivePromptService) line_editor.UiTheme {
        var ui_theme: line_editor.UiTheme = .{};
        self.applyUiStyleVariable(&ui_theme.completion_selected, "rush_style_completion_selected");
        self.applyUiStyleVariable(&ui_theme.completion_directory, "rush_style_completion_directory");
        self.applyUiStyleVariable(&ui_theme.completion_option, "rush_style_completion_option");
        self.applyUiStyleVariable(&ui_theme.completion_variable, "rush_style_completion_variable");
        self.applyUiStyleVariable(&ui_theme.completion_function, "rush_style_completion_function");
        self.applyUiStyleVariable(&ui_theme.completion_file, "rush_style_completion_file");
        self.applyUiStyleVariable(&ui_theme.completion_description, "rush_style_completion_description");
        self.applyUiStyleVariable(&ui_theme.completion_flash, "rush_style_completion_flash");
        self.applyUiStyleVariable(&ui_theme.history_match, "rush_style_history_match");
        self.applyUiStyleVariable(&ui_theme.autosuggestion, "rush_style_autosuggestion");
        self.applyUiStyleVariable(&ui_theme.diagnostic_error, "rush_style_diagnostic_error");
        return ui_theme;
    }

    fn runStyleHook(self: InteractivePromptService, io: std.Io) !void {
        if (!self.executor.hasFunction("rush_style")) return;
        const style_options: exec.ExecuteOptions = .{ .io = io, .allow_external = true, .external_stdio = .capture, .arg_zero = self.arg_zero };
        var result = try self.executor.executeScriptSlice("rush_style", style_options);
        defer result.deinit();
    }

    fn applyUiStyleVariable(self: InteractivePromptService, style: *line_editor.UiStyle, name: []const u8) void {
        const value = self.executor.getEnv(name) orelse return;
        style.* = line_editor.parseUiStyle(value) orelse style.*;
    }
};

fn cloneInteractiveCompletionContext(context: *anyopaque, allocator: std.mem.Allocator, cancel: *completion_model.CancellationToken) !*anyopaque {
    const source: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    const cloned = try allocator.create(InteractiveCompletionContext);
    errdefer allocator.destroy(cloned);
    const executor = try allocator.create(exec.Executor);
    errdefer allocator.destroy(executor);
    executor.* = exec.Executor.init(allocator);
    errdefer executor.deinit();
    try executor.copyStateFrom(source.executor);

    const history = try allocator.create(History);
    errdefer allocator.destroy(history);
    history.* = History.init(allocator);
    errdefer history.deinit();
    try history.copyFrom(source.history);

    const cache = try allocator.create(CompletionCache);
    errdefer allocator.destroy(cache);
    cache.* = CompletionCache.init(allocator);
    errdefer cache.deinit();

    const loader = try allocator.create(CompletionScriptLoader);
    errdefer allocator.destroy(loader);
    loader.* = CompletionScriptLoader.init(allocator);
    errdefer loader.deinit();

    const cwd = try allocator.dupe(u8, source.cwd);
    errdefer allocator.free(cwd);

    cloned.* = .{
        .executor = executor,
        .history = history,
        .cache = cache,
        .loader = loader,
        .io = source.io,
        .cwd = cwd,
        .arg_zero = source.arg_zero,
        .features = source.features,
        .owned_executor = executor,
        .owned_history = history,
        .owned_cache = cache,
        .owned_loader = loader,
        .owned_cwd = cwd,
        .cancel = cancel,
    };
    return cloned;
}

fn freeInteractiveCompletionContext(context: *anyopaque, allocator: std.mem.Allocator) void {
    const cloned: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    if (cloned.owned_loader) |loader| {
        loader.deinit();
        allocator.destroy(loader);
    }
    if (cloned.owned_cache) |cache| {
        cache.deinit();
        allocator.destroy(cache);
    }
    if (cloned.owned_history) |history| {
        history.deinit();
        allocator.destroy(history);
    }
    if (cloned.owned_executor) |executor| {
        executor.deinit();
        allocator.destroy(executor);
    }
    if (cloned.owned_cwd) |cwd| allocator.free(cwd);
    allocator.destroy(cloned);
}

fn renderInteractivePrompt(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    return completion_context.promptService().render(allocator, io);
}

fn requestInteractivePromptRepaint(context: *anyopaque) void {
    const terminal: *editor_driver.TerminalSession = @ptrCast(@alignCast(context));
    terminal.requestPromptRedraw();
}

fn refreshInteractiveStyle(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, scheme: editor_driver.ColorScheme) !line_editor.UiTheme {
    _ = allocator;
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    const prompt_service = completion_context.promptService();
    try prompt_service.applyColorScheme(io, scheme);
    return prompt_service.theme();
}

fn refreshInteractiveColorReport(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, report: editor_driver.ColorReport) !line_editor.UiTheme {
    _ = allocator;
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    const prompt_service = completion_context.promptService();
    try prompt_service.applyColorReport(io, report);
    return prompt_service.theme();
}

fn applyInteractiveColorScheme(executor: *exec.Executor, io: std.Io, scheme: editor_driver.ColorScheme) !void {
    const prompt_service: InteractivePromptService = .{ .executor = executor, .arg_zero = executor.arg_zero };
    try prompt_service.applyColorScheme(io, scheme);
}

fn applyInteractiveColorReport(executor: *exec.Executor, io: std.Io, report: editor_driver.ColorReport) !void {
    const prompt_service: InteractivePromptService = .{ .executor = executor, .arg_zero = executor.arg_zero };
    try prompt_service.applyColorReport(io, report);
}

fn colorReportVariable(report: editor_driver.ColorReport) ?[]const u8 {
    return switch (report.kind) {
        .fg => "rush_color_foreground",
        .bg => "rush_color_background",
        .cursor => null,
        .index => |index| switch (index) {
            0 => "rush_color_black",
            1 => "rush_color_red",
            2 => "rush_color_green",
            3 => "rush_color_yellow",
            4 => "rush_color_blue",
            5 => "rush_color_magenta",
            6 => "rush_color_cyan",
            7 => "rush_color_white",
            else => null,
        },
    };
}

fn colorSchemeName(scheme: editor_driver.ColorScheme) []const u8 {
    return switch (scheme) {
        .dark => "dark",
        .light => "light",
        .unknown => "unknown",
    };
}

fn interactiveUiTheme(executor: exec.Executor) line_editor.UiTheme {
    var executor_copy = executor;
    const prompt_service: InteractivePromptService = .{ .executor = &executor_copy, .arg_zero = executor.arg_zero };
    return prompt_service.theme();
}

fn runInteractiveIntervalHooks(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !editor_driver.HookResult {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    const prompt_service = completion_context.promptService();
    const refresh_prompt = if (prompt_service.intervalWaitMs(io)) |wait_ms| wait_ms == 0 else false;
    try prompt_service.runDueIntervals(io);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var should_refresh_prompt = refresh_prompt;

    if (try completion_context.executor.executePendingSignalTrap(.{ .io = io, .allow_external = true, .features = completion_context.features, .interactive = true, .arg_zero = completion_context.arg_zero })) |trap_result| {
        var result = trap_result;
        defer result.deinit();
        try output.appendSlice(allocator, result.stdout);
        try output.appendSlice(allocator, result.stderr);
        should_refresh_prompt = true;
    }

    if (completion_context.executor.shell_options.notify) {
        const notifications = try completion_context.executor.drainJobNotifications();
        defer completion_context.executor.allocator.free(notifications);
        try output.appendSlice(allocator, notifications);
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = should_refresh_prompt,
        .stop = completion_context.executor.pending_exit != null,
    };
}

fn nextInteractiveIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    var wait_ms = completion_context.promptService().intervalWaitMs(io);
    if (completion_context.executor.wantsImmediateJobNotificationPoll()) {
        wait_ms = if (wait_ms) |current| @min(current, immediate_notify_poll_ms) else immediate_notify_poll_ms;
    }
    return wait_ms;
}

const CompletionScriptLoader = struct {
    allocator: std.mem.Allocator,
    attempted: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) CompletionScriptLoader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CompletionScriptLoader) void {
        var iter = self.attempted.iterator();
        while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.attempted.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureLoaded(self: *CompletionScriptLoader, io: std.Io, executor: *exec.Executor, command: []const u8, arg_zero: []const u8) !void {
        if (!validCompletionScriptCommand(command)) return;
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);
        const result = try self.attempted.getOrPut(self.allocator, owned_command);
        if (result.found_existing) {
            self.allocator.free(owned_command);
            return;
        }

        try self.loadDataDirs(io, executor, command, arg_zero);
        if (try xdgDataHomeCompletionManifestPath(self.allocator, executor.*, command)) |path| {
            defer self.allocator.free(path);
            const loaded_manifest = loadOptionalCompletionManifest(self.allocator, io, executor, path) catch false;
            if (!loaded_manifest) {
                if (try xdgDataHomeCompletionPath(self.allocator, executor.*, command)) |script_path| {
                    defer self.allocator.free(script_path);
                    sourceOptionalConfig(self.allocator, io, executor, script_path, arg_zero) catch {};
                }
            }
        } else if (try xdgDataHomeCompletionPath(self.allocator, executor.*, command)) |path| {
            defer self.allocator.free(path);
            sourceOptionalConfig(self.allocator, io, executor, path, arg_zero) catch {};
        }
        if (try xdgConfigCompletionManifestPath(self.allocator, executor.*, command)) |path| {
            defer self.allocator.free(path);
            const loaded_manifest = loadOptionalCompletionManifest(self.allocator, io, executor, path) catch false;
            if (!loaded_manifest) {
                if (try xdgConfigCompletionPath(self.allocator, executor.*, command)) |script_path| {
                    defer self.allocator.free(script_path);
                    sourceOptionalConfig(self.allocator, io, executor, script_path, arg_zero) catch {};
                }
            }
        } else if (try xdgConfigCompletionPath(self.allocator, executor.*, command)) |path| {
            defer self.allocator.free(path);
            sourceOptionalConfig(self.allocator, io, executor, path, arg_zero) catch {};
        }
    }

    fn loadDataDirs(self: *CompletionScriptLoader, io: std.Io, executor: *exec.Executor, command: []const u8, arg_zero: []const u8) !void {
        const data_dirs = executor.getEnv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        var iter = std.mem.splitScalar(u8, data_dirs, ':');
        while (iter.next()) |dir| {
            if (dir.len == 0) continue;
            const manifest_path = try completionManifestPathInDir(self.allocator, dir, command);
            defer self.allocator.free(manifest_path);
            const loaded_manifest = loadOptionalCompletionManifest(self.allocator, io, executor, manifest_path) catch false;
            if (loaded_manifest) continue;

            const path = try completionPathInDir(self.allocator, dir, command);
            defer self.allocator.free(path);
            sourceOptionalConfig(self.allocator, io, executor, path, arg_zero) catch {};
        }
    }
};

fn loadCompletionDataForExecutor(context: *anyopaque, executor: *exec.Executor, command: []const u8, options: completion_model.ScriptLoaderOptions) !void {
    options.validate();
    const loader: *CompletionScriptLoader = @ptrCast(@alignCast(context));
    const io = options.io orelse return;
    try loader.ensureLoaded(io, executor, command, options.arg_zero);
}

const CompletionCache = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    entries: std.StringHashMapUnmanaged([]completion_model.Candidate) = .empty,
    active_refresh: ?*CompletionRefresh = null,

    pub fn init(allocator: std.mem.Allocator) CompletionCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CompletionCache) void {
        self.waitForRefresh();
        self.clear();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *CompletionCache) void {
        self.waitForRefresh();
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            completion_model.freeCandidates(self.allocator, entry.value_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn get(self: *CompletionCache, source: []const u8, cursor: usize, cwd: []const u8, generation: u64) ?[]const completion_model.Candidate {
        self.reapRefresh();
        var key_buffer: [4096]u8 = undefined;
        const key = completionCacheKey(&key_buffer, source, cursor, cwd, generation) catch return null;
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return self.entries.get(key);
    }

    pub fn put(self: *CompletionCache, source: []const u8, cursor: usize, cwd: []const u8, generation: u64, candidates: []const completion_model.Candidate) !void {
        var key_buffer: [4096]u8 = undefined;
        const key = try completionCacheKey(&key_buffer, source, cursor, cwd, generation);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_candidates = try completion_model.cloneCandidates(self.allocator, candidates);
        errdefer completion_model.freeCandidates(self.allocator, owned_candidates);

        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const result = try self.entries.getOrPut(self.allocator, owned_key);
        if (result.found_existing) {
            self.allocator.free(owned_key);
            completion_model.freeCandidates(self.allocator, result.value_ptr.*);
        }
        result.value_ptr.* = owned_candidates;
    }

    pub fn startRefresh(self: *CompletionCache, executor: *const exec.Executor, history: *const History, io: std.Io, source: []const u8, cursor: usize, cwd: []const u8, generation: u64) !void {
        self.reapRefresh();
        if (self.active_refresh != null) return;

        const refresh = try self.allocator.create(CompletionRefresh);
        errdefer self.allocator.destroy(refresh);
        refresh.* = .{
            .allocator = self.allocator,
            .cache = self,
            .io = io,
            .source = try self.allocator.dupe(u8, source),
            .cursor = cursor,
            .cwd = try self.allocator.dupe(u8, cwd),
            .generation = generation,
            .executor = exec.Executor.init(self.allocator),
            .history = History.init(self.allocator),
        };
        errdefer refresh.deinitFields();
        try refresh.executor.copyStateFrom(executor);
        try refresh.history.copyFrom(history);
        refresh.thread = try std.Thread.spawn(.{}, CompletionRefresh.run, .{refresh});
        self.active_refresh = refresh;
    }

    fn reapRefresh(self: *CompletionCache) void {
        const refresh = self.active_refresh orelse return;
        if (!refresh.done.load(.acquire)) return;
        self.active_refresh = null;
        refresh.thread.join();
        refresh.deinitFields();
        self.allocator.destroy(refresh);
    }

    fn waitForRefresh(self: *CompletionCache) void {
        const refresh = self.active_refresh orelse return;
        self.active_refresh = null;
        refresh.thread.join();
        refresh.deinitFields();
        self.allocator.destroy(refresh);
    }
};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

const CompletionRefresh = struct {
    allocator: std.mem.Allocator,
    cache: *CompletionCache,
    io: std.Io,
    source: []const u8,
    cursor: usize,
    cwd: []const u8,
    generation: u64,
    executor: exec.Executor = undefined,
    history: History = .{ .allocator = undefined },
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *CompletionRefresh) void {
        defer self.done.store(true, .release);
        const candidates = self.executor.collectCompletionsForInput(self.source, self.cursor, .{ .io = self.io, .allow_external = true }) catch return;
        defer self.executor.freeCompletions(candidates);
        rankCompletionCandidates(self.allocator, candidates, self.history, self.cwd, self.source, .engineDefault()) catch return;
        self.cache.put(self.source, self.cursor, self.cwd, self.generation, candidates) catch return;
    }

    fn deinitFields(self: *CompletionRefresh) void {
        self.executor.deinit();
        self.history.deinit();
        self.allocator.free(self.source);
        self.allocator.free(self.cwd);
    }
};

fn completionCacheKey(buffer: []u8, source: []const u8, cursor: usize, cwd: []const u8, generation: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}\x00{d}\x00{s}\x00{d}", .{ source, cursor, cwd, generation });
}

fn validCompletionScriptCommand(command: []const u8) bool {
    if (command.len == 0 or std.mem.eql(u8, command, ".") or std.mem.eql(u8, command, "..")) return false;
    for (command) |byte| switch (byte) {
        '/', 0 => return false,
        else => {},
    };
    return true;
}

fn completionPathInDir(allocator: std.mem.Allocator, dir: []const u8, command: []const u8) ![]const u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.rush", .{command});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ dir, "rush", "completions", file_name });
}

fn completionManifestPathInDir(allocator: std.mem.Allocator, dir: []const u8, command: []const u8) ![]const u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{command});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ dir, "rush", "completions", file_name });
}

fn xdgDataHomeCompletionPath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8) !?[]const u8 {
    return xdgDataHomeCompletionFilePath(allocator, executor, command, completionPathInDir);
}

fn xdgDataHomeCompletionManifestPath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8) !?[]const u8 {
    return xdgDataHomeCompletionFilePath(allocator, executor, command, completionManifestPathInDir);
}

fn xdgDataHomeCompletionFilePath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8, comptime pathFn: fn (std.mem.Allocator, []const u8, []const u8) anyerror![]const u8) !?[]const u8 {
    if (executor.getEnv("XDG_DATA_HOME")) |xdg_data_home| {
        if (xdg_data_home.len != 0) return try pathFn(allocator, xdg_data_home, command);
    }
    if (executor.getEnv("HOME")) |home| {
        if (home.len != 0) {
            const data_home = try std.fs.path.join(allocator, &.{ home, ".local", "share" });
            defer allocator.free(data_home);
            return try pathFn(allocator, data_home, command);
        }
    }
    return null;
}

fn xdgConfigCompletionPath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8) !?[]const u8 {
    return xdgConfigCompletionFilePath(allocator, executor, command, completionPathInDir);
}

fn xdgConfigCompletionManifestPath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8) !?[]const u8 {
    return xdgConfigCompletionFilePath(allocator, executor, command, completionManifestPathInDir);
}

fn xdgConfigCompletionFilePath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8, comptime pathFn: fn (std.mem.Allocator, []const u8, []const u8) anyerror![]const u8) !?[]const u8 {
    if (executor.getEnv("XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return try pathFn(allocator, xdg_config_home, command);
    }
    if (executor.getEnv("HOME")) |home| {
        if (home.len != 0) {
            const config_home = try std.fs.path.join(allocator, &.{ home, ".config" });
            defer allocator.free(config_home);
            return try pathFn(allocator, config_home, command);
        }
    }
    return null;
}

fn loadOptionalCompletionManifest(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, path: []const u8) !bool {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(contents);
    try loadCompletionManifestWithPath(allocator, executor, contents, path);
    return true;
}

fn loadCompletionManifest(allocator: std.mem.Allocator, executor: *exec.Executor, contents: []const u8) !void {
    try loadCompletionManifestWithPath(allocator, executor, contents, null);
}

fn loadCompletionManifestWithPath(allocator: std.mem.Allocator, executor: *exec.Executor, contents: []const u8, source_path: ?[]const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    var diagnostics = CompletionManifestDiagnostics.init(allocator);
    defer diagnostics.deinit();
    try validateCompletionManifestValue(allocator, parsed.value, &diagnostics);
    if (diagnostics.hasErrors()) return error.CompletionManifestSemanticValidationFailed;

    const root_object = switch (parsed.value) {
        .object => |object| object,
        else => return error.CompletionManifestRootMustBeObject,
    };
    const manifest_version = root_object.get("manifestVersion") orelse return error.CompletionManifestMissingManifestVersion;
    var version: i64 = completion_manifest_supported_version;
    switch (manifest_version) {
        .integer => |parsed_version| {
            if (parsed_version != completion_manifest_supported_version) return error.UnsupportedCompletionManifestVersion;
            version = parsed_version;
        },
        else => return error.CompletionManifestVersionMustBeInteger,
    }
    const command = root_object.get("command") orelse return error.CompletionManifestMissingCommand;
    const command_object = switch (command) {
        .object => |object| object,
        else => return error.CompletionManifestCommandMustBeObject,
    };
    const companion_path = if (source_path) |path| try completionManifestCompanionPath(allocator, path) else null;
    defer if (companion_path) |path| allocator.free(path);
    const source: completion_model.RuleSource = .{ .kind = .manifest, .manifest_path = source_path, .manifest_version = version, .companion_path = companion_path };
    const root_name = try manifestCommandPrimaryName(command_object);
    const platform = completionManifestCurrentPlatform();
    const platform_allowed = manifestPlatformsAllowCurrent(command_object.get("platforms"));
    try executor.registerCompletionManifestCommandState(.{
        .command = root_name,
        .manifest_path = source_path,
        .manifest_version = version,
        .platform = platform,
        .platform_allowed = platform_allowed,
    });
    if (!platform_allowed) return;

    var root_providers: std.ArrayList(CompletionManifestProviderBinding) = .empty;
    defer root_providers.deinit(allocator);
    if (command_object.get("providers")) |providers_value| try appendCompletionManifestProviders(allocator, &root_providers, providers_value);

    try loadCompletionManifestCommand(executor, command, &.{}, &.{}, source, null, false);
    if (command_object.get("variants")) |variants| try loadCompletionManifestVariants(allocator, executor, root_name, command_object, variants, root_providers.items, source);
    if (command_object.get("variantProbe")) |probe| try registerCompletionManifestVariantProbe(allocator, executor, root_name, probe);
}

fn completionManifestCompanionPath(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (!std.mem.endsWith(u8, path, ".json")) return null;
    return @as(?[]const u8, try std.fmt.allocPrint(allocator, "{s}.rush", .{path[0 .. path.len - ".json".len]}));
}

const CompletionManifestProviderBinding = struct {
    id: ?[]const u8 = null,
    kind: completion_model.ProviderKind,
    value: ?[]const u8 = null,
    static_values: ?std.json.Array = null,
    tag: ?[]const u8 = null,
    provider_order: ?usize = null,
};

fn loadCompletionManifestCommand(executor: *exec.Executor, command_value: std.json.Value, path: []const []const u8, inherited_providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource, variant: ?[]const u8, disabled: bool) anyerror!void {
    const command = switch (command_value) {
        .object => |object| object,
        else => return error.CompletionManifestCommandMustBeObject,
    };
    const name = try manifestCommandPrimaryName(command);

    var providers: std.ArrayList(CompletionManifestProviderBinding) = .empty;
    defer providers.deinit(executor.allocator);
    try providers.appendSlice(executor.allocator, inherited_providers);
    if (command.get("providers")) |providers_value| try appendCompletionManifestProviders(executor.allocator, &providers, providers_value);

    if (path.len == 0) {
        if (command.get("dynamicSubcommands")) |dynamic_subcommands| try loadCompletionManifestProviderArray(executor, name, &.{}, .dynamic_subcommands, dynamic_subcommands, providers.items, source, variant, disabled);
        if (command.get("dynamicOptions")) |dynamic_options| try loadCompletionManifestProviderArray(executor, name, &.{}, .dynamic_options, dynamic_options, providers.items, source, variant, disabled);
        if (command.get("options")) |options| try loadCompletionManifestOptions(executor, name, &.{}, options, providers.items, source, variant, disabled);
        if (command.get("arguments")) |arguments| try loadCompletionManifestArguments(executor, name, &.{}, arguments, providers.items, source, variant, disabled);
        if (command.get("subcommands")) |subcommands| try loadCompletionManifestSubcommands(executor, name, &.{}, subcommands, providers.items, source, variant, disabled);
    } else {
        const root = path[0];
        const command_path = path[1..];
        const parent_path = command_path[0 .. command_path.len - 1];
        try loadCompletionManifestSubcommandNames(executor, root, parent_path, command, source, variant, disabled);
        if (command.get("dynamicSubcommands")) |dynamic_subcommands| try loadCompletionManifestProviderArray(executor, root, command_path, .dynamic_subcommands, dynamic_subcommands, providers.items, source, variant, disabled);
        if (command.get("dynamicOptions")) |dynamic_options| try loadCompletionManifestProviderArray(executor, root, command_path, .dynamic_options, dynamic_options, providers.items, source, variant, disabled);
        if (command.get("options")) |options| try loadCompletionManifestOptions(executor, root, command_path, options, providers.items, source, variant, disabled);
        if (command.get("arguments")) |arguments| try loadCompletionManifestArguments(executor, root, command_path, arguments, providers.items, source, variant, disabled);
        if (command.get("subcommands")) |subcommands| try loadCompletionManifestSubcommands(executor, root, command_path, subcommands, providers.items, source, variant, disabled);
    }
}

fn loadCompletionManifestVariants(allocator: std.mem.Allocator, executor: *exec.Executor, root: []const u8, command: std.json.ObjectMap, variants_value: std.json.Value, inherited_providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource) !void {
    _ = command;
    const variants = switch (variants_value) {
        .object => |object| object,
        else => return error.CompletionManifestVariantsMustBeObject,
    };
    var iter = variants.iterator();
    while (iter.next()) |entry| {
        const variant_name = entry.key_ptr.*;
        const overlay = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return error.CompletionManifestVariantMustBeObject,
        };
        if (!manifestPlatformsAllowCurrent(overlay.get("platforms"))) continue;
        try loadCompletionManifestCommandOverlay(allocator, executor, root, &.{}, entry.value_ptr.*, inherited_providers, source, variant_name, true);
    }
}

fn loadCompletionManifestCommandOverlay(allocator: std.mem.Allocator, executor: *exec.Executor, root: []const u8, path: []const []const u8, overlay_value: std.json.Value, inherited_providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource, variant: []const u8, disabled: bool) anyerror!void {
    const overlay = switch (overlay_value) {
        .object => |object| object,
        else => return error.CompletionManifestVariantMustBeObject,
    };

    var providers: std.ArrayList(CompletionManifestProviderBinding) = .empty;
    defer providers.deinit(executor.allocator);
    try providers.appendSlice(executor.allocator, inherited_providers);
    if (overlay.get("providers")) |providers_value| try appendCompletionManifestProviders(executor.allocator, &providers, providers_value);

    if (overlay.get("dynamicSubcommands")) |dynamic_subcommands| try loadCompletionManifestProviderArray(executor, root, path, .dynamic_subcommands, dynamic_subcommands, providers.items, source, variant, disabled);
    if (overlay.get("dynamicOptions")) |dynamic_options| try loadCompletionManifestProviderArray(executor, root, path, .dynamic_options, dynamic_options, providers.items, source, variant, disabled);
    if (overlay.get("options")) |options| try loadCompletionManifestOptions(executor, root, path, options, providers.items, source, variant, disabled);
    if (overlay.get("arguments")) |arguments| try loadCompletionManifestArguments(executor, root, path, arguments, providers.items, source, variant, disabled);

    if (overlay.get("subcommands")) |subcommands_value| {
        const subcommands = switch (subcommands_value) {
            .array => |array| array,
            else => return error.CompletionManifestSubcommandsMustBeArray,
        };
        for (subcommands.items) |subcommand_value| {
            const subcommand = switch (subcommand_value) {
                .object => |object| object,
                else => return error.CompletionManifestSubcommandMustBeObject,
            };
            const name = try manifestCommandPrimaryName(subcommand);
            var child_path: std.ArrayList([]const u8) = .empty;
            defer child_path.deinit(allocator);
            try child_path.appendSlice(allocator, path);
            try child_path.append(allocator, name);
            try loadCompletionManifestSubcommandNames(executor, root, path, subcommand, source, variant, disabled);
            try loadCompletionManifestCommandOverlay(allocator, executor, root, child_path.items, subcommand_value, providers.items, source, variant, disabled);
        }
    }
}

fn registerCompletionManifestVariantProbe(allocator: std.mem.Allocator, executor: *exec.Executor, root: []const u8, probe_value: std.json.Value) !void {
    const probe = switch (probe_value) {
        .object => |object| object,
        else => return error.CompletionManifestVariantProbeMustBeObject,
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    if (probe.get("args")) |args_value| {
        const arg_array = switch (args_value) {
            .array => |array| array,
            else => return error.CompletionManifestVariantProbeArgsMustBeArray,
        };
        for (arg_array.items) |arg_value| if (manifestString(arg_value)) |arg| try args.append(allocator, arg);
    }

    const matches_value = probe.get("matches") orelse return;
    const matches = switch (matches_value) {
        .object => |object| object,
        else => return error.CompletionManifestVariantProbeMatchesMustBeObject,
    };
    var patterns: std.ArrayList(completion_model.VariantPattern) = .empty;
    defer patterns.deinit(allocator);
    var iter = matches.iterator();
    while (iter.next()) |entry| {
        const pattern = manifestString(entry.value_ptr.*) orelse continue;
        try patterns.append(allocator, .{ .name = entry.key_ptr.*, .pattern = pattern });
    }
    try executor.registerCompletionVariantProbe(root, args.items, patterns.items);
}

fn appendCompletionManifestProviders(allocator: std.mem.Allocator, providers: *std.ArrayList(CompletionManifestProviderBinding), providers_value: std.json.Value) !void {
    const object = switch (providers_value) {
        .object => |object| object,
        else => return error.CompletionManifestProvidersMustBeObject,
    };
    var iter = object.iterator();
    while (iter.next()) |entry| {
        var binding = try completionManifestProviderBinding(entry.value_ptr.*);
        binding.id = entry.key_ptr.*;
        try providers.append(allocator, binding);
    }
}

fn completionManifestProviderBinding(provider_value: std.json.Value) !CompletionManifestProviderBinding {
    const provider = switch (provider_value) {
        .object => |object| object,
        else => return error.CompletionManifestProviderMustBeObject,
    };
    const tag = manifestString(provider.get("tag"));
    if (manifestString(provider.get("function"))) |function| {
        return .{ .kind = .function, .value = function, .tag = tag };
    }
    if (manifestString(provider.get("builtin"))) |builtin| {
        const kind = completionManifestBuiltinProviderKind(builtin) orelse return error.UnsupportedCompletionManifestBuiltinProvider;
        return .{ .kind = kind, .value = builtin, .tag = tag orelse completionManifestBuiltinProviderTag(kind) };
    }
    if (provider.get("values")) |values_value| {
        const values = switch (values_value) {
            .array => |array| array,
            else => return error.CompletionManifestStaticProviderValuesMustBeArray,
        };
        return .{ .kind = .static_enum, .static_values = values, .tag = tag };
    }
    return error.CompletionManifestProviderMissingBinding;
}

fn resolveCompletionManifestProviderRef(provider_ref: std.json.Value, providers: []const CompletionManifestProviderBinding) !CompletionManifestProviderBinding {
    switch (provider_ref) {
        .string => |provider_id| {
            var index = providers.len;
            while (index > 0) {
                index -= 1;
                const provider = providers[index];
                if (provider.id) |id| if (std.mem.eql(u8, id, provider_id)) return provider;
            }
            return error.UnknownCompletionManifestProvider;
        },
        .object => return completionManifestProviderBinding(provider_ref),
        else => return error.CompletionManifestProviderRefMustBeStringOrObject,
    }
}

fn completionManifestBuiltinProviderKind(name: []const u8) ?completion_model.ProviderKind {
    if (std.mem.eql(u8, name, "files")) return .builtin_files;
    if (std.mem.eql(u8, name, "directories")) return .builtin_directories;
    if (std.mem.eql(u8, name, "executables")) return .builtin_executables;
    if (std.mem.eql(u8, name, "variables")) return .builtin_variables;
    return null;
}

fn completionManifestBuiltinProviderTag(kind: completion_model.ProviderKind) []const u8 {
    return switch (kind) {
        .builtin_files => "files",
        .builtin_directories => "directories",
        .builtin_executables => "executables",
        .builtin_variables => "variables",
        .function, .static_enum => "",
    };
}

fn loadCompletionManifestProviderArray(executor: *exec.Executor, root: []const u8, path: []const []const u8, kind: completion_model.RuleKind, providers_value: std.json.Value, providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource, variant: ?[]const u8, disabled: bool) !void {
    const array = switch (providers_value) {
        .array => |array| array,
        else => return error.CompletionManifestProviderArrayMustBeArray,
    };
    for (array.items, 0..) |provider_ref, index| {
        var provider = try resolveCompletionManifestProviderRef(provider_ref, providers);
        provider.provider_order = index;
        try registerCompletionManifestProviderRule(executor, root, path, kind, provider, .{}, .{}, 0, .{}, null, source, variant, disabled);
    }
}

fn manifestCommandPrimaryName(command: std.json.ObjectMap) ![]const u8 {
    const name_value = command.get("name") orelse return error.CompletionManifestCommandMissingName;
    return switch (name_value) {
        .string => |name| name,
        .array => |names| if (names.items.len == 0) error.CompletionManifestCommandNameMustBeString else switch (names.items[0]) {
            .string => |name| name,
            else => error.CompletionManifestCommandNameMustBeString,
        },
        else => error.CompletionManifestCommandNameMustBeString,
    };
}

fn loadCompletionManifestSubcommandNames(executor: *exec.Executor, root: []const u8, parent_path: []const []const u8, command: std.json.ObjectMap, source: completion_model.RuleSource, variant: ?[]const u8, disabled: bool) !void {
    const description = manifestString(command.get("description"));
    const name_value = command.get("name") orelse return error.CompletionManifestCommandMissingName;
    switch (name_value) {
        .string => |name| try executor.registerCompletionRule(.{ .root = root, .path = parent_path, .kind = .subcommand, .value = name, .description = description, .source = source, .variant = variant, .disabled = disabled }),
        .array => |names| for (names.items) |item| {
            const name = switch (item) {
                .string => |value| value,
                else => return error.CompletionManifestCommandNameMustBeString,
            };
            try executor.registerCompletionRule(.{ .root = root, .path = parent_path, .kind = .subcommand, .value = name, .description = description, .source = source, .variant = variant, .disabled = disabled });
        },
        else => return error.CompletionManifestCommandNameMustBeString,
    }
    if (command.get("aliases")) |aliases_value| {
        const aliases = switch (aliases_value) {
            .array => |array| array,
            else => return,
        };
        for (aliases.items) |alias_value| {
            const alias = switch (alias_value) {
                .string => |value| value,
                else => continue,
            };
            try executor.registerCompletionRule(.{ .root = root, .path = parent_path, .kind = .subcommand, .value = alias, .description = description, .source = source, .variant = variant, .disabled = disabled });
        }
    }
}

fn loadCompletionManifestSubcommands(executor: *exec.Executor, root: []const u8, parent_path: []const []const u8, subcommands_value: std.json.Value, providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource, variant: ?[]const u8, disabled: bool) anyerror!void {
    const subcommands = switch (subcommands_value) {
        .array => |array| array,
        else => return error.CompletionManifestSubcommandsMustBeArray,
    };
    for (subcommands.items) |subcommand_value| {
        const subcommand = switch (subcommand_value) {
            .object => |object| object,
            else => return error.CompletionManifestSubcommandMustBeObject,
        };
        const name = try manifestCommandPrimaryName(subcommand);

        var child_path: std.ArrayList([]const u8) = .empty;
        defer child_path.deinit(executor.allocator);
        try child_path.append(executor.allocator, root);
        try child_path.appendSlice(executor.allocator, parent_path);
        try child_path.append(executor.allocator, name);
        try loadCompletionManifestCommand(executor, subcommand_value, child_path.items, providers, source, variant, disabled);
    }
}

fn loadCompletionManifestOptions(executor: *exec.Executor, root: []const u8, path: []const []const u8, options_value: std.json.Value, providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource, variant: ?[]const u8, disabled: bool) !void {
    const options = switch (options_value) {
        .array => |array| array,
        else => return error.CompletionManifestOptionsMustBeArray,
    };
    for (options.items) |option_value| {
        const option = switch (option_value) {
            .object => |object| object,
            else => return error.CompletionManifestOptionMustBeObject,
        };
        if (!manifestPlatformsAllowCurrent(option.get("platforms"))) continue;
        var rule: completion_model.Rule = .{ .root = root, .path = path, .kind = .option, .description = manifestString(option.get("description")), .source = source };
        rule.variant = variant;
        rule.disabled = disabled;
        if (manifestString(option.get("long"))) |long| rule.option.long = long;
        if (manifestString(option.get("short"))) |short| rule.option.short = short;
        var spellings: std.ArrayList([]const u8) = .empty;
        var owned_alias_spellings: std.ArrayList([]const u8) = .empty;
        defer {
            for (owned_alias_spellings.items) |spelling| executor.allocator.free(spelling);
            owned_alias_spellings.deinit(executor.allocator);
            spellings.deinit(executor.allocator);
        }
        if (option.get("spellings")) |spellings_value| {
            if (spellings_value == .array) {
                for (spellings_value.array.items) |spelling_value| {
                    const spelling = manifestString(spelling_value) orelse continue;
                    try spellings.append(executor.allocator, spelling);
                }
            }
        }
        if (option.get("aliases")) |aliases_value| {
            if (aliases_value == .array) {
                for (aliases_value.array.items) |alias_value| {
                    const alias = manifestString(alias_value) orelse continue;
                    const alias_spelling = try std.fmt.allocPrint(executor.allocator, "--{s}", .{alias});
                    owned_alias_spellings.append(executor.allocator, alias_spelling) catch |err| {
                        executor.allocator.free(alias_spelling);
                        return err;
                    };
                    spellings.append(executor.allocator, alias_spelling) catch |err| {
                        return err;
                    };
                }
            }
        }
        rule.option.spellings = spellings.items;
        if (manifestString(option.get("exclusiveGroup"))) |group| rule.option.exclusive_group = group;
        const excludes = try completionManifestOptionExclusions(executor.allocator, option.get("excludes"));
        defer if (excludes.len != 0) executor.allocator.free(excludes);
        rule.option.excludes = excludes;
        rule.option.repeatable = manifestBool(option.get("repeatable"));
        rule.option.terminates_options = manifestBool(option.get("terminatesOptions"));
        rule.option.inherit = manifestBoolDefault(option.get("inherit"), true);
        if (option.get("value")) |value| {
            rule.option.value_count = manifestOptionValueCount(value);
            if (manifestOptionValueAt(value, 0)) |first| {
                if (manifestValueName(first)) |name| rule.option.argument = name;
            }
        }
        if (rule.option.long == null and rule.option.short == null and rule.option.spellings.len == 0) return error.CompletionManifestOptionMissingSpelling;
        try executor.registerCompletionRule(rule);
        if (option.get("value")) |value| try loadCompletionManifestOptionValueProvider(executor, root, path, rule, value, providers, source, variant, disabled);
    }
}

fn completionManifestOptionExclusions(allocator: std.mem.Allocator, excludes_value: ?std.json.Value) ![]const completion_model.OptionExclusion {
    const value = excludes_value orelse return &.{};
    switch (value) {
        .string => |string| {
            const excludes = try allocator.alloc(completion_model.OptionExclusion, 1);
            excludes[0] = completionManifestOptionExclusion(string);
            return excludes;
        },
        .array => |array| {
            var excludes: std.ArrayList(completion_model.OptionExclusion) = .empty;
            errdefer excludes.deinit(allocator);
            for (array.items) |item| {
                const string = manifestString(item) orelse continue;
                try excludes.append(allocator, completionManifestOptionExclusion(string));
            }
            return excludes.toOwnedSlice(allocator);
        },
        else => return &.{},
    }
}

fn completionManifestOptionExclusion(value: []const u8) completion_model.OptionExclusion {
    if (std.mem.eql(u8, value, "operands")) return .{ .kind = .operands };
    if (std.mem.eql(u8, value, "everything")) return .{ .kind = .everything };
    return .{ .kind = .option, .selector = value };
}

fn loadCompletionManifestOptionValueProvider(executor: *exec.Executor, root: []const u8, path: []const []const u8, option_rule: completion_model.Rule, value: std.json.Value, providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource, variant: ?[]const u8, disabled: bool) !void {
    var value_index: usize = 0;
    while (manifestOptionValueAt(value, value_index)) |value_item| : (value_index += 1) {
        const object = switch (value_item) {
            .object => |object| object,
            else => continue,
        };
        const provider_ref = object.get("provider") orelse continue;
        try registerCompletionManifestProviderRefs(executor, root, path, .dynamic_option_value, provider_ref, providers, option_rule.option, .{}, value_index, manifestValueGrammar(object.get("grammar")), manifestString(object.get("description")), source, variant, disabled);
    }
}

fn loadCompletionManifestArguments(executor: *exec.Executor, root: []const u8, path: []const []const u8, arguments_value: std.json.Value, providers: []const CompletionManifestProviderBinding, source: completion_model.RuleSource, variant: ?[]const u8, disabled: bool) !void {
    const arguments = switch (arguments_value) {
        .object => |object| object,
        else => return error.CompletionManifestArgumentsMustBeObject,
    };
    const states_value = arguments.get("states") orelse return;
    const states = switch (states_value) {
        .array => |array| array,
        else => return error.CompletionManifestArgumentStatesMustBeArray,
    };
    for (states.items) |state_value| {
        const state = switch (state_value) {
            .object => |object| object,
            else => return error.CompletionManifestArgumentStateMustBeObject,
        };
        var argument: completion_model.Argument = .{
            .state = manifestString(state.get("name")),
            .repeatable = manifestBool(state.get("repeatable")),
            .rest_command_line = manifestRestCommandLine(state.get("rest")),
        };
        if (manifestInteger(state.get("index"))) |index| {
            if (index >= 0) argument.index = @intCast(index);
        }
        if (state.get("after")) |after| argument.after_state = manifestConditionPreviousState(after);
        if (state.get("when")) |condition| argument.when_condition = try compileCompletionManifestArgumentCondition(executor.allocator, condition, root, path, executor.completionRules());
        defer completion_model.freeArgumentCondition(executor.allocator, argument.when_condition);
        if (state.get("after")) |condition| argument.after_condition = try compileCompletionManifestArgumentCondition(executor.allocator, condition, root, path, executor.completionRules());
        defer completion_model.freeArgumentCondition(executor.allocator, argument.after_condition);
        if (state.get("until")) |condition| argument.until_condition = try compileCompletionManifestArgumentCondition(executor.allocator, condition, root, path, executor.completionRules());
        defer completion_model.freeArgumentCondition(executor.allocator, argument.until_condition);
        if (argument.rest_command_line) {
            try executor.registerCompletionRule(.{ .root = root, .path = path, .kind = .dynamic_argument, .argument = argument, .description = manifestString(state.get("description")), .source = source, .variant = variant, .disabled = disabled });
            continue;
        }
        const provider_ref = state.get("provider") orelse continue;
        try registerCompletionManifestProviderRefs(executor, root, path, .dynamic_argument, provider_ref, providers, .{}, argument, 0, manifestValueGrammar(state.get("grammar")), manifestString(state.get("description")), source, variant, disabled);
    }
}

fn compileCompletionManifestArgumentCondition(allocator: std.mem.Allocator, condition_value: std.json.Value, root: []const u8, path: []const []const u8, rules: []const completion_model.Rule) !?*const completion_model.ArgumentCondition {
    const owned = try allocator.create(completion_model.ArgumentCondition);
    errdefer allocator.destroy(owned);
    owned.* = try compileCompletionManifestArgumentConditionValue(allocator, condition_value, root, path, rules);
    return owned;
}

fn compileCompletionManifestArgumentConditionValue(allocator: std.mem.Allocator, condition_value: std.json.Value, root: []const u8, path: []const []const u8, rules: []const completion_model.Rule) anyerror!completion_model.ArgumentCondition {
    const condition = switch (condition_value) {
        .object => |object| object,
        else => return .{ .unsupported = {} },
    };
    if (condition.get("all")) |children| return .{ .all = try compileCompletionManifestArgumentConditionChildren(allocator, children, root, path, rules) };
    if (condition.get("any")) |children| return .{ .any = try compileCompletionManifestArgumentConditionChildren(allocator, children, root, path, rules) };
    if (condition.get("not")) |child| {
        const owned_child = try allocator.create(completion_model.ArgumentCondition);
        errdefer allocator.destroy(owned_child);
        owned_child.* = try compileCompletionManifestArgumentConditionValue(allocator, child, root, path, rules);
        return .{ .not = owned_child };
    }
    if (condition.get("terminatorSeen")) |value| {
        if (value == .bool) return .{ .terminator_seen = value.bool };
        return .{ .unsupported = {} };
    }
    if (manifestString(condition.get("previousState"))) |previous_state| return .{ .previous_state = try allocator.dupe(u8, previous_state) };
    if (condition.get("optionPresent")) |selector_or_selectors| {
        return .{ .option_present = try compileCompletionManifestOptionSelectorKeys(allocator, selector_or_selectors, root, path, rules) };
    }
    if (condition.get("optionAbsent")) |selector_or_selectors| {
        return .{ .option_absent = try compileCompletionManifestOptionSelectorKeys(allocator, selector_or_selectors, root, path, rules) };
    }
    if (condition.get("optionValue")) |option_value| return try compileCompletionManifestOptionValueCondition(allocator, option_value, root, path, rules);
    return .{ .unsupported = {} };
}

fn compileCompletionManifestArgumentConditionChildren(allocator: std.mem.Allocator, children_value: std.json.Value, root: []const u8, path: []const []const u8, rules: []const completion_model.Rule) anyerror![]const completion_model.ArgumentCondition {
    const children = switch (children_value) {
        .array => |array| array,
        else => {
            const unsupported = try allocator.alloc(completion_model.ArgumentCondition, 1);
            unsupported[0] = .{ .unsupported = {} };
            return unsupported;
        },
    };
    if (children.items.len == 0) return &.{};
    const owned = try allocator.alloc(completion_model.ArgumentCondition, children.items.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |child| completion_model.freeArgumentConditionValue(allocator, child);
        allocator.free(owned);
    }
    for (children.items, 0..) |child, index| {
        owned[index] = try compileCompletionManifestArgumentConditionValue(allocator, child, root, path, rules);
        initialized += 1;
    }
    return owned;
}

fn compileCompletionManifestOptionSelectorKeys(allocator: std.mem.Allocator, selector_or_selectors: std.json.Value, root: []const u8, path: []const []const u8, rules: []const completion_model.Rule) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    errdefer for (keys.items) |key| allocator.free(key);
    switch (selector_or_selectors) {
        .string => |selector| try appendCompletionManifestOptionSelectorKey(allocator, &keys, selector, root, path, rules),
        .array => |array| for (array.items) |item| if (manifestString(item)) |selector| try appendCompletionManifestOptionSelectorKey(allocator, &keys, selector, root, path, rules),
        else => {},
    }
    return try keys.toOwnedSlice(allocator);
}

fn appendCompletionManifestOptionSelectorKey(allocator: std.mem.Allocator, keys: *std.ArrayList([]const u8), selector: []const u8, root: []const u8, path: []const []const u8, rules: []const completion_model.Rule) !void {
    const key = manifestCompletionOptionSelectorKey(rules, root, path, selector) orelse selector;
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try keys.append(allocator, owned_key);
}

fn compileCompletionManifestOptionValueCondition(allocator: std.mem.Allocator, option_value: std.json.Value, root: []const u8, path: []const []const u8, rules: []const completion_model.Rule) !completion_model.ArgumentCondition {
    const object = switch (option_value) {
        .object => |object| object,
        else => return .{ .unsupported = {} },
    };
    var children: std.ArrayList(completion_model.ArgumentCondition) = .empty;
    defer children.deinit(allocator);
    errdefer for (children.items) |child| completion_model.freeArgumentConditionValue(allocator, child);
    var iter = object.iterator();
    while (iter.next()) |entry| {
        try children.append(allocator, .{ .option_value = try compileCompletionManifestSingleOptionValueCondition(allocator, entry.key_ptr.*, entry.value_ptr.*, root, path, rules) });
    }
    if (children.items.len == 1) return children.pop().?;
    return .{ .any = try children.toOwnedSlice(allocator) };
}

fn compileCompletionManifestSingleOptionValueCondition(allocator: std.mem.Allocator, selector: []const u8, value: std.json.Value, root: []const u8, path: []const []const u8, rules: []const completion_model.Rule) !completion_model.OptionValueCondition {
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    errdefer for (values.items) |literal| allocator.free(literal);
    switch (value) {
        .string => |literal| try appendCompletionManifestOwnedString(allocator, &values, literal),
        .array => |array| for (array.items) |item| if (manifestString(item)) |literal| try appendCompletionManifestOwnedString(allocator, &values, literal),
        else => {},
    }
    const key = manifestCompletionOptionSelectorKey(rules, root, path, selector) orelse selector;
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_values = try values.toOwnedSlice(allocator);
    errdefer {
        for (owned_values) |literal| allocator.free(literal);
        if (owned_values.len != 0) allocator.free(owned_values);
    }
    return .{
        .key = owned_key,
        .values = owned_values,
    };
}

fn appendCompletionManifestOwnedString(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try values.append(allocator, owned_value);
}

fn manifestCompletionOptionSelectorKey(rules: []const completion_model.Rule, root: []const u8, path: []const []const u8, selector: []const u8) ?[]const u8 {
    for (rules) |rule| {
        if (rule.kind != .option and rule.kind != .dynamic_option_value) continue;
        if (!completionManifestRuleOptionAppliesToPath(rule, root, path)) continue;
        if (manifestCompletionOptionMatchesSelector(rule.option, selector)) return manifestCompletionOptionKey(rule.option);
    }
    return null;
}

fn manifestCompletionOptionMatchesSelector(option: completion_model.Option, selector: []const u8) bool {
    for (option.spellings) |spelling| if (std.mem.eql(u8, spelling, selector)) return true;
    if (std.mem.startsWith(u8, selector, "--")) {
        const name = selector[2..];
        if (option.long) |long| if (std.mem.eql(u8, long, name)) return true;
    }
    if (std.mem.startsWith(u8, selector, "-") and selector.len == 2) {
        const name = selector[1..];
        if (option.short) |short| if (std.mem.eql(u8, short, name)) return true;
    }
    return false;
}

fn completionManifestRuleOptionAppliesToPath(rule: completion_model.Rule, root: []const u8, path: []const []const u8) bool {
    if (rule.disabled) return false;
    if (!std.mem.eql(u8, rule.root, root)) return false;
    if (rule.option.inherit) {
        if (rule.path.len > path.len) return false;
        for (rule.path, path[0..rule.path.len]) |expected, actual| {
            if (!std.mem.eql(u8, expected, actual)) return false;
        }
        return true;
    }
    if (rule.path.len != path.len) return false;
    for (rule.path, path) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return false;
    }
    return true;
}

fn manifestCompletionOptionKey(option: completion_model.Option) []const u8 {
    if (option.long) |long| return long;
    if (option.short) |short| return short;
    if (option.spellings.len != 0) return option.spellings[0];
    return "";
}

fn manifestRestCommandLine(value: ?std.json.Value) bool {
    const rest = manifestString(value) orelse return false;
    return std.mem.eql(u8, rest, "command-line");
}

fn registerCompletionManifestProviderRule(
    executor: *exec.Executor,
    root: []const u8,
    path: []const []const u8,
    kind: completion_model.RuleKind,
    provider: CompletionManifestProviderBinding,
    option: completion_model.Option,
    argument: completion_model.Argument,
    value_index: usize,
    value_grammar: completion_model.ValueGrammar,
    description: ?[]const u8,
    source: completion_model.RuleSource,
    variant: ?[]const u8,
    disabled: bool,
) !void {
    var static_values: std.ArrayList(completion_model.StaticProviderValue) = .empty;
    defer static_values.deinit(executor.allocator);
    if (provider.static_values) |values| {
        for (values.items) |value| try static_values.append(executor.allocator, try manifestStaticProviderValue(value));
    }
    try executor.registerCompletionRule(.{
        .root = root,
        .path = path,
        .kind = kind,
        .value = provider.value,
        .provider_kind = provider.kind,
        .static_values = static_values.items,
        .option = option,
        .argument = argument,
        .value_index = value_index,
        .value_grammar = value_grammar,
        .description = description,
        .tag = provider.tag,
        .provider_order = provider.provider_order,
        .source = source,
        .variant = variant,
        .disabled = disabled,
    });
}

fn registerCompletionManifestProviderRefs(
    executor: *exec.Executor,
    root: []const u8,
    path: []const []const u8,
    kind: completion_model.RuleKind,
    provider_ref: std.json.Value,
    providers: []const CompletionManifestProviderBinding,
    option: completion_model.Option,
    argument: completion_model.Argument,
    value_index: usize,
    value_grammar: completion_model.ValueGrammar,
    description: ?[]const u8,
    source: completion_model.RuleSource,
    variant: ?[]const u8,
    disabled: bool,
) !void {
    switch (provider_ref) {
        .array => |array| {
            for (array.items, 0..) |item, index| {
                var provider = try resolveCompletionManifestProviderRef(item, providers);
                provider.provider_order = index;
                try registerCompletionManifestProviderRule(executor, root, path, kind, provider, option, argument, value_index, value_grammar, description, source, variant, disabled);
            }
        },
        else => {
            const provider = try resolveCompletionManifestProviderRef(provider_ref, providers);
            try registerCompletionManifestProviderRule(executor, root, path, kind, provider, option, argument, value_index, value_grammar, description, source, variant, disabled);
        },
    }
}

fn manifestStaticProviderValue(value: std.json.Value) !completion_model.StaticProviderValue {
    switch (value) {
        .string => |string| return .{ .value = string },
        .object => |object| {
            const choice = manifestString(object.get("value")) orelse return error.CompletionManifestStaticProviderValueMissingValue;
            const suffix = manifestString(object.get("suffix"));
            return .{
                .value = choice,
                .display = manifestString(object.get("display")),
                .description = manifestString(object.get("description")),
                .tag = manifestString(object.get("tag")),
                .suffix = suffix,
                .removable_suffix = manifestBool(object.get("removableSuffix")),
                .append_space = suffix == null and !manifestBool(object.get("noSpace")),
            };
        },
        else => return error.CompletionManifestStaticProviderValueMustBeStringOrObject,
    }
}

fn manifestValueGrammar(value: ?std.json.Value) completion_model.ValueGrammar {
    const grammar = switch (value orelse return .{}) {
        .object => |object| object,
        else => return .{},
    };
    const kind = manifestString(grammar.get("kind")) orelse return .{};
    if (std.mem.eql(u8, kind, "list")) {
        return .{ .list_separator = manifestSingleByteString(grammar.get("separator")) };
    }
    if (std.mem.eql(u8, kind, "keyValue")) {
        return .{
            .key_prefix = manifestSingleByteString(grammar.get("keyPrefix")),
            .key_value_separator = manifestSingleByteString(grammar.get("separator")),
        };
    }
    return .{};
}

fn manifestSingleByteString(value: ?std.json.Value) ?u8 {
    const string = manifestString(value) orelse return null;
    if (string.len != 1) return null;
    return string[0];
}

fn manifestConditionPreviousState(value: std.json.Value) ?[]const u8 {
    const condition = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return manifestString(condition.get("previousState"));
}

fn manifestOptionEnumValues(option: std.json.ObjectMap, providers: []const CompletionManifestProviderInfo) ?std.json.Array {
    const value = switch (option.get("value") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    if (value.get("grammar")) |grammar_value| {
        const grammar = switch (grammar_value) {
            .object => |object| object,
            else => return null,
        };
        if (manifestString(grammar.get("kind"))) |kind| {
            if (std.mem.eql(u8, kind, "enum")) {
                return switch (grammar.get("values") orelse return null) {
                    .array => |array| array,
                    else => null,
                };
            }
        }
    }
    if (value.get("provider")) |provider_ref| return manifestProviderStaticValues(provider_ref, providers);
    return null;
}

fn manifestProviderStaticValues(provider_ref: std.json.Value, providers: []const CompletionManifestProviderInfo) ?std.json.Array {
    switch (provider_ref) {
        .string => |provider_id| return if (findCompletionManifestProviderInfo(providers, provider_id)) |provider| provider.static_values else null,
        .object => |provider| {
            return switch (provider.get("values") orelse return null) {
                .array => |array| array,
                else => null,
            };
        },
        else => return null,
    }
}

fn manifestString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |string| string,
        else => null,
    };
}

fn manifestFirstString(value: ?std.json.Value) ?[]const u8 {
    const array = switch (value orelse return null) {
        .array => |array| array,
        else => return null,
    };
    if (array.items.len == 0) return null;
    return manifestString(array.items[0]);
}

fn completionManifestCurrentPlatform() []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        .dragonfly => "dragonfly",
        .windows => "windows",
        .wasi => "wasi",
        .haiku => "haiku",
        else => "unknown",
    };
}

fn manifestPlatformsAllowCurrent(value: ?std.json.Value) bool {
    const platforms_value = value orelse return true;
    const platforms = switch (platforms_value) {
        .array => |array| array,
        else => return true,
    };
    const current = completionManifestCurrentPlatform();
    for (platforms.items) |platform_value| {
        const platform = manifestString(platform_value) orelse continue;
        if (std.mem.eql(u8, platform, current)) return true;
    }
    return false;
}

fn completionManifestPlatformKnown(platform: []const u8) bool {
    inline for (&.{ "darwin", "linux", "freebsd", "openbsd", "netbsd", "dragonfly", "windows", "wasi", "haiku" }) |known| {
        if (std.mem.eql(u8, platform, known)) return true;
    }
    return false;
}

fn manifestValueName(value: std.json.Value) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return manifestString(object.get("name"));
}

fn manifestOptionValueCount(value: std.json.Value) usize {
    return switch (value) {
        .object => 1,
        .array => |array| array.items.len,
        else => 0,
    };
}

fn manifestOptionValueAt(value: std.json.Value, index: usize) ?std.json.Value {
    return switch (value) {
        .object => if (index == 0) value else null,
        .array => |array| if (index < array.items.len) array.items[index] else null,
        else => null,
    };
}

const completion_manifest_supported_version: i64 = 1;
const completion_manifest_schema_marker = "/completion/schema/v";

const CompletionManifestDiagnosticSeverity = enum { warning, err };

const CompletionManifestDiagnostic = struct {
    severity: CompletionManifestDiagnosticSeverity,
    message: []const u8,
};

const CompletionManifestDiagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(CompletionManifestDiagnostic) = .empty,

    fn init(allocator: std.mem.Allocator) CompletionManifestDiagnostics {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CompletionManifestDiagnostics) void {
        for (self.items.items) |diagnostic| self.allocator.free(diagnostic.message);
        self.items.deinit(self.allocator);
    }

    fn add(self: *CompletionManifestDiagnostics, severity: CompletionManifestDiagnosticSeverity, comptime format: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, format, args);
        errdefer self.allocator.free(message);
        try self.items.append(self.allocator, .{ .severity = severity, .message = message });
    }

    fn hasErrors(self: CompletionManifestDiagnostics) bool {
        for (self.items.items) |diagnostic| {
            if (diagnostic.severity == .err) return true;
        }
        return false;
    }
};

const CompletionManifestOptionSpellingKind = enum { short, long, literal };

const CompletionManifestOptionSpelling = struct {
    kind: CompletionManifestOptionSpellingKind,
    value: []const u8,
    key: []const u8,
    takes_value: bool = false,
    enum_values: ?std.json.Array = null,
};

const CompletionManifestProviderInfo = struct {
    id: []const u8,
    static_values: ?std.json.Array = null,
};

fn validateCompletionManifestContents(allocator: std.mem.Allocator, contents: []const u8) !CompletionManifestDiagnostics {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    var diagnostics = CompletionManifestDiagnostics.init(allocator);
    errdefer diagnostics.deinit();
    try validateCompletionManifestValue(allocator, parsed.value, &diagnostics);
    return diagnostics;
}

fn validateCompletionManifestValue(allocator: std.mem.Allocator, value: std.json.Value, diagnostics: *CompletionManifestDiagnostics) !void {
    const root = switch (value) {
        .object => |object| object,
        else => {
            try diagnostics.add(.err, "manifest: root value must be an object", .{});
            return;
        },
    };

    var manifest_version: ?i64 = null;
    if (root.get("manifestVersion")) |version_value| {
        switch (version_value) {
            .integer => |version| {
                manifest_version = version;
                if (version != completion_manifest_supported_version) {
                    try diagnostics.add(.err, "manifestVersion: unsupported completion manifest version {d}; supported version is {d}", .{ version, completion_manifest_supported_version });
                }
            },
            else => try diagnostics.add(.err, "manifestVersion: must be an integer", .{}),
        }
    } else {
        try diagnostics.add(.err, "manifestVersion: missing required manifest version", .{});
    }

    if (root.get("$schema")) |schema_value| {
        if (schema_value == .string and manifest_version != null) {
            if (rushCompletionSchemaVersion(schema_value.string)) |schema_version| {
                if (schema_version != manifest_version.?) {
                    try diagnostics.add(.warning, "$schema: references Rush completion schema v{d}, but manifestVersion is {d}", .{ schema_version, manifest_version.? });
                }
            }
        }
    }

    const command = root.get("command") orelse {
        try diagnostics.add(.err, "command: missing required command object", .{});
        return;
    };
    try validateManifestCommand(allocator, diagnostics, command, &.{}, &.{}, &.{}, "command");
}

fn rushCompletionSchemaVersion(schema: []const u8) ?i64 {
    const marker_index = std.mem.indexOf(u8, schema, completion_manifest_schema_marker) orelse return null;
    var index = marker_index + completion_manifest_schema_marker.len;
    if (index >= schema.len or !std.ascii.isDigit(schema[index])) return null;
    const start = index;
    while (index < schema.len and std.ascii.isDigit(schema[index])) : (index += 1) {}
    return std.fmt.parseInt(i64, schema[start..index], 10) catch null;
}

fn validateManifestCommand(
    allocator: std.mem.Allocator,
    diagnostics: *CompletionManifestDiagnostics,
    command_value: std.json.Value,
    inherited_providers: []const CompletionManifestProviderInfo,
    inherited_options: []const CompletionManifestOptionSpelling,
    inherited_groups: []const []const u8,
    path: []const u8,
) anyerror!void {
    const command = switch (command_value) {
        .object => |object| object,
        else => {
            try diagnostics.add(.err, "{s}: command must be an object", .{path});
            return;
        },
    };

    if (command.get("name")) |name_value| {
        try validateManifestNameValue(allocator, diagnostics, name_value, try manifestFieldPath(allocator, path, "name"), true);
    } else {
        try diagnostics.add(.err, "{s}.name: command name is required", .{path});
    }
    if (command.get("platforms")) |platforms| try validateManifestPlatforms(allocator, diagnostics, platforms, try manifestFieldPath(allocator, path, "platforms"));

    var providers: std.ArrayList(CompletionManifestProviderInfo) = .empty;
    defer providers.deinit(allocator);
    try providers.appendSlice(allocator, inherited_providers);
    if (command.get("providers")) |providers_value| {
        const provider_path = try manifestFieldPath(allocator, path, "providers");
        defer allocator.free(provider_path);
        const provider_object = switch (providers_value) {
            .object => |object| object,
            else => null,
        };
        if (provider_object) |object| {
            var iter = object.iterator();
            while (iter.next()) |entry| {
                const child_path = try manifestFieldPath(allocator, provider_path, entry.key_ptr.*);
                defer allocator.free(child_path);
                try validateManifestProvider(allocator, diagnostics, entry.value_ptr.*, child_path);
                try providers.append(allocator, completionManifestProviderInfo(entry.key_ptr.*, entry.value_ptr.*));
            }
        }
    }

    var groups: std.ArrayList([]const u8) = .empty;
    defer groups.deinit(allocator);
    try groups.appendSlice(allocator, inherited_groups);
    if (command.get("optionGroups")) |groups_value| {
        const groups_path = try manifestFieldPath(allocator, path, "optionGroups");
        defer allocator.free(groups_path);
        const group_array = switch (groups_value) {
            .array => |array| array,
            else => null,
        };
        if (group_array) |array| {
            var local_groups: std.StringHashMapUnmanaged(void) = .empty;
            defer local_groups.deinit(allocator);
            for (array.items, 0..) |group_value, index| {
                const group_path = try manifestIndexPath(allocator, groups_path, index);
                defer allocator.free(group_path);
                const group = switch (group_value) {
                    .object => |object| object,
                    else => continue,
                };
                const name = manifestString(group.get("name")) orelse continue;
                if (local_groups.contains(name)) {
                    try diagnostics.add(.err, "{s}.name: duplicate option group '{s}'", .{ group_path, name });
                } else {
                    try local_groups.put(allocator, name, {});
                }
                try groups.append(allocator, name);
            }
        }
    }

    var options: std.ArrayList(CompletionManifestOptionSpelling) = .empty;
    defer options.deinit(allocator);
    try options.appendSlice(allocator, inherited_options);
    var child_options: std.ArrayList(CompletionManifestOptionSpelling) = .empty;
    defer child_options.deinit(allocator);
    try child_options.appendSlice(allocator, inherited_options);
    if (command.get("options")) |options_value| {
        const options_path = try manifestFieldPath(allocator, path, "options");
        defer allocator.free(options_path);
        const option_array = switch (options_value) {
            .array => |array| array,
            else => null,
        };
        if (option_array) |array| {
            for (array.items, 0..) |option_value, index| {
                const option_path = try manifestIndexPath(allocator, options_path, index);
                defer allocator.free(option_path);
                try validateManifestOption(allocator, diagnostics, option_value, providers.items, &options, &child_options, groups.items, option_path);
            }
            for (array.items, 0..) |option_value, index| {
                const option = switch (option_value) {
                    .object => |object| object,
                    else => continue,
                };
                const option_path = try manifestIndexPath(allocator, options_path, index);
                defer allocator.free(option_path);
                try validateManifestOptionExcludes(allocator, diagnostics, option, options.items, option_path);
            }
        }
    }

    if (command.get("dynamicSubcommands")) |dynamic_subcommands| {
        try validateManifestProviderRefArray(allocator, diagnostics, dynamic_subcommands, providers.items, try manifestFieldPath(allocator, path, "dynamicSubcommands"));
    }
    if (command.get("dynamicOptions")) |dynamic_options| {
        try validateManifestProviderRefArray(allocator, diagnostics, dynamic_options, providers.items, try manifestFieldPath(allocator, path, "dynamicOptions"));
    }

    if (command.get("arguments")) |arguments| {
        const arguments_path = try manifestFieldPath(allocator, path, "arguments");
        defer allocator.free(arguments_path);
        try validateManifestArguments(allocator, diagnostics, arguments, providers.items, options.items, arguments_path);
    }

    if (command.get("subcommands")) |subcommands_value| {
        const subcommands_path = try manifestFieldPath(allocator, path, "subcommands");
        defer allocator.free(subcommands_path);
        const subcommands = switch (subcommands_value) {
            .array => |array| array,
            else => null,
        };
        if (subcommands) |array| {
            var seen_subcommands: std.StringHashMapUnmanaged(void) = .empty;
            defer seen_subcommands.deinit(allocator);
            for (array.items, 0..) |subcommand, index| {
                const subcommand_path = try manifestIndexPath(allocator, subcommands_path, index);
                defer allocator.free(subcommand_path);
                if (subcommand == .object) try validateManifestSubcommandNames(allocator, diagnostics, subcommand.object, &seen_subcommands, subcommand_path);
                try validateManifestCommand(allocator, diagnostics, subcommand, providers.items, child_options.items, groups.items, subcommand_path);
            }
        }
    }

    if (command.get("variants")) |variants| try validateManifestVariants(allocator, diagnostics, command, variants, providers.items, options.items, groups.items, try manifestFieldPath(allocator, path, "variants"));
    if (command.get("variantProbe")) |probe| try validateManifestVariantProbe(allocator, diagnostics, probe, command.get("variants"), try manifestFieldPath(allocator, path, "variantProbe"));
}

fn validateManifestVariants(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, command: std.json.ObjectMap, variants_value: std.json.Value, providers: []const CompletionManifestProviderInfo, inherited_options: []const CompletionManifestOptionSpelling, groups: []const []const u8, path: []const u8) anyerror!void {
    defer allocator.free(path);
    _ = command;
    const variants = switch (variants_value) {
        .object => |object| object,
        else => return,
    };
    var iter = variants.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const variant_path = try manifestFieldPath(allocator, path, name);
        defer allocator.free(variant_path);
        if (name.len == 0) try diagnostics.add(.err, "{s}: variant name must not be empty", .{variant_path});
        const overlay = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => {
                try diagnostics.add(.err, "{s}: variant overlay must be an object", .{variant_path});
                continue;
            },
        };
        try validateManifestCommandOverlay(allocator, diagnostics, overlay, providers, inherited_options, groups, variant_path);
    }
}

fn validateManifestCommandOverlay(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, overlay: std.json.ObjectMap, inherited_providers: []const CompletionManifestProviderInfo, inherited_options: []const CompletionManifestOptionSpelling, inherited_groups: []const []const u8, path: []const u8) anyerror!void {
    if (overlay.get("platforms")) |platforms| try validateManifestPlatforms(allocator, diagnostics, platforms, try manifestFieldPath(allocator, path, "platforms"));
    var providers: std.ArrayList(CompletionManifestProviderInfo) = .empty;
    defer providers.deinit(allocator);
    try providers.appendSlice(allocator, inherited_providers);
    if (overlay.get("providers")) |providers_value| {
        const provider_path = try manifestFieldPath(allocator, path, "providers");
        defer allocator.free(provider_path);
        if (providers_value == .object) {
            var iter = providers_value.object.iterator();
            while (iter.next()) |entry| {
                const child_path = try manifestFieldPath(allocator, provider_path, entry.key_ptr.*);
                defer allocator.free(child_path);
                try validateManifestProvider(allocator, diagnostics, entry.value_ptr.*, child_path);
                try providers.append(allocator, completionManifestProviderInfo(entry.key_ptr.*, entry.value_ptr.*));
            }
        }
    }

    var groups: std.ArrayList([]const u8) = .empty;
    defer groups.deinit(allocator);
    try groups.appendSlice(allocator, inherited_groups);
    if (overlay.get("optionGroups")) |groups_value| if (groups_value == .array) {
        for (groups_value.array.items) |group_value| if (group_value == .object) if (manifestString(group_value.object.get("name"))) |name| try groups.append(allocator, name);
    };

    var options: std.ArrayList(CompletionManifestOptionSpelling) = .empty;
    defer options.deinit(allocator);
    try options.appendSlice(allocator, inherited_options);
    var child_options: std.ArrayList(CompletionManifestOptionSpelling) = .empty;
    defer child_options.deinit(allocator);
    try child_options.appendSlice(allocator, inherited_options);
    if (overlay.get("options")) |options_value| if (options_value == .array) {
        const options_path = try manifestFieldPath(allocator, path, "options");
        defer allocator.free(options_path);
        for (options_value.array.items, 0..) |option_value, index| {
            const option_path = try manifestIndexPath(allocator, options_path, index);
            defer allocator.free(option_path);
            try validateManifestOption(allocator, diagnostics, option_value, providers.items, &options, &child_options, groups.items, option_path);
        }
        for (options_value.array.items, 0..) |option_value, index| {
            const option = switch (option_value) {
                .object => |object| object,
                else => continue,
            };
            const option_path = try manifestIndexPath(allocator, options_path, index);
            defer allocator.free(option_path);
            try validateManifestOptionExcludes(allocator, diagnostics, option, options.items, option_path);
        }
    };
    if (overlay.get("arguments")) |arguments| {
        const arguments_path = try manifestFieldPath(allocator, path, "arguments");
        defer allocator.free(arguments_path);
        try validateManifestArguments(allocator, diagnostics, arguments, providers.items, options.items, arguments_path);
    }
    if (overlay.get("dynamicSubcommands")) |dynamic_subcommands| try validateManifestProviderRefArray(allocator, diagnostics, dynamic_subcommands, providers.items, try manifestFieldPath(allocator, path, "dynamicSubcommands"));
    if (overlay.get("dynamicOptions")) |dynamic_options| try validateManifestProviderRefArray(allocator, diagnostics, dynamic_options, providers.items, try manifestFieldPath(allocator, path, "dynamicOptions"));
    if (overlay.get("subcommands")) |subcommands_value| if (subcommands_value == .array) {
        const subcommands_path = try manifestFieldPath(allocator, path, "subcommands");
        defer allocator.free(subcommands_path);
        for (subcommands_value.array.items, 0..) |subcommand, index| {
            const subcommand_path = try manifestIndexPath(allocator, subcommands_path, index);
            defer allocator.free(subcommand_path);
            try validateManifestCommand(allocator, diagnostics, subcommand, providers.items, child_options.items, groups.items, subcommand_path);
        }
    };
}

fn validateManifestVariantProbe(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, probe_value: std.json.Value, variants_value: ?std.json.Value, path: []const u8) !void {
    defer allocator.free(path);
    const probe = switch (probe_value) {
        .object => |object| object,
        else => return,
    };
    if (probe.get("args")) |args| if (args == .array and args.array.items.len == 0) try diagnostics.add(.err, "{s}.args: variant probe args must not be empty", .{path});
    const matches_value = probe.get("matches") orelse return;
    const matches = switch (matches_value) {
        .object => |object| object,
        else => return,
    };
    var iter = matches.iterator();
    var index: usize = 0;
    while (iter.next()) |entry| : (index += 1) {
        const variant_name = entry.key_ptr.*;
        if (!manifestVariantExists(variants_value, variant_name)) try diagnostics.add(.err, "{s}.matches.{s}: unknown variant '{s}'", .{ path, variant_name, variant_name });
        const pattern = manifestString(entry.value_ptr.*) orelse continue;
        if (pattern.len == 0 and index + 1 != matches.count()) try diagnostics.add(.err, "{s}.matches.{s}: empty pattern is only allowed for the final fallback", .{ path, variant_name });
    }
}

fn manifestVariantExists(variants_value: ?std.json.Value, name: []const u8) bool {
    const variants = switch (variants_value orelse return false) {
        .object => |object| object,
        else => return false,
    };
    return variants.get(name) != null;
}

fn validateManifestOption(
    allocator: std.mem.Allocator,
    diagnostics: *CompletionManifestDiagnostics,
    option_value: std.json.Value,
    providers: []const CompletionManifestProviderInfo,
    options: *std.ArrayList(CompletionManifestOptionSpelling),
    child_options: *std.ArrayList(CompletionManifestOptionSpelling),
    groups: []const []const u8,
    path: []const u8,
) !void {
    const option = switch (option_value) {
        .object => |object| object,
        else => return,
    };
    if (option.get("platforms")) |platforms| try validateManifestPlatforms(allocator, diagnostics, platforms, try manifestFieldPath(allocator, path, "platforms"));

    var has_spelling = false;
    const takes_value = option.get("value") != null;
    const option_key = manifestString(option.get("long")) orelse manifestString(option.get("short")) orelse manifestFirstString(option.get("spellings")) orelse "";
    const enum_values = manifestOptionEnumValues(option, providers);
    const inherit = manifestBoolDefault(option.get("inherit"), true);
    if (manifestString(option.get("short"))) |short| {
        has_spelling = true;
        const spelling: CompletionManifestOptionSpelling = .{ .kind = .short, .value = short, .key = option_key, .takes_value = takes_value, .enum_values = enum_values };
        if (try appendManifestOptionSpelling(diagnostics, options, spelling, path) and inherit) try child_options.append(diagnostics.allocator, spelling);
    }
    if (manifestString(option.get("long"))) |long| {
        has_spelling = true;
        const spelling: CompletionManifestOptionSpelling = .{ .kind = .long, .value = long, .key = option_key, .takes_value = takes_value, .enum_values = enum_values };
        if (try appendManifestOptionSpelling(diagnostics, options, spelling, path) and inherit) try child_options.append(diagnostics.allocator, spelling);
    }
    if (option.get("spellings")) |spellings_value| {
        const spellings = switch (spellings_value) {
            .array => |array| array,
            else => null,
        };
        if (spellings) |array| {
            const spellings_path = try manifestFieldPath(allocator, path, "spellings");
            defer allocator.free(spellings_path);
            for (array.items, 0..) |spelling_value, index| {
                const literal = manifestString(spelling_value) orelse continue;
                const spelling_path = try manifestIndexPath(allocator, spellings_path, index);
                defer allocator.free(spelling_path);
                has_spelling = true;
                const spelling: CompletionManifestOptionSpelling = .{ .kind = .literal, .value = literal, .key = option_key, .takes_value = takes_value and !std.mem.startsWith(u8, literal, "+"), .enum_values = enum_values };
                if (try appendManifestOptionSpelling(diagnostics, options, spelling, spelling_path) and inherit) try child_options.append(diagnostics.allocator, spelling);
            }
        }
    }
    if (option.get("aliases")) |aliases_value| {
        const aliases = switch (aliases_value) {
            .array => |array| array,
            else => null,
        };
        if (aliases) |array| {
            const aliases_path = try manifestFieldPath(allocator, path, "aliases");
            defer allocator.free(aliases_path);
            for (array.items, 0..) |alias_value, index| {
                const alias = manifestString(alias_value) orelse continue;
                const alias_path = try manifestIndexPath(allocator, aliases_path, index);
                defer allocator.free(alias_path);
                const spelling: CompletionManifestOptionSpelling = .{ .kind = .long, .value = alias, .key = option_key, .takes_value = takes_value, .enum_values = enum_values };
                if (try appendManifestOptionSpelling(diagnostics, options, spelling, alias_path) and inherit) try child_options.append(diagnostics.allocator, spelling);
            }
        }
    }
    if (!has_spelling) try diagnostics.add(.err, "{s}: option must define short, long, or spellings", .{path});

    if (manifestString(option.get("exclusiveGroup"))) |group| {
        if (!manifestStringListContains(groups, group)) {
            try diagnostics.add(.err, "{s}.exclusiveGroup: undefined option group '{s}' (declare it in optionGroups)", .{ path, group });
        }
    }

    if (option.get("value")) |value| {
        const value_path = try manifestFieldPath(allocator, path, "value");
        defer allocator.free(value_path);
        try validateManifestOptionValue(allocator, diagnostics, value, providers, value_path);
    }
}

fn validateManifestOptionExcludes(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, option: std.json.ObjectMap, options: []const CompletionManifestOptionSpelling, path: []const u8) !void {
    const excludes = option.get("excludes") orelse return;
    const excludes_path = try manifestFieldPath(allocator, path, "excludes");
    defer allocator.free(excludes_path);
    switch (excludes) {
        .string => |selector| {
            if (!completionManifestExcludeSentinel(selector)) {
                try diagnostics.add(.err, "{s}: bare excludes string must be 'operands' or 'everything' (use an array for option selectors)", .{excludes_path});
            }
        },
        .array => |array| {
            for (array.items, 0..) |item, index| {
                const selector = manifestString(item) orelse continue;
                const selector_path = try manifestIndexPath(allocator, excludes_path, index);
                defer allocator.free(selector_path);
                try validateManifestOptionExclude(diagnostics, option, options, selector, selector_path);
            }
        },
        else => {},
    }
}

fn validateManifestOptionExclude(diagnostics: *CompletionManifestDiagnostics, option: std.json.ObjectMap, options: []const CompletionManifestOptionSpelling, selector: []const u8, path: []const u8) !void {
    if (completionManifestExcludeSentinel(selector)) return;
    const excluded = findManifestOptionSelector(options, selector) orelse {
        try validateManifestOptionSelector(diagnostics, selector, options, path);
        return;
    };
    if (manifestOptionObjectHasSelector(option, excluded.kind, excluded.value)) {
        try diagnostics.add(.err, "{s}: option must not exclude itself ('{s}')", .{ path, selector });
    }
}

fn completionManifestExcludeSentinel(value: []const u8) bool {
    return std.mem.eql(u8, value, "operands") or std.mem.eql(u8, value, "everything");
}

fn manifestOptionObjectHasSelector(option: std.json.ObjectMap, kind: CompletionManifestOptionSpellingKind, value: []const u8) bool {
    switch (kind) {
        .short => if (manifestString(option.get("short"))) |short| return std.mem.eql(u8, short, value),
        .long => {
            if (manifestString(option.get("long"))) |long| if (std.mem.eql(u8, long, value)) return true;
            const aliases = switch (option.get("aliases") orelse return false) {
                .array => |array| array,
                else => return false,
            };
            for (aliases.items) |alias_value| {
                if (manifestString(alias_value)) |alias| if (std.mem.eql(u8, alias, value)) return true;
            }
        },
        .literal => return manifestOptionHasLiteralSpelling(option, value),
    }
    return false;
}

fn validateManifestOptionValue(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, providers: []const CompletionManifestProviderInfo, path: []const u8) anyerror!void {
    switch (value) {
        .object => try validateManifestValueObject(allocator, diagnostics, value, providers, path),
        .array => |array| {
            var optional_started = false;
            for (array.items, 0..) |value_item, index| {
                const value_path = try manifestIndexPath(allocator, path, index);
                defer allocator.free(value_path);
                try validateManifestValueObject(allocator, diagnostics, value_item, providers, value_path);
                const object = switch (value_item) {
                    .object => |object| object,
                    else => continue,
                };
                const required = manifestBoolDefault(object.get("required"), true);
                if (!required) optional_started = true else if (optional_started) {
                    try diagnostics.add(.err, "{s}.required: required option values cannot follow optional values", .{value_path});
                }
                if (index != 0) {
                    if (manifestString(object.get("style"))) |style| {
                        if (!std.mem.eql(u8, style, "detached")) {
                            try diagnostics.add(.err, "{s}.style: only the first option value may use non-detached styles", .{value_path});
                        }
                    }
                }
            }
        },
        else => {},
    }
}

fn validateManifestPlatforms(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, path: []const u8) !void {
    defer allocator.free(path);
    const platforms = switch (value) {
        .array => |array| array,
        else => return,
    };
    if (platforms.items.len == 0) try diagnostics.add(.err, "{s}: platforms must not be empty", .{path});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (platforms.items, 0..) |platform_value, index| {
        const platform = manifestString(platform_value) orelse continue;
        const platform_path = try manifestIndexPath(allocator, path, index);
        defer allocator.free(platform_path);
        if (!completionManifestPlatformKnown(platform)) {
            try diagnostics.add(.err, "{s}: unknown platform '{s}'", .{ platform_path, platform });
        } else if (seen.contains(platform)) {
            try diagnostics.add(.err, "{s}: duplicate platform '{s}'", .{ platform_path, platform });
        } else {
            try seen.put(allocator, platform, {});
        }
    }
}

fn validateManifestArguments(
    allocator: std.mem.Allocator,
    diagnostics: *CompletionManifestDiagnostics,
    arguments_value: std.json.Value,
    providers: []const CompletionManifestProviderInfo,
    options: []const CompletionManifestOptionSpelling,
    path: []const u8,
) !void {
    const arguments = switch (arguments_value) {
        .object => |object| object,
        else => return,
    };
    const states_value = arguments.get("states") orelse return;
    const states = switch (states_value) {
        .array => |array| array,
        else => return,
    };
    const states_path = try manifestFieldPath(allocator, path, "states");
    defer allocator.free(states_path);

    var state_names: std.ArrayList([]const u8) = .empty;
    defer state_names.deinit(allocator);
    var seen_names: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_names.deinit(allocator);
    for (states.items, 0..) |state_value, index| {
        const state_path = try manifestIndexPath(allocator, states_path, index);
        defer allocator.free(state_path);
        const state = switch (state_value) {
            .object => |object| object,
            else => continue,
        };
        const name = manifestString(state.get("name")) orelse continue;
        if (seen_names.contains(name)) {
            try diagnostics.add(.err, "{s}.name: duplicate argument state '{s}'", .{ state_path, name });
        } else {
            try seen_names.put(allocator, name, {});
        }
        try state_names.append(allocator, name);
    }

    var seen_indexes: std.ArrayList(usize) = .empty;
    defer seen_indexes.deinit(allocator);
    var next_reachable_index: usize = 0;
    var trailing_repeatable: ?[]const u8 = null;
    const terminator_defined = arguments.get("terminator") != null;
    for (states.items, 0..) |state_value, index| {
        const state_path = try manifestIndexPath(allocator, states_path, index);
        defer allocator.free(state_path);
        const state = switch (state_value) {
            .object => |object| object,
            else => continue,
        };
        const state_name = manifestString(state.get("name")) orelse "<unnamed>";
        const rest_command_line = manifestRestCommandLine(state.get("rest"));

        if (state.get("rest")) |_| {
            const rest_path = try manifestFieldPath(allocator, state_path, "rest");
            defer allocator.free(rest_path);
            if (!rest_command_line) try diagnostics.add(.err, "{s}: argument state rest must be 'command-line'", .{rest_path});
        }
        if (rest_command_line and index + 1 != states.items.len) {
            try diagnostics.add(.err, "{s}.rest: command-line rest state must be the final argument state", .{state_path});
        }
        if (rest_command_line and manifestBool(state.get("repeatable"))) {
            try diagnostics.add(.err, "{s}.repeatable: command-line rest state is implicitly repeatable and must not set repeatable", .{state_path});
        }
        if (rest_command_line and state.get("provider") != null) {
            try diagnostics.add(.err, "{s}.provider: command-line rest state must not define a provider", .{state_path});
        }
        if (rest_command_line and state.get("grammar") != null) {
            try diagnostics.add(.err, "{s}.grammar: command-line rest state must not define grammar", .{state_path});
        }

        if (trailing_repeatable) |repeatable_name| {
            if (state.get("after") == null) {
                try diagnostics.add(.err, "{s}: argument state '{s}' is unreachable after unconditional repeatable state '{s}'", .{ state_path, state_name, repeatable_name });
            }
        }

        if (manifestInteger(state.get("index"))) |state_index| {
            if (state_index < 0) continue;
            const argument_index: usize = @intCast(state_index);
            if (manifestIndexListContains(seen_indexes.items, argument_index)) {
                try diagnostics.add(.err, "{s}.index: duplicate argument index {d}", .{ state_path, argument_index });
            } else {
                try seen_indexes.append(allocator, argument_index);
            }
            if (argument_index > next_reachable_index) {
                try diagnostics.add(.err, "{s}.index: argument state '{s}' is unreachable because index {d} leaves a gap before index {d}", .{ state_path, state_name, argument_index, next_reachable_index });
            }
            next_reachable_index = @max(next_reachable_index, argument_index + 1);
        } else if (state.get("after") == null and !manifestBool(state.get("repeatable"))) {
            next_reachable_index += 1;
        }

        if (state.get("provider")) |provider| {
            const provider_path = try manifestFieldPath(allocator, state_path, "provider");
            defer allocator.free(provider_path);
            try validateManifestProviderRefOrArray(allocator, diagnostics, provider, providers, provider_path);
        }
        if (state.get("grammar")) |grammar| {
            const grammar_path = try manifestFieldPath(allocator, state_path, "grammar");
            defer allocator.free(grammar_path);
            try validateManifestValueGrammar(allocator, diagnostics, grammar, providers, grammar_path);
        }
        inline for (&.{ "when", "after", "until" }) |field| {
            if (state.get(field)) |condition| {
                const condition_path = try manifestFieldPath(allocator, state_path, field);
                defer allocator.free(condition_path);
                try validateManifestCondition(allocator, diagnostics, condition, options, state_names.items, terminator_defined, condition_path);
            }
        }
        if ((manifestBool(state.get("repeatable")) or rest_command_line) and state.get("until") == null and state.get("after") == null) trailing_repeatable = state_name;
    }
}

fn validateManifestCondition(
    allocator: std.mem.Allocator,
    diagnostics: *CompletionManifestDiagnostics,
    condition_value: std.json.Value,
    options: []const CompletionManifestOptionSpelling,
    state_names: []const []const u8,
    terminator_defined: bool,
    path: []const u8,
) !void {
    const condition = switch (condition_value) {
        .object => |object| object,
        else => return,
    };
    if (manifestBool(condition.get("terminatorSeen")) and !terminator_defined) {
        try diagnostics.add(.err, "{s}.terminatorSeen: condition is unreachable because arguments.terminator is not defined", .{path});
    }
    if (manifestString(condition.get("previousState"))) |previous_state| {
        if (!manifestStringListContains(state_names, previous_state)) {
            try diagnostics.add(.err, "{s}.previousState: unknown argument state '{s}'", .{ path, previous_state });
        }
    }
    inline for (&.{ "optionPresent", "optionAbsent" }) |field| {
        if (condition.get(field)) |selector_or_selectors| {
            const selector_path = try manifestFieldPath(allocator, path, field);
            defer allocator.free(selector_path);
            try validateManifestOptionSelectorOrSelectors(allocator, diagnostics, selector_or_selectors, options, selector_path);
        }
    }
    if (condition.get("optionValue")) |option_value| {
        const option_value_path = try manifestFieldPath(allocator, path, "optionValue");
        defer allocator.free(option_value_path);
        try validateManifestOptionValueCondition(allocator, diagnostics, option_value, options, option_value_path);
    }
    inline for (&.{ "all", "any" }) |field| {
        if (condition.get(field)) |children| {
            const children_array = switch (children) {
                .array => |array| array,
                else => null,
            };
            if (children_array) |array| {
                const children_path = try manifestFieldPath(allocator, path, field);
                defer allocator.free(children_path);
                for (array.items, 0..) |child, index| {
                    const child_path = try manifestIndexPath(allocator, children_path, index);
                    defer allocator.free(child_path);
                    try validateManifestCondition(allocator, diagnostics, child, options, state_names, terminator_defined, child_path);
                }
            }
        }
    }
    if (condition.get("not")) |child| {
        const child_path = try manifestFieldPath(allocator, path, "not");
        defer allocator.free(child_path);
        try validateManifestCondition(allocator, diagnostics, child, options, state_names, terminator_defined, child_path);
    }
}

fn validateManifestOptionValueCondition(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, options: []const CompletionManifestOptionSpelling, path: []const u8) !void {
    const object = switch (value) {
        .object => |object| object,
        else => return,
    };
    if (object.count() != 1) try diagnostics.add(.err, "{s}: optionValue condition must map exactly one option selector", .{path});
    var iter = object.iterator();
    while (iter.next()) |entry| {
        const selector = entry.key_ptr.*;
        const selector_path = try manifestFieldPath(allocator, path, selector);
        defer allocator.free(selector_path);
        const option = findManifestOptionSelector(options, selector) orelse {
            try validateManifestOptionSelector(diagnostics, selector, options, selector_path);
            continue;
        };
        if (!option.takes_value) {
            try diagnostics.add(.err, "{s}: option selector '{s}' does not take a value", .{ selector_path, selector });
        }
        switch (entry.value_ptr.*) {
            .string => |literal| try validateManifestOptionValueLiteral(diagnostics, option, literal, selector_path),
            .array => |array| {
                for (array.items, 0..) |item, index| {
                    const literal = manifestString(item) orelse continue;
                    const literal_path = try manifestIndexPath(allocator, selector_path, index);
                    defer allocator.free(literal_path);
                    try validateManifestOptionValueLiteral(diagnostics, option, literal, literal_path);
                }
            },
            else => {},
        }
    }
}

fn validateManifestOptionValueLiteral(diagnostics: *CompletionManifestDiagnostics, option: CompletionManifestOptionSpelling, literal: []const u8, path: []const u8) !void {
    const enum_values = option.enum_values orelse return;
    if (!manifestEnumValuesContain(enum_values, literal)) {
        try diagnostics.add(.err, "{s}: option value literal '{s}' is not in the option enum", .{ path, literal });
    }
}

fn manifestEnumValuesContain(values: std.json.Array, literal: []const u8) bool {
    for (values.items) |value| {
        const choice = switch (value) {
            .string => |string| string,
            .object => |object| manifestString(object.get("value")) orelse continue,
            else => continue,
        };
        if (std.mem.eql(u8, choice, literal)) return true;
    }
    return false;
}

fn validateManifestValueObject(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, providers: []const CompletionManifestProviderInfo, path: []const u8) anyerror!void {
    const object = switch (value) {
        .object => |object| object,
        else => return,
    };
    if (object.get("provider")) |provider| {
        const provider_path = try manifestFieldPath(allocator, path, "provider");
        defer allocator.free(provider_path);
        try validateManifestProviderRefOrArray(allocator, diagnostics, provider, providers, provider_path);
    }
    if (object.get("grammar")) |grammar| {
        const grammar_path = try manifestFieldPath(allocator, path, "grammar");
        defer allocator.free(grammar_path);
        try validateManifestValueGrammar(allocator, diagnostics, grammar, providers, grammar_path);
    }
}

fn validateManifestValueGrammar(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, grammar: std.json.Value, providers: []const CompletionManifestProviderInfo, path: []const u8) anyerror!void {
    const object = switch (grammar) {
        .object => |object| object,
        else => return,
    };
    if (object.get("item")) |item| {
        const item_path = try manifestFieldPath(allocator, path, "item");
        defer allocator.free(item_path);
        try validateManifestValueObject(allocator, diagnostics, item, providers, item_path);
    }
    inline for (&.{ "key", "value" }) |field| {
        if (object.get(field)) |nested| {
            const nested_path = try manifestFieldPath(allocator, path, field);
            defer allocator.free(nested_path);
            try validateManifestValueObject(allocator, diagnostics, nested, providers, nested_path);
        }
    }
}

fn validateManifestProviderRefArray(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, providers: []const CompletionManifestProviderInfo, path: []const u8) !void {
    defer allocator.free(path);
    const array = switch (value) {
        .array => |array| array,
        else => return,
    };
    for (array.items, 0..) |provider, index| {
        const provider_path = try manifestIndexPath(allocator, path, index);
        defer allocator.free(provider_path);
        try validateManifestProviderRef(allocator, diagnostics, provider, providers, provider_path);
    }
}

fn validateManifestProviderRefOrArray(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, providers: []const CompletionManifestProviderInfo, path: []const u8) !void {
    switch (value) {
        .array => |array| {
            if (array.items.len == 0) try diagnostics.add(.err, "{s}: provider array must not be empty", .{path});
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            for (array.items, 0..) |provider, index| {
                const provider_path = try manifestIndexPath(allocator, path, index);
                defer allocator.free(provider_path);
                if (manifestString(provider)) |provider_id| {
                    if (seen.contains(provider_id)) {
                        try diagnostics.add(.err, "{s}: duplicate provider ref '{s}'", .{ provider_path, provider_id });
                    } else {
                        try seen.put(allocator, provider_id, {});
                    }
                }
                try validateManifestProviderRef(allocator, diagnostics, provider, providers, provider_path);
            }
        },
        else => try validateManifestProviderRef(allocator, diagnostics, value, providers, path),
    }
}

fn validateManifestProviderRef(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, providers: []const CompletionManifestProviderInfo, path: []const u8) !void {
    switch (value) {
        .string => |provider_id| {
            if (findCompletionManifestProviderInfo(providers, provider_id) == null) {
                try diagnostics.add(.err, "{s}: unknown provider '{s}'", .{ path, provider_id });
            }
        },
        .object => try validateManifestProvider(allocator, diagnostics, value, path),
        else => {},
    }
}

fn completionManifestProviderInfo(id: []const u8, value: std.json.Value) CompletionManifestProviderInfo {
    const provider = switch (value) {
        .object => |object| object,
        else => return .{ .id = id },
    };
    const values = switch (provider.get("values") orelse return .{ .id = id }) {
        .array => |array| array,
        else => return .{ .id = id },
    };
    return .{ .id = id, .static_values = values };
}

fn findCompletionManifestProviderInfo(providers: []const CompletionManifestProviderInfo, provider_id: []const u8) ?CompletionManifestProviderInfo {
    var index = providers.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, providers[index].id, provider_id)) return providers[index];
    }
    return null;
}

fn validateManifestProvider(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, path: []const u8) !void {
    const provider = switch (value) {
        .object => |object| object,
        else => return,
    };
    const has_function = provider.get("function") != null;
    const has_builtin = provider.get("builtin") != null;
    const has_values = provider.get("values") != null;
    const binding_count = @as(u8, if (has_function) 1 else 0) + @as(u8, if (has_builtin) 1 else 0) + @as(u8, if (has_values) 1 else 0);
    if (binding_count != 1) {
        try diagnostics.add(.err, "{s}: provider must define exactly one of function, builtin, or values", .{path});
    }
    if (provider.get("function")) |function| {
        if (manifestString(function) == null) try diagnostics.add(.err, "{s}.function: provider function must be a string", .{path});
    }
    if (provider.get("tag")) |tag| {
        if (manifestString(tag) == null) try diagnostics.add(.err, "{s}.tag: provider tag must be a string", .{path});
    }
    if (provider.get("builtin")) |builtin_value| {
        const builtin = manifestString(builtin_value) orelse {
            try diagnostics.add(.err, "{s}.builtin: provider builtin must be a string", .{path});
            return;
        };
        if (completionManifestBuiltinProviderKind(builtin) == null) {
            try diagnostics.add(.err, "{s}.builtin: unsupported builtin provider '{s}'", .{ path, builtin });
        }
        if (provider.get("options") != null) {
            try diagnostics.add(.err, "{s}.options: builtin provider options are not supported in completion manifest v1", .{path});
        }
    }
    if (provider.get("values")) |values| {
        const values_path = try manifestFieldPath(allocator, path, "values");
        defer allocator.free(values_path);
        try validateManifestStaticProviderValues(allocator, diagnostics, values, values_path);
    }
}

fn validateManifestStaticProviderValues(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, values_value: std.json.Value, path: []const u8) !void {
    const values = switch (values_value) {
        .array => |array| array,
        else => {
            try diagnostics.add(.err, "{s}: static provider values must be an array", .{path});
            return;
        },
    };
    if (values.items.len == 0) try diagnostics.add(.err, "{s}: static provider values must not be empty", .{path});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    for (values.items, 0..) |value, index| {
        const value_path = try manifestIndexPath(allocator, path, index);
        defer allocator.free(value_path);
        const choice = switch (value) {
            .string => |string| string,
            .object => |object| manifestString(object.get("value")) orelse {
                try diagnostics.add(.err, "{s}.value: static provider value is required", .{value_path});
                continue;
            },
            else => {
                try diagnostics.add(.err, "{s}: static provider value must be a string or object", .{value_path});
                continue;
            },
        };
        if (value == .object and value.object.get("tag") != null and manifestString(value.object.get("tag")) == null) {
            try diagnostics.add(.err, "{s}.tag: static provider value tag must be a string", .{value_path});
        }
        if (seen.contains(choice)) {
            try diagnostics.add(.err, "{s}: duplicate static provider value '{s}'", .{ value_path, choice });
        } else {
            try seen.put(allocator, choice, {});
        }
    }
}

fn validateManifestSubcommandNames(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, command: std.json.ObjectMap, seen: *std.StringHashMapUnmanaged(void), path: []const u8) !void {
    const name_path = try manifestFieldPath(allocator, path, "name");
    defer allocator.free(name_path);
    if (command.get("name")) |name_value| try appendManifestCommandNames(allocator, diagnostics, seen, name_value, name_path);
    if (command.get("aliases")) |aliases_value| {
        const aliases = switch (aliases_value) {
            .array => |array| array,
            else => return,
        };
        const aliases_path = try manifestFieldPath(allocator, path, "aliases");
        defer allocator.free(aliases_path);
        for (aliases.items, 0..) |alias_value, index| {
            const alias = manifestString(alias_value) orelse continue;
            const alias_path = try manifestIndexPath(allocator, aliases_path, index);
            defer allocator.free(alias_path);
            if (seen.contains(alias)) {
                try diagnostics.add(.err, "{s}: duplicate subcommand name or alias '{s}'", .{ alias_path, alias });
            } else {
                try seen.put(allocator, alias, {});
            }
        }
    }
}

fn appendManifestCommandNames(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, seen: *std.StringHashMapUnmanaged(void), value: std.json.Value, path: []const u8) !void {
    switch (value) {
        .string => |name| {
            if (seen.contains(name)) {
                try diagnostics.add(.err, "{s}: duplicate subcommand name or alias '{s}'", .{ path, name });
            } else {
                try seen.put(allocator, name, {});
            }
        },
        .array => |names| for (names.items, 0..) |name_value, index| {
            const name = manifestString(name_value) orelse continue;
            const name_path = try manifestIndexPath(allocator, path, index);
            defer allocator.free(name_path);
            if (seen.contains(name)) {
                try diagnostics.add(.err, "{s}: duplicate subcommand name or alias '{s}'", .{ name_path, name });
            } else {
                try seen.put(allocator, name, {});
            }
        },
        else => {},
    }
}

fn validateManifestNameValue(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, path: []const u8, non_empty_array: bool) !void {
    defer allocator.free(path);
    switch (value) {
        .string => {},
        .array => |array| {
            if (non_empty_array and array.items.len == 0) try diagnostics.add(.err, "{s}: name array must not be empty", .{path});
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(allocator);
            for (array.items, 0..) |item, index| {
                const name = manifestString(item) orelse continue;
                if (seen.contains(name)) {
                    const item_path = try manifestIndexPath(allocator, path, index);
                    defer allocator.free(item_path);
                    try diagnostics.add(.err, "{s}: duplicate name '{s}'", .{ item_path, name });
                } else {
                    try seen.put(allocator, name, {});
                }
            }
        },
        else => {},
    }
}

fn appendManifestOptionSpelling(diagnostics: *CompletionManifestDiagnostics, options: *std.ArrayList(CompletionManifestOptionSpelling), spelling: CompletionManifestOptionSpelling, path: []const u8) !bool {
    for (options.items) |existing| {
        if (manifestOptionSpellingEquals(existing, spelling)) {
            var spelling_buffer: [256]u8 = undefined;
            try diagnostics.add(.err, "{s}: duplicate option spelling '{s}'", .{ path, manifestOptionSpellingLiteralBuf(spelling, &spelling_buffer) orelse spelling.value });
            return false;
        }
    }
    try options.append(diagnostics.allocator, spelling);
    return true;
}

fn manifestOptionSpellingEquals(a: CompletionManifestOptionSpelling, b: CompletionManifestOptionSpelling) bool {
    if (a.kind == b.kind and std.mem.eql(u8, a.value, b.value)) return true;
    var a_buffer: [256]u8 = undefined;
    var b_buffer: [256]u8 = undefined;
    const a_literal = manifestOptionSpellingLiteralBuf(a, &a_buffer) orelse return false;
    const b_literal = manifestOptionSpellingLiteralBuf(b, &b_buffer) orelse return false;
    return std.mem.eql(u8, a_literal, b_literal);
}

fn manifestOptionSpellingLiteralBuf(spelling: CompletionManifestOptionSpelling, buffer: *[256]u8) ?[]const u8 {
    return switch (spelling.kind) {
        .literal => spelling.value,
        .short => std.fmt.bufPrint(buffer, "-{s}", .{spelling.value}) catch null,
        .long => std.fmt.bufPrint(buffer, "--{s}", .{spelling.value}) catch null,
    };
}

fn validateManifestOptionSelectorOrSelectors(allocator: std.mem.Allocator, diagnostics: *CompletionManifestDiagnostics, value: std.json.Value, options: []const CompletionManifestOptionSpelling, path: []const u8) !void {
    switch (value) {
        .string => |selector| try validateManifestOptionSelector(diagnostics, selector, options, path),
        .array => |array| for (array.items, 0..) |item, index| {
            const selector = manifestString(item) orelse continue;
            const selector_path = try manifestIndexPath(allocator, path, index);
            defer allocator.free(selector_path);
            try validateManifestOptionSelector(diagnostics, selector, options, selector_path);
        },
        else => {},
    }
}

fn validateManifestOptionSelector(diagnostics: *CompletionManifestDiagnostics, selector: []const u8, options: []const CompletionManifestOptionSpelling, path: []const u8) !void {
    if (findManifestOptionSelector(options, selector) != null) return;
    try diagnostics.add(.err, "{s}: unknown option selector '{s}'", .{ path, selector });
}

fn findManifestOptionSelector(options: []const CompletionManifestOptionSpelling, selector: []const u8) ?CompletionManifestOptionSpelling {
    for (options) |option| {
        var buffer: [256]u8 = undefined;
        const spelling = manifestOptionSpellingLiteralBuf(option, &buffer) orelse continue;
        if (std.mem.eql(u8, spelling, selector)) return option;
    }
    return null;
}

fn manifestFieldPath(allocator: std.mem.Allocator, path: []const u8, field: []const u8) ![]const u8 {
    if (path.len == 0) return allocator.dupe(u8, field);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, field });
}

fn manifestIndexPath(allocator: std.mem.Allocator, path: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
}

fn manifestStringListContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn manifestIndexListContains(values: []const usize, needle: usize) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn manifestInteger(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |integer| integer,
        else => null,
    };
}

fn manifestBool(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .bool => |boolean| boolean,
        else => false,
    };
}

fn manifestBoolDefault(value: ?std.json.Value, default: bool) bool {
    return switch (value orelse return default) {
        .bool => |boolean| boolean,
        else => default,
    };
}

fn completeInteractiveLine(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, source: []const u8, cursor: usize) !completion_model.Application {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    const eval_context = try exec.completionEvalContextForInput(allocator, source, cursor);
    if (eval_context.position != .command) {
        try completion_context.loader.ensureLoaded(completion_context.io, completion_context.executor, eval_context.command, completion_context.arg_zero);
    }
    const generation = completion_context.executor.completionGeneration();
    const matcher_policy = completion_model.MatcherPolicy.engineDefault();
    if (completion_context.cache.get(source, cursor, completion_context.cwd, generation)) |cached| {
        try completion_context.cache.startRefresh(completion_context.executor, completion_context.history, completion_context.io, source, cursor, completion_context.cwd, generation);
        return completion_model.applyCandidatesForInputWithPolicy(allocator, source, cached, matcher_policy);
    }
    const candidates = try completion_context.executor.collectCompletionsForInput(source, cursor, .{
        .io = io,
        .allow_external = true,
        .features = completion_context.features,
        .cancel = completion_context.cancel,
        .completion_loader = loadCompletionDataForExecutor,
        .completion_loader_context = completion_context.loader,
        .arg_zero = completion_context.arg_zero,
    });
    defer completion_context.executor.freeCompletions(candidates);
    try rankCompletionCandidates(allocator, candidates, completion_context.history.*, completion_context.cwd, source, matcher_policy);
    try completion_context.cache.put(source, cursor, completion_context.cwd, completion_context.executor.completionGeneration(), candidates);
    return completion_model.applyCandidatesForInputWithPolicy(allocator, source, candidates, matcher_policy);
}

fn expandInteractivePathname(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, word: []const u8) !line_editor.PathExpansionMatches {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    var patterns = try completion_context.executor.expandViPathnamePatterns(allocator, io, word);
    defer patterns.deinit(allocator);
    return viPathnameExpansionsForPatterns(allocator, io, patterns.items);
}

fn viPathnameExpansionsForWord(allocator: std.mem.Allocator, io: std.Io, word: []const u8) !line_editor.PathExpansionMatches {
    var patterns = try expand.expandWordPatterns(allocator, word, .{});
    defer patterns.deinit(allocator);
    return viPathnameExpansionsForPatterns(allocator, io, patterns.items);
}

fn viPathnameExpansionsForPatterns(allocator: std.mem.Allocator, io: std.Io, patterns: []const expand.ExpansionPattern) !line_editor.PathExpansionMatches {
    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |match| allocator.free(match);
        matches.deinit(allocator);
    }

    for (patterns) |pattern| {
        var pattern_matches = try viPathnameExpansions(allocator, io, pattern);
        defer pattern_matches.deinit(allocator);
        for (pattern_matches.items) |match| try matches.append(allocator, try allocator.dupe(u8, match));
    }

    return .{ .items = try matches.toOwnedSlice(allocator) };
}

fn viPathnameExpansions(allocator: std.mem.Allocator, io: std.Io, pattern: expand.ExpansionPattern) !line_editor.PathExpansionMatches {
    var owned_pattern: ?expand.ExpansionPattern = null;
    defer if (owned_pattern) |*owned| owned.deinit(allocator);

    const search_pattern = if (expand.patternHasGlobSyntax(pattern)) pattern else blk: {
        const text = try std.mem.concat(allocator, u8, &.{ pattern.text, "*" });
        errdefer allocator.free(text);
        const special = try allocator.alloc(bool, pattern.special.len + 1);
        errdefer allocator.free(special);
        @memcpy(special[0..pattern.special.len], pattern.special);
        special[pattern.special.len] = true;
        owned_pattern = .{ .text = text, .special = special };
        break :blk owned_pattern.?;
    };

    const raw_matches = try expand.expandPathnameExpansionPattern(allocator, io, search_pattern);
    defer {
        for (raw_matches) |match| allocator.free(match);
        allocator.free(raw_matches);
    }

    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |match| allocator.free(match);
        matches.deinit(allocator);
    }
    for (raw_matches) |match| try matches.append(allocator, try markDirectoryPathname(allocator, io, match));
    return .{ .items = try matches.toOwnedSlice(allocator) };
}

fn markDirectoryPathname(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return allocator.dupe(u8, path),
        else => return err,
    };
    if (stat.kind == .directory and !std.mem.endsWith(u8, path, "/")) {
        return std.mem.concat(allocator, u8, &.{ path, "/" });
    }
    return allocator.dupe(u8, path);
}

fn expandInteractiveAbbreviation(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, cursor: usize, append_space: bool) !?completion_model.Edit {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    return completion_context.executor.expandAbbreviationForInput(allocator, source, cursor, append_space);
}

fn lookupInteractiveViAlias(context: *anyopaque, allocator: std.mem.Allocator, letter: u21) !?[]const u8 {
    const executor: *exec.Executor = @ptrCast(@alignCast(context));
    return executor.viCommandAlias(allocator, letter);
}

fn interactiveExternalEditorCommand(executor: exec.Executor) []const u8 {
    if (executor.getEnv("VISUAL")) |visual| if (visual.len != 0) return visual;
    if (executor.getEnv("EDITOR")) |editor| if (editor.len != 0) return editor;
    return "vi";
}

fn interactiveExternalEditorTmpdir(executor: exec.Executor) []const u8 {
    if (executor.getEnv("TMPDIR")) |tmpdir| if (tmpdir.len != 0) return tmpdir;
    return "/tmp";
}

fn diagnoseInteractiveLine(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, source: []const u8) !?line_editor.DiagnosticRender {
    if (source.len == 0) return null;
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .features = completion_context.features });
    defer parsed.deinit();
    if (parsed.incomplete) return null;
    if (parsed.diagnostics.len != 0) {
        const diagnostic = parsed.diagnostics[0];
        return .{
            .line = try std.fmt.allocPrint(allocator, "\x1b[31m{s}\x1b[39m \x1b[2m{s}\x1b[22m", .{ @tagName(diagnostic.kind), diagnostic.message }),
        };
    }

    const diagnostics = try completion_context.executor.completionDiagnosticsForInputOptions(source, source.len, .{ .io = io, .features = completion_context.features });
    defer completion_context.executor.freeCompletionDiagnostics(diagnostics);
    if (diagnostics.len == 0) return null;
    const diagnostic = diagnostics[0];
    const spans = try allocator.alloc(line_editor.DiagnosticSpan, 1);
    spans[0] = .{
        .start = diagnostic.start,
        .end = diagnostic.end,
        .severity = switch (diagnostic.severity) {
            .warning => .warning,
            .err => .err,
        },
    };
    return .{
        .spans = spans,
    };
}

fn rankCompletionCandidates(allocator: std.mem.Allocator, candidates: []completion_model.Candidate, history: History, cwd: []const u8, source: []const u8, matcher_policy: completion_model.MatcherPolicy) !void {
    if (history.db) |db| {
        var snapshot = History.init(allocator);
        defer snapshot.deinit();
        try snapshot.loadRecentRows(db, 500);
        std.mem.sort(completion_model.Candidate, candidates, CompletionRankContext{ .history = snapshot, .cwd = cwd, .source = source, .matcher_policy = matcher_policy }, lessThanRankedCompletion);
        return;
    }
    std.mem.sort(completion_model.Candidate, candidates, CompletionRankContext{ .history = history, .cwd = cwd, .source = source, .matcher_policy = matcher_policy }, lessThanRankedCompletion);
}

const CompletionRankContext = struct {
    history: History,
    cwd: []const u8,
    source: []const u8,
    matcher_policy: completion_model.MatcherPolicy,
};

fn lessThanRankedCompletion(context: CompletionRankContext, a: completion_model.Candidate, b: completion_model.Candidate) bool {
    const a_provider_order = completionCandidateProviderOrder(a);
    const b_provider_order = completionCandidateProviderOrder(b);
    if (a_provider_order != b_provider_order) return a_provider_order < b_provider_order;
    const a_class = completionRankClass(a);
    const b_class = completionRankClass(b);
    if (a_class != b_class) return a_class < b_class;
    const a_match_rank = completionCandidateRankSortKey(context.source, a, context.matcher_policy);
    const b_match_rank = completionCandidateRankSortKey(context.source, b, context.matcher_policy);
    if (a_match_rank != b_match_rank) return a_match_rank < b_match_rank;
    const a_score = completionRankScore(context.history, context.cwd, a.value);
    const b_score = completionRankScore(context.history, context.cwd, b.value);
    if (a_score != b_score) return a_score > b_score;
    return lessThanCompletionLabel(a, b);
}

fn completionCandidateProviderOrder(candidate: completion_model.Candidate) usize {
    return candidate.provider_order orelse std.math.maxInt(usize);
}

fn completionCandidateRankSortKey(source: []const u8, candidate: completion_model.Candidate, matcher_policy: completion_model.MatcherPolicy) u8 {
    if (candidate.replace_start > candidate.replace_end or candidate.replace_end > source.len) return 3;
    const query = source[candidate.replace_start..candidate.replace_end];
    const rank = completion_model.candidateMatchRank(candidate, query, matcher_policy) orelse return 3;
    return @intFromEnum(rank);
}

fn completionRankClass(candidate: completion_model.Candidate) u8 {
    if (completionPathRankClass(candidate)) |class| return class;
    if (candidate.kind != .option) return 2;
    if (candidate.option) |option| {
        if (option.long == null and option.short != null) return 3;
    }
    return 4;
}

fn completionPathRankClass(candidate: completion_model.Candidate) ?u8 {
    return switch (candidate.kind) {
        .directory => 0,
        .file => 1,
        else => null,
    };
}

fn lessThanCompletionLabel(a: completion_model.Candidate, b: completion_model.Candidate) bool {
    const a_label = completionSortLabel(a);
    const b_label = completionSortLabel(b);
    if (!std.mem.eql(u8, a_label, b_label)) return std.mem.lessThan(u8, a_label, b_label);
    return std.mem.lessThan(u8, a.value, b.value);
}

fn completionSortLabel(candidate: completion_model.Candidate) []const u8 {
    if (candidate.kind == .option) {
        if (candidate.option) |option| {
            if (option.long) |long| return long;
            if (option.short) |short| return short;
            if (option.spellings.len != 0) return option.spellings[0];
        }
    }
    return candidate.display orelse candidate.value;
}

fn completionRankScore(history: History, cwd: []const u8, value: []const u8) i64 {
    var score: i64 = 0;
    var recency: i64 = @intCast(history.records.items.len);
    var index = history.records.items.len;
    while (index > 0) {
        index -= 1;
        const record = history.records.items[index];
        if (historyRecordContainsWord(record.cmd, value)) {
            score += recency;
            if (record.status == 0) score += 25;
            if (cwd.len != 0 and std.mem.eql(u8, record.cwd, cwd)) score += 50;
        }
        recency -= 1;
    }
    return score;
}

fn historyRecordContainsWord(command: []const u8, value: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, command, " \t\n");
    while (iter.next()) |word| {
        if (std.mem.eql(u8, word, value)) return true;
    }
    return false;
}

const CompletionDebugFormat = enum { text, json };

fn debugCompletion(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, source: []const u8, format: CompletionDebugFormat) !void {
    const output = switch (format) {
        .text => try completionDebugOutput(allocator, io, environ_map, source),
        .json => try completionDebugJsonOutput(allocator, io, environ_map, source),
    };
    defer allocator.free(output);
    try writeAll(io, .stdout, output);
}

fn semanticCompletionPath(allocator: std.mem.Allocator, context: completion_model.SemanticContext) ![]const u8 {
    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(allocator);
    for (context.path, 0..) |segment, index| {
        if (index != 0) try path.append(allocator, ' ');
        try path.appendSlice(allocator, segment);
    }
    return path.toOwnedSlice(allocator);
}

fn debugCompletionRuleMatches(rule: completion_model.Rule, context: completion_model.SemanticContext) bool {
    if (rule.disabled) return false;
    if (!std.mem.eql(u8, rule.root, context.root)) return false;
    if (rule.path.len > context.path.len) return false;
    for (rule.path, context.path[0..rule.path.len]) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return false;
    }
    return true;
}

fn validateCompletionScripts(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout.interface.flush() catch {};
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stderr.interface.flush() catch {};

    if (std.mem.endsWith(u8, path, ".rush")) {
        const result = try validateCompletionScriptFile(allocator, io, path, &stderr.interface);
        if (result.failures == 0) {
            try stdout.interface.print("validated {s}\n", .{path});
            return 0;
        }
        return 1;
    }

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        var buf: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buf);
        defer writer.interface.flush() catch {};
        try writer.interface.print("rush: cannot open completion path '{s}': {s}\n", .{ path, @errorName(err) });
        return 2;
    };
    defer dir.close(io);

    const result = try validateCompletionScriptsInDir(allocator, io, dir, &stderr.interface);
    if (result.failures == 0) {
        try stdout.interface.print("validated {d} completion scripts in {s}\n", .{ result.checked, path });
        return 0;
    }
    try stderr.interface.print("{d} of {d} completion scripts failed validation in {s}\n", .{ result.failures, result.checked, path });
    return 1;
}

const CompletionValidationResult = struct {
    checked: usize = 0,
    failures: usize = 0,
};

fn validateCompletionScriptFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stderr: *std.Io.Writer) !CompletionValidationResult {
    var result: CompletionValidationResult = .{ .checked = 1 };
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        result.failures += 1;
        try stderr.print("invalid {s}: read failed: {s}\n", .{ path, @errorName(err) });
        return result;
    };
    defer allocator.free(contents);

    var parsed = parser.parse(allocator, contents, .{}) catch |err| {
        result.failures += 1;
        try stderr.print("invalid {s}: {s}\n", .{ path, @errorName(err) });
        return result;
    };
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) {
        result.failures += 1;
        try stderr.print("invalid {s}: parse diagnostics\n", .{path});
    }
    return result;
}

fn validateCompletionScriptsInDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, stderr: *std.Io.Writer) !CompletionValidationResult {
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result: CompletionValidationResult = .{};

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".rush")) continue;
        result.checked += 1;
        const contents = dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024)) catch |err| {
            result.failures += 1;
            try stderr.print("invalid {s}: read failed: {s}\n", .{ entry.path, @errorName(err) });
            continue;
        };
        defer allocator.free(contents);

        var parsed = parser.parse(allocator, contents, .{}) catch |err| {
            result.failures += 1;
            try stderr.print("invalid {s}: {s}\n", .{ entry.path, @errorName(err) });
            continue;
        };
        defer parsed.deinit();
        if (parsed.diagnostics.len != 0) {
            result.failures += 1;
            try stderr.print("invalid {s}: parse diagnostics\n", .{entry.path});
            continue;
        }
    }
    return result;
}

fn completionDebugOutput(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, source: []const u8) ![]const u8 {
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    try executor.importEnvironment(environ_map);
    try executor.initializeShellVariables(io);
    executor.arg_zero = "rush";
    try loadInteractiveConfig(allocator, io, &executor, .{});

    var history = History.init(allocator);
    defer history.deinit();
    const history_path = try historyPath(allocator, environ_map);
    defer if (history_path) |path| allocator.free(path);
    if (history_path) |path| history.load(io, path) catch {};

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
    const cwd = cwd_buffer[0..cwd_len];

    const context = try exec.completionEvalContextForInput(allocator, source, source.len);
    var loader = CompletionScriptLoader.init(allocator);
    defer loader.deinit();
    if (context.command.len != 0) try loader.ensureLoaded(io, &executor, context.command, "rush");

    var semantic = try executor.analyzeCompletionsForInput(source, source.len);
    defer semantic.deinit();
    const semantic_path = try semanticCompletionPath(allocator, semantic);
    defer allocator.free(semantic_path);
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{
        .io = io,
        .allow_external = true,
        .completion_loader = loadCompletionDataForExecutor,
        .completion_loader_context = &loader,
        .arg_zero = "rush",
    });
    defer executor.freeCompletions(candidates);
    const trace_semantic = executor.lastCompletionSemantic() orelse semantic;
    var effective_context = executor.lastCompletionContext() orelse context;
    effective_context.command_path = semantic_path;
    effective_context.argument_index = semantic.argument_index;
    effective_context.argument_state = semantic.argument_state;
    effective_context.parsed_options = semantic.parsed_options;
    effective_context.operands = semantic.operands;
    effective_context.options_terminated = semantic.options_terminated;
    const matcher_policy = completion_model.MatcherPolicy.engineDefault();
    try rankCompletionCandidates(allocator, candidates, history, cwd, source, matcher_policy);
    const application = try completion_model.applyCandidatesForInputWithPolicy(allocator, source, candidates, matcher_policy);
    defer application.deinit(allocator);
    var effective_value_separator_buffer: [1]u8 = undefined;
    const effective_value_separator = completionValueSegmentSeparatorSlice(effective_context.value_segment, &effective_value_separator_buffer);
    var semantic_value_separator_buffer: [1]u8 = undefined;
    const semantic_value_separator = completionValueSegmentSeparatorSlice(semantic.value_segment, &semantic_value_separator_buffer);
    var effective_option_spelling_buffer: [2]u8 = undefined;
    const effective_option_spelling = if (effective_context.option_value) |option_value| option_value.displaySpelling(&effective_option_spelling_buffer) else "";

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        \\input: {s}
        \\context:
        \\  command: {s}
        \\  prefix: {s}
        \\  previous: {s}
        \\  argument-index: {d}
        \\  argument-state: {s}
        \\  options-terminated: {}
        \\  position: {s}
        \\  option-name: {s}
        \\  option-spelling: {s}
        \\  option-value-index: {d}
        \\  value-segment: {s}
        \\  value-separator: {s}
        \\  value-position: {s}
        \\  value-key: {s}
        \\  replace: {d}..{d}
        \\matcher-policy:
        \\  source: engine-default
        \\  case-sensitivity: {s}
        \\  mode: {s}
        \\  separators: {s}
        \\  path-segments: {s}
        \\semantic:
        \\
    , .{
        source,
        effective_context.command,
        effective_context.prefix,
        effective_context.previous,
        effective_context.argument_index,
        effective_context.argument_state orelse "",
        effective_context.options_terminated,
        if (effective_context.option_value != null) "option_value" else @tagName(effective_context.position),
        if (effective_context.option_value) |option_value| option_value.name else "",
        effective_option_spelling,
        if (effective_context.option_value) |option_value| option_value.value_index else 0,
        if (effective_context.value_segment) |segment| segment.segment else "",
        effective_value_separator,
        if (effective_context.value_segment) |segment| @tagName(segment.position) else "",
        if (effective_context.value_segment) |segment| segment.key else "",
        effective_context.replace_start,
        effective_context.replace_end,
        @tagName(matcher_policy.case_sensitivity),
        @tagName(matcher_policy.mode),
        @tagName(matcher_policy.separators),
        @tagName(matcher_policy.path_segments),
    });
    try out.writer.print("  parsed-options:\n", .{});
    try writeCompletionParsedOptionsText(&out.writer, effective_context.parsed_options, "    ");
    try out.writer.print("  operands:\n", .{});
    try writeCompletionOperandsText(&out.writer, effective_context.operands, "    ");
    try out.writer.print(
        \\  root: {s}
        \\  path: {s}
        \\  position: {s}
        \\  prefix: {s}
        \\  argument-index: {d}
        \\  argument-state: {s}
        \\  options-terminated: {}
        \\  value-segment: {s}
        \\  value-separator: {s}
        \\  value-position: {s}
        \\  value-key: {s}
        \\  replace: {d}..{d}
        \\  parser-position: {s}
        \\  parser-offset: {d}
        \\
    , .{
        semantic.root,
        semantic_path,
        @tagName(semantic.position),
        semantic.prefix,
        semantic.argument_index,
        semantic.argument_state orelse "",
        semantic.options_terminated,
        if (semantic.value_segment) |segment| segment.segment else "",
        semantic_value_separator,
        if (semantic.value_segment) |segment| @tagName(segment.position) else "",
        if (semantic.value_segment) |segment| segment.key else "",
        semantic.replace_start,
        semantic.replace_end,
        @tagName(semantic.parser_position),
        semantic.parser_source_offset,
    });
    try out.writer.print("  parsed-options:\n", .{});
    try writeCompletionParsedOptionsText(&out.writer, semantic.parsed_options, "    ");
    try out.writer.print("  operands:\n", .{});
    try writeCompletionOperandsText(&out.writer, semantic.operands, "    ");
    try writeCompletionManifestTraceText(allocator, io, &out.writer, executor, source, trace_semantic, candidates);
    try out.writer.print("rules:\n", .{});
    for (executor.completionRules()) |rule| {
        if (!debugCompletionRuleMatches(rule, semantic)) continue;
        try out.writer.print("  - kind: {s}\n    source: {s}\n    root: {s}\n    path:", .{
            @tagName(rule.kind),
            @tagName(rule.source.kind),
            rule.root,
        });
        for (rule.path) |segment| try out.writer.print(" {s}", .{segment});
        try out.writer.print("\n    value: {s}\n", .{rule.value orelse ""});
        try out.writer.print("    provider-kind: {s}\n", .{@tagName(rule.provider_kind)});
        if (rule.source.kind == .manifest) {
            try out.writer.print("    manifest-path: {s}\n    manifest-version: {d}\n", .{
                rule.source.manifest_path orelse "",
                rule.source.manifest_version orelse 0,
            });
        }
        if (rule.argument.hasSelector()) {
            var argument_index_buffer: [32]u8 = undefined;
            const argument_index_text = if (rule.argument.index) |argument_index| std.fmt.bufPrint(&argument_index_buffer, "{d}", .{argument_index}) catch "" else "";
            try out.writer.print("    argument:\n      state: {s}\n      index: {s}\n      after-state: {s}\n      after-value: {s}\n      repeatable: {}\n      rest-command-line: {}\n", .{
                rule.argument.state orelse "",
                argument_index_text,
                rule.argument.after_state orelse "",
                rule.argument.after_value orelse "",
                rule.argument.repeatable,
                rule.argument.rest_command_line,
            });
        }
        if (!rule.value_grammar.isEmpty()) {
            var list_separator_buffer: [1]u8 = undefined;
            const list_separator = completionSeparatorSlice(rule.value_grammar.list_separator, &list_separator_buffer);
            var key_prefix_buffer: [1]u8 = undefined;
            const key_prefix = completionSeparatorSlice(rule.value_grammar.key_prefix, &key_prefix_buffer);
            var key_value_separator_buffer: [1]u8 = undefined;
            const key_value_separator = completionSeparatorSlice(rule.value_grammar.key_value_separator, &key_value_separator_buffer);
            try out.writer.print("    value-grammar:\n      list-separator: {s}\n      key-prefix: {s}\n      key-value-separator: {s}\n", .{
                list_separator,
                key_prefix,
                key_value_separator,
            });
        }
    }
    try out.writer.print("suppressed-options:\n", .{});
    for (executor.completionRules()) |rule| {
        if (!debugCompletionRuleMatches(rule, semantic)) continue;
        if (rule.kind != .option) continue;
        const suppression = exec.completionOptionSuppressionForOption(semantic, rule.option) orelse continue;
        for (rule.option.spellings) |spelling| try out.writer.print("  - spelling: {s}\n    reason: {s}\n    by: {s}\n    group: {s}\n", .{ spelling, @tagName(suppression.reason), suppression.by, suppression.group orelse "" });
        if (rule.option.long) |long| try out.writer.print("  - spelling: --{s}\n    reason: {s}\n    by: {s}\n    group: {s}\n", .{ long, @tagName(suppression.reason), suppression.by, suppression.group orelse "" });
        if (rule.option.short) |short| try out.writer.print("  - spelling: -{s}\n    reason: {s}\n    by: {s}\n    group: {s}\n", .{ short, @tagName(suppression.reason), suppression.by, suppression.group orelse "" });
    }
    try out.writer.print("candidates:\n", .{});
    for (candidates) |candidate| {
        const insert = try completion_model.candidateReplacementForInput(allocator, source, candidate);
        defer allocator.free(insert);
        const match_query = try completion_model.candidateQueryForInput(allocator, source, candidate);
        defer allocator.free(match_query);
        const match_rank = completion_model.candidateMatchRank(candidate, match_query, matcher_policy);
        const suppression_reason = if (match_rank == null) completion_model.candidateSuppressionReason(candidate, match_query, matcher_policy) else null;
        try out.writer.print("  - value: {s}\n    insert: {s}\n    kind: {s}\n    description: {s}\n    tag: {s}\n    suffix: {s}\n    removable-suffix: {}\n    replace: {d}..{d}\n    match-query: {s}\n    match-rank: {s}\n    suppressed: {}\n    suppression-reason: {s}\n    rank-class: {d}\n    rank-score: {d}\n", .{
            candidate.value,
            insert,
            @tagName(candidate.kind),
            candidate.description orelse "",
            candidate.tag orelse "",
            candidate.suffix orelse "",
            candidate.removable_suffix,
            candidate.replace_start,
            candidate.replace_end,
            match_query,
            matchRankName(match_rank),
            suppression_reason != null,
            matchSuppressionReasonName(suppression_reason),
            completionRankClass(candidate),
            completionRankScore(history, cwd, candidate.value),
        });
        if (candidate.option) |option| {
            try out.writer.print("    option:\n      long: {s}\n      short: {s}\n      argument: {s}\n      value-count: {d}\n      exclusive-group: {s}\n      repeatable: {}\n      terminates-options: {}\n", .{
                option.long orelse "",
                option.short orelse "",
                option.argument orelse "",
                option.value_count,
                option.exclusive_group orelse "",
                option.repeatable,
                option.terminates_options,
            });
            try out.writer.print("      spellings:", .{});
            for (option.spellings) |spelling| try out.writer.print(" {s}", .{spelling});
            try out.writer.print("\n", .{});
        }
    }
    try out.writer.print("provider-diagnostics:\n", .{});
    for (executor.completionProviderDiagnostics()) |diagnostic| {
        try out.writer.print("  - function: {s}\n    command: {s}\n", .{ diagnostic.function, diagnostic.command });
        if (diagnostic.status) |status| try out.writer.print("    status: {d}\n", .{status});
        if (diagnostic.err) |err| try out.writer.print("    error: {s}\n", .{err});
        if (diagnostic.stderr.len != 0) try out.writer.print("    stderr: {s}\n", .{diagnostic.stderr});
    }
    try out.writer.print("application:\n", .{});
    switch (application) {
        .none => try out.writer.print("  none\n", .{}),
        .ambiguous => try out.writer.print("  ambiguous\n", .{}),
        .edit => |edit| try out.writer.print("  edit:\n    replace: {d}..{d}\n    replacement: {s}\n    suffix: {s}\n    removable-suffix: {}\n    append-space: {}\n", .{ edit.replace_start, edit.replace_end, edit.replacement, edit.suffix orelse "", edit.removable_suffix, edit.append_space }),
    }
    return out.toOwnedSlice();
}

fn writeCompletionParsedOptionsText(writer: *std.Io.Writer, options: []const completion_model.ParsedOption, indent: []const u8) !void {
    for (options) |option| {
        var spelling_buffer: [2]u8 = undefined;
        const spelling = option.displaySpelling(&spelling_buffer);
        try writer.print("{s}- spelling: {s}\n{s}  from: {s}\n{s}  name: {s}\n{s}  key: {s}\n{s}  value: {s}\n{s}  repeatable: {}\n{s}  terminates-options: {}\n{s}  exclusive-group: {s}\n", .{
            indent,
            spelling,
            indent,
            option.from orelse "",
            indent,
            option.name,
            indent,
            option.key,
            indent,
            option.value orelse "",
            indent,
            option.repeatable,
            indent,
            option.terminates_options,
            indent,
            option.exclusive_group orelse "",
        });
    }
}

fn writeCompletionOperandsText(writer: *std.Io.Writer, operands: []const completion_model.ParsedOperand, indent: []const u8) !void {
    for (operands) |operand| {
        try writer.print("{s}- value: {s}\n{s}  index: {d}\n{s}  state: {s}\n{s}  after-terminator: {}\n{s}  rest-command-line: {}\n", .{
            indent,
            operand.value,
            indent,
            operand.index,
            indent,
            operand.state orelse "",
            indent,
            operand.after_terminator,
            indent,
            operand.rest_command_line,
        });
    }
}

fn completionDebugJsonOutput(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, source: []const u8) ![]const u8 {
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    try executor.importEnvironment(environ_map);
    try executor.initializeShellVariables(io);
    executor.arg_zero = "rush";
    try loadInteractiveConfig(allocator, io, &executor, .{});

    var history = History.init(allocator);
    defer history.deinit();
    const history_path = try historyPath(allocator, environ_map);
    defer if (history_path) |path| allocator.free(path);
    if (history_path) |path| history.load(io, path) catch {};

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
    const cwd = cwd_buffer[0..cwd_len];

    const context = try exec.completionEvalContextForInput(allocator, source, source.len);
    var loader = CompletionScriptLoader.init(allocator);
    defer loader.deinit();
    if (context.command.len != 0) try loader.ensureLoaded(io, &executor, context.command, "rush");

    var semantic = try executor.analyzeCompletionsForInput(source, source.len);
    defer semantic.deinit();
    const semantic_path = try semanticCompletionPath(allocator, semantic);
    defer allocator.free(semantic_path);
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{
        .io = io,
        .allow_external = true,
        .completion_loader = loadCompletionDataForExecutor,
        .completion_loader_context = &loader,
        .arg_zero = "rush",
    });
    defer executor.freeCompletions(candidates);
    const trace_semantic = executor.lastCompletionSemantic() orelse semantic;
    const trace_path = executor.lastCompletionTracePath();
    var effective_context = executor.lastCompletionContext() orelse context;
    effective_context.command_path = semantic_path;
    effective_context.argument_index = semantic.argument_index;
    effective_context.argument_state = semantic.argument_state;
    effective_context.parsed_options = semantic.parsed_options;
    effective_context.operands = semantic.operands;
    effective_context.options_terminated = semantic.options_terminated;
    const matcher_policy = completion_model.MatcherPolicy.engineDefault();
    try rankCompletionCandidates(allocator, candidates, history, cwd, source, matcher_policy);
    const application = try completion_model.applyCandidatesForInputWithPolicy(allocator, source, candidates, matcher_policy);
    defer application.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try json.beginObject();
    try json.objectField("input");
    try json.write(source);
    try json.objectField("context");
    try writeCompletionEvalContextJson(&json, effective_context);
    try json.objectField("matcherPolicy");
    try writeCompletionMatcherPolicyJson(&json, matcher_policy);
    try json.objectField("semantic");
    try writeCompletionSemanticContextJson(&json, semantic, semantic_path);
    try json.objectField("manifest");
    try writeCompletionManifestTraceJson(allocator, io, &json, executor, source, trace_semantic, trace_path, executor.lastCompletionPrecommandDepthLimited(), candidates);
    try json.objectField("matchedRules");
    try json.beginArray();
    for (executor.completionRules()) |rule| {
        if (!debugCompletionRuleMatches(rule, semantic)) continue;
        try writeCompletionRuleJson(&json, rule);
    }
    try json.endArray();
    try json.objectField("suppressedOptions");
    try writeCompletionSuppressedOptionsJson(&json, executor.completionRules(), semantic);
    try json.objectField("candidates");
    try json.beginArray();
    for (candidates) |candidate| try writeCompletionCandidateJson(allocator, &json, history, cwd, source, candidate, matcher_policy);
    try json.endArray();
    try json.objectField("providerDiagnostics");
    try writeCompletionProviderDiagnosticsJson(&json, executor.completionProviderDiagnostics());
    try json.objectField("application");
    try writeCompletionApplicationJson(&json, application);
    try json.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn writeCompletionProviderDiagnosticsJson(json: *std.json.Stringify, diagnostics: []const completion_model.ProviderDiagnostic) !void {
    try json.beginArray();
    for (diagnostics) |diagnostic| {
        try json.beginObject();
        try json.objectField("function");
        try json.write(diagnostic.function);
        try json.objectField("command");
        try json.write(diagnostic.command);
        try json.objectField("status");
        try json.write(diagnostic.status);
        try json.objectField("error");
        try json.write(diagnostic.err);
        try json.objectField("stderr");
        try json.write(diagnostic.stderr);
        try json.endObject();
    }
    try json.endArray();
}

fn writeCompletionEvalContextJson(json: *std.json.Stringify, context: completion_model.EvalContext) !void {
    try json.beginObject();
    try json.objectField("command");
    try json.write(context.command);
    try json.objectField("commandPath");
    try json.write(if (context.command_path.len != 0) context.command_path else context.command);
    try json.objectField("prefix");
    try json.write(context.prefix);
    try json.objectField("previous");
    try json.write(context.previous);
    try json.objectField("argumentIndex");
    try json.write(context.argument_index);
    try json.objectField("argumentState");
    try json.write(context.argument_state);
    try json.objectField("optionsTerminated");
    try json.write(context.options_terminated);
    try json.objectField("parsedOptions");
    try writeCompletionParsedOptionsJson(json, context.parsed_options);
    try json.objectField("operands");
    try writeCompletionOperandsJson(json, context.operands);
    try json.objectField("position");
    try json.write(if (context.option_value != null) "option_value" else @tagName(context.position));
    try json.objectField("optionName");
    try json.write(if (context.option_value) |option_value| option_value.name else @as(?[]const u8, null));
    try json.objectField("optionSpelling");
    if (context.option_value) |option_value| {
        var spelling_buffer: [2]u8 = undefined;
        try json.write(option_value.displaySpelling(&spelling_buffer));
    } else {
        try json.write(@as(?[]const u8, null));
    }
    try json.objectField("optionValueIndex");
    try json.write(if (context.option_value) |option_value| option_value.value_index else @as(?usize, null));
    try json.objectField("valueSegment");
    try json.write(if (context.value_segment) |segment| segment.segment else @as(?[]const u8, null));
    try json.objectField("valueSeparator");
    try writeCompletionSeparatorJson(json, if (context.value_segment) |segment| segment.activeSeparator() else null);
    try json.objectField("valuePosition");
    try json.write(if (context.value_segment) |segment| @tagName(segment.position) else @as(?[]const u8, null));
    try json.objectField("valueKey");
    try json.write(if (context.value_segment) |segment| segment.key else @as(?[]const u8, null));
    try json.objectField("replaceStart");
    try json.write(context.replace_start);
    try json.objectField("replaceEnd");
    try json.write(context.replace_end);
    try json.endObject();
}

fn writeCompletionMatcherPolicyJson(json: *std.json.Stringify, policy: completion_model.MatcherPolicy) !void {
    try json.beginObject();
    try json.objectField("source");
    try json.write("engine-default");
    try json.objectField("caseSensitivity");
    try json.write(@tagName(policy.case_sensitivity));
    try json.objectField("mode");
    try json.write(@tagName(policy.mode));
    try json.objectField("separators");
    try json.write(@tagName(policy.separators));
    try json.objectField("pathSegments");
    try json.write(@tagName(policy.path_segments));
    try json.endObject();
}

fn writeCompletionSemanticContextJson(json: *std.json.Stringify, context: completion_model.SemanticContext, command_path: []const u8) !void {
    try json.beginObject();
    try json.objectField("root");
    try json.write(context.root);
    try json.objectField("path");
    try json.beginArray();
    for (context.path) |segment| try json.write(segment);
    try json.endArray();
    try json.objectField("commandPath");
    try json.write(command_path);
    try json.objectField("position");
    try json.write(@tagName(context.position));
    try json.objectField("prefix");
    try json.write(context.prefix);
    try json.objectField("previous");
    try json.write(context.previous);
    try json.objectField("argumentIndex");
    try json.write(context.argument_index);
    try json.objectField("argumentState");
    try json.write(context.argument_state);
    try json.objectField("optionsTerminated");
    try json.write(context.options_terminated);
    try json.objectField("parsedOptions");
    try writeCompletionParsedOptionsJson(json, context.parsed_options);
    try json.objectField("operands");
    try writeCompletionOperandsJson(json, context.operands);
    try json.objectField("optionName");
    try json.write(if (context.option_value) |option_value| option_value.name else @as(?[]const u8, null));
    try json.objectField("optionSpelling");
    if (context.option_value) |option_value| {
        var spelling_buffer: [2]u8 = undefined;
        try json.write(option_value.displaySpelling(&spelling_buffer));
    } else {
        try json.write(@as(?[]const u8, null));
    }
    try json.objectField("optionValueIndex");
    try json.write(if (context.option_value) |option_value| option_value.value_index else @as(?usize, null));
    try json.objectField("valueSegment");
    try json.write(if (context.value_segment) |segment| segment.segment else @as(?[]const u8, null));
    try json.objectField("valueSeparator");
    try writeCompletionSeparatorJson(json, if (context.value_segment) |segment| segment.activeSeparator() else null);
    try json.objectField("valuePosition");
    try json.write(if (context.value_segment) |segment| @tagName(segment.position) else @as(?[]const u8, null));
    try json.objectField("valueKey");
    try json.write(if (context.value_segment) |segment| segment.key else @as(?[]const u8, null));
    try json.objectField("replaceStart");
    try json.write(context.replace_start);
    try json.objectField("replaceEnd");
    try json.write(context.replace_end);
    try json.objectField("suspiciousStart");
    try json.write(context.suspicious_start);
    try json.objectField("suspiciousEnd");
    try json.write(context.suspicious_end);
    try json.objectField("parserPosition");
    try json.write(@tagName(context.parser_position));
    try json.objectField("parserSourceOffset");
    try json.write(context.parser_source_offset);
    try json.endObject();
}

fn writeCompletionParsedOptionsJson(json: *std.json.Stringify, options: []const completion_model.ParsedOption) !void {
    try json.beginArray();
    for (options) |option| {
        var spelling_buffer: [2]u8 = undefined;
        try json.beginObject();
        try json.objectField("spelling");
        try json.write(option.displaySpelling(&spelling_buffer));
        try json.objectField("from");
        try json.write(option.from);
        try json.objectField("name");
        try json.write(option.name);
        try json.objectField("key");
        try json.write(option.key);
        try json.objectField("value");
        try json.write(option.value);
        try json.objectField("exclusiveGroup");
        try json.write(option.exclusive_group);
        try json.objectField("repeatable");
        try json.write(option.repeatable);
        try json.objectField("terminatesOptions");
        try json.write(option.terminates_options);
        try json.endObject();
    }
    try json.endArray();
}

fn writeCompletionOperandsJson(json: *std.json.Stringify, operands: []const completion_model.ParsedOperand) !void {
    try json.beginArray();
    for (operands) |operand| {
        try json.beginObject();
        try json.objectField("value");
        try json.write(operand.value);
        try json.objectField("index");
        try json.write(operand.index);
        try json.objectField("state");
        try json.write(operand.state);
        try json.objectField("afterTerminator");
        try json.write(operand.after_terminator);
        try json.objectField("restCommandLine");
        try json.write(operand.rest_command_line);
        try json.endObject();
    }
    try json.endArray();
}

fn writeCompletionRuleJson(json: *std.json.Stringify, rule: completion_model.Rule) !void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write(@tagName(rule.kind));
    try json.objectField("source");
    try json.write(@tagName(rule.source.kind));
    try json.objectField("manifestPath");
    try json.write(rule.source.manifest_path);
    try json.objectField("manifestVersion");
    try json.write(rule.source.manifest_version);
    try json.objectField("root");
    try json.write(rule.root);
    try json.objectField("path");
    try json.beginArray();
    for (rule.path) |segment| try json.write(segment);
    try json.endArray();
    try json.objectField("value");
    try json.write(rule.value);
    try json.objectField("providerKind");
    try json.write(@tagName(rule.provider_kind));
    try json.objectField("description");
    try json.write(rule.description);
    try json.objectField("option");
    try json.beginObject();
    try json.objectField("long");
    try json.write(rule.option.long);
    try json.objectField("short");
    try json.write(rule.option.short);
    try json.objectField("argument");
    try json.write(rule.option.argument);
    try json.objectField("valueCount");
    try json.write(rule.option.value_count);
    try json.objectField("exclusiveGroup");
    try json.write(rule.option.exclusive_group);
    try json.objectField("repeatable");
    try json.write(rule.option.repeatable);
    try json.objectField("terminatesOptions");
    try json.write(rule.option.terminates_options);
    try json.objectField("noSpace");
    try json.write(rule.option.no_space);
    try json.objectField("inherit");
    try json.write(rule.option.inherit);
    try json.endObject();
    try json.objectField("argument");
    try json.beginObject();
    try json.objectField("state");
    try json.write(rule.argument.state);
    try json.objectField("index");
    try json.write(rule.argument.index);
    try json.objectField("afterState");
    try json.write(rule.argument.after_state);
    try json.objectField("afterValue");
    try json.write(rule.argument.after_value);
    try json.objectField("repeatable");
    try json.write(rule.argument.repeatable);
    try json.objectField("restCommandLine");
    try json.write(rule.argument.rest_command_line);
    try json.endObject();
    try json.objectField("valueIndex");
    try json.write(rule.value_index);
    try json.objectField("valueGrammar");
    try json.beginObject();
    try json.objectField("listSeparator");
    try writeCompletionSeparatorJson(json, rule.value_grammar.list_separator);
    try json.objectField("keyPrefix");
    try writeCompletionSeparatorJson(json, rule.value_grammar.key_prefix);
    try json.objectField("keyValueSeparator");
    try writeCompletionSeparatorJson(json, rule.value_grammar.key_value_separator);
    try json.endObject();
    try json.endObject();
}

fn writeCompletionSuppressedOptionsJson(json: *std.json.Stringify, rules: []const completion_model.Rule, semantic: completion_model.SemanticContext) !void {
    try json.beginArray();
    for (rules) |rule| {
        if (rule.kind != .option or !debugCompletionRuleMatches(rule, semantic)) continue;
        const suppression = exec.completionOptionSuppressionForOption(semantic, rule.option) orelse continue;
        if (rule.option.long) |long| try writeCompletionSuppressedOptionJson(json, "--", long, suppression);
        if (rule.option.short) |short| try writeCompletionSuppressedOptionJson(json, "-", short, suppression);
    }
    try json.endArray();
}

fn writeCompletionSuppressedOptionJson(json: *std.json.Stringify, prefix: []const u8, name: []const u8, suppression: completion_model.OptionSuppression) !void {
    try json.beginObject();
    try json.objectField("spelling");
    var buffer: [256]u8 = undefined;
    try json.write(std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, name }) catch name);
    try json.objectField("reason");
    try json.write(@tagName(suppression.reason));
    try json.objectField("by");
    try json.write(suppression.by);
    try json.objectField("group");
    try json.write(suppression.group);
    try json.objectField("exclusion");
    try json.write(suppression.exclusion);
    try json.endObject();
}

fn writeCompletionCandidateJson(allocator: std.mem.Allocator, json: *std.json.Stringify, history: History, cwd: []const u8, source: []const u8, candidate: completion_model.Candidate, matcher_policy: completion_model.MatcherPolicy) !void {
    const insert = try completion_model.candidateReplacementForInput(allocator, source, candidate);
    defer allocator.free(insert);
    const match_query = try completion_model.candidateQueryForInput(allocator, source, candidate);
    defer allocator.free(match_query);
    const match_rank = completion_model.candidateMatchRank(candidate, match_query, matcher_policy);
    const suppression_reason = if (match_rank == null) completion_model.candidateSuppressionReason(candidate, match_query, matcher_policy) else null;
    try json.beginObject();
    try json.objectField("value");
    try json.write(candidate.value);
    try json.objectField("display");
    try json.write(candidate.display);
    try json.objectField("insert");
    try json.write(insert);
    try json.objectField("description");
    try json.write(candidate.description);
    try json.objectField("tag");
    try json.write(candidate.tag);
    try json.objectField("suffix");
    try json.write(candidate.suffix);
    try json.objectField("removableSuffix");
    try json.write(candidate.removable_suffix);
    try json.objectField("kind");
    try json.write(@tagName(candidate.kind));
    try json.objectField("replaceStart");
    try json.write(candidate.replace_start);
    try json.objectField("replaceEnd");
    try json.write(candidate.replace_end);
    try json.objectField("appendSpace");
    try json.write(candidate.append_space);
    try json.objectField("matchesPrefix");
    try json.write(match_rank != null);
    try json.objectField("matchQuery");
    try json.write(match_query);
    try json.objectField("matchRank");
    try json.write(matchRankName(match_rank));
    try json.objectField("suppressed");
    try json.write(suppression_reason != null);
    try json.objectField("suppressionReason");
    try json.write(matchSuppressionReasonName(suppression_reason));
    try json.objectField("rankClass");
    try json.write(completionRankClass(candidate));
    try json.objectField("rankScore");
    try json.write(completionRankScore(history, cwd, candidate.value));
    try json.objectField("option");
    if (candidate.option) |option| {
        try json.beginObject();
        try json.objectField("long");
        try json.write(option.long);
        try json.objectField("short");
        try json.write(option.short);
        try json.objectField("argument");
        try json.write(option.argument);
        try json.objectField("exclusiveGroup");
        try json.write(option.exclusive_group);
        try json.objectField("repeatable");
        try json.write(option.repeatable);
        try json.objectField("terminatesOptions");
        try json.write(option.terminates_options);
        try json.objectField("noSpace");
        try json.write(option.no_space);
        try json.objectField("inherit");
        try json.write(option.inherit);
        try json.endObject();
    } else {
        try json.write(@as(?[]const u8, null));
    }
    try json.endObject();
}

fn matchRankName(rank: ?completion_model.MatchRank) []const u8 {
    return if (rank) |value| @tagName(value) else "";
}

fn completionValueSegmentSeparatorText(segment: ?completion_model.ValueSegment) []const u8 {
    return completionSeparatorText(if (segment) |value| value.activeSeparator() else null);
}

fn completionValueSegmentSeparatorSlice(segment: ?completion_model.ValueSegment, buffer: *[1]u8) []const u8 {
    return completionSeparatorSlice(if (segment) |value| value.activeSeparator() else null, buffer);
}

fn completionSeparatorSlice(separator: ?u8, buffer: *[1]u8) []const u8 {
    const value = separator orelse return "";
    buffer[0] = value;
    return buffer[0..1];
}

fn completionSeparatorText(separator: ?u8) []const u8 {
    const value = separator orelse return "";
    return switch (value) {
        ',' => ",",
        '=' => "=",
        ':' => ":",
        ';' => ";",
        '|' => "|",
        '/' => "/",
        else => "",
    };
}

fn writeCompletionSeparatorJson(json: *std.json.Stringify, separator: ?u8) !void {
    const value = separator orelse {
        try json.write(@as(?[]const u8, null));
        return;
    };
    const text: [1]u8 = .{value};
    try json.write(text[0..]);
}

fn matchSuppressionReasonName(reason: ?completion_model.MatchSuppressionReason) []const u8 {
    return if (reason) |value| @tagName(value) else "";
}

fn writeCompletionApplicationJson(json: *std.json.Stringify, application: completion_model.Application) !void {
    try json.beginObject();
    switch (application) {
        .none => {
            try json.objectField("kind");
            try json.write("none");
        },
        .ambiguous => |candidates| {
            try json.objectField("kind");
            try json.write("ambiguous");
            try json.objectField("candidateCount");
            try json.write(candidates.len);
        },
        .edit => |edit| {
            try json.objectField("kind");
            try json.write("edit");
            try json.objectField("replaceStart");
            try json.write(edit.replace_start);
            try json.objectField("replaceEnd");
            try json.write(edit.replace_end);
            try json.objectField("replacement");
            try json.write(edit.replacement);
            try json.objectField("suffix");
            try json.write(edit.suffix);
            try json.objectField("removableSuffix");
            try json.write(edit.removable_suffix);
            try json.objectField("appendSpace");
            try json.write(edit.append_space);
        },
    }
    try json.endObject();
}

const ManifestParsedOption = struct {
    spelling: []const u8,
    name: []const u8,
    key: []const u8,
    short: ?[]const u8 = null,
    value: ?[]const u8 = null,
    from: ?[]const u8 = null,
    from_offset: ?usize = null,
    exclusive_group: ?[]const u8 = null,
    excludes: ?std.json.Value = null,
    repeatable: bool = false,

    fn displaySpelling(self: ManifestParsedOption, buffer: *[2]u8) []const u8 {
        if (self.from_offset) |offset| {
            if (self.from) |from| {
                if (offset < from.len) {
                    buffer[0] = '-';
                    buffer[1] = from[offset];
                    return buffer[0..2];
                }
            }
        }
        return self.spelling;
    }
};

const ManifestOptionMatch = struct {
    option: std.json.ObjectMap,
    spelling: []const u8,
    name: []const u8,
    value: ?[]const u8 = null,
    attached_value: bool = false,
};

fn manifestOptionMatchKey(matched: ManifestOptionMatch) []const u8 {
    if (std.mem.startsWith(u8, matched.spelling, "--")) return matched.name;
    return manifestString(matched.option.get("long")) orelse matched.name;
}

fn manifestOptionMatchShort(matched: ManifestOptionMatch) ?[]const u8 {
    if (std.mem.startsWith(u8, matched.spelling, "--")) {
        const long = manifestString(matched.option.get("long")) orelse return null;
        if (!std.mem.eql(u8, matched.name, long)) return null;
    }
    return manifestString(matched.option.get("short"));
}

const ManifestCompletionTrace = struct {
    parsed_options: std.ArrayList(ManifestParsedOption) = .empty,
    terminator_value: ?[]const u8 = null,
    terminator_seen: bool = false,
    active_argument_index: usize = 0,
    previous_argument_state: ?[]const u8 = null,
    active_argument_state: ?std.json.ObjectMap = null,

    fn deinit(self: *ManifestCompletionTrace, allocator: std.mem.Allocator) void {
        self.parsed_options.deinit(allocator);
    }
};

fn writeCompletionManifestTraceText(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, executor: exec.Executor, source: []const u8, semantic: completion_model.SemanticContext, candidates: []const completion_model.Candidate) !void {
    const manifest_source = primaryManifestRuleSource(executor.completionRules(), semantic);
    const manifest_state = executor.completionManifestCommandState(semantic.root);
    const variant_state = executor.completionVariantProbeState(semantic.root);
    const loaded = manifest_source != null or manifest_state != null;

    try writer.print("manifest:\n  loaded: {}\n", .{loaded});
    try writer.print("  path: {s}\n", .{if (manifest_source) |rule_source| rule_source.manifest_path orelse "" else if (manifest_state) |state| state.manifest_path orelse "" else ""});
    if (manifest_source) |rule_source| {
        try writer.print("  manifest-version: {d}\n", .{rule_source.manifest_version orelse 0});
    } else if (manifest_state) |state| {
        try writer.print("  manifest-version: {d}\n", .{state.manifest_version orelse 0});
    } else {
        try writer.print("  manifest-version: \n", .{});
    }
    try writer.print("  command-path:", .{});
    if (semantic.root.len != 0) try writer.print(" {s}", .{semantic.root});
    for (semantic.path) |segment| try writer.print(" {s}", .{segment});
    try writer.print("\n  option-name: {s}\n  option-value-index: ", .{if (semantic.option_value) |option_value| option_value.name else ""});
    if (semantic.option_value) |option_value| try writer.print("{d}", .{option_value.value_index});
    try writer.print("\n  platform-gate:\n    platform: {s}\n    allowed: {}\n", .{
        if (manifest_state) |state| state.platform else completionManifestCurrentPlatform(),
        if (manifest_state) |state| state.platform_allowed else true,
    });
    try writer.print("  variant:\n    selected: {s}\n    probed: {}\n    cached: {}\n    skipped-shadow: {}\n", .{
        if (variant_state) |state| state.selected orelse "" else "",
        if (variant_state) |state| state.last_probed else false,
        if (variant_state) |state| state.last_cached else false,
        if (variant_state) |state| state.skipped_shadow else false,
    });

    const source_info = manifest_source orelse {
        try writeEmptyManifestTraceText(writer, "noManifest", "no manifest-backed rule matched; using Rush/default completion fallback");
        return;
    };
    const path = source_info.manifest_path orelse {
        try writeEmptyManifestTraceText(writer, "noManifestPath", "manifest rule did not retain a source path; structured manifest trace unavailable");
        return;
    };

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch {
        try writeEmptyManifestTraceText(writer, "manifestUnavailable", "manifest file could not be read for trace rendering");
        return;
    };
    defer allocator.free(contents);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
        try writeEmptyManifestTraceText(writer, "manifestParseFailed", "manifest file could not be parsed for trace rendering");
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try writeEmptyManifestTraceText(writer, "manifestInvalid", "manifest root was not an object during trace rendering");
            return;
        },
    };
    const command_value = root.get("command") orelse {
        try writeEmptyManifestTraceText(writer, "manifestInvalid", "manifest command object was missing during trace rendering");
        return;
    };
    const root_command = switch (command_value) {
        .object => |object| object,
        else => {
            try writeEmptyManifestTraceText(writer, "manifestInvalid", "manifest command was not an object during trace rendering");
            return;
        },
    };
    const active_command = manifestCommandForPath(root_command, semantic.path) orelse root_command;
    var trace = try analyzeManifestCompletionTrace(allocator, source, semantic, root_command, active_command);
    defer trace.deinit(allocator);
    var active_options: std.ArrayList(std.json.ObjectMap) = .empty;
    defer active_options.deinit(allocator);
    try appendManifestOptionsForPath(allocator, &active_options, root_command, semantic.path);

    try writer.print("  parsed-options:\n", .{});
    try writeManifestParsedOptionsText(writer, trace.parsed_options.items, "    ");
    try writer.print("  terminator:\n    defined: {}\n    value: {s}\n    seen: {}\n", .{ trace.terminator_value != null, trace.terminator_value orelse "", trace.terminator_seen });
    try writer.print("  active-argument-state:\n", .{});
    if (trace.active_argument_state) |state| {
        try writeManifestArgumentStateText(writer, state, trace.active_argument_index, "    ");
    } else {
        try writer.print("    none\n", .{});
    }
    try writer.print("  matched-providers:\n", .{});
    const provider_count = try writeManifestProvidersText(writer, semantic, active_command, active_options.items, trace, candidates, "    ");
    try writer.print("  suppressed-options:\n", .{});
    try writeManifestSuppressedOptionsText(writer, active_options.items, trace.parsed_options.items, "    ");
    try writer.print("  suppressed-operands:\n", .{});
    try writeManifestSuppressedOperandsText(writer, trace.parsed_options.items, "    ");
    try writeManifestFallbackText(writer, manifestFallbackKind(loaded, provider_count, candidates), manifestFallbackReason(loaded, provider_count, candidates));
}

fn writeEmptyManifestTraceText(writer: *std.Io.Writer, fallback_kind: []const u8, fallback_reason: []const u8) !void {
    try writer.print(
        \\  parsed-options:
        \\  terminator:
        \\    defined: false
        \\    value:
        \\    seen: false
        \\  active-argument-state:
        \\    none
        \\  matched-providers:
        \\  suppressed-options:
        \\  suppressed-operands:
        \\
    , .{});
    try writeManifestFallbackText(writer, fallback_kind, fallback_reason);
}

fn writeManifestFallbackText(writer: *std.Io.Writer, kind: []const u8, reason: []const u8) !void {
    try writer.print("  fallback:\n    kind: {s}\n    reason: {s}\n", .{ kind, reason });
}

fn writeManifestParsedOptionsText(writer: *std.Io.Writer, options: []const ManifestParsedOption, indent: []const u8) !void {
    for (options) |option| {
        var spelling_buffer: [2]u8 = undefined;
        try writer.print("{s}- spelling: {s}\n{s}  from: {s}\n{s}  name: {s}\n{s}  value: {s}\n{s}  exclusive-group: {s}\n{s}  repeatable: {}\n", .{
            indent,
            option.displaySpelling(&spelling_buffer),
            indent,
            option.from orelse "",
            indent,
            option.name,
            indent,
            option.value orelse "",
            indent,
            option.exclusive_group orelse "",
            indent,
            option.repeatable,
        });
    }
}

fn writeManifestArgumentStateText(writer: *std.Io.Writer, state: std.json.ObjectMap, active_index: usize, indent: []const u8) !void {
    var provider_buffer: [128]u8 = undefined;
    try writer.print("{s}name: {s}\n{s}index: {d}\n{s}repeatable: {}\n{s}provider: {s}\n", .{
        indent,
        manifestString(state.get("name")) orelse "",
        indent,
        if (manifestInteger(state.get("index"))) |index| if (index >= 0) @as(usize, @intCast(index)) else active_index else active_index,
        indent,
        manifestBool(state.get("repeatable")),
        indent,
        if (state.get("provider")) |provider| manifestProviderRefLabel(provider, &provider_buffer) orelse "" else "",
    });
}

fn writeManifestProvidersText(writer: *std.Io.Writer, semantic: completion_model.SemanticContext, active_command: std.json.ObjectMap, active_options: []const std.json.ObjectMap, trace: ManifestCompletionTrace, candidates: []const completion_model.Candidate, indent: []const u8) !usize {
    var count: usize = 0;
    if (trace.active_argument_state) |state| {
        if (state.get("provider")) |provider| {
            count += try writeManifestProviderEntriesText(writer, provider, "argumentState", candidates, indent);
        }
    }
    if (semantic.option_value) |option_value| {
        if (findManifestOptionByName(active_options, option_value.name)) |option| {
            if (manifestOptionValueObjectAt(option, option_value.value_index)) |value| {
                if (value.get("provider")) |provider| {
                    count += try writeManifestProviderEntriesText(writer, provider, "optionValue", candidates, indent);
                }
            }
        }
    }
    if (semantic.position == .subcommand) {
        if (active_command.get("dynamicSubcommands")) |providers| count += try writeManifestProviderArrayEntriesText(writer, providers, "dynamicSubcommands", candidates, indent);
    }
    if (semantic.position == .option) {
        if (active_command.get("dynamicOptions")) |providers| count += try writeManifestProviderArrayEntriesText(writer, providers, "dynamicOptions", candidates, indent);
    }
    return count;
}

fn writeManifestProviderEntriesText(writer: *std.Io.Writer, provider_value: std.json.Value, reason: []const u8, candidates: []const completion_model.Candidate, indent: []const u8) !usize {
    switch (provider_value) {
        .array => return writeManifestProviderArrayEntriesText(writer, provider_value, reason, candidates, indent),
        else => {
            try writeManifestProviderEntryText(writer, provider_value, reason, candidates, indent);
            return 1;
        },
    }
}

fn manifestOptionValueObjectAt(option: std.json.ObjectMap, value_index: usize) ?std.json.ObjectMap {
    const value = option.get("value") orelse return null;
    const item = manifestOptionValueAt(value, value_index) orelse return null;
    return switch (item) {
        .object => |object| object,
        else => null,
    };
}

fn writeManifestProviderArrayEntriesText(writer: *std.Io.Writer, providers_value: std.json.Value, reason: []const u8, candidates: []const completion_model.Candidate, indent: []const u8) !usize {
    const providers = switch (providers_value) {
        .array => |array| array,
        else => return 0,
    };
    for (providers.items) |provider| try writeManifestProviderEntryText(writer, provider, reason, candidates, indent);
    return providers.items.len;
}

fn writeManifestProviderEntryText(writer: *std.Io.Writer, provider: std.json.Value, reason: []const u8, candidates: []const completion_model.Candidate, indent: []const u8) !void {
    var provider_buffer: [128]u8 = undefined;
    try writer.print("{s}- id: {s}\n{s}  reason: {s}\n{s}  candidate-count: {d}\n", .{
        indent,
        manifestProviderRefLabel(provider, &provider_buffer) orelse "",
        indent,
        reason,
        indent,
        manifestProviderCandidateCount(candidates, reason),
    });
}

fn writeManifestSuppressedOptionsText(writer: *std.Io.Writer, options: []const std.json.ObjectMap, parsed_options: []const ManifestParsedOption, indent: []const u8) !void {
    for (options) |option| {
        var spelling_buffer: [256]u8 = undefined;
        const spelling = manifestOptionPrimarySpelling(option, &spelling_buffer) orelse continue;
        if (manifestParsedOptionForOption(parsed_options, option)) |parsed| {
            var parsed_spelling_buffer: [2]u8 = undefined;
            if (!manifestBool(option.get("repeatable"))) try writeManifestSuppressedOptionText(writer, spelling, "alreadyPresent", parsed.displaySpelling(&parsed_spelling_buffer), null, null, indent);
            continue;
        }
        var suppressed = false;
        if (manifestString(option.get("exclusiveGroup"))) |group| {
            for (parsed_options) |parsed| {
                if (parsed.exclusive_group) |parsed_group| {
                    if (std.mem.eql(u8, group, parsed_group)) {
                        var parsed_spelling_buffer: [2]u8 = undefined;
                        try writeManifestSuppressedOptionText(writer, spelling, "exclusiveGroup", parsed.displaySpelling(&parsed_spelling_buffer), group, null, indent);
                        suppressed = true;
                        break;
                    }
                }
            }
        }
        if (suppressed) continue;
        for (parsed_options) |parsed| {
            const exclusion = manifestParsedOptionExcludesOption(parsed, option) orelse continue;
            var parsed_spelling_buffer: [2]u8 = undefined;
            try writeManifestSuppressedOptionText(writer, spelling, "excluded", parsed.displaySpelling(&parsed_spelling_buffer), null, exclusion, indent);
            break;
        }
    }
}

fn writeManifestSuppressedOperandsText(writer: *std.Io.Writer, parsed_options: []const ManifestParsedOption, indent: []const u8) !void {
    for (parsed_options) |parsed| {
        const exclusion = manifestParsedOptionExcludesOperands(parsed) orelse continue;
        var parsed_spelling_buffer: [2]u8 = undefined;
        try writer.print("{s}- reason: excluded\n{s}  by: {s}\n{s}  exclusion: {s}\n", .{
            indent,
            indent,
            parsed.displaySpelling(&parsed_spelling_buffer),
            indent,
            exclusion,
        });
        break;
    }
}

fn writeManifestSuppressedOptionText(writer: *std.Io.Writer, spelling_name: []const u8, reason: []const u8, by: []const u8, group: ?[]const u8, exclusion: ?[]const u8, indent: []const u8) !void {
    try writer.print("{s}- spelling: {s}\n", .{ indent, spelling_name });
    try writer.print("{s}  reason: {s}\n{s}  by: {s}\n{s}  group: {s}\n{s}  exclusion: {s}\n", .{ indent, reason, indent, by, indent, group orelse "", indent, exclusion orelse "" });
}

fn manifestParsedOptionExcludesOperands(parsed: ManifestParsedOption) ?[]const u8 {
    const excludes = parsed.excludes orelse return null;
    switch (excludes) {
        .string => |string| if (std.mem.eql(u8, string, "operands") or std.mem.eql(u8, string, "everything")) return string,
        .array => |array| for (array.items) |item| {
            const string = manifestString(item) orelse continue;
            if (std.mem.eql(u8, string, "operands") or std.mem.eql(u8, string, "everything")) return string;
        },
        else => {},
    }
    return null;
}

fn manifestParsedOptionExcludesOption(parsed: ManifestParsedOption, option: std.json.ObjectMap) ?[]const u8 {
    const excludes = parsed.excludes orelse return null;
    switch (excludes) {
        .string => |string| if (manifestExcludeMatchesOption(string, option)) return string,
        .array => |array| for (array.items) |item| {
            const string = manifestString(item) orelse continue;
            if (manifestExcludeMatchesOption(string, option)) return string;
        },
        else => {},
    }
    return null;
}

fn manifestExcludeMatchesOption(exclusion: []const u8, option: std.json.ObjectMap) bool {
    if (std.mem.eql(u8, exclusion, "everything")) return true;
    if (std.mem.eql(u8, exclusion, "operands")) return false;
    if (manifestOptionHasLiteralSpelling(option, exclusion)) return true;
    if (std.mem.startsWith(u8, exclusion, "--")) return manifestOptionNameMatches(option, exclusion[2..]);
    if (std.mem.startsWith(u8, exclusion, "-") and exclusion.len == 2) {
        const short = manifestString(option.get("short")) orelse return false;
        return short.len == 1 and short[0] == exclusion[1];
    }
    return false;
}

fn manifestParsedOptionsExcludeOperands(parsed_options: []const ManifestParsedOption) bool {
    for (parsed_options) |parsed| {
        if (manifestParsedOptionExcludesOperands(parsed) != null) return true;
    }
    return false;
}

fn manifestProviderRefLabel(provider: std.json.Value, buffer: *[128]u8) ?[]const u8 {
    switch (provider) {
        .string => |id| return id,
        .array => return "",
        .object => |object| {
            if (manifestString(object.get("builtin"))) |builtin| return std.fmt.bufPrint(buffer, "builtin.{s}", .{builtin}) catch builtin;
            if (manifestString(object.get("function"))) |function| return function;
            return null;
        },
        else => return null,
    }
}

fn manifestProviderCandidateCount(candidates: []const completion_model.Candidate, reason: []const u8) usize {
    if (std.mem.eql(u8, reason, "dynamicSubcommands")) return countCandidatesOfKind(candidates, .subcommand);
    if (std.mem.eql(u8, reason, "dynamicOptions")) return countCandidatesOfKind(candidates, .option);
    return candidates.len;
}

fn countCandidatesOfKind(candidates: []const completion_model.Candidate, kind: completion_model.Kind) usize {
    var count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.kind == kind) count += 1;
    }
    return count;
}

fn manifestFallbackKind(loaded: bool, provider_count: usize, candidates: []const completion_model.Candidate) []const u8 {
    if (!loaded) return "noManifest";
    if (provider_count == 0 and candidates.len != 0) return "staticCandidates";
    if (provider_count == 0) return "noProvider";
    if (candidates.len == 0) return "providerNoCandidates";
    return "none";
}

fn manifestFallbackReason(loaded: bool, provider_count: usize, candidates: []const completion_model.Candidate) []const u8 {
    if (!loaded) return "no manifest-backed rule matched; using Rush/default completion fallback";
    if (provider_count == 0 and candidates.len != 0) return "no manifest provider matched this cursor; static manifest candidates matched";
    if (provider_count == 0) return "no manifest provider matched this cursor; default fallback was considered";
    if (candidates.len == 0) return "matched manifest provider returned no candidates";
    return "manifest provider or static manifest candidates matched";
}

fn writeCompletionManifestTraceJson(allocator: std.mem.Allocator, io: std.Io, json: *std.json.Stringify, executor: exec.Executor, source: []const u8, semantic: completion_model.SemanticContext, trace_path: ?[]const []const u8, precommand_depth_limited: bool, candidates: []const completion_model.Candidate) !void {
    const manifest_source = primaryManifestRuleSource(executor.completionRules(), semantic);
    const manifest_state = executor.completionManifestCommandState(semantic.root);
    const variant_state = executor.completionVariantProbeState(semantic.root);
    const loaded = manifest_source != null or manifest_state != null;

    try json.beginObject();
    try json.objectField("loaded");
    try json.write(loaded);
    try json.objectField("path");
    try json.write(if (manifest_source) |rule_source| rule_source.manifest_path else if (manifest_state) |state| state.manifest_path else @as(?[]const u8, null));
    try json.objectField("manifestVersion");
    try json.write(if (manifest_source) |rule_source| rule_source.manifest_version else if (manifest_state) |state| state.manifest_version else @as(?i64, null));
    try json.objectField("commandPath");
    if (trace_path) |path| try writeCommandPathArrayJson(json, path) else try writeSemanticCommandPathArrayJson(json, semantic);
    try json.objectField("precommandDepthLimited");
    try json.write(precommand_depth_limited);
    try json.objectField("optionName");
    try json.write(if (semantic.option_value) |option_value| option_value.name else @as(?[]const u8, null));
    try json.objectField("optionValueIndex");
    try json.write(if (semantic.option_value) |option_value| option_value.value_index else @as(?usize, null));
    try json.objectField("platformGate");
    try json.beginObject();
    try json.objectField("platform");
    try json.write(if (manifest_state) |state| state.platform else completionManifestCurrentPlatform());
    try json.objectField("allowed");
    try json.write(if (manifest_state) |state| state.platform_allowed else true);
    try json.endObject();
    try json.objectField("variant");
    try json.beginObject();
    try json.objectField("selected");
    try json.write(if (variant_state) |state| state.selected else @as(?[]const u8, null));
    try json.objectField("probed");
    try json.write(if (variant_state) |state| state.last_probed else false);
    try json.objectField("cached");
    try json.write(if (variant_state) |state| state.last_cached else false);
    try json.objectField("skippedShadow");
    try json.write(if (variant_state) |state| state.skipped_shadow else false);
    try json.endObject();

    const source_info = manifest_source orelse {
        try writeEmptyManifestDecisionJson(json, "noManifest", "no manifest-backed rule matched; using Rush/default completion fallback");
        try json.endObject();
        return;
    };
    const path = source_info.manifest_path orelse {
        try writeEmptyManifestDecisionJson(json, "noManifestPath", "manifest rule did not retain a source path; structured manifest trace unavailable");
        try json.endObject();
        return;
    };

    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch {
        try writeEmptyManifestDecisionJson(json, "manifestUnavailable", "manifest file could not be read for trace rendering");
        try json.endObject();
        return;
    };
    defer allocator.free(contents);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
        try writeEmptyManifestDecisionJson(json, "manifestParseFailed", "manifest file could not be parsed for trace rendering");
        try json.endObject();
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try writeEmptyManifestDecisionJson(json, "manifestInvalid", "manifest root was not an object during trace rendering");
            try json.endObject();
            return;
        },
    };
    const command_value = root.get("command") orelse {
        try writeEmptyManifestDecisionJson(json, "manifestInvalid", "manifest command object was missing during trace rendering");
        try json.endObject();
        return;
    };
    const root_command = switch (command_value) {
        .object => |object| object,
        else => {
            try writeEmptyManifestDecisionJson(json, "manifestInvalid", "manifest command was not an object during trace rendering");
            try json.endObject();
            return;
        },
    };
    const active_command = manifestCommandForPath(root_command, semantic.path) orelse root_command;
    var trace = try analyzeManifestCompletionTrace(allocator, source, semantic, root_command, active_command);
    defer trace.deinit(allocator);
    var active_options: std.ArrayList(std.json.ObjectMap) = .empty;
    defer active_options.deinit(allocator);
    try appendManifestOptionsForPath(allocator, &active_options, root_command, semantic.path);

    try json.objectField("parsedOptions");
    try json.beginArray();
    for (trace.parsed_options.items) |option| {
        var spelling_buffer: [2]u8 = undefined;
        try json.beginObject();
        try json.objectField("spelling");
        try json.write(option.displaySpelling(&spelling_buffer));
        try json.objectField("from");
        try json.write(option.from);
        try json.objectField("name");
        try json.write(option.name);
        try json.objectField("value");
        try json.write(option.value);
        try json.objectField("exclusiveGroup");
        try json.write(option.exclusive_group);
        try json.objectField("repeatable");
        try json.write(option.repeatable);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("terminator");
    try json.beginObject();
    try json.objectField("defined");
    try json.write(trace.terminator_value != null);
    try json.objectField("value");
    try json.write(trace.terminator_value);
    try json.objectField("seen");
    try json.write(trace.terminator_seen);
    try json.endObject();

    try json.objectField("activeArgumentState");
    if (trace.active_argument_state) |state| {
        try writeManifestArgumentStateJson(json, state, trace.active_argument_index, trace.previous_argument_state, trace.terminator_seen, trace.parsed_options.items);
    } else {
        try json.write(@as(?[]const u8, null));
    }

    try json.objectField("matchedProviders");
    const provider_count = try writeManifestProvidersJson(json, semantic, active_command, active_options.items, trace, candidates);
    try json.objectField("suppressedOptions");
    try writeManifestSuppressedOptionsJson(json, active_options.items, trace.parsed_options.items);
    try json.objectField("suppressedOperands");
    try writeManifestSuppressedOperandsJson(json, trace.parsed_options.items);
    try json.objectField("fallback");
    try writeManifestFallbackJson(json, manifestFallbackKind(loaded, provider_count, candidates), manifestFallbackReason(loaded, provider_count, candidates));
    try json.endObject();
}

fn writeEmptyManifestDecisionJson(json: *std.json.Stringify, fallback_kind: []const u8, fallback_reason: []const u8) !void {
    try json.objectField("parsedOptions");
    try json.beginArray();
    try json.endArray();
    try json.objectField("terminator");
    try json.beginObject();
    try json.objectField("defined");
    try json.write(false);
    try json.objectField("value");
    try json.write(@as(?[]const u8, null));
    try json.objectField("seen");
    try json.write(false);
    try json.endObject();
    try json.objectField("activeArgumentState");
    try json.write(@as(?[]const u8, null));
    try json.objectField("matchedProviders");
    try json.beginArray();
    try json.endArray();
    try json.objectField("suppressedOptions");
    try json.beginArray();
    try json.endArray();
    try json.objectField("suppressedOperands");
    try json.beginArray();
    try json.endArray();
    try json.objectField("fallback");
    try writeManifestFallbackJson(json, fallback_kind, fallback_reason);
}

fn writeManifestFallbackJson(json: *std.json.Stringify, kind: []const u8, reason: []const u8) !void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write(kind);
    try json.objectField("reason");
    try json.write(reason);
    try json.endObject();
}

fn primaryManifestRuleSource(rules: []const completion_model.Rule, semantic: completion_model.SemanticContext) ?completion_model.RuleSource {
    for (rules) |rule| {
        if (rule.disabled) continue;
        if (rule.source.kind == .manifest and debugCompletionRuleMatches(rule, semantic)) return rule.source;
    }
    for (rules) |rule| {
        if (rule.disabled) continue;
        if (rule.source.kind == .manifest and std.mem.eql(u8, rule.root, semantic.root)) return rule.source;
    }
    return null;
}

fn writeSemanticCommandPathArrayJson(json: *std.json.Stringify, semantic: completion_model.SemanticContext) !void {
    try json.beginArray();
    if (semantic.root.len != 0) try json.write(semantic.root);
    for (semantic.path) |segment| try json.write(segment);
    try json.endArray();
}

fn writeCommandPathArrayJson(json: *std.json.Stringify, path: []const []const u8) !void {
    try json.beginArray();
    for (path) |segment| try json.write(segment);
    try json.endArray();
}

fn manifestCommandForPath(root_command: std.json.ObjectMap, path: []const []const u8) ?std.json.ObjectMap {
    var command = root_command;
    for (path) |segment| {
        const subcommands_value = command.get("subcommands") orelse return null;
        const subcommands = switch (subcommands_value) {
            .array => |array| array,
            else => return null,
        };
        var matched: ?std.json.ObjectMap = null;
        for (subcommands.items) |subcommand_value| {
            const subcommand = switch (subcommand_value) {
                .object => |object| object,
                else => continue,
            };
            if (manifestCommandNameMatches(subcommand, segment)) {
                matched = subcommand;
                break;
            }
        }
        command = matched orelse return null;
    }
    return command;
}

fn manifestCommandNameMatches(command: std.json.ObjectMap, name: []const u8) bool {
    if (manifestNameValueMatches(command.get("name"), name)) return true;
    return manifestNameValueMatches(command.get("aliases"), name);
}

fn manifestNameValueMatches(value: ?std.json.Value, name: []const u8) bool {
    return switch (value orelse return false) {
        .string => |string| std.mem.eql(u8, string, name),
        .array => |array| for (array.items) |item| {
            if (manifestString(item)) |string| if (std.mem.eql(u8, string, name)) break true;
        } else false,
        else => false,
    };
}

fn analyzeManifestCompletionTrace(allocator: std.mem.Allocator, source: []const u8, semantic: completion_model.SemanticContext, root_command: std.json.ObjectMap, active_command: std.json.ObjectMap) !ManifestCompletionTrace {
    var trace: ManifestCompletionTrace = .{};
    errdefer trace.deinit(allocator);
    if (active_command.get("arguments")) |arguments_value| {
        if (arguments_value == .object) trace.terminator_value = manifestString(arguments_value.object.get("terminator"));
    }

    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .cursor = source.len });
    defer parsed.deinit();
    const parser_context = parser.completionContext(parsed, source.len);

    var path_index: usize = 0;
    var word_index: usize = 0;
    var token_index: usize = 0;
    while (token_index < parsed.tokens.len) : (token_index += 1) {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        if (token.span.start > parser_context.cursor) break;
        const is_current = token_index == parser_context.token_index and parser_context.cursor <= token.span.end;
        if (is_current or token.span.end > parser_context.cursor) break;
        const word = token.lexeme(source);
        if (word_index == 0) {
            word_index += 1;
            continue;
        }
        if (path_index < semantic.path.len and std.mem.eql(u8, word, semantic.path[path_index])) {
            path_index += 1;
            word_index += 1;
            continue;
        }
        if (std.mem.eql(u8, word, "--")) {
            trace.terminator_seen = true;
            word_index += 1;
            continue;
        }
        if (!trace.terminator_seen) {
            if (findManifestOptionForPath(root_command, semantic.path, word)) |matched| {
                var parsed_option: ManifestParsedOption = .{
                    .spelling = matched.spelling,
                    .name = matched.name,
                    .key = manifestOptionMatchKey(matched),
                    .short = manifestOptionMatchShort(matched),
                    .value = matched.value,
                    .exclusive_group = manifestString(matched.option.get("exclusiveGroup")),
                    .excludes = matched.option.get("excludes"),
                    .repeatable = manifestBool(matched.option.get("repeatable")),
                };
                if (manifestBool(matched.option.get("terminatesOptions"))) trace.terminator_seen = true;
                if (manifestOptionTakesValue(matched.option) and !matched.attached_value and !std.mem.startsWith(u8, matched.spelling, "+")) {
                    if (nextCompleteWord(parsed, source, parser_context, token_index)) |next| {
                        parsed_option.value = next.word;
                        token_index = next.token_index;
                    }
                }
                try trace.parsed_options.append(allocator, parsed_option);
                word_index += 1;
                continue;
            }
            if (analyzeManifestShortOptionCluster(root_command, semantic.path, word)) |cluster| {
                if (cluster.valid) {
                    var offset: usize = 1;
                    while (offset < word.len) : (offset += 1) {
                        const matched = findManifestShortOptionForPath(root_command, semantic.path, word[offset]) orelse break;
                        var parsed_option: ManifestParsedOption = .{
                            .spelling = word,
                            .name = matched.name,
                            .key = manifestOptionMatchKey(matched),
                            .short = manifestOptionMatchShort(matched),
                            .value = if (manifestOptionTakesValue(matched.option) and offset + 1 < word.len) word[offset + 1 ..] else null,
                            .from = word,
                            .from_offset = offset,
                            .exclusive_group = manifestString(matched.option.get("exclusiveGroup")),
                            .excludes = matched.option.get("excludes"),
                            .repeatable = manifestBool(matched.option.get("repeatable")),
                        };
                        if (manifestBool(matched.option.get("terminatesOptions"))) trace.terminator_seen = true;
                        if (manifestOptionTakesValue(matched.option)) {
                            if (parsed_option.value == null) {
                                if (nextCompleteWord(parsed, source, parser_context, token_index)) |next| {
                                    parsed_option.value = next.word;
                                    token_index = next.token_index;
                                }
                            }
                            try trace.parsed_options.append(allocator, parsed_option);
                            break;
                        }
                        try trace.parsed_options.append(allocator, parsed_option);
                    }
                    word_index += 1;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, word, "-")) {
                word_index += 1;
                continue;
            }
        }
        const operand_state = manifestActiveArgumentState(active_command, trace.active_argument_index, trace.previous_argument_state, trace.terminator_seen, trace.parsed_options.items);
        trace.previous_argument_state = if (operand_state) |state| manifestString(state.get("name")) else null;
        trace.active_argument_index += 1;
        word_index += 1;
    }

    if (semantic.position == .argument or semantic.position == .subcommand) {
        trace.active_argument_state = manifestActiveArgumentState(active_command, trace.active_argument_index, trace.previous_argument_state, trace.terminator_seen, trace.parsed_options.items);
    }
    return trace;
}

const ManifestNextWord = struct {
    token_index: usize,
    word: []const u8,
};

fn nextCompleteWord(parsed: parser.ParseResult, source: []const u8, context: parser.CompletionContext, start_token_index: usize) ?ManifestNextWord {
    var index = start_token_index + 1;
    while (index < parsed.tokens.len) : (index += 1) {
        const token = parsed.tokens[index];
        if (token.kind != .word) continue;
        if (token.span.start > context.cursor) return null;
        const is_current = index == context.token_index and context.cursor <= token.span.end;
        if (is_current or token.span.end > context.cursor) return null;
        return .{ .token_index = index, .word = token.lexeme(source) };
    }
    return null;
}

fn appendManifestOptionsForPath(allocator: std.mem.Allocator, options: *std.ArrayList(std.json.ObjectMap), root_command: std.json.ObjectMap, path: []const []const u8) !void {
    try appendManifestCommandOptions(allocator, options, root_command);
    var command = root_command;
    for (path) |segment| {
        command = manifestCommandForPath(command, &.{segment}) orelse return;
        try appendManifestCommandOptions(allocator, options, command);
    }
}

fn appendManifestCommandOptions(allocator: std.mem.Allocator, options: *std.ArrayList(std.json.ObjectMap), command: std.json.ObjectMap) !void {
    const options_value = command.get("options") orelse return;
    const array = switch (options_value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |option_value| {
        if (option_value == .object) try options.append(allocator, option_value.object);
    }
}

fn findManifestOptionForPath(root_command: std.json.ObjectMap, path: []const []const u8, word: []const u8) ?ManifestOptionMatch {
    var options: [128]std.json.ObjectMap = undefined;
    var len: usize = 0;
    appendManifestOptionsForPathBounded(&options, &len, root_command, path);
    for (options[0..len]) |option| {
        if (manifestOptionMatchesWord(option, word)) |matched| return matched;
    }
    return null;
}

const ManifestShortOptionCluster = struct {
    valid: bool,
    unknown_offset: ?usize = null,
};

fn analyzeManifestShortOptionCluster(root_command: std.json.ObjectMap, path: []const []const u8, word: []const u8) ?ManifestShortOptionCluster {
    if (word.len <= 2 or word[0] != '-' or word[1] == '-') return null;
    var offset: usize = 1;
    while (offset < word.len) : (offset += 1) {
        const matched = findManifestShortOptionForPath(root_command, path, word[offset]) orelse return .{ .valid = false, .unknown_offset = offset };
        if (manifestOptionTakesValue(matched.option)) return .{ .valid = true };
    }
    return .{ .valid = true };
}

fn findManifestShortOptionForPath(root_command: std.json.ObjectMap, path: []const []const u8, short: u8) ?ManifestOptionMatch {
    var options: [128]std.json.ObjectMap = undefined;
    var len: usize = 0;
    appendManifestOptionsForPathBounded(&options, &len, root_command, path);
    for (options[0..len]) |option| {
        const option_short = manifestString(option.get("short")) orelse continue;
        if (option_short.len == 1 and option_short[0] == short) return .{ .option = option, .spelling = option_short, .name = option_short };
    }
    return null;
}

fn appendManifestOptionsForPathBounded(buffer: []std.json.ObjectMap, len: *usize, root_command: std.json.ObjectMap, path: []const []const u8) void {
    appendManifestCommandOptionsBounded(buffer, len, root_command);
    var command = root_command;
    for (path) |segment| {
        command = manifestCommandForPath(command, &.{segment}) orelse return;
        appendManifestCommandOptionsBounded(buffer, len, command);
    }
}

fn appendManifestCommandOptionsBounded(buffer: []std.json.ObjectMap, len: *usize, command: std.json.ObjectMap) void {
    const options_value = command.get("options") orelse return;
    const array = switch (options_value) {
        .array => |items| items,
        else => return,
    };
    for (array.items) |option_value| {
        if (len.* >= buffer.len) return;
        if (option_value == .object) {
            buffer[len.*] = option_value.object;
            len.* += 1;
        }
    }
}

fn manifestOptionMatchesWord(option: std.json.ObjectMap, word: []const u8) ?ManifestOptionMatch {
    if (option.get("spellings")) |spellings_value| {
        if (spellings_value == .array) {
            for (spellings_value.array.items) |spelling_value| {
                const literal = manifestString(spelling_value) orelse continue;
                if (std.mem.eql(u8, word, literal)) return .{ .option = option, .spelling = word, .name = literal };
                if (manifestLiteralOptionAttachedValue(literal, word)) |value| return .{ .option = option, .spelling = literal, .name = literal, .value = value, .attached_value = true };
            }
        }
    }
    if (std.mem.startsWith(u8, word, "--")) {
        const body = word[2..];
        const equals_index = std.mem.indexOfScalar(u8, body, '=');
        const name = if (equals_index) |index| body[0..index] else body;
        if (manifestOptionHasLongName(option, name)) {
            const spelling = word[0 .. 2 + name.len];
            return .{ .option = option, .spelling = spelling, .name = name, .value = if (equals_index) |index| body[index + 1 ..] else null, .attached_value = equals_index != null };
        }
    }
    if (std.mem.startsWith(u8, word, "-") and !std.mem.startsWith(u8, word, "--")) {
        const short = manifestString(option.get("short")) orelse return null;
        if (word.len == short.len + 1 and std.mem.eql(u8, word[1..], short)) return .{ .option = option, .spelling = word, .name = short };
    }
    return null;
}

fn manifestLiteralOptionAttachedValue(spelling: []const u8, word: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, spelling, "+")) return null;
    if (!std.mem.startsWith(u8, word, spelling) or word.len <= spelling.len) return null;
    if (std.mem.startsWith(u8, spelling, "--")) {
        if (word[spelling.len] != '=') return null;
        return word[spelling.len + 1 ..];
    }
    if (std.mem.startsWith(u8, spelling, "-")) return word[spelling.len..];
    return null;
}

fn manifestOptionHasLongName(option: std.json.ObjectMap, name: []const u8) bool {
    if (manifestString(option.get("long"))) |long| if (std.mem.eql(u8, long, name)) return true;
    const aliases_value = option.get("aliases") orelse return false;
    const aliases = switch (aliases_value) {
        .array => |array| array,
        else => return false,
    };
    for (aliases.items) |alias_value| {
        if (manifestString(alias_value)) |alias| if (std.mem.eql(u8, alias, name)) return true;
    }
    return false;
}

fn manifestOptionTakesValue(option: std.json.ObjectMap) bool {
    return option.get("value") != null;
}

fn manifestActiveArgumentState(command: std.json.ObjectMap, active_index: usize, previous_state: ?[]const u8, terminator_seen: bool, parsed_options: []const ManifestParsedOption) ?std.json.ObjectMap {
    if (manifestParsedOptionsExcludeOperands(parsed_options)) return null;
    const arguments_value = command.get("arguments") orelse return null;
    const arguments = switch (arguments_value) {
        .object => |object| object,
        else => return null,
    };
    const states_value = arguments.get("states") orelse return null;
    const states = switch (states_value) {
        .array => |array| array,
        else => return null,
    };

    for (states.items) |state_value| {
        const state = switch (state_value) {
            .object => |object| object,
            else => continue,
        };
        if (!manifestStateConditionsAllow(state, previous_state, terminator_seen, parsed_options)) continue;
        if (manifestExplicitArgumentStateMatches(state, active_index)) return state;
    }

    var next_index: usize = 0;
    for (states.items) |state_value| {
        const state = switch (state_value) {
            .object => |object| object,
            else => continue,
        };
        if (!manifestStateConditionsAllow(state, previous_state, terminator_seen, parsed_options)) continue;
        if (manifestStateHasExplicitTransition(state)) continue;
        const explicit_index = manifestInteger(state.get("index"));
        if (explicit_index) |index| if (index < 0) continue;
        const state_index: usize = if (explicit_index) |index| @intCast(index) else next_index;
        const repeatable = manifestBool(state.get("repeatable"));
        if (active_index == state_index or (repeatable and active_index >= state_index)) return state;
        if (explicit_index) |index| {
            if (index >= 0) next_index = @max(next_index, @as(usize, @intCast(index)) + 1);
        } else if (!repeatable) {
            next_index += 1;
        }
    }
    return null;
}

fn manifestExplicitArgumentStateMatches(state: std.json.ObjectMap, active_index: usize) bool {
    if (manifestInteger(state.get("index"))) |index| {
        if (index < 0) return false;
        const state_index: usize = @intCast(index);
        if (active_index == state_index or (manifestBool(state.get("repeatable")) and active_index >= state_index)) return true;
    }
    return state.get("after") != null and manifestConditionRequiresPreviousState(state.get("after"));
}

fn manifestStateHasExplicitTransition(state: std.json.ObjectMap) bool {
    return state.get("index") != null or (state.get("after") != null and manifestConditionRequiresPreviousState(state.get("after")));
}

fn manifestStateConditionsAllow(state: std.json.ObjectMap, previous_state: ?[]const u8, terminator_seen: bool, parsed_options: []const ManifestParsedOption) bool {
    if (state.get("when")) |condition| {
        if (!manifestConditionAllows(condition, previous_state, terminator_seen, parsed_options)) return false;
    }
    if (state.get("after")) |condition| {
        if (!manifestConditionAllows(condition, previous_state, terminator_seen, parsed_options)) return false;
    }
    if (state.get("until")) |condition| {
        if (manifestConditionAllows(condition, previous_state, terminator_seen, parsed_options)) return false;
    }
    return true;
}

fn manifestConditionAllows(condition_value: std.json.Value, previous_state: ?[]const u8, terminator_seen: bool, parsed_options: []const ManifestParsedOption) bool {
    const condition = switch (condition_value) {
        .object => |object| object,
        else => return true,
    };
    if (condition.get("all")) |children| {
        const array = switch (children) {
            .array => |array| array,
            else => return true,
        };
        for (array.items) |child| {
            if (!manifestConditionAllows(child, previous_state, terminator_seen, parsed_options)) return false;
        }
        return true;
    }
    if (condition.get("any")) |children| {
        const array = switch (children) {
            .array => |array| array,
            else => return true,
        };
        for (array.items) |child| {
            if (manifestConditionAllows(child, previous_state, terminator_seen, parsed_options)) return true;
        }
        return false;
    }
    if (condition.get("not")) |child| return !manifestConditionAllows(child, previous_state, terminator_seen, parsed_options);
    if (condition.get("terminatorSeen")) |value| {
        if (value == .bool) return value.bool == terminator_seen;
    }
    if (manifestString(condition.get("previousState"))) |expected| {
        const actual = previous_state orelse return false;
        return std.mem.eql(u8, actual, expected);
    }
    if (condition.get("optionPresent")) |selector_or_selectors| return manifestConditionOptionPresence(selector_or_selectors, parsed_options, true);
    if (condition.get("optionAbsent")) |selector_or_selectors| return manifestConditionOptionPresence(selector_or_selectors, parsed_options, false);
    if (condition.get("optionValue")) |option_value| return manifestConditionOptionValue(option_value, parsed_options);
    return true;
}

fn manifestConditionRequiresPreviousState(condition_value: ?std.json.Value) bool {
    const condition = switch (condition_value orelse return false) {
        .object => |object| object,
        else => return false,
    };
    if (condition.get("previousState") != null) return true;
    if (condition.get("all")) |children_value| {
        const children = switch (children_value) {
            .array => |array| array,
            else => return false,
        };
        for (children.items) |child| if (manifestConditionRequiresPreviousState(child)) return true;
        return false;
    }
    if (condition.get("any")) |children_value| {
        const children = switch (children_value) {
            .array => |array| array,
            else => return false,
        };
        if (children.items.len == 0) return false;
        for (children.items) |child| {
            if (!manifestConditionRequiresPreviousState(child)) return false;
        }
        return true;
    }
    return false;
}

fn manifestConditionOptionPresence(selector_or_selectors: std.json.Value, parsed_options: []const ManifestParsedOption, expected: bool) bool {
    switch (selector_or_selectors) {
        .string => |selector| return manifestParsedOptionsContainSelector(parsed_options, selector) == expected,
        .array => |array| {
            for (array.items) |item| {
                const selector = manifestString(item) orelse continue;
                if ((manifestParsedOptionsContainSelector(parsed_options, selector) == expected) != true) return false;
            }
            return true;
        },
        else => return true,
    }
}

fn manifestConditionOptionValue(option_value: std.json.Value, parsed_options: []const ManifestParsedOption) bool {
    const object = switch (option_value) {
        .object => |object| object,
        else => return true,
    };
    var iter = object.iterator();
    while (iter.next()) |entry| {
        if (manifestConditionOptionValueEntry(entry.key_ptr.*, entry.value_ptr.*, parsed_options)) return true;
    }
    return false;
}

fn manifestConditionOptionValueEntry(selector: []const u8, value_condition: std.json.Value, parsed_options: []const ManifestParsedOption) bool {
    for (parsed_options) |parsed| {
        if (!manifestParsedOptionMatchesSelector(parsed, selector)) continue;
        const value = parsed.value orelse continue;
        switch (value_condition) {
            .string => |literal| if (std.mem.eql(u8, value, literal)) return true,
            .array => |array| for (array.items) |item| {
                const literal = manifestString(item) orelse continue;
                if (std.mem.eql(u8, value, literal)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn manifestParsedOptionsContainSelector(parsed_options: []const ManifestParsedOption, selector: []const u8) bool {
    for (parsed_options) |parsed| {
        if (manifestParsedOptionMatchesSelector(parsed, selector)) return true;
    }
    return false;
}

fn manifestParsedOptionMatchesSelector(parsed: ManifestParsedOption, selector: []const u8) bool {
    var spelling_buffer: [2]u8 = undefined;
    if (std.mem.eql(u8, parsed.spelling, selector) or std.mem.eql(u8, parsed.displaySpelling(&spelling_buffer), selector)) return true;
    if (std.mem.startsWith(u8, selector, "--") and selector.len > 2) return std.mem.eql(u8, parsed.key, selector[2..]);
    if (std.mem.startsWith(u8, selector, "-") and selector.len == 2) {
        if (parsed.short) |short| return std.mem.eql(u8, short, selector[1..]);
        return std.mem.eql(u8, parsed.key, selector[1..]);
    }
    return false;
}

fn writeManifestArgumentStateJson(json: *std.json.Stringify, state: std.json.ObjectMap, active_index: usize, previous_state: ?[]const u8, terminator_seen: bool, parsed_options: []const ManifestParsedOption) !void {
    try json.beginObject();
    try json.objectField("name");
    try json.write(manifestString(state.get("name")) orelse "");
    try json.objectField("index");
    try json.write(if (manifestInteger(state.get("index"))) |index| if (index >= 0) @as(?i64, index) else @as(?i64, @intCast(active_index)) else @as(?i64, @intCast(active_index)));
    try json.objectField("repeatable");
    try json.write(manifestBool(state.get("repeatable")));
    try json.objectField("provider");
    if (state.get("provider")) |provider| try writeManifestProviderRefValue(json, provider) else try json.write(@as(?[]const u8, null));
    try json.objectField("conditionResults");
    try writeManifestArgumentConditionResultsJson(json, state, previous_state, terminator_seen, parsed_options);
    try json.endObject();
}

fn writeManifestArgumentConditionResultsJson(json: *std.json.Stringify, state: std.json.ObjectMap, previous_state: ?[]const u8, terminator_seen: bool, parsed_options: []const ManifestParsedOption) !void {
    try json.beginArray();
    inline for (&.{ "when", "after", "until" }) |field| {
        if (state.get(field)) |condition| try writeManifestConditionResultsJson(json, field, condition, previous_state, terminator_seen, parsed_options);
    }
    try json.endArray();
}

fn writeManifestConditionResultsJson(json: *std.json.Stringify, field: []const u8, condition_value: std.json.Value, previous_state: ?[]const u8, terminator_seen: bool, parsed_options: []const ManifestParsedOption) !void {
    const condition = switch (condition_value) {
        .object => |object| object,
        else => return,
    };
    if (condition.get("terminatorSeen")) |value| {
        if (value == .bool) {
            try writeManifestBooleanConditionResultJson(json, field, "terminatorSeen", value.bool, value.bool == terminator_seen);
        }
    }
    if (manifestString(condition.get("previousState"))) |expected| {
        const matched = if (previous_state) |actual| std.mem.eql(u8, actual, expected) else false;
        try json.beginObject();
        try json.objectField("field");
        try json.write(field);
        try json.objectField("kind");
        try json.write("previousState");
        try json.objectField("state");
        try json.write(expected);
        try json.objectField("matched");
        try json.write(matched);
        try json.endObject();
    }
    if (condition.get("optionPresent")) |selector_or_selectors| {
        try writeManifestOptionPresenceConditionResultsJson(json, field, "optionPresent", selector_or_selectors, parsed_options, true);
    }
    if (condition.get("optionAbsent")) |selector_or_selectors| {
        try writeManifestOptionPresenceConditionResultsJson(json, field, "optionAbsent", selector_or_selectors, parsed_options, false);
    }
    if (condition.get("optionValue")) |option_value| {
        const object = switch (option_value) {
            .object => |object| object,
            else => return,
        };
        var iter = object.iterator();
        while (iter.next()) |entry| {
            try json.beginObject();
            try json.objectField("field");
            try json.write(field);
            try json.objectField("kind");
            try json.write("optionValue");
            try json.objectField("selector");
            try json.write(entry.key_ptr.*);
            try json.objectField("values");
            try writeManifestConditionValueLiteralsJson(json, entry.value_ptr.*);
            try json.objectField("matched");
            try json.write(manifestConditionOptionValueEntry(entry.key_ptr.*, entry.value_ptr.*, parsed_options));
            try json.endObject();
        }
    }
    inline for (&.{ "all", "any" }) |nested_field| {
        if (condition.get(nested_field)) |children| {
            const array = switch (children) {
                .array => |array| array,
                else => return,
            };
            for (array.items) |child| try writeManifestConditionResultsJson(json, field, child, previous_state, terminator_seen, parsed_options);
        }
    }
    if (condition.get("not")) |child| try writeManifestConditionResultsJson(json, field, child, previous_state, terminator_seen, parsed_options);
}

fn writeManifestBooleanConditionResultJson(json: *std.json.Stringify, field: []const u8, kind: []const u8, expected: bool, matched: bool) !void {
    try json.beginObject();
    try json.objectField("field");
    try json.write(field);
    try json.objectField("kind");
    try json.write(kind);
    try json.objectField("expected");
    try json.write(expected);
    try json.objectField("matched");
    try json.write(matched);
    try json.endObject();
}

fn writeManifestOptionPresenceConditionResultsJson(json: *std.json.Stringify, field: []const u8, kind: []const u8, selector_or_selectors: std.json.Value, parsed_options: []const ManifestParsedOption, expected: bool) !void {
    switch (selector_or_selectors) {
        .string => |selector| try writeManifestOptionPresenceConditionResultJson(json, field, kind, selector, parsed_options, expected),
        .array => |array| for (array.items) |item| if (manifestString(item)) |selector| try writeManifestOptionPresenceConditionResultJson(json, field, kind, selector, parsed_options, expected),
        else => {},
    }
}

fn writeManifestOptionPresenceConditionResultJson(json: *std.json.Stringify, field: []const u8, kind: []const u8, selector: []const u8, parsed_options: []const ManifestParsedOption, expected: bool) !void {
    try json.beginObject();
    try json.objectField("field");
    try json.write(field);
    try json.objectField("kind");
    try json.write(kind);
    try json.objectField("selector");
    try json.write(selector);
    try json.objectField("matched");
    try json.write(manifestParsedOptionsContainSelector(parsed_options, selector) == expected);
    try json.endObject();
}

fn writeManifestConditionValueLiteralsJson(json: *std.json.Stringify, value: std.json.Value) !void {
    try json.beginArray();
    switch (value) {
        .string => |literal| try json.write(literal),
        .array => |array| for (array.items) |item| if (manifestString(item)) |literal| try json.write(literal),
        else => {},
    }
    try json.endArray();
}

fn writeManifestProvidersJson(json: *std.json.Stringify, semantic: completion_model.SemanticContext, active_command: std.json.ObjectMap, active_options: []const std.json.ObjectMap, trace: ManifestCompletionTrace, candidates: []const completion_model.Candidate) !usize {
    var count: usize = 0;
    try json.beginArray();
    if (trace.active_argument_state) |state| {
        if (state.get("provider")) |provider| {
            count += try writeManifestProviderEntriesJson(json, provider, "argumentState", candidates);
        }
    }
    if (semantic.option_value) |option_value| {
        if (findManifestOptionByName(active_options, option_value.name)) |option| {
            if (manifestOptionValueObjectAt(option, option_value.value_index)) |value| {
                if (value.get("provider")) |provider| {
                    count += try writeManifestProviderEntriesJson(json, provider, "optionValue", candidates);
                }
            }
        }
    }
    if (semantic.position == .subcommand) {
        if (active_command.get("dynamicSubcommands")) |providers| count += try writeManifestProviderArrayEntriesJson(json, providers, "dynamicSubcommands", candidates);
    }
    if (semantic.position == .option) {
        if (active_command.get("dynamicOptions")) |providers| count += try writeManifestProviderArrayEntriesJson(json, providers, "dynamicOptions", candidates);
    }
    try json.endArray();
    return count;
}

fn writeManifestProviderEntriesJson(json: *std.json.Stringify, provider_value: std.json.Value, reason: []const u8, candidates: []const completion_model.Candidate) !usize {
    switch (provider_value) {
        .array => return writeManifestProviderArrayEntriesJson(json, provider_value, reason, candidates),
        else => {
            try writeManifestProviderEntryJson(json, provider_value, reason, candidates);
            return 1;
        },
    }
}

fn writeManifestProviderArrayEntriesJson(json: *std.json.Stringify, providers_value: std.json.Value, reason: []const u8, candidates: []const completion_model.Candidate) !usize {
    const providers = switch (providers_value) {
        .array => |array| array,
        else => return 0,
    };
    for (providers.items) |provider| try writeManifestProviderEntryJson(json, provider, reason, candidates);
    return providers.items.len;
}

fn writeManifestProviderEntryJson(json: *std.json.Stringify, provider: std.json.Value, reason: []const u8, candidates: []const completion_model.Candidate) !void {
    try json.beginObject();
    try json.objectField("id");
    try writeManifestProviderRefValue(json, provider);
    try json.objectField("reason");
    try json.write(reason);
    try json.objectField("candidateCount");
    try json.write(manifestProviderCandidateCount(candidates, reason));
    try json.endObject();
}

fn writeManifestProviderRefValue(json: *std.json.Stringify, provider: std.json.Value) !void {
    switch (provider) {
        .string => |id| try json.write(id),
        .array => |array| {
            try json.beginArray();
            for (array.items) |item| try writeManifestProviderRefValue(json, item);
            try json.endArray();
        },
        .object => |object| {
            if (manifestString(object.get("builtin"))) |builtin| {
                var buffer: [128]u8 = undefined;
                const id = std.fmt.bufPrint(&buffer, "builtin.{s}", .{builtin}) catch builtin;
                try json.write(id);
            } else if (manifestString(object.get("function"))) |function| {
                try json.write(function);
            } else {
                try json.write(@as(?[]const u8, null));
            }
        },
        else => try json.write(@as(?[]const u8, null)),
    }
}

fn findManifestOptionByName(options: []const std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    for (options) |option| {
        if (manifestOptionHasLiteralSpelling(option, name)) return option;
        if (manifestString(option.get("long"))) |long| if (std.mem.eql(u8, long, name)) return option;
        if (manifestString(option.get("short"))) |short| if (std.mem.eql(u8, short, name)) return option;
        const aliases_value = option.get("aliases") orelse continue;
        if (aliases_value != .array) continue;
        for (aliases_value.array.items) |alias_value| {
            if (manifestString(alias_value)) |alias| if (std.mem.eql(u8, alias, name)) return option;
        }
    }
    return null;
}

fn writeManifestSuppressedOptionsJson(json: *std.json.Stringify, options: []const std.json.ObjectMap, parsed_options: []const ManifestParsedOption) !void {
    try json.beginArray();
    for (options) |option| {
        var spelling_buffer: [256]u8 = undefined;
        const spelling = manifestOptionPrimarySpelling(option, &spelling_buffer) orelse continue;
        if (manifestParsedOptionForOption(parsed_options, option)) |parsed| {
            var parsed_spelling_buffer: [2]u8 = undefined;
            if (!manifestBool(option.get("repeatable"))) try writeManifestSuppressedOptionJson(json, spelling, "alreadyPresent", parsed.displaySpelling(&parsed_spelling_buffer), null, null);
            continue;
        }
        var suppressed = false;
        if (manifestString(option.get("exclusiveGroup"))) |group| {
            for (parsed_options) |parsed| {
                if (parsed.exclusive_group) |parsed_group| {
                    if (std.mem.eql(u8, group, parsed_group)) {
                        var parsed_spelling_buffer: [2]u8 = undefined;
                        try writeManifestSuppressedOptionJson(json, spelling, "exclusiveGroup", parsed.displaySpelling(&parsed_spelling_buffer), group, null);
                        suppressed = true;
                        break;
                    }
                }
            }
        }
        if (suppressed) continue;
        for (parsed_options) |parsed| {
            const exclusion = manifestParsedOptionExcludesOption(parsed, option) orelse continue;
            var parsed_spelling_buffer: [2]u8 = undefined;
            try writeManifestSuppressedOptionJson(json, spelling, "excluded", parsed.displaySpelling(&parsed_spelling_buffer), null, exclusion);
            break;
        }
    }
    try json.endArray();
}

fn writeManifestSuppressedOperandsJson(json: *std.json.Stringify, parsed_options: []const ManifestParsedOption) !void {
    try json.beginArray();
    for (parsed_options) |parsed| {
        const exclusion = manifestParsedOptionExcludesOperands(parsed) orelse continue;
        var parsed_spelling_buffer: [2]u8 = undefined;
        try json.beginObject();
        try json.objectField("reason");
        try json.write("excluded");
        try json.objectField("by");
        try json.write(parsed.displaySpelling(&parsed_spelling_buffer));
        try json.objectField("exclusion");
        try json.write(exclusion);
        try json.endObject();
        break;
    }
    try json.endArray();
}

fn manifestOptionPrimarySpelling(option: std.json.ObjectMap, buffer: *[256]u8) ?[]const u8 {
    if (manifestString(option.get("long"))) |long| return std.fmt.bufPrint(buffer, "--{s}", .{long}) catch null;
    if (manifestString(option.get("short"))) |short| return std.fmt.bufPrint(buffer, "-{s}", .{short}) catch null;
    if (manifestFirstString(option.get("spellings"))) |spelling| return spelling;
    const aliases_value = option.get("aliases") orelse return null;
    if (aliases_value != .array or aliases_value.array.items.len == 0) return null;
    const alias = manifestString(aliases_value.array.items[0]) orelse return null;
    return std.fmt.bufPrint(buffer, "--{s}", .{alias}) catch null;
}

fn manifestParsedOptionForOption(parsed_options: []const ManifestParsedOption, option: std.json.ObjectMap) ?ManifestParsedOption {
    for (parsed_options) |parsed| {
        if (manifestOptionNameMatches(option, parsed.name) or manifestOptionHasLiteralSpelling(option, parsed.spelling)) return parsed;
    }
    return null;
}

fn manifestOptionNameMatches(option: std.json.ObjectMap, name: []const u8) bool {
    if (manifestOptionHasLiteralSpelling(option, name)) return true;
    if (manifestString(option.get("long"))) |long| if (std.mem.eql(u8, long, name)) return true;
    if (manifestString(option.get("short"))) |short| if (std.mem.eql(u8, short, name)) return true;
    const aliases_value = option.get("aliases") orelse return false;
    if (aliases_value != .array) return false;
    for (aliases_value.array.items) |alias_value| {
        if (manifestString(alias_value)) |alias| if (std.mem.eql(u8, alias, name)) return true;
    }
    return false;
}

fn manifestOptionHasLiteralSpelling(option: std.json.ObjectMap, spelling: []const u8) bool {
    if (option.get("spellings")) |spellings_value| {
        if (spellings_value == .array) {
            for (spellings_value.array.items) |spelling_value| {
                if (manifestString(spelling_value)) |literal| if (std.mem.eql(u8, literal, spelling)) return true;
            }
        }
    }
    if (option.get("aliases")) |aliases_value| {
        if (aliases_value == .array) {
            for (aliases_value.array.items) |alias_value| {
                const alias = manifestString(alias_value) orelse continue;
                if (spelling.len == alias.len + 2 and std.mem.startsWith(u8, spelling, "--") and std.mem.eql(u8, spelling[2..], alias)) return true;
            }
        }
    }
    return false;
}

fn writeManifestSuppressedOptionJson(json: *std.json.Stringify, spelling_name: []const u8, reason: []const u8, by: []const u8, group: ?[]const u8, exclusion: ?[]const u8) !void {
    try json.beginObject();
    try json.objectField("spelling");
    try json.write(spelling_name);
    try json.objectField("reason");
    try json.write(reason);
    try json.objectField("by");
    try json.write(by);
    try json.objectField("group");
    try json.write(group);
    try json.objectField("exclusion");
    try json.write(exclusion);
    try json.endObject();
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

const InteractiveOptions = struct {
    arg_zero: []const u8 = "rush",
    login: bool = false,
    features: compat.Features = .{},
    shell_options: shell.ShellOptions = .{},
    monitor_option_explicit: bool = false,
    positionals: []const []const u8 = &.{},
};

const InteractiveShell = struct {
    allocator: std.mem.Allocator,
    executor: exec.Executor,
    semantic_state: shell.ShellState,
    semantic_enabled: bool = false,

    fn init(allocator: std.mem.Allocator) InteractiveShell {
        return .{
            .allocator = allocator,
            .executor = exec.Executor.init(allocator),
            .semantic_state = shell.ShellState.init(allocator),
        };
    }

    fn deinit(self: *InteractiveShell) void {
        self.semantic_state.deinit();
        self.executor.deinit();
        self.* = undefined;
    }

    fn syncSemanticFromExecutor(self: *InteractiveShell, io: std.Io) !void {
        std.debug.assert(self.executor.execution_depth == 0);
        self.semantic_state.deinit();
        self.semantic_state = shell.ShellState.init(self.allocator);
        self.semantic_enabled = false;
        if (try initializeSemanticInteractiveStateFromExecutor(self.allocator, io, &self.semantic_state, self.executor)) |message| {
            std.debug.assert(message.len != 0);
            return;
        }
        self.semantic_enabled = true;
    }

    fn initializeSemanticStartup(self: *InteractiveShell, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !void {
        std.debug.assert(self.executor.execution_depth == 0);
        self.semantic_state.deinit();
        self.semantic_state = shell.ShellState.init(self.allocator);
        self.semantic_enabled = false;

        var startup_shell_options = options.shell_options;
        setInteractiveStartupShellOptions(&startup_shell_options, options.monitor_option_explicit, stdinIsTty(io));
        try initializeSemanticInteractiveStartupState(self.allocator, io, &self.semantic_state, environ_map, options.positionals, startup_shell_options);
        self.semantic_enabled = true;

        try self.executor.importEnvironment(environ_map);
        self.executor.arg_zero = options.arg_zero;
        try self.syncExecutorFromSemantic();
    }

    fn syncExecutorFromSemantic(self: *InteractiveShell) !void {
        if (!self.semantic_enabled) return;
        try syncExecutorFromSemanticInteractiveState(&self.executor, self.semantic_state);
    }
};

fn setInteractiveStartupShellOptions(shell_options: *shell.ShellOptions, monitor_option_explicit: bool, stdin_is_tty: bool) void {
    if (stdin_is_tty and !monitor_option_explicit) shell_options.monitor = true;
    shell_options.noexec = false;
}

pub fn runInteractive(allocator: std.mem.Allocator, completion_allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !u8 {
    var signal_handlers = installInteractiveSignalHandlers();
    defer signal_handlers.restore();

    var history = History.init(allocator);
    defer history.deinit();
    var history_service = InteractiveHistoryService.init(&history);
    const active_session_id = try historySessionId(allocator, io);
    defer allocator.free(active_session_id);
    history.session_id = active_session_id;
    const history_path = try historyPath(allocator, environ_map);
    defer if (history_path) |path| allocator.free(path);
    if (history_path) |path| history.load(io, path) catch {};
    defer if (history_path) |path| history.save(io, path) catch {};
    const terminal_hostname = try localHostname(allocator);
    defer allocator.free(terminal_hostname);

    var last_status: shell.ExitStatus = 0;
    var interactive_shell = InteractiveShell.init(allocator);
    defer interactive_shell.deinit();
    const executor = &interactive_shell.executor;
    history_service.attachFc(executor);
    const prompt_service: InteractivePromptService = .{ .executor = executor, .arg_zero = options.arg_zero, .features = options.features };
    try interactive_shell.initializeSemanticStartup(io, environ_map, options);
    try InteractiveConfigService.initInteractive(allocator, io, &interactive_shell, options.arg_zero).load(options);
    if (executor.pending_exit) |status| return status;
    var terminal = try editor_driver.TerminalSession.init(allocator, io);
    defer terminal.deinit();
    runtime.signal.setWakeFd(terminal.trapSignalWakeFd());
    defer runtime.signal.clearWakeFd(terminal.trapSignalWakeFd());
    try prompt_service.applyColorScheme(io, .unknown);
    try syncInteractiveTerminalSize(executor, terminal);
    if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
    executor.setPromptRepaintHandler(&terminal, requestInteractivePromptRepaint);

    var completion_cache = CompletionCache.init(completion_allocator);
    defer completion_cache.deinit();
    var completion_loader = CompletionScriptLoader.init(allocator);
    defer completion_loader.deinit();

    repl_loop: while (true) {
        if (executor.pending_exit) |status| {
            last_status = status;
            break;
        }
        terminal.refreshWinsize();
        try syncInteractiveTerminalSize(executor, terminal);
        if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const notifications = try executor.drainJobNotifications();
        try writeAll(io, .stderr, notifications);
        allocator.free(notifications);
        try prompt_service.runPendingVariableHooks(io);
        try interactive_shell.syncSemanticFromExecutor(io);
        try prompt_service.runEventHooks(io, "prompt", &.{});
        try interactive_shell.syncSemanticFromExecutor(io);
        if (executor.pending_exit) |status| {
            last_status = status;
            break;
        }
        const prompt = try prompt_service.render(allocator, io);
        defer allocator.free(prompt);
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        const physical_cwd = cwd_buffer[0..cwd_len];
        const cwd = if (executor.getEnv("PWD")) |pwd| if (pwd.len != 0) pwd else physical_cwd else physical_cwd;
        history.current_cwd = physical_cwd;
        try terminal.reportCurrentDirectory(cwd, terminal_hostname);
        const title = try terminalTitlePath(allocator, cwd, executor.getEnv("HOME"));
        defer if (title.owned) allocator.free(title.text);
        try terminal.reportWindowTitle(title.text);
        var completion_context: InteractiveCompletionContext = .{ .executor = executor, .history = &history, .cache = &completion_cache, .loader = &completion_loader, .io = io, .cwd = cwd, .arg_zero = options.arg_zero, .features = options.features };
        const ui_theme = prompt_service.theme();
        const read_options: editor_driver.ReadLineOptions = .{
            .prompt = prompt,
            .editing_mode = interactiveEditingMode(semanticShellOptions(executor.shell_options)),
            .prompt_refresh_interval_ms = prompt_service.refreshIntervalMs(),
            .hook_context = &completion_context,
            .run_hooks = runInteractiveIntervalHooks,
            .next_hook_interval_ms = nextInteractiveIntervalMs,
            .prompt_context = &completion_context,
            .refresh_prompt = renderInteractivePrompt,
            .history = history_service.lineEditorView(io),
            .completion_context = &completion_context,
            .complete = completeInteractiveLine,
            .clone_completion_context = cloneInteractiveCompletionContext,
            .free_completion_context = freeInteractiveCompletionContext,
            .expand_abbreviation = expandInteractiveAbbreviation,
            .path_expansion_context = &completion_context,
            .expand_pathname = expandInteractivePathname,
            .vi_alias_context = executor,
            .lookup_vi_alias = lookupInteractiveViAlias,
            .external_editor_command = interactiveExternalEditorCommand(executor.*),
            .external_editor_tmpdir = interactiveExternalEditorTmpdir(executor.*),
            .diagnostic_context = &completion_context,
            .diagnose = diagnoseInteractiveLine,
            .theme = ui_theme,
            .style_context = &completion_context,
            .refresh_style = refreshInteractiveStyle,
            .refresh_color_report = refreshInteractiveColorReport,
        };
        const read_result = try terminal.readLine(read_options);
        try syncInteractiveTerminalSize(executor, terminal);
        if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const line = switch (read_result) {
            .submitted => |line| line,
            .canceled => {
                if (try runInteractiveInterruptTrap(io, executor, options.arg_zero, options.features)) |result| {
                    var trap_result = result;
                    defer trap_result.deinit();
                    try terminal.leaveEditorMode();
                    var editor_mode_left = true;
                    defer if (editor_mode_left) terminal.enterEditorMode() catch {};

                    try writeAll(io, .stdout, trap_result.stdout);
                    try writeAll(io, .stderr, trap_result.stderr);
                    if (outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
                    last_status = trap_result.status;
                    try terminal.finishSemanticCommand(trap_result.status);
                    if (executor.pending_exit) |status| {
                        last_status = status;
                        editor_mode_left = false;
                        break;
                    }

                    try terminal.enterEditorMode();
                    editor_mode_left = false;
                }
                continue;
            },
            .interrupted => {
                if (executor.pending_exit) |status| {
                    last_status = status;
                    break;
                }
                continue;
            },
            .eof => {
                if (!executor.shell_options.ignoreeof) break;
                try writeAll(io, .stderr, ignoreeof_message);
                continue;
            },
        };
        defer allocator.free(line);

        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(allocator);
        try command.appendSlice(allocator, line);

        while (try interactiveInputNeedsContinuation(allocator, command.items, options.features)) {
            var continuation_options = read_options;
            continuation_options.prompt = executor.getEnv("PS2") orelse "> ";
            continuation_options.prompt_refresh_interval_ms = null;
            continuation_options.prompt_context = null;
            continuation_options.refresh_prompt = null;
            continuation_options.diagnostic_context = null;
            continuation_options.diagnose = null;
            const continuation_read_result = try terminal.readLine(continuation_options);
            try syncInteractiveTerminalSize(executor, terminal);
            if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
            const continuation_line = switch (continuation_read_result) {
                .submitted => |continuation_line| continuation_line,
                .canceled => {
                    if (try runInteractiveInterruptTrap(io, executor, options.arg_zero, options.features)) |result| {
                        var trap_result = result;
                        defer trap_result.deinit();
                        try terminal.leaveEditorMode();
                        var editor_mode_left = true;
                        defer if (editor_mode_left) terminal.enterEditorMode() catch {};

                        try writeAll(io, .stdout, trap_result.stdout);
                        try writeAll(io, .stderr, trap_result.stderr);
                        if (outputNeedsNewlineMarker(trap_result.stdout, trap_result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
                        last_status = trap_result.status;
                        try terminal.finishSemanticCommand(trap_result.status);
                        if (executor.pending_exit) |status| {
                            last_status = status;
                            editor_mode_left = false;
                            break :repl_loop;
                        }

                        try terminal.enterEditorMode();
                        editor_mode_left = false;
                    }
                    continue :repl_loop;
                },
                .interrupted => {
                    if (executor.pending_exit) |status| {
                        last_status = status;
                        break :repl_loop;
                    }
                    continue :repl_loop;
                },
                .eof => {
                    try terminal.finishSemanticCommand(2);
                    last_status = 2;
                    continue :repl_loop;
                },
            };
            defer allocator.free(continuation_line);
            try command.append(allocator, '\n');
            try command.appendSlice(allocator, continuation_line);
        }

        const input = command.items;
        if (std.mem.eql(u8, input, "exit")) {
            if (executor.shouldWarnBeforeExitWithStoppedJobs()) {
                try terminal.finishSemanticCommand(0);
                try writeAll(io, .stderr, exec.stopped_jobs_exit_warning);
                continue;
            }
            try terminal.finishSemanticCommand(0);
            break;
        }
        if (input.len == 0) {
            try terminal.finishSemanticCommand(0);
            continue;
        }

        {
            try terminal.leaveEditorMode();
            var editor_mode_left = true;
            defer if (editor_mode_left) terminal.enterEditorMode() catch {};

            const command_started_at = unixTimestamp(io);
            const command_started = monotonicTimestamp(io);
            try prompt_service.runEventHooks(io, "preexec", &.{input});
            try interactive_shell.syncSemanticFromExecutor(io);
            var result = try runInteractiveScript(allocator, io, &interactive_shell, input, .{ .io = io, .allow_external = true, .features = options.features, .external_stdio = .inherit, .interactive = true, .arg_zero = options.arg_zero });
            const command_duration_ms = durationMillis(command_started, monotonicTimestamp(io));
            defer result.deinit();
            try writeAll(io, .stdout, result.stdout);
            try writeAll(io, .stderr, result.stderr);
            if (outputNeedsNewlineMarker(result.stdout, result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
            last_status = result.status;
            executor.setLastCommandDuration(command_duration_ms);
            if (!history_service.consumeSuppressNextAppend(executor)) try history_service.addCommand(io, input, result.status, command_started_at, command_duration_ms);
            var status_buffer: [3]u8 = undefined;
            const status_text = try std.fmt.bufPrint(&status_buffer, "{d}", .{result.status});
            try prompt_service.runEventHooks(io, "postexec", &.{ input, status_text });
            try interactive_shell.syncSemanticFromExecutor(io);
            try terminal.finishSemanticCommand(result.status);
            completion_cache.clear();
            if (executor.pending_exit) |status| {
                last_status = status;
                editor_mode_left = false;
                break;
            }

            try terminal.enterEditorMode();
            editor_mode_left = false;
        }
    }

    return last_status;
}

fn interactiveInputNeedsContinuation(allocator: std.mem.Allocator, source: []const u8, features: compat.Features) !bool {
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .features = features });
    defer parsed.deinit();
    if (parsed.incomplete) return true;
    var index = parsed.tokens.len;
    while (index > 0) {
        index -= 1;
        const kind = parsed.tokens[index].kind;
        if (kind == .eof or kind.isTrivia()) continue;
        return switch (kind) {
            .pipe, .and_if, .or_if => true,
            else => false,
        };
    }
    return false;
}

test "interactive incomplete input requests continuation until complete" {
    try std.testing.expect(try interactiveInputNeedsContinuation(std.testing.allocator, "echo \"abc", .{}));
    try std.testing.expect(!try interactiveInputNeedsContinuation(std.testing.allocator, "echo \"abc\"", .{}));
    try std.testing.expect(try interactiveInputNeedsContinuation(std.testing.allocator, "for i in 1 2", .{}));
    try std.testing.expect(!try interactiveInputNeedsContinuation(std.testing.allocator, "for i in 1 2\ndo echo $i\ndone", .{}));
    try std.testing.expect(try interactiveInputNeedsContinuation(std.testing.allocator, "echo one |", .{}));
    try std.testing.expect(!try interactiveInputNeedsContinuation(std.testing.allocator, "echo one | wc -c", .{}));
    try std.testing.expect(try interactiveInputNeedsContinuation(std.testing.allocator, "echo one &&", .{}));
    try std.testing.expect(!try interactiveInputNeedsContinuation(std.testing.allocator, "echo one && echo two", .{}));
    try std.testing.expect(try interactiveInputNeedsContinuation(std.testing.allocator, "cat <<EOF", .{}));
    try std.testing.expect(!try interactiveInputNeedsContinuation(std.testing.allocator, "cat <<EOF\nbody\nEOF", .{}));
}

fn interactiveEditingMode(options: shell.ShellOptions) line_editor.EditingMode {
    return if (options.vi) .vi else .emacs;
}

const TerminalTitlePath = struct {
    text: []const u8,
    owned: bool = false,
};

fn terminalTitlePath(allocator: std.mem.Allocator, path: []const u8, maybe_home: ?[]const u8) !TerminalTitlePath {
    const home = maybe_home orelse return .{ .text = path };
    if (home.len == 0) return .{ .text = path };
    if (std.mem.eql(u8, path, home)) return .{ .text = "~" };
    if (std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/') {
        return .{ .text = try std.mem.concat(allocator, u8, &.{ "~", path[home.len..] }), .owned = true };
    }
    return .{ .text = path };
}

fn syncInteractiveTerminalSize(executor: *exec.Executor, terminal: editor_driver.TerminalSession) !void {
    const winsize = terminal.currentWinsize();
    var rows_buffer: [32]u8 = undefined;
    var cols_buffer: [32]u8 = undefined;
    const rows = try std.fmt.bufPrint(&rows_buffer, "{d}", .{winsize.rows});
    const cols = try std.fmt.bufPrint(&cols_buffer, "{d}", .{winsize.cols});
    try executor.setEnv("LINES", rows);
    try executor.setExported("LINES");
    try executor.setEnv("COLUMNS", cols);
    try executor.setExported("COLUMNS");
}

fn syncSemanticTerminalSize(shell_state: *shell.ShellState, terminal: editor_driver.TerminalSession) !void {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    const winsize = terminal.currentWinsize();
    var rows_buffer: [32]u8 = undefined;
    var cols_buffer: [32]u8 = undefined;
    const rows = try std.fmt.bufPrint(&rows_buffer, "{d}", .{winsize.rows});
    const cols = try std.fmt.bufPrint(&cols_buffer, "{d}", .{winsize.cols});
    try shell_state.putVariable("LINES", rows, .{ .exported = true });
    try shell_state.putVariable("COLUMNS", cols, .{ .exported = true });
}

fn outputNeedsNewlineMarker(stdout: []const u8, stderr: []const u8) bool {
    const output = if (stderr.len != 0) stderr else stdout;
    if (output.len == 0) return false;
    return output[output.len - 1] != '\n';
}

fn runInteractiveInterruptTrap(io: std.Io, executor: *exec.Executor, arg_zero: []const u8, features: compat.Features) !?CommandResult {
    const result = (try executor.executeSignalTrap("INT", .{ .io = io, .allow_external = true, .features = features, .interactive = true, .arg_zero = arg_zero })) orelse return null;
    return commandResultFromExecutorResult(result);
}

pub fn runReplInput(allocator: std.mem.Allocator, io: std.Io, input: []const u8) !CommandResult {
    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var history = History.init(allocator);
    defer history.deinit();
    var history_service = InteractiveHistoryService.init(&history);
    var last_status: shell.ExitStatus = 0;
    var interactive_shell = InteractiveShell.init(allocator);
    defer interactive_shell.deinit();
    const executor = &interactive_shell.executor;
    history_service.attachFc(executor);
    const prompt_service: InteractivePromptService = .{ .executor = executor };
    {
        var result = try runScriptWithExecutor(allocator, executor, embedded_config, .{ .io = io, .allow_external = true, .arg_zero = "rush", .source_path = embedded_config_path });
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
    }
    {
        // Drop the embedded default rush_prompt so prompts fall back to PS1;
        // the default prompt depends on the cwd and Git state, which would
        // make REPL transcripts nondeterministic.
        var result = try runScriptWithExecutor(allocator, executor, "unset -f rush_prompt", .{ .io = io, .allow_external = true, .arg_zero = "rush" });
        defer result.deinit();
    }
    try interactive_shell.syncSemanticFromExecutor(io);

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (executor.pending_exit) |status| {
            last_status = status;
            break;
        }
        const notifications = try executor.drainJobNotifications();
        try stderr.appendSlice(allocator, notifications);
        allocator.free(notifications);
        const prompt = try prompt_service.render(allocator, io);
        try stdout.appendSlice(allocator, prompt);
        allocator.free(prompt);
        if (std.mem.eql(u8, line, "exit")) break;
        if (line.len == 0) continue;

        const command_started_at = unixTimestamp(io);
        var result = try runInteractiveScript(allocator, io, &interactive_shell, line, .{ .io = io, .allow_external = true, .interactive = true, .arg_zero = "rush" });
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
        last_status = result.status;
        if (!history_service.consumeSuppressNextAppend(executor)) try history_service.addCommand(io, line, result.status, command_started_at, 0);
        if (executor.pending_exit) |status| {
            last_status = status;
            break;
        }
    }

    return .{
        .allocator = allocator,
        .status = last_status,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
    };
}

pub fn runScript(allocator: std.mem.Allocator, io: std.Io, script: []const u8) !CommandResult {
    return runScriptWithOptions(allocator, io, script, .{ .io = io, .allow_external = true });
}

pub fn runScriptWithOptions(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: exec.ExecuteOptions) !CommandResult {
    return runScriptWithEnvironment(allocator, io, script, options, null);
}

pub fn runScriptWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: exec.ExecuteOptions, environ_map: ?*const std.process.Environ.Map) !CommandResult {
    return runCommandStringWithEnvironment(allocator, io, script, options, environ_map, &.{}, null, .{});
}

fn runShellInvocationWithEnvironment(allocator: std.mem.Allocator, io: std.Io, invocation: ShellInvocation, environ_map: ?*const std.process.Environ.Map, external_stdio: runtime.ExternalStdio, login_shell: bool) !CommandResult {
    var owned_script: ?[]const u8 = null;
    defer if (owned_script) |script| allocator.free(script);

    var options: exec.ExecuteOptions = .{
        .io = io,
        .allow_external = true,
        .features = invocation.features,
        .external_stdio = external_stdio,
        .arg_zero = invocation.arg_zero,
    };
    if (invocation.kind == .command_string) options.verbose_input_echo = false;
    const script = switch (invocation.kind) {
        .command_string => invocation.source,
        .script_file => script: {
            owned_script = try std.Io.Dir.cwd().readFileAlloc(io, invocation.source, allocator, .unlimited);
            options.source_path = invocation.source;
            break :script owned_script.?;
        },
        .standard_input => script: {
            owned_script = try readStandardInputScript(allocator, io);
            options.stdin_script_file = std.Io.File.stdin();
            break :script owned_script.?;
        },
    };
    const interactive_options: ?InteractiveOptions = if (invocation.interactive) .{ .arg_zero = invocation.arg_zero, .login = login_shell, .monitor_option_explicit = invocation.monitor_option_explicit } else null;
    return runCommandStringWithEnvironment(allocator, io, script, options, environ_map, invocation.positionals, interactive_options, invocation.shell_options);
}

const StdinGuard = struct {
    saved_fd: c_int,

    fn replaceWith(file: std.Io.File) !StdinGuard {
        const saved_fd = dup(std.Io.File.stdin().handle);
        if (saved_fd < 0) return error.SkipZigTest;
        errdefer _ = close(saved_fd);
        if (dup2(file.handle, std.Io.File.stdin().handle) < 0) return error.SkipZigTest;
        return .{ .saved_fd = saved_fd };
    }

    fn restore(self: *StdinGuard) void {
        _ = dup2(self.saved_fd, std.Io.File.stdin().handle);
        _ = close(self.saved_fd);
        self.* = undefined;
    }
};

const StderrGuard = struct {
    saved_fd: c_int,

    fn replaceWith(file: std.Io.File) !StderrGuard {
        const saved_fd = dup(std.Io.File.stderr().handle);
        if (saved_fd < 0) return error.SkipZigTest;
        errdefer _ = close(saved_fd);
        if (dup2(file.handle, std.Io.File.stderr().handle) < 0) return error.SkipZigTest;
        return .{ .saved_fd = saved_fd };
    }

    fn restore(self: *StderrGuard) void {
        _ = dup2(self.saved_fd, std.Io.File.stderr().handle);
        _ = close(self.saved_fd);
        self.* = undefined;
    }
};

fn runInvocationWithPipeStdin(invocation: ShellInvocation, stdin: []const u8) !CommandResult {
    var pipe = try editor_driver.makePipe(std.testing.io);
    defer pipe.read.close(std.testing.io);
    var write_open = true;
    defer if (write_open) pipe.write.close(std.testing.io);

    try writeFileAll(pipe.write, stdin);
    pipe.write.close(std.testing.io);
    write_open = false;

    var guard = try StdinGuard.replaceWith(pipe.read);
    defer guard.restore();
    return runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
}

fn runInvocationWithFileStdin(invocation: ShellInvocation, path: []const u8) !CommandResult {
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var guard = try StdinGuard.replaceWith(file);
    defer guard.restore();
    return runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
}

fn writeFileAll(file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readStandardInputScript(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

fn shouldRunInteractiveStandardInput(invocation: ShellInvocation, stdin_is_tty: bool, stderr_is_tty: bool) bool {
    if (invocation.kind != .standard_input) return false;
    if (!stdin_is_tty) return false;
    return invocation.interactive or stderr_is_tty;
}

fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

fn stderrIsTty(io: std.Io) bool {
    return std.Io.File.stderr().isTty(io) catch false;
}

fn runCommandStringWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: exec.ExecuteOptions, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, interactive_options: ?InteractiveOptions, shell_options: shell.ShellOptions) !CommandResult {
    const semantic_invocation = semanticInvocationFromExecuteOptions(options);
    if (shouldUseSemanticNonInteractiveExecutor(semantic_invocation, options.allow_external, interactive_options)) {
        var semantic_execution = try runSemanticCommandString(allocator, io, script, semantic_invocation, options.external_stdio, environ_map, positionals, shell_options);
        switch (semantic_execution) {
            .output => |output| {
                semantic_execution = undefined;
                return output;
            },
            .unsupported => |message| {
                semantic_execution = undefined;
                defer allocator.free(message);
                return unsupportedSemanticCommandResult(allocator, message);
            },
        }
    }

    return runOldCommandStringWithEnvironment(allocator, io, script, options, environ_map, positionals, interactive_options, shell_options);
}

fn runOldCommandStringWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: exec.ExecuteOptions, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, interactive_options: ?InteractiveOptions, shell_options: shell.ShellOptions) !CommandResult {
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    if (environ_map) |map| try executor.importEnvironment(map);
    try executor.initializeShellVariables(io);
    executor.arg_zero = options.arg_zero;
    var startup_shell_options = shell_options;
    if (interactive_options) |startup_options| setInteractiveStartupShellOptions(&startup_shell_options, startup_options.monitor_option_explicit, stdinIsTty(io));
    executor.shell_options = legacyShellOptions(startup_shell_options, .{});
    if (positionals.len != 0) try executor.global_positionals.set(allocator, positionals);
    if (interactive_options) |startup_options| {
        try loadInteractiveConfig(allocator, io, &executor, startup_options);
        if (executor.pending_exit) |status| return emptyCommandResult(allocator, status);
    }

    return runScriptWithExecutor(allocator, &executor, script, options);
}

fn shouldUseSemanticNonInteractiveExecutor(invocation: shell.InvocationContext, allow_external: bool, interactive_options: ?InteractiveOptions) bool {
    invocation.validate();
    return interactive_options == null and !invocation.interactive and allow_external;
}

const SemanticInvocationExecution = union(enum) {
    output: CommandResult,
    unsupported: []const u8,

    fn deinit(self: *SemanticInvocationExecution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .output => |*output| output.deinit(),
            .unsupported => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

fn runSemanticCommandString(allocator: std.mem.Allocator, io: std.Io, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !SemanticInvocationExecution {
    assertSemanticStartupOptions(script, invocation, positionals);

    if (shell_options.noexec or shell_options.verbose or shell_options.xtrace) return semanticUnsupported(allocator, "semantic executor does not yet implement non-interactive noexec/verbose/xtrace startup modes");
    if (environ_map) |map| if (!semanticEnvironmentSupported(map)) return semanticUnsupported(allocator, "semantic ShellState cannot yet preserve non-shell environment names");

    if (semanticScriptNeedsAliasTiming(script)) {
        return runSemanticAliasTimingCommandString(allocator, io, script, invocation, external_stdio, environ_map, positionals, shell_options);
    }

    var parsed = try parser.parse(allocator, script, .{ .features = invocation.features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) {
        return .{ .output = try parseDiagnosticsResult(allocator, script, parsed.diagnostics) };
    }

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features, false)) |message| return semanticUnsupported(allocator, message);

    var shell_state = shell.ShellState.init(allocator);
    defer shell_state.deinit();
    try initializeSemanticInvocationState(allocator, io, &shell_state, environ_map, positionals, shell_options);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(allocator, script, program, &evaluator, &shell_state, eval_context, resolver, invocation.stdin_script_file, invocation.stdin_script_source_offset, true);
}

fn runSemanticAliasTimingCommandString(allocator: std.mem.Allocator, io: std.Io, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !SemanticInvocationExecution {
    var shell_state = shell.ShellState.init(allocator);
    defer shell_state.deinit();
    try initializeSemanticInvocationState(allocator, io, &shell_state, environ_map, positionals, shell_options);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.io = io;
    evaluator.read_stdin_from_fd = true;
    evaluator.external_stdio = external_stdio;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    var stdout: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(allocator);
    var status: shell.ExitStatus = 0;
    var start = skipSemanticChunkSeparators(script, 0);
    while (start < script.len) {
        var end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, start));
        while (true) {
            const source = std.mem.trim(u8, script[start..end], " \t\r\n;");
            if (source.len == 0) break;
            const aliased = try semanticExpandAliases(allocator, source, invocation.features, &shell_state);
            defer allocator.free(aliased);
            var parsed = try parser.parse(allocator, aliased, .{ .features = invocation.features.withStrictDiagnostics() });
            defer parsed.deinit();
            if (parsed.diagnostics.len == 0) {
                var program = try ir.lowerSimpleCommands(allocator, parsed);
                defer program.deinit();
                var alias_snapshot = shell_state.clone(allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ReadonlyVariable => unreachable,
                };
                defer alias_snapshot.deinit();
                parser_resolver.alias_state = &alias_snapshot;
                var execution = try runSemanticLoweredProgram(allocator, aliased, program, &evaluator, &shell_state, eval_context, resolver, invocation.stdin_script_file, invocation.stdin_script_source_offset, false);
                defer execution.deinit(allocator);
                switch (execution) {
                    .unsupported => |message| return semanticUnsupported(allocator, message),
                    .output => |output| {
                        try stdout.appendSlice(allocator, output.stdout);
                        try stderr.appendSlice(allocator, output.stderr);
                        status = output.status;
                    },
                }
                parser_resolver.alias_state = null;
                break;
            }
            if (!parsed.incomplete or end >= script.len) return .{ .output = try parseDiagnosticsResult(allocator, source, parsed.diagnostics) };
            end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, end));
        }
        start = skipSemanticChunkSeparators(script, end);
    }

    try appendSemanticExitTrap(allocator, &stdout, &stderr, &status, &evaluator, &shell_state, eval_context, resolver);
    return .{ .output = .{ .allocator = allocator, .status = status, .stdout = try stdout.toOwnedSlice(allocator), .stderr = try stderr.toOwnedSlice(allocator) } };
}

fn runInteractiveScript(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *InteractiveShell, script: []const u8, options: exec.ExecuteOptions) !CommandResult {
    std.debug.assert(options.interactive);
    std.debug.assert(interactive_shell.executor.execution_depth == 0);
    if (interactive_shell.semantic_enabled) {
        var semantic_execution = try runSemanticInteractiveCommandString(allocator, io, interactive_shell, script, semanticInvocationFromExecuteOptions(options), options.external_stdio);
        switch (semantic_execution) {
            .output => |output| {
                semantic_execution = undefined;
                std.debug.assert(interactive_shell.executor.pending_exit == null);
                try interactive_shell.syncExecutorFromSemantic();
                return output;
            },
            .unsupported => |message| {
                semantic_execution = undefined;
                allocator.free(message);
            },
        }
    }

    const result = try runScriptWithExecutor(allocator, &interactive_shell.executor, script, options);
    try interactive_shell.syncSemanticFromExecutor(io);
    return result;
}

fn runSemanticInteractiveCommandString(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *InteractiveShell, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    assertSemanticInteractiveOptions(script, invocation);

    const executor = &interactive_shell.executor;
    const shell_state = &interactive_shell.semantic_state;
    std.debug.assert(interactive_shell.semantic_enabled);
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (external_stdio != .inherit and external_stdio != .capture) return semanticUnsupported(allocator, "semantic interactive executor requires inherited or captured stdio");
    if (invocation.stdin_script_file != null) return semanticUnsupported(allocator, "semantic interactive executor does not consume script stdin files");
    if (executor.pending_exit != null) return semanticUnsupported(allocator, "semantic interactive executor does not run while an exit is pending");
    if (shell_state.options.verbose or shell_state.options.xtrace or shell_state.options.errexit) return semanticUnsupported(allocator, "semantic interactive executor does not yet preserve verbose/xtrace/errexit state");

    var parsed = try parser.parse(allocator, script, .{ .mode = .interactive, .features = invocation.features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return semanticUnsupported(allocator, "semantic interactive parser diagnostics are not handled by this path yet");

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features, true)) |message| return semanticUnsupported(allocator, message);
    if (semanticInteractiveProgramUnsupported(executor.*, shell_state.*, program)) |message| return semanticUnsupported(allocator, message);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    parser_resolver.features = invocation.features;
    parser_resolver.arg_zero = invocation.arg_zero;
    const resolver = parser_resolver.resolver();
    const eval_context = invocation.evalContext(.current_shell);

    return runSemanticLoweredProgram(allocator, script, program, &evaluator, shell_state, eval_context, resolver, null, 0, false);
}

fn runSemanticLoweredProgram(allocator: std.mem.Allocator, script: []const u8, program: ir.Program, evaluator: *shell.eval.Evaluator, shell_state: *shell.ShellState, eval_context: shell.EvalContext, resolver: shell.TrapActionResolver, stdin_script_file: ?std.Io.File, stdin_script_source_offset: usize, run_exit_trap: bool) !SemanticInvocationExecution {
    eval_context.validate();
    shell_state.validate();
    if (stdin_script_file == null) std.debug.assert(stdin_script_source_offset == 0);

    var accumulated_stdout: std.ArrayList(u8) = .empty;
    errdefer accumulated_stdout.deinit(allocator);
    var accumulated_stderr: std.ArrayList(u8) = .empty;
    errdefer accumulated_stderr.deinit(allocator);
    var release_accumulated = false;
    defer if (!release_accumulated) {
        accumulated_stdout.deinit(allocator);
        accumulated_stderr.deinit(allocator);
    };

    var status: shell.ExitStatus = 0;
    var control_flow: shell.ControlFlow = .normal;
    for (program.statements, 0..) |statement, statement_index| {
        std.debug.assert(statement.span.start <= statement.span.end);
        std.debug.assert(statement.span.end <= script.len);
        if (semanticStdinScriptConsumedStatement(stdin_script_file, stdin_script_source_offset, statement.span.start)) continue;

        const should_run = if (statement_index == 0) blk: {
            std.debug.assert(statement.op_before == .sequence);
            break :blk true;
        } else switch (statement.op_before) {
            .sequence => true,
            .and_if => status == 0,
            .or_if => status != 0,
        };
        if (!should_run) continue;

        const statement_end = semanticStatementSourceEnd(program, statement_index, script.len);
        const statement_script = std.mem.trim(u8, script[statement.span.start..statement_end], " \t\r\n;");
        std.debug.assert(statement_script.len != 0);
        syncSemanticStdinScriptOffset(stdin_script_file, stdin_script_source_offset, script, statement_end);
        var body = (try resolver.resolve(allocator, statement_script, .TERM, eval_context, shell_state)) orelse return semanticUnsupported(allocator, "semantic parser lowering returned no body");
        defer body.deinit();

        if (semanticBodyUnsupportedMessage(body, eval_context.interactive)) |message| return semanticUnsupported(allocator, message);
        const body_failed = semanticBodyIsFailure(body);

        var command_outcome = if (statement.async_after) blk: {
            var background_plan = (try semanticBackgroundPipelinePlan(allocator, body)) orelse return semanticUnsupported(allocator, "semantic executor production preflight keeps unsupported background statements outside the switched slice");
            defer background_plan.deinit(allocator);
            break :blk shell.eval.evaluatePipelinePlan(evaluator, shell_state, eval_context, background_plan.plan) catch |err| switch (err) {
                error.Unimplemented => return semanticUnsupported(allocator, "semantic evaluator reported an unimplemented background command shape"),
                else => |e| return e,
            };
        } else evaluateSemanticComparisonBody(evaluator, shell_state, eval_context, body) catch |err| switch (err) {
            error.Unimplemented => return semanticUnsupported(allocator, "semantic evaluator reported an unimplemented command shape"),
            else => |e| return e,
        };
        defer command_outcome.deinit();

        command_outcome.validateForContext(eval_context);
        try accumulated_stdout.appendSlice(allocator, command_outcome.stdout.items);
        try accumulated_stderr.appendSlice(allocator, command_outcome.stderr.items);
        status = command_outcome.status;
        control_flow = command_outcome.control_flow;

        const outcome_target = command_outcome.state_delta.target;
        if (outcome_target.allowsShellStateCommit() and shell_state.acceptsExecutionTarget(outcome_target)) {
            try command_outcome.commitDelta(shell_state, outcome_target);
        } else {
            std.debug.assert(outcome_target.isIsolatedFromParent());
            command_outcome.discardDelta(outcome_target);
            shell_state.last_status = status;
        }
        shell_state.validate();
        if (control_flow != .normal or body_failed) break;
    }

    control_flow.validate();
    var final_status = control_flow.status(status);
    if (run_exit_trap) try appendSemanticExitTrap(allocator, &accumulated_stdout, &accumulated_stderr, &final_status, evaluator, shell_state, eval_context, resolver);
    const stdout = try accumulated_stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try accumulated_stderr.toOwnedSlice(allocator);
    release_accumulated = true;
    return .{ .output = .{
        .allocator = allocator,
        .status = final_status,
        .stdout = stdout,
        .stderr = stderr,
    } };
}

const SemanticBackgroundPipelinePlan = struct {
    plan: shell.PipelinePlan,
    allocated_stages: []shell.PipelineStagePlan = &.{},

    fn deinit(self: *SemanticBackgroundPipelinePlan, allocator: std.mem.Allocator) void {
        if (self.allocated_stages.len != 0) allocator.free(self.allocated_stages);
        self.* = undefined;
    }
};

fn semanticBackgroundPipelinePlan(allocator: std.mem.Allocator, body: shell.TrapActionBody) !?SemanticBackgroundPipelinePlan {
    body.validate();
    return switch (body) {
        .simple => |plan| try semanticBackgroundSingleStagePlan(allocator, plan),
        .pipeline => |plan| semanticBackgroundPipelineFromPipeline(plan),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| try semanticBackgroundSingleStagePlan(allocator, plan),
            .pipeline => |plan| semanticBackgroundPipelineFromPipeline(plan),
            .compound, .failure => null,
        },
        .compound, .failure => null,
    };
}

fn semanticBackgroundSingleStagePlan(allocator: std.mem.Allocator, plan: shell.CommandPlan) !SemanticBackgroundPipelinePlan {
    plan.validate();
    const stages = try allocator.alloc(shell.PipelineStagePlan, 1);
    errdefer allocator.free(stages);
    stages[0] = .{ .simple = plan };
    return .{
        .plan = shell.PipelinePlan.init(stages, .{ .background = .background }),
        .allocated_stages = stages,
    };
}

fn semanticBackgroundPipelineFromPipeline(plan: shell.PipelinePlan) SemanticBackgroundPipelinePlan {
    plan.validate();
    return .{ .plan = shell.PipelinePlan.init(plan.stages, .{
        .negated = plan.negated,
        .status_rule = plan.status_rule,
        .background = .background,
    }) };
}

fn appendSemanticExitTrap(allocator: std.mem.Allocator, stdout: *std.ArrayList(u8), stderr: *std.ArrayList(u8), status: *shell.ExitStatus, evaluator: *shell.eval.Evaluator, shell_state: *shell.ShellState, eval_context: shell.EvalContext, resolver: shell.TrapActionResolver) !void {
    if (shell_state.getTrapForSignal(.EXIT) == null) return;
    shell_state.last_status = status.*;
    try shell_state.appendPendingTrap(.EXIT);
    var trap_outcome = (try shell.eval.executePendingTraps(evaluator, shell_state, eval_context, resolver)) orelse return;
    defer trap_outcome.deinit();
    try stdout.appendSlice(allocator, trap_outcome.stdout.items);
    try stderr.appendSlice(allocator, trap_outcome.stderr.items);
    status.* = trap_outcome.status;
    try trap_outcome.commitDelta(shell_state, trap_outcome.state_delta.target);
}

fn semanticScriptNeedsAliasTiming(script: []const u8) bool {
    var index: usize = 0;
    while (index < script.len) {
        while (index < script.len and !isSemanticAliasTokenByte(script[index])) index += 1;
        const start = index;
        while (index < script.len and isSemanticAliasTokenByte(script[index])) index += 1;
        const word = script[start..index];
        if (std.mem.eql(u8, word, "alias") or std.mem.eql(u8, word, "unalias") or std.mem.eql(u8, word, "eval") or std.mem.eql(u8, word, ".")) return true;
    }
    return false;
}

fn isSemanticAliasTokenByte(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '_';
}

fn skipSemanticChunkSeparators(script: []const u8, start: usize) usize {
    var index = start;
    while (index < script.len and (script[index] == ' ' or script[index] == '\t' or script[index] == '\r' or script[index] == '\n' or script[index] == ';')) index += 1;
    return index;
}

fn semanticLineEnd(script: []const u8, start: usize) usize {
    var index = start;
    while (index < script.len and script[index] != '\n') index += 1;
    if (index < script.len) index += 1;
    return index;
}

fn extendSemanticHereDocChunk(script: []const u8, start: usize, initial_end: usize) usize {
    var end = initial_end;
    var scan = start;
    while (scan + 1 < end) : (scan += 1) {
        if (script[scan] != '<' or script[scan + 1] != '<') continue;
        var delimiter_start = scan + 2;
        if (delimiter_start < end and script[delimiter_start] == '-') delimiter_start += 1;
        while (delimiter_start < end and (script[delimiter_start] == ' ' or script[delimiter_start] == '\t')) delimiter_start += 1;
        var delimiter_end = delimiter_start;
        while (delimiter_end < end and !isSemanticHereDocDelimiterTerminator(script[delimiter_end])) delimiter_end += 1;
        const raw_delimiter = std.mem.trim(u8, script[delimiter_start..delimiter_end], "'\"");
        if (raw_delimiter.len == 0) continue;
        end = semanticHereDocBodyEnd(script, end, raw_delimiter);
    }
    return end;
}

fn isSemanticHereDocDelimiterTerminator(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n' or byte == ';' or byte == '|' or byte == '&' or byte == '<' or byte == '>';
}

fn semanticHereDocBodyEnd(script: []const u8, body_start: usize, delimiter: []const u8) usize {
    var line_start = body_start;
    while (line_start < script.len) {
        var line_end = line_start;
        while (line_end < script.len and script[line_end] != '\n') line_end += 1;
        const raw_line = script[line_start..line_end];
        const line = if (raw_line.len != 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.eql(u8, line, delimiter)) return if (line_end < script.len) line_end + 1 else line_end;
        line_start = if (line_end < script.len) line_end + 1 else line_end;
    }
    return script.len;
}

fn semanticExpandAliases(allocator: std.mem.Allocator, source: []const u8, features: compat.Features, shell_state: *shell.ShellState) ![]const u8 {
    return parser.expandAliases(allocator, source, .{
        .features = features.withStrictDiagnostics(),
        .context = shell_state,
        .lookup = lookupSemanticAlias,
    });
}

fn lookupSemanticAlias(opaque_context: *anyopaque, name: []const u8) ?[]const u8 {
    if (!isSemanticAliasName(name)) return null;
    const shell_state: *shell.ShellState = @ptrCast(@alignCast(opaque_context));
    const alias = shell_state.getAlias(name) orelse return null;
    return alias.value;
}

fn isSemanticAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or std.ascii.isDigit(byte) or byte == '!' or byte == '%' or byte == ',' or byte == '-' or byte == '@' or byte == '_')) return false;
    }
    return true;
}

fn syncSemanticStdinScriptOffset(file: ?std.Io.File, source_offset: usize, script: []const u8, offset: usize) void {
    const stdin_file = file orelse return;
    var adjusted_offset = source_offset + offset;
    if (offset < script.len and script[offset] == '\n') adjusted_offset += 1;
    const seek_offset: std.c.off_t = @intCast(adjusted_offset);
    _ = std.c.lseek(stdin_file.handle, seek_offset, std.c.SEEK.SET);
}

fn semanticStdinScriptConsumedStatement(file: ?std.Io.File, source_offset: usize, statement_start: usize) bool {
    const stdin_file = file orelse return false;
    const current = std.c.lseek(stdin_file.handle, 0, std.c.SEEK.CUR);
    if (current < 0) return false;
    return @as(u64, @intCast(current)) > source_offset + statement_start;
}

fn semanticStatementSourceEnd(program: ir.Program, statement_index: usize, script_len: usize) usize {
    std.debug.assert(statement_index < program.statements.len);
    const statement = program.statements[statement_index];
    if (!semanticStatementHasHereDoc(program, statement)) return statement.span.end;
    if (statement_index + 1 < program.statements.len) return program.statements[statement_index + 1].span.start;
    return script_len;
}

fn semanticStatementHasHereDoc(program: ir.Program, statement: ir.Statement) bool {
    switch (statement.kind) {
        .pipeline => {
            const pipeline = program.pipelines[statement.index];
            for (pipeline.command_indexes) |command_index| {
                if (semanticCommandHasHereDoc(program.commands[command_index])) return true;
            }
            return false;
        },
        .if_command => return semanticRedirectionsHaveHereDoc(program.if_commands[statement.index].redirections),
        .loop_command => return semanticRedirectionsHaveHereDoc(program.loop_commands[statement.index].redirections),
        .for_command => return semanticRedirectionsHaveHereDoc(program.for_commands[statement.index].redirections),
        .case_command => return semanticRedirectionsHaveHereDoc(program.case_commands[statement.index].redirections),
        .function_definition => return semanticRedirectionsHaveHereDoc(program.function_definitions[statement.index].redirections),
        .brace_group => return semanticRedirectionsHaveHereDoc(program.brace_groups[statement.index].redirections),
        .subshell => return semanticRedirectionsHaveHereDoc(program.subshells[statement.index].redirections),
        .bash_test_command => return false,
    }
}

fn semanticCommandHasHereDoc(command: ir.SimpleCommand) bool {
    return semanticRedirectionsHaveHereDoc(command.redirections);
}

fn semanticRedirectionsHaveHereDoc(redirections: []const ir.Redirection) bool {
    for (redirections) |redirection| if (redirection.here_doc != null) return true;
    return false;
}

fn assertSemanticInteractiveOptions(script: []const u8, invocation: shell.InvocationContext) void {
    invocation.validate();
    std.debug.assert(invocation.interactive);
    std.debug.assert(invocation.arg_zero.len != 0);
    std.debug.assert(script.len == 0 or std.mem.indexOfScalar(u8, script, 0) == null);
}

fn assertSemanticStartupOptions(script: []const u8, invocation: shell.InvocationContext, positionals: []const []const u8) void {
    invocation.validate();
    std.debug.assert(!invocation.interactive);
    std.debug.assert(invocation.arg_zero.len != 0);
    std.debug.assert(script.len == 0 or std.mem.indexOfScalar(u8, script, 0) == null);
    for (positionals) |arg| std.debug.assert(std.mem.indexOfScalar(u8, arg, 0) == null);
}

fn semanticInvocationFromExecuteOptions(options: exec.ExecuteOptions) shell.InvocationContext {
    return shell.InvocationContext.init(.{
        .features = options.features,
        .arg_zero = options.arg_zero,
        .source = semanticInputSourceFromExecuteOptions(options),
        .interactive = options.interactive,
        .stdin_script_file = options.stdin_script_file,
        .stdin_script_source_offset = options.stdin_script_source_offset,
    });
}

fn semanticInputSourceFromExecuteOptions(options: exec.ExecuteOptions) shell.InputSource {
    if (options.source_path != null) return .script_file;
    if (options.stdin_script_file != null) return .standard_input;
    return .command_string;
}

fn semanticUnsupported(allocator: std.mem.Allocator, message: []const u8) !SemanticInvocationExecution {
    std.debug.assert(message.len != 0);
    return .{ .unsupported = try allocator.dupe(u8, message) };
}

fn unsupportedSemanticCommandResult(allocator: std.mem.Allocator, message: []const u8) !CommandResult {
    std.debug.assert(message.len != 0);
    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try std.fmt.allocPrint(allocator, "{s}\n", .{message});
    return .{ .allocator = allocator, .status = 2, .stdout = stdout, .stderr = stderr };
}

fn semanticEnvironmentSupported(environ_map: *const std.process.Environ.Map) bool {
    var iterator = environ_map.iterator();
    while (iterator.next()) |entry| {
        if (!isValidShellVariableName(entry.key_ptr.*)) return false;
        if (std.mem.indexOfScalar(u8, entry.value_ptr.*, 0) != null) return false;
    }
    return true;
}

fn semanticInteractiveProgramUnsupported(executor: exec.Executor, shell_state: shell.ShellState, program: ir.Program) ?[]const u8 {
    shell_state.validate();
    if (program.function_definitions.len != 0) return "semantic interactive executor does not yet preserve function definitions";
    if (executor.aliases.count() != 0 or shell_state.aliases.count() != 0) return "semantic interactive executor does not yet preserve alias-aware parsing";
    if (executor.arrays.count() != 0 and semanticProgramUsesShellExpansion(program)) return "semantic interactive executor does not yet preserve array expansion";
    if (shell_state.options.nounset and semanticProgramUsesShellExpansion(program)) return "semantic interactive executor does not yet preserve nounset expansion diagnostics";

    for (program.commands) |command| {
        if (command.argv.len == 0) continue;
        const root = command.argv[0];
        if (!semanticInteractiveBuiltinRootAllowed(root.text)) return "semantic interactive executor keeps unsupported builtins and external commands on the legacy interactive bridge";
        if (executor.functions.count() != 0) {
            if (wordMayUseShellExpansion(root.raw)) return "semantic interactive executor does not yet preserve dynamic function lookup";
            if (executor.functions.contains(root.text)) return "semantic interactive executor does not yet preserve shell function calls";
        }
    }
    return null;
}

fn semanticInteractiveBuiltinRootAllowed(name: []const u8) bool {
    const definition = shell.builtin.lookup(name) orelse return false;
    if (definition.semantic_class == .unsupported) return false;
    if (definition.semantic_class == .job_control or definition.semantic_class == .control_flow) return false;
    if (std.mem.eql(u8, name, "alias") or std.mem.eql(u8, name, "unalias")) return false;
    if (std.mem.eql(u8, name, "local") or std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "unset")) return false;
    if (std.mem.eql(u8, name, "trap")) return false;
    return true;
}

fn semanticProgramUsesShellExpansion(program: ir.Program) bool {
    for (program.commands) |command| {
        for (command.argv) |word| if (wordMayUseShellExpansion(word.raw)) return true;
        for (command.assignments) |word| if (wordMayUseShellExpansion(word.raw)) return true;
        for (command.redirections) |redirection| {
            if (redirection.io_number) |word| if (wordMayUseShellExpansion(word.raw)) return true;
            if (redirection.target) |word| if (wordMayUseShellExpansion(word.raw)) return true;
            if (redirection.here_doc) |body| if (wordMayUseShellExpansion(body)) return true;
        }
    }
    return false;
}

fn wordMayUseShellExpansion(raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, raw, '$') != null or std.mem.indexOfScalar(u8, raw, '`') != null;
}

fn initializeSemanticInteractiveStateFromExecutor(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, executor: exec.Executor) !?[]const u8 {
    shell_state.validate();
    shell_state.options = semanticShellOptions(executor.shell_options);
    const status_text = executor.last_status_text[0..executor.last_status_text_len];
    shell_state.last_status = std.fmt.parseInt(shell.ExitStatus, status_text, 10) catch 0;
    shell_state.pending_exit = executor.pending_exit;

    var variables = executor.env.iterator();
    while (variables.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (!isValidShellVariableName(name)) continue;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return "semantic ShellState cannot preserve variables containing NUL bytes";
        try shell_state.putVariable(name, value, .{
            .exported = executor.exported.contains(name),
            .readonly = executor.readonly.contains(name),
        });
    }

    if (shell_state.getVariable("PWD")) |pwd| {
        if (isValidLogicalPwd(allocator, pwd.value)) {
            try shell_state.setLogicalCwd(pwd.value);
        } else {
            try setSemanticPhysicalPwd(allocator, io, shell_state);
        }
    } else {
        try setSemanticPhysicalPwd(allocator, io, shell_state);
    }

    try shell_state.replacePositionals(executor.global_positionals.params);
    shell_state.validate();
    return null;
}

fn syncExecutorFromSemanticInteractiveState(executor: *exec.Executor, shell_state: shell.ShellState) !void {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(executor.execution_depth == 0);

    var removals: std.ArrayList([]const u8) = .empty;
    defer removals.deinit(executor.allocator);
    var executor_variables = executor.env.iterator();
    while (executor_variables.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!isValidShellVariableName(name)) continue;
        if (shell_state.variables.contains(name)) continue;
        try removals.append(executor.allocator, name);
    }
    for (removals.items) |name| executor.unsetEnv(name);

    var semantic_variables = shell_state.variables.iterator();
    while (semantic_variables.next()) |entry| {
        const name = entry.key_ptr.*;
        const variable = entry.value_ptr.*;
        if (executor.getEnv(name)) |current| {
            if (!std.mem.eql(u8, current, variable.value)) try executor.setEnv(name, variable.value);
        } else {
            try executor.setEnv(name, variable.value);
        }
        if (variable.exported) try executor.setExported(name);
        if (variable.readonly) try executor.setReadonly(name);
    }

    executor.shell_options = legacyShellOptions(shell_state.options, executor.shell_options.shopt);
    try executor.global_positionals.set(executor.allocator, shell_state.positionals.items);
    executor.setLastStatus(shell_state.last_status);
    if (shell_state.pending_exit) |status| executor.pending_exit = status;
}

fn initializeSemanticInvocationState(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !void {
    shell_state.validate();
    shell_state.options = shell_options;

    if (environ_map) |map| {
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            if (!isValidShellVariableName(entry.key_ptr.*)) continue;
            if (std.mem.indexOfScalar(u8, entry.value_ptr.*, 0) != null) continue;
            try shell_state.putVariable(entry.key_ptr.*, entry.value_ptr.*, .{ .exported = true });
        }
    }

    try initializeSemanticShellLevel(shell_state);
    try shell_state.putVariable("IFS", " \t\n", .{});
    try shell_state.putVariable("OPTIND", "1", .{});

    var ppid_buffer: [32]u8 = undefined;
    const ppid = try std.fmt.bufPrint(&ppid_buffer, "{d}", .{std.posix.getppid()});
    try shell_state.putVariable("PPID", ppid, .{});

    if (shell_state.getVariable("PWD")) |pwd| {
        if (isValidLogicalPwd(allocator, pwd.value)) {
            try shell_state.setLogicalCwd(pwd.value);
        } else {
            try setSemanticPhysicalPwd(allocator, io, shell_state);
        }
    } else {
        try setSemanticPhysicalPwd(allocator, io, shell_state);
    }

    try shell_state.replacePositionals(positionals);
    shell_state.validate();
}

fn initializeSemanticInteractiveStartupState(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, environ_map: *const std.process.Environ.Map, positionals: []const []const u8, shell_options: shell.ShellOptions) !void {
    try initializeSemanticInvocationState(allocator, io, shell_state, environ_map, positionals, shell_options);
    shell_state.validate();
}

fn initializeSemanticShellLevel(shell_state: *shell.ShellState) !void {
    const inherited = if (shell_state.getVariable("SHLVL")) |variable| variable.value else null;
    const level = nextStartupShellLevel(inherited);
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{level});
    try shell_state.putVariable("SHLVL", text, .{ .exported = true });
}

fn setSemanticPhysicalPwd(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState) !void {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    try shell_state.putVariable("PWD", cwd, .{ .exported = true });
    try shell_state.setLogicalCwd(cwd);
}

fn nextStartupShellLevel(inherited: ?[]const u8) i64 {
    const level = if (inherited) |text| parseShellLevel(text) orelse return 1 else return 1;
    return std.math.add(i64, level, 1) catch 1;
}

fn parseShellLevel(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var index: usize = 0;
    if (text[0] == '+' or text[0] == '-') {
        if (text.len == 1) return null;
        index = 1;
    }
    while (index < text.len) : (index += 1) {
        if (!std.ascii.isDigit(text[index])) return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn isValidLogicalPwd(allocator: std.mem.Allocator, pwd: []const u8) bool {
    if (pwd.len == 0 or pwd[0] != '/') return false;
    var parts = std.mem.splitScalar(u8, pwd, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return sameExistingFile(allocator, pwd, ".") orelse false;
}

const FileIdentity = struct {
    device: u64,
    inode: u64,
};

fn sameExistingFile(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ?bool {
    const lhs = fileIdentity(allocator, left) orelse return null;
    const rhs = fileIdentity(allocator, right) orelse return null;
    return lhs.device == rhs.device and lhs.inode == rhs.inode;
}

fn fileIdentity(allocator: std.mem.Allocator, path: []const u8) ?FileIdentity {
    const path_z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(path_z);

    if (comptime build_options.os.tag == .linux) {
        var statx_result: std.os.linux.Statx = undefined;
        if (std.c.statx(std.c.AT.FDCWD, path_z.ptr, 0, std.os.linux.STATX.BASIC_STATS, &statx_result) != 0) return null;
        return .{
            .device = (@as(u64, statx_result.dev_major) << 32) | statx_result.dev_minor,
            .inode = statx_result.ino,
        };
    }

    var stat_result: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z.ptr, &stat_result, 0) != 0) return null;
    return .{
        .device = @intCast(stat_result.dev),
        .inode = @intCast(stat_result.ino),
    };
}

fn isValidShellVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn semanticPreflightUnsupported(allocator: std.mem.Allocator, program: ir.Program, features: compat.Features, legacy_fallback_gates: bool) !?[]const u8 {
    if (legacy_fallback_gates and (program.if_commands.len != 0 or program.loop_commands.len != 0 or program.for_commands.len != 0 or program.case_commands.len != 0 or program.brace_groups.len != 0 or program.subshells.len != 0)) {
        return "semantic executor production preflight keeps compound commands unsupported outside the switched slice";
    }
    for (program.statements, 0..) |statement, index| {
        if (semanticAsyncStatementPreflightUnsupported(program, statement, index)) |message| return message;
    }
    if (legacy_fallback_gates) {
        for (program.commands) |command| {
            if (command.assignments.len != 0 and command.argv.len != 0) return "semantic executor production preflight keeps assignment-bearing commands unsupported outside the switched slice";
            if (commandUsesUnsupportedSemanticBuiltin(command, false)) return "semantic executor preflight found an unsupported builtin";
            if (commandUsesUnsupportedProductionExpansion(command)) return "semantic executor production preflight found an expansion shape outside the switched slice";
            if (command.argv.len == 0 and command.redirections.len != 0) return "semantic executor does not yet support redirection-only commands";
            if (command.redirections.len != 0) return "semantic executor production preflight keeps redirections unsupported outside the switched slice";
        }
    }
    for (program.function_definitions) |definition| {
        if (try semanticFunctionDefinitionPreflightUnsupported(allocator, definition, features)) |message| return message;
    }
    if (program.bash_test_commands.len != 0) return "semantic executor does not yet lower bash [[ ]] commands";
    return null;
}

fn semanticFunctionDefinitionPreflightUnsupported(allocator: std.mem.Allocator, definition: ir.FunctionDefinition, features: compat.Features) !?[]const u8 {
    var parsed = try parser.parse(allocator, definition.body, .{ .features = features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return "semantic executor production preflight keeps parser-rejected function bodies on the old executor";

    var body_program = try ir.lowerSimpleCommands(allocator, parsed);
    defer body_program.deinit();
    return semanticFunctionBodyProgramUnsupported(allocator, body_program, features);
}

fn semanticFunctionBodyProgramUnsupported(allocator: std.mem.Allocator, program: ir.Program, features: compat.Features) !?[]const u8 {
    for (program.statements, 0..) |statement, index| {
        if (semanticAsyncStatementPreflightUnsupported(program, statement, index)) |message| return message;
        if (statement.kind == .function_definition and statement.op_before != .sequence) return "semantic executor production preflight keeps dynamically guarded function definitions on the old executor";
    }
    for (program.function_definitions) |definition| {
        if (try semanticFunctionDefinitionPreflightUnsupported(allocator, definition, features)) |message| return message;
    }
    if (program.bash_test_commands.len != 0) return "semantic executor does not yet lower bash [[ ]] commands";
    return null;
}

fn semanticProgramHasCompoundRedirections(program: ir.Program) bool {
    for (program.if_commands) |command| if (command.redirections.len != 0) return true;
    for (program.loop_commands) |command| if (command.redirections.len != 0) return true;
    for (program.for_commands) |command| if (command.redirections.len != 0) return true;
    for (program.case_commands) |command| if (command.redirections.len != 0) return true;
    for (program.brace_groups) |group| if (group.redirections.len != 0) return true;
    for (program.subshells) |subshell| if (subshell.redirections.len != 0) return true;
    return false;
}

fn semanticProgramHasLoopDependentExpansion(program: ir.Program) bool {
    for (program.for_commands) |command| {
        if (!command.use_positionals) {
            for (command.words) |word| if (wordUsesUnsupportedForWordExpansion(word.raw)) return true;
        }
    }
    for (program.loop_commands) |command| {
        if (std.mem.indexOfScalar(u8, command.condition, '$') != null) return true;
        if (std.mem.indexOfScalar(u8, command.body, '$') != null) return true;
    }
    return false;
}

fn wordUsesUnsupportedForWordExpansion(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "$(") != null or
        std.mem.indexOfScalar(u8, raw, '`') != null or
        std.mem.indexOf(u8, raw, "${") != null or
        std.mem.indexOf(u8, raw, "$((") != null;
}

fn semanticAsyncStatementPreflightUnsupported(program: ir.Program, statement: ir.Statement, index: usize) ?[]const u8 {
    std.debug.assert(index < program.statements.len);
    if (!statement.async_after) return null;
    if (statement.kind != .pipeline) return "semantic executor production preflight keeps non-pipeline background statements unsupported outside the switched slice";
    return null;
}

fn semanticPipelinePreflightUnsupported(program: ir.Program, pipeline: ir.Pipeline) ?[]const u8 {
    std.debug.assert(program.commands.len != 0 or pipeline.command_indexes.len == 0);
    if (pipeline.stage_spans.len == 0) {
        return "semantic executor production preflight keeps empty pipelines unsupported outside the switched slice";
    }
    if (pipeline.command_indexes.len > pipeline.stage_spans.len) return "semantic executor production preflight keeps malformed pipelines unsupported outside the switched slice";
    for (pipeline.stage_spans) |stage_span| {
        if (wordUsesUnsupportedProductionExpansion(stage_span.slice(program.source))) return "semantic executor production preflight found an expansion shape outside the switched slice";
    }
    for (pipeline.command_indexes) |command_index| std.debug.assert(command_index < program.commands.len);
    return null;
}

fn commandUsesUnsupportedSemanticBuiltin(command: ir.SimpleCommand, allow_interactive_declarations: bool) bool {
    if (command.argv.len == 0) return false;
    const name = command.argv[0].text;
    const definition = shell.builtin.lookup(name) orelse return false;
    return switch (definition.semantic_class) {
        .unsupported, .predicate, .shell_state, .job_control, .control_flow => true,
        .declaration => !allow_interactive_declarations,
        .no_op, .status_constant, .output => false,
    };
}

fn commandUsesUnsupportedProductionExpansion(command: ir.SimpleCommand) bool {
    for (command.argv) |word| {
        if (wordUsesUnsupportedProductionExpansion(word.raw)) return true;
    }
    for (command.assignments) |word| {
        if (wordUsesUnsupportedProductionExpansion(word.raw)) return true;
    }
    return false;
}

fn wordUsesUnsupportedProductionExpansion(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "$(") != null or
        std.mem.indexOfScalar(u8, raw, '`') != null or
        std.mem.indexOf(u8, raw, "${") != null or
        std.mem.indexOf(u8, raw, "$((") != null or
        std.mem.indexOf(u8, raw, "$@") != null or
        std.mem.indexOf(u8, raw, "$*") != null;
}

fn semanticBodyUnsupportedMessage(body: shell.TrapActionBody, legacy_fallback_gates: bool) ?[]const u8 {
    body.validate();
    return switch (body) {
        .simple => |plan| semanticCommandUnsupportedMessage(plan, legacy_fallback_gates),
        .compound => |plan| semanticCompoundUnsupportedMessage(plan, legacy_fallback_gates),
        .pipeline => |plan| semanticPipelineUnsupportedMessage(plan, legacy_fallback_gates),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| semanticCommandUnsupportedMessage(plan, legacy_fallback_gates),
            .compound => |plan| semanticCompoundUnsupportedMessage(plan, legacy_fallback_gates),
            .pipeline => |plan| semanticPipelineUnsupportedMessage(plan, legacy_fallback_gates),
            .failure => null,
        },
        .failure => null,
    };
}

fn semanticBodyIsFailure(body: shell.TrapActionBody) bool {
    body.validate();
    return switch (body) {
        .failure => true,
        .owned => |owned| owned.body == .failure,
        .simple, .compound, .pipeline => false,
    };
}

fn semanticPipelineUnsupportedMessage(plan: shell.PipelinePlan, legacy_fallback_gates: bool) ?[]const u8 {
    plan.validate();
    for (plan.stages) |stage| switch (stage) {
        .simple => |simple| if (semanticCommandUnsupportedMessage(simple, legacy_fallback_gates)) |message| return message,
        .compound => |compound| if (semanticCompoundUnsupportedMessage(compound, legacy_fallback_gates)) |message| return message,
    };
    return null;
}

fn semanticCompoundUnsupportedMessage(plan: shell.CompoundCommandPlan, legacy_fallback_gates: bool) ?[]const u8 {
    plan.validate();
    if (legacy_fallback_gates and (plan.redirections.steps.len != 0 or plan.redirections.rollback_steps.len != 0)) return "semantic executor production preflight keeps compound redirections unsupported outside the switched slice";
    switch (plan.body) {
        .sequence, .brace_group, .subshell => |list| return semanticCommandListUnsupportedMessage(list, legacy_fallback_gates),
        .and_or_list => |and_or| for (and_or.commands) |entry| {
            if (semanticCommandUnsupportedMessage(entry.command, legacy_fallback_gates)) |message| return message;
        },
        .negation => |negation| return semanticCommandListUnsupportedMessage(negation.body, legacy_fallback_gates),
        .if_clause => |if_plan| {
            for (if_plan.branches) |branch| {
                if (semanticCommandListUnsupportedMessage(branch.condition, legacy_fallback_gates)) |message| return message;
                if (semanticCommandListUnsupportedMessage(branch.body, legacy_fallback_gates)) |message| return message;
            }
            return semanticCommandListUnsupportedMessage(if_plan.else_body, legacy_fallback_gates);
        },
        .while_loop, .until_loop => |loop| {
            if (semanticCommandListUnsupportedMessage(loop.condition, legacy_fallback_gates)) |message| return message;
            return semanticCommandListUnsupportedMessage(loop.body, legacy_fallback_gates);
        },
        .for_loop => |for_plan| return semanticCommandListUnsupportedMessage(for_plan.body, legacy_fallback_gates),
        .case_clause => |case_plan| for (case_plan.arms) |arm| {
            if (semanticCommandListUnsupportedMessage(arm.body, legacy_fallback_gates)) |message| return message;
        },
    }
    return null;
}

fn semanticCommandListUnsupportedMessage(list: shell.StatementList, legacy_fallback_gates: bool) ?[]const u8 {
    list.validate();
    for (list.commands) |command| {
        if (semanticCommandUnsupportedMessage(command, legacy_fallback_gates)) |message| return message;
    }
    for (list.statements) |entry| {
        switch (entry.plan) {
            .simple => |plan| if (semanticCommandUnsupportedMessage(plan, legacy_fallback_gates)) |message| return message,
            .compound => |plan| if (semanticCompoundUnsupportedMessage(plan, legacy_fallback_gates)) |message| return message,
            .pipeline => |plan| if (semanticPipelineUnsupportedMessage(plan, legacy_fallback_gates)) |message| return message,
        }
    }
    return null;
}

fn semanticCommandUnsupportedMessage(plan: shell.CommandPlan, legacy_fallback_gates: bool) ?[]const u8 {
    plan.validate();
    if (legacy_fallback_gates and plan.assignments.len != 0 and plan.class() != .assignment_only) return "semantic executor production preflight keeps assignment-bearing commands unsupported outside the switched slice";
    if (legacy_fallback_gates and (plan.redirections.steps.len != 0 or plan.redirections.rollback_steps.len != 0)) return "semantic executor production preflight keeps redirections unsupported outside the switched slice";
    return switch (plan.classification) {
        .regular_builtin, .special_builtin => |definition| blk: {
            if (definition.semantic_class == .unsupported) break :blk "semantic evaluator does not yet implement this builtin";
            if (legacy_fallback_gates and std.mem.eql(u8, definition.name, "read")) break :blk "semantic evaluator does not yet connect read to non-interactive stdin";
            if (legacy_fallback_gates and (std.mem.eql(u8, definition.name, "alias") or std.mem.eql(u8, definition.name, "unalias"))) break :blk "semantic evaluator does not yet integrate alias expansion with production parsing";
            break :blk null;
        },
        .empty, .assignment_only => null,
        .function_definition => |definition| if (definition.source_body == null) "semantic evaluator does not yet receive owned production function definitions" else null,
        .function, .external, .not_found => null,
    };
}

fn emptyCommandResult(allocator: std.mem.Allocator, status: shell.ExitStatus) !CommandResult {
    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try allocator.alloc(u8, 0);
    return .{ .allocator = allocator, .status = status, .stdout = stdout, .stderr = stderr };
}

fn parseDiagnosticsResult(allocator: std.mem.Allocator, script: []const u8, diagnostics: []const parser.Diagnostic) !CommandResult {
    var stderr_buffer: std.ArrayList(u8) = .empty;
    defer stderr_buffer.deinit(allocator);

    for (diagnostics) |diagnostic| {
        const line = try std.fmt.allocPrint(allocator, "rush: {s}: {s}\n", .{
            @tagName(diagnostic.kind),
            diagnostic.message,
        });
        defer allocator.free(line);
        try stderr_buffer.appendSlice(allocator, line);
        try appendDiagnosticSource(allocator, &stderr_buffer, script, diagnostic.span);
    }

    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try stderr_buffer.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .status = 2, .stdout = stdout, .stderr = stderr };
}

fn appendDiagnosticSource(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, span: parser.Span) !void {
    const line_start = diagnosticLineStart(source, span.start);
    const line_end = diagnosticLineEnd(source, span.start);
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

fn diagnosticLineStart(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index > 0 and source[index - 1] != '\n') index -= 1;
    return index;
}

fn diagnosticLineEnd(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index < source.len and source[index] != '\n') index += 1;
    return index;
}

fn commandResultFromExecutorResult(result: exec.CommandResult) CommandResult {
    return .{
        .allocator = result.allocator,
        .status = result.status,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn runScriptWithExecutor(allocator: std.mem.Allocator, executor: *exec.Executor, script: []const u8, options: exec.ExecuteOptions) !CommandResult {
    _ = options.io;
    var execution_options = options;
    execution_options.top_level_parse_diagnostics = true;
    const result = executor.executeScriptSlice(script, execution_options) catch |err| {
        if (err != error.ParseError) return err;
        return scriptDiagnosticsResult(allocator, executor, script, execution_options);
    };
    return commandResultFromExecutorResult(result);
}
fn semanticShellOptions(options: exec.ShellOptions) shell.ShellOptions {
    return .{
        .allexport = options.allexport,
        .emacs = options.emacs,
        .errexit = options.errexit,
        .ignoreeof = options.ignoreeof,
        .monitor = options.monitor,
        .noclobber = options.noclobber,
        .noexec = options.noexec,
        .noglob = options.noglob,
        .notify = options.notify,
        .nounset = options.nounset,
        .pipefail = options.pipefail,
        .verbose = options.verbose,
        .vi = options.vi,
        .xtrace = options.xtrace,
    };
}

fn legacyShellOptions(options: shell.ShellOptions, shopt: exec.ShoptOptions) exec.ShellOptions {
    return .{
        .shopt = shopt,
        .pipefail = options.pipefail,
        .emacs = options.emacs,
        .ignoreeof = options.ignoreeof,
        .vi = options.vi,
        .monitor = options.monitor,
        .noglob = options.noglob,
        .noclobber = options.noclobber,
        .noexec = options.noexec,
        .notify = options.notify,
        .nounset = options.nounset,
        .errexit = options.errexit,
        .xtrace = options.xtrace,
        .verbose = options.verbose,
        .allexport = options.allexport,
    };
}

fn evaluateSemanticComparisonBody(evaluator: *shell.eval.Evaluator, shell_state: *shell.ShellState, eval_context: shell.EvalContext, body: shell.TrapActionBody) shell.eval.EvalError!shell.CommandOutcome {
    body.validate();
    eval_context.validate();
    return switch (body) {
        .simple => |plan| shell.eval.evaluatePlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
        .compound => |plan| shell.eval.evaluateCompoundPlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
        .pipeline => |plan| shell.eval.evaluatePipelinePlan(evaluator, shell_state, eval_context, plan),
        .owned => |owned| switch (owned.body) {
            .simple => |plan| shell.eval.evaluatePlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
            .compound => |plan| shell.eval.evaluateCompoundPlan(evaluator, shell_state, eval_context.withTarget(plan.target), plan),
            .pipeline => |plan| shell.eval.evaluatePipelinePlan(evaluator, shell_state, eval_context, plan),
            .failure => |failure| shell.eval.trapActionFailureOutcome(evaluator.allocator, eval_context, failure),
        },
        .failure => |failure| shell.eval.trapActionFailureOutcome(evaluator.allocator, eval_context, failure),
    };
}

fn scriptDiagnosticsResult(allocator: std.mem.Allocator, executor: *exec.Executor, script: []const u8, options: exec.ExecuteOptions) !CommandResult {
    const aliased = try executor.expandAliasesForScriptWithFeatures(script, options.features);
    defer allocator.free(aliased);
    var parsed = try parser.parse(allocator, aliased, .{ .features = options.features.withStrictDiagnostics() });
    defer parsed.deinit();

    if (parsed.diagnostics.len != 0) {
        return parseDiagnosticsResult(allocator, script, parsed.diagnostics);
    }
    return error.ParseError;
}

const InteractiveConfigService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    executor: ?*exec.Executor = null,
    interactive_shell: ?*InteractiveShell = null,
    arg_zero: []const u8 = "rush",

    fn init(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, arg_zero: []const u8) InteractiveConfigService {
        return .{ .allocator = allocator, .io = io, .executor = executor, .arg_zero = arg_zero };
    }

    fn initInteractive(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *InteractiveShell, arg_zero: []const u8) InteractiveConfigService {
        std.debug.assert(interactive_shell.semantic_enabled);
        interactive_shell.semantic_state.validate();
        return .{ .allocator = allocator, .io = io, .interactive_shell = interactive_shell, .arg_zero = arg_zero };
    }

    fn load(self: InteractiveConfigService, options: InteractiveOptions) !void {
        try self.sourceScript(embedded_config, embedded_config_path);
        if (self.pendingExit() != null) return;

        if (self.getEnv("ENV")) |env_path| {
            if (env_path.len != 0) {
                const expanded_env_path = try self.expandParametersScalar(env_path, options.features);
                defer self.allocator.free(expanded_env_path);
                if (expanded_env_path.len != 0) {
                    try self.sourceOptional(expanded_env_path);
                    if (self.pendingExit() != null) return;
                }
            }
        }

        if (options.login) {
            try self.sourceOptional(system_profile_path);
            if (self.pendingExit() != null) return;
            const user_profile_path = try self.userStartupPath("profile.rush");
            defer if (user_profile_path) |path| self.allocator.free(path);
            if (user_profile_path) |path| {
                try self.sourceOptional(path);
                if (self.pendingExit() != null) return;
            }
        }

        try self.sourceOptional(system_config_path);
        if (self.pendingExit() != null) return;
        const user_path = try self.userStartupPath("config.rush");
        defer if (user_path) |path| self.allocator.free(path);
        if (user_path) |path| {
            try self.sourceOptional(path);
            if (self.pendingExit() != null) return;
        }
    }

    fn sourceOptional(self: InteractiveConfigService, path: []const u8) !void {
        const contents = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                try writeOptionalConfigReadWarning(self.io, path, err);
                return;
            },
        };
        defer self.allocator.free(contents);

        try self.sourceScript(contents, path);
    }

    fn sourceScript(self: InteractiveConfigService, contents: []const u8, source_path: []const u8) !void {
        var result = if (self.interactive_shell) |interactive_shell|
            try runInteractiveScript(self.allocator, self.io, interactive_shell, contents, .{ .io = self.io, .allow_external = true, .external_stdio = .capture, .interactive = true, .arg_zero = self.arg_zero, .source_path = source_path })
        else
            try runScriptWithExecutor(self.allocator, self.executor.?, contents, .{ .io = self.io, .allow_external = true, .arg_zero = self.arg_zero, .source_path = source_path });
        defer result.deinit();
        if (result.stdout.len != 0) try writeAll(self.io, .stdout, result.stdout);
        if (result.stderr.len != 0) try writeAll(self.io, .stderr, result.stderr);
    }

    fn userConfigPath(self: InteractiveConfigService) !?[]const u8 {
        return self.userStartupPath("config.rush");
    }

    fn userProfilePath(self: InteractiveConfigService) !?[]const u8 {
        return self.userStartupPath("profile.rush");
    }

    fn userStartupPath(self: InteractiveConfigService, file_name: []const u8) !?[]const u8 {
        if (self.interactive_shell) |interactive_shell| return userStartupPathForShellState(self.allocator, interactive_shell.semantic_state, file_name);
        return userStartupPathForExecutor(self.allocator, self.executor.?.*, file_name);
    }

    fn userStartupPathForExecutor(allocator: std.mem.Allocator, executor: exec.Executor, file_name: []const u8) !?[]const u8 {
        if (executor.getEnv("XDG_CONFIG_HOME")) |xdg_config_home| {
            if (xdg_config_home.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home, "rush", file_name });
        }
        if (executor.getEnv("HOME")) |home| {
            if (home.len != 0) return try std.fs.path.join(allocator, &.{ home, ".config", "rush", file_name });
        }
        return null;
    }

    fn userStartupPathForShellState(allocator: std.mem.Allocator, shell_state: shell.ShellState, file_name: []const u8) !?[]const u8 {
        shell_state.validate();
        if (shell_state.getVariable("XDG_CONFIG_HOME")) |xdg_config_home| {
            if (xdg_config_home.value.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home.value, "rush", file_name });
        }
        if (shell_state.getVariable("HOME")) |home| {
            if (home.value.len != 0) return try std.fs.path.join(allocator, &.{ home.value, ".config", "rush", file_name });
        }
        return null;
    }

    fn getEnv(self: InteractiveConfigService, name: []const u8) ?[]const u8 {
        if (self.interactive_shell) |interactive_shell| {
            interactive_shell.semantic_state.validate();
            return if (interactive_shell.semantic_state.getVariable(name)) |variable| variable.value else null;
        }
        return self.executor.?.getEnv(name);
    }

    fn pendingExit(self: InteractiveConfigService) ?shell.ExitStatus {
        if (self.interactive_shell) |interactive_shell| {
            interactive_shell.semantic_state.validate();
            return interactive_shell.semantic_state.pending_exit;
        }
        return self.executor.?.pending_exit;
    }

    fn expandParametersScalar(self: InteractiveConfigService, text: []const u8, features: compat.Features) ![]const u8 {
        if (self.interactive_shell) |interactive_shell| {
            interactive_shell.semantic_state.validate();
            var adapter = runtime.PosixAdapter.init(self.io);
            var expansion = shell.ShellExpansion.init(self.allocator, .{
                .shell_state = &interactive_shell.semantic_state,
                .eval_context = shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true }),
                .fs_port = runtime.posixPorts(&adapter).fs,
                .features = features,
                .arg_zero = self.arg_zero,
            });
            defer expansion.deinit();
            return expansion.expandParametersScalar(text);
        }
        return self.executor.?.expandParametersScalar(self.allocator, text, .{ .io = self.io, .allow_external = true, .features = features, .arg_zero = self.arg_zero });
    }
};

fn loadInteractiveConfig(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, options: InteractiveOptions) !void {
    try InteractiveConfigService.init(allocator, io, executor, options.arg_zero).load(options);
}

fn sourceOptionalConfig(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, path: []const u8, arg_zero: []const u8) !void {
    try InteractiveConfigService.init(allocator, io, executor, arg_zero).sourceOptional(path);
}

fn writeOptionalConfigReadWarning(io: std.Io, path: []const u8, err: anyerror) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print("rush: warning: cannot read {s}: {s}; skipping\n", .{ path, configReadErrorMessage(err) });
}

fn configReadErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        else => @errorName(err),
    };
}

fn sourceConfigScript(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, contents: []const u8, source_path: []const u8, arg_zero: []const u8) !void {
    try InteractiveConfigService.init(allocator, io, executor, arg_zero).sourceScript(contents, source_path);
}

fn userConfigPath(allocator: std.mem.Allocator, executor: exec.Executor) !?[]const u8 {
    return InteractiveConfigService.userStartupPathForExecutor(allocator, executor, "config.rush");
}

fn userProfilePath(allocator: std.mem.Allocator, executor: exec.Executor) !?[]const u8 {
    return InteractiveConfigService.userStartupPathForExecutor(allocator, executor, "profile.rush");
}

fn userStartupPath(allocator: std.mem.Allocator, executor: exec.Executor, file_name: []const u8) !?[]const u8 {
    return InteractiveConfigService.userStartupPathForExecutor(allocator, executor, file_name);
}

fn isLoginArgZero(arg_zero: []const u8) bool {
    const base = std.fs.path.basename(arg_zero);
    return base.len != 0 and base[0] == '-';
}

fn historyPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !?[]const u8 {
    if (environ_map.get("XDG_STATE_HOME")) |xdg_state_home| {
        if (xdg_state_home.len != 0) return try std.fs.path.join(allocator, &.{ xdg_state_home, "rush", "history.sqlite" });
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len != 0) return try std.fs.path.join(allocator, &.{ home, ".local", "state", "rush", "history.sqlite" });
    }
    return null;
}

const InteractiveSignalHandlers = struct {
    int: SignalActionGuard,
    quit: SignalActionGuard,
    term: SignalActionGuard,

    fn restore(self: *InteractiveSignalHandlers) void {
        self.term.restore();
        self.quit.restore();
        self.int.restore();
    }
};

const SignalActionGuard = struct {
    signal: std.posix.SIG,
    previous: std.posix.Sigaction,

    fn restore(self: SignalActionGuard) void {
        std.posix.sigaction(self.signal, &self.previous, null);
    }
};

fn installInteractiveSignalHandlers() InteractiveSignalHandlers {
    return .{
        .int = installInteractiveSignalHandler(.INT),
        .quit = installInteractiveSignalHandler(.QUIT),
        .term = installInteractiveSignalHandler(.TERM),
    };
}

fn installInteractiveSignalHandler(signal: std.posix.SIG) SignalActionGuard {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleInteractiveSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(signal, &action, &previous);
    return .{ .signal = signal, .previous = previous };
}

fn handleInteractiveSignal(_: std.posix.SIG) callconv(.c) void {}

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

fn writeScriptReadError(io: std.Io, path: []const u8, message: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print("rush: cannot open {s}: {s}\n", .{ path, message });
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
    const path = "rush-history-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.addRecord(.{ .cmd = "echo saved", .when = 42, .status = 0, .cwd = "/tmp" });
    try history.save(std.testing.io, path);

    var loaded = History.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.load(std.testing.io, path);
    try std.testing.expectEqualStrings("echo saved", loaded.suggest("echo").?);
    try std.testing.expectEqual(@as(i64, 42), loaded.records.items[0].when);
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), loaded.records.items[0].status);
    try std.testing.expectEqualStrings("/tmp", loaded.records.items[0].cwd);
}

test "history writes commands through to sqlite fts" {
    const path = "rush-history-fts-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try history.addCommand(std.testing.io, "git checkout feature", 130, 1234, 55);

    var reloaded = History.init(std.testing.allocator);
    defer reloaded.deinit();
    try reloaded.load(std.testing.io, path);
    try std.testing.expectEqualStrings("git checkout feature", reloaded.suggest("git").?);
    try std.testing.expectEqual(@as(shell.ExitStatus, 130), reloaded.records.items[0].status);
    try std.testing.expectEqual(@as(?u8, 2), reloaded.records.items[0].exit_signal);
    try std.testing.expectEqual(@as(i64, 55), reloaded.records.items[0].duration_ms.?);

    const count = try historyFtsMatchCount(reloaded.db.?, "checkout");
    try std.testing.expectEqual(@as(c_int, 1), count);
}

test "history exposes POSIX fc command numbers from sqlite" {
    const path = "rush-history-fc-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try history.addCommand(std.testing.io, "printf 'one\\n'", 0, 10, 1);
    try history.addCommand(std.testing.io, "printf 'two\\n'", 0, 20, 1);

    const entries = try history.fcEntries(std.testing.allocator);
    defer {
        for (entries) |entry| std.testing.allocator.free(entry.command);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(i64, 1), entries[0].number);
    try std.testing.expectEqualStrings("printf 'one\\n'", entries[0].command);
    try std.testing.expectEqual(@as(i64, 2), entries[1].number);
    try std.testing.expectEqualStrings("printf 'two\\n'", entries[1].command);
}

test "history search uses fts ranking and hides older duplicates" {
    const path = "rush-history-fts-search-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try history.addCommand(std.testing.io, "git status", 0, 10, 1);
    try history.addCommand(std.testing.io, "git switch feature", 0, 20, 1);
    try history.addCommand(std.testing.io, "git status", 0, 30, 1);
    try history.addCommand(std.testing.io, "echo git status", 0, 40, 1);

    const first = (try history.searchEntry(std.testing.allocator, "git sta", "", null)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", first.text);
    try std.testing.expectEqual(@as(i64, 30), first.when);

    const second = (try history.searchEntry(std.testing.allocator, "git sta", "", first.id)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo git status", second.text);
    try std.testing.expectEqual(@as(i64, 40), second.when);

    try std.testing.expect(try history.searchEntry(std.testing.allocator, "gco", "", null) == null);
}

test "history search ranks current cwd first while deduping commands globally" {
    const path = "rush-history-fts-cwd-search-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db.?, .{ .cmd = "git status", .cwd = "/repo", .when = 10 });
    try insertHistoryRecord(history.db.?, .{ .cmd = "git switch feature", .cwd = "/repo", .when = 20 });
    try insertHistoryRecord(history.db.?, .{ .cmd = "git status", .cwd = "/other", .when = 30 });
    try insertHistoryRecord(history.db.?, .{ .cmd = "echo git status", .cwd = "/other", .when = 40 });

    const first = (try history.searchEntry(std.testing.allocator, "git sta", "/repo", null)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", first.text);
    try std.testing.expectEqual(@as(i64, 10), first.when);

    const second = (try history.searchEntry(std.testing.allocator, "git sta", "/repo", first.id)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo git status", second.text);
    try std.testing.expectEqual(@as(i64, 40), second.when);
}

test "history navigation is scoped to current cwd" {
    const path = "rush-history-cwd-navigation-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    try insertHistoryRecord(history.db.?, .{ .cmd = "echo repo-a", .cwd = "/repo/a", .when = 10 });
    try insertHistoryRecord(history.db.?, .{ .cmd = "echo repo-b", .cwd = "/repo/b", .when = 20 });
    try insertHistoryRecord(history.db.?, .{ .cmd = "git status", .cwd = "/repo/a", .when = 30 });
    try insertHistoryRecord(history.db.?, .{ .cmd = "git status", .cwd = "/repo/b", .when = 40 });

    const repo_a_previous = (try history.previousEntry(std.testing.allocator, "", "/repo/a", "", null)).?;
    defer repo_a_previous.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", repo_a_previous.text);
    try std.testing.expectEqual(@as(i64, 30), repo_a_previous.when);

    const repo_a_older = (try history.previousEntry(std.testing.allocator, "", "/repo/a", "", repo_a_previous.id)).?;
    defer repo_a_older.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo repo-a", repo_a_older.text);

    const repo_a_next = (try history.nextEntry(std.testing.allocator, "", "/repo/a", "", repo_a_older.id)).?;
    defer repo_a_next.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", repo_a_next.text);

    const repo_b_suggestion = (try history.suggestEntry(std.testing.allocator, "echo", "/repo/b")).?;
    defer repo_b_suggestion.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo repo-b", repo_b_suggestion.text);
}

test "line history navigation is scoped to session and cwd" {
    const path = "rush-history-session-navigation-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history_a = History.init(std.testing.allocator);
    defer history_a.deinit();
    try history_a.load(std.testing.io, path);
    history_a.current_cwd = "/repo";
    history_a.session_id = "session-a";
    var history_service_a = InteractiveHistoryService.init(&history_a);
    try insertHistoryRecord(history_a.db.?, .{ .cmd = "echo a-one", .cwd = "/repo", .when = 10, .session_id = "session-a" });
    try insertHistoryRecord(history_a.db.?, .{ .cmd = "echo b-one", .cwd = "/repo", .when = 20, .session_id = "session-b" });
    try insertHistoryRecord(history_a.db.?, .{ .cmd = "git status", .cwd = "/repo", .when = 30, .session_id = "session-a" });
    try insertHistoryRecord(history_a.db.?, .{ .cmd = "git diff", .cwd = "/repo", .when = 40, .session_id = "session-b" });
    try insertHistoryRecord(history_a.db.?, .{ .cmd = "echo a-other", .cwd = "/other", .when = 50, .session_id = "session-a" });

    var history_b = History.init(std.testing.allocator);
    defer history_b.deinit();
    try history_b.load(std.testing.io, path);
    history_b.current_cwd = "/repo";
    history_b.session_id = "session-b";
    var history_service_b = InteractiveHistoryService.init(&history_b);

    var session_a = try line_editor.LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history_service_a, .previous = previousHistoryEntry, .next = nextHistoryEntry });
    defer session_a.deinit();
    try session_a.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo a-one", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git status", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("", session_a.editor.buffer.text());

    var session_b = try line_editor.LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .context = &history_service_b, .previous = previousHistoryEntry, .next = nextHistoryEntry });
    defer session_b.deinit();
    try session_b.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git diff", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo b-one", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git diff", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("", session_b.editor.buffer.text());
}

test "history load rebuilds fts for existing history rows" {
    const path = "rush-history-fts-migration-test.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    var db: ?*sqlite.sqlite3 = null;
    try sqliteCheck(sqlite.sqlite3_open_v2(path_z.ptr, &db, sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX, null), db);
    defer if (db) |handle| {
        _ = sqlite.sqlite3_close(handle);
    };
    try sqliteExec(db.?,
        \\create table history (
        \\  id integer primary key,
        \\  command text not null,
        \\  cwd text not null,
        \\  status integer not null,
        \\  started_at integer not null
        \\);
        \\insert into history(command, cwd, status, started_at) values ('git checkout main', '', 0, 1);
    );
    _ = sqlite.sqlite3_close(db.?);
    db = null;

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.load(std.testing.io, path);
    const entry = (try history.searchEntry(std.testing.allocator, "checkout", "", null)).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git checkout main", entry.text);
}

test "history path follows XDG state home then HOME fallback" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("XDG_STATE_HOME", "/state");
    try env.put("HOME", "/home/me");
    const xdg_path = (try historyPath(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(xdg_path);
    try std.testing.expectEqualStrings("/state/rush/history.sqlite", xdg_path);

    try env.put("XDG_STATE_HOME", "");
    const home_path = (try historyPath(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(home_path);
    try std.testing.expectEqualStrings("/home/me/.local/state/rush/history.sqlite", home_path);
}

test "completion cache stores cloned candidates by input cursor and cwd" {
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();

    var candidates = [_]completion_model.Candidate{.{
        .value = "checkout",
        .description = "switch branches",
        .kind = .subcommand,
        .replace_start = 4,
        .replace_end = 6,
    }};
    try cache.put("git ch", 6, "/tmp/project", 0, &candidates);

    const cached = cache.get("git ch", 6, "/tmp/project", 0) orelse return error.MissingCompletionCacheEntry;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqualStrings("checkout", cached[0].value);
    try std.testing.expectEqualStrings("switch branches", cached[0].description.?);
    try std.testing.expect(cache.get("git ch", 5, "/tmp/project", 0) == null);
    try std.testing.expect(cache.get("git ch", 6, "/tmp/other", 0) == null);
}

test "completion cache replaces existing entries" {
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();

    var first = [_]completion_model.Candidate{.{ .value = "checkout", .replace_start = 4, .replace_end = 6 }};
    var second = [_]completion_model.Candidate{.{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 }};
    try cache.put("git ch", 6, "/tmp/project", 0, &first);
    try cache.put("git ch", 6, "/tmp/project", 0, &second);

    const cached = cache.get("git ch", 6, "/tmp/project", 0) orelse return error.MissingCompletionCacheEntry;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqualStrings("cherry-pick", cached[0].value);
}

test "completion script paths follow XDG data and config homes" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("HOME", "/home/me");
    try executor.setEnv("XDG_DATA_HOME", "/data");
    try executor.setEnv("XDG_CONFIG_HOME", "/config");

    const data_path = (try xdgDataHomeCompletionPath(std.testing.allocator, executor, "git")).?;
    defer std.testing.allocator.free(data_path);
    try std.testing.expectEqualStrings("/data/rush/completions/git.rush", data_path);

    const config_path = (try xdgConfigCompletionPath(std.testing.allocator, executor, "git")).?;
    defer std.testing.allocator.free(config_path);
    try std.testing.expectEqualStrings("/config/rush/completions/git.rush", config_path);
}

test "completion script command names are safe file basenames" {
    try std.testing.expect(validCompletionScriptCommand("git"));
    try std.testing.expect(validCompletionScriptCommand("kubectl-krew"));
    try std.testing.expect(!validCompletionScriptCommand(""));
    try std.testing.expect(!validCompletionScriptCommand("."));
    try std.testing.expect(!validCompletionScriptCommand(".."));
    try std.testing.expect(!validCompletionScriptCommand("../git"));
    try std.testing.expect(!validCompletionScriptCommand("path/git"));
}

test "completion scripts lazy-load from XDG data home" {
    const root = "rush-completion-loader-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.rush", .data =
        \\__rush_complete_tool() { completion candidate loaded --kind subcommand; }
        \\complete tool --subcommands --function __rush_complete_tool
    });

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_DIRS", "");
    try executor.setEnv("XDG_DATA_HOME", root);

    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();

    try loader.ensureLoaded(std.testing.io, &executor, "tool", "rush");

    const rules = executor.completionRules();
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings("tool", rules[0].root);
    try std.testing.expectEqual(completion_model.RuleKind.dynamic_subcommands, rules[0].kind);
    try std.testing.expectEqualStrings("__rush_complete_tool", rules[0].value.?);
    try std.testing.expect(loader.attempted.contains("tool"));
}

test "completion manifests lazy-load static subcommands and options" {
    const root = "rush-completion-manifest-loader-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "options": [
        \\      { "long": "verbose", "short": "v", "description": "show more output" },
        \\      { "long": "include", "repeatable": true },
        \\      { "long": "passthrough", "terminatesOptions": true }
        \\    ],
        \\    "subcommands": [
        \\      {
        \\        "name": "run",
        \\        "description": "run a task",
        \\        "options": [
        \\          { "long": "file", "value": { "name": "path" } }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    });

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_DIRS", "");
    try executor.setEnv("XDG_DATA_HOME", root);

    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();

    try loader.ensureLoaded(std.testing.io, &executor, "tool", "rush");

    const rules = executor.completionRules();
    try std.testing.expectEqual(@as(usize, 5), rules.len);
    try std.testing.expectEqualStrings("tool", rules[0].root);
    try std.testing.expectEqual(completion_model.RuleKind.option, rules[0].kind);
    try std.testing.expectEqualStrings("verbose", rules[0].option.long.?);
    try std.testing.expectEqualStrings("v", rules[0].option.short.?);
    try std.testing.expectEqualStrings("show more output", rules[0].description.?);
    try std.testing.expectEqualStrings("include", rules[1].option.long.?);
    try std.testing.expect(rules[1].option.repeatable);
    try std.testing.expectEqualStrings("passthrough", rules[2].option.long.?);
    try std.testing.expect(rules[2].option.terminates_options);
    try std.testing.expectEqual(completion_model.RuleKind.subcommand, rules[3].kind);
    try std.testing.expectEqualStrings("run", rules[3].value.?);
    try std.testing.expectEqual(completion_model.RuleKind.option, rules[4].kind);
    try std.testing.expectEqualStrings("run", rules[4].path[0]);
    try std.testing.expectEqualStrings("file", rules[4].option.long.?);
    try std.testing.expectEqualStrings("path", rules[4].option.argument.?);

    const suppressed = try executor.collectCompletionsForInput("tool --verbose --include --", "tool --verbose --include --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(suppressed);
    try expectNoCompletionCandidate(suppressed, "--verbose");
    try expectCompletionCandidate(suppressed, "--include");

    const terminated = try executor.collectCompletionsForInput("tool --passthrough --", "tool --passthrough --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(terminated);
    try expectNoCompletionCandidate(terminated, "--verbose");
}

test "completion manifests bind companion function providers and builtin providers" {
    const root = "rush-completion-manifest-provider-binding-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush-manifest-provider-dir");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/bin");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush-manifest-provider-file.txt", .data = "fixture" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/bin/runner-tool", .data = "#!/bin/sh\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.rush", .data =
        \\__rush_complete_tool_targets() {
        \\  completion candidate target-one --kind plain
        \\}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.targets": { "function": "__rush_complete_tool_targets" },
        \\      "builtin.files": { "builtin": "files" },
        \\      "builtin.directories": { "builtin": "directories" },
        \\      "builtin.executables": { "builtin": "executables" },
        \\      "builtin.variables": { "builtin": "variables" }
        \\    },
        \\    "options": [
        \\      { "long": "config", "value": { "name": "path", "provider": "builtin.files" } },
        \\      { "long": "cwd", "value": { "name": "dir", "provider": "builtin.directories" } },
        \\      { "long": "runner", "value": { "name": "cmd", "provider": "builtin.executables" } },
        \\      { "long": "env", "value": { "name": "var", "provider": "builtin.variables" } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "index": 0, "provider": "tool.targets" }
        \\      ]
        \\    }
        \\  }
        \\}
    });

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_DIRS", "");
    try executor.setEnv("XDG_DATA_HOME", root);
    try executor.setEnv("PATH", root ++ "/bin");
    try executor.setEnv("RUSH_MANIFEST_PROVIDER_VAR", "1");

    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.ensureLoaded(std.testing.io, &executor, "tool", "rush");

    const argument_candidates = try executor.collectCompletionsForInput("tool ta", "tool ta".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(argument_candidates);
    try expectCompletionCandidate(argument_candidates, "target-one");

    const file_candidates = try executor.collectCompletionsForInput("tool --config " ++ root ++ "/rush-manifest-provider-fi", ("tool --config " ++ root ++ "/rush-manifest-provider-fi").len, .{ .io = std.testing.io });
    defer executor.freeCompletions(file_candidates);
    try expectCompletionCandidate(file_candidates, "rush-manifest-provider-file.txt");

    const directory_candidates = try executor.collectCompletionsForInput("tool --cwd " ++ root ++ "/rush-manifest-provider-di", ("tool --cwd " ++ root ++ "/rush-manifest-provider-di").len, .{ .io = std.testing.io });
    defer executor.freeCompletions(directory_candidates);
    try expectCompletionCandidate(directory_candidates, "rush-manifest-provider-dir/");

    const executable_candidates = try executor.collectCompletionsForInput("tool --runner runner", "tool --runner runner".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(executable_candidates);
    try expectCompletionCandidate(executable_candidates, "runner-tool");

    const variable_candidates = try executor.collectCompletionsForInput("tool --env RUSH_MANIFEST_PROVIDER", "tool --env RUSH_MANIFEST_PROVIDER".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(variable_candidates);
    try expectCompletionCandidate(variable_candidates, "RUSH_MANIFEST_PROVIDER_VAR");
}

test "completion application tolerates manifest path providers with mixed replacement spans" {
    const root = "rush-completion-manifest-mixed-path-span-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/src");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/src/main.zig", .data = "fixture" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.rush", .data = "__rush_complete_tool_paths() {\n" ++
        "  completion candidate " ++ root ++ "/src/main.zig --kind file\n" ++
        "}\n" ++
        "complete tool --argument --function __rush_complete_tool_paths\n" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "builtin.files": { "builtin": "files" }
        \\    },
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "pathspec", "index": 0, "repeatable": true, "provider": "builtin.files" }
        \\      ]
        \\    }
        \\  }
        \\}
    });

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_DIRS", "");
    try executor.setEnv("XDG_DATA_HOME", root);

    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.ensureLoaded(std.testing.io, &executor, "tool", "rush");
    try sourceOptionalConfig(std.testing.allocator, std.testing.io, &executor, root ++ "/rush/completions/tool.rush", "rush");

    const source = "tool " ++ root ++ "/src/mai";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);

    const full_path = findCompletionCandidate(candidates, root ++ "/src/main.zig") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "tool ".len), full_path.replace_start);
    const basename = findCompletionCandidate(candidates, "main.zig") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, ("tool " ++ root ++ "/src/").len), basename.replace_start);

    const application = try completion_model.applyCandidatesForInput(std.testing.allocator, source, candidates);
    defer application.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
}

test "completion manifest static enum providers emit scoped candidates" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.modes": {
        \\        "values": [
        \\          "auto",
        \\          { "value": "always", "description": "always enable mode" },
        \\          { "value": "csv", "suffix": ",", "removableSuffix": true },
        \\          { "value": "format:", "display": "custom format", "noSpace": true }
        \\        ]
        \\      }
        \\    },
        \\    "options": [
        \\      { "long": "mode", "value": { "name": "mode", "provider": "tool.modes" } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "mode", "index": 0, "provider": "tool.modes" }
        \\      ]
        \\    }
        \\  }
        \\}
    );

    const option_candidates = try executor.collectCompletionsForInput("tool --mode al", "tool --mode al".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(option_candidates);
    const always = findCompletionCandidate(option_candidates, "always") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("always enable mode", always.description.?);

    const display_candidates = try executor.collectCompletionsForInput("tool --mode custom", "tool --mode custom".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(display_candidates);
    const format = findCompletionCandidate(display_candidates, "format:") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("custom format", format.display.?);
    try std.testing.expect(!format.append_space);

    const suffix_candidates = try executor.collectCompletionsForInput("tool --mode cs", "tool --mode cs".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(suffix_candidates);
    const csv = findCompletionCandidate(suffix_candidates, "csv") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings(",", csv.suffix.?);
    try std.testing.expect(csv.removable_suffix);
    try std.testing.expect(!csv.append_space);

    const argument_candidates = try executor.collectCompletionsForInput("tool au", "tool au".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(argument_candidates);
    try expectCompletionCandidate(argument_candidates, "auto");
}

test "completion manifest option excludes suppress candidates asymmetrically" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.targets": { "values": ["target"] }
        \\    },
        \\    "options": [
        \\      { "long": "help", "excludes": "everything" },
        \\      { "long": "all", "excludes": "operands" },
        \\      { "long": "raw", "excludes": ["--pretty"] },
        \\      { "long": "pretty" },
        \\      { "long": "verbose" }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "index": 0, "provider": "tool.targets" }
        \\      ]
        \\    }
        \\  }
        \\}
    );

    const help_candidates = try executor.collectCompletionsForInput("tool --help ", "tool --help ".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(help_candidates);
    try std.testing.expectEqual(@as(usize, 0), help_candidates.len);

    const help_options = try executor.collectCompletionsForInput("tool --help --", "tool --help --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(help_options);
    try std.testing.expectEqual(@as(usize, 0), help_options.len);

    const all_arguments = try executor.collectCompletionsForInput("tool --all t", "tool --all t".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(all_arguments);
    try expectNoCompletionCandidate(all_arguments, "target");

    const all_options = try executor.collectCompletionsForInput("tool --all --", "tool --all --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(all_options);
    try expectCompletionCandidate(all_options, "--verbose");

    const raw_options = try executor.collectCompletionsForInput("tool --raw --", "tool --raw --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(raw_options);
    try expectNoCompletionCandidate(raw_options, "--pretty");
    try expectCompletionCandidate(raw_options, "--verbose");

    const pretty_options = try executor.collectCompletionsForInput("tool --pretty --", "tool --pretty --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(pretty_options);
    try expectCompletionCandidate(pretty_options, "--raw");
}

test "completion manifest provider arrays preserve tags order and first duplicate metadata" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var script_result = try executor.executeScriptSlice(
        \\__rush_complete_tool_func() {
        \\  completion candidate emitted --kind plain --tag emitted-tag --description emitted
        \\  completion candidate default --kind plain --description default
        \\}
    , .{ .io = std.testing.io });
    defer script_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), script_result.status);
    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.refs": {
        \\        "values": [
        \\          { "value": "shared", "description": "ref-shared" },
        \\          "zbranch"
        \\        ],
        \\        "tag": "refs"
        \\      },
        \\      "tool.files": {
        \\        "values": [
        \\          { "value": "shared", "description": "file-shared", "tag": "files" },
        \\          "afile"
        \\        ],
        \\        "tag": "files"
        \\      },
        \\      "tool.func": { "function": "__rush_complete_tool_func", "tag": "function-tag" }
        \\    },
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "provider": ["tool.refs", "tool.files", "tool.func"] }
        \\      ]
        \\    }
        \\  }
        \\}
    );

    const candidates = try executor.collectCompletionsForInput("tool ", "tool ".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try std.testing.expectEqualStrings("shared", candidates[0].value);
    try std.testing.expectEqualStrings("refs", candidates[0].tag.?);
    try std.testing.expectEqualStrings("ref-shared", candidates[0].description.?);
    try std.testing.expectEqualStrings("zbranch", candidates[1].value);
    try std.testing.expectEqualStrings("refs", candidates[1].tag.?);
    const afile = findCompletionCandidate(candidates, "afile") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("files", afile.tag.?);
    const emitted = findCompletionCandidate(candidates, "emitted") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("emitted-tag", emitted.tag.?);
    const default = findCompletionCandidate(candidates, "default") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqualStrings("function-tag", default.tag.?);
}
test "completion manifest multi-value options select each provider and preserve operand indexes" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "displayctl",
        \\    "providers": {
        \\      "display.outputs": { "values": ["HDMI-1", "DP-1"] },
        \\      "display.modes": { "values": ["1920x1080", "2560x1440"] },
        \\      "display.targets": { "values": ["target-a", "target-b"] }
        \\    },
        \\    "options": [
        \\      {
        \\        "long": "mode",
        \\        "value": [
        \\          { "name": "output", "provider": "display.outputs" },
        \\          { "name": "mode", "provider": "display.modes", "grammar": { "kind": "list", "separator": ",", "item": { "provider": "display.modes" } } }
        \\        ]
        \\      }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "index": 0, "provider": "display.targets" }
        \\      ]
        \\    }
        \\  }
        \\}
    );

    const output_candidates = try executor.collectCompletionsForInput("displayctl --mode HD", "displayctl --mode HD".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(output_candidates);
    try expectCompletionCandidate(output_candidates, "HDMI-1");
    try expectNoCompletionCandidate(output_candidates, "1920x1080");
    var context = executor.lastCompletionContext() orelse return error.MissingCompletionContext;
    try std.testing.expectEqual(@as(usize, 0), context.option_value.?.value_index);

    const mode_source = "displayctl --mode HDMI-1 current,19";
    const mode_candidates = try executor.collectCompletionsForInput(mode_source, mode_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(mode_candidates);
    const mode = findCompletionCandidate(mode_candidates, "1920x1080") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(@as(usize, "displayctl --mode HDMI-1 current,".len), mode.replace_start);
    try expectNoCompletionCandidate(mode_candidates, "HDMI-1");
    context = executor.lastCompletionContext() orelse return error.MissingCompletionContext;
    try std.testing.expectEqual(@as(usize, 1), context.option_value.?.value_index);

    const attached_mode_candidates = try executor.collectCompletionsForInput("displayctl --mode=HDMI-1 25", "displayctl --mode=HDMI-1 25".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(attached_mode_candidates);
    try expectCompletionCandidate(attached_mode_candidates, "2560x1440");
    context = executor.lastCompletionContext() orelse return error.MissingCompletionContext;
    try std.testing.expectEqual(@as(usize, 1), context.option_value.?.value_index);

    const target_source = "displayctl --mode HDMI-1 1920x1080 target";
    const target_candidates = try executor.collectCompletionsForInput(target_source, target_source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(target_candidates);
    try expectCompletionCandidate(target_candidates, "target-a");
    context = executor.lastCompletionContext() orelse return error.MissingCompletionContext;
    try std.testing.expectEqual(@as(usize, 0), context.argument_index);
    try std.testing.expectEqualStrings("target", context.argument_state.?);
}

test "completion manifest argument states branch on option values" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.jsonArgs": { "values": ["jq-filter"] },
        \\      "tool.tableArgs": { "values": ["column"] },
        \\      "tool.defaultArgs": { "values": ["input"] }
        \\    },
        \\    "options": [
        \\      { "short": "f", "long": "format", "value": { "name": "format", "grammar": { "kind": "enum", "values": ["json", "table"] } } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "json-arg", "provider": "tool.jsonArgs", "when": { "optionValue": { "--format": "json" } } },
        \\        { "name": "table-arg", "provider": "tool.tableArgs", "when": { "optionValue": { "-f": ["table"] } } },
        \\        { "name": "default-arg", "provider": "tool.defaultArgs" }
        \\      ]
        \\    }
        \\  }
        \\}
    );

    var json_analysis = try executor.analyzeCompletionsForInput("tool --format json ", "tool --format json ".len);
    defer json_analysis.deinit();
    try std.testing.expectEqualStrings("json-arg", json_analysis.argument_state.?);
    const json_candidates = try executor.collectCompletionsForInput("tool --format json ", "tool --format json ".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(json_candidates);
    try expectCompletionCandidate(json_candidates, "jq-filter");
    try expectNoCompletionCandidate(json_candidates, "column");

    var table_analysis = try executor.analyzeCompletionsForInput("tool --format table ", "tool --format table ".len);
    defer table_analysis.deinit();
    try std.testing.expectEqualStrings("table-arg", table_analysis.argument_state.?);
    const table_candidates = try executor.collectCompletionsForInput("tool --format table ", "tool --format table ".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(table_candidates);
    try expectCompletionCandidate(table_candidates, "column");
    try expectNoCompletionCandidate(table_candidates, "jq-filter");

    var missing_analysis = try executor.analyzeCompletionsForInput("tool ", "tool ".len);
    defer missing_analysis.deinit();
    try std.testing.expectEqualStrings("default-arg", missing_analysis.argument_state.?);
}

test "completion manifest optionValue conditions match any repeatable occurrence" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.matched": { "values": ["matched"] },
        \\      "tool.default": { "values": ["default"] }
        \\    },
        \\    "options": [
        \\      { "long": "include", "repeatable": true, "value": { "name": "path" } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "matched", "provider": "tool.matched", "when": { "optionValue": { "--include": ["src", "lib"] } } },
        \\        { "name": "default", "provider": "tool.default" }
        \\      ]
        \\    }
        \\  }
        \\}
    );

    var any_match = try executor.analyzeCompletionsForInput("tool --include other --include src ", "tool --include other --include src ".len);
    defer any_match.deinit();
    try std.testing.expectEqualStrings("matched", any_match.argument_state.?);

    var no_match = try executor.analyzeCompletionsForInput("tool --include other ", "tool --include other ".len);
    defer no_match.deinit();
    try std.testing.expectEqualStrings("default", no_match.argument_state.?);
}

test "completion manifest argument states evaluate nested conditions" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.terminator": { "values": ["terminated"] },
        \\      "tool.first": { "values": ["first"] },
        \\      "tool.jsonNext": { "values": ["json-next"] },
        \\      "tool.defaultNext": { "values": ["default-next"] }
        \\    },
        \\    "options": [
        \\      { "long": "format", "short": "f", "value": { "name": "format", "grammar": { "kind": "enum", "values": ["json", "table"] } } },
        \\      { "long": "dry-run" },
        \\      { "long": "skip" }
        \\    ],
        \\    "arguments": {
        \\      "terminator": "--",
        \\      "states": [
        \\        { "name": "terminator", "provider": "tool.terminator", "when": { "terminatorSeen": true } },
        \\        { "name": "first", "provider": "tool.first" },
        \\        {
        \\          "name": "json-next",
        \\          "provider": "tool.jsonNext",
        \\          "after": { "all": [
        \\            { "previousState": "first" },
        \\            { "any": [
        \\              { "optionValue": { "--format": "json" } },
        \\              { "optionValue": { "-f": "json" } }
        \\            ] },
        \\            { "optionPresent": "--dry-run" },
        \\            { "not": { "optionPresent": "--skip" } }
        \\          ] }
        \\        },
        \\        { "name": "default-next", "provider": "tool.defaultNext" }
        \\      ]
        \\    }
        \\  }
        \\}
    );

    var first = try executor.analyzeCompletionsForInput("tool ", "tool ".len);
    defer first.deinit();
    try std.testing.expectEqualStrings("first", first.argument_state.?);

    var terminated = try executor.analyzeCompletionsForInput("tool -- ", "tool -- ".len);
    defer terminated.deinit();
    try std.testing.expectEqualStrings("terminator", terminated.argument_state.?);

    var matched = try executor.analyzeCompletionsForInput("tool --format json --dry-run first ", "tool --format json --dry-run first ".len);
    defer matched.deinit();
    try std.testing.expectEqualStrings("json-next", matched.argument_state.?);

    var short_matched = try executor.analyzeCompletionsForInput("tool -f json --dry-run first ", "tool -f json --dry-run first ".len);
    defer short_matched.deinit();
    try std.testing.expectEqualStrings("json-next", short_matched.argument_state.?);

    var missing_flags = try executor.analyzeCompletionsForInput("tool first ", "tool first ".len);
    defer missing_flags.deinit();
    try std.testing.expectEqualStrings("default-next", missing_flags.argument_state.?);

    var negated = try executor.analyzeCompletionsForInput("tool --format json --dry-run --skip first ", "tool --format json --dry-run --skip first ".len);
    defer negated.deinit();
    try std.testing.expectEqualStrings("default-next", negated.argument_state.?);
}

test "completion manifest literal spellings recognize values selectors and suppression" {
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fixtures/completion-data/rush/completions/literalopts.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(manifest);

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try loadCompletionManifest(std.testing.allocator, &executor, manifest);

    const option_candidates = try executor.collectCompletionsForInput("literalopts -i", "literalopts -i".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(option_candidates);
    try expectCompletionCandidate(option_candidates, "-iname");
    try expectNoCompletionCandidate(option_candidates, "-i");

    var detached = try executor.analyzeCompletionsForInput("literalopts -iname needle path ", "literalopts -iname needle path ".len);
    defer detached.deinit();
    try std.testing.expectEqual(@as(usize, 1), detached.parsed_options.len);
    try std.testing.expectEqualStrings("-iname", detached.parsed_options[0].spelling);
    try std.testing.expectEqualStrings("-iname", detached.parsed_options[0].name);
    try std.testing.expectEqualStrings("-iname", detached.parsed_options[0].key);
    try std.testing.expectEqualStrings("needle", detached.parsed_options[0].value.?);
    try std.testing.expectEqual(@as(usize, 1), detached.argument_index);

    var attached = try executor.analyzeCompletionsForInput("literalopts -inameneedle path ", "literalopts -inameneedle path ".len);
    defer attached.deinit();
    try std.testing.expectEqual(@as(usize, 1), attached.parsed_options.len);
    try std.testing.expectEqualStrings("-iname", attached.parsed_options[0].spelling);
    try std.testing.expectEqualStrings("needle", attached.parsed_options[0].value.?);
    try std.testing.expectEqual(@as(usize, 1), attached.argument_index);

    const selector_candidates = try executor.collectCompletionsForInput("literalopts -iname needle ", "literalopts -iname needle ".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(selector_candidates);
    try expectCompletionCandidate(selector_candidates, "matched-iname");
    try expectNoCompletionCandidate(selector_candidates, "default-arg");

    const plus_candidates = try executor.collectCompletionsForInput("literalopts +", "literalopts +".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(plus_candidates);
    try expectCompletionCandidate(plus_candidates, "+o");

    var plus = try executor.analyzeCompletionsForInput("literalopts +o path ", "literalopts +o path ".len);
    defer plus.deinit();
    try std.testing.expectEqual(@as(usize, 1), plus.parsed_options.len);
    try std.testing.expectEqualStrings("+o", plus.parsed_options[0].spelling);
    try std.testing.expect(plus.parsed_options[0].value == null);
    try std.testing.expectEqual(@as(usize, 1), plus.argument_index);

    const suppressed = try executor.collectCompletionsForInput("literalopts -iname needle -", "literalopts -iname needle -".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(suppressed);
    try expectNoCompletionCandidate(suppressed, "-name");
    try expectCompletionCandidate(suppressed, "-iname");
}

test "completion manifest semantic validation dedupes effective literal spellings" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "options": [
        \\      { "short": "p" },
        \\      { "spellings": ["-p"] },
        \\      { "long": "color" },
        \\      { "spellings": ["--color"] }
        \\    ]
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[1].spellings[0]: duplicate option spelling '-p'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[3].spellings[0]: duplicate option spelling '--color'");
}

test "completion manifest variants select lazily and cache probe result" {
    const platform = completionManifestCurrentPlatform();
    const manifest = try std.fmt.allocPrint(std.testing.allocator,
        \\
        \\{{
        \\  "manifestVersion": 1,
        \\  "command": {{
        \\    "name": "lslike",
        \\    "options": [{{ "long": "base" }}],
        \\    "variantProbe": {{
        \\      "args": ["--version"],
        \\      "matches": {{ "gnu": "GNU coreutils", "unix": "" }}
        \\    }},
        \\    "variants": {{
        \\      "gnu": {{ "options": [{{ "long": "color" }}] }},
        \\      "unix": {{ "options": [{{ "long": "classify" }}, {{ "short": "@", "platforms": ["{s}"] }}] }}
        \\    }}
        \\  }}
        \\}}
    , .{platform});
    defer std.testing.allocator.free(manifest);

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try loadCompletionManifest(std.testing.allocator, &executor, manifest);
    try std.testing.expectEqual(@as(usize, 4), executor.completionRules().len);
    try executor.setCompletionVariantProbeMock("lslike", "ls (GNU coreutils) 9.5\n");

    const first = try executor.collectCompletionsForInput("lslike --", "lslike --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(first);
    try expectCompletionCandidate(first, "--base");
    try expectCompletionCandidate(first, "--color");
    try expectNoCompletionCandidate(first, "--classify");
    try std.testing.expectEqual(@as(usize, 1), executor.completionVariantProbeCount("lslike"));

    const second = try executor.collectCompletionsForInput("lslike --", "lslike --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(second);
    try expectCompletionCandidate(second, "--color");
    try std.testing.expectEqual(@as(usize, 1), executor.completionVariantProbeCount("lslike"));
}

test "completion manifest variant probe fallback and platform-gated option" {
    const platform = completionManifestCurrentPlatform();
    const manifest = try std.fmt.allocPrint(std.testing.allocator,
        \\
        \\{{
        \\  "manifestVersion": 1,
        \\  "command": {{
        \\    "name": "lslike",
        \\    "variantProbe": {{ "args": ["--version"], "matches": {{ "gnu": "GNU coreutils", "unix": "" }} }},
        \\    "variants": {{
        \\      "gnu": {{ "options": [{{ "long": "color" }}] }},
        \\      "unix": {{ "options": [{{ "long": "classify" }}, {{ "short": "@", "platforms": ["{s}"] }}] }}
        \\    }}
        \\  }}
        \\}}
    , .{platform});
    defer std.testing.allocator.free(manifest);

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try loadCompletionManifest(std.testing.allocator, &executor, manifest);
    try executor.setCompletionVariantProbeMock("lslike", "BSD ls\n");

    const long_candidates = try executor.collectCompletionsForInput("lslike --", "lslike --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(long_candidates);
    try expectCompletionCandidate(long_candidates, "--classify");
    try expectNoCompletionCandidate(long_candidates, "--color");

    const short_candidates = try executor.collectCompletionsForInput("lslike -", "lslike -".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(short_candidates);
    try expectCompletionCandidate(short_candidates, "-@");
}

test "completion manifest variant probe skips shell function shadow" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "shadowtool",
        \\    "options": [ { "long": "base" } ],
        \\    "variantProbe": { "args": ["--version"], "matches": { "gnu": "GNU", "unix": "" } },
        \\    "variants": {
        \\      "gnu": { "options": [ { "long": "color" } ] },
        \\      "unix": { "options": [ { "long": "classify" } ] }
        \\    }
        \\  }
        \\}
    );
    var function_result = try executor.executeScriptSlice("shadowtool() { :; }", .{});
    defer function_result.deinit();
    try executor.setCompletionVariantProbeMock("shadowtool", "GNU\n");

    const candidates = try executor.collectCompletionsForInput("shadowtool --", "shadowtool --".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try expectCompletionCandidate(candidates, "--base");
    try expectNoCompletionCandidate(candidates, "--color");
    try expectNoCompletionCandidate(candidates, "--classify");
    try std.testing.expectEqual(@as(usize, 0), executor.completionVariantProbeCount("shadowtool"));
    const probe = executor.completionVariantProbeState("shadowtool") orelse return error.MissingCompletionVariantProbe;
    try std.testing.expect(probe.skipped_shadow);
}

test "completion manifest command platform gate skips registration" {
    const current = completionManifestCurrentPlatform();
    const other = if (std.mem.eql(u8, current, "linux")) "darwin" else "linux";
    const manifest = try std.fmt.allocPrint(std.testing.allocator,
        \\
        \\{{
        \\  "manifestVersion": 1,
        \\  "command": {{
        \\    "name": "onlyelsewhere",
        \\    "platforms": ["{s}"],
        \\    "options": [{{ "long": "never" }}]
        \\  }}
        \\}}
    , .{other});
    defer std.testing.allocator.free(manifest);

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try loadCompletionManifest(std.testing.allocator, &executor, manifest);
    try std.testing.expectEqual(@as(usize, 0), executor.completionRules().len);
    const state = executor.completionManifestCommandState("onlyelsewhere") orelse return error.MissingCompletionManifestState;
    try std.testing.expect(!state.platform_allowed);
}

test "completion manifest precommand rest re-enters command completion" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_HOME", "test/fixtures/completion-data");
    try executor.setEnv("XDG_DATA_DIRS", "");

    const bin_dir = "rush-precommand-bin";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, bin_dir) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, bin_dir, .default_dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bin_dir ++ "/git", .data = "" });
    try executor.setEnv("PATH", bin_dir);

    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.ensureLoaded(std.testing.io, &executor, "sudo", "rush");

    const command_candidates = try executor.collectCompletionsForInput("sudo gi", "sudo gi".len, .{
        .io = std.testing.io,
        .completion_loader = loadCompletionDataForExecutor,
        .completion_loader_context = &loader,
    });
    defer executor.freeCompletions(command_candidates);
    const git_command = findCompletionCandidate(command_candidates, "git") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(completion_model.Kind.command, git_command.kind);
    try std.testing.expectEqual(@as(usize, "sudo ".len), git_command.replace_start);

    const option_source = "sudo -u root git diff --ca";
    const option_candidates = try executor.collectCompletionsForInput(option_source, option_source.len, .{
        .io = std.testing.io,
        .completion_loader = loadCompletionDataForExecutor,
        .completion_loader_context = &loader,
    });
    defer executor.freeCompletions(option_candidates);
    const cached_option = findCompletionCandidate(option_candidates, "--cached") orelse return error.MissingCompletionCandidate;
    try std.testing.expectEqual(completion_model.Kind.option, cached_option.kind);
    try std.testing.expectEqual(@as(usize, "sudo -u root git diff ".len), cached_option.replace_start);

    const nested_source = "sudo sudo git diff --sta";
    const nested_candidates = try executor.collectCompletionsForInput(nested_source, nested_source.len, .{
        .io = std.testing.io,
        .completion_loader = loadCompletionDataForExecutor,
        .completion_loader_context = &loader,
    });
    defer executor.freeCompletions(nested_candidates);
    _ = findCompletionCandidate(nested_candidates, "--staged") orelse return error.MissingCompletionCandidate;
    const trace_path = executor.lastCompletionTracePath() orelse return error.MissingCompletionTracePath;
    try std.testing.expectEqual(@as(usize, 4), trace_path.len);
    try std.testing.expectEqualStrings("sudo", trace_path[0]);
    try std.testing.expectEqualStrings("sudo", trace_path[1]);
    try std.testing.expectEqualStrings("git", trace_path[2]);
    try std.testing.expectEqualStrings("diff", trace_path[3]);
}

test "completion manifest precommand recursion is bounded" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "wrap",
        \\    "arguments": {
        \\      "states": [ { "name": "command", "rest": "command-line" } ]
        \\    }
        \\  }
        \\}
    );

    const source = "wrap wrap wrap wrap wrap wrap wrap wrap wrap echo";
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = std.testing.io });
    defer executor.freeCompletions(candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
    try std.testing.expect(executor.lastCompletionPrecommandDepthLimited());
}

test "completion manifest function providers lazy-load provider-only companions" {
    const root = "rush-completion-manifest-lazy-companion-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.rush", .data =
        \\RUSH_MANIFEST_COMPANION_LOADED=yes
        \\complete tool --subcommand companion-static
        \\__rush_complete_tool_targets() {
        \\  completion candidate target-one --kind plain
        \\}
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.targets": { "function": "__rush_complete_tool_targets" }
        \\    },
        \\    "options": [
        \\      { "long": "verbose" }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "index": 0, "provider": "tool.targets" }
        \\      ]
        \\    }
        \\  }
        \\}
    });

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_DIRS", "");
    try executor.setEnv("XDG_DATA_HOME", root);

    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.ensureLoaded(std.testing.io, &executor, "tool", "rush");

    const loaded_rules = executor.completionRules().len;
    try std.testing.expect(!executor.hasFunction("__rush_complete_tool_targets"));
    try std.testing.expect(executor.getEnv("RUSH_MANIFEST_COMPANION_LOADED") == null);

    const option_candidates = try executor.collectCompletionsForInput("tool --v", "tool --v".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(option_candidates);
    try expectCompletionCandidate(option_candidates, "--verbose");
    try std.testing.expect(!executor.hasFunction("__rush_complete_tool_targets"));
    try std.testing.expect(executor.getEnv("RUSH_MANIFEST_COMPANION_LOADED") == null);

    const argument_candidates = try executor.collectCompletionsForInput("tool ta", "tool ta".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(argument_candidates);
    try expectCompletionCandidate(argument_candidates, "target-one");
    try std.testing.expect(executor.hasFunction("__rush_complete_tool_targets"));
    try std.testing.expectEqualStrings("yes", executor.getEnv("RUSH_MANIFEST_COMPANION_LOADED").?);
    try std.testing.expectEqual(loaded_rules, executor.completionRules().len);

    const companion_static_candidates = try executor.collectCompletionsForInput("tool companion", "tool companion".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(companion_static_candidates);
    try expectNoCompletionCandidate(companion_static_candidates, "companion-static");
}

test "completion manifest builtin providers do not load companions" {
    const root = "rush-completion-manifest-builtin-no-companion-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.rush", .data =
        \\RUSH_BUILTIN_COMPANION_LOADED=yes
        \\complete tool --subcommand builtin-companion-static
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "builtin.variables": { "builtin": "variables" }
        \\    },
        \\    "options": [
        \\      { "long": "env", "value": { "name": "var", "provider": "builtin.variables" } }
        \\    ]
        \\  }
        \\}
    });

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_DATA_DIRS", "");
    try executor.setEnv("XDG_DATA_HOME", root);
    try executor.setEnv("RUSH_BUILTIN_PROVIDER_VAR", "1");

    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    try loader.ensureLoaded(std.testing.io, &executor, "tool", "rush");

    const variable_candidates = try executor.collectCompletionsForInput("tool --env RUSH_BUILTIN_PROVIDER", "tool --env RUSH_BUILTIN_PROVIDER".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(variable_candidates);
    try expectCompletionCandidate(variable_candidates, "RUSH_BUILTIN_PROVIDER_VAR");
    try std.testing.expect(executor.getEnv("RUSH_BUILTIN_COMPANION_LOADED") == null);

    const companion_static_candidates = try executor.collectCompletionsForInput("tool builtin", "tool builtin".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(companion_static_candidates);
    try expectNoCompletionCandidate(companion_static_candidates, "builtin-companion-static");
}

test "completion manifest semantic validation accepts resolved providers groups and reachable arguments" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "$schema": "https://rush.horse/completion/schema/v1.schema.json",
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.targets": { "function": "__rush_complete_tool_targets" }
        \\    },
        \\    "optionGroups": [
        \\      { "name": "mode", "exclusive": true }
        \\    ],
        \\    "options": [
        \\      { "long": "debug", "exclusiveGroup": "mode" },
        \\      { "long": "release", "exclusiveGroup": "mode" },
        \\      { "long": "help", "excludes": "everything" },
        \\      { "long": "all", "excludes": "operands" },
        \\      { "long": "raw", "excludes": ["--release"] },
        \\      { "long": "target", "value": { "name": "target", "provider": "tool.targets" } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "index": 0, "provider": "tool.targets" },
        \\        { "name": "extra", "index": 1, "grammar": { "kind": "list", "separator": ",", "item": { "provider": "tool.targets" } } }
        \\      ]
        \\    },
        \\    "subcommands": [
        \\      { "name": ["run", "r"], "aliases": ["execute"] }
        \\    ]
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(!diagnostics.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.items.len);
}

test "completion manifest semantic validation allows non-inherited option spelling conflicts" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "options": [
        \\      { "short": "C", "inherit": false, "value": { "name": "path" } }
        \\    ],
        \\    "subcommands": [
        \\      {
        \\        "name": "branch",
        \\        "options": [
        \\          { "short": "C", "description": "child-local meaning" }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(!diagnostics.hasErrors());
}

test "completion manifest semantic validation rejects invalid multi-value option sequences" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.values": { "values": ["one"] }
        \\    },
        \\    "options": [
        \\      {
        \\        "long": "pair",
        \\        "value": [
        \\          { "name": "first", "provider": "tool.values", "required": false },
        \\          { "name": "second", "provider": "tool.values" }
        \\        ]
        \\      },
        \\      {
        \\        "long": "style",
        \\        "value": [
        \\          { "name": "first", "provider": "tool.values" },
        \\          { "name": "second", "provider": "tool.values", "style": "equals" }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(diagnostics.hasErrors());
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[0].value[1].required: required option values cannot follow optional values");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[1].value[1].style: only the first option value may use non-detached styles");
}

test "completion manifest semantic validation rejects builtin provider options" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "builtin.files": { "builtin": "files", "options": { "extension": ".zig" } }
        \\    },
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "path", "provider": "builtin.files" }
        \\      ]
        \\    }
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(diagnostics.hasErrors());
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.providers.builtin.files.options: builtin provider options are not supported in completion manifest v1");
}

test "completion manifest semantic validation rejects invalid static enum providers" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.empty": { "values": [] },
        \\      "tool.duplicate": { "values": ["auto", { "value": "auto" }] },
        \\      "tool.mixed": { "function": "__tool_modes", "values": ["auto"] }
        \\    },
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "mode", "provider": "tool.empty" }
        \\      ]
        \\    }
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(diagnostics.hasErrors());
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.providers.tool.empty.values: static provider values must not be empty");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.providers.tool.duplicate.values[1]: duplicate static provider value 'auto'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.providers.tool.mixed: provider must define exactly one of function, builtin, or values");
}

test "completion manifest semantic validation checks optionValue conditions" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.formats": { "values": ["json", { "value": "table" }] },
        \\      "tool.args": { "values": ["arg"] }
        \\    },
        \\    "options": [
        \\      { "long": "verbose" },
        \\      { "long": "format", "value": { "name": "format", "grammar": { "kind": "enum", "values": ["json", "table"] } } },
        \\      { "long": "provider-format", "value": { "name": "format", "provider": "tool.formats" } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "bad-flag", "provider": "tool.args", "when": { "optionValue": { "--verbose": "json" } } },
        \\        { "name": "bad-grammar", "provider": "tool.args", "when": { "optionValue": { "--format": "yaml" } } },
        \\        { "name": "bad-provider", "provider": "tool.args", "when": { "optionValue": { "--provider-format": ["xml"] } } }
        \\      ]
        \\    }
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(diagnostics.hasErrors());
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.arguments.states[0].when.optionValue.--verbose: option selector '--verbose' does not take a value");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.arguments.states[1].when.optionValue.--format: option value literal 'yaml' is not in the option enum");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.arguments.states[2].when.optionValue.--provider-format[0]: option value literal 'xml' is not in the option enum");
}

test "completion manifest semantic validation reports clear invalid manifest diagnostics" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "$schema": "https://rush.horse/completion/schema/v2.schema.json",
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "platforms": ["bogus"],
        \\    "variantProbe": { "args": ["--version"], "matches": { "gnu": "", "missing": "x" } },
        \\    "options": [
        \\      { "long": "verbose" },
        \\      { "long": "verbose" },
        \\      { "long": "mode", "exclusiveGroup": "missing" },
        \\      { "long": "target", "value": { "name": "target", "provider": "missing.provider" } },
        \\      { "long": "self", "excludes": ["--self"] },
        \\      { "long": "bad", "excludes": ["--missing"] },
        \\      { "long": "bare", "excludes": "--verbose" }
        \\    ],
        \\    "variants": {
        \\      "gnu": { "options": [ { "long": "verbose" } ] }
        \\    },
        \\    "subcommands": [
        \\      { "name": ["run", "r"] },
        \\      { "name": "test", "aliases": ["r"] }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "index": 1 },
        \\        { "name": "extra", "provider": "missing.provider" }
        \\      ]
        \\    }
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(diagnostics.hasErrors());
    try expectCompletionManifestDiagnostic(diagnostics, .warning, "$schema: references Rush completion schema v2, but manifestVersion is 1");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[1]: duplicate option spelling '--verbose'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[2].exclusiveGroup: undefined option group 'missing'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[3].value.provider: unknown provider 'missing.provider'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[4].excludes[0]: option must not exclude itself ('--self')");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[5].excludes[0]: unknown option selector '--missing'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[6].excludes: bare excludes string must be 'operands' or 'everything' (use an array for option selectors)");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.subcommands[1].aliases[0]: duplicate subcommand name or alias 'r'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.arguments.states[0].index: argument state 'target' is unreachable");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.platforms[0]: unknown platform 'bogus'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.variantProbe.matches.gnu: empty pattern is only allowed for the final fallback");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.variantProbe.matches.missing: unknown variant 'missing'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.variants.gnu.options[0]: duplicate option spelling '--verbose'");
}

test "completion manifest semantic validation rejects invalid provider arrays" {
    var diagnostics = try validateCompletionManifestContents(std.testing.allocator,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.values": { "values": ["ok"] }
        \\    },
        \\    "options": [
        \\      { "long": "target", "value": { "name": "target", "provider": ["missing.provider", "tool.values"] } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "provider": ["tool.values", "tool.values"] }
        \\      ]
        \\    }
        \\  }
        \\}
    );
    defer diagnostics.deinit();

    try std.testing.expect(diagnostics.hasErrors());
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.options[0].value.provider[0]: unknown provider 'missing.provider'");
    try expectCompletionManifestDiagnostic(diagnostics, .err, "command.arguments.states[0].provider[1]: duplicate provider ref 'tool.values'");
}

test "completion manifest semantic validation rejects unsupported versions before compiling rules" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try std.testing.expectError(error.CompletionManifestSemanticValidationFailed, loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 2,
        \\  "command": {
        \\    "name": "tool",
        \\    "options": [
        \\      { "long": "verbose" }
        \\    ]
        \\  }
        \\}
    ));
    try std.testing.expectEqual(@as(usize, 0), executor.completionRules().len);
}

test "completion manifest semantic validation rejects duplicates before compiling rules" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    try std.testing.expectError(error.CompletionManifestSemanticValidationFailed, loadCompletionManifest(std.testing.allocator, &executor,
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "options": [
        \\      { "long": "verbose" },
        \\      { "long": "verbose" }
        \\    ]
        \\  }
        \\}
    ));
    try std.testing.expectEqual(@as(usize, 0), executor.completionRules().len);
}

fn expectCompletionManifestDiagnostic(diagnostics: CompletionManifestDiagnostics, severity: CompletionManifestDiagnosticSeverity, needle: []const u8) !void {
    for (diagnostics.items.items) |diagnostic| {
        if (diagnostic.severity == severity and std.mem.indexOf(u8, diagnostic.message, needle) != null) return;
    }
    return error.MissingCompletionManifestDiagnostic;
}

fn expectCompletionCandidate(candidates: []const completion_model.Candidate, value: []const u8) !void {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return;
    }
    return error.MissingCompletionCandidate;
}

fn findCompletionCandidate(candidates: []const completion_model.Candidate, value: []const u8) ?completion_model.Candidate {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return candidate;
    }
    return null;
}

fn expectNoCompletionCandidate(candidates: []const completion_model.Candidate, value: []const u8) !void {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return error.UnexpectedCompletionCandidate;
    }
}

test "completion cache keys include completion generation" {
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();

    var candidates = [_]completion_model.Candidate{.{ .value = "checkout", .replace_start = 4, .replace_end = 6 }};
    try cache.put("git ch", 6, "/tmp/project", 1, &candidates);

    try std.testing.expect(cache.get("git ch", 6, "/tmp/project", 0) == null);
    try std.testing.expect(cache.get("git ch", 6, "/tmp/project", 2) == null);
    const cached = cache.get("git ch", 6, "/tmp/project", 1) orelse return error.MissingCompletionCacheEntry;
    try std.testing.expectEqualStrings("checkout", cached[0].value);
}

test "completion cache refresh updates entries in background" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var setup_result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\__rush_complete_git() { completion candidate fresh --kind subcommand; }
        \\complete git --subcommands --function __rush_complete_git
    , .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), setup_result.status);

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();
    var stale = [_]completion_model.Candidate{.{ .value = "stale", .replace_start = 4, .replace_end = 5 }};
    try cache.put("git f", 5, "/tmp/project", executor.completionGeneration(), &stale);

    try cache.startRefresh(&executor, &history, std.testing.io, "git f", 5, "/tmp/project", executor.completionGeneration());
    cache.waitForRefresh();

    const cached = cache.get("git f", 5, "/tmp/project", executor.completionGeneration()) orelse return error.MissingCompletionCacheEntry;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqualStrings("fresh", cached[0].value);
}

test "interactive completion uses semantic executor path for commands variables and paths" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("RUSH_COMPLETION_VAR", "ok");

    const command_completions = try executor.collectCompletionsForInput("ec", 2, .{ .io = std.testing.io });
    defer executor.freeCompletions(command_completions);
    try std.testing.expect(hasCompletionCandidate(command_completions, "echo"));

    var variable_setup = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\__rush_complete_variables() { completion variables; }
        \\complete echo --argument --function __rush_complete_variables
    , .{ .io = std.testing.io });
    defer variable_setup.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), variable_setup.status);
    const variable_completions = try executor.collectCompletionsForInput("echo RUSH", "echo RUSH".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(variable_completions);
    try std.testing.expect(hasCompletionCandidate(variable_completions, "RUSH_COMPLETION_VAR"));

    const path = "rush-complete-path.tmp";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var path_setup = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\__rush_complete_paths() { completion files; }
        \\complete cat --argument --function __rush_complete_paths
    , .{ .io = std.testing.io });
    defer path_setup.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), path_setup.status);
    const path_completions = try executor.collectCompletionsForInput("cat rush-complete", "cat rush-complete".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(path_completions);
    try std.testing.expect(hasCompletionCandidate(path_completions, path));
}

test "vi pathname expansions use implicit star and directory marks" {
    const dir_path = "rush-vi-path-expansion-dir";
    const file_path = "rush-vi-path-expansion-file.tmp";
    std.Io.Dir.cwd().createDir(std.testing.io, dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = "" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var implicit = try viPathnameExpansionsForWord(std.testing.allocator, std.testing.io, "rush-vi-path-expansion-");
    defer implicit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), implicit.items.len);
    try std.testing.expectEqualStrings(dir_path ++ "/", implicit.items[0]);
    try std.testing.expectEqualStrings(file_path, implicit.items[1]);

    var glob = try viPathnameExpansionsForWord(std.testing.allocator, std.testing.io, "rush-vi-path-expansion-*.tmp");
    defer glob.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), glob.items.len);
    try std.testing.expectEqualStrings(file_path, glob.items[0]);
}

test "vi pathname expansions honor quoted glob literals and shell expansions" {
    const literal_star = "rush-vi-quoted-*.tmp";
    const glob_match = "rush-vi-quoted-a.tmp";
    const param_match = "rush-vi-param-value.tmp";
    const split_param_a = "rush-vi-split-param-a.tmp";
    const split_param_b = "rush-vi-split-param-b.tmp";
    const split_command_a = "rush-vi-split-command-a.tmp";
    const split_command_b = "rush-vi-split-command-b.tmp";
    const arith_match = "rush-vi-arith-3.tmp";
    const command_match = "rush-vi-command-value.tmp";
    inline for (.{ literal_star, glob_match, param_match, split_param_a, split_param_b, split_command_a, split_command_b, arith_match, command_match }) |path| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    }
    defer {
        inline for (.{ literal_star, glob_match, param_match, split_param_a, split_param_b, split_command_a, split_command_b, arith_match, command_match }) |path| {
            std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        }
    }

    var escaped = try viPathnameExpansionsForWord(std.testing.allocator, std.testing.io, "rush-vi-quoted-\\*");
    defer escaped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), escaped.items.len);
    try std.testing.expectEqualStrings(literal_star, escaped.items[0]);

    var single_quoted = try viPathnameExpansionsForWord(std.testing.allocator, std.testing.io, "'rush-vi-quoted-*'");
    defer single_quoted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), single_quoted.items.len);
    try std.testing.expectEqualStrings(literal_star, single_quoted.items[0]);

    var quoted_default = try viPathnameExpansionsForWord(std.testing.allocator, std.testing.io, "${RUSH_MISSING:-\"rush-vi-quoted-*\"}");
    defer quoted_default.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), quoted_default.items.len);
    try std.testing.expectEqualStrings(literal_star, quoted_default.items[0]);

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("RUSH_VI_PREFIX", "rush-vi-param-value");

    var param_pattern = try executor.expandViPathnamePattern(std.testing.allocator, std.testing.io, "$RUSH_VI_PREFIX");
    defer param_pattern.deinit(std.testing.allocator);
    var param = try viPathnameExpansions(std.testing.allocator, std.testing.io, param_pattern);
    defer param.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), param.items.len);
    try std.testing.expectEqualStrings(param_match, param.items[0]);

    try executor.setEnv("RUSH_VI_SPLIT_PREFIXES", "rush-vi-split-param-a rush-vi-split-param-b");
    var split_param_patterns = try executor.expandViPathnamePatterns(std.testing.allocator, std.testing.io, "$RUSH_VI_SPLIT_PREFIXES");
    defer split_param_patterns.deinit(std.testing.allocator);
    var split_param = try viPathnameExpansionsForPatterns(std.testing.allocator, std.testing.io, split_param_patterns.items);
    defer split_param.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), split_param.items.len);
    try std.testing.expectEqualStrings(split_param_a, split_param.items[0]);
    try std.testing.expectEqualStrings(split_param_b, split_param.items[1]);

    var arith_pattern = try executor.expandViPathnamePattern(std.testing.allocator, std.testing.io, "rush-vi-arith-$((1 + 2))");
    defer arith_pattern.deinit(std.testing.allocator);
    var arith = try viPathnameExpansions(std.testing.allocator, std.testing.io, arith_pattern);
    defer arith.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), arith.items.len);
    try std.testing.expectEqualStrings(arith_match, arith.items[0]);

    var command_pattern = try executor.expandViPathnamePattern(std.testing.allocator, std.testing.io, "$(printf rush-vi-command-value)");
    defer command_pattern.deinit(std.testing.allocator);
    var command = try viPathnameExpansions(std.testing.allocator, std.testing.io, command_pattern);
    defer command.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), command.items.len);
    try std.testing.expectEqualStrings(command_match, command.items[0]);

    var split_command_patterns = try executor.expandViPathnamePatterns(std.testing.allocator, std.testing.io, "$(printf 'rush-vi-split-command-a rush-vi-split-command-b')");
    defer split_command_patterns.deinit(std.testing.allocator);
    var split_command = try viPathnameExpansionsForPatterns(std.testing.allocator, std.testing.io, split_command_patterns.items);
    defer split_command.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), split_command.items.len);
    try std.testing.expectEqualStrings(split_command_a, split_command.items[0]);
    try std.testing.expectEqualStrings(split_command_b, split_command.items[1]);
}

test "interactive semantic diagnostics render spans without message line" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var setup_result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\complete git --subcommand commit
    , .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), setup_result.status);

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();
    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    var completion_context: InteractiveCompletionContext = .{ .executor = &executor, .history = &history, .cache = &cache, .loader = &loader, .io = std.testing.io, .cwd = "." };

    const diagnostic = try diagnoseInteractiveLine(&completion_context, std.testing.allocator, std.testing.io, "git comit ") orelse return error.MissingDiagnostic;
    defer diagnostic.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("", diagnostic.line);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.spans.len);
    try std.testing.expectEqual(@as(usize, 4), diagnostic.spans[0].start);
    try std.testing.expectEqual(@as(usize, 9), diagnostic.spans[0].end);
    try std.testing.expectEqual(line_editor.DiagnosticSeverity.err, diagnostic.spans[0].severity);
}

test "interactive diagnostics leave incomplete input for PS2 continuation" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();
    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    var completion_context: InteractiveCompletionContext = .{ .executor = &executor, .history = &history, .cache = &cache, .loader = &loader, .io = std.testing.io, .cwd = "." };

    try std.testing.expect(try diagnoseInteractiveLine(&completion_context, std.testing.allocator, std.testing.io, "echo \"abc") == null);
    try std.testing.expect(try diagnoseInteractiveLine(&completion_context, std.testing.allocator, std.testing.io, "echo one |") == null);
}

fn hasCompletionCandidate(candidates: []const completion_model.Candidate, value: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return true;
    }
    return false;
}

test "completion application handles no candidates" {
    const candidates = [_]completion_model.Candidate{};
    const application = try completion_model.applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(completion_model.Application.none, application);
}

test "completion application inserts one candidate" {
    const candidates = [_]completion_model.Candidate{.{
        .value = "status",
        .kind = .subcommand,
        .replace_start = 4,
        .replace_end = 6,
        .append_space = true,
    }};
    const application = try completion_model.applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqual(@as(usize, 4), edit.replace_start);
    try std.testing.expectEqual(@as(usize, 6), edit.replace_end);
    try std.testing.expectEqualStrings("status", edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "completion application reports shared-prefix candidates as ambiguous" {
    const candidates = [_]completion_model.Candidate{
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 },
    };
    const application = try completion_model.applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("checkout", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("cherry-pick", application.ambiguous[1].value);
}

test "completion application reports ambiguous candidates" {
    const candidates = [_]completion_model.Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 4 },
        .{ .value = "diff", .replace_start = 4, .replace_end = 4 },
    };
    const application = try completion_model.applyCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
}

test "completion ranking prefers recent successful same-cwd history" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.addRecord(.{ .cmd = "git checkout old", .status = 0, .cwd = "/other" });
    try history.addRecord(.{ .cmd = "git checkout cherry-pick", .status = 1, .cwd = "/repo" });
    try history.addRecord(.{ .cmd = "git checkout checkout", .status = 0, .cwd = "/repo" });

    var candidates = [_]completion_model.Candidate{
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
    };
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "git ch", .engineDefault());

    try std.testing.expectEqualStrings("checkout", candidates[0].value);
    try std.testing.expectEqualStrings("cherry-pick", candidates[1].value);
}

test "completion ranking falls back to lexical order" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    var candidates = [_]completion_model.Candidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 4 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 4 },
    };
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "git ", .engineDefault());

    try std.testing.expectEqualStrings("checkout", candidates[0].value);
    try std.testing.expectEqualStrings("status", candidates[1].value);
}

test "completion ranking prefers prefix matches before fuzzy matches" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.addRecord(.{ .cmd = "age-inspect file", .status = 0, .cwd = "/repo" });

    var candidates = [_]completion_model.Candidate{
        .{ .value = "age-inspect", .kind = .command, .replace_start = 0, .replace_end = 2 },
        .{ .value = "git", .kind = .command, .replace_start = 0, .replace_end = 2 },
    };
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "gi", .engineDefault());

    try std.testing.expectEqualStrings("git", candidates[0].value);
    try std.testing.expectEqualStrings("age-inspect", candidates[1].value);
}

test "completion ranking sorts equal scores by display label" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    var candidates = [_]completion_model.Candidate{
        .{ .value = "status", .display = "working tree", .replace_start = 4, .replace_end = 4 },
        .{ .value = "checkout", .display = "branch checkout", .replace_start = 4, .replace_end = 4 },
        .{ .value = "add", .replace_start = 4, .replace_end = 4 },
    };
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "git ", .engineDefault());

    try std.testing.expectEqualStrings("add", candidates[0].value);
    try std.testing.expectEqualStrings("checkout", candidates[1].value);
    try std.testing.expectEqualStrings("status", candidates[2].value);
}

test "completion debug output shows context provider candidates and application" {
    const root = "rush-debug-config-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "rush-debug-config-test/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "rush-debug-config-test/rush/config.rush", .data =
        \\__rush_complete_git() {
        \\  completion candidate status --description 'show status' --kind subcommand
        \\  completion candidate checkout --description 'switch branches' --kind subcommand
        \\}
        \\complete git --subcommands --function __rush_complete_git
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    const output = try completionDebugOutput(std.testing.allocator, std.testing.io, &env, "git st");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "command: git") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "prefix: st") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "matcher-policy:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mode: fuzzy") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "value: status") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "match-rank: prefix") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "suppression-reason: no_match") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "replacement: status") != null);
}

test "completion debug JSON includes candidate suffix fields" {
    const root = "rush-debug-suffix-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data =
        \\__rush_complete_git() {
        \\  completion candidate status --suffix , --removable-suffix --tag statuses
        \\}
        \\complete git --argument --function __rush_complete_git
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "git st");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const candidate = object.get("candidates").?.array.items[0].object;
    try std.testing.expectEqualStrings("status", candidate.get("value").?.string);
    try std.testing.expectEqualStrings("statuses", candidate.get("tag").?.string);
    try std.testing.expectEqualStrings(",", candidate.get("suffix").?.string);
    try std.testing.expect(candidate.get("removableSuffix").?.bool);
    try std.testing.expectEqualStrings("status,", candidate.get("insert").?.string);
    const application = object.get("application").?.object;
    try std.testing.expectEqualStrings("status,", application.get("replacement").?.string);
    try std.testing.expectEqualStrings(",", application.get("suffix").?.string);
    try std.testing.expect(application.get("removableSuffix").?.bool);
}

test "completion debug output shows semantic structured context and rules" {
    const root = "rush-debug-structured-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "rush-debug-structured-test/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "rush-debug-structured-test/rush/config.rush", .data =
        \\complete git --subcommand commit --description commit
        \\complete 'git commit' --option --long amend --description amend
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    const output = try completionDebugOutput(std.testing.allocator, std.testing.io, &env, "git commit --a");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "semantic:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "semantic:\n  parsed-options:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "semantic:  parsed-options:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "parser-offset: 0\n  parsed-options:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "parser-offset: 0  parsed-options:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "root: git") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "path: commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "position: option") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "kind: option") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "value: --amend") != null);
}

test "completion debug output exposes active argument state" {
    const root = "rush-debug-argument-state-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data =
        \\__tool_actions() { completion candidate create; }
        \\__tool_names() { completion candidate new-service; }
        \\complete tool --argument --state action --function __tool_actions
        \\complete tool --argument --state name --after create --function __tool_names
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    const text_output = try completionDebugOutput(std.testing.allocator, std.testing.io, &env, "tool create n");
    defer std.testing.allocator.free(text_output);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "argument-state: name") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "after-value: create") != null);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool create n");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("name", object.get("context").?.object.get("argumentState").?.string);
    try std.testing.expectEqualStrings("name", object.get("semantic").?.object.get("argumentState").?.string);
    const context_operands = object.get("context").?.object.get("operands").?.array.items;
    try std.testing.expectEqualStrings("create", context_operands[0].object.get("value").?.string);
    try std.testing.expectEqualStrings("action", context_operands[0].object.get("state").?.string);
}

test "completion debug JSON reports decomposed short option cluster sources" {
    const root = "rush-debug-short-cluster-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data =
        \\complete tool --option --short a --long all
        \\complete tool --option --short b --long brief
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool -ab ");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const semantic_options = parsed.value.object.get("semantic").?.object.get("parsedOptions").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), semantic_options.len);
    try std.testing.expectEqualStrings("-a", semantic_options[0].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("-ab", semantic_options[0].object.get("from").?.string);
    try std.testing.expectEqualStrings("all", semantic_options[0].object.get("key").?.string);
    try std.testing.expectEqualStrings("-b", semantic_options[1].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("-ab", semantic_options[1].object.get("from").?.string);
}

test "completion debug output reports dynamic provider failures" {
    const root = "rush-debug-provider-failure-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data =
        \\__rush_complete_tool() {
        \\  completion candidate stale
        \\  echo provider failed >&2
        \\  false
        \\}
        \\complete tool --argument --function __rush_complete_tool
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    const output = try completionDebugOutput(std.testing.allocator, std.testing.io, &env, "tool st");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "provider-diagnostics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "function: __rush_complete_tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "status: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "provider failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "value: stale") == null);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool st");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const diagnostics = parsed.value.object.get("providerDiagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("__rush_complete_tool", diagnostics[0].object.get("function").?.string);
    try std.testing.expectEqual(@as(i64, 1), diagnostics[0].object.get("status").?.integer);
}

test "completion debug output reports missing manifest provider functions" {
    const root = "rush-debug-missing-manifest-provider-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.missing": { "function": "__rush_complete_tool_missing" }
        \\    },
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "target", "index": 0, "provider": "tool.missing" }
        \\      ]
        \\    }
        \\  }
        \\}
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_DIRS", "");
    try env.put("XDG_DATA_HOME", root);

    const output = try completionDebugOutput(std.testing.allocator, std.testing.io, &env, "tool tar");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "source: manifest") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "provider-diagnostics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "function: __rush_complete_tool_missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CompletionProviderFunctionNotFound") != null);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool tar");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const diagnostics = parsed.value.object.get("providerDiagnostics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("__rush_complete_tool_missing", diagnostics[0].object.get("function").?.string);
    try std.testing.expectEqualStrings("CompletionProviderFunctionNotFound", diagnostics[0].object.get("error").?.string);
}

test "completion debug output exposes manifest source and JSON decision state" {
    const root = "rush-debug-manifest-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.targets": { "function": "__rush_complete_tool_targets" }
        \\    },
        \\    "optionGroups": [
        \\      { "name": "mode", "exclusive": true }
        \\    ],
        \\    "options": [
        \\      { "long": "debug", "exclusiveGroup": "mode" },
        \\      { "long": "release", "exclusiveGroup": "mode" },
        \\      { "long": "all", "excludes": "operands" },
        \\      { "long": "raw", "excludes": ["--release"] }
        \\    ],
        \\    "subcommands": [
        \\      {
        \\        "name": "run",
        \\        "arguments": {
        \\          "terminator": "--",
        \\          "states": [
        \\            { "name": "target", "provider": "tool.targets" }
        \\          ]
        \\        }
        \\      }
        \\    ]
        \\  }
        \\}
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_DIRS", "");
    try env.put("XDG_DATA_HOME", root);

    const text_output = try completionDebugOutput(std.testing.allocator, std.testing.io, &env, "tool run --debug ta");
    defer std.testing.allocator.free(text_output);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "source: manifest") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "manifest-path: " ++ root ++ "/rush/completions/tool.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "manifest-version: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "manifest:\n  loaded: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "command-path: tool run") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "active-argument-state:\n    name: target") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "matched-providers:\n    - id: tool.targets") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "candidate-count: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "fallback:\n    kind: providerNoCandidates") != null);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool run --debug ta");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const manifest = object.get("manifest").?.object;
    try std.testing.expect(manifest.get("loaded").?.bool);
    try std.testing.expectEqualStrings(root ++ "/rush/completions/tool.json", manifest.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 1), manifest.get("manifestVersion").?.integer);
    try std.testing.expect(manifest.get("platformGate").?.object.get("allowed").?.bool);
    const semantic_options = object.get("semantic").?.object.get("parsedOptions").?.array.items;
    try std.testing.expectEqualStrings("--debug", semantic_options[0].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("mode", semantic_options[0].object.get("exclusiveGroup").?.string);
    const context_options = object.get("context").?.object.get("parsedOptions").?.array.items;
    try std.testing.expectEqualStrings("--debug", context_options[0].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("--debug", manifest.get("parsedOptions").?.array.items[0].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("target", manifest.get("activeArgumentState").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("tool.targets", manifest.get("matchedProviders").?.array.items[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 0), manifest.get("matchedProviders").?.array.items[0].object.get("candidateCount").?.integer);
    try std.testing.expectEqualStrings("providerNoCandidates", manifest.get("fallback").?.object.get("kind").?.string);
    const generic_suppressed = object.get("suppressedOptions").?.array.items;
    try std.testing.expectEqualStrings("--release", generic_suppressed[1].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("exclusive_group", generic_suppressed[1].object.get("reason").?.string);
    try std.testing.expectEqualStrings("mode", generic_suppressed[1].object.get("group").?.string);
    const suppressed = manifest.get("suppressedOptions").?.array.items;
    try std.testing.expectEqualStrings("--debug", suppressed[0].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("alreadyPresent", suppressed[0].object.get("reason").?.string);
    try std.testing.expectEqualStrings("--release", suppressed[1].object.get("spelling").?.string);
    try std.testing.expectEqualStrings("exclusiveGroup", suppressed[1].object.get("reason").?.string);

    const terminated_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool run -- --debug");
    defer std.testing.allocator.free(terminated_output);
    var terminated = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, terminated_output, .{});
    defer terminated.deinit();
    try std.testing.expect(terminated.value.object.get("semantic").?.object.get("optionsTerminated").?.bool);

    const excluded_option_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool run --raw --");
    defer std.testing.allocator.free(excluded_option_output);
    var excluded_option = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, excluded_option_output, .{});
    defer excluded_option.deinit();
    const excluded_options = excluded_option.value.object.get("manifest").?.object.get("suppressedOptions").?.array.items;
    var found_excluded_option = false;
    for (excluded_options) |suppression| {
        const object_value = suppression.object;
        if (std.mem.eql(u8, object_value.get("spelling").?.string, "--release")) {
            try std.testing.expectEqualStrings("excluded", object_value.get("reason").?.string);
            try std.testing.expectEqualStrings("--raw", object_value.get("by").?.string);
            try std.testing.expectEqualStrings("--release", object_value.get("exclusion").?.string);
            found_excluded_option = true;
        }
    }
    try std.testing.expect(found_excluded_option);

    const excluded_operands_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool run --all ta");
    defer std.testing.allocator.free(excluded_operands_output);
    var excluded_operands = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, excluded_operands_output, .{});
    defer excluded_operands.deinit();
    const excluded_operands_manifest = excluded_operands.value.object.get("manifest").?.object;
    try std.testing.expect(excluded_operands_manifest.get("activeArgumentState").? == .null);
    const suppressed_operands = excluded_operands_manifest.get("suppressedOperands").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), suppressed_operands.len);
    try std.testing.expectEqualStrings("excluded", suppressed_operands[0].object.get("reason").?.string);
    try std.testing.expectEqualStrings("--all", suppressed_operands[0].object.get("by").?.string);
    try std.testing.expectEqualStrings("operands", suppressed_operands[0].object.get("exclusion").?.string);
}

test "completion debug JSON traces manifest optionValue condition results" {
    const root = "rush-debug-manifest-option-value-condition-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.jsonArgs": { "values": ["jq-filter"] },
        \\      "tool.defaultArgs": { "values": ["input"] }
        \\    },
        \\    "options": [
        \\      { "long": "format", "value": { "name": "format", "grammar": { "kind": "enum", "values": ["json", "table"] } } }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "json-arg", "provider": "tool.jsonArgs", "when": { "optionValue": { "--format": ["json"] } } },
        \\        { "name": "default-arg", "provider": "tool.defaultArgs" }
        \\      ]
        \\    }
        \\  }
        \\}
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_DIRS", "");
    try env.put("XDG_DATA_HOME", root);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool --format json jq");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();

    const active_state = parsed.value.object.get("manifest").?.object.get("activeArgumentState").?.object;
    try std.testing.expectEqualStrings("json-arg", active_state.get("name").?.string);
    const condition = active_state.get("conditionResults").?.array.items[0].object;
    try std.testing.expectEqualStrings("when", condition.get("field").?.string);
    try std.testing.expectEqualStrings("optionValue", condition.get("kind").?.string);
    try std.testing.expectEqualStrings("--format", condition.get("selector").?.string);
    try std.testing.expectEqualStrings("json", condition.get("values").?.array.items[0].string);
    try std.testing.expect(condition.get("matched").?.bool);
}

test "completion debug JSON traces nested manifest condition results" {
    const root = "rush-debug-manifest-nested-condition-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "tool",
        \\    "providers": {
        \\      "tool.first": { "values": ["first"] },
        \\      "tool.next": { "values": ["next"] }
        \\    },
        \\    "options": [
        \\      { "long": "format", "short": "f", "value": { "name": "format", "grammar": { "kind": "enum", "values": ["json", "table"] } } },
        \\      { "long": "dry-run" },
        \\      { "long": "skip" }
        \\    ],
        \\    "arguments": {
        \\      "states": [
        \\        { "name": "first", "provider": "tool.first" },
        \\        { "name": "next", "provider": "tool.next", "after": { "all": [
        \\          { "previousState": "first" },
        \\          { "optionValue": { "--format": ["json"] } },
        \\          { "optionPresent": "--dry-run" },
        \\          { "optionAbsent": "--skip" }
        \\        ] } }
        \\      ]
        \\    }
        \\  }
        \\}
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_DIRS", "");
    try env.put("XDG_DATA_HOME", root);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "tool -f json --dry-run first n");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();

    const active_state = parsed.value.object.get("manifest").?.object.get("activeArgumentState").?.object;
    try std.testing.expectEqualStrings("next", active_state.get("name").?.string);
    var saw_previous_state = false;
    var saw_option_value = false;
    var saw_option_present = false;
    var saw_option_absent = false;
    for (active_state.get("conditionResults").?.array.items) |item| {
        const condition = item.object;
        try std.testing.expect(condition.get("matched").?.bool);
        const kind = condition.get("kind").?.string;
        if (std.mem.eql(u8, kind, "previousState")) saw_previous_state = true;
        if (std.mem.eql(u8, kind, "optionValue")) saw_option_value = true;
        if (std.mem.eql(u8, kind, "optionPresent")) saw_option_present = true;
        if (std.mem.eql(u8, kind, "optionAbsent")) saw_option_absent = true;
    }
    try std.testing.expect(saw_previous_state);
    try std.testing.expect(saw_option_value);
    try std.testing.expect(saw_option_present);
    try std.testing.expect(saw_option_absent);
}

test "completion debug JSON reports manifest variant selection" {
    const root = "rush-debug-manifest-variant-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/varianttool.json", .data =
        \\{
        \\  "manifestVersion": 1,
        \\  "command": {
        \\    "name": "varianttool",
        \\    "variantProbe": { "args": ["--version"], "matches": { "gnu": "GNU", "unix": "" } },
        \\    "variants": {
        \\      "gnu": { "options": [ { "long": "color" } ] },
        \\      "unix": { "options": [ { "long": "classify" } ] }
        \\    }
        \\  }
        \\}
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_DIRS", "");
    try env.put("XDG_DATA_HOME", root);

    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, "varianttool --");
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const manifest = parsed.value.object.get("manifest").?.object;
    const variant = manifest.get("variant").?.object;
    try std.testing.expectEqualStrings("unix", variant.get("selected").?.string);
    try std.testing.expect(variant.get("probed").?.bool);
    try std.testing.expect(!variant.get("cached").?.bool);
    try std.testing.expect(manifest.get("platformGate").?.object.get("allowed").?.bool);
}

test "completion debug output exposes active structured value segment" {
    const root = "rush-debug-value-segment-test";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/completions");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/completions/tool.rush", .data =
        \\__tool_modes() {
        \\  completion candidate slow
        \\}
        \\complete tool --option --long mode --value-name mode
        \\complete tool --option-value --long mode --function __tool_modes --list-separator ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_DATA_DIRS", "");
    try env.put("XDG_DATA_HOME", root);

    const source = "tool --mode=fast,sl";
    const json_output = try completionDebugJsonOutput(std.testing.allocator, std.testing.io, &env, source);
    defer std.testing.allocator.free(json_output);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_output, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("sl", object.get("context").?.object.get("valueSegment").?.string);
    try std.testing.expectEqualStrings(",", object.get("semantic").?.object.get("valueSeparator").?.string);
    try std.testing.expectEqual(@as(i64, 17), object.get("application").?.object.get("replaceStart").?.integer);
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

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("$ hi\n$ $ ", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runReplInput stops when exit builtin requests shell exit" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "echo before\nexit 7\necho after\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("$ before\n$ ", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runReplInput wires fc to interactive history without recording fc itself" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\printf 'one\n'
        \\printf 'two\n'
        \\fc -l -n
        \\fc -s one=again 1
        \\fc -l -n
        \\exit
        \\
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("$ one\n$ two\n$ printf 'one\\n'\nprintf 'two\\n'\n$ again\n$ printf 'one\\n'\nprintf 'two\\n'\nprintf 'again\\n'\n$ ", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive notify schedules editor job notification polling" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();
    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    var context: InteractiveCompletionContext = .{
        .executor = &executor,
        .history = &history,
        .cache = &cache,
        .loader = &loader,
        .io = std.testing.io,
    };

    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
    try executor.background_jobs.append(std.testing.allocator, .{
        .id = 1,
        .pid = 999_999,
        .command = try std.testing.allocator.dupe(u8, "sleep 1"),
        .child = undefined,
    });
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));

    executor.shell_options.notify = true;
    try std.testing.expectEqual(@as(?u64, immediate_notify_poll_ms), try nextInteractiveIntervalMs(&context, std.testing.io));

    executor.background_jobs.items[0].state = .done;
    executor.background_jobs.items[0].notified_state = .done;
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
}

test "interactive hooks dispatch pending real signal trap" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var setup = try runScriptWithExecutor(std.testing.allocator, &executor, "trap 'echo term-trap' TERM", .{ .io = std.testing.io, .allow_external = true, .interactive = true });
    defer setup.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), setup.status);

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();
    var loader = CompletionScriptLoader.init(std.testing.allocator);
    defer loader.deinit();
    var context: InteractiveCompletionContext = .{
        .executor = &executor,
        .history = &history,
        .cache = &cache,
        .loader = &loader,
        .io = std.testing.io,
    };

    try std.posix.raise(.TERM);
    const hook_result = try runInteractiveIntervalHooks(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("term-trap\n", hook_result.output);
    try std.testing.expect(hook_result.refresh_prompt);
    try std.testing.expect(!hook_result.stop);
}

test "interactive signal handlers catch interrupt quit and terminate" {
    var handlers = installInteractiveSignalHandlers();
    defer handlers.restore();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, null, &current);
    try std.testing.expect(current.handler.handler != null);
    try std.testing.expect(current.handler.handler.? == handleInteractiveSignal);
    std.posix.sigaction(.QUIT, null, &current);
    try std.testing.expect(current.handler.handler != null);
    try std.testing.expect(current.handler.handler.? == handleInteractiveSignal);
    std.posix.sigaction(.TERM, null, &current);
    try std.testing.expect(current.handler.handler != null);
    try std.testing.expect(current.handler.handler.? == handleInteractiveSignal);
}

test "interactive interrupt runs INT trap" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var setup = try runScriptWithExecutor(std.testing.allocator, &executor, "trap 'echo trapped' INT", .{ .io = std.testing.io, .allow_external = true, .interactive = true });
    defer setup.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), setup.status);

    var result = (try runInteractiveInterruptTrap(std.testing.io, &executor, "rush", .{})) orelse return error.MissingTrapResult;
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("trapped\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string operands set the command name and positional parameters" {
    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo $0:$#:$1:$2; echo \"$@\"",
        .{ .io = std.testing.io, .arg_zero = "myname" },
        null,
        &.{ "a", "b c" },
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("myname:2:a:b c\na b c\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string invocation preserves trailing EOF backslash literal" {
    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo a\\",
        .{ .io = std.testing.io, .arg_zero = "rush" },
        null,
        &.{},
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\\\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string Bash source operands temporarily override positionals" {
    const path = "rush-command-string-source-positionals.rush";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\printf 'source:%s:%s:%s:%s\n' "$0" "$#" "$1" "$2"
        \\set -- changed
        \\
    });

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        ". ./rush-command-string-source-positionals.rush sourced 'two words'; printf 'after:%s:%s:%s:%s\n' \"$0\" \"$#\" \"$1\" \"$2\"",
        .{ .io = std.testing.io, .arg_zero = "myname", .features = compat.Features.bash() },
        null,
        &.{ "caller one", "caller two" },
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("source:myname:2:sourced:two words\nafter:myname:2:caller one:caller two\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "script file invocation sets command name and positional parameters" {
    const path = "rush-script-invocation-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\#!/usr/bin/env rush
        \\# first-line comments and shebangs are shell comments
        \\alias say='echo'
        \\read value <<EOF
        \\$2
        \\EOF
        \\say "$0:$#:$1:$value"
    });

    const invocation = parseShellInvocation(&.{ "rush", path, "arg one", "two words" }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush-script-invocation-test.rush:2:arg one:two words\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "script file invocation preserves trailing EOF backslash without final newline" {
    const path = "rush-script-trailing-backslash-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "echo a\\" });

    const invocation = parseShellInvocation(&.{ "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("a\\\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "script file invocation accepts sources larger than one mib" {
    const path = "rush-large-script-invocation-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    try contents.appendNTimes(std.testing.allocator, '#', 1024 * 1024 + 1);
    try contents.appendSlice(std.testing.allocator, "\necho ok\n");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = contents.items });

    const invocation = parseShellInvocation(&.{ "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "script file invocation shell options affect execution" {
    const path = "rush-script-options-test.rush";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\false
        \\echo unreached
    });

    const invocation = parseShellInvocation(&.{ "rush", "-e", path }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input invocation accepts -s operands and shell options" {
    const invocation = parseShellInvocation(&.{ "rush", "-e", "-s", "posarg", "two words" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(InvocationKind.standard_input, invocation.kind);
    try std.testing.expectEqualStrings("-", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("posarg", invocation.positionals[0]);
    try std.testing.expectEqualStrings("two words", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo $0:$#:$1:$2",
        .{ .io = std.testing.io, .arg_zero = invocation.arg_zero },
        null,
        invocation.positionals,
        null,
        invocation.shell_options,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("rush:2:posarg:two words\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input invocation is the default when only invocation options are present" {
    const invocation = parseShellInvocation(&.{ "rush", "--posix-strict", "-u" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(InvocationKind.standard_input, invocation.kind);
    try std.testing.expectEqualStrings("-", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 0), invocation.positionals.len);
    try std.testing.expect(invocation.features.strict_diagnostics);
    try std.testing.expect(invocation.shell_options.nounset);
}

test "interactive invocation tracks explicit monitor option" {
    const enabled = parseShellInvocation(&.{ "rush", "-im", "-c", "jobs" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(enabled.interactive);
    try std.testing.expect(enabled.shell_options.monitor);
    try std.testing.expect(enabled.monitor_option_explicit);

    const disabled = parseShellInvocation(&.{ "rush", "+m", "-i" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(disabled.interactive);
    try std.testing.expect(!disabled.shell_options.monitor);
    try std.testing.expect(disabled.monitor_option_explicit);
}

test "standard input invocation uses interactive editor when terminal rules require it" {
    const forced = parseShellInvocation(&.{ "rush", "-i" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(shouldRunInteractiveStandardInput(forced, true, false));
    try std.testing.expect(!shouldRunInteractiveStandardInput(forced, false, true));

    const implicit = parseShellInvocation(&.{ "rush", "--posix-strict", "-u" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(shouldRunInteractiveStandardInput(implicit, true, true));
    try std.testing.expect(!shouldRunInteractiveStandardInput(implicit, true, false));

    const command = parseShellInvocation(&.{ "rush", "-i", "-c", "exit" }) orelse return error.ExpectedInvocation;
    try std.testing.expect(!shouldRunInteractiveStandardInput(command, true, true));
}

test "command string invocation shell options affect execution" {
    const errexit_invocation = parseCommandStringInvocation(&.{ "rush", "-e", "-c", "false; echo unreached" }) orelse return error.ExpectedInvocation;
    var errexit = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        errexit_invocation.source,
        .{ .io = std.testing.io, .arg_zero = errexit_invocation.arg_zero },
        null,
        errexit_invocation.positionals,
        null,
        errexit_invocation.shell_options,
    );
    defer errexit.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), errexit.status);
    try std.testing.expectEqualStrings("", errexit.stdout);
    try std.testing.expectEqualStrings("", errexit.stderr);

    const clustered_errexit_invocation = parseCommandStringInvocation(&.{ "rush", "-ec", "false; echo unreached" }) orelse return error.ExpectedInvocation;
    var clustered_errexit = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        clustered_errexit_invocation.source,
        .{ .io = std.testing.io, .arg_zero = clustered_errexit_invocation.arg_zero },
        null,
        clustered_errexit_invocation.positionals,
        null,
        clustered_errexit_invocation.shell_options,
    );
    defer clustered_errexit.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), clustered_errexit.status);
    try std.testing.expectEqualStrings("", clustered_errexit.stdout);
    try std.testing.expectEqualStrings("", clustered_errexit.stderr);

    const option_after_c_invocation = parseCommandStringInvocation(&.{ "rush", "-c", "-e", "false; echo unreached" }) orelse return error.ExpectedInvocation;
    var option_after_c = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        option_after_c_invocation.source,
        .{ .io = std.testing.io, .arg_zero = option_after_c_invocation.arg_zero },
        null,
        option_after_c_invocation.positionals,
        null,
        option_after_c_invocation.shell_options,
    );
    defer option_after_c.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), option_after_c.status);
    try std.testing.expectEqualStrings("", option_after_c.stdout);
    try std.testing.expectEqualStrings("", option_after_c.stderr);

    const nounset_invocation = parseCommandStringInvocation(&.{ "rush", "-o", "nounset", "-c", "echo $RUSH_INVOCATION_UNSET_FOR_TEST_416; echo unreached" }) orelse return error.ExpectedInvocation;
    var nounset = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        nounset_invocation.source,
        .{ .io = std.testing.io, .arg_zero = nounset_invocation.arg_zero },
        null,
        nounset_invocation.positionals,
        null,
        nounset_invocation.shell_options,
    );
    defer nounset.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 1), nounset.status);
    try std.testing.expectEqualStrings("", nounset.stdout);
    try std.testing.expect(std.mem.indexOf(u8, nounset.stderr, "unset parameter") != null);

    const flags_invocation = parseCommandStringInvocation(&.{ "rush", "-bem", "-o", "nounset", "-c", "printf '<%s>\\n' \"$-\"" }) orelse return error.ExpectedInvocation;
    var flags = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        flags_invocation.source,
        .{ .io = std.testing.io, .arg_zero = flags_invocation.arg_zero },
        null,
        flags_invocation.positionals,
        null,
        flags_invocation.shell_options,
    );
    defer flags.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), flags.status);
    try std.testing.expectEqualStrings("<bemu>\n", flags.stdout);
    try std.testing.expectEqualStrings("", flags.stderr);

    const noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "echo unreached" }) orelse return error.ExpectedInvocation;
    var noexec = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = noexec_invocation.arg_zero },
        null,
        noexec_invocation.positionals,
        null,
        noexec_invocation.shell_options,
    );
    defer noexec.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), noexec.status);
    try std.testing.expectEqualStrings("", noexec.stdout);
    try std.testing.expectEqualStrings("", noexec.stderr);

    const invalid_noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "x=for; $x i in 1; do echo $i; done" }) orelse return error.ExpectedInvocation;
    var invalid_noexec = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_noexec_invocation.arg_zero },
        null,
        invalid_noexec_invocation.positionals,
        null,
        invalid_noexec_invocation.shell_options,
    );
    defer invalid_noexec.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_noexec.status);
    try std.testing.expectEqualStrings("", invalid_noexec.stdout);
    try std.testing.expect(std.mem.indexOf(u8, invalid_noexec.stderr, "misplaced reserved word") != null);

    const invalid_elif_noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "if false; then :; elif true; fi" }) orelse return error.ExpectedInvocation;
    var invalid_elif_noexec = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_elif_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_elif_noexec_invocation.arg_zero },
        null,
        invalid_elif_noexec_invocation.positionals,
        null,
        invalid_elif_noexec_invocation.shell_options,
    );
    defer invalid_elif_noexec.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_elif_noexec.status);
    try std.testing.expectEqualStrings("", invalid_elif_noexec.stdout);
    try std.testing.expect(std.mem.indexOf(u8, invalid_elif_noexec.stderr, "missing then in elif clause") != null);
}

test "command string set -v does not echo already-read input" {
    const invocation = parseShellInvocation(&.{ "rush", "-c", "set -v\necho command-string-verbose" }) orelse return error.ExpectedInvocation;
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .capture, false);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("command-string-verbose\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string read consumes piped real stdin" {
    const invocation = parseShellInvocation(&.{ "rush", "-c", "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"" }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "pipe value\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[pipe value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string read consumes file real stdin" {
    const path = "rush-command-string-read-stdin.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "file value\n" });

    const invocation = parseShellInvocation(&.{ "rush", "-c", "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"" }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithFileStdin(invocation, path);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[file value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "command string read keeps explicit stdin redirection precedence" {
    const path = "rush-command-string-read-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "redirected value\n" });

    const invocation = parseShellInvocation(&.{ "rush", "-c", "read x < \"$1\"; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"", "rush", path }) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "real stdin value\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[redirected value] status=0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input script source still leaves read at EOF" {
    const invocation = parseShellInvocation(&.{"rush"}) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithPipeStdin(invocation, "read x; status=$?; printf 'x=[%s] status=%s\n' \"$x\" \"$status\"\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("x=[] status=1\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "standard input file script seeks stdin before external commands" {
    const path = "rush-stdin-script-seek-external.tmp";
    const output_path = "rush-stdin-script-seek-external.out";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, output_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, output_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "echo start > rush-stdin-script-seek-external.out\n/usr/bin/head -1 >> rush-stdin-script-seek-external.out\necho end >> rush-stdin-script-seek-external.out\n" });

    const invocation = parseShellInvocation(&.{"rush"}) orelse return error.ExpectedInvocation;
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var guard = try StdinGuard.replaceWith(file);
    defer guard.restore();
    var result = try runShellInvocationWithEnvironment(std.testing.allocator, std.testing.io, invocation, null, .inherit, false);
    defer result.deinit();
    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqualStrings("start\necho end >> rush-stdin-script-seek-external.out\n", output);
}

test "standard input file script skips lines consumed by read" {
    const path = "rush-stdin-script-seek-read.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "read x\nprintf 'x=[%s]\\n' \"$x\"\nprintf 'after\\n'\n" });

    const invocation = parseShellInvocation(&.{"rush"}) orelse return error.ExpectedInvocation;
    var result = try runInvocationWithFileStdin(invocation, path);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("after\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "invalid arithmetic expansion returns a shell diagnostic" {
    const cases = [_][]const u8{
        "echo $((2 ** 3)); echo after",
        "echo $((\"1\" + 2)); echo after",
    };

    for (cases) |script| {
        var result = try runScript(std.testing.allocator, std.testing.io, script);
        defer result.deinit();

        try std.testing.expectEqual(@as(shell.ExitStatus, 1), result.status);
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "invalid arithmetic expression") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "after") == null);
    }
}

test "runScriptWithEnvironment imports initial shell variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "present");
    try env.put("IFS", ":");
    try env.put("OPTIND", "7");
    try env.put("PWD", "/definitely/not/rush/current/directory");

    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
        \\case $PPID in ''|*[!0123456789]*) echo bad-ppid ;; *) echo ppid-ok ;; esac
        \\printf '<%s>\n' "$RUSH_IMPORTED_ENV" "$IFS" "$OPTIND"
        \\case $PWD in /definitely/not/rush/*) echo bad-pwd ;; /*) echo pwd-ok ;; *) echo bad-pwd ;; esac
    , .{ .io = std.testing.io, .allow_external = true }, &env);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ppid-ok\n<present>\n< \t\n>\n<1>\npwd-ok\n", result.stdout);
}

test "semantic interactive command updates executor status for later commands" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    const executor = &interactive_shell.executor;
    try executor.initializeShellVariables(std.testing.io);
    executor.arg_zero = "rush";
    try interactive_shell.syncSemanticFromExecutor(std.testing.io);

    var false_result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "false", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer false_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 1), false_result.status);
    try std.testing.expectEqualStrings("", false_result.stdout);
    try std.testing.expectEqualStrings("", false_result.stderr);
    try std.testing.expectEqualStrings("1", executor.last_status_text[0..executor.last_status_text_len]);

    var status_result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "echo $?", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer status_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), status_result.status);
    try std.testing.expectEqualStrings("1\n", status_result.stdout);
    try std.testing.expectEqualStrings("", status_result.stderr);
}

test "semantic interactive shell state persists variable mutations without legacy execution" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    const executor = &interactive_shell.executor;
    try executor.initializeShellVariables(std.testing.io);
    executor.arg_zero = "rush";
    try interactive_shell.syncSemanticFromExecutor(std.testing.io);

    var assign = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "RUSH_INTERACTIVE_SEMANTIC=state", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer assign.deinit(std.testing.allocator);
    switch (assign) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try interactive_shell.syncExecutorFromSemantic();
    try std.testing.expectEqualStrings("state", executor.getEnv("RUSH_INTERACTIVE_SEMANTIC").?);

    var readback = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "printf '%s\n' \"$RUSH_INTERACTIVE_SEMANTIC\"", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer readback.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), readback.status);
    try std.testing.expectEqualStrings("state\n", readback.stdout);
    try std.testing.expectEqualStrings("", readback.stderr);
}

test "semantic interactive startup initializes ShellState without executor shell variables as source" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_INTERACTIVE_IMPORTED", "present");
    try env.put("SHLVL", "2");

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{
        .arg_zero = "rush",
        .positionals = &.{ "one", "two" },
        .shell_options = .{ .ignoreeof = true },
    });

    try std.testing.expect(interactive_shell.semantic_enabled);
    try std.testing.expectEqualStrings("present", interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_IMPORTED").?.value);
    try std.testing.expectEqualStrings("3", interactive_shell.semantic_state.getVariable("SHLVL").?.value);
    try std.testing.expectEqualStrings(" \t\n", interactive_shell.semantic_state.getVariable("IFS").?.value);
    try std.testing.expectEqualStrings("1", interactive_shell.semantic_state.getVariable("OPTIND").?.value);
    try std.testing.expect(interactive_shell.semantic_state.options.ignoreeof);
    try std.testing.expectEqual(@as(usize, 2), interactive_shell.semantic_state.positionals.items.len);
    try std.testing.expectEqualStrings("one", interactive_shell.semantic_state.positionals.items[0]);
    try std.testing.expectEqualStrings("two", interactive_shell.semantic_state.positionals.items[1]);
    try std.testing.expectEqualStrings("present", interactive_shell.executor.getEnv("RUSH_INTERACTIVE_IMPORTED").?);
}

test "interactive config service sources simple config through semantic ShellState" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    try InteractiveConfigService.initInteractive(std.testing.allocator, std.testing.io, &interactive_shell, "rush").sourceScript(
        \\RUSH_SEMANTIC_CONFIG=loaded
        \\RUSH_SEMANTIC_CONFIG_SECOND=ok
    , "semantic-config-test.rush");

    try std.testing.expectEqualStrings("loaded", interactive_shell.semantic_state.getVariable("RUSH_SEMANTIC_CONFIG").?.value);
    try std.testing.expectEqualStrings("ok", interactive_shell.semantic_state.getVariable("RUSH_SEMANTIC_CONFIG_SECOND").?.value);
    try std.testing.expectEqualStrings("loaded", interactive_shell.executor.getEnv("RUSH_SEMANTIC_CONFIG").?);
}

test "semantic interactive command falls back for function-shadowed builtins" {
    const path = "rush-semantic-interactive-function-fallback.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    const executor = &interactive_shell.executor;
    try executor.initializeShellVariables(std.testing.io);
    executor.arg_zero = "rush";

    var define = try runScriptWithExecutor(std.testing.allocator, executor, "echo() { printf 'function\\n' > " ++ path ++ "; }", .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer define.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), define.status);
    try interactive_shell.syncSemanticFromExecutor(std.testing.io);

    var result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "echo semantic", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stderr);

    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("function\n", output);
}

test "semantic interactive unset function stays on legacy state bridge" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    const executor = &interactive_shell.executor;
    try executor.initializeShellVariables(std.testing.io);
    executor.arg_zero = "rush";

    var define = try runScriptWithExecutor(std.testing.allocator, executor, "rush_semantic_unset_fn() { :; }", .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer define.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), define.status);
    try std.testing.expect(executor.functions.contains("rush_semantic_unset_fn"));
    try interactive_shell.syncSemanticFromExecutor(std.testing.io);

    var result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "unset -f rush_semantic_unset_fn", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!executor.functions.contains("rush_semantic_unset_fn"));
}

test "semantic interactive fallback happens before any partial execution" {
    const path = "rush-semantic-interactive-fallback.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    const executor = &interactive_shell.executor;
    try executor.initializeShellVariables(std.testing.io);
    executor.arg_zero = "rush";
    try interactive_shell.syncSemanticFromExecutor(std.testing.io);

    var semantic = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "echo before > " ++ path ++ "; echo redirected >> " ++ path, shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer semantic.deinit(std.testing.allocator);
    switch (semantic) {
        .unsupported => {},
        .output => return error.ExpectedSemanticUnsupported,
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));

    var result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "echo before > " ++ path ++ "; echo redirected >> " ++ path, .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stderr);

    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("before\nredirected\n", output);
}

test "semantic non-interactive invocation initializes environment arg zero and positionals" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "semantic");
    try env.put("SHLVL", "5");

    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "printf '<%s>\n' \"$0\" \"$#\" \"$1\" \"$RUSH_IMPORTED_ENV\" \"$IFS\" \"$OPTIND\" \"$SHLVL\"",
        shell.InvocationContext.init(.{ .arg_zero = "semantic-rush" }),
        .inherit,
        &env,
        &.{"positional"},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("<semantic-rush>\n<1>\n<positional>\n<semantic>\n< \t\n>\n<1>\n<6>\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation executes foreground simple pipelines" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\printf 'pipe:%s\n' value | /bin/cat
        \\false | true
        \\printf 'status:%s\n' "$?"
        \\! false
        \\printf 'negated:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("pipe:value\nstatus:0\nnegated:0\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation lowers function bodies at call time" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\func() { printf 'call:%s:%s\n' "$1" "$#"; }
        \\func first second
        \\outer() { inner() { printf 'same-list:%s\n' "$1"; }; inner nested; }
        \\outer
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("call:first:2\nsame-list:nested\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation lowers function for bodies per iteration" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\h() for i in 1 2; do echo f$i; done
        \\h
        \\show() { for x in "$@"; do echo "<$x>"; done; }
        \\show "a b" c ""
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("f1\nf2\n<a b>\n<c>\n<>\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "semantic non-interactive invocation executes function calls in pipelines with subshell isolation" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\pipe_fn() { printf 'pipe:%s\n' "$1"; }
        \\pipe_fn value | /bin/cat
        \\maker() { made() { printf 'bad\n'; }; }
        \\maker | /bin/cat
        \\made
        \\printf 'missing:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("pipe:value\nmissing:127\n", result.stdout);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "made: command not found") != null);
        },
    }
}

test "semantic parser lowering plans compound pipeline stages" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var evaluator = shell.eval.Evaluator.init(std.testing.allocator);
    var parser_resolver = shell.ParserTrapActionResolver.init(&evaluator);
    const resolver = parser_resolver.resolver();

    var body = (try resolver.resolve(
        std.testing.allocator,
        "{ printf 'left\n'; } | printf 'right\n'",
        .TERM,
        shell.EvalContext.forTarget(.current_shell),
        &shell_state,
    )) orelse return error.ExpectedSemanticBody;
    defer body.deinit();

    const plan = switch (body) {
        .owned => |owned| switch (owned.body) {
            .pipeline => |plan| plan,
            else => return error.ExpectedPipelinePlan,
        },
        else => return error.ExpectedOwnedSemanticBody,
    };

    try std.testing.expectEqual(@as(usize, 2), plan.stages.len);
    switch (plan.stages[0]) {
        .compound => |compound| try std.testing.expectEqualStrings("brace group", compound.kindName()),
        .simple => return error.ExpectedCompoundPipelineStage,
    }
    switch (plan.stages[1]) {
        .simple => {},
        .compound => return error.ExpectedSimplePipelineStage,
    }
}

test "semantic non-interactive invocation executes compound pipeline stages" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\{ printf 'brace\n'; } | /bin/cat
        \\( printf 'subshell\n' ) | /bin/cat
        \\if true; then printf 'if\n'; fi | /bin/cat
        \\while true; do printf 'while\n'; break; done | /bin/cat
        \\for item in loop; do printf 'for\n'; break; done | /bin/cat
        \\case x in x) printf 'case\n' ;; esac | /bin/cat
        \\! { false; }
        \\printf 'negated-compound:%s\n' "$?"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("brace\nsubshell\nif\nwhile\nfor\ncase\nnegated-compound:0\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

fn expectBackgroundStatusAndPidLine(prefix: []const u8, line: []const u8) !void {
    var fields = std.mem.splitScalar(u8, line, ':');
    try std.testing.expectEqualStrings(prefix, fields.next() orelse return error.ExpectedBackgroundLinePrefix);
    try std.testing.expectEqualStrings("0", fields.next() orelse return error.ExpectedBackgroundStatus);
    const pid_text = fields.next() orelse return error.ExpectedBackgroundPid;
    try std.testing.expect(fields.next() == null);
    const pid = try std.fmt.parseUnsigned(usize, pid_text, 10);
    try std.testing.expect(pid != 0);
}

test "semantic non-interactive invocation starts top-level background pipelines" {
    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        \\: & printf 'builtin:%s:%s\n' "$?" "$!"
        \\/bin/cat /dev/null | /bin/cat & printf 'pipeline:%s:%s\n' "$?" "$!"
    ,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stderr);

            var lines = std.mem.splitScalar(u8, result.stdout, '\n');
            const builtin = lines.next() orelse return error.ExpectedBackgroundBuiltinLine;
            const pipeline = lines.next() orelse return error.ExpectedBackgroundPipelineLine;
            try std.testing.expectEqualStrings("", lines.next() orelse return error.ExpectedTrailingNewline);
            try std.testing.expect(lines.next() == null);
            try expectBackgroundStatusAndPidLine("builtin", builtin);
            try expectBackgroundStatusAndPidLine("pipeline", pipeline);
        },
    }
}

test "semantic non-interactive invocation executes simple command redirections" {
    const path = "rush-semantic-simple-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var execution = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "echo redirected > " ++ path,
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer execution.deinit(std.testing.allocator);

    switch (execution) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("redirected\n", output);
}

test "semantic non-interactive invocation executes formerly gated production pipeline shapes" {
    var async_and_or = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "true && : &",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer async_and_or.deinit(std.testing.allocator);
    switch (async_and_or) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const path = "rush-semantic-compound-stage.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var redirected_compound_stage = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "{ printf 'compound\n'; } > " ++ path ++ " | /bin/cat",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer redirected_compound_stage.deinit(std.testing.allocator);
    switch (redirected_compound_stage) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

    const file_output = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(file_output);
    try std.testing.expectEqualStrings("compound\n", file_output);

    var dynamic_compound_stage = try runSemanticCommandString(
        std.testing.allocator,
        std.testing.io,
        "{ printf \"$(printf dynamic)\\n\"; } | /bin/cat",
        shell.InvocationContext.init(.{ .arg_zero = "rush" }),
        .inherit,
        null,
        &.{},
        .{},
    );
    defer dynamic_compound_stage.deinit(std.testing.allocator);
    switch (dynamic_compound_stage) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("dynamic\n", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }
}

test "runScriptWithEnvironment initializes and exports SHLVL" {
    const ShellLevelCase = struct {
        inherited: ?[]const u8,
        expected: []const u8,
    };
    const cases = [_]ShellLevelCase{
        .{ .inherited = null, .expected = "1" },
        .{ .inherited = "5", .expected = "6" },
        .{ .inherited = "not-a-number", .expected = "1" },
    };

    for (cases) |case| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        if (case.inherited) |level| try env.put("SHLVL", level);

        var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
            \\printf '<%s>\n' "$SHLVL"
            \\env | while IFS= read -r line; do case $line in SHLVL=*) printf 'exported:%s\n' "${line#SHLVL=}" ;; esac; done
        , .{ .io = std.testing.io, .allow_external = true }, &env);
        defer result.deinit();

        const expected = try std.fmt.allocPrint(std.testing.allocator, "<{s}>\nexported:{s}\n", .{ case.expected, case.expected });
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
        try std.testing.expectEqualStrings(expected, result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "runScriptWithEnvironment preserves valid inherited logical PWD" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);

    const root = "rush-test-logical-pwd";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/real");
    std.Io.Dir.cwd().symLink(std.testing.io, "real", root ++ "/link", .{}) catch return error.SkipZigTest;

    const logical_pwd = try std.mem.concat(std.testing.allocator, u8, &.{ original_cwd, "/", root, "/link" });
    defer std.testing.allocator.free(logical_pwd);
    try std.process.setCurrentPath(std.testing.io, logical_pwd);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PWD", logical_pwd);

    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
        \\case $PWD in */rush-test-logical-pwd/link) echo logical-pwd ;; *) echo bad-pwd:$PWD ;; esac
        \\case "$(pwd -L)" in */rush-test-logical-pwd/link) echo pwd-L ;; *) echo bad-L ;; esac
        \\case "$(pwd -P)" in */rush-test-logical-pwd/real) echo pwd-P ;; *) echo bad-P ;; esac
    , .{ .io = std.testing.io, .allow_external = true }, &env);
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("logical-pwd\npwd-L\npwd-P\n", result.stdout);
}

test "runScriptWithEnvironment exports PWD and OLDPWD after cd" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .default_dir);
    var tmp_root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_root_len = try tmp.dir.realPath(std.testing.io, &tmp_root_buffer);
    const tmp_root = tmp_root_buffer[0..tmp_root_len];
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "target" });
    defer std.testing.allocator.free(target_path);

    const script = try std.fmt.allocPrint(std.testing.allocator,
        \\unset PWD OLDPWD
        \\cd "{s}"
        \\env
    , .{target_path});
    defer std.testing.allocator.free(script);
    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io, script, .{ .io = std.testing.io, .allow_external = true }, null);
    defer result.deinit();

    const pwd_line = try std.fmt.allocPrint(std.testing.allocator, "PWD={s}\n", .{target_path});
    defer std.testing.allocator.free(pwd_line);
    const oldpwd_line = try std.fmt.allocPrint(std.testing.allocator, "OLDPWD={s}\n", .{original_cwd});
    defer std.testing.allocator.free(oldpwd_line);

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, pwd_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, oldpwd_line) != null);
}

test "runScriptWithOptions accepts inherit mode for external commands" {
    var result = try runScriptWithOptions(std.testing.allocator, std.testing.io, "/usr/bin/true", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .inherit,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScriptWithOptions captures simple external command output semantically" {
    var captured = try runScriptWithOptions(std.testing.allocator, std.testing.io, "/bin/sh -c 'printf out; printf err >&2'", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .capture,
    });
    defer captured.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), captured.status);
    try std.testing.expectEqualStrings("out", captured.stdout);
    try std.testing.expectEqualStrings("err", captured.stderr);

    var stdout_only = try runScriptWithOptions(std.testing.allocator, std.testing.io, "/bin/sh -c 'printf out; printf err >&2'", .{
        .io = std.testing.io,
        .allow_external = true,
        .external_stdio = .capture_stdout,
    });
    defer stdout_only.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), stdout_only.status);
    try std.testing.expectEqualStrings("out", stdout_only.stdout);
    try std.testing.expectEqualStrings("", stdout_only.stderr);
}

test "runScript executes builtins" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo hello");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
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
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ok\n", result.stdout);
}

test "POSIX mode reports misplaced reserved words" {
    var bare = try runScript(std.testing.allocator, std.testing.io, "then echo bad");
    defer bare.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), bare.status);
    try std.testing.expectEqualStrings("", bare.stdout);
    try std.testing.expect(std.mem.indexOf(u8, bare.stderr, "misplaced reserved word") != null);

    var expanded = try runScript(std.testing.allocator, std.testing.io, "x=for; $x i in 1");
    defer expanded.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 127), expanded.status);
    try std.testing.expect(std.mem.indexOf(u8, expanded.stderr, "for: command not found") != null);

    const alias_script =
        \\alias then='echo bad'
        \\then
    ;
    var alias_result = try runScript(std.testing.allocator, std.testing.io, alias_script);
    defer alias_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), alias_result.status);
    try std.testing.expectEqualStrings("", alias_result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, alias_result.stderr, "misplaced reserved word") != null);
    try std.testing.expect(std.mem.indexOf(u8, alias_result.stderr, "bad\n") == null);
}

test "runScript returns parse diagnostics" {
    var result = try runScript(std.testing.allocator, std.testing.io, "echo | ");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing command after pipeline operator") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "echo | ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "     ^") != null);
}

test "runScript executes newline-continued pipeline" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\echo before
        \\echo |
        \\echo after
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("before\nafter\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution preserves semantic builtin state and sequencing" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\VALUE=new
        \\printf 'semantic %s\n' shell
        \\printf '%s\n' "$VALUE"
        \\false && printf 'bad-and\n'
        \\true || printf 'bad-or\n'
        \\printf 'after\n'
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("semantic shell\nnew\nafter\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution handles deterministic builtin pipeline" {
    var result = try runScript(std.testing.allocator, std.testing.io, "printf 'pipe-value\n' | /bin/cat");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("pipe-value\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution handles compound pipeline stage" {
    var result = try runScript(std.testing.allocator, std.testing.io, "{ printf 'compound-value\n'; } | /bin/cat");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("compound-value\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "production shell execution handles pipeline function call" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\fn() { printf 'compare:%s\n' "$1"; }
        \\fn value | read VALUE
        \\printf 'status:%s value:%s\n' "$?" "$VALUE"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("status:0 value:\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScript reports misplaced reserved words before execution" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\echo before
        \\then
        \\echo after
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "misplaced reserved word") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "echo after") == null);
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
        status: shell.ExitStatus,
        stdout_contains: []const u8 = "",
        stderr_contains: []const u8 = "",
    };
    const cases = [_]Case{
        .{ .script = "", .status = 0 },
        .{ .script = "true", .status = 0 },
        .{ .script = "false", .status = 1 },
        .{ .script = "echo smoke", .status = 0, .stdout_contains = "smoke\n" },
        .{ .script = "echo smoke | /bin/cat", .status = 0, .stdout_contains = "smoke\n" },
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

test "aliases do not replace reserved words or function definition names" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\alias if='echo bad'
        \\if true; then echo ok; fi
        \\alias greet='echo alias'
        \\greet() { echo function; }
        \\unalias greet
        \\greet
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "function\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "bad\n") == null);
}

test "repl expands aliases defined on previous input lines" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\alias lsx='echo alias-ok'
        \\lsx
        \\alias lsx
        \\unalias lsx
        \\lsx
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("$ $ alias-ok\n$ lsx='echo alias-ok'\n$ $ $ ", result.stdout);
    try std.testing.expectEqualStrings("lsx: command not found\n", result.stderr);
}

test "aliases recursively expand and trailing blanks keep command position" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\alias say='echo recursive-ok'
        \\alias run=say
        \\run
        \\alias prefix='run '
        \\alias word='recursive-trailing-ok'
        \\prefix word
        \\alias self=self
        \\self
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok recursive-trailing-ok\n") != null);
    try std.testing.expectEqualStrings("self: command not found\n", result.stderr);
}

test "non-interactive aliases affect later complete commands" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo script-alias-ok'
        \\say
        \\if true; then echo compound-ok; fi
        \\alias prefix='say '
        \\alias word='trailing-ok'
        \\prefix word
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("script-alias-ok\ncompound-ok\nscript-alias-ok trailing-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "chunked alias scripts run EXIT trap once" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\trap 'echo bye' EXIT
        \\alias say='echo body'
        \\say
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("body\nbye\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "alias timing chunks keep multi-line here-doc bodies intact" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo alias-ok'
        \\read value <<EOF
        \\hello
        \\EOF
        \\say
        \\echo "$value"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-ok\nhello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases expand at parser-recognized command word positions" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-alias-redir.tmp") catch {};
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo parser-ok'
        \\FOO=bar say
        \\> rush-alias-redir.tmp say
        \\if say; then echo if-ok; fi
        \\read redirected < rush-alias-redir.tmp
        \\echo "$redirected"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("parser-ok\nparser-ok\nif-ok\nparser-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases expand inside command substitutions without touching here-doc bodies" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias say='echo subst-ok'
        \\alias body='echo bad'
        \\echo "$(say)"
        \\read value <<EOF
        \\body
        \\EOF
        \\echo "$value"
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("subst-ok\nbody\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases can introduce reserved-word compound commands" {
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias start='if'
        \\start true
        \\then echo alias-if-ok
        \\fi
        \\alias loop='while '
        \\count=0
        \\loop [ "$count" -lt 1 ]
        \\do echo alias-while-ok; count=$((count + 1))
        \\done
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-if-ok\nalias-while-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases defined by eval and dot affect later complete commands" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-alias-dot-source") catch {};
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\eval "alias say='echo eval-ok'"
        \\say
        \\printf '%s\n' "alias dot='echo dot-ok'" > rush-alias-dot-source
        \\. ./rush-alias-dot-source
        \\dot
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("eval-ok\ndot-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "aliases defined on a read line affect only later read lines" {
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "rush-alias-read-line-source") catch {};
    var result = try runScript(std.testing.allocator, std.testing.io,
        \\alias zzsamecmd='echo same-ok'; zzsamecmd; echo same-line:$?
        \\zzsamecmd
        \\eval "alias zzevalcmd='echo eval-ok'"; zzevalcmd; echo eval-line:$?
        \\zzevalcmd
        \\printf '%s\n' "alias zzdotcmd='echo dot-ok'" > rush-alias-read-line-source
        \\. ./rush-alias-read-line-source; zzdotcmd; echo dot-line:$?
        \\zzdotcmd
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("same-line:127\nsame-ok\neval-line:127\neval-ok\ndot-line:127\ndot-ok\n", result.stdout);
    try std.testing.expectEqualStrings("zzsamecmd: command not found\nzzevalcmd: command not found\nzzdotcmd: command not found\n", result.stderr);
}

test "prompt rendering subcommands are scoped while repaint is public" {
    var prompt_result = try runScript(std.testing.allocator, std.testing.io, "prompt text hi");
    defer prompt_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), prompt_result.status);
    try std.testing.expectEqualStrings("prompt: not rendering a prompt\n", prompt_result.stderr);

    var repaint_result = try runScript(std.testing.allocator, std.testing.io, "prompt repaint");
    defer repaint_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), repaint_result.status);
    try std.testing.expectEqualStrings("", repaint_result.stderr);

    var command_result = try runScript(std.testing.allocator, std.testing.io, "command -v prompt");
    defer command_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), command_result.status);
    try std.testing.expectEqualStrings("prompt\n", command_result.stdout);
}

test "rush_style sees rush-owned color scheme" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.initializeShellVariables(std.testing.io);

    var setup = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\readonly rush_color_scheme
        \\rush_style() { rush_style_history_match="fg=$rush_color_scheme"; }
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer setup.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), setup.status);

    try applyInteractiveColorScheme(&executor, std.testing.io, .light);
    try std.testing.expectEqualStrings("light", executor.getEnv("rush_color_scheme").?);
    try std.testing.expectEqualStrings("fg=light", executor.getEnv("rush_style_history_match").?);

    try applyInteractiveColorScheme(&executor, std.testing.io, .dark);
    try std.testing.expectEqualStrings("dark", executor.getEnv("rush_color_scheme").?);
    try std.testing.expectEqualStrings("fg=dark", executor.getEnv("rush_style_history_match").?);
}

test "interactive color reports define rgb theme variables" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.initializeShellVariables(std.testing.io);

    var setup = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_style() { rush_style_history_match="fg=$rush_color_blue"; }
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer setup.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), setup.status);

    try applyInteractiveColorReport(&executor, std.testing.io, .{ .kind = .{ .index = 4 }, .value = .{ 0x01, 0x23, 0x45 } });
    try std.testing.expectEqualStrings("#012345", executor.getEnv("rush_color_blue").?);
    try std.testing.expectEqualStrings("fg=#012345", executor.getEnv("rush_style_history_match").?);

    try applyInteractiveColorReport(&executor, std.testing.io, .{ .kind = .fg, .value = .{ 0xab, 0xcd, 0xef } });
    try std.testing.expectEqualStrings("#abcdef", executor.getEnv("rush_color_foreground").?);
}

test "repl uses rush_prompt function to build prompt text" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\rush_prompt() { prompt segment --fg blue custom; prompt text ' > '; }
        \\echo ok
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("$ \x1b[38;5;4mcustom\x1b[0m > ok\n\x1b[38;5;4mcustom\x1b[0m > ", result.stdout);
}

test "repl uses literal PS1 fallback prompt" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\PS1='custom> '
        \\echo ok
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("$ custom> ok\ncustom> ", result.stdout);
}

test "interactive startup initializes prompt variables and sources ENV" {
    const env_path = "rush-test-env-startup.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "ENV_LOADED=ok\nPS1='env> '\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("ENV", env_path);

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &executor, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("ok", executor.getEnv("ENV_LOADED").?);
    // Embedded default config provides PS2; $ENV overrides the embedded PS1 default.
    try std.testing.expectEqualStrings("> ", executor.getEnv("PS2").?);
    try std.testing.expectEqualStrings("env> ", executor.getEnv("PS1").?);
}

test "interactive startup parameter-expands ENV pathname from HOME" {
    const env_path = "rush-test-home-env-startup.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "HOME_ENV_LOADED=ok\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const env_value = try std.fmt.allocPrint(std.testing.allocator, "$HOME/{s}", .{env_path});
    defer std.testing.allocator.free(env_value);

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("HOME", cwd);
    try executor.setEnv("ENV", env_value);

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &executor, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("ok", executor.getEnv("HOME_ENV_LOADED").?);
}

test "interactive startup enables monitor by default for tty stdin" {
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.SkipZigTest;
    defer _ = close(master);
    defer _ = close(slave);

    var guard = try StdinGuard.replaceWith(.{ .handle = slave, .flags = .{ .nonblocking = false } });
    defer guard.restore();

    var default_monitor = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "case $- in *m*) echo monitor:on;; *) echo monitor:off;; esac",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        null,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer default_monitor.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), default_monitor.status);
    try std.testing.expectEqualStrings("monitor:on\n", default_monitor.stdout);
    try std.testing.expectEqualStrings("", default_monitor.stderr);

    var explicit_disabled = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "case $- in *m*) echo monitor:on;; *) echo monitor:off;; esac",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        null,
        &.{},
        .{ .arg_zero = "rush", .monitor_option_explicit = true },
        .{},
    );
    defer explicit_disabled.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), explicit_disabled.status);
    try std.testing.expectEqualStrings("monitor:off\n", explicit_disabled.stdout);
    try std.testing.expectEqualStrings("", explicit_disabled.stderr);
}

fn loadInteractiveConfigCapturingStderr(allocator: std.mem.Allocator, executor: *exec.Executor, stderr_path: []const u8) ![]u8 {
    var stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{ .truncate = true });
    var stderr_file_open = true;
    defer if (stderr_file_open) stderr_file.close(std.testing.io);

    var stderr_guard = try StderrGuard.replaceWith(stderr_file);
    var stderr_guard_active = true;
    defer if (stderr_guard_active) stderr_guard.restore();

    try loadInteractiveConfig(allocator, std.testing.io, executor, .{ .arg_zero = "rush" });

    stderr_guard.restore();
    stderr_guard_active = false;
    stderr_file.close(std.testing.io);
    stderr_file_open = false;

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, allocator, .limited(4096));
}

test "interactive startup warns and skips user config path directory" {
    const root = "rush-test-config-directory-startup";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/config.rush");

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_CONFIG_HOME", root);

    const stderr = try loadInteractiveConfigCapturingStderr(std.testing.allocator, &executor, root ++ "/stderr");
    defer std.testing.allocator.free(stderr);

    try std.testing.expectEqualStrings("rush: warning: cannot read " ++ root ++ "/rush/config.rush: is a directory; skipping\n", stderr);
    try std.testing.expectEqualStrings("> ", executor.getEnv("PS2").?);
}

test "interactive startup warns and skips unreadable user config" {
    const root = "rush-test-unreadable-config-startup";
    const config_path = root ++ "/rush/config.rush";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = "CONFIG_LOADED=bad\n" });

    var config_file = try std.Io.Dir.cwd().openFile(std.testing.io, config_path, .{});
    defer config_file.close(std.testing.io);
    try config_file.setPermissions(std.testing.io, @enumFromInt(0o000));
    defer config_file.setPermissions(std.testing.io, @enumFromInt(0o644)) catch {};

    const denied = denied: {
        const contents = std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(1024)) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => break :denied true,
            else => return err,
        };
        std.testing.allocator.free(contents);
        break :denied false;
    };
    if (!denied) return error.SkipZigTest;

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("XDG_CONFIG_HOME", root);

    const stderr = try loadInteractiveConfigCapturingStderr(std.testing.allocator, &executor, root ++ "/stderr");
    defer std.testing.allocator.free(stderr);

    try std.testing.expectEqualStrings("rush: warning: cannot read " ++ config_path ++ ": permission denied; skipping\n", stderr);
    try std.testing.expect(executor.getEnv("CONFIG_LOADED") == null);
    try std.testing.expectEqualStrings("> ", executor.getEnv("PS2").?);
}

test "interactive command string invocation sources ENV before script" {
    const env_path = "rush-test-command-string-env.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "COMMAND_STRING_ENV=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV", env_path);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"$COMMAND_STRING_ENV\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("loaded\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string invocation exits immediately when user config exits" {
    const root = "rush-test-config-exit-startup";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data = "exit 7\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo should-not-run",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string invocation exits immediately when user config exec fails" {
    const root = "rush-test-config-exec-failure-startup";
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root ++ "/rush/config.rush", .data = "exec /nonexistent/rush-task-702 2>/dev/null\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "echo should-not-run",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-interactive command string invocation does not source ENV" {
    const env_path = "rush-test-noninteractive-env.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "NONINTERACTIVE_ENV=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV", env_path);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"${NONINTERACTIVE_ENV-unset}\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        null,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("unset\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "interactive command string invocation parameter-expands ENV_DIR before script" {
    const env_path = "rush-test-env-dir-command-string.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "ENV_DIR_COMMAND_STRING=loaded\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const env_value = try std.fmt.allocPrint(std.testing.allocator, "${{ENV_DIR}}/{s}", .{env_path});
    defer std.testing.allocator.free(env_value);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ENV_DIR", cwd);
    try env.put("ENV", env_value);

    var result = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '%s\n' \"$ENV_DIR_COMMAND_STRING\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        &env,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("loaded\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "embedded default config sets prompt defaults without clobbering inherited values" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PS1", "inherited> ");

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &executor, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("inherited> ", executor.getEnv("PS1").?);
    try std.testing.expectEqualStrings("> ", executor.getEnv("PS2").?);
}

test "embedded config default prompt renders cwd and dollar sign" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor, embedded_config, .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush", .source_path = embedded_config_path });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);

    const prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(prompt);
    // The cwd segment is blue and the prompt ends with a dollar sign; the
    // exact text depends on the cwd and Git state, so only check structure.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\x1b[38;5;4m") != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, " $ "));
}

test "prompt_pwd supports fish-style dir length flags" {
    const original_cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.setCurrentPath(std.testing.io, original_cwd) catch {};

    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\cd /usr/bin
        \\rush_prompt() { prompt text "$(prompt_pwd -d 1)|$(prompt_pwd)"; }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();

    const prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("/u/bin|/usr/bin", prompt);
}

test "prompt segment supports foreground and background colors" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt segment --fg bright-blue --bg black custom; }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();

    const prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("\x1b[38;5;12m\x1b[48;5;0mcustom\x1b[0m", prompt);
}

test "prompt segment supports indexed and rgb colors" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt segment --fg '#7aa2f7' --bg index:236 custom; }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();

    const prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("\x1b[38;2;122;162;247m\x1b[48;5;236mcustom\x1b[0m", prompt);
}

test "prompt segment supports text attributes" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt segment --bold --italic --underline --reverse --strikethrough custom; }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();

    const prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("\x1b[1m\x1b[3m\x1b[4m\x1b[7m\x1b[9mcustom\x1b[0m", prompt);
}

test "prompt duration exposes previous command duration" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    executor.setLastCommandDuration(1234);

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt text $(prompt_duration)ms; }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();

    const prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("1234ms", prompt);
}

test "prompt refresh records requested idle redraw interval" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt refresh --interval 250; prompt text clock; }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();

    const prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("clock", prompt);
    try std.testing.expectEqual(@as(?u64, 250), executor.promptRefreshIntervalMs());
}

test "prompt time formats strftime and go layouts" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var strftime_result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt text $(prompt_time %Y); }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer strftime_result.deinit();
    const strftime_prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(strftime_prompt);
    try std.testing.expectEqual(@as(usize, 4), strftime_prompt.len);
    for (strftime_prompt) |byte| try std.testing.expect(std.ascii.isDigit(byte));

    var gofmt_result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt text $(prompt_time 2006); }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer gofmt_result.deinit();
    const gofmt_prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(gofmt_prompt);
    try std.testing.expectEqual(@as(usize, 4), gofmt_prompt.len);
    for (gofmt_prompt) |byte| try std.testing.expect(std.ascii.isDigit(byte));
}

test "prompt async returns cached stdout and requests repaint" {
    const Repaint = struct {
        count: usize = 0,

        fn request(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };

    var repaint: Repaint = .{};
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    executor.setPromptRepaintHandler(&repaint, Repaint.request);

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt text $(prompt_async cache-key --ttl 1000 -- echo fresh); }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();
    executor.setLastStatus(7);

    const cold_prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(cold_prompt);
    try std.testing.expectEqualStrings("", cold_prompt);
    try std.testing.expectEqual(@as(shell.ExitStatus, 7), executor.lastStatus());

    executor.waitForPromptAsyncRefreshes();
    try std.testing.expectEqual(@as(usize, 1), repaint.count);

    const warm_prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(warm_prompt);
    try std.testing.expectEqualStrings("fresh", warm_prompt);
    try std.testing.expectEqual(@as(shell.ExitStatus, 7), executor.lastStatus());
}

test "prompt async suppresses stderr from refresh output" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\rush_prompt() { prompt text $(prompt_async stderr-key --ttl 1000 -- /bin/sh -c 'echo out; echo err >&2'); }
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer result.deinit();

    const cold_prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(cold_prompt);
    try std.testing.expectEqualStrings("", cold_prompt);

    executor.waitForPromptAsyncRefreshes();
    const warm_prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(warm_prompt);
    try std.testing.expectEqualStrings("out", warm_prompt);
}

test "prompt event hooks run hidden and preserve status" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\on_prompt() { PROMPT_HOOK=$?; echo hidden; }
        \\event prompt on_prompt
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer setup.deinit();
    executor.setLastStatus(7);

    try executor.runPromptEventHooks(std.testing.io, "prompt", &.{});
    try std.testing.expectEqualStrings("7", executor.getEnv("PROMPT_HOOK").?);
    try std.testing.expectEqual(@as(shell.ExitStatus, 7), executor.lastStatus());
}

test "variable and interval hooks use prompt repaint primitive" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var setup = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\on_variable() { VARIABLE_HOOK=$1; prompt repaint; }
        \\on_interval() { INTERVAL_HOOK=$1; prompt repaint; }
        \\event variable on_variable
        \\interval clock --interval 100000 on_interval
        \\:
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" });
    defer setup.deinit();

    try executor.setEnv("RUSH_HOOK_TEST", "value");
    try executor.runPendingVariableHooks(std.testing.io);
    try std.testing.expectEqualStrings("RUSH_HOOK_TEST", executor.getEnv("VARIABLE_HOOK").?);

    try std.testing.expectEqual(@as(?u64, 0), executor.promptIntervalWaitMs(std.testing.io));
    try executor.runDuePromptIntervals(std.testing.io);
    try std.testing.expectEqualStrings("clock", executor.getEnv("INTERVAL_HOOK").?);
    try std.testing.expect((executor.promptIntervalWaitMs(std.testing.io) orelse 0) > 0);
}

test "omitted newline marker follows displayed output stream" {
    try std.testing.expect(!outputNeedsNewlineMarker("", ""));
    try std.testing.expect(!outputNeedsNewlineMarker("ok\n", ""));
    try std.testing.expect(outputNeedsNewlineMarker("ok", ""));
    try std.testing.expect(!outputNeedsNewlineMarker("ok", "err\n"));
    try std.testing.expect(outputNeedsNewlineMarker("ok\n", "err"));
}

test "startup config runtime errors include source path and line" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();

    var result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\echo before
        \\complete git --function __rush_complete_git
    , .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush", .source_path = "/tmp/rush/config.rush" });
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("before\n", result.stdout);
    try std.testing.expectEqualStrings("/tmp/rush/config.rush:2: complete: --function requires --subcommands, --options, --argument, or --option-value\n", result.stderr);
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

test "user profile path prefers XDG_CONFIG_HOME" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("HOME", "/home/example");
    try executor.setEnv("XDG_CONFIG_HOME", "/tmp/xdg");

    const path = (try userProfilePath(std.testing.allocator, executor)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/xdg/rush/profile.rush", path);
}

test "command string invocation accepts interactive flag before -c" {
    const invocation = parseCommandStringInvocation(&.{ "rush", "-i", "-c", "exit" }) orelse return error.ExpectedInvocation;

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
        const invocation = parseCommandStringInvocation(args) orelse return error.ExpectedInvocation;
        try std.testing.expectEqualStrings("echo positional", invocation.source);
        try std.testing.expectEqualStrings("name", invocation.arg_zero);
        try std.testing.expectEqual(@as(usize, 1), invocation.positionals.len);
        try std.testing.expectEqualStrings("one", invocation.positionals[0]);
        try std.testing.expect(invocation.interactive);
        try std.testing.expect(invocation.features.strict_diagnostics);
    }
}

test "command string invocation accepts set option flags before -c" {
    const invocation = parseCommandStringInvocation(
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
    const invocation = parseCommandStringInvocation(
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
    const invocation = parseCommandStringInvocation(
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
    const sc_invocation = parseCommandStringInvocation(&.{ "rush", "-sc", "echo ok" }) orelse return error.ExpectedInvocation;
    try std.testing.expectEqualStrings("echo ok", sc_invocation.source);
    try std.testing.expectEqualStrings("rush", sc_invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 0), sc_invocation.positionals.len);

    const cs_invocation = parseCommandStringInvocation(&.{ "rush", "-cs", "echo ok" }) orelse return error.ExpectedInvocation;
    try std.testing.expectEqualStrings("echo ok", cs_invocation.source);
    try std.testing.expectEqualStrings("rush", cs_invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 0), cs_invocation.positionals.len);
}

test "standard input invocation continues option parsing after -s" {
    const invocation = parseShellInvocation(&.{ "rush", "-s", "-e", "posarg", "two words" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(InvocationKind.standard_input, invocation.kind);
    try std.testing.expectEqualStrings("-", invocation.source);
    try std.testing.expectEqualStrings("rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 2), invocation.positionals.len);
    try std.testing.expectEqualStrings("posarg", invocation.positionals[0]);
    try std.testing.expectEqualStrings("two words", invocation.positionals[1]);
    try std.testing.expect(invocation.shell_options.errexit);
}

test "script file invocation accepts options before script operand" {
    const invocation = parseShellInvocation(
        &.{ "rush", "--posix-strict", "-eu", "-o", "pipefail", "script.rush", "-o", "nounset" },
    ) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(InvocationKind.script_file, invocation.kind);
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
    const invocation = parseShellInvocation(&.{ "rush", "-e", "--", "-script.rush", "arg" }) orelse return error.ExpectedInvocation;

    try std.testing.expectEqual(InvocationKind.script_file, invocation.kind);
    try std.testing.expectEqualStrings("-script.rush", invocation.source);
    try std.testing.expectEqualStrings("-script.rush", invocation.arg_zero);
    try std.testing.expectEqual(@as(usize, 1), invocation.positionals.len);
    try std.testing.expectEqualStrings("arg", invocation.positionals[0]);
    try std.testing.expect(invocation.shell_options.errexit);
}

test "command string invocation rejects invalid set option flags" {
    try std.testing.expect(parseCommandStringInvocation(&.{ "rush", "-z", "-c", "echo bad" }) == null);
    try std.testing.expect(parseCommandStringInvocation(&.{ "rush", "+z", "-c", "echo bad" }) == null);
    try std.testing.expect(parseCommandStringInvocation(&.{ "rush", "-o", "-c", "echo bad" }) == null);
    try std.testing.expect(parseCommandStringInvocation(&.{ "rush", "-o", "unknown", "-c", "echo bad" }) == null);
    try std.testing.expect(parseShellInvocation(&.{ "rush", "-z", "script.rush" }) == null);
    try std.testing.expect(parseShellInvocation(&.{ "rush", "+z", "script.rush" }) == null);
}

test "command string invocation still requires -c" {
    try std.testing.expect(parseCommandStringInvocation(&.{ "rush", "-i" }) == null);
}

test "login shell detection follows argv0 dash convention" {
    try std.testing.expect(isLoginArgZero("-rush"));
    try std.testing.expect(isLoginArgZero("/bin/-rush"));
    try std.testing.expect(!isLoginArgZero("rush"));
    try std.testing.expect(!isLoginArgZero("/bin/rush"));
}

test "integration harness compares selected scripts with /bin/sh" {
    try expectMatchesSh("echo hello");
    try expectMatchesSh("false");
    try expectMatchesSh("echo hello | /bin/cat");
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

fn runSh(allocator: std.mem.Allocator, script: []const u8) !CommandResult {
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

fn processStatus(term: std.process.Child.Term) shell.ExitStatus {
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
    std.testing.refAllDecls(history_module);
    std.testing.refAllDecls(shell);
    std.testing.refAllDecls(runtime);
    std.testing.refAllDecls(line_editor);
    std.testing.refAllDecls(editor_driver);
}
