//! Hashes and their encodings: Nix32, base16, base64, SRI. Mirrors libutil's hash.cc.

const std = @import("std");
const Writer = std.Io.Writer;
const Diag = @import("../diag.zig").Diag;
const crypto = std.crypto.hash;

pub const Algo = enum {
    md5,
    sha1,
    sha256,
    sha512,
    blake3,

    /// Mirrors hash.hh:regularHashSize.
    pub fn size(a: Algo) usize {
        return switch (a) {
            .md5 => 16,
            .sha1 => 20,
            .sha256, .blake3 => 32,
            .sha512 => 64,
        };
    }

    /// Mirrors hash.cc:printHashAlgo.
    pub fn name(a: Algo) []const u8 {
        return @tagName(a);
    }

    /// Mirrors hash.cc:parseHashAlgoOpt.
    pub fn parse(s: []const u8) ?Algo {
        return std.meta.stringToEnum(Algo, s);
    }
};

pub const Format = enum { base16, nix32, base64, sri };

pub const Error = error{BadHash};

const max_size = 64;

/// A digest. `len` may be smaller than `algo.size()` after `compress`.
pub const Hash = struct {
    algo: Algo,
    len: u8,
    buf: [max_size]u8,

    pub fn raw(algo: Algo, b: []const u8) Hash {
        var h: Hash = .{ .algo = algo, .len = @intCast(b.len), .buf = @splat(0) };
        @memcpy(h.buf[0..b.len], b);
        return h;
    }

    pub fn bytes(h: *const Hash) []const u8 {
        return h.buf[0..h.len];
    }

    pub fn eql(a: Hash, b: Hash) bool {
        return a.algo == b.algo and std.mem.eql(u8, a.bytes(), b.bytes());
    }

    /// Mirrors hash.cc:Hash::to_string.
    pub fn write(h: *const Hash, w: *Writer, format: Format, include_algo: bool) Writer.Error!void {
        if (format == .sri or include_algo) {
            try w.writeAll(h.algo.name());
            try w.writeByte(if (format == .sri) '-' else ':');
        }
        switch (format) {
            .base16 => try writeBase16(w, h.bytes()),
            .nix32 => try writeNix32(w, h.bytes()),
            .base64, .sri => try writeBase64(w, h.bytes()),
        }
    }

    /// `write` into a caller-owned buffer, which must be large enough
    /// (`max_string_len` always is).
    pub fn print(h: *const Hash, buf: []u8, format: Format, include_algo: bool) []u8 {
        var w: Writer = .fixed(buf);
        h.write(&w, format, include_algo) catch unreachable;
        return w.buffered();
    }

    pub const max_string_len = 7 + 2 * max_size + 4;

    pub fn alloc(h: *const Hash, gpa: std.mem.Allocator, format: Format, include_algo: bool) ![]u8 {
        var buf: [max_string_len]u8 = undefined;
        return gpa.dupe(u8, h.print(&buf, format, include_algo));
    }

    /// Mirrors hash.cc:Hash::parseAny: `<algo>:<hash>`, `<algo>-<base64>` (SRI), or a
    /// bare hash whose encoding is picked by its length.
    pub fn parseAny(s: []const u8, want: ?Algo, d: *Diag) Error!Hash {
        var prefix: ?[]const u8 = null;
        var rest = s;
        var is_sri = false;
        if (std.mem.indexOfScalar(u8, s, ':')) |i| {
            prefix = s[0..i];
            rest = s[i + 1 ..];
        } else if (std.mem.indexOfScalar(u8, s, '-')) |i| {
            prefix = s[0..i];
            rest = s[i + 1 ..];
            is_sri = true;
        }
        const parsed: ?Algo = if (prefix) |p|
            Algo.parse(p) orelse return d.fail(error.BadHash, "unknown hash algorithm '{s}'", .{p})
        else
            null;
        const algo = parsed orelse want orelse
            return d.fail(error.BadHash, "hash '{s}' does not include a type, nor is the type otherwise known from context", .{s});
        if (parsed != null and want != null and parsed.? != want.?)
            return d.fail(error.BadHash, "hash '{s}' should have type '{s}'", .{ s, want.?.name() });
        if (is_sri) return fromEncoded(algo, rest, .base64, d);
        return parseNonSriUnprefixed(rest, algo, d);
    }

    /// Mirrors hash.cc:Hash::parseNonSRIUnprefixed (format chosen by length).
    pub fn parseNonSriUnprefixed(s: []const u8, algo: Algo, d: *Diag) Error!Hash {
        const n = algo.size();
        if (s.len == n * 2) return fromEncoded(algo, s, .base16, d);
        if (s.len == nix32EncodedLen(n)) return fromEncoded(algo, s, .nix32, d);
        if (s.len == base64EncodedLen(n)) return fromEncoded(algo, s, .base64, d);
        return d.fail(error.BadHash, "hash '{s}' has wrong length for hash algorithm '{s}'", .{ s, algo.name() });
    }

    /// Mirrors hash.cc:Hash::parseSRI.
    pub fn parseSri(s: []const u8, d: *Diag) Error!Hash {
        const i = std.mem.indexOfScalar(u8, s, '-') orelse
            return d.fail(error.BadHash, "hash '{s}' is not SRI", .{s});
        const algo = Algo.parse(s[0..i]) orelse
            return d.fail(error.BadHash, "unknown hash algorithm '{s}'", .{s[0..i]});
        return fromEncoded(algo, s[i + 1 ..], .base64, d);
    }

    pub fn fromEncoded(algo: Algo, s: []const u8, format: Format, d: *Diag) Error!Hash {
        var buf: [max_size + 4]u8 = undefined;
        const enc_name, const decoded = switch (format) {
            .base16 => .{ "base16", try decodeBase16(&buf, s, d) },
            .nix32 => .{ "nix32", try decodeNix32(&buf, s, d) },
            .base64, .sri => .{ "Base64", try decodeBase64(&buf, s, d) },
        };
        if (decoded.len != algo.size())
            return d.fail(error.BadHash, "invalid {s} hash '{s}', length {d} != expected length {d}", .{ enc_name, s, decoded.len, algo.size() });
        return raw(algo, decoded);
    }
};

