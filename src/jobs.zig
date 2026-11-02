//! `iets eval-jobs`: the nix-eval-jobs 2.35 walk over an attribute tree
//! and its JSON lines. The main fiber walks the tree in lexicographic
//! depth-first order and hands every job or error to a sink; helpers run
//! `prefetch` range tasks that force what a job needs (`type`, `name`,
//! `drvPath`, output paths, `meta`) ahead of the walk. See
//! docs/reference/commands.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const Diag = @import("diag.zig").Diag;
const Evaluator = @import("eval/Evaluator.zig");
const Shared = @import("eval/Shared.zig");
const print = @import("eval/print.zig");
const value = @import("runtime/value.zig");
const Value = value.Value;
const Attrs = value.Attrs;
const Attr = value.Attr;
const Pos = @import("syntax/pos.zig").Pos;
const Sym = @import("syntax/symbol.zig").Sym;
const log_mod = @import("log.zig");
const provenance = @import("provenance.zig");
const path_mod = @import("store/path.zig");
const StorePath = path_mod.StorePath;
const drv_mod = @import("store/drv.zig");
const Derivation = drv_mod.Derivation;

pub const line = @import("jobs/line.zig");
pub const constituents = @import("jobs/constituents.zig");
pub const cache = @import("jobs/cache.zig");
pub const emit = @import("jobs/emit.zig");
pub const instantiate = @import("jobs/instantiate.zig");
pub const collector = @import("jobs/collector.zig");

pub const Line = line.Line;
pub const Job = line.Job;
pub const ErrorLine = line.ErrorLine;

/// The errors of the jobs layer: the store's and the worker connection's,
/// plus `Cache` for the cache-status resolver.
pub const Error = error{ Io, Protocol, Usage, Store, Plan, Cache, OutOfMemory, Canceled };

/// What the summary line counts.
pub const Stats = struct {
    jobs: u64 = 0,
    errors: u64 = 0,
};

pub const Opts = struct {
    force_recurse: bool = false,
    meta: bool = false,
    show_input_drvs: bool = false,
    /// `--no-instantiate`: nix-eval-jobs cannot read the `.drv` back, so
    /// `system` comes from the attribute and `requiredSystemFeatures` and
    /// `inputDrvs` are absent.
    no_instantiate: bool = false,
    /// `--constituents`: read `_hydraAggregate` jobs' `constituents`.
    constituents: bool = false,
    /// `--chunks M --chunk N`: only the units whose path hash is N mod M.
    chunks: u32 = 1,
    chunk: u32 = 0,
    /// `--chunk-depth D`: a path of length D is a unit, whatever it holds;
    /// a derivation above that depth is a unit of its own.
    chunk_depth: u32 = 2,
    /// `--provenance`: add a `pos` key, the source position of each job's
    /// derivation. nix-eval-jobs 2.35 has no such key, so this is off by
    /// default and the output stays flag-identical (docs/explanation/provenance.md).
    provenance: bool = false,
};

const Syms = struct {
    type: Sym,
    meta: Sym,
    outputs: Sym,
    recurse: Sym,
    system: Sym,
    hydra_aggregate: Sym,
    constituents: Sym,
    glob_constituents: Sym,
};

pub const Config = struct {
    opts: Opts,
    syms: Syms,
    /// The `--arg`/`--argstr` attrset, auto-called on every function met.
    /// In the value arena, which is never freed.
    auto_args: *Attrs,
    /// The `--apply` function, evaluated once.
    apply: ?Value,
};

/// Where a line goes: called on the walking fiber, it takes the line over.
pub const Sink = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, l: Line) void,

    pub fn send(s: Sink, l: Line) void {
        s.f(s.ctx, l);
    }
};

/// The path hash and depth of a set the walk fanned out.
const SetAt = struct { hash: u64, depth: u32 };

