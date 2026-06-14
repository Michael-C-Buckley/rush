//! Semantic trap and signal vocabulary for the redesigned shell core.
//!
//! This module owns shell-level trap names and action/disposition rules. Runtime
//! signal ports stay lower-level and deal only in numeric signal events.

const std = @import("std");

pub const Signal = enum {
    EXIT,
    HUP,
    INT,
    QUIT,
    TERM,
    USR1,
    USR2,

    pub fn name(self: Signal) []const u8 {
        return switch (self) {
            .EXIT => "EXIT",
            .HUP => "HUP",
            .INT => "INT",
            .QUIT => "QUIT",
            .TERM => "TERM",
            .USR1 => "USR1",
            .USR2 => "USR2",
        };
    }

    pub fn fromName(name_value: []const u8) ?Signal {
        for (signal_names) |entry| {
            if (std.mem.eql(u8, name_value, entry.name)) return entry.signal;
        }
        return null;
    }

    pub fn fromRuntimeNumber(number: u8) ?Signal {
        std.debug.assert(number != 0);
        return switch (number) {
            1 => .HUP,
            2 => .INT,
            3 => .QUIT,
            10 => .USR1,
            12 => .USR2,
            15 => .TERM,
            else => null,
        };
    }

    pub fn runtimeNumber(self: Signal) ?u8 {
        return switch (self) {
            .EXIT => null,
            .HUP => 1,
            .INT => 2,
            .QUIT => 3,
            .USR1 => 10,
            .USR2 => 12,
            .TERM => 15,
        };
    }

    pub fn isRuntimeSignal(self: Signal) bool {
        return self.runtimeNumber() != null;
    }

    pub fn defaultExitStatus(self: Signal) ?u8 {
        const number = self.runtimeNumber() orelse return null;
        const value: u16 = 128 + @as(u16, number);
        return if (value <= std.math.maxInt(u8)) @intCast(value) else std.math.maxInt(u8);
    }

    pub fn validate(self: Signal) void {
        std.debug.assert(Signal.fromName(self.name()) == self);
        if (self.runtimeNumber()) |number| std.debug.assert(Signal.fromRuntimeNumber(number) == self);
    }
};

const SignalName = struct {
    name: []const u8,
    signal: Signal,
};

const signal_names = [_]SignalName{
    .{ .name = "EXIT", .signal = .EXIT },
    .{ .name = "HUP", .signal = .HUP },
    .{ .name = "INT", .signal = .INT },
    .{ .name = "QUIT", .signal = .QUIT },
    .{ .name = "TERM", .signal = .TERM },
    .{ .name = "USR1", .signal = .USR1 },
    .{ .name = "USR2", .signal = .USR2 },
};

pub const ActionKind = enum {
    command,
    ignore,
};

pub const Disposition = enum {
    default,
    ignore,
    caught,
};

pub const Delivery = enum {
    default_action,
    ignored,
    queued,
};

pub fn actionKind(action: []const u8) ActionKind {
    assertValidAction(action);
    return if (action.len == 0) .ignore else .command;
}

pub fn assertValidAction(action: []const u8) void {
    std.debug.assert(std.mem.indexOfScalar(u8, action, 0) == null);
}

pub fn isValidName(name_value: []const u8) bool {
    return Signal.fromName(name_value) != null;
}

pub fn assertValidName(name_value: []const u8) void {
    std.debug.assert(isValidName(name_value));
}

test "trap signal vocabulary maps names and runtime numbers explicitly" {
    const signals = [_]Signal{ .EXIT, .HUP, .INT, .QUIT, .TERM, .USR1, .USR2 };
    for (signals) |signal| {
        signal.validate();
        try std.testing.expectEqual(signal, Signal.fromName(signal.name()).?);
    }

    try std.testing.expectEqual(@as(?Signal, Signal.INT), Signal.fromRuntimeNumber(2));
    try std.testing.expectEqual(@as(?Signal, null), Signal.fromRuntimeNumber(9));
    try std.testing.expectEqual(@as(?u8, null), Signal.EXIT.runtimeNumber());
    try std.testing.expectEqual(@as(?u8, 143), Signal.TERM.defaultExitStatus());
    try std.testing.expectEqual(ActionKind.ignore, actionKind(""));
    try std.testing.expectEqual(ActionKind.command, actionKind("echo trapped"));
}
