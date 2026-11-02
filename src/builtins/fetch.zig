//! `builtins.fetchurl`, `builtins.fetchTarball` and `builtins.fetchTree`
//! (primops/fetchTree.cc, fetchers.cc).
//!
//! The attrs `fetchTree` is given become a `source.SourceRef`, which resolves
//! to a tree; the result attrset mirrors `emitTreeAttrs`. A `path` input is a
//! virtual copy of the local directory, like the root tree. Every other input
//! is locked, and `source/remote.zig` fetches it: the store path is known
//! before the download, from the `narHash` or the `sha256`, so `/nix/store`
//! or the input store (`treestore.zig`) may hold it already, and every read
//! of a download comes out of the input store's packs.

const std = @import("std");
const Io = std.Io;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const text = @import("../syntax/text.zig");
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const store_path = @import("../store/path.zig");
const StorePath = store_path.StorePath;
const hooks = @import("store_hooks.zig");
const paths = @import("paths.zig");
const treestore = @import("../treestore.zig");
const lint = @import("../lint.zig");
const flakeref = @import("../flake/flakeref.zig");
const source = @import("../source.zig");
const Attrs = source.Attrs;
const AttrVal = source.AttrVal;
const strAttr = source.strAttr;
const Tree = source.Tree;
const remote = source.remote;
const spool = @import("../fetch/spool.zig");

/// What primops/fetchTree.cc:fetch reads from its argument: a URL string, or
/// a set of `url`, `sha256` and `name`.
const FetchArgs = struct {
    url: []const u8,
    sha256: ?[]const u8 = null,
    /// Set when the set has a `name`, even an empty one.
    name: ?[]const u8 = null,
    /// The argument was a set, not a URL string.
    attrs: bool,
};

fn fetchArgs(ev: *Evaluator, arg: Value, who: []const u8, pos: Pos) Error!FetchArgs {
    const v = try ev.force(arg);
    if (v.kind() != .attrs) return .{ .url = try ev.forceStringNoCtx(v, pos, "while evaluating the url we should fetch"), .attrs = false };
    const a = try ev.forceAttrs(v, pos, "");
    var out: FetchArgs = .{ .url = "", .attrs = true };
    var url: ?[]const u8 = null;
    for (a.attrs()) |*attr| {
        const n = ev.interner.name(attr.sym);
        const what = if (std.mem.eql(u8, n, "url"))
            "while evaluating the url we should fetch"
        else if (std.mem.eql(u8, n, "sha256"))
            "while evaluating the sha256 of the content we should fetch"
        else if (std.mem.eql(u8, n, "name"))
            "while evaluating the name of the content we should fetch"
        else
            return ev.fail(.eval, pos, "unsupported argument '{s}' to '{s}'", .{ n, who });
        const s = try ev.forceStringNoCtx(attr.cell.get(), pos, what);
        if (n[0] == 'u') url = s else if (n[0] == 's') out.sha256 = s else out.name = s;
    }
    out.url = url orelse return ev.fail(.eval, pos, "'url' argument required", .{});
    return out;
}

/// util.cc:baseNameOf: the last component, past one trailing `/`.
fn urlBaseName(url: []const u8) []const u8 {
    const u = if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url;
    return u[if (std.mem.lastIndexOfScalar(u8, u, '/')) |i| i + 1 else 0..];
}

/// A store path as a string whose context is the path itself.
fn storePathString(ev: *Evaluator, sp: *const StorePath) Error!Value {
    var buf: [512]u8 = undefined;
    const full = try ev.local.arena.allocator().dupe(u8, sp.print(&buf));
    return ev.mkStringCtx(full, &.{.{ .kind = .opaque_path, .path = full }});
}

/// primops/fetchTree.cc:fetch for `builtins.fetchurl`: the file at the URL
/// as a flat fixed output (`fetchFile`). The `sha256` is required in every
/// mode, where Nix requires it only in pure evaluation. In impure evaluation
/// its absence is unsupported, as for `fetchTarball`.
pub fn fetchurl(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    try lint.purity.unhashedFetch(ev, "fetchurl", args[0], pos);
    const a = try fetchArgs(ev, args[0], "fetchurl", pos);
    const name = if (a.name) |n| (if (n.len > 0) n else urlBaseName(a.url)) else urlBaseName(a.url);
    if (store_path.nameProblem(name)) |problem| {
        const fix = if (a.name != null)
            "Please change the value for the 'name' attribute passed to 'fetchurl', so that it can create a valid store path."
        else if (a.attrs)
            "Please add a valid 'name' attribute to the argument for 'fetchurl', so that it can create a valid store path."
        else
            // the two spaces are Nix's
            "Please pass an attribute set with 'url' and 'name' attributes to 'fetchurl',  so that it can create a valid store path.";
        return ev.fail(.eval, pos, "invalid store path name when fetching URL '{s}': {f}. {s}", .{ a.url, problem, fix });
    }
    const sha256 = a.sha256 orelse {
        const kind: Evaluator.ErrorKind = if (ev.config.pure) .eval else .unsupported;
        if (!ev.config.pure) ev.trace().markUncacheable();
        const fix = try std.fmt.allocPrint(ev.local.arena.allocator(), "run 'iets prefetch {s}' and pass the hash as 'sha256'", .{a.url});
        return ev.failHint(kind, pos, fix, "'fetchurl' requires a 'sha256' argument: {s}", .{fix});
    };
    const expected = try paths.parseSha256AllowEmpty(ev, sha256, pos);
    const sp = try remote.fetchFile(ev, a.url, name, expected, pos);
    return storePathString(ev, &sp);
}

