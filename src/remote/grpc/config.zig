//! The `grpc://` store URL: its query parameters and the error texts of
//! nix-grpc-store's client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const remote = @import("../../remote.zig");
const worker = @import("../worker.zig");

/// The `grpc://` query parameters, with the same names and defaults as
/// nix-grpc-store's `GrpcStoreConfig` settings (src/client/store.hh).
pub const Config = struct {
    /// `host:port`, the URL authority.
    authority: []const u8,
    /// `insecure`: plaintext instead of TLS. Local testing only.
    insecure: bool = false,
    /// `connect-timeout`, seconds.
    connect_timeout: u64 = default_connect_timeout,
    /// `system`: the `x-nix-system` header on every call.
    system: []const u8,
    /// `ca-cert`: PEM file with the CA that verifies the server.
    ca_cert: ?[]const u8 = null,
    /// `client-cert` / `client-key`: the mTLS client identity.
    client_cert: ?[]const u8 = null,
    client_key: ?[]const u8 = null,
    /// `token-file`: an OIDC bearer token, re-read for every call.
    token_file: ?[]const u8 = null,
    /// `reschedule-retries`: how often a build a worker bounced goes back to
    /// the scheduler before it fails.
    reschedule_retries: u32 = default_reschedule_retries,
    /// `restart-grace`, seconds: how long to wait for a scheduler that went
    /// away, and for a worker that can take an `Unplaceable` derivation.
    restart_grace: u64 = default_restart_grace,
    /// `max-builds`: concurrent `BuildDerivation` calls.
    max_builds: usize = default_max_builds,
    /// `nar-connections`: parallel connections for NAR downloads. Accepted for
    /// URL compatibility; this client fetches over the one connection.
    nar_connections: u32 = default_nar_connections,

    /// `grpc://host:port?k=v&…`. Null when the URL is not a `grpc://` one;
    /// `error.Usage` when it is but a parameter is wrong. Strings are
    /// allocated in `arena`.
    pub fn parse(arena: Allocator, url_str: []const u8, default_system: []const u8, d: *Diag) remote.Error!?Config {
        if (!std.mem.startsWith(u8, url_str, "grpc://")) return null;
        return try parseRest(arena, url_str["grpc://".len..], default_system, d);
    }

    fn parseRest(arena: Allocator, rest: []const u8, default_system: []const u8, d: *Diag) remote.Error!Config {
        const q = std.mem.indexOfScalar(u8, rest, '?');
        const authority = std.mem.trimEnd(u8, if (q) |i| rest[0..i] else rest, "/");
        const query = if (q) |i| rest[i + 1 ..] else "";
        if (authority.len == 0) return d.fail(error.Usage, "grpc:// needs a host[:port]", .{});
        var c: Config = .{ .authority = try arena.dupe(u8, authority), .system = default_system };
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |kv| {
            if (kv.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, kv, '=');
            const k = if (eq) |i| kv[0..i] else kv;
            const v = if (eq) |i| try worker.percentDecode(arena, kv[i + 1 ..]) else "1";
            const P = struct {
                fn num(dd: *Diag, what: []const u8, val: []const u8) remote.Error!u64 {
                    return std.fmt.parseInt(u64, val, 10) catch
                        dd.fail(error.Usage, "grpc://: '{s}' wants a number, got '{s}'", .{ what, val });
                }
                // configuration.cc:310, BaseSetting<bool>::parse: exactly these spellings.
                fn flag(dd: *Diag, what: []const u8, val: []const u8) remote.Error!bool {
                    for ([_][]const u8{ "true", "1", "yes" }) |t| if (std.mem.eql(u8, val, t)) return true;
                    for ([_][]const u8{ "false", "0", "no" }) |t| if (std.mem.eql(u8, val, t)) return false;
                    return dd.fail(error.Usage, "grpc://: '{s}' wants a boolean, got '{s}'", .{ what, val });
                }
            };
            const eql = std.mem.eql;
            if (eql(u8, k, "insecure")) {
                c.insecure = try P.flag(d, k, v);
            } else if (eql(u8, k, "connect-timeout")) {
                c.connect_timeout = try P.num(d, k, v);
            } else if (eql(u8, k, "system")) {
                c.system = v;
            } else if (eql(u8, k, "ca-cert")) {
                c.ca_cert = v;
            } else if (eql(u8, k, "client-cert")) {
                c.client_cert = v;
            } else if (eql(u8, k, "client-key")) {
                c.client_key = v;
            } else if (eql(u8, k, "token-file")) {
                c.token_file = v;
            } else if (eql(u8, k, "reschedule-retries")) {
                c.reschedule_retries = @truncate(try P.num(d, k, v));
            } else if (eql(u8, k, "restart-grace")) {
                c.restart_grace = try P.num(d, k, v);
            } else if (eql(u8, k, "max-builds")) {
                c.max_builds = @intCast(@max(try P.num(d, k, v), 1));
            } else if (eql(u8, k, "nar-connections")) {
                c.nar_connections = @truncate(try P.num(d, k, v));
            } else if (eql(u8, k, "debug")) {
                // store.hh has it, but it only turns on gRPC's own tracing.
            } else return d.fail(error.Usage, "grpc://: unknown parameter '{s}'", .{k});
        }
        if ((c.client_cert != null) != (c.client_key != null))
            return d.fail(error.Usage, "grpc://: client-cert and client-key must be set together", .{});
        if (c.insecure and c.token_file != null)
            return d.fail(error.Usage, "grpc://: token-file needs TLS", .{});
        return c;
    }

    /// The URL this config came from, for log lines.
    pub fn url(c: *const Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("grpc://{s}", .{c.authority});
    }

    /// `{f}` prints the URL.
    pub fn format(c: *const Config, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return c.url(w);
    }

    /// store.cc:statusError, with the same hints.
    pub fn statusError(c: *const Config, s: Status, what: []const u8, d: *Diag) error{Protocol} {
        const hint = if (!c.insecure and (s.code == .unauthenticated or s.code == .unavailable)) connectHint(c, s.message) else "";
        return d.fail(error.Protocol, "gRPC {s} on '{s}' failed ({s}): {s}{s}", .{ what, c.authority, s.code.name(), s.message, hint });
    }
};

