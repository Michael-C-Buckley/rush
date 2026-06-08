//! Terminal-independent line editor core.

const Self = @This();

const std = @import("std");
const completion = @import("completion.zig");
const vaxis = @import("vaxis");

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers = .{},
    text: []const u8 = "",
};

pub const Key = union(enum) {
    text,
    enter,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    tab,
    home,
    end,
    escape,
    ctrl_c,
    ctrl_d,
    ctrl_r,
    clear_screen,
    delete_to_start,
    delete_to_end,
    delete_previous_word,
    delete_next_word,
    yank,
    transpose_chars,
    word_left,
    word_right,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};

pub const EditBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    cursor_byte: usize = 0,

    pub fn init(allocator: std.mem.Allocator) EditBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EditBuffer) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn text(self: EditBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn replace(self: *EditBuffer, text_bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text_bytes)) return error.InvalidUtf8;
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(self.allocator, text_bytes);
        self.cursor_byte = self.bytes.items.len;
    }

    pub fn insertText(self: *EditBuffer, text_bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text_bytes)) return error.InvalidUtf8;
        try self.bytes.insertSlice(self.allocator, self.cursor_byte, text_bytes);
        self.cursor_byte += text_bytes.len;
    }

    pub fn replaceRange(self: *EditBuffer, start: usize, end: usize, replacement: []const u8) !void {
        if (start > end or end > self.bytes.items.len) return error.InvalidRange;
        if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
        try self.bytes.replaceRange(self.allocator, start, end - start, replacement);
        self.cursor_byte = start + replacement.len;
    }

    pub fn applyCompletionEdit(self: *EditBuffer, edit: completion.Edit) !void {
        try self.replaceRange(edit.replace_start, edit.replace_end, edit.replacement);
        if (edit.append_space) try self.insertText(" ");
    }

    pub fn moveLeft(self: *EditBuffer) void {
        self.cursor_byte = previousGraphemeStart(self.bytes.items, self.cursor_byte);
    }

    pub fn moveRight(self: *EditBuffer) void {
        self.cursor_byte = nextGraphemeEnd(self.bytes.items, self.cursor_byte);
    }

    pub fn moveHome(self: *EditBuffer) void {
        self.cursor_byte = 0;
    }

    pub fn moveEnd(self: *EditBuffer) void {
        self.cursor_byte = self.bytes.items.len;
    }

    pub fn moveWordLeft(self: *EditBuffer) void {
        self.cursor_byte = previousWordStart(self.bytes.items, self.cursor_byte);
    }

    pub fn moveWordRight(self: *EditBuffer) void {
        self.cursor_byte = nextWordEnd(self.bytes.items, self.cursor_byte);
    }

    pub fn deletePrevious(self: *EditBuffer) void {
        const start = previousGraphemeStart(self.bytes.items, self.cursor_byte);
        if (start == self.cursor_byte) return;
        self.bytes.replaceRange(self.allocator, start, self.cursor_byte - start, "") catch unreachable;
        self.cursor_byte = start;
    }

    pub fn deleteNext(self: *EditBuffer) void {
        const end = nextGraphemeEnd(self.bytes.items, self.cursor_byte);
        if (end == self.cursor_byte) return;
        self.bytes.replaceRange(self.allocator, self.cursor_byte, end - self.cursor_byte, "") catch unreachable;
    }

    pub fn deleteToStart(self: *EditBuffer) void {
        if (self.cursor_byte == 0) return;
        self.bytes.replaceRange(self.allocator, 0, self.cursor_byte, "") catch unreachable;
        self.cursor_byte = 0;
    }

    pub fn deleteToEnd(self: *EditBuffer) void {
        if (self.cursor_byte == self.bytes.items.len) return;
        self.bytes.replaceRange(self.allocator, self.cursor_byte, self.bytes.items.len - self.cursor_byte, "") catch unreachable;
    }

    pub fn deletePreviousWord(self: *EditBuffer) void {
        const start = previousWordStart(self.bytes.items, self.cursor_byte);
        if (start == self.cursor_byte) return;
        self.bytes.replaceRange(self.allocator, start, self.cursor_byte - start, "") catch unreachable;
        self.cursor_byte = start;
    }

    pub fn deleteNextWord(self: *EditBuffer) void {
        const end = nextWordEnd(self.bytes.items, self.cursor_byte);
        if (end == self.cursor_byte) return;
        self.bytes.replaceRange(self.allocator, self.cursor_byte, end - self.cursor_byte, "") catch unreachable;
    }

    pub fn transposeChars(self: *EditBuffer) void {
        if (self.bytes.items.len == 0) return;
        if (self.cursor_byte == 0) self.moveRight();
        const right_end = self.cursor_byte;
        const right_start = previousGraphemeStart(self.bytes.items, right_end);
        if (right_start == right_end) return;
        const left_start = previousGraphemeStart(self.bytes.items, right_start);
        if (left_start == right_start) return;

        var swapped: std.ArrayList(u8) = .empty;
        defer swapped.deinit(self.allocator);
        swapped.appendSlice(self.allocator, self.bytes.items[right_start..right_end]) catch unreachable;
        swapped.appendSlice(self.allocator, self.bytes.items[left_start..right_start]) catch unreachable;
        self.bytes.replaceRange(self.allocator, left_start, right_end - left_start, swapped.items) catch unreachable;
        self.cursor_byte = right_end;
    }

    pub fn cursorDisplayWidth(self: EditBuffer, method: vaxis.gwidth.Method) u16 {
        return vaxis.gwidth.gwidth(self.bytes.items[0..self.cursor_byte], method);
    }
};

pub const Editor = struct {
    buffer: EditBuffer,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .buffer = .init(allocator) };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn handleKey(self: *Editor, event: KeyEvent) !void {
        switch (event.key) {
            .text => try self.buffer.insertText(event.text),
            .left => self.buffer.moveLeft(),
            .right => self.buffer.moveRight(),
            .home => self.buffer.moveHome(),
            .end => self.buffer.moveEnd(),
            .word_left => self.buffer.moveWordLeft(),
            .word_right => self.buffer.moveWordRight(),
            .backspace => self.buffer.deletePrevious(),
            .delete => self.buffer.deleteNext(),
            .delete_to_start => self.buffer.deleteToStart(),
            .delete_to_end => self.buffer.deleteToEnd(),
            .delete_previous_word => self.buffer.deletePreviousWord(),
            .delete_next_word => self.buffer.deleteNextWord(),
            .transpose_chars => self.buffer.transposeChars(),
            .enter, .up, .down, .tab, .escape, .ctrl_c, .ctrl_d, .ctrl_r, .clear_screen, .yank => {},
        }
    }
};

pub const Prompt = struct {
    bytes: []const u8,
    visible_width: ?u16 = null,
};

pub const HistoryView = struct {
    entries: []const []const u8 = &.{},
    context: ?*anyopaque = null,
    previous: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ?i64) anyerror!?HistoryEntry = null,
    next: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, i64) anyerror!?HistoryEntry = null,
    search: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, ?i64) anyerror!?HistoryEntry = null,
    suggest: ?*const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?HistoryEntry = null,

    pub const HistoryEntry = struct {
        id: i64,
        text: []const u8,

        pub fn deinit(self: HistoryEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
        }
    };
};

