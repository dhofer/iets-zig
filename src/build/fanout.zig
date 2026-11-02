//! Running a dependency-ordered job set with a cap on how many run at once,
//! for a backend that schedules the builds itself (the `grpc://` farm: one
//! `BuildDerivation` per derivation).
//!
//! Every event a job produces reaches `on_event` one at a time, under one
//! lock, so the dispatcher's renderer sees one merged stream and a job's log
//! lines stay attributed to it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const event = @import("../remote/event.zig");

/// What one job needs from the scheduler: which jobs must finish first.
pub const Job = struct {
    /// Indices into the job list.
    deps: []const usize,
};

/// What one worker thread does with a job: build it, or record that a
/// dependency failed. `R` is the result type.
pub fn Work(comptime R: type) type {
    return struct {
        ctx: ?*anyopaque,
        /// Builds job `i`, reporting through `sink`.
        build: *const fn (ctx: ?*anyopaque, i: usize, sink: event.Sink) R,
        /// True when a result lets the jobs that depend on it run.
        ok: *const fn (r: *const R) bool,
        /// The result for job `i` when dependency `dep` failed.
        blocked: *const fn (ctx: ?*anyopaque, i: usize, dep: usize) R,
    };
}

/// Runs every job, at most `limit` at a time, a job only once every job it
/// depends on is done. A job whose dependency failed is never built; it gets
/// `Work.blocked`'s result instead. The results are in `gpa`; a job that
/// never ran is null.
pub fn run(comptime R: type, gpa: Allocator, io: Io, jobs: []const Job, limit: usize, work: Work(R), on_event: event.Sink) Allocator.Error![]?R {
    const results = try gpa.alloc(?R, jobs.len);
    @memset(results, null);
    if (jobs.len == 0) return results;
    errdefer gpa.free(results);

    // Who waits on whom, the other way round.
    const dependants = try gpa.alloc(std.ArrayList(usize), jobs.len);
    @memset(dependants, .empty);
    defer {
        for (dependants) |*l| l.deinit(gpa);
        gpa.free(dependants);
    }
    for (jobs, 0..) |j, i| for (j.deps) |d| try dependants[d].append(gpa, i);
    const waiting = try gpa.alloc(usize, jobs.len);
    defer gpa.free(waiting);
    const blocked = try gpa.alloc(?usize, jobs.len);
    defer gpa.free(blocked);
    @memset(blocked, null);
    var ready: std.ArrayList(usize) = .empty;
    defer ready.deinit(gpa);
    try ready.ensureTotalCapacity(gpa, jobs.len);
    for (jobs, waiting, 0..) |j, *w, i| {
        w.* = j.deps.len;
        if (j.deps.len == 0) ready.appendAssumeCapacity(i);
    }

    const State = struct {
        io: Io,
        lock: Io.Mutex = .init,
        wake: Io.Condition = .init,
        ready: *std.ArrayList(usize),
        head: usize = 0,
        remaining: usize,
        waiting: []usize,
        blocked: []?usize,
        results: []?R,
        dependants: []std.ArrayList(usize),
        work: Work(R),
        events_lock: Io.Mutex = .init,
        on_event: event.Sink,

        fn next(s: *@This()) ?usize {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            while (true) {
                if (s.head < s.ready.items.len) {
                    s.head += 1;
                    return s.ready.items[s.head - 1];
                }
                if (s.remaining == 0) return null;
                s.wake.waitUncancelable(s.io, &s.lock);
            }
        }

        fn finish(s: *@This(), i: usize, res: R) void {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            s.results[i] = res;
            const succeeded = s.work.ok(&s.results[i].?);
            s.remaining -= 1;
            for (s.dependants[i].items) |d| {
                if (!succeeded) s.blocked[d] = i;
                s.waiting[d] -= 1;
                // capacity for every job was reserved up front
                if (s.waiting[d] == 0) s.ready.appendAssumeCapacity(d);
            }
            s.wake.broadcast(s.io);
        }

        fn send(ctx: ?*anyopaque, e: event.Event) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.events_lock.lockUncancelable(s.io);
            defer s.events_lock.unlock(s.io);
            s.on_event.send(e);
        }

        fn loop(s: *@This()) void {
            const sink: event.Sink = .{ .ctx = s, .f = send };
            while (s.next()) |i| {
                const dep = blk: {
                    s.lock.lockUncancelable(s.io);
                    defer s.lock.unlock(s.io);
                    break :blk s.blocked[i];
                };
                const res = if (dep) |d| s.work.blocked(s.work.ctx, i, d) else s.work.build(s.work.ctx, i, sink);
                s.finish(i, res);
            }
        }
    };
    var st: State = .{
        .io = io,
        .ready = &ready,
        .remaining = jobs.len,
        .waiting = waiting,
        .blocked = blocked,
        .results = results,
        .dependants = dependants,
        .work = work,
        .on_event = on_event,
    };
    const n = @min(@max(limit, 1), jobs.len);
    const threads = try gpa.alloc(?std.Thread, n - 1);
    defer gpa.free(threads);
    for (threads) |*t| t.* = std.Thread.spawn(.{}, State.loop, .{&st}) catch null;
    st.loop();
    for (threads) |t| if (t) |th| th.join();
    return results;
}

