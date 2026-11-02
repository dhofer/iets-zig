//! Binary format of the cache entry parts: a tag byte per record, LEB128
//! lengths, raw bytes. One format version byte leads every part. The bytes
//! are the ones Rust iets writes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const trace = @import("../trace.zig");
const Obs = trace.Obs;
const Digest = trace.Digest;
const Diag = @import("../diag.zig").Diag;
const store_path = @import("../store/path.zig");
const StorePath = store_path.StorePath;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const source = @import("../store/source.zig");
const derivation = @import("../builtins/derivation.zig");

pub const version: u8 = 7;

const Enc = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,

    fn init(a: Allocator, versioned: bool) Allocator.Error!Enc {
        var e: Enc = .{ .a = a };
        if (versioned) try e.byte(version);
        return e;
    }

    fn byte(e: *Enc, b: u8) Allocator.Error!void {
        try e.out.append(e.a, b);
    }

    fn uint(e: *Enc, n_: u64) Allocator.Error!void {
        var n = n_;
        while (true) {
            const b: u8 = @truncate(n & 0x7f);
            n >>= 7;
            if (n == 0) return e.byte(b);
            try e.byte(b | 0x80);
        }
    }

    fn int(e: *Enc, n: i64) Allocator.Error!void {
        return e.uint(@bitCast(n));
    }

    fn bytes(e: *Enc, b: []const u8) Allocator.Error!void {
        try e.uint(b.len);
        try e.out.appendSlice(e.a, b);
    }

    fn optBytes(e: *Enc, b: ?[]const u8) Allocator.Error!void {
        if (b) |x| {
            try e.byte(1);
            try e.bytes(x);
        } else try e.byte(0);
    }

    fn digest(e: *Enc, d: *const Digest) Allocator.Error!void {
        try e.out.appendSlice(e.a, d);
    }

    fn list(e: *Enc, items: []const []const u8) Allocator.Error!void {
        try e.uint(items.len);
        for (items) |i| try e.bytes(i);
    }

    fn done(e: *Enc) Allocator.Error![]u8 {
        return e.out.toOwnedSlice(e.a);
    }
};

const Bad = error{Bad};

/// A reader over one part; every slice it returns points into the part.
const Dec = struct {
    b: []const u8,
    i: usize = 0,

    fn init(b: []const u8) Bad!Dec {
        var d: Dec = .{ .b = b };
        if (try d.byte() != version) return error.Bad;
        return d;
    }

    fn done(d: *const Dec) bool {
        return d.i >= d.b.len;
    }

    fn byte(d: *Dec) Bad!u8 {
        if (d.i >= d.b.len) return error.Bad;
        d.i += 1;
        return d.b[d.i - 1];
    }

    fn uint(d: *Dec) Bad!u64 {
        var n: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = try d.byte();
            if (shift >= 64) return error.Bad;
            n |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return n;
            shift += 7;
        }
    }

    fn int(d: *Dec) Bad!i64 {
        return @bitCast(try d.uint());
    }

    fn bytes(d: *Dec) Bad![]const u8 {
        const n = std.math.cast(usize, try d.uint()) orelse return error.Bad;
        const end = std.math.add(usize, d.i, n) catch return error.Bad;
        if (end > d.b.len) return error.Bad;
        defer d.i = end;
        return d.b[d.i..end];
    }

    fn optBytes(d: *Dec) Bad!?[]const u8 {
        return switch (try d.byte()) {
            0 => null,
            1 => try d.bytes(),
            else => error.Bad,
        };
    }

    fn flag(d: *Dec) Bad!bool {
        return switch (try d.byte()) {
            0 => false,
            1 => true,
            else => error.Bad,
        };
    }

    fn digest(d: *Dec) Bad!Digest {
        if (d.b.len - d.i < 32) return error.Bad;
        defer d.i += 32;
        return d.b[d.i..][0..32].*;
    }

    fn list(d: *Dec, a: Allocator) (Bad || Allocator.Error)![]const []const u8 {
        const n = try d.uint();
        // a count no part can hold is refused before anything is allocated
        if (n > d.b.len - d.i) return error.Bad;
        const out = try a.alloc([]const u8, @intCast(n));
        for (out) |*o| o.* = try d.bytes();
        return out;
    }
};

