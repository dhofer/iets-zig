//! The NAR of a downloaded archive, without unpacking it.
//!
//! A tar is in archive order; a NAR needs every directory's entries sorted by
//! name and nested inside it. `unpack.zig` gets there by writing a tree and
//! walking it, which costs a second copy of every byte on disk. This module
//! spools the decompressed archive into one file as it arrives, reads it once
//! to record where each member's bytes are, and then writes the NAR out of
//! that index, driving `nar.Writer` from it and reading the bytes back by
//! offset. Peak memory is the index plus one copy buffer; nothing holds a
//! member whole.
//!
//! The rules are `unpack.zig`'s, which are tarfile.cc's and
//! git-utils.cc:GitFileSystemObjectSinkImpl's. `spool matches the tree` in the
//! tests holds the two walks — the index and the unpacked tree — to the same
//! NAR bytes.
//!
//! The same index also answers evaluation. The input store (`treestore.zig`)
//! keeps it, with every file named by the id of its bytes in the store's packs
//! instead of by an offset in the spool, and every read of a fetched input
//! comes back out of those packs instead of out of `/nix/store`.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const nar = @import("../store/nar.zig");
const FileType = nar.FileType;
const tar = @import("tar.zig");
const unpack = @import("unpack.zig");
const pack = @import("../treestore/pack.zig");
const Id = pack.Id;

/// Bytes moved per read when a member is copied out of the spool.
const chunk = 128 * 1024;

/// Where a file's bytes are: in the spooled archive, in the side file that
/// holds the expanded GNU sparse members, or, once the tree is stored, in the
/// input store's packs under the id of the bytes.
pub const Blob = union(enum) {
    spool: struct { offset: u64, size: u64, sparse: bool },
    object: struct { id: Id, size: u64 },

    pub fn size(b: Blob) u64 {
        return switch (b) {
            inline else => |x| x.size,
        };
    }
};

/// One directory entry. A directory's entries are a sorted slice, not a map:
/// a full nixpkgs holds 38 000 directories of two or three entries each.
pub const Entry = struct { name: []const u8, node: Node };

pub const Node = union(enum) {
    dir: []const Entry,
    file: struct { at: Blob, exec: bool },
    symlink: []const u8,

    pub fn fileType(n: Node) FileType {
        return switch (n) {
            .dir => .directory,
            .file => .regular,
            .symlink => .symlink,
        };
    }
};

pub const Source = union(enum) {
    /// `map` is the spool mapped once it is written whole: the index and
    /// every pass over the members read it with no system call per member,
    /// where a `pread` each cost 1.7 µs, as much as hashing the bytes.
    spool: struct { spool: File, sparse: ?File, map: ?[]align(std.heap.page_size_min) const u8 = null },
    packs: *pack.Packs,
};

/// `f`, `len` bytes long, mapped read-only; null when it cannot be, and the
/// file is then read by offset.
fn mapSpool(f: File, len: u64) ?[]align(std.heap.page_size_min) const u8 {
    if (len == 0 or len > std.math.maxInt(usize)) return null;
    const m = std.posix.mmap(null, @intCast(len), .{ .READ = true }, .{ .TYPE = .SHARED }, f.handle, 0) catch return null;
    // the index reads it front to back, and the passes after it in tree order
    _ = std.posix.madvise(m.ptr, m.len, std.posix.MADV.WILLNEED) catch {};
    return m;
}

/// Version byte of the serialized index. A file that starts with anything else
/// is not read; the entry holding it is wiped (`treestore.zig`).
pub const index_version: u8 = 3;

/// Bytes of the checksum the index ends with.
const sum_len = 8;

/// The index's own checksum. It catches a changed byte before anything reads
/// what the index says, so no reader ever has to trust the file's shape.
fn checksum(body: []const u8) [sum_len]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(body, &h, .{});
    return h[0..sum_len].*;
}

pub const Error = error{ BadArchive, ReadFailed, WriteFailed, ScratchFailed } || Allocator.Error;

/// `/`-joined components, for messages.
fn show(a: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(a, "/", parts);
}

/// A file in TMPDIR, unlinked as soon as it is open: the bytes live exactly as
/// long as the handle, whatever happens to the process. The name is random and
/// the open is exclusive, so a name another user can guess cannot make this
/// truncate and write a file of theirs.
pub fn scratch(io: Io, tag: []const u8, d: *Diag) error{ScratchFailed}!File {
    const tmp = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");
    var buf: [Dir.max_path_bytes]u8 = undefined;
    var last: File.OpenError = error.PathAlreadyExists;
    var path: []const u8 = "";
    for (0..8) |_| {
        var r: [8]u8 = undefined;
        io.random(&r);
        path = std.fmt.bufPrint(&buf, "{s}/iets-spool-{s}-{x:0>16}", .{ tmp, tag, std.mem.readInt(u64, &r, .little) }) catch
            return d.fail(error.ScratchFailed, "cannot create a spool file in {s}", .{tmp});
        const f = Dir.cwd().createFile(io, path, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |e| switch (e) {
            error.PathAlreadyExists => {
                last = e;
                continue;
            },
            else => return d.fail(error.ScratchFailed, "cannot create {s}: {t}", .{ path, e }),
        };
        Dir.cwd().deleteFile(io, path) catch |e| {
            f.close(io);
            return d.fail(error.ScratchFailed, "cannot unlink {s}: {t}", .{ path, e });
        };
        return f;
    }
    return d.fail(error.ScratchFailed, "cannot create {s}: {t}", .{ path, last });
}

/// The file the download is spooled into, in a staged directory of the store.
pub const spool_name = "spool";

/// The spool of a staged download, created for writing and read back to store it.
pub fn spoolFile(io: Io, dir: Dir) File.OpenError!File {
    return dir.createFile(io, spool_name, .{ .read = true, .truncate = true });
}

/// A member path split into components, `..` applied (`unpack.memberPath`).
fn partsOf(a: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try unpack.memberParts(a, name, &parts);
    return parts.items;
}

/// A directory while the archive is indexed: a member may come in any
/// order, so its entries are a map until `finish`.
const Draft = union(enum) {
    dir: *DraftDir,
    leaf: Node,
};
const DraftDir = std.StringHashMapUnmanaged(Draft);

/// The last copy of a member wins (git-utils.cc:1213), except that a directory
/// listed again keeps what is already under it. `replace` is false for a hard
/// link, which carries no `id` and so never takes a name a member claimed.
fn put(a: Allocator, d: *DraftDir, name: []const u8, node: Draft, replace: bool) Allocator.Error!void {
    const gop = try d.getOrPut(a, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = node;
        return;
    }
    if (replace and !(node == .dir and gop.value_ptr.* == .dir)) gop.value_ptr.* = node;
}

fn newDir(a: Allocator) Allocator.Error!*DraftDir {
    const d = try a.create(DraftDir);
    d.* = .empty;
    return d;
}

/// Puts `node` at `parts`, with the missing parents created. A parent that is
/// not a directory is replaced, a symlink included, as `unpack` replaces it
/// (git-utils.cc:addNode emplaces a directory at every parent name).
fn insert(a: Allocator, root: *DraftDir, parts: []const []const u8, node: Draft, replace: bool) Allocator.Error!void {
    var at = root;
    for (parts[0 .. parts.len - 1]) |p| {
        const gop = try at.getOrPut(a, p);
        if (!gop.found_existing or gop.value_ptr.* != .dir) gop.value_ptr.* = .{ .dir = try newDir(a) };
        at = gop.value_ptr.dir;
    }
    try put(a, at, parts[parts.len - 1], node, replace);
}

fn lookup(root: *const DraftDir, parts: []const []const u8) ?Draft {
    if (parts.len == 0) return null;
    var at = root;
    for (parts[0 .. parts.len - 1]) |p| switch (at.get(p) orelse return null) {
        .dir => |d| at = d,
        .leaf => return null,
    };
    return at.get(parts[parts.len - 1]);
}

/// The draft as sorted entries, in `a`.
fn finish(a: Allocator, d: *const DraftDir) Allocator.Error![]const Entry {
    const out = try a.alloc(Entry, d.count());
    var it = d.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        out[i] = .{ .name = e.key_ptr.*, .node = switch (e.value_ptr.*) {
            .dir => |sub| .{ .dir = try finish(a, sub) },
            .leaf => |n| n,
        } };
    }
    sortEntries(out);
    return out;
}

