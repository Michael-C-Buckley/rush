//! Shell event registry for Rush extension hooks.

const std = @import("std");

pub const Name = enum {
    directory_change,
    prompt_prepare,
    prompt_async_start,
    prompt_async_end,
    completion_async_start,
    completion_async_end,
    job_start,
    job_end,
    timer_tick,

    pub fn parse(value: []const u8) ?Name {
        if (std.mem.eql(u8, value, "directory.change")) return .directory_change;
        if (std.mem.eql(u8, value, "prompt.prepare")) return .prompt_prepare;
        if (std.mem.eql(u8, value, "prompt.async.start")) return .prompt_async_start;
        if (std.mem.eql(u8, value, "prompt.async.end")) return .prompt_async_end;
        if (std.mem.eql(u8, value, "completion.async.start")) return .completion_async_start;
        if (std.mem.eql(u8, value, "completion.async.end")) return .completion_async_end;
        if (std.mem.eql(u8, value, "job.start")) return .job_start;
        if (std.mem.eql(u8, value, "job.end")) return .job_end;
        if (std.mem.eql(u8, value, "timer.tick")) return .timer_tick;
        return null;
    }

    pub fn text(self: Name) []const u8 {
        return switch (self) {
            .directory_change => "directory.change",
            .prompt_prepare => "prompt.prepare",
            .prompt_async_start => "prompt.async.start",
            .prompt_async_end => "prompt.async.end",
            .completion_async_start => "completion.async.start",
            .completion_async_end => "completion.async.end",
            .job_start => "job.start",
            .job_end => "job.end",
            .timer_tick => "timer.tick",
        };
    }
};

pub const Registration = struct {
    event: Name,
    name: []const u8,
    function_name: []const u8,
    priority: i32 = 0,
    every_ms: ?u64 = null,
    next_tick_ms: ?u64 = null,

    pub fn validate(self: Registration) void {
        assertValidRegistrationName(self.name);
        assertValidFunctionName(self.function_name);
        switch (self.event) {
            .timer_tick => std.debug.assert((self.every_ms orelse 0) != 0),
            .directory_change,
            .prompt_prepare,
            .prompt_async_start,
            .prompt_async_end,
            .completion_async_start,
            .completion_async_end,
            .job_start,
            .job_end,
            => {
                std.debug.assert(self.every_ms == null);
                std.debug.assert(self.next_tick_ms == null);
            },
        }
        if (self.next_tick_ms != null) std.debug.assert(self.every_ms != null);
    }

    pub fn clone(self: Registration, allocator: std.mem.Allocator) !Registration {
        self.validate();
        const owned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(owned_name);
        const owned_function_name = try allocator.dupe(u8, self.function_name);
        errdefer allocator.free(owned_function_name);
        return .{
            .event = self.event,
            .name = owned_name,
            .function_name = owned_function_name,
            .priority = self.priority,
            .every_ms = self.every_ms,
            .next_tick_ms = self.next_tick_ms,
        };
    }

    pub fn deinit(self: *Registration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.function_name);
        self.* = undefined;
    }
};

