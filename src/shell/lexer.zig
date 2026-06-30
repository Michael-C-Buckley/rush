//! Minimal lexer for the rewrite bootstrap.

const std = @import("std");

const source_mod = @import("source.zig");
const state_mod = @import("state.zig");
const token = @import("token.zig");

pub const LexError = error{};

pub fn lex(allocator: std.mem.Allocator, src: source_mod.Source) std.mem.Allocator.Error![]const token.Token {
    src.validate();
    var lexer: Lexer = .{ .allocator = allocator, .source = src, .position = .{ .source_id = src.id } };
    return lexer.lex();
}

pub fn lexWithAliases(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    shell_state: state_mod.State,
) std.mem.Allocator.Error![]const token.Token {
    const tokens = try lex(allocator, src);
    const expanded = try aliasExpandedSource(allocator, src, tokens, shell_state) orelse return tokens;
    const expanded_src: source_mod.Source = .{ .id = src.id, .kind = src.kind, .name = src.name, .text = expanded };
    return lex(allocator, expanded_src);
}

fn aliasExpandedSource(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    shell_state: state_mod.State,
) std.mem.Allocator.Error!?[]const u8 {
    if (shell_state.aliases.count() == 0) return null;

    var output: std.ArrayList(u8) = .empty;
    var changed = false;
    var cursor: usize = 0;
    var command_position = true;
    var skip_redirection_target = false;

    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        try output.appendSlice(allocator, src.text[cursor..tok.span.start]);
        cursor = tok.span.end;

        if (skip_redirection_target and tok.kind == .word) {
            skip_redirection_target = false;
            try output.appendSlice(allocator, src.text[tok.span.start..tok.span.end]);
            continue;
        }

        if (tok.kind == .word) {
            if (tok.reserved) |reserved| {
                command_position = reservedWordStartsCommandList(reserved);
                try output.appendSlice(allocator, src.text[tok.span.start..tok.span.end]);
                continue;
            }
            if (command_position and !tok.quoted and !isAssignmentWord(tok.text)) {
                if (shell_state.getAlias(tok.text)) |alias| {
                    try output.appendSlice(allocator, alias.value);
                    command_position = aliasEndsWithBlank(alias.value);
                    changed = true;
                    continue;
                }
            }
            if (command_position and isAssignmentWord(tok.text)) {
                command_position = true;
            } else {
                command_position = false;
            }
            try output.appendSlice(allocator, src.text[tok.span.start..tok.span.end]);
            continue;
        }

        if (isRedirectionOperatorKind(tok.kind)) {
            skip_redirection_target = true;
            try output.appendSlice(allocator, src.text[tok.span.start..tok.span.end]);
            continue;
        }

        command_position = tokenStartsCommandPosition(tok.kind);
        try output.appendSlice(allocator, src.text[tok.span.start..tok.span.end]);
    }

    if (!changed) return null;
    try output.appendSlice(allocator, src.text[cursor..]);
    const expanded: []const u8 = try output.toOwnedSlice(allocator);
    return expanded;
}

fn reservedWordStartsCommandList(reserved: token.ReservedWord) bool {
    return switch (reserved) {
        .if_kw, .then_kw, .else_kw, .elif_kw, .do_kw, .while_kw, .until_kw => true,
        else => false,
    };
}

fn tokenStartsCommandPosition(kind: token.Kind) bool {
    return switch (kind) {
        .newline,
        .semicolon,
        .ampersand,
        .pipe,
        .pipe_pipe,
        .ampersand_ampersand,
        .bang,
        .left_paren,
        .left_brace,
        => true,
        else => false,
    };
}

fn isRedirectionOperatorKind(kind: token.Kind) bool {
    return switch (kind) {
        .less,
        .less_less,
        .less_less_dash,
        .less_ampersand,
        .less_greater,
        .greater,
        .greater_greater,
        .greater_ampersand,
        .clobber,
        => true,
        else => false,
    };
}

fn isAssignmentWord(text: []const u8) bool {
    const equals_index = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    const name = text[0..equals_index];
    if (name.len == 0) return false;
    if (!isNameStart(name[0])) return false;
    for (name[1..]) |byte| if (!isNameContinue(byte)) return false;
    return true;
}

