//! Application entry point.

const std = @import("std");
const build_options = @import("builtin");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

pub const compat = @import("compat.zig");
pub const parser = @import("parser.zig");
pub const expand = @import("expand.zig");
pub const ir = @import("ir.zig");
pub const exec = @import("exec.zig");
pub const line_editor = @import("line_editor.zig");
pub const editor_driver = @import("editor_driver.zig");
pub const completion_model = @import("completion.zig");
pub const event_loop = @import("event_loop.zig");

const usage =
    \\usage: rush [--login]
    \\       rush -c SCRIPT
    \\       rush --posix-strict -c SCRIPT
    \\       rush complete --debug INPUT
    \\       rush --help
    \\
;

const system_profile_path = "/etc/rush/profile.rush";
const system_config_path = "/etc/rush/config.rush";

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const login_shell = isLoginArgZero(args[0]);

    if (args.len == 1) {
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
        try debugCompletion(allocator, init.io, init.environ_map, args[3]);
        return 0;
    }

    var script_arg: ?[]const u8 = null;
    var features: compat.Features = .{};
    if (args.len == 3 and std.mem.eql(u8, args[1], "-c")) {
        script_arg = args[2];
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "--posix-strict") and std.mem.eql(u8, args[2], "-c")) {
        script_arg = args[3];
        features = .strictPosix();
    } else {
        try writeAll(init.io, .stderr, usage);
        return 2;
    }

    var result = try runScriptWithEnvironment(allocator, init.io, script_arg.?, .{ .io = init.io, .allow_external = true, .features = features, .external_stdio = .inherit, .arg_zero = args[0] }, init.environ_map);
    defer result.deinit();

    try writeAll(init.io, .stdout, result.stdout);
    try writeAll(init.io, .stderr, result.stderr);
    return result.status;
}

pub const History = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(HistoryRecord) = .empty,
    entries: std.ArrayList([]const u8) = .empty,
    hostname: []const u8 = "",
    db: ?*sqlite.sqlite3 = null,

    pub const HistoryRecord = struct {
        cmd: []const u8,
        when: i64 = 0,
        status: exec.ExitStatus = 0,
        exit_signal: ?u8 = null,
        cwd: []const u8 = "",
        duration_ms: ?i64 = null,
        hostname: []const u8 = "",
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
        }
        self.records.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        if (self.hostname.len != 0) self.allocator.free(self.hostname);
        self.* = undefined;
    }

    pub fn copyFrom(self: *History, other: *const History) !void {
        self.* = .init(self.allocator);
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
            });
        }
    }

    pub fn add(self: *History, line: []const u8) !void {
        try self.addRecord(.{ .cmd = line });
    }

    pub fn addCommand(self: *History, io: std.Io, line: []const u8, status: exec.ExitStatus, started_at: i64, duration_ms: i64) !void {
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
        };
        if (self.db) |db| {
            try insertHistoryRecord(db, record);
            return;
        }
        try self.addRecord(record);
    }

    fn addRecord(self: *History, record: HistoryRecord) !void {
        if (record.cmd.len == 0) return;
        if (self.entries.items.len != 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], record.cmd)) return;
        const cmd = try self.allocator.dupe(u8, record.cmd);
        errdefer self.allocator.free(cmd);
        const cwd = try self.allocator.dupe(u8, record.cwd);
        errdefer self.allocator.free(cwd);
        const hostname = try self.allocator.dupe(u8, record.hostname);
        errdefer self.allocator.free(hostname);
        try self.records.append(self.allocator, .{
            .cmd = cmd,
            .when = record.when,
            .status = record.status,
            .exit_signal = record.exit_signal,
            .cwd = cwd,
            .duration_ms = record.duration_ms,
            .hostname = hostname,
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
        try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "select command, started_at, status, cwd, exit_signal, duration_ms, hostname from history order by id desc limit ?1", -1, &stmt, null), db);
        defer _ = sqlite.sqlite3_finalize(stmt);
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, @intCast(limit)), db);
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const command_text = sqlite.sqlite3_column_text(stmt, 0) orelse continue;
            const cwd_text = sqlite.sqlite3_column_text(stmt, 3) orelse @as([*c]const u8, @ptrCast(""));
            const hostname_text = sqlite.sqlite3_column_text(stmt, 6) orelse @as([*c]const u8, @ptrCast(""));
            try self.addRecord(.{
                .cmd = std.mem.span(command_text),
                .when = sqlite.sqlite3_column_int64(stmt, 1),
                .status = @intCast(sqlite.sqlite3_column_int(stmt, 2)),
                .exit_signal = if (sqlite.sqlite3_column_type(stmt, 4) == sqlite.SQLITE_NULL) null else @intCast(sqlite.sqlite3_column_int(stmt, 4)),
                .cwd = std.mem.span(cwd_text),
                .duration_ms = if (sqlite.sqlite3_column_type(stmt, 5) == sqlite.SQLITE_NULL) null else sqlite.sqlite3_column_int64(stmt, 5),
                .hostname = std.mem.span(hostname_text),
            });
        }
    }

    pub fn previousEntry(self: *History, allocator: std.mem.Allocator, prefix: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(db, allocator, prefix, before, .previous);
    }

    pub fn nextEntry(self: *History, allocator: std.mem.Allocator, prefix: []const u8, after: i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(db, allocator, prefix, after, .next);
    }

    pub fn searchEntry(self: *History, allocator: std.mem.Allocator, query: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistorySearchEntry(db, allocator, query, before);
    }

    pub fn suggestEntry(self: *History, allocator: std.mem.Allocator, prefix: []const u8) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(db, allocator, prefix, null, .previous);
    }
};

