//! RFC 7541 Appendix C's Huffman-coded strings, extracted from the RFC text
//! rather than transcribed by hand.
//!
//! Transcription is exactly where a codec's test vectors go wrong, and quietly:
//! a mistyped byte string still decodes to *something*, so the test fails
//! against a plausible answer and the reader blames the decoder. These were
//! machine-lifted from the "Hex dump of encoded data" blocks of
//! https://www.rfc-editor.org/rfc/rfc7541.txt.
//!
//! Only the Huffman strings live here. Appendix C's four *stories* — the
//! consecutive header lists that share a dynamic table and test eviction — stay
//! in zoxy-io/h2, because they exercise HPACK's representations and tables
//! rather than the primitives this package holds.

pub const huffman_strings = [_]struct { wire: []const u8, text: []const u8 }{
    .{ .wire = "d\x02", .text = "302" },
    .{ .wire = "d\x0e\xff", .text = "307" },
    .{ .wire = "\x9b\xd9\xab", .text = "gzip" },
    .{ .wire = "\xae\xc3w\x1aK", .text = "private" },
    .{ .wire = "\xa8\xeb\x10d\x9c\xbf", .text = "no-cache" },
    .{ .wire = "%\xa8I\xe9[\xa9}\x7f", .text = "custom-key" },
    .{ .wire = "\xf1\xe3\xc2\xe5\xf2:k\xa0\xab\x90\xf4\xff", .text = "www.example.com" },
    .{ .wire = "\x9d)\xad\x17\x18c\xc7\x8f\x0b\x97\xc8\xe9\xae\x82\xaeC\xd3", .text = "https://www.example.com" },
    .{ .wire = "\xd0z\xbe\x94\x10T\xd4D\xa8 \x05\x95\x04\x0b\x81f\xe0\x82\xa6-\x1b\xff", .text = "Mon, 21 Oct 2013 20:13:21 GMT" },
    .{ .wire = "\xd0z\xbe\x94\x10T\xd4D\xa8 \x05\x95\x04\x0b\x81f\xe0\x84\xa6-\x1b\xff", .text = "Mon, 21 Oct 2013 20:13:22 GMT" },
};
