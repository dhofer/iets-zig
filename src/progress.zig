//! The activities running now, from iets, the daemon or a child nix.
//! A terminal gets a status line
//! (progress-bar.cc), a pipe gets a `⏵` line after `first` and every
//! `heartbeat`. Under internal-json the records carry it and nothing is
//! drawn. With `IETS_PROGRESS=false` nothing is drawn either.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = @import("log.zig");
const sys = @import("sys.zig");
const store_path = @import("store/path.zig");

const ns_per_s = std.time.ns_per_s;
pub const first: u64 = 5 * ns_per_s;
/// Between two `⏵` lines on a pipe.
pub const heartbeat: u64 = 30 * ns_per_s;
const stall: u64 = 10 * ns_per_s;

pub const Mode = enum(u8) { off, bar, lines };

const Task = struct {
    ty: u64,
    text: []u8,
    parent: u64,
    started: u64,
    done: u64 = 0,
    expected: u64 = 0,
    /// Only a task that reports progress can be called stalled.
    measured: bool = false,
    moved: u64,
    /// What the task's own tool prints, such as git's `Receiving objects`.
    detail: []u8 = &.{},
    told: bool = false,
};

/// By id, which is start order: ids only grow, and removal keeps the order.
const Tasks = std.AutoArrayHashMapUnmanaged(u64, Task);

