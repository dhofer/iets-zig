//! The one HTTP client iets has: a streaming GET, for the fetch builtins.
//! Redirects are followed like
//! filetransfer.cc (`CURLOPT_FOLLOWLOCATION`, `CURLOPT_MAXREDIRS` 10) and
//! `file://` reads the local file, as libcurl does for the `tarball` inputs
//! `nix flake lock` writes with that scheme. Credentials follow a redirect
//! only as libcurl lets them: see `redirect`.
//!
//! The body is never held whole: the socket is read on the caller's thread,
//! through TLS (std.crypto.tls), the HTTP body framing (std.http.Reader) and
//! the decompressor, straight into the sink, so memory stays bounded.
//! The socket reads wait in `poll`, which is where `connect-timeout` and
//! `stalled-download-timeout` are kept.

const std = @import("std");
const errors = @import("../errors.zig");
const bytes_ = @import("../bytes.zig");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;
const net = @import("../sys/net.zig");
const Diag = @import("../diag.zig").Diag;
const log_mod = @import("../log.zig");
const roots = @import("roots.zig");
const bzip2 = @import("bzip2.zig");
const flate = std.compress.flate;
const zstd = @import("zstd.zig");
const xz = @import("xz.zig");
const tls = std.crypto.tls;

/// filetransfer.cc:CURLOPT_MAXREDIRS.
pub const max_redirects = 10;

/// filetransfer.hh:`download-attempts`. The setting itself is the daemon's,
/// so this is its default, fixed.
pub const tries = 5;

/// The zip-bomb guard: past `ratio_after` bytes out, a stream that gives more
/// than `max_ratio` bytes out per byte in is refused. The narHash is checked
/// only at the end, so it bounds nothing on the way.
pub const max_ratio = 1000;
pub const ratio_after: u64 = 16 << 20;

/// How many filters libarchive's `archive_read_support_filter_all` may stack
/// before iets calls the stream a bomb: a doubly compressed tarball is one
/// Nix accepts.
pub const max_filters = 8;

/// The `User-Agent` Rust iets sends: `iets/` and its version.
const user_agent = "iets/0.2.0";

/// What one download may cost. filetransfer.cc sets `connect-timeout` as
/// `CURLOPT_CONNECTTIMEOUT` and `stalled-download-timeout` as
/// `CURLOPT_LOW_SPEED_TIME` (at 1 byte/s); null is no limit for both.
/// The defaults `Limits::new` falls back to; `cli/prefetch.zig:limits`
/// reads both timeouts from nix.conf (0 is no limit) and `fetch-max-size`
/// from the settings.
pub const Limits = struct {
    connect_ns: ?u64 = 15 * std.time.ns_per_s,
    stall_ns: ?u64 = 300 * std.time.ns_per_s,
    /// The `fetch-max-size` setting: decompressed bytes.
    max_size: u64 = 16 << 30,
};

pub const Header = struct { name: []const u8, value: []const u8 };

/// What a download needs from the run.
pub const Context = struct {
    gpa: Allocator,
    io: Io,
    limits: Limits = .{},
    /// `IETS_OFFLINE`: any download is an error that names the URL.
    offline: bool = false,
    /// The run's log: a retry is announced on it, and a download is a
    /// file-transfer activity with its progress (filetransfer.cc).
    log: ?*log_mod.Log = null,
};

pub const Error = error{FetchFailed} || Allocator.Error;

/// A URL as a message may show it: the password of a `user:password@host`
/// authority is never printed, here or anywhere else.
pub fn shown(a: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return a.dupe(u8, url);
    const head = url[0..sep];
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const at = std.mem.lastIndexOfScalar(u8, rest[0..end], '@') orelse return a.dupe(u8, url);
    const colon = std.mem.indexOfScalar(u8, rest[0..at], ':') orelse return a.dupe(u8, url);
    return std.fmt.allocPrint(a, "{s}://{s}:***@{s}", .{ head, rest[0..colon], rest[at + 1 ..] });
}

fn bad(d: *Diag, url: []const u8, comptime fmt: []const u8, args: anytype) Error {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const s = shown(fba.allocator(), url) catch url;
    var mbuf: [2048]u8 = undefined;
    const why = std.fmt.bufPrint(&mbuf, fmt, args) catch fmt;
    return d.fail(error.FetchFailed, "cannot fetch '{s}': {s}", .{ s, why });
}

/// What a URL was split into; `target` is the request line's path and query.
pub const Url = struct {
    https: bool,
    host: []const u8,
    port: u16,
    target: []const u8,
    /// `user:password` before the host, percent-decoded.
    userinfo: ?[]const u8,

    pub fn parse(a: Allocator, url: []const u8, d: *Diag) Error!Url {
        const sep = std.mem.indexOf(u8, url, "://") orelse return bad(d, url, "no scheme", .{});
        const scheme = url[0..sep];
        const rest = url[sep + 3 ..];
        const https = if (std.mem.eql(u8, scheme, "https")) true else if (std.mem.eql(u8, scheme, "http")) false else return bad(d, url, "unsupported scheme '{s}'", .{scheme});
        const split = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var auth = rest[0..split];
        const path = rest[split..];
        var userinfo: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, auth, '@')) |i| {
            userinfo = try bytes_.percentDecode(a, auth[0..i], true);
            auth = auth[i + 1 ..];
        }
        var host = auth;
        var port: u16 = if (https) 443 else 80;
        if (std.mem.lastIndexOfScalar(u8, auth, ':')) |i| {
            const p = auth[i + 1 ..];
            if (p.len > 0 and allDigits(p)) {
                host = auth[0..i];
                port = std.fmt.parseInt(u16, p, 10) catch return bad(d, url, "bad port", .{});
            }
        }
        if (host.len == 0) return bad(d, url, "no host", .{});
        return .{ .https = https, .host = host, .port = port, .target = if (path.len == 0) "/" else path, .userinfo = userinfo };
    }

    /// libcurl sends the URL's `user:password` as Basic credentials on the
    /// first request, without waiting for a challenge (`CURLAUTH_BASIC` is its
    /// default `CURLOPT_HTTPAUTH`).
    pub fn basic(u: Url, a: Allocator) Allocator.Error!?Header {
        const ui = u.userinfo orelse return null;
        const enc = std.base64.standard.Encoder;
        const b64 = try a.alloc(u8, enc.calcSize(ui.len));
        _ = enc.encode(b64, ui);
        return .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Basic {s}", .{b64}) };
    }

    pub fn authority(u: Url, a: Allocator) Allocator.Error![]const u8 {
        const default: u16 = if (u.https) 443 else 80;
        if (u.port == default) return u.host;
        return std.fmt.allocPrint(a, "{s}:{d}", .{ u.host, u.port });
    }
};

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// A redirect from `from` to `to` in a transfer that began at `first`:
/// whether the credentials go along. libcurl sends a custom `Authorization`
/// only to the first scheme, host and port (http.c:Curl_allow_auth_to_host,
/// the CVE-2022-27776 fix), and filetransfer.cc never sets
/// `CURLOPT_UNRESTRICTED_AUTH`. iets's headers are all credentials, so the
/// rule covers `Private-token` too. An https-to-http redirect is refused:
/// libcurl allows it, but it drops TLS from a download nothing has verified.
pub fn redirect(first: Url, from: Url, to: Url) error{Downgrade}!bool {
    if (from.https and !to.https) return error.Downgrade;
    return first.https == to.https and std.ascii.eqlIgnoreCase(first.host, to.host) and first.port == to.port;
}

