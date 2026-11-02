//! Streaming Zstandard compressor (RFC 8878), the counterpart of
//! `std.compress.zstd.Decompress`.
//!
//! It follows libzstd's level 1: the "fast" strategy (one hash table of
//! positions, greedy matching, repeat-offset checks, step acceleration on
//! incompressible input), Huffman-coded literals that reuse the previous
//! block's table when that is cheaper, FSE-coded sequences with the table
//! mode libzstd picks for that strategy (predefined, RLE or a fresh table;
//! never repeated), and the cheap "from borders" pre-split of full blocks.
//!
//! Output is one frame without a content size or checksum, as libzstd emits
//! when streaming with its defaults.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const zstd = std.compress.zstd;

const block_max = zstd.block_size_max;
const frame_magic: u32 = 0xFD2FB528;
/// Every match is at least 4 bytes, so a block holds at most this many sequences.
const max_sequences = block_max / 4 + 1;
/// Worst case of a compressed block before it is replaced by a raw one: each
/// 4-byte match can cost up to ~49 bits of states and extra bits.
const cbuf_len = 2 * block_max + 4096;
/// Literal copies move 16 bytes at a time and may read this far past a block.
const copy_slack = 32;

const ll_max_log = zstd.table_accuracy_log_max.literal;
const ml_max_log = zstd.table_accuracy_log_max.match;
const of_max_log = zstd.table_accuracy_log_max.offset;
const fse_max_log = 9;
const huf_max_bits = 11;

pub const Options = struct {
    /// log2 of the window, 17..23. Offsets never exceed it, so a decoder
    /// needs this much history; std's decoder accepts up to 23 by default.
    window_log: u5 = 21,
    /// log2 of the number of hash table entries (4 bytes each), 10..24.
    /// The defaults for this and `min_match` are libzstd level 1's; 16 and 6
    /// compress NARs about 10% smaller for about 15% less speed.
    hash_log: u5 = 14,
    /// Bytes hashed per position, 4..8.
    min_match: u4 = 7,
};