fn previousHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
    const history: *History = @ptrCast(@alignCast(context));
    return history.previousEntry(allocator, prefix, before);
}

fn nextHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8, after: i64) !?line_editor.HistoryView.HistoryEntry {
    const history: *History = @ptrCast(@alignCast(context));
    return history.nextEntry(allocator, prefix, after);
}

fn searchHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, query: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
    const history: *History = @ptrCast(@alignCast(context));
    return history.searchEntry(allocator, query, before);
}

fn suggestHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8) !?line_editor.HistoryView.HistoryEntry {
    const history: *History = @ptrCast(@alignCast(context));
    return history.suggestEntry(allocator, prefix);
}

const HistoryDirection = enum { previous, next };

fn queryHistoryEntry(db: *sqlite.sqlite3, allocator: std.mem.Allocator, prefix: []const u8, cursor: ?i64, direction: HistoryDirection) !?line_editor.HistoryView.HistoryEntry {
    var like_pattern: std.ArrayList(u8) = .empty;
    defer like_pattern.deinit(allocator);
    try appendSqlLikePrefix(allocator, &like_pattern, prefix);

    const sql = switch (direction) {
        .previous =>
        \\select id, command from history h
        \\where (?1 is null or id < ?1)
        \\  and (?2 = '' or command like ?2 escape '\')
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command = h.command
        \\      and (?2 = '' or newer.command like ?2 escape '\')
        \\  )
        \\order by id desc limit 1
        ,
        .next =>
        \\select id, command from history h
        \\where id > ?1
        \\  and (?2 = '' or command like ?2 escape '\')
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command = h.command
        \\      and (?2 = '' or newer.command like ?2 escape '\')
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
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{ .id = sqlite.sqlite3_column_int64(stmt, 0), .text = try allocator.dupe(u8, std.mem.span(command_text)) };
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

fn queryHistorySearchEntry(db: *sqlite.sqlite3, allocator: std.mem.Allocator, query: []const u8, before: ?i64) !?line_editor.HistoryView.HistoryEntry {
    var like_pattern: std.ArrayList(u8) = .empty;
    defer like_pattern.deinit(allocator);
    try like_pattern.append(allocator, '%');
    for (query) |byte| switch (byte) {
        '%', '_', '\\' => {
            try like_pattern.append(allocator, '\\');
            try like_pattern.append(allocator, byte);
        },
        else => try like_pattern.append(allocator, byte),
    };
    try like_pattern.append(allocator, '%');

    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db,
        \\select id, command from history h
        \\where (?1 is null or id < ?1)
        \\  and (?2 = '' or command like ?2 escape '\')
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command = h.command
        \\      and (?2 = '' or newer.command like ?2 escape '\')
        \\  )
        \\order by id desc limit 1
    , -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    if (before) |id| {
        try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, id), db);
    } else {
        try sqliteCheck(sqlite.sqlite3_bind_null(stmt, 1), db);
    }
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 2, like_pattern.items.ptr, @intCast(like_pattern.items.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{ .id = sqlite.sqlite3_column_int64(stmt, 0), .text = try allocator.dupe(u8, std.mem.span(command_text)) };
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
        \\  hostname text not null default ''
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
    );
    addHistoryColumn(db, "exit_signal", "integer") catch {};
    addHistoryColumn(db, "duration_ms", "integer") catch {};
    addHistoryColumn(db, "hostname", "text not null default ''") catch {};
}

fn addHistoryColumn(db: *sqlite.sqlite3, comptime name: []const u8, comptime column_type: []const u8) !void {
    try sqliteExec(db, "alter table history add column " ++ name ++ " " ++ column_type ++ ";");
}

fn insertHistoryRecord(db: *sqlite.sqlite3, record: History.HistoryRecord) !void {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, "insert into history(command, cwd, status, exit_signal, started_at, duration_ms, hostname) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)", -1, &stmt, null), db);
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

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn monotonicTimestamp(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io, .awake);
}

fn durationMillis(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) i64 {
    return @max(start.durationTo(end).raw.toMilliseconds(), 0);
}

fn exitSignalFromStatus(status: exec.ExitStatus) ?u8 {
    if (status < 128) return null;
    return status - 128;
}

pub const Completion = struct {
    text: []const u8,
};

pub const CompletionKind = completion_model.Kind;
pub const CompletionCandidate = completion_model.Candidate;
pub const CompletionEdit = completion_model.Edit;
pub const CompletionApplication = completion_model.Application;
pub const applyCompletionCandidates = completion_model.applyCandidates;
pub const applyCompletionCandidatesForInput = completion_model.applyCandidatesForInput;

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

const InteractiveCompletionContext = struct {
    executor: *exec.Executor,
    history: *const History,
    cache: *CompletionCache,
    io: std.Io,
    cwd: []const u8 = "",
};

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

    pub fn get(self: *CompletionCache, source: []const u8, cursor: usize, cwd: []const u8) ?[]const completion_model.Candidate {
        self.reapRefresh();
        var key_buffer: [4096]u8 = undefined;
        const key = completionCacheKey(&key_buffer, source, cursor, cwd) catch return null;
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        return self.entries.get(key);
    }

    pub fn put(self: *CompletionCache, source: []const u8, cursor: usize, cwd: []const u8, candidates: []const completion_model.Candidate) !void {
        var key_buffer: [4096]u8 = undefined;
        const key = try completionCacheKey(&key_buffer, source, cursor, cwd);
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

    pub fn startRefresh(self: *CompletionCache, executor: *const exec.Executor, history: *const History, io: std.Io, source: []const u8, cursor: usize, cwd: []const u8) !void {
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
    executor: exec.Executor = undefined,
    history: History = .{ .allocator = undefined },
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *CompletionRefresh) void {
        defer self.done.store(true, .release);
        const candidates = self.executor.collectCompletionsForInput(self.source, self.cursor, .{ .io = self.io, .allow_external = true }) catch return;
        defer self.executor.freeCompletions(candidates);
        rankCompletionCandidates(self.allocator, candidates, self.history, self.cwd) catch return;
        self.cache.put(self.source, self.cursor, self.cwd, candidates) catch return;
    }

    fn deinitFields(self: *CompletionRefresh) void {
        self.executor.deinit();
        self.history.deinit();
        self.allocator.free(self.source);
        self.allocator.free(self.cwd);
    }
};

fn completionCacheKey(buffer: []u8, source: []const u8, cursor: usize, cwd: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}\x00{d}\x00{s}", .{ source, cursor, cwd });
}

fn completeInteractiveLine(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, source: []const u8, cursor: usize) !completion_model.Application {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    if (completion_context.cache.get(source, cursor, completion_context.cwd)) |cached| {
        try completion_context.cache.startRefresh(completion_context.executor, completion_context.history, completion_context.io, source, cursor, completion_context.cwd);
        return completion_model.applyCandidatesForInput(allocator, source, cached);
    }
    const candidates = try completion_context.executor.collectCompletionsForInput(source, cursor, .{ .io = io, .allow_external = true });
    defer completion_context.executor.freeCompletions(candidates);
    try rankCompletionCandidates(allocator, candidates, completion_context.history.*, completion_context.cwd);
    try completion_context.cache.put(source, cursor, completion_context.cwd, candidates);
    return completion_model.applyCandidatesForInput(allocator, source, candidates);
}

fn diagnoseInteractiveLine(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8) !?[]const u8 {
    _ = context;
    if (source.len == 0) return null;
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive });
    defer parsed.deinit();
    if (parsed.diagnostics.len == 0) return null;
    const diagnostic = parsed.diagnostics[0];
    const line = try std.fmt.allocPrint(allocator, "\x1b[31m{s}\x1b[39m \x1b[2m{s}\x1b[22m", .{ @tagName(diagnostic.kind), diagnostic.message });
    return line;
}

