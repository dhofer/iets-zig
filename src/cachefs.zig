//! On-disk hygiene shared by the caches: the compiled-IR
//! cache (sharded files), the tracing cache (a directory per entry), the
//! input store (an entry per store path) and the roots store (links). Each
//! has a format version file, a single-writer lock, mtime touches and TTL
//! sweeps. The layouts are this binary's own: the default root is
//! `iets-zig`, not Rust iets's `iets`, so a format change here never wipes
//! or sweeps Rust iets's stores, nor a change there ours.
//!
//! The invariant the processes sharing a directory hold together: an entry
//! is one file, written to a temporary name and renamed into place, so a
//! reader sees the whole previous entry or the whole new one and never
//! locks; a writer holds the store's `flock` for one such file, and one that
//! cannot take it within `lock_timeout_ns` drops the write.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Crc32 = @import("bytes.zig").Crc32;

/// The store layout; a mismatch wipes the store.
pub const format = "3";
/// Bytes of the integrity sum after an entry.
pub const sum_len = 8;
/// The largest entry a read accepts: a crafted length is refused before
/// anything is allocated.
pub const max_entry = 512 << 20;

pub const day_s: u64 = 24 * 60 * 60;
const day_ns: i96 = day_s * std.time.ns_per_s;
/// Entries unread for this many days are swept.
pub const ttl_days: u64 = 30;
const ttl_ns = ttl_days * day_ns;
/// A hit inside this window writes nothing; a sweep runs at most this often;
/// a killed writer's temporary file goes after this long.
const touch_ns = day_ns;
const gc_ns = day_ns;
const tmp_ns = day_ns;
const lock_timeout_ns = 50 * std.time.ns_per_ms;
const lock_poll_ns = 2 * std.time.ns_per_ms;

const dir_mode: File.Permissions = .fromMode(0o700);
const file_mode: File.Permissions = .fromMode(0o600);

/// The default root's name under the user's cache directory: deliberately
/// not Rust iets's `iets`, whose stores this binary must never touch.
pub const dir_name = "iets-zig";

/// The directory every store lives under: `override`, else `IETS_CACHE_DIR`,
/// else `$XDG_CACHE_HOME/iets-zig`, else `~/.cache/iets-zig`. Null without a home.
pub fn root(a: std.mem.Allocator, env: *const std.process.Environ.Map, override: ?[]const u8) !?[]const u8 {
    if (override) |d| return d;
    if (env.get("IETS_CACHE_DIR")) |d| if (d.len > 0) return d;
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return try std.fs.path.join(a, &.{ x, dir_name });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(a, &.{ home, ".cache", dir_name });
}

fn isHex(b: []const u8) bool {
    for (b) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// An entry's name in its shard: the key past its first two characters.
fn isKey(name: []const u8) bool {
    return name.len == 62 and isHex(name);
}

fn isShard(name: []const u8) bool {
    return name.len == 2 and isHex(name);
}

fn isTmp(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".") and std.mem.endsWith(u8, name, ".tmp");
}

/// How a store names its entries under its root.
pub const Shape = enum {
    /// One directory per entry, named by the 64-hex run key (tracing cache).
    dirs,
    /// One file per entry, named by its key past the two-character shard
    /// directory the key's first two characters make (IR cache).
    sharded_files,
    /// One file per entry, named by a store path's base name (the input
    /// store), beside the `packs` directory.
    store_entries,
    /// One symlink per entry, named by a 64-hex key (the roots store).
    links,

    /// The layout of a store of this shape; the input store has its own, so
    /// a change to its entries wipes it alone.
    pub fn format(sh: Shape) []const u8 {
        return switch (sh) {
            .store_entries => entries.entries_format,
            .dirs, .sharded_files, .links => cachefs_format,
        };
    }
};

const cachefs_format = format;

/// A sweep only ever removes something named like a key, so the store-level
/// files, a sibling store under a shared root, and anything else a user put
/// in the directory all survive.
fn isKeyOf(name: []const u8, shape: Shape) bool {
    return switch (shape) {
        .store_entries => entries.isEntryKey(name),
        .dirs, .links => name.len == 64 and isHex(name),
        .sharded_files => isKey(name),
    };
}