fn aliasEndsWithBlank(value: []const u8) bool {
    if (value.len == 0) return false;
    return switch (value[value.len - 1]) {
        ' ', '\t', '\n' => true,
        else => false,
    };
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    position: source_mod.Position,

    fn lex(self: *Lexer) std.mem.Allocator.Error![]const token.Token {
        var tokens: std.ArrayList(token.Token) = .empty;
        errdefer tokens.deinit(self.allocator);

        while (!self.atEnd()) {
            switch (self.peek()) {
                ' ', '\t', '\r' => self.advanceOne(),
                '\n' => try self.appendSingle(&tokens, .newline),
                '\\' => if (self.peekNextIs('\n'))
                    self.skipLineContinuation()
                else if (self.startsIoNumber())
                    try self.appendIoNumber(&tokens)
                else
                    try self.appendWord(&tokens),
                ';' => try self.appendSemicolon(&tokens),
                '&' => try self.appendAmpersand(&tokens),
                '|' => try self.appendPipe(&tokens),
                '!' => try self.appendSingle(&tokens, .bang),
                '(' => try self.appendSingle(&tokens, .left_paren),
                ')' => try self.appendSingle(&tokens, .right_paren),
                '{' => try self.appendSingle(&tokens, .left_brace),
                '}' => try self.appendSingle(&tokens, .right_brace),
                '<', '>' => try self.appendRedirectionOperator(&tokens),
                '#' => self.skipComment(),
                else => if (self.startsIoNumber()) try self.appendIoNumber(&tokens) else try self.appendWord(&tokens),
            }
        }

        try tokens.append(self.allocator, .{ .kind = .eof, .span = source_mod.Span.init(self.position, self.position.byte_offset) });
        return tokens.toOwnedSlice(self.allocator);
    }

    fn atEnd(self: Lexer) bool {
        return self.position.byte_offset >= self.source.text.len;
    }

    fn peek(self: Lexer) u8 {
        std.debug.assert(!self.atEnd());
        return self.source.text[self.position.byte_offset];
    }

    fn advanceOne(self: *Lexer) void {
        std.debug.assert(!self.atEnd());
        self.position.advance(self.source.text[self.position.byte_offset .. self.position.byte_offset + 1]);
    }

    fn appendSingle(self: *Lexer, tokens: *std.ArrayList(token.Token), kind: token.Kind) !void {
        const start = self.position;
        self.advanceOne();
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }

    fn appendSemicolon(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        self.advanceOne();
        const kind: token.Kind = if (!self.atEnd()) switch (self.peek()) {
            ';' => kind: {
                self.advanceOne();
                if (!self.atEnd() and self.peek() == '&') {
                    self.advanceOne();
                    break :kind .double_semicolon_ampersand;
                }
                break :kind .double_semicolon;
            },
            '&' => kind: {
                self.advanceOne();
                break :kind .semicolon_ampersand;
            },
            else => .semicolon,
        } else .semicolon;
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }

    fn appendAmpersand(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        self.advanceOne();
        const kind: token.Kind = if (!self.atEnd() and self.peek() == '&') kind: {
            self.advanceOne();
            break :kind .ampersand_ampersand;
        } else .ampersand;
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }

    fn appendPipe(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        self.advanceOne();
        const kind: token.Kind = if (!self.atEnd() and self.peek() == '|') kind: {
            self.advanceOne();
            break :kind .pipe_pipe;
        } else .pipe;
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }

    fn appendRedirectionOperator(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        const first = self.peek();
        self.advanceOne();
        const kind: token.Kind = switch (first) {
            '<' => if (!self.atEnd()) switch (self.peek()) {
                '<' => kind: {
                    self.advanceOne();
                    if (!self.atEnd() and self.peek() == '-') {
                        self.advanceOne();
                        break :kind .less_less_dash;
                    }
                    break :kind .less_less;
                },
                '&' => kind: {
                    self.advanceOne();
                    break :kind .less_ampersand;
                },
                '>' => kind: {
                    self.advanceOne();
                    break :kind .less_greater;
                },
                else => .less,
            } else .less,
            '>' => if (!self.atEnd()) switch (self.peek()) {
                '>' => kind: {
                    self.advanceOne();
                    break :kind .greater_greater;
                },
                '&' => kind: {
                    self.advanceOne();
                    break :kind .greater_ampersand;
                },
                '|' => kind: {
                    self.advanceOne();
                    break :kind .clobber;
                },
                else => .greater,
            } else .greater,
            else => unreachable,
        };
        const tok: token.Token = .{ .kind = kind, .span = source_mod.Span.init(start, self.position.byte_offset) };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }

    fn appendIoNumber(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        const start_offset = self.position.byte_offset;
        while (!self.atEnd() and isDigit(self.peek())) self.advanceOne();
        const tok: token.Token = .{
            .kind = .io_number,
            .span = source_mod.Span.init(start, self.position.byte_offset),
            .text = self.source.text[start_offset..self.position.byte_offset],
        };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }

    fn skipComment(self: *Lexer) void {
        while (!self.atEnd() and self.peek() != '\n') self.advanceOne();
    }

    fn skipLineContinuation(self: *Lexer) void {
        std.debug.assert(self.peek() == '\\');
        std.debug.assert(self.peekNextIs('\n'));
        self.advanceOne();
        self.advanceOne();
    }

    fn appendWord(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        const start_offset = self.position.byte_offset;
        var quoted = false;
        var quote: ?u8 = null;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (quote) |delimiter| {
                if (delimiter == '"' and byte == '\\') {
                    self.advanceOne();
                    if (!self.atEnd()) self.advanceOne();
                    continue;
                }
                if (delimiter == '"' and byte == '$' and self.peekNextIs('(')) {
                    self.advanceOne();
                    self.advanceOne();
                    self.skipCommandSubstitution();
                    continue;
                }
                if (delimiter == '"' and byte == '$' and self.peekNextIs('{')) {
                    self.advanceOne();
                    self.advanceOne();
                    self.skipBracedParameter();
                    continue;
                }
                if (delimiter == '"' and byte == '`') {
                    self.advanceOne();
                    self.skipBackquoteSubstitution();
                    continue;
                }
                if (byte == delimiter) quote = null;
                self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quoted = true;
                quote = byte;
                self.advanceOne();
                continue;
            }
            if (byte == '\\') {
                quoted = true;
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(') and self.peekByte(2) == '(') {
                self.advanceOne();
                self.advanceOne();
                self.advanceOne();
                self.skipArithmeticExpansion();
                continue;
            }
            if (byte == '$' and self.peekNextIs('\'')) {
                quoted = true;
                self.advanceOne();
                self.advanceOne();
                self.skipDollarSingleQuote();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                self.advanceOne();
                self.advanceOne();
                self.skipCommandSubstitution();
                continue;
            }
            if (byte == '$' and self.peekNextIs('{')) {
                self.advanceOne();
                self.advanceOne();
                self.skipBracedParameter();
                continue;
            }
            if (byte == '`') {
                self.advanceOne();
                self.skipBackquoteSubstitution();
                continue;
            }
            if (isWordTerminator(byte)) break;
            self.advanceOne();
        }
        const text = self.source.text[start_offset..self.position.byte_offset];
        const tok: token.Token = .{
            .kind = .word,
            .span = source_mod.Span.init(start, self.position.byte_offset),
            .text = text,
            .reserved = if (quoted) null else token.lookupReservedWord(text),
            .quoted = quoted,
        };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }

    fn startsIoNumber(self: Lexer) bool {
        if (!isDigit(self.peek())) return false;
        var offset = self.position.byte_offset;
        while (offset < self.source.text.len and isDigit(self.source.text[offset])) offset += 1;
        while (offset + 1 < self.source.text.len and self.source.text[offset] == '\\' and
            self.source.text[offset + 1] == '\n')
        {
            offset += 2;
        }
        return offset < self.source.text.len and isRedirectionStart(self.source.text[offset]);
    }

    fn peekNextIs(self: Lexer, byte: u8) bool {
        const next = self.position.byte_offset + 1;
        return next < self.source.text.len and self.source.text[next] == byte;
    }

    fn peekByte(self: Lexer, offset: usize) ?u8 {
        const index = self.position.byte_offset + offset;
        if (index >= self.source.text.len) return null;
        return self.source.text[index];
    }

    fn skipArithmeticExpansion(self: *Lexer) void {
        var paren_depth: usize = 0;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                const quote = byte;
                self.advanceOne();
                while (!self.atEnd() and self.peek() != quote) self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '(') {
                paren_depth += 1;
                self.advanceOne();
                continue;
            }
            if (byte == ')') {
                if (paren_depth != 0) {
                    paren_depth -= 1;
                    self.advanceOne();
                } else {
                    self.advanceOne();
                    if (!self.atEnd() and self.peek() == ')') self.advanceOne();
                    return;
                }
                continue;
            }
            self.advanceOne();
        }
    }

    fn skipCommandSubstitution(self: *Lexer) void {
        var depth: usize = 1;
        var quote: ?u8 = null;
        while (!self.atEnd() and depth != 0) {
            if (self.startsReservedWord("case")) {
                self.skipCaseCommandText();
                continue;
            }
            const byte = self.peek();
            if (quote) |delimiter| {
                if (byte == delimiter) quote = null;
                self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                depth += 1;
                self.advanceOne();
                self.advanceOne();
                continue;
            }
            if (byte == ')') depth -= 1;
            self.advanceOne();
        }
    }

    fn skipCaseCommandText(self: *Lexer) void {
        self.advanceBytes("case".len);
        while (!self.atEnd()) {
            if (self.startsReservedWord("esac")) {
                self.advanceBytes("esac".len);
                return;
            }

            const byte = self.peek();
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                const quote = byte;
                self.advanceOne();
                while (!self.atEnd() and self.peek() != quote) self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                self.advanceOne();
                self.advanceOne();
                self.skipCommandSubstitution();
                continue;
            }
            self.advanceOne();
        }
    }

    fn startsReservedWord(self: Lexer, word: []const u8) bool {
        const index = self.position.byte_offset;
        const text = self.source.text;
        if (index + word.len > text.len) return false;
        if (!std.mem.eql(u8, text[index..][0..word.len], word)) return false;
        if (index != 0 and isNameContinue(text[index - 1])) return false;
        if (index + word.len < text.len and isNameContinue(text[index + word.len])) return false;
        return true;
    }

    fn advanceBytes(self: *Lexer, count: usize) void {
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) self.advanceOne();
    }

    fn skipBracedParameter(self: *Lexer) void {
        var quote: ?u8 = null;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (quote) |delimiter| {
                if (byte == delimiter) quote = null;
                self.advanceOne();
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                self.advanceOne();
                continue;
            }
            self.advanceOne();
            if (byte == '}') break;
        }
    }

    fn skipBackquoteSubstitution(self: *Lexer) void {
        while (!self.atEnd()) {
            const byte = self.peek();
            self.advanceOne();
            if (byte == '\\' and !self.atEnd()) {
                self.advanceOne();
                continue;
            }
            if (byte == '`') break;
        }
    }

    fn skipDollarSingleQuote(self: *Lexer) void {
        while (!self.atEnd()) {
            const byte = self.peek();
            self.advanceOne();
            if (byte == '\\' and !self.atEnd()) {
                self.advanceOne();
                continue;
            }
            if (byte == '\'') break;
        }
    }
};