/// Mirrors hash.cc:hashString.
pub fn hashBytes(algo: Algo, data: []const u8) Hash {
    var h: Hasher = .init(algo);
    h.update(data);
    return h.finish();
}

/// Mirrors hash.cc:compressHash.
pub fn compress(h: Hash, new_size: usize) Hash {
    var out: Hash = .{ .algo = h.algo, .len = @intCast(new_size), .buf = @splat(0) };
    for (h.bytes(), 0..) |b, i| out.buf[i % new_size] ^= b;
    return out;
}

/// Mirrors hash.cc:HashSink: an incremental hasher that also counts bytes.
pub const Hasher = struct {
    state: union(Algo) {
        md5: crypto.Md5,
        sha1: crypto.Sha1,
        sha256: crypto.sha2.Sha256,
        sha512: crypto.sha2.Sha512,
        blake3: crypto.Blake3,
    },
    count: u64 = 0,

    pub fn init(algo: Algo) Hasher {
        return .{ .state = switch (algo) {
            inline else => |a| @unionInit(@FieldType(Hasher, "state"), @tagName(a), .init(.{})),
        } };
    }

    pub fn update(h: *Hasher, data: []const u8) void {
        h.count += data.len;
        switch (h.state) {
            inline else => |*s| s.update(data),
        }
    }

    pub fn finish(h: *Hasher) Hash {
        var out: Hash = .{ .algo = h.state, .len = 0, .buf = @splat(0) };
        switch (h.state) {
            inline else => |*s, a| {
                const n = comptime Algo.size(a);
                s.final(out.buf[0..n]);
                out.len = n;
            },
        }
        return out;
    }

    /// A `Writer` that hashes everything written to it.
    pub fn writer(h: *Hasher, buf: []u8) HashingWriter {
        return .{ .hasher = h, .interface = .{ .buffer = buf, .vtable = &HashingWriter.vtable } };
    }
};

