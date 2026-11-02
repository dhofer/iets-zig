//! A streaming zstd decompressor (RFC 8878). std.compress.zstd walks the
//! Huffman tree a bit at a time for every literal and copies a match a byte
//! at a time: on a channel's `nixexprs.tar.zst` that was 1.1 s of a 1.7 s
//! cold fetch, where libzstd takes 0.12 s. This one follows libzstd's shape
//! (huf_decompress.c, zstd_decompress_block.c): a block's literals are
//! decoded up front by table lookup over the four streams interleaved, and
//! literals and matches are copied 16 bytes at a time into slack past the
//! block. Frames follow one another, skippable frames are skipped, and the
//! content size and the checksum a frame declares are verified.
//!
//! Runtime safety stays on in every function here, in every build mode: the
//! decoder runs on downloaded bytes before the lock's hash can check them, so
//! a bug in it panics on a bounds or overflow check instead of corrupting
//! memory.
//!
//! Every bitstream sits in `Work.blk` between `pad` bytes on either side, so
//! a reader loads eight bytes wherever it stands without a bounds check; a
//! stream read past its start is caught by comparing positions, not by the
//! load.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const XxHash64 = std.hash.XxHash64;
const std_zstd = std.compress.zstd;

pub const Error = error{
    CorruptInput,
    WrongChecksum,
    /// A frame that needs a dictionary.
    Unsupported,
    /// A window past `max_window`.
    WindowTooLarge,
} || Reader.Error || Allocator.Error;

/// libzstd's default `ZSTD_d_windowLogMax`.
pub const max_window: u64 = 1 << 27;

const frame_magic: u32 = 0xFD2FB528;
const block_max = std_zstd.block_size_max;
/// Bytes on either side of a bitstream: more than a reader that overran by
/// one sequence's bits (at most 89) can reach below, and an 8-byte load above.
const pad = 16;
/// Past a block's end in the history and the literal buffer: a 16-byte copy
/// may write, and read, this far beyond what it needs.
const slack = 32;
/// huf.h:HUF_TABLELOG_MAX. libzstd's encoder stops at 11, but its decoder
/// takes 12, so a stream another encoder wrote with 12 decodes for Nix.
const huf_max_bits = 12;
const huf_max_symbols = 256;

/// One entry of a decoding table, for the Huffman weights' FSE and for
/// the sequences: the symbol (or, for a sequence code, its baseline and
/// extra bits), and how the state moves on.
const Seq = struct {
    base: u32 = 0,
    add_bits: u8 = 0,
    nb: u8 = 0,
    next: u16 = 0,
};

const Huf = packed struct { sym: u8, nb: u8 };

const ll_max_log = 9;
const ml_max_log = 9;
const of_max_log = 8;
const ll_max_sym = 35;
const ml_max_sym = 52;
const of_max_sym = 31;

const ll_base = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
const ll_bits = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
const ml_base = [_]u32{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539 };
const ml_bits = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

const Kind = enum { ll, ml, of };

/// The baseline and extra bits sequence code `sym` of `kind` stands for.
fn code(kind: Kind, sym: u8) Seq {
    @setRuntimeSafety(true);
    return switch (kind) {
        .ll => .{ .base = ll_base[sym], .add_bits = ll_bits[sym] },
        .ml => .{ .base = ml_base[sym], .add_bits = ml_bits[sym] },
        .of => .{ .base = @as(u32, 1) << @intCast(sym), .add_bits = sym },
    };
}

/// Reads a bitstream backwards from its end, as zstd writes Huffman
/// literals, sequences and the Huffman weights. `pos` is the count of bits
/// still unread, counted from the start of `buf`; the stream begins at bit
/// `lo`, so `pos < lo` means it was read past its start.
const RevBits = struct {
    buf: [*]const u8,
    pos: usize,
    lo: usize,

    /// The stream `buf[from..to]`, with `pad` readable bytes on either side.
    fn init(buf: [*]const u8, from: usize, to: usize) error{CorruptInput}!RevBits {
        @setRuntimeSafety(true);
        if (to <= from) return error.CorruptInput;
        const last = buf[to - 1];
        if (last == 0) return error.CorruptInput;
        // the highest set bit of the last byte marks where the stream ends
        return .{ .buf = buf, .pos = (to - 1) * 8 + 7 - @clz(last), .lo = from * 8 };
    }

    inline fn load(b: *const RevBits, at: usize) u64 {
        @setRuntimeSafety(true);
        return std.mem.readInt(u64, b.buf[at >> 3 ..][0..8], .little) >> @intCast(at & 7);
    }

    /// The next `n` bits (at most 56), the first one read as the highest.
    inline fn read(b: *RevBits, n: u8) u64 {
        @setRuntimeSafety(true);
        b.pos -= n;
        return b.load(b.pos) & ((@as(u64, 1) << @intCast(n)) - 1);
    }

    inline fn peek(b: *const RevBits, comptime n: u8) u64 {
        @setRuntimeSafety(true);
        return b.load(b.pos - n) & ((1 << n) - 1);
    }

    fn overrun(b: *const RevBits) bool {
        @setRuntimeSafety(true);
        return b.pos < b.lo;
    }
};

