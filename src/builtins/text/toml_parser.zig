//! A TOML parser ported from the `toml` crate (1.1.8) with its
//! `toml_parser` (1.1.5) and `toml_datetime` (1.1.2), the crates Rust iets
//! parses with, so a document is accepted, and refused with the same
//! message and span, as there. `builtins.fromTOML`, `iets.toml` and
//! `IETS_CONFIG` all parse with it.
//!
//! The crate works in three passes, and the first error any of them
//! reports is the one shown:
//! 1. `toml_parser::parser` turns tokens into events, checking the syntax
//!    and decoding comments and newlines (`ValidateWhitespace`), with a
//!    nesting limit (`RecursionGuard`);
//! 2. `toml::de::parser` builds the tables from the events, decoding keys
//!    and scalars and finding duplicate keys;
//! 3. deserializing into `toml::Table` turns integers and floats into
//!    numbers, in key order (the table is a `BTreeMap`).
//! The crate recovers from errors to report more of them; as only the
//! first is kept, each pass here stops at it instead.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Datetime = struct {
    date: ?struct { year: u16, month: u8, day: u8 } = null,
    time: ?struct { hour: u8, minute: u8, second: ?u8, nanosecond: ?u32 } = null,
    /// Minutes east of UTC; null for a local time, `z` for `Z`.
    offset: ?union(enum) { z, minutes: i16 } = null,
};

pub const Node = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: Datetime,
    array: *Array,
    table: *Table,
    /// A number the third pass refuses; never in a tree `parse` returns.
    invalid: *const ParseError,

    /// `DeValue::type_str`.
    fn typeName(n: Node) []const u8 {
        return switch (n) {
            .string => "string",
            .integer, .invalid => "integer",
            .float => "float",
            .boolean => "boolean",
            .datetime => "datetime",
            .array => "array",
            .table => "table",
        };
    }
};

pub const Array = struct {
    items: std.ArrayList(Node) = .empty,
    /// Made by `[[...]]` headers; a static array cannot be extended.
    of_tables: bool = false,
};

/// The crate's `DeTable`: a map with the flags that decide which later
/// header or dotted key may still extend it. The keys are in insertion
/// order; the crate's are sorted, which a reader that iterates must do.
pub const Table = struct {
    map: std.StringArrayHashMapUnmanaged(Node) = .empty,
    implicit: bool = false,
    dotted: bool = false,
    inline_: bool = false,
};

pub const Span = struct {
    start: usize,
    end: usize,

    fn before(s: Span) Span {
        return .{ .start = s.start, .end = s.start };
    }
    fn after(s: Span) Span {
        return .{ .start = s.end, .end = s.end };
    }
    fn append(s: Span, o: Span) Span {
        return .{ .start = s.start, .end = o.end };
    }
    fn at(i: usize) Span {
        return .{ .start = i, .end = i };
    }
};

/// The first error: `toml::de::Error`'s message and the span its caret
/// marks (none for an error the crate gives no position).
pub const ParseError = struct {
    msg: []const u8 = "",
    span: ?Span = null,
};

pub const Error = error{ Syntax, OutOfMemory };

/// Parses `s` into its root table; on `error.Syntax`, `err` says why.
/// The tree's strings point into `s` or `arena`.
pub fn parse(arena: Allocator, s: []const u8, err: *ParseError) Error!*Table {
    var p: Parser = .{ .s = s, .arena = arena, .err = err };
    p.tokens = try lex(arena, s);
    try p.document();
    try p.eof();
    var b: Builder = .{ .p = &p, .events = p.events.items };
    const root = try b.document();
    if (b.bad > 0) try p.firstInvalid(root);
    return root;
}

/// `toml::de::Error`'s `Display`: the position, the line with carets under
/// the span, then the message.
pub fn renderError(w: *std.Io.Writer, s: []const u8, e: ParseError) std.Io.Writer.Error!void {
    if (e.span) |span| {
        const line, const column = translatePosition(s, span.start);
        const line_num = line + 1;
        var nbuf: [24]u8 = undefined;
        const gutter = (std.fmt.bufPrint(&nbuf, "{d}", .{line_num}) catch unreachable).len;
        var lines = std.mem.splitScalar(u8, s, '\n');
        for (0..line) |_| _ = lines.next();
        const content = lines.next() orelse "";
        // the caret may go one past the line
        const highlight = @min(span.end - span.start, content.len -| column);
        try w.print("TOML parse error at line {d}, column {d}\n", .{ line_num, column + 1 });
        try w.splatByteAll(' ', gutter + 1);
        try w.writeAll("|\n");
        try w.print("{d} | {s}\n", .{ line_num, content });
        try w.splatByteAll(' ', gutter + 1);
        try w.writeByte('|');
        try w.splatByteAll(' ', column + 1);
        try w.splatByteAll('^', @max(highlight, 1));
        try w.writeByte('\n');
    }
    try w.print("{s}\n", .{e.msg});
}

/// The line and the column (in characters) of byte `index`.
fn translatePosition(input: []const u8, index_in: usize) struct { usize, usize } {
    if (input.len == 0) return .{ 0, index_in };
    const index = @min(index_in, input.len - 1);
    const column_offset = index_in - index;
    const line_start = if (std.mem.lastIndexOfScalar(u8, input[0..index], '\n')) |nl| nl + 1 else 0;
    const line = std.mem.count(u8, input[0..line_start], "\n");
    // The crate counts the characters of `line_start..=index`, or bytes
    // when that cuts a character.
    const column = if (std.unicode.utf8CountCodepoints(input[line_start .. index + 1])) |n| n - 1 else |_| index - line_start;
    return .{ line, column + column_offset };
}

/// An entry of an error's `expected` list.
const Expected = union(enum) {
    literal: []const u8,
    description: []const u8,
};

fn lit(comptime s: []const u8) Expected {
    return .{ .literal = s };
}

fn desc(comptime s: []const u8) Expected {
    return .{ .description = s };
}

// Lexing (`toml_parser::lexer`).

const TokenKind = enum(u8) {
    dot,
    equals,
    comma,
    lsquare,
    rsquare,
    lcurly,
    rcurly,
    whitespace,
    comment,
    newline,
    literal_string,
    basic_string,
    ml_literal_string,
    ml_basic_string,
    atom,
    eof,

    fn encoding(k: TokenKind) Encoding {
        return switch (k) {
            .literal_string => .literal,
            .basic_string => .basic,
            .ml_literal_string => .ml_literal,
            .ml_basic_string => .ml_basic,
            else => .none,
        };
    }
};

const Token = struct {
    kind: TokenKind,
    span: Span,
};

/// How a key or scalar is written; `none` is unquoted.
const Encoding = enum(u8) { none, literal, basic, ml_literal, ml_basic };

fn lex(arena: Allocator, s: []const u8) Allocator.Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
    try out.ensureTotalCapacity(arena, s.len / 7 * 2 + 1);
    var i: usize = if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) 3 else 0;
    while (i < s.len) {
        const start = i;
        const kind: TokenKind = switch (s[i]) {
            '.' => .dot,
            '=' => .equals,
            ',' => .comma,
            '[' => .lsquare,
            ']' => .rsquare,
            '{' => .lcurly,
            '}' => .rcurly,
            ' ', '\t' => .whitespace,
            '#' => .comment,
            '\r', '\n' => .newline,
            '\'' => if (std.mem.startsWith(u8, s[i..], "'''")) .ml_literal_string else .literal_string,
            '"' => if (std.mem.startsWith(u8, s[i..], "\"\"\"")) .ml_basic_string else .basic_string,
            else => .atom,
        };
        i = switch (kind) {
            .dot, .equals, .comma, .lsquare, .rsquare, .lcurly, .rcurly => i + 1,
            .whitespace => while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {} else i,
            .comment => std.mem.indexOfAnyPos(u8, s, i, "\r\n") orelse s.len,
            .newline => if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') i + 2 else i + 1,
            .literal_string => if (std.mem.indexOfAnyPos(u8, s, i + 1, "'\n")) |j| (if (s[j] == '\'') j + 1 else j) else s.len,
            .ml_literal_string => mlEnd(s, if (std.mem.indexOfPos(u8, s, i + 3, "'''")) |j| j + 3 else s.len, '\''),
            .basic_string => basicEnd(s, i + 1),
            .ml_basic_string => mlBasicEnd(s, i + 3),
            .atom => std.mem.indexOfAnyPos(u8, s, i, ".=,[]{} \t#\r\n") orelse s.len,
            .eof => unreachable,
        };
        try out.append(arena, .{ .kind = kind, .span = .{ .start = start, .end = i } });
    }
    try out.append(arena, .{ .kind = .eof, .span = .at(s.len) });
    return out.items;
}

/// A multi-line string takes up to two more quotes after its closing three.
fn mlEnd(s: []const u8, j_in: usize, q: u8) usize {
    var j = j_in;
    if (j < s.len and s[j] == q) j += 1;
    if (j < s.len and s[j] == q) j += 1;
    return j;
}

/// Ends after the closing quote, or before a newline, for recovery.
fn basicEnd(s: []const u8, from: usize) usize {
    var j = from;
    while (std.mem.indexOfAnyPos(u8, s, j, "\"\\\n")) |k| {
        switch (s[k]) {
            '"' => return k + 1,
            '\\' => {
                j = k + 1;
                if (j < s.len and (s[j] == '\\' or s[j] == '"')) j += 1;
            },
            else => return k,
        }
    }
    return s.len;
}