fn isWordTerminator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')', '{', '}', '<', '>' => true,
        else => false,
    };
}

fn isDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or isDigit(byte);
}

fn isRedirectionStart(byte: u8) bool {
    return byte == '<' or byte == '>';
}

test "lexer tokenizes colon command" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = ":" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings(":", tokens[0].text);
    try std.testing.expectEqual(token.Kind.eof, tokens[1].kind);
}

test "lexer tokenizes AND-OR operators" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "true&&false||! true" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("true", tokens[0].text);
    try std.testing.expectEqual(token.Kind.ampersand_ampersand, tokens[1].kind);
    try std.testing.expectEqual(token.Kind.word, tokens[2].kind);
    try std.testing.expectEqualStrings("false", tokens[2].text);
    try std.testing.expectEqual(token.Kind.pipe_pipe, tokens[3].kind);
    try std.testing.expectEqual(token.Kind.bang, tokens[4].kind);
    try std.testing.expectEqual(token.Kind.word, tokens[5].kind);
    try std.testing.expectEqualStrings("true", tokens[5].text);
    try std.testing.expectEqual(token.Kind.eof, tokens[6].kind);
}

test "lexer marks reserved words" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "if true; then :; fi" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.ReservedWord.if_kw, tokens[0].reserved.?);
    try std.testing.expectEqual(@as(?token.ReservedWord, null), tokens[1].reserved);
    try std.testing.expectEqual(token.ReservedWord.then_kw, tokens[3].reserved.?);
    try std.testing.expectEqual(token.ReservedWord.fi_kw, tokens[6].reserved.?);
}

