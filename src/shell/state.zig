//! Mutable shell state for direct evaluation.

const std = @import("std");

const ast = @import("ast.zig");
const host = @import("../host.zig");
const memory = @import("memory.zig");
const result = @import("result.zig");

pub const Mode = enum {
    posix,
    bash,
};

pub const Options = struct {
    mode: Mode = .bash,
    errexit: bool = false,
    nounset: bool = false,
    noglob: bool = false,
    noexec: bool = false,
    xtrace: bool = false,
    monitor: bool = false,
    interactive: bool = false,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    exported: bool = false,
    readonly: bool = false,

    pub fn validate(self: Variable) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const Function = struct {
    name: []const u8,
    source_text: []const u8,
    definition: ast.FunctionDefinition,

    pub fn validate(self: Function) void {
        std.debug.assert(self.name.len != 0);
        std.debug.assert(self.source_text.len != 0);
        self.definition.validate();
        std.debug.assert(std.mem.eql(u8, self.name, self.definition.name));
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    definition_arena: memory.Arena,
    options: Options = .{},
    variables: std.StringHashMapUnmanaged(Variable) = .empty,
    functions: std.StringHashMapUnmanaged(Function) = .empty,
    last_status: result.ExitStatus = 0,
    last_background_pid: ?host.Pid = null,
    loop_depth: usize = 0,
    arg_zero: []const u8 = "rush",
    positionals: []const []const u8 = &.{},
    owned_positionals: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, options: Options) State {
        return .{
            .allocator = allocator,
            .definition_arena = memory.Arena.init(allocator),
            .options = options,
        };
    }

    pub fn deinit(self: *State) void {
        var iterator = self.variables.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.value);
        }
        self.variables.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.freeOwnedPositionals();
        self.definition_arena.deinit();
        self.* = undefined;
    }

    pub fn definitionAllocator(self: *State) std.mem.Allocator {
        return self.definition_arena.allocator();
    }

    pub fn getVariable(self: State, name: []const u8) ?Variable {
        std.debug.assert(name.len != 0);
        return self.variables.get(name);
    }

    pub fn putVariable(self: *State, variable: Variable) !void {
        variable.validate();
        const owned_value = try self.allocator.dupe(u8, variable.value);
        errdefer self.allocator.free(owned_value);

        if (self.variables.getPtr(variable.name)) |existing| {
            if (existing.readonly and !variable.readonly) return error.ReadonlyVariable;
            self.allocator.free(existing.value);
            existing.value = owned_value;
            existing.exported = variable.exported;
            existing.readonly = variable.readonly;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, variable.name);
        errdefer self.allocator.free(owned_name);

        try self.variables.put(self.allocator, owned_name, .{
            .name = owned_name,
            .value = owned_value,
            .exported = variable.exported,
            .readonly = variable.readonly,
        });
    }

    pub fn removeVariable(self: *State, name: []const u8) void {
        std.debug.assert(name.len != 0);
        if (self.variables.fetchRemove(name)) |entry| {
            self.allocator.free(entry.value.name);
            self.allocator.free(entry.value.value);
        }
    }

    pub fn setPositionals(self: *State, positionals: []const []const u8) !void {
        const owned = try self.allocator.alloc([]const u8, positionals.len);
        errdefer self.allocator.free(owned);

        var copied: usize = 0;
        errdefer for (owned[0..copied]) |item| self.allocator.free(item);

        for (positionals, 0..) |positional, index| {
            owned[index] = try self.allocator.dupe(u8, positional);
            copied += 1;
        }

        self.freeOwnedPositionals();
        self.owned_positionals = owned;
        self.positionals = owned;
    }

    fn freeOwnedPositionals(self: *State) void {
        for (self.owned_positionals) |positional| self.allocator.free(positional);
        self.allocator.free(self.owned_positionals);
        self.owned_positionals = &.{};
    }

    pub fn getFunction(self: State, name: []const u8) ?Function {
        std.debug.assert(name.len != 0);
        return self.functions.get(name);
    }

    /// Installs a function definition whose name, source text, and AST storage
    /// have already been allocated from `definitionAllocator()`.
    pub fn putPersistentFunction(self: *State, function: Function) !void {
        function.validate();
        try self.functions.put(self.allocator, function.name, function);
    }

    pub fn removeFunction(self: *State, name: []const u8) void {
        std.debug.assert(name.len != 0);
        _ = self.functions.remove(name);
    }
};

test "State replaces variable values without losing the binding" {
    var shell_state = State.init(std.testing.allocator, .{});
    defer shell_state.deinit();

    try shell_state.putVariable(.{ .name = "x", .value = "old" });
    try shell_state.putVariable(.{ .name = "x", .value = "new", .exported = true });

    const variable = shell_state.getVariable("x") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("x", variable.name);
    try std.testing.expectEqualStrings("new", variable.value);
    try std.testing.expect(variable.exported);
}
