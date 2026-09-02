//! The README's usage example, as a program that runs.
//!
//! A header field value, encoded the way both HPACK and QPACK encode one — a
//! length in a prefixed integer whose top bit says "Huffman", then the Huffman
//! string itself — and read back. The two primitives compose exactly once here,
//! which is the whole of what this package is for.
//!
//! It is a compiled, run program rather than a snippet — `zig build example`,
//! and `zig build ci` runs it — so a usage example that stopped building fails
//! the build instead of greeting the next reader.

const std = @import("std");

const hpack = @import("hpack");

/// HTTP/2's width. HTTP/3 names `Integer(u62)` here instead, and nothing else
/// in this file changes; see src/integer.zig for why the width is the
/// protocol's rather than the encoding's.
const integer = hpack.integer.Integer(u32);

/// RFC 7541 section 5.2: a string literal's length sits in a seven-bit prefix,
/// under a one-bit flag saying whether the octets are Huffman-coded.
const length_prefix_bits: u4 = 7;
const huffman_flag: u8 = 0x80;

pub fn main() !void {
    const text = "www.example.com";

    // 1. Huffman-encode the value. `encodedLength` first, so the length field
    //    and the string are written once each rather than the string twice.
    var coded: [64]u8 = undefined;
    const coded_length = try hpack.huffman.encode(&coded, text);

    // 2. The length, in a seven-bit prefix under the Huffman flag. The tag is
    //    passed to `encode` rather than written first, because the tag is what
    //    decides the prefix width.
    var wire: [80]u8 = undefined;
    const header_length = try integer.encode(&wire, coded_length, length_prefix_bits, huffman_flag);
    @memcpy(wire[header_length..][0..coded_length], coded[0..coded_length]);
    const total = header_length + coded_length;

    // --- and on the way back in ---

    // 3. Read the length back, and the flag beside it.
    const decoded_length = try integer.decode(wire[0..total], length_prefix_bits);
    const is_huffman = wire[0] & huffman_flag != 0;
    std.debug.assert(is_huffman);

    // 4. Decode the string. The target is the caller's, and its capacity is
    //    what bounds a compression bomb: the shortest code is five bits, so a
    //    decoding is at most 8/5 of its input.
    var text_back: [64]u8 = undefined;
    const body = wire[decoded_length.octets..][0..decoded_length.value];
    const written = try hpack.huffman.decode(&text_back, body);

    std.debug.assert(std.mem.eql(u8, text_back[0..written], text));
    std.debug.print("{s}: {d} octets of text in {d} on the wire ({d} of header)\n", .{
        text,
        text.len,
        total,
        header_length,
    });
}
