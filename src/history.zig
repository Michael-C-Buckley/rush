//! Command history storage and editor history adapters.

const std = @import("std");
const build_options = @import("builtin");
const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const line_editor = @import("editor.zig").line;

const ExitStatus = u8;

pub const HistoryEntry = struct {
    number: i64,
    command: []const u8,
};

pub const CommandHistory = struct {
    context: *anyopaque,
    list: *const fn (*anyopaque, std.mem.Allocator) anyerror![]HistoryEntry,
    append: ?*const fn (*anyopaque, std.Io, []const u8, ExitStatus, i64, i64) anyerror!void = null,
};

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
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
        status: ExitStatus = 0,
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

    pub fn addCommand(
        self: *History,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        try self.addCommandRecord(io, line, status, started_at, duration_ms, true);
    }

    pub fn appendCommand(
        self: *History,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        try self.addCommandRecord(io, line, status, started_at, duration_ms, false);
    }

    fn addCommandRecord(
        self: *History,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
        dedupe: bool,
    ) !void {
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
        if (self.entries.items.len != 0 and
            std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], record.cmd)) return;
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
        try sqliteCheck(sqlite.sqlite3_open_v2(
            path_z.ptr,
            &db,
            sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX,
            null,
        ), db);
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
        try sqliteCheck(sqlite.sqlite3_open_v2(
            path_z.ptr,
            &db,
            sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_NOMUTEX,
            null,
        ), db);
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
        try sqliteCheck(sqlite.sqlite3_prepare_v2(
            db,
            \\select command, started_at, status, cwd, exit_signal, duration_ms, hostname, session_id
            \\from history order by id desc limit ?1
        ,
            -1,
            &stmt,
            null,
        ), db);
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
                .exit_signal = if (sqlite.sqlite3_column_type(stmt, 4) == sqlite.SQLITE_NULL)
                    null
                else
                    @intCast(sqlite.sqlite3_column_int(stmt, 4)),
                .cwd = std.mem.span(cwd_text),
                .duration_ms = if (sqlite.sqlite3_column_type(stmt, 5) == sqlite.SQLITE_NULL)
                    null
                else
                    sqlite.sqlite3_column_int64(stmt, 5),
                .hostname = std.mem.span(hostname_text),
                .session_id = std.mem.span(session_id_text),
            });
        }
    }

    pub fn previousEntry(
        self: *History,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        cwd: []const u8,
        session_id: []const u8,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(allocator, db, prefix, cwd, session_id, before, .previous);
    }

    pub fn nextEntry(
        self: *History,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        cwd: []const u8,
        session_id: []const u8,
        after: i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(allocator, db, prefix, cwd, session_id, after, .next);
    }

    pub fn numberedEntry(
        self: *History,
        allocator: std.mem.Allocator,
        number: usize,
    ) !?line_editor.HistoryView.HistoryEntry {
        if (number == 0) return null;
        if (self.db) |db| return queryHistoryEntryByNumber(allocator, db, number);
        const index = number - 1;
        if (index >= self.entries.items.len) return null;
        return .{ .id = @intCast(index), .text = try allocator.dupe(u8, self.entries.items[index]) };
    }

    pub fn fcEntries(self: *History, allocator: std.mem.Allocator) ![]HistoryEntry {
        if (self.db) |db| return queryFcHistoryEntries(allocator, db);
        var entries: std.ArrayList(HistoryEntry) = .empty;
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

    pub fn searchEntry(
        self: *History,
        allocator: std.mem.Allocator,
        query: []const u8,
        cwd: []const u8,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistorySearchEntry(allocator, db, query, cwd, before, .previous);
    }

    pub fn searchNextEntry(
        self: *History,
        allocator: std.mem.Allocator,
        query: []const u8,
        cwd: []const u8,
        after: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistorySearchEntry(allocator, db, query, cwd, after, .next);
    }

    pub fn suggestEntry(
        self: *History,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        cwd: []const u8,
    ) !?line_editor.HistoryView.HistoryEntry {
        const db = self.db orelse return null;
        return queryHistoryEntry(allocator, db, prefix, cwd, "", null, .previous);
    }
};

