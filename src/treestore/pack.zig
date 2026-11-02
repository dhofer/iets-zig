//! Where the input store keeps file contents: immutable pack files of objects
//! named by the blake3 of their bytes, so a file that two inputs share — most
//! of nixpkgs between two revisions — is stored once. The layout began as
//! Rust iets's; it is this binary's own, under the `iets-zig` cache root,
//! never shared with Rust's store. The design is
//! nix-tarmac's (github.com/Mic92/nix-tarmac), with a pack that indexes itself in place of
//! its LMDB index: a pack is written once under a temporary name and renamed
//! into place, and nothing in it changes after, which is the `cachefs`
//! discipline.
//!
//! A pack is the header, the payloads one after the other, the index — one
//! fixed-width record per object, sorted by id — and a tail: a fanout table on
//! the first byte of the id, the count, where the index starts, a checksum over
//! the index and the tail, and a trailer. A payload is LZ4 when that makes it
//! smaller. The checksum covers the index; a payload is trusted because the
//! tree it belongs to was hashed against the lock before anything named it.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Blake3 = std.crypto.hash.Blake3;
const lz4 = @import("lz4.zig");
const sys_fs = @import("../sys/fs.zig");

pub const packs_dir = "packs";

pub const Id = [32]u8;

pub fn idOf(bytes: []const u8) Id {
    var out: Id = undefined;
    Blake3.hash(bytes, &out, .{});
    return out;
}

/// An object at least this big is streamed in, uncompressed, and never held
/// in memory whole.
pub const stream_min: u64 = 64 << 20;

const magic = "ietspack";
const trailer = "ietsidx1";
const entry_len = 32 + 8 + 8 + 8 + 1;
const tail_len = 256 * 4 + 8 + 8 + 16 + 8;
const flag_lz4: u8 = 1;
const min_compress = 64;

pub const Loc = struct {
    offset: u64,
    stored: u64,
    raw: u64,
    flags: u8,
};

pub const Error = error{ Corrupt, NotFound, ReadFailed } || Allocator.Error;

