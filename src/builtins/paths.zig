//! File system primops (primops.cc): readFile, readDir, readFileType,
//! pathExists, toPath, storePath, filterSource, path, toFile, hashFile.
//! The network fetchers are registered here too; the fetch family
//! implements them.

const std = @import("std");
const errors = @import("../errors.zig");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const store_path = @import("../store/path.zig");
const StorePath = store_path.StorePath;
const IngestionMethod = store_path.IngestionMethod;
const nar = @import("../store/nar.zig");
const drv_mod = @import("../store/drv.zig");
const FileType = nar.FileType;
const import_ = @import("../eval/import.zig");
const hooks = @import("store_hooks.zig");
const lint = @import("../lint.zig");
const SrcPath = hooks.SrcPath;
pub const fetch = @import("fetch.zig");
pub const fetch_git = @import("fetch_git.zig");

pub const ops = [_]Op{
    .{ .name = "__readFile", .arity = 1, .f = readFile },
    .{ .name = "__readDir", .arity = 1, .f = readDir },
    .{ .name = "__readFileType", .arity = 1, .f = readFileType },
    .{ .name = "__pathExists", .arity = 1, .f = pathExists },
    .{ .name = "__toPath", .arity = 1, .f = toPath },
    .{ .name = "__storePath", .arity = 1, .f = storePath },
    .{ .name = "__filterSource", .arity = 2, .f = filterSource },
    .{ .name = "__path", .arity = 1, .f = path },
    .{ .name = "__toFile", .arity = 2, .f = toFile },
    .{ .name = "__hashFile", .arity = 2, .f = hashFile },
    // The fetch family (fetch.zig, fetch_git.zig, flake.zig) replaces these.
    // Each keeps its `unhashed-fetch` hook (lint/purity.zig) when ported.
    .{ .name = "__fetchurl", .arity = 1, .f = fetch.fetchurl },
    .{ .name = "fetchTarball", .arity = 1, .f = fetch.fetchTarball },
    .{ .name = "fetchGit", .arity = 1, .f = fetch_git.fetchGit },
    .{ .name = "fetchTree", .arity = 1, .f = fetch.fetchTree },
    .{ .name = "fetchMercurial", .arity = 1, .f = unsupportedHint("builtins.fetchMercurial is not supported", "use `builtins.fetchTree { type = \"hg\"; url = \"…\"; rev = \"…\"; narHash = \"…\"; }` " ++
        "or an hg flake input, or run it as nix-instantiate, nix-build or nix-shell, which fall back to Nix") },
    .{ .name = "__fetchClosure", .arity = 1, .f = unsupported("iets: network fetchers are not supported (builtins.fetchClosure)") },
};

fn unsupported(comptime msg: []const u8) *const Evaluator.PrimFn {
    return struct {
        fn f(ev: *Evaluator, _: []const Value, pos: Pos) Error!Value {
            ev.trace().markUncacheable();
            return ev.fail(.unsupported, pos, "{s}", .{msg});
        }
    }.f;
}

fn unsupportedHint(comptime msg: []const u8, comptime hint: []const u8) *const Evaluator.PrimFn {
    return struct {
        fn f(ev: *Evaluator, _: []const Value, pos: Pos) Error!Value {
            ev.trace().markUncacheable();
            return ev.failHint(.unsupported, pos, hint, "{s}", .{msg});
        }
    }.f;
}

fn notPorted(comptime name: []const u8) *const Evaluator.PrimFn {
    return unsupported(name ++ " is not implemented yet");
}

/// A fetcher not ported yet, with the `unhashed-fetch` lint every fetcher
/// runs first.
fn fetchNotPorted(comptime name: []const u8, comptime lint_name: []const u8) *const Evaluator.PrimFn {
    return struct {
        fn f(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
            ev.trace().markUncacheable();
            try lint.purity.unhashedFetch(ev, lint_name, args[0], pos);
            return ev.fail(.unsupported, pos, "{s}", .{name ++ " is not implemented yet"});
        }
    }.f;
}

fn ioError(ev: *Evaluator, e: anyerror, verb: []const u8, p: []const u8, pos: Pos) Error {
    if (e == error.FileNotFound) return ev.fail(.io, pos, "path '{s}' does not exist", .{p});
    return ev.fail(.io, pos, "{s} '{s}': {s}", .{ verb, p, errors.ioText(e) });
}

/// A failed `SrcPath.read` of a file, `readFile`'s way.
fn readError(ev: *Evaluator, f: hooks.Failed, p: []const u8, pos: Pos) Error {
    if (f.err == error.IsDir) return ev.fail(.io, pos, "file '{s}' is not a regular file", .{p});
    return ioError(ev, f.err, f.verb, p, pos);
}

