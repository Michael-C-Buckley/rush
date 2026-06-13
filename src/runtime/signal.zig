//! Low-level signal runtime port vocabulary.
//!
//! This port deliberately knows only about numeric signal events, dispositions,
//! and wakeup polling. Shell-level trap policy lives in `src/shell/*`.

const std = @import("std");

const fd = @import("fd.zig");

pub const Number = u8;

const no_wake_fd: fd.Descriptor = -1;

var pending_event: std.atomic.Value(Number) = .init(0);
var wake_fd: std.atomic.Value(fd.Descriptor) = .init(no_wake_fd);

pub const Disposition = enum {
    default,
    ignore,
    caught,
};

pub const ConfigureRequest = struct {
    signal: Number,
    disposition: Disposition,

    pub fn validate(self: ConfigureRequest) void {
        assertValidNumber(self.signal);
    }
};

pub const Event = struct {
    signal: Number,

    pub fn validate(self: Event) void {
        assertValidNumber(self.signal);
    }
};

pub const ConfigureError = error{
    Unsupported,
    Unexpected,
};

pub const PollError = error{
    Unsupported,
    Unexpected,
};

pub const ConfigureFn = *const fn (*anyopaque, ConfigureRequest) ConfigureError!void;
pub const PollFn = *const fn (*anyopaque) PollError!?Event;

pub const Port = struct {
    context: *anyopaque,
    configure_fn: ConfigureFn,
    poll_fn: PollFn,

    pub fn configure(self: Port, request: ConfigureRequest) ConfigureError!void {
        request.validate();
        try self.configure_fn(self.context, request);
    }

    pub fn poll(self: Port) PollError!?Event {
        const event = try self.poll_fn(self.context);
        if (event) |signal_event| signal_event.validate();
        return event;
    }
};

pub fn assertValidNumber(number: Number) void {
    std.debug.assert(number != 0);
}

pub fn recordCaughtSignal(number: Number) void {
    assertValidNumber(number);
    pending_event.store(number, .seq_cst);
    wakeConfiguredFd();
}

pub fn pollCaughtSignal() ?Event {
    const raw = pending_event.load(.seq_cst);
    if (raw == 0) return null;
    if (pending_event.cmpxchgStrong(raw, 0, .seq_cst, .seq_cst) != null) return null;
    return .{ .signal = raw };
}

pub fn wakeConfiguredFd() void {
    const descriptor = wake_fd.load(.acquire);
    if (descriptor != no_wake_fd) _ = std.c.write(descriptor, "t", 1);
}

pub fn setWakeFd(descriptor: fd.Descriptor) void {
    fd.assertValidDescriptor(descriptor);
    wake_fd.store(descriptor, .release);
}

pub fn clearWakeFd(descriptor: fd.Descriptor) void {
    fd.assertValidDescriptor(descriptor);
    if (wake_fd.load(.acquire) == descriptor) wake_fd.store(no_wake_fd, .release);
}

pub fn disableWakeFdForForkedChild() void {
    wake_fd.store(no_wake_fd, .release);
}

pub fn resetProcessSignalStateForTesting() void {
    pending_event.store(0, .seq_cst);
    disableWakeFdForForkedChild();
}

test "runtime signal port validates numeric events without shell policy" {
    var fake: FakeSignalPort = .{};
    const port = fake.port();

    try port.configure(.{ .signal = 15, .disposition = .caught });
    try std.testing.expectEqual(@as(Number, 15), fake.configured_signal.?);
    try std.testing.expectEqual(Disposition.caught, fake.configured_disposition.?);

    fake.next_event = .{ .signal = 2 };
    const event = (try port.poll()).?;
    try std.testing.expectEqual(@as(Number, 2), event.signal);
    try std.testing.expectEqual(@as(?Event, null), try port.poll());
}

test "runtime signal process state records caught signals" {
    resetProcessSignalStateForTesting();
    defer resetProcessSignalStateForTesting();

    recordCaughtSignal(15);

    const event = pollCaughtSignal() orelse return error.MissingSignalEvent;
    try std.testing.expectEqual(@as(Number, 15), event.signal);
    try std.testing.expectEqual(@as(?Event, null), pollCaughtSignal());
}

const FakeSignalPort = struct {
    configured_signal: ?Number = null,
    configured_disposition: ?Disposition = null,
    next_event: ?Event = null,

    fn port(self: *FakeSignalPort) Port {
        return .{
            .context = self,
            .configure_fn = configure,
            .poll_fn = poll,
        };
    }

    fn configure(context: *anyopaque, request: ConfigureRequest) ConfigureError!void {
        const self: *FakeSignalPort = @ptrCast(@alignCast(context));
        request.validate();
        self.configured_signal = request.signal;
        self.configured_disposition = request.disposition;
    }

    fn poll(context: *anyopaque) PollError!?Event {
        const self: *FakeSignalPort = @ptrCast(@alignCast(context));
        const event = self.next_event;
        self.next_event = null;
        return event;
    }
};
