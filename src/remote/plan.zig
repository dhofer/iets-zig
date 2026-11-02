//! The upload plan: the closure of the root derivations, and the sources the
//! daemon lacks hashed the way Nix addresses them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const remote = @import("../remote.zig");
const Error = remote.Error;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const nar = @import("../store/nar.zig");
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const drv_mod = @import("../store/drv.zig");
const source = @import("../store/source.zig");
const SrcPath = source.SrcPath;
const SourceKind = source.SourceKind;
const SourceOrigin = source.SourceOrigin;

/// Hashes and compares store paths by base name, for maps keyed on them.
pub const PathContext = struct {
    pub fn hash(_: PathContext, p: StorePath) u64 {
        return std.hash.Wyhash.hash(0, p.baseName());
    }
    pub fn eql(_: PathContext, a: StorePath, b: StorePath) bool {
        return a.eql(&b);
    }
};

pub fn PathMap(comptime V: type) type {
    return std.HashMapUnmanaged(StorePath, V, PathContext, std.hash_map.default_max_load_percentage);
}

pub const PathSet = PathMap(void);

/// Store path base names, what a store answers a validity query with.
pub const NameSet = std.StringHashMapUnmanaged(void);

/// What registering a `.drv` needs beyond its bytes: the flat sha256 of the
/// ATerm, which is its `text:sha256:` content address, and the hash and size
/// of its NAR.
pub const DrvHashes = struct {
    text: Hash,
    nar_hash: Hash,
    nar_size: u64,

    pub fn of(aterm: []const u8) DrvHashes {
        var h: hash_mod.Hasher = .init(.sha256);
        var buf: [4096]u8 = undefined;
        var hw = h.writer(&buf);
        nar.dumpString(aterm, &hw.interface) catch unreachable;
        hw.interface.flush() catch unreachable;
        return .{
            .text = hash_mod.hashBytes(.sha256, aterm),
            .nar_size = h.count,
            .nar_hash = h.finish(),
        };
    }
};

/// One object the daemon must hold before it can build the root.
pub const Object = union(enum) {
    /// A source tree plus the NAR hash Nix addresses it by.
    source: Source,
    /// A derivation: its ATerm. `references` is inputSrcs plus inputDrvs,
    /// sorted, what the worker protocol needs to register the `.drv` as a
    /// text path. `hashes` is filled by `prehashDrvs` before the upload
    /// starts, so the connection only writes bytes.
    drv: Drv,

    pub const Source = struct {
        path: StorePath,
        at: SrcPath,
        kind: SourceKind,
        nar_hash: Hash,
        nar_size: u64,
    };

    pub const Drv = struct {
        path: StorePath,
        aterm: []const u8,
        references: []const StorePath,
        hashes: ?DrvHashes = null,

        pub fn getHashes(d: *const Drv) DrvHashes {
            return d.hashes orelse DrvHashes.of(d.aterm);
        }
    };

    /// A source object, hashing the tree only when evaluation did not
    /// already report the hash under the same filter.
    pub fn fromOrigin(gpa: Allocator, io: Io, path: StorePath, o: SourceOrigin, d: *Diag) !Object {
        const h = o.nar orelse try hashSource(gpa, io, o.at, d);
        return .{ .source = .{ .path = path, .at = o.at, .kind = o.kind, .nar_hash = h.hash, .nar_size = h.size } };
    }

    pub fn drvObject(path: StorePath, aterm: []const u8, references: []const StorePath) Object {
        return .{ .drv = .{ .path = path, .aterm = aterm, .references = references } };
    }

    pub fn storePath(o: *const Object) *const StorePath {
        return switch (o.*) {
            .source => |*s| &s.path,
            .drv => |*v| &v.path,
        };
    }
};

fn cpus() usize {
    return std.Thread.getCpuCount() catch 4;
}