fn mlBasicEnd(s: []const u8, from: usize) usize {
    var j = from;
    while (j < s.len) {
        const k = std.mem.indexOfAnyPos(u8, s, j, "\"\\") orelse return s.len;
        if (s[k] == '\\') {
            j = k + 1;
            if (j < s.len and (s[j] == '\\' or s[j] == '"')) j += 1;
        } else if (std.mem.startsWith(u8, s[k..], "\"\"\"")) {
            return mlEnd(s, k + 3, '"');
        } else j = k + 1;
    }
    return s.len;
}

// The event parser (`toml_parser::parser::document`).

const EventKind = enum(u8) {
    std_table_open,
    std_table_close,
    array_table_open,
    array_table_close,
    inline_table_open,
    inline_table_close,
    array_open,
    array_close,
    simple_key,
    key_sep,
    key_val_sep,
    scalar,
    value_sep,
    whitespace,
    comment,
    newline,
    err,
};

const Event = struct {
    kind: EventKind,
    enc: Encoding = .none,
    span: Span,
};

/// The `toml` crate's nesting limit for arrays, inline tables and dotted keys.
const limit = 80;

const Parser = struct {
    s: []const u8,
    arena: Allocator,
    err: *ParseError,
    tokens: []const Token = &.{},
    pos: usize = 0,
    events: std.ArrayList(Event) = .empty,
    depth: i64 = 0,

    /// Reports the error: description, then the expected list as the
    /// crate's `Error::new` words it.
    fn fail(p: *Parser, description: []const u8, expected: ?[]const Expected, unexpected: ?Span) Error {
        var m: std.Io.Writer.Allocating = .init(p.arena);
        const w = &m.writer;
        w.writeAll(description) catch return error.OutOfMemory;
        if (expected) |list| {
            w.writeAll(", expected ") catch return error.OutOfMemory;
            if (list.len == 0) w.writeAll("nothing") catch return error.OutOfMemory;
            for (list, 0..) |e, i| {
                if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                switch (e) {
                    .description => |d| w.writeAll(d) catch return error.OutOfMemory,
                    .literal => |l| renderLiteral(w, l) catch return error.OutOfMemory,
                }
            }
        }
        p.err.* = .{ .msg = m.written(), .span = unexpected };
        return error.Syntax;
    }

    fn next(p: *Parser) ?Token {
        if (p.pos >= p.tokens.len) return null;
        p.pos += 1;
        return p.tokens[p.pos - 1];
    }

    fn first(p: *const Parser) ?Token {
        return if (p.pos < p.tokens.len) p.tokens[p.pos] else null;
    }

    fn nextIf(p: *Parser, kind: TokenKind) ?Token {
        const t = p.first() orelse return null;
        if (t.kind != kind) return null;
        p.pos += 1;
        return t;
    }

    fn back(p: *Parser) void {
        p.pos -|= 1;
    }

    /// The span of the last token consumed that is not whitespace, a
    /// comment, a newline or the end.
    fn previousSpan(p: *const Parser) Span {
        var i = p.pos;
        while (i > 0) {
            i -= 1;
            switch (p.tokens[i].kind) {
                .whitespace, .comment, .newline, .eof => {},
                else => return p.tokens[i].span,
            }
        }
        return .at(0);
    }

    fn emit(p: *Parser, kind: EventKind, enc: Encoding, span: Span) Error!void {
        try p.events.append(p.arena, .{ .kind = kind, .enc = enc, .span = span });
    }

    // The receiver: `RecursionGuard` over `ValidateWhitespace`.

    fn open(p: *Parser, kind: EventKind, span: Span) Error!void {
        try p.emit(kind, .none, span);
        p.depth += 1;
        if (p.depth > limit) return p.fail("cannot recurse further; max recursion depth met", null, span);
    }

    fn close(p: *Parser, kind: EventKind, span: Span) Error!void {
        p.depth -= 1;
        try p.emit(kind, .none, span);
    }

    /// Mirrors decoder/ws.rs:decode_comment.
    fn comment(p: *Parser, span: Span) Error!void {
        for (p.s[span.start..span.end], span.start..) |b, i| {
            if (!(b == 0x09 or (b >= 0x20 and b <= 0x7e) or b >= 0x80))
                return p.fail("invalid comment character", &.{desc("printable characters")}, .at(i));
        }
        try p.emit(.comment, .none, span);
    }

    /// Mirrors decoder/ws.rs:decode_newline.
    fn newline(p: *Parser, span: Span) Error!void {
        if (span.end - span.start == 1 and p.s[span.start] == '\r')
            return p.fail("carriage return must be followed by newline", &.{lit("\n")}, .at(span.end));
        try p.emit(.newline, .none, span);
    }

    fn document(p: *Parser) Error!void {
        while (p.next()) |t| switch (t.kind) {
            .lsquare => try p.onTable(t),
            .rsquare => return p.fail("missing table open", &.{lit("[")}, t.span.before()),
            .literal_string, .basic_string, .ml_literal_string, .ml_basic_string, .atom => try p.onExpressionKey(t),
            .equals => {
                try p.emit(.simple_key, .none, t.span.before());
                try p.onKeyValSep(t);
            },
            .dot => try p.onExpressionDot(t),
            .comma, .rcurly, .lcurly => return p.fail("invalid key-value pair", &.{desc("key")}, t.span.before()),
            .whitespace => try p.emit(.whitespace, .none, t.span),
            .newline => try p.newline(t.span),
            .comment => try p.onComment(t),
            .eof => break,
        };
    }

    fn onTable(p: *Parser, open_token: Token) Error!void {
        const is_array = if (p.nextIf(.lsquare)) |second| blk: {
            try p.emit(.array_table_open, .none, open_token.span.append(second.span));
            break :blk true;
        } else blk: {
            try p.emit(.std_table_open, .none, open_token.span);
            break :blk false;
        };
        try p.optWhitespace();
        const valid_key = try p.key("invalid table");
        try p.optWhitespace();
        var success = false;
        if (p.nextIf(.rsquare)) |close_token| {
            if (is_array) {
                const second = p.nextIf(.rsquare) orelse
                    return p.fail("unclosed array table", &.{lit("]")}, close_token.span.after());
                try p.emit(.array_table_close, .none, close_token.span.append(second.span));
            } else try p.emit(.std_table_close, .none, close_token.span);
            success = true;
        } else if (valid_key) {
            var last = open_token;
            var i = p.pos;
            while (i > 0) {
                i -= 1;
                if (p.tokens[i].kind != .whitespace) {
                    last = p.tokens[i];
                    break;
                }
            }
            return p.fail(if (is_array) "unclosed array table" else "unclosed table", if (is_array) &.{lit("]]")} else &.{lit("]")}, last.span.after());
        }
        if (success) try p.wsCommentNewline() else try p.ignoreToNewline();
    }

    /// A dotted key; false when a part was missing (a fake empty key stands
    /// in for it, which the second pass refuses).
    fn key(p: *Parser, invalid_description: []const u8) Error!bool {
        while (p.next()) |t| {
            switch (t.kind) {
                .rsquare, .comment, .equals, .comma, .lsquare, .lcurly, .rcurly, .newline, .eof => {
                    try p.emit(.simple_key, .none, t.span.before());
                    p.back();
                    return false;
                },
                .whitespace => {
                    try p.emit(.whitespace, .none, t.span);
                    continue;
                },
                .dot => {
                    try p.emit(.simple_key, .none, t.span.before());
                    try p.emit(.key_sep, .none, t.span);
                    continue;
                },
                else => {},
            }
            try p.emit(.simple_key, t.kind.encoding(), t.span);
            return p.optDotKeys();
        }
        const prev = p.previousSpan();
        return p.fail(invalid_description, &.{desc("key")}, prev.after());
    }

    fn onExpressionKey(p: *Parser, key_token: Token) Error!void {
        try p.emit(.simple_key, key_token.kind.encoding(), key_token.span);
        _ = try p.optDotKeys();
        try p.optWhitespace();
        const eq = p.nextIf(.equals) orelse {
            if (p.first()) |peek| return p.fail("key with no value", &.{lit("=")}, peek.span.before());
            return p.ignoreToNewline();
        };
        try p.onKeyValSep(eq);
    }

    fn onExpressionDot(p: *Parser, dot: Token) Error!void {
        try p.emit(.simple_key, .none, dot.span.before());
        p.back();
        _ = try p.optDotKeys();
        try p.optWhitespace();
        const eq = p.nextIf(.equals) orelse {
            if (p.first()) |peek| return p.fail("missing value for key", &.{lit("=")}, peek.span.before());
            return p.ignoreToNewline();
        };
        try p.onKeyValSep(eq);
    }

    fn onKeyValSep(p: *Parser, eq: Token) Error!void {
        try p.emit(.key_val_sep, .none, eq.span);
        try p.optWhitespace();
        try p.value();
        try p.wsCommentNewline();
    }

    fn optDotKeys(p: *Parser) Error!bool {
        try p.optWhitespace();
        dot: while (p.nextIf(.dot)) |dot| {
            try p.emit(.key_sep, .none, dot.span);
            while (p.next()) |t| {
                switch (t.kind) {
                    .equals, .comma, .lsquare, .rsquare, .lcurly, .rcurly, .comment, .newline, .eof => {
                        try p.emit(.simple_key, .none, t.span.before());
                        p.back();
                        return false;
                    },
                    .whitespace => {
                        try p.emit(.whitespace, .none, t.span);
                        continue;
                    },
                    .dot => {
                        try p.emit(.simple_key, .none, t.span.before());
                        try p.emit(.key_sep, .none, t.span);
                        continue;
                    },
                    else => {},
                }
                try p.emit(.simple_key, t.kind.encoding(), t.span);
                try p.optWhitespace();
                continue :dot;
            }
            try p.emit(.simple_key, .none, dot.span.after());
        }
        return true;
    }

    fn value(p: *Parser) Error!void {
        const t = p.next() orelse {
            const prev = p.previousSpan();
            return p.fail("missing value", &.{desc("value")}, prev.after());
        };
        switch (t.kind) {
            .equals => return p.fail("extra `=`", &.{}, t.span),
            .comment, .comma, .newline, .eof, .whitespace => {
                try p.emit(.scalar, .none, t.span.before());
                p.back();
            },
            .lcurly => try p.onInlineTableOpen(t),
            .rcurly => return p.fail("missing inline table opening", &.{lit("{")}, t.span.before()),
            .lsquare => try p.onArrayOpen(t),
            .rsquare => return p.fail("missing array opening", &.{lit("[")}, t.span.before()),
            .literal_string, .basic_string, .ml_literal_string, .ml_basic_string, .dot, .atom => try p.onScalar(t),
        }
    }

    /// An unquoted scalar runs over dots, and over whitespace followed by
    /// more of it (`1979-05-27 07:32:00`).
    fn onScalar(p: *Parser, t: Token) Error!void {
        var span = t.span;
        const enc = t.kind.encoding();
        if (enc == .none) while (p.first()) |n| switch (n.kind) {
            .whitespace => {
                if (p.pos + 1 < p.tokens.len and p.tokens[p.pos + 1].kind == .atom) {
                    span = span.append(p.tokens[p.pos + 1].span);
                    p.pos += 2;
                    continue;
                }
                break;
            },
            .dot, .atom => {
                span = span.append(n.span);
                p.pos += 1;
            },
            else => break,
        };
        try p.emit(.scalar, enc, span);
    }

    fn missingComma(p: *Parser, t: Token) Error {
        return p.fail("missing comma between array elements", &.{lit(",")}, t.span.before());
    }

    fn onArrayOpen(p: *Parser, array_open: Token) Error!void {
        try p.open(.array_open, array_open.span);
        var needs_value = true;
        while (p.next()) |t| switch (t.kind) {
            .comment => try p.onComment(t),
            .whitespace => try p.emit(.whitespace, .none, t.span),
            .newline => try p.newline(t.span),
            .eof => break,
            .comma => {
                if (needs_value) return p.fail("extra comma in array", &.{desc("value")}, t.span);
                try p.emit(.value_sep, .none, t.span);
                needs_value = true;
            },
            .equals => return p.fail("unexpected `=` in array", &.{ desc("value"), lit("]") }, t.span),
            .lcurly => {
                if (!needs_value) return p.missingComma(t);
                try p.onInlineTableOpen(t);
                needs_value = false;
            },
            .rcurly => {
                if (!needs_value) return p.missingComma(t);
                return p.fail("missing inline table opening", &.{lit("{")}, t.span.before());
            },
            .lsquare => {
                if (!needs_value) return p.missingComma(t);
                try p.onArrayOpen(t);
                needs_value = false;
            },
            .rsquare => return p.close(.array_close, t.span),
            .literal_string, .basic_string, .ml_literal_string, .ml_basic_string, .dot, .atom => {
                if (!needs_value) return p.missingComma(t);
                try p.onScalar(t);
                needs_value = false;
            },
        };
        return p.fail("unclosed array", &.{lit("]")}, p.previousSpan().after());
    }

    const TableState = enum {
        needs_key,
        needs_equals,
        needs_value,
        needs_comma,

        fn expected(s: TableState) []const Expected {
            const lists = struct {
                const key = [_]Expected{desc("key")};
                const equals = [_]Expected{lit("=")};
                const value = [_]Expected{desc("value")};
                const comma = [_]Expected{lit(",")};
            };
            return switch (s) {
                .needs_key => &lists.key,
                .needs_equals => &lists.equals,
                .needs_value => &lists.value,
                .needs_comma => &lists.comma,
            };
        }
    };

    fn onInlineTableOpen(p: *Parser, table_open: Token) Error!void {
        try p.open(.inline_table_open, table_open.span);
        var state: TableState = .needs_key;
        while (p.next()) |t| switch (t.kind) {
            .comment => try p.onComment(t),
            .whitespace => try p.emit(.whitespace, .none, t.span),
            .newline => try p.newline(t.span),
            .eof => break,
            .comma => {
                if (state != .needs_comma) return p.fail("extra comma in inline table", state.expected(), t.span.before());
                try p.emit(.value_sep, .none, t.span);
                state = .needs_key;
            },
            .equals => switch (state) {
                .needs_key => {
                    try p.emit(.simple_key, .none, t.span.before());
                    try p.emit(.key_val_sep, .none, t.span);
                    state = .needs_value;
                },
                .needs_equals => {
                    try p.emit(.key_val_sep, .none, t.span);
                    state = .needs_value;
                },
                .needs_value, .needs_comma => return p.fail("extra assignment between key-value pairs", state.expected(), t.span.before()),
            },
            .lcurly, .lsquare => switch (state) {
                .needs_key, .needs_comma => return p.fail("missing key for inline table element", state.expected(), t.span.before()),
                .needs_equals => return p.fail("missing assignment between key-value pairs", state.expected(), t.span.before()),
                .needs_value => {
                    if (t.kind == .lcurly) try p.onInlineTableOpen(t) else try p.onArrayOpen(t);
                    state = .needs_comma;
                },
            },
            .rcurly => {
                switch (state) {
                    .needs_key, .needs_comma => {},
                    .needs_equals => {
                        try p.emit(.key_val_sep, .none, t.span.before());
                        try p.emit(.scalar, .literal, t.span.before());
                    },
                    .needs_value => try p.emit(.scalar, .literal, t.span.before()),
                }
                return p.close(.inline_table_close, t.span);
            },
            .rsquare => switch (state) {
                .needs_key, .needs_equals, .needs_comma => return p.fail("invalid inline table element", state.expected(), t.span.before()),
                .needs_value => return p.fail("missing array opening", &.{lit("[")}, t.span.before()),
            },
            .literal_string, .basic_string, .ml_literal_string, .ml_basic_string, .dot, .atom => switch (state) {
                .needs_key => {
                    try p.inlineKey(t);
                    state = .needs_equals;
                },
                .needs_equals => return p.fail("missing assignment between key-value pairs", state.expected(), t.span.before()),
                .needs_value => {
                    try p.onScalar(t);
                    state = .needs_comma;
                },
                .needs_comma => return p.fail("missing comma between key-value pairs", state.expected(), t.span.before()),
            },
        };
        return p.fail("unclosed inline table", &.{lit("}")}, p.previousSpan().after());
    }

    fn inlineKey(p: *Parser, t: Token) Error!void {
        if (t.kind == .dot) {
            try p.emit(.simple_key, .none, t.span.before());
            p.back();
        } else try p.emit(.simple_key, t.kind.encoding(), t.span);
        _ = try p.optDotKeys();
    }

    fn optWhitespace(p: *Parser) Error!void {
        if (p.nextIf(.whitespace)) |t| try p.emit(.whitespace, .none, t.span);
    }

    fn wsCommentNewline(p: *Parser) Error!void {
        while (p.next()) |t| {
            switch (t.kind) {
                .comment => return p.onComment(t),
                .whitespace => try p.emit(.whitespace, .none, t.span),
                .newline => return p.newline(t.span),
                .eof => return,
                else => return p.fail("unexpected key or value", &.{ lit("\n"), lit("#") }, t.span.before()),
            }
        }
    }

    fn onComment(p: *Parser, t: Token) Error!void {
        try p.comment(t.span);
        const n = p.next() orelse return;
        switch (n.kind) {
            .newline => try p.newline(n.span),
            .eof => {},
            else => return p.fail("unexpected content between comment and newline", &.{lit("\n")}, n.span.before()),
        }
    }

    fn eof(p: *Parser) Error!void {
        const t = p.next() orelse return;
        if (t.kind != .eof) return p.fail("unexpected content", &.{}, t.span.before());
    }

    /// Skips the rest of a line whose start already failed without an
    /// error, as a table header with no key.
    fn ignoreToNewline(p: *Parser) Error!void {
        while (p.next()) |t| switch (t.kind) {
            .comment => return p.onComment(t),
            .whitespace => try p.emit(.whitespace, .none, t.span),
            .newline => return p.newline(t.span),
            .eof => return,
            else => try p.emit(.err, .none, t.span),
        };
    }

    /// The third pass: deserializing walks each table in key order and
    /// stops at the first number it cannot represent.
    fn firstInvalid(p: *Parser, t: *const Table) Error!void {
        const keys = try p.arena.dupe([]const u8, t.map.keys());
        std.mem.sort([]const u8, keys, {}, keyLess);
        for (keys) |k| try p.invalidIn(t.map.get(k).?);
    }

    fn invalidIn(p: *Parser, n: Node) Error!void {
        switch (n) {
            .invalid => |e| {
                p.err.* = e.*;
                return error.Syntax;
            },
            .table => |t| try p.firstInvalid(t),
            .array => |a| for (a.items.items) |x| try p.invalidIn(x),
            else => {},
        }
    }
};

