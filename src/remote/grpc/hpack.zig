//! HPACK header compression for HTTP/2 (RFC 7541).
//!
//! The decoder turns header blocks into a `HeaderList` (one byte buffer plus
//! offsets, so a block costs no per-field allocation); the encoder appends a
//! header block to a byte list and mirrors the dynamic table the peer keeps.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `CompressionError` is fatal to the connection (RFC 9113 §4.3).
/// `HeaderListTooLarge` is not: the block was fully processed, so the dynamic
/// table is still in sync and only the stream needs to be refused.
pub const Error = error{ CompressionError, HeaderListTooLarge, OutOfMemory };

/// The SETTINGS_HEADER_TABLE_SIZE every endpoint starts with (RFC 9113 §6.5.2).
pub const default_table_size: u32 = 4096;

/// RFC 7541 §4.1: an entry's size counts 32 octets on top of its strings.
const entry_overhead = 32;

/// Longest prefix-integer encoding of a `usize` (1 prefix byte + 10 for 64 bits).
const max_int_len = 11;

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

/// How the encoder represents a header (RFC 7541 §6.2).
pub const Indexing = enum {
    /// Indexes the headers that repeat on a gRPC connection, never indexes
    /// credentials, sends everything else without indexing.
    auto,
    incremental,
    without,
    /// For sensitive values: tells intermediaries never to index it either.
    never,
};

pub const Header = struct {
    /// Must already be lowercase (RFC 9113 §8.2.1).
    name: []const u8,
    value: []const u8,
    indexing: Indexing = .auto,
};

/// Decoded header fields. Fields from several blocks (headers, trailers)
/// can accumulate; `clearRetainingCapacity` between uses keeps the buffers.
pub const HeaderList = struct {
    bytes: std.ArrayList(u8) = .empty,
    fields: std.ArrayList(Slot) = .empty,

    /// A field's name starts at `off`, its value follows the name directly.
    pub const Slot = struct {
        off: usize,
        name_len: usize,
        value_len: usize,
        never_indexed: bool,
    };

    pub fn deinit(l: *HeaderList, gpa: Allocator) void {
        l.bytes.deinit(gpa);
        l.fields.deinit(gpa);
    }

    pub fn clearRetainingCapacity(l: *HeaderList) void {
        l.bytes.clearRetainingCapacity();
        l.fields.clearRetainingCapacity();
    }

    pub fn count(l: *const HeaderList) usize {
        return l.fields.items.len;
    }

    pub fn name(l: *const HeaderList, i: usize) []const u8 {
        const s = l.fields.items[i];
        return l.bytes.items[s.off..][0..s.name_len];
    }

    pub fn value(l: *const HeaderList, i: usize) []const u8 {
        const s = l.fields.items[i];
        return l.bytes.items[s.off + s.name_len ..][0..s.value_len];
    }

    /// Whether the peer sent the field as never-indexed (RFC 7541 §6.2.3); a
    /// proxy re-encoding it must keep that.
    pub fn neverIndexed(l: *const HeaderList, i: usize) bool {
        return l.fields.items[i].never_indexed;
    }

    /// The value of the first field called `n`.
    pub fn get(l: *const HeaderList, n: []const u8) ?[]const u8 {
        for (l.fields.items, 0..) |s, i| {
            if (s.name_len == n.len and std.mem.eql(u8, l.name(i), n)) return l.value(i);
        }
        return null;
    }
};

/// The dynamic table (RFC 7541 §2.3.2, §4). Entries live in a power-of-two
/// ring; their strings are packed in insertion order into one byte buffer,
/// so eviction is a pointer bump and compaction is one memmove.
const Table = struct {
    entries: []Entry = &.{},
    /// Ring index of the oldest entry.
    head: usize = 0,
    len: usize = 0,
    bytes: []u8 = &.{},
    /// Live strings occupy `bytes[start..end]`.
    start: usize = 0,
    end: usize = 0,
    /// RFC 7541 §4.1 size.
    size: usize = 0,
    max_size: usize,

    const Entry = struct { off: usize, name_len: usize, value_len: usize };

    fn deinit(t: *Table, gpa: Allocator) void {
        gpa.free(t.entries);
        gpa.free(t.bytes);
        t.* = undefined;
    }

    /// `i` counts from the newest entry, 0-based (HPACK index 62 + i).
    fn at(t: *const Table, i: usize) Field {
        const e = t.entries[(t.head + t.len - 1 - i) & (t.entries.len - 1)];
        return .{
            .name = t.bytes[e.off..][0..e.name_len],
            .value = t.bytes[e.off + e.name_len ..][0..e.value_len],
        };
    }

    fn evictOldest(t: *Table) void {
        const e = t.entries[t.head];
        t.size -= e.name_len + e.value_len + entry_overhead;
        t.len -= 1;
        if (t.len == 0) {
            t.head = 0;
            t.start = 0;
            t.end = 0;
        } else {
            t.head = (t.head + 1) & (t.entries.len - 1);
            t.start = t.entries[t.head].off;
        }
    }

    /// RFC 7541 §4.3.
    fn setMaxSize(t: *Table, n: usize) void {
        t.max_size = n;
        while (t.size > n) t.evictOldest();
    }

    /// RFC 7541 §4.4. `n` and `v` must not point into the table: eviction and
    /// compaction move its bytes.
    fn insert(t: *Table, gpa: Allocator, n: []const u8, v: []const u8) Allocator.Error!void {
        const len = n.len + v.len;
        if (len + entry_overhead > t.max_size) {
            while (t.len > 0) t.evictOldest();
            return;
        }
        while (t.size + len + entry_overhead > t.max_size) t.evictOldest();
        if (t.len == t.entries.len) try t.growEntries(gpa);
        if (t.end + len > t.bytes.len) try t.makeRoom(gpa, len);
        @memcpy(t.bytes[t.end..][0..n.len], n);
        @memcpy(t.bytes[t.end + n.len ..][0..v.len], v);
        t.entries[(t.head + t.len) & (t.entries.len - 1)] = .{
            .off = t.end,
            .name_len = n.len,
            .value_len = v.len,
        };
        if (t.len == 0) t.start = t.end;
        t.len += 1;
        t.end += len;
        t.size += len + entry_overhead;
    }

    fn growEntries(t: *Table, gpa: Allocator) Allocator.Error!void {
        const new = try gpa.alloc(Entry, @max(16, t.entries.len * 2));
        for (0..t.len) |i| new[i] = t.entries[(t.head + i) & (t.entries.len - 1)];
        gpa.free(t.entries);
        t.entries = new;
        t.head = 0;
    }

    /// Moves the live strings to the front, into a larger buffer unless the
    /// current one stays at most half full: that keeps compaction amortised
    /// O(1) per inserted byte and the buffer below twice the maximum size.
    fn makeRoom(t: *Table, gpa: Allocator, len: usize) Allocator.Error!void {
        const live = t.end - t.start;
        if ((live + len) * 2 <= t.bytes.len) {
            std.mem.copyForwards(u8, t.bytes[0..live], t.bytes[t.start..t.end]);
        } else {
            const new = try gpa.alloc(u8, @max(256, (live + len) * 2));
            @memcpy(new[0..live], t.bytes[t.start..t.end]);
            gpa.free(t.bytes);
            t.bytes = new;
        }
        for (0..t.len) |i| t.entries[(t.head + i) & (t.entries.len - 1)].off -= t.start;
        t.start = 0;
        t.end = live;
    }
};