fn putObs(e: *Enc, o: Obs) Allocator.Error!void {
    try e.byte(@backingInt(std.meta.activeTag(o)));
    switch (o) {
        .file => |x| {
            try e.bytes(x.path);
            try e.uint(x.size);
            try e.int(x.mtime_ns);
            try e.int(x.ctime_ns);
            try e.uint(x.dev);
            try e.uint(x.ino);
            try e.digest(&x.hash);
        },
        .dir => |x| {
            try e.bytes(x.path);
            try e.digest(&x.hash);
        },
        .stat => |x| {
            try e.bytes(x.path);
            try e.byte(@intFromBool(x.follow));
            try e.byte(@backingInt(x.kind));
        },
        .tree => |x| {
            try e.bytes(x.root);
            try e.digest(&x.nar_hash);
            try e.digest(&x.stat_hash);
            if (x.filtered) |f| {
                try e.byte(1);
                if (f.seen_hash) |*h| {
                    try e.byte(1);
                    try e.digest(h);
                } else try e.byte(0);
                try e.list(f.accepted);
            } else try e.byte(0);
            if (x.newest) |n| {
                try e.byte(1);
                try e.int(n);
            } else try e.byte(0);
        },
        .canon => |x| {
            try e.bytes(x.path);
            try e.optBytes(x.target);
        },
        .env => |x| {
            try e.bytes(x.name);
            if (x.value) |*h| {
                try e.byte(1);
                try e.digest(h);
            } else try e.byte(0);
        },
        .cmd => |x| {
            try e.bytes(x.dir);
            try e.byte(@backingInt(x.query));
            try e.digest(&x.hash);
        },
        .input => |x| {
            try e.bytes(x.entry);
            try e.byte(x.version);
        },
    }
}

fn getObs(d: *Dec, a: Allocator) (Bad || Allocator.Error)!Obs {
    return switch (try d.byte()) {
        0 => .{ .file = .{
            .path = try d.bytes(),
            .size = try d.uint(),
            .mtime_ns = try d.int(),
            .ctime_ns = try d.int(),
            .dev = try d.uint(),
            .ino = try d.uint(),
            .hash = try d.digest(),
        } },
        1 => .{ .dir = .{ .path = try d.bytes(), .hash = try d.digest() } },
        2 => .{ .stat = .{
            .path = try d.bytes(),
            .follow = try d.byte() != 0,
            .kind = trace.Kind.fromU8(try d.byte()) orelse return error.Bad,
        } },
        3 => blk: {
            const root = try d.bytes();
            const nar_hash = try d.digest();
            const stat_hash = try d.digest();
            const filtered: ?trace.Filtered = if (try d.flag()) .{
                .seen_hash = if (try d.flag()) try d.digest() else null,
                .accepted = try d.list(a),
            } else null;
            const newest: ?i64 = if (try d.flag()) try d.int() else null;
            break :blk .{ .tree = .{ .root = root, .nar_hash = nar_hash, .stat_hash = stat_hash, .filtered = filtered, .newest = newest } };
        },
        4 => .{ .canon = .{ .path = try d.bytes(), .target = try d.optBytes() } },
        5 => .{ .env = .{ .name = try d.bytes(), .value = if (try d.flag()) try d.digest() else null } },
        6 => .{ .cmd = .{
            .dir = try d.bytes(),
            .query = trace.Query.fromU8(try d.byte()) orelse return error.Bad,
            .hash = try d.digest(),
        } },
        7 => .{ .input = .{ .entry = try d.bytes(), .version = try d.byte() } },
        else => error.Bad,
    };
}

/// One observation alone, for exact-duplicate detection.
pub fn encodeReadset(a: Allocator, obs: []const Obs) Allocator.Error![]u8 {
    var e: Enc = try .init(a, true);
    try e.uint(obs.len);
    for (obs) |o| try putObs(&e, o);
    return e.done();
}