/// The `eval-jobs` walk of one run. The command owns it and hands it to the helpers through
/// `Shared.prefetch`: a thread-local would name whichever run a migrated
/// fiber last ran on. It must outlive the evaluator's workers.
pub const Walk = struct {
    /// Owns every line the walk makes; lines move between threads, so it
    /// must be thread-safe.
    gpa: Allocator,
    io: Io,
    config: Config = undefined,
    /// Path hash and depth of every set the walk fanned out, by address, so
    /// a helper handed a range of its cells can apply the chunk rule.
    sets_lock: Io.Mutex = .init,
    sets: std.AutoHashMapUnmanaged(usize, SetAt) = .empty,

    pub fn init(gpa: Allocator, io: Io) Walk {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(w: *Walk) void {
        w.sets.deinit(w.gpa);
    }

    /// Installs the options for every fiber. `auto_args` is the
    /// `--arg`/`--argstr` set applied to every function met on the way;
    /// `apply` the `--apply` function.
    pub fn configure(w: *Walk, ev: *Evaluator, opts: Opts, auto_args: *Attrs, apply: ?Value) Evaluator.Error!void {
        w.config = .{
            .opts = opts,
            .syms = .{
                .type = ev.s.type,
                .meta = ev.s.meta,
                .outputs = ev.s.outputs,
                .recurse = try ev.sym("recurseForDerivations"),
                .system = ev.s.system,
                .hydra_aggregate = try ev.sym("_hydraAggregate"),
                .constituents = try ev.sym("constituents"),
                .glob_constituents = try ev.sym("_hydraGlobConstituents"),
            },
            .auto_args = auto_args,
            .apply = apply,
        };
        ev.shared.prefetch = .{ .ctx = w, .f = prefetchTask };
    }

    fn rememberSet(w: *Walk, a: *Attrs, hash: u64, depth: u32) void {
        w.sets_lock.lockUncancelable(w.io);
        defer w.sets_lock.unlock(w.io);
        // a lost entry only makes a helper treat the set as below the chunk
        // depth, which forces more, never less
        w.sets.put(w.gpa, @intFromPtr(a), .{ .hash = hash, .depth = depth }) catch {};
    }

    fn recallSet(w: *Walk, a: *Attrs) ?SetAt {
        w.sets_lock.lockUncancelable(w.io);
        defer w.sets_lock.unlock(w.io);
        return w.sets.get(@intFromPtr(a));
    }

    /// The chunk rule for a node at `depth` with path hash `hash`. Units are
    /// the paths of length `chunk_depth` and the derivations above it; every
    /// deeper node belongs to its unit.
    pub fn admit(w: *const Walk, hash: u64, depth: u32, leaf: bool) bool {
        const o = w.config.opts;
        if (o.chunks <= 1 or depth > o.chunk_depth or (depth < o.chunk_depth and !leaf)) return true;
        return hash % o.chunks == o.chunk;
    }

    /// Walks `root` and hands every job or error line to `sink`, in
    /// lexicographic depth-first order. Only running out of memory stops it.
    pub fn run(w: *Walk, ev: *Evaluator, root: Value, sink: Sink) Allocator.Error!void {
        var path: std.ArrayList([]const u8) = .empty;
        defer path.deinit(w.gpa);
        return w.walk(ev, root, &path, fnv_basis, sink);
    }

    fn walk(w: *Walk, ev: *Evaluator, v: Value, path: *std.ArrayList([]const u8), hash: u64, sink: Sink) Allocator.Error!void {
        const depth: u32 = @intCast(path.items.len);
        if (depth == w.config.opts.chunk_depth and !w.admit(hash, depth, false)) return;
        const n = w.node(ev, v, path.items, hash) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EvalFailed => {
                // An attr that fails above the chunk depth is a unit of its
                // own, like a derivation there, so one chunk reports it.
                if (!w.admit(hash, depth, true)) {
                    ev.clearFailure();
                    return;
                }
                return sink.send(.{ .err = try errorLine(ev, w.gpa, path.items) });
            },
        };
        switch (n) {
            .job => |j| sink.send(.{ .job = j }),
            .skip => {},
            .recurse => |attrs| {
                w.rememberSet(attrs, hash, depth);
                const ordered = try print.lexicographic(ev, attrs);
                defer ev.gpa.free(ordered);
                const base = @intFromPtr(attrs.attrs().ptr);
                for (ordered, 0..) |attr, k| {
                    if (k % window == 0) {
                        // the cell range is in sym order, not walk order, but
                        // it covers the whole window before the walk reaches it
                        var lo: usize = std.math.maxInt(usize);
                        var hi: usize = 0;
                        for (ordered[k..@min(k + window, ordered.len)]) |x| {
                            const i = (@intFromPtr(x) - base) / @sizeOf(Attr);
                            lo = @min(lo, i);
                            hi = @max(hi, i + 1);
                        }
                        ev.fanout(.prefetch, .fromPtr(.ptr, attrs), @intCast(lo), @intCast(hi), job_batch);
                    }
                    const name = ev.interner.name(attr.sym);
                    try path.append(w.gpa, name);
                    defer path.items.len -= 1;
                    try w.walk(ev, attr.cell.get(), path, fnvStep(hash, name), sink);
                }
            },
        }
    }

    pub const Node = union(enum) {
        job: Job,
        recurse: *Attrs,
        skip,
    };

    /// worker.cc:processJobRequest for one attribute path: what to print or
    /// where to recurse.
    pub fn node(w: *Walk, ev: *Evaluator, v_in: Value, path: []const []const u8, hash: u64) Evaluator.Error!Node {
        const cfg = &w.config;
        const v = try ev.force(try ev.autoCall(v_in, cfg.auto_args));
        if (v.kind() != .attrs) return .skip;
        // the walk and the prefetch address children by index, so a union
        // is flattened here
        const attrs = v.as(Attrs);
        if (try ev.isDerivation(v)) {
            if (!w.admit(hash, @intCast(path.len), true)) return .skip;
            return .{ .job = try w.censusJob(ev, attrs, path) };
        }
        var recurse = cfg.opts.force_recurse or path.len == 0;
        if (!cfg.opts.force_recurse) if (attrs.get(cfg.syms.recurse)) |r| {
            recurse = try ev.forceBool(r.cell.get(), r.pos, "while evaluating recurseForDerivations");
        };
        return if (recurse) .{ .recurse = attrs } else .skip;
    }

    /// attr-path.cc:findAlongAttrPath with nix-eval-jobs's auto-call at
    /// every step: the value at `path` under `root`.
    pub fn findAlongAttrPath(w: *Walk, ev: *Evaluator, root: Value, path: []const []const u8) Evaluator.Error!Value {
        var v = root;
        for (path, 0..) |name, i| {
            v = try ev.force(try ev.autoCall(v, w.config.auto_args));
            const selection = try attrJoin(ev.gpa, path[0 .. i + 1]);
            defer ev.gpa.free(selection);
            if (isIndex(name) and v.kind() != .attrs) {
                if (v.kind() != .list)
                    return ev.fail(.type, .none, "the expression selected by the selection path '{s}' should be a list but is {s}", .{ selection, v.typeOf().name() });
                const l = v.as(value.List);
                const n = std.fmt.parseInt(usize, name, 10) catch std.math.maxInt(usize);
                if (n >= l.len)
                    return ev.fail(.eval, .none, "list index {d} in selection path '{s}' is out of range", .{ n, selection });
                v = l.cells()[n].get();
                continue;
            }
            if (v.kind() != .attrs)
                return ev.fail(.type, .none, "the expression selected by the selection path '{s}' should be a set but is {s}", .{ selection, v.typeOf().name() });
            const a = v.as(Attrs).get(try ev.sym(name)) orelse
                return ev.fail(.missing_attr, .none, "attribute '{s}' in selection path '{s}' not found", .{ name, selection });
            v = a.cell.get();
        }
        return v;
    }

    /// `job`; under the census, each job is an escape-tracking scope.
    inline fn censusJob(w: *Walk, ev: *Evaluator, a: *Attrs, path: []const []const u8) Evaluator.Error!Job {
        if (!Evaluator.census.enabled) return w.job(ev, a, path);
        const scope = ev.local.arena.census.scopeEnter(ev.local.arena.used);
        const r = w.job(ev, a, path);
        if (scope) {
            const c = &ev.local.arena.census;
            const bytes, const escapes = c.scopeLeave(ev.local.arena.used);
            c.job_scopes[0] += 1;
            c.job_scopes[1] += bytes;
            if (escapes == 0) {
                c.job_scopes[2] += 1;
                c.job_scopes[3] += bytes;
            }
        }
        return r;
    }

    /// drv.cc:Drv::fromPackageInfo, in the order nix-eval-jobs forces things:
    /// constituents, `--apply`, name, drvPath, outputs, the `.drv`, meta.
    fn job(w: *Walk, ev: *Evaluator, a: *Attrs, path: []const []const u8) Evaluator.Error!Job {
        const gpa = w.gpa;
        const cfg = &w.config;
        var j: Job = .{ .attr = try attrJoin(gpa, path), .attr_path = &.{}, .drv_path = undefined };
        errdefer j.deinit(gpa);
        j.attr_path = try dupeStrs(gpa, path);

        if (cfg.opts.constituents) try w.extractConstituents(ev, a, &j);
        if (j.named_constituents == null) j.named_constituents = try gpa.alloc([]const u8, 0);
        if (cfg.apply) |f| try j.putExtra(gpa, "extraValue", try applyJson(ev, gpa, f, a));

        const name = blk: {
            const n = a.get(ev.s.name) orelse return ev.fail(.eval, .none, "derivation name missing", .{});
            break :blk try ev.forceStringNoCtx(n.cell.get(), n.pos, "while evaluating the 'name' attribute of a derivation");
        };
        {
            const d = a.get(ev.s.drvPath) orelse return ev.fail(.eval, .none, "derivation does not contain a 'drvPath' attribute", .{});
            const p = try coerceStorePath(ev, d.cell.get(), d.pos, "while evaluating the 'drvPath' attribute of a derivation");
            if (!p.isDerivation()) return ev.fail(.eval, d.pos, "store path '{f}' is not a derivation", .{&p});
            j.drv_path = p;
        }
        // drv.cc:queryOutputs: an output path the evaluation cannot know yet
        // is a `null`, not an error, so a failure to resolve them is retried
        // with the names alone. nix-eval-jobs makes that retry conditional on
        // `ca-derivations`; iets never asks for the feature to evaluate such
        // a derivation, so it does not ask here either.
        w.outputs(ev, a, true, &j) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.EvalFailed => {
                if (ev.failureKind() == .cancelled) return e;
                ev.clearFailure();
                for (j.outputs.items) |o| gpa.free(o.name);
                j.outputs.clearRetainingCapacity();
                w.outputs(ev, a, false, &j) catch |e2| {
                    if (e2 == error.EvalFailed) if (ev.failure) |*f| {
                        const msg = try std.fmt.allocPrint(ev.gpa, "derivation '{s}' does not have valid outputs: {s}", .{ j.attr, f.msg });
                        ev.gpa.free(f.msg);
                        f.msg = msg;
                    };
                    return e2;
                };
            },
        };

        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var system: []const u8 = undefined;
        if (cfg.opts.no_instantiate) {
            // get-drvs.cc:PackageInfo::querySystem.
            system = if (a.get(cfg.syms.system)) |s|
                try ev.forceStringNoCtx(s.cell.get(), s.pos, "while evaluating the 'system' attribute of a derivation")
            else
                "unknown";
        } else {
            const drv = try readDrv(ev, scratch.allocator(), &j.drv_path);
            if (cfg.opts.show_input_drvs) try j.putExtra(gpa, "inputDrvs", try inputDrvsJson(gpa, &drv));
            const features = try requiredSystemFeatures(scratch.allocator(), &drv);
            try j.putExtra(gpa, "requiredSystemFeatures", try line.jsonStrList(gpa, features));
            system = drv.platform;
        }
        if (cfg.opts.meta) {
            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try w.metaJson(ev, a, &aw.writer);
            try j.putExtra(gpa, "meta", try aw.toOwnedSlice());
        }
        if (cfg.opts.provenance) if (try sitePos(ev, scratch.allocator(), &j.drv_path)) |s|
            try j.putExtra(gpa, "pos", try line.jsonStr(gpa, s));
        try j.putExtra(gpa, "name", try evalJsonStr(ev, gpa, name));
        try j.putExtra(gpa, "storeDir", try line.jsonStr(gpa, ev.store_dir));
        try j.putExtra(gpa, "system", try evalJsonStr(ev, gpa, system));
        return j;
    }

    /// get-drvs.cc:queryOutputs into `j`. Without `with_paths` the names are
    /// read and every path is left unknown, which is how a floating
    /// content-addressed output reaches the JSON as a `null`.
    fn outputs(w: *Walk, ev: *Evaluator, a: *Attrs, with_paths: bool, j: *Job) Evaluator.Error!void {
        const gpa = w.gpa;
        const o = a.get(w.config.syms.outputs) orelse {
            if (!with_paths) return j.putOutput(gpa, "out", null);
            const p = a.get(ev.s.outPath) orelse return ev.fail(.eval, .none, "derivation has no 'outPath' attribute", .{});
            const sp = try coerceStorePath(ev, p.cell.get(), p.pos, "while evaluating the output path of a derivation");
            return j.putOutput(gpa, "out", sp);
        };
        const l = try ev.forceList(o.cell.get(), o.pos, "while evaluating the 'outputs' attribute of a derivation");
        for (l.cells()) |*c| {
            const name = try ev.forceStringNoCtx(c.get(), o.pos, "while evaluating the name of an output of a derivation");
            if (!with_paths) {
                try j.putOutput(gpa, name, null);
                continue;
            }
            const v = a.get(try ev.sym(name)) orelse continue;
            const va = try ev.forceAttrs(v.cell.get(), o.pos, "while evaluating an output of a derivation");
            const p = va.get(ev.s.outPath) orelse continue;
            const sp = try coerceStorePath(ev, p.cell.get(), p.pos, "while evaluating an output path of a derivation");
            try j.putOutput(gpa, name, sp);
        }
    }

    /// drv.cc:queryMeta: `null` without usable entries, else an object.
    fn metaJson(w: *Walk, ev: *Evaluator, a: *Attrs, out: *Writer) Evaluator.Error!void {
        const m = a.get(w.config.syms.meta) orelse return out.writeAll("null") catch error.OutOfMemory;
        const meta = try ev.forceAttrs(m.cell.get(), m.pos, "while evaluating the 'meta' attribute of a derivation");
        const sorted = try print.lexicographic(ev, meta);
        defer ev.gpa.free(sorted);
        var ctx: std.ArrayList(value.Ctx) = .empty;
        defer ctx.deinit(ev.gpa);
        var first = true;
        for (sorted) |attr| {
            if (!try checkMeta(ev, attr.cell.get())) continue;
            out.writeByte(if (first) '{' else ',') catch return error.OutOfMemory;
            first = false;
            try writeJsonOrOom(print.writeJsonString(ev, out, ev.interner.name(attr.sym)));
            out.writeByte(':') catch return error.OutOfMemory;
            try writeJsonOrOom(print.writeJson(ev, out, attr.cell.get(), &ctx, true, attr.pos));
        }
        out.writeAll(if (first) "null" else "}") catch return error.OutOfMemory;
    }

    /// worker.cc:extractConstituents: the `.drv`s in the string context of
    /// `constituents`, the job names in it, and `_hydraGlobConstituents`.
    fn extractConstituents(w: *Walk, ev: *Evaluator, a: *Attrs, j: *Job) Evaluator.Error!void {
        const syms = &w.config.syms;
        const gpa = w.gpa;
        const agg = a.get(syms.hydra_aggregate) orelse return;
        if (!try ev.forceBool(agg.cell.get(), agg.pos, "while evaluating the `_hydraAggregate` attribute")) return;
        const c = a.get(syms.constituents) orelse return ev.fail(.eval, .none, "derivation must have a 'constituents' attribute", .{});
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(ev.gpa);
        var ctx: std.ArrayList(value.Ctx) = .empty;
        defer ctx.deinit(ev.gpa);
        try ev.coerceToString(c.cell.get(), &text, &ctx, c.pos, "while evaluating the `constituents` attribute", .{ .coerce_more = true, .copy_to_store = false });
        std.mem.sort(value.Ctx, ctx.items, {}, value.Ctx.lessThan);
        for (ctx.items) |e| {
            if (e.kind != .built) continue;
            // the `.drv` at the bottom of the chain: what a build starts from
            const root = if (std.mem.lastIndexOfScalar(u8, e.path, '!')) |i| e.path[i + 1 ..] else e.path;
            var d: Diag = .init(gpa);
            defer d.deinit();
            const p = StorePath.parse(root, &d) catch return ev.fail(.eval, c.pos, "{s}", .{d.message()});
            const items = j.constituents.items;
            if (items.len == 0 or !items[items.len - 1].eql(&p)) try j.constituents.append(gpa, p);
        }
        const l = try ev.forceList(c.cell.get(), c.pos, "while evaluating the `constituents` attribute");
        var named: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (named.items) |s| gpa.free(s);
            named.deinit(gpa);
        }
        for (l.cells()) |*cell| {
            const v = try ev.force(cell.get());
            if (v.kind() == .string) {
                try named.ensureUnusedCapacity(gpa, 1);
                named.appendAssumeCapacity(try gpa.dupe(u8, v.as(value.String).bytes()));
            }
        }
        j.glob_constituents = if (a.get(syms.glob_constituents)) |g|
            try ev.forceBool(g.cell.get(), g.pos, "while evaluating the `_hydraGlobConstituents` attribute")
        else
            false;
        j.setNamedConstituents(gpa, try named.toOwnedSlice(gpa));
    }

    /// A `prefetch` range task: force what the main walk
    /// will ask of each child in `start..end` of `attrs`. Never parks on a
    /// cell another fiber holds; an evaluation error in one child does not
    /// stop the others.
    fn prefetchTask(ctx: *anyopaque, ev: *Evaluator, attrs: *Attrs, start: u32, end: u32) void {
        const w: *Walk = @ptrCast(@alignCast(ctx));
        // A set the walk never registered is treated as below the chunk depth.
        const at = w.recallSet(attrs) orelse SetAt{ .hash = fnv_basis, .depth = std.math.maxInt(u32) - 1 };
        for (attrs.attrs()[start..end]) |*attr| if (!w.prefetchChild(ev, attr, at.hash, at.depth)) return;
    }

    /// Forces one child of a registered set and what a job needs of it.
    /// False only when the fiber must stop.
    fn prefetchChild(w: *Walk, ev: *Evaluator, attr: *Attr, hash: u64, depth: u32) bool {
        if (ev.bailRequested() or ev.par.cancelled) return false;
        const h = fnvStep(hash, ev.interner.name(attr.sym));
        const d = depth +% 1;
        if (d == w.config.opts.chunk_depth and !w.admit(h, d, false)) return true;
        // only the demand path may unbox a cell and take the effects a helper
        // held on its thunk (docs/explanation/evaluation.md); a prefetch task
        // runs on a helper, so it reads through the same call as a walk
        const v = switch (ev.takeCell(&attr.cell)) {
            .busy => return true,
            .ready => |r| r,
            .unclaimed => ev.forceCell(&attr.cell) catch return stopOrSkip(ev),
        };
        w.prefetchValue(ev, v, h, d) catch return stopOrSkip(ev);
        return true;
    }

    fn prefetchValue(w: *Walk, ev: *Evaluator, v_in: Value, hash: u64, depth: u32) Evaluator.Error!void {
        if (depth > 64) return;
        const cfg = &w.config;
        const v = try ev.autoCall(v_in, cfg.auto_args);
        if (v.kind() != .attrs) return;
        if (try ev.isDerivation(v)) {
            if (w.admit(hash, depth, true)) try w.prefetchJob(ev, v.as(Attrs));
            return;
        }
        const a = v.as(Attrs);
        var recurse = cfg.opts.force_recurse;
        if (!recurse) if (a.get(cfg.syms.recurse)) |r| {
            recurse = try ev.forceBool(r.cell.get(), r.pos, "");
        };
        if (!recurse) return;
        w.rememberSet(a, hash, depth);
        ev.fanout(.prefetch, .fromPtr(.ptr, a), 0, a.len, job_batch);
        for (a.attrs()) |*attr| if (!w.prefetchChild(ev, attr, hash, depth)) return ev.cancel();
    }

    fn prefetchJob(w: *Walk, ev: *Evaluator, a: *Attrs) Evaluator.Error!void {
        if (a.get(ev.s.name)) |n| _ = try ev.force(n.cell.get());
        if (a.get(ev.s.drvPath)) |d| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(ev.gpa);
            var ctx: std.ArrayList(value.Ctx) = .empty;
            defer ctx.deinit(ev.gpa);
            try ev.coerceToString(d.cell.get(), &out, &ctx, d.pos, "", .{ .copy_to_store = false });
        }
        var j: Job = .{ .attr = &.{}, .attr_path = &.{}, .drv_path = undefined };
        defer {
            for (j.outputs.items) |o| w.gpa.free(o.name);
            j.outputs.deinit(w.gpa);
        }
        try w.outputs(ev, a, true, &j);
        if (w.config.opts.meta) if (a.get(w.config.syms.meta)) |m| {
            const meta = try ev.forceAttrs(m.cell.get(), m.pos, "");
            for (meta.attrs()) |*attr| if (try checkMeta(ev, attr.cell.get())) {
                _ = try ev.forceDeep(attr.cell.get());
            };
        };
    }
};

