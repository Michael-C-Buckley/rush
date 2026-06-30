//! Minimal lexer for the rewrite bootstrap.

const std = @import("std");

const source_mod = @import("source.zig");
const token = @import("token.zig");

pub const LexError = error{};

pub fn lex(allocator: std.mem.Allocator, src: source_mod.Source) std.mem.Allocator.Error![]const token.Token {
    src.validate();
    var lexer: Lexer = .{ .allocator = allocator, .source = src, .position = .{ .source_id = src.id } };
    return lexer.lex();
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
                ';' => try self.appendSingle(&tokens, .semicolon),
                '&' => try self.appendAmpersand(&tokens),
                '|' => try self.appendPipe(&tokens),
                '!' => try self.appendSingle(&tokens, .bang),
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

    fn appendWord(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        const start_offset = self.position.byte_offset;
        var quoted = false;
        var quote: ?u8 = null;
        while (!self.atEnd()) {
            const byte = self.peek();
            if (quote) |delimiter| {
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
            if (byte == '$' and self.peekNextIs('(')) {
                self.advanceOne();
                self.advanceOne();
                self.skipCommandSubstitution();
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
        return offset < self.source.text.len and isRedirectionStart(self.source.text[offset]);
    }

    fn peekNextIs(self: Lexer, byte: u8) bool {
        const next = self.position.byte_offset + 1;
        return next < self.source.text.len and self.source.text[next] == byte;
    }

    fn skipCommandSubstitution(self: *Lexer) void {
        var depth: usize = 1;
        var quote: ?u8 = null;
        while (!self.atEnd() and depth != 0) {
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
};

fn isWordTerminator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', ';', '&', '|', '!', '<', '>' => true,
        else => false,
    };
}

fn isDigit(byte: u8) bool {
    return switch (byte) {
        '0'...'9' => true,
        else => false,
    };
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

test "lexer keeps command substitutions inside words" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=$(printf a; printf b)" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("x=$(printf a; printf b)", tokens[0].text);
    try std.testing.expectEqual(token.Kind.eof, tokens[1].kind);
}
