//! The tracing cache of a command that takes `EvalArgs`: its key, and the
//! drv and source tables a `build` entry carries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("../session.zig").Session;
const Evaluator = @import("../eval/Evaluator.zig");
const api = @import("../api.zig");
const EvalArgs = api.EvalArgs;
const trace = @import("../trace.zig");
pub const Cache = trace.run.Cache;
const Key = trace.key.Key;
const wire = trace.wire;
const cachefs = @import("../cachefs.zig");
const lint = @import("../lint.zig");
const project = @import("../project.zig");
const plan = @import("../remote/plan.zig");
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const source = @import("../store/source.zig");
const store_hooks = @import("../builtins/store_hooks.zig");
const treestore = @import("../treestore.zig");
const provenance = @import("../provenance.zig");
const Diag = @import("../diag.zig").Diag;

/// The tracing cache of `subcommand` for `a`, keyed on its arguments and on
/// `more`, the installables after the first; null when the cache is off or
/// the command cannot be keyed. In `arena`, which outlives the run.
pub fn open(s: *Session, init: *const std.process.Init, a: *const EvalArgs, subcommand: []const u8, more: []const []const u8) !?*Cache {
    return openFor(s, init, a, subcommand, more, null);
}

/// `open` for a run classic mode configures from nix.conf: its `pure-eval`,
/// search path and `system` are the evaluator's.
pub fn openFor(s: *Session, init: *const std.process.Init, a: *const EvalArgs, subcommand: []const u8, more: []const []const u8, classic: ?*const api.run.Classic) !?*Cache {
    if (a.no_tracing_cache or a.dump_drvs != null or !s.settings.cache) return null;
    const arena = init.arena.allocator();
    const root = try cachefs.root(arena, init.environ_map, a.cache_dir orelse s.settings.cache_dir) orelse return null;
    var k = (try key(s, init, a, subcommand, more, classic)) orelse return null;
    const c = try arena.create(Cache);
    var stderr: @import("../sys/fs.zig").FdWriter = .{ .fd = 2 };
    c.* = (try Cache.open(s.gpa, init.io, root, &k, a.timings, &s.log, &stderr.interface)) orelse return null;
    return c;
}

/// The input store a hit validates against and plans from, in `arena`;
/// the caller `deinit`s it.
pub fn inputStore(arena: Allocator, s: *Session, env_map: *const std.process.Environ.Map, cache_dir: ?[]const u8) !*treestore.Store {
    const root = try cachefs.root(arena, env_map, cache_dir orelse s.settings.cache_dir);
    const st = try arena.create(treestore.Store);
    st.* = .init(s.gpa, s.io, if (root) |r| try treestore.locate(arena, r) else null);
    return st;
}

/// Whether the cache holds a valid entry: the entry validated against `inputs`, its
/// `nixConfig` note replayed.
pub fn hit(s: *Session, tc: *Cache, inputs: *treestore.Store) bool {
    tc.inputs = .{ .ctx = inputs, .has = struct {
        fn has(ctx: *anyopaque, n: []const u8, version: u8) bool {
            const st: *treestore.Store = @ptrCast(@alignCast(ctx));
            return st.has(n, version);
        }
    }.has };
    if (!(tc.lookup() catch return false)) return false;
    if (tc.replayedNixConfig()) s.ignored.nixConfigSeen();
    return true;
}

