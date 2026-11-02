//! Hand-written lexer over raw bytes. It mirrors the token rules of Nix's
//! `lexer.l`, including flex's longest-match choice between identifiers,
//! paths, URIs and numbers. String, indented-string and path bodies are
//! lexed on demand by the parser through the `lex*` methods, because the
//! parser must handle `${ ... }` interpolation in between.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const ast = @import("ast.zig");
const Span = ast.Span;
const text = @import("text.zig");
const bytes = @import("../bytes.zig");

pub const Error = error{ SyntaxError, OutOfMemory };

pub const Tok = enum(u8) {
    id,
    int,
    float,
    /// `./x`, `/x`, `x/y`. The text may end with `/` when an interpolation
    /// or a trailing-slash error follows.
    path,
    /// `~/x`.
    hpath,
    /// `<x/y>`.
    spath,
    uri,
    @"if",
    then,
    @"else",
    assert,
    with,
    let,
    in,
    rec,
    inherit,
    @"or",
    ellipsis,
    eq,
    ne,
    le,
    ge,
    and_and,
    or_or,
    impl,
    update,
    concat,
    pipe_from,
    pipe_into,
    dollar_curly,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    l_paren,
    r_paren,
    dot,
    semi,
    comma,
    colon,
    at,
    question,
    assign,
    bang,
    minus,
    plus,
    star,
    slash,
    lt,
    gt,
    /// `"`; the parser lexes the body with `lexStrChunk`.
    dquote,
    /// `''` plus the optional spaces-and-newline that follow it.
    ind_open,
    eof,
    invalid,

    /// The token as bison names it in an error.
    pub fn describe(t: Tok) []const u8 {
        return switch (t) {
            .id => "identifier",
            .int => "integer",
            .float => "floating-point literal",
            .path => "path",
            .hpath => "'~/…' path",
            .spath => "'<…>' path",
            .uri => "URI",
            .@"if" => "'if'",
            .then => "'then'",
            .@"else" => "'else'",
            .assert => "'assert'",
            .with => "'with'",
            .let => "'let'",
            .in => "'in'",
            .rec => "'rec'",
            .inherit => "'inherit'",
            .@"or" => "'or'",
            .ellipsis => "'...'",
            .eq => "'=='",
            .ne => "'!='",
            .le => "'<='",
            .ge => "'>='",
            .and_and => "'&&'",
            .or_or => "'||'",
            .impl => "'->'",
            .update => "'//'",
            .concat => "'++'",
            .pipe_from => "'<|'",
            .pipe_into => "'|>'",
            .dollar_curly => "'${'",
            .l_brace => "'{'",
            .r_brace => "'}'",
            .l_bracket => "'['",
            .r_bracket => "']'",
            .l_paren => "'('",
            .r_paren => "')'",
            .dot => "'.'",
            .semi => "';'",
            .comma => "','",
            .colon => "':'",
            .at => "'@'",
            .question => "'?'",
            .assign => "'='",
            .bang => "'!'",
            .minus => "'-'",
            .plus => "'+'",
            .star => "'*'",
            .slash => "'/'",
            .lt => "'<'",
            .gt => "'>'",
            .dquote => "'\"'",
            .ind_open => "start of an indented string",
            .eof => "end of file",
            .invalid => "invalid token",
        };
    }
};

/// Packed, so `nextToken` returns it in two registers: a plain struct goes
/// back through memory, and reloading its byte-wide kind as part of a wider
/// load stalls store forwarding.
pub const Token = packed struct(u128) {
    start: u32,
    end: u32,
    kind: Tok,
    _pad: u56 = 0,

    pub fn span(t: Token) Span {
        return .{ .start = t.start, .end = t.end };
    }
};

/// How one literal run inside a string ended.
pub const StrEnd = enum { interp, close };

/// One token inside an indented string, before indentation stripping.
pub const IndPart = union(enum) {
    /// Raw source bytes; participates in indentation measurement.
    src: struct { start: u32, end: u32 },
    /// `''$`, `'''`, `''\x`, lone `$` or `'`; never counts as indentation.
    lit: struct { bytes: [2]u8, len: u8 },
    interp,
};

pub const PathPart = union(enum) {
    str: struct { start: u32, end: u32 },
    interp,
    end,
};

const id_class: u8 = 1;
const path_class: u8 = 2;

