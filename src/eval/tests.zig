//! Evaluations checked against the printed result, for the evaluator's own
//! shapes that the Nix language suite does not single out.

const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const Files = @import("Files.zig");
const Interner = @import("../syntax/symbol.zig").Interner;
const builtins = @import("../builtins.zig");
const import_ = @import("import.zig");
const print = @import("print.zig");
const value = @import("../runtime/value.zig");
const Value = value.Value;
const ir_cache = @import("../ir_cache.zig");

/// An evaluator with its tables, set up as `iets eval` does.
const Setup = struct {
    interner: Interner,
    files: Files,
    shared: Evaluator.Shared = .{},
    local: Evaluator.Local,
    ev: Evaluator,

    /// `names` are interned first, so symbol ids differ from a plain run.
    fn init(s: *Setup, names: []const []const u8) !void {
        return s.initWith(names, .{});
    }

    fn initWith(s: *Setup, names: []const []const u8, config: Evaluator.Config) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        s.interner = try .init(gpa);
        for (names) |n| _ = try s.interner.intern(n);
        s.files = .init(gpa, io);
        s.shared = .{};
        s.local = .init(gpa);
        value.flat_arena = &s.local.arena;
        s.ev = try .init(gpa, io, &s.local, &s.interner, &s.files, &s.shared, config);
        try builtins.install(&s.ev);
    }

    fn deinit(s: *Setup) void {
        s.ev.deinit();
        value.flat_arena = null;
        s.local.deinit();
        s.shared.deinit(std.testing.allocator);
        s.files.deinit();
        s.interner.deinit();
    }

    /// `v` forced deeply and printed as `nix-instantiate --eval` does.
    fn expectPrints(s: *Setup, v: Value, want: []const u8) !void {
        const r = try s.ev.forceDeep(v);
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try print.writeAmbiguous(&s.ev, &out.writer, r);
        try std.testing.expectEqualStrings(want, out.written());
    }
};

/// `src` evaluated strictly and printed.
fn expectEval(src: []const u8, want: []const u8) !void {
    var s: Setup = undefined;
    try s.init(&.{});
    defer s.deinit();
    try s.expectPrints(try import_.evalString(&s.ev, src), want);
}

test "curried lambdas share one frame, and partial applications copy it" {
    try expectEval(
        \\let f = a: b: c: [ a b c ]; g = f 1; h = g 2;
        \\in [ (g 2 3) (g 4 5) (h 6) (h 7) (f 7 8 9) (map (f 10 20) [ 1 2 ]) ]
    , "[ [ 1 2 3 ] [ 1 4 5 ] [ 1 2 6 ] [ 1 2 7 ] [ 7 8 9 ] [ [ 10 20 1 ] [ 10 20 2 ] ] ]");
}

test "a let body extends its lambda's frame" {
    try expectEval(
        \\let
        \\  k = x: let y = x + 1; inherit x; z = y * 2; in { inherit x y z; w = q: x + y + q; };
        \\  p = { a, b ? a + 1, ... }@args: let s = a + b; in t: [ s t args.a ];
        \\  q = x: { y ? x }: let r = y; in z: [ x y r z ];
        \\  e = { }: x: x;
        \\  n = a: (b: c: a + b + c) 5;
        \\in [ (k 1).z ((k 5).w 1) (p { a = 1; } 2) (q 1 { } 2) ((q 1) { y = 5; } 3) (e { } 4) (map (n 1) [ 1 2 ]) ]
    , "[ 4 12 [ 3 2 1 ] [ 1 1 1 2 ] [ 1 5 5 3 ] 4 [ 7 8 ] ]");
}

