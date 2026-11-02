//! The local content-addressed tree store: where a fetched tree lives instead
//! of `/nix/store`.
//!
//! Two different things are called a store in iets. The remote store is a Nix
//! store reached over a protocol, with its trust model. This is the other one:
//! content we own on local disk, under `cachefs`'s rules — a version file, one
//! writer at a time, an atomic rename into place, a TTL sweep
//! (../iets/docs/explanation/caching.md) — like the IR cache.
//!
//! Put a tree in, get a store path. Read bytes back for evaluation. Stream a
//! NAR out for an upload. Nothing else.
//!
//! **The store is fixed-output only, and that is what makes it safe in user
//! space.** `put` takes the hash the caller already knows — a lock entry's
//! `narHash`, or the `sha256` of a `fetchurl` — and has no form without it, so
//! the content verifies itself: no signature, no trusted builder, no daemon.
//! An entry's name *is* its content address, which is why a reader never
//! re-hashes and why two processes can share one entry.
//!
//! A `github`/`gitlab`/`sourcehut`/`tarball` input is fetched as one
//! decompressed tar and indexed (`fetch/spool.zig`). `builtins.fetchurl`
//! downloads one file and stores it as a tree of one regular file. The store
//! keeps the index as `<cache root>/inputs/<store path base name>`, with every
//! file named by the blake3 of its bytes, and the bytes themselves in
//! `inputs/packs/` (`pack.zig`), where a file that two inputs share is stored
//! once. Evaluation reads the input straight out of the packs. The layout
//! began as Rust iets's and is this binary's own: its root is `iets-zig`,
//! never Rust's store.

pub const lz4 = @import("treestore/lz4.zig");
pub const pack = @import("treestore/pack.zig");

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Diag = @import("diag.zig").Diag;
const cachefs = @import("cachefs.zig");
const spool = @import("fetch/spool.zig");
const Tree = spool.Tree;
const Node = spool.Node;
const Blob = spool.Blob;
const hash_mod = @import("store/hash.zig");
const Hash = hash_mod.Hash;
const store_path = @import("store/path.zig");
const StorePath = store_path.StorePath;
const IngestionMethod = store_path.IngestionMethod;
const nar = @import("store/nar.zig");
const FileType = nar.FileType;

/// The store path a tree with this NAR hash has. The one naming site for a
/// tree the store holds: `fetchTree`, `fetchTarball` and a copied source all
/// ask here, so a stored entry's name and an evaluated store path cannot
/// disagree.
pub fn storePath(name: []const u8, nar_hash: Hash, d: *Diag) store_path.Error!StorePath {
    return store_path.makeFixedOutputPath(.recursive, nar_hash, name, &.{}, d);
}

/// The store path a flat file whose bytes hash to `hash` has: the naming site
/// for a `fetchurl` download, as `storePath` is for a tree.
pub fn filePath(name: []const u8, hash: Hash, d: *Diag) store_path.Error!StorePath {
    return store_path.makeFixedOutputPath(.flat, hash, name, &.{}, d);
}

/// One tree the store holds: its content, and the NAR hash and size that were
/// verified against the caller's expectation before it was named.
pub const StoredTree = struct {
    tree: Tree,
    nar_hash: Hash,
    nar_size: u64,
    /// The entry's name in the store, set once the store records it.
    name: []const u8 = "",
    /// Whether this run's read set already names the entry. One observation
    /// covers every read of it.
    recorded: std.atomic.Value(bool) = .init(false),

    pub fn deinit(t: *StoredTree) void {
        t.tree.deinit();
    }

    /// The type of the member at `rel` (`""` is the tree itself), with
    /// symlinks followed as the kernel follows them under `/nix/store`;
    /// `follow` is false for an `lstat`.
    pub fn stat(t: *const StoredTree, scratch: Allocator, rel: []const u8, follow: bool) Allocator.Error!?FileType {
        const n = (try t.tree.resolve(scratch, rel, follow)) orelse return null;
        return n.fileType();
    }

    /// The node at `rel`, symlinks followed unless `follow` is false.
    pub fn at(t: *const StoredTree, scratch: Allocator, rel: []const u8, follow: bool) Allocator.Error!?*const Node {
        return t.tree.resolve(scratch, rel, follow);
    }

    /// A directory's entries, in NAR order; `NotDir` for anything else.
    pub fn list(t: *const StoredTree, scratch: Allocator, rel: []const u8) (Allocator.Error || error{ NotDir, FileNotFound })![]const spool.Entry {
        const n = (try t.tree.resolve(scratch, rel, true)) orelse return error.FileNotFound;
        return switch (n.*) {
            .dir => |d| d,
            else => error.NotDir,
        };
    }

    /// A regular member's whole contents, from `a`; `IsDir` for a member that
    /// is not a regular file.
    pub fn read(t: *const StoredTree, a: Allocator, rel: []const u8) (pack.Error || error{ IsDir, FileNotFound })![]u8 {
        const n = (try t.tree.resolve(a, rel, true)) orelse return error.FileNotFound;
        return switch (n.*) {
            .file => |f| t.tree.read(a, f.at),
            else => error.IsDir,
        };
    }

    /// The NAR of the member at `rel`, with `filter` asked about every entry
    /// below it under the path Nix would show (`shown`), as `nar.dumpPath`
    /// asks. This is what an upload streams.
    pub fn dump(t: *const StoredTree, scratch: Allocator, rel: []const u8, shown: []const u8, w: *Io.Writer, filter: anytype, d: *Diag) !void {
        const n = (try t.tree.resolve(scratch, rel, true)) orelse return error.FileNotFound;
        return t.tree.dumpFiltered(n.*, shown, w, filter, d);
    }
};

