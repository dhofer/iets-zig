//! The `grpc://` protocol calls, the counterpart of the worker backend: one
//! `QueryValidPaths`, one `AddMultipleToStore` of what the store lacks, the
//! builds, and `FetchNars` for the outputs. Each build is a `Want` on the
//! `Schedule` stream, then `BuildDerivation` on the worker that the scheduler
//! assigned. `backend.zig` drives these calls as the dispatcher's backend.

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
const nar = @import("../../store/nar.zig");
const backend = @import("../../build/backend.zig");
const plan = @import("../plan.zig");
const Object = plan.Object;
const Plan = plan.Plan;
const event = @import("../event.zig");
const copy = @import("../copy.zig");
const worker = @import("../worker.zig");
const wire = worker.wire;
const zstd = @import("../zstd.zig");
const proto = @import("proto.zig");
const config = @import("config.zig");
const Status = config.Status;
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const drvwire = @import("drvwire.zig");
const BuildResult = drvwire.BuildResult;
const PathInfo = drvwire.PathInfo;
const sched_mod = @import("sched.zig");
const Sched = sched_mod.Sched;

/// The shared timings, and what only this transport counts.
pub const Timings = struct {
    common: backend.Timings = .{},
    drvs: usize = 0,
    drvs_cached: usize = 0,
    calls: usize = 0,

    pub fn report(t: *const Timings, w: *Writer, p: *const Plan, plan_time: u64) Writer.Error!void {
        var buf: [128]u8 = undefined;
        const built = std.fmt.bufPrint(&buf, "{d} drvs, {d} already valid, ", .{ t.drvs, t.drvs_cached }) catch unreachable;
        try t.common.report(w, p, plan_time, "gRPC", "store", built);
        try w.print("\ngrpc: {d} calls", .{t.calls});
    }
};

fn baseNames(arena: Allocator, paths: []const StorePath) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, out) |*p, *n| n.* = p.baseName();
    return out;
}

/// The sources the client cannot produce (an input-addressed build output
/// pinned with `builtins.storePath`): the store fetches them instead. A
/// worker substitutes an input when the build asks for it (daemon/main.cc:
/// `gatherInputs`), so here we only check that some substituter has them,
/// which is what `QueryValidPaths` with `substitute` answers.
pub fn substitute(c: *Client, paths: []const StorePath, t: *Timings, d: *Diag) Error!void {
    if (paths.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const known = try query(c, arena.allocator(), try baseNames(arena.allocator(), paths), true, t, d);
    for (paths) |*p| if (!known.contains(p.baseName()))
        return d.fail(error.Store, "'{f}' is not in the local store and no substituter of '{s}' has it", .{ p, c.cfg.authority });
}

/// Derivations parsed from their ATerms, by path: every derivation of the
/// batch's closure, since the client walks it. Lives in `arena`.
pub const DrvTable = struct {
    paths: []StorePath,
    drvs: []Derivation,
    index: plan.PathMap(usize) = .empty,

    pub fn get(t: *const DrvTable, p: StorePath) ?*const Derivation {
        const i = t.index.get(p) orelse return null;
        return &t.drvs[i];
    }

    pub fn build(arena: Allocator, list: []const backend.Drv, d: *Diag) Error!DrvTable {
        const sorted = try arena.dupe(backend.Drv, list);
        std.mem.sort(backend.Drv, sorted, {}, struct {
            fn lt(_: void, x: backend.Drv, y: backend.Drv) bool {
                return x.path.order(&y.path) == .lt;
            }
        }.lt);
        var t: DrvTable = .{ .paths = try arena.alloc(StorePath, sorted.len), .drvs = try arena.alloc(Derivation, sorted.len) };
        var n: usize = 0;
        for (sorted) |e| {
            if ((try t.index.fetchPut(arena, e.path, n)) != null) continue;
            const name = Derivation.nameFromPath(&e.path, d) catch return error.Store;
            t.drvs[n] = Derivation.parse(arena, e.aterm, name, d) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Store,
            };
            t.paths[n] = e.path;
            n += 1;
        }
        t.paths = t.paths[0..n];
        t.drvs = t.drvs[0..n];
        return t;
    }

    /// Adds what `other` has and this table lacks.
    pub fn extend(t: *DrvTable, arena: Allocator, other: DrvTable) Allocator.Error!void {
        var paths: std.ArrayList(StorePath) = .fromOwnedSlice(t.paths);
        var drvs: std.ArrayList(Derivation) = .fromOwnedSlice(t.drvs);
        for (other.paths, other.drvs) |p, dv| if (!t.index.contains(p)) {
            try t.index.put(arena, p, paths.items.len);
            try paths.append(arena, p);
            try drvs.append(arena, dv);
        };
        t.paths = paths.items;
        t.drvs = drvs.items;
    }
};

/// The store path of `drv_path!output`, statically.
pub fn outputPath(drvs: *const DrvTable, drv_path: *const StorePath, output: []const u8) ?StorePath {
    const drv = drvs.get(drv_path.*) orelse return null;
    var d: Diag = .init(std.heap.page_allocator);
    defer d.deinit();
    return drv.outputPath(output, &d) catch null;
}

/// `QueryValidPaths` on store path base names, in one call. The names live
/// in `arena`.
pub fn queryValidPaths(c: *Client, arena: Allocator, names: []const []const u8, t: *Timings, d: *Diag) Error!plan.NameSet {
    if (names.len == 0) return .empty;
    return query(c, arena, names, false, t, d);
}

