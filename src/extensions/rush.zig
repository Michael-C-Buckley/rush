//! Rush-specific shell extensions.

const std = @import("std");

const completion = @import("../editor/completion.zig");
const editor_render = @import("../editor/render.zig");
const host = @import("../host.zig");
const shell = @import("../shell.zig");

const builtin = shell.builtin;
const result = shell.result;

pub const definitions = [_]builtin.Definition{
    builtin.extensionDefinition("abbr", .abbr),
    builtin.extensionDefinition("color", .color),
    builtin.extensionDefinition("event", .event),
    builtin.extensionDefinition("prompt", .prompt),
    builtin.extensionDefinition("prompt_async", .prompt_async),
    builtin.extensionDefinition("prompt_duration", .prompt_duration),
    builtin.extensionDefinition("prompt_pwd", .prompt_pwd),
    builtin.extensionDefinition("rush_env", .rush_env),
};

pub const registry: builtin.Registry = .{
    .extensions = &definitions,
    .ExtensionState = State,
};

pub const EventHandler = struct {
    event: []const u8,
    name: []const u8,
    action: []const u8,
    every_ms: ?u64 = null,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    abbreviations: std.StringHashMapUnmanaged([]const u8) = .empty,
    event_handlers: std.StringHashMapUnmanaged(EventHandler) = .empty,
    prompt_buffer: std.ArrayListUnmanaged(u8) = .empty,
    building_prompt: bool = false,
    previous_duration_ms: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        var abbreviation_iterator = self.abbreviations.iterator();
        while (abbreviation_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.abbreviations.deinit(self.allocator);
        var event_iterator = self.event_handlers.iterator();
        while (event_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.event);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.action);
        }
        self.event_handlers.deinit(self.allocator);
        self.prompt_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn eval(
        self: *State,
        sh: anytype,
        definition: builtin.Definition,
        args: []const []const u8,
    ) !result.EvalResult {
        return switch (definition.id) {
            .abbr => evalAbbr(self, sh, args),
            .color => evalColor(sh, args),
            .event => evalEvent(self, sh, args),
            .prompt => evalPrompt(self, args),
            .prompt_async => evalPromptAsync(sh, args),
            .prompt_duration => evalPromptDuration(self, sh, args),
            .prompt_pwd => evalPromptPwd(sh, args),
            .rush_env => evalRushEnv(sh, args),
            else => .{ .status = 127 },
        };
    }

    pub fn putAbbreviation(self: *State, name: []const u8, replacement: []const u8) !void {
        std.debug.assert(name.len != 0);
        const owned_replacement = try self.allocator.dupe(u8, replacement);
        errdefer self.allocator.free(owned_replacement);

        if (self.abbreviations.getPtr(name)) |existing| {
            self.allocator.free(existing.*);
            existing.* = owned_replacement;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.abbreviations.put(self.allocator, owned_name, owned_replacement);
    }

    pub fn getAbbreviation(self: State, name: []const u8) ?[]const u8 {
        if (name.len == 0) return null;
        return self.abbreviations.get(name);
    }

    pub fn removeAbbreviation(self: *State, name: []const u8) bool {
        if (name.len == 0) return false;
        if (self.abbreviations.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            return true;
        }
        return false;
    }

    fn putEventHandler(
        self: *State,
        event: []const u8,
        name: []const u8,
        action: []const u8,
        every_ms: ?u64,
    ) !void {
        std.debug.assert(event.len != 0);
        std.debug.assert(name.len != 0);
        std.debug.assert(action.len != 0);

        const key = try eventKey(self.allocator, event, name);
        errdefer self.allocator.free(key);
        const owned_event = try self.allocator.dupe(u8, event);
        errdefer self.allocator.free(owned_event);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_action = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(owned_action);

        if (self.event_handlers.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.event);
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.action);
        }
        try self.event_handlers.put(self.allocator, key, .{
            .event = owned_event,
            .name = owned_name,
            .action = owned_action,
            .every_ms = every_ms,
        });
    }

    fn removeEventHandler(self: *State, event: []const u8, name: []const u8) !bool {
        if (event.len == 0 or name.len == 0) return false;
        const key = try eventKey(self.allocator, event, name);
        defer self.allocator.free(key);
        if (self.event_handlers.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.event);
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.action);
            return true;
        }
        return false;
    }

    pub fn clearPrompt(self: *State) void {
        self.prompt_buffer.clearRetainingCapacity();
    }

    fn appendPrompt(self: *State, bytes: []const u8) !void {
        try self.prompt_buffer.appendSlice(self.allocator, bytes);
    }
};

