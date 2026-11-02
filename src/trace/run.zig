//! The tracing cache for one command run: the key a subcommand's arguments
//! make, the lookup, and the entry it writes. See
//! docs/explanation/caching.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cachefs = @import("../cachefs.zig");
const trace = @import("../trace.zig");
const wire = @import("wire.zig");
const store_mod = @import("store.zig");
const validate = @import("validate.zig");
const Key = @import("key.zig").Key;
const Log = @import("../log.zig").Log;
const Store = store_mod.Store;
const Part = store_mod.Part;
const Opened = store_mod.Opened;

/// The tracing cache for one run: where the entry lives and its key.
pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    store: Store,
    key: [64]u8,
    /// `--timings`: the `cache:` lines.
    timings: bool,
    /// Where the `cache:` lines, the invalidation and the replayed warnings go.
    log: *Log,
    /// The input store `Input` observations ask.
    inputs: ?validate.Inputs = null,
    /// The generation of the entry this run reads, opened once. Everything a
    /// hit replays comes from it, so a sibling that publishes meanwhile
    /// cannot mix its parts into this run.
    entry: ?Opened = null,

    /// Null when the cache root's `trace/` is not iets's to write in.
    /// `stderr` gets the refusal of a foreign directory.
    pub fn open(gpa: Allocator, io: Io, cache_root: []const u8, k: *Key, timings: bool, log: *Log, stderr: ?*Io.Writer) Allocator.Error!?Cache {
        var st = try Store.locate(gpa, io, cache_root);
        if (!cachefs.prepareShape(io, st.root, .dirs, stderr, timings)) {
            st.deinit();
            return null;
        }
        // before any evaluation records an `Env` observation
        cachefs.useEnvKey(io, st.root);
        return .{ .gpa = gpa, .io = io, .store = st, .key = k.finish(), .timings = timings, .log = log };
    }

    pub fn deinit(c: *Cache) void {
        if (c.entry) |*e| e.deinit(c.gpa);
        c.store.deinit();
    }

    fn opened(c: *Cache) *Opened {
        if (c.entry == null) c.entry = c.store.open(&c.key) catch .none;
        return &c.entry.?;
    }

    /// One part of the entry this run validated; the bytes are the entry's.
    pub fn part(c: *Cache, p: Part) ?[]const u8 {
        return switch (c.opened().*) {
            .entry => |*e| e.part(p),
            else => null,
        };
    }

    /// Where this run's entry lives, for `iets cache paths`. The file need
    /// not exist yet: a first run names the entry it is about to write.
    pub fn entryPath(c: *const Cache, buf: []u8) []const u8 {
        return c.store.entryPath(buf, &c.key);
    }

    fn line(c: *Cache, comptime fmt: []const u8, args: anytype) void {
        if (!c.timings) return;
        const s = std.fmt.allocPrint(c.gpa, fmt, args) catch return;
        defer c.gpa.free(s);
        c.log.errln(s);
    }

    /// A hit whose `build` tables do not decode: the entry goes, and the
    /// run evaluates.
    pub fn discardTables(c: *Cache) void {
        c.store.discard(&c.key, c.opened());
        c.line("cache: miss (unreadable tables, discarded)", .{});
    }

    fn bad(c: *Cache) bool {
        c.store.discard(&c.key, c.opened());
        c.line("cache: miss (unreadable entry, discarded)", .{});
        return false;
    }

    /// Validates the stored read set; true on a hit. A hit that refreshed
    /// stat fields publishes the entry again with the new read set. An entry
    /// that existed and no longer holds reports what changed; a run with no
    /// entry says nothing, because a first run invalidated nothing.
    pub fn lookup(c: *Cache) Allocator.Error!bool {
        const t0 = Io.Clock.awake.now(c.io);
        const e = switch (c.opened().*) {
            .none => {
                c.line("cache: miss (no entry)", .{});
                return false;
            },
            .bad => return c.bad(),
            .entry => |*e| e,
        };
        const bytes = e.part(.readset) orelse return c.bad();
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const obs = (try wire.decodeReadset(arena.allocator(), bytes)) orelse return c.bad();
        const threads = @min(std.Thread.getCpuCount() catch 1, 4);
        const t_load = secsSince(c.io, t0);
        const env: validate.Env = .{ .gpa = c.gpa, .io = c.io, .inputs = c.inputs };
        switch (try validate.validate(&env, obs, threads)) {
            .ok => |r| {
                if (r.refreshed > 0) {
                    const rs = try wire.encodeReadset(c.gpa, obs);
                    defer c.gpa.free(rs);
                    c.republish(e, rs);
                } else c.store.touch(&c.key);
                c.line("cache: hit, {d} entries validated, {d} rehashed, load {d:.3}s, validate {d:.3}s", .{ r.entries, r.rehashed, t_load, secsSince(c.io, t0) - t_load });
                return true;
            },
            .mismatch => |why| {
                defer c.gpa.free(why);
                c.log.invalidated(why);
                c.line("cache: miss ({s}), {d} entries, {d:.3}s", .{ why, obs.len, secsSince(c.io, t0) });
                return false;
            },
        }
    }

    /// A hit that refreshed stat fields publishes the whole entry again, with
    /// the parts it validated and the new read set. The other parts come
    /// from the open generation, so a sibling's publish in between is not
    /// mixed in.
    fn republish(c: *Cache, e: *const store_mod.Entry, readset: []const u8) void {
        var parts: [6]Store.PartBytes = undefined;
        var n: usize = 0;
        for ([_]Part{ .warnings, .nix_config, .drvs, .sources, .result }) |p| {
            if (e.part(p)) |b| {
                parts[n] = .{ .part = p, .bytes = b };
                n += 1;
            }
        }
        parts[n] = .{ .part = .readset, .bytes = readset };
        _ = c.store.publish(&c.key, parts[0 .. n + 1]) catch {};
    }

    /// What a run hands `write` besides its result.
    pub const Run = struct {
        trace: trace.Trace,
        /// The lint warnings the run printed, as records (`log.Log.lint`).
        warnings: []const []const u8 = &.{},
        /// The run's top-level flake had a `nixConfig`.
        nix_config_seen: bool = false,
        /// The drv and source tables a `build` hit reads back.
        drvs: ?[]const u8 = null,
        sources: ?[]const u8 = null,
    };

    /// Writes the entry after a successful run; a run that observed
    /// `currentTime` or called a fetcher writes nothing.
    pub fn write(c: *Cache, r: Run, result: []const u8) Allocator.Error!void {
        if (!r.trace.isCacheable()) {
            c.line("cache: not written (uncacheable run)", .{});
            return;
        }
        const t0 = Io.Clock.awake.now(c.io);
        const obs = try r.trace.take(c.gpa);
        defer c.gpa.free(obs);
        var warnings: std.ArrayList(u8) = .empty;
        defer warnings.deinit(c.gpa);
        for (r.warnings) |w| {
            try warnings.appendSlice(c.gpa, w);
            try warnings.append(c.gpa, '\n');
        }
        const readset = try wire.encodeReadset(c.gpa, obs);
        defer c.gpa.free(readset);
        var parts: [6]Store.PartBytes = undefined;
        var n: usize = 0;
        if (warnings.items.len > 0) {
            parts[n] = .{ .part = .warnings, .bytes = warnings.items };
            n += 1;
        }
        if (r.nix_config_seen) {
            parts[n] = .{ .part = .nix_config, .bytes = "" };
            n += 1;
        }
        if (r.drvs) |d| {
            parts[n] = .{ .part = .drvs, .bytes = d };
            parts[n + 1] = .{ .part = .sources, .bytes = r.sources orelse "" };
            n += 2;
        }
        parts[n] = .{ .part = .result, .bytes = result };
        parts[n + 1] = .{ .part = .readset, .bytes = readset };
        n += 2;
        if (c.store.publish(&c.key, parts[0..n])) |wrote| {
            if (wrote and obs.len > 0) {
                c.line("cache: wrote {d} entries, {d:.3}s", .{ obs.len, secsSince(c.io, t0) });
            } else if (!wrote) c.line("cache: not written (a sibling holds the store lock)", .{});
        } else |e| {
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            var ebuf: [128]u8 = undefined;
            var total: u64 = 0;
            for (parts[0..n]) |p| total += p.bytes.len;
            const why = if (e == error.TooLarge)
                try std.fmt.allocPrint(c.gpa, "cache entry is {d} bytes, over the {d} byte limit", .{ total + 10 + n * 17, cachefs.max_entry })
            else
                try c.gpa.dupe(u8, @import("../errors.zig").osText(&ebuf, e));
            defer c.gpa.free(why);
            const msg = try std.fmt.allocPrint(c.gpa, "warning: cannot write cache entry {s}: {s}", .{ c.store.entryDir(&buf, &c.key), why });
            defer c.gpa.free(msg);
            c.log.textLine(msg);
        }
        cachefs.maybeSweepShape(c.gpa, c.io, c.store.root, .dirs, if (c.timings) c.log else null);
    }

    /// On a hit: the lint warnings the recorded run printed, to stderr.
    pub fn replayWarnings(c: *Cache) Allocator.Error!void {
        const bytes = c.part(.warnings) orelse return;
        const shown = c.log.replayLints(bytes) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer c.log.gpa.free(shown);
        c.log.err(shown);
    }

    /// On a hit: whether the recorded run's top-level flake had a
    /// `nixConfig`, so the warnings that wait for one are given.
    pub fn replayedNixConfig(c: *Cache) bool {
        return c.part(.nix_config) != null;
    }
};