pub const HashingWriter = struct {
    hasher: *Hasher,
    interface: Writer,

    const vtable: Writer.VTable = .{ .drain = drain };

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *HashingWriter = @fieldParentPtr("interface", w);
        self.hasher.update(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            self.hasher.update(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.hasher.update(last);
        return n + last.len * splat;
    }
};

// Nix32: Nix's base32 with its own alphabet and reversed bit order.

const nix32_chars = "0123456789abcdfghijklmnpqrsvwxyz";

const nix32_digits: [256]u8 = blk: {
    var t: [256]u8 = @splat(0xff);
    for (nix32_chars, 0..) |c, i| t[c] = i;
    break :blk t;
};

/// Whether `c` is a Nix32 digit, the test a store path's hash part must pass
/// (path.cc:StorePath::StorePath).
pub fn isNix32Char(c: u8) bool {
    return nix32_digits[c] != 0xff;
}

/// Mirrors base-nix-32.hh:BaseNix32::encodedLength.
pub fn nix32EncodedLen(n: usize) usize {
    if (n == 0) return 0;
    return (n * 8 - 1) / 5 + 1;
}

/// Mirrors base-nix-32.cc:BaseNix32::encode.
pub fn encodeNix32(out: []u8, b: []const u8) []u8 {
    const len = nix32EncodedLen(b.len);
    for (0..len) |k| out[k] = nix32Digit(b, len - 1 - k);
    return out[0..len];
}

pub fn writeNix32(w: *Writer, b: []const u8) Writer.Error!void {
    const len = nix32EncodedLen(b.len);
    for (0..len) |k| try w.writeByte(nix32Digit(b, len - 1 - k));
}

fn nix32Digit(b: []const u8, n: usize) u8 {
    const bit = n * 5;
    const i = bit / 8;
    const j: u3 = @intCast(bit % 8);
    const lo = b[i] >> j;
    const hi: u8 = if (i + 1 < b.len and j != 0) b[i + 1] << @intCast(8 - @as(u4, j)) else 0;
    return nix32_chars[(lo | hi) & 0x1f];
}

/// Mirrors base-nix-32.cc:BaseNix32::decode. `out` needs `s.len * 5 / 8 + 1` bytes.
pub fn decodeNix32(out: []u8, s: []const u8, d: *Diag) Error![]u8 {
    if (s.len == 0) return out[0..0];
    var len = (s.len * 5 - 5) / 8 + 1;
    if (out.len < len) return d.fail(error.BadHash, "Nix32 string '{s}' is too long", .{s});
    @memset(out[0..len], 0);
    for (0..s.len) |n| {
        const c = s[s.len - n - 1];
        const digit = nix32_digits[c];
        if (digit == 0xff)
            return d.fail(error.BadHash, "invalid character in Nix32 (Nix's Base32 variation) string: '{c}'", .{c});
        const bit = n * 5;
        const i = bit / 8;
        const j: u4 = @intCast(bit % 8);
        out[i] |= digit << @intCast(j);
        const carry: u8 = if (j == 0) 0 else digit >> @intCast(8 - j);
        if (carry != 0) {
            if (len < i + 2) {
                if (out.len < i + 2) return d.fail(error.BadHash, "Nix32 string '{s}' is too long", .{s});
                out[i + 1] = 0;
                len = i + 2;
            }
            out[i + 1] |= carry;
        }
    }
    return out[0..len];
}

pub fn decodeNix32Alloc(gpa: std.mem.Allocator, s: []const u8, d: *Diag) ![]u8 {
    const buf = try gpa.alloc(u8, s.len * 5 / 8 + 2);
    errdefer gpa.free(buf);
    const n = (try decodeNix32(buf, s, d)).len;
    return gpa.realloc(buf, n);
}

// Base16 and base64 as base-n.cc writes them: lower-case hex, padded base64.

pub fn writeBase16(w: *Writer, b: []const u8) Writer.Error!void {
    // A digest is at most 64 bytes: encode it whole and write once, where
    // `printHex` goes through the writer a byte at a time.
    if (b.len > 64) return w.printHex(b, .lower);
    const digits = "0123456789abcdef";
    var buf: [128]u8 = undefined;
    for (b, 0..) |c, i| {
        buf[2 * i] = digits[c >> 4];
        buf[2 * i + 1] = digits[c & 15];
    }
    return w.writeAll(buf[0 .. 2 * b.len]);
}

/// Mirrors base-n.cc:base16::decode.
pub fn decodeBase16(out: []u8, s: []const u8, d: *Diag) Error![]u8 {
    if (s.len % 2 != 0) return d.fail(error.BadHash, "invalid base16 string '{s}': odd length", .{s});
    if (out.len < s.len / 2) return d.fail(error.BadHash, "base16 string '{s}' is too long", .{s});
    for (0..s.len / 2) |i| {
        const hi = try nibble(s[2 * i], d);
        const lo = try nibble(s[2 * i + 1], d);
        out[i] = hi << 4 | lo;
    }
    return out[0 .. s.len / 2];
}

fn nibble(c: u8, d: *Diag) Error!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => d.fail(error.BadHash, "invalid character in base16 string: '{c}'", .{c}),
    };
}

