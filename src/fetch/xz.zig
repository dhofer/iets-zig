//! A streaming, multi-stream xz decompressor. std.compress.xz decodes each block whole into
//! memory and checks no block's CRC; a channel's `nixexprs.tar.xz` is one
//! block of a quarter gigabyte, so this decodes through a dictionary of the
//! size the stream declares and hands its bytes on as they come. Every block's
//! check (CRC32, CRC64 or SHA-256), the index and the footer are verified,
//! streams follow one another with their padding, and LZMA2 is the one filter,
//! as xz writes it for a tarball.
//!
//! The LZMA2 and LZMA decoding follows xz-embedded (xz_dec_lzma2.c), which
//! is public domain: a chunk's compressed bytes are read whole (64 KiB at
//! most) and the range decoder runs over them in memory.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.@"CRC-32/ISO-HDLC";
const Crc64 = std.hash.crc.@"CRC-64/XZ";
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    CorruptInput,
    WrongChecksum,
    /// A filter other than LZMA2, or a check xz does not define.
    Unsupported,
    /// A dictionary past `max_dict`.
    DictTooLarge,
} || Reader.Error || Allocator.Error;

const magic = [6]u8{ 0xfd, '7', 'z', 'X', 'Z', 0 };
const footer_magic = "YZ";
/// lzma_rust2's default memory limit lets any dictionary xz can write; this
/// is xz's largest preset dictionary times sixteen.
const max_dict: u32 = 1 << 30;

const Check = enum(u4) {
    none = 0,
    crc32 = 1,
    crc64 = 4,
    sha256 = 10,
    _,

    fn size(c: Check) usize {
        return switch (c) {
            .none => 0,
            .crc32 => 4,
            .crc64 => 8,
            .sha256 => 32,
            _ => 0,
        };
    }
};

const Hasher = union(Check) {
    none,
    crc32: Crc32,
    crc64: Crc64,
    sha256: Sha256,

    fn init(c: Check) Hasher {
        return switch (c) {
            .none => .none,
            .crc32 => .{ .crc32 = .init() },
            .crc64 => .{ .crc64 = .init() },
            .sha256 => .{ .sha256 = .init(.{}) },
            _ => unreachable,
        };
    }

    fn update(h: *Hasher, b: []const u8) void {
        switch (h.*) {
            .none => {},
            .crc32 => |*x| x.update(b),
            .crc64 => |*x| x.update(b),
            .sha256 => |*x| x.update(b),
        }
    }

    fn matches(h: *Hasher, want: []const u8) bool {
        var buf: [32]u8 = undefined;
        const got: []const u8 = switch (h.*) {
            .none => return true,
            .crc32 => |*x| blk: {
                std.mem.writeInt(u32, buf[0..4], x.final(), .little);
                break :blk buf[0..4];
            },
            .crc64 => |*x| blk: {
                std.mem.writeInt(u64, buf[0..8], x.final(), .little);
                break :blk buf[0..8];
            },
            .sha256 => |*x| blk: {
                x.final(buf[0..32]);
                break :blk buf[0..32];
            },
        };
        return std.mem.eql(u8, got, want);
    }
};

/// The LZ window: decoded bytes, a circle of `size`. `start` is the first
/// byte not yet handed on; `full` how much of the circle holds history.
const Dict = struct {
    buf: []u8 = &.{},
    size: usize = 0,
    pos: usize = 0,
    start: usize = 0,
    full: usize = 0,
    limit: usize = 0,

    fn reset(d: *Dict) void {
        d.pos = 0;
        d.start = 0;
        d.full = 0;
    }

    fn hasSpace(d: *const Dict) bool {
        return d.pos < d.limit;
    }

    fn get(d: *const Dict, dist: usize) u8 {
        const off = if (dist >= d.pos) d.size else 0;
        return d.buf[d.pos +% off -% dist -% 1];
    }

    fn put(d: *Dict, b: u8) void {
        d.buf[d.pos] = b;
        d.pos += 1;
        if (d.full < d.pos) d.full = d.pos;
    }

    /// Repeats `len.*` bytes from `dist` back, as many as fit before `limit`;
    /// what does not fit stays in `len`. False for a distance the window
    /// does not hold.
    fn repeat(d: *Dict, len: *u32, dist: usize) bool {
        if (dist >= d.full or dist >= d.size) return false;
        const left: usize = @min(d.limit - d.pos, len.*);
        len.* -= @intCast(left);
        var back = if (dist >= d.pos) d.pos + d.size - dist - 1 else d.pos - dist - 1;
        if (back < d.pos and back + left <= d.pos) {
            // behind the write position, not overlapping it
            @memcpy(d.buf[d.pos..][0..left], d.buf[back..][0..left]);
            d.pos += left;
        } else {
            for (0..left) |_| {
                d.buf[d.pos] = d.buf[back];
                d.pos += 1;
                back += 1;
                if (back == d.size) back = 0;
            }
        }
        if (d.full < d.pos) d.full = d.pos;
        return true;
    }
};

