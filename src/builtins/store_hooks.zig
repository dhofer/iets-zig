//! Where the bytes of a path the evaluator reads come from, and what copying
//! a path to the store makes of it.
//!
//! iets never writes the store. A store path this evaluation made stands for
//! bytes it still has: `"${./x}"`, `builtins.path` and `filterSource` record
//! the local tree they hashed (and the filter's choices), `toFile` and the
//! derivation family record a text in memory. Every reader of a path asks
//! `locate` first, so `readFile "${./x}/a"`, `import` of a copied file and
//! `pathExists` read the local tree. The content is the same by
//! construction: the store path is the NAR hash of exactly those bytes.
//!
//! Every reader below records what it saw in the tracing cache's read set
//! (`Evaluator.trace`). Missing, and would plug in here: the SCM's
//! untracked-file check in `check`.

const std = @import("std");
const errors = @import("../errors.zig");
const Io = std.Io;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const store_path = @import("../store/path.zig");
const StorePath = store_path.StorePath;
const nar = @import("../store/nar.zig");
const FileType = nar.FileType;
const Hash = @import("../store/hash.zig").Hash;
const import_ = @import("../eval/import.zig");
// A fetched input is read out of the input store.
const treestore = @import("../treestore.zig");
const purity = @import("../lint/purity.zig");
const trace_mod = @import("../trace.zig");
const source_mod = @import("../store/source.zig");
const sysfs = @import("../sys/fs.zig");

/// Absolute paths on disk a filtered copy kept.
pub const PathSet = std.StringHashMapUnmanaged(void);

pub const Src = union(enum) {
    /// A tree on disk at `root`. `accepted`, when set, holds the paths below
    /// `root` the copy kept; anything else under it is not in the copy.
    fs: struct { root: []const u8, accepted: ?*const PathSet = null },
    /// A `toFile` text or a `.drv` this evaluation holds in memory.
    mem: []const u8,
    /// A tree the input store holds: a fetched input, read out of its packs.
    tree: Tree,

    pub const Tree = struct {
        t: *treestore.StoredTree,
        /// As for `fs`, with each member named by its path in the entry
        /// under `/` (`SrcPath.inSpool`).
        accepted: ?*const PathSet = null,
    };
};

/// What a store path this evaluation made stands for.
pub const Origin = struct {
    src: Src,
    /// A text's references, sorted and unique; none for a tree.
    refs: []const StorePath = &.{},
    /// A tree's NAR hash and size under its filter, so an upload sends it
    /// without hashing the tree again; null for a text.
    nar: ?nar.NarHash = null,
    /// Copied from a local path by this evaluation (`read-through-copy`).
    copy: bool = false,
    /// For `.tree`: the member of the input store entry the copy is of,
    /// empty for the entry itself.
    rel: []const u8 = "",
};

/// The evaluator's store bookkeeping (`Evaluator.hooks`). Everything lives in
/// the evaluator's arena.
pub const State = struct {
    /// Store paths this evaluation made, by base name.
    known: std.StringHashMapUnmanaged(Origin) = .empty,
    /// Store paths a pure evaluation may read though it did not make them:
    /// built outputs an import read (`addOnDisk`), by base name.
    on_disk: std.StringHashMapUnmanaged(void) = .empty,
    /// The lock node name of the flake root and of each locked input, by
    /// base name: a tree whose files are the user's or an input's (lint
    /// scope) and whose paths are not re-copies.
    flakes: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The store path of `"${path}"`, by source path.
    src_to_store: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// What the local store answered for the references of a path, by base name.
    store_refs: std.StringHashMapUnmanaged([]const StorePath) = .empty,
    /// Store queries started ahead, by base name: see `prefetchReferences`.
    prefetched: std.StringHashMapUnmanaged(*Prefetch) = .empty,
    /// Paths of the project the kernel showed resolve inside it, and
    /// whether with the last component followed (`admits`).
    beneath: std.StringHashMapUnmanaged(bool) = .empty,
    /// The project root, opened once for `beneath`; -1 when it cannot be.
    project_fd: ?std.os.linux.fd_t = null,

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        var it = st.prefetched.valueIterator();
        while (it.next()) |p| p.*.deinit();
        st.prefetched.deinit(gpa);
        st.known.deinit(gpa);
        st.on_disk.deinit(gpa);
        st.flakes.deinit(gpa);
        st.src_to_store.deinit(gpa);
        st.store_refs.deinit(gpa);
        st.beneath.deinit(gpa);
        if (st.project_fd) |fd| if (fd >= 0) {
            _ = std.os.linux.close(fd);
        };
    }
};

/// A `nix path-info` run on another thread from the start, so the answer is
/// there when evaluation first asks: the process costs ~25 ms, which every
/// worker would otherwise wait out.
pub const Prefetch = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Held while one thread awaits the future; the others wait for its answer.
    lock: Io.Mutex = .init,
    future: Io.Future(?[]StorePath),
    taken: bool = false,

    /// The references, owned by the slot; null when the store did not answer.
    fn answer(p: *Prefetch) ?[]StorePath {
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        p.taken = true;
        return p.future.await(p.io);
    }

    fn deinit(p: *Prefetch) void {
        const r = if (p.taken) p.future.await(p.io) else p.future.cancel(p.io);
        if (r) |refs| p.gpa.free(refs);
        p.gpa.destroy(p);
    }
};

/// At most this many prefetches start; the rest are queried on demand.
const max_prefetch = 8;

