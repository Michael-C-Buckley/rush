//! `shopt` compatibility extension builtin implementation.

const std = @import("std");

const api = @import("../api.zig");
const delta = @import("../../shell/delta.zig");
const state = @import("../../shell/state.zig");

const ShoptSpec = struct {
    name: []const u8,
    option: state.ShellShopt,
};

const shopt_specs = [_]ShoptSpec{.{ .name = "expand_aliases", .option = .expand_aliases }};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    if (!std.mem.eql(u8, name, "shopt")) return null;
    return .{ .handler = evaluate };
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !api.EvaluationResult {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    std.debug.assert(std.mem.eql(u8, invocation.argv[0], "shopt"));

    const request = parseRequest(invocation) catch |err| switch (err) {
        error.UnsupportedOption => return api.EvaluationResult.normal(try invocation.usageError(
            "shopt",
            "unsupported option",
        )),
        error.ConflictingMode => return api.EvaluationResult.normal(try invocation.usageError(
            "shopt",
            "conflicting options",
        )),
    };
    return api.EvaluationResult.normal(try evaluateRequest(invocation, request));
}

const Mode = enum {
    list,
    reusable,
    query,
    set,
    unset,
};

const Request = struct {
    mode: Mode = .list,
    first_operand: usize,
};

fn parseRequest(invocation: *api.Invocation) error{ UnsupportedOption, ConflictingMode }!Request {
    var request: Request = .{ .first_operand = 1 };
    var index: usize = 1;
    while (index < invocation.argv.len) : (index += 1) {
        const arg = invocation.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |option| switch (option) {
            'p' => try setMode(&request, .reusable),
            'q' => try setMode(&request, .query),
            's' => try setMode(&request, .set),
            'u' => try setMode(&request, .unset),
            else => return error.UnsupportedOption,
        };
    }
    request.first_operand = index;
    return request;
}

fn setMode(request: *Request, mode: Mode) error{ConflictingMode}!void {
    if (request.mode != .list and request.mode != mode) return error.ConflictingMode;
    request.mode = mode;
}

fn evaluateRequest(invocation: *api.Invocation, request: Request) !state.ExitStatus {
    if (request.first_operand >= invocation.argv.len) {
        return switch (request.mode) {
            .list => listShopts(invocation, false),
            .reusable => listShopts(invocation, true),
            .query => 0,
            .set, .unset => invocation.usageError("shopt", "missing option name"),
        };
    }

    var status: state.ExitStatus = 0;
    for (invocation.argv[request.first_operand..]) |name| {
        const spec = lookupShopt(name) orelse {
            try reportInvalidShopt(invocation, name);
            status = 1;
            continue;
        };
        switch (request.mode) {
            .list => try printShopt(invocation, spec, false),
            .reusable => try printShopt(invocation, spec, true),
            .query => {
                if (!shoptEnabled(invocation.shell_state, invocation.state_delta.*, spec.option)) status = 1;
            },
            .set => try invocation.state_delta.setShopt(spec.option, true),
            .unset => try invocation.state_delta.setShopt(spec.option, false),
        }
    }
    return status;
}

fn listShopts(invocation: *api.Invocation, reusable: bool) !state.ExitStatus {
    for (shopt_specs) |spec| try printShopt(invocation, spec, reusable);
    return 0;
}

fn printShopt(invocation: *api.Invocation, spec: ShoptSpec, reusable: bool) !void {
    const enabled = shoptEnabled(invocation.shell_state, invocation.state_delta.*, spec.option);
    if (reusable) {
        try invocation.stdout.print(
            invocation.allocator,
            "shopt {s} {s}\n",
            .{ if (enabled) "-s" else "-u", spec.name },
        );
    } else {
        try invocation.stdout.print(invocation.allocator, "{s}\t{s}\n", .{ spec.name, if (enabled) "on" else "off" });
    }
}

fn lookupShopt(name: []const u8) ?ShoptSpec {
    for (shopt_specs) |spec| if (std.mem.eql(u8, name, spec.name)) return spec;
    return null;
}

fn shoptEnabled(shell_state: state.ShellState, state_delta: delta.StateDelta, option: state.ShellShopt) bool {
    var enabled = shell_state.shopts.enabled(option);
    for (state_delta.shopt_changes.items) |change| {
        if (change.option == option) enabled = change.enabled;
    }
    return enabled;
}

fn reportInvalidShopt(invocation: *api.Invocation, name: []const u8) !void {
    try invocation.stderr.print(invocation.allocator, "shopt: {s}: invalid shell option name\n", .{name});
    const diagnostic = try std.fmt.allocPrint(
        invocation.allocator,
        "shopt: {s}: invalid shell option name",
        .{name},
    );
    errdefer invocation.allocator.free(diagnostic);
    try invocation.diagnostics.append(invocation.allocator, diagnostic);
}