fn sortEntries(es: []Entry) void {
    std.mem.sortUnstable(Entry, es, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
}

/// git-utils.cc:dereferenceSingletonDirectory: one entry, and a directory.
fn dereference(root: []const Entry) []const Entry {
    if (root.len == 1 and root[0].node == .dir) return root[0].node.dir;
    return root;
}

/// Finds `name` among sorted entries.
fn find(d: []const Entry, name: []const u8) ?*const Entry {
    var lo: usize = 0;
    var hi = d.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, d[mid].name, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return &d[mid],
        }
    }
    return null;
}

/// An index of members, and where their bytes are.
pub const Tree = struct {
    gpa: Allocator,
    io: Io,
    /// Holds the nodes and their names.
    arena: std.heap.ArenaAllocator,
    src: Source,
    root: Node,

    /// Closes the spool files, if any: the packs are the store's.
    pub fn deinit(t: *Tree) void {
        switch (t.src) {
            .spool => |s| {
                if (s.map) |m| std.posix.munmap(m);
                s.spool.close(t.io);
                if (s.sparse) |f| f.close(t.io);
            },
            .packs => {},
        }
        t.arena.deinit();
    }

    /// Indexes the decompressed tar in `spool`, which is read from the start and
    /// kept for `dump`; the tree owns it from here, whatever happens. `max_size`
    /// is `fetch-max-size`: the spool and everything a sparse member expands to
    /// must fit in it together.
    pub fn index(gpa: Allocator, io: Io, spool: File, max_size: u64, d: *Diag) Error!Tree {
        var t: Tree = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .src = .{ .spool = .{ .spool = spool, .sparse = null } }, .root = undefined };
        errdefer t.deinit();
        const a = t.arena.allocator();
        // the drafts and the per-member scratch go when the index is built
        var draft_arena: std.heap.ArenaAllocator = .init(gpa);
        defer draft_arena.deinit();
        const da = draft_arena.allocator();
        var member_arena: std.heap.ArenaAllocator = .init(gpa);
        defer member_arena.deinit();

        const spool_len = (spool.stat(io) catch |e| return d.fail(error.ReadFailed, "cannot read the spooled tarball: {t}", .{e})).size;
        t.src.spool.map = mapSpool(spool, spool_len);
        var room = max_size -| spool_len;
        const root = try newDir(da);
        var links: std.StringHashMapUnmanaged(struct { parts: []const []const u8, target: []const []const u8 }) = .empty;
        var sparse_at: u64 = 0;
        var ar: tar.Archive = .{ .src = if (t.src.spool.map) |m| .{ .bytes = m } else .{ .file = .{ .io = io, .file = spool } } };
        var td: Diag = .init(gpa);
        defer td.deinit();
        while (true) {
            _ = member_arena.reset(.retain_capacity);
            const ma = member_arena.allocator();
            var e = (ar.next(ma, &td) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return d.fail(error.BadArchive, "cannot read the tarball: {s}", .{td.message()}),
            }) orelse break;
            // libarchive reads the pax global header as archive metadata, not
            // as a member; GitHub's tarballs start with one.
            if (e.typeflag == tar.Type.pax_global) continue;
            const pax = try paxSparse(ma, &ar, &e, d);
            const name = if (pax) |s| s.name orelse try e.path(ma) else try e.path(ma);
            const parts = try partsOf(a, name);
            if (parts.len == 0) continue;
            if (parts.len > nar.max_depth)
                return d.fail(error.BadArchive, "tarball member '{s}' is nested deeper than {d} directories", .{ name, nar.max_depth });
            switch (e.typeflag) {
                tar.Type.char, tar.Type.block_dev, tar.Type.fifo => return d.fail(error.BadArchive, "file '{s}' in tarball has unsupported file type {s}", .{ name, tar.Type.debugName(e.typeflag) }),
                tar.Type.directory => try insert(da, root, parts, .{ .dir = try newDir(da) }, true),
                tar.Type.symlink => {
                    const target = try linkTarget(a, &e, parts, "symlink", d);
                    try insert(da, root, parts, .{ .leaf = .{ .symlink = target } }, true);
                },
                tar.Type.link => {
                    const target = try linkTarget(ma, &e, parts, "link", d);
                    const key = try std.mem.join(da, "\x00", parts);
                    try links.put(da, key, .{ .parts = parts, .target = try partsOf(a, target) });
                },
                else => {
                    // libarchive gives every other type flag AE_IFREG (tarfile.cc:224)
                    const exec = (e.mode() orelse 0o644) & 0o100 != 0;
                    // A sparse member's holes are not in the archive, so it is
                    // the one member whose bytes must be written out to be
                    // indexed, and the one whose size the spool does not bound.
                    const expanded: ?u64 = if (pax) |s| s.size else if (e.typeflag == tar.Type.gnu_sparse) e.size else null;
                    const at: Blob = if (expanded) |size| blk: {
                        if (size > room) return d.fail(error.BadArchive, "the tarball expands to over the fetch-max-size of {d} bytes", .{max_size});
                        room -= size;
                        const side = t.src.spool.sparse orelse s: {
                            t.src.spool.sparse = try scratch(io, "sparse", d);
                            break :s t.src.spool.sparse.?;
                        };
                        expand(ma, io, &ar, &e, pax, side, sparse_at, size) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return d.fail(error.ReadFailed, "cannot read '{s}' from the tarball: {s}", .{ try show(ma, parts), expandText(err) }),
                        };
                        const b: Blob = .{ .spool = .{ .offset = sparse_at, .size = size, .sparse = true } };
                        sparse_at += size;
                        break :blk b;
                    } else .{ .spool = .{ .offset = e.file_pos, .size = e.size, .sparse = false } };
                    try insert(da, root, parts, .{ .leaf = .{ .file = .{ .at = at, .exec = exec } } }, true);
                },
            }
        }
        // git-utils.cc:1352: the links are resolved last, in the order of their
        // own names, and each one only takes a name no member claimed. So a
        // link may name a link whose own name sorts before it.
        const keys = try da.alloc([]const u8, links.count());
        {
            var it = links.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) keys[i] = k.*;
        }
        std.mem.sortUnstable([]const u8, keys, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (keys) |k| {
            const l = links.get(k).?;
            const linked: Node = switch (lookup(root, l.target) orelse
                return d.fail(error.BadArchive, "tarball member '{s}' is a hard link to '{s}', which the archive does not hold", .{ try show(da, l.parts), try show(da, l.target) })) {
                .leaf => |n| n,
                .dir => return d.fail(error.BadArchive, "tarball member '{s}' is a hard link to the directory '{s}'", .{ try show(da, l.parts), try show(da, l.target) }),
            };
            if (lookup(root, l.parts) != null) continue;
            // each alias is read and hashed again, or holds its own copy of
            // a symlink target, so it costs that size
            const cost: u64 = switch (linked) {
                .file => |f| f.at.size(),
                .symlink => |s| s.len,
                .dir => 0,
            };
            if (cost > room) return d.fail(error.BadArchive, "the tarball expands to over the fetch-max-size of {d} bytes", .{max_size});
            room -= cost;
            try insert(da, root, l.parts, .{ .leaf = linked }, false);
        }
        t.root = .{ .dir = dereference(try finish(a, root)) };
        return t;
    }

    /// The spool as one regular file, not executable: what `builtins.fetchurl`
    /// downloads (tarball.cc:downloadFile). The tree owns `spool`.
    pub fn file(gpa: Allocator, io: Io, spool: File, d: *Diag) Error!Tree {
        const size = (spool.stat(io) catch |e| {
            spool.close(io);
            return d.fail(error.ReadFailed, "cannot read the spooled download: {t}", .{e});
        }).size;
        return .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .src = .{ .spool = .{ .spool = spool, .sparse = null } },
            .root = .{ .file = .{ .at = .{ .spool = .{ .offset = 0, .size = size, .sparse = false } }, .exec = false } },
        };
    }

    /// A tree whose files' bytes are in `spool` where `root` says; `arena`
    /// holds `root` and is the tree's from here.
    pub fn spooled(gpa: Allocator, io: Io, spool: File, arena: std.heap.ArenaAllocator, root: Node) Tree {
        return .{ .gpa = gpa, .io = io, .arena = arena, .src = .{ .spool = .{ .spool = spool, .sparse = null } }, .root = root };
    }

    /// A tree whose files are objects in `packs`; `arena` holds `root`.
    pub fn stored(gpa: Allocator, io: Io, packs: *pack.Packs, arena: std.heap.ArenaAllocator, root: Node) Tree {
        return .{ .gpa = gpa, .io = io, .arena = arena, .src = .{ .packs = packs }, .root = root };
    }

    /// The `algo` hash of the bytes of a tree that is one regular file, which
    /// is what names it as a flat fixed output. Null for any other tree.
    pub fn fileHash(t: *const Tree, algo: hash_mod.Algo) !?Hash {
        const f = switch (t.root) {
            .file => |f| f,
            else => return null,
        };
        var h: hash_mod.Hasher = .init(algo);
        var hbuf: [256]u8 = undefined;
        var hw = h.writer(&hbuf);
        var rbuf: [chunk]u8 = undefined;
        var br = try t.blob(f.at, &rbuf);
        defer br.deinit(t.gpa);
        br.reader().streamExact64(&hw.interface, f.at.size()) catch |e| switch (e) {
            error.EndOfStream => return error.ReadFailed,
            else => |x| return x,
        };
        try hw.interface.flush();
        return h.finish();
    }

    /// Every file's blob, once: a hard link shares its target's. In `a`.
    pub fn files(t: *const Tree, a: Allocator) Allocator.Error![]Blob {
        var seen: std.AutoHashMapUnmanaged(Blob, void) = .empty;
        defer seen.deinit(t.gpa);
        var out: std.ArrayList(Blob) = .empty;
        try walkFiles(t.gpa, a, t.root, &seen, &out);
        return out.items;
    }

    fn walkFiles(gpa: Allocator, a: Allocator, n: Node, seen: *std.AutoHashMapUnmanaged(Blob, void), out: *std.ArrayList(Blob)) Allocator.Error!void {
        switch (n) {
            .file => |f| if (!(try seen.getOrPut(gpa, f.at)).found_existing) try out.append(a, f.at),
            .dir => |d| for (d) |e| try walkFiles(gpa, a, e.node, seen, out),
            .symlink => {},
        }
    }

    /// The same tree with every file named by the id of its bytes, which `ids`
    /// holds for every blob `files` gave; in `a`.
    pub fn withIds(t: *const Tree, a: Allocator, ids: *const std.AutoHashMapUnmanaged(Blob, Id)) Allocator.Error!Node {
        return mapIds(a, t.root, ids);
    }

    fn mapIds(a: Allocator, n: Node, ids: *const std.AutoHashMapUnmanaged(Blob, Id)) Allocator.Error!Node {
        return switch (n) {
            .file => |f| .{ .file = .{ .at = .{ .object = .{ .id = ids.get(f.at).?, .size = f.at.size() } }, .exec = f.exec } },
            .symlink => |s| .{ .symlink = try a.dupe(u8, s) },
            .dir => |d| blk: {
                const out = try a.alloc(Entry, d.len);
                for (d, out) |e, *o| o.* = .{ .name = try a.dupe(u8, e.name), .node = try mapIds(a, e.node, ids) };
                break :blk .{ .dir = out };
            },
        };
    }

    /// A spool member's bytes in the mapping, when the spool is mapped.
    fn mapped(t: *const Tree, s: @FieldType(Blob, "spool")) ?[]const u8 {
        if (s.sparse) return null;
        const m = t.src.spool.map orelse return null;
        if (s.offset > m.len or s.size > m.len - s.offset) return null;
        return m[@intCast(s.offset)..][0..@intCast(s.size)];
    }

    fn spoolSource(t: *const Tree, sparse: bool) File {
        const s = t.src.spool;
        return if (sparse) s.sparse.? else s.spool;
    }

    /// A member's bytes as a reader through `buf`, for the NAR writer to pull
    /// from. A spool member is read a buffer at a time, by offset, so two
    /// threads may read one tree at once; an object is one payload, so it is
    /// read whole.
    pub fn blob(t: *const Tree, at: Blob, buf: []u8) pack.Error!BlobReader {
        switch (at) {
            .spool => |s| {
                if (t.mapped(s)) |m| return .{ .mapped = .fixed(m) };
                var fr = File.Reader.initSize(t.spoolSource(s.sparse), t.io, buf, null);
                fr.seekTo(s.offset) catch return error.ReadFailed;
                return .{ .file = fr };
            },
            .object => |o| {
                const bytes = try t.object(t.gpa, o.id, o.size);
                return .{ .bytes = .{ .data = bytes, .r = .fixed(bytes) } };
            },
        }
    }

    fn object(t: *const Tree, a: Allocator, id: Id, size: u64) pack.Error![]u8 {
        const bytes = try t.src.packs.read(a, &id);
        if (bytes.len != size) {
            a.free(bytes);
            return error.Corrupt;
        }
        return bytes;
    }

    /// The member at the resolved components `at`, without following a symlink.
    fn nodeAt(t: *const Tree, at: []const []const u8) ?*const Node {
        var n: *const Node = &t.root;
        for (at) |name| {
            const d = switch (n.*) {
                .dir => |d| d,
                else => return null,
            };
            n = &(find(d, name) orelse return null).node;
        }
        return n;
    }

    /// The member at `rel` (`""` is the tree itself), with symlinks followed
    /// the way the kernel follows them for a path under `/nix/store`;
    /// `follow_last` is false for an `lstat`. A target that leaves the tree is
    /// not resolved: the spool holds no bytes for it.
    pub fn resolve(t: *const Tree, scratch_a: Allocator, rel: []const u8, follow_last: bool) Allocator.Error!?*const Node {
        var todo: std.ArrayList([]const u8) = .empty;
        defer todo.deinit(scratch_a);
        var at: std.ArrayList([]const u8) = .empty;
        defer at.deinit(scratch_a);
        try pushParts(scratch_a, &todo, rel);
        var hops: usize = 0;
        while (todo.pop()) |c| {
            if (std.mem.eql(u8, c, "..")) {
                if (at.pop() == null) return null;
                continue;
            }
            try at.append(scratch_a, c);
            const n = t.nodeAt(at.items) orelse continue;
            if (n.* != .symlink) continue;
            if (todo.items.len == 0 and !follow_last) break;
            hops += 1;
            if (hops > 32 or std.mem.startsWith(u8, n.symlink, "/")) return null;
            _ = at.pop();
            try pushParts(scratch_a, &todo, n.symlink);
        }
        return t.nodeAt(at.items);
    }

    fn pushParts(a: Allocator, todo: *std.ArrayList([]const u8), p: []const u8) Allocator.Error!void {
        const start = todo.items.len;
        var it = std.mem.tokenizeScalar(u8, p, '/');
        while (it.next()) |c| if (!std.mem.eql(u8, c, ".")) try todo.append(a, c);
        std.mem.reverse([]const u8, todo.items[start..]);
    }

    /// A regular member's whole contents, in one read into one buffer from
    /// `a`: no `open`, no copy through a staging buffer, so a read of a member
    /// costs less than a read of the same file under `/nix/store`.
    pub fn read(t: *const Tree, a: Allocator, at: Blob) pack.Error![]u8 {
        switch (at) {
            .object => |o| return t.object(a, o.id, o.size),
            .spool => |s| {
                const out = try a.alloc(u8, @intCast(s.size));
                if (t.mapped(s)) |m| {
                    @memcpy(out, m);
                    return out;
                }
                const n = t.spoolSource(s.sparse).readPositionalAll(t.io, out, s.offset) catch {
                    a.free(out);
                    return error.ReadFailed;
                };
                if (n != out.len) {
                    a.free(out);
                    return error.ReadFailed;
                }
                return out;
            },
        }
    }

    /// The NAR of the whole tree. No filter runs, so the walk builds no
    /// shown paths.
    pub fn dump(t: *const Tree, w: *Io.Writer, d: *Diag) DumpError!void {
        return t.write(t.root, null, w, nar.keep_all, d);
    }

    /// The NAR of `node`, with `filter` asked about every entry below it under
    /// the path Nix would show (`shown`), as `nar.dumpPath` asks.
    pub fn dumpFiltered(t: *const Tree, at: Node, shown: []const u8, w: *Io.Writer, filter: anytype, d: *Diag) !void {
        return t.write(at, shown, w, filter, d);
    }

    fn write(t: *const Tree, top: Node, shown: ?[]const u8, w: *Io.Writer, filter: anytype, d: *Diag) !void {
        const n: nar.Writer = .{ .w = w };
        const buf = try t.gpa.alloc(u8, chunk);
        defer t.gpa.free(buf);
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(t.gpa);
        if (shown) |s| try path.appendSlice(t.gpa, s);
        try n.header();
        try t.writeNode(top, if (shown != null) &path else null, n, filter, buf, 0, d);
        try w.flush();
    }

    pub const DumpError = error{ ReadFailed, WriteFailed, BadPath } || pack.Error;

    /// One node into the writer, in NAR order. The index already holds every
    /// directory's entries sorted by name, so this walk only follows them.
    fn writeNode(t: *const Tree, n: Node, shown: ?*std.ArrayList(u8), w: nar.Writer, filter: anytype, buf: []u8, depth: usize, d: *Diag) !void {
        if (depth >= nar.max_depth)
            return d.fail(error.BadPath, "the tarball exceeds the maximum NAR directory depth of {d}", .{nar.max_depth});
        switch (n) {
            .file => |f| {
                var br = t.blob(f.at, buf) catch |e| return d.fail(e, "{s}", .{blobText(e)});
                defer br.deinit(t.gpa);
                w.regular(f.exec, f.at.size(), br.reader()) catch |e| switch (e) {
                    error.WriteFailed => return error.WriteFailed,
                    else => return d.fail(error.ReadFailed, "the spooled tarball is truncated", .{}),
                };
            },
            .symlink => |s| try w.symlink(s),
            .dir => |entries| {
                try w.dir();
                for (entries) |e| {
                    const base = if (shown) |p| p.items.len else 0;
                    if (shown) |p| {
                        try p.append(t.gpa, '/');
                        try p.appendSlice(t.gpa, e.name);
                        if (!try filter.accept(p.items, e.node.fileType())) {
                            p.shrinkRetainingCapacity(base);
                            continue;
                        }
                    }
                    try w.entry(e.name);
                    try t.writeNode(e.node, shown, w, filter, buf, depth + 1, d);
                    try w.endEntry();
                    if (shown) |p| p.shrinkRetainingCapacity(base);
                }
                try w.endDir();
            },
        }
    }
};

