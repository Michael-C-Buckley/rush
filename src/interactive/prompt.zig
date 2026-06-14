//! Interactive prompt and editor environment helpers.

const std = @import("std");

const shell = @import("../shell.zig");

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
