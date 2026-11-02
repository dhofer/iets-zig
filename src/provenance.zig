//! Provenance: store paths back to the local trees they came from, and
//! derivations back to the attribute and the source position that defined
//! them. See docs/explanation/provenance.md.
//!
//! `IETS_PROVENANCE=0` (`Settings.provenance`) turns every rewrite off, so a
//! byte comparison against the real nix sees the plain store paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const store_path = @import("store/path.zig");
const Evaluator = @import("eval/Evaluator.zig");
const Pos = @import("syntax/pos.zig").Pos;
const Pair = @import("config.zig").Override;

/// How many times a mapping may point at another mapped tree.
const max_hops = 8;

/// A byte a store path's base name may hold (path.cc:checkName).
fn isNameByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or switch (b) {
        '+', '-', '.', '_', '?', '=' => true,
        else => false,
    };
}

/// A pseudo-file (`«derivation-internal»`, `«arg»`) rather than a real path.
fn isPseudo(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "«");
}

const Entry = struct { prefix: []const u8, local: []const u8 };

/// Store-path prefix to local directory, longest match first. Everything
/// lives in its arena.
pub const SourceMap = struct {
    arena: std.heap.ArenaAllocator,
    /// Sorted by prefix, descending: the longest match of any prefix of a
    /// path is the first entry that matches.
    entries: std.ArrayList(Entry) = .empty,
    /// Locked input trees by lock node name, for positions only: the name
    /// is not a path, so text rewrites never use it.
    inputs: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) SourceMap {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *SourceMap) void {
        m.arena.deinit();
    }

    /// Adds one mapping. Call `sort` once every mapping is in.
    pub fn insert(m: *SourceMap, prefix: []const u8, local: []const u8) !void {
        const a = m.arena.allocator();
        try m.entries.append(a, .{ .prefix = try a.dupe(u8, prefix), .local = try a.dupe(u8, local) });
    }

    /// A locked input tree, named by its lock node.
    pub fn insertInput(m: *SourceMap, prefix: []const u8, name: []const u8) !void {
        const a = m.arena.allocator();
        try m.inputs.append(a, .{ .prefix = try a.dupe(u8, prefix), .local = try a.dupe(u8, name) });
    }

    /// Orders the entries for matching and resolves the chains: a tree
    /// copied from a tree that is itself in the store (`./.` inside a flake
    /// already in the store) must land on the local directory, not on the
    /// store path in between.
    pub fn sort(m: *SourceMap) !void {
        std.mem.sort(Entry, m.entries.items, {}, struct {
            fn gt(_: void, x: Entry, y: Entry) bool {
                return std.mem.order(u8, x.prefix, y.prefix) == .gt;
            }
        }.gt);
        // dedup consecutive equal prefixes, keeping the first
        var w: usize = 0;
        for (m.entries.items, 0..) |e, i| {
            if (i > 0 and std.mem.eql(u8, e.prefix, m.entries.items[w - 1].prefix)) continue;
            m.entries.items[w] = e;
            w += 1;
        }
        m.entries.shrinkRetainingCapacity(w);
        const a = m.arena.allocator();
        for (0..max_hops) |_| {
            var changed = false;
            const resolved = try a.alloc(?[]const u8, m.entries.items.len);
            for (m.entries.items, resolved) |e, *r| r.* = try m.locate(a, e.local);
            for (m.entries.items, resolved) |*e, r| if (r) |x| if (!std.mem.eql(u8, x, e.local)) {
                e.local = x;
                changed = true;
            };
            if (!changed) break;
        }
    }

    fn find(m: *const SourceMap, path: []const u8) ?Entry {
        for (m.entries.items) |e| if (std.mem.startsWith(u8, path, e.prefix)) return e;
        return null;
    }

    /// The local path `path` came from, with the tail below the mapped
    /// prefix kept; in `a`.
    pub fn locate(m: *const SourceMap, a: Allocator, path: []const u8) !?[]const u8 {
        const e = m.find(path) orelse return null;
        return try std.mem.concat(a, u8, &.{ e.local, path[e.prefix.len..] });
    }

    /// `<input>/<tail>` for a file inside a locked input no local
    /// directory stands for; in `a`.
    pub fn label(m: *const SourceMap, a: Allocator, path: []const u8) !?[]const u8 {
        for (m.inputs.items) |e| {
            if (!std.mem.startsWith(u8, path, e.prefix)) continue;
            const rest = path[e.prefix.len..];
            if (rest.len == 0 or rest[0] == '/') return try std.mem.concat(a, u8, &.{ e.local, rest });
        }
        return null;
    }

    /// Every store path this map knows, replaced by its local path. Only
    /// the `<store>/<base>` segments are looked at, so a long log line costs
    /// one search per store path in it.
    pub fn rewrite(m: *const SourceMap, w: *std.Io.Writer, text: []const u8) !void {
        if (m.entries.items.len == 0) return w.writeAll(text);
        const store = store_path.store_dir;
        var i: usize = 0;
        var done: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, store)) |at| {
            i = at + 1;
            if (at + store.len >= text.len or text[at + store.len] != '/') continue;
            const start = at + store.len + 1;
            var end = start;
            while (end < text.len and isNameByte(text[end])) end += 1;
            const e = m.find(text[at..end]) orelse continue;
            try w.writeAll(text[done..at]);
            try w.writeAll(e.local);
            try w.writeAll(text[at + e.prefix.len .. end]);
            done = end;
            i = end;
        }
        try w.writeAll(text[done..]);
    }

    pub fn rewriteAlloc(m: *const SourceMap, a: Allocator, text: []const u8) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        try m.rewrite(&buf.writer, text);
        return buf.toOwnedSlice();
    }

    /// The trees this evaluation copied, plus the `source-map` setting.
    pub fn fromEval(gpa: Allocator, ev: *Evaluator, source_map: []const Pair) !SourceMap {
        var m: SourceMap = .init(gpa);
        errdefer m.deinit();
        {
            ev.shared.hooks_lock.lockUncancelable(ev.io);
            defer ev.shared.hooks_lock.unlock(ev.io);
            var it = ev.shared.hooks.known.iterator();
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            while (it.next()) |kv| switch (kv.value_ptr.src) {
                .fs => |f| {
                    const prefix = std.fmt.bufPrint(&buf, "{s}/{s}", .{ store_path.store_dir, kv.key_ptr.* }) catch continue;
                    try m.insert(prefix, f.root);
                },
                // a fetched tree has no local path to name
                .mem, .tree => {},
            };
            // the locked trees no local directory stands for, by lock node
            // name
            var fl = ev.shared.hooks.flakes.iterator();
            while (fl.next()) |kv| {
                if (ev.shared.hooks.known.get(kv.key_ptr.*)) |o| if (o.src == .fs) continue;
                const prefix = std.fmt.bufPrint(&buf, "{s}/{s}", .{ store_path.store_dir, kv.key_ptr.* }) catch continue;
                try m.insertInput(prefix, kv.value_ptr.*);
            }
        }
        for (source_map) |p| try m.insert(p.name, p.value);
        try m.sort();
        return m;
    }
};