pub const CompletionMenu = struct {
    candidates: []completion.Candidate = &.{},
    selected: usize = no_selection,
    window_start: usize = 0,

    const no_selection = std.math.maxInt(usize);

    pub fn deinit(self: *CompletionMenu, allocator: std.mem.Allocator) void {
        if (self.candidates.len != 0) completion.freeCandidates(allocator, self.candidates);
        self.* = .{};
    }

    pub fn replace(self: *CompletionMenu, allocator: std.mem.Allocator, candidates: []const completion.Candidate) !void {
        self.deinit(allocator);
        self.candidates = try completion.cloneCandidates(allocator, candidates);
        self.selected = no_selection;
        self.window_start = 0;
    }

    pub fn clear(self: *CompletionMenu, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn isOpen(self: CompletionMenu) bool {
        return self.candidates.len != 0;
    }

    pub fn selectPrevious(self: *CompletionMenu) void {
        if (self.candidates.len == 0) return;
        self.selected = if (self.selected == no_selection or self.selected == 0) self.candidates.len - 1 else self.selected - 1;
    }

    pub fn selectNext(self: *CompletionMenu) void {
        if (self.candidates.len == 0) return;
        self.selected = if (self.selected == no_selection) 0 else (self.selected + 1) % self.candidates.len;
    }

    pub fn selectedCandidate(self: CompletionMenu) ?completion.Candidate {
        if (self.candidates.len == 0 or self.selected == no_selection) return null;
        return self.candidates[self.selected];
    }

    pub fn visibleWindowStart(self: *CompletionMenu, max_rows: usize) usize {
        if (self.candidates.len == 0) return 0;
        if (self.selected == no_selection) {
            self.window_start = 0;
            return 0;
        }
        const visible_rows = @max(max_rows, 1);
        if (self.candidates.len <= visible_rows) {
            self.window_start = 0;
            return 0;
        }
        const last_start = self.candidates.len - visible_rows;
        self.window_start = @min(self.window_start, last_start);
        if (self.selected < self.window_start) {
            self.window_start = self.selected;
        } else if (self.selected >= self.window_start + visible_rows) {
            self.window_start = self.selected + 1 - visible_rows;
        }
        return self.window_start;
    }
};

pub const LineSession = struct {
    allocator: std.mem.Allocator,
    prompt: Prompt,
    editor: Editor,
    history: HistoryView = .{},
    history_index: ?i64 = null,
    saved_edit: std.ArrayList(u8) = .empty,
    history_search_query: std.ArrayList(u8) = .empty,
    history_search_original: std.ArrayList(u8) = .empty,
    history_search_match: ?HistoryView.HistoryEntry = null,
    kill_ring: std.ArrayList(u8) = .empty,
    completion_menu: CompletionMenu = .{},
    state: State = .editing,
    submitted_line: ?[]const u8 = null,
    paste_depth: usize = 0,
    clear_screen_requested: bool = false,

    pub const State = enum {
        editing,
        history_search,
        submitted,
        canceled,
        eof,
    };

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) !LineSession {
        return initWithOptions(allocator, .{ .bytes = prompt }, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, prompt: Prompt, history: HistoryView) !LineSession {
        return .{
            .allocator = allocator,
            .prompt = .{
                .bytes = try allocator.dupe(u8, prompt.bytes),
                .visible_width = prompt.visible_width,
            },
            .editor = .init(allocator),
            .history = history,
        };
    }

    pub fn deinit(self: *LineSession) void {
        if (self.submitted_line) |line| self.allocator.free(line);
        if (self.history_search_match) |entry| entry.deinit(self.allocator);
        self.history_search_original.deinit(self.allocator);
        self.history_search_query.deinit(self.allocator);
        self.completion_menu.deinit(self.allocator);
        self.kill_ring.deinit(self.allocator);
        self.saved_edit.deinit(self.allocator);
        self.editor.deinit();
        self.allocator.free(self.prompt.bytes);
        self.* = undefined;
    }

    pub fn handleKey(self: *LineSession, event: KeyEvent) !void {
        if (self.state != .editing and self.state != .history_search) return;
        if (self.paste_depth != 0) {
            if (event.key == .text or event.key == .enter) {
                const text = if (event.key == .enter) "\n" else event.text;
                try self.editor.handleKey(.{ .key = .text, .text = text });
                self.completion_menu.clear(self.allocator);
            }
            return;
        }
        if (self.state == .history_search) return self.handleHistorySearchKey(event);
        switch (event.key) {
            .enter => {
                if (self.completion_menu.selectedCandidate()) |candidate| {
                    try self.applyCompletionCandidate(candidate);
                    return;
                }
                self.completion_menu.clear(self.allocator);
                std.debug.assert(self.submitted_line == null);
                self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
                self.state = .submitted;
            },
            .escape => {
                self.completion_menu.clear(self.allocator);
                self.state = .canceled;
            },
            .ctrl_c => {
                self.completion_menu.clear(self.allocator);
                self.state = .canceled;
            },
            .ctrl_d => {
                self.completion_menu.clear(self.allocator);
                if (self.editor.buffer.text().len == 0) {
                    self.state = .eof;
                } else {
                    self.editor.buffer.deleteNext();
                }
            },
            .ctrl_r => try self.beginHistorySearch(),
            .clear_screen => {
                self.completion_menu.clear(self.allocator);
                self.clear_screen_requested = true;
            },
            .backspace => {
                self.editor.buffer.deletePrevious();
                self.completion_menu.clear(self.allocator);
            },
            .delete => {
                self.editor.buffer.deleteNext();
                self.completion_menu.clear(self.allocator);
            },
            .delete_to_start => {
                try self.killRange(0, self.editor.buffer.cursor_byte, 0);
                self.completion_menu.clear(self.allocator);
            },
            .delete_to_end => {
                try self.killRange(self.editor.buffer.cursor_byte, self.editor.buffer.text().len, self.editor.buffer.cursor_byte);
                self.completion_menu.clear(self.allocator);
            },
            .delete_previous_word => {
                const start = previousWordStart(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(start, self.editor.buffer.cursor_byte, start);
                self.completion_menu.clear(self.allocator);
            },
            .delete_next_word => {
                const end = nextWordEnd(self.editor.buffer.text(), self.editor.buffer.cursor_byte);
                try self.killRange(self.editor.buffer.cursor_byte, end, self.editor.buffer.cursor_byte);
                self.completion_menu.clear(self.allocator);
            },
            .yank => {
                if (self.kill_ring.items.len != 0) {
                    try self.editor.buffer.insertText(self.kill_ring.items);
                    self.completion_menu.clear(self.allocator);
                }
            },
            .left, .home, .word_left, .word_right => {
                try self.editor.handleKey(event);
                self.completion_menu.clear(self.allocator);
            },
            .right, .end => {
                if (self.editor.buffer.cursor_byte == self.editor.buffer.text().len and try self.acceptAutosuggestion()) {
                    self.completion_menu.clear(self.allocator);
                    return;
                }
                try self.editor.handleKey(event);
                self.completion_menu.clear(self.allocator);
            },
            .up => if (self.completion_menu.isOpen()) self.completion_menu.selectPrevious() else try self.historyPrevious(),
            .down => if (self.completion_menu.isOpen()) self.completion_menu.selectNext() else try self.historyNext(),
            .tab => if (self.completion_menu.isOpen()) {
                if (event.modifiers.shift) self.completion_menu.selectPrevious() else self.completion_menu.selectNext();
            },
            else => {
                try self.editor.handleKey(event);
                if (!self.completion_menu.isOpen()) self.completion_menu.clear(self.allocator);
            },
        }
    }

    pub fn takeClearScreenRequest(self: *LineSession) bool {
        const requested = self.clear_screen_requested;
        self.clear_screen_requested = false;
        return requested;
    }

    pub fn applyCompletion(self: *LineSession, application: completion.Application) !void {
        switch (application) {
            .edit => |edit| {
                try self.editor.buffer.applyCompletionEdit(edit);
                self.completion_menu.clear(self.allocator);
            },
            .ambiguous => |candidates| try self.completion_menu.replace(self.allocator, candidates),
            .none => self.completion_menu.clear(self.allocator),
        }
    }

    pub fn hasCompletionMenu(self: LineSession) bool {
        return self.completion_menu.isOpen();
    }

    pub fn beginPaste(self: *LineSession) void {
        self.paste_depth += 1;
    }

    pub fn endPaste(self: *LineSession) void {
        if (self.paste_depth != 0) self.paste_depth -= 1;
    }

    pub fn renderFrame(self: *LineSession, allocator: std.mem.Allocator, options: RenderOptions) !Frame {
        var render_options = options;
        var status_line: ?[]const u8 = null;
        var suggestion_suffix: ?[]const u8 = null;
        defer if (status_line) |line| allocator.free(line);
        defer if (suggestion_suffix) |suffix| allocator.free(suffix);
        render_options.prompt = self.prompt;
        render_options.completion_menu = self.completion_menu.candidates;
        render_options.completion_selection = self.completion_menu.selected;
        render_options.completion_window_start = self.completion_menu.visibleWindowStart(render_options.menuCandidateRows());
        if (self.state == .history_search) {
            status_line = try std.fmt.allocPrint(allocator, "\x1b[2mhistory `{s}`: {s}\x1b[22m", .{ self.history_search_query.items, if (self.history_search_match) |entry| entry.text else "no match" });
            render_options.status_line = status_line.?;
        } else if (try self.currentAutosuggestion(allocator)) |suggestion| {
            defer suggestion.deinit(allocator);
            const text = self.editor.buffer.text();
            if (std.mem.startsWith(u8, suggestion.text, text) and renderableInlineText(suggestion.text)) {
                suggestion_suffix = try allocator.dupe(u8, suggestion.text[text.len..]);
                render_options.suggestion = suggestion_suffix.?;
            }
        }
        return frameFromLine(allocator, self.editor, render_options);
    }

    pub fn render(self: *LineSession, allocator: std.mem.Allocator, options: RenderOptions) ![]const u8 {
        var frame = try self.renderFrame(allocator, options);
        defer frame.deinit(allocator);
        return serializeFullFrame(allocator, frame, options.synchronized_output);
    }

    pub fn takeSubmittedLine(self: *LineSession) ?[]const u8 {
        const line = self.submitted_line orelse return null;
        self.submitted_line = null;
        return line;
    }

    fn historyPrevious(self: *LineSession) !void {
        const prefix = try self.historyPrefix();
        if (try self.queryPreviousHistory(prefix)) |entry| {
            defer entry.deinit(self.allocator);
            self.history_index = entry.id;
            try self.editor.buffer.replace(entry.text);
            self.completion_menu.clear(self.allocator);
            return;
        }
        if (self.history.entries.len == 0) return;
        const start: usize = if (self.history_index) |index| @intCast(index) else self.history.entries.len;
        const index = self.findPreviousHistoryMatch(start, prefix) orelse return;
        self.history_index = @intCast(index);
        try self.editor.buffer.replace(self.history.entries[index]);
        self.completion_menu.clear(self.allocator);
    }

    fn historyNext(self: *LineSession) !void {
        const index = self.history_index orelse return;
        const prefix = self.saved_edit.items;
        if (try self.queryNextHistory(prefix, index)) |entry| {
            defer entry.deinit(self.allocator);
            self.history_index = entry.id;
            try self.editor.buffer.replace(entry.text);
            self.completion_menu.clear(self.allocator);
            return;
        }
        if (self.history.context != null) {
            self.history_index = null;
            try self.editor.buffer.replace(self.saved_edit.items);
            self.saved_edit.clearRetainingCapacity();
            self.completion_menu.clear(self.allocator);
            return;
        }
        const next_index = self.findNextHistoryMatch(@as(usize, @intCast(index)) + 1, prefix) orelse {
            self.history_index = null;
            try self.editor.buffer.replace(self.saved_edit.items);
            self.saved_edit.clearRetainingCapacity();
            self.completion_menu.clear(self.allocator);
            return;
        };
        self.history_index = @intCast(next_index);
        try self.editor.buffer.replace(self.history.entries[next_index]);
        self.completion_menu.clear(self.allocator);
    }

    fn queryPreviousHistory(self: *LineSession, prefix: []const u8) !?HistoryView.HistoryEntry {
        const context = self.history.context orelse return null;
        const previous = self.history.previous orelse return null;
        return previous(context, self.allocator, prefix, self.history_index);
    }

    fn queryNextHistory(self: *LineSession, prefix: []const u8, after: i64) !?HistoryView.HistoryEntry {
        const context = self.history.context orelse return null;
        const next = self.history.next orelse return null;
        return next(context, self.allocator, prefix, after);
    }

    fn beginHistorySearch(self: *LineSession) !void {
        const search = self.history.search orelse return;
        _ = search;
        self.history_search_query.clearRetainingCapacity();
        self.history_search_original.clearRetainingCapacity();
        try self.history_search_original.appendSlice(self.allocator, self.editor.buffer.text());
        self.clearHistorySearchMatch();
        self.state = .history_search;
        try self.refreshHistorySearch(null);
        self.completion_menu.clear(self.allocator);
    }

    fn handleHistorySearchKey(self: *LineSession, event: KeyEvent) !void {
        switch (event.key) {
            .enter, .tab => {
                if (self.history_search_match) |entry| try self.editor.buffer.replace(entry.text);
                self.finishHistorySearch();
            },
            .escape, .ctrl_c => {
                try self.editor.buffer.replace(self.history_search_original.items);
                self.finishHistorySearch();
            },
            .ctrl_r, .up => try self.refreshHistorySearch(if (self.history_search_match) |entry| entry.id else null),
            .down => try self.refreshHistorySearch(null),
            .backspace => {
                if (self.history_search_query.items.len != 0) {
                    const start = previousGraphemeStart(self.history_search_query.items, self.history_search_query.items.len);
                    self.history_search_query.replaceRange(self.allocator, start, self.history_search_query.items.len - start, "") catch unreachable;
                    try self.refreshHistorySearch(null);
                }
            },
            .text => {
                try self.history_search_query.appendSlice(self.allocator, event.text);
                try self.refreshHistorySearch(null);
            },
            else => {},
        }
    }

    fn refreshHistorySearch(self: *LineSession, before: ?i64) !void {
        self.clearHistorySearchMatch();
        const context = self.history.context orelse return;
        const search = self.history.search orelse return;
        if (try search(context, self.allocator, self.history_search_query.items, before)) |entry| {
            self.history_search_match = entry;
            try self.editor.buffer.replace(entry.text);
        } else {
            try self.editor.buffer.replace(self.history_search_original.items);
        }
    }

    fn finishHistorySearch(self: *LineSession) void {
        self.clearHistorySearchMatch();
        self.history_search_query.clearRetainingCapacity();
        self.history_search_original.clearRetainingCapacity();
        self.state = .editing;
    }

    fn clearHistorySearchMatch(self: *LineSession) void {
        if (self.history_search_match) |entry| entry.deinit(self.allocator);
        self.history_search_match = null;
    }

    fn currentAutosuggestion(self: *LineSession, allocator: std.mem.Allocator) !?HistoryView.HistoryEntry {
        if (self.completion_menu.isOpen()) return null;
        if (self.editor.buffer.cursor_byte != self.editor.buffer.text().len) return null;
        if (self.editor.buffer.text().len == 0) return null;
        const context = self.history.context orelse return null;
        const suggest = self.history.suggest orelse return null;
        return suggest(context, allocator, self.editor.buffer.text());
    }

    fn acceptAutosuggestion(self: *LineSession) !bool {
        if (try self.currentAutosuggestion(self.allocator)) |suggestion| {
            defer suggestion.deinit(self.allocator);
            if (!renderableInlineText(suggestion.text)) return false;
            try self.editor.buffer.replace(suggestion.text);
            self.completion_menu.clear(self.allocator);
            return true;
        }
        return false;
    }

    fn historyPrefix(self: *LineSession) ![]const u8 {
        if (self.history_index == null) {
            self.saved_edit.clearRetainingCapacity();
            try self.saved_edit.appendSlice(self.allocator, self.editor.buffer.text());
        }
        return self.saved_edit.items;
    }

    fn findPreviousHistoryMatch(self: LineSession, start: usize, prefix: []const u8) ?usize {
        var index = start;
        while (index > 0) {
            index -= 1;
            if (self.historyEntryMatches(index, prefix)) return index;
        }
        return null;
    }

    fn findNextHistoryMatch(self: LineSession, start: usize, prefix: []const u8) ?usize {
        var index = start;
        while (index < self.history.entries.len) : (index += 1) {
            if (self.historyEntryMatches(index, prefix)) return index;
        }
        return null;
    }

    fn historyEntryMatches(self: LineSession, index: usize, prefix: []const u8) bool {
        const entry = self.history.entries[index];
        if (prefix.len != 0 and !std.mem.startsWith(u8, entry, prefix)) return false;
        return self.isNewestMatchingCommand(index, prefix);
    }

    fn isNewestMatchingCommand(self: LineSession, index: usize, prefix: []const u8) bool {
        const entry = self.history.entries[index];
        for (self.history.entries[index + 1 ..]) |newer| {
            if (prefix.len != 0 and !std.mem.startsWith(u8, newer, prefix)) continue;
            if (std.mem.eql(u8, newer, entry)) return false;
        }
        return true;
    }

    fn applyCompletionCandidate(self: *LineSession, candidate: completion.Candidate) !void {
        try self.editor.buffer.applyCompletionEdit(.{
            .replace_start = candidate.replace_start,
            .replace_end = candidate.replace_end,
            .replacement = candidate.value,
            .append_space = candidate.append_space,
        });
        self.completion_menu.clear(self.allocator);
    }

    fn killRange(self: *LineSession, start: usize, end: usize, cursor_byte: usize) !void {
        if (start == end) return;
        self.kill_ring.clearRetainingCapacity();
        try self.kill_ring.appendSlice(self.allocator, self.editor.buffer.text()[start..end]);
        try self.editor.buffer.replaceRange(start, end, "");
        self.editor.buffer.cursor_byte = cursor_byte;
        self.completion_menu.clear(self.allocator);
    }
};

pub const Frame = struct {
    lines: []const []const u8,
    cursor_row: usize = 0,
    cursor_col: u16 = 0,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn clone(self: Frame, allocator: std.mem.Allocator) !Frame {
        const lines = try allocator.alloc([]const u8, self.lines.len);
        errdefer allocator.free(lines);
        var initialized: usize = 0;
        errdefer for (lines[0..initialized]) |line| allocator.free(line);
        for (self.lines, 0..) |line, index| {
            lines[index] = try allocator.dupe(u8, line);
            initialized += 1;
        }
        return .{ .lines = lines, .cursor_row = self.cursor_row, .cursor_col = self.cursor_col };
    }
};

pub const FrameRenderer = struct {
    previous: ?Frame = null,

    pub fn deinit(self: *FrameRenderer, allocator: std.mem.Allocator) void {
        if (self.previous) |*previous| previous.deinit(allocator);
        self.* = undefined;
    }

    pub fn render(self: *FrameRenderer, allocator: std.mem.Allocator, frame: Frame, options: FrameRenderOptions) ![]const u8 {
        const output = if (self.previous) |previous| blk: {
            if (frame.lines.len > previous.lines.len) break :blk try serializeFullFrame(allocator, frame, options.synchronized_output);
            break :blk try serializeFrameDiff(allocator, previous, frame, options.synchronized_output);
        } else try serializeFullFrame(allocator, frame, options.synchronized_output);
        errdefer allocator.free(output);
        if (self.previous) |*previous| previous.deinit(allocator);
        self.previous = try frame.clone(allocator);
        return output;
    }

    pub fn reset(self: *FrameRenderer, allocator: std.mem.Allocator) void {
        if (self.previous) |*previous| previous.deinit(allocator);
        self.previous = null;
    }
};

pub const FrameRenderOptions = struct {
    synchronized_output: bool = true,
};

pub const RenderOptions = struct {
    prompt: Prompt = .{ .bytes = "" },
    completion_menu: []const completion.Candidate = &.{},
    completion_selection: usize = 0,
    completion_window_start: usize = 0,
    suggestion: []const u8 = "",
    status_line: []const u8 = "",
    diagnostic_line: []const u8 = "",
    diagnostic_spans: []const DiagnosticSpan = &.{},
    semantic_prompt_marks: bool = false,
    width: u16 = 80,
    height: u16 = 24,
    width_method: vaxis.gwidth.Method = .unicode,
    synchronized_output: bool = true,

    fn menuCandidateRows(self: RenderOptions) usize {
        return @max(@as(usize, @intCast(self.height)) -| 2, 1);
    }
};

pub const DiagnosticSeverity = enum {
    warning,
    err,
};

pub const DiagnosticSpan = struct {
    start: usize,
    end: usize,
    severity: DiagnosticSeverity,
};

pub const DiagnosticRender = struct {
    line: []const u8 = "",
    spans: []const DiagnosticSpan = &.{},

    pub fn deinit(self: DiagnosticRender, allocator: std.mem.Allocator) void {
        if (self.line.len != 0) allocator.free(self.line);
        allocator.free(self.spans);
    }
};

pub const semanticPromptEnd = "\x1b]133;B\x07";

pub fn renderLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) ![]const u8 {
    var frame = try frameFromLine(allocator, editor, options);
    defer frame.deinit(allocator);
    return serializeFullFrame(allocator, frame, options.synchronized_output);
}

pub fn frameFromLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) !Frame {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var input_line: std.ArrayList(u8) = .empty;
    errdefer input_line.deinit(allocator);
    try input_line.appendSlice(allocator, options.prompt.bytes);
    if (options.semantic_prompt_marks) try input_line.appendSlice(allocator, semanticPromptEnd);
    try appendDiagnosticStyledInput(allocator, &input_line, editor.buffer.text(), options.diagnostic_spans);
    if (options.suggestion.len != 0 and renderableInlineText(options.suggestion)) {
        try input_line.appendSlice(allocator, "\x1b[90m");
        try input_line.appendSlice(allocator, options.suggestion);
        try input_line.appendSlice(allocator, "\x1b[39m");
    }
    const input_line_bytes = try input_line.toOwnedSlice(allocator);
    defer allocator.free(input_line_bytes);

    const wrap_width = @max(options.width, 1);
    var cursor_prefix: std.ArrayList(u8) = .empty;
    defer cursor_prefix.deinit(allocator);
    try cursor_prefix.appendSlice(allocator, options.prompt.bytes);
    try cursor_prefix.appendSlice(allocator, editor.buffer.text()[0..editor.buffer.cursor_byte]);
    const cursor_position = wrappedPosition(cursor_prefix.items, wrap_width, options.width_method);

    try appendWrappedLine(allocator, &lines, input_line_bytes, wrap_width, options.width_method);
    if (cursor_position.row == lines.items.len) try lines.append(allocator, try allocator.dupe(u8, ""));
    if (options.status_line.len != 0) try appendWrappedLine(allocator, &lines, options.status_line, wrap_width, options.width_method);
    if (options.diagnostic_line.len != 0) try appendWrappedLine(allocator, &lines, options.diagnostic_line, wrap_width, options.width_method);
    try appendCompletionMenuLines(allocator, &lines, options.completion_menu, options.completion_selection, options.completion_window_start, options.width, options.height);

    return .{
        .lines = try lines.toOwnedSlice(allocator),
        .cursor_row = cursor_position.row,
        .cursor_col = cursor_position.col,
    };
}