/// fetchTree.cc:fetch for `builtins.fetchTarball`: with a `sha256` the store
/// path is known before the download, so it is the same fetch as a locked
/// `tarball` input. Without one it is not, and the call is unsupported.
pub fn fetchTarball(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    try lint.purity.unhashedFetch(ev, "fetchTarball", args[0], pos);
    const a = try fetchArgs(ev, args[0], "fetchTarball", pos);
    const name = a.name orelse "source";
    const arena = ev.local.arena.allocator();
    const url = if (std.mem.startsWith(u8, a.url, "channel:"))
        try std.fmt.allocPrint(arena, "https://channels.nixos.org/{s}/nixexprs.tar.xz", .{a.url["channel:".len..]})
    else
        a.url;
    if (ev.config.pure and a.sha256 == null)
        return ev.fail(.eval, pos, "in pure evaluation mode, 'fetchTarball' requires a 'sha256' argument", .{});
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const hash: Hash = blk: {
        if (a.sha256) |h| if (h.len > 0) if (Hash.parseAny(h, .sha256, &d)) |x| break :blk x else |_| {};
        ev.trace().markUncacheable();
        return ev.fail(.unsupported, pos, "builtins.fetchTarball without a sha256 is not supported", .{});
    };
    // not `source::tree`: `fetchTarball` names the entry itself, and the
    // input store's entry names are what an upload looks up
    const sp = treestore.storePath(name, hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    var attrs: Attrs = .{};
    try attrs.put(arena, "type", .{ .str = "tarball" });
    try attrs.put(arena, "url", .{ .str = url });
    try attrs.put(arena, "narHash", .{ .str = try hash.alloc(arena, .sri, true) });
    try remote.ensureReadable(ev, &sp, hash, &attrs, pos);
    return storePathString(ev, &sp);
}

/// The attrs `fetchTree` accepts: strings and paths, booleans, non-negative
/// integers (fetchTree.cc).
fn collectAttrs(ev: *Evaluator, arg: Value, pos: Pos) Error!Attrs {
    const w = try ev.force(arg);
    if (w.kind() != .attrs)
        return ev.fail(.unsupported, pos, "'fetchTree' with a URL argument is not supported; pass the locked attribute set", .{});
    const out = try inputAttrs(ev, try ev.forceAttrs(w, pos, ""), "fetchTree", pos);
    // fetchTree.cc:158 (`allowNameArgument` is false for fetchTree), before
    // the attrs reach `Input::fromAttrs`, which is where the missing `type`
    // is seen
    if (out.contains("name")) return ev.fail(.eval, pos, "argument 'name' isn\u{2019}t supported in call to 'fetchTree'", .{});
    // refused before any check reads the hash
    if (out.get("narHash")) |v| if (v != .str)
        return ev.fail(.eval, pos, "input attribute 'narHash' is not a string {s}", .{try source.attrsToJson(ev.local.arena.allocator(), &out)});
    if (!out.contains("type")) return ev.fail(.eval, pos, "argument 'type' is missing in call to 'fetchTree'", .{});
    return out;
}

/// The attribute set of a call to `fetcher` as input attributes, in the
/// evaluator's arena.
pub fn inputAttrs(ev: *Evaluator, a: *value.Attrs, fetcher: []const u8, pos: Pos) Error!Attrs {
    const arena = ev.local.arena.allocator();
    var out: Attrs = .{};
    for (a.attrs()) |*attr| {
        const name = try text.lossyAlloc(arena, ev.interner.name(attr.sym));
        if (std.mem.eql(u8, name, "__final")) continue;
        const v = try ev.force(attr.cell.get());
        const val: AttrVal = switch (v.view()) {
            .string => |s| .{ .str = try text.lossyAlloc(arena, s.bytes()) },
            .path => |p| .{ .str = try text.lossyAlloc(arena, p.bytes()) },
            .bool => |b| .{ .bool = b },
            .int => |n| if (n >= 0) .{ .int = @intCast(n) } else return ev.fail(.eval, pos, "negative value given for '{s}' argument '{s}': {d}", .{ fetcher, name, n }),
            else => return ev.fail(.type, pos, "argument '{s}' to '{s}' is {s} while a string, Boolean or integer is expected", .{ name, fetcher, v.typeOf().show() }),
        };
        try out.put(arena, name, val);
    }
    return out;
}

/// fetchTree.cc:fetchTree: a pure evaluation refuses an input that is not
/// locked (a `narHash` for `path` and `tarball`, a `rev` for the rest). The
/// message names the input the way `Input::to_string` does
/// (`flakeref.attrsToString`); for `git` (fetchTree adds `?shallow=1`) and
/// what iets cannot show, it is unsupported and classic mode falls back.
fn checkLocked(ev: *Evaluator, attrs: *const Attrs, pos: Pos) Error!void {
    const ty = strAttr(attrs, "type") orelse "";
    const by_hash = std.mem.eql(u8, ty, "path") or std.mem.eql(u8, ty, "tarball");
    if (attrs.contains(if (by_hash) "narHash" else "rev")) return;
    const a = ev.local.arena.allocator();
    var d: Diag = .init(a);
    // fetchTree.cc only warns on a `narHash`
    const showable = !attrs.contains("narHash") and (by_hash or std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab"));
    if (showable) if (flakeref.attrsToString(a, attrs, &d)) |s|
        return ev.fail(.eval, pos, "in pure evaluation mode, 'fetchTree' doesn't fetch unlocked input '{s}'", .{s})
    else |e| if (e == error.OutOfMemory) return error.OutOfMemory;
    const detail: ?[]const u8 = strAttr(attrs, "url") orelse (flakeref.attrsToString(a, attrs, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    });
    if (detail) |x| return ev.fail(.unsupported, pos, "an unlocked '{s}' input '{s}' in pure evaluation mode is not supported", .{ ty, x });
    return ev.fail(.unsupported, pos, "an unlocked '{s}' input in pure evaluation mode is not supported", .{ty});
}

pub const PathHash = union(enum) {
    found: source.local.Dated,
    /// The tree is not the one expected; this is its hash.
    mismatch: Hash,
};

/// The NAR hash and the `lastModified` of a `path` input at the absolute
/// `path`, or the hash of a tree that is not `expect`.
pub fn pathNarHash(ev: *Evaluator, path: []const u8, expect: ?Hash, pos: Pos) Error!PathHash {
    const at = (try hooks.locate(ev, path)) orelse return switch (try source.local.pathTree(ev, path, expect, pos)) {
        .found => |f| .{ .found = f },
        .mismatch => |h| .{ .mismatch = h },
    };
    // a store tree's mtimes are all 1, so that is its lastModified
    const hash = blk: {
        if (at.rel.len == 0 and at.src == .tree and at.src.tree.accepted == null) break :blk at.src.tree.t.nar_hash;
        const sp = try paths.addPath(ev, pos, "source", path, null, .recursive, null, null);
        const o = hooks.origin(ev, &sp) orelse unreachable;
        break :blk (o.nar orelse unreachable).hash;
    };
    if (expect) |e| if (!e.eql(hash)) return .{ .mismatch = hash };
    return .{ .found = .{ .hash = hash, .mtime = 1 } };
}

pub fn fetchTree(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    try lint.purity.unhashedFetch(ev, "fetchTree", args[0], pos);
    var attrs = try collectAttrs(ev, args[0], pos);
    if (ev.config.pure) try checkLocked(ev, &attrs, pos);
    const a = ev.local.arena.allocator();
    const ty = strAttr(&attrs, "type") orelse "";
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const tree: Tree = blk: {
        if (std.mem.eql(u8, ty, "path")) {
            const path = strAttr(&attrs, "path") orelse return ev.fail(.eval, pos, "fetchTree: 'path' attribute is missing", .{});
            if (!std.mem.startsWith(u8, path, "/"))
                return ev.fail(.eval, pos, "cannot fetch input '{s}' because it uses a relative path", .{try source.toUrl(a, &attrs)});
            const exp: ?Hash = if (strAttr(&attrs, "narHash")) |h| source.parseNarHash(h, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()}) else null;
            const found = switch (try pathNarHash(ev, path, exp, pos)) {
                .found => |f| f,
                .mismatch => |hash| {
                    var eb: [Hash.max_string_len]u8 = undefined;
                    var gb: [Hash.max_string_len]u8 = undefined;
                    const narhash_sym = try ev.sym("narHash");
                    const in = try ev.forceAttrs(args[0], pos, "");
                    const at: ?[]const u8 = if (in.get(narhash_sym)) |x| try @import("../provenance.zig").errorPos(a, ev, null, x.pos) else null;
                    return remote.hashMismatch(ev, pos, hash, at, "NAR hash mismatch in input '{s}', expected '{s}' but got '{s}'", .{ try source.toUrl(a, &attrs), exp.?.print(&eb, .sri, true), hash.print(&gb, .sri, true) });
                },
            };
            try attrs.put(a, "narHash", .{ .str = try found.hash.alloc(a, .sri, true) });
            try attrs.putFirst(a, "lastModified", .{ .int = @intCast(@max(found.mtime, 0)) });
            const sp = treestore.storePath("source", found.hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
            break :blk .{ .path = sp, .attrs = attrs };
        }
        for ([_][]const u8{ "github", "gitlab", "sourcehut", "git", "tarball", "hg" }) |t| if (std.mem.eql(u8, ty, t)) {
            const r: source.SourceRef = .{ .locked = attrs };
            break :blk try source.tree(ev, &r, pos);
        };
        return ev.fail(.unsupported, pos, "fetchTree input type '{s}' is not supported", .{ty});
    };
    const name = if (strAttr(&tree.attrs, "narHash")) |h| remote.inputNameOf(ev, h) else null;
    if (name) |n| try hooks.nameFlake(ev, &tree.path, n);
    const src: ?[]const u8 = if (name) |n| try std.fmt.allocPrint(a, "inputs.{s}", .{n}) else null;
    return emitTreeAttrs(ev, &tree, src, pos);
}

const count_name = "revCountRaw";

/// `f` is the function of the thunk that `emitTreeAttrs` makes for
/// `revCount`. No builtin has the name, so no expression can make one.
pub fn isCount(f: Value) bool {
    const app = switch (f.view()) {
        .primop_app => |p| p,
        else => return false,
    };
    return std.mem.eql(u8, app.op.name(), count_name);
}

/// `revCount` is a thunk over this, so the SCM counts and `rev-count`
/// reports only when the evaluation reads the value, as in Nix 2.35
/// (fetchTree.cc:emitLazyAttrThunk). `args[0]` is the name of the tree when
/// the lint is on for it. `args[1]` is the count when the lock holds it,
/// else the name of the SCM, the root and the revision.
fn revCount(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const t = try ev.force(args[0]);
    if (t.kind() == .string) try lint.purity.revCount(ev, t.as(value.String).bytes(), pos);
    const of = try ev.force(args[1]);
    if (of.kind() != .list) return of;
    const l = try ev.forceList(of, pos, "");
    var parts: [3][]const u8 = undefined;
    if (l.cells().len != 3) return ev.fail(.eval, pos, "iets: revCount of an unknown tree", .{});
    for (l.cells(), &parts) |*c, *o| o.* = (try ev.forceString(try ev.forceCell(c), pos, "")).bytes();
    const s = source.scm.named(parts[0]) orelse return ev.fail(.eval, pos, "iets: revCount of an unknown tree", .{});
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const n = source.scm.revCount(source.scmCx(ev, &d), s, parts[1], parts[2]) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ScmFailed => return ev.fail(.io, pos, "{s}", .{d.message()}),
    };
    return ev.mkInt(@intCast(n));
}

/// fetchTree.cc:emitTreeAttrs with `emptyRevFallback = false`; `forceDirty`
/// is expressed by the caller leaving out `rev`/`revCount`. `src` names the
/// tree (`self`, `inputs.<node>`). Each string that changes with the tree
/// gets the mark `tree-meta-in-drv` reads, and `revCount` is a thunk that
/// reports `rev-count`, when the lint is on for the tree.
pub fn emitTreeAttrs(ev: *Evaluator, tree: *const Tree, src: ?[]const u8, pos: Pos) Error!Value {
    const a = ev.local.arena.allocator();
    const at = &tree.attrs;
    var entries: std.ArrayList(value.Attr) = .empty;
    defer entries.deinit(ev.gpa);
    var buf: [512]u8 = undefined;
    const full = try a.dupe(u8, tree.path.print(&buf));
    try entries.append(ev.gpa, .{ .sym = ev.s.outPath, .pos = pos, .cell = .init(try ev.mkStringCtx(full, &.{.{ .kind = .opaque_path, .path = full }})) });
    const counted: ?[]const u8 = if (src) |s| (if (lint.purity.treeLevel(ev, .rev_count, s) != .off) s else null) else null;
    const marked: ?[]const u8 = if (src) |s| (if (lint.purity.treeLevel(ev, .tree_meta_in_drv, s) != .off) s else null) else null;
    const Push = struct {
        ev: *Evaluator,
        entries: *std.ArrayList(value.Attr),
        marked: ?[]const u8,
        pos: Pos,
        fn str(p: @This(), name: []const u8, v: []const u8) Error!void {
            const w = if (p.marked) |s| blk: {
                const m = try std.fmt.allocPrint(p.ev.local.arena.allocator(), "{s}.{s}", .{ s, name });
                break :blk try p.ev.mkStringCtx(v, &.{.{ .kind = .impure_meta, .path = m }});
            } else try p.ev.mkString(v);
            try p.entries.append(p.ev.gpa, .{ .sym = try p.ev.sym(name), .pos = p.pos, .cell = .init(w) });
        }
    };
    const push: Push = .{ .ev = ev, .entries = &entries, .marked = marked, .pos = pos };
    if (strAttr(at, "narHash")) |h| try push.str("narHash", h);
    if (strAttr(at, "rev")) |rev| {
        try push.str("rev", rev);
        try push.str("shortRev", rev[0..@min(rev.len, 7)]);
    }
    if (strAttr(at, "dirtyRev")) |dr| {
        try push.str("dirtyRev", dr);
        try push.str("dirtyShortRev", strAttr(at, "dirtyShortRev") orelse "");
    }
    if (source.intAttr(at, "lastModified")) |t| {
        var db: [14]u8 = undefined;
        try push.str("lastModifiedDate", source.lastModifiedDate(&db, @intCast(t)));
        try entries.append(ev.gpa, .{ .sym = try ev.sym("lastModified"), .pos = pos, .cell = .init(try ev.mkInt(@intCast(t))) });
    }
    const of: ?Value = blk: {
        if (tree.counter) |c| if (tree.rev()) |rev| {
            const parts = [_]Value{ try ev.mkString(c.scm.name), try ev.mkString(c.root), try ev.mkString(rev) };
            break :blk try ev.mkList(&parts);
        };
        break :blk if (source.intAttr(at, "revCount")) |n| try ev.mkInt(@intCast(n)) else null;
    };
    if (of) |o| {
        var w = o;
        if (tree.counter != null or counted != null) {
            const name: Value = if (counted) |s| try ev.mkString(s) else .null;
            const op = try ev.mkPrimOp(count_name, 2, revCount);
            w = try ev.mkThunkApp(try ev.mkPrimOpApp(op.as(value.PrimOp), &.{name}, &.{}), o);
        }
        try entries.append(ev.gpa, .{ .sym = try ev.sym("revCount"), .pos = pos, .cell = .init(w) });
    }
    if (std.mem.eql(u8, strAttr(at, "type") orelse "", "git"))
        try entries.append(ev.gpa, .{ .sym = try ev.sym("submodules"), .pos = pos, .cell = .init(.fromBool(source.boolAttr(at, "submodules") orelse false)) });
    return ev.mkAttrs(entries.items, pos);
}

const testing = std.testing;

test "a URL's base name is its last component" {
    try testing.expectEqualStrings("hello.txt", urlBaseName("file:///tmp/x/hello.txt"));
    try testing.expectEqualStrings("x", urlBaseName("https://h/a/x/"));
    try testing.expectEqualStrings("", urlBaseName("https://h/a//"));
}

/// An evaluator with an input store under `tmp`, as `iets eval` sets it up.
const Env = struct {
    tmp: testing.TmpDir,
    base: []const u8,
    arena: std.heap.ArenaAllocator,
    interner: @import("../syntax/symbol.zig").Interner,
    files: @import("../eval/Files.zig"),
    shared: Evaluator.Shared = .{},
    local: Evaluator.Local,
    store: treestore.Store,
    ev: Evaluator,

    fn init(e: *Env, pure: bool) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        e.tmp = testing.tmpDir(.{});
        e.arena = .init(gpa);
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        e.base = try e.arena.allocator().dupe(u8, buf[0..try e.tmp.dir.realPath(io, &buf)]);
        e.interner = try .init(gpa);
        e.files = .init(gpa, io);
        e.shared = .{};
        e.local = .init(gpa);
        value.flat_arena = &e.local.arena;
        e.store = .init(gpa, io, try std.fmt.allocPrint(e.arena.allocator(), "{s}/cache/inputs", .{e.base}));
        e.ev = try .init(gpa, io, &e.local, &e.interner, &e.files, &e.shared, .{ .pure = pure, .inputs = &e.store });
        try @import("../builtins.zig").install(&e.ev);
    }

    fn deinit(e: *Env) void {
        e.ev.deinit();
        e.store.deinit();
        value.flat_arena = null;
        e.local.deinit();
        e.shared.deinit(testing.allocator);
        e.files.deinit();
        e.interner.deinit();
        e.arena.deinit();
        e.tmp.cleanup();
    }

    /// `src` with `@` standing for the scratch directory, as a string.
    fn eval(e: *Env, src: []const u8) ![]const u8 {
        const a = e.arena.allocator();
        const code = try std.mem.replaceOwned(u8, a, src, "@", e.base);
        const v = try @import("../eval/import.zig").evalString(&e.ev, code);
        return a.dupe(u8, (try e.ev.forceString(v, .none, "")).bytes());
    }

    fn message(e: *Env) []const u8 {
        return if (e.ev.failure) |f| f.msg else "";
    }
};

