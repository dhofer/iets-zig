//! The progress renderer.
//! Everything goes to stderr, so stdout stays what the command already
//! printed.
//!
//! One buffer per build, flushed as one block when that build stops, so the
//! logs of concurrent builds never interleave (ci_renderer.py:34-197). The
//! verdict closes the block, except when the block is folded, where it is
//! the header. A failure prints the last `failure_tail` lines. On
//! Actions-style CI the successes are folded with `::group::` markers. A
//! heartbeat names the running builds every `heartbeat`, and a build silent
//! for `stall` switches to live streaming.
//!
//! On a terminal the running builds are a region under the output, redrawn
//! in place with a spinner (tty_renderer.py). Verdicts scroll up above it.
//! Without a terminal the block form above is the fallback.
//!
//! The renderer is not reentrant: the dispatcher keeps it behind a lock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const log_ = @import("../log.zig");
const Log = log_.Log;
const Env = @import("../env.zig").Env;
const tty = @import("../sys/tty.zig");
const findStorePrefix = @import("../store/path.zig").findStorePrefix;
const text_ = @import("../syntax/text.zig");
const event = @import("event.zig");
const BuildEvent = event.BuildEvent;
const Kind = event.Kind;
const Duration = event.Duration;

const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;

/// Unfolded tail of a failure log.
pub const failure_tail: usize = 200;
/// Lines kept per build; the oldest rotate out.
pub const buffer_lines: usize = 10_000;
/// Lines shown when a build is escalated to live streaming.
const stall_tail: usize = 5;
pub const heartbeat_ns: u64 = 30 * ns_per_s;
pub const stall_ns: u64 = 300 * ns_per_s;
/// One spinner frame.
pub const frame_ns: u64 = 100 * ns_per_ms;
/// Log lines redraw the region at most this often.
const log_redraw_ns: u64 = 50 * ns_per_ms;
/// Log lines a terminal shows of a failed build.
const extract_lines: usize = 10;
const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const attr_width: usize = 40;
/// Builds that already stopped whose tails are kept.
const finished_kept: usize = 64;

const green = "\x1b[32m";
const red = "\x1b[31m";
const yellow = "\x1b[33m";
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

pub const Mode = enum {
    /// A terminal: one line per state change, logs only on failure.
    tty,
    /// No terminal: the whole log of every build, in one block.
    ci,
};

/// The renderer's settings. `fold` is on when the CI is Actions-shaped.
pub const Style = struct {
    mode: Mode,
    color: bool,
    fold: bool,
    quiet: bool,

    /// What the environment asks for: a terminal on stderr means `tty`,
    /// `GITHUB_ACTIONS`/`GITEA_ACTIONS`/`FORGEJO_ACTIONS` mean folding.
    pub fn detect(log: *Log) Style {
        return .{
            .mode = if (log.interactive()) .tty else .ci,
            .color = log.color(),
            .fold = actionsCi(log.env),
            .quiet = false,
        };
    }
};

/// The CIs whose logs understand `::group::` markers.
fn actionsCi(env: Env) bool {
    for ([_][]const u8{ "GITHUB_ACTIONS", "GITEA_ACTIONS", "FORGEJO_ACTIONS" }) |v| {
        if (env.nonEmpty(v) != null) return true;
    }
    return false;
}

/// The status line under the builds, in the colours of the rows above it.
pub fn writeStatus(w: *Writer, color: bool, line: []const u8) !void {
    const mark = "⏵";
    if (!color or !std.mem.startsWith(u8, line, mark)) return w.writeAll(line);
    const rest = line[mark.len..];
    // the time a task has taken is the one part that stays in the background
    var txt = rest;
    var age: []const u8 = "";
    if (std.mem.lastIndexOf(u8, rest, " (")) |at| if (std.mem.endsWith(u8, rest, ")")) {
        txt = rest[0..at];
        age = rest[at..];
    };
    try w.print(yellow ++ mark ++ reset ++ "{s}", .{txt});
    if (age.len > 0) try w.print(dim ++ "{s}" ++ reset, .{age});
}

/// Where the time comes from: the awake clock of the log's `Io`, or a
/// test's own.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// Monotonic nanoseconds; null reads the awake clock.
    now: ?*const fn (ctx: ?*anyopaque) u64 = null,
};

/// Takes the lines of the region; they live only for the call. Empty takes
/// the region down.
pub const Live = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, lines: []const []const u8) void,

    /// The region of `log`, under its output.
    pub fn onLog(log: *Log) Live {
        return .{ .ctx = log, .f = struct {
            fn f(c: ?*anyopaque, lines: []const []const u8) void {
                const l: *Log = @ptrCast(@alignCast(c.?));
                l.setRegion(lines) catch {};
            }
        }.f };
    }
};

