//! One build dispatch. Every command
//! that realises a derivation goes through `Dispatch`: the builder URL, the
//! upload plan, the connection, the upload and the build are one object, and
//! a root's output path is one lookup
//! (docs/explanation/plumbing-and-porcelain.md).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Evaluator = @import("../eval/Evaluator.zig");
const Session = @import("../session.zig").Session;
const config = @import("../config.zig");
const settings = @import("../settings.zig");
const remote = @import("../remote.zig");
const plan = remote.plan;
const Plan = plan.Plan;
const worker = remote.worker;
const StorePath = @import("../store/path.zig").StorePath;
const path_mod = @import("../store/path.zig");
const source = @import("../store/source.zig");
const SourceOrigin = source.SourceOrigin;
const locate = @import("../store/locate.zig");
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const store_hooks = @import("../builtins/store_hooks.zig");
const build = @import("../build.zig");
const executor = build.executor;
const Dispatcher = build.dispatch.Dispatcher;
const Target = build.dispatch.Target;
const Outcome = build.dispatch.Outcome;
pub const Style = build.render.Style;
const installable = @import("installable.zig");
const provenance = @import("../provenance.zig");
const Provenance = provenance.Provenance;
const Root = installable.Root;

pub const Error = remote.Error;

/// The Nix settings the native commands read: the session's nix.conf, or
/// the defaults when none was read.
pub fn nixConfig(s: *Session) config.Config {
    return s.nix_conf orelse .empty(s.gpa, s.io, s.env);
}

/// Every place the builds may go: the flag, else the `builder` setting, else
/// nix.conf's `store` (docs/reference/settings.md). In `arena`.
pub fn places(arena: Allocator, s: *Session, env: ?*const std.process.Environ.Map, url: ?[]const u8, d: *Diag) !executor.Places {
    const cfg = nixConfig(s);
    const specs = try settings.builders(arena, url, &s.settings, &cfg);
    return executor.Places.parse(arena, specs, cfg.system(), env, d);
}

/// The one store a command addresses, for the commands that address a store
/// rather than build: `plumbing missing`, `--dry-run`. With several places
/// that is the first one.
pub fn transport(arena: Allocator, s: *Session, env: ?*const std.process.Environ.Map, url: ?[]const u8, d: *Diag) !worker.Transport {
    return (try places(arena, s, env, url, d)).get(0).transport;
}

/// The derivations and sources an evaluation made, as the plan reads them.
/// The evaluator's tables are shared with its workers, so every read takes
/// their lock; the references are parsed once per derivation.
pub const EvalInputs = struct {
    ev: *Evaluator,
    lock: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    drvs: std.StringHashMapUnmanaged(?plan.DrvInfo) = .empty,

    pub fn init(ev: *Evaluator) EvalInputs {
        return .{ .ev = ev, .arena = .init(ev.gpa) };
    }

    pub fn deinit(e: *EvalInputs) void {
        e.drvs.deinit(e.ev.gpa);
        e.arena.deinit();
    }

    pub fn inputs(e: *EvalInputs) plan.Inputs {
        return .{ .ctx = e, .drv = drvFn, .source = sourceFn };
    }

    fn drvFn(ctx: ?*anyopaque, p: *const StorePath) ?plan.DrvInfo {
        const e: *EvalInputs = @ptrCast(@alignCast(ctx.?));
        return e.drv(p) catch null;
    }

    fn drv(e: *EvalInputs, p: *const StorePath) !?plan.DrvInfo {
        e.lock.lockUncancelable(e.ev.io);
        defer e.lock.unlock(e.ev.io);
        if (e.drvs.get(p.baseName())) |i| return i;
        const info = blk: {
            const ev = e.ev;
            ev.shared.drv_lock.lock(ev);
            defer ev.shared.drv_lock.unlock(ev);
            break :blk ev.shared.drv.table.get(p.baseName());
        };
        const a = e.arena.allocator();
        var out: ?plan.DrvInfo = null;
        if (info) |i| if (i.aterm) |aterm| {
            var d: Diag = .init(a);
            const refs = try a.alloc(StorePath, i.references.len);
            for (i.references, refs) |r, *o| o.* = try StorePath.parse(r, &d);
            out = .{ .aterm = aterm, .references = path_mod.sortUnique(refs) };
        };
        try e.drvs.put(e.ev.gpa, try a.dupe(u8, p.baseName()), out);
        return out;
    }

    fn sourceFn(ctx: ?*anyopaque, p: *const StorePath) ?SourceOrigin {
        const e: *EvalInputs = @ptrCast(@alignCast(ctx.?));
        const o = store_hooks.origin(e.ev, p) orelse return null;
        return switch (o.src) {
            .mem => |bytes| .text(bytes, o.refs),
            .fs => |f| .{ .at = .fs(f.root, f.accepted), .kind = .source, .nar = o.nar },
            // a copy of a member names the entry it is in and the member
            .tree => |x| .{ .at = .spool(if (x.t.name.len > 0) x.t.name else e.keepName(p) catch return null, x.t, x.accepted, o.rel), .kind = .source, .nar = o.nar orelse .{ .hash = x.t.nar_hash, .size = x.t.nar_size } },
        };
    }

    /// `p`'s base name where the plan can keep it: the caller's path may be
    /// a copy on its stack.
    fn keepName(e: *EvalInputs, p: *const StorePath) ![]const u8 {
        e.lock.lockUncancelable(e.ev.io);
        defer e.lock.unlock(e.ev.io);
        return e.arena.allocator().dupe(u8, p.baseName());
    }

    /// How many sources the evaluation added, for `--timings`.
    pub fn sourceCount(e: *EvalInputs) usize {
        const ev = e.ev;
        ev.shared.hooks_lock.lockUncancelable(ev.io);
        defer ev.shared.hooks_lock.unlock(ev.io);
        return ev.shared.hooks.known.count();
    }
};

