//! Fuzz targets. Lives outside `src/` because it needs platform surfaces that
//! `zig build lint` forbids in the library.
//!
//! Run modes:
//! * `zig build fuzz` — replays the seed corpus once (regression mode).
//! * `zig build fuzz --fuzz` — coverage-guided fuzzing via Zig's native fuzzer.
//!
//! docs/TIGER_STYLE.md makes fuzzing a gate rather than a nicety: these two
//! primitives are the unbounded surfaces of field compression — a prefixed
//! integer's continuation run has no length, and a Huffman string's symbol
//! boundaries are not on octet boundaries — and both are reached, on every
//! connection, by octets a peer chose.
//!
//! The property every target shares is **reject or parse, with no third
//! outcome**. A decoder may return a well-formed answer or an error; what it
//! may not do is panic, read out of bounds, fail to terminate, or return an
//! answer that is quietly short.
//!
//! Ported from zoxy-io/h2 along with the code they cover, and generalised where
//! the code was: the integer targets run at both widths.

const std = @import("std");

const hpack = @import("hpack");

/// The oracle's own assert, always on.
///
/// Deliberately not `std.debug.assert` and deliberately not the library's
/// `-Dassertions`-gated one. Every property these targets check is expressed as
/// an assertion, so an assertion the build can remove is a fuzz target the
/// build can turn into a crash-only fuzzer — and `zig build fuzz --fuzz
/// -Doptimize=ReleaseFast` is the natural way to actually fuzz.
fn assert(ok: bool) void {
    if (!ok) @panic("fuzz: oracle assertion failed");
}

/// Inputs are capped so a failing case stays small enough to read.
const input_max = 1024;

/// A Huffman decoding cannot exceed 8/5 of its input: the shortest code is five
/// bits. Four times the input is room to spare, so an `OutputTooLong` from
/// these targets would be a bug in the bound rather than a small buffer.
const huffman_expansion_max = 4;

const Hpack = hpack.integer.Integer(u32);
const Qpack = hpack.integer.Integer(u62);

test "fuzz: huffman decoder" {
    try std.testing.fuzz({}, fuzzHuffman, .{});
}

/// The Huffman kernel alone, where a failure localizes.
///
/// Beyond reject-or-parse: anything this decoder accepts must re-encode to the
/// bytes it came from. The code is canonical, so a string has exactly one valid
/// encoding, and an accepted input that re-encodes differently means the
/// decoder walked a path no encoder would produce — which is a second spelling
/// of a header value, and therefore a smuggling primitive rather than a
/// cosmetic disagreement.
fn fuzzHuffman(_: void, smith: *std.testing.Smith) !void {
    var wire: [input_max]u8 = undefined;
    const length = smith.slice(&wire);

    var decoded: [input_max * huffman_expansion_max]u8 = undefined;
    const written = hpack.huffman.decode(&decoded, wire[0..length]) catch return;

    var reencoded: [input_max * huffman_expansion_max]u8 = undefined;
    const encoded_length = try hpack.huffman.encode(&reencoded, decoded[0..written]);
    assert(encoded_length == length);
    assert(std.mem.eql(u8, reencoded[0..encoded_length], wire[0..length]));
}

test "fuzz: huffman kernels agree" {
    try std.testing.fuzz({}, fuzzHuffmanAgreement, .{});
}

/// The twelve-bit window and the nibble automaton must be indistinguishable.
///
/// `decode` is the window and `decodeReference` is the automaton, and the whole
/// case for shipping the faster one rests on their agreeing everywhere — not
/// only on what they accept, but on which error they return and how much they
/// wrote. The exhaustive test in `huffman.zig` covers every one- and two-octet
/// input; this covers the shapes that need more octets to reach, which is where
/// the escapes and the accumulator refill live.
fn fuzzHuffmanAgreement(_: void, smith: *std.testing.Smith) !void {
    var wire: [input_max]u8 = undefined;
    const length = smith.slice(&wire);

    var reference: [input_max * huffman_expansion_max]u8 = undefined;
    var window: [input_max * huffman_expansion_max]u8 = undefined;
    @memset(&reference, 0);
    @memset(&window, 0);

    // The capacity is drawn, not fixed. With a buffer that always fits, the
    // only behavioural difference the two kernels can have — what each leaves
    // in the target when it runs out of room mid-pair — is unreachable, and the
    // window emits two symbols per lookup where the automaton emits one.
    const capacity = @min(reference.len, smith.value(u16));

    if (hpack.huffman.decodeReference(reference[0..capacity], wire[0..length])) |written| {
        // Reachable only on the bug this target hunts: the automaton accepted
        // and the window did not.
        const other = hpack.huffman.decode(window[0..capacity], wire[0..length]) catch unreachable;
        assert(written == other);
    } else |err| {
        if (hpack.huffman.decode(window[0..capacity], wire[0..length])) |_| {
            // The window accepted what the automaton rejected.
            unreachable;
        } else |other| {
            assert(err == other);
        }
    }
    // Whatever each wrote, including on the error paths.
    assert(std.mem.eql(u8, reference[0..capacity], window[0..capacity]));
}

