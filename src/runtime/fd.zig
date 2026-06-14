//! File-descriptor runtime port vocabulary.
//!
//! Redirection and pipeline plans depend on this narrow descriptor abstraction;
//! concrete open/close/dup/pipe calls belong to the POSIX adapter.

const std = @import("std");

// ziglint-ignore: Z006 type alias
pub const Descriptor = std.posix.fd_t;
pub const current_working_directory: Descriptor = std.posix.AT.FDCWD;

pub const Operation = enum {
    open,
    close,
    duplicate,
    duplicate_to,
    pipe,
    is_tty,
};

pub const OpenAccess = enum {
    read_only,
    write_only,
    read_write,
};

pub const OpenOptions = struct {
    access: OpenAccess = .read_only,
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,
    append: bool = false,
    close_on_exec: bool = true,
    mode: std.posix.mode_t = 0o666,

    pub fn validate(self: OpenOptions) void {
        std.debug.assert(!self.exclusive or self.create);
        std.debug.assert(!self.truncate or self.access != .read_only);
        std.debug.assert(!self.append or self.access != .read_only);
        std.debug.assert(!(self.truncate and self.append));
        std.debug.assert((self.mode & ~@as(std.posix.mode_t, 0o7777)) == 0);
    }

    pub fn toPosixFlags(self: OpenOptions) std.posix.O {
        self.validate();

        var flags: std.posix.O = .{
            .ACCMODE = switch (self.access) {
                .read_only => .RDONLY,
                .write_only => .WRONLY,
                .read_write => .RDWR,
            },
        };
        if (@hasField(std.posix.O, "CREAT")) flags.CREAT = self.create;
        if (@hasField(std.posix.O, "EXCL")) flags.EXCL = self.exclusive;
        if (@hasField(std.posix.O, "TRUNC")) flags.TRUNC = self.truncate;
        if (@hasField(std.posix.O, "APPEND")) flags.APPEND = self.append;
        if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = self.close_on_exec;
        return flags;
    }
};

pub const OpenRequest = struct {
    path: []const u8,
    directory: Descriptor = current_working_directory,
    options: OpenOptions = .{},

    /// `path` is borrowed for the duration of the call; the runtime does not
    /// retain it. `directory` is either `current_working_directory` or an open
    /// directory descriptor owned by the caller.
    pub fn init(path: []const u8, options: OpenOptions) OpenRequest {
        const request: OpenRequest = .{ .path = path, .options = options };
        request.validate();
        return request;
    }

    pub fn validate(self: OpenRequest) void {
        std.debug.assert(self.path.len != 0);
        if (self.directory != current_working_directory) assertValidDescriptor(self.directory);
        self.options.validate();
    }
};

pub const OpenResult = struct {
    descriptor: Descriptor,

    pub fn validate(self: OpenResult) void {
        assertValidDescriptor(self.descriptor);
    }
};

pub const CloseRequest = struct {
    descriptor: Descriptor,

    pub fn init(descriptor: Descriptor) CloseRequest {
        const request: CloseRequest = .{ .descriptor = descriptor };
        request.validate();
        return request;
    }

    pub fn validate(self: CloseRequest) void {
        assertValidDescriptor(self.descriptor);
    }
};

pub const DuplicateRequest = struct {
    descriptor: Descriptor,
    close_on_exec: bool = false,

    pub fn init(descriptor: Descriptor) DuplicateRequest {
        const request: DuplicateRequest = .{ .descriptor = descriptor };
        request.validate();
        return request;
    }

    pub fn validate(self: DuplicateRequest) void {
        assertValidDescriptor(self.descriptor);
    }
};

pub const DuplicateResult = struct {
    descriptor: Descriptor,

    pub fn validate(self: DuplicateResult) void {
        assertValidDescriptor(self.descriptor);
    }
};

pub const DuplicateToRequest = struct {
    source: Descriptor,
    target: Descriptor,
    close_on_exec: bool = false,

    pub fn init(source: Descriptor, target: Descriptor) DuplicateToRequest {
        const request: DuplicateToRequest = .{ .source = source, .target = target };
        request.validate();
        return request;
    }

    pub fn validate(self: DuplicateToRequest) void {
        assertValidDescriptor(self.source);
        assertValidDescriptor(self.target);
    }
};

pub const PipeRequest = struct {
    close_on_exec: bool = true,

    pub fn validate(_: PipeRequest) void {}
};

pub const PipeResult = struct {
    read: Descriptor,
    write: Descriptor,

    pub fn validate(self: PipeResult) void {
        assertValidDescriptor(self.read);
        assertValidDescriptor(self.write);
        std.debug.assert(self.read != self.write);
    }
};