/// The local path a `file:` URL names: `file:/p`, `file:///p` and
/// `file://localhost/p` all name `/p`. libcurl reads an empty host and
/// `localhost`; any other host is not a local file, so it is not one here.
pub fn filePath(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, "file:")) return null;
    const rest = url[5..];
    if (!std.mem.startsWith(u8, rest, "//")) return rest;
    const after = rest[2..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    const host = after[0..slash];
    if (host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost")) return after[slash..];
    return null;
}

/// Whether `location` starts with a scheme, and so is absolute. What comes
/// before `://` must be a scheme (RFC 3986): a `://` in a query is not one.
fn hasScheme(location: []const u8) bool {
    const sep = std.mem.indexOf(u8, location, "://") orelse return false;
    const s = location[0..sep];
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "+-.", c) == null) return false;
    return true;
}

/// `.` and `..` segments removed, as a URL path has them removed
/// (RFC 3986:5.2.4). A `..` at the top removes nothing.
fn normalise(a: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            _ = out.pop();
            continue;
        }
        try out.append(a, seg);
    }
    const slash = (std.mem.endsWith(u8, path, "/") or std.mem.endsWith(u8, path, ".")) and out.items.len > 0;
    const joined = try std.mem.join(a, "/", out.items);
    return std.fmt.allocPrint(a, "/{s}{s}", .{ joined, if (slash) "/" else "" });
}

/// `Location` against the URL it came from: absolute, host-relative or
/// path-relative (libcurl resolves all three).
pub fn resolve(a: Allocator, base: []const u8, location: []const u8) Allocator.Error![]const u8 {
    if (hasScheme(location)) return a.dupe(u8, location);
    var scheme: []const u8 = "https";
    var rest = base;
    if (std.mem.indexOf(u8, base, "://")) |i| {
        scheme = base[0..i];
        rest = base[i + 3 ..];
    }
    const authority = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
    const joined = if (std.mem.startsWith(u8, location, "/")) location else blk: {
        var path = rest[authority.len..];
        path = path[0 .. std.mem.indexOfAny(u8, path, "?#") orelse path.len];
        const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else "";
        break :blk try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, location });
    };
    const cut = std.mem.indexOfAny(u8, joined, "?#") orelse joined.len;
    return std.fmt.allocPrint(a, "{s}://{s}{s}{s}", .{ scheme, authority, try normalise(a, joined[0..cut]), joined[cut..] });
}

/// filetransfer.cc:finish: the statuses Nix treats as transient, and the delay
/// each one starts from (`RETRY_TIME_MS_DEFAULT`, and a minute for 429). 404,
/// 410 and the authorisation failures are final, as are 501, 505 and 511.
fn transient(status: u16) ?u64 {
    return switch (status) {
        429 => 60_000,
        408 => 250,
        501, 505, 511 => null,
        500, 502...504, 506...510, 512...599 => 250,
        else => null,
    };
}

/// `GET url` with `headers`, following redirects, with the body decompressed
/// into `sink` as it arrives when `unpack` is set (`iets prefetch` hashes
/// the bytes the URL serves, as `nix store prefetch-file` does); the number of
/// bytes written. A `file://` URL is read from the file system instead.
/// Nothing buffers the whole body. `headers` are credentials: they go only
/// where `redirect` lets them.
pub fn get(ctx: Context, url: []const u8, headers: []const Header, unpack: bool, sink: *Writer, d: *Diag) Error!u64 {
    if (ctx.offline) return d.fail(error.FetchFailed, "cannot fetch '{s}': IETS_OFFLINE is set", .{url});
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (filePath(url)) |p| {
        const path = try bytes_.percentDecode(a, p[0 .. std.mem.indexOfAny(u8, p, "?#") orelse p.len], true);
        const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |e|
            return d.fail(error.FetchFailed, "cannot read '{s}': {s}", .{ path, strerror(e) });
        defer f.close(ctx.io);
        const buf = try a.alloc(u8, 64 << 10);
        var fr = f.readerStreaming(ctx.io, buf);
        var counted: Counted = .init(&fr.interface);
        return pipe(ctx, url, &counted, unpack, sink, null, d) catch |e| switch (e) {
            error.FileReadFailed => d.fail(error.FetchFailed, "cannot read the download: {f}", .{ioText(fr.err orelse error.ReadFailed)}),
            else => |x| x,
        };
    }
    return stream(ctx, a, url, headers, unpack, sink, d);
}

/// `get` with decompression.
pub fn getDecompressed(ctx: Context, url: []const u8, headers: []const Header, sink: *Writer, d: *Diag) Error!u64 {
    return get(ctx, url, headers, true, sink, d);
}

/// Follows redirects and pipes the body of the 200 into `sink`.
fn stream(ctx: Context, a: Allocator, url: []const u8, headers: []const Header, unpack: bool, sink: *Writer, d: *Diag) Error!u64 {
    const first = try Url.parse(a, url, d);
    var sent: std.ArrayList(Header) = .empty;
    try sent.appendSlice(a, headers);
    if (try first.basic(a)) |h| try sent.append(a, h);
    var current: []const u8 = url;
    var credentials = true;
    var redirects: usize = 0;
    var attempt: u32 = 0;
    while (true) {
        const t = try Transport.open(ctx, a, current, if (credentials) sent.items else &.{}, d);
        defer t.close();
        switch (t.status) {
            200 => {
                var counted: Counted = .init(t.body);
                const n = pipe(ctx, current, &counted, unpack, sink, t, d) catch |e| switch (e) {
                    error.FileReadFailed => unreachable,
                    else => |x| return x,
                };
                if (t.truncated()) return bad(d, current, "reading the response failed: the connection closed before the body ended", .{});
                return n;
            },
            301, 302, 303, 307, 308 => {
                redirects += 1;
                if (redirects > max_redirects) return bad(d, url, "more than {d} redirects", .{max_redirects});
                const to = t.location orelse return bad(d, current, "HTTP {d} with no Location", .{t.status});
                const next = try resolve(a, current, to);
                const from = try Url.parse(a, current, d);
                const dest = try Url.parse(a, next, d);
                credentials = redirect(first, from, dest) catch return bad(d, next, "refusing a redirect from https to http", .{});
                current = next;
            },
            else => |other| {
                attempt += 1;
                const base = transient(other) orelse return bad(d, current, "HTTP status {d}", .{other});
                if (attempt >= tries) return bad(d, current, "HTTP status {d}", .{other});
                const ms = base << @intCast(attempt - 1);
                if (ctx.log) |l| l.textLine(try std.fmt.allocPrint(a, "warning: unable to download '{s}': HTTP error {d}; retrying in {d} ms (attempt {d}/{d})", .{ try shown(a, current), other, ms, attempt, tries }));
                ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
            },
        }
    }
}

