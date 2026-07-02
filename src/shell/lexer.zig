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

pub const AliasLexResult = struct {
    source: source_mod.Source,
    tokens: []const token.Token,
};

pub fn lexWithAliases(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    shell_state: state_mod.State,
) std.mem.Allocator.Error![]const token.Token {
    return (try lexWithAliasesSource(allocator, src, shell_state)).tokens;
}

pub fn lexWithAliasesSource(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    shell_state: state_mod.State,
) std.mem.Allocator.Error!AliasLexResult {
    var current_src = src;
    var seen_sources: std.ArrayList([]const u8) = .empty;
    while (true) {
        const tokens = try lex(allocator, current_src);
        const expanded = try aliasExpandedSource(allocator, current_src, tokens, shell_state) orelse return .{
            .source = current_src,
            .tokens = tokens,
        };
        if (std.mem.eql(u8, expanded, current_src.text)) return .{
            .source = current_src,
            .tokens = try lex(allocator, current_src),
        };
        for (seen_sources.items) |seen| {
            if (std.mem.eql(u8, expanded, seen)) return .{
                .source = current_src,
                .tokens = try lex(allocator, current_src),
            };
        }
        try seen_sources.append(allocator, current_src.text);
        current_src = .{ .id = src.id, .kind = src.kind, .name = src.name, .text = expanded };
    }
}

fn aliasExpandedSource(
    allocator: std.mem.Allocator,
    src: source_mod.Source,
    tokens: []const token.Token,
    shell_state: state_mod.State,
) std.mem.Allocator.Error!?[]const u8 {
    if (shell_state.aliases.count() == 0) return null;
    if (!aliasesEnabled(shell_state)) return null;

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

pub fn aliasesEnabled(shell_state: state_mod.State) bool {
    return shell_state.options.mode == .posix or shell_state.options.interactive or shell_state.options.expand_aliases;
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
        .right_paren,
        .left_brace,
        .here_doc_body,
        .here_doc_body_unterminated,
        => true,
        else => false,
    };
}

