# hpack

![GitHub License](https://img.shields.io/github/license/zoxy-io/hpack?color=orange)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-x86_64-linux.yml?label=x86_64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-aarch64-linux.yml?label=aarch64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-x86_64-windows.yml?label=x86_64-windows)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-macos.yml?label=macos)

HPACK (RFC 7541): header compression for HTTP/2, whole — and the two primitives
HTTP/3 borrows from it.

## Scope

**RFC 7541 entire.** `Decoder` and `Encoder` are the entry points.

* **§6 field line representations** — indexed, literal with and without
  indexing, never-indexed, and the dynamic table size update.
* **§2.3 and Appendix A — the tables.** The 61-entry static table, and a
  dynamic table whose storage is the caller's, sized by the
  `SETTINGS_HEADER_TABLE_SIZE` it advertises. A caller advertising `0` passes no
  buffer and the table disappears.
* **§5.2 and Appendix B — the Huffman code.** Encoder, decoder, and a second
  decoder kept as a cross-check.
* **§5.1 — the prefixed integer**, parameterised by value width.
* `memory.overlaps`, the span-arithmetic guard the table and the decoder assert
  with before a `@memcpy` that is undefined on overlap.

Out of scope: everything above field compression. HTTP/2's framing and its
message rules are [zoxy-io/h2](https://github.com/zoxy-io/h2), which re-exports
this package as `h2.hpack`. QPACK's own layers are
[zoxy-io/h3](https://github.com/zoxy-io/h3) — its static table is a different
99-entry table indexed from zero, and its dynamic table is addressed relative to
an insert count HPACK has no notion of, so those genuinely are not shared.

## Why it is not a directory inside h2

RFC 9204 adopts two of these pieces verbatim: §4.1.1 takes the prefixed integer
and §4.1.2 takes the Huffman code, with the same 257-symbol table. So h3 needs
them, and the choice was to copy them, to have h3 depend on h2, or to extract.

Copying would have put a second 900-line vectorised Huffman decoder in the
organisation, where a bug fixed in one stays live in the other. Depending on h2
would have made h3 build HTTP/2's frame codec to get a Huffman table.

Extraction won — and RFC 7541 came out **whole** rather than in the two shared
pieces, so that the package holding it is named for what it holds. h3 imports
`huffman` and `integer` and nothing else; Zig prunes the rest, so it costs h3
nothing but a line in `build.zig.zon`.

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
  the organisation's graph — h2 and h3 depend on it and it depends on nothing —
  so a dependency here is one every consumer inherits without asking.
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

* [zoxy-io/h2](https://github.com/zoxy-io/h2) — the whole package, re-exported
  as `h2.hpack`, at `Integer(u32)`. HTTP/2 SETTINGS values are `u32` and every
  HPACK index, length and table size is bounded by one.
* [zoxy-io/h3](https://github.com/zoxy-io/h3) — `huffman` and `integer` only, at
  `Integer(u62)`, because QPACK's values are bounded by a QUIC stream offset.

Both are in turn consumed by [zoxy](https://github.com/zoxy-io/zoxy) (reverse
proxy, libxev completion callbacks) and [zrk](https://github.com/zoxy-io/zrk)
(load generator, zio green threads through `std.Io`), which is why nothing here
names an I/O type: they do not share a runtime.