fn query(c: *Client, arena: Allocator, names: []const []const u8, subst: bool, t: *Timings, d: *Diag) Error!plan.NameSet {
    t.calls += 1;
    const reply = try c.call(proto.QueryValidPathsReply, arena, "QueryValidPaths", proto.QueryValidPathsRequest{ .paths = names, .substitute = subst }, d);
    var out: plan.NameSet = .empty;
    for (reply.paths) |p| try out.put(arena, p, {});
    return out;
}

/// `QueryPathInfos`: the 1.16 `UnkeyedValidPathInfo` of each path the store
/// has, signatures included. The worker substitutes a path it lacks from the
/// cache first, so this also answers for cached outputs.
fn queryPathInfos(c: *Client, arena: Allocator, paths: []const StorePath, t: *Timings, d: *Diag) Error!copy.Infos {
    var out: copy.Infos = .empty;
    if (paths.len == 0) return out;
    t.calls += 1;
    const reply = try c.call(proto.QueryPathInfosReply, arena, "QueryPathInfos", proto.QueryPathInfosRequest{ .paths = try baseNames(arena, paths) }, d);
    for (reply.infos) |entry| {
        const info = try PathInfo.decode(arena, entry.path, entry.info, d);
        try out.put(arena, info.path, info);
    }
    return out;
}

/// pump.hh:`kChunkSize`.
const chunk = 256 << 10;

/// Ships `AddMultipleChunk`s on the call, one message per `chunk` of
/// compressed bytes (pump.hh:`ZstdWriterSink`). The chunk is the writer's
/// buffer.
const ChunkShip = struct {
    call: *client_mod.Call,
    sent: u64 = 0,
    /// The writer's buffer, after room for a message's prefix and head.
    buf: []u8,
    interface: Writer,

    const head_room = client_mod.prefix_len + proto.max_len_head;

    fn init(call: *client_mod.Call, buf: []u8) ChunkShip {
        return .{ .call = call, .buf = buf, .interface = .{ .buffer = buf[head_room..], .vtable = &.{ .drain = drain, .flush = flush } } };
    }

    /// `AddMultipleChunk{ .data = buffered }`: its prefix and head go into
    /// the room in front of the bytes, which go out uncopied.
    fn ship(s: *ChunkShip) Writer.Error!void {
        const n = s.interface.end;
        if (n == 0) return;
        s.sent += n;
        var head: [proto.max_len_head]u8 = undefined;
        const h = proto.putLen(&head, proto.AddMultipleChunk.tags.data, n);
        const msg = s.buf[head_room - h - client_mod.prefix_len .. head_room + n];
        client_mod.putPrefix(msg[0..client_mod.prefix_len], h + n);
        @memcpy(msg[client_mod.prefix_len..][0..h], head[0..h]);
        s.call.sendFramed(msg) catch return error.WriteFailed;
        s.interface.end = 0;
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const s: *ChunkShip = @fieldParentPtr("interface", w);
        try s.ship();
        return w.writeSplat(data, splat);
    }

    fn flush(w: *Writer) Writer.Error!void {
        const s: *ChunkShip = @fieldParentPtr("interface", w);
        try s.ship();
    }
};

/// `AddMultipleToStore`: one zstd stream of the worker-protocol framing (a
/// count, then each `ValidPathInfo` at 1.16 followed by its NAR), from the
/// same `writeObject` the worker transport uses. Like the C++ sink, the
/// stream is flushed once, at the end; the reader decodes a partial frame
/// fine. `check_sigs` is false because every path sent is content-addressed,
/// so the daemon recomputes its address. For a `write` token the server
/// forces `CheckSigs` on anyway (daemon/main.cc), which those paths still
/// pass. Returns the compressed bytes sent.
pub fn addMultiple(c: *Client, objects: []const *Object, t: *Timings, d: *Diag) Error!u64 {
    const deadline = nowNs(c.io) + @as(i96, c.cfg.connect_timeout) * std.time.ns_per_s;
    var pause: i96 = 500 * std.time.ns_per_ms;
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        t.calls += 1;
        const headers = try c.headers(arena.allocator(), d);
        var status: Status = undefined;
        if (upload(c, arena.allocator(), objects, headers.items, &status, d)) |n| return n else |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Status => {
                if (!config.goneAway(status) or nowNs(c.io) + pause > deadline) return c.statusError(status, "AddMultipleToStore", d);
                c.log.errln("{s}: {s}, retrying", .{ c.cfg.authority, config.firstLine(status.message) });
                client_mod.sleepNs(c.io, pause);
                pause = @min(pause * 2, 4 * std.time.ns_per_s);
            },
        }
    }
}

