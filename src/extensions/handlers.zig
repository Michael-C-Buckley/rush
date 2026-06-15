//! Handler lookup for bundled Rush extension builtins.

const api = @import("api.zig");

const local = @import("compat/local.zig");
const source = @import("compat/source.zig");
const type_builtin = @import("compat/type.zig");
const abbr = @import("editor/abbr.zig");
const unsupported = @import("unsupported.zig");

pub fn lookup(name: []const u8) ?api.HandlerSpec {
    if (local.handlerFor(name)) |handler| return handler;
    if (source.handlerFor(name)) |handler| return handler;
    if (type_builtin.handlerFor(name)) |handler| return handler;
    if (abbr.handlerFor(name)) |handler| return handler;
    if (unsupported.handlerFor(name)) |handler| return handler;
    return null;
}
