//! RFC 7541 section 5.1: integers with an N-bit prefix.
//!
//! A value below the prefix's maximum is that prefix; anything larger sets
//! every prefix bit and continues in 7-bit groups, low group first, with the
//! high bit marking continuation. The bits above the prefix are the caller's
//! type tag and never part of the value, which is the property that makes this
//! encoding — rather than QUIC's variable-length integer — the one both HPACK
//! and QPACK use: a field line representation is one to four tag bits followed
//! by an index in whatever remains of the octet, and a variable-length integer
//! has no room for a tag.
//!
//! RFC 9204 section 4.1.1 adopts this section by reference, unchanged. The two
//! protocols differ in exactly one thing, and it is what `Integer` is
//! parameterised by.
//!
//! ## The width is the protocol's, not the encoding's
//!
//! Section 5.1 puts no ceiling on a value at all. Every real ceiling comes from
//! the *field* being encoded, and the two protocols draw theirs from different
//! places:
//!
//! * **HPACK** indexes, string lengths and table sizes are all bounded by
//!   HTTP/2 SETTINGS values, which are `u32`. `Integer(u32)`.
//! * **QPACK** indexes and lengths are ultimately bounded by a QUIC stream
//!   offset, which is 62 bits (RFC 9000 section 16). `Integer(u62)`.
//!
//! So a consumer names its width once, at the import, and the bound is visible
//! at the call site:
//!
//!     const integer = hpack.integer.Integer(u32); // h2
//!     const integer = hpack.integer.Integer(u62); // h3
//!
//! ## Why this primitive owns a bound at all
//!
//! Section 5.1 sets no limit on how many continuation octets an encoder may
//! send, and says so explicitly: an implementation "MUST" guard against
//! integers that exceed what it can represent. An unbounded run of octets with
//! the high bit set is therefore legal-looking input that a trusting decoder
//! will follow forever, and every integer in either protocol — index, length,
//! table size, insert count — flows through here. The bound belongs at the
//! primitive rather than at each of a dozen call sites, because a call site
//! that forgets it is silent.

const std = @import("std");

const assert = @import("assert.zig").assert;

/// The widest prefix section 5.1 defines. A prefix is the low bits of an octet
/// whose high bits carry a representation's type tag, and the representations
/// with no tag bits — HPACK's dynamic table size update successor and both
/// protocols' string lengths — use seven or eight.
pub const prefix_bits_max: u4 = 8;

