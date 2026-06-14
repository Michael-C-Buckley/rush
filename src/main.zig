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
pub const history_module = @import("history.zig");
pub const shell = @import("shell.zig");
pub const runtime = @import("runtime.zig");
pub const line_editor = @import("line_editor.zig");
pub const editor_driver = @import("editor_driver.zig");
pub const event_loop = @import("event_loop.zig");

const usage =
    \\usage: rush [--login]
    \\       rush [-i] [--posix-strict] [set-options]
    \\       rush [-i] [--posix-strict] [set-options] -c SCRIPT [NAME [ARGS...]]
    \\       rush [-i] [--posix-strict] [set-options] -s [ARGS...]
    \\       rush [-i] [--posix-strict] [set-options] SCRIPT_FILE [ARGS...]
    \\       rush --help
    \\
;

const system_profile_path = build_config.sysconfdir ++ "/rush/profile.rush";
const system_config_path = build_config.sysconfdir ++ "/rush/config.rush";
const embedded_config = @embedFile("default_config");
const embedded_config_path = "embedded:config.rush";
const omitted_newline_marker = "\x1b[2m⏎\x1b[22m\r\n";
const ignoreeof_message = "Use \"exit\" to leave the shell.\r\n";
const stopped_jobs_exit_warning = "You have stopped jobs.\n";
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

const RunOptions = struct {
    io: ?std.Io = null,
    allow_external: bool = true,
    features: compat.Features = .{},
    external_stdio: runtime.ExternalStdio = .capture,
    interactive: bool = false,
    arg_zero: []const u8 = "rush",
    source_path: ?[]const u8 = null,
    stdin_script_file: ?std.Io.File = null,
    stdin_script_source_offset: usize = 0,
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

    pub fn fcEntries(self: *History, allocator: std.mem.Allocator) ![]history_module.HistoryEntry {
        if (self.db) |db| return queryFcHistoryEntries(db, allocator);
        var entries: std.ArrayList(history_module.HistoryEntry) = .empty;
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
    suppress_next_append: bool = false,

    fn init(history: *History) InteractiveHistoryService {
        return .{ .history = history };
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

    fn suppressNextAppend(self: *InteractiveHistoryService) void {
        self.suppress_next_append = true;
    }

    fn consumeSuppressNextAppend(self: *InteractiveHistoryService) bool {
        const suppress = self.suppress_next_append;
        self.suppress_next_append = false;
        return suppress;
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

    fn fcEntries(self: *InteractiveHistoryService, allocator: std.mem.Allocator) ![]history_module.HistoryEntry {
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

fn queryFcHistoryEntries(db: *sqlite.sqlite3, allocator: std.mem.Allocator) ![]history_module.HistoryEntry {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "select id, command from history order by id asc", -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var entries: std.ArrayList(history_module.HistoryEntry) = .empty;
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

const InteractiveContext = struct {
    semantic_state: *shell.ShellState,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},
};

fn interactivePromptText(shell_state: *shell.ShellState, name: []const u8, fallback: []const u8) []const u8 {
    return interactiveGetEnv(shell_state, name) orelse fallback;
}

fn renderStaticInteractivePrompt(allocator: std.mem.Allocator, shell_state: *shell.ShellState) ![]const u8 {
    return allocator.dupe(u8, interactivePromptText(shell_state, "PS1", "$ "));
}

fn interactiveGetEnv(shell_state: *shell.ShellState, name: []const u8) ?[]const u8 {
    std.debug.assert(isValidShellVariableName(name));
    shell_state.validate();
    if (shell_state.getVariable(name)) |variable| return variable.value;
    return null;
}

fn interactiveExternalEditorCommand(shell_state: *shell.ShellState) []const u8 {
    if (interactiveGetEnv(shell_state, "VISUAL")) |visual| if (visual.len != 0) return visual;
    if (interactiveGetEnv(shell_state, "EDITOR")) |editor| if (editor.len != 0) return editor;
    return "vi";
}

fn interactiveExternalEditorTmpdir(shell_state: *shell.ShellState) []const u8 {
    if (interactiveGetEnv(shell_state, "TMPDIR")) |tmpdir| if (tmpdir.len != 0) return tmpdir;
    return "/tmp";
}

fn runInteractiveIntervalHooks(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) !editor_driver.HookResult {
    const interactive_context: *InteractiveContext = @ptrCast(@alignCast(context));
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var should_refresh_prompt = false;

    const semantic_state = interactive_context.semantic_state;
    if (try executeInteractivePendingTraps(allocator, io, semantic_state, interactive_context.arg_zero, interactive_context.features)) |trap_result| {
        var result = trap_result;
        defer result.deinit();
        try output.appendSlice(allocator, result.stdout);
        try output.appendSlice(allocator, result.stderr);
        should_refresh_prompt = true;
    }

    if (semantic_state.options.notify) {
        const notifications = try drainInteractiveSemanticJobNotifications(allocator, io, semantic_state);
        defer allocator.free(notifications);
        try output.appendSlice(allocator, notifications);
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .refresh_prompt = should_refresh_prompt,
        .stop = semantic_state.pending_exit != null,
    };
}

fn nextInteractiveIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    _ = io;
    const interactive_context: *InteractiveContext = @ptrCast(@alignCast(context));
    if (shellStateWantsImmediateJobNotificationPoll(interactive_context.semantic_state)) {
        return immediate_notify_poll_ms;
    }
    return null;
}

fn drainInteractiveSemanticJobNotifications(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState) ![]const u8 {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    const eval_context = shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true });
    var outcome = try shell.eval.drainJobNotifications(&evaluator, shell_state, eval_context);
    defer outcome.deinit();
    try outcome.commitDelta(shell_state, .current_shell);
    const output = try outcome.stdout.toOwnedSlice(allocator);
    outcome.stdout = .empty;
    shell_state.validate();
    return output;
}

fn executeInteractivePendingTraps(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) !?CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(arg_zero.len != 0);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    evaluator.features = features;
    evaluator.arg_zero = arg_zero;
    evaluator.external_stdio = .inherit;
    const eval_context = shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true });

    if (try shell.eval.observeRuntimeSignal(&evaluator, shell_state, eval_context)) |observed| {
        var observation = observed;
        defer observation.deinit();
        try observation.command_outcome.commitDelta(shell_state, .current_shell);
    }

    var resolver = shell.eval.ParserTrapActionResolver.init(&evaluator);
    resolver.features = features;
    resolver.arg_zero = arg_zero;
    var trap_outcome = (try shell.eval.executePendingTraps(&evaluator, shell_state, eval_context, resolver.resolver())) orelse return null;
    defer trap_outcome.deinit();

    const stdout = try trap_outcome.stdout.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try trap_outcome.stderr.toOwnedSlice(allocator);
    errdefer allocator.free(stderr);
    try trap_outcome.commitDelta(shell_state, .current_shell);
    shell_state.validate();
    return .{ .allocator = allocator, .status = trap_outcome.status, .stdout = stdout, .stderr = stderr };
}