/// A name a store of `shape` puts in its own root.
fn belongs(name: []const u8, shape: Shape) bool {
    for ([_][]const u8{ "version", "lock", "gc-stamp", "env-key" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return isTmp(name) or isKeyOf(name, shape) or
        (shape == .sharded_files and isShard(name)) or
        (shape == .store_entries and std.mem.eql(u8, name, "packs"));
}

fn allOurs(io: Io, d: Dir, shape: Shape) bool {
    var it = d.iterate();
    while (it.next(io) catch return false) |e| if (!belongs(e.name, shape)) return false;
    return true;
}

fn isEmptyDir(io: Io, d: Dir) bool {
    var it = d.iterate();
    return (it.next(io) catch return false) == null;
}

/// Whose directory a store root is: null when it is not
/// iets's, else why it must be wiped first, or null-reason when it is ready.
const Owner = union(enum) { ready, stale: []const u8, foreign };

fn owner(io: Io, d: Dir, shape: Shape) Owner {
    var buf: [64]u8 = undefined;
    if (d.readFile(io, "version", &buf)) |v| {
        if (!std.mem.eql(u8, std.mem.trim(u8, v, " \n\t\r"), shape.format())) return .{ .stale = "format version mismatch" };
    } else |_| {
        if (!isEmptyDir(io, d)) {
            if (allOurs(io, d, shape)) return .{ .stale = "no format version" };
            return .foreign;
        }
    }
    if (d.statFile(io, "lock", .{ .follow_symlinks = false })) |st| {
        if (st.kind == .directory) return .{ .stale = "lock is not a file" };
    } else |_| {}
    var sbuf: [64]u8 = undefined;
    if (d.readFile(io, "gc-stamp", &sbuf)) |stamp| {
        if (stampSecs(stamp) == null) return .{ .stale = "unreadable gc stamp" };
    } else |_| {}
    return .ready;
}

fn stampSecs(bytes: []const u8) ?i64 {
    const t = std.mem.trim(u8, bytes, " \n\t\r");
    const v = std.fmt.parseInt(u64, t, 10) catch return null;
    return std.math.cast(i64, v);
}

/// Empties a store iets owns, touching only the names its own layout
/// makes: the store-level files, the temporary files, the entries and the
/// IR shards. Anything else in the directory stays.
fn wipe(io: Io, d: Dir, shape: Shape) void {
    for ([_][]const u8{ "version", "lock", "gc-stamp", "env-key" }) |n| d.deleteTree(io, n) catch {};
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const ours = isTmp(e.name) or isKeyOf(e.name, shape) or
            (shape == .sharded_files and isShard(e.name)) or
            (shape == .store_entries and std.mem.eql(u8, e.name, "packs"));
        if (ours) names.append(arena.allocator(), arena.allocator().dupe(u8, e.name) catch return) catch return;
    }
    for (names.items) |n| {
        if (shape == .sharded_files and isShard(n)) {
            wipeShard(io, d, n);
        } else d.deleteTree(io, n) catch {};
    }
}

fn wipeShard(io: Io, d: Dir, name: []const u8) void {
    var s = d.openDir(io, name, .{ .iterate = true }) catch return;
    var si = s.iterate();
    while (si.next(io) catch null) |f| if (isTmp(f.name) or isKey(f.name)) s.deleteFile(io, f.name) catch {};
    s.close(io);
    d.deleteDir(io, name) catch {};
}

/// Make `path` a usable IR store, and say whether it is.
pub fn prepare(io: Io, path: []const u8, stderr: ?*Io.Writer) bool {
    return prepareShape(io, path, .sharded_files, stderr, false);
}

/// Makes `path` usable as a store of `shape`, and says whether it is. A
/// version mismatch or an unreadable store-level file wipes the store and
/// starts it empty: a cache is never repaired in place. A directory that is
/// not iets's is refused instead, because `--cache-dir` points this at a
/// directory the user names.
pub fn prepareShape(io: Io, path: []const u8, shape: Shape, stderr: ?*Io.Writer, timings: bool) bool {
    if (Dir.cwd().openDir(io, path, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close(io);
        switch (owner(io, d, shape)) {
            .ready => {},
            .stale => |why| {
                if (timings) if (stderr) |w| {
                    w.print("cache: wiping {s} ({s})\n", .{ path, why }) catch {};
                    w.flush() catch {};
                };
                wipe(io, d, shape);
            },
            .foreign => {
                if (stderr) |w| {
                    w.print("error: {s} is not an iets cache and is not empty, so iets will not use it; point --cache-dir (or IETS_CACHE_DIR) at a new or empty directory, or empty this one\n", .{path}) catch {};
                    w.flush() catch {};
                }
                return false;
            },
        }
    } else |_| {}
    // a root that cannot be made is still the run's to try: its writes fail
    // and say so
    entries.createDir(io, path) catch return true;
    var d = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return true;
    defer d.close(io);
    var buf: [16]u8 = undefined;
    if (d.readFile(io, "version", &buf)) |_| {} else |_| writeAtomic(io, d, "version", &.{shape.format()}) catch {};
    d.setPermissions(io, dir_mode) catch {};
    return true;
}

/// The key of this process's `getEnv` hashes, from `<root>/env-key`. An
/// observation of an environment variable needs only to know whether the
/// value changed, so an entry holds a keyed hash and never the value; the
/// key keeps that hash from being a guessing game for whoever reads the
/// file. One process uses one cache, so the first store prepared sets it;
/// without one the hash is keyed with zeros, and nothing that run records
/// reaches disk.
pub fn useEnvKey(io: Io, root_path: []const u8) void {
    env_lock.lockUncancelable(io);
    defer env_lock.unlock(io);
    if (env_set.load(.acquire)) return;
    var d = Dir.cwd().openDir(io, root_path, .{}) catch return;
    defer d.close(io);
    var k: [32]u8 = undefined;
    if (readEnvKey(io, d, &k)) return setEnvKey(k);
    // two cold processes must not each publish a key: the loser's entries
    // would hash with one the winner's run cannot reproduce
    const l = writeLock(io, d);
    defer if (l) |f| unlock(io, f);
    if (readEnvKey(io, d, &k)) return setEnvKey(k);
    io.random(&k);
    writeAtomic(io, d, "env-key", &.{&k}) catch {};
    setEnvKey(k);
}

fn readEnvKey(io: Io, d: Dir, out: *[32]u8) bool {
    var buf: [33]u8 = undefined;
    const got = d.readFile(io, "env-key", &buf) catch return false;
    if (got.len != 32) return false;
    @memcpy(out, got);
    return true;
}

fn setEnvKey(k: [32]u8) void {
    env_secret = k;
    env_set.store(true, .release);
}

/// Process-wide by nature: one process uses one cache.
var env_secret: [32]u8 = @splat(0);
var env_set: std.atomic.Value(bool) = .init(false);
var env_lock: Io.Mutex = .init;

pub fn envKey() *const [32]u8 {
    return &env_secret;
}

var tag_counter: std.atomic.Value(u64) = .init(0);

/// A counter that keeps two writers of one name inside one process apart, for
/// every temporary name the caches make.
pub fn tag() u64 {
    return tag_counter.fetchAdd(1, .monotonic);
}

/// Write `chunks` to `name` in `d` through a temporary file, so a reader sees
/// the old contents or the new ones; `name` is a name in `d`, not a path.
pub fn writeAtomic(io: Io, d: Dir, name: []const u8, chunks: []const []const u8) !void {
    var tmp_buf: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.{d}.{d}.tmp", .{ name, std.os.linux.getpid(), tag_counter.fetchAdd(1, .monotonic) });
    var f = try d.createFile(io, tmp, .{ .permissions = file_mode });
    errdefer d.deleteFile(io, tmp) catch {};
    {
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var w = f.writerStreaming(io, &wbuf);
        for (chunks) |c| try w.interface.writeAll(c);
        try w.interface.flush();
    }
    try Dir.rename(d, tmp, d, name, io);
}

/// The integrity sum of an entry under `key`: CRC-32 of the key and the
/// parts, then their length.
pub fn checksum(key: []const u8, parts: []const []const u8) [sum_len]u8 {
    var h: Crc32 = .{};
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, key.len)));
    h.update(key);
    var len: usize = 0;
    for (parts) |p| {
        h.update(p);
        len += p.len;
    }
    var out: [sum_len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], h.final(), .little);
    std.mem.writeInt(u32, out[4..8], @truncate(len), .little);
    return out;
}