/// False for a cancel, which stops the task; any other failure skips the
/// child, as the demand path will report it.
fn stopOrSkip(ev: *Evaluator) bool {
    const stop = ev.failureKind() == .cancelled;
    ev.clearFailure();
    return !stop;
}

/// Cells per helper task. A leaf costs a whole build graph, so batches
/// are small.
const job_batch = 4;
/// Children the main walk fans out ahead of itself in one go; the task
/// deque is bounded, so a huge set is fed in windows.
const window = 1024;

/// The error line for `path` from the failure in flight, which it clears;
/// also printed to stderr as nix-eval-jobs does. In `gpa`.
pub fn errorLine(ev: *Evaluator, gpa: Allocator, path: []const []const u8) Allocator.Error!ErrorLine {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try errorReport(ev, arena.allocator());
    if (ev.config.session) |s| _ = r.emit(&s.log);
    const fatal = ev.failureKind() == .stack_overflow;
    ev.clearFailure();
    const attr = try attrJoin(gpa, path);
    errdefer gpa.free(attr);
    const attr_path = try dupeStrs(gpa, path);
    errdefer freeStrs(gpa, attr_path);
    return .{ .attr = attr, .attr_path = attr_path, .message = r.text(gpa) catch return error.OutOfMemory, .fatal = fatal };
}

