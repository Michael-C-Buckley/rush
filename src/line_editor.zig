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
            .backspace => self.buffer.deletePrevious(),
            .delete => self.buffer.deleteNext(),
            .enter, .up, .down, .tab, .escape, .ctrl_c, .ctrl_d => {},
        }
    }
};

pub const Prompt = struct {
    bytes: []const u8,
    visible_width: ?u16 = null,
};

pub const HistoryView = struct {
    entries: []const []const u8 = &.{},
};

pub const CompletionMenu = struct {
    candidates: []completion.Candidate = &.{},
    selected: usize = 0,

    pub fn deinit(self: *CompletionMenu, allocator: std.mem.Allocator) void {
        if (self.candidates.len != 0) completion.freeCandidates(allocator, self.candidates);
        self.* = .{};
    }

    pub fn replace(self: *CompletionMenu, allocator: std.mem.Allocator, candidates: []const completion.Candidate) !void {
        self.deinit(allocator);
        self.candidates = try completion.cloneCandidates(allocator, candidates);
        self.selected = 0;
    }

    pub fn clear(self: *CompletionMenu, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }

    pub fn isOpen(self: CompletionMenu) bool {
        return self.candidates.len != 0;
    }

    pub fn selectPrevious(self: *CompletionMenu) void {
        if (self.candidates.len == 0) return;
        self.selected = if (self.selected == 0) self.candidates.len - 1 else self.selected - 1;
    }

    pub fn selectNext(self: *CompletionMenu) void {
        if (self.candidates.len == 0) return;
        self.selected = (self.selected + 1) % self.candidates.len;
    }

    pub fn selectedCandidate(self: CompletionMenu) ?completion.Candidate {
        if (self.candidates.len == 0) return null;
        return self.candidates[self.selected];
    }
};