/// Hashes the ATerm of every `.drv` in `objects` on a thread pool. Without
/// this each ATerm is hashed twice inside the framed upload, one drv at a
/// time, with the daemon waiting.
pub fn prehashDrvs(gpa: Allocator, objects: []const *Object) void {
    var todo: std.ArrayList(*Object.Drv) = .empty;
    defer todo.deinit(gpa);
    for (objects) |o| switch (o.*) {
        .drv => |*v| if (v.hashes == null) todo.append(gpa, v) catch {
            v.hashes = DrvHashes.of(v.aterm);
        },
        .source => {},
    };
    if (todo.items.len < 2) {
        for (todo.items) |v| v.hashes = DrvHashes.of(v.aterm);
        return;
    }
    const Ctx = struct {
        todo: []const *Object.Drv,
        next: std.atomic.Value(usize) = .init(0),
        fn run(c: *@This()) void {
            while (true) {
                const i = c.next.fetchAdd(1, .monotonic);
                if (i >= c.todo.len) return;
                c.todo[i].hashes = DrvHashes.of(c.todo[i].aterm);
            }
        }
    };
    var ctx: Ctx = .{ .todo = todo.items };
    runThreads(gpa, @min(cpus(), todo.items.len), &ctx, Ctx.run);
}

/// Runs `f(ctx)` on `n` threads, the caller being one of them, and joins.
/// A thread that cannot start leaves its share to the others.
fn runThreads(gpa: Allocator, n: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx)) void) void {
    const threads = gpa.alloc(?std.Thread, n -| 1) catch return f(ctx);
    defer gpa.free(threads);
    for (threads) |*t| t.* = std.Thread.spawn(.{}, f, .{ctx}) catch null;
    f(ctx);
    for (threads) |t| if (t) |th| th.join();
}

/// The NAR hash and size of a source, one pass over the bytes.
pub fn hashSource(gpa: Allocator, io: Io, at: SrcPath, d: *Diag) !source.NarHash {
    var h: hash_mod.Hasher = .init(.sha256);
    var buf: [1 << 16]u8 = undefined;
    var hw = h.writer(&buf);
    try at.nar(gpa, io, &hw.interface, d);
    return .{ .size = h.count, .hash = h.finish() };
}

/// Levels of the graph `missingTopDown` asks about one call at a time before
/// it asks about the closure of what is left in one call.
const top_down_levels = 2;

pub const NodeSet = std.AutoHashMapUnmanaged(u32, void);

/// The nodes reachable from `roots` through nodes lacking any of their keys.
/// A store holds the closure of every path it holds, so nothing below a held
/// node is asked about; a warm store answers in one or two small calls.
/// `answered`: what the store holds of the roots' keys, if already asked.
///
/// `graph` provides `keys(gpa, n, *std.ArrayList(StorePath), *Diag) !void`
/// (the store paths that must all be valid for `n` to be held),
/// `children(gpa, n, *std.ArrayList(u32)) !void`, and
/// `query([]const StorePath, *NameSet, arena) !void`, which adds the base
/// names the store holds to the set, both allocated in `arena`.
pub fn missingTopDown(gpa: Allocator, roots: []const u32, graph: anytype, answered: ?*const NameSet, d: *Diag) !NodeSet {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // in `arena`, where `query` puts what it adds
    var valid: NameSet = .empty;
    if (answered) |a| {
        var it = a.keyIterator();
        while (it.next()) |k| try valid.put(arena, k.*, {});
    }
    var asked: NodeSet = .empty;
    defer asked.deinit(gpa);
    if (answered != null) for (roots) |r| try asked.put(gpa, r, {});
    var seen: NodeSet = .empty;
    defer seen.deinit(gpa);
    var missing: NodeSet = .empty;
    errdefer missing.deinit(gpa);

    var level: std.ArrayList(u32) = .empty;
    defer level.deinit(gpa);
    try level.appendSlice(gpa, roots);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(gpa);
    var ask: std.ArrayList(u32) = .empty;
    defer ask.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var kids: std.ArrayList(u32) = .empty;
    defer kids.deinit(gpa);
    var keys: std.ArrayList(StorePath) = .empty;
    defer keys.deinit(gpa);

    var depth: usize = 0;
    while (true) : (depth += 1) {
        var kept: usize = 0;
        for (level.items) |n| {
            if ((try seen.fetchPut(gpa, n, {})) != null) continue;
            level.items[kept] = n;
            kept += 1;
        }
        level.items.len = kept;
        if (level.items.len == 0) break;

        ask.clearRetainingCapacity();
        for (level.items) |n| if ((try asked.fetchPut(gpa, n, {})) == null) try ask.append(gpa, n);
        if (depth >= top_down_levels) {
            stack.clearRetainingCapacity();
            try stack.appendSlice(gpa, level.items);
            while (stack.pop()) |n| {
                kids.clearRetainingCapacity();
                try graph.children(gpa, n, &kids);
                for (kids.items) |c| if ((try asked.fetchPut(gpa, c, {})) == null) {
                    try ask.append(gpa, c);
                    try stack.append(gpa, c);
                };
            }
        }
        if (ask.items.len > 0) {
            keys.clearRetainingCapacity();
            for (ask.items) |n| try graph.keys(gpa, n, &keys, d);
            try graph.query(keys.items, &valid, arena);
        }
        next.clearRetainingCapacity();
        for (level.items) |n| {
            keys.clearRetainingCapacity();
            try graph.keys(gpa, n, &keys, d);
            const lacking = for (keys.items) |*k| {
                if (!valid.contains(k.baseName())) break true;
            } else false;
            if (lacking) {
                try missing.put(gpa, n, {});
                try graph.children(gpa, n, &next);
            }
        }
        std.mem.swap(std.ArrayList(u32), &level, &next);
    }
    return missing;
}

