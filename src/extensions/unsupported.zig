//! Explicit handlers for extension builtins that are registered but not yet implemented.

const std = @import("std");

const api = @import("api.zig");
const state = @import("../shell/state.zig");

const unsupported_names = [_][]const u8{
    "color",
    "complete",
    "shopt",
    "source",
};

pub fn handlerFor(name: []const u8) ?api.HandlerSpec {
    for (unsupported_names) |unsupported| {
        if (std.mem.eql(u8, name, unsupported)) return .{ .handler = evaluate };
    }
    return null;
}

fn evaluate(context: ?*anyopaque, invocation: *api.Invocation) !state.ExitStatus {
    _ = context;
    std.debug.assert(invocation.argv.len != 0);
    return invocation.statusError(2, invocation.argv[0], "extension builtin is not implemented");
}
