//! The dispatcher's transport half.
//! `Dispatcher` (build/dispatch.zig) owns the batching, the provenance, the
//! event stream and the records; a `Backend` owns the wire: what "ask
//! whether these paths are valid", "register these objects" and "build this
//! ready set" mean on one transport.
//!
//! Two of them. The worker backend holds one `Connection` and sends one
//! `BuildPathsWithResults` per ready set, because the protocol is serial per
//! connection and a per-derivation op idles the daemon between derivations
//! (docs/explanation/history.md: 7-10x slower). The `grpc://` backend fans
//! the ready set out instead: one `BuildDerivation` per derivation, placed
//! by the store's scheduler, with up to `max-builds` in flight, which the
//! gRPC API tags with its derivation, so the events key correctly.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const remote = @import("../remote.zig");
const StorePath = @import("../store/path.zig").StorePath;
const worker = remote.worker;
const wire = worker.wire;
const plan = remote.plan;
const Plan = plan.Plan;
const Object = plan.Object;
const copy = remote.copy;
const Sink = remote.event.Sink;
const Error = remote.Error;
const nar = @import("../store/nar.zig");
const grpc_config = remote.grpc.config;
const Grpc = remote.grpc.backend.Grpc;

/// One derivation of a ready set, and the outputs the caller wants.
pub const Job = struct {
    drv: StorePath,
    /// Empty means every output.
    outputs: []const []const u8 = &.{},

    /// `<out1,out2>` sorted and unique, or `*`: the output half of a derived
    /// path; in `arena`.
    pub fn spec(j: Job, arena: Allocator) Allocator.Error![]const u8 {
        if (j.outputs.len == 0) return "*";
        const names = try arena.dupe([]const u8, j.outputs);
        std.mem.sort([]const u8, names, {}, lessStr);
        var out: std.ArrayList(u8) = .empty;
        for (names, 0..) |n, i| {
            if (i > 0 and std.mem.eql(u8, n, names[i - 1])) continue;
            if (out.items.len > 0) try out.append(arena, ',');
            try out.appendSlice(arena, n);
        }
        return out.items;
    }

    /// `/nix/store/x.drv!spec`, the derived path the worker protocol takes.
    pub fn derivedPath(j: Job, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{f}!{s}", .{ &j.drv, try j.spec(arena) });
    }
};

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// What became of one derivation of a ready set.
pub const Status = struct {
    ok: bool,
    /// The one-line reason, when it failed.
    reason: []const u8 = "",
    /// `buildExit` of the failure, 0 for a success.
    exit: i32 = 0,

    pub const ok_status: Status = .{ .ok = true };

    pub fn failed(reason: []const u8, exit: i32) Status {
        return .{ .ok = false, .reason = reason, .exit = exit };
    }
};

/// One derivation of a batch's closure: its path and the ATerm that hashes
/// to it.
pub const Drv = struct {
    path: StorePath,
    aterm: []const u8,
};

/// One ready set, plus the derivations behind it.
pub const Batch = struct {
    jobs: []const Job,
    /// The jobs' own derivations, or with `true` everything they need too,
    /// references before referrers, allocated in `arena`.
    drvs_ctx: ?*anyopaque = null,
    drvs: *const fn (ctx: ?*anyopaque, closure: bool, arena: Allocator, d: *Diag) anyerror![]const Drv,
};

/// What the client side of an upload measured, which no backend can see:
/// `--timings` wants it in the same report.
pub const Phase = struct {
    /// Planned paths the store lacked.
    missing: usize = 0,
    resolve_ns: u64 = 0,
    /// Missing sources the client located and hashed.
    resolve_paths: usize = 0,
    /// Of those, the ones read from the local store.
    store_sources: usize = 0,
};

/// How a build's end is logged, shared with the gRPC backend.
pub const buildExit = @import("../log.zig").buildExit;

/// The local daemon, where out-links and GC roots go whatever the builder
/// is (docs/reference/classic.md).
pub fn local(arena: Allocator, env: ?*const std.process.Environ.Map) Allocator.Error!worker.Transport {
    return .{ .unix = try worker.defaultSocket(arena, env) };
}

/// A store path and the out-link `nix build` makes for it, if any.
pub const Link = struct { path: []const u8, link: ?[]const u8 };

