//! Interactive startup file and configuration sourcing.

const std = @import("std");
const build_config = @import("build_config");

const compat = @import("../shell/compat.zig");
const runner = @import("../runner.zig");
const runtime = @import("../runtime.zig");
const shell = @import("../shell.zig");

const system_profile_path = build_config.sysconfdir ++ "/rush/profile.rush";
const system_config_path = build_config.sysconfdir ++ "/rush/config.rush";
const embedded_config = @embedFile("default_config");
const embedded_config_path = "embedded:config.rush";

pub const Options = struct {
    arg_zero: []const u8 = "rush",
    login: bool = false,
    features: compat.Features = .{},
    shell_options: shell.ShellOptions = .{},
    monitor_option_explicit: bool = false,
    positionals: []const []const u8 = &.{},
};

const OutputStream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: OutputStream, bytes: []const u8) !void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn setShellOptions(shell_options: *shell.ShellOptions, monitor_option_explicit: bool, stdin_is_tty: bool) void {
    if (stdin_is_tty and !monitor_option_explicit) shell_options.monitor = true;
    shell_options.noexec = false;
}

pub fn sourceDefaultConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    arg_zero: []const u8,
    features: compat.Features,
) !runner.CommandResult {
    return runner.runShellStateScript(
        allocator,
        io,
        shell_state,
        embedded_config,
        embedded_config_path,
        arg_zero,
        features,
        .capture,
    );
}

const ConfigService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    arg_zero: []const u8 = "rush",
    features: compat.Features = .{},

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        shell_state: *shell.ShellState,
        arg_zero: []const u8,
        features: compat.Features,
    ) ConfigService {
        shell_state.validate();
        std.debug.assert(shell_state.scope == .current_shell);
        return .{
            .allocator = allocator,
            .io = io,
            .shell_state = shell_state,
            .arg_zero = arg_zero,
            .features = features,
        };
    }

    fn load(self: ConfigService, options: Options) !void {
        try self.sourceScript(embedded_config, embedded_config_path);
        if (self.pendingExit() != null) return;

        if (self.getEnv("ENV")) |env_path| {
            if (env_path.len != 0) {
                const expanded_env_path = try self.expandParametersScalar(env_path, options.features);
                defer self.allocator.free(expanded_env_path);
                if (expanded_env_path.len != 0) {
                    try self.sourceOptional(expanded_env_path);
                    if (self.pendingExit() != null) return;
                }
            }
        }

        if (options.login) {
            try self.sourceOptional(system_profile_path);
            if (self.pendingExit() != null) return;
            const user_profile_path = try self.userStartupPath("profile.rush");
            defer if (user_profile_path) |path| self.allocator.free(path);
            if (user_profile_path) |path| {
                try self.sourceOptional(path);
                if (self.pendingExit() != null) return;
            }
        }

        try self.sourceOptional(system_config_path);
        if (self.pendingExit() != null) return;
        const user_path = try self.userStartupPath("config.rush");
        defer if (user_path) |path| self.allocator.free(path);
        if (user_path) |path| {
            try self.sourceOptional(path);
            if (self.pendingExit() != null) return;
        }
    }

    fn sourceOptional(self: ConfigService, path: []const u8) !void {
        const contents = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => {
                try writeConfigReadWarning(self.io, path, err);
                return;
            },
        };
        defer self.allocator.free(contents);

        try self.sourceScript(contents, path);
    }

    fn sourceScript(self: ConfigService, contents: []const u8, source_path: []const u8) !void {
        var result = try runner.runShellStateScript(
            self.allocator,
            self.io,
            self.shell_state,
            contents,
            source_path,
            self.arg_zero,
            self.features,
            .capture,
        );
        defer result.deinit();
        if (result.stdout.len != 0) try writeAll(self.io, .stdout, result.stdout);
        if (result.stderr.len != 0) try writeAll(self.io, .stderr, result.stderr);
    }

    fn userConfigPath(self: ConfigService) !?[]const u8 {
        return self.userStartupPath("config.rush");
    }

    fn userProfilePath(self: ConfigService) !?[]const u8 {
        return self.userStartupPath("profile.rush");
    }

    fn userStartupPath(self: ConfigService, file_name: []const u8) !?[]const u8 {
        return userStartupPathForShellState(self.allocator, self.shell_state.*, file_name);
    }

    fn userStartupPathForShellState(
        allocator: std.mem.Allocator,
        shell_state: shell.ShellState,
        file_name: []const u8,
    ) !?[]const u8 {
        shell_state.validate();
        if (shell_state.getVariable("XDG_CONFIG_HOME")) |xdg_config_home| {
            if (xdg_config_home.value.len != 0) {
                return try std.fs.path.join(allocator, &.{ xdg_config_home.value, "rush", file_name });
            }
        }
        if (shell_state.getVariable("HOME")) |home| {
            if (home.value.len != 0) {
                return try std.fs.path.join(allocator, &.{ home.value, ".config", "rush", file_name });
            }
        }
        return null;
    }

    fn getEnv(self: ConfigService, name: []const u8) ?[]const u8 {
        self.shell_state.validate();
        return if (self.shell_state.getVariable(name)) |variable| variable.value else null;
    }

    fn pendingExit(self: ConfigService) ?shell.ExitStatus {
        self.shell_state.validate();
        return self.shell_state.pending_exit;
    }

    fn expandParametersScalar(self: ConfigService, text: []const u8, features: compat.Features) ![]const u8 {
        self.shell_state.validate();
        var adapter = runtime.PosixAdapter.init(self.io);
        var expansion = shell.ShellExpansion.init(self.allocator, .{
            .shell_state = self.shell_state,
            .eval_context = shell.EvalContext.init(.{
                .target = .current_shell,
                .source = .interactive,
                .interactive = true,
            }),
            .fs_port = runtime.posixPorts(&adapter).fs,
            .features = features,
            .arg_zero = self.arg_zero,
        });
        defer expansion.deinit();
        return expansion.expandParametersScalar(text);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, io: std.Io, shell_state: *shell.ShellState, options: Options) !void {
    try ConfigService.init(allocator, io, shell_state, options.arg_zero, options.features).load(options);
}