fn rankCompletionCandidates(allocator: std.mem.Allocator, candidates: []completion_model.Candidate, history: History, cwd: []const u8) !void {
    if (history.db) |db| {
        var snapshot = History.init(allocator);
        defer snapshot.deinit();
        try snapshot.loadRecentRows(db, 500);
        std.mem.sort(completion_model.Candidate, candidates, CompletionRankContext{ .history = snapshot, .cwd = cwd }, lessThanRankedCompletion);
        return;
    }
    std.mem.sort(completion_model.Candidate, candidates, CompletionRankContext{ .history = history, .cwd = cwd }, lessThanRankedCompletion);
}

const CompletionRankContext = struct {
    history: History,
    cwd: []const u8,
};

fn lessThanRankedCompletion(context: CompletionRankContext, a: completion_model.Candidate, b: completion_model.Candidate) bool {
    const a_score = completionRankScore(context.history, context.cwd, a.value);
    const b_score = completionRankScore(context.history, context.cwd, b.value);
    if (a_score != b_score) return a_score > b_score;
    return std.mem.lessThan(u8, a.value, b.value);
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

fn debugCompletion(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, source: []const u8) !void {
    const output = try completionDebugOutput(allocator, io, environ_map, source);
    defer allocator.free(output);
    try writeAll(io, .stdout, output);
}

fn completionDebugOutput(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, source: []const u8) ![]const u8 {
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    try executor.importEnvironment(environ_map);
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
    const provider = executor.completionProvider(context.command);
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = io, .allow_external = true });
    defer executor.freeCompletions(candidates);
    const effective_context = executor.lastCompletionContext() orelse context;
    try rankCompletionCandidates(allocator, candidates, history, cwd);
    const application = try completion_model.applyCandidatesForInput(allocator, source, candidates);
    defer application.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        \\input: {s}
        \\context:
        \\  command: {s}
        \\  prefix: {s}
        \\  previous: {s}
        \\  argument-index: {d}
        \\  position: {s}
        \\  option-name: {s}
        \\  option-spelling: {s}
        \\  replace: {d}..{d}
        \\provider: {s}
        \\candidates:
    , .{
        source,
        effective_context.command,
        effective_context.prefix,
        effective_context.previous,
        effective_context.argument_index,
        if (effective_context.option_value != null) "option_value" else @tagName(effective_context.position),
        if (effective_context.option_value) |option_value| option_value.name else "",
        if (effective_context.option_value) |option_value| option_value.spelling else "",
        effective_context.replace_start,
        effective_context.replace_end,
        if (provider) |p| p.function else "<none>",
    });
    for (candidates) |candidate| {
        const prefix = if (candidate.replace_end <= source.len and candidate.replace_start <= candidate.replace_end) source[candidate.replace_start..candidate.replace_end] else "";
        const matches = std.mem.startsWith(u8, candidate.value, prefix);
        try out.writer.print("  - value: {s}\n    kind: {s}\n    description: {s}\n    replace: {d}..{d}\n    matches-prefix: {}\n    rank-score: {d}\n", .{
            candidate.value,
            @tagName(candidate.kind),
            candidate.description orelse "",
            candidate.replace_start,
            candidate.replace_end,
            matches,
            completionRankScore(history, cwd, candidate.value),
        });
        if (candidate.option) |option| {
            try out.writer.print("    option:\n      long: {s}\n      short: {s}\n      argument: {s}\n", .{
                option.long orelse "",
                option.short orelse "",
                option.argument orelse "",
            });
        }
    }
    try out.writer.print("application:\n", .{});
    switch (application) {
        .none => try out.writer.print("  none\n", .{}),
        .ambiguous => try out.writer.print("  ambiguous\n", .{}),
        .edit => |edit| try out.writer.print("  edit:\n    replace: {d}..{d}\n    replacement: {s}\n    append-space: {}\n", .{ edit.replace_start, edit.replace_end, edit.replacement, edit.append_space }),
    }
    return out.toOwnedSlice();
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
};

