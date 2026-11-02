//! The syntax tree as text: `writeJson` prints the machine form of
//! `iets parse --json` (docs/reference/syntax-tree.md), `writeSexp` the
//! S-expressions of `iets parse` and of the tests. Both walk the `Ast`
//! directly.

const std = @import("std");
const Writer = std.Io.Writer;
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const AttrElem = ast_mod.AttrElem;
const Bind = ast_mod.Bind;
const ExprId = ast_mod.ExprId;
const Range = ast_mod.Range;
const Span = ast_mod.Span;
const Interner = @import("symbol.zig").Interner;
const Sym = @import("symbol.zig").Sym;
const text = @import("text.zig");

const E = Writer.Error;

fn binOpName(op: ast_mod.BinOp) []const u8 {
    return switch (op) {
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .gt => ">",
        .le => "<=",
        .ge => ">=",
        .@"and" => "&&",
        .@"or" => "||",
        .impl => "->",
        .update => "//",
        .concat => "++",
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
    };
}

fn pathForm(k: ast_mod.PathKind) []const u8 {
    return switch (k) {
        .relative => "relative",
        .absolute => "absolute",
        .home => "home",
        .search => "search",
    };
}

/// The shortest digits that read back as `v`, and the decimal exponent of
/// the first one: `v = 0.d1d2... * 10^(exp + 1)`.
const Decimal = struct {
    neg: bool,
    digits: []const u8,
    exp: i32,

    fn of(v: f64, buf: *[64]u8) Decimal {
        const s = std.fmt.float.render(buf, v, .{}) catch unreachable;
        const neg = s[0] == '-';
        const body = s[@intFromBool(neg)..];
        const e = std.mem.findScalar(u8, body, 'e').?;
        const exp = std.fmt.parseInt(i32, body[e + 1 ..], 10) catch unreachable;
        // drop the point in place: `d.ddd` -> `dddd`, kept in `buf`
        const mant = body[0..e];
        var n: usize = 0;
        const out = buf[32..];
        for (mant) |c| if (c != '.') {
            out[n] = c;
            n += 1;
        };
        return .{ .neg = neg, .digits = out[0..n], .exp = exp };
    }

    fn writeFixed(d: Decimal, w: *Writer) E!void {
        if (d.exp >= 0) {
            const int_len: usize = @intCast(d.exp + 1);
            if (d.digits.len <= int_len) {
                try w.writeAll(d.digits);
                try w.splatByteAll('0', int_len - d.digits.len);
                try w.writeAll(".0");
            } else {
                try w.writeAll(d.digits[0..int_len]);
                try w.writeByte('.');
                try w.writeAll(d.digits[int_len..]);
            }
        } else {
            try w.writeAll("0.");
            try w.splatByteAll('0', @intCast(-d.exp - 1));
            try w.writeAll(d.digits);
        }
    }

    fn writeExp(d: Decimal, w: *Writer, plus: bool) E!void {
        try w.writeByte(d.digits[0]);
        if (d.digits.len > 1) {
            try w.writeByte('.');
            try w.writeAll(d.digits[1..]);
        }
        try w.writeByte('e');
        if (plus and d.exp >= 0) try w.writeByte('+');
        try w.print("{d}", .{d.exp});
    }
};

/// A float as Rust iets's dump prints it (Rust's `{:?}`).
pub fn writeFloatDebug(w: *Writer, v: f64) E!void {
    if (v == 0) return w.writeAll(if (std.math.signbit(v)) "-0.0" else "0.0");
    var buf: [64]u8 = undefined;
    const d: Decimal = .of(v, &buf);
    if (d.neg) try w.writeByte('-');
    if (d.exp < -4 or d.exp >= 16) return d.writeExp(w, false);
    return d.writeFixed(w);
}

