//! The one build path. Every iets
//! command that realises a derivation goes through `Dispatcher`: one
//! connection carries the uploads and the builds of a batch of ready
//! derivations, and every build reports through one structured event stream
//! with provenance attached.
//!
//! Three axes, kept apart:
//!
//! - **What to feed it.** `iets build` hands over a fixed set of roots
//!   (`upload.PlanUpload`). `eval-jobs` instantiation hands over batches as
//!   the walk finishes attributes (`upload.StreamUpload`). See
//!   docs/reference/commands.md.
//! - **How to reach the store.** `backend.Backend`: the worker protocol
//!   sends one `BuildPathsWithResults` per ready set
//!   (docs/explanation/history.md: one op per ready set beats one op per
//!   derivation by 7-10x, and the protocol is serial per connection);
//!   `grpc://` fans the set out instead.
//! - **What to say about it.** `render`, from one event stream.

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const log_mod = @import("../log.zig");
const Log = log_mod.Log;
const provenance = @import("../provenance.zig");
const Provenance = provenance.Provenance;
const remote = @import("../remote.zig");
const Event = remote.event.Event;
const Sink = remote.event.Sink;
const worker = remote.worker;
const plan = remote.plan;
const Plan = plan.Plan;
const StorePath = @import("../store/path.zig").StorePath;
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const hash_mod = @import("../store/hash.zig");
const backend = @import("backend.zig");
const Backend = backend.Backend;
const upload_mod = @import("upload.zig");
const Uploader = upload_mod.Uploader;
const event = @import("event.zig");
const BuildEvent = event.BuildEvent;
const Kind = event.Kind;
const render = @import("render.zig");
const Renderer = render.Renderer;
const Style = render.Style;

pub const Error = remote.Error;

/// One derivation the caller asked for, under the name it wants to see.
pub const Target = struct {
    /// Attribute path, or the derivation name when the caller has none.
    attr: []const u8,
    drv: StorePath,
    /// Wanted output names; empty means every output (`!*`).
    outputs: []const []const u8 = &.{},

    pub fn job(t: Target) backend.Job {
        return .{ .drv = t.drv, .outputs = t.outputs };
    }
};

/// What became of one target. Its strings live as long as the dispatcher.
pub const Outcome = struct {
    attr: []const u8,
    drv: StorePath,
    success: bool,
    skipped: bool = false,
    reason: ?[]const u8 = null,
    log_tail: []const []const u8 = &.{},
    /// By output name, for the targets that built.
    outputs: []const event.Output = &.{},
    /// `log.buildExit` of a failure, 0 otherwise.
    exit: i32 = 0,
};

fn now(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// Where the events go: the renderer, behind a lock the heartbeat shares.
pub const Reporter = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    render: Renderer,
    /// The renderer's output when it writes the session's stderr.
    log_out: ?render.LogOut = null,
    out_buf: [4096]u8 = undefined,
    /// Whose log shows the live region, so the region comes down with us.
    live: ?*Log = null,
    /// Per drv: when the build started and how long it ran.
    timing: std.StringHashMapUnmanaged(Timing) = .empty,

    const Timing = struct { start: u64, took: ?u64 = null };

    /// The renderer on the session's stderr, drawing the live region on a
    /// terminal. Under internal-json the activity records carry the
    /// progress instead.
    pub fn create(gpa: Allocator, l: *Log, style: Style) !*Reporter {
        const r = try gpa.create(Reporter);
        r.* = .{ .gpa = gpa, .io = l.io, .render = undefined };
        r.log_out = .init(l, &r.out_buf);
        r.render = .init(gpa, l, style, &r.log_out.?.writer, .{});
        if (style.mode == .tty and !style.quiet and !l.isJson()) {
            l.progress.setLive(true);
            r.render.withLive(.onLog(l));
            r.live = l;
        }
        return r;
    }

    /// The same, writing the progress somewhere else than stderr.
    pub fn createOutput(gpa: Allocator, l: *Log, style: Style, out: *Writer, clock: render.Clock) !*Reporter {
        const r = try gpa.create(Reporter);
        r.* = .{ .gpa = gpa, .io = l.io, .render = .init(gpa, l, style, out, clock) };
        return r;
    }

    pub fn destroy(r: *Reporter) void {
        r.finish();
        if (r.live) |l| l.progress.setLive(false);
        var it = r.timing.keyIterator();
        while (it.next()) |k| r.gpa.free(k.*);
        r.timing.deinit(r.gpa);
        r.render.deinit();
        r.gpa.destroy(r);
    }

    /// The summary, and the region taken down; once is enough.
    pub fn finish(r: *Reporter) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.render.finish() catch {};
        if (r.log_out) |*o| o.writer.flush() catch {};
    }

    /// The derivations the build op now running reports verdicts for.
    fn owns(r: *Reporter, drvs: []const []const u8) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.render.owns(drvs) catch {};
    }

    fn release(r: *Reporter) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.render.release() catch {};
        r.flushOut();
    }

    fn emit(r: *Reporter, e: *const BuildEvent) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.render.event(e) catch {};
        r.flushOut();
    }

    fn flushOut(r: *Reporter) void {
        if (r.log_out) |*o| o.writer.flush() catch {};
    }

    fn heartbeat(r: *Reporter) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.render.heartbeat() catch {};
        r.flushOut();
    }

    fn interval(r: *Reporter) u64 {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        return r.render.interval();
    }

    fn started(r: *Reporter, drv: []const u8) void {
        if (r.timing.contains(drv)) return;
        const k = r.gpa.dupe(u8, drv) catch return;
        r.timing.put(r.gpa, k, .{ .start = now(r.io) }) catch r.gpa.free(k);
    }

    fn stoppedTiming(r: *Reporter, drv: []const u8) void {
        const t = r.timing.getPtr(drv) orelse return;
        if (t.took == null) t.took = now(r.io) - t.start;
    }

    fn duration(r: *const Reporter, drv: []const u8) u64 {
        const t = r.timing.get(drv) orelse return 0;
        return t.took orelse now(r.io) - t.start;
    }

    /// The build's log tail, in `a`: the live buffer, else what a finished
    /// build left.
    fn tail(r: *Reporter, a: Allocator, drv: []const u8) []const []const u8 {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        const live = r.render.liveTail(a, drv) catch return &.{};
        if (live.len > 0) return live;
        return r.render.retainedTail(a, drv) catch &.{};
    }

    fn stopped(r: *Reporter, drv: []const u8, built: bool) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.render.stopped(drv, built) catch {};
        r.flushOut();
    }

    fn note(r: *Reporter, msg: []const u8) void {
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        r.render.note(msg);
        r.flushOut();
    }
};