pub const Board = struct {
    gpa: Allocator,
    io: std.Io,
    mode_: std.atomic.Value(u8) = .init(@backingInt(Mode.off)),
    /// The build renderer draws the running builds itself, so the status
    /// line leaves them out.
    live: std.atomic.Value(bool) = .init(false),
    /// `IETS_PROGRESS=false`: the ticker draws nothing.
    hidden: std.atomic.Value(bool) = .init(false),
    lock: std.Io.Mutex = .init,
    all: Tasks = .empty,
    ticking: bool = false,
    /// A child that may prompt on the terminal runs (processes.cc:338).
    suspended: usize = 0,
    beat: ?u64 = null,
    /// The log the ticker draws on; null for a board on its own (tests).
    owner: ?*log.Log = null,
    /// What a tick draws, kept between ticks; under `lock`.
    line: std.Io.Writer.Allocating,
    /// The status line in colour.
    painted: std.Io.Writer.Allocating,
    /// A task's text without its store hashes.
    unhashed: std.Io.Writer.Allocating,

    pub fn init(gpa: Allocator, io: std.Io) Board {
        return .{ .gpa = gpa, .io = io, .line = .init(gpa), .painted = .init(gpa), .unhashed = .init(gpa) };
    }

    pub fn deinit(b: *Board) void {
        for (b.all.values()) |*t| freeTask(b.gpa, t);
        b.all.deinit(b.gpa);
        b.line.deinit();
        b.painted.deinit();
        b.unhashed.deinit();
    }

    pub fn setMode(b: *Board, m: Mode) void {
        b.mode_.store(@backingInt(m), .monotonic);
    }

    pub fn mode(b: *const Board) Mode {
        return @fromBackingInt(@intCast(b.mode_.load(.monotonic)));
    }

    pub fn setLive(b: *Board, on: bool) void {
        b.live.store(on, .monotonic);
    }

    pub fn setHidden(b: *Board, on: bool) void {
        b.hidden.store(on, .monotonic);
    }

    /// The line logging.cc:SimpleLogger::startActivity prints, for a pipe
    /// under a Nix name, in `out`. The build renderer reports builds.
    pub fn start(b: *Board, id: u64, lvl: u64, ty: u64, text: []const u8, parent: u64, classic: bool, out: *std.ArrayList(u8)) !bool {
        const now = sys.monotonicNs();
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        const t = try b.gpa.dupe(u8, text);
        errdefer b.gpa.free(t);
        try b.all.put(b.gpa, id, .{ .ty = ty, .text = t, .parent = parent, .started = now, .moved = now });
        if (!b.ticking and b.owner != null) {
            b.ticking = true;
            spawnTicker(b);
        }
        if (b.mode() == .lines and classic and lvl <= log.lvl_info and text.len > 0 and !isBuild(ty)) {
            try out.print(b.gpa, "{s}...", .{text});
            return true;
        }
        return false;
    }

    /// logging.hh:resProgress: done, expected, running, failed.
    pub fn result(b: *Board, id: u64, ty: u64, f: []const log.Field) void {
        if (ty != log.res_progress) return;
        const n = struct {
            fn at(fs: []const log.Field, i: usize) u64 {
                if (i >= fs.len) return 0;
                return switch (fs[i]) {
                    .int => |v| if (v < 0) 0 else @intCast(v),
                    .str => 0,
                };
            }
        }.at;
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        const task = b.all.getPtr(id) orelse return;
        if (n(f, 0) != task.done) task.moved = sys.monotonicNs();
        task.measured = true;
        task.done = n(f, 0);
        task.expected = n(f, 1);
    }

    pub fn detail(b: *Board, id: u64, text: []const u8) !void {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        const task = b.all.getPtr(id) orelse return;
        if (std.mem.eql(u8, task.detail, text)) return;
        const d = try b.gpa.dupe(u8, text);
        b.gpa.free(task.detail);
        task.detail = d;
        task.moved = sys.monotonicNs();
    }

    pub fn @"suspend"(b: *Board) void {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.suspended += 1;
    }

    pub fn @"resume"(b: *Board) void {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.suspended -|= 1;
    }

    /// Whether that was the last task: the status line must come down now,
    /// not a tick later, or the next output puts it back.
    pub fn stop(b: *Board, id: u64) bool {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        if (b.all.fetchOrderedRemove(id)) |kv| {
            var t = kv.value;
            freeTask(b.gpa, &t);
        }
        return b.all.count() == 0;
    }

    /// Null once nothing runs, which ends the ticker. `classic` and
    /// `color` are what the log says about the run.
    pub fn tick(b: *Board, now: u64, classic: bool, color: bool) !?Tick {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        if (b.all.count() == 0) {
            b.ticking = false;
            return null;
        }
        if (b.hidden.load(.monotonic)) return .quiet;
        b.line.clearRetainingCapacity();
        switch (b.mode()) {
            .bar => {
                if (b.suspended > 0) return .{ .bar = "" };
                _ = try b.summary(now, !b.live.load(.monotonic));
                b.painted.clearRetainingCapacity();
                try writeStatus(&b.painted.writer, color, b.line.written());
                return .{ .bar = b.painted.written() };
            },
            .lines => {
                if (classic) return .quiet;
                const due = if (b.beat) |beat| now - beat >= heartbeat else true;
                var new = false;
                var old = false;
                for (b.all.values()) |k| {
                    if (isBuild(k.ty) or now -| k.started < first) continue;
                    old = true;
                    if (!k.told) new = true;
                }
                if (!(new or (due and old))) return .quiet;
                if (!try b.summary(now, false)) return .quiet;
                b.beat = now;
                for (b.all.values()) |*k| k.told = true;
                return .{ .line = b.line.written() };
            },
            .off => return .quiet,
        }
    }

    /// One group per type into `line`: a single task by its text, several
    /// by their count. False when there is nothing to show.
    fn summary(b: *Board, now: u64, builds: bool) !bool {
        const Group = struct { ty: u64, first: *const Task, n: usize = 0, bytes: u64 = 0 };
        // logging.hh:ActivityType has 14 types
        var groups: [32]Group = undefined;
        var n: usize = 0;
        for (b.all.values()) |*k| {
            if (!shown(&b.all, k)) continue;
            if (!builds and isBuild(k.ty)) continue;
            const g = for (groups[0..n]) |*g| {
                if (g.ty == k.ty) break g;
            } else if (n < groups.len) blk: {
                groups[n] = .{ .ty = k.ty, .first = k };
                n += 1;
                break :blk &groups[n - 1];
            } else continue;
            g.n += 1;
            g.bytes += k.done;
        }
        if (n == 0) return false;
        const w = &b.line.writer;
        try w.writeAll("⏵ ");
        for (groups[0..n], 0..) |g, i| {
            if (i > 0) try w.writeAll(" · ");
            if (g.n == 1) {
                try b.one(g.first, now);
            } else {
                try w.print("{d} {s}", .{ g.n, verb(g.ty) });
                if (countsBytes(g.ty)) try w.print(", {f}", .{Size{ .b = g.bytes }});
            }
        }
        return true;
    }

    fn one(b: *Board, k: *const Task, now: u64) !void {
        const w = &b.line.writer;
        b.unhashed.clearRetainingCapacity();
        try writeUnhashed(&b.unhashed.writer, k.text);
        try writeShort(w, b.unhashed.written());
        if (k.expected > 0 and countsBytes(k.ty)) {
            try w.print(", {f} of {f}", .{ Size{ .b = k.done }, Size{ .b = k.expected } });
        } else if (countsBytes(k.ty) and k.done > 0) {
            try w.print(", {f}", .{Size{ .b = k.done }});
        } else if (k.expected > 0) {
            try w.print(", {d}/{d}", .{ k.done, k.expected });
        }
        if (k.detail.len > 0) try w.print(", {s}", .{k.detail});
        const age = now -| k.started;
        const quiet = now -| k.moved;
        const watched = k.measured or k.detail.len > 0;
        if (watched and quiet >= stall) {
            try w.print(" ({f}, no data for {f})", .{ Duration{ .ns = age }, Duration{ .ns = quiet } });
        } else if (age >= ns_per_s) {
            try w.print(" ({f})", .{Duration{ .ns = age }});
        }
    }
};