fn evalAbbr(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1) return listAbbreviations(state, sh);
    if (std.mem.eql(u8, args[1], "--list")) {
        if (args.len != 2) return .{ .status = 2 };
        return listAbbreviations(state, sh);
    }
    if (std.mem.eql(u8, args[1], "--erase") or
        std.mem.eql(u8, args[1], "erase") or
        std.mem.eql(u8, args[1], "remove"))
    {
        if (args.len < 3) return .{ .status = 2 };
        var status: result.ExitStatus = 0;
        for (args[2..]) |name| {
            if (!state.removeAbbreviation(name)) status = 1;
        }
        return .{ .status = status };
    }
    if (args.len != 3 or !isAbbreviationName(args[1])) return .{ .status = 2 };
    try state.putAbbreviation(args[1], args[2]);
    return .{};
}

fn listAbbreviations(state: *State, sh: anytype) !result.EvalResult {
    var iterator = state.abbreviations.iterator();
    while (iterator.next()) |entry| {
        try sh.host.writeAll(.stdout, "abbr ");
        try sh.host.writeAll(.stdout, entry.key_ptr.*);
        try sh.host.writeAll(.stdout, " ");
        try writeShellSingleQuoted(sh, entry.value_ptr.*);
        try sh.host.writeAll(.stdout, "\n");
    }
    return .{};
}

fn isAbbreviationName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn writeShellSingleQuoted(sh: anytype, value: []const u8) !void {
    try sh.host.writeAll(.stdout, "'");
    for (value, 0..) |byte, index| {
        if (byte == '\'') {
            try sh.host.writeAll(.stdout, "'\\''");
        } else {
            try sh.host.writeAll(.stdout, value[index..][0..1]);
        }
    }
    try sh.host.writeAll(.stdout, "'");
}

fn evalEvent(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 1 or std.mem.eql(u8, args[1], "list")) return listEvents(state, sh, args[2..]);
    if (std.mem.eql(u8, args[1], "add")) return eventAdd(state, args[2..]);
    if (std.mem.eql(u8, args[1], "remove")) return eventRemove(state, args[2..]);
    return .{ .status = 2 };
}

fn eventAdd(state: *State, args: []const []const u8) !result.EvalResult {
    if (args.len < 3) return .{ .status = 2 };
    var every_ms: ?u64 = null;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--every")) {
            index += 1;
            if (index >= args.len) return .{ .status = 2 };
            every_ms = std.fmt.parseInt(u64, args[index], 10) catch return .{ .status = 2 };
        } else return .{ .status = 2 };
    }
    try state.putEventHandler(args[0], args[1], args[2], every_ms);
    return .{};
}

fn eventRemove(state: *State, args: []const []const u8) !result.EvalResult {
    if (args.len != 2) return .{ .status = 2 };
    _ = try state.removeEventHandler(args[0], args[1]);
    return .{};
}

fn listEvents(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    const filter = if (args.len == 0) null else args[0];
    var iterator = state.event_handlers.iterator();
    while (iterator.next()) |entry| {
        const handler = entry.value_ptr.*;
        if (filter) |event_name| if (!std.mem.eql(u8, handler.event, event_name)) continue;
        try sh.host.writeAll(.stdout, handler.event);
        try sh.host.writeAll(.stdout, "\t");
        try sh.host.writeAll(.stdout, handler.name);
        try sh.host.writeAll(.stdout, "\t");
        try sh.host.writeAll(.stdout, handler.action);
        try sh.host.writeAll(.stdout, "\n");
    }
    return .{};
}