/// Start the store query for every search-path entry that is a store path:
/// `-I nixpkgs=/nix/store/...` is copied with its context, so evaluation asks
/// for its references.
pub fn prefetchSearchPath(ev: *Evaluator) Error!void {
    for (ev.config.search_path) |e| {
        if (ev.shared.hooks.prefetched.count() >= max_prefetch) return;
        const rest = store_path.stripStoreDir(e.path) orelse continue;
        const base = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        var d: Diag = .init(ev.gpa);
        defer d.deinit();
        const sp = StorePath.fromBaseName(base, &d) catch continue;
        if (ev.shared.hooks.prefetched.contains(sp.baseName())) continue;
        const p = try ev.gpa.create(Prefetch);
        p.* = .{ .gpa = ev.gpa, .io = ev.io, .future = ev.io.concurrent(queryStore, .{ ev.gpa, ev.io, sp }) catch {
            ev.gpa.destroy(p);
            return;
        } };
        const key = try ev.local.arena.allocator().dupe(u8, sp.baseName());
        try ev.shared.hooks.prefetched.put(ev.gpa, key, p);
    }
}

/// What a stat says, `missing` for any error where a kind is all the caller
/// wants: the tracing cache's kinds.
pub const Kind = trace_mod.Kind;

/// A failed read: the verb Nix names the failed step with, and the error.
pub const Failed = struct { verb: []const u8, err: anyerror };

pub const stat_verb = "getting status of";
pub const read_verb = "reading file";

/// What a `SrcPath` opens.
pub const At = union(enum) {
    disk: []const u8,
    mem: []const u8,
    tree: struct { t: *treestore.StoredTree, rel: []const u8 },
};

pub const DirEntry = struct { name: []const u8, type: FileType };

