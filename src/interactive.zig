//! Interactive Rush session orchestration.

const std = @import("std");

const editor = @import("editor.zig");
const extensions = @import("extensions.zig");
const history = @import("history.zig");
const host = @import("host.zig");
const interactive_style = @import("interactive/style.zig");
const startup = @import("interactive/startup.zig");
const shell = @import("shell.zig");

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
    if (try startup.source(&sh, &source_id, options.login, !prompted_stdin)) |status| return status;

    var command_history = history.History.init(allocator);
    defer command_history.deinit();
    if (try startup.historyPath(allocator, env)) |path| {
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

    var session: InteractiveSession = .{
        .allocator = allocator,
        .io = io,
        .sh = &sh,
        .source_id = &source_id,
        .command_history = &command_history,
        .history_service = &history_service,
    };
    return session.runTerminal();
}

const InteractiveSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sh: *RushShell,
    source_id: *shell.source.SourceId,
    command_history: *history.History,
    history_service: *history.InteractiveHistoryService,
    last_command_duration_ms: ?i64 = null,

    fn runTerminal(self: *InteractiveSession) !u8 {
        var terminal = editor.driver.TerminalSession.init(self.allocator, self.io) catch {
            try self.sh.host.writeAll(.stderr, "rush: cannot initialize terminal\n");
            return 2;
        };
        defer terminal.deinit();

        while (true) {
            const line_result = self.readLine(&terminal) catch |err| switch (err) {
                error.EditorFailure => return 2,
                else => return err,
            };
            switch (line_result) {
                .submitted => |line| {
                    defer self.allocator.free(line);
                    if (try self.evaluateSubmittedLine(&terminal, line)) |status| return status;
                },
                .canceled, .interrupted => continue,
                .eof => {
                    try terminal.leaveEditorMode();
                    return self.exitWithLastStatus();
                },
            }
        }
    }

    const ReadLineError = error{EditorFailure} || error{OutOfMemory};

    fn readLine(self: *InteractiveSession, terminal: *editor.driver.TerminalSession) ReadLineError!editor.driver.ReadLineResult {
        const prompt_text = extensions.rush.renderPrompt(
            self.allocator,
            self.sh,
            self.sh.state.last_status,
            self.last_command_duration_ms,
        ) catch try prompt(self.allocator, self.sh);
        defer self.allocator.free(prompt_text);

        const current_cwd = self.sh.host.currentDir(self.allocator) catch try self.allocator.dupe(u8, "");
        defer self.allocator.free(current_cwd);
        self.command_history.current_cwd = current_cwd;

        return terminal.readLine(.{
            .prompt = prompt_text,
            .history = self.history_service.lineEditorView(self.io),
            .completion_context = self.sh,
            .expand_abbreviation = expandRushAbbreviation,
            .theme = interactive_style.theme(self.sh.state),
            .style_context = self.sh,
            .refresh_style = interactive_style.refreshStyle,
            .refresh_color_report = interactive_style.refreshColorReport,
        }) catch {
            self.sh.host.writeAll(.stderr, "rush: editor error\n") catch {};
            return error.EditorFailure;
        };
    }

    fn evaluateSubmittedLine(
        self: *InteractiveSession,
        terminal: *editor.driver.TerminalSession,
        line: []const u8,
    ) !?u8 {
        try terminal.leaveEditorMode();

        const src: shell.source.Source = .{
            .id = self.source_id.*,
            .kind = .interactive,
            .name = "interactive",
            .text = line,
        };
        self.source_id.* +%= 1;

        const started_at = unixTimestamp(self.io);
        const evaluated = self.sh.evalSource(src) catch {
            self.sh.state.last_status = 2;
            try self.sh.host.writeAll(.stderr, "rush: shell error\n");
            terminal.finishSemanticCommand(2) catch {};
            try terminal.enterEditorMode();
            return null;
        };
        const duration_ms = @max(unixTimestamp(self.io) - started_at, 0) * 1000;
        self.last_command_duration_ms = duration_ms;
        self.history_service.addCommand(self.io, line, evaluated.status, started_at, duration_ms) catch {};
        terminal.finishSemanticCommand(evaluated.status) catch {};

        switch (evaluated.flow) {
            .exit => |status| return self.exit(status),
            else => {
                try terminal.enterEditorMode();
                return null;
            },
        }
    }

    fn exitWithLastStatus(self: *InteractiveSession) u8 {
        return self.exit(self.sh.state.last_status);
    }

    fn exit(self: *InteractiveSession, status: u8) u8 {
        return shell.eval.runExitTrap(self.sh, status) catch {
            self.sh.host.writeAll(.stderr, "rush: shell error\n") catch {};
            return 2;
        };
    }
};

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
            sh.state.last_status = 2;
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

fn prompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (startup.envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, "rush> ");
}

fn promptedStdinPrompt(allocator: std.mem.Allocator, sh: *RushShell) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    if (startup.envValue(sh.env, "PS1")) |value| return allocator.dupe(u8, value);
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

fn unixTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

test {
    std.testing.refAllDecls(@This());
}
