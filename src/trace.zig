//! Tracing evaluation cache: the read set an evaluation records, its
//! validation against the file system, and the on-disk entry. The design is
//! docs/explanation/caching.md.
//!
//! An evaluator holds a `Trace` (`Evaluator.Config.trace`), a handle that is
//! off by default and records nothing. Every read the evaluation makes of the
//! outside world goes through one of its methods, from any worker: the
//! recorder copies what it is given under its lock, so a caller may pass
//! bytes it is about to free.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const sysfs = @import("sys/fs.zig");
const nar = @import("store/nar.zig");
const cachefs = @import("cachefs.zig");

pub const key = @import("trace/key.zig");
pub const wire = @import("trace/wire.zig");
pub const store = @import("trace/store.zig");
pub const validate = @import("trace/validate.zig");
pub const watch = @import("trace/watch.zig");
pub const run = @import("trace/run.zig");

pub const Digest = [32]u8;

/// Absolute paths on disk a filtered copy kept (`store_hooks.PathSet`).
pub const PathSet = std.StringHashMapUnmanaged(void);

/// What a stat saw. The order numbers the wire tags.
pub const Kind = enum(u8) {
    missing,
    regular,
    directory,
    symlink,
    other,

    pub fn fromU8(b: u8) ?Kind {
        return if (b <= @backingInt(Kind.other)) @fromBackingInt(b) else null;
    }

    /// The kind the type bits of a mode name.
    pub fn ofMode(m: u16) Kind {
        return switch (m & std.os.linux.S.IFMT) {
            std.os.linux.S.IFREG => .regular,
            std.os.linux.S.IFDIR => .directory,
            std.os.linux.S.IFLNK => .symlink,
            else => .other,
        };
    }

    pub fn of(k: Io.File.Kind) Kind {
        return switch (k) {
            .file => .regular,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        };
    }

    pub fn ofFileType(t: nar.FileType) Kind {
        return switch (t) {
            .regular => .regular,
            .directory => .directory,
            .symlink => .symlink,
            .unknown => .other,
        };
    }

    /// The name `readFileType` and `readDir` give it.
    pub fn nixName(k: Kind) []const u8 {
        return switch (k) {
            .regular => nar.FileType.regular.nixName(),
            .directory => nar.FileType.directory.nixName(),
            .symlink => nar.FileType.symlink.nixName(),
            else => nar.FileType.unknown.nixName(),
        };
    }

    /// The kind's name in `iets cache dump`, spelt as Rust iets's dump spells it.
    pub fn debugName(k: Kind) []const u8 {
        return switch (k) {
            .missing => "Missing",
            .regular => "Regular",
            .directory => "Directory",
            .symlink => "Symlink",
            .other => "Other",
        };
    }
};

/// The filter result of a `filterSource`/`builtins.path` copy: every entry
/// the filter was asked about (hashed) and the ones it accepted.
pub const Filtered = struct {
    /// Null when the accepted set came from outside the tree (a git index),
    /// so entries the set does not name cannot change the result.
    seen_hash: ?Digest,
    /// Absolute paths, sorted.
    accepted: []const []const u8,
};

/// The queries of a working tree that a run may record. An entry holds the
/// query, and validation builds its command line from this table, so a cache
/// directory a stranger can write names no program of its own.
pub const Query = enum(u8) {
    git_ls_files,
    git_status,
    git_head,
    /// Every ref and `HEAD`: what resolving a branch or a tag depends on.
    git_refs,
    /// The file `core.attributesFile` names, which the export of a tree reads.
    git_attributes_file,

    pub fn fromU8(b: u8) ?Query {
        return if (b <= @backingInt(Query.git_attributes_file)) @fromBackingInt(b) else null;
    }

    /// The `Scm` name of the system this query belongs to.
    pub fn scm(_: Query) []const u8 {
        return "git";
    }

    /// `--no-optional-locks` on every query: evaluation writes nothing to a
    /// repository, and `git status` would otherwise rewrite `.git/index`,
    /// which direnv watches.
    pub fn argv(q: Query) []const []const u8 {
        return switch (q) {
            .git_ls_files => &.{ "git", "--no-optional-locks", "ls-files", "-z", "--cached", "--stage", "-v" },
            .git_status => &.{ "git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=no", "--no-renames", "--ignore-submodules=all" },
            .git_head => &.{ "git", "--no-optional-locks", "rev-parse", "--verify", "-q", "HEAD" },
            .git_refs => &.{ "git", "--no-optional-locks", "show-ref", "--head" },
            .git_attributes_file => &.{ "git", "--no-optional-locks", "config", "--path", "--get", "core.attributesFile" },
        };
    }

    /// The query `args` is, or null for a command line this table does not
    /// hold: its answer is then no observation and the run is uncacheable.
    pub fn of(args: []const []const u8) ?Query {
        inline for (comptime std.enums.values(Query)) |q| {
            const want = q.argv();
            if (want.len == args.len) {
                for (want, args) |a, b| {
                    if (!std.mem.eql(u8, a, b)) break;
                } else return q;
            }
        }
        return null;
    }
};