pub fn blobText(e: anyerror) []const u8 {
    return switch (e) {
        error.Corrupt => "an object in the input store is not the size its index says",
        error.NotFound => "an object of this input is missing from the input store",
        error.ReadFailed => "the spooled tarball is truncated",
        else => @errorName(e),
    };
}

/// A member's bytes being read: a spool range or an object held whole.
pub const BlobReader = union(enum) {
    file: File.Reader,
    bytes: struct { data: []u8, r: Io.Reader },
    /// A slice of the mapped spool, which the tree owns.
    mapped: Io.Reader,

    pub fn reader(b: *BlobReader) *Io.Reader {
        return switch (b.*) {
            .file => |*f| &f.interface,
            .bytes => |*x| &x.r,
            .mapped => |*r| r,
        };
    }

    pub fn deinit(b: *BlobReader, gpa: Allocator) void {
        switch (b.*) {
            .file, .mapped => {},
            .bytes => |x| gpa.free(x.data),
        }
    }
};

/// Serializes a stored index: the NAR hash and size the fetch verified against
/// the lock, so no reader ever hashes the tree again, then the tree with every
/// file named by its object id. Ends with its own checksum. The layout is
/// byte for byte the one Rust iets writes, so the two share the input store.
pub fn encodeIndex(gpa: Allocator, root: Node, nar_hash: Hash, nar_size: u64) Allocator.Error![]u8 {
    var e: std.ArrayList(u8) = try .initCapacity(gpa, 1 << 16);
    errdefer e.deinit(gpa);
    try e.append(gpa, index_version);
    try putBytes(gpa, &e, nar_hash.algo.name());
    try putBytes(gpa, &e, nar_hash.bytes());
    try putU64(gpa, &e, nar_size);
    try putNode(gpa, &e, root);
    const sum = checksum(e.items);
    try e.appendSlice(gpa, &sum);
    return e.toOwnedSlice(gpa);
}

