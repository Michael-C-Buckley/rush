//! Semantic lowering from parser CST to execution-oriented IR.

const std = @import("std");
const parser = @import("parser.zig");

pub const WordRef = struct {
    span: parser.Span,
    text: []const u8,
};

pub const Redirection = struct {
    span: parser.Span,
    io_number: ?WordRef = null,
    operator: parser.TokenKind,
    target: ?WordRef = null,
};

pub const SimpleCommand = struct {
    span: parser.Span,
    assignments: []WordRef,
    argv: []WordRef,
    redirections: []Redirection,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    commands: []SimpleCommand,

    pub fn deinit(self: *Program) void {
        for (self.commands) |command| {
            self.allocator.free(command.assignments);
            self.allocator.free(command.argv);
            self.allocator.free(command.redirections);
        }
        self.allocator.free(self.commands);
        self.* = undefined;
    }
};

pub fn lowerSimpleCommands(allocator: std.mem.Allocator, parsed: parser.ParseResult) !Program {
    var commands: std.ArrayList(SimpleCommand) = .empty;
    errdefer {
        for (commands.items) |command| {
            allocator.free(command.assignments);
            allocator.free(command.argv);
            allocator.free(command.redirections);
        }
        commands.deinit(allocator);
    }

    for (parsed.nodes, 0..) |node, node_index| {
        if (node.kind != .simple_command) continue;
        const lowered = try lowerSimpleCommand(allocator, parsed, parser.NodeId.init(node_index));
        try commands.append(allocator, lowered);
    }

    return .{
        .allocator = allocator,
        .commands = try commands.toOwnedSlice(allocator),
    };
}

fn lowerSimpleCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, id: parser.NodeId) !SimpleCommand {
    const node = parsed.nodes[id.index()];
    std.debug.assert(node.kind == .simple_command);

    var assignments: std.ArrayList(WordRef) = .empty;
    errdefer assignments.deinit(allocator);
    var argv: std.ArrayList(WordRef) = .empty;
    errdefer argv.deinit(allocator);
    var redirections: std.ArrayList(Redirection) = .empty;
    errdefer redirections.deinit(allocator);

    for (parsed.nodeChildren(node)) |child| {
        const child_node_id = switch (child) {
            .node => |child_node| child_node,
            .token => continue,
        };
        const child_node = parsed.nodes[child_node_id.index()];
        switch (child_node.kind) {
            .assignment_word => try assignments.append(allocator, wordRef(parsed, child_node)),
            .command_word, .word => try argv.append(allocator, wordRef(parsed, child_node)),
            .redirection => try redirections.append(allocator, lowerRedirection(parsed, child_node)),
            else => {},
        }
    }

    return .{
        .span = node.span,
        .assignments = try assignments.toOwnedSlice(allocator),
        .argv = try argv.toOwnedSlice(allocator),
        .redirections = try redirections.toOwnedSlice(allocator),
    };
}

fn lowerRedirection(parsed: parser.ParseResult, node: parser.Node) Redirection {
    std.debug.assert(node.kind == .redirection);

    var result: Redirection = .{
        .span = node.span,
        .operator = .invalid,
    };

    for (parsed.nodeChildren(node)) |child| switch (child) {
        .token => |token_id| {
            const token = parsed.tokens[token_id.index()];
            if (token.kind.isRedirectOperator()) result.operator = token.kind;
        },
        .node => |node_id| {
            const child_node = parsed.nodes[node_id.index()];
            switch (child_node.kind) {
                .io_number => result.io_number = wordRef(parsed, child_node),
                .word => result.target = wordRef(parsed, child_node),
                else => {},
            }
        },
    };

    return result;
}

fn wordRef(parsed: parser.ParseResult, node: parser.Node) WordRef {
    std.debug.assert(node.token_end == node.token_start + 1);
    const token = parsed.tokens[node.token_start];
    return .{
        .span = node.span,
        .text = token.lexeme(parsed.source),
    };
}

test "lower simple command assignments argv and redirections" {
    var parsed = try parser.parse(std.testing.allocator, "FOO=bar echo hi 2>out", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.commands.len);
    const command = program.commands[0];
    try std.testing.expectEqualStrings("FOO=bar", command.assignments[0].text);
    try std.testing.expectEqualStrings("echo", command.argv[0].text);
    try std.testing.expectEqualStrings("hi", command.argv[1].text);
    try std.testing.expectEqual(@as(usize, 1), command.redirections.len);
    try std.testing.expectEqual(parser.TokenKind.greater, command.redirections[0].operator);
    try std.testing.expectEqualStrings("2", command.redirections[0].io_number.?.text);
    try std.testing.expectEqualStrings("out", command.redirections[0].target.?.text);
}

test "lower preserves multiple simple commands from lists and pipelines" {
    var parsed = try parser.parse(std.testing.allocator, "echo hi | grep h && pwd", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 3), program.commands.len);
    try std.testing.expectEqualStrings("echo", program.commands[0].argv[0].text);
    try std.testing.expectEqualStrings("grep", program.commands[1].argv[0].text);
    try std.testing.expectEqualStrings("pwd", program.commands[2].argv[0].text);
}