fn isRedirectionOperatorKind(kind: token.Kind) bool {
    return switch (kind) {
        .less,
        .less_less,
        .less_less_dash,
        .less_less_less,
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
    const name_end = if (equals_index > 0 and text[equals_index - 1] == '+') equals_index - 1 else equals_index;
    const name = text[0..name_end];
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

const HereDocDelimiter = struct {
    text: []const u8,
    quoted: bool,
};

/// Performs quote removal on a raw here-document delimiter word.
///
/// Expansions inside the delimiter are unspecified by POSIX and are kept
/// as literal text here.
fn hereDocDelimiter(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!HereDocDelimiter {
    if (std.mem.indexOfAny(u8, raw, "'\"\\") == null) return .{ .text = raw, .quoted = false };

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var quoted = false;
    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\'' => {
                quoted = true;
                index += 1;
                while (index < raw.len and raw[index] != '\'') : (index += 1) {
                    try text.append(allocator, raw[index]);
                }
                if (index < raw.len) index += 1;
            },
            '"' => {
                quoted = true;
                index += 1;
                while (index < raw.len and raw[index] != '"') {
                    if (raw[index] == '\\' and index + 1 < raw.len) {
                        switch (raw[index + 1]) {
                            '$', '`', '"', '\\' => index += 1,
                            '\n' => {
                                index += 2;
                                continue;
                            },
                            else => {},
                        }
                    }
                    try text.append(allocator, raw[index]);
                    index += 1;
                }
                if (index < raw.len) index += 1;
            },
            '\\' => {
                if (index + 1 < raw.len and raw[index + 1] == '\n') {
                    index += 2;
                    continue;
                }
                quoted = true;
                index += 1;
                if (index < raw.len) {
                    try text.append(allocator, raw[index]);
                    index += 1;
                }
            },
            else => {
                try text.append(allocator, raw[index]);
                index += 1;
            },
        }
    }
    return .{ .text = try text.toOwnedSlice(allocator), .quoted = quoted };
}

fn stripLeadingTabs(line: []const u8) []const u8 {
    var index: usize = 0;
    while (index < line.len and line[index] == '\t') index += 1;
    return line[index..];
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    position: source_mod.Position,
    pending_here_docs: std.ArrayList(PendingHereDoc) = .empty,
    here_doc_delimiter_expected: ?bool = null,

    const PendingHereDoc = struct {
        delimiter: []const u8,
        strip_tabs: bool,
        quoted: bool,
    };

    fn lex(self: *Lexer) std.mem.Allocator.Error![]const token.Token {
        var tokens: std.ArrayList(token.Token) = .empty;
        errdefer tokens.deinit(self.allocator);
        defer self.pending_here_docs.deinit(self.allocator);

        while (!self.atEnd()) {
            const count_before = tokens.items.len;
            try self.lexOne(&tokens);
            try self.trackHereDocs(&tokens, count_before);
        }
        // Here-document bodies delimited by end of input (no trailing
        // newline) still get body tokens so the parser never scans text.
        if (self.pending_here_docs.items.len != 0) try self.lexHereDocBodies(&tokens);

        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        try tokens.append(self.allocator, .{ .kind = .eof, .span = source_mod.Span.init(self.position, self.position.byte_offset) });
        return tokens.toOwnedSlice(self.allocator);
    }

    fn lexOne(self: *Lexer, tokens: *std.ArrayList(token.Token)) std.mem.Allocator.Error!void {
        switch (self.peek()) {
            ' ', '\t', '\r' => self.advanceOne(),
            '\n' => try self.appendSingle(tokens, .newline),
            '\\' => if (self.peekNextIs('\n'))
                self.skipLineContinuation()
            else if (self.startsIoNumber())
                try self.appendIoNumber(tokens)
            else
                try self.appendWord(tokens),
            ';' => try self.appendSemicolon(tokens),
            '&' => try self.appendAmpersand(tokens),
            '|' => try self.appendPipe(tokens),
            '!' => if (self.peekByte(1)) |next|
                if (isWordTerminator(next)) try self.appendSingle(tokens, .bang) else try self.appendWord(tokens)
            else
                try self.appendSingle(tokens, .bang),
            '(' => try self.appendSingle(tokens, .left_paren),
            ')' => try self.appendSingle(tokens, .right_paren),
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            '{' => if (self.nextStartsWord()) try self.appendWord(tokens) else try self.appendSingle(tokens, .left_brace),
            // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
            '}' => if (self.nextStartsWord()) try self.appendWord(tokens) else try self.appendSingle(tokens, .right_brace),
            '<', '>' => try self.appendRedirectionOperator(tokens),
            '#' => self.skipComment(),
            else => if (self.startsIoNumber()) try self.appendIoNumber(tokens) else try self.appendWord(tokens),
        }
    }

    /// Follows here-document operators through the token stream: the word
    /// after `<<` or `<<-` is the delimiter, and the bodies for every
    /// pending here-document start on the line after the next newline
    /// token. Bodies are lexed immediately as dedicated tokens so no body
    /// byte is ever tokenized as command text (or alias-substituted).
    fn trackHereDocs(
        self: *Lexer,
        tokens: *std.ArrayList(token.Token),
        first_new: usize,
    ) std.mem.Allocator.Error!void {
        var index = first_new;
        while (index < tokens.items.len) : (index += 1) {
            const tok = tokens.items[index];
            if (self.here_doc_delimiter_expected) |strip_tabs| {
                self.here_doc_delimiter_expected = null;
                if (tok.kind == .word) {
                    const raw = self.source.text[tok.span.start..tok.span.end];
                    const delimiter = try hereDocDelimiter(self.allocator, raw);
                    try self.pending_here_docs.append(self.allocator, .{
                        .delimiter = delimiter.text,
                        .strip_tabs = strip_tabs,
                        .quoted = delimiter.quoted,
                    });
                }
            }
            switch (tok.kind) {
                .less_less => self.here_doc_delimiter_expected = false,
                .less_less_dash => self.here_doc_delimiter_expected = true,
                .newline => if (self.pending_here_docs.items.len != 0) {
                    try self.lexHereDocBodies(tokens);
                },
                else => {},
            }
        }
    }

    fn lexHereDocBodies(self: *Lexer, tokens: *std.ArrayList(token.Token)) std.mem.Allocator.Error!void {
        for (self.pending_here_docs.items) |pending| {
            try self.lexHereDocBody(tokens, pending);
        }
        self.pending_here_docs.clearRetainingCapacity();
    }

    fn lexHereDocBody(
        self: *Lexer,
        tokens: *std.ArrayList(token.Token),
        pending: PendingHereDoc,
    ) std.mem.Allocator.Error!void {
        const text = self.source.text;
        const start = self.position;

        var stripped: std.ArrayList(u8) = .empty;
        errdefer stripped.deinit(self.allocator);
        var offset = start.byte_offset;
        var body_end = offset;
        var terminated = false;
        var continued = false;
        while (offset <= text.len) {
            const line_start = offset;
            const newline_index = std.mem.findScalarPos(u8, text, offset, '\n');
            const line_end = newline_index orelse text.len;
            const next_offset = if (newline_index) |newline| newline + 1 else text.len;
            const raw_line = text[line_start..line_end];
            const strip = pending.strip_tabs and !continued;
            const candidate = if (strip) stripLeadingTabs(raw_line) else raw_line;
            if (!continued and std.mem.eql(u8, candidate, pending.delimiter)) {
                terminated = true;
                offset = next_offset;
                break;
            }

            if (pending.strip_tabs) {
                try stripped.appendSlice(self.allocator, candidate);
                if (newline_index != null) try stripped.append(self.allocator, '\n');
            }
            continued = !pending.quoted and candidate.len != 0 and candidate[candidate.len - 1] == '\\';
            body_end = next_offset;
            if (next_offset == offset) break;
            offset = next_offset;
        }
        if (!terminated) offset = text.len;

        const body: []const u8 = if (pending.strip_tabs)
            try stripped.toOwnedSlice(self.allocator)
        else
            text[start.byte_offset..body_end];
        self.position.advance(text[start.byte_offset..offset]);

        const tok: token.Token = .{
            .kind = if (terminated) .here_doc_body else .here_doc_body_unterminated,
            .span = source_mod.Span.init(start, offset),
            .text = body,
            .quoted = pending.quoted,
        };
        tok.validate();
        try tokens.append(self.allocator, tok);
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
                    if (!self.atEnd() and self.peek() == '<') {
                        self.advanceOne();
                        break :kind .less_less_less;
                    }
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
                if (!self.peekNextIs('\n')) quoted = true;
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
            if (byte == '[' and self.skipBracketExpression()) continue;
            if (isWordTerminator(byte)) break;
            self.advanceOne();
        }
        const raw_text = self.source.text[start_offset..self.position.byte_offset];
        const text = try self.wordText(raw_text);
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

    fn wordText(self: Lexer, raw_text: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, raw_text, "\\\n") == null) return raw_text;

        var output: std.ArrayList(u8) = .empty;
        var index: usize = 0;
        var quote: ?u8 = null;
        while (index < raw_text.len) {
            const byte = raw_text[index];
            if (quote) |delimiter| {
                if (byte == delimiter) quote = null;
                if (delimiter == '"' and byte == '\\' and index + 1 < raw_text.len) {
                    const escaped = raw_text[index + 1];
                    if (escaped == '\n') {
                        index += 2;
                        continue;
                    }
                    if (doubleQuoteEscapes(escaped)) {
                        try output.append(self.allocator, byte);
                        try output.append(self.allocator, escaped);
                        index += 2;
                        continue;
                    }
                }
                if (delimiter == '"' and byte == '$' and index + 1 < raw_text.len and raw_text[index + 1] == '(') {
                    const close_index = scanCommandSubstitutionText(raw_text, index + 1) orelse raw_text.len - 1;
                    try output.appendSlice(self.allocator, raw_text[index .. close_index + 1]);
                    index = close_index + 1;
                    continue;
                }
                try output.append(self.allocator, byte);
                index += 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                try output.append(self.allocator, byte);
                index += 1;
                continue;
            }
            if (byte == '\\') {
                if (index + 1 < raw_text.len and raw_text[index + 1] == '\n') {
                    index += 2;
                    continue;
                }
                try output.append(self.allocator, byte);
                index += 1;
                if (index < raw_text.len) {
                    try output.append(self.allocator, raw_text[index]);
                    index += 1;
                }
                continue;
            }
            if (byte == '$' and index + 1 < raw_text.len and raw_text[index + 1] == '(') {
                const close_index = scanCommandSubstitutionText(raw_text, index + 1) orelse raw_text.len - 1;
                try output.appendSlice(self.allocator, raw_text[index .. close_index + 1]);
                index = close_index + 1;
                continue;
            }
            try output.append(self.allocator, byte);
            index += 1;
        }
        return output.toOwnedSlice(self.allocator);
    }

    fn scanCommandSubstitutionText(text: []const u8, open_index: usize) ?usize {
        std.debug.assert(text[open_index] == '(');
        var depth: usize = 1;
        var quote: ?u8 = null;
        var index = open_index + 1;
        while (index < text.len and depth != 0) {
            const byte = text[index];
            if (quote) |delimiter| {
                if (byte == delimiter) quote = null;
                index += 1;
                continue;
            }
            if (byte == '\\') {
                index += if (index + 1 < text.len) 2 else 1;
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                index += 1;
                continue;
            }
            if (byte == '$' and index + 1 < text.len and text[index + 1] == '(') {
                depth += 1;
                index += 2;
                continue;
            }
            if (byte == '(') depth += 1;
            if (byte == ')') {
                depth -= 1;
                if (depth == 0) return index;
            }
            index += 1;
        }
        return null;
    }

    fn doubleQuoteEscapes(byte: u8) bool {
        return switch (byte) {
            '$', '`', '"', '\\', '\n' => true,
            else => false,
        };
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

    fn nextStartsWord(self: Lexer) bool {
        if (self.peekByte(1)) |next| return !isWordTerminator(next);
        return false;
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
            if (byte == '#' and self.commentStartsAtCurrentOffset()) {
                self.skipComment();
                continue;
            }
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
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
            if (byte == '(') depth += 1;
            if (byte == ')') depth -= 1;
            self.advanceOne();
        }
    }

    fn commentStartsAtCurrentOffset(self: Lexer) bool {
        const offset = self.position.byte_offset;
        if (offset == 0) return true;
        return switch (self.source.text[offset - 1]) {
            ' ', '\t', '\n', '\r', ';', '&', '|', '(', ')' => true,
            else => false,
        };
    }

    fn skipCaseCommandText(self: *Lexer) void {
        self.advanceBytes("case".len);
        while (!self.atEnd()) {
            if (self.startsReservedWord("esac")) {
                self.advanceBytes("esac".len);
                return;
            }

            const byte = self.peek();
            if (byte == '#' and self.commentStartsAtCurrentOffset()) {
                self.skipComment();
                continue;
            }
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
        var depth: usize = 1;
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
            if (byte == '\\') {
                self.advanceOne();
                if (!self.atEnd()) self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('{')) {
                depth += 1;
                self.advanceOne();
                self.advanceOne();
                continue;
            }
            if (byte == '$' and self.peekNextIs('(')) {
                self.advanceOne();
                self.advanceOne();
                self.skipCommandSubstitution();
                continue;
            }
            self.advanceOne();
            if (byte == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
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

    fn skipBracketExpression(self: *Lexer) bool {
        std.debug.assert(!self.atEnd());
        std.debug.assert(self.peek() == '[');

        var index = self.position.byte_offset + 1;
        if (index >= self.source.text.len or isWordTerminator(self.source.text[index])) return false;
        if (index < self.source.text.len and (self.source.text[index] == '!' or self.source.text[index] == '^')) {
            index += 1;
        }
        var saw_member = false;
        while (index < self.source.text.len) {
            const byte = self.source.text[index];
            if (byte == '\\' and index + 1 < self.source.text.len) {
                index += 2;
                saw_member = true;
                continue;
            }
            if (byte == ']' and saw_member) {
                self.advanceBytes(index + 1 - self.position.byte_offset);
                return true;
            }
            if (isWordTerminator(byte)) return false;
            if (byte == '\n' or byte == '\r') return false;
            saw_member = true;
            index += 1;
        }
        return false;
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
        ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')', '<', '>' => true,
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

test "lexer keeps exclamation mark words together" {
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "test x != y; ! false" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("test", tokens[0].text);
    try std.testing.expectEqual(token.Kind.word, tokens[1].kind);
    try std.testing.expectEqualStrings("x", tokens[1].text);
    try std.testing.expectEqual(token.Kind.word, tokens[2].kind);
    try std.testing.expectEqualStrings("!=", tokens[2].text);
    try std.testing.expectEqual(token.Kind.word, tokens[3].kind);
    try std.testing.expectEqualStrings("y", tokens[3].text);
    try std.testing.expectEqual(token.Kind.semicolon, tokens[4].kind);
    try std.testing.expectEqual(token.Kind.bang, tokens[5].kind);
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
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
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

test "lexer removes line continuations inside word tokens" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text =
        \\f\
        \\(){ :; }
        ,
    };
    const tokens = try lex(arena.allocator(), src);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("f", tokens[0].text);
    try std.testing.expect(!tokens[0].quoted);
    try std.testing.expectEqual(token.Kind.left_paren, tokens[1].kind);
}

test "lexer preserves escaped backslash before double quoted newline" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "printf \"\\\\\n\"",
    };
    const tokens = try lex(arena.allocator(), src);

    try std.testing.expectEqual(token.Kind.word, tokens[1].kind);
    try std.testing.expectEqualStrings("\"\\\\\n\"", tokens[1].text);
    try std.testing.expect(tokens[1].quoted);
}

test "lexer preserves single quoted newline after escaped single quote" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "-c",
        .text = "v='a'\\''\\\\\\\nZ'",
    };
    const tokens = try lex(arena.allocator(), src);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("v='a'\\''\\\\\\\nZ'", tokens[0].text);
    try std.testing.expect(tokens[0].quoted);
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
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "x=$(printf a; printf b)" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(token.Kind.word, tokens[0].kind);
    try std.testing.expectEqualStrings("x=$(printf a; printf b)", tokens[0].text);
    try std.testing.expectEqual(token.Kind.eof, tokens[1].kind);
}