fn putU64(gpa: Allocator, e: *std.ArrayList(u8), v: u64) Allocator.Error!void {
    var n = v;
    while (true) {
        const b: u8 = @truncate(n & 0x7f);
        n >>= 7;
        if (n == 0) return e.append(gpa, b);
        try e.append(gpa, b | 0x80);
    }
}

fn putBytes(gpa: Allocator, e: *std.ArrayList(u8), b: []const u8) Allocator.Error!void {
    try putU64(gpa, e, b.len);
    try e.appendSlice(gpa, b);
}

fn putNode(gpa: Allocator, e: *std.ArrayList(u8), n: Node) Allocator.Error!void {
    switch (n) {
        .dir => |d| {
            try e.append(gpa, 0);
            try putU64(gpa, e, d.len);
            for (d) |c| {
                try putBytes(gpa, e, c.name);
                try putNode(gpa, e, c.node);
            }
        },
        .file => |f| {
            // an index is stored once its files are objects
            const o = f.at.object;
            try e.append(gpa, 1);
            try e.append(gpa, @intFromBool(f.exec));
            try e.appendSlice(gpa, &o.id);
            try putU64(gpa, e, o.size);
        },
        .symlink => |s| {
            try e.append(gpa, 2);
            try putBytes(gpa, e, s);
        },
    }
}