/// The observations of a read set; null for bytes that are not one. The
/// subjects point into `b`, the slice is `a`'s.
pub fn decodeReadset(a: Allocator, b: []const u8) Allocator.Error!?[]Obs {
    var d = Dec.init(b) catch return null;
    const n = d.uint() catch return null;
    if (n > b.len) return null;
    var out: std.ArrayList(Obs) = try .initCapacity(a, @intCast(n));
    errdefer out.deinit(a);
    for (0..@intCast(n)) |_| out.appendAssumeCapacity(getObs(&d, a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => {
            out.deinit(a);
            return null;
        },
    });
    if (!d.done()) {
        out.deinit(a);
        return null;
    }
    return try out.toOwnedSlice(a);
}

/// A root `iets build` resolved: the drv path and the output named by context.
pub const Root = struct { drv: StorePath, output: ?[]const u8 };

pub fn encodeRoots(a: Allocator, roots: []const Root) Allocator.Error![]u8 {
    var e: Enc = try .init(a, true);
    try e.uint(roots.len);
    for (roots) |r| {
        try e.bytes(r.drv.baseName());
        try e.optBytes(r.output);
    }
    return e.done();
}

fn storePathOf(b: []const u8) Bad!StorePath {
    if (!std.unicode.utf8ValidateSlice(b)) return error.Bad;
    return StorePath.ofBaseName(b) orelse error.Bad;
}

pub fn decodeRoots(a: Allocator, b: []const u8) Allocator.Error!?[]Root {
    var d = Dec.init(b) catch return null;
    const n = d.uint() catch return null;
    if (n > b.len) return null;
    const out = try a.alloc(Root, @intCast(n));
    for (out) |*r| {
        r.drv = storePathOf(d.bytes() catch return null) catch return null;
        r.output = d.optBytes() catch return null;
        if (r.output) |o| if (!std.unicode.utf8ValidateSlice(o)) return null;
    }
    if (!d.done()) return null;
    return out;
}

/// One derivation of a `build` entry: what `derivation.Info` holds of it,
/// and the attribute it came from when known.
pub const Drv = struct {
    path: StorePath,
    /// Sorted.
    outputs: []const []const u8,
    /// Base names, sorted.
    references: []const []const u8,
    aterm: []const u8,
    attr: ?[]const u8 = null,
};

fn baseOf(p: []const u8) []const u8 {
    return if (store_path.stripStoreDir(p)) |rest| rest else p;
}

fn drvLess(_: void, x: Drv, y: Drv) bool {
    return std.mem.lessThan(u8, x.path.baseName(), y.path.baseName());
}

/// Every derivation this evaluation produced (the ones with an ATerm), by
/// `.drv` base name; drvs read from `/nix/store` are re-read by the planner.
pub fn encodeDrvs(a: Allocator, table: *const std.StringHashMapUnmanaged(derivation.Info)) (Allocator.Error || Bad)![]u8 {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var items: std.ArrayList(Drv) = .empty;
    var it = table.iterator();
    while (it.next()) |kv| {
        const aterm = kv.value_ptr.aterm orelse continue;
        const refs = try sa.alloc([]const u8, kv.value_ptr.references.len);
        for (kv.value_ptr.references, refs) |r, *o| o.* = baseOf(r);
        std.mem.sortUnstable([]const u8, refs, {}, lessBytes);
        try items.append(sa, .{ .path = try storePathOf(kv.key_ptr.*), .outputs = kv.value_ptr.outputs, .references = refs, .aterm = aterm, .attr = kv.value_ptr.attr });
    }
    std.mem.sortUnstable(Drv, items.items, {}, drvLess);
    return encodeDrvList(a, items.items);
}

