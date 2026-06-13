//! Builtin command vocabulary for the redesigned semantic shell core.
//!
//! Builtin dispatch is semantic shell behavior. Concrete builtin execution will
//! be added later without moving the old executor in this skeleton task.

const std = @import("std");

pub const BuiltinKind = enum {
    regular,
    special,
};

pub const Builtin = struct {
    name: []const u8,
    kind: BuiltinKind = .regular,

    pub fn init(name: []const u8, kind: BuiltinKind) Builtin {
        const definition: Builtin = .{ .name = name, .kind = kind };
        definition.validate();
        return definition;
    }

    pub fn isSpecial(self: Builtin) bool {
        self.validate();
        return self.kind == .special;
    }

    pub fn validate(self: Builtin) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const default_builtins = [_]Builtin{
    Builtin.init(":", .special),
    Builtin.init(".", .special),
    Builtin.init("break", .special),
    Builtin.init("continue", .special),
    Builtin.init("eval", .special),
    Builtin.init("exec", .special),
    Builtin.init("exit", .special),
    Builtin.init("export", .special),
    Builtin.init("readonly", .special),
    Builtin.init("return", .special),
    Builtin.init("set", .special),
    Builtin.init("shift", .special),
    Builtin.init("times", .special),
    Builtin.init("trap", .special),
    Builtin.init("unset", .special),

    Builtin.init("[", .regular),
    Builtin.init("abbr", .regular),
    Builtin.init("alias", .regular),
    Builtin.init("bg", .regular),
    Builtin.init("cd", .regular),
    Builtin.init("color", .regular),
    Builtin.init("command", .regular),
    Builtin.init("complete", .regular),
    Builtin.init("echo", .regular),
    Builtin.init("env", .regular),
    Builtin.init("event", .regular),
    Builtin.init("false", .regular),
    Builtin.init("fc", .regular),
    Builtin.init("fg", .regular),
    Builtin.init("getopts", .regular),
    Builtin.init("hash", .regular),
    Builtin.init("interval", .regular),
    Builtin.init("jobs", .regular),
    Builtin.init("kill", .regular),
    Builtin.init("local", .regular),
    Builtin.init("printf", .regular),
    Builtin.init("pwd", .regular),
    Builtin.init("read", .regular),
    Builtin.init("shopt", .regular),
    Builtin.init("source", .regular),
    Builtin.init("test", .regular),
    Builtin.init("true", .regular),
    Builtin.init("type", .regular),
    Builtin.init("ulimit", .regular),
    Builtin.init("umask", .regular),
    Builtin.init("unalias", .regular),
    Builtin.init("wait", .regular),
};

pub const default_registry: []const Builtin = &default_builtins;

pub fn lookup(name: []const u8) ?Builtin {
    return lookupIn(default_registry, name);
}

pub fn lookupIn(registry: []const Builtin, name: []const u8) ?Builtin {
    assertUniqueNames(registry);
    for (registry) |definition| {
        definition.validate();
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

pub fn isSpecialBuiltin(name: []const u8) bool {
    const definition = lookup(name) orelse return false;
    return definition.kind == .special;
}

pub fn assertUniqueNames(registry: []const Builtin) void {
    for (registry, 0..) |left, left_index| {
        left.validate();
        for (registry[left_index + 1 ..]) |right| {
            right.validate();
            std.debug.assert(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

test "builtin registry classifies POSIX special builtins separately" {
    const special_names = [_][]const u8{
        ":",
        ".",
        "break",
        "continue",
        "eval",
        "exec",
        "exit",
        "export",
        "readonly",
        "return",
        "set",
        "shift",
        "times",
        "trap",
        "unset",
    };

    for (special_names) |name| {
        const definition = lookup(name) orelse return error.TestExpectedEqual;
        try std.testing.expect(definition.isSpecial());
        try std.testing.expect(isSpecialBuiltin(name));
    }

    const regular = lookup("echo") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(BuiltinKind.regular, regular.kind);
    try std.testing.expect(!regular.isSpecial());
    try std.testing.expect(!isSpecialBuiltin("echo"));
    try std.testing.expectEqual(@as(?Builtin, null), lookup("definitely-not-a-builtin"));
}
