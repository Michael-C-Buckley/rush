//! Tokens produced by the shell lexer.

const std = @import("std");

const source = @import("source.zig");

pub const Kind = enum {
    word,
    newline,
    semicolon,
    double_semicolon,
    semicolon_ampersand,
    double_semicolon_ampersand,
    ampersand,
    ampersand_greater,
    ampersand_greater_greater,
    pipe,
    pipe_ampersand,
    pipe_pipe,
    ampersand_ampersand,
    bang,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    less,
    less_less,
    less_less_dash,
    less_less_less,
    less_ampersand,
    less_greater,
    greater,
    greater_greater,
    greater_ampersand,
    clobber,
    io_number,
    /// Processed here-document body emitted after the newline that starts
    /// it. The span covers the raw body including the delimiter line; the
    /// text holds the body with <tab> stripping already applied and the
    /// delimiter line excluded. `quoted` records a quoted delimiter, which
    /// suppresses expansion of the body.
    here_doc_body,
    /// A here-document body whose delimiter line was not found before the
    /// end of input; the body runs to the end of the input.
    here_doc_body_unterminated,
    eof,
};

pub const ReservedWord = enum {
    if_kw,
    then_kw,
    else_kw,
    elif_kw,
    fi_kw,
    do_kw,
    done_kw,
    case_kw,
    esac_kw,
    while_kw,
    until_kw,
    for_kw,
    in_kw,
    function_kw,
};

const ReservedWordMap = std.StaticStringMap(ReservedWord);

pub const reserved_words: ReservedWordMap = .initComptime(.{
    .{ "case", .case_kw },
    .{ "do", .do_kw },
    .{ "done", .done_kw },
    .{ "elif", .elif_kw },
    .{ "else", .else_kw },
    .{ "esac", .esac_kw },
    .{ "fi", .fi_kw },
    .{ "for", .for_kw },
    .{ "function", .function_kw },
    .{ "if", .if_kw },
    .{ "in", .in_kw },
    .{ "then", .then_kw },
    .{ "until", .until_kw },
    .{ "while", .while_kw },
});

pub fn lookupReservedWord(text: []const u8) ?ReservedWord {
    return reserved_words.get(text);
}

pub const Token = struct {
    kind: Kind,
    span: source.Span,
    text: []const u8 = "",
    reserved: ?ReservedWord = null,
    quoted: bool = false,

    pub fn validate(self: Token) void {
        self.span.validate();
        if (self.reserved != null) {
            std.debug.assert(self.kind == .word);
            std.debug.assert(!self.quoted);
            std.debug.assert(self.text.len != 0);
        }
        switch (self.kind) {
            .word, .io_number => std.debug.assert(self.text.len != 0),
            .here_doc_body, .here_doc_body_unterminated => {},
            else => std.debug.assert(!self.quoted),
        }
    }
};

test "reserved word lookup uses static map" {
    try std.testing.expectEqual(ReservedWord.if_kw, lookupReservedWord("if").?);
    try std.testing.expectEqual(ReservedWord.then_kw, lookupReservedWord("then").?);
    try std.testing.expectEqual(ReservedWord.done_kw, lookupReservedWord("done").?);
    try std.testing.expectEqual(@as(?ReservedWord, null), lookupReservedWord("printf"));
}
