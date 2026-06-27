//! Handler lookup for bundled Rush extension builtins.

const api = @import("api.zig");

const local = @import("compat/local.zig");
const shopt = @import("compat/shopt.zig");
const source = @import("compat/source.zig");
const type_builtin = @import("compat/type.zig");
const abbr = @import("editor/abbr.zig");
const prompt = @import("editor/prompt.zig");
const rush_complete = @import("editor/rush_complete.zig");
const color = @import("color.zig");
const env_import = @import("env_import.zig");
const event = @import("event.zig");

pub fn lookup(name: []const u8) ?api.HandlerSpec {
    if (local.handlerFor(name)) |handler| return handler;
    if (shopt.handlerFor(name)) |handler| return handler;
    if (source.handlerFor(name)) |handler| return handler;
    if (type_builtin.handlerFor(name)) |handler| return handler;
    if (abbr.handlerFor(name)) |handler| return handler;
    if (prompt.handlerFor(name)) |handler| return handler;
    if (rush_complete.handlerForContext(name, null)) |handler| return handler;
    if (color.handlerFor(name)) |handler| return handler;
    if (env_import.handlerFor(name)) |handler| return handler;
    if (event.handlerFor(name)) |handler| return handler;
    return null;
}