pub const Decoder = struct {
    table: Table,
    /// The SETTINGS_HEADER_TABLE_SIZE we advertise: the bound for size updates.
    max_allowed: usize,
    /// Our SETTINGS_MAX_HEADER_LIST_SIZE (RFC 9113 §6.5.2 sizes).
    max_header_list_size: usize,
    /// Set when our setting dropped below the peer's table size: the next
    /// block must start with a size update (RFC 7541 §4.2).
    update_required: bool,

    /// `header_table_size` is the SETTINGS_HEADER_TABLE_SIZE we advertise.
    /// The peer's encoder starts at the protocol default of 4096, so a smaller
    /// setting obliges it to send a size update first.
    pub fn init(header_table_size: u32, max_header_list_size: u32) Decoder {
        return .{
            .table = .{ .max_size = @min(header_table_size, default_table_size) },
            .max_allowed = header_table_size,
            .max_header_list_size = max_header_list_size,
            .update_required = header_table_size < default_table_size,
        };
    }

    pub fn deinit(d: *Decoder, gpa: Allocator) void {
        d.table.deinit(gpa);
    }

    /// Call when the peer acknowledged a new SETTINGS_HEADER_TABLE_SIZE of ours.
    pub fn setMaxAllowed(d: *Decoder, header_table_size: u32) void {
        d.max_allowed = header_table_size;
        if (header_table_size < d.table.max_size) d.update_required = true;
    }

    /// Decodes one complete header block (HEADERS plus CONTINUATION payloads)
    /// and appends its fields to `out`. On error `out` is left as it was.
    /// RFC 7541 §6.
    pub fn decode(d: *Decoder, gpa: Allocator, block: []const u8, out: *HeaderList) Error!void {
        const bytes_mark = out.bytes.items.len;
        const fields_mark = out.fields.items.len;
        errdefer {
            out.bytes.items.len = bytes_mark;
            out.fields.items.len = fields_mark;
        }

        var p: usize = 0;
        // RFC 7541 §4.2: size updates are only allowed at the start of a block.
        var updated = false;
        while (p < block.len and block[p] & 0xe0 == 0x20) {
            const n = try decodeInt(block, &p, 5);
            if (n > d.max_allowed) return error.CompressionError;
            d.table.setMaxSize(n);
            updated = true;
        }
        if (d.update_required) {
            if (!updated) return error.CompressionError;
            d.update_required = false;
        }

        var list_size: usize = 0;
        // Past the limit the block is still decoded to keep the table in sync.
        var too_large = false;
        while (p < block.len) {
            const b = block[p];
            const start = out.bytes.items.len;
            var name_len: usize = undefined;
            var value_len: usize = undefined;
            var never = false;
            if (b & 0x80 != 0) {
                // §6.1 indexed header field.
                const f = try d.field(try decodeInt(block, &p, 7));
                list_size += f.name.len + f.value.len + entry_overhead;
                if (too_large or list_size > d.max_header_list_size) {
                    too_large = true;
                    continue;
                }
                try out.bytes.ensureUnusedCapacity(gpa, f.name.len + f.value.len);
                out.bytes.appendSliceAssumeCapacity(f.name);
                out.bytes.appendSliceAssumeCapacity(f.value);
                name_len = f.name.len;
                value_len = f.value.len;
            } else {
                // §6.2 literal header field.
                var index_it = false;
                const idx = if (b & 0x40 != 0) blk: {
                    index_it = true;
                    break :blk try decodeInt(block, &p, 6);
                } else if (b & 0x20 != 0) {
                    return error.CompressionError;
                } else blk: {
                    never = b & 0x10 != 0;
                    break :blk try decodeInt(block, &p, 4);
                };
                if (idx == 0) {
                    name_len = try readString(gpa, block, &p, &out.bytes);
                } else {
                    const f = try d.field(idx);
                    try out.bytes.appendSlice(gpa, f.name);
                    name_len = f.name.len;
                }
                value_len = try readString(gpa, block, &p, &out.bytes);
                if (index_it) {
                    const s = out.bytes.items[start..];
                    try d.table.insert(gpa, s[0..name_len], s[name_len..][0..value_len]);
                }
                list_size += name_len + value_len + entry_overhead;
                if (too_large or list_size > d.max_header_list_size) {
                    too_large = true;
                    out.bytes.items.len = start;
                    continue;
                }
            }
            try out.fields.append(gpa, .{
                .off = start,
                .name_len = name_len,
                .value_len = value_len,
                .never_indexed = never,
            });
        }
        if (too_large) return error.HeaderListTooLarge;
    }

    /// RFC 7541 §2.3.3 index address space.
    fn field(d: *const Decoder, idx: usize) error{CompressionError}!Field {
        if (idx == 0) return error.CompressionError;
        if (idx <= static_table.len) return static_table[idx - 1];
        const i = idx - static_table.len - 1;
        if (i >= d.table.len) return error.CompressionError;
        return d.table.at(i);
    }
};

