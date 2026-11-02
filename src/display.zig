//! The bottom of the terminal as a live region under the scrolling output.
//!
//! Output lines are written at absolute rows inside a scroll margin that
//! ends above the region, so the region is never touched by them. The size is
//! polled on every frame. While it changes nothing is erased. Once it holds
//! still the screen is rebuilt from the lines kept in `history`, because
//! terminals disagree on how they reflow what is already drawn. Every frame is
//! one string wrapped in synchronized-update markers (tty_renderer.py:Display).

const std = @import("std");
const Allocator = std.mem.Allocator;
const tty = @import("sys/tty.zig");

const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const sync_start = "\x1b[?2026h";
const sync_end = "\x1b[?2026l";
pub const reset = "\x1b[0m";
/// Frames a smaller region must last before the region gives up its rows.
pub const shrink_after = 30;
/// Lines kept to rebuild the screen from.
const history_max = 1000;

/// Columns and rows.
pub const Size = [2]usize;

/// What a display asks of the terminal.
pub const Term = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable = &tty_vtable,

    pub const VTable = struct {
        /// Null when there is no terminal to draw on.
        size: *const fn (?*anyopaque) ?Size,
        /// Row and column of the cursor, counted from 1.
        cursor: *const fn (?*anyopaque) ?[2]usize,
        /// Where the region starts, for whatever must take it down on a signal.
        guard: *const fn (?*anyopaque, usize) void,
    };

    pub fn size(t: Term) ?Size {
        return t.vtable.size(t.ctx);
    }
    pub fn cursor(t: Term) ?[2]usize {
        return t.vtable.cursor(t.ctx);
    }
    pub fn guard(t: Term, top: usize) void {
        t.vtable.guard(t.ctx, top);
    }

    /// stderr's terminal.
    pub const stderr: Term = .{};
};

const tty_vtable: Term.VTable = .{
    .size = struct {
        fn f(_: ?*anyopaque) ?Size {
            return tty.size();
        }
    }.f,
    .cursor = struct {
        fn f(_: ?*anyopaque) ?[2]usize {
            return tty.cursor();
        }
    }.f,
    .guard = struct {
        fn f(_: ?*anyopaque, top: usize) void {
            tty.guardRegion(top);
        }
    }.f,
};