/// The bytes of the entry at `sub` in `d`: a regular file that is no link,
/// of a length an entry can have. Its sum is the caller's to check.
pub fn readEntry(io: Io, d: Dir, sub: []const u8, gpa: std.mem.Allocator) ?[]u8 {
    var f = d.openFile(io, sub, .{ .follow_symlinks = false, .allow_directory = false }) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    if (st.kind != .file or st.size > max_entry) return null;
    const bytes = gpa.alloc(u8, st.size) catch return null;
    const n = f.readPositionalAll(io, bytes, 0) catch {
        gpa.free(bytes);
        return null;
    };
    if (n != bytes.len) {
        gpa.free(bytes);
        return null;
    }
    // A hit marks the entry used, at most once a day, for the sweep.
    const now = Io.Clock.real.now(io);
    if (now.nanoseconds - st.mtime.nanoseconds > touch_ns) f.setTimestampsNow(io) catch {};
    return bytes;
}

/// The store's writer lock, or null when a sibling holds it past a short
/// wait: the caller skips its write, which is cheaper than waiting.
pub fn writeLock(io: Io, d: Dir) ?File {
    const f = d.createFile(io, "lock", .{ .truncate = false, .permissions = file_mode }) catch return null;
    var waited: u64 = 0;
    while (true) {
        if (f.tryLock(io, .exclusive) catch false) return f;
        if (waited >= lock_timeout_ns) break;
        io.sleep(.fromNanoseconds(lock_poll_ns), .awake) catch break;
        waited += lock_poll_ns;
    }
    f.close(io);
    return null;
}

/// `writeLock` with the two failures apart: `error.LockOpen` when the lock
/// file cannot be opened at all, a store this run cannot write, and null
/// when a sibling held the lock past the timeout, a skipped write.
pub fn tryWriteLock(io: Io, d: Dir) File.OpenError!?File {
    const f = try d.createFile(io, "lock", .{ .truncate = false, .permissions = file_mode });
    var waited: u64 = 0;
    while (true) {
        if (f.tryLock(io, .exclusive) catch false) return f;
        if (waited >= lock_timeout_ns) break;
        io.sleep(.fromNanoseconds(lock_poll_ns), .awake) catch break;
        waited += lock_poll_ns;
    }
    f.close(io);
    return null;
}

pub fn unlock(io: Io, f: File) void {
    f.unlock(io);
    f.close(io);
}

/// Remove entries unread for 30 days and stale temporary files, at most
/// once a day per store, which `gc-stamp` records. For a sharded store,
/// whose writer lock the caller holds.
pub fn maybeSweep(io: Io, d: Dir) void {
    const now = Io.Clock.real.now(io).nanoseconds;
    var buf: [32]u8 = undefined;
    if (d.readFile(io, "gc-stamp", &buf)) |s| {
        const secs = std.fmt.parseInt(i64, std.mem.trim(u8, s, " \n"), 10) catch 0;
        if (now - @as(i96, secs) * std.time.ns_per_s < gc_ns) return;
    } else |_| {}
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (isTmp(e.name)) {
            sweepOne(io, d, e.name, now, tmp_ns);
        } else if (isShard(e.name)) {
            var s = d.openDir(io, e.name, .{ .iterate = true }) catch continue;
            defer s.close(io);
            var si = s.iterate();
            while (si.next(io) catch null) |f| {
                if (isKey(f.name)) sweepOne(io, s, f.name, now, ttl_ns) else if (isTmp(f.name)) sweepOne(io, s, f.name, now, tmp_ns);
            }
        }
    }
    var sbuf: [32]u8 = undefined;
    const stamp = std.fmt.bufPrint(&sbuf, "{d}\n", .{@divFloor(now, std.time.ns_per_s)}) catch return;
    writeAtomic(io, d, "gc-stamp", &.{stamp}) catch {};
}

