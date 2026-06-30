//! Tokens produced by the shell lexer.

const source = @import("source.zig");

pub const Kind = enum {
    word,
    assignment_word,
    newline,
    semicolon,
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
};