/// One observation of the outside world. The tag order is the wire tag.
pub const Obs = union(enum(u8)) {
    file: struct {
        path: []const u8,
        size: u64,
        mtime_ns: i64,
        /// Changes on every write, and no user program can set it: without
        /// it a `cp -p` in place over a file of the same length is a hit.
        ctime_ns: i64,
        dev: u64,
        ino: u64,
        hash: Digest,
    },
    dir: struct { path: []const u8, hash: Digest },
    stat: struct { path: []const u8, follow: bool, kind: Kind },
    tree: struct {
        root: []const u8,
        nar_hash: Digest,
        stat_hash: Digest,
        filtered: ?Filtered,
        /// The newest `lstat` mtime in the tree, in seconds, when the
        /// evaluation saw it: a `path:` input's `lastModified`.
        newest: ?i64,
    },
    canon: struct { path: []const u8, target: ?[]const u8 },
    /// `value` is a keyed hash, not the value: an entry that held the answer
    /// of every `getEnv` in clear would be a file of the user's secrets.
    env: struct { name: []const u8, value: ?Digest },
    /// A query of an SCM asked in `dir`; `hash` covers its exit status and
    /// stdout.
    cmd: struct { dir: []const u8, query: Query, hash: Digest },
    /// One entry of the input store read during the evaluation. Its name is
    /// the NAR hash of its tree, so the check is that the store still holds
    /// it and that its index is a version this binary reads.
    input: struct { entry: []const u8, version: u8 },

    /// Identity for deduplication: kind, subject and the one flag that makes
    /// two observations of one subject different questions.
    const Subject = struct { kind: std.meta.Tag(Obs), flag: u8, bytes: []const u8 };

    fn subject(o: Obs) Subject {
        const bytes, const flag: u8 = switch (o) {
            .file => |x| .{ x.path, 0 },
            .dir => |x| .{ x.path, 0 },
            .stat => |x| .{ x.path, @intFromBool(x.follow) },
            .tree => |x| .{ x.root, @intFromBool(x.filtered != null) },
            .canon => |x| .{ x.path, 0 },
            .env => |x| .{ x.name, 0 },
            .cmd => |x| .{ x.dir, @backingInt(x.query) },
            .input => |x| .{ x.entry, 0 },
        };
        return .{ .kind = std.meta.activeTag(o), .flag = flag, .bytes = bytes };
    }

    /// `o` with every slice copied into `a`.
    pub fn dupe(o: Obs, a: Allocator) Allocator.Error!Obs {
        var c = o;
        switch (c) {
            .file => |*x| x.path = try a.dupe(u8, x.path),
            .dir => |*x| x.path = try a.dupe(u8, x.path),
            .stat => |*x| x.path = try a.dupe(u8, x.path),
            .tree => |*x| {
                x.root = try a.dupe(u8, x.root);
                if (x.filtered) |*f| {
                    const acc = try a.alloc([]const u8, f.accepted.len);
                    for (f.accepted, acc) |s, *d| d.* = try a.dupe(u8, s);
                    f.accepted = acc;
                }
            },
            .canon => |*x| {
                x.path = try a.dupe(u8, x.path);
                if (x.target) |t| x.target = try a.dupe(u8, t);
            },
            .env => |*x| x.name = try a.dupe(u8, x.name),
            .cmd => |*x| x.dir = try a.dupe(u8, x.dir),
            .input => |*x| x.entry = try a.dupe(u8, x.entry),
        }
        return c;
    }

    /// Every field equal, the bytes of every slice included: what makes
    /// two observations encode the same.
    pub fn eql(a: Obs, b: Obs) bool {
        return deepEql(a, b);
    }
};

/// `a == b` through slices, optionals, structs and tagged unions, where
/// `std.meta.eql` compares a slice by its pointer.
fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names) |name| if (!deepEql(@field(a, name), @field(b, name))) return false;
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            return switch (a) {
                inline else => |x, tag| deepEql(x, @field(b, @tagName(tag))),
            };
        },
        .optional => {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return deepEql(x, y);
        },
        .pointer => |info| {
            comptime std.debug.assert(info.size == .slice);
            if (a.len != b.len) return false;
            if (info.child == u8) return std.mem.eql(u8, a, b);
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        .array => return std.mem.eql(std.meta.Elem(T), &a, &b),
        else => return a == b,
    }
}

