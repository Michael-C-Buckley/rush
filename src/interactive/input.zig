//! Interactive input rendering and editor policy helpers.

const std = @import("std");

const compat = @import("../shell/compat.zig");
const line_editor = @import("../editor.zig").line;
const parser = @import("../shell/parser.zig");
const shell = @import("../shell.zig");

pub fn renderHighlighted(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
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

pub fn needsContinuation(allocator: std.mem.Allocator, source: []const u8, features: compat.Features) !bool {
    var parsed = try parser.parse(allocator, source, .{ .mode = .interactive, .features = features });
    defer parsed.deinit();
    if (parsed.incomplete) return true;
    var index = parsed.tokens.len;
    while (index > 0) {
        index -= 1;
        const kind = parsed.tokens[index].kind;
        if (kind == .eof or kind.isTrivia()) continue;
        return switch (kind) {
            .pipe, .and_if, .or_if => true,
            else => false,
        };
    }
    return false;
}

pub fn editingMode(options: shell.ShellOptions) line_editor.EditingMode {
    return if (options.vi) .vi else .emacs;
}

pub const TitlePath = struct {
    text: []const u8,
    owned: bool = false,
};

pub fn titlePath(allocator: std.mem.Allocator, path: []const u8, maybe_home: ?[]const u8) !TitlePath {
    const home = maybe_home orelse return .{ .text = path };
    if (home.len == 0) return .{ .text = path };
    if (std.mem.eql(u8, path, home)) return .{ .text = "~" };
    if (std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/') {
        return .{ .text = try std.mem.concat(allocator, u8, &.{ "~", path[home.len..] }), .owned = true };
    }
    return .{ .text = path };
}

pub fn outputNeedsNewlineMarker(stdout: []const u8, stderr: []const u8) bool {
    const output = if (stderr.len != 0) stderr else stdout;
    if (output.len == 0) return false;
    return output[output.len - 1] != '\n';
}

test "interactive incomplete input requests continuation until complete" {
    try std.testing.expect(try needsContinuation(std.testing.allocator, "echo \"abc", .{}));
    try std.testing.expect(!try needsContinuation(std.testing.allocator, "echo \"abc\"", .{}));
    try std.testing.expect(try needsContinuation(std.testing.allocator, "for i in 1 2", .{}));
    try std.testing.expect(!try needsContinuation(std.testing.allocator, "for i in 1 2\ndo echo $i\ndone", .{}));
    try std.testing.expect(try needsContinuation(std.testing.allocator, "echo one |", .{}));
    try std.testing.expect(!try needsContinuation(std.testing.allocator, "echo one | wc -c", .{}));
    try std.testing.expect(try needsContinuation(std.testing.allocator, "echo one &&", .{}));
    try std.testing.expect(!try needsContinuation(std.testing.allocator, "echo one && echo two", .{}));
    try std.testing.expect(try needsContinuation(std.testing.allocator, "cat <<EOF", .{}));
    try std.testing.expect(!try needsContinuation(std.testing.allocator, "cat <<EOF\nbody\nEOF", .{}));
}

test "interactive highlight renderer uses parser classifications" {
    const rendered = try renderHighlighted(std.testing.allocator, "echo hi > out # comment");
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[36mecho\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[35m>\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[32m# comment\x1b[0m") != null);
}
