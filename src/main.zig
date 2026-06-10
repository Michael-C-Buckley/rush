//! Application entry point.

const std = @import("std");
const build_options = @import("builtin");
const build_config = @import("build_config");
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
    \\       rush complete validate [DIR]
    \\       rush --help
    \\
;

const system_profile_path = build_config.sysconfdir ++ "/rush/profile.rush";
const system_config_path = build_config.sysconfdir ++ "/rush/config.rush";
const embedded_config = @embedFile("default_config");
const embedded_config_path = "embedded:config.rush";
const omitted_newline_marker = "\x1b[2m⏎\x1b[22m\r\n";

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

    if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "complete") and std.mem.eql(u8, args[2], "validate")) {
        const dir = if (args.len == 4) args[3] else "share/rush/completions";
        return validateCompletionScripts(allocator, init.io, dir);
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
        return queryHistorySearchEntry(db, allocator, query, before, .previous);
    }

    pub fn searchNextEntry(self: *History, allocator: std.mem.Allocator, query: []const u8, after: ?i64) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistorySearchEntry(db, allocator, query, after, .next);
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

fn searchNextHistoryEntry(context: *anyopaque, allocator: std.mem.Allocator, query: []const u8, after: ?i64) !?line_editor.HistoryView.HistoryEntry {
    const history: *History = @ptrCast(@alignCast(context));
    return history.searchNextEntry(allocator, query, after);
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
        \\select id, command, started_at from history h
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
        \\select id, command, started_at from history h
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
    return .{ .id = sqlite.sqlite3_column_int64(stmt, 0), .text = try allocator.dupe(u8, std.mem.span(command_text)), .when = sqlite.sqlite3_column_int64(stmt, 2) };
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

fn queryHistorySearchEntry(db: *sqlite.sqlite3, allocator: std.mem.Allocator, query: []const u8, cursor: ?i64, direction: HistoryDirection) !?line_editor.HistoryView.HistoryEntry {
    var fts_query: std.ArrayList(u8) = .empty;
    defer fts_query.deinit(allocator);
    try appendHistoryFtsQuery(allocator, &fts_query, query);
    if (fts_query.items.len == 0) return queryHistoryEntry(db, allocator, "", cursor, direction);

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
        \\    where newer.id > h.id and newer.command = h.command
        \\  )
        \\order by bm25(history_fts), h.id desc
        \\limit 1 offset ?2
        ,
        .next =>
        \\select h.id, h.command, h.started_at
        \\from history_fts f
        \\join history h on h.id = f.rowid
        \\where history_fts match ?1
        \\  and not exists (
        \\    select 1 from history newer
        \\    where newer.id > h.id and newer.command = h.command
        \\  )
        \\order by bm25(history_fts) desc, h.id asc
        \\limit 1 offset ?2
        ,
    };
    try sqliteCheck(sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, fts_query.items.ptr, @intCast(fts_query.items.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 2, offset), db);
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
    try sqliteExec(db, "insert into history_fts(history_fts) values('rebuild');");
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

const InteractiveCompletionContext = struct {
    executor: *exec.Executor,
    history: *const History,
    cache: *CompletionCache,
    loader: *CompletionScriptLoader,
    io: std.Io,
    cwd: []const u8 = "",
    arg_zero: []const u8 = "rush",
    owned_executor: ?*exec.Executor = null,
    owned_history: ?*History = null,
    owned_cache: ?*CompletionCache = null,
    owned_loader: ?*CompletionScriptLoader = null,
    owned_cwd: ?[]u8 = null,
    cancel: ?*completion_model.CancellationToken = null,
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
    const fallback_prompt = completion_context.executor.getEnv("PS1") orelse "$ ";
    return completion_context.executor.renderPrompt(.{
        .io = io,
        .allow_external = true,
        .external_stdio = .inherit,
        .arg_zero = completion_context.arg_zero,
    }, fallback_prompt) catch |err| switch (err) {
        error.RecursivePrompt => try allocator.dupe(u8, fallback_prompt),
        else => |e| return e,
    };
}

