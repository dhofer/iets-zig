//! `builtins.fetchGit` (fetchTree.cc with `isFetchGit`, git.cc). A local
//! working tree without a `ref` or a `rev` is copied the way the flake's own
//! tree is (git.cc:getAccessorFromWorkdir), so the tracing cache follows its
//! files. A commit of a local repository, by `rev` or by `ref`, is read
//! from the repository (git.cc:getAccessorFromCommit). Any other fetch goes
//! to Nix's own `fetchGit`, as a git flake input does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const text = @import("../syntax/text.zig");
const StorePath = @import("../store/path.zig").StorePath;
const lint = @import("../lint.zig");
const flakeref = @import("../flake/flakeref.zig");
const source = @import("../source.zig");
const Attrs = source.Attrs;
const AttrVal = source.AttrVal;
const strAttr = source.strAttr;
const boolAttr = source.boolAttr;
const Tree = source.Tree;
const fetch = @import("fetch.zig");

const null_rev = source.scm.git.null_rev;

/// git.cc:GitInputScheme::allowedAttrs.
const allowed = [_][]const u8{ "url", "ref", "rev", "shallow", "submodules", "lfs", "exportIgnore", "lastModified", "revCount", "narHash", "allRefs", "name", "dirtyRev", "dirtyShortRev", "verifyCommit", "keytype", "publicKey", "publicKeys" };

const flags = [_][]const u8{ "shallow", "submodules", "lfs", "exportIgnore", "allRefs", "verifyCommit" };

/// The attributes the copy of a working tree reads; any other goes to Nix.
const from_workdir = [_][]const u8{ "url", "name", "shallow", "submodules", "lfs", "exportIgnore", "allRefs" };

/// The attributes the read of a commit takes; any other goes to Nix.
const from_commit_keys = [_][]const u8{ "url", "name", "rev", "ref", "submodules", "exportIgnore" };

fn among(k: []const u8, set: []const []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, k)) return true;
    return false;
}

fn only(args: *const Attrs, keys: []const []const u8) bool {
    for (args.items()) |e| if (!among(e.key, keys)) return false;
    return true;
}

const refError = @import("flake.zig").refError;

pub fn fetchGit(ev: *Evaluator, args_in: []const Value, pos: Pos) Error!Value {
    try lint.purity.unhashedFetch(ev, "fetchGit", args_in[0], pos);
    const a = ev.local.arena.allocator();
    var args = try callAttrs(ev, args_in[0], pos);
    const url = strAttr(&args, "url") orelse return ev.fail(.eval, pos, "input attribute 'url' is missing", .{});
    var d: Diag = .init(a);
    const fixed: ?[]const u8 = flakeref.fixGitUrl(a, url, &d) catch |e| switch (e) {
        error.Unsupported => if (ev.config.pure) return refError(ev, e, &d, pos) else null,
        else => return refError(ev, e, &d, pos),
    };
    const submodules = boolAttr(&args, "submodules") orelse false;
    if (!submodules) try args.putFirst(a, "exportIgnore", .{ .bool = true });
    if (ev.config.pure) try checkLocked(ev, &args, fixed orelse url, pos);
    const root: ?[]const u8 = if (fixed) |f| try workdirRoot(a, f) else null;
    const tree: ?Tree = blk: {
        const r = root orelse break :blk null;
        if (only(&args, &from_workdir)) break :blk try fromWorkdir(ev, &args, r, pos);
        if (only(&args, &from_commit_keys)) break :blk try fromCommit(ev, &args, r, pos);
        break :blk null;
    };
    if (tree) |t| return fetch.emitTreeAttrs(ev, &t, null, pos);
    const shown = (try inputString(a, &args, fixed orelse url)) orelse url;
    return fromNix(ev, &args, shown, pos);
}

/// fetchTree.cc:fetchTree with `isFetchGit`: a string is the URL, and an
/// attribute set has no `type`.
fn callAttrs(ev: *Evaluator, arg: Value, pos: Pos) Error!Attrs {
    const a = ev.local.arena.allocator();
    const w = try ev.force(arg);
    if (w.kind() != .attrs) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ev.gpa);
        var ctx: std.ArrayList(Ctx) = .empty;
        defer ctx.deinit(ev.gpa);
        try ev.coerceToString(w, &out, &ctx, pos, "while evaluating the first argument passed to 'fetchGit'", .{ .copy_to_store = false });
        var m: Attrs = .{};
        // `out` goes on return: the url is a copy
        try m.put(a, "url", .{ .str = try std.fmt.allocPrint(a, "{f}", .{text.lossy(out.items)}) });
        return m;
    }
    const set = try ev.forceAttrs(w, pos, "");
    if (set.get(ev.s.type) != null) return ev.fail(.eval, pos, "unexpected argument 'type'", .{});
    const attrs = try fetch.inputAttrs(ev, set, "fetchGit", pos);
    // fetchers.cc:Input::fromAttrs, then git.cc:inputFromAttrs
    for (attrs.items()) |e| if (!among(e.key, &allowed))
        return ev.fail(.eval, pos, "input attribute '{s}' not supported by scheme 'git'", .{e.key});
    for (flags) |k| if (attrs.get(k)) |v| if (v != .bool)
        return ev.fail(.eval, pos, "input attribute '{s}' is not a Boolean", .{k});
    return attrs;
}