pub fn sourceOptionalConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    path: []const u8,
    arg_zero: []const u8,
) !void {
    try ConfigService.init(allocator, io, shell_state, arg_zero, .{}).sourceOptional(path);
}

fn writeConfigReadWarning(io: std.Io, path: []const u8, err: anyerror) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    defer writer.interface.flush() catch {};
    try writer.interface.print(
        "rush: warning: cannot read {s}: {s}; skipping\n",
        .{ path, configReadErrorMessage(err) },
    );
}

fn configReadErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        else => @errorName(err),
    };
}

pub fn sourceConfigScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    shell_state: *shell.ShellState,
    contents: []const u8,
    source_path: []const u8,
    arg_zero: []const u8,
) !void {
    try ConfigService.init(allocator, io, shell_state, arg_zero, .{}).sourceScript(contents, source_path);
}

extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup(fd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;

const StderrGuard = struct {
    saved_fd: c_int,

    fn replaceWith(file: std.Io.File) !StderrGuard {
        const saved_fd = dup(std.Io.File.stderr().handle);
        if (saved_fd < 0) return error.SkipZigTest;
        errdefer _ = close(saved_fd);
        if (dup2(file.handle, std.Io.File.stderr().handle) < 0) return error.SkipZigTest;
        return .{ .saved_fd = saved_fd };
    }

    fn restore(self: *StderrGuard) void {
        _ = dup2(self.saved_fd, std.Io.File.stderr().handle);
        _ = close(self.saved_fd);
        self.* = undefined;
    }
};

fn sourceOptionalConfigCapturingStderr(
    allocator: std.mem.Allocator,
    shell_state: *shell.ShellState,
    path: []const u8,
    stderr_path: []const u8,
) ![]u8 {
    var stderr_file = try std.Io.Dir.cwd().createFile(std.testing.io, stderr_path, .{ .truncate = true });
    var stderr_file_open = true;
    defer if (stderr_file_open) stderr_file.close(std.testing.io);

    var stderr_guard = try StderrGuard.replaceWith(stderr_file);
    var stderr_guard_active = true;
    defer if (stderr_guard_active) stderr_guard.restore();

    try sourceOptionalConfig(allocator, std.testing.io, shell_state, path, "rush");

    stderr_guard.restore();
    stderr_guard_active = false;
    stderr_file.close(std.testing.io);
    stderr_file_open = false;

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, stderr_path, allocator, .limited(4096));
}

test "interactive config service sources simple config through semantic ShellState" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    try sourceConfigScript(std.testing.allocator, std.testing.io, &shell_state,
        \\RUSH_SEMANTIC_CONFIG=loaded
        \\RUSH_SEMANTIC_CONFIG_SECOND=ok
    , "semantic-config-test.rush", "rush");
    try std.testing.expectEqualStrings("loaded", shell_state.getVariable("RUSH_SEMANTIC_CONFIG").?.value);
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("RUSH_SEMANTIC_CONFIG_SECOND").?.value);
}
test "interactive startup initializes prompt variables and sources expanded ENV" {
    const env_path = "rush-test-env-startup.rush";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env_path, .data = "ENV_LOADED=ok\nPS1='env> '\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, env_path) catch {};

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const env_value = try std.fmt.allocPrint(std.testing.allocator, "$HOME/{s}", .{env_path});
    defer std.testing.allocator.free(env_value);

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("HOME", cwd, .{ .exported = true });
    try shell_state.putVariable("ENV", env_value, .{ .exported = true });

    try loadConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("ok", shell_state.getVariable("ENV_LOADED").?.value);
    // Embedded default config provides PS2; $ENV overrides the embedded PS1 default.
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
    try std.testing.expectEqualStrings("env> ", shell_state.getVariable("PS1").?.value);
}
test "interactive startup warns and skips user config path directory" {
    const root = "rush-test-config-directory-startup";
    try std.Io.Dir.cwd().deleteTree(std.testing.io, root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root ++ "/rush/config.rush");

    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();

    const stderr = try sourceOptionalConfigCapturingStderr(
        std.testing.allocator,
        &shell_state,
        root ++ "/rush/config.rush",
        root ++ "/stderr",
    );
    defer std.testing.allocator.free(stderr);

    try std.testing.expectEqualStrings(
        "rush: warning: cannot read " ++ root ++ "/rush/config.rush: is a directory; skipping\n",
        stderr,
    );
}
test "embedded default config sets prompt defaults without clobbering inherited values" {
    var shell_state = shell.ShellState.init(std.testing.allocator);
    defer shell_state.deinit();
    try shell_state.putVariable("PS1", "inherited> ", .{});

    try loadConfig(std.testing.allocator, std.testing.io, &shell_state, .{ .arg_zero = "rush" });
    try std.testing.expectEqualStrings("inherited> ", shell_state.getVariable("PS1").?.value);
    try std.testing.expectEqualStrings("> ", shell_state.getVariable("PS2").?.value);
}
