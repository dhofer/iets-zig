//! Where an evaluation's time went, as a sampled flame graph.
//!
//! A tick thread asks for a sample and the call path tests one relaxed
//! load, so no clock is read per call. Each fiber samples its own shadow
//! stack on the worker that owns it, and never reads another fiber's. The
//! output is the folded form `frame;frame <count>` that `flamegraph.pl` and
//! every compatible tool read (docs/reference/profile.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const errors = @import("errors.zig");
const Log = @import("log.zig").Log;
const Pos = @import("syntax/pos.zig").Pos;
const Sym = @import("syntax/symbol.zig").Sym;
const Interner = @import("syntax/symbol.zig").Interner;
const Files = @import("eval/Files.zig");

/// Frames below this are left out of a sample, so hashing one stays
/// bounded. A nixpkgs attribute reaches about 200.
pub const max_depth = 512;

/// What a sample stands for.
pub const Mode = enum {
    /// One sample, so a stack's count is the time it was on CPU.
    time,
    /// The arena bytes allocated since the last sample, so a stack's count
    /// is the memory it built.
    bytes,

    /// `IETS_PROFILE`, or null when the word names no profile.
    pub fn parse(name: []const u8) ?Mode {
        if (std.mem.eql(u8, name, "eval")) return .time;
        if (std.mem.eql(u8, name, "alloc")) return .bytes;
        return null;
    }
};

/// Set on the low word of a frame whose callee is a builtin, so a primop
/// name and a lambda name are never read for each other.
const primop: u32 = 1 << 31;

/// Low word of a frame whose lambda has no name.
const anon: u32 = ~primop;

/// A call site and the lambda it entered, in one word: both halves are
/// already interned, and `Profile.write` turns them into text at the end
/// instead of while the samples are collected.
pub inline fn frame(pos: Pos, name: ?Sym) u64 {
    return @as(u64, @backingInt(pos)) << 32 | (if (name) |s| @backingInt(s) else anon);
}

/// A call site and the builtin it entered.
pub inline fn primopFrame(pos: Pos, sym: Sym) u64 {
    return @as(u64, @backingInt(pos)) << 32 | (@backingInt(sym) | primop);
}

/// One fiber's shadow stack. Pushed and popped by the call path, read by
/// nothing else. A fiber made from another starts a stack of its own.
pub const Stack = struct {
    frames: std.ArrayList(u64) = .empty,
    last_tick: u64 = 0,
    /// The run's profile, for `due` and `take` at a call.
    profile: ?*Profile = null,
    /// Arena bytes in use at the last sample, so the next weighs the bytes since.
    last_bytes: usize = 0,

    pub fn deinit(s: *Stack, gpa: Allocator) void {
        s.frames.deinit(gpa);
    }

    /// Enters `f`. The whole cost of a call that is not sampled.
    pub inline fn enter(s: *Stack, gpa: Allocator, f: u64) void {
        s.frames.append(gpa, f) catch {};
    }

    /// Whether the tick thread has asked for a sample since this fiber's
    /// last. One relaxed load and a compare, which is what a call pays.
    pub inline fn due(s: *const Stack, p: *const Profile) bool {
        return p.tick.load(.monotonic) != s.last_tick;
    }

    /// Credits this fiber's stack with `bytes`, or with one sample when the
    /// profile weighs time. Cold: 99 times a second per fiber on CPU.
    pub fn take(s: *Stack, p: *Profile, bytes: u64) void {
        @branchHint(.cold);
        s.last_tick = p.tick.load(.monotonic);
        const w = if (p.by_bytes.load(.monotonic)) bytes else 1;
        const n = @min(s.frames.items.len, max_depth);
        p.sample(s.frames.items[0..n], w);
    }

    pub inline fn depth(s: *const Stack) usize {
        return s.frames.items.len;
    }

    /// Returns to `d`. A call that failed left its frames behind, and
    /// `tryEval` goes on evaluating, so the unwind is by depth and not by a
    /// pop per frame.
    pub inline fn unwind(s: *Stack, d: usize) void {
        s.frames.shrinkRetainingCapacity(d);
    }
};

const Folded = std.HashMapUnmanaged([]const u64, u64, struct {
    pub fn hash(_: @This(), k: []const u64) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(k));
    }
    pub fn eql(_: @This(), a: []const u64, b: []const u64) bool {
        return std.mem.eql(u64, a, b);
    }
}, std.hash_map.default_max_load_percentage);