pub const Encoder = struct {
    table: Table,
    /// Our own cap on the table, whatever the peer allows.
    limit: usize,
    /// The table size the next block announces, if `pending_update`.
    target: usize,
    /// The smallest size since the last block: RFC 7541 §4.2 requires
    /// announcing it before `target` when it is lower.
    pending_min: usize,
    pending_update: bool,
    /// Huffman-codes strings where that is shorter; off only for tests.
    huffman: bool = true,

    /// `limit` caps the table memory spent on this connection. The peer's
    /// setting starts at the protocol default of 4096.
    pub fn init(limit: u32) Encoder {
        const target = @min(limit, default_table_size);
        return .{
            .table = .{ .max_size = default_table_size },
            .limit = limit,
            .target = target,
            .pending_min = target,
            .pending_update = target != default_table_size,
        };
    }

    pub fn deinit(e: *Encoder, gpa: Allocator) void {
        e.table.deinit(gpa);
    }

    /// Call when the peer's SETTINGS_HEADER_TABLE_SIZE arrives; the next
    /// block starts with the size update(s).
    pub fn setPeerMaxSize(e: *Encoder, header_table_size: u32) void {
        const new = @min(header_table_size, e.limit);
        if (!e.pending_update) {
            if (new == e.table.max_size) return;
            e.pending_update = true;
            e.pending_min = new;
        } else {
            e.pending_min = @min(e.pending_min, new);
        }
        e.target = new;
    }

    /// Appends the header block for `headers` to `out`. After an error the
    /// encoder may no longer match the peer's table: close the connection.
    pub fn encode(e: *Encoder, gpa: Allocator, headers: []const Header, out: *std.ArrayList(u8)) Allocator.Error!void {
        if (e.pending_update) {
            try out.ensureUnusedCapacity(gpa, 2 * max_int_len);
            if (e.pending_min < e.target) {
                putInt(out, 0x20, 5, e.pending_min);
                e.table.setMaxSize(e.pending_min);
            }
            putInt(out, 0x20, 5, e.target);
            e.table.setMaxSize(e.target);
            e.pending_update = false;
        }
        for (headers) |h| try e.encodeOne(gpa, h, out);
    }

    /// RFC 7541 §6.1, §6.2.
    fn encodeOne(e: *Encoder, gpa: Allocator, h: Header, out: *std.ArrayList(u8)) Allocator.Error!void {
        try out.ensureUnusedCapacity(gpa, h.name.len + h.value.len + 3 * max_int_len);
        const mode: Indexing = if (h.indexing == .auto) e.autoIndexing(h) else h.indexing;

        const st = staticLookup(h.name, h.value);
        if (mode != .never and st.exact) return putInt(out, 0x80, 7, st.index);
        var name_idx: usize = st.index;
        if (mode != .never or name_idx == 0) {
            const dy = e.findDynamic(h.name, h.value, mode != .never);
            if (dy.exact != 0) return putInt(out, 0x80, 7, dy.exact);
            if (name_idx == 0) name_idx = dy.name;
        }
        // The name index refers to the table before this insertion, as the
        // decoder resolves it before inserting.
        switch (mode) {
            .incremental => {
                try e.table.insert(gpa, h.name, h.value);
                putInt(out, 0x40, 6, name_idx);
            },
            .without => putInt(out, 0x00, 4, name_idx),
            .never => putInt(out, 0x10, 4, name_idx),
            .auto => unreachable,
        }
        if (name_idx == 0) e.putString(out, h.name);
        e.putString(out, h.value);
    }

    fn autoIndexing(e: *const Encoder, h: Header) Indexing {
        if (never_indexed_names.has(h.name)) return .never;
        const repeats = indexed_names.has(h.name) or
            (std.mem.startsWith(u8, h.name, "grpc-") and !std.mem.eql(u8, h.name, "grpc-timeout"));
        if (!repeats) return .without;
        // An entry near the table size would flush everything else out.
        const size = h.name.len + h.value.len + entry_overhead;
        return if (size * 4 <= e.table.max_size * 3) .incremental else .without;
    }

    const DynamicMatch = struct { exact: usize = 0, name: usize = 0 };

    fn findDynamic(e: *const Encoder, n: []const u8, v: []const u8, want_exact: bool) DynamicMatch {
        var m: DynamicMatch = .{};
        for (0..e.table.len) |i| {
            const f = e.table.at(i);
            if (!std.mem.eql(u8, f.name, n)) continue;
            const idx = static_table.len + 1 + i;
            if (m.name == 0) m.name = idx;
            if (!want_exact) return m;
            if (std.mem.eql(u8, f.value, v)) {
                m.exact = idx;
                return m;
            }
        }
        return m;
    }

    /// RFC 7541 §5.2. Capacity is reserved by the caller.
    fn putString(e: *const Encoder, out: *std.ArrayList(u8), s: []const u8) void {
        if (e.huffman) {
            const hl = huffmanEncodedLen(s);
            if (hl < s.len) {
                putInt(out, 0x80, 7, hl);
                huffmanEncode(s, out.unusedCapacitySlice()[0..hl]);
                out.items.len += hl;
                return;
            }
        }
        putInt(out, 0x00, 7, s.len);
        out.appendSliceAssumeCapacity(s);
    }
};

const indexed_names = std.StaticStringMap(void).initComptime(.{
    .{":authority"},
    .{":path"},
    .{"content-type"},
    .{"te"},
    .{"user-agent"},
    .{"x-nix-system"},
});

const never_indexed_names = std.StaticStringMap(void).initComptime(.{
    .{"authorization"},
    .{"proxy-authorization"},
});

/// HPACK index of the first static entry with each name; entries sharing a
/// name are adjacent in the static table.
const static_name_index = blk: {
    var kvs: []const struct { []const u8, u8 } = &.{};
    for (static_table, 1..) |f, i| {
        if (i > 1 and std.mem.eql(u8, static_table[i - 2].name, f.name)) continue;
        kvs = kvs ++ .{.{ f.name, @as(u8, i) }};
    }
    break :blk std.StaticStringMap(u8).initComptime(kvs);
};

const StaticMatch = struct { index: usize, exact: bool };

fn staticLookup(n: []const u8, v: []const u8) StaticMatch {
    const first = static_name_index.get(n) orelse return .{ .index = 0, .exact = false };
    var i: usize = first;
    while (i <= static_table.len and std.mem.eql(u8, static_table[i - 1].name, n)) : (i += 1) {
        if (std.mem.eql(u8, static_table[i - 1].value, v)) return .{ .index = i, .exact = true };
    }
    return .{ .index = first, .exact = false };
}

/// RFC 7541 §5.1. The caller guarantees `p.* < block.len`. Values are capped
/// at 2^32 - 1, far beyond any legitimate index or length.
fn decodeInt(block: []const u8, p: *usize, comptime prefix_bits: u4) error{CompressionError}!usize {
    const mask: u8 = (1 << prefix_bits) - 1;
    var v: u64 = block[p.*] & mask;
    p.* += 1;
    if (v < mask) return @intCast(v);
    var shift: u6 = 0;
    while (true) {
        if (p.* >= block.len) return error.CompressionError;
        const b = block[p.*];
        p.* += 1;
        v += @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
        if (shift > 28) return error.CompressionError;
    }
    if (v > std.math.maxInt(u32)) return error.CompressionError;
    return @intCast(v);
}

/// RFC 7541 §5.1. Capacity is reserved by the caller.
fn putInt(out: *std.ArrayList(u8), first: u8, comptime prefix_bits: u4, v: usize) void {
    const max_prefix: u8 = (1 << prefix_bits) - 1;
    if (v < max_prefix) {
        out.appendAssumeCapacity(first | @as(u8, @intCast(v)));
        return;
    }
    out.appendAssumeCapacity(first | max_prefix);
    var r = v - max_prefix;
    while (r >= 0x80) : (r >>= 7) out.appendAssumeCapacity(@as(u8, @truncate(r)) | 0x80);
    out.appendAssumeCapacity(@intCast(r));
}

/// RFC 7541 §5.2. Appends the decoded string to `buf`, returns its length.
fn readString(gpa: Allocator, block: []const u8, p: *usize, buf: *std.ArrayList(u8)) Error!usize {
    if (p.* >= block.len) return error.CompressionError;
    const huffman = block[p.*] & 0x80 != 0;
    const n = try decodeInt(block, p, 7);
    if (n > block.len - p.*) return error.CompressionError;
    const src = block[p.*..][0..n];
    p.* += n;
    if (!huffman) {
        try buf.appendSlice(gpa, src);
        return n;
    }
    // The shortest code is 5 bits; the decoder writes one byte past the end.
    try buf.ensureUnusedCapacity(gpa, n * 8 / 5 + 1);
    const k = try huffmanDecode(src, buf.unusedCapacitySlice());
    buf.items.len += k;
    return k;
}

