//! Editor-facing Rush extension builtins.

const shell_builtin = @import("../shell/builtin.zig");

pub const prompt = @import("editor/prompt.zig");
pub const rush_complete = @import("editor/rush_complete.zig");

pub const builtins = [_]shell_builtin.Builtin{
    shell_builtin.Builtin.initExtension("abbr", .extension_state),
} ++ prompt.builtins ++ rush_complete.builtins;
