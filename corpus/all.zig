//! Root of the corpus test binary. It needs an allocator and a JSON parser,
//! and 828 KiB of fixtures, none of which belong in a package that promises no
//! allocator and ships nothing but source to its consumers.

test {
    _ = @import("hpack.zig");
}
