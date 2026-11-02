//! `grpc://` as one of the dispatcher's backends (`build.backend`).
//!
//! Where the worker protocol sends one `BuildPathsWithResults` per ready
//! set, this fans the set out. The store builds one derivation per
//! `BuildDerivation` call, so the client walks the batch's whole derivation
//! closure, dependencies first, up to `max-builds` in flight. Each
//! derivation goes to the scheduler first (`sched.zig`), which names the
//! worker or answers that the cache has it. Every call knows its derivation,
//! so its `log_line` and `phase` events carry the drv path and the renderer
//! keys its per-build buffers on them.
//!
//! Outputs land in the farm's binary cache, not in a local store, so an
//! out-link needs them registered locally first (docs/reference/builders.md).
//!
//! The dispatcher calls these methods through `build/backend.zig`'s
//! `GrpcBackend`, which wraps `Grpc` in the `Backend` interface.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const remote = @import("../../remote.zig");
const Error = remote.Error;
const path_mod = @import("../../store/path.zig");
const StorePath = path_mod.StorePath;
const drv_mod = @import("../../store/drv.zig");
const Derivation = drv_mod.Derivation;
const backend = @import("../../build/backend.zig");
const fanout = @import("../../build/fanout.zig");
const plan = @import("../plan.zig");
const Object = plan.Object;
const Plan = plan.Plan;
const event = @import("../event.zig");
const copy = @import("../copy.zig");
const worker = @import("../worker.zig");
const config = @import("config.zig");
const Client = @import("client.zig").Client;
const build = @import("build.zig");
const drvwire = @import("drvwire.zig");
const BuildResult = drvwire.BuildResult;
const Sched = @import("sched.zig").Sched;