fn appendDiagnosticStyledInput(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, spans: []const DiagnosticSpan) !void {
    if (spans.len == 0) {
        try out.appendSlice(allocator, text);
        return;
    }

    var active: ?DiagnosticSeverity = null;
    var i: usize = 0;
    while (i < text.len) {
        var iter = vaxis.unicode.graphemeIterator(text[i..]);
        const grapheme = iter.next() orelse break;
        const grapheme_end = i + grapheme.len;
        const severity = diagnosticSeverityAt(spans, i, grapheme_end);
        if (active != severity) {
            if (active != null) try out.appendSlice(allocator, "\x1b[24;59m");
            if (severity) |value| try out.appendSlice(allocator, diagnosticUnderlineAnsi(value));
            active = severity;
        }
        try out.appendSlice(allocator, text[i..grapheme_end]);
        i = grapheme_end;
    }
    if (active != null) try out.appendSlice(allocator, "\x1b[24;59m");
    if (i < text.len) try out.appendSlice(allocator, text[i..]);
}

fn diagnosticSeverityAt(spans: []const DiagnosticSpan, start: usize, end: usize) ?DiagnosticSeverity {
    for (spans) |span| {
        const span_end = @max(span.end, span.start + 1);
        if (start < span_end and end > span.start) return span.severity;
    }
    return null;
}