pub fn runInteractive(allocator: std.mem.Allocator, completion_allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, options: InteractiveOptions) !u8 {
    installInteractiveSignalHandlers();

    var history = History.init(allocator);
    defer history.deinit();
    const history_path = try historyPath(allocator, environ_map);
    defer if (history_path) |path| allocator.free(path);
    if (history_path) |path| history.load(io, path) catch {};
    defer if (history_path) |path| history.save(io, path) catch {};

    var last_status: exec.ExitStatus = 0;
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    try executor.importEnvironment(environ_map);
    executor.arg_zero = options.arg_zero;
    try loadInteractiveConfig(allocator, io, &executor, options);
    var terminal = try editor_driver.TerminalSession.init(allocator, io);
    defer terminal.deinit();

    var completion_cache = CompletionCache.init(completion_allocator);
    defer completion_cache.deinit();

    while (true) {
        const prompt = executor.renderPrompt(.{ .io = io, .allow_external = true, .external_stdio = .inherit, .arg_zero = options.arg_zero }, "rush$ ") catch |err| switch (err) {
            error.RecursivePrompt => try allocator.dupe(u8, "rush$ "),
            else => |e| return e,
        };
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        var completion_context: InteractiveCompletionContext = .{ .executor = &executor, .history = &history, .cache = &completion_cache, .io = io, .cwd = cwd_buffer[0..cwd_len] };
        const read_result = try terminal.readLine(.{
            .prompt = prompt,
            .history = .{
                .context = &history,
                .previous = previousHistoryEntry,
                .next = nextHistoryEntry,
                .search = searchHistoryEntry,
                .suggest = suggestHistoryEntry,
            },
            .completion_context = &completion_context,
            .complete = completeInteractiveLine,
            .diagnostic_context = &completion_context,
            .diagnose = diagnoseInteractiveLine,
        });
        allocator.free(prompt);
        const line = switch (read_result) {
            .submitted => |line| line,
            .canceled => continue,
            .eof => break,
        };
        defer allocator.free(line);
        if (std.mem.eql(u8, line, "exit")) {
            try terminal.finishSemanticCommand(0);
            break;
        }
        if (line.len == 0) {
            try terminal.finishSemanticCommand(0);
            continue;
        }

        {
            try terminal.leaveEditorMode();
            var editor_mode_left = true;
            defer if (editor_mode_left) terminal.enterEditorMode() catch {};

            const command_started_at = unixTimestamp(io);
            const command_started = monotonicTimestamp(io);
            var result = try runScriptWithExecutor(allocator, &executor, line, .{ .io = io, .allow_external = true, .external_stdio = .inherit, .arg_zero = options.arg_zero });
            const command_duration_ms = durationMillis(command_started, monotonicTimestamp(io));
            defer result.deinit();
            try writeAll(io, .stdout, result.stdout);
            try writeAll(io, .stderr, result.stderr);
            last_status = result.status;
            executor.setLastCommandDuration(command_duration_ms);
            try history.addCommand(io, line, result.status, command_started_at, command_duration_ms);
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
    var parsed = try parser.parse(allocator, aliased, .{ .features = options.features });
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

fn loadInteractiveConfig(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, options: InteractiveOptions) !void {
    if (options.login) {
        try sourceOptionalConfig(allocator, io, executor, system_profile_path, options.arg_zero);
        const user_profile_path = try userStartupPath(allocator, executor.*, "profile.rush");
        defer if (user_profile_path) |path| allocator.free(path);
        if (user_profile_path) |path| try sourceOptionalConfig(allocator, io, executor, path, options.arg_zero);
    }

    try sourceOptionalConfig(allocator, io, executor, system_config_path, options.arg_zero);
    const user_path = try userStartupPath(allocator, executor.*, "config.rush");
    defer if (user_path) |path| allocator.free(path);
    if (user_path) |path| try sourceOptionalConfig(allocator, io, executor, path, options.arg_zero);
}

fn sourceOptionalConfig(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, path: []const u8, arg_zero: []const u8) !void {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(contents);

    var result = try runScriptWithExecutor(allocator, executor, contents, .{ .io = io, .allow_external = true, .arg_zero = arg_zero });
    defer result.deinit();
    if (result.stdout.len != 0) try writeAll(io, .stdout, result.stdout);
    if (result.stderr.len != 0) try writeAll(io, .stderr, result.stderr);
}

fn userConfigPath(allocator: std.mem.Allocator, executor: exec.Executor) !?[]const u8 {
    return userStartupPath(allocator, executor, "config.rush");
}

fn userProfilePath(allocator: std.mem.Allocator, executor: exec.Executor) !?[]const u8 {
    return userStartupPath(allocator, executor, "profile.rush");
}

fn userStartupPath(allocator: std.mem.Allocator, executor: exec.Executor, file_name: []const u8) !?[]const u8 {
    if (executor.getEnv("XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home, "rush", file_name });
    }
    if (executor.getEnv("HOME")) |home| {
        if (home.len != 0) return try std.fs.path.join(allocator, &.{ home, ".config", "rush", file_name });
    }
    return null;
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
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), loaded.records.items[0].status);
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
    try std.testing.expectEqual(@as(exec.ExitStatus, 130), reloaded.records.items[0].status);
    try std.testing.expectEqual(@as(?u8, 2), reloaded.records.items[0].exit_signal);
    try std.testing.expectEqual(@as(i64, 55), reloaded.records.items[0].duration_ms.?);

    const count = try historyFtsMatchCount(reloaded.db.?, "checkout");
    try std.testing.expectEqual(@as(c_int, 1), count);
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
    try cache.put("git ch", 6, "/tmp/project", &candidates);

    const cached = cache.get("git ch", 6, "/tmp/project") orelse return error.MissingCompletionCacheEntry;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqualStrings("checkout", cached[0].value);
    try std.testing.expectEqualStrings("switch branches", cached[0].description.?);
    try std.testing.expect(cache.get("git ch", 5, "/tmp/project") == null);
    try std.testing.expect(cache.get("git ch", 6, "/tmp/other") == null);
}

test "completion cache replaces existing entries" {
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();

    var first = [_]completion_model.Candidate{.{ .value = "checkout", .replace_start = 4, .replace_end = 6 }};
    var second = [_]completion_model.Candidate{.{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 }};
    try cache.put("git ch", 6, "/tmp/project", &first);
    try cache.put("git ch", 6, "/tmp/project", &second);

    const cached = cache.get("git ch", 6, "/tmp/project") orelse return error.MissingCompletionCacheEntry;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqualStrings("cherry-pick", cached[0].value);
}

test "completion cache refresh updates entries in background" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var setup_result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\__rush_complete_git() { completion candidate fresh --kind subcommand; }
        \\complete git --function __rush_complete_git
    , .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), setup_result.status);

    var history = History.init(std.testing.allocator);
    defer history.deinit();
    var cache = CompletionCache.init(std.testing.allocator);
    defer cache.deinit();
    var stale = [_]completion_model.Candidate{.{ .value = "stale", .replace_start = 4, .replace_end = 5 }};
    try cache.put("git f", 5, "/tmp/project", &stale);

    try cache.startRefresh(&executor, &history, std.testing.io, "git f", 5, "/tmp/project");
    cache.waitForRefresh();

    const cached = cache.get("git f", 5, "/tmp/project") orelse return error.MissingCompletionCacheEntry;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqualStrings("fresh", cached[0].value);
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

