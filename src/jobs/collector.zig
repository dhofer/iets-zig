//! `--max-memory-size`: nix-eval-jobs's worker restarts. The main process
//! runs one collector thread per `--workers`, each driving a worker
//! process (`iets eval-jobs --worker ...`) through a line protocol; a
//! worker whose peak RSS crosses the limit finishes its instantiation
//! batch, says `restart`, and the collector spawns a fresh one.
//!
//! Collector to worker: `do <JSON attr path>` or `exit`. Worker to
//! collector: `next` when ready for a path; after `do`: `{"attrs":[..]}`
//! for a set to recurse into, `ok` for a skipped node or a queued job, or
//! an error line; job lines at any time (the worker's instantiator prints
//! them once their batch is registered); `restart` last when it leaves.
//! `nix-config`, before the first `next`, when the root flake has a
//! `nixConfig`: a worker is hushed, so the collector gives the warnings
//! that wait for one.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const Diag = @import("../diag.zig").Diag;
const Evaluator = @import("../eval/Evaluator.zig");
const print = @import("../eval/print.zig");
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Session = @import("../session.zig").Session;
const remote = @import("../remote.zig");
const sys_fs = @import("../sys/fs.zig");
const jobs = @import("../jobs.zig");
const Error = jobs.Error;
const Walk = jobs.Walk;
const line = @import("line.zig");
const Line = line.Line;
const instantiate = @import("instantiate.zig");
const Instantiator = instantiate.Instantiator;

pub const msg_next = "next";
pub const msg_restart = "restart";
pub const msg_ok = "ok";
pub const msg_exit = "exit";
pub const msg_do = "do ";
pub const msg_nix_config = "nix-config";

/// A worker's stdout: whole lines from the walk and the instantiating
/// thread, never interleaved.
pub const Out = struct {
    io: Io,
    fd: std.os.linux.fd_t = 1,
    lock: Io.Mutex = .init,

    pub fn write(o: *Out, bytes: []const u8) void {
        o.lock.lockUncancelable(o.io);
        defer o.lock.unlock(o.io);
        // a collector that is gone stops the worker at its next read
        sys_fs.writeAll(o.fd, bytes) catch return;
        sys_fs.writeAll(o.fd, "\n") catch return;
    }
};

/// `VmHWM` of this process, in MB (Linux only; 0 elsewhere).
pub fn peakRssMb(io: Io) u64 {
    var buf: [8192]u8 = undefined;
    const s = Io.Dir.cwd().readFile(io, "/proc/self/status", &buf) catch return 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        if (!std.mem.startsWith(u8, l, "VmHWM:")) continue;
        var f = std.mem.tokenizeAny(u8, l["VmHWM:".len..], " \t");
        const kb = std.fmt.parseInt(u64, f.next() orelse return 0, 10) catch return 0;
        return kb / 1024;
    }
    return 0;
}

/// The next line without its newline, in `buf`; false at the end of the
/// stream.
fn readLine(r: *Io.Reader, buf: *Writer.Allocating) error{ ReadFailed, OutOfMemory }!bool {
    buf.clearRetainingCapacity();
    const n = r.streamDelimiterEnding(&buf.writer, '\n') catch |e| return switch (e) {
        error.ReadFailed => error.ReadFailed,
        error.WriteFailed => error.OutOfMemory,
    };
    _ = r.peekByte() catch return n > 0;
    r.toss(1);
    return true;
}

/// The worker side (worker.cc:worker): serve `do` requests from stdin until
/// `exit` or the memory limit. `inst` is finished on the way out.
pub fn runWorker(w: *Walk, ev: *Evaluator, root: Value, inst_in: ?*Instantiator, max_memory_mb: u64, out: *Out, d: *Diag) Error!void {
    const gpa = w.gpa;
    var inst = inst_in;
    errdefer if (inst) |i| flush(i, d) catch {};
    var rbuf: [64 << 10]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(w.io, &rbuf);
    var cmd: Writer.Allocating = .init(gpa);
    defer cmd.deinit();
    var resp: Writer.Allocating = .init(gpa);
    defer resp.deinit();
    const chunk_depth = w.config.opts.chunk_depth;
    while (true) {
        out.write(msg_next);
        const more = readLine(&stdin.interface, &cmd) catch |e| return remote.failIo(d, e, "reading from the collector", .{});
        if (!more) break;
        const c = cmd.written();
        if (std.mem.eql(u8, c, msg_exit)) break;
        if (!std.mem.startsWith(u8, c, msg_do)) return d.fail(error.Protocol, "worker error: received invalid command '{s}'", .{c});
        const path = line.decodeStrList(gpa, c[msg_do.len..], d) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            remote.prefix(d, "worker error: bad path", .{});
            return error.Protocol;
        };
        defer {
            for (path) |p| gpa.free(p);
            gpa.free(path);
        }
        var hash = jobs.fnv_basis;
        for (path) |p| hash = jobs.fnvStep(hash, p);
        const depth: u32 = @intCast(path.len);
        resp.clearRetainingCapacity();
        if (depth == chunk_depth and !w.admit(hash, depth, false)) {
            resp.writer.writeAll(msg_ok) catch return error.OutOfMemory;
        } else try request(w, ev, root, path, hash, inst, out, &resp.writer);
        out.write(resp.written());
        if (peakRssMb(w.io) > max_memory_mb) {
            if (inst) |i| {
                inst = null;
                try flush(i, d);
            }
            out.write(msg_restart);
            return;
        }
    }
    if (inst) |i| {
        inst = null;
        try flush(i, d);
    }
}