/// Decodes `src` into `dst`, which holds at least `src.len * 8 / 5 + 1`
/// bytes. Rejects EOS and padding that is longer than 7 bits or not all
/// ones (RFC 7541 §5.2).
fn huffmanDecode(src: []const u8, dst: []u8) error{CompressionError}!usize {
    var state: u8 = 0;
    var flags: u8 = huff_accept;
    var n: usize = 0;
    for (src) |b| {
        inline for (.{ b >> 4, b & 0xf }) |nibble| {
            const t = huff_decode_table[state][nibble];
            if (t.flags & huff_fail != 0) return error.CompressionError;
            // Unconditional store keeps the loop branch-free.
            dst[n] = t.sym;
            n += t.flags & huff_emit;
            state = t.next;
            flags = t.flags;
        }
    }
    if (flags & huff_accept == 0) return error.CompressionError;
    return n;
}

fn huffmanEncodedLen(s: []const u8) usize {
    var bits: usize = 0;
    for (s) |c| bits += huffman_lens[c];
    return (bits + 7) / 8;
}

/// `dst.len` must be `huffmanEncodedLen(s)`. Pads with the EOS prefix.
fn huffmanEncode(s: []const u8, dst: []u8) void {
    // At most 7 pending bits plus a 30-bit code: fits in 64 bits.
    var acc: u64 = 0;
    var nbits: u6 = 0;
    var i: usize = 0;
    for (s) |c| {
        acc = (acc << @intCast(huffman_lens[c])) | huffman_codes[c];
        nbits += @intCast(huffman_lens[c]);
        while (nbits >= 8) {
            nbits -= 8;
            dst[i] = @truncate(acc >> nbits);
            i += 1;
        }
    }
    if (nbits > 0) {
        const pad: u6 = 8 - nbits;
        dst[i] = @truncate((acc << pad) | ((@as(u64, 1) << pad) - 1));
        i += 1;
    }
    std.debug.assert(i == dst.len);
}

const huff_emit: u8 = 1;
const huff_accept: u8 = 2;
const huff_fail: u8 = 4;

const HuffTransition = struct { next: u8, sym: u8, flags: u8 };

/// A 4-bit-at-a-time state machine over the code tree: states are the 256
/// internal nodes. Codes are at least 5 bits, so a nibble emits at most one
/// symbol. A state accepts the end of input when the bits since the last
/// symbol are at most 7 ones, i.e. valid padding.
const huff_decode_table: [256][16]HuffTransition = blk: {
    @setEvalBranchQuota(200_000);
    const leaf: u16 = 0x8000;
    var child: [256][2]u16 = @splat(.{ 0, 0 });
    var depth: [256]u8 = @splat(0);
    var all_ones: [256]bool = @splat(false);
    all_ones[0] = true;
    var nodes: usize = 1;
    for (0..257) |sym| {
        const code = huffman_codes[sym];
        const len = huffman_lens[sym];
        var node: usize = 0;
        var bit_i: usize = len - 1;
        while (bit_i > 0) : (bit_i -= 1) {
            const bit = (code >> bit_i) & 1;
            if (child[node][bit] == 0) {
                child[node][bit] = nodes;
                depth[nodes] = depth[node] + 1;
                all_ones[nodes] = all_ones[node] and bit == 1;
                nodes += 1;
            }
            node = child[node][bit];
        }
        child[node][code & 1] = leaf | sym;
    }
    if (nodes != 256) @compileError("HPACK Huffman code is not a complete tree");

    var table: [256][16]HuffTransition = undefined;
    for (0..256) |s| {
        for (0..16) |nibble| {
            var node: usize = s;
            var sym: u8 = 0;
            var flags: u8 = 0;
            for (0..4) |k| {
                const c = child[node][(nibble >> (3 - k)) & 1];
                if (c & leaf == 0) {
                    node = c;
                } else if (c & ~leaf == 256) {
                    flags = huff_fail;
                    break;
                } else {
                    sym = @truncate(c);
                    flags |= huff_emit;
                    node = 0;
                }
            }
            if (flags != huff_fail and all_ones[node] and depth[node] <= 7) flags |= huff_accept;
            table[s][nibble] = .{ .next = @intCast(node), .sym = sym, .flags = flags };
        }
    }
    break :blk table;
};