fn utf8(ev: *Evaluator, b: []const u8, pos: Pos) Error![]const u8 {
    if (!std.unicode.utf8ValidateSlice(b)) return ev.fail(.eval, pos, "'{s}' is not valid UTF-8", .{b});
    return b;
}

/// Nix's `coerceToPath`: path values pass through, `__toString` sets are
/// called, everything else is coerced to a string that must be absolute.
/// The canonical path is in the arena; its context goes to `ctx`.
pub fn coerceToPath(ev: *Evaluator, v_in: Value, ctx: *std.ArrayList(Ctx), pos: Pos, err_ctx: []const u8) Error![]const u8 {
    const v = ev.force(v_in) catch |e| return ev.addTrace(e, pos, "{s}", .{err_ctx});
    switch (v.view()) {
        .path => |p| return p.bytes(),
        .attrs => |a| if (a.get(ev.s.__toString)) |f| {
            const r = try ev.call1(try ev.forceCell(&f.cell), v, pos);
            return coerceToPath(ev, r, ctx, pos, err_ctx);
        },
        else => {},
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ev.gpa);
    try ev.coerceToString(v, &out, ctx, pos, err_ctx, .{ .copy_to_store = false });
    if (out.items.len == 0 or out.items[0] != '/') {
        const e = ev.fail(.eval, pos, "string '{s}' doesn't represent an absolute path", .{out.items});
        return ev.addTrace(e, pos, "{s}", .{err_ctx});
    }
    return Evaluator.canonPath(ev.local.arena.allocator(), out.items);
}

/// Nix's `realisePath` without building: a path with a derivation output in
/// its context cannot be realised here, and an opaque store path or `.drv`
/// (primops.cc:realiseContext treats `DrvDeep` as opaque) must exist or be
/// one this evaluation made. The result is the path as Nix names it;
/// `store_hooks.locate` gives the file to read.
pub fn realisePath(ev: *Evaluator, v: Value, pos: Pos) Error![]const u8 {
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    const p = try coerceToPath(ev, v, &ctx, .none, "while realising the context of a path");
    for (ctx.items) |c| {
        const e = switch (c.kind) {
            .impure_path, .impure_meta => continue,
            .opaque_path, .drv_deep => blk: {
                if ((try hooks.locate(ev, c.path)) != null) continue;
                if ((try hooks.stat(ev, c.path, true)) != .missing) continue;
                if (madeHere(ev, c.path))
                    break :blk ev.fail(.unsupported, pos, "'{s}' is not in the store and this run did not keep its text (--no-tracing-cache)", .{c.path});
                break :blk ev.fail(.eval, pos, "path '{s}' is not valid", .{c.path});
            },
            .built => blk: {
                if (try builtOutputPresent(ev, c.path, c.output)) |out| {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    try lint.purity.ifdLocalOutput(ev, out.print(&buf), pos);
                    try hooks.addOnDisk(ev, &out);
                    continue;
                }
                break :blk ev.fail(.unsupported, pos, "import from derivation is not supported: '{s}' is not built", .{c.path});
            },
        };
        return ev.addTrace(e, pos, "while realising the context of path '{s}'", .{p});
    }
    return p;
}

/// Whether `p` names a derivation this evaluation made.
fn madeHere(ev: *Evaluator, p: []const u8) bool {
    const base = store_path.stripStoreDir(p) orelse return false;
    ev.shared.drv_lock.lock(ev);
    defer ev.shared.drv_lock.unlock(ev);
    return ev.shared.drv.table.contains(base);
}

/// The path of output `output` of `drv` when it is already in the store, so
/// a read needs no build. Only a path known without a build counts:
/// input-addressed or fixed, not a dynamic derivation's, a floating or a
/// deferred one. Nix refuses the read with `allow-import-from-derivation`
/// off and warns with `trace-import-from-derivation`, so both leave it to
/// the real nix (`Session.readsBuiltOutputs`).
fn builtOutputPresent(ev: *Evaluator, drv: []const u8, output: []const u8) Error!?StorePath {
    const s = ev.config.session orelse return null;
    if (!s.readsBuiltOutputs()) return null;
    if (std.mem.indexOfScalar(u8, drv, '!') != null) return null;
    var arena_state: std.heap.ArenaAllocator = .init(ev.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(a);
    const dp = StorePath.parse(drv, &d) catch return null;
    const kept = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        const i = ev.shared.drv.table.get(dp.baseName()) orelse break :blk null;
        break :blk i.aterm;
    };
    const aterm = kept orelse std.Io.Dir.cwd().readFileAlloc(ev.io, drv, a, .unlimited) catch return null;
    const name = drv_mod.Derivation.nameFromPath(&dp, &d) catch return null;
    const parsed = drv_mod.Derivation.parse(a, aterm, name, &d) catch return null;
    const out = (parsed.outputPath(output, &d) catch return null) orelse return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if ((try hooks.stat(ev, out.print(&buf), true)) == .missing) return null;
    return out;
}

