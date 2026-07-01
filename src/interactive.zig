//! Interactive Rush session orchestration.

const std = @import("std");
const build_config = @import("build_config");
const default_config = @embedFile("default_config");

const editor = @import("editor.zig");
const extensions = @import("extensions.zig");
const file_util = @import("file_util.zig");
const history = @import("history.zig");
const host = @import("host.zig");
const shell = @import("shell.zig");

const editor_render = editor.render;

const RushShell = shell.ShellWithBuiltins(host.RealHost, extensions.rush.registry);

pub const Options = struct {
    state_options: shell.state.Options,
    arg_zero: []const u8,
    positionals: []const []const u8 = &.{},
    login: bool = false,
};

pub fn run(
    allocator: std.mem.Allocator,
    real_host: host.RealHost,
    io: std.Io,
    env: []const [*:0]const u8,
    options: Options,
) !u8 {
    var sh = RushShell.init(allocator, real_host, .{
        .state = options.state_options,
        .env = env,
        .arg_zero = options.arg_zero,
        .positionals = options.positionals,
    });
    defer sh.deinit();

    const prompted_stdin = !sh.host.isTerminalFd(.stdin);

    var source_id: shell.source.SourceId = 1;
    if (try sourceStartup(&sh, &source_id, options.login, !prompted_stdin)) |status| return status;

    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    if (try historyPath(allocator, env)) |path| {
        defer allocator.free(path);
        command_history.load(io, path) catch |err| {
            const message = try std.fmt.allocPrint(
                sh.scratchAllocator(),
                "rush: history disabled: {s}\n",
                .{@errorName(err)},
            );
            try sh.host.writeAll(.stderr, message);
        };
    }
    command_history.session_id = history.sessionId(allocator, io) catch "";
    var history_service = history.InteractiveHistoryService.init(&command_history);

    if (prompted_stdin) {
        return runPromptedStdin(allocator, &sh, &source_id);
    }

    var terminal = editor.driver.TerminalSession.init(allocator, io) catch {
        try sh.host.writeAll(.stderr, "rush: cannot initialize terminal\n");
        return 2;
    };
    defer terminal.deinit();

    var last_command_duration_ms: ?i64 = null;
    while (true) {
        const prompt_text = extensions.rush.renderPrompt(
            allocator,
            &sh,
            sh.state.last_status,
            last_command_duration_ms,
        ) catch try prompt(allocator, &sh);
        defer allocator.free(prompt_text);
        const current_cwd = sh.host.currentDir(allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(current_cwd);
        command_history.current_cwd = current_cwd;
        const line_result = terminal.readLine(.{
            .prompt = prompt_text,
            .history = history_service.lineEditorView(io),
            .completion_context = &sh,
            .expand_abbreviation = expandRushAbbreviation,
            .theme = interactiveUiTheme(sh.state),
            .style_context = &sh,
            .refresh_style = refreshInteractiveStyle,
            .refresh_color_report = refreshInteractiveColorReport,
        }) catch {
            try sh.host.writeAll(.stderr, "rush: editor error\n");
            return 2;
        };
        switch (line_result) {
            .submitted => |line| {
                defer allocator.free(line);

                try terminal.leaveEditorMode();

                const src: shell.source.Source = .{
                    .id = source_id,
                    .kind = .interactive,
                    .name = "interactive",
                    .text = line,
                };
                source_id +%= 1;

                const started_at = unixTimestamp(io);
                const evaluated = sh.evalSource(src) catch {
                    try sh.host.writeAll(.stderr, "rush: shell error\n");
                    terminal.finishSemanticCommand(2) catch {};
                    try terminal.enterEditorMode();
                    continue;
                };
                const duration_ms = @max(unixTimestamp(io) - started_at, 0) * 1000;
                last_command_duration_ms = duration_ms;
                history_service.addCommand(io, line, evaluated.status, started_at, duration_ms) catch {};
                terminal.finishSemanticCommand(evaluated.status) catch {};

                switch (evaluated.flow) {
                    .exit => |status| return shell.eval.runExitTrap(&sh, status) catch {
                        try sh.host.writeAll(.stderr, "rush: shell error\n");
                        return 2;
                    },
                    else => try terminal.enterEditorMode(),
                }
            },
            .canceled, .interrupted => continue,
            .eof => {
                try terminal.leaveEditorMode();
                return shell.eval.runExitTrap(&sh, sh.state.last_status) catch {
                    try sh.host.writeAll(.stderr, "rush: shell error\n");
                    return 2;
                };
            },
        }
    }
}

fn runPromptedStdin(
    allocator: std.mem.Allocator,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
) !u8 {
    while (true) {
        const prompt_text = try promptedStdinPrompt(allocator, sh);
        defer allocator.free(prompt_text);
        try sh.host.writeAll(.stderr, prompt_text);

        const line = try readInteractiveStdinLine(allocator, sh) orelse {
            return shell.eval.runExitTrap(sh, sh.state.last_status) catch {
                try sh.host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            };
        };
        defer allocator.free(line);

        const src: shell.source.Source = .{
            .id = source_id.*,
            .kind = .interactive,
            .name = "interactive",
            .text = line,
        };
        source_id.* +%= 1;

        const evaluated = sh.evalSource(src) catch {
            try sh.host.writeAll(.stderr, "rush: shell error\n");
            continue;
        };
        switch (evaluated.flow) {
            .exit => |status| return shell.eval.runExitTrap(sh, status) catch {
                try sh.host.writeAll(.stderr, "rush: shell error\n");
                return 2;
            },
            else => {},
        }
    }
}

fn readInteractiveStdinLine(allocator: std.mem.Allocator, sh: *RushShell) !?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try sh.host.read(.stdin, &byte);
        if (read_len == 0) {
            if (line.items.len == 0) return null;
            return try line.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
        try line.append(allocator, byte[0]);
    }
}