/// The input store under the cache root `cache_root`, or null without one.
pub fn locate(a: Allocator, cache_root: ?[]const u8) Allocator.Error!?[]const u8 {
    const r = cache_root orelse return null;
    return try std.fs.path.join(a, &.{ r, "inputs" });
}

/// Why a tree was not stored. A mismatch carries the hash the content really
/// has, so the caller can say what it expected instead.
pub const Rejected = union(enum) {
    mismatch: Hash,
    /// The message is in the `Diag`.
    io,
    /// No cache directory, or the rename lost to something that is not a
    /// sibling's entry: the tree stays unstored, which costs a fetch on the
    /// next run and nothing else.
    unstorable,
};

/// A place to download into, under the store root. The staged directory is
/// named like a `cachefs` temporary, so a killed writer's leftovers are swept.
pub const Staged = struct {
    io: Io,
    gpa: Allocator,
    dir_path: []const u8,
    dir: Dir,

    pub fn deinit(s: *Staged) void {
        s.dir.close(s.io);
        Dir.cwd().deleteTree(s.io, s.dir_path) catch {};
        s.gpa.free(s.dir_path);
    }
};

/// The store of one run: where it lives, the trees it opened, and what
/// opening them cost. The caller owns it and the evaluator holds a pointer (`Evaluator.Config.inputs`).
pub const Store = struct {
    gpa: Allocator,
    io: Io,
    /// `<cache root>/inputs`; null when no home is known.
    root_path: ?[]const u8,
    /// Where `prepare` says why a directory is refused.
    stderr: ?*Io.Writer = null,
    lock: Io.Mutex = .init,
    state: enum { unknown, ready, unusable } = .unknown,
    packs: ?*pack.Packs = null,
    /// Trees opened, by store path base name. An entry is content-addressed,
    /// so one open serves every read of it; a stored null records a name the
    /// store does not hold, so a miss is asked once. A tree lives as long as
    /// the store: a reader may hold it.
    opened: std.StringHashMapUnmanaged(?*StoredTree) = .empty,
    retired: std.ArrayList(*StoredTree) = .empty,
    entries: std.atomic.Value(usize) = .init(0),
    nanos: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: Allocator, io: Io, root_path: ?[]const u8) Store {
        return .{ .gpa = gpa, .io = io, .root_path = root_path };
    }

    pub fn deinit(s: *Store) void {
        var it = s.opened.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |t| destroyTree(s.gpa, t);
        }
        s.opened.deinit(s.gpa);
        for (s.retired.items) |t| destroyTree(s.gpa, t);
        s.retired.deinit(s.gpa);
        if (s.packs) |p| p.deinit();
    }

    /// The store root, prepared on first use; null when unusable.
    pub fn root(s: *Store) ?[]const u8 {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        return s.rootLocked();
    }

    fn rootLocked(s: *Store) ?[]const u8 {
        const r = s.root_path orelse return null;
        switch (s.state) {
            .ready => return r,
            .unusable => return null,
            .unknown => {
                s.state = if (cachefs.entries.prepare(s.io, r, s.stderr)) .ready else .unusable;
                return if (s.state == .ready) r else null;
            },
        }
    }

    pub fn packsOf(s: *Store) ?*pack.Packs {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        if (s.packs) |p| return p;
        const r = s.rootLocked() orelse return null;
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&buf, "{s}/{s}", .{ r, pack.packs_dir }) catch return null;
        s.packs = pack.Packs.open(s.gpa, s.io, dir) catch return null;
        return s.packs;
    }

    /// What opening the trees of this run cost, for `--timings`: reading each
    /// index and decoding it is the one fixed cost the tree store adds to an
    /// evaluation that `/nix/store` does not pay.
    pub fn reportTimings(s: *Store, w: *Io.Writer) void {
        const n = s.entries.load(.monotonic);
        if (n > 0) w.print("inputs: {d} entries opened, {d:.3}s\n", .{ n, @as(f64, @floatFromInt(s.nanos.load(.monotonic))) / 1e9 }) catch {};
    }

    /// The tree named `name`, opened once per run.
    pub fn get(s: *Store, name: []const u8) ?*StoredTree {
        {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            if (s.opened.get(name)) |hit| return hit;
        }
        const t0 = Io.Clock.awake.now(s.io);
        const found: ?*StoredTree = blk: {
            const r = s.root() orelse break :blk null;
            const p = s.packsOf() orelse break :blk null;
            break :blk openEntry(s.gpa, s.io, r, p, name) catch null;
        };
        if (found != null) {
            _ = s.entries.fetchAdd(1, .monotonic);
            const dt = Io.Clock.awake.now(s.io).nanoseconds - t0.nanoseconds;
            _ = s.nanos.fetchAdd(@intCast(@max(dt, 0)), .monotonic);
        }
        return s.remember(name, found, false);
    }

    /// Records what `name` opened to: a tree replaces a recorded miss, and
    /// otherwise the first record wins unless `replace`.
    fn remember(s: *Store, name: []const u8, t: ?*StoredTree, replace: bool) ?*StoredTree {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const gop = s.opened.getOrPut(s.gpa, name) catch return t;
        if (!gop.found_existing) {
            gop.key_ptr.* = s.gpa.dupe(u8, name) catch {
                s.opened.removeByPtr(gop.key_ptr);
                return t;
            };
            gop.value_ptr.* = t;
            if (t) |x| x.name = gop.key_ptr.*;
            return t;
        }
        const old = gop.value_ptr.*;
        if (old == null or (replace and t != null)) {
            if (old) |o| s.retired.append(s.gpa, o) catch {};
            gop.value_ptr.* = t;
            if (t) |x| x.name = gop.key_ptr.*;
            return t;
        }
        if (t) |lost| destroyTree(s.gpa, lost);
        return old;
    }

    /// Whether the store holds `name`, for the tracing cache: an entry's
    /// presence is the whole observation, because its name is its content
    /// address.
    pub fn has(s: *Store, name: []const u8, version: u8) bool {
        if (version != spool.index_version) return false;
        const r = s.root() orelse return false;
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ r, name }) catch return false;
        const st = Dir.cwd().statFile(s.io, p, .{ .follow_symlinks = false }) catch return false;
        if (st.kind != .file) return false;
        // a tracing-cache hit reads nothing out of the entry, so this is the
        // only thing that keeps the TTL sweep from removing an input in use
        cachefs.entries.touch(s.io, p);
        return true;
    }

    pub fn stage(s: *Store, name: []const u8) ?Staged {
        const r = s.root() orelse return null;
        const p = std.fmt.allocPrint(s.gpa, "{s}/.{s}.{d}.{d}.tmp", .{ r, name, std.os.linux.getpid(), pack.tag() }) catch return null;
        Dir.cwd().deleteTree(s.io, p) catch {};
        cachefs.entries.createDir(s.io, p) catch {
            s.gpa.free(p);
            return null;
        };
        const d = Dir.cwd().openDir(s.io, p, .{}) catch {
            s.gpa.free(p);
            return null;
        };
        return .{ .io = s.io, .gpa = s.gpa, .dir_path = p, .dir = d };
    }

    /// One download per tree: every process that is about to fetch `name`
    /// takes this lock first, and one that had to wait finds the tree its
    /// sibling stored (`reopen`). The lock file is named like a temporary, so
    /// the sweep removes it once it is a day old and unused. `on_wait` has a
    /// `call` method.
    pub fn fetchLock(s: *Store, name: []const u8, on_wait: anytype) ?File {
        const r = s.root() orelse return null;
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/.{s}.fetching.tmp", .{ r, name }) catch return null;
        return cachefs.entries.waitLock(s.io, p, on_wait);
    }

    pub fn unlock(s: *Store, f: File) void {
        f.unlock(s.io);
        f.close(s.io);
    }

    /// `get`, past a miss this process recorded earlier.
    pub fn reopen(s: *Store, name: []const u8) ?*StoredTree {
        {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            if (s.opened.getEntry(name)) |e| if (e.value_ptr.* == null) {
                const k = e.key_ptr.*;
                s.opened.removeByPtr(e.key_ptr);
                s.gpa.free(k);
            };
        }
        return s.get(name);
    }

    /// Puts a tree in, under the store path `name`, `method` and `expect`
    /// name. `expect` is known before: a `narHash` (`recursive`) or the hash
    /// of the bytes of one file (`flat`, `fetchurl`). A tree that does not
    /// hash to it is refused, so an entry's name is its content address: the
    /// whole trust model. The pack, then the index, is renamed into place; a
    /// sibling first wins. Takes `staged` and `tree` whatever happens.
    pub fn put(s: *Store, name: []const u8, method: IngestionMethod, expect: Hash, staged: *Staged, tree: *Tree, why: *Rejected, d: *Diag) error{Rejected}!*StoredTree {
        defer staged.deinit();
        defer tree.deinit();
        const r = s.root() orelse {
            why.* = .unstorable;
            return error.Rejected;
        };
        const p = s.packsOf() orelse {
            why.* = .unstorable;
            return error.Rejected;
        };
        const got = try storeTree(s.gpa, s.io, r, p, name, method, expect, tree, why, d);
        cachefs.entries.maybeSweep(s.io, r, Sweeper{ .gpa = s.gpa, .io = s.io, .root = r });
        return s.remember(got.name.baseName(), got.tree, true).?;
    }

    /// Drops the objects no entry names any more (`collect`).
    pub fn collectGarbage(s: *Store, dry_run: bool) pack.Collected {
        const r = s.root() orelse return .{};
        return collect(s.gpa, s.io, r, dry_run);
    }
};