const Realised = struct {
    at: SrcPath,
    /// The path messages name: the file on disk, else the path itself.
    shown: []const u8,
    /// The path after resolution, as Nix names it.
    named: []const u8,
};

/// What a realised path reads. An entry a copied tree's filter left out is
/// `path '...' does not exist`. `follow` is the resolution primops.cc asks
/// `realisePath` for; `readFileType` asks for none.
fn realiseExisting(ev: *Evaluator, v: Value, follow: ?hooks.Follow, pos: Pos) Error!Realised {
    const p0 = try realisePath(ev, v, pos);
    const l: hooks.Located = if (follow) |m| try hooks.located(ev, p0, m, pos) else .{ .path = p0, .at = try hooks.locate(ev, p0) };
    const at = try hooks.check(ev, l.at, l.path, pos);
    if (try at.hidden(ev)) return ioError(ev, error.FileNotFound, hooks.stat_verb, l.path, pos);
    try lint.coerce.readThroughCopy(ev, l.path, pos);
    return .{ .at = at, .shown = (try at.local(ev)) orelse l.path, .named = l.path };
}

fn readFile(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const r = try realiseExisting(ev, args[0], .full, pos);
    var failed: hooks.Failed = undefined;
    const bytes = r.at.read(ev, null, true, &failed) catch |e| switch (e) {
        error.IoFailed => return readError(ev, failed, r.shown, pos),
        else => |x| return x,
    };
    if (std.mem.indexOfScalar(u8, bytes, 0) != null)
        return ev.fail(.eval, pos, "the contents of the file '{s}' cannot be represented as a Nix string", .{r.shown});
    const refs = try fileReferences(ev, r.named, bytes);
    if (refs.len == 0) return ev.mkStringStatic(bytes, &.{});
    const ctx = try ev.local.arena.allocSlice(Ctx, refs.len);
    for (refs, ctx) |*sp, *c| c.* = .{ .kind = .opaque_path, .path = try fullPath(ev, sp) };
    return ev.mkStringStatic(bytes, try ev.ctxToArena(ctx));
}

fn fullPath(ev: *Evaluator, sp: *const StorePath) Error![]const u8 {
    var buf: [512]u8 = undefined;
    return ev.local.arena.dupe(u8, sp.print(&buf));
}

/// primops.cc:prim_readFile's context: the references of the file's store
/// path whose hash part occurs in `bytes`.
fn fileReferences(ev: *Evaluator, named: []const u8, bytes: []const u8) Error![]const StorePath {
    // nothing for the scan to keep, so skip the lookup
    if (!hasHashRun(bytes)) return &.{};
    // realisePath resolves links before the isInStore check
    const p = if ((try hooks.locate(ev, named)) == null) blk: {
        const r = canonicalize(ev, named) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return &.{},
        };
        break :blk r;
    } else named;
    if (!ev.isStorePathText(p)) return &.{};
    const sp = toStorePath(p) orelse return &.{};
    return scanReferences(ev, bytes, try references(ev, &sp));
}

/// `realpath` of `p`, in the arena, with what it resolved to (or that it
/// did not) in the read set.
fn canonicalize(ev: *Evaluator, p: []const u8) ![]const u8 {
    const r = std.Io.Dir.cwd().realPathFileAlloc(ev.io, p, ev.local.arena.allocator()) catch |e| {
        if (e != error.OutOfMemory) ev.trace().canon(p, null);
        return e;
    };
    ev.trace().canon(p, r);
    return r;
}

fn hasHashRun(bytes: []const u8) bool {
    var run: usize = 0;
    for (bytes) |b| {
        run = if (hash_mod.isNix32Char(b)) run + 1 else 0;
        if (run == store_path.hash_part_len) return true;
    }
    return false;
}

/// references.cc:RefScanSink: the `refs` whose hash part occurs in `bytes`, sorted.
fn scanReferences(ev: *Evaluator, bytes: []const u8, refs: []const StorePath) Error![]const StorePath {
    if (refs.len == 0) return &.{};
    const n = store_path.hash_part_len;
    var found: std.ArrayList(StorePath) = .empty;
    const seen = try ev.gpa.alloc(bool, refs.len);
    defer ev.gpa.free(seen);
    @memset(seen, false);
    var i: usize = 0;
    while (i + n <= bytes.len and found.items.len < refs.len) {
        const window = bytes[i..][0..n];
        var bad: ?usize = null;
        var j: usize = n;
        while (j > 0) : (j -= 1) if (!hash_mod.isNix32Char(window[j - 1])) {
            bad = j - 1;
            break;
        };
        if (bad) |b| {
            i += b + 1;
            continue;
        }
        for (refs, seen) |*r, *s| if (!s.* and std.mem.eql(u8, r.hashPart(), window)) {
            s.* = true;
            try found.append(ev.local.arena.allocator(), r.*);
        };
        i += 1;
    }
    return store_path.sortUnique(found.items);
}