pub const Pack = struct {
    file: File,
    /// The file's name in the packs directory.
    name: []const u8,
    index: []u8,
    fanout: [256]u32,
    len: u64,

    /// Null when the file is not a whole, well-formed pack: the caller
    /// removes it rather than reading anything it says. The open neither
    /// follows a symlink nor waits on a FIFO: the directory is writable by
    /// whoever runs iets.
    pub fn open(gpa: Allocator, io: Io, dir: Dir, name: []const u8) !?*Pack {
        const file = try openNoFollow(io, dir, name);
        errdefer file.close(io);
        const st = try file.stat(io);
        if (st.kind != .file) {
            file.close(io);
            return null;
        }
        const p = try parse(gpa, io, file, st.size) orelse {
            file.close(io);
            return null;
        };
        p.name = gpa.dupe(u8, name) catch |e| {
            gpa.free(p.index);
            gpa.destroy(p);
            return e;
        };
        return p;
    }

    fn parse(gpa: Allocator, io: Io, file: File, len: u64) Allocator.Error!?*Pack {
        if (len < magic.len + tail_len) return null;
        var head: [8]u8 = undefined;
        if ((file.readPositionalAll(io, &head, 0) catch return null) != 8) return null;
        if (!std.mem.eql(u8, &head, magic)) return null;
        var tail: [tail_len]u8 = undefined;
        if ((file.readPositionalAll(io, &tail, len - tail_len) catch return null) != tail_len) return null;
        if (!std.mem.eql(u8, tail[tail_len - 8 ..], trailer)) return null;
        const n = std.mem.readInt(u64, tail[1024..1032], .little);
        const start = std.mem.readInt(u64, tail[1032..1040], .little);
        const index_len = std.math.mul(u64, n, entry_len) catch return null;
        const end = std.math.add(u64, start, index_len) catch return null;
        if (start < magic.len or end + tail_len != len) return null;
        const index = try gpa.alloc(u8, @intCast(index_len));
        errdefer gpa.free(index);
        if ((file.readPositionalAll(io, index, start) catch return null) != index.len) {
            gpa.free(index);
            return null;
        }
        var h: Blake3 = .init(.{});
        h.update(index);
        h.update(tail[0..1040]);
        var digest: [32]u8 = undefined;
        h.final(&digest);
        if (!std.mem.eql(u8, digest[0..16], tail[1040..1056])) {
            gpa.free(index);
            return null;
        }
        const p = try gpa.create(Pack);
        p.* = .{ .file = file, .name = "", .index = index, .fanout = undefined, .len = len };
        for (&p.fanout, 0..) |*f, i| f.* = std.mem.readInt(u32, tail[i * 4 ..][0..4], .little);
        if (!p.wellFormed(start)) {
            gpa.free(index);
            gpa.destroy(p);
            return null;
        }
        return p;
    }

    /// The index is sorted, the fanout agrees with it, and every payload lies
    /// between the header and the index: a reader can then trust what an entry
    /// says without checking it again.
    fn wellFormed(p: *const Pack, start: u64) bool {
        var counts: [256]u32 = @splat(0);
        for (0..p.count()) |i| {
            const id = p.idAt(i);
            if (i > 0 and !std.mem.lessThan(u8, p.idAt(i - 1), id)) return false;
            counts[id[0]] += 1;
            const loc = p.locAt(i);
            const fits = loc.offset >= magic.len and (std.math.add(u64, loc.offset, loc.stored) catch return false) <= start;
            const shape = switch (loc.flags) {
                0 => loc.stored == loc.raw,
                flag_lz4 => loc.stored < loc.raw,
                else => false,
            };
            if (!fits or !shape) return false;
        }
        var sum: u32 = 0;
        for (counts, 0..) |c, b| {
            sum += c;
            if (p.fanout[b] != sum) return false;
        }
        return true;
    }

    pub fn close(p: *Pack, gpa: Allocator, io: Io) void {
        p.file.close(io);
        gpa.free(p.index);
        gpa.free(p.name);
        gpa.destroy(p);
    }

    pub fn count(p: *const Pack) usize {
        return p.index.len / entry_len;
    }

    pub fn idAt(p: *const Pack, i: usize) []const u8 {
        return p.index[i * entry_len ..][0..32];
    }

    pub fn locAt(p: *const Pack, i: usize) Loc {
        const e = p.index[i * entry_len ..][0..entry_len];
        return .{
            .offset = std.mem.readInt(u64, e[32..40], .little),
            .stored = std.mem.readInt(u64, e[40..48], .little),
            .raw = std.mem.readInt(u64, e[48..56], .little),
            .flags = e[56],
        };
    }

    pub fn find(p: *const Pack, id: *const Id) ?Loc {
        const b = id[0];
        var lo: usize = if (b == 0) 0 else p.fanout[b - 1];
        var hi: usize = p.fanout[b];
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u8, p.idAt(mid), id)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return p.locAt(mid),
            }
        }
        return null;
    }

    /// An object's bytes, from `gpa`.
    pub fn read(p: *const Pack, gpa: Allocator, io: Io, loc: Loc) Error![]u8 {
        const stored = try gpa.alloc(u8, @intCast(loc.stored));
        const n = p.file.readPositionalAll(io, stored, loc.offset) catch {
            gpa.free(stored);
            return error.Corrupt;
        };
        if (n != stored.len) {
            gpa.free(stored);
            return error.Corrupt;
        }
        if (loc.flags & flag_lz4 == 0) return stored;
        defer gpa.free(stored);
        const out = try gpa.alloc(u8, @intCast(loc.raw));
        lz4.decompress(stored, out) catch {
            gpa.free(out);
            return error.Corrupt;
        };
        return out;
    }
};