fn lessBytes(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// `encodeDrvs` of a list already sorted by path.
pub fn encodeDrvList(a: Allocator, drvs: []const Drv) Allocator.Error![]u8 {
    var e: Enc = try .init(a, true);
    try e.uint(drvs.len);
    for (drvs) |x| {
        try e.bytes(x.path.baseName());
        try e.list(x.outputs);
        try e.list(x.references);
        try e.bytes(x.aterm);
        try e.optBytes(x.attr);
    }
    return e.done();
}

pub fn decodeDrvs(a: Allocator, b: []const u8) Allocator.Error!?[]Drv {
    var d = Dec.init(b) catch return null;
    const n = d.uint() catch return null;
    if (n > b.len) return null;
    const out = try a.alloc(Drv, @intCast(n));
    for (out) |*x| x.* = decodeDrv(&d, a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => return null,
    };
    if (!d.done()) return null;
    return out;
}

fn decodeDrv(d: *Dec, a: Allocator) (Bad || Allocator.Error)!Drv {
    const path = try storePathOf(try d.bytes());
    const outputs = try d.list(a);
    for (outputs) |o| if (!std.unicode.utf8ValidateSlice(o)) return error.Bad;
    const refs = try d.list(a);
    for (refs) |r| _ = try storePathOf(r);
    const aterm = try d.bytes();
    const attr = try d.optBytes();
    if (attr) |x| if (!std.unicode.utf8ValidateSlice(x)) return error.Bad;
    return .{ .path = path, .outputs = outputs, .references = refs, .aterm = aterm, .attr = attr };
}

/// One source of a `build` entry: its store path and where its bytes are.
pub const Source = struct { path: StorePath, origin: source.SourceOrigin };

fn sourceLess(_: void, x: Source, y: Source) bool {
    return std.mem.lessThan(u8, x.path.baseName(), y.path.baseName());
}

fn acceptedSet(e: *Enc, sa: Allocator, accepted: ?*const source.PathSet) Allocator.Error!void {
    const set = accepted orelse return e.byte(0);
    try e.byte(1);
    const v = try sa.alloc([]const u8, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) v[i] = k.*;
    std.mem.sortUnstable([]const u8, v, {}, lessBytes);
    try e.list(v);
}

/// Where each source's bytes were, sorted by store path.
pub fn encodeSources(a: Allocator, sources: []Source) Allocator.Error![]u8 {
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    std.mem.sortUnstable(Source, sources, {}, sourceLess);
    var e: Enc = try .init(a, true);
    try e.uint(sources.len);
    for (sources) |s| {
        try e.bytes(s.path.baseName());
        switch (s.origin.at.src) {
            .fs => |f| {
                try e.byte(0);
                try e.bytes(f.root);
                try acceptedSet(&e, sa, f.accepted);
            },
            .spool => |sp| {
                try e.byte(1);
                try e.bytes(sp.name);
                try acceptedSet(&e, sa, sp.accepted);
            },
            .mem => |m| {
                try e.byte(2);
                try e.bytes(m);
            },
        }
        try e.bytes(s.origin.at.rel);
        switch (s.origin.kind) {
            .source => try e.byte(0),
            .text => |refs| {
                try e.byte(1);
                try e.uint(refs.len);
                for (refs) |r| try e.bytes(r.baseName());
            },
            .flat => |h| {
                try e.byte(2);
                try e.bytes(h.algo.name());
                try e.bytes(h.bytes());
            },
        }
        if (s.origin.nar) |n| {
            try e.byte(1);
            try e.bytes(n.hash.bytes());
            try e.uint(n.size);
        } else try e.byte(0);
    }
    return e.done();
}

/// Opens an input-store entry by name for a decoded spool source.
pub const OpenTree = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, name: []const u8) ?*const @import("../treestore.zig").StoredTree,
};

pub fn decodeSources(a: Allocator, b: []const u8, trees: ?OpenTree) Allocator.Error!?[]Source {
    var d = Dec.init(b) catch return null;
    const n = d.uint() catch return null;
    if (n > b.len) return null;
    const out = try a.alloc(Source, @intCast(n));
    for (out) |*s| s.* = decodeSource(&d, a, trees) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => return null,
    };
    if (!d.done()) return null;
    return out;
}