const sha = "113a52l57f2jv9fh9igj2xh2mi0is40flxbkqi69wbh7nlybkcbm";

test "a hashed fetch has the store path nix gives, and reads back from the input store" {
    var e: Env = undefined;
    try e.init(false);
    defer e.deinit();
    try e.tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.txt", .data = "hello fetchurl\n" });
    const call = "builtins.fetchurl { url = \"file://@/hello.txt\"; sha256 = \"" ++ sha ++ "\"; }";
    try testing.expectEqualStrings("/nix/store/3ay25cl2lpykmx07i7m22qxz7zwzqmvy-hello.txt", try e.eval(call));
    // the input store holds it now: the file may go
    try e.tmp.dir.deleteFile(testing.io, "hello.txt");
    try testing.expectEqualStrings("hello fetchurl\n", try e.eval("builtins.readFile (" ++ call ++ ")"));
    try e.tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.txt", .data = "hello fetchurl\n" });
    try testing.expectEqualStrings("/nix/store/wi98cklj3li90ii41aggl9mf0w3nqp5y-x", try e.eval("builtins.fetchurl { url = \"file://@/hello.txt\"; sha256 = \"" ++ sha ++ "\"; name = \"x\"; }"));
}

test "a wrong hash is refused with the hash the file has" {
    var e: Env = undefined;
    try e.init(false);
    defer e.deinit();
    try e.tmp.dir.writeFile(testing.io, .{ .sub_path = "hello.txt", .data = "hello fetchurl\n" });
    try testing.expectError(error.EvalFailed, e.eval("builtins.fetchurl { url = \"file://@/hello.txt\"; sha256 = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; name = \"y\"; }"));
    const want = try std.mem.replaceOwned(u8, e.arena.allocator(), "hash mismatch in file downloaded from 'file://@/hello.txt':\n  specified: sha256:0000000000000000000000000000000000000000000000000000\n  got:       sha256:" ++ sha, "@", e.base);
    try testing.expectEqualStrings(want, e.message());
    try testing.expectEqual(Evaluator.ErrorKind.hash_mismatch, e.ev.failure.?.kind);
}