const Sweeper = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,

    pub fn call(c: Sweeper) void {
        _ = collect(c.gpa, c.io, c.root, false);
    }
};

fn destroyTree(gpa: Allocator, t: *StoredTree) void {
    t.deinit();
    gpa.destroy(t);
}

/// What the name of an entry holds: nothing this run can read now, something
/// that is no entry, or a tree whose nodes are in `arena`.
const ReadEntry = union(enum) { missing, bad, ok: struct { arena: std.heap.ArenaAllocator, dec: spool.Decoded } };

fn readEntry(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!ReadEntry {
    const f = switch (cachefs.entries.openEntry(io, path)) {
        .file => |f| f,
        .missing => return .missing,
        .foreign => return .bad,
    };
    defer f.file.close(io);
    const bytes = try gpa.alloc(u8, @intCast(f.size));
    defer gpa.free(bytes);
    const n = f.file.readPositionalAll(io, bytes, 0) catch return .bad;
    if (n != bytes.len) return .bad;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const dec = (spool.decodeIndex(arena.allocator(), bytes) catch |e| {
        arena.deinit();
        return e;
    }) orelse {
        arena.deinit();
        return .bad;
    };
    return .{ .ok = .{ .arena = arena, .dec = dec } };
}

/// The entry `name` of the store at `root`. One whose index does not decode
/// is wiped: the next evaluation fetches it again.
fn openEntry(gpa: Allocator, io: Io, root: []const u8, packs: *pack.Packs, name: []const u8) Allocator.Error!?*StoredTree {
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, name }) catch return null;
    switch (try readEntry(gpa, io, path)) {
        .missing => return null,
        .bad => {
            Dir.cwd().deleteFile(io, path) catch {};
            return null;
        },
        .ok => |ok| {
            cachefs.entries.touch(io, path);
            var arena = ok.arena;
            const t = gpa.create(StoredTree) catch |e| {
                arena.deinit();
                return e;
            };
            t.* = .{ .tree = Tree.stored(gpa, io, packs, arena, ok.dec.root), .nar_hash = ok.dec.nar_hash, .nar_size = ok.dec.nar_size };
            return t;
        },
    }
}