fn shellStateWantsImmediateJobNotificationPoll(shell_state: *const shell.ShellState) bool {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (!shell_state.options.notify) return false;
    if (shell_state.pending_job_notifications.items.len != 0) return true;
    for (shell_state.background_jobs.items) |job| {
        job.validate();
        if (job.state != .done or job.notified_state != job.state) return true;
    }
    return false;
}

fn interactivePendingExit(interactive_shell: *const InteractiveShell) ?shell.ExitStatus {
    if (!interactive_shell.semantic_enabled) return null;
    interactive_shell.semantic_state.validate();
    std.debug.assert(interactive_shell.semantic_state.scope == .current_shell);
    return interactive_shell.semantic_state.pending_exit;
}

fn shellStateHasStoppedJobs(shell_state: shell.ShellState) bool {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    for (shell_state.background_jobs.items) |job| {
        job.validate();
        if (job.state == .stopped) return true;
    }
    return false;
}

fn shouldWarnBeforeExitWithStoppedJobs(shell_state: *shell.ShellState) bool {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (!shellStateHasStoppedJobs(shell_state.*)) {
        shell_state.warned_stopped_jobs_on_exit = false;
        shell_state.validate();
        return false;
    }
    if (shell_state.warned_stopped_jobs_on_exit) return false;
    shell_state.warned_stopped_jobs_on_exit = true;
    shell_state.validate();
    return true;
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
    semantic_state: shell.ShellState,
    semantic_enabled: bool = false,

    fn init(allocator: std.mem.Allocator) InteractiveShell {
        return .{
            .allocator = allocator,
            .semantic_state = shell.ShellState.init(allocator),
        };
    }

    fn deinit(self: *InteractiveShell) void {
        self.semantic_state.deinit();
        self.* = undefined;
    }

    fn initializeSemanticStartup(self: *InteractiveShell, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !void {
        self.semantic_state.deinit();
        self.semantic_state = shell.ShellState.init(self.allocator);
        self.semantic_enabled = false;

        var startup_shell_options = options.shell_options;
        setInteractiveStartupShellOptions(&startup_shell_options, options.monitor_option_explicit, stdinIsTty(io));
        try initializeSemanticInteractiveStartupState(self.allocator, io, &self.semantic_state, environ_map, options.positionals, startup_shell_options);
        self.semantic_enabled = true;
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
    try interactive_shell.initializeSemanticStartup(io, environ_map, options);
    try loadInteractiveConfig(allocator, io, &interactive_shell.semantic_state, options);
    if (interactivePendingExit(&interactive_shell)) |status| return status;
    var terminal = try editor_driver.TerminalSession.init(allocator, io);
    defer terminal.deinit();
    runtime.signal.setWakeFd(terminal.trapSignalWakeFd());
    defer runtime.signal.clearWakeFd(terminal.trapSignalWakeFd());
    if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);

    _ = completion_allocator;

    repl_loop: while (true) {
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        terminal.refreshWinsize();
        if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const notifications = if (interactive_shell.semantic_enabled)
            try drainInteractiveSemanticJobNotifications(allocator, io, &interactive_shell.semantic_state)
        else
            try allocator.dupe(u8, "");
        defer allocator.free(notifications);
        try writeAll(io, .stderr, notifications);
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        const prompt = try renderStaticInteractivePrompt(allocator, &interactive_shell.semantic_state);
        defer allocator.free(prompt);
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        const physical_cwd = cwd_buffer[0..cwd_len];
        const cwd = if (interactiveGetEnv(&interactive_shell.semantic_state, "PWD")) |pwd| if (pwd.len != 0) pwd else physical_cwd else physical_cwd;
        history.current_cwd = physical_cwd;
        try terminal.reportCurrentDirectory(cwd, terminal_hostname);
        const title = try terminalTitlePath(allocator, cwd, interactiveGetEnv(&interactive_shell.semantic_state, "HOME"));
        defer if (title.owned) allocator.free(title.text);
        try terminal.reportWindowTitle(title.text);
        var interactive_context: InteractiveContext = .{ .semantic_state = &interactive_shell.semantic_state, .arg_zero = options.arg_zero, .features = options.features };
        const read_options: editor_driver.ReadLineOptions = .{
            .prompt = prompt,
            .editing_mode = interactiveEditingMode(interactive_shell.semantic_state.options),
            .hook_context = &interactive_context,
            .run_hooks = runInteractiveIntervalHooks,
            .next_hook_interval_ms = nextInteractiveIntervalMs,
            .history = history_service.lineEditorView(io),
            .external_editor_command = interactiveExternalEditorCommand(&interactive_shell.semantic_state),
            .external_editor_tmpdir = interactiveExternalEditorTmpdir(&interactive_shell.semantic_state),
        };
        const read_result = try terminal.readLine(read_options);
        if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
        const line = switch (read_result) {
            .submitted => |line| line,
            .canceled => {
                if (try runInteractiveInterruptTrap(allocator, io, &interactive_shell.semantic_state, options.arg_zero, options.features)) |result| {
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
                    if (interactivePendingExit(&interactive_shell)) |status| {
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
                if (interactivePendingExit(&interactive_shell)) |status| {
                    last_status = status;
                    break;
                }
                continue;
            },
            .eof => {
                if (!interactive_shell.semantic_state.options.ignoreeof) break;
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
            continuation_options.prompt = interactivePromptText(&interactive_shell.semantic_state, "PS2", "> ");
            continuation_options.diagnostic_context = null;
            continuation_options.diagnose = null;
            const continuation_read_result = try terminal.readLine(continuation_options);
            if (interactive_shell.semantic_enabled) try syncSemanticTerminalSize(&interactive_shell.semantic_state, terminal);
            const continuation_line = switch (continuation_read_result) {
                .submitted => |continuation_line| continuation_line,
                .canceled => {
                    if (try runInteractiveInterruptTrap(allocator, io, &interactive_shell.semantic_state, options.arg_zero, options.features)) |result| {
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
                        if (interactivePendingExit(&interactive_shell)) |status| {
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
                    if (interactivePendingExit(&interactive_shell)) |status| {
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
            if (shouldWarnBeforeExitWithStoppedJobs(&interactive_shell.semantic_state)) {
                try terminal.finishSemanticCommand(0);
                try writeAll(io, .stderr, stopped_jobs_exit_warning);
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
            var result = try runInteractiveScript(allocator, io, &interactive_shell, input, .{ .io = io, .allow_external = true, .features = options.features, .external_stdio = .inherit, .interactive = true, .arg_zero = options.arg_zero });
            const command_duration_ms = durationMillis(command_started, monotonicTimestamp(io));
            defer result.deinit();
            try writeAll(io, .stdout, result.stdout);
            try writeAll(io, .stderr, result.stderr);
            if (outputNeedsNewlineMarker(result.stdout, result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
            last_status = result.status;
            if (!history_service.consumeSuppressNextAppend()) try history_service.addCommand(io, input, result.status, command_started_at, command_duration_ms);
            try terminal.finishSemanticCommand(result.status);
            if (interactivePendingExit(&interactive_shell)) |status| {
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

fn runInteractiveInterruptTrap(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) !?CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (shell_state.trapDisposition(.INT) != .caught) return null;
    try shell_state.appendPendingTrap(.INT);
    return executeInteractivePendingTraps(allocator, io, shell_state, arg_zero, features);
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
    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    try interactive_shell.initializeSemanticStartup(io, &empty_env, .{});
    {
        var result = try runSemanticShellStateScript(allocator, io, &interactive_shell.semantic_state, embedded_config, embedded_config_path, "rush", .{}, .capture);
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
    }

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (interactivePendingExit(&interactive_shell)) |status| {
            last_status = status;
            break;
        }
        const notifications = if (interactive_shell.semantic_enabled)
            try drainInteractiveSemanticJobNotifications(allocator, io, &interactive_shell.semantic_state)
        else
            try allocator.dupe(u8, "");
        try stderr.appendSlice(allocator, notifications);
        allocator.free(notifications);
        const prompt = try renderStaticInteractivePrompt(allocator, &interactive_shell.semantic_state);
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
        if (!history_service.consumeSuppressNextAppend()) try history_service.addCommand(io, line, result.status, command_started_at, 0);
        if (interactivePendingExit(&interactive_shell)) |status| {
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

pub fn runScriptWithOptions(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions) !CommandResult {
    return runScriptWithEnvironment(allocator, io, script, options, null);
}

pub fn runScriptWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions, environ_map: ?*const std.process.Environ.Map) !CommandResult {
    return runCommandStringWithEnvironment(allocator, io, script, options, environ_map, &.{}, null, .{});
}

fn runShellInvocationWithEnvironment(allocator: std.mem.Allocator, io: std.Io, invocation: ShellInvocation, environ_map: ?*const std.process.Environ.Map, external_stdio: runtime.ExternalStdio, login_shell: bool) !CommandResult {
    var owned_script: ?[]const u8 = null;
    defer if (owned_script) |script| allocator.free(script);

    var options: RunOptions = .{
        .io = io,
        .allow_external = true,
        .features = invocation.features,
        .external_stdio = external_stdio,
        .arg_zero = invocation.arg_zero,
    };
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
    const interactive_options: ?InteractiveOptions = if (invocation.interactive) .{ .arg_zero = invocation.arg_zero, .login = login_shell, .features = invocation.features, .shell_options = invocation.shell_options, .monitor_option_explicit = invocation.monitor_option_explicit, .positionals = invocation.positionals } else null;
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

fn runCommandStringWithEnvironment(allocator: std.mem.Allocator, io: std.Io, script: []const u8, options: RunOptions, environ_map: ?*const std.process.Environ.Map, positionals: []const []const u8, interactive_options: ?InteractiveOptions, shell_options: shell.ShellOptions) !CommandResult {
    const semantic_invocation = semanticInvocationFromRunOptions(options);
    if (interactive_options) |startup_options| {
        var interactive_run_options = options;
        interactive_run_options.interactive = true;
        var interactive_shell = InteractiveShell.init(allocator);
        defer interactive_shell.deinit();
        var empty_env = std.process.Environ.Map.init(allocator);
        defer empty_env.deinit();
        const startup_env = environ_map orelse &empty_env;
        var startup_shell_options = shell_options;
        setInteractiveStartupShellOptions(&startup_shell_options, startup_options.monitor_option_explicit, stdinIsTty(io));
        try interactive_shell.initializeSemanticStartup(io, startup_env, .{
            .arg_zero = startup_options.arg_zero,
            .login = startup_options.login,
            .features = startup_options.features,
            .shell_options = startup_shell_options,
            .monitor_option_explicit = startup_options.monitor_option_explicit,
            .positionals = positionals,
        });
        try loadInteractiveConfig(allocator, io, &interactive_shell.semantic_state, startup_options);
        if (interactivePendingExit(&interactive_shell)) |status| return emptyCommandResult(allocator, status);
        return runInteractiveScript(allocator, io, &interactive_shell, script, interactive_run_options);
    }
    if (semantic_invocation.interactive or !options.allow_external) {
        return unsupportedSemanticCommandResult(allocator, "non-interactive command strings must run through the semantic executor");
    }
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

fn runSemanticShellStateScript(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, script: []const u8, source_path: []const u8, arg_zero: []const u8, features: compat.Features, external_stdio: runtime.ExternalStdio) !CommandResult {
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    std.debug.assert(arg_zero.len != 0);
    std.debug.assert(source_path.len != 0);
    if (script.len == 0) return emptyCommandResult(allocator, shell_state.last_status);

    const invocation = shell.InvocationContext.init(.{ .features = features, .arg_zero = arg_zero, .source = .script_file, .interactive = true });
    var semantic_execution = if (semanticScriptNeedsAliasTiming(script))
        try runSemanticAliasTimingShellStateScript(allocator, io, shell_state, script, invocation, external_stdio)
    else
        try runSemanticShellStateScriptWithoutAliasTiming(allocator, io, shell_state, script, invocation, external_stdio);
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

fn runSemanticShellStateScriptWithoutAliasTiming(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    shell_state.validate();
    invocation.validate();

    var parsed = try parser.parse(allocator, script, .{ .features = invocation.features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return .{ .output = try parseDiagnosticsResult(allocator, script, parsed.diagnostics) };

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features, false)) |message| return semanticUnsupported(allocator, message);

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

    return runSemanticLoweredProgram(allocator, script, program, &evaluator, shell_state, eval_context, resolver, null, 0, false);
}

fn runSemanticAliasTimingShellStateScript(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    shell_state.validate();
    invocation.validate();

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
    var status = shell_state.last_status;
    var start = skipSemanticChunkSeparators(script, 0);
    while (start < script.len) {
        var end = extendSemanticHereDocChunk(script, start, semanticLineEnd(script, start));
        while (true) {
            const source = std.mem.trim(u8, script[start..end], " \t\r\n;");
            if (source.len == 0) break;
            const aliased = try semanticExpandAliases(allocator, source, invocation.features, shell_state);
            defer allocator.free(aliased);
            var parsed = try parser.parse(allocator, aliased, .{ .features = invocation.features.withStrictDiagnostics() });
            defer parsed.deinit();
            if (parsed.diagnostics.len == 0) {
                var program = try ir.lowerSimpleCommands(allocator, parsed);
                defer program.deinit();
                if (try semanticPreflightUnsupported(allocator, program, invocation.features, false)) |message| return semanticUnsupported(allocator, message);
                var alias_snapshot = shell_state.clone(allocator) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ReadonlyVariable => unreachable,
                };
                defer alias_snapshot.deinit();
                parser_resolver.alias_state = &alias_snapshot;
                var execution = try runSemanticLoweredProgram(allocator, aliased, program, &evaluator, shell_state, eval_context, resolver, null, 0, false);
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

    const out = try stdout.toOwnedSlice(allocator);
    errdefer allocator.free(out);
    const err = try stderr.toOwnedSlice(allocator);
    return .{ .output = .{ .allocator = allocator, .status = status, .stdout = out, .stderr = err } };
}

fn runInteractiveScript(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *InteractiveShell, script: []const u8, options: RunOptions) !CommandResult {
    std.debug.assert(options.interactive);
    if (interactive_shell.semantic_enabled) {
        var semantic_execution = try runSemanticInteractiveCommandString(allocator, io, interactive_shell, script, semanticInvocationFromRunOptions(options), options.external_stdio);
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

    return unsupportedSemanticCommandResult(allocator, "semantic interactive executor is disabled while legacy interactive services are active");
}

fn runSemanticInteractiveCommandString(allocator: std.mem.Allocator, io: std.Io, interactive_shell: *InteractiveShell, script: []const u8, invocation: shell.InvocationContext, external_stdio: runtime.ExternalStdio) !SemanticInvocationExecution {
    assertSemanticInteractiveOptions(script, invocation);

    const shell_state = &interactive_shell.semantic_state;
    std.debug.assert(interactive_shell.semantic_enabled);
    shell_state.validate();
    std.debug.assert(shell_state.scope == .current_shell);
    if (external_stdio != .inherit and external_stdio != .capture) return semanticUnsupported(allocator, "semantic interactive executor requires inherited or captured stdio");
    if (invocation.stdin_script_file != null) return semanticUnsupported(allocator, "semantic interactive executor does not consume script stdin files");
    if (shell_state.pending_exit != null) return semanticUnsupported(allocator, "semantic interactive executor does not run while an exit is pending");
    if (shell_state.options.verbose or shell_state.options.xtrace or shell_state.options.errexit) return semanticUnsupported(allocator, "semantic interactive executor does not yet preserve verbose/xtrace/errexit state");

    var parsed = try parser.parse(allocator, script, .{ .mode = .interactive, .features = invocation.features.withStrictDiagnostics() });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) return semanticUnsupported(allocator, "semantic interactive parser diagnostics are not handled by this path yet");

    var program = try ir.lowerSimpleCommands(allocator, parsed);
    defer program.deinit();
    if (try semanticPreflightUnsupported(allocator, program, invocation.features, true)) |message| return semanticUnsupported(allocator, message);
    if (semanticInteractiveProgramUnsupported(shell_state.*, program)) |message| return semanticUnsupported(allocator, message);

    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.features = invocation.features;
    evaluator.arg_zero = invocation.arg_zero;
    evaluator.external_stdio = external_stdio;
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
        switch (control_flow) {
            .exit, .fatal => |exit_status| shell_state.setPendingExit(exit_status),
            .normal, .break_loop, .continue_loop, .return_from_scope => {},
        }

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

fn semanticInvocationFromRunOptions(options: RunOptions) shell.InvocationContext {
    return shell.InvocationContext.init(.{
        .features = options.features,
        .arg_zero = options.arg_zero,
        .source = semanticInputSourceFromRunOptions(options),
        .interactive = options.interactive,
        .stdin_script_file = options.stdin_script_file,
        .stdin_script_source_offset = options.stdin_script_source_offset,
    });
}

fn semanticInputSourceFromRunOptions(options: RunOptions) shell.InputSource {
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

fn semanticInteractiveProgramUnsupported(shell_state: shell.ShellState, program: ir.Program) ?[]const u8 {
    shell_state.validate();
    if (program.function_definitions.len != 0) return "semantic interactive executor does not yet preserve function definitions";
    if (shell_state.aliases.count() != 0) return "semantic interactive executor does not yet preserve alias-aware parsing";
    if (shell_state.options.nounset and semanticProgramUsesShellExpansion(program)) return "semantic interactive executor does not yet preserve nounset expansion diagnostics";

    for (program.commands) |command| {
        if (command.argv.len == 0) continue;
        const root = command.argv[0];
        if (shell.builtin.lookup(root.text) != null and !semanticInteractiveBuiltinRootAllowed(root.text)) return "semantic interactive executor reports unsupported builtins as diagnostics";
        if (shell_state.functions.count() != 0) {
            if (wordMayUseShellExpansion(root.raw)) return "semantic interactive executor does not yet preserve dynamic function lookup";
            if (shell_state.functions.contains(root.text)) return "semantic interactive executor does not yet preserve shell function calls";
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
            if (commandUsesUnsupportedSemanticBuiltin(command, false)) return "semantic executor preflight found an unsupported builtin";
            if (commandUsesUnsupportedProductionExpansion(command)) return "semantic executor production preflight found an expansion shape outside the switched slice";
            if (command.argv.len == 0 and command.redirections.len != 0) return "semantic executor does not yet support redirection-only commands";
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

const InteractiveConfigService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},

    fn init(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, arg_zero: []const u8, features: compat.Features) InteractiveConfigService {
        shell_state.validate();
        std.debug.assert(shell_state.scope == .current_shell);
        return .{ .allocator = allocator, .io = io, .shell_state = shell_state, .arg_zero = arg_zero, .features = features };
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
        var result = try runSemanticShellStateScript(self.allocator, self.io, self.shell_state, contents, source_path, self.arg_zero, self.features, .capture);
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
        return userStartupPathForShellState(self.allocator, self.shell_state.*, file_name);
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
        self.shell_state.validate();
        return if (self.shell_state.getVariable(name)) |variable| variable.value else null;
    }

    fn pendingExit(self: InteractiveConfigService) ?shell.ExitStatus {
        self.shell_state.validate();
        return self.shell_state.pending_exit;
    }

    fn expandParametersScalar(self: InteractiveConfigService, text: []const u8, features: compat.Features) ![]const u8 {
        self.shell_state.validate();
        var adapter = runtime.PosixAdapter.init(self.io);
        var expansion = shell.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true }),
            .fs_port = runtime.posixPorts(&adapter).fs,
            .features = features,
            .arg_zero = self.arg_zero,
        });
        defer expansion.deinit();
        return expansion.expandParametersScalar(text);
    }
};

fn loadInteractiveConfig(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, options: InteractiveOptions) !void {
    try InteractiveConfigService.init(allocator, io, shell_state, options.arg_zero, options.features).load(options);
}

fn sourceOptionalConfig(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, path: []const u8, arg_zero: []const u8) !void {
    try InteractiveConfigService.init(allocator, io, shell_state, arg_zero, .{}).sourceOptional(path);
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

fn sourceConfigScript(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, contents: []const u8, source_path: []const u8, arg_zero: []const u8) !void {
    try InteractiveConfigService.init(allocator, io, shell_state, arg_zero, .{}).sourceScript(contents, source_path);
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

test "runReplInput reports unsupported exit builtin without legacy fallback" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "echo before\nexit 7\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("$ before\n$ $ ", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
}

test "runReplInput reports unsupported fc history bridge without legacy fallback" {
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

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "$ one\n$ two\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
}

test "interactive notify schedules editor job notification polling" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var context: InteractiveContext = .{ .semantic_state = &shell_state };

    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
    try shell_state.appendJobNotification(.{ .job_id = 1, .state = .done, .command = "sleep 1" });
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));

    shell_state.options.notify = true;
    try std.testing.expectEqual(@as(?u64, immediate_notify_poll_ms), try nextInteractiveIntervalMs(&context, std.testing.io));

    shell_state.consumeJobNotifications(1);
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
}

test "interactive semantic job notifications drain from ShellState" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    shell_state.options.notify = true;
    try shell_state.appendJobNotification(.{ .job_id = 1, .state = .done, .command = "sleep 1" });

    var context: InteractiveContext = .{ .semantic_state = &shell_state };

    try std.testing.expectEqual(@as(?u64, immediate_notify_poll_ms), try nextInteractiveIntervalMs(&context, std.testing.io));
    const hook_result = try runInteractiveIntervalHooks(&context, std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(hook_result.output);

    try std.testing.expectEqualStrings("[1] Done sleep 1\n", hook_result.output);
    try std.testing.expectEqual(@as(usize, 0), shell_state.pending_job_notifications.items.len);
    try std.testing.expectEqual(@as(?u64, null), try nextInteractiveIntervalMs(&context, std.testing.io));
}

test "interactive hooks dispatch pending semantic signal trap" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.TERM, "echo term-trap");
    try shell_state.appendPendingTrap(.TERM);

    var context: InteractiveContext = .{ .semantic_state = &shell_state };

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
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.setTrapForSignal(.INT, "echo trapped");

    var result = (try runInteractiveInterruptTrap(std.testing.allocator, std.testing.io, &shell_state, "rush", .{})) orelse return error.MissingTrapResult;
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

test "command string semantic source operands report unsupported" {
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

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(result.stderr.len != 0);
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
    try std.testing.expect(std.mem.indexOf(u8, nounset.stderr, "parameter not set") != null);

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
    var no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = noexec_invocation.arg_zero },
        null,
        noexec_invocation.positionals,
        null,
        noexec_invocation.shell_options,
    );
    defer no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), no_execute.status);
    try std.testing.expectEqualStrings("", no_execute.stdout);
    try std.testing.expect(no_execute.stderr.len != 0);

    const invalid_noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "x=for; $x i in 1; do echo $i; done" }) orelse return error.ExpectedInvocation;
    var invalid_no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_noexec_invocation.arg_zero },
        null,
        invalid_noexec_invocation.positionals,
        null,
        invalid_noexec_invocation.shell_options,
    );
    defer invalid_no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_no_execute.status);
    try std.testing.expectEqualStrings("", invalid_no_execute.stdout);
    try std.testing.expect(invalid_no_execute.stderr.len != 0);

    const invalid_elif_noexec_invocation = parseCommandStringInvocation(&.{ "rush", "-n", "-c", "if false; then :; elif true; fi" }) orelse return error.ExpectedInvocation;
    var invalid_elif_no_execute = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        invalid_elif_noexec_invocation.source,
        .{ .io = std.testing.io, .arg_zero = invalid_elif_noexec_invocation.arg_zero },
        null,
        invalid_elif_noexec_invocation.positionals,
        null,
        invalid_elif_noexec_invocation.shell_options,
    );
    defer invalid_elif_no_execute.deinit();

    try std.testing.expectEqual(@as(shell.ExitStatus, 2), invalid_elif_no_execute.status);
    try std.testing.expectEqualStrings("", invalid_elif_no_execute.stdout);
    try std.testing.expect(invalid_elif_no_execute.stderr.len != 0);
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
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var false_result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "false", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer false_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 1), false_result.status);
    try std.testing.expectEqualStrings("", false_result.stdout);
    try std.testing.expectEqualStrings("", false_result.stderr);
    try std.testing.expectEqual(@as(shell.ExitStatus, 1), interactive_shell.semantic_state.last_status);

    var status_result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "echo $?", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer status_result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), status_result.status);
    try std.testing.expectEqualStrings("1\n", status_result.stdout);
    try std.testing.expectEqualStrings("", status_result.stderr);
}

test "semantic interactive shell state persists variable mutations without legacy execution" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var assign = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "RUSH_INTERACTIVE_SEMANTIC=state", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer assign.deinit(std.testing.allocator);
    switch (assign) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expectEqualStrings("state", interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_SEMANTIC").?.value);

    var readback = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "printf '%s\n' \"$RUSH_INTERACTIVE_SEMANTIC\"", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer readback.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), readback.status);
    try std.testing.expectEqualStrings("state\n", readback.stdout);
    try std.testing.expectEqualStrings("", readback.stderr);
}

test "semantic interactive assignment-bearing commands preserve assignment lifetime without legacy fallback" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var temporary = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "RUSH_INTERACTIVE_TEMPORARY=discarded true", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer temporary.deinit(std.testing.allocator);
    switch (temporary) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expect(interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_TEMPORARY") == null);

    var persistent = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "RUSH_INTERACTIVE_SPECIAL=persistent :", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer persistent.deinit(std.testing.allocator);
    switch (persistent) {
        .output => |output| try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status),
        .unsupported => return error.ExpectedSemanticOutput,
    }
    try std.testing.expectEqualStrings("persistent", interactive_shell.semantic_state.getVariable("RUSH_INTERACTIVE_SPECIAL").?.value);
}

