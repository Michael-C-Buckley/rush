//! Interactive prompt and editor environment helpers.

const std = @import("std");

const shell = @import("../shell.zig");
const interactive_input = @import("input.zig");
const line_editor = @import("../line_editor.zig");

pub fn text(shell_state: *shell.ShellState, name: []const u8, fallback: []const u8) []const u8 {
    return getEnv(shell_state, name) orelse fallback;
}

pub fn renderStatic(allocator: std.mem.Allocator, shell_state: *shell.ShellState) ![]const u8 {
    return allocator.dupe(u8, text(shell_state, "PS1", "$ "));
}

pub fn getEnv(shell_state: *shell.ShellState, name: []const u8) ?[]const u8 {
    std.debug.assert(shell.startup.isValidVariableName(name));
    shell_state.validate();
    if (shell_state.getVariable(name)) |variable| return variable.value;
    return null;
}

pub fn externalEditorCommand(shell_state: *shell.ShellState) []const u8 {
    if (getEnv(shell_state, "VISUAL")) |visual| if (visual.len != 0) return visual;
    if (getEnv(shell_state, "EDITOR")) |editor| if (editor.len != 0) return editor;
    return "vi";
}

pub fn externalEditorTmpdir(shell_state: *shell.ShellState) []const u8 {
    if (getEnv(shell_state, "TMPDIR")) |tmpdir| if (tmpdir.len != 0) return tmpdir;
    return "/tmp";
}

test "interactive prompt helpers use ShellState prompts and editing mode" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("PS1", "semantic> ", .{});
    try shell_state.putVariable("PS2", "semantic2> ", .{});
    shell_state.options.vi = true;
    shell_state.validate();

    const prompt = try renderStatic(std.testing.allocator, &shell_state);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("semantic> ", prompt);
    try std.testing.expectEqualStrings("semantic2> ", text(&shell_state, "PS2", "> "));
    try std.testing.expectEqual(line_editor.EditingMode.vi, interactive_input.editingMode(shell_state.options));
}