test "without a hash no evaluation fetches" {
    for ([_]bool{ true, false }) |pure| {
        var e: Env = undefined;
        try e.init(pure);
        defer e.deinit();
        try testing.expectError(error.EvalFailed, e.eval("builtins.fetchurl \"file://@/hello.txt\""));
        try testing.expect(std.mem.startsWith(u8, e.message(), "'fetchurl' requires a 'sha256' argument: run 'iets prefetch file://"));
        try testing.expectEqual(if (pure) Evaluator.ErrorKind.eval else .unsupported, e.ev.failure.?.kind);
    }
}

test "a tarball is fetched once, and its files are read out of the input store" {
    var e: Env = undefined;
    try e.init(true);
    defer e.deinit();
    const tar = @import("../fetch/tar.zig");
    const bytes = try tar.testTar(e.arena.allocator(), &.{
        .{ .name = "proj/", .t = tar.Type.directory, .mode = 0o755 },
        .{ .name = "proj/default.nix", .t = tar.Type.regular, .data = "{ x = 1; }\n" },
        .{ .name = "proj/sub/a", .t = tar.Type.regular, .mode = 0o755, .data = "hi\n" },
    });
    try e.tmp.dir.writeFile(testing.io, .{ .sub_path = "proj.tar", .data = bytes });
    // the tree's NAR hash, from the spool the way the store computes it
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const f = try spool.scratch(testing.io, "test", &d);
    try f.writePositionalAll(testing.io, bytes, 0);
    var t = try spool.Tree.index(testing.allocator, testing.io, f, std.math.maxInt(u64), &d);
    defer t.deinit();
    var h: hash_mod.Hasher = .init(.sha256);
    var hb: [4096]u8 = undefined;
    var hw = h.writer(&hb);
    try t.dump(&hw.interface, &d);
    var sb: [Hash.max_string_len]u8 = undefined;
    const call = try std.fmt.allocPrint(e.arena.allocator(), "builtins.fetchTarball {{ url = \"file://@/proj.tar\"; sha256 = \"{s}\"; }}", .{h.finish().print(&sb, .sri, true)});
    const out = try e.eval(call);
    try testing.expect(std.mem.endsWith(u8, out, "-source"));
    try e.tmp.dir.deleteFile(testing.io, "proj.tar");
    const x = try std.fmt.allocPrint(e.arena.allocator(), "toString (import ({s})).x + builtins.readFile \"${{{s}}}/sub/a\"", .{ call, call });
    try testing.expectEqualStrings("1hi\n", try e.eval(x));
    try testing.expectError(error.EvalFailed, e.eval("builtins.fetchTarball \"file://@/proj.tar\""));
    try testing.expectEqualStrings("in pure evaluation mode, 'fetchTarball' requires a 'sha256' argument", e.message());
}