/// A float as Rust iets's JSON prints it (serde_json with zmij).
pub fn writeFloatJson(w: *Writer, v: f64) E!void {
    if (v == 0) return w.writeAll(if (std.math.signbit(v)) "-0.0" else "0.0");
    var buf: [64]u8 = undefined;
    const d: Decimal = .of(v, &buf);
    if (d.neg) try w.writeByte('-');
    if (d.exp < -5 or d.exp > 15) return d.writeExp(w, true);
    return d.writeFixed(w);
}

/// Text in the S-expressions: printable ASCII as is, the rest escaped.
fn quote(w: *Writer, bytes: []const u8) E!void {
    try w.writeByte('"');
    for (bytes) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(b),
        else => try w.print("\\x{x:0>2}", .{b}),
    };
    try w.writeByte('"');
}

const Sexp = struct {
    a: *const Ast,
    i: *const Interner,
    w: *Writer,

    fn name(s: Sexp, sym: Sym) E!void {
        try s.w.writeAll(s.i.nameStr(sym));
    }

    fn parts(s: Sexp, r: Range) E!void {
        for (s.a.partsOf(r)) |p| {
            try s.w.writeByte(' ');
            switch (p) {
                .lit => |l| try quote(s.w, s.a.bytesOf(l)),
                .interp => |e| {
                    try s.w.writeAll("(interp ");
                    try s.expr(e);
                    try s.w.writeByte(')');
                },
            }
        }
    }

    fn attrpath(s: Sexp, r: Range) E!void {
        try s.w.writeByte('(');
        for (s.a.elemsOf(r), 0..) |el, k| {
            if (k > 0) try s.w.writeByte(' ');
            switch (el) {
                .static => |sym| try s.name(sym),
                .dynamic => |e| {
                    try s.w.writeAll("(dyn ");
                    try s.expr(e);
                    try s.w.writeByte(')');
                },
            }
        }
        try s.w.writeByte(')');
    }

    fn binds(s: Sexp, r: Range) E!void {
        for (s.a.bindsOf(r)) |b| {
            try s.w.writeByte(' ');
            switch (b.kind) {
                .value => |v| {
                    try s.w.writeAll("(= ");
                    try s.attrpath(v.path);
                    try s.w.writeByte(' ');
                    try s.expr(v.value);
                },
                .inherit => |inh| {
                    try s.w.writeAll("(inherit");
                    if (inh.from != .none) {
                        try s.w.writeAll(" (from ");
                        try s.expr(inh.from);
                        try s.w.writeByte(')');
                    }
                    for (s.a.namesOf(inh.names)) |n| {
                        try s.w.writeByte(' ');
                        try s.name(n.sym);
                    }
                },
            }
            try s.w.writeByte(')');
        }
    }

    fn list(s: Sexp, r: Range) E!void {
        for (s.a.idsOf(r)) |e| {
            try s.w.writeByte(' ');
            try s.expr(e);
        }
    }

    fn fields(s: Sexp, head: []const u8, es: []const ExprId) E!void {
        try s.w.writeByte('(');
        try s.w.writeAll(head);
        for (es) |e| {
            try s.w.writeByte(' ');
            try s.expr(e);
        }
        try s.w.writeByte(')');
    }

    fn expr(s: Sexp, id: ExprId) E!void {
        const w = s.w;
        switch (s.a.expr(id)) {
            .int => |v| try w.print("{d}", .{v}),
            .float => |v| try writeFloatDebug(w, v),
            .@"var" => |sym| try s.name(sym),
            .str => |r| {
                try w.writeAll("(str");
                try s.parts(r);
                try w.writeByte(')');
            },
            .path => |p| {
                try w.writeAll("(path ");
                try w.writeAll(switch (p.kind) {
                    .relative => "rel",
                    .absolute => "abs",
                    .home => "home",
                    .search => "search",
                });
                try s.parts(p.parts);
                try w.writeByte(')');
            },
            .select => |x| {
                try w.writeAll("(select ");
                try s.expr(x.subject);
                try w.writeByte(' ');
                try s.attrpath(x.path);
                if (x.default != .none) {
                    try w.writeAll(" (or ");
                    try s.expr(x.default);
                    try w.writeByte(')');
                }
                try w.writeByte(')');
            },
            .has_attr => |x| {
                try w.writeAll("(? ");
                try s.expr(x.subject);
                try w.writeByte(' ');
                try s.attrpath(x.path);
                try w.writeByte(')');
            },
            .attrs => |x| {
                try w.writeAll(if (x.rec) "(rec-attrs" else "(attrs");
                try s.binds(x.binds);
                try w.writeByte(')');
            },
            .list => |r| {
                try w.writeAll("(list");
                try s.list(r);
                try w.writeByte(')');
            },
            .lambda => |x| {
                try w.writeAll("(lambda ");
                try s.name(x.arg);
                try w.writeByte(' ');
                try s.expr(x.body);
                try w.writeByte(')');
            },
            .lambda_pattern => |x| {
                const pat = s.a.pattern(x.pattern);
                try w.writeAll("(lambda {");
                const formals = s.a.formalsOf(pat.formals);
                for (formals, 0..) |f, k| {
                    if (k > 0) try w.writeAll(", ");
                    try s.name(f.name);
                    if (f.default != .none) {
                        try w.writeAll(" ? ");
                        try s.expr(f.default);
                    }
                }
                if (pat.ellipsis) try w.writeAll(if (formals.len == 0) "..." else ", ...");
                try w.writeByte('}');
                if (pat.bind) |b| {
                    try w.writeAll(" @ ");
                    try s.name(b);
                }
                try w.writeByte(' ');
                try s.expr(x.body);
                try w.writeByte(')');
            },
            .apply => |x| {
                try w.writeAll("(apply ");
                try s.expr(x.func);
                try s.list(x.args);
                try w.writeByte(')');
            },
            .let => |x| {
                try w.writeAll("(let (");
                try s.binds(x.binds);
                try w.writeAll(") ");
                try s.expr(x.body);
                try w.writeByte(')');
            },
            .with => |x| try s.fields("with", &.{ x.scope, x.body }),
            .@"if" => |x| try s.fields("if", &.{ x.cond, x.then, x.@"else" }),
            .assert => |x| try s.fields("assert", &.{ x.cond, x.body }),
            .unary => |x| try s.fields(if (x.op == .neg) "neg" else "!", &.{x.expr}),
            .binary => |x| try s.fields(binOpName(x.op), &.{ x.lhs, x.rhs }),
        }
    }
};

