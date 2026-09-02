//! Microbenchmarks for the decode and encode paths, run as `zig build bench`.
//!
//! In-process rather than hparse's subprocess-per-implementation shape: there
//! is nothing to compare against yet. When there is — nghttp2's HPACK is the
//! obvious first — it arrives as hparse does it, a C binary under `bench/`
//! compiled by Zig's bundled clang, outside `src/` and outside the lint's
//! walk. The reporting table below is already the shape that comparison wants.
//!
//! Two footguns this harness exists to have gotten right once, both learned in
//! hparse:
//!
//! 1. **ReleaseFast is hardcoded**, not offered. `standardOptimizeOption`'s
//!    `preferred_optimize_mode` does *not* do this — it still yields Debug
//!    unless `-Drelease` is passed, which produces numbers that mean nothing.
//! 2. **`use_llvm` is set** in build.zig. Zig 0.16's self-hosted x86_64 backend
//!    scalarizes `@Vector` code, and HPACK's Huffman decode is exactly the kind
//!    of table-and-vector work that would silently lose an order of magnitude.
//!
//! Read the numbers as bands across runs, never as single values. `min` is the
//! least noisy signal on a laptop; `mean` and `max` say how much the machine
//! was interfering while it was collected.

const std = @import("std");
const bench_options = @import("bench_options");

const hpack = @import("hpack");

/// Always on, whatever the optimize mode says.
///
/// `std.debug.assert` is elided in ReleaseFast, which this file hardcodes — so
/// a setup check written with it does not run, and a workload that quietly
/// decoded half of what it claimed would be reported as a fast one. The library
/// has `-Dassertions` for that choice; a benchmark's own checks should not be
/// switchable at all.
fn assert(ok: bool) void {
    if (!ok) @panic("bench: check failed");
}

const examples = hpack.rfc7541_examples;

/// The four RFC 7541 Appendix C stories are the workload rather than a
/// synthetic string, for the reason hparse benchmarks against real requests:
/// Huffman throughput depends entirely on the code-length distribution of the
/// input, and header text is nothing like uniform bytes. All 98 symbols with
/// codes of 15 bits or fewer are printable ASCII, and ten of the shortest five
/// are `0 1 2 a c e i o s t`.
const stories = examples.stories;

/// A realistic single value, for the kernel-only workloads: a date header, 29
/// octets of text in 22 of wire.
const date_text = "Mon, 21 Oct 2013 20:13:21 GMT";

/// A browser request and the response to it, of the shape a reverse proxy
/// actually forwards.
///
/// The Appendix C workload is what the RFC gives us and it is not what a proxy
/// sees: four short stories, mostly indexed references, whose longest value is a
/// 29-octet date. Issue #4 exists because a Huffman change that moved 25-46% at
/// the kernel moved 6% there — and 6% of a workload that unrepresentative is not
/// a number to decide anything with.
///
/// The values here are long on purpose and the lengths are the point: a real
/// session cookie is hundreds of octets, a `set-cookie` carries attributes, and
/// a content-security-policy is longer than most of the block.
const heavy_request = [_]hpack.Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "shop.example.com" },
    .{ .name = ":path", .value = "/catalog/category/womens-outerwear?page=3&sort=price_asc&color=black&size=m" },
    .{ .name = "user-agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36" },
    .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" },
    .{ .name = "accept-language", .value = "en-GB,en-US;q=0.9,en;q=0.8,ru;q=0.7" },
    .{ .name = "accept-encoding", .value = "gzip, deflate, br, zstd" },
    .{ .name = "referer", .value = "https://shop.example.com/catalog/category/womens-outerwear?page=2&sort=price_asc" },
    .{ .name = "cookie", .value = "session_id=8f14e45fceea167a5a36dedd4bea2543; csrf_token=c9f0f895fb98ab9159f51fd0297e236d; " ++
        "cart=eyJpdGVtcyI6W3siaWQiOjEyMzQsInF0eSI6Mn0seyJpZCI6NTY3OCwicXR5IjoxfV19; " ++
        "_ga=GA1.2.1234567890.1698765432; _gid=GA1.2.9876543210.1698765432; " ++
        "locale=en-GB; currency=GBP; consent=analytics:1,marketing:0,functional:1" },
    .{ .name = "sec-ch-ua", .value = "\"Not A(Brand\";v=\"99\", \"Google Chrome\";v=\"121\", \"Chromium\";v=\"121\"" },
    .{ .name = "sec-fetch-site", .value = "same-origin" },
    .{ .name = "if-none-match", .value = "W/\"6a1f3c9b8e2d4f7a0c5b1e8d3f6a9c2b\"" },
};