/// A hash map context over a value's contents: `autoHash` through every
/// slice, and `deepEql`.
fn Deep(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), k: K) u64 {
            var h: std.hash.Wyhash = .init(0);
            std.hash.autoHashStrat(&h, k, .Deep);
            return h.final();
        }
        pub fn eql(_: @This(), a: K, b: K) bool {
            return deepEql(a, b);
        }
    };
}

/// The recorder behind a `Trace`: the observations, under one lock, and the
/// subjects they name, in an arena the lock also guards.
pub const Recorder = struct {
    gpa: Allocator,
    io: Io,
    lock: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    obs: std.ArrayList(Obs) = .empty,
    uncacheable: std.atomic.Value(bool) = .init(false),
    /// Where the run keeps its entry, and what follows from a revision.
    store: ?*const store.Store = null,

    pub fn init(gpa: Allocator, io: Io, st: ?*const store.Store) Recorder {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa), .store = st };
    }

    pub fn deinit(r: *Recorder) void {
        r.obs.deinit(r.gpa);
        r.arena.deinit();
    }

    pub fn handle(r: *Recorder) Trace {
        return .{ .r = r };
    }
};

/// Recorder handle; the default is off and records nothing. Copies share.
pub const Trace = struct {
    r: ?*Recorder = null,

    pub const off: Trace = .{};

    pub inline fn isOn(t: Trace) bool {
        return t.r != null;
    }

    /// The answer the store of the run keeps for `k`. It follows from the
    /// key alone, so it is no observation. The bytes are `a`'s.
    pub fn kept(t: Trace, a: Allocator, k: []const u8) ?[]u8 {
        const r = t.r orelse return null;
        const s = r.store orelse return null;
        return s.kept(a, k);
    }

    pub fn keep(t: Trace, k: []const u8, answer: []const u8) void {
        const r = t.r orelse return;
        const s = r.store orelse return;
        s.keep(k, answer);
    }

    pub fn record(t: Trace, o: Obs) void {
        const r = t.r orelse return;
        r.lock.lockUncancelable(r.io);
        defer r.lock.unlock(r.io);
        // an observation lost to memory makes the read set incomplete, and an
        // incomplete read set must never be written
        const c = o.dupe(r.arena.allocator()) catch return t.markUncacheable();
        r.obs.append(r.gpa, c) catch return t.markUncacheable();
    }

    pub fn markUncacheable(t: Trace) void {
        if (t.r) |r| r.uncacheable.store(true, .monotonic);
    }

    pub fn isCacheable(t: Trace) bool {
        const r = t.r orelse return false;
        return !r.uncacheable.load(.monotonic);
    }

    /// Every observation, deduplicated on (kind, subject); two observations
    /// of one subject with different values are both kept. The slice is
    /// `a`'s; the subjects stay the recorder's.
    pub fn take(t: Trace, a: Allocator) Allocator.Error![]Obs {
        const r = t.r orelse return &.{};
        r.lock.lockUncancelable(r.io);
        const all = r.obs;
        r.obs = .empty;
        r.lock.unlock(r.io);
        var all_ = all;
        defer all_.deinit(r.gpa);
        return dedupe(a, all.items);
    }

    /// A regular file whose bytes are in memory.
    pub fn file(t: Trace, path: []const u8, meta: sysfs.Meta, bytes: []const u8) void {
        if (!t.isOn()) return;
        t.record(fileObs(path, meta, sha256(bytes)));
    }

    pub fn stat(t: Trace, path: []const u8, follow: bool, kind: Kind) void {
        if (!t.isOn()) return;
        t.record(.{ .stat = .{ .path = path, .follow = follow, .kind = kind } });
    }

    /// Stats `path` and records what it saw; returns the kind.
    pub fn statNow(t: Trace, path: []const u8, follow: bool) Kind {
        const k = statKind(path, follow);
        t.stat(path, follow, k);
        return k;
    }

    pub fn env(t: Trace, name: []const u8) void {
        if (!t.isOn()) return;
        t.record(.{ .env = .{ .name = name, .value = envHash(name) } });
    }

    /// Runs `args` in `dir`, records what it printed, returns its exit status
    /// and stdout (`gpa`'s). A command line `Query` does not hold still runs,
    /// but its answer is no observation: the run is uncacheable instead.
    pub fn cmd(t: Trace, gpa: Allocator, io: Io, dir: []const u8, args: []const []const u8) !CmdOut {
        const out = try runCmd(gpa, io, dir, args);
        if (t.isOn()) {
            if (Query.of(args)) |q| {
                t.record(.{ .cmd = .{ .dir = dir, .query = q, .hash = cmdHash(out.status, out.stdout) } });
            } else t.markUncacheable();
        }
        return out;
    }

    pub fn canon(t: Trace, path: []const u8, target: ?[]const u8) void {
        if (!t.isOn()) return;
        t.record(.{ .canon = .{ .path = path, .target = target } });
    }

    /// A fingerprint accumulator for a tree about to be dumped; null when
    /// tracing is off, so the dump's filter wrapper costs nothing.
    pub fn fp(t: Trace, root: []const u8) ?TreeFp {
        if (!t.isOn()) return null;
        return TreeFp.init(root);
    }

    /// A tree copied to the store. `accepted` is the filter result, null for
    /// an unfiltered copy. `fp_` is what the NAR dump's filter recorded;
    /// without it the tree is walked once more with `lstat` only.
    pub fn tree(t: Trace, root: []const u8, nar_hash: Digest, accepted: ?*const PathSet, fp_: ?*TreeFp) void {
        t.treeWith(root, nar_hash, accepted, true, null, fp_);
    }

    /// An unfiltered tree whose newest mtime the evaluation can see.
    pub fn treeDated(t: Trace, root: []const u8, nar_hash: Digest, newest: i64, fp_: ?*TreeFp) void {
        t.treeWith(root, nar_hash, null, true, newest, fp_);
    }

    /// A tree whose accepted set comes from outside (a git index): only the
    /// accepted entries matter, so no `seen_hash` is kept.
    pub fn treeExternal(t: Trace, root: []const u8, nar_hash: Digest, accepted: *const PathSet, fp_: ?*TreeFp) void {
        t.treeWith(root, nar_hash, accepted, false, null, fp_);
    }

    fn treeWith(t: Trace, root: []const u8, nar_hash: Digest, accepted: ?*const PathSet, keep_seen: bool, newest: ?i64, fp_: ?*TreeFp) void {
        const r = t.r orelse return;
        const hashes = (if (fp_) |f| f.finish() else null) orelse
            treeFingerprint(r.gpa, r.io, root, accepted) catch return t.markUncacheable();
        var filtered: ?Filtered = null;
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(r.gpa);
        if (accepted) |a| {
            // Only the members under this root can decide this tree: the set
            // a caller passes is the enclosing filter's, which for a flake
            // input is every tracked file of the whole input.
            var it = a.keyIterator();
            while (it.next()) |p| if (std.mem.startsWith(u8, p.*, root))
                list.append(r.gpa, p.*) catch return t.markUncacheable();
            std.mem.sortUnstable([]const u8, list.items, {}, lessBytes);
            filtered = .{ .seen_hash = if (keep_seen) hashes.seen else null, .accepted = list.items };
        }
        t.record(.{ .tree = .{ .root = root, .nar_hash = nar_hash, .stat_hash = hashes.stat, .filtered = filtered, .newest = newest } });
    }
};

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Keeps every observation whose (kind, subject) occurs once, and of the
/// rest one per distinct encoding. One pass finds the subjects that repeat
/// and a second encodes only those: comparing each repeat with every earlier
/// observation was quadratic, and 80,000 of one subject took 12 s.
fn dedupe(a: Allocator, all: []const Obs) Allocator.Error![]Obs {
    var counts: std.HashMapUnmanaged(Obs.Subject, u32, Deep(Obs.Subject), 80) = .empty;
    defer counts.deinit(a);
    try counts.ensureTotalCapacity(a, @intCast(all.len));
    for (all) |o| {
        const gop = counts.getOrPutAssumeCapacity(o.subject());
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    var exact: std.HashMapUnmanaged(Obs, void, Deep(Obs), 80) = .empty;
    defer exact.deinit(a);
    var out: std.ArrayList(Obs) = try .initCapacity(a, all.len);
    errdefer out.deinit(a);
    for (all) |o| {
        if (counts.get(o.subject()).? > 1) {
            const gop = try exact.getOrPut(a, o);
            if (gop.found_existing) continue;
        }
        out.appendAssumeCapacity(o);
    }
    return out.toOwnedSlice(a);
}

pub const CmdOut = struct { status: i32, stdout: []u8 };

/// Runs `args` in `dir` and returns its exit status and stdout; stderr is
/// inherited and stdin is empty.
fn runCmd(gpa: Allocator, io: Io, dir: []const u8, args: []const []const u8) !CmdOut {
    var child = try std.process.spawn(io, .{ .argv = args, .cwd = .{ .path = dir }, .stdin = .ignore, .stdout = .pipe, .stderr = .inherit });
    defer child.kill(io);
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &buf);
    const out = r.interface.allocRemaining(gpa, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    errdefer gpa.free(out);
    const term = try child.wait(io);
    const status: i32 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    return .{ .status = status, .stdout = out };
}

/// Asks `q` in `dir` again, for validation. The argv comes from the table,
/// never from the entry.
pub fn runQuery(gpa: Allocator, io: Io, dir: []const u8, q: Query) !CmdOut {
    return runCmd(gpa, io, dir, q.argv());
}

pub fn cmdHash(status: i32, stdout: []const u8) Digest {
    var h: Sha256 = .init(.{});
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(i32, status)));
    h.update(stdout);
    return h.finalResult();
}

