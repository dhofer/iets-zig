//! The CA roots of the TLS client: `NIX_SSL_CERT_FILE`, else `SSL_CERT_FILE`
//! (Nix 2.34.8, libstore/filetransfer.cc), else the platform store, else the
//! Mozilla set compiled in. The platform store is what std's
//! `Certificate.Bundle.rescan` finds.

const std = @import("std");
const errors = @import("../errors.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;
const Diag = @import("../diag.zig").Diag;

/// Mozilla's set, the roots Rust iets compiles in (webpki-roots).
const compiled_in = @embedFile("roots.pem");

/// Adds the certificates of the PEM text `pem` to `b`, as
/// `Bundle.addCertsFromFile` adds a file's: one that does not parse or has
/// expired is left out.
pub fn addPem(b: *Bundle, gpa: Allocator, pem: []const u8, now_sec: i64) !void {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, pem, at, begin)) |s| {
        const start = s + begin.len;
        const stop = std.mem.indexOfPos(u8, pem, start, end) orelse return error.MissingEndCertificateMarker;
        at = stop + end.len;
        // base64 with the line breaks left out
        var enc: std.ArrayList(u8) = .empty;
        defer enc.deinit(gpa);
        for (pem[start..stop]) |c| if (!std.ascii.isWhitespace(c)) try enc.append(gpa, c);
        const len = try std.base64.standard.Decoder.calcSizeForSlice(enc.items);
        try b.bytes.ensureUnusedCapacity(gpa, len);
        const decoded_start: u32 = @intCast(b.bytes.items.len);
        try std.base64.standard.Decoder.decode(b.bytes.allocatedSlice()[decoded_start..][0..len], enc.items);
        b.bytes.items.len += len;
        try b.parseCert(gpa, decoded_start, now_sec);
    }
}

/// How many roots `b` holds.
pub fn count(b: *const Bundle) usize {
    return b.map.count();
}

/// The first variable that is set decides, even when empty: an empty
/// `NIX_SSL_CERT_FILE` hides `SSL_CERT_FILE`, as in Nix. A named file that
/// cannot be read is an error, never a fallback. `env` looks a variable up;
/// `platform` fills a bundle from the system's store.
pub fn choose(gpa: Allocator, io: Io, env: anytype, platform: anytype, now: Io.Timestamp, d: *Diag) !Bundle {
    var b: Bundle = .empty;
    errdefer b.deinit(gpa);
    const now_sec = now.toSeconds();
    for ([_][]const u8{ "NIX_SSL_CERT_FILE", "SSL_CERT_FILE" }) |v| {
        const path = env.get(v) orelse continue;
        if (path.len == 0) break;
        const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |e|
            return d.fail(error.BadRoots, "{s}={s}: {f}", .{ v, path, errors.os(e) });
        defer gpa.free(text);
        addPem(&b, gpa, text, now_sec) catch |e| return d.fail(error.BadRoots, "{s}={s}: {t}", .{ v, path, e });
        if (count(&b) == 0) return d.fail(error.BadRoots, "{s}={s}: no CA certificate in the file", .{ v, path });
        return b;
    }
    platform.fill(&b, gpa, io, now) catch {};
    if (count(&b) == 0) try addPem(&b, gpa, compiled_in, now_sec);
    return b;
}

/// The system's store: what std's `Bundle.rescan` finds.
pub const system = struct {
    pub fn fill(_: @This(), b: *Bundle, gpa: Allocator, io: Io, now: Io.Timestamp) !void {
        try b.rescan(gpa, io, now);
    }
}{};

/// The process environment, through libc.
pub const process_env = struct {
    pub fn get(_: @This(), name: []const u8) ?[]const u8 {
        var buf: [64]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        return std.mem.span(std.c.getenv(z) orelse return null);
    }
}{};

/// The roots, chosen once per process: they are immutable, costly to build
/// and hold no run state. A failure is kept too, with its message.
var once_lock: Io.Mutex = .init;
var once: ?union(enum) { ok: Bundle, err: []const u8 } = null;

pub fn get(gpa: Allocator, io: Io, d: *Diag) !*const Bundle {
    once_lock.lockUncancelable(io);
    defer once_lock.unlock(io);
    if (once == null) {
        var cd: Diag = .init(std.heap.page_allocator);
        if (choose(std.heap.page_allocator, io, process_env, system, Io.Clock.real.now(io), &cd)) |b| {
            once = .{ .ok = b };
        } else |_| {
            once = .{ .err = cd.msg orelse "out of memory" };
        }
    }
    _ = gpa;
    return switch (once.?) {
        .ok => |*b| b,
        .err => |m| d.fail(error.BadRoots, "{s}", .{m}),
    };
}

const testing = std.testing;