/// A store asked which paths it holds: `query(ctx, paths, valid, arena)` adds
/// the base names it holds to `valid`, the names and the set's growth both
/// allocated in `arena`.
pub const Query = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, paths: []const StorePath, valid: *NameSet, arena: Allocator) anyerror!void,

    pub fn call(q: Query, paths: []const StorePath, valid: *NameSet, arena: Allocator) anyerror!void {
        return q.f(q.ctx, paths, valid, arena);
    }
};

/// The closure of the roots: what the daemon must hold before it can build
/// them. Sources are only named here; `resolve` locates and hashes the ones
/// the daemon lacks. Everything lives in `arena`.
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    /// Input sources in registration order: a `toFile` text after the
    /// sources it references.
    sources: []StorePath = &.{},
    /// The eval-time origin of every source in `sources` that this
    /// evaluation added.
    origins: PathMap(SourceOrigin) = .empty,
    /// Derivations in post-order: each after its input drvs.
    drvs: []Object = &.{},
    /// Input drvs that were not created by this evaluation and were read
    /// from `/nix/store`.
    store_drvs: usize = 0,

    pub fn init(gpa: Allocator) Plan {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(p: *Plan) void {
        p.arena.deinit();
    }

    /// The store path of node `i` of `queryMissing`: the sources, then the drvs.
    pub fn node(p: *const Plan, i: u32) *const StorePath {
        if (i < p.sources.len) return &p.sources[i];
        return p.drvs[i - p.sources.len].storePath();
    }

    /// The plan's paths in the closure of `roots` that the store lacks
    /// (`missingTopDown`), as nodes (see `node`). A valid drv answers for
    /// all it references.
    pub fn queryMissing(p: *const Plan, gpa: Allocator, roots: []const StorePath, answered: ?*const NameSet, q: Query, d: *Diag) !NodeSet {
        var index: PathMap(u32) = .empty;
        defer index.deinit(gpa);
        const n_src: u32 = @intCast(p.sources.len);
        for (p.sources, 0..) |s, i| try index.put(gpa, s, @intCast(i));
        for (p.drvs, 0..) |*o, i| try index.put(gpa, o.storePath().*, n_src + @as(u32, @intCast(i)));
        var root_nodes: std.ArrayList(u32) = .empty;
        defer root_nodes.deinit(gpa);
        for (roots) |r| if (index.get(r)) |i| try root_nodes.append(gpa, i);
        const G = struct {
            p: *const Plan,
            index: *const PathMap(u32),
            q: Query,
            pub fn keys(g: @This(), a: Allocator, n: u32, out: *std.ArrayList(StorePath), _: *Diag) !void {
                try out.append(a, g.p.node(n).*);
            }
            pub fn children(g: @This(), a: Allocator, n: u32, out: *std.ArrayList(u32)) !void {
                if (n < g.p.sources.len) return;
                switch (g.p.drvs[n - g.p.sources.len]) {
                    .drv => |v| for (v.references) |r| if (g.index.get(r)) |i| try out.append(a, i),
                    .source => {},
                }
            }
            pub fn query(g: @This(), paths: []const StorePath, valid: *NameSet, arena: Allocator) !void {
                try g.q.call(paths, valid, arena);
            }
        };
        const g: G = .{ .p = p, .index = &index, .q = q };
        return missingTopDown(gpa, root_nodes.items, g, answered, d);
    }

    /// Locates and hashes `missing`, a subset of `sources` in plan order:
    /// eval-time origins first, the rest through `locate` in one batch,
    /// hashed on a thread pool. The result lives in `p`'s arena.
    pub fn resolve(p: *Plan, gpa: Allocator, io: Io, missing: []const StorePath, locate: Locator, d: *Diag) !Resolved {
        const arena = p.arena.allocator();
        const infos = try gpa.alloc(?SourceOrigin, missing.len);
        defer gpa.free(infos);
        var unknown: std.ArrayList(StorePath) = .empty;
        defer unknown.deinit(gpa);
        for (missing, infos) |m, *slot| {
            slot.* = p.origins.get(m);
            if (slot.* == null) try unknown.append(gpa, m);
        }
        var substitute: std.ArrayList(StorePath) = .empty;
        if (unknown.items.len > 0) {
            const found = try gpa.alloc(?SourceOrigin, unknown.items.len);
            defer gpa.free(found);
            @memset(found, null);
            try locate.call(unknown.items, found, arena, d);
            var j: usize = 0;
            for (missing, infos) |m, *slot| {
                if (slot.* != null) continue;
                if (found[j]) |info| slot.* = info else try substitute.append(arena, m);
                j += 1;
            }
        }
        var paths: std.ArrayList(StorePath) = .empty;
        defer paths.deinit(gpa);
        var origins: std.ArrayList(SourceOrigin) = .empty;
        defer origins.deinit(gpa);
        for (missing, infos) |m, i| if (i) |info| {
            try paths.append(gpa, m);
            try origins.append(gpa, info);
        };
        return .{
            .objects = try hashSources(gpa, arena, io, paths.items, origins.items, d),
            .substitute = substitute.items,
            .store_sources = unknown.items.len - substitute.items.len,
        };
    }
};