/// The heartbeat thread: pokes the renderer so a CI log shows liveness and a
/// stalled build gets escalated even while the client sits in a read.
const Heartbeat = struct {
    io: Io,
    /// Set to stop; waiting on it is the tick, so a stop needs no tick.
    stop: Io.Event = .unset,
    thread: ?std.Thread = null,

    fn start(h: *Heartbeat, r: *Reporter) void {
        h.thread = std.Thread.spawn(.{}, run, .{ h, r }) catch null;
    }

    fn run(h: *Heartbeat, r: *Reporter) void {
        var last = now(h.io);
        while (!h.stop.isSet()) {
            const every = r.interval();
            const left = every -| (now(h.io) - last);
            h.stop.waitTimeout(h.io, .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } }) catch {};
            if (!h.stop.isSet() and now(h.io) - last >= every) {
                last = now(h.io);
                r.heartbeat();
            }
        }
    }

    fn end(h: *Heartbeat) void {
        h.stop.set(h.io);
        if (h.thread) |t| t.join();
        h.thread = null;
    }
};

/// The dispatcher: one backend, one event stream, batched build ops.
pub const Dispatcher = struct {
    gpa: Allocator,
    io: Io,
    log: *Log,
    backend: Backend,
    reporter: *Reporter,
    prov: *const Provenance,
    seen: plan.PathSet = .empty,
    /// Nix's failingExitStatus of the failed builds, 0 while none failed.
    exit: i32 = 0,
    upload: upload_mod.Stats = .{},
    heartbeat: Heartbeat,
    /// What the outcomes point into.
    keep: std.heap.ArenaAllocator,

    /// Connects `t` and starts the reporting. `prov` must outlive it.
    pub fn open(cx: backend.Context, l: *Log, t: *const worker.Transport, options: worker.Options, prov: *const Provenance, style: Style, d: *Diag) Error!*Dispatcher {
        const reporter = try Reporter.create(cx.gpa, l, style);
        errdefer reporter.destroy();
        const t0 = now(cx.io);
        const First = struct {
            r: *Reporter,
            pub fn onEvent(f: *@This(), e: Event) void {
                if (e == .log) f.r.note(e.log.line);
            }
        };
        var first: First = .{ .r = reporter };
        const b = try backend.open(cx, t, options, .of(First, &first), d);
        b.noteConnect(now(cx.io) - t0);
        return withBackend(cx.gpa, l, b, prov, reporter);
    }

    /// Wraps an already-open backend; the dispatcher owns both it and the
    /// reporter from here on.
    pub fn withBackend(gpa: Allocator, l: *Log, b: Backend, prov: *const Provenance, reporter: *Reporter) Allocator.Error!*Dispatcher {
        const dp = try gpa.create(Dispatcher);
        dp.* = .{
            .gpa = gpa,
            .io = l.io,
            .log = l,
            .backend = b,
            .reporter = reporter,
            .prov = prov,
            .heartbeat = .{ .io = l.io },
            .keep = .init(gpa),
        };
        dp.heartbeat.start(reporter);
        return dp;
    }

    pub fn destroy(dp: *Dispatcher) void {
        dp.heartbeat.end();
        dp.reporter.destroy();
        dp.backend.close();
        dp.seen.deinit(dp.gpa);
        dp.keep.deinit();
        dp.gpa.destroy(dp);
    }

    /// Uploads what the batch needs and builds it in one op. Targets whose
    /// drv was already dispatched are dropped. The outcomes live as long as
    /// the dispatcher.
    pub fn submit(dp: *Dispatcher, up: Uploader, batch_in: []const Target, d: *Diag) Error![]Outcome {
        var batch: std.ArrayList(Target) = .empty;
        defer batch.deinit(dp.gpa);
        for (batch_in) |t| {
            if ((try dp.seen.fetchPut(dp.gpa, t.drv, {})) != null) continue;
            try batch.append(dp.gpa, t);
        }
        if (batch.items.len == 0) return &.{};
        const out = try dp.submitOnce(up, batch.items, d);
        for (out) |o| dp.exit = log_mod.combineExit(dp.exit, o.exit);
        return out;
    }

    fn submitOnce(dp: *Dispatcher, up: Uploader, batch: []const Target, d: *Diag) Error![]Outcome {
        const keep = dp.keep.allocator();
        var scratch_state: std.heap.ArenaAllocator = .init(dp.gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        var by_drv: ByDrv = .empty;
        const roots = try scratch.alloc(StorePath, batch.len);
        const drv_strs = try scratch.alloc([]const u8, batch.len);
        for (batch, roots, drv_strs) |t, *r, *s| {
            r.* = t.drv;
            s.* = try std.fmt.allocPrint(scratch, "{f}", .{&t.drv});
            try by_drv.put(scratch, s.*, t.attr);
        }
        // Until this op reports its verdicts, the end of a build's activity
        // decides nothing: with a build hook the daemon runs two activities
        // for one derivation, and neither says whether it succeeded.
        dp.reporter.owns(by_drv.keys());

        var sink_ctx: EventSink = .{ .dp = dp, .names = .{ .prov = dp.prov, .by_drv = &by_drv } };
        const sink: Sink = .of(EventSink, &sink_ctx);

        const built = try staticOutputs(scratch, up, batch, roots);
        var held = false;
        if (built) |o| {
            const r = try alreadyBuilt(scratch, dp.backend, roots, o, sink, d);
            try up.rootsAnswered(roots, &r.roots_valid);
            held = r.held;
        }
        var status: backend.StatusMap = .empty;
        if (held) {
            for (by_drv.keys()) |k| try status.put(scratch, k, .ok_status);
        } else {
            const stats = try up.upload(dp.backend, roots, sink, d);
            dp.upload.merge(stats);
            const jobs = try scratch.alloc(backend.Job, batch.len);
            for (batch, jobs) |t, *j| j.* = t.job();
            var dc: DrvsCtx = .{ .up = up, .roots = roots };
            status = try dp.backend.submit(scratch, .{ .jobs = jobs, .drvs_ctx = &dc, .drvs = DrvsCtx.f }, sink, d);
        }

        const names = sink_ctx.names;
        var earlier_failed = false;
        for (status.values()) |s| if (!s.ok) {
            earlier_failed = true;
        };
        const out = try keep.alloc(Outcome, batch.len);
        for (batch, drv_strs, out) |t, drv, *o| {
            const elapsed = dp.reporter.duration(drv);
            const attr = try keep.dupe(u8, t.attr);
            const s = status.get(drv) orelse {
                // No verdict for this target. Either the store stopped before
                // it reached it (`keep-going` off, something earlier failed),
                // or the op came back without it, which is a broken builder.
                // Both leave the target unbuilt, so both exit non-zero.
                const why = if (earlier_failed)
                    "an earlier build in the batch failed"
                else
                    try std.fmt.allocPrint(keep, "the builder returned no build result for '{s}'", .{drv});
                const ev = try names.event(scratch, drv, .{ .skipped = .{ .why = why } }, elapsed);
                dp.reporter.emit(&ev);
                o.* = .{ .attr = attr, .drv = t.drv, .success = false, .skipped = true, .reason = why, .exit = 1 };
                continue;
            };
            if (s.ok) {
                const map: []const backend.OutputEntry = if (built) |b| b.get(drv).? else try dp.backend.outputs(scratch, drv, sink, d);
                var outs: std.ArrayList(event.Output) = .empty;
                for (map) |e| {
                    const p = e.path orelse continue;
                    if (t.outputs.len > 0 and !contains(t.outputs, e.name)) continue;
                    try outs.append(keep, .{ .name = try keep.dupe(u8, e.name), .path = try keep.dupe(u8, p) });
                }
                const ev = try names.event(scratch, drv, .{ .built = .{ .outputs = outs.items } }, elapsed);
                dp.reporter.emit(&ev);
                o.* = .{ .attr = attr, .drv = t.drv, .success = true, .outputs = outs.items };
                continue;
            }
            const tail = dp.reporter.tail(keep, drv);
            // The daemon's message is several coloured lines; the records
            // want one plain one, the log tail has the rest.
            const full = try rewriteAlloc(scratch, dp.prov, s.reason);
            const plain = try log_mod.stripAnsi(scratch, full);
            const reason = try log_mod.reasonLine(keep, plain);
            const ev = try names.event(scratch, drv, .{ .failed = .{ .reason = reason, .log_tail = tail } }, elapsed);
            dp.reporter.emit(&ev);
            dp.log.buildFailed(names.pos(drv), full, s.exit, null);
            o.* = .{ .attr = attr, .drv = t.drv, .success = false, .reason = reason, .log_tail = tail, .exit = s.exit };
        }
        // A mismatch is a fact about a fixed-output derivation of this
        // batch's closure, from the daemon; anything else that prints the
        // words is dropped. Nix's worker sets the hash-mismatch flag for the
        // whole run, so a root whose dependency mismatched exits 102 as well.
        var planned: Planned = .{ .up = up, .roots = roots, .arena = scratch };
        if (dp.log.resolveMismatches(&planned, Planned.has) > 0) dp.exit = log_mod.combineExit(dp.exit, 102);
        // a batch that built in full built every dependency too
        if (earlier_failed or status.count() < batch.len) {
            const held_ok = blk: {
                dp.reporter.lock.lockUncancelable(dp.io);
                defer dp.reporter.lock.unlock(dp.io);
                break :blk try dp.reporter.render.heldSuccesses(scratch);
            };
            const left = try unbuilt(scratch, dp.backend, held_ok, sink);
            dp.reporter.lock.lockUncancelable(dp.io);
            defer dp.reporter.lock.unlock(dp.io);
            try dp.reporter.render.setUnfinished(left);
        }
        dp.reporter.release();
        return out;
    }

    /// `--no-build`: register the closure and stop.
    pub fn uploadOnly(dp: *Dispatcher, up: Uploader, roots: []const StorePath, d: *Diag) Error!void {
        var by_drv: ByDrv = .empty;
        var sink_ctx: EventSink = .{ .dp = dp, .names = .{ .prov = dp.prov, .by_drv = &by_drv } };
        const stats = try up.upload(dp.backend, roots, .of(EventSink, &sink_ctx), d);
        dp.upload.merge(stats);
    }

    /// `--dry-run`: register the closure, then ask what building `targets`
    /// takes; in `arena`.
    pub fn missing(dp: *Dispatcher, arena: Allocator, up: Uploader, targets: []const Target, d: *Diag) Error!worker.Missing {
        const roots = try arena.alloc(StorePath, targets.len);
        const jobs = try arena.alloc(backend.Job, targets.len);
        for (targets, roots, jobs) |t, *r, *j| {
            r.* = t.drv;
            j.* = t.job();
        }
        try dp.uploadOnly(up, roots, d);
        var by_drv: ByDrv = .empty;
        var sink_ctx: EventSink = .{ .dp = dp, .names = .{ .prov = dp.prov, .by_drv = &by_drv } };
        return dp.backend.missing(arena, jobs, .of(EventSink, &sink_ctx), d);
    }

    /// An indirect GC root at `link` for `store_path`.
    pub fn outLink(dp: *Dispatcher, store_path: []const u8, link: []const u8, d: *Diag) Error!void {
        return dp.backend.addRoot(store_path, link, d);
    }

    /// `nix build`'s outputs and out-links, on the local daemon whatever
    /// the builder is.
    pub fn outLinks(dp: *Dispatcher, links: []const backend.Link, d: *Diag) Error!void {
        return dp.backend.outLinks(links, d);
    }

    /// Restores one output of a remote store into `dir`.
    pub fn fetch(dp: *Dispatcher, store_path: []const u8, dir: []const u8, d: *Diag) Error!void {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(dp.io, dir) catch |e| return remote.failIo(d, e, "cannot create {s}", .{dir});
        const sp = StorePath.parse(store_path, d) catch return error.Store;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dest = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, sp.baseName() }) catch return d.fail(error.Usage, "path too long", .{});
        // a dangling symlink is a path that is there, and the restore must
        // not write through it
        if (cwd.statFile(dp.io, dest, .{ .follow_symlinks = false })) |_| {
            return d.fail(error.Usage, "fetch: '{s}' already exists", .{dest});
        } else |_| {}
        return dp.backend.fetch(store_path, dir, d);
    }

    /// `--timings`: the backend's own per-phase report.
    pub fn report(dp: *Dispatcher, w: *Writer, p: *const Plan, plan_time: u64) Writer.Error!void {
        return dp.backend.report(w, p, plan_time);
    }
};

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Drv path to the attribute the caller gave for it.
const ByDrv = std.StringArrayHashMapUnmanaged([]const u8);