fn evalPrompt(state: *State, args: []const []const u8) !result.EvalResult {
    if (args.len < 2) return .{ .status = 2 };
    if (std.mem.eql(u8, args[1], "async-pending")) return .{ .status = 1 };
    if (!state.building_prompt) return .{};
    if (std.mem.eql(u8, args[1], "text")) {
        if (args.len < 3) return .{ .status = 2 };
        try appendPromptText(state, args[2..]);
        return .{};
    }
    if (std.mem.eql(u8, args[1], "newline")) {
        if (args.len != 2) return .{ .status = 2 };
        try state.appendPrompt("\n");
        return .{};
    }
    if (std.mem.eql(u8, args[1], "segment")) {
        var style: editor_render.UiStyle = .{};
        var index: usize = 2;
        while (index < args.len) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--fg")) {
                index += 1;
                if (index >= args.len) return .{ .status = 2 };
                style.fg = editor_render.parseUiColor(args[index]) orelse return .{ .status = 2 };
                index += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--bg")) {
                index += 1;
                if (index >= args.len) return .{ .status = 2 };
                style.bg = editor_render.parseUiColor(args[index]) orelse return .{ .status = 2 };
                index += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--bold")) style.bold = true else if (std.mem.eql(u8, arg, "--dim")) style.dim = true else if (std.mem.eql(u8, arg, "--italic")) style.italic = true else if (std.mem.eql(u8, arg, "--underline")) style.ul = .single else if (std.mem.eql(u8, arg, "--reverse")) style.reverse = true else if (std.mem.eql(u8, arg, "--strikethrough")) style.strike = true else break;
            index += 1;
        }
        if (index >= args.len) return .{ .status = 2 };
        try appendStyledPromptText(state, style, args[index..]);
        return .{};
    }
    return .{ .status = 2 };
}

fn appendPromptText(state: *State, args: []const []const u8) !void {
    for (args, 0..) |arg, index| {
        if (index != 0) try state.appendPrompt(" ");
        try state.appendPrompt(arg);
    }
}

fn appendStyledPromptText(state: *State, style: editor_render.UiStyle, args: []const []const u8) !void {
    var styled: std.ArrayList(u8) = .empty;
    defer styled.deinit(state.allocator);
    try editor_render.appendUiStyleStart(state.allocator, &styled, style);
    for (args, 0..) |arg, index| {
        if (index != 0) try styled.append(state.allocator, ' ');
        try styled.appendSlice(state.allocator, arg);
    }
    try editor_render.appendUiStyleEnd(state.allocator, &styled, style);
    try state.appendPrompt(styled.items);
}

fn evalPromptAsync(sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len < 2) return .{ .status = 2 };
    var index: usize = 2;
    while (index < args.len and !std.mem.eql(u8, args[index], "--")) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--ttl")) index += 1;
        if (index >= args.len) return .{ .status = 2 };
    }
    if (index >= args.len or !std.mem.eql(u8, args[index], "--")) return .{ .status = 2 };
    index += 1;
    if (index >= args.len) return .{ .status = 2 };

    const ShellType = switch (@typeInfo(@TypeOf(sh))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(sh),
    };
    if (!@hasDecl(ShellType, "evalSourceNested")) return .{ .status = 1 };

    const command = try shellCommand(sh.scratchAllocator(), args[index..]);
    const src: shell.source.Source = .{ .id = 0, .kind = .command_string, .name = "prompt_async", .text = command };
    return sh.evalSourceNested(src);
}

fn evalPromptPwd(sh: anytype, args: []const []const u8) !result.EvalResult {
    const options = parsePromptPwdOptions(args) orelse return .{ .status = 2 };
    const HostType = switch (@typeInfo(@TypeOf(sh.host))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(sh.host),
    };
    if (!@hasDecl(HostType, "currentDir")) return .{ .status = 1 };
    const cwd = if (sh.state.getVariable("PWD")) |variable| variable.value else shellEnvValue(sh, "PWD") orelse try sh.host.currentDir(sh.scratchAllocator());
    const display = try formatPromptPwd(sh.scratchAllocator(), cwd, if (sh.state.getVariable("HOME")) |home| home.value else shellEnvValue(sh, "HOME"), options);
    try sh.host.writeAll(.stdout, display);
    try sh.host.writeAll(.stdout, "\n");
    return .{};
}

const PromptPwdOptions = struct {
    dir_length: ?usize = null,
    full_length_dirs: usize = 1,
};

fn parsePromptPwdOptions(args: []const []const u8) ?PromptPwdOptions {
    var options: PromptPwdOptions = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dir-length")) {
            index += 1;
            if (index >= args.len) return null;
            options.dir_length = std.fmt.parseInt(usize, args[index], 10) catch return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--full-length-dirs")) {
            index += 1;
            if (index >= args.len) return null;
            options.full_length_dirs = std.fmt.parseInt(usize, args[index], 10) catch return null;
            continue;
        }
        return null;
    }
    return options;
}