pub const Grpc = struct {
    gpa: Allocator,
    io: Io,
    env: ?*const std.process.Environ.Map,
    c: *Client,
    t: build.Timings,
    /// Everything this run uploaded, so a `NOT_FOUND` retry can re-send one
    /// derivation's closure.
    objects: build.Objects,
    /// The derivations the submitted batches named, for their output paths.
    arena: std.heap.ArenaAllocator,
    drvs: build.DrvTable = .{ .paths = &.{}, .drvs = &.{} },

    pub fn open(gpa: Allocator, io: Io, cfg: config.Config, env: ?*const std.process.Environ.Map, log: remote.Log, d: *Diag) Error!*Grpc {
        const c = try Client.open(gpa, io, cfg, log, d);
        errdefer c.close();
        const g = try gpa.create(Grpc);
        g.* = .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .c = c,
            .t = .{ .common = .{ .trusted = c.info.trusted }, .calls = 1 },
            .objects = .init(gpa),
            .arena = .init(gpa),
        };
        return g;
    }

    pub fn close(g: *Grpc) void {
        g.objects.deinit();
        g.arena.deinit();
        g.c.close();
        g.gpa.destroy(g);
    }

    fn now(g: *const Grpc) u64 {
        return @intCast(Io.Clock.awake.now(g.io).toNanoseconds());
    }

    /// The subset of `paths` the store already has, by base name, in `arena`.
    pub fn queryValid(g: *Grpc, arena: Allocator, paths: []const StorePath, d: *Diag) Error!plan.NameSet {
        if (paths.len == 0) return .empty;
        const names = try arena.alloc([]const u8, paths.len);
        for (paths, names) |*p, *n| n.* = p.baseName();
        g.t.common.query_paths += names.len;
        const t0 = g.now();
        const valid = try build.queryValidPaths(g.c, arena, names, &g.t, d);
        g.t.common.query += g.now() - t0;
        return valid;
    }

    pub fn substitute(g: *Grpc, paths: []const StorePath, d: *Diag) Error!void {
        if (paths.len == 0) return;
        g.t.common.substitute_paths += paths.len;
        const t0 = g.now();
        var buf: [512]u8 = undefined;
        const what = std.fmt.bufPrint(&buf, "substituting {d} paths on '{f}'", .{ paths.len, &g.c.cfg }) catch "substituting";
        const act = g.c.log.activity(0, remote.lvl_talkative, remote.act_unknown, what, &.{});
        defer act.end();
        const r = build.substitute(g.c, paths, &g.t, d);
        g.t.common.substitute += g.now() - t0;
        return r;
    }

    /// Registers `objects` on the store; returns the bytes it cost. The
    /// objects' bytes must outlive the backend: a `NOT_FOUND` retry re-sends
    /// them.
    pub fn addObjects(g: *Grpc, objects: []const *Object, d: *Diag) Error!u64 {
        if (objects.len == 0) return 0;
        const t0 = g.now();
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{f}", .{&g.c.cfg}) catch g.c.cfg.authority;
        var copying: copy.Copying = .init(g.c.log, objects.len, "local", url);
        defer copying.end();
        const bytes = try build.addMultiple(g.c, objects, &g.t, d);
        g.t.common.add += g.now() - t0;
        g.t.common.add_paths += objects.len;
        g.t.common.add_bytes += bytes;
        try g.objects.extend(objects);
        return bytes;
    }

    /// Builds a ready set. Every job gets a verdict keyed by its derivation
    /// path, in `arena`.
    pub fn submit(g: *Grpc, arena: Allocator, batch: backend.Batch, on_event: event.Sink, d: *Diag) Error!std.StringArrayHashMapUnmanaged(backend.Status) {
        // The client walks the closure, so it needs all of it.
        const a = g.arena.allocator();
        const list = batch.drvs(batch.drvs_ctx, true, a, d) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => if (d.msg != null) error.Plan else remote.failIo(d, e, "the batch's derivations", .{}),
        };
        const table = try build.DrvTable.build(a, list, d);
        try g.drvs.extend(a, table);
        const t0 = g.now();
        const r = buildBatch(g, arena, batch, on_event, d);
        g.t.common.build += g.now() - t0;
        return r;
    }

    /// Output name to store path for a derivation that built, in `arena`.
    pub fn outputs(g: *Grpc, arena: Allocator, drv: []const u8, d: *Diag) Error![]const worker.Connection.OutputEntry {
        const t0 = g.now();
        const p = StorePath.parse(drv, d) catch return error.Store;
        const dv = g.drvs.get(p) orelse return d.fail(error.Plan, "'{s}' is not in the batch's closure", .{drv});
        const out = try arena.alloc(worker.Connection.OutputEntry, dv.outputs.len);
        for (dv.outputs, out) |o, *e| {
            const op = (dv.outputPath(o.name, d) catch return error.Store) orelse
                return d.fail(error.Plan, "'{s}': output '{s}' has no statically known path", .{ drv, o.name });
            e.* = .{ .name = o.name, .path = try std.fmt.allocPrint(arena, "{f}", .{&op}) };
        }
        g.t.common.outputs += g.now() - t0;
        return out;
    }

    /// Restores one output into `dir`, whose existence the caller checked.
    pub fn fetch(g: *Grpc, store_path: []const u8, dir: []const u8, d: *Diag) Error!void {
        const t0 = g.now();
        var buf: [1024]u8 = undefined;
        const what = std.fmt.bufPrint(&buf, "copying path '{s}' from '{f}'", .{ store_path, &g.c.cfg }) catch "copying path";
        const act = g.c.log.activity(0, remote.lvl_info, remote.act_copy_path, what, &.{.{ .string = store_path }});
        defer act.end();
        const paths = [_]StorePath{StorePath.parse(store_path, d) catch return error.Store};
        try build.fetchIntoDir(g.c, &paths, dir, &g.t, d);
        g.t.common.fetch += g.now() - t0;
        g.t.common.fetched += 1;
    }

    pub fn addRoot(g: *Grpc, store_path: []const u8, link: []const u8, d: *Diag) Error!void {
        return g.outLinks(&.{.{ .path = store_path, .link = link }}, d);
    }

    /// The store published the outputs to its cache, so they are copied
    /// into the local store before the symlink that names them.
    pub fn outLinks(g: *Grpc, links: []const backend.Link, d: *Diag) Error!void {
        if (links.len == 0) return;
        const t0 = g.now();
        g.t.common.links += links.len;
        var arena: std.heap.ArenaAllocator = .init(g.gpa);
        defer arena.deinit();
        const paths = try backend.linkTargets(arena.allocator(), links, d);
        const local = try backend.local(arena.allocator(), g.env);
        const conn = try worker.Connection.open(g.gpa, g.io, &local, g.env, g.c.log, .ignore, d);
        defer conn.close();
        g.t.common.link_copied += try build.register(g.c, paths, conn, .ignore, d);
        const r = backend.addRoots(conn, links, d);
        g.t.common.link += g.now() - t0;
        return r;
    }

    pub fn noteConnect(g: *Grpc, ns: u64) void {
        g.t.common.connect = ns;
    }

    pub fn noteUpload(g: *Grpc, p: backend.Phase) void {
        g.t.common.noteUpload(p);
    }

    /// `--timings`: one line per phase, in the flow's order.
    pub fn report(g: *const Grpc, w: *Writer, p: *const Plan, plan_time: u64) Writer.Error!void {
        return g.t.report(w, p, plan_time);
    }
};

