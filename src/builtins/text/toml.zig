//! `builtins.fromTOML`, with Nix's datetime rendering
//! (primops/fromTOML.cc:normalizeDatetimeFormat).
//!
//! Nix parses with toml11 pinned to `toml::spec::v(1, 0, 0)`. iets parses
//! with `toml_parser.zig`, a port of the `toml` crate Rust iets uses so the
//! errors are the same bytes; it implements 1.1, so the 1.1-only syntax is
//! taken back out with a pre-pass, `reject11` here, and a check for
//! omitted seconds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("../../eval/Evaluator.zig");
const value = @import("../../runtime/value.zig");
const Value = value.Value;
const Pos = @import("../../syntax/pos.zig").Pos;
const text = @import("../../syntax/text.zig");

pub fn fromToml(ev: *Evaluator, args: []const Value, pos: Pos) Evaluator.Error!Value {
    const s = try ev.forceStringNoCtx(args[0], pos, "while evaluating the argument passed to builtins.fromTOML");
    var buf: [96]u8 = undefined;
    if (utf8Error(&buf, s)) |msg| return ev.fail(.eval, pos, "while parsing TOML: {s}", .{msg});
    if (reject11(s)) |what| return ev.fail(.eval, pos, "while parsing TOML: {s}", .{what});
    var arena: std.heap.ArenaAllocator = .init(ev.gpa);
    defer arena.deinit();
    var err: ParseError = .{};
    const root = parse(arena.allocator(), s, &err) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return ev.fail(.eval, pos, "while parsing TOML: {s}", .{err.msg}),
    };
    return convert(ev, .{ .table = root }, pos);
}

/// A TOML document as a table, for a reader that is not `fromTOML`
/// (`iets.toml`, `IETS_CONFIG`). On `error.Syntax`, `err` says why.
pub fn parseTable(arena: Allocator, s: []const u8, err: *ParseError) error{ Syntax, OutOfMemory }!*const Table {
    var buf: [96]u8 = undefined;
    if (utf8Error(&buf, s)) |m| {
        err.* = .{ .msg = try arena.dupe(u8, m) };
        return error.Syntax;
    }
    return parse(arena, s, err);
}

/// The message Rust iets prints for invalid UTF-8 (its `Utf8Error`), or null.
fn utf8Error(buf: []u8, s: []const u8) ?[]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return null;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch
            return std.fmt.bufPrint(buf, "invalid utf-8 sequence of 1 bytes from index {d}", .{i}) catch unreachable;
        if (i + n > s.len) {
            // A truncated sequence at the end is "incomplete" only when the
            // bytes present are a valid prefix.
            var k: usize = 1;
            while (i + k < s.len and validContinuation(s[i], k, s[i + k])) k += 1;
            if (i + k == s.len) return std.fmt.bufPrint(buf, "incomplete utf-8 byte sequence from index {d}", .{i}) catch unreachable;
            return std.fmt.bufPrint(buf, "invalid utf-8 sequence of {d} bytes from index {d}", .{ k, i }) catch unreachable;
        }
        if (std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            i += n;
            continue;
        }
        var k: usize = 1;
        while (k < n and validContinuation(s[i], k, s[i + k])) k += 1;
        return std.fmt.bufPrint(buf, "invalid utf-8 sequence of {d} bytes from index {d}", .{ k, i }) catch unreachable;
    }
    return null;
}

/// Whether `c` may be byte `k` of the sequence that starts with `lead`.
fn validContinuation(lead: u8, k: usize, c: u8) bool {
    if (k == 1) {
        const lo: u8, const hi: u8 = switch (lead) {
            0xe0 => .{ 0xa0, 0xbf },
            0xed => .{ 0x80, 0x9f },
            0xf0 => .{ 0x90, 0xbf },
            0xf4 => .{ 0x80, 0x8f },
            else => .{ 0x80, 0xbf },
        };
        return c >= lo and c <= hi;
    }
    return c >= 0x80 and c <= 0xbf;
}

// The TOML 1.1 pre-pass.