/// RFC 7541 Appendix A.
const static_table = [61]Field{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

/// RFC 7541 Appendix B, indexed by symbol; 256 is EOS.
const huffman_codes = [257]u32{
    0x1ff8,     0x7fffd8,  0xfffffe2,  0xfffffe3, 0xfffffe4, 0xfffffe5,  0xfffffe6,  0xfffffe7,
    0xfffffe8,  0xffffea,  0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb,  0xfffffec,
    0xfffffed,  0xfffffee, 0xfffffef,  0xffffff0, 0xffffff1, 0xffffff2,  0x3ffffffe, 0xffffff3,
    0xffffff4,  0xffffff5, 0xffffff6,  0xffffff7, 0xffffff8, 0xffffff9,  0xffffffa,  0xffffffb,
    0x14,       0x3f8,     0x3f9,      0xffa,     0x1ff9,    0x15,       0xf8,       0x7fa,
    0x3fa,      0x3fb,     0xf9,       0x7fb,     0xfa,      0x16,       0x17,       0x18,
    0x0,        0x1,       0x2,        0x19,      0x1a,      0x1b,       0x1c,       0x1d,
    0x1e,       0x1f,      0x5c,       0xfb,      0x7ffc,    0x20,       0xffb,      0x3fc,
    0x1ffa,     0x21,      0x5d,       0x5e,      0x5f,      0x60,       0x61,       0x62,
    0x63,       0x64,      0x65,       0x66,      0x67,      0x68,       0x69,       0x6a,
    0x6b,       0x6c,      0x6d,       0x6e,      0x6f,      0x70,       0x71,       0x72,
    0xfc,       0x73,      0xfd,       0x1ffb,    0x7fff0,   0x1ffc,     0x3ffc,     0x22,
    0x7ffd,     0x3,       0x23,       0x4,       0x24,      0x5,        0x25,       0x26,
    0x27,       0x6,       0x74,       0x75,      0x28,      0x29,       0x2a,       0x7,
    0x2b,       0x76,      0x2c,       0x8,       0x9,       0x2d,       0x77,       0x78,
    0x79,       0x7a,      0x7b,       0x7ffe,    0x7fc,     0x3ffd,     0x1ffd,     0xffffffc,
    0xfffe6,    0x3fffd2,  0xfffe7,    0xfffe8,   0x3fffd3,  0x3fffd4,   0x3fffd5,   0x7fffd9,
    0x3fffd6,   0x7fffda,  0x7fffdb,   0x7fffdc,  0x7fffdd,  0x7fffde,   0xffffeb,   0x7fffdf,
    0xffffec,   0xffffed,  0x3fffd7,   0x7fffe0,  0xffffee,  0x7fffe1,   0x7fffe2,   0x7fffe3,
    0x7fffe4,   0x1fffdc,  0x3fffd8,   0x7fffe5,  0x3fffd9,  0x7fffe6,   0x7fffe7,   0xffffef,
    0x3fffda,   0x1fffdd,  0xfffe9,    0x3fffdb,  0x3fffdc,  0x7fffe8,   0x7fffe9,   0x1fffde,
    0x7fffea,   0x3fffdd,  0x3fffde,   0xfffff0,  0x1fffdf,  0x3fffdf,   0x7fffeb,   0x7fffec,
    0x1fffe0,   0x1fffe1,  0x3fffe0,   0x1fffe2,  0x7fffed,  0x3fffe1,   0x7fffee,   0x7fffef,
    0xfffea,    0x3fffe2,  0x3fffe3,   0x3fffe4,  0x7ffff0,  0x3fffe5,   0x3fffe6,   0x7ffff1,
    0x3ffffe0,  0x3ffffe1, 0xfffeb,    0x7fff1,   0x3fffe7,  0x7ffff2,   0x3fffe8,   0x1ffffec,
    0x3ffffe2,  0x3ffffe3, 0x3ffffe4,  0x7ffffde, 0x7ffffdf, 0x3ffffe5,  0xfffff1,   0x1ffffed,
    0x7fff2,    0x1fffe3,  0x3ffffe6,  0x7ffffe0, 0x7ffffe1, 0x3ffffe7,  0x7ffffe2,  0xfffff2,
    0x1fffe4,   0x1fffe5,  0x3ffffe8,  0x3ffffe9, 0xffffffd, 0x7ffffe3,  0x7ffffe4,  0x7ffffe5,
    0xfffec,    0xfffff3,  0xfffed,    0x1fffe6,  0x3fffe9,  0x1fffe7,   0x1fffe8,   0x7ffff3,
    0x3fffea,   0x3fffeb,  0x1ffffee,  0x1ffffef, 0xfffff4,  0xfffff5,   0x3ffffea,  0x7ffff4,
    0x3ffffeb,  0x7ffffe6, 0x3ffffec,  0x3ffffed, 0x7ffffe7, 0x7ffffe8,  0x7ffffe9,  0x7ffffea,
    0x7ffffeb,  0xffffffe, 0x7ffffec,  0x7ffffed, 0x7ffffee, 0x7ffffef,  0x7fffff0,  0x3ffffee,
    0x3fffffff,
};
const huffman_lens = [257]u8{
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6,  10, 10, 12, 13, 6,  8,  11, 10, 10, 8,  11, 8,  6,  6,  6,
    5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  7,  8,  15, 6,  12, 10,
    13, 6,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,  8,  7,  8,  13, 19, 13, 14, 6,
    15, 5,  6,  5,  6,  5,  6,  6,  6,  5,  7,  7,  6,  6,  6,  5,
    6,  7,  6,  5,  5,  6,  7,  7,  7,  7,  7,  15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
    30,
};

const testing = std.testing;

fn dehex(comptime s: []const u8) []const u8 {
    const final = comptime blk: {
        @setEvalBranchQuota(100_000);
        var buf: [s.len / 2]u8 = undefined;
        var n: usize = 0;
        var hi: ?u8 = null;
        for (s) |c| {
            const v: u8 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                else => continue,
            };
            if (hi) |h| {
                buf[n] = h * 16 + v;
                n += 1;
                hi = null;
            } else hi = v;
        }
        break :blk buf[0..n].*;
    };
    return &final;
}

const Pair = [2][]const u8;

fn expectList(l: *const HeaderList, want: []const Pair) !void {
    try testing.expectEqual(want.len, l.count());
    for (want, 0..) |w, i| {
        try testing.expectEqualStrings(w[0], l.name(i));
        try testing.expectEqualStrings(w[1], l.value(i));
    }
}

/// `want` lists the dynamic table newest first.
fn expectTable(t: *const Table, want: []const Pair, size: usize) !void {
    try testing.expectEqual(want.len, t.len);
    for (want, 0..) |w, i| {
        const f = t.at(i);
        try testing.expectEqualStrings(w[0], f.name);
        try testing.expectEqualStrings(w[1], f.value);
    }
    try testing.expectEqual(size, t.size);
}

const Step = struct {
    block: []const u8,
    headers: []const Pair,
    table: []const Pair,
    size: usize,
    /// Our encoding where it differs from the RFC's.
    encoded: ?[]const u8 = null,
};

/// Decodes the steps on one connection, and re-encodes their headers with
/// incremental indexing, which is what the RFC examples use.
fn runSeries(table_size: u32, huffman: bool, steps: []const Step) !void {
    const gpa = testing.allocator;
    var d: Decoder = .init(table_size, 1 << 20);
    defer d.deinit(gpa);
    // The examples assume the setting was in force from the start.
    d.update_required = false;
    var e: Encoder = .init(default_table_size);
    defer e.deinit(gpa);
    e.table.max_size = table_size;
    e.huffman = huffman;
    var list: HeaderList = .{};
    defer list.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (steps) |step| {
        list.clearRetainingCapacity();
        try d.decode(gpa, step.block, &list);
        try expectList(&list, step.headers);
        try expectTable(&d.table, step.table, step.size);

        var hs: [8]Header = undefined;
        for (step.headers, 0..) |h, i| hs[i] = .{ .name = h[0], .value = h[1], .indexing = .incremental };
        out.clearRetainingCapacity();
        try e.encode(gpa, hs[0..step.headers.len], &out);
        try testing.expectEqualSlices(u8, step.encoded orelse step.block, out.items);
        try expectTable(&e.table, step.table, step.size);
    }
}

test "C.2.1 literal header field with indexing" {
    const gpa = testing.allocator;
    var d: Decoder = .init(4096, 1 << 20);
    defer d.deinit(gpa);
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    try d.decode(gpa, dehex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"), &l);
    try expectList(&l, &.{.{ "custom-key", "custom-header" }});
    try expectTable(&d.table, &.{.{ "custom-key", "custom-header" }}, 55);
}

test "C.2.2 literal header field without indexing" {
    const gpa = testing.allocator;
    var d: Decoder = .init(4096, 1 << 20);
    defer d.deinit(gpa);
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    try d.decode(gpa, dehex("040c 2f73 616d 706c 652f 7061 7468"), &l);
    try expectList(&l, &.{.{ ":path", "/sample/path" }});
    try testing.expect(!l.neverIndexed(0));
    try expectTable(&d.table, &.{}, 0);
}

test "C.2.3 literal header field never indexed" {
    const gpa = testing.allocator;
    var d: Decoder = .init(4096, 1 << 20);
    defer d.deinit(gpa);
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    const block = dehex("1008 7061 7373 776f 7264 0673 6563 7265 74");
    try d.decode(gpa, block, &l);
    try expectList(&l, &.{.{ "password", "secret" }});
    try testing.expect(l.neverIndexed(0));
    try expectTable(&d.table, &.{}, 0);

    var e: Encoder = .init(4096);
    defer e.deinit(gpa);
    e.huffman = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try e.encode(gpa, &.{.{ .name = "password", .value = "secret", .indexing = .never }}, &out);
    try testing.expectEqualSlices(u8, block, out.items);
}

test "C.2.4 indexed header field" {
    const gpa = testing.allocator;
    var d: Decoder = .init(4096, 1 << 20);
    defer d.deinit(gpa);
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    try d.decode(gpa, dehex("82"), &l);
    try expectList(&l, &.{.{ ":method", "GET" }});
    try expectTable(&d.table, &.{}, 0);
}

const c3_c4_headers = [3][]const Pair{
    &.{ .{ ":method", "GET" }, .{ ":scheme", "http" }, .{ ":path", "/" }, .{ ":authority", "www.example.com" } },
    &.{ .{ ":method", "GET" }, .{ ":scheme", "http" }, .{ ":path", "/" }, .{ ":authority", "www.example.com" }, .{ "cache-control", "no-cache" } },
    &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":path", "/index.html" }, .{ ":authority", "www.example.com" }, .{ "custom-key", "custom-value" } },
};
const c3_c4_tables = [3][]const Pair{
    &.{.{ ":authority", "www.example.com" }},
    &.{ .{ "cache-control", "no-cache" }, .{ ":authority", "www.example.com" } },
    &.{ .{ "custom-key", "custom-value" }, .{ "cache-control", "no-cache" }, .{ ":authority", "www.example.com" } },
};