/// A new object for the pack: compressed already, read again as it goes in,
/// or left to the pack that holds it.
const Object = union(enum) { ready: pack.Prepared, stream, none };

const Made = struct { at: Blob, id: pack.Id, obj: Object };

/// The workers of a batch: each takes the next file of `order` until none
/// is left, so a big file does not hold up a share of small ones behind it.
const Batch = struct {
    tree: *const Tree,
    packs: *pack.Packs,
    gpa: Allocator,
    files: []const Blob,
    out: []Made,
    /// Indices into `files`, the biggest first: the last file taken is a
    /// small one, so the workers finish together.
    order: []const u32,
    next: std.atomic.Value(usize) = .init(0),
    err: std.atomic.Value(bool) = .init(false),
    first_err: ?anyerror = null,

    fn run(b: *Batch) void {
        var buf: [128 * 1024]u8 = undefined;
        while (!b.err.load(.monotonic)) {
            const i = b.next.fetchAdd(1, .monotonic);
            if (i >= b.order.len) return;
            const k = b.order[i];
            b.out[k] = b.make(b.files[k], &buf) catch |e| {
                if (!b.err.swap(true, .monotonic)) b.first_err = e;
                return;
            };
        }
    }

    fn make(b: *Batch, at: Blob, buf: []u8) !Made {
        if (at.size() >= pack.stream_min) {
            var br = try b.tree.blob(at, buf);
            defer br.deinit(b.gpa);
            var h: std.crypto.hash.Blake3 = .init(.{});
            var left = at.size();
            const r = br.reader();
            while (left > 0) {
                const got = r.peekGreedy(1) catch return error.ReadFailed;
                const n: usize = @intCast(@min(left, got.len));
                h.update(got[0..n]);
                r.toss(n);
                left -= n;
            }
            var id: pack.Id = undefined;
            h.final(&id);
            return .{ .at = at, .id = id, .obj = if (b.packs.contains(&id)) .none else .stream };
        }
        const bytes = try b.tree.read(b.gpa, at);
        const id = pack.idOf(bytes);
        if (b.packs.contains(&id)) {
            b.gpa.free(bytes);
            return .{ .at = at, .id = id, .obj = .none };
        }
        return .{ .at = at, .id = id, .obj = .{ .ready = try pack.prepare(b.gpa, bytes) } };
    }
};

/// Reads, hashes and, unless some pack already holds it, compresses every
/// distinct file of `tree` on several threads, a batch at a time so that one
/// batch bounds the memory, and appends the new ones to `writer` in the tree's
/// order. Gives each file's id, and the files left to the packs that hold them.
fn objects(gpa: Allocator, tree: *const Tree, packs: *pack.Packs, writer: *pack.PackWriter, ids: *std.AutoHashMapUnmanaged(Blob, pack.Id), elsewhere: *std.AutoArrayHashMapUnmanaged(pack.Id, Blob)) !void {
    const batch_bytes: u64 = 32 << 20;
    const max_threads = 8;
    const threads: usize = @max(1, @min(std.Thread.getCpuCount() catch 1, max_threads));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const files = try tree.files(arena.allocator());
    const made = try arena.allocator().alloc(Made, files.len);
    const order = try arena.allocator().alloc(u32, files.len);
    var start: usize = 0;
    while (start < files.len) {
        var end = start;
        var size: u64 = 0;
        while (end < files.len and (end == start or size < batch_bytes)) : (end += 1) size += files[end].size();
        const batch = files[start..end];
        const out = made[start..end];
        // a slot no worker reached holds nothing to free
        for (out, batch) |*m, at| m.* = .{ .at = at, .id = undefined, .obj = .none };
        const ord = order[0..batch.len];
        for (ord, 0..) |*o, k| o.* = @intCast(k);
        std.mem.sortUnstable(u32, ord, batch, struct {
            fn gt(fs: []const Blob, x: u32, y: u32) bool {
                return fs[x].size() > fs[y].size();
            }
        }.gt);
        var b: Batch = .{ .tree = tree, .packs = packs, .gpa = gpa, .files = batch, .out = out, .order = ord };
        var handles: [max_threads]?std.Thread = @splat(null);
        const helpers = @min(threads, batch.len) - 1;
        // this thread works too, and does the share of a helper that did
        // not start
        for (handles[0..helpers]) |*h| h.* = std.Thread.spawn(.{}, Batch.run, .{&b}) catch null;
        b.run();
        for (handles[0..helpers]) |h| if (h) |t| t.join();
        if (b.err.load(.monotonic)) {
            for (out) |m| if (m.obj == .ready) m.obj.ready.deinit(gpa);
            return b.first_err.?;
        }
        var buf: [128 * 1024]u8 = undefined;
        for (out, 0..) |m, k| {
            ids.put(gpa, m.at, m.id) catch |e| {
                for (out[k..]) |rest| if (rest.obj == .ready) rest.obj.ready.deinit(gpa);
                return e;
            };
            switch (m.obj) {
                .ready => |p| writer.addPrepared(m.id, p) catch |e| {
                    for (out[k + 1 ..]) |rest| if (rest.obj == .ready) rest.obj.ready.deinit(gpa);
                    return e;
                },
                .stream => {
                    var br = try tree.blob(m.at, &buf);
                    defer br.deinit(gpa);
                    try writer.addStream(m.id, br.reader(), m.at.size());
                },
                .none => {
                    const gop = try elsewhere.getOrPut(gpa, m.id);
                    if (!gop.found_existing) gop.value_ptr.* = m.at;
                },
            }
        }
        writer.startWriteback();
        start = end;
    }
}