/// fetchers.cc:Input::to_string of the input `args` make.
fn inputString(a: Allocator, args: *const Attrs, url: []const u8) Error!?[]const u8 {
    var input = try args.clone(a);
    try input.put(a, "type", .{ .str = "git" });
    try input.put(a, "url", .{ .str = url });
    var d: Diag = .init(a);
    return flakeref.attrsToString(a, &input, &d) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// fetchTree.cc:fetchTree: a pure evaluation fetches a `rev` that is not
/// the null revision, or warns and fetches what a `narHash` checks.
fn checkLocked(ev: *Evaluator, args: *const Attrs, url: []const u8, pos: Pos) Error!void {
    if (strAttr(args, "rev")) |r| if (!std.mem.eql(u8, r, null_rev)) return;
    const shown = (try inputString(ev.local.arena.allocator(), args, url)) orelse
        return ev.fail(.unsupported, pos, "an unlocked Git input '{s}' in pure evaluation mode is not supported", .{url});
    if (args.contains("narHash")) {
        ev.log("warning: Input '{s}' is unlocked (e.g. lacks a Git revision) but is checked by NAR hash. This is not reproducible and will break after garbage collection or when shared.", .{shown});
        return;
    }
    return ev.fail(.eval, pos, "in pure evaluation mode, 'fetchGit' doesn't fetch unlocked input '{s}'", .{shown});
}

/// git.cc:getRepoInfo: the path of a `file:` URL, when it is absolute. It
/// is a working tree when it has a `.git`; any other is a repository.
fn workdirRoot(a: Allocator, url: []const u8) Error!?[]const u8 {
    const p = (flakeref.fileUrlPath(a, url) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    }) orelse return null;
    return if (std.mem.startsWith(u8, p, "/")) p else null;
}

/// git.cc:getAccessorFromWorkdir, with fetchTree.cc:emitTreeAttrs'
/// `emptyRevFallback`. Null when Nix must answer: the tree is not a working
/// tree, it has submodules to copy, or its count needs history that a
/// shallow clone does not have.
fn fromWorkdir(ev: *Evaluator, args: *const Attrs, root: []const u8, pos: Pos) Error!?Tree {
    const a = ev.local.arena.allocator();
    const git = &source.scm.git.scm;
    const t = ev.trace();
    if (t.statNow(try git.rootMarker(a, root), true) == .missing) return null;
    const submodules = boolAttr(args, "submodules") orelse false;
    if (submodules and t.statNow(try source.scm.join(a, root, ".gitmodules"), false) != .missing) return null;
    const name = strAttr(args, "name") orelse "source";
    const exp = boolAttr(args, "exportIgnore") orelse false;
    const wd = try source.local.workdir(ev, git, root, name, exp, pos);
    var tree = wd.tree;
    const shallow = boolAttr(args, "shallow") orelse false;
    if (!wd.dirty and !shallow and tree.counter == null) return null;
    if (wd.dirty) ev.log("warning: Git tree '{s}' is dirty", .{root});
    if (shallow) tree.counter = null;
    try tree.attrs.put(a, "submodules", .{ .bool = submodules });
    try tree.attrs.putFirst(a, "rev", .{ .str = null_rev });
    if (tree.counter == null) try tree.attrs.put(a, "revCount", .{ .int = 0 });
    return tree;
}

/// git.cc:getAccessorFromCommit on a local repository: the tree of `rev`,
/// or of the commit that `ref` names, which iets reads itself. Null when
/// Nix must answer: the repository has no working tree or is shallow, it
/// has submodules to copy, it lacks the revision, or `ref` names none.
fn fromCommit(ev: *Evaluator, args: *const Attrs, root: []const u8, pos: Pos) Error!?Tree {
    if (boolAttr(args, "submodules") orelse false) return null;
    const a = ev.local.arena.allocator();
    const git = &source.scm.git.scm;
    const t = ev.trace();
    const marker = try git.rootMarker(a, root);
    const shallow = try source.scm.join(a, marker, "shallow");
    for ([_]struct { []const u8, bool }{ .{ marker, false }, .{ shallow, true } }) |c| {
        const missing = t.statNow(c[0], true) == .missing;
        if (missing != c[1]) return null;
    }
    const rev: []const u8 = blk: {
        if (strAttr(args, "rev")) |r| {
            if (isRev(r)) break :blk r;
            return null;
        }
        const name = strAttr(args, "ref") orelse return null;
        if (!isRefName(name)) return null;
        var d: Diag = .init(ev.gpa);
        defer d.deinit();
        break :blk (git.resolve.?(source.scmCx(ev, &d), root, name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScmFailed => return ev.fail(.io, pos, "{s}", .{d.message()}),
        }) orelse return null;
    };
    const exp = boolAttr(args, "exportIgnore") orelse false;
    const name = strAttr(args, "name") orelse "source";
    return source.local.commitTree(ev, git, root, rev, name, exp, pos);
}

