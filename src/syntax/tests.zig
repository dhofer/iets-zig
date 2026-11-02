//! Parser tests.

const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const syntax = @import("../syntax.zig");
const Diag = @import("../diag.zig").Diag;
const Interner = syntax.Interner;
const Ast = syntax.Ast;
const lineCol = syntax.lineCol;

const Parsed = struct {
    interner: Interner,
    ast: Ast,

    fn deinit(p: *Parsed) void {
        p.ast.deinit(gpa);
        p.interner.deinit();
    }
};

fn parseOk(src: []const u8) !Parsed {
    var interner: Interner = try .init(gpa);
    errdefer interner.deinit();
    var d: Diag = .init(gpa);
    defer d.deinit();
    var at: u32 = 0;
    const a = syntax.parse(gpa, src, @fromBackingInt(@intCast(0)), &interner, &d, &at) catch |e| {
        std.debug.print("parse of {f} failed: {s}\n", .{ std.zig.fmtString(src), d.message() });
        return e;
    };
    return .{ .interner = interner, .ast = a };
}

fn dumpSrc(src: []const u8) ![]u8 {
    var p = try parseOk(src);
    defer p.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try syntax.dump.writeSexp(&w.writer, &p.ast, &p.interner);
    return w.toOwnedSlice();
}

const Failure = struct {
    msg: []u8,
    at: u32,

    fn deinit(f: Failure) void {
        gpa.free(f.msg);
    }
};

fn parseError(src: []const u8) !Failure {
    var interner: Interner = try .init(gpa);
    defer interner.deinit();
    var d: Diag = .init(gpa);
    defer d.deinit();
    var at: u32 = 0;
    var a = syntax.parse(gpa, src, @fromBackingInt(@intCast(0)), &interner, &d, &at) catch |e| switch (e) {
        error.SyntaxError => return .{ .msg = try gpa.dupe(u8, d.message()), .at = at },
        else => return e,
    };
    defer a.deinit(gpa);
    std.debug.print("expected a parse error for {f}\n", .{std.zig.fmtString(src)});
    return error.TestUnexpectedResult;
}

fn expectDump(src: []const u8, want: []const u8) !void {
    const got = try dumpSrc(src);
    defer gpa.free(got);
    testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("for {f}\n", .{std.zig.fmtString(src)});
        return e;
    };
}

fn expectErrContains(src: []const u8, want: []const u8) !void {
    const f = try parseError(src);
    defer f.deinit();
    if (std.mem.find(u8, f.msg, want) == null) {
        std.debug.print("for {f}: {s} lacks {s}\n", .{ std.zig.fmtString(src), f.msg, want });
        return error.TestUnexpectedResult;
    }
}

/// The value of a plain-string dump, still quoted.
fn expectStr(src: []const u8, want: []const u8) !void {
    const d = try dumpSrc(src);
    defer gpa.free(d);
    if (!std.mem.startsWith(u8, d, "(str ") or !std.mem.endsWith(u8, d, ")")) {
        std.debug.print("not a plain string dump: {s}\n", .{d});
        return error.TestUnexpectedResult;
    }
    testing.expectEqualStrings(want, d[5 .. d.len - 1]) catch |e| {
        std.debug.print("for {f}\n", .{std.zig.fmtString(src)});
        return e;
    };
}

test "indented string stripping" {
    try expectStr("''\n  foo\n   bar\n  ''", "\"foo\\n bar\\n\"");
    try expectStr("''\n    a\n  $\n  b''", "\"  a\\n$\\nb\"");
    try expectStr("''\n  a'$''", "\"a'$\"");
    try expectStr("''   \n  x''", "\"x\"");
    try expectStr("''  a\n  '''\n  ''", "\"a\\n''\\n\"");
    try expectStr("''\n  foo''\\\n  bar''", "\"foo\\nbar\"");
    try expectStr("''\n  a\n\n  b\n''", "\"a\\n\\nb\\n\"");
    try expectStr("''''", "\"\"");
    try expectStr("''\n  ''", "\"\"");
    try expectStr("'' a$ ''", "\"a$ \"");
    try expectStr("''$${x}''", "\"$${x}\"");
    try expectStr("''''\\n''", "\"\\n\"");
    try expectStr("''  a\r\n  b''", "\"a\\r\\nb\"");
    try expectDump("''  ${\"a\"}\n  x''", "(str (interp (str \"a\")) \"\\nx\")");
    try expectDump("''\n  x = ${x};\n    y\n''", "(str \"x = \" (interp x) \";\\n  y\\n\")");
}