/// `open(O_NOFOLLOW | O_NONBLOCK)`: a link is no pack and a FIFO is not waited
/// on.
pub fn openNoFollow(io: Io, dir: Dir, name: []const u8) !File {
    _ = io;
    const fd = try std.posix.openat(dir.handle, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// An object's payload as a pack stores it, made apart from the writer so that
/// several threads can compress while one appends.
pub const Prepared = struct {
    payload: []u8,
    raw: u64,
    flags: u8,

    pub fn deinit(p: Prepared, gpa: Allocator) void {
        gpa.free(p.payload);
    }
};

/// `bytes`, owned by the result, compressed when that makes them smaller.
pub fn prepare(gpa: Allocator, bytes: []u8) Allocator.Error!Prepared {
    if (bytes.len >= min_compress) {
        const buf = try gpa.alloc(u8, lz4.bound(bytes.len));
        const n = lz4.compress(bytes, buf);
        if (n < bytes.len) {
            gpa.free(bytes);
            return .{ .payload = gpa.realloc(buf, n) catch buf[0..n], .raw = bytes.len, .flags = flag_lz4 };
        }
        gpa.free(buf);
    }
    return .{ .payload = bytes, .raw = bytes.len, .flags = 0 };
}

/// The caches' one counter of temporary names (`cachefs.tag`).
pub const tag = @import("../cachefs.zig").tag;

/// A pack being written, under a temporary name in the packs directory, so a
/// killed writer leaves a `.tmp` the sweep removes.
pub const PackWriter = struct {
    gpa: Allocator,
    io: Io,
    dir: Dir,
    tmp_buf: [64]u8,
    tmp: []const u8,
    file: File,
    fw: File.Writer,
    buf: []u8,
    at: u64,
    entries: std.ArrayList(struct { id: Id, loc: Loc }) = .empty,
    ids: std.AutoHashMapUnmanaged(Id, void) = .empty,
    finished: bool = false,
    /// The bytes the disk was asked to start writing (`startWriteback`).
    written_back: u64 = 0,

    /// A writer into `dir`, which is created when missing; `dir` stays the
    /// caller's.
    pub fn init(gpa: Allocator, io: Io, dir: Dir) !*PackWriter {
        const w = try gpa.create(PackWriter);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .io = io, .dir = dir, .tmp_buf = undefined, .tmp = "", .file = undefined, .fw = undefined, .buf = &.{}, .at = magic.len };
        w.tmp = std.fmt.bufPrint(&w.tmp_buf, ".pack.{d}.{d}.tmp", .{ std.os.linux.getpid(), tag() }) catch unreachable;
        w.file = try dir.createFile(io, w.tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        errdefer {
            w.file.close(io);
            dir.deleteFile(io, w.tmp) catch {};
        }
        w.buf = try gpa.alloc(u8, 1 << 20);
        w.fw = w.file.writerStreaming(io, w.buf);
        try w.fw.interface.writeAll(magic);
        return w;
    }

    /// Drops the pack unless `finish` named it.
    pub fn deinit(w: *PackWriter) void {
        if (!w.finished) {
            w.file.close(w.io);
            w.dir.deleteFile(w.io, w.tmp) catch {};
        }
        w.entries.deinit(w.gpa);
        w.ids.deinit(w.gpa);
        w.gpa.free(w.buf);
        w.gpa.destroy(w);
    }

    pub fn add(w: *PackWriter, id: Id, bytes: []const u8) !void {
        if (w.ids.contains(id)) return;
        try w.addPrepared(id, try prepare(w.gpa, try w.gpa.dupe(u8, bytes)));
    }

    /// Takes `p` whatever happens.
    pub fn addPrepared(w: *PackWriter, id: Id, p: Prepared) !void {
        defer p.deinit(w.gpa);
        if ((try w.ids.getOrPut(w.gpa, id)).found_existing) return;
        try w.push(id, p.payload, p.raw, p.flags);
    }

    /// An object of `raw` bytes copied from `r` as it is, for one of at least
    /// `stream_min` bytes.
    pub fn addStream(w: *PackWriter, id: Id, r: *Io.Reader, raw: u64) !void {
        if ((try w.ids.getOrPut(w.gpa, id)).found_existing) return;
        r.streamExact64(&w.fw.interface, raw) catch |e| switch (e) {
            error.EndOfStream => return error.ObjectChangedSize,
            else => |x| return x,
        };
        try w.entries.append(w.gpa, .{ .id = id, .loc = .{ .offset = w.at, .stored = raw, .raw = raw, .flags = 0 } });
        w.at += raw;
    }

    /// An object copied from another pack as it is stored, for a compaction:
    /// nothing is decompressed or compressed again. It goes through in
    /// chunks, as a streamed object may be any size.
    pub fn copy(w: *PackWriter, id: Id, from: *const Pack, loc: Loc) !void {
        if ((try w.ids.getOrPut(w.gpa, id)).found_existing) return;
        var buf: [64 * 1024]u8 = undefined;
        var done: u64 = 0;
        while (done < loc.stored) {
            const n: usize = @intCast(@min(loc.stored - done, buf.len));
            if ((from.file.readPositionalAll(w.io, buf[0..n], loc.offset + done) catch return error.Corrupt) != n) return error.Corrupt;
            try w.fw.interface.writeAll(buf[0..n]);
            done += n;
        }
        try w.entries.append(w.gpa, .{ .id = id, .loc = .{ .offset = w.at, .stored = loc.stored, .raw = loc.raw, .flags = loc.flags } });
        w.at += loc.stored;
    }

    /// Starts the disk writing what the pack holds so far, so `finish`'s
    /// sync waits for the last of it rather than all of it: on a channel
    /// tarball's 96 MB pack, a 55 ms sync after the last object.
    pub fn startWriteback(w: *PackWriter) void {
        const handed = w.at - w.fw.interface.end;
        if (handed <= w.written_back) return;
        sys_fs.startWriteback(w.file.handle, w.written_back, handed - w.written_back);
        w.written_back = handed;
    }

    fn push(w: *PackWriter, id: Id, payload: []const u8, raw: u64, flags: u8) !void {
        try w.fw.interface.writeAll(payload);
        try w.entries.append(w.gpa, .{ .id = id, .loc = .{ .offset = w.at, .stored = payload.len, .raw = raw, .flags = flags } });
        w.at += payload.len;
    }

    /// Writes the index, syncs and renames the pack into place, named by the
    /// checksum of its index; the name, in `name_buf`. Null when it holds
    /// nothing: no file is left.
    pub fn finish(w: *PackWriter, name_buf: *[37]u8) !?[]const u8 {
        w.finished = true;
        if (w.entries.items.len == 0) {
            w.file.close(w.io);
            w.dir.deleteFile(w.io, w.tmp) catch {};
            return null;
        }
        errdefer {
            w.file.close(w.io);
            w.dir.deleteFile(w.io, w.tmp) catch {};
        }
        // sorted as (first 8 bytes, position) pairs: an id is a blake3 hash,
        // so the prefix almost always decides, and a pair moves cheaper
        // than an entry
        const items = w.entries.items;
        const Key = struct { prefix: u64, at: u32 };
        const keys = try w.gpa.alloc(Key, items.len);
        defer w.gpa.free(keys);
        for (keys, items, 0..) |*k, e, i| k.* = .{ .prefix = std.mem.readInt(u64, e.id[0..8], .big), .at = @intCast(i) };
        std.mem.sortUnstable(Key, keys, items, struct {
            fn lt(es: @TypeOf(items), a: Key, b: Key) bool {
                if (a.prefix != b.prefix) return a.prefix < b.prefix;
                return std.mem.lessThan(u8, &es[a.at].id, &es[b.at].id);
            }
        }.lt);
        var fanout: [256]u32 = @splat(0);
        var h: Blake3 = .init(.{});
        const out = &w.fw.interface;
        for (keys) |k| {
            const e = items[k.at];
            var rec: [entry_len]u8 = undefined;
            @memcpy(rec[0..32], &e.id);
            std.mem.writeInt(u64, rec[32..40], e.loc.offset, .little);
            std.mem.writeInt(u64, rec[40..48], e.loc.stored, .little);
            std.mem.writeInt(u64, rec[48..56], e.loc.raw, .little);
            rec[56] = e.loc.flags;
            h.update(&rec);
            try out.writeAll(&rec);
            fanout[e.id[0]] += 1;
        }
        var tail: [1040]u8 = undefined;
        var sum: u32 = 0;
        for (fanout, 0..) |c, i| {
            sum += c;
            std.mem.writeInt(u32, tail[i * 4 ..][0..4], sum, .little);
        }
        std.mem.writeInt(u64, tail[1024..1032], w.entries.items.len, .little);
        std.mem.writeInt(u64, tail[1032..1040], w.at, .little);
        h.update(&tail);
        var digest: [32]u8 = undefined;
        h.final(&digest);
        try out.writeAll(&tail);
        try out.writeAll(digest[0..16]);
        try out.writeAll(trailer);
        try out.flush();
        try w.file.sync(w.io);
        w.file.close(w.io);
        const name = std.fmt.bufPrint(name_buf, "{x}.pack", .{digest[0..16]}) catch unreachable;
        try Dir.rename(w.dir, w.tmp, w.dir, name, w.io);
        return name;
    }
};

/// The packs of a directory as one listing saw them.
pub const PackSet = struct {
    packs: []*Pack,

    pub fn find(s: *const PackSet, id: *const Id) ?struct { pack: *Pack, loc: Loc } {
        for (s.packs) |p| if (p.find(id)) |loc| return .{ .pack = p, .loc = loc };
        return null;
    }
};

/// The packs of a store as a process sees them: one listing, taken again when
/// an object is not in it, because a compaction since may have moved it. A
/// pack this process has open stays readable after a sweep unlinks it: every
/// pack opened stays open, and every listing stays valid, until `deinit`, so
/// a reader holds a listing with no count of its own.
pub const Packs = struct {
    gpa: Allocator,
    io: Io,
    dir_path: []const u8,
    lock: Io.Mutex = .init,
    current: *PackSet,
    /// Every pack opened, by file name: a name is the checksum of its index,
    /// so a pack listed again is the one already open.
    open_packs: std.StringHashMapUnmanaged(*Pack) = .empty,
    sets: std.ArrayList(*PackSet) = .empty,

    pub fn open(gpa: Allocator, io: Io, dir_path: []const u8) Allocator.Error!*Packs {
        const p = try gpa.create(Packs);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = io, .dir_path = try gpa.dupe(u8, dir_path), .current = undefined };
        p.current = try p.load();
        return p;
    }

    pub fn deinit(p: *Packs) void {
        for (p.sets.items) |s| {
            p.gpa.free(s.packs);
            p.gpa.destroy(s);
        }
        p.sets.deinit(p.gpa);
        var it = p.open_packs.valueIterator();
        while (it.next()) |pk| pk.*.close(p.gpa, p.io);
        p.open_packs.deinit(p.gpa);
        p.gpa.free(p.dir_path);
        p.gpa.destroy(p);
    }

    /// Every whole pack in the directory. A pack that does not parse is
    /// removed: it is a cache file, and its objects come back with the inputs
    /// that need them. The caller holds the lock or owns `p` alone.
    fn load(p: *Packs) Allocator.Error!*PackSet {
        var list: std.ArrayList(*Pack) = .empty;
        defer list.deinit(p.gpa);
        if (Dir.cwd().openDir(p.io, p.dir_path, .{ .iterate = true })) |d_| {
            var d = d_;
            defer d.close(p.io);
            var it = d.iterate();
            while (it.next(p.io) catch null) |e| {
                if (!std.mem.endsWith(u8, e.name, ".pack")) continue;
                if (p.open_packs.get(e.name)) |pk| {
                    try list.append(p.gpa, pk);
                    continue;
                }
                const pk = Pack.open(p.gpa, p.io, d, e.name) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                } orelse {
                    d.deleteFile(p.io, e.name) catch {};
                    continue;
                };
                try p.open_packs.put(p.gpa, pk.name, pk);
                try list.append(p.gpa, pk);
            }
        } else |_| {}
        const s = try p.gpa.create(PackSet);
        errdefer p.gpa.destroy(s);
        s.* = .{ .packs = try list.toOwnedSlice(p.gpa) };
        try p.sets.append(p.gpa, s);
        return s;
    }

    pub fn snapshot(p: *Packs) *const PackSet {
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        return p.current;
    }

    pub fn refresh(p: *Packs) Allocator.Error!*const PackSet {
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        p.current = try p.load();
        return p.current;
    }

    pub fn contains(p: *Packs, id: *const Id) bool {
        return p.snapshot().find(id) != null;
    }

    /// An object's bytes, from `gpa`. `NotFound` when no pack holds it even
    /// after a fresh listing: the entry that named it is then not whole.
    pub fn read(p: *Packs, gpa: Allocator, id: *const Id) Error![]u8 {
        if (p.snapshot().find(id)) |f| return f.pack.read(gpa, p.io, f.loc);
        if ((try p.refresh()).find(id)) |f| return f.pack.read(gpa, p.io, f.loc);
        return error.NotFound;
    }
};