fn diagnosticUnderlineAnsi(_: DiagnosticSeverity) []const u8 {
    return "\x1b[4:3;58;5;1m";
}

fn renderableInlineText(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn serializeFullFrame(allocator: std.mem.Allocator, frame: Frame, synchronized_output: bool) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");
    try output.appendSlice(allocator, "\r\x1b[2K");
    if (frame.lines.len != 0) try output.appendSlice(allocator, frame.lines[0]);
    try output.appendSlice(allocator, "\x1b[J");
    for (frame.lines[1..]) |line| {
        try output.appendSlice(allocator, "\r\n");
        try output.appendSlice(allocator, line);
    }
    const cursor_sequence = try cursorMoveFrom(frame.lines.len -| 1, frame.cursor_row, frame.cursor_col, allocator);
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");

    return output.toOwnedSlice(allocator);
}

fn serializeFrameDiff(allocator: std.mem.Allocator, previous: Frame, frame: Frame, synchronized_output: bool) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");

    var current_row = previous.cursor_row;
    const max_lines = @max(previous.lines.len, frame.lines.len);
    for (0..max_lines) |row| {
        const old_line = if (row < previous.lines.len) previous.lines[row] else null;
        const new_line = if (row < frame.lines.len) frame.lines[row] else null;
        const changed = if (old_line) |old| if (new_line) |new| !std.mem.eql(u8, old, new) else true else new_line != null;
        if (!changed) continue;
        const move = try cursorMoveFrom(current_row, row, 0, allocator);
        defer allocator.free(move);
        try output.appendSlice(allocator, move);
        try output.appendSlice(allocator, "\x1b[2K");
        if (new_line) |line| try output.appendSlice(allocator, line);
        current_row = row;
    }

    const cursor_sequence = try cursorMoveFrom(current_row, frame.cursor_row, frame.cursor_col, allocator);
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");
    return output.toOwnedSlice(allocator);
}