fn sweepOne(io: Io, d: Dir, name: []const u8, now: i96, older: i96) void {
    const st = d.statFile(io, name, .{ .follow_symlinks = false }) catch return;
    if (now - st.mtime.nanoseconds > older) d.deleteFile(io, name) catch {};
}

/// What a sweep found and removed.
pub const Swept = struct { scanned: usize = 0, removed: usize = 0, bytes: u64 = 0 };

fn ageNs(io: Io, d: Dir, name: []const u8, follow: bool, now: i96) ?i96 {
    const st = d.statFile(io, name, .{ .follow_symlinks = follow }) catch return null;
    return now - st.mtime.nanoseconds;
}

fn entrySize(io: Io, d: Dir, name: []const u8, shape: Shape) u64 {
    return switch (shape) {
        .sharded_files, .store_entries => (d.statFile(io, name, .{}) catch return 0).size,
        // a root holds no bytes of its own; what it frees is the daemon's to say
        .links => 0,
        .dirs => blk: {
            var sub = d.openDir(io, name, .{ .iterate = true }) catch break :blk 0;
            defer sub.close(io);
            var n: u64 = 0;
            var it = sub.iterate();
            while (it.next(io) catch null) |e| n += (sub.statFile(io, e.name, .{}) catch continue).size;
            break :blk n;
        },
    };
}

fn dropEntry(io: Io, d: Dir, name: []const u8, shape: Shape) bool {
    switch (shape) {
        .links, .sharded_files, .store_entries => d.deleteFile(io, name) catch return false,
        .dirs => d.deleteTree(io, name) catch return false,
    }
    return true;
}

fn sweepDir(io: Io, d: Dir, shape: Shape, ttl: i96, dry_run: bool, out: *Swept) void {
    const now = Io.Clock.real.now(io).nanoseconds;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (isTmp(e.name) or isKeyOf(e.name, shape))
            names.append(arena.allocator(), arena.allocator().dupe(u8, e.name) catch return) catch return;
    }
    for (names.items) |name| {
        if (isTmp(name)) {
            // a killed writer leaves a file in the hashed stores and a whole
            // staged directory in the input store
            if (!dry_run) if (ageNs(io, d, name, true, now)) |a| if (a >= tmp_ns) d.deleteTree(io, name) catch {};
            continue;
        }
        out.scanned += 1;
        // a link is aged by itself, not by what it names: a store path
        // carries the store's epoch
        const a = ageNs(io, d, name, shape != .links, now) orelse continue;
        if (a < ttl) continue;
        const bytes = entrySize(io, d, name, shape);
        if (dry_run or dropEntry(io, d, name, shape)) {
            out.removed += 1;
            out.bytes += bytes;
        }
    }
}

/// Removes every entry unread for longer than `ttl_s` seconds, and the
/// temporary files a killed writer left behind; `dry_run` counts and changes
/// nothing.
pub fn sweep(gpa: std.mem.Allocator, io: Io, root_path: []const u8, shape: Shape, ttl_s: u64, dry_run: bool) Swept {
    var out: Swept = .{};
    const ttl: i96 = @as(i96, ttl_s) * std.time.ns_per_s;
    var d = Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return out;
    defer d.close(io);
    switch (shape) {
        .dirs, .links => sweepDir(io, d, shape, ttl, dry_run, &out),
        .store_entries => {
            sweepDir(io, d, shape, ttl, dry_run, &out);
            // the entries name the objects; the packs hold them
            out.bytes += @import("treestore.zig").collect(gpa, io, root_path, dry_run).freed;
        },
        .sharded_files => {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            var shards: std.ArrayList([]const u8) = .empty;
            var it = d.iterate();
            while (it.next(io) catch null) |e| if (isShard(e.name) and e.kind == .directory)
                shards.append(arena.allocator(), arena.allocator().dupe(u8, e.name) catch break) catch break;
            for (shards.items) |name| {
                var sub = d.openDir(io, name, .{ .iterate = true }) catch continue;
                sweepDir(io, sub, shape, ttl, dry_run, &out);
                sub.close(io);
                if (!dry_run) d.deleteDir(io, name) catch {};
            }
        },
    }
    return out;
}

