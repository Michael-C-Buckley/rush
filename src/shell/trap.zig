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
    KILL,
    PIPE,
    ALRM,
    VTALRM,
    TERM,
    CONT,
    USR1,
    USR2,

    pub fn name(self: Signal) []const u8 {
        return switch (self) {
            .EXIT => "EXIT",
            .HUP => "HUP",
            .INT => "INT",
            .QUIT => "QUIT",
            .KILL => "KILL",
            .PIPE => "PIPE",
            .ALRM => "ALRM",
            .VTALRM => "VTALRM",
            .TERM => "TERM",
            .CONT => "CONT",
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
            @intFromEnum(std.posix.SIG.HUP) => .HUP,
            @intFromEnum(std.posix.SIG.INT) => .INT,
            @intFromEnum(std.posix.SIG.QUIT) => .QUIT,
            @intFromEnum(std.posix.SIG.PIPE) => .PIPE,
            @intFromEnum(std.posix.SIG.ALRM) => .ALRM,
            @intFromEnum(std.posix.SIG.VTALRM) => .VTALRM,
            @intFromEnum(std.posix.SIG.CONT) => .CONT,
            @intFromEnum(std.posix.SIG.USR1) => .USR1,
            @intFromEnum(std.posix.SIG.USR2) => .USR2,
            @intFromEnum(std.posix.SIG.TERM) => .TERM,
            else => null,
        };
    }

    pub fn runtimeNumber(self: Signal) ?u8 {
        return switch (self) {
            .EXIT => null,
            .KILL => null,
            .HUP => @intFromEnum(std.posix.SIG.HUP),
            .INT => @intFromEnum(std.posix.SIG.INT),
            .QUIT => @intFromEnum(std.posix.SIG.QUIT),
            .PIPE => @intFromEnum(std.posix.SIG.PIPE),
            .ALRM => @intFromEnum(std.posix.SIG.ALRM),
            .VTALRM => @intFromEnum(std.posix.SIG.VTALRM),
            .CONT => @intFromEnum(std.posix.SIG.CONT),
            .USR1 => @intFromEnum(std.posix.SIG.USR1),
            .USR2 => @intFromEnum(std.posix.SIG.USR2),
            .TERM => @intFromEnum(std.posix.SIG.TERM),
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
    .{ .name = "KILL", .signal = .KILL },
    .{ .name = "PIPE", .signal = .PIPE },
    .{ .name = "ALRM", .signal = .ALRM },
    .{ .name = "VTALRM", .signal = .VTALRM },
    .{ .name = "TERM", .signal = .TERM },
    .{ .name = "CONT", .signal = .CONT },
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
    const signals = [_]Signal{ .EXIT, .HUP, .INT, .QUIT, .KILL, .PIPE, .ALRM, .TERM, .CONT, .USR1, .USR2 };
    for (signals) |signal| {
        signal.validate();
        try std.testing.expectEqual(signal, Signal.fromName(signal.name()).?);
    }

    try std.testing.expectEqual(@as(?Signal, Signal.INT), Signal.fromRuntimeNumber(@intFromEnum(std.posix.SIG.INT)));
    try std.testing.expectEqual(@as(?Signal, Signal.PIPE), Signal.fromRuntimeNumber(@intFromEnum(std.posix.SIG.PIPE)));
    try std.testing.expectEqual(@as(?Signal, null), Signal.fromRuntimeNumber(@intFromEnum(std.posix.SIG.KILL)));
    try std.testing.expectEqual(@as(?u8, null), Signal.EXIT.runtimeNumber());
    try std.testing.expectEqual(@as(?u8, null), Signal.KILL.runtimeNumber());
    try std.testing.expectEqual(@as(?u8, 128 + @intFromEnum(std.posix.SIG.PIPE)), Signal.PIPE.defaultExitStatus());
    try std.testing.expectEqual(@as(?u8, 128 + @intFromEnum(std.posix.SIG.TERM)), Signal.TERM.defaultExitStatus());
    try std.testing.expectEqual(ActionKind.ignore, actionKind(""));
    try std.testing.expectEqual(ActionKind.command, actionKind("echo trapped"));
}