/// A writer into the log's stderr, so the output
/// scrolls above the live region. Flushed once per block of lines.
pub const LogOut = struct {
    log: *Log,
    writer: Writer,

    pub fn init(log: *Log, buffer: []u8) LogOut {
        return .{ .log = log, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const o: *LogOut = @fieldParentPtr("writer", w);
        if (w.end > 0) o.log.err(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            if (d.len > 0) o.log.err(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        if (last.len > 0) for (0..splat) |_| o.log.err(last);
        return n + last.len * splat;
    }
};

const Lines = std.Deque([]u8);

/// One build's buffered output.
const Build = struct {
    drv: []u8,
    /// The attribute plus its source position, for the state-change lines.
    label: []u8,
    /// The attribute alone, for the per-line log prefix.
    short: []u8,
    /// Where the derivation was defined, for the failure line.
    pos: ?[]u8,
    started: u64,
    /// When the build's activity ended, for a build whose verdict the op
    /// that owns it reports later.
    ended: ?u64 = null,
    last_output: u64,
    lines: Lines = .empty,
    dropped: bool = false,
    phase: ?[]u8 = null,
    /// Escalated by the stall detector: lines go out as they arrive and the
    /// final block is skipped.
    streaming: bool = false,

    fn deinit(b: *Build, gpa: Allocator) void {
        gpa.free(b.drv);
        gpa.free(b.label);
        gpa.free(b.short);
        if (b.pos) |p| gpa.free(p);
        if (b.phase) |p| gpa.free(p);
        var it = b.lines.iterator();
        while (it.next()) |l| gpa.free(l);
        b.lines.deinit(gpa);
    }

    /// The last `n` lines, borrowed, in an array from `arena`.
    fn tail(b: *const Build, arena: Allocator, n: usize) ![]const []const u8 {
        const skip = b.lines.len -| n;
        const out = try arena.alloc([]const u8, b.lines.len - skip);
        for (out, skip..) |*o, i| o.* = b.lines.at(i);
        return out;
    }

    /// How long the build ran: to its activity's end when that is known.
    fn elapsed(b: *const Build, now: u64) u64 {
        return (b.ended orelse now) -| b.started;
    }
};

/// The tail kept of a build that stopped.
const Finished = struct {
    drv: []u8,
    tail: [][]u8,

    fn deinit(f: Finished, gpa: Allocator) void {
        gpa.free(f.drv);
        freeLines(gpa, f.tail);
    }
};

/// Frees what `liveTail`, `retainedTail` and `heldSuccesses` return.
pub fn freeLines(gpa: Allocator, lines: [][]u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

fn dupeLines(gpa: Allocator, lines: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, lines.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |l| gpa.free(l);
        gpa.free(out);
    }
    for (lines) |l| {
        out[n] = try gpa.dupe(u8, l);
        n += 1;
    }
    return out;
}

/// Derivation paths, each key owned by the set.
const DrvSet = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(s: *DrvSet, gpa: Allocator) void {
        s.clear(gpa);
        s.map.deinit(gpa);
    }

    fn contains(s: *const DrvSet, drv: []const u8) bool {
        return s.map.contains(drv);
    }

    fn insert(s: *DrvSet, gpa: Allocator, drv: []const u8) !void {
        const gop = try s.map.getOrPut(gpa, drv);
        if (gop.found_existing) return;
        gop.key_ptr.* = gpa.dupe(u8, drv) catch |e| {
            s.map.removeByPtr(gop.key_ptr);
            return e;
        };
    }

    fn remove(s: *DrvSet, gpa: Allocator, drv: []const u8) bool {
        const kv = s.map.fetchRemove(drv) orelse return false;
        gpa.free(kv.key);
        return true;
    }

    fn clear(s: *DrvSet, gpa: Allocator) void {
        var it = s.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        s.map.clearRetainingCapacity();
    }
};

/// By derivation; the key is the build's own `drv`.
const Builds = std.StringArrayHashMapUnmanaged(Build);

pub const Renderer = struct {
    gpa: Allocator,
    /// For internal-json, the message records and the hash mismatches.
    log: *Log,
    style: Style,
    out: *Writer,
    live: ?Live = null,
    clock: Clock,
    began: u64,
    last_draw: u64,
    succeeded: usize = 0,
    failed_count: usize = 0,
    stopped_count: usize = 0,
    running: Builds = .empty,
    /// Buffers of builds that already stopped, for a failure reported after
    /// the activity ended. Bounded: only the most recent are kept.
    finished: std.Deque(Finished) = .empty,
    /// Derivations the daemon named in a failure message. The stop of a
    /// build activity says nothing about success, so this is where a
    /// dependency's verdict comes from.
    failed: DrvSet = .{},
    /// Derivations that already got a full verdict block, so the op's own
    /// result does not print the log a second time.
    verdicted: DrvSet = .{},
    /// Derivations the running build op reports a verdict for itself. The
    /// end of their activity says nothing: a build hook ends two activities
    /// for one build, and only the op's result knows whether it succeeded.
    owned: DrvSet = .{},
    /// Builds whose activity ended with no failure known yet. The daemon
    /// names a failed dependency only afterwards, so a verdict waits here
    /// until the op is over or the daemon contradicts it.
    held: Builds = .empty,
    /// Held builds whose outputs the store lacks. With `keep-going` off the
    /// daemon stops the other builds when one fails, and names only that one.
    unfinished: DrvSet = .{},
    /// The lines of one call, reset when it returns.
    tmp: std.heap.ArenaAllocator,
    /// The line being written, before the log filters it.
    line_buf: Writer.Allocating,
    /// The live region's lines, end to end.
    rows: Writer.Allocating,

    /// `clock` is `.{}` outside tests.
    pub fn init(gpa: Allocator, log: *Log, style: Style, out: *Writer, clock: Clock) Renderer {
        var r: Renderer = .{
            .gpa = gpa,
            .log = log,
            .style = style,
            .out = out,
            .clock = clock,
            .began = 0,
            .last_draw = 0,
            .tmp = .init(gpa),
            .line_buf = .init(gpa),
            .rows = .init(gpa),
        };
        r.began = r.now();
        r.last_draw = r.began;
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        const gpa = r.gpa;
        for ([_]*Builds{ &r.running, &r.held }) |m| {
            for (m.values()) |*b| b.deinit(gpa);
            m.deinit(gpa);
        }
        while (r.finished.popFront()) |f| f.deinit(gpa);
        r.finished.deinit(gpa);
        for ([_]*DrvSet{ &r.failed, &r.verdicted, &r.owned, &r.unfinished }) |s| s.deinit(gpa);
        r.tmp.deinit();
        r.line_buf.deinit();
        r.rows.deinit();
    }

    /// Draws the running builds through `live`.
    pub fn withLive(r: *Renderer, live: Live) void {
        r.live = live;
    }

    fn now(r: *const Renderer) u64 {
        if (r.clock.now) |f| return f(r.clock.ctx);
        return @intCast(Io.Clock.awake.now(r.log.io).toNanoseconds());
    }

    fn arena(r: *Renderer) Allocator {
        return r.tmp.allocator();
    }

    /// Every public call ends here: its lines are gone.
    fn done(r: *Renderer) void {
        _ = r.tmp.reset(.retain_capacity);
    }

    fn isLive(r: *const Renderer) bool {
        return r.live != null and r.style.mode == .tty and !r.style.quiet;
    }

    /// How often `heartbeat` should run, in nanoseconds.
    pub fn interval(r: *const Renderer) u64 {
        return if (r.isLive()) frame_ns else heartbeat_ns;
    }

    /// Log lines are throttled. A state change draws at once.
    fn redraw(r: *Renderer, throttled: bool) !void {
        if (!r.isLive()) return;
        const t = r.now();
        if (throttled and t -| r.last_draw < log_redraw_ns) return;
        r.last_draw = t;
        const lines = try r.region();
        r.live.?.f(r.live.?.ctx, lines);
    }

    /// `code` when the output has colours.
    fn c(r: *const Renderer, comptime code: []const u8) []const u8 {
        return if (r.style.color) code else "";
    }

    fn sgr(r: *const Renderer, comptime code: []const u8, s: []const u8) Sgr {
        return .{ .on = r.c(code), .text = s, .off = r.c(reset) };
    }

    /// `name>`, dimmed: what a build's log lines start with.
    fn prefix(r: *const Renderer, name: []const u8) Sgr {
        return .{ .on = r.c(dim), .text = name, .tail = ">", .off = r.c(reset) };
    }

    /// What a build says; under internal-json its activity records say it.
    fn shows(r: *const Renderer) bool {
        return !r.log.isJson();
    }

    /// Starts a line: write it into the result, then `end` it.
    fn begin(r: *Renderer) *Writer {
        r.line_buf.clearRetainingCapacity();
        return &r.line_buf.writer;
    }

    fn end(r: *Renderer) void {
        r.log.writeLine(r.out, r.line_buf.written()) catch {};
    }

    /// One line of a block, in colour `code`.
    fn put(r: *Renderer, comptime code: []const u8, comptime f: []const u8, args: anytype) !void {
        const w = r.begin();
        try w.writeAll(r.c(code));
        try w.print(f, args);
        if (code.len > 0) try w.writeAll(r.c(reset));
        r.end();
    }

    /// One line alone, in colour `code`.
    fn say(r: *Renderer, comptime code: []const u8, comptime f: []const u8, args: anytype) !void {
        if (!r.shows()) return;
        try r.put(code, f, args);
        r.flush();
    }

    /// The end of a block.
    fn flush(r: *Renderer) void {
        r.out.flush() catch {};
    }

    /// A header, then a row and the last log line per running build, all
    /// in one buffer.
    fn region(r: *Renderer) ![]const []const u8 {
        if (r.running.count() == 0) return &.{};
        const a = r.arena();
        const t = r.now();
        const age = t -| r.began;
        const spin = spinner[@intCast(age / frame_ns % spinner.len)];
        const buf = &r.rows;
        buf.clearRetainingCapacity();
        const w = &buf.writer;
        var ends: std.ArrayList(usize) = .empty;
        try w.print(" {f} {s}✔{d}{s} {s}✘{d}{s} ⏵{d}   {f}", .{
            r.sgr(bold, "BUILD"),
            r.c(green),
            r.succeeded,
            r.c(reset),
            r.c(red),
            r.failed_count,
            r.c(reset),
            r.running.count(),
            Duration{ .ns = age },
        });
        try ends.append(a, buf.written().len);
        const running = try a.alloc(*const Build, r.running.count());
        for (running, r.running.values()) |*p, *b| p.* = b;
        std.mem.sort(*const Build, running, {}, struct {
            fn lt(_: void, x: *const Build, y: *const Build) bool {
                if (x.started != y.started) return x.started < y.started;
                return std.mem.lessThan(u8, x.drv, y.drv);
            }
        }.lt);
        // two rows a build under the header, and one for the overflow note
        const rows: usize = if (tty.size()) |s| s[1] else 24;
        var fit = (rows -| 3) / 2;
        if (running.len > fit) fit = @max(fit -| 1, 1);
        for (running[0..@min(fit, running.len)]) |b| {
            try w.print(" {f} ", .{r.sgr(yellow, spin)});
            try fitRight(w, b.short, attr_width);
            try w.writeByte(' ');
            try padRight(w, b.phase orelse "build", 12);
            try w.writeByte(' ');
            var d: [32]u8 = undefined;
            try padLeft(w, try std.fmt.bufPrint(&d, "{f}", .{Duration{ .ns = b.elapsed(t) }}), 7);
            try ends.append(a, buf.written().len);
            try w.print("{s}     ", .{r.c(dim)});
            if (try lastLine(buf, b)) {
                try w.writeAll(r.c(reset));
                try ends.append(a, buf.written().len);
            } else buf.shrinkRetainingCapacity(ends.getLast());
        }
        if (running.len > fit) {
            try w.print("{s}     … +{d} more{s}", .{ r.c(dim), running.len - fit, r.c(reset) });
            try ends.append(a, buf.written().len);
        }
        const lines = try a.alloc([]const u8, ends.items.len);
        var from: usize = 0;
        for (lines, ends.items) |*l, e| {
            l.* = buf.written()[from..e];
            from = e;
        }
        return lines;
    }

    fn tally(r: *Renderer, ok: bool) void {
        if (ok) r.succeeded += 1 else r.failed_count += 1;
    }

    /// Takes the region down and sums up a run of several builds.
    pub fn finish(r: *Renderer) !void {
        defer r.done();
        if (r.live) |l| l.f(l.ctx, &.{});
        if (r.style.quiet or r.succeeded + r.failed_count + r.stopped_count < 2) return;
        if (!r.shows()) return;
        const w = r.begin();
        try w.print("{f} {s}✔ {d} succeeded{s}", .{ r.sgr(bold, "summary:"), r.c(green), r.succeeded, r.c(reset) });
        if (r.failed_count > 0) try w.print(" · {s}✘ {d} failed{s}", .{ r.c(red), r.failed_count, r.c(reset) });
        if (r.stopped_count > 0) try w.print(" · {s}{d} stopped{s}", .{ r.c(dim), r.stopped_count, r.c(reset) });
        try w.print(" · {f}", .{Duration{ .ns = r.now() -| r.began }});
        r.end();
        r.flush();
    }

    /// The held builds that `release` would call a success, copied with
    /// `gpa` (`freeLines`).
    pub fn heldSuccesses(r: *const Renderer, gpa: Allocator) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |d| gpa.free(d);
            out.deinit(gpa);
        }
        for (r.held.keys()) |d| {
            if (r.failed.contains(d)) continue;
            try out.ensureUnusedCapacity(gpa, 1);
            out.appendAssumeCapacity(try gpa.dupe(u8, d));
        }
        return out.toOwnedSlice(gpa);
    }

    /// Of the held builds, those that did not finish.
    pub fn setUnfinished(r: *Renderer, drvs: []const []const u8) !void {
        for (drvs) |d| try r.unfinished.insert(r.gpa, d);
    }

    /// The derivations the build op now running reports verdicts for.
    pub fn owns(r: *Renderer, drvs: []const []const u8) !void {
        r.owned.clear(r.gpa);
        for (drvs) |d| try r.owned.insert(r.gpa, d);
    }

    /// The op is over, so every failure it had to report has been reported
    /// and a held verdict is now known. Then the end of an activity decides
    /// a verdict again.
    pub fn release(r: *Renderer) !void {
        defer r.done();
        r.owned.clear(r.gpa);
        const held = try r.arena().dupe(Build, r.held.values());
        r.held.clearRetainingCapacity();
        defer for (held) |*b| b.deinit(r.gpa);
        std.mem.sort(Build, held, {}, struct {
            fn lt(_: void, x: Build, y: Build) bool {
                return (x.ended orelse x.started) < (y.ended orelse y.started);
            }
        }.lt);
        for (held) |*b| {
            const ok = !r.failed.contains(b.drv);
            if (ok and r.unfinished.remove(r.gpa, b.drv)) {
                r.stopped_count += 1;
                try r.say(dim, "·  {s} stopped after {f} (an output is not in the store)", .{ b.label, Duration{ .ns = b.elapsed(r.now()) } });
                continue;
            }
            try r.verdicted.insert(r.gpa, b.drv);
            const why: ?[]const u8 = if (ok) null else "the daemon named it only after the build ended";
            try r.verdictBlock(b, ok, why);
        }
        try r.redraw(false);
    }

    /// A line as it came, unless internal-json says it.
    fn text(r: *Renderer, l: []const u8) void {
        if (!r.shows()) return;
        r.log.writeLine(r.out, l) catch {};
        r.flush();
    }

    /// One line, outside any build: a plan note, a daemon message.
    pub fn note(r: *Renderer, msg: []const u8) void {
        r.log.writeLine(r.out, msg) catch {};
        r.flush();
    }

    pub fn event(r: *Renderer, e: *const BuildEvent) !void {
        defer r.done();
        try r.dispatch(e);
        try r.redraw(e.kind == .log);
    }

    fn dispatch(r: *Renderer, e: *const BuildEvent) !void {
        switch (e.kind) {
            .started => try r.started(e),
            .phase => |p| try r.phase(e, p),
            .log => |bytes| try r.onLog(e, bytes),
            .built => try r.verdict(e, true, null),
            .failed => |f| try r.failure(e, f.reason, f.log_tail),
            .skipped => |s| if (!r.style.quiet) {
                try r.say(dim, "· {s} skipped: {s}", .{ e.attr, s.why });
            },
        }
    }

    fn started(r: *Renderer, e: *const BuildEvent) !void {
        // A build hook starts two activities for one derivation: its own
        // "building X on 'ssh-ng://…'" and the build behind it.
        if (r.running.contains(e.drv)) return;
        const gpa = r.gpa;
        const t = r.now();
        try r.running.ensureUnusedCapacity(gpa, 1);
        const drv = try gpa.dupe(u8, e.drv);
        errdefer gpa.free(drv);
        const label = try gpa.dupe(u8, e.attr);
        errdefer gpa.free(label);
        const short = try gpa.dupe(u8, shortLabel(e.attr));
        errdefer gpa.free(short);
        const pos = if (e.pos) |p| try gpa.dupe(u8, p) else null;
        r.running.putAssumeCapacityNoClobber(drv, .{
            .drv = drv,
            .label = label,
            .short = short,
            .pos = pos,
            .started = t,
            .last_output = t,
        });
        // The verdict names the build, so a start line would repeat it.
        if (!r.style.quiet and r.style.mode == .ci) try r.say("", "▶ building {s}", .{e.attr});
    }

    fn phase(r: *Renderer, e: *const BuildEvent, p: []const u8) !void {
        const b = r.running.getPtr(e.drv) orelse return;
        const gpa = r.gpa;
        const l = try std.fmt.allocPrint(gpa, "@ phase {s}", .{p});
        errdefer gpa.free(l);
        const copy = try gpa.dupe(u8, p);
        errdefer gpa.free(copy);
        try b.lines.pushBack(gpa, l);
        if (b.phase) |old| gpa.free(old);
        b.phase = copy;
        b.last_output = r.now();
    }

    fn onLog(r: *Renderer, e: *const BuildEvent, bytes: []const u8) !void {
        const gpa = r.gpa;
        const txt: []u8 = if (std.unicode.utf8ValidateSlice(bytes))
            try gpa.dupe(u8, bytes)
        else
            try std.fmt.allocPrint(gpa, "{f}", .{text_.lossy(bytes)});
        var kept = false;
        defer if (!kept) gpa.free(txt);
        // A failure message names the derivation that failed, which is the
        // only per-derivation verdict the protocol carries.
        try r.noteFailures(txt);
        // Only the daemon's own line counts, and only until the plan
        // confirms it: a build's log can print the same words, and
        // `fix-hashes` acts on the answer. The line may end up in a build's
        // buffer, which the log never sees, so it is read off here.
        if (e.drv.len == 0) r.log.noteMismatch(txt);
        // A line the daemon did not attribute belongs to the running build
        // when there is exactly one: that is what a remote builder's own
        // stderr looks like coming back through the daemon.
        const daemon = e.drv.len == 0 and !r.style.quiet;
        const b = r.running.getPtr(e.drv) orelse if (r.running.count() == 1) blk: {
            if (daemon and r.log.isJson()) r.note(txt);
            break :blk &r.running.values()[0];
        } else {
            if (daemon) {
                r.note(txt);
            } else if (!r.style.quiet) {
                r.text(txt);
            }
            return;
        };
        b.last_output = r.now();
        if (b.lines.len == buffer_lines) {
            gpa.free(b.lines.popFront().?);
            b.dropped = true;
        }
        try b.lines.pushBack(gpa, txt);
        kept = true;
        if (b.streaming) try r.say("", "{f} {s}", .{ r.prefix(b.short), txt });
    }

    /// Every `<hash>-<name>.drv` a failure message names.
    fn noteFailures(r: *Renderer, txt: []const u8) !void {
        if (std.mem.indexOf(u8, txt, "failed") == null and std.mem.indexOf(u8, txt, "error") == null) return;
        const a = r.arena();
        const plain = try log_.stripAnsi(a, txt);
        for (try drvPaths(a, plain)) |d| try r.failed.insert(r.gpa, d);
    }

    /// A build's activity ended: flush its block, with the verdict the
    /// daemon's messages imply, and keep the tail for the op's own result.
    ///
    /// Nothing is printed for a derivation the running op owns: the
    /// activity's end says nothing about success, the op's result does, and
    /// a build hook ends two activities for one build. The buffer stays
    /// open, so the daemon's own error text still lands in that build's
    /// block.
    pub fn stopped(r: *Renderer, drv: []const u8, built: bool) !void {
        defer r.done();
        if (built and !r.failed.contains(drv)) try r.succeed(drv) else try r.settle(drv);
        try r.redraw(false);
    }

    /// The backend saw the build succeed, so the verdict needs no op.
    fn succeed(r: *Renderer, drv: []const u8) !void {
        var b = (r.running.fetchSwapRemove(drv) orelse return).value;
        defer b.deinit(r.gpa);
        try r.retain(&b);
        try r.verdicted.insert(r.gpa, b.drv);
        try r.verdictBlock(&b, true, null);
    }

    fn settle(r: *Renderer, drv: []const u8) !void {
        if (r.owned.contains(drv)) {
            if (r.running.getPtr(drv)) |b| {
                if (b.ended == null) b.ended = r.now();
            }
            return;
        }
        var b = (r.running.fetchSwapRemove(drv) orelse return).value;
        var keep = false;
        defer if (!keep) b.deinit(r.gpa);
        try r.retain(&b);
        if (r.failed.contains(drv)) {
            try r.verdicted.insert(r.gpa, b.drv);
            try r.verdictBlock(&b, false, null);
            return;
        }
        // the daemon names a failed dependency only after the activity
        // ends, so a success is not known here: the verdict waits for
        // `release`
        b.ended = r.now();
        const gop = try r.held.getOrPut(r.gpa, b.drv);
        if (gop.found_existing) gop.value_ptr.deinit(r.gpa);
        gop.key_ptr.* = b.drv;
        gop.value_ptr.* = b;
        keep = true;
    }

    fn retain(r: *Renderer, b: *const Build) !void {
        const gpa = r.gpa;
        const drv = try gpa.dupe(u8, b.drv);
        errdefer gpa.free(drv);
        const tail = try dupeLines(gpa, try b.tail(r.arena(), failure_tail));
        errdefer freeLines(gpa, tail);
        try r.finished.pushBack(gpa, .{ .drv = drv, .tail = tail });
        while (r.finished.len > finished_kept) r.finished.popFront().?.deinit(gpa);
    }

    /// `✘  <attr> failed after <t> (<reason>), defined at <file>:<line>:<col>`:
    /// the attribute without its position, then the reason, then where the
    /// derivation was defined.
    fn writeFailed(r: *const Renderer, w: *Writer, attr: []const u8, pos: ?[]const u8, elapsed: u64, reason: ?[]const u8) !void {
        try w.print("{f}  {f} failed after {f}", .{ r.sgr(red, "✘"), r.sgr(bold, attr), Duration{ .ns = elapsed } });
        if (reason) |why| if (why.len > 0) try w.print(" ({s})", .{why});
        if (pos) |p| try w.print("{s}, defined at {s}{s}", .{ r.c(dim), p, r.c(reset) });
    }

    /// The failure line alone.
    fn sayFailed(r: *Renderer, attr: []const u8, pos: ?[]const u8, elapsed: u64, reason: ?[]const u8) !void {
        if (!r.shows()) return;
        try r.writeFailed(r.begin(), attr, pos, elapsed, reason);
        r.end();
        r.flush();
    }

    fn verdict(r: *Renderer, e: *const BuildEvent, ok: bool, reason: ?[]const u8) !void {
        if (r.running.fetchSwapRemove(e.drv)) |kv| {
            var b = kv.value;
            defer b.deinit(r.gpa);
            try r.retain(&b);
            try r.verdictBlock(&b, ok, reason);
        } else if (!ok) {
            r.tally(false);
            try r.sayFailed(shortLabel(e.attr), e.pos, e.elapsed, reason);
        }
    }

    fn failure(r: *Renderer, e: *const BuildEvent, reason: []const u8, tail: []const []const u8) !void {
        if (r.held.fetchSwapRemove(e.drv)) |kv| {
            var b = kv.value;
            defer b.deinit(r.gpa);
            try r.verdicted.insert(r.gpa, e.drv);
            try r.verdictBlock(&b, false, reason);
            return;
        }
        if (r.running.contains(e.drv)) return r.verdict(e, false, reason);
        if (r.verdicted.contains(e.drv)) {
            // The block went out when the activity stopped. Say something
            // only when that block claimed a success the op now contradicts.
            if (!r.failed.contains(e.drv)) {
                r.succeeded -|= 1;
                r.tally(false);
                try r.sayFailed(shortLabel(e.attr), e.pos, e.elapsed, reason);
            }
            return;
        }
        r.tally(false);
        if (!r.shows()) return;
        try r.writeFailed(r.begin(), shortLabel(e.attr), e.pos, e.elapsed, reason);
        r.end();
        if (r.style.mode == .tty) {
            try r.extract(e.attr, e.drv, tail);
        } else {
            try r.logLines(e.attr, tail);
            try r.put(red, "✘ end of log for {s} · nix log {s}", .{ e.attr, e.drv });
        }
        r.flush();
    }

    /// Where the full log is, then its last lines.
    fn extract(r: *Renderer, attr: []const u8, drv: []const u8, tail: []const []const u8) !void {
        try r.put(dim, "── error extract (full log: nix log {s}) ──", .{drv});
        try r.logLines(attr, tail[tail.len -| extract_lines..]);
    }

    /// A build's log lines, each after its prefix.
    fn logLines(r: *Renderer, name: []const u8, lines: []const []const u8) !void {
        for (lines) |l| try r.put("", "{f} {s}", .{ r.prefix(name), l });
    }

    /// The verdict line of a build.
    fn writeHead(r: *const Renderer, w: *Writer, b: *const Build, ok: bool, reason: ?[]const u8, t: u64) !void {
        if (!ok) return r.writeFailed(w, b.short, b.pos, b.elapsed(t), reason);
        try w.print("{f}  {f} {s}({f}){s}", .{ r.sgr(green, "✔"), r.sgr(bold, b.label), r.c(dim), Duration{ .ns = b.elapsed(t) }, r.c(reset) });
    }

    fn verdictBlock(r: *Renderer, b: *const Build, ok: bool, reason: ?[]const u8) !void {
        r.tally(ok);
        if (!r.shows()) return;
        defer r.flush();
        const a = r.arena();
        const t = r.now();
        // the log is already on screen; a failure repeats its tail, whose
        // cause came before the lines the stall showed
        if ((b.streaming and ok) or r.style.quiet or (ok and r.style.mode == .tty)) {
            try r.writeHead(r.begin(), b, ok, reason, t);
            return r.end();
        }
        if (r.style.mode == .tty) {
            try r.writeHead(r.begin(), b, ok, reason, t);
            r.end();
            return r.extract(b.short, b.drv, try b.tail(a, extract_lines));
        }
        const body = try b.tail(a, if (ok) b.lines.len else failure_tail);
        if (ok and r.style.fold) {
            const w = r.begin();
            try w.writeAll("::group::");
            try r.writeHead(w, b, ok, reason, t);
            r.end();
            try r.logLines(b.short, body);
            r.log.writeLine(r.out, "::endgroup::") catch {};
        } else if (ok) {
            // the verdict closes the block: a build that has printed a ✔
            // must not keep talking. Folding needs it first, and so does a
            // failure, whose head is what a reader scrolls back to.
            try r.logLines(b.short, body);
            try r.writeHead(r.begin(), b, ok, reason, t);
            r.end();
        } else {
            const w = r.begin();
            try r.writeHead(w, b, ok, reason, t);
            if (b.dropped) try w.print(" (oldest lines dropped, buffer={d})", .{buffer_lines});
            r.end();
            try r.logLines(b.short, body);
            try r.put(red, "✘ end of log for {s}", .{b.label});
        }
    }

    /// The tail kept for a build that already stopped, copied with `gpa`
    /// (`freeLines`).
    pub fn retainedTail(r: *const Renderer, gpa: Allocator, drv: []const u8) ![][]u8 {
        var i = r.finished.len;
        while (i > 0) {
            i -= 1;
            const f = r.finished.at(i);
            if (std.mem.eql(u8, f.drv, drv)) return dupeLines(gpa, f.tail);
        }
        return gpa.alloc([]u8, 0);
    }

    /// The live buffer of a running build, copied with `gpa` (`freeLines`).
    pub fn liveTail(r: *Renderer, gpa: Allocator, drv: []const u8) ![][]u8 {
        defer r.done();
        const b = r.running.getPtr(drv) orelse return gpa.alloc([]u8, 0);
        return dupeLines(gpa, try b.tail(r.arena(), failure_tail));
    }

    /// One heartbeat: escalate the stalled builds, then name what is running.
    pub fn heartbeat(r: *Renderer) !void {
        defer r.done();
        // the region already shows every running build, spinning
        if (r.isLive()) return r.redraw(false);
        try r.checkStalls();
        if (r.running.count() == 0 or r.style.quiet or !r.shows()) return;
        const a = r.arena();
        const t = r.now();
        const builds = try a.alloc(*const Build, r.running.count());
        for (builds, r.running.values()) |*p, *b| p.* = b;
        std.mem.sort(*const Build, builds, t, struct {
            fn lt(at: u64, x: *const Build, y: *const Build) bool {
                return at -| x.started > at -| y.started;
            }
        }.lt);
        const w = r.begin();
        try w.print("{s}⏵ {d} building: ", .{ r.c(dim), builds.len });
        for (builds, 0..) |b, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s} ({f}", .{ b.label, Duration{ .ns = t -| b.started } });
            if (b.phase) |p| try w.print(", {s}", .{p});
            try w.writeAll(if (b.streaming) ") ⚠stalled" else ")");
        }
        try w.writeAll(r.c(reset));
        r.end();
        r.flush();
    }

    fn checkStalls(r: *Renderer) !void {
        const a = r.arena();
        const t = r.now();
        for (r.running.values()) |*b| {
            if (b.streaming or t -| b.last_output < stall_ns) continue;
            b.streaming = true;
            if (!r.shows()) continue;
            try r.put(bold, "⚠ {s}: no output for {f}, last lines:", .{ b.short, Duration{ .ns = t -| b.last_output } });
            try r.logLines(b.short, try b.tail(a, stall_tail));
            try r.put(bold, "⚠ {s}: streaming further output live", .{b.short});
            r.flush();
        }
    }
};