fn keyLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `render_literal` of the toml crate's error.
fn renderLiteral(w: *std.Io.Writer, l: []const u8) std.Io.Writer.Error!void {
    if (std.mem.eql(u8, l, "\n")) return w.writeAll("newline");
    if (std.mem.eql(u8, l, "`")) return w.writeAll("'`'");
    try w.print("`{s}`", .{l});
}

// The table builder (`toml::de::parser`).

const Key = struct {
    name: []const u8,
    span: Span,
};

const Header = struct {
    path: []const Key,
    key: ?Key,
    is_array: bool,
};

const Builder = struct {
    p: *Parser,
    events: []const Event,
    pos: usize = 0,
    root: *Table = undefined,
    current: *Table = undefined,
    header: ?Header = null,
    /// Numbers the third pass refuses.
    bad: usize = 0,

    fn next(b: *Builder) ?Event {
        if (b.pos >= b.events.len) return null;
        b.pos += 1;
        return b.events[b.pos - 1];
    }

    fn kindAt(b: *const Builder, k: usize) ?EventKind {
        return if (b.pos + k < b.events.len) b.events[b.pos + k].kind else null;
    }

    fn newTable(b: *Builder) Error!*Table {
        const t = try b.p.arena.create(Table);
        t.* = .{};
        return t;
    }

    fn document(b: *Builder) Error!*Table {
        b.root = try b.newTable();
        b.current = try b.newTable();
        while (b.next()) |e| switch (e.kind) {
            .std_table_open, .array_table_open => {
                try b.finishTable();
                const header = try b.onTable(e);
                try b.startTable(header);
            },
            .simple_key => {
                const path, const key = try b.onKey(e);
                var kv = b.next() orelse break;
                if (kv.kind == .whitespace) kv = b.next() orelse break;
                if (kv.kind != .key_val_sep) break;
                if (b.kindAt(0) == .whitespace) b.pos += 1;
                const v = try b.value();
                try b.captureKeyValue(path, key, v);
            },
            else => {},
        };
        try b.finishTable();
        return b.root;
    }

    fn onTable(b: *Builder, open: Event) Error!Header {
        var h: Header = .{ .path = &.{}, .key = null, .is_array = open.kind == .array_table_open };
        while (b.next()) |e| switch (e.kind) {
            .array_table_close, .std_table_close => break,
            .simple_key => {
                h.path, const key = try b.onKey(e);
                h.key = key;
            },
            else => {},
        };
        return h;
    }

    /// A dotted key: the path to its table and the last part.
    fn onKey(b: *Builder, first: Event) Error!struct { []const Key, Key } {
        var path: std.ArrayList(Key) = .empty;
        var current: ?Event = first;
        var result: ?Key = null;
        if (b.moreKey()) while (b.next()) |e| switch (e.kind) {
            .simple_key => {
                current = e;
                if (!b.moreKey()) break;
            },
            .key_sep => try b.closeKey(&path, &result, &current),
            else => {},
        };
        try b.closeKey(&path, &result, &current);
        if (path.items.len >= limit) return b.p.fail("recursion limit", null, null);
        return .{ path.items, result.? };
    }

    fn moreKey(b: *const Builder) bool {
        const k0 = b.kindAt(0);
        return k0 == .key_sep or (k0 == .whitespace and b.kindAt(1) == .key_sep);
    }

    fn closeKey(b: *Builder, path: *std.ArrayList(Key), result: *?Key, current: *?Event) Error!void {
        const e = current.* orelse return;
        current.* = null;
        const name = try b.decodeKey(e);
        if (result.*) |last| try path.append(b.p.arena, last);
        result.* = .{ .name = name, .span = e.span };
    }

    fn value(b: *Builder) Error!Node {
        if (b.next()) |e| switch (e.kind) {
            .inline_table_open => return b.onInlineTable(),
            .array_open => return b.onArray(),
            .scalar => return b.onScalar(e),
            else => {},
        };
        return .{ .integer = 0 };
    }

    fn onArray(b: *Builder) Error!Node {
        const a = try b.p.arena.create(Array);
        a.* = .{};
        var current: ?Node = null;
        while (b.next()) |e| switch (e.kind) {
            .std_table_open, .array_table_open, .inline_table_close, .simple_key, .key_sep, .key_val_sep, .std_table_close, .array_table_close => break,
            .inline_table_open => current = try b.onInlineTable(),
            .array_open => current = try b.onArray(),
            .scalar => current = try b.onScalar(e),
            .value_sep, .array_close => {
                if (current) |v| try a.items.append(b.p.arena, v);
                current = null;
                if (e.kind == .array_close) break;
            },
            else => {},
        };
        return .{ .array = a };
    }

    fn onInlineTable(b: *Builder) Error!Node {
        const result = try b.newTable();
        result.inline_ = true;
        var key: ?struct { []const Key, Key } = null;
        var current: ?Node = null;
        while (b.next()) |e| switch (e.kind) {
            .std_table_open, .array_table_open, .std_table_close, .array_close, .array_table_close, .key_sep => break,
            .simple_key => key = try b.onKey(e),
            .inline_table_open => current = try b.onInlineTable(),
            .array_open => current = try b.onArray(),
            .scalar => current = try b.onScalar(e),
            .value_sep, .inline_table_close => {
                if (key) |k| if (current) |v| try b.inlineValue(result, k[0], k[1], v);
                key = null;
                current = null;
                if (e.kind == .inline_table_close) break;
            },
            else => {},
        };
        return .{ .table = result };
    }

    fn inlineValue(b: *Builder, result: *Table, path: []const Key, key: Key, v: Node) Error!void {
        var t = result;
        for (path) |k| {
            const gop = try t.map.getOrPut(b.p.arena, k.name);
            if (!gop.found_existing) {
                const nt = try b.newTable();
                nt.* = .{ .implicit = true, .dotted = true, .inline_ = true };
                gop.value_ptr.* = .{ .table = nt };
                t = nt;
                continue;
            }
            switch (gop.value_ptr.*) {
                .table => |x| {
                    if (!x.implicit) return b.p.fail("duplicate key", null, k.span);
                    t = x;
                },
                else => |old| return b.cannotExtend(old.typeName(), k.span),
            }
        }
        if (t.dotted == (path.len == 0)) return b.p.fail("duplicate key", null, key.span);
        const gop = try t.map.getOrPut(b.p.arena, key.name);
        if (gop.found_existing) return b.p.fail("duplicate key", null, key.span);
        gop.value_ptr.* = v;
    }

    fn cannotExtend(b: *Builder, type_name: []const u8, span: Span) Error {
        return b.p.fail(try std.fmt.allocPrint(b.p.arena, "cannot extend value of type {s} with a dotted key", .{type_name}), null, span);
    }

    /// The table a dotted path names in a document, made as needed.
    fn descend(b: *Builder, root: *Table, path: []const Key, dotted: bool) Error!*Table {
        var t = root;
        for (path) |k| {
            const gop = try t.map.getOrPut(b.p.arena, k.name);
            if (!gop.found_existing) {
                const nt = try b.newTable();
                nt.* = .{ .implicit = true, .dotted = dotted };
                gop.value_ptr.* = .{ .table = nt };
                t = nt;
                continue;
            }
            switch (gop.value_ptr.*) {
                .array => |a| {
                    if (!a.of_tables) return b.cannotExtend("array", k.span);
                    switch (a.items.items[a.items.items.len - 1]) {
                        .table => |x| t = x,
                        else => |last| return b.cannotExtend(last.typeName(), k.span),
                    }
                },
                .table => |x| {
                    if (x.inline_) return b.cannotExtend("inline table", k.span);
                    if (dotted and x.implicit) x.dotted = true;
                    if (dotted and !x.implicit) return b.p.fail("duplicate key", null, k.span);
                    t = x;
                },
                else => |old| return b.cannotExtend(old.typeName(), k.span),
            }
        }
        return t;
    }

    fn captureKeyValue(b: *Builder, path: []const Key, key: Key, v: Node) Error!void {
        const dotted = path.len > 0;
        const parent = try b.descend(b.current, path, dotted);
        if (dotted and !parent.implicit) return b.p.fail("duplicate key", null, key.span);
        const gop = try parent.map.getOrPut(b.p.arena, key.name);
        if (gop.found_existing) return b.p.fail("duplicate key", null, key.span);
        gop.value_ptr.* = v;
    }

    fn finishTable(b: *Builder) Error!void {
        const prev = b.current;
        b.current = try b.newTable();
        const header = b.header orelse {
            b.root = prev;
            return;
        };
        b.header = null;
        const key = header.key orelse return;
        const parent = try b.descend(b.root, header.path, false);
        const gop = try parent.map.getOrPut(b.p.arena, key.name);
        if (header.is_array) {
            if (!gop.found_existing) {
                const a = try b.p.arena.create(Array);
                a.* = .{ .of_tables = true };
                gop.value_ptr.* = .{ .array = a };
            }
            switch (gop.value_ptr.*) {
                .array => |a| if (a.of_tables) return a.items.append(b.p.arena, .{ .table = prev }),
                else => {},
            }
            return b.p.fail("duplicate key", null, key.span);
        }
        gop.value_ptr.* = .{ .table = prev };
    }

    fn startTable(b: *Builder, header: Header) Error!void {
        if (!header.is_array) if (header.key) |key| {
            const parent = try b.descend(b.root, header.path, false);
            if (parent.map.fetchSwapRemove(key.name)) |old| {
                switch (old.value) {
                    .table => |t| if (t.implicit and !t.dotted) {
                        b.current = t;
                    } else return b.p.fail("duplicate key", null, key.span),
                    else => return b.p.fail("duplicate key", null, key.span),
                }
            }
        };
        b.current.implicit = false;
        b.current.dotted = false;
        b.header = header;
    }

    fn raw(b: *const Builder, e: Event) []const u8 {
        return b.p.s[e.span.start..e.span.end];
    }

    /// Mirrors source.rs:Raw::decode_key.
    fn decodeKey(b: *Builder, e: Event) Error![]const u8 {
        var d: Decoder = .{ .p = b.p, .raw = b.raw(e), .base = e.span.start };
        return switch (e.enc) {
            .literal => d.literalString(),
            .basic => d.basicString(),
            .ml_literal => d.failAt("keys cannot be multi-line literal strings", &.{ desc("basic string"), desc("literal string") }, .{ .start = 0, .end = d.raw.len }),
            .ml_basic => d.failAt("keys cannot be multi-line basic strings", &.{ desc("basic string"), desc("literal string") }, .{ .start = 0, .end = d.raw.len }),
            .none => d.unquotedKey(),
        };
    }

    /// Mirrors toml de/parser/value.rs:on_scalar, with the number
    /// conversions of the third pass.
    fn onScalar(b: *Builder, e: Event) Error!Node {
        var d: Decoder = .{ .p = b.p, .raw = b.raw(e), .base = e.span.start };
        const s = switch (e.enc) {
            .literal => return .{ .string = try d.literalString() },
            .basic => return .{ .string = try d.basicString() },
            .ml_literal => return .{ .string = try d.mlLiteralString() },
            .ml_basic => return .{ .string = try d.mlBasicString() },
            .none => try d.unquotedScalar(),
        };
        switch (s.kind) {
            .string => return .{ .string = s.text },
            .boolean => return .{ .boolean = s.text[0] == 't' },
            .datetime => {
                var why: DatetimeError = .{};
                const dt = parseDatetime(s.text, &why) catch {
                    var buf: [96]u8 = undefined;
                    return b.p.fail(try b.p.arena.dupe(u8, why.message(&buf)), null, e.span);
                };
                return .{ .datetime = dt };
            },
            .float => return floatValue(s.text) orelse b.invalid("floating-point number overflowed", e.span),
            .integer => |radix| return b.integer(s.text, radix, e.span),
        }
    }

    fn invalid(b: *Builder, msg: []const u8, span: Span) Error!Node {
        const err = try b.p.arena.create(ParseError);
        err.* = .{ .msg = msg, .span = span };
        b.bad += 1;
        return .{ .invalid = err };
    }

    /// `ValueDeserializer::deserialize_any` into `toml::Value`: the first of
    /// i64, u64, i128 and u128 the digits fit, and only i64 is a value.
    fn integer(b: *Builder, digits: []const u8, radix: u8, span: Span) Error!Node {
        if (parseInt(i64, digits, radix)) |i| return .{ .integer = i };
        if (parseInt(u64, digits, radix) != null) return b.invalid("u64 value was too large", span);
        if (parseInt(i128, digits, radix)) |i|
            return b.invalid(try std.fmt.allocPrint(b.p.arena, "invalid type: integer `{d}` as i128, expected any valid TOML value", .{i}), span);
        if (parseInt(u128, digits, radix)) |i|
            return b.invalid(try std.fmt.allocPrint(b.p.arena, "invalid type: integer `{d}` as u128, expected any valid TOML value", .{i}), span);
        return b.invalid("integer number overflowed", span);
    }
};

