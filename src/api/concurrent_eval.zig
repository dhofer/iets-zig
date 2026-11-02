//! Differential test of the parallel runtime: every case is evaluated with
//! 1, 4 and 8 workers. Stdout, exit code and the effect lines on stderr,
//! in their order, must match.
//!
//! The three runs of a case go at once, each in a session of its own, and
//! several cases at once: evaluators in several threads must not see each
//! other.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const api = @import("../api.zig");
const testkit = api.testkit;
const EvalArgs = api.EvalArgs;
const Evaluator = @import("../eval/Evaluator.zig");
const lint = @import("../lint.zig");

const slow = "slow = n: builtins.foldl' (a: b: a + b) 0 (builtins.genList (x: x) n);";
const workers = [_]u32{ 1, 4, 8 };

const Case = struct {
    name: []const u8,
    strict: bool = true,
    lint: ?[]const u8 = null,
    /// How many derivations the program demands; the dump directory must
    /// hold at least that many.
    drvs: ?usize = null,
    /// Reads outside the project: the import case reads the Rust tree's
    /// `tests/lang`, a sibling of this one.
    impure: bool = false,
    expr: []const u8,
};

fn case(name: []const u8, strict: bool, expr: []const u8) Case {
    return .{ .name = name, .strict = strict, .expr = expr };
}

const stops =
    \\let SLOW d = i: (derivation { name = "d${toString i}"; builder = "/bin/sh"; system = "x86_64-linux"; }).drvPath;
;

/// A lint finding or a dumped `.drv` is work beyond what the program asked
/// for. The lint cases hold it to demand.
fn effect(name: []const u8, lint_: ?[]const u8, drvs: ?usize, expr: []const u8) Case {
    return .{ .name = name, .lint = lint_, .drvs = drvs, .expr = expr };
}

const plain_cases = [_]Case{
    case("shared-graph", true,
        \\let
        \\  n = 400;
        \\  m = 1000003;
        \\  g = builtins.genList (i: if i < 2 then i else (builtins.elemAt g (i - 1) + builtins.elemAt g (i - 2) + (if i > 100 then builtins.elemAt g (i - 100) else 0)) - (builtins.elemAt g (i - 1) + builtins.elemAt g (i - 2) + (if i > 100 then builtins.elemAt g (i - 100) else 0)) / m * m) n;
        \\  rows = builtins.genList (r: map (i: builtins.elemAt g ((i * 7 + r) - (i * 7 + r) / n * n)) (builtins.genList (x: x) 64)) 64;
        \\in builtins.foldl' (a: b: a + builtins.foldl' (x: y: x + y) 0 b) 0 rows
    ),
    case("deep-attrs", true,
        \\let mk = d: if d == 0 then { v = 1; } else builtins.listToAttrs (map (i: { name = "k${toString i}"; value = mk (d - 1); }) [ 0 1 2 3 4 ]); in mk 5
    ),
    case("cycle", true, "let x = y; y = x; in [ x y x y x y ]"),
    case("cycle-two-ranges", true, "let x = y + 1; y = x + 1; in [ x 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 y 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 x ]"),
    case("cycle-deep", true, "let a = { p = b.q; }; b = { q = a.p; }; in [ a.p b.q 1 2 ]"),
    case("error-elem", true,
        \\map (i: if i == 3 then throw "boom" else i) [ 1 2 3 4 5 6 ]
    ),
    case("try-eval", true,
        \\map (i: (builtins.tryEval (if i == 3 then throw "boom" else i)).value) [ 1 2 3 4 5 6 ]
    ),
    case("trace-once", true,
        \\map (i: builtins.trace "t${toString i}" (i * 2)) [ 1 2 3 4 5 6 7 8 9 10 ]
    ),
    case("warn-once", true,
        \\builtins.concatStringsSep "," (map (i: builtins.warn "w${toString i}" (toString i)) [ 1 2 3 4 5 6 ])
    ),
    .{ .name = "import-shared", .impure = true, .expr = "let f = import ROOT/tests/lang/eval-okay-arithmetic.nix; in map (i: f) [ 1 2 3 4 5 6 7 8 ]" },
    case("drv", true,
        \\let d = derivation { name = "x"; builder = "/bin/sh"; system = "x86_64-linux"; args = map (i: toString i) [ 1 2 3 4 5 ]; }; in map (i: d.drvPath) [ 1 2 3 4 5 6 ]
    ),
    case("json", true, "builtins.toJSON (builtins.genList (i: { a = i; b = builtins.genList (j: i * j) 8; }) 40)"),
    // the identity of a function is the word before forcing
    case("fn-identity", true, "let SLOW t = (x: y: x) 1; A = [ t t t t t t t t ]; B = [ t t t t t t t t ]; in builtins.seq (builtins.any (x: false) A) (builtins.seq (slow 300000) (A == B))"),
    // a thunk only a helper forced still prints as <CODE>
    case("print-code", false, "let SLOW l = map (x: x + slow 20000) [ 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 ]; in builtins.seq (builtins.any (x: x > 0) l) l"),
    // one thunk in one cell is still read by the printer
    // (docs/explanation/evaluation.md, "One cell is not enough")
    case("print-code-single", false, "let SLOW l = builtins.genList (i: slow 20000 * 0 + i + 1) 20; in builtins.seq (builtins.any (x: x > 0) l) l"),
    case("nan", true, "let inf = 1.0e308 * 10.0; nan = inf - inf; in [ (nan == nan) nan (0.0 - nan) inf (-inf) ]"),
    // deeper than a helper stack: a helper that runs out drops its task
    case("deep-chain", true, "let xs = builtins.genList (i: i) 200000; r = builtins.foldl' (acc: x: { v = acc; }) null xs; in builtins.deepSeq r 1"),
    // one failure stops the speculation, so no task restarts it
    case("failing-shared", true,
        \\let SLOW bad = builtins.seq (slow 100000) (throw "bad"); l = builtins.genList (i: bad + i) 20000; in builtins.foldl' (a: b: a + b) 0 l
    ),
};

