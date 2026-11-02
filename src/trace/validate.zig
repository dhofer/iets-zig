//! Checks a recorded read set against the world, on a few threads. Any
//! mismatch is a miss. Stat-only checks come first; a file whose stat
//! changed is rehashed and accepted when its content did not. The messages
//! are Rust iets's, word for word.

const std = @import("std");
const text = @import("../syntax/text.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const trace = @import("../trace.zig");
const Obs = trace.Obs;
const Kind = trace.Kind;
const Digest = trace.Digest;
const sysfs = @import("../sys/fs.zig");

pub const Report = struct {
    entries: usize = 0,
    /// Files and trees whose contents were rehashed because their stat changed.
    rehashed: usize = 0,
    /// Entries whose stat fields were refreshed; the read set should be rewritten.
    refreshed: usize = 0,
};

/// The input store, which an `Input` observation asks whether it still holds
/// an entry (`treestore.Store.has`).
pub const Inputs = struct {
    ctx: *anyopaque,
    has: *const fn (ctx: *anyopaque, name: []const u8, version: u8) bool,
};

/// What validation needs besides the read set.
pub const Env = struct {
    gpa: Allocator,
    io: Io,
    inputs: ?Inputs = null,
};

/// The lowest-indexed observation that no longer holds, and why: the read
/// set has one order, so one change always names the same observation,
/// whichever thread saw it. `why` is `gpa`'s.
pub const Result = union(enum) { ok: Report, mismatch: []u8 };

const Outcome = union(enum) {
    same,
    /// Content still matches; the entry's stat fields are stale.
    refresh: Obs,
    changed: []u8,
};

fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .missing => "missing",
        .regular => "a regular file",
        .directory => "a directory",
        .symlink => "a symbolic link",
        .other => "another kind of file",
    };
}