fn references(ev: *Evaluator, sp: ?*const StorePath) Error![]const StorePath {
    const p = sp orelse return &.{};
    if (try drvReferences(ev, p)) |r| return r;
    return hooks.references(ev, p);
}

/// The inputs of a derivation this evaluation made: its `.drv` is in no store.
fn drvReferences(ev: *Evaluator, sp: *const StorePath) Error!?[]const StorePath {
    const refs = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        const i = ev.shared.drv.table.get(sp.baseName()) orelse return null;
        break :blk i.references;
    };
    const out = try ev.local.arena.allocSlice(StorePath, refs.len);
    var n: usize = 0;
    for (refs) |r| {
        out[n] = toStorePath(r) orelse continue;
        n += 1;
    }
    std.mem.sort(StorePath, out[0..n], {}, struct {
        fn lt(_: void, a: StorePath, b: StorePath) bool {
            return std.mem.lessThan(u8, a.baseName(), b.baseName());
        }
    }.lt);
    return out[0..n];
}

fn readDir(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const r = try realiseExisting(ev, args[0], .full, pos);
    var failed: hooks.Failed = undefined;
    const listing = r.at.readDir(ev, &failed) catch |e| switch (e) {
        error.IoFailed => {
            if (failed.err == error.NotDir) return ev.fail(.io, pos, "'{s}' is not a directory", .{r.shown});
            return ioError(ev, failed.err, failed.verb, r.shown, pos);
        },
        else => |x| return x,
    };
    var names: [4]Value = undefined;
    for (std.enums.values(FileType), 0..) |t, i| names[i] = try ev.mkStringStatic(t.nixName(), &.{});
    const entries = try ev.gpa.alloc(value.Attr, listing.len);
    defer ev.gpa.free(entries);
    for (listing, entries) |l, *e| e.* = .{ .sym = try ev.sym(l.name), .pos = .none, .cell = .init(names[@backingInt(l.type)]) };
    return ev.mkAttrs(entries, pos);
}

/// Reads `st_size` bytes like `readFile`, so a procfs file hashes as empty.
fn hashFile(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const algo = try @import("text.zig").parseAlgo(ev, args[0], pos, "while evaluating the first argument passed to builtins.hashFile");
    const p = try realisePath(ev, args[1], pos);
    const l = try hooks.located(ev, p, .full, pos);
    const at = try hooks.check(ev, l.at, l.path, pos);
    var failed: hooks.Failed = undefined;
    const bytes = at.read(ev, null, true, &failed) catch |e| switch (e) {
        error.IoFailed => return ev.fail(.io, pos, "opening file '{s}': {s}", .{ l.path, errors.ioText(failed.err) }),
        else => |x| return x,
    };
    var buf: [Hash.max_string_len]u8 = undefined;
    return ev.mkString(hash_mod.hashBytes(algo, bytes).print(&buf, .base16, false));
}

fn readFileType(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const r = try realiseExisting(ev, args[0], null, pos);
    const kind = r.at.stat(ev, false) catch |e| switch (e) {
        error.OutOfMemory, error.EvalFailed => |x| return x,
        else => return ioError(ev, e, hooks.stat_verb, r.shown, pos),
    };
    return ev.mkStringStatic(kind.nixName(), &.{});
}

fn pathExists(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const v = try ev.force(args[0]);
    const must_be_dir = v.kind() == .string and blk: {
        const b = v.as(value.String).bytes();
        break :blk std.mem.endsWith(u8, b, "/") or std.mem.endsWith(u8, b, "/.");
    };
    const p = try realisePath(ev, v, pos);
    const mode: hooks.Follow = if (must_be_dir) .full else .ancestors;
    const l = try hooks.located(ev, p, mode, pos);
    if (!try hooks.admits(ev, l.at, l.path, mode, pos)) return .false;
    try lint.coerce.readThroughCopy(ev, l.path, pos);
    const at = l.at orelse SrcPath.fs(l.path);
    const k = at.stat(ev, must_be_dir) catch |e| switch (e) {
        error.OutOfMemory, error.EvalFailed => |x| return x,
        error.FileNotFound, error.NotDir => return .false,
        else => return ioError(ev, e, hooks.stat_verb, (try at.local(ev)) orelse l.path, pos),
    };
    return .fromBool(k == .directory or !must_be_dir);
}

fn toPath(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    const p = try coerceToPath(ev, args[0], &ctx, pos, "while evaluating the first argument passed to builtins.toPath");
    return ev.mkStringCtx(p, ctx.items);
}

/// The store path `<store>/<hash>-<name>` that `p` is or lies under.
fn toStorePath(p: []const u8) ?StorePath {
    const s = hooks.splitStorePath(p) orelse return null;
    if (s.base.len > store_path.max_base_len) return null;
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var d: Diag = .init(fba.allocator());
    return StorePath.fromBaseName(s.base, &d) catch null;
}