/// An evaluator under a lint configuration, for the marks and the
/// `rev-count` findings of a tree's metadata.
const LintRun = struct {
    interner: @import("../syntax/symbol.zig").Interner,
    files: @import("../eval/Files.zig"),
    shared: Evaluator.Shared = .{},
    local: Evaluator.Local,
    ev: Evaluator,
    cfg: lint.Config,
    arena: std.heap.ArenaAllocator,

    fn init(r: *LintRun, toml: []const u8) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        r.arena = .init(gpa);
        r.cfg = .{};
        var notes: lint.Notes = .{};
        var dg: Diag = .init(r.arena.allocator());
        if (toml.len > 0) try r.cfg.applyToml(r.arena.allocator(), toml, "/r/iets.toml", &notes, &dg);
        r.interner = try .init(gpa);
        r.files = .init(gpa, io);
        r.shared = .{};
        r.local = .init(gpa);
        value.flat_arena = &r.local.arena;
        r.ev = try .init(gpa, io, &r.local, &r.interner, &r.files, &r.shared, .{ .lints = &r.cfg });
        try @import("../builtins.zig").install(&r.ev);
    }

    fn deinit(r: *LintRun) void {
        r.ev.deinit();
        value.flat_arena = null;
        r.local.deinit();
        r.shared.deinit(testing.allocator);
        r.files.deinit();
        r.interner.deinit();
        r.arena.deinit();
    }

    /// The metadata of a tree with a `rev`, a date and a count, named `src`.
    fn tree(r: *LintRun, src: []const u8) !Value {
        const a = r.arena.allocator();
        var d: Diag = .init(a);
        var attrs: Attrs = .{};
        try attrs.put(a, "narHash", .{ .str = "sha256-x" });
        try attrs.put(a, "rev", .{ .str = &@as([40]u8, @splat('a')) });
        try attrs.put(a, "lastModified", .{ .int = 86400 });
        try attrs.put(a, "revCount", .{ .int = 7 });
        const t: Tree = .{ .path = try StorePath.parse("/nix/store/00000000000000000000000000000000-source", &d), .attrs = attrs };
        return emitTreeAttrs(&r.ev, &t, src, .none);
    }

    fn apply(r: *LintRun, f: []const u8, t: Value) !Value {
        const fv = try @import("../eval/import.zig").evalString(&r.ev, f);
        return r.ev.force(try r.ev.apply(fv, &.{t}, .none));
    }

    /// `f tree` as a string, and the names of its marks.
    fn marks(r: *LintRun, t: Value, f: []const u8) !struct { []const u8, []const []const u8 } {
        const s = try r.ev.forceString(try r.apply(f, t), .none, "");
        var names: std.ArrayList([]const u8) = .empty;
        for (s.context()) |c| {
            try testing.expectEqual(value.CtxKind.impure_meta, c.kind);
            try names.append(r.arena.allocator(), c.path);
        }
        return .{ s.bytes(), names.items };
    }

    /// The `rev-count` findings: the tree, then the line and column of the
    /// site when the finding has one.
    fn found(r: *LintRun) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (lint.report.records(&r.ev)) |rec| {
            const head = "warning: [rev-count] '";
            if (!std.mem.startsWith(u8, rec, head)) continue;
            const tree_end = std.mem.indexOf(u8, rec, ".revCount' is") orelse continue;
            const name = rec[head.len..tree_end];
            const at = "\n  at «string»:";
            const shown = if (std.mem.indexOf(u8, rec, at)) |i| try std.fmt.allocPrint(r.arena.allocator(), "{s} {s}", .{ name, rec[i + at.len ..] }) else name;
            try out.append(r.arena.allocator(), shown);
        }
        return out.items;
    }
};

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "the mark follows the string like store context" {
    var r: LintRun = undefined;
    try r.init("");
    defer r.deinit();
    const t = try r.tree("self");
    for ([_][2][]const u8{
        .{ "t: t.rev", "self.rev" },
        .{ "t: t.narHash", "self.narHash" },
        .{ "t: builtins.substring 0 8 t.lastModifiedDate", "self.lastModifiedDate" },
        .{ "t: \"v\" + t.shortRev", "self.shortRev" },
        .{ "t: \"1.0-${t.shortRev}\"", "self.shortRev" },
        .{ "t: builtins.concatStringsSep \".\" [ \"1\" t.shortRev ]", "self.shortRev" },
        .{ "t: toString t.rev", "self.rev" },
        .{ "t: toString [ 1 t.rev ]", "self.rev" },
        .{ "t: builtins.replaceStrings [ \"a\" ] [ \"b\" ] t.rev", "self.rev" },
        .{ "t: builtins.toJSON { r = t.rev; }", "self.rev" },
    }) |c| try expectStrings(&.{c[1]}, (try r.marks(t, c[0]))[1]);
    try expectStrings(&.{ "self.narHash", "self.shortRev" }, (try r.marks(t, "t: t.shortRev + t.narHash"))[1]);
    for ([_][]const u8{
        "t: builtins.unsafeDiscardStringContext t.rev",
        // an integer holds no context: docs/reference/lints.md, Limits
        "t: toString t.lastModified",
        "t: toString t.revCount",
    }) |f| try expectStrings(&.{}, (try r.marks(t, f))[1]);
}