/// Rust's `from_str_radix`: an optional sign, then digits only.
fn parseInt(comptime T: type, s: []const u8, radix: u8) ?T {
    if (s.len == 0) return null;
    const neg = s[0] == '-';
    const digits = if (s[0] == '+' or s[0] == '-') s[1..] else s;
    if (digits.len == 0) return null;
    if (neg and @typeInfo(T).int.signedness == .unsigned) return null;
    var v: T = 0;
    for (digits) |c| {
        const d = std.fmt.charToDigit(c, radix) catch return null;
        v = std.math.mul(T, v, radix) catch return null;
        v = (if (neg) std.math.sub(T, v, @intCast(d)) else std.math.add(T, v, @intCast(d))) catch return null;
    }
    return v;
}

/// `DeFloat::to_f64`: null when Rust's parse fails, or overflows to an
/// infinity that was not written as one.
fn floatValue(s: []const u8) ?Node {
    const body = if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s[1..] else s;
    const neg = s.len > 0 and s[0] == '-';
    if (std.mem.eql(u8, body, "inf")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
    if (std.mem.eql(u8, body, "nan")) return .{ .float = if (neg) -std.math.nan(f64) else std.math.nan(f64) };
    const f = std.fmt.parseFloat(f64, s) catch return null;
    if (std.math.isInf(f)) return null;
    return .{ .float = f };
}

// Decoding keys and scalars (`toml_parser::decoder`).

const ScalarKind = union(enum) {
    string,
    boolean,
    datetime,
    float,
    integer: u8,
};

const Scalar = struct {
    kind: ScalarKind,
    text: []const u8,
};

const Radix = enum {
    dec,
    hex,
    oct,
    bin,

    fn value(r: Radix) u8 {
        return switch (r) {
            .dec => 10,
            .hex => 16,
            .oct => 8,
            .bin => 2,
        };
    }

    fn invalidDescription(r: Radix) []const u8 {
        return switch (r) {
            .dec => "invalid integer number",
            .hex => "invalid hexadecimal number",
            .oct => "invalid octal number",
            .bin => "invalid binary number",
        };
    }

    fn valid(r: Radix, c: u8) bool {
        return switch (r) {
            .dec => std.ascii.isDigit(c),
            .hex => std.ascii.isHex(c),
            .oct => c >= '0' and c <= '7',
            .bin => c == '0' or c == '1',
        };
    }
};

fn isLiteralChar(b: u8) bool {
    return b == 0x09 or (b >= 0x20 and b <= 0x26) or (b >= 0x28 and b <= 0x7e) or b >= 0x80;
}

fn isBasicUnescaped(b: u8) bool {
    return b == ' ' or b == '\t' or b == 0x21 or (b >= 0x23 and b <= 0x5b) or (b >= 0x5d and b <= 0x7e) or b >= 0x80;
}

fn isMlbUnescaped(b: u8) bool {
    return isBasicUnescaped(b) or b == '"' or b == '\n';
}

fn isUnquotedChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == '_';
}