/// `<store>/<hash>-<name>` with nothing after it.
fn isStorePath(p: []const u8) bool {
    const s = hooks.splitStorePath(p) orelse return false;
    return s.rest.len == 0 and toStorePath(p) != null;
}

fn storePath(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    if (ev.config.pure)
        return ev.fail(.eval, pos, "'builtins.storePath' is not allowed in pure evaluation mode", .{});
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    var p = try coerceToPath(ev, args[0], &ctx, pos, "while evaluating the first argument passed to 'builtins.storePath'");
    if (!isStorePath(p)) {
        p = try hooks.resolveLinks(ev, p, .full, pos);
        const at = try hooks.locate(ev, p);
        if (at == null or try at.?.hidden(ev)) {
            p = canonicalize(ev, p) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ioError(ev, e, hooks.stat_verb, p, pos),
            };
        }
    }
    const sp = toStorePath(p) orelse
        return ev.fail(.eval, pos, "path '{s}' is not in the Nix store", .{p});
    try ctx.append(ev.gpa, .{ .kind = .opaque_path, .path = try fullPath(ev, &sp) });
    return ev.mkStringCtx(p, ctx.items);
}

/// The base name of a canonical path; `source` for the root, like
/// `SourcePath::baseName`.
fn baseName(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return "source";
    return if (i + 1 < p.len) p[i + 1 ..] else "source";
}

/// A store path as a string whose context is that path.
fn storePathString(ev: *Evaluator, sp: *const StorePath) Error!Value {
    const full = try fullPath(ev, sp);
    const ctx = try ev.local.arena.dupe(Ctx, &.{.{ .kind = .opaque_path, .path = full }});
    return ev.mkStringStatic(full, ctx);
}

/// The store path `p` lies under when the value that named it carried a
/// context, which is when primops.cc:addPath reads its references.
fn inStore(ev: *Evaluator, p: []const u8, ctx: []const Ctx) ?StorePath {
    if (ctx.len == 0 or !ev.isStorePathText(p)) return null;
    return toStorePath(p);
}

/// A `builtins.path` or `filterSource` filter: the tree's own, then the
/// user's function, which sees the path as Nix would show it.
const UserFilter = struct {
    ev: *Evaluator,
    at: *const SrcPath,
    func: ?Value,
    pos: Pos,
    /// For a copy below a copied store path: the local root and the store
    /// path it stands for.
    local_root: []const u8,
    shown_root: ?[]const u8,
    accepted: ?*hooks.PathSet,
    /// Set when the copy keeps a `.git` entry at its top, with
    /// `git-in-source` on.
    saw_git: ?*bool = null,
    /// The tracing cache's fingerprint of the tree, fed every offer.
    fp: ?*@import("../trace.zig").TreeFp = null,

    pub fn accept(f: UserFilter, p: []const u8, t: FileType) Error!bool {
        const keep = try f.decide(p, t);
        if (f.fp) |x| x.entry(p, t, keep);
        if (keep) if (f.saw_git) |g| if (hooks.isGitEntry(f.local_root, p)) {
            g.* = true;
        };
        return keep;
    }

    fn decide(f: UserFilter, p: []const u8, t: FileType) Error!bool {
        if (!f.at.accepts(p)) return false;
        const func = f.func orelse return true;
        const ev = f.ev;
        const shown = if (f.shown_root) |r|
            if (std.mem.startsWith(u8, p, f.local_root))
                try std.mem.concat(ev.local.arena.allocator(), u8, &.{ r, p[f.local_root.len..] })
            else
                p
        else
            p;
        const a = try ev.mkString(shown);
        const b = try ev.mkStringStatic(t.nixName(), &.{});
        const r = try ev.call2(func, a, b, f.pos);
        const keep = try ev.forceBool(r, f.pos, "while evaluating the return value of the path filter function");
        if (keep) if (f.accepted) |set| try set.put(ev.local.arena.allocator(), try ev.local.arena.dupe(u8, p), {});
        return keep;
    }
};

/// Mirrors primops.cc:addPath. `in_store` is a store path the caller was
/// given with a context, whose references belong to the copy.
pub fn addPath(ev: *Evaluator, pos: Pos, name: []const u8, p: []const u8, filter: ?Value, method: IngestionMethod, expected: ?Hash, in_store: ?StorePath) Error!StorePath {
    return addPathInner(ev, pos, name, p, filter, method, expected, in_store) catch |e|
        ev.addTrace(e, pos, "while adding path '{s}'", .{p});
}