fn cursorMoveFrom(from_row: usize, to_row: usize, col: u16, allocator: std.mem.Allocator) ![]const u8 {
    if (col == 0) {
        if (from_row > to_row) return std.fmt.allocPrint(allocator, "\x1b[{d}A\r", .{from_row - to_row});
        if (to_row > from_row) return std.fmt.allocPrint(allocator, "\x1b[{d}B\r", .{to_row - from_row});
        return allocator.dupe(u8, "\r");
    }
    if (from_row > to_row) return std.fmt.allocPrint(allocator, "\x1b[{d}A\r\x1b[{d}C", .{ from_row - to_row, col });
    if (to_row > from_row) return std.fmt.allocPrint(allocator, "\x1b[{d}B\r\x1b[{d}C", .{ to_row - from_row, col });
    return std.fmt.allocPrint(allocator, "\r\x1b[{d}C", .{col});
}

fn appendWrappedLine(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), bytes: []const u8, width: u16, method: vaxis.gwidth.Method) !void {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(allocator);
    var row_width: u16 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (escapeSequenceEnd(bytes, i)) |end| {
            try row.appendSlice(allocator, bytes[i..end]);
            i = end;
            continue;
        }

        var iter = vaxis.unicode.graphemeIterator(bytes[i..]);
        const grapheme = iter.next() orelse break;
        const grapheme_bytes = bytes[i .. i + grapheme.len];
        const grapheme_width = vaxis.gwidth.gwidth(grapheme_bytes, method);
        if (row_width != 0 and row_width + grapheme_width > width) {
            try lines.append(allocator, try row.toOwnedSlice(allocator));
            row = .empty;
            row_width = 0;
        }
        try row.appendSlice(allocator, grapheme_bytes);
        row_width += grapheme_width;
        i += grapheme.len;
        if (row_width == width and i < bytes.len) {
            try lines.append(allocator, try row.toOwnedSlice(allocator));
            row = .empty;
            row_width = 0;
        }
    }
    try lines.append(allocator, try row.toOwnedSlice(allocator));
}

const WrappedPosition = struct {
    row: usize,
    col: u16,
};

fn wrappedPosition(bytes: []const u8, width: u16, method: vaxis.gwidth.Method) WrappedPosition {
    var row: usize = 0;
    var col: u16 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (escapeSequenceEnd(bytes, i)) |end| {
            i = end;
            continue;
        }
        var iter = vaxis.unicode.graphemeIterator(bytes[i..]);
        const grapheme = iter.next() orelse break;
        const grapheme_width = vaxis.gwidth.gwidth(bytes[i .. i + grapheme.len], method);
        if (col != 0 and col + grapheme_width > width) {
            row += 1;
            col = 0;
        }
        col += grapheme_width;
        i += grapheme.len;
        if (col == width) {
            row += 1;
            col = 0;
        }
    }
    return .{ .row = row, .col = col };
}

fn escapeSequenceEnd(bytes: []const u8, index: usize) ?usize {
    if (index >= bytes.len or bytes[index] != 0x1b) return null;
    if (index + 1 >= bytes.len) return bytes.len;
    if (bytes[index + 1] == '[') {
        var i = index + 2;
        while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
        return if (i < bytes.len) i + 1 else bytes.len;
    }
    if (bytes[index + 1] == ']') {
        var i = index + 2;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == 0x07) return i + 1;
            if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') return i + 2;
        }
        return bytes.len;
    }
    return index + 2;
}

fn appendCompletionMenuLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), candidates: []const completion.Candidate, selected: usize, window_start: usize, width: u16, height: u16) !void {
    if (candidates.len == 0) return;
    const max_rows = @max(@as(usize, @intCast(height)) -| 2, 1);
    const window = completionMenuWindow(candidates.len, selected, window_start, max_rows);
    const label_width = @min(@max(@as(usize, @intCast(width)) / 3, 12), 28);
    const kind_width = @as(usize, 10);
    const fixed_width = 2 + label_width + 1 + kind_width + 2;
    const description_width = @as(usize, @intCast(width)) -| fixed_width;
    for (candidates[window.start..window.end], window.start..) |candidate, index| {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        const label = candidate.display orelse candidate.value;
        if (index == selected) try line.appendSlice(allocator, "\x1b[1;38;5;81m❯\x1b[22;39m ") else try line.appendSlice(allocator, "  ");
        if (index == selected) try line.appendSlice(allocator, "\x1b[1m");
        try appendCompletionKindStyle(allocator, &line, candidate.kind);
        try appendPaddedCell(allocator, &line, label, label_width);
        try line.appendSlice(allocator, "\x1b[22;39m");
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, "\x1b[2m");
        try appendPaddedCell(allocator, &line, @tagName(candidate.kind), kind_width);
        try line.appendSlice(allocator, "\x1b[22m");
        if (candidate.description) |description| {
            if (description.len != 0 and description_width != 0) {
                try line.append(allocator, ' ');
                try line.appendSlice(allocator, "\x1b[90m");
                try appendTruncated(allocator, &line, description, description_width);
                try line.appendSlice(allocator, "\x1b[39m");
            }
        }
        if (candidates.len > window.end - window.start) {
            try line.append(allocator, ' ');
            try line.appendSlice(allocator, if (index == selected) "\x1b[38;5;81m┃\x1b[39m" else "\x1b[90m│\x1b[39m");
        }
        try lines.append(allocator, try line.toOwnedSlice(allocator));
    }
    if (window.start != 0 or window.end != candidates.len) {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "  \x1b[2mshowing {d}-{d} of {d}\x1b[22m", .{ window.start + 1, window.end, candidates.len }));
    }
}

fn appendCompletionKindStyle(allocator: std.mem.Allocator, line: *std.ArrayList(u8), kind: completion.Kind) !void {
    const color: u8 = switch (kind) {
        .command => 39,
        .builtin => 39,
        .function => 35,
        .file => 250,
        .directory => 33,
        .variable => 45,
        .option => 81,
        .subcommand => 39,
        .plain => 39,
    };
    if (color == 39) return;
    const sequence = try std.fmt.allocPrint(allocator, "\x1b[38;5;{d}m", .{color});
    defer allocator.free(sequence);
    try line.appendSlice(allocator, sequence);
}

const CompletionMenuWindow = struct {
    start: usize,
    end: usize,
};

fn completionMenuWindow(count: usize, selected: usize, window_start: usize, max_rows: usize) CompletionMenuWindow {
    if (count <= max_rows) return .{ .start = 0, .end = count };
    if (selected == std.math.maxInt(usize)) return .{ .start = @min(window_start, count - max_rows), .end = @min(@min(window_start, count - max_rows) + max_rows, count) };
    const selected_row = @min(selected, count - 1);
    var start = @min(window_start, count - max_rows);
    if (selected_row < start) {
        start = selected_row;
    } else if (selected_row >= start + max_rows) {
        start = selected_row + 1 - max_rows;
    }
    if (start + max_rows > count) start = count - max_rows;
    return .{ .start = start, .end = start + max_rows };
}

fn appendPaddedCell(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    const before = output.items.len;
    try appendTruncated(allocator, output, text, width);
    const written = output.items.len - before;
    if (written < width) try output.appendNTimes(allocator, ' ', width - written);
}

fn appendTruncated(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    if (width == 0) return;
    if (text.len <= width) {
        try output.appendSlice(allocator, text);
        return;
    }
    if (width == 1) {
        try output.appendSlice(allocator, "…");
        return;
    }
    try output.appendSlice(allocator, text[0 .. width - 1]);
    try output.appendSlice(allocator, "…");
}

pub fn visibleWidth(bytes: []const u8, method: vaxis.gwidth.Method) u16 {
    var width: u16 = 0;
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] != 0x1b) {
            i += 1;
            continue;
        }
        width += vaxis.gwidth.gwidth(bytes[plain_start..i], method);
        if (i + 1 >= bytes.len) return width;
        if (bytes[i + 1] == '[') {
            i += 2;
            while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
            if (i < bytes.len) i += 1;
        } else if (bytes[i + 1] == ']') {
            i += 2;
            while (i < bytes.len) : (i += 1) {
                if (bytes[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                    i += 2;
                    break;
                }
            }
        } else {
            i += 2;
        }
        plain_start = i;
    }
    width += vaxis.gwidth.gwidth(bytes[plain_start..], method);
    return width;
}

pub fn keyEventFromVaxis(key: vaxis.Key) KeyEvent {
    const modifiers: Modifiers = @bitCast(key.mods);
    return .{
        .key = keyFromVaxis(key.codepoint, modifiers),
        .modifiers = modifiers,
        .text = key.text orelse "",
    };
}