pub const LineSession = struct {
    allocator: std.mem.Allocator,
    prompt: Prompt,
    editor: Editor,
    history: HistoryView = .{},
    history_index: ?usize = null,
    saved_edit: std.ArrayList(u8) = .empty,
    completion_menu: CompletionMenu = .{},
    state: State = .editing,
    submitted_line: ?[]const u8 = null,
    paste_depth: usize = 0,

    pub const State = enum {
        editing,
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
        self.completion_menu.deinit(self.allocator);
        self.saved_edit.deinit(self.allocator);
        self.editor.deinit();
        self.allocator.free(self.prompt.bytes);
        self.* = undefined;
    }

    pub fn handleKey(self: *LineSession, event: KeyEvent) !void {
        if (self.state != .editing) return;
        if (self.paste_depth != 0) {
            if (event.key == .text or event.key == .enter) {
                const text = if (event.key == .enter) "\n" else event.text;
                try self.editor.handleKey(.{ .key = .text, .text = text });
                self.completion_menu.clear(self.allocator);
            }
            return;
        }
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
            .up => if (self.completion_menu.isOpen()) self.completion_menu.selectPrevious() else try self.historyPrevious(),
            .down => if (self.completion_menu.isOpen()) self.completion_menu.selectNext() else try self.historyNext(),
            .tab => if (self.completion_menu.selectedCandidate()) |candidate| try self.applyCompletionCandidate(candidate),
            else => {
                try self.editor.handleKey(event);
                self.completion_menu.clear(self.allocator);
            },
        }
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

    pub fn render(self: *LineSession, allocator: std.mem.Allocator, options: RenderOptions) ![]const u8 {
        var render_options = options;
        render_options.prompt = self.prompt;
        render_options.completion_menu = self.completion_menu.candidates;
        render_options.completion_selection = self.completion_menu.selected;
        return renderLine(allocator, self.editor, render_options);
    }

    pub fn takeSubmittedLine(self: *LineSession) ?[]const u8 {
        const line = self.submitted_line orelse return null;
        self.submitted_line = null;
        return line;
    }

    fn historyPrevious(self: *LineSession) !void {
        if (self.history.entries.len == 0) return;
        const prefix = try self.historyPrefix();
        const start = self.history_index orelse self.history.entries.len;
        const index = self.findPreviousHistoryMatch(start, prefix) orelse return;
        self.history_index = index;
        try self.editor.buffer.replace(self.history.entries[index]);
        self.completion_menu.clear(self.allocator);
    }

    fn historyNext(self: *LineSession) !void {
        const index = self.history_index orelse return;
        const prefix = self.saved_edit.items;
        const next_index = self.findNextHistoryMatch(index + 1, prefix) orelse {
            self.history_index = null;
            try self.editor.buffer.replace(self.saved_edit.items);
            self.saved_edit.clearRetainingCapacity();
            self.completion_menu.clear(self.allocator);
            return;
        };
        self.history_index = next_index;
        try self.editor.buffer.replace(self.history.entries[next_index]);
        self.completion_menu.clear(self.allocator);
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
};

pub const RenderOptions = struct {
    prompt: Prompt = .{ .bytes = "" },
    completion_menu: []const completion.Candidate = &.{},
    completion_selection: usize = 0,
    width: u16 = 80,
    height: u16 = 24,
    width_method: vaxis.gwidth.Method = .unicode,
    synchronized_output: bool = true,
};

pub fn renderLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    if (options.synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");
    try output.appendSlice(allocator, "\r\x1b[2K");
    try output.appendSlice(allocator, options.prompt.bytes);
    try output.appendSlice(allocator, editor.buffer.text());
    try output.appendSlice(allocator, "\x1b[J");

    const menu_rows = try appendCompletionMenu(allocator, &output, options.completion_menu, options.completion_selection, options.width, options.height);

    const prompt_width = options.prompt.visible_width orelse visibleWidth(options.prompt.bytes, options.width_method);
    const cursor_width = prompt_width + editor.buffer.cursorDisplayWidth(options.width_method);
    const cursor_sequence = if (menu_rows == 0)
        try std.fmt.allocPrint(allocator, "\r\x1b[{d}C", .{cursor_width})
    else
        try std.fmt.allocPrint(allocator, "\x1b[{d}A\r\x1b[{d}C", .{ menu_rows, cursor_width });
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (options.synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");

    return output.toOwnedSlice(allocator);
}

fn appendCompletionMenu(allocator: std.mem.Allocator, output: *std.ArrayList(u8), candidates: []const completion.Candidate, selected: usize, width: u16, height: u16) !usize {
    if (candidates.len == 0) return 0;
    var rows: usize = 0;
    const max_rows = @max(@as(usize, @intCast(height)) -| 2, 1);
    const window = completionMenuWindow(candidates.len, selected, max_rows);
    const label_width = @min(@max(@as(usize, @intCast(width)) / 3, 12), 28);
    const kind_width = @as(usize, 10);
    const fixed_width = 2 + label_width + 1 + kind_width + 1;
    const description_width = @as(usize, @intCast(width)) -| fixed_width;
    for (candidates[window.start..window.end], window.start..) |candidate, index| {
        const label = candidate.display orelse candidate.value;
        try output.appendSlice(allocator, "\r\n");
        if (index == selected) try output.appendSlice(allocator, "\x1b[7m❯ ") else try output.appendSlice(allocator, "  ");
        try appendPaddedCell(allocator, output, label, label_width);
        try output.append(allocator, ' ');
        try appendPaddedCell(allocator, output, @tagName(candidate.kind), kind_width);
        if (candidate.description) |description| {
            if (description.len != 0 and description_width != 0) {
                try output.append(allocator, ' ');
                try appendTruncated(allocator, output, description, description_width);
            }
        }
        if (index == selected) try output.appendSlice(allocator, "\x1b[27m");
        rows += 1;
    }
    if (window.start != 0 or window.end != candidates.len) {
        const more = try std.fmt.allocPrint(allocator, "\r\n  showing {d}-{d} of {d}", .{ window.start + 1, window.end, candidates.len });
        defer allocator.free(more);
        try output.appendSlice(allocator, more);
        rows += 1;
    }
    return rows;
}

const CompletionMenuWindow = struct {
    start: usize,
    end: usize,
};

fn completionMenuWindow(count: usize, selected: usize, max_rows: usize) CompletionMenuWindow {
    if (count <= max_rows) return .{ .start = 0, .end = count };
    const selected_row = @min(selected, count - 1);
    var start = if (selected_row >= max_rows) selected_row + 1 - max_rows else 0;
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
    if (modifiers.ctrl) {
        switch (codepoint) {
            'c' => return .ctrl_c,
            'd' => return .ctrl_d,
            else => {},
        }
    }
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[7m❯ checkout") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "git che\x1b[J") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[2A") != null);
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

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false, .height = 3 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[7m❯ three") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "showing 3-3 of 3") != null);
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
