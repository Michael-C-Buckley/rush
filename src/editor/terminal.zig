//! Terminal capability negotiation and input parsing for the editor driver.

const std = @import("std");
const vaxis = @import("vaxis");

const line_editor = @import("session.zig");

const kitty_keyboard_set = "\x1b[={d}u";
const legacy_kitty_keyboard_flags: u5 = 0;
const editor_kitty_keyboard_flags: u5 = @bitCast(vaxis.Key.KittyFlags{});

pub const Event = union(enum) {
    key_press: line_editor.KeyEvent,
    key_release: line_editor.KeyEvent,
    paste: []const u8,
    paste_start,
    paste_end,
    invalid_utf8,
    focus_in,
    focus_out,
    resize: vaxis.Winsize,
    capability: Capability,
    color_scheme: ColorScheme,
    color_report: ColorReport,
    prompt_redraw,
};

pub const ColorScheme = enum { dark, light, unknown };

pub const ColorReport = vaxis.Color.Report;

pub const Capability = enum {
    kitty_keyboard,
    kitty_graphics,
    rgb,
    sgr_pixels,
    unicode,
    da1,
    color_scheme_updates,
    multi_cursor,
};

pub const Capabilities = struct {
    kitty_keyboard: bool = false,
    kitty_keyboard_handoff: bool = false,
    kitty_graphics: bool = false,
    rgb: bool = false,
    sgr_pixels: bool = false,
    unicode: bool = false,
    da1: bool = false,
    color_scheme_updates: bool = false,
    multi_cursor: bool = false,
    synchronized_output: bool = true,
    bracketed_paste: bool = false,
    in_band_resize_enabled: bool = false,
    in_band_resize: bool = false,

    pub fn widthMethod(self: Capabilities) vaxis.gwidth.Method {
        return if (self.unicode) .unicode else .wcwidth;
    }

    pub fn appendQuerySequences(
        self: *Capabilities,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
    ) !void {
        try output.appendSlice(
            allocator,
            vaxis.ctlseqs.decrqm_sgr_pixels ++
                vaxis.ctlseqs.decrqm_unicode ++
                vaxis.ctlseqs.decrqm_color_scheme ++
                vaxis.ctlseqs.csi_u_query ++
                vaxis.ctlseqs.kitty_graphics_query ++
                vaxis.ctlseqs.multi_cursor_query ++
                vaxis.ctlseqs.primary_device_attrs ++
                vaxis.ctlseqs.in_band_resize_set ++
                vaxis.ctlseqs.bp_set,
        );
        self.bracketed_paste = true;
        self.in_band_resize_enabled = true;
    }

    pub fn appendColorReportQueries(
        _: Capabilities,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
    ) !void {
        try output.appendSlice(allocator, vaxis.ctlseqs.osc10_query ++ vaxis.ctlseqs.osc11_query);
        for (0..8) |index| {
            var sequence_buffer: [32]u8 = undefined;
            const sequence = try std.fmt.bufPrint(&sequence_buffer, vaxis.ctlseqs.osc4_query, .{index});
            try output.appendSlice(allocator, sequence);
        }
    }

    pub fn appendInitialQuerySequences(
        self: *Capabilities,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
    ) !void {
        try self.appendColorReportQueries(allocator, output);
        try self.appendQuerySequences(allocator, output);
    }

    pub fn appendApplySequence(
        self: *Capabilities,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
        capability: Capability,
    ) !void {
        switch (capability) {
            .kitty_keyboard => {
                if (!self.kitty_keyboard) {
                    try appendKittyKeyboardSetSequence(allocator, output, editor_kitty_keyboard_flags);
                }
                self.kitty_keyboard = true;
            },
            .kitty_graphics => self.kitty_graphics = true,
            .rgb => self.rgb = true,
            .sgr_pixels => self.sgr_pixels = true,
            .unicode => {
                if (!self.unicode) try output.appendSlice(allocator, vaxis.ctlseqs.unicode_set);
                self.unicode = true;
            },
            .da1 => self.da1 = true,
            .color_scheme_updates => {
                if (!self.color_scheme_updates) {
                    try output.appendSlice(
                        allocator,
                        vaxis.ctlseqs.color_scheme_request ++ vaxis.ctlseqs.color_scheme_set,
                    );
                }
                self.color_scheme_updates = true;
            },
            .multi_cursor => self.multi_cursor = true,
        }
    }

    pub fn appendSuspendSequences(
        self: *Capabilities,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
    ) !void {
        if (self.kitty_keyboard and !self.kitty_keyboard_handoff) {
            try appendKittyKeyboardSetSequence(allocator, output, legacy_kitty_keyboard_flags);
            self.kitty_keyboard_handoff = true;
        }
        if (self.unicode) try output.appendSlice(allocator, vaxis.ctlseqs.unicode_reset);
        if (self.color_scheme_updates) try output.appendSlice(allocator, vaxis.ctlseqs.color_scheme_reset);
        if (self.in_band_resize_enabled) try output.appendSlice(allocator, vaxis.ctlseqs.in_band_resize_reset);
        if (self.bracketed_paste) try output.appendSlice(allocator, vaxis.ctlseqs.bp_reset);
        self.unicode = false;
        self.color_scheme_updates = false;
        self.in_band_resize_enabled = false;
        self.in_band_resize = false;
        self.bracketed_paste = false;
    }

    pub fn appendResumeSequences(
        self: *Capabilities,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
    ) !void {
        if (!self.kitty_keyboard_handoff) return;
        try appendKittyKeyboardSetSequence(allocator, output, editor_kitty_keyboard_flags);
        self.kitty_keyboard_handoff = false;
    }

    pub fn appendResetSequences(
        self: *Capabilities,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
    ) !void {
        if (self.kitty_keyboard or self.kitty_keyboard_handoff) {
            try appendKittyKeyboardSetSequence(allocator, output, legacy_kitty_keyboard_flags);
        }
        if (self.unicode) try output.appendSlice(allocator, vaxis.ctlseqs.unicode_reset);
        if (self.color_scheme_updates) try output.appendSlice(allocator, vaxis.ctlseqs.color_scheme_reset);
        if (self.in_band_resize_enabled) try output.appendSlice(allocator, vaxis.ctlseqs.in_band_resize_reset);
        if (self.bracketed_paste) try output.appendSlice(allocator, vaxis.ctlseqs.bp_reset);
        self.kitty_keyboard = false;
        self.kitty_keyboard_handoff = false;
        self.unicode = false;
        self.color_scheme_updates = false;
        self.in_band_resize_enabled = false;
        self.in_band_resize = false;
        self.bracketed_paste = false;
    }
};

