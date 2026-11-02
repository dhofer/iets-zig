//! Anonymous memory: mapping, giving back and fencing off address space.
//! Linux only.

const std = @import("std");
const linux = std.os.linux;

pub fn pageSize() usize {
    return std.heap.pageSize();
}

/// Bytes of `[base, base + len)` that are resident, in whole pages.
pub fn resident(gpa: std.mem.Allocator, base: [*]u8, len: usize) !usize {
    const page = pageSize();
    const v = try gpa.alloc(u8, len / page);
    defer gpa.free(v);
    _ = linux.mincore(base, len, v.ptr);
    var n: usize = 0;
    for (v) |b| n += b & 1;
    return n * page;
}

/// `len` zeroed bytes, readable and writable. A `lazy` mapping reserves
/// address space and charges nothing until the pages are touched.
pub fn map(len: usize, lazy: bool) ?[*]u8 {
    const rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = lazy }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @ptrFromInt(rc);
}

/// Hands the pages back and leaves fresh zero pages in their place.
pub fn reset(p: [*]u8, len: usize) void {
    _ = linux.mmap(p, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
}

/// Gives the pages back. The range stays mapped and reads as zeros.
pub fn discard(p: [*]u8, len: usize) void {
    _ = linux.madvise(p, len, linux.MADV.DONTNEED);
}

pub fn unmap(p: [*]u8, len: usize) void {
    _ = linux.munmap(@alignCast(p), len);
}

/// Makes the low `len` bytes of a mapping fault when touched.
pub fn fence(p: [*]u8, len: usize) void {
    _ = linux.mprotect(@alignCast(p), len, .{});
}

/// Replaces the range with address space that faults and costs nothing.
/// `false` leaves the pages as they were.
pub fn revoke(p: [*]u8, len: usize) bool {
    const rc = linux.mmap(p, len, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED = true }, -1, 0);
    return linux.errno(rc) == .SUCCESS;
}

/// Advises `[p, p + len)` to be huge pages (`MADV_HUGEPAGE`) while the kernel
/// hands them over cheaply, and leaves it to small pages from the first time
/// it cannot. Under the usual `defrag=madvise`, a fault in an advised range
/// compacts memory to make a huge page, synchronously. A run that fits in
/// the free 2 MB blocks never compacts and saves a fault per 4 KB: 30% of
/// nixos-server. The whole nixpkgs universe (23 GB) outgrows them, and then
/// most compactions fail (`thp_fault_fallback`), each after its stall: a
/// third of the run's wall time at 8 workers. So past `max_fallbacks` since
/// the first advice, new memory is not advised. The counter is the
/// machine's, so another process's failures count too, as they say the same
/// about free memory.
pub noinline fn adviseHuge(p: [*]u8, len: usize) void {
    if (huge_closed.load(.monotonic)) return;
    if (thpFallbacks()) |n| {
        const base = huge_base.cmpxchgStrong(no_base, n, .monotonic, .monotonic) orelse n;
        if (n -% base > max_fallbacks) {
            huge_closed.store(true, .monotonic);
            return;
        }
    }
    _ = linux.madvise(@alignCast(p), len, linux.MADV.HUGEPAGE);
}

/// Huge-page faults the kernel failed to fill since the first advice, past
/// which `adviseHuge` stops advising. A failure costs a compaction stall of
/// a millisecond or more.
const max_fallbacks = 64;
const no_base = std.math.maxInt(u64);
var huge_base: std.atomic.Value(u64) = .init(no_base);
var huge_closed: std.atomic.Value(bool) = .init(false);

/// `thp_fault_fallback` from `/proc/vmstat`; null when it cannot be read.
noinline fn thpFallbacks() ?u64 {
    const rc = linux.open("/proc/vmstat", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    // a read returns at most a page of it
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return counter(buf[0..n], "thp_fault_fallback");
}

/// The value of `name` in a `/proc/vmstat` text.
fn counter(text: []const u8, name: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len > name.len and std.mem.startsWith(u8, l, name) and l[name.len] == ' ')
            return std.fmt.parseInt(u64, l[name.len + 1 ..], 10) catch null;
    }
    return null;
}

test "a vmstat counter is read by its whole name" {
    const text = "thp_fault_fallback_charge 7\nthp_fault_fallback 42\nnr_free_pages 1\n";
    try std.testing.expectEqual(42, counter(text, "thp_fault_fallback"));
    try std.testing.expectEqual(7, counter(text, "thp_fault_fallback_charge"));
    try std.testing.expectEqual(null, counter(text, "compact_stall"));
}

test "a mapping is resident once touched, and not after a discard" {
    const len = 16 * pageSize();
    const p = map(len, true).?;
    defer unmap(p, len);
    @memset(p[0 .. 4 * pageSize()], 1);
    try std.testing.expect(try resident(std.testing.allocator, p, len) >= 4 * pageSize());
    discard(p, len);
    try std.testing.expectEqual(0, p[0]);
    reset(p, len);
    try std.testing.expectEqual(0, try resident(std.testing.allocator, p, len));
}
