//! Rendering and UI styling for the terminal line editor.

const std = @import("std");
const vaxis = @import("vaxis");

const completion = @import("completion.zig");

const max_menu_candidate_rows = 16;

pub const UnderlineStyle = enum { none, single, double, curly, dotted, dashed };

pub const UiStyle = struct {
    fg: ?vaxis.Color = null,
    bg: ?vaxis.Color = null,
    ul: UnderlineStyle = .none,
    ul_color: ?vaxis.Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    reverse: bool = false,
    strike: bool = false,
};

pub const UiTheme = struct {
    completion_selected: UiStyle = .{ .fg = .{ .index = 6 }, .bold = true },
    completion_directory: UiStyle = .{ .fg = .{ .index = 4 } },
    completion_option: UiStyle = .{ .fg = .{ .index = 6 } },
    completion_variable: UiStyle = .{ .fg = .{ .index = 5 } },
    completion_function: UiStyle = .{ .fg = .{ .index = 5 } },
    completion_file: UiStyle = .{ .fg = .{ .index = 7 } },
    completion_description: UiStyle = .{ .dim = true },
    completion_flash: UiStyle = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } },
    history_match: UiStyle = .{ .fg = .{ .index = 3 } },
    autosuggestion: UiStyle = .{ .dim = true },
    diagnostic_error: UiStyle = .{ .ul = .curly, .ul_color = .{ .index = 1 } },
};

pub const CursorShape = enum {
    default,
    block,
    beam,
    underline,
};

