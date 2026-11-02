//! The `__json` text of a `.drv` as Nix reads and writes it again:
//! parsed-derivations.cc:StructuredAttrs::parse, then `dump()`.
//! nlohmann::json keeps the keys of an object in a `std::map`, so the text
//! comes back with its keys sorted bytewise and the last of two equal keys.

const std = @import("std");
const text_ = @import("../syntax/text.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diag = @import("../diag.zig").Diag;

pub const Error = error{ BadJson, OutOfMemory };

/// One value of the document. Children are slices of the parse arena, and
/// neither parsing nor writing recurses: a deep value must not overflow the stack.
const Node = union(enum) {
    /// A number, boolean or null, already in the form Nix writes.
    literal: []const u8,
    /// A string, decoded.
    string: []const u8,
    array: []const Node,
    /// Sorted by key, keys unique.
    object: []const Member,
};

const Member = struct { key: []const u8, value: Node };

/// The `__json` value of a `.drv` in the form Nix writes it, allocated with
/// `gpa`, or Nix's error.
pub fn normaliseStructuredAttrs(gpa: Allocator, text: []const u8, d: *Diag) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var p: Parser = .{ .s = text, .arena = arena.allocator(), .d = d };
    const root = try p.document();
    const kind = switch (root) {
        .object => {
            var out: Writer.Allocating = try .initCapacity(gpa, text.len);
            errdefer out.deinit();
            write(arena.allocator(), &out.writer, root) catch return error.OutOfMemory;
            return out.toOwnedSlice();
        },
        .array => "array",
        .string => "string",
        .literal => |l| switch (l[0]) {
            'n' => "null",
            't', 'f' => "boolean",
            else => "number",
        },
    };
    return d.fail(error.BadJson, "cannot process __json attribute: [json.exception.type_error.302] type must be object, but is {s}", .{kind});
}

