//! Terminal-independent line editor core.

const Self = @This();

const std = @import("std");
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
    home,
    end,
    escape,
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

    pub fn insertText(self: *EditBuffer, text_bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text_bytes)) return error.InvalidUtf8;
        try self.bytes.insertSlice(self.allocator, self.cursor_byte, text_bytes);
        self.cursor_byte += text_bytes.len;
    }

    pub fn moveLeft(self: *EditBuffer) void {
        self.cursor_byte = previousScalarStart(self.bytes.items, self.cursor_byte);
    }

    pub fn moveRight(self: *EditBuffer) void {
        self.cursor_byte = nextScalarEnd(self.bytes.items, self.cursor_byte);
    }

    pub fn deletePrevious(self: *EditBuffer) void {
        const start = previousScalarStart(self.bytes.items, self.cursor_byte);
        if (start == self.cursor_byte) return;
        self.bytes.replaceRange(self.allocator, start, self.cursor_byte - start, "") catch unreachable;
        self.cursor_byte = start;
    }

    pub fn deleteNext(self: *EditBuffer) void {
        const end = nextScalarEnd(self.bytes.items, self.cursor_byte);
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
            .backspace => self.buffer.deletePrevious(),
            .delete => self.buffer.deleteNext(),
            .enter, .up, .down, .home, .end, .escape => {},
        }
    }
};

pub const LineSession = struct {
    allocator: std.mem.Allocator,
    prompt: []const u8,
    editor: Editor,
    state: State = .editing,
    submitted_line: ?[]const u8 = null,

    pub const State = enum {
        editing,
        submitted,
        canceled,
    };

    pub fn init(allocator: std.mem.Allocator, prompt: []const u8) !LineSession {
        return .{
            .allocator = allocator,
            .prompt = try allocator.dupe(u8, prompt),
            .editor = .init(allocator),
        };
    }

    pub fn deinit(self: *LineSession) void {
        if (self.submitted_line) |line| self.allocator.free(line);
        self.editor.deinit();
        self.allocator.free(self.prompt);
        self.* = undefined;
    }

    pub fn handleKey(self: *LineSession, event: KeyEvent) !void {
        if (self.state != .editing) return;
        switch (event.key) {
            .enter => {
                std.debug.assert(self.submitted_line == null);
                self.submitted_line = try self.allocator.dupe(u8, self.editor.buffer.text());
                self.state = .submitted;
            },
            .escape => self.state = .canceled,
            else => try self.editor.handleKey(event),
        }
    }

    pub fn render(self: LineSession, allocator: std.mem.Allocator, options: RenderOptions) ![]const u8 {
        var render_options = options;
        render_options.prompt = self.prompt;
        return renderLine(allocator, self.editor, render_options);
    }

    pub fn takeSubmittedLine(self: *LineSession) ?[]const u8 {
        const line = self.submitted_line orelse return null;
        self.submitted_line = null;
        return line;
    }
};

pub const RenderOptions = struct {
    prompt: []const u8 = "",
    width_method: vaxis.gwidth.Method = .unicode,
    synchronized_output: bool = true,
};

pub fn renderLine(allocator: std.mem.Allocator, editor: Editor, options: RenderOptions) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    if (options.synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");
    try output.appendSlice(allocator, "\r\x1b[2K");
    try output.appendSlice(allocator, options.prompt);
    try output.appendSlice(allocator, editor.buffer.text());

    const prompt_width = vaxis.gwidth.gwidth(options.prompt, options.width_method);
    const cursor_width = prompt_width + editor.buffer.cursorDisplayWidth(options.width_method);
    const cursor_sequence = try std.fmt.allocPrint(allocator, "\r\x1b[{d}C", .{cursor_width});
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (options.synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");

    return output.toOwnedSlice(allocator);
}

pub fn keyEventFromVaxis(key: vaxis.Key) KeyEvent {
    return .{
        .key = keyFromVaxisCodepoint(key.codepoint),
        .modifiers = @bitCast(key.mods),
        .text = key.text orelse "",
    };
}

fn keyFromVaxisCodepoint(codepoint: u21) Key {
    return switch (codepoint) {
        vaxis.Key.enter => .enter,
        vaxis.Key.backspace => .backspace,
        vaxis.Key.delete => .delete,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.escape => .escape,
        else => .text,
    };
}

fn previousScalarStart(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte == 0) return 0;
    var index = cursor_byte - 1;
    while (index > 0 and (bytes[index] & 0b1100_0000) == 0b1000_0000) index -= 1;
    return index;
}

fn nextScalarEnd(bytes: []const u8, cursor_byte: usize) usize {
    if (cursor_byte >= bytes.len) return bytes.len;
    var index = cursor_byte + 1;
    while (index < bytes.len and (bytes[index] & 0b1100_0000) == 0b1000_0000) index += 1;
    return index;
}

test "edit buffer inserts and deletes utf8 scalars" {
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

test "edit buffer reports cursor display width with vaxis" {
    var buffer = EditBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.insertText("a界");
    try std.testing.expectEqual(@as(u16, 3), buffer.cursorDisplayWidth(.unicode));
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

test "line session renders with its prompt" {
    var session = try LineSession.init(std.testing.allocator, "rush> ");
    defer session.deinit();
    try session.handleKey(.{ .key = .text, .text = "x" });

    const rendered = try session.render(std.testing.allocator, .{ .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2Krush> x\r\x1b[7C", rendered);
}

test "render line redraws prompt and buffer inside synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "abc" });
    editor.buffer.moveLeft();

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = "$ " });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\x1b[?2026h\r\x1b[2K$ abc\r\x1b[4C\x1b[?2026l", rendered);
}

test "render line can omit synchronized output" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.handleKey(.{ .key = .text, .text = "界" });

    const rendered = try renderLine(std.testing.allocator, editor, .{ .prompt = "> ", .synchronized_output = false });
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\r\x1b[2K> 界\r\x1b[4C", rendered);
}