/// A path below the root of a `Src`.
pub const SrcPath = struct {
    src: Src,
    /// Relative to the root, without a leading slash; empty for the root.
    rel: []const u8 = "",

    /// `p` itself on the real file system.
    pub fn fs(p: []const u8) SrcPath {
        return .{ .src = .{ .fs = .{ .root = p } } };
    }

    pub fn join(sp: SrcPath, ev: *Evaluator, sub: []const u8) Error!SrcPath {
        if (sub.len == 0) return sp;
        if (sp.rel.len == 0) return .{ .src = sp.src, .rel = sub };
        return .{ .src = sp.src, .rel = try std.mem.concat(ev.local.arena.allocator(), u8, &.{ sp.rel, "/", sub }) };
    }

    /// The path on disk, for `Src.fs`.
    pub fn local(sp: SrcPath, ev: *Evaluator) Error!?[]const u8 {
        const f = switch (sp.src) {
            .fs => |f| f,
            .mem, .tree => return null,
        };
        return try below(ev, f.root, sp.rel);
    }

    /// Whether the tree's filter kept `p`: a path on disk, or for an input
    /// store entry a path in it under `/`.
    pub fn accepts(sp: SrcPath, p: []const u8) bool {
        const accepted = switch (sp.src) {
            .fs => |f| f.accepted,
            .tree => |x| x.accepted,
            .mem => null,
        };
        return if (accepted) |a| a.contains(p) else true;
    }

    /// Where a spool dump names this path: `/` plus its path in the entry.
    pub fn inSpool(sp: SrcPath, a: std.mem.Allocator) Error![]const u8 {
        return std.mem.concat(a, u8, &.{ "/", sp.rel });
    }

    /// Null when the store copy has no such entry: the tree's filter left it
    /// out, or it lies below a file in memory.
    pub fn at(sp: SrcPath, ev: *Evaluator) Error!?At {
        switch (sp.src) {
            .fs => {
                const p = (try sp.local(ev)).?;
                if (sp.rel.len == 0 or sp.accepts(p)) return .{ .disk = p };
                return null;
            },
            .mem => |b| return if (sp.rel.len == 0) .{ .mem = b } else null,
            .tree => |x| {
                if (x.accepted != null and !sp.accepts(try sp.inSpool(ev.local.arena.allocator()))) return null;
                return .{ .tree = .{ .t = x.t, .rel = sp.rel } };
            },
        }
    }

    pub fn hidden(sp: SrcPath, ev: *Evaluator) Error!bool {
        return (try sp.at(ev)) == null;
    }

    /// A symlink's target; null for anything else and for an entry the
    /// tree's filter hides.
    pub fn readLink(sp: SrcPath, ev: *Evaluator) Error!?[]const u8 {
        const p = switch ((try sp.at(ev)) orelse return null) {
            .disk => |p| p,
            .mem => return null,
            .tree => |x| {
                const n = (try x.t.at(ev.local.arena.allocator(), x.rel, false)) orelse return null;
                return switch (n.*) {
                    .symlink => |target| target,
                    else => null,
                };
            },
        };
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(ev.io, p, &buf) catch return null;
        return try ev.local.arena.dupe(u8, buf[0..n]);
    }

    /// `stat`, or `lstat` unless `follow`, recorded in the read set.
    pub fn stat(sp: SrcPath, ev: *Evaluator, follow: bool) (Error || Io.Dir.StatFileError)!Kind {
        switch ((try sp.at(ev)) orelse return error.FileNotFound) {
            .disk => |p| {
                const m = sysfs.stat(p, follow) catch |e| {
                    ev.trace().stat(p, follow, .missing);
                    return switch (e) {
                        error.Unreadable => error.AccessDenied,
                        else => |x| x,
                    };
                };
                const k: Kind = .ofMode(m.mode);
                ev.trace().stat(p, follow, k);
                return k;
            },
            .mem => return .regular,
            .tree => |x| {
                treestore.record(ev.trace(), x.t);
                const t = (try x.t.stat(ev.local.arena.allocator(), x.rel, follow)) orelse return error.FileNotFound;
                return switch (t) {
                    .regular => .regular,
                    .directory => .directory,
                    .symlink => .symlink,
                    .unknown => .other,
                };
            },
        }
    }

    /// `import`'s stat: whether `/default.nix` is appended. A regular file on
    /// disk records nothing: its `File` observation checks the type.
    pub fn isDir(sp: SrcPath, ev: *Evaluator) (Error || Io.Dir.StatFileError)!bool {
        if (try sp.at(ev)) |a| if (a == .disk) {
            const m = sysfs.stat(a.disk, true) catch |e| return switch (e) {
                error.Unreadable => error.AccessDenied,
                else => |x| x,
            };
            if (m.isDir()) ev.trace().stat(a.disk, true, .directory);
            return m.isDir();
        };
        return (try sp.stat(ev, true)) == .directory;
    }

    /// A regular file's bytes, in the arena. `sized` is `readFile`'s read: a
    /// stat first, `IsDir` for a file that is not regular, then `st_size`
    /// bytes, so a procfs file reads as empty. Otherwise the file is read to
    /// its end (`import`). On `error.IoFailed`, `failed` says why.
    /// The bytes, from `a`; null `a` reads into the arena, where an
    /// in-memory text is returned as it is.
    pub fn read(sp: SrcPath, ev: *Evaluator, a_: ?std.mem.Allocator, sized: bool, failed: *Failed) (Error || error{IoFailed})![]const u8 {
        const p = switch ((try sp.at(ev)) orelse return fail(failed, stat_verb, error.FileNotFound)) {
            .disk => |p| p,
            .mem => |b| return if (a_) |a| a.dupe(u8, b) else b,
            .tree => |x| {
                const r = x.t.read(a_ orelse ev.local.arena.allocator(), x.rel) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // the type of the member is what the stat would have said
                    error.FileNotFound => return fail(failed, stat_verb, e),
                    error.IsDir => return fail(failed, if (sized) stat_verb else read_verb, e),
                    else => {
                        treestore.record(ev.trace(), x.t);
                        return fail(failed, read_verb, e);
                    },
                };
                treestore.record(ev.trace(), x.t);
                return r;
            },
        };
        const a = a_ orelse ev.local.arena.allocator();
        const tr = ev.trace();
        var meta: ?sysfs.Meta = null;
        if (sized) {
            const m = sysfs.stat(p, true) catch |e| return fail(failed, stat_verb, statErr(e));
            if (m.isDir()) return fail(failed, stat_verb, error.IsDir);
            // a FIFO or a device has no size to read to: read it to its end
            if (m.isFile()) meta = m;
        }
        const f = Io.Dir.cwd().openFile(ev.io, p, .{}) catch |e| return fail(failed, read_verb, e);
        defer f.close(ev.io);
        if (meta == null) {
            // `import`: the stat of the open file, which the read set needs
            if (tr.isOn()) meta = sysfs.fstat(f.handle) catch |e| return fail(failed, stat_verb, statErr(e));
            var buf: [4096]u8 = undefined;
            var r = f.readerStreaming(ev.io, &buf);
            const bytes = r.interface.allocRemaining(a, .unlimited) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fail(failed, read_verb, r.err orelse e),
            };
            if (meta) |m| tr.file(p, m, bytes);
            return bytes;
        }
        const buf = try a.alloc(u8, @intCast(meta.?.size));
        var n: usize = 0;
        while (n < buf.len) {
            const k = f.readPositional(ev.io, &.{buf[n..]}, n) catch |e| return fail(failed, read_verb, e);
            if (k == 0) break;
            n += k;
        }
        tr.file(p, meta.?, buf[0..n]);
        return buf[0..n];
    }

    /// A directory's entries, the ones the tree's filter hides left out;
    /// `NotDir` for anything else.
    pub fn readDir(sp: SrcPath, ev: *Evaluator, failed: *Failed) (Error || error{IoFailed})![]DirEntry {
        const p = switch ((try sp.at(ev)) orelse return fail(failed, stat_verb, error.FileNotFound)) {
            .disk => |p| p,
            .mem => return fail(failed, stat_verb, error.NotDir),
            .tree => |x| {
                const a = ev.local.arena.allocator();
                const list = x.t.list(a, x.rel) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return fail(failed, "opening directory", e),
                };
                treestore.record(ev.trace(), x.t);
                const out = try a.alloc(DirEntry, list.len);
                var n: usize = 0;
                for (list) |e| {
                    if (sp.src.tree.accepted != null) {
                        const member = try std.mem.concat(a, u8, &.{ if (x.rel.len == 0) "" else "/", x.rel, "/", e.name });
                        if (!sp.accepts(member)) continue;
                    }
                    out[n] = .{ .name = e.name, .type = e.node.fileType() };
                    n += 1;
                }
                return out[0..n];
            },
        };
        var dir = Io.Dir.cwd().openDir(ev.io, p, .{ .iterate = true }) catch |e| return fail(failed, "opening directory", e);
        defer dir.close(ev.io);
        const a = ev.local.arena.allocator();
        var out: std.ArrayList(DirEntry) = .empty;
        // the `Dir` observation keeps the full listing, the one validation
        // can read again, not the one the tree's filter leaves
        const tr = ev.trace();
        var listing: std.ArrayList(trace_mod.DirEnt) = .empty;
        defer listing.deinit(ev.gpa);
        var it = dir.iterateAssumeFirstIteration();
        while (it.next(ev.io) catch |e| return fail(failed, "reading directory", e)) |e| {
            const t: FileType = if (e.kind == .unknown) blk: {
                // a file system whose `dirent` carries no `d_type`
                const st = dir.statFile(ev.io, e.name, .{ .follow_symlinks = false }) catch |err|
                    return fail(failed, stat_verb, err);
                break :blk .of(st.kind);
            } else .of(e.kind);
            const name = try a.dupe(u8, e.name);
            if (tr.isOn()) try listing.append(ev.gpa, .{ .name = name, .kind = .ofFileType(t) });
            if (sp.src == .fs and sp.src.fs.accepted != null) {
                const full = try below(ev, p, e.name);
                if (!sp.accepts(full)) continue;
            }
            try out.append(a, .{ .name = name, .type = t });
        }
        if (tr.isOn()) tr.record(.{ .dir = .{ .path = p, .hash = trace_mod.dirListingHash(listing.items) } });
        return out.items;
    }
};