pub const Compressor = struct {
    gpa: std.mem.Allocator,
    out: *Writer,
    /// Uncompressed bytes are written here. Its buffer is the tail of `hist`
    /// past the compressed history, so buffered writes land in place.
    writer: Writer,

    /// Window history followed by the pending (not yet compressed) bytes.
    hist: []u8,
    /// Index in `hist` of the first pending byte; `writer.end` pending bytes follow.
    start: usize,
    window_size: u32,
    hash_table: []u32,
    hash_log: u5,
    min_match: u4,
    /// Repeat offsets as the decoder will see them after the last compressed block.
    rep: [3]u32,
    header_written: bool,
    /// Input bytes minus output bytes so far.
    savings: i64,

    lits: []u8,
    nlits: usize,
    seq_ll: []u32,
    seq_ml: []u32,
    seq_of: []u32,
    nseq: usize,
    codes: []u8,
    extra: []u64,
    cbuf: []u8,

    /// `huf[huf_cur]` is the decoder's current literals table when
    /// `huf_valid`; a new one is built in the other slot and becomes current
    /// only once its block is emitted compressed.
    huf: [2]Huffman,
    huf_cur: u1,
    huf_valid: bool,
    huf_new: bool,

    ll_default: FseCTable,
    ml_default: FseCTable,
    of_default: FseCTable,
    ll_table: FseCTable,
    ml_table: FseCTable,
    of_table: FseCTable,

    pub fn init(gpa: std.mem.Allocator, out: *Writer, options: Options) std.mem.Allocator.Error!Compressor {
        const window_log = std.math.clamp(options.window_log, 17, 23);
        const hash_log = std.math.clamp(options.hash_log, 10, 24);
        const window_size: u32 = @as(u32, 1) << window_log;
        // A slide moves a window's worth of history, so the slack past it
        // sets how often that happens: 6 MiB keeps the cost to a few percent
        // (measured), and two blocks is the minimum for a slide to free room.
        const slack = @max(window_size, 6 << 20);
        const hist_alloc = try gpa.alloc(u8, window_size + slack + copy_slack);
        errdefer gpa.free(hist_alloc);
        const hist = hist_alloc[0 .. window_size + slack];
        const hash_table = try gpa.alloc(u32, @as(usize, 1) << hash_log);
        errdefer gpa.free(hash_table);
        @memset(hash_table, 0);
        const lits = try gpa.alloc(u8, block_max + 64);
        errdefer gpa.free(lits);
        const seqs = try gpa.alloc(u32, 3 * max_sequences);
        errdefer gpa.free(seqs);
        const codes = try gpa.alloc(u8, 3 * max_sequences);
        errdefer gpa.free(codes);
        const extra = try gpa.alloc(u64, max_sequences);
        errdefer gpa.free(extra);
        const cbuf = try gpa.alloc(u8, cbuf_len + 64);
        errdefer gpa.free(cbuf);

        var c: Compressor = .{
            .gpa = gpa,
            .out = out,
            .writer = .{
                .buffer = hist,
                .end = 0,
                .vtable = &.{ .drain = drain, .flush = flushVtable, .rebase = rebaseVtable },
            },
            .hist = hist,
            .start = 0,
            .window_size = window_size,
            .hash_table = hash_table,
            .hash_log = hash_log,
            .min_match = std.math.clamp(options.min_match, 4, 8),
            .rep = .{ zstd.start_repeated_offset_1, zstd.start_repeated_offset_2, zstd.start_repeated_offset_3 },
            .header_written = false,
            .savings = 0,
            .lits = lits,
            .nlits = 0,
            .seq_ll = seqs[0..max_sequences],
            .seq_ml = seqs[max_sequences..][0..max_sequences],
            .seq_of = seqs[2 * max_sequences ..][0..max_sequences],
            .nseq = 0,
            .codes = codes,
            .extra = extra,
            .cbuf = cbuf,
            .huf = undefined,
            .huf_cur = 0,
            .huf_valid = false,
            .huf_new = false,
            .ll_default = undefined,
            .ml_default = undefined,
            .of_default = undefined,
            .ll_table = undefined,
            .ml_table = undefined,
            .of_table = undefined,
        };
        c.ll_default.build(&zstd.literals_length_default_distribution, 6);
        c.ml_default.build(&zstd.match_lengths_default_distribution, 6);
        c.of_default.build(&zstd.offset_codes_default_distribution, 5);
        return c;
    }

    pub fn deinit(c: *Compressor) void {
        c.gpa.free(c.hist.ptr[0 .. c.hist.len + copy_slack]);
        c.gpa.free(c.hash_table);
        c.gpa.free(c.lits);
        c.gpa.free(c.seq_ll.ptr[0 .. 3 * max_sequences]);
        c.gpa.free(c.codes);
        c.gpa.free(c.extra);
        c.gpa.free(c.cbuf);
        c.* = undefined;
    }

    /// ZSTD_e_flush: every byte written so far goes out as complete blocks, so
    /// a decoder fed the output can produce all of it, while the frame stays
    /// open and later data may still match against earlier data.
    pub fn flush(c: *Compressor) Writer.Error!void {
        try c.compressPending(.flush);
        try c.out.flush();
    }

    /// ZSTD_e_end: emits the remaining data and the last block. The writer
    /// must not be used afterwards.
    pub fn finish(c: *Compressor) Writer.Error!void {
        try c.compressPending(.end);
        try c.out.flush();
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const c: *Compressor = @alignCast(@fieldParentPtr("writer", w));
        try c.compressPending(.full);
        if (c.hist.len - (c.start + w.end) < block_max) c.slide();
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            const k = c.append(bytes);
            n += k;
            if (k < bytes.len) return n;
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 1) {
            const dest = w.buffer[w.end..];
            const k = @min(dest.len, splat);
            @memset(dest[0..k], pattern[0]);
            w.end += k;
            return n + k;
        }
        for (0..splat) |_| {
            const k = c.append(pattern);
            n += k;
            if (k < pattern.len) return n;
        }
        return n;
    }

    fn flushVtable(w: *Writer) Writer.Error!void {
        const c: *Compressor = @alignCast(@fieldParentPtr("writer", w));
        return c.flush();
    }

    /// Compressing a block consumes buffered bytes, so blocks are only
    /// compressed while at least `preserve` bytes stay pending.
    fn rebaseVtable(w: *Writer, preserve: usize, capacity: usize) Writer.Error!void {
        const c: *Compressor = @alignCast(@fieldParentPtr("writer", w));
        while (w.end >= block_max and w.end - block_max >= preserve) {
            try c.emitBlock(c.start, c.start + block_max, false);
            c.consume(block_max);
        }
        c.slide();
        if (w.buffer.len - w.end < capacity) return error.WriteFailed;
    }

    fn append(c: *Compressor, bytes: []const u8) usize {
        const w = &c.writer;
        const dest = w.buffer[w.end..];
        const k = @min(dest.len, bytes.len);
        @memcpy(dest[0..k], bytes[0..k]);
        w.end += k;
        return k;
    }

    fn consume(c: *Compressor, n: usize) void {
        const pending = c.writer.end - n;
        c.start += n;
        c.writer.buffer = c.hist[c.start..];
        c.writer.end = pending;
    }

    /// Drops history older than the window by moving the rest to the front of
    /// `hist`; hash table positions move with it, and those that fall off
    /// clamp to 0, which is still a real (verified-before-use) position.
    fn slide(c: *Compressor) void {
        const keep_from = c.start -| c.window_size;
        if (keep_from == 0) return;
        const end = c.start + c.writer.end;
        std.mem.copyForwards(u8, c.hist[0 .. end - keep_from], c.hist[keep_from..end]);
        const d: u32 = @intCast(keep_from);
        for (c.hash_table) |*e| e.* -|= d;
        c.start -= keep_from;
        c.writer.buffer = c.hist[c.start..];
    }

    const PendingMode = enum { full, flush, end };

    fn compressPending(c: *Compressor, mode: PendingMode) Writer.Error!void {
        while (true) {
            const pending = c.writer.end;
            if (pending == 0 or (mode == .full and pending < block_max)) break;
            // Mirrors zstd_compress.c:ZSTD_optimalBlockSize: only full blocks
            // are split, and only once compression has proven worthwhile.
            const n = if (pending >= block_max and c.savings >= 3)
                splitBlock(c.hist[c.start..][0..block_max])
            else
                @min(pending, block_max);
            const last = mode == .end and n == pending;
            try c.emitBlock(c.start, c.start + n, last);
            c.consume(n);
            if (last) return;
        }
        if (mode == .end) {
            try c.writeFrameHeader();
            var hdr: [3]u8 = undefined;
            std.mem.writeInt(u24, &hdr, 1, .little);
            try c.out.writeAll(&hdr);
        }
    }

    /// RFC 8878 §3.1.1.1: no content size (streaming), no dictionary, no
    /// checksum; the window descriptor carries the window size.
    fn writeFrameHeader(c: *Compressor) Writer.Error!void {
        if (c.header_written) return;
        c.header_written = true;
        c.savings -= 6;
        var hdr: [6]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], frame_magic, .little);
        hdr[4] = 0;
        hdr[5] = @as(u8, std.math.log2_int(u32, c.window_size) - 10) << 3;
        try c.out.writeAll(&hdr);
    }

    /// Mirrors zstd_compress.c:ZSTD_compressBlock_internal: compress, then
    /// fall back to an RLE or raw block when that is smaller. Raw and RLE
    /// blocks carry no sequences or tables, so the repeat offsets are rolled
    /// back and a new Huffman table is dropped.
    fn emitBlock(c: *Compressor, bs: usize, be: usize, last: bool) Writer.Error!void {
        try c.writeFrameHeader();
        const src = c.hist[bs..be];
        const saved_rep = c.rep;
        const csize = c.compressBlock(bs, be);
        var hdr: [3]u8 = undefined;
        const last_bit: u24 = @intFromBool(last);
        if (csize != 0 and csize < 25 and c.nseq < 4 and c.nlits < 10 and isRle(src)) {
            c.rep = saved_rep;
            std.mem.writeInt(u24, &hdr, last_bit | (1 << 1) | @as(u24, @intCast(src.len)) << 3, .little);
            try c.out.writeAll(&hdr);
            try c.out.writeByte(src[0]);
            c.savings += @as(i64, @intCast(src.len)) - 4;
        } else if (csize == 0) {
            c.rep = saved_rep;
            std.mem.writeInt(u24, &hdr, last_bit | @as(u24, @intCast(src.len)) << 3, .little);
            try c.out.writeAll(&hdr);
            try c.out.writeAll(src);
            c.savings -= 3;
        } else {
            if (c.huf_new) {
                c.huf_cur ^= 1;
                c.huf_valid = true;
            }
            std.mem.writeInt(u24, &hdr, last_bit | (2 << 1) | @as(u24, @intCast(csize)) << 3, .little);
            try c.out.writeAll(&hdr);
            try c.out.writeAll(c.cbuf[0..csize]);
            c.savings += @as(i64, @intCast(src.len)) - @as(i64, @intCast(csize + 3));
        }
    }

    /// Returns the size of the compressed block body in `cbuf`, or 0 when a
    /// raw block is smaller.
    fn compressBlock(c: *Compressor, bs: usize, be: usize) usize {
        c.nseq = 0;
        c.nlits = 0;
        switch (c.min_match) {
            4 => c.matchFast(4, bs, be),
            5 => c.matchFast(5, bs, be),
            6 => c.matchFast(6, bs, be),
            7 => c.matchFast(7, bs, be),
            else => c.matchFast(8, bs, be),
        }
        var op = c.encodeLiterals(c.cbuf);
        op += c.encodeSequences(c.cbuf[op..]);
        const src_len = be - bs;
        if (op >= src_len -| minGain(src_len)) return 0;
        return op;
    }

    /// Mirrors zstd_fast.c:ZSTD_compressBlock_fast_noDict_generic (the
    /// pipelined variant): two adjacent positions are probed per step, the
    /// repeat offset is tried two ahead, and the step grows every 128 bytes
    /// without a match. A repeat offset of 0 means "unusable in this block";
    /// the real value is kept aside and restored for the next block.
    noinline fn matchFast(c: *Compressor, comptime mls: u32, bs: usize, be: usize) void {
        const base = c.hist.ptr;
        const table = c.hash_table.ptr;
        const hlog = c.hash_log;
        const step_size: usize = 2;
        const step_incr: usize = 1 << 7;
        // Measured from the block end, so every match in the block is within the window.
        const prefix_start: usize = be -| c.window_size;
        const ilimit: usize = be -| 8;

        var store: SeqStore = .{
            .lits = c.lits.ptr,
            .ll = c.seq_ll.ptr,
            .ml = c.seq_ml.ptr,
            .of = c.seq_of.ptr,
        };
        defer {
            c.nlits = store.nlits;
            c.nseq = store.n;
        }

        var anchor = bs;
        var ip0 = bs;
        ip0 += @intFromBool(ip0 == prefix_start);
        var rep1 = c.rep[0];
        var rep2 = c.rep[1];
        var saved1: u32 = 0;
        var saved2: u32 = 0;
        {
            const max_rep = ip0 - prefix_start;
            if (rep2 > max_rep) {
                saved2 = rep2;
                rep2 = 0;
            }
            if (rep1 > max_rep) {
                saved1 = rep1;
                rep1 = 0;
            }
        }

        outer: while (true) {
            var step = step_size;
            var next_step = ip0 + step_incr;
            var ip1 = ip0 + 1;
            var ip2 = ip0 + step;
            var ip3 = ip2 + 1;
            if (ip3 >= ilimit) break :outer;

            var hash0 = hashAt(base, ip0, hlog, mls);
            var hash1 = hashAt(base, ip1, hlog, mls);
            var match_idx: usize = table[hash0];
            var current0: usize = undefined;
            var match0: usize = undefined;
            var mlen: usize = undefined;

            const is_rep = search: while (true) {
                const rval = read32(base, ip2 - rep1);
                current0 = ip0;
                table[hash0] = @intCast(ip0);
                if (read32(base, ip2) == rval and rep1 > 0) {
                    ip0 = ip2;
                    match0 = ip0 - rep1;
                    mlen = @intFromBool(base[ip0 - 1] == base[match0 - 1]);
                    ip0 -= mlen;
                    match0 -= mlen;
                    mlen += 4;
                    table[hash1] = @intCast(ip1);
                    break :search true;
                }
                if (match_idx >= prefix_start and read32(base, ip0) == read32(base, match_idx)) {
                    table[hash1] = @intCast(ip1);
                    break :search false;
                }

                match_idx = table[hash1];
                hash0 = hash1;
                hash1 = hashAt(base, ip2, hlog, mls);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip3;

                current0 = ip0;
                table[hash0] = @intCast(ip0);
                if (match_idx >= prefix_start and read32(base, ip0) == read32(base, match_idx)) {
                    // Search resumes at least 4 bytes on, past ip1.
                    if (step <= 4) table[hash1] = @intCast(ip1);
                    break :search false;
                }

                match_idx = table[hash1];
                hash0 = hash1;
                hash1 = hashAt(base, ip2, hlog, mls);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip0 + step;
                ip3 = ip1 + step;
                if (ip2 >= next_step) {
                    step += 1;
                    next_step += step_incr;
                }
                if (ip3 >= ilimit) break :outer;
            };

            var off_base: u32 = 1;
            if (!is_rep) {
                match0 = match_idx;
                rep2 = rep1;
                rep1 = @intCast(ip0 - match0);
                off_base = rep1 + 3;
                mlen = 4;
                while (ip0 > anchor and match0 > prefix_start and base[ip0 - 1] == base[match0 - 1]) {
                    ip0 -= 1;
                    match0 -= 1;
                    mlen += 1;
                }
            }

            mlen += count(base, ip0 + mlen, match0 + mlen, be);
            store.add(base, anchor, ip0, off_base, mlen);
            ip0 += mlen;
            anchor = ip0;

            if (ip0 <= ilimit) {
                table[hashAt(base, current0 + 2, hlog, mls)] = @intCast(current0 + 2);
                table[hashAt(base, ip0 - 2, hlog, mls)] = @intCast(ip0 - 2);
                if (rep2 > 0) {
                    while (ip0 <= ilimit and read32(base, ip0) == read32(base, ip0 - rep2)) {
                        const rlen = count(base, ip0 + 4, ip0 + 4 - rep2, be) + 4;
                        const tmp = rep1;
                        rep1 = rep2;
                        rep2 = tmp;
                        table[hashAt(base, ip0, hlog, mls)] = @intCast(ip0);
                        // Literal length 0 makes repeat code 1 mean the second repeat offset.
                        store.add(base, anchor, anchor, 1, rlen);
                        ip0 += rlen;
                        anchor = ip0;
                    }
                }
            }
        }

        saved2 = if (saved1 != 0 and rep1 != 0) saved1 else saved2;
        c.rep[0] = if (rep1 != 0) rep1 else saved1;
        c.rep[1] = if (rep2 != 0) rep2 else saved2;

        const last = be - anchor;
        @memcpy(store.lits[store.nlits..][0..last], base[anchor..be]);
        store.nlits += last;
    }

    /// Mirrors zstd_compress_literals.c:ZSTD_compressLiterals and
    /// huf_compress.c:HUF_compress_internal: raw below 64 bytes or when
    /// Huffman does not gain enough, RLE for a single symbol, and the
    /// previous block's Huffman table (treeless literals) when it is no worse
    /// than a new table plus its description. RFC 8878 §3.1.1.3.1.
    fn encodeLiterals(c: *Compressor, dst: []u8) usize {
        c.huf_new = false;
        const lits = c.lits[0..c.nlits];
        const len = lits.len;
        if (len < 64) return writeRawLiterals(dst, lits);

        // Likely incompressible: sample both ends before a full histogram.
        if ((c.nseq == 0 or len / c.nseq >= 20) and len >= 4096 * 10) {
            var head: [256]u32 = @splat(0);
            var tail: [256]u32 = @splat(0);
            histogram(lits[0..4096], &head);
            histogram(lits[len - 4096 ..], &tail);
            const most = std.mem.max(u32, &head) + std.mem.max(u32, &tail);
            if (most <= ((2 * 4096) >> 7) + 4) return writeRawLiterals(dst, lits);
        }

        var counts: [256]u32 = @splat(0);
        histogram(lits, &counts);
        var max_sym: usize = 255;
        while (counts[max_sym] == 0) max_sym -= 1;
        const largest = std.mem.max(u32, counts[0 .. max_sym + 1]);
        if (largest == len) {
            const n = writeLiteralsHeader(dst, 1, len);
            dst[n] = lits[0];
            return n + 1;
        }
        if (largest <= (len >> 7) + 4) return writeRawLiterals(dst, lits);

        const prev = &c.huf[c.huf_cur];
        const prev_ok = c.huf_valid and prev.covers(&counts, max_sym);
        if (prev_ok and len <= 1024)
            return huffmanLiterals(dst, lits, prev, null, &counts) orelse writeRawLiterals(dst, lits);

        const huf = &c.huf[c.huf_cur ^ 1];
        huf.build(&counts, max_sym, optimalTableLog(huf_max_bits, len, max_sym, 1));
        var table: [256]u8 = undefined;
        const table_len = huf.writeTable(&table) orelse 0;
        if (prev_ok and (table_len == 0 or
            prev.cost(&counts) <= table_len + huf.cost(&counts) or table_len + 12 >= len))
            return huffmanLiterals(dst, lits, prev, null, &counts) orelse writeRawLiterals(dst, lits);
        if (table_len == 0 or table_len + 12 >= len) return writeRawLiterals(dst, lits);
        const n = huffmanLiterals(dst, lits, huf, table[0..table_len], &counts) orelse
            return writeRawLiterals(dst, lits);
        c.huf_new = true;
        return n;
    }

    /// RFC 8878 §3.1.1.3.2. Mirrors zstd_compress_sequences.c:ZSTD_encodeSequences
    /// for the bitstream and ZSTD_selectEncodingType for the table modes.
    fn encodeSequences(c: *Compressor, dst: []u8) usize {
        const n = c.nseq;
        var op: usize = undefined;
        if (n < 128) {
            dst[0] = @intCast(n);
            op = 1;
        } else if (n < 0x7F00) {
            dst[0] = @intCast((n >> 8) + 0x80);
            dst[1] = @truncate(n);
            op = 2;
        } else {
            dst[0] = 0xFF;
            std.mem.writeInt(u16, dst[1..3], @intCast(n - 0x7F00), .little);
            op = 3;
        }
        if (n == 0) return op;

        const llc = c.codes[0..n];
        const mlc = c.codes[max_sequences..][0..n];
        const ofc = c.codes[2 * max_sequences ..][0..n];
        var ll_count: [36]u32 = @splat(0);
        var ml_count: [53]u32 = @splat(0);
        var of_count: [32]u32 = @splat(0);
        const extra = c.extra[0..n];
        for (0..n) |i| {
            const ll = c.seq_ll[i];
            const ml = c.seq_ml[i];
            const of = c.seq_of[i];
            const l = llCode(ll);
            const m = mlCode(ml - 3);
            const o: u5 = std.math.log2_int(u32, of);
            const lt = zstd.literals_length_code_table[l];
            const mt = zstd.match_length_code_table[m];
            // All extra bits of a sequence in one word (at most 16 + 16 + 23
            // bits), with their count in the top byte.
            var e: u64 = ll - lt[0];
            var nb: u6 = lt[1];
            e |= @as(u64, ml - mt[0]) << nb;
            nb += mt[1];
            e |= @as(u64, of - (@as(u32, 1) << o)) << nb;
            nb += o;
            extra[i] = e | @as(u64, nb) << 56;
            llc[i] = l;
            mlc[i] = m;
            ofc[i] = o;
            ll_count[l] += 1;
            ml_count[m] += 1;
            of_count[o] += 1;
        }

        const modes_at = op;
        op += 1;
        const ll_mode, const ll_t = selectTable(&c.ll_table, &c.ll_default, &ll_count, llc[n - 1], n, ll_max_log, 6, dst, &op);
        const of_mode, const of_t = selectTable(&c.of_table, &c.of_default, &of_count, ofc[n - 1], n, of_max_log, 5, dst, &op);
        const ml_mode, const ml_t = selectTable(&c.ml_table, &c.ml_default, &ml_count, mlc[n - 1], n, ml_max_log, 6, dst, &op);
        dst[modes_at] = @as(u8, @backingInt(ll_mode)) << 6 | @as(u8, @backingInt(of_mode)) << 4 | @as(u8, @backingInt(ml_mode)) << 2;

        var bw: BitWriter = .{ .buf = dst[op..] };
        // The decoder reads backwards, so the last sequence goes in first.
        const last = n - 1;
        var s_ml: FseState = .init(ml_t, mlc[last]);
        var s_of: FseState = .init(of_t, ofc[last]);
        var s_ll: FseState = .init(ll_t, llc[last]);
        addExtraBits(&bw, extra[last]);
        var i = last;
        while (i > 0) {
            i -= 1;
            s_of.encode(&bw, ofc[i]);
            s_ml.encode(&bw, mlc[i]);
            s_ll.encode(&bw, llc[i]);
            bw.flush();
            addExtraBits(&bw, extra[i]);
        }
        s_ml.flushState(&bw);
        s_of.flushState(&bw);
        s_ll.flushState(&bw);
        return op + bw.close();
    }

    /// At most 55 bits, which fits after a flush.
    inline fn addExtraBits(bw: *BitWriter, e: u64) void {
        bw.addFast(e & ((1 << 56) - 1), @intCast(e >> 56));
        bw.flush();
    }
};

