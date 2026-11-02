//! The on-disk tracing cache: one directory per key, holding one file that
//! carries every part of the entry. The file is written under a temporary
//! name and renamed into place, so one rename publishes the whole entry and
//! a reader that opened it holds one generation of it. `cachefs` holds the
//! store-level structure (version, writer lock, sweeps) this shares with the
//! IR cache. The bytes are the ones Rust iets writes.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const cachefs = @import("../cachefs.zig");
const wire = @import("wire.zig");

/// The one file of an entry directory.
pub const entry_name = "entry";
/// Leads the file; the key holds the build id, so an older binary's entries
/// are never read and this only has to catch bytes iets did not write.
const version: u8 = 2;
/// The version byte, the number of parts, and the integrity check over the
/// key and the rest of the file.
const header = 2 + cachefs.sum_len;
/// One part's place in the file: tag, offset, length.
const slot = 17;

/// What an entry holds. Which parts exist depends on the subcommand. The
/// value is the tag in the file.
pub const Part = enum(u8) {
    /// The observations a hit validates.
    readset = 0,
    /// The stdout bytes of an `eval`, or the roots of a `build`.
    result = 1,
    /// Every derivation a `build` evaluation produced.
    drvs = 2,
    /// Where each source's bytes were.
    sources = 3,
    /// The lint warnings the run printed; a hit prints them again.
    warnings = 4,
    /// Empty, and there when the run's top-level flake had a `nixConfig`.
    nix_config = 5,
};

/// One generation of one entry: the bytes read from the file that was open
/// and where its parts are. Reading the whole file through one descriptor is
/// what makes the snapshot, and the integrity check needs all of it before
/// any part is decoded.
pub const Entry = struct {
    data: []u8,
    slots: []Slot,

    const Slot = struct { tag: u8, at: u64, n: u64 };

    pub fn deinit(e: *Entry, gpa: Allocator) void {
        gpa.free(e.data);
        gpa.free(e.slots);
    }

    /// Null for any bytes that are not the entry this binary wrote for `k`.
    /// The check covers the key, so an entry copied from another one is not
    /// an entry here either. Takes `data`.
    fn parse(gpa: Allocator, data: []u8, k: []const u8) Allocator.Error!?Entry {
        errdefer gpa.free(data);
        if (data.len < header or data[0] != version) {
            gpa.free(data);
            return null;
        }
        const sum = cachefs.checksum(k, &.{ data[0..2], data[header..] });
        if (!std.mem.eql(u8, data[2..header], &sum)) {
            gpa.free(data);
            return null;
        }
        const count: usize = data[1];
        const payload = header + count * slot;
        if (payload > data.len) {
            gpa.free(data);
            return null;
        }
        const slots = try gpa.alloc(Slot, count);
        for (slots, 0..) |*s, i| {
            const b = data[header + i * slot ..][0..slot];
            const at = std.mem.readInt(u64, b[1..9], .little);
            const n = std.mem.readInt(u64, b[9..17], .little);
            const end = std.math.add(u64, at, n) catch std.math.maxInt(u64);
            if (at < payload or end > data.len) {
                gpa.free(slots);
                gpa.free(data);
                return null;
            }
            s.* = .{ .tag = b[0], .at = at, .n = n };
        }
        return .{ .data = data, .slots = slots };
    }

    /// The entry file at `path`, for `iets cache dump`. The key is the name
    /// of the directory the entry lives in, which is how a store names it.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!?Entry {
        const dir = std.fs.path.dirname(path) orelse return null;
        const k = std.fs.path.basename(dir);
        const data = (try readFound(gpa, io, path)) orelse return null;
        return parse(gpa, data, k);
    }

    /// The bytes of one part, from this generation of the entry; they point
    /// into the entry.
    pub fn part(e: *const Entry, p: Part) ?[]const u8 {
        for (e.slots) |s| if (s.tag == @backingInt(p)) return e.data[@intCast(s.at)..][0..@intCast(s.n)];
        return null;
    }
};

/// The whole file at `path` when it opens as an entry can; null otherwise.
fn readFound(gpa: Allocator, io: Io, path: []const u8) Allocator.Error!?[]u8 {
    return switch (cachefs.entries.openEntry(io, path)) {
        .file => |f| readAll(gpa, io, f.file, f.size),
        else => null,
    };
}

fn readAll(gpa: Allocator, io: Io, f: Io.File, size: u64) Allocator.Error!?[]u8 {
    defer f.close(io);
    const data = try gpa.alloc(u8, @intCast(size));
    const n = f.readPositionalAll(io, data, 0) catch {
        gpa.free(data);
        return null;
    };
    if (n != data.len) {
        gpa.free(data);
        return null;
    }
    return data;
}

