//! Builtin command vocabulary for the redesigned semantic shell core.
//!
//! Builtin dispatch is semantic shell behavior. Concrete builtin execution will
//! be added later without moving the old executor in this skeleton task.

const std = @import("std");

pub const BuiltinKind = enum {
    regular,
    special,
};

pub const BuiltinSemanticClass = enum {
    unsupported,
    no_op,
    status_constant,
    output,
    predicate,
    declaration,
    shell_state,
    job_control,
    control_flow,

    pub fn isNonMutating(self: BuiltinSemanticClass) bool {
        return switch (self) {
            .no_op,
            .status_constant,
            .output,
            .predicate,
            .control_flow,
            => true,
            .unsupported, .declaration, .shell_state, .job_control => false,
        };
    }

    pub fn isStateful(self: BuiltinSemanticClass) bool {
        return switch (self) {
            .declaration, .shell_state, .job_control => true,
            .unsupported, .no_op, .status_constant, .output, .predicate, .control_flow => false,
        };
    }
};

pub const Builtin = struct {
    name: []const u8,
    kind: BuiltinKind = .regular,
    semantic_class: BuiltinSemanticClass = .unsupported,

    pub fn init(name: []const u8, kind: BuiltinKind) Builtin {
        return initWithSemantics(name, kind, .unsupported);
    }

    pub fn initWithSemantics(name: []const u8, kind: BuiltinKind, semantic_class: BuiltinSemanticClass) Builtin {
        const definition: Builtin = .{ .name = name, .kind = kind, .semantic_class = semantic_class };
        definition.validate();
        return definition;
    }

    pub fn isSpecial(self: Builtin) bool {
        self.validate();
        return self.kind == .special;
    }

    pub fn isSemanticallyNonMutating(self: Builtin) bool {
        self.validate();
        return self.semantic_class.isNonMutating();
    }

    pub fn validate(self: Builtin) void {
        std.debug.assert(self.name.len != 0);
        switch (self.semantic_class) {
            .unsupported => {},
            .no_op => std.debug.assert(std.mem.eql(u8, self.name, ":")),
            .status_constant => std.debug.assert(std.mem.eql(u8, self.name, "true") or std.mem.eql(u8, self.name, "false")),
            .output => std.debug.assert(std.mem.eql(u8, self.name, "echo") or std.mem.eql(u8, self.name, "printf")),
            .predicate => std.debug.assert(std.mem.eql(u8, self.name, "test") or std.mem.eql(u8, self.name, "[")),
            .declaration => std.debug.assert(std.mem.eql(u8, self.name, "export") or std.mem.eql(u8, self.name, "readonly") or std.mem.eql(u8, self.name, "unset")),
            .shell_state => std.debug.assert(std.mem.eql(u8, self.name, "set") or std.mem.eql(u8, self.name, "shift") or std.mem.eql(u8, self.name, "alias") or std.mem.eql(u8, self.name, "unalias") or std.mem.eql(u8, self.name, "trap") or std.mem.eql(u8, self.name, "local") or std.mem.eql(u8, self.name, "read")),
            .job_control => std.debug.assert(std.mem.eql(u8, self.name, "jobs") or std.mem.eql(u8, self.name, "fg") or std.mem.eql(u8, self.name, "bg")),
            .control_flow => std.debug.assert(std.mem.eql(u8, self.name, "break") or std.mem.eql(u8, self.name, "continue") or std.mem.eql(u8, self.name, "exit") or std.mem.eql(u8, self.name, "return")),
        }
    }
};

pub const default_builtins = [_]Builtin{
    Builtin.initWithSemantics(":", .special, .no_op),
    Builtin.init(".", .special),
    Builtin.initWithSemantics("break", .special, .control_flow),
    Builtin.initWithSemantics("continue", .special, .control_flow),
    Builtin.init("eval", .special),
    Builtin.init("exec", .special),
    Builtin.initWithSemantics("exit", .special, .control_flow),
    Builtin.initWithSemantics("export", .special, .declaration),
    Builtin.initWithSemantics("readonly", .special, .declaration),
    Builtin.initWithSemantics("return", .special, .control_flow),
    Builtin.initWithSemantics("set", .special, .shell_state),
    Builtin.initWithSemantics("shift", .special, .shell_state),
    Builtin.init("times", .special),
    Builtin.initWithSemantics("trap", .special, .shell_state),
    Builtin.initWithSemantics("unset", .special, .declaration),

    Builtin.initWithSemantics("[", .regular, .predicate),
    Builtin.init("abbr", .regular),
    Builtin.initWithSemantics("alias", .regular, .shell_state),
    Builtin.initWithSemantics("bg", .regular, .job_control),
    Builtin.init("cd", .regular),
    Builtin.init("color", .regular),
    Builtin.init("command", .regular),
    Builtin.init("complete", .regular),
    Builtin.initWithSemantics("echo", .regular, .output),
    Builtin.init("env", .regular),
    Builtin.init("event", .regular),
    Builtin.initWithSemantics("false", .regular, .status_constant),
    Builtin.init("fc", .regular),
    Builtin.initWithSemantics("fg", .regular, .job_control),
    Builtin.init("getopts", .regular),
    Builtin.init("hash", .regular),
    Builtin.init("interval", .regular),
    Builtin.initWithSemantics("jobs", .regular, .job_control),
    Builtin.init("kill", .regular),
    Builtin.initWithSemantics("local", .regular, .shell_state),
    Builtin.initWithSemantics("printf", .regular, .output),
    Builtin.init("pwd", .regular),
    Builtin.initWithSemantics("read", .regular, .shell_state),
    Builtin.init("shopt", .regular),
    Builtin.init("source", .regular),
    Builtin.initWithSemantics("test", .regular, .predicate),
    Builtin.initWithSemantics("true", .regular, .status_constant),
    Builtin.init("type", .regular),
    Builtin.init("ulimit", .regular),
    Builtin.init("umask", .regular),
    Builtin.initWithSemantics("unalias", .regular, .shell_state),
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
    try std.testing.expectEqual(BuiltinSemanticClass.output, regular.semantic_class);
    try std.testing.expect(regular.isSemanticallyNonMutating());
    try std.testing.expect(!regular.isSpecial());
    try std.testing.expect(!isSpecialBuiltin("echo"));
    try std.testing.expectEqual(BuiltinSemanticClass.no_op, (lookup(":") orelse return error.TestExpectedEqual).semantic_class);
    try std.testing.expectEqual(BuiltinSemanticClass.status_constant, (lookup("true") orelse return error.TestExpectedEqual).semantic_class);
    try std.testing.expectEqual(BuiltinSemanticClass.status_constant, (lookup("false") orelse return error.TestExpectedEqual).semantic_class);
    try std.testing.expectEqual(BuiltinSemanticClass.predicate, (lookup("test") orelse return error.TestExpectedEqual).semantic_class);
    try std.testing.expectEqual(BuiltinSemanticClass.predicate, (lookup("[") orelse return error.TestExpectedEqual).semantic_class);
    try std.testing.expectEqual(@as(?Builtin, null), lookup("definitely-not-a-builtin"));
}
