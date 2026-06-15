//! `type` compatibility extension builtin.

const std = @import("std");

const api = @import("../api.zig");
const shell_builtin = @import("../../shell/builtin.zig");
const outcome = @import("../../shell/outcome.zig");

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "type")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "type"));

    const request = parseRequest(invocation) catch |err| switch (err) {
        error.UnsupportedOption => return api.EvaluationResult.normal(try invocation.usageError(
            "type",
            "unsupported option",
        )),
    };
    if (request.first_operand >= invocation.argv.len) return api.EvaluationResult.normal(try invocation.usageError(
        "type",
        "missing operand",
    ));

    var status: outcome.ExitStatus = 0;
    for (invocation.argv[request.first_operand..]) |name| {
        if (try describeCommand(invocation, request.options, name)) continue;
        try reportNotFound(invocation, name);
        status = 1;
    }
    return api.EvaluationResult.normal(status);
}

const TypeOptions = struct {
    all: bool = false,
    type_only: bool = false,
    path_only: bool = false,
    force_path: bool = false,
    suppress_functions: bool = false,
};

const TypeRequest = struct {
    options: TypeOptions,
    first_operand: usize,
};

fn parseRequest(invocation: *api.Invocation) error{UnsupportedOption}!TypeRequest {
    var options: TypeOptions = .{};
    var index: usize = 1;
    while (index < invocation.argv.len) : (index += 1) {
        const arg = invocation.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'a' => options.all = true,
            't' => options.type_only = true,
            'p' => options.path_only = true,
            'P' => options.force_path = true,
            'f' => options.suppress_functions = true,
            else => return error.UnsupportedOption,
        };
    }
    return .{ .options = options, .first_operand = index };
}

fn describeCommand(invocation: *api.Invocation, options: TypeOptions, name: []const u8) !bool {
    var found = false;
    const shell_lookup_enabled = !options.force_path;
    if (shell_lookup_enabled and !options.path_only and isAliasName(name)) {
        if (invocation.shell_state.getAlias(name)) |alias| {
            try printAlias(invocation, options, name, alias.value);
            if (!options.all) return true;
            found = true;
        }
    }

    if (shell_lookup_enabled) {
        if (lookupBuiltin(invocation.builtins, name, .special) != null) {
            try printBuiltin(invocation, options, name, .special);
            if (!options.all) return true;
            found = true;
        }
    }

    if (shell_lookup_enabled and !options.suppress_functions and isShellName(name)) {
        if (invocation.shell_state.getFunction(name) != null) {
            try printFunction(invocation, options, name);
            if (!options.all) return true;
            found = true;
        }
    }

    if (shell_lookup_enabled) {
        if (lookupBuiltin(invocation.builtins, name, .regular) != null) {
            try printBuiltin(invocation, options, name, .regular);
            if (!options.all) return true;
            found = true;
        }
    }

    if (invocation.external_resolver) |resolver| {
        if (options.all) {
            const resolutions = try resolver.resolveAll(invocation.allocator, invocation.assignments, name);
            defer api.freeExternalResolutions(invocation.allocator, resolutions);
            for (resolutions) |resolution| try printExternal(invocation, options, name, resolution.path);
            found = found or resolutions.len != 0;
        } else if (try resolver.resolve(invocation.allocator, invocation.assignments, name)) |resolution| {
            defer invocation.allocator.free(resolution.path);
            try printExternal(invocation, options, name, resolution.path);
            found = true;
        }
    }

    return found;
}

fn printAlias(invocation: *api.Invocation, options: TypeOptions, name: []const u8, value: []const u8) !void {
    if (options.type_only) return invocation.stdout.appendSlice(invocation.allocator, "alias\n");
    try invocation.stdout.print(invocation.allocator, "{s} is an alias for ", .{name});
    try api.appendShellSingleQuoted(invocation.allocator, invocation.stdout, value);
    try invocation.stdout.append(invocation.allocator, '\n');
}

fn printBuiltin(
    invocation: *api.Invocation,
    options: TypeOptions,
    name: []const u8,
    kind: shell_builtin.BuiltinKind,
) !void {
    if (options.path_only) return;
    if (options.type_only) return invocation.stdout.appendSlice(invocation.allocator, "builtin\n");
    const description = if (kind == .special) "special shell builtin" else "shell builtin";
    try invocation.stdout.print(invocation.allocator, "{s} is a {s}\n", .{ name, description });
}

fn printFunction(invocation: *api.Invocation, options: TypeOptions, name: []const u8) !void {
    if (options.path_only) return;
    if (options.type_only) return invocation.stdout.appendSlice(invocation.allocator, "function\n");
    try invocation.stdout.print(invocation.allocator, "{s} is a shell function\n", .{name});
}

fn printExternal(invocation: *api.Invocation, options: TypeOptions, name: []const u8, path: []const u8) !void {
    if (options.type_only) return invocation.stdout.appendSlice(invocation.allocator, "file\n");
    if (options.path_only) return invocation.stdout.print(invocation.allocator, "{s}\n", .{path});
    try invocation.stdout.print(invocation.allocator, "{s} is {s}\n", .{ name, path });
}

fn lookupBuiltin(
    builtins: []const shell_builtin.Builtin,
    name: []const u8,
    kind: shell_builtin.BuiltinKind,
) ?shell_builtin.Builtin {
    for (builtins) |definition| {
        definition.validate();
        if (definition.kind == kind and std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

fn reportNotFound(invocation: *api.Invocation, name: []const u8) !void {
    try invocation.stderr.print(invocation.allocator, "type: {s}: not found\n", .{name});
    const diagnostic = try std.fmt.allocPrint(invocation.allocator, "type: {s}: not found", .{name});
    errdefer invocation.allocator.free(diagnostic);
    try invocation.diagnostics.append(invocation.allocator, diagnostic);
}

fn isShellName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return true;
}

fn isAliasName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphabetic(byte) or
            std.ascii.isDigit(byte) or
            byte == '!' or
            byte == '%' or
            byte == ',' or
            byte == '-' or
            byte == '@' or
            byte == '_')) return false;
    }
    return true;
}
