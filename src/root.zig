//! hpack — the two primitives HPACK is built out of: RFC 7541's Huffman code
//! and its prefixed integer.
//!
//! They are here rather than in h2 because QPACK adopts both unchanged — RFC
//! 9204 section 4.1.1 takes RFC 7541 section 5.1, and section 4.1.2 takes
//! section 5.2 with the same 257-symbol table. Before this package existed
//! there were two copies of a 900-line vectorised Huffman decoder in one
//! organisation, and a bug fixed in one was a bug still live in the other.
//!
//! The layers above stay with the protocol that owns them: HPACK's
//! representations and tables are in zoxy-io/h2, QPACK's in zoxy-io/h3. Those
//! are genuinely different — QPACK's static table is a different table indexed
//! from zero, and its dynamic table is addressed relative to an insert count
//! HPACK has no notion of — so sharing them would be a fiction.
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

/// Span arithmetic for the copies both consumers make between caller-owned
/// buffers. One function, and it is here because both of them assert with it
/// before a `@memcpy` that is undefined on overlap.
pub const memory = @import("memory.zig");

/// RFC 7541 Appendix C's Huffman-coded strings, machine-lifted from the RFC.
pub const rfc7541_strings = @import("rfc7541_strings.zig");

test {
    _ = assertions;
    _ = integer;
    _ = huffman;
    _ = huffman_codes;
    _ = memory;
    _ = rfc7541_strings;
}