fn formatPromptPwd(allocator: std.mem.Allocator, cwd: []const u8, maybe_home: ?[]const u8, options: PromptPwdOptions) ![]const u8 {
    var display: []const u8 = cwd;
    if (maybe_home) |home| {
        if (home.len != 0 and std.mem.eql(u8, cwd, home)) {
            display = "~";
        } else if (home.len != 0 and std.mem.startsWith(u8, cwd, home) and cwd.len > home.len and cwd[home.len] == '/') {
            display = try std.mem.concat(allocator, u8, &.{ "~", cwd[home.len..] });
        }
    }
    const dir_length = options.dir_length orelse return allocator.dupe(u8, display);
    if (dir_length == 0) return allocator.dupe(u8, display);
    return abbreviatePromptPath(allocator, display, dir_length, options.full_length_dirs);
}

fn abbreviatePromptPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    dir_length: usize,
    full_length_dirs: usize,
) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var cursor: usize = 0;
    const prefix: []const u8 = if (std.mem.startsWith(u8, path, "~/")) prefix: {
        cursor = 2;
        break :prefix "~/";
    } else if (std.mem.eql(u8, path, "~")) {
        return allocator.dupe(u8, path);
    } else if (std.mem.startsWith(u8, path, "/")) prefix: {
        cursor = 1;
        break :prefix "/";
    } else "";

    while (cursor <= path.len) {
        const rest = path[cursor..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (slash != 0) try parts.append(allocator, rest[0..slash]);
        if (slash == rest.len) break;
        cursor += slash + 1;
    }
    if (parts.items.len <= full_length_dirs) return allocator.dupe(u8, path);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, prefix);
    for (parts.items, 0..) |part, index| {
        if (index != 0) try out.append(allocator, '/');
        if (index + full_length_dirs >= parts.items.len) {
            try out.appendSlice(allocator, part);
        } else {
            try out.appendSlice(allocator, part[0..@min(dir_length, part.len)]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn evalColor(sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len == 4 and std.mem.eql(u8, args[1], "dim")) {
        const color = parseRgb(args[2]) orelse return .{ .status = 2 };
        const percent = std.fmt.parseInt(u8, args[3], 10) catch return .{ .status = 2 };
        if (percent > 100) return .{ .status = 2 };
        try writeRgb(sh, blendRgb(color, .{ 0, 0, 0 }, percent));
        return .{};
    }
    if (args.len == 5 and std.mem.eql(u8, args[1], "blend")) {
        const lhs = parseRgb(args[2]) orelse return .{ .status = 2 };
        const rhs = parseRgb(args[3]) orelse return .{ .status = 2 };
        const percent = std.fmt.parseInt(u8, args[4], 10) catch return .{ .status = 2 };
        if (percent > 100) return .{ .status = 2 };
        try writeRgb(sh, blendRgb(lhs, rhs, percent));
        return .{};
    }
    return .{ .status = 2 };
}

fn evalPromptDuration(state: *State, sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len != 1) return .{ .status = 2 };
    const duration_ms = state.previous_duration_ms orelse return .{ .status = 1 };
    try sh.host.writeAll(.stdout, try std.fmt.allocPrint(sh.scratchAllocator(), "{d}ms\n", .{duration_ms}));
    return .{};
}

fn evalRushEnv(sh: anytype, args: []const []const u8) !result.EvalResult {
    if (args.len != 2) return .{ .status = 2 };
    const input = try readStdinAlloc(sh);
    defer sh.scratchAllocator().free(input);

    if (std.mem.eql(u8, args[1], "import-json")) return importJsonEnv(sh, input);
    if (std.mem.eql(u8, args[1], "import-sh")) return importShEnv(sh, input);
    return .{ .status = 2 };
}

fn readStdinAlloc(sh: anytype) ![]const u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(sh.scratchAllocator());
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_len = try sh.host.read(.stdin, &buffer);
        if (read_len == 0) break;
        try input.appendSlice(sh.scratchAllocator(), buffer[0..read_len]);
    }
    return input.toOwnedSlice(sh.scratchAllocator());
}