/// `json.erase(key)` on a top-level object, then `dump()`, allocated with
/// `gpa`; null when there is no `key`, so the caller keeps its text as it is.
pub fn eraseKey(gpa: Allocator, text: []const u8, key: []const u8, d: *Diag) Error!?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var p: Parser = .{ .s = text, .arena = arena.allocator(), .d = d };
    const root = try p.document();
    if (root != .object) return null;
    const members = root.object;
    const i = for (members, 0..) |m, i| {
        if (std.mem.eql(u8, m.key, key)) break i;
    } else return null;
    const rest = try std.mem.concat(arena.allocator(), Member, &.{ members[0..i], members[i + 1 ..] });
    var out: Writer.Allocating = try .initCapacity(gpa, text.len);
    errdefer out.deinit();
    write(arena.allocator(), &out.writer, .{ .object = rest }) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    arena: Allocator,
    d: *Diag,

    fn err(p: *Parser, comptime what: []const u8) Error {
        const before = p.s[0..@min(p.i, p.s.len)];
        const line = 1 + std.mem.count(u8, before, "\n");
        const col = 1 + before.len - (if (std.mem.lastIndexOfScalar(u8, before, '\n')) |n| n + 1 else 0);
        return p.d.fail(error.BadJson, "cannot process __json attribute: [json.exception.parse_error.101] parse error at line {d}, column {d}: {s}", .{ line, col, what });
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn ws(p: *Parser) void {
        while (p.peek()) |c| switch (c) {
            ' ', '\t', '\n', '\r' => p.i += 1,
            else => return,
        };
    }

    /// An array or object not yet closed: its children so far are
    /// `pending[start..]`, and for an object `key` is that of the value that
    /// comes next.
    const Open = struct { object: bool, start: usize, key: []const u8 = "" };

    fn document(p: *Parser) Error!Node {
        if (std.mem.startsWith(u8, p.s, "\xef\xbb\xbf")) p.i = 3;
        var open: std.ArrayList(Open) = .empty;
        var pending: std.ArrayList(Member) = .empty;
        while (true) {
            p.ws();
            var done: Node = switch (p.peek() orelse 0) {
                '{' => blk: {
                    p.i += 1;
                    p.ws();
                    if (p.peek() == '}') {
                        p.i += 1;
                        break :blk .{ .object = &.{} };
                    }
                    try open.append(p.arena, .{ .object = true, .start = pending.items.len, .key = try p.key() });
                    continue;
                },
                '[' => blk: {
                    p.i += 1;
                    p.ws();
                    if (p.peek() == ']') {
                        p.i += 1;
                        break :blk .{ .array = &.{} };
                    }
                    try open.append(p.arena, .{ .object = false, .start = pending.items.len });
                    continue;
                },
                else => try p.scalar(),
            };
            while (true) {
                if (open.items.len == 0) {
                    p.ws();
                    // nlohmann's lexer reads a NUL byte between tokens as the end
                    if (p.peek()) |c| if (c != 0)
                        return p.err("syntax error while parsing value - unexpected input; expected end of input");
                    return done;
                }
                const top = &open.items[open.items.len - 1];
                try pending.append(p.arena, .{ .key = top.key, .value = done });
                p.ws();
                const c = p.peek();
                if (c == ',') {
                    p.i += 1;
                    if (top.object) {
                        p.ws();
                        top.key = try p.key();
                    }
                    break;
                }
                if (c == @as(u8, if (top.object) '}' else ']')) {
                    p.i += 1;
                    done = try p.close(top.*, &pending);
                    open.items.len -= 1;
                    continue;
                }
                return if (top.object)
                    p.err("syntax error while parsing object - expected ',' or '}'")
                else
                    p.err("syntax error while parsing array - expected ',' or ']'");
            }
        }
    }

    fn close(p: *Parser, o: Open, pending: *std.ArrayList(Member)) Error!Node {
        const items = pending.items[o.start..];
        defer pending.items.len = o.start;
        if (!o.object) {
            const a = try p.arena.alloc(Node, items.len);
            for (items, a) |m, *n| n.* = m.value;
            return .{ .array = a };
        }
        // stable, so of two equal keys the later stays later; it is the one kept
        std.mem.sort(Member, items, {}, struct {
            fn lt(_: void, a: Member, b: Member) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        var n: usize = 0;
        for (items) |m| {
            if (n > 0 and std.mem.eql(u8, items[n - 1].key, m.key)) {
                items[n - 1] = m;
                continue;
            }
            items[n] = m;
            n += 1;
        }
        return .{ .object = try p.arena.dupe(Member, items[0..n]) };
    }

    /// An object key and the `:` after it.
    fn key(p: *Parser) Error![]const u8 {
        if (p.peek() != '"') return p.err("syntax error while parsing object key - invalid literal");
        const k = try p.string();
        p.ws();
        if (p.peek() != ':') return p.err("syntax error while parsing object separator - expected ':'");
        p.i += 1;
        return k;
    }

    fn scalar(p: *Parser) Error!Node {
        const c = p.peek() orelse return p.err("syntax error while parsing value - unexpected end of input");
        return switch (c) {
            '"' => .{ .string = try p.string() },
            't' => p.literal("true"),
            'f' => p.literal("false"),
            'n' => p.literal("null"),
            '-', '0'...'9' => .{ .literal = try p.number() },
            else => p.err("syntax error while parsing value - invalid literal"),
        };
    }

    fn literal(p: *Parser, comptime lit: []const u8) Error!Node {
        if (!std.mem.startsWith(u8, p.s[p.i..], lit)) return p.err("syntax error while parsing value - invalid literal");
        p.i += lit.len;
        return .{ .literal = lit };
    }

    fn hex4(p: *Parser) Error!u21 {
        const bad = "syntax error while parsing value - invalid string: '\\u' must be followed by 4 hex digits";
        if (p.i + 4 > p.s.len) return p.err(bad);
        var v: u21 = 0;
        for (p.s[p.i..][0..4]) |c| v = v * 16 + (std.fmt.charToDigit(c, 16) catch return p.err(bad));
        p.i += 4;
        return v;
    }

    /// A string from its opening quote, decoded.
    fn string(p: *Parser) Error![]const u8 {
        const surrogate = "syntax error while parsing value - invalid string: surrogate U+D800..U+DBFF must be followed by U+DC00..U+DFFF";
        p.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.err("syntax error while parsing value - invalid string: missing closing quote");
            p.i += 1;
            switch (c) {
                '"' => return out.items,
                '\\' => {
                    const e = p.peek();
                    p.i += 1;
                    const plain: u8 = switch (e orelse 0) {
                        '"' => '"',
                        '\\' => '\\',
                        '/' => '/',
                        'b' => 8,
                        'f' => 12,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'u' => {
                            var cp = try p.hex4();
                            if (cp >= 0xD800 and cp < 0xDC00) {
                                if (!std.mem.startsWith(u8, p.s[p.i..], "\\u")) return p.err(surrogate);
                                p.i += 2;
                                const lo = try p.hex4();
                                if (lo < 0xDC00 or lo >= 0xE000) return p.err(surrogate);
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            } else if (cp >= 0xDC00 and cp < 0xE000) {
                                return p.err("syntax error while parsing value - invalid string: surrogate U+DC00..U+DFFF must follow U+D800..U+DBFF");
                            }
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                            try out.appendSlice(p.arena, buf[0..n]);
                            continue;
                        },
                        else => return p.err("syntax error while parsing value - invalid string: forbidden character after backslash"),
                    };
                    try out.append(p.arena, plain);
                },
                0...0x1f => return p.err("syntax error while parsing value - invalid string: control character must be escaped"),
                0x80...0xff => {
                    const start = p.i - 1;
                    const len: usize = switch (c) {
                        0xc2...0xdf => 2,
                        0xe0...0xef => 3,
                        0xf0...0xf4 => 4,
                        else => 1,
                    };
                    if (start + len > p.s.len or !std.unicode.utf8ValidateSlice(p.s[start..][0..len]))
                        return p.err("syntax error while parsing value - invalid string: ill-formed UTF-8 byte");
                    try out.appendSlice(p.arena, p.s[start..][0..len]);
                    p.i = start + len;
                },
                else => try out.append(p.arena, c),
            }
        }
    }

    fn digits(p: *Parser) void {
        while (p.peek()) |c| switch (c) {
            '0'...'9' => p.i += 1,
            else => return,
        };
    }

    fn isDigit(c: ?u8) bool {
        return c != null and std.ascii.isDigit(c.?);
    }

    /// A number in the form nlohmann writes it.
    fn number(p: *Parser) Error![]const u8 {
        const start = p.i;
        const neg = p.peek() == '-';
        if (neg) p.i += 1;
        switch (p.peek() orelse 0) {
            '0' => p.i += 1,
            '1'...'9' => p.digits(),
            else => return p.err("syntax error while parsing value - invalid number; expected digit after '-'"),
        }
        var float = false;
        if (p.peek() == '.') {
            float = true;
            p.i += 1;
            if (!isDigit(p.peek())) return p.err("syntax error while parsing value - invalid number; expected digit after '.'");
            p.digits();
        }
        if (p.peek() == 'e' or p.peek() == 'E') {
            float = true;
            p.i += 1;
            if (p.peek() == '+' or p.peek() == '-') p.i += 1;
            if (!isDigit(p.peek())) return p.err("syntax error while parsing value - invalid number; expected digit after exponent");
            p.digits();
        }
        const text = p.s[start..p.i];
        // an integer out of range becomes a double, as in nlohmann's lexer
        if (!float) {
            if (neg) {
                if (std.fmt.parseInt(i64, text, 10)) |v| return std.fmt.allocPrint(p.arena, "{d}", .{v}) else |_| {}
            } else if (std.fmt.parseInt(u64, text, 10)) |v| return std.fmt.allocPrint(p.arena, "{d}", .{v}) else |_| {}
        }
        const f = std.fmt.parseFloat(f64, text) catch unreachable;
        if (!std.math.isFinite(f))
            return p.d.fail(error.BadJson, "cannot process __json attribute: [json.exception.out_of_range.406] number overflow parsing '{s}'", .{text});
        var buf: [64]u8 = undefined;
        return p.arena.dupe(u8, jsonFloat(&buf, f));
    }
};

/// Shortest round-trip float, as nlohmann::json writes it: plain decimal for
/// exponents in [-4, 15), with `.0` when it would read as an integer, and
/// `<mantissa>e<sign><two digits>` otherwise. `buf` needs 32 bytes.
pub fn jsonFloat(buf: []u8, f: f64) []const u8 {
    if (!std.math.isFinite(f)) return "null";
    var sci_buf: [32]u8 = undefined;
    const sci = std.fmt.bufPrint(&sci_buf, "{e}", .{f}) catch unreachable;
    const e = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e + 1 ..], 10) catch unreachable;
    if (exp >= -4 and exp < 15) {
        const s = std.fmt.bufPrint(buf, "{d}", .{f}) catch unreachable;
        if (std.mem.indexOfScalar(u8, s, '.') != null) return s;
        buf[s.len..][0..2].* = ".0".*;
        return buf[0 .. s.len + 2];
    }
    return std.fmt.bufPrint(buf, "{s}e{c}{d:0>2}", .{ sci[0..e], @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch unreachable;
}

/// The text of `root`, as nlohmann's `dump()` writes it, from an explicit stack.
fn write(scratch: Allocator, w: *Writer, root: Node) (Writer.Error || Allocator.Error)!void {
    const Frame = struct { node: Node, next: usize = 0 };
    var stack: std.ArrayList(Frame) = .empty;
    try stack.append(scratch, .{ .node = root });
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        switch (top.node) {
            .literal => |l| {
                try w.writeAll(l);
                stack.items.len -= 1;
            },
            .string => |s| {
                try text_.writeJsonStringRaw(w, s);
                stack.items.len -= 1;
            },
            .array => |a| {
                if (top.next == a.len) {
                    try w.writeAll(if (a.len == 0) "[]" else "]");
                    stack.items.len -= 1;
                    continue;
                }
                try w.writeByte(if (top.next == 0) '[' else ',');
                top.next += 1;
                try stack.append(scratch, .{ .node = a[top.next - 1] });
            },
            .object => |o| {
                if (top.next == o.len) {
                    try w.writeAll(if (o.len == 0) "{}" else "}");
                    stack.items.len -= 1;
                    continue;
                }
                try w.writeByte(if (top.next == 0) '{' else ',');
                const m = o[top.next];
                top.next += 1;
                try text_.writeJsonStringRaw(w, m.key);
                try w.writeByte(':');
                try stack.append(scratch, .{ .node = m.value });
            },
        }
    }
}

