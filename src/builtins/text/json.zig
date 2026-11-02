//! `builtins.toJSON` (over `print.writeJson`) and `builtins.fromJSON`, a
//! parser with nlohmann::json's acceptance rules (json-to-value.cc).

const std = @import("std");
const Evaluator = @import("../../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Pos = @import("../../syntax/pos.zig").Pos;
const print = @import("../../eval/print.zig");
const text = @import("../../syntax/text.zig");

/// A recursive-descent limit nlohmann does not have: the parser recurses.
const max_depth: u32 = 100_000;

pub fn toJson(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    var out: std.Io.Writer.Allocating = .init(ev.gpa);
    defer out.deinit();
    var ctx: std.ArrayList(Ctx) = .empty;
    defer ctx.deinit(ev.gpa);
    print.writeJson(ev, &out.writer, args[0], &ctx, true, pos) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => |x| return x,
    };
    return ev.mkStringCtx(out.written(), ctx.items);
}

pub fn fromJson(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.fromJSON");
    var p: Parser = .{ .s = s, .ev = ev, .pos = pos };
    defer p.buf.deinit(ev.gpa);
    return p.document();
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    ev: *Evaluator,
    depth: u32 = 0,
    pos: Pos,
    /// Scratch for decoding one string.
    buf: std.ArrayList(u8) = .empty,

    /// primops.cc:prim_fromJSON traces only JSONParseError, not the integer
    /// range or null byte errors.
    fn failParse(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        const e = p.ev.fail(.eval, .none, fmt, args);
        return p.ev.addTrace(e, p.pos, "while decoding a JSON string", .{});
    }

    fn err(p: *Parser, what: []const u8) Error {
        var line: usize = 1;
        var col: usize = 1;
        for (p.s[0..@min(p.i, p.s.len)]) |b| {
            if (b == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        return p.failParse("[json.exception.parse_error.101] parse error at line {d}, column {d}: {s}", .{ line, col, what });
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn peekDigit(p: *const Parser) bool {
        const c = p.peek() orelse return false;
        return std.ascii.isDigit(c);
    }

    fn ws(p: *Parser) void {
        while (p.peek()) |c| switch (c) {
            ' ', '\t', '\n', '\r' => p.i += 1,
            else => return,
        };
    }

    fn document(p: *Parser) Error!Value {
        if (std.mem.startsWith(u8, p.s, "\xef\xbb\xbf")) p.i = 3;
        p.ws();
        const v = try p.parseValue();
        p.ws();
        if (p.i != p.s.len) return p.err("syntax error while parsing value - unexpected input; expected end of input");
        return v;
    }

    fn parseValue(p: *Parser) Error!Value {
        const c = p.peek() orelse return p.err("syntax error while parsing value - unexpected end of input");
        return switch (c) {
            '{' => p.object(),
            '[' => p.array(),
            '"' => p.ev.mkString(try p.string()),
            't' => p.literal("true", .true),
            'f' => p.literal("false", .false),
            'n' => p.literal("null", .null),
            '-', '0'...'9' => p.number(),
            else => p.err("syntax error while parsing value - invalid literal"),
        };
    }

    fn literal(p: *Parser, lit: []const u8, v: Value) Error!Value {
        if (!std.mem.startsWith(u8, p.s[p.i..], lit)) return p.err("syntax error while parsing value - invalid literal");
        p.i += lit.len;
        return v;
    }

    fn nest(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > max_depth) return p.err("nesting too deep");
        try p.ev.checkStack();
    }

    fn object(p: *Parser) Error!Value {
        try p.nest();
        p.i += 1;
        const gpa = p.ev.gpa;
        var entries: std.ArrayList(value.Attr) = .empty;
        defer entries.deinit(gpa);
        p.ws();
        if (p.peek() == '}') {
            p.i += 1;
            p.depth -= 1;
            return p.ev.emptyAttrs();
        }
        while (true) {
            p.ws();
            if (p.peek() != '"') return p.err("syntax error while parsing object key - invalid literal");
            const sym = try p.ev.sym(try p.string());
            p.ws();
            if (p.peek() != ':') return p.err("syntax error while parsing object separator - expected ':'");
            p.i += 1;
            p.ws();
            const v = try p.parseValue();
            try entries.append(gpa, .{ .sym = sym, .pos = .none, .cell = .init(v) });
            p.ws();
            switch (p.peek() orelse 0) {
                ',' => p.i += 1,
                '}' => {
                    p.i += 1;
                    break;
                },
                else => return p.err("syntax error while parsing object - expected ',' or '}'"),
            }
        }
        p.depth -= 1;
        // Of duplicate keys the last value wins (insert_or_assign); the
        // stable sort keeps them in input order.
        std.mem.sort(value.Attr, entries.items, {}, attrLess);
        var n: usize = 0;
        for (entries.items) |e| {
            if (n > 0 and entries.items[n - 1].sym == e.sym) {
                entries.items[n - 1] = e;
            } else {
                entries.items[n] = e;
                n += 1;
            }
        }
        return p.ev.mkAttrsSorted(entries.items[0..n]);
    }

    fn attrLess(_: void, a: value.Attr, b: value.Attr) bool {
        return @backingInt(a.sym) < @backingInt(b.sym);
    }

    fn array(p: *Parser) Error!Value {
        try p.nest();
        p.i += 1;
        const gpa = p.ev.gpa;
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(gpa);
        p.ws();
        if (p.peek() == ']') {
            p.i += 1;
            p.depth -= 1;
            return p.ev.mkList(&.{});
        }
        while (true) {
            p.ws();
            try items.append(gpa, try p.parseValue());
            p.ws();
            switch (p.peek() orelse 0) {
                ',' => p.i += 1,
                ']' => {
                    p.i += 1;
                    break;
                },
                else => return p.err("syntax error while parsing array - expected ',' or ']'"),
            }
        }
        p.depth -= 1;
        return p.ev.mkList(items.items);
    }

    fn hex4(p: *Parser) Error!u21 {
        var v: u21 = 0;
        for (0..4) |_| {
            const c = p.peek() orelse 0;
            const d = std.fmt.charToDigit(c, 16) catch
                return p.err("syntax error while parsing value - invalid string: '\\u' must be followed by 4 hex digits");
            v = v * 16 + d;
            p.i += 1;
        }
        return v;
    }

    /// The decoded string at a quote, in `buf` until the next call.
    fn string(p: *Parser) Error![]const u8 {
        const gpa = p.ev.gpa;
        const out = &p.buf;
        out.clearRetainingCapacity();
        p.i += 1;
        while (true) {
            const c = p.peek() orelse return p.err("syntax error while parsing value - invalid string: missing closing quote");
            p.i += 1;
            switch (c) {
                '"' => break,
                '\\' => {
                    const e = p.peek() orelse return p.err("syntax error while parsing value - invalid string: forbidden character after backslash");
                    p.i += 1;
                    switch (e) {
                        '"', '\\', '/' => try out.append(gpa, e),
                        'b' => try out.append(gpa, 8),
                        'f' => try out.append(gpa, 12),
                        'n' => try out.append(gpa, '\n'),
                        'r' => try out.append(gpa, '\r'),
                        't' => try out.append(gpa, '\t'),
                        'u' => {
                            var cp = try p.hex4();
                            if (cp >= 0xD800 and cp < 0xDC00) {
                                if (!std.mem.startsWith(u8, p.s[p.i..], "\\u"))
                                    return p.err("syntax error while parsing value - invalid string: surrogate must be followed by a low surrogate");
                                p.i += 2;
                                const lo = try p.hex4();
                                if (lo < 0xDC00 or lo >= 0xE000)
                                    return p.err("syntax error while parsing value - invalid string: surrogate must be followed by a low surrogate");
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            } else if (cp >= 0xDC00 and cp < 0xE000) {
                                return p.err("syntax error while parsing value - invalid string: low surrogate must follow a high surrogate");
                            }
                            var b: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &b) catch unreachable;
                            try out.appendSlice(gpa, b[0..n]);
                        },
                        else => return p.err("syntax error while parsing value - invalid string: forbidden character after backslash"),
                    }
                },
                0...0x1f => return p.err("syntax error while parsing value - invalid string: control character must be escaped"),
                0x80...0xff => {
                    // One UTF-8 sequence, validated as nlohmann's lexer does.
                    const start = p.i - 1;
                    const len: usize = switch (c) {
                        0xc2...0xdf => 2,
                        0xe0...0xef => 3,
                        0xf0...0xf4 => 4,
                        else => return p.err("syntax error while parsing value - invalid string: ill-formed UTF-8 byte"),
                    };
                    if (start + len > p.s.len or !std.unicode.utf8ValidateSlice(p.s[start .. start + len]))
                        return p.err("syntax error while parsing value - invalid string: ill-formed UTF-8 byte");
                    try out.appendSlice(gpa, p.s[start .. start + len]);
                    p.i = start + len;
                },
                else => try out.append(gpa, c),
            }
        }
        // json-to-value.cc checks each key and string value once it is whole.
        if (std.mem.indexOfScalar(u8, out.items, 0) != null)
            return p.ev.fail(.eval, .none, "{f}", .{text.noNulMessage(out.items)});
        return out.items;
    }

    fn number(p: *Parser) Error!Value {
        const start = p.i;
        const neg = p.peek() == '-';
        if (neg) p.i += 1;
        switch (p.peek() orelse 0) {
            '0' => p.i += 1,
            '1'...'9' => while (p.peekDigit()) {
                p.i += 1;
            },
            else => return p.err("syntax error while parsing value - invalid number; expected digit after '-'"),
        }
        var is_float = false;
        if (p.peek() == '.') {
            is_float = true;
            p.i += 1;
            if (!p.peekDigit()) return p.err("syntax error while parsing value - invalid number; expected digit after '.'");
            while (p.peekDigit()) p.i += 1;
        }
        if (p.peek() == 'e' or p.peek() == 'E') {
            is_float = true;
            p.i += 1;
            if (p.peek() == '+' or p.peek() == '-') p.i += 1;
            if (!p.peekDigit()) return p.err("syntax error while parsing value - invalid number; expected digit after exponent");
            while (p.peekDigit()) p.i += 1;
        }
        const t = p.s[start..p.i];
        if (!is_float) {
            if (neg) {
                if (std.fmt.parseInt(i64, t, 10)) |i| return p.ev.mkInt(i) else |_| {}
            } else if (std.fmt.parseInt(u64, t, 10)) |u| {
                if (u > std.math.maxInt(i64))
                    return p.ev.fail(.eval, .none, "unsigned json number {d} outside of Nix integer range", .{u});
                return p.ev.mkInt(@intCast(u));
            } else |_| {}
        }
        const f = std.fmt.parseFloat(f64, t) catch unreachable;
        // strtod only fails on overflow; underflow yields zero or a subnormal.
        if (!std.math.isFinite(f))
            return p.failParse("[json.exception.out_of_range.406] number overflow parsing '{s}'", .{t});
        return p.ev.mkFloat(f);
    }
};
