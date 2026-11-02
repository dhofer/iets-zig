//! A fixed-capacity Chase-Lev work-stealing deque of two-word entries. The
//! owner pushes and pops at the bottom (LIFO); thieves steal from the top.
//! `push` fails when full, so an entry is never overwritten while a thief
//! may still read it, and no memory reclamation is needed. The orderings
//! follow Lê et al., "Correct and Efficient Work-Stealing for Weak Memory
//! Models" (PPoPP 2013).

const std = @import("std");
const Deque = @This();
const Atomic = std.atomic.Value;

pub const Entry = struct { u64, u64 };

top: Atomic(i64) align(std.atomic.cache_line) = .init(0),
bottom: Atomic(i64) align(std.atomic.cache_line) = .init(0),
buf: []Atomic(u64),

/// `cap` must be a power of two.
pub fn init(gpa: std.mem.Allocator, cap: usize) !Deque {
    std.debug.assert(std.math.isPowerOfTwo(cap));
    const buf = try gpa.alloc(Atomic(u64), cap * 2);
    @memset(buf, .init(0));
    return .{ .buf = buf };
}

pub fn deinit(d: *Deque, gpa: std.mem.Allocator) void {
    gpa.free(d.buf);
}

inline fn slot(d: *const Deque, i: i64) usize {
    return (@as(usize, @bitCast(i)) & (d.buf.len / 2 - 1)) * 2;
}

/// Owner only. False when full.
pub fn push(d: *Deque, e: Entry) bool {
    const bot = d.bottom.load(.monotonic);
    const top = d.top.load(.acquire);
    if (bot - top >= d.buf.len / 2) return false;
    const s = d.slot(bot);
    d.buf[s].store(e[0], .monotonic);
    d.buf[s + 1].store(e[1], .monotonic);
    // Release: a thief that sees the new bottom sees the entry.
    d.bottom.store(bot + 1, .release);
    return true;
}

/// Owner only.
pub fn pop(d: *Deque) ?Entry {
    const bot = d.bottom.load(.monotonic) - 1;
    d.bottom.store(bot, .monotonic);
    seqCstFence();
    const top = d.top.load(.monotonic);
    if (top > bot) {
        d.bottom.store(bot + 1, .monotonic);
        return null;
    }
    const s = d.slot(bot);
    const e: Entry = .{ d.buf[s].load(.monotonic), d.buf[s + 1].load(.monotonic) };
    if (top < bot) return e;
    // The last entry: race the thieves for it.
    const won = d.top.cmpxchgStrong(top, top + 1, .seq_cst, .monotonic) == null;
    d.bottom.store(bot + 1, .monotonic);
    return if (won) e else null;
}

/// Any thread. Null when empty or when it lost a race; callers move on.
pub fn steal(d: *Deque) ?Entry {
    const top = d.top.load(.acquire);
    seqCstFence();
    const bot = d.bottom.load(.acquire);
    if (top >= bot) return null;
    const s = d.slot(top);
    const e: Entry = .{ d.buf[s].load(.monotonic), d.buf[s + 1].load(.monotonic) };
    if (d.top.cmpxchgStrong(top, top + 1, .seq_cst, .monotonic) != null) return null;
    return e;
}

/// A full fence. Zig has no `@fence`; a seq_cst read-modify-write on a
/// private word is one on every target.
inline fn seqCstFence() void {
    var x: Atomic(u8) = .init(0);
    _ = x.fetchAdd(0, .seq_cst);
}

test "owner is LIFO, thief is FIFO" {
    var d: Deque = try .init(std.testing.allocator, 8);
    defer d.deinit(std.testing.allocator);
    for (0..8) |i| try std.testing.expect(d.push(.{ i, 100 + i }));
    try std.testing.expect(!d.push(.{ 9, 9 }));
    try std.testing.expectEqual(Entry{ 0, 100 }, d.steal().?);
    try std.testing.expectEqual(Entry{ 7, 107 }, d.pop().?);
    try std.testing.expect(d.push(.{ 8, 108 }));
    try std.testing.expectEqual(Entry{ 8, 108 }, d.pop().?);
    var i: u64 = 6;
    while (i >= 1) : (i -= 1) try std.testing.expectEqual(Entry{ i, 100 + i }, d.pop().?);
    try std.testing.expectEqual(null, d.pop());
    try std.testing.expectEqual(null, d.steal());
}

test "concurrent sum" {
    const N: u64 = 200_000;
    var d: Deque = try .init(std.testing.allocator, 1024);
    defer d.deinit(std.testing.allocator);
    var sum: Atomic(u64) = .init(0);
    var taken: Atomic(u64) = .init(0);
    const Thief = struct {
        fn run(dq: *Deque, s: *Atomic(u64), t: *Atomic(u64)) void {
            while (t.load(.monotonic) < N) {
                if (dq.steal()) |e| {
                    std.debug.assert(e[1] == e[0] * 2);
                    _ = s.fetchAdd(e[0], .monotonic);
                    _ = t.fetchAdd(1, .monotonic);
                }
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Thief.run, .{ &d, &sum, &taken });
    var i: u64 = 0;
    while (i < N) {
        if (d.push(.{ i, i * 2 })) {
            i += 1;
        } else if (d.pop()) |e| {
            _ = sum.fetchAdd(e[0], .monotonic);
            _ = taken.fetchAdd(1, .monotonic);
        }
    }
    while (taken.load(.monotonic) < N) {
        if (d.pop()) |e| {
            _ = sum.fetchAdd(e[0], .monotonic);
            _ = taken.fetchAdd(1, .monotonic);
        }
    }
    for (threads) |t| t.join();
    try std.testing.expectEqual(N * (N - 1) / 2, sum.load(.monotonic));
}
