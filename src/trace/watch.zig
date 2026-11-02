//! Which paths of a read set a watcher can use. The selection is for a
//! watcher that compares modification times, which is all a file watcher
//! has.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const trace = @import("../trace.zig");
const Obs = trace.Obs;
const sysfs = @import("../sys/fs.zig");
const store_path = @import("../store/path.zig");

/// A watcher stats every path it holds, and a caller that writes them into
/// an environment has a size limit, so the list has a bound.
pub const max = 500;

pub const Watched = struct {
    path: []const u8,
    /// `content` a file the run read, `listing` a directory it listed,
    /// `absent` a path it found missing, `scm` the file a source-control
    /// query depends on, `member` a file under a tree the run copied.
    kind: []const u8,
};

/// Whether `p` is `root` or below it, by whole components.
fn under(p: []const u8, root: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, p, r)) return false;
    return p.len == r.len or p[r.len] == '/' or r.len == 0;
}

/// The watchable paths of `obs`, in the order the run read them. `skip`
/// names roots that never change under a watcher (the Nix store, iets's own
/// stores). A tree that lies inside another tree is a path the expression
/// copied, so its members follow. An outermost tree is the flake's source,
/// which every edit changes and few shells depend on: only what the run read
/// out of it is watched. Environment variables and resolved links have no
/// file. Everything is `a`'s.
pub fn watched(a: Allocator, io: Io, obs: []const Obs, skip: []const []const u8) Allocator.Error![]Watched {
    var out: std.ArrayList(Watched) = .empty;
    const Tree = struct { root: []const u8, filtered: ?trace.Filtered };
    var trees: std.ArrayList(Tree) = .empty;
    for (obs) |o| {
        switch (o) {
            .file => |x| if (kept(x.path, skip)) try out.append(a, .{ .path = x.path, .kind = "content" }),
            .dir => |x| if (kept(x.path, skip)) try out.append(a, .{ .path = x.path, .kind = "listing" }),
            // A `Stat` observed existence and kind, which an mtime does not
            // answer: a git index refresh moves `.git` while it is still a
            // directory. A `Missing` path has no mtime to churn, and its
            // creation is the change it looks like.
            .stat => |x| if (x.kind == .missing and kept(x.path, skip)) try out.append(a, .{ .path = x.path, .kind = "absent" }),
            .tree => |x| if (kept(x.root, skip)) try trees.append(a, .{ .root = x.root, .filtered = x.filtered }),
            else => if (@import("../source/scm.zig").owner(o)) |w| if (kept(w.root, skip)) if (try w.scm.watch(a, io, w.root)) |p|
                try out.append(a, .{ .path = p, .kind = "scm" }),
        }
    }
    for (trees.items) |t| {
        for (trees.items) |r| {
            if (!std.mem.eql(u8, t.root, r.root) and under(t.root, r.root)) {
                try members(a, io, t.root, t.filtered, &out);
                break;
            }
        }
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var kept_: std.ArrayList(Watched) = .empty;
    for (out.items) |w| {
        if ((try seen.getOrPut(a, w.path)).found_existing) continue;
        // a path that is not UTF-8 is not one a watcher's list can hold
        if (!std.unicode.utf8ValidateSlice(w.path)) continue;
        try kept_.append(a, w);
    }
    return kept_.items;
}

fn kept(p: []const u8, skip: []const []const u8) bool {
    for (skip) |s| if (under(p, s)) return false;
    return true;
}

fn lessBytes(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// `p` and what the copy took below it; the directories too, because an
/// entry that comes or goes changes the copy.
fn members(a: Allocator, io: Io, p: []const u8, filtered: ?trace.Filtered, out: *std.ArrayList(Watched)) Allocator.Error!void {
    if (out.items.len > max) return;
    try out.append(a, .{ .path = p, .kind = "member" });
    const m = sysfs.stat(p, false) catch return;
    if (!m.isDir()) return;
    const ents = trace.readDirKinds(a, io, p) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const kids = try a.alloc([]const u8, ents.len);
    for (ents, kids) |e, *k| k.* = try std.fs.path.join(a, &.{ p, e.name });
    std.mem.sortUnstable([]const u8, kids, {}, lessBytes);
    for (kids) |k| {
        const take = if (filtered) |f| std.sort.binarySearch([]const u8, f.accepted, k, struct {
            fn cmp(key_: []const u8, x: []const u8) std.math.Order {
                return std.mem.order(u8, key_, x);
            }
        }.cmp) != null else true;
        if (take) try members(a, io, k, filtered, out);
    }
}

/// The watchable paths of the entry file at `entry`, in the order the run
/// read them, capped at `max`; null when it is not an entry. The stores to
/// skip come from the entry itself: it lives at `<cache>/trace/<key>/entry`,
/// so its cache root is three levels up, and a caller that used
/// `--cache-dir` passes nothing extra. Everything is `a`'s.
pub fn ofEntry(gpa: Allocator, a: Allocator, io: Io, entry: []const u8) Allocator.Error!?[]Watched {
    var e = (try trace.store.Entry.open(gpa, io, entry)) orelse return null;
    defer e.deinit(gpa);
    const bytes = e.part(.readset) orelse return null;
    const obs = (try trace.wire.decodeReadset(a, bytes)) orelse return null;
    var skip: std.ArrayList([]const u8) = .empty;
    try skip.append(a, store_path.store_dir);
    var own: ?[]const u8 = entry;
    for (0..3) |_| own = if (own) |o| std.fs.path.dirname(o) else null;
    if (own) |o| try skip.append(a, o);
    // the subjects point into the entry, which goes before the caller is done
    for (obs) |*o| o.* = try o.dupe(a);
    const w = try watched(a, io, obs, skip.items);
    return w[0..@min(w.len, max)];
}

const testing = std.testing;

test "only the paths an mtime can speak for" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    for ([_][]const u8{ ".git", "src/keep", "src/drop" }) |sub| try tmp.dir.createDirPath(io, sub);
    for ([_][]const u8{ "hook.sh", "src/keep/a", "src/drop/b" }) |f| try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const d = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const at = struct {
        fn f(al: Allocator, root: []const u8, p: []const u8) []const u8 {
            return if (p.len == 0) root else std.fs.path.join(al, &.{ root, p }) catch unreachable;
        }
    }.f;
    const file = struct {
        fn f(path: []const u8) Obs {
            return .{ .file = .{ .path = path, .size = 0, .mtime_ns = 0, .ctime_ns = 0, .dev = 0, .ino = 0, .hash = @splat(0) } };
        }
    }.f;
    const tree = struct {
        fn f(root: []const u8, accepted: ?[]const []const u8) Obs {
            return .{ .tree = .{ .root = root, .nar_hash = @splat(0), .stat_hash = @splat(0), .newest = null, .filtered = if (accepted) |acc| .{ .seen_hash = null, .accepted = acc } else null } };
        }
    }.f;
    var obs: std.ArrayList(Obs) = .empty;
    try obs.appendSlice(a, &.{
        tree(d, null),
        file(at(a, d, "flake.nix")),
        file("/nix/store/aaa-source/default.nix"),
        file(at(a, d, "cache/inputs/x")),
        .{ .cmd = .{ .dir = d, .query = .git_status, .hash = @splat(0) } },
        .{ .env = .{ .name = "HOME", .value = null } },
        .{ .stat = .{ .path = at(a, d, "local.nix"), .follow = false, .kind = .missing } },
        .{ .stat = .{ .path = at(a, d, ".git"), .follow = true, .kind = .directory } },
        .{ .dir = .{ .path = at(a, d, "conf.d"), .hash = @splat(0) } },
        file(at(a, d, "flake.nix")),
        tree(at(a, d, "hook.sh"), null),
        tree(at(a, d, "src"), &.{ at(a, d, "src/keep"), at(a, d, "src/keep/a") }),
    });
    for (0..max + 1) |i| try obs.append(a, file(try std.fmt.allocPrint(a, "/nix/store/aaa-source/{d}", .{i})));
    const got = try watched(a, io, obs.items, &.{ "/nix/store", at(a, d, "cache") });
    const want = [_][]const u8{ "flake.nix", ".git/index", "local.nix", "conf.d", "hook.sh", "src", "src/keep", "src/keep/a" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(at(a, d, w), g.path);
}