const Hashed = struct { size: u64 = 0, nar: Hash = undefined, flat: ?Hash = null, err: ?anyerror = null, d: Diag };

fn hashTree(tree: *const Tree, method: IngestionMethod, flat_algo: hash_mod.Algo, nar_algo: hash_mod.Algo, out: *Hashed) void {
    hashTreeInner(tree, method, flat_algo, nar_algo, out) catch |e| {
        out.err = e;
    };
}

fn hashTreeInner(tree: *const Tree, method: IngestionMethod, flat_algo: hash_mod.Algo, nar_algo: hash_mod.Algo, out: *Hashed) !void {
    if (method == .flat) {
        out.flat = (try tree.fileHash(flat_algo)) orelse
            return out.d.fail(error.NotAFile, "a flat fixed output is one regular file", .{});
    }
    var h: hash_mod.Hasher = .init(nar_algo);
    var hb: [64 * 1024]u8 = undefined;
    var hw = h.writer(&hb);
    try tree.dump(&hw.interface, &out.d);
    out.size = h.count;
    out.nar = h.finish();
}

const Got = struct { name: StorePath, tree: *StoredTree };

fn ioFailed(why: *Rejected, d: *Diag, e: anyerror) error{Rejected} {
    why.* = .io;
    if (d.msg == null) d.fail(e, "{s}", .{spool.blobText(e)}) catch {};
    return error.Rejected;
}

/// `put` into the store at `root`: the name of the entry, and the tree read
/// back out of the packs.
fn storeTree(gpa: Allocator, io: Io, root: []const u8, packs: *pack.Packs, name: []const u8, method: IngestionMethod, expect: Hash, tree: *const Tree, why: *Rejected, d: *Diag) error{Rejected}!Got {
    d.deinit();
    // the index and an upload carry a sha256 NAR hash, whatever algorithm
    // names a flat file
    const nar_algo: hash_mod.Algo = switch (method) {
        .recursive => expect.algo,
        .flat => .sha256,
        else => {
            why.* = .unstorable;
            return error.Rejected;
        },
    };
    cachefs.entries.createDir(io, packs.dir_path) catch |e| return ioFailed(why, d, e);
    var pdir = Dir.cwd().openDir(io, packs.dir_path, .{}) catch |e| return ioFailed(why, d, e);
    defer pdir.close(io);
    const writer = pack.PackWriter.init(gpa, io, pdir) catch |e| return ioFailed(why, d, e);
    defer writer.deinit();
    // the objects go into a pack that is still a temporary, so they can be
    // made while the NAR is hashed: a mismatch drops the pack unnamed
    var hashed: Hashed = .{ .d = .init(gpa) };
    defer hashed.d.deinit();
    const hasher = std.Thread.spawn(.{}, hashTree, .{ tree, method, expect.algo, nar_algo, &hashed }) catch null;
    var ids: std.AutoHashMapUnmanaged(Blob, pack.Id) = .empty;
    defer ids.deinit(gpa);
    var elsewhere: std.AutoArrayHashMapUnmanaged(pack.Id, Blob) = .empty;
    defer elsewhere.deinit(gpa);
    const made = objects(gpa, tree, packs, writer, &ids, &elsewhere);
    if (hasher) |t| t.join() else hashTree(tree, method, expect.algo, nar_algo, &hashed);
    if (hashed.err) |e| {
        if (hashed.d.msg) |m| d.fail(e, "{s}", .{m}) catch {};
        return ioFailed(why, d, e);
    }
    const got = hashed.flat orelse hashed.nar;
    if (!got.eql(expect)) {
        why.* = .{ .mismatch = got };
        return error.Rejected;
    }
    made catch |e| return ioFailed(why, d, e);
    var nd: Diag = .init(gpa);
    defer nd.deinit();
    const sp = (if (method == .flat) filePath(name, got, &nd) else storePath(name, got, &nd)) catch {
        why.* = .unstorable;
        return error.Rejected;
    };
    var tree_arena: std.heap.ArenaAllocator = .init(gpa);
    var keep_arena = false;
    defer if (!keep_arena) tree_arena.deinit();
    const stored_root = tree.withIds(tree_arena.allocator(), &ids) catch |e| return ioFailed(why, d, e);
    const index = spool.encodeIndex(gpa, stored_root, hashed.nar, hashed.size) catch |e| return ioFailed(why, d, e);
    defer gpa.free(index);
    {
        // `collect` holds the lock for as long as a compaction takes, so this
        // waits rather than drop a whole download; under it, a pack this tree
        // relied on may have gone, and its objects come from the spool instead
        const l = cachefs.entries.storeLock(io, root) orelse {
            why.* = .unstorable;
            return error.Rejected;
        };
        defer {
            l.unlock(io);
            l.close(io);
        }
        const now = packs.refresh() catch |e| return ioFailed(why, d, e);
        var it = elsewhere.iterator();
        while (it.next()) |e| if (now.find(e.key_ptr) == null) {
            const bytes = tree.read(gpa, e.value_ptr.*) catch |err| return ioFailed(why, d, err);
            defer gpa.free(bytes);
            writer.add(e.key_ptr.*, bytes) catch |err| return ioFailed(why, d, err);
        };
        var nb: [37]u8 = undefined;
        _ = writer.finish(&nb) catch |e| return ioFailed(why, d, e);
        var rdir = Dir.cwd().openDir(io, root, .{}) catch |e| return ioFailed(why, d, e);
        defer rdir.close(io);
        if (rdir.access(io, sp.baseName(), .{})) |_| {} else |_| {
            cachefs.writeAtomic(io, rdir, sp.baseName(), &.{index}) catch |e| return ioFailed(why, d, e);
        }
    }
    _ = packs.refresh() catch |e| return ioFailed(why, d, e);
    const t = gpa.create(StoredTree) catch |e| return ioFailed(why, d, e);
    keep_arena = true;
    t.* = .{ .tree = Tree.stored(gpa, io, packs, tree_arena, stored_root), .nar_hash = hashed.nar, .nar_size = hashed.size };
    return .{ .name = sp, .tree = t };
}

