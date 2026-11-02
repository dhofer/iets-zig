//! Byte scanning shared by the lexer and the printers, and the byte
//! decodings several readers share.

const std = @import("std");

/// The first index at or after `start` holding one of `needles`, 16 bytes at
/// a time: `std.mem.findAnyPos` is a scalar loop, and comments and string
/// bodies are long.
pub fn findAnyPos(src: []const u8, start: usize, comptime needles: []const u8) ?usize {
    const V = @Vector(16, u8);
    var i = start;
    while (i + 16 <= src.len) : (i += 16) {
        const v: V = src[i..][0..16].*;
        var hit: @Vector(16, bool) = @splat(false);
        inline for (needles) |n| hit = hit | (v == @as(V, @splat(n)));
        const mask: u16 = @bitCast(hit);
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < src.len) : (i += 1) {
        inline for (needles) |n| if (src[i] == n) return i;
    }
    return null;
}

/// `std.mem.eql` for long byte strings: four 64-byte blocks per branch,
/// their differences OR-ed together, where `std.mem.eql` tests every block.
/// The shared-string table compares whole strings on every hit, some of
/// them scripts of many kilobytes.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len < 64 or a.ptr == b.ptr) return std.mem.eql(u8, a, b);
    const V = @Vector(64, u8);
    const zero: V = @splat(0);
    var i: usize = 0;
    while (i + 256 <= a.len) : (i += 256) {
        var x: V = zero;
        inline for (0..4) |k| x |= @as(V, a[i + 64 * k ..][0..64].*) ^ @as(V, b[i + 64 * k ..][0..64].*);
        if (@as(u64, @bitCast(x != zero)) != 0) return false;
    }
    while (i + 64 <= a.len) : (i += 64) {
        if (@as(u64, @bitCast(@as(V, a[i..][0..64].*) != @as(V, b[i..][0..64].*))) != 0) return false;
    }
    // The last block, overlapping what was compared already.
    const t = a.len - 64;
    return @as(u64, @bitCast(@as(V, a[t..][0..64].*) != @as(V, b[t..][0..64].*))) == 0;
}

test eql {
    var x: [1000]u8 = undefined;
    for (&x, 0..) |*c, i| c.* = @truncate(i *% 7);
    var y = x;
    for ([_]usize{ 0, 63, 64, 65, 255, 256, 300, 999 }) |n| {
        try std.testing.expect(eql(x[0..n], y[0..n]));
        if (n == 0) continue;
        y[n - 1] ^= 1;
        try std.testing.expect(!eql(x[0..n], y[0..n]));
        y[n / 2] ^= 1;
        y[n - 1] ^= 1;
        try std.testing.expect(!eql(x[0..n], y[0..n]));
        y[n / 2] ^= 1;
    }
    try std.testing.expect(!eql(x[0..70], y[0..71]));
}

/// Append the offset after every `\n` of `src` to `starts`, 64 bytes at a
/// time: one mask per block and a loop over its bits, where a search per
/// line pays its setup every 30 bytes. False, with `starts` in an
/// unspecified state, when `src` holds a `\r`, whose rules are the caller's.
pub fn newlineStarts(gpa: std.mem.Allocator, src: []const u8, starts: *std.ArrayList(u32)) !bool {
    const V = @Vector(64, u8);
    var cr: u64 = 0;
    var i: usize = 0;
    while (i + 64 <= src.len) : (i += 64) {
        const v: V = src[i..][0..64].*;
        var m: u64 = @bitCast(v == @as(V, @splat('\n')));
        cr |= @bitCast(v == @as(V, @splat('\r')));
        try starts.ensureUnusedCapacity(gpa, @popCount(m));
        while (m != 0) : (m &= m - 1) starts.appendAssumeCapacity(@intCast(i + @ctz(m) + 1));
    }
    for (src[i..], i..) |c, k| switch (c) {
        '\n' => try starts.append(gpa, @intCast(k + 1)),
        '\r' => return false,
        else => {},
    };
    return cr == 0;
}