/// What a collection did, or would do on a dry run.
pub const Collected = struct {
    removed: usize = 0,
    rewritten: usize = 0,
    freed: u64 = 0,
};

/// Removes every pack that holds no object in `live`, and rewrites a pack whose
/// dead bytes outweigh its live ones into a new pack of the live ones only. The
/// caller holds the store's lock, so no writer publishes an entry meanwhile;
/// a reader that has a pack open keeps reading it after the unlink.
pub fn collect(gpa: Allocator, io: Io, dir_path: []const u8, live: *const std.AutoHashMapUnmanaged(Id, void), dry_run: bool) !Collected {
    var out: Collected = .{};
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out;
    defer dir.close(io);
    const all = try Packs.open(gpa, io, dir_path);
    defer all.deinit();
    for (all.current.packs) |pack| {
        var keep: u64 = 0;
        var dead: u64 = 0;
        for (0..pack.count()) |i| {
            const id: *const Id = pack.idAt(i)[0..32];
            if (live.contains(id.*)) keep += pack.locAt(i).stored else dead += pack.locAt(i).stored;
        }
        if (keep == 0) {
            out.removed += 1;
            out.freed += pack.len;
            if (!dry_run) try dir.deleteFile(io, pack.name);
        } else if (dead > keep) {
            out.rewritten += 1;
            out.freed += dead;
            if (!dry_run) {
                const w = try PackWriter.init(gpa, io, dir);
                defer w.deinit();
                for (0..pack.count()) |i| {
                    const id: *const Id = pack.idAt(i)[0..32];
                    if (live.contains(id.*)) try w.copy(id.*, pack, pack.locAt(i));
                }
                var nb: [37]u8 = undefined;
                const new = try w.finish(&nb);
                if (new == null or !std.mem.eql(u8, new.?, pack.name)) try dir.deleteFile(io, pack.name);
            }
        }
    }
    return out;
}

