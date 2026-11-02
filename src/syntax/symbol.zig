//! Symbol interner. One `Table` holds every name of a run and may be shared
//! by many threads; each thread works through its own `Interner` handle,
//! which puts a small lock-free cache in front of the table.
//!
//! Lookups never lock: each of the table's shards is an open-addressing
//! array of atomic slots, and a reader only loads. An insert takes its
//! shard's lock, writes the name, and publishes the slot last. A shard that
//! grows publishes a new array and keeps the old one until the table goes,
//! so a reader still probing the old array stays safe (it just misses, and
//! the locked path finds the name in the new one). Ids are dense: an id is
//! handed out only under the shard lock, after the miss is confirmed.

const std = @import("std");
const Scratch = @import("../Scratch.zig");
const Allocator = std.mem.Allocator;

/// An interned identifier or attribute name. Ids are dense and start at 0.
/// Attrsets sort by id, so id order is arbitrary but stable within a run.
pub const Sym = enum(u32) {
    _,

    pub fn index(s: Sym) u32 {
        return @backingInt(s);
    }

    pub fn fromIndex(i: u32) Sym {
        return @fromBackingInt(@intCast(i));
    }
};

/// Symbols one run may hold.
pub const max_syms: u32 = 1 << 30;

const fx_seed: u64 = 0x517c_c1b7_2722_0a95;

/// FxHash: one multiply per word. Keys here are short; SipHash-class
/// hashes cost more than the probing they save.
pub const FxHasher = struct {
    h: u64 = 0,

    pub inline fn add(f: *FxHasher, w: u64) void {
        f.h = (std.math.rotl(u64, f.h, 5) ^ w) *% fx_seed;
    }

    pub fn write(f: *FxHasher, bytes: []const u8) void {
        var b = bytes;
        while (b.len >= 8) {
            f.add(std.mem.readInt(u64, b[0..8], .little));
            b = b[8..];
        }
        if (b.len >= 4) {
            f.add(std.mem.readInt(u32, b[0..4], .little));
            b = b[4..];
        }
        for (b) |x| f.add(x);
    }
};

/// Content hash of a byte string, its length mixed in. Four independent
/// chains over 32-byte blocks: one chain waits on a multiply per 8 bytes,
/// and dedup tables hash kilobyte builder scripts.
pub fn fxBytes(bytes: []const u8) u64 {
    var h: FxHasher = .{};
    const nblocks = bytes.len / 32;
    if (nblocks > 0) {
        var l: [4]FxHasher = @splat(.{});
        for (0..nblocks) |i| {
            const b = bytes[i * 32 ..][0..32];
            inline for (0..4) |k| l[k].add(std.mem.readInt(u64, b[k * 8 ..][0..8], .little));
        }
        for (l) |x| h.add(x.h);
    }
    h.write(bytes[nblocks * 32 ..]);
    h.add(bytes.len);
    return h.h;
}

/// The hash the shard and the handle cache use: FxHash fills the high bits
/// well and the shard index reads those.
fn hashName(b: []const u8) u64 {
    var h: FxHasher = .{};
    // Most names are identifiers of up to 16 bytes: two overlapping loads
    // and two multiplies, where the byte loop chained one per tail byte.
    if (b.len <= 16) {
        var lo: u64 = 0;
        var hi: u64 = 0;
        if (b.len >= 8) {
            lo = std.mem.readInt(u64, b[0..8], .little);
            hi = std.mem.readInt(u64, b[b.len - 8 ..][0..8], .little);
        } else if (b.len >= 4) {
            lo = std.mem.readInt(u32, b[0..4], .little);
            hi = std.mem.readInt(u32, b[b.len - 4 ..][0..4], .little);
        } else if (b.len > 0) {
            lo = @as(u64, b[0]) | @as(u64, b[b.len / 2]) << 8 | @as(u64, b[b.len - 1]) << 16;
        }
        h.add(lo);
        h.add(hi ^ @as(u64, b.len) << 56);
        return h.h;
    }
    h.write(b);
    return h.h;
}