pub const Display = struct {
    /// Row, counted from 1, that the next output line goes to.
    row: usize,
    /// First row of the region as last drawn.
    top: usize,
    /// Bottom row of the scroll margin, 0 for none.
    margin: usize = 0,
    size: Size = .{ 0, 0 },
    resizing: bool = false,
    /// Rows the region keeps, so it does not twitch with every build that
    /// starts or ends.
    height: usize = 0,
    /// Frames in a row that needed fewer rows than `height`.
    calm: usize = 0,
    /// The most rows those frames needed.
    peak: usize = 0,
    history: std.ArrayList([]u8) = .empty,

    /// A display whose first output line goes to `origin`, the row the
    /// cursor is on.
    pub fn init(origin: usize) Display {
        return .{ .row = origin, .top = origin };
    }

    pub fn deinit(d: *Display, gpa: Allocator) void {
        for (d.history.items) |l| gpa.free(l);
        d.history.deinit(gpa);
    }

    /// One update: `output` lines scroll up above the region, which is
    /// redrawn as `region`. The caller owns the frame.
    pub fn frame(d: *Display, gpa: Allocator, size: Size, output_in: []const []const u8, region_in: []const []const u8) ![]u8 {
        const cols, const rows = size;
        // one row stays for output
        const cap = @max(rows -| 2, 1);
        const region = region_in[0..@min(region_in.len, cap)];
        const height = @min(d.settle(region.len), cap);
        const limit = rows - height;
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        const w = &buf.writer;
        try w.writeAll(sync_start ++ hide_cursor);
        for (output_in) |l| try d.history.append(gpa, try gpa.dupe(u8, l));
        if (d.history.items.len > history_max) {
            const drop = d.history.items.len - history_max;
            for (d.history.items[0..drop]) |l| gpa.free(l);
            d.history.replaceRangeAssumeCapacity(0, drop, &.{});
        }
        var output = output_in;
        if (size[0] != d.size[0] or size[1] != d.size[1]) {
            // absolute rows are unreliable now: release the margin, erase
            // nothing and skip the region until the size settles
            try w.writeAll("\x1b[r");
            d.margin = 0;
            d.resizing = d.size[1] != 0;
            d.size = size;
            d.row = @min(d.row, rows);
        } else if (d.resizing) {
            d.resizing = false;
            try w.writeAll("\x1b[2J\x1b[1;1H");
            d.row = try d.rebuild(w, limit);
            output = &.{};
        }
        if (!d.resizing and d.row > limit + 1) {
            // the region grew over output, which scrolls up out of its way
            try d.scroll(w, d.row - 1, d.row - limit - 1);
            d.row = limit + 1;
        }
        for (output) |line| {
            const n = rowsOf(line, cols);
            if (d.row + n - 1 <= limit) {
                try put(w, d.row, line, cols);
                d.row += n;
            } else {
                // scroll up as far as this line needs, then put it at the bottom
                try d.scroll(w, limit, d.row + n - 1 - limit);
                try put(w, @max((limit + 1) -| n, 1), line, cols);
                d.row = limit + 1;
            }
        }
        d.top = @min(d.row, limit + 1);
        if (!d.resizing) {
            for (0..height) |i| {
                const line = if (i < region.len) region[i] else "";
                // one column short, so the cursor never waits to wrap
                try w.print("\x1b[{d};1H", .{d.top + i});
                try fitInto(w, line, cols -| 1);
                try w.writeAll(reset ++ "\x1b[K");
            }
            try w.writeAll("\x1b[J");
        }
        try w.print("\x1b[{d};1H" ++ sync_end, .{d.top});
        return buf.toOwnedSlice();
    }

    /// The rows to keep for a region that needs `need`. It grows at once and
    /// shrinks once a smaller size has lasted.
    fn settle(d: *Display, need: usize) usize {
        if (need >= d.height or need == 0) {
            d.height = need;
            d.calm = 0;
            d.peak = 0;
        } else {
            d.calm += 1;
            d.peak = @max(d.peak, need);
            if (d.calm >= shrink_after) {
                d.height = d.peak;
                d.calm = 0;
                d.peak = 0;
            }
        }
        return d.height;
    }

    /// Takes the region down and lets output scroll the whole screen again.
    pub fn close(d: *const Display, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, sync_start ++ "\x1b[r\x1b[{d};1H\x1b[J" ++ show_cursor ++ sync_end, .{d.top}) catch unreachable;
    }

    /// Writes the newest lines that fit in `budget` rows from the top.
    /// Returns the row after them.
    fn rebuild(d: *const Display, w: *std.Io.Writer, budget: usize) !usize {
        const cols = d.size[0];
        var used: usize = 0;
        var take: usize = 0;
        var i = d.history.items.len;
        while (i > 0) {
            i -= 1;
            const n = rowsOf(d.history.items[i], cols);
            if (used + n > budget) break;
            used += n;
            take += 1;
        }
        var row: usize = 1;
        for (d.history.items[d.history.items.len - take ..]) |line| {
            try put(w, row, line, cols);
            row += rowsOf(line, cols);
        }
        return row;
    }

    /// Scrolls rows 1 to `bottom` up by `n`, into the scrollback.
    fn scroll(d: *Display, w: *std.Io.Writer, bottom: usize, n: usize) !void {
        if (d.margin != bottom) {
            d.margin = bottom;
            try w.print("\x1b[1;{d}r", .{bottom});
        }
        try w.print("\x1b[{d};1H", .{bottom});
        try w.splatByteAll('\n', @min(n, bottom));
    }
};

/// `line` at `row`, over whatever was there.
fn put(w: *std.Io.Writer, row: usize, line: []const u8, cols: usize) !void {
    try w.print("\x1b[{d};1H{s}" ++ reset, .{ row, line });
    // a line that ends at the last column leaves the cursor waiting to wrap,
    // and erasing from there would take that column's character along
    const width = visibleWidth(line);
    if (width == 0 or width % cols != 0) try w.writeAll("\x1b[K");
}