test "C.3 requests without Huffman coding" {
    try runSeries(4096, false, &.{
        .{ .block = dehex("8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d"), .headers = c3_c4_headers[0], .table = c3_c4_tables[0], .size = 57 },
        .{ .block = dehex("8286 84be 5808 6e6f 2d63 6163 6865"), .headers = c3_c4_headers[1], .table = c3_c4_tables[1], .size = 110 },
        .{ .block = dehex("8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573 746f 6d2d 7661 6c75 65"), .headers = c3_c4_headers[2], .table = c3_c4_tables[2], .size = 164 },
    });
}

test "C.4 requests with Huffman coding" {
    try runSeries(4096, true, &.{
        .{ .block = dehex("8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff"), .headers = c3_c4_headers[0], .table = c3_c4_tables[0], .size = 57 },
        .{ .block = dehex("8286 84be 5886 a8eb 1064 9cbf"), .headers = c3_c4_headers[1], .table = c3_c4_tables[1], .size = 110 },
        .{ .block = dehex("8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b b8e8 b4bf"), .headers = c3_c4_headers[2], .table = c3_c4_tables[2], .size = 164 },
    });
}

const date1 = "Mon, 21 Oct 2013 20:13:21 GMT";
const date2 = "Mon, 21 Oct 2013 20:13:22 GMT";
const location = "https://www.example.com";
const cookie = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1";
const c5_c6_headers = [3][]const Pair{
    &.{ .{ ":status", "302" }, .{ "cache-control", "private" }, .{ "date", date1 }, .{ "location", location } },
    &.{ .{ ":status", "307" }, .{ "cache-control", "private" }, .{ "date", date1 }, .{ "location", location } },
    &.{ .{ ":status", "200" }, .{ "cache-control", "private" }, .{ "date", date2 }, .{ "location", location }, .{ "content-encoding", "gzip" }, .{ "set-cookie", cookie } },
};
const c5_c6_tables = [3][]const Pair{
    &.{ .{ "location", location }, .{ "date", date1 }, .{ "cache-control", "private" }, .{ ":status", "302" } },
    &.{ .{ ":status", "307" }, .{ "location", location }, .{ "date", date1 }, .{ "cache-control", "private" } },
    &.{ .{ "set-cookie", cookie }, .{ "content-encoding", "gzip" }, .{ "date", date2 } },
};

test "C.5 responses without Huffman coding" {
    try runSeries(256, false, &.{
        .{ .block = dehex(
            \\4803 3330 3258 0770 7269 7661 7465 611d
            \\4d6f 6e2c 2032 3120 4f63 7420 3230 3133
            \\2032 303a 3133 3a32 3120 474d 546e 1768
            \\7474 7073 3a2f 2f77 7777 2e65 7861 6d70
            \\6c65 2e63 6f6d
        ), .headers = c5_c6_headers[0], .table = c5_c6_tables[0], .size = 222 },
        .{ .block = dehex("4803 3330 37c1 c0bf"), .headers = c5_c6_headers[1], .table = c5_c6_tables[1], .size = 222 },
        .{ .block = dehex(
            \\88c1 611d 4d6f 6e2c 2032 3120 4f63 7420
            \\3230 3133 2032 303a 3133 3a32 3220 474d
            \\54c0 5a04 677a 6970 7738 666f 6f3d 4153
            \\444a 4b48 514b 425a 584f 5157 454f 5049
            \\5541 5851 5745 4f49 553b 206d 6178 2d61
            \\6765 3d33 3630 303b 2076 6572 7369 6f6e
            \\3d31
        ), .headers = c5_c6_headers[2], .table = c5_c6_tables[2], .size = 215 },
    });
}

test "C.6 responses with Huffman coding" {
    try runSeries(256, true, &.{
        .{ .block = dehex(
            \\4882 6402 5885 aec3 771a 4b61 96d0 7abe
            \\9410 54d4 44a8 2005 9504 0b81 66e0 82a6
            \\2d1b ff6e 919d 29ad 1718 63c7 8f0b 97c8
            \\e9ae 82ae 43d3
        ), .headers = c5_c6_headers[0], .table = c5_c6_tables[0], .size = 222 },
        // "307" is 3 bytes either way; we only Huffman-code when it is shorter.
        .{ .block = dehex("4883 640e ffc1 c0bf"), .headers = c5_c6_headers[1], .table = c5_c6_tables[1], .size = 222, .encoded = dehex("4803 3330 37c1 c0bf") },
        .{ .block = dehex(
            \\88c1 6196 d07a be94 1054 d444 a820 0595
            \\040b 8166 e084 a62d 1bff c05a 839b d9ab
            \\77ad 94e7 821d d7f2 e6c7 b335 dfdf cd5b
            \\3960 d5af 2708 7f36 72c1 ab27 0fb5 291f
            \\9587 3160 65c0 03ed 4ee5 b106 3d50 07
        ), .headers = c5_c6_headers[2], .table = c5_c6_tables[2], .size = 215 },
    });
}

test "C.1 integer representation" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureUnusedCapacity(gpa, 3 * max_int_len);
    putInt(&out, 0, 5, 10);
    putInt(&out, 0, 5, 1337);
    out.appendAssumeCapacity(0); // 42 with an 8-bit prefix is not used by HPACK
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0x1f, 0x9a, 0x0a, 0 }, out.items);
    var p: usize = 0;
    try testing.expectEqual(10, try decodeInt(out.items, &p, 5));
    try testing.expectEqual(1337, try decodeInt(out.items, &p, 5));
    try testing.expectEqual(4, p);
}

test "integer round trips at every prefix size" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const values = [_]usize{ 0, 1, 14, 15, 16, 30, 31, 32, 62, 63, 64, 126, 127, 128, 255, 256, 16383, 16384, 1 << 21, std.math.maxInt(u32) };
    inline for (.{ 4, 5, 6, 7 }) |prefix| {
        for (values) |v| {
            out.clearRetainingCapacity();
            try out.ensureUnusedCapacity(gpa, max_int_len);
            putInt(&out, 0, prefix, v);
            var p: usize = 0;
            try testing.expectEqual(v, try decodeInt(out.items, &p, prefix));
            try testing.expectEqual(out.items.len, p);
        }
    }
}