/// Slot index and tag come from the low bits, which FxHash leaves weak: at
/// millions of names of one shape (`a0`, `a1`, ...) unmixed probe chains
/// dominated. One multiply carries the entropy up, one fold brings it down.
inline fn mix(h: u64) u64 {
    const m = h *% 0x9e3779b97f4a7c15;
    return m ^ (m >> 32);
}

/// The first 8 bytes of `name`, big-endian and zero-padded: two names in
/// byte order have prefixes in the same order or equal ones.
fn prefixOf(name: []const u8) u64 {
    var p: [8]u8 = @splat(0);
    const n = @min(name.len, 8);
    @memcpy(p[0..n], name[0..n]);
    return std.mem.readInt(u64, &p, .big);
}

const Entry = struct {
    ptr: [*]const u8,
    len: u32,
    prefix: u64,
};

/// The id -> name table is segmented: chunk `k` holds `first_chunk << k`
/// entries, so it grows without moving and a reader needs no lock.
const first_chunk_log2 = 10;
const n_chunks = 21;
comptime {
    std.debug.assert((@as(u64, 1) << (first_chunk_log2 + n_chunks)) - (1 << first_chunk_log2) >= max_syms);
}

inline fn chunkOf(id: u32) struct { u5, u32 } {
    const x = id + (1 << first_chunk_log2);
    const lg: u5 = @intCast(31 - @clz(x));
    return .{ lg - first_chunk_log2, x - (@as(u32, 1) << lg) };
}

const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    /// Held for one probe and one small copy, so a spin beats a futex; a
    /// preempted holder is waited out with `yield`.
    fn lock(l: *SpinLock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            var n: u32 = 0;
            while (l.held.load(.monotonic)) {
                std.atomic.spinLoopHint();
                n += 1;
                if (n == 64) {
                    n = 0;
                    std.Thread.yield() catch {};
                }
            }
        }
    }

    fn unlock(l: *SpinLock) void {
        l.held.store(false, .release);
    }
};

/// One open-addressing array. A slot is `tag << 32 | (id + 1)`, 0 when empty.
const Slots = struct {
    mask: u32,
    prev: ?*Slots,
    slots: []std.atomic.Value(u64),
};

const n_shards = 64;

const Shard = struct {
    lock: SpinLock = .{},
    slots: std.atomic.Value(?*Slots) = .init(null),
    count: u32 = 0,
    /// Name bytes. A plain bump allocator: the shard lock already
    /// serialises it, and `std.heap.ArenaAllocator` pays an atomic per call.
    names: Scratch = .{ .backing = undefined },
    _: void align(std.atomic.cache_line) = {},
};