/// A sweep on a write path, at most once a day per store. The stamp is
/// claimed under the writer lock and the walk runs unlocked, so a sweep of a
/// large store never holds a sibling's write back.
pub fn maybeSweepShape(gpa: std.mem.Allocator, io: Io, root_path: []const u8, shape: Shape, timings: ?*@import("log.zig").Log) void {
    {
        var d = Dir.cwd().openDir(io, root_path, .{}) catch return;
        defer d.close(io);
        if (!due(io, d)) return;
        const l = writeLock(io, d) orelse return;
        defer unlock(io, l);
        if (!due(io, d)) return;
        var sbuf: [32]u8 = undefined;
        const now = Io.Clock.real.now(io).nanoseconds;
        const stamp = std.fmt.bufPrint(&sbuf, "{d}", .{@divFloor(now, std.time.ns_per_s)}) catch return;
        writeAtomic(io, d, "gc-stamp", &.{stamp}) catch return;
    }
    const s = sweep(gpa, io, root_path, shape, ttl_days * day_s, false);
    if (timings) |l| if (s.scanned > 0) {
        var buf: [Dir.max_path_bytes + 128]u8 = undefined;
        l.errln(std.fmt.bufPrint(&buf, "cache: swept {d} of {d} entries ({d} KiB) from {s}", .{ s.removed, s.scanned, s.bytes / 1024, root_path }) catch return);
    };
}

/// Whether a sweep is due: no stamp, an unreadable one, one a day old, or
/// one ahead of the clock (a sweep must not wait for the clock to catch up).
fn due(io: Io, d: Dir) bool {
    var buf: [64]u8 = undefined;
    const s = d.readFile(io, "gc-stamp", &buf) catch return true;
    const secs = stampSecs(s) orelse return true;
    const now = Io.Clock.real.now(io).nanoseconds;
    const age = now - @as(i96, secs) * std.time.ns_per_s;
    return age < 0 or age >= gc_ns;
}

/// The stores a `cache gc` run walks under the cache root `root_path`: the
/// tracing cache, the IR cache, the input store and the roots store.
pub const Store = struct { root: []const u8, shape: Shape };

pub fn stores(a: std.mem.Allocator, root_path: []const u8) ![4]Store {
    return .{
        .{ .root = try std.fs.path.join(a, &.{ root_path, "trace" }), .shape = .dirs },
        .{ .root = try std.fs.path.join(a, &.{ root_path, "ir" }), .shape = .sharded_files },
        .{ .root = try std.fs.path.join(a, &.{ root_path, "inputs" }), .shape = .store_entries },
        .{ .root = try std.fs.path.join(a, &.{ root_path, "roots" }), .shape = .links },
    };
}

/// The link in the roots store that `parts` name: what the root is for,
/// then whatever tells two of them apart, length-prefixed into one 64-hex
/// key so no part can spell another one's boundary.
pub fn rootLink(a: std.mem.Allocator, root_path: []const u8, parts: []const []const u8) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |p| {
        h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, p.len)));
        h.update(p);
    }
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    return std.fs.path.join(a, &.{ root_path, "roots", &hex });
}

