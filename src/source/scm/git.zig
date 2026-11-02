//! git. The tree is what git.cc:getAccessorFromWorkdir copies: the index
//! entries that still exist, no `.git`, no submodules. Each command that reads
//! the working tree is a `Cmd` observation. The date and the count follow from
//! the revision, which is one, so they are none (git.cc:getLastModified and
//! getRevCount keep them by revision). The tree of a revision follows from
//! it too; the name of a branch or a tag is a `Cmd` observation of the refs.

const std = @import("std");
const errors = @import("../../errors.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const scm_mod = @import("../scm.zig");
const Cx = scm_mod.Cx;
const Error = scm_mod.Error;
const Snapshot = scm_mod.Snapshot;
const Commit = scm_mod.Commit;
const PathEntry = scm_mod.PathEntry;
const trace_mod = @import("../../trace.zig");
const proc = @import("../proc.zig");
const Trace = trace_mod.Trace;
const Query = trace_mod.Query;
const PathSet = @import("../../builtins/store_hooks.zig").PathSet;

pub const null_rev = "0000000000000000000000000000000000000000";

pub const scm: scm_mod.Scm = .{
    .name = "git",
    .title = "Git",
    .marker = ".git",
    .snapshot = snapshot,
    .rev_count = revCount,
    .export_ignored = exportIgnored,
    .resolve = resolve,
    .tree_at = treeAt,
    .untracked = untracked,
    .tree_of = treeOf,
    .watch = watch,
};

fn treeOf(o: trace_mod.Obs) ?[]const u8 {
    return switch (o) {
        .cmd => |x| if (std.mem.eql(u8, x.query.scm(), "git")) x.dir else null,
        else => null,
    };
}

const Run = struct { status: i32, out: []const u8 };

/// `git ARGS` in `root`, through the trace: the exit status and stdout.
fn run(cx: Cx, t: Trace, root: []const u8, args: []const []const u8) Error!Run {
    const argv = try cx.a.alloc([]const u8, args.len + 1);
    argv[0] = "git";
    @memcpy(argv[1..], args);
    const o = t.cmd(cx.a, cx.io, root, argv) catch |e|
        return cx.d.fail(error.ScmFailed, "iets: cannot run git: {f}", .{errors.os(e)});
    return .{ .status = o.status, .out = o.stdout };
}

/// A traced query. Its argv comes from `trace.Query`, so the command and the
/// observation that records it can never drift apart.
fn query(cx: Cx, root: []const u8, q: Query) Error![]const u8 {
    return git(cx, cx.trace, root, q.argv()[1..]);
}

fn git(cx: Cx, t: Trace, root: []const u8, args: []const []const u8) Error![]const u8 {
    const r = try run(cx, t, root, args);
    if (r.status != 0) {
        const joined = try std.mem.join(cx.a, " ", args);
        return cx.d.fail(error.ScmFailed, "iets: `git {s}` failed in '{s}' (exit {d})", .{ joined, root, r.status });
    }
    return r.out;
}

/// A number that follows from a revision. The revision is an observation,
/// so this command is none.
fn ofRev(cx: Cx, root: []const u8, args: []const []const u8) Error!u64 {
    const out = try git(cx, Trace.off, root, args);
    return std.fmt.parseInt(u64, std.mem.trim(u8, out, " \t\r\n"), 10) catch 0;
}

/// The environment git runs in for `piped`: the caller's, and
/// `GIT_ATTR_NOSYSTEM`, as Nix opens a repository without the system's
/// attributes.
fn pipedEnv(cx: Cx) Error!std.process.Environ.Map {
    var m: std.process.Environ.Map = .init(cx.a);
    if (cx.env) |e| {
        var it = e.iterator();
        while (it.next()) |kv| try m.put(kv.key_ptr.*, kv.value_ptr.*);
    } else {
        m = try proc.processEnv(cx.a);
    }
    try m.put("GIT_ATTR_NOSYSTEM", "1");
    return m;
}

/// `git ARGS` in `root` with `stdin` as its input; the exit status and the
/// output. No observation.
fn piped(cx: Cx, root: []const u8, args: []const []const u8, stdin: []const u8) Error!Run {
    const argv = try cx.a.alloc([]const u8, args.len + 4);
    argv[0] = "git";
    argv[1] = "--no-optional-locks";
    argv[2] = "-C";
    argv[3] = root;
    @memcpy(argv[4..], args);
    var env = try pipedEnv(cx);
    const o = proc.run(cx.a, cx.io, null, argv, stdin, &env) catch |e|
        return cx.d.fail(error.ScmFailed, "iets: `git {s}` failed in '{s}': {f}", .{ args[0], root, errors.os(e) });
    return .{ .status = o.status, .out = o.stdout };
}

/// A file that changes an answer and that git tracks nowhere: its bytes, or
/// its absence, become an observation.
fn observe(cx: Cx, p: []const u8) ?[]const u8 {
    const f = scm_mod.readFileMeta(cx.io, cx.a, p) orelse {
        _ = cx.trace.statNow(p, true);
        return null;
    };
    cx.trace.file(p, f.meta, f.bytes);
    return f.bytes;
}

fn trimEnd(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " \t\r\n");
}