fn requestInteractivePromptRepaint(context: *anyopaque) void {
    const terminal: *editor_driver.TerminalSession = @ptrCast(@alignCast(context));
    terminal.requestPromptRedraw();
}

fn runInteractiveIntervalHooks(context: *anyopaque, io: std.Io) !void {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    try completion_context.executor.runDuePromptIntervals(io);
}

fn nextInteractiveIntervalMs(context: *anyopaque, io: std.Io) !?u64 {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    return completion_context.executor.promptIntervalWaitMs(io);
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
        if (try xdgDataHomeCompletionPath(self.allocator, executor.*, command)) |path| {
            defer self.allocator.free(path);
            sourceOptionalConfig(self.allocator, io, executor, path, arg_zero) catch {};
        }
        if (try xdgConfigCompletionPath(self.allocator, executor.*, command)) |path| {
            defer self.allocator.free(path);
            sourceOptionalConfig(self.allocator, io, executor, path, arg_zero) catch {};
        }
    }

    fn loadDataDirs(self: *CompletionScriptLoader, io: std.Io, executor: *exec.Executor, command: []const u8, arg_zero: []const u8) !void {
        const data_dirs = executor.getEnv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        var iter = std.mem.splitScalar(u8, data_dirs, ':');
        while (iter.next()) |dir| {
            if (dir.len == 0) continue;
            const path = try completionPathInDir(self.allocator, dir, command);
            defer self.allocator.free(path);
            sourceOptionalConfig(self.allocator, io, executor, path, arg_zero) catch {};
        }
    }
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
        rankCompletionCandidates(self.allocator, candidates, self.history, self.cwd, self.source) catch return;
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

fn xdgDataHomeCompletionPath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8) !?[]const u8 {
    if (executor.getEnv("XDG_DATA_HOME")) |xdg_data_home| {
        if (xdg_data_home.len != 0) return try completionPathInDir(allocator, xdg_data_home, command);
    }
    if (executor.getEnv("HOME")) |home| {
        if (home.len != 0) {
            const data_home = try std.fs.path.join(allocator, &.{ home, ".local", "share" });
            defer allocator.free(data_home);
            return try completionPathInDir(allocator, data_home, command);
        }
    }
    return null;
}

fn xdgConfigCompletionPath(allocator: std.mem.Allocator, executor: exec.Executor, command: []const u8) !?[]const u8 {
    if (executor.getEnv("XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return try completionPathInDir(allocator, xdg_config_home, command);
    }
    if (executor.getEnv("HOME")) |home| {
        if (home.len != 0) {
            const config_home = try std.fs.path.join(allocator, &.{ home, ".config" });
            defer allocator.free(config_home);
            return try completionPathInDir(allocator, config_home, command);
        }
    }
    return null;
}

fn completeInteractiveLine(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, source: []const u8, cursor: usize) !completion_model.Application {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    const eval_context = try exec.completionEvalContextForInput(allocator, source, cursor);
    if (eval_context.position != .command) {
        try completion_context.loader.ensureLoaded(completion_context.io, completion_context.executor, eval_context.command, completion_context.arg_zero);
    }
    const generation = completion_context.executor.completionGeneration();
    if (completion_context.cache.get(source, cursor, completion_context.cwd, generation)) |cached| {
        try completion_context.cache.startRefresh(completion_context.executor, completion_context.history, completion_context.io, source, cursor, completion_context.cwd, generation);
        return completion_model.applyCandidatesForInput(allocator, source, cached);
    }
    const candidates = try completion_context.executor.collectCompletionsForInput(source, cursor, .{ .io = io, .allow_external = true, .cancel = completion_context.cancel });
    defer completion_context.executor.freeCompletions(candidates);
    try rankCompletionCandidates(allocator, candidates, completion_context.history.*, completion_context.cwd, source);
    try completion_context.cache.put(source, cursor, completion_context.cwd, completion_context.executor.completionGeneration(), candidates);
    return completion_model.applyCandidatesForInput(allocator, source, candidates);
}

fn expandInteractiveAbbreviation(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, cursor: usize, append_space: bool) !?completion_model.Edit {
    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    return completion_context.executor.expandAbbreviationForInput(allocator, source, cursor, append_space);
}

fn diagnoseInteractiveLine(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, source: []const u8) !?line_editor.DiagnosticRender {
    if (source.len == 0) return null;
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive });
    defer parsed.deinit();
    if (parsed.diagnostics.len != 0) {
        const diagnostic = parsed.diagnostics[0];
        return .{
            .line = try std.fmt.allocPrint(allocator, "\x1b[31m{s}\x1b[39m \x1b[2m{s}\x1b[22m", .{ @tagName(diagnostic.kind), diagnostic.message }),
        };
    }

    const completion_context: *InteractiveCompletionContext = @ptrCast(@alignCast(context));
    const diagnostics = try completion_context.executor.completionDiagnosticsForInputOptions(source, source.len, .{ .io = io });
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

