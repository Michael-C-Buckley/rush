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
    try sh.state.putVariable(.{ .name = "rush_color_scheme", .value = colorSchemeName(scheme) });
    try runStyleFunction(sh);
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
    try sh.state.putVariable(.{ .name = variable, .value = value });
    try runStyleFunction(sh);
    return theme(sh.state);
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
    applyUiStyleVariable(state, &ui_theme.completion_selected, "rush_style_completion_selected");
    applyUiStyleVariable(state, &ui_theme.completion_command, "rush_style_completion_command");
    applyUiStyleVariable(state, &ui_theme.completion_builtin, "rush_style_completion_builtin");
    applyUiStyleVariable(state, &ui_theme.completion_subcommand, "rush_style_completion_subcommand");
    applyUiStyleVariable(state, &ui_theme.completion_plain, "rush_style_completion_plain");
    applyUiStyleVariable(state, &ui_theme.completion_directory, "rush_style_completion_directory");
    applyUiStyleVariable(state, &ui_theme.completion_option, "rush_style_completion_option");
    applyUiStyleVariable(state, &ui_theme.completion_variable, "rush_style_completion_variable");
    applyUiStyleVariable(state, &ui_theme.completion_function, "rush_style_completion_function");
    applyUiStyleVariable(state, &ui_theme.completion_file, "rush_style_completion_file");
    applyUiStyleVariable(state, &ui_theme.completion_description, "rush_style_completion_description");
    applyUiStyleVariable(state, &ui_theme.completion_summary, "rush_style_completion_summary");
    applyUiStyleVariable(state, &ui_theme.completion_flash, "rush_style_completion_flash");
    applyUiStyleVariable(state, &ui_theme.history_match, "rush_style_history_match");
    applyUiStyleVariable(state, &ui_theme.autosuggestion, "rush_style_autosuggestion");
    applyUiStyleVariable(state, &ui_theme.diagnostic_error, "rush_style_diagnostic_error");
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
        \\    rush_style_history_match='fg=red,bold'
        \\  else
        \\    rush_style_history_match='fg=blue'
        \\  fi
        \\}
        ,
    };
    _ = try sh.evalSource(src);

    const ui_theme = try refreshStyle(&sh, std.testing.allocator, std.testing.io, .light);

    try std.testing.expectEqualStrings("light", sh.state.getVariable("rush_color_scheme").?.value);
    try std.testing.expectEqual(editor_render.parseUiColor("red").?, ui_theme.history_match.fg.?);
    try std.testing.expect(ui_theme.history_match.bold);
}

test "interactive color reports update rush color variables" {
    // ziglint-ignore: Z010 explicit type retained for readability/type inference
    var sh = RushShell.init(std.testing.allocator, host.RealHost{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text = "rush_style() { rush_style_completion_directory=\"fg=$rush_color_blue\"; }",
    };
    _ = try sh.evalSource(src);

    const ui_theme = try refreshColorReport(
        &sh,
        std.testing.allocator,
        std.testing.io,
        .{ .kind = .{ .index = 4 }, .value = .{ 0x01, 0x23, 0x45 } },
    );

    try std.testing.expectEqualStrings("#012345", sh.state.getVariable("rush_color_blue").?.value);
    try std.testing.expectEqual(editor_render.parseUiColor("#012345").?, ui_theme.completion_directory.fg.?);
}

test {
    std.testing.refAllDecls(@This());
}