fn changed(a: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Outcome {
    return .{ .changed = try std.fmt.allocPrint(a, fmt, args) };
}

/// Why a path no longer reads: it is not there, or it is there and the read
/// failed. The message says which, because the two need different fixes.
fn unreadable(a: Allocator, path: []const u8, e: anyerror) Allocator.Error!Outcome {
    const what = if (e == error.FileNotFound) "is gone" else "cannot be read";
    return changed(a, "{s} {s}", .{ try text.lossyAlloc(a, path), what });
}

/// sha256 of a file's bytes without holding them.
fn fileSha256(io: Io, p: []const u8) !Digest {
    const f = try Io.Dir.cwd().openFile(io, p, .{});
    defer f.close(io);
    var buf: [1 << 16]u8 = undefined;
    var h: Sha256 = .init(.{});
    var off: u64 = 0;
    while (true) {
        const n = try f.readPositional(io, &.{&buf}, off);
        if (n == 0) break;
        h.update(buf[0..n]);
        off += n;
    }
    return h.finalResult();
}

fn check(env: *const Env, a: Allocator, o: Obs, rehashed: *std.atomic.Value(usize), dirs: *trace.DirBuf) Allocator.Error!Outcome {
    switch (o) {
        .file => |x| {
            const m = sysfs.stat(x.path, true) catch |e| return unreadable(a, x.path, e);
            if (!m.isFile())
                return changed(a, "{s} is now {s}, not a regular file", .{ try text.lossyAlloc(a, x.path), kindName(.ofMode(m.mode)) });
            if (m.size == x.size and m.mtime_ns == x.mtime_ns and m.ctime_ns == x.ctime_ns and m.dev == x.dev and m.ino == x.ino)
                return .same;
            _ = rehashed.fetchAdd(1, .monotonic);
            const now = fileSha256(env.io, x.path) catch |e| return unreadable(a, x.path, e);
            if (!std.mem.eql(u8, &now, &x.hash)) return changed(a, "{s} changed", .{try text.lossyAlloc(a, x.path)});
            return .{ .refresh = trace.fileObs(x.path, m, x.hash) };
        },
        .dir => |x| {
            const now = trace.dirHash(env.gpa, env.io, x.path, dirs) catch |e| return unreadable(a, x.path, e);
            if (std.mem.eql(u8, &now, &x.hash)) return .same;
            return changed(a, "directory {s} has different entries", .{try text.lossyAlloc(a, x.path)});
        },
        .stat => |x| {
            const now = trace.statKind(x.path, x.follow);
            if (now == x.kind) return .same;
            const p = try text.lossyAlloc(a, x.path);
            if (now == .missing) return changed(a, "{s} is gone", .{p});
            if (x.kind == .missing) return changed(a, "{s} now exists", .{p});
            return changed(a, "{s} is now {s}, not {s}", .{ p, kindName(now), kindName(x.kind) });
        },
        .tree => |x| {
            var set: trace.PathSet = .empty;
            const accepted: ?*const trace.PathSet = if (x.filtered) |f| blk: {
                try set.ensureTotalCapacity(a, @intCast(f.accepted.len));
                for (f.accepted) |p| set.putAssumeCapacity(p, {});
                break :blk &set;
            } else null;
            const fp = trace.treeFingerprint(env.gpa, env.io, x.root, accepted) catch |e| return unreadable(a, x.root, e);
            if (std.mem.eql(u8, &fp.stat, &x.stat_hash)) return .same;
            _ = rehashed.fetchAdd(1, .monotonic);
            const rh = trace.treeRehash(env.gpa, env.io, x.root, accepted) catch |e| return unreadable(a, x.root, e);
            const seen_moved = if (x.filtered) |f| if (f.seen_hash) |s| !std.mem.eql(u8, &s, &rh.seen) else false else false;
            if (!std.mem.eql(u8, &rh.nar_hash, &x.nar_hash) or seen_moved)
                return changed(a, "source tree {s} changed", .{try text.lossyAlloc(a, x.root)});
            if (x.newest) |n| if (n != rh.newest)
                return changed(a, "source tree {s} has another modification time", .{try text.lossyAlloc(a, x.root)});
            var r = o;
            r.tree.stat_hash = rh.stat;
            return .{ .refresh = r };
        },
        .canon => |x| {
            const now: ?[]const u8 = Io.Dir.cwd().realPathFileAlloc(env.io, x.path, a) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            const same = if (now) |n| (if (x.target) |t| std.mem.eql(u8, n, t) else false) else x.target == null;
            if (same) return .same;
            return changed(a, "{s} resolves to a different path", .{try text.lossyAlloc(a, x.path)});
        },
        .env => |x| {
            const now = trace.envHash(x.name);
            const what = if (now) |n| (if (x.value) |v| (if (std.mem.eql(u8, &n, &v)) return .same else "changed") else "is now set") else if (x.value == null) return .same else "is no longer set";
            return changed(a, "environment variable ${s} {s}", .{ try text.lossyAlloc(a, x.name), what });
        },
        .cmd => |x| {
            if (trace.runQuery(env.gpa, env.io, x.dir, x.query)) |out| {
                defer env.gpa.free(out.stdout);
                if (std.mem.eql(u8, &trace.cmdHash(out.status, out.stdout), &x.hash)) return .same;
            } else |_| {}
            const argv = try std.mem.join(a, " ", x.query.argv());
            return changed(a, "the output of `{s}` in {s} changed", .{ argv, try text.lossyAlloc(a, x.dir) });
        },
        // One `stat` per entry, no bytes: the name is the content address, so
        // an entry that is still there still holds what the run read.
        .input => |x| {
            const in = env.inputs orelse return changed(a, "input store entry {s} is gone", .{try text.lossyAlloc(a, x.entry)});
            if (in.has(in.ctx, x.entry, x.version)) return .same;
            return changed(a, "input store entry {s} is gone", .{try text.lossyAlloc(a, x.entry)});
        },
    }
}

const Shared = struct {
    env: *const Env,
    obs: []Obs,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    rehashed: std.atomic.Value(usize) = .init(0),
    lock: Io.Mutex = .init,
    /// The lowest failing index and its message (`gpa`'s).
    first: ?struct { i: usize, why: []u8 } = null,
    refreshes: std.ArrayList(struct { i: usize, o: Obs }) = .empty,
    oom: bool = false,

    fn work(s: *Shared) void {
        var dirs: trace.DirBuf = .{};
        defer dirs.deinit(s.env.gpa);
        var scratch: std.heap.ArenaAllocator = .init(s.env.gpa);
        defer scratch.deinit();
        while (!s.failed.load(.monotonic)) {
            const i = s.next.fetchAdd(1, .monotonic);
            if (i >= s.obs.len) break;
            _ = scratch.reset(.retain_capacity);
            const out = check(s.env, scratch.allocator(), s.obs[i], &s.rehashed, &dirs) catch {
                s.lock.lockUncancelable(s.env.io);
                s.oom = true;
                s.lock.unlock(s.env.io);
                s.failed.store(true, .monotonic);
                break;
            };
            switch (out) {
                .same => {},
                .refresh => |o| {
                    s.lock.lockUncancelable(s.env.io);
                    defer s.lock.unlock(s.env.io);
                    // the subjects of a refresh are the recorded ones; only
                    // the stat fields are new
                    s.refreshes.append(s.env.gpa, .{ .i = i, .o = o }) catch {
                        s.oom = true;
                    };
                },
                .changed => |why_| {
                    const better = @import("../source/scm.zig").changed(s.env.gpa, s.obs[i]);
                    s.failed.store(true, .monotonic);
                    s.lock.lockUncancelable(s.env.io);
                    defer s.lock.unlock(s.env.io);
                    if (s.first == null or i < s.first.?.i) {
                        if (s.first) |f| s.env.gpa.free(f.why);
                        const why = better orelse (s.env.gpa.dupe(u8, why_) catch {
                            s.oom = true;
                            break;
                        });
                        s.first = .{ .i = i, .why = why };
                    } else if (better) |b| s.env.gpa.free(b);
                    break;
                },
            }
        }
    }
};

/// Validates every observation on `threads` threads. On success the
/// refreshed entries are written back into `obs`. The mismatch names the
/// lowest-indexed observation that failed: the threads stop at the first
/// failure, but every index below it was already handed out and a thread
/// finishes the check it started, so the lowest failing index is among the
/// ones seen.
pub fn validate(env: *const Env, obs: []Obs, threads_: usize) Allocator.Error!Result {
    var s: Shared = .{ .env = env, .obs = obs };
    defer s.refreshes.deinit(env.gpa);
    const threads = std.math.clamp(threads_, 1, @max(obs.len, 1));
    var ts: [16]?std.Thread = @splat(null);
    for (1..@min(threads, ts.len)) |i| ts[i] = std.Thread.spawn(.{}, Shared.work, .{&s}) catch null;
    s.work();
    for (ts) |t| if (t) |x| x.join();
    if (s.oom) {
        if (s.first) |f| env.gpa.free(f.why);
        return error.OutOfMemory;
    }
    if (s.failed.load(.monotonic)) return .{ .mismatch = s.first.?.why };
    for (s.refreshes.items) |r| obs[r.i] = r.o;
    return .{ .ok = .{ .entries = obs.len, .rehashed = s.rehashed.load(.monotonic), .refreshed = s.refreshes.items.len } };
}

const testing = std.testing;

fn setMtime(dir: Io.Dir, name: []const u8, secs: i64) !void {
    const ts: Io.Timestamp = .fromNanoseconds(@as(i96, secs) * std.time.ns_per_s);
    try dir.setTimestamps(testing.io, name, .{ .modify_timestamp = .{ .new = ts }, .access_timestamp = .{ .new = ts } });
}

fn nowSecs() i64 {
    return @intCast(@divFloor(Io.Clock.real.now(testing.io).nanoseconds, std.time.ns_per_s));
}

const test_env: Env = .{ .gpa = testing.allocator, .io = testing.io };

fn expectOk(obs: []Obs, threads: usize) !Report {
    return switch (try validate(&test_env, obs, threads)) {
        .ok => |r| r,
        .mismatch => |m| {
            defer testing.allocator.free(m);
            std.debug.print("unexpected mismatch: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectMismatch(obs: []Obs, threads: usize) ![]u8 {
    return switch (try validate(&test_env, obs, threads)) {
        .ok => error.TestUnexpectedResult,
        .mismatch => |m| m,
    };
}

fn filePath(tmp: *testing.TmpDir, buf: []u8, name: []const u8) ![]const u8 {
    const n = try tmp.dir.realPath(testing.io, buf);
    return std.fmt.bufPrint(buf[n..], "{s}/{s}", .{ buf[0..n], name });
}

test "a file written just now is rehashed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.nix", .data = "1" });
    var buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const p = try filePath(&tmp, &buf, "a.nix");
    var obs = [_]Obs{trace.fileObs(p, try sysfs.stat(p, true), trace.sha256("1"))};
    try testing.expectEqual(1, (try expectOk(&obs, 2)).rehashed);
    try setMtime(tmp.dir, "a.nix", nowSecs() + 60);
    obs[0] = trace.fileObs(p, try sysfs.stat(p, true), trace.sha256("1"));
    try testing.expectEqual(1, (try expectOk(&obs, 2)).rehashed);
}

test "a touch refreshes, an edit misses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.nix", .data = "1" });
    try setMtime(tmp.dir, "a.nix", nowSecs() - 60);
    var buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const p = try filePath(&tmp, &buf, "a.nix");
    var obs = [_]Obs{trace.fileObs(p, try sysfs.stat(p, true), trace.sha256("1"))};
    var r = try expectOk(&obs, 2);
    try testing.expectEqual(0, r.rehashed + r.refreshed);
    try setMtime(tmp.dir, "a.nix", nowSecs() - 30);
    r = try expectOk(&obs, 2);
    try testing.expectEqual(1, r.rehashed);
    try testing.expectEqual(1, r.refreshed);
    r = try expectOk(&obs, 2);
    try testing.expectEqual(0, r.rehashed + r.refreshed);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.nix", .data = "2" });
    testing.allocator.free(try expectMismatch(&obs, 2));
}