/// The UTF-8 length of the character at `s[0]`, 1 for a stray byte.
fn charLen(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 1;
    return @min(n, s.len);
}

const Decoder = struct {
    p: *Parser,
    /// The token's text; error spans are relative to it, `base` places it.
    raw: []const u8,
    base: usize,

    fn failAt(d: *Decoder, description: []const u8, expected: ?[]const Expected, at: Span) Error {
        return d.p.fail(description, expected, .{ .start = d.base + at.start, .end = d.base + at.end });
    }

    fn off(d: *const Decoder, s: []const u8) usize {
        return @intFromPtr(s.ptr) - @intFromPtr(d.raw.ptr);
    }

    fn whole(d: *const Decoder) Span {
        return .{ .start = 0, .end = d.raw.len };
    }

    fn literalString(d: *Decoder) Error![]const u8 {
        const invalid = "invalid literal string";
        var s = d.raw;
        if (s.len > 0 and s[0] == '\'') s = s[1..] else return d.failAt(invalid, &.{lit("'")}, .at(0));
        if (s.len > 0 and s[s.len - 1] == '\'') s = s[0 .. s.len - 1] else return d.failAt(invalid, &.{lit("'")}, .at(d.raw.len));
        for (s, 0..) |b, i| if (!isLiteralChar(b))
            return d.failAt(invalid, &.{desc("non-single-quote visible characters")}, .at(d.off(s) + i));
        return s;
    }

    fn stripStartNewline(s: []const u8) []const u8 {
        if (std.mem.startsWith(u8, s, "\n")) return s[1..];
        if (std.mem.startsWith(u8, s, "\r\n")) return s[2..];
        return s;
    }

    fn mlLiteralString(d: *Decoder) Error![]const u8 {
        const invalid = "invalid multi-line literal string";
        var s = d.raw;
        if (std.mem.startsWith(u8, s, "'''")) s = s[3..] else return d.failAt(invalid, &.{lit("'")}, .at(0));
        s = stripStartNewline(s);
        if (std.mem.endsWith(u8, s, "'''")) s = s[0 .. s.len - 3] else return d.failAt(invalid, &.{lit("'")}, .at(d.raw.len));
        for (s, 0..) |b, i| {
            if (b == '\'' or b == '\n') continue;
            if (b == '\r') {
                if (i + 1 >= s.len or s[i + 1] != '\n')
                    return d.failAt("carriage return must be followed by newline", &.{lit("\n")}, .at(d.off(s) + i + 1));
            } else if (!isLiteralChar(b)) {
                return d.failAt(invalid, &.{desc("non-single-quote characters")}, .at(d.off(s) + i));
            }
        }
        return s;
    }

    fn basicString(d: *Decoder) Error![]const u8 {
        const invalid = "invalid basic string";
        var s = d.raw;
        if (s.len > 0 and s[0] == '"') s = s[1..] else return d.failAt(invalid, &.{lit("\"")}, .at(0));
        if (s.len > 0 and s[s.len - 1] == '"') s = s[0 .. s.len - 1] else return d.failAt(invalid, &.{lit("\"")}, .at(d.raw.len));
        var i: usize = 0;
        while (i < s.len and isBasicUnescaped(s[i])) i += 1;
        // the common case borrows the source
        if (i == s.len) return s;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(d.p.arena, s[0..i]);
        while (i < s.len) {
            if (s[i] == '\\') {
                i += 1;
                try d.escape(s, &i, &out);
            } else {
                const start = i;
                while (i < s.len and !isBasicUnescaped(s[i]) and s[i] != '\\') i += 1;
                return d.failAt(invalid, &.{ desc("non-double-quote visible characters"), lit("\\") }, .{ .start = d.off(s) + start, .end = d.off(s) + i });
            }
            const seg = i;
            while (i < s.len and isBasicUnescaped(s[i])) i += 1;
            try out.appendSlice(d.p.arena, s[seg..i]);
        }
        return out.items;
    }

    /// After a backslash at `s[i-1]`. Mirrors decoder/string.rs:escape_seq_char.
    fn escape(d: *Decoder, s: []const u8, i: *usize, out: *std.ArrayList(u8)) Error!void {
        const escapes: []const Expected = &.{ lit("b"), lit("e"), lit("f"), lit("n"), lit("r"), lit("\\"), lit("\""), lit("x"), lit("u"), lit("U") };
        if (i.* >= s.len) return d.failAt("missing escaped value", escapes, .at(d.off(s) + i.*));
        const c = s[i.*];
        const b: u8 = switch (c) {
            'b' => 8,
            'e' => 0x1b,
            'f' => 12,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            'x', 'u', 'U' => {
                i.* += 1;
                return d.hexEscape(s, i, out, switch (c) {
                    'x' => 2,
                    'u' => 4,
                    else => 8,
                });
            },
            else => return d.failAt("missing escaped value", escapes, .at(d.off(s) + i.*)),
        };
        i.* += 1;
        try out.append(d.p.arena, b);
    }

    fn hexEscape(d: *Decoder, s: []const u8, i: *usize, out: *std.ArrayList(u8), n: usize) Error!void {
        const start = i.*;
        while (i.* < s.len and i.* - start < n and std.ascii.isHex(s[i.*])) i.* += 1;
        const hex: []const Expected = &.{desc("unicode hexadecimal value")};
        if (i.* - start != n) return d.failAt("too few unicode value digits", hex, .at(d.off(s) + i.*));
        const cp = std.fmt.parseInt(u32, s[start..i.*], 16) catch unreachable;
        if (cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return d.failAt("invalid value", hex, .at(d.off(s) + start));
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch unreachable;
        try out.appendSlice(d.p.arena, buf[0..len]);
    }

    fn mlBasicString(d: *Decoder) Error![]const u8 {
        const invalid = "invalid multi-line basic string";
        var s = d.raw;
        if (std.mem.startsWith(u8, s, "\"\"\"")) s = s[3..] else return d.failAt(invalid, &.{lit("\"")}, .at(0));
        s = stripStartNewline(s);
        if (std.mem.endsWith(u8, s, "\"\"\"")) s = s[0 .. s.len - 3] else return d.failAt(invalid, &.{lit("\"")}, .at(d.raw.len));
        var i: usize = 0;
        while (i < s.len and isMlbUnescaped(s[i])) i += 1;
        if (i == s.len) return s;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(d.p.arena, s[0..i]);
        while (i < s.len) {
            if (s[i] == '\\') {
                i += 1;
                if (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) {
                    try d.escapedNewline(s, &i);
                } else try d.escape(s, &i, &out);
            } else if (s[i] == '\r') {
                if (i + 1 < s.len and s[i + 1] == '\n') {
                    try out.appendSlice(d.p.arena, "\r\n");
                    i += 2;
                } else return d.failAt("carriage return must be followed by newline", &.{lit("\n")}, .at(d.off(s) + i + 1));
            } else {
                const start = i;
                while (i < s.len and !(isMlbUnescaped(s[i]) or s[i] == '\\' or s[i] == '\r')) i += 1;
                return d.failAt(invalid, &.{ lit("\\"), desc("characters") }, .{ .start = d.off(s) + start, .end = d.off(s) + i });
            }
            const seg = i;
            while (i < s.len and isMlbUnescaped(s[i])) i += 1;
            try out.appendSlice(d.p.arena, s[seg..i]);
        }
        return out.items;
    }

    /// A line-ending backslash: whitespace, the newline, then all
    /// whitespace and newlines after it go.
    fn escapedNewline(d: *Decoder, s: []const u8, i: *usize) Error!void {
        while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) i.* += 1;
        if (i.* < s.len and s[i.*] == '\n') {
            i.* += 1;
        } else if (i.* < s.len and s[i.*] == '\r') {
            i.* += 1;
            if (i.* < s.len and s[i.*] == '\n') i.* += 1 else return d.failAt("carriage return must be followed by newline", &.{lit("\n")}, .at(d.off(s) + i.*));
        } else return d.failAt("invalid multi-line basic string", &.{lit("\n")}, .at(d.off(s) + i.*));
        while (true) {
            const start = i.*;
            while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t' or s[i.*] == '\n')) i.* += 1;
            if (i.* < s.len and s[i.*] == '\r') {
                if (i.* + 1 < s.len and s[i.* + 1] == '\n') i.* += 2 else return d.failAt("carriage return must be followed by newline", &.{lit("\n")}, .at(d.off(s) + i.* + 1));
            }
            if (i.* == start) break;
        }
    }

    fn unquotedKey(d: *Decoder) Error![]const u8 {
        const s = d.raw;
        const expected: []const Expected = &.{ desc("letters"), desc("numbers"), lit("-"), lit("_") };
        if (s.len == 0) return d.failAt("unquoted keys cannot be empty", expected, .at(0));
        // A run of bad bytes is one error; the first run is the one shown.
        if (std.mem.indexOfNone(u8, s, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")) |start| {
            var end = start + 1;
            while (end < s.len and !isUnquotedChar(s[end])) end += 1;
            return d.failAt("invalid unquoted key", expected, .{ .start = start, .end = end });
        }
        return s;
    }

    /// Mirrors decoder/scalar.rs:decode_unquoted_scalar.
    fn unquotedScalar(d: *Decoder) Error!Scalar {
        const s = d.raw;
        if (s.len == 0) return d.invalidScalar();
        if (!std.ascii.isDigit(s[0]) and std.mem.indexOfScalar(u8, s, ' ') != null) return d.invalidScalar();
        return switch (s[0]) {
            '+', '-' => d.signPrefix(s[1..]),
            '_', '1'...'9' => d.datetimeFloatOrInteger(s),
            '0' => d.zeroPrefix(s, false),
            '.' => {
                try d.ensureFloat(s);
                return d.floatOrInteger(s, .float);
            },
            't', 'T' => d.symbol("true", .boolean, "invalid boolean"),
            'f', 'F' => d.symbol("false", .boolean, "invalid boolean"),
            'i', 'I' => d.symbol("inf", .float, "invalid float"),
            'n', 'N' => d.symbol("nan", .float, "invalid float"),
            else => d.invalidScalar(),
        };
    }

    fn signPrefix(d: *Decoder, value: []const u8) Error!Scalar {
        if (value.len == 0) return d.invalidScalar();
        if (value[0] == '+' or value[0] == '-') {
            const start = d.off(value);
            return d.failAt("redundant numeric sign", &.{}, .{ .start = start, .end = start + 1 });
        }
        switch (value[0]) {
            '_', '1'...'9' => return d.datetimeFloatOrInteger(value),
            '0' => return d.zeroPrefix(value, true),
            '.' => {
                try d.ensureFloat(d.raw);
                return d.floatOrInteger(d.raw, .float);
            },
            'i', 'I', 'n', 'N' => {
                const word: []const u8 = if (value[0] == 'i' or value[0] == 'I') "inf" else "nan";
                if (!std.mem.eql(u8, value, word)) {
                    const start = d.off(value);
                    const expected: []const Expected = if (word[0] == 'i') &.{comptime lit("inf")} else &.{comptime lit("nan")};
                    return d.failAt("invalid float", expected, .{ .start = start, .end = start + value.len });
                }
                return .{ .kind = .float, .text = d.raw };
            },
            else => return d.invalidScalar(),
        }
    }

    fn zeroPrefix(d: *Decoder, value: []const u8, signed: bool) Error!Scalar {
        if (value.len == 1) return d.floatOrInteger(d.raw, .{ .integer = 10 });
        const r = value[1];
        const radix: Radix = switch (r) {
            'x', 'X' => .hex,
            'o', 'O' => .oct,
            'b', 'B' => .bin,
            'd', 'D' => .dec,
            else => return d.datetimeFloatOrInteger(value),
        };
        if (std.mem.indexOfScalar(u8, value, ' ') != null) return d.invalidScalar();
        if (signed) return d.failAt("integers with a radix cannot be signed", &.{}, .{ .start = 0, .end = 1 });
        if (radix == .dec) return d.failAt("redundant integer number prefix", &.{}, .{ .start = 0, .end = 2 });
        if (std.ascii.isUpper(r)) {
            const start = d.off(value);
            const expected: []const Expected = switch (radix) {
                .hex => &.{comptime lit("0x")},
                .oct => &.{comptime lit("0o")},
                else => &.{comptime lit("0b")},
            };
            return d.failAt("radix must be lowercase", expected, .{ .start = start, .end = start + 2 });
        }
        const stream = value[2..];
        try d.ensureRadixed(stream, radix);
        return d.floatOrInteger(stream, .{ .integer = radix.value() });
    }

    fn datetimeFloatOrInteger(d: *Decoder, value: []const u8) Error!Scalar {
        const digit_end = for (value, 0..) |c, i| {
            if (!std.ascii.isDigit(c)) break i;
        } else {
            try d.noLeadingZero(value);
            return d.floatOrInteger(d.raw, .{ .integer = 10 });
        };
        const rest = value[digit_end..];
        if (rest[0] == '-' or rest[0] == ':') return .{ .kind = .datetime, .text = d.raw };
        if (std.mem.indexOfScalar(u8, rest, ' ') != null) return d.invalidScalar();
        if (std.mem.indexOfAny(u8, rest, ".eE") != null) {
            try d.ensureFloat(value);
            return d.floatOrInteger(d.raw, .float);
        }
        if (rest[0] == '_') {
            try d.noLeadingZero(value);
            return d.floatOrInteger(d.raw, .{ .integer = 10 });
        }
        return d.invalidScalar();
    }

    fn ensureFloat(d: *Decoder, value_in: []const u8) Error!void {
        var value = value_in;
        try d.decUint(&value, false, "invalid mantissa");
        if (value.len > 0 and value[0] == '.') {
            value = value[1..];
            try d.decUint(&value, true, "invalid fraction");
        }
        if (value.len > 0 and (value[0] == 'e' or value[0] == 'E')) {
            value = value[1..];
            if (value.len > 0 and (value[0] == '+' or value[0] == '-')) value = value[1..];
            try d.decUint(&value, true, "invalid exponent");
        }
        if (value.len > 0) return d.failAt("invalid float", &.{}, .{ .start = d.off(value), .end = d.raw.len });
    }

    fn decUint(d: *Decoder, value: *[]const u8, zero_prefix: bool, invalid: []const u8) Error!void {
        const start = value.*;
        var digits: usize = 0;
        while (value.len > 0 and (std.ascii.isDigit(value.*[0]) or value.*[0] == '_')) {
            if (value.*[0] != '_') digits += 1;
            value.* = value.*[1..];
        }
        const at = d.off(start);
        if (digits == 0) return d.failAt(invalid, &.{desc("digits")}, .at(at));
        if (digits > 1 and start[0] == '0' and !zero_prefix)
            return d.failAt("unexpected leading zero", &.{}, .{ .start = at, .end = at + 1 });
    }

    fn noLeadingZero(d: *Decoder, value: []const u8) Error!void {
        if (value.len > 0 and value[0] == '0') {
            const at = d.off(value);
            return d.failAt("unexpected leading zero", &.{}, .{ .start = at, .end = at + 1 });
        }
    }

    fn ensureRadixed(d: *Decoder, value: []const u8, radix: Radix) Error!void {
        if (value.len > 0 and (value[0] == '+' or value[0] == '-')) {
            const pos = std.mem.indexOfAny(u8, d.raw, "+-").?;
            return d.failAt("unexpected sign", &.{}, .{ .start = pos, .end = pos + 1 });
        }
        var i: usize = 0;
        while (i < value.len) : (i += charLen(value[i..])) {
            if (!radix.valid(value[i]) and value[i] != '_') return d.failAt(radix.invalidDescription(), null, .at(d.off(value) + i));
        }
    }

    /// The digits without their `_` separators, each of which must stand
    /// between two digits.
    fn floatOrInteger(d: *Decoder, stream: []const u8, kind: ScalarKind) Error!Scalar {
        const stream_start = d.off(stream);
        if (std.mem.indexOfScalar(u8, stream, '_') == null) return .{ .kind = kind, .text = stream };
        var out: std.ArrayList(u8) = .empty;
        var rest = stream;
        while (rest.len > 0) {
            const sep = std.mem.indexOfScalar(u8, rest, '_');
            const sep_start = sep orelse rest.len;
            const part_start = d.off(rest);
            const part_end = part_start + sep_start;
            const part = rest[0..sep_start];
            rest = rest[sep_start..];
            if (sep != null) {
                rest = rest[1..];
                var bad = false;
                if (sep_start > 0) {
                    if (!anyDigit(d.raw[part_start + sep_start - 1], kind)) bad = true;
                } else if (part_start == stream_start) bad = true;
                if (rest.len > 0) {
                    if (!anyDigit(rest[0], kind)) bad = true;
                } else bad = true;
                if (bad) return d.failAt("`_` may only go between digits", &.{}, .{ .start = part_end, .end = part_end + 1 });
            }
            try out.appendSlice(d.p.arena, part);
        }
        return .{ .kind = kind, .text = out.items };
    }

    fn anyDigit(b: u8, kind: ScalarKind) bool {
        return if (kind == .float) std.ascii.isDigit(b) else std.ascii.isHex(b);
    }

    fn symbol(d: *Decoder, comptime word: []const u8, kind: ScalarKind, invalid: []const u8) Error!Scalar {
        if (!std.mem.eql(u8, d.raw, word)) {
            if (std.mem.indexOfScalar(u8, d.raw, ' ') != null) return d.invalidScalar();
            return d.failAt(invalid, &.{lit(word)}, d.whole());
        }
        return .{ .kind = kind, .text = word };
    }

    fn invalidScalar(d: *Decoder) Error!Scalar {
        const s = d.raw;
        if (std.mem.endsWith(u8, s, "'''")) return d.failAt("missing opening quote", &.{lit("'''")}, .at(0));
        if (std.mem.endsWith(u8, s, "\"\"\"")) return d.failAt("missing opening quote", &.{lit("\"\"\"")}, .at(0));
        if (std.mem.endsWith(u8, s, "'")) return d.failAt("missing opening quote", &.{lit("'")}, .at(0));
        if (std.mem.endsWith(u8, s, "\"")) return d.failAt("missing opening quote", &.{lit("\"")}, .at(0));
        return d.failAt("string values must be quoted", &.{desc("literal string")}, d.whole());
    }
};

// Dates and times (`toml_datetime`'s `FromStr for Datetime`).

const DatetimeError = struct {
    what: ?[]const u8 = null,
    expected: ?[]const u8 = null,

    fn message(e: DatetimeError, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print("invalid {s}", .{e.what orelse "datetime"}) catch {};
        if (e.expected) |x| w.print(", expected {s}", .{x}) catch {};
        return w.buffered();
    }
};

const DtKind = enum { digits, dash, colon, dot, t, space, z, plus, unknown };

const DtToken = struct {
    kind: DtKind,
    raw: []const u8,
};

const DtLexer = struct {
    s: []const u8,

    fn next(l: *DtLexer) ?DtToken {
        if (l.s.len == 0) return null;
        const kind: DtKind, const end: usize = switch (l.s[0]) {
            '0'...'9' => .{ .digits, std.mem.indexOfNone(u8, l.s, "0123456789") orelse l.s.len },
            '-' => .{ .dash, 1 },
            ':' => .{ .colon, 1 },
            'T', 't' => .{ .t, 1 },
            ' ' => .{ .space, 1 },
            'Z', 'z' => .{ .z, 1 },
            '+' => .{ .plus, 1 },
            '.' => .{ .dot, 1 },
            else => .{ .unknown, l.s.len },
        };
        defer l.s = l.s[end..];
        return .{ .kind = kind, .raw = l.s[0..end] };
    }

    fn peek(l: DtLexer) ?DtKind {
        var c = l;
        return if (c.next()) |t| t.kind else null;
    }
};

/// The next token, which must be `kind`; else the error says what was
/// expected of `what`.
fn dtExpect(l: *DtLexer, kind: DtKind, why: *DatetimeError, what: ?[]const u8, expected: []const u8) error{Invalid}!DtToken {
    const t = l.next();
    if (t == null or t.?.kind != kind) {
        why.* = .{ .what = what, .expected = expected };
        return error.Invalid;
    }
    return t.?;
}

fn dtFail(why: *DatetimeError, what: ?[]const u8, expected: ?[]const u8) error{Invalid} {
    why.* = .{ .what = what, .expected = expected };
    return error.Invalid;
}

/// Digits Rust's `str::parse` reads as `T`, else the bare "invalid datetime".
fn dtNum(comptime T: type, raw: []const u8, why: *DatetimeError) error{Invalid}!T {
    return std.fmt.parseInt(T, raw, 10) catch dtFail(why, null, null);
}

fn parseDatetime(s: []const u8, why: *DatetimeError) error{Invalid}!Datetime {
    var result: Datetime = .{};
    var l: DtLexer = .{ .s = s };
    const digits = try dtExpect(&l, .digits, why, null, "year or hour");
    const sep = l.next() orelse return dtFail(why, null, "`-` (YYYY-MM) or `:` (HH:MM)");
    switch (sep.kind) {
        .dash => {
            const month = try dtExpect(&l, .digits, why, "date", "month");
            _ = try dtExpect(&l, .dash, why, "date", "`-` (MM-DD)");
            const day = try dtExpect(&l, .digits, why, "date", "day");
            if (digits.raw.len != 4) return dtFail(why, "date", "a four-digit year (YYYY)");
            if (month.raw.len != 2) return dtFail(why, "date", "a two-digit month (MM)");
            if (day.raw.len != 2) return dtFail(why, "date", "a two-digit day (DD)");
            const y = try dtNum(u16, digits.raw, why);
            const m = try dtNum(u8, month.raw, why);
            const dd = try dtNum(u8, day.raw, why);
            if (m < 1 or m > 12) return dtFail(why, "date", "month between 01 and 12");
            const leap = y % 4 == 0 and (y % 100 != 0 or y % 400 == 0);
            const max: u8, const expected: []const u8 = switch (m) {
                2 => if (leap) .{ 29, "day between 01 and 29" } else .{ 28, "day between 01 and 28" },
                4, 6, 9, 11 => .{ 30, "day between 01 and 30" },
                else => .{ 31, "day between 01 and 31" },
            };
            if (dd < 1 or dd > max) return dtFail(why, "date", expected);
            result.date = .{ .year = y, .month = m, .day = dd };
        },
        .colon => l = .{ .s = s },
        else => return dtFail(why, null, "`-` (YYYY-MM) or `:` (HH:MM)"),
    }
    const partial_time = if (result.date != null) blk: {
        const t = l.next() orelse break :blk false;
        if (t.kind != .t and t.kind != .space) return dtFail(why, "date-time", "`T` between date and time");
        break :blk true;
    } else true;
    if (partial_time) {
        const hour = try dtExpect(&l, .digits, why, "time", "hour");
        _ = try dtExpect(&l, .colon, why, "time", "`:` (HH:MM)");
        const minute = try dtExpect(&l, .digits, why, "time", "minute");
        var second: ?DtToken = null;
        if (l.peek() == .colon) {
            _ = l.next();
            second = try dtExpect(&l, .digits, why, "time", "second");
        }
        var nano: ?DtToken = null;
        if (second != null and l.peek() == .dot) {
            _ = l.next();
            nano = try dtExpect(&l, .digits, why, "time", "nanosecond");
        }
        if (hour.raw.len != 2) return dtFail(why, "time", "a two-digit hour (HH)");
        if (minute.raw.len != 2) return dtFail(why, "time", "a two-digit minute (MM)");
        if (second) |x| if (x.raw.len != 2) return dtFail(why, "time", "a two-digit second (SS)");
        const h = try dtNum(u8, hour.raw, why);
        const mi = try dtNum(u8, minute.raw, why);
        const sec: ?u8 = if (second) |x| try dtNum(u8, x.raw, why) else null;
        const ns: ?u32 = if (nano) |x| blk: {
            var v: u32 = 0;
            for (x.raw, 0..) |c, i| if (i < 9) {
                v += std.math.pow(u32, 10, @intCast(8 - i)) * (c - '0');
            };
            break :blk v;
        } else null;
        if (h > 23) return dtFail(why, "time", "hour between 00 and 23");
        if (mi > 59) return dtFail(why, "time", "minute between 00 and 59");
        if ((sec orelse 0) > 60) return dtFail(why, "time", "second between 00 and 60");
        result.time = .{ .hour = h, .minute = mi, .second = sec, .nanosecond = ns };
    }
    if (result.date != null and result.time != null) if (l.next()) |t| switch (t.kind) {
        .z => result.offset = .z,
        .plus, .dash => {
            const hours = try dtExpect(&l, .digits, why, "offset", "hour");
            _ = try dtExpect(&l, .colon, why, "offset", "`:` (HH:MM)");
            const minutes = try dtExpect(&l, .digits, why, "offset", "minute");
            if (hours.raw.len != 2) return dtFail(why, "offset", "a two-digit hour (HH)");
            if (minutes.raw.len != 2) return dtFail(why, "offset", "a two-digit minute (MM)");
            const hh = try dtNum(u8, hours.raw, why);
            const mm = try dtNum(u8, minutes.raw, why);
            if (hh > 23) return dtFail(why, "offset", "hours between 00 and 23");
            if (mm > 59) return dtFail(why, "offset", "minutes between 00 and 59");
            const total: i16 = @as(i16, hh) * 60 + mm;
            result.offset = .{ .minutes = if (t.kind == .dash) -total else total };
        },
        else => return dtFail(why, "offset", "`Z`, +OFFSET, -OFFSET"),
    };
    if (l.s.len > 0) return dtFail(why, null, null);
    return result;
}

/// `toml_datetime`'s `Display`, as the toml crate shows a value.
pub fn displayDatetime(w: *std.Io.Writer, d: Datetime) std.Io.Writer.Error!void {
    if (d.date) |date| try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ date.year, date.month, date.day });
    if (d.time) |t| {
        if (d.date != null) try w.writeByte('T');
        try w.print("{d:0>2}:{d:0>2}", .{ t.hour, t.minute });
        if (t.second orelse (if (t.nanosecond != null) @as(u8, 0) else null)) |sec| try w.print(":{d:0>2}", .{sec});
        if (t.nanosecond) |ns| {
            var buf: [9]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{ns}) catch unreachable;
            const trimmed = std.mem.trimEnd(u8, &buf, "0");
            try w.print(".{s}", .{if (trimmed.len == 0) "0" else trimmed});
        }
    }
    if (d.offset) |off| switch (off) {
        .z => try w.writeByte('Z'),
        .minutes => |m| {
            const a = @abs(m);
            try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (m < 0) '-' else '+'), a / 60, a % 60 });
        },
    };
}