/// What a key names on disk.
pub const Opened = union(enum) {
    /// No entry, or one that does not open now: a miss, and nothing to
    /// report or wipe.
    none,
    /// An entry whose bytes are not one: poison and wipe.
    bad,
    entry: Entry,

    pub fn deinit(o: *Opened, gpa: Allocator) void {
        switch (o.*) {
            .entry => |*e| e.deinit(gpa),
            else => {},
        }
    }
};

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    /// `<cache root>/trace`: the directory the user names is never a removal target.
    root: []const u8,

    /// The store under the cache root `cache_root`.
    pub fn locate(gpa: Allocator, io: Io, cache_root: []const u8) Allocator.Error!Store {
        return .{ .gpa = gpa, .io = io, .root = try std.fs.path.join(gpa, &.{ cache_root, "trace" }) };
    }

    pub fn deinit(s: *Store) void {
        s.gpa.free(s.root);
    }

    /// `<root>/<key>`, in `buf`.
    pub fn entryDir(s: *const Store, buf: []u8, k: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ s.root, k }) catch "";
    }

    /// `<root>/<key>/entry`, in `buf`.
    pub fn entryPath(s: *const Store, buf: []u8, k: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}/" ++ entry_name, .{ s.root, k }) catch "";
    }

    /// Opens the entry once. Every part a run reads comes from the returned
    /// `Entry`, so a sibling that publishes meanwhile cannot be read half.
    pub fn open(s: *const Store, k: []const u8) Allocator.Error!Opened {
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const path = s.entryPath(&buf, k);
        const data = switch (cachefs.entries.openEntry(s.io, path)) {
            .file => |f| (try readAll(s.gpa, s.io, f.file, f.size)) orelse return .none,
            .missing => return .none,
            .foreign => return .bad,
        };
        return if (try Entry.parse(s.gpa, data, k)) |e| .{ .entry = e } else .bad;
    }

    pub const PartBytes = struct { part: Part, bytes: []const u8 };

    /// `TooLarge`, or the error of the step that failed.
    pub const PublishError = anyerror;

    /// Publishes `parts` as the whole entry, in one rename under one hold of
    /// the store lock. False when a sibling writer held that lock: the entry
    /// stays the generation it was and the next run misses.
    pub fn publish(s: *const Store, k: []const u8, parts: []const PartBytes) PublishError!bool {
        if (parts.len > 255) return error.TooLarge;
        const head = [2]u8{ version, @intCast(parts.len) };
        // an entry over the cap is one no reader will open, so write nothing
        // rather than seconds of bytes that are dead on arrival
        var total: u64 = header + parts.len * slot;
        for (parts) |p| total += p.bytes.len;
        if (total > cachefs.max_entry) return error.TooLarge;
        var table: [255 * slot]u8 = undefined;
        var at: u64 = header + parts.len * slot;
        for (parts, 0..) |p, i| {
            const b = table[i * slot ..][0..slot];
            b[0] = @backingInt(p.part);
            std.mem.writeInt(u64, b[1..9], at, .little);
            std.mem.writeInt(u64, b[9..17], p.bytes.len, .little);
            at += p.bytes.len;
        }
        const tbl = table[0 .. parts.len * slot];
        var covered: [258][]const u8 = undefined;
        covered[0] = &head;
        covered[1] = tbl;
        for (parts, 0..) |p, i| covered[2 + i] = p.bytes;
        const sum = cachefs.checksum(k, covered[0 .. 2 + parts.len]);
        var chunks: [259][]const u8 = undefined;
        chunks[0] = &head;
        chunks[1] = &sum;
        chunks[2] = tbl;
        for (parts, 0..) |p, i| chunks[3 + i] = p.bytes;
        var root = try Dir.cwd().openDir(s.io, s.root, .{});
        defer root.close(s.io);
        const l = (try cachefs.tryWriteLock(s.io, root)) orelse return false;
        defer cachefs.unlock(s.io, l);
        // under the lock, so a sibling's discard cannot remove it before the rename
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const dir = s.entryDir(&buf, k);
        try cachefs.entries.createDir(s.io, dir);
        var d = try Dir.cwd().openDir(s.io, dir, .{});
        defer d.close(s.io);
        try cachefs.writeAtomic(s.io, d, entry_name, chunks[0 .. 3 + parts.len]);
        return true;
    }

    /// An entry that holds an answer and an empty read set: the answer
    /// follows from the key, so nothing can make it stale.
    pub fn keep(s: *const Store, k: []const u8, answer: []const u8) void {
        const none = wire.encodeReadset(s.gpa, &.{}) catch return;
        defer s.gpa.free(none);
        _ = s.publish(k, &.{ .{ .part = .result, .bytes = answer }, .{ .part = .readset, .bytes = none } }) catch {};
    }

    /// The answer that `keep` put under `k`, in `a`.
    pub fn kept(s: *const Store, a: Allocator, k: []const u8) ?[]u8 {
        var o = s.open(k) catch return null;
        defer o.deinit(s.gpa);
        switch (o) {
            .none => return null,
            .bad => {
                s.discard(k, &o);
                return null;
            },
            .entry => |*e| {
                s.touch(k);
                return a.dupe(u8, e.part(.result) orelse return null) catch null;
            },
        }
    }

    /// A hit marks the entry as used; renaming a file into the directory
    /// already does that, so a republished entry needs no touch.
    pub fn touch(s: *const Store, k: []const u8) void {
        var buf: [Dir.max_path_bytes]u8 = undefined;
        cachefs.entries.touch(s.io, s.entryDir(&buf, k));
    }

    /// Poison and wipe, never repair: an entry that does not decode goes.
    /// `rejected` is what the caller opened. A sibling may have published a
    /// good generation since, so the entry goes only if, under the writer
    /// lock, it is still bad or still the bytes the caller rejected. A
    /// sibling that holds the lock past its timeout keeps the entry for a
    /// later run to judge.
    pub fn discard(s: *const Store, k: []const u8, rejected: *const Opened) void {
        var root = Dir.cwd().openDir(s.io, s.root, .{}) catch return;
        defer root.close(s.io);
        const l = (cachefs.tryWriteLock(s.io, root) catch return) orelse return;
        defer cachefs.unlock(s.io, l);
        var now = s.open(k) catch return;
        defer now.deinit(s.gpa);
        const stale = switch (now) {
            .bad => true,
            .entry => |*e| switch (rejected.*) {
                .entry => |*was| std.mem.eql(u8, e.data, was.data),
                else => false,
            },
            .none => false,
        };
        if (stale) root.deleteTree(s.io, k) catch {};
    }
};

