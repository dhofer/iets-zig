//! The paths a watcher has to watch for a tracing-cache entry's answer to go
//! stale. `iets cache paths` is the command over this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const watch = @import("../trace/watch.zig");

/// The most paths `watchPaths` gives.
pub const max = watch.max;

pub const Watched = watch.Watched;

/// The watchable paths of the entry file at `entry`, in the order the run
/// read them, capped at `max`. The stores to exclude come from `entry`
/// itself: an entry lives at `<cache>/trace/<key>/entry`. Everything is
/// `a`'s.
pub fn watchPaths(gpa: Allocator, a: Allocator, io: std.Io, entry: []const u8, d: *Diag) error{ Cache, OutOfMemory }![]Watched {
    return (try watch.ofEntry(gpa, a, io, entry)) orelse d.fail(error.Cache, "{s} is not a cache entry", .{entry});
}

test "a file that is no entry is not a cache entry" {
    var d: Diag = .init(std.testing.allocator);
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Cache, watchPaths(std.testing.allocator, arena.allocator(), std.testing.io, "/nonexistent/entry", &d));
    try std.testing.expectEqualStrings("/nonexistent/entry is not a cache entry", d.message());
}