/// Mirrors zstd_compress_internal.h:ZSTD_storeSeq, kept in locals by the
/// match finder so the hot loop does not go through the compressor.
const SeqStore = struct {
    lits: [*]u8,
    nlits: usize = 0,
    ll: [*]u32,
    ml: [*]u32,
    of: [*]u32,
    n: usize = 0,

    inline fn add(s: *SeqStore, base: [*]const u8, lit_start: usize, lit_end: usize, off_base: u32, mlen: usize) void {
        const ll = lit_end - lit_start;
        // Overshoots by up to 15 bytes; `copy_slack` and the literal buffer's slack absorb it.
        var i: usize = 0;
        while (i < ll) : (i += 16) s.lits[s.nlits + i ..][0..16].* = base[lit_start + i ..][0..16].*;
        s.nlits += ll;
        s.ll[s.n] = @intCast(ll);
        s.ml[s.n] = @intCast(mlen);
        s.of[s.n] = off_base;
        s.n += 1;
    }
};

const TableMode = enum(u2) { predefined = 0, rle = 1, compressed = 2, repeat = 3 };

/// Mirrors zstd_compress_sequences.c:ZSTD_selectEncodingType for strategies
/// below lazy, then ZSTD_buildCTable. The last symbol's count is reduced by
/// one because the initial state encodes it for free.
fn selectTable(
    dyn: *FseCTable,
    default: *const FseCTable,
    counts: []u32,
    last_code: u8,
    nseq: usize,
    max_log: u32,
    default_log: u5,
    dst: []u8,
    op: *usize,
) struct { TableMode, *const FseCTable } {
    var max_sym: usize = counts.len - 1;
    while (counts[max_sym] == 0) max_sym -= 1;
    var most: u32 = 0;
    var most_sym: usize = 0;
    for (counts[0 .. max_sym + 1], 0..) |n, s| if (n > most) {
        most = n;
        most_sym = s;
    };
    if (most == nseq) {
        if (nseq <= 2) return .{ .predefined, default };
        dst[op.*] = @intCast(most_sym);
        op.* += 1;
        dyn.buildRle(@intCast(most_sym));
        return .{ .rle, dyn };
    }
    const dynamic_min = ((@as(usize, 1) << default_log) * 9) >> 3;
    if (nseq < dynamic_min or most < (nseq >> (default_log - 1))) return .{ .predefined, default };

    const table_log = optimalTableLog(max_log, nseq, max_sym, 2);
    var total = nseq;
    if (counts[last_code] > 1) {
        counts[last_code] -= 1;
        total -= 1;
    }
    var norm: [64]i16 = undefined;
    if (!normalizeCount(norm[0 .. max_sym + 1], table_log, counts[0 .. max_sym + 1], total, total >= 2048))
        return .{ .predefined, default };
    op.* += writeNCount(dst[op.*..], norm[0 .. max_sym + 1], table_log);
    dyn.build(norm[0 .. max_sym + 1], table_log);
    return .{ .compressed, dyn };
}

