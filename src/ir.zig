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

pub const Pipeline = struct {
    span: parser.Span,
    command_indexes: []usize,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    commands: []SimpleCommand,
    pipelines: []Pipeline,

    pub fn deinit(self: *Program) void {
        for (self.commands) |command| {
            for (command.assignments) |word| self.allocator.free(word.text);
            for (command.argv) |word| self.allocator.free(word.text);
            for (command.redirections) |redirection| {
                if (redirection.io_number) |word| self.allocator.free(word.text);
                if (redirection.target) |word| self.allocator.free(word.text);
            }
            self.allocator.free(command.assignments);
            self.allocator.free(command.argv);
            self.allocator.free(command.redirections);
        }
        for (self.pipelines) |pipeline| {
            self.allocator.free(pipeline.command_indexes);
        }
        self.allocator.free(self.commands);
        self.allocator.free(self.pipelines);
        self.* = undefined;
    }
};

pub fn lowerSimpleCommands(allocator: std.mem.Allocator, parsed: parser.ParseResult) !Program {
    var commands: std.ArrayList(SimpleCommand) = .empty;
    var pipelines: std.ArrayList(Pipeline) = .empty;
    const missing_command = std.math.maxInt(usize);
    const command_indexes_by_node = try allocator.alloc(usize, parsed.nodes.len);
    defer allocator.free(command_indexes_by_node);
    @memset(command_indexes_by_node, missing_command);

    errdefer {
        for (commands.items) |command| {
            freeCommand(allocator, command);
        }
        for (pipelines.items) |pipeline| {
            allocator.free(pipeline.command_indexes);
        }
        commands.deinit(allocator);
        pipelines.deinit(allocator);
    }

    for (parsed.nodes, 0..) |node, node_index| {
        if (node.kind != .simple_command) continue;
        command_indexes_by_node[node_index] = commands.items.len;
        const lowered = try lowerSimpleCommand(allocator, parsed, parser.NodeId.init(node_index));
        try commands.append(allocator, lowered);
    }

    for (parsed.nodes) |node| {
        if (node.kind != .pipeline) continue;
        const lowered = try lowerPipeline(allocator, parsed, node, command_indexes_by_node, missing_command);
        try pipelines.append(allocator, lowered);
    }

    return .{
        .allocator = allocator,
        .commands = try commands.toOwnedSlice(allocator),
        .pipelines = try pipelines.toOwnedSlice(allocator),
    };
}

fn lowerPipeline(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node, command_indexes_by_node: []const usize, missing_command: usize) !Pipeline {
    var command_indexes: std.ArrayList(usize) = .empty;
    errdefer command_indexes.deinit(allocator);

    for (parsed.nodeChildren(node)) |child| {
        const child_node_id = switch (child) {
            .node => |child_node| child_node,
            .token => continue,
        };
        const child_node = parsed.nodes[child_node_id.index()];
        if (child_node.kind != .simple_command) continue;
        const command_index = command_indexes_by_node[child_node_id.index()];
        std.debug.assert(command_index != missing_command);
        try command_indexes.append(allocator, command_index);
    }

    return .{
        .span = node.span,
        .command_indexes = try command_indexes.toOwnedSlice(allocator),
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
            .assignment_word => try assignments.append(allocator, try wordRef(allocator, parsed, child_node)),
            .command_word, .word => try argv.append(allocator, try wordRef(allocator, parsed, child_node)),
            .redirection => try redirections.append(allocator, try lowerRedirection(allocator, parsed, child_node)),
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

fn lowerRedirection(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !Redirection {
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
                .io_number => result.io_number = try wordRef(allocator, parsed, child_node),
                .word => result.target = try wordRef(allocator, parsed, child_node),
                else => {},
            }
        },
    };

    return result;
}

fn wordRef(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !WordRef {
    std.debug.assert(node.token_end == node.token_start + 1);
    const token = parsed.tokens[node.token_start];
    return .{
        .span = node.span,
        .text = try quoteRemove(allocator, token.lexeme(parsed.source)),
    };
}

fn freeCommand(allocator: std.mem.Allocator, command: SimpleCommand) void {
    for (command.assignments) |word| allocator.free(word.text);
    for (command.argv) |word| allocator.free(word.text);
    for (command.redirections) |redirection| {
        if (redirection.io_number) |word| allocator.free(word.text);
        if (redirection.target) |word| allocator.free(word.text);
    }
    allocator.free(command.assignments);
    allocator.free(command.argv);
    allocator.free(command.redirections);
}

pub fn quoteRemove(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {
                    try output.append(allocator, raw[index]);
                }
                if (index < raw.len) index += 1;
            },
            '"' => {
                index += 1;
                while (index < raw.len and raw[index] != '"') {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        index += 1;
                    }
                    try output.append(allocator, raw[index]);
                    index += 1;
                }
                if (index < raw.len) index += 1;
            },
            '\\' => {
                index += 1;
                if (index < raw.len) {
                    try output.append(allocator, raw[index]);
                    index += 1;
                }
            },
            else => |c| {
                try output.append(allocator, c);
                index += 1;
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

test "quote removal handles single double and backslash quoting" {
    const single = try quoteRemove(std.testing.allocator, "'hello world'");
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("hello world", single);

    const double = try quoteRemove(std.testing.allocator, "\"hello world\"");
    defer std.testing.allocator.free(double);
    try std.testing.expectEqualStrings("hello world", double);

    const backslash = try quoteRemove(std.testing.allocator, "hello\\ world");
    defer std.testing.allocator.free(backslash);
    try std.testing.expectEqualStrings("hello world", backslash);
}

test "lower removes quotes from execution words" {
    var parsed = try parser.parse(std.testing.allocator, "echo 'hello world' \"again\" a\\ b", .{});
    defer parsed.deinit();

    var program = try lowerSimpleCommands(std.testing.allocator, parsed);
    defer program.deinit();

    const command = program.commands[0];
    try std.testing.expectEqualStrings("echo", command.argv[0].text);
    try std.testing.expectEqualStrings("hello world", command.argv[1].text);
    try std.testing.expectEqualStrings("again", command.argv[2].text);
    try std.testing.expectEqualStrings("a b", command.argv[3].text);
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
    try std.testing.expectEqual(@as(usize, 2), program.pipelines.len);
    try std.testing.expectEqual(@as(usize, 2), program.pipelines[0].command_indexes.len);
    try std.testing.expectEqual(@as(usize, 0), program.pipelines[0].command_indexes[0]);
    try std.testing.expectEqual(@as(usize, 1), program.pipelines[0].command_indexes[1]);
    try std.testing.expectEqual(@as(usize, 1), program.pipelines[1].command_indexes.len);
    try std.testing.expectEqual(@as(usize, 2), program.pipelines[1].command_indexes[0]);
}