/// The prefixed-integer codec for a given value width.
///
/// `Value` must be an unsigned integer of at least 8 bits — a prefix alone can
/// reach 255, so anything narrower could not hold what a single octet encodes —
/// and at most 62, which is the widest either protocol needs and the width at
/// which `u64` accumulation is still provably free of overflow.
pub fn Integer(comptime Value: type) type {
    return struct {
        /// The largest value this width can carry. Held as `u64` so that the
        /// range check below is a comparison rather than a cast that has
        /// already lost the evidence.
        pub const value_max: u64 = std.math.maxInt(Value);

        /// The most continuation octets a value may use.
        ///
        /// Enough 7-bit groups to cover `Value`, and not one more: a further
        /// octet cannot describe a representable value, so accepting one only
        /// buys an attacker a longer walk. Five for `u32`, nine for `u62`.
        ///
        /// It is worth being explicit that this is stricter than section 5.1,
        /// which sets no limit: a peer may pad an integer with zero-valued
        /// groups indefinitely and still be conformant, and such an encoding is
        /// rejected here as `TooLarge`. That is the right direction for a
        /// decoder facing the open internet, and it is a deliberate deviation
        /// rather than an oversight.
        pub const continuation_octets_max: u32 = (@bitSizeOf(Value) + 6) / 7;

        comptime {
            assert(@typeInfo(Value) == .int);
            assert(@typeInfo(Value).int.signedness == .unsigned);
            // A prefix alone reaches 255, so a narrower value could not hold
            // what one octet encodes.
            assert(@bitSizeOf(Value) >= 8);
            assert(@bitSizeOf(Value) <= 62);
            // The groups have to cover the width, which is what makes the bound
            // "enough" rather than "some number".
            assert(continuation_octets_max * 7 >= @bitSizeOf(Value));
            assert((continuation_octets_max - 1) * 7 < @bitSizeOf(Value));
            // And the proof that `decode` may accumulate in `u64` unchecked:
            // the groups contribute strictly less than 2^63, and the prefix
            // adds at most 255, so the sum cannot reach 2^64.
            assert(continuation_octets_max * 7 <= 63);
            // The shift is a `u6`, and it reaches 7 per continuation octet.
            assert((continuation_octets_max - 1) * 7 <= std.math.maxInt(u6));
            // The two widths the protocols actually use, checked here so that a
            // change to the formula is caught rather than merely compiled.
            if (Value == u32) assert(continuation_octets_max == 5);
            if (Value == u62) assert(continuation_octets_max == 9);
        }

        pub const DecodeError = error{
            /// The encoding continues past the end of the input. The caller may
            /// have more bytes; within an HPACK field block, which arrives
            /// whole, it does not, and this is malformed. On a QPACK encoder
            /// stream it is ordinary — more octets are coming.
            Incomplete,
            /// More continuation octets than `continuation_octets_max`, or a
            /// value too large for `Value`.
            TooLarge,
        };

        pub const Decoded = struct {
            value: Value,
            /// Octets consumed, including the prefix octet. Always at least one.
            octets: u32,
        };

        /// Decode the integer beginning at `source[0]`, whose prefix occupies
        /// the low `prefix_bits` bits of that octet. Bits above the prefix are
        /// the caller's type tag and are ignored here.
        pub fn decode(source: []const u8, prefix_bits: u4) DecodeError!Decoded {
            assert(prefix_bits >= 1);
            assert(prefix_bits <= prefix_bits_max);
            if (source.len == 0) return error.Incomplete;

            const prefix_max: u64 = (@as(u64, 1) << prefix_bits) - 1;
            assert(prefix_max <= std.math.maxInt(u8));
            const prefix: u64 = source[0] & @as(u8, @intCast(prefix_max));
            if (prefix < prefix_max) {
                assert(prefix <= value_max);
                return .{ .value = @intCast(prefix), .octets = 1 };
            }

            // Accumulated in `u64` so the range check below is a comparison
            // rather than a wrap that has already lost the evidence. The
            // comptime block above proves the sum cannot overflow it.
            var value: u64 = prefix_max;
            var shift: u6 = 0;
            var continuation_octets: u32 = 0;
            while (continuation_octets < continuation_octets_max) {
                const index = continuation_octets + 1;
                if (index >= source.len) return error.Incomplete;
                const octet = source[index];
                continuation_octets += 1;

                value += @as(u64, octet & 0x7f) << shift;
                if (octet & 0x80 == 0) {
                    if (value > value_max) return error.TooLarge;
                    const decoded: Decoded = .{
                        .value = @intCast(value),
                        .octets = continuation_octets + 1,
                    };
                    assert(decoded.octets <= continuation_octets_max + 1);
                    return decoded;
                }
                shift += 7;
            }
            assert(continuation_octets == continuation_octets_max);
            return error.TooLarge;
        }

        pub const EncodeError = error{
            /// `target` cannot hold the encoding.
            OutputTooLong,
        };

        /// Write `value` into `target` with a `prefix_bits`-bit prefix, keeping
        /// the tag bits `tag` supplies above that prefix.
        ///
        /// The caller passes the tag rather than setting `target[0]` first,
        /// because the tag is what decides `prefix_bits`, and splitting them
        /// across two arguments invites a pair that disagrees.
        pub fn encode(target: []u8, value: Value, prefix_bits: u4, tag: u8) EncodeError!u32 {
            assert(prefix_bits >= 1);
            assert(prefix_bits <= prefix_bits_max);
            // The tag must not reach into the prefix, or it would be read back
            // as part of the value. An eight-bit prefix leaves no room for a
            // tag at all, so there is nothing to check there.
            if (prefix_bits < prefix_bits_max) {
                assert((tag & ((@as(u16, 1) << prefix_bits) - 1)) == 0);
            }

            // Checked once, up front, so this function either writes the whole
            // encoding or touches nothing. `huffman.encode` has the same
            // contract, and a caller writing a length followed by a Huffman
            // string composes exactly the two — one of them leaving a
            // half-written prefix behind on failure would be a trap set for
            // whoever writes that caller.
            const length = encodedLength(value, prefix_bits);
            if (length > target.len) return error.OutputTooLong;

            const prefix_max: u64 = (@as(u64, 1) << prefix_bits) - 1;
            const wide: u64 = value;
            if (wide < prefix_max) {
                target[0] = tag | @as(u8, @intCast(wide));
                assert(length == 1);
                return 1;
            }

            target[0] = tag | @as(u8, @intCast(prefix_max));
            var remaining: u64 = wide - prefix_max;
            var index: u32 = 1;
            while (remaining >= 0x80) {
                assert(index < length);
                target[index] = @as(u8, @truncate(remaining)) | 0x80;
                index += 1;
                remaining >>= 7;
            }
            assert(index < length);
            target[index] = @intCast(remaining);
            assert(index + 1 == length);
            return length;
        }

        /// Octets `encode` would write. Lets a caller check space once for a
        /// whole representation instead of unwinding a partial write.
        pub fn encodedLength(value: Value, prefix_bits: u4) u32 {
            assert(prefix_bits >= 1);
            assert(prefix_bits <= prefix_bits_max);
            const prefix_max: u64 = (@as(u64, 1) << prefix_bits) - 1;
            const wide: u64 = value;
            if (wide < prefix_max) return 1;

            var remaining: u64 = wide - prefix_max;
            var octets: u32 = 1;
            while (remaining >= 0x80) {
                octets += 1;
                remaining >>= 7;
                assert(octets <= continuation_octets_max);
            }
            assert(octets <= continuation_octets_max);
            return octets + 1;
        }
    };
}

