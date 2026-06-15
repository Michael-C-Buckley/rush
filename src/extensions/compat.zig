//! Non-POSIX compatibility extension builtins.

const shell_builtin = @import("../shell/builtin.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("local", .shell_state),
    shell_builtin.Builtin.initExtension("shopt", .shell_state),
    shell_builtin.Builtin.initExtension("source", .shell_state),
    shell_builtin.Builtin.initExtension("type", .output),
};
