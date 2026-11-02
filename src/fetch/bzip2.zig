//! A bzip2 decompressor, written out because std has none. Streams follow
//! one another until the input ends, as Rust iets reads them. Every block's
//! CRC and every stream's combined CRC are checked.
//!
//! The decoding follows the format bzip2 1.0.8 writes (decompress.c): the
//! Huffman stage with its selectors, the move-to-front stage with its runs of
//! RUNA and RUNB, the inverse Burrows-Wheeler transform, and the initial
//! run-length stage. A block is decoded whole into the transform's table and
//! its bytes come out a buffer at a time, so a block that expands far is never
//! held expanded. Randomised blocks, which no bzip2 since 0.9.5 writes, are an
//! error.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;

pub const Error = error{
    /// The input is not bzip2, or breaks its rules.
    CorruptInput,
    /// A block or a stream does not match its CRC.
    WrongChecksum,
    /// A randomised block (bzip2 0.9.0).
    Unsupported,
} || Reader.Error || std.mem.Allocator.Error;

const block_magic: u48 = 0x314159265359;
const end_magic: u48 = 0x177245385090;
const max_groups = 6;
const max_alpha = 258;
const max_code_len = 20;
const group_size = 50;
const max_selectors = 18002;

/// The CRC bzip2 uses: CRC-32 with the polynomial 0x04c11db7, not reflected.
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @as(u32, i) << 24;
        for (0..8) |_| c = if (c & 0x80000000 != 0) (c << 1) ^ 0x04c11db7 else c << 1;
        e.* = c;
    }
    break :blk t;
};

const Huffman = struct {
    min_len: u5,
    max_len: u5,
    limit: [max_code_len + 2]i32,
    base: [max_code_len + 2]i32,
    perm: [max_alpha]u16,

    /// Mirrors huffman.c:BZ2_hbCreateDecodeTables.
    fn init(lens: []const u8) Huffman {
        var h: Huffman = undefined;
        var lo: u8 = 32;
        var hi: u8 = 0;
        for (lens) |l| {
            lo = @min(lo, l);
            hi = @max(hi, l);
        }
        h.min_len = @intCast(lo);
        h.max_len = @intCast(hi);
        var pp: usize = 0;
        for (lo..hi + 1) |i| {
            for (lens, 0..) |l, j| if (l == i) {
                h.perm[pp] = @intCast(j);
                pp += 1;
            };
        }
        var base: [max_code_len + 2]i32 = @splat(0);
        for (lens) |l| base[l + 1] += 1;
        for (1..base.len) |i| base[i] += base[i - 1];
        var limit: [max_code_len + 2]i32 = @splat(0);
        var vec: i32 = 0;
        for (lo..hi + 1) |i| {
            vec += base[i + 1] - base[i];
            limit[i] = vec - 1;
            vec <<= 1;
        }
        for (lo + 1..hi + 1) |i| base[i] = ((limit[i - 1] + 1) << 1) - base[i];
        h.limit = limit;
        h.base = base;
        return h;
    }
};