/// `file:line:col` of `pos`, the local path when the file is a copy of one;
/// in `a`. Null when the position is unknown or inside a pseudo-file.
pub fn describePos(a: Allocator, ev: *Evaluator, map: ?*const SourceMap, pos: Pos) !?[]const u8 {
    const l = ev.files.locate(pos) orelse return null;
    if (isPseudo(l.file.path)) return null;
    var path: []const u8 = l.file.path;
    if (map) |m| path = try m.locate(a, path) orelse try m.label(a, path) orelse path;
    return try std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ path, l.line, l.column });
}

/// `pos` as an error shows it: `describePos`, else the evaluator's own
/// `file:line:col` or `«none»`.
pub fn errorPos(a: Allocator, ev: *Evaluator, map: ?*const SourceMap, pos: Pos) ![]const u8 {
    if (try describePos(a, ev, map, pos)) |p| return p;
    return std.fmt.allocPrint(a, "{f}", .{ev.files.at(pos)});
}

/// `pos` unless it is unknown or in a pseudo-file.
pub fn realPos(ev: *Evaluator, pos: Pos) ?Pos {
    const l = ev.files.locate(pos) orelse return null;
    return if (isPseudo(l.file.path)) null else pos;
}

/// The derivation name inside a `.drv` store path: no hash, no extension.
/// What a build line calls a derivation no attribute points at.
pub fn drvName(drv_path: []const u8) []const u8 {
    const base = std.fs.path.basename(drv_path);
    const name = if (std.mem.endsWith(u8, base, ".drv")) base[0 .. base.len - 4] else base;
    if (std.mem.indexOfScalar(u8, name, '-')) |i| if (i == 32) return name[i + 1 ..];
    return name;
}