/// The body through the decompressor, when asked for, into `sink`.
fn pipe(ctx: Context, url: []const u8, counted: *Counted, unpack: bool, sink: *Writer, t: ?*Transport, d: *Diag) (Error || error{FileReadFailed})!u64 {
    var dec: ?*Decompressor = null;
    defer if (dec) |x| x.deinit();
    const src: *Reader = if (unpack) blk: {
        dec = Decompressor.init(ctx.gpa, &counted.interface, layersBudget(ctx.limits.max_size), d) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return readFailure(url, t, null, counted, d),
            error.FetchFailed => return error.FetchFailed,
        };
        break :blk dec.?.out;
    } else &counted.interface;
    return drain(ctx, url, src, counted, sink, t, dec, d);
}

/// Why a read of the body failed: the transport's error before the
/// reader's, the order Rust iets reports them in.
fn readFailure(url: []const u8, t: ?*Transport, dec: ?*Decompressor, counted: *Counted, d: *Diag) (Error || error{FileReadFailed}) {
    if (t) |tr| if (tr.failure()) |f| return switch (f) {
        .stalled => bad(d, url, "the download stalled (stalled-download-timeout)", .{}),
        .timed_out => bad(d, url, "the connection timed out (connect-timeout)", .{}),
        .other => |e| bad(d, url, "reading the response failed: {f}", .{ioText(e)}),
    };
    if (dec) |x| if (x.errorText()) |m| return d.fail(error.FetchFailed, "cannot read the download: {s}", .{m});
    _ = counted;
    if (t == null) return error.FileReadFailed;
    return bad(d, url, "reading the response failed: {s}", .{"the body could not be read"});
}

/// Copies the decompressed stream into `sink` within `limits.max_size` and the
/// `max_ratio` to the compressed bytes `counted` saw.
fn drain(ctx: Context, url: []const u8, src: *Reader, counted: *Counted, sink: *Writer, t: ?*Transport, dec: ?*Decompressor, d: *Diag) (Error || error{FileReadFailed})!u64 {
    const buf = try ctx.gpa.alloc(u8, 64 << 10);
    defer ctx.gpa.free(buf);
    // filetransfer.cc:TransferItem::act, its progress at most every 100 ms
    const act: ?log_mod.Activity = if (ctx.log) |l| blk: {
        var sbuf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&sbuf);
        const s = shown(fba.allocator(), url) catch url;
        var tbuf: [4200]u8 = undefined;
        const text = std.fmt.bufPrint(&tbuf, "downloading '{s}'", .{s}) catch "downloading";
        break :blk l.activity(0, log_mod.lvl_talkative, log_mod.act_file_transfer, text, &.{.{ .str = s }});
    } else null;
    defer if (act) |x| x.end();
    var told: ?Io.Timestamp = null;
    var out: u64 = 0;
    while (true) {
        if (act) |x| {
            const now = Io.Clock.awake.now(ctx.io);
            if (told == null or told.?.durationTo(now).nanoseconds >= 100 * std.time.ns_per_ms) {
                told = now;
                x.result(log_mod.res_progress, &.{ .{ .int = @intCast(counted.count) }, .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 } });
            }
        }
        const n = src.readSliceShort(buf) catch return readFailure(url, t, dec, counted, d);
        if (n == 0) break;
        out += n;
        if (out > ctx.limits.max_size) return bad(d, url, "over the fetch-max-size of {d} bytes", .{ctx.limits.max_size});
        if (out > ratio_after and out / @max(counted.count, 1) > max_ratio)
            return bad(d, url, "it decompresses over {d} times its size", .{max_ratio});
        sink.writeAll(buf[0..n]) catch return d.fail(error.FetchFailed, "cannot write the download: write failed", .{});
        if (n < buf.len) break;
    }
    return out;
}

/// A reader that adds what it reads to a counter: the compressed side, for
/// the ratio `drain` checks.
const Counted = struct {
    inner: *Reader,
    count: u64 = 0,
    interface: Reader,

    fn init(inner: *Reader) Counted {
        return .{ .inner = inner, .interface = .{ .vtable = &.{ .stream = streamFn }, .buffer = &.{}, .seek = 0, .end = 0 } };
    }

    fn streamFn(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        const c: *Counted = @alignCast(@fieldParentPtr("interface", r));
        const n = try c.inner.stream(w, limit);
        c.count += n;
        return n;
    }
};

/// The magic bytes libarchive's `archive_read_support_filter_all`
/// recognises, for the filters iets implements (tarfile.cc:TarArchive).
pub const Compression = enum {
    none,
    gzip,
    xz,
    zstd,
    bzip2,

    pub fn sniff(b: []const u8) Compression {
        if (std.mem.startsWith(u8, b, &.{ 0x1f, 0x8b })) return .gzip;
        if (std.mem.startsWith(u8, b, &.{ 0xfd, '7', 'z', 'X', 'Z', 0x00 })) return .xz;
        if (std.mem.startsWith(u8, b, &.{ 0x28, 0xb5, 0x2f, 0xfd })) return .zstd;
        if (std.mem.startsWith(u8, b, "BZh")) return .bzip2;
        return .none;
    }
};

/// What the layers of an archive within `max_size` may read: every layer
/// about that much, with room for the framing that grows incompressible
/// data. `drain` still holds the output to `max_size`.
pub fn layersBudget(max_size: u64) u64 {
    return max_size *| (2 * (max_filters + 1));
}

/// The bytes every filter layer reads, charged against one budget, so the
/// work of a layer that outputs little, such as a run of empty gzip members,
/// is bounded too.
const Charged = struct {
    inner: *Reader,
    left: *u64,
    over: bool = false,
    interface: Reader,

    fn streamFn(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        const c: *Charged = @alignCast(@fieldParentPtr("interface", r));
        const n = try c.inner.stream(w, limit);
        if (n > c.left.*) {
            c.over = true;
            return error.ReadFailed;
        }
        c.left.* -= n;
        return n;
    }
};

/// Gzip members one after another, and the stream over as soon as what
/// follows the last one is not a gzip header. libarchive's filter bids on the
/// bytes and, finding no filter, hands the rest to the tar reader, which stops
/// at its own end-of-archive marker.
const MultiGz = struct {
    input: *Reader,
    dec: flate.Decompress,
    window: []u8,
    interface: Reader,

    fn streamFn(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        const m: *MultiGz = @alignCast(@fieldParentPtr("interface", r));
        while (true) {
            return m.dec.reader.stream(w, limit) catch |e| switch (e) {
                error.EndOfStream => {
                    const next = m.input.peek(2) catch |pe| switch (pe) {
                        error.EndOfStream => return error.EndOfStream,
                        error.ReadFailed => return error.ReadFailed,
                    };
                    if (!std.mem.eql(u8, next, &.{ 0x1f, 0x8b })) return error.EndOfStream;
                    m.dec = .init(m.input, .gzip, m.window);
                    continue;
                },
                else => |x| return x,
            };
        }
    }
};