fn addPathInner(ev: *Evaluator, pos: Pos, name_in: []const u8, p_in: []const u8, filter: ?Value, method: IngestionMethod, expected: ?Hash, in_store: ?StorePath) Error!StorePath {
    const name = try utf8(ev, name_in, pos);
    const refs = try references(ev, if (in_store) |*s| s else null);
    try lint.coerce.storePathRecopy(ev, p_in, pos);
    try lint.coerce.readThroughCopy(ev, p_in, pos);
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const expected_sp: ?StorePath = if (expected) |h|
        store_path.makeFixedOutputPath(method, h, name, refs, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()})
    else
        null;
    // An expected path already valid in the real store could be returned
    // without reading the source (source/remote.zig:validInStore); that
    // check would plug in here.

    // primops.cc:addPath dumps `path.resolveSymlinks()`, so the copy is of
    // what the links point at and a dangling one is an error.
    const l = try hooks.located(ev, p_in, .full, pos);
    const p = l.path;
    const virtual_tree = l.at != null;
    // A path under a tree this evaluation copied reads the local tree, with
    // that tree's filter applied before this call's `filter`; the filter
    // function still sees the store path Nix would show it.
    var at = try hooks.check(ev, l.at, p, pos);
    if (!virtual_tree) {
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(ev.io, p, ev.local.arena.allocator()) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // a link with no target, or a missing component: the walk names
            // the path that does not exist, as `resolveSymlinks` names it
            else => {
                const end = try hooks.resolveLinks(ev, p, .full, pos);
                return ioError(ev, error.FileNotFound, hooks.stat_verb, end, pos);
            },
        };
        if (!std.mem.eql(u8, resolved, p)) ev.trace().canon(p, resolved);
        at = .fs(resolved);
    }
    switch ((try at.at(ev)) orelse return ioError(ev, error.FileNotFound, hooks.stat_verb, p, pos)) {
        .mem => return hooks.recopyUnsupported(ev, p, pos),
        .tree => |x| {
            @import("../treestore.zig").record(ev.trace(), x.t);
            if (method == .flat) {
                var failed: hooks.Failed = undefined;
                const bytes = at.read(ev, null, true, &failed) catch |e| switch (e) {
                    error.IoFailed => return readError(ev, failed, p, pos),
                    else => |y| return y,
                };
                const sp = store_path.makeFixedOutputPath(.flat, hash_mod.hashBytes(.sha256, bytes), name, refs, &d) catch
                    return ev.fail(.eval, pos, "{s}", .{d.message()});
                hooks.noteStoreAdd(ev, &sp, "flat", bytes.len, at, pos);
                return finish(ev, pos, p, sp, expected_sp);
            }
            return addStoredCopy(ev, pos, name, p, filter, refs, at, x.t, virtual_tree, expected_sp);
        },
        .disk => {},
    }
    if (virtual_tree) _ = at.stat(ev, false) catch |e| switch (e) {
        error.OutOfMemory, error.EvalFailed => |x| return x,
        else => return ioError(ev, error.FileNotFound, hooks.stat_verb, p, pos),
    };
    const resolved = (try at.local(ev)).?;
    const parent = at.src.fs.accepted;
    var hash: Hash = undefined;
    var nar_size: u64 = 0;
    switch (method) {
        // only `outputHashMode` reaches it, never a path added to the store
        .text => unreachable,
        .flat => {
            var failed: hooks.Failed = undefined;
            const bytes = at.read(ev, null, true, &failed) catch |e| switch (e) {
                error.IoFailed => return readError(ev, failed, p, pos),
                else => |x| return x,
            };
            hash = hash_mod.hashBytes(.sha256, bytes);
            nar_size = bytes.len;
        },
        .recursive => {
            var accepted: ?*hooks.PathSet = null;
            if (filter != null) {
                accepted = try ev.local.arena.create(hooks.PathSet);
                accepted.?.* = .empty;
            }
            var saw_git = false;
            // The observation records `accepted`, which is the dump's own
            // decisions unless an enclosing tree's `parent` set is the only
            // thing narrowing them: then the recorded filter is accept-all
            // and only a separate walk matches it.
            var fp: ?@import("../trace.zig").TreeFp = if (filter != null or parent == null) ev.trace().fp(resolved) else null;
            const uf: UserFilter = .{
                .ev = ev,
                .at = &at,
                .func = filter,
                .pos = pos,
                .local_root = resolved,
                .shown_root = if (virtual_tree) p else null,
                .accepted = accepted,
                .saw_git = if (ev.lintOn(.git_in_source)) &saw_git else null,
                .fp = if (fp) |*x| x else null,
            };
            const nh = nar.narHashFiltered(ev.gpa, ev.io, std.Io.Dir.cwd(), resolved, .sha256, uf, &d) catch |e| switch (e) {
                error.OutOfMemory, error.EvalFailed => |x| return x,
                error.BadPath => return ev.fail(.io, pos, "{s}", .{d.message()}),
                else => return ioError(ev, e, "copying", p, pos),
            };
            hash = nh.hash;
            ev.trace().tree(resolved, @import("../trace.zig").hashToDigest(&hash), accepted, if (fp) |*x| x else null);
            if (saw_git) try lint.purity.gitInSource(ev, p, pos);
            try lint.purity.largeSourceCopy(ev, p, nh.size, pos);
            const sp = store_path.makeFixedOutputPath(method, hash, name, refs, &d) catch
                return ev.fail(.eval, pos, "{s}", .{d.message()});
            hooks.noteStoreAdd(ev, &sp, "tree", nh.size, at, pos);
            try hooks.addTree(ev, &sp, resolved, if (accepted) |a| a else parent, true, nh);
            return finish(ev, pos, p, sp, expected_sp);
        },
    }
    const sp = store_path.makeFixedOutputPath(method, hash, name, refs, &d) catch
        return ev.fail(.eval, pos, "{s}", .{d.message()});
    hooks.noteStoreAdd(ev, &sp, "flat", nar_size, at, pos);
    return finish(ev, pos, p, sp, expected_sp);
}