test "semantic interactive external commands run through runtime ports without legacy fallback" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var external = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "/usr/bin/printf 'semantic-external\\n'", shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .capture);
    defer external.deinit(std.testing.allocator);
    switch (external) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |output| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), output.status);
            try std.testing.expectEqualStrings("semantic-external\n", output.stdout);
            try std.testing.expectEqualStrings("", output.stderr);
        },
    }
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
}

test "interactive config service sources simple config through semantic ShellState" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });
    try sourceConfigScript(std.testing.allocator, std.testing.io, &interactive_shell.semantic_state,
        \\RUSH_SEMANTIC_CONFIG=loaded
        \\RUSH_SEMANTIC_CONFIG_SECOND=ok
    , "semantic-config-test.rush", "rush");
    try std.testing.expectEqualStrings("loaded", interactive_shell.semantic_state.getVariable("RUSH_SEMANTIC_CONFIG").?.value);
    try std.testing.expectEqualStrings("ok", interactive_shell.semantic_state.getVariable("RUSH_SEMANTIC_CONFIG_SECOND").?.value);
}

test "semantic interactive command reports function-shadowed builtin unsupported" {
    const path = "rush-semantic-interactive-function-fallback.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });
    try sourceConfigScript(std.testing.allocator, std.testing.io, &interactive_shell.semantic_state, "echo() { printf 'function\\n' > " ++ path ++ "; }", "semantic-interactive-test.rush", "rush");

    var result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "echo semantic", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("semantic interactive executor does not yet preserve shell function calls\n", result.stderr);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
}