/// The S-expression of the whole file, without a trailing newline.
pub fn writeSexp(w: *Writer, a: *const Ast, i: *const Interner) E!void {
    return (Sexp{ .a = a, .i = i, .w = w }).expr(a.root);
}

const Json = struct {
    a: *const Ast,
    i: *const Interner,
    w: *Writer,

    fn open(j: Json, kind: []const u8, span: Span) E!void {
        try j.w.print("{{\"kind\":\"{s}\",\"start\":{d},\"end\":{d}", .{ kind, span.start, span.end });
    }

    fn field(j: Json, comptime f: []const u8) E!void {
        try j.w.writeAll(",\"" ++ f ++ "\":");
    }

    fn name(j: Json, sym: Sym) E!void {
        try text.writeJsonString(j.w, j.i.nameStr(sym));
    }

    fn opt(j: Json, e: ExprId) E!void {
        if (e == .none) return j.w.writeAll("null");
        try j.expr(e);
    }

    fn list(j: Json, r: Range) E!void {
        try j.w.writeByte('[');
        for (j.a.idsOf(r), 0..) |e, k| {
            if (k > 0) try j.w.writeByte(',');
            try j.expr(e);
        }
        try j.w.writeByte(']');
    }

    fn parts(j: Json, r: Range) E!void {
        try j.w.writeByte('[');
        for (j.a.partsOf(r), 0..) |p, k| {
            if (k > 0) try j.w.writeByte(',');
            switch (p) {
                .lit => |l| try text.writeJsonString(j.w, j.a.bytesOf(l)),
                .interp => |e| try j.expr(e),
            }
        }
        try j.w.writeByte(']');
    }

    fn attrpath(j: Json, r: Range) E!void {
        try j.w.writeByte('[');
        for (j.a.elemsOf(r), 0..) |el, k| {
            if (k > 0) try j.w.writeByte(',');
            switch (el) {
                .static => |sym| try j.name(sym),
                .dynamic => |e| try j.expr(e),
            }
        }
        try j.w.writeByte(']');
    }

    fn binds(j: Json, r: Range) E!void {
        try j.w.writeByte('[');
        for (j.a.bindsOf(r), 0..) |b, k| {
            if (k > 0) try j.w.writeByte(',');
            switch (b.kind) {
                .value => |v| {
                    try j.open("bind", b.span);
                    try j.field("path");
                    try j.attrpath(v.path);
                    try j.field("value");
                    try j.expr(v.value);
                },
                .inherit => |inh| {
                    try j.open("inherit", b.span);
                    try j.field("from");
                    try j.opt(inh.from);
                    try j.field("names");
                    try j.w.writeByte('[');
                    for (j.a.namesOf(inh.names), 0..) |n, m| {
                        if (m > 0) try j.w.writeByte(',');
                        try j.open("name", n.span);
                        try j.field("name");
                        try j.name(n.sym);
                        try j.w.writeByte('}');
                    }
                    try j.w.writeByte(']');
                },
            }
            try j.w.writeByte('}');
        }
        try j.w.writeByte(']');
    }

    fn exprField(j: Json, comptime f: []const u8, e: ExprId) E!void {
        try j.field(f);
        try j.expr(e);
    }

    fn opName(j: Json, op: []const u8) E!void {
        try j.field("op");
        try text.writeJsonString(j.w, op);
    }

    fn lambdaTail(j: Json, ellipsis: bool, body: ExprId) E!void {
        try j.field("ellipsis");
        try j.w.writeAll(if (ellipsis) "true" else "false");
        try j.exprField("body", body);
    }

    fn expr(j: Json, id: ExprId) E!void {
        const w = j.w;
        const e = j.a.expr(id);
        try j.open(switch (e) {
            .int => "int",
            .float => "float",
            .str => "string",
            .path => "path",
            .@"var" => "var",
            .select => "select",
            .has_attr => "has-attr",
            .attrs => "attrs",
            .list => "list",
            .lambda, .lambda_pattern => "lambda",
            .apply => "apply",
            .let => "let",
            .with => "with",
            .@"if" => "if",
            .assert => "assert",
            .unary => "unary",
            .binary => "binary",
        }, j.a.span(id));
        switch (e) {
            .int => |v| {
                try j.field("value");
                try w.print("{d}", .{v});
            },
            .float => |v| {
                try j.field("value");
                try writeFloatJson(w, v);
            },
            .str => |r| {
                try j.field("parts");
                try j.parts(r);
            },
            .path => |p| {
                try j.field("form");
                try text.writeJsonString(w, pathForm(p.kind));
                try j.field("parts");
                try j.parts(p.parts);
            },
            .@"var" => |sym| {
                try j.field("name");
                try j.name(sym);
            },
            .select => |x| {
                try j.exprField("subject", x.subject);
                try j.field("path");
                try j.attrpath(x.path);
                try j.field("default");
                try j.opt(x.default);
            },
            .has_attr => |x| {
                try j.exprField("subject", x.subject);
                try j.field("path");
                try j.attrpath(x.path);
            },
            .attrs => |x| {
                try j.field("rec");
                try w.writeAll(if (x.rec) "true" else "false");
                try j.field("binds");
                try j.binds(x.binds);
            },
            .list => |r| {
                try j.field("items");
                try j.list(r);
            },
            .lambda => |x| {
                try j.field("arg");
                try j.name(x.arg);
                try j.field("formals");
                try w.writeAll("null");
                try j.lambdaTail(false, x.body);
            },
            .lambda_pattern => |x| {
                const pat = j.a.pattern(x.pattern);
                try j.field("arg");
                if (pat.bind) |b| try j.name(b) else try w.writeAll("null");
                try j.field("formals");
                try w.writeByte('[');
                for (j.a.formalsOf(pat.formals), 0..) |f, k| {
                    if (k > 0) try w.writeByte(',');
                    try j.open("formal", f.span);
                    try j.field("name");
                    try j.name(f.name);
                    try j.field("default");
                    try j.opt(f.default);
                    try w.writeByte('}');
                }
                try w.writeByte(']');
                try j.lambdaTail(pat.ellipsis, x.body);
            },
            .apply => |x| {
                try j.exprField("func", x.func);
                try j.field("args");
                try j.list(x.args);
            },
            .let => |x| {
                try j.field("binds");
                try j.binds(x.binds);
                try j.exprField("body", x.body);
            },
            .with => |x| {
                try j.exprField("scope", x.scope);
                try j.exprField("body", x.body);
            },
            .@"if" => |x| {
                try j.exprField("cond", x.cond);
                try j.exprField("then", x.then);
                try j.exprField("else", x.@"else");
            },
            .assert => |x| {
                try j.exprField("cond", x.cond);
                try j.exprField("body", x.body);
            },
            .unary => |x| {
                try j.opName(if (x.op == .neg) "-" else "!");
                try j.exprField("expr", x.expr);
            },
            .binary => |x| {
                try j.opName(binOpName(x.op));
                try j.exprField("lhs", x.lhs);
                try j.exprField("rhs", x.rhs);
            },
        }
        try w.writeByte('}');
    }
};