/// The missing sources after `Plan.resolve`: what the client uploads and
/// what it leaves to the daemon.
pub const Resolved = struct {
    /// Hashed sources, in the order they were asked for.
    objects: []Object,
    /// Sources the client cannot produce: not in the local store, or not
    /// content-addressed the way v1 sends (an input-addressed build output
    /// pinned with `builtins.storePath`). The daemon substitutes them.
    substitute: []const StorePath,
    /// Sources with no eval-time origin, read from the local store and hashed.
    store_sources: usize,
};

/// Maps input source store paths that eval did not record, in one batch, to
/// where to read them and how they were addressed; null when the local side
/// cannot produce the path and the daemon must substitute it. `iets build`
/// asks the local store. `f` fills `out`, one slot per path, allocating in
/// `arena`.
pub const Locator = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, paths: []const StorePath, out: []?SourceOrigin, arena: Allocator, d: *Diag) anyerror!void,

    pub fn call(l: Locator, paths: []const StorePath, out: []?SourceOrigin, arena: Allocator, d: *Diag) anyerror!void {
        return l.f(l.ctx, paths, out, arena, d);
    }
};

/// Checks that a planned source still hashes to its store path: the NAR of
/// the original tree must yield the path eval computed, or the daemon
/// rejects it. Only sources the plan hashed itself need this. A tree whose
/// hash comes from evaluation cannot fail it by construction; if such a tree
/// changed on disk after evaluation, the daemon catches it, because
/// `AddMultipleToStore` recomputes the NAR hash of a `fixed:r` path and
/// rejects a mismatch, and `writeObject` refuses to send a NAR whose length
/// is not the recorded `nar_size`.
fn checkSourcePath(path: *const StorePath, kind: SourceKind, nar_hash: Hash, d: *Diag) !void {
    if (kind != .source) return;
    const expected = path_mod.makeFixedOutputPath(.recursive, nar_hash, path.name(), &.{}, d) catch
        return error.Store;
    if (!expected.eql(path))
        return d.fail(error.Plan, "source '{f}' changed since evaluation (now {f})", .{ path, &expected });
}