/// One load per byte where the two tests made up to six compares.
const class: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    for (0..256) |b| {
        const c: u8 = @intCast(b);
        const alnum = std.ascii.isAlphanumeric(c);
        if (alnum or c == '_' or c == '\'' or c == '-') t[b] |= id_class;
        if (alnum or c == '.' or c == '_' or c == '-' or c == '+') t[b] |= path_class;
    }
    break :blk t;
};

inline fn isIdChar(b: u8) bool {
    return class[b] & id_class != 0;
}

inline fn isPathChar(b: u8) bool {
    return class[b] & path_class != 0;
}

fn isUriSchemeChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '+' or b == '-' or b == '.';
}

fn isUriChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or switch (b) {
        '%', '/', '?', ':', '@', '&', '=', '+', '$', ',', '-', '_', '.', '!', '~', '*', '\'' => true,
        else => false,
    };
}

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    gpa: Allocator,
    d: *Diag,
    /// Where the last error is, as a byte offset.
    err_at: u32 = 0,
    /// `# iets:` comments as `#`-start and end offsets; `takeAllows`
    /// resolves their lines, so the token path pays nothing for them.
    allows: std.ArrayList([2]u32) = .empty,
    /// End of the last `# iets:` comment noted: the parser rewinds for its
    /// third token of lookahead, and a comment is noted once.
    noted_to: usize = 0,
    /// Where an error places the end of the file when a path runs into it:
    /// the last token of the path, which Nix's lexer unstashes there
    /// (lexer.l, `<INPATH><<EOF>>`).
    eof_at: ?u32 = null,
    /// A failed allocation while noting a comment, reported by `takeAllows`.
    oom: bool = false,

    pub fn init(gpa: Allocator, src: []const u8, d: *Diag) Lexer {
        return .{ .src = src, .gpa = gpa, .d = d };
    }

    pub fn deinit(lx: *Lexer) void {
        lx.allows.deinit(lx.gpa);
    }

    pub fn fail(lx: *Lexer, offset: u32, comptime fmt: []const u8, args: anytype) error{SyntaxError} {
        lx.err_at = offset;
        return lx.d.fail(error.SyntaxError, fmt, args);
    }

    /// The `# iets:` comments lexed so far, in source order, each with the
    /// line it covers: after code its own line; on a line of its own the
    /// line of the next token, found by skipping trivia again from the
    /// comment's end (an own-line comment at the end of the file covers
    /// nothing).
    pub fn takeAllows(lx: *Lexer, out: *std.ArrayList(ast.AllowComment), gpa: Allocator) !void {
        if (lx.oom) return error.OutOfMemory;
        defer lx.allows.clearRetainingCapacity();
        for (lx.allows.items) |se| {
            const start: usize = se[0];
            const end: usize = se[1];
            const txt: Span = .{ .start = @intCast(start + "# iets:".len), .end = @intCast(end) };
            var i = start;
            while (i > 0 and (lx.src[i - 1] == ' ' or lx.src[i - 1] == '\t')) i -= 1;
            const own_line = i == 0 or lx.src[i - 1] == '\n' or lx.src[i - 1] == '\r';
            var line: Span = undefined;
            if (own_line) {
                const save = lx.pos;
                lx.pos = end;
                lx.skipTrivia();
                const p = lx.pos;
                lx.pos = save;
                if (p >= lx.src.len) continue;
                line = .{ .start = @intCast(lx.lineStart(p)), .end = @intCast(lx.lineEnd(p)) };
            } else {
                line = .{ .start = @intCast(lx.lineStart(start)), .end = @intCast(end) };
            }
            try out.append(gpa, .{ .text = txt, .line = line });
        }
    }

    fn lineStart(lx: *const Lexer, p: usize) usize {
        var i = p;
        while (i > 0 and lx.src[i - 1] != '\n') i -= 1;
        return i;
    }

    fn lineEnd(lx: *const Lexer, p: usize) usize {
        var i = p;
        while (i < lx.src.len and lx.src[i] != '\n' and lx.src[i] != '\r') i += 1;
        return i;
    }

    /// A `#` comment to the end of its line, noted when it is `# iets:`.
    /// Out of line so `nextToken` stays small.
    noinline fn comment(lx: *Lexer) void {
        const src = lx.src;
        const start = lx.pos;
        const i = bytes.findAnyPos(src, start, "\n\r") orelse src.len;
        lx.pos = i;
        if (lx.at(start + 2) == 'i' and std.mem.startsWith(u8, src[start..i], "# iets:") and start >= lx.noted_to) {
            lx.noted_to = i;
            lx.allows.append(lx.gpa, .{ @intCast(start), @intCast(i) }) catch {
                lx.oom = true;
            };
        }
    }

    inline fn at(lx: *const Lexer, i: usize) u8 {
        return if (i < lx.src.len) lx.src[i] else 0;
    }

    inline fn skipTrivia(lx: *Lexer) void {
        const src = lx.src;
        var p = lx.pos;
        while (p < src.len) {
            switch (src[p]) {
                ' ', '\t', '\r', '\n' => p += 1,
                '#' => {
                    lx.pos = p;
                    lx.comment();
                    p = lx.pos;
                },
                '/' => {
                    if (lx.at(p + 1) != '*') break;
                    const body = p + 2;
                    const k = std.mem.find(u8, src[@min(body, src.len)..], "*/") orelse break;
                    p = body + k + 2;
                },
                else => break,
            }
        }
        lx.pos = p;
    }

    /// `PATH_CHAR* ('/' PATH_CHAR+)+ '/'?` starting at `p`.
    fn scanPath(lx: *const Lexer, p: usize) ?usize {
        var i = p;
        while (isPathChar(lx.at(i))) i += 1;
        if (lx.at(i) != '/') return null;
        var end: ?usize = null;
        while (true) {
            const seg = i + 1;
            var j = seg;
            while (isPathChar(lx.at(j))) j += 1;
            if (j == seg) return if (end != null) i + 1 else null;
            end = j;
            i = j;
            if (lx.at(i) != '/') return end;
        }
    }

    /// Longest of PATH or `PATH_SEG` followed by `${`; returns the token end.
    fn scanPathToken(lx: *const Lexer, p: usize) ?usize {
        var i = p;
        while (isPathChar(lx.at(i))) i += 1;
        if (lx.at(i) != '/') return null;
        if (lx.scanPath(p)) |e| return e;
        if (lx.at(i + 1) == '$' and lx.at(i + 2) == '{') return i + 1;
        return null;
    }

    /// `~ ('/' PATH_CHAR+)+ '/'?` or `~/` followed by `${`.
    fn scanHpath(lx: *const Lexer, p: usize) ?usize {
        if (lx.at(p) != '~' or lx.at(p + 1) != '/') return null;
        if (lx.scanPath(p + 1)) |e| return e;
        if (lx.at(p + 2) == '$' and lx.at(p + 3) == '{') return p + 2;
        return null;
    }

    fn scanSpath(lx: *const Lexer, p: usize) ?usize {
        var i = p + 1;
        const start = i;
        while (isPathChar(lx.at(i))) i += 1;
        if (i == start) return null;
        while (lx.at(i) == '/') {
            const seg = i + 1;
            var j = seg;
            while (isPathChar(lx.at(j))) j += 1;
            if (j == seg) return null;
            i = j;
        }
        return if (lx.at(i) == '>') i + 1 else null;
    }

    fn scanUri(lx: *const Lexer, p: usize) ?usize {
        if (!std.ascii.isAlphabetic(lx.at(p))) return null;
        var i = p + 1;
        while (isUriSchemeChar(lx.at(i))) i += 1;
        if (lx.at(i) != ':') return null;
        i += 1;
        const body = i;
        while (isUriChar(lx.at(i))) i += 1;
        return if (i == body) null else i;
    }

    const KindEnd = struct { Tok, usize };

    /// Longest match: `kind` up to `end`, unless a float or a path that
    /// starts at `start` runs further.
    fn orFloatOrPath(lx: *const Lexer, start: usize, kind0: Tok, end0: usize) KindEnd {
        var kind = kind0;
        var end = end0;
        if (lx.scanFloat(start)) |e| if (e > end) {
            kind = .float;
            end = e;
        };
        if (lx.scanPathToken(start)) |e| if (e > end) {
            kind = .path;
            end = e;
        };
        return .{ kind, end };
    }

    fn scanFloat(lx: *const Lexer, p: usize) ?usize {
        var i = p;
        const b = lx.at(i);
        if (b >= '1' and b <= '9') {
            i += 1;
            while (std.ascii.isDigit(lx.at(i))) i += 1;
            if (lx.at(i) != '.') return null;
            i += 1;
            while (std.ascii.isDigit(lx.at(i))) i += 1;
        } else {
            if (b == '0') i += 1;
            if (lx.at(i) != '.') return null;
            i += 1;
            const start = i;
            while (std.ascii.isDigit(lx.at(i))) i += 1;
            if (i == start) return null;
        }
        if (lx.at(i) == 'e' or lx.at(i) == 'E') {
            var j = i + 1;
            if (lx.at(j) == '+' or lx.at(j) == '-') j += 1;
            const digits = j;
            while (std.ascii.isDigit(lx.at(j))) j += 1;
            if (j > digits) i = j;
        }
        return i;
    }

    /// The keyword `w` spells, or `.id`: by length, then one integer
    /// compare per candidate.
    inline fn keyword(w: []const u8) Tok {
        const Kw = struct {
            inline fn is(x: []const u8, comptime k: []const u8) bool {
                const T = @Int(.unsigned, 8 * k.len);
                return std.mem.readInt(T, x[0..k.len], .little) == comptime std.mem.readInt(T, k[0..k.len], .little);
            }
        };
        if (w[0] < 'a') return .id;
        return switch (w.len) {
            2 => if (Kw.is(w, "if")) .@"if" else if (Kw.is(w, "in")) .in else if (Kw.is(w, "or")) .@"or" else .id,
            3 => if (Kw.is(w, "let")) .let else if (Kw.is(w, "rec")) .rec else .id,
            4 => if (Kw.is(w, "then")) .then else if (Kw.is(w, "else")) .@"else" else if (Kw.is(w, "with")) .with else .id,
            6 => if (Kw.is(w, "assert")) .assert else .id,
            7 => if (Kw.is(w, "inherit")) .inherit else .id,
            else => .id,
        };
    }

    /// Next token in normal (expression) mode.
    pub fn nextToken(lx: *Lexer) Token {
        lx.skipTrivia();
        const start = lx.pos;
        if (start >= lx.src.len) {
            const p = lx.eof_at orelse @as(u32, @intCast(start));
            return .{ .kind = .eof, .start = p, .end = p };
        }
        const b = lx.src[start];
        const kind: Tok, const end: usize = switch (b) {
            'a'...'z', 'A'...'Z', '_' => blk: {
                var i = start + 1;
                while (isIdChar(lx.at(i))) i += 1;
                var kind: Tok = .id;
                var end = i;
                const next = lx.at(i);
                if (next == ':' or next == '.' or next == '+' or next == '/') {
                    // A path needs a `/` and a URI a `:` right after the
                    // run of path chars from `start`; `a.b.c` chains have
                    // neither and skip both scans.
                    var k = start;
                    while (isPathChar(lx.at(k))) k += 1;
                    const after = lx.at(k);
                    if (after == '/') if (lx.scanPathToken(start)) |e| if (e > end) {
                        kind = .path;
                        end = e;
                    };
                    if (after == ':') if (lx.scanUri(start)) |e| if (e > end) {
                        kind = .uri;
                        end = e;
                    };
                }
                if (kind == .id) kind = keyword(lx.src[start..end]);
                break :blk .{ kind, end };
            },
            '0'...'9' => blk: {
                var i = start + 1;
                while (std.ascii.isDigit(lx.at(i))) i += 1;
                break :blk lx.orFloatOrPath(start, .int, i);
            },
            '.' => blk: {
                if (lx.at(start + 1) == '.' and lx.at(start + 2) == '.')
                    break :blk lx.orFloatOrPath(start, .ellipsis, start + 3);
                break :blk lx.orFloatOrPath(start, .dot, start + 1);
            },
            '/' => if (lx.scanPathToken(start)) |e|
                .{ .path, e }
            else if (lx.at(start + 1) == '/')
                .{ .update, start + 2 }
            else
                .{ .slash, start + 1 },
            '-' => if (lx.scanPathToken(start)) |e|
                .{ .path, e }
            else if (lx.at(start + 1) == '>')
                .{ .impl, start + 2 }
            else
                .{ .minus, start + 1 },
            '+' => if (lx.scanPathToken(start)) |e|
                .{ .path, e }
            else if (lx.at(start + 1) == '+')
                .{ .concat, start + 2 }
            else
                .{ .plus, start + 1 },
            '~' => if (lx.scanHpath(start)) |e| .{ .hpath, e } else .{ .invalid, start + 1 },
            '<' => if (lx.scanSpath(start)) |e| .{ .spath, e } else switch (lx.at(start + 1)) {
                '=' => .{ .le, start + 2 },
                '|' => .{ .pipe_from, start + 2 },
                else => .{ .lt, start + 1 },
            },
            '>' => if (lx.at(start + 1) == '=') .{ .ge, start + 2 } else .{ .gt, start + 1 },
            '=' => if (lx.at(start + 1) == '=') .{ .eq, start + 2 } else .{ .assign, start + 1 },
            '!' => if (lx.at(start + 1) == '=') .{ .ne, start + 2 } else .{ .bang, start + 1 },
            '&' => if (lx.at(start + 1) == '&') .{ .and_and, start + 2 } else .{ .invalid, start + 1 },
            '|' => switch (lx.at(start + 1)) {
                '|' => .{ .or_or, start + 2 },
                '>' => .{ .pipe_into, start + 2 },
                else => .{ .invalid, start + 1 },
            },
            '$' => if (lx.at(start + 1) == '{') .{ .dollar_curly, start + 2 } else .{ .invalid, start + 1 },
            '\'' => blk: {
                if (lx.at(start + 1) != '\'') break :blk .{ .invalid, start + 1 };
                var i = start + 2;
                while (lx.at(i) == ' ') i += 1;
                if (lx.at(i) == '\n' and i < lx.src.len) break :blk .{ .ind_open, i + 1 };
                break :blk .{ .ind_open, start + 2 };
            },
            '"' => .{ .dquote, start + 1 },
            '{' => .{ .l_brace, start + 1 },
            '}' => .{ .r_brace, start + 1 },
            '[' => .{ .l_bracket, start + 1 },
            ']' => .{ .r_bracket, start + 1 },
            '(' => .{ .l_paren, start + 1 },
            ')' => .{ .r_paren, start + 1 },
            ';' => .{ .semi, start + 1 },
            ',' => .{ .comma, start + 1 },
            ':' => .{ .colon, start + 1 },
            '@' => .{ .at, start + 1 },
            '?' => .{ .question, start + 1 },
            '*' => .{ .star, start + 1 },
            else => .{ .invalid, start + 1 },
        };
        lx.pos = end;
        return .{ .kind = kind, .start = @intCast(start), .end = @intCast(end) };
    }

    /// Lex literal text of a `"..."` string into `out` until `${` or the
    /// closing quote. Escapes are decoded and CR / CRLF become LF.
    pub fn lexStrChunk(lx: *Lexer, out: *std.ArrayList(u8), gpa: Allocator) Error!StrEnd {
        const start = lx.pos;
        const base = out.items.len;
        // a NUL before an error at the end of the file is the one reported
        const end = lx.strChunk(out, gpa);
        // lexer.l:unescapeStr tests the raw bytes, so an escaped NUL passes
        if (std.mem.findScalar(u8, lx.src[start..lx.pos], 0) == null) return end;
        var i = start;
        while (i < lx.pos) {
            switch (lx.src[i]) {
                '\\' => i += 2,
                0 => return lx.nulError(start, out.items[base..]),
                else => i += 1,
            }
        }
        return end;
    }

    fn strChunk(lx: *Lexer, out: *std.ArrayList(u8), gpa: Allocator) Error!StrEnd {
        const src = lx.src;
        while (true) {
            if (lx.pos >= src.len) return lx.eofError("expecting '\"'");
            switch (src[lx.pos]) {
                '"' => {
                    lx.pos += 1;
                    return .close;
                },
                '\\' => {
                    lx.pos += 1;
                    if (lx.pos >= src.len) return lx.eofError("expecting '\"'");
                    try out.append(gpa, unescape(src[lx.pos]));
                    lx.pos += 1;
                },
                '\r' => {
                    try out.append(gpa, '\n');
                    lx.pos += 1;
                    if (lx.at(lx.pos) == '\n') lx.pos += 1;
                },
                '$' => {
                    lx.pos += 1;
                    const c = lx.at(lx.pos);
                    if (c == '{') {
                        lx.pos += 1;
                        return .interp;
                    } else if (c == '"' or c == '\\') {
                        try out.append(gpa, '$');
                    } else if (lx.pos >= src.len) {
                        return lx.eofError("expecting '\"'");
                    } else if (c == '\r') {
                        try out.appendSlice(gpa, "$\n");
                        lx.pos += 1;
                        if (lx.at(lx.pos) == '\n') lx.pos += 1;
                    } else {
                        try out.appendSlice(gpa, &.{ '$', c });
                        lx.pos += 1;
                    }
                },
                else => {
                    const run = lx.pos;
                    var i = bytes.findAnyPos(src, run + 1, "\"\\$\r") orelse src.len;
                    _ = &i;
                    try out.appendSlice(gpa, src[run..i]);
                    lx.pos = i;
                },
            }
        }
    }

    /// Lex tokens of an indented string into `parts` until `${` or `''`.
    pub fn lexIndChunk(lx: *Lexer, parts: *std.ArrayList(IndPart), gpa: Allocator) Error!StrEnd {
        const src = lx.src;
        while (true) {
            if (lx.pos >= src.len) return lx.eofError("expecting end of an indented string");
            const b = src[lx.pos];
            if (b == '\'' and lx.at(lx.pos + 1) == '\'') {
                const c = lx.at(lx.pos + 2);
                if (lx.pos + 2 < src.len) {
                    if (c == '$') {
                        try parts.append(gpa, .{ .lit = .{ .bytes = .{ '$', 0 }, .len = 1 } });
                        lx.pos += 3;
                        continue;
                    } else if (c == '\'') {
                        try parts.append(gpa, .{ .lit = .{ .bytes = .{ '\'', '\'' }, .len = 2 } });
                        lx.pos += 3;
                        continue;
                    } else if (c == '\\' and lx.pos + 3 < src.len) {
                        try parts.append(gpa, .{ .lit = .{ .bytes = .{ unescape(src[lx.pos + 3]), 0 }, .len = 1 } });
                        lx.pos += 4;
                        continue;
                    }
                }
                lx.pos += 2;
                return .close;
            }
            if (b == '$' and lx.at(lx.pos + 1) == '{') {
                lx.pos += 2;
                return .interp;
            }
            const start = lx.pos;
            var i = start;
            while (true) {
                i = bytes.findAnyPos(src, i, "'$") orelse {
                    i = src.len;
                    break;
                };
                const n = lx.at(i + 1);
                if (src[i] == '\'') {
                    if (n == '\'' or n == '$' or i + 1 >= src.len) break;
                } else {
                    if (n == '{' or n == '\'' or i + 1 >= src.len) break;
                }
                i += 2;
            }
            if (i > start) {
                if (std.mem.findScalar(u8, src[start..i], 0) != null) return lx.nulError(start, src[start..i]);
                try parts.append(gpa, .{ .src = .{ .start = @intCast(start), .end = @intCast(i) } });
                lx.pos = i;
                continue;
            }
            try parts.append(gpa, .{ .lit = .{ .bytes = .{ b, 0 }, .len = 1 } });
            lx.pos += 1;
        }
    }

    /// Continue a path after its first token or after `}` of an
    /// interpolation. `after_slash` is true when the previous piece ended
    /// with `/`.
    pub fn lexPathPart(lx: *Lexer, after_slash: bool) error{SyntaxError}!PathPart {
        const p = lx.pos;
        if (lx.at(p) == '$' and lx.at(p + 1) == '{') {
            lx.pos = p + 2;
            return .interp;
        }
        const end: ?usize = lx.scanPath(p) orelse blk: {
            var i = p;
            while (isPathChar(lx.at(i))) i += 1;
            if (lx.at(i) == '/') break :blk i + 1;
            if (i > p) break :blk i;
            break :blk null;
        };
        if (end) |e| {
            lx.pos = e;
            return .{ .str = .{ .start = @intCast(p), .end = @intCast(e) } };
        }
        if (after_slash) return lx.fail(@intCast(p), "path has a trailing slash", .{});
        return .end;
    }

    fn eofError(lx: *Lexer, comptime expecting: []const u8) error{SyntaxError} {
        return lx.fail(@intCast(lx.src.len), "syntax error, unexpected end of file, " ++ expecting, .{});
    }

    fn nulError(lx: *Lexer, start: usize, s: []const u8) error{SyntaxError} {
        return lx.fail(@intCast(start), "{f}", .{text.noNulMessage(s)});
    }
};

inline fn unescape(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => c,
    };
}