test "semantic interactive unset function reports unsupported without legacy bridge" {
    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });
    try sourceConfigScript(std.testing.allocator, std.testing.io, &interactive_shell.semantic_state, "rush_semantic_unset_fn() { :; }", "semantic-interactive-test.rush", "rush");
    try std.testing.expect(interactive_shell.semantic_state.functions.contains("rush_semantic_unset_fn"));

    var result = try runInteractiveScript(std.testing.allocator, std.testing.io, &interactive_shell, "unset -f rush_semantic_unset_fn", .{ .io = std.testing.io, .allow_external = true, .external_stdio = .inherit, .interactive = true, .arg_zero = "rush" });
    defer result.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 2), result.status);
    try std.testing.expectEqualStrings("semantic executor preflight found an unsupported builtin\n", result.stderr);
    try std.testing.expect(interactive_shell.semantic_state.functions.contains("rush_semantic_unset_fn"));
}

test "semantic interactive invocation executes simple command redirections without legacy fallback" {
    const path = "rush-semantic-interactive-redirection.tmp";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    var interactive_shell = InteractiveShell.init(std.testing.allocator);
    defer interactive_shell.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try interactive_shell.initializeSemanticStartup(std.testing.io, &env, .{ .arg_zero = "rush" });

    var semantic = try runSemanticInteractiveCommandString(std.testing.allocator, std.testing.io, &interactive_shell, "echo before > " ++ path ++ "; echo redirected >> " ++ path, shell.InvocationContext.init(.{ .interactive = true, .arg_zero = "rush" }), .inherit);
    defer semantic.deinit(std.testing.allocator);
    switch (semantic) {
        .unsupported => return error.ExpectedSemanticExecution,
        .output => |result| {
            try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
            try std.testing.expectEqualStrings("", result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        },
    }

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
            \\env
        , .{ .io = std.testing.io, .allow_external = true }, &env);
        defer result.deinit();

        const expected = try std.fmt.allocPrint(std.testing.allocator, "<{s}>\n", .{case.expected});
        defer std.testing.allocator.free(expected);
        const exported = try std.fmt.allocPrint(std.testing.allocator, "\nSHLVL={s}\n", .{case.expected});
        defer std.testing.allocator.free(exported);
        try std.testing.expectEqual(@as(shell.ExitStatus, 0), result.status);
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, expected));
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, exported) != null);
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
    var result = try runScriptWithOptions(std.testing.allocator, std.testing.io, "echo ok", .{ .io = std.testing.io, .allow_external = true, .features = .bash() });
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

