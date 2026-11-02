//! A local tree. The working tree of an SCM is copied the way
//! git.cc:getAccessorFromWorkdir does it: the files the SCM tracks (`scm`),
//! with the working tree contents and modes; nothing untracked. A plain
//! directory is copied whole (path.cc). The copy is virtual: the store path
//! is computed from the NAR hash and registered with the store hooks, so
//! reads under it go to the working tree (`store_hooks.locate`); nothing is
//! fetched and the store is never consulted.

const std = @import("std");
const errors = @import("../errors.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const store_path = @import("../store/path.zig");
const StorePath = store_path.StorePath;
const nar = @import("../store/nar.zig");
const FileType = nar.FileType;
const hooks = @import("../builtins/store_hooks.zig");
const PathSet = hooks.PathSet;
const treestore = @import("../treestore.zig");
const source = @import("../source.zig");
const Attrs = source.Attrs;
const Tree = source.Tree;
const scm_mod = @import("scm.zig");
const Scm = scm_mod.Scm;
const trace = @import("../trace.zig");
const remote = @import("remote.zig");

fn mtimeSecs(st: Io.File.Stat) i64 {
    return @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
}

fn sri(a: Allocator, h: Hash) Allocator.Error![]const u8 {
    return h.alloc(a, .sri, true);
}

/// A directory copied whole, as a `path:` input.
pub fn pathSource(ev: *Evaluator, dir: []const u8, pos: Pos) Error!Tree {
    const a = ev.local.arena.allocator();
    const got = (try pathTree(ev, dir, null, pos)).found;
    var attrs: Attrs = .{};
    try attrs.put(a, "type", .{ .str = "path" });
    try attrs.put(a, "path", .{ .str = try a.dupe(u8, dir) });
    try attrs.put(a, "narHash", .{ .str = try sri(a, got.hash) });
    try attrs.put(a, "lastModified", .{ .int = @intCast(@max(got.mtime, 0)) });
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const path = treestore.storePath("source", got.hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    return .{ .path = path, .attrs = attrs };
}

pub const Dated = struct { hash: Hash, mtime: i64 };

/// What `pathTree` found: the tree, or the hash of a tree that is not the
/// one expected.
pub const PathTree = union(enum) { found: Dated, mismatch: Hash };

/// NAR hash of a whole directory and the newest `lstat` mtime in it. A tree
/// that is not `expect` is not made readable, and `mismatch` has its hash.
pub fn pathTree(ev: *Evaluator, dir: []const u8, expect: ?Hash, pos: Pos) Error!PathTree {
    var fp = ev.trace().fp(dir);
    const r = dumpAndMaxMtime(ev.gpa, ev.io, dir, if (fp) |*f| f else null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var eb: [128]u8 = undefined;
            return ev.fail(.io, pos, "copying '{s}' to the store: {s}", .{ dir, errors.osText(&eb, e) });
        },
    };
    if (expect) |e| if (!e.eql(r.hash)) return .{ .mismatch = r.hash };
    if (namesItsContent(dir, r.hash)) {
        ev.trace().stat(dir, false, .directory);
    } else ev.trace().treeDated(dir, trace.hashToDigest(&r.hash), r.mtime, if (fp) |*f| f else null);
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const sp = treestore.storePath("source", r.hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    try hooks.addTree(ev, &sp, dir, null, false, .{ .hash = r.hash, .size = r.size });
    return .{ .found = .{ .hash = r.hash, .mtime = r.mtime } };
}

/// A store path that is the fixed-output path of the tree just hashed: a
/// locked input that is already in `/nix/store`. Its name is its NAR hash,
/// so the tracing cache checks that it is still there and walks none of
/// it, as it does for an input store entry. Any other directory, in the
/// store or not, keeps its `Tree` observation.
fn namesItsContent(dir: []const u8, hash: Hash) bool {
    const p = StorePath.ofPath(dir) orelse return false;
    // a message the answer never shows: its allocation stays on the stack
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var d: Diag = .init(fba.allocator());
    const q = treestore.storePath(p.name(), hash, &d) catch return false;
    return q.eql(&p);
}

const MaxMtime = struct { hash: Hash, size: u64, mtime: i64 };

/// One walk for both answers, like `dumpPathAndGetMtime`: the dump already
/// reaches every entry in the tree, so the newest `lstat` mtime comes from
/// its filter instead of a second walk.
fn dumpAndMaxMtime(gpa: Allocator, io: Io, dir: []const u8, fp: ?*trace.TreeFp) !MaxMtime {
    const st = try Io.Dir.cwd().statFile(io, dir, .{ .follow_symlinks = false });
    var mtime = mtimeSecs(st);
    const F = struct {
        io: Io,
        mtime: *i64,
        fp: ?*trace.TreeFp,
        pub fn accept(f: @This(), p: []const u8, t: FileType) error{}!bool {
            if (Io.Dir.cwd().statFile(f.io, p, .{ .follow_symlinks = false })) |s| {
                f.mtime.* = @max(f.mtime.*, mtimeSecs(s));
            } else |_| {}
            if (f.fp) |x| x.entry(p, t, true);
            return true;
        }
    };
    var d: Diag = .init(gpa);
    defer d.deinit();
    const nh = try nar.narHashFiltered(gpa, io, Io.Dir.cwd(), dir, .sha256, F{ .io = io, .mtime = &mtime, .fp = fp }, &d);
    return .{ .hash = nh.hash, .size = nh.size, .mtime = mtime };
}

/// The filter set for the NAR dump: every tracked file and the directories
/// above it (CanonPath::isAllowed on the allow-list accessor).
pub fn acceptedSet(a: Allocator, root: []const u8, files: *const PathSet) Allocator.Error!PathSet {
    var acc: PathSet = .empty;
    try acc.ensureTotalCapacity(a, files.count() * 2);
    const r = std.mem.trimEnd(u8, root, "/");
    var it = files.keyIterator();
    while (it.next()) |f| {
        var p = f.*;
        while (!std.mem.eql(u8, p, r)) {
            if ((try acc.getOrPut(a, p)).found_existing) break;
            const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse break;
            p = if (i == 0) "/" else p[0..i];
        }
    }
    return acc;
}

/// The working tree of an SCM, with the flake's `subdir` carried through.
pub fn trackedSource(ev: *Evaluator, scm: *const Scm, root: []const u8, subdir: []const u8, pos: Pos) Error!Tree {
    var t = (try workdir(ev, scm, root, "source", false, pos)).tree;
    t.subdir = subdir;
    return t;
}

fn scmError(ev: *Evaluator, e: scm_mod.Error, d: *const Diag, pos: Pos) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ScmFailed => ev.fail(.io, pos, "{s}", .{d.message()}),
    };
}

