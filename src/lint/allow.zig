//! `# iets: allow NAME[, NAME...]`: a comment that silences the named lints
//! (`all` and `family:NAME` too) for one source line, whatever their level.
//! On a line of its own it covers the next non-blank, non-comment line;
//! after code it covers its own line. The lexer notes the comments, the
//! compiler resolves the names into this table, and the compiler and the
//! evaluator check a site's line before its level. A name the registry does
//! not know is the `unknown-allow` lint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lint = @import("../lint.zig");
const LintId = lint.LintId;
const Diag = @import("../diag.zig").Diag;

/// One lint per bit.
pub const Mask = u64;

comptime {
    std.debug.assert(lint.N <= 64);
}

/// The byte range of one covered line and the lints allowed on it.
pub const Line = struct { start: u32, end: u32, mask: Mask };

/// The allowed lints of one file, by the line they cover. Sorted by
/// `start`, one entry per line; empty for nearly every file.
pub const Allows = struct {
    lines: std.ArrayList(Line) = .empty,

    pub const empty: Allows = .{};

    pub fn deinit(a: *Allows, gpa: Allocator) void {
        a.lines.deinit(gpa);
    }

    pub fn isEmpty(a: *const Allows) bool {
        return a.lines.items.len == 0;
    }

    /// The table a stored entry holds, which the writer wrote in `start`
    /// order. Any other order is not a table this wrote: null, and the
    /// caller drops the entry.
    pub fn validSorted(lines: []const Line) bool {
        for (lines, 0..) |l, i| {
            if (l.mask == 0 or l.start >= l.end) return false;
            if (i > 0 and lines[i - 1].start >= l.start) return false;
        }
        return true;
    }

    /// Adds the allowed lints of the line `start..end`; a line given twice
    /// (an own-line comment above it and a trailing one on it) keeps both.
    pub fn add(a: *Allows, gpa: Allocator, start: u32, end: u32, mask: Mask) Allocator.Error!void {
        if (mask == 0 or start >= end) return;
        const items = a.lines.items;
        var i: usize = 0;
        while (i < items.len and items[i].start < start) i += 1;
        if (i < items.len and items[i].start == start) {
            items[i].mask |= mask;
            items[i].end = @max(items[i].end, end);
            return;
        }
        try a.lines.insert(gpa, i, .{ .start = start, .end = end, .mask = mask });
    }

    /// Whether `id` is allowed at byte offset `off` of the file.
    pub inline fn covers(a: *const Allows, off: u32, id: LintId) bool {
        if (a.lines.items.len == 0) return false;
        return coversSlow(a.lines.items, off, id);
    }

    noinline fn coversSlow(lines: []const Line, off: u32, id: LintId) bool {
        var lo: usize = 0;
        var hi: usize = lines.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lines[mid].start <= off) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return false;
        const l = lines[lo - 1];
        return off < l.end and l.mask & lint.bit(id) != 0;
    }
};

/// One word of a `# iets:` comment the registry cannot resolve: its byte
/// offset inside the comment text and the `unknown-allow` message.
pub const Bad = struct { at: u32, msg: []const u8 };

/// The text of one comment after `# iets:`: the mask of the lints it names,
/// and one `unknown-allow` message per name (or directive) it gets wrong.
pub fn parseComment(a: Allocator, text: []const u8, bad: *std.ArrayList(Bad)) Allocator.Error!Mask {
    var it = Words{ .text = text };
    const first = it.next() orelse {
        try bad.append(a, .{ .at = 0, .msg = "empty `# iets:` comment: use `allow NAME[, NAME...]`" });
        return 0;
    };
    if (!std.mem.eql(u8, first.word, "allow")) {
        try bad.append(a, .{ .at = first.at, .msg = try std.fmt.allocPrint(a, "unknown directive '{s}' in a `# iets:` comment: use `allow NAME[, NAME...]`", .{first.word}) });
        return 0;
    }
    var mask: Mask = 0;
    var any = false;
    var dg: Diag = .init(a);
    defer dg.deinit();
    while (it.next()) |w| {
        any = true;
        if (lint.select(w.word, &dg)) |s| {
            mask |= s.mask;
        } else |_| try bad.append(a, .{ .at = w.at, .msg = try std.fmt.allocPrint(a, "{s} in `# iets: allow`", .{dg.message()}) });
    }
    if (!any) try bad.append(a, .{ .at = first.at, .msg = "`# iets: allow` names no lint" });
    return mask;
}

const Words = struct {
    text: []const u8,
    i: usize = 0,

    fn sep(c: u8) bool {
        return c == ' ' or c == '\t' or c == ',';
    }

    fn next(w: *Words) ?struct { at: u32, word: []const u8 } {
        while (w.i < w.text.len and sep(w.text[w.i])) w.i += 1;
        if (w.i >= w.text.len) return null;
        const start = w.i;
        while (w.i < w.text.len and !sep(w.text[w.i])) w.i += 1;
        return .{ .at = @intCast(start), .word = w.text[start..w.i] };
    }
};

const testing = std.testing;

test "comment names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: std.ArrayList(Bad) = .empty;
    var m = try parseComment(a, " allow ifd, fod  family:path", &bad);
    try testing.expectEqual(lint.bit(.ifd) | lint.bit(.fod) | lint.bit(.absolute_path_literal) | lint.bit(.short_path_literal), m);
    try testing.expectEqual(0, bad.items.len);
    m = try parseComment(a, " allow all", &bad);
    try testing.expectEqual(lint.N, @popCount(m));
    try testing.expectEqual(0, bad.items.len);
    m = try parseComment(a, " allow fdo, fod", &bad);
    try testing.expectEqual(lint.bit(.fod), m);
    try testing.expectEqual(1, bad.items.len);
    try testing.expectEqual(7, bad.items[0].at);
    try testing.expect(std.mem.indexOf(u8, bad.items[0].msg, "unknown lint 'fdo'") != null);
    bad.clearRetainingCapacity();
    m = try parseComment(a, " allo fod", &bad);
    try testing.expectEqual(0, m);
    try testing.expect(std.mem.indexOf(u8, bad.items[0].msg, "unknown directive 'allo'") != null);
    bad.clearRetainingCapacity();
    m = try parseComment(a, " allow", &bad);
    try testing.expectEqual(0, m);
    try testing.expect(std.mem.indexOf(u8, bad.items[0].msg, "names no lint") != null);
    bad.clearRetainingCapacity();
    _ = try parseComment(a, "", &bad);
    try testing.expect(std.mem.indexOf(u8, bad.items[0].msg, "empty") != null);
}

test "lines" {
    var al: Allows = .{};
    defer al.deinit(testing.allocator);
    const g = testing.allocator;
    try testing.expect(!al.covers(0, .path_copy));
    try al.add(g, 10, 20, lint.bit(.path_copy));
    try al.add(g, 30, 40, lint.bit(.eq_function));
    try al.add(g, 10, 20, lint.bit(.fod));
    try al.add(g, 5, 5, lint.bit(.ifd));
    try testing.expectEqual(2, al.lines.items.len);
    try testing.expect(al.covers(10, .path_copy));
    try testing.expect(al.covers(19, .fod));
    try testing.expect(!al.covers(20, .path_copy));
    try testing.expect(!al.covers(9, .path_copy));
    try testing.expect(!al.covers(15, .eq_function));
    try testing.expect(al.covers(35, .eq_function));
    try testing.expect(!al.covers(45, .eq_function));
}