fn keyFromVaxis(codepoint: u21, modifiers: Modifiers) Key {
    if (modifiers.alt or modifiers.meta) {
        switch (codepoint) {
            'b' => return .word_left,
            'f' => return .word_right,
            'd' => return .delete_next_word,
            vaxis.Key.backspace => return .delete_previous_word,
            vaxis.Key.left => return .word_left,
            vaxis.Key.right => return .word_right,
            else => {},
        }
    }
    if (modifiers.ctrl) {
        switch (codepoint) {
            'a' => return .home,
            'b' => return .left,
            'c' => return .ctrl_c,
            'd' => return .ctrl_d,
            'e' => return .end,
            'f' => return .right,
            'h' => return .backspace,
            'i' => return .tab,
            'j' => return .enter,
            'k' => return .delete_to_end,
            'l' => return .clear_screen,
            'm' => return .enter,
            'n' => return .down,
            'p' => return .up,
            'r' => return .ctrl_r,
            't' => return .transpose_chars,
            'u' => return .delete_to_start,
            'w' => return .delete_previous_word,
            'y' => return .yank,
            vaxis.Key.left => return .word_left,
            vaxis.Key.right => return .word_right,
            else => {},
        }
    }
    if (codepoint == 0x01) return .home;
    if (codepoint == 0x02) return .left;
    if (codepoint == 0x03) return .ctrl_c;
    if (codepoint == 0x04) return .ctrl_d;
    if (codepoint == 0x05) return .end;
    if (codepoint == 0x06) return .right;
    if (codepoint == 0x08) return .backspace;
    if (codepoint == 0x09) return .tab;
    if (codepoint == 0x0a) return .enter;
    if (codepoint == 0x0b) return .delete_to_end;
    if (codepoint == 0x0c) return .clear_screen;
    if (codepoint == 0x0d) return .enter;
    if (codepoint == 0x0e) return .down;
    if (codepoint == 0x10) return .up;
    if (codepoint == 0x12) return .ctrl_r;
    if (codepoint == 0x14) return .transpose_chars;
    if (codepoint == 0x15) return .delete_to_start;
    if (codepoint == 0x17) return .delete_previous_word;
    if (codepoint == 0x19) return .yank;
    if (codepoint == 0x7f) return .backspace;
    return switch (codepoint) {
        vaxis.Key.enter => .enter,
        vaxis.Key.backspace => .backspace,
        vaxis.Key.delete => .delete,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.tab => .tab,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.escape => .escape,
        else => .text,
    };
}

fn previousGraphemeStart(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte == 0) return 0;
    var iter = vaxis.unicode.graphemeIterator(bytes[0..cursor_byte]);
    var start: usize = 0;
    while (iter.next()) |grapheme| start = grapheme.start;
    return start;
}

fn nextGraphemeEnd(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte >= bytes.len) return bytes.len;
    var iter = vaxis.unicode.graphemeIterator(bytes[cursor_byte..]);
    const grapheme = iter.next() orelse return cursor_byte;
    return cursor_byte + grapheme.len;
}

fn previousWordStart(bytes: []const u8, cursor_byte: usize) usize {
    var i = cursor_byte;
    while (i != 0) {
        const previous = previousCodepointStart(bytes, i);
        if (!isAsciiWhitespace(bytes[previous])) break;
        i = previous;
    }
    while (i != 0) {
        const previous = previousCodepointStart(bytes, i);
        if (isAsciiWhitespace(bytes[previous])) break;
        i = previous;
    }
    return i;
}

fn nextWordEnd(bytes: []const u8, cursor_byte: usize) usize {
    var i = cursor_byte;
    while (i < bytes.len) {
        if (!isAsciiWhitespace(bytes[i])) break;
        i = nextCodepointEnd(bytes, i);
    }
    while (i < bytes.len) {
        if (isAsciiWhitespace(bytes[i])) break;
        i = nextCodepointEnd(bytes, i);
    }
    return i;
}

fn previousCodepointStart(bytes: []const u8, cursor_byte: usize) usize {
    var i = cursor_byte - 1;
    while (i != 0 and (bytes[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

fn nextCodepointEnd(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte >= bytes.len) return bytes.len;
    const len = std.unicode.utf8ByteSequenceLength(bytes[cursor_byte]) catch return bytes.len;
    return cursor_byte + len;
}

fn isAsciiWhitespace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

test "key mapping supports readline control keys" {
    const ctrl: Modifiers = .{ .ctrl = true };

    try std.testing.expectEqual(Key.home, keyFromVaxis('a', ctrl));
    try std.testing.expectEqual(Key.left, keyFromVaxis('b', ctrl));
    try std.testing.expectEqual(Key.end, keyFromVaxis('e', ctrl));
    try std.testing.expectEqual(Key.right, keyFromVaxis('f', ctrl));
    try std.testing.expectEqual(Key.backspace, keyFromVaxis('h', ctrl));
    try std.testing.expectEqual(Key.delete_to_end, keyFromVaxis('k', ctrl));
    try std.testing.expectEqual(Key.clear_screen, keyFromVaxis('l', ctrl));
    try std.testing.expectEqual(Key.down, keyFromVaxis('n', ctrl));
    try std.testing.expectEqual(Key.up, keyFromVaxis('p', ctrl));
    try std.testing.expectEqual(Key.transpose_chars, keyFromVaxis('t', ctrl));
    try std.testing.expectEqual(Key.delete_to_start, keyFromVaxis('u', ctrl));
    try std.testing.expectEqual(Key.delete_previous_word, keyFromVaxis('w', ctrl));
    try std.testing.expectEqual(Key.yank, keyFromVaxis('y', ctrl));
    try std.testing.expectEqual(Key.word_left, keyFromVaxis(vaxis.Key.left, ctrl));
    try std.testing.expectEqual(Key.word_right, keyFromVaxis(vaxis.Key.right, ctrl));
}

test "key mapping supports readline meta word keys" {
    const alt: Modifiers = .{ .alt = true };

    try std.testing.expectEqual(Key.word_left, keyFromVaxis('b', alt));
    try std.testing.expectEqual(Key.word_right, keyFromVaxis('f', alt));
    try std.testing.expectEqual(Key.delete_next_word, keyFromVaxis('d', alt));
    try std.testing.expectEqual(Key.delete_previous_word, keyFromVaxis(vaxis.Key.backspace, alt));
    try std.testing.expectEqual(Key.word_left, keyFromVaxis(vaxis.Key.left, alt));
    try std.testing.expectEqual(Key.word_right, keyFromVaxis(vaxis.Key.right, alt));
}

test "key mapping supports legacy control bytes" {
    try std.testing.expectEqual(Key.home, keyFromVaxis(0x01, .{}));
    try std.testing.expectEqual(Key.tab, keyFromVaxis(0x09, .{}));
    try std.testing.expectEqual(Key.enter, keyFromVaxis(0x0d, .{}));
    try std.testing.expectEqual(Key.backspace, keyFromVaxis(0x7f, .{}));
    try std.testing.expectEqual(Key.clear_screen, keyFromVaxis(0x0c, .{}));
    try std.testing.expectEqual(Key.transpose_chars, keyFromVaxis(0x14, .{}));
    try std.testing.expectEqual(Key.delete_previous_word, keyFromVaxis(0x17, .{}));
    try std.testing.expectEqual(Key.yank, keyFromVaxis(0x19, .{}));
}

test "edit buffer inserts and deletes utf8 graphemes" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.handleKey(.{ .key = .text, .text = "aéb" });
    try std.testing.expectEqualStrings("aéb", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 4), editor.buffer.cursor_byte);

    editor.buffer.moveLeft();
    try std.testing.expectEqual(@as(usize, 3), editor.buffer.cursor_byte);
    editor.buffer.deletePrevious();
    try std.testing.expectEqualStrings("ab", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 1), editor.buffer.cursor_byte);
}

test "edit buffer moves and deletes by grapheme cluster" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.handleKey(.{ .key = .text, .text = "a👩‍🚀éb" });
    try std.testing.expectEqual(@as(usize, "a👩‍🚀éb".len), editor.buffer.cursor_byte);

    editor.buffer.moveLeft();
    try std.testing.expectEqual(@as(usize, "a👩‍🚀é".len), editor.buffer.cursor_byte);
    editor.buffer.moveLeft();
    try std.testing.expectEqual(@as(usize, "a👩‍🚀".len), editor.buffer.cursor_byte);
    editor.buffer.deletePrevious();
    try std.testing.expectEqualStrings("aéb", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 1), editor.buffer.cursor_byte);

    editor.buffer.deleteNext();
    try std.testing.expectEqualStrings("ab", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, 1), editor.buffer.cursor_byte);
}