/// The uploader's walk, for a backend that schedules the builds itself.
const DrvsCtx = struct {
    up: Uploader,
    roots: []const StorePath,

    fn f(ctx: ?*anyopaque, closure: bool, arena: Allocator, d: *Diag) anyerror![]const backend.Drv {
        const c: *DrvsCtx = @ptrCast(@alignCast(ctx.?));
        return c.up.drvs(c.roots, closure, arena, d);
    }
};

/// Whether a `specified` hash is the output hash of a fixed-output
/// derivation of the batch's closure, walked once, on the first mismatch.
const Planned = struct {
    up: Uploader,
    roots: []const StorePath,
    arena: Allocator,
    drvs: ?[]const backend.Drv = null,

    fn has(p: *Planned, specified: []const u8) bool {
        if (p.drvs == null) {
            var d: Diag = .init(p.arena);
            p.drvs = p.up.drvs(p.roots, true, p.arena, &d) catch &.{};
        }
        for (p.drvs.?) |*dv| if (hasOutputHash(p.arena, dv, specified)) return true;
        return false;
    }
};

/// Output name to path per root drv, in `a`.
const Static = std.StringHashMapUnmanaged([]const backend.OutputEntry);

/// The wanted output paths of every target, when each one is known without
/// building: input-addressed and fixed outputs. Null when any is not, or a
/// drv cannot be read; the batch then asks the store as usual.
fn staticOutputs(a: Allocator, up: Uploader, batch: []const Target, roots: []const StorePath) Allocator.Error!?Static {
    var d: Diag = .init(a);
    const drvs = up.drvs(roots, false, a, &d) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else null;
    var all: Static = .empty;
    for (batch) |t| {
        const dv = for (drvs) |*x| {
            if (x.path.eql(&t.drv)) break x;
        } else return null;
        const name = Derivation.nameFromPath(&t.drv, &d) catch return null;
        const parsed = Derivation.parse(a, dv.aterm, name, &d) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else null;
        for (t.outputs) |n| if (parsed.output(n) == null) return null;
        var outs: std.ArrayList(backend.OutputEntry) = .empty;
        for (parsed.outputs) |o| {
            if (t.outputs.len > 0 and !contains(t.outputs, o.name)) continue;
            const p = (parsed.outputPath(o.name, &d) catch return null) orelse return null;
            try outs.append(a, .{ .name = o.name, .path = try std.fmt.allocPrint(a, "{f}", .{&p}) });
        }
        try all.put(a, try std.fmt.allocPrint(a, "{f}", .{&t.drv}), outs.items);
    }
    return all;
}

