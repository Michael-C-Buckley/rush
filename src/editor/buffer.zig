//! Text buffer editing core for the line editor.

const std = @import("std");
const completion = @import("completion.zig");
const key = @import("key.zig");
const vaxis = @import("vaxis");

pub const Snapshot = struct {
    text: []u8,
    cursor_byte: usize,

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
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
        self.bytes.replaceRange(
            self.allocator,
            self.cursor_byte,
            self.bytes.items.len - self.cursor_byte,
            "",
        ) catch unreachable;
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

    pub fn replaceGrapheme(self: *EditBuffer, text_bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text_bytes)) return error.InvalidUtf8;
        const end = nextGraphemeEnd(self.bytes.items, self.cursor_byte);
        if (end == self.cursor_byte) {
            try self.insertText(text_bytes);
            return;
        }
        try self.bytes.replaceRange(self.allocator, self.cursor_byte, end - self.cursor_byte, text_bytes);
        self.cursor_byte += text_bytes.len;
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

    pub fn handleKey(self: *Editor, event: key.Event) !void {
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
            .enter,
            .up,
            .down,
            .tab,
            .escape,
            .ctrl_c,
            .ctrl_d,
            .ctrl_r,
            .clear_screen,
            .argument_left,
            .argument_right,
            .delete_previous_argument,
            .delete_next_argument,
            .yank,
            .undo,
            .redo,
            => {},
        }
    }
};

pub fn previousGraphemeStart(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte == 0) return 0;
    var iter = vaxis.unicode.graphemeIterator(bytes[0..cursor_byte]);
    var start: usize = 0;
    while (iter.next()) |grapheme| start = grapheme.start;
    return start;
}

pub fn nextGraphemeEnd(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte >= bytes.len) return bytes.len;
    var iter = vaxis.unicode.graphemeIterator(bytes[cursor_byte..]);
    const grapheme = iter.next() orelse return cursor_byte;
    return cursor_byte + grapheme.len;
}

pub fn previousWordStart(bytes: []const u8, cursor_byte: usize) usize {
    var i = cursor_byte;
    while (i != 0) {
        const previous = previousCodepointStart(bytes, i);
        if (!isWordSeparator(bytes[previous])) break;
        i = previous;
    }
    while (i != 0) {
        const previous = previousCodepointStart(bytes, i);
        if (isWordSeparator(bytes[previous])) break;
        i = previous;
    }
    return i;
}

pub fn nextWordEnd(bytes: []const u8, cursor_byte: usize) usize {
    var i = cursor_byte;
    while (i < bytes.len) {
        if (!isWordSeparator(bytes[i])) break;
        i = nextCodepointEnd(bytes, i);
    }
    while (i < bytes.len) {
        if (isWordSeparator(bytes[i])) break;
        i = nextCodepointEnd(bytes, i);
    }
    return i;
}

fn previousCodepointStart(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte == 0) return 0;
    var index = cursor_byte - 1;
    while (index != 0 and (bytes[index] & 0b1100_0000) == 0b1000_0000) index -= 1;
    return index;
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

fn isWordSeparator(byte: u8) bool {
    return byte == '/' or isAsciiWhitespace(byte);
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

test "edit buffer treats path separators as word boundaries" {
    var buffer = EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insertText("cat src/editor/buffer.zig");
    buffer.deletePreviousWord();
    try std.testing.expectEqualStrings("cat src/editor/", buffer.text());
    try std.testing.expectEqual(@as(usize, "cat src/editor/".len), buffer.cursor_byte);

    buffer.deletePreviousWord();
    try std.testing.expectEqualStrings("cat src/", buffer.text());
    try std.testing.expectEqual(@as(usize, "cat src/".len), buffer.cursor_byte);

    buffer.moveWordLeft();
    try std.testing.expectEqual(@as(usize, "cat ".len), buffer.cursor_byte);
    buffer.moveWordRight();
    try std.testing.expectEqual(@as(usize, "cat src".len), buffer.cursor_byte);
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