test "what a recorder stores validates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "flake.nix", .data = "1" });
    try setMtime(tmp.dir, "flake.nix", nowSecs() - 60);
    var buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const p = try filePath(&tmp, &buf, "flake.nix");
    var mbuf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const missing = try filePath(&tmp, &mbuf, "missing");
    var rec: trace.Recorder = .init(testing.allocator, testing.io, null);
    defer rec.deinit();
    const t = rec.handle();
    t.file(p, try sysfs.stat(p, true), "1");
    _ = t.statNow(missing, true);
    const obs = try t.take(testing.allocator);
    defer testing.allocator.free(obs);
    try testing.expectEqual(2, obs.len);
    const r = try expectOk(obs, 2);
    try testing.expectEqual(0, r.rehashed + r.refreshed);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "flake.nix", .data = "22" });
    testing.allocator.free(try expectMismatch(obs, 2));
}

test "a resolved path validates as the same" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.nix", .data = "1" });
    var buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const p = try filePath(&tmp, &buf, "a.nix");
    const resolved = try Io.Dir.cwd().realPathFileAlloc(testing.io, p, testing.allocator);
    defer testing.allocator.free(resolved);
    var rec: trace.Recorder = .init(testing.allocator, testing.io, null);
    defer rec.deinit();
    rec.handle().canon(p, resolved);
    const obs = try rec.handle().take(testing.allocator);
    defer testing.allocator.free(obs);
    _ = try expectOk(obs, 2);
}