/// One layer of the stack: the charged input and the filter on it.
const Layer = struct {
    charged: Charged,
    charged_buf: [64 << 10]u8,
    filter: union(enum) {
        none,
        gzip: MultiGz,
        xz: xz.Decompress,
        zstd: zstd.Decompress,
        bzip2: bzip2.Decompress,
    },
    filter_buf: []u8 = &.{},
};

/// `src` with the compression its first bytes announce undone, as
/// `archive_read_support_filter_all` does it, without holding the stream. A
/// filter's own output is sniffed again, so a doubly compressed archive
/// unpacks. What the layers read together may not exceed the budget.
pub const Decompressor = struct {
    gpa: Allocator,
    left: u64,
    layers: [max_filters]*Layer = undefined,
    n: usize = 0,
    out: *Reader = undefined,

    pub fn init(gpa: Allocator, src: *Reader, budget: u64, d: *Diag) (Allocator.Error || error{ ReadFailed, FetchFailed })!*Decompressor {
        const self = try gpa.create(Decompressor);
        self.* = .{ .gpa = gpa, .left = budget };
        errdefer self.deinit();
        var read = src;
        for (0..max_filters) |_| {
            const l = try gpa.create(Layer);
            l.* = .{ .charged = .{ .inner = read, .left = &self.left, .interface = undefined }, .charged_buf = undefined, .filter = .none };
            l.charged.interface = .{ .vtable = &.{ .stream = Charged.streamFn }, .buffer = &l.charged_buf, .seek = 0, .end = 0 };
            self.layers[self.n] = l;
            self.n += 1;
            const cin = &l.charged.interface;
            const head = cin.peekGreedy(6) catch |e| switch (e) {
                error.EndOfStream => cin.buffered(),
                error.ReadFailed => {
                    if (self.errorText()) |m| return d.fail(error.FetchFailed, "cannot read the archive: {s}", .{m});
                    return error.ReadFailed;
                },
            };
            switch (Compression.sniff(head)) {
                .none => {
                    self.out = cin;
                    return self;
                },
                .gzip => {
                    l.filter_buf = try gpa.alloc(u8, flate.max_window_len);
                    l.filter = .{ .gzip = .{ .input = cin, .dec = .init(cin, .gzip, l.filter_buf), .window = l.filter_buf, .interface = undefined } };
                    l.filter.gzip.interface = .{ .vtable = &.{ .stream = MultiGz.streamFn }, .buffer = &.{}, .seek = 0, .end = 0 };
                    read = &l.filter.gzip.interface;
                },
                .xz => {
                    l.filter_buf = try gpa.alloc(u8, 64 << 10);
                    l.filter = .{ .xz = try .init(cin, gpa, l.filter_buf) };
                    read = &l.filter.xz.reader;
                },
                .zstd => {
                    if (zstdWindow(cin.peekGreedy(18) catch cin.buffered())) |window| if (window > zstd.max_window)
                        return d.fail(error.FetchFailed, "cannot start the zstd decoder: Frame requires too much memory for decoding", .{});
                    l.filter_buf = try gpa.alloc(u8, 64 << 10);
                    l.filter = .{ .zstd = try .init(cin, gpa, l.filter_buf) };
                    read = &l.filter.zstd.reader;
                },
                .bzip2 => {
                    l.filter_buf = try gpa.alloc(u8, 64 << 10);
                    l.filter = .{ .bzip2 = .init(cin, gpa, l.filter_buf) };
                    read = &l.filter.bzip2.reader;
                },
            }
        }
        return d.fail(error.FetchFailed, "the archive has over {d} layers of compression", .{max_filters});
    }

    pub fn deinit(self: *Decompressor) void {
        for (self.layers[0..self.n]) |l| {
            switch (l.filter) {
                .xz => |*x| x.deinit(),
                .zstd => |*z| z.deinit(),
                .bzip2 => |*b| b.deinit(),
                else => {},
            }
            if (l.filter_buf.len > 0) self.gpa.free(l.filter_buf);
            self.gpa.destroy(l);
        }
        self.gpa.destroy(self);
    }

    /// Why a read failed inside the stack, outermost layer first.
    pub fn errorText(self: *const Decompressor) ?[]const u8 {
        for (self.layers[0..self.n]) |l| {
            if (l.charged.over) return "the archive's layers of compression decompress to too much";
            switch (l.filter) {
                .none => {},
                .gzip => |*g| if (g.dec.err) |e| return @errorName(e),
                .xz => |*x| if (x.err) |e| return @errorName(e),
                .zstd => |*z| if (z.err) |e| return @errorName(e),
                .bzip2 => |*b| if (b.err) |e| return @errorName(e),
            }
        }
        return null;
    }
};