/// One `AddMultipleToStore` attempt. The server status explains a stream the
/// server broke better than the local write error does
/// (transfer.cc:addMultipleToStoreOnce). A stream this side broke, a source
/// that no longer dumps as evaluated, reaches the server only as its end, so
/// the local error wins then, as an `INTERNAL` status.
fn upload(c: *Client, arena: Allocator, objects: []const *Object, headers: []const client_mod.Header, status: *Status, d: *Diag) error{ Status, OutOfMemory }!u64 {
    var k = try c.start(arena, "/nix.remote.NixRemote/AddMultipleToStore", headers, status);
    defer k.deinit();
    plan.prehashDrvs(c.gpa, objects);
    // store.cc sends the flags alone first; the zstd stream follows in its
    // own messages.
    try k.send(proto.AddMultipleChunk{});
    const buf = try c.gpa.alloc(u8, ChunkShip.head_room + chunk + (1 << 16));
    defer c.gpa.free(buf);
    var ship: ChunkShip = .init(&k, buf);
    var local: Diag = .init(c.gpa);
    defer local.deinit();
    const written = writeStream(c, &ship.interface, objects, &local);
    if (written) |_| {
        k.closeSend() catch {};
    } else |e| if (e != error.WriteFailed) {
        // our side broke the stream: its reason, not the server's
        k.conn.cancel(k.s);
        status.* = .{ .code = .internal, .message = try arena.dupe(u8, local.msg orelse @errorName(e)) };
        return error.Status;
    }
    const reply = k.recv(proto.AddMultipleReply, arena) catch |e| return e;
    const s = try k.finish(arena);
    if (s.code != .ok) {
        status.* = s;
        return error.Status;
    }
    if (written) |_| {} else |_| {
        status.* = .{ .code = .unavailable, .message = "gRPC stream closed by peer" };
        return error.Status;
    }
    _ = reply;
    _ = d;
    return ship.sent;
}

fn writeStream(c: *Client, out: *Writer, objects: []const *Object, d: *Diag) !void {
    var z = try zstd.Compressor.init(c.gpa, out, .{});
    defer z.deinit();
    const w = &z.writer;
    try wire.writeU64(w, objects.len);
    for (objects) |o| try wire.writeObject(c.gpa, c.io, w, o, d);
    try z.finish();
    try out.flush();
}

/// One derivation the farm must build, in the shape `BuildDerivation` wants.
pub const Job = struct {
    drv_path: StorePath,
    drv: *const Derivation,
    input_srcs: []const StorePath,
    /// The features the balancer routes on.
    features: []const []const u8,

    pub fn init(arena: Allocator, drv_path: StorePath, drv: *const Derivation, input_srcs: []const StorePath) Allocator.Error!Job {
        return .{ .drv_path = drv_path, .drv = drv, .input_srcs = input_srcs, .features = try requiredSystemFeatures(arena, drv) };
    }

    /// build.cc:`fillWant`. `drv_path` is the base name, as C++
    /// `StorePath::to_string` prints it.
    fn want(j: *const Job, arena: Allocator) Allocator.Error!proto.Want {
        var keys: std.ArrayList([]const u8) = .empty;
        var d: Diag = .init(arena);
        for (j.drv.outputs) |o| {
            const p = (j.drv.outputPath(o.name, &d) catch null) orelse continue;
            try keys.append(arena, try std.fmt.allocPrint(arena, "{s}.narinfo", .{p.hashPart()}));
        }
        const inputs = try arena.alloc([]const u8, j.input_srcs.len);
        for (j.input_srcs, inputs) |*p, *s| s.* = try std.fmt.allocPrint(arena, "{f}", .{p});
        return .{
            .drv_path = j.drv_path.baseName(),
            .out_keys = keys.items,
            .inputs = inputs,
            .required_features = j.features,
            .system = j.drv.platform,
        };
    }
};

/// nix-compat.hh:`requiredSystemFeatures`, which the balancer routes on: the
/// `requiredSystemFeatures` environment variable, space separated, or the
/// same key of `__json` when the derivation has structured attributes;
/// sorted and unique.
fn requiredSystemFeatures(arena: Allocator, drv: *const Derivation) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (drv.structured_attrs) |json| {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{})) |v| {
            if (v == .object) if (v.object.get("requiredSystemFeatures")) |list| if (list == .array) {
                for (list.array.items) |f| if (f == .string) try out.append(arena, f.string);
            };
        } else |_| {}
    } else {
        var it = std.mem.tokenizeAny(u8, drv.envGet("requiredSystemFeatures") orelse "", " \t\n\r\x0b\x0c");
        while (it.next()) |f| try out.append(arena, f);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var n: usize = 0;
    for (out.items) |f| {
        if (n > 0 and std.mem.eql(u8, out.items[n - 1], f)) continue;
        out.items[n] = f;
        n += 1;
    }
    return out.items[0..n];
}

pub const Built = struct { res: BuildResult, calls: usize };

