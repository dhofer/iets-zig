//! A connected `grpc://` store: one HTTP/2 connection, reopened when it
//! breaks, and the headers every call carries.
//!
//! A call that fails returns `error.Status` and leaves the gRPC status in
//! the `Call` or the caller's `*Status`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const remote = @import("../../remote.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const proto = @import("proto.zig");
const tls = @import("tls/tls.zig");
const roots = @import("../../fetch/roots.zig");
const config = @import("config.zig");
const Config = config.Config;
const Status = config.Status;
const Code = config.Code;

/// Far above gRPC's usual 4 MiB cap on a decoded message: NAR frames are
/// larger.
pub const max_message: usize = 256 << 20;

/// What `StoreInfo` reported.
pub const StoreInfo = struct {
    trusted: ?bool = null,
};

pub const Header = hpack.Header;

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    /// Owns the config's strings.
    arena: std.heap.ArenaAllocator,
    cfg: Config,
    log: remote.Log,
    host: []const u8,
    port: u16,
    authority: []const u8,
    lock: Io.Mutex = .init,
    conn: ?*h2.Conn = null,
    bundle: ?std.crypto.Certificate.Bundle = null,
    bundle_lock: Io.RwLock = .init,
    identity: ?tls.pem.OwnedIdentity = null,
    info: StoreInfo = .{},

    /// Connects and runs `StoreInfo`, which is what `GrpcStore::connect` does.
    pub fn open(gpa: Allocator, io: Io, cfg: Config, log: remote.Log, d: *Diag) remote.Error!*Client {
        const c = try gpa.create(Client);
        c.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .cfg = undefined, .log = log, .host = "", .port = 0, .authority = "" };
        errdefer c.close();
        c.cfg = try dupeConfig(c.arena.allocator(), cfg);
        try c.endpoint(d);
        {
            var why: ?[]u8 = null;
            defer if (why) |w| gpa.free(w);
            c.conn = c.connect(&why) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return config.connectError(&c.cfg, why orelse "transport error", d),
            };
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const reply = try c.call(proto.StoreInfoReply, arena.allocator(), "StoreInfo", proto.StoreInfoRequest{}, d);
        c.info = .{ .trusted = reply.trusted };
        return c;
    }

    pub fn close(c: *Client) void {
        if (c.conn) |conn| conn.release();
        if (c.bundle) |*b| b.deinit(c.gpa);
        if (c.identity) |*i| i.deinit(c.gpa);
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    fn dupeConfig(a: Allocator, cfg: Config) Allocator.Error!Config {
        var out = cfg;
        out.authority = try a.dupe(u8, cfg.authority);
        out.system = try a.dupe(u8, cfg.system);
        inline for (.{ "ca_cert", "client_cert", "client_key", "token_file" }) |f|
            if (@field(cfg, f)) |v| {
                @field(out, f) = try a.dupe(u8, v);
            };
        return out;
    }

    /// The host and port of the authority, and for TLS the roots, the
    /// `ca-cert` and the client identity (store.cc:sslOptions). The
    /// balancer's own certificate is public, so the shared roots
    /// (`fetch/roots.zig`: the system's, Mozilla's when it has none) verify
    /// it; `ca-cert` adds another CA.
    fn endpoint(c: *Client, d: *Diag) remote.Error!void {
        const a = c.arena.allocator();
        const auth = c.cfg.authority;
        var host = auth;
        var port: u16 = if (c.cfg.insecure) 80 else 443;
        if (std.mem.startsWith(u8, auth, "[")) {
            const close_i = std.mem.indexOfScalar(u8, auth, ']') orelse return d.fail(error.Usage, "grpc://{s}: invalid authority", .{auth});
            host = auth[1..close_i];
            const tail = auth[close_i + 1 ..];
            if (std.mem.startsWith(u8, tail, ":")) port = std.fmt.parseInt(u16, tail[1..], 10) catch
                return d.fail(error.Usage, "grpc://{s}: invalid port number", .{auth});
        } else if (std.mem.lastIndexOfScalar(u8, auth, ':')) |i| {
            host = auth[0..i];
            port = std.fmt.parseInt(u16, auth[i + 1 ..], 10) catch
                return d.fail(error.Usage, "grpc://{s}: invalid port number", .{auth});
        }
        c.host = try a.dupe(u8, host);
        c.port = port;
        c.authority = auth;
        if (c.cfg.insecure) return;
        const now = Io.Clock.real.now(c.io);
        c.bundle = tls.pem.loadCaBundle(c.gpa, c.io, now, .{ .system_roots = false, .extra_ca_path = c.cfg.ca_cert }) catch |e| {
            if (c.cfg.ca_cert) |p| return remote.failIo(d, e, "cannot read '{s}'", .{p});
            return d.fail(error.Protocol, "grpc://{s}: TLS: cannot load the CA roots: {t}", .{ auth, e });
        };
        const shared = roots.get(c.gpa, c.io, d) catch {
            const why = try a.dupe(u8, d.message());
            return d.fail(error.Protocol, "grpc://{s}: TLS: {s}", .{ auth, why });
        };
        addRoots(&c.bundle.?, c.gpa, shared, now.toSeconds()) catch
            return d.fail(error.Protocol, "grpc://{s}: TLS: cannot load the CA roots", .{auth});
        if (c.cfg.client_cert) |cert| {
            const key = c.cfg.client_key.?;
            c.identity = tls.pem.loadIdentity(c.gpa, c.io, cert, key) catch |e| switch (e) {
                error.FileNotFound, error.AccessDenied, error.IsDir => return remote.failIo(d, e, "cannot read '{s}' or '{s}'", .{ cert, key }),
                else => return d.fail(error.Protocol, "grpc://{s}: TLS: {t}", .{ auth, e }),
            };
        }
    }

    /// Every root of `from` into `into`, each certificate parsed again at
    /// its place in the copied bytes.
    fn addRoots(into: *std.crypto.Certificate.Bundle, gpa: Allocator, from: *const std.crypto.Certificate.Bundle, now_sec: i64) !void {
        const base: u32 = @intCast(into.bytes.items.len);
        try into.bytes.appendSlice(gpa, from.bytes.items);
        var it = from.map.valueIterator();
        while (it.next()) |at| try into.parseCert(gpa, base + at.*, now_sec);
    }

    fn connect(c: *Client, why: *?[]u8) !*h2.Conn {
        return h2.Conn.connect(c.gpa, c.io, .{
            .host = c.host,
            .port = c.port,
            .connect_timeout_s = c.cfg.connect_timeout,
            .tls = if (c.cfg.insecure) null else .{
                .bundle = &c.bundle.?,
                .bundle_lock = &c.bundle_lock,
                .identity = if (c.identity) |*i| i.identity() else null,
            },
        }, why);
    }

    /// A live connection, reconnecting when the last one broke or got a
    /// GOAWAY, with a reference the caller drops with `release`.
    fn liveConn(c: *Client, arena: Allocator, status: *Status) error{ Status, OutOfMemory }!*h2.Conn {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.conn) |conn| {
            if (conn.usable()) {
                conn.retain();
                return conn;
            }
            conn.release();
            c.conn = null;
        }
        var why: ?[]u8 = null;
        defer if (why) |w| c.gpa.free(w);
        const conn = c.connect(&why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                status.* = .{ .code = .unavailable, .message = try arena.dupe(u8, why orelse "transport error") };
                return error.Status;
            },
        };
        c.conn = conn;
        conn.retain();
        return conn;
    }

    pub fn statusError(c: *const Client, s: Status, what: []const u8, d: *Diag) error{Protocol} {
        return c.cfg.statusError(s, what, d);
    }

    /// The headers `StaticHeaders` stamps on every call plus the per-call
    /// bearer token, which the C++ `TokenFileCredentials` re-reads each time.
    pub fn headers(c: *const Client, arena: Allocator, d: *Diag) remote.Error!std.ArrayList(Header) {
        var h: std.ArrayList(Header) = .empty;
        if (c.cfg.system.len > 0) try h.append(arena, .{ .name = "x-nix-system", .value = c.cfg.system });
        if (c.cfg.token_file) |path| {
            const raw = Io.Dir.cwd().readFileAlloc(c.io, path, arena, .limited(1 << 20)) catch |e|
                return remote.failIo(d, e, "cannot read '{s}'", .{path});
            const token = std.mem.trim(u8, raw, " \t\n\r\x0b\x0c");
            if (token.len == 0 or std.mem.indexOfAny(u8, token, "\r\n") != null)
                return d.fail(error.Usage, "token file '{s}' is empty or multi-line", .{path});
            try h.append(arena, .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}), .indexing = .never });
        }
        return h;
    }

    /// One unary call with the store's fixed headers and the `UNAVAILABLE`
    /// retry loop of `GrpcStore::retrying`: the first call waits
    /// `connect-timeout` for the service, later ones get the same.
    pub fn call(c: *Client, comptime Resp: type, arena: Allocator, comptime method: []const u8, req: anytype, d: *Diag) remote.Error!Resp {
        const deadline = nowNs(c.io) + @as(i96, c.cfg.connect_timeout) * std.time.ns_per_s;
        var pause: i96 = 500 * std.time.ns_per_ms;
        while (true) {
            const h = try c.headers(arena, d);
            var status: Status = undefined;
            if (c.unary(Resp, arena, "/nix.remote.NixRemote/" ++ method, req, h.items, &status)) |resp| return resp else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Status => {
                    if (!config.goneAway(status) or nowNs(c.io) + pause > deadline) return c.statusError(status, method, d);
                    c.log.errln("{s}: {s}, retrying", .{ c.cfg.authority, config.firstLine(status.message) });
                    sleepNs(c.io, pause);
                    pause = @min(pause * 2, 4 * std.time.ns_per_s);
                },
            }
        }
    }

    /// One unary call, no retries: the reply, or `error.Status` with `status` set.
    pub fn unary(c: *Client, comptime Resp: type, arena: Allocator, path: []const u8, req: anytype, extra: []const Header, status: *Status) error{ Status, OutOfMemory }!Resp {
        var k = try c.start(arena, path, extra, status);
        defer k.deinit();
        k.send(req) catch |e| return k.failedSend(e, arena);
        k.closeSend() catch |e| return k.failedSend(e, arena);
        const resp = (try k.recv(Resp, arena)) orelse {
            const s = try k.finish(arena);
            status.* = if (s.code == .ok) .{ .code = .internal, .message = "gRPC unary call ended without a message" } else s;
            return error.Status;
        };
        const s = try k.finish(arena);
        if (s.code != .ok) {
            status.* = s;
            return error.Status;
        }
        return resp;
    }

    /// Starts a call to `path` (`/package.Service/Method`) with the request
    /// headers and `extra` metadata.
    pub fn start(c: *Client, arena: Allocator, path: []const u8, extra: []const Header, status: *Status) error{ Status, OutOfMemory }!Call {
        const conn = try c.liveConn(arena, status);
        errdefer conn.release();
        var hs: std.ArrayList(Header) = try .initCapacity(arena, 8 + extra.len);
        hs.appendSliceAssumeCapacity(&.{
            .{ .name = ":method", .value = "POST" },
            .{ .name = ":scheme", .value = if (c.cfg.insecure) "http" else "https" },
            .{ .name = ":path", .value = path },
            .{ .name = ":authority", .value = c.authority },
            .{ .name = "content-type", .value = "application/grpc" },
            .{ .name = "te", .value = "trailers" },
            .{ .name = "user-agent", .value = "iets-grpc" },
        });
        hs.appendSliceAssumeCapacity(extra);
        const s = conn.open(hs.items, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unavailable => {
                status.* = .{ .code = .unavailable, .message = try conn.failureText(arena) };
                return error.Status;
            },
        };
        return .{ .conn = conn, .s = s, .status = status };
    }
};

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).toNanoseconds();
}