fn flush(i: *Instantiator, d: *Diag) Error!void {
    const st = try i.finish(d);
    st.close();
}

/// worker.cc:processJobRequest: the response to one `do`.
fn request(w: *Walk, ev: *Evaluator, root: Value, path: []const []const u8, hash: u64, inst: ?*Instantiator, out: *Out, resp: *Writer) Error!void {
    const gpa = w.gpa;
    const depth: u32 = @intCast(path.len);
    const t0 = Io.Clock.awake.now(w.io).toNanoseconds();
    const alloc0 = ev.local.arena.used;
    const r = if (w.findAlongAttrPath(ev, root, path)) |v| w.node(ev, v, path, hash) else |e| e;
    const ms: u64 = @intCast(@divTrunc(Io.Clock.awake.now(w.io).toNanoseconds() - t0, std.time.ns_per_ms));
    const stats = try line.statsJson(gpa, ms, ev.local.arena.used -| alloc0);
    var stats_owned = true;
    defer if (stats_owned) gpa.free(stats);
    const oom = error.OutOfMemory;
    const n = r catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EvalFailed => {
            if (!w.admit(hash, depth, true)) {
                ev.clearFailure();
                return resp.writeAll(msg_ok) catch oom;
            }
            var l: Line = .{ .err = try jobs.errorLine(ev, gpa, path) };
            defer l.deinit(gpa);
            l.err.stats = stats;
            stats_owned = false;
            return l.render(resp) catch oom;
        },
    };
    switch (n) {
        .job => |j| {
            var l: Line = .{ .job = j };
            stats_owned = false;
            l.job.putExtra(gpa, "stats", stats) catch |e| {
                l.deinit(gpa);
                return e;
            };
            if (inst) |i| {
                i.push(l);
            } else {
                defer l.deinit(gpa);
                const bytes = try l.renderAlloc(gpa);
                defer gpa.free(bytes);
                out.write(bytes);
            }
            resp.writeAll(msg_ok) catch return oom;
        },
        .recurse => |attrs| {
            const names = try print.lexicographic(ev, attrs);
            defer ev.gpa.free(names);
            const attr = try jobs.attrJoin(gpa, path);
            defer gpa.free(attr);
            (struct {
                fn f(wr: *Writer, a: []const u8, p: []const []const u8, e: *Evaluator, ns: []const *value.Attr) Writer.Error!void {
                    try wr.writeAll("{\"attr\":");
                    try line.writeStr(wr, a);
                    try wr.writeAll(",\"attrPath\":");
                    try line.writeStrList(wr, p);
                    try wr.writeAll(",\"attrs\":[");
                    for (ns, 0..) |x, i| {
                        if (i > 0) try wr.writeByte(',');
                        try line.writeStr(wr, e.interner.name(x.sym));
                    }
                    try wr.writeAll("]}");
                }
            }).f(resp, attr, path, ev, names) catch return oom;
        },
        .skip => resp.writeAll(msg_ok) catch return oom,
    }
}

/// An attribute path the collector owns: its strings and the slice.
const Path = []const []const u8;

fn pathOrder(_: void, a: Path, b: Path) std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        const o = std.mem.order(u8, x, y);
        if (o != .eq) return o;
    }
    return std.math.order(a.len, b.len);
}

fn freePath(gpa: Allocator, p: Path) void {
    for (p) |s| gpa.free(s);
    gpa.free(p);
}

const Control = union(enum) {
    next,
    restart,
    ok,
    /// Owned names.
    attrs: Path,
    err: Line,
};