/// Huffman-coded literals with a table description (`table`) or reusing the
/// decoder's current table (treeless). Null when raw literals are smaller.
fn huffmanLiterals(dst: []u8, lits: []const u8, huf: *const Huffman, table: ?[]const u8, counts: *const [256]u32) ?usize {
    const len = lits.len;
    const single = len < 256;
    const lh: usize = if (single) 3 else 3 + @as(usize, @intFromBool(len >= 1024)) + @intFromBool(len >= 16384);
    var op = lh;
    if (table) |t| {
        @memcpy(dst[op..][0..t.len], t);
        op += t.len;
    }
    const limit = len - minGain(len);
    if (op - lh + huf.cost(counts) + (if (single) @as(usize, 1) else 10) >= limit) return null;

    if (single) {
        op += huf.encodeStream(dst[op..], lits);
    } else {
        const jump = op;
        op += 6;
        const seg = (len + 3) / 4;
        for (0..4) |k| {
            const part = lits[k * seg .. @min(len, (k + 1) * seg)];
            const size = huf.encodeStream(dst[op..], part);
            if (k < 3) std.mem.writeInt(u16, dst[jump + 2 * k ..][0..2], @intCast(size), .little);
            op += size;
        }
    }
    const csize = op - lh;
    if (csize >= limit) return null;

    const block_type: u64 = if (table == null) 3 else 2;
    const sf: u64, const field_bits: u6 = switch (lh) {
        3 => .{ @intFromBool(!single), 10 },
        4 => .{ 2, 14 },
        else => .{ 3, 18 },
    };
    const v: u64 = block_type | sf << 2 | @as(u64, len) << 4 | @as(u64, csize) << (4 + field_bits);
    for (0..lh) |i| dst[i] = @truncate(v >> @intCast(8 * i));
    return op;
}

/// Mirrors zstd_preSplit.c:ZSTD_splitBlock_fromBorders: byte histograms of
/// the first and last 512 bytes of a full block; when they differ, the
/// middle decides where the block is cut, so each part gets its own tables.
fn splitBlock(block: []const u8) usize {
    const seg = 512;
    assert(block.len == block_max);
    var past: [256]i64 = @splat(0);
    var new: [256]i64 = @splat(0);
    for (block[0..seg]) |b| past[b] += 1;
    for (block[block.len - seg ..]) |b| new[b] += 1;
    if (fingerprintDistance(&past, &new) < seg * seg * 14 / 16) return block.len;
    var middle: [256]i64 = @splat(0);
    for (block[block.len / 2 - seg / 2 ..][0..seg]) |b| middle[b] += 1;
    const from_begin = fingerprintDistance(&past, &middle);
    const from_end = fingerprintDistance(&new, &middle);
    if (@abs(from_begin - from_end) < seg * seg / 3) return 64 * 1024;
    return if (from_begin > from_end) 32 * 1024 else 96 * 1024;
}

/// Mirrors zstd_preSplit.c:fpDistance for two 512-event fingerprints.
fn fingerprintDistance(a: *const [256]i64, b: *const [256]i64) i64 {
    var d: i64 = 0;
    for (a, b) |x, y| d += @intCast(@abs(x - y) * 512);
    return d;
}

/// Mirrors zstd_compress_internal.h:ZSTD_minGain for strategies below btultra.
fn minGain(src_len: usize) usize {
    return (src_len >> 6) + 2;
}

fn isRle(src: []const u8) bool {
    const b = src[0];
    for (src) |x| if (x != b) return false;
    return true;
}

fn histogram(src: []const u8, counts: *[256]u32) void {
    // Four tables break the store-to-load dependency on runs of one byte.
    var t: [4][256]u32 = @splat(@splat(0));
    var i: usize = 0;
    while (i + 4 <= src.len) : (i += 4) {
        t[0][src[i]] += 1;
        t[1][src[i + 1]] += 1;
        t[2][src[i + 2]] += 1;
        t[3][src[i + 3]] += 1;
    }
    while (i < src.len) : (i += 1) t[0][src[i]] += 1;
    for (counts, 0..) |*n, s| n.* += t[0][s] + t[1][s] + t[2][s] + t[3][s];
}

/// RFC 8878 §3.1.1.3.1.1, Size_Format for raw and RLE literals.
fn writeLiteralsHeader(dst: []u8, block_type: u8, size: usize) usize {
    if (size < 32) {
        dst[0] = block_type | @as(u8, @intCast(size)) << 3;
        return 1;
    } else if (size < 4096) {
        std.mem.writeInt(u16, dst[0..2], @intCast(block_type | 1 << 2 | size << 4), .little);
        return 2;
    } else {
        std.mem.writeInt(u24, dst[0..3], @intCast(block_type | 3 << 2 | size << 4), .little);
        return 3;
    }
}

fn writeRawLiterals(dst: []u8, lits: []const u8) usize {
    const n = writeLiteralsHeader(dst, 0, lits.len);
    @memcpy(dst[n..][0..lits.len], lits);
    return n + lits.len;
}

fn llCode(ll: u32) u8 {
    const table = comptime codeTable(64, &zstd.literals_length_code_table, 0);
    return if (ll > 63) @as(u8, std.math.log2_int(u32, ll)) + 19 else table[ll];
}

fn mlCode(ml_base: u32) u8 {
    const table = comptime codeTable(128, &zstd.match_length_code_table, 3);
    return if (ml_base > 127) @as(u8, std.math.log2_int(u32, ml_base)) + 36 else table[ml_base];
}