/// One derivation through the scheduler (build.cc:`Run::resultFor`): a
/// `Want`, then `BuildDerivation` on the worker it names. A worker that
/// bounces the build sends it back to the scheduler, up to
/// `reschedule-retries` times. Returns the result and the RPCs it cost; the
/// result's strings live in `arena`.
pub fn build(c: *Client, arena: Allocator, sched: *Sched, job: *const Job, objects: *const Objects, sink: event.Sink, act: remote.Activity, d: *Diag) Error!Built {
    var calls: usize = 0;
    var bounces: u32 = 0;
    // A refusal costs no call, so spending `reschedule-retries` on it would
    // fail the derivation with nothing attempted. Bounded like `Unplaceable`.
    const refuse_by = nowNs(c.io) + sched.grace();
    while (true) {
        const answer = try sched.place(arena, try job.want(arena), d);
        const worker_addr, const assign_id = switch (answer) {
            // 2 = AlreadyValid.
            .cached => return .{ .res = .{ .status = 2 }, .calls = calls },
            .assigned => |x| .{ x.worker, x.assign_id },
        };
        if (sched.health.refusal(worker_addr)) |wait| {
            const left = refuse_by - nowNs(c.io);
            if (left <= 0)
                return d.fail(error.Store, "'{f}': waited {d}s, and every worker the scheduler assigned turns builds away (last '{s}')", .{
                    &job.drv_path, @divTrunc(sched.grace(), std.time.ns_per_s), worker_addr,
                });
            client_mod.sleepNs(c.io, @min(wait, left));
            continue;
        }
        if (try buildDerivation(c, arena, job, worker_addr, assign_id, objects, sink, act, &calls, d)) |res| {
            sched.health.worked(worker_addr);
            return .{ .res = res, .calls = calls };
        }
        sched.health.bounced(worker_addr);
        bounces += 1;
        if (bounces > c.cfg.reschedule_retries)
            return d.fail(error.Store, "'{f}': gave up after {d} reschedules", .{ &job.drv_path, c.cfg.reschedule_retries });
        client_mod.sleepNs(c.io, @as(i96, reschedulePause(bounces)) * std.time.ns_per_s);
    }
}

/// After the `n`th bounce, in seconds: 1 doubling to 30, 121 s over the
/// default 8 reschedules. build.cc asks again at once, but a worker that
/// crashed stays placeable until the scheduler notices (42 s seen), and every
/// bounce off it is instant, so back-to-back asks spent the budget first.
/// This is one derivation's own backstop; `health` is what stops the whole
/// batch walking this ladder against the same address.
pub fn reschedulePause(n: u32) u64 {
    return @min(@as(u64, 1) << @intCast(@min(n -| 1, 5)), 30);
}

/// build.cc:`buildAssigned`: `NOT_FOUND` means the worker lacks the `.drv`
/// closure, so upload it and ask once more. Null when the worker bounced the
/// build and the scheduler must place it again.
fn buildDerivation(c: *Client, arena: Allocator, job: *const Job, worker_addr: []const u8, assign_id: u64, objects: *const Objects, sink: event.Sink, act: remote.Activity, calls: *usize, d: *Diag) Error!?BuildResult {
    var drv_bytes: Writer.Allocating = .init(arena);
    drvwire.writeBasicDerivation(&drv_bytes.writer, job.drv, job.input_srcs, d) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        error.Store => error.Store,
    };
    const req: proto.BuildDerivationRequest = .{
        // `StorePath::to_string()` on the C++ side: the base name.
        .drv_path = job.drv_path.baseName(),
        .drv = drv_bytes.written(),
        .build_mode = 0,
        .protocol = drvwire.build_protocol,
        .assign_id = assign_id,
    };
    // build.cc:routingFor.
    var headers = try c.headers(arena, d);
    var kept: usize = 0;
    for (headers.items) |h| if (!std.mem.eql(u8, h.name, "x-nix-system")) {
        headers.items[kept] = h;
        kept += 1;
    };
    headers.items.len = kept;
    try headers.append(arena, .{ .name = "x-nix-system", .value = job.drv.platform });
    try headers.append(arena, .{ .name = "x-nix-features", .value = try std.mem.join(arena, ",", job.features) });
    try headers.append(arena, .{ .name = "x-nix-worker", .value = worker_addr });

    calls.* += 1;
    var status: Status = undefined;
    var r = tryBuildDerivation(c, arena, &req, headers.items, &job.drv_path, sink, act, &status);
    if (r) |_| {} else |e| if (e == error.Status and status.code == .not_found) {
        calls.* += try uploadClosure(c, arena, objects, &job.drv_path, headers.items, d) + 1;
        r = tryBuildDerivation(c, arena, &req, headers.items, &job.drv_path, sink, act, &status);
    }
    if (r) |res| return res else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Status => switch (status.code) {
            // Superseded, not expected there (any more), worker draining or
            // gone, or died mid-stream.
            .aborted, .failed_precondition, .unavailable, .unknown, .internal => {
                c.log.errln("{f}: {s}, asking the scheduler again", .{ &job.drv_path, config.firstLine(status.message) });
                return null;
            },
            else => return c.statusError(status, "BuildDerivation", d),
        },
    }
}