test "string escapes and interpolation" {
    try expectStr("\"a\\nb\\tc\\\\d\\$e\\\"f\\qg\"", "\"a\\nb\\tc\\\\d$e\\\"fqg\"");
    try expectStr("\"a\r\nb\rc\"", "\"a\\nb\\nc\"");
    try expectStr("\"$${x}\"", "\"$${x}\"");
    try expectStr("\"$$\"", "\"$$\"");
    try expectStr("\"$\"", "\"$\"");
    try expectStr("\"\"", "\"\"");
    try expectStr("\"$\\n\"", "\"$\\n\"");
    try expectDump("\"a${b}c\"", "(str \"a\" (interp b) \"c\")");
    try expectDump("\"${b}\"", "(str (interp b))");
    try expectDump("\"${\"x\"}\"", "(str (interp (str \"x\")))");
    try expectDump("\"a${ \"b${c}\" }\"", "(str \"a\" (interp (str \"b\" (interp c))))");
    try expectDump("x:y", "(str \"x:y\")");
    try expectDump("https://a.b/c?d=e", "(str \"https://a.b/c?d=e\")");
    try expectErrContains("\"abc", "end of file");
    try expectErrContains("a 1\"$", "end of file");
}

test "paths" {
    try expectDump("./foo", "(path rel \"./foo\")");
    try expectDump("../foo/bar.nix", "(path rel \"../foo/bar.nix\")");
    try expectDump("/foo", "(path abs \"/foo\")");
    try expectDump("~/foo", "(path home \"/foo\")");
    try expectDump("<nixpkgs/lib>", "(path search \"nixpkgs/lib\")");
    try expectDump("./foo/${x}", "(path rel \"./foo/\" (interp x))");
    try expectDump("./${x}/y${z}.nix", "(path rel \"./\" (interp x) \"/y\" (interp z) \".nix\")");
    try expectDump("~/${x}", "(path home \"/\" (interp x))");
    try expectDump("/${x}", "(path abs \"/\" (interp x))");
    try expectDump("x/${a}b", "(path rel \"x/\" (interp a) \"b\")");
    try expectDump("2/3", "(path rel \"2/3\")");
    try expectDump("a / b", "(/ a b)");
    try expectDump("a // b", "(// a b)");
    try expectErrContains("a < b > c", "unexpected '>'");
    try expectDump("a <b> c", "(apply a (path search \"b\") c)");
    try expectErrContains("./foo/", "trailing slash");
    try expectErrContains("/foo/${x}/", "trailing slash");
}

test "numbers" {
    try expectDump("007", "7");
    try expectDump("1.", "1.0");
    try expectDump(".5", "0.5");
    try expectDump("1.5e3", "1500.0");
    try expectDump("0.5e-1", "0.05");
    try expectDump("-1", "-1");
    try expectDump("- 1", "-1");
    try expectDump("- - 1", "1");
    try expectDump("-1.5", "-1.5");
    try expectDump("-0.0", "0.0");
    try expectDump("-x", "(neg x)");
    try expectDump("x.5", "(apply x 0.5)");
    try expectDump("1e3", "(apply 1 e3)");
    try expectDump("9223372036854775807", "9223372036854775807");
    try expectErrContains("9223372036854775808", "invalid integer");
    try expectErrContains("-9223372036854775808", "invalid integer");
}