/// How many rows `line` takes at `cols` columns.
fn rowsOf(line: []const u8, cols: usize) usize {
    return @max(std.math.divCeil(usize, visibleWidth(line), cols) catch 1, 1);
}

/// One character of `s` at `i`: its length in bytes. An invalid byte is
/// one character, as the replacement character lossy decoding puts there.
fn charLen(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 1;
    if (i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) return 1;
    return n;
}

fn isFinal(c: u8) bool {
    return c >= '@' and c <= '~';
}

/// Columns `s` takes, leaving its escape codes out.
pub fn visibleWidth(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != 0x1b) {
            n += 1;
            i += charLen(s, i);
            continue;
        }
        i += 1;
        if (i < s.len and s[i] == '[') {
            i += 1;
            while (i < s.len) {
                const c = s[i];
                i += charLen(s, i);
                if (isFinal(c)) break;
            }
        } else if (i < s.len) {
            i += charLen(s, i);
        }
    }
    return n;
}

/// `line` cut to `width` visible columns, escape codes kept whole. A cut
/// ends with a reset, so a dropped code cannot leave its colour on.
pub fn fitInto(w: *std.Io.Writer, line: []const u8, width: usize) !void {
    var seen: usize = 0;
    var cut = false;
    var i: usize = 0;
    while (i < line.len) {
        const n = charLen(line, i);
        if (line[i] == 0x1b) {
            try w.writeByte(0x1b);
            i += 1;
            if (i < line.len) {
                const open = line[i];
                const k = charLen(line, i);
                try w.writeAll(line[i .. i + k]);
                i += k;
                if (open == '[') while (i < line.len) {
                    const c = line[i];
                    const m = charLen(line, i);
                    try w.writeAll(line[i .. i + m]);
                    i += m;
                    if (isFinal(c)) break;
                };
            }
        } else if (seen < width) {
            try w.writeAll(line[i .. i + n]);
            seen += 1;
            i += n;
        } else {
            cut = true;
            i += n;
        }
    }
    if (cut) try w.writeAll(reset);
}

pub fn fit(gpa: Allocator, line: []const u8, width: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try fitInto(&buf.writer, line, width);
    return buf.toOwnedSlice();
}