/// Drops the objects no entry names any more: a pack none of them uses goes,
/// and one mostly unused is rewritten (`pack.collect`). An entry whose index
/// does not decode goes too. Runs under the store's lock, so no `put`
/// publishes an entry between the marking and the sweeping.
pub fn collect(gpa: Allocator, io: Io, root: []const u8, dry_run: bool) pack.Collected {
    const l = cachefs.entries.storeLock(io, root) orelse return .{};
    defer {
        l.unlock(io);
        l.close(io);
    }
    var live: std.AutoHashMapUnmanaged(pack.Id, void) = .empty;
    defer live.deinit(gpa);
    var dir = Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return .{};
    defer dir.close(io);
    var it = dir.iterate();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    while (it.next(io) catch return .{}) |e| {
        if (e.kind != .file or !cachefs.entries.isEntryKey(e.name)) continue;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, e.name }) catch continue;
        switch (readEntry(gpa, io, path) catch return .{}) {
            .ok => |ok| {
                var a = ok.arena;
                defer a.deinit();
                spool.objectIds(gpa, ok.dec.root, &live) catch return .{};
            },
            .bad => if (!dry_run) dir.deleteFile(io, e.name) catch {},
            // its objects are unknown, so no pack can be proved dead
            .missing => if (dir.access(io, e.name, .{})) |_| return .{} else |_| {},
        }
    }
    const pdir = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, pack.packs_dir }) catch return .{};
    return pack.collect(gpa, io, pdir, &live, dry_run) catch .{};
}

/// Puts the entry `tree` is in the read set, once per run. The entry's name
/// is the NAR hash of its tree, so its presence, plus the index version that
/// says the entry can still be read, is the whole check: there is nothing per
/// file to stat and nothing to rehash.
pub fn record(t: @import("trace.zig").Trace, tree: *StoredTree) void {
    if (t.isOn() and !tree.recorded.swap(true, .monotonic))
        t.record(.{ .input = .{ .entry = tree.name, .version = spool.index_version } });
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;
const tar = @import("fetch/tar.zig");

const TestStore = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    d: Diag,
    arena: std.heap.ArenaAllocator,

    fn init() !*TestStore {
        const s = try testing.allocator.create(TestStore);
        s.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .root = "", .d = .init(testing.allocator), .arena = .init(testing.allocator) };
        var buf: [Dir.max_path_bytes]u8 = undefined;
        s.root = try s.arena.allocator().dupe(u8, buf[0..try s.tmp.dir.realPath(testing.io, &buf)]);
        return s;
    }

    fn deinit(s: *TestStore) void {
        s.d.deinit();
        s.tmp.cleanup();
        s.arena.deinit();
        testing.allocator.destroy(s);
    }

    /// A spooled tarball holding `files` under one top-level directory, and
    /// its NAR hash.
    fn treeOf(s: *TestStore, files: []const [2][]const u8) !struct { Tree, Hash } {
        const a = s.arena.allocator();
        var ms: std.ArrayList(tar.TestMember) = .empty;
        for (files) |f| try ms.append(a, .{ .name = try std.fmt.allocPrint(a, "top/{s}", .{f[0]}), .t = tar.Type.regular, .data = f[1] });
        const bytes = try tar.testTar(a, ms.items);
        const f = try spool.scratch(testing.io, "test", &s.d);
        try f.writePositionalAll(testing.io, bytes, 0);
        var t = try Tree.index(testing.allocator, testing.io, f, std.math.maxInt(u64), &s.d);
        errdefer t.deinit();
        var h: hash_mod.Hasher = .init(.sha256);
        var hb: [4096]u8 = undefined;
        var hw = h.writer(&hb);
        try t.dump(&hw.interface, &s.d);
        return .{ t, h.finish() };
    }

    fn packsDir(s: *TestStore) ![]const u8 {
        return std.fmt.allocPrint(s.arena.allocator(), "{s}/packs", .{s.root});
    }

    fn put(s: *TestStore, packs: *pack.Packs, files: []const [2][]const u8) ![]const u8 {
        var t, const h = try s.treeOf(files);
        defer t.deinit();
        var why: Rejected = undefined;
        const got = try storeTree(testing.allocator, testing.io, s.root, packs, "source", .recursive, h, &t, &why, &s.d);
        destroyTree(testing.allocator, got.tree);
        return s.arena.allocator().dupe(u8, got.name.baseName());
    }

    fn read(s: *TestStore, name: []const u8, file: []const u8) ![]u8 {
        const packs = try pack.Packs.open(testing.allocator, testing.io, try s.packsDir());
        defer packs.deinit();
        const t = (try openEntry(testing.allocator, testing.io, s.root, packs, name)) orelse return error.FileNotFound;
        defer destroyTree(testing.allocator, t);
        return t.read(testing.allocator, file);
    }

    fn objectCount(s: *TestStore) !usize {
        const packs = try pack.Packs.open(testing.allocator, testing.io, try s.packsDir());
        defer packs.deinit();
        var n: usize = 0;
        for (packs.current.packs) |p| n += p.count();
        return n;
    }
};