/// Inverts a code table (baseline, extra bits) into a value-to-code lookup.
fn codeTable(comptime n: usize, codes: []const struct { u32, u5 }, comptime bias: u32) [n]u8 {
    @setEvalBranchQuota(10000);
    var t: [n]u8 = undefined;
    for (codes, 0..) |entry, code| {
        const lo = entry[0] - bias;
        const hi = lo + (@as(u32, 1) << entry[1]);
        var v = lo;
        while (v < hi and v < n) : (v += 1) t[v] = code;
    }
    return t;
}

inline fn read32(base: [*]const u8, i: usize) u32 {
    return std.mem.readInt(u32, base[i..][0..4], .little);
}

inline fn read64(base: [*]const u8, i: usize) u64 {
    return std.mem.readInt(u64, base[i..][0..8], .little);
}

/// Mirrors zstd_compress_internal.h:ZSTD_hashPtr.
inline fn hashAt(base: [*]const u8, i: usize, hlog: u5, comptime mls: u32) usize {
    if (mls == 4) {
        return (read32(base, i) *% 2654435761) >> @intCast(32 - @as(u6, hlog));
    }
    const prime: u64 = switch (mls) {
        5 => 889523592379,
        6 => 227718039650203,
        7 => 58295818150454627,
        else => 0xCF1BBCDCB7A56463,
    };
    const v = if (mls == 8) read64(base, i) else read64(base, i) << (64 - 8 * mls);
    return @intCast((v *% prime) >> @intCast(64 - @as(u7, hlog)));
}

/// Mirrors zstd_compress_internal.h:ZSTD_count.
inline fn count(base: [*]const u8, a0: usize, b0: usize, end: usize) usize {
    var a = a0;
    var b = b0;
    while (a + 8 <= end) {
        const d = read64(base, a) ^ read64(base, b);
        if (d != 0) return a - a0 + @ctz(d) / 8;
        a += 8;
        b += 8;
    }
    while (a < end and base[a] == base[b]) {
        a += 1;
        b += 1;
    }
    return a - a0;
}

/// Forward bit writer for streams the decoder reads backwards (RFC 8878
/// §4.1). `buf` needs 8 bytes of slack past the data: flushes store a whole word.
const BitWriter = struct {
    buf: []u8,
    pos: usize = 0,
    acc: u64 = 0,
    n: u32 = 0,

    /// `v` must fit in `nb` bits.
    inline fn addFast(b: *BitWriter, v: u64, nb: u32) void {
        b.acc |= v << @intCast(b.n);
        b.n += nb;
    }

    inline fn add(b: *BitWriter, v: u64, nb: u32) void {
        const mask = (@as(u64, 1) << @intCast(nb)) - 1;
        b.addFast(v & mask, nb);
    }

    inline fn flush(b: *BitWriter) void {
        std.mem.writeInt(u64, b.buf[b.pos..][0..8], b.acc, .little);
        const k = b.n >> 3;
        b.pos += k;
        b.acc >>= @intCast(k * 8);
        b.n &= 7;
    }

    /// The final 1 bit marks where the stream starts for the reader.
    fn close(b: *BitWriter) usize {
        b.add(1, 1);
        b.flush();
        return b.pos + @intFromBool(b.n > 0);
    }
};

/// Mirrors fse_compress.c's FSE_CTable: `state` maps a cumulative symbol slot
/// to the next state, `tt` holds per-symbol deltas.
const FseCTable = struct {
    table_log: u32,
    state: [1 << fse_max_log]u16,
    tt: [64]SymbolTransform,

    const SymbolTransform = struct { delta_find_state: i32, delta_nb_bits: u32 };

    /// Mirrors fse_compress.c:FSE_buildCTable_wksp; the spread must match the
    /// decoder's (RFC 8878 §4.1.1).
    fn build(t: *FseCTable, norm: []const i16, table_log: u32) void {
        const size: u32 = @as(u32, 1) << @intCast(table_log);
        const mask = size - 1;
        const step = (size >> 1) + (size >> 3) + 3;
        var symbols: [1 << fse_max_log]u8 = undefined;
        var cumul: [65]u32 = undefined;
        var high = size - 1;
        t.table_log = table_log;
        cumul[0] = 0;
        for (norm, 0..) |n, s| {
            if (n == -1) {
                cumul[s + 1] = cumul[s] + 1;
                symbols[high] = @intCast(s);
                high -%= 1;
            } else {
                cumul[s + 1] = cumul[s] + @as(u32, @intCast(n));
            }
        }
        var pos: u32 = 0;
        for (norm, 0..) |n, s| {
            if (n <= 0) continue;
            for (0..@intCast(n)) |_| {
                symbols[pos] = @intCast(s);
                pos = (pos + step) & mask;
                while (pos > high) pos = (pos + step) & mask;
            }
        }
        assert(pos == 0);
        for (0..size) |u| {
            const s = symbols[u];
            t.state[cumul[s]] = @intCast(size + u);
            cumul[s] += 1;
        }
        var total: i32 = 0;
        for (norm, 0..) |n, s| {
            switch (n) {
                0 => t.tt[s] = .{ .delta_find_state = 0, .delta_nb_bits = ((table_log + 1) << 16) - size },
                -1, 1 => {
                    t.tt[s] = .{ .delta_find_state = total - 1, .delta_nb_bits = (table_log << 16) - size };
                    total += 1;
                },
                else => {
                    const nn: u32 = @intCast(n);
                    const max_bits_out = table_log - std.math.log2_int(u32, nn - 1);
                    const min_state_plus = nn << @intCast(max_bits_out);
                    t.tt[s] = .{ .delta_find_state = total - n, .delta_nb_bits = (max_bits_out << 16) - min_state_plus };
                    total += n;
                },
            }
        }
    }

    /// Mirrors fse_compress.c:FSE_buildCTable_rle: no state bits at all.
    fn buildRle(t: *FseCTable, symbol: u8) void {
        t.table_log = 0;
        t.state[0] = 0;
        t.state[1] = 0;
        t.tt[symbol] = .{ .delta_find_state = 0, .delta_nb_bits = 0 };
    }
};

const FseState = struct {
    value: u32,
    t: *const FseCTable,

    /// Mirrors FSE_initCState2: start in the cheapest state for the symbol.
    inline fn init(t: *const FseCTable, symbol: u8) FseState {
        const tt = t.tt[symbol];
        const nb = (tt.delta_nb_bits +% (1 << 15)) >> 16;
        const v = (nb << 16) -% tt.delta_nb_bits;
        const idx: i32 = @as(i32, @intCast(v >> @intCast(nb))) + tt.delta_find_state;
        return .{ .value = t.state[@intCast(idx)], .t = t };
    }

    inline fn encode(s: *FseState, bw: *BitWriter, symbol: u8) void {
        const tt = s.t.tt[symbol];
        const nb = (s.value +% tt.delta_nb_bits) >> 16;
        bw.add(s.value, nb);
        const idx: i32 = @as(i32, @intCast(s.value >> @intCast(nb))) + tt.delta_find_state;
        s.value = s.t.state[@intCast(idx)];
    }

    inline fn flushState(s: *FseState, bw: *BitWriter) void {
        bw.add(s.value, s.t.table_log);
        bw.flush();
    }
};

fn highbit(x: usize) i32 {
    return std.math.log2_int(usize, @max(x, 1));
}

/// Mirrors fse_compress.c:FSE_optimalTableLog_internal.
fn optimalTableLog(max_log: u32, src_size: usize, max_sym: usize, minus: i32) u32 {
    const max_bits_src = highbit(src_size - 1) - minus;
    const min_bits = @min(highbit(src_size) + 1, highbit(max_sym) + 2);
    var tl: i32 = @intCast(max_log);
    if (max_bits_src < tl) tl = max_bits_src;
    if (min_bits > tl) tl = min_bits;
    tl = std.math.clamp(tl, 5, 12);
    return @min(@as(u32, @intCast(tl)), max_log);
}