test "operator precedence" {
    const cases = [_][2][]const u8{
        .{ "a -> b -> c", "(-> a (-> b c))" },
        .{ "a || b && c", "(|| a (&& b c))" },
        .{ "a && b || c", "(|| (&& a b) c)" },
        .{ "a == b && c", "(&& (== a b) c)" },
        .{ "a < b == c", "(== (< a b) c)" },
        .{ "a // b // c", "(// a (// b c))" },
        .{ "a // b + c", "(// a (+ b c))" },
        .{ "!a + b", "(! (+ a b))" },
        .{ "!a // b", "(// (! a) b)" },
        .{ "!a == b", "(== (! a) b)" },
        .{ "-a + b", "(+ (neg a) b)" },
        .{ "-a * b", "(* (neg a) b)" },
        .{ "a - b - c", "(- (- a b) c)" },
        .{ "a + b * c", "(+ a (* b c))" },
        .{ "a * b ++ c", "(* a (++ b c))" },
        .{ "a ++ b ++ c", "(++ a (++ b c))" },
        .{ "a ++ b ? c", "(++ a (? b (c)))" },
        .{ "!a ? b", "(! (? a (b)))" },
        .{ "-a ? b", "(? (neg a) (b))" },
        .{ "a ? b.c", "(? a (b c))" },
        .{ "a ? b == c", "(== (? a (b)) c)" },
        .{ "f a b", "(apply f a b)" },
        .{ "(f a) b", "(apply f a b)" },
        .{ "f a.b c", "(apply f (select a (b)) c)" },
        .{ "-f a", "(neg (apply f a))" },
        .{ "f -a", "(- f a)" },
        .{ "a.b or c d", "(apply (select a (b) (or c)) d)" },
        .{ "f or x", "(apply f or x)" },
        .{ "a |> f |> g", "(apply g (apply f a))" },
        .{ "g <| f <| a", "(apply g (apply f a))" },
        .{ "a |> f x", "(apply f x a)" },
        .{ "if a then b else c: d", "(if a b (lambda c d))" },
        .{ "with a; b: c", "(with a (lambda b c))" },
        .{ "assert a; b", "(assert a b)" },
        .{ "a ? b ? c", "(? (? a (b)) (c))" },
    };
    for (cases) |c| try expectDump(c[0], c[1]);
    try expectErrContains("a == b == c", "unexpected '=='");
    try expectErrContains("a < b < c", "unexpected '<'");
    try expectErrContains("a |> f <| b", "unexpected");
    try expectErrContains("[ -1 ]", "unexpected '-'");
    try expectErrContains("1 != != 2", "unexpected '!='");
}

test "attrs and bindings" {
    try expectDump("{ }", "(attrs)");
    try expectDump("rec { a = 1; }", "(rec-attrs (= (a) 1))");
    try expectDump("{ a.b.\"c\".${d} = 1; }", "(attrs (= (a b c (dyn d)) 1))");
    try expectDump("{ ${\"x\"} = 1; }", "(attrs (= (x) 1))");
    try expectDump("{ \"a${b}\" = 1; }", "(attrs (= ((dyn (str \"a\" (interp b)))) 1))");
    try expectDump("{ or = 1; }.or", "(select (attrs (= (or) 1)) (or))");
    try expectDump("{ inherit a b; inherit (c) d \"e\"; }", "(attrs (inherit a b) (inherit (from c) d e))");
    try expectDump("let a = 1; in a", "(let ( (= (a) 1)) a)");
    try expectDump("let { body = 1; }", "(select (rec-attrs (= (body) 1)) (body))");
    try expectDump("let a.${b} = 1; in a", "(let ( (= (a (dyn b)) 1)) a)");
    try expectDump("{ a = 1; b = { c = 2; }; b.d = 3; }", "(attrs (= (a) 1) (= (b) (attrs (= (c) 2))) (= (b d) 3))");
    try expectErrContains("let ${b} = 1; in a", "dynamic attributes not allowed in let");
    try expectErrContains("{ inherit ${b}; }", "dynamic attributes not allowed in inherit");
    try expectErrContains("{ a = 1; a = 2; }", "attribute 'a' already defined");
    try expectErrContains("{ a.b = 1; a.b = 2; }", "attribute 'a.b' already defined");
    try expectErrContains("{ a.b = 1; a = { b = 2; }; }", "attribute 'a.b' already defined");
    try expectErrContains("{ a = { b = 2; }; a.b = 1; }", "attribute 'a.b' already defined");
    try expectErrContains("{ inherit a; a = 1; }", "already defined");
    try expectErrContains("{ inherit a a; }", "already defined");
    try expectErrContains("{ a = 1; inherit (x) a; }", "already defined");
    try expectErrContains("{ a.b = 1; inherit a; }", "already defined");
    try expectErrContains("{ a = 1; }; }", "expecting end of file");
    try expectErrContains("{ a ... }", "expecting '.' or '='");
    try expectErrContains("{ 1 = x; }", "unexpected integer");
}