/// The store paths `out_links` was given, in `arena`.
pub fn linkTargets(arena: Allocator, links: []const Link, d: *Diag) remote.Error![]StorePath {
    const out = try arena.alloc(StorePath, links.len);
    for (links, out) |l, *p| p.* = StorePath.parse(l.path, d) catch return error.Store;
    return out;
}

/// Makes each symlink that was asked for, as a GC root of `conn`'s store.
pub fn addRoots(conn: *worker.Connection, links: []const Link, d: *Diag) remote.Error!void {
    for (links) |l| if (l.link) |link| try conn.addPermRoot(l.path, link, d);
}

/// What either backend did, in the shape `--timings` prints. Durations in ns.
pub const Timings = struct {
    connect: u64 = 0,
    query: u64 = 0,
    resolve: u64 = 0,
    substitute: u64 = 0,
    add: u64 = 0,
    build: u64 = 0,
    outputs: u64 = 0,
    fetch: u64 = 0,
    /// `-o`: the copy into the local store and the GC roots.
    link: u64 = 0,
    trusted: ?bool = null,
    query_paths: usize = 0,
    missing: usize = 0,
    /// Missing sources the client located and hashed.
    resolve_paths: usize = 0,
    /// Of those, the ones with no eval-time origin, found through the local store.
    store_sources: usize = 0,
    /// Missing sources left to the store's substituters.
    substitute_paths: usize = 0,
    add_paths: usize = 0,
    add_bytes: u64 = 0,
    fetched: usize = 0,
    links: usize = 0,
    /// Paths `-o` copied into the local store; the rest it already held.
    link_copied: usize = 0,

    pub fn noteUpload(t: *Timings, p: Phase) void {
        t.missing += p.missing;
        t.resolve += p.resolve_ns;
        t.resolve_paths += p.resolve_paths;
        t.store_sources += p.store_sources;
    }

    /// `protocol`, `store` and `built` are the words that differ by
    /// transport; the caller appends its own last line.
    pub fn report(t: *const Timings, w: *Writer, p: *const Plan, plan_time: u64, protocol: []const u8, store: []const u8, built: []const u8) Writer.Error!void {
        const trusted = if (t.trusted) |b| (if (b) "trusted" else "untrusted") else "trust unknown";
        try w.print("plan: {d} sources, {d} drvs, {f}s\nconnect: {s}, {s}, {f}s\nquery: {d} paths, {d} missing, {f}s\nresolve: {d} sources", .{
            p.sources.len,   p.drvs.len, secs(plan_time),
            protocol,        trusted,    secs(t.connect),
            t.query_paths,   t.missing,  secs(t.query),
            t.resolve_paths,
        });
        if (t.store_sources > 0) try w.print(", {d} not from this eval, read from /nix/store", .{t.store_sources});
        try w.print(", {f}s", .{secs(t.resolve)});
        if (t.substitute_paths > 0)
            try w.print("\nsubstitute: {d} paths left to the {s}, {f}s", .{ t.substitute_paths, store, secs(t.substitute) });
        try w.print("\nadd: {d} paths, {d} bytes, {f}s\nbuild: {s}{f}s\noutputs: {f}s", .{
            t.add_paths, t.add_bytes, secs(t.add), built, secs(t.build), secs(t.outputs),
        });
        if (t.fetched > 0) try w.print("\nfetch: {d} outputs, {f}s", .{ t.fetched, secs(t.fetch) });
        if (t.links > 0) try w.print("\nlink: {d} out-links, {d} paths copied, {f}s", .{ t.links, t.link_copied, secs(t.link) });
    }
};

/// Seconds with three decimals, as Rust iets prints them in the timings.
pub fn secs(ns: u64) Secs {
    return .{ .ns = ns };
}

pub const Secs = struct {
    ns: u64,
    pub fn format(s: Secs, w: *Writer) Writer.Error!void {
        // rounded to the millisecond, as `{:.3}` of the seconds prints them
        const ms_total = (s.ns + 500_000) / 1_000_000;
        try w.print("{d}.{d:0>3}", .{ ms_total / 1000, ms_total % 1000 });
    }
};

/// The timings with every line, for the report tests of both backends.
pub fn everyTiming() Timings {
    const ms = std.time.ns_per_ms;
    return .{
        .connect = 1 * ms,
        .query = 2 * ms,
        .resolve = 3 * ms,
        .substitute = 4 * ms,
        .add = 5 * ms,
        .build = 6 * ms,
        .outputs = 7 * ms,
        .fetch = 8 * ms,
        .trusted = true,
        .query_paths = 9,
        .missing = 8,
        .resolve_paths = 7,
        .store_sources = 6,
        .substitute_paths = 5,
        .add_paths = 4,
        .add_bytes = 3,
        .fetched = 2,
        .link = 10 * ms,
        .links = 1,
        .link_copied = 3,
    };
}