fn statErr(e: sysfs.StatError) anyerror {
    return switch (e) {
        error.Unreadable => error.AccessDenied,
        else => e,
    };
}

fn fail(failed: *Failed, verb: []const u8, err: anyerror) error{IoFailed} {
    failed.* = .{ .verb = verb, .err = err };
    return error.IoFailed;
}

fn below(ev: *Evaluator, root: []const u8, rel: []const u8) Error![]const u8 {
    if (rel.len == 0) return root;
    const sep: []const u8 = if (std.mem.endsWith(u8, root, "/")) "" else "/";
    return std.mem.concat(ev.local.arena.allocator(), u8, &.{ root, sep, rel });
}

/// The store path `path` lies under, split into its base name and the rest
/// (without the slash); null outside the store.
pub fn splitStorePath(path: []const u8) ?struct { base: []const u8, rest: []const u8 } {
    const rest = store_path.stripStoreDir(path) orelse return null;
    const i = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ .base = rest, .rest = "" };
    return .{ .base = rest[0..i], .rest = rest[i + 1 ..] };
}

/// What `path` reads when it lies under a store path this evaluation made:
/// the local tree or the text it stands for. Null otherwise.
pub fn locate(ev: *Evaluator, path: []const u8) Error!?SrcPath {
    const s = splitStorePath(path) orelse return null;
    const o = knownGet(ev, s.base) orelse {
        if (!std.mem.endsWith(u8, s.base, ".drv")) return null;
        const text = drvText(ev, s.base) orelse return null;
        return try (SrcPath{ .src = .{ .mem = text } }).join(ev, s.rest);
    };
    const root: SrcPath = .{ .src = o.src, .rel = o.rel };
    return try root.join(ev, s.rest);
}

/// The ATerm of a derivation this evaluation made, when it was kept.
fn drvText(ev: *Evaluator, base: []const u8) ?[]const u8 {
    ev.shared.drv_lock.lock(ev);
    defer ev.shared.drv_lock.unlock(ev);
    const i = ev.shared.drv.table.get(base) orelse return null;
    return i.aterm;
}

/// `locate`, else `path` itself on the real file system.
pub fn resolve(ev: *Evaluator, path: []const u8) Error!SrcPath {
    return (try locate(ev, path)) orelse .fs(path);
}

/// The origin of a store path this evaluation made.
pub fn origin(ev: *Evaluator, sp: *const StorePath) ?Origin {
    return knownGet(ev, sp.baseName());
}

// The tables are shared by every worker; each access holds the lock only
// for the lookup or the insert, never across I/O or evaluation.

/// What this evaluation made the store path with base name `base` from.
pub fn knownOrigin(ev: *Evaluator, base: []const u8) ?Origin {
    return knownGet(ev, base);
}

fn knownGet(ev: *Evaluator, base: []const u8) ?Origin {
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    return ev.shared.hooks.known.get(base);
}

fn knownPut(ev: *Evaluator, base: []const u8, o: Origin) Error!void {
    const a = ev.local.arena.allocator();
    const key = try a.dupe(u8, base);
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    try ev.shared.hooks.known.put(ev.gpa, key, o);
}

/// The references of `sp`: a text's own (a `toFile`, a `.drv`), none for a
/// tree this evaluation copied, else what the local store holds, empty when
/// it cannot answer. primops.cc:addPath and prim_readFile swallow
/// `queryPathInfo`'s error the same way.
pub fn references(ev: *Evaluator, sp: *const StorePath) Error![]const StorePath {
    if (origin(ev, sp)) |o| return o.refs;
    {
        ev.shared.hooks_lock.lockUncancelable(ev.io);
        defer ev.shared.hooks_lock.unlock(ev.io);
        if (ev.shared.hooks.store_refs.get(sp.baseName())) |r| return r;
    }
    const r = try queryReferences(ev, sp);
    const key = try ev.local.arena.allocator().dupe(u8, sp.baseName());
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    try ev.shared.hooks.store_refs.put(ev.gpa, key, r);
    return r;
}

/// The local store's references of `sp`, from the query started ahead when
/// there is one; empty when the store cannot answer.
fn queryReferences(ev: *Evaluator, sp: *const StorePath) Error![]const StorePath {
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    const pre = ev.shared.hooks.prefetched.get(sp.baseName());
    ev.shared.hooks_lock.unlock(ev.io);
    // A failed prefetch queries again.
    const refs = (if (pre) |p| p.answer() else null) orelse queryStore(ev.gpa, ev.io, sp.*) orelse return &.{};
    defer if (pre == null) ev.gpa.free(refs);
    return ev.local.arena.dupe(StorePath, refs);
}

/// `nix path-info --json`'s references of `sp`, sorted and unique, or null.
/// This takes the `nix` on `PATH`, without looking past iets's own shims
/// for the real one.
fn queryStore(gpa: std.mem.Allocator, io: Io, sp: StorePath) ?[]StorePath {
    var pbuf: [512]u8 = undefined;
    const full = sp.print(&pbuf);
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "nix", "--extra-experimental-features", "nix-command", "path-info", "--json", full },
    }) catch return null;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |c| if (c != 0) return null,
        else => return null,
    }
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, res.stdout, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const info = parsed.value.object.get(full) orelse return null;
    if (info != .object) return null;
    const refs = info.object.get("references") orelse return null;
    if (refs != .array) return null;
    const out = gpa.alloc(StorePath, refs.array.items.len) catch return null;
    var d: Diag = .init(gpa);
    defer d.deinit();
    for (refs.array.items, out) |r, *o| {
        if (r == .string) if (StorePath.parse(r.string, &d)) |p| {
            o.* = p;
            continue;
        } else |_| {};
        gpa.free(out);
        return null;
    }
    const n = store_path.sortUnique(out).len;
    return gpa.realloc(out, n) catch {
        gpa.free(out);
        return null;
    };
}