fn sourceStartup(
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    login: bool,
    source_default_config: bool,
) !?u8 {
    if (source_default_config) {
        if (try sourceStartupText(sh, source_id, "default_config", default_config)) |status| return status;
    }

    if (envValue(sh.env, "ENV")) |env_path| {
        if (try sourceStartupFileIfExists(sh, source_id, env_path)) |status| return status;
    }

    if (login) {
        const system_profile = try std.fs.path.join(
            sh.allocator,
            &.{ build_config.sysconfdir, "rush", "profile.rush" },
        );
        defer sh.allocator.free(system_profile);
        if (try sourceStartupFileIfExists(sh, source_id, system_profile)) |status| return status;

        const user_profile = try userConfigPath(sh.allocator, sh.env, "profile.rush");
        defer if (user_profile) |path| sh.allocator.free(path);
        if (user_profile) |path| {
            if (try sourceStartupFileIfExists(sh, source_id, path)) |status| return status;
        }
    }

    const system_config = try std.fs.path.join(sh.allocator, &.{ build_config.sysconfdir, "rush", "config.rush" });
    defer sh.allocator.free(system_config);
    if (try sourceStartupFileIfExists(sh, source_id, system_config)) |status| return status;

    const user_config = try userConfigPath(sh.allocator, sh.env, "config.rush");
    defer if (user_config) |path| sh.allocator.free(path);
    if (user_config) |path| {
        if (try sourceStartupFileIfExists(sh, source_id, path)) |status| return status;
    }

    return null;
}

fn sourceStartupFileIfExists(
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    path: []const u8,
) !?u8 {
    const path_z = try sh.allocator.dupeZ(u8, path);
    defer sh.allocator.free(path_z);
    if (!sh.host.fileAccessZ(path_z, .read)) return null;

    const text = file_util.readFileAlloc(sh.allocator, &sh.host, path) catch {
        const message = try std.fmt.allocPrint(sh.scratchAllocator(), "rush: cannot read {s}\n", .{path});
        try sh.host.writeAll(.stderr, message);
        return null;
    };
    defer sh.allocator.free(text);
    return sourceStartupText(sh, source_id, path, text);
}

fn sourceStartupText(
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    name: []const u8,
    text: []const u8,
) !?u8 {
    const src: shell.source.Source = .{
        .id = source_id.*,
        .kind = .sourced_file,
        .name = name,
        .text = text,
    };
    source_id.* +%= 1;

    const evaluated = sh.evalSource(src) catch {
        const message = try std.fmt.allocPrint(sh.scratchAllocator(), "rush: error while sourcing {s}\n", .{name});
        try sh.host.writeAll(.stderr, message);
        return null;
    };
    return switch (evaluated.flow) {
        .exit => |status| shell.eval.runExitTrap(sh, status) catch 2,
        else => null,
    };
}

fn userConfigPath(allocator: std.mem.Allocator, env: []const [*:0]const u8, file_name: []const u8) !?[]const u8 {
    if (envValue(env, "XDG_CONFIG_HOME")) |xdg_config_home| {
        if (xdg_config_home.len != 0) return try std.fs.path.join(allocator, &.{ xdg_config_home, "rush", file_name });
    }

    const home = envValue(env, "HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home, ".config", "rush", file_name });
}

fn prompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "rush> ");
}

fn promptedStdinPrompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "$ ");
}

fn expandRushAbbreviation(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    append_space: bool,
) !?editor.completion.Edit {
    const sh: *RushShell = @ptrCast(@alignCast(context));
    return extensions.rush.expandAbbreviation(&sh.extensions, allocator, source, cursor, append_space);
}

