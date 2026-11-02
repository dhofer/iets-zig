//! The general-purpose allocator of release builds, in place of glibc
//! malloc: a worker thread's glibc heap is fresh 4 KB pages, which cost
//! nixos-server 30k page faults (Rust iets, under mimalloc: 4k) and most of a
//! worker's system time.
//!
//! The small path has the shape of `std.heap.SmpAllocator`: power-of-two
//! size classes, a free list per class per thread slot, slabs of one class.
//! Unlike it, every byte comes from segments advised to be huge pages, and
//! no address range goes back to the kernel: a freed block of any size
//! waits on its class's list for the next request. A freed block of 1 MB or
//! more gives its pages back (`MADV_DONTNEED`) and keeps its range, so a
//! once-only buffer does not stay resident.

const std = @import("std");
const vm = @import("sys/vm.zig");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
} };

/// Small blocks are carved from slabs of this size, each serving one class.
const slab_len = 64 << 10;
const min_class = 3;
/// Classes of powers of two from 8 B to 32 KB are small. Past that, up to
/// 32 MB, classes are quarter steps (40, 48, 56, 64 KB, 80 KB, ...), kept on
/// global lists: on huge pages a block's rounding is memory touched (6 MB
/// of peak on nixos-server against powers of two). Larger blocks are
/// mappings of their own.
const small_count = std.math.log2(slab_len) - min_class;
const small_max_log2 = std.math.log2(slab_len) - 1;
const large_count = 4 * (25 - small_max_log2);
/// Segments are carved into slabs and large blocks.
const segment_len = 64 << 20;
const huge_page = 2 << 20;

const max_slots = 64;
/// Freed blocks from this size on give their pages back.
const release_min = 1 << 20;

const Slot = struct {
    _: void align(std.atomic.cache_line) = {},
    mutex: std.atomic.Mutex = .unlocked,
    /// Per small class: the next unused slot of the class's current slab.
    next: [small_count]usize = @splat(0),
    /// Per small class: the free list, linked through each block's first word.
    frees: [small_count]usize = @splat(0),
};

const Large = struct {
    _: void align(std.atomic.cache_line) = {},
    mutex: std.atomic.Mutex = .unlocked,
    frees: usize = 0,
};

var slots: [max_slots]Slot = @splat(.{});
var large: [large_count]Large = @splat(.{});
var slot_count: std.atomic.Value(u32) = .init(0);
/// Read only inside the allocator's functions, which never park a fiber.
threadlocal var slot_index: u32 = 0;

var segment_mutex: std.atomic.Mutex = .unlocked;
var segment_cur: usize = 0;
var segment_end: usize = 0;

fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn slotCount() u32 {
    const n = slot_count.load(.monotonic);
    if (n != 0) return n;
    const c: u32 = @intCast(@min(std.Thread.getCpuCount() catch max_slots, max_slots));
    slot_count.store(c, .monotonic);
    return c;
}

/// This thread's slot, locked; the next free one when another thread holds it.
fn lockSlot() *Slot {
    var i = slot_index;
    if (slots[i].mutex.tryLock()) {
        @branchHint(.likely);
        return &slots[i];
    }
    const n = slotCount();
    while (true) {
        i = (i + 1) % n;
        if (slots[i].mutex.tryLock()) {
            slot_index = i;
            return &slots[i];
        }
    }
}

/// The class of a block: for a small one log2 of its size, less
/// `min_class`; then the large classes; `own` for a mapping of its own:
/// past 32 MB, or a large block aligned past a page.
fn classOf(len: usize, alignment: Alignment) usize {
    if (alignment.toByteUnits() > slab_len) return own;
    const size = @max(len, alignment.toByteUnits(), 1 << min_class);
    if (size <= 1 << small_max_log2) return std.math.log2_int_ceil(usize, size) - min_class;
    if (alignment.toByteUnits() > std.heap.page_size_min or size > 32 << 20) return own;
    const k = std.math.log2_int(usize, size - 1);
    const step = @as(usize, 1) << @intCast(k - 2);
    const q = std.math.divCeil(usize, size, step) catch unreachable;
    return small_count + (k - small_max_log2) * 4 + (q - 5);
}

/// The size of large class `i` (counted from the first large class).
fn largeSize(i: usize) usize {
    return (5 + i % 4) << @intCast(i / 4 + small_max_log2 - 2);
}

const own = small_count + large_count;

/// `len` bytes aligned to `alignment` from the segments, which are carved
/// in order and never given back.
fn carve(len: usize, alignment: usize) ?usize {
    lockSpin(&segment_mutex);
    defer segment_mutex.unlock();
    var start = std.mem.alignForward(usize, segment_cur, alignment);
    if (segment_cur == 0 or start + len > segment_end) {
        // The rest of the segment stays unused: untouched, it costs no memory.
        const seg = mapHuge(segment_len) orelse return null;
        segment_cur = @intFromPtr(seg);
        segment_end = segment_cur + segment_len;
        start = std.mem.alignForward(usize, segment_cur, alignment);
    }
    segment_cur = start + len;
    return start;
}

