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
                '#' => self.skipComment(),
                else => try self.appendWord(&tokens),
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

    fn skipComment(self: *Lexer) void {
        while (!self.atEnd() and self.peek() != '\n') self.advanceOne();
    }

    fn appendWord(self: *Lexer, tokens: *std.ArrayList(token.Token)) !void {
        const start = self.position;
        const start_offset = self.position.byte_offset;
        while (!self.atEnd() and !isWordTerminator(self.peek())) self.advanceOne();
        const text = self.source.text[start_offset..self.position.byte_offset];
        const tok: token.Token = .{ .kind = .word, .span = source_mod.Span.init(start, self.position.byte_offset), .text = text };
        tok.validate();
        try tokens.append(self.allocator, tok);
    }
};

fn isWordTerminator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', ';' => true,
        else => false,
    };
}

test "lexer tokenizes colon command" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = ":" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings(":", tokens[0].text);
    try std.testing.expectEqual(token.Kind.eof, tokens[1].kind);
}