pub const Decoded = struct { root: Node, nar_hash: Hash, nar_size: u64 };

/// The tree, NAR hash and NAR size a stored index holds, its nodes in `a`.
/// Null on anything unexpected, so the caller wipes the entry rather than
/// repairing it.
pub fn decodeIndex(a: Allocator, bytes: []const u8) Allocator.Error!?Decoded {
    if (bytes.len < sum_len) return null;
    const body = bytes.len - sum_len;
    if (!std.mem.eql(u8, &checksum(bytes[0..body]), bytes[body..])) return null;
    var x: Idx = .{ .b = bytes[0..body] };
    if ((x.byte() orelse return null) != index_version) return null;
    const algo = hash_mod.Algo.parse(x.bytes() orelse return null) orelse return null;
    const hb = x.bytes() orelse return null;
    if (hb.len != algo.size()) return null;
    const nar_hash: Hash = .raw(algo, hb);
    const nar_size = x.int() orelse return null;
    const root = (try getNode(a, &x, 0)) orelse return null;
    if (x.i != body) return null;
    return .{ .root = root, .nar_hash = nar_hash, .nar_size = nar_size };
}

const Idx = struct {
    b: []const u8,
    i: usize = 0,

    fn byte(x: *Idx) ?u8 {
        if (x.i >= x.b.len) return null;
        x.i += 1;
        return x.b[x.i - 1];
    }

    fn int(x: *Idx) ?u64 {
        var n: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = x.byte() orelse return null;
            if (shift >= 64) return null;
            n |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return n;
            shift += 7;
        }
    }

    fn bytes(x: *Idx) ?[]const u8 {
        const n = x.int() orelse return null;
        if (n > x.b.len - x.i) return null;
        const s = x.b[x.i..][0..@intCast(n)];
        x.i += @intCast(n);
        return s;
    }
};

fn getNode(a: Allocator, x: *Idx, depth: usize) Allocator.Error!?Node {
    if (depth > nar.max_depth) return null;
    switch (x.byte() orelse return null) {
        0 => {
            const n = x.int() orelse return null;
            if (n > x.b.len - x.i) return null;
            const dir = try a.alloc(Entry, @intCast(n));
            for (dir, 0..) |*e, i| {
                const name = try a.dupe(u8, x.bytes() orelse return null);
                e.* = .{ .name = name, .node = (try getNode(a, x, depth + 1)) orelse return null };
                if (i > 0 and !std.mem.lessThan(u8, dir[i - 1].name, name)) return null;
            }
            return .{ .dir = dir };
        },
        1 => {
            const flags = x.byte() orelse return null;
            if (flags > 1) return null;
            if (x.b.len - x.i < 32) return null;
            const id = x.b[x.i..][0..32].*;
            x.i += 32;
            return .{ .file = .{ .at = .{ .object = .{ .id = id, .size = x.int() orelse return null } }, .exec = flags == 1 } };
        },
        2 => return .{ .symlink = try a.dupe(u8, x.bytes() orelse return null) },
        else => return null,
    }
}

pub fn objectIds(gpa: Allocator, n: Node, out: *std.AutoHashMapUnmanaged(Id, void)) Allocator.Error!void {
    switch (n) {
        .file => |f| switch (f.at) {
            .object => |o| try out.put(gpa, o.id, {}),
            .spool => {},
        },
        .dir => |d| for (d) |e| try objectIds(gpa, e.node, out),
        .symlink => {},
    }
}

/// What the `GNU.sparse.*` pax records of a member say: the name the member
/// really has, the size it expands to, and its data blocks. `map` is null for
/// format 1.0, which holds the map at the head of the member's data instead.
pub const Sparse = struct {
    name: ?[]const u8,
    size: u64,
    map: ?[]const [2]u64,
};

fn decimal(v: []const u8) ?u64 {
    return std.fmt.parseInt(u64, v, 10) catch null;
}

/// The three GNU pax sparse formats (GNU tar, `Sparse Formats`): 0.0 repeats
/// `offset`/`numbytes`, 0.1 holds one `map`, and 1.0 (`major` 1) puts the map in
/// the data. Without these records the member is an ordinary file.
pub fn paxSparse(a: Allocator, ar: *tar.Archive, e: *const tar.Entry, d: *Diag) Error!?Sparse {
    // a pax header the crate did not take as one (no ustar magic) is the
    // member's own data
    const ext = e.pax orelse if (e.typeflag == tar.Type.pax_local) try ar.readAll(a, e) else return null;
    var name: ?[]const u8 = null;
    var size: ?u64 = null;
    var real: ?u64 = null;
    var major: u64 = 0;
    var offset: ?u64 = null;
    var map: ?[]const [2]u64 = null;
    var blocks: std.ArrayList([2]u64) = .empty;
    var it = tar.paxRecords(ext);
    while (it.next() catch return d.fail(error.BadArchive, "cannot read a pax record: malformed pax extension", .{})) |r| {
        const k = r.key;
        const v = r.value;
        if (std.mem.eql(u8, k, "GNU.sparse.name")) {
            name = v;
        } else if (std.mem.eql(u8, k, "GNU.sparse.size")) {
            size = decimal(v);
        } else if (std.mem.eql(u8, k, "GNU.sparse.realsize")) {
            real = decimal(v);
        } else if (std.mem.eql(u8, k, "GNU.sparse.major")) {
            major = decimal(v) orelse 0;
        } else if (std.mem.eql(u8, k, "GNU.sparse.offset")) {
            offset = decimal(v);
        } else if (std.mem.eql(u8, k, "GNU.sparse.numbytes")) {
            const o = offset orelse return d.fail(error.BadArchive, "a tarball member has a bad sparse map", .{});
            offset = null;
            const n = decimal(v) orelse return d.fail(error.BadArchive, "a tarball member has a bad sparse map", .{});
            try blocks.append(a, .{ o, n });
        } else if (std.mem.eql(u8, k, "GNU.sparse.map")) {
            var got: std.ArrayList([2]u64) = .empty;
            var nums = std.mem.splitScalar(u8, v, ',');
            while (nums.next()) |o| {
                const n = nums.next() orelse return d.fail(error.BadArchive, "a tarball member has a bad sparse map", .{});
                try got.append(a, .{
                    decimal(o) orelse return d.fail(error.BadArchive, "a tarball member has a bad sparse map", .{}),
                    decimal(n) orelse return d.fail(error.BadArchive, "a tarball member has a bad sparse map", .{}),
                });
            }
            map = got.items;
        }
    }
    if (major >= 1) {
        const s = real orelse return d.fail(error.BadArchive, "a sparse tarball member has no 'realsize'", .{});
        return .{ .name = name, .size = s, .map = null };
    }
    const m = map orelse if (blocks.items.len > 0) blocks.items else return null;
    const s = size orelse return d.fail(error.BadArchive, "a sparse tarball member has no 'size'", .{});
    return .{ .name = name, .size = s, .map = m };
}

