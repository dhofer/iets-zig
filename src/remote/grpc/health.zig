//! Which worker addresses are worth calling, shared by the threads of one
//! batch.
//!
//! The scheduler keeps a worker placeable until it notices the worker is
//! gone (42 s seen on farm.numtide.com, 2026-09-22) and a bounce off it is
//! instant. `build.reschedulePause` backs each derivation off on its own, so
//! derivations placed on one dead address each walk their own ladder and the
//! client concludes nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Consecutive bounces before an address is refused. One decides nothing: a
/// superseded assignment, a worker that started draining and a build the
/// scheduler re-placed each bounce exactly once.
const threshold = 2;

const Entry = struct {
    /// Consecutive bounces since the last build this address completed.
    bounces: u32 = 0,
    /// When it may be called again (monotonic ns), once the circuit is open.
    until: ?i96 = null,
};

pub const Health = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    workers: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn init(gpa: Allocator, io: Io) Health {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(h: *Health) void {
        var it = h.workers.keyIterator();
        while (it.next()) |k| h.gpa.free(k.*);
        h.workers.deinit(h.gpa);
    }

    fn now(h: *Health) i96 {
        return Io.Clock.awake.now(h.io).toNanoseconds();
    }

    /// How long to wait (ns) before calling `addr` again, null when it is usable.
    pub fn refusal(h: *Health, addr: []const u8) ?i96 {
        const t = h.now();
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        const e = h.workers.getPtr(addr) orelse return null;
        const until = e.until orelse return null;
        if (until > t) return until - t;
        // Let one caller probe it, and close it again on the next bounce.
        e.until = null;
        return null;
    }

    pub fn bounced(h: *Health, addr: []const u8) void {
        const t = h.now();
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        const gop = h.workers.getOrPut(h.gpa, addr) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = h.gpa.dupe(u8, addr) catch {
                _ = h.workers.remove(addr);
                return;
            };
            gop.value_ptr.* = .{};
        }
        const e = gop.value_ptr;
        e.bounces += 1;
        if (e.bounces >= threshold) e.until = t + cooldownNs(e.bounces - threshold);
    }

    /// The address returned a build result, failed or not: it is serving.
    pub fn worked(h: *Health, addr: []const u8) void {
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        if (h.workers.fetchRemove(addr)) |kv| h.gpa.free(kv.key);
    }
};

/// The ladder `build.reschedulePause` walks, so there is one curve: 1 s
/// doubling to 30 s.
pub fn cooldown(n: u32) u64 {
    return @min(@as(u64, 1) << @intCast(@min(n, 5)), 30);
}

fn cooldownNs(n: u32) i96 {
    return @as(i96, cooldown(n)) * std.time.ns_per_s;
}

const testing = std.testing;

test "one bounce does not refuse an address" {
    var h: Health = .init(testing.allocator, testing.io);
    defer h.deinit();
    h.bounced("a:1");
    try testing.expectEqual(null, h.refusal("a:1"));
}

test "two bounces refuse it" {
    var h: Health = .init(testing.allocator, testing.io);
    defer h.deinit();
    h.bounced("a:1");
    h.bounced("a:1");
    try testing.expect(h.refusal("a:1") != null);
}

test "an unknown address is usable" {
    var h: Health = .init(testing.allocator, testing.io);
    defer h.deinit();
    try testing.expectEqual(null, h.refusal("a:1"));
}

test "a completed build clears the history" {
    var h: Health = .init(testing.allocator, testing.io);
    defer h.deinit();
    h.bounced("a:1");
    h.bounced("a:1");
    h.worked("a:1");
    try testing.expectEqual(null, h.refusal("a:1"));
    h.bounced("a:1");
    try testing.expectEqual(null, h.refusal("a:1"));
}

test "one address does not refuse another" {
    var h: Health = .init(testing.allocator, testing.io);
    defer h.deinit();
    h.bounced("a:1");
    h.bounced("a:1");
    try testing.expectEqual(null, h.refusal("b:2"));
}

test "the cooldown grows and stops at 30s" {
    var s: [8]u64 = undefined;
    for (&s, 0..) |*x, n| x.* = cooldown(@intCast(n));
    try testing.expectEqualSlices(u64, &.{ 1, 2, 4, 8, 16, 30, 30, 30 }, &s);
    try testing.expectEqual(30, cooldown(std.math.maxInt(u32)));
}

test "a passed cooldown lets one caller through" {
    var h: Health = .init(testing.allocator, testing.io);
    defer h.deinit();
    h.bounced("a:1");
    h.bounced("a:1");
    h.workers.getPtr("a:1").?.until = h.now();
    try testing.expectEqual(null, h.refusal("a:1"));
    try testing.expectEqual(null, h.refusal("a:1"));
    h.bounced("a:1");
    const wait = h.refusal("a:1") orelse return error.TestExpectedRefusal;
    try testing.expect(wait > 0 and wait <= cooldownNs(1));
}