/// Dumps and hashes every source on a thread pool; results keep the input
/// order and live in `arena`.
fn hashSources(gpa: Allocator, arena: Allocator, io: Io, paths: []const StorePath, infos: []const SourceOrigin, d: *Diag) ![]Object {
    const out = try arena.alloc(Object, paths.len);
    if (paths.len == 0) return out;
    const Slot = struct { err: ?anyerror = null, diag: Diag };
    const slots = try gpa.alloc(Slot, paths.len);
    defer {
        for (slots) |*s| s.diag.deinit();
        gpa.free(slots);
    }
    for (slots) |*s| s.* = .{ .diag = .init(gpa) };
    const Ctx = struct {
        gpa: Allocator,
        io: Io,
        paths: []const StorePath,
        infos: []const SourceOrigin,
        out: []Object,
        slots: []Slot,
        next: std.atomic.Value(usize) = .init(0),
        fn run(c: *@This()) void {
            while (true) {
                const i = c.next.fetchAdd(1, .monotonic);
                if (i >= c.paths.len) return;
                c.one(i) catch |e| {
                    c.slots[i].err = e;
                };
            }
        }
        fn one(c: *@This(), i: usize) !void {
            const p = &c.paths[i];
            const info = c.infos[i];
            const sd = &c.slots[i].diag;
            const o = Object.fromOrigin(c.gpa, c.io, p.*, info, sd) catch |e| {
                if (sd.msg == null) return remote.failIo(sd, e, "cannot dump '{f}'", .{p});
                remote.prefix(sd, "cannot dump '{f}'", .{p});
                return error.Io;
            };
            if (info.nar == null) try checkSourcePath(p, o.source.kind, o.source.nar_hash, sd);
            c.out[i] = o;
        }
    };
    var ctx: Ctx = .{ .gpa = gpa, .io = io, .paths = paths, .infos = infos, .out = out, .slots = slots };
    runThreads(gpa, @min(cpus(), paths.len), &ctx, Ctx.run);
    for (slots) |*s| if (s.err) |e| {
        if (s.diag.msg) |m| return d.fail(e, "{s}", .{m});
        return e;
    };
    return out;
}

/// What evaluation recorded of a derivation: its ATerm, if it holds it, and
/// what it references (inputSrcs plus inputDrvs, sorted).
pub const DrvInfo = struct {
    aterm: ?[]const u8,
    references: []const StorePath,
};

/// What the evaluation knows: the drv table and the origin of every added
/// source. Both may answer nothing, in which case everything is read from
/// `/nix/store`. The evaluator's tables plug in through this interface (`api/build.zig:EvalInputs`, a hit's
/// `api/cache.zig:Tables`).
pub const Inputs = struct {
    ctx: ?*anyopaque = null,
    drv: ?*const fn (ctx: ?*anyopaque, p: *const StorePath) ?DrvInfo = null,
    source: ?*const fn (ctx: ?*anyopaque, p: *const StorePath) ?SourceOrigin = null,

    pub fn getDrv(i: Inputs, p: *const StorePath) ?DrvInfo {
        const f = i.drv orelse return null;
        return f(i.ctx, p);
    }

    pub fn getSource(i: Inputs, p: *const StorePath) ?SourceOrigin {
        const f = i.source orelse return null;
        return f(i.ctx, p);
    }
};

/// One derivation of a walk: its ATerm and what it references.
pub const Node = struct {
    path: StorePath,
    aterm: []const u8,
    references: []const StorePath,
};

pub const Loaded = struct {
    aterm: []const u8,
    references: []const StorePath,
    /// Read from `/nix/store`, not this evaluation's.
    stored: bool,
};

