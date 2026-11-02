//! The real Nix binaries. Under the classic
//! symlink farm, `nix` on `PATH` is iets itself, so every subprocess and the
//! fallback resolve past it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const sys = @import("sys.zig");
const Env = @import("env.zig").Env;

/// Written by the farm derivation next to its `bin/`: the directory that
/// holds the nix the farm shadows.
const real_dir_file = "share/iets/real-nix-bin";

fn executable(p: []const u8) bool {
    return sys.fs.runnableFile(p);
}

/// `p` resolved, in `a`; null when it does not resolve.
fn canonicalize(a: Allocator, p: []const u8) ?[]u8 {
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (p.len >= zbuf.len) return null;
    @memcpy(zbuf[0..p.len], p);
    zbuf[p.len] = 0;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const r = std.c.realpath(zbuf[0..p.len :0], &out) orelse return null;
    return a.dupe(u8, std.mem.sliceTo(r, 0)) catch null;
}

fn readLink(a: Allocator, p: []const u8) ?[]u8 {
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (p.len >= zbuf.len) return null;
    @memcpy(zbuf[0..p.len], p);
    zbuf[p.len] = 0;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const rc = linux.readlink(zbuf[0..p.len :0], &out, out.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    return a.dupe(u8, out[0..rc]) catch null;
}

fn dirname(p: []const u8) ?[]const u8 {
    return std.fs.path.dirname(p);
}

/// The bin directory a farm entry points at: every hop of the symlink chain
/// from `p` is a directory that may carry `real_dir_file` beside it. The
/// system path is itself a symlink farm over ours, so the file is one or
/// more hops away.
fn farmRealDir(a: Allocator, io: std.Io, p: []const u8) ?[]const u8 {
    var cur: []const u8 = p;
    for (0..16) |_| {
        const dir = dirname(cur) orelse return null;
        const marker = std.fs.path.join(a, &.{ dir, "..", real_dir_file }) catch return null;
        if (std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(1 << 16))) |s| {
            return std.mem.trim(u8, s, " \t\r\n");
        } else |_| {}
        const target = readLink(a, cur) orelse return null;
        cur = if (std.fs.path.isAbsolute(target)) target else std.fs.path.join(a, &.{ dir, target }) catch return null;
    }
    return null;
}

/// A candidate that is iets, whatever build of it: this executable, or a
/// symlink chain that ends in a file named `iets`. A host can hold several
/// builds of the same source, and a farm made by one of them points at its
/// own `bin/iets`, which is not `/proc/self/exe`.
fn isIets(canonical: []const u8, me: ?[]const u8) bool {
    if (me) |m| if (std.mem.eql(u8, canonical, m)) return true;
    return std.mem.eql(u8, std.fs.path.basename(canonical), "iets");
}

/// `dir/<name>` as a real nix: the file itself when it is not iets, else the
/// bin directory the farm entry for that iets records. Null means the
/// directory offers no real nix, so the caller must look further. Without
/// this a directory that holds iets's own classic mode commands makes the
/// fallback exec iets again.
fn candidate(a: Allocator, io: std.Io, dir: []const u8, name: []const u8, me: ?[]const u8) ?[]const u8 {
    const p = std.fs.path.join(a, &.{ dir, name }) catch return null;
    if (!executable(p)) return null;
    const c = canonicalize(a, p);
    if (c == null or !isIets(c.?, me)) return p;
    const real_dir = farmRealDir(a, io, p) orelse return null;
    const r = std.fs.path.join(a, &.{ real_dir, name }) catch return null;
    return if (executable(r)) r else null;
}

/// The first `<name>` in `dirs` that is not iets, or the bin directory the
/// farm entry for an iets records. Every iets is skipped like ourselves,
/// so a second build of iets under the name `nix` never wins.
fn onPath(a: Allocator, io: std.Io, name: []const u8, dirs: []const []const u8, me: ?[]const u8) ?[]const u8 {
    for (dirs) |d| if (candidate(a, io, d, name, me)) |p| return p;
    return null;
}

fn splitPath(a: Allocator, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| try out.append(a, if (d.len == 0) "." else d);
    return out.toOwnedSlice(a);
}

/// This executable, resolved, so that it compares with what a candidate
/// resolves to.
fn thisExe(a: Allocator) ?[]const u8 {
    return canonicalize(a, "/proc/self/exe");
}

/// The real `<name>`, in `a`: `nix_bin_dir/<name>` when it exists there,
/// else the bin directory the farm on `PATH` was built for, else the first
/// `<name>` on `PATH` that is not iets.
pub fn real(a: Allocator, io: std.Io, env: Env, nix_bin_dir: ?[]const u8, name: []const u8) ?[]const u8 {
    const me = thisExe(a);
    if (nix_bin_dir) |dir| if (candidate(a, io, dir, name, me)) |p| return p;
    const dirs = splitPath(a, env.get("PATH") orelse return null) catch return null;
    return onPath(a, io, name, dirs, me) orelse sibling(a, env, name);
}

