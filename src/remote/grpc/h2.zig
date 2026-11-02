//! An HTTP/2 client connection (RFC 9113), as much of it as gRPC needs:
//! one TCP or TLS connection carrying many streams,
//! with HPACK, both levels of flow control, SETTINGS, PING and GOAWAY.
//!
//! One reader thread owns the input side: it decodes frames and hands each
//! stream its headers, data and trailers. Any thread may open a stream and
//! write to it; frames go out whole under `wlock`. Lock order: `wlock` may be
//! held while taking `lock`, never the reverse.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const hpack = @import("hpack.zig");
const tls = @import("tls/tls.zig");
const remote = @import("../../remote.zig");
const net = @import("../../sys/net.zig");

pub const FrameType = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
    _,
};

const flag_end_stream: u8 = 0x1;
const flag_ack: u8 = 0x1;
const flag_end_headers: u8 = 0x4;
const flag_padded: u8 = 0x8;
const flag_priority: u8 = 0x20;

/// RFC 9113 §7.
pub const ErrorCode = enum(u32) {
    no_error = 0,
    protocol_error = 1,
    internal_error = 2,
    flow_control_error = 3,
    settings_timeout = 4,
    stream_closed = 5,
    frame_size_error = 6,
    refused_stream = 7,
    cancel = 8,
    compression_error = 9,
    connect_error = 10,
    enhance_your_calm = 11,
    inadequate_security = 12,
    http_1_1_required = 13,
    _,
};

const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// What this client advertises: an 8 MiB stream window and a 32 MiB
/// connection window, so a NAR download is not held to
/// the 64 KiB default.
pub const stream_window: u32 = 8 << 20;
pub const conn_window: u32 = 32 << 20;
/// Larger DATA frames mean fewer syscalls and headers on a NAR download.
const max_frame_size: u32 = 1 << 18;
const max_header_list: u32 = 16 << 20;
const default_frame_size: u32 = 16384;

/// The peer's SETTINGS that shape what this side sends.
const PeerSettings = struct {
    max_frame_size: u32 = default_frame_size,
    initial_window: u32 = 65535,
    max_concurrent: u32 = std.math.maxInt(u32),
};

pub const Stream = struct {
    id: u32 = 0,
    send_window: i64,
    headers: hpack.HeaderList = .{},
    trailers: hpack.HeaderList = .{},
    got_headers: bool = false,
    /// The peer sent END_STREAM.
    ended: bool = false,
    reset: ?ErrorCode = null,
    /// This side sent END_STREAM or RST_STREAM.
    local_done: bool = false,
    data: std.ArrayList(u8) = .empty,
    head: usize = 0,
    /// Bytes read but not yet given back in a WINDOW_UPDATE.
    unacked: u32 = 0,

    fn buffered(s: *const Stream) usize {
        return s.data.items.len - s.head;
    }
};

/// Why the connection stopped: its text goes into the status of every call
/// still on it.
pub const Failure = struct {
    /// GOAWAY: streams above `last_stream` were never processed.
    goaway: bool = false,
    last_stream: u32 = std.math.maxInt(u32),
    text: []const u8,
};

pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    socket: Io.net.Stream,
    sr: Io.net.Stream.Reader,
    sw: Io.net.Stream.Writer,
    tls_client: ?tls.Client = null,
    bufs: []u8,
    r: *Io.Reader,
    w: *Io.Writer,
    /// The protocol ALPN chose, for an error naming it.
    alpn: ?[]const u8 = null,

    wlock: Io.Mutex = .init,
    encoder: hpack.Encoder,
    hdr_out: std.ArrayList(u8) = .empty,

    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    streams: std.AutoHashMapUnmanaged(u32, *Stream) = .empty,
    next_id: u32 = 1,
    active: u32 = 0,
    peer: PeerSettings = .{},
    send_window: i64 = 65535,
    recv_unacked: u32 = 0,
    failure: ?Failure = null,
    /// The client's reference plus one per open call.
    refs: u32 = 1,

    decoder: hpack.Decoder,
    thread: ?std.Thread = null,
    /// The reader thread's text for why the connection broke.
    err_buf: [256]u8 = undefined,
    /// The server's first SETTINGS arrived.
    settings_received: bool = false,
    /// Why a write failed, if one did before the reader saw the end.
    write_failed: ?[]const u8 = null,
    werr_buf: [128]u8 = undefined,

    pub const Options = struct {
        /// `host:port` for `:authority`, and the host for SNI.
        host: []const u8,
        port: u16,
        tls: ?TlsOptions = null,
        connect_timeout_s: u64 = 30,
    };

    pub const TlsOptions = struct {
        bundle: *std.crypto.Certificate.Bundle,
        bundle_lock: *Io.RwLock,
        identity: ?tls.Identity = null,
    };

    /// A connect or handshake failure, in the words gRPC's own client uses,
    /// which `config.connectHint` reads.
    pub const ConnectFailure = struct { text: []const u8 };

    const sock_buf = 64 << 10;

    /// Connects, runs the TLS handshake if asked, sends the preface and
    /// SETTINGS and starts the reader. On failure `why` holds the text,
    /// allocated in `gpa`.
    pub fn connect(gpa: Allocator, io: Io, o: Options, why: *?[]u8) !*Conn {
        const c = try connectRaw(gpa, io, o, why);
        // The server's SETTINGS come in its first flight. Waiting for them
        // turns a peer that refuses us after the handshake (a TLS 1.3 server
        // rejecting the client certificate) into a connect error that names
        // its reason, not a failed first call.
        c.lock.lockUncancelable(io);
        const deadline = Io.Clock.awake.now(io).toNanoseconds() + @as(i96, o.connect_timeout_s) * std.time.ns_per_s;
        while (!c.settings_received and c.failure == null) {
            const left = deadline - Io.Clock.awake.now(io).toNanoseconds();
            if (left <= 0) break;
            c.cond.waitTimeout(io, &c.lock, .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } }) catch {};
        }
        const failed = c.failure;
        c.lock.unlock(io);
        if (failed) |f| {
            why.* = gpa.dupe(u8, f.text) catch null;
            c.release();
            return error.ConnectFailed;
        }
        return c;
    }

    fn connectRaw(gpa: Allocator, io: Io, o: Options, why: *?[]u8) !*Conn {
        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        const tls_min = std.crypto.tls.Client.min_buffer_len;
        // A whole frame must fit the buffer the frames are read from.
        const frame_buf = max_frame_size + 64;
        const bufs = try gpa.alloc(u8, if (o.tls != null) 2 * tls_min + (tls_min + frame_buf) + sock_buf else frame_buf + sock_buf);
        errdefer gpa.free(bufs);
        const socket = connectTcp(io, o.host, o.port, o.connect_timeout_s) catch |e| {
            why.* = std.fmt.allocPrint(gpa, "transport error: tcp connect error: {s}", .{remote.ioText(e)}) catch null;
            return error.ConnectFailed;
        };
        errdefer socket.close(io);
        // gRPC calls are small request/reply exchanges: no Nagle delay
        const one: c_int = 1;
        std.posix.setsockopt(socket.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
        c.* = .{
            .gpa = gpa,
            .io = io,
            .socket = socket,
            .sr = undefined,
            .sw = undefined,
            .bufs = bufs,
            .r = undefined,
            .w = undefined,
            .encoder = .init(hpack.default_table_size),
            .decoder = .init(hpack.default_table_size, max_header_list),
        };
        var rest = bufs;
        const take = struct {
            fn f(b: *[]u8, n: usize) []u8 {
                const sl = b.*[0..n];
                b.* = b.*[n..];
                return sl;
            }
        }.f;
        if (o.tls) |t| {
            c.sr = socket.reader(io, take(&rest, tls_min));
            c.sw = socket.writer(io, take(&rest, tls_min));
            const tls_r = take(&rest, tls_min + frame_buf);
            const tls_w = take(&rest, sock_buf);
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            var alert: std.crypto.tls.Alert = undefined;
            const host_only = o.host;
            c.tls_client = tls.Client.init(&c.sr.interface, &c.sw.interface, .{
                .host = .{ .explicit = host_only },
                .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = t.bundle_lock, .bundle = t.bundle } },
                .read_buffer = tls_r,
                .write_buffer = tls_w,
                .entropy = &entropy,
                .realtime_now = Io.Clock.real.now(io),
                .alpn = &.{"h2"},
                .identity = t.identity,
                .alert = &alert,
            }) catch |e| {
                why.* = if (e == error.TlsAlert)
                    std.fmt.allocPrint(gpa, "transport error: TLS handshake failed: received fatal alert: {t}", .{alert.description}) catch null
                else if (e == error.EndOfStream or e == error.ReadFailed)
                    std.fmt.allocPrint(gpa, "transport error: TLS handshake failed: Socket closed", .{}) catch null
                else
                    std.fmt.allocPrint(gpa, "transport error: TLS handshake failed: invalid peer certificate: {t}", .{e}) catch null;
                return error.ConnectFailed;
            };
            const tc = &c.tls_client.?;
            if (tc.alpnProtocol()) |p| if (!std.mem.eql(u8, p, "h2")) {
                why.* = std.fmt.allocPrint(gpa, "transport error: TLS handshake failed: the server chose ALPN '{s}', not h2", .{p}) catch null;
                return error.ConnectFailed;
            };
            c.r = &tc.reader;
            c.w = &tc.writer;
        } else {
            c.sr = socket.reader(io, take(&rest, frame_buf));
            c.sw = socket.writer(io, take(&rest, sock_buf));
            c.r = &c.sr.interface;
            c.w = &c.sw.interface;
        }
        c.start() catch |e| {
            why.* = std.fmt.allocPrint(gpa, "transport error: {s}", .{remote.ioText(c.writeErr(e))}) catch null;
            return error.ConnectFailed;
        };
        c.thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, readLoop, .{c}) catch |e| {
            why.* = std.fmt.allocPrint(gpa, "transport error: {t}", .{e}) catch null;
            return error.ConnectFailed;
        };
        return c;
    }

    /// A TCP connection to `host:port` within `timeout_s`; running out of
    /// time reads as the OS's own timeout.
    fn connectTcp(io: Io, host: []const u8, port: u16, timeout_s: u64) !Io.net.Stream {
        const deadline = Io.Clock.awake.now(io).nanoseconds + @as(i96, timeout_s) * std.time.ns_per_s;
        const r = if (Io.net.IpAddress.parse(host, port)) |addr|
            net.connectAddr(io, addr, deadline)
        else |_|
            net.connect(io, try Io.net.HostName.init(host), port, deadline);
        return r catch |e| if (e == error.Timeout) error.ConnectionTimedOut else e;
    }

    fn writeErr(c: *Conn, e: anyerror) anyerror {
        return c.sw.err orelse e;
    }

    /// The client preface (RFC 9113 §3.4) and our SETTINGS, then the
    /// connection window raised to `conn_window`.
    fn start(c: *Conn) !void {
        try c.w.writeAll(preface);
        var s: [3 * 6]u8 = undefined;
        put16(s[0..2], 0x2); // ENABLE_PUSH
        put32(s[2..6], 0);
        put16(s[6..8], 0x4); // INITIAL_WINDOW_SIZE
        put32(s[8..12], stream_window);
        put16(s[12..14], 0x5); // MAX_FRAME_SIZE
        put32(s[14..18], max_frame_size);
        try c.frameRaw(.settings, 0, 0, &s);
        var wu: [4]u8 = undefined;
        put32(&wu, conn_window - 65535);
        try c.frameRaw(.window_update, 0, 0, &wu);
        try c.flushRaw();
    }

    fn put16(b: *[2]u8, v: u16) void {
        std.mem.writeInt(u16, b, v, .big);
    }

    fn put32(b: *[4]u8, v: u32) void {
        std.mem.writeInt(u32, b, v, .big);
    }

    /// Writes one frame; the caller holds `wlock` (or is the only writer).
    fn frameRaw(c: *Conn, ty: FrameType, flags: u8, id: u32, payload: []const u8) !void {
        var h: [9]u8 = undefined;
        std.mem.writeInt(u24, h[0..3], @intCast(payload.len), .big);
        h[3] = @backingInt(ty);
        h[4] = flags;
        std.mem.writeInt(u32, h[5..9], id & 0x7fff_ffff, .big);
        try c.w.writeAll(&h);
        try c.w.writeAll(payload);
    }

    fn flushRaw(c: *Conn) !void {
        try c.w.flush();
        if (c.tls_client != null) try c.sw.interface.flush();
    }

    /// One control frame from any thread, flushed.
    fn control(c: *Conn, ty: FrameType, flags: u8, id: u32, payload: []const u8) void {
        c.wlock.lockUncancelable(c.io);
        defer c.wlock.unlock(c.io);
        c.frameRaw(ty, flags, id, payload) catch |e| return c.failWrite(e);
        c.flushRaw() catch |e| return c.failWrite(e);
    }

    /// A write that failed: the socket is shut down so the reader ends too,
    /// and the reader's reason wins, as it explains more (a TLS alert the
    /// peer sent before closing); the write's error is the fallback.
    fn failWrite(c: *Conn, e: anyerror) void {
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            if (c.write_failed == null and c.failure == null)
                c.write_failed = std.fmt.bufPrint(&c.werr_buf, "transport error: {s}", .{remote.ioText(c.writeErr(e))}) catch "transport error";
        }
        // only the sending half: what the peer sent before it closed (a TLS
        // alert) stays readable, and the peer answers the FIN by closing
        c.socket.shutdown(c.io, .send) catch {};
    }

    /// Marks the connection dead (or draining, for a GOAWAY) and wakes
    /// every waiter; the first failure wins.
    fn failLocked(c: *Conn, f: Failure) void {
        if (c.failure == null) {
            c.failure = .{ .goaway = f.goaway, .last_stream = f.last_stream, .text = c.gpa.dupe(u8, f.text) catch "transport error" };
        } else if (!f.goaway and c.failure.?.goaway) {
            // a GOAWAY then the socket closing: streams below the last
            // stream id now fail too
            c.failure.?.goaway = false;
            c.failure.?.last_stream = 0;
        }
        c.cond.broadcast(c.io);
    }

    /// Whether a new stream can still go on this connection.
    pub fn usable(c: *Conn) bool {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return c.failure == null and c.write_failed == null;
    }

    pub fn retain(c: *Conn) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        c.refs += 1;
    }

    /// Drops a reference; the last one closes the socket, joins the reader
    /// and frees everything.
    pub fn release(c: *Conn) void {
        c.lock.lockUncancelable(c.io);
        c.refs -= 1;
        const last = c.refs == 0;
        c.lock.unlock(c.io);
        if (!last) return;
        c.wlock.lockUncancelable(c.io);
        if (c.failure == null) {
            // RFC 9113 §6.8: a graceful close
            var g: [8]u8 = @splat(0);
            c.frameRaw(.goaway, 0, 0, &g) catch {};
            c.flushRaw() catch {};
        }
        c.wlock.unlock(c.io);
        c.socket.shutdown(c.io, .both) catch {};
        if (c.thread) |t| t.join();
        c.socket.close(c.io);
        var it = c.streams.valueIterator();
        while (it.next()) |s| freeStream(c.gpa, s.*);
        c.streams.deinit(c.gpa);
        if (c.failure) |f| c.gpa.free(f.text);
        c.encoder.deinit(c.gpa);
        c.decoder.deinit(c.gpa);
        c.hdr_out.deinit(c.gpa);
        c.gpa.free(c.bufs);
        c.gpa.destroy(c);
    }

    fn freeStream(gpa: Allocator, s: *Stream) void {
        s.headers.deinit(gpa);
        s.trailers.deinit(gpa);
        s.data.deinit(gpa);
        gpa.destroy(s);
    }

    pub const OpenError = error{ Unavailable, OutOfMemory };

    /// Opens a stream with `headers` (pseudo-headers first). `end` sends
    /// END_STREAM with them, a request without a body. On `Unavailable` the
    /// connection's failure text says why.
    pub fn open(c: *Conn, headers: []const hpack.Header, end: bool) OpenError!*Stream {
        const s = try c.gpa.create(Stream);
        errdefer c.gpa.destroy(s);
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            while (c.failure == null and c.active >= c.peer.max_concurrent) c.cond.waitUncancelable(c.io, &c.lock);
            if (c.failure != null) return error.Unavailable;
            c.active += 1;
        }
        c.wlock.lockUncancelable(c.io);
        defer c.wlock.unlock(c.io);
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            if (c.failure != null or c.write_failed != null or c.next_id > 0x7fff_ffff) {
                c.active -= 1;
                return error.Unavailable;
            }
            s.* = .{ .id = c.next_id, .send_window = c.peer.initial_window, .local_done = end };
            c.next_id += 2;
            c.streams.put(c.gpa, s.id, s) catch |e| {
                c.active -= 1;
                return e;
            };
        }
        c.hdr_out.clearRetainingCapacity();
        c.encoder.encode(c.gpa, headers, &c.hdr_out) catch {
            // the encoder's table may now differ from the peer's
            c.lock.lockUncancelable(c.io);
            c.failLocked(.{ .text = "transport error: out of memory" });
            c.lock.unlock(c.io);
            c.forget(s);
            return error.Unavailable;
        };
        c.writeHeaderBlock(s.id, c.hdr_out.items, end) catch |e| {
            c.failWrite(e);
            c.forget(s);
            return error.Unavailable;
        };
        return s;
    }

    /// Takes a stream that never went out back off the books; the caller
    /// frees it.
    fn forget(c: *Conn, s: *Stream) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        _ = c.streams.remove(s.id);
        c.active -= 1;
        c.cond.broadcast(c.io);
    }

    fn writeHeaderBlock(c: *Conn, id: u32, block: []const u8, end: bool) !void {
        const max = c.peerFrameSize();
        var rest = block;
        var first = true;
        while (true) {
            const n = @min(rest.len, max);
            const last = n == rest.len;
            var flags: u8 = if (last) flag_end_headers else 0;
            if (first and end) flags |= flag_end_stream;
            try c.frameRaw(if (first) .headers else .continuation, flags, id, rest[0..n]);
            rest = rest[n..];
            first = false;
            if (last) break;
        }
        try c.flushRaw();
    }

    fn peerFrameSize(c: *Conn) usize {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        return c.peer.max_frame_size;
    }

    pub const SendError = error{ Unavailable, Reset };

    /// Sends `data` on `s` as DATA frames, as the flow-control windows allow,
    /// then END_STREAM if `end`. Blocks while the peer's windows are shut.
    pub fn send(c: *Conn, s: *Stream, data: []const u8, end: bool) SendError!void {
        var rest = data;
        while (true) {
            var n: usize = 0;
            {
                c.lock.lockUncancelable(c.io);
                defer c.lock.unlock(c.io);
                while (true) {
                    if (c.failure) |f| if (!f.goaway or s.id > f.last_stream) return error.Unavailable;
                    if (s.reset != null) return error.Reset;
                    if (rest.len == 0) break;
                    const win = @min(c.send_window, s.send_window);
                    if (win > 0) {
                        n = @min(rest.len, @as(usize, @intCast(win)), c.peer.max_frame_size);
                        c.send_window -= @intCast(n);
                        s.send_window -= @intCast(n);
                        break;
                    }
                    c.cond.waitUncancelable(c.io, &c.lock);
                }
            }
            const last = n == rest.len;
            if (n == 0 and !end) return;
            c.wlock.lockUncancelable(c.io);
            const flags: u8 = if (last and end) flag_end_stream else 0;
            const r = c.frameRaw(.data, flags, s.id, rest[0..n]);
            const fr = if (r) |_| (if (last) c.flushRaw() else {}) else |e| e;
            c.wlock.unlock(c.io);
            fr catch |e| {
                c.failWrite(e);
                return error.Unavailable;
            };
            rest = rest[n..];
            if (last) {
                if (end) {
                    c.lock.lockUncancelable(c.io);
                    s.local_done = true;
                    c.lock.unlock(c.io);
                }
                return;
            }
        }
    }

    pub const RecvError = error{ Unavailable, Reset };

    /// Waits for the response headers.
    pub fn awaitHeaders(c: *Conn, s: *Stream) RecvError!void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        while (!s.got_headers) {
            if (s.reset != null) return error.Reset;
            if (s.ended) return;
            if (c.failure) |f| if (!f.goaway or s.id > f.last_stream) return error.Unavailable;
            c.cond.waitUncancelable(c.io, &c.lock);
        }
    }

    /// Reads exactly `out.len` bytes of the response body; false when the
    /// stream ended cleanly before the first byte.
    pub fn readExact(c: *Conn, s: *Stream, out: []u8) (RecvError || error{Truncated})!bool {
        var got: usize = 0;
        while (got < out.len) {
            var update: u32 = 0;
            var conn_update: u32 = 0;
            {
                c.lock.lockUncancelable(c.io);
                defer c.lock.unlock(c.io);
                while (s.buffered() == 0) {
                    if (s.reset != null) return error.Reset;
                    if (s.ended) return if (got == 0) false else error.Truncated;
                    if (c.failure) |f| if (!f.goaway or s.id > f.last_stream) return error.Unavailable;
                    c.cond.waitUncancelable(c.io, &c.lock);
                }
                const n = @min(out.len - got, s.buffered());
                @memcpy(out[got..][0..n], s.data.items[s.head..][0..n]);
                s.head += n;
                got += n;
                if (s.head == s.data.items.len) {
                    s.data.clearRetainingCapacity();
                    s.head = 0;
                }
                s.unacked += @intCast(n);
                if (s.unacked >= stream_window / 2 and !s.ended) {
                    update = s.unacked;
                    s.unacked = 0;
                }
                c.recv_unacked += @intCast(n);
                if (c.recv_unacked >= conn_window / 4) {
                    conn_update = c.recv_unacked;
                    c.recv_unacked = 0;
                }
            }
            if (update > 0 or conn_update > 0) c.windowUpdates(s.id, update, conn_update);
        }
        return true;
    }

    fn windowUpdates(c: *Conn, id: u32, stream_inc: u32, conn_inc: u32) void {
        c.wlock.lockUncancelable(c.io);
        defer c.wlock.unlock(c.io);
        var b: [4]u8 = undefined;
        if (stream_inc > 0) {
            put32(&b, stream_inc);
            c.frameRaw(.window_update, 0, id, &b) catch |e| return c.failWrite(e);
        }
        if (conn_inc > 0) {
            put32(&b, conn_inc);
            c.frameRaw(.window_update, 0, 0, &b) catch |e| return c.failWrite(e);
        }
        c.flushRaw() catch |e| return c.failWrite(e);
    }

    /// Waits for the end of the stream: trailers or a reset.
    pub fn awaitEnd(c: *Conn, s: *Stream) RecvError!void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        while (!s.ended) {
            if (s.reset != null) return error.Reset;
            if (c.failure) |f| if (!f.goaway or s.id > f.last_stream) return error.Unavailable;
            // body bytes nobody will read must not hold the window shut
            if (s.buffered() > 0) {
                s.data.clearRetainingCapacity();
                s.head = 0;
            }
            c.cond.waitUncancelable(c.io, &c.lock);
        }
    }

    /// The failure text and whether the stream was refused unprocessed
    /// (above a GOAWAY's last stream), under the lock.
    pub fn failureText(c: *Conn, arena: Allocator) Allocator.Error![]const u8 {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        // a failed write shut the socket: the reader's reason is on its way
        while (c.failure == null and c.write_failed != null) c.cond.waitUncancelable(c.io, &c.lock);
        const f = c.failure orelse return "transport error";
        return arena.dupe(u8, f.text);
    }

    /// Resets `s` from any thread, waking whoever waits on it; its owner
    /// still `close`s it.
    pub fn cancel(c: *Conn, s: *Stream) void {
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            if (s.reset != null or (s.ended and s.local_done)) return;
            s.reset = .cancel;
            c.cond.broadcast(c.io);
        }
        var b: [4]u8 = undefined;
        put32(&b, @backingInt(ErrorCode.cancel));
        c.control(.rst_stream, 0, s.id, &b);
    }

    /// Ends `s` on this side: a stream the peer has not finished is reset
    /// with CANCEL. Frees it.
    pub fn close(c: *Conn, s: *Stream) void {
        var rst = false;
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            rst = s.reset == null and (!s.ended or !s.local_done) and c.failure == null;
            _ = c.streams.remove(s.id);
            c.active -= 1;
            // the bytes the stream held count against the connection window
            c.recv_unacked += @intCast(s.buffered());
            c.cond.broadcast(c.io);
        }
        if (rst) {
            var b: [4]u8 = undefined;
            put32(&b, @backingInt(ErrorCode.cancel));
            c.control(.rst_stream, 0, s.id, &b);
        }
        freeStream(c.gpa, s);
    }

    // The reader thread.

    fn readLoop(c: *Conn) void {
        var hblock: std.ArrayList(u8) = .empty;
        defer hblock.deinit(c.gpa);
        var tmp: hpack.HeaderList = .{};
        defer tmp.deinit(c.gpa);
        const why = c.readFrames(&hblock, &tmp);
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        c.failLocked(.{ .text = why });
    }

    /// Reads frames until the connection breaks; returns why.
    fn readFrames(c: *Conn, hblock: *std.ArrayList(u8), tmp: *hpack.HeaderList) []const u8 {
        var cont_id: u32 = 0;
        var cont_end = false;
        var settings_seen = false;
        while (true) {
            const h = c.r.takeArray(9) catch |e| return c.readErrText(e);
            const len = std.mem.readInt(u24, h[0..3], .big);
            const ty: FrameType = @fromBackingInt(@intCast(h[3]));
            const flags = h[4];
            const id = std.mem.readInt(u32, h[5..9], .big) & 0x7fff_ffff;
            if (len > max_frame_size) return "h2 protocol error: frame too large";
            if (!settings_seen and ty != .settings) return "h2 protocol error: the server did not start with SETTINGS";
            if (cont_id != 0 and ty != .continuation) return "h2 protocol error: expected CONTINUATION";
            const payload = c.readPayload(len) catch |e| return c.readErrText(e);
            switch (ty) {
                .data => {
                    if (id == 0) return "h2 protocol error: DATA on stream 0";
                    const body = unpad(payload, flags) orelse return "h2 protocol error: bad padding";
                    c.onData(id, body, payload.len, flags & flag_end_stream != 0) catch return "transport error: out of memory";
                },
                .headers => {
                    if (id == 0) return "h2 protocol error: HEADERS on stream 0";
                    var block = unpad(payload, flags) orelse return "h2 protocol error: bad padding";
                    if (flags & flag_priority != 0) {
                        if (block.len < 5) return "h2 protocol error: short HEADERS";
                        block = block[5..];
                    }
                    hblock.clearRetainingCapacity();
                    hblock.appendSlice(c.gpa, block) catch return "transport error: out of memory";
                    if (flags & flag_end_headers == 0) {
                        cont_id = id;
                        cont_end = flags & flag_end_stream != 0;
                        continue;
                    }
                    if (c.onHeaders(id, hblock.items, flags & flag_end_stream != 0, tmp)) |e| return e;
                },
                .continuation => {
                    if (id != cont_id or id == 0) return "h2 protocol error: unexpected CONTINUATION";
                    if (hblock.items.len + payload.len > max_header_list) return "h2 protocol error: header block too large";
                    hblock.appendSlice(c.gpa, payload) catch return "transport error: out of memory";
                    if (flags & flag_end_headers != 0) {
                        cont_id = 0;
                        if (c.onHeaders(id, hblock.items, cont_end, tmp)) |e| return e;
                    }
                },
                .rst_stream => {
                    if (payload.len != 4) return "h2 protocol error: bad RST_STREAM";
                    const code: ErrorCode = @fromBackingInt(@intCast(std.mem.readInt(u32, payload[0..4], .big)));
                    c.lock.lockUncancelable(c.io);
                    if (c.streams.get(id)) |s| s.reset = code;
                    c.cond.broadcast(c.io);
                    c.lock.unlock(c.io);
                },
                .settings => {
                    if (flags & flag_ack != 0) continue;
                    if (payload.len % 6 != 0) return "h2 protocol error: bad SETTINGS";
                    settings_seen = true;
                    if (c.onSettings(payload)) |e| return e;
                    c.control(.settings, flag_ack, 0, "");
                },
                .ping => {
                    if (payload.len != 8) return "h2 protocol error: bad PING";
                    if (flags & flag_ack == 0) c.control(.ping, flag_ack, 0, payload);
                },
                .goaway => {
                    if (payload.len < 8) return "h2 protocol error: bad GOAWAY";
                    const last = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
                    const code = std.mem.readInt(u32, payload[4..8], .big);
                    var buf: [512]u8 = undefined;
                    const debug = payload[8..@min(payload.len, 8 + 256)];
                    const text = std.fmt.bufPrint(&buf, "transport error: connection error received: GOAWAY with code {d} ({t}){s}{s}", .{
                        code,
                        @as(ErrorCode, @fromBackingInt(@intCast(code))),
                        if (debug.len > 0) ": " else "",
                        debug,
                    }) catch "transport error: connection error received: GOAWAY";
                    c.lock.lockUncancelable(c.io);
                    c.failLocked(.{ .goaway = true, .last_stream = last, .text = text });
                    c.lock.unlock(c.io);
                },
                .window_update => {
                    if (payload.len != 4) return "h2 protocol error: bad WINDOW_UPDATE";
                    const inc = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
                    c.lock.lockUncancelable(c.io);
                    defer c.lock.unlock(c.io);
                    if (id == 0) {
                        c.send_window += inc;
                    } else if (c.streams.get(id)) |s| s.send_window += inc;
                    c.cond.broadcast(c.io);
                },
                .priority => {},
                .push_promise => return "h2 protocol error: PUSH_PROMISE with push disabled",
                _ => {},
            }
        }
    }

    fn readPayload(c: *Conn, len: usize) ![]const u8 {
        if (len <= c.r.buffer.len) return c.r.take(len);
        return error.EndOfStream;
    }

    fn readErrText(c: *Conn, e: anyerror) []const u8 {
        const t = c.readErrTextRaw(e);
        if (std.mem.startsWith(u8, t, "transport error: connection closed")) {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            if (c.write_failed) |w| return w;
        }
        return t;
    }

    fn readErrTextRaw(c: *Conn, e: anyerror) []const u8 {
        if (e == error.EndOfStream) return "transport error: connection closed: Connection reset by peer";
        if (c.tls_client) |*t| if (t.read_err) |re| return switch (re) {
            error.TlsConnectionTruncated => "transport error: connection closed: Connection reset by peer",
            // rustls words it so, and `connectHint` looks for "TLS"
            error.TlsAlert => if (t.alert) |al|
                std.fmt.bufPrint(&c.err_buf, "transport error: TLS error: received fatal alert: {t}", .{al.description}) catch "transport error: TLS error"
            else
                "transport error: TLS error",
            else => std.fmt.bufPrint(&c.err_buf, "transport error: TLS error: {t}", .{re}) catch "transport error: TLS error",
        };
        const se = c.sr.err orelse e;
        return switch (se) {
            error.ConnectionResetByPeer => "transport error: connection error: Connection reset by peer",
            error.ConnectionTimedOut => "transport error: Connection timed out",
            else => "transport error: connection closed: Connection reset by peer",
        };
    }

    fn unpad(payload: []const u8, flags: u8) ?[]const u8 {
        if (flags & flag_padded == 0) return payload;
        if (payload.len < 1) return null;
        const pad = payload[0];
        if (pad + 1 > payload.len) return null;
        return payload[1 .. payload.len - pad];
    }

    fn onData(c: *Conn, id: u32, body: []const u8, frame_len: usize, end: bool) !void {
        var conn_update: u32 = 0;
        {
            c.lock.lockUncancelable(c.io);
            defer c.lock.unlock(c.io);
            if (c.streams.get(id)) |s| {
                if (!s.ended and s.reset == null) try s.data.appendSlice(c.gpa, body);
                // padding counts against the windows but is never read
                s.unacked += @intCast(frame_len - body.len);
                if (end) s.ended = true;
                c.cond.broadcast(c.io);
                c.recv_unacked += @intCast(frame_len - body.len);
            } else {
                // a stream already closed here still used the window
                c.recv_unacked += @intCast(frame_len);
            }
            if (c.recv_unacked >= conn_window / 4) {
                conn_update = c.recv_unacked;
                c.recv_unacked = 0;
            }
        }
        if (conn_update > 0) c.windowUpdates(0, 0, conn_update);
    }

    fn onHeaders(c: *Conn, id: u32, block: []const u8, end: bool, tmp: *hpack.HeaderList) ?[]const u8 {
        tmp.clearRetainingCapacity();
        // the decoder's table must follow every block, whoever it is for
        c.decoder.decode(c.gpa, block, tmp) catch |e| switch (e) {
            error.CompressionError => return "h2 protocol error: compression error",
            error.OutOfMemory => return "transport error: out of memory",
            error.HeaderListTooLarge => {
                c.lock.lockUncancelable(c.io);
                if (c.streams.get(id)) |s| s.reset = .protocol_error;
                c.cond.broadcast(c.io);
                c.lock.unlock(c.io);
                return null;
            },
        };
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        const s = c.streams.get(id) orelse return null;
        // 1xx informational headers come before the real ones
        if (!s.got_headers) {
            if (tmp.get(":status")) |st| if (st.len == 3 and st[0] == '1') return null;
            std.mem.swap(hpack.HeaderList, &s.headers, tmp);
            s.got_headers = true;
        } else std.mem.swap(hpack.HeaderList, &s.trailers, tmp);
        if (end) s.ended = true;
        c.cond.broadcast(c.io);
        return null;
    }

    fn onSettings(c: *Conn, payload: []const u8) ?[]const u8 {
        c.lock.lockUncancelable(c.io);
        var table: ?u32 = null;
        var i: usize = 0;
        while (i < payload.len) : (i += 6) {
            const k = std.mem.readInt(u16, payload[i..][0..2], .big);
            const v = std.mem.readInt(u32, payload[i + 2 ..][0..4], .big);
            switch (k) {
                0x1 => table = v,
                0x3 => c.peer.max_concurrent = v,
                0x4 => {
                    if (v > 0x7fff_ffff) {
                        c.lock.unlock(c.io);
                        return "h2 protocol error: flow control error";
                    }
                    // RFC 9113 §6.9.2: every open stream's window moves by the change
                    const delta = @as(i64, v) - c.peer.initial_window;
                    var it = c.streams.valueIterator();
                    while (it.next()) |s| s.*.send_window += delta;
                    c.peer.initial_window = v;
                },
                0x5 => {
                    if (v < default_frame_size or v > 0xff_ffff) {
                        c.lock.unlock(c.io);
                        return "h2 protocol error: bad MAX_FRAME_SIZE";
                    }
                    c.peer.max_frame_size = v;
                },
                else => {},
            }
        }
        c.settings_received = true;
        c.cond.broadcast(c.io);
        c.lock.unlock(c.io);
        if (table) |t| {
            c.wlock.lockUncancelable(c.io);
            c.encoder.setPeerMaxSize(t);
            c.wlock.unlock(c.io);
        }
        return null;
    }
};