test "lexer marks quoted words as non-reserved" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "'if'" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expect(tokens[0].quoted);
    try std.testing.expectEqual(@as(?token.ReservedWord, null), tokens[0].reserved);
}

test "lexer keeps quoted spaces inside words" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \"hello world\"" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("printf", tokens[0].text);
    try std.testing.expectEqual(token.Kind.word, tokens[1].kind);
    try std.testing.expect(tokens[1].quoted);
    try std.testing.expectEqualStrings("\"hello world\"", tokens[1].text);
}

test "lexer treats backslash escaped quote as word text" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf \\'3" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(token.Kind.word, tokens[1].kind);
    try std.testing.expectEqualStrings("\\'3", tokens[1].text);
    try std.testing.expect(tokens[1].quoted);
}

test "lexer removes top-level line continuations before comments" {
    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text =
        \\printf foo \
        \\# comment
        \\printf bar
        ,
    };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqualStrings("printf", tokens[0].text);
    try std.testing.expectEqualStrings("foo", tokens[1].text);
    try std.testing.expectEqual(token.Kind.newline, tokens[2].kind);
    try std.testing.expectEqualStrings("printf", tokens[3].text);
    try std.testing.expectEqualStrings("bar", tokens[4].text);
}

test "lexer keeps dollar single quoted words separate" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf $'\\'' $'\\\\'" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqualStrings("$'\\''", tokens[1].text);
    try std.testing.expect(tokens[1].quoted);
    try std.testing.expectEqualStrings("$'\\\\'", tokens[2].text);
    try std.testing.expect(tokens[2].quoted);
}

test "lexer keeps command substitutions inside words" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=$(printf a; printf b)" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("x=$(printf a; printf b)", tokens[0].text);
    try std.testing.expectEqual(token.Kind.eof, tokens[1].kind);
}