test "many bindings use the indexed duplicate check" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "{ ");
    for (0..40) |k| try src.print(gpa, "a{d}.x = 1; ", .{k});
    try src.appendSlice(gpa, "a7.x = 2; }");
    try expectErrContains(src.items, "attribute 'a7.x' already defined at 1:");
}

test "lambdas" {
    try expectDump("x: x", "(lambda x x)");
    try expectDump("{ }: x", "(lambda {} x)");
    try expectDump("{ ... }: x", "(lambda {...} x)");
    try expectDump("{ a, b ? 1, ... }: a", "(lambda {a, b ? 1, ...} a)");
    try expectDump("{ a, }: a", "(lambda {a} a)");
    try expectDump("x@{ a }: a", "(lambda {a} @ x a)");
    try expectDump("{ a }@x: a", "(lambda {a} @ x a)");
    try expectDump("x: y: z", "(lambda x (lambda y z))");
    try expectErrContains("{ ..., a }: a", "expecting '}'");
    try expectErrContains("{ a, a }: a", "duplicate formal function argument 'a'");
    try expectErrContains("a@{ a }: a", "duplicate formal function argument 'a'");
    try expectErrContains("{ a b }: a", "expecting '.' or '='");
}

test "comments and misc" {
    try expectDump("# c\n1 /* x */ # y\n", "1");
    try expectDump("/** doc */ x: x", "(lambda x x)");
    try expectDump("{ x = # c\ry; }", "(attrs (= (x) y))");
    try expectDump("[ a b.c (d e) ]", "(list a (select b (c)) (apply d e))");
    try expectDump("__curPos", "__curPos");
    try expectErrContains("é", "invalid token");
    try expectErrContains("(", "end of file");
    try expectErrContains("a.'b", "invalid token");
    try expectErrContains("", "end of file");
}

test "an error position at a lone CR" {
    const f = try parseError("l\r =");
    defer f.deinit();
    try testing.expectEqual(.{ 2, 2 }, lineCol("l\r =", f.at));
}

fn parsedAllows(src: []const u8) !Parsed {
    return parseOk(src);
}

test "allow comments" {
    // own line: the next non-blank, non-comment line; trailing: its own line
    {
        var p = try parsedAllows("# iets: allow fod\n\n# plain\n  with a; [\n  (with b; x) # iets: allow fod, ifd\n]\n");
        defer p.deinit();
        const l = p.ast.allows.items;
        try testing.expectEqual(2, l.len);
        try testing.expectEqual(syntax.Span{ .start = 27, .end = 38 }, l[0].line);
        try testing.expectEqual(syntax.Span{ .start = 39, .end = 75 }, l[1].line);
        try testing.expectEqual(syntax.Span{ .start = 7, .end = 17 }, l[0].text);
    }
    // a comment before the third token of lookahead is noted once
    {
        var p = try parsedAllows("{\n# iets: allow fod\nb = with x; y; }");
        defer p.deinit();
        try testing.expectEqual(1, p.ast.allows.items.len);
        try testing.expectEqual(syntax.Span{ .start = 20, .end = 36 }, p.ast.allows.items[0].line);
    }
    // an own-line comment at the end of the file covers nothing
    {
        var p = try parsedAllows("1\n# iets: allow fod\n");
        defer p.deinit();
        try testing.expectEqual(0, p.ast.allows.items.len);
    }
    // other comments are not noted
    {
        var p = try parsedAllows("# iets allow fod\n#iets: allow fod\n1");
        defer p.deinit();
        try testing.expectEqual(0, p.ast.allows.items.len);
    }
}

