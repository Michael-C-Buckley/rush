//! Builtin command dispatch for the direct evaluator.

const std = @import("std");

const result = @import("result.zig");

pub const Kind = enum {
    special,
    regular,
};

pub const Id = enum {
    colon,
    false_,
    true_,
};

pub const Definition = struct {
    name: []const u8,
    id: Id,
    kind: Kind,

    pub fn validate(self: Definition) void {
        std.debug.assert(self.name.len != 0);
    }
};

const DefinitionMap = std.StaticStringMap(Definition);

pub const definitions: DefinitionMap = .initComptime(.{
    .{ ":", Definition{ .name = ":", .id = .colon, .kind = .special } },
    .{ "false", Definition{ .name = "false", .id = .false_, .kind = .regular } },
    .{ "true", Definition{ .name = "true", .id = .true_, .kind = .regular } },
});

pub fn lookup(name: []const u8) ?Definition {
    const definition = definitions.get(name) orelse return null;
    definition.validate();
    return definition;
}

pub fn eval(definition: Definition) result.EvalResult {
    definition.validate();
    return switch (definition.id) {
        .colon, .true_ => .{},
        .false_ => .{ .status = 1 },
    };
}

test "builtin lookup identifies null true and false utilities" {
    try std.testing.expectEqual(Id.colon, lookup(":").?.id);
    try std.testing.expectEqual(Id.true_, lookup("true").?.id);
    try std.testing.expectEqual(Id.false_, lookup("false").?.id);
    try std.testing.expectEqual(@as(?Definition, null), lookup("missing"));
}

test "builtin eval returns utility status" {
    const true_definition = lookup("true").?;
    const false_definition = lookup("false").?;

    try std.testing.expectEqual(@as(result.ExitStatus, 0), eval(true_definition).status);
    try std.testing.expectEqual(@as(result.ExitStatus, 1), eval(false_definition).status);
}