test "a copy in place that keeps the stat still misses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.nix", .data = "AAAA" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.nix", .data = "BBBB" });
    const fixed: i64 = 1_000_000_000;
    try setMtime(tmp.dir, "a.nix", fixed);
    try setMtime(tmp.dir, "b.nix", fixed);
    var buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const p = try filePath(&tmp, &buf, "a.nix");
    var obuf: [2 * std.fs.max_path_bytes]u8 = undefined;
    const other = try filePath(&tmp, &obuf, "b.nix");
    const m = try sysfs.stat(p, true);
    var obs = [_]Obs{trace.fileObs(p, m, trace.sha256("AAAA"))};
    _ = try expectOk(&obs, 1);
    // the kernel stamps ctime from a clock that ticks every few
    // milliseconds, so wait until a write can get a new one
    while (true) {
        try setMtime(tmp.dir, "b.nix", fixed);
        if ((try sysfs.stat(other, true)).ctime_ns != m.ctime_ns) break;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    const f = try tmp.dir.openFile(testing.io, "a.nix", .{ .mode = .write_only });
    try f.writePositionalAll(testing.io, "BBBB", 0);
    f.close(testing.io);
    try setMtime(tmp.dir, "a.nix", fixed);
    const now = try sysfs.stat(p, true);
    try testing.expectEqual(m.size, now.size);
    try testing.expectEqual(m.mtime_ns, now.mtime_ns);
    try testing.expectEqual(m.ino, now.ino);
    testing.allocator.free(try expectMismatch(&obs, 1));
}