const heavy_response = [_]hpack.Field{
    .{ .name = ":status", .value = "200" },
    .{ .name = "date", .value = "Fri, 22 Aug 2026 14:09:46 GMT" },
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "content-length", .value = "48213" },
    .{ .name = "cache-control", .value = "private, no-cache, no-store, max-age=0, must-revalidate" },
    .{ .name = "set-cookie", .value = "session_id=3c59dc048e8850243be8079a5c74d079; Path=/; Expires=Sat, 23 Aug 2026 14:09:46 GMT; " ++
        "Max-Age=86400; HttpOnly; Secure; SameSite=Lax; Domain=.example.com" },
    .{ .name = "set-cookie", .value = "cart=eyJpdGVtcyI6W3siaWQiOjEyMzQsInF0eSI6M31dfQ; Path=/; Secure; SameSite=Lax" },
    .{ .name = "strict-transport-security", .value = "max-age=63072000; includeSubDomains; preload" },
    .{ .name = "content-security-policy", .value = "default-src \'self\'; script-src \'self\' \'unsafe-inline\' https://cdn.example.com; " ++
        "img-src \'self\' data: https://images.example.com; frame-ancestors \'none\'" },
    .{ .name = "link", .value = "</assets/app.8f14e45f.css>; rel=preload; as=style, " ++
        "</assets/app.c9f0f895.js>; rel=preload; as=script, " ++
        "<https://images.example.com>; rel=preconnect; crossorigin" },
    .{ .name = "vary", .value = "Accept-Encoding, Accept-Language, Cookie" },
    .{ .name = "etag", .value = "W/\"6a1f3c9b8e2d4f7a0c5b1e8d3f6a9c2b\"" },
    .{ .name = "x-request-id", .value = "01JAXQ7K3M8P2N5R9T4V6W1Y0Z" },
};

/// Both blocks encoded at comptime, once with Huffman and once without.
///
/// Same fields, same order, same encoder mode — the only difference is the
/// coding, which is what makes the pair a measurement of Huffman's share rather
/// than of two unrelated workloads. `.static_only` so the two blocks are
/// independent of each other and of the order they are decoded in; a dynamic
/// context would make the second block cheap for reasons that have nothing to
/// do with Huffman.
fn encodeHeavy(
    comptime source: []const hpack.Field,
    comptime policy: hpack.Encoder.Huffman,
) []const u8 {
    comptime {
        @setEvalBranchQuota(2_000_000);
        var storage: hpack.Encoder.Storage(4096) = .{};
        var encoder = storage.encoder(.static_only);
        encoder.huffman = policy;
        var buffer: [4096]u8 = undefined;
        const encoded = encoder.encode(&buffer, source);
        // A partial block would silently make this a shorter workload.
        if (encoded.fields != source.len) @compileError("heavy block did not fit");
        const frozen: [encoded.written]u8 = buffer[0..encoded.written].*;
        return &frozen;
    }
}

const heavy_coded = [_][]const u8{
    encodeHeavy(&heavy_request, .always),
    encodeHeavy(&heavy_response, .always),
};

const heavy_raw = [_][]const u8{
    encodeHeavy(&heavy_request, .never),
    encodeHeavy(&heavy_response, .never),
};

/// Octets of name and value text across both heavy blocks, from the source
/// fields rather than from a decode.
const heavy_octets = blk: {
    var total: u64 = 0;
    for (heavy_request ++ heavy_response) |field| total += field.name.len + field.value.len;
    break :blk total;
};