/// The verdicts of one ready set, by derivation path.
pub const StatusMap = std.StringArrayHashMapUnmanaged(Status);
/// Output name to store path, sorted by name; a null path is not known
/// without building.
pub const OutputEntry = worker.Connection.OutputEntry;

/// One transport, as the dispatcher uses it. `of`
/// makes one from any type with these methods.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The subset of `paths` the store already has, by base name, in `arena`.
        queryValid: *const fn (*anyopaque, Allocator, []const StorePath, Sink, *Diag) Error!plan.NameSet,
        /// Realises the sources the client cannot produce (an input-addressed
        /// build output pinned with `builtins.storePath`): the store
        /// substitutes them, and must hold them before the drvs that name them.
        substitute: *const fn (*anyopaque, []const StorePath, Sink, *Diag) Error!void,
        /// Registers `objects` on the store; returns the bytes it cost.
        addObjects: *const fn (*anyopaque, []const *Object, Sink, *Diag) Error!u64,
        /// Builds a ready set. Every job gets a verdict, keyed by its
        /// derivation path; a job the store never reached is absent.
        submit: *const fn (*anyopaque, Allocator, Batch, Sink, *Diag) Error!StatusMap,
        /// What building `jobs` would build and fetch; null when the
        /// transport cannot say.
        missing: ?*const fn (*anyopaque, Allocator, []const Job, Sink, *Diag) Error!worker.Missing,
        /// Output name to store path for a derivation that built.
        outputs: *const fn (*anyopaque, Allocator, []const u8, Sink, *Diag) Error![]const OutputEntry,
        /// Restores one output into `dir`, whose existence the caller checked.
        fetch: *const fn (*anyopaque, []const u8, []const u8, *Diag) Error!void,
        /// An indirect GC root at `link` for `store_path`.
        addRoot: *const fn (*anyopaque, []const u8, []const u8, *Diag) Error!void,
        /// `nix build`'s outputs on the local daemon, an output the builder
        /// kept registered there first, and a symlink with its GC root where
        /// a link is named. `--no-link` names none, yet the path stays valid,
        /// as the build hook leaves it.
        outLinks: *const fn (*anyopaque, []const Link, *Diag) Error!void,
        noteConnect: *const fn (*anyopaque, u64) void,
        noteUpload: *const fn (*anyopaque, Phase) void,
        /// `--timings`: one line per phase, in the flow's order.
        report: *const fn (*anyopaque, *Writer, *const Plan, u64) Writer.Error!void,
        close: *const fn (*anyopaque) void,
    };

    /// `T`'s methods as a backend; `missing` is optional.
    pub fn of(comptime T: type, p: *T) Backend {
        const V = struct {
            fn self(c: *anyopaque) *T {
                return @ptrCast(@alignCast(c));
            }
            fn queryValid(c: *anyopaque, a: Allocator, paths: []const StorePath, s: Sink, d: *Diag) Error!plan.NameSet {
                return self(c).queryValid(a, paths, s, d);
            }
            fn substitute(c: *anyopaque, paths: []const StorePath, s: Sink, d: *Diag) Error!void {
                return self(c).substitute(paths, s, d);
            }
            fn addObjects(c: *anyopaque, objects: []const *Object, s: Sink, d: *Diag) Error!u64 {
                return self(c).addObjects(objects, s, d);
            }
            fn submit(c: *anyopaque, a: Allocator, b: Batch, s: Sink, d: *Diag) Error!StatusMap {
                return self(c).submit(a, b, s, d);
            }
            fn missing(c: *anyopaque, a: Allocator, jobs: []const Job, s: Sink, d: *Diag) Error!worker.Missing {
                return self(c).missing(a, jobs, s, d);
            }
            fn outputs(c: *anyopaque, a: Allocator, drv: []const u8, s: Sink, d: *Diag) Error![]const OutputEntry {
                return self(c).outputs(a, drv, s, d);
            }
            fn fetch(c: *anyopaque, sp: []const u8, dir: []const u8, d: *Diag) Error!void {
                return self(c).fetch(sp, dir, d);
            }
            fn addRoot(c: *anyopaque, sp: []const u8, link: []const u8, d: *Diag) Error!void {
                return self(c).addRoot(sp, link, d);
            }
            fn outLinks(c: *anyopaque, links: []const Link, d: *Diag) Error!void {
                return self(c).outLinks(links, d);
            }
            fn noteConnect(c: *anyopaque, ns: u64) void {
                self(c).noteConnect(ns);
            }
            fn noteUpload(c: *anyopaque, ph: Phase) void {
                self(c).noteUpload(ph);
            }
            fn report(c: *anyopaque, w: *Writer, pl: *const Plan, t: u64) Writer.Error!void {
                return self(c).report(w, pl, t);
            }
            fn close(c: *anyopaque) void {
                self(c).close();
            }
        };
        const W = struct {
            const vtable: VTable = .{
                .queryValid = V.queryValid,
                .substitute = V.substitute,
                .addObjects = V.addObjects,
                .submit = V.submit,
                .missing = if (@hasDecl(T, "missing")) V.missing else null,
                .outputs = V.outputs,
                .fetch = V.fetch,
                .addRoot = V.addRoot,
                .outLinks = V.outLinks,
                .noteConnect = V.noteConnect,
                .noteUpload = V.noteUpload,
                .report = V.report,
                .close = V.close,
            };
        };
        return .{ .ptr = p, .vtable = &W.vtable };
    }

    pub fn queryValid(b: Backend, arena: Allocator, paths: []const StorePath, on_event: Sink, d: *Diag) Error!plan.NameSet {
        return b.vtable.queryValid(b.ptr, arena, paths, on_event, d);
    }
    pub fn substitute(b: Backend, paths: []const StorePath, on_event: Sink, d: *Diag) Error!void {
        return b.vtable.substitute(b.ptr, paths, on_event, d);
    }
    pub fn addObjects(b: Backend, objects: []const *Object, on_event: Sink, d: *Diag) Error!u64 {
        return b.vtable.addObjects(b.ptr, objects, on_event, d);
    }
    pub fn submit(b: Backend, arena: Allocator, batch: Batch, on_event: Sink, d: *Diag) Error!StatusMap {
        return b.vtable.submit(b.ptr, arena, batch, on_event, d);
    }
    pub fn missing(b: Backend, arena: Allocator, jobs: []const Job, on_event: Sink, d: *Diag) Error!worker.Missing {
        const f = b.vtable.missing orelse return d.fail(error.Usage, "--dry-run needs a worker-protocol builder", .{});
        return f(b.ptr, arena, jobs, on_event, d);
    }
    pub fn outputs(b: Backend, arena: Allocator, drv: []const u8, on_event: Sink, d: *Diag) Error![]const OutputEntry {
        return b.vtable.outputs(b.ptr, arena, drv, on_event, d);
    }
    pub fn fetch(b: Backend, store_path: []const u8, dir: []const u8, d: *Diag) Error!void {
        return b.vtable.fetch(b.ptr, store_path, dir, d);
    }
    pub fn addRoot(b: Backend, store_path: []const u8, link: []const u8, d: *Diag) Error!void {
        return b.vtable.addRoot(b.ptr, store_path, link, d);
    }
    pub fn outLinks(b: Backend, links: []const Link, d: *Diag) Error!void {
        return b.vtable.outLinks(b.ptr, links, d);
    }
    pub fn noteConnect(b: Backend, ns: u64) void {
        b.vtable.noteConnect(b.ptr, ns);
    }
    pub fn noteUpload(b: Backend, p: Phase) void {
        b.vtable.noteUpload(b.ptr, p);
    }
    pub fn report(b: Backend, w: *Writer, p: *const Plan, plan_time: u64) Writer.Error!void {
        return b.vtable.report(b.ptr, w, p, plan_time);
    }
    pub fn close(b: Backend) void {
        b.vtable.close(b.ptr);
    }
};