fn tryBuildDerivation(c: *Client, arena: Allocator, req: *const proto.BuildDerivationRequest, headers: []const client_mod.Header, drv_path: *const StorePath, sink: event.Sink, act: remote.Activity, status: *Status) error{ Status, OutOfMemory }!BuildResult {
    var k = try c.start(arena, "/nix.remote.NixRemote/BuildDerivation", headers, status);
    defer k.deinit();
    k.send(req.*) catch |e| return k.failedSend(e, arena);
    k.closeSend() catch |e| return k.failedSend(e, arena);
    var pbuf: [path_mod.max_base_len + 256]u8 = undefined;
    const drv = drv_path.print(&pbuf);
    var res: ?BuildResult = null;
    var msg_arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer msg_arena.deinit();
    while (true) {
        _ = msg_arena.reset(.retain_capacity);
        const msg = (try k.recv(proto.BuildDerivationChunk, msg_arena.allocator())) orelse break;
        const ev = msg.event orelse continue;
        switch (ev) {
            .log_line => |line| {
                const l = try @import("../../syntax/text.zig").lossyAlloc(msg_arena.allocator(), line);
                act.result(remote.res_build_log_line, &.{.{ .string = std.mem.trimEnd(u8, l, "\n") }});
                sink.send(.{ .log = .{ .drv_path = drv, .line = line } });
            },
            // The call knows its derivation, so the phase is attributed the
            // way the daemon's `setPhase` result is.
            .phase => |phase| {
                act.result(remote.res_set_phase, &.{.{ .string = phase }});
                sink.send(.{ .phase = .{ .drv_path = drv, .phase = phase } });
            },
            .done => |done| {
                var r: Io.Reader = .fixed(done.result);
                var d: Diag = .init(c.gpa);
                defer d.deinit();
                res = BuildResult.read(&r, arena, &d) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Io => {
                        status.* = .{ .code = .internal, .message = try arena.dupe(u8, d.message()) };
                        return error.Status;
                    },
                };
            },
        }
    }
    const s = try k.finish(arena);
    if (s.code != .ok) {
        status.* = s;
        return error.Status;
    }
    return res orelse {
        status.* = .{ .code = .internal, .message = "gRPC BuildDerivation stream ended without a result" };
        return error.Status;
    };
}

/// What this run can re-send, by store path base name, so a `NOT_FOUND`
/// retry re-sends just the closure of one derivation
/// (store.cc:`uploadDrvClosure`). Everything this run registered is here; a
/// path the store already had is not ours to send again, and neither is a
/// substituted source. The objects are copied; their bytes must outlive it.
pub const Objects = struct {
    gpa: Allocator,
    by_name: std.StringHashMapUnmanaged(*Object) = .empty,

    pub fn init(gpa: Allocator) Objects {
        return .{ .gpa = gpa };
    }

    pub fn deinit(o: *Objects) void {
        var it = o.by_name.valueIterator();
        while (it.next()) |v| o.gpa.destroy(v.*);
        o.by_name.deinit(o.gpa);
    }

    /// Remembers what an `AddMultipleToStore` carried.
    pub fn extend(o: *Objects, objects: []const *Object) Allocator.Error!void {
        for (objects) |src| {
            const copied = try o.gpa.create(Object);
            copied.* = src.*;
            const gop = try o.by_name.getOrPut(o.gpa, copied.storePath().baseName());
            if (gop.found_existing) o.gpa.destroy(gop.value_ptr.*);
            gop.key_ptr.* = copied.storePath().baseName();
            gop.value_ptr.* = copied;
        }
    }

    /// `drv_path` and everything it references, references before
    /// referrers, in `arena`.
    fn closure(o: *const Objects, arena: Allocator, drv_path: *const StorePath) Allocator.Error![]*Object {
        var out: std.ArrayList(*Object) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const Item = struct { name: []const u8, expanded: bool };
        var stack: std.ArrayList(Item) = .empty;
        try stack.append(arena, .{ .name = drv_path.baseName(), .expanded = false });
        while (stack.pop()) |e| {
            const obj = o.by_name.get(e.name) orelse continue;
            if (e.expanded) {
                try out.append(arena, obj);
                continue;
            }
            if ((try seen.fetchPut(arena, obj.storePath().baseName(), {})) != null) continue;
            try stack.append(arena, .{ .name = e.name, .expanded = true });
            switch (obj.*) {
                .drv => |v| for (v.references) |*r| try stack.append(arena, .{ .name = r.baseName(), .expanded = false }),
                .source => {},
            }
        }
        return out.items;
    }
};

/// store.cc:`uploadDrvClosure`: `QueryValidPaths` on the closure with the
/// same routing headers, then `AddMultipleToStore` of what the worker lacks.
fn uploadClosure(c: *Client, arena: Allocator, objects: *const Objects, drv_path: *const StorePath, headers: []const client_mod.Header, d: *Diag) Error!usize {
    const closure = try objects.closure(arena, drv_path);
    if (closure.len == 0) return 0;
    const names = try arena.alloc([]const u8, closure.len);
    for (closure, names) |o, *n| n.* = o.storePath().baseName();
    var status: Status = undefined;
    const reply = c.unary(proto.QueryValidPathsReply, arena, "/nix.remote.NixRemote/QueryValidPaths", proto.QueryValidPathsRequest{ .paths = names }, headers, &status) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Status => return c.statusError(status, "QueryValidPaths", d),
    };
    var valid: plan.NameSet = .empty;
    for (reply.paths) |p| try valid.put(arena, p, {});
    var missing: std.ArrayList(*Object) = .empty;
    for (closure) |o| if (!valid.contains(o.storePath().baseName())) try missing.append(arena, o);
    if (missing.items.len == 0) return 1;
    _ = upload(c, arena, missing.items, headers, &status, d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Status => return c.statusError(status, "AddMultipleToStore", d),
    };
    return 2;
}