fn freeTask(gpa: Allocator, t: *Task) void {
    gpa.free(t.text);
    gpa.free(t.detail);
}

/// What one tick draws, borrowed from the board until the next tick.
pub const Tick = union(enum) {
    bar: []const u8,
    line: []const u8,
    quiet,
};

fn spawnTicker(b: *Board) void {
    const t = std.Thread.spawn(.{}, tickerLoop, .{b}) catch {
        b.ticking = false;
        return;
    };
    t.detach();
}

fn tickerLoop(b: *Board) void {
    const l = b.owner.?;
    while (true) {
        sys.sleepNs(if (b.mode() == .bar) 250 * std.time.ns_per_ms else ns_per_s);
        const t = b.tick(sys.monotonicNs(), l.isClassic(), l.color()) catch return;
        const tk = t orelse {
            l.setStatus("") catch {};
            return;
        };
        switch (tk) {
            .bar => |line| l.setStatus(line) catch {},
            .line => |line| l.errln(line),
            .quiet => {},
        }
    }
}

/// The build renderer reports these in a log.
fn isBuild(ty: u64) bool {
    return ty == log.act_build or ty == log.act_builds or ty == log.act_realise;
}

fn countsBytes(ty: u64) bool {
    return ty == log.act_copy_path or ty == log.act_file_transfer;
}

fn verb(ty: u64) []const u8 {
    return switch (ty) {
        log.act_build => "building",
        log.act_copy_path, log.act_copy_paths => "copying",
        log.act_file_transfer => "downloading",
        log.act_fetch_tree => "fetching",
        log.act_substitute => "substituting",
        log.act_query_path_info => "querying",
        else => "running",
    };
}

/// A task under another task with a text is folded into it, as a download
/// into the copy that asked for it.
fn shown(all: *const Tasks, k: *const Task) bool {
    if (k.text.len == 0) return false;
    var up = k.parent;
    for (0..16) |_| {
        const p = all.getPtr(up) orelse return true;
        if (p.text.len > 0) return false;
        up = p.parent;
    }
    return true;
}

/// Longer quoted names keep only their ends, so the numbers after them
/// still fit on the line.
const quoted = 40;

