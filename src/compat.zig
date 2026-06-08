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
    strict_diagnostics: bool = false,

    pub fn posix() Features {
        return .{ .mode = .posix };
    }

    pub fn strictPosix() Features {
        return .{ .mode = .posix, .strict_diagnostics = true };
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

test "strict POSIX diagnostics can be requested explicitly" {
    const std = @import("std");
    const features = Features.strictPosix();
    try std.testing.expectEqual(Mode.posix, features.mode);
    try std.testing.expect(features.strict_diagnostics);
}

test "Bash compatibility can be requested explicitly" {
    const std = @import("std");
    const features = Features.bash();
    try std.testing.expectEqual(Mode.bash, features.mode);
    try std.testing.expect(features.isBash());
}