/// `text` in a colour: `on` and `off` are empty without colours.
const Sgr = struct {
    on: []const u8,
    text: []const u8,
    tail: []const u8 = "",
    off: []const u8,

    pub fn format(s: Sgr, w: *Writer) Writer.Error!void {
        try w.writeAll(s.on);
        try w.writeAll(s.text);
        try w.writeAll(s.tail);
        try w.writeAll(s.off);
    }
};
/// Characters, counted as code points: every byte that does not continue a
/// UTF-8 sequence.
fn charCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += @intFromBool(c & 0xc0 != 0x80);
    return n;
}

/// Byte offset of the `n`th character.
fn charOffset(s: []const u8, n: usize) usize {
    var seen: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xc0 == 0x80) continue;
        if (seen == n) return i;
        seen += 1;
    }
    return s.len;
}

/// `s` left-aligned, padded with spaces to `n` characters.
fn padRight(w: *Writer, s: []const u8, n: usize) !void {
    try w.writeAll(s);
    try w.splatByteAll(' ', n -| charCount(s));
}

/// `s` right-aligned in `n` characters.
fn padLeft(w: *Writer, s: []const u8, n: usize) !void {
    try w.splatByteAll(' ', n -| charCount(s));
    try w.writeAll(s);
}

/// Appends the last log line, stripped so it cannot move the cursor. False
/// when there is none, or nothing is left of it.
fn lastLine(buf: *Writer.Allocating, b: *const Build) !bool {
    var i = b.lines.len;
    const l = while (i > 0) {
        i -= 1;
        const x = b.lines.at(i);
        if (!std.mem.startsWith(u8, x, "@ phase ")) break x;
    } else return false;
    const start = buf.written().len;
    var it: log_.Plain = .{ .s = l };
    while (it.next()) |chunk| try buf.writer.writeAll(chunk);
    // drop control characters, then trim Unicode whitespace; both in place
    const s = buf.written()[start..];
    var n: usize = 0;
    var j: usize = 0;
    while (j < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[j]) catch 1;
        const end = @min(j + len, s.len);
        const cp = std.unicode.utf8Decode(s[j..end]) catch null;
        if (cp == null or !isControl(cp.?)) {
            std.mem.copyForwards(u8, s[n..], s[j..end]);
            n += end - j;
        }
        j = end;
    }
    const t = trimUnicode(s[0..n]);
    std.mem.copyForwards(u8, s, t);
    buf.shrinkRetainingCapacity(start + t.len);
    return t.len > 0;
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f);
}