pub fn sleepNs(io: Io, ns: i96) void {
    io.sleep(.fromNanoseconds(@intCast(@max(ns, 0))), .awake) catch {};
}

/// A gRPC message's prefix: no compression, then its length.
pub const prefix_len = 5;

pub fn putPrefix(out: *[prefix_len]u8, n: usize) void {
    out[0] = 0;
    std.mem.writeInt(u32, out[1..5], @intCast(n), .big);
}

/// One gRPC call on one HTTP/2 stream: length-prefixed messages each way
/// and the status at the end.
pub const Call = struct {
    conn: *h2.Conn,
    s: *h2.Stream,
    /// Where a failure's status goes.
    status: *Status,
    buf: std.ArrayList(u8) = .empty,
    headers_checked: bool = false,
    done: ?Status = null,

    pub fn deinit(k: *Call) void {
        k.buf.deinit(k.conn.gpa);
        k.conn.close(k.s);
        k.conn.release();
    }

    /// The status of a failed stream or connection, in the words Rust iets
    /// prints.
    fn streamFailed(k: *Call, e: anyerror, arena: Allocator) error{ Status, OutOfMemory } {
        k.status.* = switch (e) {
            error.Reset => blk: {
                const code = k.s.reset orelse .internal_error;
                break :blk .{
                    .code = switch (code) {
                        .refused_stream => .unavailable,
                        .cancel => .cancelled,
                        .enhance_your_calm => .resource_exhausted,
                        .inadequate_security => .permission_denied,
                        else => .internal,
                    },
                    .message = try std.fmt.allocPrint(arena, "h2 protocol error: stream error received: {t}", .{code}),
                };
            },
            error.Truncated => .{ .code = .internal, .message = "h2 protocol error: the stream ended inside a message" },
            else => .{ .code = .unavailable, .message = try k.conn.failureText(arena) },
        };
        k.done = k.status.*;
        return error.Status;
    }

    /// Sends one message.
    pub fn send(k: *Call, msg: anytype) error{ Status, OutOfMemory }!void {
        const n = proto.encodedLen(msg);
        const gpa = k.conn.gpa;
        k.buf.clearRetainingCapacity();
        try k.buf.resize(gpa, prefix_len + n);
        putPrefix(k.buf.items[0..prefix_len], n);
        _ = proto.encodeInto(k.buf.items[prefix_len..], msg);
        try k.sendFramed(k.buf.items);
    }

    /// Sends one message already encoded behind its `putPrefix`.
    pub fn sendFramed(k: *Call, framed: []const u8) error{ Status, OutOfMemory }!void {
        k.conn.send(k.s, framed, false) catch return k.sendFailed();
    }

    /// A send that failed: the stream's end says why, better than the send.
    pub fn failedSend(k: *Call, e: error{ Status, OutOfMemory }, arena: Allocator) error{ Status, OutOfMemory } {
        if (e == error.OutOfMemory) return e;
        const s = try k.finish(arena);
        if (s.code != .ok) k.status.* = s;
        return error.Status;
    }

    /// The reason a peer stopped reading is in its status, which `finish` reads.
    fn sendFailed(k: *Call) error{ Status, OutOfMemory } {
        k.status.* = .{ .code = .unavailable, .message = "gRPC stream closed by peer" };
        return error.Status;
    }

    /// Half-closes the request side.
    pub fn closeSend(k: *Call) error{ Status, OutOfMemory }!void {
        k.conn.send(k.s, "", true) catch return k.sendFailed();
    }

    fn checkHeaders(k: *Call, arena: Allocator) error{ Status, OutOfMemory }!void {
        if (k.headers_checked) return;
        k.conn.awaitHeaders(k.s) catch |e| return k.streamFailed(e, arena);
        k.headers_checked = true;
        if (!k.s.got_headers) return;
        const h = &k.s.headers;
        const st = h.get(":status") orelse "";
        if (!std.mem.eql(u8, st, "200")) {
            // the gRPC spec's mapping of an HTTP status (http-grpc-status-mapping.md)
            const code: Code = if (std.mem.eql(u8, st, "400")) .internal else if (std.mem.eql(u8, st, "401")) .unauthenticated else if (std.mem.eql(u8, st, "403")) .permission_denied else if (std.mem.eql(u8, st, "404")) .unimplemented else if (std.mem.eql(u8, st, "429") or std.mem.eql(u8, st, "502") or std.mem.eql(u8, st, "503") or std.mem.eql(u8, st, "504")) .unavailable else .unknown;
            // a proxy may still say what went wrong in gRPC terms
            if (h.get("grpc-status") == null) {
                k.status.* = .{ .code = code, .message = try std.fmt.allocPrint(arena, "HTTP status code {s}", .{st}) };
                k.done = k.status.*;
                return error.Status;
            }
        }
    }

    /// The next message, decoded into `arena` (strings point into an arena
    /// copy of its bytes); null at the end of the stream, after which
    /// `finish` says how it ended.
    pub fn recv(k: *Call, comptime T: type, arena: Allocator) error{ Status, OutOfMemory }!?T {
        try k.checkHeaders(arena);
        var prefix: [5]u8 = undefined;
        const more = k.conn.readExact(k.s, &prefix) catch |e| return k.streamFailed(e, arena);
        if (!more) return null;
        if (prefix[0] != 0) {
            k.status.* = .{ .code = .internal, .message = "protocol error: received message with compressed-flag but no grpc-encoding was specified" };
            return error.Status;
        }
        const len = std.mem.readInt(u32, prefix[1..5], .big);
        if (len > max_message) {
            k.status.* = .{ .code = .out_of_range, .message = try std.fmt.allocPrint(arena, "Error, decoded message length too large: found {d} bytes, the limit is: {d} bytes", .{ len, max_message }) };
            return error.Status;
        }
        const bytes = try arena.alloc(u8, len);
        _ = k.conn.readExact(k.s, bytes) catch |e| return k.streamFailed(if (e == error.Truncated) e else e, arena);
        return proto.decode(T, arena, bytes) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadProtobuf => {
                k.status.* = .{ .code = .internal, .message = "failed to decode Protobuf message" };
                return error.Status;
            },
        };
    }

    /// Waits for the end of the call and returns its status: `grpc-status`
    /// and `grpc-message` from the trailers, or from the headers of a
    /// trailers-only reply.
    pub fn finish(k: *Call, arena: Allocator) error{OutOfMemory}!Status {
        if (k.done) |s| return s;
        k.checkHeaders(arena) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Status => return k.status.*,
        };
        k.conn.awaitEnd(k.s) catch |e| {
            if (k.streamFailed(e, arena) == error.OutOfMemory) return error.OutOfMemory;
            return k.status.*;
        };
        const t = if (k.s.trailers.count() > 0) &k.s.trailers else &k.s.headers;
        const s: Status = if (t.get("grpc-status")) |gs| .{
            .code = Code.fromInt(std.fmt.parseInt(u64, gs, 10) catch 2),
            .message = try percentDecode(arena, t.get("grpc-message") orelse ""),
        } else .{ .code = .unknown, .message = "protocol error: missing grpc-status" };
        k.done = s;
        if (s.code != .ok) k.status.* = s;
        return s;
    }
};

/// `grpc-message` is percent-encoded UTF-8 (PROTOCOL-HTTP2.md), where `+`
/// is itself.
fn percentDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return @import("../../bytes.zig").percentDecode(arena, s, false);
}

test "grpc-message is percent-decoded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b%", try percentDecode(arena.allocator(), "a%20b%"));
    try std.testing.expectEqualStrings("Ünï", try percentDecode(arena.allocator(), "%C3%9Cn%C3%AF"));
}