/// Record a text this evaluation holds as store path `sp`: `toFile`, and the
/// derivation family's `.drv` files. `refs` is sorted and unique.
pub fn addText(ev: *Evaluator, sp: *const StorePath, bytes: []const u8, refs: []const StorePath) Error!void {
    const a = ev.local.arena.allocator();
    try knownPut(ev, sp.baseName(), .{
        .src = .{ .mem = try a.dupe(u8, bytes) },
        .refs = try a.dupe(StorePath, refs),
    });
}

/// Record that store path `sp` is a copy of the tree at `root` on disk,
/// restricted to `accepted` when set. `copy`: this evaluation copied it
/// from a local path (`builtins.path`, a coercion).
/// `nh` is the NAR hash and size the copy computed, when it did.
pub fn addTree(ev: *Evaluator, sp: *const StorePath, root: []const u8, accepted: ?*const PathSet, copy: bool, nh: ?nar.NarHash) Error!void {
    const a = ev.local.arena.allocator();
    try knownPut(ev, sp.baseName(), .{
        .src = .{ .fs = .{ .root = try a.dupe(u8, root), .accepted = accepted } },
        .copy = copy,
        .nar = nh,
    });
}

/// Record that store path `sp` is the tree `t` the input store holds, so
/// every read below it comes out of the store's packs.
pub fn addStoredTree(ev: *Evaluator, sp: *const StorePath, t: *treestore.StoredTree) Error!void {
    try knownPut(ev, sp.baseName(), .{ .src = .{ .tree = .{ .t = t } }, .nar = .{ .hash = t.nar_hash, .size = t.nar_size } });
}

/// Record that store path `sp` is the member `rel` of the input store
/// entry `x` under its filter, with the NAR hash and size its copy made.
pub fn addStoredCopy(ev: *Evaluator, sp: *const StorePath, x: Src.Tree, rel: []const u8, nh: nar.NarHash) Error!void {
    try knownPut(ev, sp.baseName(), .{ .src = .{ .tree = x }, .rel = try ev.local.arena.dupe(u8, rel), .nar = nh });
}

/// A copy of the member `at` of an input store entry: the entry itself
/// needs no hashing, as its store path is the one the lock named and its NAR
/// hash is in the index; a member below it, or a filtered tree, is hashed
/// out of the packs under the tree's filter. Every read of the copy goes to
/// the entry.
pub fn copyStoredTree(ev: *Evaluator, at: SrcPath, name: []const u8, path: []const u8, pos: Pos) Error!StorePath {
    const x = at.src.tree;
    const t = x.t;
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    if (at.rel.len == 0 and x.accepted == null and t.name.len > 0) if (StorePath.fromBaseName(t.name, &d)) |sp| return sp else |_| {};
    var h: @import("../store/hash.zig").Hasher = .init(.sha256);
    var hb: [64 << 10]u8 = undefined;
    var hw = h.writer(&hb);
    var scratch: std.heap.ArenaAllocator = .init(ev.gpa);
    defer scratch.deinit();
    const shown = try source_mod.SrcPath.spoolBase(scratch.allocator(), at.rel);
    t.dump(scratch.allocator(), at.rel, shown, &hw.interface, SpoolFilter{ .sp = &at }, &d) catch |e| {
        var ebuf: [128]u8 = undefined;
        return ev.fail(.io, pos, "copying '{s}' to the store: {s}", .{ path, if (d.msg) |m| m else errors.osText(&ebuf, e) });
    };
    hw.interface.flush() catch {};
    const size = h.count;
    const hash = h.finish();
    const sp = treestore.storePath(name, hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    const a = ev.local.arena.allocator();
    try knownPut(ev, sp.baseName(), .{ .src = at.src, .rel = try a.dupe(u8, at.rel), .nar = .{ .hash = hash, .size = size } });
    noteStoreAdd(ev, &sp, "tree", size, at, pos);
    return sp;
}

/// The filter of an input store member's dump: the tree's own.
pub const SpoolFilter = struct {
    sp: *const SrcPath,
    pub fn accept(f: SpoolFilter, p: []const u8, _: FileType) error{}!bool {
        return f.sp.accepts(p);
    }
};

/// Names the flake root or locked input `sp` is, unless it has a name: the
/// root is named before any input is fetched and keeps its name. Only a
/// path this evaluation knows, made or on disk, is named.
pub fn nameFlake(ev: *Evaluator, sp: *const StorePath, name: []const u8) Error!void {
    const a = ev.local.arena.allocator();
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    const st = &ev.shared.hooks;
    if (!st.known.contains(sp.baseName()) and !st.on_disk.contains(sp.baseName())) return;
    const gop = try st.flakes.getOrPut(ev.gpa, sp.baseName());
    if (gop.found_existing) return;
    gop.key_ptr.* = try a.dupe(u8, sp.baseName());
    gop.value_ptr.* = try a.dupe(u8, name);
}

/// The lock node name of the flake root or locked input whose store path
/// has the base name `base`.
pub fn flakeNamed(ev: *Evaluator, base: []const u8) ?[]const u8 {
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    return ev.shared.hooks.flakes.get(base);
}

/// The lock node name of the flake tree `path` lies in.
pub fn flakeOf(ev: *Evaluator, path: []const u8) ?[]const u8 {
    const s = splitStorePath(path) orelse return null;
    return flakeNamed(ev, s.base);
}

/// `p` is the `.git` entry at the top of the tree rooted at `root`.
pub fn isGitEntry(root: []const u8, p: []const u8) bool {
    if (!std.mem.endsWith(u8, p, "/.git")) return false;
    const parent = p[0 .. p.len - "/.git".len];
    return std.mem.eql(u8, std.mem.trimEnd(u8, parent, "/"), std.mem.trimEnd(u8, root, "/"));
}

/// The source path a string coercion copied to the store path `sp`.
pub fn copiedFrom(ev: *Evaluator, sp: []const u8) ?[]const u8 {
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    var it = ev.shared.hooks.src_to_store.iterator();
    while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, sp)) return e.key_ptr.*;
    return null;
}

