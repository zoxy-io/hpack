//! `assert`, and the build option that decides whether it ships.
//!
//! ## Why this is not `std.debug.assert`
//!
//! `std.debug.assert` is `if (!ok) unreachable`, and in `ReleaseFast` and
//! `ReleaseSmall` `unreachable` is undefined behaviour rather than a trap. The
//! optimizer is therefore entitled to assume the condition holds and delete the
//! check — so a consumer building for speed gets a stack whose safety argument
//! rests on checks that are not in the binary.
//!
//! Inherited from zoxy-io/h2 along with the Huffman codec it guards, and the
//! argument survives the move intact.
//!
//! ## The rule this makes load-bearing
//!
//! An assertion may not be the only guard on a `catch unreachable`. Once
//! assertions are optional, an `unreachable` behind one is reachable — and in
//! ReleaseFast that is undefined behaviour rather than a panic. h2 violated the
//! rule exactly once, in `Encoder.encodeSizeUpdate`, where the guard on a
//! peer-supplied capacity was an assertion and the fallout was a spin that
//! could not be interrupted. If an `unreachable` is reachable when the
//! assertions are gone, the guard is a returned error and the assertion beside
//! it is documentation.
//!
//! ## The option, and why it must be forwarded
//!
//! zoxy wants assertions on in production: it is the security boundary and it
//! points this decoder at the open internet. zrk is a latency-measuring tool
//! whose whole pitch is not injecting client-side noise into the measurement. A
//! library cannot decide that for its consumers, so `-Dassertions` decides it,
//! defaulting to on.
//!
//! This package is unusual in the organisation in being two levels down from a
//! binary: zrk depends on h2 and h3, and those depend on this. So the option
//! has to be *forwarded* rather than left to default, or a consumer that turned
//! its own assertions off would still be running this package's:
//!
//!     const hpack = b.dependency("hpack", .{
//!         .target = target,
//!         .optimize = optimize,
//!         .assertions = assertions, // forwarded, not defaulted
//!     });
//!
//! ## Comptime is not part of the bargain
//!
//! An assertion evaluated during the build costs a consumer nothing at run
//! time, and several of this package's are proofs its correctness rests on:
//! `huffman.zig` builds its decode window, its nibble automaton and its
//! canonical table in `comptime` blocks that assert their way through the
//! construction, and `integer.zig` proves that its `u64` accumulator cannot
//! overflow at whatever width it was instantiated with. Turning those off with
//! the option would silently delete the proofs, so `assert` detects comptime
//! and ignores the option there.

const std = @import("std");
const build_options = @import("build_options");

/// Whether run-time assertions are compiled in. Public so a consumer can branch
/// on it — a test that measures assertion behaviour has to know — and so the
/// benchmark can print which build it measured.
pub const enabled: bool = build_options.assertions;

/// Check an invariant.
///
/// A failure is a bug in this package or a violated precondition in its caller,
/// never a malformed input: every wire-format error has a named error value and
/// a path that returns it. So this is the "downgrade correctness bugs into
/// liveness bugs" trade of docs/TIGER_STYLE.md — a crash a consumer can see and
/// report, in place of a wrong answer it cannot.
pub inline fn assert(ok: bool) void {
    // At comptime the option does not apply; see the note above. `unreachable`
    // here is a compile error rather than undefined behaviour, which is exactly
    // what a failed proof should be.
    if (@inComptime()) {
        if (!ok) unreachable;
        return;
    }
    if (!enabled) return;
    if (!ok) {
        @branchHint(.cold);
        fail();
    }
}

/// Out of line, so a holding assertion costs a not-taken branch and nothing
/// else — no panic path inlined into a decode loop, and no register pressure
/// from one.
fn fail() noreturn {
    @branchHint(.cold);
    @panic("hpack: assertion failed");
}

test "assert admits what is true" {
    assert(true);
    assert(1 + 1 == 2);
}

test "the option is what the build said it was" {
    // Weak on purpose. The claim worth proving — that a *comptime* assertion is
    // checked whichever way `-Dassertions` was set — cannot be made in a `test`
    // block, because the failing case is a compile error rather than a failing
    // test. The real gate is `checks/comptime_assert_is_not_optional.zig`, a
    // fixture `zig build checks` requires to *fail* to compile.
    try std.testing.expectEqual(@import("build_options").assertions, enabled);
}