const testing = std.testing;

fn testObjects(a: Allocator) ![4][]const u8 {
    const big = try a.alloc(u8, 20000);
    for (0..5000) |i| std.mem.writeInt(u32, big[i * 4 ..][0..4], @intCast(i), .little);
    return .{ "", "short", &@as([4096]u8, @splat('a')), big };
}

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(testing.io, buf)];
}

test "a pack reads back what was written" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const objects = try testObjects(arena.allocator());
    const w = try PackWriter.init(testing.allocator, io, tmp.dir);
    defer w.deinit();
    for (objects) |o| try w.add(idOf(o), o);
    var nb: [37]u8 = undefined;
    const name = (try w.finish(&nb)).?;
    const p = (try Pack.open(testing.allocator, io, tmp.dir, name)).?;
    defer p.close(testing.allocator, io);
    for (objects) |o| {
        const got = try p.read(testing.allocator, io, p.find(&idOf(o)).?);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, o, got);
    }
    try testing.expect(p.find(&idOf("absent")) == null);
    const a = p.find(&idOf(objects[2])).?;
    try testing.expect(a.stored < a.raw);
}

test "a streamed object reads back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const o: [4096]u8 = @splat(7);
    const w = try PackWriter.init(testing.allocator, io, tmp.dir);
    defer w.deinit();
    var r: Io.Reader = .fixed(&o);
    try w.addStream(idOf(&o), &r, o.len);
    var nb: [37]u8 = undefined;
    const p = (try Pack.open(testing.allocator, io, tmp.dir, (try w.finish(&nb)).?)).?;
    defer p.close(testing.allocator, io);
    const got = try p.read(testing.allocator, io, p.find(&idOf(&o)).?);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &o, got);
}