/// Whether the store holds every root and every wanted output, so nothing
/// needs to go up or build, and which roots it holds. The daemon would answer
/// the same, but nixbuild.net takes a quarter of a second to. The roots are
/// asked first: a missing drv costs it 7 ms, a missing output 170 ms.
fn alreadyBuilt(a: Allocator, b: Backend, roots: []const StorePath, outputs: Static, sink: Sink, d: *Diag) Error!struct { held: bool, roots_valid: plan.NameSet } {
    const roots_valid = try b.queryValid(a, roots, sink, d);
    for (roots) |r| if (!roots_valid.contains(r.baseName())) return .{ .held = false, .roots_valid = roots_valid };
    var paths: std.ArrayList(StorePath) = .empty;
    var it = outputs.valueIterator();
    while (it.next()) |m| for (m.*) |e| {
        const p = StorePath.parse(e.path orelse return .{ .held = false, .roots_valid = roots_valid }, d) catch
            return .{ .held = false, .roots_valid = roots_valid };
        try paths.append(a, p);
    };
    const valid = try b.queryValid(a, paths.items, sink, d);
    for (paths.items) |p| if (!valid.contains(p.baseName())) return .{ .held = false, .roots_valid = roots_valid };
    return .{ .held = true, .roots_valid = roots_valid };
}