/// Mirrors fse_compress.c:FSE_normalizeCount. Returns false when the result
/// is unusable (the caller then picks another encoding).
fn normalizeCount(norm: []i16, table_log: u32, counts: []const u32, total: usize, low_prob: bool) bool {
    const rtb = [8]u64{ 0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 };
    const low_prob_count: i16 = if (low_prob) -1 else 1;
    const scale: u6 = @intCast(62 - table_log);
    const step: u64 = (@as(u64, 1) << 62) / total;
    const vstep: u64 = @as(u64, 1) << (scale - 20);
    var still: i32 = @as(i32, 1) << @intCast(table_log);
    var largest: usize = 0;
    var largest_p: i16 = 0;
    const low_threshold = total >> @intCast(table_log);
    for (counts, 0..) |n, s| {
        if (n == total) return false;
        if (n == 0) {
            norm[s] = 0;
            continue;
        }
        if (n <= low_threshold) {
            norm[s] = low_prob_count;
            still -= 1;
        } else {
            const scaled = @as(u64, n) * step;
            var proba: i16 = @intCast(scaled >> scale);
            if (proba < 8) {
                const rest = vstep * rtb[@intCast(proba)];
                proba += @intFromBool(scaled - (@as(u64, @intCast(proba)) << scale) > rest);
            }
            if (proba > largest_p) {
                largest_p = proba;
                largest = s;
            }
            norm[s] = proba;
            still -= proba;
        }
    }
    if (-still >= (norm[largest] >> 1)) {
        if (!normalizeM2(norm, table_log, counts, total, low_prob_count)) return false;
    } else {
        norm[largest] += @intCast(still);
    }
    var sum: i32 = 0;
    for (norm, counts) |p, n| {
        if (n != 0 and p == 0) return false;
        sum += @abs(p);
    }
    return sum == @as(i32, 1) << @intCast(table_log);
}

/// Mirrors fse_compress.c:FSE_normalizeM2, the fallback for skewed inputs.
fn normalizeM2(norm: []i16, table_log: u32, counts: []const u32, total_in: usize, low_prob_count: i16) bool {
    const not_yet: i16 = -2;
    var total: u64 = total_in;
    var distributed: u32 = 0;
    const low_threshold = total >> @intCast(table_log);
    var low_one = (total * 3) >> @intCast(table_log + 1);
    for (counts, 0..) |n, s| {
        if (n == 0) {
            norm[s] = 0;
        } else if (n <= low_threshold) {
            norm[s] = low_prob_count;
            distributed += 1;
            total -= n;
        } else if (n <= low_one) {
            norm[s] = 1;
            distributed += 1;
            total -= n;
        } else norm[s] = not_yet;
    }
    var to_distribute: u32 = (@as(u32, 1) << @intCast(table_log)) - distributed;
    if (to_distribute == 0) return true;
    if (total / to_distribute > low_one) {
        low_one = (total * 3) / (to_distribute * 2);
        for (counts, 0..) |n, s| {
            if (norm[s] == not_yet and n <= low_one) {
                norm[s] = 1;
                distributed += 1;
                total -= n;
            }
        }
        to_distribute = (@as(u32, 1) << @intCast(table_log)) - distributed;
    }
    if (distributed == counts.len) {
        var max_v: usize = 0;
        var max_c: u32 = 0;
        for (counts, 0..) |n, s| if (n > max_c) {
            max_v = s;
            max_c = n;
        };
        norm[max_v] += @intCast(to_distribute);
        return true;
    }
    if (total == 0) {
        var s: usize = 0;
        while (to_distribute > 0) : (s = (s + 1) % counts.len) {
            if (norm[s] > 0) {
                to_distribute -= 1;
                norm[s] += 1;
            }
        }
        return true;
    }
    const v_step_log: u6 = @intCast(62 - table_log);
    const mid: u64 = (@as(u64, 1) << (v_step_log - 1)) - 1;
    const r_step: u64 = ((@as(u64, 1) << v_step_log) * to_distribute + mid) / total;
    var tmp_total: u64 = mid;
    for (counts, 0..) |n, s| {
        if (norm[s] == not_yet) {
            const end = tmp_total + n * r_step;
            const s_start: u32 = @intCast(tmp_total >> v_step_log);
            const s_end: u32 = @intCast(end >> v_step_log);
            const weight = s_end - s_start;
            if (weight < 1) return false;
            norm[s] = @intCast(weight);
            tmp_total = end;
        }
    }
    return true;
}

/// Mirrors fse_compress.c:FSE_writeNCount_generic (RFC 8878 §4.1.1).
fn writeNCount(dst: []u8, norm: []const i16, table_log: u32) usize {
    const size: i32 = @as(i32, 1) << @intCast(table_log);
    var out: usize = 0;
    var bits: u32 = table_log - 5;
    var nbits: u5 = 4;
    var remaining: i32 = size + 1;
    var threshold: i32 = size;
    var nb: u5 = @intCast(table_log + 1);
    var symbol: usize = 0;
    var prev0 = false;
    while (symbol < norm.len and remaining > 1) {
        if (prev0) {
            var start = symbol;
            while (symbol < norm.len and norm[symbol] == 0) symbol += 1;
            if (symbol == norm.len) break;
            while (symbol >= start + 24) {
                start += 24;
                bits += @as(u32, 0xFFFF) << nbits;
                dst[out] = @truncate(bits);
                dst[out + 1] = @truncate(bits >> 8);
                out += 2;
                bits >>= 16;
            }
            while (symbol >= start + 3) {
                start += 3;
                bits += @as(u32, 3) << nbits;
                nbits += 2;
            }
            bits += @as(u32, @intCast(symbol - start)) << nbits;
            nbits += 2;
            if (nbits > 16) {
                dst[out] = @truncate(bits);
                dst[out + 1] = @truncate(bits >> 8);
                out += 2;
                bits >>= 16;
                nbits -= 16;
            }
        }
        var n: i32 = norm[symbol];
        symbol += 1;
        const max = (2 * threshold - 1) - remaining;
        remaining -= @intCast(@abs(n));
        n += 1;
        if (n >= threshold) n += max;
        bits += @as(u32, @intCast(n)) << nbits;
        nbits += nb;
        nbits -= @intFromBool(n < max);
        prev0 = n == 1;
        assert(remaining >= 1);
        while (remaining < threshold) {
            nb -= 1;
            threshold >>= 1;
        }
        if (nbits > 16) {
            dst[out] = @truncate(bits);
            dst[out + 1] = @truncate(bits >> 8);
            out += 2;
            bits >>= 16;
            nbits -= 16;
        }
    }
    assert(remaining == 1);
    dst[out] = @truncate(bits);
    dst[out + 1] = @truncate(bits >> 8);
    return out + (@as(usize, nbits) + 7) / 8;
}