/// `api.report`'s report of the failure in flight, without the provenance
/// rewrite; in `a`.
pub fn errorReport(ev: *Evaluator, a: Allocator) Allocator.Error!log_mod.Report {
    const f = ev.failure orelse return .{ .code = "eval", .raw = "unknown failure" };
    const trace = try a.alloc(log_mod.TraceEntry, f.trace.items.len);
    for (f.trace.items, trace) |t, *e| e.* = .{
        .msg = try a.dupe(u8, t.msg),
        .pos = if (t.pos == .none) null else try describePos(ev, a, t.pos),
    };
    return .{
        .code = f.kind.code(),
        .raw = try a.dupe(u8, f.msg),
        .pos = if (f.pos == .none) null else try describePos(ev, a, f.pos),
        .trace = trace,
        .hint = if (f.hint) |h| try a.dupe(u8, h) else null,
    };
}

/// `file:line:col` of `pos`, never mapped to a local copy.
fn describePos(ev: *Evaluator, a: Allocator, pos: Pos) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{f}", .{ev.files.at(pos)});
}

/// worker.cc:attrPathJoin: elements containing a dot are quoted. In `gpa`.
pub fn attrJoin(gpa: Allocator, path: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (path, 0..) |p, i| {
        if (i > 0) try out.append(gpa, '.');
        const dotted = std.mem.indexOfScalar(u8, p, '.') != null;
        if (dotted) try out.append(gpa, '"');
        try out.appendSlice(gpa, p);
        if (dotted) try out.append(gpa, '"');
    }
    return out.toOwnedSlice(gpa);
}