/// store.hh: `GrpcStoreConfig::defaultConnectTimeout`.
pub const default_connect_timeout: u64 = 30;
/// store.hh: `GrpcStoreConfig::defaultRescheduleRetries`.
pub const default_reschedule_retries: u32 = 8;
/// store.hh: `GrpcStoreConfig::defaultRestartGrace`.
pub const default_restart_grace: u64 = 120;
/// store.hh: `GrpcStoreConfig::defaultMaxBuilds`.
pub const default_max_builds: usize = 64;
/// store.hh: the `nar-connections` setting's default.
pub const default_nar_connections: u32 = 4;

/// The gRPC status codes (grpc/status.h).
pub const Code = enum(u8) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,

    /// The code's name as the error messages show it, the words Rust iets
    /// prints.
    pub fn name(c: Code) []const u8 {
        return switch (c) {
            .ok => "Ok",
            .cancelled => "Cancelled",
            .unknown => "Unknown",
            .invalid_argument => "InvalidArgument",
            .deadline_exceeded => "DeadlineExceeded",
            .not_found => "NotFound",
            .already_exists => "AlreadyExists",
            .permission_denied => "PermissionDenied",
            .resource_exhausted => "ResourceExhausted",
            .failed_precondition => "FailedPrecondition",
            .aborted => "Aborted",
            .out_of_range => "OutOfRange",
            .unimplemented => "Unimplemented",
            .internal => "Internal",
            .unavailable => "Unavailable",
            .data_loss => "DataLoss",
            .unauthenticated => "Unauthenticated",
        };
    }

    /// A `grpc-status` value; a number outside the table is `Unknown`, as
    /// the gRPC spec has a client treat it.
    pub fn fromInt(n: u64) Code {
        return if (n <= 16) @fromBackingInt(@intCast(n)) else .unknown;
    }
};

/// A failed call's gRPC status. `message` is owned by whoever produced
/// the status (the call's arena).
pub const Status = struct {
    code: Code,
    message: []const u8,
};

/// store.cc:transportError: gRPC folds every connect failure into
/// `UNAVAILABLE`, only the text tells TCP from TLS apart.
pub fn transportError(msg: []const u8) bool {
    for ([_][]const u8{
        "Connection refused",
        "Connection reset",
        "No route",
        "unreachable",
        "timed out",
        "DNS",
        "GOAWAY",
        "error trying to connect",
        "tcp connect error",
    }) |n| if (std.mem.indexOf(u8, msg, n) != null) return true;
    return false;
}

fn contains(s: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, s, n) != null;
}

/// store.cc:goneAway: a worker or the balancer restarting under us.
pub fn goneAway(s: Status) bool {
    return switch (s.code) {
        .unavailable => transportError(s.message) or contains(s.message, "upstream") or contains(s.message, "shutting down"),
        .cancelled => contains(s.message, "Cancelling all calls"),
        else => false,
    };
}

pub fn firstLine(msg: []const u8) []const u8 {
    return msg[0 .. std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len];
}