/// `file://ROOT`, as the input's `url`.
fn fileUrl(a: Allocator, root: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "file://{s}", .{root});
}

/// The tree of `rev` in the repository at `root`
/// (git.cc:getAccessorFromCommit), under the store `name`, without what
/// `Scm.export_ignored` drops when `export` is set. Null when the
/// repository has not got the revision.
pub fn commitTree(ev: *Evaluator, scm: *const Scm, root: []const u8, rev: []const u8, name: []const u8, exp: bool, pos: Pos) Error!?Tree {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const tree_at = scm.tree_at orelse return null;
    const commit = (tree_at(source.scmCx(ev, &d), root, rev, exp) catch |e| return scmError(ev, e, &d, pos)) orelse return null;
    const stored = try remote.storeCommit(ev, name, commit, pos);
    const a = ev.local.arena.allocator();
    var attrs: Attrs = .{};
    try attrs.put(a, "type", .{ .str = scm.name });
    try attrs.put(a, "url", .{ .str = try fileUrl(a, root) });
    try attrs.put(a, "narHash", .{ .str = try sri(a, stored.hash) });
    try attrs.put(a, "rev", .{ .str = try a.dupe(u8, rev) });
    try attrs.put(a, "lastModified", .{ .int = commit.last_modified });
    try attrs.put(a, "submodules", .{ .bool = false });
    return .{ .path = stored.path, .attrs = attrs, .counter = .{ .scm = scm, .root = try a.dupe(u8, root) } };
}

/// `commitTree` for a flake root, with its `subdir`. The revision has to be
/// there: a root flake is never fetched.
pub fn commitSource(ev: *Evaluator, scm: *const Scm, root: []const u8, rev: []const u8, subdir: []const u8, pos: Pos) Error!Tree {
    var t = (try commitTree(ev, scm, root, rev, "source", false, pos)) orelse
        return ev.fail(.io, pos, "iets: the {s} repository at '{s}' has no revision {s}; check it out and name the directory instead", .{ scm.title, root, rev });
    t.subdir = subdir;
    return t;
}

pub const Workdir = struct { tree: Tree, dirty: bool };