pub fn sha256(bytes: []const u8) Digest {
    var d: Digest = undefined;
    Sha256.hash(bytes, &d, .{});
    return d;
}

/// What an `Env` observation records: the keyed hash of the value of `name`,
/// or null when the variable is not set. The key is the cache's own
/// (`cachefs.envKey`), so the entry says whether the value changed and
/// nothing else about it.
pub fn envHash(name: []const u8) ?Digest {
    var zbuf: [4096]u8 = undefined;
    if (name.len >= zbuf.len or std.mem.indexOfScalar(u8, name, 0) != null) return null;
    @memcpy(zbuf[0..name.len], name);
    zbuf[name.len] = 0;
    const v = std.c.getenv(zbuf[0..name.len :0]) orelse return null;
    var h: std.crypto.hash.Blake3 = .init(.{ .key = cachefs.envKey().* });
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, name.len)));
    h.update(name);
    h.update(std.mem.span(v));
    var d: Digest = undefined;
    h.final(&d);
    return d;
}

/// The owner execute bit as the stat hash has always held it: 0o100 or 0.
fn execBit(m: sysfs.Meta) u32 {
    return if (m.mode & 0o100 != 0) 0o100 else 0;
}

/// An mtime this close to the present may share its timestamp with a write
/// still to come; a future one comes from a clock ahead of ours.
const racy_ns: i64 = 2_000_000_000;