const testing = std.testing;

fn expectError(src: []const u8, msg: []const u8, start: ?usize) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var err: ParseError = .{};
    try testing.expectError(error.Syntax, parse(arena.allocator(), src, &err));
    try testing.expectEqualStrings(msg, err.msg);
    try testing.expectEqual(start, if (err.span) |s| s.start else null);
}

fn expectOk(src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var err: ParseError = .{};
    _ = parse(arena.allocator(), src, &err) catch |e| {
        std.debug.print("{s}: {s}\n", .{ src, err.msg });
        return e;
    };
}

test "documents the crate accepts" {
    try expectOk("a.b.c = 1\n[a.b.d]\nx = 1");
    try expectOk("[a.b.c]\n[a]\nb.d = 1");
    try expectOk("[[f]]\n[f.p]\n[[f.v]]\n[[f]]");
    try expectOk("s = \"\"\"\\\n   x\"\"\"\nt = '''\nx''''\n");
    try expectOk("d = 1979-05-27T07:32:00.5-07:00\nt = 07:32:00\nl = 1979-05-27\nm = 07:32");
    // TOML 1.1: newlines and a trailing comma in an inline table
    try expectOk("a = { b = 1,\n c = 2, }");
    try expectOk("a = \"\\e\\x41\"");
}