test "interactive aliases report unsupported without legacy fallback" {
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

    try std.testing.expectEqual(@as(shell.ExitStatus, 127), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "bad\n") == null);
}

test "repl reports alias builtins unsupported without legacy fallback" {
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
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "alias-ok\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "lsx: command not found\n") != null);
}

test "recursive interactive aliases report unsupported without legacy fallback" {
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
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok recursive-trailing-ok\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "self: command not found\n") != null);
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

test "interactive prompt helpers use ShellState prompts and editing mode" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("PS1", "semantic> ", .{});
    try shell_state.putVariable("PS2", "semantic2> ", .{});
    shell_state.options.vi = true;
    shell_state.validate();

    const prompt = try renderStaticInteractivePrompt(std.testing.allocator, &shell_state);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("semantic> ", prompt);
    try std.testing.expectEqualStrings("semantic2> ", interactivePromptText(&shell_state, "PS2", "> "));
    try std.testing.expectEqual(line_editor.EditingMode.vi, interactiveEditingMode(shell_state.options));
}

test "interactive startup initializes prompt variables and sources ENV" {
    const env_path = "rush-test-env-startup.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "ENV_LOADED=ok\nPS1='env> '\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("ENV", env_path, .{ .exported = true });

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("ENV_LOADED").?.value);
    // Embedded default config provides PS2; $ENV overrides the embedded PS1 default.
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
    try std.testing.expectEqualStrings("env> ", shell_state.getVariable("PS1").?.value);
}