/// `addPath`'s recursive copy of a member of an input store entry: the
/// dump out of the packs under the tree's own filter and then `filter`,
/// whose decisions the copy keeps as its `accepted` set, each member named
/// by its path in the entry under `/`. The filter function sees the store
/// path Nix would show it.
fn addStoredCopy(ev: *Evaluator, pos: Pos, name: []const u8, p: []const u8, filter: ?Value, refs: []const StorePath, at: hooks.SrcPath, t: *@import("../treestore.zig").StoredTree, virtual_tree: bool, expected_sp: ?StorePath) Error!StorePath {
    if (virtual_tree) _ = at.stat(ev, false) catch |e| switch (e) {
        error.OutOfMemory, error.EvalFailed => |x| return x,
        else => return ioError(ev, error.FileNotFound, hooks.stat_verb, p, pos),
    };
    const a = ev.local.arena.allocator();
    const parent = at.src.tree.accepted;
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    var accepted: ?*hooks.PathSet = null;
    var nh: nar.NarHash = undefined;
    if (filter == null and parent == null and at.rel.len == 0) {
        // the whole entry: its NAR hash is in the index
        nh = .{ .hash = t.nar_hash, .size = t.nar_size };
    } else {
        if (filter != null) {
            accepted = try a.create(hooks.PathSet);
            accepted.?.* = .empty;
        }
        var scratch: std.heap.ArenaAllocator = .init(ev.gpa);
        defer scratch.deinit();
        const base = try @import("../store/source.zig").SrcPath.spoolBase(scratch.allocator(), at.rel);
        const uf: UserFilter = .{
            .ev = ev,
            .at = &at,
            .func = filter,
            .pos = pos,
            .local_root = base,
            .shown_root = if (virtual_tree) p else null,
            .accepted = accepted,
        };
        var h: hash_mod.Hasher = .init(.sha256);
        var hb: [64 << 10]u8 = undefined;
        var hw = h.writer(&hb);
        t.dump(scratch.allocator(), at.rel, base, &hw.interface, uf, &d) catch |e| switch (e) {
            error.OutOfMemory, error.EvalFailed => |x| return x,
            else => return if (d.msg != null) ev.fail(.io, pos, "{s}", .{d.message()}) else ioError(ev, e, "copying", p, pos),
        };
        hw.interface.flush() catch {};
        nh = .{ .size = h.count, .hash = h.finish() };
    }
    const sp = store_path.makeFixedOutputPath(.recursive, nh.hash, name, refs, &d) catch
        return ev.fail(.eval, pos, "{s}", .{d.message()});
    hooks.noteStoreAdd(ev, &sp, "tree", nh.size, at, pos);
    // a spool origin's root is itself a member, which no filter was asked about
    if (accepted) |set| try set.put(a, try at.inSpool(a), {});
    const kept: ?*const hooks.PathSet = if (accepted) |set| set else parent;
    try hooks.addStoredCopy(ev, &sp, .{ .t = t, .accepted = kept }, at.rel, nh);
    return finish(ev, pos, p, sp, expected_sp);
}

fn finish(ev: *Evaluator, pos: Pos, p: []const u8, sp: StorePath, expected: ?StorePath) Error!StorePath {
    if (expected) |e| if (!e.eql(&sp))
        return ev.fail(.eval, pos, "store path mismatch in (possibly filtered) path added from '{s}'", .{p});
    return sp;
}

fn filterSource(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    const p = try coerceToPath(ev, args[1], &ctx, pos, "while evaluating the second argument (the path to filter) passed to 'builtins.filterSource'");
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.filterSource");
    const sp = try addPath(ev, pos, baseName(p), p, f, .recursive, null, inStore(ev, p, ctx.items));
    return storePathString(ev, &sp);
}

