//! Root module for `zig build fuzz`. Imports only the parser and its
//! dependencies so fuzz coverage instrumentation (and the coverage totals the
//! fuzzer reports) measure parser code rather than the whole shell binary.

const std = @import("std");

pub const compat = @import("compat.zig");
pub const parser = @import("parser.zig");

test "fuzz parser" {
    try std.testing.fuzz({}, parser.fuzzParser, .{ .corpus = &parser.fuzz_corpus_entries });
}

test {
    std.testing.refAllDecls(compat);
    std.testing.refAllDecls(parser);
}