const eq_lint = "eq-type-mismatch";

const effect_cases = [_]Case{
    effect("lint-speculated", eq_lint, null,
        \\let SLOW in builtins.any (x: x) [ (slow 300000 > 0) (1 == "a") (2 == "b") (3 == "c") (4 == "d") ]
    ),
    effect("lint-demanded", eq_lint, null,
        \\let SLOW in builtins.all (x: x == false) [ (slow 300000 > 0 && false) (1 == "a") (2 == "b") (3 == "c") (4 == "d") ]
    ),
    // a helper is still on the second element when the demand path
    // finishes the first, so the demand path walks the rest ahead of it
    effect("lint-ahead", eq_lint, null,
        \\let SLOW in [ (slow 300000) (builtins.seq (slow 600000) (1 == "a")) (2 == "b") 3 4 ]
    ),
    effect("trace-ahead", null, null,
        \\let SLOW in [ (slow 300000) (builtins.seq (slow 600000) (builtins.trace "a" 1)) (builtins.trace "b" 2) 3 4 ]
    ),
    effect("warn-ahead", eq_lint, null,
        \\let SLOW in [ (slow 300000) (builtins.seq (slow 600000) (builtins.warn "a" 1)) (2 == "b") 3 4 ]
    ),
    // `x` is shared: the walk forces it ahead, under the third element,
    // and the sequential run under the second
    effect("lint-shared-ahead", eq_lint, null,
        \\let SLOW x = 0 == "x"; in [ (slow 300000) (builtins.seq (slow 600000) (builtins.seq x (1 == "a"))) (builtins.seq x 2) 3 4 ]
    ),
    effect("trace-shared-ahead", null, null,
        \\let SLOW x = builtins.trace "x" 0; in [ (slow 300000) (builtins.seq (slow 600000) (builtins.seq x (builtins.trace "a" 1))) (builtins.seq x 2) 3 4 ]
    ),
    // a helper forces `x` under the second element, and the demand path
    // reads it under the first
    effect("lint-shared-helper", eq_lint, null,
        \\let SLOW x = 0 == "x"; in [ (builtins.seq (slow 600000) (builtins.seq x (1 == "a"))) (builtins.seq x 2) 3 4 5 ]
    ),
    // an outer entry forces an inner entry twice: the second force must
    // still read `x`, or the inner value lands in its set without it
    effect("lint-map-twice", eq_lint, null,
        \\let SLOW x = builtins.seq (0 == "x") 1; inner = builtins.mapAttrs (n: v: v) { a = x; }; outer = builtins.mapAttrs (n: v: builtins.seq v v) inner; in [ (slow 600000) outer 3 4 5 ]
    ),
    // a helper's `x` fails after its finding, and `tryEval` keeps the
    // value of the thunk that forced it
    effect("lint-try-helper", eq_lint, null,
        \\let SLOW x = builtins.seq (0 == "x") (throw "no"); in [ (slow 300000) (builtins.tryEval x).success 3 4 5 ]
    ),
    // the same through a `mapAttrs` entry, whose value lands in the set
    effect("lint-shared-map", eq_lint, null,
        \\let SLOW m = builtins.mapAttrs (n: v: builtins.seq (0 == "x") v) { a = 1; }; in [ (builtins.seq (slow 600000) (builtins.seq m.a (1 == "a"))) m.a 3 4 5 ]
    ),
    // `elem` returns at the first element, so nothing below it is demanded
    effect("drv-speculated", null, 0, "STOPS in builtins.elem 1 [ (slow 300000 * 0 + 1) (builtins.stringLength (d 1)) (builtins.stringLength (d 2)) (builtins.stringLength (d 3)) ]"),
    effect("drv-demanded", null, 8, "STOPS in map (i: builtins.stringLength (d i)) [ 1 2 3 4 5 6 7 8 ]"),
};