/// Where one derivation was defined.
pub const Site = struct {
    /// The attribute path the cli walked to it.
    attr: ?[]const u8 = null,
    /// `file:line:col` of the `derivation` call, already mapped.
    pos: ?[]const u8 = null,
    /// Another derivation of the evaluation has the same position, so it
    /// tells them apart only on a failure line.
    shared: bool = false,

    /// The position when it names this derivation alone.
    pub fn ownPos(s: Site) ?[]const u8 {
        return if (s.shared) null else s.pos;
    }
};

/// Everything the build side needs after the evaluator is gone: the source
/// map and one `Site` per derivation this evaluation created. `snapshot`
/// takes each derivation's attribute and position from its caller
/// (`api.build.snapshot` reads them from the derivation table).
pub const Provenance = struct {
    map: SourceMap,
    sites: std.StringHashMapUnmanaged(Site) = .empty,
    on: bool = false,

    /// Provenance that maps and names nothing.
    pub fn off(gpa: Allocator) Provenance {
        return .{ .map = .init(gpa) };
    }

    /// Rewriting only: no derivation is named. This is what a run that hit
    /// the evaluation cache can offer, because the cache keeps no positions.
    pub fn fromMap(map: SourceMap, enabled: bool) Provenance {
        return .{ .map = map, .on = enabled };
    }

    pub fn deinit(p: *Provenance) void {
        p.sites.deinit(p.map.arena.child_allocator);
        p.map.deinit();
    }

    pub const Drv = struct { path: []const u8, attr: ?[]const u8, pos: ?Pos };

    /// The map and the sites of `drvs`, the derivations of `ev`.
    pub fn snapshot(gpa: Allocator, ev: *Evaluator, source_map: []const Pair, drvs: []const Drv, enabled: bool) !Provenance {
        if (!enabled) return .off(gpa);
        var p: Provenance = .{ .map = try .fromEval(gpa, ev, source_map), .on = true };
        errdefer p.deinit();
        const a = p.map.arena.allocator();
        var uses: std.AutoHashMapUnmanaged(Pos, usize) = .empty;
        defer uses.deinit(gpa);
        for (drvs) |d| if (d.pos) |pos| {
            const g = try uses.getOrPut(gpa, pos);
            g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
        };
        for (drvs) |d| {
            if (d.attr == null and d.pos == null) continue;
            try p.sites.put(gpa, try a.dupe(u8, d.path), .{
                .attr = if (d.attr) |x| try a.dupe(u8, x) else null,
                .pos = if (d.pos) |pos| try describePos(a, ev, &p.map, pos) else null,
                .shared = if (d.pos) |pos| uses.get(pos).? > 1 else false,
            });
        }
        return p;
    }

    pub fn site(p: *const Provenance, drv_path: []const u8) ?Site {
        if (!p.on) return null;
        return p.sites.get(drv_path);
    }

    pub fn rewrite(p: *const Provenance, w: *std.Io.Writer, text: []const u8) !void {
        if (!p.on) return w.writeAll(text);
        return p.map.rewrite(w, text);
    }

    /// The attribute alone, for a caller that shows the position itself.
    pub fn attrOf(p: *const Provenance, drv_path: []const u8) ?[]const u8 {
        return (p.site(drv_path) orelse return null).attr;
    }

    /// What is being built: `<attr> (<file>:<line>:<col>)`, as much as is
    /// known; in `a`. Null when nothing is.
    pub fn nameOf(p: *const Provenance, a: Allocator, drv_path: []const u8) !?[]const u8 {
        const s = p.site(drv_path) orelse return null;
        const what = s.attr orelse drvName(drv_path);
        if (s.ownPos()) |pos| return try std.fmt.allocPrint(a, "{s} ({s})", .{ what, pos });
        return try a.dupe(u8, what);
    }

    /// The `building ...` line, when provenance is known.
    pub fn started(p: *const Provenance, a: Allocator, drv_path: []const u8) !?[]const u8 {
        const n = try p.nameOf(a, drv_path) orelse return null;
        return try std.fmt.allocPrint(a, "building {s}", .{n});
    }

    /// The `error: build of ... failed` line, when provenance is known.
    pub fn failed(p: *const Provenance, a: Allocator, drv_path: []const u8, reason: []const u8) !?[]const u8 {
        const s = p.site(drv_path) orelse return null;
        const base = std.fs.path.basename(drv_path);
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        const w = &buf.writer;
        try w.print("error: build of {s} failed ({s})", .{ s.attr orelse drvName(drv_path), base });
        if (s.pos) |pos| try w.print(", defined at {s}", .{pos});
        if (reason.len > 0) {
            try w.writeAll(": ");
            try p.rewrite(w, reason);
        }
        return try buf.toOwnedSlice();
    }
};

