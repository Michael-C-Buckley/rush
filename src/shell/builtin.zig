//! Builtin command vocabulary for the redesigned semantic shell core.
//!
//! Builtin dispatch is semantic shell behavior.

const std = @import("std");

pub const BuiltinKind = enum {
    regular,
    special,
};

pub const BuiltinOrigin = enum {
    posix,
    extension,
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
    origin: BuiltinOrigin = .posix,

    pub fn init(name: []const u8, kind: BuiltinKind) Builtin {
        return initWithSemantics(name, kind, .unsupported);
    }

    pub fn initWithSemantics(name: []const u8, kind: BuiltinKind, semantic_class: BuiltinSemanticClass) Builtin {
        const definition: Builtin = .{ .name = name, .kind = kind, .semantic_class = semantic_class };
        definition.validate();
        return definition;
    }

    pub fn initExtension(name: []const u8, semantic_class: BuiltinSemanticClass) Builtin {
        const definition: Builtin = .{
            .name = name,
            .kind = .regular,
            .semantic_class = semantic_class,
            .origin = .extension,
        };
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
        if (self.origin == .extension) {
            std.debug.assert(self.kind == .regular);
            return;
        }
        std.debug.assert(semanticClassAcceptsName(self.semantic_class, self.name));
    }
};

pub const RegistryError = error{
    DuplicateBuiltin,
    ExtensionSpecialBuiltin,
};