test "errors are the crate's, first pass before second before third" {
    try expectError("a=1\na=2", "duplicate key", 4);
    try expectError("[a]\n[a]", "duplicate key", 5);
    try expectError("a.b=1\n[a]", "duplicate key", 7);
    try expectError("a=[1]\n[[a]]", "duplicate key", 8);
    try expectError("a={}\na.b=1", "cannot extend value of type inline table with a dotted key", 5);
    try expectError("x = [1, 2", "unclosed array, expected `]`", 9);
    try expectError("k = 0x", "integer number overflowed", 4);
    try expectError("k = tru", "invalid boolean, expected `true`", 4);
    try expectError("a=01", "unexpected leading zero, expected nothing", 2);
    try expectError("a=1_", "`_` may only go between digits, expected nothing", 3);
    try expectError("a=1e400", "floating-point number overflowed", 2);
    try expectError("a = 1 b=2", "unexpected key or value, expected newline, `#`", 7);
    try expectError("a=1979-02-30", "invalid date, expected day between 01 and 28", 2);
    // a syntax error anywhere comes before a duplicate key
    try expectError("a=1\na=2\nb=[", "unclosed array, expected `]`", 11);
    // number conversion goes in key order
    try expectError("z=9223372036854775808\na=99999999999999999999999999999999999999999", "integer number overflowed", 24);
}

test "renderError" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderError(&w, "a = 1\nab = 2", .{ .msg = "duplicate key", .span = .{ .start = 6, .end = 8 } });
    try testing.expectEqualStrings(
        \\TOML parse error at line 2, column 1
        \\  |
        \\2 | ab = 2
        \\  | ^^
        \\duplicate key
        \\
    , w.buffered());
}