fn secsSince(io: Io, t0: Io.Timestamp) f64 {
    const ns = Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

const testing = std.testing;

fn hitEntry(a: Allocator) ![]u8 {
    return wire.encodeReadset(a, &.{.{ .env = .{ .name = "IETS_NO_SUCH_VARIABLE", .value = null } }});
}

const TestCache = struct {
    log: Log,
    root: []const u8,

    fn cached(t: *TestCache) !Cache {
        var k: Key = .init("eval");
        return (try Cache.open(testing.allocator, testing.io, t.root, &k, false, &t.log, null)).?;
    }
};

fn putHit(c: *Cache, readset: []const u8) !void {
    try testing.expect(try c.store.publish(&c.key, &.{.{ .part = .readset, .bytes = readset }}));
}

fn entryExists(c: *const Cache) bool {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    Io.Dir.cwd().access(testing.io, c.store.entryDir(&buf, &c.key), .{}) catch return false;
    return true;
}

test "a corrupt entry is dropped and a corrupt store is wiped" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t: TestCache = .{ .log = .init(testing.allocator, testing.io, .{}), .root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)] };
    defer t.log.deinit();
    const hit = try hitEntry(testing.allocator);
    defer testing.allocator.free(hit);

    var c = try t.cached();
    try putHit(&c, hit);
    try testing.expect(try c.lookup());
    c.deinit();

    var ebuf: [Io.Dir.max_path_bytes]u8 = undefined;
    c = try t.cached();
    const entry = try testing.allocator.dupe(u8, c.entryPath(&ebuf));
    defer testing.allocator.free(entry);
    var gbuf: [4096]u8 = undefined;
    const good = try Io.Dir.cwd().readFile(testing.io, entry, &gbuf);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = entry, .data = good[0 .. good.len / 2] });
    c.deinit();
    c = try t.cached();
    try testing.expect(!try c.lookup());
    try testing.expect(!entryExists(&c));

    try putHit(&c, "garbage");
    c.deinit();
    c = try t.cached();
    try testing.expect(!try c.lookup());
    try testing.expect(!entryExists(&c));

    try putHit(&c, hit);
    var sbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&sbuf, "{s}/gc-stamp", .{c.store.root}), .data = "\x01not a time" });
    c.deinit();
    c = try t.cached();
    try testing.expect(!entryExists(&c));
    try putHit(&c, hit);
    c.deinit();
    c = try t.cached();
    defer c.deinit();
    try testing.expect(try c.lookup());
}