test "lexer keeps brace characters inside word tokens" {
    // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
    const src: source_mod.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = "printf {} x{} {}x a{b}" };
    const tokens = try lex(std.testing.allocator, src);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqualStrings("{}", tokens[1].text);
    try std.testing.expectEqualStrings("x{}", tokens[2].text);
    try std.testing.expectEqualStrings("{}x", tokens[3].text);
    try std.testing.expectEqualStrings("a{b}", tokens[4].text);
}

test "lexer emits here-document bodies as dedicated tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<-E\n\tbody\n\tE\necho next\n",
    };
    const tokens = try lex(allocator, src);

    var body: ?token.Token = null;
    for (tokens) |tok| {
        if (tok.kind == .here_doc_body) body = tok;
        // No body byte may leak into ordinary word tokens.
        if (tok.kind == .word) try std.testing.expect(!std.mem.eql(u8, tok.text, "body"));
    }
    const body_token = body orelse return error.ExpectedHereDocBody;
    try std.testing.expectEqualStrings("body\n", body_token.text);
    try std.testing.expect(!body_token.quoted);
    // The span covers the raw body including tabs and the delimiter line.
    try std.testing.expectEqualStrings("\tbody\n\tE\n", src.text[body_token.span.start..body_token.span.end]);
}

test "alias substitution copies here-document bodies verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var shell_state = state_mod.State.init(std.testing.allocator, .{ .mode = .posix });
    defer shell_state.deinit();
    try shell_state.putAlias(.{ .name = "hi", .value = "printf hi" });

    const src: source_mod.Source = .{
        .id = 1,
        .kind = .script_file,
        .name = "test",
        .text = "cat <<E\nhi\nE\nhi\n",
    };
    const lexed = try lexWithAliasesSource(allocator, src, shell_state);

    // The command-position `hi` after the body expands; the body line does not.
    try std.testing.expectEqualStrings("cat <<E\nhi\nE\nprintf hi\n", lexed.source.text);
}