/// `root/rel`, or `rel` when it is absolute (`Path::join`).
fn under(a: Allocator, root: []const u8, rel: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, rel, "/")) return rel;
    return scm_mod.join(a, root, rel);
}

/// The attribute files that libgit2 reads beside the `.gitattributes` of
/// the tree, as Nix opens a repository: `$GIT_DIR/info/attributes` and the
/// file `core.attributesFile` names. libgit2 has no default for the second,
/// where git reads `$XDG_CONFIG_HOME/git/attributes`, so the `-c` this
/// gives makes git read the same files. Both files, and the setting, are
/// observed.
fn attrFiles(cx: Cx, root: []const u8) Error![]const u8 {
    const info = trimEnd(try git(cx, Trace.off, root, &.{ "rev-parse", "--git-path", "info/attributes" }));
    _ = observe(cx, try under(cx.a, root, info));
    const r = try run(cx, cx.trace, root, Query.git_attributes_file.argv()[1..]);
    const global = trimEnd(r.out);
    if (r.status != 0 or global.len == 0) return "core.attributesFile=/dev/null";
    _ = observe(cx, try under(cx.a, root, global));
    return std.fmt.allocPrint(cx.a, "core.attributesFile={s}", .{global});
}

/// The paths of `paths`, relative to the root, that `export-ignore` drops.
/// `source` is `--cached` for the index or `--source=REV` for a revision.
/// Null when git refuses.
fn checkExport(cx: Cx, root: []const u8, source: []const u8, paths: []const []const u8) Error!?PathSet {
    const config = try attrFiles(cx, root);
    var stdin: std.ArrayList(u8) = .empty;
    for (paths) |p| {
        try stdin.appendSlice(cx.a, p);
        try stdin.append(cx.a, 0);
    }
    const r = try piped(cx, root, &.{ "-c", config, "check-attr", source, "-z", "--stdin", "export-ignore" }, stdin.items);
    if (r.status != 0) return null;
    var out: PathSet = .empty;
    var fields = std.mem.splitScalar(u8, r.out, 0);
    while (true) {
        const path = fields.next() orelse break;
        _ = fields.next() orelse break;
        const info = fields.next() orelse break;
        if (std.mem.eql(u8, info, "set")) try out.put(cx.a, path, {});
    }
    return out;
}

/// The entries of `paths` that `export-ignore` drops, after the
/// `.gitattributes` in the index (git-utils.cc:GitExportIgnoreSourceAccessor
/// on a working tree). The index is what `ls-files` observes, so this query
/// is none.
fn exportIgnored(cx: Cx, root: []const u8, paths: *const PathSet) Error!PathSet {
    var rel: std.ArrayList([]const u8) = .empty;
    var it = paths.keyIterator();
    while (it.next()) |p| if (stripRoot(p.*, root)) |r| try rel.append(cx.a, r);
    const dropped = (try checkExport(cx, root, "--cached", rel.items)) orelse
        return cx.d.fail(error.ScmFailed, "iets: `git check-attr` failed in '{s}'", .{root});
    var out: PathSet = .empty;
    var dt = dropped.keyIterator();
    while (dt.next()) |p| try out.put(cx.a, try scm_mod.join(cx.a, root, p.*), {});
    return out;
}