test "an IR cache entry loads where symbol ids differ, re-sorting every frame" {
    const src =
        \\let
        \\  zeta = 1; alpha = zeta + 1; mid = { c = alpha; b = zeta; a = mid2; };
        \\  mid2 = rec { y = x + 1; x = 10; inherit zeta; inherit (mid) b; };
        \\  f = { q, p ? q + 1, ... }@args: let s = p + q; r = s * 2; in t: [ s r t args.q ];
        \\  g = w: let v = w; u = v; in u;
        \\in [ zeta alpha mid mid2 (f { q = 1; } 5) (g 3) (with mid; [ a.y c ]) ({ inherit (mid) c b; }) ]
    ;
    const want = "[ 1 2 { a = { b = 1; x = 10; y = 11; zeta = 1; }; b = 1; c = 2; } «repeated» [ 3 6 5 1 ] 3 [ 11 2 ] { b = 1; c = 2; } ]";
    var a: Setup = undefined;
    try a.init(&.{});
    defer a.deinit();
    const code = try import_.compileSource(&a.ev, "/t.nix", src, "/", null);
    const entry = (try ir_cache.serialize(&a.ev, code, a.files.files.items[a.files.files.items.len - 1].base, &.{}, &.{})).?;
    defer std.testing.allocator.free(entry);
    try a.expectPrints(try a.ev.eval(a.ev.root_env, code), want);

    // The names in reverse order of their first use, and some more.
    var b: Setup = undefined;
    try b.init(&.{ "args", "t", "r", "s", "p", "q", "u", "v", "w", "g", "f", "x", "y", "c", "b", "a", "mid2", "mid", "alpha", "zeta" });
    defer b.deinit();
    const file = try b.files.add("/t.nix", src);
    var loaded = (try ir_cache.deserialize(&b.ev, entry, file.base, src.len)).?;
    defer loaded.deinit(std.testing.allocator);
    try b.expectPrints(try b.ev.eval(b.ev.root_env, loaded.code), want);

    // A damaged entry is refused, never loaded.
    var bad = try std.testing.allocator.dupe(u8, entry);
    defer std.testing.allocator.free(bad);
    for (0..bad.len) |i| {
        const saved = bad[i];
        bad[i] ^= 0x5a;
        if (try ir_cache.deserialize(&b.ev, bad, file.base, src.len)) |l| {
            var x = l;
            x.deinit(std.testing.allocator);
        }
        bad[i] = saved;
    }
}

// Whole-expression tests: what a source prints, or the error it fails with.

/// The printed value of `src`, or the message of its error, in `buf`.
const Outcome = union(enum) { ok: []const u8, err: []const u8 };

fn evalOutcome(s: *Setup, src: []const u8, a: std.mem.Allocator) !Outcome {
    const v = import_.evalString(&s.ev, src) catch |e| return failed(s, e, a);
    const r = s.ev.forceDeep(v) catch |e| return failed(s, e, a);
    var out: std.Io.Writer.Allocating = .init(a);
    try print.writeAmbiguous(&s.ev, &out.writer, r);
    return .{ .ok = try out.toOwnedSlice() };
}

fn failed(s: *Setup, e: anyerror, a: std.mem.Allocator) !Outcome {
    if (e != error.EvalFailed) return e;
    return .{ .err = try a.dupe(u8, s.ev.failure.?.msg) };
}

fn evalWith(config: Evaluator.Config, src: []const u8, a: std.mem.Allocator) !Outcome {
    var s: Setup = undefined;
    try s.initWith(&.{}, config);
    defer s.deinit();
    return evalOutcome(&s, src, a);
}

fn expectErr(src: []const u8, want: []const u8) !void {
    return expectErrWith(.{}, src, want);
}

fn expectErrWith(config: Evaluator.Config, src: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    switch (try evalWith(config, src, arena.allocator())) {
        .ok => |o| {
            std.debug.print("{s}: expected an error, got {s}\n", .{ src, o });
            return error.TestExpectedError;
        },
        .err => |m| try std.testing.expectEqualStrings(want, m),
    }
}

