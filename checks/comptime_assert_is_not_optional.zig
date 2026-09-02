//! A fixture that must FAIL to compile, whichever way `-Dassertions` was set.
//!
//! The claim: a `comptime` assertion is a proof the package rests on, and the
//! build option does not reach it. That cannot be stated in a `test` block,
//! because the failing case is a compile error rather than a failing test — and
//! the obvious attempt, `comptime assert(true)`, passes even if the
//! `@inComptime()` branch in `src/assert.zig` were deleted outright. A
//! tautology wearing a proof's name.
//!
//! It matters more here than in a package whose comptime assertions are
//! incidental: `huffman.zig` *builds* its decode window, its nibble automaton
//! and its canonical table in comptime blocks that assert their way through the
//! construction. An assertion the option could delete there would be a table
//! silently built wrong.

const hpack = @import("hpack");

comptime {
    hpack.assertions.assert(1 == 2);
}