test "an empty writer leaves no file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const w = try PackWriter.init(testing.allocator, io, tmp.dir);
    defer w.deinit();
    var nb: [37]u8 = undefined;
    try testing.expect((try w.finish(&nb)) == null);
    var it = tmp.dir.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "a changed index byte is not a pack" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const objects = try testObjects(arena.allocator());
    const w = try PackWriter.init(testing.allocator, io, tmp.dir);
    defer w.deinit();
    for (objects) |o| try w.add(idOf(o), o);
    var nb: [37]u8 = undefined;
    const name = try arena.allocator().dupe(u8, (try w.finish(&nb)).?);
    const good = try tmp.dir.readFileAlloc(io, name, arena.allocator(), .unlimited);
    const start = good.len - tail_len - objects.len * entry_len;
    var i = start;
    while (i < good.len) : (i += 7) {
        const bad = try arena.allocator().dupe(u8, good);
        bad[i] ^= 1;
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bad });
        try testing.expect((try Pack.open(testing.allocator, io, tmp.dir, name)) == null);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = good[0 .. good.len - 1] });
    try testing.expect((try Pack.open(testing.allocator, io, tmp.dir, name)) == null);
}

test "a set finds objects across packs, drops a broken one, and sees a later pack" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pb: [Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &pb);
    for ([_][]const u8{ "one", "two" }) |o| {
        const w = try PackWriter.init(testing.allocator, io, tmp.dir);
        defer w.deinit();
        try w.add(idOf(o), o);
        var nb: [37]u8 = undefined;
        _ = try w.finish(&nb);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "junk.pack", .data = "not a pack" });
    const packs = try Packs.open(testing.allocator, io, path);
    defer packs.deinit();
    for ([_][]const u8{ "one", "two" }) |o| {
        const got = try packs.read(testing.allocator, &idOf(o));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(o, got);
    }
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "junk.pack", .{}));
    try testing.expectError(error.NotFound, packs.read(testing.allocator, &idOf("three")));
    const w = try PackWriter.init(testing.allocator, io, tmp.dir);
    defer w.deinit();
    try w.add(idOf("late"), "late");
    var nb: [37]u8 = undefined;
    _ = try w.finish(&nb);
    const got = try packs.read(testing.allocator, &idOf("late"));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("late", got);
}

