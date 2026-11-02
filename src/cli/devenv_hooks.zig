//! `print-dev-env`'s steps that evaluate and build, on the evaluator
//! (`api/run.zig`), the installable resolution and the worker backend; and
//! its tracing cache entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Evaluator = @import("../eval/Evaluator.zig");
const value = @import("../runtime/value.zig");
const remote = @import("../remote.zig");
const worker = remote.worker;
const Transport = worker.Transport;
const Connection = worker.Connection;
const Sink = remote.event.Sink;
const StorePath = @import("../store/path.zig").StorePath;
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const api = @import("../api.zig");
const installable = api.installable;
const derivation = @import("../builtins/derivation.zig");
const store_hooks = @import("../builtins/store_hooks.zig");
const devenv_mod = @import("../devenv.zig");
const treestore = @import("../treestore.zig");
const build = @import("../build.zig");
const backend = build.backend;
const Provenance = @import("../provenance.zig").Provenance;
const cli = @import("../cli.zig");
const args_mod = @import("args.zig");
const devenv = @import("devenv.zig");
const Error = devenv.Error;

pub const Impl = struct {
    /// The `-env` derivation is in the store or was built: the connection that
    /// did it, which `finish` gives back.
    pub const Realised = struct {
        conn: *Connection,
        /// Whether a build ran (the outputs were not all valid before).
        built: bool,
        /// `Worker::report(&plan, plan_time)` for `--timings`, when it built.
        report: ?[]const u8 = null,
    };

    /// The evaluator's derivation hash cache and the loader behind it.
    pub const HashCache = struct { cache: *drv_mod.DrvHashCache, loader: drv_mod.Loader };

    c: *const cli.Ctx,
    args: api.EvalArgs = .{},
    /// Classic mode's evaluator configuration (`nix develop`), whose run
    /// keys and evaluates as classic mode does: no lints, nix.conf's system.
    classic: ?*const api.run.Classic = null,
    /// The run's tracing cache, from `openCache`.
    cache: ?*api.cache.Cache = null,
    /// The input store a hit validates against.
    inputs: ?*treestore.Store = null,
    ev: ?*Evaluator = null,
    w: ?*backend.Worker = null,
    /// The exit code of the failure a step reported (`error.Reported`).
    code: u8 = 1,

    pub fn deinit(h: *Impl) void {
        if (h.cache) |c| c.deinit();
        if (h.inputs) |i| i.deinit();
        h.cache = null;
        h.inputs = null;
    }

    /// `run.cached(&args, kind)`: the tracing cache entry of this run, none
    /// when the cache is off or the run cannot be keyed.
    pub fn openCache(h: *Impl, kind: []const u8) void {
        h.cache = api.cache.openFor(h.c.s, h.c.init, &h.args, kind, &.{}, h.classic) catch null;
    }

    /// The run evaluates `flake` with `args`, its tracing cache entry of
    /// the kind `kind`.
    pub fn begin(h: *Impl, args: api.EvalArgs, flake: []const u8, kind: []const u8) void {
        h.args = args;
        h.args.input = .{ .flake = flake };
        h.openCache(kind);
    }

    /// A failure reported with the exit code `code`.
    pub fn exit(h: *Impl, code: u8) error{Reported} {
        h.code = code;
        return error.Reported;
    }

    pub fn entryPath(h: *Impl, arena: Allocator) ?[]const u8 {
        const c = h.cache orelse return null;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        return arena.dupe(u8, c.entryPath(&buf)) catch null;
    }

    pub fn cachedResult(h: *Impl, arena: Allocator) ?[]const u8 {
        const c = h.cache orelse return null;
        const s = h.c.s;
        if (h.inputs == null) h.inputs = api.cache.inputStore(h.c.init.arena.allocator(), s, h.c.init.environ_map, h.args.cache_dir) catch return null;
        if (!api.cache.hit(s, c, h.inputs.?)) return null;
        return arena.dupe(u8, c.part(.result) orelse return null) catch null;
    }

    pub fn replayWarnings(h: *Impl) void {
        const c = h.cache orelse return;
        c.replayWarnings() catch {};
    }

    pub fn writeResult(h: *Impl, bytes: []const u8) void {
        const c = h.cache orelse return;
        api.cache.writeEntry(c, h.c.s, h.ev.?, bytes, false) catch {};
    }

    pub fn run(h: *Impl, job: *const fn (job_ctx: *anyopaque) u8, job_ctx: *anyopaque) u8 {
        const J = struct {
            h: *Impl,
            job: *const fn (job_ctx: *anyopaque) u8,
            job_ctx: *anyopaque,
            fn go(j: *@This(), ev: *Evaluator) !u8 {
                j.h.ev = ev;
                defer j.h.ev = null;
                return j.job(j.job_ctx);
            }
        };
        var j: J = .{ .h = h, .job = job, .job_ctx = job_ctx };
        const r: api.run.Run = .{ .s = h.c.s, .init = h.c.init, .args = &h.args, .classic = h.classic, .cache = h.cache };
        return r.go(&j, J.go);
    }

    /// What evaluation found for the installable: its derivations
    /// (`installable::drv_roots`). An evaluation error is reported here.
    pub fn evalRoots(h: *Impl, arena: Allocator, loc: []const u8, frag: []const u8, d: *Diag) (Error || error{Reported})![]const StorePath {
        const ev = h.ev.?;
        return h.resolveRoots(ev, arena, loc, frag, d) catch |e| switch (e) {
            error.EvalFailed => return h.exit(api.report(ev, h.c.s, arena) catch 1),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// The flake's outputs, the first dev-shell candidate of `frag`, and the
    /// derivations it names.
    fn resolveRoots(h: *Impl, ev: *Evaluator, arena: Allocator, loc: []const u8, frag: []const u8, d: *Diag) Evaluator.Error![]const StorePath {
        _ = d;
        var one = h.args;
        one.input = .{ .flake = loc };
        one.attr = null;
        const cwd = std.process.currentPathAlloc(h.c.init.io, arena) catch "/";
        const outputs = try api.evaluate(ev, arena, &one, cwd);
        const candidates = try installable.attrPaths(arena, .dev_shell, frag, ev.config.system);
        const found = for (candidates) |cand| {
            if (try selectPath(ev, arena, outputs, cand)) |v| break v;
        } else {
            var buf: std.Io.Writer.Allocating = .init(arena);
            installable.showAttrPaths(&buf.writer, candidates) catch return error.OutOfMemory;
            return ev.fail(.missing_attr, .none, "flake '{s}' does not provide attribute {s}", .{ loc, buf.written() });
        };
        var roots: std.ArrayList(installable.DrvRoot) = .empty;
        try installable.drvRoots(ev, arena, found, &roots);
        const out = try arena.alloc(StorePath, roots.items.len);
        for (roots.items, out) |r, *o| o.* = r.drv;
        return out;
    }

    pub fn loadDrv(h: *Impl, arena: Allocator, path: StorePath, d: *Diag) Error!Derivation {
        const ev = h.ev.?;
        const kept = blk: {
            ev.shared.drv_lock.lock(ev);
            defer ev.shared.drv_lock.unlock(ev);
            const i = ev.shared.drv.table.get(path.baseName()) orelse break :blk null;
            break :blk i.aterm;
        };
        if (kept) |aterm| return Derivation.parse(arena, aterm, Derivation.nameFromPath(&path, d) catch return error.Store, d) catch |e| mapDrv(e);
        return drv_mod.loadDerivationFromStore(ev.io, arena, path, d) catch |e| mapDrv(e);
    }

    pub fn lockHashCache(h: *Impl) HashCache {
        const ev = h.ev.?;
        ev.shared.drv_lock.lock(ev);
        return .{ .cache = ev.shared.drv.hashCache(ev.gpa), .loader = .{ .ctx = h, .loadFn = loadFn } };
    }

    fn loadFn(ctx: *anyopaque, arena: Allocator, p: StorePath, d: *Diag) drv_mod.Error!Derivation {
        return loadDrv(@ptrCast(@alignCast(ctx)), arena, p, d) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadDerivation,
        };
    }

    pub fn releaseHashCache(h: *Impl) void {
        const ev = h.ev.?;
        ev.shared.drv_lock.unlock(ev);
    }

    pub fn record(h: *Impl, env_path: StorePath, drv: *const Derivation, aterm: []const u8, d: *Diag) Error!void {
        _ = d;
        const ev = h.ev.?;
        const a = ev.local.arena.allocator();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const refs = try a.alloc([]const u8, drv.input_srcs.len + drv.input_drvs.len);
        for (drv.input_srcs, refs[0..drv.input_srcs.len]) |*p, *r| r.* = try a.dupe(u8, p.print(&buf));
        for (drv.input_drvs, refs[drv.input_srcs.len..]) |*in, *r| r.* = try a.dupe(u8, in.path.print(&buf));
        const names = try a.alloc([]const u8, drv.outputs.len);
        for (drv.outputs, names) |o, *n| n.* = try a.dupe(u8, o.name);
        {
            ev.shared.drv_lock.lock(ev);
            defer ev.shared.drv_lock.unlock(ev);
            const g = try ev.shared.drv.table.getOrPut(ev.gpa, env_path.baseName());
            if (!g.found_existing) g.key_ptr.* = try a.dupe(u8, env_path.baseName());
            g.value_ptr.* = .{ .outputs = names, .references = refs, .aterm = try a.dupe(u8, aterm) };
        }
        const sh = devenv_mod.getEnvShPath();
        store_hooks.addText(ev, &sh, devenv_mod.get_env_sh, &.{}) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.EvalFailed => error.Store,
        };
    }

    pub fn derivationCount(h: *Impl) u64 {
        return h.ev.?.shared.drv.nr_derivations;
    }

    pub fn provenance(h: *Impl, gpa: Allocator) Allocator.Error!Provenance {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        return api.build.snapshot(h.c.s, arena.allocator(), h.ev.?);
    }

    pub fn realise(h: *Impl, arena: Allocator, transport: *const Transport, options: *const worker.Options, env_path: StorePath, out_paths: []const []const u8, sink: Sink, d: *Diag) Error!Realised {
        const s = h.c.s;
        const ev = h.ev.?;
        const cx: backend.Context = .{ .gpa = s.gpa, .io = s.io, .env = h.c.init.environ_map, .log = .of(&s.log) };
        const w = try backend.Worker.open(cx, transport, options.*, sink, d);
        h.w = w;
        const outs = try arena.alloc(StorePath, out_paths.len);
        for (out_paths, outs) |p, *o| o.* = try StorePath.parse(p, d);
        const valid = try w.conn.queryValid(arena, outs, sink, d);
        if (valid.len == out_paths.len) return .{ .conn = w.conn, .built = false };
        const t2 = now(s.io);
        var inputs: api.build.EvalInputs = .init(ev);
        defer inputs.deinit();
        var p = remote.plan.plan(s.gpa, s.io, &.{env_path}, inputs.inputs(), d) catch |e| return mapPlan(e);
        defer p.deinit();
        const plan_time = now(s.io) - t2;
        const Loc = struct {
            nix: @import("../store/locate.zig").Nix,
            fn f(c: ?*anyopaque, paths: []const StorePath, out: []?@import("../store/source.zig").SourceOrigin, a: Allocator, dd: *Diag) anyerror!void {
                const l: *@This() = @ptrCast(@alignCast(c.?));
                const none: @import("../store/locate.zig").Overrides = .empty;
                return @import("../store/locate.zig").locateInStore(a, l.nix, paths, &none, out, dd);
            }
        };
        var loc: Loc = .{ .nix = .{ .io = s.io, .env = s.env, .nix_bin_dir = s.settings.nix_bin_dir } };
        var up: build.upload.PlanUpload = .init(s.gpa, s.io, &p, .{ .ctx = &loc, .f = Loc.f });
        defer up.deinit();
        const b = backend.Backend.of(backend.Worker, w);
        _ = try up.upload(b, &.{env_path}, sink, d);
        const job: backend.Job = .{ .drv = env_path };
        const NoDrvs = struct {
            fn f(_: ?*anyopaque, _: bool, _: Allocator, _: *Diag) anyerror![]const backend.Drv {
                return &.{};
            }
        };
        const status = try w.submit(arena, .{ .jobs = &.{job}, .drvs = NoDrvs.f }, sink, d);
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        for (status.values()) |st| if (!st.ok) sink.send(worker.failedEvent(env_path.print(&pbuf), st.reason));
        var rep: std.Io.Writer.Allocating = .init(arena);
        w.report(&rep.writer, &p, plan_time) catch {};
        return .{ .conn = w.conn, .built = true, .report = rep.written() };
    }

    pub fn finish(h: *Impl) void {
        if (h.w) |w| w.close();
        h.w = null;
    }
};

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).toNanoseconds());
}

fn mapDrv(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Store,
    };
}

fn mapPlan(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Io => error.Io,
        error.Protocol => error.Protocol,
        else => error.Store,
    };
}

/// `path` selected in `v`, null when an attribute on the way is missing.
fn selectPath(ev: *Evaluator, arena: Allocator, v_in: value.Value, path: []const u8) Evaluator.Error!?value.Value {
    var d: Diag = .init(arena);
    const parts = installable.parseAttrPath(arena, path, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ev.fail(.eval, .none, "{s}", .{d.message()}),
    };
    var v = v_in;
    for (parts) |name| {
        const f = try ev.force(v);
        if (f.kind() != .attrs) return null;
        const at = f.as(value.Attrs).get(try ev.sym(name)) orelse return null;
        v = at.cell.get();
    }
    return v;
}