/// The derivations of `drvs` with an output the store does not hold. A
/// derivation the store cannot answer for is left out: its verdict stays
/// what the daemon's messages say.
fn unbuilt(a: Allocator, b: Backend, drvs: []const []const u8, sink: Sink) Allocator.Error![]const []const u8 {
    var d: Diag = .init(a);
    var out: std.ArrayList([]const u8) = .empty;
    const Item = struct { drv: []const u8, paths: []const StorePath };
    var items: std.ArrayList(Item) = .empty;
    var all: std.ArrayList(StorePath) = .empty;
    for (drvs) |drv| {
        const map = b.outputs(a, drv, sink, &d) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        var paths: std.ArrayList(StorePath) = .empty;
        const known = for (map) |e| {
            const p = StorePath.parse(e.path orelse break false, &d) catch break false;
            try paths.append(a, p);
        } else true;
        if (!known) {
            try out.append(a, drv);
            continue;
        }
        try all.appendSlice(a, paths.items);
        try items.append(a, .{ .drv = drv, .paths = paths.items });
    }
    const valid = b.queryValid(a, all.items, sink, &d) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return out.items;
    };
    for (items.items) |it| for (it.paths) |p| if (!valid.contains(p.baseName())) {
        try out.append(a, it.drv);
        break;
    };
    return out.items;
}

/// What one derivation is called and where it was defined: the attribute
/// the caller gave for it, else what provenance knows, else the
/// derivation's own name. The position is added in one place, here.
const Names = struct {
    prov: *const Provenance,
    by_drv: *const ByDrv,

    fn pos(n: Names, drv: []const u8) ?[]const u8 {
        const s = n.prov.site(drv) orelse return null;
        return s.pos;
    }

    fn attr(n: Names, drv: []const u8) []const u8 {
        if (n.by_drv.get(drv)) |a| return a;
        return n.prov.attrOf(drv) orelse stripHash(drv);
    }

    /// `<attr> (<file>:<line>:<col>)` when the position is known and names
    /// this derivation alone.
    fn label(n: Names, a: Allocator, drv: []const u8) ![]const u8 {
        const at = n.attr(drv);
        const s = n.prov.site(drv) orelse return at;
        const p = s.ownPos() orelse return at;
        return std.fmt.allocPrint(a, "{s} ({s})", .{ at, p });
    }

    fn event(n: Names, a: Allocator, drv: []const u8, kind: Kind, elapsed: u64) !BuildEvent {
        return .{ .attr = try n.label(a, drv), .drv = drv, .kind = kind, .elapsed = elapsed, .pos = n.pos(drv) };
    }
};

/// `text` with the store paths of copied sources named as the local files
/// they came from; in `a`.
fn rewriteAlloc(a: Allocator, prov: *const Provenance, text: []const u8) Allocator.Error![]const u8 {
    var buf: Writer.Allocating = .init(a);
    prov.rewrite(&buf.writer, text) catch return error.OutOfMemory;
    return buf.written();
}

