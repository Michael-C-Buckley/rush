//! Owning shell instance parameterized by a concrete Host type.

const std = @import("std");

const eval = @import("eval.zig");
const lexer = @import("lexer.zig");
const memory = @import("memory.zig");
const parser = @import("parser.zig");
const result = @import("result.zig");
const source = @import("source.zig");
const state = @import("state.zig");

pub const InitOptions = struct {
    state: state.Options = .{},
    env: []const [*:0]const u8 = &.{},
    arg_zero: []const u8 = "rush",
    positionals: []const []const u8 = &.{},
};

pub fn Shell(comptime Host: type) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        env: []const [*:0]const u8,
        exec_envp_cache: ?[:null]const ?[*:0]const u8 = null,
        state: state.State,
        arenas: memory.Arenas,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, host: Host, options: InitOptions) Self {
            var shell: Self = .{
                .allocator = allocator,
                .host = host,
                .env = options.env,
                .state = state.State.init(allocator, options.state),
                .arenas = memory.Arenas.init(allocator),
            };
            shell.state.arg_zero = options.arg_zero;
            shell.state.positionals = options.positionals;
            return shell;
        }

        pub fn deinit(self: *Self) void {
            if (self.exec_envp_cache) |envp| self.allocator.free(envp);
            self.arenas.deinit();
            self.state.deinit();
            self.* = undefined;
        }

        pub fn execEnvp(self: *Self) ![:null]const ?[*:0]const u8 {
            if (self.exec_envp_cache) |envp| return envp;

            const envp = try self.allocator.allocSentinel(?[*:0]const u8, self.env.len, null);
            for (self.env, 0..) |entry, index| envp[index] = entry;
            self.exec_envp_cache = envp;
            return envp;
        }

        pub fn astAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.ast.allocator();
        }

        pub fn scratchAllocator(self: *Self) std.mem.Allocator {
            return self.arenas.scratchAllocator();
        }

        pub fn resetForTopLevelCommand(self: *Self) void {
            self.arenas.resetForTopLevelCommand();
        }

        pub fn beginScratchScope(self: *Self) !memory.ScratchScope {
            return self.arenas.beginScratchScope();
        }

        pub fn evalSource(self: *Self, src: source.Source) !result.EvalResult {
            src.validate();
            if (!self.sourceNeedsAliasAwareEvaluation(src)) return self.evalSourceChunk(src, src.text);
            if (src.text.len == 0) return self.evalSourceChunk(src, src.text);

            var start: usize = 0;
            var end: usize = 0;
            var last: result.EvalResult = .{};
            while (start < src.text.len) {
                end = nextLineEnd(src.text, end);
                const evaluated = self.evalSourceChunk(src, src.text[start..end]) catch |err| switch (err) {
                    error.ExpectedCommand,
                    error.ExpectedRedirectionTarget,
                    error.UnclosedCommandSubstitution,
                    error.UnclosedQuote,
                    error.UnexpectedToken,
                    => {
                        if (end < src.text.len) continue;
                        return err;
                    },
                    else => return err,
                };

                last = evaluated;
                if (last.flow != .normal) return last;
                start = end;
            }
            return last;
        }

        fn evalSourceChunk(self: *Self, src: source.Source, text: []const u8) !result.EvalResult {
            self.resetForTopLevelCommand();

            const chunk_src: source.Source = .{ .id = src.id, .kind = src.kind, .name = src.name, .text = text };

            const ast_allocator = self.astAllocator();
            const tokens = try lexer.lexWithAliases(ast_allocator, chunk_src, self.state);
            const program = try parser.parse(ast_allocator, chunk_src, tokens);
            program.validate();
            return eval.evalProgram(Host, self, program);
        }

        fn sourceNeedsAliasAwareEvaluation(self: *Self, src: source.Source) bool {
            return self.state.aliases.count() != 0 or std.mem.indexOf(u8, src.text, "alias") != null;
        }
    };
}

fn nextLineEnd(text: []const u8, start: usize) usize {
    std.debug.assert(start < text.len);
    const newline_index = std.mem.indexOfScalar(u8, text[start..], '\n') orelse return text.len;
    return start + newline_index + 1;
}

test "Shell caches exec environment pointer array" {
    const TestHost = struct {};
    const env = [_][*:0]const u8{ "A=1", "B=2" };

    var shell = Shell(TestHost).init(std.testing.allocator, .{}, .{ .env = &env });
    defer shell.deinit();

    const first = try shell.execEnvp();
    const second = try shell.execEnvp();

    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqualStrings("A=1", std.mem.span(first[0].?));
    try std.testing.expectEqualStrings("B=2", std.mem.span(first[1].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), first[2]);
}