/// The JSON of the whole file: one node object
/// (docs/reference/syntax-tree.md).
pub fn writeJson(w: *Writer, a: *const Ast, i: *const Interner) E!void {
    return (Json{ .a = a, .i = i, .w = w }).expr(a.root);
}

/// One line of `iets parse --json`: `{"file":...,"root":...}` and a newline.
pub fn writeJsonLine(w: *Writer, file: []const u8, a: *const Ast, i: *const Interner) E!void {
    try w.writeAll("{\"file\":");
    try text.writeJsonString(w, file);
    try w.writeAll(",\"root\":");
    try writeJson(w, a, i);
    try w.writeAll("}\n");
}

fn floatStr(comptime f: fn (*Writer, f64) E!void, v: f64, buf: []u8) []const u8 {
    var w: Writer = .fixed(buf);
    f(&w, v) catch unreachable;
    return w.buffered();
}

test "floats print like Rust's Debug and like serde_json" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { f64, []const u8, []const u8 }{
        .{ 1.0, "1.0", "1.0" },
        .{ 1500.0, "1500.0", "1500.0" },
        .{ 0.05, "0.05", "0.05" },
        .{ 1.5e-7, "1.5e-7", "1.5e-7" },
        .{ 1e-5, "1e-5", "0.00001" },
        .{ 1e-4, "0.0001", "0.0001" },
        .{ 1e15, "1000000000000000.0", "1000000000000000.0" },
        .{ 1e16, "1e16", "1e+16" },
        .{ 1.25e16, "1.25e16", "1.25e+16" },
        .{ 1.2345678901234569e23, "1.2345678901234569e23", "1.2345678901234569e+23" },
        .{ 123.456, "123.456", "123.456" },
        .{ -1.5, "-1.5", "-1.5" },
        .{ 0.0, "0.0", "0.0" },
        .{ 3e-308, "3e-308", "3e-308" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], floatStr(writeFloatDebug, c[0], &buf));
        try std.testing.expectEqualStrings(c[2], floatStr(writeFloatJson, c[0], &buf));
    }
}
