//! The LZ4 block format, as `lz4_flex::block` writes and reads it: a raw
//! block with no frame and no size prefix, the decompressed size kept by the
//! caller. The input store's packs (`pack.zig`) hold their payloads in it.
//! The compressor need not match `lz4_flex` byte for byte: any valid block
//! decodes the same.

const std = @import("std");

/// The last match must start this far before the end of the block, and the
/// last five bytes are always literals (the format's end-of-block rules).
const mf_limit = 12;
const last_literals = 5;
const min_match = 4;
const hash_log = 12;
const max_distance = 65535;

/// The largest block `compress` can make of `n` bytes.
pub fn bound(n: usize) usize {
    return n + n / 255 + 16;
}

fn hash4(v: u32) u32 {
    return (v *% 2654435761) >> (32 - hash_log);
}

fn read32(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

fn putLength(out: []u8, o: *usize, n: usize) void {
    var left = n;
    while (left >= 255) : (left -= 255) {
        out[o.*] = 255;
        o.* += 1;
    }
    out[o.*] = @intCast(left);
    o.* += 1;
}

fn emit(out: []u8, o: *usize, lit: []const u8, match_len: ?usize, offset: u16) void {
    const ll = lit.len;
    const ml = if (match_len) |m| m - min_match else 0;
    const token_at = o.*;
    o.* += 1;
    var token: u8 = @as(u8, @intCast(@min(ll, 15))) << 4;
    if (ll >= 15) putLength(out, o, ll - 15);
    @memcpy(out[o.*..][0..ll], lit);
    o.* += ll;
    if (match_len != null) {
        std.mem.writeInt(u16, out[o.*..][0..2], offset, .little);
        o.* += 2;
        token |= @intCast(@min(ml, 15));
        if (ml >= 15) putLength(out, o, ml - 15);
    }
    out[token_at] = token;
}

/// `src` compressed into `out`, which holds at least `bound(src.len)` bytes;
/// the block's length. Greedy matching over a hash of four bytes, with the
/// skip that speeds through data that does not compress.
pub fn compress(src: []const u8, out: []u8) usize {
    std.debug.assert(out.len >= bound(src.len));
    var o: usize = 0;
    if (src.len < mf_limit + 1) {
        emit(out, &o, src, null, 0);
        return o;
    }
    var table: [1 << hash_log]u32 = @splat(0);
    const match_limit = src.len - mf_limit;
    const end_match = src.len - last_literals;
    var anchor: usize = 0;
    var i: usize = 1;
    table[hash4(read32(src, 0))] = 0;
    var misses: usize = 0;
    while (i < match_limit) {
        const v = read32(src, i);
        const h = hash4(v);
        const cand: usize = table[h];
        table[h] = @intCast(i);
        if (cand < i and i - cand <= max_distance and read32(src, cand) == v) {
            misses = 0;
            var s = i;
            var c = cand;
            // extend backwards over literals not yet emitted
            while (s > anchor and c > 0 and src[s - 1] == src[c - 1]) {
                s -= 1;
                c -= 1;
            }
            var len: usize = min_match + (i - s);
            while (i + (len - (i - s)) < end_match and src[s + len] == src[c + len]) len += 1;
            emit(out, &o, src[anchor..s], len, @intCast(s - c));
            i = s + len;
            anchor = i;
            if (i >= match_limit) break;
            // seed the table with the position just before the next search
            table[hash4(read32(src, i - 2))] = @intCast(i - 2);
            continue;
        }
        misses += 1;
        i += 1 + (misses >> 6);
    }
    emit(out, &o, src[anchor..], null, 0);
    return o;
}

pub const Error = error{CorruptInput};

/// The block `src` decompressed into `out`, which must come out exactly full.
pub fn decompress(src: []const u8, out: []u8) Error!void {
    var i: usize = 0;
    var o: usize = 0;
    while (true) {
        if (i >= src.len) return error.CorruptInput;
        const token = src[i];
        i += 1;
        var ll: usize = token >> 4;
        if (ll == 15) ll += try takeLength(src, &i);
        if (ll > src.len - i or ll > out.len - o) return error.CorruptInput;
        @memcpy(out[o..][0..ll], src[i..][0..ll]);
        i += ll;
        o += ll;
        if (i == src.len) break;
        if (src.len - i < 2) return error.CorruptInput;
        const offset: usize = std.mem.readInt(u16, src[i..][0..2], .little);
        i += 2;
        if (offset == 0 or offset > o) return error.CorruptInput;
        var ml: usize = (token & 15) + min_match;
        if (token & 15 == 15) ml += try takeLength(src, &i);
        if (ml > out.len - o) return error.CorruptInput;
        // an overlapping match repeats the bytes it has just written
        if (offset >= ml) {
            @memcpy(out[o..][0..ml], out[o - offset ..][0..ml]);
        } else {
            for (0..ml) |k| out[o + k] = out[o + k - offset];
        }
        o += ml;
    }
    if (o != out.len) return error.CorruptInput;
}

fn takeLength(src: []const u8, i: *usize) Error!usize {
    var n: usize = 0;
    while (true) {
        if (i.* >= src.len) return error.CorruptInput;
        const b = src[i.*];
        i.* += 1;
        n += b;
        if (b != 255) return n;
    }
}

const testing = std.testing;

fn roundTrip(src: []const u8) !usize {
    const buf = try testing.allocator.alloc(u8, bound(src.len));
    defer testing.allocator.free(buf);
    const n = compress(src, buf);
    const back = try testing.allocator.alloc(u8, src.len);
    defer testing.allocator.free(back);
    try decompress(buf[0..n], back);
    try testing.expectEqualSlices(u8, src, back);
    return n;
}

test "blocks round-trip, and a repetitive one shrinks" {
    _ = try roundTrip("");
    _ = try roundTrip("short");
    _ = try roundTrip("exactly13byte");
    try testing.expect(try roundTrip(&@as([4096]u8, @splat('a'))) < 64);
    var words: [20000]u8 = undefined;
    for (&words, 0..) |*b, i| b.* = @truncate(i *% 7 +% (i >> 9));
    _ = try roundTrip(&words);
    var x: u64 = 0x9e3779b97f4a7c15;
    var noise: [70000]u8 = undefined;
    for (&noise) |*b| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        b.* = @truncate(x);
    }
    _ = try roundTrip(&noise);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..3000) |i| try text.print(testing.allocator, "line {d} of the file, {d}\n", .{ i, i % 17 });
    try testing.expect(try roundTrip(text.items) < text.items.len / 2);
}

test "a block in the reference format decodes" {
    // three literals, a match of 16 at offset 3, and the five last literals
    const block = [_]u8{ 0x3c, 'a', 'b', 'c', 3, 0, 0x50, 'b', 'c', 'a', 'b', 'c' };
    var out: [24]u8 = undefined;
    try decompress(&block, &out);
    try testing.expectEqualStrings("abcabcabcabcabcabcabcabc", &out);
}

test "a corrupt block is an error, never a crash" {
    var out: [32]u8 = undefined;
    try testing.expectError(error.CorruptInput, decompress(&.{ 0x10, 'a', 5, 0 }, &out));
    try testing.expectError(error.CorruptInput, decompress(&.{0xf0}, &out));
    try testing.expectError(error.CorruptInput, decompress(&.{}, &out));
    try testing.expectError(error.CorruptInput, decompress(&.{ 0x10, 'a' }, out[0..2]));
}