pub const InteractiveHistoryService = struct {
    history: *History,
    suppress_next_append: bool = false,

    pub fn init(history: *History) InteractiveHistoryService {
        return .{ .history = history };
    }

    pub fn lineEditorView(self: *InteractiveHistoryService, io: std.Io) line_editor.HistoryView {
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

    pub fn addCommand(
        self: *InteractiveHistoryService,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        try self.history.addCommand(io, line, status, started_at, duration_ms);
    }

    pub fn suppressNextAppend(self: *InteractiveHistoryService) void {
        self.suppress_next_append = true;
    }

    pub fn consumeSuppressNextAppend(self: *InteractiveHistoryService) bool {
        const suppress = self.suppress_next_append;
        self.suppress_next_append = false;
        return suppress;
    }

    fn previousEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        if (try self.history.previousEntry(
            allocator,
            prefix,
            self.history.current_cwd,
            self.history.session_id,
            before,
        )) |entry| return entry;
        if (self.history.session_id.len == 0) return null;
        if (try self.hasCurrentSessionEntry(allocator, prefix)) return null;
        return self.history.previousEntry(allocator, prefix, self.history.current_cwd, "", before);
    }

    fn nextEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        after: i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        if (try self.history.nextEntry(
            allocator,
            prefix,
            self.history.current_cwd,
            self.history.session_id,
            after,
        )) |entry| return entry;
        if (self.history.session_id.len == 0) return null;
        if (try self.hasCurrentSessionEntry(allocator, prefix)) return null;
        return self.history.nextEntry(allocator, prefix, self.history.current_cwd, "", after);
    }

    fn hasCurrentSessionEntry(self: *InteractiveHistoryService, allocator: std.mem.Allocator, prefix: []const u8) !bool {
        const entry = try self.history.previousEntry(allocator, prefix, self.history.current_cwd, self.history.session_id, null);
        if (entry) |value| {
            value.deinit(allocator);
            return true;
        }
        return false;
    }

    fn numberedEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        number: usize,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.numberedEntry(allocator, number);
    }

    fn fcEntries(self: *InteractiveHistoryService, allocator: std.mem.Allocator) ![]HistoryEntry {
        return self.history.fcEntries(allocator);
    }

    fn appendFcCommand(
        self: *InteractiveHistoryService,
        io: std.Io,
        line: []const u8,
        status: ExitStatus,
        started_at: i64,
        duration_ms: i64,
    ) !void {
        try self.history.appendCommand(io, line, status, started_at, duration_ms);
    }

    fn searchEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        query: []const u8,
        before: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.searchEntry(allocator, query, self.history.current_cwd, before);
    }

    fn searchNextEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        query: []const u8,
        after: ?i64,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.searchNextEntry(allocator, query, self.history.current_cwd, after);
    }

    fn suggestEntry(
        self: *InteractiveHistoryService,
        allocator: std.mem.Allocator,
        prefix: []const u8,
    ) !?line_editor.HistoryView.HistoryEntry {
        return self.history.suggestEntry(allocator, prefix, self.history.current_cwd);
    }
};

fn previousHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    prefix: []const u8,
    before: ?i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.previousEntry(allocator, prefix, before);
}

fn nextHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    prefix: []const u8,
    after: i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.nextEntry(allocator, prefix, after);
}

fn numberedHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    number: usize,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.numberedEntry(allocator, number);
}

fn searchHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    query: []const u8,
    before: ?i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.searchEntry(allocator, query, before);
}

fn searchNextHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    query: []const u8,
    after: ?i64,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.searchNextEntry(allocator, query, after);
}

fn suggestHistoryEntry(
    context: *anyopaque,
    allocator: std.mem.Allocator, // ziglint-ignore: Z023 (callback iface)
    prefix: []const u8,
) !?line_editor.HistoryView.HistoryEntry {
    const history_service: *InteractiveHistoryService = @ptrCast(@alignCast(context));
    return history_service.suggestEntry(allocator, prefix);
}

fn applyLineHistoryRequest(session: *line_editor.LineSession, history: line_editor.HistoryView) !void {
    const request = session.takeHistoryRequest() orelse return;
    defer request.deinit(std.testing.allocator);
    const context = history.context orelse return try session.applyHistoryResult(request, .{ .entry = null });
    const result: line_editor.HistoryResult = switch (request) {
        .previous => |previous| if (history.previous) |callback|
            .{ .entry = try callback(context, std.testing.allocator, previous.prefix, previous.before) }
        else
            .{ .entry = null },
        .next => |next| if (history.next) |callback|
            .{ .entry = try callback(context, std.testing.allocator, next.prefix, next.after) }
        else
            .{ .entry = null },
        .by_number => |number| if (history.by_number) |callback|
            .{ .entry = try callback(context, std.testing.allocator, number) }
        else
            .{ .entry = null },
        .search,
        .search_next,
        => .{ .entries = &.{} },
        .suggest => .{ .entry = null },
    };
    try session.applyHistoryResult(request, result);
}

const HistoryDirection = enum { previous, next };

fn exitSignalFromStatus(status: ExitStatus) ?u8 {
    if (status < 128) return null;
    return status - 128;
}