fn expectErrPrefix(src: []const u8, prefix: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    switch (try evalWith(.{}, src, arena.allocator())) {
        .ok => return error.TestExpectedError,
        .err => |m| if (!std.mem.startsWith(u8, m, prefix)) {
            std.debug.print("{s}: {s}\n", .{ src, m });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectPure(src: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    switch (try evalWith(.{ .pure = true }, src, arena.allocator())) {
        .ok => |o| try std.testing.expectEqualStrings(want, o),
        .err => |m| {
            std.debug.print("{s}: {s}\n", .{ src, m });
            return error.TestUnexpectedResult;
        },
    }
}

fn evalStr(src: []const u8) ![]const u8 {
    var s: Setup = undefined;
    try s.init(&.{});
    defer s.deinit();
    switch (try evalOutcome(&s, src, std.testing.allocator)) {
        .ok => |o| return o,
        .err => |m| {
            defer std.testing.allocator.free(m);
            std.debug.print("{s}: {s}\n", .{ src, m });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectEvalEach(cases: []const [2][]const u8) !void {
    for (cases) |c| expectEval(c[0], c[1]) catch |e| {
        std.debug.print("case: {s}\n", .{c[0]});
        return e;
    };
}

test "intersectAttrs matches a filter" {
    // "p i j" is the set p<k> = "<p>-<i>-<k>" for k in i..j, so `//` both
    // overlaps and shadows; sets of 8 or more stay unions
    const cases = [_][2][]const u8{
        .{ "a 0 30", "a 5 40" },
        .{ "a 3 6", "a 0 20 // b 0 400 // a 10 30 // c 0 50" },
        .{ "a 0 20 // b 0 400 // a 10 30 // c 0 50", "a 3 6 // b 7 9" },
        .{ "a 0 40 // b 0 40 // c 5 9", "b 20 60 // a 30 35 // c 0 300" },
        .{ "x 0 500", "a 0 20 // b 0 400 // c 0 50" },
    };
    const gpa = std.testing.allocator;
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var sets: [2][]const u8 = undefined;
        for (c, &sets) |spec, *out| {
            var w: std.Io.Writer.Allocating = .init(a);
            var parts = std.mem.splitSequence(u8, spec, " // ");
            var first = true;
            while (parts.next()) |part| {
                var f = std.mem.splitScalar(u8, part, ' ');
                const p = f.next().?;
                const i = f.next().?;
                const j = f.next().?;
                if (!first) try w.writer.writeAll(" // ");
                first = false;
                try w.writer.print("(builtins.listToAttrs (builtins.genList (k: {{ name = \"{s}${{toString (k + {s})}}\"; value = \"{s}-{s}-${{toString k}}\"; }}) ({s} - {s})))", .{ p, i, p, i, j, i });
            }
            out.* = w.written();
        }
        const src = try std.fmt.allocPrint(a, "let l = {s}; r = {s}; want = builtins.listToAttrs (map (n: {{ name = n; value = r.${{n}}; }}) (builtins.filter (n: l ? ${{n}}) (builtins.attrNames r))); got = builtins.intersectAttrs l r; in [ (got == want) (builtins.length (builtins.attrNames got)) ]", .{ sets[0], sets[1] });
        const out = try evalStr(src);
        defer gpa.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "[ true "));
    }
}

test "lambda params read or ignored" {
    try expectEvalEach(&.{
        .{ "(x: 1) (throw \"never\")", "1" },
        .{ "(a: _: b: [ a b ]) 1 2 3", "[ 1 3 ]" },
        .{ "let f = a: _: a; in f 1 2", "1" },
        .{ "(_: let a = 1; b = a; in b) 0", "1" },
        .{ "with { y = 5; }; (x: y) 0", "5" },
        .{ "(x: { inherit x; }) 1", "{ x = 1; }" },
        .{ "(x: \"${x}\") \"s\"", "\"s\"" },
        .{ "(__findFile: <p>) (_: _: \"found\")", "\"found\"" },
        .{ "(a: b: c: [ a b c ]) 1 2 3", "[ 1 2 3 ]" },
        .{ "let f = a: b: c: [ a b c ]; g = f 1; h = g 2; in [ (h 3) (h 4) (g 5 6) ]", "[ [ 1 2 3 ] [ 1 2 4 ] [ 1 5 6 ] ]" },
        .{ "(a: a: a) 1 2", "2" },
        .{ "(x: let x = 2; y = x; in y) 1", "2" },
        .{ "(x: let y = x + 1; in [ x y ]) 1", "[ 1 2 ]" },
        .{ "(x: let inherit x; in x) 1", "1" },
        .{ "(x: let inherit (x) a; in a) { a = 1; }", "1" },
        .{ "let y = 1; in ({ a ? y }: let y = 2; in a) { }", "1" },
        .{ "({ a }: { b }: let c = a + b; in c) { a = 1; } { b = 2; }", "3" },
        .{ "({ }: b: b) { } 1", "1" },
        .{ "let f = a: b: (c: [ a b c ]); in (f 1 2) 3", "[ 1 2 3 ]" },
        .{ "builtins.mapAttrs (n: v: n + v) { a = \"x\"; }", "{ a = \"ax\"; }" },
    });
}

// `[ ]` and `{ }` compile to one value per site, which every evaluation
// and every caller shares.
test "empty literals" {
    try expectEvalEach(&.{
        .{ "let f = { a ? [ ] }: a ++ [ 1 ]; in [ (f { }) (f { }) ]", "[ [ 1 ] [ 1 ] ]" },
        .{ "let f = x: { } // x; in [ (f { a = 1; }) (f { b = 2; }) ]", "[ { a = 1; } { b = 2; } ]" },
        .{ "[ ([ ] == [ ]) ({ } == { }) (rec { } == { }) ]", "[ true true true ]" },
        .{ "map builtins.typeOf [ [ ] { } ]", "[ \"list\" \"set\" ]" },
        .{ "let s = { }; in (s.x or [ ]) ++ (s.y or [ 2 ])", "[ 2 ]" },
        .{ "let n = \"a\"; in { ${n} = 1; }", "{ a = 1; }" },
    });
}

test "every empty list and set is one object" {
    var s: Setup = undefined;
    try s.init(&.{});
    defer s.deinit();
    const list = try s.ev.mkList(&.{});
    const attrs = try s.ev.emptyAttrs();
    const made = try s.ev.forceDeep(try import_.evalString(&s.ev, "[ [ ] { } (builtins.filter (x: false) [ 1 ]) (removeAttrs { a = 1; } [ \"a\" ]) ]"));
    const cells = (try s.ev.forceList(made, .none, "")).cells();
    try std.testing.expectEqual(list, try s.ev.mkList(&.{}));
    try std.testing.expectEqual(attrs, try s.ev.emptyAttrs());
    try std.testing.expectEqual(list, cells[0].get());
    try std.testing.expectEqual(list, cells[2].get());
    try std.testing.expectEqual(attrs, cells[1].get());
    try std.testing.expectEqual(attrs, cells[3].get());
}

test "arithmetic and strings" {
    try expectEvalEach(&.{
        .{ "1 + 2 * 3 - 4 / 2", "5" },
        .{ "1.5 + 1", "2.5" },
        .{ "\"a\" + \"b\" + toString 3", "\"ab3\"" },
        .{ "builtins.stringLength \"héllo\"", "6" },
        .{ "-(3 - 5)", "2" },
    });
}

test "laziness and recursion" {
    try expectEvalEach(&.{
        .{ "let x = throw \"no\"; in 1", "1" },
        .{ "let fib = n: if n < 2 then n else fib (n - 1) + fib (n - 2); in fib 15", "610" },
        .{ "rec { a = b + 1; b = 1; }.a", "2" },
    });
    try expectErr("let x = y; y = x; in x", "infinite recursion encountered");
}

test "scoping" {
    try expectEvalEach(&.{
        .{ "let x = 1; in with { x = 2; }; x", "1" },
        .{ "with { x = 2; }; with { x = 3; }; x", "3" },
        .{ "with { map = 1; }; map", "<PRIMOP>" },
        .{ "with { true = 1; }; true", "true" },
        .{ "let f = { a, b ? a + 1, ... } @ args: a + b + args.c; in f { a = 1; c = 10; }", "13" },
        .{ "let inherit (builtins) length; in length [ 1 2 ]", "2" },
        .{ "{ a.b = 1; a.c = 2; a = { d = 3; }; }", "{ a = { b = 1; c = 2; d = 3; }; }" },
    });
    try expectErrPrefix("{ a = 1; a = 2; }", "attribute 'a' already defined");
}

test "attrs and lists" {
    try expectEvalEach(&.{
        .{ "{ b = 2; a = 1; } // { a = 3; }", "{ a = 3; b = 2; }" },
        .{ "[ 1 ] ++ [ 2 3 ]", "[ 1 2 3 ]" },
        .{ "{ a = 1; } ? a", "true" },
        .{ "{ a = 1; }.b or 7", "7" },
        .{ "let s = \"x\"; in { ${s} = 1; \"${s}y\" = 2; }", "{ x = 1; xy = 2; }" },
        .{ "builtins.sort builtins.lessThan [ 3 1 2 ]", "[ 1 2 3 ]" },
        .{ "map (x: x * 2) [ 1 2 ]", "[ 2 4 ]" },
        .{ "builtins.foldl' (a: b: a + b) 0 [ 1 2 3 ]", "6" },
    });
}

test "equality" {
    try expectEvalEach(&.{
        .{ "let f = x: x; in f == f", "false" },
        .{ "let f = x: x; in builtins.elem f [ f ]", "true" },
        .{ "1 == 1.0", "true" },
        .{ "[ 1 { a = \"x\"; } ] == [ 1 { a = \"x\"; } ]", "true" },
        .{ "\"a\" < \"b\" && [ 1 2 ] < [ 1 3 ]", "true" },
    });
}

test "tryEval and errors" {
    try expectEvalEach(&.{
        .{ "(builtins.tryEval (throw \"x\")).success", "false" },
        .{ "(builtins.tryEval (assert false; 1)).success", "false" },
    });
    try expectErr("builtins.tryEval (abort \"x\")", "evaluation aborted with the following error message: 'x'");
    try expectErr("{ a = 1; }.b", "attribute 'b' missing");
}

test "printing" {
    try expectEvalEach(&.{
        .{ "[ (x: x) builtins.map (builtins.map (x: x)) ]", "[ <LAMBDA> <PRIMOP> <PRIMOP-APP> ]" },
        .{ "1.0e10", "1e+10" },
        .{ "0.1 + 0.2", "0.3" },
        .{ "\"a\\n\\\"b\\\" \\${x}\"", "\"a\\n\\\"b\\\" \\${x}\"" },
        .{ "{ \"a b\" = 1; }", "{ \"a b\" = 1; }" },
        .{ "{ \"1\" = 1; \"if\" = 2; a-b = 3; }", "{ \"1\" = 1; a-b = 3; \"if\" = 2; }" },
    });
}

test "the derivation wrapper exists" {
    try expectEvalEach(&.{
        .{ "builtins.isFunction derivation", "true" },
        .{ "builtins.typeOf builtins.derivation", "\"lambda\"" },
    });
}

test "reading a derivation output is unsupported" {
    const drv = "(derivation { name = \"x\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; })";
    for ([_][]const u8{ "import", "scopedImport {}", "builtins.readFile", "builtins.readDir", "builtins.pathExists", "builtins.readFileType", "builtins.hashFile \"sha256\"" }) |f| {
        var s: Setup = undefined;
        try s.init(&.{});
        defer s.deinit();
        const src = try std.fmt.allocPrint(std.testing.allocator, "{s} {s}", .{ f, drv });
        defer std.testing.allocator.free(src);
        const r = import_.evalString(&s.ev, src) catch |e| e;
        const r2 = if (r) |v| s.ev.forceDeep(v) else |e| e;
        try std.testing.expectError(error.EvalFailed, r2);
        try std.testing.expectEqual(.unsupported, s.ev.failure.?.kind);
    }
}

test "fetchMercurial is unsupported" {
    var s: Setup = undefined;
    try s.init(&.{});
    defer s.deinit();
    try std.testing.expectError(error.EvalFailed, import_.evalString(&s.ev, "builtins.fetchMercurial /tmp"));
    try std.testing.expectEqual(.unsupported, s.ev.failure.?.kind);
    try std.testing.expectEqualStrings("builtins.fetchMercurial is not supported", s.ev.failure.?.msg);
    const hint = s.ev.failure.?.hint orelse "";
    try std.testing.expect(std.mem.indexOf(u8, hint, "type = \"hg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "nix-instantiate") != null);
}

// The answers of `nix-instantiate --pure-eval --read-write-mode` (Nix 2.34.8).
test "pure eval answers like nix" {
    try expectPure("builtins ? currentSystem", "false");
    try expectPure("builtins ? currentTime", "false");
    try expectPure("builtins.getEnv \"HOME\"", "\"\"");
    try expectPure("builtins.nixPath", "[ ]");
    try expectPure("builtins.pathExists /etc/hostname", "false");
    try expectPure("builtins.readFile (builtins.toFile \"a\" \"b\")", "\"b\"");
    try expectPure("import (builtins.toFile \"a.nix\" \"1\")", "1");
    const drv = "(derivation { name = \"p\"; builder = \"/bin/sh\"; system = \"x\"; })";
    try expectPure("(import " ++ drv ++ ".drvPath).name", "\"p\"");
    const pure: Evaluator.Config = .{ .pure = true };
    try expectErrWith(pure, "builtins.currentSystem", "attribute 'currentSystem' missing");
    try expectErrWith(pure, "__currentSystem", "undefined variable '__currentSystem'");
    try expectErrWith(pure, "<nixpkgs>", "cannot look up '<nixpkgs>' in pure evaluation mode (use '--impure' to override)");
    try expectErrWith(pure, "builtins.readFile /etc/hostname", "access to absolute path '/etc/hostname' is forbidden in pure evaluation mode (use '--impure' to override)");
    try expectErrWith(pure, "builtins.readFile " ++ drv ++ ".drvPath", "access to absolute path '/nix/store/z4c1kxpa2xx2wq9gyqmmmxfvxl4fcjax-p.drv' is forbidden in pure evaluation mode (use '--impure' to override)");
    try expectErrWith(pure, "builtins.storePath /nix/store/ah3pxz4xa52hd6vhbx17vcsci0b8bmbr-source", "'builtins.storePath' is not allowed in pure evaluation mode");
    try expectErrWith(pure, "builtins.fetchTarball \"https://example.com/x.tar.gz\"", "in pure evaluation mode, 'fetchTarball' requires a 'sha256' argument");
    try expectErrWith(pure, "builtins.fetchTree { type = \"tarball\"; url = \"https://example.com/x.tar.gz\"; }", "in pure evaluation mode, 'fetchTree' doesn't fetch unlocked input 'https://example.com/x.tar.gz'");
    try expectErrWith(pure, "builtins.fetchTree { type = \"github\"; owner = \"o\"; repo = \"r\"; ref = \"main\"; }", "in pure evaluation mode, 'fetchTree' doesn't fetch unlocked input 'github:o/r/main'");
    try expectErrWith(pure, "builtins.fetchTree { type = \"path\"; path = \"/a b\"; lastModified = 3; }", "in pure evaluation mode, 'fetchTree' doesn't fetch unlocked input 'path:/a%20b?lastModified=3'");
    try expectErrWith(pure, "builtins.fetchTree { type = \"gitlab\"; owner = \"o\"; repo = \"r\"; host = \"x.org\"; }", "in pure evaluation mode, 'fetchTree' doesn't fetch unlocked input 'gitlab:o/r?host=x.org'");
    try expectErrWith(pure, "builtins.fetchTree { type = \"file\"; url = \"https://example.com/x\"; narHash = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; }", "an unlocked 'file' input 'https://example.com/x' in pure evaluation mode is not supported");
    try expectErrWith(pure, "builtins.fetchTree { type = \"indirect\"; id = \"nixpkgs\"; }", "an unlocked 'indirect' input 'flake:nixpkgs' in pure evaluation mode is not supported");
    try expectErrWith(pure, "builtins.fetchTree { type = \"sourcehut\"; owner = \"o\"; repo = \"r\"; }", "an unlocked 'sourcehut' input in pure evaluation mode is not supported");
    for ([_][2][]const u8{
        .{ "builtins.fetchGit \"/a b\"", "in pure evaluation mode, 'fetchGit' doesn't fetch unlocked input 'git+file:///a%20b?exportIgnore=1'" },
        .{ "builtins.fetchGit { url = \"https://x.org/a.git\"; ref = \"main\"; }", "in pure evaluation mode, 'fetchGit' doesn't fetch unlocked input 'git+https://x.org/a.git?exportIgnore=1&ref=main'" },
        .{ "builtins.fetchGit { url = \"git+ssh://git@x.org/a\"; submodules = true; shallow = true; }", "in pure evaluation mode, 'fetchGit' doesn't fetch unlocked input 'git+ssh://git@x.org/a?shallow=1&submodules=1'" },
        .{ "builtins.fetchGit \"rel/x\"", "in pure evaluation mode, 'fetchGit' doesn't fetch unlocked input 'git+file:rel/x?exportIgnore=1'" },
        .{ "builtins.fetchGit \"github.com:a/b\"", "SCP-like URL 'github.com:a/b' is not supported; use SSH URL syntax instead (ssh://...)" },
        .{ "builtins.fetchGit { url = \"/a\"; type = \"git\"; }", "unexpected argument 'type'" },
        .{ "builtins.fetchGit { url = \"/a\"; foo = 1; }", "input attribute 'foo' not supported by scheme 'git'" },
        .{ "builtins.fetchGit { }", "input attribute 'url' is missing" },
        .{ "builtins.fetchGit { url = \"/a\"; shallow = 1; }", "input attribute 'shallow' is not a Boolean" },
        .{ "builtins.fetchGit { url = \"/a\"; x = []; }", "argument 'x' to 'fetchGit' is a list while a string, Boolean or integer is expected" },
        .{ "builtins.fetchGit 1", "cannot coerce an integer to a string: 1" },
    }) |c| try expectErrWith(pure, c[0], c[1]);
    try expectErrWith(pure, "builtins.getFlake \"/tmp\"", "cannot call 'getFlake' on unlocked flake reference '/tmp', at «none»:0 (use --impure to override)");
}

test "fromJSON and fromTOML reject null bytes" {
    const msg = "input string '{s}' cannot be represented as Nix string because it contains null bytes";
    try expectErr("builtins.fromJSON \"\\\"a\\\\u0000b\\\"\"", std.fmt.comptimePrint(msg, .{"a␀b"}));
    try expectErr("builtins.fromJSON \"{\\\"a\\\\u0000\\\": 1}\"", std.fmt.comptimePrint(msg, .{"a␀"}));
    try expectErr("builtins.fromTOML \"a = \\\"x\\\\u0000y\\\"\"", "while parsing TOML: error: " ++ std.fmt.comptimePrint(msg, .{"x␀y"}));
    try expectErr("builtins.fromTOML \"\\\"k\\\\u0000\\\" = 1\"", "while parsing TOML: error: " ++ std.fmt.comptimePrint(msg, .{"k␀"}));
}

// The `.drvPath` answers of `nix-instantiate --eval --strict` (Nix 2.34.8). A
// Nix string is bytes, and the `.drv` path hashes them as they are.
test "derivation keeps env and args that are not UTF-8" {
    const cases = [_][2][]const u8{
        .{ "v = byte;", "vhkdfhp7f0qfk8j0kx9b54hpn6cyg8m1-x.drv" },
        .{ "args = [ byte ];", "qsjvddzs1qqxaf6lm7w8pf66lhmkzb5l-x.drv" },
        .{ "v = byte; __structuredAttrs = false; passAsFile = [ \"v\" ];", "qxxd6h5v28msmzrnzf9mc1jxfk2d645i-x.drv" },
    };
    inline for (cases) |c| try expectEval(
        "let byte = builtins.substring 0 1 \"é\"; in (derivation { name = \"x\"; builder = \"/bin/sh\"; system = \"x86_64-linux\"; " ++ c[0] ++ " }).drvPath",
        "\"/nix/store/" ++ c[1] ++ "\"",
    );
}

// `nix-instantiate --eval --arg a $'\n\n1' --arg b '  throw "b"'` names
// `«string»:1:3` for the throw (Nix 2.34.8).
test "a second pseudo file keeps its own positions" {
    var s: Setup = undefined;
    try s.init(&.{});
    defer s.deinit();
    _ = try import_.evalString(&s.ev, "\n\n1");
    try std.testing.expectError(error.EvalFailed, import_.evalString(&s.ev, "  throw \"b\""));
    var buf: [64]u8 = undefined;
    const at = try std.fmt.bufPrint(&buf, "{f}", .{s.files.at(s.ev.failure.?.pos)});
    try std.testing.expectEqualStrings("«string»:1:3", at);
}

test "update forces the right operand first" {
    try expectEvalEach(&.{
        .{ "builtins.tryEval (1 // throw \"x\")", "{ success = false; value = false; }" },
        .{ "builtins.tryEval ({ } // { } // (assert false; { }))", "{ success = false; value = false; }" },
    });
    try expectErrPrefix("builtins.tryEval (throw \"x\" // 1)", "expected a set");
}

test "an invalid regex fails before the string is forced" {
    try expectErrPrefix("builtins.tryEval (builtins.match \"(\" (throw \"x\"))", "invalid regular expression");
    try expectErrPrefix("builtins.tryEval (builtins.split \"(\" (throw \"x\"))", "invalid regular expression");
}

test "nix_eq forces what the shortcut skips" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = "let x = { a = throw \"a\"; }; in";
    try expectEval(x ++ " x == x", "true");
    const cases = [_]struct { []const u8, Outcome }{
        .{ x ++ " x == x", .{ .err = "a" } },
        // the attribute is one slot: forced, then equal without a look inside
        .{ "let x = { a = { b = throw \"b\"; }; }; in x == x", .{ .ok = "true" } },
        .{ "[ 1 2 ] == [ 1 2 ]", .{ .ok = "true" } },
    };
    for (cases) |c| {
        var s: Setup = undefined;
        try s.init(&.{});
        defer s.deinit();
        s.ev.nix_eq = true;
        const got = try evalOutcome(&s, c[0], a);
        try std.testing.expectEqual(std.meta.activeTag(c[1]), std.meta.activeTag(got));
        switch (got) {
            inline else => |g, t| try std.testing.expectEqualStrings(@field(c[1], @tagName(t)), g),
        }
    }
}

test "a function select is a fresh slot when its subject is forced" {
    // `f` forces `foo` in its slot, as the main fiber does when a helper
    // still has the `==` element
    try expectEval("let g = x: x; foo = { a = x: x; b = g g; }; f = foo.a; in builtins.seq f " ++
        "[ ([ foo.a ] == [ foo.a ]) ([ foo.b ] == [ foo.b ]) ([ (foo.c or g) ] == [ (foo.c or g) ]) ]", "[ false false false ]");
}

test "sets compare in the symbol order of nix" {
    const f = struct {
        fn f(comptime n: []const u8) []const u8 {
            return "builtins.tryEval ({ a = 1; \"" ++ n ++ "\" = throw \"t\"; } == { a = 2; \"" ++ n ++ "\" = 1; })";
        }
    }.f;
    try expectEval(f("meta"), "{ success = false; value = false; }");
    try expectEval(f(""), "{ success = false; value = false; }");
    try expectEval(f("y"), "{ success = true; value = false; }");
}

const ca = "__contentAddressed = true; outputHashMode = \"recursive\"; outputHashAlgo = \"sha256\";";
const fod = "outputHashMode = \"flat\"; outputHash = \"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=\";";

// `builder-rpc-v0` builders register their outputs themselves, so the
// environment holds no placeholder for them. The paths are Nix's.
test "builder-rpc outputs have no placeholder" {
    const cases = [_][3][]const u8{
        .{ ca, "requiredSystemFeatures = [ \"builder-rpc-v0\" ];", "hfx0mg11cj7g5b1ldb78lhm3vlcrg9hc" },
        .{ ca, "requiredSystemFeatures = \"kvm builder-rpc-v0\";", "vsdi08jx2v1qg20bjx02gd4y6h85avrr" },
        .{ ca, "__structuredAttrs = true; requiredSystemFeatures = [ \"builder-rpc-v0\" ];", "lj3fkgvh7jaqlyaq2bbs478s6qha1w0a" },
        .{ fod, "requiredSystemFeatures = [ \"builder-rpc-v0\" ];", "kkx1jwyzrkygzcgj8gkbi56pwd5f60hx" },
    };
    inline for (cases) |c| try expectEval(
        "(derivation { name = \"x\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; " ++ c[0] ++ " " ++ c[1] ++ " }).drvPath",
        "\"/nix/store/" ++ c[2] ++ "-x.drv\"",
    );
}

// `--arg` values are thunks, and the last of a name wins
// (common-eval-args.cc keeps autoArgs in a map).
test "auto args are lazy and the last of a name wins" {
    var s: Setup = undefined;
    try s.init(&.{});
    defer s.deinit();
    const api = @import("../api.zig");
    const args = [_]api.AutoArg{
        .{ .name = "x", .text = "throw \"no\"", .is_str = false },
        .{ .name = "y", .text = "1", .is_str = false },
        .{ .name = "y", .text = "two", .is_str = true },
    };
    const auto = try api.autoArgs(&s.ev, std.testing.allocator, &args);
    const f = try import_.evalString(&s.ev, "{ x, y }: y");
    try s.expectPrints(try s.ev.autoCall(f, auto), "\"two\"");
}

test "autoCall names a formal no argument gives" {
    var s: Setup = undefined;
    try s.init(&.{});
    defer s.deinit();
    const auto = try @import("../api.zig").autoArgs(&s.ev, std.testing.allocator, &.{});
    const f = try import_.evalString(&s.ev, "{ x, y ? 1 }: y");
    try std.testing.expectError(error.EvalFailed, s.ev.autoCall(f, auto));
    try std.testing.expectEqualStrings("cannot evaluate a function that has an argument without a value ('x')", s.ev.failure.?.msg);
}
