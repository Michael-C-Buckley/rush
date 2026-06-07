//! Compatibility mode plumbing.
//!
//! Rush starts from a POSIX baseline. Bash-compatible behavior should be added
//! behind explicit feature plumbing rather than scattered ad-hoc conditionals.

pub const Mode = enum {
    posix,
    bash,
};

pub const Features = struct {
    mode: Mode = .posix,

    pub fn posix() Features {
        return .{ .mode = .posix };
    }

    pub fn bash() Features {
        return .{ .mode = .bash };
    }

    pub fn isBash(self: Features) bool {
        return self.mode == .bash;
    }
};

test "compatibility defaults to POSIX" {
    const std = @import("std");
    const features: Features = .{};
    try std.testing.expectEqual(Mode.posix, features.mode);
    try std.testing.expect(!features.isBash());
}

test "Bash compatibility can be requested explicitly" {
    const std = @import("std");
    const features = Features.bash();
    try std.testing.expectEqual(Mode.bash, features.mode);
    try std.testing.expect(features.isBash());
}