const testing = std.testing;

const Probe = struct {
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    lock: Io.Mutex = .init,
    order: std.ArrayList(usize) = .empty,
    fail: ?usize = null,

    fn build(ctx: ?*anyopaque, i: usize, sink: event.Sink) u32 {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        const n = p.live.fetchAdd(1, .seq_cst) + 1;
        _ = p.peak.fetchMax(n, .seq_cst);
        sink.send(.{ .log = .{ .drv_path = "job", .line = "x" } });
        {
            p.lock.lockUncancelable(testing.io);
            defer p.lock.unlock(testing.io);
            p.order.append(testing.allocator, i) catch {};
        }
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
        _ = p.live.fetchSub(1, .seq_cst);
        return if (p.fail == i) 0 else @intCast(i + 1);
    }

    fn ok(r: *const u32) bool {
        return r.* > 0 and r.* < 1000;
    }

    fn blocked(_: ?*anyopaque, _: usize, dep: usize) u32 {
        return @intCast(1000 + dep);
    }

    fn work(p: *Probe) Work(u32) {
        return .{ .ctx = p, .build = build, .ok = ok, .blocked = blocked };
    }
};

const Counter = struct {
    n: usize = 0,
    pub fn onEvent(c: *Counter, _: event.Event) void {
        c.n += 1;
    }
};

// The cap is the number of builds in flight, whatever the job count.
test "at most limit builds run at once" {
    var p: Probe = .{};
    defer p.order.deinit(testing.allocator);
    var seen: Counter = .{};
    const none: []const usize = &.{};
    const jobs: [6]Job = @splat(.{ .deps = none });
    const out = try run(u32, testing.allocator, testing.io, &jobs, 2, p.work(), .of(Counter, &seen));
    defer testing.allocator.free(out);
    try testing.expectEqual(6, out.len);
    for (out) |r| try testing.expect(r != null and r.? > 0);
    try testing.expectEqual(6, seen.n);
    try testing.expect(p.peak.load(.seq_cst) <= 2);
}

test "dependencies run first" {
    var p: Probe = .{};
    defer p.order.deinit(testing.allocator);
    // 2 needs 1, 1 needs 0.
    const jobs = [_]Job{ .{ .deps = &.{} }, .{ .deps = &.{0} }, .{ .deps = &.{1} } };
    const out = try run(u32, testing.allocator, testing.io, &jobs, 4, p.work(), .ignore);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, p.order.items);
}

test "a failed dependency blocks its dependants" {
    var p: Probe = .{ .fail = 0 };
    defer p.order.deinit(testing.allocator);
    const jobs = [_]Job{ .{ .deps = &.{} }, .{ .deps = &.{0} }, .{ .deps = &.{1} }, .{ .deps = &.{} } };
    const out = try run(u32, testing.allocator, testing.io, &jobs, 4, p.work(), .ignore);
    defer testing.allocator.free(out);
    try testing.expectEqual(0, out[0].?);
    // a blocked job counts as failed, so the failure propagates
    try testing.expectEqual(1000, out[1].?);
    try testing.expectEqual(1001, out[2].?);
    try testing.expectEqual(4, out[3].?);
    for (p.order.items) |i| try testing.expect(i != 1 and i != 2);
}