test "the name an entry gets is the store path the lock's narHash implies" {
    const cases = [_][2][]const u8{
        .{ "sha256-9i/VTdusq/+NM/tz+J1Re+ojkMB8MBf0QshnYfzHz30=", "/nix/store/z4wkdlk69gck09s64a8ghpn6h7bxhkyy-source" },
        .{ "sha256-vlHUuqAcbcH2RKmHbPiuQzbv1pnzzavXnI62RD0bqCU=", "/nix/store/7j1q60m17gf95k3s0gk2qvjqygnp1q36-source" },
        .{ "sha256-Ft/BRnIqw1MywFoXydKobjjWmDFgDdYtSpJliE8+yUw=", "/nix/store/mkp6xi3vnvrllpmc17337m6sci9chm5l-source" },
        .{ "sha256-m0pDuRJG7EDo9ri+4Ksu83VsI+PlxNC9lNBfydejce4=", "/nix/store/aiapnjc6w07cz0jxy8s3j8cg1vfh1k8b-source" },
    };
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    for (cases) |c| {
        const h = try Hash.parseAny(c[0], null, &d);
        var buf: [512]u8 = undefined;
        try testing.expectEqualStrings(c[1], (try storePath("source", h, &d)).print(&buf));
    }
}

test "a stored input reads back, and a wrong hash is refused" {
    const s = try TestStore.init();
    defer s.deinit();
    const packs = try pack.Packs.open(testing.allocator, testing.io, try s.packsDir());
    defer packs.deinit();
    const name = try s.put(packs, &.{ .{ "a", "alpha" }, .{ "b", "beta" } });
    const a = try s.read(name, "a");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("alpha", a);
    const b = try s.read(name, "b");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("beta", b);

    var t, _ = try s.treeOf(&.{.{ "a", "alpha" }});
    defer t.deinit();
    var o, const other = try s.treeOf(&.{.{ "a", "other" }});
    o.deinit();
    var why: Rejected = undefined;
    try testing.expectError(error.Rejected, storeTree(testing.allocator, testing.io, s.root, packs, "source", .recursive, other, &t, &why, &s.d));
    try testing.expect(why == .mismatch);
}

test "two inputs share their common files" {
    const s = try TestStore.init();
    defer s.deinit();
    const packs = try pack.Packs.open(testing.allocator, testing.io, try s.packsDir());
    defer packs.deinit();
    const shared: [5000]u8 = @splat('s');
    const a = try s.put(packs, &.{ .{ "shared", &shared }, .{ "only-a", "a" } });
    const b = try s.put(packs, &.{ .{ "shared", &shared }, .{ "only-b", "b" } });
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqual(@as(usize, 3), try s.objectCount());
    const got = try s.read(b, "shared");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &shared, got);
}

test "collect keeps what an entry names, and an open tree stays readable" {
    const s = try TestStore.init();
    defer s.deinit();
    const packs = try pack.Packs.open(testing.allocator, testing.io, try s.packsDir());
    defer packs.deinit();
    const big: [50_000]u8 = @splat('x');
    const a = try s.put(packs, &.{ .{ "shared", "shared bytes" }, .{ "big", &big } });
    const b = try s.put(packs, &.{ .{ "shared", "shared bytes" }, .{ "small", "y" } });
    const early_packs = try pack.Packs.open(testing.allocator, testing.io, try s.packsDir());
    defer early_packs.deinit();
    const early = (try openEntry(testing.allocator, testing.io, s.root, early_packs, a)).?;
    defer destroyTree(testing.allocator, early);
    try s.tmp.dir.deleteFile(testing.io, a);
    const c = collect(testing.allocator, testing.io, s.root, false);
    try testing.expect(c.rewritten + c.removed >= 1);
    try testing.expectEqual(@as(usize, 2), try s.objectCount());
    const shared = try s.read(b, "shared");
    defer testing.allocator.free(shared);
    try testing.expectEqualStrings("shared bytes", shared);
    const got = try early.read(testing.allocator, "big");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &big, got);
}