/// `p` relative to `root`, when it lies strictly below it.
pub fn stripRoot(p: []const u8, root: []const u8) ?[]const u8 {
    const r = std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, p, r) or p.len <= r.len + 1 or p[r.len] != '/') return null;
    return p[r.len + 1 ..];
}

/// The directories that hold `path`, `""` for the root first.
fn parentsOf(a: Allocator, path: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    try out.append(a, path[0..0]);
    for (path, 0..) |b, i| if (b == '/') try out.append(a, path[0..i]);
}

fn anyParentIn(path: []const u8, set: *const PathSet) bool {
    if (set.contains("")) return true;
    for (path, 0..) |b, i| if (b == '/' and set.contains(path[0..i])) return true;
    return false;
}

fn attributesIn(a: Allocator, dir: []const u8) Allocator.Error![]const u8 {
    if (dir.len == 0) return ".gitattributes";
    return std.mem.concat(a, u8, &.{ dir, "/.gitattributes" });
}

/// git-utils.cc:GitExportIgnoreSourceAccessor at a revision asks libgit2
/// with `GIT_ATTR_CHECK_INCLUDE_COMMIT`, which reads the `.gitattributes`
/// of the working tree and of the index as well as the commit's. `git
/// check-attr --source` reads the commit's alone, so it answers the same
/// only when the other two hold the commit's files. The working tree's are
/// observed, and the index through `ls-files`.
fn sameAttributes(cx: Cx, root: []const u8, dirs: *const PathSet, oids: *const std.StringHashMapUnmanaged([]const u8), blobs: *const std.StringHashMapUnmanaged([]const u8)) Error!bool {
    const ls = try query(cx, root, .git_ls_files);
    var entries = std.mem.splitScalar(u8, ls, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
        const path = entry[tab + 1 ..];
        if (!std.mem.endsWith(u8, path, ".gitattributes")) continue;
        const d = path[0 .. path.len - ".gitattributes".len];
        const dir: ?[]const u8 = if (d.len == 0) d else if (std.mem.endsWith(u8, d, "/")) d[0 .. d.len - 1] else null;
        if (dir == null or !dirs.contains(dir.?)) continue;
        var fields = std.mem.splitScalar(u8, entry[0..tab], ' ');
        _ = fields.next();
        _ = fields.next();
        const oid = fields.next();
        const want = oids.get(path);
        if (oid == null or want == null or !std.mem.eql(u8, oid.?, want.?)) {
            if (!(oid == null and want == null)) return false;
        }
    }
    var it = dirs.keyIterator();
    while (it.next()) |dir| {
        const rel = try attributesIn(cx.a, dir.*);
        const on_disk = observe(cx, try scm_mod.join(cx.a, root, rel));
        const blob = blobs.get(rel);
        if (on_disk == null and blob == null) continue;
        if (on_disk == null or blob == null or !std.mem.eql(u8, on_disk.?, blob.?)) return false;
    }
    return true;
}

const Listed = struct { path: []const u8, mode: []const u8, oid: []const u8 };

