//! Fetching: an HTTP client, a spooled archive read by offset, and an archive
//! unpacker. None of it knows about flakes; a locked flake input is one caller
//! (`source/`, not ported yet), the fetch builtins are another. Ported from
//! ../iets/src/fetch/.

pub const bzip2 = @import("fetch/bzip2.zig");
pub const tar = @import("fetch/tar.zig");
pub const spool = @import("fetch/spool.zig");
pub const unpack = @import("fetch/unpack.zig");
pub const roots = @import("fetch/roots.zig");
pub const http = @import("fetch/http.zig");
pub const xz = @import("fetch/xz.zig");
pub const zstd = @import("fetch/zstd.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
