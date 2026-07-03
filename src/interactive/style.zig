//! Interactive editor style and terminal color integration.

const std = @import("std");

const editor = @import("../editor.zig");
const extensions = @import("../extensions.zig");
const host = @import("../host.zig");
const shell = @import("../shell.zig");

const editor_render = editor.render;
const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

pub fn refreshStyle(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    scheme: editor.driver.ColorScheme,
) !editor_render.UiTheme {
    _ = allocator;
    _ = io;
    const sh: *RushShell = @ptrCast(@alignCast(context));
    const scheme_name = colorSchemeName(scheme);
    if (variableChanged(sh, "rush_color_scheme", scheme_name)) {
        try sh.state.putVariable(.{ .name = "rush_color_scheme", .value = scheme_name });
        sh.extensions.style_dirty = true;
    }
    if (sh.extensions.style_dirty) {
        try runStyleFunction(sh);
        sh.extensions.style_dirty = false;
    }
    return theme(sh.state);
}

pub fn refreshColorReport(
    context: *anyopaque,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    allocator: std.mem.Allocator,
    // ziglint-ignore: Z023 parameter order follows method or callback shape; preserve API
    io: std.Io,
    report: editor.driver.ColorReport,
) !editor_render.UiTheme {
    _ = allocator;
    _ = io;
    const sh: *RushShell = @ptrCast(@alignCast(context));
    const variable = colorReportVariable(report) orelse return theme(sh.state);
    var value_buffer: [8]u8 = undefined;
    const value = try std.fmt.bufPrint(
        &value_buffer,
        "#{x:0>2}{x:0>2}{x:0>2}",
        .{ report.value[0], report.value[1], report.value[2] },
    );
    // Only record the color here. Every color-query wave is terminated by a
    // DA1 query, so `refreshStyle` runs `rush_style` once per batch instead of
    // once per report, and only when a report actually changed a color;
    // running it here made a held Enter ~4x slower.
    if (variableChanged(sh, variable, value)) {
        try sh.state.putVariable(.{ .name = variable, .value = value });
        sh.extensions.style_dirty = true;
    }
    return theme(sh.state);
}

fn variableChanged(sh: *RushShell, name: []const u8, value: []const u8) bool {
    const existing = sh.state.getVariable(name) orelse return true;
    return !std.mem.eql(u8, existing.value, value);
}

fn runStyleFunction(sh: *RushShell) !void {
    if (sh.state.getFunction("rush_style") == null) return;
    const src: shell.source.Source = .{ .id = 0, .kind = .command_string, .name = "rush_style", .text = "rush_style" };
    _ = sh.evalSourceNested(src) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
}

fn colorReportVariable(report: editor.driver.ColorReport) ?[]const u8 {
    return switch (report.kind) {
        .fg => "rush_color_foreground",
        .bg => "rush_color_background",
        .cursor => null,
        .index => |index| switch (index) {
            0 => "rush_color_black",
            1 => "rush_color_red",
            2 => "rush_color_green",
            3 => "rush_color_yellow",
            4 => "rush_color_blue",
            5 => "rush_color_magenta",
            6 => "rush_color_cyan",
            7 => "rush_color_white",
            else => null,
        },
    };
}

fn colorSchemeName(scheme: editor.driver.ColorScheme) []const u8 {
    return switch (scheme) {
        .dark => "dark",
        .light => "light",
        .unknown => "unknown",
    };
}

pub fn theme(state: shell.state.State) editor_render.UiTheme {
    var ui_theme: editor_render.UiTheme = .{};
    applyUiStyleVariable(state, &ui_theme.selection, "rush_style_selection");
    applyUiStyleVariable(state, &ui_theme.command, "rush_style_command");
    applyUiStyleVariable(state, &ui_theme.plain, "rush_style_plain");
    applyUiStyleVariable(state, &ui_theme.directory, "rush_style_directory");
    applyUiStyleVariable(state, &ui_theme.option, "rush_style_option");
    applyUiStyleVariable(state, &ui_theme.variable, "rush_style_variable");
    applyUiStyleVariable(state, &ui_theme.function, "rush_style_function");
    applyUiStyleVariable(state, &ui_theme.file, "rush_style_file");
    applyUiStyleVariable(state, &ui_theme.muted, "rush_style_muted");
    applyUiStyleVariable(state, &ui_theme.flash, "rush_style_flash");
    applyUiStyleVariable(state, &ui_theme.match, "rush_style_match");
    applyUiStyleVariable(state, &ui_theme.err, "rush_style_error");
    applyUiStyleVariable(state, &ui_theme.comment, "rush_style_comment");
    applyUiStyleVariable(state, &ui_theme.quote, "rush_style_quote");
    applyUiStyleVariable(state, &ui_theme.pending, "rush_style_pending");
    return ui_theme;
}