test "url literals are noted" {
    var p = try parseOk("[ https://a.b x:y ]");
    defer p.deinit();
    try testing.expectEqual(2, p.ast.notes.items.len);
}

test "spans cover tokens" {
    var p = try parseOk("  f a.b  ");
    defer p.deinit();
    try testing.expectEqual(syntax.Span{ .start = 2, .end = 7 }, p.ast.span(p.ast.root));
}

test "nul in string literals" {
    const cases = [_]struct { []const u8, []const u8, [2]u32 }{
        .{ "\"foo\x00bar\"", "foo␀bar", .{ 1, 2 } },
        .{ "''\n  foo\n  \x00\n  bar\n''", "  foo\n  ␀\n  bar\n", .{ 2, 1 } },
        .{ "let x = \"q\"; in \"a${x}\x00b\"", "␀b", .{ 1, 23 } },
        .{ "''x${\"y\"}\x00z''", "␀z", .{ 1, 10 } },
        .{ "let y = \"a\x00b\"; in 1", "a␀b", .{ 1, 10 } },
        .{ "{ \"a\x00b\" = 1; }", "a␀b", .{ 1, 4 } },
        .{ "\"a\\n\x00b\"", "a\n␀b", .{ 1, 2 } },
        .{ "\"a\r\n\x00b\"", "a\n␀b", .{ 1, 2 } },
        .{ "\"$\x00\"", "$␀", .{ 1, 2 } },
        // before the end of the file that the string runs into
        .{ "\"foo\x00bar", "foo␀bar", .{ 1, 2 } },
    };
    for (cases) |c| {
        const f = try parseError(c[0]);
        defer f.deinit();
        const want = try std.fmt.allocPrint(gpa, "input string '{s}' cannot be represented as Nix string because it contains null bytes", .{c[1]});
        defer gpa.free(want);
        try testing.expectEqualStrings(want, f.msg);
        const l, const col = lineCol(c[0], f.at);
        try testing.expectEqual(c[2], [2]u32{ l, col });
    }
    // escaped NULs pass, as in Nix
    gpa.free(try dumpSrc("\"a\\\x00b\""));
    gpa.free(try dumpSrc("''a''\\\x00b''"));
}

fn expectErrAt(src: []const u8, msg: ?[]const u8, pos: [2]u32) !void {
    const f = try parseError(src);
    defer f.deinit();
    if (msg) |m| if (std.mem.find(u8, f.msg, m) == null) {
        std.debug.print("for {f}: {s}\n", .{ std.zig.fmtString(src), f.msg });
        return error.TestUnexpectedResult;
    };
    const l, const c = lineCol(src, f.at);
    testing.expectEqual(pos, [2]u32{ l, c }) catch |e| {
        std.debug.print("for {f}: {s}\n", .{ std.zig.fmtString(src), f.msg });
        return e;
    };
}