fn queryHistoryEntry(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    prefix: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    cursor: ?i64,
    direction: HistoryDirection,
) !?line_editor.HistoryView.HistoryEntry {
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
    try sqliteCheck(sqlite.sqlite3_bind_text(
        stmt,
        2,
        like_pattern.items.ptr,
        @intCast(like_pattern.items.len),
        null,
    ), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 3, cwd.ptr, @intCast(cwd.len), null), db);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 4, session_id.ptr, @intCast(session_id.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = sqlite.sqlite3_column_int64(stmt, 0),
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

fn queryHistoryEntryByNumber(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    number: usize,
) !?line_editor.HistoryView.HistoryEntry {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select id, command, started_at from history where id = ?1",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_int64(stmt, 1, @intCast(number)), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc == sqlite.SQLITE_DONE) return null;
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    const command_text = sqlite.sqlite3_column_text(stmt, 1) orelse return null;
    return .{
        .id = sqlite.sqlite3_column_int64(stmt, 0),
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
}

fn queryFcHistoryEntries(allocator: std.mem.Allocator, db: *sqlite.sqlite3) ![]HistoryEntry {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select id, command from history order by id asc",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var entries: std.ArrayList(HistoryEntry) = .empty;
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

fn queryHistorySearchEntry(
    allocator: std.mem.Allocator,
    db: *sqlite.sqlite3,
    query: []const u8,
    cwd: []const u8,
    cursor: ?i64,
    direction: HistoryDirection,
) !?line_editor.HistoryView.HistoryEntry {
    var fts_query: std.ArrayList(u8) = .empty;
    defer fts_query.deinit(allocator);
    try appendHistoryFtsQuery(allocator, &fts_query, query);
    if (fts_query.items.len == 0) return queryHistoryEntry(allocator, db, "", cwd, "", cursor, direction);

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
    return .{
        .id = offset + 1,
        .text = try allocator.dupe(u8, std.mem.span(command_text)),
        .when = sqlite.sqlite3_column_int64(stmt, 2),
    };
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
    );
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteHistoryDbFilesIfExists(io: std.Io, path: []const u8) !void {
    var wal_buffer: [4096]u8 = undefined;
    var shm_buffer: [4096]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_buffer, "{s}-wal", .{path});
    const shm_path = try std.fmt.bufPrint(&shm_buffer, "{s}-shm", .{path});

    try deleteFileIfExists(io, path);
    try deleteFileIfExists(io, wal_path);
    try deleteFileIfExists(io, shm_path);
}

fn insertHistoryRecord(db: *sqlite.sqlite3, record: History.HistoryRecord) !void {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        \\insert into history(command, cwd, status, exit_signal, started_at, duration_ms, hostname, session_id)
        \\values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    ,
        -1,
        &stmt,
        null,
    ), db);
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
    try sqliteCheck(sqlite.sqlite3_bind_text(
        stmt,
        8,
        record.session_id.ptr,
        @intCast(record.session_id.len),
        null,
    ), db);
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
    try sqliteCheck(sqlite.sqlite3_prepare_v2(
        db,
        "select count(*) from history_fts where history_fts match ?1",
        -1,
        &stmt,
        null,
    ), db);
    defer _ = sqlite.sqlite3_finalize(stmt);
    try sqliteCheck(sqlite.sqlite3_bind_text(stmt, 1, query.ptr, @intCast(query.len), null), db);
    const rc = sqlite.sqlite3_step(stmt);
    if (rc != sqlite.SQLITE_ROW) try sqliteCheck(rc, db);
    return sqlite.sqlite3_column_int(stmt, 0);
}

pub fn localHostname(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&buffer) catch return allocator.dupe(u8, "");
    return allocator.dupe(u8, hostname);
}

pub fn sessionId(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const pid = std.c.getpid();
    const started_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return std.fmt.allocPrint(allocator, "{d}:{d}", .{ pid, started_ns });
}

pub fn defaultPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !?[]const u8 {
    if (environ_map.get("XDG_STATE_HOME")) |xdg_state_home| {
        if (xdg_state_home.len != 0)
            return try std.fs.path.join(allocator, &.{ xdg_state_home, "rush", "history.sqlite" });
    }
    if (environ_map.get("HOME")) |home| {
        if (home.len != 0)
            return try std.fs.path.join(allocator, &.{ home, ".local", "state", "rush", "history.sqlite" });
    }
    return null;
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
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
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
    try std.testing.expectEqual(@as(ExitStatus, 0), loaded.records.items[0].status);
    try std.testing.expectEqualStrings("/tmp", loaded.records.items[0].cwd);
}

test "history writes commands through to sqlite fts" {
    const path = "rush-history-fts-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
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
    try std.testing.expectEqual(@as(ExitStatus, 130), reloaded.records.items[0].status);
    try std.testing.expectEqual(@as(?u8, 2), reloaded.records.items[0].exit_signal);
    try std.testing.expectEqual(@as(i64, 55), reloaded.records.items[0].duration_ms.?);

    const count = try historyFtsMatchCount(reloaded.db.?, "checkout");
    try std.testing.expectEqual(@as(c_int, 1), count);
}