const testing = std.testing;

const test_key: []const u8 = &@as([64]u8, @splat('a'));
const test_key_entry = @as([64]u8, @splat('a')) ++ "/entry";

fn testStore(tmp: *testing.TmpDir, buf: []u8) !Store {
    const root = buf[0..try tmp.dir.realPath(testing.io, buf)];
    try testing.expect(cachefs.prepareShape(testing.io, root, .dirs, null, false));
    return .{ .gpa = testing.allocator, .io = testing.io, .root = root };
}

test "one rename publishes every part" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const s = try testStore(&tmp, &buf);
    var none = try s.open(test_key);
    try testing.expect(none == .none);
    try testing.expect(try s.publish(test_key, &.{ .{ .part = .result, .bytes = "out" }, .{ .part = .readset, .bytes = "obs" } }));
    var o = try s.open(test_key);
    defer o.deinit(testing.allocator);
    try testing.expectEqualStrings("obs", o.entry.part(.readset).?);
    try testing.expectEqualStrings("out", o.entry.part(.result).?);
    try testing.expect(o.entry.part(.drvs) == null);
    var d = try tmp.dir.openDir(testing.io, test_key, .{ .iterate = true });
    defer d.close(testing.io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    try testing.expectEqual(1, n);
    none.deinit(testing.allocator);
}

test "a reader of one generation never sees the next" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const s = try testStore(&tmp, &buf);
    try testing.expect(try s.publish(test_key, &.{ .{ .part = .readset, .bytes = "old obs" }, .{ .part = .result, .bytes = "old out" } }));
    var e = try s.open(test_key);
    defer e.deinit(testing.allocator);
    try testing.expectEqualStrings("old obs", e.entry.part(.readset).?);
    try testing.expect(try s.publish(test_key, &.{ .{ .part = .readset, .bytes = "new observations" }, .{ .part = .result, .bytes = "new out" }, .{ .part = .warnings, .bytes = "w" } }));
    try testing.expectEqualStrings("old out", e.entry.part(.result).?);
    try testing.expect(e.entry.part(.warnings) == null);
    var next = try s.open(test_key);
    defer next.deinit(testing.allocator);
    try testing.expectEqualStrings("new out", next.entry.part(.result).?);
}