/// Unicode `White_Space`.
fn isSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn trimUnicode(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = 0;
    var seen = false;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const e = @min(i + n, s.len);
        const cp = std.unicode.utf8Decode(s[i..e]) catch null;
        if (cp == null or !isSpace(cp.?)) {
            if (!seen) start = i;
            seen = true;
            end = e;
        }
        i = e;
    }
    return if (seen) s[start..end] else s[0..0];
}

/// `s` cut to `n` characters, keeping its ends, or padded to them.
fn fitRight(w: *Writer, s: []const u8, n: usize) !void {
    const chars = charCount(s);
    if (chars <= n) return padRight(w, s, n);
    const head = (n - 1) / 2;
    const tail = n - 1 - head;
    try w.writeAll(s[0..charOffset(s, head)]);
    try w.writeAll("…");
    try w.writeAll(s[charOffset(s, chars - tail)..]);
}

/// The label without the source position: `checks.x.foo (f.nix:1:2)` as
/// `checks.x.foo`, so a log prefix stays short.
fn shortLabel(label: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, label, " (") orelse return label;
    return label[0..i];
}

/// Every `<store>/<name>.drv` in `txt`, in order, without duplicates,
/// borrowed from `txt` in an array from `a`.
fn drvPaths(a: Allocator, txt: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (findStorePrefix(txt[i..])) |sp| {
        const start = i + sp.start;
        var end = start + sp.len;
        while (end < txt.len and (std.ascii.isAlphanumeric(txt[end]) or switch (txt[end]) {
            '+', '-', '.', '_' => true,
            else => false,
        })) end += 1;
        const path = txt[start..end];
        if (std.mem.endsWith(u8, path, ".drv")) {
            const dup = for (out.items) |p| {
                if (std.mem.eql(u8, p, path)) break true;
            } else false;
            if (!dup) try out.append(a, path);
        }
        i = @max(end, start + sp.len);
    }
    return out.items;
}

