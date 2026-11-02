//! The project root: the directory a run's sources belong to.
//!
//! Three things need the same answer, so they ask the same question here:
//! pure evaluation reads below the root without a flake
//! (`store_hooks.allowed`), the `impure-path-in-drv` and
//! `absolute-path-in-drv` lints split on it, and the project `iets.toml`
//! walk stops at it.
//!
//! Three markers, and each says something different, so each is weighed
//! differently:
//!
//! 1. **A working tree** is the unit the code lives in, and the nearest one
//!    wins over everything below it.
//! 2. **`flake.nix`** claims a boundary — Nix makes that directory a tree —
//!    so the nearest one wins when there is no working tree.
//! 3. **`iets.toml`** claims nothing. It sets lint levels for what is below
//!    it, so the **outermost** one answers, and only when neither of the
//!    two above does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");

pub const flake = "flake.nix";
pub const config = "iets.toml";

/// The marker of a working tree of each SCM iets knows, in the order
/// detection asks them.
pub const scm_markers = @import("source/scm.zig").markers;

/// Every entry whose presence makes a directory a project root, whatever
/// the rule that weighs them.
pub const markers = scm_markers ++ [_][]const u8{ flake, config };

fn parent(dir: []const u8) ?[]const u8 {
    if (dir.len <= 1) return null;
    const i = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
    return if (i == 0) "/" else dir[0..i];
}

/// The project root at or above `start`, null above every marker.
/// `present(ctx, dir, marker)` decides whether a marker is there: the file
/// system for a frontend, the tracing cache's own `stat` for the lint.
///
/// The walk goes to the top whenever no working tree is found, so a marker
/// above a deeper one is still weighed — and, for the lint, so every probe
/// the answer depends on is an observation.
pub fn findWith(start: []const u8, ctx: anytype, comptime present: fn (@TypeOf(ctx), []const u8, []const u8) bool) ?[]const u8 {
    var found_flake: ?[]const u8 = null;
    var found_config: ?[]const u8 = null;
    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = parent(d)) {
        for (scm_markers) |m| if (present(ctx, d, m)) return d;
        if (found_flake == null and present(ctx, d, flake)) found_flake = d;
        if (present(ctx, d, config)) found_config = d;
    }
    return found_flake orelse found_config;
}

/// `findWith` on the file system.
pub fn find(start: []const u8) ?[]const u8 {
    return findWith(start, {}, onDisk);
}

fn onDisk(_: void, dir: []const u8, marker: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir, if (std.mem.endsWith(u8, dir, "/")) "" else "/", marker }) catch return false;
    return sys.fs.exists(p);
}

const testing = std.testing;

/// A directory under /tmp: the test tree is inside a Git worktree, whose
/// marker would answer for every directory below it.
const Tree = struct {
    root: []u8,
    dir: std.Io.Dir,

    fn init() !Tree {
        var r: [8]u8 = undefined;
        sys.random(&r);
        const root = try std.fmt.allocPrint(testing.allocator, "/tmp/iets-project-{x}", .{r});
        try std.Io.Dir.cwd().createDirPath(testing.io, root);
        return .{ .root = root, .dir = try std.Io.Dir.cwd().openDir(testing.io, root, .{}) };
    }
    fn deinit(x: *Tree) void {
        x.dir.close(testing.io);
        std.Io.Dir.cwd().deleteTree(testing.io, x.root) catch {};
        testing.allocator.free(x.root);
    }
    fn touch(x: *Tree, p: []const u8) !void {
        try x.dir.writeFile(testing.io, .{ .sub_path = p, .data = "" });
    }
    fn path(x: *Tree, buf: []u8, sub: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ x.root, sub }) catch unreachable;
    }
};

test "each marker is a root" {
    var x: Tree = try .init();
    defer x.deinit();
    try x.dir.createDirPath(testing.io, "a/b");
    var b1: [4096]u8 = undefined;
    const deep = x.path(&b1, "a/b");
    try testing.expect(find(deep) == null);
    for (markers) |m| {
        try x.touch(m);
        try testing.expectEqualStrings(x.root, find(deep).?);
        try x.dir.deleteFile(testing.io, m);
    }
}

test "a working tree wins over a file marker below it" {
    var x: Tree = try .init();
    defer x.deinit();
    try x.dir.createDirPath(testing.io, "sub/deep");
    try x.touch("sub/iets.toml");
    try x.touch("sub/flake.nix");
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    const deep = x.path(&b1, "sub/deep");
    const sub = x.path(&b2, "sub");
    try testing.expectEqualStrings(sub, find(deep).?);
    try x.touch(".git");
    try testing.expectEqualStrings(x.root, find(deep).?);
}

test "the nearest flake wins without a working tree" {
    var x: Tree = try .init();
    defer x.deinit();
    try x.dir.createDirPath(testing.io, "inner/deep");
    try x.touch(flake);
    try x.touch("inner/flake.nix");
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    try testing.expectEqualStrings(x.path(&b2, "inner"), find(x.path(&b1, "inner/deep")).?);
}

test "a config file never shrinks the root" {
    var x: Tree = try .init();
    defer x.deinit();
    try x.dir.createDirPath(testing.io, "sub/deep");
    try x.touch("sub/iets.toml");
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    const deep = x.path(&b1, "sub/deep");
    try testing.expectEqualStrings(x.path(&b2, "sub"), find(deep).?);
    try x.touch(config);
    try testing.expectEqualStrings(x.root, find(deep).?);
    try x.touch(flake);
    try testing.expectEqualStrings(x.root, find(deep).?);
}
