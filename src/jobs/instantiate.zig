//! The instantiation nix-eval-jobs does inside `derivationStrict`: every
//! job's `.drv` and its input closure registered through the daemon. Here
//! it happens in batches on a thread beside the walk: one
//! `build.upload.StreamUpload` per batch over the worker backend, then
//! `--gc-roots-dir` roots (worker.cc:registerGCRoot) and the batch's lines
//! go on to the sink.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Evaluator = @import("../eval/Evaluator.zig");
const remote = @import("../remote.zig");
const worker = remote.worker;
const Connection = worker.Connection;
const Transport = worker.Transport;
const backend = @import("../build/backend.zig");
const upload = @import("../build/upload.zig");
const StreamUpload = upload.StreamUpload;
const EvalInputs = @import("../api/build.zig").EvalInputs;
const locate = @import("../store/locate.zig");
const StorePath = @import("../store/path.zig").StorePath;
const jobs = @import("../jobs.zig");
const Error = jobs.Error;
const line = @import("line.zig");
const Line = line.Line;
const Job = line.Job;

/// The most lines per daemon round trip.
pub const batch = 256;

pub const Stats = struct {
    upload: upload.Stats = .{},
    roots: usize = 0,
};

/// The daemon side: one connection and the upload that remembers what it
/// holds.
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    worker: *backend.Worker,
    /// The evaluation's tables, read from the instantiating thread under
    /// their locks.
    inputs: *EvalInputs,
    up: StreamUpload,
    gc_roots_dir: ?[]const u8,
    stats: Stats = .{},

    pub fn open(cx: backend.Context, transport: *const Transport, gc_roots_dir: ?[]const u8, ev: *Evaluator, nix: locate.Nix, d: *Diag) Error!*Store {
        const w = try backend.Worker.open(cx, transport, .default(), .ignore, d);
        errdefer w.close();
        if (gc_roots_dir) |dir| Io.Dir.cwd().createDirPath(cx.io, dir) catch |e|
            return remote.failIo(d, e, "cannot create '{s}'", .{dir});
        const inputs = try cx.gpa.create(EvalInputs);
        errdefer cx.gpa.destroy(inputs);
        inputs.* = .init(ev);
        const st = try cx.gpa.create(Store);
        st.* = .{
            .gpa = cx.gpa,
            .io = cx.io,
            .worker = w,
            .inputs = inputs,
            .up = .init(cx.gpa, cx.io, inputs.inputs(), nix),
            .gc_roots_dir = gc_roots_dir,
        };
        return st;
    }

    pub fn close(st: *Store) void {
        st.up.deinit();
        st.inputs.deinit();
        st.gpa.destroy(st.inputs);
        st.worker.close();
        st.gpa.destroy(st);
    }

    /// The daemon connection, for what runs after the walk.
    pub fn connection(st: *Store) *Connection {
        return st.worker.conn;
    }

    /// Registers the closures of `js`' drvs that the daemon lacks, then
    /// roots each job's `.drv`.
    pub fn instantiate(st: *Store, js: []const *const Job, d: *Diag) Error!void {
        const t0 = now(st.io);
        const roots = try st.gpa.alloc(StorePath, js.len);
        defer st.gpa.free(roots);
        for (js, roots) |j, *r| r.* = j.drv_path;
        var s = try st.up.upload(.of(backend.Worker, st.worker), roots, .ignore, d);
        if (st.gc_roots_dir) |dir| for (js) |j| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const root = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, j.drv_path.baseName() }) catch
                return d.fail(error.Io, "cannot create '{s}': File name too long", .{dir});
            if (exists(st.io, root)) continue;
            var pbuf: [std.fs.max_path_bytes]u8 = undefined;
            try st.worker.addRoot(j.drv_path.print(&pbuf), root, d);
            st.stats.roots += 1;
        };
        s.time = now(st.io) - t0;
        st.stats.upload.merge(s);
    }
};

/// Whether anything is at `p`, a dangling link included (`symlink_metadata`).
fn exists(io: Io, p: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn now(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).toNanoseconds());
}

/// Where an instantiated batch goes, in walk order; it takes the lines over.
pub const BatchSink = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, lines: []Line, d: *Diag) Error!void,
};

