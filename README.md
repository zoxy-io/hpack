# hpack

![GitHub License](https://img.shields.io/github/license/zoxy-io/hpack?color=orange)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-x86_64-linux.yml?label=x86_64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-aarch64-linux.yml?label=aarch64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-x86_64-windows.yml?label=x86_64-windows)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-macos.yml?label=macos)

The two primitives HPACK is built out of — RFC 7541's Huffman code and its
prefixed integer — and the two QPACK adopts unchanged.

## Scope

* **RFC 7541 §5.2 and Appendix B — the Huffman code.** Encoder, decoder, and a
  second decoder kept as a cross-check.
* **RFC 7541 §5.1 — the prefixed integer**, parameterised by value width.
* `memory.overlaps`, the span-arithmetic guard both consumers assert with
  before a `@memcpy` that is undefined on overlap.

The layers above them stay with the protocol that owns them: HPACK's field line
representations, static table and dynamic table are in
[zoxy-io/h2](https://github.com/zoxy-io/h2), and QPACK's are in
[zoxy-io/h3](https://github.com/zoxy-io/h3). Those are genuinely different —
QPACK's static table is a different 99-entry table indexed from zero, and its
dynamic table is addressed relative to an insert count that HPACK has no notion
of. What the two protocols share is exactly what RFC 9204 §4.1.1 and §4.1.2
adopt *verbatim*, and that is what is here.

## Why it exists

Before this package there were two copies of a 900-line vectorised Huffman
decoder in one organisation, and a bug fixed in one was a bug still live in the
other. The alternatives were considered in
[h3's design notes](https://github.com/zoxy-io/h3/blob/main/docs/DESIGN.md#7-open-decisions):
copy it again, have h3 depend on h2, or extract. Extraction won because h2
depending on h3 or the reverse would be a cycle waiting to happen the first time
either needed something from the other, and because "the RFC 7541 primitives" is
a real boundary rather than a convenient one — RFC 9204 draws it in its own text.

## The one thing the two protocols differ on

How wide an integer can be — and it is a parameter, not a fork:

```zig
const integer = hpack.integer.Integer(u32); // HPACK: bounded by HTTP/2 SETTINGS
const integer = hpack.integer.Integer(u62); // QPACK: bounded by a QUIC stream offset
```

RFC 7541 §5.1 puts no ceiling on a value at all. Every real ceiling comes from
the *field* being encoded, so the width belongs to the protocol rather than to
the encoding — and naming it at the import puts the bound where a reader can see
it. Everything derived from it follows: `Integer(u32)` allows five continuation
octets and `Integer(u62)` allows nine, because that is how many 7-bit groups
each width needs, and a further octet could not describe a representable value.

## Properties

* Never allocates — no `std.mem.Allocator` in the public API.
* Caller-owned, caller-sized buffers. A Huffman decoding is at most 8/5 of its
  input, and the target's capacity is what bounds a compression bomb.
* Zero dependencies beyond the Zig toolchain. This package sits at the bottom of
  the organisation's graph, so a dependency here is one every consumer inherits
  without asking.
* Assertions ship by default. `-Dassertions=false` removes them — and because
  this package is *two* levels below a binary, the option has to be **forwarded**
  by h2 and h3 rather than left to default. Both do; see
  [`src/assert.zig`](src/assert.zig).
* No I/O types anywhere. `zig build lint` enforces it.

## Usage

A field value, encoded the way both protocols encode one — a length in a
prefixed integer whose top bit says "Huffman", then the string:

```zig
const hpack = @import("hpack");
const integer = hpack.integer.Integer(u32);

// Out: the string first, so the length is written once rather than the string twice.
var coded: [64]u8 = undefined;
const coded_length = try hpack.huffman.encode(&coded, "www.example.com");

var wire: [80]u8 = undefined;
const header_length = try integer.encode(&wire, coded_length, 7, 0x80);
@memcpy(wire[header_length..][0..coded_length], coded[0..coded_length]);

// In: the length and its flag, then the string.
const length = try integer.decode(&wire, 7);
const is_huffman = wire[0] & 0x80 != 0;

var text: [64]u8 = undefined;
const written = try hpack.huffman.decode(&text, wire[length.octets..][0..length.value]);
```

[`example/strings.zig`](example/strings.zig) is that, compiled and run —
`zig build example`, and `zig build ci` runs it.

## The two Huffman decoders

`decode` reads twelve bits per lookup and emits up to two symbols;
`decodeReference` is the nibble automaton of Pajarola's *Fast Prefix Code
Processing* (2003), which nghttp2 has used since 2014. `decode` is the one
consumers call, and the property that makes shipping it safe is that the two are
**indistinguishable** — same octets, same errors, same amount written, including
on the error paths. That is a fuzz target ([`fuzz/fuzz.zig`](fuzz/fuzz.zig)),
not a benchmark, because a faster decoder that accepts one input the reference
rejects is a second spelling of a header value and therefore a smuggling
primitive.

**Which of the two is actually faster is an open question**, and the honest
answer today is "it depends on the machine, and nobody has re-measured".
`decode` was chosen in h2 against a measurement on an M-series laptop. On an
x86_64 Linux box the ordering inverts, and by a wide margin:

| row | `decode` (window) | `decodeReference` (automaton) |
|---|---:|---:|
| `huffman decode` (13 octets) | 48.9 ns | **31.5 ns** |
| `huffman decode long` (~170 octets) | 261.0 ns | **201.8 ns** |

`zig build bench`, 5 x 1M, and the same numbers come out of h2 at the commit
this package was extracted from — so this is a pre-existing question the move
inherited, not one it introduced. The window's other property still holds and is
the reason it is not simply deleted: its table is 16 KiB where the automaton's
is 16352 octets plus a second 16 KiB of transitions, and h2's argument was about
staying resident beside a proxy's working set rather than about a tight loop.
Settling it wants a measurement on both architectures with cache counters, not
another laptop run.

A consumer that never calls `decodeReference` does not pay for its table: a
binary calling only `decode` is 16352 octets smaller.

## Gates

```sh
zig build ci      # format check, tests, the lint's own tests, fuzz corpus, boundary lint
zig build ci -Doptimize=ReleaseFast                     # zoxy's build
zig build ci -Doptimize=ReleaseFast -Dassertions=false  # zrk's build
zig build bench   # Huffman and integer microbenchmarks (ReleaseFast)
zig build fuzz    # replay the fuzz corpus; --fuzz to actually fuzz
zig build fmt-fix # reformat in place
zig build example # build and run the usage example above
```

## Consumers

* [zoxy-io/h2](https://github.com/zoxy-io/h2) — HPACK, at `Integer(u32)`.
* [zoxy-io/h3](https://github.com/zoxy-io/h3) — QPACK, at `Integer(u62)`.

Both are in turn consumed by [zoxy](https://github.com/zoxy-io/zoxy) (reverse
proxy, libxev completion callbacks) and [zrk](https://github.com/zoxy-io/zrk)
(load generator, zio green threads through `std.Io`), which is why nothing here
names an I/O type: they do not share a runtime.