/// Huffman code for literals (RFC 8878 §4.2): canonical, at most 11 bits.
const Huffman = struct {
    code: [256]u16,
    len: [256]u8,
    max_len: u8,
    max_sym: usize,

    /// Optimal lengths by the two-queue method, then limited to `max_bits`
    /// by lengthening the rarest codes and shortening the most frequent ones
    /// until the code is complete again (zstd derives the last weight from
    /// completeness).
    fn build(h: *Huffman, counts: *const [256]u32, max_sym: usize, max_bits: u32) void {
        h.max_sym = max_sym;
        @memset(&h.len, 0);
        @memset(&h.code, 0);
        var syms: [256]u8 = undefined;
        var n: usize = 0;
        for (counts[0 .. max_sym + 1], 0..) |cnt, s| if (cnt > 0) {
            syms[n] = @intCast(s);
            n += 1;
        };
        assert(n >= 2);
        std.mem.sort(u8, syms[0..n], counts, struct {
            fn lessThan(c: *const [256]u32, a: u8, b: u8) bool {
                return c[a] < c[b] or (c[a] == c[b] and a < b);
            }
        }.lessThan);

        var weight: [512]u32 = undefined;
        var parent: [512]u16 = undefined;
        for (syms[0..n], 0..) |s, i| weight[i] = counts[s];
        var leaf: usize = 0;
        var node: usize = n;
        for (n..2 * n - 1) |next| {
            var pick: [2]usize = undefined;
            for (&pick) |*p| {
                if (leaf < n and (node >= next or weight[leaf] <= weight[node])) {
                    p.* = leaf;
                    leaf += 1;
                } else {
                    p.* = node;
                    node += 1;
                }
            }
            weight[next] = weight[pick[0]] + weight[pick[1]];
            parent[pick[0]] = @intCast(next);
            parent[pick[1]] = @intCast(next);
        }
        var depth: [512]u8 = undefined;
        depth[2 * n - 2] = 0;
        var i = 2 * n - 2;
        var max_len: u8 = 0;
        while (i > 0) {
            i -= 1;
            depth[i] = depth[parent[i]] + 1;
        }
        for (syms[0..n], 0..) |s, k| {
            h.len[s] = depth[k];
            max_len = @max(max_len, depth[k]);
        }

        if (max_len > max_bits) {
            const mb: u5 = @intCast(max_bits);
            const cap: u32 = @as(u32, 1) << mb;
            var kraft: u32 = 0;
            for (syms[0..n]) |s| {
                h.len[s] = @min(h.len[s], mb);
                kraft += @as(u32, 1) << @intCast(mb - h.len[s]);
            }
            while (kraft > cap) {
                for (syms[0..n]) |s| {
                    if (h.len[s] < mb) {
                        h.len[s] += 1;
                        kraft -= @as(u32, 1) << @intCast(mb - h.len[s]);
                        if (kraft <= cap) break;
                    }
                }
            }
            while (kraft < cap) {
                var k = n;
                while (k > 0) {
                    k -= 1;
                    const s = syms[k];
                    while (h.len[s] > 1 and kraft + (@as(u32, 1) << @intCast(mb - h.len[s])) <= cap) {
                        kraft += @as(u32, 1) << @intCast(mb - h.len[s]);
                        h.len[s] -= 1;
                    }
                }
            }
            max_len = 0;
            for (syms[0..n]) |s| max_len = @max(max_len, h.len[s]);
        }
        h.max_len = max_len;

        // Canonical codes: longest codes get the lowest values, ties by symbol.
        var per_len: [16]u16 = @splat(0);
        for (h.len[0 .. max_sym + 1]) |l| per_len[l] += 1;
        var next_code: [16]u16 = undefined;
        var code: u16 = 0;
        var l: usize = max_len;
        while (l > 0) : (l -= 1) {
            next_code[l] = code;
            code = (code + per_len[l]) >> 1;
        }
        for (h.len[0 .. max_sym + 1], 0..) |len, s| {
            if (len == 0) continue;
            h.code[s] = next_code[len];
            next_code[len] += 1;
        }
    }

    /// Mirrors huf_compress.c:HUF_validateCTable: every present symbol has a code.
    fn covers(h: *const Huffman, counts: *const [256]u32, max_sym: usize) bool {
        for (counts[0 .. max_sym + 1], h.len[0 .. max_sym + 1]) |n, l| if (n != 0 and l == 0) return false;
        return true;
    }

    /// Mirrors huf_compress.c:HUF_estimateCompressedSize, in bytes.
    fn cost(h: *const Huffman, counts: *const [256]u32) usize {
        var bits: usize = 0;
        for (counts, h.len) |n, l| bits += @as(usize, n) * l;
        return bits >> 3;
    }

    /// Mirrors huf_compress.c:HUF_writeCTable: FSE-compressed weights when
    /// that is smaller, else 4-bit weights. The last symbol's weight is implied.
    fn writeTable(h: *const Huffman, dst: []u8) ?usize {
        const n = h.max_sym;
        var weights: [256]u8 = undefined;
        for (h.len[0..n], 0..) |l, s| weights[s] = if (l == 0) 0 else h.max_len + 1 - l;
        var tmp: [512]u8 = undefined;
        const fse_size = compressWeights(&tmp, weights[0..n]);
        if (fse_size > 1 and fse_size < n / 2) {
            dst[0] = @intCast(fse_size);
            @memcpy(dst[1..][0..fse_size], tmp[0..fse_size]);
            return fse_size + 1;
        }
        if (n > 128) return null;
        dst[0] = @intCast(127 + n);
        weights[n] = 0;
        var k: usize = 0;
        while (k < n) : (k += 2) dst[1 + k / 2] = weights[k] << 4 | weights[k + 1];
        return 1 + (n + 1) / 2;
    }

    /// Literals are written last to first so the decoder, reading backwards,
    /// produces them in order.
    fn encodeStream(h: *const Huffman, dst: []u8, src: []const u8) usize {
        var elts: [256]u32 = undefined;
        for (&elts, h.code, h.len) |*e, code, len| e.* = @as(u32, code) << 8 | len;
        var bw: BitWriter = .{ .buf = dst };
        var i = src.len;
        while (i & 3 != 0) {
            i -= 1;
            const e = elts[src[i]];
            bw.addFast(e >> 8, e & 0xff);
        }
        bw.flush();
        while (i > 0) {
            i -= 4;
            inline for (.{ 3, 2, 1, 0 }) |k| {
                const e = elts[src[i + k]];
                bw.addFast(e >> 8, e & 0xff);
            }
            bw.flush();
        }
        return bw.close();
    }
};

/// Mirrors huf_compress.c:HUF_compressWeights: FSE with two interleaved
/// states sharing one table (RFC 8878 §4.2.1.2). Returns 0 or 1 when not
/// worth it.
fn compressWeights(dst: []u8, weights: []const u8) usize {
    var counts: [16]u32 = @splat(0);
    for (weights) |w| counts[w] += 1;
    var max_w: usize = 15;
    while (counts[max_w] == 0) max_w -= 1;
    const most = std.mem.max(u32, counts[0 .. max_w + 1]);
    if (most == weights.len) return 1;
    if (most == 1) return 0;
    const table_log = optimalTableLog(6, weights.len, max_w, 2);
    var norm: [16]i16 = undefined;
    if (!normalizeCount(norm[0 .. max_w + 1], table_log, counts[0 .. max_w + 1], weights.len, false)) return 0;
    var op = writeNCount(dst, norm[0 .. max_w + 1], table_log);
    var table: FseCTable = undefined;
    table.build(norm[0 .. max_w + 1], table_log);

    var bw: BitWriter = .{ .buf = dst[op..] };
    const n = weights.len;
    // State 0 encodes even indices and is read first, so it is flushed last.
    var states: [2]FseState = undefined;
    states[(n - 1) & 1] = .init(&table, weights[n - 1]);
    states[(n - 2) & 1] = .init(&table, weights[n - 2]);
    var i = n - 2;
    while (i > 0) {
        i -= 1;
        states[i & 1].encode(&bw, weights[i]);
        bw.flush();
    }
    states[1].flushState(&bw);
    states[0].flushState(&bw);
    op += bw.close();
    return op;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testCompress(data: []const u8, options: Options, chunk: usize) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Compressor = try .init(testing.allocator, &out.writer, options);
    defer c.deinit();
    var i: usize = 0;
    while (i < data.len) {
        const n = @min(chunk, data.len - i);
        try c.writer.writeAll(data[i..][0..n]);
        i += n;
    }
    try c.finish();
    return out.toOwnedSlice();
}

/// Decodes as much as `compressed` allows; a truncated frame (as after a
/// flush) ends with `error.EndOfStream` recorded by the decoder.
fn testDecompress(compressed: []const u8, complete: bool) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var d: zstd.Decompress = .init(&in, &.{}, .{});
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    if (d.reader.streamRemaining(&out.writer)) |_| {
        if (!complete) try testing.expectEqual(@as(usize, 0), compressed.len);
    } else |err| {
        try testing.expectEqual(error.ReadFailed, err);
        if (complete) {
            std.debug.print("decode error: {?}\n", .{d.err});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(error.EndOfStream, d.err.?);
    }
    return out.toOwnedSlice();
}

fn testRoundTrip(data: []const u8, options: Options, chunk: usize) !usize {
    const compressed = try testCompress(data, options, chunk);
    defer testing.allocator.free(compressed);
    const decompressed = try testDecompress(compressed, true);
    defer testing.allocator.free(decompressed);
    try testing.expectEqualSlices(u8, data, decompressed);
    return compressed.len;
}

/// Text-like data: words from a small vocabulary mixed with numbers.
fn fillText(buf: []u8, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const words = [_][]const u8{
        "nix",    "store", "derivation", "/nix/store/", "lib",   "bin", "share", "the",
        "output", "hash",  "sha256-",    "build",       "input", "\n",  "{\n  ", "\"",
    };
    var i: usize = 0;
    while (i < buf.len) {
        if (r.uintLessThan(u8, 8) == 0) {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d} ", .{r.int(u32)}) catch unreachable;
            const n = @min(s.len, buf.len - i);
            @memcpy(buf[i..][0..n], s[0..n]);
            i += n;
        } else {
            const w = words[r.uintLessThan(usize, words.len)];
            const n = @min(w.len, buf.len - i);
            @memcpy(buf[i..][0..n], w[0..n]);
            i += n;
            if (i < buf.len) {
                buf[i] = ' ';
                i += 1;
            }
        }
    }
}

test "empty input" {
    const compressed = try testCompress("", .{}, 1);
    defer testing.allocator.free(compressed);
    try testing.expectEqual(@as(usize, 9), compressed.len);
    const d = try testDecompress(compressed, true);
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}

test "small inputs" {
    var buf: [300]u8 = undefined;
    fillText(&buf, 1);
    for ([_]usize{ 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 63, 64, 65, 100, 255, 256, 300 }) |n| {
        _ = try testRoundTrip(buf[0..n], .{}, 7);
        _ = try testRoundTrip(buf[0..n], .{}, n);
    }
    _ = try testRoundTrip("abcabcabcabcabcabcabcabcabcabcabcabc", .{}, 100);
}