const base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Mirrors base-n.hh:base64::encodedLength.
pub fn base64EncodedLen(n: usize) usize {
    return (n + 2) / 3 * 4;
}

/// Mirrors base-n.cc:base64::encode.
pub fn writeBase64(w: *Writer, b: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < b.len) : (i += 3) {
        const chunk = b[i..@min(i + 3, b.len)];
        var n: u32 = 0;
        for (chunk, 0..) |c, k| n |= @as(u32, c) << @intCast(16 - 8 * k);
        for (0..4) |k| {
            try w.writeByte(if (k <= chunk.len) base64_chars[(n >> @intCast(18 - 6 * k)) & 0x3f] else '=');
        }
    }
}

/// Mirrors base-n.cc:base64::decode (stops at '=', skips '\n').
pub fn decodeBase64(out: []u8, s: []const u8, d: *Diag) Error![]u8 {
    var len: usize = 0;
    var acc: u32 = 0;
    var bits: u5 = 0;
    for (s) |c| {
        if (c == '=') break;
        if (c == '\n') continue;
        const digit = std.mem.indexOfScalar(u8, base64_chars, c) orelse
            return d.fail(error.BadHash, "invalid character in Base64 string: '{c}'", .{c});
        bits += 6;
        acc = acc << 6 | @as(u32, @intCast(digit));
        if (bits >= 8) {
            if (len == out.len) return d.fail(error.BadHash, "Base64 string '{s}' is too long", .{s});
            out[len] = @truncate(acc >> (bits - 8));
            len += 1;
            bits -= 8;
        }
    }
    return out[0..len];
}

pub fn decodeBase64Alloc(gpa: std.mem.Allocator, s: []const u8, d: *Diag) ![]u8 {
    const buf = try gpa.alloc(u8, (s.len + 3) / 4 * 3);
    errdefer gpa.free(buf);
    const n = (try decodeBase64(buf, s, d)).len;
    return gpa.realloc(buf, n);
}

const testing = std.testing;
const abc_sha256_hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

fn expectPrinted(h: Hash, format: Format, include_algo: bool, want: []const u8) !void {
    var buf: [Hash.max_string_len]u8 = undefined;
    try testing.expectEqualStrings(want, h.print(&buf, format, include_algo));
}

// nix hash convert --hash-algo ALGO --to nix32 $(printf abc | ALGOsum | cut -d' ' -f1)
test "nix32" {
    try expectPrinted(hashBytes(.sha256, "abc"), .nix32, false, "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s");
    try expectPrinted(hashBytes(.sha1, "abc"), .nix32, false, "kpcd173cq987hw957sx6m0868wv3x6d9");
    try expectPrinted(hashBytes(.md5, "abc"), .nix32, false, "3jgzhjhz9zjvbb0kyj7jc500ch");
}