/// Mirrors `newHashAllowEmpty`: an empty hash string means all zeros.
pub fn parseSha256AllowEmpty(ev: *Evaluator, s_in: []const u8, pos: Pos) Error!Hash {
    const s = try utf8(ev, s_in, pos);
    if (s.len == 0) {
        const zero: Hash = .raw(.sha256, &@as([32]u8, @splat(0)));
        var buf: [Hash.max_string_len]u8 = undefined;
        try ev.effect("warning: found empty hash, assuming '{s}'", .{zero.print(&buf, .sri, true)});
        return zero;
    }
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    return Hash.parseAny(s, .sha256, &d) catch ev.fail(.eval, pos, "{s}", .{d.message()});
}

fn path(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const a = try ev.forceAttrs(args[0], pos, "while evaluating the argument passed to 'builtins.path'");
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    var p: ?[]const u8 = null;
    var name: []const u8 = "";
    var filter: ?Value = null;
    var method: IngestionMethod = .recursive;
    var expected: ?Hash = null;
    for (a.attrs()) |*attr| {
        const n = ev.interner.name(attr.sym);
        const v = attr.cell.get();
        if (std.mem.eql(u8, n, "path")) {
            p = try coerceToPath(ev, v, &ctx, attr.pos, "while evaluating the 'path' attribute passed to 'builtins.path'");
        } else if (std.mem.eql(u8, n, "name")) {
            name = try ev.forceStringNoCtx(v, attr.pos, "while evaluating the `name` attribute passed to builtins.path");
        } else if (std.mem.eql(u8, n, "filter")) {
            filter = try ev.forceFunction(v, attr.pos, "while evaluating the `filter` parameter passed to builtins.path");
        } else if (std.mem.eql(u8, n, "recursive")) {
            method = if (try ev.forceBool(v, attr.pos, "while evaluating the `recursive` attribute passed to builtins.path")) .recursive else .flat;
        } else if (std.mem.eql(u8, n, "sha256")) {
            const s = try ev.forceStringNoCtx(v, attr.pos, "while evaluating the `sha256` attribute passed to builtins.path");
            expected = try parseSha256AllowEmpty(ev, s, attr.pos);
        } else {
            return ev.fail(.eval, attr.pos, "unsupported argument '{s}' to 'builtins.path'", .{n});
        }
    }
    const pp = p orelse
        return ev.fail(.eval, pos, "missing required 'path' attribute in the first argument to 'builtins.path'", .{});
    if (name.len == 0) name = baseName(pp);
    const sp = try addPath(ev, pos, name, pp, filter, method, expected, inStore(ev, pp, ctx.items));
    return storePathString(ev, &sp);
}

/// Nix's internal context form: base names, `=` and `!out!` prefixes.
fn writeCtxInternal(w: *std.Io.Writer, c: Ctx) std.Io.Writer.Error!void {
    switch (c.kind) {
        .opaque_path => try w.writeAll(baseName(c.path)),
        .drv_deep => try w.print("={s}", .{baseName(c.path)}),
        // value/context.cc: one `<output>!` per layer, then the `.drv`'s name
        .built => {
            try w.print("!{s}!", .{c.output});
            var rest = c.path;
            while (std.mem.indexOfScalar(u8, rest, '!')) |i| {
                try w.print("{s}!", .{rest[0..i]});
                rest = rest[i + 1 ..];
            }
            try w.writeAll(baseName(rest));
        },
        .impure_path, .impure_meta => try w.writeAll(c.path),
    }
}

fn toFile(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const name = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.toFile");
    const contents = try ev.forceString(args[1], pos, "while evaluating the second argument passed to builtins.toFile");
    var refs: std.ArrayList(StorePath) = .empty;
    defer refs.deinit(ev.gpa);
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    for (contents.context()) |c| switch (c.kind) {
        .impure_path, .impure_meta => {},
        .opaque_path => {
            const sp = StorePath.parse(try utf8(ev, c.path, pos), &d) catch
                return ev.fail(.eval, pos, "{s}", .{d.message()});
            try refs.append(ev.gpa, sp);
        },
        .drv_deep, .built => {
            var buf: [1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            writeCtxInternal(&w, c) catch {};
            return ev.fail(.eval, pos, "files created by builtins.toFile may not reference derivations, but {s} references {s}", .{ name, w.buffered() });
        },
    };
    const sorted = store_path.sortUnique(refs.items);
    const h = hash_mod.hashBytes(.sha256, contents.bytes());
    const sp = store_path.makeTextPath(try utf8(ev, name, pos), h, .{ .a = sorted }, &d) catch
        return ev.fail(.eval, pos, "{s}", .{d.message()});
    hooks.noteStoreAdd(ev, &sp, "text", contents.bytes().len, .{ .src = .{ .mem = "" } }, pos);
    try hooks.addText(ev, &sp, contents.bytes(), sorted);
    return storePathString(ev, &sp);
}