/// The shared table. Its allocator must be thread-safe when handles on
/// several threads intern.
pub const Table = struct {
    gpa: Allocator,
    shards: [n_shards]Shard = @splat(.{}),
    chunks: [n_chunks]std.atomic.Value(?[*]Entry) = @splat(.init(null)),
    next: std.atomic.Value(u32) = .init(0),

    pub fn create(gpa: Allocator) !*Table {
        const t = try gpa.create(Table);
        t.* = .{ .gpa = gpa };
        for (&t.shards) |*s| s.names = .init(gpa);
        return t;
    }

    /// No handle may be used after this.
    pub fn destroy(t: *Table) void {
        for (&t.shards) |*s| {
            var p = s.slots.raw;
            while (p) |sl| {
                p = sl.prev;
                t.gpa.free(sl.slots);
                t.gpa.destroy(sl);
            }
            s.names.deinit();
        }
        for (&t.chunks, 0..) |*c, k| {
            if (c.raw) |p| t.gpa.free(p[0 .. @as(usize, 1) << @intCast(first_chunk_log2 + k)]);
        }
        t.gpa.destroy(t);
    }

    inline fn entry(t: *const Table, s: Sym) *const Entry {
        const k, const off = chunkOf(s.index());
        const c = t.chunks[k].load(.acquire) orelse unreachable;
        return &c[off];
    }

    pub fn name(t: *const Table, s: Sym) []const u8 {
        std.debug.assert(s.index() < t.next.load(.monotonic));
        const e = t.entry(s);
        return e.ptr[0..e.len];
    }

    /// The order of names by bytes, as far as their first 8 bytes decide
    /// it; on a tie, compare the names.
    pub fn prefix(t: *const Table, s: Sym) u64 {
        return t.entry(s).prefix;
    }

    pub fn count(t: *const Table) u32 {
        return t.next.load(.monotonic);
    }

    fn shardOf(t: *Table, h: u64) *Shard {
        return &t.shards[@intCast(h >> 58)];
    }

    fn probe(t: *const Table, sl: *const Slots, m: u64, bytes: []const u8) ?Sym {
        const tag: u32 = @truncate(m >> 32);
        var i: u32 = @as(u32, @truncate(m)) & sl.mask;
        while (true) : (i = (i + 1) & sl.mask) {
            const v = sl.slots[i].load(.acquire);
            if (v == 0) return null;
            if (@as(u32, @truncate(v >> 32)) == tag) {
                const s: Sym = .fromIndex(@as(u32, @truncate(v)) - 1);
                const e = t.entry(s);
                if (e.len == bytes.len and std.mem.eql(u8, e.ptr[0..e.len], bytes)) return s;
            }
        }
    }

    /// A lookup that does not intern.
    pub fn get(t: *Table, bytes: []const u8) ?Sym {
        return t.getHashed(bytes, hashName(bytes));
    }

    fn getHashed(t: *Table, bytes: []const u8, h: u64) ?Sym {
        const sl = t.shardOf(h).slots.load(.acquire) orelse return null;
        return t.probe(sl, mix(h), bytes);
    }

    pub fn intern(t: *Table, bytes: []const u8) error{OutOfMemory}!Sym {
        return t.internHashed(bytes, hashName(bytes));
    }

    fn internHashed(t: *Table, bytes: []const u8, h: u64) error{OutOfMemory}!Sym {
        if (t.getHashed(bytes, h)) |s| return s;
        const sh = t.shardOf(h);
        sh.lock.lock();
        defer sh.lock.unlock();
        const m = mix(h);
        var sl = sh.slots.raw;
        if (sl) |p| if (t.probe(p, m, bytes)) |s| return s;
        if (bytes.len > std.math.maxInt(u32)) return error.OutOfMemory;

        if (sl == null or (sh.count + 1) * 4 > (sl.?.mask + 1) * 3) sl = try t.grow(sh);

        const id = t.next.fetchAdd(1, .monotonic);
        if (id >= max_syms) return error.OutOfMemory;
        const copy = try sh.names.allocator().dupe(u8, bytes);
        const k, const off = chunkOf(id);
        const chunk = t.chunks[k].load(.acquire) orelse try t.newChunk(k);
        chunk[off] = .{ .ptr = copy.ptr, .len = @intCast(bytes.len), .prefix = prefixOf(bytes) };

        const s = sl.?;
        var i: u32 = @as(u32, @truncate(m)) & s.mask;
        while (s.slots[i].raw != 0) i = (i + 1) & s.mask;
        s.slots[i].store((m >> 32 << 32) | (@as(u64, id) + 1), .release);
        sh.count += 1;
        return .fromIndex(id);
    }

    /// Chunks are allocated by whichever shard needs one first; losers of
    /// the race free theirs.
    fn newChunk(t: *Table, k: u5) ![*]Entry {
        const n = @as(usize, 1) << (first_chunk_log2 + @as(u6, k));
        const fresh = try t.gpa.alloc(Entry, n);
        if (t.chunks[k].cmpxchgStrong(null, fresh.ptr, .acq_rel, .acquire)) |other| {
            t.gpa.free(fresh);
            return other.?;
        }
        return fresh.ptr;
    }

    fn grow(t: *Table, sh: *Shard) !*Slots {
        const old = sh.slots.raw;
        const cap: u32 = if (old) |o| (o.mask + 1) * 2 else 16;
        const sl = try t.gpa.create(Slots);
        errdefer t.gpa.destroy(sl);
        const slots = try t.gpa.alloc(std.atomic.Value(u64), cap);
        @memset(slots, .init(0));
        sl.* = .{ .mask = cap - 1, .prev = old, .slots = slots };
        if (old) |o| {
            for (o.slots) |*v| {
                const x = v.raw;
                if (x == 0) continue;
                const e = t.entry(.fromIndex(@as(u32, @truncate(x)) - 1));
                const m = mix(hashName(e.ptr[0..e.len]));
                var i: u32 = @as(u32, @truncate(m)) & sl.mask;
                while (slots[i].raw != 0) i = (i + 1) & sl.mask;
                slots[i].raw = x;
            }
        }
        sh.slots.store(sl, .release);
        return sl;
    }
};