test "a changed byte or a copied entry is a miss" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    var t: TestCache = .{ .log = .init(testing.allocator, testing.io, .{}), .root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)] };
    defer t.log.deinit();
    const hit = try hitEntry(testing.allocator);
    defer testing.allocator.free(hit);
    var c = try t.cached();
    defer c.deinit();
    try putHit(&c, hit);
    try testing.expect(try c.lookup());
    var ebuf: [Io.Dir.max_path_bytes]u8 = undefined;
    const entry = try testing.allocator.dupe(u8, c.entryPath(&ebuf));
    defer testing.allocator.free(entry);
    var gbuf: [4096]u8 = undefined;
    const good = try testing.allocator.dupe(u8, try Io.Dir.cwd().readFile(testing.io, entry, &gbuf));
    defer testing.allocator.free(good);
    var dbuf: [Io.Dir.max_path_bytes]u8 = undefined;
    for (0..good.len) |i| {
        const b = try testing.allocator.dupe(u8, good);
        defer testing.allocator.free(b);
        b[i] ^= 0xff;
        try Io.Dir.cwd().createDirPath(testing.io, c.store.entryDir(&dbuf, &c.key));
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = entry, .data = b });
        var c2 = try t.cached();
        defer c2.deinit();
        try testing.expect(!try c2.lookup());
        try testing.expect(!entryExists(&c2));
    }
    const other = @as([63]u8, @splat('0')) ++ "7";
    try Io.Dir.cwd().createDirPath(testing.io, c.store.entryDir(&dbuf, other));
    var obuf: [Io.Dir.max_path_bytes]u8 = undefined;
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = c.store.entryPath(&obuf, other), .data = good });
    var o = try c.store.open(other);
    defer o.deinit(testing.allocator);
    try testing.expect(o == .bad);
}
