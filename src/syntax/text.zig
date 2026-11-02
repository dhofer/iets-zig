//! Byte-string helpers for messages and output: Rust's lossy UTF-8
//! conversion (which iets's messages and JSON use), JSON string quoting,
//! and line/column lookup.

const std = @import("std");
const scan = @import("../bytes.zig");
const Writer = std.Io.Writer;

/// Length of the valid UTF-8 sequence at the start of `s`, or of its
/// maximal invalid prefix as a negative number (Unicode's "maximal subpart"
/// rule, which Rust's `from_utf8_lossy` follows: each such prefix becomes
/// one U+FFFD).
fn seqLen(s: []const u8) i8 {
    const b = s[0];
    if (b < 0x80) return 1;
    const n: u8, const lo: u8, const hi: u8 = switch (b) {
        0xc2...0xdf => .{ 2, 0x80, 0xbf },
        0xe0 => .{ 3, 0xa0, 0xbf },
        0xe1...0xec, 0xee, 0xef => .{ 3, 0x80, 0xbf },
        0xed => .{ 3, 0x80, 0x9f },
        0xf0 => .{ 4, 0x90, 0xbf },
        0xf1...0xf3 => .{ 4, 0x80, 0xbf },
        0xf4 => .{ 4, 0x80, 0x8f },
        else => return -1,
    };
    if (s.len < 2 or s[1] < lo or s[1] > hi) return -1;
    var i: u8 = 2;
    while (i < n) : (i += 1) {
        if (s.len <= i or s[i] < 0x80 or s[i] > 0xbf) return -@as(i8, @intCast(i));
    }
    return @intCast(n);
}

/// Write `s` as UTF-8, replacing invalid sequences with U+FFFD and, when
/// `nul` is set, NUL bytes with it.
pub fn writeLossy(w: *Writer, s: []const u8, nul: ?[]const u8) Writer.Error!void {
    var i: usize = 0;
    var run: usize = 0;
    while (i < s.len) {
        if (s[i] == 0 and nul != null) {
            try w.writeAll(s[run..i]);
            try w.writeAll(nul.?);
            i += 1;
            run = i;
            continue;
        }
        const n = seqLen(s[i..]);
        if (n > 0) {
            i += @intCast(n);
            continue;
        }
        try w.writeAll(s[run..i]);
        try w.writeAll("\u{fffd}");
        i += @intCast(-n);
        run = i;
    }
    try w.writeAll(s[run..]);
}

pub const Lossy = struct {
    bytes: []const u8,

    pub fn format(l: Lossy, w: *Writer) Writer.Error!void {
        return writeLossy(w, l.bytes, null);
    }
};

pub fn lossy(bytes: []const u8) Lossy {
    return .{ .bytes = bytes };
}

/// `bytes` as UTF-8 in a slice: `bytes` itself when valid, else a copy in
/// `a` with each maximal invalid subpart replaced by U+FFFD.
pub fn lossyAlloc(a: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return std.fmt.allocPrint(a, "{f}", .{lossy(bytes)});
}

pub const NoNul = struct {
    bytes: []const u8,

    pub fn format(n: NoNul, w: *Writer) Writer.Error!void {
        try w.writeAll("input string '");
        try writeLossy(w, n.bytes, "␀");
        try w.writeAll("' cannot be represented as Nix string because it contains null bytes");
    }
};

/// The message of `eval.cc:forceNoNullByte`.
pub fn noNulMessage(bytes: []const u8) NoNul {
    return .{ .bytes = bytes };
}

/// How many bytes at `i`, the start of an invalid sequence, one U+FFFD
/// stands for: the maximal subpart (`seqLen`).
pub fn invalidLen(s: []const u8, i: usize) usize {
    const n = seqLen(s[i..]);
    return if (n < 0) @intCast(-n) else 1;
}