const cache_size = 4096;

const CacheEntry = struct {
    hash: u64,
    ptr: [*]const u8,
    len: u32,
    sym: u32,

    const empty: CacheEntry = .{ .hash = 0, .ptr = "".ptr, .len = 0, .sym = std.math.maxInt(u32) };
};

/// A handle on a `Table` with its own direct-mapped cache: a hit costs one
/// hash and one compare. Use one handle per thread.
pub const Interner = struct {
    table: *Table,
    cache: *[cache_size]CacheEntry,
    /// The handle from `init` owns the table and destroys it in `deinit`;
    /// handles from `fork` must be gone by then.
    owner: bool,

    pub fn init(gpa: Allocator) !Interner {
        const t = try Table.create(gpa);
        errdefer t.destroy();
        return .{ .table = t, .cache = try newCache(gpa), .owner = true };
    }

    /// Another handle on the same table, for another thread.
    pub fn fork(i: *const Interner) !Interner {
        return .{ .table = i.table, .cache = try newCache(i.table.gpa), .owner = false };
    }

    fn newCache(gpa: Allocator) !*[cache_size]CacheEntry {
        const c = try gpa.create([cache_size]CacheEntry);
        @memset(c, .empty);
        return c;
    }

    pub fn deinit(i: *Interner) void {
        i.table.gpa.destroy(i.cache);
        if (i.owner) i.table.destroy();
        i.* = undefined;
    }

    pub fn intern(i: *Interner, bytes: []const u8) error{OutOfMemory}!Sym {
        const h = hashName(bytes);
        const e = &i.cache[@as(usize, @truncate(mix(h))) & (cache_size - 1)];
        if (e.hash == h and e.sym != CacheEntry.empty.sym and e.len == bytes.len and
            std.mem.eql(u8, e.ptr[0..e.len], bytes)) return .fromIndex(e.sym);
        const s = try i.table.internHashed(bytes, h);
        const n = i.table.name(s);
        e.* = .{ .hash = h, .ptr = n.ptr, .len = @intCast(n.len), .sym = s.index() };
        return s;
    }

    pub fn get(i: *const Interner, bytes: []const u8) ?Sym {
        return i.table.get(bytes);
    }

    pub fn name(i: *const Interner, s: Sym) []const u8 {
        return i.table.name(s);
    }

    /// The name as Rust iets shows it: the bytes when they are UTF-8,
    /// `<non-utf8>` otherwise. Used where Nix prints a name.
    pub fn nameStr(i: *const Interner, s: Sym) []const u8 {
        const n = i.table.name(s);
        return if (std.unicode.utf8ValidateSlice(n)) n else "<non-utf8>";
    }

    pub fn prefix(i: *const Interner, s: Sym) u64 {
        return i.table.prefix(s);
    }

    pub fn count(i: *const Interner) u32 {
        return i.table.count();
    }
};

const testing = std.testing;

test "fxBytes sees every byte and its place" {
    var base: [100]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @intCast(i);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(testing.allocator);
    const add = struct {
        fn f(s: *std.AutoHashMapUnmanaged(u64, void), b: []const u8) !void {
            const r = try s.getOrPut(testing.allocator, fxBytes(b));
            try testing.expect(!r.found_existing);
        }
    }.f;
    try add(&seen, &base);
    for (0..base.len) |i| {
        var s = base;
        s[i] ^= 0x80;
        try add(&seen, &s);
    }
    for ([_][2]usize{ .{ 0, 8 }, .{ 8, 24 }, .{ 0, 32 } }) |ab| {
        var s = base;
        for (0..8) |k| std.mem.swap(u8, &s[ab[0] + k], &s[ab[1] + k]);
        try add(&seen, &s);
    }
    try add(&seen, base[0..99]);
}