/// A terminal that gets what a display wrote: cursor addressing, erase,
/// scroll margins and autowrap, no reflow on resize. Like xterm, an erase
/// at the last column takes that column along. For the tests here and in
/// `log.zig`.
pub const Emu = struct {
    gpa: Allocator,
    grid: std.ArrayList(std.ArrayList(u21)) = .empty,
    row: usize = 0,
    col: usize = 0,
    /// The last column was written and the cursor waits to wrap.
    wrap: bool = false,
    /// First and last row of the scroll margin.
    margin: [2]usize,

    pub fn init(gpa: Allocator, rows: usize, cols: usize) !Emu {
        var e: Emu = .{ .gpa = gpa, .margin = .{ 0, rows - 1 } };
        for (0..rows) |_| try e.grid.append(gpa, try blank(gpa, cols));
        return e;
    }

    fn blank(gpa: Allocator, cols: usize) !std.ArrayList(u21) {
        var r: std.ArrayList(u21) = .empty;
        try r.appendNTimes(gpa, ' ', cols);
        return r;
    }

    pub fn deinit(e: *Emu) void {
        for (e.grid.items) |*r| r.deinit(e.gpa);
        e.grid.deinit(e.gpa);
    }

    fn width(e: *const Emu) usize {
        return e.grid.items[0].items.len;
    }

    fn lineFeed(e: *Emu) !void {
        if (e.row == e.margin[1]) {
            var gone = e.grid.orderedRemove(e.margin[0]);
            gone.deinit(e.gpa);
            try e.grid.insert(e.gpa, e.margin[1], try blank(e.gpa, e.width()));
        } else if (e.row + 1 < e.grid.items.len) {
            e.row += 1;
        }
    }

    pub fn feed(e: *Emu, s: []const u8) !void {
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |c| switch (c) {
            0x1b => {
                if (it.nextCodepoint() != '[') return error.OnlyCsiIsEmulated;
                var params: [32]u8 = undefined;
                var np: usize = 0;
                const end = while (it.nextCodepoint()) |t| {
                    if (t >= '@' and t <= '~') break t;
                    params[np] = @intCast(t);
                    np += 1;
                } else return error.UnfinishedEscape;
                try e.csi(params[0..np], @intCast(end));
            },
            '\n' => try e.lineFeed(),
            '\r' => {
                e.col = 0;
                e.wrap = false;
            },
            else => {
                if (e.wrap) {
                    e.col = 0;
                    e.wrap = false;
                    try e.lineFeed();
                }
                e.grid.items[e.row].items[e.col] = c;
                if (e.col + 1 == e.width()) e.wrap = true else e.col += 1;
            },
        };
    }

    fn csi(e: *Emu, params: []const u8, end: u8) !void {
        var n: [4]usize = @splat(0);
        var k: usize = 0;
        var parts = std.mem.splitScalar(u8, params, ';');
        while (parts.next()) |p| {
            const v = std.fmt.parseInt(usize, p, 10) catch continue;
            if (k < n.len) n[k] = v;
            k += 1;
        }
        const rows = e.grid.items.len;
        const cs = e.width();
        switch (end) {
            'H' => {
                e.row = @min(@max(n[0], 1), rows) - 1;
                e.col = @min(@max(n[1], 1), cs) - 1;
                e.wrap = false;
            },
            'K' => @memset(e.grid.items[e.row].items[e.col..], ' '),
            'J' => if (n[0] == 2) {
                for (e.grid.items) |r| @memset(r.items, ' ');
            } else {
                @memset(e.grid.items[e.row].items[e.col..], ' ');
                for (e.grid.items[e.row + 1 ..]) |r| @memset(r.items, ' ');
            },
            'r' => {
                const top = @max(n[0], 1);
                const bottom = if (n[1] == 0) rows else n[1];
                e.margin = .{ top - 1, @min(bottom, rows) - 1 };
                e.row = 0;
                e.col = 0;
                e.wrap = false;
            },
            // colours and modes change nothing drawn
            'm', 'h', 'l' => {},
            else => return error.UnemulatedCsi,
        }
    }

    pub fn resize(e: *Emu, rows: usize, cs: usize) !void {
        while (e.grid.items.len > rows) {
            var r = e.grid.pop().?;
            r.deinit(e.gpa);
        }
        while (e.grid.items.len < rows) try e.grid.append(e.gpa, try blank(e.gpa, cs));
        for (e.grid.items) |*r| {
            if (r.items.len > cs) r.shrinkRetainingCapacity(cs) else try r.appendNTimes(e.gpa, ' ', cs - r.items.len);
        }
        e.margin = .{ 0, rows - 1 };
        e.row = @min(e.row, rows - 1);
        e.col = @min(e.col, cs - 1);
        e.wrap = false;
    }

    /// The screen, each row with its trailing blanks dropped. The caller
    /// frees it with `freeScreen`.
    pub fn screen(e: *const Emu) ![][]u8 {
        const out = try e.gpa.alloc([]u8, e.grid.items.len);
        for (e.grid.items, out) |r, *o| {
            var s: std.ArrayList(u8) = .empty;
            for (r.items) |c| {
                var b: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &b) catch 1;
                try s.appendSlice(e.gpa, b[0..len]);
            }
            const t = std.mem.trimEnd(u8, s.items, " ");
            s.shrinkRetainingCapacity(t.len);
            o.* = try s.toOwnedSlice(e.gpa);
        }
        return out;
    }

    pub fn freeScreen(e: *const Emu, r: [][]u8) void {
        for (r) |x| e.gpa.free(x);
        e.gpa.free(r);
    }

    pub fn cursor(e: *const Emu) [2]usize {
        return .{ e.row, e.col };
    }
};

const testing = std.testing;
const W = 60;
const H = 12;

/// Feeds one frame to the terminal; the caller frees it.
fn show(d: *Display, e: *Emu, size: Size, output: []const []const u8, region: []const []const u8) ![]u8 {
    const f = try d.frame(testing.allocator, size, output, region);
    try e.feed(f);
    return f;
}