/// Everything about the command that can change its result. Null for an
/// input this port cannot name (a flake).
fn key(s: *Session, init: *const std.process.Init, a: *const EvalArgs, subcommand: []const u8, more: []const []const u8, classic: ?*const api.run.Classic) !?Key {
    const arena = init.arena.allocator();
    const cwd = try std.process.currentPathAlloc(init.io, arena);
    const pure = if (classic) |c| c.pure else a.pure orelse s.settings.pure;
    var k: Key = .init(subcommand);
    if (pure) {
        k.field("pure-eval", "1");
        // the root the evaluator enforces (`api/run.zig`)
        if (try api.projectRoot(arena, init.io, a, cwd)) |r| k.field("project-root", r) else k.field("no-project-root", "");
    }
    if (a.reference_lock_file) |p| k.field("reference-lock-file", try api.absPath(arena, cwd, p));
    const flake_input = if (a.input) |i| i == .flake else false;
    var needs_cwd = false;
    switch (a.input orelse return null) {
        .expr => |e| {
            k.field("expr", e);
            needs_cwd = needs_cwd or trace.key.hasRelativePath(s.gpa, e);
        },
        // The file is named by path, never by content: the read set holds it.
        .file => |f| k.field("file", try api.absPath(arena, cwd, f)),
        // named by its reference and its directory: the read set holds its
        // files
        .flake => |f| {
            var d: Diag = .init(arena);
            const fr = api.flake.flakeRef(arena, init.io, f, cwd, &d) catch return null;
            k.field("flake", f);
            k.field("flake-dir", fr.dir);
            needs_cwd = true;
        },
    }
    for (more) |m| {
        if (flake_input) {
            var d: Diag = .init(arena);
            const fr = api.flake.flakeRef(arena, init.io, m, cwd, &d) catch return null;
            k.field("flake", m);
            k.field("flake-dir", fr.dir);
        } else k.field("more-attr", m);
    }
    for (a.args) |x| {
        if (x.is_str) {
            k.field("argstr", x.name);
        } else {
            k.field("arg", x.name);
            needs_cwd = needs_cwd or trace.key.hasRelativePath(s.gpa, x.text);
        }
        k.field("val", x.text);
    }
    // the search path the evaluator gets (`api/run.zig`)
    if (classic) |c| {
        for (c.search_path) |e| {
            k.field("include-prefix", e.prefix);
            k.field("include-path", e.path);
        }
    } else for (a.includes) |inc| {
        const e = try api.searchEntry(arena, cwd, inc);
        k.field("include-prefix", e.prefix);
        k.field("include-path", e.path);
    }
    if (!pure and classic == null) if (init.environ_map.get("NIX_PATH")) |np| {
        var it = std.mem.tokenizeScalar(u8, np, ':');
        while (it.next()) |x| {
            const e = try api.searchEntry(arena, cwd, x);
            k.field("include-prefix", e.prefix);
            k.field("include-path", e.path);
        }
    };
    if (a.attrs.len == 0) {
        k.field("attr", a.attr orelse "");
    } else for (a.attrs) |x| k.field("attr", x);
    k.flag("strict", a.strict);
    k.flag("json", a.json);
    k.flag("raw", a.raw);
    k.field("lints", (try lintKey(arena, init, a, cwd)) orelse return null);
    for (a.xp_features) |f| k.field("xp", f);
    k.field("system", if (classic) |c| c.system else "x86_64-linux");
    if (!s.readsBuiltOutputs()) k.field("built-outputs", "0");
    if (needs_cwd) k.field("cwd", cwd);
    return k;
}

/// The key of the lint configuration the run resolves; its notes are the
/// run's to print, so they are dropped here.
fn lintKey(arena: Allocator, init: *const std.process.Init, a: *const EvalArgs, cwd: []const u8) !?[]const u8 {
    const start = try api.entryDir(arena, init.io, a, cwd);
    const roots = try arena.alloc([]const u8, a.lint_roots.len);
    for (a.lint_roots, roots) |x, *o| o.* = try api.absPath(arena, cwd, x);
    var notes: lint.Notes = .{};
    var dg: Diag = .init(arena);
    const cfg = lint.Config.resolve(arena, init.io, .fromMap(init.environ_map), start, a.lints, roots, a.lint_scope, &notes, &dg) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BadConfig => return null,
    };
    return try cfg.key(arena);
}

/// The drv and source tables of the evaluation `ev` made, for a `build`
/// entry: every derivation with its ATerm, and every source it added.
pub fn tables(gpa: Allocator, ev: *Evaluator) !struct { drvs: []u8, sources: []u8 } {
    const drvs = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        break :blk try wire.encodeDrvs(gpa, &ev.shared.drv.table);
    };
    errdefer gpa.free(drvs);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(wire.Source) = .empty;
    {
        ev.shared.hooks_lock.lockUncancelable(ev.io);
        defer ev.shared.hooks_lock.unlock(ev.io);
        var it = ev.shared.hooks.known.iterator();
        while (it.next()) |kv| {
            const p = StorePath.ofBaseName(kv.key_ptr.*) orelse continue;
            const o = kv.value_ptr.*;
            const origin: source.SourceOrigin = switch (o.src) {
                .mem => |bytes| .text(bytes, o.refs),
                .fs => |f| .{ .at = .fs(f.root, f.accepted), .kind = .source, .nar = o.nar },
                // a copy of a member names the entry it is in and the member
                .tree => |x| .{ .at = .spool(if (x.t.name.len > 0) x.t.name else kv.key_ptr.*, x.t, x.accepted, o.rel), .kind = .source, .nar = o.nar orelse .{ .hash = x.t.nar_hash, .size = x.t.nar_size } },
            };
            try list.append(a, .{ .path = p, .origin = origin });
        }
    }
    return .{ .drvs = drvs, .sources = try wire.encodeSources(gpa, list.items) };
}