const set8 = "{ a = t; b = t; c = t; d = t; e = t; f = t; g = t; h = t; }";
const set8_pre = "s = " ++ set8 ++ ";";

/// Every route by which one thunk's word reaches a second cell, as `pre`
/// and the expression both sides are: `any` fans the first list out so
/// helpers force `t`, and `==` then reads both cells. A route nothing marks
/// is a silent return of the bug, so each route has its own case.
const Route = struct { name: []const u8, pre: []const u8, ab: []const u8 };

const routes = [_]Route{
    .{ .name = "local", .pre = "", .ab = "[ t t t t t t t t ]" },
    .{ .name = "select", .pre = "s = { inherit t; };", .ab = "[ s.t s.t s.t s.t s.t s.t s.t s.t ]" },
    .{ .name = "apply", .pre = "f = x: [ x x x x x x x x ];", .ab = "f t" },
    .{ .name = "concat", .pre = "L = [ t t t t ]; M = [ t t t t ];", .ab = "L ++ M" },
    .{ .name = "tail", .pre = "L = [ 0 t t t t t t t t ];", .ab = "builtins.tail L" },
    .{ .name = "filter", .pre = "L = [ t 1 t 2 t 3 t 4 t 5 t 6 t 7 t 8 ];", .ab = "builtins.filter (x: !(builtins.isInt x)) L" },
    .{ .name = "attr-values", .pre = set8_pre, .ab = "builtins.attrValues s" },
    .{ .name = "cat-attrs", .pre = "l = builtins.genList (i: { k = t; }) 8;", .ab = "builtins.catAttrs \"k\" l" },
    .{ .name = "list-to-attrs", .pre = "l = builtins.genList (i: { name = \"k${toString i}\"; value = t; }) 8;", .ab = "builtins.attrValues (builtins.listToAttrs l)" },
    .{ .name = "update", .pre = set8_pre, .ab = "builtins.attrValues (s // { z = 1; })" },
    .{ .name = "inherit-from", .pre = set8_pre, .ab = "builtins.attrValues { inherit (s) a b c d e f g h; }" },
    .{ .name = "rec-attrs", .pre = "", .ab = "builtins.attrValues (rec " ++ set8 ++ ")" },
    .{ .name = "map-arg", .pre = "L = [ t t t t t t t t ];", .ab = "builtins.concatLists (builtins.map (x: [ x ]) L)" },
    // one `mapAttrs` result, read twice: a second call would make fresh
    // map words and the two sides would differ whatever the workers do
    .{ .name = "map-attrs", .pre = "s = " ++ set8 ++ "; m = builtins.attrValues (builtins.mapAttrs (n: v: v) s);", .ab = "builtins.tail ([ 0 ] ++ m)" },
    .{ .name = "zip-attrs", .pre = "s = { a = t; };", .ab = "(builtins.zipAttrsWith (n: vs: vs) [ s s s s s s s s ]).a" },
    .{ .name = "with-scope", .pre = "s = { a = t; b = t; c = t; d = t; };", .ab = "with s; [ a b c d a b c d ]" },
    .{ .name = "remove-attrs", .pre = "s = { a = t; b = t; c = t; d = t; e = t; f = t; g = t; h = t; z = 1; };", .ab = "builtins.attrValues (builtins.removeAttrs s [ \"z\" ])" },
    .{ .name = "intersect-attrs", .pre = set8_pre, .ab = "builtins.attrValues (builtins.intersectAttrs s s)" },
    .{ .name = "foldl", .pre = "L = [ t t t t t t t t ];", .ab = "builtins.foldl' (acc: x: acc ++ [ x ]) [] L" },
    // one thunk shared through many routes at once
    .{
        .name = "stress",
        .pre = "L = [ t t t t ]; s = { a = t; b = t; c = t; d = t; }; W = (builtins.tail ([ 0 ] ++ L)) ++ (builtins.attrValues s) ++ (builtins.attrValues { inherit (s) a b c d; }) ++ (builtins.concatLists (builtins.map (x: [ x ]) L)) ++ (builtins.attrValues (builtins.mapAttrs (n: v: v) s)) ++ (builtins.filter (x: !(builtins.isInt x)) [ t 1 t 2 ]) ++ (with s; [ a b c d ]) ++ (builtins.attrValues (s // { z = 1; })) ++ (builtins.attrValues (rec { e = t; f = t; })) ++ [ s.a s.b ];",
        .ab = "builtins.tail ([ 0 ] ++ W)",
    },
};