test "completion application handles no candidates" {
    const candidates = [_]CompletionCandidate{};
    const application = try applyCompletionCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(CompletionApplication.none, application);
}

test "completion application inserts one candidate" {
    const candidates = [_]CompletionCandidate{.{
        .value = "status",
        .kind = .subcommand,
        .replace_start = 4,
        .replace_end = 6,
        .append_space = true,
    }};
    const application = try applyCompletionCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    const edit = application.edit;
    try std.testing.expectEqual(@as(usize, 4), edit.replace_start);
    try std.testing.expectEqual(@as(usize, 6), edit.replace_end);
    try std.testing.expectEqualStrings("status", edit.replacement);
    try std.testing.expect(edit.append_space);
}

test "completion application reports shared-prefix candidates as ambiguous" {
    const candidates = [_]CompletionCandidate{
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 },
    };
    const application = try applyCompletionCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
    try std.testing.expectEqualStrings("checkout", application.ambiguous[0].value);
    try std.testing.expectEqualStrings("cherry-pick", application.ambiguous[1].value);
}

test "completion application reports ambiguous candidates" {
    const candidates = [_]CompletionCandidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 4 },
        .{ .value = "diff", .replace_start = 4, .replace_end = 4 },
    };
    const application = try applyCompletionCandidates(std.testing.allocator, &candidates);
    defer application.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), application.ambiguous.len);
}