test "end of file inside a path is at its last token" {
    const cases = [_]struct { []const u8, [2]u32 }{
        .{ "[ ./a", .{ 1, 3 } },
        .{ "[ ~/a", .{ 1, 3 } },
        .{ "[ ./a${b}", .{ 1, 9 } },
        .{ "[ ./a${b}c", .{ 1, 10 } },
        .{ "( ./a", .{ 1, 3 } },
        .{ "/a/", .{ 1, 1 } },
        .{ "/a/${b}/", .{ 1, 8 } },
        .{ "[ ./a/${b}/", .{ 1, 11 } },
        // a byte after the path is a token of its own, and the end is there
        .{ "[ ./a ", .{ 1, 7 } },
        .{ "./a/ ", .{ 1, 5 } },
    };
    for (cases) |c| try expectErrAt(c[0], null, c[1]);
}

test "the error reported is the one Nix meets first" {
    const cases = [_]struct { []const u8, []const u8, [2]u32 }{
        .{ "/a//0", "unexpected end of path", .{ 1, 1 } },
        .{ "/a//0 ", "unexpected end of path", .{ 1, 4 } },
        .{ "x/a//0//1", "unexpected string", .{ 1, 8 } },
        .{ "{ a, a }: (", "unexpected end of file", .{ 1, 12 } },
        .{ "{ x } @ x: 1", "duplicate formal function argument 'x'", .{ 1, 1 } },
        .{ "{ a = 1; a = 2; b = }", "attribute 'a' already defined at 1:3", .{ 1, 10 } },
        .{ "let a.b = 1; a = 2; in", "attribute 'a' already defined at 1:5", .{ 1, 14 } },
        .{ "let ${a} = 1; in 1", "dynamic attributes not allowed in let", .{ 1, 1 } },
        .{ "let ${a} = 1; in (", "unexpected end of file", .{ 1, 19 } },
        .{ "{l,l}:v|>l<|", "duplicate formal function argument 'l'", .{ 1, 4 } },
        .{ "(a <| b |> c)", "unexpected '|>', expecting ')'", .{ 1, 9 } },
        .{ "let x = a |> b <| c; in x", "unexpected '<|', expecting ';'", .{ 1, 16 } },
    };
    for (cases) |c| try expectErrAt(c[0], c[1], c[2]);
}

test "an interpolated name is static when Nix has one string node" {
    try expectDump("r.${''${\"t\"}''}", "(select r (t))");
    try expectDump("r.${'' ${\"t\"}''}", "(select r (t))");
    try expectDump("r.${'''''t''}", "(select r ((dyn (str \"''t\"))))");
    try expectDump("rec { ${''${\"a\"}''} = 1; b = a; }", "(rec-attrs (= (a) 1) (= (b) a))");
}

fn jsonOf(src: []const u8) ![]u8 {
    var p = try parseOk(src);
    defer p.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try syntax.dump.writeJson(&w.writer, &p.ast, &p.interner);
    return w.toOwnedSlice();
}

fn walk(v: std.json.Value, src: []const u8, nodes: *usize) !void {
    switch (v) {
        .object => |o| {
            if (o.get("kind")) |kind| {
                const start: usize = @intCast(o.get("start").?.integer);
                const end: usize = @intCast(o.get("end").?.integer);
                try testing.expect(start < end and end <= src.len);
                if (std.mem.eql(u8, kind.string, "var") or std.mem.eql(u8, kind.string, "name"))
                    try testing.expectEqualStrings(src[start..end], o.get("name").?.string);
                nodes.* += 1;
            }
            for (o.values()) |x| try walk(x, src, nodes);
        },
        .array => |a| for (a.items) |x| try walk(x, src, nodes),
        else => {},
    }
}

test "json gives every node its kind and span" {
    {
        const j = try jsonOf("a: a.b or 1");
        defer gpa.free(j);
        try testing.expectEqualStrings(
            \\{"kind":"lambda","start":0,"end":11,"arg":"a","formals":null,"ellipsis":false,"body":{"kind":"select","start":3,"end":11,"subject":{"kind":"var","start":3,"end":4,"name":"a"},"path":["b"],"default":{"kind":"int","start":10,"end":11,"value":1}}}
        , j);
    }
    const src = "{ x ? 1.5, ... }@s: with s; [ ./p \"t${x}\" ] // { inherit (s) y; \"k\".${x} = !x; }";
    const j = try jsonOf(src);
    defer gpa.free(j);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, j, .{});
    defer parsed.deinit();
    var nodes: usize = 0;
    try walk(parsed.value, src, &nodes);
    try testing.expectEqual(18, nodes);
    const k = try jsonOf("\"\\\"\u{e9}\"");
    defer gpa.free(k);
    try testing.expectEqualStrings(
        \\{"kind":"string","start":0,"end":6,"parts":["\"é"]}
    , k);
}