/// The farm never shadows `nix-store`, so its real location names the nix
/// installation even on a system path built without the marker.
fn sibling(a: Allocator, env: Env, name: []const u8) ?[]const u8 {
    const me = thisExe(a);
    const dirs = splitPath(a, env.get("PATH") orelse return null) catch return null;
    for (dirs) |dir| {
        const probe = std.fs.path.join(a, &.{ dir, "nix-store" }) catch return null;
        if (!executable(probe)) continue;
        const resolved = canonicalize(a, probe) orelse return null;
        const p = std.fs.path.join(a, &.{ dirname(resolved) orelse return null, name }) catch return null;
        if (executable(p)) {
            const c = canonicalize(a, p);
            if (c == null or !isIets(c.?, me)) return p;
        }
    }
    return null;
}

/// `nix` for a subprocess. A bare `nix` when none is found, so the spawn
/// error names it.
pub fn nix(a: Allocator, io: std.Io, env: Env, nix_bin_dir: ?[]const u8) []const u8 {
    return real(a, io, env, nix_bin_dir, "nix") orelse "nix";
}

const testing = std.testing;

const Tmp = struct {
    root: []u8,
    fn init() !Tmp {
        var r: [8]u8 = undefined;
        sys.random(&r);
        const root = try std.fmt.allocPrint(testing.allocator, "/tmp/iets-nixbin-{x}", .{r});
        try std.Io.Dir.cwd().createDirPath(testing.io, root);
        return .{ .root = root };
    }
    fn deinit(t: *Tmp) void {
        std.Io.Dir.cwd().deleteTree(testing.io, t.root) catch {};
        testing.allocator.free(t.root);
    }
    fn p(t: *Tmp, a: Allocator, sub: []const u8) []const u8 {
        return std.fs.path.join(a, &.{ t.root, sub }) catch unreachable;
    }
};

fn symlink(target: []const u8, at: []const u8) !void {
    try std.Io.Dir.cwd().symLink(testing.io, target, at, .{});
}

fn exe(at: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = at, .data = "#!/bin/sh\nexit 0\n", .flags = .{ .permissions = .executable_file } });
}

test "farm marker is found through two hops" {
    var t: Tmp = try .init();
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(testing.io, t.p(a, "farm/bin"));
    try cwd.createDirPath(testing.io, t.p(a, "farm/share/iets"));
    try cwd.createDirPath(testing.io, t.p(a, "sys/bin"));
    try cwd.writeFile(testing.io, .{ .sub_path = t.p(a, "farm/" ++ real_dir_file), .data = "/real/bin\n" });
    try symlink("/proc/self/exe", t.p(a, "farm/bin/nix"));
    try symlink(t.p(a, "farm/bin/nix"), t.p(a, "sys/bin/nix"));
    try testing.expectEqualStrings("/real/bin", farmRealDir(a, testing.io, t.p(a, "sys/bin/nix")).?);
    try testing.expect(farmRealDir(a, testing.io, t.p(a, "sys/bin/other")) == null);
}

test "every iets build is skipped" {
    var t: Tmp = try .init();
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = t.p(a, "x");
    const y = t.p(a, "y");
    const rl = t.p(a, "real");
    for ([_][]const u8{ x, y, rl }) |d| try std.Io.Dir.cwd().createDirPath(testing.io, d);
    for ([_][]const u8{ x, y }) |d| {
        try exe(try std.fs.path.join(a, &.{ d, "iets" }));
        try symlink(try std.fs.path.join(a, &.{ d, "iets" }), try std.fs.path.join(a, &.{ d, "nix" }));
    }
    const n = try std.fs.path.join(a, &.{ rl, "nix" });
    try exe(n);
    const dirs = [_][]const u8{ x, y, rl };
    try testing.expectEqualStrings(n, onPath(a, testing.io, "nix", &dirs, null).?);
    try testing.expect(onPath(a, testing.io, "nix", dirs[0..2], null) == null);
    const resolved = canonicalize(a, n).?;
    try testing.expect(onPath(a, testing.io, "nix", &dirs, resolved) == null);
    // what `nix-bin-dir` points at goes through the same test, so a
    // directory of iets's own classic mode commands cannot exec iets again
    try testing.expect(candidate(a, testing.io, x, "nix", null) == null);
    try testing.expectEqualStrings(n, candidate(a, testing.io, rl, "nix", null).?);
    try testing.expect(candidate(a, testing.io, rl, "nix-build", null) == null);
}