/// Whether a pure evaluation may read `path` (eval.cc: rootFS is the store
/// behind an allow list): under a store path this evaluation made, or inside
/// this run's project. Always true when impure.
pub fn allowed(ev: *Evaluator, path: []const u8) bool {
    if (!ev.config.pure) return true;
    if (splitStorePath(path)) |s| if (knownGet(ev, s.base) != null or isOnDisk(ev, s.base)) return true;
    return inProject(ev, path);
}

/// A path that is simply on disk, such as a realised derivation output:
/// pure evaluation may read it (primops.cc:realiseContext's `allowPath`).
/// It has no origin, so no upload sends it.
pub fn addOnDisk(ev: *Evaluator, sp: *const StorePath) Error!void {
    const key = try ev.local.arena.allocator().dupe(u8, sp.baseName());
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    try ev.shared.hooks.on_disk.put(ev.gpa, key, {});
}

fn isOnDisk(ev: *Evaluator, base: []const u8) bool {
    ev.shared.hooks_lock.lockUncancelable(ev.io);
    defer ev.shared.hooks_lock.unlock(ev.io);
    return ev.shared.hooks.on_disk.contains(base);
}

fn inProject(ev: *Evaluator, path: []const u8) bool {
    var root = ev.config.project_root orelse return false;
    // a root of "/" becomes "", so that every absolute path is below it
    if (std.mem.endsWith(u8, root, "/")) root = root[0 .. root.len - 1];
    return std.mem.startsWith(u8, path, root) and (path.len == root.len or path[root.len] == '/');
}

/// The project root at or above `start` (`project.find`); null above
/// every marker.
pub fn findProjectRoot(io: Io, arena: std.mem.Allocator, start: []const u8) !?[]const u8 {
    _ = io;
    _ = arena;
    return @import("../project.zig").find(start);
}

/// Which components a resolution follows (source-accessor.hh:SymlinkResolution).
pub const Follow = enum {
    /// Every component but the last: `pathExists`.
    ancestors,
    /// Every component: `readFile`, `readDir`, `builtins.path`.
    full,
};

/// Mirrors source-accessor.cc:resolveSymlinks. A store path this evaluation
/// made holds no bytes, so the kernel would resolve a link below it against
/// the local tree it stands for. Walking the text of the path instead puts
/// every target where the store copy would. A link the filter hides, or one
/// a pure evaluation may not read, is left alone.
pub fn resolveLinks(ev: *Evaluator, path: []const u8, mode: Follow, pos: Pos) Error![]const u8 {
    const a = ev.local.arena.allocator();
    // components still to walk, the next one last
    var todo: std.ArrayList([]const u8) = .empty;
    defer todo.deinit(ev.gpa);
    try pushComponents(ev, &todo, path);
    var res: std.ArrayList(u8) = .empty;
    var hops: u32 = 0;
    while (todo.pop()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            res.shrinkRetainingCapacity(std.mem.lastIndexOfScalar(u8, res.items, '/') orelse 0);
            continue;
        }
        try res.append(a, '/');
        try res.appendSlice(a, c);
        if (mode == .ancestors and todo.items.len == 0) break;
        const target = (try (try resolve(ev, res.items)).readLink(ev)) orelse continue;
        if (!allowed(ev, res.items)) continue;
        hops += 1;
        if (hops > 1024)
            return ev.fail(.eval, pos, "infinite symlink recursion in path '{s}'", .{path});
        if (std.mem.startsWith(u8, target, "/")) {
            res.clearRetainingCapacity();
        } else {
            res.shrinkRetainingCapacity(std.mem.lastIndexOfScalar(u8, res.items, '/') orelse 0);
        }
        try pushComponents(ev, &todo, target);
    }
    if (res.items.len == 0) try res.append(a, '/');
    return res.items;
}

fn pushComponents(ev: *Evaluator, todo: *std.ArrayList([]const u8), p: []const u8) Error!void {
    const start = todo.items.len;
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |c| try todo.append(ev.gpa, c);
    std.mem.reverse([]const u8, todo.items[start..]);
}

pub const Located = struct { path: []const u8, at: ?SrcPath };

/// Where a read of `path` goes once the symlinks `mode` names are resolved:
/// the path resolution ended at, and its place in the (virtual) store, null
/// for one the real file system answers. The walk runs only under a store
/// path this evaluation copied from a local tree; elsewhere the kernel
/// resolves as the accessor would.
pub fn located(ev: *Evaluator, path: []const u8, mode: Follow, pos: Pos) Error!Located {
    const at = try locate(ev, path);
    if (at == null or at.?.src != .fs) return .{ .path = path, .at = at };
    const res = try resolveLinks(ev, path, mode, pos);
    if (std.mem.eql(u8, res, path)) return .{ .path = path, .at = at };
    return .{ .path = res, .at = try locate(ev, res) };
}

// The link check of pure evaluation.

/// `allowed` for the path a read of `path` reaches: a path in the project
/// by its text is followed through its links and `..` unless the kernel
/// shows it stays there. `at` is where `located` put it.
pub fn admits(ev: *Evaluator, at: ?SrcPath, path: []const u8, mode: Follow, pos: Pos) Error!bool {
    if (!allowed(ev, path)) return false;
    if (at != null or !ev.config.pure or !inProject(ev, path) or beneathProject(ev, path, mode == .full)) return true;
    return allowed(ev, try resolveLinks(ev, path, mode, pos));
}