/// A JSON string as serde_json writes it, every byte that needs no escape
/// as it is: for text already known to be UTF-8, or bytes a reader takes
/// as they come.
pub fn writeJsonStringRaw(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |b, i| {
        const esc: []const u8 = switch (b) {
            '"' => "\\\"",
            '\\' => "\\\\",
            8 => "\\b",
            12 => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...7, 11, 14...0x1f => "",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        if (esc.len > 0) try w.writeAll(esc) else try w.print("\\u{x:0>4}", .{b});
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

/// A JSON string as serde_json writes it, the bytes converted lossily.
pub fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b >= 0x80) {
            const n = seqLen(s[i..]);
            if (n > 0) {
                try w.writeAll(s[i..][0..@intCast(n)]);
                i += @intCast(n);
            } else {
                try w.writeAll("\u{fffd}");
                i += @intCast(-n);
            }
            continue;
        }
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
            else => try w.writeByte(b),
        }
        i += 1;
    }
    try w.writeByte('"');
}

/// 1-based line and column of a byte offset. The column counts bytes, as
/// Nix does. A line ends at `\n`, at `\r\n` and at a lone `\r`
/// (position.cc, `Pos::LinesIterator`).
pub fn lineCol(src: []const u8, offset: u32) struct { u32, u32 } {
    const off = @min(offset, src.len);
    var line: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (scan.findAnyPos(src, i, "\n\r")) |eol| {
        const next = if (src[eol] == '\r' and eol + 1 < src.len and src[eol + 1] == '\n') eol + 2 else eol + 1;
        if (next > off) break;
        line += 1;
        start = next;
        i = next;
    }
    return .{ line, @intCast(off - start + 1) };
}

/// The offset of each line's first byte, by the same rule as `lineCol`.
pub fn lineStarts(gpa: std.mem.Allocator, src: []const u8) ![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);
    var i: usize = 0;
    while (scan.findAnyPos(src, i, "\n\r")) |eol| {
        i = if (src[eol] == '\r' and eol + 1 < src.len and src[eol + 1] == '\n') eol + 2 else eol + 1;
        try starts.append(gpa, @intCast(i));
    }
    return starts.toOwnedSlice(gpa);
}

const testing = std.testing;

fn lossyOwned(s: []const u8) ![]u8 {
    var a: Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    try writeLossy(&a.writer, s, null);
    return a.toOwnedSlice();
}

test "lossy replaces maximal invalid subparts" {
    const cases = [_][2][]const u8{
        .{ "abc", "abc" },
        .{ "\xc3\xa9", "\xc3\xa9" },
        .{ "\xff", "\u{fffd}" },
        .{ "\xe2\x82", "\u{fffd}" },
        .{ "\xe2\x82x", "\u{fffd}x" },
        .{ "\xf0\x90\x80", "\u{fffd}" },
        .{ "\xed\xa0\x80", "\u{fffd}\u{fffd}\u{fffd}" },
        .{ "\xc0\xaf", "\u{fffd}\u{fffd}" },
        .{ "\xf4\x90\x80\x80", "\u{fffd}\u{fffd}\u{fffd}\u{fffd}" },
    };
    for (cases) |c| {
        const got = try lossyOwned(c[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "lineCol counts bytes" {
    const src = "ab\ncd\xc3\xa9f\n";
    try testing.expectEqual(.{ 1, 1 }, lineCol(src, 0));
    try testing.expectEqual(.{ 1, 3 }, lineCol(src, 2));
    try testing.expectEqual(.{ 2, 1 }, lineCol(src, 3));
    try testing.expectEqual(.{ 2, 5 }, lineCol(src, 7));
    try testing.expectEqual(.{ 3, 1 }, lineCol(src, 9));
}

test "a line ends at CR LF and lone CR" {
    const src = "a\rb\r\nc\n\rd";
    try testing.expectEqual(.{ 2, 1 }, lineCol(src, 2));
    try testing.expectEqual(.{ 2, 3 }, lineCol(src, 4));
    try testing.expectEqual(.{ 3, 1 }, lineCol(src, 5));
    try testing.expectEqual(.{ 4, 1 }, lineCol(src, 7));
    try testing.expectEqual(.{ 5, 1 }, lineCol(src, 8));
    const starts = try lineStarts(testing.allocator, src);
    defer testing.allocator.free(starts);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 5, 7, 8 }, starts);
}
