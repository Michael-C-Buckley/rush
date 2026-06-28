//! Key event types and terminal key translation for the editor.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Event = struct {
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

pub fn eventFromVaxis(input: vaxis.Key) Event {
    const modifiers: Modifiers = @bitCast(input.mods);
    return .{
        .key = keyFromVaxis(input.codepoint, modifiers),
        .modifiers = modifiers,
        .text = input.text orelse "",
    };
}

pub fn keyFromVaxis(codepoint: u21, modifiers: Modifiers) Key {
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

test "key mapping supports raw control bytes" {
    try std.testing.expectEqual(Key.home, keyFromVaxis(0x01, .{}));
    try std.testing.expectEqual(Key.tab, keyFromVaxis(0x09, .{}));
    try std.testing.expectEqual(Key.enter, keyFromVaxis(0x0d, .{}));
    try std.testing.expectEqual(Key.backspace, keyFromVaxis(0x7f, .{}));
    try std.testing.expectEqual(Key.clear_screen, keyFromVaxis(0x0c, .{}));
    try std.testing.expectEqual(Key.transpose_chars, keyFromVaxis(0x14, .{}));
    try std.testing.expectEqual(Key.delete_previous_word, keyFromVaxis(0x17, .{}));
    try std.testing.expectEqual(Key.yank, keyFromVaxis(0x19, .{}));
}