/// Never an mtime a file has, so the next validation rehashes.
const untrusted_mtime: i64 = std.math.minInt(i64);

fn nowNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) *% 1_000_000_000 +% ts.nsec;
}

pub fn fileObs(path: []const u8, meta: sysfs.Meta, hash: Digest) Obs {
    const racy = meta.mtime_ns > nowNs() -| racy_ns;
    return .{ .file = .{
        .path = path,
        .size = meta.size,
        .mtime_ns = if (racy) untrusted_mtime else meta.mtime_ns,
        .ctime_ns = meta.ctime_ns,
        .dev = meta.dev,
        .ino = meta.ino,
        .hash = hash,
    } };
}

pub fn statKind(p: []const u8, follow: bool) Kind {
    const m = sysfs.stat(p, follow) catch return .missing;
    return .ofMode(m.mode);
}

/// One listing entry, for `dirListingHash`.
pub const DirEnt = struct { name: []const u8, kind: Kind };

fn entLess(_: void, a: DirEnt, b: DirEnt) bool {
    return switch (std.mem.order(u8, a.name, b.name)) {
        .lt => true,
        .gt => false,
        .eq => @backingInt(a.kind) < @backingInt(b.kind),
    };
}

/// sha256 of the sorted `(name, type)` listing of a directory, as `readDir`
/// reports it. Sorts `entries`.
pub fn dirListingHash(entries: []DirEnt) Digest {
    std.mem.sortUnstable(DirEnt, entries, {}, entLess);
    var h: Sha256 = .init(.{});
    for (entries) |e| {
        h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, e.name.len)));
        h.update(e.name);
        h.update(&.{@backingInt(e.kind)});
    }
    return h.finalResult();
}

/// Scratch for `dirHash`, reused across the directories of one walk: every
/// entry name in one buffer, and a side table that is what gets sorted.
pub const DirBuf = struct {
    names: std.ArrayList(u8) = .empty,
    ents: std.ArrayList(Ent) = .empty,

    const Ent = struct { at: u32, len: u32, kind: u8 };

    pub fn deinit(b: *DirBuf, gpa: Allocator) void {
        b.names.deinit(gpa);
        b.ents.deinit(gpa);
    }
};

pub const ListError = Allocator.Error || error{ FileNotFound, NotDir, Unreadable };

fn listError(e: anyerror) ListError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        else => error.Unreadable,
    };
}

/// The kind of a directory entry: `d_type`, or an `lstat` where the file
/// system gives none.
fn entKind(io: Io, dir: Io.Dir, e: Io.Dir.Entry) Kind {
    if (e.kind != .unknown) return .of(e.kind);
    const st = dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch return .other;
    return .of(st.kind);
}