/// The tree of `rev`, as git.cc:getAccessorFromCommit reads a local
/// repository: every blob as it is stored, a submodule as an empty
/// directory, and with `export`, no entry that `export-ignore` drops.
fn treeAt(cx: Cx, root: []const u8, rev: []const u8, exp: bool) Error!?Commit {
    const quiet = Trace.off;
    const commit = try std.fmt.allocPrint(cx.a, "{s}^{{commit}}", .{rev});
    if ((try run(cx, quiet, root, &.{ "cat-file", "-e", commit })).status != 0) return null;
    const last_modified = try ofRev(cx, root, &.{ "log", "-1", "--format=%ct", rev });
    const ls = try git(cx, quiet, root, &.{ "ls-tree", "-r", "-z", "--full-tree", rev });
    var listed: std.ArrayList(Listed) = .empty;
    var it = std.mem.splitScalar(u8, ls, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse return null;
        var fields = std.mem.splitScalar(u8, entry[0..tab], ' ');
        const mode = fields.next() orelse return null;
        _ = fields.next() orelse return null;
        const oid = fields.next() orelse return null;
        try listed.append(cx.a, .{ .path = entry[tab + 1 ..], .mode = mode, .oid = oid });
    }
    var stdin: std.ArrayList(u8) = .empty;
    for (listed.items) |l| if (!std.mem.eql(u8, l.mode, "160000")) {
        try stdin.appendSlice(cx.a, l.oid);
        try stdin.append(cx.a, '\n');
    };
    const r = try piped(cx, root, &.{ "cat-file", "--batch" }, stdin.items);
    if (r.status != 0) return null;
    var out = r.out;
    var entries: std.ArrayList(PathEntry) = try .initCapacity(cx.a, listed.items.len);
    var oids: std.StringHashMapUnmanaged([]const u8) = .empty;
    var blobs: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (listed.items) |l| {
        if (std.mem.eql(u8, l.mode, "160000")) {
            try entries.append(cx.a, .{ .path = l.path, .entry = .empty });
            continue;
        }
        const nl = std.mem.indexOfScalar(u8, out, '\n') orelse return null;
        const sp = std.mem.lastIndexOfScalar(u8, out[0..nl], ' ');
        const size_text = if (sp) |i| out[i + 1 .. nl] else out[0..nl];
        const size = std.fmt.parseInt(usize, size_text, 10) catch return null;
        if (nl + 1 + size >= out.len) return null;
        const bytes = out[nl + 1 .. nl + 1 + size];
        out = out[nl + 2 + size ..];
        if (std.mem.endsWith(u8, l.path, ".gitattributes")) {
            try oids.put(cx.a, l.path, l.oid);
            try blobs.put(cx.a, l.path, bytes);
        }
        const e: scm_mod.Entry = if (std.mem.eql(u8, l.mode, "100644"))
            .{ .file = .{ .bytes = bytes, .exec = false } }
        else if (std.mem.eql(u8, l.mode, "100755"))
            .{ .file = .{ .bytes = bytes, .exec = true } }
        else if (std.mem.eql(u8, l.mode, "120000"))
            .{ .symlink = bytes }
        else
            return null;
        try entries.append(cx.a, .{ .path = l.path, .entry = e });
    }
    var dirs: PathSet = .empty;
    var ps: std.ArrayList([]const u8) = .empty;
    for (entries.items) |e| {
        ps.clearRetainingCapacity();
        try parentsOf(cx.a, e.path, &ps);
        for (ps.items) |p| try dirs.put(cx.a, p, {});
    }
    if (exp) {
        if (!try sameAttributes(cx, root, &dirs, &oids, &blobs)) return null;
        var asked: std.ArrayList([]const u8) = .empty;
        for (entries.items) |e| try asked.append(cx.a, e.path);
        var dit = dirs.keyIterator();
        while (dit.next()) |d| if (d.len > 0) try asked.append(cx.a, d.*);
        const src = try std.fmt.allocPrint(cx.a, "--source={s}", .{rev});
        const dropped = (try checkExport(cx, root, src, asked.items)) orelse return null;
        var kept: std.ArrayList(PathEntry) = .empty;
        for (entries.items) |e| if (keptBy(&dropped, e.path)) try kept.append(cx.a, e);
        // an export keeps a directory whose entries it all drops
        dit = dirs.keyIterator();
        while (dit.next()) |d| if (d.len > 0 and keptBy(&dropped, d.*)) try kept.append(cx.a, .{ .path = d.*, .entry = .empty });
        entries = kept;
    }
    return .{ .rev = try cx.a.dupe(u8, rev), .last_modified = last_modified, .entries = entries.items };
}

fn keptBy(dropped: *const PathSet, p: []const u8) bool {
    if (dropped.contains(p)) return false;
    return !anyParentIn(p, dropped);
}

