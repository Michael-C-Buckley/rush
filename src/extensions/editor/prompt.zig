//! Prompt rendering extension builtins.

const std = @import("std");

const editor_render = @import("../../editor/render.zig");
const api = @import("../api.zig");
const shell_context = @import("../../shell/context.zig");
const delta = @import("../../shell/delta.zig");
const shell_builtin = @import("../../shell/builtin.zig");
const state = @import("../../shell/state.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("prompt", .shell_state),
    shell_builtin.Builtin.initExtension("prompt_pwd", .output),
    shell_builtin.Builtin.initExtension("prompt_duration", .output),
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    previous_duration_ms: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn toOwnedSlice(self: *Builder) ![]u8 {
        const output = try self.bytes.toOwnedSlice(self.allocator);
        self.bytes = .empty;
        return output;
    }
};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    return handlerForContext(name, null);
}

pub fn handlerForContext(name: []const u8, handler_context: ?*anyopaque) ?api.HandlerSpec {
    if (std.mem.eql(u8, name, "prompt")) return .{ .context = handler_context, .handler = evaluatePrompt };
    if (std.mem.eql(u8, name, "prompt_pwd")) return .{ .handler = evaluatePromptPwd };
    if (std.mem.eql(u8, name, "prompt_duration")) return .{
        .context = handler_context,
        .handler = evaluatePromptDuration,
    };
    return null;
}

fn evaluatePrompt(handler_context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "prompt"));
    const builder: *Builder = if (handler_context) |ctx| @ptrCast(@alignCast(ctx)) else {
        return api.EvaluationResult.normal(try invocation.usageError(
            "prompt",
            "only available while rendering prompt",
        ));
    };

    if (invocation.argv.len < 2) return api.EvaluationResult.normal(try promptUsage(invocation));
    if (std.mem.eql(u8, invocation.argv[1], "text")) return evaluatePromptText(builder, invocation);
    if (std.mem.eql(u8, invocation.argv[1], "segment")) return evaluatePromptSegment(builder, invocation);
    if (std.mem.eql(u8, invocation.argv[1], "newline")) return evaluatePromptNewline(builder, invocation);
    return api.EvaluationResult.normal(try invocation.usageError("prompt", "unsupported command"));
}

fn evaluatePromptText(builder: *Builder, invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len < 3) return api.EvaluationResult.normal(try promptUsage(invocation));
    try appendPromptText(builder, invocation.argv[2..]);
    return api.EvaluationResult.normal(0);
}

fn evaluatePromptSegment(builder: *Builder, invocation: *api.Invocation) !api.EvaluationResult {
    var style: editor_render.UiStyle = .{};
    var index: usize = 2;
    while (index < invocation.argv.len) {
        const option = invocation.argv[index];
        if (!std.mem.startsWith(u8, option, "--")) break;
        index += 1;
        if (std.mem.eql(u8, option, "--fg") or std.mem.eql(u8, option, "--bg")) {
            if (index >= invocation.argv.len) return api.EvaluationResult.normal(try promptUsage(invocation));
            const color = editor_render.parseUiColor(invocation.argv[index]) orelse {
                return api.EvaluationResult.normal(try invocation.usageError("prompt", "invalid color"));
            };
            if (std.mem.eql(u8, option, "--fg")) style.fg = color else style.bg = color;
            index += 1;
        } else if (std.mem.eql(u8, option, "--bold")) {
            style.bold = true;
        } else if (std.mem.eql(u8, option, "--dim")) {
            style.dim = true;
        } else if (std.mem.eql(u8, option, "--italic")) {
            style.italic = true;
        } else if (std.mem.eql(u8, option, "--underline")) {
            style.ul = .single;
        } else if (std.mem.eql(u8, option, "--reverse")) {
            style.reverse = true;
        } else if (std.mem.eql(u8, option, "--strikethrough")) {
            style.strike = true;
        } else return api.EvaluationResult.normal(try invocation.usageError("prompt", "unsupported option"));
    }
    if (index >= invocation.argv.len) return api.EvaluationResult.normal(try promptUsage(invocation));

    try editor_render.appendUiStyleStart(builder.allocator, &builder.bytes, style);
    try appendPromptText(builder, invocation.argv[index..]);
    try editor_render.appendUiStyleEnd(builder.allocator, &builder.bytes, style);
    return api.EvaluationResult.normal(0);
}

fn evaluatePromptNewline(builder: *Builder, invocation: *api.Invocation) !api.EvaluationResult {
    if (invocation.argv.len != 2) return api.EvaluationResult.normal(try promptUsage(invocation));
    try builder.bytes.append(builder.allocator, '\n');
    return api.EvaluationResult.normal(0);
}

fn appendPromptText(builder: *Builder, args: []const []const u8) !void {
    for (args, 0..) |arg, index| {
        if (index != 0) try builder.bytes.append(builder.allocator, ' ');
        try builder.bytes.appendSlice(builder.allocator, arg);
    }
}

fn evaluatePromptPwd(handler_context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = handler_context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "prompt_pwd"));

    const options = parsePromptPwdOptions(invocation.argv) orelse {
        return api.EvaluationResult.normal(try invocation.usageError("prompt_pwd", "unsupported option"));
    };
    const cwd = promptCwd(invocation);
    const home = if (invocation.shell_state.getVariable("HOME")) |variable| variable.value else null;
    const display = try formatPromptPwd(invocation.allocator, cwd, home, options);
    defer invocation.allocator.free(display);
    try invocation.stdout.print(invocation.allocator, "{s}\n", .{display});
    return api.EvaluationResult.normal(0);
}