fn showFree(d: *Display, e: *Emu, size: Size, output: []const []const u8, region: []const []const u8) !void {
    testing.allocator.free(try show(d, e, size, output, region));
}

fn count(rows: []const []const u8, what: []const u8) usize {
    var n: usize = 0;
    for (rows) |r| {
        if (std.mem.indexOf(u8, r, what) != null) n += 1;
    }
    return n;
}

const Fixture = struct {
    d: Display,
    e: Emu,
    fn init(origin: usize, rows: usize, cs: usize) !Fixture {
        return .{ .d = .init(origin), .e = try .init(testing.allocator, rows, cs) };
    }
    fn deinit(f: *Fixture) void {
        f.d.deinit(testing.allocator);
        f.e.deinit();
    }
};

test "output scrolls and the region stays at the bottom" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    for (0..40) |i| {
        const la = try std.fmt.bufPrint(&a, "verdict-{d}-a", .{i});
        const lb = try std.fmt.bufPrint(&b, "verdict-{d}-b", .{i});
        try showFree(&f.d, &f.e, .{ W, H }, &.{ la, lb }, &.{ "HEADER", "run", "gist" });
    }
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    try testing.expectEqualStrings("HEADER", rows[H - 3]);
    try testing.expectEqualStrings("run", rows[H - 2]);
    try testing.expectEqualStrings("gist", rows[H - 1]);
    var k: usize = H - 3 - 8;
    for (36..40) |i| for ([_][]const u8{ "a", "b" }) |s| {
        const want = try std.fmt.bufPrint(&a, "verdict-{d}-{s}", .{ i, s });
        try testing.expectEqualStrings(want, rows[k]);
        k += 1;
    };
    try testing.expectEqual(1, count(rows, "HEADER"));
}

test "the region comes down on close" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    var a: [32]u8 = undefined;
    for (0..5) |i| try showFree(&f.d, &f.e, .{ W, H }, &.{try std.fmt.bufPrint(&a, "verdict-{d}", .{i})}, &.{ "HEADER", "run" });
    var cb: [64]u8 = undefined;
    try f.e.feed(f.d.close(&cb));
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    try testing.expectEqual(0, count(rows, "HEADER"));
    for (0..5) |i| try testing.expectEqualStrings(try std.fmt.bufPrint(&a, "verdict-{d}", .{i}), rows[i]);
    // the margin is gone: the cursor below the output scrolls the screen
    try testing.expectEqual([2]usize{ 5, 0 }, f.e.cursor());
}

test "growth does not eat output" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    try showFree(&f.d, &f.e, .{ W, H }, &.{"verdict-0"}, &.{"HEADER"});
    try showFree(&f.d, &f.e, .{ W, H }, &.{"verdict-1"}, &.{ "HEADER", "a", "b", "c" });
    try showFree(&f.d, &f.e, .{ W, H }, &.{}, &.{"HEADER"});
    var cb: [64]u8 = undefined;
    try f.e.feed(f.d.close(&cb));
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    try testing.expectEqualStrings("verdict-0", rows[0]);
    try testing.expectEqualStrings("verdict-1", rows[1]);
    try testing.expectEqual(0, count(rows, "HEADER") + count(rows, " a"));
}

test "output starts at the origin" {
    var f: Fixture = try .init(4, H, W);
    defer f.deinit();
    try showFree(&f.d, &f.e, .{ W, H }, &.{ "v0", "v1" }, &.{ "HEADER", "run" });
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    for ([_][]const u8{ "v0", "v1", "HEADER", "run" }, rows[3..7]) |w, r| try testing.expectEqualStrings(w, r);
    for (rows[7..]) |r| try testing.expectEqualStrings("", r);
}

