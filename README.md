# hpack

![GitHub License](https://img.shields.io/github/license/zoxy-io/hpack?color=orange)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-x86_64-linux.yml?label=x86_64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-aarch64-linux.yml?label=aarch64-linux)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-x86_64-windows.yml?label=x86_64-windows)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/zoxy-io/hpack/test-macos.yml?label=macos)

HPACK ([RFC 7541](https://www.rfc-editor.org/rfc/rfc7541)) header compression
for Zig 0.16.

hpack implements the whole RFC: the encoder and decoder, the static and
dynamic tables, the Huffman code and the prefixed integer. The last two are
also what QPACK (RFC 9204) adopts unchanged, so they are usable on their own
and parameterised by integer width. The library never allocates, has no
dependencies, and never reads from a socket: bytes in, fields out.

## What is implemented

| Section | Coverage |
|---|---|
| §2.3, Appendix A tables | The 61-entry static table, and a dynamic table over caller-owned storage sized by the `SETTINGS_HEADER_TABLE_SIZE` you advertise |
| §5.1 prefixed integer | `Integer(u32)` for HTTP/2, `Integer(u62)` for QPACK; the width bounds the continuation octets |
| §5.2, Appendix B Huffman | Encoder and a twelve-bit-window decoder, plus a second reference decoder the fuzz targets hold the first one indistinguishable from |
| §6 representations | Indexed, literal with and without indexing, never-indexed, and dynamic table size update, in both directions |
| Appendix C | All twelve worked examples, machine-extracted and checked for exact output, not just round-trip |

The decoder is also checked against 600 header blocks from
[http2jp/hpack-test-case](https://github.com/http2jp/hpack-test-case),
produced by nghttp2 and haskell-http2 under five encoding strategies, vendored
under `corpus/`.

## Installation

```sh
zig fetch --save git+https://github.com/zoxy-io/hpack
```

```zig
// build.zig
const hpack = b.dependency("hpack", .{
    .target = target,
    .optimize = optimize,
    // Optional. Assertions are on in every optimize mode unless disabled here.
    // .assertions = false,
});
exe.root_module.addImport("hpack", hpack.module("hpack"));
```

## Usage

Encoding a header block. Storage for the dynamic table and the encoder's
hashes is a fixed-size value sized at compile time:

```zig
const hpack = @import("hpack");

var storage: hpack.Encoder.Storage(4096) = .{};
var encoder = storage.encoder(.dynamic); // or .static_only, for a block to replay

var block: [256]u8 = undefined;
const encoded = encoder.encode(&block, &.{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":path", .value = "/" },
    .{ .name = "authorization", .value = token, .never_indexed = true },
});
// encoded.fields is how many fit; encoded.written is the block length.
```

Decoding one. Fields come out of an iterator, and each field's slices borrow
from the buffer until the next call:

```zig
var table_storage: hpack.DynamicTable.Storage(4096) = .{};
var decoder: hpack.Decoder = .init(table_storage.table(), list_size_max);

var field_buffer: [8 * 1024]u8 = undefined;
var iterator = decoder.iterate(&field_buffer, block[0..encoded.written]);
while (try iterator.next()) |field| {
    // field.name, field.value
}
```

The two primitives on their own, as QPACK uses them:

```zig
const integer = hpack.integer.Integer(u62);

var coded: [64]u8 = undefined;
const coded_length = try hpack.huffman.encode(&coded, "www.example.com");

var wire: [80]u8 = undefined;
const header_length = try integer.encode(&wire, coded_length, 7, 0x80); // 7-bit prefix, Huffman flag
@memcpy(wire[header_length..][0..coded_length], coded[0..coded_length]);

const length = try integer.decode(&wire, 7);
var text: [64]u8 = undefined;
const written = try hpack.huffman.decode(&text, wire[length.octets..][0..length.value]);
```

[`example/strings.zig`](example/strings.zig) is that last snippet as a
program, compiled and run as part of `zig build ci`.

Sizing is the caller's. A Huffman decoding is at most 8/5 of its input, so
the target buffer's capacity is what bounds a compression bomb, and the
decoder's `list_size_max` is the `SETTINGS_MAX_HEADER_LIST_SIZE` you
advertise.

## Design constraints

- **No allocator.** `std.mem.Allocator` does not appear in the public API or
  under `src/`. Table storage and output buffers are caller-owned.
- **No dependencies.** Nothing beyond the Zig toolchain.
- **No I/O.** No `std.Io`, `std.posix`, `std.net` or `std.fs` under `src/`.
  The build's lint step enforces this.
- **HPACK and QPACK differ by parameter, not by branch.** The integer width is
  the whole of that difference today.
- **Assertions are a build option.** On by default in every optimize mode,
  removed with `-Dassertions=false`. See [`src/assert.zig`](src/assert.zig).

## Building and testing

```sh
zig build ci                                             # fmt, unit tests, fuzz corpus, interop corpus, example, lint
zig build ci -Doptimize=ReleaseFast                      # release, assertions on
zig build ci -Doptimize=ReleaseFast -Dassertions=false   # release, assertions off
zig build fuzz --fuzz                                    # coverage-guided fuzzing
zig build bench                                          # Huffman and integer microbenchmarks
zig build fmt-fix                                        # reformat
```

CI runs the three `ci` invocations above on x86_64 and aarch64 Linux,
Windows and macOS.

## Used by

- [zoxy-io/h2](https://github.com/zoxy-io/h2) re-exports this package as
  `h2.hpack`.
- [zoxy-io/h3](https://github.com/zoxy-io/h3) uses `huffman` and `integer`
  for QPACK.

## Documentation

- [docs/TIGER_STYLE.md](docs/TIGER_STYLE.md): the coding rules the lint and
  the review enforce.
- [corpus/README.md](corpus/README.md): the vendored interoperability corpus
  and how the files were chosen.

## License

[MIT](LICENSE)