/// Whether a cache entry may send a run to `program`: a file inside
/// `out_path`, a path of the store directory, with no `..` component. A
/// cache directory is writable by whoever runs iets, so an entry that named
/// a program freely would be a way to start one.
pub fn programOfOutput(out_path: []const u8, program: []const u8) bool {
    const store_path = @import("store/path.zig");
    const sp = store_path.StorePath.ofPath(out_path) orelse return false;
    var pbuf: [512]u8 = undefined;
    const full = sp.print(&pbuf);
    if (!std.mem.startsWith(u8, program, full)) return false;
    if (program.len > full.len and program[full.len] != '/') return false;
    var it = std.mem.splitScalar(u8, program, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return false;
    return true;
}

/// The input store's half of the hygiene (`Shape.store_entries`): one
/// file per entry, named by a store path's base name, beside the `packs`
/// directory that holds the objects (`treestore.zig`). It has a format of its
/// own, so a change to its entries wipes it alone. Paths are absolute: the
/// store root is the caller's.
pub const entries = struct {
    const store_path = @import("store/path.zig");
    const Diag = @import("diag.zig").Diag;

    /// The format version of a `store_entries` store.
    pub const entries_format = "2";
    const packs = "packs";

    /// A store path's base name: the name an entry has.
    pub fn isEntryKey(name: []const u8) bool {
        return store_path.StorePath.ofBaseName(name) != null;
    }

    /// Makes `path` a usable input store, and says whether it is.
    pub fn prepare(io: Io, path: []const u8, stderr: ?*Io.Writer) bool {
        return prepareShape(io, path, .store_entries, stderr, false);
    }

    /// `create_dir_all` with mode 0700 on what it makes.
    pub fn createDir(io: Io, path: []const u8) !void {
        _ = try Dir.cwd().createDirPathStatus(io, path, dir_mode);
    }

    /// What the name of an entry holds, as `openEntry` found it.
    pub const Found = union(enum) {
        /// A regular file of a length an entry can have, open for reading.
        file: struct { file: File, size: u64, mtime: Io.Timestamp },
        /// Nothing this run can read now.
        missing,
        /// A name that is no entry: a link, a directory, a FIFO, or a length
        /// no entry has. The caller wipes it.
        foreign,
    };

    /// Opens an entry under the rules a cache directory needs: the name must
    /// not be a symbolic link, what it names must be a regular file, and its
    /// length one an entry can have. `O_NONBLOCK` keeps the open of a FIFO
    /// from waiting for a writer.
    pub fn openEntry(io: Io, path: []const u8) Found {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0) catch {
            const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return .missing;
            return if (st.kind != .file) .foreign else .missing;
        };
        const f: File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        const st = f.stat(io) catch {
            f.close(io);
            return .missing;
        };
        if (st.kind != .file or st.size > max_entry) {
            f.close(io);
            return .foreign;
        }
        return .{ .file = .{ .file = f, .size = st.size, .mtime = st.mtime } };
    }

    /// Marks `path` as used, at most once per day: a hot cache on a busy box
    /// does not churn the disk.
    pub fn touch(io: Io, path: []const u8) void {
        const st = Dir.cwd().statFile(io, path, .{}) catch return;
        const now = Io.Clock.real.now(io).nanoseconds;
        if (now - st.mtime.nanoseconds < touch_ns) return;
        Dir.cwd().setTimestamps(io, path, .{ .access_timestamp = .now, .modify_timestamp = .now }) catch {};
    }

    /// An exclusive `flock` on the file `path`, taken without a timeout: the
    /// one wait in the caches, for work that costs far more than waiting (a
    /// download). `on_wait` runs once when a sibling holds it. The file is
    /// touched, so a sweep never takes a lock file that is in use.
    pub fn waitLock(io: Io, path: []const u8, on_wait: anytype) ?File {
        const f = Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = file_mode }) catch return null;
        if (!(f.tryLock(io, .exclusive) catch false)) {
            on_wait.call();
            f.lock(io, .exclusive) catch {
                f.close(io);
                return null;
            };
        }
        f.setTimestampsNow(io) catch {};
        return f;
    }

    /// The store's writer lock, waited for.
    pub fn storeLock(io: Io, root_path: []const u8) ?File {
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/lock", .{root_path}) catch return null;
        return waitLock(io, p, struct {
            fn call(_: @This()) void {}
        }{});
    }

    /// A sweep on a write path, at most once a day per store: entries unread
    /// for 30 days and a killed writer's leftovers go, then `collect` drops
    /// the objects no entry names. The stamp is claimed under the writer lock
    /// and the walk runs unlocked.
    pub fn maybeSweep(io: Io, root_path: []const u8, collect: anytype) void {
        var d = Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
        defer d.close(io);
        if (!due(io, d)) return;
        {
            const l = writeLock(io, d) orelse return;
            defer unlock(io, l);
            if (!due(io, d)) return;
            var sbuf: [32]u8 = undefined;
            const now = Io.Clock.real.now(io).nanoseconds;
            const stamp = std.fmt.bufPrint(&sbuf, "{d}", .{@divFloor(now, std.time.ns_per_s)}) catch return;
            writeAtomic(io, d, "gc-stamp", &.{stamp}) catch return;
        }
        sweepEntries(io, d, ttl_ns);
        collect.call();
    }

    /// Removes every entry unread for longer than `ttl`, and the temporary
    /// files and staged directories a killed writer left behind.
    pub fn sweepEntries(io: Io, d: Dir, ttl: i96) void {
        const now = Io.Clock.real.now(io).nanoseconds;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        var gone: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            const tmp = isTmp(e.name);
            if (!tmp and !isEntryKey(e.name)) continue;
            const st = d.statFile(io, e.name, .{}) catch continue;
            if (now - st.mtime.nanoseconds < if (tmp) tmp_ns else ttl) continue;
            gone.append(arena.allocator(), arena.allocator().dupe(u8, e.name) catch return) catch return;
        }
        for (gone.items) |n| d.deleteTree(io, n) catch {};
    }
};

test "the sum covers the key, the bytes and their length" {
    const a = checksum("k", &.{ "ab", "c" });
    try std.testing.expectEqualSlices(u8, &a, &checksum("k", &.{"abc"}));
    try std.testing.expect(!std.mem.eql(u8, &a, &checksum("j", &.{"abc"})));
    try std.testing.expect(!std.mem.eql(u8, &a, &checksum("k", &.{"abd"})));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, a[4..8], .little));
}

test "a store is prepared, written, read and refused when foreign" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ base, "ir" });
    defer std.testing.allocator.free(path);
    try std.testing.expect(prepare(io, path, null));
    var d = try Dir.cwd().openDir(io, path, .{});
    defer d.close(io);
    try d.createDirPath(io, "ab");
    var shard = try d.openDir(io, "ab", .{});
    defer shard.close(io);
    try writeAtomic(io, shard, &@as([62]u8, @splat('c')), &.{ "hello", " world" });
    const got = readEntry(io, d, "ab/" ++ @as([62]u8, @splat('c')), std.testing.allocator).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
    const l = writeLock(io, d).?;
    unlock(io, l);
    try tmp.dir.createDirPath(io, "other");
    try tmp.dir.writeFile(io, .{ .sub_path = "other/notes.txt", .data = "mine" });
    const other = try std.fs.path.join(std.testing.allocator, &.{ base, "other" });
    defer std.testing.allocator.free(other);
    try std.testing.expect(!prepare(io, other, null));
}

test "an input store of another layout is wiped, and a foreign directory refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const a = std.testing.allocator;
    const path = try std.fs.path.join(a, &.{ base, "inputs" });
    defer a.free(path);
    try tmp.dir.createDirPath(io, "inputs/z4wkdlk69gck09s64a8ghpn6h7bxhkyy-source");
    try tmp.dir.writeFile(io, .{ .sub_path = "inputs/z4wkdlk69gck09s64a8ghpn6h7bxhkyy-source/spool", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "inputs/version", .data = format });
    try std.testing.expect(entries.prepare(io, path, null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "inputs/z4wkdlk69gck09s64a8ghpn6h7bxhkyy-source", .{}));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("2", try tmp.dir.readFile(io, "inputs/version", &buf));
    try tmp.dir.createDirPath(io, "mine");
    try tmp.dir.writeFile(io, .{ .sub_path = "mine/notes.txt", .data = "x" });
    const mine = try std.fs.path.join(a, &.{ base, "mine" });
    defer a.free(mine);
    try std.testing.expect(!entries.prepare(io, mine, null));
}