test "bytes that are not an entry are bad, not a panic" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const s = try testStore(&tmp, &buf);
    const cases = [_][]const u8{ "", "\x01", "\x09\x01", "\x01\x04", &[_]u8{ 1, 1, 0 } ++ @as([16]u8, @splat(255)) };
    try tmp.dir.createDirPath(testing.io, test_key);
    for (cases) |c| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = test_key_entry, .data = c });
        var o = try s.open(test_key);
        defer o.deinit(testing.allocator);
        try testing.expect(o == .bad);
    }
}

test "a discard takes only the generation it rejected" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const s = try testStore(&tmp, &buf);
    const Gen = struct {
        fn of(st: *const Store, out: []const u8) !Opened {
            try testing.expect(try st.publish(test_key, &.{ .{ .part = .readset, .bytes = "obs" }, .{ .part = .result, .bytes = out } }));
            return st.open(test_key);
        }
        fn corrupt(st: *const Store, t: *testing.TmpDir) !Opened {
            try t.dir.createDirPath(testing.io, test_key);
            try t.dir.writeFile(testing.io, .{ .sub_path = test_key_entry, .data = "\x01" });
            return st.open(test_key);
        }
        fn present(st: *const Store) !bool {
            var o = try st.open(test_key);
            defer o.deinit(testing.allocator);
            return o == .entry;
        }
    };
    var bad = try Gen.corrupt(&s, &tmp);
    try testing.expect(bad == .bad);
    var old = try Gen.of(&s, "old");
    defer old.deinit(testing.allocator);
    s.discard(test_key, &bad);
    try testing.expect(try Gen.present(&s));
    var new = try Gen.of(&s, "new");
    defer new.deinit(testing.allocator);
    s.discard(test_key, &old);
    try testing.expect(try Gen.present(&s));
    s.discard(test_key, &new);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, test_key, .{}));
    var again = try Gen.of(&s, "again");
    defer again.deinit(testing.allocator);
    var c = try Gen.corrupt(&s, &tmp);
    s.discard(test_key, &c);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, test_key, .{}));
}

// Cache hygiene, the cases that need no command line.

const hygiene_keys = 4;
const hygiene_obs = 400;

fn keyOf(buf: *[64]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>64}", .{i}) catch unreachable;
}

fn hygienePublish(s: *const Store, key: usize, writer: u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const obs = try a.alloc(@import("../trace.zig").Obs, hygiene_obs);
    for (obs, 0..) |*o, i| o.* = .{ .env = .{ .name = try std.fmt.allocPrint(a, "IETS_TEST_{d}_{d}", .{ key, i }), .value = @splat(writer) } };
    const readset = try wire.encodeReadset(a, obs);
    const result = try a.alloc(u8, 700 + @as(usize, writer) * 137);
    @memset(result, writer);
    const warnings = try a.alloc(u8, 64 + @as(usize, writer));
    @memset(warnings, writer);
    var kb: [64]u8 = undefined;
    _ = s.publish(keyOf(&kb, key), &.{ .{ .part = .warnings, .bytes = warnings }, .{ .part = .result, .bytes = result }, .{ .part = .readset, .bytes = readset } }) catch false;
}

fn writerOf(b: []const u8) !u8 {
    try testing.expect(b.len > 0);
    for (b) |x| try testing.expectEqual(b[0], x);
    return b[0];
}