fn rankCompletionCandidates(allocator: std.mem.Allocator, candidates: []completion_model.Candidate, history: History, cwd: []const u8, source: []const u8) !void {
    if (history.db) |db| {
        var snapshot = History.init(allocator);
        defer snapshot.deinit();
        try snapshot.loadRecentRows(db, 500);
        std.mem.sort(completion_model.Candidate, candidates, CompletionRankContext{ .history = snapshot, .cwd = cwd, .source = source }, lessThanRankedCompletion);
        return;
    }
    std.mem.sort(completion_model.Candidate, candidates, CompletionRankContext{ .history = history, .cwd = cwd, .source = source }, lessThanRankedCompletion);
}

const CompletionRankContext = struct {
    history: History,
    cwd: []const u8,
    source: []const u8,
};

fn lessThanRankedCompletion(context: CompletionRankContext, a: completion_model.Candidate, b: completion_model.Candidate) bool {
    const a_class = completionRankClass(a);
    const b_class = completionRankClass(b);
    if (a_class != b_class) return a_class < b_class;
    const a_match_rank = completionCandidateRankSortKey(context.source, a);
    const b_match_rank = completionCandidateRankSortKey(context.source, b);
    if (a_match_rank != b_match_rank) return a_match_rank < b_match_rank;
    const a_score = completionRankScore(context.history, context.cwd, a.value);
    const b_score = completionRankScore(context.history, context.cwd, b.value);
    if (a_score != b_score) return a_score > b_score;
    return lessThanCompletionLabel(a, b);
}

fn completionCandidateRankSortKey(source: []const u8, candidate: completion_model.Candidate) u8 {
    if (candidate.replace_start > candidate.replace_end or candidate.replace_end > source.len) return 3;
    const query = source[candidate.replace_start..candidate.replace_end];
    const rank = completion_model.candidateFuzzyMatchRank(candidate, query) orelse return 3;
    return @intFromEnum(rank);
}