/// A `FetchNars` stream: one zstd stream across every path, flushed at each
/// frame, so a frame's decompressed bytes belong to `paths[path_index]`.
/// Each frame is handed to the decoder as its whole input: a flushed frame
/// ends on a block boundary, where the decoder stops for more input with its
/// window and tables intact.
const NarDecoder = struct {
    dec: std.compress.zstd.Decompress,
    input: Io.Reader,
    buf: []u8,

    fn init(gpa: Allocator) Allocator.Error!*NarDecoder {
        const n = try gpa.create(NarDecoder);
        errdefer gpa.destroy(n);
        n.buf = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        n.input = .fixed("");
        n.dec = .init(&n.input, n.buf, .{});
        return n;
    }

    fn deinit(n: *NarDecoder, gpa: Allocator) void {
        gpa.free(n.buf);
        gpa.destroy(n);
    }

    /// Starts on `data`, one frame's whole input.
    fn start(n: *NarDecoder, data: []const u8) void {
        n.input = .fixed(data);
    }

    /// Decodes more of the frame `start` gave into `dec.reader`'s buffer:
    /// false once the frame is used up.
    fn more(n: *NarDecoder) !bool {
        n.dec.reader.fillMore() catch |e| switch (e) {
            error.EndOfStream => return n.used(),
            error.ReadFailed => {
                const de = n.dec.err orelse return error.ReadFailed;
                if (de == error.EndOfStream and n.input.bufferedLen() == 0) {
                    n.dec.err = null;
                    return n.used();
                }
                return de;
            },
        };
        return true;
    }

    fn used(n: *const NarDecoder) error{MalformedFrame}!bool {
        if (n.input.bufferedLen() != 0) return error.MalformedFrame;
        return false;
    }
};

/// A `FetchNars` call read a path at a time: `next` moves to the next path
/// the store sends, and `reader` is its NAR, decoded frame by frame as it
/// is read, so a NAR is never held whole.
pub const NarStream = struct {
    c: *Client,
    names: []const []const u8,
    /// Where `reader`'s failures are reported.
    d: *Diag,
    arena: std.heap.ArenaAllocator,
    /// The frame being read; reset for each.
    frame_arena: std.heap.ArenaAllocator,
    status: Status,
    k: client_mod.Call,
    dec: *NarDecoder,
    /// The current path's NAR.
    reader: Io.Reader,
    /// A frame of the next path, which ended the current one.
    pending: ?proto.NarFrame = null,
    cur: usize = 0,
    /// `dec` holds a frame not yet used up.
    in_frame: bool = false,
    /// That frame is its path's last.
    frame_eof: bool = false,
    /// The current path's NAR is all read.
    path_done: bool = true,
    /// The current path ended with a frame that said so.
    eof: bool = false,
    /// The call sent its last frame.
    done: bool = false,
    /// Why `reader` failed, already in `d`.
    err: ?Error = null,

    const reader_len = @max(1 << 16, nar.min_reader_buffer);

    /// Starts `FetchNars(names)`, store path base names that outlive it.
    pub fn open(c: *Client, names: []const []const u8, d: *Diag) Error!*NarStream {
        const gpa = c.gpa;
        const s = try gpa.create(NarStream);
        errdefer gpa.destroy(s);
        s.* = .{
            .c = c,
            .names = names,
            .d = d,
            .arena = .init(gpa),
            .frame_arena = .init(gpa),
            .status = undefined,
            .k = undefined,
            .dec = undefined,
            .reader = .{ .vtable = &.{ .stream = stream, .discard = discard }, .buffer = &.{}, .seek = 0, .end = 0 },
        };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        const headers = try c.headers(a, d);
        s.k = c.start(a, "/nix.remote.NixRemote/FetchNars", headers.items, &s.status) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Status => return c.statusError(s.status, "FetchNars", d),
        };
        errdefer s.k.deinit();
        s.k.send(proto.FetchNarsRequest{ .paths = names }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Status => {},
        };
        s.k.closeSend() catch {};
        s.dec = try NarDecoder.init(gpa);
        errdefer s.dec.deinit(gpa);
        s.reader.buffer = try gpa.alloc(u8, reader_len);
        return s;
    }

    pub fn close(s: *NarStream) void {
        const gpa = s.c.gpa;
        gpa.free(s.reader.buffer);
        s.dec.deinit(gpa);
        s.k.deinit();
        s.frame_arena.deinit();
        s.arena.deinit();
        gpa.destroy(s);
    }

    /// Moves to the next path the store sends, past what is left of the
    /// current one: its index into `names`, or null after the last frame.
    pub fn next(s: *NarStream) Error!?usize {
        if (!s.path_done) _ = s.reader.discardRemaining() catch return s.err.?;
        s.reader.seek = 0;
        s.reader.end = 0;
        const f = s.pending orelse (try s.recv()) orelse return null;
        s.pending = null;
        s.cur = f.path_index;
        s.path_done = false;
        s.eof = false;
        s.begin(f);
        return s.cur;
    }

    /// The call's status, once `next` said there is no more.
    pub fn finish(s: *NarStream) Error!void {
        const st = try s.k.finish(s.arena.allocator());
        if (st.code != .ok) return s.c.statusError(st, "FetchNars", s.d);
    }

    /// A failure of what read `reader`: the call's own, already reported,
    /// or the reader's under the context "restoring a NAR".
    pub fn readFail(s: *NarStream, e: anyerror) Error {
        if (e == error.ReadFailed) if (s.err) |se| return se;
        // a bad NAR keeps the message that says how it is bad
        if (e == error.BadNar and s.d.msg != null) {
            remote.prefix(s.d, "restoring a NAR", .{});
            return error.Io;
        }
        return remote.failIo(s.d, e, "restoring a NAR", .{});
    }

    fn begin(s: *NarStream, f: proto.NarFrame) void {
        s.dec.start(f.data);
        s.in_frame = true;
        s.frame_eof = f.eof;
    }

    /// The next frame, null after the last.
    fn recv(s: *NarStream) Error!?proto.NarFrame {
        if (s.done) return null;
        _ = s.frame_arena.reset(.retain_capacity);
        const f = s.k.recv(proto.NarFrame, s.frame_arena.allocator()) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Status => return s.c.statusError(s.status, "FetchNars", s.d),
        } orelse {
            s.done = true;
            return null;
        };
        if (f.path_index >= s.names.len)
            return s.d.fail(error.Protocol, "FetchNars sent a frame for path {d}, only {d} were asked for", .{ f.path_index, s.names.len });
        return f;
    }

    /// Decodes more of the current path: false at its end.
    fn fill(s: *NarStream) error{ReadFailed}!bool {
        while (true) {
            if (s.in_frame) {
                if (s.dec.more() catch |e| return s.fail(remote.failIo(s.d, e, "restoring a NAR", .{}))) return true;
                s.in_frame = false;
                if (s.frame_eof) {
                    s.path_done = true;
                    s.eof = true;
                }
                continue;
            }
            if (s.path_done) return false;
            const f = (s.recv() catch |e| return s.fail(e)) orelse {
                s.path_done = true;
                return false;
            };
            if (f.path_index != s.cur) {
                s.pending = f;
                s.path_done = true;
                return false;
            }
            s.begin(f);
        }
    }

    fn fail(s: *NarStream, e: Error) error{ReadFailed} {
        s.err = e;
        return error.ReadFailed;
    }

    fn stream(r: *Io.Reader, w: *Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const s: *NarStream = @fieldParentPtr("reader", r);
        const src = &s.dec.dec.reader;
        while (true) {
            const avail = src.buffered();
            if (avail.len > 0) {
                const n = try w.write(limit.slice(avail));
                src.toss(n);
                return n;
            }
            if (!try s.fill()) return error.EndOfStream;
        }
    }

    fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
        const s: *NarStream = @fieldParentPtr("reader", r);
        const src = &s.dec.dec.reader;
        while (true) {
            const avail = src.buffered();
            if (avail.len > 0) {
                const n = limit.minInt(avail.len);
                src.toss(n);
                return n;
            }
            if (!try s.fill()) return error.EndOfStream;
        }
    }
};

