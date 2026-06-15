//! Interactive prompt and editor environment helpers.

const std = @import("std");

const extension_handlers = @import("../extensions/handlers.zig");
const prompt_extension = @import("../extensions/editor/prompt.zig");
const runtime = @import("../runtime.zig");
const shell = @import("../shell.zig");
const command_plan = @import("../shell/command_plan.zig");
const extension_api = @import("../extensions/api.zig");
const interactive_input = @import("input.zig");
const line_editor = @import("../editor.zig").line;

pub fn text(shell_state: *shell.ShellState, name: []const u8, fallback: []const u8) []const u8 {
    return getEnv(shell_state, name) orelse fallback;
}

pub fn renderStatic(allocator: std.mem.Allocator, shell_state: *shell.ShellState) ![]const u8 {
    return allocator.dupe(u8, text(shell_state, "PS1", "$ "));
}

pub const RenderOptions = struct {
    arg_zero: []const u8 = "rush",
    features: shell.compat.Features = .{},
    previous_duration_ms: ?i64 = null,
};

pub fn render(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    options: RenderOptions,
) ![]const u8 {
    shell_state.validate();
    const prompt_function = shell_state.getFunction("rush_prompt") orelse return renderStatic(allocator, shell_state);

    var builder = prompt_extension.Builder.init(allocator);
    defer builder.deinit();
    builder.previous_duration_ms = options.previous_duration_ms;

    var lookup_context: PromptLookupContext = .{ .builder = &builder };
    var adapter = runtime.PosixAdapter.init(io);
    var evaluator = shell.eval.Evaluator.initWithRuntimePorts(allocator, runtime.posixPorts(&adapter));
    evaluator.io = io;
    evaluator.features = options.features;
    evaluator.arg_zero = options.arg_zero;
    evaluator.setExtensionHandlerLookup(&lookup_context, promptExtensionLookup);

    var working_state = shell_state.clone(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => unreachable,
    };
    defer working_state.deinit();

    const plan = command_plan.classifyExpandedSimpleCommand(.{
        .command = .{ .argv = &[_][]const u8{"rush_prompt"} },
        .lookup = .{ .functions = &.{prompt_function} },
        .target = .current_shell,
    });
    var result = shell.eval.evaluatePlan(
        &evaluator,
        &working_state,
        shell.EvalContext.init(.{ .target = .current_shell, .source = .interactive, .interactive = true }),
        plan,
    ) catch return renderStatic(allocator, shell_state);
    defer result.deinit();
    if (result.status != 0 or result.control_flow != .normal or builder.bytes.items.len == 0) {
        return renderStatic(allocator, shell_state);
    }
    return builder.toOwnedSlice();
}

const PromptLookupContext = struct {
    builder: *prompt_extension.Builder,
};

fn promptExtensionLookup(context: ?*anyopaque, name: []const u8) ?extension_api.HandlerSpec {
    const lookup_context: *PromptLookupContext = @ptrCast(@alignCast(context.?));
    if (prompt_extension.handlerForContext(name, lookup_context.builder)) |handler| return handler;
    return extension_handlers.lookup(name);
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