/// Reads an FSE table description forwards, the low bits first.
const FwdBits = struct {
    src: []const u8,
    pos: usize = 0,

    fn peek(b: *const FwdBits, n: u5) u32 {
        @setRuntimeSafety(true);
        var v: u32 = 0;
        const at = b.pos >> 3;
        for (0..4) |i| if (at + i < b.src.len) {
            v |= @as(u32, b.src[at + i]) << @intCast(8 * i);
        };
        return (v >> @intCast(b.pos & 7)) & ((@as(u32, 1) << n) - 1);
    }

    fn take(b: *FwdBits, n: u5) u32 {
        @setRuntimeSafety(true);
        const v = b.peek(n);
        b.pos += n;
        return v;
    }
};

/// fse_decompress.c:FSE_readNCount. The normalized counts go to `norm`; the
/// result is the accuracy log and the bytes the description took.
fn readCounts(src: []const u8, norm: []i16, max_sym: usize, max_log: u5) error{CorruptInput}!struct { log: u5, used: usize, syms: usize } {
    @setRuntimeSafety(true);
    var b: FwdBits = .{ .src = src };
    const log: u5 = @intCast(b.take(4) + 5);
    if (log > max_log) return error.CorruptInput;
    var remaining: i32 = (@as(i32, 1) << log) + 1;
    var threshold: i32 = @as(i32, 1) << log;
    var nb: u5 = log + 1;
    var sym: usize = 0;
    var prev0 = false;
    while (remaining > 1 and sym <= max_sym) {
        if (prev0) {
            var n0 = sym;
            while (true) {
                const r = b.take(2);
                n0 += r;
                if (r != 3) break;
            }
            if (n0 > max_sym + 1) return error.CorruptInput;
            while (sym < n0) : (sym += 1) norm[sym] = 0;
            if (sym > max_sym) break;
        }
        const max: i32 = 2 * threshold - 1 - remaining;
        const v: i32 = @intCast(b.peek(nb));
        var count: i32 = undefined;
        if ((v & (threshold - 1)) < max) {
            count = v & (threshold - 1);
            b.pos += nb - 1;
        } else {
            count = v & (2 * threshold - 1);
            if (count >= threshold) count -= max;
            b.pos += nb;
        }
        count -= 1;
        remaining -= if (count < 0) -count else count;
        if (remaining < 1) return error.CorruptInput;
        norm[sym] = @intCast(count);
        sym += 1;
        prev0 = count == 0;
        while (remaining < threshold) {
            nb -= 1;
            threshold >>= 1;
        }
        if (b.pos > src.len * 8) return error.CorruptInput;
    }
    if (remaining != 1) return error.CorruptInput;
    const used = (b.pos + 7) / 8;
    if (used > src.len) return error.CorruptInput;
    return .{ .log = log, .used = used, .syms = sym };
}

/// fse_decompress.c:FSE_buildDTable_internal, with each symbol turned into
/// what `kind` makes of it (`null`: the symbol itself, in `base`).
fn buildTable(out: []Seq, norm: []const i16, syms: usize, log: u5, kind: ?Kind) error{CorruptInput}!void {
    @setRuntimeSafety(true);
    const size = @as(usize, 1) << log;
    var next: [256]u16 = undefined;
    var high = size - 1;
    var sym_of: [1 << ll_max_log]u8 = undefined;
    for (norm[0..syms], 0..) |n, s| {
        if (n == -1) {
            sym_of[high] = @intCast(s);
            high -%= 1;
            next[s] = 1;
        } else next[s] = @intCast(n);
    }
    const step = (size >> 1) + (size >> 3) + 3;
    const mask = size - 1;
    var p: usize = 0;
    for (norm[0..syms], 0..) |n, s| {
        if (n <= 0) continue;
        for (0..@intCast(n)) |_| {
            sym_of[p] = @intCast(s);
            p = (p + step) & mask;
            while (p > high) p = (p + step) & mask;
        }
    }
    if (p != 0) return error.CorruptInput;
    for (0..size) |u| {
        const s = sym_of[u];
        const ns = next[s];
        next[s] += 1;
        if (ns == 0) return error.CorruptInput;
        const nb: u8 = @intCast(@as(u32, log) - std.math.log2_int(u16, ns));
        var e: Seq = if (kind) |k| code(k, s) else .{ .base = s };
        e.nb = nb;
        e.next = @intCast((@as(u32, ns) << @intCast(nb)) - size);
        out[u] = e;
    }
}

/// The tables and buffers of the decoder, too big for the stack or the struct.
const Work = struct {
    blk: [pad + block_max + pad]u8 = @splat(0),
    lit: [block_max + slack]u8 = undefined,
    huf: [1 << huf_max_bits]Huf = undefined,
    huf_bits: u8 = 0,
    ll: [1 << ll_max_log]Seq = undefined,
    ml: [1 << ml_max_log]Seq = undefined,
    of: [1 << of_max_log]Seq = undefined,
    ll_def: [1 << 6]Seq = undefined,
    ml_def: [1 << 6]Seq = undefined,
    of_def: [1 << 5]Seq = undefined,
    ll_rle: [1]Seq = undefined,
    ml_rle: [1]Seq = undefined,
    of_rle: [1]Seq = undefined,

    fn init(w: *Work) void {
        @setRuntimeSafety(true);
        w.* = .{};
        buildTable(&w.ll_def, &std_zstd.literals_length_default_distribution, ll_max_sym + 1, 6, .ll) catch unreachable;
        buildTable(&w.ml_def, &std_zstd.match_lengths_default_distribution, ml_max_sym + 1, 6, .ml) catch unreachable;
        buildTable(&w.of_def, &std_zstd.offset_codes_default_distribution, 29, 5, .of) catch unreachable;
    }
};

