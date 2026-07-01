//! Owning shell instance parameterized by a concrete Host type.

const std = @import("std");

const builtin = @import("builtin.zig");
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
    return ShellWithBuiltins(Host, builtin.default_registry);
}

pub fn ShellWithBuiltins(comptime Host: type, comptime builtin_registry: builtin.Registry) type {
    return struct {
        allocator: std.mem.Allocator,
        host: Host,
        env: []const [*:0]const u8,
        exec_envp_cache: ?[:null]const ?[*:0]const u8 = null,
        state: state.State,
        extensions: builtin_registry.ExtensionState,
        arenas: memory.Arenas,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, host: Host, options: InitOptions) Self {
            var shell: Self = .{
                .allocator = allocator,
                .host = host,
                .env = options.env,
                .state = state.State.init(allocator, options.state),
                .extensions = builtin_registry.ExtensionState.init(allocator),
                .arenas = memory.Arenas.init(allocator),
            };
            shell.state.putVariable(.{ .name = "PS4", .value = "+ " }) catch unreachable;
            shell.state.putVariable(.{ .name = "IFS", .value = " \t\n" }) catch unreachable;
            shell.state.arg_zero = options.arg_zero;
            shell.state.positionals = options.positionals;
            return shell;
        }

        pub fn deinit(self: *Self) void {
            if (self.exec_envp_cache) |envp| self.allocator.free(envp);
            self.arenas.deinit();
            self.extensions.deinit();
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

        pub fn lookupBuiltin(self: *Self, name: []const u8) ?builtin.Definition {
            const definition = builtin_registry.lookup(name) orelse return null;
            if (self.state.options.mode == .posix and (definition.id == .source or definition.id == .shopt)) return null;
            return definition;
        }

        pub fn evalExtensionBuiltin(
            self: *Self,
            definition: builtin.Definition,
            args: []const []const u8,
        ) !result.EvalResult {
            return self.extensions.eval(self, definition, args);
        }

        pub fn resetForTopLevelCommand(self: *Self) void {
            self.arenas.resetForTopLevelCommand();
        }

        pub fn beginScratchScope(self: *Self) !memory.ScratchScope {
            return self.arenas.beginScratchScope();
        }

        pub fn evalSource(self: *Self, src: source.Source) !result.EvalResult {
            return self.evalSourceWithReset(src, true);
        }

        pub fn evalSourceNested(self: *Self, src: source.Source) !result.EvalResult {
            return self.evalSourceWithReset(src, false);
        }

        fn evalSourceWithReset(self: *Self, src: source.Source, reset_chunks: bool) !result.EvalResult {
            src.validate();
            if (!self.sourceNeedsAliasAwareEvaluation(src)) return self.evalSourceChunk(src, src.text, reset_chunks, false);
            if (src.text.len == 0) return self.evalSourceChunk(src, src.text, reset_chunks, false);

            var start: usize = 0;
            var end: usize = 0;
            var last: result.EvalResult = .{};
            while (start < src.text.len) {
                end = nextLineEnd(src.text, end);
                const require_complete_here_docs = end < src.text.len;
                const evaluated = self.evalSourceChunk(
                    src,
                    src.text[start..end],
                    reset_chunks,
                    require_complete_here_docs,
                ) catch |err| switch (err) {
                    error.ExpectedCommand,
                    error.ExpectedRedirectionTarget,
                    error.IncompleteHereDoc,
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
                if (last.flow != .normal) {
                    if (!self.state.options.interactive or last.flow != .fatal) return last;
                    last.flow = .normal;
                    self.state.last_status = last.status;
                }
                start = end;
            }
            return last;
        }

        fn evalSourceChunk(
            self: *Self,
            src: source.Source,
            text: []const u8,
            reset: bool,
            require_complete_here_docs: bool,
        ) !result.EvalResult {
            if (reset) self.resetForTopLevelCommand();

            const chunk_src: source.Source = .{ .id = src.id, .kind = src.kind, .name = src.name, .text = text };

            const ast_allocator = self.astAllocator();
            const lexed = try lexer.lexWithAliasesSource(ast_allocator, chunk_src, self.state);
            const program = if (require_complete_here_docs)
                try parser.parseWithAliasesRequiringCompleteHereDocs(ast_allocator, lexed.source, lexed.tokens, self.state)
            else
                try parser.parseWithAliases(ast_allocator, lexed.source, lexed.tokens, self.state);
            program.validate();
            return eval.evalProgram(Host, self, program);
        }

        fn sourceNeedsAliasAwareEvaluation(self: *Self, src: source.Source) bool {
            return self.state.options.interactive or self.state.aliases.count() != 0 or
                std.mem.indexOf(u8, src.text, "alias") != null or
                (self.state.options.mode == .bash and std.mem.indexOf(u8, src.text, "shopt") != null);
        }
    };
}

fn nextLineEnd(text: []const u8, start: usize) usize {
    std.debug.assert(start < text.len);
    var cursor = start;
    while (cursor < text.len) {
        const newline_index = std.mem.indexOfScalar(u8, text[cursor..], '\n') orelse return text.len;
        const end = cursor + newline_index + 1;
        if (end < 2 or text[end - 2] != '\\') return end;
        cursor = end;
    }
    return text.len;
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

test "Shell initializes IFS from the shell default instead of the environment" {
    const TestHost = struct {};
    const env = [_][*:0]const u8{"IFS=abc"};

    var shell = Shell(TestHost).init(std.testing.allocator, .{}, .{ .env = &env });
    defer shell.deinit();

    try std.testing.expectEqualStrings(" \t\n", shell.state.getVariable("IFS").?.value);
}

test "ShellWithBuiltins uses the supplied compile-time builtin registry" {
    const TestHost = struct {};

    var shell = ShellWithBuiltins(TestHost, builtin.core_registry).init(std.testing.allocator, .{}, .{});
    defer shell.deinit();

    try std.testing.expect(shell.lookupBuiltin("printf") != null);
    try std.testing.expectEqual(@as(?builtin.Definition, null), shell.lookupBuiltin("abbr"));
}