/// The window the first zstd frame asks for, from its header.
fn zstdWindow(h: []const u8) ?u64 {
    if (h.len < 6 or !std.mem.eql(u8, h[0..4], &.{ 0x28, 0xb5, 0x2f, 0xfd })) return null;
    const fhd = h[4];
    if (fhd & 0x20 == 0) {
        const wd = h[5];
        const base = @as(u64, 1) << @intCast(10 + (wd >> 3));
        return base + (base / 8) * (wd & 7);
    }
    const dict_lens = [_]usize{ 0, 1, 2, 4 };
    const fcs_lens = [_]usize{ 1, 2, 4, 8 };
    const dict_len = dict_lens[fhd & 3];
    const fcs_len = fcs_lens[fhd >> 6];
    const at = 5 + dict_len;
    if (h.len < at + fcs_len) return null;
    var v: u64 = 0;
    for (h[at..][0..fcs_len], 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
    if (fcs_len == 2) v += 256;
    return v;
}

/// `bytes` with the compression it announces undone, from `gpa`.
pub fn decompress(gpa: Allocator, bytes: []const u8, budget: u64, d: *Diag) ![]u8 {
    var r: Reader = .fixed(bytes);
    const dec = Decompressor.init(gpa, &r, budget, d) catch |e| switch (e) {
        error.ReadFailed => return d.fail(error.FetchFailed, "cannot read the archive", .{}),
        else => |x| return x,
    };
    defer dec.deinit();
    return dec.out.allocRemaining(gpa, .unlimited) catch |e| switch (e) {
        error.ReadFailed => d.fail(error.FetchFailed, "cannot decompress the stream: {s}", .{dec.errorText() orelse "read failed"}),
        else => |x| x,
    };
}

/// An error a download meets, as Rust iets prints it: `text (os error N)`
/// for an OS error.
pub const IoText = struct {
    e: anyerror,

    pub fn format(t: IoText, w: *Io.Writer) Io.Writer.Error!void {
        return switch (t.e) {
            error.UnknownHostName, error.EndOfStream => w.writeAll(strerror(t.e)),
            else => errors.os(t.e).format(w),
        };
    }
};

pub fn ioText(e: anyerror) IoText {
    return .{ .e = e };
}

/// The text without " (os error N)", as Rust iets prints it in its own
/// I/O errors.
pub fn strerror(e: anyerror) []const u8 {
    return switch (e) {
        error.UnknownHostName => "failed to lookup address information: Name or service not known",
        error.EndOfStream => "unexpected end of file",
        else => errors.ioText(e),
    };
}

/// One request and its response: a socket with the stall clock on its reads,
/// TLS on it for `https`, and the HTTP framing on that.
const Transport = struct {
    ctx: Context,
    stream: Io.net.Stream,
    /// While connecting, the time `connect-timeout` runs out (awake clock).
    deadline: ?i96,
    failed: ?Failure = null,
    eof: bool = false,
    status: u16 = 0,
    location: ?[]const u8 = null,
    sock_in: Reader,
    sock_in_buf: [tls.Client.min_buffer_len]u8,
    sock_out: Io.net.Stream.Writer,
    sock_out_buf: [tls.Client.min_buffer_len]u8,
    tls_client: ?tls.Client = null,
    tls_read_buf: [tls.Client.min_buffer_len]u8,
    tls_write_buf: [tls.Client.min_buffer_len]u8,
    http: std.http.Reader,
    body_buf: [64 << 10]u8,
    body: *Reader = undefined,

    const Failure = union(enum) { stalled, timed_out, other: anyerror };

    fn failure(t: *const Transport) ?Failure {
        return t.failed;
    }

    /// The body ended before its declared length.
    fn truncated(t: *const Transport) bool {
        return t.eof and t.http.state == .body_remaining_content_length and t.http.state.body_remaining_content_length > 0;
    }

    fn close(t: *Transport) void {
        t.stream.close(t.ctx.io);
        t.ctx.gpa.destroy(t);
    }

    fn now(t: *const Transport) i96 {
        return Io.Clock.awake.now(t.ctx.io).nanoseconds;
    }

    /// Connects, sends the request and reads the response head. `connect-timeout`
    /// covers TCP and TLS, as `CURLOPT_CONNECTTIMEOUT` does; the wait for the
    /// status line counts as a stall.
    fn open(ctx: Context, a: Allocator, url: []const u8, headers: []const Header, d: *Diag) Error!*Transport {
        const u = try Url.parse(a, url, d);
        const host = Io.net.HostName.init(u.host) catch return bad(d, url, "the host is not a valid name", .{});
        const t = try ctx.gpa.create(Transport);
        t.* = .{
            .ctx = ctx,
            .stream = undefined,
            .deadline = null,
            .sock_in = undefined,
            .sock_in_buf = undefined,
            .sock_out = undefined,
            .sock_out_buf = undefined,
            .tls_read_buf = undefined,
            .tls_write_buf = undefined,
            .http = undefined,
            .body_buf = undefined,
        };
        if (ctx.limits.connect_ns) |c| t.deadline = t.now() + c;
        t.stream = net.connect(ctx.io, host, u.port, t.deadline) catch |e| {
            ctx.gpa.destroy(t);
            if (e == error.Timeout) return bad(d, url, "the connection timed out (connect-timeout)", .{});
            return d.fail(error.FetchFailed, "cannot connect to '{s}': {s}", .{ try u.authority(a), strerror(e) });
        };
        errdefer t.close();
        t.sock_in = .{ .vtable = &.{ .stream = sockStream }, .buffer = &t.sock_in_buf, .seek = 0, .end = 0 };
        t.sock_out = t.stream.writer(ctx.io, &t.sock_out_buf);
        var plain_in: *Reader = &t.sock_in;
        var plain_out: *Writer = &t.sock_out.interface;
        if (u.https) {
            const bundle = roots.get(ctx.gpa, ctx.io, d) catch return error.FetchFailed;
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            ctx.io.random(&entropy);
            var lock: Io.RwLock = .init;
            t.tls_client = tls.Client.init(&t.sock_in, &t.sock_out.interface, .{
                .host = .{ .explicit = u.host },
                .ca = .{ .bundle = .{ .gpa = ctx.gpa, .io = ctx.io, .lock = &lock, .bundle = @constCast(bundle) } },
                .read_buffer = &t.tls_read_buf,
                .write_buffer = &t.tls_write_buf,
                .entropy = &entropy,
                .realtime_now = Io.Clock.real.now(ctx.io),
                // the body's length is checked against the header, so a
                // connection cut short is seen anyway
                .allow_truncation_attacks = true,
            }) catch |e| {
                if (t.failed) |f| if (f == .timed_out) return bad(d, url, "the connection timed out (connect-timeout)", .{});
                return d.fail(error.FetchFailed, "TLS handshake with '{s}': {t}", .{ u.host, e });
            };
            plain_in = &t.tls_client.?.reader;
            plain_out = &t.tls_client.?.writer;
        }
        // connected: from here every wait is a stall
        t.deadline = null;
        sendHead(plain_out, u, a, headers) catch return t.requestFailed(d, url, error.WriteFailed);
        if (t.tls_client != null) t.sock_out.interface.flush() catch return t.requestFailed(d, url, error.WriteFailed);
        t.http = .{ .in = plain_in, .interface = undefined, .state = .ready, .max_head_len = t.body_buf.len };
        const head_bytes = t.http.receiveHead() catch |e| return t.requestFailed(d, url, e);
        const head = std.http.Client.Response.Head.parse(head_bytes) catch |e| return t.requestFailed(d, url, e);
        t.status = @intCast(@backingInt(head.status));
        if (head.location) |l| t.location = try a.dupe(u8, l);
        if (t.status == 200) t.body = t.http.bodyReader(&t.body_buf, head.transfer_encoding, head.content_length);
        return t;
    }

    fn requestFailed(t: *Transport, d: *Diag, url: []const u8, e: anyerror) Error {
        if (t.failed) |f| switch (f) {
            .stalled => return bad(d, url, "no response (stalled-download-timeout)", .{}),
            .timed_out => return bad(d, url, "the connection timed out (connect-timeout)", .{}),
            .other => |x| return bad(d, url, "request failed: {f}", .{ioText(x)}),
        };
        return bad(d, url, "request failed: {f}", .{ioText(e)});
    }

    fn sendHead(w: *Writer, u: Url, a: Allocator, headers: []const Header) !void {
        try w.print("GET {s} HTTP/1.1\r\nhost: {s}\r\nuser-agent: {s}\r\n", .{ u.target, try u.authority(a), user_agent });
        for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        try w.writeAll("\r\n");
        try w.flush();
    }

    /// The socket's reads, each one waited for in `poll`: past the deadline
    /// while connecting, else past `stalled-download-timeout`.
    fn sockStream(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        const t: *Transport = @alignCast(@fieldParentPtr("sock_in", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const fd = t.stream.socket.handle;
        while (true) {
            const wait_ns: ?i96 = if (t.deadline) |dl| dl - t.now() else if (t.ctx.limits.stall_ns) |s| s else null;
            if (wait_ns) |ns| {
                if (ns <= 0) return t.fail(if (t.deadline != null) .timed_out else .stalled);
                var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
                const ms: i32 = @intCast(@min(@divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
                const ready = posix.poll(&pfd, ms) catch |e| return t.fail(.{ .other = e });
                if (ready == 0) {
                    if (t.deadline != null) return t.fail(.timed_out);
                    // Like curl, which tries the socket before `Curl_speedcheck`,
                    // the kernel decides: time the process was stopped or not
                    // scheduled is no stall when bytes are waiting.
                    if (!arrived(fd)) return t.fail(.stalled);
                }
            }
            const rc = linux.recvfrom(fd, dest.ptr, dest.len, 0, null, null);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        t.eof = true;
                        return error.EndOfStream;
                    }
                    w.advance(rc);
                    return rc;
                },
                .INTR, .AGAIN => continue,
                .CONNRESET => return t.fail(.{ .other = error.ConnectionResetByPeer }),
                .TIMEDOUT => return t.fail(.{ .other = error.ConnectionTimedOut }),
                else => return t.fail(.{ .other = error.ReadFailed }),
            }
        }
    }

    fn fail(t: *Transport, f: Failure) error{ReadFailed} {
        t.failed = f;
        return error.ReadFailed;
    }
};

/// Whether the kernel holds a byte for the socket (or its end).
fn arrived(fd: posix.fd_t) bool {
    var b: [1]u8 = undefined;
    const rc = linux.recvfrom(fd, &b, 1, linux.MSG.PEEK | linux.MSG.DONTWAIT, null, null);
    return linux.errno(rc) != .AGAIN;
}

const testing = std.testing;

test "urls split" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var u = try Url.parse(a, "https://api.github.com/repos/a/b/tarball/c", &d);
    try testing.expect(u.https);
    try testing.expectEqualStrings("api.github.com", u.host);
    try testing.expectEqual(@as(u16, 443), u.port);
    try testing.expectEqualStrings("/repos/a/b/tarball/c", u.target);
    try testing.expectEqualStrings("api.github.com", try u.authority(a));
    u = try Url.parse(a, "http://localhost:8080", &d);
    try testing.expect(!u.https);
    try testing.expectEqualStrings("localhost", u.host);
    try testing.expectEqual(@as(u16, 8080), u.port);
    try testing.expectEqualStrings("/", u.target);
    try testing.expectEqualStrings("localhost:8080", try u.authority(a));
    u = try Url.parse(a, "https://gitlab.com/api/v4/projects/a%2Fb/repository/archive.tar.gz?sha=d", &d);
    try testing.expectEqualStrings("/api/v4/projects/a%2Fb/repository/archive.tar.gz?sha=d", u.target);
    try testing.expectError(error.FetchFailed, Url.parse(a, "ftp://x/y", &d));
    try testing.expectError(error.FetchFailed, Url.parse(a, "nonsense", &d));
}

test "redirects resolve" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "https://api.github.com/repos/a/b/tarball/c", "https://codeload.github.com/a/b/tar.gz/c", "https://codeload.github.com/a/b/tar.gz/c" },
        .{ "https://x.example/a/b?q=1", "/c/d", "https://x.example/c/d" },
        .{ "https://x.example/a/b", "c", "https://x.example/a/c" },
        // a `://` in a query is not a scheme, and `.` and `..` are applied
        .{ "https://x.example/a/b", "/ok.tar?next=http://y.invalid/x", "https://x.example/ok.tar?next=http://y.invalid/x" },
        .{ "https://x.example/a/b", "../ok.tar", "https://x.example/ok.tar" },
        .{ "https://x.example/a/b", "./d/", "https://x.example/a/d/" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[2], try resolve(a, c[0], c[1]));
}