fn applyUiStyleVariable(state: shell.state.State, ui_style: *editor_render.UiStyle, name: []const u8) void {
    const variable = state.getVariable(name) orelse return;
    ui_style.* = editor_render.parseUiStyle(variable.value) orelse ui_style.*;
}

test "interactive style refresh runs rush_style with color scheme" {
    // ziglint-ignore: Z010 explicit type retained for readability/type inference
    var sh = RushShell.init(std.testing.allocator, host.RealHost{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\rush_style() {
        \\  if test "$rush_color_scheme" = light; then
        \\    rush_style_match='fg=red,bold'
        \\  else
        \\    rush_style_match='fg=blue'
        \\  fi
        \\}
        ,
    };
    _ = try sh.evalSource(src);

    const ui_theme = try refreshStyle(&sh, std.testing.allocator, std.testing.io, .light);

    try std.testing.expectEqualStrings("light", sh.state.getVariable("rush_color_scheme").?.value);
    try std.testing.expectEqual(editor_render.parseUiColor("red").?, ui_theme.match.fg.?);
    try std.testing.expect(ui_theme.match.bold);
}

test "interactive color reports update rush color variables without running rush_style" {
    // ziglint-ignore: Z010 explicit type retained for readability/type inference
    var sh = RushShell.init(std.testing.allocator, host.RealHost{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text =
        \\rush_style() {
        \\  rush_style_runs=$((${rush_style_runs:-0} + 1))
        \\  rush_style_directory="fg=$rush_color_blue"
        \\}
        ,
    };
    _ = try sh.evalSource(src);

    const report_theme = try refreshColorReport(
        &sh,
        std.testing.allocator,
        std.testing.io,
        .{ .kind = .{ .index = 4 }, .value = .{ 0x01, 0x23, 0x45 } },
    );

    // The report only records the color; rush_style waits for the DA1
    // batch terminator so it runs once per query wave.
    const default_theme: editor_render.UiTheme = .{};
    try std.testing.expectEqualStrings("#012345", sh.state.getVariable("rush_color_blue").?.value);
    try std.testing.expectEqual(default_theme.directory.fg, report_theme.directory.fg);
    try std.testing.expectEqual(null, sh.state.getVariable("rush_style_runs"));

    const ui_theme = try refreshStyle(&sh, std.testing.allocator, std.testing.io, .dark);
    try std.testing.expectEqual(editor_render.parseUiColor("#012345").?, ui_theme.directory.fg.?);
    try std.testing.expectEqualStrings("1", sh.state.getVariable("rush_style_runs").?.value);

    // A repeated batch with identical colors and scheme is deduped:
    // no rush_style rerun on the next DA1.
    _ = try refreshColorReport(
        &sh,
        std.testing.allocator,
        std.testing.io,
        .{ .kind = .{ .index = 4 }, .value = .{ 0x01, 0x23, 0x45 } },
    );
    _ = try refreshStyle(&sh, std.testing.allocator, std.testing.io, .dark);
    try std.testing.expectEqualStrings("1", sh.state.getVariable("rush_style_runs").?.value);

    // A changed color marks the style dirty and reruns once on DA1.
    _ = try refreshColorReport(
        &sh,
        std.testing.allocator,
        std.testing.io,
        .{ .kind = .{ .index = 4 }, .value = .{ 0x67, 0x89, 0xab } },
    );
    const changed_theme = try refreshStyle(&sh, std.testing.allocator, std.testing.io, .dark);
    try std.testing.expectEqual(editor_render.parseUiColor("#6789ab").?, changed_theme.directory.fg.?);
    try std.testing.expectEqualStrings("2", sh.state.getVariable("rush_style_runs").?.value);

    // A scheme change alone also reruns rush_style.
    _ = try refreshStyle(&sh, std.testing.allocator, std.testing.io, .light);
    try std.testing.expectEqualStrings("3", sh.state.getVariable("rush_style_runs").?.value);
}

test {
    std.testing.refAllDecls(@This());
}