const testing = std.testing;

/// HPACK's width, and what h2 imports.
const Hpack = Integer(u32);

/// QPACK's width, and what h3 imports.
const Qpack = Integer(u62);

// RFC 7541 Appendix C.1 gives three worked examples; each is both directions,
// and each is run at both widths, because the encoding is the same one and a
// generic that answered differently for `u62` would be a bug the HPACK-only
// vectors could not see.

test "C.1.1: 10 in a 5-bit prefix" {
    inline for (.{ Hpack, Qpack }) |integer| {
        const decoded = try integer.decode(&.{0b0000_1010}, 5);
        try testing.expectEqual(@as(u64, 10), decoded.value);
        try testing.expectEqual(@as(u32, 1), decoded.octets);

        var target: [8]u8 = undefined;
        target[0] = 0;
        try testing.expectEqual(@as(u32, 1), try integer.encode(&target, 10, 5, 0));
        try testing.expectEqual(@as(u8, 0b0000_1010), target[0]);
    }
}

test "C.1.2: 1337 in a 5-bit prefix" {
    inline for (.{ Hpack, Qpack }) |integer| {
        const decoded = try integer.decode(&.{ 0b0001_1111, 0b1001_1010, 0b0000_1010 }, 5);
        try testing.expectEqual(@as(u64, 1337), decoded.value);
        try testing.expectEqual(@as(u32, 3), decoded.octets);

        var target: [8]u8 = undefined;
        try testing.expectEqual(@as(u32, 3), try integer.encode(&target, 1337, 5, 0));
        try testing.expectEqualSlices(u8, &.{ 0b0001_1111, 0b1001_1010, 0b0000_1010 }, target[0..3]);
    }
}

test "C.1.3: 42 starting at an octet boundary" {
    inline for (.{ Hpack, Qpack }) |integer| {
        const decoded = try integer.decode(&.{0b0010_1010}, 8);
        try testing.expectEqual(@as(u64, 42), decoded.value);
        try testing.expectEqual(@as(u32, 1), decoded.octets);

        var target: [8]u8 = undefined;
        try testing.expectEqual(@as(u32, 1), try integer.encode(&target, 42, 8, 0));
        try testing.expectEqual(@as(u8, 42), target[0]);
    }
}

test "tag bits above the prefix are ignored on decode and kept on encode" {
    // 0b1010_1010 with a 5-bit prefix is the value 10 behind a 0b101 tag.
    const decoded = try Hpack.decode(&.{0b1010_1010}, 5);
    try testing.expectEqual(@as(u32, 10), decoded.value);

    var target: [4]u8 = undefined;
    _ = try Hpack.encode(&target, 10, 5, 0b1010_0000);
    try testing.expectEqual(@as(u8, 0b1010_1010), target[0]);
}