pub const IsTtyRequest = struct {
    descriptor: Descriptor,

    pub fn init(descriptor: Descriptor) IsTtyRequest {
        const request: IsTtyRequest = .{ .descriptor = descriptor };
        request.validate();
        return request;
    }

    pub fn validate(self: IsTtyRequest) void {
        assertValidDescriptor(self.descriptor);
    }
};

pub const IsTtyResult = struct {
    is_tty: bool,

    pub fn validate(_: IsTtyResult) void {}
};

pub const OpenError = std.posix.OpenError;
pub const CloseError = error{
    BadFileDescriptor,
    Unexpected,
};
pub const DuplicateError = error{
    BadFileDescriptor,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};
pub const PipeError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unsupported,
    Unexpected,
};
pub const IsTtyError = error{Unexpected};

pub const OpenFn = *const fn (*anyopaque, OpenRequest) OpenError!OpenResult;
pub const CloseFn = *const fn (*anyopaque, CloseRequest) CloseError!void;
pub const DuplicateFn = *const fn (*anyopaque, DuplicateRequest) DuplicateError!DuplicateResult;
pub const DuplicateToFn = *const fn (*anyopaque, DuplicateToRequest) DuplicateError!void;
pub const PipeFn = *const fn (*anyopaque, PipeRequest) PipeError!PipeResult;
pub const IsTtyFn = *const fn (*anyopaque, IsTtyRequest) IsTtyError!IsTtyResult;

pub const Port = struct {
    context: *anyopaque,
    open_fn: OpenFn,
    close_fn: CloseFn,
    duplicate_fn: DuplicateFn,
    duplicate_to_fn: DuplicateToFn,
    pipe_fn: PipeFn,
    is_tty_fn: IsTtyFn,

    pub fn open(self: Port, request: OpenRequest) OpenError!OpenResult {
        request.validate();
        const result = try self.open_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn close(self: Port, request: CloseRequest) CloseError!void {
        request.validate();
        try self.close_fn(self.context, request);
    }

    pub fn duplicate(self: Port, request: DuplicateRequest) DuplicateError!DuplicateResult {
        request.validate();
        const result = try self.duplicate_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn duplicateTo(self: Port, request: DuplicateToRequest) DuplicateError!void {
        request.validate();
        try self.duplicate_to_fn(self.context, request);
    }

    pub fn pipe(self: Port, request: PipeRequest) PipeError!PipeResult {
        request.validate();
        const result = try self.pipe_fn(self.context, request);
        result.validate();
        return result;
    }

    pub fn isTty(self: Port, request: IsTtyRequest) IsTtyError!IsTtyResult {
        request.validate();
        const result = try self.is_tty_fn(self.context, request);
        result.validate();
        return result;
    }
};

pub fn isValidDescriptor(descriptor: Descriptor) bool {
    return descriptor >= 0;
}

pub fn assertValidDescriptor(descriptor: Descriptor) void {
    std.debug.assert(isValidDescriptor(descriptor));
}

test "runtime fd open options map to boring POSIX flags" {
    const read_only: OpenOptions = .{};
    try std.testing.expectEqual(std.posix.ACCMODE.RDONLY, read_only.toPosixFlags().ACCMODE);

    const write_create: OpenOptions = .{
        .access = .write_only,
        .create = true,
        .truncate = true,
        .close_on_exec = true,
    };
    const write_flags = write_create.toPosixFlags();
    try std.testing.expectEqual(std.posix.ACCMODE.WRONLY, write_flags.ACCMODE);
    if (@hasField(std.posix.O, "CREAT")) try std.testing.expect(write_flags.CREAT);
    if (@hasField(std.posix.O, "TRUNC")) try std.testing.expect(write_flags.TRUNC);
    if (@hasField(std.posix.O, "CLOEXEC")) try std.testing.expect(write_flags.CLOEXEC);

    const read_write_append: OpenOptions = .{
        .access = .read_write,
        .create = true,
        .append = true,
    };
    const append_flags = read_write_append.toPosixFlags();
    try std.testing.expectEqual(std.posix.ACCMODE.RDWR, append_flags.ACCMODE);
    if (@hasField(std.posix.O, "APPEND")) try std.testing.expect(append_flags.APPEND);
}

test "runtime fd request validation accepts explicit low-level lifetimes" {
    const open_request = OpenRequest.init("rush-runtime-test", .{ .access = .read_write, .create = true });
    open_request.validate();

    const close_request = CloseRequest.init(0);
    close_request.validate();

    const duplicate_request = DuplicateRequest.init(1);
    duplicate_request.validate();

    const duplicate_to_request = DuplicateToRequest.init(1, 2);
    duplicate_to_request.validate();

    const pipe_result: PipeResult = .{ .read = 3, .write = 4 };
    pipe_result.validate();

    const is_tty_request = IsTtyRequest.init(0);
    is_tty_request.validate();

    const is_tty_result: IsTtyResult = .{ .is_tty = false };
    is_tty_result.validate();
}