/// A `Want` and a `BuildDerivation` per derivation of the batch's closure,
/// at most `max-builds` in flight, a derivation only once its inputs are
/// done. Derivations whose outputs the store already reports valid are
/// skipped. The C++ plugin sends them anyway and lets the niks3 claim answer
/// `AlreadyValid`, which costs one RPC per derivation; one extra
/// `QueryValidPaths` over the output paths is cheaper and asks the same store.
fn buildBatch(g: *Grpc, arena: Allocator, batch: backend.Batch, on_event: event.Sink, d: *Diag) Error!std.StringArrayHashMapUnmanaged(backend.Status) {
    const c = g.c;
    const drvs = &g.drvs;
    var out: std.StringArrayHashMapUnmanaged(backend.Status) = .empty;
    for (batch.jobs) |j| try out.put(arena, try std.fmt.allocPrint(arena, "{f}", .{&j.drv}), .ok_status);
    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(g.gpa);
    for (batch.jobs) |j| {
        const i = drvs.index.get(j.drv) orelse return d.fail(error.Plan, "'{f}' is not in the batch's closure", .{&j.drv});
        try roots.append(g.gpa, @intCast(i));
    }
    var scratch: std.heap.ArenaAllocator = .init(g.gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var needs = try missingDrvs(g.gpa, sa, drvs, roots.items, ClientQuery{ .g = g }, d);
    defer needs.deinit(g.gpa);

    var jobs: std.ArrayList(build.Job) = .empty;
    const index = try sa.alloc(?usize, drvs.drvs.len);
    @memset(index, null);
    const OutputOf = struct {
        fn f(ctx: ?*const anyopaque, dep: *const StorePath, output: []const u8) ?StorePath {
            return build.outputPath(@ptrCast(@alignCast(ctx.?)), dep, output);
        }
    };
    for (drvs.paths, drvs.drvs, 0..) |*p, *dv, i| {
        if (!needs.contains(@intCast(i))) continue;
        const srcs = try drvwire.basicInputSrcs(sa, p, dv, .{ .ctx = drvs, .f = OutputOf.f }, d);
        index[i] = jobs.items.len;
        try jobs.append(sa, try build.Job.init(sa, p.*, dv, srcs));
    }
    g.t.drvs += jobs.items.len;
    g.t.drvs_cached += drvs.drvs.len - jobs.items.len;
    if (jobs.items.len == 0) return out;
    const graph = try sa.alloc(fanout.Job, jobs.items.len);
    for (jobs.items, graph) |j, *n| {
        var deps: std.ArrayList(usize) = .empty;
        for (j.drv.input_drvs) |in| if (drvs.index.get(in.path)) |di| if (index[di]) |ji| try deps.append(sa, ji);
        n.* = .{ .deps = deps.items };
    }

    const sched = Sched.open(g.gpa, c) catch return error.OutOfMemory;
    defer sched.close();
    // no daemon to report, so the activities of build/worker.cc come from here
    const realise = c.log.activity(0, remote.lvl_error, remote.act_realise, "", &.{});
    defer realise.end();
    const builds = c.log.activity(0, remote.lvl_error, remote.act_builds, "", &.{});
    defer builds.end();
    const substitutions = c.log.activity(0, remote.lvl_error, remote.act_copy_paths, "", &.{});
    defer substitutions.end();

    // one arena per job: a job runs on one thread at a time, and its result
    // lives until the verdicts are read
    const arenas = try sa.alloc(std.heap.ArenaAllocator, jobs.items.len);
    for (arenas) |*x| x.* = .init(g.gpa);
    defer for (arenas) |*x| x.deinit();
    var url_buf: [512]u8 = undefined;
    const Run = struct {
        c: *Client,
        sched: *Sched,
        jobs: []const build.Job,
        objects: *const build.Objects,
        arenas: []std.heap.ArenaAllocator,
        builds: remote.Activity,
        url: []const u8,
        lock: Io.Mutex = .init,
        counts: [4]u64,
        calls: std.atomic.Value(usize) = .init(0),

        fn progress(r: *@This(), comptime f: fn (*[4]u64) void) void {
            r.lock.lockUncancelable(r.c.io);
            defer r.lock.unlock(r.c.io);
            f(&r.counts);
            r.builds.result(remote.res_progress, &.{ .{ .int = r.counts[0] }, .{ .int = r.counts[1] }, .{ .int = r.counts[2] }, .{ .int = r.counts[3] } });
        }

        fn buildOne(ctx: ?*anyopaque, i: usize, sink: event.Sink) BuildResult {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            const job = &r.jobs[i];
            const a = r.arenas[i].allocator();
            const drv = std.fmt.allocPrint(a, "{f}", .{&job.drv_path}) catch "";
            const text = std.fmt.allocPrint(a, "building '{s}' on '{s}'", .{ drv, r.url }) catch "building";
            const act = r.c.log.activity(0, remote.lvl_info, remote.act_build, text, &.{ .{ .string = drv }, .{ .string = r.url }, .{ .int = 1 }, .{ .int = 1 } });
            defer act.end();
            r.progress(struct {
                fn f(n: *[4]u64) void {
                    n[2] += 1;
                }
            }.f);
            sink.send(.{ .started = .{ .drv_path = drv } });
            var bd: Diag = .init(r.c.gpa);
            defer bd.deinit();
            const res: BuildResult = if (build.build(r.c, a, r.sched, job, r.objects, sink, act, &bd)) |b| blk: {
                _ = r.calls.fetchAdd(b.calls, .monotonic);
                break :blk b.res;
            } else |_|
                // 9 = MiscFailure. nix reports only the top level result, so
                // name the leaf that broke.
                .{ .status = 9, .error_msg = a.dupe(u8, bd.message()) catch "" };
            if (res.success()) r.progress(struct {
                fn f(n: *[4]u64) void {
                    n[2] -= 1;
                    n[0] += 1;
                }
            }.f) else r.progress(struct {
                fn f(n: *[4]u64) void {
                    n[2] -= 1;
                    n[3] += 1;
                }
            }.f);
            sink.send(.{ .stopped = .{ .drv_path = drv, .built = res.success() } });
            return res;
        }

        fn ok(res: *const BuildResult) bool {
            return res.success();
        }

        fn blocked(ctx: ?*anyopaque, i: usize, dep: usize) BuildResult {
            const r: *@This() = @ptrCast(@alignCast(ctx.?));
            const a = r.arenas[i].allocator();
            // 10 = DependencyFailed.
            return .{ .status = 10, .error_msg = std.fmt.allocPrint(a, "dependency '{f}' failed", .{&r.jobs[dep].drv_path}) catch "" };
        }
    };
    var run: Run = .{
        .c = c,
        .sched = sched,
        .jobs = jobs.items,
        .objects = &g.objects,
        .arenas = arenas,
        .builds = builds,
        .url = std.fmt.bufPrint(&url_buf, "{f}", .{&c.cfg}) catch c.cfg.authority,
        .counts = .{ 0, jobs.items.len, 0, 0 },
    };
    const results = try fanout.run(BuildResult, g.gpa, g.io, graph, c.cfg.max_builds, .{
        .ctx = &run,
        .build = Run.buildOne,
        .ok = Run.ok,
        .blocked = Run.blocked,
    }, on_event);
    defer g.gpa.free(results);
    g.t.calls += run.calls.load(.monotonic);

    for (results, jobs.items) |res, *j| {
        const drv = try std.fmt.allocPrint(arena, "{f}", .{&j.drv_path});
        var reason: []const u8 = undefined;
        var exit: i32 = 1;
        if (res) |r| {
            if (r.success()) continue;
            reason = try std.fmt.allocPrint(arena, "status {d}: {s}", .{ r.status, r.error_msg });
            exit = backend.buildExit(r.status, r.error_msg);
        } else reason = "the farm never reached this derivation";
        if (out.getPtr(drv)) |slot| {
            slot.* = .failed(reason, exit);
        } else {
            // A dependency, not something the caller asked for: the
            // renderer still wants its verdict.
            on_event.send(worker.failedEvent(drv, reason));
        }
    }
    return out;
}

/// The store asked through the backend's client.
const ClientQuery = struct {
    g: *Grpc,
    pub fn call(q: ClientQuery, paths: []const StorePath, valid: *plan.NameSet, arena: Allocator, d: *Diag) !void {
        const names = try arena.alloc([]const u8, paths.len);
        for (paths, names) |*p, *n| n.* = try arena.dupe(u8, p.baseName());
        const got = try build.queryValidPaths(q.g.c, arena, names, &q.g.t, d);
        var it = got.keyIterator();
        while (it.next()) |k| try valid.put(arena, k.*, {});
    }
};

/// The derivations of the roots' closure whose outputs the store lacks
/// (`plan.missingTopDown`): nothing below a derivation the store has built
/// is asked about or built. Nodes are indices into `drvs`.
fn missingDrvs(gpa: Allocator, arena: Allocator, drvs: *const build.DrvTable, roots: []const u32, store: anytype, d: *Diag) !plan.NodeSet {
    const G = struct {
        drvs: *const build.DrvTable,
        q: @TypeOf(store),
        arena: Allocator,
        d: *Diag,
        pub fn keys(s: @This(), a: Allocator, n: u32, out: *std.ArrayList(StorePath), dd: *Diag) !void {
            const p = &s.drvs.paths[n];
            const drv = &s.drvs.drvs[n];
            for (drv.outputs) |o| {
                const op = (drv.outputPath(o.name, dd) catch return error.Store) orelse
                    return dd.fail(error.Plan, "'{f}': output '{s}' has no statically known path; the build " ++
                        "farm needs statically known input and output paths", .{ p, o.name });
                try out.append(a, op);
            }
        }
        pub fn children(s: @This(), a: Allocator, n: u32, out: *std.ArrayList(u32)) !void {
            for (s.drvs.drvs[n].input_drvs) |in| if (s.drvs.index.get(in.path)) |i| try out.append(a, @intCast(i));
        }
        pub fn query(s: @This(), paths: []const StorePath, valid: *plan.NameSet, a: Allocator) !void {
            try s.q.call(paths, valid, a, s.d);
        }
    };
    return plan.missingTopDown(gpa, roots, G{ .drvs = drvs, .q = store, .arena = arena, .d = d }, null, d);
}

// Tests

const testing = std.testing;

fn sp(buf: *[256]u8, name: []const u8) StorePath {
    const nix32 = "0123456789abcdfghijklmnpqrsvwxyz";
    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*h, i| h.* = nix32[name[i % name.len] % 32];
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const s = std.fmt.bufPrint(buf, "/nix/store/{s}-{s}", .{ &hash, name }) catch unreachable;
    return StorePath.parse(s, &d) catch unreachable;
}

const Edge = struct { []const u8, []const []const u8 };

/// Each `(name, inputs)` is `name.drv` with one output `name-out`.
fn testGraph(arena: Allocator, edges: []const Edge) !build.DrvTable {
    var list: std.ArrayList(backend.Drv) = .empty;
    var buf: [256]u8 = undefined;
    for (edges) |e| {
        var aterm: std.ArrayList(u8) = .empty;
        const out = sp(&buf, try std.fmt.allocPrint(arena, "{s}-out", .{e[0]}));
        try aterm.print(arena, "Derive([(\"out\",\"{f}\",\"\",\"\")],[", .{&out});
        for (e[1], 0..) |in, i| {
            if (i > 0) try aterm.append(arena, ',');
            const ip = sp(&buf, try std.fmt.allocPrint(arena, "{s}.drv", .{in}));
            try aterm.print(arena, "(\"{f}\",[\"out\"])", .{&ip});
        }
        try aterm.appendSlice(arena, "],[],\"x\",\"y\",[],[])");
        try list.append(arena, .{ .path = sp(&buf, try std.fmt.allocPrint(arena, "{s}.drv", .{e[0]})), .aterm = aterm.items });
    }
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return build.DrvTable.build(arena, list.items, &d);
}

const Recorder = struct {
    valid: []const []const u8,
    calls: *std.ArrayList([]const u8),
    /// The recorded calls outlive the walk's arena.
    keep: Allocator,
    pub fn call(r: Recorder, paths: []const StorePath, valid: *plan.NameSet, arena: Allocator, _: *Diag) !void {
        var asked: std.ArrayList([]const u8) = .empty;
        for (paths) |*p| {
            const n = p.name();
            try asked.append(arena, n[0 .. n.len - 4]);
            for (r.valid) |v| if (std.mem.eql(u8, n[0 .. n.len - 4], v)) try valid.put(arena, try arena.dupe(u8, p.baseName()), {});
        }
        std.mem.sort([]const u8, asked.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        try r.calls.append(r.keep, try std.mem.join(r.keep, " ", asked.items));
    }
};

fn expectMissing(edges: []const Edge, valid: []const []const u8, want_needs: []const u8, want_calls: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = try testGraph(a, edges);
    var buf: [256]u8 = undefined;
    const root = t.index.get(sp(&buf, "root.drv")).?;
    var calls: std.ArrayList([]const u8) = .empty;
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var needs = try missingDrvs(testing.allocator, a, &t, &.{@intCast(root)}, Recorder{ .valid = valid, .calls = &calls, .keep = a }, &d);
    defer needs.deinit(testing.allocator);
    var names: std.ArrayList([]const u8) = .empty;
    var it = needs.keyIterator();
    while (it.next()) |n| try names.append(a, t.drvs[n.*].name);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try testing.expectEqualStrings(want_needs, try std.mem.join(a, " ", names.items));
    try testing.expectEqual(want_calls.len, calls.items.len);
    for (want_calls, calls.items) |w, g| try testing.expectEqualStrings(w, g);
}

const chain = [_]Edge{
    .{ "root", &.{"a"} },
    .{ "a", &.{"b"} },
    .{ "b", &.{"c"} },
    .{ "c", &.{"d"} },
    .{ "d", &.{} },
};

test "a built root asks nothing below it" {
    try expectMissing(&chain, &.{ "root", "a", "b", "c", "d" }, "", &.{"root"});
}

test "a built input stops the walk" {
    try expectMissing(&chain, &.{ "a", "b", "c", "d" }, "root", &.{ "root", "a" });
}

test "a cold store is asked the rest in one call" {
    try expectMissing(&chain, &.{}, "a b c d root", &.{ "root", "a", "b c d" });
}

test "an input below a built one is not built" {
    try expectMissing(&chain, &.{"c"}, "a b root", &.{ "root", "a", "b c d" });
}