fn refreshInteractiveStyle(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    scheme: editor.driver.ColorScheme,
) !editor_render.UiTheme {
    _ = allocator;
    _ = io;
    const sh: *RushShell = @ptrCast(@alignCast(context));
    try sh.state.putVariable(.{ .name = "rush_color_scheme", .value = colorSchemeName(scheme) });
    try runStyleFunction(sh);
    return interactiveUiTheme(sh.state);
}

fn refreshInteractiveColorReport(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    report: editor.driver.ColorReport,
) !editor_render.UiTheme {
    _ = allocator;
    _ = io;
    const sh: *RushShell = @ptrCast(@alignCast(context));
    const variable = colorReportVariable(report) orelse return interactiveUiTheme(sh.state);
    var value_buffer: [8]u8 = undefined;
    const value = try std.fmt.bufPrint(
        &value_buffer,
        "#{x:0>2}{x:0>2}{x:0>2}",
        .{ report.value[0], report.value[1], report.value[2] },
    );
    try sh.state.putVariable(.{ .name = variable, .value = value });
    try runStyleFunction(sh);
    return interactiveUiTheme(sh.state);
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

fn interactiveUiTheme(state: shell.state.State) editor_render.UiTheme {
    var theme: editor_render.UiTheme = .{};
    applyUiStyleVariable(state, &theme.completion_selected, "rush_style_completion_selected");
    applyUiStyleVariable(state, &theme.completion_command, "rush_style_completion_command");
    applyUiStyleVariable(state, &theme.completion_builtin, "rush_style_completion_builtin");
    applyUiStyleVariable(state, &theme.completion_subcommand, "rush_style_completion_subcommand");
    applyUiStyleVariable(state, &theme.completion_plain, "rush_style_completion_plain");
    applyUiStyleVariable(state, &theme.completion_directory, "rush_style_completion_directory");
    applyUiStyleVariable(state, &theme.completion_option, "rush_style_completion_option");
    applyUiStyleVariable(state, &theme.completion_variable, "rush_style_completion_variable");
    applyUiStyleVariable(state, &theme.completion_function, "rush_style_completion_function");
    applyUiStyleVariable(state, &theme.completion_file, "rush_style_completion_file");
    applyUiStyleVariable(state, &theme.completion_description, "rush_style_completion_description");
    applyUiStyleVariable(state, &theme.completion_summary, "rush_style_completion_summary");
    applyUiStyleVariable(state, &theme.completion_flash, "rush_style_completion_flash");
    applyUiStyleVariable(state, &theme.history_match, "rush_style_history_match");
    applyUiStyleVariable(state, &theme.autosuggestion, "rush_style_autosuggestion");
    applyUiStyleVariable(state, &theme.diagnostic_error, "rush_style_diagnostic_error");
    return theme;
}

fn applyUiStyleVariable(state: shell.state.State, style: *editor_render.UiStyle, name: []const u8) void {
    const variable = state.getVariable(name) orelse return;
    style.* = editor_render.parseUiStyle(variable.value) orelse style.*;
}

fn historyPath(allocator: std.mem.Allocator, env: []const [*:0]const u8) !?[]const u8 {
    if (envValue(env, "XDG_STATE_HOME")) |xdg_state_home| {
        if (xdg_state_home.len != 0) return try std.fs.path.join(allocator, &.{
            xdg_state_home,
            "rush",
            "history.sqlite",
        });
    }
    const home = envValue(env, "HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home, ".local", "state", "rush", "history.sqlite" });
}

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn envValue(env: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len != 0);
    for (env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

test "interactive style refresh runs rush_style with color scheme" {
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

    const theme = try refreshInteractiveStyle(&sh, std.testing.allocator, std.testing.io, .light);

    try std.testing.expectEqualStrings("light", sh.state.getVariable("rush_color_scheme").?.value);
    try std.testing.expectEqual(editor_render.parseUiColor("red").?, theme.history_match.fg.?);
    try std.testing.expect(theme.history_match.bold);
}

test "interactive color reports update rush color variables" {
    var sh = RushShell.init(std.testing.allocator, host.RealHost{}, .{});
    defer sh.deinit();

    const src: shell.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "test",
        .text = "rush_style() { rush_style_completion_directory=\"fg=$rush_color_blue\"; }",
    };
    _ = try sh.evalSource(src);

    const theme = try refreshInteractiveColorReport(
        &sh,
        std.testing.allocator,
        std.testing.io,
        .{ .kind = .{ .index = 4 }, .value = .{ 0x01, 0x23, 0x45 } },
    );

    try std.testing.expectEqualStrings("#012345", sh.state.getVariable("rush_color_blue").?.value);
    try std.testing.expectEqual(editor_render.parseUiColor("#012345").?, theme.completion_directory.fg.?);
}

test {
    std.testing.refAllDecls(@This());
}