fn completionRankClass(candidate: completion_model.Candidate) u8 {
    if (candidate.kind != .option) return 0;
    if (candidate.option) |option| {
        if (option.long == null and option.short != null) return 1;
    }
    return 2;
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

fn debugCompletion(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, source: []const u8) !void {
    const output = try completionDebugOutput(allocator, io, environ_map, source);
    defer allocator.free(output);
    try writeAll(io, .stdout, output);
}

fn semanticCompletionPath(allocator: std.mem.Allocator, context: exec.CompletionSemanticContext) ![]const u8 {
    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(allocator);
    for (context.path, 0..) |segment, index| {
        if (index != 0) try path.append(allocator, ' ');
        try path.appendSlice(allocator, segment);
    }
    return path.toOwnedSlice(allocator);
}

fn debugCompletionRuleMatches(rule: completion_model.Rule, context: exec.CompletionSemanticContext) bool {
    if (!std.mem.eql(u8, rule.root, context.root)) return false;
    if (rule.path.len > context.path.len) return false;
    for (rule.path, context.path[0..rule.path.len]) |expected, actual| {
        if (!std.mem.eql(u8, expected, actual)) return false;
    }
    return true;
}

fn validateCompletionScripts(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        var buf: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buf);
        defer writer.interface.flush() catch {};
        try writer.interface.print("rush: cannot open completion directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return 2;
    };
    defer dir.close(io);

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout.interface.flush() catch {};
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    defer stderr.interface.flush() catch {};

    const result = try validateCompletionScriptsInDir(allocator, io, dir, &stderr.interface);
    if (result.failures == 0) {
        try stdout.interface.print("validated {d} completion scripts in {s}\n", .{ result.checked, dir_path });
        return 0;
    }
    try stderr.interface.print("{d} of {d} completion scripts failed validation in {s}\n", .{ result.failures, result.checked, dir_path });
    return 1;
}