test "nix sees no mark" {
    var r: LintRun = undefined;
    try r.init("");
    defer r.deinit();
    const t = try r.tree("self");
    const f =
        \\t: builtins.toJSON [
        \\  (builtins.getContext t.rev) (builtins.hasContext t.rev)
        \\  (t.rev == builtins.unsafeDiscardStringContext t.rev)
        \\  (builtins.toJSON t.shortRev) { ${t.shortRev} = 1; }
        \\  (builtins.match "(a+)" t.rev != null) (builtins.stringLength t.rev)
        \\  t.lastModifiedDate
        \\]
    ;
    try testing.expectEqualStrings("[{},false,true,\"\\\"aaaaaaa\\\"\",{\"aaaaaaa\":1},true,40,\"19700102000000\"]", (try r.marks(t, f))[0]);
}

test "the tree decides the level" {
    const Case = struct { toml: []const u8, src: []const u8, want: bool };
    const input = "[lint]\ntree-meta-in-drv = \"off\"\n[lint.inputs.nixpkgs]\ntree-meta-in-drv = \"warn\"\n";
    for ([_]Case{
        .{ .toml = "", .src = "self", .want = true },
        .{ .toml = "", .src = "inputs.nixpkgs", .want = false },
        .{ .toml = "[lint]\ntree-meta-in-drv = \"off\"\n", .src = "self", .want = false },
        .{ .toml = input, .src = "inputs.nixpkgs", .want = true },
        .{ .toml = input, .src = "inputs.other", .want = false },
        .{ .toml = input, .src = "self", .want = false },
        .{ .toml = "[lint]\nscope = \"all\"\n", .src = "inputs.nixpkgs", .want = true },
        .{ .toml = "[lint.inputs.nixpkgs]\n\"family:purity\" = \"error\"\n", .src = "inputs.nixpkgs", .want = true },
    }) |c| {
        var r: LintRun = undefined;
        try r.init(c.toml);
        defer r.deinit();
        const t = try r.tree(c.src);
        try testing.expectEqual(c.want, (try r.marks(t, "t: t.rev"))[1].len > 0);
    }
}