pub const Decompress = struct {
    input: *Reader,
    gpa: std.mem.Allocator,
    reader: Reader,
    err: ?Error = null,

    bits: u64 = 0,
    nbits: u7 = 0,

    /// The transform's table: a byte in the low eight bits, the next
    /// position above them. Sized for the largest block, 900k.
    tt: []u32 = &.{},
    block_max: usize = 0,
    /// The block being written out: positions left and the next one's index.
    left: usize = 0,
    pos: u32 = 0,
    /// The run-length stage: the last byte, how many times it came in a row,
    /// and copies still owed from a run's count byte.
    last: i32 = -1,
    run: u8 = 0,
    owed: u32 = 0,
    owed_byte: u8 = 0,
    block_crc: u32 = 0,
    want_block_crc: u32 = 0,
    stream_crc: u32 = 0,
    state: enum { stream_start, block_start, in_block, done } = .stream_start,

    pub fn init(input: *Reader, gpa: std.mem.Allocator, buffer: []u8) Decompress {
        return .{
            .input = input,
            .gpa = gpa,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn deinit(d: *Decompress) void {
        d.gpa.free(d.tt);
    }

    fn stream(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        const d: *Decompress = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = d.fill(dest) catch |e| switch (e) {
            error.ReadFailed => return error.ReadFailed,
            else => {
                d.err = e;
                return error.ReadFailed;
            },
        };
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    fn need(d: *Decompress, n: u7) Error!void {
        while (d.nbits < n) {
            const b = d.input.takeByte() catch |e| switch (e) {
                error.EndOfStream => return error.CorruptInput,
                else => |x| return x,
            };
            d.bits = (d.bits << 8) | b;
            d.nbits += 8;
        }
    }

    fn take(d: *Decompress, comptime T: type) Error!T {
        const n = @bitSizeOf(T);
        try d.need(n);
        d.nbits -= n;
        const v: T = @truncate(d.bits >> @intCast(d.nbits));
        return v;
    }

    fn bit(d: *Decompress) Error!bool {
        return try d.take(u1) == 1;
    }

    /// Bytes into `out`; zero only at the end of the last stream.
    fn fill(d: *Decompress, out: []u8) Error!usize {
        var o: usize = 0;
        while (o < out.len) {
            switch (d.state) {
                .done => break,
                .stream_start => {
                    if (!try d.startStream()) {
                        d.state = .done;
                        break;
                    }
                    d.state = .block_start;
                },
                .block_start => {
                    if (!try d.readBlock()) {
                        // the end of a stream; another may follow
                        d.state = .stream_start;
                        continue;
                    }
                    d.state = .in_block;
                },
                .in_block => {
                    o += d.emit(out[o..]);
                    if (d.left == 0 and d.owed == 0) {
                        if (~d.block_crc != d.want_block_crc) return error.WrongChecksum;
                        d.stream_crc = ((d.stream_crc << 1) | (d.stream_crc >> 31)) ^ d.want_block_crc;
                        d.state = .block_start;
                    }
                },
            }
        }
        return o;
    }

    /// The `BZh` header of the next stream; false when the input has ended.
    fn startStream(d: *Decompress) Error!bool {
        // a stream ends on a byte boundary: the bits left are its padding
        d.nbits = 0;
        _ = d.input.peekByte() catch |e| switch (e) {
            error.EndOfStream => return false,
            else => |x| return x,
        };
        const head = d.input.takeArray(4) catch |e| switch (e) {
            error.EndOfStream => return error.CorruptInput,
            else => |x| return x,
        };
        if (!std.mem.eql(u8, head[0..3], "BZh") or head[3] < '1' or head[3] > '9') return error.CorruptInput;
        const max = @as(usize, head[3] - '0') * 100_000;
        if (max > d.tt.len) {
            d.gpa.free(d.tt);
            d.tt = &.{};
            d.tt = try d.gpa.alloc(u32, max);
        }
        d.block_max = max;
        d.stream_crc = 0;
        return true;
    }

    /// Decodes the next block into `tt`; false at the end of the stream.
    fn readBlock(d: *Decompress) Error!bool {
        const magic = try d.take(u48);
        if (magic == end_magic) {
            if (try d.take(u32) != d.stream_crc) return error.WrongChecksum;
            return false;
        }
        if (magic != block_magic) return error.CorruptInput;
        d.want_block_crc = try d.take(u32);
        if (try d.bit()) return error.Unsupported;
        const orig_ptr: u32 = try d.take(u24);

        // the bytes the block uses
        var seq_to_byte: [256]u8 = undefined;
        var in_use: usize = 0;
        const groups16 = try d.take(u16);
        for (0..16) |i| {
            if (groups16 & (@as(u16, 0x8000) >> @intCast(i)) == 0) continue;
            const sub = try d.take(u16);
            for (0..16) |j| if (sub & (@as(u16, 0x8000) >> @intCast(j)) != 0) {
                seq_to_byte[in_use] = @intCast(i * 16 + j);
                in_use += 1;
            };
        }
        if (in_use == 0) return error.CorruptInput;
        const alpha = in_use + 2;

        const n_groups: usize = try d.take(u3);
        if (n_groups < 2 or n_groups > max_groups) return error.CorruptInput;
        const n_selectors: usize = try d.take(u15);
        if (n_selectors < 1) return error.CorruptInput;
        var selectors = try d.gpa.alloc(u8, @min(n_selectors, max_selectors));
        defer d.gpa.free(selectors);
        var mtf_groups: [max_groups]u8 = .{ 0, 1, 2, 3, 4, 5 };
        for (0..n_selectors) |i| {
            var j: usize = 0;
            while (try d.bit()) {
                j += 1;
                if (j >= n_groups) return error.CorruptInput;
            }
            // bzip2 1.0.8 reads selectors past its limit and drops them
            if (i >= max_selectors) continue;
            const v = mtf_groups[j];
            var k = j;
            while (k > 0) : (k -= 1) mtf_groups[k] = mtf_groups[k - 1];
            mtf_groups[0] = v;
            selectors[i] = v;
        }
        const used_selectors = @min(n_selectors, max_selectors);

        var tables: [max_groups]Huffman = undefined;
        for (0..n_groups) |t| {
            var lens: [max_alpha]u8 = undefined;
            var cur: i32 = try d.take(u5);
            for (0..alpha) |i| {
                while (true) {
                    if (cur < 1 or cur > max_code_len) return error.CorruptInput;
                    if (!try d.bit()) break;
                    cur += if (try d.bit()) -1 else 1;
                }
                lens[i] = @intCast(cur);
            }
            tables[t] = .init(lens[0..alpha]);
        }

        // Huffman and move-to-front together
        var mtf: [256]u8 = undefined;
        for (&mtf, 0..) |*m, i| m.* = @intCast(i);
        var counts: [256]u32 = @splat(0);
        var n: usize = 0;
        var group: usize = 0;
        var group_left: usize = 0;
        var table: *const Huffman = &tables[0];
        const eob = alpha - 1;
        var run: usize = 0;
        var run_weight: usize = 1;
        while (true) {
            if (group_left == 0) {
                if (group >= used_selectors) return error.CorruptInput;
                table = &tables[selectors[group]];
                group += 1;
                group_left = group_size;
            }
            group_left -= 1;
            const sym = try d.symbol(table);
            if (sym <= 1) {
                if (run_weight >= 2 * 1024 * 1024) return error.CorruptInput;
                run += (sym + 1) * run_weight;
                run_weight <<= 1;
                continue;
            }
            if (run > 0) {
                const b = seq_to_byte[mtf[0]];
                if (run > d.block_max - n) return error.CorruptInput;
                counts[b] += @intCast(run);
                @memset(d.tt[n..][0..run], b);
                n += run;
                run = 0;
                run_weight = 1;
            }
            if (sym == eob) break;
            if (n >= d.block_max) return error.CorruptInput;
            const idx = sym - 1;
            const v = mtf[idx];
            std.mem.copyBackwards(u8, mtf[1 .. idx + 1], mtf[0..idx]);
            mtf[0] = v;
            const b = seq_to_byte[v];
            counts[b] += 1;
            d.tt[n] = b;
            n += 1;
        }
        if (orig_ptr >= n) return error.CorruptInput;

        // the inverse transform: link every position to the next
        var sum: u32 = 0;
        for (&counts) |*c| {
            const k = c.*;
            c.* = sum;
            sum += k;
        }
        for (0..n) |i| {
            const b: u8 = @truncate(d.tt[i]);
            d.tt[counts[b]] |= @as(u32, @intCast(i)) << 8;
            counts[b] += 1;
        }
        // the entry at `orig_ptr` only starts the chain; its byte is not output
        d.pos = d.tt[orig_ptr] >> 8;
        d.left = n;
        d.last = -1;
        d.run = 0;
        d.owed = 0;
        d.block_crc = 0xffffffff;
        return true;
    }

    fn symbol(d: *Decompress, h: *const Huffman) Error!usize {
        var len: u7 = h.min_len;
        var v: i32 = @intCast(try d.takeBits(len));
        while (len <= max_code_len and v > h.limit[len]) {
            len += 1;
            v = (v << 1) | @intFromBool(try d.bit());
        }
        if (len > max_code_len) return error.CorruptInput;
        const at = v - h.base[len];
        if (at < 0 or at >= max_alpha) return error.CorruptInput;
        return h.perm[@intCast(at)];
    }

    fn takeBits(d: *Decompress, n: u7) Error!u32 {
        if (n == 0) return 0;
        try d.need(n);
        d.nbits -= n;
        return @truncate((d.bits >> @intCast(d.nbits)) & ((@as(u64, 1) << @intCast(n)) - 1));
    }

    /// The block's bytes after the run-length stage, into `out`.
    fn emit(d: *Decompress, out: []u8) usize {
        var o: usize = 0;
        var crc = d.block_crc;
        defer d.block_crc = crc;
        while (o < out.len) {
            if (d.owed > 0) {
                const k = @min(d.owed, out.len - o);
                @memset(out[o..][0..k], d.owed_byte);
                for (0..k) |_| crc = (crc << 8) ^ crc_table[(crc >> 24) ^ d.owed_byte];
                o += k;
                d.owed -= @intCast(k);
                continue;
            }
            if (d.left == 0) break;
            const e = d.tt[d.pos];
            const b: u8 = @truncate(e);
            d.pos = e >> 8;
            d.left -= 1;
            if (d.run == 4) {
                // the byte after four alike counts more copies
                d.owed = b;
                d.owed_byte = @intCast(d.last);
                d.run = 0;
                d.last = -1;
                continue;
            }
            if (b == d.last) d.run += 1 else {
                d.run = 1;
                d.last = b;
            }
            out[o] = b;
            o += 1;
            crc = (crc << 8) ^ crc_table[(crc >> 24) ^ b];
        }
        return o;
    }
};

const testing = std.testing;

fn decompressAll(in: []const u8) ![]u8 {
    var r: Reader = .fixed(in);
    var buf: [4096]u8 = undefined;
    var d: Decompress = .init(&r, testing.allocator, &buf);
    defer d.deinit();
    return d.reader.allocRemaining(testing.allocator, .unlimited) catch |e| {
        if (d.err) |x| return x;
        return e;
    };
}

// `printf 'hello bzip2\n' | bzip2 -9`
const hello = [_]u8{
    0x42, 0x5a, 0x68, 0x39, 0x31, 0x41, 0x59, 0x26, 0x53, 0x59, 0xab, 0x6b, 0xa1, 0xf1, 0x00, 0x00,
    0x02, 0xd9, 0x80, 0x00, 0x10, 0x40, 0x00, 0x10, 0x00, 0x12, 0x64, 0xc0, 0x10, 0x20, 0x00, 0x31,
    0x00, 0xd3, 0x4d, 0x04, 0x00, 0x1e, 0xa3, 0xef, 0x4e, 0x51, 0xa2, 0x07, 0x8b, 0xb9, 0x22, 0x9c,
    0x28, 0x48, 0x55, 0xb5, 0xd0, 0xf8, 0x80,
};

test "a stream decodes, and two streams in a row decode to both" {
    const one = try decompressAll(&hello);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("hello bzip2\n", one);
    const two = try decompressAll(&hello ++ hello);
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("hello bzip2\nhello bzip2\n", two);
}

test "a changed byte is an error" {
    // the last byte holds padding, which nothing checks
    for (4..hello.len - 1) |i| {
        var bad = hello;
        bad[i] ^= 0x10;
        if (decompressAll(&bad)) |out| {
            testing.allocator.free(out);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

/// Long runs, text and noise, in three blocks of `bzip2 -1` (testdata/mixed.bz2).
fn mixed(out: []u8) void {
    var x: u64 = 0x9e3779b97f4a7c15;
    for (out, 0..) |*b, i| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        b.* = switch ((i / 1000) % 3) {
            0 => 'a',
            1 => 0x20 + @as(u8, @truncate(x & 0x3f)),
            else => @truncate(x),
        };
    }
}

test "blocks with runs, text and noise decode" {
    const want = try testing.allocator.alloc(u8, 300000);
    defer testing.allocator.free(want);
    mixed(want);
    const got = try decompressAll(@embedFile("testdata/mixed.bz2"));
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
}