fn importJsonEnv(sh: anytype, input: []const u8) !result.EvalResult {
    var parsed = std.json.parseFromSlice(std.json.Value, sh.scratchAllocator(), input, .{
        .duplicate_field_behavior = .use_last,
    }) catch return .{ .status = 1 };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .status = 1 },
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (!isShellVariableName(entry.key_ptr.*)) return .{ .status = 1 };
        switch (entry.value_ptr.*) {
            .string => |value| if (!try putExportedEnv(sh, entry.key_ptr.*, value)) return .{ .status = 1 },
            .null => if (!removeEnv(sh, entry.key_ptr.*)) return .{ .status = 1 },
            else => return .{ .status = 1 },
        }
    }
    return .{};
}

fn importShEnv(sh: anytype, input: []const u8) !result.EvalResult {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            const assignment = std.mem.trim(u8, line[7..], " \t");
            const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return .{ .status = 1 };
            const name = assignment[0..equals];
            if (!isShellVariableName(name)) return .{ .status = 1 };
            const value = parseShellEnvValue(sh.scratchAllocator(), assignment[equals + 1 ..]) catch return .{ .status = 1 };
            defer sh.scratchAllocator().free(value);
            if (!try putExportedEnv(sh, name, value)) return .{ .status = 1 };
            continue;
        }
        if (std.mem.startsWith(u8, line, "unset ")) {
            const name = std.mem.trim(u8, line[6..], " \t");
            if (!isShellVariableName(name)) return .{ .status = 1 };
            if (!removeEnv(sh, name)) return .{ .status = 1 };
            continue;
        }
        return .{ .status = 1 };
    }
    return .{};
}

fn putExportedEnv(sh: anytype, name: []const u8, value: []const u8) !bool {
    sh.state.putVariable(.{ .name = name, .value = value, .exported = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadonlyVariable => return false,
    };
    return true;
}

fn removeEnv(sh: anytype, name: []const u8) bool {
    if (sh.state.getVariable(name)) |variable| {
        if (variable.readonly) return false;
        sh.state.removeVariable(name);
        return true;
    }
    if (sh.state.getVariableAttributes(name)) |attributes| {
        if (attributes.readonly) return false;
        sh.state.removeVariableAttributes(name);
    }
    return true;
}

fn parseShellEnvValue(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
        if (std.mem.indexOfScalar(u8, value[1 .. value.len - 1], '\'') != null) return error.InvalidEnvScript;
        return allocator.dupe(u8, value[1 .. value.len - 1]);
    }
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var index: usize = 1;
        while (index < value.len - 1) : (index += 1) {
            if (value[index] == '\\') {
                index += 1;
                if (index >= value.len - 1) return error.InvalidEnvScript;
            }
            try out.append(allocator, value[index]);
        }
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.indexOfAny(u8, value, " \t'\"`;$|&<>()") != null) return error.InvalidEnvScript;
    return allocator.dupe(u8, value);
}

fn isShellVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn writeRgb(sh: anytype, rgb: [3]u8) !void {
    try sh.host.writeAll(.stdout, try std.fmt.allocPrint(
        sh.scratchAllocator(),
        "#{x:0>2}{x:0>2}{x:0>2}\n",
        .{ rgb[0], rgb[1], rgb[2] },
    ));
}

pub fn renderPrompt(
    allocator: std.mem.Allocator,
    sh: anytype,
    previous_status: result.ExitStatus,
    previous_duration_ms: ?i64,
) ![]const u8 {
    if (sh.state.getFunction("rush_prompt") == null) return staticPrompt(allocator, sh);
    sh.extensions.clearPrompt();
    sh.extensions.building_prompt = true;
    sh.extensions.previous_duration_ms = previous_duration_ms;
    defer sh.extensions.building_prompt = false;
    defer sh.extensions.previous_duration_ms = null;

    const saved_status = sh.state.last_status;
    sh.state.last_status = previous_status;
    defer sh.state.last_status = saved_status;

    const src: shell.source.Source = .{ .id = 0, .kind = .command_string, .name = "prompt", .text = "rush_prompt" };
    const evaluated = sh.evalSourceNested(src) catch return staticPrompt(allocator, sh);
    if (evaluated.status != 0 or evaluated.flow != .normal or sh.extensions.prompt_buffer.items.len == 0) {
        return staticPrompt(allocator, sh);
    }
    return allocator.dupe(u8, sh.extensions.prompt_buffer.items);
}

fn staticPrompt(allocator: std.mem.Allocator, sh: anytype) ![]const u8 {
    if (sh.state.getVariable("PS1")) |variable| return allocator.dupe(u8, variable.value);
    return allocator.dupe(u8, "rush> ");
}