/// `found` after `f` read each tree of `sources`.
fn reads(toml: []const u8, sources: []const []const u8, f: []const u8) ![]const []const u8 {
    var r: LintRun = undefined;
    try r.init(toml);
    defer r.deinit();
    for (sources) |s| {
        const t = try r.tree(s);
        const v = try r.apply(f, t);
        try testing.expectEqual(@as(i64, 14), v.view().int);
    }
    const got = try r.found();
    // the run's arena goes with it
    const out = try testing.allocator.alloc([]const u8, got.len);
    for (got, out) |g, *o| o.* = try testing.allocator.dupe(u8, g);
    return out;
}

fn expectReads(want: []const []const u8, toml: []const u8, sources: []const []const u8, f: []const u8) !void {
    const got = try reads(toml, sources, f);
    defer {
        for (got) |g| testing.allocator.free(g);
        testing.allocator.free(got);
    }
    try expectStrings(want, got);
}

test "a read of the count is one finding for each tree" {
    const twice = "t: t.revCount + t.revCount";
    const names = "t: if t ? revCount && builtins.elem \"revCount\" (builtins.attrNames t) then 14 else 0";
    const unused = "t: let n = t.revCount; in { inherit (t) revCount; v = 14; }.v";
    const trees = [_][]const u8{ "self", "inputs.a", "inputs.b" };
    try expectReads(&.{"self 1:4"}, "", &trees, twice);
    try expectReads(&.{"self 1:4"}, "", &.{ "self", "self" }, twice);
    try expectReads(&.{}, "", &trees, names);
    try expectReads(&.{}, "", &trees, unused);
    try expectReads(&.{"inputs.b 1:4"}, "[lint]\nrev-count = \"off\"\n[lint.inputs.b]\n\"family:purity\" = \"warn\"\n", &trees, twice);
    try expectReads(&.{ "self 1:4", "inputs.a 1:4", "inputs.b 1:4" }, "[lint]\nscope = \"all\"\n", &trees, twice);

    var r: LintRun = undefined;
    try r.init("[lint]\nrev-count = \"error\"\n");
    defer r.deinit();
    const t = try r.tree("self");
    const l = try r.apply("t: [ (builtins.tryEval t.revCount).value (builtins.tryEval (with t; revCount)).value ]", t);
    for ((try r.ev.forceList(l, .none, "")).cells()) |*c| {
        try testing.expectError(error.EvalFailed, r.ev.forceCell(c));
        try testing.expectEqual(Evaluator.ErrorKind.lint, r.ev.failure.?.kind);
        try testing.expect(std.mem.startsWith(u8, r.ev.failure.?.msg, "[rev-count] 'self.revCount' is deprecated"));
    }
}