fn readAccepted(d: *Dec, a: Allocator) (Bad || Allocator.Error)!?*const source.PathSet {
    if (!try d.flag()) return null;
    const items = try d.list(a);
    const set = try a.create(source.PathSet);
    set.* = .empty;
    for (items) |p| try set.put(a, p, {});
    return set;
}

fn decodeSource(d: *Dec, a: Allocator, trees: ?OpenTree) (Bad || Allocator.Error)!Source {
    const path = try storePathOf(try d.bytes());
    const src: source.Src = switch (try d.byte()) {
        0 => .{ .fs = .{ .root = try d.bytes(), .accepted = try readAccepted(d, a) } },
        1 => blk: {
            const name = try d.bytes();
            if (!std.unicode.utf8ValidateSlice(name)) return error.Bad;
            const accepted = try readAccepted(d, a);
            const t = trees orelse return error.Bad;
            const tree = t.open(t.ctx, name) orelse return error.Bad;
            break :blk .{ .spool = .{ .name = name, .tree = tree, .accepted = accepted } };
        },
        2 => .{ .mem = try d.bytes() },
        else => return error.Bad,
    };
    const rel = try d.bytes();
    const kind: source.SourceKind = switch (try d.byte()) {
        0 => .source,
        1 => blk: {
            const names = try d.list(a);
            const refs = try a.alloc(StorePath, names.len);
            for (names, refs) |nm, *r| r.* = try storePathOf(nm);
            break :blk .{ .text = refs };
        },
        2 => blk: {
            const algo_name = try d.bytes();
            const algo = hash_mod.Algo.parse(algo_name) orelse return error.Bad;
            const hb = try d.bytes();
            if (hb.len != algo.size()) return error.Bad;
            break :blk .{ .flat = Hash.raw(algo, hb) };
        },
        else => return error.Bad,
    };
    const nar: ?source.NarHash = if (try d.flag()) blk: {
        const hb = try d.bytes();
        if (hb.len != 32) return error.Bad;
        break :blk .{ .hash = Hash.raw(.sha256, hb), .size = try d.uint() };
    } else null;
    return .{ .path = path, .origin = .{ .at = .{ .src = src, .rel = rel }, .kind = kind, .nar = nar } };
}

const testing = std.testing;

test "a read set round-trips" {
    const obs = [_]Obs{
        .{ .file = .{ .path = "/a", .size = 3, .mtime_ns = -5, .ctime_ns = -4, .dev = 66, .ino = 1 << 40, .hash = @splat(7) } },
        .{ .dir = .{ .path = "/d", .hash = @splat(1) } },
        .{ .stat = .{ .path = "/s", .follow = true, .kind = .symlink } },
        .{ .tree = .{ .root = "/t", .nar_hash = @splat(2), .stat_hash = @splat(3), .filtered = .{ .seen_hash = @splat(4), .accepted = &.{"/t/x"} }, .newest = -7 } },
        .{ .canon = .{ .path = "/c", .target = null } },
        .{ .env = .{ .name = "HOME", .value = @splat(9) } },
    };
    const a = testing.allocator;
    const b = try encodeReadset(a, &obs);
    defer a.free(b);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const back = (try decodeReadset(arena.allocator(), b)).?;
    try testing.expectEqual(obs.len, back.len);
    for (obs, back) |x, y| try testing.expect(x.eql(y));
    try testing.expect(try decodeReadset(arena.allocator(), b[0 .. b.len - 1]) == null);
}