pub const fnv_basis: u64 = 0xcbf29ce484222325;

/// FNV-1a of one more path element (NUL-terminated) after `h`.
pub fn fnvStep(h_in: u64, name: []const u8) u64 {
    var h = h_in;
    for (name) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h *% 0x100000001b3;
}

/// attr-path.cc: an all-digit component is a list index. Under an attrset it
/// names an attribute instead, where nix-eval-jobs fails: a `listToAttrs`
/// jobset keyed by numbers must build.
fn isIndex(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |b| if (!std.ascii.isDigit(b)) return false;
    _ = std.fmt.parseInt(u32, name, 10) catch return false;
    return true;
}

fn coerceStorePath(ev: *Evaluator, v: Value, pos: Pos, what: []const u8) Evaluator.Error!StorePath {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ev.gpa);
    var ctx: std.ArrayList(value.Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try ev.coerceToString(v, &out, &ctx, pos, what, .{ .copy_to_store = false });
    const s = out.items;
    if (!std.mem.startsWith(u8, s, ev.store_dir))
        return ev.fail(.eval, pos, "path '{s}' is not in the Nix store", .{s});
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    return StorePath.parse(s, &d) catch ev.fail(.eval, pos, "{s}", .{d.message()});
}

/// get-drvs.cc:PackageInfo::checkMeta: values JSON can carry, no
/// derivations, no functions, no null, no paths.
fn checkMeta(ev: *Evaluator, v_in: Value) Evaluator.Error!bool {
    const v = try ev.force(v_in);
    return switch (v.view()) {
        .list => |l| {
            for (l.cells()) |*c| if (!try checkMeta(ev, c.get())) return false;
            return true;
        },
        .attrs => |a| {
            if (a.get(ev.s.outPath) != null) return false;
            for (a.attrs()) |*attr| if (!try checkMeta(ev, attr.cell.get())) return false;
            return true;
        },
        .int, .bool, .string, .float => true,
        else => false,
    };
}