test "base16" {
    try expectPrinted(hashBytes(.sha256, "abc"), .base16, false, abc_sha256_hex);
    try expectPrinted(hashBytes(.sha1, "abc"), .base16, false, "a9993e364706816aba3e25717850c26c9cd0d89d");
    try expectPrinted(hashBytes(.sha256, ""), .base16, false, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    try expectPrinted(hashBytes(.sha256, "abc"), .base16, true, "sha256:" ++ abc_sha256_hex);
}

test "sri and sha512" {
    try expectPrinted(hashBytes(.sha256, "abc"), .sri, false, "sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");
    const h = hashBytes(.sha512, "abc");
    try expectPrinted(h, .nix32, false, "2gs8k559z4rlahfx0y688s49m2vvszylcikrfinm30ly9rak69236nkam5ydvly1ai7xac99vxfc4ii84hawjbk876blyk1jfhkbbyx");
    try expectPrinted(h, .base64, false, "3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==");
}

test "streaming matches one-shot" {
    var h: Hasher = .init(.sha256);
    var buf: [4]u8 = undefined;
    var w = h.writer(&buf);
    try w.interface.writeAll("a");
    try w.interface.writeAll("bcdefgh");
    try w.interface.flush();
    try testing.expectEqual(8, h.count);
    try testing.expect(h.finish().eql(hashBytes(.sha256, "abcdefgh")));
}

test "parseAny accepts every format" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const h = hashBytes(.sha256, "abc");
    var b1: [Hash.max_string_len]u8 = undefined;
    var b2: [Hash.max_string_len]u8 = undefined;
    const inputs = [_][]const u8{
        abc_sha256_hex,
        "sha256:" ++ abc_sha256_hex,
        h.print(&b1, .nix32, true),
        h.print(&b2, .sri, false),
    };
    for (inputs) |s| try testing.expect((try Hash.parseAny(s, .sha256, &d)).eql(h));
    try testing.expect((try Hash.parseAny(inputs[3], null, &d)).eql(h));
    try testing.expectError(error.BadHash, Hash.parseAny(abc_sha256_hex, null, &d));
    try testing.expectError(error.BadHash, Hash.parseAny("sha1:" ++ abc_sha256_hex, .sha256, &d));
    try testing.expectEqualStrings("hash 'sha1:" ++ abc_sha256_hex ++ "' should have type 'sha256'", d.message());
    try testing.expectError(error.BadHash, Hash.parseAny("sha256:abc", null, &d));
}

test "nix32 round-trips and rejects" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    for (1..70) |n| {
        var data: [70]u8 = undefined;
        for (0..n) |i| data[i] = @truncate(i * 37 + 11);
        var enc: [128]u8 = undefined;
        var dec: [80]u8 = undefined;
        const e = encodeNix32(&enc, data[0..n]);
        try testing.expectEqualSlices(u8, data[0..n], try decodeNix32(&dec, e, &d));
    }
    var dec: [80]u8 = undefined;
    try testing.expectError(error.BadHash, decodeNix32(&dec, "e", &d));
    try testing.expectEqual(20, (try decodeNix32(&dec, &@as([32]u8, @splat('z')), &d)).len);
    try testing.expectError(error.BadHash, Hash.fromEncoded(.sha256, &@as([52]u8, @splat('z')), .nix32, &d));
}

test "base64 round-trips" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    for (0..70) |n| {
        var data: [70]u8 = undefined;
        for (0..n) |i| data[i] = @truncate(i * 53 + 7);
        var enc: [128]u8 = undefined;
        var w: Writer = .fixed(&enc);
        try writeBase64(&w, data[0..n]);
        try testing.expectEqual(base64EncodedLen(n), w.buffered().len);
        var dec: [80]u8 = undefined;
        try testing.expectEqualSlices(u8, data[0..n], try decodeBase64(&dec, w.buffered(), &d));
    }
    var dec: [8]u8 = undefined;
    try testing.expectError(error.BadHash, decodeBase64(&dec, "ab$c", &d));
}

test "compress xors" {
    const c = compress(Hash.raw(.sha256, &.{ 1, 2, 3, 4, 5, 6 }), 4);
    try testing.expectEqualSlices(u8, &.{ 1 ^ 5, 2 ^ 6, 3, 4 }, c.bytes());
}