/// `--fetch-to DIR`: the farm never copies outputs into a local store, so
/// the NARs come back over `FetchNars`, each restored as its frames arrive.
pub fn fetchIntoDir(c: *Client, paths: []const StorePath, dir: []const u8, t: *Timings, d: *Diag) Error!void {
    t.calls += 1;
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const s = try NarStream.open(c, try baseNames(arena.allocator(), paths), d);
    defer s.close();
    while (try s.next()) |i| {
        var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ dir, paths[i].baseName() }) catch
            return s.readFail(error.NameTooLong);
        nar.restorePath(c.io, &s.reader, Io.Dir.cwd(), dest, d) catch |e| return s.readFail(e);
    }
    return s.finish();
}

/// Registers `paths` and their closure in the local nix-daemon so an
/// out-link points at a real local store path. The local daemon substitutes
/// first: a farm publishes outputs under the cache key, while a worker's
/// path infos carry only the worker's key. The rest comes from the remote:
/// `QueryPathInfos` for the closure, then `FetchNars` for what the local
/// store lacks, written into one `AddMultipleToStore` with each path's
/// `ValidPathInfo`, signatures included, so the daemon checks them as
/// `nix copy --from` does.
pub fn register(c: *Client, paths: []const StorePath, conn: *worker.Connection, on_event: event.Sink, d: *Diag) Error!usize {
    var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var local: plan.PathSet = .empty;
    for (try conn.substitutePaths(a, paths, on_event, d)) |p| try local.put(a, p, {});
    var todo: std.ArrayList(StorePath) = .empty;
    for (paths) |p| if (!local.contains(p)) try todo.append(a, p);
    if (todo.items.len == 0) return 0;
    var t: Timings = .{};
    var infos = try remoteClosure(c, a, todo.items, &t, d);
    var valid: plan.PathSet = .empty;
    for (try conn.queryValid(a, try copy.keys(a, &infos), on_event, d)) |v| try valid.put(a, v, {});
    var ordered: std.ArrayList(StorePath) = .empty;
    for (try copy.topoSort(c.gpa, a, &infos)) |p| if (!valid.contains(p)) try ordered.append(a, p);
    if (ordered.items.len == 0) return 0;
    addFetched(c, a, conn, &infos, ordered.items, on_event, d) catch |e| {
        const msg = d.message();
        const text = std.fmt.allocPrint(a, "{s}\nhint: '{f}' publishes its outputs to a binary cache. The local daemon " ++
            "checks their signatures, as `nix copy --from` does, so add the cache's public " ++
            "key to `trusted-public-keys` in nix.conf, or use --no-link.", .{ msg, &c.cfg }) catch return e;
        return d.fail(error.Protocol, "{s}", .{text});
    };
    return ordered.items.len;
}