/// What a backend needs from its run: the allocator, the I/O, the
/// environment (socket paths, ssh) and the log the daemon's activities go to.
pub const Context = struct {
    gpa: Allocator,
    io: Io,
    env: ?*const std.process.Environ.Map = null,
    log: remote.Log = .none,
};

/// Connects the transport `t` names. `t`'s strings must outlive the backend.
pub fn open(cx: Context, t: *const worker.Transport, options: worker.Options, on_event: Sink, d: *Diag) Error!Backend {
    if (t.* == .grpc) {
        const g = try GrpcBackend.open(cx, t.grpc, d);
        return .of(GrpcBackend, g);
    }
    const w = try Worker.open(cx, t, options, on_event, d);
    return .of(Worker, w);
}

/// The `grpc://` client (remote/grpc/backend.zig) as a backend. Its calls
/// tag their events themselves; the ones with no build behind them emit
/// none.
pub const GrpcBackend = struct {
    g: *Grpc,

    fn open(cx: Context, cfg: grpc_config.Config, d: *Diag) Error!*GrpcBackend {
        const g = try Grpc.open(cx.gpa, cx.io, cfg, cx.env, cx.log, d);
        errdefer g.close();
        const b = try cx.gpa.create(GrpcBackend);
        b.* = .{ .g = g };
        return b;
    }

    pub fn queryValid(b: *GrpcBackend, arena: Allocator, paths: []const StorePath, _: Sink, d: *Diag) Error!plan.NameSet {
        return b.g.queryValid(arena, paths, d);
    }
    pub fn substitute(b: *GrpcBackend, paths: []const StorePath, _: Sink, d: *Diag) Error!void {
        return b.g.substitute(paths, d);
    }
    pub fn addObjects(b: *GrpcBackend, objects: []const *Object, _: Sink, d: *Diag) Error!u64 {
        return b.g.addObjects(objects, d);
    }
    pub fn submit(b: *GrpcBackend, arena: Allocator, batch: Batch, on_event: Sink, d: *Diag) Error!StatusMap {
        return b.g.submit(arena, batch, on_event, d);
    }
    pub fn outputs(b: *GrpcBackend, arena: Allocator, drv: []const u8, _: Sink, d: *Diag) Error![]const OutputEntry {
        return b.g.outputs(arena, drv, d);
    }
    pub fn fetch(b: *GrpcBackend, store_path: []const u8, dir: []const u8, d: *Diag) Error!void {
        return b.g.fetch(store_path, dir, d);
    }
    pub fn addRoot(b: *GrpcBackend, store_path: []const u8, link: []const u8, d: *Diag) Error!void {
        return b.g.addRoot(store_path, link, d);
    }
    pub fn outLinks(b: *GrpcBackend, links: []const Link, d: *Diag) Error!void {
        return b.g.outLinks(links, d);
    }
    pub fn noteConnect(b: *GrpcBackend, ns: u64) void {
        b.g.noteConnect(ns);
    }
    pub fn noteUpload(b: *GrpcBackend, p: Phase) void {
        b.g.noteUpload(p);
    }
    pub fn report(b: *GrpcBackend, w: *Writer, p: *const Plan, plan_time: u64) Writer.Error!void {
        return b.g.report(w, p, plan_time);
    }
    pub fn close(b: *GrpcBackend) void {
        const gpa = b.g.gpa;
        b.g.close();
        gpa.destroy(b);
    }
};