/// The TOML 1.1 additions toml11 at spec 1.0.0 refuses: a newline or a
/// trailing comma inside an inline table, and the `\e` and `\xHH` string
/// escapes. Omitted seconds are caught on the parsed value instead.
fn reject11(b: []const u8) ?[]const u8 {
    var i: usize = 0;
    // '{' for an inline table, '[' for an array or a table header. Only the
    // innermost matters: a newline inside an array nested in an inline table
    // is valid 1.0. Deeper nesting than this is refused by the parser anyway.
    var open: [256]u8 = undefined;
    var depth: usize = 0;
    // The last byte that was not whitespace, a comment or inside a string.
    var last: u8 = 0;
    while (i < b.len) {
        const c = b[i];
        switch (c) {
            '#' => while (i < b.len and b[i] != '\n') {
                i += 1;
            },
            '\n' => {
                if (depth > 0 and depth <= open.len and open[depth - 1] == '{') return "newline in inline table is TOML 1.1";
                i += 1;
            },
            ' ', '\t', '\r' => i += 1,
            '"' => {
                i = skipBasicString(b, i) catch |e| return switch (e) {
                    error.EscapeE => "the \\e escape is TOML 1.1",
                    error.EscapeX => "the \\xHH escape is TOML 1.1",
                };
                last = c;
            },
            '\'' => {
                i = skipLiteralString(b, i);
                last = c;
            },
            '}' => {
                if (last == ',') return "trailing comma in inline table is TOML 1.1";
                depth -|= 1;
                last = c;
                i += 1;
            },
            ']' => {
                depth -|= 1;
                last = c;
                i += 1;
            },
            '{', '[' => {
                if (depth < open.len) open[depth] = c;
                depth += 1;
                last = c;
                i += 1;
            },
            else => {
                last = c;
                i += 1;
            },
        }
    }
    return null;
}

/// Skip a basic string, single- or multi-line, starting at its first quote.
fn skipBasicString(b: []const u8, i: usize) error{ EscapeE, EscapeX }!usize {
    const multi = std.mem.startsWith(u8, b[i + 1 ..], "\"\"");
    var j = i + @as(usize, if (multi) 3 else 1);
    while (j < b.len) {
        switch (b[j]) {
            '\\' => {
                if (j + 1 < b.len) switch (b[j + 1]) {
                    'e' => return error.EscapeE,
                    'x' => return error.EscapeX,
                    else => {},
                };
                j += 2;
            },
            '"' => {
                if (!multi) return j + 1;
                const run = quoteRun(b, j, '"');
                if (run < 3) {
                    j += run;
                } else return j + @min(run, 5);
            },
            // An unterminated string: leave it to the parser.
            '\n' => if (!multi) return j else {
                j += 1;
            },
            else => j += 1,
        }
    }
    return b.len;
}

fn skipLiteralString(b: []const u8, i: usize) usize {
    const multi = std.mem.startsWith(u8, b[i + 1 ..], "''");
    var j = i + @as(usize, if (multi) 3 else 1);
    while (j < b.len) {
        switch (b[j]) {
            '\'' => {
                if (!multi) return j + 1;
                const run = quoteRun(b, j, '\'');
                if (run < 3) {
                    j += run;
                } else return j + @min(run, 5);
            },
            '\n' => if (!multi) return j else {
                j += 1;
            },
            else => j += 1,
        }
    }
    return b.len;
}

fn quoteRun(b: []const u8, i: usize, q: u8) usize {
    var n: usize = 0;
    while (i + n < b.len and b[i + n] == q) n += 1;
    return n;
}

// The document tree, from the parser.

pub const parser = @import("toml_parser.zig");
pub const Datetime = parser.Datetime;
pub const Node = parser.Node;
pub const Array = parser.Array;
pub const Table = parser.Table;
pub const ParseError = parser.ParseError;
pub const parse = parser.parse;
pub const renderError = parser.renderError;

// Conversion to Nix values.

fn noNul(ev: *Evaluator, s: []const u8, pos: Pos) Evaluator.Error!void {
    // prim_fromTOML wraps the thrown Error's what(), prefix included.
    if (std.mem.indexOfScalar(u8, s, 0) != null)
        return ev.fail(.eval, pos, "while parsing TOML: error: {f}", .{text.noNulMessage(s)});
}