test "edit buffer reports cursor display width with vaxis" {
    var buffer = EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insertText("a界");
    try std.testing.expectEqual(@as(u16, 3), buffer.cursorDisplayWidth(.unicode));
}

test "edit buffer moves and deletes by shell words" {
    var buffer = EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insertText("git checkout main");
    buffer.moveWordLeft();
    try std.testing.expectEqual(@as(usize, "git checkout ".len), buffer.cursor_byte);
    buffer.moveWordLeft();
    try std.testing.expectEqual(@as(usize, "git ".len), buffer.cursor_byte);
    buffer.moveWordRight();
    try std.testing.expectEqual(@as(usize, "git checkout".len), buffer.cursor_byte);
    buffer.deletePreviousWord();
    try std.testing.expectEqualStrings("git  main", buffer.text());
    try std.testing.expectEqual(@as(usize, "git ".len), buffer.cursor_byte);
    buffer.deleteNextWord();
    try std.testing.expectEqualStrings("git ", buffer.text());
}

test "edit buffer kills to start and end" {
    var buffer = EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insertText("abcdef");
    buffer.moveLeft();
    buffer.moveLeft();
    buffer.deleteToStart();
    try std.testing.expectEqualStrings("ef", buffer.text());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor_byte);
    try buffer.insertText("cd");
    buffer.deleteToEnd();
    try std.testing.expectEqualStrings("cd", buffer.text());
}

test "edit buffer transposes adjacent graphemes" {
    var buffer = EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insertText("ab👩‍🚀d");
    buffer.moveLeft();
    buffer.transposeChars();
    try std.testing.expectEqualStrings("a👩‍🚀bd", buffer.text());
    try std.testing.expectEqual(@as(usize, "a👩‍🚀b".len), buffer.cursor_byte);
}

test "line session yanks last killed text" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git checkout main" });
    try session.handleKey(.{ .key = .word_left });
    try session.handleKey(.{ .key = .delete_to_end });
    try std.testing.expectEqualStrings("git checkout ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
}

test "line session yanks killed previous and next words" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git checkout main" });
    try session.handleKey(.{ .key = .word_left });
    try session.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .home });
    try session.handleKey(.{ .key = .delete_next_word });
    try std.testing.expectEqualStrings(" checkout main", session.editor.buffer.text());
    try session.handleKey(.{ .key = .yank });
    try std.testing.expectEqualStrings("git checkout main", session.editor.buffer.text());
}

test "line session records clear screen requests" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();

    try session.handleKey(.{ .key = .clear_screen });
    try std.testing.expect(session.takeClearScreenRequest());
    try std.testing.expect(!session.takeClearScreenRequest());
}

test "editor handles readline movement and deletion keys" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.handleKey(.{ .key = .text, .text = "git checkout main" });
    try editor.handleKey(.{ .key = .word_left });
    try std.testing.expectEqual(@as(usize, "git checkout ".len), editor.buffer.cursor_byte);
    try editor.handleKey(.{ .key = .delete_to_end });
    try std.testing.expectEqualStrings("git checkout ", editor.buffer.text());
    try editor.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git ", editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "git ".len), editor.buffer.cursor_byte);
}

test "line session applies completion edit" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.editor.buffer.replace("git st");

    const application: completion.Application = .{ .edit = .{
        .replace_start = 4,
        .replace_end = 6,
        .replacement = "status",
        .append_space = true,
    } };
    try session.applyCompletion(application);

    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
    try std.testing.expectEqual(@as(usize, "git status ".len), session.editor.buffer.cursor_byte);
}

test "line session leaves ambiguous and empty completions unchanged" {
    var session = try LineSession.init(std.testing.allocator, "");
    defer session.deinit();
    try session.editor.buffer.replace("git ");

    try session.applyCompletion(.{ .ambiguous = &.{} });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.applyCompletion(.none);
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
}

test "line session renders ambiguous completion menu" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .description = "switch branches", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .display = "cherry", .description = "apply commits", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "checkout") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cherry") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "subcommand") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "switch branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "apply commits") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1;38;5;81m❯") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2msubcommand") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[90mswitch branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "git che\x1b[J") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2A") != null);
}

test "completion menu styles candidates by kind" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "--help", .description = "show help", .kind = .option, .replace_start = 0, .replace_end = 0 },
        .{ .value = "$HOME", .description = "home directory", .kind = .variable, .replace_start = 0, .replace_end = 0 },
        .{ .value = "src", .description = "source directory", .kind = .directory, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;81m--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;45m$HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;33msrc") != null);
}

test "completion menu selection accepts selected candidate" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqualStrings("git cherry-pick ", session.editor.buffer.text());
    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
}

test "accepting completion clears previously rendered menu rows" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git che");
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 4, .replace_end = 7 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const menu_frame = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_frame);
    try std.testing.expect(std.mem.indexOf(u8, menu_frame, "checkout") != null);

    try session.handleKey(.{ .key = .tab });
    try session.handleKey(.{ .key = .enter });
    const accepted_frame = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(accepted_frame);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "git checkout \x1b[J") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_frame, "\x1b[2A") == null);
}

test "completion menu selection wraps with arrow keys" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
}

test "completion menu cycles selection with tab and shift tab" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "switch", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try std.testing.expect(session.hasCompletionMenu());
    try std.testing.expect(session.completion_menu.selectedCandidate() == null);

    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('n', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.selected);
    try session.handleKey(.{ .key = keyFromVaxis('p', .{ .ctrl = true }) });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.selected);

    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try session.handleKey(.{ .key = .enter });
    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
}

test "completion menu remains open across text edits and modifier-only events" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git s");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 5 },
        .{ .value = "switch", .kind = .subcommand, .replace_start = 4, .replace_end = 5 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .text, .text = "t" });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try std.testing.expect(session.hasCompletionMenu());
    try session.handleKey(.{ .key = .text, .text = "" });
    try std.testing.expectEqualStrings("git st", session.editor.buffer.text());
    try std.testing.expect(session.hasCompletionMenu());

    try session.handleKey(.{ .key = .escape });
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion menu closes on deletion edits" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .backspace });
    try std.testing.expectEqualStrings("git s", session.editor.buffer.text());
    try std.testing.expect(!session.hasCompletionMenu());

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .delete_previous_word });
    try std.testing.expectEqualStrings("git ", session.editor.buffer.text());
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion menu closes on cursor movement" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{
        .{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
        .{ .value = "stash", .kind = .subcommand, .replace_start = 4, .replace_end = 6 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    try session.handleKey(.{ .key = .left });
    try std.testing.expectEqual(@as(usize, "git s".len), session.editor.buffer.cursor_byte);
    try std.testing.expect(!session.hasCompletionMenu());

    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .home });
    try std.testing.expectEqual(@as(usize, 0), session.editor.buffer.cursor_byte);
    try std.testing.expect(!session.hasCompletionMenu());
}

test "completion edit clears rendered menu" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git st");
    var candidates = [_]completion.Candidate{.{ .value = "status", .kind = .subcommand, .replace_start = 4, .replace_end = 6 }};
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try std.testing.expectEqual(@as(usize, 1), session.completion_menu.candidates.len);

    try session.applyCompletion(.{ .edit = .{ .replace_start = 4, .replace_end = 6, .replacement = "status", .append_space = true } });
    try std.testing.expectEqual(@as(usize, 0), session.completion_menu.candidates.len);
    try std.testing.expectEqualStrings("git status ", session.editor.buffer.text());
}

test "completion menu respects render height" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "two") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 1-1 of 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2A") != null);
}

test "completion menu visible window follows selection" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try session.editor.buffer.replace("git ");
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 4, .replace_end = 4 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[1;38;5;81m❯\x1b[22;39m \x1b[1mthree") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 3-3 of 3") != null);
}

test "completion menu only pins selection to bottom while scrolling down" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "one", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "two", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "three", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "four", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });
    try session.handleKey(.{ .key = .down });

    const scrolled_down = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 4 });
    defer std.testing.allocator.free(scrolled_down);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "\x1b[1;38;5;81m❯\x1b[22;39m \x1b[1mthree") != null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_down, "showing 2-3 of 4") != null);

    try session.handleKey(.{ .key = .up });
    const moved_up = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 4 });
    defer std.testing.allocator.free(moved_up);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "\x1b[1;38;5;81m❯\x1b[22;39m \x1b[1mtwo") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved_up, "showing 2-3 of 4") != null);
}

