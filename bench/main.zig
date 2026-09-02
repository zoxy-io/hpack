//! Microbenchmarks for the two primitives, which are the hot paths of every
//! consumer's field decoding.
//!
//! ## The two footguns this file exists to avoid
//!
//! **An unused result is a deleted loop.** Every workload accumulates into
//! `sink`, which `run` then hands to `doNotOptimizeAway`. The build hardcodes
//! `ReleaseFast` for the same reason in reverse: a benchmark built in Debug
//! reports numbers that mean nothing.
//!
//! **A constant input is a folded loop.** A sink alone does not stop that: the
//! result *is* used, it is just computed once. So every workload calls
//! `doNotOptimizeAway` on its *input* inside the loop.
//!
//! ## What to read out of it
//!
//! Bands across runs, never single numbers. The row that decides a design
//! question is `huffman decode` against `huffman decode (automaton)`: the
//! twelve-bit window ships only because it is faster than the reference
//! automaton *and* agrees with it everywhere, and the second half of that claim
//! is a fuzz target rather than a benchmark.

const std = @import("std");

const hpack = @import("hpack");
const options = @import("bench_options");

const Hpack = hpack.integer.Integer(u32);
const Qpack = hpack.integer.Integer(u62);

/// A field value of the length a real header carries, rather than a short
/// string where the per-call overhead dominates the kernel.
const sample_text = "Mon, 21 Oct 2013 20:13:21 GMT; www.example.com; no-cache, private";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    std.debug.print("hpack bench — {d} runs x {d} iterations, assertions {s}\n\n", .{
        options.runs,
        options.iterations,
        if (hpack.assertions.enabled) "on" else "off",
    });
    std.debug.print("{s:<32} {s:>12} {s:>12}\n", .{ "workload", "mean ns/op", "best ns/op" });
    std.debug.print("{s}\n", .{"-" ** 58});

    run(io, "huffman encode", benchHuffmanEncode);
    run(io, "huffman decode (window)", benchHuffmanDecode);
    run(io, "huffman decode (automaton)", benchHuffmanDecodeReference);
    run(io, "integer decode (u32)", benchIntegerNarrow);
    run(io, "integer decode (u62)", benchIntegerWide);
}

fn run(io: std.Io, name: []const u8, workload: fn (u64) u64) void {
    var best: u64 = std.math.maxInt(u64);
    var total: u64 = 0;
    var sink: u64 = 0;
    var index: u64 = 0;
    while (index < options.runs) : (index += 1) {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        sink +%= workload(options.iterations);
        const finished = std.Io.Clock.awake.now(io).nanoseconds;
        const elapsed: u64 = @intCast(finished - started);
        total += elapsed;
        best = @min(best, elapsed);
    }
    std.mem.doNotOptimizeAway(sink);
    // Fractional, not integer: the integer rows run in a couple of nanoseconds,
    // and a truncating division reports every one of them as the same number.
    const mean_ns = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(options.runs * options.iterations));
    const best_ns = @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(options.iterations));
    std.debug.print("{s:<32} {d:>12.3} {d:>12.3}\n", .{ name, mean_ns, best_ns });
}

fn benchHuffmanEncode(iterations: u64) u64 {
    var text = sample_text.*;
    var target: [256]u8 = undefined;
    var sink: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        std.mem.doNotOptimizeAway(&text);
        sink +%= hpack.huffman.encode(&target, &text) catch unreachable; // The target is four times the text, and the code cannot expand past 8/5.
    }
    return sink;
}

/// Encoded once, outside the loop, so the decode rows measure decoding.
fn encodedSample(target: []u8) usize {
    return hpack.huffman.encode(target, sample_text) catch unreachable; // As above.
}

fn benchHuffmanDecode(iterations: u64) u64 {
    var wire: [256]u8 = undefined;
    const length = encodedSample(&wire);
    var target: [256]u8 = undefined;
    var sink: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        std.mem.doNotOptimizeAway(&wire);
        sink +%= hpack.huffman.decode(&target, wire[0..length]) catch unreachable; // Just produced by this package's own encoder.
    }
    return sink;
}

fn benchHuffmanDecodeReference(iterations: u64) u64 {
    var wire: [256]u8 = undefined;
    const length = encodedSample(&wire);
    var target: [256]u8 = undefined;
    var sink: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        std.mem.doNotOptimizeAway(&wire);
        sink +%= hpack.huffman.decodeReference(&target, wire[0..length]) catch unreachable; // As above.
    }
    return sink;
}

fn benchIntegerNarrow(iterations: u64) u64 {
    // 1337 in a five-bit prefix: three octets, which is the shape a length
    // field takes once it leaves the prefix.
    var wire = [_]u8{ 0x1f, 0x9a, 0x0a };
    var sink: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        std.mem.doNotOptimizeAway(&wire);
        sink +%= (Hpack.decode(&wire, 5) catch unreachable).value; // A well-formed three-octet encoding.
    }
    return sink;
}

fn benchIntegerWide(iterations: u64) u64 {
    // The same octets at QPACK's width, so the row isolates what the wider
    // instantiation costs rather than what a longer value costs.
    var wire = [_]u8{ 0x1f, 0x9a, 0x0a };
    var sink: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        std.mem.doNotOptimizeAway(&wire);
        sink +%= (Qpack.decode(&wire, 5) catch unreachable).value; // As above.
    }
    return sink;
}