/// A mapping of `len` bytes aligned to 2 MB and advised to be huge pages.
fn mapHuge(len: usize) ?[*]align(huge_page) u8 {
    const full = len + huge_page;
    const m = posix.mmap(null, full, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch return null;
    const start = std.mem.alignForward(usize, @intFromPtr(m.ptr), huge_page);
    const head = start - @intFromPtr(m.ptr);
    if (head > 0) posix.munmap(m[0..head]);
    const tail = full - head - len;
    if (tail > 0) posix.munmap(@alignCast(m[head + len ..][0..tail]));
    const p: [*]align(huge_page) u8 = @ptrFromInt(start);
    vm.adviseHuge(p, len);
    return p;
}

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const class = classOf(len, alignment);
    if (class < small_count) return allocSmall(class);
    if (class < own) return allocLarge(class - small_count);
    if (alignment.toByteUnits() > huge_page) return null;
    return @ptrCast(mapHuge(std.mem.alignForward(usize, len, huge_page)) orelse return null);
}

fn allocSmall(class: usize) ?[*]u8 {
    const size = @as(usize, 1) << @intCast(class + min_class);
    const s = lockSlot();
    defer s.mutex.unlock();
    const top = s.frees[class];
    if (top != 0) {
        @branchHint(.likely);
        s.frees[class] = @as(*const usize, @ptrFromInt(top)).*;
        return @ptrFromInt(top);
    }
    const next = s.next[class];
    if (next % slab_len != 0) {
        @branchHint(.likely);
        s.next[class] = next + size;
        return @ptrFromInt(next);
    }
    const slab = carve(slab_len, slab_len) orelse return null;
    s.next[class] = slab + size;
    return @ptrFromInt(slab);
}

fn allocLarge(k: usize) ?[*]u8 {
    const l = &large[k];
    lockSpin(&l.mutex);
    const top = l.frees;
    if (top != 0) {
        l.frees = @as(*const usize, @ptrFromInt(top)).*;
        l.mutex.unlock();
        return @ptrFromInt(top);
    }
    l.mutex.unlock();
    return @ptrFromInt(carve(largeSize(k), std.heap.page_size_min) orelse return null);
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const class = classOf(memory.len, alignment);
    const p = @intFromPtr(memory.ptr);
    if (class < small_count) {
        const s = lockSlot();
        defer s.mutex.unlock();
        @as(*usize, @ptrFromInt(p)).* = s.frees[class];
        s.frees[class] = p;
    } else if (class < own) {
        // A large block's pages go back to the kernel and come again on
        // reuse: a once-only buffer (a 16 MB source and its parse tree)
        // would otherwise stay resident for the whole run.
        const size = largeSize(class - small_count);
        if (size >= release_min) posix.madvise(@ptrFromInt(p), size, posix.MADV.DONTNEED) catch {};
        const l = &large[class - small_count];
        lockSpin(&l.mutex);
        defer l.mutex.unlock();
        @as(*usize, @ptrFromInt(p)).* = l.frees;
        l.frees = p;
    } else {
        const len = std.mem.alignForward(usize, memory.len, huge_page);
        posix.munmap(@as([*]align(std.heap.page_size_min) u8, @alignCast(memory.ptr))[0..len]);
    }
}

/// In place within a block's class; a mapping of its own grows up to its
/// 2 MB rounding.
fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const class = classOf(memory.len, alignment);
    const new_class = classOf(new_len, alignment);
    if (class < own or new_class < own) return class == new_class;
    return std.mem.alignForward(usize, new_len, huge_page) == std.mem.alignForward(usize, memory.len, huge_page);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
}

test "large classes are quarter steps" {
    try std.testing.expectEqual(40 << 10, largeSize(classOf((32 << 10) + 1, .@"1") - small_count));
    try std.testing.expectEqual(64 << 10, largeSize(classOf(64 << 10, .@"1") - small_count));
    try std.testing.expectEqual(80 << 10, largeSize(classOf((64 << 10) + 1, .@"1") - small_count));
    try std.testing.expectEqual(32 << 20, largeSize(classOf(32 << 20, .@"8") - small_count));
    try std.testing.expectEqual(own, classOf((32 << 20) + 1, .@"8"));
    for (0..large_count) |i| try std.testing.expectEqual(small_count + i, classOf(largeSize(i), .@"16"));
}

test "classes, reuse and growth" {
    const a = allocator;
    const x = try a.alloc(u8, 100);
    a.free(x);
    const y = try a.alloc(u8, 120);
    try std.testing.expectEqual(x.ptr, y.ptr);
    a.free(y);

    const big = try a.alloc(u8, 200 << 10);
    @memset(big, 7);
    a.free(big);
    const big2 = try a.alloc(u8, 210 << 10);
    try std.testing.expectEqual(big.ptr, big2.ptr);
    a.free(big2);

    const p = try a.alignedAlloc(u8, .fromByteUnits(4096), 10);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(p.ptr), 4096));
    a.free(p);

    var l: std.ArrayList(u64) = .empty;
    defer l.deinit(a);
    for (0..10_000_000) |i| try l.append(a, i);
    try std.testing.expectEqual(@as(u64, 9_999_999), l.items[9_999_999]);
}

test "threads share the lists" {
    const T = struct {
        fn run() void {
            var ptrs: [1000][]u8 = undefined;
            for (&ptrs, 0..) |*q, i| {
                q.* = allocator.alloc(u8, 1 + i * 37 % 5000) catch unreachable;
                @memset(q.*, @truncate(i));
            }
            for (ptrs, 0..) |q, i| {
                for (q) |c| assert(c == @as(u8, @truncate(i)));
                allocator.free(q);
            }
        }
    };
    var ts: [8]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, T.run, .{});
    for (ts) |t| t.join();
}
