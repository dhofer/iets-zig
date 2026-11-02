//! Builds: the dispatcher's backends and the job fan-out. Ported from
//! ../iets/src/build/; so far only what the `grpc://` backend needs.

pub const backend = @import("build/backend.zig");
pub const fanout = @import("build/fanout.zig");
pub const executor = @import("build/executor.zig");
pub const upload = @import("build/upload.zig");
pub const dispatch = @import("build/dispatch.zig");
pub const event = @import("build/event.zig");
pub const render = @import("build/render.zig");
pub const fixhash = @import("build/fixhash.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
