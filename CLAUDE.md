# hpack

HPACK (RFC 7541) in Zig 0.16, whole: the Huffman code, the prefixed integer,
both tables, and the field line representations either side of them.

It is a package of its own rather than a directory in h2 because QPACK adopts
two of its pieces unchanged (RFC 9204 sections 4.1.1 and 4.1.2), so
[zoxy-io/h3](https://github.com/zoxy-io/h3) builds against `huffman` and
`integer` and nothing else here. [zoxy-io/h2](https://github.com/zoxy-io/h2)
re-exports the whole package as `h2.hpack`, which is the spelling its own
consumers already use. Read before writing code:

- [docs/TIGER_STYLE.md](docs/TIGER_STYLE.md) — enforced coding rules. h2's, plus
  the deltas being the bottom of the dependency graph forces.
- [README.md](README.md) — scope, and what is deliberately *not* here.

## Gates — run before every commit

- `zig build ci` — format check, unit tests, the lint's own tests, the fuzz
  corpus, the usage example and the boundary lint. Exactly what CI runs.
- `zig build ci -Doptimize=ReleaseFast` and
  `zig build ci -Doptimize=ReleaseFast -Dassertions=false` — the two builds that
  ship. Not optional: `-Dassertions=false` in Debug removes the `if (!ok)` and
  nothing else, so only a release mode tests that the checks are gone.
- `zig build bench` — **not optional for a change that touches a decode or
  encode path.** Quote the numbers in the commit message. Compare bands across
  runs, never single numbers.

## Review — required before every commit

Run the `tiger-style-reviewer` agent on the diff before committing a slice.

## Policies

- **No dependencies, with more force than elsewhere.** A dependency added here
  is inherited by h2, h3, zoxy and zrk, none of which were asked. `@cImport` is
  lint-forbidden.
- **No allocator, no I/O types.** Lint-enforced. Every buffer is caller-owned
  and caller-sized.
- **Anything that differs between HPACK and QPACK is a parameter, never a
  branch.** `Integer(Value)` is the whole of that difference today.
- **The `-Dassertions` option must be forwarded by consumers, not defaulted.**
  This package is two levels below a binary; see docs/TIGER_STYLE.md. A review
  of h2's or h3's `build.zig` should check that line.
- **`std.debug.assert` is lint-forbidden.** Use `@import("assert.zig").assert`.
- **The two Huffman decoders must stay indistinguishable** — same octets, same
  error, same amount written, on every path. That is a fuzz target, and it is a
  correctness rule rather than a performance one: a faster decoder that accepts
  one input the reference rejects is a second spelling of a header value.
  Note **which of the two is faster is currently an open question** — the
  ordering inverts between aarch64 and x86_64, and README.md has the numbers.
  Do not repeat the "the window is faster" claim without a fresh measurement.
- **Every bound is a named constant** with a comptime assert relating it to its
  neighbours and a comment naming the RFC clause it comes from.
- **Every parsing change ships with its fuzz coverage.**
- **Write to zoxy's threat model**, which is the stricter one.
- **Workflow:** small slices, one commit per slice, descriptive commit messages.
  Push and open PRs only when asked. A change to the public API here is a change
  to h2 and h3 both — say so in the commit message, and remember h2 re-exports
  this package wholesale, so a rename here reaches zrk and zoxy.