/// git-utils.cc:getWorkdirInfo: index entries minus deleted ones; dirty
/// when any tracked file differs from HEAD or the index.
fn snapshot(cx: Cx, root: []const u8) Error!Snapshot {
    // `-v` tags an entry that git checks against the working tree no more
    // (`S` for skip-worktree, lower case for assume-unchanged): `git status`
    // never reports such an entry, while libgit2's status, which
    // getWorkdirInfo reads, still calls it deleted when it is not on disk
    const ls = try query(cx, root, .git_ls_files);
    var files: PathSet = .empty;
    var dirty = false;
    var it = std.mem.splitScalar(u8, ls, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, entry, '\t') orelse continue;
        var fields = std.mem.splitScalar(u8, entry[0..tab], ' ');
        const tag = fields.next() orelse "";
        if (std.mem.eql(u8, fields.next() orelse "", "160000")) continue;
        const file = try scm_mod.join(cx.a, root, entry[tab + 1 ..]);
        if (!std.mem.eql(u8, tag, "H") and cx.trace.statNow(file, false) == .missing) {
            dirty = true;
            continue;
        }
        try files.put(cx.a, file, {});
    }
    const status = try query(cx, root, .git_status);
    var st = std.mem.splitScalar(u8, status, 0);
    while (st.next()) |entry| {
        if (entry.len <= 3) continue;
        dirty = true;
        if (entry[0] == 'D' or entry[1] == 'D') {
            const p = try scm_mod.join(cx.a, root, entry[3..]);
            _ = files.remove(p);
        }
    }
    const head = try run(cx, cx.trace, root, Query.git_head.argv()[1..]);
    const head_rev: ?[]const u8 = if (head.status == 0) std.mem.trim(u8, head.out, " \t\r\n") else null;
    const last_modified = if (head_rev) |h| try ofRev(cx, root, &.{ "log", "-1", "--format=%ct", h }) else 0;
    const shallow = try scm_mod.join(cx.a, root, ".git/shallow");
    const is_shallow = cx.trace.statNow(shallow, true) != .missing;
    return .{
        .files = files,
        .dirty = dirty,
        // git.cc gives a clean tree without a commit the null revision
        .rev = head_rev orelse if (!dirty) null_rev else null,
        .last_modified = last_modified,
        .countable = !is_shallow,
    };
}

/// git-utils.cc:resolveRef, which is `git_revparse_single`: git's own
/// lookup of a name, peeled to the commit. The refs are observed whole.
fn resolve(cx: Cx, root: []const u8, name: []const u8) Error!?[]const u8 {
    _ = try run(cx, cx.trace, root, Query.git_refs.argv()[1..]);
    const commit = try std.fmt.allocPrint(cx.a, "{s}^{{commit}}", .{name});
    const r = try run(cx, Trace.off, root, &.{ "rev-parse", "--verify", "-q", "--end-of-options", commit });
    const rev = std.mem.trim(u8, r.out, " \t\r\n");
    return if (r.status == 0 and rev.len > 0) rev else null;
}

fn revCount(cx: Cx, root: []const u8, rev: []const u8) Error!u64 {
    // git.cc gives the null revision the count 0
    if (std.mem.eql(u8, rev, null_rev)) return 0;
    return ofRev(cx, root, &.{ "rev-list", "--count", rev });
}

fn untracked(cx: Cx, root: []const u8, rel: []const u8) ?[]const u8 {
    var child = std.process.spawn(cx.io, .{
        .argv = &.{ "git", "--no-optional-locks", "-C", root, "ls-files", "--error-unmatch", "--", rel },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const term = child.wait(cx.io) catch return null;
    const ok = switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (ok) return null;
    return std.fmt.allocPrint(cx.a, "git -C \"{s}\" add \"{s}\"", .{ root, rel }) catch null;
}

/// `git ls-files`, `git status` and the `HEAD` queries all change with the
/// index: a commit, a checkout and `git add` rewrite it. A linked work tree
/// has a `.git` file that names its git directory.
fn watch(a: Allocator, io: Io, root: []const u8) Allocator.Error!?[]const u8 {
    const dot = try scm_mod.join(a, root, ".git");
    const m = sysfs.stat(dot, true) catch return null;
    if (m.isDir()) return try scm_mod.join(a, dot, "index");
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, dot, &buf) catch return null;
    if (!std.mem.startsWith(u8, text, "gitdir: ")) return null;
    return try scm_mod.join(a, try under(a, root, trimEnd(text["gitdir: ".len..])), "index");
}

const sysfs = @import("../../sys/fs.zig");

const testing = std.testing;

test "a path strictly below the root is relative to it" {
    try testing.expectEqualStrings("a/b", stripRoot("/r/a/b", "/r").?);
    try testing.expectEqualStrings("a", stripRoot("/r/a", "/r/").?);
    try testing.expect(stripRoot("/r", "/r") == null);
    try testing.expect(stripRoot("/rx/a", "/r") == null);
}