/// A writer error from an allocating writer is out of memory.
fn writeJsonOrOom(r: (Evaluator.Error || Writer.Error)!void) Evaluator.Error!void {
    r catch |e| return switch (e) {
        error.EvalFailed => error.EvalFailed,
        else => error.OutOfMemory,
    };
}

/// A JSON string of `s` as the evaluator writes one: invalid UTF-8 fails.
fn evalJsonStr(ev: *Evaluator, gpa: Allocator, s: []const u8) Evaluator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeJsonOrOom(print.writeJsonString(ev, &aw.writer, s));
    return aw.toOwnedSlice();
}

/// worker.cc:applyExprToValue: `--apply` on the job, printed as strict JSON.
fn applyJson(ev: *Evaluator, gpa: Allocator, f: Value, a: *Attrs) Evaluator.Error![]u8 {
    const res = try ev.apply(f, &.{.fromPtr(.ptr, a)}, .none);
    _ = try ev.forceAttrs(res, .none, "apply needs to evaluate to an attrset");
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var ctx: std.ArrayList(value.Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    try writeJsonOrOom(print.writeJson(ev, &aw.writer, res, &ctx, true, .none));
    return aw.toOwnedSlice();
}

/// `inputDrvs`: each input `.drv` and the outputs used of it.
fn inputDrvsJson(gpa: Allocator, drv: *const Derivation) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    (struct {
        fn f(wr: *Writer, d: *const Derivation) Writer.Error!void {
            try wr.writeByte('{');
            for (d.input_drvs, 0..) |in, i| {
                if (i > 0) try wr.writeByte(',');
                try line.writePath(wr, &in.path);
                try wr.writeByte(':');
                try line.writeStrList(wr, in.node.outputs);
            }
            try wr.writeByte('}');
        }
    }).f(w, drv) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// The `.drv` nix-eval-jobs reads back from the store: from this
/// evaluation's table, else from `/nix/store`. In `a`.
fn readDrv(ev: *Evaluator, a: Allocator, p: *const StorePath) Evaluator.Error!Derivation {
    var d: Diag = .init(a);
    const name = Derivation.nameFromPath(p, &d) catch return ev.fail(.eval, .none, "{s}", .{d.message()});
    const aterm = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        const info = ev.shared.drv.table.get(p.baseName()) orelse break :blk null;
        break :blk info.aterm;
    };
    if (aterm) |t| return Derivation.parse(a, t, name, &d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => ev.fail(.eval, .none, "{s}", .{d.message()}),
    };
    return drv_mod.loadDerivationFromStore(ev.io, a, p.*, &d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => ev.fail(.eval, .none, "{s}", .{d.message()}),
    };
}