/// `dirListingHash` of `p`, without an allocation per entry. The digest is
/// the same: the same canonical order over the same fields.
pub fn dirHash(gpa: Allocator, io: Io, p: []const u8, buf: *DirBuf) ListError!Digest {
    buf.names.clearRetainingCapacity();
    buf.ents.clearRetainingCapacity();
    var dir = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch |e| return listError(e);
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch |e| return listError(e)) |e| {
        try buf.ents.append(gpa, .{ .at = @intCast(buf.names.items.len), .len = @intCast(e.name.len), .kind = @backingInt(entKind(io, dir, e)) });
        try buf.names.appendSlice(gpa, e.name);
    }
    const names = buf.names.items;
    std.mem.sortUnstable(DirBuf.Ent, buf.ents.items, names, struct {
        fn lt(n: []const u8, a: DirBuf.Ent, b: DirBuf.Ent) bool {
            return switch (std.mem.order(u8, n[a.at..][0..a.len], n[b.at..][0..b.len])) {
                .lt => true,
                .gt => false,
                .eq => a.kind < b.kind,
            };
        }
    }.lt);
    var h: Sha256 = .init(.{});
    for (buf.ents.items) |e| {
        h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, e.len)));
        h.update(names[e.at..][0..e.len]);
        h.update(&.{e.kind});
    }
    return h.finalResult();
}

/// The `(name, kind)` listing of `p`, names in `a`.
pub fn readDirKinds(a: Allocator, io: Io, p: []const u8) ListError![]DirEnt {
    var dir = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch |e| return listError(e);
    defer dir.close(io);
    var out: std.ArrayList(DirEnt) = .empty;
    var it = dir.iterateAssumeFirstIteration();
    while (it.next(io) catch |e| return listError(e)) |e|
        try out.append(a, .{ .name = try a.dupe(u8, e.name), .kind = entKind(io, dir, e) });
    return out.items;
}

fn accepts(accepted: ?*const PathSet, p: []const u8) bool {
    const a = accepted orelse return true;
    return a.contains(p);
}

pub const TreeHashes = struct { stat: Digest, seen: Digest };

/// The two hashes `treeFingerprint` computes, taken from the NAR dump that
/// is already walking the tree. The dump offers every directory entry to its
/// filter in NAR order, which is the order `treeFingerprint` walks in, so
/// feeding each offer to `entry` reproduces both digests byte for byte.
pub const TreeFp = struct {
    root_len: usize,
    stat_h: Sha256 = .init(.{}),
    seen_h: Sha256 = .init(.{}),
    /// The newest mtime among the root and the accepted entries, in seconds.
    newest: i64 = std.math.minInt(i64),
    ok: bool = true,

    /// Seeds the fingerprint with the root's own `lstat`, the one node the
    /// dump never offers to the filter. Null when the root cannot be read.
    pub fn init(root: []const u8) ?TreeFp {
        var f: TreeFp = .{ .root_len = trimmed(root).len };
        f.statOne(root, "");
        return if (f.ok) f else null;
    }

    /// One directory entry the dump offered to the filter, and what the
    /// filter answered. Rejected entries reach `seen_hash` only.
    pub fn entry(f: *TreeFp, p: []const u8, t: nar.FileType, accepted: bool) void {
        const rel = p[f.root_len..];
        f.seen_h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, rel.len)));
        f.seen_h.update(rel);
        f.seen_h.update(&.{@backingInt(Kind.ofFileType(t))});
        if (accepted) f.statOne(p, rel);
    }

    fn statOne(f: *TreeFp, p: []const u8, rel: []const u8) void {
        const m = sysfs.stat(p, false) catch {
            f.ok = false;
            return;
        };
        f.newest = @max(f.newest, m.mtime_secs);
        hashStat(&f.stat_h, p, rel, m) catch {
            f.ok = false;
        };
    }

    /// The two hashes, or null when any `lstat` on the way failed and the
    /// fingerprint would not be the tree's.
    pub fn finish(f: *TreeFp) ?TreeHashes {
        if (!f.ok) return null;
        return .{ .stat = f.stat_h.finalResult(), .seen = f.seen_h.finalResult() };
    }
};

/// The root as the NAR dump spells it: without a trailing slash.
fn trimmed(root: []const u8) []const u8 {
    var r = root;
    while (r.len > 1 and r[r.len - 1] == '/') r.len -= 1;
    return r;
}

/// One node's `lstat` in the stat hash: relative path, kind, size, mtime,
/// ctime, device, inode, the execute bit, and a link's target.
fn hashStat(h: *Sha256, p: []const u8, rel: []const u8, m: sysfs.Meta) error{Unreadable}!void {
    const kind: Kind = .ofMode(m.mode);
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, rel.len)));
    h.update(rel);
    h.update(&.{@backingInt(kind)});
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, m.size)));
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(i64, m.mtime_ns)));
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(i64, m.ctime_ns)));
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, m.dev)));
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, m.ino)));
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, execBit(m))));
    if (kind == .symlink) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        h.update(readLink(p, &buf) orelse return error.Unreadable);
    }
}