fn appendStyleStart(state: *State, fg: ?[]const u8, bg: ?[]const u8) !void {
    if (fg == null and bg == null) return;
    try state.appendPrompt("\x1b[");
    var needs_separator = false;
    if (fg) |color| {
        try appendColorCode(state, false, color);
        needs_separator = true;
    }
    if (bg) |color| {
        if (needs_separator) try state.appendPrompt(";");
        try appendColorCode(state, true, color);
    }
    try state.appendPrompt("m");
}

fn appendColorCode(state: *State, background: bool, color: []const u8) !void {
    if (parseRgb(color)) |rgb| {
        const prefix = if (background) "48" else "38";
        try appendPromptPrint(state, "{s};2;{d};{d};{d}", .{ prefix, rgb[0], rgb[1], rgb[2] });
        return;
    }
    const base: u8 = if (background) 40 else 30;
    const offset = namedAnsiColorOffset(color) orelse {
        try state.appendPrompt(if (background) "49" else "39");
        return;
    };
    try appendPromptPrint(state, "{d}", .{base + offset});
}

fn appendPromptPrint(state: *State, comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(state.allocator, fmt, args);
    defer state.allocator.free(bytes);
    try state.appendPrompt(bytes);
}

fn namedAnsiColorOffset(color: []const u8) ?u8 {
    if (std.mem.eql(u8, color, "black")) return 0;
    if (std.mem.eql(u8, color, "red")) return 1;
    if (std.mem.eql(u8, color, "green")) return 2;
    if (std.mem.eql(u8, color, "yellow")) return 3;
    if (std.mem.eql(u8, color, "blue")) return 4;
    if (std.mem.eql(u8, color, "magenta")) return 5;
    if (std.mem.eql(u8, color, "cyan")) return 6;
    if (std.mem.eql(u8, color, "white")) return 7;
    return null;
}

fn shellEnvValue(sh: anytype, name: []const u8) ?[]const u8 {
    for (sh.env) |entry_ptr| {
        const entry = std.mem.span(entry_ptr);
        if (entry.len <= name.len or entry[name.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

pub fn expandAbbreviation(
    state: *State,
    allocator: std.mem.Allocator,
    source: []const u8,
    cursor: usize,
    append_space: bool,
) !?completion.Edit {
    const end = @min(cursor, source.len);
    var start = end;
    while (start > 0 and isCommandNameByte(source[start - 1])) start -= 1;
    if (start == end) return null;
    if (start > 0 and !isCommandSeparator(source[start - 1])) return null;
    const name = source[start..end];
    const replacement = state.getAbbreviation(name) orelse return null;
    return .{
        .replace_start = start,
        .replace_end = end,
        .replacement = try allocator.dupe(u8, replacement),
        .append_space = append_space,
    };
}

fn isCommandNameByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', ';', '|', '&', '(', ')' => false,
        else => true,
    };
}

fn isCommandSeparator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', ';', '|', '&', '(' => true,
        else => false,
    };
}

fn parseRgb(text: []const u8) ?[3]u8 {
    if (text.len != 7 or text[0] != '#') return null;
    return .{
        std.fmt.parseInt(u8, text[1..3], 16) catch return null,
        std.fmt.parseInt(u8, text[3..5], 16) catch return null,
        std.fmt.parseInt(u8, text[5..7], 16) catch return null,
    };
}

fn blendRgb(lhs: [3]u8, rhs: [3]u8, percent: u8) [3]u8 {
    var out: [3]u8 = undefined;
    for (&out, lhs, rhs) |*channel, a, b| {
        const left: i32 = a;
        const right: i32 = b;
        channel.* = @intCast(@divTrunc(left * (100 - percent) + right * percent, 100));
    }
    return out;
}

fn shellCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (args, 0..) |arg, index| {
        if (index != 0) try out.append(allocator, ' ');
        try appendShellSingleQuoted(allocator, &out, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn appendShellSingleQuoted(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
}

fn eventKey(allocator: std.mem.Allocator, event: []const u8, name: []const u8) ![]const u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(allocator);
    try key.appendSlice(allocator, event);
    try key.append(allocator, 0);
    try key.appendSlice(allocator, name);
    return key.toOwnedSlice(allocator);
}

test "Rush extension registry exposes abbr as an extension" {
    const abbr = registry.lookup("abbr") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(builtin.Origin.extension, abbr.origin);
}