/// The working tree of an SCM under the store name `name`, without what
/// `Scm.export_ignored` drops when `export` is set, and whether it is dirty.
pub fn workdir(ev: *Evaluator, scm: *const Scm, root: []const u8, name: []const u8, exp: bool, pos: Pos) Error!Workdir {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const cx = source.scmCx(ev, &d);
    const a = cx.a;
    const at = scm.snapshot(cx, root) catch |e| return scmError(ev, e, &d, pos);
    const accepted = try a.create(PathSet);
    accepted.* = try acceptedSet(a, root, &at.files);
    if (exp) if (scm.export_ignored) |f| {
        const dropped = f(cx, root, accepted) catch |e| return scmError(ev, e, &d, pos);
        if (dropped.count() > 0) {
            var kept: PathSet = .empty;
            var it = accepted.keyIterator();
            while (it.next()) |p| if (!droppedAbove(p.*, root, &dropped)) try kept.put(a, p.*, {});
            accepted.* = kept;
        }
    };
    var fp = ev.trace().fp(root);
    const F = struct {
        set: *const PathSet,
        fp: ?*trace.TreeFp,
        pub fn accept(f: @This(), p: []const u8, t: FileType) error{}!bool {
            const keep = f.set.contains(p);
            if (f.fp) |x| x.entry(p, t, keep);
            return keep;
        }
    };
    const nh = nar.narHashFiltered(ev.gpa, ev.io, Io.Dir.cwd(), root, .sha256, F{ .set = accepted, .fp = if (fp) |*x| x else null }, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var eb: [128]u8 = undefined;
            const why = if (e == error.BadPath or e == error.ReadFailed) d.message() else errors.osText(&eb, e);
            return ev.fail(.io, pos, "copying '{s}' to the store: {s}", .{ root, why });
        },
    };
    ev.trace().treeExternal(root, trace.hashToDigest(&nh.hash), accepted, if (fp) |*x| x else null);
    const path = treestore.storePath(name, nh.hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    try hooks.addTree(ev, &path, root, accepted, false, nh);
    var attrs: Attrs = .{};
    try attrs.put(a, "type", .{ .str = scm.name });
    try attrs.put(a, "url", .{ .str = try fileUrl(a, root) });
    try attrs.put(a, "narHash", .{ .str = try sri(a, nh.hash) });
    try attrs.put(a, "lastModified", .{ .int = at.last_modified });
    // fetchTree.cc:emitTreeAttrs: a dirty tree shows no count
    const counts = at.countable and !at.dirty and at.rev != null;
    if (at.rev) |h| {
        if (at.dirty) {
            try attrs.put(a, "dirtyShortRev", .{ .str = try std.fmt.allocPrint(a, "{s}-dirty", .{h[0..@min(h.len, 7)]}) });
            try attrs.put(a, "dirtyRev", .{ .str = try std.fmt.allocPrint(a, "{s}-dirty", .{h}) });
        } else try attrs.put(a, "rev", .{ .str = try a.dupe(u8, h) });
    }
    return .{
        .tree = .{
            .path = path,
            .attrs = attrs,
            .counter = if (counts) .{ .scm = scm, .root = try a.dupe(u8, root) } else null,
        },
        .dirty = at.dirty,
    };
}

/// `p`, or a directory between it and `root`, is in `dropped`.
fn droppedAbove(p: []const u8, root: []const u8, dropped: *const PathSet) bool {
    const r = std.mem.trimEnd(u8, root, "/");
    var x = p;
    while (!std.mem.eql(u8, x, r) and x.len > r.len) {
        if (dropped.contains(x)) return true;
        const i = std.mem.lastIndexOfScalar(u8, x, '/') orelse return false;
        x = x[0..i];
    }
    return false;
}

const testing = std.testing;

test "only a content-addressed store path names its content" {
    const h = hash_mod.hashBytes(.sha256, "a tree");
    const other = hash_mod.hashBytes(.sha256, "another tree");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const sp = try treestore.storePath("source", h, &d);
    var buf: [512]u8 = undefined;
    const p = sp.print(&buf);
    try testing.expect(namesItsContent(p, h));
    try testing.expect(!namesItsContent(p, other));
    var b2: [600]u8 = undefined;
    try testing.expect(!namesItsContent(try std.fmt.bufPrint(&b2, "{s}x", .{p}), h));
    try testing.expect(!namesItsContent(try std.fmt.bufPrint(&b2, "{s}/sub", .{p}), h));
    try testing.expect(!namesItsContent("/home/u/source", h));
}

test "the accepted set adds the parent directories" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: PathSet = .empty;
    try files.put(a, "/r/a/b/c.nix", {});
    try files.put(a, "/r/d.nix", {});
    const acc = try acceptedSet(a, "/r", &files);
    var v: std.ArrayList([]const u8) = .empty;
    var it = acc.keyIterator();
    while (it.next()) |k| try v.append(a, k.*);
    std.mem.sort([]const u8, v.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try testing.expectEqual(@as(usize, 4), v.items.len);
    for ([_][]const u8{ "/r/a", "/r/a/b", "/r/a/b/c.nix", "/r/d.nix" }, v.items) |w, g| try testing.expectEqualStrings(w, g);
}

test "the newest mtime covers the root and its children" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "d/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/sub/a", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "d/newest", .data = "x" });
    const f = try tmp.dir.openFile(io, "d/newest", .{ .mode = .read_write });
    const later: Io.Timestamp = .{ .nanoseconds = Io.Clock.real.now(io).nanoseconds + 1000 * std.time.ns_per_s };
    try f.setTimestamps(io, .{ .access_timestamp = .{ .new = later }, .modify_timestamp = .{ .new = later } });
    f.close(io);
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const dir = try std.fmt.allocPrint(gpa, "{s}/d", .{base});
    defer gpa.free(dir);
    const r = try dumpAndMaxMtime(gpa, io, dir, null);
    try testing.expectEqual(@as(i64, @intCast(@divFloor(later.nanoseconds, std.time.ns_per_s))), r.mtime);
    var d: Diag = .init(gpa);
    defer d.deinit();
    try testing.expect(r.hash.eql(try nar.narHash(gpa, io, Io.Dir.cwd(), dir, &d)));
}
