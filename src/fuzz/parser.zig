//! Parser fuzz target.
//!
//! Run with `zig build fuzz-parser --fuzz` for continuous fuzzing, or with a
//! bounded limit such as `zig build fuzz-parser --fuzz=10000`.

const std = @import("std");

pub const parser = @import("rush-parser");

test "fuzz parser" {
    try std.testing.fuzz({}, parser.fuzzParser, .{ .corpus = &parser.fuzz_corpus_entries });
}
