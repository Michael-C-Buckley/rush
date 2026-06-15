//! Color utility Rush extension builtins.

const std = @import("std");

const api = @import("api.zig");
const shell_builtin = @import("../shell/builtin.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("color", .output),
};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "color")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "color"));

    if (invocation.argv.len < 2) return api.EvaluationResult.normal(try usage(invocation));
    if (std.mem.eql(u8, invocation.argv[1], "dim")) return evaluateDim(invocation);
    if (std.mem.eql(u8, invocation.argv[1], "blend")) return evaluateBlend(invocation);
    return api.EvaluationResult.normal(try invocation.usageError("color", "unsupported command"));
}

fn evaluateDim(invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len != 4) return api.EvaluationResult.normal(try usage(invocation));
    const color = parseRgb(invocation.argv[2]) orelse {
        return api.EvaluationResult.normal(try invalidColor(invocation));
    };
    const percent = parsePercent(invocation.argv[3]) orelse {
        return api.EvaluationResult.normal(try invalidPercent(invocation));
    };
    try printRgb(invocation, blendRgb(color, .{ .r = 0, .g = 0, .b = 0 }, percent));
    return api.EvaluationResult.normal(0);
}

fn evaluateBlend(invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len != 5) return api.EvaluationResult.normal(try usage(invocation));
    const from = parseRgb(invocation.argv[2]) orelse {
        return api.EvaluationResult.normal(try invalidColor(invocation));
    };
    const to = parseRgb(invocation.argv[3]) orelse return api.EvaluationResult.normal(try invalidColor(invocation));
    const percent = parsePercent(invocation.argv[4]) orelse {
        return api.EvaluationResult.normal(try invalidPercent(invocation));
    };
    try printRgb(invocation, blendRgb(from, to, percent));
    return api.EvaluationResult.normal(0);
}

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

fn parseRgb(text: []const u8) ?Rgb {
    if (text.len != 7 or text[0] != '#') return null;
    return .{
        .r = std.fmt.parseInt(u8, text[1..3], 16) catch return null,
        .g = std.fmt.parseInt(u8, text[3..5], 16) catch return null,
        .b = std.fmt.parseInt(u8, text[5..7], 16) catch return null,
    };
}

fn parsePercent(text: []const u8) ?u8 {
    const percent = std.fmt.parseInt(u8, text, 10) catch return null;
    if (percent > 100) return null;
    return percent;
}

fn blendRgb(from: Rgb, to: Rgb, percent: u8) Rgb {
    return .{
        .r = blendChannel(from.r, to.r, percent),
        .g = blendChannel(from.g, to.g, percent),
        .b = blendChannel(from.b, to.b, percent),
    };
}

fn blendChannel(from: u8, to: u8, percent: u8) u8 {
    const left: u16 = @as(u16, from) * (100 - @as(u16, percent));
    const right: u16 = @as(u16, to) * @as(u16, percent);
    return @intCast((left + right + 50) / 100);
}

fn printRgb(invocation: *api.Invocation, color: Rgb) !void {
    try invocation.stdout.append(invocation.allocator, '#');
    try appendHexByte(invocation.allocator, invocation.stdout, color.r);
    try appendHexByte(invocation.allocator, invocation.stdout, color.g);
    try appendHexByte(invocation.allocator, invocation.stdout, color.b);
    try invocation.stdout.append(invocation.allocator, '\n');
}

fn appendHexByte(allocator: std.mem.Allocator, out: *std.ArrayList(u8), byte: u8) !void {
    const digits = "0123456789abcdef";
    try out.append(allocator, digits[byte >> 4]);
    try out.append(allocator, digits[byte & 0x0f]);
}

fn usage(invocation: *api.Invocation) !u8 {
    return invocation.usageError("color", "usage: color dim COLOR PERCENT | color blend COLOR COLOR PERCENT");
}

fn invalidColor(invocation: *api.Invocation) !u8 {
    return invocation.usageError("color", "invalid color");
}

fn invalidPercent(invocation: *api.Invocation) !u8 {
    return invocation.usageError("color", "invalid percent");
}

test "color blends rgb values" {
    try std.testing.expectEqual(@as(Rgb, .{ .r = 0x18, .g = 0x30, .b = 0x60 }), blendRgb(
        .{ .r = 0x20, .g = 0x40, .b = 0x80 },
        .{ .r = 0, .g = 0, .b = 0 },
        25,
    ));
    try std.testing.expectEqual(@as(Rgb, .{ .r = 0x80, .g = 0x80, .b = 0x80 }), blendRgb(
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0xff, .g = 0xff, .b = 0xff },
        50,
    ));
}

test "color parses strict truecolor values and percentages" {
    try std.testing.expectEqual(@as(Rgb, .{ .r = 0x20, .g = 0x40, .b = 0x80 }), parseRgb("#204080").?);
    try std.testing.expectEqual(@as(?Rgb, null), parseRgb("204080"));
    try std.testing.expectEqual(@as(?Rgb, null), parseRgb("#20408"));
    try std.testing.expectEqual(@as(?Rgb, null), parseRgb("#20408x"));
    try std.testing.expectEqual(@as(?u8, 100), parsePercent("100"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("101"));
}