test "file urls name a local path" {
    try testing.expectEqualStrings("/abs/p", filePath("file:///abs/p").?);
    try testing.expectEqualStrings("/abs/p", filePath("file://localhost/abs/p").?);
    try testing.expectEqualStrings("/abs/p", filePath("file:/abs/p").?);
    try testing.expect(filePath("file://elsewhere/abs/p") == null);
    try testing.expect(filePath("https://x.example/p") == null);
}

test "redirects keep credentials only on the same origin" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const first = try Url.parse(a, "https://api.github.com/a", &d);
    try testing.expect(try redirect(first, first, try Url.parse(a, "https://API.github.com/b", &d)));
    const other = try Url.parse(a, "https://codeload.github.com/b", &d);
    try testing.expect(!try redirect(first, first, other));
    try testing.expect(try redirect(first, other, try Url.parse(a, "https://api.github.com/c", &d)));
    try testing.expect(!try redirect(first, first, try Url.parse(a, "https://api.github.com:8443/", &d)));
    try testing.expectError(error.Downgrade, redirect(first, first, try Url.parse(a, "http://api.github.com/b", &d)));
    const plain = try Url.parse(a, "http://x.example/a", &d);
    try testing.expect(!try redirect(plain, plain, try Url.parse(a, "https://x.example/a", &d)));
}

test "magic bytes" {
    try testing.expectEqual(Compression.gzip, Compression.sniff(&.{ 0x1f, 0x8b, 8, 0 }));
    try testing.expectEqual(Compression.bzip2, Compression.sniff("BZh9"));
    try testing.expectEqual(Compression.xz, Compression.sniff(&.{ 0xfd, '7', 'z', 'X', 'Z', 0 }));
    try testing.expectEqual(Compression.zstd, Compression.sniff(&.{ 0x28, 0xb5, 0x2f, 0xfd }));
    try testing.expectEqual(Compression.none, Compression.sniff("./file\x00\x00"));
}

test "a password is never shown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://x.example/a?u=1", try shown(a, "https://x.example/a?u=1"));
    try testing.expectEqualStrings("http://user:***@h:1/x", try shown(a, "http://user:s3cret@h:1/x"));
    try testing.expectEqualStrings("http://user@h/x", try shown(a, "http://user@h/x"));
}

/// `bytes` gzipped, one member.
fn gz(a: Allocator, bytes: []const u8) ![]u8 {
    var out: Writer.Allocating = try .initCapacity(a, 64);
    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out.writer, &window, .gzip, .fastest);
    try c.writer.writeAll(bytes);
    try c.writer.flush();
    try c.finish();
    return out.written();
}

test "trailing bytes and a second layer: libarchive's rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const one = try gz(a, "payload");
    for ([_][]const u8{ "", &@as([8]u8, @splat(0)), "GARBAGE" }) |extra| {
        const got = try decompress(testing.allocator, try std.mem.concat(a, u8, &.{ one, extra }), std.math.maxInt(u64), &d);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("payload", got);
    }
    const two = try decompress(testing.allocator, try std.mem.concat(a, u8, &.{ one, one }), std.math.maxInt(u64), &d);
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("payloadpayload", two);
    const nested = try decompress(testing.allocator, try gz(a, one), std.math.maxInt(u64), &d);
    defer testing.allocator.free(nested);
    try testing.expectEqualStrings("payload", nested);

    var onion: []const u8 = "deep";
    for (0..max_filters + 1) |_| onion = try gz(a, onion);
    try testing.expectError(error.FetchFailed, decompress(testing.allocator, onion, std.math.maxInt(u64), &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "layers") != null);

    // empty members that output nothing still cost what they are read as
    const empty = try gz(a, "");
    var members: std.ArrayList(u8) = .empty;
    for (0..1 << 14) |_| try members.appendSlice(a, empty);
    try testing.expectError(error.FetchFailed, decompress(testing.allocator, try gz(a, members.items), 1 << 16, &d));

    // incompressible bytes compressed twice still fit the budget of their size
    var x: u64 = 0x9e3779b97f4a7c15;
    const noise = try a.alloc(u8, 800 << 10);
    for (noise) |*b| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        b.* = @truncate(x);
    }
    const back = try decompress(testing.allocator, try gz(a, try gz(a, noise)), layersBudget(1 << 20), &d);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, noise, back);
}

