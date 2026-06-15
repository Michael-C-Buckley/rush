//! Editor-facing Rush extension builtins.

const shell_builtin = @import("../shell/builtin.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("abbr", .shell_state),
    shell_builtin.Builtin.initExtension("complete", .unsupported),
};