test "Huffman known vectors and padding" {
    var buf: [64]u8 = undefined;
    const enc = dehex("f1e3 c2e5 f23a 6ba0 ab90 f4ff");
    try testing.expectEqual(enc.len, huffmanEncodedLen("www.example.com"));
    huffmanEncode("www.example.com", buf[0..enc.len]);
    try testing.expectEqualSlices(u8, enc, buf[0..enc.len]);
    const n = try huffmanDecode(enc, &buf);
    try testing.expectEqualStrings("www.example.com", buf[0..n]);
    // The empty string, and every symbol alone.
    try testing.expectEqual(0, try huffmanDecode("", &buf));
    for (0..256) |c| {
        const s = [1]u8{@intCast(c)};
        const len = huffmanEncodedLen(&s);
        var tmp: [4]u8 = undefined;
        huffmanEncode(&s, tmp[0..len]);
        const k = try huffmanDecode(tmp[0..len], &buf);
        try testing.expectEqualSlices(u8, &s, buf[0..k]);
    }
}

test "Huffman round trips over random bytes" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7541);
    const r = prng.random();
    var src: [600]u8 = undefined;
    const enc = try gpa.alloc(u8, src.len * 4);
    defer gpa.free(enc);
    const dec = try gpa.alloc(u8, enc.len * 8 / 5 + 1);
    defer gpa.free(dec);
    for (0..2000) |i| {
        const len = r.uintLessThan(usize, src.len + 1);
        // Half the inputs are printable, as real header values are.
        if (i % 2 == 0) r.bytes(src[0..len]) else for (src[0..len]) |*c| {
            c.* = r.intRangeAtMost(u8, 0x20, 0x7e);
        }
        const el = huffmanEncodedLen(src[0..len]);
        huffmanEncode(src[0..len], enc[0..el]);
        const n = try huffmanDecode(enc[0..el], dec);
        try testing.expectEqualSlices(u8, src[0..len], dec[0..n]);
    }
}

test "Huffman rejects EOS and bad padding" {
    var buf: [64]u8 = undefined;
    const bad = [_][]const u8{
        &.{0xff}, // 8 bits of padding
        &.{ 0x1f, 0xff }, // "a" then 11 bits of padding
        &.{ 0x1f, 0xff, 0xff },
        &.{ 0xff, 0x9f, 0xff, 0xff, 0xff }, // 29-bit padding
        &.{ 'R', 0xbc, '0', 0xff, 0xff, 0xff, 0xff }, // padding ends inside a symbol
        &.{ 0xff, 0xff, 0xff, 0xff, 0xfc }, // EOS then "?"
        &.{ 0xff, 0xff, 0xff, 0xff }, // EOS
        &.{0x00}, // "0" then padding of zeros
        &.{0x1e}, // "a" then padding "110"
    };
    for (bad) |b| try testing.expectError(error.CompressionError, huffmanDecode(b, &buf));
    // "a" (00011) with valid padding "111".
    try testing.expectEqual(1, try huffmanDecode(&.{0x1f}, &buf));
}

fn expectDecodeError(err: Error, table_size: u32, block: []const u8) !void {
    const gpa = testing.allocator;
    var d: Decoder = .init(table_size, 1 << 20);
    defer d.deinit(gpa);
    d.update_required = false;
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    try testing.expectError(err, d.decode(gpa, block, &l));
    try testing.expectEqual(0, l.count());
    try testing.expectEqual(0, l.bytes.items.len);
}

test "decoder rejects malformed blocks" {
    const ce = error.CompressionError;
    try expectDecodeError(ce, 4096, &.{0x80}); // index 0
    try expectDecodeError(ce, 4096, &.{0xbe}); // index 62, empty table
    try expectDecodeError(ce, 4096, &.{ 0x82, 0xbe }); // first field decoded, then rolled back
    try expectDecodeError(ce, 4096, &.{0xff}); // truncated integer
    try expectDecodeError(ce, 4096, &.{ 0xff, 0x80 }); // truncated continuation
    try expectDecodeError(ce, 4096, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f }); // too many bytes
    try expectDecodeError(ce, 4096, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f }); // above 2^32
    try expectDecodeError(ce, 4096, &.{ 0x40, 0x0a, 0x63 }); // truncated literal name
    try expectDecodeError(ce, 4096, &.{0x40}); // missing name
    try expectDecodeError(ce, 4096, &.{ 0x44, 0x05, 'a' }); // truncated value
    try expectDecodeError(ce, 4096, &.{0x44}); // missing value
    try expectDecodeError(ce, 4096, &.{ 0x7f, 0x00, 0x00 }); // literal name index 63, empty table
    try expectDecodeError(ce, 4096, &.{ 0x04, 0x81, 0xff }); // Huffman: 8 bits of padding
    try expectDecodeError(ce, 4096, &.{ 0x04, 0x81, 0x00 }); // Huffman: zero padding
    try expectDecodeError(ce, 4096, &.{ 0x04, 0x84, 0xff, 0xff, 0xff, 0xff }); // Huffman: EOS
    try expectDecodeError(ce, 4096, &.{ 0x82, 0x20 }); // size update after a field
    try expectDecodeError(ce, 4096, &.{ 0x3f, 0xe2, 0x1f }); // size update to 4097
    try expectDecodeError(ce, 256, &.{ 0x3f, 0xe2, 0x01 }); // size update to 257
}

test "size updates" {
    const gpa = testing.allocator;
    var d: Decoder = .init(4096, 1 << 20);
    defer d.deinit(gpa);
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    try d.decode(gpa, dehex("400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572"), &l);
    try testing.expectEqual(1, d.table.len);
    // Two updates at the start (shrink to 0, then back) empty the table.
    try d.decode(gpa, &.{ 0x20, 0x3f, 0xe1, 0x1f, 0x82 }, &l);
    try testing.expectEqual(0, d.table.len);
    try testing.expectEqual(4096, d.table.max_size);

    // Lowering our setting makes an update mandatory in the next block.
    d.setMaxAllowed(100);
    try testing.expectError(error.CompressionError, d.decode(gpa, &.{0x82}, &l));
    try testing.expectError(error.CompressionError, d.decode(gpa, &.{ 0x3f, 0x46, 0x82 }, &l)); // 101
    try d.decode(gpa, &.{ 0x3f, 0x45, 0x82 }, &l); // 100
    try d.decode(gpa, &.{0x82}, &l);
    try testing.expectEqual(100, d.table.max_size);

    // A decoder advertising less than 4096 needs the update from the start.
    var d2: Decoder = .init(0, 1 << 20);
    defer d2.deinit(gpa);
    try testing.expectError(error.CompressionError, d2.decode(gpa, &.{0x82}, &l));
    try d2.decode(gpa, &.{ 0x20, 0x82 }, &l);
}

