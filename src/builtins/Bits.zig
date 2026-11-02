//! One bit per element of a list or set, on the stack up to 1024
//! elements: what a builtin keeps, before it allocates the result once at
//! its size.

const std = @import("std");
const Bits = @This();

stack: [16]u64,
heap: ?[]u64,

pub fn init(gpa: std.mem.Allocator, len: usize) error{OutOfMemory}!Bits {
    const n = (len + 63) / 64;
    var b: Bits = .{ .stack = @splat(0), .heap = null };
    if (n > b.stack.len) {
        const h = try gpa.alloc(u64, n);
        @memset(h, 0);
        b.heap = h;
    }
    return b;
}

pub fn deinit(b: *Bits, gpa: std.mem.Allocator) void {
    if (b.heap) |h| gpa.free(h);
}

fn words(b: *Bits) []u64 {
    return b.heap orelse &b.stack;
}

pub fn set(b: *Bits, i: usize) void {
    b.words()[i / 64] |= @as(u64, 1) << @truncate(i);
}

pub fn isSet(b: *Bits, i: usize) bool {
    return b.words()[i / 64] & (@as(u64, 1) << @truncate(i)) != 0;
}

test "bits past the stack words" {
    var b: Bits = try .init(std.testing.allocator, 5000);
    defer b.deinit(std.testing.allocator);
    b.set(0);
    b.set(4999);
    try std.testing.expect(b.isSet(0) and b.isSet(4999) and !b.isSet(1));
}