const testing = std.testing;

test "the status line takes the colours of the rows above" {
    const l = "⏵ copying path 'x' (51s)";
    const cases = [_]struct { bool, []const u8, []const u8 }{
        .{ true, l, "\x1b[33m⏵\x1b[0m copying path 'x'\x1b[2m (51s)\x1b[0m" },
        .{ true, "⏵ 16 copying, 301.2 MiB", "\x1b[33m⏵\x1b[0m 16 copying, 301.2 MiB" },
        .{ false, l, l },
        .{ true, "", "" },
    };
    for (cases) |c| {
        var got: Writer.Allocating = .init(testing.allocator);
        defer got.deinit();
        try writeStatus(&got.writer, c[0], c[1]);
        try testing.expectEqualStrings(c[2], got.written());
    }
}

/// A clock a test moves by hand.
const FakeClock = struct {
    t: u64 = 1000 * ns_per_s,

    fn clock(f: *FakeClock) Clock {
        return .{ .ctx = f, .now = struct {
            fn now(c: ?*anyopaque) u64 {
                const s: *FakeClock = @ptrCast(@alignCast(c.?));
                return s.t;
            }
        }.now };
    }
};

/// What the live region was given, frame by frame.
const Frames = struct {
    frames: std.ArrayList([][]u8) = .empty,

    fn deinit(f: *Frames) void {
        for (f.frames.items) |x| freeLines(testing.allocator, x);
        f.frames.deinit(testing.allocator);
    }

    fn last(f: *const Frames) [][]u8 {
        return f.frames.items[f.frames.items.len - 1];
    }

    fn live(f: *Frames) Live {
        return .{ .ctx = f, .f = struct {
            fn push(c: ?*anyopaque, lines: []const []const u8) void {
                const s: *Frames = @ptrCast(@alignCast(c.?));
                const copy = dupeLines(testing.allocator, lines) catch @panic("oom");
                s.frames.append(testing.allocator, copy) catch @panic("oom");
            }
        }.push };
    }
};

