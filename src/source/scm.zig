//! The source control system (SCM) of a local working tree. An `Scm`
//! supplies what such a tree gives to an evaluation: its root, the files it
//! tracks, the dirty flag and the metadata of its revision. `known` is the
//! one list of the implementations, and the callers reach them through the
//! functions below it, never by name. A remote input (`git+https:`, `hg+`)
//! is a fetcher and is not here.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const trace_mod = @import("../trace.zig");
const Trace = trace_mod.Trace;
const PathSet = @import("../builtins/store_hooks.zig").PathSet;

pub const git = @import("scm/git.zig");
pub const ledger = @import("scm/ledger.zig");

/// What an `Scm` call works with. `a` holds every answer; `d` the message
/// of a failure.
pub const Cx = struct {
    gpa: Allocator,
    io: Io,
    /// Holds what the answers point into; the caller frees it as a whole.
    a: Allocator,
    trace: Trace,
    /// The environment a command runs in; the process's when null.
    env: ?*const std.process.Environ.Map = null,
    d: *Diag,
};

pub const Error = error{ ScmFailed, OutOfMemory };

/// A working tree as its SCM reports it.
pub const Snapshot = struct {
    /// The tracked files that are in the working tree, as absolute paths.
    /// The working tree supplies their contents and their modes.
    files: PathSet,
    /// A tracked file differs from the revision.
    dirty: bool,
    /// The revision the tree is at, as the SCM spells it: `rev` on a clean
    /// tree, the start of `dirtyRev` on a dirty one. Null when the SCM has
    /// no name for it.
    rev: ?[]const u8,
    /// The date of the revision in seconds since the epoch, 0 without one.
    last_modified: u64,
    /// The SCM has the whole history of the revision, so `revCount` has an
    /// answer. A shallow clone has not.
    countable: bool,
};

/// One entry of a revision's tree.
pub const Entry = union(enum) {
    file: struct { bytes: []const u8, exec: bool },
    symlink: []const u8,
    /// A directory with nothing in it: what a submodule is when its
    /// contents are not copied.
    empty,
};

/// An entry by its path below the root, with `/` between the parts.
pub const PathEntry = struct { path: []const u8, entry: Entry };

/// A revision of a repository as its SCM reports it. Every answer follows
/// from the revision, which never changes.
pub const Commit = struct {
    rev: []const u8,
    last_modified: u64,
    /// A directory is implied by the entries below it.
    entries: []const PathEntry,
};

/// One SCM. The functions get the root of the working tree as an absolute
/// path.
pub const Scm = struct {
    /// The `type` of the tree as an input and the scheme of its URL: `git`
    /// in `git+file://`.
    name: []const u8,
    /// The name as a message spells it: `Git`.
    title: []const u8,
    /// The entry whose presence makes a directory the root of a working
    /// tree of this SCM.
    marker: []const u8,
    /// Reads the working tree. Each answer that does not come from a
    /// tracked file is recorded in the trace.
    snapshot: *const fn (cx: Cx, root: []const u8) Error!Snapshot,
    /// The number of revisions up to `rev`, for a `countable` tree. The
    /// answer follows from `rev`, so it is no observation.
    rev_count: *const fn (cx: Cx, root: []const u8, rev: []const u8) Error!u64,
    /// The entries of `paths` that an export of the working tree leaves out
    /// (`export-ignore` in git). Null: none.
    export_ignored: ?*const fn (cx: Cx, root: []const u8, paths: *const PathSet) Error!PathSet = null,
    /// The revision that `name`, a branch or a tag, points to; null when
    /// there is none or the SCM cannot tell, and the caller asks Nix.
    resolve: ?*const fn (cx: Cx, root: []const u8, name: []const u8) Error!?[]const u8 = null,
    /// The tree of revision `rev`, without what an export leaves out when
    /// `export` is set; null when the repository has not got it or the SCM
    /// cannot read it the way Nix does.
    tree_at: ?*const fn (cx: Cx, root: []const u8, rev: []const u8, exp: bool) Error!?Commit = null,
    /// For `rel`, a file on disk below `root` the SCM does not track: the
    /// command that makes the SCM track it. Null when it is tracked.
    untracked: *const fn (cx: Cx, root: []const u8, rel: []const u8) ?[]const u8,
    /// The root of the working tree that `o` is about, when `snapshot` of
    /// this SCM recorded `o`.
    tree_of: *const fn (o: trace_mod.Obs) ?[]const u8,
    /// The file that changes when an answer of the SCM on the tree at
    /// `root` changes, for a program that watches files; null when the
    /// observations of the SCM are files and nothing else.
    watch: *const fn (a: Allocator, io: Io, root: []const u8) Allocator.Error!?[]const u8,

    /// `dir/marker`, in `a`.
    pub fn rootMarker(s: *const Scm, a: Allocator, dir: []const u8) Allocator.Error![]const u8 {
        return join(a, dir, s.marker);
    }
};