test "completion ranking prefers recent successful same-cwd history" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.addRecord(.{ .cmd = "git checkout old", .status = 0, .cwd = "/other" });
    try history.addRecord(.{ .cmd = "git checkout cherry-pick", .status = 1, .cwd = "/repo" });
    try history.addRecord(.{ .cmd = "git checkout checkout", .status = 0, .cwd = "/repo" });

    var candidates = [_]CompletionCandidate{
        .{ .value = "cherry-pick", .replace_start = 4, .replace_end = 6 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 6 },
    };
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo");

    try std.testing.expectEqualStrings("checkout", candidates[0].value);
    try std.testing.expectEqualStrings("cherry-pick", candidates[1].value);
}

test "completion ranking falls back to lexical order" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    var candidates = [_]CompletionCandidate{
        .{ .value = "status", .replace_start = 4, .replace_end = 4 },
        .{ .value = "checkout", .replace_start = 4, .replace_end = 4 },
    };
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo");

    try std.testing.expectEqualStrings("checkout", candidates[0].value);
    try std.testing.expectEqualStrings("status", candidates[1].value);
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
        \\complete git --function __rush_complete_git
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);

    const output = try completionDebugOutput(std.testing.allocator, std.testing.io, &env, "git st");
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "command: git") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "prefix: st") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "provider: __rush_complete_git") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "value: status") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "replacement: status") != null);
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