const CompletionValidationResult = struct {
    checked: usize = 0,
    failures: usize = 0,
};

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
    var semantic = try executor.analyzeCompletionsForInput(source, source.len);
    defer semantic.deinit();
    const semantic_path = try semanticCompletionPath(allocator, semantic);
    defer allocator.free(semantic_path);
    const candidates = try executor.collectCompletionsForInput(source, source.len, .{ .io = io, .allow_external = true });
    defer executor.freeCompletions(candidates);
    const effective_context = executor.lastCompletionContext() orelse context;
    try rankCompletionCandidates(allocator, candidates, history, cwd, source);
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
        \\semantic:
        \\  root: {s}
        \\  path: {s}
        \\  position: {s}
        \\  prefix: {s}
        \\  replace: {d}..{d}
        \\rules:
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
        semantic.root,
        semantic_path,
        @tagName(semantic.position),
        semantic.prefix,
        semantic.replace_start,
        semantic.replace_end,
    });
    for (executor.completionRules()) |rule| {
        if (!debugCompletionRuleMatches(rule, semantic)) continue;
        try out.writer.print("  - kind: {s}\n    root: {s}\n    path:", .{
            @tagName(rule.kind),
            rule.root,
        });
        for (rule.path) |segment| try out.writer.print(" {s}", .{segment});
        try out.writer.print("\n    value: {s}\n", .{rule.value orelse ""});
    }
    for (candidates) |candidate| {
        const prefix = if (candidate.replace_end <= source.len and candidate.replace_start <= candidate.replace_end) source[candidate.replace_start..candidate.replace_end] else "";
        const match_rank = completion_model.candidateFuzzyMatchRank(candidate, prefix);
        try out.writer.print("  - value: {s}\n    kind: {s}\n    description: {s}\n    replace: {d}..{d}\n    matches-prefix: {}\n    rank-score: {d}\n", .{
            candidate.value,
            @tagName(candidate.kind),
            candidate.description orelse "",
            candidate.replace_start,
            candidate.replace_end,
            match_rank != null,
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
    try executor.initializeShellVariables(io);
    executor.arg_zero = options.arg_zero;
    try loadInteractiveConfig(allocator, io, &executor, options);
    var terminal = try editor_driver.TerminalSession.init(allocator, io);
    defer terminal.deinit();
    try syncInteractiveTerminalSize(&executor, terminal);
    executor.setPromptRepaintHandler(&terminal, requestInteractivePromptRepaint);

    var completion_cache = CompletionCache.init(completion_allocator);
    defer completion_cache.deinit();
    var completion_loader = CompletionScriptLoader.init(allocator);
    defer completion_loader.deinit();

    while (true) {
        terminal.refreshWinsize();
        try syncInteractiveTerminalSize(&executor, terminal);
        const notifications = try executor.drainJobNotifications();
        try writeAll(io, .stderr, notifications);
        allocator.free(notifications);
        try executor.runPendingVariableHooks(io);
        try executor.runPromptEventHooks(io, "prompt", &.{});
        const fallback_prompt = executor.getEnv("PS1") orelse "$ ";
        const prompt = executor.renderPrompt(.{ .io = io, .allow_external = true, .external_stdio = .inherit, .arg_zero = options.arg_zero }, fallback_prompt) catch |err| switch (err) {
            error.RecursivePrompt => try allocator.dupe(u8, fallback_prompt),
            else => |e| return e,
        };
        defer allocator.free(prompt);
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
        try terminal.reportCurrentDirectory(cwd_buffer[0..cwd_len], history.hostname);
        var completion_context: InteractiveCompletionContext = .{ .executor = &executor, .history = &history, .cache = &completion_cache, .loader = &completion_loader, .io = io, .cwd = cwd_buffer[0..cwd_len], .arg_zero = options.arg_zero };
        const read_result = try terminal.readLine(.{
            .prompt = prompt,
            .prompt_refresh_interval_ms = executor.promptRefreshIntervalMs(),
            .hook_context = &completion_context,
            .run_hooks = runInteractiveIntervalHooks,
            .next_hook_interval_ms = nextInteractiveIntervalMs,
            .prompt_context = &completion_context,
            .refresh_prompt = renderInteractivePrompt,
            .history = .{
                .now = unixTimestamp(io),
                .context = &history,
                .previous = previousHistoryEntry,
                .next = nextHistoryEntry,
                .search = searchHistoryEntry,
                .search_next = searchNextHistoryEntry,
                .suggest = suggestHistoryEntry,
            },
            .completion_context = &completion_context,
            .complete = completeInteractiveLine,
            .clone_completion_context = cloneInteractiveCompletionContext,
            .free_completion_context = freeInteractiveCompletionContext,
            .expand_abbreviation = expandInteractiveAbbreviation,
            .diagnostic_context = &completion_context,
            .diagnose = diagnoseInteractiveLine,
        });
        try syncInteractiveTerminalSize(&executor, terminal);
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
            try executor.runPromptEventHooks(io, "preexec", &.{line});
            var result = try runScriptWithExecutor(allocator, &executor, line, .{ .io = io, .allow_external = true, .external_stdio = .inherit, .arg_zero = options.arg_zero });
            const command_duration_ms = durationMillis(command_started, monotonicTimestamp(io));
            defer result.deinit();
            try writeAll(io, .stdout, result.stdout);
            try writeAll(io, .stderr, result.stderr);
            if (outputNeedsNewlineMarker(result.stdout, result.stderr)) try writeAll(io, .stderr, omitted_newline_marker);
            last_status = result.status;
            executor.setLastCommandDuration(command_duration_ms);
            try history.addCommand(io, line, result.status, command_started_at, command_duration_ms);
            var status_buffer: [3]u8 = undefined;
            const status_text = try std.fmt.bufPrint(&status_buffer, "{d}", .{result.status});
            try executor.runPromptEventHooks(io, "postexec", &.{ line, status_text });
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

fn outputNeedsNewlineMarker(stdout: []const u8, stderr: []const u8) bool {
    const output = if (stderr.len != 0) stderr else stdout;
    if (output.len == 0) return false;
    return output[output.len - 1] != '\n';
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
    {
        var result = try runScriptWithExecutor(allocator, &executor, embedded_config, .{ .io = io, .allow_external = true, .arg_zero = "rush", .source_path = embedded_config_path });
        defer result.deinit();
        try stdout.appendSlice(allocator, result.stdout);
        try stderr.appendSlice(allocator, result.stderr);
    }

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const notifications = try executor.drainJobNotifications();
        try stderr.appendSlice(allocator, notifications);
        allocator.free(notifications);
        const prompt = try executor.renderPrompt(.{ .io = io, .allow_external = true, .arg_zero = "rush" }, executor.getEnv("PS1") orelse "$ ");
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
    var executor = exec.Executor.init(allocator);
    defer executor.deinit();
    if (environ_map) |map| try executor.importEnvironment(map);
    try executor.initializeShellVariables(io);
    executor.arg_zero = options.arg_zero;

    return runScriptWithExecutor(allocator, &executor, script, options);
}

fn runScriptWithExecutor(allocator: std.mem.Allocator, executor: *exec.Executor, script: []const u8, options: exec.ExecuteOptions) !exec.CommandResult {
    _ = options.io;
    return executor.executeScriptSlice(script, options) catch |err| {
        if (err != error.ParseError) return err;
        return scriptDiagnosticsResult(allocator, executor, script, options);
    };
}

fn scriptDiagnosticsResult(allocator: std.mem.Allocator, executor: *exec.Executor, script: []const u8, options: exec.ExecuteOptions) !exec.CommandResult {
    const aliased = try executor.expandAliasesForScript(script);
    defer allocator.free(aliased);
    var parsed = try parser.parse(allocator, aliased, .{ .features = options.features });
    defer parsed.deinit();

    if (parsed.diagnostics.len != 0) {
        return diagnosticsResult(allocator, script, parsed.diagnostics);
    }
    return error.ParseError;
}

fn loadInteractiveConfig(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, options: InteractiveOptions) !void {
    try sourceConfigScript(allocator, io, executor, embedded_config, embedded_config_path, options.arg_zero);

    if (executor.getEnv("ENV")) |env_path| {
        if (env_path.len != 0) try sourceOptionalConfig(allocator, io, executor, env_path, options.arg_zero);
    }

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

    try sourceConfigScript(allocator, io, executor, contents, path, arg_zero);
}

fn sourceConfigScript(allocator: std.mem.Allocator, io: std.Io, executor: *exec.Executor, contents: []const u8, source_path: []const u8, arg_zero: []const u8) !void {
    var result = try runScriptWithExecutor(allocator, executor, contents, .{ .io = io, .allow_external = true, .arg_zero = arg_zero, .source_path = source_path });
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

    const first = (try history.searchEntry(std.testing.allocator, "git sta", null)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("git status", first.text);
    try std.testing.expectEqual(@as(i64, 30), first.when);

    const second = (try history.searchEntry(std.testing.allocator, "git sta", first.id)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo git status", second.text);
    try std.testing.expectEqual(@as(i64, 40), second.when);

    try std.testing.expect(try history.searchEntry(std.testing.allocator, "gco", null) == null);
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
    const entry = (try history.searchEntry(std.testing.allocator, "checkout", null)).?;
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

test "supplied completion scripts validate" {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "share/rush/completions", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    const result = try validateCompletionScriptsInDir(std.testing.allocator, std.testing.io, dir, &stderr.writer);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(result.checked != 0);
    try std.testing.expectEqual(@as(usize, 0), result.failures);
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
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), setup_result.status);

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
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), variable_setup.status);
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
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), path_setup.status);
    const path_completions = try executor.collectCompletionsForInput("cat rush-complete", "cat rush-complete".len, .{ .io = std.testing.io });
    defer executor.freeCompletions(path_completions);
    try std.testing.expect(hasCompletionCandidate(path_completions, path));
}

test "interactive semantic diagnostics render spans without message line" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    var setup_result = try runScriptWithExecutor(std.testing.allocator, &executor,
        \\complete git --subcommand commit
    , .{ .io = std.testing.io });
    defer setup_result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), setup_result.status);

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
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "git ch");

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
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "git ");

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
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "gi");

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
    try rankCompletionCandidates(std.testing.allocator, &candidates, history, "/repo", "git ");

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
    try std.testing.expect(std.mem.indexOf(u8, output, "value: status") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "replacement: status") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, output, "root: git") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "path: commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "position: option") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "kind: option") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "value: --amend") != null);
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
    try std.testing.expectEqualStrings("$ hi\n$ $ ", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runReplInput stops when exit builtin requests shell exit" {
    var result = try runReplInput(std.testing.allocator, std.testing.io, "echo before\nexit 7\necho after\n");
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 7), result.status);
    try std.testing.expectEqualStrings("$ before\n$ ", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runScriptWithEnvironment imports initial shell variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RUSH_IMPORTED_ENV", "present");
    try env.put("IFS", ":");
    try env.put("PWD", "/definitely/not/rush/current/directory");

    var result = try runScriptWithEnvironment(std.testing.allocator, std.testing.io,
        \\case $PPID in ''|*[!0123456789]*) echo bad-ppid ;; *) echo ppid-ok ;; esac
        \\printf '<%s>\n' "$RUSH_IMPORTED_ENV" "$IFS"
        \\case $PWD in /definitely/not/rush/*) echo bad-pwd ;; /*) echo pwd-ok ;; *) echo bad-pwd ;; esac
    , .{ .io = std.testing.io, .allow_external = true }, &env);
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("ppid-ok\n<present>\n< \t\n>\npwd-ok\n", result.stdout);
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
    try std.testing.expectEqualStrings("$ $ alias-ok\n$ alias ll='echo alias-ok'\n$ $ $ ", result.stdout);
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

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
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

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
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

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("alias-ok\nhello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "prompt rendering subcommands are scoped while repaint is public" {
    var prompt_result = try runScript(std.testing.allocator, std.testing.io, "prompt text hi");
    defer prompt_result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 2), prompt_result.status);
    try std.testing.expectEqualStrings("prompt: not rendering a prompt\n", prompt_result.stderr);

    var repaint_result = try runScript(std.testing.allocator, std.testing.io, "prompt repaint");
    defer repaint_result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), repaint_result.status);
    try std.testing.expectEqualStrings("", repaint_result.stderr);

    var command_result = try runScript(std.testing.allocator, std.testing.io, "command -v prompt");
    defer command_result.deinit();
    try std.testing.expectEqual(@as(exec.ExitStatus, 0), command_result.status);
    try std.testing.expectEqualStrings("prompt\n", command_result.stdout);
}

test "repl uses rush_prompt function to build prompt text" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\rush_prompt() { prompt segment --fg blue custom; prompt text ' > '; }
        \\echo ok
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
    try std.testing.expectEqualStrings("$ \x1b[38;5;4mcustom\x1b[0m > ok\n\x1b[38;5;4mcustom\x1b[0m > ", result.stdout);
}

test "repl uses literal PS1 fallback prompt" {
    var result = try runReplInput(std.testing.allocator, std.testing.io,
        \\PS1='custom> '
        \\echo ok
        \\exit
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(exec.ExitStatus, 0), result.status);
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

test "embedded default config sets prompt defaults without clobbering inherited values" {
    var executor = exec.Executor.init(std.testing.allocator);
    defer executor.deinit();
    try executor.setEnv("PS1", "inherited> ");

    try loadInteractiveConfig(std.testing.allocator, std.testing.io, &executor, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("inherited> ", executor.getEnv("PS1").?);
    try std.testing.expectEqualStrings("> ", executor.getEnv("PS2").?);
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
    try std.testing.expectEqual(@as(exec.ExitStatus, 7), executor.lastStatus());

    executor.waitForPromptAsyncRefreshes();
    try std.testing.expectEqual(@as(usize, 1), repaint.count);

    const warm_prompt = try executor.renderPrompt(.{ .io = std.testing.io, .allow_external = true, .arg_zero = "rush" }, "rush$ ");
    defer std.testing.allocator.free(warm_prompt);
    try std.testing.expectEqualStrings("fresh", warm_prompt);
    try std.testing.expectEqual(@as(exec.ExitStatus, 7), executor.lastStatus());
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
    try std.testing.expectEqual(@as(exec.ExitStatus, 7), executor.lastStatus());
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

    try std.testing.expectEqual(@as(exec.ExitStatus, 2), result.status);
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