/// Workloads are registered here and nowhere else, so adding one is a row
/// rather than a new file with its own timing loop to get subtly wrong.
const workloads = [_]Workload{
    .{ .name = "hpack decode", .run = benchHpackDecode },
    .{ .name = "hpack decode heavy", .run = benchHpackDecodeHeavy, .divisor = 100 },
    .{ .name = "hpack decode heavy raw", .run = benchHpackDecodeHeavyRaw, .divisor = 100 },
    .{ .name = "hpack encode", .run = benchHpackEncode },
    .{ .name = "hpack encode static", .run = benchHpackEncodeStatic },
    .{ .name = "hpack encode table miss", .run = benchEncodeTableMiss },
    .{ .name = "hpack encode table hit", .run = benchEncodeTableHit },
    .{ .name = "hpack encode table small", .run = benchEncodeTableSmall },
    .{ .name = "hpack encode table 1k", .run = benchEncodeTable1k },
    .{ .name = "hpack encode table 2k", .run = benchEncodeTable2k },
    .{ .name = "huffman decode", .run = benchHuffmanDecode },
    .{ .name = "huffman decode ref", .run = benchHuffmanDecodeReference },
    .{ .name = "huffman decode long", .run = benchHuffmanDecodeLong },
    .{ .name = "huffman decode long ref", .run = benchHuffmanDecodeLongReference },
    .{ .name = "huffman encode", .run = benchHuffmanEncode },
    // The two widths `Integer` is instantiated at, so what the wider one costs
    // is measured rather than assumed. h2 builds the first and h3 the second.
    .{ .name = "integer decode (u32)", .run = benchIntegerNarrow },
    .{ .name = "integer decode (u62)", .run = benchIntegerWide },
};

const Workload = struct {
    name: []const u8,
    /// Iterations for this row are the run's count divided by this.
    ///
    /// A row whose unit of work is a whole header block costs microseconds
    /// rather than nanoseconds, and at the default million iterations it would
    /// add seconds to a gate that runs before every commit. `ns/op` stays
    /// comparable because the divisor is applied to the count the result is
    /// divided by as well.
    divisor: u64 = 1,
    /// Runs `iterations` units of work and returns a value derived from all
    /// of them.
    ///
    /// Returning it is not enough on its own: a workload must also call
    /// `doNotOptimizeAway` on each unit's result *inside* the loop. The
    /// placeholder this harness shipped with was written without that, and
    /// ReleaseFast folded the whole loop to a constant and reported 0.000s —
    /// which is what the harness exists to not do quietly. A real decode has a
    /// live output the optimizer cannot fold, but it can still hoist an
    /// invariant parse out of the loop, so the barrier stays.
    run: *const fn (iterations: u64) u64,
};

const Result = struct {
    name: []const u8,
    /// Iterations this row actually ran, after its divisor.
    iterations: u64,
    min_ns: u64,
    mean_ns: u64,
    max_ns: u64,
};

/// Decode every Appendix C header block, each story against a fresh
/// compression context so evictions happen where the RFC says they do.
///
/// This is zoxy's hot path: a proxy decodes one request block per stream and
/// wants the fields, so the measurement includes resolving indices and copying
/// out of the dynamic table, not just the Huffman kernel.
fn benchHpackDecode(iterations: u64) u64 {
    assert(iterations >= 1);
    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        for (stories) |story| {
            var storage: hpack.DynamicTable.Storage(4096) = .{};
            var decoder = hpack.Decoder.init(storage.table(), 64 * 1024);
            for (story.examples) |example| {
                var buffer: [4096]u8 = undefined;
                var iterator = decoder.iterate(&buffer, example.wire);
                while (iterator.next() catch null) |field| {
                    // Consumed, so the decode cannot be folded away. A field
                    // the optimizer can prove is unread is a field it can
                    // decline to produce.
                    checksum +%= field.name.len +% field.value.len;
                    std.mem.doNotOptimizeAway(checksum);
                }
            }
        }
    }
    return checksum;
}

/// A header-heavy block with long values, decoded field by field.
fn benchHpackDecodeHeavy(iterations: u64) u64 {
    return benchDecodeBlocks(iterations, &heavy_coded);
}

