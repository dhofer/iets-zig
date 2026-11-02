//! The `grpc://` transport: nix-grpc-store (github.com/Mic92/nix-grpc-store),
//! spoken natively: protobuf, gRPC framing and HTTP/2 are iets's own.

const std = @import("std");

pub const config = @import("grpc/config.zig");
pub const drvwire = @import("grpc/drvwire.zig");
pub const hpack = @import("grpc/hpack.zig");
pub const proto = @import("grpc/proto.zig");
pub const tls = @import("grpc/tls/tls.zig");
pub const h2 = @import("grpc/h2.zig");
pub const client = @import("grpc/client.zig");
pub const health = @import("grpc/health.zig");
pub const sched = @import("grpc/sched.zig");
pub const build = @import("grpc/build.zig");
pub const backend = @import("grpc/backend.zig");

pub const Config = config.Config;

test {
    std.testing.refAllDecls(@This());
}
