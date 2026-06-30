//! Owning shell instance parameterized by a concrete Host type.

const std = @import("std");

const eval = @import("eval.zig");
const lexer = @import("lexer.zig");
const memory = @import("memory.zig");
const parser = @import("parser.zig");
const result = @import("result.zig");
const source = @import("source.zig");
const state = @import("state.zig");

pub fn Shell(comptime Host: type) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        state: state.State,
        arenas: memory.Arenas,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, host: Host, options: state.Options) Self {
            return .{
                .allocator = allocator,
                .host = host,
                .state = state.State.init(allocator, options),
                .arenas = memory.Arenas.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.arenas.deinit();
            self.state.deinit();
            self.* = undefined;
        }

        pub fn astAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.ast.allocator();
        }

        pub fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.scratch.allocator();
        }

        pub fn resetForTopLevelCommand(self: *Self) void {
            self.arenas.resetForTopLevelCommand();
        }

        pub fn resetScratch(self: *Self) void {
            self.arenas.resetScratch();
        }

        pub fn evalSource(self: *Self, src: source.Source) !result.EvalResult {
            src.validate();
            self.resetForTopLevelCommand();

            const ast_allocator = self.astAllocator();
            const tokens = try lexer.lex(ast_allocator, src);
            const program = try parser.parse(ast_allocator, src, tokens);
            program.validate();
            return eval.evalProgram(Host, self, program);
        }
    };
}