/// Derivations read back from their ATerm text: `.drv` files, or the
/// entries of a `--dump-drvs` directory. Sources are not in it, so they
/// come from the local store.
pub const DrvTable = struct {
    arena: std.heap.ArenaAllocator,
    map: plan.PathMap(plan.DrvInfo) = .empty,

    pub fn init(gpa: Allocator) DrvTable {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(t: *DrvTable) void {
        t.arena.deinit();
    }

    pub fn inputs(t: *DrvTable) plan.Inputs {
        return .{ .ctx = t, .drv = struct {
            fn f(ctx: ?*anyopaque, p: *const StorePath) ?plan.DrvInfo {
                const tt: *DrvTable = @ptrCast(@alignCast(ctx.?));
                return tt.map.get(p.*);
            }
        }.f };
    }

    /// One derivation read back from its ATerm text.
    pub fn add(t: *DrvTable, path: StorePath, text: []const u8, d: *Diag) !void {
        const a = t.arena.allocator();
        const own = try a.dupe(u8, text);
        const drv = try Derivation.parse(a, own, try Derivation.nameFromPath(&path, d), d);
        const refs = try a.alloc(StorePath, drv.input_srcs.len + drv.input_drvs.len);
        for (drv.input_srcs, 0..) |s, i| refs[i] = s;
        for (drv.input_drvs, 0..) |in, i| refs[drv.input_srcs.len + i] = in.path;
        try t.map.put(a, path, .{ .aterm = own, .references = path_mod.sortUnique(refs) });
    }

    /// The derivations `--dump-drvs DIR` wrote: an evaluation's whole ATerm
    /// table, which is what lets one process plan or build a closure another
    /// evaluated and never wrote to the store (docs/reference/plumbing.md).
    pub fn addDir(t: *DrvTable, io: Io, dir: []const u8, d: *Diag) !void {
        var dh = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |e| return d.fail(error.Io, "reading '{s}': {s}", .{ dir, remote.ioText(e) });
        defer dh.close(io);
        var it = dh.iterate();
        while (it.next(io) catch |e| return d.fail(error.Io, "reading '{s}': {s}", .{ dir, remote.ioText(e) })) |entry| {
            var pd: Diag = .init(d.gpa);
            defer pd.deinit();
            const path = StorePath.fromBaseName(entry.name, &pd) catch continue;
            if (!path.isDerivation()) continue;
            const text = dh.readFileAlloc(io, entry.name, d.gpa, .unlimited) catch |e| return d.fail(error.Io, "reading '{s}': {s}", .{ entry.name, remote.ioText(e) });
            defer d.gpa.free(text);
            try t.add(path, text, d);
        }
    }
};

/// A planned closure, the connection that carries it, and the builds.
pub const Dispatch = struct {
    gpa: Allocator,
    io: Io,
    plan: Plan,
    /// `--source STOREPATH=LOCAL`: read those paths from a local tree.
    overrides: locate.Overrides = .empty,
    nix: locate.Nix,
    d: *Dispatcher,

    /// Connects `t` and takes over `p`; `prov` must outlive the dispatch.
    pub fn open(s: *Session, env: ?*const std.process.Environ.Map, t: *const worker.Transport, options: worker.Options, p: Plan, prov: *const Provenance, style: Style, d: *Diag) Error!Dispatch {
        const cx: build.backend.Context = .{ .gpa = s.gpa, .io = s.io, .env = env, .log = .of(&s.log) };
        return .{
            .gpa = s.gpa,
            .io = s.io,
            .plan = p,
            .nix = .{ .io = s.io, .env = s.env, .nix_bin_dir = s.settings.nix_bin_dir },
            .d = try Dispatcher.open(cx, &s.log, t, options, prov, style, d),
        };
    }

    pub fn deinit(x: *Dispatch) void {
        x.d.destroy();
        x.plan.deinit();
    }

    fn locator(x: *Dispatch) plan.Locator {
        return .{ .ctx = x, .f = struct {
            fn f(ctx: ?*anyopaque, paths: []const StorePath, out: []?SourceOrigin, arena: Allocator, d: *Diag) anyerror!void {
                const xx: *Dispatch = @ptrCast(@alignCast(ctx.?));
                return locate.locateInStore(arena, xx.nix, paths, &xx.overrides, out, d);
            }
        }.f };
    }

    /// Uploads what `batch` needs and builds it in one op.
    pub fn submit(x: *Dispatch, batch: []const Target, d: *Diag) Error![]Outcome {
        var up: build.upload.PlanUpload = .init(x.gpa, x.io, &x.plan, x.locator());
        defer up.deinit();
        return x.d.submit(up.uploader(), batch, d);
    }

    /// `--no-build`: register the closure and stop.
    pub fn uploadOnly(x: *Dispatch, roots: []const StorePath, d: *Diag) Error!void {
        var up: build.upload.PlanUpload = .init(x.gpa, x.io, &x.plan, x.locator());
        defer up.deinit();
        return x.d.uploadOnly(up.uploader(), roots, d);
    }

    /// `--dry-run`: what building `targets` would build and fetch, in `arena`.
    pub fn missing(x: *Dispatch, arena: Allocator, targets: []const Target, d: *Diag) Error!worker.Missing {
        var up: build.upload.PlanUpload = .init(x.gpa, x.io, &x.plan, x.locator());
        defer up.deinit();
        return x.d.missing(arena, up.uploader(), targets, d);
    }

    /// Builds every root in one op. Roots that share a derivation become one
    /// target carrying both outputs; `name` says what a derivation is called.
    pub fn realise(x: *Dispatch, arena: Allocator, roots: []const Root, ctx: anytype, comptime name: fn (@TypeOf(ctx), *const StorePath) []const u8, d: *Diag) Error!Built {
        var batch: std.ArrayList(Target) = .empty;
        var outs: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        // by pointer: a name may be a slice of the root itself (`drvName`)
        for (roots) |*r| {
            const i = for (batch.items, 0..) |t, k| {
                if (t.drv.eql(&r.drv)) break k;
            } else blk: {
                try batch.append(arena, .{ .attr = name(ctx, &r.drv), .drv = r.drv });
                try outs.append(arena, .empty);
                break :blk batch.items.len - 1;
            };
            for (outs.items[i].items) |o| {
                if (std.mem.eql(u8, o, r.output)) break;
            } else try outs.items[i].append(arena, r.output);
        }
        for (batch.items, outs.items) |*t, o| t.outputs = o.items;
        return .{ .outcomes = try x.submit(batch.items, d) };
    }
};

/// What a build put in the store, by derivation and output name.
pub const Built = struct {
    outcomes: []const Outcome,

    /// One output path per root, in the order the roots were given; in `a`.
    pub fn paths(b: Built, a: Allocator, roots: []const Root, d: *Diag) ![]const []const u8 {
        const out = try a.alloc([]const u8, roots.len);
        for (roots, out) |r, *o|
            o.* = b.find(r) orelse return d.fail(error.Store, "derivation '{f}' has no output '{s}'", .{ &r.drv, r.output });
        return out;
    }

    fn find(b: Built, r: Root) ?[]const u8 {
        for (b.outcomes) |oc| {
            if (!oc.drv.eql(&r.drv)) continue;
            for (oc.outputs) |x| if (std.mem.eql(u8, x.name, r.output)) return x.path;
        }
        return null;
    }
};

/// The source map and the sites of every derivation this evaluation made.
pub fn snapshot(s: *Session, arena: Allocator, ev: *Evaluator) !Provenance {
    var drvs: std.ArrayList(Provenance.Drv) = .empty;
    {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        var it = ev.shared.drv.table.iterator();
        while (it.next()) |e| {
            const i = e.value_ptr.*;
            if (i.attr == null and i.site == .none) continue;
            try drvs.append(arena, .{
                .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path_mod.store_dir, e.key_ptr.* }),
                .attr = i.attr,
                .pos = if (i.site == .none) null else i.site,
            });
        }
    }
    return Provenance.snapshot(s.gpa, ev, s.settings.source_map, drvs.items, s.settings.provenance);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Dispatch);
    std.testing.refAllDecls(EvalInputs);
    std.testing.refAllDecls(DrvTable);
}