fn keyLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn convert(ev: *Evaluator, n: Node, pos: Pos) Evaluator.Error!Value {
    switch (n) {
        .string => |s| {
            try noNul(ev, s, pos);
            return ev.mkString(s);
        },
        .integer => |i| return ev.mkInt(i),
        .invalid => unreachable,
        .float => |f| return ev.mkFloat(f),
        .boolean => |b| return .fromBool(b),
        .datetime => |d| {
            // Seconds are optional only from TOML 1.1 on.
            if (d.time) |t| if (t.second == null)
                return ev.fail(.eval, pos, "while parsing TOML: a time without seconds is TOML 1.1", .{});
            if (!ev.config.parse_toml_timestamps)
                return ev.fail(.eval, pos, "while parsing TOML: Dates and times are not supported", .{});
            var buf: [64]u8 = undefined;
            var entries = [_]value.Attr{
                .{ .sym = try ev.sym("_type"), .pos = .none, .cell = .init(try ev.mkStringStatic("timestamp", &.{})) },
                .{ .sym = ev.s.value, .pos = .none, .cell = .init(try ev.mkString(formatDatetime(&buf, d))) },
            };
            return ev.mkAttrs(&entries, pos);
        },
        .array => |a| {
            const l = try ev.allocList(a.items.items.len);
            for (a.items.items, l.raw()) |it, *c| c.* = .init(try convert(ev, it, pos));
            return .fromPtr(.ptr, l);
        },
        .table => |t| {
            // The crate's table is a BTreeMap: keys convert in byte order.
            const keys = try ev.gpa.dupe([]const u8, t.map.keys());
            defer ev.gpa.free(keys);
            std.mem.sort([]const u8, keys, {}, keyLess);
            const entries = try ev.gpa.alloc(value.Attr, keys.len);
            defer ev.gpa.free(entries);
            for (keys, entries) |k, *e| {
                try noNul(ev, k, pos);
                e.* = .{ .sym = try ev.sym(k), .pos = .none, .cell = .init(try convert(ev, t.map.get(k).?, pos)) };
            }
            return ev.mkAttrs(entries, pos);
        },
    }
}

/// toml11 < 4 prints 3, 6 or 9 subsecond digits, or none.
fn subsecondPrecision(ns: u32) u32 {
    if (ns == 0) return 0;
    if (ns % 1_000_000 == 0) return 3;
    if (ns % 1_000 == 0) return 6;
    return 9;
}

pub fn formatDatetime(buf: []u8, d: Datetime) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (d.date) |date| w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ date.year, date.month, date.day }) catch unreachable;
    if (d.time) |t| {
        if (d.date != null) w.writeByte('T') catch unreachable;
        w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second orelse 0 }) catch unreachable;
        const ns = t.nanosecond orelse 0;
        const prec = subsecondPrecision(ns);
        if (prec > 0) {
            const frac = ns / std.math.pow(u32, 10, 9 - prec);
            w.print(".{d:0>[1]}", .{ frac, prec }) catch unreachable;
        }
    }
    if (d.offset) |off| switch (off) {
        .z => w.writeByte('Z') catch unreachable,
        .minutes => |m| {
            const a = @abs(m);
            w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (m < 0) '-' else '+'), a / 60, a % 60 }) catch unreachable;
        },
    };
    return w.buffered();
}

const testing = std.testing;

test "inline tables stay on one line" {
    const cases = [_]struct { []const u8, bool }{
        .{ "a = { b = 1,\n c = 2 }", false },
        .{ "a = { # hi\n b = 1 }", false },
        .{ "a = { b = 1, }", false },
        .{ "a = { b = 1 , }", false },
        .{ "a = { b = 1, c = { d = 2, } }", false },
        // a newline is fine one container deeper
        .{ "a = { b = [1,\n2] }", true },
        .{ "a = { b = \"\"\"x\ny\"\"\" }", true },
        .{ "a = [\n {b = 1},\n]", true },
        .{ "a = { b = 1 }", true },
        // braces and commas inside strings are not structure
        .{ "a = { b = \"}\", c = \",\" }", true },
        .{ "a = { b = ',' }", true },
    };
    for (cases) |c| try testing.expectEqual(c[1], reject11(c[0]) == null);
}

test "new escapes are refused" {
    try testing.expect(reject11("a = \"\\e\"") != null);
    try testing.expect(reject11("a = \"\\x41\"") != null);
    try testing.expect(reject11("a = \"\"\"\n\\e\"\"\"") != null);
    // An escaped backslash does not start an escape.
    try testing.expect(reject11("a = \"x\\\\e\"") == null);
    // Literal strings have no escapes.
    try testing.expect(reject11("a = '\\e'") == null);
    try testing.expect(reject11("a = '''\\x41'''") == null);
}

test "datetime format" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("07:32:00.500", formatDatetime(&buf, .{ .time = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 500_000_000 } }));
    try testing.expectEqualStrings("1979-05-27T00:32:00.999999-07:00", formatDatetime(&buf, .{
        .date = .{ .year = 1979, .month = 5, .day = 27 },
        .time = .{ .hour = 0, .minute = 32, .second = 0, .nanosecond = 999_999_000 },
        .offset = .{ .minutes = -420 },
    }));
}

test {
    _ = parser;
}