test "prefix order agrees with byte order" {
    var i: Interner = try .init(testing.allocator);
    defer i.deinit();
    const names = [_][]const u8{ "", "a", "a\x00", "a\x00b", "ab", "abcdefgh", "abcdefghi", "abcdefgg", "\xff", "B" };
    var syms: [names.len]Sym = undefined;
    for (names, &syms) |n, *s| s.* = try i.intern(n);
    for (names, syms) |x, a| for (names, syms) |y, b| {
        const by_prefix = switch (std.math.order(i.prefix(a), i.prefix(b))) {
            .eq => std.mem.order(u8, x, y),
            else => |o| o,
        };
        try testing.expectEqual(std.mem.order(u8, x, y), by_prefix);
    };
}

test "intern is stable and shared" {
    var i: Interner = try .init(testing.allocator);
    defer i.deinit();
    const a = try i.intern("foo");
    const b = try i.intern("bar");
    try testing.expect(a != b);
    try testing.expectEqual(a, try i.intern("foo"));
    try testing.expectEqualStrings("foo", i.name(a));
    try testing.expectEqual(b, i.get("bar").?);
    try testing.expectEqual(null, i.get("baz"));
    var j = try i.fork();
    defer j.deinit();
    const c = try j.intern("baz");
    try testing.expectEqual(c, i.get("baz").?);
    try testing.expectEqual(3, i.count());
}

test "empty name misses the cache sentinel" {
    var i: Interner = try .init(testing.allocator);
    defer i.deinit();
    const e = try i.intern("");
    try testing.expectEqualStrings("", i.name(e));
    try testing.expectEqual(e, try i.intern(""));
    try testing.expectEqual(1, i.count());
}

test "many names grow the shards and chunks" {
    var i: Interner = try .init(testing.allocator);
    defer i.deinit();
    var buf: [16]u8 = undefined;
    for (0..20000) |k| {
        const n = std.fmt.bufPrint(&buf, "a{d}", .{k}) catch unreachable;
        try testing.expectEqual(k, (try i.intern(n)).index());
    }
    for (0..20000) |k| {
        const n = std.fmt.bufPrint(&buf, "a{d}", .{k}) catch unreachable;
        try testing.expectEqualStrings(n, i.name(i.get(n).?));
    }
}

test "concurrent intern agrees" {
    const gpa = std.heap.smp_allocator;
    var i: Interner = try .init(gpa);
    defer i.deinit();
    const n_threads = 8;
    const Result = [5000]Sym;
    var results: [n_threads]Result = undefined;
    var handles: [n_threads]Interner = undefined;
    var threads: [n_threads]std.Thread = undefined;
    const run = struct {
        fn f(h: *Interner, t: u32, out: *Result) void {
            var buf: [16]u8 = undefined;
            for (out, 0..) |*o, k| {
                const n = std.fmt.bufPrint(&buf, "sym{d}", .{(@as(u32, @intCast(k)) * 7 + t) % 3000}) catch unreachable;
                o.* = h.intern(n) catch unreachable;
            }
        }
    }.f;
    for (&threads, &handles, &results, 0..) |*th, *h, *r, t| {
        h.* = try i.fork();
        th.* = try std.Thread.spawn(.{}, run, .{ h, @as(u32, @intCast(t)), r });
    }
    for (threads) |th| th.join();
    for (&handles) |*h| h.deinit();
    var buf: [16]u8 = undefined;
    for (results, 0..) |r, t| for (r, 0..) |s, k| {
        const n = std.fmt.bufPrint(&buf, "sym{d}", .{(k * 7 + t) % 3000}) catch unreachable;
        try testing.expectEqualStrings(n, i.name(s));
        try testing.expectEqual(s, i.get(n).?);
    };
    try testing.expectEqual(3000, i.count());
}