/// One `AddMultipleToStore` of `order`: each path's info, then its NAR as
/// `FetchNars` streams it.
fn addFetched(c: *Client, arena: Allocator, conn: *worker.Connection, infos: *const copy.Infos, order: []const StorePath, on_event: event.Sink, d: *Diag) Error!void {
    var up = try conn.addMultipleToStore(false, d);
    const w = up.writer();
    wire.writeU64(w, order.len) catch |e| return up.fail(e, d);
    const s = NarStream.open(c, try baseNames(arena, order), d) catch |e| return up.fail(e, d);
    defer s.close();
    const started = try arena.alloc(bool, order.len);
    @memset(started, false);
    while (s.next() catch |e| return up.fail(e, d)) |i| {
        if (!started[i]) {
            started[i] = true;
            infos.getPtr(order[i]).?.write(w) catch |e| return up.fail(s.readFail(e), d);
        }
        _ = s.reader.streamRemaining(w) catch |e| return up.fail(s.readFail(e), d);
    }
    s.finish() catch |e| return up.fail(e, d);
    try up.finish(on_event, d);
}

/// The closure of `paths` on the remote store, as path infos in `arena`.
fn remoteClosure(c: *Client, arena: Allocator, paths: []const StorePath, t: *Timings, d: *Diag) Error!copy.Infos {
    var infos: copy.Infos = .empty;
    var queue: std.ArrayList(StorePath) = .empty;
    try queue.appendSlice(arena, paths);
    while (queue.items.len > 0) {
        var batch: std.ArrayList(StorePath) = .empty;
        for (queue.items) |p| if (!infos.contains(p)) try batch.append(arena, p);
        queue.clearRetainingCapacity();
        const unique = path_mod.sortUnique(batch.items);
        if (unique.len == 0) break;
        const got = try queryPathInfos(c, arena, unique, t, d);
        for (unique) |p| {
            const info = got.get(p) orelse
                return d.fail(error.Protocol, "'{f}' has no path info on '{s}'", .{ &p, c.cfg.authority });
            for (info.references) |r| {
                const rp = StorePath.parse(r, d) catch return error.Store;
                if (!infos.contains(rp)) try queue.append(arena, rp);
            }
            try infos.put(arena, p, info);
        }
    }
    return infos;
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).toNanoseconds();
}

// Tests

const testing = std.testing;

test "the timings report with every line" {
    var t: Timings = .{ .common = backend.everyTiming(), .drvs = 11, .drvs_cached = 10, .calls = 12 };
    t.common.trusted = true;
    var p: Plan = .init(testing.allocator);
    defer p.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try t.report(&out.writer, &p, 9 * std.time.ns_per_ms);
    try testing.expectEqualStrings(
        \\plan: 0 sources, 0 drvs, 0.009s
        \\connect: gRPC, trusted, 0.001s
        \\query: 9 paths, 8 missing, 0.002s
        \\resolve: 7 sources, 6 not from this eval, read from /nix/store, 0.003s
        \\substitute: 5 paths left to the store, 0.004s
        \\add: 4 paths, 3 bytes, 0.005s
        \\build: 11 drvs, 10 already valid, 0.006s
        \\outputs: 0.007s
        \\fetch: 2 outputs, 0.008s
        \\link: 1 out-links, 3 paths copied, 0.010s
        \\grpc: 12 calls
    , out.written());
}

test "reschedules back off past a dead worker" {
    var p: [8]u64 = undefined;
    for (&p, 1..) |*x, n| x.* = reschedulePause(@intCast(n));
    try testing.expectEqualSlices(u64, &.{ 1, 2, 4, 8, 16, 30, 30, 30 }, &p);
    try testing.expectEqual(30, reschedulePause(std.math.maxInt(u32)));
}

test "required features come from the env or structured attrs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var drv: Derivation = .{ .name = "x", .platform = "x86_64-linux" };
    try drv.envSet(a, "requiredSystemFeatures", "kvm big-parallel");
    const f = try requiredSystemFeatures(a, &drv);
    try testing.expectEqual(2, f.len);
    try testing.expectEqualStrings("big-parallel", f[0]);
    try testing.expectEqualStrings("kvm", f[1]);
    drv.structured_attrs = "{\"requiredSystemFeatures\":[\"kvm\"]}";
    const g = try requiredSystemFeatures(a, &drv);
    try testing.expectEqual(1, g.len);
    try testing.expectEqualStrings("kvm", g[0]);
}

test "a NAR stream decodes frame by frame" {
    // one zstd frame of raw blocks split at block boundaries: the decoder
    // must stop between them and go on with the next input
    var z: [64]u8 = undefined;
    var w: Writer = .fixed(&z);
    try w.writeAll(&.{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x48 }); // magic, no checksum, window
    const block1 = "hello ";
    const block2 = "world";
    try w.writeInt(u24, @intCast(block1.len << 3), .little); // raw, not last
    try w.writeAll(block1);
    const split = w.end;
    try w.writeInt(u24, @intCast(block2.len << 3 | 1), .little); // raw, last
    try w.writeAll(block2);
    const all = w.buffered();
    const dec = try NarDecoder.init(testing.allocator);
    defer dec.deinit(testing.allocator);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    for ([_][]const u8{ all[0..split], all[split..] }, [_][]const u8{ "hello ", "hello world" }) |frame, want| {
        dec.start(frame);
        while (try dec.more()) {
            try got.appendSlice(testing.allocator, dec.dec.reader.buffered());
            dec.dec.reader.toss(dec.dec.reader.bufferedLen());
        }
        try testing.expectEqualStrings(want, got.items);
    }
}

test {
    _ = @import("server_tests.zig");
}