test "completion menu truncates long columns to terminal width" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{.{
        .value = "extraordinarily-long-subcommand-name",
        .description = "this description is intentionally too long for the menu",
        .kind = .subcommand,
        .replace_start = 0,
        .replace_end = 0,
    }};
    try session.applyCompletion(.{ .ambiguous = &candidates });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .width = 32 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "extraordina…") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "intentionally") == null);
}

test "line session submits an owned copy on enter" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "echo hi" });
    try session.handleKey(.{ .key = .enter });

    try std.testing.expectEqual(LineSession.State.submitted, session.state);
    const line = session.takeSubmittedLine().?;
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("echo hi", line);
}

test "line session cancels on escape" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .escape });
    try session.handleKey(.{ .key = .text, .text = "d" });

    try std.testing.expectEqual(LineSession.State.canceled, session.state);
    try std.testing.expectEqualStrings("abc", session.editor.buffer.text());
}

test "line session cancels on ctrl-c" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "abc" });
    try session.handleKey(.{ .key = .ctrl_c });

    try std.testing.expectEqual(LineSession.State.canceled, session.state);
    try std.testing.expect(session.takeSubmittedLine() == null);
}

test "line session treats ctrl-d as eof only on empty buffer" {
    var empty = try LineSession.init(std.testing.allocator, "$ ");
    defer empty.deinit();
    try empty.handleKey(.{ .key = .ctrl_d });
    try std.testing.expectEqual(LineSession.State.eof, empty.state);

    var non_empty = try LineSession.init(std.testing.allocator, "$ ");
    defer non_empty.deinit();
    try non_empty.handleKey(.{ .key = .text, .text = "ab" });
    non_empty.editor.buffer.moveLeft();
    try non_empty.handleKey(.{ .key = .ctrl_d });
    try std.testing.expectEqual(LineSession.State.editing, non_empty.state);
    try std.testing.expectEqualStrings("a", non_empty.editor.buffer.text());
}

test "line session renders with its prompt" {
    var session = try LineSession.init(std.testing.allocator, "rush> ");
    defer session.deinit();
    try session.handleKey(.{ .key = .text, .text = "x" });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2Krush> x\x1b[J\r\x1b[7C", rendered);
}

test "render line styles diagnostic spans without moving cursor" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("git comit");

    const spans = [_]DiagnosticSpan{.{ .start = 4, .end = 9, .severity = .err }};
    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &spans,
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K$ git \x1b[4:3;58;5;1mcomit\x1b[24;59m\x1b[J\r\x1b[11C", rendered);
}

test "render line wraps styled diagnostic spans" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.buffer.replace("git commit --amend");

    const spans = [_]DiagnosticSpan{.{ .start = 11, .end = 18, .severity = .warning }};
    const rendered = try renderLine(std.testing.allocator, editor, .{
        .prompt = .{ .bytes = "$ " },
        .diagnostic_spans = &spans,
        .width = 12,
        .synchronized_output = false,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[4:3;58;5;1m--amend\x1b[24;59m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "\r\x1b[8C"));
}

test "line session navigates full history from empty buffer" {
    const entries = [_][]const u8{ "echo one", "echo two" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("echo one", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("echo two", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("", session.editor.buffer.text());
}

test "line session searches history by draft prefix" {
    const entries = [_][]const u8{ "echo one", "git status", "echo two", "git diff" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .down });
    try std.testing.expectEqualStrings("git", session.editor.buffer.text());
}

test "line session hides older duplicate history commands" {
    const entries = [_][]const u8{ "git status", "echo hi", "git status", "git diff" };
    var session = try LineSession.initWithOptions(std.testing.allocator, .{ .bytes = "$ " }, .{ .entries = &entries });
    defer session.deinit();

    try session.handleKey(.{ .key = .text, .text = "git" });
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git diff", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
    try session.handleKey(.{ .key = .up });
    try std.testing.expectEqualStrings("git status", session.editor.buffer.text());
}

test "line session inserts enter literally during paste" {
    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    session.beginPaste();
    try session.handleKey(.{ .key = .text, .text = "echo" });
    try session.handleKey(.{ .key = .enter });
    try session.handleKey(.{ .key = .text, .text = "hi" });
    session.endPaste();

    try std.testing.expectEqual(LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("echo\nhi", session.editor.buffer.text());
}

test "render line redraws prompt and buffer inside synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abc" });
    editor.buffer.moveLeft();

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " } });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\x1b[?2026h\r\x1b[2K$ abc\x1b[J\r\x1b[4C\x1b[?2026l", rendered);
}

test "render line can omit synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "界" });

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "> " }, .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K> 界\x1b[J\r\x1b[4C", rendered);
}

test "render line ignores ansi prompt bytes for cursor placement" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "x" });

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "\x1b[34mrush> \x1b[0m" }, .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K\x1b[34mrush> \x1b[0mx\x1b[J\r\x1b[7C", rendered);
}

test "frame wraps long input at terminal width" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abcdef" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ abc", frame.lines[0]);
    try std.testing.expectEqualStrings("def", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), frame.cursor_col);
}

test "frame wrapping keeps cursor on trailing empty row at exact width" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abc" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ abc", frame.lines[0]);
    try std.testing.expectEqualStrings("", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), frame.cursor_col);
}

test "frame wrapping preserves prompt escape sequences" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abcd" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "\x1b[34m$ \x1b[0m", .visible_width = 2 }, .width = 4 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("\x1b[34m$ \x1b[0mab", frame.lines[0]);
    try std.testing.expectEqualStrings("cd", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor_col);
}

test "frame wrapping computes cursor with wide graphemes" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "ab界" });

    var frame = try frameFromLine(std.testing.allocator, editor, .{ .prompt = .{ .bytes = "$ " }, .width = 5 });
    defer frame.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), frame.lines.len);
    try std.testing.expectEqualStrings("$ ab", frame.lines[0]);
    try std.testing.expectEqualStrings("界", frame.lines[1]);
    try std.testing.expectEqual(@as(usize, 1), frame.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), frame.cursor_col);
}

test "frame renderer diffs changed input line" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var first_editor = Editor.init(std.testing.allocator);
    defer first_editor.deinit();
    try first_editor.handleKey(.{ .key = .text, .text = "a" });
    var first = try frameFromLine(std.testing.allocator, first_editor, .{ .prompt = .{ .bytes = "$ " }, .synchronized_output = false });
    defer first.deinit(std.testing.allocator);
    const first_output = try renderer.render(std.testing.allocator, first, .{ .synchronized_output = false });
    defer std.testing.allocator.free(first_output);
    try std.testing.expect(std.mem.indexOf(u8, first_output, "\x1b[J") != null);

    var second_editor = Editor.init(std.testing.allocator);
    defer second_editor.deinit();
    try second_editor.handleKey(.{ .key = .text, .text = "ab" });
    var second = try frameFromLine(std.testing.allocator, second_editor, .{ .prompt = .{ .bytes = "$ " }, .synchronized_output = false });
    defer second.deinit(std.testing.allocator);
    const second_output = try renderer.render(std.testing.allocator, second, .{ .synchronized_output = false });
    defer std.testing.allocator.free(second_output);

    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\x1b[2K$ ab") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\r\x1b[0C") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\r\x1b[4C") != null);
}

test "frame renderer redraws when frame adds lines" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    var input_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer input_frame.deinit(std.testing.allocator);
    const input_output = try renderer.render(std.testing.allocator, input_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(input_output);

    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try std.testing.expect(std.mem.indexOf(u8, menu_output, "\x1b[J") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu_output, "checkout") != null);
}

test "frame renderer diffs when frame removes lines" {
    var renderer: FrameRenderer = .{};
    defer renderer.deinit(std.testing.allocator);

    var session = try LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    var candidates = [_]completion.Candidate{
        .{ .value = "checkout", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
        .{ .value = "cherry-pick", .kind = .subcommand, .replace_start = 0, .replace_end = 0 },
    };
    try session.applyCompletion(.{ .ambiguous = &candidates });
    var menu_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer menu_frame.deinit(std.testing.allocator);
    const menu_output = try renderer.render(std.testing.allocator, menu_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(menu_output);

    try session.handleKey(.{ .key = .tab });
    try session.handleKey(.{ .key = .enter });
    var accepted_frame = try session.renderFrame(std.testing.allocator, .{ .synchronized_output = false });
    defer accepted_frame.deinit(std.testing.allocator);
    const accepted_output = try renderer.render(std.testing.allocator, accepted_frame, .{ .synchronized_output = false });
    defer std.testing.allocator.free(accepted_output);

    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[J") == null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[2K$ checkout ") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_output, "\x1b[1B\r\x1b[2K") != null);
}