/// The range decoder over one chunk's compressed bytes.
const Rc = struct {
    in: []const u8 = &.{},
    i: usize = 0,
    range: u32 = 0,
    code: u32 = 0,
    overrun: bool = false,

    fn init(in: []const u8) Error!Rc {
        if (in.len < 5 or in[0] != 0) return error.CorruptInput;
        return .{ .in = in, .i = 5, .range = 0xffffffff, .code = std.mem.readInt(u32, in[1..5], .big) };
    }

    inline fn byte(rc: *Rc) u8 {
        if (rc.i >= rc.in.len) {
            rc.overrun = true;
            return 0;
        }
        const b = rc.in[rc.i];
        rc.i += 1;
        return b;
    }

    inline fn normalize(rc: *Rc) void {
        if (rc.range < (1 << 24)) {
            rc.range <<= 8;
            rc.code = (rc.code << 8) | rc.byte();
        }
    }

    inline fn bit(rc: *Rc, prob: *u16) u1 {
        rc.normalize();
        const bound = (rc.range >> 11) * prob.*;
        if (rc.code < bound) {
            rc.range = bound;
            prob.* += (2048 - prob.*) >> 5;
            return 0;
        }
        rc.range -= bound;
        rc.code -= bound;
        prob.* -= prob.* >> 5;
        return 1;
    }

    inline fn tree(rc: *Rc, probs: []u16, limit: u32) u32 {
        var sym: u32 = 1;
        while (sym < limit) sym = (sym << 1) | rc.bit(&probs[sym]);
        return sym - limit;
    }

    /// A reverse bit tree whose node `sym` (from 1) is `probs[sym - 1]`.
    inline fn reverse(rc: *Rc, probs: []u16, bits: u5, dest: *u32) void {
        var sym: u32 = 1;
        var i: u5 = 0;
        while (i < bits) : (i += 1) {
            if (rc.bit(&probs[sym - 1]) == 1) {
                sym = (sym << 1) + 1;
                dest.* += @as(u32, 1) << i;
            } else sym <<= 1;
        }
    }

    inline fn direct(rc: *Rc, dest: *u32, count: u32) void {
        var n = count;
        while (n > 0) : (n -= 1) {
            rc.normalize();
            rc.range >>= 1;
            rc.code -%= rc.range;
            const mask: u32 = 0 -% (rc.code >> 31);
            rc.code +%= rc.range & mask;
            dest.* = (dest.* << 1) +% (mask +% 1);
        }
    }

    fn finished(rc: *const Rc) bool {
        return rc.code == 0 and rc.i == rc.in.len and !rc.overrun;
    }
};

const states = 12;
const pos_states_max = 1 << 4;
const literal_coder_size = 0x300;
const match_len_max = 273;

const LenDec = struct {
    choice: u16,
    choice2: u16,
    low: [pos_states_max][8]u16,
    mid: [pos_states_max][8]u16,
    high: [256]u16,

    fn decode(l: *LenDec, rc: *Rc, pos_state: usize) u32 {
        if (rc.bit(&l.choice) == 0) return 2 + rc.tree(&l.low[pos_state], 8);
        if (rc.bit(&l.choice2) == 0) return 2 + 8 + rc.tree(&l.mid[pos_state], 8);
        return 2 + 8 + 8 + rc.tree(&l.high, 256);
    }
};