test "a resize keeps one region" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    for (0..10) |i| try showFree(&f.d, &f.e, .{ W, H }, &.{try std.fmt.bufPrint(&a, "verdict-{d}", .{i})}, &.{ "HEADER", try std.fmt.bufPrint(&b, "run-{d}", .{i}) });
    try f.e.resize(8, 40);
    for (10..16) |i| try showFree(&f.d, &f.e, .{ 40, 8 }, &.{try std.fmt.bufPrint(&a, "verdict-{d}", .{i})}, &.{ "HEADER", try std.fmt.bufPrint(&b, "run-{d}", .{i}) });
    // two frames let the size settle
    try showFree(&f.d, &f.e, .{ 40, 8 }, &.{}, &.{ "HEADER", "run-16" });
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    try testing.expectEqual(1, count(rows, "HEADER"));
    try testing.expectEqualStrings("HEADER", rows[6]);
    try testing.expectEqualStrings("run-16", rows[7]);
    try testing.expectEqualStrings("verdict-15", rows[5]);
}

test "a resize burst never erases" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    try showFree(&f.d, &f.e, .{ W, H }, &.{ "verdict-0", "verdict-1" }, &.{ "HEADER", "run" });
    var burst: std.ArrayList(u8) = .empty;
    defer burst.deinit(testing.allocator);
    var a: [32]u8 = undefined;
    for ([_]usize{ 11, 10, 9 }, 0..) |rows, i| {
        try f.e.resize(rows, W);
        const fr = try show(&f.d, &f.e, .{ W, rows }, &.{try std.fmt.bufPrint(&a, "verdict-{d}", .{2 + i})}, &.{ "HEADER", "run" });
        defer testing.allocator.free(fr);
        try burst.appendSlice(testing.allocator, fr);
    }
    try testing.expect(std.mem.indexOf(u8, burst.items, "HEADER") == null);
    try testing.expect(std.mem.indexOf(u8, burst.items, "\x1b[J") == null);
    try testing.expect(std.mem.indexOf(u8, burst.items, "\x1b[2J") == null);
    try showFree(&f.d, &f.e, .{ W, 9 }, &.{"verdict-5"}, &.{ "HEADER", "run" });
    try showFree(&f.d, &f.e, .{ W, 9 }, &.{"verdict-6"}, &.{ "HEADER", "run" });
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    var shown: usize = 0;
    for (rows) |r| if (std.mem.startsWith(u8, r, "verdict-")) {
        try testing.expectEqualStrings(try std.fmt.bufPrint(&a, "verdict-{d}", .{shown}), r);
        shown += 1;
    };
    try testing.expectEqual(7, shown);
    try testing.expectEqualStrings("HEADER", rows[shown]);
    try testing.expectEqual(1, count(rows, "HEADER"));
}

test "the region keeps its rows until a smaller size lasts" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    const names = [_][]const u8{ "run-0", "run-1", "run-2", "run-3", "run-4", "run-5", "run-6", "run-7", "run-8" };
    var fill: [H][]const u8 = undefined;
    var fb: [H][16]u8 = undefined;
    for (&fill, 0..) |*l, i| l.* = try std.fmt.bufPrint(&fb[i], "out-{d}", .{i});
    const ga = testing.allocator;
    ga.free(try show(&f.d, &f.e, .{ W, H }, &fill, names[0..8]));
    const top = f.d.top;
    try testing.expectEqual(H - 7, top);
    for ([_]usize{ 3, 8, 2, 6, 3, 8, 4 }) |n| {
        ga.free(try show(&f.d, &f.e, .{ W, H }, &.{}, names[0..n]));
        try testing.expectEqual(top, f.d.top);
    }
    for (0..shrink_after) |_| ga.free(try show(&f.d, &f.e, .{ W, H }, &.{}, names[0..3]));
    // the largest of the calm frames is what stays
    try testing.expectEqual(4, f.d.height);
    ga.free(try show(&f.d, &f.e, .{ W, H }, &.{"next"}, names[0..3]));
    {
        const rows = try f.e.screen();
        defer f.e.freeScreen(rows);
        try testing.expectEqualStrings("next", rows[top - 1]);
    }
    ga.free(try show(&f.d, &f.e, .{ W, H }, &.{}, &.{}));
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    for (rows) |r| try testing.expect(!std.mem.startsWith(u8, r, "run-"));
}