/// One sequence table in use: its entries and accuracy log.
const Table = struct {
    t: []const Seq = &.{},
    log: u5 = 0,
};

/// A zstd stream (or several frames) undone, as a `Reader`.
pub const Decompress = struct {
    input: *Reader,
    gpa: Allocator,
    reader: Reader,
    err: ?Error = null,
    work: *Work,

    /// The history: the window behind `pos`, and the decoded bytes from
    /// `start` to `pos` not yet handed on.
    hist: []u8 = &.{},
    pos: usize = 0,
    start: usize = 0,
    seq: enum { frame, block, done } = .frame,
    frames: usize = 0,

    // the frame being read
    window: usize = 0,
    block_limit: usize = 0,
    content_size: ?u64 = null,
    produced: u64 = 0,
    checksum: ?XxHash64 = null,
    rep: [3]u32 = .{ 1, 4, 8 },
    huf_ok: bool = false,
    ll: Table = .{},
    ml: Table = .{},
    of: Table = .{},

    pub fn init(input: *Reader, gpa: Allocator, buffer: []u8) Allocator.Error!Decompress {
        @setRuntimeSafety(true);
        const w = try gpa.create(Work);
        w.init();
        return .{
            .input = input,
            .gpa = gpa,
            .work = w,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    pub fn deinit(x: *Decompress) void {
        @setRuntimeSafety(true);
        x.gpa.free(x.hist);
        x.gpa.destroy(x.work);
    }

    fn stream(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        @setRuntimeSafety(true);
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

    fn fill(x: *Decompress, out: []u8) Error!usize {
        @setRuntimeSafety(true);
        var o: usize = 0;
        while (o < out.len) {
            if (x.start < x.pos) {
                const n = @min(x.pos - x.start, out.len - o);
                @memcpy(out[o..][0..n], x.hist[x.start..][0..n]);
                x.start += n;
                o += n;
                continue;
            }
            switch (x.seq) {
                .done => break,
                .frame => try x.frameHeader(),
                .block => try x.block(),
            }
        }
        return o;
    }

    fn take(x: *Decompress, comptime n: usize) Error!*[n]u8 {
        @setRuntimeSafety(true);
        return x.input.takeArray(n) catch |e| switch (e) {
            error.EndOfStream => error.CorruptInput,
            else => |y| y,
        };
    }

    fn readAll(x: *Decompress, dest: []u8) Error!void {
        @setRuntimeSafety(true);
        x.input.readSliceAll(dest) catch |e| switch (e) {
            error.EndOfStream => return error.CorruptInput,
            else => |y| return y,
        };
    }

    fn frameHeader(x: *Decompress) Error!void {
        @setRuntimeSafety(true);
        // the end of the input between frames is the end of the stream
        _ = x.input.peekByte() catch |e| switch (e) {
            error.EndOfStream => {
                if (x.frames == 0) return error.CorruptInput;
                x.seq = .done;
                return;
            },
            else => |y| return y,
        };
        const magic = std.mem.readInt(u32, try x.take(4), .little);
        if (magic & 0xFFFFFFF0 == 0x184D2A50) {
            const size = std.mem.readInt(u32, try x.take(4), .little);
            x.input.discardAll(size) catch |e| switch (e) {
                error.EndOfStream => return error.CorruptInput,
                else => |y| return y,
            };
            return;
        }
        if (magic != frame_magic) return error.CorruptInput;
        const fhd = (try x.take(1))[0];
        if (fhd & 0x08 != 0) return error.CorruptInput;
        const single = fhd & 0x20 != 0;
        var window: u64 = 0;
        if (!single) {
            const wd = (try x.take(1))[0];
            const base = @as(u64, 1) << @intCast(10 + (wd >> 3));
            window = base + (base / 8) * (wd & 7);
        }
        const dict_lens = [_]u8{ 0, 1, 2, 4 };
        const dict_len = dict_lens[fhd & 3];
        var dict: u32 = 0;
        for (0..dict_len) |i| dict |= @as(u32, (try x.take(1))[0]) << @intCast(8 * i);
        if (dict != 0) return error.Unsupported;
        const fcs_len: u8 = switch (fhd >> 6) {
            0 => if (single) 1 else 0,
            1 => 2,
            2 => 4,
            else => 8,
        };
        x.content_size = null;
        if (fcs_len > 0) {
            var v: u64 = 0;
            for (0..fcs_len) |i| v |= @as(u64, (try x.take(1))[0]) << @intCast(8 * i);
            if (fcs_len == 2) v += 256;
            x.content_size = v;
        }
        if (single) window = x.content_size.?;
        if (window > max_window) return error.WindowTooLarge;
        x.window = @intCast(window);
        x.block_limit = @min(x.window, block_max);
        // twice the window, so the history moves once per window of output;
        // a single segment holds the whole frame and never moves
        const cap = (if (single) x.window else 2 * @max(x.window, block_max)) + block_max + slack;
        if (x.hist.len < cap) {
            x.gpa.free(x.hist);
            x.hist = &.{};
            x.hist = try x.gpa.alloc(u8, cap);
        }
        // everything decoded has been handed on, and no match reaches back
        // into another frame
        x.pos = 0;
        x.start = 0;
        x.produced = 0;
        x.checksum = if (fhd & 0x04 != 0) XxHash64.init(0) else null;
        x.rep = .{ 1, 4, 8 };
        x.huf_ok = false;
        x.ll = .{};
        x.ml = .{};
        x.of = .{};
        x.frames += 1;
        x.seq = .block;
    }

    fn block(x: *Decompress) Error!void {
        @setRuntimeSafety(true);
        // everything decoded has been handed on; keep the window and make
        // room for a block past it
        if (x.pos + block_max + slack > x.hist.len) {
            const keep = @min(x.pos, x.window);
            @memmove(x.hist[0..keep], x.hist[x.pos - keep .. x.pos]);
            x.pos = keep;
            x.start = keep;
        }
        const h = std.mem.readInt(u24, try x.take(3), .little);
        const last = h & 1 != 0;
        const size: usize = h >> 3;
        const at = x.pos;
        switch ((h >> 1) & 3) {
            0 => {
                if (size > x.block_limit) return error.CorruptInput;
                try x.readAll(x.hist[at..][0..size]);
                x.pos += size;
            },
            1 => {
                if (size > x.block_limit) return error.CorruptInput;
                const b = (try x.take(1))[0];
                @memset(x.hist[at..][0..size], b);
                x.pos += size;
            },
            2 => {
                if (size > x.block_limit) return error.CorruptInput;
                const blk = &x.work.blk;
                try x.readAll(blk[pad..][0..size]);
                @memset(blk[pad + size ..][0..pad], 0);
                x.pos += try x.compressed(pad, pad + size);
            },
            else => return error.CorruptInput,
        }
        x.produced += x.pos - at;
        if (x.checksum) |*c| c.update(x.hist[at..x.pos]);
        if (!last) return;
        if (x.content_size) |cs| if (cs != x.produced) return error.CorruptInput;
        if (x.checksum) |*c| {
            const want = std.mem.readInt(u32, try x.take(4), .little);
            if (@as(u32, @truncate(c.final())) != want) return error.WrongChecksum;
        }
        x.seq = .frame;
    }

    /// Decodes the compressed block `blk[from..to]` into the history at
    /// `pos`; the result is its size.
    fn compressed(x: *Decompress, from: usize, to: usize) Error!usize {
        @setRuntimeSafety(true);
        const w = x.work;
        const src = w.blk[0..to];
        var i = from;
        // the literals section
        const b0 = src[i];
        const lit_type = b0 & 3;
        const sf = (b0 >> 2) & 3;
        // the literals, with `slack` readable bytes past `nlits`
        var lits: []const u8 = undefined;
        var nlits: usize = undefined;
        if (lit_type < 2) {
            var regen: usize = undefined;
            var hdr: usize = undefined;
            switch (sf) {
                0, 2 => {
                    regen = b0 >> 3;
                    hdr = 1;
                },
                1 => {
                    if (i + 2 > to) return error.CorruptInput;
                    regen = (b0 >> 4) + (@as(usize, src[i + 1]) << 4);
                    hdr = 2;
                },
                else => {
                    if (i + 3 > to) return error.CorruptInput;
                    regen = (b0 >> 4) + (@as(usize, src[i + 1]) << 4) + (@as(usize, src[i + 2]) << 12);
                    hdr = 3;
                },
            }
            if (regen > x.block_limit) return error.CorruptInput;
            i += hdr;
            if (lit_type == 0) {
                if (i + regen > to) return error.CorruptInput;
                lits = w.blk[i..];
                i += regen;
            } else {
                if (i + 1 > to) return error.CorruptInput;
                @memset(w.lit[0..regen], src[i]);
                lits = &w.lit;
                i += 1;
            }
            nlits = regen;
        } else {
            const hdr: usize = switch (sf) {
                0, 1 => 3,
                2 => 4,
                else => 5,
            };
            if (i + hdr > to) return error.CorruptInput;
            var hv: u64 = 0;
            for (0..hdr) |k| hv |= @as(u64, src[i + k]) << @intCast(8 * k);
            const field: u6 = switch (sf) {
                0, 1 => 10,
                2 => 14,
                else => 18,
            };
            const mask = (@as(u64, 1) << field) - 1;
            const regen: usize = @intCast((hv >> 4) & mask);
            const csize: usize = @intCast((hv >> (4 + field)) & mask);
            if (regen > x.block_limit) return error.CorruptInput;
            i += hdr;
            if (i + csize > to) return error.CorruptInput;
            var s = i;
            const end = i + csize;
            if (lit_type == 2) {
                s += try x.hufTable(s, end);
                x.huf_ok = true;
            } else if (!x.huf_ok) return error.CorruptInput;
            if (sf == 0) {
                try x.hufStream(w.lit[0..regen], s, end);
            } else {
                try x.hufStreams(w.lit[0..regen], s, end);
            }
            lits = &w.lit;
            nlits = regen;
            i = end;
        }

        // the sequences section
        if (i >= to) return error.CorruptInput;
        var nseq: usize = src[i];
        i += 1;
        if (nseq >= 128) {
            if (nseq == 255) {
                if (i + 2 > to) return error.CorruptInput;
                nseq = @as(usize, src[i]) + (@as(usize, src[i + 1]) << 8) + 0x7F00;
                i += 2;
            } else {
                if (i + 1 > to) return error.CorruptInput;
                nseq = ((nseq - 128) << 8) + src[i];
                i += 1;
            }
        }
        const out = x.hist[x.pos..];
        if (nseq == 0) {
            if (i != to) return error.CorruptInput;
            @memcpy(out[0..nlits], lits[0..nlits]);
            return nlits;
        }
        if (i >= to) return error.CorruptInput;
        const modes = src[i];
        i += 1;
        if (modes & 3 != 0) return error.CorruptInput;
        i += try x.seqTable(&x.ll, .ll, modes >> 6, src[i..to]);
        i += try x.seqTable(&x.of, .of, (modes >> 4) & 3, src[i..to]);
        i += try x.seqTable(&x.ml, .ml, (modes >> 2) & 3, src[i..to]);
        return x.sequences(lits, nlits, nseq, i, to);
    }

    /// huf_decompress.c:HUF_readStats and HUF_readDTableX1: the Huffman
    /// table described at `blk[from..to]`; the result is the bytes it took.
    fn hufTable(x: *Decompress, from: usize, to: usize) Error!usize {
        @setRuntimeSafety(true);
        const w = x.work;
        const src = w.blk[0..to];
        if (from >= to) return error.CorruptInput;
        const hb = src[from];
        var weights: [huf_max_symbols]u8 = undefined;
        var n: usize = 0;
        var used: usize = undefined;
        if (hb >= 128) {
            n = hb - 127;
            used = 1 + (n + 1) / 2;
            if (from + used > to) return error.CorruptInput;
            for (0..n) |k| {
                const byte = src[from + 1 + k / 2];
                weights[k] = if (k & 1 == 0) byte >> 4 else byte & 15;
            }
        } else {
            used = 1 + @as(usize, hb);
            if (from + used > to) return error.CorruptInput;
            var norm: [256]i16 = undefined;
            const c = try readCounts(src[from + 1 .. from + used], &norm, 255, 6);
            var t: [1 << 6]Seq = undefined;
            try buildTable(&t, &norm, c.syms, c.log, null);
            var br = try RevBits.init(src.ptr, from + 1 + c.used, from + used);
            var s1 = br.read(c.log);
            var s2 = br.read(c.log);
            // two interleaved states; the stream ends when it is read past
            // its start, and the other state gives one last weight
            while (true) {
                if (n + 2 > 255) return error.CorruptInput;
                weights[n] = @intCast(t[s1].base);
                n += 1;
                s1 = t[s1].next + br.read(t[s1].nb);
                if (br.overrun()) {
                    weights[n] = @intCast(t[s2].base);
                    n += 1;
                    break;
                }
                weights[n] = @intCast(t[s2].base);
                n += 1;
                s2 = t[s2].next + br.read(t[s2].nb);
                if (br.overrun()) {
                    weights[n] = @intCast(t[s1].base);
                    n += 1;
                    break;
                }
            }
        }
        var total: u32 = 0;
        for (weights[0..n]) |wt| {
            if (wt > huf_max_bits) return error.CorruptInput;
            if (wt > 0) total += @as(u32, 1) << @intCast(wt - 1);
        }
        if (total == 0) return error.CorruptInput;
        const max_bits = std.math.log2_int(u32, total) + 1;
        if (max_bits > huf_max_bits) return error.CorruptInput;
        // the last weight is implied: it fills the table to a power of two
        const rest = (@as(u32, 1) << @intCast(max_bits)) - total;
        if (!std.math.isPowerOfTwo(rest)) return error.CorruptInput;
        weights[n] = std.math.log2_int(u32, rest) + 1;
        n += 1;
        var count: [huf_max_bits + 2]u32 = @splat(0);
        for (weights[0..n]) |wt| count[wt] += 1;
        // HUF_readStats: the longest codes come in pairs, at least one
        if (count[1] < 2 or count[1] & 1 != 0) return error.CorruptInput;
        var start: [huf_max_bits + 2]u32 = undefined;
        var next: u32 = 0;
        for (1..max_bits + 1) |wt| {
            start[wt] = next;
            next += count[wt] << @intCast(wt - 1);
        }
        for (weights[0..n], 0..) |wt, s| {
            if (wt == 0) continue;
            const len = @as(u32, 1) << @intCast(wt - 1);
            const e: Huf = .{ .sym = @intCast(s), .nb = @intCast(max_bits + 1 - wt) };
            @memset(w.huf[start[wt]..][0..len], e);
            start[wt] += len;
        }
        w.huf_bits = @intCast(max_bits);
        return used;
    }

    fn hufStream(x: *Decompress, out: []u8, from: usize, to: usize) Error!void {
        @setRuntimeSafety(true);
        var br = try RevBits.init(&x.work.blk, from, to);
        switch (x.work.huf_bits) {
            inline 1...huf_max_bits => |mb| try hufRun(mb, &x.work.huf, &br, out),
            else => unreachable,
        }
        if (br.pos != br.lo) return error.CorruptInput;
    }

    /// Four streams behind a jump table of their sizes, interleaved.
    fn hufStreams(x: *Decompress, out: []u8, from: usize, to: usize) Error!void {
        @setRuntimeSafety(true);
        if (from + 6 > to) return error.CorruptInput;
        const blk = &x.work.blk;
        const l1: usize = std.mem.readInt(u16, blk[from..][0..2], .little);
        const l2: usize = std.mem.readInt(u16, blk[from + 2 ..][0..2], .little);
        const l3: usize = std.mem.readInt(u16, blk[from + 4 ..][0..2], .little);
        const s1 = from + 6;
        const s2 = s1 + l1;
        const s3 = s2 + l2;
        const s4 = s3 + l3;
        if (s4 >= to) return error.CorruptInput;
        // MIN_LITERALS_FOR_4_STREAMS: each stream holds at least one literal
        if (out.len < 6) return error.CorruptInput;
        const q = (out.len + 3) / 4;
        var brs = [4]RevBits{
            try .init(blk, s1, s2),
            try .init(blk, s2, s3),
            try .init(blk, s3, s4),
            try .init(blk, s4, to),
        };
        const outs = [4][]u8{ out[0..q], out[q .. 2 * q], out[2 * q .. 3 * q], out[3 * q ..] };
        switch (x.work.huf_bits) {
            inline 1...huf_max_bits => |mb| try hufRun4(mb, &x.work.huf, &brs, outs),
            else => unreachable,
        }
        for (brs) |b| if (b.pos != b.lo) return error.CorruptInput;
    }

    /// Reads a table for `kind` in `mode` from the start of `src`; the
    /// result is the bytes it took.
    fn seqTable(x: *Decompress, t: *Table, comptime kind: Kind, mode: u8, src: []const u8) Error!usize {
        @setRuntimeSafety(true);
        const w = x.work;
        const max_sym, const max_log, const own, const rle, const def, const def_log = switch (kind) {
            .ll => .{ ll_max_sym, ll_max_log, &w.ll, &w.ll_rle, &w.ll_def, 6 },
            .ml => .{ ml_max_sym, ml_max_log, &w.ml, &w.ml_rle, &w.ml_def, 6 },
            .of => .{ of_max_sym, of_max_log, &w.of, &w.of_rle, &w.of_def, 5 },
        };
        switch (mode) {
            0 => {
                t.* = .{ .t = def, .log = def_log };
                return 0;
            },
            1 => {
                if (src.len < 1 or src[0] > max_sym) return error.CorruptInput;
                rle[0] = code(kind, src[0]);
                t.* = .{ .t = rle, .log = 0 };
                return 1;
            },
            2 => {
                var norm: [256]i16 = undefined;
                const c = try readCounts(src, &norm, max_sym, max_log);
                try buildTable(own, &norm, c.syms, c.log, kind);
                t.* = .{ .t = own, .log = c.log };
                return c.used;
            },
            else => {
                if (t.t.len == 0) return error.CorruptInput;
                return 0;
            },
        }
    }

    /// Decodes `nseq` sequences from `blk[from..to]` and executes them with
    /// the `nlits` of `lits` into the history at `pos`; the result is the
    /// bytes written.
    fn sequences(x: *Decompress, lits: []const u8, nlits: usize, nseq: usize, from: usize, to: usize) Error!usize {
        @setRuntimeSafety(true);
        var br = try RevBits.init(&x.work.blk, from, to);
        const ll_t = x.ll.t;
        const ml_t = x.ml.t;
        const of_t = x.of.t;
        var ls: usize = @intCast(br.read(x.ll.log));
        var os: usize = @intCast(br.read(x.of.log));
        var ms: usize = @intCast(br.read(x.ml.log));
        var rep = x.rep;
        const out = x.hist;
        var o: usize = x.pos;
        var li: usize = 0;
        // where a match may reach back to: this frame's output still held
        const floor: usize = x.pos - @as(usize, @intCast(@min(x.produced, x.pos)));
        const limit = x.pos + x.block_limit;
        for (0..nseq) |k| {
            if (br.overrun()) return error.CorruptInput;
            const le = ll_t[ls];
            const me = ml_t[ms];
            const oe = of_t[os];
            var off: u32 = oe.base + @as(u32, @intCast(br.read(oe.add_bits)));
            const ml: usize = me.base + @as(u32, @intCast(br.read(me.add_bits)));
            const ll: usize = le.base + @as(u32, @intCast(br.read(le.add_bits)));
            if (off > 3) {
                off -= 3;
                rep[2] = rep[1];
                rep[1] = rep[0];
                rep[0] = off;
            } else {
                const r = off - 1 + @intFromBool(ll == 0);
                if (r != 0) {
                    off = if (r == 3) rep[0] -% 1 else rep[r];
                    if (r != 1) rep[2] = rep[1];
                    rep[1] = rep[0];
                    rep[0] = off;
                } else off = rep[0];
            }
            if (k + 1 < nseq) {
                ls = le.next + @as(usize, @intCast(br.read(le.nb)));
                ms = me.next + @as(usize, @intCast(br.read(me.nb)));
                os = oe.next + @as(usize, @intCast(br.read(oe.nb)));
            }
            if (ll > nlits - li or ml + ll > limit - o) return error.CorruptInput;
            copy16(out[o..], lits[li..], ll);
            li += ll;
            o += ll;
            if (off == 0 or off > o - floor) return error.CorruptInput;
            copyMatch(out, o, off, ml);
            o += ml;
        }
        if (br.pos != br.lo) return error.CorruptInput;
        const rest = nlits - li;
        if (rest > limit - o) return error.CorruptInput;
        @memcpy(out[o..][0..rest], lits[li..][0..rest]);
        x.rep = rep;
        return o + rest - x.pos;
    }
};

/// Decodes `out.len` literals from one stream.
fn hufRun(comptime mb: u8, t: *const [1 << huf_max_bits]Huf, br: *RevBits, out: []u8) error{CorruptInput}!void {
    @setRuntimeSafety(true);
    for (out) |*c| {
        if (br.overrun()) return error.CorruptInput;
        const e = t[@intCast(br.peek(mb))];
        br.pos -= e.nb;
        c.* = e.sym;
    }
}

/// Four streams a symbol at a time each, so their loads overlap; the last
/// stream may be shorter by up to three.
fn hufRun4(comptime mb: u8, t: *const [1 << huf_max_bits]Huf, brs: *[4]RevBits, outs: [4][]u8) error{CorruptInput}!void {
    @setRuntimeSafety(true);
    const n = outs[3].len;
    var b0 = brs[0];
    var b1 = brs[1];
    var b2 = brs[2];
    var b3 = brs[3];
    for (0..n) |i| {
        if (b0.overrun() or b1.overrun() or b2.overrun() or b3.overrun()) return error.CorruptInput;
        const e0 = t[@intCast(b0.peek(mb))];
        const e1 = t[@intCast(b1.peek(mb))];
        const e2 = t[@intCast(b2.peek(mb))];
        const e3 = t[@intCast(b3.peek(mb))];
        b0.pos -= e0.nb;
        b1.pos -= e1.nb;
        b2.pos -= e2.nb;
        b3.pos -= e3.nb;
        outs[0][i] = e0.sym;
        outs[1][i] = e1.sym;
        outs[2][i] = e2.sym;
        outs[3][i] = e3.sym;
    }
    brs.* = .{ b0, b1, b2, b3 };
    for (0..3) |s| try hufRun(mb, t, &brs[s], outs[s][n..]);
}

/// Copies `n` bytes from `src` to `dst` in 16-byte steps; both have `slack`
/// bytes past `n` and do not overlap.
inline fn copy16(dst: []u8, src: []const u8, n: usize) void {
    @setRuntimeSafety(true);
    var k: usize = 0;
    while (k < n) : (k += 16) dst[k..][0..16].* = src[k..][0..16].*;
}

/// A match of `n` bytes at `out[o..]`, `off` bytes back. Chunks wider than
/// the offset would read bytes not yet written, so a short offset copies
/// narrower.
inline fn copyMatch(out: []u8, o: usize, off: usize, n: usize) void {
    @setRuntimeSafety(true);
    const s = o - off;
    if (off >= 16) {
        var k: usize = 0;
        while (k < n) : (k += 16) out[o + k ..][0..16].* = out[s + k ..][0..16].*;
    } else if (off == 1) {
        @memset(out[o..][0..n], out[s]);
    } else if (off >= 8) {
        var k: usize = 0;
        while (k < n) : (k += 8) out[o + k ..][0..8].* = out[s + k ..][0..8].*;
    } else {
        for (0..n) |k| out[o + k] = out[s + k];
    }
}

const testing = std.testing;
const Compressor = @import("../remote/zstd.zig").Compressor;

fn decodeAll(gpa: Allocator, in: []const u8) ![]u8 {
    var r: Reader = .fixed(in);
    var x = try Decompress.init(&r, gpa, &.{});
    defer x.deinit();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = x.reader.streamRemaining(&out.writer) catch |e| switch (e) {
        error.ReadFailed => return x.err.?,
        else => |y| return y,
    };
    return out.toOwnedSlice();
}

fn roundTrip(data: []const u8) !void {
    var enc: Writer.Allocating = .init(testing.allocator);
    defer enc.deinit();
    var c = try Compressor.init(testing.allocator, &enc.writer, .{});
    defer c.deinit();
    try c.writer.writeAll(data);
    try c.finish();
    const got = try decodeAll(testing.allocator, enc.written());
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, data, got);
}

test "our encoder's output decodes back" {
    try roundTrip("");
    try roundTrip("a");
    try roundTrip("hello, hello, hello, hello world\n");
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const big = try testing.allocator.alloc(u8, 6 << 20);
    defer testing.allocator.free(big);
    // text-like: words from a small vocabulary, so literals are Huffman
    // coded and matches have every kind of offset
    var i: usize = 0;
    const words = [_][]const u8{ "nixpkgs", "lib", "mkDerivation", " = ", "{ ", " }", ";\n", "inherit", "stdenv", "\t", "0", "1" };
    while (i < big.len) {
        const wd = words[r.uintLessThan(usize, words.len)];
        const n = @min(wd.len, big.len - i);
        @memcpy(big[i..][0..n], wd[0..n]);
        i += n;
    }
    try roundTrip(big);
    r.bytes(big[0 .. 1 << 20]);
    try roundTrip(big);
    @memset(big, 0);
    try roundTrip(big);
}

/// The text `testdata/text.zst` begins with: words and printable bytes
/// drawn by a 64-bit LCG, which the test regenerates.
fn lcgText(out: []u8) void {
    const words = [_][]const u8{ "nixpkgs", "lib", "mkDerivation", " = ", "{ ", " }", ";\n", "inherit", "stdenv", "\t", "0", "1", "fetchurl", "sha256-", "version", "\"", "meta.license", "maintainers", "/nix/store/", "x86_64-linux" };
    var s: u64 = 1;
    var i: usize = 0;
    while (i < out.len) {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        const w = (s >> 33) % (words.len + 3);
        if (w < words.len) {
            const n = @min(words[w].len, out.len - i);
            @memcpy(out[i..][0..n], words[w][0..n]);
            i += n;
        } else {
            out[i] = @intCast(32 + (s >> 40) % 95);
            i += 1;
        }
    }
}

test "zstd -19 --check output decodes, in frames around a skippable one" {
    // `zstd -19 --check` of 300000 bytes of `lcgText`, a skippable frame,
    // then `zstd -1` of "hello\n"
    const got = try decodeAll(testing.allocator, @embedFile("testdata/text.zst"));
    defer testing.allocator.free(got);
    const want = try testing.allocator.alloc(u8, 300000);
    defer testing.allocator.free(want);
    lcgText(want);
    try testing.expectEqualSlices(u8, want, got[0..@min(got.len, want.len)]);
    try testing.expectEqualStrings("hello\n", got[want.len..]);
}

test "a wrong checksum, a cut stream and a dictionary are errors" {
    const in = @embedFile("testdata/text.zst");
    const first = std.mem.indexOf(u8, in, &.{ 0x50, 0x2A, 0x4D, 0x18 }).?;
    const bad = try testing.allocator.dupe(u8, in[0..first]);
    defer testing.allocator.free(bad);
    bad[bad.len - 1] ^= 1;
    try testing.expectError(error.WrongChecksum, decodeAll(testing.allocator, bad));
    try testing.expectError(error.CorruptInput, decodeAll(testing.allocator, in[0 .. first - 9]));
    try testing.expectError(error.CorruptInput, decodeAll(testing.allocator, in[0..3]));
    // a frame header with a one-byte dictionary id
    try testing.expectError(error.Unsupported, decodeAll(testing.allocator, &.{ 0x28, 0xb5, 0x2f, 0xfd, 0x01, 0x58, 0x07 }));
}

test "literals: 12-bit Huffman tables, and the code shapes libzstd refuses" {
    // hand-built frames with a 1 KiB window; libzstd decodes the first and
    // refuses the other two. 12 bits: weights 1, 1, 2..11 and an implied 12
    const huf12 = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x7d, 0x00, 0x00, 0x42, 0xc0, 0x02, 0x8b, 0x11, 0x23, 0x45, 0x67, 0x89, 0xab, 0x05, 0x00, 0x00, 0x0c, 0x00 };
    const got = try decodeAll(testing.allocator, &huf12);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 12, 0, 1, 11 }, got);
    // two symbols of weight 11: no code of the longest length
    try testing.expectError(error.CorruptInput, decodeAll(testing.allocator, &.{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x3d, 0x00, 0x00, 0x42, 0xc0, 0x00, 0x80, 0xb0, 0x16, 0x00 }));
    // four literals in four streams
    try testing.expectError(error.CorruptInput, decodeAll(testing.allocator, &.{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0xad, 0x00, 0x00, 0x46, 0x40, 0x04, 0x8a, 0x11, 0x23, 0x45, 0x67, 0x89, 0xa0, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x03, 0x03, 0x03, 0x03, 0x00 }));
}

test "corrupt blocks fail without reading out of bounds" {
    const in = @embedFile("testdata/text.zst");
    const copy = try testing.allocator.dupe(u8, in);
    defer testing.allocator.free(copy);
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    for (0..300) |_| {
        @memcpy(copy, in);
        for (0..1 + r.uintLessThan(usize, 4)) |_| copy[6 + r.uintLessThan(usize, copy.len - 6)] ^= @as(u8, 1) << r.int(u3);
        if (decodeAll(testing.allocator, copy)) |got| testing.allocator.free(got) else |_| {}
    }
}