// 300000 steals and parks as often as 3000000 did, at a tenth of the time
// in the unoptimized test build; 30000 starts fewer tasks
fn routeCase(comptime r: Route) Case {
    return case("route-" ++ r.name, true, "let SLOW t = (x: y: x) 1; " ++ r.pre ++ " A = " ++ r.ab ++ "; B = " ++ r.ab ++ "; in builtins.seq (builtins.any (x: false) A) (builtins.seq (slow 300000) (A == B))");
}

const all_cases = plain_cases ++ effect_cases ++ blk: {
    var cs: [routes.len]Case = undefined;
    for (routes, &cs) |r, *c| c.* = routeCase(r);
    break :blk cs;
};

const Outcome = struct {
    out: []const u8,
    rc: u8,
    /// The effect lines of stderr, in order, joined.
    eff: []const u8,
};

/// The source of `c`, its placeholders filled in.
fn source(a: Allocator, c: Case, root: []const u8) ![]const u8 {
    var s = try std.mem.replaceOwned(u8, a, c.expr, "STOPS", stops);
    s = try std.mem.replaceOwned(u8, a, s, "SLOW", slow);
    return std.mem.replaceOwned(u8, a, s, "ROOT", root);
}

fn outcome(a: Allocator, c: Case, src: []const u8, w: u32, dump: ?[]const u8) !Outcome {
    const lints: []const lint.Flag = if (c.lint) |n| &.{.{ .selector = n, .level = .warn }} else &.{};
    const args: EvalArgs = .{
        .input = .{ .expr = src },
        .strict = c.strict,
        .workers = w,
        .no_tracing_cache = true,
        .no_ir_cache = true,
        .lints = lints,
        .dump_drvs = dump,
        .pure = if (c.impure) false else null,
    };
    const o = try testkit.eval(std.heap.smp_allocator, testing.io, &args);
    defer o.deinit(std.heap.smp_allocator);
    var eff: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, o.err, '\n');
    while (it.next()) |l| {
        for ([_][]const u8{ "trace", "evaluation warning", "warning: [" }) |p| if (std.mem.startsWith(u8, l, p)) {
            try eff.appendSlice(a, l);
            try eff.append(a, '\n');
            break;
        };
    }
    return .{ .out = try a.dupe(u8, o.out), .rc = o.rc, .eff = eff.items };
}