test "interactive startup parameter-expands ENV pathname from HOME" {
    const env_path = "rush-test-home-env-startup.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "HOME_ENV_LOADED=ok\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const env_value = try std.fmt.allocPrint(std.testing.allocator, "$HOME/{s}", .{env_path});
    defer std.testing.allocator.free(env_value);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("HOME", cwd, .{ .exported = true });
    try shell_state.putVariable("ENV", env_value, .{ .exported = true });

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("HOME_ENV_LOADED").?.value);
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
        "printf '<%s>\\n' \"$-\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        null,
        &.{},
        .{ .arg_zero = "rush" },
        .{},
    );
    defer default_monitor.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), default_monitor.status);
    try std.testing.expect(std.mem.indexOf(u8, default_monitor.stdout, "m") != null);
    try std.testing.expectEqualStrings("", default_monitor.stderr);

    var explicit_disabled = try runCommandStringWithEnvironment(
        std.testing.allocator,
        std.testing.io,
        "printf '<%s>\\n' \"$-\"",
        .{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" },
        null,
        &.{},
        .{ .arg_zero = "rush", .monitor_option_explicit = true },
        .{},
    );
    defer explicit_disabled.deinit();
    try std.testing.expectEqual(@as(shell.ExitStatus, 0), explicit_disabled.status);
    try std.testing.expect(std.mem.indexOf(u8, explicit_disabled.stdout, "m") == null);
    try std.testing.expectEqualStrings("", explicit_disabled.stderr);
}