/// The same fields, encoded without Huffman.
///
/// Not a workload anyone runs — it is the diagnostic that bounds every other
/// number here that touches Huffman. One caveat on reading it: a literal that
/// was not Huffman-coded is returned as a slice of the block itself
/// (`Decoder.readString`), so this row skips the kernel *and* the write into the
/// output buffer, while the coded row pays both. The gap is therefore the
/// kernel plus a ~1.7 KiB copy, which makes it an upper bound on Huffman's
/// share rather than the share itself.
fn benchHpackDecodeHeavyRaw(iterations: u64) u64 {
    return benchDecodeBlocks(iterations, &heavy_raw);
}

fn benchDecodeBlocks(iterations: u64, blocks: []const []const u8) u64 {
    assert(iterations >= 1);
    assert(blocks.len >= 1);
    // `next() catch null` below ends the loop on an error, so a block that
    // stopped decoding early would be timed as a shorter workload and reported
    // as a faster one. Checked once, outside the loop.
    assertBlocksDecodeWhole(blocks);

    // The blocks are compile-time-known rodata, and the other rows here take
    // the same precaution: a decode the optimizer can see through is a decode
    // it can partly precompute.
    var wire: [heavy_coded.len][]const u8 = undefined;
    for (&wire, blocks) |*slot, block| slot.* = block;
    std.mem.doNotOptimizeAway(&wire);

    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        var storage: hpack.DynamicTable.Storage(4096) = .{};
        var decoder = hpack.Decoder.init(storage.table(), 64 * 1024);
        for (wire) |block| {
            var buffer: [16 * 1024]u8 = undefined;
            var iterator = decoder.iterate(&buffer, block);
            while (iterator.next() catch null) |field| {
                checksum +%= field.name.len +% field.value.len;
                std.mem.doNotOptimizeAway(checksum);
            }
        }
    }
    return checksum;
}

/// Every block decodes to the field count and octet count it was built from.
///
/// The coded and raw variants must agree on both, or the pair is measuring two
/// different workloads and their ratio means nothing.
fn assertBlocksDecodeWhole(blocks: []const []const u8) void {
    var storage: hpack.DynamicTable.Storage(4096) = .{};
    var decoder = hpack.Decoder.init(storage.table(), 64 * 1024);
    var count: u32 = 0;
    var octets: u64 = 0;
    for (blocks) |block| {
        var buffer: [16 * 1024]u8 = undefined;
        var iterator = decoder.iterate(&buffer, block);
        while (iterator.next() catch unreachable) |field| {
            count += 1;
            octets += field.name.len + field.value.len;
        }
    }
    assert(count == heavy_request.len + heavy_response.len);
    assert(octets == heavy_octets);
}

/// Encode every Appendix C header list, each story against a fresh context.
///
/// This is zoxy's response path, and the cost centre is lookup rather than
/// Huffman: a static-table probe and, on a miss, a scan of the dynamic table's
/// hashes.
fn benchHpackEncode(iterations: u64) u64 {
    return benchEncode(iterations, .dynamic);
}

/// The same lists in static-only mode, which is zrk's path.
///
/// zrk encodes once at startup and replays, so this number is not on its hot
/// path at all. It is here as the other half of the comparison: the difference
/// between the two is what the dynamic table's bookkeeping costs.
fn benchHpackEncodeStatic(iterations: u64) u64 {
    return benchEncode(iterations, .static_only);
}

/// The body of both, which differ only in mode. Kept in one place so the two
/// numbers stay comparable: a change to one that missed the other would look
/// like a result.
/// A dynamic table saturated with distinct fields, and a field that misses it.
///
/// Issue #5 exists because `zig build bench` could not ask this. The Appendix C
/// stories keep tables of three or four entries, so the encode rows above never
/// scan more than a handful — and a miss against a full table is the case the
/// scan is written for: `lookup` walks `field_hashes` end to end, fails, then
/// walks `name_hashes` end to end.
///
/// Note what "saturated" means in practice. `entriesRequired` allows 128 slots
/// at 4 KiB because an entry cannot cost less than RFC 7541 section 4.1's 32
/// octets of assumed overhead — but 128 live entries would need every name and
/// value to be empty. Fields of a realistic size fill the same 4 KiB with about
/// half that, and the count is asserted below so the row cannot quietly become
/// a short-scan workload.
const churn_fields = blk: {
    @setEvalBranchQuota(200_000);
    var generated: [churn_count]hpack.Field = undefined;
    for (&generated, 0..) |*field, index| {
        field.* = .{
            // High-cardinality request headers, which is what actually defeats
            // a dynamic table in front of a proxy.
            .name = std.fmt.comptimePrint("x-request-context-{d:0>3}", .{index}),
            .value = std.fmt.comptimePrint("{x:0>16}-{x:0>16}", .{
                index *% 2654435761,
                index *% 40503 +% 0x9e3779b9,
            }),
        };
    }
    break :blk generated;
};