/// One worker process and its pipes.
const Proc = struct {
    c: *Collector,
    child: std.process.Child,
    from_buf: []u8,
    from: Io.File.Reader,
    buf: Writer.Allocating,

    fn spawn(c: *Collector, d: *Diag) Error!*Proc {
        _ = c.spawned.fetchAdd(1, .monotonic);
        const p = try c.gpa.create(Proc);
        errdefer c.gpa.destroy(p);
        const from_buf = try c.gpa.alloc(u8, 1 << 20);
        errdefer c.gpa.free(from_buf);
        const child = std.process.spawn(c.io, .{
            .argv = c.argv,
            .environ_map = c.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        }) catch |e| return remote.failIo(d, e, "spawning worker process", .{});
        p.* = .{ .c = c, .child = child, .from_buf = from_buf, .from = undefined, .buf = .init(c.gpa) };
        p.from = p.child.stdout.?.readerStreaming(c.io, from_buf);
        return p;
    }

    /// Kills a worker still running, and frees it.
    fn destroy(p: *Proc) void {
        const gpa = p.c.gpa;
        if (p.child.id != null) p.child.kill(p.c.io);
        p.buf.deinit();
        gpa.free(p.from_buf);
        gpa.destroy(p);
    }

    fn send(p: *Proc, msg: []const u8, d: *Diag) Error!void {
        const f = p.child.stdin orelse return d.fail(error.Io, "writing to worker: Broken pipe", .{});
        var w = f.writerStreaming(p.c.io, &.{});
        w.interface.writeAll(msg) catch return d.fail(error.Io, "writing to worker: Broken pipe", .{});
        w.interface.writeAll("\n") catch return d.fail(error.Io, "writing to worker: Broken pipe", .{});
    }

    /// nix-eval-jobs.cc:handleBrokenWorkerPipe: what a dead worker means.
    fn broken(p: *Proc, what: []const u8, d: *Diag) Error {
        if (p.child.stdin) |f| f.close(p.c.io);
        p.child.stdin = null;
        const term = p.child.wait(p.c.io) catch |e|
            return d.fail(error.Protocol, "while {s}, waitpid for evaluation worker failed: {s}", .{ what, remote.ioText(e) });
        return switch (term) {
            .exited => |code| if (code == 1)
                d.fail(error.Protocol, "while {s}, evaluation worker exited with exit code 1, (possible infinite recursion)", .{what})
            else
                d.fail(error.Protocol, "while {s}, evaluation worker exited with {d}", .{ what, code }),
            .signal => |sig| if (@backingInt(sig) == 9)
                d.fail(error.Protocol, "while {s}, evaluation worker got killed by SIGKILL, maybe memory limit reached?", .{what})
            else
                d.fail(error.Protocol, "while {s}, evaluation worker crashed with signal {d}", .{ what, @backingInt(sig) }),
            else => d.fail(error.Protocol, "while {s}, evaluation worker exited with -1", .{what}),
        };
    }

    fn readLine_(p: *Proc, d: *Diag) Error!bool {
        return readLine(&p.from.interface, &p.buf) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => remote.failIo(d, p.from.err orelse error.ReadFailed, "reading from worker", .{}),
        };
    }

    /// The next control line; job lines on the way go to the sink.
    fn readControl(p: *Proc, what: []const u8, d: *Diag) Error!Control {
        const gpa = p.c.gpa;
        while (true) {
            if (!try p.readLine_(d)) return p.broken(what, d);
            const s = p.buf.written();
            if (std.mem.eql(u8, s, msg_next)) return .next;
            if (std.mem.eql(u8, s, msg_restart)) return .restart;
            if (std.mem.eql(u8, s, msg_ok)) return .ok;
            if (std.mem.eql(u8, s, msg_nix_config)) {
                p.c.s.ignored.nixConfigSeen();
                continue;
            }
            if (s.len == 0 or s[0] != '{')
                return d.fail(error.Protocol, "worker error: unexpected line '{s}'", .{s});
            var fields = line.splitObject(gpa, s, d) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return d.fail(error.Protocol, "Received invalid JSON from worker: {s}\n json: '{s}'", .{ d.message(), s });
            };
            defer {
                for (fields.items) |f| gpa.free(f.key);
                fields.deinit(gpa);
            }
            var has_attr = false;
            var err_raw: ?[]const u8 = null;
            for (fields.items) |f| {
                if (std.mem.eql(u8, f.key, "attrs")) {
                    const names = line.decodeStrList(gpa, f.value, d) catch |e| {
                        if (e == error.OutOfMemory) return error.OutOfMemory;
                        return d.fail(error.Protocol, "Received invalid JSON from worker: {s}", .{d.message()});
                    };
                    return .{ .attrs = names };
                }
                if (std.mem.eql(u8, f.key, "attr")) has_attr = true;
                if (std.mem.eql(u8, f.key, "error") and err_raw == null) err_raw = f.value;
            }
            if (!has_attr) {
                const msg = if (err_raw) |raw| line.decodeString(gpa, raw, d) catch null else null;
                defer if (msg) |m| gpa.free(m);
                return d.fail(error.Protocol, "worker error: {s}", .{msg orelse ""});
            }
            const l = try parseLine(gpa, s, d);
            switch (l) {
                .err => return .{ .err = l },
                .job => p.c.sink.send(l),
            }
        }
    }

    /// Reads the job lines a leaving worker still prints, then reaps it.
    fn drain(p: *Proc, d: *Diag) Error!void {
        if (p.child.stdin) |f| f.close(p.c.io);
        p.child.stdin = null;
        while (try p.readLine_(d)) {
            const s = p.buf.written();
            if (s.len > 0 and s[0] == '{') p.c.sink.send(try parseLine(p.c.gpa, s, d));
        }
        _ = p.child.wait(p.c.io) catch {};
    }
};