test "collect removes dead packs and compacts mostly dead ones" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pb: [Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &pb);
    var big1: [10003]u8 = @splat(1);
    @memset(big1[10000..], 1 ^ 0x55);
    var big2: [10003]u8 = @splat(2);
    @memset(big2[10000..], 2 ^ 0x55);
    const keep = "keep, small";
    var mixed_buf: [37]u8 = undefined;
    var dead_buf: [37]u8 = undefined;
    const mixed = blk: {
        const w = try PackWriter.init(gpa, io, tmp.dir);
        defer w.deinit();
        try w.add(idOf(keep), keep);
        try w.add(idOf(&big1), &big1);
        break :blk (try w.finish(&mixed_buf)).?;
    };
    const dead = blk: {
        const w = try PackWriter.init(gpa, io, tmp.dir);
        defer w.deinit();
        try w.add(idOf(&big2), &big2);
        break :blk (try w.finish(&dead_buf)).?;
    };
    var live: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer live.deinit(gpa);
    try live.put(gpa, idOf(keep), {});

    const dry = try collect(gpa, io, path, &live, true);
    try testing.expectEqual(@as(usize, 1), dry.removed);
    try testing.expectEqual(@as(usize, 1), dry.rewritten);
    try tmp.dir.access(io, mixed, .{});
    try tmp.dir.access(io, dead, .{});

    const reader = try Packs.open(gpa, io, path);
    defer reader.deinit();
    _ = try collect(gpa, io, path, &live, false);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, mixed, .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, dead, .{}));
    const early = try reader.read(gpa, &idOf(keep));
    gpa.free(early);
    try testing.expectEqual(@as(usize, 1), (try reader.refresh()).packs.len);
    const late = try reader.read(gpa, &idOf(keep));
    defer gpa.free(late);
    try testing.expectEqualStrings(keep, late);
    try testing.expectError(error.NotFound, reader.read(gpa, &idOf(&big1)));
}
