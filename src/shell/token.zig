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
    pipe,
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
    less_ampersand,
    less_greater,
    greater,
    greater_greater,
    greater_ampersand,
    clobber,
    io_number,
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
            else => {},
        }
    }
};