fn appendKittyKeyboardSetSequence(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    flags: u5,
) !void {
    const sequence = try std.fmt.allocPrint(allocator, kitty_keyboard_set, .{flags});
    defer allocator.free(sequence);
    try output.appendSlice(allocator, sequence);
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    parser: vaxis.Parser = undefined,
    pending: std.ArrayList(u8) = .empty,
    event_text_arena: std.heap.ArenaAllocator,
    saw_invalid_utf8: bool = false,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator, .event_text_arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Parser) void {
        self.pending.deinit(self.allocator);
        self.event_text_arena.deinit();
        self.* = undefined;
    }

    pub fn resetEventText(self: *Parser) void {
        _ = self.event_text_arena.reset(.retain_capacity);
    }

    pub fn feed(self: *Parser, bytes: []const u8, events: *std.ArrayList(Event)) !void {
        if (self.pending.items.len == 0 and std.mem.eql(u8, bytes, "\x1b")) {
            try events.append(self.allocator, .{ .key_press = .{ .key = .escape } });
            return;
        }

        try self.pending.appendSlice(self.allocator, bytes);
        while (self.pending.items.len != 0) {
            if (incompleteUtf8Prefix(self.pending.items)) break;
            const result = self.parser.parse(self.pending.items, null) catch |err| switch (err) {
                error.InvalidUTF8 => {
                    if (incompleteUtf8Prefix(self.pending.items)) break;
                    try events.append(self.allocator, .invalid_utf8);
                    self.pending.replaceRange(self.allocator, 0, 1, "") catch unreachable;
                    continue;
                },
                else => |e| return e,
            };
            if (result.n == 0) break;
            if (result.event) |event| {
                self.saw_invalid_utf8 = false;
                if (try self.eventFromVaxis(event)) |terminal_event| {
                    if (self.saw_invalid_utf8) try events.append(self.allocator, .invalid_utf8);
                    try events.append(self.allocator, terminal_event);
                } else if (self.saw_invalid_utf8) {
                    try events.append(self.allocator, .invalid_utf8);
                }
            }
            self.pending.replaceRange(self.allocator, 0, result.n, "") catch unreachable;
        }
    }

    fn eventFromVaxis(self: *Parser, event: vaxis.Event) !?Event {
        return switch (event) {
            .key_press => |key| .{ .key_press = try self.keyEventFromVaxis(key) },
            .key_release => |key| .{ .key_release = try self.keyEventFromVaxis(key) },
            .paste => |text| .{ .paste = try self.eventText(text) },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .focus_in => .focus_in,
            .focus_out => .focus_out,
            .cap_kitty_keyboard => .{ .capability = .kitty_keyboard },
            .cap_kitty_graphics => .{ .capability = .kitty_graphics },
            .cap_rgb => .{ .capability = .rgb },
            .cap_sgr_pixels => .{ .capability = .sgr_pixels },
            .cap_unicode => .{ .capability = .unicode },
            .cap_da1 => .{ .capability = .da1 },
            .cap_color_scheme_updates => .{ .capability = .color_scheme_updates },
            .cap_multi_cursor => .{ .capability = .multi_cursor },
            .winsize => |winsize| .{ .resize = winsize },
            .color_scheme => |scheme| .{ .color_scheme = switch (scheme) {
                .dark => .dark,
                .light => .light,
            } },
            .color_report => |report| .{ .color_report = report },
            .mouse, .mouse_leave => null,
        };
    }

    fn keyEventFromVaxis(self: *Parser, key: vaxis.Key) !line_editor.KeyEvent {
        var event = line_editor.keyEventFromVaxis(key);
        if (event.text.len != 0) {
            event.text = try self.eventText(event.text);
        }
        return event;
    }

    fn eventText(self: *Parser, text: []const u8) ![]const u8 {
        if (std.unicode.utf8ValidateSlice(text)) return self.event_text_arena.allocator().dupe(u8, text);

        self.saw_invalid_utf8 = true;
        var sanitized: std.ArrayList(u8) = .empty;
        const arena_allocator = self.event_text_arena.allocator();
        var index: usize = 0;
        while (index < text.len) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch {
                index += 1;
                continue;
            };
            if (index + sequence_len > text.len) break;
            const sequence = text[index .. index + sequence_len];
            if (std.unicode.utf8ValidateSlice(sequence)) {
                try sanitized.appendSlice(arena_allocator, sequence);
                index += sequence_len;
            } else {
                index += 1;
            }
        }
        return sanitized.toOwnedSlice(arena_allocator);
    }
};

