//! A bump allocator for values. Nothing is freed until the arena goes away, so
//! object layout, not allocation speed, decides peak memory.

const std = @import("std");
const Arena = @This();
const census_mod = @import("census.zig");
const vm = @import("../sys/vm.zig");

backing: std.mem.Allocator,
/// Bytes left in the current chunk start at `cur`; `end` is one past it.
cur: usize = 0,
end: usize = 0,
chunks: std.ArrayList([]align(page) u8) = .empty,
/// Bytes handed out, for the statistics.
used: usize = 0,
/// Bytes of the chunks taken from the kernel, for the statistics.
mapped: usize = 0,
/// The memory census of what this arena holds (`-Dstats2=true` only).
census: if (census_mod.enabled) census_mod.Census else void,

const page = std.heap.page_size_min;
/// Chunks come straight from the kernel, large and advised to be huge
/// pages: a 700 MB run is then a few hundred page faults, not 200,000.
const chunk_size = 32 << 20;

pub fn init(backing: std.mem.Allocator) Arena {
    return .{ .backing = backing, .census = if (census_mod.enabled) .init(backing) else {} };
}

pub fn deinit(a: *Arena) void {
    if (census_mod.enabled) a.census.deinit();
    for (a.chunks.items) |c| std.posix.munmap(c);
    a.chunks.deinit(a.backing);
    a.* = undefined;
}

/// `n` bytes aligned to 8.
pub inline fn alloc(a: *Arena, n: usize) error{OutOfMemory}![*]align(8) u8 {
    const size = std.mem.alignForward(usize, n, 8);
    if (a.end - a.cur < size) return a.allocSlow(size);
    const p = a.cur;
    a.cur += size;
    a.used += size;
    return @ptrFromInt(p);
}

fn allocSlow(a: *Arena, size: usize) error{OutOfMemory}![*]align(8) u8 {
    // A large object gets a chunk of its own and the current chunk stays open.
    const big = size > chunk_size / 4;
    const len = if (big) std.mem.alignForward(usize, size, page) else chunk_size;
    const c = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch
        return error.OutOfMemory;
    errdefer std.posix.munmap(c);
    vm.adviseHuge(c.ptr, c.len);
    try a.chunks.append(a.backing, c);
    a.mapped += len;
    a.used += size;
    if (big) return c.ptr;
    a.cur = @intFromPtr(c.ptr) + size;
    a.end = @intFromPtr(c.ptr) + len;
    return c.ptr;
}

/// Give back the end of the last allocation, which `p` starts.
pub fn shrinkLast(a: *Arena, p: [*]u8, old: usize, new: usize) void {
    const old_end = @intFromPtr(p) + std.mem.alignForward(usize, old, 8);
    if (old_end != a.cur) return;
    const new_end = @intFromPtr(p) + std.mem.alignForward(usize, new, 8);
    a.used -= old_end - new_end;
    a.cur = new_end;
}

pub fn create(a: *Arena, comptime T: type) error{OutOfMemory}!*T {
    comptime std.debug.assert(@alignOf(T) <= 8);
    return @ptrCast(try a.alloc(@sizeOf(T)));
}

/// A `T` header followed by `n` `E`s.
pub fn createWithTail(a: *Arena, comptime T: type, comptime E: type, n: usize) error{OutOfMemory}!*T {
    comptime std.debug.assert(@alignOf(T) <= 8 and @alignOf(E) <= 8 and @sizeOf(T) % @alignOf(E) == 0);
    return @ptrCast(try a.alloc(@sizeOf(T) + n * @sizeOf(E)));
}

pub fn allocSlice(a: *Arena, comptime T: type, n: usize) error{OutOfMemory}![]T {
    comptime std.debug.assert(@alignOf(T) <= 8);
    if (n == 0) return &.{};
    const p: [*]T = @ptrCast(try a.alloc(n * @sizeOf(T)));
    return p[0..n];
}

pub fn dupe(a: *Arena, comptime T: type, s: []const T) error{OutOfMemory}![]T {
    const out = try a.allocSlice(T, s.len);
    @memcpy(out, s);
    return out;
}

/// A `std.mem.Allocator` over the arena; `free` is a no-op and `resize` grows
/// in place only for the last allocation.
pub fn allocator(a: *Arena) std.mem.Allocator {
    return .{ .ptr = a, .vtable = &.{
        .alloc = vtAlloc,
        .resize = vtResize,
        .remap = vtRemap,
        .free = vtFree,
    } };
}

fn vtAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const a: *Arena = @ptrCast(@alignCast(ctx));
    if (alignment.toByteUnits() > 8) {
        const p = a.alloc(len + alignment.toByteUnits()) catch return null;
        return @ptrFromInt(alignment.forward(@intFromPtr(p)));
    }
    return a.alloc(len) catch null;
}

fn vtResize(ctx: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const a: *Arena = @ptrCast(@alignCast(ctx));
    if (new_len <= mem.len) return true;
    const old_end = std.mem.alignForward(usize, @intFromPtr(mem.ptr) + mem.len, 8);
    if (old_end != a.cur) return false;
    const new_end = std.mem.alignForward(usize, @intFromPtr(mem.ptr) + new_len, 8);
    if (new_end > a.end) return false;
    a.used += new_end - a.cur;
    a.cur = new_end;
    return true;
}

fn vtRemap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (vtResize(ctx, mem, alignment, new_len, ra)) mem.ptr else null;
}

fn vtFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

test "bump and big objects" {
    var a: Arena = .init(std.testing.allocator);
    defer a.deinit();
    const x = try a.create(u64);
    x.* = 7;
    const big = try a.allocSlice(u8, chunk_size);
    @memset(big, 1);
    const y = try a.create(u64);
    try std.testing.expectEqual(@intFromPtr(x) + 8, @intFromPtr(y));
    var l: std.ArrayList(u8) = .empty;
    for (0..100) |i| try l.append(a.allocator(), @truncate(i));
    try std.testing.expectEqual(99, l.items[99]);
}