/// `text` with each long quoted name cut down to its ends.
fn writeShort(w: *std.Io.Writer, text: []const u8) !void {
    var parts = std.mem.splitScalar(u8, text, '\'');
    var i: usize = 0;
    while (parts.next()) |part_in| : (i += 1) {
        if (i > 0) try w.writeByte('\'');
        if (i % 2 == 0 or chars(part_in) <= quoted) {
            try w.writeAll(part_in);
            continue;
        }
        const part = if (std.mem.indexOf(u8, part_in, "://")) |at| part_in[at + 3 ..] else part_in;
        const n = chars(part);
        try w.writeAll(part[0..byteOfChar(part, 20)]);
        try w.writeAll("…");
        try w.writeAll(part[byteOfChar(part, n -| (quoted - 21))..]);
    }
}

fn chars(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// The byte offset of character `n` of `s`, or its length.
fn byteOfChar(s: []const u8, n: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var k: usize = 0;
    while (k < n) : (k += 1) _ = it.nextCodepointSlice() orelse break;
    return it.i;
}

/// `text` without the hash of each store path in it.
fn writeUnhashed(w: *std.Io.Writer, text: []const u8) !void {
    var rest = text;
    while (store_path.findStorePrefix(rest)) |sp| {
        try w.writeAll(rest[0..sp.start]);
        const after = rest[sp.start + sp.len ..];
        const hashed = after.len > 33 and after[32] == '-' and for (after[0..32]) |c| {
            if (!std.ascii.isAlphanumeric(c)) break false;
        } else true;
        if (hashed) {
            rest = after[33..];
        } else {
            try w.writeAll(rest[sp.start .. sp.start + sp.len]);
            rest = after;
        }
    }
    try w.writeAll(rest);
}

pub const Duration = @import("build/event.zig").Duration;

/// Bytes in the largest binary unit, one decimal.
/// The progress line is below the command line, so it keeps a copy of
/// `cli/render.zig`'s `size`.
pub const Size = struct {
    b: u64,
    pub fn format(sz: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var unit: u32 = 0;
        var v = sz.b;
        while (v > 1024 and unit < 8) {
            unit += 1;
            v /= 1024;
        }
        const scaled = @as(f64, @floatFromInt(sz.b)) / std.math.pow(f64, 1024, @floatFromInt(@max(unit, 1)));
        try w.print("{d:.1} {c}iB", .{ scaled, "KKMGTPEZY"[unit] });
    }
};

const writeStatus = @import("build/render.zig").writeStatus;

const testing = std.testing;

fn mkTask(ty: u64, text: []const u8, parent: u64, age_s: u64, now: u64) !Task {
    const at = now - age_s * ns_per_s;
    return .{ .ty = ty, .text = try testing.allocator.dupe(u8, text), .parent = parent, .started = at, .moved = at };
}

fn expectShort(text: []const u8, want: []const u8) !void {
    var t: std.Io.Writer.Allocating = .init(testing.allocator);
    defer t.deinit();
    try writeUnhashed(&t.writer, text);
    var got: std.Io.Writer.Allocating = .init(testing.allocator);
    defer got.deinit();
    try writeShort(&got.writer, t.written());
    try testing.expectEqualStrings(want, got.written());
}

/// The summary of what `b` holds.
fn summaryOf(b: *Board, now: u64, builds: bool) ![]const u8 {
    b.line.clearRetainingCapacity();
    try testing.expect(try b.summary(now, builds));
    return b.line.written();
}

test "store hashes are left out" {
    try expectShort(
        "copying path '/nix/store/0123456789abcdfghijklmnpqrsvwxyz-hello-2.12' from 'https://cache.nixos.org'",
        "copying path 'hello-2.12' from 'https://cache.nixos.org'",
    );
    try expectShort("/nix/store/x", "/nix/store/x");
    try expectShort(
        "downloading 'https://github.com/NixOS/nixpkgs/archive/66bbe65cae88eb900d5b3236bc1b07fa47a09c12.tar.gz'",
        "downloading 'github.com/NixOS/nix…07fa47a09c12.tar.gz'",
    );
}

const now0: u64 = 1000 * ns_per_s;

test "a download inside a copy is part of the copy" {
    var b: Board = .init(testing.allocator, testing.io);
    defer b.deinit();
    try b.all.put(testing.allocator, 1, try mkTask(log.act_substitute, "", 0, 3, now0));
    try b.all.put(testing.allocator, 2, try mkTask(log.act_copy_path, "copying path 'a'", 1, 3, now0));
    try b.all.put(testing.allocator, 3, try mkTask(log.act_file_transfer, "downloading 'u'", 2, 3, now0));
    try testing.expectEqualStrings("⏵ copying path 'a' (3s)", try summaryOf(&b, now0, true));
}

test "several of a kind are counted" {
    var b: Board = .init(testing.allocator, testing.io);
    defer b.deinit();
    var a = try mkTask(log.act_file_transfer, "downloading 'a'", 0, 0, now0);
    a.done = 1 << 20;
    var c = try mkTask(log.act_file_transfer, "downloading 'b'", 0, 0, now0);
    c.done = 1 << 20;
    try b.all.put(testing.allocator, 1, a);
    try b.all.put(testing.allocator, 2, c);
    try b.all.put(testing.allocator, 3, try mkTask(log.act_build, "building 'x'", 0, 0, now0));
    try testing.expectEqualStrings("⏵ 2 downloading, 2.0 MiB · building 'x'", try summaryOf(&b, now0, true));
    try testing.expectEqualStrings("⏵ 2 downloading, 2.0 MiB", try summaryOf(&b, now0, false));
}

test "a transfer that does not move says so" {
    var b: Board = .init(testing.allocator, testing.io);
    defer b.deinit();
    var k = try mkTask(log.act_file_transfer, "downloading 'u'", 0, 45, now0);
    k.done = 2048;
    k.measured = true;
    try b.all.put(testing.allocator, 1, k);
    try testing.expectEqualStrings("⏵ downloading 'u', 2.0 KiB (45s, no data for 45s)", try summaryOf(&b, now0, false));
}

test "a log hears of a task after first and then every heartbeat" {
    var b: Board = .init(testing.allocator, testing.io);
    defer b.deinit();
    b.setMode(.lines);
    const start = now0 - ns_per_s;
    try b.all.put(testing.allocator, 1, try mkTask(log.act_fetch_tree, "fetching 'x'", 0, 0, start));
    b.ticking = true;
    const now = start + ns_per_s;
    try testing.expect((try b.tick(now, false, false)).? == .quiet);
    const later = now + first;
    var young = try mkTask(log.act_file_transfer, "downloading 'y'", 0, 0, later);
    young.started = later - 4 * ns_per_s;
    try b.all.put(testing.allocator, 2, young);
    const t = (try b.tick(later, false, false)).?;
    try testing.expectEqualStrings("⏵ fetching 'x' (6s) · downloading 'y' (4s)", t.line);
    try testing.expect((try b.tick(later + ns_per_s, false, false)).? == .quiet);
    try testing.expect((try b.tick(later + heartbeat, false, false)).? == .line);
    _ = b.stop(1);
    _ = b.stop(2);
    try testing.expect(try b.tick(later + heartbeat, false, false) == null);
}

test "a hidden board draws nothing" {
    var b: Board = .init(testing.allocator, testing.io);
    defer b.deinit();
    b.setHidden(true);
    try b.all.put(testing.allocator, 1, try mkTask(log.act_fetch_tree, "fetching 'x'", 0, 0, now0));
    b.ticking = true;
    const later = now0 + first;
    for ([_]Mode{ .lines, .bar }) |m| {
        b.setMode(m);
        try testing.expect((try b.tick(later, false, false)).? == .quiet);
    }
    b.setHidden(false);
    try testing.expect((try b.tick(later, false, false)).? == .bar);
}

test "sizes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.5 KiB", try std.fmt.bufPrint(&buf, "{f}", .{Size{ .b = 512 }}));
    try testing.expectEqualStrings("1.0 KiB", try std.fmt.bufPrint(&buf, "{f}", .{Size{ .b = 1024 }}));
}