test "a region that grows and shrinks loses no output" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    const names = [_][]const u8{ "run-0", "run-1", "run-2", "run-3", "run-4", "run-5", "run-6", "run-7", "run-8" };
    var n: usize = 0;
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    for (0..60) |step| {
        const heights = [_]usize{ 2, 8, 3, 9, 2 };
        const h = heights[step % 5];
        const o1 = try std.fmt.bufPrint(&a, "verdict-{d}", .{n + 1});
        const o2 = try std.fmt.bufPrint(&b, "verdict-{d}", .{n + 2});
        n += 2;
        testing.allocator.free(try show(&f.d, &f.e, .{ W, H }, &.{ o1, o2 }, names[0..h]));
    }
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    var last: ?usize = null;
    for (rows) |r| {
        if (std.mem.startsWith(u8, r, "run-")) break;
        const v = if (std.mem.startsWith(u8, r, "verdict-")) std.fmt.parseInt(usize, r[8..], 10) catch 0 else 0;
        if (last) |l| try testing.expectEqual(l + 1, v);
        last = v;
    }
    try testing.expectEqual(n, last.?);
}

test "wrapped output does not corrupt the region" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    const long = "verdict-long " ++ @as([2 * W]u8, @splat('x'));
    for (0..5) |_| try showFree(&f.d, &f.e, .{ W, H }, &.{long}, &.{ "HEADER", "run" });
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    try testing.expectEqualStrings("HEADER", rows[H - 2]);
    try testing.expectEqualStrings("run", rows[H - 1]);
    try testing.expectEqual(1, count(rows, "HEADER"));
    // three rows a line, three whole lines fit above the region
    var k: usize = 0;
    for (rows) |r| {
        if (std.mem.startsWith(u8, r, "verdict-long")) k += 1;
    }
    try testing.expectEqual(3, k);
    for (rows[H - 3]) |c| try testing.expectEqual('x', c);
}

test "a full width line keeps its last column" {
    var f: Fixture = try .init(1, H, W);
    defer f.deinit();
    const full: []const u8 = &@as([W]u8, @splat('y'));
    try showFree(&f.d, &f.e, .{ W, H }, &.{full}, &.{"HEADER"});
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    try testing.expectEqualStrings(full, rows[0]);
}

test "a frame is one synchronized write" {
    var d: Display = .init(1);
    defer d.deinit(testing.allocator);
    const f = try d.frame(testing.allocator, .{ W, H }, &.{"a"}, &.{"R"});
    defer testing.allocator.free(f);
    try testing.expect(std.mem.startsWith(u8, f, sync_start) and std.mem.endsWith(u8, f, sync_end));
    try testing.expectEqual(1, std.mem.count(u8, f, sync_start));
}

test "a region taller than the screen is clamped" {
    var f: Fixture = try .init(1, 5, W);
    defer f.deinit();
    var big: [20][]const u8 = undefined;
    var bb: [20][8]u8 = undefined;
    for (&big, 0..) |*l, i| l.* = try std.fmt.bufPrint(&bb[i], "r{d}", .{i});
    try showFree(&f.d, &f.e, .{ W, 5 }, &.{"out"}, &big);
    const rows = try f.e.screen();
    defer f.e.freeScreen(rows);
    try testing.expectEqualStrings("out", rows[0]);
    // the region floats under the output until that reaches the bottom
    try testing.expectEqualStrings("r0", rows[1]);
    try testing.expectEqualStrings("r1", rows[2]);
    try testing.expectEqualStrings("r2", rows[3]);
    try testing.expectEqualStrings("", rows[4]);
}

test "colour and width" {
    const ga = testing.allocator;
    try testing.expectEqual(3, visibleWidth("\x1b[32mabc\x1b[0m"));
    const cases = [_][3][]const u8{
        .{ "abcd", "4", "abcd" },
        .{ "\x1b[32mab\x1b[0m", "4", "\x1b[32mab\x1b[0m" },
        .{ "\x1b[32mabcdef\x1b[0m", "4", "\x1b[32mabcd\x1b[0m\x1b[0m" },
        .{ "\x1b[2mabcdef", "4", "\x1b[2mabcd\x1b[0m" },
    };
    for (cases) |c| {
        const got = try fit(ga, c[0], 4);
        defer ga.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}