/// A renderer writing into memory, with a log of its own and a stopped
/// clock: every duration renders as `0s`.
const Harness = struct {
    log: Log,
    sink: Writer.Allocating,
    clock: FakeClock = .{},
    frames: Frames = .{},
    r: Renderer,

    fn create(mode: Mode, fold: bool, live: bool) !*Harness {
        const h = try testing.allocator.create(Harness);
        h.* = .{ .log = .init(testing.allocator, testing.io, .{}), .sink = .init(testing.allocator), .r = undefined };
        h.log.stderr_tty = false;
        h.log.sink_state = .none;
        const style: Style = .{ .mode = mode, .color = false, .fold = fold, .quiet = false };
        h.r = .init(testing.allocator, &h.log, style, &h.sink.writer, h.clock.clock());
        if (live) h.r.withLive(h.frames.live());
        return h;
    }

    fn ci(fold: bool) !*Harness {
        return create(.ci, fold, false);
    }

    fn destroy(h: *Harness) void {
        h.r.deinit();
        h.frames.deinit();
        h.sink.deinit();
        h.log.deinit();
        testing.allocator.destroy(h);
    }

    fn text(h: *Harness) []const u8 {
        return h.sink.written();
    }

    fn has(h: *Harness, s: []const u8) bool {
        return std.mem.indexOf(u8, h.text(), s) != null;
    }

    fn find(h: *Harness, s: []const u8) usize {
        return std.mem.indexOf(u8, h.text(), s) orelse std.debug.panic("{s} not in:\n{s}", .{ s, h.text() });
    }

    fn count(h: *Harness, s: []const u8) usize {
        return std.mem.count(u8, h.text(), s);
    }

    fn expectHas(h: *Harness, s: []const u8) !void {
        if (!h.has(s)) {
            std.debug.print("missing {s} in:\n{s}\n", .{ s, h.text() });
            return error.TestExpectedEqual;
        }
    }

    fn expectLacks(h: *Harness, s: []const u8) !void {
        if (h.has(s)) {
            std.debug.print("unexpected {s} in:\n{s}\n", .{ s, h.text() });
            return error.TestUnexpectedResult;
        }
    }
};