test "a put after a collection brings its own objects" {
    const s = try TestStore.init();
    defer s.deinit();
    const shared: [5000]u8 = @splat('r');
    const stale = try pack.Packs.open(testing.allocator, testing.io, try s.packsDir());
    defer stale.deinit();
    const a = try s.put(stale, &.{.{ "shared", &shared }});
    try s.tmp.dir.deleteFile(testing.io, a);
    _ = collect(testing.allocator, testing.io, s.root, false);
    try testing.expectEqual(@as(usize, 0), try s.objectCount());
    // `stale` still lists the pack the collection removed
    const b = try s.put(stale, &.{ .{ "shared", &shared }, .{ "new", "n" } });
    const got = try s.read(b, "shared");
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &shared, got);
}

test "a flat file is named by the hash of its bytes" {
    const s = try TestStore.init();
    defer s.deinit();
    const io = testing.io;
    const hash = try Hash.parseAny("113a52l57f2jv9fh9igj2xh2mi0is40flxbkqi69wbh7nlybkcbm", .sha256, &s.d);
    const packs = try pack.Packs.open(testing.allocator, io, try s.packsDir());
    defer packs.deinit();
    const f = try spool.scratch(io, "test", &s.d);
    try f.writePositionalAll(io, "hello fetchurl\n", 0);
    var t = try Tree.file(testing.allocator, io, f, &s.d);
    defer t.deinit();
    var why: Rejected = undefined;
    const got = try storeTree(testing.allocator, io, s.root, packs, "hello.txt", .flat, hash, &t, &why, &s.d);
    defer destroyTree(testing.allocator, got.tree);
    try testing.expectEqualStrings("3ay25cl2lpykmx07i7m22qxz7zwzqmvy-hello.txt", got.name.baseName());
    const back = try s.read(got.name.baseName(), "");
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("hello fetchurl\n", back);
    try testing.expectEqual(FileType.regular, (try got.tree.stat(testing.allocator, "", true)).?);
    try testing.expect(got.tree.nar_hash.eql(nar.narHashOfString("hello fetchurl\n")));

    const g = try spool.scratch(io, "test", &s.d);
    try g.writePositionalAll(io, "other\n", 0);
    var other = try Tree.file(testing.allocator, io, g, &s.d);
    defer other.deinit();
    try testing.expectError(error.Rejected, storeTree(testing.allocator, io, s.root, packs, "hello.txt", .flat, hash, &other, &why, &s.d));
    try testing.expect(why.mismatch.eql(hash_mod.hashBytes(.sha256, "other\n")));
}

test "a store hands out a tree once and remembers a miss" {
    const s = try TestStore.init();
    defer s.deinit();
    const io = testing.io;
    var st: Store = .init(testing.allocator, io, try std.fmt.allocPrint(s.arena.allocator(), "{s}/inputs", .{s.root}));
    defer st.deinit();
    const name = "3ay25cl2lpykmx07i7m22qxz7zwzqmvy-hello.txt";
    try testing.expect(st.get(name) == null);
    var staged = st.stage(name).?;
    const f = try spool.spoolFile(io, staged.dir);
    try f.writePositionalAll(io, "hello fetchurl\n", 0);
    var t = try Tree.file(testing.allocator, io, f, &s.d);
    const hash = try Hash.parseAny("113a52l57f2jv9fh9igj2xh2mi0is40flxbkqi69wbh7nlybkcbm", .sha256, &s.d);
    var why: Rejected = undefined;
    const put = try st.put("hello.txt", .flat, hash, &staged, &t, &why, &s.d);
    try testing.expect(st.get(name).? == put);
    try testing.expect(st.has(name, spool.index_version));
    try testing.expect(!st.has(name, spool.index_version + 1));
}

// A tracing-cache hit reads nothing out of an input, so the validation of
// its `Input` observation is what keeps the sweep from removing it.
test "an input observation marks its entry as used" {
    const s = try TestStore.init();
    defer s.deinit();
    const io = testing.io;
    const root = try std.fmt.allocPrint(s.arena.allocator(), "{s}/inputs", .{s.root});
    var st: Store = .init(testing.allocator, io, root);
    defer st.deinit();
    _ = st.root().?;
    const name = "a3ck4d9zzk4l1r76rz5zv2wgycmpsy1y-source";
    const entry = try std.fmt.allocPrint(s.arena.allocator(), "{s}/{s}", .{ root, name });
    try Dir.cwd().writeFile(io, .{ .sub_path = entry, .data = "" });
    const old: Io.Timestamp = .fromNanoseconds(Io.Clock.real.now(io).nanoseconds - 40 * 24 * 3600 * std.time.ns_per_s);
    try Dir.cwd().setTimestamps(io, entry, .{ .modify_timestamp = .{ .new = old } });
    const trace = @import("trace.zig");
    var obs = [_]trace.Obs{.{ .input = .{ .entry = name, .version = spool.index_version } }};
    const Has = struct {
        fn has(ctx: *anyopaque, n: []const u8, v: u8) bool {
            const x: *Store = @ptrCast(@alignCast(ctx));
            return x.has(n, v);
        }
    };
    const env: trace.validate.Env = .{ .gpa = testing.allocator, .io = io, .inputs = .{ .ctx = &st, .has = Has.has } };
    try testing.expect(try trace.validate.validate(&env, &obs, 1) == .ok);
    try testing.expect((try Dir.cwd().statFile(io, entry, .{})).mtime.nanoseconds > old.nanoseconds);
}
