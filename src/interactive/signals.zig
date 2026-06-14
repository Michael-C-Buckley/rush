//! Interactive signal handler installation.

const std = @import("std");

pub const Handlers = struct {
    int: ActionGuard,
    quit: ActionGuard,
    term: ActionGuard,

    pub fn restore(self: *Handlers) void {
        self.term.restore();
        self.quit.restore();
        self.int.restore();
    }
};

pub const ActionGuard = struct {
    signal: std.posix.SIG,
    previous: std.posix.Sigaction,

    pub fn restore(self: ActionGuard) void {
        std.posix.sigaction(self.signal, &self.previous, null);
    }
};

pub fn install() Handlers {
    return .{
        .int = installHandler(.INT),
        .quit = installHandler(.QUIT),
        .term = installHandler(.TERM),
    };
}

fn installHandler(signal: std.posix.SIG) ActionGuard {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(signal, &action, &previous);
    return .{ .signal = signal, .previous = previous };
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {}