pub const Removal = struct {
    event: Name,
    name: []const u8,

    pub fn validate(self: Removal) void {
        assertValidRegistrationName(self.name);
    }

    pub fn clone(self: Removal, allocator: std.mem.Allocator) !Removal {
        self.validate();
        return .{ .event = self.event, .name = try allocator.dupe(u8, self.name) };
    }

    pub fn deinit(self: *Removal, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const HookCall = struct {
    name: []const u8,
    function_name: []const u8,
    priority: i32,
    every_ms: ?u64 = null,

    pub fn deinit(self: *HookCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.function_name);
        self.* = undefined;
    }
};

pub fn orderedHookCalls(
    allocator: std.mem.Allocator,
    registrations: []const Registration,
    event_name: Name,
) ![]HookCall {
    var calls: std.ArrayList(HookCall) = .empty;
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    for (registrations) |registration| {
        registration.validate();
        if (registration.event != event_name) continue;
        const owned_name = try allocator.dupe(u8, registration.name);
        errdefer allocator.free(owned_name);
        const owned_function_name = try allocator.dupe(u8, registration.function_name);
        errdefer allocator.free(owned_function_name);
        try calls.append(allocator, .{
            .name = owned_name,
            .function_name = owned_function_name,
            .priority = registration.priority,
            .every_ms = registration.every_ms,
        });
    }
    std.mem.sort(HookCall, calls.items, {}, lessThanHookCall);
    return calls.toOwnedSlice(allocator);
}

pub fn freeHookCalls(allocator: std.mem.Allocator, calls: []HookCall) void {
    for (calls) |*call| call.deinit(allocator);
    allocator.free(calls);
}

fn lessThanHookCall(_: void, left: HookCall, right: HookCall) bool {
    if (left.priority != right.priority) return left.priority < right.priority;
    return std.mem.lessThan(u8, left.name, right.name);
}

pub fn nextTimerDelayMs(registrations: []Registration, now_ms: u64) ?u64 {
    var next_delay: ?u64 = null;
    for (registrations) |*registration| {
        registration.validate();
        if (registration.event != .timer_tick) continue;
        const every_ms = registration.every_ms.?;
        const next_tick_ms = registration.next_tick_ms orelse now_ms +| every_ms;
        registration.next_tick_ms = next_tick_ms;
        const delay = if (next_tick_ms <= now_ms) 0 else next_tick_ms - now_ms;
        if (next_delay == null or delay < next_delay.?) next_delay = delay;
    }
    return next_delay;
}

pub fn dueTimerHookCalls(
    allocator: std.mem.Allocator,
    registrations: []Registration,
    now_ms: u64,
) ![]HookCall {
    var calls: std.ArrayList(HookCall) = .empty;
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    for (registrations) |*registration| {
        registration.validate();
        if (registration.event != .timer_tick) continue;
        const every_ms = registration.every_ms.?;
        const next_tick_ms = registration.next_tick_ms orelse now_ms +| every_ms;
        registration.next_tick_ms = next_tick_ms;
        if (next_tick_ms > now_ms) continue;
        registration.next_tick_ms = now_ms +| every_ms;

        const owned_name = try allocator.dupe(u8, registration.name);
        errdefer allocator.free(owned_name);
        const owned_function_name = try allocator.dupe(u8, registration.function_name);
        errdefer allocator.free(owned_function_name);
        try calls.append(allocator, .{
            .name = owned_name,
            .function_name = owned_function_name,
            .priority = registration.priority,
            .every_ms = every_ms,
        });
    }
    std.mem.sort(HookCall, calls.items, {}, lessThanHookCall);
    return calls.toOwnedSlice(allocator);
}

pub fn assertValidRegistrationName(name: []const u8) void {
    std.debug.assert(isValidRegistrationName(name));
}

pub fn isValidRegistrationName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.') continue;
        return false;
    }
    return true;
}

pub fn assertValidFunctionName(name: []const u8) void {
    std.debug.assert(isValidFunctionName(name));
}

pub fn isValidFunctionName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

test "event names parse and render" {
    try std.testing.expectEqual(Name.directory_change, Name.parse("directory.change").?);
    try std.testing.expectEqual(Name.prompt_prepare, Name.parse("prompt.prepare").?);
    try std.testing.expectEqual(Name.prompt_async_start, Name.parse("prompt.async.start").?);
    try std.testing.expectEqual(Name.prompt_async_end, Name.parse("prompt.async.end").?);
    try std.testing.expectEqual(Name.completion_async_start, Name.parse("completion.async.start").?);
    try std.testing.expectEqual(Name.completion_async_end, Name.parse("completion.async.end").?);
    try std.testing.expectEqual(Name.job_start, Name.parse("job.start").?);
    try std.testing.expectEqual(Name.job_end, Name.parse("job.end").?);
    try std.testing.expectEqual(Name.timer_tick, Name.parse("timer.tick").?);
    try std.testing.expectEqual(@as(?Name, null), Name.parse("chpwd"));
    try std.testing.expectEqualStrings("directory.change", Name.directory_change.text());
}

test "orderedHookCalls sorts by priority then registration name" {
    const registrations = [_]Registration{
        .{ .event = .directory_change, .name = "z", .function_name = "hook_z", .priority = 20 },
        .{ .event = .directory_change, .name = "a", .function_name = "hook_a", .priority = 20 },
        .{ .event = .directory_change, .name = "first", .function_name = "hook_first", .priority = 10 },
        .{ .event = .prompt_prepare, .name = "other", .function_name = "hook_other", .priority = 0 },
    };
    const calls = try orderedHookCalls(std.testing.allocator, &registrations, .directory_change);
    defer freeHookCalls(std.testing.allocator, calls);

    try std.testing.expectEqual(@as(usize, 3), calls.len);
    try std.testing.expectEqualStrings("first", calls[0].name);
    try std.testing.expectEqualStrings("a", calls[1].name);
    try std.testing.expectEqualStrings("z", calls[2].name);
}

test "timer hooks become due after their interval" {
    var registrations = [_]Registration{
        .{ .event = .timer_tick, .name = "clock", .function_name = "on_clock", .every_ms = 1000 },
    };

    try std.testing.expectEqual(@as(?u64, 1000), nextTimerDelayMs(&registrations, 10));
    try std.testing.expectEqual(@as(?u64, 1), nextTimerDelayMs(&registrations, 1009));

    const calls = try dueTimerHookCalls(std.testing.allocator, &registrations, 1010);
    defer freeHookCalls(std.testing.allocator, calls);

    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("clock", calls[0].name);
    try std.testing.expectEqualStrings("on_clock", calls[0].function_name);
    try std.testing.expectEqual(@as(?u64, 2010), registrations[0].next_tick_ms);
}