/// A full revision that is not the null one; any other spelling goes to
/// Nix, which checks it.
fn isRev(r: []const u8) bool {
    if (r.len != 40 or std.mem.eql(u8, r, null_rev)) return false;
    for (r) |b| if (!((b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))) return false;
    return true;
}

/// A plain branch or tag name; any other goes to Nix, which checks it.
fn isRefName(r: []const u8) bool {
    if (r.len == 0) return false;
    if (r[0] == '-' or r[0] == '/' or r[0] == '.') return false;
    if (r[r.len - 1] == '/' or r[r.len - 1] == '.') return false;
    if (std.mem.indexOf(u8, r, "..") != null or std.mem.indexOf(u8, r, "//") != null) return false;
    for (r) |b| if (!(std.ascii.isAlphanumeric(b) or b == '.' or b == '_' or b == '-' or b == '/' or b == '+')) return false;
    return true;
}

/// Nix's `fetchGit` with the call's own attributes. A result with a `rev`
/// asked for follows from it, so only the store path is an observation; any
/// other depends on the repository now, and the run is uncacheable.
fn fromNix(ev: *Evaluator, args: *const Attrs, shown: []const u8, pos: Pos) Error!Value {
    const a = ev.local.arena.allocator();
    const is_locked = if (strAttr(args, "rev")) |r| !std.mem.eql(u8, r, null_rev) else false;
    if (!is_locked) ev.trace().markUncacheable();
    const got = try source.remote.fetchGitWithNix(ev, args, shown, pos);
    var attrs = try got.clone(a);
    try attrs.put(a, "type", .{ .str = "git" });
    const out = strAttr(&attrs, "outPath") orelse return ev.fail(.eval, pos, "iets: nix gave no store path", .{});
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const path = StorePath.parse(out, &d) catch return ev.fail(.eval, pos, "iets: nix gave no store path", .{});
    const nar_hash = blk: {
        const h = strAttr(&attrs, "narHash") orelse break :blk null;
        break :blk source.parseNarHash(h, &d) catch null;
    } orelse return ev.fail(.eval, pos, "iets: nix gave no narHash", .{});
    var input: Attrs = .{};
    for ([_][]const u8{ "type", "rev", "narHash" }) |k| if (attrs.get(k)) |v| try input.put(a, k, v);
    if (args.get("url")) |v| try input.put(a, "url", v);
    try source.remote.ensureReadable(ev, &path, nar_hash, &input, pos);
    const tree: Tree = .{ .path = path, .attrs = attrs };
    return fetch.emitTreeAttrs(ev, &tree, null, pos);
}

const testing = std.testing;

test "only a full lowercase rev is a rev" {
    const rev = "61c2d57b4c40383bc42bf989900543aaba01d24f";
    try testing.expect(isRev(rev));
    try testing.expect(!isRev(null_rev));
    try testing.expect(!isRev("61C2D57B4C40383BC42BF989900543AABA01D24F"));
    try testing.expect(!isRev(rev[0..7]));
}

test "a plain ref name is read by iets" {
    for ([_][]const u8{ "main", "HEAD", "v1.0", "refs/tags/v1", "a_b+c" }) |r| try testing.expect(isRefName(r));
}

test "a ref name git would refuse is not" {
    for ([_][]const u8{ "", "-x", "/a", "a/", "a..b", "a//b", "a b", "a~1", "a^", "x.", ".x" }) |r| try testing.expect(!isRefName(r));
}

test "a working tree is a file url of an absolute path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    for ([_]struct { []const u8, ?[]const u8 }{
        .{ "/r/a b", "/r/a b" },
        .{ "file:///r/x", "/r/x" },
        .{ "git+file:///r/x", "/r/x" },
        .{ "rel/x", null },
        .{ "https://x.org/a.git", null },
    }) |c| {
        const fixed = try flakeref.fixGitUrl(a, c[0], &d);
        const got = try workdirRoot(a, fixed);
        if (c[1]) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }
}