test "history exposes POSIX fc command numbers from sqlite" {
    const path = "rush-history-fc-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
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
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
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
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
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
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
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
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var history_a = History.init(std.testing.allocator);
    defer history_a.deinit();
    try history_a.load(std.testing.io, path);
    history_a.current_cwd = "/repo";
    history_a.session_id = "session-a";
    var history_service_a = InteractiveHistoryService.init(&history_a);
    try insertHistoryRecord(history_a.db.?, .{
        .cmd = "echo a-one",
        .cwd = "/repo",
        .when = 10,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history_a.db.?, .{
        .cmd = "echo b-one",
        .cwd = "/repo",
        .when = 20,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history_a.db.?, .{
        .cmd = "git status",
        .cwd = "/repo",
        .when = 30,
        .session_id = "session-a",
    });
    try insertHistoryRecord(history_a.db.?, .{
        .cmd = "git diff",
        .cwd = "/repo",
        .when = 40,
        .session_id = "session-b",
    });
    try insertHistoryRecord(history_a.db.?, .{
        .cmd = "echo a-other",
        .cwd = "/other",
        .when = 50,
        .session_id = "session-a",
    });

    var history_b = History.init(std.testing.allocator);
    defer history_b.deinit();
    try history_b.load(std.testing.io, path);
    history_b.current_cwd = "/repo";
    history_b.session_id = "session-b";
    var history_service_b = InteractiveHistoryService.init(&history_b);

    const history_view_a: line_editor.HistoryView = .{
        .context = &history_service_a,
        .previous = previousHistoryEntry,
        .next = nextHistoryEntry,
    };
    var session_a = try line_editor.LineSession.initWithOptions(
        std.testing.allocator,
        .{ .bytes = "$ " },
        history_view_a,
    );
    defer session_a.deinit();
    try session_a.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("git status", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("echo a-one", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("git status", session_a.editor.buffer.text());
    try session_a.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_a, history_view_a);
    try std.testing.expectEqualStrings("", session_a.editor.buffer.text());

    const history_view_b: line_editor.HistoryView = .{
        .context = &history_service_b,
        .previous = previousHistoryEntry,
        .next = nextHistoryEntry,
    };
    var session_b = try line_editor.LineSession.initWithOptions(
        std.testing.allocator,
        .{ .bytes = "$ " },
        history_view_b,
    );
    defer session_b.deinit();
    try session_b.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("git diff", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("echo b-one", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("git diff", session_b.editor.buffer.text());
    try session_b.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session_b, history_view_b);
    try std.testing.expectEqualStrings("", session_b.editor.buffer.text());
}

test "line history falls back to persisted cwd history for new sessions" {
    const path = "rush-history-session-fallback-test.sqlite";
    try deleteHistoryDbFilesIfExists(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-wal") catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path ++ "-shm") catch {};

    var stored_history = History.init(std.testing.allocator);
    defer stored_history.deinit();
    try stored_history.load(std.testing.io, path);
    try insertHistoryRecord(stored_history.db.?, .{
        .cmd = "echo older",
        .cwd = "/repo",
        .when = 10,
        .session_id = "old-session",
    });
    try insertHistoryRecord(stored_history.db.?, .{
        .cmd = "git status",
        .cwd = "/repo",
        .when = 20,
        .session_id = "old-session",
    });
    try insertHistoryRecord(stored_history.db.?, .{
        .cmd = "echo elsewhere",
        .cwd = "/other",
        .when = 30,
        .session_id = "old-session",
    });

    var new_history = History.init(std.testing.allocator);
    defer new_history.deinit();
    try new_history.load(std.testing.io, path);
    new_history.current_cwd = "/repo";
    new_history.session_id = "new-session";
    var history_service = InteractiveHistoryService.init(&new_history);
    const history_view: line_editor.HistoryView = .{
        .context = &history_service,
        .previous = previousHistoryEntry,
        .next = nextHistoryEntry,
    };
    var session = try line_editor.LineSession.initWithOptions(
        std.testing.allocator,
        .{ .bytes = "$ " },
        history_view,
    );
    defer session.deinit();

    try session.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session, history_view);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try applyLineHistoryRequest(&session, history_view);
    try std.testing.expectEqualStrings("echo older", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try applyLineHistoryRequest(&session, history_view);
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "history path follows XDG state home then HOME fallback" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("XDG_STATE_HOME", "/state");
    try env.put("HOME", "/home/me");
    const xdg_path = (try defaultPath(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(xdg_path);
    try std.testing.expectEqualStrings("/state/rush/history.sqlite", xdg_path);

    try env.put("XDG_STATE_HOME", "");
    const home_path = (try defaultPath(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(home_path);
    try std.testing.expectEqualStrings("/home/me/.local/state/rush/history.sqlite", home_path);
}