pub const BuiltinRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Builtin) = .empty,

    pub fn init(allocator: std.mem.Allocator) BuiltinRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BuiltinRegistry) void {
        for (self.entries.items) |entry| self.allocator.free(entry.name);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *BuiltinRegistry, definition: Builtin) (std.mem.Allocator.Error || RegistryError)!void {
        if (definition.origin == .extension and definition.kind == .special) return error.ExtensionSpecialBuiltin;
        definition.validate();
        if (self.lookup(definition.name) != null) return error.DuplicateBuiltin;

        const owned_name = try self.allocator.dupe(u8, definition.name);
        errdefer self.allocator.free(owned_name);
        var owned_definition = definition;
        owned_definition.name = owned_name;
        try self.entries.append(self.allocator, owned_definition);
    }

    pub fn registerSlice(
        self: *BuiltinRegistry,
        definitions: []const Builtin,
    ) (std.mem.Allocator.Error || RegistryError)!void {
        for (definitions) |definition| try self.register(definition);
    }

    pub fn lookup(self: BuiltinRegistry, name: []const u8) ?Builtin {
        for (self.entries.items) |definition| {
            definition.validate();
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    pub fn slice(self: BuiltinRegistry) []const Builtin {
        assertUniqueNames(self.entries.items);
        return self.entries.items;
    }
};

fn semanticClassAcceptsName(semantic_class: BuiltinSemanticClass, name: []const u8) bool {
    return switch (semantic_class) {
        .unsupported => true,
        .no_op => matchesName(name, &.{":"}),
        .status_constant => matchesName(name, &.{ "true", "false" }),
        .output => matchesName(name, &.{ "echo", "printf", "env", "pwd" }),
        .predicate => matchesName(name, &.{ "test", "[" }),
        .declaration => matchesName(name, &.{ "export", "readonly", "unset" }),
        .shell_state => matchesName(name, &.{
            ".",
            "eval",
            "set",
            "shift",
            "alias",
            "unalias",
            "trap",
            "local",
            "read",
            "cd",
            "command",
            "abbr",
            "exec",
            "umask",
            "hash",
            "getopts",
        }),
        .job_control => matchesName(name, &.{ "jobs", "fg", "bg", "wait", "kill" }),
        .control_flow => matchesName(name, &.{ "break", "continue", "exit", "return" }),
    };
}

fn matchesName(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub const posix_builtins = [_]Builtin{
    Builtin.initWithSemantics(":", .special, .no_op),
    Builtin.initWithSemantics(".", .special, .shell_state),
    Builtin.initWithSemantics("break", .special, .control_flow),
    Builtin.initWithSemantics("continue", .special, .control_flow),
    Builtin.initWithSemantics("eval", .special, .shell_state),
    Builtin.initWithSemantics("exec", .special, .shell_state),
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
    Builtin.initWithSemantics("alias", .regular, .shell_state),
    Builtin.initWithSemantics("bg", .regular, .job_control),
    Builtin.initWithSemantics("cd", .regular, .shell_state),
    Builtin.initWithSemantics("command", .regular, .shell_state),
    Builtin.initWithSemantics("echo", .regular, .output),
    Builtin.initWithSemantics("env", .regular, .output),
    Builtin.initWithSemantics("false", .regular, .status_constant),
    Builtin.init("fc", .regular),
    Builtin.initWithSemantics("fg", .regular, .job_control),
    Builtin.initWithSemantics("getopts", .regular, .shell_state),
    Builtin.initWithSemantics("hash", .regular, .shell_state),
    Builtin.initWithSemantics("jobs", .regular, .job_control),
    Builtin.initWithSemantics("kill", .regular, .job_control),
    Builtin.initWithSemantics("printf", .regular, .output),
    Builtin.initWithSemantics("pwd", .regular, .output),
    Builtin.initWithSemantics("read", .regular, .shell_state),
    Builtin.initWithSemantics("test", .regular, .predicate),
    Builtin.initWithSemantics("true", .regular, .status_constant),
    Builtin.init("ulimit", .regular),
    Builtin.initWithSemantics("umask", .regular, .shell_state),
    Builtin.initWithSemantics("unalias", .regular, .shell_state),
    Builtin.initWithSemantics("wait", .regular, .job_control),
};

pub const posix_registry: []const Builtin = &posix_builtins;

pub fn lookup(name: []const u8) ?Builtin {
    return lookupIn(posix_registry, name);
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
    try std.testing.expectEqual(
        BuiltinSemanticClass.no_op,
        (lookup(":") orelse return error.TestExpectedEqual).semantic_class,
    );
    try std.testing.expectEqual(
        BuiltinSemanticClass.status_constant,
        (lookup("true") orelse return error.TestExpectedEqual).semantic_class,
    );
    try std.testing.expectEqual(
        BuiltinSemanticClass.status_constant,
        (lookup("false") orelse return error.TestExpectedEqual).semantic_class,
    );
    try std.testing.expectEqual(
        BuiltinSemanticClass.predicate,
        (lookup("test") orelse return error.TestExpectedEqual).semantic_class,
    );
    try std.testing.expectEqual(
        BuiltinSemanticClass.predicate,
        (lookup("[") orelse return error.TestExpectedEqual).semantic_class,
    );
    try std.testing.expectEqual(
        BuiltinSemanticClass.shell_state,
        (lookup("command") orelse return error.TestExpectedEqual).semantic_class,
    );
    try std.testing.expectEqual(@as(?Builtin, null), lookup("definitely-not-a-builtin"));
}

test "POSIX builtin registry excludes Rush extension builtins" {
    const extension_names = [_][]const u8{
        "abbr",
        "color",
        "local",
        "shopt",
        "source",
        "type",
    };

    for (extension_names) |name| try std.testing.expectEqual(@as(?Builtin, null), lookup(name));
}

test "builtin registry rejects duplicate names and extension special builtins" {
    var registry = BuiltinRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(Builtin.initWithSemantics("echo", .regular, .output));
    try std.testing.expectError(
        error.DuplicateBuiltin,
        registry.register(Builtin.initWithSemantics("echo", .regular, .output)),
    );

    const extension_special: Builtin = .{
        .name = "rush-special",
        .kind = .special,
        .semantic_class = .unsupported,
        .origin = .extension,
    };
    try std.testing.expectError(error.ExtensionSpecialBuiltin, registry.register(extension_special));
}