const Lzma = struct {
    state: u8 = 0,
    rep0: u32 = 0,
    rep1: u32 = 0,
    rep2: u32 = 0,
    rep3: u32 = 0,
    /// A match's bytes that did not fit before the limit.
    len: u32 = 0,
    lc: u4 = 0,
    lp: u3 = 0,
    pb: u3 = 0,
    is_match: [states][pos_states_max]u16 = undefined,
    is_rep: [states]u16 = undefined,
    is_rep0: [states]u16 = undefined,
    is_rep1: [states]u16 = undefined,
    is_rep2: [states]u16 = undefined,
    is_rep0_long: [states][pos_states_max]u16 = undefined,
    dist_slot: [4][64]u16 = undefined,
    dist_special: [114]u16 = undefined,
    dist_align: [16]u16 = undefined,
    match_len: LenDec = undefined,
    rep_len: LenDec = undefined,
    literal: [16 * literal_coder_size]u16 = undefined,

    fn reset(l: *Lzma) void {
        l.state = 0;
        l.rep0 = 0;
        l.rep1 = 0;
        l.rep2 = 0;
        l.rep3 = 0;
        l.len = 0;
        // every probability starts at one half
        inline for (.{ "is_match", "is_rep", "is_rep0", "is_rep1", "is_rep2", "is_rep0_long", "dist_slot", "dist_special", "dist_align", "match_len", "rep_len", "literal" }) |f| {
            const p = &@field(l, f);
            const words: []u16 = @as([*]u16, @ptrCast(p))[0 .. @sizeOf(@TypeOf(p.*)) / 2];
            @memset(words, 1024);
        }
    }

    fn props(l: *Lzma, b_in: u8) Error!void {
        var b = b_in;
        if (b > (4 * 5 + 4) * 9 + 8) return error.CorruptInput;
        l.pb = @intCast(b / 45);
        b %= 45;
        l.lp = @intCast(b / 9);
        l.lc = @intCast(b % 9);
        if (@as(u8, l.lc) + l.lp > 4) return error.CorruptInput;
    }

    fn literalState(l: *Lzma) void {
        l.state = if (l.state < 4) 0 else if (l.state < 10) l.state - 3 else l.state - 6;
    }

    /// Decodes until the dictionary reaches its limit or the chunk runs out.
    fn run(l: *Lzma, rc: *Rc, d: *Dict) Error!void {
        if (l.len > 0 and !d.repeat(&l.len, l.rep0)) return error.CorruptInput;
        const pb_mask: usize = (@as(usize, 1) << l.pb) - 1;
        const lp_mask: usize = (@as(usize, 1) << l.lp) - 1;
        while (d.hasSpace() and !rc.overrun) {
            const pos_state = d.pos & pb_mask;
            if (rc.bit(&l.is_match[l.state][pos_state]) == 0) {
                const prev: usize = if (d.full > 0) d.get(0) else 0;
                const low = ((d.pos & lp_mask) << l.lc) + (prev >> @intCast(8 - @as(u4, l.lc)));
                const probs = l.literal[literal_coder_size * low ..][0..literal_coder_size];
                var sym: u32 = 1;
                if (l.state < 7) {
                    while (sym < 0x100) sym = (sym << 1) | rc.bit(&probs[sym]);
                } else {
                    var match_byte: u32 = d.get(l.rep0);
                    var offset: u32 = 0x100;
                    while (sym < 0x100) {
                        match_byte <<= 1;
                        const match_bit = match_byte & offset;
                        if (rc.bit(&probs[offset + match_bit + sym]) == 1) {
                            sym = (sym << 1) + 1;
                            offset &= match_bit;
                        } else {
                            sym <<= 1;
                            offset &= ~match_bit;
                        }
                    }
                }
                d.put(@truncate(sym));
                l.literalState();
                continue;
            }
            if (rc.bit(&l.is_rep[l.state]) == 0) {
                l.state = if (l.state < 7) 7 else 10;
                l.rep3 = l.rep2;
                l.rep2 = l.rep1;
                l.rep1 = l.rep0;
                l.len = l.match_len.decode(rc, pos_state);
                const dist_state = @min(l.len - 2, 3);
                const slot = rc.tree(&l.dist_slot[dist_state], 64);
                if (slot < 4) {
                    l.rep0 = slot;
                } else {
                    const limit: u5 = @intCast((slot >> 1) - 1);
                    l.rep0 = 2 | (slot & 1);
                    if (slot < 14) {
                        l.rep0 <<= limit;
                        rc.reverse(l.dist_special[l.rep0 - slot ..], limit, &l.rep0);
                    } else {
                        // the direct bits shift in below the two top bits
                        rc.direct(&l.rep0, limit - 4);
                        l.rep0 <<= 4;
                        rc.reverse(l.dist_align[1..], 4, &l.rep0);
                    }
                }
            } else {
                if (rc.bit(&l.is_rep0[l.state]) == 0) {
                    if (rc.bit(&l.is_rep0_long[l.state][pos_state]) == 0) {
                        l.state = if (l.state < 7) 9 else 11;
                        l.len = 1;
                        if (!d.repeat(&l.len, l.rep0)) return error.CorruptInput;
                        continue;
                    }
                } else {
                    var tmp: u32 = undefined;
                    if (rc.bit(&l.is_rep1[l.state]) == 0) {
                        tmp = l.rep1;
                    } else {
                        if (rc.bit(&l.is_rep2[l.state]) == 0) {
                            tmp = l.rep2;
                        } else {
                            tmp = l.rep3;
                            l.rep3 = l.rep2;
                        }
                        l.rep2 = l.rep1;
                    }
                    l.rep1 = l.rep0;
                    l.rep0 = tmp;
                }
                l.state = if (l.state < 7) 8 else 11;
                l.len = l.rep_len.decode(rc, pos_state);
            }
            if (!d.repeat(&l.len, l.rep0)) return error.CorruptInput;
        }
        // the decoder rests normalized, so the end of a chunk is where its
        // last byte was read
        rc.normalize();
    }
};