test "every filter's magic decodes: gzip, bzip2, xz and zstd" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const want = "hello filters\n";
    // printf 'hello filters\n' | xz, | zstd and | bzip2
    const xz_bytes = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04, 0xe6, 0xd6, 0xb4, 0x46, 0x04, 0xc0, 0x12, 0x0e, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9d, 0xc1, 0x66, 0xa9, 0x01, 0x00, 0x0d, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x66, 0x69, 0x6c, 0x74, 0x65, 0x72, 0x73, 0x0a, 0x00, 0x00, 0x00, 0xcc, 0x2f, 0x27, 0x5d, 0xbb, 0x03, 0xc3, 0x01, 0x00, 0x01, 0x2e, 0x0e, 0x00, 0x91, 0x39, 0xcc, 0x1f, 0xb6, 0xf3, 0x7d, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x59, 0x5a };
    const zstd_bytes = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x58, 0x71, 0x00, 0x00, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x66, 0x69, 0x6c, 0x74, 0x65, 0x72, 0x73, 0x0a, 0x20, 0x1b, 0x0d, 0xc6 };
    const bz_bytes = [_]u8{ 0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0xc1, 0x4b, 0xe8, 0xb9, 0x00, 0x00, 0x02, 0xd1, 0x80, 0x00, 0x10, 0x40, 0x00, 0x03, 0x64, 0x9c, 0x00, 0x20, 0x00, 0x22, 0x01, 0xa6, 0x9a, 0x08, 0x06, 0x9a, 0x68, 0x5b, 0x9c, 0x01, 0x29, 0x44, 0xf4, 0xf8, 0xbb, 0x92, 0x29, 0xc2, 0x84, 0x86, 0x0a, 0x5f, 0x45, 0xc8 };
    const gz_bytes = try gz(arena.allocator(), want);
    for ([_][]const u8{ gz_bytes, &xz_bytes, &zstd_bytes, &bz_bytes, want }) |in| {
        const got = try decompress(testing.allocator, in, std.math.maxInt(u64), &d);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
}

/// A server on 127.0.0.1 for `n` connections, one after the other: `reply`
/// answers each; the lowercased request heads are kept in `heads`.
fn Server(comptime Reply: type) type {
    return struct {
        const Self = @This();
        io: Io,
        server: Io.net.Server,
        port: u16,
        n: usize,
        reply: Reply,
        heads: [8][1024]u8 = undefined,
        head_lens: [8]usize = @splat(0),
        served: std.atomic.Value(usize) = .init(0),
        thread: std.Thread = undefined,

        fn start(s: *Self, io: Io, n: usize, reply: Reply) !void {
            const addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
            s.* = .{ .io = io, .server = try addr.listen(io, .{}), .port = 0, .n = n, .reply = reply };
            s.port = s.server.socket.address.getPort();
            s.thread = try std.Thread.spawn(.{}, run, .{s});
        }

        fn run(s: *Self) void {
            for (0..s.n) |i| {
                const c = s.server.accept(s.io) catch return;
                defer c.close(s.io);
                var h = &s.heads[i];
                var len: usize = 0;
                var rbuf: [1]u8 = undefined;
                var cr = c.reader(s.io, &rbuf);
                while (len < h.len and !std.mem.endsWith(u8, h[0..len], "\r\n\r\n")) {
                    const b = cr.interface.takeByte() catch break;
                    h[len] = std.ascii.toLower(b);
                    len += 1;
                }
                s.head_lens[i] = len;
                var wbuf: [4096]u8 = undefined;
                var cw = c.writer(s.io, &wbuf);
                s.reply.answer(i, h[0..len], &cw.interface);
                cw.interface.flush() catch {};
                _ = s.served.fetchAdd(1, .release);
            }
        }

        fn head(s: *Self, i: usize) []const u8 {
            return s.heads[i][0..s.head_lens[i]];
        }

        fn stop(s: *Self) void {
            s.thread.join();
            s.server.deinit(s.io);
        }
    };
}

fn respond(w: *Writer, status: []const u8, extra: []const u8, body: []const u8) void {
    w.print("HTTP/1.1 {s}\r\n{s}content-length: {d}\r\n\r\n", .{ status, extra, body.len }) catch {};
    w.writeAll(body) catch {};
}

/// No wall-clock limit: the servers run in this process, so any limit fires
/// when the host does not schedule the process for that long.
fn testCtx() Context {
    return .{ .gpa = testing.allocator, .io = testing.io, .limits = .{ .connect_ns = null, .stall_ns = null, .max_size = 1 << 30 } };
}

const Ok = struct {
    body: []const u8,
    fn answer(o: @This(), _: usize, _: []const u8, w: *Writer) void {
        respond(w, "200 OK", "", o.body);
    }
};

test "credentials stay on the first origin" {
    var other: Server(Ok) = undefined;
    try other.start(testing.io, 1, .{ .body = "hello" });
    const Redirect = struct {
        other: u16,
        fn answer(r: @This(), _: usize, head_: []const u8, w: *Writer) void {
            var buf: [64]u8 = undefined;
            const to = if (std.mem.startsWith(u8, head_, "get / ")) "/again" else std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/x", .{r.other}) catch unreachable;
            var lb: [128]u8 = undefined;
            respond(w, "302 Found", std.fmt.bufPrint(&lb, "location: {s}\r\n", .{to}) catch unreachable, "");
        }
    };
    var first: Server(Redirect) = undefined;
    try first.start(testing.io, 2, .{ .other = other.port });
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var ub: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{first.port});
    _ = try getDecompressed(testCtx(), url, &.{.{ .name = "Authorization", .value = "token s3cret" }}, &out.writer, &d);
    first.stop();
    other.stop();
    try testing.expectEqualStrings("hello", out.written());
    for (0..2) |i| try testing.expect(std.mem.indexOf(u8, first.head(i), "authorization: token s3cret") != null);
    try testing.expect(std.mem.indexOf(u8, other.head(0), "authorization") == null);
}