/// One run's samples. Lives on the session, so two evaluators in one
/// process each profile their own run.
pub const Profile = struct {
    gpa: Allocator,
    io: std.Io,
    /// Weighs a sample by the arena bytes since the one before it, instead
    /// of by one for the time it stood for.
    by_bytes: std.atomic.Value(bool) = .init(false),
    /// Bumped by the tick thread; compared by the call path.
    tick: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    lock: std.Io.Mutex = .init,
    folded: Folded = .empty,
    /// Set by the first evaluator that profiles, for `write` to symbolise with.
    files: ?*const Files = null,
    interner: ?*const Interner = null,
    /// Samples a second the tick thread asks for.
    hz: u32 = 99,
    /// Where the folded lines go. `-` is stderr; null profiles nothing.
    to: ?[]const u8 = null,
    thread: ?std.Thread = null,

    pub fn init(gpa: Allocator, io: std.Io) Profile {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(p: *Profile) void {
        p.stop.store(true, .monotonic);
        if (p.thread) |t| t.join();
        var it = p.folded.keyIterator();
        while (it.next()) |k| p.gpa.free(k.*);
        p.folded.deinit(p.gpa);
    }

    /// Whether this run profiles. A sample is never taken when it does
    /// not, because the tick stays at zero.
    pub fn on(p: *const Profile) bool {
        return p.to != null;
    }

    /// What `write` needs to turn a frame into text.
    pub fn names(p: *Profile, files: *const Files, interner: *const Interner) void {
        if (p.files == null) {
            p.files = files;
            p.interner = interner;
        }
    }

    fn sample(p: *Profile, frames: []const u64, weight: u64) void {
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        const gop = p.folded.getOrPut(p.gpa, frames) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = p.gpa.dupe(u64, frames) catch {
                p.folded.removeByPtr(gop.key_ptr);
                return;
            };
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += weight;
    }

    /// Starts profiling in `mode`, writing to `to` (`-` for stderr), with a
    /// tick thread at `hz`. The thread ends on the first tick after `write`.
    pub fn open(p: *Profile, mode: Mode, to: []const u8, hz: u32) void {
        p.hz = @max(hz, 1);
        p.by_bytes.store(mode == .bytes, .monotonic);
        p.to = to;
        p.thread = std.Thread.spawn(.{}, ticker, .{p}) catch null;
    }

    fn ticker(p: *Profile) void {
        const period = std.time.ns_per_s / @as(u64, p.hz);
        while (!p.stop.load(.monotonic)) {
            sys.sleepNs(period);
            _ = p.tick.fetchAdd(1, .monotonic);
        }
    }

    /// Writes the folded lines, and stops the tick thread. Called once,
    /// when the run has finished.
    pub fn write(p: *Profile, log: *Log) void {
        p.stop.store(true, .monotonic);
        const to = p.to orelse return;
        // once: the evaluator writes it while its files are still there,
        // and the session's end must not write it again
        p.to = null;
        p.lock.lockUncancelable(p.io);
        defer p.lock.unlock(p.io);
        var buf: std.Io.Writer.Allocating = .init(p.gpa);
        defer buf.deinit();
        if (p.folded.count() == 0) {
            var line: [128]u8 = undefined;
            log.errln(std.fmt.bufPrint(&line, "profile: no samples at {d} Hz, so the evaluation was shorter than one tick", .{p.hz}) catch return);
            return;
        }
        var it = p.folded.iterator();
        while (it.next()) |e| {
            for (e.key_ptr.*, 0..) |f, i| {
                if (i > 0) buf.writer.writeByte(';') catch return;
                p.describe(&buf.writer, f) catch return;
            }
            buf.writer.print(" {d}\n", .{e.value_ptr.*}) catch return;
        }
        if (std.mem.eql(u8, to, "-")) {
            sys.fs.writeAll(2, buf.written()) catch {};
            return;
        }
        switch (sys.fs.openSink(to)) {
            .fd => |fd| {
                sys.fs.writeAll(fd, buf.written()) catch {};
                _ = std.os.linux.close(fd);
            },
            .err => |e| {
                var line: [std.fs.max_path_bytes + 128]u8 = undefined;
                log.errln(std.fmt.bufPrint(&line, "error (ignored): opening profile file \"{s}\": {s}", .{ to, errors.errnoText(e) }) catch return);
            },
        }
    }

    /// `file:line:col:name`, and no name for an anonymous lambda. A frame a
    /// flame graph tool reads must hold no `;` and no space; a Nix path can
    /// hold either, so both are replaced.
    fn describe(p: *const Profile, w: *std.Io.Writer, f: u64) !void {
        const pos: Pos = @fromBackingInt(@as(u32, @intCast(f >> 32)));
        const low: u32 = @truncate(f);
        const files = p.files orelse return w.print("pos{d}", .{f >> 32});
        var tmp: [std.fs.max_path_bytes + 256]u8 = undefined;
        var t: std.Io.Writer = .fixed(&tmp);
        if (files.locate(pos)) |l| {
            t.print("{s}:{d}:{d}", .{ l.file.path, l.line, l.column }) catch {};
        } else t.writeAll("«none»") catch {};
        if (low & primop != 0 and low != anon) {
            t.print(":«{s}»", .{p.interner.?.nameStr(@fromBackingInt(low & ~primop))}) catch {};
        } else if (low != anon) {
            t.print(":{s}", .{p.interner.?.nameStr(@fromBackingInt(low))}) catch {};
        }
        for (t.buffered()) |c| try w.writeByte(switch (c) {
            ';' => ',',
            ' ' => '_',
            else => c,
        });
    }
};

const testing = std.testing;

/// A call the way the evaluator enters one: push, then sample if a tick passed.
fn call(s: *Stack, p: *Profile, f: u64, bytes: u64) void {
    s.enter(testing.allocator, f);
    if (s.due(p)) s.take(p, bytes);
}

fn expectFolded(p: *Profile, want: []const struct { []const u64, u64 }) !void {
    try testing.expectEqual(want.len, p.folded.count());
    for (want) |w| try testing.expectEqual(w[1], p.folded.get(w[0]).?);
}

test "a frame keeps its call site and its name" {
    const f = frame(@fromBackingInt(7), @fromBackingInt(3));
    try testing.expectEqual(7, f >> 32);
    try testing.expectEqual(3, @as(u32, @truncate(f)));
    try testing.expectEqual(anon, @as(u32, @truncate(frame(@fromBackingInt(7), null))));
}

test "a sample is taken once per tick" {
    var p: Profile = .init(testing.allocator, testing.io);
    defer p.deinit();
    var s: Stack = .{};
    defer s.deinit(testing.allocator);
    p.tick.store(1, .monotonic);
    call(&s, &p, 10, 0);
    call(&s, &p, 20, 0);
    try expectFolded(&p, &.{.{ &.{10}, 1 }});
    p.tick.store(2, .monotonic);
    call(&s, &p, 30, 0);
    try expectFolded(&p, &.{ .{ &.{10}, 1 }, .{ &.{ 10, 20, 30 }, 1 } });
}

test "an unwind returns to a depth" {
    var p: Profile = .init(testing.allocator, testing.io);
    defer p.deinit();
    var s: Stack = .{};
    defer s.deinit(testing.allocator);
    const d = s.depth();
    call(&s, &p, 10, 0);
    call(&s, &p, 20, 0);
    s.unwind(d);
    try testing.expectEqual(0, s.depth());
    p.tick.store(1, .monotonic);
    call(&s, &p, 30, 0);
    try expectFolded(&p, &.{.{ &.{30}, 1 }});
}

test "a deep stack is capped" {
    var p: Profile = .init(testing.allocator, testing.io);
    defer p.deinit();
    var s: Stack = .{};
    defer s.deinit(testing.allocator);
    for (0..max_depth + 10) |i| {
        call(&s, &p, i, 0);
        p.tick.store(i + 1, .monotonic);
    }
    var it = p.folded.keyIterator();
    while (it.next()) |k| try testing.expect(k.len <= max_depth);
}

test "a weight is bytes when the profile asks for them" {
    var p: Profile = .init(testing.allocator, testing.io);
    defer p.deinit();
    p.by_bytes.store(true, .monotonic);
    var s: Stack = .{};
    defer s.deinit(testing.allocator);
    p.tick.store(1, .monotonic);
    call(&s, &p, 10, 4096);
    try expectFolded(&p, &.{.{ &.{10}, 4096 }});
}

test "a frame is described without a semicolon or a space" {
    var files: Files = .init(testing.allocator, testing.io);
    defer files.deinit();
    var interner: Interner = try .init(testing.allocator);
    defer interner.deinit();
    const f = try files.add("/a b;c.nix", "x\nfoo");
    const name = try interner.intern("go");
    var p: Profile = .init(testing.allocator, testing.io);
    defer p.deinit();
    p.names(&files, &interner);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.describe(&w, frame(.at(f.base + 2), name));
    try w.writeByte('|');
    try p.describe(&w, primopFrame(.at(f.base), name));
    try w.writeByte('|');
    try p.describe(&w, frame(.at(f.base), null));
    try testing.expectEqualStrings("/a_b,c.nix:2:1:go|/a_b,c.nix:1:1:«go»|/a_b,c.nix:1:1", w.buffered());
}