/// derivation-options.cc:getRequiredSystemFeatures, sorted and unique; in `a`.
fn requiredSystemFeatures(a: Allocator, drv: *const Derivation) Allocator.Error![]const []const u8 {
    var set: std.ArrayList([]const u8) = .empty;
    if (drv.structured_attrs) |js| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, js, .{})) |v| {
            if (v == .object) if (v.object.get("requiredSystemFeatures")) |f| if (f == .array) {
                for (f.array.items) |x| if (x == .string) try set.append(a, x.string);
            };
        } else |_| {}
    } else if (drv.envGet("requiredSystemFeatures")) |s| {
        var it = std.mem.tokenizeAny(u8, s, " \t\n\r");
        while (it.next()) |x| try set.append(a, x);
    }
    const known = for (drv.outputs) |o| switch (o.output) {
        .input_addressed, .fixed => {},
        else => break false,
    } else true;
    if (!known) try set.append(a, "ca-derivations");
    std.mem.sort([]const u8, set.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var n: usize = 0;
    for (set.items) |x| {
        if (n > 0 and std.mem.eql(u8, set.items[n - 1], x)) continue;
        set.items[n] = x;
        n += 1;
    }
    return set.items[0..n];
}

/// `--provenance`: where the derivation `p` was defined, the local path when
/// its file is a copy of one; in `a`.
fn sitePos(ev: *Evaluator, a: Allocator, p: *const StorePath) Evaluator.Error!?[]const u8 {
    const pos = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        const info = ev.shared.drv.table.get(p.baseName()) orelse return null;
        break :blk info.site;
    };
    if (pos == .none) return null;
    const s = ev.config.session orelse return provenance.describePos(a, ev, null, pos);
    if (!s.settings.provenance) return provenance.describePos(a, ev, null, pos);
    // Built on first use, so a tree copied later is not in it;
    // only the walking fiber gets here.
    if (s.source_map == null) s.source_map = try .fromEval(s.gpa, ev, s.settings.source_map);
    return provenance.describePos(a, ev, &s.source_map.?, pos);
}