/// The member's data as `expand` reads it: by offset, within the member.
const MemberData = struct {
    src: tar.Source,
    at: u64,
    left: u64,

    fn readExact(m: *MemberData, buf: []u8) error{ ReadFailed, UnexpectedEof }!void {
        if (buf.len > m.left) return error.UnexpectedEof;
        if (try m.src.readAt(buf, m.at) != buf.len) return error.UnexpectedEof;
        m.at += buf.len;
        m.left -= buf.len;
    }
};

fn expandText(e: anyerror) []const u8 {
    return switch (e) {
        error.UnexpectedEof => "failed to fill whole buffer",
        error.BadMap => "a sparse map that does not fit the file",
        error.BadDecimal => "a bad sparse map in a tarball member",
        else => @errorName(e),
    };
}

/// A sparse member written out whole at `base` in the side file: its data
/// blocks where they belong, and holes for the rest.
pub fn expand(a: Allocator, io: Io, ar: *tar.Archive, e: *const tar.Entry, pax: ?Sparse, side: File, base: u64, size: u64) !void {
    var buf: [chunk]u8 = undefined;
    const p = pax orelse {
        // an old-style GNU sparse member: its runs are in the entry
        var to = base;
        for (e.sparse orelse &.{}) |r| {
            if (r.data) {
                var left = r.len;
                var from = r.archive_at;
                while (left > 0) {
                    const n: usize = @intCast(@min(left, buf.len));
                    if (try ar.src.readAt(buf[0..n], from) != n) return error.UnexpectedEof;
                    try side.writePositionalAll(io, buf[0..n], to);
                    from += n;
                    to += n;
                    left -= n;
                }
            } else to += r.len;
        }
        try side.setLength(io, base + size);
        return;
    };
    var data: MemberData = .{ .src = ar.src, .at = e.file_pos, .left = e.size };
    var owned: std.ArrayList([2]u64) = .empty;
    defer owned.deinit(a);
    const map = p.map orelse blk: {
        try readMap(a, &data, &owned);
        break :blk owned.items;
    };
    var end: u64 = 0;
    for (map) |m| {
        const at = m[0];
        const len = m[1];
        const stop = std.math.add(u64, at, len) catch return error.BadMap;
        if (at < end or stop > size) return error.BadMap;
        end = stop;
        var left = len;
        var to = base + at;
        while (left > 0) {
            const n: usize = @intCast(@min(left, buf.len));
            try data.readExact(buf[0..n]);
            try side.writePositionalAll(io, buf[0..n], to);
            to += n;
            left -= n;
        }
    }
    try side.setLength(io, base + size);
}

/// The map a format 1.0 sparse member holds at the head of its data: decimal
/// numbers on their own lines, padded out to whole 512-byte blocks.
fn readMap(a: Allocator, data: *MemberData, out: *std.ArrayList([2]u64)) !void {
    var dec: Decimals = .{ .src = data };
    const count = try dec.next();
    for (0..count) |_| try out.append(a, .{ try dec.next(), try dec.next() });
}

const Decimals = struct {
    src: *MemberData,
    buf: [512]u8 = undefined,
    pos: usize = 512,

    fn next(x: *Decimals) !u64 {
        var n: u64 = 0;
        var digits: usize = 0;
        while (true) {
            if (x.pos == x.buf.len) {
                try x.src.readExact(&x.buf);
                x.pos = 0;
            }
            const b = x.buf[x.pos];
            x.pos += 1;
            if (b == '\n' and digits > 0) return n;
            const dgt = b -% '0';
            if (dgt >= 10) return error.BadDecimal;
            n = std.math.mul(u64, n, 10) catch return error.BadDecimal;
            n = std.math.add(u64, n, dgt) catch return error.BadDecimal;
            digits += 1;
        }
    }
};

fn linkTarget(a: Allocator, e: *const tar.Entry, parts: []const []const u8, what: []const u8, d: *Diag) Error![]const u8 {
    const t = e.linkName() orelse return d.fail(error.BadArchive, "tarball {s} '{s}' has no target", .{ what, try show(a, parts) });
    return a.dupe(u8, t);
}

const testing = std.testing;
const T = tar.Type;
const TM = tar.TestMember;

const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    base: []const u8,
    d: Diag,
    n: usize = 0,

    fn init() !*TestEnv {
        const e = try testing.allocator.create(TestEnv);
        e.* = .{ .arena = .init(testing.allocator), .tmp = testing.tmpDir(.{ .iterate = true }), .base = "", .d = .init(testing.allocator) };
        var buf: [Dir.max_path_bytes]u8 = undefined;
        e.base = try e.arena.allocator().dupe(u8, buf[0..try e.tmp.dir.realPath(testing.io, &buf)]);
        return e;
    }

    fn deinit(e: *TestEnv) void {
        e.d.deinit();
        e.tmp.cleanup();
        e.arena.deinit();
        testing.allocator.destroy(e);
    }

    fn spooled(e: *TestEnv, bytes: []const u8, max: u64) !Tree {
        const f = try scratch(testing.io, "test", &e.d);
        try f.writePositionalAll(testing.io, bytes, 0);
        return Tree.index(testing.allocator, testing.io, f, max, &e.d);
    }

    /// The NAR the spool writes for the tar `bytes`.
    fn streamed(e: *TestEnv, bytes: []const u8) ![]const u8 {
        var t = try e.spooled(bytes, std.math.maxInt(u64));
        defer t.deinit();
        var out: Io.Writer.Allocating = .init(e.arena.allocator());
        try t.dump(&out.writer, &e.d);
        return out.written();
    }

    /// The NAR of the tree `unpack` writes for the same archive.
    fn unpacked(e: *TestEnv, bytes: []const u8) ![]const u8 {
        const a = e.arena.allocator();
        e.n += 1;
        const dest = try std.fmt.allocPrint(a, "{s}/u{d}", .{ e.base, e.n });
        var ud: Diag = .init(testing.allocator);
        defer ud.deinit();
        const root = try unpack.unpack(a, testing.io, bytes, dest, &ud);
        var out: Io.Writer.Allocating = .init(a);
        try nar.dumpPath(a, testing.io, Dir.cwd(), root, &out.writer, nar.keep_all, &ud);
        return out.written();
    }

    fn same(e: *TestEnv, members: []const TM) ![]const u8 {
        const bytes = try tar.testTar(e.arena.allocator(), members);
        const s = try e.streamed(bytes);
        try testing.expectEqualSlices(u8, try e.unpacked(bytes), s);
        return s;
    }
};

test "the spool's NAR is the unpacked tree's, rule for rule" {
    const e = try TestEnv.init();
    defer e.deinit();
    const big: [70 * 1024]u8 = @splat('z');
    _ = try e.same(&.{
        .{ .name = "pax_global_header", .t = T.pax_global, .data = "" },
        .{ .name = "repo-abc/", .t = T.directory, .mode = 0o755 },
        .{ .name = "repo-abc/flake.nix", .t = T.regular, .data = "{}\n" },
        .{ .name = "repo-abc/run", .t = T.regular, .mode = 0o755, .data = "#!/bin/sh\n" },
        .{ .name = "repo-abc/empty/", .t = T.directory, .mode = 0o700 },
        .{ .name = "repo-abc/link", .t = T.symlink, .mode = 0o777, .data = "flake.nix" },
        .{ .name = "repo-abc/dup", .t = T.regular, .data = "first" },
        .{ .name = "repo-abc/dup", .t = T.regular, .mode = 0o755, .data = "second" },
        .{ .name = "repo-abc/same", .t = T.link, .data = "repo-abc/run" },
        .{ .name = "repo-abc/deep/a/b/c", .t = T.regular, .data = "nested\n" },
        .{ .name = "repo-abc/big", .t = T.regular, .data = &big },
    });
}