test "highly repetitive input" {
    const zeros = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(zeros);
    @memset(zeros, 0);
    const size = try testRoundTrip(zeros, .{}, 1 << 20);
    try testing.expect(size < 100);

    for (zeros, 0..) |*b, i| b.* = "0123456789abcdef"[i % 16];
    try testing.expect(try testRoundTrip(zeros, .{}, 4096) < 1000);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Compressor = try .init(testing.allocator, &out.writer, .{});
    defer c.deinit();
    try c.writer.splatByteAll('x', 3 << 20);
    try c.writer.print("{d} and then {s}", .{ 12345, "more" });
    try c.finish();
    const d = try testDecompress(out.written(), true);
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, (3 << 20) + 19), d.len);
    try testing.expectEqualStrings("12345 and then more", d[3 << 20 ..]);
    for (d[0 .. 3 << 20]) |b| try testing.expectEqual('x', b);
}

test "random input" {
    const data = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(data);
    var prng: std.Random.DefaultPrng = .init(42);
    prng.random().bytes(data);
    const size = try testRoundTrip(data, .{}, 65536);
    // Raw blocks: 3 bytes per 128 KiB block plus the frame header.
    try testing.expect(size <= data.len + 6 + 3 * 9);
    // Low-entropy random symbols take the Huffman-only path.
    for (data) |*b| b.* = "abcdefgh"[b.* & 7];
    try testing.expect(try testRoundTrip(data, .{}, 65536) < data.len / 2);
}

test "multi-block inputs" {
    const data = try testing.allocator.alloc(u8, 6 << 20);
    defer testing.allocator.free(data);
    fillText(data[0 .. 1 << 20], 7);
    // Copies at long distances exercise far offsets and the window slide.
    @memcpy(data[1 << 20 .. 2 << 20], data[0 .. 1 << 20]);
    var prng: std.Random.DefaultPrng = .init(3);
    prng.random().bytes(data[2 << 20 .. 3 << 20]);
    fillText(data[3 << 20 .. 5 << 20], 8);
    @memcpy(data[5 << 20 .. 6 << 20], data[(5 << 20) - 1900000 ..][0 .. 1 << 20]);
    for ([_]Options{ .{}, .{ .window_log = 17 }, .{ .window_log = 23, .hash_log = 17, .min_match = 4 }, .{ .min_match = 7 }, .{ .min_match = 5 }, .{ .min_match = 8, .hash_log = 12 } }) |o| {
        const size = try testRoundTrip(data, o, 1 << 20);
        try testing.expect(size < data.len / 2);
    }
    _ = try testRoundTrip(data[0 .. 3 << 20], .{}, 999);
}

test "flush in the middle" {
    const data = try testing.allocator.alloc(u8, 3 << 20);
    defer testing.allocator.free(data);
    fillText(data, 11);
    @memcpy(data[2 << 20 ..], data[0 .. 1 << 20]);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Compressor = try .init(testing.allocator, &out.writer, .{});
    defer c.deinit();
    const cuts = [_]usize{ 0, 0, 1, 5, 100, 70000, 70000, 200000, 1 << 20, (1 << 20) + 3, 2 << 20, (5 << 19) + 77 };
    var prev: usize = 0;
    for (cuts) |cut| {
        try c.writer.writeAll(data[prev..cut]);
        prev = cut;
        try c.flush();
        const d = try testDecompress(out.written(), false);
        defer testing.allocator.free(d);
        try testing.expectEqualSlices(u8, data[0..cut], d);
    }
    try c.writer.writeAll(data[prev..]);
    try c.finish();
    const d = try testDecompress(out.written(), true);
    defer testing.allocator.free(d);
    try testing.expectEqualSlices(u8, data, d);
}

/// Mixed data: text, random bytes, zeros and far copies.
fn fillMixed(data: []u8, seed: u64) void {
    const q = data.len / 5;
    fillText(data[0 .. 3 * q], seed);
    var prng: std.Random.DefaultPrng = .init(seed +% 1);
    prng.random().bytes(data[3 * q .. 4 * q]);
    @memset(data[4 * q ..][0 .. q / 3], 0);
    @memcpy(data[4 * q + q / 3 ..], data[100..][0 .. data.len - 4 * q - q / 3]);
}

/// Compresses with a flush after every `flush_every`-ish bytes (0: none).
fn testCompressFlushing(data: []const u8, options: Options, flush_every: usize, seed: u64) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Compressor = try .init(testing.allocator, &out.writer, options);
    defer c.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    var i: usize = 0;
    while (i < data.len) {
        const n = if (flush_every == 0) data.len else @min(data.len - i, 1 + prng.random().uintLessThan(usize, 2 * flush_every));
        try c.writer.writeAll(data[i..][0..n]);
        i += n;
        if (flush_every != 0) try c.flush();
    }
    try c.finish();
    return out.toOwnedSlice();
}

test "zstd command line decodes the output" {
    const io = testing.io;
    const data = try testing.allocator.alloc(u8, 5 << 20);
    defer testing.allocator.free(data);
    fillMixed(data, 5);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const configs = [_]struct { Options, usize }{
        .{ .{}, 0 },
        .{ .{}, 2 << 20 },
        .{ .{ .window_log = 23, .hash_log = 16, .min_match = 6 }, 0 },
        .{ .{ .window_log = 17, .min_match = 4 }, 50000 },
        .{ .{ .min_match = 5 }, 3000 },
    };
    for (configs, 0..) |config, k| {
        const compressed = try testCompressFlushing(data, config[0], config[1], k);
        defer testing.allocator.free(compressed);
        try tmp.dir.writeFile(io, .{ .sub_path = "data.zst", .data = compressed });
        const result = std.process.run(testing.allocator, io, .{
            .argv = &.{ "zstd", "-d", "-c", "-q", "data.zst" },
            .cwd = .{ .dir = tmp.dir },
            .stdout_limit = .limited(64 << 20),
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        if (!result.term.success()) {
            std.debug.print("zstd failed: {s}\n", .{result.stderr});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualSlices(u8, data, result.stdout);
        const d = try testDecompress(compressed, true);
        defer testing.allocator.free(d);
        try testing.expectEqualSlices(u8, data, d);
    }
}

test "many small flushes" {
    // Tiny blocks alternate between compressed, raw and RLE, which must keep
    // repeat offsets and the reused Huffman table in step with the decoder.
    const data = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(data);
    fillMixed(data, 21);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Compressor = try .init(testing.allocator, &out.writer, .{ .window_log = 17 });
    defer c.deinit();
    var prng: std.Random.DefaultPrng = .init(4);
    var i: usize = 0;
    var round: usize = 0;
    while (i < data.len) : (round += 1) {
        const n = @min(data.len - i, 1 + prng.random().uintLessThan(usize, 40000));
        try c.writer.writeAll(data[i..][0..n]);
        i += n;
        try c.flush();
        if (round % 8 == 0) {
            const d = try testDecompress(out.written(), false);
            defer testing.allocator.free(d);
            try testing.expectEqualSlices(u8, data[0..i], d);
        }
    }
    try c.finish();
    const d = try testDecompress(out.written(), true);
    defer testing.allocator.free(d);
    try testing.expectEqualSlices(u8, data, d);
}

test "writer rebase keeps pending bytes" {
    const data = try testing.allocator.alloc(u8, 3 << 20);
    defer testing.allocator.free(data);
    fillMixed(data, 33);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var c: Compressor = try .init(testing.allocator, &out.writer, .{});
    defer c.deinit();
    const w = &c.writer;
    var i: usize = 0;
    while (i < data.len) {
        const n = @min(data.len - i, 700000);
        try w.writeAll(data[i..][0..n]);
        i += n;
        const before = w.buffered().len;
        try w.rebase(1000, 1 << 20);
        try testing.expect(w.buffered().len >= @min(before, 1000));
        try testing.expect(w.buffer.len - w.end >= 1 << 20);
    }
    try c.finish();
    const d = try testDecompress(out.written(), true);
    defer testing.allocator.free(d);
    try testing.expectEqualSlices(u8, data, d);
}

test "huffman table descriptions" {
    // Many distinct literal values force FSE-compressed weights (more than
    // 128 symbols cannot use the direct form).
    const data = try testing.allocator.alloc(u8, 200000);
    defer testing.allocator.free(data);
    var prng: std.Random.DefaultPrng = .init(77);
    const r = prng.random();
    for (data) |*b| {
        const x = r.int(u16);
        b.* = if (x < 40000) @intCast(x % 7) else @truncate(x);
    }
    try testing.expect(try testRoundTrip(data, .{}, 200000) < data.len);
    for (data) |*b| b.* = @intCast(r.uintLessThan(u8, 100) + @as(u8, @intFromBool(r.boolean())) * 100);
    _ = try testRoundTrip(data, .{}, 200000);
}