test "runReplInput stops when exit builtin requests shell exit" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "echo before\nexit 7\necho after\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("rush$ before\nrush$ ", result.stdout);
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

test "strict POSIX mode reports misplaced reserved words" {
    var loose = try runScript(std.testing.allocator, std.testing.io, "then echo bad");
    defer loose.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 127), loose.status);
    try std.testing.expect(std.mem.indexOf(u8, loose.stderr, "then: command not found") != null);

    var strict = try runScriptWithOptions(std.testing.allocator, std.testing.io, "then echo bad", .{ .io = std.testing.io, .allow_external = true, .features = .strictPosix() });
    defer strict.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 2), strict.status);
    try std.testing.expectEqualStrings("", strict.stdout);
    try std.testing.expect(std.mem.indexOf(u8, strict.stderr, "misplaced reserved word") != null);
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

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "function\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "bad\n") == null);
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

    try std.testing.expectEqual(@as(exec.ExitStatus, 127), result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "recursive-ok recursive-trailing-ok\n") != null);
    try std.testing.expectEqualStrings("self: command not found\n", result.stderr);
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
    try std.testing.expectEqualStrings("rush$ \x1b[38;5;4mcustom\x1b[0m > ok\n\x1b[38;5;4mcustom\x1b[0m > ", result.stdout);
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

test "login shell detection follows argv0 dash convention" {
    try std.testing.expect(isLoginArgZero("-rush"));
    try std.testing.expect(isLoginArgZero("/bin/-rush"));
    try std.testing.expect(!isLoginArgZero("rush"));
    try std.testing.expect(!isLoginArgZero("/bin/rush"));
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
    std.testing.refAllDecls(line_editor);
    std.testing.refAllDecls(editor_driver);
}
