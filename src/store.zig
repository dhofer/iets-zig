//! Pure store-layer functions: hashing, NAR, store paths and derivations.
//! No dependency on the evaluator.

pub const hash = @import("store/hash.zig");
pub const path = @import("store/path.zig");
pub const nar = @import("store/nar.zig");
pub const json = @import("store/json.zig");
pub const drv = @import("store/drv.zig");
pub const source = @import("store/source.zig");
pub const locate = @import("store/locate.zig");
pub const drvdiff = @import("store/drvdiff.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("store/aterm_crosscheck.zig");
    _ = @import("store/nar_parity.zig");
}