/// Scope errors that Nix reports from its resolver: `compile` reports them.
const not_parser_errors = [_][]const u8{
    "parse-fail-undef-var.nix",
    "parse-fail-regression-20060610.nix",
};

/// Nix rejects these in its parser. The corpus files them under eval-fail
/// because `nix-instantiate --eval` is what fails.
const parser_errors = [_][]const u8{
    "eval-fail-dynamic-attrs-inherit.nix",
    "eval-fail-dynamic-attrs-inherit-2.nix",
    "eval-fail-dynamic-attrs-let.nix",
    "eval-fail-dynamic-attrs-let-2.nix",
    "eval-fail-dynamic-attrs-let-3.nix",
    "eval-fail-path-slash.nix",
    "eval-fail-string-nul-1.nix",
    "eval-fail-string-nul-2.nix",
};

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

test "lang corpus parses or fails as Nix does" {
    const io = testing.io;
    var dir = std.Io.Dir.cwd().openDir(io, "../iets/tests/lang", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    var interner: Interner = try .init(gpa);
    defer interner.deinit();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".nix")) continue;
        const src = try dir.readFileAlloc(io, e.name, gpa, .unlimited);
        defer gpa.free(src);
        const must_fail = (std.mem.startsWith(u8, e.name, "parse-fail-") and !contains(&not_parser_errors, e.name)) or
            contains(&parser_errors, e.name);
        var d: Diag = .init(gpa);
        defer d.deinit();
        var at: u32 = 0;
        if (syntax.parse(gpa, src, @fromBackingInt(@intCast(0)), &interner, &d, &at)) |a| {
            var x = a;
            x.deinit(gpa);
            if (must_fail) {
                std.debug.print("{s}: parsed but should fail\n", .{e.name});
                return error.TestUnexpectedResult;
            }
        } else |err| {
            if (err != error.SyntaxError) return err;
            if (!must_fail) {
                const l, const c = lineCol(src, at);
                std.debug.print("{s}:{d}:{d}: {s}\n", .{ e.name, l, c, d.message() });
                return error.TestUnexpectedResult;
            }
        }
        n += 1;
    }
    try testing.expect(n > 100);
}

fn deepNestingCases() void {
    deepNestingCasesFallible() catch |e| {
        std.debug.print("deep nesting: {t}\n", .{e});
        deep_failed = true;
    };
}

var deep_failed = false;

fn deepNestingCasesFallible() !void {
    const shapes = [_][3][]const u8{
        .{ "(", "1", ")" },
        .{ "[", "", "]" },
        .{ "{a=", "1", ";}" },
        .{ "x: ", "1", "" },
        .{ "-", "1", "" },
        .{ "!", "true", "" },
    };
    for (shapes) |s| {
        const n = 60_000;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        for (0..n) |_| try src.appendSlice(gpa, s[0]);
        try src.appendSlice(gpa, s[1]);
        for (0..n) |_| try src.appendSlice(gpa, s[2]);
        const f = try parseError(src.items);
        defer f.deinit();
        try testing.expectEqualStrings("stack overflow (possible infinite recursion)", f.msg);
    }
}

// A deeply nested file must give an error, never a stack overflow. The
// parse runs on a big stack, as the evaluator's thread would give it.
test "deep nesting ends with an error" {
    const t = try std.Thread.spawn(.{ .stack_size = 1 << 30 }, deepNestingCases, .{});
    t.join();
    try testing.expect(!deep_failed);
}