const testing = std.testing;

fn norm(text: []const u8, d: *Diag) ![]u8 {
    return normaliseStructuredAttrs(testing.allocator, text, d);
}

// What the `drv-oracle` of nix-conformance (Nix 2.34.8) wrote for each `__json` text.
test "as nix writes it" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const cases = [_][2][]const u8{
        .{ "{\"b\":1,\"a\":2}", "{\"a\":2,\"b\":1}" },
        .{ "{\"a\":1,\"a\":2}", "{\"a\":2}" },
        .{ "{\"a\":-0,\"b\":-0.0}", "{\"a\":0,\"b\":-0.0}" },
        .{ "{\"a\":1e-400}", "{\"a\":0.0}" },
        .{ "{\"a\":18446744073709551615}", "{\"a\":18446744073709551615}" },
        .{ "{\"a\":18446744073709551616}", "{\"a\":1.8446744073709552e+19}" },
        .{ "{\"a\":-9223372036854775809}", "{\"a\":-9.223372036854776e+18}" },
        .{ "{\"a\":1E5,\"b\":1.5e300}", "{\"a\":100000.0,\"b\":1.5e+300}" },
        .{ "\u{feff} {\"a\" : [ 1 , 2 ] } \n", "{\"a\":[1,2]}" },
        .{ "{\"a\":\"\\u0000\\u001f\\/\\ud83d\\ude00\"}", "{\"a\":\"\\u0000\\u001f/\u{1f600}\"}" },
        .{ "{\"\u{e9}\":1,\"z\":2,\"Z\":3,\"_\":4}", "{\"Z\":3,\"_\":4,\"z\":2,\"\u{e9}\":1}" },
        .{ "{\"a\":1} \x00}\"", "{\"a\":1}" },
        .{ "{\"a\":{},\"b\":[]}", "{\"a\":{},\"b\":[]}" },
    };
    for (cases) |c| {
        const got = try norm(c[0], &d);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "what nix refuses" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const cases = [_][2][]const u8{
        .{ "[1]", "type must be object, but is array" },
        .{ "null", "type must be object, but is null" },
        .{ "{\"a\":1e400}", "number overflow parsing '1e400'" },
        .{ "{\"a\":\"x\x00y\"}", "control character must be escaped" },
        .{ "{\"a\":\"\\ud800\"}", "invalid string" },
        .{ "{\"a\":\"\xff\"}", "ill-formed UTF-8" },
        .{ "{\"a\":1} x", "expected end of input" },
        .{ "", "unexpected end of input" },
        .{ "{\"a\":01}", "expected ',' or '}'" },
        .{ "{\"a\":1.}", "expected digit after '.'" },
    };
    for (cases) |c| {
        try testing.expectError(error.BadJson, norm(c[0], &d));
        try testing.expect(std.mem.startsWith(u8, d.message(), "cannot process __json attribute: "));
        if (std.mem.indexOf(u8, d.message(), c[1]) == null) {
            std.debug.print("{s}\n", .{d.message()});
            return error.TestUnexpectedResult;
        }
    }
    _ = norm("{\"a\":\n  x}", &d) catch {};
    try testing.expectEqualStrings("cannot process __json attribute: [json.exception.parse_error.101] parse error at line 2, column 3: syntax error while parsing value - invalid literal", d.message());
}

// The deepest value a 16 KiB `drv-read` input can hold.
test "deep nesting" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const depth = 8192;
    const text = try std.mem.concat(testing.allocator, u8, &.{ "{\"a\":", &@as([depth]u8, @splat('[')), &@as([depth]u8, @splat(']')), "}" });
    defer testing.allocator.free(text);
    const got = try norm(text, &d);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(text, got);
}

test "jsonFloat" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.0001", jsonFloat(&buf, 0.0001));
    try testing.expectEqualStrings("1e-05", jsonFloat(&buf, 0.00001));
    try testing.expectEqualStrings("123.456", jsonFloat(&buf, 123.456));
    try testing.expectEqualStrings("1e+15", jsonFloat(&buf, 1e15));
    try testing.expectEqualStrings("100000000000000.0", jsonFloat(&buf, 1e14));
    try testing.expectEqualStrings("5e-324", jsonFloat(&buf, 5e-324));
}