/// Distinct fields in the churn pool.
///
/// Comfortably more than the table holds, so that by the time the loop returns
/// to a field its entry has long since been evicted and the encode is a miss
/// again. A pool the size of the table would turn every second pass into a hit
/// and measure something else.
const churn_count = 192;

/// The live entries the pool actually leaves in a 4 KiB table, checked rather
/// than assumed: a change to the field shapes above that halved the scan length
/// would otherwise be invisible.
const churn_entries_min = 40;

/// `Encoder.scan_lanes`, which is private. Repeated here only so the rows can
/// assert which path they time; a mismatch shows up as a failing assert on the
/// row that changed sides, which is the outcome worth having.
const scan_lanes_bench = 8;

fn benchEncodeTableMiss(iterations: u64) u64 {
    return benchEncodeTable(iterations, .miss, 4096);
}

fn benchEncodeTableHit(iterations: u64) u64 {
    return benchEncodeTable(iterations, .hit, 4096);
}

/// The same misses against a table too small to vectorize.
///
/// Two entries, not three: the churn field is 21 + 33 + 32 = 86 octets, so 256
/// octets holds two. That is under one vector, so this row takes the *strided*
/// walk — the code the vectorized scan did not touch.
///
/// Which makes it the negative control, and the most useful row in the set. It
/// runs the identical field sequence through the identical encoder along
/// unchanged code; if it moved when `table miss` moved, the difference would be
/// alignment or layout luck from recompiling rather than the scan. It does not
/// move.
///
/// It is therefore *not* a point on the size series below. The scan's cost per
/// live entry is linear across 1k, 2k and 4k, which all take the vector path;
/// reading this row as a fourth point averages across a code-path switch.
fn benchEncodeTableSmall(iterations: u64) u64 {
    return benchEncodeTable(iterations, .miss, 256);
}

/// Two more sizes, so the claim that the difference *is* the scan can be
/// checked rather than asserted: the scan is the only part of a miss that is
/// linear in live entries, so these three rows — 11, 23 and 47 live entries,
/// all on the vector path — must fall on a line. `table small` is the control
/// and not a fourth point; see its comment.
fn benchEncodeTable1k(iterations: u64) u64 {
    return benchEncodeTable(iterations, .miss, 1024);
}

fn benchEncodeTable2k(iterations: u64) u64 {
    return benchEncodeTable(iterations, .miss, 2048);
}

const TableProbe = enum {
    /// A field in neither table: both hash arrays are walked end to end, and
    /// the field is then inserted, evicting the oldest and keeping the table
    /// saturated.
    miss,
    /// The newest entry, which matches on the first comparison and inserts
    /// nothing. The floor the miss row is read against.
    hit,
};

fn benchEncodeTable(iterations: u64, probe: TableProbe, comptime capacity: u32) u64 {
    assert(iterations >= 1);

    var storage: hpack.Encoder.Storage(capacity) = .{};
    var encoder = storage.encoder(.dynamic);
    var target: [4096]u8 = undefined;

    // Saturate before timing anything.
    for (churn_fields) |field| {
        _ = encoder.encodeField(&target, field) catch unreachable;
    }
    assert(encoder.table.count >= 1);
    // Which code path this row actually times, pinned rather than assumed. A
    // change to the field shapes that dropped a row under one vector would
    // otherwise move it silently to the untouched strided walk — which is
    // exactly what `table small` does on purpose, and what the other rows must
    // not.
    if (capacity == 4096) assert(encoder.table.count >= churn_entries_min);
    if (capacity >= 1024) assert(encoder.table.count >= scan_lanes_bench);
    if (capacity == 256) assert(encoder.table.count < scan_lanes_bench);
    // The pool has to outlast the table, or a probe would find its own entry.
    comptime assert(churn_count > capacity / @as(u32, hpack.Field.overhead));

    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        const field = switch (probe) {
            .miss => churn_fields[@intCast(index % churn_fields.len)],
            // Position zero: whatever the saturating loop inserted last.
            .hit => churn_fields[churn_fields.len - 1],
        };
        checksum +%= encoder.encodeField(&target, field) catch unreachable;
        std.mem.doNotOptimizeAway(checksum);
    }
    return checksum;
}