/// Whether the kernel shows that `path`, in the project by its text,
/// resolves inside it too (`sys.fs.beneath`). A proof is kept, by path.
fn beneathProject(ev: *Evaluator, path: []const u8, follow: bool) bool {
    const root_in = ev.config.project_root orelse return false;
    const st = &ev.shared.hooks;
    {
        ev.shared.hooks_lock.lockUncancelable(ev.io);
        defer ev.shared.hooks_lock.unlock(ev.io);
        if (st.beneath.get(path)) |full| if (full or !follow) return true;
        if (st.project_fd == null) {
            const d = Io.Dir.cwd().openDir(ev.io, root_in, .{}) catch null;
            st.project_fd = if (d) |x| x.handle else -1;
        }
    }
    const fd = st.project_fd.?;
    if (fd < 0) return false;
    const root = if (std.mem.endsWith(u8, root_in, "/")) root_in[0 .. root_in.len - 1] else root_in;
    var rel = path[root.len..];
    if (std.mem.startsWith(u8, rel, "/")) rel = rel[1..];
    const found = @import("../sys/fs.zig").beneath(fd, rel, follow) orelse return false;
    // a missing entry may yet appear as a link
    if (found) {
        const key = ev.local.arena.allocator().dupe(u8, path) catch return true;
        ev.shared.hooks_lock.lockUncancelable(ev.io);
        defer ev.shared.hooks_lock.unlock(ev.io);
        st.beneath.put(ev.gpa, key, follow) catch {};
    }
    return true;
}

/// A located path behind the pure-eval allow list, with the error Nix's
/// `AllowListSourceAccessor` throws: what every read of a file goes through.
/// A file the working tree's SCM does not track is not refused here yet.
pub fn check(ev: *Evaluator, at: ?SrcPath, path: []const u8, pos: Pos) Error!SrcPath {
    if (try admits(ev, at, path, .full, pos)) {
        const sp = at orelse return .fs(path);
        if (try sp.hidden(ev)) try untracked(ev, sp, pos);
        return sp;
    }
    return ev.fail(.eval, pos, "access to absolute path '{s}' is forbidden in pure evaluation mode (use '--impure' to override)", .{path});
}

/// git.cc:makeNotAllowedError, in Nix's words: a path on disk that a
/// working tree leaves out because its SCM does not track it.
fn untracked(ev: *Evaluator, at: SrcPath, pos: Pos) Error!void {
    @branchHint(.cold);
    const scm = @import("../source/scm.zig");
    const root = switch (at.src) {
        .fs => |f| f.root,
        else => return,
    };
    const s = scm.at(ev.io, root) orelse return;
    const full = (try at.local(ev)) orelse return;
    _ = Io.Dir.cwd().statFile(ev.io, full, .{ .follow_symlinks = false }) catch return;
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const cx = @import("../source.zig").scmCx(ev, &d);
    const add = s.untracked(cx, root, at.rel) orelse return;
    const hint = try std.fmt.allocPrint(ev.local.arena.allocator(), "run '{s}'", .{add});
    return ev.failHint(.io, pos, hint, "Path '{s}' in the repository \"{s}\" is not tracked by {s}.\n\nTo make it visible to Nix, run:\n\n{s}", .{ at.rel, root, s.title, add });
}

/// `check` of `path` located afresh.
pub fn open(ev: *Evaluator, path: []const u8, pos: Pos) Error!SrcPath {
    return check(ev, try locate(ev, path), path, pos);
}

/// `SrcPath.stat` of `path`, `missing` for any error.
pub fn stat(ev: *Evaluator, path: []const u8, follow: bool) Error!Kind {
    const sp = try resolve(ev, path);
    return sp.stat(ev, follow) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.EvalFailed => error.EvalFailed,
        else => .missing,
    };
}

/// Copying a text held in memory again would need a store to put it in.
pub fn recopyUnsupported(ev: *Evaluator, path: []const u8, pos: Pos) Error {
    return ev.fail(.unsupported, pos, "copying '{s}' to the store again is not supported", .{path});
}

/// The filter of a copy: the tree's own. `saw_git` notes a `.git` entry
/// at the top of `root` the copy keeps, for `git-in-source`.
const TreeFilter = struct {
    sp: *const SrcPath,
    root: []const u8,
    saw_git: ?*bool,
    fp: ?*trace_mod.TreeFp = null,
    pub fn accept(f: TreeFilter, p: []const u8, t: FileType) error{}!bool {
        const keep = f.sp.accepts(p);
        if (f.fp) |x| x.entry(p, t, keep);
        if (keep) if (f.saw_git) |g| if (isGitEntry(f.root, p)) {
            g.* = true;
        };
        return keep;
    }
};