test "entries larger than the table empty it" {
    const gpa = testing.allocator;
    var t: Table = .{ .max_size = 100 };
    defer t.deinit(gpa);
    try t.insert(gpa, "foo", "bar");
    try testing.expectEqual(38, t.size);
    try t.insert(gpa, "long", &@as([70]u8, @splat('x')));
    try testing.expectEqual(0, t.len);
    try testing.expectEqual(0, t.size);
    try t.insert(gpa, "a", "b");
    try expectTable(&t, &.{.{ "a", "b" }}, 34);
}

test "header list size limit keeps the table in sync" {
    const gpa = testing.allocator;
    var d: Decoder = .init(4096, 60);
    defer d.deinit(gpa);
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    try d.decode(gpa, &.{0x82}, &l); // 7 + 3 + 32 = 42
    // custom-key: custom-header is 55 by itself; 42 + 55 > 60.
    const block = dehex("82 400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d 6865 6164 6572");
    try testing.expectError(error.HeaderListTooLarge, d.decode(gpa, block, &l));
    try expectList(&l, &.{.{ ":method", "GET" }});
    try expectTable(&d.table, &.{.{ "custom-key", "custom-header" }}, 55);
    // The entry can be referenced, but does not fit with :method either.
    try testing.expectError(error.HeaderListTooLarge, d.decode(gpa, &.{ 0x82, 0xbe }, &l));
    l.clearRetainingCapacity();
    try d.decode(gpa, &.{0xbe}, &l);
    try expectList(&l, &.{.{ "custom-key", "custom-header" }});
}

test "encoder picks representations" {
    const gpa = testing.allocator;
    var e: Encoder = .init(4096);
    defer e.deinit(gpa);
    e.huffman = false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const headers = [_]Header{
        .{ .name = ":method", .value = "POST" }, // static exact
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/a.B/C" }, // static name, indexed
        .{ .name = "te", .value = "trailers" }, // literal name, indexed
        .{ .name = "grpc-timeout", .value = "1S" }, // without indexing
        .{ .name = "authorization", .value = "x" }, // never, static name 23
        .{ .name = "x-other", .value = "1" }, // without, literal name
    };
    try e.encode(gpa, &headers, &out);
    try testing.expectEqualSlices(u8, dehex("83 86 44 06 2f612e422f43 40 02 7465 08 7472 6169 6c65 7273" ++
        "00 0c 6772 7063 2d74 696d 656f 7574 02 3153 1f08 01 78 00 07 782d 6f74 6865 72 01 31"), out.items);
    try expectTable(&e.table, &.{ .{ "te", "trailers" }, .{ ":path", "/a.B/C" } }, 85);
    // The second time, the indexed headers are one byte each; the sensitive
    // one stays literal.
    out.clearRetainingCapacity();
    try e.encode(gpa, &headers, &out);
    try testing.expectEqualSlices(u8, dehex("83 86 bf be 00 0c 6772 7063 2d74 696d 656f 7574 02 3153 1f08 01 78 00 07 782d 6f74 6865 72 01 31"), out.items);
}

test "encoder size updates" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // A limit below the default is announced in the first block.
    var e: Encoder = .init(0);
    defer e.deinit(gpa);
    try e.encode(gpa, &.{.{ .name = ":authority", .value = "h" }}, &out);
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x01, 0x01, 'h' }, out.items); // a zero-size table indexes nothing
    try testing.expectEqual(0, e.table.len);

    var e2: Encoder = .init(8192);
    defer e2.deinit(gpa);
    e2.setPeerMaxSize(8192);
    e2.setPeerMaxSize(100);
    e2.setPeerMaxSize(4096);
    out.clearRetainingCapacity();
    try e2.encode(gpa, &.{}, &out);
    // The minimum, then the final size (RFC 7541 §4.2).
    try testing.expectEqualSlices(u8, &.{ 0x3f, 0x45, 0x3f, 0xe1, 0x1f }, out.items);
    out.clearRetainingCapacity();
    e2.setPeerMaxSize(4096);
    try e2.encode(gpa, &.{}, &out);
    try testing.expectEqual(0, out.items.len);
}

test "encoder and decoder stay in sync over many blocks" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    var e: Encoder = .init(4096);
    defer e.deinit(gpa);
    var d: Decoder = .init(4096, 1 << 20);
    defer d.deinit(gpa);
    var l: HeaderList = .{};
    defer l.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const names = [_][]const u8{ ":authority", ":path", ":method", ":status", "content-type", "te", "user-agent", "x-nix-system", "grpc-status", "grpc-message", "grpc-timeout", "authorization", "x-custom", "cache-control", "set-cookie" };
    var values: [24][]const u8 = undefined;
    var value_buf: [24][300]u8 = undefined;
    for (&values, &value_buf, 0..) |*v, *buf, i| {
        // Some values are long enough to force evictions.
        const len = if (i % 6 == 0) r.intRangeAtMost(usize, 100, 300) else r.intRangeAtMost(usize, 0, 20);
        for (buf[0..len]) |*c| c.* = r.intRangeAtMost(u8, 0x20, 0x7e);
        v.* = buf[0..len];
    }
    values[1] = "POST";
    values[2] = "application/grpc";
    values[3] = "0";

    const sizes = [_]u32{ 0, 64, 256, 1000, 4096, 8192 };
    var headers: [40]Header = undefined;
    for (0..3000) |block_i| {
        if (r.uintLessThan(u8, 20) == 0) {
            const s = sizes[r.uintLessThan(usize, sizes.len)];
            e.setPeerMaxSize(s);
            d.setMaxAllowed(s);
            if (r.boolean()) {
                const s2 = sizes[r.uintLessThan(usize, sizes.len)];
                e.setPeerMaxSize(s2);
                d.setMaxAllowed(s2);
            }
        }
        e.huffman = block_i % 3 != 0;
        const n = r.uintLessThan(usize, headers.len + 1);
        for (headers[0..n]) |*h| h.* = .{
            .name = names[r.uintLessThan(usize, names.len)],
            .value = values[r.uintLessThan(usize, values.len)],
            .indexing = @fromBackingInt(r.int(u2)),
        };
        out.clearRetainingCapacity();
        try e.encode(gpa, headers[0..n], &out);
        l.clearRetainingCapacity();
        try d.decode(gpa, out.items, &l);
        try testing.expectEqual(n, l.count());
        for (headers[0..n], 0..) |h, i| {
            try testing.expectEqualStrings(h.name, l.name(i));
            try testing.expectEqualStrings(h.value, l.value(i));
            const never = h.indexing == .never or (h.indexing == .auto and std.mem.eql(u8, h.name, "authorization"));
            try testing.expectEqual(never, l.neverIndexed(i));
        }
        try testing.expectEqual(e.table.len, d.table.len);
        try testing.expectEqual(e.table.size, d.table.size);
        try testing.expectEqual(e.table.max_size, d.table.max_size);
        for (0..d.table.len) |i| {
            try testing.expectEqualStrings(e.table.at(i).name, d.table.at(i).name);
            try testing.expectEqualStrings(e.table.at(i).value, d.table.at(i).value);
        }
    }
}