const testing = std.testing;
const old_key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const young_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

const TestDir = struct {
    tmp: testing.TmpDir,
    buf: [Dir.max_path_bytes]u8 = undefined,
    path: []const u8 = "",

    fn init(t: *TestDir) !void {
        t.tmp = testing.tmpDir(.{ .iterate = true });
        t.path = t.buf[0..try t.tmp.dir.realPath(testing.io, &t.buf)];
    }

    fn ready(t: *TestDir) !void {
        try testing.expect(prepareShape(testing.io, t.path, .dirs, null, false));
    }

    fn exists(t: *TestDir, sub: []const u8) bool {
        t.tmp.dir.access(testing.io, sub, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    fn read(t: *TestDir, sub: []const u8, buf: []u8) ![]u8 {
        return t.tmp.dir.readFile(testing.io, sub, buf);
    }

    fn backDate(t: *TestDir, sub: []const u8, secs: u64, follow: bool) !void {
        const now = Io.Clock.real.now(testing.io).nanoseconds;
        const ts: Io.Timestamp = .fromNanoseconds(now - @as(i96, secs) * std.time.ns_per_s);
        try t.tmp.dir.setTimestamps(testing.io, sub, .{ .follow_symlinks = follow, .modify_timestamp = .{ .new = ts }, .access_timestamp = .{ .new = ts } });
    }
};

test "a version mismatch wipes the store" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    try t.tmp.dir.createDirPath(testing.io, old_key);
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "version", .data = "99" });
    try t.ready();
    try testing.expect(!t.exists(old_key));
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings(format, try t.read("version", &buf));
}

test "a garbled stamp wipes the store" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    try t.tmp.dir.createDirPath(testing.io, old_key);
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "gc-stamp", .data = "\x00not a time" });
    try t.ready();
    try testing.expect(!t.exists(old_key));
}

test "a store without a version file is wiped once" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.tmp.dir.createDirPath(testing.io, old_key);
    try t.ready();
    try testing.expect(!t.exists(old_key));
    try t.ready();
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings(format, try t.read("version", &buf));
}

test "a directory that is not ours is refused untouched" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "unrelated.txt", .data = "PRECIOUS" });
    try t.tmp.dir.createDirPath(testing.io, "notes");
    try testing.expect(!prepareShape(testing.io, t.path, .dirs, null, false));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("PRECIOUS", try t.read("unrelated.txt", &buf));
    try testing.expect(t.exists("notes") and !t.exists("version"));
}

test "a wipe keeps what iets did not create" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    try t.tmp.dir.createDirPath(testing.io, old_key);
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "unrelated.txt", .data = "PRECIOUS" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "version", .data = "99" });
    try t.ready();
    try testing.expect(!t.exists(old_key));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("PRECIOUS", try t.read("unrelated.txt", &buf));
}

test "a wipe of the IR cache walks its shards" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try testing.expect(prepareShape(testing.io, t.path, .sharded_files, null, false));
    try t.tmp.dir.createDirPath(testing.io, "ab");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ab/" ++ old_key[2..], .data = "ir" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ab/keep.txt", .data = "PRECIOUS" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "version", .data = "99" });
    try testing.expect(prepareShape(testing.io, t.path, .sharded_files, null, false));
    try testing.expect(!t.exists("ab/" ++ old_key[2..]));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("PRECIOUS", try t.read("ab/keep.txt", &buf));
}

test "an empty directory is ours to take" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings(format, try t.read("version", &buf));
}

test "the writer lock excludes one holder at a time" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    const held = writeLock(testing.io, t.tmp.dir).?;
    try testing.expect(writeLock(testing.io, t.tmp.dir) == null);
    unlock(testing.io, held);
    unlock(testing.io, writeLock(testing.io, t.tmp.dir).?);
}

test "a touch inside the interval writes nothing" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "entry", .data = "x" });
    try t.backDate("entry", 60, true);
    const before = (try t.tmp.dir.statFile(testing.io, "entry", .{})).mtime;
    var pbuf: [Dir.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/entry", .{t.path});
    entries.touch(testing.io, p);
    try testing.expectEqual(before.nanoseconds, (try t.tmp.dir.statFile(testing.io, "entry", .{})).mtime.nanoseconds);
    try t.backDate("entry", 3 * day_s, true);
    entries.touch(testing.io, p);
    try testing.expect((try t.tmp.dir.statFile(testing.io, "entry", .{})).mtime.nanoseconds > before.nanoseconds);
}

