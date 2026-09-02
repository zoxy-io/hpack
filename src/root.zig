//! hpack — HPACK (RFC 7541): header compression for HTTP/2, and the two
//! primitives HTTP/3 borrows from it.
//!
//! The whole RFC lives here: the Huffman code, the prefixed integer, the static
//! and dynamic tables, and the field line representations either side of them.
//! `Decoder` and `Encoder` are the entry points.
//!
//! It is a package of its own rather than a directory inside
//! [zoxy-io/h2](https://github.com/zoxy-io/h2) because QPACK adopts two of its
//! pieces unchanged — RFC 9204 section 4.1.1 takes RFC 7541 section 5.1's
//! integer, and section 4.1.2 takes section 5.2's Huffman code with the same
//! 257-symbol table — so [zoxy-io/h3](https://github.com/zoxy-io/h3) builds
//! against `huffman` and `integer` and nothing else here. The alternative was a
//! second 900-line copy of a vectorised Huffman decoder in the same
//! organisation, where a bug fixed in one stays live in the other.
//!
//! What QPACK does *not* borrow is everything above those two: its static table
//! is a different table indexed from zero, and its dynamic table is addressed
//! relative to an insert count HPACK has no notion of. Those are h3's.
//!
//! `huffman` exports two decoders, and `huffman.decode` is the one to call.
//! `huffman.decodeReference` is the slower nibble automaton, kept as the oracle
//! the faster one is tested against; it is public only so the benchmark and the
//! fuzz targets can reach it from their own modules.
//!
//! The one thing the two protocols do differ on is how wide an integer can be,
//! and that is a parameter rather than a fork: see `integer.Integer`.
//!
//! Bytes in, bytes out. No allocator, no I/O types, no dependencies — see
//! README.md for the scope and docs/TIGER_STYLE.md for what `zig build lint`
//! enforces.

const std = @import("std");

/// `assert` and the `-Dassertions` build option. Named for the option rather
/// than for the function, so the flag reads `hpack.assertions.enabled` and the
/// function does not stutter as `hpack.assert.assert`.
pub const assertions = @import("assert.zig");

/// RFC 7541 section 5.1, adopted unchanged by RFC 9204 section 4.1.1.
pub const integer = @import("integer.zig");

/// RFC 7541 section 5.2 and Appendix B, adopted unchanged by RFC 9204
/// section 4.1.2.
pub const huffman = @import("huffman.zig");

/// The Huffman code's own table, exposed for a consumer that wants the codes
/// rather than the codec — a benchmark comparing against another
/// implementation, or a test asserting a symbol's length.
pub const huffman_codes = @import("huffman_codes.zig");

/// Span arithmetic for the copies this package makes between caller-owned
/// buffers. One function, and it is here because the dynamic table and the
/// decoder each assert with it before a `@memcpy` that is undefined on overlap.
pub const memory = @import("memory.zig");

/// HPACK proper: the field line representations and the two tables.
///
/// `Decoder` and `Encoder` are the entry points; everything else is exposed
/// because a consumer occasionally needs a piece on its own — zrk encodes one
/// header block at startup and replays it forever, and reaches `huffman`
/// directly to size the buffer it does that in.
pub const Decoder = @import("Decoder.zig");
pub const DynamicTable = @import("DynamicTable.zig");
pub const Encoder = @import("Encoder.zig");
pub const Field = @import("Field.zig");
pub const static_table = @import("static_table.zig");

/// RFC 7541 Appendix C, machine-extracted. Public so a consumer can run the
/// same conformance vectors against its own integration.
pub const rfc7541_examples = @import("rfc7541_examples.zig");

test {
    _ = assertions;
    _ = integer;
    _ = huffman;
    _ = huffman_codes;
    _ = memory;
    _ = Decoder;
    _ = DynamicTable;
    _ = Encoder;
    _ = Field;
    _ = static_table;
    _ = rfc7541_examples;
}