/// The worker protocol: one serial connection, one op per ready set.
pub const Worker = struct {
    cx: Context,
    conn: *worker.Connection,
    transport: *const worker.Transport,
    /// The transport's URI, for the copy activities.
    uri: []const u8,
    t: Timings,

    pub fn open(cx: Context, transport: *const worker.Transport, options: worker.Options, on_event: Sink, d: *Diag) Error!*Worker {
        const conn = try worker.Connection.openWith(cx.gpa, cx.io, transport, options, cx.env, cx.log, on_event, d);
        errdefer conn.close();
        const w = try cx.gpa.create(Worker);
        errdefer cx.gpa.destroy(w);
        var buf: Writer.Allocating = .init(cx.gpa);
        defer buf.deinit();
        transport.uri(&buf.writer, cx.env) catch return error.OutOfMemory;
        w.* = .{
            .cx = cx,
            .conn = conn,
            .transport = transport,
            .uri = try buf.toOwnedSlice(),
            .t = .{ .trusted = conn.trusted },
        };
        return w;
    }

    pub fn close(w: *Worker) void {
        w.conn.close();
        w.cx.gpa.free(w.uri);
        w.cx.gpa.destroy(w);
    }

    fn now(w: *const Worker) u64 {
        return @intCast(Io.Clock.awake.now(w.cx.io).toNanoseconds());
    }

    pub fn queryValid(w: *Worker, arena: Allocator, paths: []const StorePath, on_event: Sink, d: *Diag) Error!plan.NameSet {
        if (paths.len == 0) return .empty;
        w.t.query_paths += paths.len;
        const t0 = w.now();
        const valid = try w.conn.queryValid(arena, paths, on_event, d);
        w.t.query += w.now() - t0;
        var out: plan.NameSet = .empty;
        try out.ensureTotalCapacity(arena, @intCast(valid.len));
        for (valid) |*v| out.putAssumeCapacity(v.baseName(), {});
        return out;
    }

    pub fn substitute(w: *Worker, paths: []const StorePath, on_event: Sink, d: *Diag) Error!void {
        if (paths.len == 0) return;
        w.t.substitute_paths += paths.len;
        const t0 = w.now();
        var arena: std.heap.ArenaAllocator = .init(w.cx.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const targets = try a.alloc([]const u8, paths.len);
        for (paths, targets) |*p, *t| t.* = try std.fmt.allocPrint(a, "{f}", .{p});
        const results = try w.conn.buildPathsWithResults(a, targets, on_event, d);
        w.t.substitute += w.now() - t0;
        for (results) |r| if (!r.success())
            return d.fail(error.Store, "cannot substitute '{s}' on the builder: status {d}: {s}", .{ r.path, r.status, r.msg });
    }

    pub fn addObjects(w: *Worker, objects: []const *Object, on_event: Sink, d: *Diag) Error!u64 {
        if (objects.len == 0) return 0;
        const t0 = w.now();
        plan.prehashDrvs(w.cx.gpa, objects);
        const before = w.conn.bytesSent();
        var copying: copy.Copying = .init(w.cx.log, objects.len, "local", w.uri);
        defer copying.end();
        var up = try w.conn.addMultipleToStore(false, d);
        const out = up.writer();
        wire.writeU64(out, objects.len) catch |e| return up.fail(e, d);
        var pbuf: [512]u8 = undefined;
        for (objects) |o| {
            const act = copying.path(o.storePath().print(&pbuf));
            defer act.end();
            wire.writeObject(w.cx.gpa, w.cx.io, out, o, d) catch |e| return up.fail(e, d);
        }
        try up.finish(on_event, d);
        const bytes = w.conn.bytesSent() - before;
        w.t.add += w.now() - t0;
        w.t.add_paths += objects.len;
        w.t.add_bytes += bytes;
        return bytes;
    }

    pub fn submit(w: *Worker, arena: Allocator, batch: Batch, on_event: Sink, d: *Diag) Error!StatusMap {
        const targets = try arena.alloc([]const u8, batch.jobs.len);
        for (batch.jobs, targets) |j, *t| t.* = try j.derivedPath(arena);
        const t0 = w.now();
        const results = try w.conn.buildPathsWithResults(arena, targets, on_event, d);
        w.t.build += w.now() - t0;
        var out: StatusMap = .empty;
        for (results) |r| {
            const drv = if (std.mem.indexOfScalar(u8, r.path, '!')) |i| r.path[0..i] else r.path;
            const e = try out.getOrPut(arena, drv);
            if (!e.found_existing) e.value_ptr.* = .ok_status;
            if (!r.success()) {
                const exit = buildExit(r.status, r.msg);
                e.value_ptr.* = .failed(try std.fmt.allocPrint(arena, "status {d}: {s}", .{ r.status, r.msg }), exit);
            }
        }
        return out;
    }

    pub fn missing(w: *Worker, arena: Allocator, jobs: []const Job, on_event: Sink, d: *Diag) Error!worker.Missing {
        const paths = try arena.alloc([]const u8, jobs.len);
        for (jobs, paths) |j, *p| p.* = try j.derivedPath(arena);
        return w.conn.queryMissing(arena, paths, on_event, d);
    }

    pub fn outputs(w: *Worker, arena: Allocator, drv: []const u8, on_event: Sink, d: *Diag) Error![]const OutputEntry {
        const t0 = w.now();
        const map = try w.conn.queryDerivationOutputMap(arena, drv, on_event, d);
        w.t.outputs += w.now() - t0;
        return map;
    }

    pub fn fetch(w: *Worker, store_path: []const u8, dir: []const u8, d: *Diag) Error!void {
        const sp = StorePath.parse(store_path, d) catch return error.Store;
        const t0 = w.now();
        var buf: [4096]u8 = undefined;
        const what = std.fmt.bufPrint(&buf, "copying path '{s}' from '{s}'", .{ store_path, w.uri }) catch "copying path";
        const act = w.cx.log.activity(0, remote.lvl_info, remote.act_copy_path, what, &.{.{ .string = store_path }});
        defer act.end();
        const io = w.cx.io;
        const r = try w.conn.narReader(&sp, .ignore, d);
        var dh = Io.Dir.cwd().openDir(io, dir, .{}) catch |e| return w.conn.narFail(e, d);
        defer dh.close(io);
        nar.restorePath(io, r, dh, sp.baseName(), d) catch |e| return w.conn.narFail(e, d);
        w.t.fetch += w.now() - t0;
        w.t.fetched += 1;
    }

    pub fn addRoot(w: *Worker, store_path: []const u8, link: []const u8, d: *Diag) Error!void {
        return w.conn.addPermRoot(store_path, link, d);
    }

    pub fn outLinks(w: *Worker, links: []const Link, d: *Diag) Error!void {
        if (links.len == 0) return;
        const t0 = w.now();
        w.t.links += links.len;
        defer w.t.link += w.now() - t0;
        var arena: std.heap.ArenaAllocator = .init(w.cx.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const here = try local(a, w.cx.env);
        if (w.transport.* == .unix and std.mem.eql(u8, w.transport.unix, here.unix)) return addRoots(w.conn, links, d);
        // A symlink and its GC root are worth nothing without the path they
        // name, so the closure comes back to the local daemon first.
        const paths = try linkTargets(a, links, d);
        const conn = try worker.Connection.open(w.cx.gpa, w.cx.io, &here, w.cx.env, w.cx.log, .ignore, d);
        defer conn.close();
        w.t.link_copied += try copy.closure(w.cx.gpa, w.conn, w.uri, conn, paths, w.cx.log, .ignore, d);
        return addRoots(conn, links, d);
    }

    pub fn noteConnect(w: *Worker, ns: u64) void {
        w.t.connect = ns;
    }

    pub fn noteUpload(w: *Worker, p: Phase) void {
        w.t.noteUpload(p);
    }

    pub fn report(w: *Worker, out: *Writer, p: *const Plan, plan_time: u64) Writer.Error!void {
        return workerReport(out, &w.t, p, plan_time, w.conn.minor, w.conn.stats);
    }
};

fn workerReport(w: *Writer, t: *const Timings, p: *const Plan, plan_time: u64, minor: u64, s: worker.Stats) Writer.Error!void {
    var buf: [32]u8 = undefined;
    const protocol = std.fmt.bufPrint(&buf, "protocol 1.{d}", .{minor}) catch unreachable;
    try t.report(w, p, plan_time, protocol, "daemon", "");
    try w.print("\nworker: {d} ops, {d} round trips, {d} bytes sent", .{ s.ops, s.round_trips, s.bytes_sent });
}

const testing = std.testing;

fn testDrv(name: []const u8) !StorePath {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var buf: [128]u8 = undefined;
    return StorePath.parse(try std.fmt.bufPrint(&buf, "/nix/store/00000000000000000000000000000000-{s}.drv", .{name}), &d);
}

test "the timings report with every line" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var p: Plan = .init(testing.allocator);
    defer p.deinit();
    const t = everyTiming();
    try workerReport(&out.writer, &t, &p, 9 * std.time.ns_per_ms, 38, .{ .ops = 1, .round_trips = 2, .bytes_sent = 3 });
    try testing.expectEqualStrings(
        \\plan: 0 sources, 0 drvs, 0.009s
        \\connect: protocol 1.38, trusted, 0.001s
        \\query: 9 paths, 8 missing, 0.002s
        \\resolve: 7 sources, 6 not from this eval, read from /nix/store, 0.003s
        \\substitute: 5 paths left to the daemon, 0.004s
        \\add: 4 paths, 3 bytes, 0.005s
        \\build: 0.006s
        \\outputs: 0.007s
        \\fetch: 2 outputs, 0.008s
        \\link: 1 out-links, 3 paths copied, 0.010s
        \\worker: 1 ops, 2 round trips, 3 bytes sent
    , out.written());
}

test "output specs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("*", try (Job{ .drv = try testDrv("x") }).spec(a));
    try testing.expectEqualStrings("dev,out", try (Job{ .drv = try testDrv("x"), .outputs = &.{ "out", "dev", "out" } }).spec(a));
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(Worker);
    testing.refAllDecls(GrpcBackend);
    _ = Backend.of(Worker, undefined);
    _ = Backend.of(GrpcBackend, undefined);
}