fn parseLine(gpa: Allocator, s: []const u8, d: *Diag) Error!Line {
    return Line.parse(gpa, s, d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Protocol => error.Protocol,
        error.Store => error.Store,
    };
}

/// nix-eval-jobs.cc:main's collector threads, each with its own worker
/// process, until the tree is walked.
pub const Collector = struct {
    gpa: Allocator,
    io: Io,
    s: *Session,
    /// The worker's command line, `iets eval-jobs --worker ...`.
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
    /// Thread-safe: every line reaches it in completion order.
    sink: jobs.Sink,
    /// Worker processes spawned so far: `--workers` plus one per restart.
    spawned: std.atomic.Value(usize) = .init(0),
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    todo: std.PriorityQueue(Path, void, pathOrder) = .empty,
    active: std.ArrayList(Path) = .empty,
    /// The first collector's error; the walk stops on it.
    failed: ?struct { err: Error, msg: []const u8 } = null,

    pub fn deinit(c: *Collector) void {
        while (c.todo.pop()) |p| freePath(c.gpa, p);
        c.todo.deinit(c.gpa);
        for (c.active.items) |p| freePath(c.gpa, p);
        c.active.deinit(c.gpa);
        if (c.failed) |f| c.gpa.free(f.msg);
    }

    /// Runs `workers` collector threads from the root; the first failure,
    /// its message on `d`.
    pub fn run(c: *Collector, workers: usize, d: *Diag) Error!void {
        try c.todo.push(c.gpa, try c.gpa.alloc([]const u8, 0));
        const n = @max(workers, 1);
        const threads = try c.gpa.alloc(?std.Thread, n);
        defer c.gpa.free(threads);
        for (threads) |*t| t.* = std.Thread.spawn(.{ .stack_size = 16 << 20 }, thread, .{c}) catch |e| blk: {
            c.fail(remote.failIo(d, e, "cannot start a collector thread", .{}), d.message());
            break :blk null;
        };
        for (threads) |t| if (t) |x| x.join();
        if (c.failed) |f| return d.fail(f.err, "{s}", .{f.msg});
    }

    fn fail(c: *Collector, err: Error, msg: []const u8) void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        if (c.failed == null) c.failed = .{ .err = err, .msg = c.gpa.dupe(u8, msg) catch "out of memory" };
        c.cond.broadcast(c.io);
    }

    fn thread(c: *Collector) void {
        var d: Diag = .init(c.gpa);
        defer d.deinit();
        var proc: ?*Proc = null;
        defer if (proc) |p| p.destroy();
        c.collect(&proc, &d) catch |e| c.fail(e, d.message());
    }

    fn nextJob(c: *Collector) ?Path {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        while (true) {
            if ((c.todo.count() == 0 and c.active.items.len == 0) or c.failed != null) return null;
            if (c.todo.pop()) |p| {
                c.active.append(c.gpa, p) catch {
                    freePath(c.gpa, p);
                    return null;
                };
                return p;
            }
            c.cond.waitUncancelable(c.io, &c.lock);
        }
    }

    /// `path` is done; its children, owned, go to the queue.
    fn done(c: *Collector, path: Path, children: []Path) Allocator.Error!void {
        c.lock.lockUncancelable(c.io);
        defer c.lock.unlock(c.io);
        defer c.cond.broadcast(c.io);
        for (c.active.items, 0..) |p, i| if (p.ptr == path.ptr) {
            _ = c.active.swapRemove(i);
            freePath(c.gpa, p);
            break;
        };
        var pushed: usize = 0;
        errdefer for (children[pushed..]) |p| freePath(c.gpa, p);
        for (children) |p| {
            try c.todo.push(c.gpa, p);
            pushed += 1;
        }
    }

    fn collect(c: *Collector, proc: *?*Proc, d: *Diag) Error!void {
        const gpa = c.gpa;
        while (true) {
            const path = c.nextJob() orelse {
                if (proc.*) |p| {
                    // A worker whose pending status is `restart` is leaving on its own.
                    const ctl = try p.readControl("checking worker process", d);
                    freeControl(gpa, ctl);
                    if (ctl != .restart) try p.send(msg_exit, d);
                    try p.drain(d);
                }
                return;
            };
            while (true) {
                if (proc.* == null) proc.* = try Proc.spawn(c, d);
                const ctl = try proc.*.?.readControl("checking worker process", d);
                switch (ctl) {
                    .next => break,
                    .restart => {
                        const old = proc.*.?;
                        proc.* = null;
                        defer old.destroy();
                        try old.drain(d);
                    },
                    else => {
                        freeControl(gpa, ctl);
                        return d.fail(error.Protocol, "worker error: unexpected response while idle", .{});
                    },
                }
            }
            const p = proc.*.?;
            const joined = try jobs.attrJoin(gpa, path);
            defer gpa.free(joined);
            {
                var aw: Writer.Allocating = .init(gpa);
                defer aw.deinit();
                aw.writer.writeAll(msg_do) catch return error.OutOfMemory;
                line.writeStrList(&aw.writer, path) catch return error.OutOfMemory;
                try p.send(aw.written(), d);
            }
            const what = try std.fmt.allocPrint(gpa, "reading result for attrPath '{s}'", .{joined});
            defer gpa.free(what);
            var children: std.ArrayList(Path) = .empty;
            defer children.deinit(gpa);
            errdefer for (children.items) |x| freePath(gpa, x);
            switch (try p.readControl(what, d)) {
                .ok => {},
                .attrs => |names| {
                    defer gpa.free(names);
                    var k: usize = 0;
                    errdefer for (names[k..]) |x| gpa.free(x);
                    try children.ensureTotalCapacity(gpa, names.len);
                    for (names) |n| {
                        const child = try gpa.alloc([]const u8, path.len + 1);
                        var m: usize = 0;
                        errdefer {
                            for (child[0..m]) |x| gpa.free(x);
                            gpa.free(child);
                        }
                        for (path) |x| {
                            child[m] = try gpa.dupe(u8, x);
                            m += 1;
                        }
                        child[m] = n;
                        k += 1;
                        children.appendAssumeCapacity(child);
                    }
                },
                .err => |l| {
                    const fatal = l.err.fatal;
                    const text = if (fatal) try gpa.dupe(u8, l.err.message) else null;
                    defer if (text) |t| gpa.free(t);
                    c.sink.send(l);
                    if (fatal) return d.fail(error.Protocol, "{s}", .{text.?});
                },
                else => |ctl| {
                    freeControl(gpa, ctl);
                    return d.fail(error.Protocol, "worker error: unexpected status for '{s}'", .{joined});
                },
            }
            const owned = try children.toOwnedSlice(gpa);
            defer gpa.free(owned);
            try c.done(path, owned);
        }
    }
};