/// The daemon's stream mapped onto `BuildEvent`s.
const EventSink = struct {
    dp: *Dispatcher,
    names: Names,

    pub fn onEvent(s: *EventSink, e: Event) void {
        s.handle(e) catch {};
    }

    fn handle(s: *EventSink, e: Event) !void {
        const r = s.dp.reporter;
        var arena_state: std.heap.ArenaAllocator = .init(s.dp.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        switch (e) {
            .started => |x| {
                r.started(x.drv_path);
                const ev = try s.names.event(a, x.drv_path, .started, 0);
                r.emit(&ev);
            },
            .phase => |x| {
                const ev = try s.names.event(a, x.drv_path, .{ .phase = x.phase }, r.duration(x.drv_path));
                r.emit(&ev);
            },
            .log => |x| {
                const line = try rewriteAlloc(a, s.names.prov, x.line);
                const ev = try s.names.event(a, x.drv_path, .{ .log = line }, r.duration(x.drv_path));
                r.emit(&ev);
            },
            .stopped => |x| {
                r.stoppedTiming(x.drv_path);
                r.stopped(x.drv_path, x.built);
            },
            .failed => |x| {
                const d = r.duration(x.drv_path);
                const tail = r.tail(a, x.drv_path);
                const reason = try rewriteAlloc(a, s.names.prov, x.reason);
                const ev = try s.names.event(a, x.drv_path, .{ .failed = .{ .reason = reason, .log_tail = tail } }, d);
                r.emit(&ev);
            },
        }
    }
};

/// Whether `dv` is fixed-output with `specified` as its output hash. The
/// ATerm holds the hash in base 16, so the scan is over bytes and only a
/// derivation that could match is parsed.
fn hasOutputHash(a: Allocator, dv: *const backend.Drv, specified: []const u8) bool {
    var d: Diag = .init(a);
    const want = hash_mod.Hash.parseAny(specified, null, &d) catch return false;
    var buf: [hash_mod.Hash.max_string_len]u8 = undefined;
    const hex = want.print(&buf, .base16, false);
    if (std.mem.indexOf(u8, dv.aterm, hex) == null) return false;
    const name = Derivation.nameFromPath(&dv.path, &d) catch return false;
    const drv = Derivation.parse(a, dv.aterm, name, &d) catch return false;
    for (drv.outputs) |o| switch (o.output) {
        .fixed => |f| if (f.hash.eql(want)) return true,
        else => {},
    };
    return false;
}

/// `<hash>-<name>.drv` as just `<name>`, the way a build log names a
/// derivation that no attribute points at.
fn stripHash(drv_path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, drv_path, '/')) |i| drv_path[i + 1 ..] else drv_path;
    const b = if (std.mem.endsWith(u8, base, ".drv")) base[0 .. base.len - 4] else base;
    if (std.mem.indexOfScalar(u8, b, '-')) |i| if (i == 32) return b[i + 1 ..];
    return b;
}

// Tests

const testing = std.testing;
const fanout = @import("fanout.zig");
const Object = plan.Object;

fn testDrv(name: []const u8) StorePath {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var buf: [128]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "/nix/store/00000000000000000000000000000000-{s}.drv", .{name}) catch unreachable;
    return StorePath.parse(p, &d) catch unreachable;
}

test "targets become jobs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t: Target = .{ .attr = "a", .drv = testDrv("x"), .outputs = &.{ "out", "dev" } };
    const j = t.job();
    try testing.expect(j.drv.eql(&t.drv));
    try testing.expectEqualStrings("dev,out", try j.spec(arena.allocator()));
}

test "hash stripping" {
    var buf: [128]u8 = undefined;
    const p = testDrv("hello");
    try testing.expectEqualStrings("hello", stripHash(p.print(&buf)));
    try testing.expectEqualStrings("plain", stripHash("plain"));
}