fn dupeStrs(gpa: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, items.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (items, out) |s, *o| {
        o.* = try gpa.dupe(u8, s);
        n += 1;
    }
    return out;
}

fn freeStrs(gpa: Allocator, items: []const []const u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

const testing = std.testing;

test "attrJoin quotes dotted names" {
    const s = try attrJoin(testing.allocator, &.{ "a", "b.c", "d" });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a.\"b.c\".d", s);
}

test "fnvStep hashes each element NUL-terminated" {
    var h: u64 = fnv_basis;
    for ("ab\x00") |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    try testing.expectEqual(h, fnvStep(fnv_basis, "ab"));
}

test "the chunk rule" {
    var w: Walk = .init(testing.allocator, testing.io);
    w.config.opts = .{ .chunks = 2, .chunk = 1, .chunk_depth = 2 };
    try testing.expect(w.admit(4, 1, false));
    try testing.expect(!w.admit(4, 1, true));
    try testing.expect(w.admit(5, 1, true));
    try testing.expect(!w.admit(4, 2, false));
    try testing.expect(w.admit(4, 3, true));
}

test "a numeric name selects an attribute under a set" {
    const Files = @import("eval/Files.zig");
    const Interner = @import("syntax/symbol.zig").Interner;
    const import_ = @import("eval/import.zig");
    const gpa = testing.allocator;
    var interner: Interner = try .init(gpa);
    defer interner.deinit();
    var files: Files = .init(gpa, testing.io);
    defer files.deinit();
    var shared: Shared = .{};
    defer shared.deinit(gpa);
    var local: Evaluator.Local = .init(gpa);
    defer local.deinit();
    value.flat_arena = &local.arena;
    defer value.flat_arena = null;
    var ev: Evaluator = try .init(gpa, testing.io, &local, &interner, &files, &shared, .{});
    defer ev.deinit();
    try @import("builtins.zig").install(&ev);

    var w: Walk = .init(gpa, testing.io);
    defer w.deinit();
    const args = try import_.evalString(&ev, "{ }");
    try w.configure(&ev, .{}, args.as(Attrs), null);
    const root = try import_.evalString(&ev,
        \\{ "9" = { a = 1; }; l = [ 7 ]; }
    );
    const cases = [_]struct { []const []const u8, ?i64 }{
        .{ &.{ "9", "a" }, 1 },
        .{ &.{"9"}, null },
        .{ &.{ "l", "0" }, 7 },
    };
    for (cases) |c| {
        const v = try w.findAlongAttrPath(&ev, root, c[0]);
        _ = try w.node(&ev, v, c[0], 0);
        const r = try ev.force(v);
        const got: ?i64 = if (r.view() == .int) r.view().int else null;
        try testing.expectEqual(c[1], got);
    }
}

test {
    std.testing.refAllDecls(@This());
}