test newlineStarts {
    const gpa = std.testing.allocator;
    var l: std.ArrayList(u32) = .empty;
    defer l.deinit(gpa);
    const src = "a\n" ++ @as([70]u8, @splat('b')) ++ "\n\nc\n";
    try std.testing.expect(try newlineStarts(gpa, src, &l));
    try std.testing.expectEqualSlices(u32, &.{ 2, 73, 74, 76 }, l.items);
    l.clearRetainingCapacity();
    try std.testing.expect(!try newlineStarts(gpa, @as([65]u8, @splat('x')) ++ "\r\n", &l));
    try std.testing.expect(!try newlineStarts(gpa, "a\r" ++ @as([64]u8, @splat('x')), &l));
}

/// The first byte at or after `start` that JSON must escape: a quote, a
/// backslash or a control character.
pub fn findJsonEscape(src: []const u8, start: usize) ?usize {
    const V = @Vector(16, u8);
    var i = start;
    while (i + 16 <= src.len) : (i += 16) {
        const v: V = src[i..][0..16].*;
        const hit = (v < @as(V, @splat(0x20))) | (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\\')));
        const mask: u16 = @bitCast(hit);
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < src.len) : (i += 1) switch (src[i]) {
        0...0x1f, '"', '\\' => return i,
        else => {},
    };
    return null;
}

test "findJsonEscape" {
    try std.testing.expectEqual(@as(?usize, 20), findJsonEscape("abcdefghijklmnopqrst\"x", 0));
    try std.testing.expectEqual(@as(?usize, 3), findJsonEscape("abc\n", 0));
    try std.testing.expectEqual(@as(?usize, null), findJsonEscape("plain text that is long enough", 0));
}

test "findAnyPos agrees with std" {
    var buf: [100]u8 = undefined;
    for (&buf, 0..) |*b, k| b.* = @truncate('a' + k % 26);
    buf[37] = '$';
    buf[80] = '\n';
    for (0..100) |st| {
        try std.testing.expectEqual(std.mem.findAnyPos(u8, &buf, st, "$\n"), findAnyPos(&buf, st, "$\n"));
    }
}

/// CRC-32 (IEEE), the checksum of `std.hash.Crc32`, 16 bytes per step with
/// sixteen tables: the std one takes a table lookup per byte, and the IR
/// cache sums every entry it reads, tens of megabytes a run.
pub const Crc32 = struct {
    crc: u32 = 0xffff_ffff,

    const tables = blk: {
        @setEvalBranchQuota(100_000);
        var t: [16][256]u32 = undefined;
        for (0..256) |i| {
            var c: u32 = i;
            for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0xedb8_8320 else c >> 1;
            t[0][i] = c;
        }
        for (0..256) |i| for (1..16) |k| {
            t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
        };
        break :blk t;
    };

    pub fn update(h: *Crc32, data: []const u8) void {
        var c = h.crc;
        var i: usize = 0;
        while (i + 16 <= data.len) : (i += 16) {
            const b = data[i..][0..16];
            const w = std.mem.readInt(u32, b[0..4], .little) ^ c;
            c = tables[15][w & 0xff] ^ tables[14][(w >> 8) & 0xff] ^ tables[13][(w >> 16) & 0xff] ^ tables[12][w >> 24];
            inline for (4..16) |k| c ^= tables[15 - k][b[k]];
        }
        for (data[i..]) |x| c = tables[0][(c ^ x) & 0xff] ^ (c >> 8);
        h.crc = c;
    }

    pub fn final(h: Crc32) u32 {
        return ~h.crc;
    }
};

test Crc32 {
    var buf: [1000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    for ([_]usize{ 0, 1, 15, 16, 17, 100, 1000 }) |n| {
        var a: Crc32 = .{};
        a.update(buf[0 .. n / 2]);
        a.update(buf[n / 2 .. n]);
        try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), a.final());
    }
}

/// `%XX` decoded in a copy of `s`; a `%` without two hex digits stays.
/// With `plus_is_space`, `+` is a space, as in a URL's query and userinfo;
/// a gRPC message keeps it.
pub fn percentDecode(a: std.mem.Allocator, s: []const u8, comptime plus_is_space: bool) std.mem.Allocator.Error![]u8 {
    const out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |c| {
                out[n] = c;
                n += 1;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = if (plus_is_space and s[i] == '+') ' ' else s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

test percentDecode {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a b%", try percentDecode(a, "a%20b%", false));
    try std.testing.expectEqualStrings("a b", try percentDecode(a, "a+b", true));
    try std.testing.expectEqualStrings("a+b", try percentDecode(a, "a+b", false));
    try std.testing.expectEqualStrings("%4", try percentDecode(a, "%4", true));
}