/// A backend that builds every job of a batch concurrently, the way the
/// `grpc://` farm does, and tags every line it streams with its drv.
const Fan = struct {
    limit: usize,
    over: std.atomic.Value(bool) = .init(false),
    /// False: the op comes back without a verdict for any job, the way a
    /// store that stopped early leaves its targets.
    verdicts: bool = true,
    live: std.atomic.Value(usize) = .init(0),
    jobs: []const backend.Job = &.{},

    pub fn queryValid(_: *Fan, _: Allocator, _: []const StorePath, _: Sink, _: *Diag) Error!plan.NameSet {
        return .empty;
    }
    pub fn substitute(_: *Fan, _: []const StorePath, _: Sink, _: *Diag) Error!void {}
    pub fn addObjects(_: *Fan, _: []const *Object, _: Sink, _: *Diag) Error!u64 {
        return 0;
    }
    fn build(ctx: ?*anyopaque, i: usize, sink: Sink) bool {
        const f: *Fan = @ptrCast(@alignCast(ctx.?));
        var pbuf: [256]u8 = undefined;
        const drv = f.jobs[i].drv.print(&pbuf);
        if (f.live.fetchAdd(1, .seq_cst) + 1 > f.limit) f.over.store(true, .seq_cst);
        sink.send(.{ .started = .{ .drv_path = drv } });
        for (0..4) |n| {
            var lbuf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&lbuf, "{s} line {d}", .{ f.jobs[i].drv.baseName()[33..], n }) catch unreachable;
            sink.send(.{ .log = .{ .drv_path = drv, .line = line } });
            Io.sleep(testing.io, .fromMilliseconds(2), .awake) catch {};
        }
        _ = f.live.fetchSub(1, .seq_cst);
        return true;
    }
    pub fn submit(f: *Fan, a: Allocator, batch: backend.Batch, on_event: Sink, _: *Diag) Error!backend.StatusMap {
        f.jobs = batch.jobs;
        const graph = try a.alloc(fanout.Job, batch.jobs.len);
        for (graph) |*g| g.* = .{ .deps = &.{} };
        const results = try fanout.run(bool, testing.allocator, testing.io, graph, f.limit, .{
            .ctx = f,
            .build = build,
            .ok = struct {
                fn ok(r: *const bool) bool {
                    return r.*;
                }
            }.ok,
            .blocked = struct {
                fn b(_: ?*anyopaque, _: usize, _: usize) bool {
                    return false;
                }
            }.b,
        }, on_event);
        testing.allocator.free(results);
        var out: backend.StatusMap = .empty;
        if (!f.verdicts) return out;
        for (batch.jobs) |j| try out.put(a, try std.fmt.allocPrint(a, "{f}", .{&j.drv}), .ok_status);
        return out;
    }
    pub fn outputs(_: *Fan, a: Allocator, drv: []const u8, _: Sink, d: *Diag) Error![]const backend.OutputEntry {
        const p = StorePath.parse(drv, d) catch return error.Store;
        const base = p.baseName();
        const out = try a.alloc(backend.OutputEntry, 1);
        out[0] = .{ .name = "out", .path = try std.fmt.allocPrint(a, "/nix/store/{s}", .{base[0 .. base.len - 4]}) };
        return out;
    }
    pub fn fetch(_: *Fan, _: []const u8, _: []const u8, _: *Diag) Error!void {}
    pub fn addRoot(_: *Fan, _: []const u8, _: []const u8, _: *Diag) Error!void {}
    pub fn outLinks(_: *Fan, _: []const backend.Link, _: *Diag) Error!void {}
    pub fn noteConnect(_: *Fan, _: u64) void {}
    pub fn noteUpload(_: *Fan, _: backend.Phase) void {}
    pub fn report(_: *Fan, _: *Writer, _: *const Plan, _: u64) Writer.Error!void {}
    pub fn close(_: *Fan) void {}
};

const NoUpload = struct {
    pub fn upload(_: *NoUpload, _: Backend, _: []const StorePath, _: Sink, _: *Diag) Error!upload_mod.Stats {
        return .{};
    }
    pub fn drvs(_: *NoUpload, _: []const StorePath, _: bool, _: Allocator, _: *Diag) anyerror![]const backend.Drv {
        return &.{};
    }
    pub fn rootsAnswered(_: *NoUpload, _: []const StorePath, _: *const plan.NameSet) Allocator.Error!void {}
};

/// A session whose log writes nowhere, and an output to read back.
const TestRun = struct {
    s: *@import("../session.zig").Session,
    out: Writer.Allocating,
    prov: Provenance,

    fn init() !TestRun {
        const s = try @import("../session.zig").Session.create(testing.allocator, testing.io, .{});
        var discard: Writer.Discarding = .init(&.{});
        _ = &discard;
        return .{ .s = s, .out = .init(testing.allocator), .prov = .off(testing.allocator) };
    }
    fn deinit(t: *TestRun) void {
        t.prov.deinit();
        t.out.deinit();
        t.s.destroy();
    }
};

test "a fan-out backend keeps the cap and the log blocks" {
    var t: TestRun = try .init();
    defer t.deinit();
    var null_out: Writer.Discarding = .init(&.{});
    t.s.log.writeTo(&null_out.writer);
    var fan: Fan = .{ .limit = 2 };
    const style: Style = .{ .mode = .ci, .color = false, .fold = false, .quiet = false };
    const rep = try Reporter.createOutput(testing.allocator, &t.s.log, style, &t.out.writer, .{});
    const dp = try Dispatcher.withBackend(testing.allocator, &t.s.log, .of(Fan, &fan), &t.prov, rep);
    defer dp.destroy();
    const names = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    var targets: [4]Target = undefined;
    for (names, &targets) |n, *tg| tg.* = .{ .attr = n, .drv = testDrv(n), .outputs = &.{"out"} };
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var nu: NoUpload = .{};
    const outcomes = try dp.submit(.of(NoUpload, &nu), &targets, &d);
    try testing.expectEqual(4, outcomes.len);
    for (outcomes) |o| try testing.expect(o.success);
    try testing.expect(!fan.over.load(.seq_cst));
    dp.reporter.finish();
    const out = t.out.written();
    for (names) |n| {
        var idx: [8]usize = undefined;
        var k: usize = 0;
        var it = std.mem.splitScalar(u8, out, '\n');
        var i: usize = 0;
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "{s}.drv line ", .{n});
        while (it.next()) |l| : (i += 1) if (std.mem.indexOf(u8, l, needle) != null) {
            idx[k] = i;
            k += 1;
        };
        try testing.expectEqual(4, k);
        try testing.expectEqual(3, idx[3] - idx[0]);
    }
}