/// Some count when the key holds an entry: never a torn one, never a mix
/// of two writers' parts.
fn hygieneCheck(s: *const Store, key: usize) !?usize {
    var kb: [64]u8 = undefined;
    var o = try s.open(keyOf(&kb, key));
    defer o.deinit(testing.allocator);
    const e = switch (o) {
        .none => return null,
        .bad => return error.TestUnexpectedResult,
        .entry => |*e| e,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const obs = (try wire.decodeReadset(arena.allocator(), e.part(.readset).?)).?;
    try testing.expectEqual(hygiene_obs, obs.len);
    const w = try writerOf(e.part(.result).?);
    for (obs) |ob| try testing.expectEqual(w, try writerOf(&ob.env.value.?));
    try testing.expectEqual(w, try writerOf(e.part(.warnings).?));
    try testing.expectEqual(700 + @as(usize, w) * 137, e.part(.result).?.len);
    return obs.len;
}

test "concurrent readers and writers never see a torn entry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const s = try testStore(&tmp, &buf);
    var writing: std.atomic.Value(usize) = .init(8);
    var failed: std.atomic.Value(bool) = .init(false);
    const W = struct {
        fn write(st: *const Store, w: u8, n: *std.atomic.Value(usize), bad: *std.atomic.Value(bool)) void {
            for (0..60) |round| {
                const key = (round + w) % hygiene_keys;
                hygienePublish(st, key, w + 1) catch bad.store(true, .monotonic);
                _ = hygieneCheck(st, (key + 1) % hygiene_keys) catch bad.store(true, .monotonic);
            }
            _ = n.fetchSub(1, .monotonic);
        }
        fn read(st: *const Store, r: usize, n: *std.atomic.Value(usize), bad: *std.atomic.Value(bool)) void {
            var i = r;
            while (n.load(.monotonic) > 0) : (i += 1) {
                _ = hygieneCheck(st, i % hygiene_keys) catch bad.store(true, .monotonic);
                if (i % 8 == 0) {
                    var kb: [64]u8 = undefined;
                    st.discard(keyOf(&kb, i % hygiene_keys), &.bad);
                }
            }
        }
    };
    var ts: [12]std.Thread = undefined;
    for (0..8) |w| ts[w] = try std.Thread.spawn(.{}, W.write, .{ &s, @as(u8, @intCast(w)), &writing, &failed });
    for (0..4) |r| ts[8 + r] = try std.Thread.spawn(.{}, W.read, .{ &s, r, &writing, &failed });
    for (ts) |t| t.join();
    try testing.expect(!failed.load(.monotonic));
    for (0..hygiene_keys) |key| {
        var kb: [64]u8 = undefined;
        s.discard(keyOf(&kb, key), &.bad);
        try testing.expect((try hygieneCheck(&s, key)) != null);
    }
}

test "an entry that is not a plain file is refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "good", .data = "x" });
    var p: [Dir.max_path_bytes]u8 = undefined;
    const at = struct {
        fn f(b: []u8, r: []const u8, n: []const u8) []const u8 {
            return std.fmt.bufPrint(b, "{s}/{s}", .{ r, n }) catch unreachable;
        }
    }.f;
    switch (cachefs.entries.openEntry(io, at(&p, root, "good"))) {
        .file => |f| f.file.close(io),
        else => return error.TestUnexpectedResult,
    }
    const huge = try tmp.dir.createFile(io, "huge", .{});
    try huge.setLength(io, cachefs.max_entry + 1);
    huge.close(io);
    try testing.expect(cachefs.entries.openEntry(io, at(&p, root, "huge")) == .foreign);
    try tmp.dir.createDirPath(io, "dir");
    try testing.expect(cachefs.entries.openEntry(io, at(&p, root, "dir")) == .foreign);
    try testing.expect(cachefs.entries.openEntry(io, at(&p, root, "none")) == .missing);
    try tmp.dir.symLink(io, "good", "link", .{});
    try testing.expect(cachefs.entries.openEntry(io, at(&p, root, "link")) == .foreign);
    var zb: [Dir.max_path_bytes + 1]u8 = undefined;
    const fifo = at(&p, root, "fifo");
    @memcpy(zb[0..fifo.len], fifo);
    zb[fifo.len] = 0;
    try testing.expectEqual(0, std.os.linux.mknodat(std.os.linux.AT.FDCWD, zb[0..fifo.len :0], std.os.linux.S.IFIFO | 0o600, 0));
    try testing.expect(cachefs.entries.openEntry(io, fifo) == .foreign);
}

test "an entry that does not open is a miss and stays" {
    if (std.os.linux.geteuid() == 0) return;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const s = try testStore(&tmp, &buf);
    try testing.expect(try s.publish(test_key, &.{.{ .part = .readset, .bytes = "x" }}));
    try tmp.dir.setFilePermissions(testing.io, test_key_entry, .fromMode(0o000), .{});
    var o = try s.open(test_key);
    defer o.deinit(testing.allocator);
    try testing.expect(o == .none);
    try testing.expect(s.kept(testing.allocator, test_key) == null);
    try tmp.dir.access(testing.io, test_key_entry, .{});
}

test "a published entry is private to its owner" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const s = try testStore(&tmp, &buf);
    try testing.expect(try s.publish(test_key, &.{.{ .part = .readset, .bytes = "x" }}));
    const mode = struct {
        fn of(d: Dir, sub: []const u8) !u32 {
            return (try d.statFile(testing.io, sub, .{})).permissions.toMode() & 0o777;
        }
    }.of;
    try testing.expectEqual(0o700, try mode(tmp.dir, test_key));
    try testing.expectEqual(0o600, try mode(tmp.dir, test_key_entry));
    try testing.expectEqual(0o600, try mode(tmp.dir, "lock"));
}