pub fn connectHint(cfg: *const Config, msg: []const u8) []const u8 {
    if (transportError(msg)) return "\nhint: could not reach the server (TCP/DNS), not a certificate problem.";
    for ([_][]const u8{ "handshake", "Handshake", "SSL", "TLS", "certificate", "Socket closed" }) |n| {
        if (!contains(msg, n)) continue;
        if (cfg.client_cert == null and cfg.token_file == null)
            return "\nhint: TLS handshake failed and no client certificate was presented. " ++
                "Set 'client-cert'/'client-key' or 'token-file'.";
        return "\nhint: TLS handshake failed: the server certificate is not trusted by our CA " ++
            "bundle, the server rejected our client certificate, or the peer is not " ++
            "speaking TLS.";
    }
    return "";
}

pub fn connectError(cfg: *const Config, msg: []const u8, d: *Diag) error{Protocol} {
    return d.fail(error.Protocol, "cannot connect to '{f}': {s}{s}", .{ cfg, msg, connectHint(cfg, msg) });
}

const testing = std.testing;

fn testCfg(arena: Allocator, url_: []const u8) !Config {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return (try Config.parse(arena, url_, "x86_64-linux", &d)).?;
}

fn bad(url_: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Usage, Config.parse(arena.allocator(), url_, "x86_64-linux", &d));
}

test "defaults match the cxx settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try testCfg(arena.allocator(), "grpc://farm.numtide.com:50051");
    try testing.expectEqualStrings("farm.numtide.com:50051", c.authority);
    try testing.expect(!c.insecure);
    try testing.expectEqual(30, c.connect_timeout);
    try testing.expectEqualStrings("x86_64-linux", c.system);
    try testing.expectEqual(8, c.reschedule_retries);
    try testing.expectEqual(64, c.max_builds);
    try testing.expectEqual(4, c.nar_connections);
    try testing.expectEqual(null, c.ca_cert);
    try testing.expectEqual(null, c.token_file);
}

test "every parameter parses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try testCfg(arena.allocator(), "grpc://farm:50051?system=aarch64-linux&token-file=/run/t&ca-cert=/ca.pem" ++
        "&reschedule-retries=2&max-builds=3&nar-connections=8&connect-timeout=7");
    try testing.expectEqualStrings("aarch64-linux", c.system);
    try testing.expectEqualStrings("/run/t", c.token_file.?);
    try testing.expectEqualStrings("/ca.pem", c.ca_cert.?);
    try testing.expectEqual(2, c.reschedule_retries);
    try testing.expectEqual(3, c.max_builds);
    try testing.expectEqual(8, c.nar_connections);
    try testing.expectEqual(7, c.connect_timeout);
}

test "insecure is a bare flag or a boolean" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try testCfg(a, "grpc://127.0.0.1:50051?insecure=1")).insecure);
    try testing.expect((try testCfg(a, "grpc://127.0.0.1:50051?insecure")).insecure);
    try testing.expect((try testCfg(a, "grpc://127.0.0.1:50051?insecure=true")).insecure);
    try testing.expect(!(try testCfg(a, "grpc://127.0.0.1:50051?insecure=false")).insecure);
}

test "mtls needs both halves" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try testCfg(arena.allocator(), "grpc://farm:50051?client-cert=/c.crt&client-key=/c.key");
    try testing.expectEqualStrings("/c.crt", c.client_cert.?);
    try bad("grpc://farm:50051?client-cert=/c.crt");
}

test "a token needs tls and unknown parameters are errors" {
    try bad("grpc://farm:50051?insecure=1&token-file=/t");
    try bad("grpc://farm:50051?nope=1");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectEqual(null, try Config.parse(testing.allocator, "ssh-ng://host", "x86_64-linux", &d));
}

test "percent escapes decode in values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try testCfg(arena.allocator(), "grpc://farm:50051?token-file=%2Frun%2Fkeys%2Ftoken");
    try testing.expectEqualStrings("/run/keys/token", c.token_file.?);
}

test "status errors carry the hints of store.cc" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try testCfg(arena.allocator(), "grpc://farm:50051");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectEqual(error.Protocol, c.statusError(.{ .code = .unavailable, .message = "tcp connect error: Connection refused" }, "StoreInfo", &d));
    try testing.expectEqualStrings("gRPC StoreInfo on 'farm:50051' failed (Unavailable): tcp connect error: Connection refused" ++
        "\nhint: could not reach the server (TCP/DNS), not a certificate problem.", d.message());
    try testing.expect(goneAway(.{ .code = .unavailable, .message = "upstream connect error" }));
    try testing.expect(!goneAway(.{ .code = .internal, .message = "upstream" }));
}
