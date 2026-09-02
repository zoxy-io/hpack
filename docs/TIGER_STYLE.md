# hpack style — adopted from h2's, which adopted zoxy's

hpack adopts [h2's TIGER_STYLE](https://github.com/zoxy-io/h2/blob/main/docs/TIGER_STYLE.md),
which adopts [zoxy's](https://github.com/zoxy-io/zoxy/blob/main/docs/TIGER_STYLE.md),
which adopts [TigerBeetle's](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
Those are the source of truth. This file records only the **deltas** that being
the bottom of the dependency graph forces.

> Design goals, in priority order: **safety, performance, developer experience.**

---

## What being two levels down changes

### The assertions option must be forwarded, not defaulted

Every other package in the organisation is one dependency away from a binary, so
`-Dassertions` defaulting to on is enough: a consumer that wants it off says so.
This one is two away. zrk depends on h2 and h3; those depend on this. If h2 and
h3 called `b.dependency("hpack", .{})` without passing the option through, a
consumer that turned assertions off would still be running this package's — and
would have no way to tell.

So: **h2 and h3 forward the option, and that line is load-bearing.** A review of
either package's `build.zig` should check it the way it checks a lint rule.

### A dependency here is one nobody chose

`build.zig.zon`'s `dependencies` table is empty and stays empty. That is the
same rule h2 and h3 have, with more force behind it: a dependency added here is
inherited by h2, h3, zoxy, zrk and anything they ship, none of which were asked.
`@cImport` is lint-forbidden for the same reason.

### The API is shared, so a change is a change to two protocols

An adjustment that suits HPACK and inconveniences QPACK is not a local decision.
The concrete rule: **anything that differs between the two protocols is a
parameter, never a branch.** `Integer(Value)` is the whole of that difference
today, and if a second one appears it takes the same shape rather than growing
an `if (protocol == ...)`.

## What is unchanged and matters most here

### Put a limit on everything

These two primitives *are* the unbounded surfaces of field compression:

- A prefixed integer's continuation run has no length. RFC 7541 §5.1 sets no
  limit and says an implementation MUST guard against integers it cannot
  represent, so an unbounded run of high-bit octets is legal-looking input a
  trusting decoder follows forever. The bound lives at the primitive because a
  call site that forgets it is silent.
- A Huffman string's symbol boundaries are not on octet boundaries, and its
  decoding can reach 8/5 of its input. The target's capacity is the bomb bound,
  and it is the caller's to size.

Every bound is a named constant with a comptime assert relating it to its
neighbours, and every one traces to an RFC clause that the constant names.

### Comptime assertions are proofs, not decoration

`huffman.zig` *builds* its decode window, its nibble automaton and its canonical
table in `comptime` blocks that assert their way through the construction, and
`integer.zig` proves that its `u64` accumulator cannot overflow at whatever
width it was instantiated with. An assertion the `-Dassertions` option could
delete there would be a table silently built wrong, which is why `assert`
detects comptime and ignores the option — and why
`checks/comptime_assert_is_not_optional.zig` is a fixture the build requires to
*fail* to compile.

### Two kernels, one behaviour

The package ships two Huffman decoders and the faster one is what consumers
call. The rule that makes that safe: **they must be indistinguishable — same
octets, same error, same amount written, including on the error paths.** That is
a fuzz target rather than a test, because the interesting inputs are the ones
that reach an escape or an accumulator refill, and it is not a performance
question: a faster decoder that accepts one input the reference rejects is a
second spelling of a header value, which is a request-smuggling primitive.

If the two ever have to disagree, the faster one is deleted.

## Threat model

zoxy's, which is the stricter one, unchanged: hostile input from the open
internet, on the assumption that the peer is trying to make this code allocate,
loop, or read out of bounds. Both consumers' consumers point these decoders at
different populations, and a codec with two threat models is a codec with one
threat model and a bug.

## Gates

- `zig build ci` on all three legs, as h2 and h3.
- **A decode or encode path changed without `zig build bench` numbers in the
  commit message** is a finding. The window-versus-automaton row is the one that
  decides a design question, so it is the one to quote.
- **Every parsing change ships with its fuzz coverage.** `fuzz/` holds the
  targets; a decode path without one is not done.
- RFC 7541 Appendix C's Huffman strings ship as fixtures and run in CI.