/// A download against a server that sends `sent` and then holds the
/// connection open until the call has returned: only the stall limit can end
/// the call.
fn stalled(sent: []const u8, d: *Diag) !void {
    const Hold = struct {
        sent: []const u8,
        done: *std.atomic.Value(bool),
        fn answer(h: @This(), _: usize, _: []const u8, w: *Writer) void {
            w.writeAll(h.sent) catch {};
            w.flush() catch {};
            while (!h.done.load(.acquire)) testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    var s: Server(Hold) = undefined;
    try s.start(testing.io, 1, .{ .sent = sent, .done = &done });
    var ctx = testCtx();
    ctx.limits.stall_ns = 50 * std.time.ns_per_ms;
    var ub: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{s.port});
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const r = getDecompressed(ctx, url, &.{}, &out.writer, d);
    done.store(true, .release);
    s.stop();
    try testing.expectError(error.FetchFailed, r);
}

test "a server that never answers is a stall" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try stalled("", &d);
    try testing.expect(std.mem.indexOf(u8, d.message(), "no response (stalled-download-timeout)") != null);
}

test "a stalled download fails" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try stalled("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nhalf", &d);
    try testing.expect(std.mem.indexOf(u8, d.message(), "(stalled-download-timeout)") != null);
}

fn fileUrl(a: Allocator, tmp: *testing.TmpDir, name: []const u8, bytes: []const u8) ![]const u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fmt.allocPrint(a, "file://{s}/{s}", .{ base, name });
}

test "downloads stop at the size limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const zeros = try a.alloc(u8, 4 << 20);
    @memset(zeros, 0);
    const url = try fileUrl(a, &tmp, "size.gz", try gz(a, zeros));
    var small = testCtx();
    small.limits.max_size = 1 << 20;
    var sink: Writer.Discarding = .init(&.{});
    try testing.expectError(error.FetchFailed, getDecompressed(small, url, &.{}, &sink.writer, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "fetch-max-size") != null);
    try testing.expectEqual(@as(u64, 4 << 20), try getDecompressed(testCtx(), url, &.{}, &sink.writer, &d));
}

test "credentials in the URL are sent and never printed" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const Check = struct {
        fn answer(_: @This(), _: usize, head_: []const u8, w: *Writer) void {
            // the head comes in lower case; base64("user:s3cret") lowered
            const ok = std.mem.indexOf(u8, head_, "authorization: basic dxnlcjpzm2nyzxq=") != null;
            respond(w, if (ok) "200 OK" else "401 Unauthorized", "", if (ok) "hello" else "");
        }
    };
    var s: Server(Check) = undefined;
    try s.start(testing.io, 1, .{});
    var ub: [64]u8 = undefined;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try getDecompressed(testCtx(), try std.fmt.bufPrint(&ub, "http://user:s3cret@127.0.0.1:{d}/x", .{s.port}), &.{}, &out.writer, &d);
    s.stop();
    try testing.expectEqualStrings("hello", out.written());

    const Forbid = struct {
        fn answer(_: @This(), _: usize, _: []const u8, w: *Writer) void {
            respond(w, "403 Forbidden", "", "");
        }
    };
    var f: Server(Forbid) = undefined;
    try f.start(testing.io, 1, .{});
    const r = getDecompressed(testCtx(), try std.fmt.bufPrint(&ub, "http://user:s3cret@127.0.0.1:{d}/x", .{f.port}), &.{}, &out.writer, &d);
    f.stop();
    try testing.expectError(error.FetchFailed, r);
    try testing.expect(std.mem.indexOf(u8, d.message(), "s3cret") == null);
    try testing.expect(std.mem.indexOf(u8, d.message(), "user:***@") != null);
}

test "a transient status is retried, a 404 is not" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const Flaky = struct {
        fn answer(_: @This(), i: usize, _: []const u8, w: *Writer) void {
            if (i < 2) respond(w, "503 Service Unavailable", "", "") else respond(w, "200 OK", "", "late");
        }
    };
    var s: Server(Flaky) = undefined;
    try s.start(testing.io, 3, .{});
    var ub: [64]u8 = undefined;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try getDecompressed(testCtx(), try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{s.port}), &.{}, &out.writer, &d);
    s.stop();
    try testing.expectEqualStrings("late", out.written());

    const Gone = struct {
        fn answer(_: @This(), _: usize, _: []const u8, w: *Writer) void {
            respond(w, "404 Not Found", "", "");
        }
    };
    var g: Server(Gone) = undefined;
    try g.start(testing.io, 1, .{});
    const r = getDecompressed(testCtx(), try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{g.port}), &.{}, &out.writer, &d);
    g.stop();
    try testing.expectError(error.FetchFailed, r);
    try testing.expect(std.mem.indexOf(u8, d.message(), "HTTP status 404") != null);
}

test "a decompression bomb is refused" {
    // deflate tops out near 1032:1, so the bomb is zstd: 64 MiB of zeros
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const url = try fileUrl(arena.allocator(), &tmp, "bomb.zst", @embedFile("testdata/bomb.zst"));
    var sink: Writer.Discarding = .init(&.{});
    try testing.expectError(error.FetchFailed, getDecompressed(testCtx(), url, &.{}, &sink.writer, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "times its size") != null);
}

test "time the reader did not run is no stall: the kernel decides" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)));
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    try testing.expect(!arrived(fds[0]));
    try testing.expectEqual(@as(usize, 4), linux.write(fds[1], "data", 4));
    try testing.expect(arrived(fds[0]));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), linux.read(fds[0], &buf, buf.len));
    try testing.expect(!arrived(fds[0]));
    // the peer's end counts as something to read
    _ = linux.close(fds[1]);
    fds[1] = -1;
    try testing.expect(arrived(fds[0]));
}

test "a chunked body is read whole, and a body cut short is an error" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const Chunked = struct {
        fn answer(_: @This(), _: usize, _: []const u8, w: *Writer) void {
            w.writeAll("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n") catch {};
        }
    };
    var s: Server(Chunked) = undefined;
    try s.start(testing.io, 1, .{});
    var ub: [64]u8 = undefined;
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = try getDecompressed(testCtx(), try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{s.port}), &.{}, &out.writer, &d);
    s.stop();
    try testing.expectEqualStrings("hello world", out.written());

    const Short = struct {
        fn answer(_: @This(), _: usize, _: []const u8, w: *Writer) void {
            w.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nhalf") catch {};
        }
    };
    var c: Server(Short) = undefined;
    try c.start(testing.io, 1, .{});
    const r = get(testCtx(), try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/", .{c.port}), &.{}, false, &out.writer, &d);
    c.stop();
    try testing.expectError(error.FetchFailed, r);
    try testing.expect(std.mem.indexOf(u8, d.message(), "reading the response failed") != null);
}

test "a refused connection names the authority" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    // a port just closed: nothing listens there
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var srv = try addr.listen(testing.io, .{});
    const port = srv.socket.address.getPort();
    srv.deinit(testing.io);
    var ub: [64]u8 = undefined;
    var sink: Writer.Discarding = .init(&.{});
    try testing.expectError(error.FetchFailed, getDecompressed(testCtx(), try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}/x", .{port}), &.{}, &sink.writer, &d));
    var want: [128]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "cannot connect to '127.0.0.1:{d}': Connection refused", .{port}), d.message());
}