fn ev(kind: Kind) BuildEvent {
    return .init("checks.x.a", "/nix/store/a.drv", kind, 0);
}

fn send(r: *Renderer, kind: Kind) !void {
    try r.event(&ev(kind));
}

test "ci folds a success and never a failure" {
    {
        const h = try Harness.ci(true);
        defer h.destroy();
        try send(&h.r, .started);
        try send(&h.r, .{ .log = "line one" });
        try h.r.stopped("/nix/store/a.drv", false);
        try h.r.release();
        try h.expectHas("::group::✔  checks.x.a");
        try h.expectHas("checks.x.a> line one");
        try h.expectHas("::endgroup::");
    }
    const h = try Harness.ci(true);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .log = "boom" });
    try send(&h.r, .{ .failed = .{ .reason = "status 1" } });
    try h.expectLacks("::group::");
    try h.expectHas("✘  checks.x.a failed after 0s (status 1)");
    try h.expectHas("checks.x.a> boom");
}

// Unfolded, the ✔ is the last line of the block: a build that reports
// success must not keep printing its log afterwards.
test "an unfolded success ends with its verdict" {
    const h = try Harness.ci(false);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .log = "line one" });
    try h.r.stopped("/nix/store/a.drv", false);
    try h.r.release();
    const log = h.find("checks.x.a> line one");
    const done = h.find("✔  checks.x.a");
    try testing.expect(h.find("▶ building") < log and log < done);
}

test "logs of two builds do not interleave" {
    const h = try Harness.ci(false);
    defer h.destroy();
    const r = &h.r;
    try r.event(&.init("a", "/nix/store/a.drv", .started, 0));
    try r.event(&.init("b", "/nix/store/b.drv", .started, 0));
    try r.event(&.init("a", "/nix/store/a.drv", .{ .log = "a1" }, 0));
    try r.event(&.init("b", "/nix/store/b.drv", .{ .log = "b1" }, 0));
    try r.event(&.init("a", "/nix/store/a.drv", .{ .log = "a2" }, 0));
    try r.stopped("/nix/store/a.drv", false);
    try r.release();
    try r.stopped("/nix/store/b.drv", false);
    try r.release();
    const a1 = h.find("a> a1");
    const a2 = h.find("a> a2");
    const b1 = h.find("b> b1");
    try testing.expect(a1 < a2 and a2 < b1);
}

test "tty keeps successful logs off the screen" {
    const h = try Harness.create(.tty, false, false);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .log = "noise" });
    try send(&h.r, .{ .phase = "build" });
    try h.r.stopped("/nix/store/a.drv", false);
    try h.r.release();
    try h.expectLacks("▶ building");
    try h.expectHas("✔  checks.x.a (0s)");
    try h.expectLacks("noise");
}

test "the live region spins and counts" {
    const h = try Harness.create(.tty, false, true);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .phase = "buildPhase" });
    try send(&h.r, .{ .log = "compiling foo.c" });
    // log lines wait for the next frame
    try h.r.heartbeat();
    const last = h.frames.last();
    try testing.expect(std.mem.indexOf(u8, last[0], "BUILD ✔0 ✘0 ⏵1") != null);
    const spun = for (spinner) |c| {
        if (std.mem.indexOf(u8, last[1], c) != null) break true;
    } else false;
    try testing.expect(spun);
    try testing.expect(std.mem.indexOf(u8, last[1], "checks.x.a") != null);
    try testing.expect(std.mem.indexOf(u8, last[1], "buildPhase") != null);
    try testing.expectEqualStrings("compiling foo.c", std.mem.trim(u8, last[2], " "));
    // the start is not announced above the region
    try h.expectLacks("▶");

    try h.r.stopped("/nix/store/a.drv", false);
    try h.r.release();
    try h.expectHas("✔  checks.x.a (0s)");
    try h.expectLacks("compiling");
    // nothing runs, so the region is taken down
    try testing.expect(h.frames.last().len == 0);
}

test "a region row pads by characters" {
    const h = try Harness.create(.tty, false, true);
    defer h.destroy();
    try send(&h.r, .started);
    try h.r.heartbeat();
    const row = h.frames.last()[1];
    const gap: [30]u8 = @splat(' ');
    const gap2: [13]u8 = @splat(' ');
    try testing.expectEqualStrings(" ⠋ checks.x.a" ++ gap ++ " build" ++ gap2 ++ "0s", row);
}

test "a failure shows a short extract" {
    const h = try Harness.create(.tty, false, true);
    defer h.destroy();
    try send(&h.r, .started);
    var buf: [16]u8 = undefined;
    for (0..30) |i| try send(&h.r, .{ .log = try std.fmt.bufPrint(&buf, "line {d}", .{i}) });
    try send(&h.r, .{ .failed = .{ .reason = "status 1" } });
    try h.expectHas("✘  checks.x.a failed after 0s (status 1)");
    try h.expectHas("error extract (full log: nix log /nix/store/a.drv)");
    try h.expectHas("checks.x.a> line 29");
    try h.expectHas("checks.x.a> line 20");
    try h.expectLacks("line 19");
}

test "the summary follows more than one build" {
    const h = try Harness.create(.tty, false, true);
    defer h.destroy();
    for ([_][]const u8{ "a", "b" }) |n| {
        var buf: [32]u8 = undefined;
        const drv = try std.fmt.bufPrint(&buf, "/nix/store/{s}.drv", .{n});
        try h.r.event(&.init(n, drv, .started, 0));
        try h.r.event(&.init(n, drv, .{ .built = .{} }, 0));
    }
    try h.r.finish();
    try h.expectHas("summary: ✔ 2 succeeded · 0s");
    try testing.expect(h.frames.last().len == 0);
}

// A backend that saw the build succeed does not wait for the op, even for a
// build the op owns.
test "a build the backend saw succeed is verdicted at once" {
    const h = try Harness.create(.tty, false, true);
    defer h.destroy();
    try h.r.owns(&.{"/nix/store/a.drv"});
    try send(&h.r, .started);
    try h.r.stopped("/nix/store/a.drv", true);
    try h.expectHas("✔  checks.x.a (0s)");
    try testing.expect(h.frames.last().len == 0);
    // the op's own result adds nothing
    try send(&h.r, .{ .built = .{} });
    try h.r.release();
    try testing.expectEqual(1, h.count("✔"));
}

test "one build needs no summary" {
    const h = try Harness.create(.tty, false, true);
    defer h.destroy();
    try send(&h.r, .started);
    try h.r.stopped("/nix/store/a.drv", false);
    try h.r.release();
    try h.r.finish();
    try h.expectLacks("summary");
}