pub fn writeAll(tty: *vaxis.tty.PosixTty, bytes: []const u8) !void {
    try tty.writer().writeAll(bytes);
    try tty.writer().flush();
}

pub fn writeText(tty: *vaxis.tty.PosixTty, bytes: []const u8) !void {
    var writer = tty.writer();
    for (bytes) |byte| {
        if (byte == '\n') try writer.writeByte('\r');
        try writer.writeByte(byte);
    }
    try writer.flush();
}

fn incompleteUtf8Prefix(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return false;
    if (sequence_len == 1) return false;
    if (sequence_len == 2 and bytes[0] < 0xc2) return false;
    if (bytes[0] > 0xf4) return false;
    if (bytes.len > 1) {
        if (!utf8ContinuationByte(bytes[1])) return false;
        switch (bytes[0]) {
            0xe0 => if (bytes[1] < 0xa0) return false,
            0xed => if (bytes[1] >= 0xa0) return false,
            0xf0 => if (bytes[1] < 0x90) return false,
            0xf4 => if (bytes[1] >= 0x90) return false,
            else => {},
        }
    }
    if (bytes.len > 2 and !utf8ContinuationByte(bytes[2])) return false;
    return bytes.len < sequence_len;
}

fn utf8ContinuationByte(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn applyTerminalEventsForTest(session: *line_editor.LineSession, events: []const Event) !void {
    for (events) |event| {
        switch (event) {
            .key_press => |key| try session.handleKey(key),
            .paste_start => session.beginPaste(),
            .paste_end => session.endPaste(),
            .paste => |text| try session.handlePaste(text),
            .invalid_utf8,
            .key_release,
            .focus_in,
            .focus_out,
            .resize,
            .capability,
            .color_scheme,
            .color_report,
            .prompt_redraw,
            => {},
        }
    }
}

test "terminal capability planning emits query sequences and records enabled modes" {
    var capabilities: Capabilities = .{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try capabilities.appendInitialQuerySequences(std.testing.allocator, &output);

    try std.testing.expect(capabilities.bracketed_paste);
    try std.testing.expect(capabilities.in_band_resize_enabled);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.osc10_query) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.decrqm_unicode) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.bp_set) != null);
}