const testing = std.testing;

fn testMap() !SourceMap {
    var m: SourceMap = .init(testing.allocator);
    try m.insert("/nix/store/aaaa-source", "/home/u/repo");
    try m.insert("/nix/store/bbbb-source", "/home/u/nixpkgs");
    try m.insert("/nix/store/aaaa-source-extra", "/home/u/other");
    try m.sort();
    return m;
}

fn expectLocate(m: *const SourceMap, path: []const u8, want: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try m.locate(arena.allocator(), path);
    if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
}

fn expectRewrite(m: *const SourceMap, text: []const u8, want: []const u8) !void {
    const got = try m.rewriteAlloc(testing.allocator, text);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "locate takes the longest prefix" {
    var m = try testMap();
    defer m.deinit();
    try expectLocate(&m, "/nix/store/aaaa-source/default.nix", "/home/u/repo/default.nix");
    try expectLocate(&m, "/nix/store/aaaa-source-extra/x", "/home/u/other/x");
    try expectLocate(&m, "/nix/store/aaaa-source", "/home/u/repo");
}

test "locate without a match is none" {
    var m = try testMap();
    defer m.deinit();
    try expectLocate(&m, "/nix/store/cccc-source/x", null);
    try expectLocate(&m, "/home/u/repo/default.nix", null);
    var e: SourceMap = .init(testing.allocator);
    defer e.deinit();
    try expectLocate(&e, "/nix/store/aaaa-source", null);
}

test "a tree copied from a store tree resolves to the local one" {
    // `./.` inside a flake that is already in the store copies the store
    // tree again; the log line names the second copy.
    var m: SourceMap = .init(testing.allocator);
    defer m.deinit();
    try m.insert("/nix/store/aaaa-source", "/home/u/repo");
    try m.insert("/nix/store/bbbb-aaaa-source", "/nix/store/aaaa-source");
    try m.sort();
    try expectLocate(&m, "/nix/store/bbbb-aaaa-source/flake.nix", "/home/u/repo/flake.nix");
    try expectRewrite(&m, "tree is /nix/store/bbbb-aaaa-source", "tree is /home/u/repo");
}

test "a path followed by a colour escape still matches" {
    var m = try testMap();
    defer m.deinit();
    try expectRewrite(&m, "at \x1b[35;1m/nix/store/aaaa-source/x.nix\x1b[0m!", "at \x1b[35;1m/home/u/repo/x.nix\x1b[0m!");
}

test "rewrite replaces every known path in a line" {
    var m = try testMap();
    defer m.deinit();
    try expectRewrite(&m, "cc: /nix/store/aaaa-source/src/a.c and '/nix/store/bbbb-source/x.h', not /nix/store/cccc-out/lib", "cc: /home/u/repo/src/a.c and '/home/u/nixpkgs/x.h', not /nix/store/cccc-out/lib");
}

test "rewrite leaves unknown text alone" {
    var m = try testMap();
    defer m.deinit();
    for ([_][]const u8{ "no store path here", "/nix/store", "/nix/store/", "/nix/storeaaaa-source" }) |l| try expectRewrite(&m, l, l);
    var e: SourceMap = .init(testing.allocator);
    defer e.deinit();
    try expectRewrite(&e, "/nix/store/aaaa-source/a", "/nix/store/aaaa-source/a");
}

fn testProvenance(attr: []const u8, path: []const u8, pos: []const u8, shared: bool) !Provenance {
    var p: Provenance = .{ .map = try testMap(), .on = true };
    try p.sites.put(testing.allocator, path, .{ .attr = attr, .pos = pos, .shared = shared });
    return p;
}

test "failed line names the attribute and the position" {
    var p = try testProvenance("packages.x86_64-linux.hello", "/nix/store/dddd-x.drv", "/home/u/repo/default.nix:3:5", false);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "error: build of packages.x86_64-linux.hello failed (dddd-x.drv), defined at /home/u/repo/default.nix:3:5: builder failed",
        (try p.failed(a, "/nix/store/dddd-x.drv", "builder failed")).?,
    );
    try testing.expectEqualStrings("building packages.x86_64-linux.hello (/home/u/repo/default.nix:3:5)", (try p.started(a, "/nix/store/dddd-x.drv")).?);
    try testing.expect(try p.failed(a, "/nix/store/eeee-y.drv", "x") == null);
    var o: Provenance = .off(testing.allocator);
    defer o.deinit();
    try testing.expect(try o.failed(a, "/nix/store/dddd-x.drv", "x") == null);
}