fn freeControl(gpa: Allocator, ctl: Control) void {
    switch (ctl) {
        .attrs => |a| freePath(gpa, a),
        .err => |l| {
            var x = l;
            x.deinit(gpa);
        },
        else => {},
    }
}

const testing = std.testing;

test "paths order as Rust's Vec<String>" {
    try testing.expectEqual(.lt, pathOrder({}, &.{"a"}, &.{ "a", "b" }));
    try testing.expectEqual(.gt, pathOrder({}, &.{"b"}, &.{ "a", "z" }));
    try testing.expectEqual(.eq, pathOrder({}, &.{ "a", "b" }, &.{ "a", "b" }));
    try testing.expectEqual(.lt, pathOrder({}, &.{}, &.{"a"}));
}

test "readLine splits on newlines and keeps a last unterminated line" {
    var r: Io.Reader = .fixed("next\n{\"a\":1}\nlast");
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try testing.expect(try readLine(&r, &buf));
    try testing.expectEqualStrings("next", buf.written());
    try testing.expect(try readLine(&r, &buf));
    try testing.expectEqualStrings("{\"a\":1}", buf.written());
    try testing.expect(try readLine(&r, &buf));
    try testing.expectEqualStrings("last", buf.written());
    try testing.expect(!try readLine(&r, &buf));
}

test "peak RSS is read from /proc" {
    try testing.expect(peakRssMb(testing.io) > 0);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Collector);
}