fn benchEncode(iterations: u64, mode: hpack.Encoder.Mode) u64 {
    assert(iterations >= 1);
    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        for (stories) |story| {
            var storage: hpack.Encoder.Storage(4096) = .{};
            var encoder = storage.encoder(mode);
            for (story.examples) |example| {
                var block: [4096]u8 = undefined;
                const encoded = encoder.encode(&block, example.fields);
                assert(encoded.fields == example.fields.len);
                checksum +%= encoded.written;
                std.mem.doNotOptimizeAway(checksum);
            }
        }
    }
    return checksum;
}

/// The Huffman kernel on its own, where a change to it shows up undiluted by
/// the representation layer above.
fn benchHuffmanDecode(iterations: u64) u64 {
    return benchDecodeKernel(iterations, date_wire, .window);
}

/// The date header's wire form, lifted from the RFC's own vectors.
const date_wire = blk: {
    for (examples.huffman_strings) |vector| {
        if (std.mem.eql(u8, vector.text, date_text)) break :blk vector.wire;
    }
    unreachable;
};

/// A long, realistic value: one set-cookie of the shape the RFC's own C.5.3
/// uses, extended with the attributes a real one carries — 132 octets of text.
const long_text = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1; " ++
    "path=/some/reasonably/long/path; domain=www.example.com; secure; httponly";

const long_wire = blk: {
    @setEvalBranchQuota(200_000);
    var buffer: [512]u8 = undefined;
    const length = hpack.huffman.encode(&buffer, long_text) catch unreachable;
    break :blk buffer[0..length].*;
};

/// The retired nibble automaton on the same value, so the two numbers are a
/// direct comparison on identical input.
fn benchHuffmanDecodeReference(iterations: u64) u64 {
    return benchDecodeKernel(iterations, date_wire, .automaton);
}

/// A longer value, where the per-call cost stops dominating.
///
/// A header value of twenty-nine octets is realistic and also short enough that
/// setting up a bit reader is a visible fraction of the work. A cookie or a
/// long location header is where a wider window is supposed to pay, so both
/// lengths are measured rather than one.
fn benchHuffmanDecodeLong(iterations: u64) u64 {
    return benchDecodeKernel(iterations, &long_wire, .window);
}

fn benchHuffmanDecodeLongReference(iterations: u64) u64 {
    return benchDecodeKernel(iterations, &long_wire, .automaton);
}

const Kernel = enum { window, automaton };

fn benchDecodeKernel(iterations: u64, wire: []const u8, kernel: Kernel) u64 {
    assert(iterations >= 1);
    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        var decoded: [1024]u8 = undefined;
        const written = switch (kernel) {
            .window => hpack.huffman.decode(&decoded, wire) catch unreachable,
            .automaton => hpack.huffman.decodeReference(&decoded, wire) catch unreachable,
        };
        assert(written >= 1);
        checksum +%= written +% decoded[0];
        std.mem.doNotOptimizeAway(checksum);
    }
    return checksum;
}

/// A validation result as a number, so that discarding it is not an option the
/// optimizer has. Accept and reject differ so that a kernel that started
/// rejecting everything would not keep the same number.
fn outcome(result: anytype) u64 {
    if (result) |_| return 1 else |_| return 2;
}

