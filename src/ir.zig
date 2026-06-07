//! Semantic lowering from parser CST to execution-oriented IR.

const std = @import("std");
const expand = @import("expand.zig");
const parser = @import("parser.zig");

pub const WordRef = struct {
    span: parser.Span,
    raw: []const u8,
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

pub const ListOp = enum {
    sequence,
    and_if,
    or_if,
};

pub const Pipeline = struct {
    span: parser.Span,
    command_indexes: []usize,
    op_before: ListOp = .sequence,
};

pub const IfCommand = struct {
    span: parser.Span,
    condition: []const u8,
    then_body: []const u8,
    else_body: ?[]const u8 = null,
};

pub const LoopKind = enum {
    while_loop,
    until_loop,
};

pub const LoopCommand = struct {
    span: parser.Span,
    kind: LoopKind,
    condition: []const u8,
    body: []const u8,
};

pub const ForCommand = struct {
    span: parser.Span,
    name: []const u8,
    words: []WordRef,
    body: []const u8,
};

pub const StatementKind = enum {
    pipeline,
    if_command,
    loop_command,
    for_command,
};

pub const Statement = struct {
    kind: StatementKind,
    index: usize,
    op_before: ListOp = .sequence,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    commands: []SimpleCommand,
    pipelines: []Pipeline,
    if_commands: []IfCommand = &.{},
    loop_commands: []LoopCommand = &.{},
    for_commands: []ForCommand = &.{},
    statements: []Statement = &.{},

    pub fn deinit(self: *Program) void {
        for (self.commands) |command| {
            for (command.assignments) |word| freeWord(self.allocator, word);
            for (command.argv) |word| freeWord(self.allocator, word);
            for (command.redirections) |redirection| {
                if (redirection.io_number) |word| freeWord(self.allocator, word);
                if (redirection.target) |word| freeWord(self.allocator, word);
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
        self.allocator.free(self.if_commands);
        self.allocator.free(self.loop_commands);
        for (self.for_commands) |command| {
            self.allocator.free(command.name);
            for (command.words) |word| freeWord(self.allocator, word);
            self.allocator.free(command.words);
        }
        self.allocator.free(self.for_commands);
        self.allocator.free(self.statements);
        self.* = undefined;
    }
};

pub fn lowerSimpleCommands(allocator: std.mem.Allocator, parsed: parser.ParseResult) !Program {
    var commands: std.ArrayList(SimpleCommand) = .empty;
    var pipelines: std.ArrayList(Pipeline) = .empty;
    var if_commands: std.ArrayList(IfCommand) = .empty;
    var loop_commands: std.ArrayList(LoopCommand) = .empty;
    var for_commands: std.ArrayList(ForCommand) = .empty;
    var statement_refs: std.ArrayList(LoweredStatementRef) = .empty;
    defer statement_refs.deinit(allocator);
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
        if_commands.deinit(allocator);
        loop_commands.deinit(allocator);
        for (for_commands.items) |command| freeForCommand(allocator, command);
        for_commands.deinit(allocator);
    }

    for (parsed.nodes, 0..) |node, node_index| {
        if (node.kind != .simple_command) continue;
        command_indexes_by_node[node_index] = commands.items.len;
        const lowered = try lowerSimpleCommand(allocator, parsed, parser.NodeId.init(node_index));
        try commands.append(allocator, lowered);
    }

    var previous_pipeline_token_end: ?usize = null;
    for (parsed.nodes) |node| {
        if (node.kind != .pipeline) continue;
        var lowered = try lowerPipeline(allocator, parsed, node, command_indexes_by_node, missing_command);
        if (previous_pipeline_token_end) |previous_end| {
            lowered.op_before = listOpBetween(parsed.tokens, previous_end, node.token_start);
        }
        previous_pipeline_token_end = node.token_end;
        try statement_refs.append(allocator, .{ .kind = .pipeline, .index = pipelines.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try pipelines.append(allocator, lowered);
    }

    for (parsed.nodes) |node| {
        if (node.kind != .if_command) continue;
        try statement_refs.append(allocator, .{ .kind = .if_command, .index = if_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try if_commands.append(allocator, lowerIfCommand(parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .loop_command) continue;
        try statement_refs.append(allocator, .{ .kind = .loop_command, .index = loop_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try loop_commands.append(allocator, lowerLoopCommand(parsed, node));
    }

    for (parsed.nodes) |node| {
        if (node.kind != .for_command) continue;
        try statement_refs.append(allocator, .{ .kind = .for_command, .index = for_commands.items.len, .token_start = node.token_start, .token_end = node.token_end });
        try for_commands.append(allocator, try lowerForCommand(allocator, parsed, node));
    }

    std.mem.sort(LoweredStatementRef, statement_refs.items, {}, lessThanStatementRef);
    var statements: std.ArrayList(Statement) = .empty;
    errdefer statements.deinit(allocator);
    var previous_statement_end: ?usize = null;
    for (statement_refs.items) |statement_ref| {
        var statement: Statement = .{ .kind = statement_ref.kind, .index = statement_ref.index };
        if (previous_statement_end) |previous_end| {
            statement.op_before = listOpBetween(parsed.tokens, previous_end, statement_ref.token_start);
        }
        previous_statement_end = statement_ref.token_end;
        try statements.append(allocator, statement);
    }

    return .{
        .allocator = allocator,
        .commands = try commands.toOwnedSlice(allocator),
        .pipelines = try pipelines.toOwnedSlice(allocator),
        .if_commands = try if_commands.toOwnedSlice(allocator),
        .loop_commands = try loop_commands.toOwnedSlice(allocator),
        .for_commands = try for_commands.toOwnedSlice(allocator),
        .statements = try statements.toOwnedSlice(allocator),
    };
}

const LoweredStatementRef = struct {
    kind: StatementKind,
    index: usize,
    token_start: usize,
    token_end: usize,
};

fn lessThanStatementRef(_: void, a: LoweredStatementRef, b: LoweredStatementRef) bool {
    return a.token_start < b.token_start;
}

fn lowerForCommand(allocator: std.mem.Allocator, parsed: parser.ParseResult, node: parser.Node) !ForCommand {
    std.debug.assert(node.kind == .for_command);
    var name_token: ?usize = null;
    var in_token: ?usize = null;
    var do_token: ?usize = null;
    var done_token: ?usize = null;
    var depth: usize = 0;

    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        const lexeme = token.lexeme(parsed.source);
        const reserved_position = isReservedPosition(parsed, node.token_start, token_index);
        if (reserved_position and std.mem.eql(u8, lexeme, "for")) {
            depth += 1;
        } else if (depth == 1 and name_token == null) {
            if (!std.mem.eql(u8, lexeme, "in") and !std.mem.eql(u8, lexeme, "do")) name_token = token_index;
        } else if (depth == 1 and std.mem.eql(u8, lexeme, "in") and do_token == null) {
            in_token = token_index;
        } else if (depth == 1 and do_token == null and reserved_position and std.mem.eql(u8, lexeme, "do")) {
            do_token = token_index;
        } else if (reserved_position and std.mem.eql(u8, lexeme, "done")) {
            if (depth == 1 and done_token == null) done_token = token_index;
            if (depth > 0) depth -= 1;
        }
    }

    const name_index = name_token orelse node.token_start;
    const do_index = do_token orelse node.token_end;
    const done_index = done_token orelse node.token_end;
    const word_start = if (in_token) |index| index + 1 else do_index;

    var words: std.ArrayList(WordRef) = .empty;
    errdefer {
        for (words.items) |word| freeWord(allocator, word);
        words.deinit(allocator);
    }
    for (word_start..do_index) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word) continue;
        try words.append(allocator, try wordRefFromToken(allocator, parsed, token_index));
    }

    const name = try allocator.dupe(u8, parsed.tokens[name_index].lexeme(parsed.source));
    errdefer allocator.free(name);

    return .{
        .span = node.span,
        .name = name,
        .words = try words.toOwnedSlice(allocator),
        .body = spanSlice(parsed, @min(do_index + 1, node.token_end), done_index),
    };
}

fn lowerLoopCommand(parsed: parser.ParseResult, node: parser.Node) LoopCommand {
    std.debug.assert(node.kind == .loop_command);
    const opener = parsed.tokens[node.token_start].lexeme(parsed.source);
    var do_token: ?usize = null;
    var done_token: ?usize = null;
    var depth: usize = 0;

    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word or !isReservedPosition(parsed, node.token_start, token_index)) continue;
        const lexeme = token.lexeme(parsed.source);
        if (std.mem.eql(u8, lexeme, "while") or std.mem.eql(u8, lexeme, "until")) {
            depth += 1;
        } else if (depth == 1 and do_token == null and std.mem.eql(u8, lexeme, "do")) {
            do_token = token_index;
        } else if (std.mem.eql(u8, lexeme, "done")) {
            if (depth == 1 and done_token == null) done_token = token_index;
            if (depth > 0) depth -= 1;
        }
    }

    const do_index = do_token orelse node.token_end;
    const done_index = done_token orelse node.token_end;
    return .{
        .span = node.span,
        .kind = if (std.mem.eql(u8, opener, "while")) .while_loop else .until_loop,
        .condition = spanSlice(parsed, node.token_start + 1, do_index),
        .body = spanSlice(parsed, @min(do_index + 1, node.token_end), done_index),
    };
}

fn lowerIfCommand(parsed: parser.ParseResult, node: parser.Node) IfCommand {
    std.debug.assert(node.kind == .if_command);
    var then_token: ?usize = null;
    var else_token: ?usize = null;
    var fi_token: ?usize = null;
    var depth: usize = 0;

    for (node.token_start..node.token_end) |token_index| {
        const token = parsed.tokens[token_index];
        if (token.kind != .word or !isReservedPosition(parsed, node.token_start, token_index)) continue;
        const lexeme = token.lexeme(parsed.source);
        if (std.mem.eql(u8, lexeme, "if")) {
            depth += 1;
        } else if (std.mem.eql(u8, lexeme, "fi")) {
            if (depth == 1 and fi_token == null) fi_token = token_index;
            if (depth > 0) depth -= 1;
        } else if (depth == 1 and then_token == null and std.mem.eql(u8, lexeme, "then")) {
            then_token = token_index;
        } else if (depth == 1 and else_token == null and (std.mem.eql(u8, lexeme, "else") or std.mem.eql(u8, lexeme, "elif"))) {
            else_token = token_index;
        }
    }

    const then_index = then_token orelse node.token_end;
    const fi_index = fi_token orelse node.token_end;
    const condition_start = node.token_start + 1;
    const condition_end = then_index;
    const body_start = @min(then_index + 1, node.token_end);
    const body_end = else_token orelse fi_index;
    const else_body = if (else_token) |else_index| blk: {
        if (std.mem.eql(u8, parsed.tokens[else_index].lexeme(parsed.source), "elif")) {
            break :blk spanSlice(parsed, else_index, fi_index);
        }
        break :blk spanSlice(parsed, @min(else_index + 1, node.token_end), fi_index);
    } else null;

    return .{
        .span = node.span,
        .condition = spanSlice(parsed, condition_start, condition_end),
        .then_body = spanSlice(parsed, body_start, body_end),
        .else_body = else_body,
    };
}

fn isReservedPosition(parsed: parser.ParseResult, start: usize, token_index: usize) bool {
    if (token_index == start) return true;
    var index = token_index;
    while (index > start) {
        index -= 1;
        const token = parsed.tokens[index];
        if (token.kind.isTrivia()) continue;
        if (isListSeparatorToken(token.kind)) return true;
        const lexeme = if (token.kind == .word) token.lexeme(parsed.source) else "";
        return std.mem.eql(u8, lexeme, "then") or std.mem.eql(u8, lexeme, "else") or std.mem.eql(u8, lexeme, "elif") or std.mem.eql(u8, lexeme, "do") or std.mem.eql(u8, lexeme, "in");
    }
    return true;
}

fn isListSeparatorToken(kind: parser.TokenKind) bool {
    return switch (kind) {
        .newline, .semicolon, .and_if, .or_if, .ampersand => true,
        else => false,
    };
}

fn spanSlice(parsed: parser.ParseResult, token_start: usize, token_end: usize) []const u8 {
    if (token_start >= token_end or token_start >= parsed.tokens.len) return "";
    const end_index = @min(token_end, parsed.tokens.len);
    const start = parsed.tokens[token_start].span.start;
    const end = parsed.tokens[end_index - 1].span.end;
    if (end < start) return "";
    return parsed.source[start..end];
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

fn listOpBetween(tokens: []const parser.Token, start: usize, end: usize) ListOp {
    for (tokens[start..end]) |token| {
        switch (token.kind) {
            .and_if => return .and_if,
            .or_if => return .or_if,
            else => {},
        }
    }
    return .sequence;
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
    return wordRefFromToken(allocator, parsed, node.token_start);
}

fn wordRefFromToken(allocator: std.mem.Allocator, parsed: parser.ParseResult, token_index: usize) !WordRef {
    const token = parsed.tokens[token_index];
    const raw = try allocator.dupe(u8, token.lexeme(parsed.source));
    errdefer allocator.free(raw);
    const text = try expand.expandWordScalar(allocator, raw, .{});
    return .{
        .span = token.span,
        .raw = raw,
        .text = text,
    };
}

fn freeForCommand(allocator: std.mem.Allocator, command: ForCommand) void {
    allocator.free(command.name);
    for (command.words) |word| freeWord(allocator, word);
    allocator.free(command.words);
}

fn freeCommand(allocator: std.mem.Allocator, command: SimpleCommand) void {
    for (command.assignments) |word| freeWord(allocator, word);
    for (command.argv) |word| freeWord(allocator, word);
    for (command.redirections) |redirection| {
        if (redirection.io_number) |word| freeWord(allocator, word);
        if (redirection.target) |word| freeWord(allocator, word);
    }
    allocator.free(command.assignments);
    allocator.free(command.argv);
    allocator.free(command.redirections);
}

fn freeWord(allocator: std.mem.Allocator, word: WordRef) void {
    allocator.free(word.raw);
    allocator.free(word.text);
}

test "quote removal handles single double and backslash quoting" {
    const single = try expand.quoteRemove(std.testing.allocator, "'hello world'");
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("hello world", single);

    const double = try expand.quoteRemove(std.testing.allocator, "\"hello world\"");
    defer std.testing.allocator.free(double);
    try std.testing.expectEqualStrings("hello world", double);

    const backslash = try expand.quoteRemove(std.testing.allocator, "hello\\ world");
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