/// The tables of a `build` entry read back, as the plan reads them: the
/// derivations by path and the origin of every source. Everything is in
/// `arena`.
pub const Tables = struct {
    drvs: plan.PathMap(plan.DrvInfo) = .empty,
    attrs: plan.PathMap([]const u8) = .empty,
    sources: plan.PathMap(source.SourceOrigin) = .empty,
    source_count: usize = 0,

    /// Null when a part does not decode, or names an input-store entry the
    /// store no longer holds: the caller discards the entry.
    pub fn decode(arena: Allocator, drvs_b: []const u8, sources_b: []const u8, store: ?*treestore.Store) !?Tables {
        var t: Tables = .{};
        const drvs = (try wire.decodeDrvs(arena, drvs_b)) orelse return null;
        for (drvs) |x| {
            const refs = try arena.alloc(StorePath, x.references.len);
            var d: Diag = .init(arena);
            for (x.references, refs) |r, *o| o.* = StorePath.fromBaseName(r, &d) catch return null;
            try t.drvs.put(arena, x.path, .{ .aterm = x.aterm, .references = path_mod.sortUnique(refs) });
            if (x.attr) |at| try t.attrs.put(arena, x.path, at);
        }
        const Open = struct {
            fn open(ctx: *anyopaque, name: []const u8) ?*const treestore.StoredTree {
                const st: *treestore.Store = @ptrCast(@alignCast(ctx));
                return st.get(name);
            }
        };
        const opener: ?wire.OpenTree = if (store) |st| .{ .ctx = st, .open = Open.open } else null;
        const sources = (try wire.decodeSources(arena, sources_b, opener)) orelse return null;
        for (sources) |x| try t.sources.put(arena, x.path, x.origin);
        t.source_count = sources.len;
        return t;
    }

    pub fn inputs(t: *Tables) plan.Inputs {
        return .{ .ctx = t, .drv = drvFn, .source = sourceFn };
    }

    fn drvFn(ctx: ?*anyopaque, p: *const StorePath) ?plan.DrvInfo {
        const t: *Tables = @ptrCast(@alignCast(ctx.?));
        return t.drvs.get(p.*);
    }

    fn sourceFn(ctx: ?*anyopaque, p: *const StorePath) ?source.SourceOrigin {
        const t: *Tables = @ptrCast(@alignCast(ctx.?));
        return t.sources.get(p.*);
    }

    /// The trees on disk the sources were copied from, for the messages of
    /// a build that evaluated nothing.
    pub fn sourceMap(t: *const Tables, gpa: Allocator, arena: Allocator, extra: []const @import("../settings.zig").Pair) !provenance.SourceMap {
        var m: provenance.SourceMap = .init(gpa);
        errdefer m.deinit();
        var it = t.sources.iterator();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        while (it.next()) |kv| if (try kv.value_ptr.at.local(arena)) |local| {
            const prefix = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path_mod.store_dir, kv.key_ptr.baseName() }) catch continue;
            try m.insert(prefix, local);
        };
        for (extra) |p| try m.insert(p.name, p.value);
        try m.sort();
        return m;
    }
};

/// Writes the entry of a successful run: `result`, the read set, the lint
/// warnings as records a hit replays, and with `with_tables` the drv and
/// source tables a `build` hit plans from.
pub fn writeEntry(c: *Cache, s: *Session, ev: *Evaluator, result: []const u8, with_tables: bool) !void {
    // the log's own allocator owns what `lint` returns
    const lg = s.log.gpa;
    var records: std.ArrayList([]const u8) = .empty;
    defer {
        for (records.items) |r| lg.free(r);
        records.deinit(lg);
    }
    const sites = lint.report.sites(ev);
    for (lint.report.records(ev), 0..) |text, i| {
        const l = try s.log.lint(text, if (i < sites.len) sites[i] else null);
        lg.free(l.shown);
        try records.append(lg, l.record);
    }
    var run: Cache.Run = .{ .trace = ev.trace(), .warnings = records.items, .nix_config_seen = s.ignored.nixConfigWasSeen() };
    var t: ?@TypeOf(try tables(s.gpa, ev)) = null;
    defer if (t) |x| {
        s.gpa.free(x.drvs);
        s.gpa.free(x.sources);
    };
    if (with_tables and ev.trace().isCacheable()) {
        t = try tables(s.gpa, ev);
        run.drvs = t.?.drvs;
        run.sources = t.?.sources;
    }
    try c.write(run, result);
}

/// `writeEntry` for a `build`: the roots are the result.
pub fn writeBuild(c: *Cache, s: *Session, ev: *Evaluator, roots: []const @import("installable.zig").DrvRoot) !void {
    const w = try s.gpa.alloc(wire.Root, roots.len);
    defer s.gpa.free(w);
    for (roots, w) |r, *o| o.* = .{ .drv = r.drv, .output = r.output };
    const bytes = try wire.encodeRoots(s.gpa, w);
    defer s.gpa.free(bytes);
    try writeEntry(c, s, ev, bytes, true);
}