test "drvs, sources and roots round-trip" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var d: Diag = .init(a);
    defer d.deinit();
    const p = try StorePath.fromBaseName("a3ck4d9zzk4l1r76rz5zv2wgycmpsy1y-x.drv", &d);
    const s = try StorePath.fromBaseName("a3ck4d9zzk4l1r76rz5zv2wgycmpsy1y-src", &d);
    var table: std.StringHashMapUnmanaged(derivation.Info) = .empty;
    defer table.deinit(a);
    try table.put(a, p.baseName(), .{ .outputs = &.{"out"}, .references = &.{"/nix/store/a3ck4d9zzk4l1r76rz5zv2wgycmpsy1y-src"}, .aterm = "Derive(...)" });
    try table.put(a, s.baseName(), .{ .outputs = &.{}, .references = &.{} });
    const enc = try encodeDrvs(a, &table);
    defer a.free(enc);
    const back = (try decodeDrvs(aa, enc)).?;
    try testing.expectEqual(1, back.len);
    try testing.expectEqualStrings("Derive(...)", back[0].aterm);
    try testing.expectEqualStrings(s.baseName(), back[0].references[0]);

    const hash = @import("../store/nar.zig").narHashOfString("x");
    var acc: source.PathSet = .empty;
    try acc.put(aa, "/tmp/x/a", {});
    const f = try StorePath.fromBaseName("3ay25cl2lpykmx07i7m22qxz7zwzqmvy-hello.txt", &d);
    const flat = try Hash.parseAny("113a52l57f2jv9fh9igj2xh2mi0is40flxbkqi69wbh7nlybkcbm", .sha256, &d);
    var sources = [_]Source{
        .{ .path = s, .origin = .tree(.fs("/tmp/x", &acc), hash, 152) },
        .{ .path = p, .origin = .text("hi", &.{s}) },
        .{ .path = f, .origin = .flat(.fs("/tmp/hello.txt", null), flat, hash, 9) },
    };
    const se = try encodeSources(a, &sources);
    defer a.free(se);
    const sb = (try decodeSources(aa, se, null)).?;
    try testing.expectEqual(3, sb.len);
    for (sb) |x| {
        if (x.path.eql(&f)) {
            try testing.expect(x.origin.kind.flat.eql(flat));
            try testing.expectEqual(9, x.origin.nar.?.size);
        } else if (x.path.eql(&s)) {
            try testing.expectEqualStrings("/tmp/x", x.origin.at.src.fs.root);
            try testing.expect(x.origin.at.src.fs.accepted.?.contains("/tmp/x/a"));
            try testing.expectEqual(152, x.origin.nar.?.size);
        } else {
            try testing.expectEqualStrings("hi", x.origin.at.src.mem);
            try testing.expect(x.origin.kind.text[0].eql(&s));
            try testing.expect(x.origin.nar == null);
        }
    }

    // a spool source keeps its filter, its members named under `/`
    const StoredTree = @import("../treestore.zig").StoredTree;
    var macc: source.PathSet = .empty;
    try macc.put(aa, "/lib", {});
    const never: *const StoredTree = @ptrFromInt(@alignOf(StoredTree));
    var spooled = [_]Source{.{ .path = s, .origin = .tree(.spool(s.baseName(), never, &macc, "lib"), hash, 7) }};
    const pe = try encodeSources(a, &spooled);
    defer a.free(pe);
    const open: OpenTree = .{ .ctx = undefined, .open = struct {
        fn go(_: *anyopaque, _: []const u8) ?*const StoredTree {
            return @ptrFromInt(@alignOf(StoredTree));
        }
    }.go };
    const pb = (try decodeSources(aa, pe, open)).?;
    const sp = pb[0].origin.at;
    try testing.expectEqualStrings("lib", sp.rel);
    try testing.expectEqualStrings(s.baseName(), sp.src.spool.name);
    try testing.expect(sp.src.spool.accepted.?.contains("/lib") and !sp.src.spool.accepted.?.contains("/lib/x"));

    const roots = [_]Root{ .{ .drv = p, .output = "out" }, .{ .drv = p, .output = null } };
    const re = try encodeRoots(a, &roots);
    defer a.free(re);
    const rb = (try decodeRoots(aa, re)).?;
    try testing.expectEqual(2, rb.len);
    try testing.expectEqualStrings("out", rb[0].output.?);
    try testing.expect(rb[1].output == null and rb[1].drv.eql(&p));
}