test "terminal capability application plans writes only on state changes" {
    var capabilities: Capabilities = .{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try capabilities.appendApplySequence(std.testing.allocator, &output, .unicode);
    try std.testing.expect(capabilities.unicode);
    try std.testing.expectEqualStrings(vaxis.ctlseqs.unicode_set, output.items);

    output.clearRetainingCapacity();
    try capabilities.appendApplySequence(std.testing.allocator, &output, .unicode);
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "terminal capability reset plans active-mode cleanup" {
    var capabilities: Capabilities = .{
        .kitty_keyboard = true,
        .unicode = true,
        .color_scheme_updates = true,
        .bracketed_paste = true,
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try capabilities.appendResetSequences(std.testing.allocator, &output);

    try std.testing.expect(!capabilities.kitty_keyboard);
    try std.testing.expect(!capabilities.unicode);
    try std.testing.expect(!capabilities.color_scheme_updates);
    try std.testing.expect(!capabilities.bracketed_paste);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[=0u") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.unicode_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.color_scheme_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.bp_reset) != null);
}

test "terminal capability suspend forces legacy keyboard during command handoff" {
    var capabilities: Capabilities = .{
        .kitty_keyboard = true,
        .unicode = true,
        .bracketed_paste = true,
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try capabilities.appendSuspendSequences(std.testing.allocator, &output);

    try std.testing.expect(capabilities.kitty_keyboard);
    try std.testing.expect(capabilities.kitty_keyboard_handoff);
    try std.testing.expect(!capabilities.unicode);
    try std.testing.expect(!capabilities.bracketed_paste);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\x1b[=0u") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.unicode_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, vaxis.ctlseqs.bp_reset) != null);

    output.clearRetainingCapacity();
    try capabilities.appendResumeSequences(std.testing.allocator, &output);
    const editor_sequence = try std.fmt.allocPrint(
        std.testing.allocator,
        kitty_keyboard_set,
        .{editor_kitty_keyboard_flags},
    );
    defer std.testing.allocator.free(editor_sequence);

    try std.testing.expect(capabilities.kitty_keyboard);
    try std.testing.expect(!capabilities.kitty_keyboard_handoff);
    try std.testing.expectEqualStrings(editor_sequence, output.items);
}

test "terminal parser emits text keys" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("a", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.text, events.items[0].key_press.key);
    try std.testing.expectEqualStrings("a", events.items[0].key_press.text);
}

test "terminal parser emits color scheme changes" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[?997;1n", &events);
    try parser.feed("\x1b[?997;2n", &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(ColorScheme.dark, events.items[0].color_scheme);
    try std.testing.expectEqual(ColorScheme.light, events.items[1].color_scheme);
}

test "terminal parser emits terminal color reports" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b]10;rgb:0101/2323/4545\x1b\\", &events);
    try parser.feed("\x1b]4;4;rgb:6767/8989/abab\x1b\\", &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(vaxis.Color.Kind.fg, events.items[0].color_report.kind);
    try std.testing.expectEqual([3]u8{ 0x01, 0x23, 0x45 }, events.items[0].color_report.value);
    const color_index: vaxis.Color.Kind = .{ .index = 4 };
    try std.testing.expectEqual(color_index, events.items[1].color_report.kind);
    try std.testing.expectEqual([3]u8{ 0x67, 0x89, 0xab }, events.items[1].color_report.value);
}

test "terminal parser treats single escape chunk as escape key" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.escape, events.items[0].key_press.key);
}

test "terminal parser emits arrow keys" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[D", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.left, events.items[0].key_press.key);
}

test "terminal parser keeps split escape sequences pending" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[", &events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try parser.feed("D", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.left, events.items[0].key_press.key);
}

test "terminal parser emits enter and backspace" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\r\x7f", &events);

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(line_editor.Key.enter, events.items[0].key_press.key);
    try std.testing.expectEqual(line_editor.Key.backspace, events.items[1].key_press.key);
}

test "terminal parser marks bracketed paste around text keys" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[200~echo one\necho two\x1b[201~", &events);

    try std.testing.expect(events.items.len > 3);
    try std.testing.expectEqual(Event.paste_start, events.items[0]);
    try std.testing.expectEqual(Event.paste_end, events.items[events.items.len - 1]);
    var saw_enter = false;
    for (events.items[1 .. events.items.len - 1]) |event| {
        if (event == .key_press and event.key_press.key == .enter) saw_enter = true;
    }
    try std.testing.expect(saw_enter);
}

test "terminal parser keeps large bracketed paste text alive until handled" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    var pasted: std.ArrayList(u8) = .empty;
    defer pasted.deinit(std.testing.allocator);
    for (0..80) |_| try pasted.appendSlice(std.testing.allocator, "true\n");
    try pasted.appendSlice(std.testing.allocator, "touch /tmp/rush-paste-marker\n");

    var sequence: std.ArrayList(u8) = .empty;
    defer sequence.deinit(std.testing.allocator);
    try sequence.appendSlice(std.testing.allocator, "\x1b[200~");
    try sequence.appendSlice(std.testing.allocator, pasted.items);
    try sequence.appendSlice(std.testing.allocator, "\x1b[201~");

    try parser.feed(sequence.items, &events);

    var session = try line_editor.LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    try applyTerminalEventsForTest(&session, events.items);
    try std.testing.expectEqual(line_editor.LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings(pasted.items, session.editor.buffer.text());
}

test "terminal parser round-trips bracketed paste across small chunks" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    var session = try line_editor.LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();

    const pasted = "echo one\necho two\ntouch /tmp/rush-paste-marker\n";
    const sequence = "\x1b[200~" ++ pasted ++ "\x1b[201~";
    var offset: usize = 0;
    while (offset < sequence.len) {
        const end = @min(offset + 7, sequence.len);
        try parser.feed(sequence[offset..end], &events);
        try applyTerminalEventsForTest(&session, events.items);
        events.clearRetainingCapacity();
        parser.resetEventText();
        offset = end;
    }

    try std.testing.expectEqual(line_editor.LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings(pasted, session.editor.buffer.text());
}

test "terminal parser reports invalid utf8 input without failing" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[200~ok\xffdone\x1b[201~", &events);

    var saw_invalid_utf8 = false;
    var saw_paste_end = false;
    var session = try line_editor.LineSession.init(std.testing.allocator, "$ ");
    defer session.deinit();
    for (events.items) |event| {
        switch (event) {
            .invalid_utf8 => saw_invalid_utf8 = true,
            .paste_end => saw_paste_end = true,
            else => {},
        }
    }
    try applyTerminalEventsForTest(&session, events.items);

    try std.testing.expect(saw_invalid_utf8);
    try std.testing.expect(saw_paste_end);
    try std.testing.expectEqual(line_editor.LineSession.State.editing, session.state);
    try std.testing.expectEqualStrings("okdone", session.editor.buffer.text());
}

test "terminal parser waits for split utf8 codepoint" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\xc3", &events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try parser.feed("\xa9", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.text, events.items[0].key_press.key);
    try std.testing.expectEqualStrings("é", events.items[0].key_press.text);
}

test "terminal parser emits tab key" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\t", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(line_editor.Key.tab, events.items[0].key_press.key);
}

test "terminal parser emits in-band resize events" {
    var parser = Parser.init(std.testing.allocator);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);

    try parser.feed("\x1b[48;30;120;600;1200t", &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(@as(u16, 30), events.items[0].resize.rows);
    try std.testing.expectEqual(@as(u16, 120), events.items[0].resize.cols);
}