test "a long attribute keeps its ends" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try fitRight(&w, "short", 8);
    try testing.expectEqualStrings("short   ", w.buffered());
    w = .fixed(&buf);
    try fitRight(&w, "abcdefghijklmnopqrstuvwxyz", 11);
    try testing.expectEqual(11, charCount(w.buffered()));
    try testing.expectEqualStrings("abcde…vwxyz", w.buffered());
}

test "a daemon failure message decides the verdict" {
    const h = try Harness.ci(false);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .log = "about to fail" });
    // Unattributed, as the daemon sends it, with nix's colours.
    try h.r.event(&.init("", "", .{ .log = "\x1b[31;1merror:\x1b[0m build of '\x1b[35;1m/nix/store/a.drv\x1b[0m' failed" }, 0));
    try h.r.stopped("/nix/store/a.drv", false);
    try h.r.release();
    try h.expectHas("✘  checks.x.a failed after 0s");
    try h.expectLacks("✔");
    // The op's own result must not repeat the whole log.
    try send(&h.r, .{ .failed = .{ .reason = "status 9" } });
    try testing.expectEqual(1, h.count("about to fail"));
}

// A build hook: two activities for one derivation, and the op that owns it
// has the only verdict there is.
test "an owned build is verdicted once by its op" {
    const h = try Harness.ci(false);
    defer h.destroy();
    const r = &h.r;
    const at = struct {
        fn at(kind: Kind) BuildEvent {
            return .{ .attr = "prov-fail (/home/u/repo/default.nix:2:3)", .drv = "/nix/store/a.drv", .kind = kind, .elapsed = 0, .pos = "/home/u/repo/default.nix:2:3" };
        }
    }.at;
    try r.owns(&.{"/nix/store/a.drv"});
    try r.event(&at(.started));
    try r.event(&at(.started));
    try r.event(&at(.{ .log = "about to fail" }));
    // The hook's activity ends, then the build's; neither is a verdict.
    try r.stopped("/nix/store/a.drv", false);
    try r.stopped("/nix/store/a.drv", false);
    // The daemon's own error text is unattributed, and still belongs to the
    // one build that is running.
    try r.event(&.init("", "", .{ .log = "error: build of '/nix/store/a.drv' on 'ssh-ng://b' failed" }, 0));
    try testing.expectEqual(1, h.count("▶ building"));
    try h.expectLacks("✔");

    try r.event(&at(.{ .failed = .{ .reason = "status 1: builder failed" } }));
    try h.expectHas("✘  prov-fail failed after 0s (status 1: builder failed), defined at /home/u/repo/default.nix:2:3");
    try h.expectHas("prov-fail> about to fail");
    // The daemon's text went through the build's own block, not raw.
    try h.expectHas("prov-fail> error: build of");
}

test "drv paths of a failure message" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msg = "error: builder for '/nix/store/2ijv-x.drv' failed; nix log /nix/store/2ijv-x.drv";
    const got = try drvPaths(arena.allocator(), msg);
    try testing.expectEqual(1, got.len);
    try testing.expectEqualStrings("/nix/store/2ijv-x.drv", got[0]);
    try testing.expectEqual(0, (try drvPaths(arena.allocator(), "/nix/store/2ijv-x is an output")).len);
}

// The daemon names a failed dependency after its activity ended, so the end
// of the op, not the order of the messages, decides the verdict.
test "a failure after the activity ended never claims a success" {
    const h = try Harness.ci(false);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .log = "work" });
    try h.r.stopped("/nix/store/a.drv", false);
    // no verdict before the op is over
    try h.expectLacks("✔");
    try h.r.event(&.init("", "", .{ .log = "error: build of '/nix/store/a.drv' failed" }, 0));
    try h.r.release();
    try h.expectHas("✘  checks.x.a failed after 0s");
    try h.expectLacks("✔");
}

// Only the daemon's own line may report a mismatch; a build's log line
// prints the same words and means nothing.
test "a build log never reports a mismatch" {
    const h = try Harness.ci(false);
    defer h.destroy();
    const ln = log_.mismatch_text ++ " 'x':\n  specified: sha256-AoAoAoAoAo=\n     got:    sha256-BoBoBoBoBo=";
    const any = struct {
        fn f(_: void, _: []const u8) bool {
            return true;
        }
    }.f;
    try send(&h.r, .started);
    try send(&h.r, .{ .log = ln });
    try testing.expectEqual(0, h.log.resolveMismatches({}, any));
    try h.r.event(&.init("", "", .{ .log = ln }, 0));
    try testing.expectEqual(1, h.log.resolveMismatches({}, any));
}

test "heartbeat names running builds" {
    const h = try Harness.ci(false);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .phase = "configure" });
    try h.r.heartbeat();
    try h.expectHas("⏵ 1 building: checks.x.a (0s, configure)");
}

test "a stalled build that fails still shows its cause" {
    const h = try Harness.ci(false);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .log = "error: the cause" });
    for (0..stall_tail) |_| try send(&h.r, .{ .log = "waiting" });
    h.r.running.getPtr("/nix/store/a.drv").?.streaming = true;
    try send(&h.r, .{ .failed = .{ .reason = "status 1" } });
    try h.expectHas("checks.x.a> error: the cause");
}

test "a silent build streams after the stall" {
    const h = try Harness.ci(false);
    defer h.destroy();
    try send(&h.r, .started);
    try send(&h.r, .{ .log = "last words" });
    h.clock.t += stall_ns + ns_per_s;
    try h.r.heartbeat();
    try h.expectHas("⚠ checks.x.a: no output for 5m01s, last lines:\nchecks.x.a> last words\n⚠ checks.x.a: streaming further output live\n");
    try h.expectHas("⏵ 1 building: checks.x.a (5m01s) ⚠stalled");
    try send(&h.r, .{ .log = "more" });
    try h.expectHas("checks.x.a> more\n");
}

test "the last line cannot move the cursor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Build = .{ .drv = &.{}, .label = &.{}, .short = &.{}, .pos = null, .started = 0, .last_output = 0 };
    var l1 = "  \x1b[31mred\x1b[0m\r\x07\u{a0}".*;
    var l2 = "@ phase build".*;
    try b.lines.pushBack(a, &l1);
    try b.lines.pushBack(a, &l2);
    var out: Writer.Allocating = .init(a);
    try out.writer.writeAll("x");
    try testing.expect(try lastLine(&out, &b));
    try testing.expectEqualStrings("xred", out.written());
    var none: Build = .{ .drv = &.{}, .label = &.{}, .short = &.{}, .pos = null, .started = 0, .last_output = 0 };
    var l3 = " \x1b[2J\t".*;
    try none.lines.pushBack(a, &l3);
    try testing.expect(!try lastLine(&out, &none));
    try testing.expectEqualStrings("xred", out.written());
}

test "a log writer goes through the session's log" {
    var l: Log = .init(testing.allocator, testing.io, .{});
    defer l.deinit();
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    l.writeTo(&out.writer);
    var buf: [8]u8 = undefined;
    var lo: LogOut = .init(&l, &buf);
    try lo.writer.writeAll("a line longer than the buffer\n");
    try lo.writer.flush();
    try testing.expectEqualStrings("a line longer than the buffer\n", out.written());
}
