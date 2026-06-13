//! Builtin command vocabulary for the redesigned semantic shell core.
//!
//! Builtin dispatch is semantic shell behavior. Concrete builtin execution will
//! be added later without moving the old executor in this skeleton task.

pub const BuiltinKind = enum {
    regular,
    special,
};

pub const Builtin = struct {
    name: []const u8,
    kind: BuiltinKind = .regular,
};