fn loadInteractiveConfigCapturingStderr(allocator: std.mem.Allocator, shell_state: *shell.ShellState, stderr_path: []const u8) ![]u8 {
    var stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{ .truncate = true });
    var stderr_file_open = true;
    defer if (stderr_file_open) stderr_file.close(std.testing.io);

    var stderr_guard = try StderrGuard.replaceWith(stderr_file);
    var stderr_guard_active = true;
    defer if (stderr_guard_active) stderr_guard.restore();

    try loadInteractiveConfig(allocator, std.testing.io, shell_state, .{ .arg_zero = "rush" });

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

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("XDG_CONFIG_HOME", root, .{ .exported = true });

    const stderr = try loadInteractiveConfigCapturingStderr(std.testing.allocator, &shell_state, root ++ "/stderr");
    defer std.testing.allocator.free(stderr);

    try std.testing.expectEqualStrings("rush: warning: cannot read " ++ root ++ "/rush/config.rush: is a directory; skipping\n", stderr);
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
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

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("XDG_CONFIG_HOME", root, .{ .exported = true });

    const stderr = try loadInteractiveConfigCapturingStderr(std.testing.allocator, &shell_state, root ++ "/stderr");
    defer std.testing.allocator.free(stderr);

    try std.testing.expectEqualStrings("rush: warning: cannot read " ++ config_path ++ ": permission denied; skipping\n", stderr);
    try std.testing.expect(shell_state.getVariable("CONFIG_LOADED") == null);
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
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
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("PS1", "inherited> ", .{});

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("inherited> ", shell_state.getVariable("PS1").?.value);
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
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
    std.testing.refAllDecls(history_module);
    std.testing.refAllDecls(shell);
    std.testing.refAllDecls(runtime);
    std.testing.refAllDecls(line_editor);
    std.testing.refAllDecls(editor_driver);
}