test "an input file is labelled by its lock node" {
    var m = try testMap();
    defer m.deinit();
    try m.insertInput("/nix/store/cccc-source", "nixpkgs");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("nixpkgs/pkgs/a.nix", (try m.label(arena.allocator(), "/nix/store/cccc-source/pkgs/a.nix")).?);
    try testing.expect(try m.label(arena.allocator(), "/nix/store/cccc-source-x/a.nix") == null);
    try expectRewrite(&m, "/nix/store/cccc-source/a.nix", "/nix/store/cccc-source/a.nix");
}

test "a shared position is left off the started line only" {
    var p = try testProvenance("unit-x.service", "/nix/store/dddd-unit-x.service.drv", "nixpkgs/pkgs/stdenv/generic/make-derivation.nix:651:11", true);
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("building unit-x.service", (try p.started(a, "/nix/store/dddd-unit-x.service.drv")).?);
    try testing.expect(std.mem.endsWith(u8, (try p.failed(a, "/nix/store/dddd-unit-x.service.drv", "")).?, "defined at nixpkgs/pkgs/stdenv/generic/make-derivation.nix:651:11"));
}

test "drv names drop the hash and the extension" {
    try testing.expectEqualStrings("hello-2.12", drvName("/nix/store/0123456789abcdfghijklmnpqrsvwxyz-hello-2.12.drv"));
    try testing.expectEqualStrings("x", drvName("x.drv"));
}
