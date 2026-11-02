//! A bump allocator for temporaries dropped all at once, owned by one
//! thread. `std.heap.ArenaAllocator` is thread-safe: an atomic
//! read-modify-write on every allocation, which cost the compile 2%.
//! `reset` keeps every chunk, so a scratch reused file after file stops
//! asking the backing allocator once it has seen its largest file.

const std = @import("std");
const Alignment = std.mem.Alignment;
const Scratch = @This();

backing: std.mem.Allocator,
chunks: std.ArrayList([]align(16) u8) = .empty,
/// The chunk allocations come from, and the offset of its free bytes.
idx: usize = 0,
cur: usize = 0,
/// The start of the last allocation, which `resize` and `free` may move.
last: usize = 0,

const min_chunk = 64 << 10;

pub fn init(backing: std.mem.Allocator) Scratch {
    return .{ .backing = backing };
}

pub fn deinit(s: *Scratch) void {
    for (s.chunks.items) |c| s.backing.free(c);
    s.chunks.deinit(s.backing);
    s.* = undefined;
}

/// Drop every allocation; the chunks stay for the next round.
pub fn reset(s: *Scratch) void {
    s.idx = 0;
    s.cur = 0;
    s.last = 0;
}

pub fn allocator(s: *Scratch) std.mem.Allocator {
    return .{ .ptr = s, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const s: *Scratch = @ptrCast(@alignCast(ctx));
    while (s.idx < s.chunks.items.len) {
        const c = s.chunks.items[s.idx];
        const start = alignment.forward(@intFromPtr(c.ptr) + s.cur) - @intFromPtr(c.ptr);
        if (start + n <= c.len) {
            s.last = start;
            s.cur = start + n;
            return c.ptr + start;
        }
        s.idx += 1;
        s.cur = 0;
    }
    const prev = if (s.chunks.items.len > 0) s.chunks.items[s.chunks.items.len - 1].len else 0;
    const len = @max(min_chunk, prev * 2, n + alignment.toByteUnits());
    s.chunks.ensureUnusedCapacity(s.backing, 1) catch return null;
    const c = s.backing.alignedAlloc(u8, .@"16", len) catch return null;
    s.chunks.appendAssumeCapacity(c);
    s.idx = s.chunks.items.len - 1;
    s.cur = 0;
    return alloc(ctx, n, alignment, 0);
}

/// True when `memory` is the last allocation of the current chunk.
fn isLast(s: *Scratch, memory: []u8) bool {
    if (s.idx >= s.chunks.items.len) return false;
    const c = s.chunks.items[s.idx];
    return @intFromPtr(memory.ptr) == @intFromPtr(c.ptr) + s.last and s.last + memory.len == s.cur;
}

fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    const s: *Scratch = @ptrCast(@alignCast(ctx));
    if (!s.isLast(memory)) return new_len <= memory.len;
    if (s.last + new_len > s.chunks.items[s.idx].len) return false;
    s.cur = s.last + new_len;
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    const s: *Scratch = @ptrCast(@alignCast(ctx));
    if (s.isLast(memory)) s.cur = s.last;
}

test "grow in place, spill to a new chunk, reuse after reset" {
    var s: Scratch = .init(std.testing.allocator);
    defer s.deinit();
    const a = s.allocator();
    var l: std.ArrayList(u64) = .empty;
    for (0..50_000) |i| try l.append(a, i);
    try std.testing.expectEqual(@as(u64, 49_999), l.items[49_999]);
    const p = try a.alignedAlloc(u8, .@"64", 3);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(p.ptr), 64));
    const chunks = s.chunks.items.len;
    s.reset();
    l = .empty;
    for (0..50_000) |i| try l.append(a, i);
    try std.testing.expectEqual(chunks, s.chunks.items.len);
}
