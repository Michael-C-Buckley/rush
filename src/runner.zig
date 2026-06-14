//! Script runner public types and result formatting helpers.

const std = @import("std");

const compat = @import("compat.zig");
const cli_invocation = @import("invocation.zig");
const parser = @import("parser.zig");
const runtime = @import("runtime.zig");
const shell = @import("shell.zig");

pub const Options = struct {
    io: ?std.Io = null,
    allow_external: bool = true,
    features: compat.Features = .{},
    external_stdio: runtime.ExternalStdio = .capture,
    interactive: bool = false,
    arg_zero: []const u8 = "rush",
    source_path: ?[]const u8 = null,
    stdin_script_file: ?std.Io.File = null,
    stdin_script_source_offset: usize = 0,
};

pub fn invocationContext(options: Options) shell.InvocationContext {
    return shell.InvocationContext.init(.{
        .features = options.features,
        .arg_zero = options.arg_zero,
        .source = inputSource(options),
        .interactive = options.interactive,
        .stdin_script_file = options.stdin_script_file,
        .stdin_script_source_offset = options.stdin_script_source_offset,
    });
}

pub fn inputSource(options: Options) shell.InputSource {
    if (options.source_path != null) return .script_file;
    if (options.stdin_script_file != null) return .standard_input;
    return .command_string;
}

pub const LoadedInvocationScript = struct {
    allocator: std.mem.Allocator,
    script: []const u8,
    options: Options,
    owns_script: bool,

    pub fn deinit(self: *LoadedInvocationScript) void {
        if (self.owns_script) self.allocator.free(self.script);
        self.* = undefined;
    }
};

pub fn loadInvocationScript(allocator: std.mem.Allocator, io: std.Io, invocation: cli_invocation.ShellInvocation, external_stdio: runtime.ExternalStdio) !LoadedInvocationScript {
    var options: Options = .{
        .io = io,
        .allow_external = true,
        .features = invocation.features,
        .external_stdio = external_stdio,
        .arg_zero = invocation.arg_zero,
    };
    switch (invocation.kind) {
        .command_string => return .{
            .allocator = allocator,
            .script = invocation.source,
            .options = options,
            .owns_script = false,
        },
        .script_file => {
            const script = try std.Io.Dir.cwd().readFileAlloc(io, invocation.source, allocator, .unlimited);
            options.source_path = invocation.source;
            return .{
                .allocator = allocator,
                .script = script,
                .options = options,
                .owns_script = true,
            };
        },
        .standard_input => {
            const script = try readStandardInputScript(allocator, io);
            options.stdin_script_file = std.Io.File.stdin();
            return .{
                .allocator = allocator,
                .script = script,
                .options = options,
                .owns_script = true,
            };
        },
    }
}

fn readStandardInputScript(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

pub const CommandResult = struct {
    allocator: std.mem.Allocator,
    status: shell.ExitStatus,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn empty(allocator: std.mem.Allocator, status: shell.ExitStatus) !CommandResult {
    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try allocator.alloc(u8, 0);
    return .{ .allocator = allocator, .status = status, .stdout = stdout, .stderr = stderr };
}

pub fn unsupported(allocator: std.mem.Allocator, message: []const u8) !CommandResult {
    std.debug.assert(message.len != 0);
    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try std.fmt.allocPrint(allocator, "{s}\n", .{message});
    return .{ .allocator = allocator, .status = 2, .stdout = stdout, .stderr = stderr };
}

pub fn parseDiagnostics(allocator: std.mem.Allocator, script: []const u8, diagnostics: []const parser.Diagnostic) !CommandResult {
    var stderr_buffer: std.ArrayList(u8) = .empty;
    defer stderr_buffer.deinit(allocator);

    for (diagnostics) |diagnostic| {
        const line = try std.fmt.allocPrint(allocator, "rush: {s}: {s}\n", .{
            @tagName(diagnostic.kind),
            diagnostic.message,
        });
        defer allocator.free(line);
        try stderr_buffer.appendSlice(allocator, line);
        try appendDiagnosticSource(allocator, &stderr_buffer, script, diagnostic.span);
    }

    const stdout = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout);
    const stderr = try stderr_buffer.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .status = 2, .stdout = stdout, .stderr = stderr };
}

fn appendDiagnosticSource(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, span: parser.Span) !void {
    const line_start = diagnosticLineStart(source, span.start);
    const line_end = diagnosticLineEnd(source, span.start);
    const line = source[line_start..line_end];
    const caret_start = span.start - line_start;
    const caret_end = @max(caret_start + 1, @min(span.end, line_end) - line_start);

    try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "  ");
    try out.appendNTimes(allocator, ' ', caret_start);
    try out.appendNTimes(allocator, '^', caret_end - caret_start);
    try out.append(allocator, '\n');
}

fn diagnosticLineStart(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index > 0 and source[index - 1] != '\n') index -= 1;
    return index;
}

fn diagnosticLineEnd(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index < source.len and source[index] != '\n') index += 1;
    return index;
}