/// The store path a path value coerces to (`"${./foo}"`): the NAR of the
/// file or tree, added as Nix's `addToStore` would. Nothing is written; the
/// store path is remembered, so later reads below it read `path`.
pub fn copyPathToStore(ev: *Evaluator, path: []const u8, pos: Pos) Error![]const u8 {
    {
        ev.shared.hooks_lock.lockUncancelable(ev.io);
        defer ev.shared.hooks_lock.unlock(ev.io);
        if (ev.shared.hooks.src_to_store.get(path)) |sp| return sp;
    }
    const at = try open(ev, path, pos);
    var ebuf: [128]u8 = undefined;
    const base = std.fs.path.basename(path);
    const name = if (base.len == 0) "source" else base;
    const local = switch ((try at.at(ev)) orelse
        return ev.fail(.io, pos, "copying '{s}' to the store: {s}", .{ path, errors.osText(&ebuf, error.FileNotFound) })) {
        .mem => return recopyUnsupported(ev, path, pos),
        .tree => |x| {
            treestore.record(ev.trace(), x.t);
            const sp = try copyStoredTree(ev, at, name, path, pos);
            var pbuf: [512]u8 = undefined;
            const full = try ev.local.arena.allocator().dupe(u8, sp.print(&pbuf));
            const key = try ev.local.arena.allocator().dupe(u8, path);
            ev.shared.hooks_lock.lockUncancelable(ev.io);
            defer ev.shared.hooks_lock.unlock(ev.io);
            try ev.shared.hooks.src_to_store.put(ev.gpa, key, full);
            return full;
        },
        .disk => |p| p,
    };
    // a plain local directory, not a tree the flake machinery filtered
    if (ev.lintOn(.dir_copy_unfiltered) and at.src.fs.accepted == null and !ev.isStorePathText(path)) {
        if (ev.trace().statNow(local, true) == .directory) try purity.dirCopyUnfiltered(ev, path, pos);
    }
    var saw_git = false;
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    var fp = ev.trace().fp(local);
    const filter: TreeFilter = .{ .sp = &at, .root = local, .saw_git = if (ev.lintOn(.git_in_source)) &saw_git else null, .fp = if (fp) |*x| x else null };
    const nh = nar.narHashFiltered(ev.gpa, ev.io, Io.Dir.cwd(), local, .sha256, filter, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPath, error.ReadFailed => return ev.fail(.io, pos, "copying '{s}' to the store: {s}", .{ path, d.message() }),
        else => return ev.fail(.io, pos, "copying '{s}' to the store: {s}", .{ path, errors.osText(&ebuf, e) }),
    };
    ev.trace().tree(local, trace_mod.hashToDigest(&nh.hash), at.src.fs.accepted, if (fp) |*x| x else null);
    if (saw_git) try purity.gitInSource(ev, path, pos);
    try purity.largeSourceCopy(ev, path, nh.size, pos);
    const sp = store_path.makeFixedOutputPath(.recursive, nh.hash, name, &.{}, &d) catch
        return ev.fail(.eval, pos, "{s}", .{d.message()});
    var pbuf: [512]u8 = undefined;
    const a = ev.local.arena.allocator();
    const full = try a.dupe(u8, sp.print(&pbuf));
    {
        const key = try a.dupe(u8, path);
        ev.shared.hooks_lock.lockUncancelable(ev.io);
        defer ev.shared.hooks_lock.unlock(ev.io);
        try ev.shared.hooks.src_to_store.put(ev.gpa, key, full);
    }
    noteStoreAdd(ev, &sp, "tree", nh.size, at, pos);
    try addTree(ev, &sp, local, at.src.fs.accepted, true, nh);
    return full;
}

/// Names a store path this evaluation made on the event stream: what Nix
/// would `addToStore` or `addTextToStore`. `size` is the NAR size of a
/// tree, the byte count of a flat add or a text.
pub fn noteStoreAdd(ev: *Evaluator, sp: *const StorePath, kind: []const u8, size: u64, from: SrcPath, pos: Pos) void {
    ev.stats.store_adds += 1;
    const s = ev.config.session orelse return;
    var r = s.events.rec(.store, "store-add") orelse return;
    var pbuf: [512]u8 = undefined;
    _ = r.set("path", sp.print(&pbuf)).set("kind", kind).set("size", size);
    const at = r.start("from");
    switch (from.src) {
        .fs => |f| {
            r.raw(f.root);
            if (from.rel.len > 0) {
                r.raw("/");
                r.raw(from.rel);
            }
            if (f.accepted != null) r.raw(" (filtered)");
        },
        .tree => |x| {
            r.raw("input-store:");
            r.raw(x.t.name);
            if (from.rel.len > 0) {
                r.raw("/");
                r.raw(from.rel);
            }
            if (x.accepted != null) r.raw(" (filtered)");
        },
        .mem => r.raw("text"),
    }
    r.quote(at);
    var abuf: [std.fs.max_path_bytes + 64]u8 = undefined;
    _ = r.set("at", std.fmt.bufPrint(&abuf, "{f}", .{ev.files.at(pos)}) catch "«none»");
    r.end();
}

const testing = std.testing;

test "a copied tree's reads go to the local files" {
    var interner: @import("../syntax/symbol.zig").Interner = try .init(testing.allocator);
    defer interner.deinit();
    var files: @import("../eval/Files.zig") = .init(testing.allocator, testing.io);
    defer files.deinit();
    var shared: Evaluator.Shared = .{};
    defer shared.deinit(testing.allocator);
    var local: Evaluator.Local = .init(testing.allocator);
    defer local.deinit();
    var ev: Evaluator = try .init(testing.allocator, testing.io, &local, &interner, &files, &shared, .{});
    defer ev.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const sp: StorePath = try .parse("/nix/store/z4wkdlk69gck09s64a8ghpn6h7bxhkyy-source", &d);
    const accepted = try ev.local.arena.create(PathSet);
    accepted.* = .empty;
    for ([_][]const u8{ "/r/flake.nix", "/r/a", "/r/a/b.nix" }) |p| try accepted.put(ev.local.arena.allocator(), p, {});
    try addTree(&ev, &sp, "/r", accepted, false, null);
    const base = "/nix/store/z4wkdlk69gck09s64a8ghpn6h7bxhkyy-source";
    try testing.expectEqualStrings("/r", (try onDisk(&ev, base)).?);
    try testing.expectEqualStrings("/r/a/b.nix", (try onDisk(&ev, base ++ "/a/b.nix")).?);
    try testing.expect((try onDisk(&ev, base ++ "/untracked")) == null);
    const other = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-other/x";
    try testing.expectEqualStrings(other, (try onDisk(&ev, other)).?);
    try testing.expect((try locate(&ev, "/nix/store/not-a-store-path")) == null);
}

fn onDisk(ev: *Evaluator, p: []const u8) !?[]const u8 {
    const at = (try (try resolve(ev, p)).at(ev)) orelse return null;
    return at.disk;
}