test "a selection of the count is the site" {
    for ([_][2][]const u8{
        .{ "t: t.revCount * 2", "1:4" },
        .{ "t: (t.revCount or 0) * 2", "1:5" },
        .{ "t: { inherit (t) revCount; }.revCount * 2", "1:18" },
        .{ "t: (let inherit (t) revCount; in revCount) * 2", "1:21" },
        .{ "t: (rec { inherit (t) revCount; n = revCount * 2; }).n", "1:23" },
        .{ "t: { sourceInfo = t; }.sourceInfo.revCount * 2", "1:4" },
        .{ "t: t.\"revCount\" * 2", "1:4" },
        .{ "t: t.${\"revCount\"} * 2", "1:4" },
        .{ "t: (let s = t; in s.revCount) * 2", "1:19" },
        .{ "t: ({ self, ... }: self.revCount) { self = t; } * 2", "1:20" },
        .{ "t: ({ a = 1; } // t).revCount * 2", "1:4" },
        .{ "t: builtins.getAttr \"revCount\" t * 2", "1:4" },
        .{ "t: builtins.getAttr (\"rev\" + \"Count\") t * 2", "1:4" },
        .{ "t:\n  let n = t.revCount; in n + n", "2:11" },
    }) |c| {
        const want = try std.fmt.allocPrint(testing.allocator, "self {s}", .{c[1]});
        defer testing.allocator.free(want);
        expectReads(&.{want}, "", &.{"self"}, c[0]) catch |e| {
            std.debug.print("case {s}\n", .{c[0]});
            return e;
        };
    }
}

test "a read that is not a selection has no site" {
    for ([_][]const u8{
        "t: t.${\"rev\" + \"Count\"} * 2",
        "t: (with t; revCount) * 2",
        "t: ({ revCount, ... }: revCount * 2) t",
        "t: builtins.elemAt (builtins.attrValues (builtins.intersectAttrs { revCount = 1; } t)) 0 * 2",
        "t: (builtins.fromJSON (builtins.toJSON (builtins.intersectAttrs { revCount = 1; } t))).revCount * 2",
        "t: (builtins.mapAttrs (n: v: v) t).revCount * 2",
    }) |f| expectReads(&.{"self"}, "", &.{"self"}, f) catch |e| {
        std.debug.print("case {s}\n", .{f});
        return e;
    };
}

test "the first read of a tree gives its finding" {
    try expectReads(&.{"self 1:4"}, "", &.{"self"}, "t: t.revCount + (with t; revCount) + t.revCount - 7");
    try expectReads(&.{"self"}, "", &.{"self"}, "t: (with t; revCount) + t.revCount");
    try expectReads(&.{}, "", &.{"self"}, "t: t.revCount + t.revCount # iets: allow rev-count");
    try expectReads(&.{"self 2:5"}, "", &.{"self"}, "t: t.revCount # iets: allow rev-count\n  + t.revCount");
    try expectReads(&.{"self"}, "", &.{"self"}, "t: t.revCount # iets: allow rev-count\n  + (with t; revCount)");
}

test "the name on a value that is not a tree is silent" {
    for ([_][]const u8{
        "t: { revCount = 14; }.revCount",
        "t: { revCount = t.lastModified / 86400 * 14; }.revCount",
        "t: (builtins.zipAttrsWith (n: vs: 14) [ { revCount = 1; } ]).revCount",
        "t: (builtins.mapAttrs (n: v: v * 2) { revCount = 7; }).revCount",
        "t: builtins.getAttr \"revCount\" { revCount = 14; }",
        "t: { revCount = 14; }.revCount or 0",
        "t: { }.revCount or 14",
        "t: { }.a.revCount or 14",
    }) |f| try expectReads(&.{}, "[lint]\nscope = \"all\"\n", &.{ "self", "inputs.a" }, f);
}