const ca =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBiTCCAS+gAwIBAgIUYqdid7LEUqasdYlUjSL8+CUCJwQwCgYIKoZIzj0EAwIw
    \\GTEXMBUGA1UEAwwOaWV0cyB0ZXN0IHJvb3QwIBcNMjYxMDA5MTYyNDU2WhgPMjEy
    \\NjA5MTUxNjI0NTZaMBkxFzAVBgNVBAMMDmlldHMgdGVzdCByb290MFkwEwYHKoZI
    \\zj0CAQYIKoZIzj0DAQcDQgAEngrQS1SJb7q35MOe2l5vde337hrZfbAvFJxNXpNn
    \\I77sXiamR0/gx0GP+PqfgF6RvwpwoDvWZZ1PbwlJeAoQr6NTMFEwHQYDVR0OBBYE
    \\FD5ctw4e54co56kh/n93SxbYz2xYMB8GA1UdIwQYMBaAFD5ctw4e54co56kh/n93
    \\SxbYz2xYMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIgPNEswBcf
    \\yBSVTKb+pHkI+2FnxMJ3rAqDQY8+ZxT68DUCIQD4BHWTRVy6D9ngnltoK5cfyk3R
    \\xaH3eJUFJGliZRO5NA==
    \\-----END CERTIFICATE-----
    \\
;

const Vars = struct {
    set: []const [2][]const u8,
    pub fn get(v: Vars, name: []const u8) ?[]const u8 {
        for (v.set) |kv| if (std.mem.eql(u8, kv[0], name)) return kv[1];
        return null;
    }
};

const NoPlatform = struct {
    pub fn fill(_: NoPlatform, _: *Bundle, _: Allocator, _: Io, _: Io.Timestamp) !void {}
};

const OnePlatform = struct {
    pub fn fill(_: OnePlatform, b: *Bundle, gpa: Allocator, _: Io, now: Io.Timestamp) !void {
        try addPem(b, gpa, ca, now.toSeconds());
    }
};

const Env = struct {
    tmp: testing.TmpDir,
    base: []u8,
    d: Diag,

    fn init() !Env {
        var e: Env = .{ .tmp = testing.tmpDir(.{}), .base = undefined, .d = .init(testing.allocator) };
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        e.base = try testing.allocator.dupe(u8, buf[0..try e.tmp.dir.realPath(testing.io, &buf)]);
        return e;
    }

    fn deinit(e: *Env) void {
        testing.allocator.free(e.base);
        e.d.deinit();
        e.tmp.cleanup();
    }

    fn file(e: *Env, name: []const u8, text: []const u8) ![]u8 {
        try e.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
        return std.fs.path.join(testing.allocator, &.{ e.base, name });
    }

    fn run(e: *Env, vars: []const [2][]const u8, platform: anytype) !usize {
        var b = try choose(testing.allocator, testing.io, Vars{ .set = vars }, platform, Io.Clock.real.now(testing.io), &e.d);
        defer b.deinit(testing.allocator);
        return count(&b);
    }
};

test "no bundle anywhere gives the compiled-in set" {
    var e = try Env.init();
    defer e.deinit();
    try testing.expect(try e.run(&.{}, NoPlatform{}) > 100);
}

test "the platform store wins over the compiled-in set" {
    var e = try Env.init();
    defer e.deinit();
    try testing.expectEqual(@as(usize, 1), try e.run(&.{}, OnePlatform{}));
}

test "NIX_SSL_CERT_FILE wins over SSL_CERT_FILE and the platform" {
    var e = try Env.init();
    defer e.deinit();
    const good = try e.file("ca.pem", ca);
    defer testing.allocator.free(good);
    const none = try e.file("none.pem", "");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 1), try e.run(&.{ .{ "NIX_SSL_CERT_FILE", good }, .{ "SSL_CERT_FILE", none } }, NoPlatform{}));
}

test "an empty NIX_SSL_CERT_FILE hides SSL_CERT_FILE" {
    var e = try Env.init();
    defer e.deinit();
    const none = try e.file("hidden.pem", "");
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 1), try e.run(&.{ .{ "NIX_SSL_CERT_FILE", "" }, .{ "SSL_CERT_FILE", none } }, OnePlatform{}));
}

test "a named file that is missing or empty is an error" {
    var e = try Env.init();
    defer e.deinit();
    try testing.expectError(error.BadRoots, e.run(&.{.{ "SSL_CERT_FILE", "/nonexistent/ca.pem" }}, NoPlatform{}));
    try testing.expect(std.mem.startsWith(u8, e.d.message(), "SSL_CERT_FILE=/nonexistent/ca.pem: "));
    const empty = try e.file("empty.pem", "");
    defer testing.allocator.free(empty);
    try testing.expectError(error.BadRoots, e.run(&.{.{ "NIX_SSL_CERT_FILE", empty }}, NoPlatform{}));
    try testing.expect(std.mem.endsWith(u8, e.d.message(), "no CA certificate in the file"));
}