fn benchHuffmanEncode(iterations: u64) u64 {
    assert(iterations >= 1);
    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        var wire: [64]u8 = undefined;
        const written = hpack.huffman.encode(&wire, date_text) catch unreachable;
        checksum +%= written;
        std.mem.doNotOptimizeAway(checksum);
    }
    return checksum;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const runs: u64 = bench_options.runs;
    const iterations: u64 = bench_options.iterations;
    assert(runs >= 1);
    assert(iterations >= 1);

    var results: [workloads.len]Result = undefined;
    for (&results, workloads) |*result, workload| {
        result.* = measure(io, workload, runs, @max(1, iterations / workload.divisor));
    }

    report(&results, iterations);
}

/// Times `runs` repetitions of one workload and reduces them to a band.
fn measure(io: std.Io, workload: Workload, runs: u64, iterations: u64) Result {
    assert(runs >= 1);
    assert(iterations >= 1);

    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u128 = 0;

    var run: u64 = 0;
    while (run < runs) : (run += 1) {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        const produced = workload.run(iterations);
        const finished = std.Io.Clock.awake.now(io).nanoseconds;
        std.mem.doNotOptimizeAway(produced);
        assert(finished >= started);

        const elapsed_ns: u64 = @intCast(finished - started);
        min_ns = @min(min_ns, elapsed_ns);
        max_ns = @max(max_ns, elapsed_ns);
        total_ns += elapsed_ns;
    }
    assert(run == runs);
    assert(min_ns <= max_ns);

    return .{
        .name = workload.name,
        .iterations = iterations,
        .min_ns = min_ns,
        .mean_ns = @intCast(total_ns / runs),
        .max_ns = max_ns,
    };
}

fn report(results: []const Result, iterations: u64) void {
    assert(results.len >= 1);
    assert(iterations >= 1);

    std.debug.print("\n{s:<24} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        "workload", "min", "mean", "max", "ns/op",
    });
    std.debug.print("{s}\n", .{"-" ** 77});
    for (results) |result| {
        assert(result.min_ns <= result.max_ns);
        std.debug.print("{s:<24} {d:>11.3}s {d:>11.3}s {d:>11.3}s {d:>12.3}\n", .{
            result.name,
            seconds(result.min_ns),
            seconds(result.mean_ns),
            seconds(result.max_ns),
            nanosecondsPerOp(result.min_ns, result.iterations),
        });
    }
    // Which build this was. The numbers move by tens of percent between the
    // two — `hpack decode` most of all — so a table without this
    // line is a table that can be compared against the wrong thing.
    std.debug.print(
        "\n{d} iterations per run, assertions {s}. " ++
            "Compare bands across runs, never single numbers.\n",
        .{ iterations, if (hpack.assertions.enabled) "on" else "off" },
    );
}

fn seconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s;
}

/// Reported off `min`, which is the least noise-contaminated of the three.
fn nanosecondsPerOp(min_ns: u64, iterations: u64) f64 {
    assert(iterations >= 1);
    return @as(f64, @floatFromInt(min_ns)) / @as(f64, @floatFromInt(iterations));
}

const IntegerNarrow = hpack.integer.Integer(u32);
const IntegerWide = hpack.integer.Integer(u62);

/// 1337 in a five-bit prefix: three octets, which is the shape a string length
/// takes once it leaves the prefix.
const integer_wire = [_]u8{ 0x1f, 0x9a, 0x0a };

fn benchIntegerNarrow(iterations: u64) u64 {
    return benchInteger(IntegerNarrow, iterations);
}

/// The same octets at QPACK's width, so the row isolates what the wider
/// instantiation costs rather than what a longer value costs.
fn benchIntegerWide(iterations: u64) u64 {
    return benchInteger(IntegerWide, iterations);
}

fn benchInteger(comptime integer: type, iterations: u64) u64 {
    assert(iterations >= 1);
    var wire = integer_wire;
    var checksum: u64 = 0;
    var index: u64 = 0;
    while (index < iterations) : (index += 1) {
        // The input is made opaque inside the loop, not merely the result
        // consumed after it: a `const` encoding is constant-folded and the
        // whole loop becomes a multiplication.
        std.mem.doNotOptimizeAway(&wire);
        checksum +%= (integer.decode(&wire, 5) catch unreachable).value; // A well-formed three-octet encoding.
    }
    return checksum;
}