/// One run of a case at one worker count, on a thread of its own.
const Job = struct {
    c: Case,
    src: []const u8,
    w: u32,
    dump: ?[]const u8,
    arena: std.heap.ArenaAllocator,
    got: anyerror!Outcome = error.NotRun,
    dumped: ?usize = null,

    fn run(j: *Job) void {
        j.got = outcome(j.arena.allocator(), j.c, j.src, j.w, j.dump);
        if (j.dump) |d| {
            var dir = std.Io.Dir.cwd().openDir(testing.io, d, .{ .iterate = true }) catch return;
            defer dir.close(testing.io);
            var n: usize = 0;
            var di = dir.iterate();
            while (di.next(testing.io) catch null) |_| n += 1;
            j.dumped = n;
            std.Io.Dir.cwd().deleteTree(testing.io, d) catch {};
        }
    }
};

/// What is wrong with `c`, if anything, in `a`; its runs at the three
/// worker counts go at once.
fn check(a: Allocator, c: Case, root: []const u8, tmp: []const u8) !?[]const u8 {
    const src = try source(a, c, root);
    var jobs: [workers.len]Job = undefined;
    var threads: [workers.len]std.Thread = undefined;
    for (workers, &jobs, &threads) |w, *j, *t| {
        const dump = if (c.drvs != null) try std.fmt.allocPrint(a, "{s}/iets-concurrent-eval-{d}-{s}-{d}", .{ tmp, std.os.linux.getpid(), c.name, w }) else null;
        j.* = .{ .c = c, .src = src, .w = w, .dump = dump, .arena = .init(std.heap.smp_allocator) };
        t.* = try std.Thread.spawn(.{}, Job.run, .{j});
    }
    for (threads) |t| t.join();
    defer for (&jobs) |*j| j.arena.deinit();
    const base = try jobs[0].got;
    for (jobs[1..]) |*j| {
        const o = try j.got;
        if (o.rc != base.rc or !std.mem.eql(u8, o.out, base.out) or !std.mem.eql(u8, o.eff, base.eff))
            return try std.fmt.allocPrint(a, "{s}: 1 vs {d} workers:\n{d} {s}\n{s}---\n{d} {s}\n{s}", .{ c.name, j.w, base.rc, base.out, base.eff, o.rc, o.out, o.eff });
    }
    if (c.drvs) |want| for (jobs) |j| {
        const got = j.dumped orelse 0;
        if (got < want) return try std.fmt.allocPrint(a, "{s}: {d} workers: {d} derivations dumped, {d} demanded", .{ c.name, j.w, got, want });
    };
    return null;
}

/// The Rust tree, whose `tests/lang` the import case reads; null when it
/// is not beside this one.
fn rustRoot(a: Allocator) !?[]const u8 {
    const cwd = try api.workingDir(testing.io, a);
    const root = try api.absPath(a, cwd, "../iets");
    std.Io.Dir.cwd().access(testing.io, try std.fmt.allocPrint(a, "{s}/tests/lang/eval-okay-arithmetic.nix", .{root}), .{}) catch return null;
    return root;
}