test "one leading directory is stripped; two top-level entries are not" {
    const e = try TestEnv.init();
    defer e.deinit();
    const one = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = T.regular, .data = "x" } });
    const two = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = T.regular, .data = "x" }, .{ .name = "g", .t = T.regular, .data = "y" } });
    try testing.expect(!std.mem.eql(u8, one, two));
    _ = try e.same(&.{.{ .name = "only", .t = T.regular, .data = "x" }});
}

test "an empty archive is an empty directory" {
    const e = try TestEnv.init();
    defer e.deinit();
    const got = try e.same(&.{});
    var out: Io.Writer.Allocating = .init(e.arena.allocator());
    const n: nar.Writer = .{ .w = &out.writer };
    try n.header();
    try n.dir();
    try n.endDir();
    try testing.expectEqualSlices(u8, out.written(), got);
}

test "the same errors as the tree path, for the same archives" {
    const e = try TestEnv.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const cases = [_]struct { m: []const TM, why: []const u8 }{
        .{ .m = &.{.{ .name = "dev", .t = T.fifo }}, .why = "unsupported file type" },
        .{ .m = &.{.{ .name = "l", .t = T.link, .data = "missing" }}, .why = "hard link" },
        .{ .m = &.{ .{ .name = "d/", .t = T.directory, .mode = 0o755 }, .{ .name = "l", .t = T.link, .data = "d" }, .{ .name = "k", .t = T.regular, .data = "x" } }, .why = "hard link" },
    };
    for (cases) |c| {
        const bytes = try tar.testTar(a, c.m);
        try testing.expectError(error.BadArchive, e.streamed(bytes));
        try testing.expect(std.mem.indexOf(u8, e.d.message(), c.why) != null);
        if (e.unpacked(bytes)) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "archives the git sink accepts: '..', a member below a symlink, an unknown type" {
    const e = try TestEnv.init();
    defer e.deinit();
    const escaped = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/a", .t = T.regular, .data = "in" }, .{ .name = "t/../../esc", .t = T.regular, .data = "out" } });
    const want = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/a", .t = T.regular, .data = "in" }, .{ .name = "esc", .t = T.regular, .data = "out" } });
    try testing.expectEqualSlices(u8, want, escaped);
    const under = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/s", .t = T.symlink, .mode = 0o777, .data = "/etc" }, .{ .name = "t/s/f", .t = T.regular, .data = "x" } });
    const want2 = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/s/f", .t = T.regular, .data = "x" } });
    try testing.expectEqualSlices(u8, want2, under);
    const unknown = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = 'Z', .data = "hello" } });
    const want3 = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = T.regular, .data = "hello" } });
    try testing.expectEqualSlices(u8, want3, unknown);
}

test "a hard link never replaces a member, and may name a later link" {
    const e = try TestEnv.init();
    defer e.deinit();
    const later = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = T.regular, .data = "first" }, .{ .name = "t/h", .t = T.link, .data = "t/f" }, .{ .name = "t/h", .t = T.regular, .data = "second" } });
    const want = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = T.regular, .data = "first" }, .{ .name = "t/h", .t = T.regular, .data = "second" } });
    try testing.expectEqualSlices(u8, want, later);
    const chain = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = T.regular, .data = "x" }, .{ .name = "t/h2", .t = T.link, .data = "t/h1" }, .{ .name = "t/h1", .t = T.link, .data = "t/f" } });
    const want2 = try e.same(&.{ .{ .name = "t/", .t = T.directory, .mode = 0o755 }, .{ .name = "t/f", .t = T.regular, .data = "x" }, .{ .name = "t/h1", .t = T.regular, .data = "x" }, .{ .name = "t/h2", .t = T.regular, .data = "x" } });
    try testing.expectEqualSlices(u8, want2, chain);
}

test "the scratch file never follows a symlink" {
    const io = testing.io;
    const e = try TestEnv.init();
    defer e.deinit();
    // every name is random, so a planted link is never opened: only the
    // exclusive create could be tricked, and it refuses an existing name
    const f = try scratch(io, "bait", &e.d);
    defer f.close(io);
    try f.writePositionalAll(io, "the archive", 0);
    try testing.expectError(error.PathAlreadyExists, Dir.cwd().createFile(io, "/proc/self/exe", .{ .exclusive = true }));
}

/// One pax local extended header and the member it belongs to.
fn paxTar(a: Allocator, records: []const [2][]const u8, name: []const u8, data: []const u8) ![]u8 {
    var recs: std.ArrayList(u8) = .empty;
    for (records) |r| {
        const body = try std.fmt.allocPrint(a, " {s}={s}\n", .{ r[0], r[1] });
        var len = body.len + 1;
        while (true) {
            const rec = try std.fmt.allocPrint(a, "{d}{s}", .{ len, body });
            if (rec.len == len) {
                try recs.appendSlice(a, rec);
                break;
            }
            len = rec.len;
        }
    }
    return tar.testTar(a, &.{ .{ .name = "PaxHeaders/x", .t = T.pax_local, .data = recs.items }, .{ .name = name, .t = T.regular, .data = data } });
}

fn holey() [8192]u8 {
    var want: [8192]u8 = @splat(0);
    @memcpy(want[4096..4100], "abcd");
    return want;
}

test "GNU tar's three pax sparse formats give the file the archive describes" {
    const e = try TestEnv.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var one_zero: [516]u8 = @splat(0);
    @memcpy(one_zero[0..9], "1\n4096\n4\n");
    @memcpy(one_zero[512..516], "abcd");
    const cases = [_]struct { recs: []const [2][]const u8, name: []const u8, data: []const u8 }{
        .{ .recs = &.{ .{ "GNU.sparse.size", "8192" }, .{ "GNU.sparse.numblocks", "1" }, .{ "GNU.sparse.offset", "4096" }, .{ "GNU.sparse.numbytes", "4" } }, .name = "top/sparse", .data = "abcd" },
        .{ .recs = &.{ .{ "GNU.sparse.size", "8192" }, .{ "GNU.sparse.numblocks", "1" }, .{ "GNU.sparse.name", "top/sparse" }, .{ "GNU.sparse.map", "4096,4" } }, .name = "top/GNUSparseFile.1/sparse", .data = "abcd" },
        .{ .recs = &.{ .{ "GNU.sparse.major", "1" }, .{ "GNU.sparse.minor", "0" }, .{ "GNU.sparse.name", "top/sparse" }, .{ "GNU.sparse.realsize", "8192" } }, .name = "top/GNUSparseFile.1/sparse", .data = &one_zero },
    };
    const h = holey();
    const want = try e.same(&.{ .{ .name = "top/", .t = T.directory, .mode = 0o755 }, .{ .name = "top/sparse", .t = T.regular, .data = &h } });
    for (cases) |c| {
        const bytes = try paxTar(a, c.recs, c.name, c.data);
        const s = try e.streamed(bytes);
        try testing.expectEqualSlices(u8, try e.unpacked(bytes), s);
        try testing.expectEqualSlices(u8, want, s);
    }
}

test "a sparse member counts against the size limit before it is written" {
    const e = try TestEnv.init();
    defer e.deinit();
    var data: [512]u8 = @splat(0);
    @memcpy(data[0..2], "0\n");
    const bomb = try paxTar(e.arena.allocator(), &.{ .{ "GNU.sparse.major", "1" }, .{ "GNU.sparse.minor", "0" }, .{ "GNU.sparse.name", "top/hole" }, .{ "GNU.sparse.realsize", "1099511627776" } }, "top/GNUSparseFile.1/hole", &data);
    try testing.expect(bomb.len < 4096);
    try testing.expectError(error.BadArchive, e.spooled(bomb, 1 << 20));
    try testing.expect(std.mem.indexOf(u8, e.d.message(), "fetch-max-size") != null);
}