pub fn parseUiStyle(text: []const u8) ?UiStyle {
    var style: UiStyle = .{};
    var iter = std.mem.splitScalar(u8, text, ',');
    while (iter.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "bold")) {
            style.bold = true;
        } else if (std.mem.eql(u8, part, "dim")) {
            style.dim = true;
        } else if (std.mem.eql(u8, part, "italic")) {
            style.italic = true;
        } else if (std.mem.eql(u8, part, "reverse")) {
            style.reverse = true;
        } else if (std.mem.eql(u8, part, "strike")) {
            style.strike = true;
        } else if (std.mem.startsWith(u8, part, "fg=")) {
            style.fg = parseUiColor(part["fg=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, part, "bg=")) {
            style.bg = parseUiColor(part["bg=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, part, "ul_color=")) {
            style.ul_color = parseUiColor(part["ul_color=".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, part, "ul=")) {
            style.ul = parseUiUnderline(part["ul=".len..]) orelse return null;
        } else return null;
    }
    return style;
}

fn parseUiUnderline(name: []const u8) ?UnderlineStyle {
    if (std.mem.eql(u8, name, "none")) return .none;
    if (std.mem.eql(u8, name, "single")) return .single;
    if (std.mem.eql(u8, name, "double")) return .double;
    if (std.mem.eql(u8, name, "curly")) return .curly;
    if (std.mem.eql(u8, name, "dotted")) return .dotted;
    if (std.mem.eql(u8, name, "dashed")) return .dashed;
    return null;
}

fn parseUiColor(name: []const u8) ?vaxis.Color {
    if (std.mem.eql(u8, name, "default")) return .default;
    if (std.mem.eql(u8, name, "black")) return .{ .index = 0 };
    if (std.mem.eql(u8, name, "red")) return .{ .index = 1 };
    if (std.mem.eql(u8, name, "green")) return .{ .index = 2 };
    if (std.mem.eql(u8, name, "yellow")) return .{ .index = 3 };
    if (std.mem.eql(u8, name, "blue")) return .{ .index = 4 };
    if (std.mem.eql(u8, name, "magenta")) return .{ .index = 5 };
    if (std.mem.eql(u8, name, "cyan")) return .{ .index = 6 };
    if (std.mem.eql(u8, name, "white")) return .{ .index = 7 };
    if (std.mem.eql(u8, name, "bright-black")) return .{ .index = 8 };
    if (std.mem.eql(u8, name, "bright-red")) return .{ .index = 9 };
    if (std.mem.eql(u8, name, "bright-green")) return .{ .index = 10 };
    if (std.mem.eql(u8, name, "bright-yellow")) return .{ .index = 11 };
    if (std.mem.eql(u8, name, "bright-blue")) return .{ .index = 12 };
    if (std.mem.eql(u8, name, "bright-magenta")) return .{ .index = 13 };
    if (std.mem.eql(u8, name, "bright-cyan")) return .{ .index = 14 };
    if (std.mem.eql(u8, name, "bright-white")) return .{ .index = 15 };
    if (std.mem.startsWith(u8, name, "index:")) {
        return .{ .index = std.fmt.parseUnsigned(u8, name["index:".len..], 10) catch return null };
    }
    if (name.len != 0 and std.ascii.isDigit(name[0])) {
        return .{ .index = std.fmt.parseUnsigned(u8, name, 10) catch return null };
    }
    if (name.len == 7 and name[0] == '#') {
        return vaxis.Color.rgbFromUint(std.fmt.parseUnsigned(u24, name[1..], 16) catch return null);
    }
    return null;
}

pub const Prompt = struct {
    bytes: []const u8,
    visible_width: ?u16 = null,
};

pub const CompletionFlash = struct {
    start: usize,
    end: usize,
};

pub const Frame = struct {
    lines: []const []const u8,
    input_line_count: usize = 0,
    cursor_row: usize = 0,
    cursor_col: u16 = 0,
    cursor_shape: CursorShape = .default,

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
        return .{
            .lines = lines,
            .input_line_count = self.input_line_count,
            .cursor_row = self.cursor_row,
            .cursor_col = self.cursor_col,
            .cursor_shape = self.cursor_shape,
        };
    }
};

pub const FrameRenderer = struct {
    previous: ?Frame = null,

    pub fn deinit(self: *FrameRenderer, allocator: std.mem.Allocator) void {
        if (self.previous) |*previous| previous.deinit(allocator);
        self.* = undefined;
    }

    pub fn render(
        self: *FrameRenderer,
        allocator: std.mem.Allocator,
        frame: Frame,
        options: FrameRenderOptions,
    ) ![]const u8 {
        const output = if (self.previous) |previous| blk: {
            if (frame.lines.len > previous.lines.len) {
                break :blk try serializeFullFrame(allocator, frame, options.synchronized_output);
            }
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

    pub fn clearRowsAfterFirst(self: FrameRenderer, allocator: std.mem.Allocator) ![]const u8 {
        const previous = self.previous orelse return allocator.dupe(u8, "");
        if (previous.lines.len <= 1) return allocator.dupe(u8, "");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var current_row = previous.cursor_row;
        for (1..previous.lines.len) |row| {
            const move = try cursorMoveFrom(allocator, current_row, row, 0);
            defer allocator.free(move);
            try output.appendSlice(allocator, move);
            try output.appendSlice(allocator, "\x1b[2K");
            current_row = row;
        }
        const restore = try cursorMoveFrom(allocator, current_row, previous.cursor_row, previous.cursor_col);
        defer allocator.free(restore);
        try output.appendSlice(allocator, restore);
        return output.toOwnedSlice(allocator);
    }

    pub fn interruptOutputPrefix(self: FrameRenderer, allocator: std.mem.Allocator) ![]const u8 {
        const previous = self.previous orelse return allocator.dupe(u8, "");

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var current_row = previous.cursor_row;
        for (0..previous.lines.len) |row| {
            const move = try cursorMoveFrom(allocator, current_row, row, 0);
            defer allocator.free(move);
            try output.appendSlice(allocator, move);
            try output.appendSlice(allocator, "\x1b[2K");
            current_row = row;
        }
        const restore = try cursorMoveFrom(allocator, current_row, 0, 0);
        defer allocator.free(restore);
        try output.appendSlice(allocator, restore);
        return output.toOwnedSlice(allocator);
    }

    pub fn submittedHandoff(self: FrameRenderer, allocator: std.mem.Allocator) ![]const u8 {
        const previous = self.previous orelse return allocator.dupe(u8, "");
        const input_line_count = @min(@max(previous.input_line_count, 1), previous.lines.len);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var current_row = previous.cursor_row;
        if (previous.lines.len > input_line_count) {
            for (input_line_count..previous.lines.len) |row| {
                const move = try cursorMoveFrom(allocator, current_row, row, 0);
                defer allocator.free(move);
                try output.appendSlice(allocator, move);
                try output.appendSlice(allocator, "\x1b[2K");
                current_row = row;
            }
        }
        const move_to_bottom = try cursorMoveFrom(allocator, current_row, input_line_count - 1, 0);
        defer allocator.free(move_to_bottom);
        try output.appendSlice(allocator, move_to_bottom);
        return output.toOwnedSlice(allocator);
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
    completion_label_width: ?usize = null,
    suggestion: []const u8 = "",
    status_line: []const u8 = "",
    diagnostic_line: []const u8 = "",
    diagnostic_spans: []const DiagnosticSpan = &.{},
    completion_flash: ?CompletionFlash = null,
    theme: UiTheme = .{},
    semantic_prompt_marks: bool = false,
    width: u16 = 80,
    height: u16 = 24,
    width_method: vaxis.gwidth.Method = .unicode,
    synchronized_output: bool = true,
    cursor_shape: CursorShape = .default,

    pub fn menuCandidateRows(self: RenderOptions) usize {
        return @min(@max(@as(usize, @intCast(self.height)) -| 2, 1), max_menu_candidate_rows);
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

pub const semantic_prompt_end = "\x1b]133;B\x07";

pub const Input = struct {
    text: []const u8,
    cursor_byte: usize,
};

pub fn renderLine(allocator: std.mem.Allocator, input: Input, options: RenderOptions) ![]const u8 {
    var frame = try frameFromInput(allocator, input, options);
    defer frame.deinit(allocator);
    return serializeFullFrame(allocator, frame, options.synchronized_output);
}

pub fn frameFromInput(allocator: std.mem.Allocator, input: Input, options: RenderOptions) !Frame {
    std.debug.assert(input.cursor_byte <= input.text.len);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var input_line: std.ArrayList(u8) = .empty;
    errdefer input_line.deinit(allocator);
    try input_line.appendSlice(allocator, options.prompt.bytes);
    if (options.semantic_prompt_marks) try input_line.appendSlice(allocator, semantic_prompt_end);
    try appendStyledInput(
        allocator,
        &input_line,
        input.text,
        options.diagnostic_spans,
        options.completion_flash,
        options.theme,
    );
    if (options.suggestion.len != 0 and renderableInlineText(options.suggestion)) {
        try appendUiStyleStart(allocator, &input_line, options.theme.autosuggestion);
        try input_line.appendSlice(allocator, options.suggestion);
        try appendUiStyleEnd(allocator, &input_line, options.theme.autosuggestion);
    }
    const input_line_bytes = try input_line.toOwnedSlice(allocator);
    defer allocator.free(input_line_bytes);

    const wrap_width = @max(options.width, 1);
    var cursor_prefix: std.ArrayList(u8) = .empty;
    defer cursor_prefix.deinit(allocator);
    try cursor_prefix.appendSlice(allocator, options.prompt.bytes);
    try cursor_prefix.appendSlice(allocator, input.text[0..input.cursor_byte]);
    const cursor_position = wrappedPosition(cursor_prefix.items, wrap_width, options.width_method);

    try appendWrappedLine(allocator, &lines, input_line_bytes, wrap_width, options.width_method);
    if (cursor_position.row == lines.items.len) try lines.append(allocator, try allocator.dupe(u8, ""));
    const input_line_count = lines.items.len;
    if (options.status_line.len != 0) {
        try appendWrappedLine(allocator, &lines, options.status_line, wrap_width, options.width_method);
    }
    if (options.diagnostic_line.len != 0) {
        try appendWrappedLine(allocator, &lines, options.diagnostic_line, wrap_width, options.width_method);
    }
    try appendCompletionMenuLines(allocator, &lines, .{
        .candidates = options.completion_menu,
        .selected = options.completion_selection,
        .window_start = options.completion_window_start,
        .width = options.width,
        .height = options.height,
        .label_width_override = options.completion_label_width,
        .theme = options.theme,
    });

    return .{
        .lines = try lines.toOwnedSlice(allocator),
        .input_line_count = input_line_count,
        .cursor_row = cursor_position.row,
        .cursor_col = cursor_position.col,
        .cursor_shape = options.cursor_shape,
    };
}

fn appendStyledInput(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    spans: []const DiagnosticSpan,
    flash: ?CompletionFlash,
    theme: UiTheme,
) !void {
    if (spans.len == 0 and flash == null) {
        try out.appendSlice(allocator, text);
        return;
    }

    var active: ?DiagnosticSeverity = null;
    var flash_active = false;
    var i: usize = 0;
    while (i < text.len) {
        var iter = vaxis.unicode.graphemeIterator(text[i..]);
        const grapheme = iter.next() orelse break;
        const grapheme_end = i + grapheme.len;
        const should_flash = completionFlashAt(flash, i, grapheme_end);
        if (flash_active != should_flash) {
            if (flash_active) try appendUiStyleEnd(allocator, out, theme.completion_flash);
            if (should_flash) try appendUiStyleStart(allocator, out, theme.completion_flash);
            flash_active = should_flash;
        }
        const severity = diagnosticSeverityAt(spans, i, grapheme_end);
        if (active != severity) {
            if (active != null) try out.appendSlice(allocator, "\x1b[24;59m");
            if (severity) |value| try appendUiStyleStart(allocator, out, diagnosticStyle(theme, value));
            active = severity;
        }
        try out.appendSlice(allocator, text[i..grapheme_end]);
        i = grapheme_end;
    }
    if (active != null) try out.appendSlice(allocator, "\x1b[24;59m");
    if (flash_active) try appendUiStyleEnd(allocator, out, theme.completion_flash);
    if (i < text.len) try out.appendSlice(allocator, text[i..]);
}

fn completionFlashAt(flash: ?CompletionFlash, start: usize, end: usize) bool {
    const span = flash orelse return false;
    return start < span.end and end > span.start;
}

pub fn completionFlashForCursor(text: []const u8, cursor: usize) CompletionFlash {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    var start = @min(cursor, text.len);
    while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) : (start -= 1) {}
    var end = @min(cursor, text.len);
    while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
    if (start == end and start != 0) start -= 1;
    return .{ .start = start, .end = end };
}

fn diagnosticStyle(theme: UiTheme, _: DiagnosticSeverity) UiStyle {
    return theme.diagnostic_error;
}

pub fn appendUiStyleStart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), style: UiStyle) !void {
    if (style.bold) try out.appendSlice(allocator, "\x1b[1m");
    if (style.dim) try out.appendSlice(allocator, "\x1b[2m");
    if (style.italic) try out.appendSlice(allocator, "\x1b[3m");
    switch (style.ul) {
        .none => {},
        .single => try out.appendSlice(allocator, "\x1b[4m"),
        .double => try out.appendSlice(allocator, "\x1b[4:2m"),
        .curly => try out.appendSlice(allocator, "\x1b[4:3m"),
        .dotted => try out.appendSlice(allocator, "\x1b[4:4m"),
        .dashed => try out.appendSlice(allocator, "\x1b[4:5m"),
    }
    if (style.reverse) try out.appendSlice(allocator, "\x1b[7m");
    if (style.strike) try out.appendSlice(allocator, "\x1b[9m");
    if (style.fg) |color| try appendAnsiColor(allocator, out, .fg, color);
    if (style.bg) |color| try appendAnsiColor(allocator, out, .bg, color);
    if (style.ul_color) |color| try appendAnsiColor(allocator, out, .ul, color);
}

pub fn appendUiStyleEnd(allocator: std.mem.Allocator, out: *std.ArrayList(u8), style: UiStyle) !void {
    if (style.strike) try out.appendSlice(allocator, "\x1b[29m");
    if (style.reverse) try out.appendSlice(allocator, "\x1b[27m");
    if (style.ul != .none or style.ul_color != null) try out.appendSlice(allocator, "\x1b[24;59m");
    if (style.italic) try out.appendSlice(allocator, "\x1b[23m");
    if (style.bold or style.dim) try out.appendSlice(allocator, "\x1b[22m");
    if (style.bg != null) try out.appendSlice(allocator, "\x1b[49m");
    if (style.fg != null) try out.appendSlice(allocator, "\x1b[39m");
}

fn appendAnsiColor(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: enum { fg, bg, ul },
    color: vaxis.Color,
) !void {
    switch (color) {
        .default => switch (kind) {
            .fg => try out.appendSlice(allocator, "\x1b[39m"),
            .bg => try out.appendSlice(allocator, "\x1b[49m"),
            .ul => try out.appendSlice(allocator, "\x1b[59m"),
        },
        .index => |index| {
            const prefix = switch (kind) {
                .fg => "38",
                .bg => "48",
                .ul => "58",
            };
            const sequence = try std.fmt.allocPrint(allocator, "\x1b[{s};5;{d}m", .{ prefix, index });
            defer allocator.free(sequence);
            try out.appendSlice(allocator, sequence);
        },
        .rgb => |rgb| {
            const prefix = switch (kind) {
                .fg => "38",
                .bg => "48",
                .ul => "58",
            };
            const sequence = try std.fmt.allocPrint(
                allocator,
                "\x1b[{s};2;{d};{d};{d}m",
                .{ prefix, rgb[0], rgb[1], rgb[2] },
            );
            defer allocator.free(sequence);
            try out.appendSlice(allocator, sequence);
        },
    }
}

fn diagnosticSeverityAt(spans: []const DiagnosticSpan, start: usize, end: usize) ?DiagnosticSeverity {
    for (spans) |span| {
        const span_end = @max(span.end, span.start + 1);
        if (start < span_end and end > span.start) return span.severity;
    }
    return null;
}

pub fn renderableInlineText(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

pub fn serializeFullFrame(allocator: std.mem.Allocator, frame: Frame, synchronized_output: bool) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");
    if (frame.cursor_shape != .default) try output.appendSlice(allocator, cursorShapeSequence(frame.cursor_shape));
    try output.appendSlice(allocator, "\r\x1b[2K");
    if (frame.lines.len != 0) try output.appendSlice(allocator, frame.lines[0]);
    for (frame.lines[1..]) |line| {
        try output.appendSlice(allocator, "\r\n\x1b[2K");
        try output.appendSlice(allocator, line);
    }
    const cursor_sequence = try cursorMoveFrom(allocator, frame.lines.len -| 1, frame.cursor_row, frame.cursor_col);
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");

    return output.toOwnedSlice(allocator);
}

fn serializeFrameDiff(
    allocator: std.mem.Allocator,
    previous: Frame,
    frame: Frame,
    synchronized_output: bool,
) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026h");
    if (previous.cursor_shape != frame.cursor_shape) {
        try output.appendSlice(allocator, cursorShapeSequence(frame.cursor_shape));
    }

    var current_row = previous.cursor_row;
    const max_lines = @max(previous.lines.len, frame.lines.len);
    for (0..max_lines) |row| {
        const old_line = if (row < previous.lines.len) previous.lines[row] else null;
        const new_line = if (row < frame.lines.len) frame.lines[row] else null;
        const changed = if (old_line) |old|
            if (new_line) |new| !std.mem.eql(u8, old, new) else true
        else
            new_line != null;
        if (!changed) continue;
        const move = try cursorMoveFrom(allocator, current_row, row, 0);
        defer allocator.free(move);
        try output.appendSlice(allocator, move);
        try output.appendSlice(allocator, "\x1b[2K");
        if (new_line) |line| try output.appendSlice(allocator, line);
        current_row = row;
    }

    const cursor_sequence = try cursorMoveFrom(allocator, current_row, frame.cursor_row, frame.cursor_col);
    defer allocator.free(cursor_sequence);
    try output.appendSlice(allocator, cursor_sequence);
    if (synchronized_output) try output.appendSlice(allocator, "\x1b[?2026l");
    return output.toOwnedSlice(allocator);
}

fn cursorShapeSequence(shape: CursorShape) []const u8 {
    return switch (shape) {
        .default => "\x1b[0 q",
        .block => "\x1b[2 q",
        .beam => "\x1b[6 q",
        .underline => "\x1b[4 q",
    };
}

fn cursorMoveFrom(allocator: std.mem.Allocator, from_row: usize, to_row: usize, col: u16) ![]const u8 {
    if (col == 0) {
        if (from_row > to_row) return std.fmt.allocPrint(allocator, "\x1b[{d}A\r", .{from_row - to_row});
        if (to_row > from_row) return std.fmt.allocPrint(allocator, "\x1b[{d}B\r", .{to_row - from_row});
        return allocator.dupe(u8, "\r");
    }
    if (from_row > to_row) {
        return std.fmt.allocPrint(allocator, "\x1b[{d}A\r\x1b[{d}C", .{ from_row - to_row, col });
    }
    if (to_row > from_row) {
        return std.fmt.allocPrint(allocator, "\x1b[{d}B\r\x1b[{d}C", .{ to_row - from_row, col });
    }
    return std.fmt.allocPrint(allocator, "\r\x1b[{d}C", .{col});
}

fn appendWrappedLine(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    bytes: []const u8,
    width: u16,
    method: vaxis.gwidth.Method,
) !void {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(allocator);
    var row_width: u16 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '\n') {
            try lines.append(allocator, try row.toOwnedSlice(allocator));
            row = .empty;
            row_width = 0;
            i += 1;
            continue;
        }
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
        if (bytes[i] == '\n') {
            row += 1;
            col = 0;
            i += 1;
            continue;
        }
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

const CompletionMenuOptions = struct {
    candidates: []const completion.Candidate,
    selected: usize,
    window_start: usize,
    width: u16,
    height: u16,
    label_width_override: ?usize,
    theme: UiTheme,
};

fn appendCompletionMenuLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]const u8),
    options: CompletionMenuOptions,
) !void {
    const candidates = options.candidates;
    if (candidates.len == 0) return;
    const max_rows = @min(@max(@as(usize, @intCast(options.height)) -| 2, 1), max_menu_candidate_rows);
    const window = completionMenuWindow(candidates.len, options.selected, options.window_start, max_rows);
    const label_width = options.label_width_override orelse try completionMenuLabelWidth(
        allocator,
        candidates[window.start..window.end],
        options.width,
    );
    const fixed_width = 2 + label_width + 1;
    const description_width = @as(usize, @intCast(options.width)) -| fixed_width;
    for (candidates[window.start..window.end], window.start..) |candidate, index| {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        const label = try completionMenuLabel(allocator, candidate);
        defer if (label.owned) |owned| allocator.free(owned);
        if (index == options.selected) {
            try appendUiStyleStart(allocator, &line, options.theme.completion_selected);
            try line.appendSlice(allocator, "  ");
            const kind_style = completionKindStyle(options.theme, candidate.kind);
            try appendUiStyleStart(allocator, &line, kind_style);
            try appendPaddedCell(allocator, &line, label.text, label_width);
            try appendUiStyleEnd(allocator, &line, kind_style);
            try appendUiStyleStart(allocator, &line, options.theme.completion_selected);
            if (candidate.description) |description| {
                if (description.len != 0 and description_width != 0) {
                    try line.append(allocator, ' ');
                    try appendUiStyleStart(allocator, &line, options.theme.completion_description);
                    try appendTruncated(allocator, &line, description, description_width);
                    try appendUiStyleEnd(allocator, &line, options.theme.completion_description);
                    try appendUiStyleStart(allocator, &line, options.theme.completion_selected);
                }
            }
            try line.appendSlice(allocator, "  ");
            try appendUiStyleEnd(allocator, &line, options.theme.completion_selected);
        } else {
            try line.appendSlice(allocator, "  ");
            const kind_style = completionKindStyle(options.theme, candidate.kind);
            try appendUiStyleStart(allocator, &line, kind_style);
            try appendPaddedCell(allocator, &line, label.text, label_width);
            try appendUiStyleEnd(allocator, &line, kind_style);
            if (candidate.description) |description| {
                if (description.len != 0 and description_width != 0) {
                    try line.append(allocator, ' ');
                    try appendUiStyleStart(allocator, &line, options.theme.completion_description);
                    try appendTruncated(allocator, &line, description, description_width);
                    try appendUiStyleEnd(allocator, &line, options.theme.completion_description);
                }
            }
        }
        try lines.append(allocator, try line.toOwnedSlice(allocator));
    }
    if (window.start != 0 or window.end != candidates.len) {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, "  ");
        try appendUiStyleStart(allocator, &line, options.theme.completion_description);
        const text = try std.fmt.allocPrint(
            allocator,
            "showing {d}-{d} of {d}",
            .{ window.start + 1, window.end, candidates.len },
        );
        defer allocator.free(text);
        try line.appendSlice(allocator, text);
        try appendUiStyleEnd(allocator, &line, options.theme.completion_description);
        try lines.append(allocator, try line.toOwnedSlice(allocator));
    }
}