/// A drv's ATerm and references: this evaluation's, else `/nix/store`'s,
/// read and parsed into `arena`.
pub fn loadDrv(arena: Allocator, io: Io, p: *const StorePath, inputs: Inputs, d: *Diag) !Loaded {
    if (inputs.getDrv(p)) |info| if (info.aterm) |aterm|
        return .{ .aterm = aterm, .references = info.references, .stored = false };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = p.print(&buf);
    const text = Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch |e|
        return remote.failIo(d, e, "cannot read derivation '{s}'", .{full});
    const name = drv_mod.Derivation.nameFromPath(p, d) catch return error.Store;
    const drv = drv_mod.Derivation.parse(arena, text, name, d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Store,
    };
    const refs = try arena.alloc(StorePath, drv.input_srcs.len + drv.input_drvs.len);
    for (drv.input_srcs, 0..) |s, i| refs[i] = s;
    for (drv.input_drvs, 0..) |in, i| refs[drv.input_srcs.len + i] = in.path;
    return .{ .aterm = text, .references = path_mod.sortUnique(refs), .stored = true };
}

pub const Walk = struct {
    drvs: []Node,
    sources: []StorePath,
    from_store: usize,
};

/// The drvs `roots` need, each after every drv it references, and the
/// sources they name, each after the sources its `toFile` text references:
/// the daemon registers a path only once its references are valid, and a
/// text can point at a copied path no derivation lists. The walk stops at
/// `known`. `from_store` counts the drvs read from `/nix/store`. Everything
/// is allocated in `arena`.
pub fn walk(gpa: Allocator, arena: Allocator, io: Io, roots: []const StorePath, known: *const PathSet, inputs: Inputs, d: *Diag) !Walk {
    var seen: PathSet = .empty;
    defer seen.deinit(gpa);
    var drvs: std.ArrayList(Node) = .empty;
    var srcs: std.ArrayList(StorePath) = .empty;
    var from_store: usize = 0;
    const Pending = struct { path: StorePath, done: ?Loaded };
    var stack: std.ArrayList(Pending) = .empty;
    defer stack.deinit(gpa);
    var i = roots.len;
    while (i > 0) {
        i -= 1;
        try stack.append(gpa, .{ .path = roots[i], .done = null });
    }
    const S = struct {
        fn addSource(g: Allocator, a: Allocator, p: StorePath, k: *const PathSet, in: Inputs, sn: *PathSet, out: *std.ArrayList(StorePath)) Allocator.Error!void {
            if (k.contains(p) or (try sn.fetchPut(g, p, {})) != null) return;
            if (in.getSource(&p)) |o| if (o.textRefs()) |refs| for (refs) |r| {
                if (!r.isDerivation()) try addSource(g, a, r, k, in, sn, out);
            };
            try out.append(a, p);
        }
    };
    while (stack.pop()) |e| {
        if (e.done) |l| {
            try drvs.append(arena, .{ .path = e.path, .aterm = l.aterm, .references = l.references });
            continue;
        }
        if (known.contains(e.path) or (try seen.fetchPut(gpa, e.path, {})) != null) continue;
        const l = try loadDrv(arena, io, &e.path, inputs, d);
        if (l.stored) from_store += 1;
        try stack.append(gpa, .{ .path = e.path, .done = l });
        for (l.references) |r| {
            if (r.isDerivation()) {
                if (!known.contains(r) and !seen.contains(r)) try stack.append(gpa, .{ .path = r, .done = null });
            } else try S.addSource(gpa, arena, r, known, inputs, &seen, &srcs);
        }
    }
    return .{ .drvs = drvs.items, .sources = srcs.items, .from_store = from_store };
}

/// Computes the closure of `roots`: input drvs recursively and every input
/// source, without reading or hashing a source. Every drv comes from
/// `inputs`; what is not there is read from `/nix/store` and counted in the
/// plan. Fixed-output drvs are ordinary drvs here; the builder fetches them.
pub fn plan(gpa: Allocator, io: Io, roots: []const StorePath, inputs: Inputs, d: *Diag) !Plan {
    var p: Plan = .init(gpa);
    errdefer p.deinit();
    const arena = p.arena.allocator();
    const none: PathSet = .empty;
    const w = try walk(gpa, arena, io, roots, &none, inputs, d);
    for (w.sources) |s| if (inputs.getSource(&s)) |o| try p.origins.put(arena, s, o);
    const objs = try arena.alloc(Object, w.drvs.len);
    for (w.drvs, objs) |n, *o| o.* = .drvObject(n.path, n.aterm, n.references);
    p.sources = w.sources;
    p.drvs = objs;
    p.store_drvs = w.from_store;
    return p;
}

// Tests

const testing = std.testing;