test "a sweep drops old entries and keeps young ones" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    for ([_]struct { []const u8, u64 }{ .{ old_key, 40 * day_s }, .{ young_key, 60 } }) |e| {
        try t.tmp.dir.createDirPath(testing.io, e[0]);
        var b: [80]u8 = undefined;
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&b, "{s}/readset", .{e[0]}), .data = "payload" });
        try t.backDate(e[0], e[1], true);
    }
    try t.tmp.dir.createDirPath(testing.io, "ir");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = ".readset.1.0.tmp", .data = "litter" });
    try t.backDate(".readset.1.0.tmp", 3 * day_s, true);
    const dry = sweep(testing.allocator, testing.io, t.path, .dirs, ttl_days * day_s, true);
    try testing.expectEqual(2, dry.scanned);
    try testing.expectEqual(1, dry.removed);
    try testing.expect(t.exists(old_key) and t.exists(".readset.1.0.tmp"));
    const done = sweep(testing.allocator, testing.io, t.path, .dirs, ttl_days * day_s, false);
    try testing.expectEqual(Swept{ .scanned = 2, .removed = 1, .bytes = 7 }, done);
    try testing.expect(!t.exists(old_key) and t.exists(young_key) and t.exists("ir") and !t.exists(".readset.1.0.tmp"));
}

test "a sweep ages a root by its link, not by what it names" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.tmp.dir.createDirPath(testing.io, "target");
    try t.backDate("target", 400 * day_s, true);
    for ([_]struct { []const u8, u64 }{ .{ old_key, 40 * day_s }, .{ young_key, 60 } }) |e| {
        try t.tmp.dir.symLink(testing.io, "target", e[0], .{});
        try t.backDate(e[0], e[1], false);
    }
    const s = sweep(testing.allocator, testing.io, t.path, .links, ttl_days * day_s, false);
    try testing.expectEqual(Swept{ .scanned = 2, .removed = 1, .bytes = 0 }, s);
    try testing.expect(!t.exists(old_key) and t.exists(young_key) and t.exists("target"));
}

test "a sweep walks the shards of the IR cache" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    try t.tmp.dir.createDirPath(testing.io, "ab");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ab/" ++ old_key[2..], .data = "ir" });
    try t.backDate("ab/" ++ old_key[2..], 40 * day_s, true);
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ab/" ++ young_key[2..], .data = "ir" });
    try t.backDate("ab/" ++ young_key[2..], 60, true);
    const s = sweep(testing.allocator, testing.io, t.path, .sharded_files, ttl_days * day_s, false);
    try testing.expectEqual(2, s.scanned);
    try testing.expectEqual(1, s.removed);
    try testing.expect(t.exists("ab/" ++ young_key[2..]));
}

test "a sweep runs once per interval, and a stamp in the future is due" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    maybeSweepShape(testing.allocator, testing.io, t.path, .dirs, null);
    var b1: [32]u8 = undefined;
    const stamp = try testing.allocator.dupe(u8, try t.read("gc-stamp", &b1));
    defer testing.allocator.free(stamp);
    try t.tmp.dir.createDirPath(testing.io, old_key);
    try t.backDate(old_key, 40 * day_s, true);
    maybeSweepShape(testing.allocator, testing.io, t.path, .dirs, null);
    try testing.expect(t.exists(old_key));
    var b2: [32]u8 = undefined;
    try testing.expectEqualStrings(stamp, try t.read("gc-stamp", &b2));
    const now: u64 = @intCast(@divFloor(Io.Clock.real.now(testing.io).nanoseconds, std.time.ns_per_s));
    var sb: [32]u8 = undefined;
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "gc-stamp", .data = try std.fmt.bufPrint(&sb, "{d}", .{now - 2 * day_s}) });
    maybeSweepShape(testing.allocator, testing.io, t.path, .dirs, null);
    try testing.expect(!t.exists(old_key));
    try t.tmp.dir.createDirPath(testing.io, old_key);
    try t.backDate(old_key, 40 * day_s, true);
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "gc-stamp", .data = try std.fmt.bufPrint(&sb, "{d}", .{now + 900 * day_s}) });
    maybeSweepShape(testing.allocator, testing.io, t.path, .dirs, null);
    try testing.expect(!t.exists(old_key) and t.exists("version"));
}

test "a lock that cannot be opened is not a busy lock" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.ready();
    const held = (try tryWriteLock(testing.io, t.tmp.dir)).?;
    try testing.expect((try tryWriteLock(testing.io, t.tmp.dir)) == null);
    unlock(testing.io, held);
    try t.tmp.dir.setFilePermissions(testing.io, "lock", .fromMode(0o400), .{});
    // root opens it anyway
    if (std.os.linux.geteuid() != 0) try testing.expect(std.meta.isError(tryWriteLock(testing.io, t.tmp.dir)));
}

test "a cache is private to its owner" {
    var t: TestDir = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.tmp.dir.createDirPath(testing.io, "trace");
    try t.tmp.dir.setFilePermissions(testing.io, "trace", .fromMode(0o755), .{});
    var pbuf: [Dir.max_path_bytes]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&pbuf, "{s}/trace", .{t.path});
    try testing.expect(prepareShape(testing.io, root_path, .dirs, null, false));
    const mode = struct {
        fn of(d: Dir, sub: []const u8) !u32 {
            return (try d.statFile(testing.io, sub, .{})).permissions.toMode() & 0o777;
        }
    }.of;
    try testing.expectEqual(0o700, try mode(t.tmp.dir, "trace"));
    try testing.expectEqual(0o600, try mode(t.tmp.dir, "trace/version"));
}