fn readLink(p: []const u8, buf: []u8) ?[]const u8 {
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (p.len >= zbuf.len) return null;
    @memcpy(zbuf[0..p.len], p);
    zbuf[p.len] = 0;
    const rc = std.os.linux.readlink(zbuf[0..p.len :0], buf.ptr, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return buf[0..rc];
}

pub const WalkError = ListError || error{TooDeep};

/// Walks `root` like the NAR dump does (sorted entries, no descent into
/// rejected directories) and hashes what `lstat` reports for every accepted
/// entry (`stat`) and the `(relative path, type)` of every entry the filter
/// saw (`seen`). No file contents are read.
pub fn treeFingerprint(gpa: Allocator, io: Io, root: []const u8, accepted: ?*const PathSet) WalkError!TreeHashes {
    var w: FpWalk = .{ .gpa = gpa, .io = io, .accepted = accepted };
    defer w.deinit();
    try w.path.appendSlice(gpa, trimmed(root));
    w.root_len = w.path.items.len;
    try w.walk(0);
    return .{ .stat = w.stat_h.finalResult(), .seen = w.seen_h.finalResult() };
}

const FpWalk = struct {
    gpa: Allocator,
    io: Io,
    accepted: ?*const PathSet,
    stat_h: Sha256 = .init(.{}),
    seen_h: Sha256 = .init(.{}),
    /// The node's absolute path; its relative part starts at `root_len`.
    path: std.ArrayList(u8) = .empty,
    root_len: usize = 0,

    fn deinit(w: *FpWalk) void {
        w.path.deinit(w.gpa);
    }

    fn walk(w: *FpWalk, depth: usize) WalkError!void {
        if (depth > 64) return error.TooDeep;
        const p = w.path.items;
        const m = sysfs.stat(p, false) catch |e| return switch (e) {
            error.FileNotFound => error.FileNotFound,
            error.NotDir => error.NotDir,
            else => error.Unreadable,
        };
        hashStat(&w.stat_h, p, p[w.root_len..], m) catch return error.Unreadable;
        if (!m.isDir()) return;
        var scratch: std.heap.ArenaAllocator = .init(w.gpa);
        defer scratch.deinit();
        const ents = try readDirKinds(scratch.allocator(), w.io, p);
        std.mem.sortUnstable(DirEnt, ents, {}, entLess);
        const base = w.path.items.len;
        for (ents) |e| {
            try w.path.append(w.gpa, '/');
            try w.path.appendSlice(w.gpa, e.name);
            const rel = w.path.items[w.root_len..];
            w.seen_h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, rel.len)));
            w.seen_h.update(rel);
            w.seen_h.update(&.{@backingInt(e.kind)});
            if (accepts(w.accepted, w.path.items)) try w.walk(depth + 1);
            w.path.shrinkRetainingCapacity(base);
        }
    }
};

/// The NAR filter of a rehash: the recorded filter, with every offer fed to
/// the fingerprint.
const RehashFilter = struct {
    fp: *TreeFp,
    accepted: ?*const PathSet,

    pub fn accept(f: RehashFilter, p: []const u8, t: nar.FileType) error{}!bool {
        const keep = accepts(f.accepted, p);
        f.fp.entry(p, t, keep);
        return keep;
    }
};

pub const Rehashed = struct { nar_hash: Digest, seen: Digest, stat: Digest, newest: i64 };

/// NAR hash of `root` under the recorded filter, plus the `seen` and the
/// current `stat` hash, for the slow path of `Tree` validation.
pub fn treeRehash(gpa: Allocator, io: Io, root: []const u8, accepted: ?*const PathSet) !Rehashed {
    var f = TreeFp.init(root) orelse return error.FileNotFound;
    var d: @import("diag.zig").Diag = .init(gpa);
    defer d.deinit();
    const nh = nar.narHashFiltered(gpa, io, Io.Dir.cwd(), root, .sha256, RehashFilter{ .fp = &f, .accepted = accepted }, &d) catch |e| return switch (e) {
        error.FileNotFound => error.FileNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreadable,
    };
    const newest = f.newest;
    const h = f.finish() orelse return error.Unreadable;
    var digest: Digest = undefined;
    @memcpy(&digest, nh.hash.bytes());
    return .{ .nar_hash = digest, .seen = h.seen, .stat = h.stat, .newest = newest };
}

/// The 32 bytes of a sha256 `Hash`.
pub fn hashToDigest(h: anytype) Digest {
    var d: Digest = undefined;
    @memcpy(&d, h.bytes()[0..32]);
    return d;
}

test {
    std.testing.refAllDecls(@This());
}

const testing = std.testing;

fn testRecorder() Recorder {
    return .init(testing.allocator, testing.io, null);
}