/// `dir/name`, without a doubled slash at the root.
pub fn join(a: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]const u8 {
    const sep: []const u8 = if (std.mem.endsWith(u8, dir, "/")) "" else "/";
    return std.mem.concat(a, u8, &.{ dir, sep, name });
}

/// Every SCM iets knows, in the order detection asks them. The ledger is a
/// made-up SCM that only the tests know.
pub const known: []const *const Scm = if (builtin.is_test) &.{ &git.scm, &ledger.scm } else &.{&git.scm};

/// The marker of each SCM, for `project.zig`, in the order detection asks.
pub const markers: [known.len][]const u8 = blk: {
    var m: [known.len][]const u8 = undefined;
    for (known, 0..) |s, i| m[i] = s.marker;
    break :blk m;
};

fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// The SCM that has a working tree with its root at `root`.
pub fn at(io: Io, root: []const u8) ?*const Scm {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (known) |s| {
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const m = s.rootMarker(fba.allocator(), root) catch continue;
        if (exists(io, m)) return s;
    }
    return null;
}

fn parent(dir: []const u8) ?[]const u8 {
    if (dir.len <= 1) return null;
    const i = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
    return if (i == 0) "/" else dir[0..i];
}

pub const Found = struct { scm: *const Scm, root: []const u8 };

/// The working tree that holds `dir`: its SCM and its root, the nearest
/// ancestor (or `dir` itself) that an SCM knows as one. The root is a
/// prefix of `dir`.
pub fn detect(io: Io, dir: []const u8) ?Found {
    var d: ?[]const u8 = dir;
    while (d) |x| : (d = parent(x)) {
        if (at(io, x)) |s| return .{ .scm = s, .root = x };
    }
    return null;
}

/// Records the probes a `detect` of `dir` made, `found` being the root it
/// stopped at. Without them a cached result stays a path flake after a
/// working tree appears above `dir`.
pub fn recordDetect(t: Trace, dir: []const u8, found: ?[]const u8) void {
    if (!t.isOn()) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var d: ?[]const u8 = dir;
    while (d) |x| : (d = parent(x)) {
        for (known) |s| {
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            const m = s.rootMarker(fba.allocator(), x) catch continue;
            _ = t.statNow(m, true);
        }
        if (found) |f| if (std.mem.eql(u8, f, x)) return;
    }
}

/// The SCM that recorded `o`, and the root of the working tree that `o`
/// is about.
pub fn owner(o: trace_mod.Obs) ?Found {
    for (known) |s| if (s.tree_of(o)) |root| return .{ .scm = s, .root = root };
    return null;
}

/// Why a cached result is stale when `o` no longer holds: the tree is what
/// the user changed, not the answer of one query. In `a`.
pub fn changed(a: Allocator, o: trace_mod.Obs) ?[]u8 {
    const w = owner(o) orelse return null;
    return std.fmt.allocPrint(a, "the {s} working tree in {s} changed", .{ w.scm.name, w.root }) catch null;
}

pub fn named(name: []const u8) ?*const Scm {
    for (known) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// A file read whole, with what a `stat` (following links) reported of
/// it, for an observation; null when it is no regular file that reads.
pub fn readFileMeta(io: Io, a: Allocator, p: []const u8) ?struct { meta: sysfs.Meta, bytes: []u8 } {
    const meta = sysfs.stat(p, true) catch return null;
    if (!meta.isFile()) return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, p, a, .unlimited) catch return null;
    return .{ .meta = meta, .bytes = bytes };
}

const sysfs = @import("../sys/fs.zig");

/// The key the run's store keeps a count under.
pub fn countKey(a: Allocator, s: *const Scm, rev: []const u8) Allocator.Error![]const u8 {
    var k: trace_mod.key.Key = .init("rev-count");
    k.field("scm", s.name);
    k.field("rev", rev);
    return a.dupe(u8, &k.finish());
}

/// `Scm.rev_count`, asked once for each revision: the store of the run
/// keeps the answer with the name of the SCM and the revision as the key,
/// as git.cc:getRevCount does in the fetcher cache of Nix.
pub fn revCount(cx: Cx, s: *const Scm, root: []const u8, rev: []const u8) Error!u64 {
    const key = try countKey(cx.a, s, rev);
    if (cx.trace.kept(cx.a, key)) |b| if (std.fmt.parseInt(u64, b, 10)) |n| return n else |_| {};
    const n = try s.rev_count(cx, root, rev);
    var buf: [24]u8 = undefined;
    cx.trace.keep(key, std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
    return n;
}

test {
    _ = git;
    _ = ledger;
}

test "detection finds the nearest working tree" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "w/.ledger");
    try tmp.dir.createDirPath(io, "w/a/b");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const gpa = std.testing.allocator;
    const dir = try std.fmt.allocPrint(gpa, "{s}/w/a/b", .{base});
    defer gpa.free(dir);
    const f = detect(io, dir).?;
    try std.testing.expectEqualStrings("ledger", f.scm.name);
    try std.testing.expect(std.mem.endsWith(u8, f.root, "/w"));
    try std.testing.expect(named("git") == &git.scm);
    try std.testing.expect(named("svn") == null);
}
