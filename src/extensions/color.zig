//! Color utility Rush extension builtins.

const shell_builtin = @import("../shell/builtin.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("color", .unsupported),
};