fn sp(name: []const u8) StorePath {
    var buf: [256]u8 = undefined;
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var hash: [32]u8 = @splat('0');
    const digits = std.fmt.bufPrint(&buf, "{d}", .{name.len}) catch unreachable;
    @memcpy(hash[32 - digits.len ..], digits);
    const s = std.fmt.bufPrint(&buf, "/nix/store/{s}-{s}", .{ &hash, name }) catch unreachable;
    return StorePath.parse(s, &d) catch unreachable;
}

/// root -> a -> b -> src_b, root -> src
fn chain(gpa: Allocator) !Plan {
    var p: Plan = .init(gpa);
    const a_ = p.arena.allocator();
    const src = sp("src");
    const src_b = sp("src-b");
    const b = sp("b.drv");
    const a = sp("a.drv");
    p.sources = try a_.dupe(StorePath, &.{ src_b, src });
    var root_refs = [_]StorePath{ a, src };
    p.drvs = try a_.dupe(Object, &.{
        .drvObject(b, "", try a_.dupe(StorePath, &.{src_b})),
        .drvObject(a, "", try a_.dupe(StorePath, &.{b})),
        .drvObject(sp("root.drv"), "", try a_.dupe(StorePath, path_mod.sortUnique(&root_refs))),
    });
    return p;
}

const Recorder = struct {
    held: []const []const u8,
    calls: std.ArrayList([]const u8) = .empty,
    arena: Allocator,

    fn query(ctx: ?*anyopaque, paths: []const StorePath, valid: *NameSet, arena: Allocator) anyerror!void {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        var names: std.ArrayList([]const u8) = .empty;
        for (paths) |*p| try names.append(r.arena, p.name());
        std.mem.sortUnstable([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        try r.calls.append(r.arena, try std.mem.join(r.arena, " ", names.items));
        for (paths) |*p| for (r.held) |h| if (std.mem.eql(u8, sp(h).baseName(), p.baseName())) {
            try valid.put(arena, try arena.dupe(u8, p.baseName()), {});
        };
    }
};

fn calls(held: []const []const u8, answered: ?*const NameSet, want_calls: []const []const u8, want_missing: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try chain(testing.allocator);
    defer p.deinit();
    var r: Recorder = .{ .held = held, .arena = arena };
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var missing = try p.queryMissing(testing.allocator, &.{sp("root.drv")}, answered, .{ .ctx = &r, .f = Recorder.query }, &d);
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(want_calls.len, r.calls.items.len);
    for (want_calls, r.calls.items) |w, g| try testing.expectEqualStrings(w, g);
    var names: std.ArrayList([]const u8) = .empty;
    var it = missing.keyIterator();
    while (it.next()) |n| try names.append(arena, p.node(n.*).name());
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try testing.expectEqualStrings(want_missing, try std.mem.join(arena, " ", names.items));
}

test "a held root answers for its closure" {
    try calls(&.{"root.drv"}, null, &.{"root.drv"}, "");
}

test "a held input answers for its closure" {
    try calls(&.{ "a.drv", "src" }, null, &.{ "root.drv", "a.drv src" }, "root.drv");
}

test "a cold store is asked the rest in one call" {
    try calls(&.{}, null, &.{ "root.drv", "a.drv src", "b.drv src-b" }, "a.drv b.drv root.drv src src-b");
}

test "an answered root is not asked again" {
    const empty: NameSet = .empty;
    try calls(&.{ "a.drv", "src" }, &empty, &.{"a.drv src"}, "root.drv");
}

test "memory source matches dumpString" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const o: SourceOrigin = .text("hello\n", &.{});
    const h = try hashSource(testing.allocator, testing.io, o.at, &d);
    try testing.expect(h.hash.eql(nar.narHashOfString("hello\n")));
    try testing.expect(h.size > 0);
}

test "hashSource matches narHashFiltered" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "t/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "t/a", .data = "a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "t/sub/b", .data = "bb" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "t", &buf);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const h = try hashSource(testing.allocator, io, .fs(buf[0..n], null), &d);
    const want = try nar.narHashFiltered(testing.allocator, io, tmp.dir, "t", .sha256, nar.keep_all, &d);
    try testing.expect(h.hash.eql(want.hash));
    try testing.expectEqual(want.size, h.size);
}
