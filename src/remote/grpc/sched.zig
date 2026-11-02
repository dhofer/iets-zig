//! The `Scheduler.Schedule` stream (client/build.cc:`GrpcStore::Run`): a
//! `Want` for each derivation whose inputs are built, answered `Assigned`
//! (build it on that worker), `Cached` or `Unplaceable`. The worker turns a
//! `BuildDerivation` away unless the scheduler announced it.
//!
//! The scheduler keeps soft state only, so a stream that breaks or says
//! `Restarting` is opened again and every unanswered `Want` goes out again
//! (`scheduleUntilDone`). One pump thread reads the stream; the threads of a
//! batch `place` their derivations and wait for the answer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const remote = @import("../../remote.zig");
const proto = @import("proto.zig");
const config = @import("config.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const Health = @import("health.zig").Health;

pub const Answer = union(enum) {
    /// `worker` is owned by the caller's arena.
    assigned: struct { worker: []const u8, assign_id: u64 },
    cached,
};

/// One placed derivation: its `Want` (owned, re-sent after a reconnect) and
/// the scheduler's messages for it, oldest first.
const Waiter = struct {
    arena: std.heap.ArenaAllocator,
    want: proto.Want,
    msgs: std.ArrayList(Msg) = .empty,
    /// Removed from `open`: no more messages will come.
    closed: bool = false,
};

const Msg = union(enum) {
    assigned: struct { worker: []const u8, assign_id: u64 },
    cached,
    unplaceable: []const u8,
};

pub const Sched = struct {
    gpa: Allocator,
    io: Io,
    c: *Client,
    lock: Io.Mutex = .init,
    cond: Io.Condition = .init,
    waiters: std.StringHashMapUnmanaged(*Waiter) = .empty,
    fatal: ?[]const u8 = null,
    /// The stream being read, which `place` sends on; null between streams.
    call: ?*client_mod.Call = null,
    send_lock: Io.Mutex = .init,
    stop: bool = false,
    thread: ?std.Thread = null,
    grace_ns: i96,
    /// What the batch has learnt about the addresses it was assigned.
    health: Health,

    pub fn open(gpa: Allocator, c: *Client) !*Sched {
        const s = try gpa.create(Sched);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = c.io,
            .c = c,
            .grace_ns = @as(i96, c.cfg.restart_grace) * std.time.ns_per_s,
            .health = .init(gpa, c.io),
        };
        s.thread = try std.Thread.spawn(.{}, pump, .{s});
        return s;
    }

    pub fn close(s: *Sched) void {
        {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            s.stop = true;
            if (s.call) |k| k.conn.cancel(k.s);
            s.cond.broadcast(s.io);
        }
        if (s.thread) |t| t.join();
        var it = s.waiters.valueIterator();
        while (it.next()) |w| freeWaiter(s.gpa, w.*);
        s.waiters.deinit(s.gpa);
        if (s.fatal) |f| s.gpa.free(f);
        s.health.deinit();
        s.gpa.destroy(s);
    }

    fn freeWaiter(gpa: Allocator, w: *Waiter) void {
        w.arena.deinit();
        gpa.destroy(w);
    }

    /// `restart-grace`, which also bounds the refusals in `build.build`.
    pub fn grace(s: *const Sched) i96 {
        return s.grace_ns;
    }

    /// Sends `want` and waits for the scheduler's answer. `Unplaceable` is
    /// advisory: the `Want` stays queued, and fails only once
    /// `restart-grace` passes without an `Assigned`.
    pub fn place(s: *Sched, arena: Allocator, want: proto.Want, d: *Diag) remote.Error!Answer {
        const w = try s.gpa.create(Waiter);
        w.* = .{ .arena = .init(s.gpa), .want = undefined };
        w.want = dupeWant(w.arena.allocator(), want) catch |e| {
            freeWaiter(s.gpa, w);
            return e;
        };
        const drv = w.want.drv_path;
        {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            if (s.fatal) |f| {
                freeWaiter(s.gpa, w);
                return d.fail(error.Protocol, "{s}", .{f});
            }
            const gop = s.waiters.getOrPut(s.gpa, drv) catch |e| {
                freeWaiter(s.gpa, w);
                return e;
            };
            if (gop.found_existing) gop.value_ptr.*.closed = true;
            gop.value_ptr.* = w;
        }
        s.sendWants(&.{w.want});
        defer {
            s.lock.lockUncancelable(s.io);
            if (s.waiters.get(drv)) |cur| if (cur == w) {
                _ = s.waiters.remove(drv);
            };
            s.lock.unlock(s.io);
            freeWaiter(s.gpa, w);
        }

        var deadline: ?i96 = null;
        var reason: []const u8 = "";
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        while (true) {
            if (w.msgs.items.len > 0) {
                const m = w.msgs.orderedRemove(0);
                switch (m) {
                    .assigned => |a| return .{ .assigned = .{ .worker = try arena.dupe(u8, a.worker), .assign_id = a.assign_id } },
                    .cached => return .cached,
                    .unplaceable => |r| {
                        if (deadline == null) {
                            s.c.log.errln("{s}: {s}, waiting up to {d}s for a worker", .{ drv, r, @divTrunc(s.grace_ns, std.time.ns_per_s) });
                            deadline = nowNs(s.io) + s.grace_ns;
                        }
                        reason = r;
                    },
                }
                continue;
            }
            if (w.closed or s.fatal != null or s.stop) {
                const e = s.fatal orelse "the scheduler stream closed";
                return d.fail(error.Protocol, "{s}", .{e});
            }
            if (deadline) |dl| {
                const left = dl - nowNs(s.io);
                if (left <= 0) return d.fail(error.Store, "{s}: {s}", .{ drv, reason });
                s.cond.waitTimeout(s.io, &s.lock, .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } }) catch {};
            } else s.cond.waitUncancelable(s.io, &s.lock);
        }
    }

    fn dupeWant(a: Allocator, w: proto.Want) Allocator.Error!proto.Want {
        var out = w;
        out.drv_path = try a.dupe(u8, w.drv_path);
        out.system = try a.dupe(u8, w.system);
        inline for (.{ "out_keys", "inputs", "required_features" }) |f| {
            const src = @field(w, f);
            const dst = try a.alloc([]const u8, src.len);
            for (src, dst) |x, *y| y.* = try a.dupe(u8, x);
            @field(out, f) = dst;
        }
        return out;
    }

    /// Sends a batch of wants on the current stream, if there is one; a
    /// stream opened later sends every open want itself.
    fn sendWants(s: *Sched, wants: []const proto.Want) void {
        s.send_lock.lockUncancelable(s.io);
        defer s.send_lock.unlock(s.io);
        const k = blk: {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            break :blk s.call orelse return;
        };
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const msgs = arena.allocator().alloc(proto.ClientMsg, wants.len) catch return;
        for (wants, msgs) |w, *m| m.* = .{ .msg = .{ .want = w } };
        // a failed send shows up as the stream's end in the pump
        k.send(proto.ClientMsgs{ .msgs = msgs }) catch {};
    }

    /// Every waiting `place` fails with this text.
    fn fail(s: *Sched, text: []const u8) void {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        if (s.fatal == null) s.fatal = s.gpa.dupe(u8, text) catch "the scheduler stream failed";
        var it = s.waiters.valueIterator();
        while (it.next()) |w| w.*.closed = true;
        s.waiters.clearRetainingCapacity();
        s.cond.broadcast(s.io);
    }

    const End = union(enum) {
        restarting,
        closed,
        failed: config.Status,
    };

    fn pump(s: *Sched) void {
        const first_pause: i96 = 500 * std.time.ns_per_ms;
        var pause = first_pause;
        var give_up: ?i96 = null;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        while (true) {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            var answered = false;
            const end = s.stream(a, &answered, &d) catch |e| {
                s.fail(if (e == error.OutOfMemory) "out of memory" else d.message());
                return;
            };
            if (s.isStopped()) return;
            const status = switch (end) {
                .restarting => {
                    pause = first_pause;
                    give_up = null;
                    continue;
                },
                .closed => {
                    var buf: [512]u8 = undefined;
                    s.fail(std.fmt.bufPrint(&buf, "the scheduler at '{s}' closed the stream", .{s.c.cfg.authority}) catch "the scheduler closed the stream");
                    return;
                },
                .failed => |st| st,
            };
            if (!schedulerGone(status)) {
                std.debug.assert(s.c.statusError(status, "Schedule", &d) == error.Protocol);
                s.fail(d.message());
                return;
            }
            const now = nowNs(s.io);
            if (answered or give_up == null) {
                give_up = now + s.grace_ns;
                pause = first_pause;
            }
            if (now + pause > give_up.?) {
                std.debug.assert(s.c.statusError(status, "Schedule", &d) == error.Protocol);
                s.fail(d.message());
                return;
            }
            s.c.log.errln("scheduler at {s}: {s}, reconnecting", .{ s.c.cfg.authority, config.firstLine(status.message) });
            if (s.sleepUnlessStopped(pause)) return;
            pause = @min(pause * 2, 8 * std.time.ns_per_s);
        }
    }

    fn isStopped(s: *Sched) bool {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        return s.stop;
    }

    fn sleepUnlessStopped(s: *Sched, ns: i96) bool {
        const until = nowNs(s.io) + ns;
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        while (!s.stop) {
            const left = until - nowNs(s.io);
            if (left <= 0) return false;
            s.cond.waitTimeout(s.io, &s.lock, .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } }) catch {};
        }
        return true;
    }

    /// One `Schedule` stream until it ends: whether it answered anything,
    /// and how.
    fn stream(s: *Sched, a: Allocator, answered: *bool, d: *Diag) remote.Error!End {
        var status: config.Status = undefined;
        const hs = try s.c.headers(a, d);
        var k = s.c.start(a, "/nix.remote.Scheduler/Schedule", hs.items, &status) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Status => return .{ .failed = status },
        };
        defer k.deinit();
        {
            s.send_lock.lockUncancelable(s.io);
            defer s.send_lock.unlock(s.io);
            var wants: std.ArrayList(proto.Want) = .empty;
            {
                s.lock.lockUncancelable(s.io);
                defer s.lock.unlock(s.io);
                if (s.stop) return .closed;
                var it = s.waiters.valueIterator();
                while (it.next()) |w| try wants.append(a, w.*.want);
                s.call = &k;
            }
            if (wants.items.len > 0) {
                const msgs = try a.alloc(proto.ClientMsg, wants.items.len);
                for (wants.items, msgs) |w, *m| m.* = .{ .msg = .{ .want = w } };
                k.send(proto.ClientMsgs{ .msgs = msgs }) catch {};
            }
        }
        defer {
            s.send_lock.lockUncancelable(s.io);
            s.lock.lockUncancelable(s.io);
            s.call = null;
            s.lock.unlock(s.io);
            s.send_lock.unlock(s.io);
        }
        var msg_arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer msg_arena.deinit();
        while (true) {
            _ = msg_arena.reset(.retain_capacity);
            const msgs = k.recv(proto.SchedMsgs, msg_arena.allocator()) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Status => return .{ .failed = try dupeStatus(a, status) },
            } orelse {
                const st = try k.finish(a);
                if (st.code == .ok) return .closed;
                return .{ .failed = st };
            };
            answered.* = true;
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            for (msgs.msgs) |m| {
                const msg = m.msg orelse continue;
                const drv, const out: Msg = switch (msg) {
                    .restarting => return .restarting,
                    .assigned => |x| blk: {
                        if (x.worker_addr.len == 0) continue;
                        break :blk .{ x.drv_path, .{ .assigned = .{ .worker = x.worker_addr, .assign_id = x.assign_id } } };
                    },
                    .cached => |x| .{ x.drv_path, .cached },
                    .unplaceable => |x| .{ x.drv_path, .{ .unplaceable = x.reason } },
                };
                const w = s.waiters.get(drv) orelse continue;
                const wa = w.arena.allocator();
                try w.msgs.append(wa, switch (out) {
                    .assigned => |x| .{ .assigned = .{ .worker = try wa.dupe(u8, x.worker), .assign_id = x.assign_id } },
                    .cached => .cached,
                    .unplaceable => |r| .{ .unplaceable = try wa.dupe(u8, r) },
                });
                if (out != .unplaceable) _ = s.waiters.remove(drv);
            }
            s.cond.broadcast(s.io);
        }
    }
};

fn dupeStatus(a: Allocator, st: config.Status) Allocator.Error!config.Status {
    return .{ .code = st.code, .message = try a.dupe(u8, st.message) };
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).toNanoseconds();
}

/// build.cc:`schedulerGone`: worth reconnecting for, unlike auth or TLS.
fn schedulerGone(s: config.Status) bool {
    return switch (s.code) {
        .unavailable, .unknown, .internal => std.mem.indexOf(u8, s.message, "andshake") == null and
            std.mem.indexOf(u8, s.message, "certificate") == null,
        else => false,
    };
}

test "a scheduler that went away is worth reconnecting to" {
    try std.testing.expect(schedulerGone(.{ .code = .unavailable, .message = "transport error" }));
    try std.testing.expect(!schedulerGone(.{ .code = .unavailable, .message = "TLS handshake failed" }));
    try std.testing.expect(!schedulerGone(.{ .code = .permission_denied, .message = "" }));
}