test "fuzz: huffman round trip" {
    try std.testing.fuzz({}, fuzzHuffmanRoundTrip, .{});
}

/// The other direction: every byte string encodes, and decodes back to itself.
fn fuzzHuffmanRoundTrip(_: void, smith: *std.testing.Smith) !void {
    var text: [input_max]u8 = undefined;
    const length = smith.slice(&text);

    var wire: [input_max * huffman_expansion_max]u8 = undefined;
    const encoded_length = try hpack.huffman.encode(&wire, text[0..length]);
    assert(encoded_length == hpack.huffman.encodedLength(text[0..length]));

    var decoded: [input_max]u8 = undefined;
    const written = try hpack.huffman.decode(&decoded, wire[0..encoded_length]);
    assert(std.mem.eql(u8, decoded[0..written], text[0..length]));
}

test "fuzz: integer codec, at HTTP/2's width" {
    try std.testing.fuzz({}, fuzzIntegerNarrow, .{});
}

test "fuzz: integer codec, at HTTP/3's width" {
    try std.testing.fuzz({}, fuzzIntegerWide, .{});
}

fn fuzzIntegerNarrow(_: void, smith: *std.testing.Smith) !void {
    try fuzzInteger(Hpack, smith);
}

fn fuzzIntegerWide(_: void, smith: *std.testing.Smith) !void {
    try fuzzInteger(Qpack, smith);
}

/// The prefix-integer primitive, whose worst failure is not returning at all.
///
/// Run at both widths, separately rather than in one target, so that a
/// coverage-guided run cannot spend its whole budget on one of them. The wide
/// instantiation reaches four continuation octets the narrow one rejects, and
/// those are exactly where the accumulator's overflow proof would fail if the
/// bound were derived wrong.
fn fuzzInteger(comptime integer: type, smith: *std.testing.Smith) !void {
    var source: [64]u8 = undefined;
    const length = smith.slice(&source);
    if (length == 0) return;

    const prefix_bits: u4 = @intCast(1 + @as(u4, smith.value(u3)));
    const decoded = integer.decode(source[0..length], prefix_bits) catch return;
    assert(decoded.octets >= 1);
    assert(decoded.octets <= length);
    assert(decoded.octets <= integer.continuation_octets_max + 1);

    // Re-encoding must reproduce the *value*, not the octets. RFC 7541 section
    // 5.1 permits a non-minimal encoding — `{0x1f, 0x80, 0x00}` and
    // `{0x1f, 0x00}` are both 31 behind a 5-bit prefix — so asserting byte
    // identity here would fail on input the decoder accepts by design, and a
    // coverage-guided run reaches such input almost immediately.
    var target: [16]u8 = undefined;
    const prefix_mask: u8 = @intCast((@as(u16, 1) << prefix_bits) - 1);
    const tag: u8 = source[0] & ~prefix_mask;
    const written = try integer.encode(&target, decoded.value, prefix_bits, tag);
    assert(written == integer.encodedLength(decoded.value, prefix_bits));
    assert(written <= decoded.octets);

    const again = try integer.decode(target[0..written], prefix_bits);
    assert(again.value == decoded.value);
    assert(again.octets == written);
}

test "fuzz: overlap detection is symmetric" {
    try std.testing.fuzz({}, fuzzOverlap, .{});
}

/// `memory.overlaps` guards two `@memcpy` sites that are undefined on overlap,
/// so the property that matters is that it never answers *false* for two spans
/// that share an octet. Checked against the definition rather than against
/// itself: two offsets and two lengths into one buffer, with the answer derived
/// arithmetically.
fn fuzzOverlap(_: void, smith: *std.testing.Smith) !void {
    var block: [256]u8 = undefined;
    const left_start = smith.valueRangeAtMost(u8, 0, block.len - 1);
    const left_end = smith.valueRangeAtMost(u8, left_start, block.len - 1);
    const right_start = smith.valueRangeAtMost(u8, 0, block.len - 1);
    const right_end = smith.valueRangeAtMost(u8, right_start, block.len - 1);

    const left = block[left_start..left_end];
    const right = block[right_start..right_end];
    const answer = hpack.memory.overlaps(left, right);

    // The definition, spelled out: two non-empty half-open ranges share a point
    // exactly when each begins before the other ends.
    const expected = left.len != 0 and right.len != 0 and
        left_start < right_end and right_start < left_end;
    assert(answer == expected);
    // And it is symmetric, which is the property both call sites rely on.
    assert(hpack.memory.overlaps(right, left) == answer);
}