/// The thread: lines in, instantiated batches out to the sink, in order.
pub const Instantiator = struct {
    gpa: Allocator,
    io: Io,
    store: *Store,
    sink: BatchSink,
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(Line) = .empty,
    closed: bool = false,
    /// The thread stopped on an error; later lines are dropped.
    failed: bool = false,
    result: Error!void = {},
    /// The thread's error message.
    diag: Diag,
    thread: std.Thread = undefined,

    pub fn start(gpa: Allocator, io: Io, store: *Store, sink: BatchSink, d: *Diag) Error!*Instantiator {
        const i = try gpa.create(Instantiator);
        errdefer gpa.destroy(i);
        i.* = .{ .gpa = gpa, .io = io, .store = store, .sink = sink, .diag = .init(gpa) };
        i.thread = std.Thread.spawn(.{ .stack_size = 64 << 20 }, run, .{i}) catch |e|
            return remote.failIo(d, e, "cannot start the instantiate thread", .{});
        return i;
    }

    /// Queues `l`; the instantiator takes it over.
    pub fn push(i: *Instantiator, l: Line) void {
        var x = l;
        i.lock.lockUncancelable(i.io);
        defer i.lock.unlock(i.io);
        if (i.failed) return x.deinit(i.gpa);
        i.queue.append(i.gpa, x) catch return x.deinit(i.gpa);
        i.cond.signal(i.io);
    }

    /// Flushes the last batch and returns the store for later use; else the
    /// thread's error, its message on `d`. Frees `i`.
    pub fn finish(i: *Instantiator, d: *Diag) Error!*Store {
        {
            i.lock.lockUncancelable(i.io);
            defer i.lock.unlock(i.io);
            i.closed = true;
            i.cond.signal(i.io);
        }
        i.thread.join();
        const st = i.store;
        const r = i.result;
        if (r) |_| {} else |_| if (i.diag.msg) |m| {
            if (d.msg) |old| d.gpa.free(old);
            d.msg = d.gpa.dupe(u8, m) catch null;
        }
        for (i.queue.items) |*l| l.deinit(i.gpa);
        i.queue.deinit(i.gpa);
        i.diag.deinit();
        i.gpa.destroy(i);
        r catch |e| {
            st.close();
            return e;
        };
        return st;
    }

    /// The first line and what queued behind it, up to `batch`; null once
    /// closed and drained. The caller owns the slice.
    fn next(i: *Instantiator) Allocator.Error!?[]Line {
        i.lock.lockUncancelable(i.io);
        defer i.lock.unlock(i.io);
        while (i.queue.items.len == 0) {
            if (i.closed) return null;
            i.cond.waitUncancelable(i.io, &i.lock);
        }
        const n = @min(batch, i.queue.items.len);
        const out = try i.gpa.dupe(Line, i.queue.items[0..n]);
        i.queue.replaceRangeAssumeCapacity(0, n, &.{});
        return out;
    }

    fn run(i: *Instantiator) void {
        i.result = i.loop();
        if (i.result) |_| {} else |_| {
            i.lock.lockUncancelable(i.io);
            defer i.lock.unlock(i.io);
            i.failed = true;
        }
    }

    fn loop(i: *Instantiator) Error!void {
        while (try i.next()) |lines| {
            defer i.gpa.free(lines);
            var handed = false;
            defer if (!handed) for (lines) |*l| l.deinit(i.gpa);
            var js: std.ArrayList(*const Job) = .empty;
            defer js.deinit(i.gpa);
            for (lines) |*l| switch (l.*) {
                .job => |*j| try js.append(i.gpa, j),
                .err => {},
            };
            if (js.items.len > 0) try i.store.instantiate(js.items, &i.diag);
            handed = true;
            try i.sink.f(i.sink.ctx, lines, &i.diag);
        }
    }
};

test "a batch takes at most `batch` lines" {
    var i: Instantiator = .{ .gpa = std.testing.allocator, .io = std.testing.io, .store = undefined, .sink = undefined, .diag = .init(std.testing.allocator) };
    defer i.diag.deinit();
    defer i.queue.deinit(i.gpa);
    const empty: Line = .{ .err = .{ .attr = &.{}, .attr_path = &.{}, .message = &.{} } };
    for (0..batch + 3) |_| try i.queue.append(i.gpa, empty);
    const first = (try i.next()).?;
    defer i.gpa.free(first);
    try std.testing.expectEqual(batch, first.len);
    try std.testing.expectEqual(3, i.queue.items.len);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Store);
    std.testing.refAllDecls(Instantiator);
}