/// Builds the dependencies `done`, `cut` and `bad` of one target. `bad`
/// fails, so the store stops `cut` and names only `bad`.
const Stops = struct {
    pub fn queryValid(_: *Stops, a: Allocator, paths: []const StorePath, _: Sink, _: *Diag) Error!plan.NameSet {
        var out: plan.NameSet = .empty;
        for (paths) |*p| if (std.mem.endsWith(u8, p.baseName(), "-done")) try out.put(a, try a.dupe(u8, p.baseName()), {});
        return out;
    }
    pub fn substitute(_: *Stops, _: []const StorePath, _: Sink, _: *Diag) Error!void {}
    pub fn addObjects(_: *Stops, _: []const *Object, _: Sink, _: *Diag) Error!u64 {
        return 0;
    }
    pub fn submit(_: *Stops, a: Allocator, batch: backend.Batch, on_event: Sink, _: *Diag) Error!backend.StatusMap {
        var bufs: [3][256]u8 = undefined;
        const ps = [_]StorePath{ testDrv("done"), testDrv("cut"), testDrv("bad") };
        var strs: [3][]const u8 = undefined;
        for (&ps, &bufs, &strs) |*p, *b, *s| s.* = p.print(b);
        for (strs) |s| on_event.send(.{ .started = .{ .drv_path = s } });
        on_event.send(.{ .failed = .{ .drv_path = strs[2], .reason = "hash mismatch" } });
        for (strs[0..2]) |s| on_event.send(.{ .stopped = .{ .drv_path = s, .built = false } });
        var pbuf: [256]u8 = undefined;
        const why = try std.fmt.allocPrint(a, "1 dependencies of derivation '{s}' failed", .{testDrv("pkg").print(&pbuf)});
        var out: backend.StatusMap = .empty;
        for (batch.jobs) |j| try out.put(a, try std.fmt.allocPrint(a, "{f}", .{&j.drv}), .failed(why, 1));
        return out;
    }
    pub fn outputs(_: *Stops, a: Allocator, drv: []const u8, s: Sink, d: *Diag) Error![]const backend.OutputEntry {
        var f: Fan = .{ .limit = 1 };
        return f.outputs(a, drv, s, d);
    }
    pub fn fetch(_: *Stops, _: []const u8, _: []const u8, _: *Diag) Error!void {}
    pub fn addRoot(_: *Stops, _: []const u8, _: []const u8, _: *Diag) Error!void {}
    pub fn outLinks(_: *Stops, _: []const backend.Link, _: *Diag) Error!void {}
    pub fn noteConnect(_: *Stops, _: u64) void {}
    pub fn noteUpload(_: *Stops, _: backend.Phase) void {}
    pub fn report(_: *Stops, _: *Writer, _: *const Plan, _: u64) Writer.Error!void {}
    pub fn close(_: *Stops) void {}
};

test "a dependency the store stopped is not a success" {
    var t: TestRun = try .init();
    defer t.deinit();
    var null_out: Writer.Discarding = .init(&.{});
    t.s.log.writeTo(&null_out.writer);
    var st: Stops = .{};
    const style: Style = .{ .mode = .tty, .color = false, .fold = false, .quiet = false };
    const rep = try Reporter.createOutput(testing.allocator, &t.s.log, style, &t.out.writer, .{});
    const dp = try Dispatcher.withBackend(testing.allocator, &t.s.log, .of(Stops, &st), &t.prov, rep);
    defer dp.destroy();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var nu: NoUpload = .{};
    const outcomes = try dp.submit(.of(NoUpload, &nu), &.{.{ .attr = "pkg", .drv = testDrv("pkg") }}, &d);
    try testing.expect(!outcomes[0].success);
    dp.reporter.finish();
    const out = t.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "✔  done") != null);
    try testing.expect(std.mem.indexOf(u8, out, "✔  cut") == null);
    try testing.expect(std.mem.indexOf(u8, out, "·  cut stopped after") != null);
    try testing.expect(std.mem.indexOf(u8, out, "✔ 1 succeeded · ✘ 2 failed · 1 stopped") != null);
}

test "a target with no verdict fails" {
    var t: TestRun = try .init();
    defer t.deinit();
    var null_out: Writer.Discarding = .init(&.{});
    t.s.log.writeTo(&null_out.writer);
    var fan: Fan = .{ .limit = 1, .verdicts = false };
    const style: Style = .{ .mode = .ci, .color = false, .fold = false, .quiet = false };
    const rep = try Reporter.createOutput(testing.allocator, &t.s.log, style, &t.out.writer, .{});
    const dp = try Dispatcher.withBackend(testing.allocator, &t.s.log, .of(Fan, &fan), &t.prov, rep);
    defer dp.destroy();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var nu: NoUpload = .{};
    const outcomes = try dp.submit(.of(NoUpload, &nu), &.{.{ .attr = "a", .drv = testDrv("a") }}, &d);
    try testing.expectEqual(1, outcomes.len);
    try testing.expect(!outcomes[0].success);
    try testing.expect(outcomes[0].skipped);
    try testing.expectEqual(0, outcomes[0].outputs.len);
    try testing.expectEqual(1, outcomes[0].exit);
    try testing.expectEqual(1, dp.exit);
    try testing.expect(std.mem.indexOf(u8, outcomes[0].reason.?, "no build result") != null);
}