test "a value at the prefix maximum still needs a continuation octet" {
    // 31 in a 5-bit prefix cannot be the prefix itself: all-ones means "more".
    var target: [4]u8 = undefined;
    try testing.expectEqual(@as(u32, 2), try Hpack.encode(&target, 31, 5, 0));
    try testing.expectEqualSlices(u8, &.{ 0b0001_1111, 0 }, target[0..2]);

    const decoded = try Hpack.decode(target[0..2], 5);
    try testing.expectEqual(@as(u32, 31), decoded.value);
    try testing.expectEqual(@as(u32, 2), decoded.octets);
}

test "round trip across every prefix width and a spread of values" {
    const values = [_]u32{
        0,                    1,                        2,                    30,  31,   32,    126,   127,
        128,                  254,                      255,                  256, 1337, 16383, 16384, std.math.maxInt(u16),
        std.math.maxInt(u24), std.math.maxInt(u32) - 1, std.math.maxInt(u32),
    };
    var target: [16]u8 = undefined;
    for (1..prefix_bits_max + 1) |bits_usize| {
        const bits: u4 = @intCast(bits_usize);
        for (values) |value| {
            const written = try Hpack.encode(&target, value, bits, 0);
            try testing.expectEqual(Hpack.encodedLength(value, bits), written);
            const decoded = try Hpack.decode(target[0..written], bits);
            try testing.expectEqual(value, decoded.value);
            try testing.expectEqual(written, decoded.octets);
        }
    }
}

test "the wide width round-trips past where the narrow one stops" {
    // The values only QPACK can reach. `u32`'s codec rejects every one of them,
    // which is the whole point of naming the width at the import.
    const values = [_]u62{
        @as(u62, std.math.maxInt(u32)) + 1,
        1 << 40,
        (1 << 62) - 2,
        (1 << 62) - 1,
    };
    var target: [16]u8 = undefined;
    for (1..prefix_bits_max + 1) |bits_usize| {
        const bits: u4 = @intCast(bits_usize);
        for (values) |value| {
            const written = try Qpack.encode(&target, value, bits, 0);
            try testing.expectEqual(Qpack.encodedLength(value, bits), written);
            const decoded = try Qpack.decode(target[0..written], bits);
            try testing.expectEqual(value, decoded.value);
            try testing.expectError(error.TooLarge, Hpack.decode(target[0..written], bits));
        }
    }
}

test "truncated encodings report Incomplete, never a short value" {
    // 1337 needs three octets; every strict prefix of it is incomplete.
    const full = [_]u8{ 0b0001_1111, 0b1001_1010, 0b0000_1010 };
    try testing.expectError(error.Incomplete, Hpack.decode(full[0..0], 5));
    try testing.expectError(error.Incomplete, Hpack.decode(full[0..1], 5));
    try testing.expectError(error.Incomplete, Hpack.decode(full[0..2], 5));
}

test "an unbounded continuation run terminates as TooLarge" {
    // The shape a decoder without this bound follows forever, at both widths:
    // the wide one walks four octets further and then stops just the same.
    const bomb = [_]u8{0xff} ** 64;
    inline for (.{ Hpack, Qpack }) |integer| {
        try testing.expectError(error.TooLarge, integer.decode(&bomb, 5));
        try testing.expectError(error.TooLarge, integer.decode(&bomb, 7));
        try testing.expectError(error.TooLarge, integer.decode(&bomb, 8));
    }
}

test "a value past the chosen width is rejected rather than wrapped" {
    // Prefix 255 plus 2^35-ish: representable in five octets, not in u32.
    const source = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f };
    try testing.expectError(error.TooLarge, Hpack.decode(&source, 8));
    // The same octets are an ordinary value at QPACK's width.
    try testing.expectEqual(@as(u62, 0x8_0000_00fe), (try Qpack.decode(&source, 8)).value);
}

test "encode reports OutputTooLong instead of writing past the target" {
    var target: [1]u8 = undefined;
    try testing.expectError(error.OutputTooLong, Hpack.encode(&target, 1337, 5, 0));
    var empty: [0]u8 = undefined;
    try testing.expectError(error.OutputTooLong, Hpack.encode(&empty, 0, 5, 0));
}

test "the bound is the width's, derived rather than chosen" {
    try testing.expectEqual(@as(u32, 5), Hpack.continuation_octets_max);
    try testing.expectEqual(@as(u32, 9), Qpack.continuation_octets_max);
    try testing.expectEqual(@as(u64, std.math.maxInt(u32)), Hpack.value_max);
    try testing.expectEqual(@as(u64, (1 << 62) - 1), Qpack.value_max);
}