/// Cases run this many at a time, each with its three worker counts.
const at_once = 4;

test "concurrent eval matches sequential eval" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try rustRoot(a);
    const tmp: []const u8 = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";

    const Slot = struct {
        c: Case,
        root: []const u8,
        tmp: []const u8,
        arena: std.heap.ArenaAllocator,
        failed: anyerror!?[]const u8 = null,

        fn run(s: *@This()) void {
            s.failed = check(s.arena.allocator(), s.c, s.root, s.tmp);
        }
    };
    var failures: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < all_cases.len) : (i += at_once) {
        const batch = all_cases[i..@min(i + at_once, all_cases.len)];
        var slots: [at_once]Slot = undefined;
        var threads: [at_once]std.Thread = undefined;
        var n: usize = 0;
        for (batch) |c| {
            // the import case needs the Rust tree beside this one
            if (std.mem.indexOf(u8, c.expr, "ROOT") != null and root == null) continue;
            slots[n] = .{ .c = c, .root = root orelse "", .tmp = tmp, .arena = .init(std.heap.smp_allocator) };
            threads[n] = try std.Thread.spawn(.{}, Slot.run, .{&slots[n]});
            n += 1;
        }
        for (threads[0..n], slots[0..n]) |t, *s| {
            t.join();
            defer s.arena.deinit();
            if (try s.failed) |f| try failures.append(a, try a.dupe(u8, f));
        }
    }
    for (failures.items) |f| std.debug.print("{s}\n\n", .{f});
    try testing.expectEqual(@as(usize, 0), failures.items.len);
}

test "every case has a distinct name" {
    for (all_cases, 0..) |c, i| for (all_cases[i + 1 ..]) |d| {
        try testing.expect(!std.mem.eql(u8, c.name, d.name));
    };
    try testing.expectEqual(@as(usize, 51), all_cases.len);
}

const alloc_expr = "let xs = builtins.genList (i: builtins.genList (j: { a = j; b = toString (i + j); }) 3000) 300; in builtins.length (builtins.deepSeq xs xs)";

/// The arena bytes of every worker after `alloc_expr` at `n` workers.
fn arenaBytes(n: u32) !f64 {
    const inst = try api.Instance.create(std.heap.smp_allocator, testing.io, .{});
    defer inst.destroy();
    const ev = &inst.ev;
    const Run = struct {
        result: Evaluator.Error!void = {},
        fn go(e: *Evaluator, j: *@This()) void {
            j.result = blk: {
                const v = @import("../eval/import.zig").evalString(e, alloc_expr) catch |x| break :blk x;
                _ = e.forceDeep(v) catch |x| break :blk x;
            };
        }
    };
    var job: Run = .{};
    if (n <= 1) {
        Run.go(ev, &job);
        try job.result;
        return @floatFromInt(ev.local.arena.used);
    }
    ev.par.on = true;
    const pool = try Evaluator.Pool.create(ev, n);
    defer pool.destroy();
    try pool.run(Run.go, &job);
    try job.result;
    // worker 0's arena is the main evaluator's again
    var sum: usize = ev.local.arena.used;
    for (pool.workers[1..]) |*w| sum += w.local.arena.used;
    return @floatFromInt(sum);
}

test "concurrent eval sums arena use over workers" {
    const Both = struct {
        one: anyerror!f64 = 0,
        four: anyerror!f64 = 0,
        fn run(b: *@This()) void {
            b.one = arenaBytes(1);
            b.four = arenaBytes(4);
        }
    };
    var b: Both = .{};
    // the stack `main` gives the evaluator
    const t = try std.Thread.spawn(.{ .stack_size = api.main_stack }, Both.run, .{&b});
    t.join();
    const ratio = try b.four / try b.one;
    if (ratio < 0.9 or ratio > 1.5) {
        std.debug.print("arena total follows the worker count: {d} at 1, {d} at 4\n", .{ try b.one, try b.four });
        return error.TestUnexpectedResult;
    }
}