const PromptPwdOptions = struct {
    dir_length: usize = 0,
    full_length_dirs: usize = 1,
};

fn parsePromptPwdOptions(argv: []const []const u8) ?PromptPwdOptions {
    var options: PromptPwdOptions = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const option = argv[index];
        if (std.mem.eql(u8, option, "-d") or std.mem.eql(u8, option, "--dir-length")) {
            index += 1;
            if (index >= argv.len) return null;
            options.dir_length = std.fmt.parseInt(usize, argv[index], 10) catch return null;
        } else if (std.mem.eql(u8, option, "-D") or std.mem.eql(u8, option, "--full-length-dirs")) {
            index += 1;
            if (index >= argv.len) return null;
            options.full_length_dirs = std.fmt.parseInt(usize, argv[index], 10) catch return null;
        } else return null;
    }
    return options;
}

fn promptCwd(invocation: *api.Invocation) []const u8 {
    if (invocation.shell_state.logical_cwd.len != 0) return invocation.shell_state.logical_cwd;
    if (invocation.shell_state.getVariable("PWD")) |variable| if (variable.value.len != 0) return variable.value;
    return ".";
}

fn formatPromptPwd(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    home: ?[]const u8,
    options: PromptPwdOptions,
) ![]const u8 {
    const home_replaced = try replaceHome(allocator, cwd, home);
    defer if (home_replaced.owned) allocator.free(home_replaced.text);
    if (options.dir_length == 0) return allocator.dupe(u8, home_replaced.text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var parts = std.mem.splitScalar(u8, home_replaced.text, '/');
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);
    while (parts.next()) |part| try components.append(allocator, part);

    for (components.items, 0..) |component, index| {
        if (index != 0) try out.append(allocator, '/');
        if (component.len == 0 or component.len == 1 or components.items.len - index <= options.full_length_dirs) {
            try out.appendSlice(allocator, component);
        } else {
            try appendShortComponent(allocator, &out, component, options.dir_length);
        }
    }
    return out.toOwnedSlice(allocator);
}

const ReplacedHome = struct {
    text: []const u8,
    owned: bool = false,
};

fn replaceHome(allocator: std.mem.Allocator, cwd: []const u8, home: ?[]const u8) !ReplacedHome {
    const home_value = home orelse return .{ .text = cwd };
    if (home_value.len == 0) return .{ .text = cwd };
    if (std.mem.eql(u8, cwd, home_value)) return .{ .text = "~" };
    if (std.mem.startsWith(u8, cwd, home_value) and cwd.len > home_value.len and cwd[home_value.len] == '/') {
        return .{ .text = try std.mem.concat(allocator, u8, &.{ "~", cwd[home_value.len..] }), .owned = true };
    }
    return .{ .text = cwd };
}

fn appendShortComponent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    component: []const u8,
    length: usize,
) !void {
    if (length == 0 or component.len <= length) return out.appendSlice(allocator, component);
    if (component[0] == '.' and component.len > 1) {
        try out.append(allocator, '.');
        try out.appendSlice(allocator, component[1..@min(component.len, 1 + length)]);
        return;
    }
    try out.appendSlice(allocator, component[0..length]);
}

fn evaluatePromptDuration(handler_context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "prompt_duration"));
    if (invocation.argv.len != 1) return api.EvaluationResult.normal(try invocation.usageError(
        "prompt_duration",
        "too many arguments",
    ));
    const builder: *Builder = if (handler_context) |ctx| @ptrCast(@alignCast(ctx)) else {
        return api.EvaluationResult.normal(try invocation.usageError(
            "prompt_duration",
            "only available while rendering prompt",
        ));
    };
    const duration_ms = builder.previous_duration_ms orelse return api.EvaluationResult.normal(1);
    try invocation.stdout.print(invocation.allocator, "{d}ms\n", .{duration_ms});
    return api.EvaluationResult.normal(0);
}

fn promptUsage(invocation: *api.Invocation) !u8 {
    return invocation.usageError(
        "prompt",
        "usage: prompt text TEXT... | prompt segment [OPTIONS] TEXT... | prompt newline",
    );
}

test "prompt builder appends styled segments through userdata" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(std.testing.allocator);
    var diagnostics: std.ArrayList([]const u8) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var shell_state = state.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    var state_delta = delta.StateDelta.init(std.testing.allocator, .current_shell);
    defer state_delta.deinit();
    var invocation: api.Invocation = .{
        .allocator = std.testing.allocator,
        .argv = &[_][]const u8{ "prompt", "segment", "--fg", "blue", "rush" },
        .builtins = &.{},
        .shell_state = shell_state,
        .state_delta = &state_delta,
        .eval_context = shell_context.EvalContext.forTarget(.current_shell),
        .stdout = &stdout,
        .stderr = &stderr,
        .diagnostics = &diagnostics,
    };

    const result = try evaluatePrompt(&builder, &invocation);
    try std.testing.expectEqual(@as(u8, 0), result.status);
    try std.testing.expectEqualStrings("\x1b[38;5;4mrush\x1b[39m", builder.bytes.items);
}

test "prompt_pwd shortens home-relative paths" {
    const display = try formatPromptPwd(
        std.testing.allocator,
        "/home/me/repos/rush",
        "/home/me",
        .{ .dir_length = 1, .full_length_dirs = 1 },
    );
    defer std.testing.allocator.free(display);
    try std.testing.expectEqualStrings("~/r/rush", display);
}