test "dedupe keeps conflicting values" {
    var r = testRecorder();
    defer r.deinit();
    const t = r.handle();
    const o1: Obs = .{ .env = .{ .name = "A", .value = @splat(1) } };
    const o2: Obs = .{ .env = .{ .name = "A", .value = @splat(2) } };
    t.record(o1);
    t.record(o1);
    t.record(o2);
    t.record(o2);
    const v = try t.take(testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqual(2, v.len);
    try testing.expect(v[0].eql(o1) and v[1].eql(o2));
}

test "dedupe of many repeats is linear" {
    var r = testRecorder();
    defer r.deinit();
    const t = r.handle();
    for (0..80_000) |i| t.record(.{ .stat = .{ .path = "/a", .follow = true, .kind = if (i % 2 == 0) .regular else .missing } });
    const t0 = Io.Clock.awake.now(testing.io);
    const v = try t.take(testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqual(2, v.len);
    try testing.expect(Io.Clock.awake.now(testing.io).nanoseconds - t0.nanoseconds < 2 * std.time.ns_per_s);
}

test "only a named query is an observation" {
    for (std.enums.values(Query)) |q| {
        try testing.expectEqual(q, Query.of(q.argv()).?);
        try testing.expectEqual(q, Query.fromU8(@backingInt(q)).?);
    }
    try testing.expect(Query.of(&.{ "sh", "-c" }) == null);
    try testing.expect(Query.fromU8(std.enums.values(Query).len) == null);
    var r = testRecorder();
    defer r.deinit();
    const t = r.handle();
    try testing.expect(t.isCacheable());
    const out = try t.cmd(testing.allocator, testing.io, "/", &.{"true"});
    testing.allocator.free(out.stdout);
    try testing.expect(!t.isCacheable());
    const v = try t.take(testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqual(0, v.len);
}

/// A tree of a few files, a subdirectory, a symlink and an executable.
pub fn testTree(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "world\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x.sh", .data = "#!/bin/sh\n", .flags = .{ .permissions = .fromMode(0o755) } });
    try tmp.dir.symLink(io, "a.txt", "link", .{});
}

fn tmpPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(testing.io, buf)];
}

test "the dump's fingerprint matches the separate walk" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testTree(&tmp);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &pbuf);
    var set: PathSet = .empty;
    defer set.deinit(testing.allocator);
    const a = try std.fs.path.join(testing.allocator, &.{ dir, "a.txt" });
    defer testing.allocator.free(a);
    const s = try std.fs.path.join(testing.allocator, &.{ dir, "sub" });
    defer testing.allocator.free(s);
    try set.put(testing.allocator, a, {});
    try set.put(testing.allocator, s, {});
    for ([_]?*const PathSet{ null, &set }) |accepted| {
        var f = TreeFp.init(dir).?;
        var d: @import("diag.zig").Diag = .init(testing.allocator);
        defer d.deinit();
        _ = try nar.narHashFiltered(testing.allocator, testing.io, Io.Dir.cwd(), dir, .sha256, RehashFilter{ .fp = &f, .accepted = accepted }, &d);
        const got = f.finish().?;
        const want = try treeFingerprint(testing.allocator, testing.io, dir, accepted);
        try testing.expectEqualSlices(u8, &want.stat, &got.stat);
        try testing.expectEqualSlices(u8, &want.seen, &got.seen);
    }
}

test "the fingerprint changes with content, size and seen entries" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testTree(&tmp);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmpPath(&tmp, &pbuf);
    const a = try treeFingerprint(testing.allocator, testing.io, dir, null);
    const b = try treeFingerprint(testing.allocator, testing.io, dir, null);
    try testing.expectEqualSlices(u8, &a.stat, &b.stat);
    try testing.expectEqualSlices(u8, &a.seen, &b.seen);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new-file", .data = "x" });
    const c = try treeFingerprint(testing.allocator, testing.io, dir, null);
    try testing.expect(!std.mem.eql(u8, &a.stat, &c.stat));
    try testing.expect(!std.mem.eql(u8, &a.seen, &c.seen));
    const rh = try treeRehash(testing.allocator, testing.io, dir, null);
    const nf = try std.fs.path.join(testing.allocator, &.{ dir, "new-file" });
    defer testing.allocator.free(nf);
    try testing.expectEqual((try sysfs.stat(nf, false)).mtime_secs, rh.newest);
    try testing.expectEqualSlices(u8, &c.stat, &rh.stat);
    try testing.expectEqualSlices(u8, &c.seen, &rh.seen);
    var d: @import("diag.zig").Diag = .init(testing.allocator);
    defer d.deinit();
    const want = try nar.narHash(testing.allocator, testing.io, Io.Dir.cwd(), dir, &d);
    try testing.expectEqualSlices(u8, want.bytes(), &rh.nar_hash);
}