/// An xz stream (or several) undone, as a `Reader`.
pub const Decompress = struct {
    input: *Reader,
    gpa: Allocator,
    reader: Reader,
    err: ?Error = null,

    dict: Dict = .{},
    lzma: *Lzma,
    chunk: [64 << 10]u8 = undefined,
    rc: Rc = .{},
    flags: [2]u8 = undefined,
    check: Check = .none,
    hasher: Hasher = .none,
    /// Records of the stream's blocks, for the index: unpadded and
    /// uncompressed size.
    records: std.ArrayList([2]u64) = .empty,
    /// The block being read: its header's size and the sizes it declares,
    /// and what has come of it so far.
    block_header: u64 = 0,
    block_packed: ?u64 = null,
    block_unpacked: ?u64 = null,
    packed_in: u64 = 0,
    unpacked_out: u64 = 0,
    /// LZMA2's state between chunks.
    need_dict_reset: bool = true,
    need_props: bool = true,
    left: u32 = 0,
    seq: enum { stream_header, block_or_index, control, copy, lzma, block_end, stream_padding, done } = .stream_header,

    pub fn init(input: *Reader, gpa: Allocator, buffer: []u8) Allocator.Error!Decompress {
        const l = try gpa.create(Lzma);
        l.* = .{};
        return .{
            .input = input,
            .gpa = gpa,
            .lzma = l,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    pub fn deinit(x: *Decompress) void {
        x.gpa.free(x.dict.buf);
        x.gpa.destroy(x.lzma);
        x.records.deinit(x.gpa);
    }

    fn stream(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        const x: *Decompress = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = x.fill(dest) catch |e| {
            x.err = e;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }

    fn take(x: *Decompress, n: usize) Error![]u8 {
        return x.input.take(n) catch |e| switch (e) {
            error.EndOfStream => error.CorruptInput,
            else => |y| y,
        };
    }

    fn takeByte(x: *Decompress) Error!u8 {
        return (try x.take(1))[0];
    }

    /// Hands on what the dictionary holds past `start`.
    fn flush(x: *Decompress, out: []u8) usize {
        const d = &x.dict;
        const n = @min(d.pos - d.start, out.len);
        @memcpy(out[0..n], d.buf[d.start..][0..n]);
        x.hasher.update(d.buf[d.start..][0..n]);
        d.start += n;
        x.unpacked_out += n;
        if (d.start == d.size and d.pos == d.size) {
            d.pos = 0;
            d.start = 0;
        }
        return n;
    }

    fn fill(x: *Decompress, out: []u8) Error!usize {
        var o: usize = 0;
        while (o < out.len) {
            if (x.dict.start < x.dict.pos) {
                o += x.flush(out[o..]);
                continue;
            }
            switch (x.seq) {
                .done => break,
                .stream_header => try x.streamHeader(),
                .block_or_index => try x.blockOrIndex(),
                .control => try x.control(),
                .copy => {
                    // an uncompressed chunk, through the dictionary
                    const d = &x.dict;
                    if (d.pos == d.size) {
                        d.pos = 0;
                        d.start = 0;
                    }
                    const n = @min(x.left, d.size - d.pos);
                    const src = try x.take(n);
                    @memcpy(d.buf[d.pos..][0..n], src);
                    d.pos += n;
                    if (d.full < d.pos) d.full = d.pos;
                    x.left -= @intCast(n);
                    x.packed_in += n;
                    if (x.left == 0) x.seq = .control;
                },
                .lzma => {
                    const d = &x.dict;
                    if (d.pos == d.size) {
                        d.pos = 0;
                        d.start = 0;
                    }
                    d.limit = d.pos + @min(x.left, d.size - d.pos);
                    const before = d.pos;
                    try x.lzma.run(&x.rc, d);
                    if (x.rc.overrun) return error.CorruptInput;
                    x.left -= @intCast(d.pos - before);
                    if (x.left == 0) {
                        if (x.lzma.len != 0 or !x.rc.finished()) return error.CorruptInput;
                        x.seq = .control;
                    }
                },
                .block_end => try x.blockEnd(),
                .stream_padding => try x.streamPadding(),
            }
        }
        return o;
    }

    fn streamHeader(x: *Decompress) Error!void {
        const h = try x.take(12);
        if (!std.mem.eql(u8, h[0..6], &magic)) return error.CorruptInput;
        if (Crc32.hash(h[6..8]) != std.mem.readInt(u32, h[8..12], .little)) return error.WrongChecksum;
        if (h[6] != 0 or h[7] & 0xf0 != 0) return error.Unsupported;
        x.flags = h[6..8].*;
        x.check = @fromBackingInt(@intCast(@as(u4, @truncate(h[7]))));
        if (x.check.size() == 0 and x.check != .none) return error.Unsupported;
        x.records.clearRetainingCapacity();
        x.seq = .block_or_index;
    }

    fn blockOrIndex(x: *Decompress) Error!void {
        const size_byte = (try x.input.peek(1))[0];
        if (size_byte == 0) return x.index();
        const size: usize = (@as(usize, size_byte) + 1) * 4;
        const h = try x.take(size);
        if (Crc32.hash(h[0 .. size - 4]) != std.mem.readInt(u32, h[size - 4 ..][0..4], .little)) return error.WrongChecksum;
        const flags = h[1];
        if (flags & 0x3c != 0) return error.Unsupported;
        if (flags & 0x03 != 0) return error.Unsupported; // one filter: LZMA2
        var at: usize = 2;
        x.block_packed = if (flags & 0x40 != 0) try varint(h, &at, size - 4) else null;
        x.block_unpacked = if (flags & 0x80 != 0) try varint(h, &at, size - 4) else null;
        if (try varint(h, &at, size - 4) != 0x21) return error.Unsupported;
        if (try varint(h, &at, size - 4) != 1) return error.Unsupported;
        if (at >= size - 4) return error.CorruptInput;
        const dict_bits = h[at];
        at += 1;
        if (dict_bits > 40) return error.CorruptInput;
        for (h[at .. size - 4]) |b| if (b != 0) return error.CorruptInput;
        const dict_size: u64 = if (dict_bits == 40) 0xffffffff else (@as(u64, 2) | (dict_bits & 1)) << @intCast(dict_bits / 2 + 11);
        if (dict_size > max_dict) return error.DictTooLarge;
        const want: usize = @intCast(@max(dict_size, 4096));
        if (x.dict.buf.len < want) {
            x.gpa.free(x.dict.buf);
            x.dict.buf = &.{};
            x.dict.buf = try x.gpa.alloc(u8, want);
        }
        x.dict.size = want;
        x.dict.reset();
        x.block_header = size;
        x.packed_in = 0;
        x.unpacked_out = 0;
        x.hasher = .init(x.check);
        x.need_dict_reset = true;
        x.need_props = true;
        x.seq = .control;
    }

    /// The next LZMA2 chunk's header (xz_dec_lzma2_run).
    fn control(x: *Decompress) Error!void {
        const c = try x.takeByte();
        x.packed_in += 1;
        if (c == 0) {
            x.seq = .block_end;
            return;
        }
        if (c >= 0xe0 or c == 0x01) {
            x.need_props = true;
            x.need_dict_reset = false;
            x.dict.reset();
        } else if (x.need_dict_reset) return error.CorruptInput;
        if (c >= 0x80) {
            const sizes = try x.take(4);
            x.packed_in += 4;
            x.left = ((@as(u32, c) & 0x1f) << 16) + std.mem.readInt(u16, sizes[0..2], .big) + 1;
            const packed_len: usize = @as(usize, std.mem.readInt(u16, sizes[2..4], .big)) + 1;
            if (c >= 0xc0) {
                x.need_props = false;
                try x.lzma.props(try x.takeByte());
                x.packed_in += 1;
                x.lzma.reset();
            } else if (x.need_props) {
                return error.CorruptInput;
            } else if (c >= 0xa0) x.lzma.reset();
            const in = try x.take(packed_len);
            @memcpy(x.chunk[0..packed_len], in);
            x.packed_in += packed_len;
            x.rc = try .init(x.chunk[0..packed_len]);
            x.seq = .lzma;
            return;
        }
        if (c > 0x02) return error.CorruptInput;
        const sizes = try x.take(2);
        x.packed_in += 2;
        x.left = @as(u32, std.mem.readInt(u16, sizes[0..2], .big)) + 1;
        x.seq = .copy;
    }

    fn blockEnd(x: *Decompress) Error!void {
        if (x.block_packed) |p| if (p != x.packed_in) return error.CorruptInput;
        if (x.block_unpacked) |u| if (u != x.unpacked_out) return error.CorruptInput;
        const unpadded = x.block_header + x.packed_in + x.check.size();
        const pad = (4 - (x.block_header + x.packed_in) % 4) % 4;
        for (try x.take(@intCast(pad))) |b| if (b != 0) return error.CorruptInput;
        const want = try x.take(x.check.size());
        if (!x.hasher.matches(want)) return error.WrongChecksum;
        try x.records.append(x.gpa, .{ unpadded, x.unpacked_out });
        x.seq = .block_or_index;
    }

    /// The index after the blocks, and the stream footer.
    fn index(x: *Decompress) Error!void {
        var crc: Crc32 = .init();
        var n: u64 = 0;
        const zero = try x.take(1);
        crc.update(zero);
        n += 1;
        const count = try x.indexVarint(&crc, &n);
        if (count != x.records.items.len) return error.CorruptInput;
        for (x.records.items) |rec| {
            if (try x.indexVarint(&crc, &n) != rec[0]) return error.CorruptInput;
            if (try x.indexVarint(&crc, &n) != rec[1]) return error.CorruptInput;
        }
        const pad = (4 - n % 4) % 4;
        const p = try x.take(@intCast(pad));
        for (p) |b| if (b != 0) return error.CorruptInput;
        crc.update(p);
        n += pad;
        if (crc.final() != std.mem.readInt(u32, (try x.take(4))[0..4], .little)) return error.WrongChecksum;
        n += 4;
        const f = try x.take(12);
        if (Crc32.hash(f[4..10]) != std.mem.readInt(u32, f[0..4], .little)) return error.WrongChecksum;
        if ((@as(u64, std.mem.readInt(u32, f[4..8], .little)) + 1) * 4 != n) return error.CorruptInput;
        if (!std.mem.eql(u8, f[8..10], &x.flags) or !std.mem.eql(u8, f[10..12], footer_magic)) return error.CorruptInput;
        x.seq = .stream_padding;
    }

    fn indexVarint(x: *Decompress, crc: *Crc32, n: *u64) Error!u64 {
        var v: u64 = 0;
        var i: u6 = 0;
        while (true) : (i += 7) {
            const b = try x.takeByte();
            crc.update(&.{b});
            n.* += 1;
            if (i > 56 or (b == 0 and i > 0)) return error.CorruptInput;
            v |= @as(u64, b & 0x7f) << i;
            if (b & 0x80 == 0) return v;
        }
    }

    /// Zero bytes in fours after a stream, then another stream or the end.
    fn streamPadding(x: *Decompress) Error!void {
        var pad: usize = 0;
        while (true) {
            const b = x.input.peekByte() catch |e| switch (e) {
                error.EndOfStream => {
                    if (pad % 4 != 0) return error.CorruptInput;
                    x.seq = .done;
                    return;
                },
                else => |y| return y,
            };
            if (b != 0) break;
            x.input.toss(1);
            pad += 1;
        }
        if (pad % 4 != 0) return error.CorruptInput;
        x.seq = .stream_header;
    }
};

fn varint(h: []const u8, at: *usize, end: usize) Error!u64 {
    var v: u64 = 0;
    var i: u6 = 0;
    while (true) : (i += 7) {
        if (at.* >= end or i > 56) return error.CorruptInput;
        const b = h[at.*];
        at.* += 1;
        if (b == 0 and i > 0) return error.CorruptInput;
        v |= @as(u64, b & 0x7f) << i;
        if (b & 0x80 == 0) return v;
    }
}

const testing = std.testing;

fn decodeAll(in: []const u8) ![]u8 {
    var r: Reader = .fixed(in);
    var buf: [4096]u8 = undefined;
    var x: Decompress = try .init(&r, testing.allocator, &buf);
    defer x.deinit();
    return x.reader.allocRemaining(testing.allocator, .unlimited) catch |e| {
        if (x.err) |y| return y;
        return e;
    };
}

// printf 'hello filters\n' | xz
const hello = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04, 0xe6, 0xd6, 0xb4, 0x46, 0x04, 0xc0, 0x12, 0x0e, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9d, 0xc1, 0x66, 0xa9, 0x01, 0x00, 0x0d, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x66, 0x69, 0x6c, 0x74, 0x65, 0x72, 0x73, 0x0a, 0x00, 0x00, 0x00, 0xcc, 0x2f, 0x27, 0x5d, 0xbb, 0x03, 0xc3, 0x01, 0x00, 0x01, 0x2e, 0x0e, 0x00, 0x91, 0x39, 0xcc, 0x1f, 0xb6, 0xf3, 0x7d, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x59, 0x5a };

test "a stream decodes, and two with padding between decode to both" {
    const one = try decodeAll(&hello);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("hello filters\n", one);
    const two = try decodeAll(&hello ++ [_]u8{ 0, 0, 0, 0 } ++ hello);
    defer testing.allocator.free(two);
    try testing.expectEqualStrings("hello filters\nhello filters\n", two);
}

test "a changed byte is an error" {
    for (0..hello.len) |i| {
        var bad = hello;
        bad[i] ^= 0x01;
        if (decodeAll(&bad)) |out| {
            testing.allocator.free(out);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

/// Long runs, text and noise (as in bzip2.zig), through `xz -6`, the
/// check of each kind, and a small dictionary that wraps.
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

test "runs, text and noise decode with every check and a wrapping dictionary" {
    const want = try testing.allocator.alloc(u8, 300000);
    defer testing.allocator.free(want);
    mixed(want);
    inline for (.{ "testdata/mixed-crc64.xz", "testdata/mixed-sha256-dict4k.xz", "testdata/mixed-crc32-blocks.xz" }) |f| {
        const got = try decodeAll(@embedFile(f));
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, want, got);
    }
}