test "dir, stat and env checks" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x", .data = "" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ents = try trace.readDirKinds(arena.allocator(), testing.io, p);
    var obs = [_]Obs{
        .{ .dir = .{ .path = p, .hash = trace.dirListingHash(ents) } },
        .{ .stat = .{ .path = p, .follow = true, .kind = .directory } },
        .{ .env = .{ .name = "IETS_TRACE_TEST_UNSET", .value = null } },
    };
    _ = try expectOk(&obs, 3);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "y", .data = "" });
    testing.allocator.free(try expectMismatch(&obs, 3));
}

test "the lowest failing observation is the one reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var obs: [64]Obs = undefined;
    for (&obs, 0..) |*o, n| o.* = if (n % 7 == 3)
        .{ .stat = .{ .path = try std.fmt.allocPrint(arena.allocator(), "/nonexistent/iets-validate-{d}", .{n}), .follow = true, .kind = .regular } }
    else
        .{ .env = .{ .name = "IETS_TRACE_TEST_UNSET", .value = null } };
    for (0..50) |_| {
        const m = try expectMismatch(&obs, 4);
        defer testing.allocator.free(m);
        try testing.expectEqualStrings("/nonexistent/iets-validate-3 is gone", m);
    }
}

test "the buffered dir hash agrees with the listing hash" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "b", "a", "B", "A", "a-long-one", "a0", "_0", "zz", "10", "2", "non\xffutf8" }) |n|
        try tmp.dir.writeFile(testing.io, .{ .sub_path = n, .data = "x" });
    try tmp.dir.createDirPath(testing.io, "adir");
    try tmp.dir.symLink(testing.io, "a", "alink", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const want = trace.dirListingHash(try trace.readDirKinds(arena.allocator(), testing.io, p));
    var db: trace.DirBuf = .{};
    defer db.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &want, &try trace.dirHash(testing.allocator, testing.io, p, &db));
    var tmp2 = testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    var buf2: [std.fs.max_path_bytes]u8 = undefined;
    const e = buf2[0..try tmp2.dir.realPath(testing.io, &buf2)];
    const none = trace.dirListingHash(try trace.readDirKinds(arena.allocator(), testing.io, e));
    try testing.expectEqualSlices(u8, &none, &try trace.dirHash(testing.allocator, testing.io, e, &db));
    try testing.expectEqualSlices(u8, &want, &try trace.dirHash(testing.allocator, testing.io, p, &db));
}