fn completionMenuLabelWidth(allocator: std.mem.Allocator, candidates: []const completion.Candidate, width: u16) !usize {
    var widest: usize = 0;
    for (candidates) |candidate| {
        const label = try completionMenuLabel(allocator, candidate);
        defer if (label.owned) |owned| allocator.free(owned);
        widest = @max(widest, visibleWidth(label.text, .unicode));
    }
    return @min(widest, @as(usize, @intCast(width)) -| 3);
}

const CompletionMenuLabel = struct {
    text: []const u8,
    owned: ?[]const u8 = null,
};

fn completionMenuLabel(allocator: std.mem.Allocator, candidate: completion.Candidate) !CompletionMenuLabel {
    if (candidate.display) |display| return .{ .text = display };
    if (candidate.kind != .option) return .{ .text = candidate.value };
    const option = candidate.option orelse return .{ .text = candidate.value };
    if (option.long) |long| {
        if (option.short) |short| {
            const owned = try std.fmt.allocPrint(allocator, "--{s},-{s}", .{ long, short });
            return .{ .text = owned, .owned = owned };
        }
    }
    return .{ .text = candidate.value };
}

fn completionKindStyle(theme: UiTheme, kind: completion.Kind) UiStyle {
    return switch (kind) {
        .function => theme.completion_function,
        .file => theme.completion_file,
        .directory => theme.completion_directory,
        .variable => theme.completion_variable,
        .option => theme.completion_option,
        .command, .builtin, .subcommand, .plain => .{},
    };
}

const CompletionMenuWindow = struct {
    start: usize,
    end: usize,
};

fn completionMenuWindow(count: usize, selected: usize, window_start: usize, max_rows: usize) CompletionMenuWindow {
    if (count <= max_rows) return .{ .start = 0, .end = count };
    if (selected == std.math.maxInt(usize)) {
        const start = @min(window_start, count - max_rows);
        return .{ .start = start, .end = @min(start + max_rows, count) };
    }
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
    const written = visibleWidth(output.items[before..], .unicode);
    if (written < width) try output.appendNTimes(allocator, ' ', width - written);
}

fn appendTruncated(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    if (width == 0) return;
    if (visibleWidth(text, .unicode) <= width) {
        try output.appendSlice(allocator, text);
        return;
    }
    if (width == 1) {
        try output.appendSlice(allocator, "…");
        return;
    }
    var written: usize = 0;
    var i: usize = 0;
    while (i < text.len and written < width - 1) {
        if (escapeSequenceEnd(text, i)) |end| {
            try output.appendSlice(allocator, text[i..end]);
            i = end;
            continue;
        }
        try output.append(allocator, text[i]);
        i += 1;
        written += 1;
    }
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