test "hard links count against the budget, and a dropped one costs nothing" {
    const e = try TestEnv.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const big = try a.alloc(u8, 64 << 10);
    @memset(big, 'x');
    var ms: std.ArrayList(TM) = .empty;
    try ms.append(a, .{ .name = "f", .t = T.regular, .data = big });
    for (0..32) |i| try ms.append(a, .{ .name = try std.fmt.allocPrint(a, "l{d}", .{i}), .t = T.link, .data = "f" });
    try testing.expectError(error.BadArchive, e.spooled(try tar.testTar(a, ms.items), 1 << 20));
    try testing.expect(std.mem.indexOf(u8, e.d.message(), "fetch-max-size") != null);

    // a hard link to a symlink copies its target
    const target = try a.alloc(u8, 99);
    @memset(target, 'x');
    ms.clearRetainingCapacity();
    try ms.append(a, .{ .name = "s", .t = T.symlink, .mode = 0o777, .data = target });
    for (0..32) |i| try ms.append(a, .{ .name = try std.fmt.allocPrint(a, "l{d}", .{i}), .t = T.link, .data = "s" });
    const links = try tar.testTar(a, ms.items);
    try testing.expectError(error.BadArchive, e.spooled(links, links.len + 1000));

    const huge = try a.alloc(u8, 300 << 10);
    @memset(huge, 'x');
    var t = try e.spooled(try tar.testTar(a, &.{
        .{ .name = "f", .t = T.regular, .data = huge },
        .{ .name = "a", .t = T.link, .data = "f" },
        .{ .name = "b", .t = T.link, .data = "f" },
        .{ .name = "c", .t = T.link, .data = "f" },
        .{ .name = "a", .t = T.regular, .data = "a" },
        .{ .name = "b", .t = T.regular, .data = "b" },
        .{ .name = "c", .t = T.regular, .data = "c" },
    }), 1 << 20);
    t.deinit();
}

test "a member nested too deep is refused" {
    const e = try TestEnv.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var deep: std.ArrayList(u8) = .empty;
    for (0..nar.max_depth + 1) |i| {
        if (i > 0) try deep.append(a, '/');
        try deep.append(a, 'd');
    }
    const bytes = try paxTar(a, &.{.{ "path", deep.items }}, "x", "x");
    try testing.expectError(error.BadArchive, e.spooled(bytes, std.math.maxInt(u64)));
    try testing.expect(std.mem.indexOf(u8, e.d.message(), "nested deeper") != null);
}

/// The tree as the store keeps it: its files as objects in a pack under
/// `dir`, and the index naming them.
fn storedTest(e: *TestEnv, t: *const Tree, packs: *pack.Packs) !struct { Tree, []const u8 } {
    const a = e.arena.allocator();
    const w = try pack.PackWriter.init(testing.allocator, testing.io, e.tmp.dir);
    defer w.deinit();
    var ids: std.AutoHashMapUnmanaged(Blob, Id) = .empty;
    defer ids.deinit(testing.allocator);
    for (try t.files(a)) |at| {
        const bytes = try t.read(a, at);
        const id = pack.idOf(bytes);
        try w.add(id, bytes);
        try ids.put(testing.allocator, at, id);
    }
    var tree_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    const root = try t.withIds(tree_arena.allocator(), &ids);
    var nb: [37]u8 = undefined;
    _ = try w.finish(&nb);
    var h: hash_mod.Hasher = .init(.sha256);
    var hb: [4096]u8 = undefined;
    var hw = h.writer(&hb);
    try t.dump(&hw.interface, &e.d);
    const index = try encodeIndex(a, root, h.finish(), h.count);
    _ = try packs.refresh();
    return .{ Tree.stored(testing.allocator, testing.io, packs, tree_arena, root), index };
}

test "a stored tree dumps the spool's NAR and reads the same" {
    const e = try TestEnv.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const long = try a.alloc(u8, 10_000);
    @memset(long, 'z');
    var t = try e.spooled(try tar.testTar(a, &.{
        .{ .name = "t/", .t = T.directory, .mode = 0o755 },
        .{ .name = "t/a", .t = T.regular, .data = "same" },
        .{ .name = "t/sub/", .t = T.directory, .mode = 0o755 },
        .{ .name = "t/sub/b", .t = T.regular, .mode = 0o755, .data = "same" },
        .{ .name = "t/sub/long", .t = T.regular, .data = long },
        .{ .name = "t/empty", .t = T.regular, .data = "" },
        .{ .name = "t/l", .t = T.symlink, .mode = 0o777, .data = "sub/b" },
    }), std.math.maxInt(u64));
    defer t.deinit();
    const packs = try pack.Packs.open(testing.allocator, testing.io, e.base);
    defer packs.deinit();
    var back, const index = try storedTest(e, &t, packs);
    defer back.deinit();
    var want: Io.Writer.Allocating = .init(a);
    try t.dump(&want.writer, &e.d);
    var got: Io.Writer.Allocating = .init(a);
    try back.dump(&got.writer, &e.d);
    try testing.expectEqualSlices(u8, want.written(), got.written());
    const l = (try back.resolve(a, "l", true)).?;
    try testing.expectEqualStrings("same", try back.read(a, l.file.at));
    const dec = (try decodeIndex(a, index)).?;
    var ids: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer ids.deinit(testing.allocator);
    try objectIds(testing.allocator, dec.root, &ids);
    // "same" twice, the long file and the empty one
    try testing.expectEqual(@as(u32, 3), ids.count());
}

test "no byte of a stored index is believed on its own" {
    const e = try TestEnv.init();
    defer e.deinit();
    const a = e.arena.allocator();
    var t = try e.spooled(try tar.testTar(a, &.{
        .{ .name = "t/", .t = T.directory, .mode = 0o755 },
        .{ .name = "t/f", .t = T.regular, .data = "x" },
        .{ .name = "t/l", .t = T.symlink, .mode = 0o777, .data = "f" },
    }), std.math.maxInt(u64));
    defer t.deinit();
    const packs = try pack.Packs.open(testing.allocator, testing.io, e.base);
    defer packs.deinit();
    var back, const good = try storedTest(e, &t, packs);
    defer back.deinit();
    try testing.expect((try decodeIndex(a, good)) != null);
    for (0..good.len) |i| {
        const bad = try a.dupe(u8, good);
        bad[i] ^= 0xff;
        try testing.expect((try decodeIndex(a, bad)) == null);
    }
}

test "the NAR hash of the fixture is the one a lock file records" {
    const e = try TestEnv.init();
    defer e.deinit();
    const a = e.arena.allocator();
    const http = @import("http.zig");
    const plain = try http.decompress(a, @embedFile("testdata/tree.tar.gz"), std.math.maxInt(u64), &e.d);
    const s = try e.streamed(plain);
    try testing.expectEqualSlices(u8, try e.unpacked(plain), s);
    var h: hash_mod.Hasher = .init(.sha256);
    h.update(s);
    var buf: [128]u8 = undefined;
    const want = std.mem.trim(u8, @embedFile("testdata/narHash"), " \n");
    try testing.expectEqualStrings(want, h.finish().print(&buf, .sri, true));
}
